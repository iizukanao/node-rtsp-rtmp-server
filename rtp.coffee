# RTP spec:
#   RFC 3550  http://tools.ietf.org/html/rfc3550
# RTP payload format for H.264 video:
#   RFC 6184  http://tools.ietf.org/html/rfc6184
# RTP payload format for AAC audio:
#   RFC 3640  http://tools.ietf.org/html/rfc3640
#   RFC 5691  http://tools.ietf.org/html/rfc5691

# Number of seconds from 1900-01-01 to 1970-01-01
EPOCH = 2208988800

# Constant for calculating NTP fractional second
NTP_SCALE_FRAC = 4294.967295
TIMESTAMP_ROUNDOFF = 4294967296  # 32 bits

RTP_HEADER_LEN = 12

publicAPI =
  # Number of bytes in RTP header
  RTP_HEADER_LEN: RTP_HEADER_LEN

  # Replace SSRC in-place in the given RTP header
  replaceSSRCInRTP: (buf, ssrc) ->
    buf[8]  = (ssrc >>> 24) & 0xff
    buf[9]  = (ssrc >>> 16) & 0xff
    buf[10] = (ssrc >>> 8) & 0xff
    buf[11] = ssrc & 0xff
    return

  # Get NTP timestamp for a time
  # time is expressed the same as Date.now()
  getNTPTimestamp: (time) ->
    sec = parseInt(time / 1000)
    ms = time - (sec * 1000)
    ntp_sec = sec + EPOCH
    ntp_usec = Math.round(ms * 1000 * NTP_SCALE_FRAC)
    return [ntp_sec, ntp_usec]

  # Used for encapsulating AAC audio data
  # opts:
  #   accessUnitLength (number): number of bytes in the access unit
  createAudioHeader: (opts) ->
    return [
      ## payload
      ## See section 3.2.1 and 3.3.6 of RFC 3640 for details
      ## AU Header Section
      # AU-headers-length(16) for AAC-hbr
      # Number of bits in the AU-headers
      0x00, 0x10,
      # AU Header
      # AU-size(13) by SDP
      # AU-Index(3) or AU-Index-Delta(3)
      # AU-Index is used for the first access unit, and the value must be 0
      # AU-Index-Delta is used for the consecutive When interleaving is not applied, AU-Index-Delta is 0
      opts.accessUnitLength >> 5,
      (opts.accessUnitLength & 0b11111) << 3,
      # There is no Auxiliary Section for AAC-hbr
    ]

  # Used for encapsulating H.264 video data
  createFragmentationUnitHeader: (opts) ->
    return [
      # Fragmentation Unit
      # See section 5.8 of RFC 6184 for details
      #
      # FU indicator
      # forbidden_zero_bit(1), nal_ref_idc(2), type(5)
      # type is 28 for FU-A
      opts.nal_ref_idc | 28,
      # FU header
      # start bit(1) == 0, end bit(1) == 1, reserved bit(1), type(5)
      (opts.isStart << 7) | (opts.isEnd << 6) | opts.nal_unit_type
    ]

  # Create RTP header
  # opts:
  #   marker (boolean): true if this is the last packet of the
  #                     access unit indicated by the RTP timestamp
  #   payloadType (number): payload type
  #   sequenceNumber (number): sequence number
  #   timestamp (number): timestamp in 90 kHz clock rate
  #   ssrc (number): SSRC (can be null)
  createRTPHeader: (opts) ->
    seqNum = opts.sequenceNumber
    ts = opts.timestamp
    ssrc = opts.ssrc ? 0
    return [
      # version(2): 2
      # padding(1): 0
      # extension(1): 0
      # CSRC count(4): 0
      0b10000000,

      # marker(1)
      # payload type(7)
      (opts.marker << 7) | opts.payloadType,

      # sequence number(16)
      seqNum >>> 8,
      seqNum & 0xff,

      # timestamp(32) in 90 kHz clock rate
      (ts >>> 24) & 0xff,
      (ts >>> 16) & 0xff,
      (ts >>> 8) & 0xff,
      ts & 0xff,

      # SSRC(32)
      (ssrc >>> 24) & 0xff,
      (ssrc >>> 16) & 0xff,
      (ssrc >>> 8) & 0xff,
      ssrc & 0xff,
    ]

  # Create RTCP Sender Report packet
  # opts:
  #   time: timestamp of the packet
  #   rtpTime: timestamp relative to the start point of media
  #   ssrc: SSRC
  #   packetCount: packet count
  #   octetCount: octetCount
  createSenderReport: (opts) ->
    if not opts?.ssrc?
      throw new Error "createSenderReport: ssrc is required"
    ssrc = opts.ssrc
    if not opts?.packetCount?
      throw new Error "createSenderReport: packetCount is required"
    packetCount = opts.packetCount
    if not opts?.octetCount?
      throw new Error "createSenderReport: octetCount is required"
    octetCount = opts.octetCount
    if not opts?.time?
      throw new Error "createSenderReport: time is required"
    ntp_ts = publicAPI.getNTPTimestamp opts.time
    if not opts?.rtpTime?
      throw new Error "createSenderReport: rtpTime is required"
    rtp_ts = opts.rtpTime

    length = 6  # 28 (packet bytes) / 4 (32-bit word) - 1
    return [
      # See section 6.4.1 for details

      # version(2): 2 (RTP version 2)
      # padding(1): 0 (padding doesn't exist)
      # reception report count(5): 0 (no reception report blocks)
      0b10000000,

      # packet type(8): 200 (RTCP Sender Report)
      200,

      # length(16)
      length >> 8, length & 0xff,

      # SSRC of sender(32)
      (ssrc >>> 24) & 0xff,
      (ssrc >>> 16) & 0xff,
      (ssrc >>> 8) & 0xff,
      ssrc & 0xff,

      # [sender info]
      # NTP timestamp(64)
      (ntp_ts[0] >>> 24) & 0xff,
      (ntp_ts[0] >>> 16) & 0xff,
      (ntp_ts[0] >>> 8) & 0xff,
      ntp_ts[0] & 0xff,
      (ntp_ts[1] >>> 24) & 0xff,
      (ntp_ts[1] >>> 16) & 0xff,
      (ntp_ts[1] >>> 8) & 0xff,
      ntp_ts[1] & 0xff,

      # RTP timestamp(32)
      (rtp_ts >>> 24) & 0xff,
      (rtp_ts >>> 16) & 0xff,
      (rtp_ts >>> 8) & 0xff,
      rtp_ts & 0xff,

      # sender's packet count(32)
      (packetCount >>> 24) & 0xff,
      (packetCount >>> 16) & 0xff,
      (packetCount >>> 8) & 0xff,
      packetCount & 0xff,

      # sender's octet count(32)
      (octetCount >>> 24) & 0xff,
      (octetCount >>> 16) & 0xff,
      (octetCount >>> 8) & 0xff,
      octetCount & 0xff,
    ]

module.exports = publicAPI
