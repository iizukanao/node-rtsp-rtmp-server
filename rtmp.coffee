net           = require 'net'
crypto        = require 'crypto'
Sequent       = require 'sequent'
RTMPHandshake = require './rtmp_handshake'

codecUtils    = require './codec_utils'
config        = require './config'

# enum
SESSION_STATE_NEW = 1
SESSION_STATE_HANDSHAKE_ONGOING = 2
SESSION_STATE_HANDSHAKE_DONE = 3

TIMESTAMP_ROUNDOFF = 4294967296  # 32 bits

sessionsCount = 0
sessions = {}
rtmptSessionsCount = 0
rtmptSessions = {}

clientMaxId = 0

lastTimestamp = null

codecConfigPackets = []
spsPacket = null  # NAL unit type 7: Sequence parameter set
ppsPacket = null  # NAL unit type 8: Picture parameter set

calcHmac = (data, key) ->
  hmac = crypto.createHmac 'sha256', key
  hmac.update data
  return hmac.digest()

# Generate a new client ID without collision
generateNewClientID = ->
  clientID = generateClientID()
  while sessions[clientID]?
    clientID = generateClientID()
  return clientID

# Generate a new random client ID (like Cookie)
generateClientID = ->
  possible = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  numPossible = possible.length
  clientID = ''
  for i in [0..7]
    clientID += possible.charAt((Math.random() * numPossible) | 0)
  return clientID

retainCodecConfigPacket = (buf) ->
  if codecConfigPackets.length >= 2
    console.error "Error: no more codec config is needed"
    return
  codecConfigPackets.push buf
  nalUnitType = buf[0] & 0x1f
  console.log "[rtmp] Retained codec config for NAL unit type #{nalUnitType}"
  for b in buf
    process.stdout.write b.toString(16) + " "
  console.log()
  if nalUnitType is 7
    spsPacket = buf
  else if nalUnitType is 8
    ppsPacket = buf
  else
    console.error "Unknown NAL unit type: #{nalUnitType}"

parseAcknowledgementMessage = (buf) ->
  sequenceNumber = (buf[0] << 24) + (buf[1] << 16) + (buf[2] << 8) + buf[3]
  return {
    sequenceNumber: sequenceNumber
  }

convertPTSToMilliseconds = (pts) ->
  Math.round pts / 90

createAudioMessage = (params) ->
  # TODO: Use type 1/2/3
  audioMessage = createRTMPMessage
    chunkStreamID: 4
    timestamp: params.timestamp
    messageTypeID: 0x08  # Audio Data
    messageStreamID: 1
    body: params.body
  , params.chunkSize

sendVideoMessage = (params) ->
  allSessions = []
  for clientID, session of rtmptSessions
    allSessions.push session.rtmpSession

  for clientID, session of sessions
    allSessions.push session

  for session in allSessions
    if session.isWaitingForKeyFrame and params.isKeyFrame
      session.isFirstVideoMessage = true
      session.isFirstAudioMessage = true
      session.isPlaying = true
      session.playStartTimestamp = params.timestamp
      session.isWaitingForKeyFrame = false
    if session.isPlaying
      messages = []
      if session.isFirstVideoMessage
        emptyVideoMessage = session.createVideoMessage
          body: new Buffer [
            (5 << 4) | config.videoCodecId,
            0x00
          ]
          timestamp: 0
          chunkSize: @chunkSize
        messages.push emptyVideoMessage
        session.isFirstVideoMessage = false
      videoMessage = session.createVideoMessage
        body: params.body
        timestamp: session.getScaledTimestamp params.timestamp
        chunkSize: session.chunkSize
      messages.push videoMessage
      session.sendData messages

sendAudioMessage = (params) ->
  allSessions = []
  for clientID, session of rtmptSessions
    allSessions.push session.rtmpSession

  for clientID, session of sessions
    allSessions.push session

  for session in allSessions
    if session.isPlaying
      messages = []
      if session.isFirstAudioMessage
        emptyAudioMessage = session.createAudioMessage
          body: new Buffer []
          timestamp: 0
          chunkSize: @chunkSize
        messages.push emptyAudioMessage
        session.isFirstAudioMessage = false
      audioMessage = session.createAudioMessage
        body: params.body
        timestamp: session.getScaledTimestamp params.timestamp
        chunkSize: session.chunkSize
      messages.push audioMessage
      session.sendData messages

queueVideoMessage = (params) ->
  params.avType = 'video'
  params.chunkStreamID = 4
  params.messageTypeID = 0x09  # Video Data
  params.messageStreamID = 1
  params.originalTimestamp = params.timestamp
  queuedRTMPMessages.push params
  queuedRTMPMessages.sort (a, b) ->
    a.timestamp - b.timestamp

  setImmediate flushRTMPMessages

queueAudioMessage = (params) ->
  params.avType = 'audio'
  params.chunkStreamID = 4
  params.messageTypeID = 0x08  # Audio Data
  params.messageStreamID = 1
  params.originalTimestamp = params.timestamp
  queuedRTMPMessages.push params
  queuedRTMPMessages.sort (a, b) ->
    a.timestamp - b.timestamp

  setImmediate flushRTMPMessages

createVideoMessage = (params) ->
  # TODO: Use type 1/2/3
  videoMessage = createRTMPMessage
    chunkStreamID: 4
    timestamp: params.timestamp
    messageTypeID: 0x09  # Video Data
    messageStreamID: 1
    body: params.body
  , params.chunkSize

parseUserControlMessage = (buf) ->
  eventType = (buf[0] << 8) + buf[1]
  eventData = buf[2..]
  message =
    eventType: eventType
    eventData: eventData
  if eventType is 3  # SetBufferLength
    # first 4 bytes: stream ID
    message.streamID = (eventData[0] << 24) + (eventData[1] << 16) +
      (eventData[2] << 8) + eventData[3]
    # next 4 bytes: buffer length in milliseconds
    message.bufferLength = (eventData[4] << 24) + (eventData[5] << 16) +
      (eventData[6] << 8) + eventData[7]
  return message

parseIEEE754Double = (buf) ->
  sign = buf[0] >> 7  # 1 == negative
  exponent = ((buf[0] & 0b1111111) << 4) + (buf[1] >> 4)
  exponent -= 1023  # because 1023 means zero
  fraction = 1
  for i in [0..51]
    byteIndex = 1 + parseInt (i + 4) / 8
    bitIndex = 7 - (i + 4) % 8
    bitValue = (buf[byteIndex] >> bitIndex) & 0b1
    if bitValue > 0
      fraction += Math.pow(2, -(i+1))
  value = fraction * Math.pow 2, exponent
  if sign is 1
    value = -value
  value

parseAMF0StrictArray = (buf) ->
  arr = []
  len = (buf[0] << 24) + (buf[1] << 16) + (buf[2] << 8) + buf[3]
  readLen = 4
  while len-- >= 0
    result = parseAMF0Data buf[readLen..]
    arr.push result.value
    readLen += result.readLen
  return { value: arr, readLen: readLen }

parseAMF0ECMAArray = (buf) ->
  obj = {}
  bufLen = buf.length
  readLen = 0
  while readLen < bufLen
    nameLen = (buf[readLen++] << 8) + buf[readLen++]
    name = buf.toString 'utf8', readLen, readLen + nameLen
    readLen += nameLen
    result = parseAMF0Data buf[readLen..]
    readLen += result.readLen
    if result.type is 'object-end-marker'
      break
    obj[name] = result.value
  return { value: obj, readLen: readLen }

# Decode buffer into AMF0 packets
parseAMF0CommandMessage = (buf) ->
  amf0Packets = []
  remainingLen = buf.length
  while remainingLen > 0
    result = parseAMF0Data buf
    amf0Packets.push result
    remainingLen -= result.readLen
    buf = buf[result.readLen..]
  return {
    command: amf0Packets[0].value
    transactionID: amf0Packets[1].value
    objects: amf0Packets[2..]
  }

parseAMF0Data = (buf) ->
  i = 0
  type = buf[i++]
  if type is 0x00  # number-marker
    value = buf.readDoubleBE i
    return { type: 'number', value: value, readLen: i + 8 }
  else if type is 0x01  # boolean-marker
    value = if buf[i] is 0x00 then false else true
    return { type: 'boolean', value: value, readLen: i + 1 }
  else if type is 0x02  # string-marker
    strLen = (buf[i++] << 8) + buf[i++]
    value = buf.toString 'utf8', i, i+strLen
    return { type: 'string', value: value, readLen: i + strLen }
  else if type is 0x03  # object-marker
    result = parseAMF0ECMAArray buf[i..]
    return { type: 'object', value: result.value, readLen: i + result.readLen }
  else if type is 0x05  # null-marker
    return { type: 'null', value: null, readLen: i }
  else if type is 0x06  # undefined-marker
    return { type: 'undefined', value: undefined, readLen: i }
  else if type is 0x08  # ecma-array-marker
    # associative-count (4 bytes) is safe to be ignored, right?
    result = parseAMF0ECMAArray buf[i+4..]
    return { type: 'array', value: result.value, readLen: i + 4 + result.readLen }
  else if type is 0x09  # object-end-marker
    return { type: 'object-end-marker', readLen: 3 }
  else if type is 0x0a  # strict-array-marker
    result = parseAMF0StrictArray buf[i..]
    return { type: 'strict-array', value: result.value, readLen: i + result.readLen }
  else if type is 0x0b  # date-marker
    time = buf.readDoubleBE i
    date = new Date(time)
    return { type: 'date', value: date, readLen: i + 10 }  # 8 (time) + 2 (time-zone)
  else
    throw new Error "Unknown data type for AMF0: #{type}"

createAMF0Data = (data) ->
  type = typeof data
  buf = null
  if type is 'number'
    buf = new Buffer 9
    buf[0] = 0x00  # number-marker
    buf.writeDoubleBE data, 1
  else if type is 'boolean'
    buf = new Buffer 2
    buf[0] = 0x01  # boolean-marker
    buf[1] = if data then 0x01 else 0x00
  else if type is 'string'
    buf = new Buffer 3
    buf[0] = 0x02  # string-marker
    strBytes = new Buffer data, 'utf8'
    strLen = strBytes.length
    buf[1] = (strLen >> 8) & 0xff
    buf[2] = strLen & 0xff
    buf = Buffer.concat [buf, strBytes], 3 + strLen
  else if data is null
    buf = new Buffer [ 0x05 ]  # null-marker
  else if type is 'undefined'
    buf = new Buffer [ 0x06 ]  # undefined-marker
  else if data instanceof Date
    buf = new Buffer 11
    buf[0] = 0x0b  # date-marker
    buf.writeDoubleBE data.getTime(), 1
    # Time-zone should be 0x0000
    buf[9] = 0
    buf[10] = 0
  else if data instanceof Array
    buf = new Buffer [ 0x0a ]  # strict-array-marker
    buf = createAMF0StrictArray data, buf
  else if type is 'object'
    count = Object.keys(data).length
    buf = new Buffer [
      # ecma-array-marker
      0x08,
      # array-count
      (count >>> 24) & 0xff,
      (count >>> 16) & 0xff,
      (count >>> 8) & 0xff,
      count & 0xff
    ]
    buf = createAMF0ECMAArray data, buf
  else
    throw new Error "Unknown data type \"#{type}\" for data #{data}"
  buf

createAMF0StrictArray = (arr, buf=null) ->
  bufs = []
  totalLength = 0
  if buf?
    bufs.push buf
    totalLength += buf.length

  # array-count (U32)
  arrLen = arr.length
  bufs.push new Buffer [
    (arrLen >>> 24) & 0xff,
    (arrLen >>> 16) & 0xff,
    (arrLen >>> 8) & 0xff,
    arrLen & 0xff
  ]
  totalLength += 4

  for value, i in arr
    valueBytes = createAMF0Data value
    bufs.push valueBytes
    totalLength += valueBytes.length
  return Buffer.concat bufs, totalLength

createAMF0Object = (obj) ->
  buf = new Buffer [ 0x03 ]  # object-marker
  return createAMF0ECMAArray obj, buf

createAMF0ECMAArray = (obj, buf=null) ->
  bufs = []
  totalLength = 0
  if buf?
    bufs.push buf
    totalLength += buf.length
  for name, value of obj
    nameBytes = new Buffer name, 'utf8'
    nameLen = nameBytes.length
    nameLenBytes = new Buffer 2
    nameLenBytes[0] = (nameLen >> 8) & 0xff
    nameLenBytes[1] = nameLen & 0xff
    dataBytes = createAMF0Data value
    bufs.push nameLenBytes, nameBytes, dataBytes
    totalLength += 2 + nameLen + dataBytes.length

  # Add object-end-marker
  bufs.push new Buffer [0x00, 0x00, 0x09]
  totalLength += 3

  return Buffer.concat bufs, totalLength

queuedRTMPMessages = []

counter = 0

flushRTMPMessages = ->
  if queuedRTMPMessages.length < config.rtmpMessageQueueSize
    return

  mostRecentAVType = queuedRTMPMessages[queuedRTMPMessages.length-1].avType
  largestIndex = null
  for i in [queuedRTMPMessages.length-2..0]
    rtmpMessage = queuedRTMPMessages[i]
    if rtmpMessage.avType isnt mostRecentAVType
      largestIndex = i
      break
  if largestIndex is null
    return

  rtmpMessagesToSend = queuedRTMPMessages[0..largestIndex]
  queuedRTMPMessages = queuedRTMPMessages[largestIndex+1..]

  allSessions = []
  for clientID, session of rtmptSessions
    allSessions.push session.rtmpSession

  for clientID, session of sessions
    allSessions.push session

  for session in allSessions
    msgs = null
    if session.isWaitingForKeyFrame
      for rtmpMessage, i in rtmpMessagesToSend
        if rtmpMessage.avType is 'video' and rtmpMessage.isKeyFrame
          session.isPlaying = true
          session.playStartTimestamp = rtmpMessage.originalTimestamp
          session.isWaitingForKeyFrame = false
          msgs = rtmpMessagesToSend[i..]
          break
    else
      msgs = rtmpMessagesToSend

    if not msgs?
      continue

    if session.isPlaying
      for rtmpMessage in msgs
        rtmpMessage.timestamp = session.getScaledTimestamp(rtmpMessage.originalTimestamp) % TIMESTAMP_ROUNDOFF

      if msgs.length > 1
        buf = createRTMPAggregateMessage msgs, session.chunkSize
      else
        buf = createRTMPMessage msgs[0], session.chunkSize
      session.sendData buf

  return

createMessageHeader = (params) ->
  payloadLength = params.body.length
  if not params.messageTypeID?
    console.warn "Warning: createMessageHeader(): messageTypeID is not set"
  if not params.timestamp?
    console.warn "Warning: createMessageHeader(): timestamp is not set"
  if not params.messageStreamID?
    console.warn "Warning: createMessageHeader(): messageStreamID is not set"
  # 6.1.1.  Message Header
  return new Buffer [
    params.messageTypeID,
    # Payload length (3 bytes) big-endian
    (payloadLength >> 16) & 0xff,
    (payloadLength >> 8) & 0xff,
    payloadLength & 0xff,
    # Timestamp (4 bytes) big-endian (unusual format; not sure)
    (params.timestamp >>> 16) & 0xff,
    (params.timestamp >>> 8) & 0xff,
    params.timestamp & 0xff,
    (params.timestamp >>> 24) & 0xff,
    # Stream ID (3 bytes) big-endian
    (params.messageStreamID >> 16) & 0xff,
    (params.messageStreamID >> 8) & 0xff,
    params.messageStreamID & 0xff,
  ]

# All sub-messages must have the same chunk stream ID
createRTMPAggregateMessage = (rtmpMessages, chunkSize) ->
  bufs = []
  totalLength = 0
  aggregateTimestamp = null
  for rtmpMessage in rtmpMessages
    if not aggregateTimestamp?
      aggregateTimestamp = rtmpMessage.timestamp

    header = createMessageHeader rtmpMessage
    len = header.length + rtmpMessage.body.length
    bufs.push header, rtmpMessage.body, new Buffer [
      # Back pointer (UI32)
      (len >>> 24) & 0xff,
      (len >>> 16) & 0xff,
      (len >>> 8) & 0xff,
      len & 0xff
    ]
    totalLength += len + 4
  aggregateBody = Buffer.concat bufs, totalLength

  createRTMPMessage
    chunkStreamID: 4
    timestamp: aggregateTimestamp
    messageTypeID: 22  # Aggregate Message
    messageStreamID: 1
    body: aggregateBody
  , chunkSize

createRTMPType1Message = (params) ->
  bodyLength = params.body.length
  formatTypeID = 1
  if not params.body?
    console.warn "Warning: createRTMPType1Message(): body is not set for RTMP message"
  if not params.chunkStreamID?
    console.warn "Warning: createRTMPType1Message(): chunkStreamID is not set for RTMP message"
  if not params.timestampDelta?
    console.warn "Warning: createRTMPType1Message(): timestampDelta is not set for RTMP message"
  if not params.messageStreamID?
    console.warn "Warning: createRTMPType1Message(): messageStreamID is not set for RTMP message"
  useExtendedTimestamp = false
  if params.timestampDelta >= 0xffffff
    useExtendedTimestamp = true
    ordinaryTimestampBytes = [ 0xff, 0xff, 0xff ]
  else
    ordinaryTimestampBytes = [
      (params.timestampDelta >> 16) & 0xff,
      (params.timestampDelta >> 8) & 0xff,
      params.timestampDelta & 0xff,
    ]

  # Header for Type 1 Chunk Message Header
  header = new Buffer [
    # Format (2 bits), Chunk Stream ID (6 bits)
    (formatTypeID << 6) | params.chunkStreamID,
    # Timestamp Delta (3 bytes)
    ordinaryTimestampBytes[0],
    ordinaryTimestampBytes[1],
    ordinaryTimestampBytes[2],
    # Message Length (3 bytes)
    (bodyLength >> 16) & 0xff,
    (bodyLength >> 8) & 0xff,
    bodyLength & 0xff,
    # Message Type ID (1 byte)
    params.messageTypeID,
  ]
  if useExtendedTimestamp
    extendedTimestamp = new Buffer [
      (params.timestampDelta >> 24) & 0xff,
      (params.timestampDelta >> 16) & 0xff,
      (params.timestampDelta >> 8) & 0xff,
      params.timestampDelta & 0xff,
    ]
    header = Buffer.concat [
      header, extendedTimestamp
    ], 12
  body = params.body
  return Buffer.concat [header, body], 8 + bodyLength

createRTMPMessage = (params, chunkSize=128) ->
  bodyLength = params.body.length
  # TODO: Use format type ID 1 and 2
  formatTypeID = 0
  if not params.body?
    console.warn "Warning: createRTMPMessage(): body is not set for RTMP message"
  if not params.chunkStreamID?
    console.warn "Warning: createRTMPMessage(): chunkStreamID is not set for RTMP message"
  if not params.timestamp?
    console.warn "Warning: createRTMPMessage(): timestamp is not set for RTMP message"
  if not params.messageStreamID?
    console.warn "Warning: createRTMPMessage(): messageStreamID is not set for RTMP message"
  useExtendedTimestamp = false
  if params.timestamp >= 0xffffff
    useExtendedTimestamp = true
    timestamp = [ 0xff, 0xff, 0xff ]
  else
    timestamp = [
      (params.timestamp >> 16) & 0xff,
      (params.timestamp >> 8) & 0xff,
      params.timestamp & 0xff,
    ]

  bufs = [
    # Header for Type 0 Chunk Message Header
    new Buffer [
      # Format (2 bits), Chunk Stream ID (6 bits)
      (formatTypeID << 6) | params.chunkStreamID,
      # Timestamp (3 bytes)
      timestamp[0],
      timestamp[1],
      timestamp[2],
      # Message Length (3 bytes)
      (bodyLength >> 16) & 0xff,
      (bodyLength >> 8) & 0xff,
      bodyLength & 0xff,
      # Message Type ID (1 byte)
      params.messageTypeID,
      # Message Stream ID (4 bytes) little-endian
      params.messageStreamID & 0xff
      (params.messageStreamID >>> 8) & 0xff,
      (params.messageStreamID >>> 16) & 0xff,
      (params.messageStreamID >>> 24) & 0xff,
    ]
  ]
  totalLength = 12
  if useExtendedTimestamp
    bufs.push new Buffer [
      (params.timestamp >> 24) & 0xff,
      (params.timestamp >> 16) & 0xff,
      (params.timestamp >> 8) & 0xff,
      params.timestamp & 0xff,
    ]
    totalLength += 4
  body = params.body
  if bodyLength > chunkSize
    bufs.push body[0...chunkSize]
    totalLength += chunkSize
    body = body[chunkSize..]
    bodyLength -= chunkSize

    # Use Format Type 3 for remaining chunks
    type3Header = new Buffer [
      (3 << 6) | params.chunkStreamID
    ]
    loop
      bodyChunk = body[0...chunkSize]
      bodyChunkLen = bodyChunk.length
      bufs.push type3Header, bodyChunk
      totalLength += 1 + bodyChunkLen
      body = body[bodyChunkLen..]
      bodyLength -= bodyChunkLen
      if bodyLength is 0
        break
  else
    bufs.push body
    totalLength += bodyLength

  return Buffer.concat bufs, totalLength

createAMF0DataMessage = (params, chunkSize) ->
  len = 0
  for obj in params.objects
    len += obj.length
  amf0Bytes = Buffer.concat params.objects, len
  return createRTMPMessage
    chunkStreamID: params.chunkStreamID
    timestamp: params.timestamp
    messageTypeID: 0x12  # AMF0 Data
    messageStreamID: params.messageStreamID
    body: amf0Bytes
  , chunkSize

createAMF0CommandMessage = (params, chunkSize) ->
  commandBuf = createAMF0Data(params.command)
  transactionIDBuf = createAMF0Data(params.transactionID)
  len = commandBuf.length + transactionIDBuf.length
  for obj in params.objects
    len += obj.length
  amf0Bytes = Buffer.concat [commandBuf, transactionIDBuf, params.objects...], len

  return createRTMPMessage
    chunkStreamID: params.chunkStreamID
    timestamp: params.timestamp
    messageTypeID: 0x14  # AMF0 Command
    messageStreamID: params.messageStreamID
    body: amf0Bytes
  , chunkSize

class RTMPSession
  constructor: (socket) ->
    console.log "new RTMPSession"
    @listeners = {}
    @state = SESSION_STATE_NEW
    @socket = socket
    @chunkSize = 128
    @previousChunkMessage = {}
    @isPlaying = false
    @clientid = generateNewClientID()
    @useEncryption = false

  clearTimeout: ->
    if @timeoutTimer?
      clearTimeout @timeoutTimer
      @timeoutTimer = null

  scheduleTimeout: ->
    if @isTearedDown
      return
    @clearTimeout()
    @lastTimeoutScheduledTime = Date.now()
    @timeoutTimer = setTimeout =>
      if @isTearedDown
        return
      if not @timeoutTimer?
        return
      if Date.now() - @lastTimeoutScheduledTime < config.rtmpSessionTimeoutMs
        return
      console.log "RTMP session timeout: #{@clientid}"
      @teardown()
    , config.rtmpSessionTimeoutMs

  schedulePing: ->
    @lastPingScheduledTime = Date.now()
    if @pingTimer?
      clearTimeout @pingTimer
    @pingTimer = setTimeout =>
      if Date.now() - @lastPingScheduledTime < config.rtmpPingTimeoutMs
        console.log "ping timeout canceled"
      @ping()
    , config.rtmpPingTimeoutMs

  ping: ->
    pingRequest = createRTMPMessage
      chunkStreamID: 2
      timestamp: lastTimestamp
      messageTypeID: 0x04  # User Control Message
      messageStreamID: 0
      body: new Buffer [
        # Event Type: 6=PingRequest
        0, 6,
        # Server Timestamp
        (lastTimestamp >> 24) & 0xff,
        (lastTimestamp >> 16) & 0xff,
        (lastTimestamp >> 8) & 0xff,
        lastTimestamp & 0xff
      ]

    @sendData pingRequest

  stopPlaying: ->
    @isPlaying = false
    @isWaitingForKeyFrame = false

  teardown: ->
    if @isTearedDown
      console.log "[rtmp] already teared down"
      return
    console.log "[rtmp] teardown"
    @isTearedDown = true
    @clearTimeout()
    @stopPlaying()
    if @cipherIn?
      @cipherIn.final()
      @cipherIn = null
    if @cipherOut?
      @cipherOut.final()
      @cipherOut = null
    try
      @socket.end()
    catch e
      console.error "Socket.end error: #{e}"
    @emit 'teardown'

  getScaledTimestamp: (timestamp) ->
    ts = timestamp - @playStartTimestamp
    if ts < 0
      ts = 0
    return ts

  createVideoMessage: (params) ->
    params.chunkStreamID = 4
    params.messageTypeID = 0x09  # Video Data
    params.messageStreamID = 1
    return @createAVMessage params

  createAudioMessage: (params) ->
    params.chunkStreamID = 4
    params.messageTypeID = 0x08  # Audio Data
    params.messageStreamID = 1
    return @createAVMessage params

  createAVMessage: (params) ->
    thisTimestamp = @getScaledTimestamp params.timestamp
    if @lastAVTimestamp? and params.body.length <= @chunkSize
      # Use Type 1 if chunking is not needed
      params.timestampDelta = (thisTimestamp - @lastAVTimestamp) % TIMESTAMP_ROUNDOFF
      msg = createRTMPType1Message params
    else
      # Use Type 0
      msg = createRTMPMessage params, @chunkSize

    @lastAVTimestamp = thisTimestamp

    return msg

  concatenate: (arr) ->
    if Buffer.isBuffer arr
      return arr
    if not (arr instanceof Array)
      return

    len = 0
    for item, i in arr
      if item?
        len += item.length
      else
        arr[i] = new Buffer 0
    return Buffer.concat arr, len

  emit: (event, data) ->
    if not @listeners[event]?
      return
    for listener in @listeners[event]
      listener data
    return

  on: (event, listener) ->
    if not @listeners[event]?
      @listeners[event] = [listener]
    else
      @listeners[event].push listener
    return

  removeListener: (event, listener) ->
    listeners = @listeners[event]
    if not listeners?
      return
    removedCount = 0
    for _listener, i in listeners
      if _listener is listener
        console.log "[rtmp] removed listener for #{event}"
        actualIndex = i - removedCount
        listeners[actualIndex..actualIndex] = []  # Remove element
        removedCount++
    return

  sendData: (arr) ->
    if not arr?
      return
    if Buffer.isBuffer arr
      buf = arr
    else
      len = 0
      for item in arr
        len += item.length
      buf = Buffer.concat arr, len
    if @useEncryption
      buf = @encrypt buf
    @emit 'data', buf

  rejectConnect: (commandMessage, callback) ->
    streamBegin0 = createRTMPMessage
      chunkStreamID: 2
      timestamp: 0
      messageTypeID: 0x04  # User Control Message
      messageStreamID: 0
      body: new Buffer [
        # Stream Begin (see 7.1.7. User Control Message Events)
        0, 0,
        # Stream ID of the stream that became functional
        0, 0, 0, 0
      ]

    _error = createAMF0CommandMessage
      chunkStreamID: 3
      timestamp: 0
      messageStreamID: 0
      command: '_error'
      transactionID: 1
      objects: [
        createAMF0Data(null),
        createAMF0Object({
          level: 'error'
          code: 'NetConnection.Connect.Rejected'
          description: 'Connection failed.'
          description: '[ Server.Reject ] : (_defaultRoot_, ) : Invalid application name(/_definst_).'
        })
      ]

    close = createAMF0CommandMessage
      chunkStreamID: 3
      timestamp: 0
      messageStreamID: 0
      command: 'close'
      transactionID: 0
      objects: [
        createAMF0Data(null)
      ]

    callback null, @concatenate [ streamBegin0, _error, close ]

  respondConnect: (commandMessage, callback) ->
    app = commandMessage.objects[0].value.app
    app = app.replace /\/$/, ''  # JW Player adds / at the end
    if app isnt config.rtmpApplicationName
      console.warn "Invalid app name: #{app}"
      @rejectConnect commandMessage, callback
      return

    windowAck = createRTMPMessage
      chunkStreamID: 2
      timestamp: 0
      messageTypeID: 0x05  # Window Acknowledgement Size
      messageStreamID: 0
      # 0x140000 == 1310720
      # 0x2625a0 == 2500000
      body: new Buffer [
        # Acknowledgement Window Size (4 bytes)
#        0, 0x14, 0, 0
        0, 0x26, 0x25, 0xa0
      ]

    setPeerBandwidth = createRTMPMessage
      chunkStreamID: 2
      timestamp: 0
      messageTypeID: 0x06  # Set Peer Bandwidth
      messageStreamID: 0
      body: new Buffer [
        # Window acknowledgement size (4 bytes)
        0, 0x26, 0x25, 0xa0,
        # Limit Type
        0x02
      ]

    streamBegin0 = createRTMPMessage
      chunkStreamID: 2
      timestamp: 0
      messageTypeID: 0x04  # User Control Message
      messageStreamID: 0
      body: new Buffer [
        # Stream Begin (see 7.1.7. User Control Message Events)
        0, 0,
        # Stream ID of the stream that became functional
        0, 0, 0, 0
      ]

    # 7.2.1.1.  connect
    connectResult = createAMF0CommandMessage
      chunkStreamID: 3
      timestamp: 0
      messageStreamID: 0
      command: '_result'
      transactionID: 1  # Always 1
      objects: [
        createAMF0Object({
          fmsVer: 'FMS/3,0,4,423'
          capabilities: 31
        }),
        createAMF0Object({
          level: 'status'
          code: 'NetConnection.Connect.Success'
          description: 'Connection succeeded.'
          objectEncoding: @objectEncoding ? 0
        })
      ]

    onBWDone = createAMF0CommandMessage
      chunkStreamID: 3
      timestamp: 0
      messageStreamID: 0
      command: 'onBWDone'
      transactionID: 0
      objects: [ createAMF0Data(null) ]

    callback null, @concatenate [
      windowAck, setPeerBandwidth, streamBegin0, connectResult,
      onBWDone
    ]

  encrypt: (data) ->
    isSingleByte = typeof(data) is 'number'
    if isSingleByte
      data = new Buffer [ data ]
    result = @cipherIn.update data
    if isSingleByte
      return result[0]
    else
      return result

  decrypt: (data) ->
    isSingleByte = typeof(data) is 'number'
    if isSingleByte
      data = new Buffer [ data ]
    result = @cipherOut.update data
    if isSingleByte
      return result[0]
    else
      return result

  respondHandshake: (c0c1, callback) ->
    RTMPHandshake.generateS0S1S2 c0c1, (err, s0s1s2, keys) =>
      type = s0s1s2[0]
      if type is 6
        @useEncryption = true
        console.log "using encryption"

      @clientPublicKey  = keys.clientPublicKey
      @dh = keys.dh
      @sharedSecret = @dh.computeSecret @clientPublicKey
      @keyOut = calcHmac(@dh.getPublicKey(), @sharedSecret)[0..15]
      @keyIn = calcHmac(@clientPublicKey, @sharedSecret)[0..15]

      @cipherOut = crypto.createCipheriv 'rc4', @keyOut, ''
      @cipherIn  = crypto.createCipheriv 'rc4', @keyIn, ''
      zeroBytes = new Buffer 1536
      zeroBytes.fill 0
      @encrypt zeroBytes
      @decrypt zeroBytes

      callback null, s0s1s2

  parseRTMPMessages: (rtmpMessage) ->
    rtmpBody = new Buffer []

    messages = []

    while rtmpMessage.length > 0
      message = {}

      # 5.3.1.1.  Chunk Basic Header
      chunkBasicHeader = rtmpMessage[0]
      message.formatType = chunkBasicHeader >> 6
      message.chunkStreamID = chunkBasicHeader & 0b111111
      if message.chunkStreamID is 0
        message.chunkStreamID = rtmpMessage[1] + 64
        chunkMessageHeader = rtmpMessage[2..]
      else if message.chunkStreamID is 1
        message.chunkStreamID = (rtmpMessage[1] << 8) + rtmpMessage[2] + 64
        chunkMessageHeader = rtmpMessage[3..]
      else
        chunkMessageHeader = rtmpMessage[1..]

      if message.formatType is 0  # 5.3.1.2.1.  Type 0
        message.timestamp = (chunkMessageHeader[0] << 16) +
          (chunkMessageHeader[1] << 8) + chunkMessageHeader[2]
        message.messageLength = (chunkMessageHeader[3] << 16) +
          (chunkMessageHeader[4] << 8) + chunkMessageHeader[5]
        message.messageTypeID = chunkMessageHeader[6]
        message.messageStreamID = chunkMessageHeader.readInt32LE 7  # TODO: signed or unsigned?
        chunkBody = chunkMessageHeader[11..]
      else if message.formatType is 1  # 5.3.1.2.2.  Type 1
        message.timestampDelta = (chunkMessageHeader[0] << 16) +
          (chunkMessageHeader[1] << 8) + chunkMessageHeader[2]
        message.messageLength = (chunkMessageHeader[3] << 16) +
          (chunkMessageHeader[4] << 8) + chunkMessageHeader[5]
        message.messageTypeID = chunkMessageHeader[6]
        previousChunk = @previousChunkMessage[message.chunkStreamID]
        if previousChunk?
          message.messageStreamID = previousChunk.messageStreamID
        else
          throw new Error "Chunk reference error for type 1: previous chunk for id #{message.chunkStreamID} is not found"
        chunkBody = chunkMessageHeader[7..]
      else if message.formatType is 2  # 5.3.1.2.3.  Type 2
        message.timestampDelta = (chunkMessageHeader[0] << 16) +
        (chunkMessageHeader[1] << 8) + chunkMessageHeader[2]
        previousChunk = @previousChunkMessage[message.chunkStreamID]
        if previousChunk?
          message.messageStreamID = previousChunk.messageStreamID
          message.messageLength = previousChunk.messageLength
          message.messageTypeID = previousChunk.messageTypeID
        else
          throw new Error "Chunk reference error for type 2: previous chunk for id #{message.chunkStreamID} is not found"
        chunkBody = chunkMessageHeader[3..]
      else if message.formatType is 3  # 5.3.1.2.4.  Type 3
        previousChunk = @previousChunkMessage[message.chunkStreamID]
        if previousChunk?
          message.messageStreamID = previousChunk.messageStreamID
          message.messageLength = previousChunk.messageLength
          message.timestampDelta = previousChunk.timestampDelta
          message.messageTypeID = previousChunk.messageTypeID
        else
          throw new Error "Chunk reference error for type 3: previous chunk for id #{message.chunkStreamID} is not found"
        chunkBody = chunkMessageHeader
      else
        throw new Error "Unknown format type: #{formatType}"

      # TODO: Handle for type 2 and 3
      messageSize = Math.min @chunkSize, message.messageLength

      rtmpMessage = chunkBody[messageSize..]

      chunkBody = chunkBody[0...messageSize]

      if message.formatType is 3 and
      @previousChunkMessage[message.chunkStreamID].formatType is 0
        # Concatenate chunk
        # TODO: concatenate splitted buffer that share the same chunk stream ID?
        previousChunk = @previousChunkMessage[message.chunkStreamID]
        if previousChunk?
          previousChunk.body = Buffer.concat [
            previousChunk.body, chunkBody
          ], previousChunk.body.length + chunkBody.length
        else
          throw new Error "Chunk concatenate error: previous chunk not found"
      else
        message.body = chunkBody
        messages.push message
        @previousChunkMessage[message.chunkStreamID] = message
        @previousChunk = message

    messages

  respondCreateStream: (requestCommand, callback) ->
    _result = createAMF0CommandMessage
      chunkStreamID: 3
      timestamp: 0
      messageStreamID: 0
      command: '_result'
      transactionID: requestCommand.transactionID  # may be 2
      objects: [
        createAMF0Data(null),
        createAMF0Data(1)  # stream id
      ]
    callback null, _result

  respondPlay: (commandMessage, callback) ->
    @chunkSize = config.rtmpPlayChunkSize

    # 5.4.1.  Set Chunk Size (1)
    setChunkSize = createRTMPMessage
      chunkStreamID: 2
      timestamp: 0
      messageTypeID: 0x01  # Set Chunk Size
      messageStreamID: 0
      body: new Buffer [
        (@chunkSize >>> 24) & 0x7f,  # top bit must be zero
        (@chunkSize >>> 16) & 0xff,
        (@chunkSize >>> 8) & 0xff,
        @chunkSize & 0xff
      ]

    streamBegin1 = createRTMPMessage
      chunkStreamID: 2
      timestamp: 0
      messageTypeID: 0x04  # User Control Message
      messageStreamID: 0
      body: new Buffer [
        # Stream Begin (see 7.1.7. User Control Message Events)
        0, 0,
        # Stream ID of the stream that became functional
        0, 0, 0, 1
      ]
    , @chunkSize

    playReset = createAMF0CommandMessage
      chunkStreamID: 4
      timestamp: 0
      messageStreamID: 1
      command: 'onStatus'
      transactionID: 0
      objects: [
        createAMF0Data(null),
        createAMF0Object({
          level: 'status'
          code: 'NetStream.Play.Reset'
          description: "Playing and resetting #{config.rtmpApplicationName}."
          details: config.rtmpApplicationName
          clientid: @clientid
        })
      ]
    , @chunkSize

    playStart = createAMF0CommandMessage
      chunkStreamID: 4
      timestamp: 0
      messageStreamID: 1
      command: 'onStatus'
      transactionID: 0
      objects: [
        createAMF0Data(null),
        createAMF0Object({
          level: 'status'
          code: 'NetStream.Play.Start'
          description: "Started playing #{config.rtmpApplicationName}."
          details: config.rtmpApplicationName
          clientid: @clientid
        })
      ]
    , @chunkSize

    rtmpSampleAccess = createAMF0DataMessage
      chunkStreamID: 4
      timestamp: 0
      messageStreamID: 1
      objects: [
        createAMF0Data('|RtmpSampleAccess'),
        createAMF0Data(false),
        createAMF0Data(false)
      ]
    , @chunkSize

    onMetaData = createAMF0DataMessage
      chunkStreamID: 4
      timestamp: 0
      messageStreamID: 1
      objects: [
        createAMF0Data('onMetaData'),
        createAMF0Data({
          cuePoints: []
          audiodatarate: config.audioBitrateKbps
          hasVideo: config.flv.hasVideo
          stereo: config.flv.stereo
          canSeekToEnd: false
          framerate: config.videoFrameRate
          audiosamplerate: config.audioSampleRate
          videocodecid: config.flv.videocodecid
          hasAudio: true
          audiodelay: 0
          height: config.height
          hasMetadata: true
          audiocodecid: config.flv.audiocodecid
          audiochannels: config.flv.audiochannels
          videodatarate: config.videoBitrateKbps
          hasCuePoints: false
          width: config.width
          aacaot: config.flv.aacaot
          avclevel: config.flv.avclevel
          avcprofile: config.flv.avcprofile
        })
      ]
    , @chunkSize

    codecConfigs = @getCodecConfigs()

    callback null, @concatenate [
      setChunkSize, streamBegin1, playReset,
      playStart,
      rtmpSampleAccess, onMetaData,
      codecConfigs
    ]

    @isWaitingForKeyFrame = true

  getCodecConfigs: ->
    if not spsPacket? or not ppsPacket?
      console.error "Error: SPS or PPS is not present"
      return

    # video
    spsLen = spsPacket.length
    ppsLen = ppsPacket.length
    buf = new Buffer [
      # VIDEODATA tag (Appeared in Adobe's Video File Format Spec v10.1 E.4.3.1 VIDEODATA
      0x17,  # ( 1=keyframe << 4 ) + 7=video_codec_id
      0x00,  # 0=configuration data
      0x00,  # composition time
      0x00,  # composition time
      0x00,  # composition time

      # AVC decoder configuration: described in ISO 14496-15 5.2.4.1.1 Syntax
      0x01,  # version
      spsPacket[1..3]...,
      0xff, # 6 bits reserved (111111) + 2 bits nal size length - 1 (11)
      0xe1, # 3 bits reserved (111) + 5 bits number of sps (00001)

      (spsLen >> 8) & 0xff,
      spsLen & 0xff,
      spsPacket...,

      0x01,  # number of PPS (1)

      (ppsLen >> 8) & 0xff,
      ppsLen & 0xff,
      ppsPacket...
    ]
    videoConfigMessage = createVideoMessage
      body: buf
      timestamp: 0
      chunkSize: @chunkSize

    # audio
    buf = new Buffer [
      # AUDIODATA tag: appeared in Adobe's Video File Format Spec v10.1 E.4.2.1 AUDIODATA
      (config.audioCodecId << 4) \ # SoundFormat (4 bits): 10=AAC
      | (2 << 2) \ # SoundRate (2 bits): 2=22kHz
      | (1 << 1) \ # SoundSize (1 bit): 1=16-bit samples
      | 0          # SoundType (1 bit): 0=Mono sound
      , 0  # AACPacketType (1 bit): 0=AAC sequence header

      # AAC AudioSpecificConfig: described in ISO 14496-3 1.6.2.1 AudioSpecificConfig
      , (2 << 3) \ # audioObjectType (5 bits): 2=AAC LC (Table 1.1)
      # samplingFrequencyIndex (4 bits): (Table 1.16)
      | (codecUtils.getSamplingFreqIndex(config.audioSampleRate) >> 1)
      , ((7 & 0x01) << 7) \ # samplingFrequencyIndex (cont 1 bit)
      | (1 << 3) \ # channelConfiguration (4 bits): 1=mono
      | (0 << 2) \ # frameLengthFlag (1 bit): 0=1024
      | (0 << 1) \ # dependsOnCoreCorder (1 bit): 0=no
      | 0 # extensionFlag (1 bit): 0 for audio object type 2
    ]
    audioConfigMessage = createAudioMessage
      body: buf
      timestamp: 0
      chunkSize: @chunkSize

    return @concatenate [ videoConfigMessage, audioConfigMessage ]

  pauseOrUnpauseStream: (commandMessage, callback) ->
    doPause = commandMessage.objects[1]?.value is true
    if doPause
      @isPlaying = false
      @isWaitingForKeyFrame = false
      callback null
    else
      @respondPlay commandMessage, callback

  closeStream: (callback) ->
    @isPlaying = false
    @isWaitingForKeyFrame = false
    callback null

  deleteStream: (callback) ->
    @isPlaying = false
    @isWaitingForKeyFrame = false
    callback null

  handleAMFCommandMessage: (commandMessage, callback) ->
    if commandMessage.command is 'connect'
      # Retain objectEncoding for later use
      #   3=AMF3, 0=AMF0
      @objectEncoding = commandMessage.objects[0]?.value?.objectEncoding

      @respondConnect commandMessage, callback
    else if commandMessage.command is 'createStream'
      @respondCreateStream commandMessage, callback
    else if commandMessage.command is 'play'
      streamName = commandMessage.objects[1]?.value
      console.log "[rtmp] requested stream=#{streamName}"
      @respondPlay commandMessage, callback
    else if commandMessage.command is 'closeStream'
      @closeStream callback
    else if commandMessage.command is 'deleteStream'
      @deleteStream callback
    else if commandMessage.command is 'pause'
      @pauseOrUnpauseStream commandMessage, callback
    else
      console.warn "[rtmp:receive] unknown AMF command: #{commandMessage.command}"
      callback null

  handleData: (buf, callback) ->
    @scheduleTimeout()
    if @state is SESSION_STATE_NEW
      if @tmpBuf?
        buf = Buffer.concat [@tmpBuf, buf], @tmpBuf.length + buf.length
        @tmpBuf = null
      if buf.length < 1537
        console.log "Waiting for complete C0+C1"
        @tmpBuf = buf
        return
      @tmpBuf = null
      @state = SESSION_STATE_HANDSHAKE_ONGOING
      @respondHandshake buf, callback
      return
    else if @state is SESSION_STATE_HANDSHAKE_ONGOING
      if @tmpBuf?
        buf = Buffer.concat [@tmpBuf, buf], @tmpBuf.length + buf.length
        @tmpBuf = null
      if buf.length < 1536
        console.log "Waiting for complete C2+RTMPMessage"
        @tmpBuf = buf
        return
      @tmpBuf = null

      # TODO: should we validate C2?
#      c2Message = buf[0..1535]

      @state = SESSION_STATE_HANDSHAKE_DONE
      console.log "[rtmp] handshake success, buf.length=#{buf.length}"

      if buf.length <= 1536
        callback null
        return

      buf = buf[1536..]

    if @state is SESSION_STATE_HANDSHAKE_DONE
      if @useEncryption
        buf = @decrypt buf

      rtmpMessages = @parseRTMPMessages buf
      seq = new Sequent
      outputs = []
      for rtmpMessage in rtmpMessages
        if rtmpMessage.messageTypeID is 0x05  # Window Acknowledgement Size
          ackWindowSize = (rtmpMessage.body[0] << 24) +
            (rtmpMessage.body[1] << 16) +
            (rtmpMessage.body[2] << 8) +
            rtmpMessage.body[3]
          console.log "[rtmp:receive] WindowAck=#{ackWindowSize}"
          seq.done()
        else if rtmpMessage.messageTypeID is 20  # AMF0 command
          commandMessage = parseAMF0CommandMessage rtmpMessage.body
          console.log "[rtmp:receive] AMF0 command=#{commandMessage.command}"
          @handleAMFCommandMessage commandMessage, (err, output) ->
            if output?
              outputs.push output
            seq.done()

        else if rtmpMessage.messageTypeID is 17  # AMF3 command
          commandMessage = parseAMF0CommandMessage rtmpMessage.body[1..]
          console.log "[rtmp:receive] AMF3 command=#{commandMessage.command}"
          @handleAMFCommandMessage commandMessage, (err, output) ->
            if output?
              outputs.push output
            seq.done()

        else if rtmpMessage.messageTypeID is 4   # User Control Message
          userControlMessage = parseUserControlMessage rtmpMessage.body
          if userControlMessage.eventType is 3  # SetBufferLength
            streamID = (userControlMessage.eventData[0] << 24) +
              (userControlMessage.eventData[1] << 16) +
              (userControlMessage.eventData[2] << 8) +
              userControlMessage.eventData[3]
            bufferLength = (userControlMessage.eventData[4] << 24) +
              (userControlMessage.eventData[5] << 16) +
              (userControlMessage.eventData[6] << 8) +
              userControlMessage.eventData[7]
            console.log "[rtmp:receive] SetBufferLength: streamID=#{streamID} bufferLength=#{bufferLength}"
          else if userControlMessage.eventType is 7
            timestamp = (userControlMessage.eventData[0] << 24) +
              (userControlMessage.eventData[1] << 16) +
              (userControlMessage.eventData[2] << 8) +
              userControlMessage.eventData[3]
            console.log "[rtmp:receive] PingResponse: timestamp=#{timestamp}"
          else
            console.log "[rtmp:receive] User Control Message"
            console.log userControlMessage
          seq.done()
        else if rtmpMessage.messageTypeID is 3   # Acknowledgement
          acknowledgementMessage = parseAcknowledgementMessage rtmpMessage.body
          console.log "[rtmp:receive] ack=#{acknowledgementMessage.sequenceNumber}"
          seq.done()
        else
          console.log "[rtmp:receive] unknown message type ID: #{rtmpMessage.messageTypeID}"
          seq.done()
      seq.wait rtmpMessages.length, =>
        outbuf = @concatenate outputs
        if @useEncryption
          outbuf = @encrypt outbuf
        callback null, outbuf
    else
      console.log "[rtmp:receive] unknown session state: #{@state}"
      callback new Error "Unknown session state"

class RTMPServer
  constructor: ->
    @port = 1935
    @server = net.createServer (c) =>
      console.log "[rtmp] new client"
      c.clientId = ++clientMaxId
      sess = new RTMPSession c
      sessions[c.clientId] = sess
      sessionsCount++
      c.rtmpSession = sess
      sess.on 'data', (data) ->
        if data? and data.length > 0
          c.write data
      c.on 'close', ->
        console.log "[rtmp] client is disconnected"
        if sessions[c.clientId]?
          sessions[c.clientId].teardown()
          delete sessions[c.clientId]
          sessionsCount--
        console.log "[rtmp] current #{sessionsCount} clients"
      c.on 'error', (err) ->
        console.error "[rtmp] Socket error: #{err}"
        c.destroy()
      c.on 'data', (data) =>
        c.rtmpSession.handleData data, (err, output) ->
          if err
            console.error "[rtmp] Error: #{err}"
          else if output?
            if output.length > 0
              c.write output
          else
            console.log "[rtmp] no response"

  start: (callback) ->
    @server.listen @port, '0.0.0.0', 511, callback

  stop: (callback) ->
    @server.close callback

  teardownRTMPTClient: (socket) ->
    if socket.rtmptClientID?
      console.log "teardownRTMPTClient: #{socket.rtmptClientID}"
      tsession = rtmptSessions[socket.rtmptClientID]
      if tsession?
        tsession.rtmpSession?.teardown()
        delete rtmptSessions[socket.rtmptClientID]
        rtmptSessionsCount--

  sendVideoPacket: (nalUnit, timestamp) ->
    timestamp = convertPTSToMilliseconds timestamp
    lastTimestamp = timestamp

    nalUnitType = nalUnit[0] & 0x1f
    if nalUnitType in [7, 8] # codec config
      retainCodecConfigPacket nalUnit
      return

    if sessionsCount + rtmptSessionsCount is 0
      return

    isKeyFrame = nalUnitType is 5
    if nalUnitType is 5  # IDR picture (keyframe)
      firstByte = (1 << 4) | config.videoCodecId
    else  # non-IDR picture (I frame)
      firstByte = (2 << 4) | config.videoCodecId
    payloadLen = nalUnit.length
    headerBytes = new Buffer [
      # VIDEODATA tag
      firstByte,
      0x01,  # picture data
      0,     # composition time
      0,     # composition time
      0,     # composition time

      # The length of this data is specified in
      # configuration data that has already been sent
      (payloadLen >>> 24) & 0xff,
      (payloadLen >>> 16) & 0xff,
      (payloadLen >>> 8) & 0xff,
      payloadLen & 0xff,
    ]
    buf = Buffer.concat [headerBytes, nalUnit], payloadLen + 9

    queueVideoMessage
      body: buf
      timestamp: timestamp
      isKeyFrame: isKeyFrame

    return

  sendAudioPacket: (rawDataBlock, timestamp) ->
    timestamp = convertPTSToMilliseconds timestamp
    lastTimestamp = timestamp

    if sessionsCount + rtmptSessionsCount is 0
      return

    headerBytes = new Buffer [
        # AUDIODATA tag: appeared in Adobe's Video File Format Spec v10.1 E.4.2.1 AUDIODATA
        (config.audioCodecId << 4) \ # SoundFormat (4 bits): 10=AAC
        | (2 << 2) \ # SoundRate (2 bits): 2=22kHz
        | (1 << 1) \ # SoundSize (1 bit): 1=16-bit samples
        | 0          # SoundType (1 bit): 0=Mono sound
        , 1  # AACPacketType (1 bit): 1=AAC raw
    ]
    buf = Buffer.concat [headerBytes, rawDataBlock], rawDataBlock.length + 2

    queueAudioMessage
      body: buf
      timestamp: timestamp

    return

  startStream: (timeForVideoRTPZero) ->
    console.log "RTMP server startStream"
    codecConfigPackets = []

  handleRTMPTRequest: (req, callback) ->
    # /fcs/ident2 will be handled in another place
    if (match = /^\/([^/]+)\/([^/]+)(?:\/([^\/]+))?/.exec req.uri)?
      command = match[1]
      client = match[2]
      index = match[3]
      if not index?
        index = client
      if command is 'fcs' and index is 'ident2'
        response = """
        HTTP/1.1 400 RTMPT command /fcs/ident2 is not supported
        Cache-Control: no-cache
        Content-Type: text/plain
        Content-Length: 0
        Connection: keep-alive


        """.replace /\n/g, '\r\n'
        callback null, response
      else if command is 'open'
        session = new RTMPTSession req.socket, ->
          rtmptSessions[session.id] = session
          rtmptSessionsCount++
          session.respondOpen req, callback
      else if command is 'idle'
        session = rtmptSessions[client]
        if session?
          session.respondIdle req, callback
        else
          callback new Error "No such session"
      else if command is 'send'
        session = rtmptSessions[client]
        if session?
          session.respondSend req, callback
        else
          callback new Error "No such session"
      else if command is 'close'
        session = rtmptSessions[client]
        if session?
          session.respondClose req, callback
        else
          callback new Error "No such session"
      else
        callback new Error "Unknown command: #{command}"
    else
      callback new Error "Unknown URI: #{req.uri}"

# Generate a new sessionID without collision
generateNewSessionID = (callback) ->
  generateSessionID (err, sid) ->
    if err
      callback err
      return
    if rtmptSessions[sid]?
      generateNewSessionID callback
    else
      callback null, sid

# Generate a new random session ID
# NOTE: Session ID must be 31 characters or less
generateSessionID = (callback) ->
  crypto.randomBytes 16, (err, buf) ->
    if err
      callback err
    else
      sid = buf.toString('hex')[0..30]
      callback null, sid

class RTMPTSession
  constructor: (socket, callback) ->
    console.log "[rtmpt] new"
    @socket = socket
    @pollingDelay = 1
    @pendingResponses = []
    @rtmpSession = new RTMPSession socket
    @rtmpSession.on 'data', (data) =>
      @scheduleTimeout()
      @pendingResponses.push data
    @rtmpSession.on 'teardown', =>
      console.log "[rtmpt] received teardown"
      @close()
    generateNewSessionID (err, sid) =>
      if err
        callback err
      else
        console.log "session id: #{sid}"
        @id = sid
        @socket.rtmptClientID = @id
        @scheduleTimeout()
        callback? null

  clearTimeout: ->
    if @timeoutTimer?
      clearTimeout @timeoutTimer
      @timeoutTimer = null

  scheduleTimeout: ->
    if @isClosed
      return
    @clearTimeout()
    @lastTimeoutScheduledTime = Date.now()
    @timeoutTimer = setTimeout =>
      if @isClosed
        return
      if not @timeoutTimer?
        return
      if Date.now() - @lastTimeoutScheduledTime < config.rtmptSessionTimeoutMs
        return
      console.log "RTMPT session timeout: #{@id}"
      @close()
    , config.rtmptSessionTimeoutMs

  close: ->
    if @isClosed
      console.log "[rtmpt] already closed"
      return
    console.log "[rtmpt] close"
    @isClosed = true
    @clearTimeout()
    if @rtmpSession?
      @rtmpSession.teardown()
      @rtmpSession = null
    if rtmptSessions[@id]?
      delete rtmptSessions[@id]
      rtmptSessionsCount--

  createHTTPResponse: (buf) ->
    @scheduleTimeout()
    if buf?
      contentLength = buf.length
    else
      contentLength = 0
    header = """
    HTTP/1.1 200 OK
    Cache-Control: no-cache
    Content-Length: #{contentLength}
    Connection: keep-alive
    Content-Type: application/x-fcs


    """.replace /\n/g, '\r\n'
    allBytes = new Buffer header, 'utf8'
    if buf?
      allBytes = Buffer.concat [allBytes, buf], allBytes.length + buf.length
    return allBytes

  respondOpen: (req, callback) ->
    @scheduleTimeout()
    body = @id + '\n'
    bodyBytes = new Buffer body, 'utf8'
    callback null, @createHTTPResponse bodyBytes

  respondIdle: (req, callback) ->
    @scheduleTimeout()
    bufs = [
      new Buffer [ @pollingDelay ]
    ]
    totalLength = 1
    for resp in @pendingResponses
      bufs.push resp
      totalLength += resp.length
    @pendingResponses = []
    allBytes = Buffer.concat bufs, totalLength
    callback null, @createHTTPResponse allBytes

  respondSend: (req, callback) ->
    @scheduleTimeout()
    @rtmpSession.handleData req.rawbody, (err, output) =>
      if err
        console.error "[rtmpt:send-resp] Error: #{err}"
        callback err
      else if output?
        interval = new Buffer [ @pollingDelay ]
        allBytes = Buffer.concat [interval, output], 1 + output.length
        callback null, @createHTTPResponse allBytes
      else
        console.log "[rtmpt:send-resp] no response"
        allBytes = new Buffer [ @pollingDelay ]
        callback null, @createHTTPResponse allBytes

  respondClose: (req, callback) ->
    allBytes = new Buffer [ @pollingDelay ]
    @close()
    callback null, @createHTTPResponse allBytes

module.exports = RTMPServer
