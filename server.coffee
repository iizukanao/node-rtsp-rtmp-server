# RTSP and RTMP/RTMPE/RTMPT/RTMPTE server implementation mainly for
# Raspberry Pi. Also serves HTTP contents as this server is meant to
# be run on port 80.

# TODO: clear old sessioncookies

net         = require 'net'
dgram       = require 'dgram'
fs          = require 'fs'
os          = require 'os'
crypto      = require 'crypto'
url         = require 'url'
path        = require 'path'
spawn       = require('child_process').spawn

codec_utils = require './codec_utils'
config      = require './config'
RTMPServer  = require './rtmp'
HTTPHandler = require './http'
rtsp        = require './rtsp'
rtp         = require './rtp'
sdp         = require './sdp'
h264        = require './h264'
aac         = require './aac'
hybrid_udp  = require './hybrid_udp'
bits        = require './bits'

# Clock rate for audio stream
audioClockRate = null

# Default server name for RTSP and HTTP responses
DEFAULT_SERVER_NAME = 'node-rtsp-rtmp-server/0.2.2'

serverName = config.serverName ? DEFAULT_SERVER_NAME

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

DEBUG_PACKET_DATA = false

# If true, RTSP requests/responses tunneled in HTTP will be
# printed to the console
DEBUG_HTTP_TUNNEL = false

# If true, UDP transport will always be disabled and
# clients will be forced to use TCP transport.
DEBUG_DISABLE_UDP_TRANSPORT = false

# Two CRLFs
CRLF_CRLF = [ 0x0d, 0x0a, 0x0d, 0x0a ]

detectedVideoWidth = null
detectedVideoHeight = null
detectedAudioSampleRate = null
detectedAudioChannels = null
detectedAudioPeriodSize = null

# Delete UNIX domain sockets
deleteReceiverSocketsSync = ->
  if config.receiverType is 'unix'
    if fs.existsSync config.videoControlReceiverPath
      try
        fs.unlinkSync config.videoControlReceiverPath
      catch e
        console.error "unlink error: #{e}"
    if fs.existsSync config.audioControlReceiverPath
      try
        fs.unlinkSync config.audioControlReceiverPath
      catch e
        console.error "unlink error: #{e}"
    if fs.existsSync config.videoDataReceiverPath
      try
        fs.unlinkSync config.videoDataReceiverPath
      catch e
        console.error "unlink error: #{e}"
    if fs.existsSync config.audioDataReceiverPath
      try
        fs.unlinkSync config.audioDataReceiverPath
      catch e
        console.error "unlink error: #{e}"
  return

deleteReceiverSocketsSync()

isVideoStarted = false
isAudioStarted = false

uploadingClient = null

# For debug
lastSentVideoTimestamp = 0

getVideoSendTimeForUploadingRTPTimestamp = (rtpTimestamp) ->
  if uploadingClient.uploadingTimestampInfo.video?
    rtpDiff = rtpTimestamp - uploadingClient.uploadingTimestampInfo.video.rtpTimestamp # 90 kHz clock
    timeDiff = rtpDiff / 90
    return uploadingClient.uploadingTimestampInfo.video.time + timeDiff
  else
    return Date.now()

getAudioSendTimeForUploadingRTPTimestamp = (rtpTimestamp) ->
  if uploadingClient.uploadingTimestampInfo.audio?
    rtpDiff = rtpTimestamp - uploadingClient.uploadingTimestampInfo.audio.rtpTimestamp
    timeDiff = rtpDiff * 1000 / audioClockRate
    return uploadingClient.uploadingTimestampInfo.audio.time + timeDiff
  else
    return Date.now()

# Create RTMP server
rtmpServer = new RTMPServer
rtmpServer.on 'stream_reset', ->
  console.log 'stream_reset from rtmp source'
  resetStreams()
rtmpServer.on 'video_start', ->
  onReceiveVideoControlBuffer()
rtmpServer.on 'video_data', (pts, dts, nalUnits) ->
  onReceiveVideoPacket nalUnits, pts, dts
rtmpServer.on 'audio_start', ->
  onReceiveAudioControlBuffer()
rtmpServer.on 'audio_data', (pts, dts, adtsFrame) ->
  onReceiveAudioPacket adtsFrame, pts, dts

rtmpServer.start ->
  # RTMP server is ready

httpHandler = new HTTPHandler
httpHandler.setServerName serverName

updateConfig = ->
  rtmpServer.updateConfig config

# profile-level-id is defined in RFC 6184.
# profile_idc, constraint flags for Baseline profile are
# defined in A.2.1 in H.264 Annex A.
# profile-level-id is a base16 representation of three bytes:
#   1) profile_idc (2 bytes) = 66 (Baseline profile)
#                              77 (Main profile)
#                              100 (High profile)
#   2) a byte herein referred to as profile-iop
#     (defined in 7.4.2.1.1 in H.264 spec)
#     constraint_set0_flag: 1 (Constrained Baseline Profile); Main=0
#     constraint_set1_flag: 1 (Constrained Baseline Profile); Main=1
#     constraint_set2_flag: 0; Main=0
#     constraint_set3_flag: Must be 0 (ignored by decoders in this case); Main=0
#     constraint_set4_flag: Must be 0 (ignored by decoders in this case); Main=0? (frame_mbs_only_flag)
#     constraint_set5_flag: Must be 0 (ignored by decoders in this case); Main=1 (B frames are not present)
#     reserved_zero_2bits : both 0
#   3) level_idc = 31 (Level 3.1)
PROFILE_LEVEL_ID = '42C01F'  # Baseline Profile, Level 3.1
# PROFILE_LEVEL_ID will be replaced with incoming SPS packet (NAL unit type 7), from byte 1 to 3

spropParameterSets = ''  # will be populated later
spsString = ''
ppsString = ''
spsNALUnit = null
ppsNALUnit = null

# Reset audio/video streams
resetStreams = ->
  isVideoStarted = false
  isAudioStarted = false
  uploadingClient = null
  spropParameterSets = ''
  rtmpServer.resetStreams()

# Update spropParameterSets based on NAL unit
updateSpropParam = (buf) ->
  nalUnitType = buf[0] & 0x1f
  if nalUnitType is 7  # SPS packet
    spsString = buf.toString 'base64'
    PROFILE_LEVEL_ID = buf[1..3].toString('hex').toUpperCase()
  else if nalUnitType is 8  # PPS packet
    ppsString = buf.toString 'base64'

  spropParameterSets = spsString + ',' + ppsString

clientsCount = 0
clients = {}
httpSessions = {}

zeropad = (columns, num) ->
  num += ''
  while num.length < columns
    num = '0' + num
  num

getDateHeader = ->
  d = new Date
  "#{DAY_NAMES[d.getUTCDay()]}, #{d.getUTCDate()} #{MONTH_NAMES[d.getUTCMonth()]}" +
  " #{d.getUTCFullYear()} #{zeropad 2, d.getUTCHours()}:#{zeropad 2, d.getUTCMinutes()}" +
  ":#{zeropad 2, d.getUTCSeconds()} UTC"

getLocalIP = ->
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

getExternalIP = ->
  "127.0.0.1" # TODO: Fetch this from UPnP or something

# Get local IP address which is meaningful to the
# partner of the given socket
getMeaningfulIPTo = (socket) ->
  if isPrivateNetwork socket
    return getLocalIP()
  else
    return getExternalIP()

timeForVideoRTPZero = null
timeForAudioRTPZero = null

getVideoRTPTimestamp = (time) ->
  return Math.round time * 90 % TIMESTAMP_ROUNDOFF

getAudioRTPTimestamp = (time) ->
  if not audioClockRate?
    throw new Error "audioClockRate is null"
  return Math.round time * (audioClockRate / 1000) % TIMESTAMP_ROUNDOFF

sendVideoSenderReport = (client) ->
  if not timeForVideoRTPZero?
    return

  time = new Date().getTime()
  buf = new Buffer rtp.createSenderReport
    time: time
    rtpTime: getVideoRTPTimestamp time - timeForVideoRTPZero
    ssrc: client.videoSSRC
    packetCount: client.videoPacketCount
    octetCount: client.videoOctetCount

  if client.useTCPForVideo
    if client.useHTTP
      if client.httpClientType is 'GET'
        sendDataByTCP client.socket, client.videoTCPControlChannel, buf
    else
      sendDataByTCP client.socket, client.videoTCPControlChannel, buf
  else
    if client.clientVideoRTCPPort?
      videoRTCPSocket.send buf, 0, buf.length, client.clientVideoRTCPPort, client.ip, (err, bytes) ->
        if err
          console.error "[videoRTCPSend] error: #{err.message}"

sendAudioSenderReport = (client) ->
  if not timeForAudioRTPZero?
    return

  time = new Date().getTime()
  buf = new Buffer rtp.createSenderReport
    time: time
    rtpTime: getAudioRTPTimestamp time - timeForAudioRTPZero
    ssrc: client.audioSSRC
    packetCount: client.audioPacketCount
    octetCount: client.audioOctetCount

  if client.useTCPForAudio
    if client.useHTTP
      if client.httpClientType is 'GET'
        sendDataByTCP client.socket, client.audioTCPControlChannel, buf
    else
      sendDataByTCP client.socket, client.audioTCPControlChannel, buf
  else
    if client.clientAudioRTCPPort?
      audioRTCPSocket.send buf, 0, buf.length, client.clientAudioRTCPPort, client.ip, (err, bytes) ->
        if err
          console.error "[audioRTCPSend] error: #{err.message}"

stopSendingRTCP = (client) ->
  if client.timeoutID?
    clearTimeout client.timeoutID
    client.timeoutID = null

# Send RTCP sender report packets for audio and video streams
sendSenderReports = (client) ->
  if not clients[client.socket.clientID]? # socket is already closed
    stopSendingRTCP client
    return

  if isAudioStarted
    sendAudioSenderReport client
  if isVideoStarted
    sendVideoSenderReport client

  client.timeoutID = setTimeout ->
    sendSenderReports client
  , config.rtcpSenderReportIntervalMs

startSendingRTCP = (client) ->
  stopSendingRTCP client

  sendSenderReports client

onReceiveVideoRTCP = (buf) ->
  # TODO: handle BYE message

onReceiveAudioRTCP = (buf) ->
  # TODO: handle BYE message

videoFrames = 0
audioFrames = 0

onReceiveBuffer = (buf) ->
  packetType = buf[0]
  switch packetType
    when 0x00 then onReceiveVideoControlBuffer buf
    when 0x01 then onReceiveAudioControlBuffer buf
    when 0x02 then onReceiveVideoDataBuffer buf
    when 0x03 then onReceiveAudioDataBuffer buf
    when 0x04 then onReceiveVideoDataBufferWithDTS buf
    when 0x05 then onReceiveAudioDataBufferWithDTS buf
    else
      console.log "unknown packet type: #{packetType}"
      # ignore
  return

onReceiveVideoControlBuffer = (buf) ->
  console.log "video start"
  isVideoStarted = true
  timeForVideoRTPZero = Date.now()
  timeForAudioRTPZero = timeForVideoRTPZero
  spropParameterSets = ''
  rtmpServer.startVideo()

onReceiveAudioControlBuffer = (buf) ->
  console.log "audio start"
  isAudioStarted = true
  timeForAudioRTPZero = Date.now()
  timeForVideoRTPZero = timeForAudioRTPZero
  rtmpServer.startAudio()

onReceiveVideoDataBuffer = (buf) ->
  pts = buf[1] * 0x010000000000 + \
        buf[2] * 0x0100000000   + \
        buf[3] * 0x01000000     + \
        buf[4] * 0x010000       + \
        buf[5] * 0x0100         + \
        buf[6]
  dts = pts
  nalUnit = buf[7..]
  onReceiveVideoPacket nalUnit, pts, dts

onReceiveVideoDataBufferWithDTS = (buf) ->
  pts = buf[1] * 0x010000000000 + \
        buf[2] * 0x0100000000   + \
        buf[3] * 0x01000000     + \
        buf[4] * 0x010000       + \
        buf[5] * 0x0100         + \
        buf[6]
  dts = buf[7]  * 0x010000000000 + \
        buf[8]  * 0x0100000000   + \
        buf[9]  * 0x01000000     + \
        buf[10] * 0x010000       + \
        buf[11] * 0x0100         + \
        buf[12]
  nalUnit = buf[13..]
  onReceiveVideoPacket nalUnit, pts, dts

onReceiveAudioDataBuffer = (buf) ->
  pts = buf[1] * 0x010000000000 + \
        buf[2] * 0x0100000000   + \
        buf[3] * 0x01000000     + \
        buf[4] * 0x010000       + \
        buf[5] * 0x0100         + \
        buf[6]
  dts = pts
  adtsFrame = buf[7..]
  onReceiveAudioPacket adtsFrame, pts, dts

onReceiveAudioDataBufferWithDTS = (buf) ->
  pts = buf[1] * 0x010000000000 + \
        buf[2] * 0x0100000000   + \
        buf[3] * 0x01000000     + \
        buf[4] * 0x010000       + \
        buf[5] * 0x0100         + \
        buf[6]
  dts = buf[7]  * 0x010000000000 + \
        buf[8]  * 0x0100000000   + \
        buf[9]  * 0x01000000     + \
        buf[10] * 0x010000       + \
        buf[11] * 0x0100         + \
        buf[12]
  adtsFrame = buf[13..]
  onReceiveAudioPacket adtsFrame, pts, dts

createReceiver = (name, callback) ->
  return net.createServer (c) ->
    console.log "new connection to #{name}"
    buf = null
    c.on 'close', ->
      console.log "connection to #{name} closed"
    c.on 'data', (data) ->
      if config.debug.dropAllData
        return
      if buf?
        buf = Buffer.concat [buf, data]
      else
        buf = data
      if buf.length >= 3  # 3 bytes == payload size
        loop
          payloadSize = buf[0] * 0x10000 + buf[1] * 0x100 + buf[2]
          totalSize = payloadSize + 3  # 3 bytes for payload size
          if buf.length >= totalSize
            callback buf.slice 3, totalSize  # 3 bytes for payload size
            if buf.length > totalSize
              buf = buf.slice totalSize
            else
              buf = null
              break
          else
            break
      return

# Setup data receivers
#
# We create four separate sockets for receiving different kinds of data.
# If we have just one socket for receiving all kinds of data, the sender
# has to lock and synchronize audio/video writer threads and it leads to
# slightly worse performance.
if config.receiverType in ['unix', 'tcp']
  videoControlReceiver = createReceiver 'VideoControl', onReceiveVideoControlBuffer
  audioControlReceiver = createReceiver 'AudioControl', onReceiveAudioControlBuffer
  videoDataReceiver = createReceiver 'VideoData', onReceiveVideoDataBuffer
  audioDataReceiver = createReceiver 'AudioData', onReceiveAudioDataBuffer
else if config.receiverType is 'udp'
  videoControlReceiver = new hybrid_udp.UDPServer
  videoControlReceiver.name = 'VideoControl'
  videoControlReceiver.on 'packet', (buf) ->
    onReceiveVideoControlBuffer buf[3..]
  audioControlReceiver = new hybrid_udp.UDPServer
  audioControlReceiver.name = 'AudioControl'
  audioControlReceiver.on 'packet', (buf) ->
    onReceiveAudioControlBuffer buf[3..]
  videoDataReceiver = new hybrid_udp.UDPServer
  videoDataReceiver.name = 'VideoData'
  videoDataReceiver.on 'packet', (buf) ->
    onReceiveVideoDataBuffer buf[3..]
  audioDataReceiver = new hybrid_udp.UDPServer
  audioDataReceiver.name = 'AudioData'
  audioDataReceiver.on 'packet', (buf) ->
    onReceiveAudioDataBuffer buf[3..]
else
  throw new Error "unknown receiverType in config: #{config.receiverType}"

# Start data receivers
if config.receiverType is 'unix'
  videoControlReceiver.listen config.videoControlReceiverPath, ->
    fs.chmodSync config.videoControlReceiverPath, '777'
    console.log "videoControlReceiver is listening on #{config.videoControlReceiverPath}"
  audioControlReceiver.listen config.audioControlReceiverPath, ->
    fs.chmodSync config.audioControlReceiverPath, '777'
    console.log "audioControlReceiver is listening on #{config.audioControlReceiverPath}"
  videoDataReceiver.listen config.videoDataReceiverPath, ->
    fs.chmodSync config.videoDataReceiverPath, '777'
    console.log "videoDataReceiver is listening on #{config.videoDataReceiverPath}"
  audioDataReceiver.listen config.audioDataReceiverPath, ->
    fs.chmodSync config.audioDataReceiverPath, '777'
    console.log "audioDataReceiver is listening on #{config.audioDataReceiverPath}"
else if config.receiverType is 'tcp'
  videoControlReceiver.listen config.videoControlReceiverPort,
    config.receiverListenHost, config.receiverTCPBacklog, ->
      console.log "videoControlReceiver is listening on tcp:#{config.videoControlReceiverPort}"
  audioControlReceiver.listen config.audioControlReceiverPort,
    config.receiverListenHost, config.receiverTCPBacklog, ->
      console.log "audioControlReceiver is listening on tcp:#{config.audioControlReceiverPort}"
  videoDataReceiver.listen config.videoDataReceiverPort,
    config.receiverListenHost, config.receiverTCPBacklog, ->
      console.log "videoDataReceiver is listening on tcp:#{config.videoDataReceiverPort}"
  audioDataReceiver.listen config.audioDataReceiverPort,
    config.receiverListenHost, config.receiverTCPBacklog, ->
      console.log "audioDataReceiver is listening on tcp:#{config.audioDataReceiverPort}"
else if config.receiverType is 'udp'
  videoControlReceiver.start config.videoControlReceiverPort, config.receiverListenHost, ->
    console.log "videoControlReceiver is listening on udp:#{config.videoControlReceiverPort}"
  audioControlReceiver.start config.audioControlReceiverPort, config.receiverListenHost, ->
    console.log "audioControlReceiver is listening on udp:#{config.audioControlReceiverPort}"
  videoDataReceiver.start config.videoDataReceiverPort, config.receiverListenHost, ->
    console.log "videoDataReceiver is listening on udp:#{config.videoDataReceiverPort}"
  audioDataReceiver.start config.audioDataReceiverPort, config.receiverListenHost, ->
    console.log "audioDataReceiver is listening on udp:#{config.audioDataReceiverPort}"
else
  throw new Error "unknown receiverType in config: #{config.receiverType}"

# Generate random 32 bit unsigned integer.
# Return value is intended to be used as an SSRC identifier.
generateRandom32 = ->
  str = "#{new Date().getTime()}#{process.pid}#{os.hostname()}" + \
        "#{process.getuid()}#{process.getgid()}" + \
        (1 + Math.random() * 1000000000)

  md5sum = crypto.createHash 'md5'
  md5sum.update str
  md5sum.digest()[0..3].readUInt32BE(0)

# Generate new random session ID
# NOTE: Samsung SC-02B doesn't work with some hex string
generateNewSessionID = (callback) ->
  id = ''
  for i in [0..7]
    id += parseInt(Math.random() * 9) + 1
  callback null, id

highestClientID = 0

teardownClient = (id) ->
  client = clients[id]
  if client?
    console.log "[rtsp] teardownClient: id=#{id} session=#{client?.sessionID}"
    stopSendingRTCP client
    try
      client.socket.end()
    catch e
      console.error "socket.end() error: #{e}"
    delete clients[id]
    clientsCount--

listClients = ->
  console.log "#{Object.keys(clients).length} clients"
#  for clientID, client of clients
#    console.log " id=#{clientID} session=#{client.sessionID}"
  return

sendDataByTCP = (socket, channel, rtpBuffer) ->
  rtpLen = rtpBuffer.length
  tcpHeader = rtsp.createInterleavedHeader
    channel: channel
    payloadLength: rtpLen
  socket.write Buffer.concat [tcpHeader, rtpBuffer],
    rtsp.INTERLEAVED_HEADER_LEN + rtpBuffer.length

# Process incoming RTSP data that is tunneled in HTTP POST
handlePOSTData = (client, data='', callback) ->
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
  processRemainingBuffer = ->
    if client.postBase64Buf? or client.postBuf?
      handlePOSTData client, '', callback
    else
      callback? null
    return

  if postData[0] is rtsp.INTERLEAVED_SIGN  # interleaved data
    interleavedData = rtsp.getInterleavedData postData
    if not interleavedData?
      # not enough buffer for an interleaved data
      client.postBuf = postData
      callback? null
      return
    # At this point, postData has enough buffer for this interleaved data.

    onInterleavedRTPPacketFromClient client, interleavedData

    if postData.length > interleavedData.totalLength
      client.postBuf = client.buf[interleavedData.totalLength..]

    processRemainingBuffer()
  else
    delimiterPos = bits.searchBytesInArray postData, CRLF_CRLF
    if delimiterPos is -1  # not found (not enough buffer)
      client.postBuf = postData
      callback? null
      return

    decodedRequest = postData[0...delimiterPos].toString 'utf8'
    remainingPostData = postData[delimiterPos+CRLF_CRLF.length..]
    req = parseRequest decodedRequest
    if not req?  # parse error
      console.error "Error: request can't be parsed: #{decodedRequest}"
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
      console.log "===request (HTTP tunneled/decoded)==="
      process.stdout.write decodedRequest
      console.log "============="
    respond client.socket, req, (err, output) ->
      if err
        console.error "[respond] Error: #{err}"
        callback? err
        return
      if DEBUG_HTTP_TUNNEL
        console.log "===response (HTTP tunneled)==="
        process.stdout.write output
        console.log "============="
      client.getClient.socket.write output
      processRemainingBuffer()

clearTimeout = (socket) ->
  if socket.timeoutTimer?
    clearTimeout socket.timeoutTimer

scheduleTimeout = (socket) ->
  clearTimeout socket
  socket.scheduledTimeoutTime = Date.now() + config.keepaliveTimeoutMs
  socket.timeoutTimer = setTimeout ->
    if not clients[socket.clientID]?
      return
    if Date.now() < socket.scheduledTimeoutTime
      return
    console.log "keepalive timeout: #{socket.clientID}"
    teardownClient socket.clientID
  , config.keepaliveTimeoutMs

# Called when the server received an interleaved RTP packet
onInterleavedRTPPacketFromClient = (client, interleavedData) ->
  if client is uploadingClient
    # TODO: Support multiple streams
    senderInfo =
      address: null
      port: null
    switch interleavedData.channel
      when uploadingClient.uploadingChannels.videoData
        onUploadVideoData interleavedData.data, senderInfo
      when uploadingClient.uploadingChannels.videoControl
        onUploadVideoControl interleavedData.data, senderInfo
      when uploadingClient.uploadingChannels.audioData
        onUploadAudioData interleavedData.data, senderInfo
      when uploadingClient.uploadingChannels.audioControl
        onUploadAudioControl interleavedData.data, senderInfo
      else
        console.error "Error: unknown interleaved channel: #{interleavedData.channel}"
  # Discard incoming RTP packets if the client is not uploading streams

# Called when new data comes from TCP connection
handleOnData = (c, data) ->
  id_str = c.clientID
  if not clients[id_str]?
    console.warn "error: invalid client ID: #{id_str}"
    return

  client = clients[id_str]
  if client.isSendingPOST
    handlePOSTData client, data.toString 'utf8'
    return
  if c.buf?
    c.buf = Buffer.concat [c.buf, data], c.buf.length + data.length
  else
    c.buf = data
  if c.buf[0] is rtsp.INTERLEAVED_SIGN # dollar sign '$' (RFC 2326 - 10.12)
    interleavedData = rtsp.getInterleavedData c.buf
    if not interleavedData?
      # not enough buffer for an interleaved data
      return

    # At this point, c.buf has enough buffer for this interleaved data.
    if c.buf.length > interleavedData.totalLength
      c.buf = c.buf[interleavedData.totalLength..]
    else
      c.buf = null

    onInterleavedRTPPacketFromClient client, interleavedData

    if c.buf?
      # Process the remaining buffer
      # TODO: Is there more efficient way to do this?
      buf = c.buf
      c.buf = null
      handleOnData c, buf

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
      console.log "===RTSP request (cont)==="
      process.stdout.write data.toString 'utf8'
      console.log "=================="
  else
    bufString = c.buf.toString 'utf8'
    if bufString.indexOf('\r\n\r\n') is -1
      return
    if DEBUG_RTSP
      console.log "===RTSP request==="
      process.stdout.write bufString
      console.log "=================="
    req = parseRequest bufString
    if not req?
      console.error "Error: request can't be parsed: #{bufString}"
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
  respond c, req, (err, output, resultOpts) ->
    if err
      console.error "[respond] Error: #{err}"
      return
    # Write the response
    if DEBUG_RTSP
      console.log "===RTSP response==="
    if output instanceof Array
      for out, i in output
        if DEBUG_RTSP
          console.log out
        c.write out
    else
      if DEBUG_RTSP
        process.stdout.write output
      c.write output
    if DEBUG_RTSP
      console.log "==================="
    if resultOpts?.close
      console.log "[#{c.clientID}] end"
      c.end()
    if c.buf?
      # Process the remaining buffer
      buf = c.buf
      c.buf = null
      handleOnData c, buf

onClientConnect = (c) ->
  # New client is connected
  highestClientID++
  id_str = 'c' + highestClientID
  console.log "client connected #{id_str}"
  generateNewSessionID (err, sessionID) ->
    throw err if err
    clients[id_str] =
      id: id_str
      sessionID: sessionID
      socket: c
      ip: c.remoteAddress
      isGlobal: not isPrivateNetwork c
      videoPacketCount: 0
      videoOctetCount: 0
      audioPacketCount: 0
      audioOctetCount: 0
      isPlaying: false
      timeoutID: null
      videoSSRC: generateRandom32()
      audioSSRC: generateRandom32()
      supportsReliableRTP: false
    clientsCount++
    listClients()
    c.setKeepAlive true, 120000
    c.clientID = id_str  # TODO: Is this safe?
    c.isAuthenticated = false
    c.requestCount = 0
    c.responseCount = 0
    c.on 'close', ->
      console.log "[#{new Date}] client #{id_str} is closed"
      teardownClient c.clientID
      listClients()
    c.buf = null
    c.on 'error', (err) ->
      console.error "Socket error (#{c.clientID}): #{err}"
      c.destroy()
    c.on 'data', (data) ->
      handleOnData c, data

process.on 'SIGINT', ->
  deleteReceiverSocketsSync()
  process.kill process.pid, 'SIGTERM'

process.on 'uncaughtException', (err) ->
  deleteReceiverSocketsSync()
  throw err

onUploadVideoData = (msg, senderInfo) ->
  if not uploadingClient?
    console.log "no client is uploading data"
    return
  packet = rtp.parsePacket msg
  if not uploadingClient.videoRTPStartTimestamp?
    # TODO: Is this correct to set the start timestamp in this manner?
    uploadingClient.videoRTPStartTimestamp = packet.rtpHeader.timestamp
  if packet.rtpHeader.payloadType is uploadingClient.announceSDPInfo.video.fmt
    rtp.feedUnorderedH264Buffer msg, 'upload-client'
  else
    console.error "Error: Unknown payload type: #{packet.rtpHeader.payloadType} as video"

onUploadVideoControl = (msg, rinfo) ->
  packets = rtp.parsePackets msg
  for packet in packets
    if packet.rtcpSenderReport?
      if not uploadingClient.uploadingTimestampInfo.video?
        uploadingClient.uploadingTimestampInfo.video = {}
      uploadingClient.uploadingTimestampInfo.video.rtpTimestamp = packet.rtcpSenderReport.rtpTimestamp
      uploadingClient.uploadingTimestampInfo.video.time = packet.rtcpSenderReport.ntpTimestampInMs

onUploadAudioData = (msg, rinfo) ->
  packet = rtp.parsePacket msg
  if not uploadingClient.audioRTPStartTimestamp?
    # TODO: Is this correct to set the start timestamp in this manner?
    uploadingClient.audioRTPStartTimestamp = packet.rtpHeader.timestamp
  if packet.rtpHeader.payloadType is uploadingClient.announceSDPInfo.audio.fmt
    rtp.feedUnorderedAACBuffer msg, 'upload-client', uploadingClient.announceSDPInfo.audio.fmtpParams
  else
    console.error "Error: Unknown payload type: #{packet.rtpHeader.payloadType} as audio"

onUploadAudioControl = (msg, rinfo) ->
  packets = rtp.parsePackets msg
  for packet in packets
    if packet.rtcpSenderReport?
      if not uploadingClient.uploadingTimestampInfo.audio?
        uploadingClient.uploadingTimestampInfo.audio = {}
      uploadingClient.uploadingTimestampInfo.audio.rtpTimestamp = packet.rtcpSenderReport.rtpTimestamp
      uploadingClient.uploadingTimestampInfo.audio.time = packet.rtcpSenderReport.ntpTimestampInMs

udpVideoDataServer = dgram.createSocket 'udp4'
udpVideoDataServer.on 'error', (err) ->
  console.log "udp video data receiver error: #{err.message}"
  throw err
udpVideoDataServer.on 'message', (msg, rinfo) ->
  onUploadVideoData msg, rinfo
udpVideoDataServer.on 'listening', ->
  addr = udpVideoDataServer.address()
  console.log "udp video data receiver is listening on port #{addr.port}"
udpVideoDataServer.bind config.rtspVideoDataUDPListenPort

udpVideoControlServer = dgram.createSocket 'udp4'
udpVideoControlServer.on 'error', (err) ->
  console.log "udp video control receiver error: #{err.message}"
  throw err
udpVideoControlServer.on 'message', (msg, rinfo) ->
  onUploadVideoControl msg, rinfo
udpVideoControlServer.on 'listening', ->
  addr = udpVideoControlServer.address()
  console.log "udp video control receiver is listening on port #{addr.port}"
udpVideoControlServer.bind config.rtspVideoControlUDPListenPort

udpAudioDataServer = dgram.createSocket 'udp4'
udpAudioDataServer.on 'error', (err) ->
  console.log "udp audio data receiver error: #{err.message}"
  throw err
udpAudioDataServer.on 'message', (msg, rinfo) ->
  onUploadAudioData msg, rinfo
udpAudioDataServer.on 'listening', ->
  addr = udpAudioDataServer.address()
  console.log "udp audio data receiver is listening on port #{addr.port}"
udpAudioDataServer.bind config.rtspAudioDataUDPListenPort

udpAudioControlServer = dgram.createSocket 'udp4'
udpAudioControlServer.on 'error', (err) ->
  console.log "udp audio control receiver error: #{err.message}"
  throw err
udpAudioControlServer.on 'message', (msg, rinfo) ->
  onUploadAudioControl msg, rinfo
udpAudioControlServer.on 'listening', ->
  addr = udpAudioControlServer.address()
  console.log "udp audio control receiver is listening on port #{addr.port}"
udpAudioControlServer.bind config.rtspAudioControlUDPListenPort

server = net.createServer (c) ->
  onClientConnect c

server.on 'error', (err) ->
  console.error "Server error: #{err.message}"
  throw err

console.log "starting rtsp/http server on port #{config.serverPort}"
server.listen config.serverPort, '0.0.0.0', 511, ->
  console.log "server started"

videoSequenceNumber = 0
audioSequenceNumber = 0
TIMESTAMP_ROUNDOFF = 4294967296  # 32 bits

lastVideoRTPTimestamp = null
lastAudioRTPTimestamp = null
videoRTPTimestampInterval = Math.round(90000 / config.videoFrameRate)
audioRTPTimestampInterval = config.audioPeriodSize

getNextVideoSequenceNumber = ->
  num = videoSequenceNumber + 1
  if num > 65535
    num -= 65535
  num

getNextAudioSequenceNumber = ->
  num = audioSequenceNumber + 1
  if num > 65535
    num -= 65535
  num

getNextVideoRTPTimestamp = ->
  if lastVideoRTPTimestamp?
    lastVideoRTPTimestamp + videoRTPTimestampInterval
  else
    0

getNextAudioRTPTimestamp = ->
  if lastAudioRTPTimestamp?
    lastAudioRTPTimestamp + audioRTPTimestampInterval
  else
    0

videoRTPSocket = dgram.createSocket 'udp4'
videoRTPSocket.bind config.videoRTPServerPort
videoRTCPSocket = dgram.createSocket 'udp4'
videoRTCPSocket.bind config.videoRTCPServerPort

audioRTPSocket = dgram.createSocket 'udp4'
audioRTPSocket.bind config.audioRTPServerPort
audioRTCPSocket = dgram.createSocket 'udp4'
audioRTCPSocket.bind config.audioRTCPServerPort

sendVideoPacketWithFragment = (nalUnit, timestamp, marker=true) ->
  ts = timestamp % TIMESTAMP_ROUNDOFF
  lastVideoRTPTimestamp = ts

  if clientsCount is 0
    return

  nalUnitType = nalUnit[0] & 0x1f
  isKeyFrame = nalUnitType is 5
  nal_ref_idc = nalUnit[0] & 0b01100000  # skip ">> 5" operation

  nalUnit = nalUnit.slice 1

  fragmentNumber = 0
  while nalUnit.length > SINGLE_NAL_UNIT_MAX_SIZE
    if ++videoSequenceNumber > 65535
      videoSequenceNumber -= 65535

    fragmentNumber++
    thisNalUnit = nalUnit.slice 0, SINGLE_NAL_UNIT_MAX_SIZE
    nalUnit = nalUnit.slice SINGLE_NAL_UNIT_MAX_SIZE

    # TODO: sequence number should be started from a random number
    rtpData = rtp.createRTPHeader
      marker: false
      payloadType: 97
      sequenceNumber: videoSequenceNumber
      timestamp: ts
      ssrc: null

    rtpData = rtpData.concat rtp.createFragmentationUnitHeader
      nal_ref_idc: nal_ref_idc
      nal_unit_type: nalUnitType
      isStart: fragmentNumber is 1
      isEnd: false

    # Append NAL unit
    thisNalUnitLen = thisNalUnit.length
    rtpBuffer = Buffer.concat [new Buffer(rtpData), thisNalUnit],
      rtp.RTP_HEADER_LEN + 2 + thisNalUnitLen

    if DEBUG_PACKET_DATA
      md5 = crypto.createHash 'md5'
      md5.update thisNalUnit
      tsDiff = ts - lastSentVideoTimestamp
      console.log "video: ts #{tsDiff} md5 #{md5.digest('hex')[0..6]} fragment: #{rtpBuffer.length} bytes marker=false" + (if isKeyFrame then " isKeyFrame=#{isKeyFrame}" else "")
      lastSentVideoTimestamp = ts
    for clientID, client of clients
      if client.isWaitingForKeyFrame and isKeyFrame
        process.stdout.write "KeyFrame"
        client.isPlaying = true
        client.isWaitingForKeyFrame = false

      if client.isPlaying
        rtp.replaceSSRCInRTP rtpBuffer, client.videoSSRC

        client.videoPacketCount++
        client.videoOctetCount += thisNalUnitLen
        if client.useTCPForVideo
          if client.useHTTP
            if client.httpClientType is 'GET'
              sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
          else
            sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
        else
          if client.clientVideoRTPPort?
            videoRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientVideoRTPPort, client.ip, (err, bytes) ->
              if err
                console.log "[videoRTPSend] error: #{err.message}"

  # last packet
  if ++videoSequenceNumber > 65535
    videoSequenceNumber -= 65535

  # TODO: sequence number should be started from a random number
  rtpData = rtp.createRTPHeader
    marker: marker
    payloadType: 97
    sequenceNumber: videoSequenceNumber
    timestamp: ts
    ssrc: null

  rtpData = rtpData.concat rtp.createFragmentationUnitHeader
    nal_ref_idc: nal_ref_idc
    nal_unit_type: nalUnitType
    isStart: false
    isEnd: true

  nalUnitLen = nalUnit.length
  rtpBuffer = Buffer.concat [new Buffer(rtpData), nalUnit],
    rtp.RTP_HEADER_LEN + 2 + nalUnitLen
  if DEBUG_PACKET_DATA
    md5 = crypto.createHash 'md5'
    md5.update nalUnit
    tsDiff = ts - lastSentVideoTimestamp
    console.log "video: ts #{tsDiff} md5 #{md5.digest('hex')[0..6]} fragment-last: #{rtpBuffer.length} bytes marker=#{marker}" + (if isKeyFrame then " isKeyFrame=#{isKeyFrame}" else "")
    lastSentVideoTimestamp = ts
  for clientID, client of clients
    if client.isWaitingForKeyFrame and isKeyFrame
      process.stdout.write "KeyFrame"
      client.isPlaying = true
      client.isWaitingForKeyFrame = false

    if client.isPlaying
      rtp.replaceSSRCInRTP rtpBuffer, client.videoSSRC

      client.videoPacketCount++
      client.videoOctetCount += nalUnitLen
      if client.useTCPForVideo
        if client.useHTTP
          if client.httpClientType is 'GET'
            sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
        else
          sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
      else
        if client.clientVideoRTPPort?
          videoRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientVideoRTPPort, client.ip, (err, bytes) ->
            if err
              console.log "[videoRTPSend] error: #{err.message}"
  return

sendVideoPacketAsSingleNALUnit = (nalUnit, timestamp, marker=true) ->
  if ++videoSequenceNumber > 65535
    videoSequenceNumber -= 65535

  ts = timestamp % TIMESTAMP_ROUNDOFF
  lastVideoRTPTimestamp = ts

  nalUnitType = nalUnit[0] & 0x1f

  if clientsCount is 0
    return

  isKeyFrame = nalUnitType is 5

  # TODO: sequence number should be started from a random number
  rtpHeader = rtp.createRTPHeader
    marker: marker
    payloadType: 97
    sequenceNumber: videoSequenceNumber
    timestamp: ts
    ssrc: null

  nalUnitLen = nalUnit.length
  rtpBuffer = Buffer.concat [new Buffer(rtpHeader), nalUnit],
    rtp.RTP_HEADER_LEN + nalUnitLen
  if DEBUG_PACKET_DATA
    md5 = crypto.createHash 'md5'
    md5.update nalUnit
    tsDiff = ts - lastSentVideoTimestamp
    console.log "video: ts #{tsDiff} md5 #{md5.digest('hex')[0..6]} single: #{rtpBuffer.length} bytes marker=#{marker}" + (if isKeyFrame then " isKeyFrame=#{isKeyFrame}" else "")
    lastSentVideoTimestamp = ts

  for clientID, client of clients
    if client.isWaitingForKeyFrame and isKeyFrame
      process.stdout.write "KeyFrame"
      client.isPlaying = true
      client.isWaitingForKeyFrame = false

    if client.isPlaying
      rtp.replaceSSRCInRTP rtpBuffer, client.videoSSRC

      client.videoPacketCount++
      client.videoOctetCount += nalUnitLen
      if client.useTCPForVideo
        if client.useHTTP
          if client.httpClientType is 'GET'
            sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
        else
          sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
      else
        if client.clientVideoRTPPort?
          videoRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientVideoRTPPort, client.ip, (err, bytes) ->
            if err
              console.error "[videoRTPSend] error: #{err.message}"
  return

# nal_unit_type 7
onSPSNALUnit = (nalUnit) ->
  spsNALUnit = nalUnit
  updateSpropParam nalUnit
  rtmpServer.updateSPS nalUnit
  try
    h264.readSPS nalUnit
  catch e
    console.error "video data error: failed to read SPS"
    console.error e.stack
    return
  sps = h264.getSPS()
  frameSize = h264.getFrameSize sps
  isConfigUpdated = false
  if detectedVideoWidth isnt frameSize.width
    detectedVideoWidth = frameSize.width
    console.log "video width has been changed to #{detectedVideoWidth}"
    config.videoWidth = detectedVideoWidth
    isConfigUpdated = true
  if detectedVideoHeight isnt frameSize.height
    detectedVideoHeight = frameSize.height
    console.log "video height has been changed to #{detectedVideoHeight}"
    config.videoHeight = detectedVideoHeight
    isConfigUpdated = true
  if config.flv.avclevel isnt sps.level_idc
    config.flv.avclevel = sps.level_idc
    console.log "avclevel has been changed to #{config.flv.avclevel}"
    isConfigUpdated = true
  if config.flv.avcprofile isnt sps.profile_idc
    config.flv.avcprofile = sps.profile_idc
    console.log "avcprofile has been changed to #{config.flv.avcprofile}"
    isConfigUpdated = true
  if isConfigUpdated
    updateConfig()

# nal_unit_type 8
onPPSNALUnit = (nalUnit) ->
  ppsNALUnit = nalUnit
  updateSpropParam nalUnit
  rtmpServer.updatePPS nalUnit

sendNALUnitOverRTSP = (nalUnit, pts, dts, marker) ->
  if nalUnit.length >= SINGLE_NAL_UNIT_MAX_SIZE
    sendVideoPacketWithFragment nalUnit, pts, marker  # TODO what about dts?
  else
    sendVideoPacketAsSingleNALUnit nalUnit, pts, marker  # TODO what about dts?

# nal_unit_type 5 must not separated with 7 and 8 which
# share the same timestamp as 5
onReceiveVideoNALUnits = (nalUnits, pts, dts) ->
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
      onSPSNALUnit nalUnit
    else if nalUnitType is h264.NAL_UNIT_TYPE_PPS  # 8
      isPPSSent = true
      onPPSNALUnit nalUnit

    # If this is keyframe but SPS and PPS do not exist in the
    # same timestamp, we insert them before the keyframe.
    # TODO: Send SPS and PPS as an aggregation packet (STAP-A).
    if nalUnitType is 5  # keyframe
      if not isSPSSent  # nal_unit_type 7
        if spsNALUnit?
          sendNALUnitOverRTSP spsNALUnit, pts, dts, false
          # there is a case where timestamps of two keyframes are identical
          # (i.e. nalUnits argument contains multiple keyframes)
          isSPSSent = true
        else
          console.error "Error: SPS is not set"
      if not isPPSSent  # nal_unit_type 8
        if ppsNALUnit?
          sendNALUnitOverRTSP ppsNALUnit, pts, dts, false
          # there is a case where timestamps of two keyframes are identical
          # (i.e. nalUnits argument contains multiple keyframes)
          isPPSSent = true
        else
          console.error "Error: PPS is not set"

    sendNALUnitOverRTSP nalUnit, pts, dts, isLastPacket

  rtmpServer.sendVideoPacket nalUnits, pts, dts

  return

# Takes H.264 NAL units separated by start code (0x000001)
#
# arguments:
#   nalUnit: Buffer
#   pts: timestamp in 90 kHz clock rate (PTS)
onReceiveVideoPacket = (nalUnitGlob, pts, dts) ->
  nalUnits = h264.splitIntoNALUnits nalUnitGlob
  if nalUnits.length is 0
    return
  onReceiveVideoNALUnits nalUnits, pts, dts
  return

updateAudioSampleRate = (sampleRate) ->
  audioClockRate = sampleRate
  config.audioSampleRate = sampleRate

updateAudioChannels = (channels) ->
  config.audioChannels = channels

# pts, dts: in 90KHz clock rate
onReceiveAudioAccessUnits = (accessUnits, pts, dts) ->
  if not config.audioSampleRate?
    throw new Error "audio sample rate isn't detected"

  ptsPerFrame = 90000 / (config.audioSampleRate / 1024)

  # timestamp: RTP timestamp in audioClockRate
  # pts: PTS in 90 kHz clock
  if audioClockRate isnt 90000  # given pts is not in 90 kHz clock
    timestamp = pts * audioClockRate / 90000
  else
    timestamp = pts

  rtpTimePerFrame = 1024

  for accessUnit, i in accessUnits
    if DEBUG_PACKET_DATA
      md5 = crypto.createHash 'md5'
      md5.update accessUnit
      console.log "audio: pts #{pts} md5 #{md5.digest('hex')[0..6]} #{accessUnit.length} bytes"
    rtmpServer.sendAudioPacket accessUnit,
      Math.round(pts + ptsPerFrame * i),
      Math.round(dts + ptsPerFrame * i)

  if clientsCount is 0
    return

  frameGroups = rtp.groupAudioFrames accessUnits
  processedFrames = 0
  for group, i in frameGroups
    concatRawDataBlock = Buffer.concat group

    if ++audioSequenceNumber > 65535
      audioSequenceNumber -= 65535

    ts = Math.round((timestamp + rtpTimePerFrame * processedFrames) % TIMESTAMP_ROUNDOFF)
    processedFrames += group.length
    lastAudioRTPTimestamp = (timestamp + rtpTimePerFrame * processedFrames) % TIMESTAMP_ROUNDOFF

    # TODO dts
    rtpData = rtp.createRTPHeader
      marker: true
      payloadType: 96
      sequenceNumber: audioSequenceNumber
      timestamp: ts
      ssrc: null

    accessUnitLength = concatRawDataBlock.length

    # TODO: maximum size of AAC-hbr is 8191 octets
    # TODO: sequence number should be started from a random number

    audioHeader = rtp.createAudioHeader
      accessUnits: group

    rtpData = rtpData.concat audioHeader

    # Append the access unit (rawDataBlock)
    rtpBuffer = Buffer.concat [new Buffer(rtpData), concatRawDataBlock],
      rtp.RTP_HEADER_LEN + audioHeader.length + accessUnitLength

    for clientID, client of clients
      if client.isPlaying
        rtp.replaceSSRCInRTP rtpBuffer, client.audioSSRC

        client.audioPacketCount++
        client.audioOctetCount += accessUnitLength
        if client.useTCPForAudio
          if client.useHTTP
            if client.httpClientType is 'GET'
              sendDataByTCP client.socket, client.audioTCPDataChannel, rtpBuffer
          else
            sendDataByTCP client.socket, client.audioTCPDataChannel, rtpBuffer
        else
          if client.clientAudioRTPPort?
            audioRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientAudioRTPPort, client.ip, (err, bytes) ->
              if err
                console.error "[audioRTPSend] error: #{err.message}"
  return

# pts, dts: in 90KHz clock rate
onReceiveAudioPacket = (adtsFrameGlob, pts, dts) ->
  adtsFrames = aac.splitIntoADTSFrames adtsFrameGlob
  if adtsFrames.length is 0
    return
  adtsInfo = aac.parseADTSFrame adtsFrames[0]

  if detectedAudioSampleRate isnt adtsInfo.sampleRate
    detectedAudioSampleRate = adtsInfo.sampleRate
    console.log "audio sample rate has been changed to #{detectedAudioSampleRate}"
    updateAudioSampleRate adtsInfo.sampleRate

  if detectedAudioChannels isnt adtsInfo.channels
    detectedAudioChannels = adtsInfo.channels
    console.log "audio channels has been changed to #{detectedAudioChannels}"
    updateAudioChannels adtsInfo.channels

  if config.audioObjectType isnt adtsInfo.audioObjectType
    config.audioObjectType = adtsInfo.audioObjectType
    console.log "audio object type has been changed to #{config.audioObjectType}"
    updateConfig()

  rtpTimePerFrame = 1024

  rawDataBlocks = []
  for adtsFrame, i in adtsFrames
    rawDataBlock = adtsFrame[7..]
    rawDataBlocks.push rawDataBlock

  onReceiveAudioAccessUnits rawDataBlocks, pts, dts

h264Buffer = []

rtp.on 'h264_nal_units', (clientId, nalUnits, rtpTimestamp) ->
  if not uploadingClient?
    return
  sendTime = getVideoSendTimeForUploadingRTPTimestamp rtpTimestamp
  diffTimeInMs = sendTime - Date.now()
  calculatedPTS = rtpTimestamp - uploadingClient.videoRTPStartTimestamp
  if diffTimeInMs >= 20  # later than 20 ms
    setTimeout ->
      onReceiveVideoNALUnits nalUnits, calculatedPTS, calculatedPTS
    , diffTimeInMs
  else
    onReceiveVideoNALUnits nalUnits, calculatedPTS, calculatedPTS

rtp.on 'aac_access_units', (clientId, accessUnits, rtpTimestamp) ->
  if not uploadingClient?
    return
  sendTime = getAudioSendTimeForUploadingRTPTimestamp rtpTimestamp
  diffTimeInMs = sendTime - Date.now()
  calculatedPTS = Math.round (rtpTimestamp - uploadingClient.audioRTPStartTimestamp) * 90000 / audioClockRate
  if diffTimeInMs >= 20  # later than 20ms
    setTimeout ->
      onReceiveAudioAccessUnits accessUnits, calculatedPTS, calculatedPTS
    , diffTimeInMs
  else
    onReceiveAudioAccessUnits accessUnits, calculatedPTS, calculatedPTS

pad = (digits, n) ->
  n = n + ''
  while n.length < digits
    n = '0' + n
  n

getISO8601DateString = ->
  d = new Date
  str = "#{d.getUTCFullYear()}-#{pad 2, d.getUTCMonth()+1}-#{pad 2, d.getUTCDate()}T" + \
        "#{pad 2, d.getUTCHours()}:#{pad 2, d.getUTCMinutes()}:#{pad 2, d.getUTCSeconds()}." + \
        "#{pad 4, d.getUTCMilliseconds()}Z"
  str

consumePathname = (uri, callback) ->
  pathname = url.parse(uri).pathname[1..]

  # TODO: Implement authentication yourself
  authSuccess = true

  if authSuccess
    callback null
  else
    callback new Error 'Invalid access'

respondWithUnsupportedTransport = (callback, headers) ->
  res = 'RTSP/1.0 461 Unsupported Transport\n'
  if headers?
    for name, value of headers
      res += "#{name}: #{value}\n"
  res += '\n'
  callback null, res.replace /\n/g, '\r\n'

notFound = (protocol, opts, callback) ->
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

respondWithNotFound = (protocol='RTSP', callback) ->
  res = """
  #{protocol}/1.0 404 Not Found
  Content-Length: 9
  Content-Type: text/plain

  Not Found
  """.replace /\n/g, "\r\n"
  callback null, res

# Check if the remote address of the given socket is private
isPrivateNetwork = (socket) ->
  if /^(10\.|192\.168\.|127\.0\.0\.)/.test socket.remoteAddress
    return true
  if (match = /^172.(\d+)\./.exec socket.remoteAddress)?
    num = parseInt match[1]
    if 16 <= num <= 31
      return true
  return false

respond = (socket, req, callback) ->
  client = clients[socket.clientID]
  if req.method is 'OPTIONS'
    res = """
    RTSP/1.0 200 OK
    CSeq: #{req.headers.cseq}
    Public: DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE, ANNOUNCE, RECORD


    """.replace /\n/g, "\r\n"
    callback null, res
  else if (req.method is 'POST') and (req.protocol.indexOf('HTTP') isnt -1)
    pathname = url.parse(req.uri).pathname
    if config.enableRTMPT and /^\/(?:fcs|open|idle|send|close)\//.test pathname
      rtmpServer.handleRTMPTRequest req, (err, output, resultOpts) ->
        if err
          console.error "[rtmpt] Error: #{err}"
          respondWithNotFound 'HTTP', (err, response) ->
            callback response, resultOpts
        else
          callback err, output, resultOpts
      return
    # TODO: POST/GET connections may be re-initialized
    # Incoming channel
    if not httpSessions[req.headers['x-sessioncookie']]?
      respondWithNotFound 'HTTP', callback
      return
    socket.isAuthenticated = true
    client.sessionCookie = req.headers['x-sessioncookie']
    httpSessions[client.sessionCookie].post = client
    getClient = httpSessions[client.sessionCookie].get
    # Make circular reference
    getClient.postClient = client
    client.getClient = getClient
    client.useHTTP = true
    client.httpClientType = 'POST'
    client.isSendingPOST = true

    if req.body?
      handlePOSTData client, req.body
    # There's no response from the server
  else if (req.method is 'GET') and (req.protocol.indexOf('HTTP') isnt -1)  # GET and HTTP
    pathname = url.parse(req.uri).pathname
    if pathname is '/crossdomain.xml'
      httpHandler.respondCrossDomainXML req, (err, output) ->
        callback err, output,
          close: req.headers.connection?.toLowerCase() isnt 'keep-alive'
      return
    else if (match = /^\/live\/(.*)$/.exec req.uri)?
      # Outgoing channel
      consumePathname req.uri, (err) ->
        if err
          console.warn "Can't consume pathname"
          respondWithNotFound 'HTTP', callback
          return
        client.sessionCookie = req.headers['x-sessioncookie']
        client.useHTTP = true
        client.httpClientType = 'GET'
        if httpSessions[client.sessionCookie]?
          postClient = httpSessions[client.sessionCookie].post
          if postClient?
            postClient.getClient = client
            client.postClient = postClient
        else
          httpSessions[client.sessionCookie] = {}
        httpSessions[client.sessionCookie].get = client
        socket.isAuthenticated = true
        res = """
        HTTP/1.0 200 OK
        Server: #{serverName}
        Connection: close
        Date: #{getDateHeader()}
        Cache-Control: no-store
        Pragma: no-cache
        Content-Type: application/x-rtsp-tunnelled


        """.replace /\n/g, "\r\n"

        # Do not close the connection
        callback null, res
    else
      httpHandler.handlePath pathname, req, (err, output) ->
        callback err, output,
          close: req.headers.connection?.toLowerCase() isnt 'keep-alive'
      return

#      console.warn "Routing failed: #{req.uri}"
#      isKeepAlive = req.headers.connection?.toLowerCase() is 'keep-alive'
#      opts = { keepalive: isKeepAlive }
#      notFound 'HTTP', opts, (err, content) ->
#        callback null, content,
#          close: not isKeepAlive
#      return

  else if req.method is 'DESCRIBE'  # DESCRIBE for RTSP, GET for HTTP
    consumePathname req.uri, (err) ->
      if err
        respondWithNotFound 'RTSP', callback
        return
      socket.isAuthenticated = true
      client.bandwidth = req.headers.bandwidth

      sdpData =
        username      : '-'
        sessionID     : client.sessionID
        sessionVersion: client.sessionID
        addressType   : 'IP4'
        unicastAddress: getMeaningfulIPTo socket

      if isAudioStarted
        sdpData.hasAudio          = true
        sdpData.audioPayloadType  = 96
        sdpData.audioEncodingName = 'mpeg4-generic'
        sdpData.audioClockRate    = audioClockRate
        sdpData.audioChannels     = config.audioChannels
        sdpData.audioSampleRate   = config.audioSampleRate
        sdpData.audioObjectType   = config.audioObjectType

      if isVideoStarted
        sdpData.hasVideo                = true
        sdpData.videoPayloadType        = 97
        sdpData.videoEncodingName       = 'H264'  # must be H264
        sdpData.videoClockRate          = 90000  # must be 90000
        sdpData.videoProfileLevelId     = PROFILE_LEVEL_ID
        sdpData.videoSpropParameterSets = spropParameterSets
        sdpData.videoHeight             = config.videoHeight
        sdpData.videoWidth              = config.videoWidth
        sdpData.videoFrameRate          = config.videoFrameRate.toFixed 1

      body = sdp.createSDP sdpData

      if /^HTTP\//.test req.protocol
        res = 'HTTP/1.0 200 OK\n'
      else
        res = 'RTSP/1.0 200 OK\n'
      if req.headers.cseq?
        res += "CSeq: #{req.headers.cseq}\n"
      dateHeader = getDateHeader()
      res += """
      Content-Base: #{req.uri}/
      Content-Length: #{body.length}
      Content-Type: application/sdp
      Date: #{dateHeader}
      Expires: #{dateHeader}
      Session: #{client.sessionID};timeout=60
      Server: #{serverName}
      Cache-Control: no-cache


      """.replace /\n/g, "\r\n"

      callback null, res + body
  else if req.method is 'SETUP'
    if not socket.isAuthenticated
      respondWithNotFound 'RTSP', callback
      return
    serverPort = null
    track = null

    if DEBUG_DISABLE_UDP_TRANSPORT and
    (not /\bTCP\b/.test req.headers.transport)
      # Disable UDP transport and force the client to switch to TCP transport
      console.log "Unsupported transport: UDP is disabled"
      respondWithUnsupportedTransport callback, {CSeq: req.headers.cseq}
      return

    mode = 'play'
    if (match = /;mode=([^;]*)/.exec req.headers.transport)?
      mode = match[1].toUpperCase()  # PLAY or RECORD

    if mode is 'RECORD'
      sdpInfo = client.announceSDPInfo
      if (match = /\/([^/]+)$/.exec req.uri)?
        streamId = match[1]
        mediaType = null
        for media in sdpInfo.media
          if media.attributes?.control is streamId
            mediaType = media.media
            break
        if not mediaType?
          throw new Error "streamid not found: #{streamId}"
      else
        throw new Error "Unknown URI: #{req.uri}"

      uploadingClient.uploadingChannels = {}
      if (match = /;interleaved=(\d)-(\d)/.exec req.headers.transport)?
        if mediaType is 'video'
          uploadingClient.uploadingChannels.videoData = parseInt match[1]
          uploadingClient.uploadingChannels.videoControl = parseInt match[2]
        else  # audio
          uploadingClient.uploadingChannels.audioData = parseInt match[1]
          uploadingClient.uploadingChannels.audioControl = parseInt match[2]
        # interleaved mode (use current connection)
        transportHeader = req.headers.transport.replace(/mode=[^;]*/, '')
      else
        if mediaType is 'video'
          [dataPort, controlPort] = [config.rtspVideoDataUDPListenPort, config.rtspVideoControlUDPListenPort]
        else  # audio
          [dataPort, controlPort] = [config.rtspAudioDataUDPListenPort, config.rtspAudioControlUDPListenPort]
        transportHeader = req.headers.transport.replace(/mode=[^;]*/, '') +
                          "source=#{getMeaningfulIPTo socket}" +
                          ";server_port=#{dataPort}-#{controlPort}"
      dateHeader = getDateHeader()
      res = """
      RTSP/1.0 200 OK
      Date: #{dateHeader}
      Expires: #{dateHeader}
      Transport: #{transportHeader}
      Session: #{client.sessionID};timeout=60
      CSeq: #{req.headers.cseq}
      Server: #{serverName}
      Cache-Control: no-cache


      """.replace /\n/g, "\r\n"
      callback null, res
    else
      if /trackID=1/.test req.uri  # audio
        track = 'audio'
        if client.useHTTP
          ssrc = client.getClient.audioSSRC
        else
          ssrc = client.audioSSRC
        serverPort = "#{config.audioRTPServerPort}-#{config.audioRTCPServerPort}"
        if (match = /client_port=(\d+)-(\d+)/.exec req.headers.transport)?
          client.clientAudioRTPPort = parseInt match[1]
          client.clientAudioRTCPPort = parseInt match[2]
      else  # video
        track = 'video'
        if client.useHTTP
          ssrc = client.getClient.videoSSRC
        else
          ssrc = client.videoSSRC
        serverPort = "#{config.videoRTPServerPort}-#{config.videoRTCPServerPort}"
        if (match = /client_port=(\d+)-(\d+)/.exec req.headers.transport)?
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
                          ";source=#{getMeaningfulIPTo socket}" +
                          ";server_port=#{serverPort};ssrc=#{zeropad(8, ssrc.toString(16))}"
      dateHeader = getDateHeader()
      res = """
      RTSP/1.0 200 OK
      Date: #{dateHeader}
      Expires: #{dateHeader}
      Transport: #{transportHeader}
      Session: #{client.sessionID};timeout=60
      CSeq: #{req.headers.cseq}
      Server: #{serverName}
      Cache-Control: no-cache


      """.replace /\n/g, "\r\n"
      callback null, res
    # after the response, client will send one or two RTP packets to this server
  else if req.method is 'PLAY'
    if not socket.isAuthenticated
      respondWithNotFound 'RTSP', callback
      return

    preventFromPlaying = false

#    if (req.headers['user-agent']?.indexOf('QuickTime') > -1) and
#    not client.getClient?.useTCPForVideo
#      # QuickTime produces poor quality image over UDP.
#      # So we let QuickTime switch transport.
#      console.log "[[[ UDP is discouraged for QuickTime ]]]"
#      preventFromPlaying = true

#    Range: clock=#{getISO8601DateString()}-
    # RTP-Info is defined in Section 12.33 in RFC 2326
    # seq: Indicates the sequence number of the first packet of the stream.
    # rtptime: Indicates the RTP timestamp corresponding to the time value in
    #          the Range response header.
    # TODO: Send this response after the first packet for this stream arrives
    baseUrl = req.uri.replace /\/$/, ''
    rtpInfos = []
    if isAudioStarted
      rtpInfos.push "url=#{baseUrl}/trackID=1;seq=#{getNextAudioSequenceNumber()};rtptime=#{getNextAudioRTPTimestamp()}"
    if isVideoStarted
      rtpInfos.push "url=#{baseUrl}/trackID=2;seq=#{getNextVideoSequenceNumber()};rtptime=#{getNextVideoRTPTimestamp()}"
    res = """
    RTSP/1.0 200 OK
    Range: npt=0.0-
    Session: #{client.sessionID};timeout=60
    CSeq: #{req.headers.cseq}
    RTP-Info: #{rtpInfos.join ','}
    Server: #{serverName}
    Cache-Control: no-cache


    """.replace /\n/g, "\r\n"
    if not preventFromPlaying
      if client.useHTTP
        console.log "[[[ start sending to #{client.getClient.id} through GET ]]]"
        if ENABLE_START_PLAYING_FROM_KEYFRAME and isVideoStarted
          client.getClient.isWaitingForKeyFrame = true
        else
          client.getClient.isPlaying = true
      else if client.useTCPForVideo  # or client.useTCPForAudio?
        console.log "[[[ start sending to #{client.id} by TCP ]]]"
        if ENABLE_START_PLAYING_FROM_KEYFRAME and isVideoStarted
          client.isWaitingForKeyFrame = true
        else
          client.isPlaying = true
      else
        console.log "[[[ start sending to #{client.id} by UDP ]]]"
        if ENABLE_START_PLAYING_FROM_KEYFRAME and isVideoStarted
          client.isWaitingForKeyFrame = true
        else
          client.isPlaying = true
      if client.useHTTP
        startSendingRTCP client.getClient
      else
        startSendingRTCP client
    else
      console.log "[[[ NOT PLAYING ]]]"
    callback null, res
  else if req.method is 'PAUSE'
    if not socket.isAuthenticated
      respondWithNotFound 'RTSP', callback
      return
    stopSendingRTCP client
    if client.useHTTP
      client.getClient.isWaitingForKeyFrame = false
      client.getClient.isPlaying = false
    else
      client.isWaitingForKeyFrame = false
      client.isPlaying = false
    res = """
    RTSP/1.0 200 OK
    Session: #{client.sessionID};timeout=60
    CSeq: #{req.headers.cseq}
    Cache-Control: no-cache


    """.replace /\n/g, "\r\n"
    callback null, res
  else if req.method is 'TEARDOWN'
    if client is uploadingClient
      console.log "[rtsp] client finished to upload streams"
      uploadingClient = null
    if not socket.isAuthenticated
      respondWithNotFound 'RTSP', callback
      return
    if client.useHTTP
      client.getClient.isWaitingForKeyFrame = false
      client.getClient.isPlaying = false
    else
      client.isWaitingForKeyFrame = false
      client.isPlaying = false
    res = """
    RTSP/1.0 200 OK
    Session: #{client.sessionID};timeout=60
    CSeq: #{req.headers.cseq}
    Cache-Control: no-cache


    """.replace /\n/g, "\r\n"
    callback null, res
  else if req.method is 'ANNOUNCE'
    resetStreams()
    rtp.clearAllUnorderedPacketBuffers()

    sdpInfo = sdp.parse req.body

    for media in sdpInfo.media
      if media.media is 'video'
        sdpInfo.video = media
        if media.fmtpParams?['sprop-parameter-sets']?
          nalUnits = h264.parseSpropParameterSets media.fmtpParams['sprop-parameter-sets']
          for nalUnit in nalUnits
            nalUnitType = nalUnit[0] & 0x1f
            switch nalUnitType
              when h264.NAL_UNIT_TYPE_SPS  # 7
                onSPSNALUnit nalUnit
              when h264.NAL_UNIT_TYPE_PPS  # 8
                onPPSNALUnit nalUnit
              else
                console.warn "unknown nal_unit_type #{nalUnitType} in sprop-parameter-sets"
      else if media.media is 'audio'
        sdpInfo.audio = media

        if not media.clockRate?
          console.error "Error: rtpmap attribute in SDP must have audio clock rate; assuming 44100"
          media.clockRate = 44100
        detectedAudioSampleRate = media.clockRate
        console.log "audio sample rate has been changed to #{detectedAudioSampleRate}"
        updateAudioSampleRate detectedAudioSampleRate

        if not media.audioChannels?
          console.error "Error: rtpmap attribute in SDP must have audio channels; assuming 2"
          media.audioChannels = 2
        detectedAudioChannels = media.audioChannels
        console.log "audio channels has been changed to #{detectedAudioChannels}"
        updateAudioChannels detectedAudioChannels

        if not media.fmtpParams?
          console.error "Error: fmtp attribute does not exist in SDP"
          media.fmtpParams = {}

        if media.fmtpParams.config?
          audioSpecificConfig = rtp.parseAACConfig media.fmtpParams.config
          config.audioObjectType = audioSpecificConfig.audioObjectType
        else
          console.error "Error: fmtp attribute in SDP does not have config parameter; assuming audioObjectType=2"
          config.audioObjectType = 2
        console.log "audio object type has been changed to #{config.audioObjectType}"

        if media.fmtpParams.sizelength?
          media.fmtpParams.sizelength = parseInt media.fmtpParams.sizelength
        else
          console.error "Error: fmtp attribute in SDP must have sizelength parameter; assuming 13"
          media.fmtpParams.sizelength = 13
        if media.fmtpParams.indexlength?
          media.fmtpParams.indexlength = parseInt media.fmtpParams.indexlength
        else
          console.error "Error: fmtp attribute in SDP must have indexlength parameter; assuming 3"
          media.fmtpParams.indexlength = 3
        if media.fmtpParams.indexdeltalength?
          media.fmtpParams.indexdeltalength = parseInt media.fmtpParams.indexdeltalength
        else
          console.error "Error: fmtp attribute in SDP must have indexdeltalength parameter; assuming 3"
          media.fmtpParams.indexdeltalength = 3

        updateConfig()

    client.announceSDPInfo = sdpInfo
    uploadingClient = client
    uploadingClient.uploadingTimestampInfo = {}

    socket.isAuthenticated = true

    res = """
    RTSP/1.0 200 OK
    CSeq: #{req.headers.cseq}


    """.replace /\n/g, "\r\n"
    callback null, res
  else if req.method is 'RECORD'
    console.log "[rtsp] client started to upload streams"
    onReceiveVideoControlBuffer()
    onReceiveAudioControlBuffer()
    res = """
    RTSP/1.0 200 OK
    Session: #{client.sessionID};timeout=60
    CSeq: #{req.headers.cseq}
    Server: #{serverName}
    Cache-Control: no-cache


    """.replace /\n/g, "\r\n"
    callback null, res
  else
    console.warn "method not implemented: #{req.method}"
    respondWithNotFound 'RTSP', callback

parseRequest = (data) ->
  [headerPart, body] = data.split '\r\n\r\n'

  lines = headerPart.split /\r\n/
  [method, uri, protocol] = lines[0].split /\s+/
  headers = {}
  for line, i in lines
    continue if i is 0
    continue if /^\s*$/.test line
    params = line.split ": "
    headers[params[0].toLowerCase()] = params[1]

  try
    decodedURI = decodeURIComponent uri
  catch e
    console.log "error: failed to decode URI: #{uri}"
    return null

  return {
    method: method
    uri: decodedURI
    protocol: protocol
    headers: headers
    body: body
    headerBytes: headerPart.length  # TODO
  }
