net = require 'net'
fs = require 'fs'

config = require './config'
avstreams = require './avstreams'
hybrid_udp = require './hybrid_udp'
logger = require './logger'

TAG = 'custom_receiver'

class CustomReceiver
  constructor: (@type, callback) ->
    if not callback?
      throw new Error "Mandatory callback argument is not passed"
    if not callback.videoControl?
      throw new Error "Mandatory callback.videoControl is not passed"
    if not callback.audioControl?
      throw new Error "Mandatory callback.audioControl is not passed"
    if not callback.videoData?
      throw new Error "Mandatory callback.videoData is not passed"
    if not callback.audioData?
      throw new Error "Mandatory callback.audioData is not passed"

    # We create four separate sockets for receiving different kinds of data.
    # If we have just one socket for receiving all kinds of data, the sender
    # has to lock and synchronize audio/video writer threads and it leads to
    # slightly worse performance.
    if @type in ['unix', 'tcp']
      @videoControlReceiver = @createReceiver 'VideoControl', callback.videoControl
      @audioControlReceiver = @createReceiver 'AudioControl', callback.audioControl
      @videoDataReceiver = @createReceiver 'VideoData', callback.videoData
      @audioDataReceiver = @createReceiver 'AudioData', callback.audioData
    else if @type is 'udp'
      @videoControlReceiver = new hybrid_udp.UDPServer
      @videoControlReceiver.name = 'VideoControl'
      @videoControlReceiver.on 'packet', (buf, addr, port) =>
        logger.info "[custom_receiver] started receiving video"
        if buf.length >= 5
          streamId = buf.toString 'utf8', 4
        else
          streamId = "public"  # TODO: Use default value or throw error?
        @setInternalStreamId streamId
        callback.videoControl @getInternalStream(), buf[3..]
      @audioControlReceiver = new hybrid_udp.UDPServer
      @audioControlReceiver.name = 'AudioControl'
      @audioControlReceiver.on 'packet', (buf, addr, port) =>
        logger.info "[custom_receiver] started receiving audio"
        callback.audioControl @getInternalStream(), buf[3..]
      @videoDataReceiver = new hybrid_udp.UDPServer
      @videoDataReceiver.name = 'VideoData'
      @videoDataReceiver.on 'packet', (buf, addr, port) =>
        callback.videoData @getInternalStream(), buf[3..]
      @audioDataReceiver = new hybrid_udp.UDPServer
      @audioDataReceiver.name = 'AudioData'
      @audioDataReceiver.on 'packet', (buf, addr, port) =>
        callback.audioData @getInternalStream(), buf[3..]
    else
      throw new Error "unknown receiver type: #{@type}"

  getInternalStream: ->
    if not @internalStream?
      logger.warn '[rtsp] warn: Internal stream name not known; using default "public"'
      streamId = 'public'  # TODO: Use default value or throw error?
      @internalStream = avstreams.getOrCreate streamId
    return @internalStream

  setInternalStreamId: (streamId) ->
    if @internalStream? and (@internalStream.id isnt streamId)
      avstreams.remove @internalStream
    logger.info "[rtsp] internal stream name has been set to: #{streamId}"
    stream = avstreams.get streamId
    if stream?
      logger.info "[rtsp] resetting existing stream"
      stream.reset()
    else
      stream = avstreams.create streamId
      stream.type = avstreams.STREAM_TYPE_LIVE
    @internalStream = stream

  start: ->
    if @type is 'unix'
      @startUnix()
    else if @type is 'tcp'
      @startTCP()
    else if @type is 'udp'
      @startUDP()
    else
      throw new Error "unknown receiverType in config: #{@type}"

  startUnix: ->
    @videoControlReceiver.listen config.videoControlReceiverPath, ->
      fs.chmodSync config.videoControlReceiverPath, '777'
      logger.debug "[#{TAG}] videoControl socket: #{config.videoControlReceiverPath}"
    @audioControlReceiver.listen config.audioControlReceiverPath, ->
      fs.chmodSync config.audioControlReceiverPath, '777'
      logger.debug "[#{TAG}] audioControl socket: #{config.audioControlReceiverPath}"
    @videoDataReceiver.listen config.videoDataReceiverPath, ->
      fs.chmodSync config.videoDataReceiverPath, '777'
      logger.debug "[#{TAG}] videoData socket: #{config.videoDataReceiverPath}"
    @audioDataReceiver.listen config.audioDataReceiverPath, ->
      fs.chmodSync config.audioDataReceiverPath, '777'
      logger.debug "[#{TAG}] audioData socket: #{config.audioDataReceiverPath}"

  startTCP: ->
    @videoControlReceiver.listen config.videoControlReceiverPort,
      config.receiverListenHost, config.receiverTCPBacklog, ->
        logger.debug "[#{TAG}] videoControl socket: tcp:#{config.videoControlReceiverPort}"
    @audioControlReceiver.listen config.audioControlReceiverPort,
      config.receiverListenHost, config.receiverTCPBacklog, ->
        logger.debug "[#{TAG}] audioControl socket: tcp:#{config.audioControlReceiverPort}"
    @videoDataReceiver.listen config.videoDataReceiverPort,
      config.receiverListenHost, config.receiverTCPBacklog, ->
        logger.debug "[#{TAG}] videoData socket: tcp:#{config.videoDataReceiverPort}"
    @audioDataReceiver.listen config.audioDataReceiverPort,
      config.receiverListenHost, config.receiverTCPBacklog, ->
        logger.debug "[#{TAG}] audioData socket: tcp:#{config.audioDataReceiverPort}"

  startUDP: ->
    @videoControlReceiver.start config.videoControlReceiverPort, config.receiverListenHost, ->
      logger.debug "[#{TAG}] videoControl socket: udp:#{config.videoControlReceiverPort}"
    @audioControlReceiver.start config.audioControlReceiverPort, config.receiverListenHost, ->
      logger.debug "[#{TAG}] audioControl socket: udp:#{config.audioControlReceiverPort}"
    @videoDataReceiver.start config.videoDataReceiverPort, config.receiverListenHost, ->
      logger.debug "[#{TAG}] videoData socket: udp:#{config.videoDataReceiverPort}"
    @audioDataReceiver.start config.audioDataReceiverPort, config.receiverListenHost, ->
      logger.debug "[#{TAG}] audioData socket: udp:#{config.audioDataReceiverPort}"

  # Delete UNIX domain sockets
  deleteReceiverSocketsSync: ->
    if @type is 'unix'
      if fs.existsSync config.videoControlReceiverPath
        try
          fs.unlinkSync config.videoControlReceiverPath
        catch e
          logger.error "unlink error: #{e}"
      if fs.existsSync config.audioControlReceiverPath
        try
          fs.unlinkSync config.audioControlReceiverPath
        catch e
          logger.error "unlink error: #{e}"
      if fs.existsSync config.videoDataReceiverPath
        try
          fs.unlinkSync config.videoDataReceiverPath
        catch e
          logger.error "unlink error: #{e}"
      if fs.existsSync config.audioDataReceiverPath
        try
          fs.unlinkSync config.audioDataReceiverPath
        catch e
          logger.error "unlink error: #{e}"
    return

  createReceiver: (name, callback) ->
    return net.createServer (c) =>
      logger.info "[custom_receiver] new connection to #{name}"
      buf = null
      c.on 'close', ->
        logger.info "[custom_receiver] connection to #{name} closed"
      c.on 'data', (data) =>
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
              if name is 'VideoControl'  # parse stream name
                if buf.length >= 5
                  streamId = buf.toString 'utf8', 4, totalSize
                else
                  streamId = "public"  # TODO: Use default value or throw error?
                @setInternalStreamId streamId

              # 3 bytes for payload size
              callback @getInternalStream(), buf.slice(3, totalSize)
              if buf.length > totalSize
                buf = buf.slice totalSize
              else
                buf = null
                break
            else
              break
        return

module.exports = CustomReceiver
