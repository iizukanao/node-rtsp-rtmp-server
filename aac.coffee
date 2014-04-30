# AAC parser

fs   = require 'fs'
bits = require './bits'

audioBuf = null

MPEG_IDENTIFIER_MPEG2 = 1
MPEG_IDENTIFIER_MPEG4 = 0

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

  # @param opts: {
  #   frameLength (int): 1024 or 960
  #   dependsOnCoreCoder (boolean) (optional): true if core coder is used
  #   coreCoderDelay (number) (optional): delay in samples. mandatory if
  #                                       dependsOnCoreCoder is true.
  # }
  addGASpecificConfig: (opts) ->
    # frameLengthFlag (1 bit)
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

    # extensionFlag (1 bit)
    if opts.audioObjectType in [1, 2, 3, 4, 6, 7]
      bits.add_bit 0
    else
      throw new Error "audio object type #{opts.audioObjectType} is not implemented"

  # @param opts: {
  #   audioObjectType (int): audio object type
  #   extensionAudioObjectType (int) (optional):
  #   sampleRate (int): sample rate in Hz
  #   extensionSampleRate (int) (optional): extension sample rate in Hz
  #   channels (int): number of channels
  #   frameLength (int): 1024 or 960
  # }
  createAudioSpecificConfig: (opts) ->
    bits.create_buf()

    # Table 1.13 - AudioSpecificConfig()

    if opts.extensionAudioObjectType is 5
      audioObjectType = opts.extensionAudioObjectType
    else
      audioObjectType = opts.audioObjectType

    # GetAudioObjectType()
    bits.add_bits 5, audioObjectType
    if audioObjectType >= 31
      bits.add_bits 6, audioObjectType - 32

    samplingFreqIndex = api.getSamplingFreqIndex opts.sampleRate
    bits.add_bits 4, samplingFreqIndex
    if samplingFreqIndex is 0xf
      bits.add_bits 24, opts.sampleRate
    channelConfiguration = api.getChannelConfiguration opts.channels
    bits.add_bits 4, channelConfiguration

    if opts.extensionAudioObjectType is 5
      extensionSamplingFreqIndex = api.getSamplingFreqIndex opts.extensionSampleRate
      bits.add_bits 4, extensionSamplingFreqIndex
      if extensionSamplingFreqIndex is 0xf
        bits.add_bits 24, opts.extensionSampleRate
      # GetAudioObjectType()
      bits.add_bits 5, opts.audioObjectType
      if opts.audioObjectType >= 31
        bits.add_bits 6, opts.audioObjectType - 32
    switch opts.audioObjectType
      when 1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23
        api.addGASpecificConfig opts
      else
        throw new Error "audio object type #{opts.audioObjectType} is not implemented"
    switch opts.audioObjectType
      when 17, 19, 20, 21, 22, 23, 24, 25, 26, 27
        throw new Error "audio object type #{opts.audioObjectType} is not implemented"

    return bits.get_created_buf()

  parseADTSFrame: (adtsFrame) ->
    info = {}

    if (adtsFrame[0] isnt 0xff) or (adtsFrame[1] & 0xf0 isnt 0xf0)
      throw new Error "malformed audio: data doesn't start with a syncword (0xfff)"

    info.mpegIdentifier = bits.read_bits_uint adtsFrame, 12, 1
    profile_ObjectType = bits.read_bits_uint adtsFrame, 16, 2
    if info.mpegIdentifier is MPEG_IDENTIFIER_MPEG2
      info.audioObjectType = profile_ObjectType
    else
      info.audioObjectType = profile_ObjectType + 1
    freq = bits.read_bits_uint adtsFrame, 18, 4
    info.sampleRate = api.getSampleRateFromFreqIndex freq
    info.channels = bits.read_bits_uint adtsFrame, 23, 3

#    # raw_data_block starts from byte index 7
#    id_syn_ele = bits.read_bits_uint adtsFrame, 56, 3
#    console.log "id_syn_ele: #{id_syn_ele}"

    return info

  getNextADTSFrame: ->
    if not audioBuf?
      throw new Error "aac error: file is not opened yet"

    if not api.hasMoreData()
      return null

    # An ADTS frame starts with a syncword (0xfff).
    # But a raw data block may also contain 0xfff which is not
    # a syncword. The length of a frame can be determined by
    # aac_frame_length which is included in the ADTS variable header.
    # However, an audio file may start in the middle of a raw data
    # block. In that case, there is some difficulty in searching for
    # a correct syncword. In real use cases, those data should be
    # handled correctly, but we reject such data here for the
    # sake of simplicity.
    if (audioBuf[0] isnt 0xff) or (audioBuf[1] & 0xf0 isnt 0xf0)
      throw new Error "malformed audio: data doesn't start with a syncword (0xfff)\n" +
                      "try ffmpeg -i <input_file> -c:a copy output.aac"

    aac_frame_length = bits.read_bits_uint audioBuf, 30, 13
    adtsFrame = audioBuf[0...aac_frame_length]

    # Truncate audio buffer
    audioBuf = audioBuf[aac_frame_length..]

    return adtsFrame

module.exports = api
