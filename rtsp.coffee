# RTSP/HTTP/RTMPT hybrid server
#
# RTSP spec:
#   RFC 2326  http://www.ietf.org/rfc/rfc2326.txt

# TODO: clear old sessioncookies

net = require 'net'
dgram = require 'dgram'
os = require 'os'
crypto = require 'crypto'
url = require 'url'
Sequent = require 'sequent'

rtp = require './rtp'
sdp = require './sdp'
h264 = require './h264'
aac = require './aac'
http = require './http'
avstreams = require './avstreams'
Bits = require './bits'
logger = require './logger'
config = require './config'

enabledFeatures = []
if config.enableRTSP
  enabledFeatures.push 'rtsp'
if config.enableHTTP
  enabledFeatures.push 'http'
if config.enableRTMPT
  enabledFeatures.push 'rtmpt'
TAG = enabledFeatures.join '/'

# Default server name for RTSP and HTTP responses
DEFAULT_SERVER_NAME = 'node-rtsp-rtmp-server'

# Start playing from keyframe
ENABLE_START_PLAYING_FROM_KEYFRAME = false

# Maximum single NAL unit size
SINGLE_NAL_UNIT_MAX_SIZE = 1358

DAY_NAMES = [
  'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'
]

MONTH_NAMES = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
]

# If true, RTSP requests/response will be printed to the console
DEBUG_RTSP = false
DEBUG_RTSP_HEADERS_ONLY = false

# If true, outgoing video/audio packets are printed to the console
DEBUG_OUTGOING_PACKET_DATA = false

# If true, outgoing RTCP packets (sender reports) are printed to the console
DEBUG_OUTGOING_RTCP = false

# If true, RTSP requests/responses tunneled in HTTP will be
# printed to the console
DEBUG_HTTP_TUNNEL = false

# If true, UDP transport will always be disabled and
# clients will be forced to use TCP transport.
DEBUG_DISABLE_UDP_TRANSPORT = false

# Two CRLFs
CRLF_CRLF = [ 0x0d, 0x0a, 0x0d, 0x0a ]

TIMESTAMP_ROUNDOFF = 4294967296  # 32 bits

if DEBUG_OUTGOING_PACKET_DATA
  logger.enableTag 'rtsp:out'

zeropad = (columns, num) ->
  num += ''
  while num.length < columns
    num = '0' + num
  num

pad = (digits, n) ->
  n = n + ''
  while n.length < digits
    n = '0' + n
  n

# Generate new random session ID
# NOTE: Samsung SC-02B doesn't work with some hex string
generateNewSessionID = (callback) ->
  id = ''
  for i in [0..7]
    id += parseInt(Math.random() * 9) + 1
  callback null, id

# Generate random 32 bit unsigned integer.
# Return value is intended to be used as an SSRC identifier.
generateRandom32 = ->
  str = "#{new Date().getTime()}#{process.pid}#{os.hostname()}" + \
        (1 + Math.random() * 1000000000)

  md5sum = crypto.createHash 'md5'
  md5sum.update str
  md5sum.digest()[0..3].readUInt32BE(0)

resetStreamParams = (stream) ->
  stream.rtspUploadingClient = null
  stream.videoSequenceNumber = 0
  stream.audioSequenceNumber = 0
  stream.lastVideoRTPTimestamp = null
  stream.lastAudioRTPTimestamp = null
  stream.videoRTPTimestampInterval = Math.round(90000 / stream.videoFrameRate)
  stream.audioRTPTimestampInterval = stream.audioPeriodSize

avstreams.on 'update_frame_rate', (stream, frameRate) ->
  stream.videoRTPTimestampInterval = Math.round(90000 / frameRate)

avstreams.on 'new', (stream) ->
  stream.rtspNumClients = 0
  stream.rtspClients = {}
  resetStreamParams stream

avstreams.on 'reset', (stream) ->
  resetStreamParams stream

class RTSPServer
  constructor: (opts) ->
    @httpHandler = opts.httpHandler
    @rtmpServer = opts.rtmpServer
    @rtmptCallback = opts.rtmptCallback

    @numClients = 0

    @eventListeners = {}
    @serverName = opts?.serverName ? DEFAULT_SERVER_NAME
    @port = opts?.port ? 8080
    @clients = {}
    @httpSessions = {}
    @rtspUploadingClients = {}
    @highestClientID = 0

    @rtpParser = new rtp.RTPParser

    @rtpParser.on 'h264_nal_units', (streamId, nalUnits, rtpTimestamp) =>
      stream = avstreams.get streamId
      if not stream?  # No matching stream
        logger.warn "warn: No matching stream to id #{streamId}"
        return

      if not stream.rtspUploadingClient?
        # No uploading client associated with the stream
        logger.warn "warn: No uploading client associated with the stream #{stream.id}"
        return
      sendTime = @getVideoSendTimeForUploadingRTPTimestamp stream, rtpTimestamp
      calculatedPTS = rtpTimestamp - stream.rtspUploadingClient.videoRTPStartTimestamp
      @emit 'video', stream, nalUnits, calculatedPTS, calculatedPTS

    @rtpParser.on 'aac_access_units', (streamId, accessUnits, rtpTimestamp) =>
      stream = avstreams.get streamId
      if not stream?  # No matching stream
        logger.warn "warn: No matching stream to id #{streamId}"
        return

      if not stream.rtspUploadingClient?
        # No uploading client associated with the stream
        logger.warn "warn: No uploading client associated with the stream #{stream.id}"
        return
      sendTime = @getAudioSendTimeForUploadingRTPTimestamp stream, rtpTimestamp
      calculatedPTS = Math.round (rtpTimestamp - stream.rtspUploadingClient.audioRTPStartTimestamp) * 90000 / stream.audioClockRate
      # PTS may not be monotonically increased (it may not be in decoding order)
      @emit 'audio', stream, accessUnits, calculatedPTS, calculatedPTS

  setServerName: (name) ->
    @serverName = name

  getNextVideoSequenceNumber: (stream) ->
    num = stream.videoSequenceNumber + 1
    if num > 65535
      num -= 65535
    num

  getNextAudioSequenceNumber: (stream) ->
    num = stream.audioSequenceNumber + 1
    if num > 65535
      num -= 65535
    num

  # TODO: Adjust RTP timestamp based on play start time
  getNextVideoRTPTimestamp: (stream) ->
    if stream.lastVideoRTPTimestamp?
      return stream.lastVideoRTPTimestamp + stream.videoRTPTimestampInterval
    else
      return 0

  # TODO: Adjust RTP timestamp based on play start time
  getNextAudioRTPTimestamp: (stream) ->
    if stream.lastAudioRTPTimestamp?
      return stream.lastAudioRTPTimestamp + stream.audioRTPTimestampInterval
    else
      return 0

  getVideoRTPTimestamp: (stream, time) ->
    return Math.round time * 90 % TIMESTAMP_ROUNDOFF

  getAudioRTPTimestamp: (stream, time) ->
    if not stream.audioClockRate?
      throw new Error "audioClockRate is null"
    return Math.round time * (stream.audioClockRate / 1000) % TIMESTAMP_ROUNDOFF

  getVideoSendTimeForUploadingRTPTimestamp: (stream, rtpTimestamp) ->
    videoTimestampInfo = stream.rtspUploadingClient?.uploadingTimestampInfo.video
    if videoTimestampInfo?
      rtpDiff = rtpTimestamp - videoTimestampInfo.rtpTimestamp # 90 kHz clock
      timeDiff = rtpDiff / 90
      return videoTimestampInfo.time + timeDiff
    else
      return Date.now()

  getAudioSendTimeForUploadingRTPTimestamp: (stream, rtpTimestamp) ->
    audioTimestampInfo = stream.rtspUploadingClient?.uploadingTimestampInfo.audio
    if audioTimestampInfo?
      rtpDiff = rtpTimestamp - audioTimestampInfo.rtpTimestamp
      timeDiff = rtpDiff * 1000 / stream.audioClockRate
      return audioTimestampInfo.time + timeDiff
    else
      return Date.now()

  # @public
  sendVideoData: (stream, nalUnits, pts, dts) ->
    isSPSSent = false
    isPPSSent = false
    for nalUnit, i in nalUnits
      isLastPacket = i is nalUnits.length - 1
      # detect configuration
      nalUnitType = h264.getNALUnitType nalUnit
      if config.dropH264AccessUnitDelimiter and
      (nalUnitType is h264.NAL_UNIT_TYPE_ACCESS_UNIT_DELIMITER)
        # ignore access unit delimiters
        continue
      if nalUnitType is h264.NAL_UNIT_TYPE_SPS  # 7
        isSPSSent = true
      else if nalUnitType is h264.NAL_UNIT_TYPE_PPS  # 8
        isPPSSent = true

      # If this is keyframe but SPS and PPS do not exist in the
      # same timestamp, we insert them before the keyframe.
      # TODO: Send SPS and PPS as an aggregation packet (STAP-A).
      if nalUnitType is 5  # keyframe
        # Compensate SPS/PPS if they are not included in nalUnits
        if not isSPSSent  # nal_unit_type 7
          if stream.spsNALUnit?
            @sendNALUnitOverRTSP stream, stream.spsNALUnit, pts, dts, false
            # there is a case where timestamps of two keyframes are identical
            # (i.e. nalUnits argument contains multiple keyframes)
            isSPSSent = true
          else
            logger.error "Error: SPS is not set"
        if not isPPSSent  # nal_unit_type 8
          if stream.ppsNALUnit?
            @sendNALUnitOverRTSP stream, stream.ppsNALUnit, pts, dts, false
            # there is a case where timestamps of two keyframes are identical
            # (i.e. nalUnits argument contains multiple keyframes)
            isPPSSent = true
          else
            logger.error "Error: PPS is not set"

      @sendNALUnitOverRTSP stream, nalUnit, pts, dts, isLastPacket

    return

  sendNALUnitOverRTSP: (stream, nalUnit, pts, dts, marker) ->
    if nalUnit.length > SINGLE_NAL_UNIT_MAX_SIZE
      @sendVideoPacketWithFragment stream, nalUnit, pts, marker  # TODO what about dts?
    else
      @sendVideoPacketAsSingleNALUnit stream, nalUnit, pts, marker  # TODO what about dts?

  # @public
  sendAudioData: (stream, accessUnits, pts, dts) ->
    if not stream.audioSampleRate?
      throw new Error "audio sample rate has not been detected for stream #{stream.id}"

    # timestamp: RTP timestamp in audioClockRate
    # pts: PTS in 90 kHz clock
    if stream.audioClockRate isnt 90000  # given pts is not in 90 kHz clock
      timestamp = pts * stream.audioClockRate / 90000
    else
      timestamp = pts

    rtpTimePerFrame = 1024

    if @numClients is 0
      return

    if stream.rtspNumClients is 0
      # No clients connected to the stream
      return

    frameGroups = rtp.groupAudioFrames accessUnits
    processedFrames = 0
    for group, i in frameGroups
      concatRawDataBlock = Buffer.concat group

      if ++stream.audioSequenceNumber > 65535
        stream.audioSequenceNumber -= 65535

      ts = Math.round((timestamp + rtpTimePerFrame * processedFrames) % TIMESTAMP_ROUNDOFF)
      processedFrames += group.length
      stream.lastAudioRTPTimestamp = (timestamp + rtpTimePerFrame * processedFrames) % TIMESTAMP_ROUNDOFF

      # TODO dts
      rtpData = rtp.createRTPHeader
        marker: true
        payloadType: 96
        sequenceNumber: stream.audioSequenceNumber
        timestamp: ts
        ssrc: null

      accessUnitLength = concatRawDataBlock.length

      # TODO: maximum size of AAC-hbr is 8191 octets
      # TODO: sequence number should start at a random number

      audioHeader = rtp.createAudioHeader
        accessUnits: group

      rtpData = rtpData.concat audioHeader

      for clientID, client of stream.rtspClients
        # Append the access unit (rawDataBlock)
        rtpBuffer = Buffer.concat [new Buffer(rtpData), concatRawDataBlock],
          rtp.RTP_HEADER_LEN + audioHeader.length + accessUnitLength
        if client.isPlaying
          rtp.replaceSSRCInRTP rtpBuffer, client.audioSSRC

          client.audioPacketCount++
          client.audioOctetCount += accessUnitLength
          logger.tag 'rtsp:out', "[rtsp:stream:#{stream.id}] send audio to #{client.id}: ts=#{ts} pts=#{pts}"
          if client.useTCPForAudio
            if client.useHTTP
              if client.httpClientType is 'GET'
                @sendDataByTCP client.socket, client.audioTCPDataChannel, rtpBuffer
            else
              @sendDataByTCP client.socket, client.audioTCPDataChannel, rtpBuffer
          else
            if client.clientAudioRTPPort?
              @audioRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientAudioRTPPort, client.ip, (err, bytes) ->
                if err
                  logger.error "[audioRTPSend] error: #{err.message}"
    return

  sendEOS: (stream) ->
    for clientID, client of stream.rtspClients
      logger.debug "[#{TAG}:client=#{clientID}] sending goodbye for stream #{stream.id}"
      buf = new Buffer rtp.createGoodbye
        ssrcs: [ client.videoSSRC ]
      if client.useTCPForVideo
        if client.useHTTP
          if client.httpClientType is 'GET'
            @sendDataByTCP client.socket, client.videoTCPControlChannel, buf
        else
          @sendDataByTCP client.socket, client.videoTCPControlChannel, buf
      else
        if client.clientVideoRTCPPort?
          @videoRTCPSocket.send buf, 0, buf.length, client.clientVideoRTCPPort, client.ip, (err, bytes) ->
            if err
              logger.error "[videoRTCPSend] error: #{err.message}"

      buf = new Buffer rtp.createGoodbye
        ssrcs: [ client.audioSSRC ]
      if client.useTCPForAudio
        if client.useHTTP
          if client.httpClientType is 'GET'
            @sendDataByTCP client.socket, client.audioTCPControlChannel, buf
        else
          @sendDataByTCP client.socket, client.audioTCPControlChannel, buf
      else
        if client.clientAudioRTCPPort?
          @audioRTCPSocket.send buf, 0, buf.length, client.clientAudioRTCPPort, client.ip, (err, bytes) ->
            if err
              logger.error "[audioRTCPSend] error: #{err.message}"

  dumpClients: ->
    logger.raw "[rtsp/http: #{Object.keys(@clients).length} clients]"
    for clientID, client of @clients
      logger.raw " " + client.toString()
    return

  setLivePathConsumer: (func) ->
    @livePathConsumer = func

  setAuthenticator: (func) ->
    @authenticator = func

  start: (opts, callback) ->
    serverPort = opts?.port ? @port

    @videoRTPSocket = dgram.createSocket 'udp4'
    @videoRTPSocket.bind config.videoRTPServerPort
    @videoRTCPSocket = dgram.createSocket 'udp4'
    @videoRTCPSocket.bind config.videoRTCPServerPort

    @audioRTPSocket = dgram.createSocket 'udp4'
    @audioRTPSocket.bind config.audioRTPServerPort
    @audioRTCPSocket = dgram.createSocket 'udp4'
    @audioRTCPSocket.bind config.audioRTCPServerPort

    @server = net.createServer (c) =>
      # New client is connected
      @highestClientID++
      id_str = 'c' + @highestClientID
      logger.info "[#{TAG}:client=#{id_str}] connected"
      generateNewSessionID (err, sessionID) =>
        throw err if err
        client = @clients[id_str] = new RTSPClient
          id: id_str
          sessionID: sessionID
          socket: c
          ip: c.remoteAddress
        @numClients++
        c.setKeepAlive true, 120000
        c.clientID = id_str  # TODO: Is this safe?
        c.isAuthenticated = false
        c.requestCount = 0
        c.responseCount = 0
        c.on 'close', =>
          logger.info "[#{TAG}:client=#{id_str}] disconnected"
          logger.debug "[#{TAG}:client=#{id_str}] teardown: session=#{sessionID}"
          try
            c.end()
          catch e
            logger.error "socket.end() error: #{e}"

          delete @clients[id_str]
          @numClients--
          api.leaveClient client
          @stopSendingRTCP client

          # TODO: Is this fast enough?
          for addr, _client of @rtspUploadingClients
            if _client is client
              delete @rtspUploadingClients[addr]

          @dumpClients()
        c.buf = null
        c.on 'error', (err) ->
          logger.error "Socket error (#{c.clientID}): #{err}"
          c.destroy()
        c.on 'data', (data) =>
          @handleOnData c, data

    @server.on 'error', (err) ->
      logger.error "[#{TAG}] server error: #{err.message}"

    udpVideoDataServer = dgram.createSocket 'udp4'
    udpVideoDataServer.on 'error', (err) ->
      logger.error "[#{TAG}] udp video data receiver error: #{err.message}"
      throw err
    udpVideoDataServer.on 'message', (msg, rinfo) =>
      stream = @getStreamByRTSPUDPAddress rinfo.address, rinfo.port, 'video-data'
      if stream?
        @onUploadVideoData stream, msg, rinfo
#      else
#        logger.warn "[#{TAG}] warn: received UDP video data but no existing client found: #{rinfo.address}:#{rinfo.port}"
    udpVideoDataServer.on 'listening', ->
      addr = udpVideoDataServer.address()
      logger.debug "[#{TAG}] udp video data receiver is listening on port #{addr.port}"
    udpVideoDataServer.bind config.rtspVideoDataUDPListenPort

    udpVideoControlServer = dgram.createSocket 'udp4'
    udpVideoControlServer.on 'error', (err) ->
      logger.error "[#{TAG}] udp video control receiver error: #{err.message}"
      throw err
    udpVideoControlServer.on 'message', (msg, rinfo) =>
      stream = @getStreamByRTSPUDPAddress rinfo.address, rinfo.port, 'video-control'
      if stream?
        @onUploadVideoControl stream, msg, rinfo
#      else
#        logger.warn "[#{TAG}] warn: received UDP video control data but no existing client found: #{rinfo.address}:#{rinfo.port}"
    udpVideoControlServer.on 'listening', ->
      addr = udpVideoControlServer.address()
      logger.debug "[#{TAG}] udp video control receiver is listening on port #{addr.port}"
    udpVideoControlServer.bind config.rtspVideoControlUDPListenPort

    udpAudioDataServer = dgram.createSocket 'udp4'
    udpAudioDataServer.on 'error', (err) ->
      logger.error "[#{TAG}] udp audio data receiver error: #{err.message}"
      throw err
    udpAudioDataServer.on 'message', (msg, rinfo) =>
      stream = @getStreamByRTSPUDPAddress rinfo.address, rinfo.port, 'audio-data'
      if stream?
        @onUploadAudioData stream, msg, rinfo
#      else
#        logger.warn "[#{TAG}] warn: received UDP audio data but no existing client found: #{rinfo.address}:#{rinfo.port}"
    udpAudioDataServer.on 'listening', ->
      addr = udpAudioDataServer.address()
      logger.debug "[#{TAG}] udp audio data receiver is listening on port #{addr.port}"
    udpAudioDataServer.bind config.rtspAudioDataUDPListenPort

    udpAudioControlServer = dgram.createSocket 'udp4'
    udpAudioControlServer.on 'error', (err) ->
      logger.error "[#{TAG}] udp audio control receiver error: #{err.message}"
      throw err
    udpAudioControlServer.on 'message', (msg, rinfo) =>
      stream = @getStreamByRTSPUDPAddress rinfo.address, rinfo.port, 'audio-control'
      if stream?
        @onUploadAudioControl stream, msg, rinfo
#      else
#        logger.warn "[#{TAG}] warn: received UDP audio control data but no existing client found: #{rinfo.address}:#{rinfo.port}"
    udpAudioControlServer.on 'listening', ->
      addr = udpAudioControlServer.address()
      logger.debug "[#{TAG}] udp audio control receiver is listening on port #{addr.port}"
    udpAudioControlServer.bind config.rtspAudioControlUDPListenPort

    logger.debug "[#{TAG}] starting server on port #{serverPort}"
    @server.listen serverPort, '0.0.0.0', 511, =>
      logger.info "[#{TAG}] server started on port #{serverPort}"
      callback?()

  stop: (callback) ->
    @server?.close callback

  on: (event, listener) ->
    if @eventListeners[event]?
      @eventListeners[event].push listener
    else
      @eventListeners[event] = [ listener ]
    return

  emit: (event, args...) ->
    if @eventListeners[event]?
      for listener in @eventListeners[event]
        listener args...
    return

  # rtsp://localhost:80/live/a -> live/a
  # This method returns null if no stream id is extracted from the uri
  @getStreamIdFromUri: (uri, removeDepthFromEnd=0) ->
    try
      pathname = url.parse(uri).pathname
    catch e
      return null

    if pathname? and pathname.length > 0
      # Remove leading slash
      pathname = pathname[1..]

      # Remove trailing slash
      if pathname[pathname.length-1] is '/'
        pathname = pathname[0..pathname.length-2]

      # Go up directories if removeDepthFromEnd is specified
      while removeDepthFromEnd > 0
        slashPos = pathname.lastIndexOf '/'
        if slashPos is -1
          break
        pathname = pathname[0...slashPos]
        removeDepthFromEnd--

    return pathname

  getStreamByRTSPUDPAddress: (addr, port, channelType) ->
    client = @rtspUploadingClients[addr + ':' + port]
    if client?
      return client.uploadingStream
    return null

  getStreamByUri: (uri) ->
    streamId = RTSPServer.getStreamIdFromUri uri
    if streamId?
      return avstreams.get streamId
    else
      return null

  sendVideoSenderReport: (stream, client) ->
    if not stream.timeAtVideoStart?
      return

    time = new Date().getTime()
    rtpTime = @getVideoRTPTimestamp stream, time - stream.timeAtVideoStart
    if DEBUG_OUTGOING_RTCP
      logger.info "video sender report: rtpTime=#{rtpTime} time=#{time} timeAtVideoStart=#{stream.timeAtVideoStart}"
    buf = new Buffer rtp.createSenderReport
      time: time
      rtpTime: rtpTime
      ssrc: client.videoSSRC
      packetCount: client.videoPacketCount
      octetCount: client.videoOctetCount

    if client.useTCPForVideo
      if client.useHTTP
        if client.httpClientType is 'GET'
          @sendDataByTCP client.socket, client.videoTCPControlChannel, buf
      else
        @sendDataByTCP client.socket, client.videoTCPControlChannel, buf
    else
      if client.clientVideoRTCPPort?
        @videoRTCPSocket.send buf, 0, buf.length, client.clientVideoRTCPPort, client.ip, (err, bytes) ->
          if err
            logger.error "[videoRTCPSend] error: #{err.message}"

  sendAudioSenderReport: (stream, client) ->
    if not stream.timeAtAudioStart?
      return

    time = new Date().getTime()
    rtpTime = @getAudioRTPTimestamp stream, time - stream.timeAtAudioStart
    if DEBUG_OUTGOING_RTCP
      logger.info "audio sender report: rtpTime=#{rtpTime} time=#{time} timeAtAudioStart=#{stream.timeAtAudioStart}"
    buf = new Buffer rtp.createSenderReport
      time: time
      rtpTime: rtpTime
      ssrc: client.audioSSRC
      packetCount: client.audioPacketCount
      octetCount: client.audioOctetCount

    if client.useTCPForAudio
      if client.useHTTP
        if client.httpClientType is 'GET'
          @sendDataByTCP client.socket, client.audioTCPControlChannel, buf
      else
        @sendDataByTCP client.socket, client.audioTCPControlChannel, buf
    else
      if client.clientAudioRTCPPort?
        @audioRTCPSocket.send buf, 0, buf.length, client.clientAudioRTCPPort, client.ip, (err, bytes) ->
          if err
            logger.error "[audioRTCPSend] error: #{err.message}"

  stopSendingRTCP: (client) ->
    if client.timeoutID?
      clearTimeout client.timeoutID
      client.timeoutID = null

  # Send RTCP sender report packets for audio and video streams
  sendSenderReports: (stream, client) ->
    if not @clients[client.id]?  # client socket is already closed
      @stopSendingRTCP client
      return

    if stream.isAudioStarted
      @sendAudioSenderReport stream, client
    if stream.isVideoStarted
      @sendVideoSenderReport stream, client

    client.timeoutID = setTimeout =>
      @sendSenderReports stream, client
    , config.rtcpSenderReportIntervalMs

  startSendingRTCP: (stream, client) ->
    @stopSendingRTCP client

    @sendSenderReports stream, client

  onReceiveVideoRTCP: (buf) ->
    # TODO: handle BYE message

  onReceiveAudioRTCP: (buf) ->
    # TODO: handle BYE message

  sendDataByTCP: (socket, channel, rtpBuffer) ->
    rtpLen = rtpBuffer.length
    tcpHeader = api.createInterleavedHeader
      channel: channel
      payloadLength: rtpLen
    socket.write Buffer.concat [tcpHeader, rtpBuffer],
      api.INTERLEAVED_HEADER_LEN + rtpBuffer.length

  # Process incoming RTSP data that is tunneled in HTTP POST
  handleTunneledPOSTData: (client, data='', callback) ->
    # Concatenate outstanding base64 string
    if client.postBase64Buf?
      base64Buf = client.postBase64Buf + data
    else
      base64Buf = data

    if base64Buf.length > 0
      # Length of base64-encoded string is always divisible by 4
      div = base64Buf.length % 4
      if div isnt 0
        # extract last div characters
        client.postBase64Buf = base64Buf[-div..]
        base64Buf = base64Buf[0...-div]
      else
        client.postBase64Buf = null

      # Decode base64-encoded data
      decodedBuf = new Buffer(base64Buf, 'base64')
    else  # no base64 input
      decodedBuf = new Buffer []

    # Concatenate outstanding buffer
    if client.postBuf?
      postData = Buffer.concat [client.postBuf, decodedBuf]
      client.postBuf = null
    else
      postData = decodedBuf

    if postData.length is 0  # no data to process
      callback? null
      return

    # Will be called before return
    processRemainingBuffer = =>
      if client.postBase64Buf? or client.postBuf?
        @handleTunneledPOSTData client, '', callback
      else
        callback? null
      return

    # TODO: Do we have to interpret interleaved data here?
    if config.enableRTSP and (postData[0] is api.INTERLEAVED_SIGN)  # interleaved data
      interleavedData = api.getInterleavedData postData
      if not interleavedData?
        # not enough buffer for an interleaved data
        client.postBuf = postData
        callback? null
        return
      # At this point, postData has enough buffer for this interleaved data.

      @onInterleavedRTPPacketFromClient client, interleavedData

      if postData.length > interleavedData.totalLength
        client.postBuf = client.buf[interleavedData.totalLength..]

      processRemainingBuffer()
    else
      delimiterPos = Bits.searchBytesInArray postData, CRLF_CRLF
      if delimiterPos is -1  # not found (not enough buffer)
        client.postBuf = postData
        callback? null
        return

      decodedRequest = postData[0...delimiterPos].toString 'utf8'
      remainingPostData = postData[delimiterPos+CRLF_CRLF.length..]
      req = http.parseRequest decodedRequest
      if not req?  # parse error
        logger.error "Unable to parse request: #{decodedRequest}"
        callback? new Error "malformed request"
        return

      if req.headers['content-length']?
        req.contentLength = parseInt req.headers['content-length']
        if remainingPostData.length < req.contentLength
          # not enough buffer for the body
          client.postBuf = postData
          callback? null
          return
        if remainingPostData.length > req.contentLength
          req.rawbody = remainingPostData[0...req.contentLength]
          client.postBuf = remainingPostData[req.contentLength..]
        else # remainingPostData.length == req.contentLength
          req.rawbody = remainingPostData
      else if remainingPostData.length > 0
        client.postBuf = remainingPostData

      if DEBUG_HTTP_TUNNEL
        logger.info "===request (HTTP tunneled/decoded)==="
        process.stdout.write decodedRequest
        logger.info "============="
      @respond client.socket, req, (err, output) ->
        if err
          logger.error "[respond] Error: #{err}"
          callback? err
          return
        if output?
          if DEBUG_HTTP_TUNNEL
            logger.info "===response (HTTP tunneled)==="
            process.stdout.write output
            logger.info "============="
          client.getClient.socket.write output
        else
          if DEBUG_HTTP_TUNNEL
            logger.info "===empty response (HTTP tunneled)==="
        processRemainingBuffer()

#  cancelTimeout: (socket) ->
#    if socket.timeoutTimer?
#      clearTimeout socket.timeoutTimer
#
#  scheduleTimeout: (socket) ->
#    @cancelTimeout socket
#    socket.scheduledTimeoutTime = Date.now() + config.keepaliveTimeoutMs
#    socket.timeoutTimer = setTimeout =>
#      if not clients[socket.clientID]?
#        return
#      if Date.now() < socket.scheduledTimeoutTime
#        return
#      logger.info "keepalive timeout: #{socket.clientID}"
#      @teardownClient socket.clientID
#    , config.keepaliveTimeoutMs

  # Called when the server received an interleaved RTP packet
  onInterleavedRTPPacketFromClient: (client, interleavedData) ->
    if client.uploadingStream?
      stream = client.uploadingStream
      # TODO: Support multiple streams
      senderInfo =
        address: null
        port: null
      switch interleavedData.channel
        when stream.rtspUploadingClient.uploadingChannels.videoData
          @onUploadVideoData stream, interleavedData.data, senderInfo
        when stream.rtspUploadingClient.uploadingChannels.videoControl
          @onUploadVideoControl stream, interleavedData.data, senderInfo
        when stream.rtspUploadingClient.uploadingChannels.audioData
          @onUploadAudioData stream, interleavedData.data, senderInfo
        when stream.rtspUploadingClient.uploadingChannels.audioControl
          @onUploadAudioControl stream, interleavedData.data, senderInfo
        else
          logger.error "Error: unknown interleaved channel: #{interleavedData.channel}"
    # Discard incoming RTP packets if the client is not uploading streams

  # Called when new data comes from TCP connection
  handleOnData: (c, data) ->
    id_str = c.clientID
    if not @clients[id_str]?  # client socket is already closed
      logger.error "error: invalid client ID: #{id_str}"
      return

    client = @clients[id_str]
    if client.isSendingPOST
      @handleTunneledPOSTData client, data.toString 'utf8'
      return
    if c.buf?
      c.buf = Buffer.concat [c.buf, data], c.buf.length + data.length
    else
      c.buf = data
    if c.buf[0] is api.INTERLEAVED_SIGN # dollar sign '$' (RFC 2326 - 10.12)
      interleavedData = api.getInterleavedData c.buf
      if not interleavedData?
        # not enough buffer for an interleaved data
        return

      # At this point, c.buf has enough buffer for this interleaved data.
      if c.buf.length > interleavedData.totalLength
        c.buf = c.buf[interleavedData.totalLength..]
      else
        c.buf = null

      @onInterleavedRTPPacketFromClient client, interleavedData

      if c.buf?
        # Process the remaining buffer
        # TODO: Is there more efficient way to do this?
        buf = c.buf
        c.buf = null
        @handleOnData c, buf

      return
    if c.ongoingRequest?
      req = c.ongoingRequest
      req.rawbody = Buffer.concat [req.rawbody, data], req.rawbody.length + data.length
      if req.rawbody.length < req.contentLength
        return
      req.socket = c
      if req.rawbody.length > req.contentLength
        c.buf = req.rawbody[req.contentLength..]
        req.rawbody = req.rawbody[0...req.contentLength]
      else
        c.buf = null
      req.body = req.rawbody.toString 'utf8'
      if DEBUG_RTSP
        logger.info "===RTSP/HTTP request (cont) from #{id_str}==="
        if DEBUG_RTSP_HEADERS_ONLY
          logger.info "(redacted)"
        else
          process.stdout.write data.toString 'utf8'
        logger.info "=================="
    else
      bufString = c.buf.toString 'utf8'
      if bufString.indexOf('\r\n\r\n') is -1
        return
      if DEBUG_RTSP
        logger.info "===RTSP/HTTP request from #{id_str}==="
        if DEBUG_RTSP_HEADERS_ONLY
          process.stdout.write bufString.replace(/\r\n\r\n[\s\S]*/, '\n')
        else
          process.stdout.write bufString
        logger.info "=================="
      req = http.parseRequest bufString
      if not req?
        logger.error "Unable to parse request: #{bufString}"
        c.buf = null
        return
      req.rawbody = c.buf[req.headerBytes+4..]
      req.socket = c
      if req.headers['content-length']?
        if req.headers['content-type'] is 'application/x-rtsp-tunnelled'
          # If HTTP tunneling is used, we have to ignore content-length.
          req.contentLength = 0
        else
          req.contentLength = parseInt req.headers['content-length']
        if req.rawbody.length < req.contentLength
          c.ongoingRequest = req
          return
        if req.rawbody.length > req.contentLength
          c.buf = req.rawbody[req.contentLength..]
          req.rawbody = req.rawbody[0...req.contentLength]
        else
          c.buf = null
      else
        if req.rawbody.length > 0
          c.buf = req.rawbody
        else
          c.buf = null
    c.ongoingRequest = null
    @respond c, req, (err, output, resultOpts) =>
      if err
        logger.error "[respond] Error: #{err}"
        return
      if output?
        # Write the response
        if DEBUG_RTSP
          logger.info "===RTSP/HTTP response to #{id_str}==="
        if output instanceof Array
          for out, i in output
            if DEBUG_RTSP
              logger.info out
            c.write out
        else
          if DEBUG_RTSP
            if DEBUG_RTSP_HEADERS_ONLY
              delimPos = Bits.searchBytesInArray output, [ 0x0d, 0x0a, 0x0d, 0x0a ]
              if delimPos isnt -1
                headerBytes = output[0..delimPos+1]
              else
                headerBytes = output
              process.stdout.write headerBytes
            else
              process.stdout.write output
          c.write output
        if DEBUG_RTSP
          logger.info "==================="
      else
        if DEBUG_RTSP
          logger.info "===RTSP/HTTP empty response to #{id_str}==="
      if resultOpts?.close
        # Half-close the socket
        c.end()
      if c.buf?
        # Process the remaining buffer
        buf = c.buf
        c.buf = null
        @handleOnData c, buf

  sendVideoPacketWithFragment: (stream, nalUnit, timestamp, marker=true) ->
    ts = timestamp % TIMESTAMP_ROUNDOFF
    stream.lastVideoRTPTimestamp = ts

    if @numClients is 0
      return

    if stream.rtspNumClients is 0
      # No clients connected to the stream
      return

    nalUnitType = nalUnit[0] & 0x1f
    isKeyFrame = nalUnitType is 5
    nal_ref_idc = nalUnit[0] & 0b01100000  # skip ">> 5" operation

    nalUnit = nalUnit.slice 1

    fragmentNumber = 0
    # We subtract 1 from SINGLE_NAL_UNIT_MAX_SIZE in order to
    # prevent nalUnit from not being fragmented when the length of
    # original nalUnit is equal to SINGLE_NAL_UNIT_MAX_SIZE
    while nalUnit.length > SINGLE_NAL_UNIT_MAX_SIZE - 1
      if ++stream.videoSequenceNumber > 65535
        stream.videoSequenceNumber -= 65535

      fragmentNumber++
      thisNalUnit = nalUnit.slice 0, SINGLE_NAL_UNIT_MAX_SIZE - 1
      nalUnit = nalUnit.slice SINGLE_NAL_UNIT_MAX_SIZE - 1

      # TODO: sequence number should start at a random number
      rtpData = rtp.createRTPHeader
        marker: false
        payloadType: 97
        sequenceNumber: stream.videoSequenceNumber
        timestamp: ts
        ssrc: null

      rtpData = rtpData.concat rtp.createFragmentationUnitHeader
        nal_ref_idc: nal_ref_idc
        nal_unit_type: nalUnitType
        isStart: fragmentNumber is 1
        isEnd: false

      # Append NAL unit
      thisNalUnitLen = thisNalUnit.length

      for clientID, client of stream.rtspClients
        if client.isWaitingForKeyFrame and isKeyFrame
          client.isPlaying = true
          client.isWaitingForKeyFrame = false

        if client.isPlaying
          rtpBuffer = Buffer.concat [new Buffer(rtpData), thisNalUnit],
            rtp.RTP_HEADER_LEN + 2 + thisNalUnitLen
          rtp.replaceSSRCInRTP rtpBuffer, client.videoSSRC

          logger.tag 'rtsp:out', "[rtsp:stream:#{stream.id}] send video to #{client.id}: fragment n=#{fragmentNumber} timestamp=#{ts} bytes=#{rtpBuffer.length} marker=false keyframe=#{isKeyFrame}"

          client.videoPacketCount++
          client.videoOctetCount += thisNalUnitLen
          if client.useTCPForVideo
            if client.useHTTP
              if client.httpClientType is 'GET'
                @sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
            else
              @sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
          else
            if client.clientVideoRTPPort?
              @videoRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientVideoRTPPort, client.ip, (err, bytes) ->
                if err
                  logger.error "[videoRTPSend] error: #{err.message}"

    # last packet
    if ++stream.videoSequenceNumber > 65535
      stream.videoSequenceNumber -= 65535

    # TODO: sequence number should be started from a random number
    rtpData = rtp.createRTPHeader
      marker: marker
      payloadType: 97
      sequenceNumber: stream.videoSequenceNumber
      timestamp: ts
      ssrc: null

    rtpData = rtpData.concat rtp.createFragmentationUnitHeader
      nal_ref_idc: nal_ref_idc
      nal_unit_type: nalUnitType
      isStart: false
      isEnd: true

    nalUnitLen = nalUnit.length

    for clientID, client of stream.rtspClients
      if client.isWaitingForKeyFrame and isKeyFrame
        client.isPlaying = true
        client.isWaitingForKeyFrame = false

      if client.isPlaying
        rtpBuffer = Buffer.concat [new Buffer(rtpData), nalUnit],
          rtp.RTP_HEADER_LEN + 2 + nalUnitLen
        rtp.replaceSSRCInRTP rtpBuffer, client.videoSSRC

        client.videoPacketCount++
        client.videoOctetCount += nalUnitLen
        logger.tag 'rtsp:out', "[rtsp:stream:#{stream.id}] send video to #{client.id}: fragment-last n=#{fragmentNumber+1} timestamp=#{ts} bytes=#{rtpBuffer.length} marker=#{marker} keyframe=#{isKeyFrame}"
        if client.useTCPForVideo
          if client.useHTTP
            if client.httpClientType is 'GET'
              @sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
          else
            @sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
        else
          if client.clientVideoRTPPort?
            @videoRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientVideoRTPPort, client.ip, (err, bytes) ->
              if err
                logger.error "[videoRTPSend] error: #{err.message}"
    return

  sendVideoPacketAsSingleNALUnit: (stream, nalUnit, timestamp, marker=true) ->
    if ++stream.videoSequenceNumber > 65535
      stream.videoSequenceNumber -= 65535

    ts = timestamp % TIMESTAMP_ROUNDOFF
    stream.lastVideoRTPTimestamp = ts

    nalUnitType = nalUnit[0] & 0x1f

    if @numClients is 0
      return

    if stream.rtspNumClients is 0
      # No clients connected to the stream
      return

    isKeyFrame = nalUnitType is 5

    # TODO: sequence number should be started from a random number
    rtpHeader = rtp.createRTPHeader
      marker: marker
      payloadType: 97
      sequenceNumber: stream.videoSequenceNumber
      timestamp: ts
      ssrc: null

    nalUnitLen = nalUnit.length

    for clientID, client of stream.rtspClients
      if client.isWaitingForKeyFrame and isKeyFrame
        client.isPlaying = true
        client.isWaitingForKeyFrame = false

      if client.isPlaying
        rtpBuffer = Buffer.concat [new Buffer(rtpHeader), nalUnit],
          rtp.RTP_HEADER_LEN + nalUnitLen
        rtp.replaceSSRCInRTP rtpBuffer, client.videoSSRC

        client.videoPacketCount++
        client.videoOctetCount += nalUnitLen
        logger.tag 'rtsp:out', "[rtsp:stream:#{stream.id}] send video to #{client.id}: single timestamp=#{timestamp} keyframe=#{isKeyFrame}"
        if client.useTCPForVideo
          if client.useHTTP
            if client.httpClientType is 'GET'
              @sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
          else
            @sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
        else
          if client.clientVideoRTPPort?
            @videoRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientVideoRTPPort, client.ip, (err, bytes) ->
              if err
                logger.error "[videoRTPSend] error: #{err.message}"
    return

  @getISO8601DateString: ->
    d = new Date
    str = "#{d.getUTCFullYear()}-#{pad 2, d.getUTCMonth()+1}-#{pad 2, d.getUTCDate()}T" + \
          "#{pad 2, d.getUTCHours()}:#{pad 2, d.getUTCMinutes()}:#{pad 2, d.getUTCSeconds()}." + \
          "#{pad 4, d.getUTCMilliseconds()}Z"
    str

  # @return callback(err, isAuthenticated)
  authenticate: (req, callback) ->
    if not @authenticator?
      return callback null, true

    if (match = /^Basic (\S+)/.exec req.headers.authorization)?
      token = match[1]
      decodedToken = Buffer.from(token, 'base64').toString('utf8')
      if (match = /^(.*?):(.*)/.exec decodedToken)?
        username = match[1]
        password = match[2]
        return @authenticator username, password, callback
    callback null, false

  consumePathname: (uri, callback) ->
    if @livePathConsumer?
      @livePathConsumer uri, callback
    else
      pathname = url.parse(uri).pathname[1..]

      # TODO: Implement authentication yourself
      authSuccess = true

      if authSuccess
        callback null
      else
        callback new Error 'Invalid access'

  respondWithUnsupportedTransport: (callback, headers) ->
    res = 'RTSP/1.0 461 Unsupported Transport\n'
    if headers?
      for name, value of headers
        res += "#{name}: #{value}\n"
    res += '\n'
    callback null, res.replace /\n/g, '\r\n'

  notFound: (protocol, opts, callback) ->
    res = """
    #{protocol}/1.0 404 Not Found
    Content-Length: 9
    Content-Type: text/plain

    """
    if opts?.keepalive
      res += "Connection: keep-alive\n"
    else
      res += "Connection: close\n"
    res += """

    Not Found
    """
    callback null, res.replace /\n/g, "\r\n"

  respondWithServerError: (req, protocol, callback) ->
    if not protocol?
      protocol = 'RTSP'
    res = """
    #{protocol}/1.0 500 Internal Server Error
    Date: #{api.getDateHeader()}
    Content-Length: 21
    Content-Type: text/plain

    Internal Server Error
    """.replace /\n/g, "\r\n"
    callback null, res,
      close: (protocol is 'HTTP') and (req.headers.connection?.toLowerCase() isnt 'keep-alive')

  respondWithNotFound: (req, protocol, callback) ->
    if not protocol?
      protocol = 'RTSP'
    res = """
    #{protocol}/1.0 404 Not Found
    Date: #{api.getDateHeader()}
    Content-Length: 9
    Content-Type: text/plain

    Not Found
    """.replace /\n/g, "\r\n"
    callback null, res,
      close: (protocol is 'HTTP') and (req.headers.connection?.toLowerCase() isnt 'keep-alive')

  respondWithUnauthorized: (req, protocol, callback) ->
    if not protocol?
      protocol = 'RTSP'
    res = """
    #{protocol}/1.0 401 Unauthorized
    Date: #{api.getDateHeader()}
    Content-Length: 12
    Content-Type: text/plain
    WWW-Authenticate: Basic realm="Restricted"

    Unauthorized
    """.replace /\n/g, "\r\n"
    callback null, res,
      close: (protocol is 'HTTP') and (req.headers.connection?.toLowerCase() isnt 'keep-alive')

  respondOptions: (socket, req, callback) ->
    res = """
    RTSP/1.0 200 OK
    CSeq: #{req.headers.cseq ? 0}
    Public: DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE, ANNOUNCE, RECORD


    """.replace /\n/g, "\r\n"
    callback null, res

  respondPost: (socket, req, callback) ->
    client = @clients[socket.clientID]
    pathname = url.parse(req.uri).pathname
    if config.enableRTMPT and /^\/(?:fcs|open|idle|send|close)\//.test pathname
      if not client.clientType?
        client.clientType = 'rtmpt'
        @dumpClients()
      if @rtmptCallback?
        @rtmptCallback req, (err, output) =>
          if err
            logger.error "[rtmpt] Error: #{err}"
            @respondWithNotFound req, 'HTTP', callback
          else
            callback err, output
      else
        @respondWithNotFound req, 'HTTP', callback
    else if config.enableRTSP
      # TODO: POST/GET connections may be re-initialized
      # Incoming channel
      if not @httpSessions[req.headers['x-sessioncookie']]?
        if @httpHandler?
          @respondWithNotFound req, 'HTTP', callback
        else
          # Request cannot be handled; close the connection
          callback null, null,
            close: true
        return
      socket.isAuthenticated = true
      client.sessionCookie = req.headers['x-sessioncookie']
      @httpSessions[client.sessionCookie].post = client
      getClient = @httpSessions[client.sessionCookie].get
      # Make circular reference
      getClient.postClient = client
      client.getClient = getClient
      client.useHTTP = true
      client.httpClientType = 'POST'
      client.isSendingPOST = true

      if req.body?
        @handleTunneledPOSTData client, req.body

      # There's no response from the server
    else if @httpHandler?
      @httpHandler.handlePath pathname, req, (err, output) ->
        callback err, output,
          close: req.headers.connection?.toLowerCase() isnt 'keep-alive'
    else
      # Request cannot be handled; close the connection
      callback null, null,
        close: true
    return

  respondGet: (socket, req, callback) ->
    liveRegex = new RegExp("^/#{config.liveApplicationName}/(.*)$")
    recordedRegex = new RegExp("^/#{config.recordedApplicationName}/(.*)$")
    client = @clients[socket.clientID]
    pathname = url.parse(req.uri).pathname
    if config.enableRTSP and (match = liveRegex.exec req.uri)?
      # Outgoing channel
      @consumePathname req.uri, (err) =>
        if err
          logger.warn "Failed to consume pathname: #{err}"
          @respondWithNotFound req, 'HTTP', callback
          return
        @authenticate req, (err, ok) =>
          if err
            logger.error "[#{TAG}:client=#{socket.clientID}] authenticate() error: #{err.message}"
            @respondWithServerError req, req.protocolName, callback
            return
          if not ok
            logger.debug "[#{TAG}:client=#{socket.clientID}] authentication failed"
            @respondWithUnauthorized req, req.protocolName, callback
            return
          client.sessionCookie = req.headers['x-sessioncookie']
          client.useHTTP = true
          client.httpClientType = 'GET'
          if @httpSessions[client.sessionCookie]?
            postClient = @httpSessions[client.sessionCookie].post
            if postClient?
              postClient.getClient = client
              client.postClient = postClient
          else
            @httpSessions[client.sessionCookie] = {}
          @httpSessions[client.sessionCookie].get = client
          socket.isAuthenticated = true
          res = """
          HTTP/1.0 200 OK
          Server: #{@serverName}
          Connection: close
          Date: #{api.getDateHeader()}
          Cache-Control: no-store
          Pragma: no-cache
          Content-Type: application/x-rtsp-tunnelled


          """.replace /\n/g, "\r\n"

          # Do not close the connection
          callback null, res
    else if config.enableRTSP and (match = recordedRegex.exec req.uri)?
      # Outgoing channel
      @consumePathname req.uri, (err) =>
        if err
          logger.warn "Failed to consume pathname: #{err}"
          @respondWithNotFound req, 'HTTP', callback
          return
        @authenticate req, (err, ok) =>
          if err
            logger.error "[#{TAG}:client=#{socket.clientID}] authenticate() error: #{err.message}"
            @respondWithServerError req, req.protocolName, callback
            return
          if not ok
            logger.debug "[#{TAG}:client=#{socket.clientID}] authentication failed"
            @respondWithUnauthorized req, req.protocolName, callback
            return
          client.sessionCookie = req.headers['x-sessioncookie']
          client.useHTTP = true
          client.httpClientType = 'GET'
          if @httpSessions[client.sessionCookie]?
            postClient = @httpSessions[client.sessionCookie].post
            if postClient?
              postClient.getClient = client
              client.postClient = postClient
          else
            @httpSessions[client.sessionCookie] = {}
          @httpSessions[client.sessionCookie].get = client
          socket.isAuthenticated = true
          res = """
          HTTP/1.0 200 OK
          Server: #{@serverName}
          Connection: close
          Date: #{api.getDateHeader()}
          Cache-Control: no-store
          Pragma: no-cache
          Content-Type: application/x-rtsp-tunnelled


          """.replace /\n/g, "\r\n"

          # Do not close the connection
          callback null, res
    else if @httpHandler?
      @httpHandler.handlePath pathname, req, (err, output) ->
        callback err, output,
          close: req.headers.connection?.toLowerCase() isnt 'keep-alive'
    else
      # Request cannot be handled; close the connection
      callback null, null,
        close: true
    return

  respondDescribe: (socket, req, callback) ->
    client = @clients[socket.clientID]
    @consumePathname req.uri, (err) =>
      if err
        @respondWithNotFound req, 'RTSP', callback
        return
      @authenticate req, (err, ok) =>
        if err
          logger.error "[#{TAG}:client=#{socket.clientID}] authenticate() error: #{err.message}"
          @respondWithServerError req, req.protocolName, callback
          return
        if not ok
          logger.debug "[#{TAG}:client=#{socket.clientID}] authentication failed"
          @respondWithUnauthorized req, req.protocolName, callback
          return
        socket.isAuthenticated = true
        client.bandwidth = req.headers.bandwidth

        streamId = RTSPServer.getStreamIdFromUri req.uri
        stream = null
        if streamId?
          stream = avstreams.get streamId

        client.stream = stream

        if not stream?
          logger.info "[#{TAG}:client=#{client.id}] requested stream not found: #{streamId}"
          @respondWithNotFound req, 'RTSP', callback
          return

        sdpData =
          username      : '-'
          sessionID     : client.sessionID
          sessionVersion: client.sessionID
          addressType   : 'IP4'
          unicastAddress: api.getMeaningfulIPTo socket

        if stream.isAudioStarted
          sdpData.hasAudio          = true
          sdpData.audioPayloadType  = 96
          sdpData.audioEncodingName = 'mpeg4-generic'
          sdpData.audioClockRate    = stream.audioClockRate
          sdpData.audioChannels     = stream.audioChannels
          sdpData.audioSampleRate   = stream.audioSampleRate
          sdpData.audioObjectType   = stream.audioObjectType

          ascInfo = stream.audioASCInfo
          # Check whether explicit hierarchical signaling of SBR is used
          if ascInfo?.explicitHierarchicalSBR and config.rtspDisableHierarchicalSBR
            logger.debug "[#{TAG}:client=#{client.id}] converting hierarchical signaling of SBR" +
              " (AudioSpecificConfig=0x#{stream.audioSpecificConfig.toString 'hex'})" +
              " to backward compatible signaling"
            sdpData.audioSpecificConfig = new Buffer aac.createAudioSpecificConfig ascInfo
          else if stream.audioSpecificConfig?
            sdpData.audioSpecificConfig = stream.audioSpecificConfig
          else
            # no AudioSpecificConfig available
            sdpData.audioSpecificConfig = new Buffer aac.createAudioSpecificConfig
              audioObjectType: stream.audioObjectType
              samplingFrequency: stream.audioSampleRate
              channels: stream.audioChannels
              frameLength: 1024  # TODO: How to detect 960?
          logger.debug "[#{TAG}:client=#{client.id}] sending AudioSpecificConfig: 0x#{sdpData.audioSpecificConfig.toString 'hex'}"

        if stream.isVideoStarted
          sdpData.hasVideo                = true
          sdpData.videoPayloadType        = 97
          sdpData.videoEncodingName       = 'H264'  # must be H264
          sdpData.videoClockRate          = 90000  # must be 90000
          sdpData.videoProfileLevelId     = stream.videoProfileLevelId
          if stream.spropParameterSets isnt ''
            sdpData.videoSpropParameterSets = stream.spropParameterSets
          sdpData.videoHeight             = stream.videoHeight
          sdpData.videoWidth              = stream.videoWidth
          sdpData.videoFrameRate          = stream.videoFrameRate.toFixed 1

        if stream.isRecorded()
          sdpData.durationSeconds = stream.durationSeconds

        try
          body = sdp.createSDP sdpData
        catch e
          logger.error "error: Unable to create SDP: #{e}"
          callback new Error 'Unable to create SDP'
          return

        if /^HTTP\//.test req.protocol
          res = 'HTTP/1.0 200 OK\n'
        else
          res = 'RTSP/1.0 200 OK\n'
        if req.headers.cseq?
          res += "CSeq: #{req.headers.cseq}\n"
        dateHeader = api.getDateHeader()
        res += """
        Content-Base: #{req.uri}/
        Content-Length: #{body.length}
        Content-Type: application/sdp
        Date: #{dateHeader}
        Expires: #{dateHeader}
        Session: #{client.sessionID};timeout=60
        Server: #{@serverName}
        Cache-Control: no-cache


        """

        callback null, res.replace(/\n/g, "\r\n") + body

  respondSetup: (socket, req, callback) ->
    client = @clients[socket.clientID]
    if not socket.isAuthenticated
      @respondWithNotFound req, 'RTSP', callback
      return
    serverPort = null
    track = null

    if DEBUG_DISABLE_UDP_TRANSPORT and
    (not /\bTCP\b/.test req.headers.transport)
      # Disable UDP transport and force the client to switch to TCP transport
      logger.info "Unsupported transport: UDP is disabled"
      @respondWithUnsupportedTransport callback, {CSeq: req.headers.cseq}
      return

    client.mode = 'PLAY'
    if (match = /;mode=([^;]*)/.exec req.headers.transport)?
      client.mode = match[1].toUpperCase()  # PLAY or RECORD

    if client.mode is 'RECORD'
      sdpInfo = client.announceSDPInfo
      if (match = /\/([^/]+)$/.exec req.uri)?
        setupStreamId = match[1]  # e.g. "streamid=0"
        mediaType = null
        for media in sdpInfo.media
          if media.attributes?.control is setupStreamId
            mediaType = media.media
            break
        if not mediaType?
          throw new Error "streamid not found: #{setupStreamId}"
      else
        throw new Error "Unknown URI: #{req.uri}"

      streamId = RTSPServer.getStreamIdFromUri req.uri, 1
      stream = avstreams.get streamId
      if not stream?
        logger.warn "warning: SETUP specified non-existent stream: #{streamId}"
        logger.warn "         Stream has to be created by ANNOUNCE method."
        stream = avstreams.create streamId
        stream.type = avstreams.STREAM_TYPE_LIVE
      if not stream.rtspUploadingClient?
        stream.rtspUploadingClient = {}
      if not stream.rtspUploadingClient.uploadingChannels?
        stream.rtspUploadingClient.uploadingChannels = {}
      if (match = /;interleaved=(\d)-(\d)/.exec req.headers.transport)?
        if not client.clientType?
          client.clientType = 'publish-tcp'
          @dumpClients()
        if mediaType is 'video'
          stream.rtspUploadingClient.uploadingChannels.videoData = parseInt match[1]
          stream.rtspUploadingClient.uploadingChannels.videoControl = parseInt match[2]
        else  # audio
          stream.rtspUploadingClient.uploadingChannels.audioData = parseInt match[1]
          stream.rtspUploadingClient.uploadingChannels.audioControl = parseInt match[2]
        # interleaved mode (use current connection)
        transportHeader = req.headers.transport.replace(/mode=[^;]*/, '')
      else
        if not client.clientType?
          client.clientType = 'publish-udp'
          @dumpClients()
        if mediaType is 'video'
          [dataPort, controlPort] = [config.rtspVideoDataUDPListenPort, config.rtspVideoControlUDPListenPort]
          if (match = /;client_port=(\d+)-(\d+)/.exec req.headers.transport)?
            logger.debug "registering video rtspUploadingClient #{client.ip}:#{parseInt(match[1])}"
            logger.debug "registering video rtspUploadingClient #{client.ip}:#{parseInt(match[2])}"
            @rtspUploadingClients[client.ip + ':' + parseInt(match[1])] = client
            @rtspUploadingClients[client.ip + ':' + parseInt(match[2])] = client
        else  # audio
          [dataPort, controlPort] = [config.rtspAudioDataUDPListenPort, config.rtspAudioControlUDPListenPort]
          if (match = /;client_port=(\d+)-(\d+)/.exec req.headers.transport)?
            logger.debug "registering audio rtspUploadingClient #{client.ip}:#{parseInt(match[1])}"
            logger.debug "registering audio rtspUploadingClient #{client.ip}:#{parseInt(match[2])}"
            @rtspUploadingClients[client.ip + ':' + parseInt(match[1])] = client
            @rtspUploadingClients[client.ip + ':' + parseInt(match[2])] = client

        # client will send packets to "source" address which is specified here
        transportHeader = req.headers.transport.replace(/mode=[^;]*/, '') +
#                          "source=#{api.getMeaningfulIPTo socket};" +
                          "server_port=#{dataPort}-#{controlPort}"
      dateHeader = api.getDateHeader()
      res = """
      RTSP/1.0 200 OK
      Date: #{dateHeader}
      Expires: #{dateHeader}
      Transport: #{transportHeader}
      Session: #{client.sessionID};timeout=60
      CSeq: #{req.headers.cseq}
      Server: #{@serverName}
      Cache-Control: no-cache


      """.replace /\n/g, "\r\n"
      callback null, res
    else  # PLAY mode
      if /trackID=1\/?$/.test req.uri  # audio
        track = 'audio'
        if client.useHTTP
          ssrc = client.getClient.audioSSRC
        else
          ssrc = client.audioSSRC
        serverPort = "#{config.audioRTPServerPort}-#{config.audioRTCPServerPort}"
        if (match = /;client_port=(\d+)-(\d+)/.exec req.headers.transport)?
          client.clientAudioRTPPort = parseInt match[1]
          client.clientAudioRTCPPort = parseInt match[2]
      else  # video
        track = 'video'
        if client.useHTTP
          ssrc = client.getClient.videoSSRC
        else
          ssrc = client.videoSSRC
        serverPort = "#{config.videoRTPServerPort}-#{config.videoRTCPServerPort}"
        if (match = /;client_port=(\d+)-(\d+)/.exec req.headers.transport)?
          client.clientVideoRTPPort = parseInt match[1]
          client.clientVideoRTCPPort = parseInt match[2]

      if /\bTCP\b/.test req.headers.transport
        useTCPTransport = true
        if (match = /;interleaved=(\d+)-(\d+)/.exec req.headers.transport)?
          ch1 = parseInt match[1]
          ch2 = parseInt match[2]
          # even channel number is used for data, odd number is for control
          if ch1 % 2 is 0
            [data_ch, control_ch] = [ch1, ch2]
          else
            [data_ch, control_ch] = [ch2, ch1]
        else
          if track is 'audio'
            data_ch = 0
            control_ch = 1
          else
            data_ch = 2
            control_ch = 3
        if track is 'video'
          if client.useHTTP
            target = client.getClient
          else
            target = client
          target.videoTCPDataChannel = data_ch
          target.videoTCPControlChannel = control_ch
          target.useTCPForVideo = true
        else
          if client.useHTTP
            target = client.getClient
          else
            target = client
          target.audioTCPDataChannel = data_ch
          target.audioTCPControlChannel = control_ch
          target.useTCPForAudio = true
      else
        useTCPTransport = false
        if track is 'video'
          client.useTCPForVideo = false
        else
          client.useTCPForAudio = false

      client.supportsReliableRTP = req.headers['x-retransmit'] is 'our-retransmit'
      if req.headers['x-dynamic-rate']?
        client.supportsDynamicRate = req.headers['x-dynamic-rate'] is '1'
      else
        client.supportsDynamicRate = client.supportsReliableRTP
      if req.headers['x-transport-options']?
        match = /late-tolerance=([0-9.]+)/.exec req.headers['x-transport-options']
        if match?
          client.lateTolerance = parseFloat match[1]

      if useTCPTransport
        if /;interleaved=/.test req.headers.transport
          transportHeader = req.headers.transport
        else  # Maybe HTTP tunnelling
          transportHeader = req.headers.transport + ";interleaved=#{data_ch}-#{control_ch}" +
                            ";ssrc=#{zeropad(8, ssrc.toString(16))}"
      else
        transportHeader = req.headers.transport +
#                          ";source=#{api.getMeaningfulIPTo socket}" +
                          ";server_port=#{serverPort};ssrc=#{zeropad(8, ssrc.toString(16))}"
      dateHeader = api.getDateHeader()
      res = """
      RTSP/1.0 200 OK
      Date: #{dateHeader}
      Expires: #{dateHeader}
      Transport: #{transportHeader}
      Session: #{client.sessionID};timeout=60
      CSeq: #{req.headers.cseq}
      Server: #{@serverName}
      Cache-Control: no-cache


      """.replace /\n/g, "\r\n"
      callback null, res
    # after the response, client will send one or two RTP packets to this server

  respondPlay: (socket, req, callback) ->
    if req.headers.range? and (match = /npt=([\d.]+)-/.exec req.headers.range)?
      startTime = parseFloat match[1]
    else
      startTime = null

    client = @clients[socket.clientID]
    if not socket.isAuthenticated
      @respondWithNotFound req, 'RTSP', callback
      return

    preventFromPlaying = false
    stream = client.stream
    if not stream?
      @respondWithNotFound req, 'RTSP', callback
      return

    doResumeLater = false

    rangeStartTime = 0
    seq = new Sequent
    if stream.isRecorded()
      if not startTime? and stream.isPaused()
        startTime = stream.getCurrentPlayTime()
        logger.info "[#{TAG}:client=#{client.id}] resuming stream at #{stream.getCurrentPlayTime()}"
      if startTime?
        logger.info "[#{TAG}:client=#{client.id}] seek to #{startTime}"
        stream.pause()
        rangeStartTime = startTime
        stream.seek startTime, (err, actualStartTime) ->
          if err
            logger.error "[#{TAG}:client=#{client.id}] error: seek failed: #{err}"
            return
          logger.debug "[#{TAG}:client=#{client.id}] finished seeking stream to #{startTime}"
          stream.sendVideoPacketsSinceLastKeyFrame startTime, ->
            doResumeLater = true
            seq.done()
      else
        seq.done()
    else
      seq.done()


#    if (req.headers['user-agent']?.indexOf('QuickTime') > -1) and
#    not client.getClient?.useTCPForVideo
#      # QuickTime produces poor quality image over UDP.
#      # So we let QuickTime switch transport.
#      logger.info "UDP is disabled for QuickTime"
#      preventFromPlaying = true

#    Range: clock=#{RTSPServer.getISO8601DateString()}-
    # RTP-Info is defined in Section 12.33 in RFC 2326
    # seq: Indicates the sequence number of the first packet of the stream.
    # rtptime: Indicates the RTP timestamp corresponding to the time value in
    #          the Range response header.
    # TODO: Send this response after the first packet for this stream arrives
    seq.wait 1, =>
      baseUrl = req.uri.replace /\/$/, ''
      rtpInfos = []
      if stream.isAudioStarted
        rtpInfos.push "url=#{baseUrl}/trackID=1;seq=#{@getNextAudioSequenceNumber stream};rtptime=#{@getNextAudioRTPTimestamp stream}"
      if stream.isVideoStarted
        rtpInfos.push "url=#{baseUrl}/trackID=2;seq=#{@getNextVideoSequenceNumber stream};rtptime=#{@getNextVideoRTPTimestamp stream}"
      res = """
      RTSP/1.0 200 OK
      Range: npt=#{rangeStartTime}-
      Session: #{client.sessionID};timeout=60
      CSeq: #{req.headers.cseq}
      RTP-Info: #{rtpInfos.join ','}
      Server: #{@serverName}
      Cache-Control: no-cache


      """.replace /\n/g, "\r\n"
      if not preventFromPlaying
        stream.rtspNumClients++
        client.enablePlaying()
        if client.useHTTP
          logger.info "[#{TAG}:client=#{client.getClient.id}] start streaming over HTTP GET"
          stream.rtspClients[client.getClient.id] = client.getClient
          client.clientType = 'http-post'
          client.getClient.clientType = 'http-get'
          @dumpClients()
        else if client.useTCPForVideo  # or client.useTCPForAudio?
          logger.info "[#{TAG}:client=#{client.id}] start streaming over TCP"
          stream.rtspClients[client.id] = client
          client.clientType = 'tcp'
          @dumpClients()
        else
          logger.info "[#{TAG}:client=#{client.id}] start streaming over UDP"
          if ENABLE_START_PLAYING_FROM_KEYFRAME and stream.isVideoStarted
            client.isWaitingForKeyFrame = true
          else
            client.isPlaying = true
          stream.rtspClients[client.id] = client
          client.clientType = 'udp'
          @dumpClients()
        if client.useHTTP
          @startSendingRTCP stream, client.getClient
        else
          @startSendingRTCP stream, client
      else
        logger.info "[#{TAG}:client=#{client.id}] not playing"
      callback null, res

      if doResumeLater
        stream.resume false

  respondPause: (socket, req, callback) ->
    client = @clients[socket.clientID]
    if not socket.isAuthenticated
      @respondWithNotFound req, 'RTSP', callback
      return
    @stopSendingRTCP client
    client.disablePlaying()
    if client.stream.isRecorded()
      client.stream.pause()
    res = """
    RTSP/1.0 200 OK
    Session: #{client.sessionID};timeout=60
    CSeq: #{req.headers.cseq}
    Cache-Control: no-cache


    """.replace /\n/g, "\r\n"
    callback null, res

  respondTeardown: (socket, req, callback) ->
    client = @clients[socket.clientID]
    stream = client.uploadingStream ? client.stream
    if client is stream?.rtspUploadingClient
      logger.info "[#{TAG}:client=#{client.id}] finished uploading stream #{stream.id}"
      stream.rtspUploadingClient = null
      stream.emit 'end'
    if stream?.type is avstreams.STREAM_TYPE_RECORDED
      stream.teardown?()
    if not socket.isAuthenticated
      @respondWithNotFound req, 'RTSP', callback
      return
    client.disablePlaying()
    if stream?.rtspClients[client.id]?
      delete stream.rtspClients[client.id]
      stream.rtspNumClients--
    res = """
    RTSP/1.0 200 OK
    Session: #{client.sessionID};timeout=60
    CSeq: #{req.headers.cseq}
    Cache-Control: no-cache


    """.replace /\n/g, "\r\n"
    callback null, res

  respondAnnounce: (socket, req, callback) ->
    # TODO: Refuse uploading to a stream that is being uploaded
    client = @clients[socket.clientID]
    streamId = RTSPServer.getStreamIdFromUri req.uri
    stream = avstreams.get streamId
    if stream?
      stream.reset()
      @rtpParser.clearUnorderedPacketBuffer stream.id
    else
      stream = avstreams.create streamId
      stream.type = avstreams.STREAM_TYPE_LIVE

    sdpInfo = sdp.parse req.body

    for media in sdpInfo.media
      if media.media is 'video'
        sdpInfo.video = media
        if media.fmtpParams?['packetization-mode']?
          packetizationMode = parseInt media.fmtpParams['packetization-mode']
          if packetizationMode not in [0, 1]
            logger.error "[rtsp:stream:#{streamId}] error: unsupported packetization-mode: #{packetizationMode}"
        if media.fmtpParams?['sprop-parameter-sets']?
          nalUnits = h264.parseSpropParameterSets media.fmtpParams['sprop-parameter-sets']
          for nalUnit in nalUnits
            nalUnitType = nalUnit[0] & 0x1f
            switch nalUnitType
              when h264.NAL_UNIT_TYPE_SPS  # 7
                stream.updateSPS nalUnit
              when h264.NAL_UNIT_TYPE_PPS  # 8
                stream.updatePPS nalUnit
              else
                logger.warn "unknown nal_unit_type #{nalUnitType} in sprop-parameter-sets"
      else if media.media is 'audio'
        sdpInfo.audio = media

        if not media.clockRate?
          logger.error "Error: rtpmap attribute in SDP must have audio clock rate; assuming 44100"
          media.clockRate = 44100

        if not media.audioChannels?
          logger.error "Error: rtpmap attribute in SDP must have audio channels; assuming 2"
          media.audioChannels = 2

        logger.debug "[#{TAG}:client=#{client.id}] audio fmtp: #{JSON.stringify media.fmtpParams}"

        if not media.fmtpParams?
          logger.error "Error: fmtp attribute does not exist in SDP"
          media.fmtpParams = {}

        audioSpecificConfig = null
        ascInfo = null
        if media.fmtpParams.config? and (media.fmtpParams.config isnt '')
          audioSpecificConfig = new Buffer media.fmtpParams.config, 'hex'
          ascInfo = aac.parseAudioSpecificConfig audioSpecificConfig
          audioObjectType = ascInfo.audioObjectType
        else
          logger.error "Error: fmtp attribute in SDP does not have config parameter; assuming audioObjectType=2"
          audioObjectType = 2

        stream.updateConfig
          audioSampleRate: media.clockRate
          audioClockRate: media.clockRate
          audioChannels: media.audioChannels
          audioObjectType: audioObjectType
          audioSpecificConfig: audioSpecificConfig
          audioASCInfo: ascInfo

        if media.fmtpParams.sizelength?
          media.fmtpParams.sizelength = parseInt media.fmtpParams.sizelength
        else
          logger.error "Error: fmtp attribute in SDP must have sizelength parameter; assuming 13"
          media.fmtpParams.sizelength = 13
        if media.fmtpParams.indexlength?
          media.fmtpParams.indexlength = parseInt media.fmtpParams.indexlength
        else
          logger.error "Error: fmtp attribute in SDP must have indexlength parameter; assuming 3"
          media.fmtpParams.indexlength = 3
        if media.fmtpParams.indexdeltalength?
          media.fmtpParams.indexdeltalength = parseInt media.fmtpParams.indexdeltalength
        else
          logger.error "Error: fmtp attribute in SDP must have indexdeltalength parameter; assuming 3"
          media.fmtpParams.indexdeltalength = 3

    client.announceSDPInfo = sdpInfo
    # make circular reference between stream and client
    stream.rtspUploadingClient = client
    client.uploadingStream = stream
    client.uploadingTimestampInfo = {}

    socket.isAuthenticated = true

    res = """
    RTSP/1.0 200 OK
    CSeq: #{req.headers.cseq}


    """.replace /\n/g, "\r\n"
    callback null, res

  respondRecord: (socket, req, callback) ->
    client = @clients[socket.clientID]
    if client.mode isnt 'RECORD'
      logger.debug "client mode is not RECORD (got #{client.mode})"
      res = """
      RTSP/1.0 405 Method Not Allowed
      CSeq: #{req.headers.cseq}


      """.replace /\n/g, "\r\n"
      return callback null, res

    streamId = RTSPServer.getStreamIdFromUri req.uri
    logger.info "[#{TAG}:client=#{client.id}] started uploading stream #{streamId}"
    stream = avstreams.getOrCreate streamId
    if client.announceSDPInfo.video?  # has video
      @emit 'video_start', stream
    if client.announceSDPInfo.audio?  # has audio
      @emit 'audio_start', stream
    res = """
    RTSP/1.0 200 OK
    Session: #{client.sessionID};timeout=60
    CSeq: #{req.headers.cseq}
    Server: #{@serverName}
    Cache-Control: no-cache


    """.replace /\n/g, "\r\n"
    callback null, res

  respond: (socket, req, callback) ->
    if (req.protocolName isnt 'RTSP') and (req.protocolName isnt 'HTTP')
      # Request cannot be handled; close the connection
      callback null, null,
        close: true
    if config.enableRTSP and (req.protocolName is 'RTSP') and (req.method is 'OPTIONS')
      @respondOptions socket, req, callback
    else if (req.method is 'POST') and (req.protocolName is 'HTTP') # HTTP POST
      @respondPost socket, req, callback
    else if (req.method is 'GET') and (req.protocolName is 'HTTP') # HTTP GET
      @respondGet socket, req, callback
    else if config.enableRTSP and (req.protocolName is 'RTSP') and (req.method is 'DESCRIBE')  # DESCRIBE for RTSP, GET for HTTP
      @respondDescribe socket, req, callback
    else if config.enableRTSP and (req.protocolName is 'RTSP') and (req.method is 'SETUP')
      @respondSetup socket, req, callback
    else if config.enableRTSP and (req.protocolName is 'RTSP') and (req.method is 'PLAY')
      @respondPlay socket, req, callback
    else if config.enableRTSP and (req.protocolName is 'RTSP') and (req.method is 'PAUSE')
      @respondPause socket, req, callback
    else if config.enableRTSP and (req.protocolName is 'RTSP') and (req.method is 'TEARDOWN')
      @respondTeardown socket, req, callback
    else if config.enableRTSP and (req.protocolName is 'RTSP') and (req.method is 'ANNOUNCE')
      @respondAnnounce socket, req, callback
    else if config.enableRTSP and (req.protocolName is 'RTSP') and (req.method is 'RECORD')
      @respondRecord socket, req, callback
    else
      logger.warn "[#{TAG}] method \"#{req.method}\" not implemented for protocol \"#{req.protocol}\""
      @respondWithNotFound req, req.protocolName, callback

  # Called when received video data over RTSP
  onUploadVideoData: (stream, msg, rinfo) ->
    if not stream.rtspUploadingClient?
#      logger.warn "no client is uploading video data to stream #{stream.id}"
      return
    packet = rtp.parsePacket msg
    if not stream.rtspUploadingClient.videoRTPStartTimestamp?
      # TODO: Is it correct to set the start timestamp in this manner?
      stream.rtspUploadingClient.videoRTPStartTimestamp = packet.rtpHeader.timestamp
    if packet.rtpHeader.payloadType is stream.rtspUploadingClient.announceSDPInfo.video.fmt
      @rtpParser.feedUnorderedH264Buffer msg, stream.id
    else
      logger.error "Error: Unknown payload type: #{packet.rtpHeader.payloadType} as video"

  onUploadVideoControl: (stream, msg, rinfo) ->
    if not stream.rtspUploadingClient?
#      logger.warn "no client is uploading audio data to stream #{stream.id}"
      return
    packets = rtp.parsePackets msg
    for packet in packets
      if packet.rtcpSenderReport?
        if not stream.rtspUploadingClient.uploadingTimestampInfo.video?
          stream.rtspUploadingClient.uploadingTimestampInfo.video = {}
        stream.rtspUploadingClient.uploadingTimestampInfo.video.rtpTimestamp = packet.rtcpSenderReport.rtpTimestamp
        stream.rtspUploadingClient.uploadingTimestampInfo.video.time = packet.rtcpSenderReport.ntpTimestampInMs

  onUploadAudioData: (stream, msg, rinfo) ->
    if not stream.rtspUploadingClient?
#      logger.warn "no client is uploading audio data to stream #{stream.id}"
      return
    packet = rtp.parsePacket msg
    if not stream.rtspUploadingClient.audioRTPStartTimestamp?
      # TODO: Is it correct to set the start timestamp in this manner?
      stream.rtspUploadingClient.audioRTPStartTimestamp = packet.rtpHeader.timestamp
    if packet.rtpHeader.payloadType is stream.rtspUploadingClient.announceSDPInfo.audio.fmt
      @rtpParser.feedUnorderedAACBuffer msg, stream.id, stream.rtspUploadingClient.announceSDPInfo.audio.fmtpParams
    else
      logger.error "Error: Unknown payload type: #{packet.rtpHeader.payloadType} as audio"

  onUploadAudioControl: (stream, msg, rinfo) ->
    if not stream.rtspUploadingClient?
#      logger.warn "no client is uploading audio data to stream #{stream.id}"
      return
    packets = rtp.parsePackets msg
    for packet in packets
      if packet.rtcpSenderReport?
        if not stream.rtspUploadingClient.uploadingTimestampInfo.audio?
          stream.rtspUploadingClient.uploadingTimestampInfo.audio = {}
        stream.rtspUploadingClient.uploadingTimestampInfo.audio.rtpTimestamp = packet.rtcpSenderReport.rtpTimestamp
        stream.rtspUploadingClient.uploadingTimestampInfo.audio.time = packet.rtcpSenderReport.ntpTimestampInMs

# Represents an RTSP session
class RTSPClient
  constructor: (opts) ->
    @videoPacketCount = 0
    @videoOctetCount = 0
    @audioPacketCount = 0
    @audioOctetCount = 0
    @isPlaying = false
    @timeoutID = null
    @videoSSRC = generateRandom32()
    @audioSSRC = generateRandom32()
    @supportsReliableRTP = false

    for name, value of opts
      @[name] = value

  disablePlaying: ->
    if @useHTTP
      @getClient.isWaitingForKeyFrame = false
      @getClient.isPlaying = false
    else
      @isWaitingForKeyFrame = false
      @isPlaying = false

  enablePlaying: ->
    if @useHTTP
      if ENABLE_START_PLAYING_FROM_KEYFRAME and client.stream.isVideoStarted
        @getClient.isWaitingForKeyFrame = true
      else
        @getClient.isPlaying = true
    else
      if ENABLE_START_PLAYING_FROM_KEYFRAME and stream.isVideoStarted
        @isWaitingForKeyFrame = true
      else
        @isPlaying = true

  toString: ->
    if not @socket.remoteAddress?
      return "#{@id}: session=#{@sessionID} (being destroyed)"
    else
      transportDesc = if @clientType? then "type=#{@clientType}" else ''
      if @clientType in ['http-get', 'tcp', 'udp']
        transportDesc += " isPlaying=#{@isPlaying}"
      return "#{@id}: session=#{@sessionID} addr=#{@socket.remoteAddress} port=#{@socket.remotePort} #{transportDesc}"

api =
  RTSPServer: RTSPServer

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

  isLoopbackAddress: (socket) ->
    return socket.remoteAddress is '127.0.0.1'

  # Check if the remote address of the given socket is private
  isPrivateNetwork: (socket) ->
    if /^(10\.|192\.168\.|127\.0\.0\.)/.test socket.remoteAddress
      return true
    if (match = /^172.(\d+)\./.exec socket.remoteAddress)?
      num = parseInt match[1]
      if 16 <= num <= 31
        return true
    return false

  getDateHeader: ->
    d = new Date
    "#{DAY_NAMES[d.getUTCDay()]}, #{d.getUTCDate()} #{MONTH_NAMES[d.getUTCMonth()]}" +
    " #{d.getUTCFullYear()} #{zeropad 2, d.getUTCHours()}:#{zeropad 2, d.getUTCMinutes()}" +
    ":#{zeropad 2, d.getUTCSeconds()} UTC"

  # Returns this machine's IP address which is attached to network interface
  # TODO: Get IP address from socket
  getLocalIP: ->
    ifacePrecedence = [ 'wlan', 'eth', 'en' ]

    # compare function for sort
    getPriority = (ifaceName) ->
      for name, i in ifacePrecedence
        if ifaceName.indexOf(name) is 0
          return i
      return ifacePrecedence.length

    ifaces = os.networkInterfaces()
    ifaceNames = Object.keys(ifaces)
    ifaceNames.sort (a, b) ->
      getPriority(a) - getPriority(b)

    for ifaceName in ifaceNames
      for addr in ifaces[ifaceName]
        if (not addr.internal) and (addr.family is 'IPv4')
          return addr.address

    return "127.0.0.1"

  getExternalIP: ->
    return "127.0.0.1" # TODO: Fetch this from UPnP or something

  # Get local IP address which is meaningful to the
  # partner of the given socket
  getMeaningfulIPTo: (socket) ->
    if api.isLoopbackAddress socket
      return '127.0.0.1'
    else if api.isPrivateNetwork socket
      return api.getLocalIP()
    else
      return api.getExternalIP()

  leaveClient: (client) ->
    for streamName, stream of avstreams.getAll()
      logger.debug "[stream:#{stream.id}] leaveClient: #{client.id}"
      if stream.rtspClients[client.id]?
        delete stream.rtspClients[client.id]
        stream.rtspNumClients--
    return

module.exports = api
