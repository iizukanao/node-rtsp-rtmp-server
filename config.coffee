os = require 'os'

module.exports =
  ############################
  ### Basic configurations ###
  ############################

  # Server listen port
  serverPort: 80

  # RTMP server listen port
  rtmpServerPort: 1935

  # Server name which will be embedded in
  # RTSP and HTTP response headers.
  # Default server name is used when this value is null.
  serverName: 'node-rtsp-rtmp-server'

  # Average frame rate of video (informative)
  videoFrameRate: 30

  # Video bitrate in Kbps (informative)
  videoBitrateKbps: 2000

  # Audio bitrate in Kbps (informative)
  audioBitrateKbps: 40

  ### Enable/disable each functions ###

  # Enable RTSP server
  enableRTSP: true

  # Enable RTMP/RTMPE server (not including RTMPT)
  enableRTMP: true

  # Enable RTMPT/RTMPTE server
  enableRTMPT: true

  # Enable HTTP server
  enableHTTP: true

  # Enable custom protocol receiver
  enableCustomReceiver: true

  ### Custom protocol receiver configurations ###

  # Transport for custom protocol receiver
  # 'unix' or 'tcp' or 'udp'
  receiverType: if os.platform() is 'win32' then 'tcp' else 'unix'

  # For receiverType == 'unix'
  # UNIX domain socket used for receiving audio/video data
  videoControlReceiverPath: '/tmp/node_rtsp_rtmp_videoControl'
  audioControlReceiverPath: '/tmp/node_rtsp_rtmp_audioControl'
  videoDataReceiverPath   : '/tmp/node_rtsp_rtmp_videoData'
  audioDataReceiverPath   : '/tmp/node_rtsp_rtmp_audioData'

  # For receiverType == 'tcp' or 'udp'
  receiverListenHost      : '0.0.0.0'
  videoControlReceiverPort: 1111
  audioControlReceiverPort: 1112
  videoDataReceiverPort   : 1113
  audioDataReceiverPort   : 1114

  # For receiverType == 'tcp'
  receiverTCPBacklog: 511

  ### RTSP configurations ###

  # Server ports for RTP and RTCP
  audioRTPServerPort : 7042  # even
  audioRTCPServerPort: 7043  # odd and contiguous
  videoRTPServerPort : 7044  # even
  videoRTCPServerPort: 7045  # odd and contiguous

  ### RTSP/RTMP configurations ###

  # Application name for live streams. Live streams will be accessible at
  # rtsp://{host}:{serverPort}/{liveApplicationName}/{streamName} or
  # rtmp://{host}:{rtmpServerPort}/{liveApplicationName}/{streamName}
  liveApplicationName: 'live'

  # MP4 files in recordedDir will be accessible at
  # rtsp://{host}:{serverPort}/{recordedApplicationName}/{filename} or
  # rtmp://{host}:{rtmpServerPort}/{recordedApplicationName}/mp4:{filename}
  # To disable this feature, comment out the following two lines.
  recordedApplicationName: 'file'
  recordedDir: 'file'

  ### RTMP configurations ###

  # If true, the server waits for the first keyframe
  # before starting to send video/audio frames over RTMP.
  rtmpWaitForKeyFrame: false

  flv:
    # Has video?
    hasVideo: true

    # See: Adobe Flash Video File Format Specification Version 10.1 - E.4.3.1 VIDEODATA
    videocodecid: 7  # H.264

    # See: Adobe Flash Video File Format Specification Version 10.1 - E.4.2.1 AUDIODATA
    audiocodecid: 10 # AAC


  ###############################
  ### Advanced configurations ###
  ###############################

  # Period size of each audio frame. Use 1024 for picam.
  audioPeriodSize: 1024

  # HTTP keepalive timeout
  keepaliveTimeoutMs: 30000  # milliseconds

  # RTSP
  rtcpSenderReportIntervalMs: 5000  # milliseconds

  # RTMP ping timeout
  rtmpPingTimeoutMs: 5000  # milliseconds

  # RTMP session timeout
  rtmpSessionTimeoutMs: 600000  # milliseconds

  # RTMPT session timeout
  rtmptSessionTimeoutMs: 600000  # milliseconds

  # RTMP play chunk size
  rtmpPlayChunkSize: 4096  # bytes

  # Maximum number of RTMP messages being sent at once
  rtmpMessageQueueSize: 5

  # For HE-AAC streaming over RTSP:
  # If true, explicit hierarchical signaling of SBR in AudioSpecificConfig
  # will be converted to explicit backward compatible signaling.
  rtspDisableHierarchicalSBR: true

  # For HE-AAC streaming over RTMP:
  # If true, explicit hierarchical signaling of SBR in AudioSpecificConfig
  # will be converted to explicit backward compatible signaling.
  # Flash Player won't play audio if hierarchical signaling is used.
  rtmpDisableHierarchicalSBR: true

  # If true, H.264 access unit delimiter NAL units are
  # not sent to clients
  dropH264AccessUnitDelimiter: true

  debug:
    # If true, all incoming data are ignored
    dropAllData: false

  # UDP port numbers to receive incoming RTP data
  rtspVideoDataUDPListenPort   : 5004
  rtspVideoControlUDPListenPort: 5005
  rtspAudioDataUDPListenPort   : 5006
  rtspAudioControlUDPListenPort: 5007
