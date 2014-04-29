crypto = require 'crypto'

module.exports =
  # Calculate the digest of data and return a buffer
  calcHmac: (data, key) ->
    hmac = crypto.createHmac 'sha256', key
    hmac.update data
    return hmac.digest()

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
      else
        throw new Error "Unknown sampling_frequency_index: #{freqIndex}"

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
      else
        throw new Error "Unknown sample rate: #{sampleRate}"
