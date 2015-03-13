# RTSP and RTMP/RTMPE/RTMPT/RTMPTE server implementation.
# Also serves HTTP contents as this server is meant to
# be run on port 80.

net         = require 'net'
fs          = require 'fs'
crypto      = require 'crypto'

config         = require './config'
rtmp           = require './rtmp'
http           = require './http'
rtsp           = require './rtsp'
h264           = require './h264'
aac            = require './aac'
hybrid_udp     = require './hybrid_udp'
Bits           = require './bits'
avstreams      = require './avstreams'
CustomReceiver = require './custom_receiver'
logger         = require './logger'

Bits.set_warning_fatal true
logger.setLevel logger.LEVEL_INFO

# If true, incoming video/audio packets are printed to the console
DEBUG_INCOMING_PACKET_DATA = false

# If true, hash value of each incoming video/audio access unit is printed to the console
DEBUG_INCOMING_PACKET_HASH = false

## Default server name for RTSP and HTTP responses
DEFAULT_SERVER_NAME = 'node-rtsp-rtmp-server/0.2.2'

serverName = config.serverName ? DEFAULT_SERVER_NAME

# Create RTMP server
rtmpServer = new rtmp.RTMPServer
rtmpServer.on 'video_start', (streamId) ->
  stream = avstreams.getOrCreate streamId
  onReceiveVideoControlBuffer stream
rtmpServer.on 'video_data', (streamId, pts, dts, nalUnits) ->
  stream = avstreams.get streamId
  if stream?
    onReceiveVideoPacket stream, nalUnits, pts, dts
  else
    console.warn "warning: invalid streamId received from rtmp: #{streamId}"
rtmpServer.on 'audio_start', (streamId) ->
  stream = avstreams.getOrCreate streamId
  onReceiveAudioControlBuffer stream
rtmpServer.on 'audio_data', (streamId, pts, dts, adtsFrame) ->
  stream = avstreams.get streamId
  if stream?
    onReceiveAudioPacket stream, adtsFrame, pts, dts
  else
    console.warn "warning: invalid streamId received from rtmp: #{streamId}"

rtmpServer.start ->
  # RTMP server is ready

# buf argument can be null (not used)
onReceiveVideoControlBuffer = (stream, buf) ->
  logger.debug "video start"
  stream.resetFrameRate stream
  stream.isVideoStarted = true
  stream.timeAtVideoStart = Date.now()
  stream.timeAtAudioStart = stream.timeAtVideoStart
#  stream.spropParameterSets = ''

# buf argument can be null (not used)
onReceiveAudioControlBuffer = (stream, buf) ->
  logger.debug "audio start"
  stream.isAudioStarted = true
  stream.timeAtAudioStart = Date.now()
  stream.timeAtVideoStart = stream.timeAtAudioStart

onReceiveVideoDataBuffer = (stream, buf) ->
  pts = buf[1] * 0x010000000000 + \
        buf[2] * 0x0100000000   + \
        buf[3] * 0x01000000     + \
        buf[4] * 0x010000       + \
        buf[5] * 0x0100         + \
        buf[6]
  dts = pts
  nalUnit = buf[7..]
  onReceiveVideoPacket stream, nalUnit, pts, dts

onReceiveAudioDataBuffer = (stream, buf) ->
  pts = buf[1] * 0x010000000000 + \
        buf[2] * 0x0100000000   + \
        buf[3] * 0x01000000     + \
        buf[4] * 0x010000       + \
        buf[5] * 0x0100         + \
        buf[6]
  dts = pts
  adtsFrame = buf[7..]
  onReceiveAudioPacket stream, adtsFrame, pts, dts

# Setup data receivers for custom protocol
customReceiver = new CustomReceiver config.receiverType,
  videoControl: onReceiveVideoControlBuffer
  audioControl: onReceiveAudioControlBuffer
  videoData: onReceiveVideoDataBuffer
  audioData: onReceiveAudioDataBuffer

# Delete old sockets
customReceiver.deleteReceiverSocketsSync()

# Start data receivers for custom protocol
customReceiver.start()

process.on 'SIGINT', ->
  customReceiver.deleteReceiverSocketsSync()
  process.kill process.pid, 'SIGTERM'

process.on 'uncaughtException', (err) ->
  customReceiver.deleteReceiverSocketsSync()
  throw err

httpHandler = new http.HTTPHandler
  serverName: serverName

rtspServer = new rtsp.RTSPServer
  serverName : serverName
  httpHandler: httpHandler
  rtmpServer : rtmpServer
rtspServer.on 'video_start', (stream) ->
  onReceiveVideoControlBuffer stream
rtspServer.on 'audio_start', (stream) ->
  onReceiveAudioControlBuffer stream
rtspServer.on 'video', (stream, nalUnits, pts, dts) ->
  onReceiveVideoNALUnits stream, nalUnits, pts, dts
rtspServer.on 'audio', (stream, accessUnits, pts, dts) ->
  onReceiveAudioAccessUnits stream, accessUnits, pts, dts
rtspServer.start port: config.serverPort

# nal_unit_type 5 must not separated with 7 and 8 which
# share the same timestamp as 5
onReceiveVideoNALUnits = (stream, nalUnits, pts, dts) ->
  if DEBUG_INCOMING_PACKET_DATA
    console.log "receive video: num_nal_units=#{nalUnits.length} pts=#{pts}"

  # rtspServer will parse nalUnits and updates SPS/PPS for the stream,
  # so we don't need to parse them here.
  # TODO: Should SPS/PPS be parsed here?
  rtspServer.sendVideoData stream, nalUnits, pts, dts

  rtmpServer.sendVideoPacket stream, nalUnits, pts, dts

  hasVideoFrame = false
  for nalUnit in nalUnits
    nalUnitType = h264.getNALUnitType nalUnit
    if (nalUnitType is h264.NAL_UNIT_TYPE_IDR_PICTURE) or (nalUnitType is h264.NAL_UNIT_TYPE_NON_IDR_PICTURE)  # 5 (key frame) or 1 (inter frame)
      hasVideoFrame = true
      if not DEBUG_INCOMING_PACKET_HASH
        break
    if DEBUG_INCOMING_PACKET_HASH
      md5 = crypto.createHash 'md5'
      md5.update nalUnit
      tsDiff = pts - stream.lastSentVideoTimestamp
      console.log "video: pts=#{pts} pts_diff=#{tsDiff} md5=#{md5.digest('hex')[0..6]} nal_unit_type=#{nalUnitType} bytes=#{nalUnit.length}"
      stream.lastSentVideoTimestamp = pts

  if hasVideoFrame
    stream.calcFrameRate pts

  return

# Takes H.264 NAL units separated by start code (0x000001)
#
# arguments:
#   nalUnit: Buffer
#   pts: timestamp in 90 kHz clock rate (PTS)
onReceiveVideoPacket = (stream, nalUnitGlob, pts, dts) ->
  nalUnits = h264.splitIntoNALUnits nalUnitGlob
  if nalUnits.length is 0
    return
  onReceiveVideoNALUnits stream, nalUnits, pts, dts
  return

# pts, dts: in 90KHz clock rate
onReceiveAudioAccessUnits = (stream, accessUnits, pts, dts) ->
  rtspServer.sendAudioData stream, accessUnits, pts, dts

  if DEBUG_INCOMING_PACKET_DATA
    console.log "receive audio: num_access_units=#{accessUnits.length} pts=#{pts}"

  ptsPerFrame = 90000 / (stream.audioSampleRate / 1024)

  for accessUnit, i in accessUnits
    if DEBUG_INCOMING_PACKET_HASH
      md5 = crypto.createHash 'md5'
      md5.update accessUnit
      console.log "audio: pts=#{pts} md5=#{md5.digest('hex')[0..6]} bytes=#{accessUnit.length}"
    rtmpServer.sendAudioPacket stream, accessUnit,
      Math.round(pts + ptsPerFrame * i),
      Math.round(dts + ptsPerFrame * i)

# pts, dts: in 90KHz clock rate
onReceiveAudioPacket = (stream, adtsFrameGlob, pts, dts) ->
  adtsFrames = aac.splitIntoADTSFrames adtsFrameGlob
  if adtsFrames.length is 0
    return
  adtsInfo = aac.parseADTSFrame adtsFrames[0]

  isConfigUpdated = false

  stream.updateConfig
    audioSampleRate: adtsInfo.sampleRate
    audioClockRate: adtsInfo.sampleRate
    audioChannels: adtsInfo.channels
    audioObjectType: adtsInfo.audioObjectType

  rtpTimePerFrame = 1024

  rawDataBlocks = []
  for adtsFrame, i in adtsFrames
    rawDataBlock = adtsFrame[7..]
    rawDataBlocks.push rawDataBlock

  onReceiveAudioAccessUnits stream, rawDataBlocks, pts, dts

avstreams.on 'new', (stream) ->
  if DEBUG_INCOMING_PACKET_HASH
    stream.lastSentVideoTimestamp = 0

avstreams.on 'reset', (stream) ->
  if DEBUG_INCOMING_PACKET_HASH
    stream.lastSentVideoTimestamp = 0

## TODO: Do we need to do something for remove_stream event?
#avstreams.on 'remove_stream', (stream) ->
#  console.log "received remove_stream event from stream #{stream.id}"
