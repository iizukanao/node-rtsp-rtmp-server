# AAC parser

fs   = require 'fs'
bits = require './bits'

audioBuf = null
audioSampleRate = null
audioChannels = null

api =
  open: (file) ->
    audioBuf = fs.readFileSync file  # up to 1GB

  close: ->
    audioBuf = null

  hasMoreData: ->
    return audioBuf? and (audioBuf.length > 0)

  getSampleRate: ->
    return audioSampleRate

  getChannels: ->
    return audioChannels

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

    if not audioSampleRate?
      freq = bits.read_bits_uint audioBuf, 18, 4

      # Get sample rate from sampling_frequency_index
      audioSampleRate = switch freq
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
        else
          throw new Error "audio error: unknown sampling_frequency_index: #{freq}"

    if not audioChannels?
      audioChannels = bits.read_bits_uint audioBuf, 23, 3

    aac_frame_length = bits.read_bits_uint audioBuf, 30, 13
    adtsFrame = audioBuf[0...aac_frame_length]

    # Truncate audio buffer
    audioBuf = audioBuf[aac_frame_length..]

    return adtsFrame

module.exports = api
