# AAC parser

fs = require 'fs'
Bits = require './bits'
logger = require './logger'

audioBuf = null

MPEG_IDENTIFIER_MPEG2 = 1
MPEG_IDENTIFIER_MPEG4 = 0

eventListeners = {}

api =
  SYN_ID_SCE: 0x0  # single_channel_element
  SYN_ID_CPE: 0x1  # channel_pair_element
  SYN_ID_CCE: 0x2  # coupling_channel_element
  SYN_ID_LFE: 0x3  # lfe_channel_element
  SYN_ID_DSE: 0x4  # data_stream_elemen
  SYN_ID_PCE: 0x5  # program_config_element
  SYN_ID_FIL: 0x6  # fill_element
  SYN_ID_END: 0x7  # TERM

  open: (file) ->
    audioBuf = fs.readFileSync file  # up to 1GB

  close: ->
    audioBuf = null

  emit: (name, data...) ->
    if eventListeners[name]?
      for listener in eventListeners[name]
        listener data...
    return

  on: (name, listener) ->
    if eventListeners[name]?
      eventListeners[name].push listener
    else
      eventListeners[name] = [ listener ]

  end: ->
    @emit 'end'

  parseADTSHeader: (buf) ->
    info = {}
    bits = new Bits buf

    # adts_fixed_header()
    info.syncword = bits.read_bits 12
    info.ID = bits.read_bit()
    info.layer = bits.read_bits 2
    info.protection_absent = bits.read_bit()
    info.profile_ObjectType = bits.read_bits 2
    info.sampling_frequency_index = bits.read_bits 4
    info.private_bit = bits.read_bit()
    info.channel_configuration = bits.read_bits 3
    info.original_copy = bits.read_bit()
    info.home = bits.read_bit()

    # adts_variable_header()
    info.copyright_identification_bit = bits.read_bit()
    info.copyright_identification_start = bits.read_bit()
    info.aac_frame_length = bits.read_bits 13
    info.adts_buffer_fullness = bits.read_bits 11
    info.number_of_raw_data_blocks_in_frame = bits.read_bits 2

    return info

  # For ascInfo argument, pass a return value of readAudioSpecificConfig()
  createADTSHeader: (ascInfo, aac_frame_length) ->
    bits = new Bits
    bits.create_buf()
    # adts_fixed_header()
    bits.add_bits 12, 0xfff  # syncword
    bits.add_bit 0  # ID (1=MPEG-2 AAC; 0=MPEG-4)
    bits.add_bits 2, 0  # layer
    bits.add_bit 1  # protection_absent
    if ascInfo.audioObjectType - 1 > 0b11
      throw new Error "invalid audioObjectType: #{ascInfo.audioObjectType} (must be <= 4)"
    bits.add_bits 2, ascInfo.audioObjectType - 1  # profile_ObjectType
    bits.add_bits 4, ascInfo.samplingFrequencyIndex  # sampling_frequency_index
    bits.add_bit 0  # private_bit
    if ascInfo.channelConfiguration > 0b111
      throw new Error "invalid channelConfiguration: #{ascInfo.channelConfiguration} (must be <= 7)"
    bits.add_bits 3, ascInfo.channelConfiguration  # channel_configuration
    bits.add_bit 0  # original_copy
    bits.add_bit 0  # home

    # adts_variable_header()
    bits.add_bit 0  # copyright_identification_bit
    bits.add_bit 0  # copyright_identification_start
    if aac_frame_length > 8192 - 7  # 7 == length of ADTS header
      throw new Error "invalid aac_frame_length: #{aac_frame_length} (must be <= 8192)"
    bits.add_bits 13, aac_frame_length + 7  # aac_frame_length (7 == ADTS header length)
    bits.add_bits 11, 0x7ff  # adts_buffer_fullness (0x7ff = VBR)
    bits.add_bits 2, 0  # number_of_raw_data_blocks_in_frame (actual - 1)

    return bits.get_created_buf()

  getNextPossibleSyncwordPosition: (buffer) ->
    syncwordPos = Bits.searchBitsInArray buffer, [0xff, 0xf0], 1
    # The maximum distance between two syncwords is 8192 bytes.
    if syncwordPos > 8192
      throw new Error "the next syncword is too far: #{syncwordPos} bytes"
    return syncwordPos

  skipToNextPossibleSyncword: ->
    syncwordPos = Bits.searchBitsInArray audioBuf, [0xff, 0xf0], 1
    if syncwordPos > 0
      # The maximum distance between two syncwords is 8192 bytes.
      if syncwordPos > 8192
        throw new Error "the next syncword is too far: #{syncwordPos} bytes"
      logger.debug "skipped #{syncwordPos} bytes until syncword"
      audioBuf = audioBuf[syncwordPos..]
    return

  splitIntoADTSFrames: (buffer) ->
    adtsFrames = []
    loop
      if buffer.length < 7
        # not enough ADTS header
        break
      if (buffer[0] isnt 0xff) or (buffer[1] & 0xf0 isnt 0xf0)
        console.log "aac: syncword is not at current position"
        syncwordPos = @getNextPossibleSyncwordPosition()
        buffer = buffer[syncwordPos..]
        continue

      aac_frame_length = Bits.parse_bits_uint buffer, 30, 13
      if buffer.length < aac_frame_length
        # not enough buffer
        break

      if buffer.length >= aac_frame_length + 2
        # check next syncword
        if (buffer[aac_frame_length] isnt 0xff) or
        (buffer[aac_frame_length+1] & 0xf0 isnt 0xf0)  # false syncword
          console.log "aac:splitIntoADTSFrames(): syncword was false positive (emulated syncword)"
          syncwordPos = @getNextPossibleSyncwordPosition()
          buffer = buffer[syncwordPos..]
          continue

      adtsFrame = buffer[0...aac_frame_length]

      # Truncate audio buffer
      buffer = buffer[aac_frame_length..]

      adtsFrames.push adtsFrame
    return adtsFrames

  feedPESPacket: (pesPacket) ->
    if audioBuf?
      audioBuf = Buffer.concat [audioBuf, pesPacket.pes.data]
    else
      audioBuf = pesPacket.pes.data

    pts = pesPacket.pes.PTS
    dts = pesPacket.pes.DTS

    adtsFrames = []
    loop
      if audioBuf.length < 7
        # not enough ADTS header
        break
      if (audioBuf[0] isnt 0xff) or (audioBuf[1] & 0xf0 isnt 0xf0)
        console.log "aac: syncword is not at current position"
        @skipToNextPossibleSyncword()
        continue

      aac_frame_length = Bits.parse_bits_uint audioBuf, 30, 13
      if audioBuf.length < aac_frame_length
        # not enough buffer
        break

      if audioBuf.length >= aac_frame_length + 2
        # check next syncword
        if (audioBuf[aac_frame_length] isnt 0xff) or
        (audioBuf[aac_frame_length+1] & 0xf0 isnt 0xf0)  # false syncword
          console.log "aac:feedPESPacket(): syncword was false positive (emulated syncword)"
          @skipToNextPossibleSyncword()
          continue

      adtsFrame = audioBuf[0...aac_frame_length]

      # Truncate audio buffer
      audioBuf = audioBuf[aac_frame_length..]

      adtsFrames.push adtsFrame
      @emit 'dts_adts_frame', pts, dts, adtsFrame
    if adtsFrames.length > 0
      @emit 'dts_adts_frames', pts, dts, adtsFrames

  feed: (data) ->
    if audioBuf?
      audioBuf = Buffer.concat [audioBuf, data]
    else
      audioBuf = data

    adtsFrames = []
    loop
      if audioBuf.length < 7
        # not enough ADTS header
        break
      if (audioBuf[0] isnt 0xff) or (audioBuf[1] & 0xf0 isnt 0xf0)
        console.log "aac: syncword is not at current position"
        @skipToNextPossibleSyncword()
        continue

      aac_frame_length = Bits.parse_bits_uint audioBuf, 30, 13
      if audioBuf.length < aac_frame_length
        # not enough buffer
        break

      if audioBuf.length >= aac_frame_length + 2
        # check next syncword
        if (audioBuf[aac_frame_length] isnt 0xff) or
        (audioBuf[aac_frame_length+1] & 0xf0 isnt 0xf0)  # false syncword
          console.log "aac:feed(): syncword was false positive (emulated syncword)"
          @skipToNextPossibleSyncword()
          continue

      adtsFrame = audioBuf[0...aac_frame_length]

      # Truncate audio buffer
      audioBuf = audioBuf[aac_frame_length..]

      adtsFrames.push adtsFrame
      @emit 'adts_frame', adtsFrame
    if adtsFrames.length > 0
      @emit 'adts_frames', adtsFrames

  hasMoreData: ->
    return audioBuf? and (audioBuf.length > 0)

  getSampleRateFromFreqIndex: (freqIndex) ->
    switch freqIndex
      when 0x0 then 96000
      when 0x1 then 88200
      when 0x2 then 64000
      when 0x3 then 48000
      when 0x4 then 44100
      when 0x5 then 32000
      when 0x6 then 24000
      when 0x7 then 22050
      when 0x8 then 16000
      when 0x9 then 12000
      when 0xa then 11025
      when 0xb then  8000
      when 0xc then  7350
      else null  # escape value

  # ISO 14496-3 - Table 1.16
  getSamplingFreqIndex: (sampleRate) ->
    switch sampleRate
      when 96000 then 0x0
      when 88200 then 0x1
      when 64000 then 0x2
      when 48000 then 0x3
      when 44100 then 0x4
      when 32000 then 0x5
      when 24000 then 0x6
      when 22050 then 0x7
      when 16000 then 0x8
      when 12000 then 0x9
      when 11025 then 0xa
      when  8000 then 0xb
      when  7350 then 0xc
      else 0xf  # escape value

  getChannelConfiguration: (channels) ->
    switch channels
      when 1 then 1
      when 2 then 2
      when 3 then 3
      when 4 then 4
      when 5 then 5
      when 6 then 6
      when 8 then 7
      else
        throw new Error "#{channels} channels audio is not supported"

  getChannelsByChannelConfiguration: (channelConfiguration) ->
    switch channelConfiguration
      when 1 then 1
      when 2 then 2
      when 3 then 3
      when 4 then 4
      when 5 then 5
      when 6 then 6
      when 7 then 8
      else
        throw new Error "Channel configuration #{channelConfiguration} is not supported"

  # @param opts: {
  #   frameLength (int): 1024 or 960
  #   dependsOnCoreCoder (boolean) (optional): true if core coder is used
  #   coreCoderDelay (number) (optional): delay in samples. mandatory if
  #                                       dependsOnCoreCoder is true.
  # }
  addGASpecificConfig: (bits, opts) ->
    # frameLengthFlag (1 bit)
    if opts.frameLengthFlag?
      bits.add_bit opts.frameLengthFlag
    else
      if opts.frameLength is 1024
        bits.add_bit 0
      else if opts.frameLength is 960
        bits.add_bit 1
      else
        throw new Error "Invalid frameLength: #{opts.frameLength} (must be 1024 or 960)"

    # dependsOnCoreCoder (1 bit)
    if opts.dependsOnCoreCoder
      bits.add_bit 1
      bits.add_bits 14, opts.coreCoderDelay
    else
      bits.add_bit 0

    if opts.extensionFlag?
      bits.add_bit opts.extensionFlag
    else
      # extensionFlag (1 bit)
      if opts.audioObjectType in [1, 2, 3, 4, 6, 7]
        bits.add_bit 0
      else
        throw new Error "audio object type #{opts.audioObjectType} is not implemented"

  # ISO 14496-3 GetAudioObjectType()
  readGetAudioObjectType: (bits) ->
    audioObjectType = bits.read_bits 5
    if audioObjectType is 31
      audioObjectType = 32 + bits.read_bits 6
    return audioObjectType

  # @param opts: {
  #   samplingFrequencyIndex: number
  #   channelConfiguration: number
  #   audioObjectType: number
  # }
  readGASpecificConfig: (bits, opts) ->
    info = {}
    info.frameLengthFlag = bits.read_bit()
    info.dependsOnCoreCoder = bits.read_bit()
    if info.dependsOnCoreCoder is 1
      info.coreCoderDelay = bits.read_bits 14
    info.extensionFlag = bits.read_bit()
    if opts.channelConfiguration is 0
      info.program_config_element = api.read_program_config_element bits
    if opts.audioObjectType in [6, 20]
      info.layerNr = bits.read_bits 3
    if info.extensionFlag
      if opts.audioObjectType is 22
        info.numOfSubFrame = bits.read_bits 5
        info.layer_length = bits.read_bits 11
      if opts.audioObjectType in [17, 19, 20, 23]
        info.aacSectionDataResilienceFlag = bits.read_bit()
        info.aacScalefactorDataResilienceFlag = bits.read_bit()
        info.aacSpectralDataResilienceFlag = bits.read_bit()
      info.extensionFlag3 = bits.read_bit()
      # ISO 14496-3 says: tbd in version 3
    return info

  # ISO 14496-3 1.6.2.1 AudioSpecificConfig
  parseAudioSpecificConfig: (buf) ->
    bits = new Bits buf
    asc = api.readAudioSpecificConfig bits
    return asc

  # ISO 14496-3 1.6.2.1 AudioSpecificConfig
  readAudioSpecificConfig: (bits) ->
    info = {}
    info.audioObjectType = api.readGetAudioObjectType bits
    info.samplingFrequencyIndex = bits.read_bits 4
    if info.samplingFrequencyIndex is 0xf
      info.samplingFrequency = bits.read_bits 24
    else
      info.samplingFrequency = api.getSampleRateFromFreqIndex info.samplingFrequencyIndex
    info.channelConfiguration = bits.read_bits 4

    info.sbrPresentFlag = -1
    info.psPresentFlag = -1
    info.mpsPresentFlag = -1
    if (info.audioObjectType is 5) or (info.audioObjectType is 29)
      # Explicit hierarchical signaling of SBR
      # 1.6.5.2 2.A in ISO 14496-3
      info.explicitHierarchicalSBR = true

      info.extensionAudioObjectType = 5
      info.sbrPresentFlag = 1
      if info.audioObjectType is 29
        info.psPresentFlag = 1
      extensionSamplingFrequencyIndex = bits.read_bits 4
      if extensionSamplingFrequencyIndex is 0xf
        info.extensionSamplingFrequency = bits.read_bits 24
      else
        info.extensionSamplingFrequency = api.getSampleRateFromFreqIndex extensionSamplingFrequencyIndex
      info.audioObjectType = api.readGetAudioObjectType bits
      if info.audioObjectType is 22
        info.extensionChannelConfiguration = bits.read_bits 4
    else
      info.extensionAudioObjectType = 0

    switch info.audioObjectType
      when 1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23
        info.gaSpecificConfig = api.readGASpecificConfig bits, info
      else
        throw new Error "audio object type #{info.audioObjectType} is not implemented"
    switch info.audioObjectType
      when 17, 19, 20, 21, 22, 23, 24, 25, 26, 27, 39
        throw new Error "audio object type #{info.audioObjectType} is not implemented"

    extensionIdentifier = -1
    if bits.get_remaining_bits() >= 11
      extensionIdentifier = bits.read_bits 11
    if extensionIdentifier is 0x2b7
      extensionIdentifier = -1

      if (info.extensionAudioObjectType isnt 5) and (bits.get_remaining_bits() >= 5)
        # Explicit backward compatible signaling of SBR
        # 1.6.5.2 2.B in ISO 14496-3
        info.explicitBackwardCompatibleSBR = true

        info.extensionAudioObjectType = api.readGetAudioObjectType bits
        if info.extensionAudioObjectType is 5
          info.sbrPresentFlag = bits.read_bit()
          if info.sbrPresentFlag is 1
            extensionSamplingFrequencyIndex = bits.read_bits 4
            if extensionSamplingFrequencyIndex is 0xf
              info.extensionSamplingFrequency = bits.read_bits 24
            else
              info.extensionSamplingFrequency = api.getSampleRateFromFreqIndex extensionSamplingFrequencyIndex
          if bits.get_remaining_bits() >= 12
            extensionIdentifier = bits.read_bits 11
            if extensionIdentifier is 0x548
              extensionIdentifier = -1
              info.psPresentFlag = bits.read_bit()
        if info.extensionAudioObjectType is 22
          info.sbrPresentFlag = bits.read_bit()
          if info.sbrPresentFlag is 1
            extensionSamplingFrequencyIndex = bits.read_bits 4
            if extensionSamplingFrequencyIndex is 0xf
              info.extensionSamplingFrequency = bits.read_bits 24
            else
              info.extensionSamplingFrequency = api.getSampleRateFromFreqIndex extensionSamplingFrequencyIndex
          info.extensionChannelConfiguration = bits.read_bits 4
    if (extensionIdentifier is -1) and (bits.get_remaining_bits() >= 11)
      extensionIdentifier = bits.read_bits 11
    if extensionIdentifier is 0x76a
      logger.warn "aac: this audio config may not be supported (extensionIdentifier == 0x76a)"
      if (info.audioObjectType isnt 30) and (bits.get_remaining_bits() >= 1)
        info.mpsPresentFlag = bits.read_bit()
        if info.mpsPresentFlag is 1
          info.sacPayloadEmbedding = 1
          info.sscLen = bits.read_bits 8
          if info.sscLen is 0xff
            sscLenExt = bits.read_bits 16
            info.sscLen += sscLenExt
          info.spatialSpecificConfig = api.readSpatialSpecificConfig bits

    return info

  readSpatialSpecificConfig: (bits) ->
    throw new Error "SpatialSpecificConfig is not implemented"

  # Inverse of GetAudioObjectType() in ISO 14496-3 Table 1.14
  addAudioObjectType: (bits, audioObjectType) ->
    if audioObjectType >= 32
      bits.add_bits 5, 31  # 0b11111
      bits.add_bits 6, audioObjectType - 32
    else
      bits.add_bits 5, audioObjectType

  # @param opts: A return value of parseAudioSpecificConfig(), or an object: {
  #   audioObjectType (int): audio object type
  #   samplingFrequency (int): sample rate in Hz
  #   extensionSamplingFrequency (int) (optional): sample rate in Hz for extension
  #   channels (int): number of channels
  #   extensionChannels (int): number of channels for extension
  #   frameLength (int): 1024 or 960
  # }
  createAudioSpecificConfig: (opts, explicitHierarchicalSBR=false) ->
    bits = new Bits
    bits.create_buf()

    # Table 1.13 - AudioSpecificConfig()

    if (opts.sbrPresentFlag is 1) and explicitHierarchicalSBR
      if opts.psPresentFlag is 1
        audioObjectType = 29 # HE-AAC v2
      else
        audioObjectType = 5  # HE-AAC v1
    else
      audioObjectType = opts.audioObjectType

    api.addAudioObjectType bits, audioObjectType

    samplingFreqIndex = api.getSamplingFreqIndex opts.samplingFrequency
    bits.add_bits 4, samplingFreqIndex
    if samplingFreqIndex is 0xf
      bits.add_bits 24, opts.samplingFrequency
    if opts.channelConfiguration?
      bits.add_bits 4, opts.channelConfiguration
    else
      channelConfiguration = api.getChannelConfiguration opts.channels
      bits.add_bits 4, channelConfiguration

    if (opts.sbrPresentFlag is 1) and explicitHierarchicalSBR
      # extensionSamplingFrequencyIndex
      samplingFreqIndex = api.getSamplingFreqIndex opts.extensionSamplingFrequency
      bits.add_bits 4, samplingFreqIndex
      if samplingFreqIndex is 0xf
        # extensionSamplingFrequency
        bits.add_bits 24, opts.extensionSamplingFrequency
      api.addAudioObjectType bits, opts.audioObjectType
      if opts.audioObjectType is 22
        if opts.channelConfiguration?
          bits.add_bits 4, opts.channelConfiguration
        else
          channelConfiguration = api.getChannelConfiguration opts.extensionChannels
          bits.add_bits 4, channelConfiguration

    switch opts.audioObjectType
      when 1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23
        if opts.gaSpecificConfig?
          api.addGASpecificConfig bits, opts.gaSpecificConfig
        else
          api.addGASpecificConfig bits, opts
      else
        throw new Error "audio object type #{opts.audioObjectType} is not implemented"
    switch opts.audioObjectType
      when 17, 19, 20, 21, 22, 23, 24, 25, 26, 27, 39
        throw new Error "audio object type #{opts.audioObjectType} is not implemented"

    if (opts.sbrPresentFlag is 1) and (not explicitHierarchicalSBR)
      # extensionIdentifier
      bits.add_bits 11, 0x2b7

      if opts.audioObjectType isnt 22
        # extensionAudioObjectType
        api.addAudioObjectType bits, 5

        # sbrPresentFlag
        bits.add_bit 1

        samplingFreqIndex = api.getSamplingFreqIndex opts.extensionSamplingFrequency
        # extensionSamplingFrequencyIndex
        bits.add_bits 4, samplingFreqIndex
        if samplingFreqIndex is 0xf
          # extensionSamplingFrequency
          bits.add_bits 24, opts.extensionSamplingFrequency

        if opts.psPresentFlag is 1
          # extensionIdentifier
          bits.add_bits 11, 0x548
          # psPresentFlag
          bits.add_bit 1
      else  # opts.audioObjectType is 22
        # extensionAudioObjectType
        api.addAudioObjectType bits, 22
        # sbrPresentFlag
        bits.add_bit 1

        samplingFreqIndex = api.getSamplingFreqIndex opts.extensionSamplingFrequency
        # extensionSamplingFrequencyIndex
        bits.add_bits 4, samplingFreqIndex
        if samplingFreqIndex is 0xf
          # extensionSamplingFrequency
          bits.add_bits 24, opts.extensionSamplingFrequency

        # extensionChannelConfiguration
        if opts.extensionChannelConfiguration?
          bits.add_bits 4, opts.extensionChannelConfiguration
        else
          channelConfiguration = api.getChannelConfiguration opts.extensionChannels
          bits.add_bits 4, channelConfiguration

    return bits.get_created_buf()

  parseADTSFrame: (adtsFrame) ->
    info = {}

    if (adtsFrame[0] isnt 0xff) or (adtsFrame[1] & 0xf0 isnt 0xf0)
      throw new Error "malformed audio: data doesn't start with a syncword (0xfff)"

    info.mpegIdentifier = Bits.parse_bits_uint adtsFrame, 12, 1
    profile_ObjectType = Bits.parse_bits_uint adtsFrame, 16, 2
    if info.mpegIdentifier is MPEG_IDENTIFIER_MPEG2
      info.audioObjectType = profile_ObjectType
    else
      info.audioObjectType = profile_ObjectType + 1
    freq = Bits.parse_bits_uint adtsFrame, 18, 4
    info.sampleRate = api.getSampleRateFromFreqIndex freq
    info.channels = Bits.parse_bits_uint adtsFrame, 23, 3

#    # raw_data_block starts from byte index 7
#    id_syn_ele = Bits.parse_bits_uint adtsFrame, 56, 3

    return info

  getNextADTSFrame: ->
    if not audioBuf?
      throw new Error "aac error: file is not opened yet"

    loop
      if not api.hasMoreData()
        return null

      if (audioBuf[0] isnt 0xff) or (audioBuf[1] & 0xf0 isnt 0xf0)
        console.log "aac: syncword is not at current position"
        @skipToNextPossibleSyncword()
        continue

      aac_frame_length = Bits.parse_bits_uint audioBuf, 30, 13
      if audioBuf.length < aac_frame_length
        # not enough buffer
        return null

      if audioBuf.length >= aac_frame_length + 2
        # check next syncword
        if (audioBuf[aac_frame_length] isnt 0xff) or
        (audioBuf[aac_frame_length+1] & 0xf0 isnt 0xf0)  # false syncword
          console.log "aac:getNextADTSFrame(): syncword was false positive (emulated syncword)"
          @skipToNextPossibleSyncword()
          continue

      adtsFrame = audioBuf[0...aac_frame_length]

      # Truncate audio buffer
      audioBuf = audioBuf[aac_frame_length..]

      return adtsFrame

module.exports = api
