h264             = require './h264'
logger           = require './logger'
EventEmitterModule = require './EventEmitterModule'

class AVStream
  constructor: (id) ->
    @id = id # string
    @initAVParams()

  initAVParams: ->
    @audioClockRate      = null  # int
    @audioSampleRate     = null  # int
    @audioChannels       = null  # int
    @audioPeriodSize     = 1024  # TODO: detect from stream?
    @audioObjectType     = null  # int
    @videoWidth          = null  # int
    @videoHeight         = null  # int
    @videoProfileLevelId = null  # string (e.g. '42C01F')
    @videoFrameRate      = 30.0  # float  # TODO
    @videoAVCLevel       = null  # int
    @videoAVCProfile     = null  # int
    @isVideoStarted      = false # boolean
    @isAudioStarted      = false # boolean
    @timeAtVideoStart    = null  # milliseconds since the epoch
    @timeAtAudioStart    = null  # milliseconds since the epoch
    @spropParameterSets  = ''    # string
    @spsString           = ''    # string
    @ppsString           = ''    # string
    @spsNALUnit          = null  # buffer
    @ppsNALUnit          = null  # buffer

  reset: ->
    logger.debug "[stream:#{@id}] reset"
    @initAVParams()
#    @isVideoStarted = false
#    @isAudioStarted = false
#    @rtspUploadingClient = null
#    @spropParameterSets = ''
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
    @videoFrameRate = 30.0  # TODO: What value should we use?

  calcFrameRate: (pts) ->
    if @frameRateCalcBasePTS?
      diffMs = (pts - @frameRateCalcBasePTS) / 90
      @frameRateCalcNumFrames++
      if (@frameRateCalcNumFrames >= 150) or (diffMs >= 5000)
        frameRate = @frameRateCalcNumFrames * 1000 / diffMs
        if frameRate isnt @videoFrameRate
          logger.debug "[stream:#{@id}] frame rate: #{@videoFrameRate}"
          @videoFrameRate = frameRate
          @emit 'update_frame_rate', frameRate
        @frameRateCalcBasePTS = pts
        @frameRateCalcNumFrames = 0
    else
      @frameRateCalcBasePTS = pts
      @frameRateCalcNumFrames = 0

  updateConfig: (obj) ->
    isConfigUpdated = false
    for name, value of obj
      if @[name] isnt value
        @[name] = value
        logger.debug "[stream:#{@id}] update #{name}: #{value}"
        isConfigUpdated = true
    if isConfigUpdated
      @emit 'updateConfig'

  # nal_unit_type 7
  updateSPS: (nalUnit) ->
    if nalUnit isnt @spsNALUnit
      logger.debug "[stream:#{@id}] updated SPS"
      @spsNALUnit = nalUnit
      @updateSpropParam nalUnit
      try
        sps = h264.readSPS nalUnit
      catch e
        console.error "[stream:#{@id}] video data error: failed to read SPS"
        console.error e.stack
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
        @emit 'updateConfig'

  # nal_unit_type 8
  updatePPS: (nalUnit) ->
    if nalUnit isnt @ppsNALUnit
      logger.debug "[stream:#{@id}] updated PPS"
      @ppsNALUnit = nalUnit
      @updateSpropParam nalUnit
      @emit 'updateConfig'

  toString: ->
    return "stream #{@id}: rtspNumClients=#{@rtspNumClients} rtspClients=#{Object.keys(@rtspClients).length}"

EventEmitterModule.mixin AVStream


eventListeners = {}
streams = {}

api =
  AVStream: AVStream

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
    return streams[streamId]

  create: (streamId) ->
    stream = new AVStream streamId
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
      console.warn "warning: overwriting stream: #{stream.id}"
    streams[stream.id] = stream
    api.emit 'add_stream', stream
    stream._onAnyListener = ((stream) ->
      (eventName, data...) ->
        api.emit eventName, stream, data...
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
