# SDP spec:
#   RFC 4566  https://tools.ietf.org/html/rfc4566

aac = require './aac'

api =
  # opts:
  #   username (string): Username or '-'
  #   sessionID (string): Session ID (numeric string)
  #   sessionVersion (string): Session version number
  #   addressType (string): 'IP4' or 'IP6'
  #   unicastAddress (string): Address of the machine from which the session
  #                            was created. A local IP address MUST NOT be
  #                            used in any context where the SDP description
  #                            might leave the scope in which the address is
  #                            meaningful.
  #   audioPayloadType (number): payload type for audio
  #   audioEncodingName (string): encoding name for audio
  #   audioClockRate (number): clock rate for audio
  #   audioChannels (number): number of audio channels
  #   audioSampleRate (number): audio sample rate
  #   audioObjectType (number): audio object type
  #   videoPayloadType (number): payload type for video
  #   videoEncodingName (string): encoding name for video
  #   videoClockRate (number): clock rate for video
  #   videoProfileLevelId (string): profile-level-id for video
  #   videoSpropParameterSets (string): sprop-parameter-sets for video
  #   videoHeight (number): video frame height
  #   videoWidth (number): video frame width
  #   videoFrameRate (string): video frame rate. Either <integer> or
  #                            <integer>.<fraction> is allowed.
  createSDP: (opts) ->
    for prop in ['username', 'sessionID', 'sessionVersion', 'addressType',
      'unicastAddress', 'audioPayloadType', 'audioEncodingName', 'audioClockRate',
      'audioChannels', 'audioSampleRate', 'videoPayloadType', 'videoEncodingName',
      'videoClockRate', 'videoProfileLevelId', 'videoSpropParameterSets',
      'videoHeight', 'videoWidth', 'videoFrameRate']
      if not opts?[prop]?
        throw new Error "createSDP: property #{prop} is required"

    # configspec: for MPEG-4 Audio streams, use hexstring of AudioSpecificConfig()
    # see 1.6.2.1 of ISO/IEC 14496-3 for the details of AudioSpecificConfig
    configspec = new Buffer aac.createAudioSpecificConfig
      audioObjectType: opts.audioObjectType
      sampleRate: opts.audioSampleRate
      channels: opts.audioChannels
      frameLength: 1024  # TODO: How to detect 960?
    configspec = configspec.toString 'hex'

    # SDP parameters are defined in RFC 4566.
    # sizeLength, indexLength, indexDeltaLength are defined by
    # RFC 3640 or RFC 5691.
    #
    # packetization-mode: (see Section 5.4 of RFC 6184 for details)
    #   0: Single NAL Unit Mode
    #   1: Non-Interleaved Mode (for STAP-A, FU-A)
    #   2: Interleaved Mode (for STAP-B, MTAP16, MTAP24, FU-A, FU-B)
    #
    # rtpmap:96 mpeg4-generic/<audio clock rate>/<audio channels>
    #
    # TODO: How to determine profile-level-id?
    #   1: Main Audio Profile Level 1
    """
    v=0
    o=#{opts.username} #{opts.sessionID} #{opts.sessionVersion} IN #{opts.addressType} #{opts.unicastAddress}
    s= 
    c=IN #{opts.addressType} #{opts.unicastAddress}
    t=0 0
    a=sdplang:en
    a=range:npt=0.0-
    a=control:*
    m=audio 0 RTP/AVP #{opts.audioPayloadType}
    a=rtpmap:#{opts.audioPayloadType} #{opts.audioEncodingName}/#{opts.audioClockRate}/#{opts.audioChannels}
    a=fmtp:#{opts.audioPayloadType} profile-level-id=1;mode=AAC-hbr;sizeLength=13;indexLength=3;indexDeltaLength=3;config=#{configspec}
    a=control:trackID=1
    m=video 0 RTP/AVP #{opts.videoPayloadType}
    a=rtpmap:#{opts.videoPayloadType} #{opts.videoEncodingName}/#{opts.videoClockRate}
    a=fmtp:#{opts.videoPayloadType} packetization-mode=1;profile-level-id=#{opts.videoProfileLevelId};sprop-parameter-sets=#{opts.videoSpropParameterSets}
    a=cliprect:0,0,#{opts.videoHeight},#{opts.videoWidth}
    a=framesize:#{opts.videoPayloadType} #{opts.videoWidth}-#{opts.videoHeight}
    a=framerate:#{opts.videoFrameRate}
    a=control:trackID=2

    """.replace /\n/g, "\r\n"

module.exports = api
