module.exports =
  #######################
  ## Basic configurations
  #######################

  # Server listen port
  serverPort: 80

  # Server name to be embedded in response headers
  serverName: 'node-rtsp-rtmp-server/0.1.0'

  # Video frame size
  width : 480
  height: 360

  # How many frames per second
  videoFrameRate: 30

  # Audio sample rate in Hz
  audioSampleRate: 48000

  # Video bitrate in Kbps
  videoBitrateKbps: 1000

  # Audio bitrate in Kbps
  audioBitrateKbps: 40

  # UNIX domain sockets used for receiving audio and video frames
  videoReceiverPath: '/tmp/node_rtsp_rtmp_videoReceiver'
  videoControlPath : '/tmp/node_rtsp_rtmp_videoControl'
  audioReceiverPath: '/tmp/node_rtsp_rtmp_audioReceiver'
  audioControlPath : '/tmp/node_rtsp_rtmp_audioControl'

  audioRTPServerPort : 7042  # even
  audioRTCPServerPort: 7043  # odd and contiguous
  videoRTPServerPort : 7044  # even
  videoRTCPServerPort: 7045  # odd and contiguous

  # RTMP stream name
  rtmpApplicationName: 'live'

  ##########################
  ## Advanced configurations
  ##########################

  # Period size of each audio frame. Use 1024 for picam.
  audioPeriodSize: 1024

  # See: Adobe Flash Video File Format Specification Version 10.1 - E.4.3.1 VIDEODATA
  videoCodecId: 7  # H.264

  # See: Adobe Flash Video File Format Specification Version 10.1 - E.4.2.1 AUDIODATA
  audioCodecId: 10 # AAC

  # HTTP keepalive timeout
  keepaliveTimeoutMs: 30000  # milliseconds

  # RTSP
  rtcpSenderReportIntervalMs: 5000  # milliseconds

  # RTMP ping timeout
  rtmpPingTimeoutMs: 5000  # milliseconds

  # RTMP session timeout
  rtmpSessionTimeoutMs: 60000  # milliseconds

  # RTMPT session timeout
  rtmptSessionTimeoutMs: 60000  # milliseconds

  # RTMP play chunk size
  rtmpPlayChunkSize: 4096  # bytes

  # Maximum number of RTMP messages being sent at once
  rtmpMessageQueueSize: 5

  debug:
    # Drop all incoming data
    dropAllData: false
