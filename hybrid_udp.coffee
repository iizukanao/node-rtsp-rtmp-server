# Hybrid UDP
# - can send fire-and-forget (unreliable) packet
# - can send reliable packet which requires ACK

###
# Usage

    hybrid_udp = require './hybrid_udp'

    server = new hybrid_udp.UDPServer
    server.on 'packet', (buf, addr, port) ->
      # buf is a Buffer instance
      console.log "server received: 0x#{buf.toString 'hex'}"
      if buf[0] is 0x04
        # shutdown server
        server.stop()
        console.log "server stopped"
    server.start 9999, "localhost", ->
      console.log "server started"

      client = new hybrid_udp.UDPClient
      client.start 9999, "localhost", ->
        console.log "client started"
        console.log "client: writing 0x010203"
        client.write new Buffer([0x01, 0x02, 0x03]), ->
          console.log "client: writing 0x040506 and waiting for ACK"
          client.writeReliable new Buffer([0x04, 0x05, 0x06]), ->
            console.log "client: received ACK"
            client.stop()
            console.log "client stopped"
###

events = require 'events'
dgram = require 'dgram'

logger = require './logger'

MAX_PACKET_ID = 255
FRAGMENT_HEADER_LEN = 2

RESEND_TIMEOUT = 100  # ms

PACKET_TYPE_UNRELIABLE  = 0x01
PACKET_TYPE_REQUIRE_ACK = 0x02
PACKET_TYPE_ACK         = 0x03
PACKET_TYPE_RESET       = 0x04

OLD_UDP_PACKET_TIME_THRESHOLD = 1000

RECEIVE_PACKET_ID_WINDOW = 10

INITIAL_PACKET_ID = 0

zeropad = (width, num) ->
  num += ''
  while num.length < width
    num = '0' + num
  return num

exports.UDPClient = class UDPClient
  constructor: ->
    @pendingPackets = []
    @newPacketId = 0
    @maxPacketSize = 8000  # good for LAN?
#    @maxPacketSize = 1472  # good for internet
    @isInBlockMode = false
    @ackCallbacks = {}
    @serverPort = null
    @serverHost = null
    @isStopped = false

    @socket = dgram.createSocket 'udp4'

    @socket.on 'error', (err) ->
      logger.error "UDPServer socket error: #{err}"
      @socket.close()

    @socket.on 'message', (msg, rinfo) =>
      @onMessage msg, rinfo

  start: (serverPort, serverHost, callback) ->
    @serverPort = serverPort
    @serverHost = serverHost
    # bind to any available port
    @socket.bind 0, '0.0.0.0', =>
      @resetPacketId callback

  stop: ->
    @isStopped = true
    @socket.close()

  onMessage: (msg, rinfo) ->
    packetType = msg[0]
    if packetType is PACKET_TYPE_ACK
      packetId = msg[1]
      if @ackCallbacks[packetId]?
        @ackCallbacks[packetId]()
      else
        logger.warn "ACK is already processed for packetId #{packetId}"
    else
      logger.warn "unknown packet type: #{packetType} len=#{msg.length}"
      logger.warn msg

  getNextPacketId: ->
    id = @newPacketId
    if ++@newPacketId > MAX_PACKET_ID
      @newPacketId = 0
    return id

  sendPacket: (packetType, packetId, buf, callback) ->
    sendData = new Buffer @maxPacketSize
    sendData[0] = packetType
    sendData[1] = packetId

    fragmentSize = @maxPacketSize - FRAGMENT_HEADER_LEN - 2
    if fragmentSize <= 0
      throw new Error "maxPacketSize must be > #{FRAGMENT_HEADER_LEN + 2}"
    bufLen = buf.length
    totalFragments = Math.ceil bufLen / fragmentSize
    # maximum number of fragments is 256
    if totalFragments > 256
      throw new Error "too many fragments: #{totalFragments} (buf.length=#{bufLen} / fragmentSize=#{fragmentSize})"
    endFragmentNumber = totalFragments - 1
    sendData[2] = endFragmentNumber

    fragmentNumber = 0
    wroteLen = 0
    sentCount = 0

    sendNextFragment = =>
      if wroteLen >= bufLen
        throw new Error "wroteLen (#{wroteLen}) > bufLen (#{bufLen})"
      remainingLen = bufLen - wroteLen
      if remainingLen < fragmentSize
        thisLen = remainingLen
      else
        thisLen = fragmentSize
      sendData[3] = fragmentNumber
      buf.copy sendData, 4, wroteLen, wroteLen + thisLen
      fragmentNumber++
      @socket.send sendData, 0, thisLen + 4, @serverPort, @serverHost, =>
        wroteLen += thisLen
        sentCount++
        if sentCount is totalFragments
          callback?()
        else
          sendNextFragment()

    sendNextFragment()

  resetPacketId: (callback) ->
    buf = new Buffer [
      # packet type
      PACKET_TYPE_RESET,
      # packet id
      INITIAL_PACKET_ID,
    ]
    @newPacketId = INITIAL_PACKET_ID + 1

    isACKReceived = false

    # wait until receives ack
    @waitForACK INITIAL_PACKET_ID, ->
      isACKReceived = true
      callback?()

    # send
    @socket.send buf, 0, buf.length, @serverPort, @serverHost

    setTimeout =>
      if not isACKReceived and not @isStopped
        logger.warn "resend reset (no ACK received)"
        @resetPacketId callback
    , RESEND_TIMEOUT

  rawSend: (buf, offset, length, callback) ->
    @socket.send buf, offset, length, @serverPort, @serverAddress, callback

  write: (buf, callback) ->
    if @isInBlockMode
      @pendingPackets.push [@write, arguments...]
      return

    packetId = @getNextPacketId()
    @sendPacket PACKET_TYPE_UNRELIABLE, packetId, buf, callback

  _writeReliableBypassBlock: (buf, packetId, onSuccessCallback, onTimeoutCallback) ->
    isACKReceived = false

    # wait until receives ack
    @waitForACK packetId, ->
      isACKReceived = true
      onSuccessCallback?()

    # send
    @sendPacket PACKET_TYPE_REQUIRE_ACK, packetId, buf

    setTimeout =>
      if not isACKReceived and not @isStopped
        logger.warn "resend #{packetId} (no ACK received)"
        onTimeoutCallback()
    , RESEND_TIMEOUT

  _writeReliable: (buf, packetId, callback) ->
    if @isInBlockMode
      @pendingPackets.push [@_writeReliable, arguments...]
      # TODO: limit maximum number of pending packets
      return

    @_writeReliableBypassBlock buf, packetId, callback, =>
      @_writeReliable buf, packetId, callback

  writeReliable: (buf, callback) ->
    packetId = @getNextPacketId()
    @_writeReliable buf, packetId, callback

  waitForACK: (packetId, callback) ->
    @ackCallbacks[packetId] = =>
      delete @ackCallbacks[packetId]
      callback?()

  flushPendingPackets: (callback) ->
    if @pendingPackets.length is 0
      callback?()
      return

    packet = @pendingPackets.shift()
    func = packet[0]
    args = packet[1..]
    origCallback = args[func.length-1]
    args[func.length-1] = =>
      @flushPendingPackets callback
      origCallback?()
    func.apply this, args

  _writeReliableBlocked: (buf, packetId, callback) ->
    @_writeReliableBypassBlock buf, packetId, callback, =>
      @_writeReliableBlocked buf, packetId, callback

  # Defer other packets until this packet is received
  writeReliableBlocked: (buf, callback) ->
    if @isInBlockMode
      @pendingPackets.push [@writeReliableBlocked, arguments...]
      return

    @isInBlockMode = true

    packetId = @getNextPacketId()
    @_writeReliableBlocked buf, packetId, =>
      @isInBlockMode = false
      @flushPendingPackets callback

  fragment: (buf, fragmentSize=maxPacketSize) ->
    fragments = []
    remainingLen = buf.length
    while remainingLen > 0
      if remainingLen < fragmentSize
        thisLen = remainingLen
      else
        thisLen = fragmentSize
      fragments.push buf[0...thisLen]
      buf = buf[thisLen..]
    return fragments

exports.UDPServer = class UDPServer extends events.EventEmitter
  constructor: ->
    super()
    @socket = dgram.createSocket 'udp4'

    @socket.on 'error', (err) ->
      logger.error "UDPServer socket error: #{err}"
      @socket.close()

    @socket.on 'message', (msg, rinfo) =>
      @onReceiveMessage msg, rinfo

    @isStopped = false
    @resetServerState()

  resetServerState: ->
    @videoReceiveBuf = {}
    @processedPacketId = null
    @latestPacketId = null
    @bufferedPackets = {}
    @packetLastReceiveTime = {}

  onReceiveMessage: (msg, rinfo) ->
    packetType = msg[0]
    packetId = msg[1]
    endFragmentNumber = msg[2]
    fragmentNumber = msg[3]

    if packetType is PACKET_TYPE_RESET
      @resetServerState()
      @latestPacketId = packetId
      @processedPacketId = packetId
      @sendAck packetId, rinfo.port, rinfo.address
      return

    @packetLastReceiveTime[packetId] = Date.now()

    if @latestPacketId?
      if (packetId <= @latestPacketId + RECEIVE_PACKET_ID_WINDOW and
      packetId > @latestPacketId) or
      packetId < @latestPacketId - 50
        @latestPacketId = packetId
    else
      @latestPacketId = packetId

    if endFragmentNumber > 0  # fragmentation
      if @videoReceiveBuf[packetId]?
        # check if existing packet is too old
        if Date.now() - @videoReceiveBuf[packetId].time >= OLD_UDP_PACKET_TIME_THRESHOLD
          logger.warn "drop stale buffer of packetId #{packetId}"
          @videoReceiveBuf[packetId] = null
      if not @videoReceiveBuf[packetId]?
        @videoReceiveBuf[packetId] =
          buf: []
          totalReceivedLength: 0
      targetBuf = @videoReceiveBuf[packetId]
      targetBuf.buf[fragmentNumber] = msg[4..]
      targetBuf.time = Date.now()
      targetBuf.totalReceivedLength += msg.length - 4
      isMissing = false
      for i in [0..endFragmentNumber]
        if not targetBuf.buf[i]?
          isMissing = true
          break
      if not isMissing  # received all fragments
        try
          receivedBuf = Buffer.concat targetBuf.buf
          @onReceivePacket
            packetType: packetType
            packetId: packetId
            port: rinfo.port
            address: rinfo.address
            body: receivedBuf
        catch e
          logger.error "concat/receive error for packetId=#{packetId}: #{e}"
          logger.error e.stack
          logger.error targetBuf.buf
        finally
          delete @videoReceiveBuf[packetId]
          delete @packetLastReceiveTime[packetId]
    else  # no fragmentation
      receivedBuf = msg[4..]
      delete @videoReceiveBuf[packetId]
      delete @packetLastReceiveTime[packetId]
      @onReceivePacket
        packetType: packetType
        packetId: packetId
        port: rinfo.port
        address: rinfo.address
        body: receivedBuf

  consumeBufferedPacketsFrom: (packetId) ->
    oldEnoughTime = Date.now() - OLD_UDP_PACKET_TIME_THRESHOLD
    loop
      if not @bufferedPackets[packetId]?
        break
      if @packetLastReceiveTime[packetId] <= oldEnoughTime
        logger.warn "packet #{packetId} is too old"
        break
      @onCompletePacket @bufferedPackets[packetId]
      delete @bufferedPackets[packetId]
      @processedPacketId = packetId
      if packetId is MAX_PACKET_ID
        packetId = 0
      else
        packetId++
    return

  deleteOldBufferedPackets: ->
    if @processedPacketId is @latestPacketId
      return

    isDoneSomething = false
    if @processedPacketId is MAX_PACKET_ID
      oldestUnprocessedPacketId = 0
    else
      oldestUnprocessedPacketId = @processedPacketId + 1
    oldEnoughTime = Date.now() - OLD_UDP_PACKET_TIME_THRESHOLD
    for packetId in [oldestUnprocessedPacketId...@latestPacketId]
      if not @packetLastReceiveTime[packetId]?
        @packetLastReceiveTime[packetId] = Date.now()
      if @packetLastReceiveTime[packetId] <= oldEnoughTime
        # Failed to receive a packet
        timeDiff = oldEnoughTime - @packetLastReceiveTime[packetId]
        logger.warn "dropped packet #{packetId}: #{timeDiff} ms late"
        isDoneSomething = true
        if @bufferedPackets[packetId]?
          delete @bufferedPackets[packetId]
        if @processedPacketId is MAX_PACKET_ID
          @processedPacketId = 0
        else
          @processedPacketId++
      else
        break
    if isDoneSomething
      if @processedPacketId is MAX_PACKET_ID
        nextPacketId = 0
      else
        nextPacketId = @processedPacketId + 1
      @consumeBufferedPacketsFrom nextPacketId
    return

  onReceivePacket: (packet) ->
    anticipatingPacketId = @processedPacketId + 1
    if anticipatingPacketId is MAX_PACKET_ID + 1
      anticipatingPacketId = 0
    if packet.packetId is anticipatingPacketId  # continuous
      @processedPacketId = packet.packetId
      @onCompletePacket packet
      if packet.packetId is MAX_PACKET_ID
        nextPacketId = 0
      else
        nextPacketId = packet.packetId + 1
      @consumeBufferedPacketsFrom nextPacketId
    else  # non-continuous
      if @processedPacketId - RECEIVE_PACKET_ID_WINDOW <= packet.packetId <= @processedPacketId
        logger.warn "duplicated packet #{packet.packetId}"
        if packet.packetType is PACKET_TYPE_REQUIRE_ACK
          @sendAck packet.packetId, packet.port, packet.address
        return
      @bufferedPackets[packet.packetId] = packet
      @deleteOldBufferedPackets()

  onCompletePacket: (packet) ->
    if packet.packetType is PACKET_TYPE_REQUIRE_ACK
      @sendAck packet.packetId, packet.port, packet.address

    setTimeout =>
      @emit 'packet', packet.body, packet.address, packet.port
    , 0

  sendAck: (packetId, port, address, callback) ->
    buf = new Buffer [
      # packet type
      PACKET_TYPE_ACK,
      # packet id
      packetId
    ]
    @socket.send buf, 0, buf.length, port, address, callback

  start: (port, address, callback) ->
    @socket.bind port, address, callback

  stop: ->
    @isStopped = true
    @socket.close()
