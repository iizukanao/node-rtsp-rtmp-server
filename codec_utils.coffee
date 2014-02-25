crypto = require 'crypto'

module.exports =
  # Calculate the digest of data and return a buffer
  calcHmac: (data, key) ->
    hmac = crypto.createHmac 'sha256', key
    hmac.update data
    return hmac.digest()

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
