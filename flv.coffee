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
  AAC_PACKET_TYPE_RAW: 1  # AAC raw

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

  # @param  opts (object) {
  #   soundFormat (int)
  #   soundRate (int)
  #   soundSize (int)
  #   soundType (int)
  #   aacPacketType (int) (optional): mandatory if soundFormat is AAC
  # }
  # @return array
  createAudioDataTag: (opts) ->
    # AUDIODATA tag: Adobe's Video File Format Spec v10.1 E.4.2.1 AUDIODATA
    # TODO: If AAC, SoundType and SoundRate should be 1 and 44 kHz, respectively.
    buf = [
      (opts.soundFormat << 4) \ # SoundFormat (4 bits)
      | (opts.soundRate << 2) \ # SoundRate (2 bits): ignored by Flash Player if AAC
      | (opts.soundSize << 1) \ # SoundSize (1 bit)
      | opts.soundType  # SoundType (1 bit): ignored by Flash Player if AAC
    ]
    if opts.soundFormat is api.SOUND_FORMAT_AAC
      buf.push opts.aacPacketType  # AACPacketType (1 bit)
    return buf

module.exports = api
