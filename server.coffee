# RTSP and RTMP/RTMPE/RTMPT/RTMPTE server implementation.
# Also combined with HTTP server as this server is supposed
# to be run on port 80.

net    = require 'net'
dgram  = require 'dgram'
fs     = require 'fs'
os     = require 'os'
crypto = require 'crypto'
url    = require 'url'
path   = require 'path'
spawn  = require('child_process').spawn

SERVER_PORT = 8000

# Server name to be embedded in response header
SERVER_NAME = "node-rtsp-rtmp-server/0.0.1"

# 720p
WIDTH = 480
HEIGHT = 360
FRAMERATE = 30

AUDIO_SAMPLE_RATE = 22050
AUDIO_PERIOD_SIZE = 1024

AUDIO_CLOCK_RATE = 90000

DEBUG_DROP_ALL_PACKETS = false

ENABLE_START_PLAYING_FROM_KEYFRAME = false

SINGLE_NAL_UNIT_MAX_SIZE = 1358

# TODO: clear old sessioncookies
SESSION_COOKIE_TIMEOUT = 600000  # 10 minutes
RTCP_SENDER_REPORT_INTERVAL = 5000  # milliseconds
KEEPALIVE_TIMEOUT = 30000

DAY_NAMES = [
  'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'
]

MONTH_NAMES = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
]

# UNIX sockets used for receiving audio and video packets
VIDEO_RECEIVER_PATH = '/tmp/node_rtsp_rtmp_videoReceiver'
VIDEO_CONTROL_PATH = '/tmp/node_rtsp_rtmp_videoControl'
AUDIO_RECEIVER_PATH = '/tmp/node_rtsp_rtmp_audioReceiver'
AUDIO_CONTROL_PATH = '/tmp/node_rtsp_rtmp_audioControl'

RTMPServer = require './rtmp'
rtmpServer = new RTMPServer
rtmpServer.start ->
  console.log "RTMP server is started"

HTTPHandler = require './http'
httpHandler = new HTTPHandler

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
#   3) level_idc = 30 (Level 3.0)
PROFILE_LEVEL_ID = '42C01E'  # Baseline Profile, Level 3.0
# PROFILE_LEVEL_ID will be retrieved from SPS packet (NAL unit type 7) from byte 1 to 3

spropParameterSets = ''  # will be populated later

addSpropParam = (buf) ->
  nalUnitType = buf[0] & 0x1f
  if nalUnitType is 7  # SPS packet
    PROFILE_LEVEL_ID = buf[1..3].toString('hex').toUpperCase()
    console.log "PROFILE_LEVEL_ID has been updated to #{PROFILE_LEVEL_ID}"
  if spropParameterSets.indexOf(',') isnt -1
    console.warn "[warning] sprop is already filled. sprop=#{spropParameterSets} buf=#{buf.toString 'base64'}"
    return
  if spropParameterSets isnt ''
    spropParameterSets += ','
  spropParameterSets += buf.toString 'base64'

clientsCount = 0
clients = {}
httpSessions = {}

serverAudioRTPPort  = 7042  # even
serverAudioRTCPPort = 7043  # odd and contiguous
serverVideoRTPPort  = 7044  # even
serverVideoRTCPPort = 7045  # odd and contiguous

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
  ifaces = os.networkInterfaces()

  if ifaces.wlan0?
    for addr in ifaces.wlan0
      if addr.family is 'IPv4'
        return addr.address

  if ifaces.eth0?
    for addr in ifaces.eth0
      if addr.family is 'IPv4'
        return addr.address

  "127.0.0.1"

getExternalIP = ->
  "127.0.0.1" # TODO: Fetch this from UPnP or something

EPOCH = 2208988800
NTP_SCALE_FRAC = 4294.967295

timeForVideoRTPZero = null
timeForAudioRTPZero = null

getNTPTimestamp = (time) ->
  sec = Math.round(time / 1000)
  ms = time - (sec * 1000)
  ntp_sec = sec + EPOCH
  ntp_usec = Math.round(ms * 1000 * NTP_SCALE_FRAC)
  return [ntp_sec, ntp_usec]

getVideoRTPTimestamp = (time) ->
  if not timeForVideoRTPZero?
    throw new Error "timeForVideoRTPZero is not set"
  ts = Math.round (time - timeForVideoRTPZero) * 90 % TIMESTAMP_ROUNDOFF
  ts

getAudioRTPTimestamp = (time) ->
  if not timeForAudioRTPZero?
    throw new Error "timeForAudioRTPZero is not set"
  ts = Math.round ((time - timeForAudioRTPZero) * AUDIO_CLOCK_RATE / 1000) % TIMESTAMP_ROUNDOFF
  ts

sendVideoSenderReport = (client) ->
  if not timeForVideoRTPZero?
    return

  time = new Date().getTime()
  ntp_ts = getNTPTimestamp time
  rtp_ts = getVideoRTPTimestamp time
  length = 6  # packet bytes / 4 (32 bits) - 1
  data = [
    # [header]
    # version(2), padding(1), reception report count(5)
    0x80,
    # packet type(8)
    200,
    # length(16)
    length >> 8, length & 0xff,
    # SSRC of sender(32)
    (client.videoSSRC >>> 24) & 0xff, (client.videoSSRC >>> 16) & 0xff,
    (client.videoSSRC >>> 8) & 0xff, client.videoSSRC & 0xff,

    # [sender info]
    # NTP timestamp(64)
    (ntp_ts[0] >>> 24) & 0xff, (ntp_ts[0] >>> 16) & 0xff, (ntp_ts[0] >>> 8) & 0xff, ntp_ts[0] & 0xff,
    (ntp_ts[1] >>> 24) & 0xff, (ntp_ts[1] >>> 16) & 0xff, (ntp_ts[1] >>> 8) & 0xff, ntp_ts[1] & 0xff,
    # RTP timestamp(32)
    (rtp_ts >>> 24) & 0xff, (rtp_ts >>> 16) & 0xff, (rtp_ts >>> 8) & 0xff, rtp_ts & 0xff,
    # sender's packet count(32)
    (client.videoPacketCount >>> 24) & 0xff, (client.videoPacketCount >>> 16) & 0xff,
    (client.videoPacketCount >>> 8) & 0xff, client.videoPacketCount & 0xff,
    # sender's octet count(32)
    (client.videoOctetCount >>> 24) & 0xff, (client.videoOctetCount >>> 16) & 0xff,
    (client.videoOctetCount >>> 8) & 0xff, client.videoOctetCount & 0xff,
  ]
  buf = new Buffer data
  if client.useTCPForVideo
    if client.useHTTP
      if client.httpClientType is 'GET'
        sendDataByTCP client.socket, client.videoTCPControlChannel, buf
    else
      sendDataByTCP client.socket, client.videoTCPControlChannel, buf
  else
    videoRTCPSocket.send buf, 0, buf.length, client.clientVideoRTCPPort, client.ip, (err, bytes) ->
      if err
        console.error "[videoRTCPSend] error: #{err.message}"

sendAudioSenderReport = (client) ->
  if not timeForAudioRTPZero?
    return

  time = new Date().getTime()
  ntp_ts = getNTPTimestamp time
  rtp_ts = getAudioRTPTimestamp(time)
  length = 6  # packet bytes / 4 (32 bits) - 1
  data = [
    # [header]
    # version(2), padding(1), reception report count(5)
    0x80,
    # packet type(8)
    200,
    # length(16)
    length >> 8, length & 0xff,
    # SSRC of sender(32)
    (client.audioSSRC >>> 24) & 0xff, (client.audioSSRC >>> 16) & 0xff,
    (client.audioSSRC >>> 8) & 0xff, client.audioSSRC & 0xff,

    # [sender info]
    # NTP timestamp(64)
    (ntp_ts[0] >>> 24) & 0xff, (ntp_ts[0] >>> 16) & 0xff, (ntp_ts[0] >>> 8) & 0xff, ntp_ts[0] & 0xff,
    (ntp_ts[1] >>> 24) & 0xff, (ntp_ts[1] >>> 16) & 0xff, (ntp_ts[1] >>> 8) & 0xff, ntp_ts[1] & 0xff,
    # RTP timestamp(32)
    (rtp_ts >>> 24) & 0xff, (rtp_ts >>> 16) & 0xff, (rtp_ts >>> 8) & 0xff, rtp_ts & 0xff,
    # sender's packet count(32)
    (client.audioPacketCount >>> 24) & 0xff, (client.audioPacketCount >>> 16) & 0xff,
    (client.audioPacketCount >>> 8) & 0xff, client.audioPacketCount & 0xff,
    # sender's octet count(32)
    (client.audioOctetCount >>> 24) & 0xff, (client.audioOctetCount >>> 16) & 0xff,
    (client.audioOctetCount >>> 8) & 0xff, client.audioOctetCount & 0xff,
  ]
  buf = new Buffer data
  if client.useTCPForAudio
    if client.useHTTP
      if client.httpClientType is 'GET'
        sendDataByTCP client.socket, client.audioTCPControlChannel, buf
    else
      sendDataByTCP client.socket, client.audioTCPControlChannel, buf
  else
    audioRTCPSocket.send buf, 0, buf.length, client.clientAudioRTCPPort, client.ip, (err, bytes) ->
      if err
        console.error "[audioRTCPSend] error: #{err.message}"

stopSendingRTCP = (client) ->
  if client.timeoutID?
    clearTimeout client.timeoutID
    client.timeoutID = null

sendSenderReports = (client) ->
  if not client.timeoutID?
    return

  sendAudioSenderReport client
  sendVideoSenderReport client

  client.timeoutID = setTimeout ->
    sendSenderReports client
  , RTCP_SENDER_REPORT_INTERVAL

startSendingRTCP = (client) ->
  stopSendingRTCP client

  sendSenderReports client

onReceiveVideoRTCP = (buf) ->
  # TODO: handle BYE message

onReceiveAudioRTCP = (buf) ->
  # TODO: handle BYE message

videoFrames = 0
audioFrames = 0
lastVideoStatsTime = null
lastAudioStatsTime = null

onReceiveVideoBuffer = (buf) ->
  # Using own format
  # pts (6 bytes)
  # NAL unit (remaining)
  pts = buf[0] * 0x010000000000 + \
        buf[1] * 0x0100000000   + \
        buf[2] * 0x01000000     + \
        buf[3] * 0x010000       + \
        buf[4] * 0x0100         + \
        buf[5]
  nalUnit = buf.slice 6
  onReceiveVideoPacket nalUnit, pts

onReceiveAudioBuffer = (buf) ->
  # Using own format
  # pts (6 bytes)
  # Access Unit == raw_data_block (remaining)
  pts = buf[0] * 0x010000000000 + \
        buf[1] * 0x0100000000   + \
        buf[2] * 0x01000000     + \
        buf[3] * 0x010000       + \
        buf[4] * 0x0100         + \
        buf[5]
  if AUDIO_CLOCK_RATE isnt 90000
    pts = pts * AUDIO_CLOCK_RATE / 90000
  rawDataBlock = buf.slice 6
  onReceiveAudioPacket rawDataBlock, pts

videoReceiveServer = net.createServer (c) ->
  console.log "new videoReceiveServer connection"
  buf = null
  c.on 'close', ->
    console.log "videoReceiveServer connection closed"
  c.on 'data', (data) ->
    if DEBUG_DROP_ALL_PACKETS
      return
    if buf?
      buf = Buffer.concat [buf, data], buf.length + data.length
    else
      buf = data
    if buf.length >= 3
      loop
        payloadSize = buf[0] * 0x10000 + buf[1] * 0x100 + buf[2]
        totalSize = payloadSize + 3  # 3 bytes for payload size
        if buf.length >= totalSize
          onReceiveVideoBuffer buf.slice 3, totalSize  # 3 bytes for payload size
          if buf.length > totalSize
            buf = buf.slice totalSize
          else
            buf = null
            break
        else
          break

if fs.existsSync VIDEO_RECEIVER_PATH
  console.log "unlink #{VIDEO_RECEIVER_PATH}"
  fs.unlinkSync VIDEO_RECEIVER_PATH
videoReceiveServer.listen VIDEO_RECEIVER_PATH, ->
  fs.chmodSync VIDEO_RECEIVER_PATH, '777'
  console.log "videoReceiveServer is listening"

videoControlServer = net.createServer (c) ->
  console.log "new videoControl connection"
  c.on 'close', ->
    console.log "videoControl connection closed"
  c.on 'data', (data) ->
    if data[0] is 1  # timestamp information
      time  = data[1] * 0x0100000000000000  # this loses some precision
      time += data[2] * 0x01000000000000
      time += data[3] * 0x010000000000
      time += data[4] * 0x0100000000
      time += data[5] * 0x01000000
      time += data[6] * 0x010000
      time += data[7] * 0x0100
      time += data[8]
      lastVideoStatsTime = new Date().getTime()
      timeForVideoRTPZero = time / 1000
      timeForAudioRTPZero = timeForVideoRTPZero
      console.log "timeForVideoRTPZero: #{timeForVideoRTPZero}"
      spropParameterSets = ''
      rtmpServer.startStream timeForVideoRTPZero
if fs.existsSync VIDEO_CONTROL_PATH
  console.log "unlink #{VIDEO_CONTROL_PATH}"
  fs.unlinkSync VIDEO_CONTROL_PATH
videoControlServer.listen VIDEO_CONTROL_PATH, ->
  fs.chmodSync VIDEO_CONTROL_PATH, '777'
  console.log "videoControlServer is listening"

audioReceiveServer = net.createServer (c) ->
  console.log "new audioReceiveServer connection"
  buf = null
  c.on 'close', ->
    console.log "audioReceiveServer connection closed"
  c.on 'data', (data) ->
    if DEBUG_DROP_ALL_PACKETS
      return
    if buf?
      buf = Buffer.concat [buf, data], buf.length + data.length
    else
      buf = data
    if buf.length >= 3
      loop
        payloadSize = buf[0] * 0x10000 + buf[1] * 0x100 + buf[2]
        totalSize = payloadSize + 3  # 3 bytes for payload size
        if buf.length >= totalSize
          onReceiveAudioBuffer buf.slice 3, totalSize  # 3 bytes for payload size
          if buf.length > totalSize
            buf = buf.slice totalSize
          else
            buf = null
            break
        else
          break

if fs.existsSync AUDIO_RECEIVER_PATH
  console.log "unlink #{AUDIO_RECEIVER_PATH}"
  fs.unlinkSync AUDIO_RECEIVER_PATH
audioReceiveServer.listen AUDIO_RECEIVER_PATH, ->
  fs.chmodSync AUDIO_RECEIVER_PATH, '777'
  console.log "audioReceiveServer is listening"

audioControlServer = net.createServer (c) ->
  console.log "new audioControl connection"
  c.on 'close', ->
    console.log "audioControl connection closed"
  c.on 'data', (data) ->
    if data[0] is 1  # timestamp information
      time  = data[1] * 0x0100000000000000  # this loses some precision
      time += data[2] * 0x01000000000000
      time += data[3] * 0x010000000000
      time += data[4] * 0x0100000000
      time += data[5] * 0x01000000
      time += data[6] * 0x010000
      time += data[7] * 0x0100
      time += data[8]
      lastAudioStatsTime = new Date().getTime()
      timeForAudioRTPZero = time / 1000
      timeForVideoRTPZero = timeForAudioRTPZero
      console.log "timeForAudioRTPZero: #{timeForAudioRTPZero}"
      rtmpServer.startStream timeForAudioRTPZero
if fs.existsSync AUDIO_CONTROL_PATH
  console.log "unlink #{AUDIO_CONTROL_PATH}"
  fs.unlinkSync AUDIO_CONTROL_PATH
audioControlServer.listen AUDIO_CONTROL_PATH, ->
  fs.chmodSync AUDIO_CONTROL_PATH, '777'
  console.log "audioControlServer is listening"

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
  tcpHeader = new Buffer [
    0x24, channel, rtpLen >> 8, rtpLen & 0xff,
  ]
  socket.write Buffer.concat [tcpHeader, rtpBuffer], 4 + rtpBuffer.length

handlePOSTData = (client, data) ->
  # Decode Base64-encoded data
  decodedRequest = new Buffer(data, 'base64').toString 'utf8'
  if decodedRequest[0] is 0x24  # dollar sign '$'
    console.log "[POST] Received an RTP packet (#{decodedRequest.length} bytes), ignored."
    for c in decodedRequest
      process.stdout.write c.toString(16) + ' '
    console.log()
    return
  req = parseRequest decodedRequest
  console.log "===request (decoded)==="
  process.stdout.write decodedRequest
  console.log "============="
  respond client.socket, req, (err, output) ->
    if err
      console.log "[respond] Error: #{err}"
      return
    console.log "===response==="
    process.stdout.write output
    console.log "============="
    client.getClient.socket.write output

clearTimeout = (socket) ->
  if socket.timeoutTimer?
    clearTimeout socket.timeoutTimer

scheduleTimeout = (socket) ->
  clearTimeout socket
  socket.scheduledTimeoutTime = Date.now() + KEEPALIVE_TIMEOUT
  socket.timeoutTimer = setTimeout ->
    if not clients[socket.clientID]?
      return
    if Date.now() < socket.scheduledTimeoutTime
      return
    console.log "keepalive timeout: #{socket.clientID}"
    teardownClient socket.clientID
  , KEEPALIVE_TIMEOUT

handleOnData = (c, data) ->
  id_str = c.clientID
  if not clients[id_str]?
    return

  if clients[id_str].isSendingPOST
    handlePOSTData clients[id_str], data.toString 'utf8'  # TODO: buffering
    return
  if c.buf?
    c.buf = Buffer.concat [c.buf, data], c.buf.length + data.length
  else
    c.buf = data
  if c.buf[0] is 0x24  # dollar sign '$'
    console.log "Received an RTP packet (#{c.buf.length} bytes), ignored."
    for b in c.buf
      process.stdout.write b.toString(16) + ' '
    console.log()
    c.buf = null
    return
  if c.ongoingRequest?
    req = c.ongoingRequest
    req.rawbody = Buffer.concat [req.rawbody, data], req.rawbody.length + data.length
    if req.rawbody.length < req.contentLength
      return
    req.socket = c
    bufString = req.rawbody.toString 'utf8'
    if req.rawbody.length > req.contentLength
      c.buf = req.rawbody[req.contentLength..]
      req.rawbody = req.rawbody[0...req.contentLength]
    else
      c.buf = null
  else
    bufString = c.buf.toString 'utf8'
    if bufString.indexOf('\r\n\r\n') is -1
      return
    req = parseRequest bufString
    req.rawbody = c.buf[req.headerBytes+4..]
    req.socket = c
    if req.headers['content-length']?
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
      c.buf = req.rawbody
  c.ongoingRequest = null
  respond c, req, (err, output, resultOpts) ->
    if err
      console.error "[respond] Error: #{err}"
      return
    if output instanceof Array
      for out, i in output
        c.write out
    else
      c.write output
    if resultOpts?.close
      console.log "[#{c.clientID}] end"
      c.end()
    if c.buf?
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
      isGlobal: not isLocal c
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
  process.kill process.pid, 'SIGTERM'

server = net.createServer (c) ->
  onClientConnect c

server.on 'error', (err) ->
  console.error "Server error: #{err.message}"
  throw err

console.log "Starting server on port #{SERVER_PORT}"
server.listen SERVER_PORT, '0.0.0.0', 511, ->
  console.log "Server bound on port #{SERVER_PORT}"

videoSequenceNumber = 0
audioSequenceNumber = 0
TIMESTAMP_ROUNDOFF = 4294967296  # 32 bits

lastVideoRTPTimestamp = null
lastAudioRTPTimestamp = null
videoRTPTimestampInterval = Math.round 90000 / FRAMERATE
audioRTPTimestampInterval = Math.round AUDIO_CLOCK_RATE / (AUDIO_SAMPLE_RATE / AUDIO_PERIOD_SIZE)

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
videoRTPSocket.bind serverVideoRTPPort
videoRTCPSocket = dgram.createSocket 'udp4'
videoRTCPSocket.bind serverVideoRTCPPort

audioRTPSocket = dgram.createSocket 'udp4'
audioRTPSocket.bind serverAudioRTPPort
audioRTCPSocket = dgram.createSocket 'udp4'
audioRTCPSocket.bind serverAudioRTCPPort

sendVideoPacketWithFragment = (nalUnit, timestamp) ->
  ts = timestamp % TIMESTAMP_ROUNDOFF
  lastVideoRTPTimestamp = ts

  nalUnitType = nalUnit[0] & 0x1f
  if nalUnitType in [7, 8] # sprop
    console.log "[rtsp-fragment] addSpropParam by NAL unit type #{nalUnitType}"
    addSpropParam nalUnit
    return

  if nalUnitType not in [1, 5]
    console.log "nalUnitType: #{nalUnitType}"

  if clientsCount is 0
    return

  isKeyFrame = nalUnitType is 5
  nal_ref_idc = nalUnit[0] & 0b01100000  # skip ">> 5" operation here

  nalUnit = nalUnit.slice 1

  fragmentNumber = 0
  while nalUnit.length > SINGLE_NAL_UNIT_MAX_SIZE
    if ++videoSequenceNumber > 65535
      videoSequenceNumber -= 65535

    fragmentNumber++
    thisNalUnit = nalUnit.slice 0, SINGLE_NAL_UNIT_MAX_SIZE
    nalUnit = nalUnit.slice SINGLE_NAL_UNIT_MAX_SIZE

    if fragmentNumber is 1
      start_bit = 1
    else
      start_bit = 0

    # TODO: sequence number should be started from a random number
    # Section 5.1 of RFC 3350 and 6184
    rtpData = [
      # version(2), padding(1), extension(1), CSRC count(4)
      0x80,
      # marker(1) == 0, payload type(7)
      97,
      # sequence number(16)
      videoSequenceNumber >>> 8, videoSequenceNumber & 0xff,
      # timestamp(32) in 90 kHz clock rate
      (ts >>> 24) & 0xff, (ts >>> 16) & 0xff, (ts >>> 8) & 0xff, ts & 0xff,
      # SSRC(32) will be filled later
      0, 0, 0, 0

      # FU indicator
      # forbidden_zero_bit(1), nal_ref_idc(2), type(5)
      # type is 28 for FU-A
      nal_ref_idc | 28,
      # FU header
      # start bit(1), end bit(1), reserved bit(1), type(5)
      start_bit << 7 | nalUnitType
    ]
    thisNalUnitLen = thisNalUnit.length
    rtpBuffer = Buffer.concat [new Buffer(rtpData), thisNalUnit], 14 + thisNalUnitLen
    for clientID, client of clients
      if client.isWaitingForKeyFrame and isKeyFrame
        process.stdout.write "KeyFrame"
        client.isPlaying = true
        client.isWaitingForKeyFrame = false

      if client.isPlaying
        rtpBuffer[8] = (client.videoSSRC >>> 24) & 0xff
        rtpBuffer[9] = (client.videoSSRC >>> 16) & 0xff
        rtpBuffer[10] = (client.videoSSRC >>> 8) & 0xff
        rtpBuffer[11] = client.videoSSRC & 0xff
        client.videoPacketCount++
        client.videoOctetCount += thisNalUnitLen
        if client.useTCPForVideo
          if client.useHTTP
            if client.httpClientType is 'GET'
              sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
          else
            sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
        else
          videoRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientVideoRTPPort, client.ip, (err, bytes) ->
            if err
              console.log "[videoRTPSend] error: #{err.message}"

  # last packet
  if ++videoSequenceNumber > 65535
    videoSequenceNumber -= 65535

  # TODO: sequence number should be started from a random number
  # Section 5.1 of RFC 3350 and 6184
  rtpData = [
    # version(2), padding(1), extension(1), CSRC count(4)
    0x80,
    # marker(1) == 1, payload type(7)
    1 << 7 | 97,
    # sequence number(16)
    videoSequenceNumber >>> 8, videoSequenceNumber & 0xff,
    # timestamp(32) in 90 kHz clock rate
    (ts >>> 24) & 0xff, (ts >>> 16) & 0xff, (ts >>> 8) & 0xff, ts & 0xff,
    # SSRC(32) will be filled later
    0, 0, 0, 0

    # FU indicator
    # forbidden_zero_bit(1), nal_ref_idc(2), type(5)
    # type is 28 for FU-A
    nal_ref_idc | 28,
    # FU header
    # start bit(1) == 0, end bit(1) == 1, reserved bit(1), type(5)
    1 << 6 | nalUnitType
  ]
  nalUnitLen = nalUnit.length
  rtpBuffer = Buffer.concat [new Buffer(rtpData), nalUnit], 14 + nalUnitLen
  for clientID, client of clients
    if client.isWaitingForKeyFrame and isKeyFrame
      process.stdout.write "KeyFrame"
      client.isPlaying = true
      client.isWaitingForKeyFrame = false

    if client.isPlaying
      rtpBuffer[8] = (client.videoSSRC >>> 24) & 0xff
      rtpBuffer[9] = (client.videoSSRC >>> 16) & 0xff
      rtpBuffer[10] = (client.videoSSRC >>> 8) & 0xff
      rtpBuffer[11] = client.videoSSRC & 0xff
      client.videoPacketCount++
      client.videoOctetCount += nalUnitLen
      if client.useTCPForVideo
        if client.useHTTP
          if client.httpClientType is 'GET'
            sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
        else
          sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
      else
        videoRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientVideoRTPPort, client.ip, (err, bytes) ->
          if err
            console.log "[videoRTPSend] error: #{err.message}"
  return

sendVideoPacketAsSingleNALUnit = (nalUnit, timestamp) ->
  if ++videoSequenceNumber > 65535
    videoSequenceNumber -= 65535

  ts = timestamp % TIMESTAMP_ROUNDOFF
  lastVideoRTPTimestamp = ts

  nalUnitType = nalUnit[0] & 0x1f
  if nalUnitType in [7, 8] # sprop
    console.log "[rtsp-single] addSpropParam by NAL unit type #{nalUnitType}"
    addSpropParam nalUnit
    return

  if nalUnitType not in [1, 5]
    console.log "nalUnitType: #{nalUnitType}"

  if clientsCount is 0
    return

  isKeyFrame = nalUnitType is 5

  marker = 1

  # TODO: sequence number should be started from a random number
  rtpData = [
    # version(2), padding(1), extension(1), CSRC count(4)
    0x80,
    # marker(1), payload type(7)
    marker << 7 | 97,
    # sequence number(16)
    videoSequenceNumber >>> 8, videoSequenceNumber & 0xff,
    # timestamp(32) in 90 kHz clock rate
    (ts >>> 24) & 0xff, (ts >>> 16) & 0xff, (ts >>> 8) & 0xff, ts & 0xff,
    # SSRC(32) will be filled later
    0, 0, 0, 0
  ]
  nalUnitLen = nalUnit.length
  rtpBuffer = Buffer.concat [new Buffer(rtpData), nalUnit], 12 + nalUnitLen
  for clientID, client of clients
    if client.isWaitingForKeyFrame and isKeyFrame
      process.stdout.write "KeyFrame"
      client.isPlaying = true
      client.isWaitingForKeyFrame = false

    if client.isPlaying
      rtpBuffer[8] = (client.videoSSRC >>> 24) & 0xff
      rtpBuffer[9] = (client.videoSSRC >>> 16) & 0xff
      rtpBuffer[10] = (client.videoSSRC >>> 8) & 0xff
      rtpBuffer[11] = client.videoSSRC & 0xff
      client.videoPacketCount++
      client.videoOctetCount += nalUnitLen
      if client.useTCPForVideo
        if client.useHTTP
          if client.httpClientType is 'GET'
            sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
        else
          sendDataByTCP client.socket, client.videoTCPDataChannel, rtpBuffer
      else
        videoRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientVideoRTPPort, client.ip, (err, bytes) ->
          if err
            console.error "[videoRTPSend] error: #{err.message}"
  return

# Takes one H.264 NAL unit as argument
#
# arguments:
#   nalUnit: Buffer
#   timestamp: timestamp in 90 kHz clock rate (PTS)
onReceiveVideoPacket = (nalUnit, timestamp) ->
  rtmpServer.sendVideoPacket nalUnit, timestamp

  if nalUnit.length >= SINGLE_NAL_UNIT_MAX_SIZE
    sendVideoPacketWithFragment nalUnit, timestamp
  else
    sendVideoPacketAsSingleNALUnit nalUnit, timestamp

  return

onReceiveAudioPacket = (rawDataBlock, timestamp) ->
  rtmpServer.sendAudioPacket rawDataBlock, timestamp

  if ++audioSequenceNumber > 65535
    audioSequenceNumber -= 65535

  ts = timestamp % TIMESTAMP_ROUNDOFF
  lastAudioRTPTimestamp = ts

  if clientsCount is 0
    return

  marker = 1

  accessUnitLength = rawDataBlock.length

  # TODO: maximum size of AAC-hbr is 8191 octets
  # TODO: sequence number should be started from a random number
  rtpData = [
    # version(2), padding(1), extension(1), CSRC count(4)
    0x80,
    # marker(1), payload type(7)
    marker << 7 | 96,
    # sequence number(16)
    audioSequenceNumber >>> 8, audioSequenceNumber & 0xff,
    # timestamp(32) in 90 kHz clock rate (clock rate is specified in SDP)
    (ts >>> 24) & 0xff, (ts >>> 16) & 0xff, (ts >>> 8) & 0xff, ts & 0xff,
    # SSRC(32) will be filled later
    0, 0, 0, 0

    ## payload
    ## AU Header Section
    # AU-headers-length(16) for AAC-hbr
    0x00, 0x10,
    # AU Header
    # AU-size(13) by SDP
    # AU-Index(3) MUST be coded with the value 0
    accessUnitLength >> 5,
    (accessUnitLength & 0b11111) << 3,
    # There is no Auxiliary Section for AAC-hbr
    ## raw_data_block (access unit) follows
  ]
  rawDataBlockLen = rawDataBlock.length
  rtpBuffer = Buffer.concat [new Buffer(rtpData), rawDataBlock], 16 + rawDataBlockLen
  for clientID, client of clients
    if client.isPlaying
      rtpBuffer[8] = (client.audioSSRC >>> 24) & 0xff
      rtpBuffer[9] = (client.audioSSRC >>> 16) & 0xff
      rtpBuffer[10] = (client.audioSSRC >>> 8) & 0xff
      rtpBuffer[11] = client.audioSSRC & 0xff
      client.audioPacketCount++
      client.audioOctetCount += rawDataBlockLen
      if client.useTCPForAudio
        if client.useHTTP
          if client.httpClientType is 'GET'
            sendDataByTCP client.socket, client.audioTCPDataChannel, rtpBuffer
        else
          sendDataByTCP client.socket, client.audioTCPDataChannel, rtpBuffer
      else
        audioRTPSocket.send rtpBuffer, 0, rtpBuffer.length, client.clientAudioRTPPort, client.ip, (err, bytes) ->
          if err
            console.error "[audioRTPSend] error: #{err.message}"
  return

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

# Check if the remote address is private
isLocal = (socket) ->
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
    Public: DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE


    """.replace /\n/g, "\r\n"
    callback null, res
  else if req.method is 'POST' and req.protocol.indexOf('HTTP') isnt -1
    pathname = url.parse(req.uri).pathname
    if ENABLE_RTMPT and /^\/(?:fcs|open|idle|send|close)\//.test pathname
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
    # There's no response
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
        Server: #{SERVER_NAME}
        Connection: close
        Date: #{getDateHeader()}
        Cache-Control: no-store
        Pragma: no-cache
        Content-Type: application/x-rtsp-tunnelled


        """.replace /\n/g, "\r\n"

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
      # packetization-mode: (refer to Section 5.4 of RFC 6184)
      #   0: Single NAL Unit Mode
      #   1: Non-Interleaved Mode (for STAP-A, FU-A)
      #   2: Interleaved Mode (for STAP-B, MTAP16, MTAP24, FU-A, FU-B)
      # see Section 6.2 of http://tools.ietf.org/html/rfc6184
      #
      # config: for MPEG-4 Audio streams, use hexstring of AudioSpecificConfig()
      # see Table 1.16 of AudioSpecificConfig definition in "ISO/IEC 14496-3 Part 3: Audio"
      config = \
        2 << 11 \ # audioObjectType(5 bits) 2 == AAC LC
        | 7 << 7 \ # samplingFrequencyIndex(4 bits) 0x7 == 22050, 0x4 == 44100, 0x3 == 48000
        | 1 << 3   # channelConfiguration(4 bits) 1 == 1 channel
        # other GASpecificConfig(3 bits) are all zeroes
      config = config.toString 16  # get the hexstring
      # rtpmap:96 mpeg4-generic/<clock rate>/<channels>

      # SDP parameters are defined in RFC 4566.
      # Definition of sizeLength, indexLength, indexDeltaLength is found in RFC 3640 or RFC 5691
      body = """
      v=0
      o=- #{client.sessionID} #{client.sessionID} IN IP4 127.0.0.1
      s= 
      c=IN IP4 0.0.0.0
      t=0 0
      a=sdplang:en
      a=range:npt=0.0-
      a=control:*
      m=audio 0 RTP/AVP 96
      a=rtpmap:96 mpeg4-generic/#{AUDIO_CLOCK_RATE}/1
      a=fmtp:96 profile-level-id=1;mode=AAC-hbr;sizeLength=13;indexLength=3;indexDeltaLength=3;config=#{config}
      a=control:trackID=1
      m=video 0 RTP/AVP 97
      a=rtpmap:97 H264/90000
      a=fmtp:97 packetization-mode=1;profile-level-id=#{PROFILE_LEVEL_ID};sprop-parameter-sets=#{spropParameterSets}
      a=cliprect:0,0,#{HEIGHT},#{WIDTH}
      a=framesize:97 #{WIDTH}-#{HEIGHT}
      a=framerate:#{FRAMERATE.toFixed 1}
      a=control:trackID=2

      """.replace /\n/g, "\r\n"

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
      Server: #{SERVER_NAME}
      Cache-Control: no-cache


      """.replace /\n/g, "\r\n"

      callback null, res + body
  else if req.method is 'SETUP'
    if not socket.isAuthenticated
      respondWithNotFound 'RTSP', callback
      return
    serverPort = null
    track = null

    # Check tranpsort
    if client.isGlobal and not /\bTCP\b/.test req.headers.transport
      # We can't use UDP over the internet in most cases.
      console.log "Unsupported transport: UDP may not be available over the internet"
      respondWithUnsupportedTransport callback, {CSeq: req.headers.cseq}
      return

    if /trackID=1/.test req.uri  # audio
      track = 'audio'
      if client.useHTTP
        ssrc = client.getClient.audioSSRC
      else
        ssrc = client.audioSSRC
      serverPort = "#{serverAudioRTPPort}-#{serverAudioRTCPPort}"
      if (match = /client_port=(\d+)-(\d+)/.exec req.headers.transport)?
        client.clientAudioRTPPort = parseInt match[1]
        client.clientAudioRTCPPort = parseInt match[2]
    else  # video
      track = 'video'
      if client.useHTTP
        ssrc = client.getClient.videoSSRC
      else
        ssrc = client.videoSSRC
      serverPort = "#{serverVideoRTPPort}-#{serverVideoRTCPPort}"
      if (match = /client_port=(\d+)-(\d+)/.exec req.headers.transport)?
        client.clientVideoRTPPort = parseInt match[1]
        client.clientVideoRTCPPort = parseInt match[2]

    if /\bTCP\b/.test req.headers.transport
      useTCPTransport = true
      if (match = /interleaved=(\d+)-(\d+)/.exec req.headers.transport)?
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
      if /interleaved=/.test req.headers.transport
        transportHeader = req.headers.transport
      else  # Maybe HTTP tunnelling
        transportHeader = req.headers.transport + ";interleaved=#{data_ch}-#{control_ch}" +
                          ";ssrc=#{zeropad(8, ssrc.toString(16))}"
    else
      transportHeader = req.headers.transport +
                        ";source=#{if isLocal(socket) then getLocalIP() else getExternalIP()}" +
                        ";server_port=#{serverPort};ssrc=#{zeropad(8, ssrc.toString(16))}"
    dateHeader = getDateHeader()
    res = """
    RTSP/1.0 200 OK
    Date: #{dateHeader}
    Expires: #{dateHeader}
    Transport: #{transportHeader}
    Session: #{client.sessionID};timeout=60
    CSeq: #{req.headers.cseq}
    Server: #{SERVER_NAME}
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
    res = """
    RTSP/1.0 200 OK
    Range: npt=0.0-
    Session: #{client.sessionID};timeout=60
    CSeq: #{req.headers.cseq}
    RTP-Info: url=#{baseUrl}/trackID=1;seq=#{getNextAudioSequenceNumber()};rtptime=#{getNextAudioRTPTimestamp()},url=#{baseUrl}/trackID=2;seq=#{getNextVideoSequenceNumber()};rtptime=#{getNextVideoRTPTimestamp()}
    Server: #{SERVER_NAME}
    Cache-Control: no-cache


    """.replace /\n/g, "\r\n"
    if not preventFromPlaying
      if client.useHTTP
        console.log "[[[ start sending to #{client.getClient.id} through GET ]]]"
        if ENABLE_START_PLAYING_FROM_KEYFRAME
          client.getClient.isWaitingForKeyFrame = true
        else
          client.getClient.isPlaying = true
      else if client.useTCPForVideo  # or client.useTCPForAudio?
        console.log "[[[ start sending to #{client.id} by TCP ]]]"
        if ENABLE_START_PLAYING_FROM_KEYFRAME
          client.isWaitingForKeyFrame = true
        else
          client.isPlaying = true
      else
        console.log "[[[ start sending to #{client.id} by UDP ]]]"
        if ENABLE_START_PLAYING_FROM_KEYFRAME
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
  method: method
  uri: decodeURIComponent uri
  protocol: protocol
  headers: headers
  body: body
  headerBytes: headerPart.length  # TODO
