h264 = require './h264'
aac = require './aac'
Bits = require './bits'
logger = require './logger'

api =
  SOUND_FORMAT_AAC: 10  # AAC

  SOUND_RATE_5KHZ : 0  # 5.5 kHz
  SOUND_RATE_11KHZ: 1  # 11 kHz
  SOUND_RATE_22KHZ: 2  # 22 kHz
  SOUND_RATE_44KHZ: 3  # 44 kHz

  # SoundSize for compressed audio is 1 (16-bit)
  SOUND_SIZE_COMPRESSED: 1

  SOUND_TYPE_MONO: 0
  SOUND_TYPE_STEREO: 1

  AAC_PACKET_TYPE_SEQUENCE_HEADER: 0  # AAC sequence header
  AAC_PACKET_TYPE_RAW            : 1  # AAC raw

  AVC_PACKET_TYPE_SEQUENCE_HEADER: 0  # AVC sequence header
  AVC_PACKET_TYPE_NALU           : 1  # AVC NALU
  AVC_PACKET_TYPE_EOS            : 2  # AVC end of sequence

  getSoundType: (channels) ->
    if channels > 1  # stereo
      return 1
    else  # mono
      return 0

  getSoundSize: (numBits) ->
    switch numBits
      when 8 then 0
      when 16 then 1
      else
        throw new Error "Invalid number of bits in a sample: #{numBits}"

  getSampleRateFromSoundRate: (soundRate) ->
    switch soundRate
      when 0 then  5512
      when 1 then 11025
      when 2 then 22050
      when 3 then 44100
      else
        throw new Error "Invalid SoundRate: #{soundRate}"

  # @param  sampleRate (number) sample rate in Hz
  # @return  (number) sound rate
  getSoundRate: (sampleRate) ->
    switch parseInt sampleRate
      when  5512 then 0
      when 11025 then 1
      when 22050 then 2
      when 44100 then 3
      else
        throw new Error "Sample rate is not supported by FLV: #{sampleRate}"

  # @param  opts (object) {
  #   aacPacketType: flv.AAC_PACKET_TYPE_SEQUENCE_HEADER or
  #                  flv.AAC_PACKET_TYPE_RAW
  # }
  # @return  array
  createAACAudioDataTag: (opts) ->
    return api.createAudioDataTag
      soundFormat: api.SOUND_FORMAT_AAC
      soundRate: api.SOUND_RATE_44KHZ  # ignored by Flash Player
      soundSize: api.SOUND_SIZE_COMPRESSED
      soundType: api.SOUND_TYPE_STEREO  # ignored by Flash Player
      aacPacketType: opts.aacPacketType

  videoCodecID2Str: (codecID) ->
    switch codecID
      when 2 then "Sorenson H.263"
      when 3 then "Screen video"
      when 4 then "On2 VP6"
      when 5 then "On2 VP6 with alpha channel"
      when 6 then "Screen video version 2"
      when 7 then "AVC"
      else "unknown"

  parseVideo: (buf) ->
    info = {}
    bits = new Bits buf
    info.videoDataTag = api.readVideoDataTag bits

    # Reject if the codec is not H.264
    if info.videoDataTag.codecID isnt 7
      throw new Error "flv: Video codec ID #{info.videoDataTag.codecID} " +
        "(#{api.videoCodecID2Str info.videoDataTag.codecID}) is not supported. Use H.264."

    switch info.videoDataTag.avcPacketType
      when api.AVC_PACKET_TYPE_SEQUENCE_HEADER
        info.avcDecoderConfigurationRecord = h264.readAVCDecoderConfigurationRecord bits
      when api.AVC_PACKET_TYPE_NALU
        info.nalUnits = bits.remaining_buffer()
      when api.AVC_PACKET_TYPE_EOS
      else
        throw new Error "flv: unknown AVCPacketType: #{info.videoDataTag.avcPacketType}"
    return info

  splitNALUnits: (buf, nalUnitLengthSize) ->
    bits = new Bits buf
    nalUnits = []
    while bits.has_more_data()
      nalUnitLen = bits.read_bits nalUnitLengthSize * 8
      nalUnits.push bits.read_bytes nalUnitLen
    return nalUnits

  soundFormat2Str: (soundFormat) ->
    switch soundFormat
      when 0 then "Linear PCM, platform endian"
      when 1 then "ADPCM"
      when 2 then "MP3"
      when 3 then "Linear PCM, little endian"
      when 4 then "Nellymoser 16 kHz mono"
      when 5 then "Nellymoser 8 kHz mono"
      when 6 then "Nellymoser"
      when 7 then "G.711 A-law logarithmic PCM"
      when 8 then "G.711 mu-law logarithmic PCM"
      when 9 then "reserved"
      when 10 then "AAC"
      when 11 then "Speex"
      when 14 then "MP3 8 kHz"
      when 15 then "Device-specific sound"
      else "unknown"

  parseAudio: (buf) ->
    info = {}
    bits = new Bits buf
    info.audioDataTag = api.readAudioDataTag bits

    # Reject if the sound format is not AAC
    if info.audioDataTag.soundFormat isnt api.SOUND_FORMAT_AAC
      throw new Error "flv: Sound format #{info.audioDataTag.soundFormat} " +
        "(#{api.soundFormat2Str info.audioDataTag.soundFormat}) is not supported. Use AAC."

    switch info.audioDataTag.aacPacketType
      when api.AAC_PACKET_TYPE_SEQUENCE_HEADER
        if bits.has_more_data()
          bits.mark()
          info.ascInfo = aac.readAudioSpecificConfig bits
          info.audioSpecificConfig = bits.marked_bytes()
        else
          logger.warn "flv:parseAudio(): warn: AAC sequence header does not contain AudioSpecificConfig"
      when api.AAC_PACKET_TYPE_RAW
        info.rawDataBlock = bits.remaining_buffer()
      else
        throw new Error "flv: unknown AACPacketType: #{info.audioDataTag.aacPacketType}"
    return info

  # E.4.3.1 VIDEODATA
  readVideoDataTag: (bits) ->
    info = {}
    info.frameType = bits.read_bits 4
    info.codecID = bits.read_bits 4
    if info.codecID is 7
      info.avcPacketType = bits.read_byte()
      info.compositionTime = bits.read_bits 24
#      if (info.avcPacketType isnt 1) and (info.compositionTime isnt 0)
#        # TODO: Does this situation require special handling?
#        logger.error "flv:readVideoDataTag(): AVCPacketType isn't 1 but CompositionTime isn't 0 (feature not implemented); AVCPacketType=#{info.avcPacketType} CompositionTime=#{info.compositionTime}"
    return info

  # E.4.2.1 AUDIODATA
  readAudioDataTag: (bits) ->
    info = {}
    b = bits.read_byte()
    info.soundFormat = b >> 4
    info.soundRate = (b >> 2) & 0b11
    info.soundSize = (b >> 1) & 0b1
    info.soundType = b & 0b1
    if info.soundFormat is api.SOUND_FORMAT_AAC
      info.aacPacketType = bits.read_byte()
    return info

  # @param  opts (object) {
  #   soundFormat (int)
  #   soundRate (int)
  #   soundSize (int)
  #   soundType (int)
  #   aacPacketType (int) (optional): mandatory if soundFormat is AAC
  # }
  # @return array
  createAudioDataTag: (opts) ->
    soundType = opts.soundType
    soundRate = opts.soundRate
    # If AAC, SoundType and SoundRate should be 1 (stereo) and 3 (44 kHz),
    # respectively. Flash Player ignores these values.
    if opts.soundFormat is api.SOUND_FORMAT_AAC
      soundType = 1
      soundRate = api.SOUND_RATE_44KHZ

    # AUDIODATA tag: Adobe's Video File Format Spec v10.1 E.4.2.1 AUDIODATA
    buf = [
      (opts.soundFormat << 4) \ # SoundFormat (4 bits)
      | (soundRate << 2) \      # SoundRate (2 bits): ignored by Flash Player if AAC
      | (opts.soundSize << 1) \ # SoundSize (1 bit)
      | soundType               # SoundType (1 bit): ignored by Flash Player if AAC
    ]
    if opts.soundFormat is api.SOUND_FORMAT_AAC
      buf.push opts.aacPacketType  # AACPacketType (1 bit)
    return buf

  # Convert milliseconds into PTS (90 kHz clock)
  convertMsToPTS: (ms) ->
    return ms * 90

module.exports = api
