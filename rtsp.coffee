# RTSP spec:
#   RFC 2326  http://www.ietf.org/rfc/rfc2326.txt

api =
  INTERLEAVED_SIGN: 0x24  # '$' (dollar sign)
  INTERLEAVED_HEADER_LEN: 4

  # Creates an interleaved header and returns the buffer.
  #
  # opts:
  #   channel: <number> channel identifier
  #   payloadLength: <number> payload length
  createInterleavedHeader: (opts) ->
    if not opts?.channel?
      throw new Error "createInterleavedHeader: channel is required"
    if not opts?.payloadLength?
      throw new Error "createInterleavedHeader: payloadLength is required"

    return new Buffer [
      api.INTERLEAVED_SIGN,
      opts.channel,
      opts.payloadLength >> 8, opts.payloadLength & 0xff,
    ]

  # Parses and returns an interleaved header.
  #
  # If the buffer doesn't have enough length for an interleaved header,
  # returns null.
  parseInterleavedHeader: (buf) ->
    if buf.length < api.INTERLEAVED_HEADER_LEN
      # not enough buffer
      return null

    if buf[0] isnt api.INTERLEAVED_SIGN
      throw new Error "The buffer is not an interleaved data"

    info = {}
    info.channel = buf[1]
    info.payloadLength = (buf[2] << 8) | buf[3]
    info.totalLength = api.INTERLEAVED_HEADER_LEN + info.payloadLength
    return info

  # Parses and returns the information of complete interleaved data.
  #
  # If parsing failed or buf doesn't have enough length for
  # the payload, returns null.
  getInterleavedData: (buf) ->
    info = api.parseInterleavedHeader buf
    if not info?
      return null

    if buf.length < info.totalLength
      # not enough buffer
      return null

    info.data = buf[api.INTERLEAVED_HEADER_LEN...info.totalLength]

    return info

module.exports = api
