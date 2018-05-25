# RTSP and RTMP/RTMPE/RTMPT/RTMPTE server implementation.
# Also serves HTTP contents as this server is meant to
# be run on port 80.

net = require 'net'
fs = require 'fs'
crypto = require 'crypto'

config = require './config'
rtmp = require './rtmp'
http = require './http'
rtsp = require './rtsp'
h264 = require './h264'
aac = require './aac'
mp4 = require './mp4'
Bits = require './bits'
avstreams = require './avstreams'
CustomReceiver = require './custom_receiver'
logger = require './logger'
packageJson = require './package.json'

Sequent = require 'sequent'

# If true, incoming video/audio packets are printed to the console
DEBUG_INCOMING_PACKET_DATA = false

# If true, hash value of each incoming video/audio access unit is printed to the console
DEBUG_INCOMING_PACKET_HASH = false

## Default server name for RTSP and HTTP responses
DEFAULT_SERVER_NAME = "node-rtsp-rtmp-server/#{packageJson.version}"

serverName = config.serverName ? DEFAULT_SERVER_NAME

class StreamServer
  constructor: (opts) ->
    @serverName = opts?.serverName ? serverName

    if config.enableRTMP or config.enableRTMPT
      # Create RTMP server
      @rtmpServer = new rtmp.RTMPServer
      @rtmpServer.on 'video_start', (streamId) =>
        stream = avstreams.getOrCreate streamId
        @onReceiveVideoControlBuffer stream
      @rtmpServer.on 'video_data', (streamId, pts, dts, nalUnits) =>
        stream = avstreams.get streamId
        if stream?
          @onReceiveVideoPacket stream, nalUnits, pts, dts
        else
          logger.warn "warn: Received invalid streamId from rtmp: #{streamId}"
      @rtmpServer.on 'audio_start', (streamId) =>
        stream = avstreams.getOrCreate streamId
        @onReceiveAudioControlBuffer stream
      @rtmpServer.on 'audio_data', (streamId, pts, dts, adtsFrame) =>
        stream = avstreams.get streamId
        if stream?
          @onReceiveAudioPacket stream, adtsFrame, pts, dts
        else
          logger.warn "warn: Received invalid streamId from rtmp: #{streamId}"

    if config.enableCustomReceiver
      # Setup data receivers for custom protocol
      @customReceiver = new CustomReceiver config.receiverType,
        videoControl: (args...) =>
          @onReceiveVideoControlBuffer args...
        audioControl: (args...) =>
          @onReceiveAudioControlBuffer args...
        videoData: (args...) =>
          @onReceiveVideoDataBuffer args...
        audioData: (args...) =>
          @onReceiveAudioDataBuffer args...

      # Delete old sockets
      @customReceiver.deleteReceiverSocketsSync()

    if config.enableHTTP
      @httpHandler = new http.HTTPHandler
        serverName: @serverName
        documentRoot: opts?.documentRoot

    if config.enableRTSP or config.enableHTTP or config.enableRTMPT
      if config.enableRTMPT
        rtmptCallback = (args...) =>
          @rtmpServer.handleRTMPTRequest args...
      else
        rtmptCallback = null
      if config.enableHTTP
        httpHandler = @httpHandler
      else
        httpHandler = null
      @rtspServer = new rtsp.RTSPServer
        serverName : @serverName
        httpHandler: httpHandler
        rtmptCallback: rtmptCallback
      @rtspServer.on 'video_start', (stream) =>
        @onReceiveVideoControlBuffer stream
      @rtspServer.on 'audio_start', (stream) =>
        @onReceiveAudioControlBuffer stream
      @rtspServer.on 'video', (stream, nalUnits, pts, dts) =>
        @onReceiveVideoNALUnits stream, nalUnits, pts, dts
      @rtspServer.on 'audio', (stream, accessUnits, pts, dts) =>
        @onReceiveAudioAccessUnits stream, accessUnits, pts, dts

    avstreams.on 'new', (stream) ->
      if DEBUG_INCOMING_PACKET_HASH
        stream.lastSentVideoTimestamp = 0

    avstreams.on 'reset', (stream) ->
      if DEBUG_INCOMING_PACKET_HASH
        stream.lastSentVideoTimestamp = 0

    avstreams.on 'end', (stream) =>
      if config.enableRTSP
        @rtspServer.sendEOS stream
      if config.enableRTMP or config.enableRTMPT
        @rtmpServer.sendEOS stream

    # for mp4
    avstreams.on 'audio_data', (stream, data, pts) =>
      @onReceiveAudioAccessUnits stream, [ data ], pts, pts

    avstreams.on 'video_data', (stream, nalUnits, pts, dts) =>
      if not dts?
        dts = pts
      @onReceiveVideoNALUnits stream, nalUnits, pts, dts

    avstreams.on 'audio_start', (stream) =>
      @onReceiveAudioControlBuffer stream

    avstreams.on 'video_start', (stream) =>
      @onReceiveVideoControlBuffer stream

    ## TODO: Do we need to do something for remove_stream event?
    #avstreams.on 'remove_stream', (stream) ->
    #  logger.raw "received remove_stream event from stream #{stream.id}"

  attachRecordedDir: (dir) ->
    if config.recordedApplicationName?
      logger.info "attachRecordedDir: dir=#{dir} app=#{config.recordedApplicationName}"
      avstreams.attachRecordedDirToApp dir, config.recordedApplicationName

  attachMP4: (filename, streamName) ->
    logger.info "attachMP4: file=#{filename} stream=#{streamName}"

    context = this
    generator = new avstreams.AVStreamGenerator
      # Generate an AVStream upon request
      generate: ->
        try
          mp4File = new mp4.MP4File filename
        catch err
          logger.error "error opening MP4 file #{filename}: #{err}"
          return null
        streamId = avstreams.createNewStreamId()
        mp4Stream = new avstreams.MP4Stream streamId
        logger.info "created stream #{streamId} from #{filename}"
        avstreams.emit 'new', mp4Stream
        avstreams.add mp4Stream

        mp4Stream.type = avstreams.STREAM_TYPE_RECORDED
        audioSpecificConfig = null
        mp4File.on 'audio_data', (data, pts) ->
          context.onReceiveAudioAccessUnits mp4Stream, [ data ], pts, pts
        mp4File.on 'video_data', (nalUnits, pts, dts) ->
          if not dts?
            dts = pts
          context.onReceiveVideoNALUnits mp4Stream, nalUnits, pts, dts
        mp4File.on 'eof', =>
          mp4Stream.emit 'end'
        mp4File.parse()
        mp4Stream.updateSPS mp4File.getSPS()
        mp4Stream.updatePPS mp4File.getPPS()
        ascBuf = mp4File.getAudioSpecificConfig()
        bits = new Bits ascBuf
        ascInfo = aac.readAudioSpecificConfig bits
        mp4Stream.updateConfig
          audioSpecificConfig: ascBuf
          audioASCInfo: ascInfo
          audioSampleRate: ascInfo.samplingFrequency
          audioClockRate: 90000
          audioChannels: ascInfo.channelConfiguration
          audioObjectType: ascInfo.audioObjectType
        mp4Stream.durationSeconds = mp4File.getDurationSeconds()
        mp4Stream.lastTagTimestamp = mp4File.getLastTimestamp()
        mp4Stream.mp4File = mp4File
        mp4File.fillBuffer ->
          context.onReceiveAudioControlBuffer mp4Stream
          context.onReceiveVideoControlBuffer mp4Stream
        return mp4Stream

      play: ->
        @mp4File.play()

      pause: ->
        @mp4File.pause()

      resume: ->
        return @mp4File.resume()

      seek: (seekSeconds, callback) ->
        actualStartTime = @mp4File.seek seekSeconds
        callback null, actualStartTime

      sendVideoPacketsSinceLastKeyFrame: (endSeconds, callback) ->
        @mp4File.sendVideoPacketsSinceLastKeyFrame endSeconds, callback

      teardown: ->
        @mp4File.close()
        @destroy()

      getCurrentPlayTime: ->
        return @mp4File.currentPlayTime

      isPaused: ->
        return @mp4File.isPaused()

    avstreams.addGenerator streamName, generator

  stop: (callback) ->
    if config.enableCustomReceiver
      @customReceiver.deleteReceiverSocketsSync()
    callback?()

  start: (callback) ->
    seq = new Sequent
    waitCount = 0

    if config.enableRTMP
      waitCount++
      @rtmpServer.start { port: config.rtmpServerPort }, ->
        seq.done()
        # RTMP server is ready

    if config.enableCustomReceiver
      # Start data receivers for custom protocol
      @customReceiver.start()

    if config.enableRTSP or config.enableHTTP or config.enableRTMPT
      waitCount++
      @rtspServer.start { port: config.serverPort }, ->
        seq.done()

    seq.wait waitCount, ->
      callback?()

  setLivePathConsumer: (func) ->
    if config.enableRTSP
      @rtspServer.setLivePathConsumer func

  setAuthenticator: (func) ->
    if config.enableRTSP
      @rtspServer.setAuthenticator func

  # buf argument can be null (not used)
  onReceiveVideoControlBuffer: (stream, buf) ->
    stream.resetFrameRate stream
    stream.isVideoStarted = true
    stream.timeAtVideoStart = Date.now()
    stream.timeAtAudioStart = stream.timeAtVideoStart
  #  stream.spropParameterSets = ''

  # buf argument can be null (not used)
  onReceiveAudioControlBuffer: (stream, buf) ->
    stream.isAudioStarted = true
    stream.timeAtAudioStart = Date.now()
    stream.timeAtVideoStart = stream.timeAtAudioStart

  onReceiveVideoDataBuffer: (stream, buf) ->
    pts = buf[1] * 0x010000000000 + \
          buf[2] * 0x0100000000   + \
          buf[3] * 0x01000000     + \
          buf[4] * 0x010000       + \
          buf[5] * 0x0100         + \
          buf[6]
    # TODO: Support dts
    dts = pts
    nalUnit = buf[7..]
    @onReceiveVideoPacket stream, nalUnit, pts, dts

  onReceiveAudioDataBuffer: (stream, buf) ->
    pts = buf[1] * 0x010000000000 + \
          buf[2] * 0x0100000000   + \
          buf[3] * 0x01000000     + \
          buf[4] * 0x010000       + \
          buf[5] * 0x0100         + \
          buf[6]
    # TODO: Support dts
    dts = pts
    adtsFrame = buf[7..]
    @onReceiveAudioPacket stream, adtsFrame, pts, dts

  # nal_unit_type 5 must not separated with 7 and 8 which
  # share the same timestamp as 5
  onReceiveVideoNALUnits: (stream, nalUnits, pts, dts) ->
    if DEBUG_INCOMING_PACKET_DATA
      logger.info "receive video: num_nal_units=#{nalUnits.length} pts=#{pts}"

    if config.enableRTSP
      # rtspServer will parse nalUnits and updates SPS/PPS for the stream,
      # so we don't need to parse them here.
      # TODO: Should SPS/PPS be parsed here?
      @rtspServer.sendVideoData stream, nalUnits, pts, dts

    if config.enableRTMP or config.enableRTMPT
      @rtmpServer.sendVideoPacket stream, nalUnits, pts, dts

    hasVideoFrame = false
    for nalUnit in nalUnits
      nalUnitType = h264.getNALUnitType nalUnit
      if nalUnitType is h264.NAL_UNIT_TYPE_SPS  # 7
        stream.updateSPS nalUnit
      else if nalUnitType is h264.NAL_UNIT_TYPE_PPS  # 8
        stream.updatePPS nalUnit
      else if (nalUnitType is h264.NAL_UNIT_TYPE_IDR_PICTURE) or
      (nalUnitType is h264.NAL_UNIT_TYPE_NON_IDR_PICTURE)  # 5 (key frame) or 1 (inter frame)
        hasVideoFrame = true
      if DEBUG_INCOMING_PACKET_HASH
        md5 = crypto.createHash 'md5'
        md5.update nalUnit
        tsDiff = pts - stream.lastSentVideoTimestamp
        logger.info "video: pts=#{pts} pts_diff=#{tsDiff} md5=#{md5.digest('hex')[0..6]} nal_unit_type=#{nalUnitType} bytes=#{nalUnit.length}"
        stream.lastSentVideoTimestamp = pts

    if hasVideoFrame
      stream.calcFrameRate pts

    return

  # Takes H.264 NAL units separated by start code (0x000001)
  #
  # arguments:
  #   nalUnit: Buffer
  #   pts: timestamp in 90 kHz clock rate (PTS)
  onReceiveVideoPacket: (stream, nalUnitGlob, pts, dts) ->
    nalUnits = h264.splitIntoNALUnits nalUnitGlob
    if nalUnits.length is 0
      return
    @onReceiveVideoNALUnits stream, nalUnits, pts, dts
    return

  # pts, dts: in 90KHz clock rate
  onReceiveAudioAccessUnits: (stream, accessUnits, pts, dts) ->
    if config.enableRTSP
      @rtspServer.sendAudioData stream, accessUnits, pts, dts

    if DEBUG_INCOMING_PACKET_DATA
      logger.info "receive audio: num_access_units=#{accessUnits.length} pts=#{pts}"

    ptsPerFrame = 90000 / (stream.audioSampleRate / 1024)

    for accessUnit, i in accessUnits
      if DEBUG_INCOMING_PACKET_HASH
        md5 = crypto.createHash 'md5'
        md5.update accessUnit
        logger.info "audio: pts=#{pts} md5=#{md5.digest('hex')[0..6]} bytes=#{accessUnit.length}"
      if config.enableRTMP or config.enableRTMPT
        @rtmpServer.sendAudioPacket stream, accessUnit,
          Math.round(pts + ptsPerFrame * i),
          Math.round(dts + ptsPerFrame * i)

    return

  # pts, dts: in 90KHz clock rate
  onReceiveAudioPacket: (stream, adtsFrameGlob, pts, dts) ->
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

    @onReceiveAudioAccessUnits stream, rawDataBlocks, pts, dts

module.exports = StreamServer
