crypto = require 'crypto'
fs = require 'fs'
path = require 'path'

h264 = require './h264'
aac = require './aac'
mp4 = require './mp4'
Bits = require './bits'
EventEmitterModule = require './event_emitter'
logger = require './logger'

createStreamId = ->
  try
    buf = crypto.randomBytes 256
  catch e
    logger.error "crypto.randomBytes() failed: #{e}"
    buf = crypto.pseudoRandomBytes 256

  shasum = crypto.createHash 'sha512'
  shasum.update buf
  return shasum.digest('hex')[0..7]

# Generates stream upon request
class AVStreamGenerator
  constructor: (methods) ->
    if methods?.generate?
      @generate = methods.generate
    if methods?.teardown?
      @teardown = methods.teardown
    if methods?.pause?
      @pause = methods.pause
    if methods?.resume?
      @resume = methods.resume
    if methods?.seek?
      @seek = methods.seek
    if methods?.sendVideoPacketsSinceLastKeyFrame?
      @sendVideoPacketsSinceLastKeyFrame = methods.sendVideoPacketsSinceLastKeyFrame
    if methods?.getCurrentPlayTime?
      @getCurrentPlayTime = methods.getCurrentPlayTime
    if methods?.isPaused?
      @isPaused = methods.isPaused

    methods?.init?()

  generate: ->

  teardown: ->

class AVStream extends EventEmitterModule
  constructor: (id) ->
    super()
    @id = id  # string
    @initAVParams()

  initAVParams: ->
    @audioClockRate      = null  # int
    @audioSampleRate     = null  # int
    @audioChannels       = null  # int
    @audioPeriodSize     = 1024  # TODO: detect this from stream?
    @audioObjectType     = null  # int
    @videoWidth          = null  # int
    @videoHeight         = null  # int
    @videoProfileLevelId = null  # string (e.g. '42C01F')
    @videoFrameRate      = 30.0  # float  # TODO: default value
    @videoAVCLevel       = null  # int
    @videoAVCProfile     = null  # int
    @isVideoStarted      = false # boolean
    @isAudioStarted      = false # boolean
    @timeAtVideoStart    = null  # milliseconds since the epoch
    @timeAtAudioStart    = null  # milliseconds since the epoch
    @spsString           = ''    # string
    @ppsString           = ''    # string
    @spsNALUnit          = null  # buffer
    @ppsNALUnit          = null  # buffer
    @spropParameterSets  = ''    # string
    @type                = null  # string ('live' or 'recorded')

  destroy: ->
    logger.debug "[stream:#{@id}] destroy"
    @spsNALUnit = null
    @ppsNALUnit = null
    @emit 'destroy'

  isRecorded: ->
    return @type is api.STREAM_TYPE_RECORDED

  reset: ->
    logger.debug "[stream:#{@id}] reset"
    @initAVParams()
    @emit 'reset'

  updateSpropParam: (buf) ->
    nalUnitType = buf[0] & 0x1f
    if nalUnitType is 7  # SPS packet
      @spsString = buf.toString 'base64'
      @videoProfileLevelId = buf[1..3].toString('hex').toUpperCase()
    else if nalUnitType is 8  # PPS packet
      @ppsString = buf.toString 'base64'

    @spropParameterSets = @spsString + ',' + @ppsString

  resetFrameRate: ->
    @frameRateCalcBasePTS = null
    @frameRateCalcNumFrames = null
    @videoFrameRate = 30.0  # TODO: What value should we use as a default frame rate?

  calcFrameRate: (pts) ->
    if @frameRateCalcBasePTS?
      diffMs = (pts - @frameRateCalcBasePTS) / 90
      if pts isnt @lastPTS
        @frameRateCalcNumFrames++
        @lastPTS = pts
      if (@frameRateCalcNumFrames >= 150) or (diffMs >= 5000)
        frameRate = @frameRateCalcNumFrames * 1000 / diffMs
        if frameRate isnt @videoFrameRate
          logger.debug "[stream:#{@id}] frame rate: #{@videoFrameRate}"
          @videoFrameRate = frameRate
          @emit 'update_frame_rate', frameRate
        @frameRateCalcBasePTS = pts
        @frameRateCalcNumFrames = 0
        @lastPTS = null
    else
      @frameRateCalcBasePTS = pts
      @frameRateCalcNumFrames = 0
      @lastPTS = null

  updateConfig: (obj) ->
    isConfigUpdated = false
    for name, value of obj
      if @[name] isnt value
        @[name] = value
        if value instanceof Buffer
          logger.debug "[stream:#{@id}] update #{name}: Buffer=<0x#{value.toString 'hex'}>"
        else if typeof(value) is 'object'
          logger.debug "[stream:#{@id}] update #{name}:"
          logger.debug value
        else
          logger.debug "[stream:#{@id}] update #{name}: #{value}"
        if name is 'audioASCInfo'
          if value?.sbrPresentFlag is 1
            if value?.psPresentFlag is 1
              logger.debug "[stream:#{@id}] audio: HE-AAC v2"
            else
              logger.debug "[stream:#{@id}] audio: HE-AAC v1"
        isConfigUpdated = true
    if isConfigUpdated
      @emit 'updateConfig'

  # nal_unit_type 7
  updateSPS: (nalUnit) ->
    if (not @spsNALUnit?) or (nalUnit.compare(@spsNALUnit) isnt 0)
      @spsNALUnit = nalUnit
      @updateSpropParam nalUnit
      try
        sps = h264.readSPS nalUnit
      catch e
        logger.error "[stream:#{@id}] video data error: failed to read SPS"
        logger.error e.stack
        return
      frameSize = h264.getFrameSize sps
      isConfigUpdated = false
      if @videoWidth isnt frameSize.width
        @videoWidth = frameSize.width
        logger.debug "[stream:#{@id}] video width: #{@videoWidth}"
        isConfigUpdated = true
      if @videoHeight isnt frameSize.height
        @videoHeight = frameSize.height
        logger.debug "[stream:#{@id}] video height: #{@videoHeight}"
        isConfigUpdated = true
      if @videoAVCLevel isnt sps.level_idc
        @videoAVCLevel = sps.level_idc
        logger.debug "[stream:#{@id}] video avclevel: #{@videoAVCLevel}"
        isConfigUpdated = true
      if @videoAVCProfile isnt sps.profile_idc
        @videoAVCProfile = sps.profile_idc
        logger.debug "[stream:#{@id}] video avcprofile: #{@videoAVCProfile}"
        isConfigUpdated = true
      if isConfigUpdated
        logger.debug "[stream:#{@id}] updated SPS: 0x#{nalUnit.toString 'hex'}"
        @emit 'updateConfig'

  # nal_unit_type 8
  updatePPS: (nalUnit) ->
    if (not @ppsNALUnit?) or (nalUnit.compare(@ppsNALUnit) isnt 0)
      logger.debug "[stream:#{@id}] updated PPS: 0x#{nalUnit.toString 'hex'}"
      @ppsNALUnit = nalUnit
      @updateSpropParam nalUnit
      @emit 'updateConfig'

  toString: ->
    str = "#{@id}: "
    if @videoWidth?
      str += "video: #{@videoWidth}x#{@videoHeight} profile=#{@videoAVCProfile} level=#{@videoAVCLevel}"
    else
      str += "video: (waiting for data)"
    if @audioSampleRate?
      str += "; audio: samplerate=#{@audioSampleRate} channels=#{@audioChannels} objecttype=#{@audioObjectType}"
    else
      str += "; audio: (waiting for data)"
    return str

class MP4Stream extends AVStream
  @create: (filename) ->
    try
      mp4File = new mp4.MP4File filename
    catch err
      logger.error "error opening MP4 file #{filename}: #{err}"
      return null
    streamId = api.createNewStreamId()
    mp4Stream = new MP4Stream streamId
    logger.debug "created stream #{streamId} from file #{filename}"
    api.emit 'new', mp4Stream
    api.add mp4Stream

    mp4Stream.type = api.STREAM_TYPE_RECORDED
    mp4File.on 'audio_data', (data, pts) ->
      mp4Stream.emit 'audio_data', data, pts
    mp4File.on 'video_data', (nalUnits, pts, dts) ->
      mp4Stream.emit 'video_data', nalUnits, pts, dts
    mp4File.on 'eof', ->
      mp4Stream.emit 'end'
    mp4File.parse()
    if mp4File.hasVideo()
      mp4Stream.updateSPS mp4File.getSPS()
      mp4Stream.updatePPS mp4File.getPPS()
    if mp4File.hasAudio()
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
      if mp4File.hasAudio()
        mp4Stream.emit 'audio_start'
        mp4Stream.isAudioStarted = true
      if mp4File.hasVideo()
        mp4Stream.emit 'video_start'
        mp4Stream.isVideoStarted = true
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
    logger.debug "[mp4stream:#{@id}] teardown"
    @mp4File.close()
    @destroy()

  getCurrentPlayTime: ->
    return @mp4File.currentPlayTime

  isPaused: ->
    return @mp4File.isPaused()


eventListeners = {}
streams = {}
streamGenerators = {}
recordedAppToDir = {}

api =
  STREAM_TYPE_LIVE: 'live'
  STREAM_TYPE_RECORDED: 'recorded'

  AVStream: AVStream
  MP4Stream: MP4Stream
  AVStreamGenerator: AVStreamGenerator

  emit: (name, data...) ->
    if eventListeners[name]?
      for listener in eventListeners[name]
        listener data...
    return

  on: (name, listener) ->
    if eventListeners[name]?
      eventListeners[name].push listener
    else
      eventListeners[name] = [ listener ]

  removeListener: (name, listener) ->
    if eventListeners[name]?
      for _listener, i in eventListeners[name]
        if _listener is listener
          eventListeners[i..i] = []  # remove element at index i
    return

  getAll: ->
    return streams

  exists: (streamId) ->
    return streams[streamId]?

  get: (streamId) ->
    if streams[streamId]? # existing stream
      return streams[streamId]
    else if streamGenerators[streamId]? # generator
      stream = streamGenerators[streamId].generate()
      if stream?
        stream.teardown = streamGenerators[streamId].teardown
        stream.pause = streamGenerators[streamId].pause
        stream.resume = ->
          stream.resetFrameRate()
          return streamGenerators[streamId].resume.apply this, arguments
        stream.seek = ->
          stream.resetFrameRate()
          streamGenerators[streamId].seek.apply this, arguments
        stream.getCurrentPlayTime = streamGenerators[streamId].getCurrentPlayTime
        stream.sendVideoPacketsSinceLastKeyFrame =
          streamGenerators[streamId].sendVideoPacketsSinceLastKeyFrame
        stream.isPaused = streamGenerators[streamId].isPaused
        logger.debug "created stream #{stream.id}"
      return stream
    else # recorded dir
      for app, dir of recordedAppToDir
        if streamId[0..app.length] is app + '/'
          filename = streamId[app.length+1..]

          # Strip "filetype:" from "filetype:filename"
          if (match = /^(\w*?):(.*)$/.exec filename)?
            filetype = match[1]
            filename = match[2]
          else
            filetype = 'mp4'  # default extension

          filename = path.normalize filename

          # Check that filename is legitimate
          pathSep = path.sep
          if pathSep is '\\'  # Windows
            pathSep = '\\' + pathSep  # Escape '\' for regex
          if (filename is '.') or
          new RegExp("(^|#{pathSep})..(#{pathSep}|$)").test filename
            logger.warn "rejected request to stream: #{streamId}"
            break

          try
            fs.accessSync "#{dir}/#{filename}", fs.R_OK
          catch e
            # Add extension to the end and try again
            try
              fs.accessSync "#{dir}/#{filename}.#{filetype}", fs.R_OK
              filename = "#{filename}.#{filetype}"
            catch e
              logger.error "error: failed to read #{dir}/#{filename} or #{dir}/#{filename}.#{filetype}: #{e}"
              return null
          stream = MP4Stream.create "#{dir}/#{filename}"
          logger.info "created stream #{stream.id} from #{dir}/#{filename}"
          return stream
      return null

  attachRecordedDirToApp: (dir, appName) ->
    if recordedAppToDir[appName]?
      logger.warn "warning: avstreams.attachRecordedDirToApp: overwriting existing app: #{appName}"
    recordedAppToDir[appName] = dir

  addGenerator: (streamId, generator) ->
    if streamGenerators[streamId]?
      logger.warn "warning: avstreams.addGenerator(): overwriting generator: #{streamId}"
    streamGenerators[streamId] = generator

  removeGenerator: (streamId) ->
    if streamGenerators[streamId]?
      streamGenerators[streamId].teardown()
    delete streamGenerators[streamId]

  createNewStreamId: ->
    retryCount = 0
    loop
      id = createStreamId()
      if not api.exists id
        return id
      retryCount++
      if retryCount >= 100
        throw new Error "avstreams.createNewStreamId: Failed to create new stream id"

  # Creates a new stream.
  # If streamId is not given, a unique id will be generated.
  create: (streamId) ->
    if not streamId?
      streamId = api.createNewStreamId()
    stream = new AVStream streamId
    logger.debug "created stream #{streamId}"
    api.emit 'new', stream
    api.add stream
    return stream

  getOrCreate: (streamId) ->
    stream = streams[streamId]
    if not stream?
      stream = api.create streamId
    return stream

  add: (stream) ->
    if streams[stream.id]?
      logger.warn "warning: overwriting stream: #{stream.id}"
    streams[stream.id] = stream
    api.emit 'add_stream', stream
    stream._onAnyListener = ((stream) ->
      (eventName, data...) ->
        api.emit eventName, stream, data...
        if eventName is 'destroy'
          api.remove stream.id
    )(stream)
    stream.onAny stream._onAnyListener

  remove: (streamId) ->
    if typeof(streamId) is 'object'
      # streamId argument might be stream object
      stream = streamId
      streamId = stream?.id
    else
      stream = streams[streamId]
    if stream?
      stream.offAny stream._onAnyListener
      api.emit 'remove_stream', stream
    delete streams[streamId]

  clear: ->
    streams = {}
    api.emit 'clear_streams'

  dump: ->
    logger.raw "[streams: #{Object.keys(streams).length}]"
    for streamId, stream of streams
      logger.raw " " + stream.toString()

module.exports = api
