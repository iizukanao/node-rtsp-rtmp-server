# RTMP/RTMPE/RTMPT/RTMPTE server
#
# RTMP specification is available at:
# http://wwwimages.adobe.com/content/dam/Adobe/en/devnet/rtmp/pdf/rtmp_specification_1.0.pdf

net = require 'net'
url = require 'url'
crypto = require 'crypto'
Sequent = require 'sequent'

rtmp_handshake = require './rtmp_handshake'
codec_utils = require './codec_utils'
config = require './config'
h264 = require './h264'
aac = require './aac'
flv = require './flv'
avstreams = require './avstreams'
logger = require './logger'
Bits = require './bits'

# enum
SESSION_STATE_NEW               = 1
SESSION_STATE_HANDSHAKE_ONGOING = 2
SESSION_STATE_HANDSHAKE_DONE    = 3

AVC_PACKET_TYPE_SEQUENCE_HEADER = 0
AVC_PACKET_TYPE_NALU            = 1
AVC_PACKET_TYPE_END_OF_SEQUENCE = 2

EXTENDED_TIMESTAMP_TYPE_NOT_USED = 'not-used'
EXTENDED_TIMESTAMP_TYPE_ABSOLUTE = 'absolute'
EXTENDED_TIMESTAMP_TYPE_DELTA    = 'delta'

TIMESTAMP_ROUNDOFF = 4294967296  # 32 bits

DEBUG_INCOMING_STREAM_DATA = false
DEBUG_INCOMING_RTMP_PACKETS = false
DEBUG_OUTGOING_RTMP_PACKETS = false

RTMPT_SEND_REQUEST_BUFFER_SIZE = 10

# Number of active sessions
sessionsCount = 0

# Active sessions
sessions = {}

# Number of active RTMPT sessions
rtmptSessionsCount = 0

# Active RTMPT sessions
rtmptSessions = {}

# The newest client ID
clientMaxId = 0

queuedRTMPMessages = {}

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

parseAcknowledgementMessage = (buf) ->
  sequenceNumber = (buf[0] * Math.pow(256, 3)) + (buf[1] << 16) + (buf[2] << 8) + buf[3]
  return {
    sequenceNumber: sequenceNumber
  }

convertPTSToMilliseconds = (pts) ->
  Math.floor pts / 90

createAudioMessage = (params) ->
  # TODO: Use type 1/2/3
  audioMessage = createRTMPMessage
    chunkStreamID: 4
    timestamp: params.timestamp
    messageTypeID: 0x08  # Audio Data
    messageStreamID: 1
    body: params.body
  , params.chunkSize

clearQueuedRTMPMessages = (stream) ->
  if queuedRTMPMessages[stream.id]?
    queuedRTMPMessages[stream.id] = []

queueRTMPMessages = (stream, messages, params) ->
  for message in messages
    message.originalTimestamp = message.timestamp
  if queuedRTMPMessages[stream.id]?
    queuedRTMPMessages[stream.id].push messages...
  else
    queuedRTMPMessages[stream.id] = [ messages... ] # Prevent copying array as reference

  flushRTMPMessages stream, params

queueVideoMessage = (stream, params) ->
  params.avType = 'video'
  params.chunkStreamID = 4
  params.messageTypeID = 0x09  # Video Data
  params.messageStreamID = 1
  params.originalTimestamp = params.timestamp
  if queuedRTMPMessages[stream.id]?
    queuedRTMPMessages[stream.id].push params
  else
    queuedRTMPMessages[stream.id] = [ params ]

  setImmediate ->
    flushRTMPMessages stream

queueAudioMessage = (stream, params) ->
  params.avType = 'audio'
  params.chunkStreamID = 4
  params.messageTypeID = 0x08  # Audio Data
  params.messageStreamID = 1
  params.originalTimestamp = params.timestamp
  if queuedRTMPMessages[stream.id]?
    queuedRTMPMessages[stream.id].push params
  else
    queuedRTMPMessages[stream.id] = [ params ]

  setImmediate ->
    flushRTMPMessages stream

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
  while --len >= 0
    result = parseAMF0Data buf[readLen..]
    arr.push result.value
    readLen += result.readLen
  return { value: arr, readLen: readLen }

parseAMF0ECMAArray = (buf) ->
  # associative-count
  count = (buf[0] << 24) + (buf[1] << 16) + (buf[2] << 8) + buf[3]
  result = parseAMF0Object buf[4..], count
  result.readLen += 4
  return result

parseAMF0Object = (buf, maxItems=null) ->
  obj = {}
  bufLen = buf.length
  readLen = 0
  items = 0
  if (not maxItems?) or (maxItems > 0)
    while readLen < bufLen
      nameLen = (buf[readLen++] << 8) + buf[readLen++]
      if nameLen > 0  # object-end-marker will follow
        name = buf.toString 'utf8', readLen, readLen + nameLen
        readLen += nameLen
      else
        name = null
      result = parseAMF0Data buf[readLen..]
      readLen += result.readLen
      if result.type is 'object-end-marker'
        break
      else
        items++
        if maxItems? and (items > maxItems)
          logger.warn "warn: illegal AMF0 data: force break because items (#{items}) > maxItems (#{maxItems})"
          break
      if name?
        obj[name] = result.value
      else
        logger.warn "warn: illegal AMF0 data: object key for value #{result.value} is zero length"
  return { value: obj, readLen: readLen }

# Do opposite of parseAMF0DataMessage()
serializeAMF0DataMessage = (parsedObject) ->
  bufs = []
  for object in parsedObject.objects
    bufs.push createAMF0Data object.value
  return Buffer.concat bufs

# Decode AMF0 data message buffer into AMF0 packets
parseAMF0DataMessage = (buf) ->
  amf0Packets = []
  remainingLen = buf.length
  while remainingLen > 0
    result = parseAMF0Data buf
    amf0Packets.push result
    remainingLen -= result.readLen
    buf = buf[result.readLen..]
  return {
    objects: amf0Packets
  }

# Decode buffer into AMF0 packets
parseAMF0CommandMessage = (buf) ->
  amf0Packets = []
  remainingLen = buf.length
  while remainingLen > 0
    try
      result = parseAMF0Data buf
    catch e
      logger.error "[rtmp] error parsing AMF0 command (maybe a bug); buf:"
      logger.error buf
      throw e
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
    result = parseAMF0Object buf[i..]
    return { type: 'object', value: result.value, readLen: i + result.readLen }
  else if type is 0x05  # null-marker
    return { type: 'null', value: null, readLen: i }
  else if type is 0x06  # undefined-marker
    return { type: 'undefined', value: undefined, readLen: i }
  else if type is 0x08  # ecma-array-marker
    result = parseAMF0ECMAArray buf[i..]
    return { type: 'array', value: result.value, readLen: i + result.readLen }
  else if type is 0x09  # object-end-marker
    return { type: 'object-end-marker', readLen: i }
  else if type is 0x0a  # strict-array-marker
    result = parseAMF0StrictArray buf[i..]
    return { type: 'strict-array', value: result.value, readLen: i + result.readLen }
  else if type is 0x0b  # date-marker
    time = buf.readDoubleBE i
    date = new Date(time)
    return { type: 'date', value: date, readLen: i + 10 }  # 8 (time) + 2 (time-zone)
  else
    throw new Error "Unknown AMF0 data type: #{type}"

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
    buf = createAMF0Object data
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
  return createAMF0PropertyList obj, buf

createAMF0ECMAArray = (obj) ->
  count = Object.keys(obj).length
  buf = new Buffer [
    # ecma-array-marker
    0x08,
    # array-count
    (count >>> 24) & 0xff,
    (count >>> 16) & 0xff,
    (count >>> 8) & 0xff,
    count & 0xff
  ]
  return createAMF0PropertyList obj, buf

createAMF0PropertyList = (obj, buf=null) ->
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

counter = 0

flushRTMPMessages = (stream, params) ->
  if not stream?
    logger.error "[rtmp] error: flushRTMPMessages: Invalid stream"
    return

  if (params?.forceFlush isnt true) and
  (queuedRTMPMessages[stream.id].length < config.rtmpMessageQueueSize)
    # not enough buffer
    return

  rtmpMessagesToSend = queuedRTMPMessages[stream.id]
  queuedRTMPMessages[stream.id] = []

  for rtmpMessage, i in rtmpMessagesToSend
    rtmpMessage.index = i

  # Move audio before video if the PTS are the same
  rtmpMessagesToSend.sort (a, b) ->
    cmp = a.originalTimestamp - b.originalTimestamp
    if cmp is 0
      if (not a.avType?) or (not b.avType?)
        cmp = 0
      else if a.avType is b.avType
        cmp = 0
      else if a.avType is 'audio'  # a=audio b=video
        cmp = -1
      else if b.avType is 'audio'  # a=video b=audio
        cmp = 1
    if cmp is 0
      cmp = a.index - b.index  # keep the original order
    return cmp

  if rtmpMessagesToSend.length is 0
    # nothing to send
    return

  allSessions = []
  for clientID, session of rtmptSessions
    allSessions.push session.rtmpSession

  for clientID, session of sessions
    allSessions.push session

  for session in allSessions
    if session.stream?.id isnt stream.id  # The session is not associated with current stream
      continue
    msgs = null

    # If video starts with an inter frame, Flash Player might
    # shows images looks like a glitch until the first keyframe.
    if session.isWaitingForKeyFrame
      if config.rtmpWaitForKeyFrame
        if stream.isVideoStarted  # has video stream
          for rtmpMessage, i in rtmpMessagesToSend
            if (rtmpMessage.avType is 'video') and rtmpMessage.isKeyFrame
              logger.info "[rtmp:client=#{session.clientid}] started playing stream #{stream.id}"
              session.startPlaying()
              session.playStartTimestamp = rtmpMessage.originalTimestamp
              session.playStartDateTime = Date.now()  # TODO: Should we use slower process.hrtime()?
              session.isWaitingForKeyFrame = false
              msgs = rtmpMessagesToSend[i..]
              break
        else  # audio only
          logger.info "[rtmp:client=#{session.clientid}] started playing stream #{stream.id}"
          session.startPlaying()
          session.playStartTimestamp = rtmpMessagesToSend[0].originalTimestamp
          session.playStartDateTime = Date.now()
          session.isWaitingForKeyFrame = false
          msgs = rtmpMessagesToSend
      else  # Do not wait for a keyframe
        logger.info "[rtmp:client=#{session.clientid}] started playing stream #{stream.id}"
        session.startPlaying()
        session.playStartTimestamp = rtmpMessagesToSend[0].originalTimestamp
        session.playStartDateTime = Date.now()
        session.isWaitingForKeyFrame = false
        msgs = rtmpMessagesToSend
    else
      msgs = rtmpMessagesToSend

    if not msgs?
      continue

    if session.isPlaying
      for rtmpMessage in msgs
        # get milliseconds elapsed since play start
        rtmpMessage.timestamp = session.getScaledTimestamp(rtmpMessage.originalTimestamp) % TIMESTAMP_ROUNDOFF
      if session.isResuming
        # Remove audio messages which are already sent until
        # the first video message comes
        filteredMsgs = []
        for rtmpMessage, i in msgs
          if not rtmpMessage.avType?
            filteredMsgs.push rtmpMessage
          else if rtmpMessage.avType is 'video'
            filteredMsgs.push msgs[i..]...
            session.isResuming = false
            break
          else if rtmpMessage.timestamp > session.lastSentTimestamp
            filteredMsgs.push rtmpMessage
          else
            logger.debug "[rtmp:client=#{session.clientid}] skipped message (timestamp=#{rtmpMessage.timestamp} <= lastSentTimestamp=#{session.lastSentTimestamp})"
      else
        filteredMsgs = msgs

      if (params?.hasControlMessage isnt true) and (filteredMsgs.length > 1)
        buf = createRTMPAggregateMessage filteredMsgs, session.chunkSize
        if DEBUG_OUTGOING_RTMP_PACKETS
          logger.info "send RTMP agg msg: #{buf.length} bytes; time=" + filteredMsgs.map((item) -> "#{item.avType?[0] ? 'other'}#{if item.avType is 'video' and item.isKeyFrame then '(key)' else ''}:#{item.timestamp}#{if item.avType is 'video' and item.compositionTime isnt 0 then "(cmp=#{item.timestamp+item.compositionTime})" else ''}").join(',')
        session.sendData buf
      else
        bufs = []
        for rtmpMessage in filteredMsgs
          bufs.push createRTMPMessage rtmpMessage, session.chunkSize
        buf = Buffer.concat bufs
        if DEBUG_OUTGOING_RTMP_PACKETS
          logger.info "send RTMP msg: #{buf.length} bytes; time=" + filteredMsgs.map((item) -> "#{item.avType?[0] ? 'other'}:#{item.timestamp}").join(',')
        session.sendData buf

      session.lastSentTimestamp = filteredMsgs[filteredMsgs.length-1].timestamp

  return

# RTMP Message Header used in Aggregate Message
createMessageHeader = (params) ->
  payloadLength = params.body.length
  if not params.messageTypeID?
    logger.warn "[rtmp] warning: createMessageHeader(): messageTypeID is not set"
  if not params.timestamp?
    logger.warn "[rtmp] warning: createMessageHeader(): timestamp is not set"
  if not params.messageStreamID?
    logger.warn "[rtmp] warning: createMessageHeader(): messageStreamID is not set"
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
    logger.warn "[rtmp] warning: createRTMPType1Message(): body is not set for RTMP message"
  if not params.chunkStreamID?
    logger.warn "[rtmp] warning: createRTMPType1Message(): chunkStreamID is not set for RTMP message"
  if not params.timestampDelta?
    logger.warn "[rtmp] warning: createRTMPType1Message(): timestampDelta is not set for RTMP message"
  if not params.messageStreamID?
    logger.warn "[rtmp] warning: createRTMPType1Message(): messageStreamID is not set for RTMP message"
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
    logger.warn "[rtmp] warning: createRTMPMessage(): body is not set for RTMP message"
  if not params.chunkStreamID?
    logger.warn "[rtmp] warning: createRTMPMessage(): chunkStreamID is not set for RTMP message"
  if not params.timestamp?
    logger.warn "[rtmp] warning: createRTMPMessage(): timestamp is not set for RTMP message"
  if not params.messageStreamID?
    logger.warn "[rtmp] warning: createRTMPMessage(): messageStreamID is not set for RTMP message"
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
  return createRTMPMessage createAMF0DataMessageParams(params), chunkSize

createAMF0DataMessageParams = (params) ->
  len = 0
  for obj in params.objects
    len += obj.length
  amf0Bytes = Buffer.concat params.objects, len
  return {
    chunkStreamID: params.chunkStreamID
    timestamp: params.timestamp
    messageTypeID: 0x12  # AMF0 Data
    messageStreamID: params.messageStreamID
    body: amf0Bytes
  }

createAMF0CommandMessage = (params, chunkSize) ->
  return createRTMPMessage createAMF0CommandMessageParams(params), chunkSize

createAMF0CommandMessageParams = (params) ->
  commandBuf = createAMF0Data(params.command)
  transactionIDBuf = createAMF0Data(params.transactionID)
  len = commandBuf.length + transactionIDBuf.length
  for obj in params.objects
    len += obj.length
  amf0Bytes = Buffer.concat [commandBuf, transactionIDBuf, params.objects...], len
  return {
    chunkStreamID: params.chunkStreamID
    timestamp: params.timestamp
    messageTypeID: 0x14  # AMF0 Command
    messageStreamID: params.messageStreamID
    body: amf0Bytes
  }

class RTMPSession
  constructor: (socket) ->
    logger.debug "[rtmp] created a new session"
    @listeners = {}
    @state = SESSION_STATE_NEW
    @socket = socket
    @chunkSize = 128
    @receiveChunkSize = 128
    @previousChunkMessage = {}
    @isPlaying = false
    @clientid = generateNewClientID()
    @useEncryption = false
    @receiveTimestamp = null
    @lastSentAckBytes = 0
    @receivedBytes = 0
    @stream = null # AVStream
    @seekedDuringPause = false
    @lastSentTimestamp = null
    @isResuming = false

    # Some broadcaster software like Wirecast does not send Window Acknowledgement Size,
    # so it seems we have to set a default value.
    @windowAckSize = 2500000

  toString: ->
    return "#{@clientid}: addr=#{@socket.remoteAddress} port=#{@socket.remotePort}"

  startPlaying: ->
    @isPlaying = true
    @isResuming = false

  parseVideoMessage: (buf) ->
    info = flv.parseVideo buf
    nalUnitGlob = null
    isEOS = false
    switch info.videoDataTag.avcPacketType
      when flv.AVC_PACKET_TYPE_SEQUENCE_HEADER
        # Retain AVC configuration
        @avcInfo = info.avcDecoderConfigurationRecord
        if @avcInfo.numOfSPS > 1
          logger.warn "warn: flv:parseVideo(): numOfSPS is #{numOfSPS} > 1 (may not work)"
        if @avcInfo.numOfPPS > 1
          logger.warn "warn: flv:parseVideo(): numOfPPS is #{numOfPPS} > 1 (may not work)"
        sps = h264.concatWithStartCodePrefix @avcInfo.sps
        pps = h264.concatWithStartCodePrefix @avcInfo.pps
        nalUnitGlob = Buffer.concat [sps, pps]
      when flv.AVC_PACKET_TYPE_NALU
        if not @avcInfo?
          throw new Error "[rtmp:publish] malformed video data: avcInfo is missing"
        # TODO: This must be too heavy and needs better alternative.
        nalUnits = flv.splitNALUnits info.nalUnits, @avcInfo.nalUnitLengthSize
        nalUnitGlob = h264.concatWithStartCodePrefix nalUnits
      when flv.AVC_PACKET_TYPE_EOS
        isEOS = true
      else
        throw new Error "unknown AVCPacketType: #{flv.AVC_PACKET_TYPE_SEQUENCE_HEADER}"
    return {
      info: info
      nalUnitGlob: nalUnitGlob
      isEOS: isEOS
    }

  parseAudioMessage: (buf) ->
    info = flv.parseAudio buf
    adtsFrame = null
    stream = @stream
    if not stream?
      throw new Error "[rtmp] Stream not set for this session"
    switch info.audioDataTag.aacPacketType
      when flv.AAC_PACKET_TYPE_SEQUENCE_HEADER
        if info.audioSpecificConfig?
          stream.updateConfig
            audioSpecificConfig: info.audioSpecificConfig
            audioASCInfo: info.ascInfo
        else
          logger.warn "[rtmp] skipping empty AudioSpecificConfig"
      when flv.AAC_PACKET_TYPE_RAW
        if not stream.audioASCInfo?
          logger.error "[rtmp:publish] malformed audio data: AudioSpecificConfig is missing"

        # TODO: This must be a little heavy and needs better alternative.
        adtsHeader = new Buffer aac.createADTSHeader stream.audioASCInfo, info.rawDataBlock.length
        adtsFrame = Buffer.concat [ adtsHeader, info.rawDataBlock ]
      else
        throw new Error "[rtmp:publish] unknown AAC_PACKET_TYPE: #{info.audioDataTag.aacPacketType}"
    return {
      info: info
      adtsFrame: adtsFrame
    }

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
      logger.info "[rtmp:client=#{@clientid}] session timeout"
      @teardown()
    , config.rtmpSessionTimeoutMs

  schedulePing: ->
    @lastPingScheduledTime = Date.now()
    if @pingTimer?
      clearTimeout @pingTimer
    @pingTimer = setTimeout =>
      if Date.now() - @lastPingScheduledTime < config.rtmpPingTimeoutMs
        logger.debug "[rtmp] ping timeout canceled"
      @ping()
    , config.rtmpPingTimeoutMs

  ping: ->
    currentTimestamp = @getCurrentTimestamp()
    pingRequest = createRTMPMessage
      chunkStreamID: 2
      timestamp: currentTimestamp
      messageTypeID: 0x04  # User Control Message
      messageStreamID: 0
      body: new Buffer [
        # Event Type: 6=PingRequest
        0, 6,
        # Server Timestamp
        (currentTimestamp >> 24) & 0xff,
        (currentTimestamp >> 16) & 0xff,
        (currentTimestamp >> 8) & 0xff,
        currentTimestamp & 0xff
      ]

    @sendData pingRequest

  stopPlaying: ->
    @isPlaying = false
    @isWaitingForKeyFrame = false

  teardown: ->
    if @isTearedDown
      logger.debug "[rtmp] already teared down"
      return
    @isTearedDown = true
    @clearTimeout()
    @stopPlaying()
    if @stream?.type is avstreams.STREAM_TYPE_RECORDED
      @stream.teardown?()
    if @cipherIn?
      @cipherIn.final()
      @cipherIn = null
    if @cipherOut?
      @cipherOut.final()
      @cipherOut = null
    try
      @socket.end()
    catch e
      logger.error "[rtmp] socket.end error: #{e}"
    @emit 'teardown'

  getCurrentTimestamp: ->
    return Date.now() - @playStartDateTime

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

  emit: (event, args...) ->
    if not @listeners[event]?
      return
    for listener in @listeners[event]
      listener args...
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
        logger.debug "[rtmp] removed listener for #{event}"
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
          description: "[ Server.Reject ] : (_defaultRoot_, ) : Invalid application name(/#{@app})."
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
    @app = app

    if (app isnt config.liveApplicationName) and (app isnt config.recordedApplicationName)
      logger.warn "[rtmp:client=#{@clientid}] requested invalid app name: #{app}"
      @rejectConnect commandMessage, callback
      return

    # TODO: use @chunkSize for createRTMPMessage()?

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
    rtmp_handshake.generateS0S1S2 c0c1, (err, s0s1s2, keys) =>
      type = s0s1s2[0]
      if type is 6
        @useEncryption = true
        logger.info "[rtmp:client=#{@clientid}] enabled encryption"

        @clientPublicKey  = keys.clientPublicKey
        @dh = keys.dh
        @sharedSecret = @dh.computeSecret @clientPublicKey
        @keyOut = codec_utils.calcHmac(@dh.getPublicKey(), @sharedSecret)[0..15]
        @keyIn = codec_utils.calcHmac(@clientPublicKey, @sharedSecret)[0..15]

        @cipherOut = crypto.createCipheriv 'rc4', @keyOut, ''
        @cipherIn  = crypto.createCipheriv 'rc4', @keyIn, ''
        zeroBytes = new Buffer 1536
        zeroBytes.fill 0
        @encrypt zeroBytes
        @decrypt zeroBytes

      callback null, s0s1s2

  parseRTMPMessages: (rtmpMessage) ->
    messages = []
    consumedLen = 0

    while rtmpMessage.length > 1
      headerLen = 0
      message = {}

      # RTMP Chunk Format
      #
      # ------------------
      # Basic Header (1-3 bytes)
      # ------------------
      # Message Header (0/3/7/11 bytes)
      # ------------------
      # Extended Timestamp (0/4 bytes)
      # ------------------
      # Chunk Data (variable size)
      # ------------------

      # 5.3.1.1. Chunk Basic Header
      #
      # Chunk basic header 1 (1 byte)
      # For chunk stream IDs 2-63
      # ---------------
      # fmt (2 bits)
      # chunk stream id (6 bits)
      # ---------------
      #
      # Chunk basic header 2 (2 bytes)
      # For chunk stream IDs 64-319
      # ---------------
      # fmt (2 bits)
      # 0 (6 bits)
      # chunk stream id - 64 (8 bits)
      # ---------------
      #
      # Chunk basic header 3 (3 bytes)
      # For chunk stream IDs 64-65599
      # ---------------
      # fmt (2 bits)
      # 1 (6 bits)
      # chunk stream id - 64 (16 bits)
      # ---------------
      chunkBasicHeader = rtmpMessage[0]
      message.formatType = chunkBasicHeader >> 6
      message.chunkStreamID = chunkBasicHeader & 0b111111
      if message.chunkStreamID is 0  # Chunk basic header 2
        if rtmpMessage.length < 2  # buffer is incomplete
          break
        message.chunkStreamID = rtmpMessage[1] + 64
        chunkMessageHeader = rtmpMessage[2..]
        headerLen += 2
      else if message.chunkStreamID is 1  # Chunk basic header 3
        if rtmpMessage.length < 3  # buffer is incomplete
          break
        message.chunkStreamID = (rtmpMessage[1] << 8) + rtmpMessage[2] + 64
        chunkMessageHeader = rtmpMessage[3..]
        headerLen += 3
      else  # Chunk basic header 1
        chunkMessageHeader = rtmpMessage[1..]
        headerLen += 1

      # 5.3.1.2. Chunk Message Header
      #
      # 5.3.1.2.1 Type 0 chunk header (11 bytes)
      # ---------------
      # timestamp (3 bytes)
      #   Absolute timestamp of the message.
      #   The value of 0xffffff indicates the presence of
      #   Extended Timestamp field.
      # message length (3 bytes)
      # message type id (1 byte)
      # message stream id (4 bytes) - little endian
      # ---------------
      #
      # 5.3.1.2.2 Type 1 chunk header (7 bytes)
      # This chunk has the same stream ID as the preceding chunk.
      # ---------------
      # timestamp delta (3 bytes)
      # message length (3 bytes)
      # message type id (1 byte)
      # ---------------
      #
      # 5.3.1.2.3. Type 2 chunk header (3 bytes)
      # This chunk has the same stream ID and message length as
      # the preceding chunk.
      # ---------------
      # timestamp delta (3 bytes)
      # ---------------
      #
      # 5.3.1.2.4. Type 3 chunk header (0 byte)
      # This chunk has the same stream ID, message length, and
      # timestamp delta as the preceding chunk.
      # ---------------
      # ---------------

      if message.formatType is 0  # Type 0 (11 bytes)
        if chunkMessageHeader.length < 11  # buffer is incomplete
          break
        message.timestamp = (chunkMessageHeader[0] << 16) +
          (chunkMessageHeader[1] << 8) + chunkMessageHeader[2]

        if message.timestamp is 0xffffff
          message.extendedTimestampType = EXTENDED_TIMESTAMP_TYPE_ABSOLUTE
        else
          message.extendedTimestampType = EXTENDED_TIMESTAMP_TYPE_NOT_USED

        message.timestampDelta = 0
        message.messageLength = (chunkMessageHeader[3] << 16) +
          (chunkMessageHeader[4] << 8) + chunkMessageHeader[5]
        message.messageTypeID = chunkMessageHeader[6]
        message.messageStreamID = chunkMessageHeader.readUInt32LE 7  # TODO: signed or unsigned?
        chunkBody = chunkMessageHeader[11..]
        headerLen += 11
      else if message.formatType is 1  # Type 1 (7 bytes)
        if chunkMessageHeader.length < 7  # buffer is incomplete
          break
        message.timestampDelta = (chunkMessageHeader[0] << 16) +
          (chunkMessageHeader[1] << 8) + chunkMessageHeader[2]

        if message.timestampDelta is 0xffffff
          message.extendedTimestampType = EXTENDED_TIMESTAMP_TYPE_DELTA
        else
          message.extendedTimestampType = EXTENDED_TIMESTAMP_TYPE_NOT_USED

        message.messageLength = (chunkMessageHeader[3] << 16) +
          (chunkMessageHeader[4] << 8) + chunkMessageHeader[5]
        message.messageTypeID = chunkMessageHeader[6]
        previousChunk = @previousChunkMessage[message.chunkStreamID]
        if previousChunk?
          message.timestamp = previousChunk.timestamp
          message.messageStreamID = previousChunk.messageStreamID
        else
          throw new Error "#{@clientid}: Chunk reference error for type 1: previous chunk for id #{message.chunkStreamID} is not found (possibly a bug)"
        chunkBody = chunkMessageHeader[7..]
        headerLen += 7
      else if message.formatType is 2  # Type 2 (3 bytes)
        if chunkMessageHeader.length < 3  # buffer is incomplete
          break
        message.timestampDelta = (chunkMessageHeader[0] << 16) +
        (chunkMessageHeader[1] << 8) + chunkMessageHeader[2]

        if message.timestampDelta is 0xffffff
          message.extendedTimestampType = EXTENDED_TIMESTAMP_TYPE_DELTA
        else
          message.extendedTimestampType = EXTENDED_TIMESTAMP_TYPE_NOT_USED

        previousChunk = @previousChunkMessage[message.chunkStreamID]
        if previousChunk?
          message.timestamp = previousChunk.timestamp
          message.messageStreamID = previousChunk.messageStreamID
          message.messageLength = previousChunk.messageLength
          message.messageTypeID = previousChunk.messageTypeID
        else
          throw new Error "#{@clientid}: Chunk reference error for type 2: previous chunk for id #{message.chunkStreamID} is not found (possibly a bug)"
        chunkBody = chunkMessageHeader[3..]
        headerLen += 3
      else if message.formatType is 3  # Type 3 (0 byte)
        previousChunk = @previousChunkMessage[message.chunkStreamID]
        if previousChunk?
          message.timestamp = previousChunk.timestamp
          message.messageStreamID = previousChunk.messageStreamID
          message.messageLength = previousChunk.messageLength
          message.timestampDelta = previousChunk.timestampDelta
          message.extendedTimestampType = previousChunk.extendedTimestampType
          message.messageTypeID = previousChunk.messageTypeID
        else
          throw new Error "#{@clientid}: Chunk reference error for type 3: previous chunk for id #{message.chunkStreamID} is not found (possibly a bug)"
        chunkBody = chunkMessageHeader
      else
        throw new Error "Unknown format type: #{formatType}"

      # 5.3.1.3. Extended Timestamp
      if message.extendedTimestampType is EXTENDED_TIMESTAMP_TYPE_ABSOLUTE
        if chunkBody.length < 4  # buffer is incomplete
          break
        message.timestamp = (chunkBody[0] * Math.pow(256, 3)) +
          (chunkBody[1] << 16) + (chunkBody[2] << 8) + chunkBody[3]
        chunkBody = chunkBody[4..]
        headerLen += 4
      else if message.extendedTimestampType is EXTENDED_TIMESTAMP_TYPE_DELTA
        if chunkBody.length < 4  # buffer is incomplete
          break
        message.timestampDelta = (chunkBody[0] * Math.pow(256, 3)) +
          (chunkBody[1] << 16) + (chunkBody[2] << 8) + chunkBody[3]
        chunkBody = chunkBody[4..]
        headerLen += 4

      previousChunk = @previousChunkMessage[message.chunkStreamID]
      if previousChunk? and previousChunk.isIncomplete
        remainingMessageLen = message.messageLength - previousChunk.body.length
      else
        remainingMessageLen = message.messageLength
      chunkPayloadSize = Math.min @receiveChunkSize, remainingMessageLen

      if chunkBody.length < chunkPayloadSize  # buffer is incomplete
        break

      # We have enough buffer for this chunk

      rtmpMessage = chunkBody[chunkPayloadSize..]
      chunkBody = chunkBody[0...chunkPayloadSize]
      consumedLen += headerLen + chunkPayloadSize

      if previousChunk? and previousChunk.isIncomplete
        # Do not count timestampDelta
        message.body = Buffer.concat [ previousChunk.body, chunkBody ]
      else
        message.body = chunkBody

        # Calculate timestamp for this message
        if message.timestampDelta?
          if not message.timestamp?
            throw new Error "timestamp delta is given, but base timestamp is not known"
          message.timestamp += message.timestampDelta

          # Handle timestamp overflow
          if message.timestamp > TIMESTAMP_ROUNDOFF
            message.timestamp %= TIMESTAMP_ROUNDOFF

      if message.body.length >= message.messageLength # message is completed
        # TODO: Is this check redundant?
        if message.body.length isnt message.messageLength
          logger.warn "[rtmp] warning: message lengths don't match: " +
            "got=#{message.body.length} expected=#{message.messageLength}"

        messages.push message
      else
        message.isIncomplete = true
      @previousChunkMessage[message.chunkStreamID] = message
      if messages.length is 1
        break

    return {
      consumedLen : consumedLen
      rtmpMessages: messages
    }

  # releaseStream()
  respondReleaseStream: (requestCommand, callback) ->
    streamName = requestCommand.objects[1]?.value
    logger.debug "[rtmp] releaseStream: #{@app}/#{streamName}"

    # TODO: Destroy stream here?

    _result = createAMF0CommandMessage
      chunkStreamID: 3
      timestamp: 0
      messageStreamID: 0
      command: '_result'
      transactionID: requestCommand.transactionID
      objects: [
        createAMF0Data(null)
        createAMF0Data(null)
      ]
    callback null, _result

  # @setDataFrame
  receiveSetDataFrame: (requestData) ->
    if requestData.objects[1].value is 'onMetaData'
      logger.debug "[rtmp:receive] received @setDataFrame onMetaData"
    else
      throw new Error "Unknown @setDataFrame: #{requestData.objects[1].value}"

  respondFCUnpublish: (requestCommand, callback) ->
    streamName = requestCommand.objects[1]?.value
    logger.info "[rtmp] FCUnpublish: #{streamName}"
    _result = createAMF0CommandMessage
      chunkStreamID: 3
      timestamp: 0
      messageStreamID: 0
      command: '_result'
      transactionID: requestCommand.transactionID
      objects: [
        createAMF0Data(null)
        createAMF0Data(null)
      ]

    unpublishSuccess = createAMF0CommandMessage
      chunkStreamID: 4
      timestamp: 0
      messageStreamID: 1
      command: 'onStatus'
      transactionID: requestCommand.transactionID
      objects: [
        createAMF0Data(null),
        createAMF0Object({
          level: 'status'
          code: 'NetStream.Unpublish.Success'
          description: ''
          details: streamName
          clientid: @clientid
        })
      ]
    , @chunkSize

    callback null, @concatenate [
      _result
      unpublishSuccess
    ]

  # 7.2.2.6. publish
  respondPublish: (requestCommand, callback) ->
    @receiveTimestamp = null
    publishingName = requestCommand.objects[1]?.value

    if typeof publishingName isnt 'string'
      publishStart = createAMF0CommandMessage
        chunkStreamID: 4
        timestamp: 0
        messageStreamID: 1
        command: 'onStatus'
        transactionID: requestCommand.transactionID
        objects: [
          createAMF0Data(null),
          createAMF0Object({
            level: 'error'
            code: 'NetStream.Publish.Start'
            description: 'Publishing Name parameter is invalid.'
            details: @app
            clientid: @clientid
          })
        ]
      , @chunkSize
      return callback null, publishStart

    # Strip query string part from a string like:
    # "livestream?videoKeyframeFrequency=5&totalDatarate=248"
    urlInfo = url.parse publishingName
    if urlInfo.query?
      pairs = urlInfo.query.split '&'
      params = {}
      for pair in pairs
        kv = pair.split '='
        params[ kv[0] ] = kv[1]
      # TODO: Use this information for something
      # totalDatarate: Total kbps for video + audio
      logger.info JSON.stringify params

    publishingName = @app + '/' + urlInfo.pathname
    @streamId = publishingName
    stream = avstreams.get @streamId
    if stream?
      stream.reset()
    else
      stream = avstreams.create @streamId
      stream.type = avstreams.STREAM_TYPE_LIVE
    @stream = stream
    # TODO: Check if streamId is already used
    publishingType = requestCommand.objects[2]?.value
    # publishingType should be lowercase ('live') but Wirecast uses uppercase ('LIVE')
    if publishingType.toLowerCase() isnt 'live'
      logger.warn "[rtmp] warn: publishing type other than 'live' is not supported (got #{publishingType}); assuming 'live'"
    logger.info "[rtmp] publish: stream=#{publishingName} publishingType=#{publishingType}"
    # strip query string from publishingName
    if (match = /^(.*?)\?/.exec publishingName)?
      streamName = match[1]
    else
      streamName = publishingName

    @isFirstVideoReceived = false
    @isFirstAudioReceived = false

    publishStart = createAMF0CommandMessage
      chunkStreamID: 4
      timestamp: 0
      messageStreamID: 1
      command: 'onStatus'
      transactionID: requestCommand.transactionID
      objects: [
        createAMF0Data(null),
        createAMF0Object({
          level: 'status'
          code: 'NetStream.Publish.Start'
          description: ''
          details: streamName
          clientid: @clientid
        })
      ]
    , @chunkSize
    callback null, publishStart

  respondWithError: (requestCommand, callback) ->
    _error = createAMF0CommandMessage
      chunkStreamID: 3
      timestamp: 0
      messageStreamID: 0
      command: '_error'
      transactionID: requestCommand.transactionID
      objects: [
        createAMF0Data(null),
        createAMF0Object({
          level: 'error'
          code: ''
          description: 'Request failed.'
          details: @app
          clientid: @clientid
        })
      ]
    callback null, _error

  # FCPublish()
  respondFCPublish: (requestCommand, callback) ->
    streamName = requestCommand.objects[1]?.value
    logger.debug "[rtmp] FCPublish: #{@app}/#{streamName}"
    _result = createAMF0CommandMessage
      chunkStreamID: 3
      timestamp: 0
      messageStreamID: 0
      command: '_result'
      transactionID: requestCommand.transactionID
      objects: [
        createAMF0Data(null)
        createAMF0Data(null)
      ]
    callback null, _result

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

  respondPlay: (commandMessage, callback, streamId=null) ->
    if not streamId?
      streamId = @app + '/' + commandMessage.objects[1]?.value
    logger.info "[rtmp:client=#{@clientid}] requested stream #{streamId}"
    @chunkSize = config.rtmpPlayChunkSize
    @stream = avstreams.get streamId
    if not @stream?
      logger.error "[rtmp:client=#{@clientid}] error: stream not found: #{streamId}"
      _error = createAMF0CommandMessage
        chunkStreamID: 3
        timestamp: 0
        messageStreamID: 0
        command: '_error'
        transactionID: commandMessage.transactionID
        objects: [
          createAMF0Data(null),
          createAMF0Object({
            level: 'error'
            code: 'NetStream.Play.StreamNotFound'
            description: ''
            details: streamId
            clientid: @clientid
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

      callback null, @concatenate [ _error, close ]
      return

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

    logger.debug "[rtmp:client=#{@clientid}] stream type: #{@stream.type}"
    if @stream.isRecorded()
      streamIsRecorded = createRTMPMessage
        chunkStreamID: 2
        timestamp: 0
        messageTypeID: 0x04  # User Control Message
        messageStreamID: 0
        body: new Buffer [
          # StreamIsRecorded (see 7.1.7. User Control Message Events)
          0, 4,
          # Stream ID of the recorded stream
          0, 0, 0, 1
        ]
      , @chunkSize

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
          description: "Playing and resetting #{streamId}."
          details: streamId
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
          description: "Started playing #{streamId}."
          details: streamId
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

    dataStart = createAMF0DataMessage
      chunkStreamID: 4
      timestamp: 0
      messageStreamID: 1
      objects: [
        createAMF0Data('onStatus'),
        createAMF0Object({
          code: 'NetStream.Data.Start'
        })
      ]
    , @chunkSize

    metadata =
      canSeekToEnd: false
      cuePoints   : []
      hasMetadata : true
      hasCuePoints: false

    if @stream?
      stream = @stream

      if stream?
        if stream.isVideoStarted
          metadata.hasVideo      = true
          metadata.framerate     = stream.videoFrameRate
          metadata.height        = stream.videoHeight
          metadata.videocodecid  = config.flv.videocodecid # TODO
          metadata.videodatarate = config.videoBitrateKbps # TODO
          metadata.width         = stream.videoWidth
          metadata.avclevel      = stream.videoAVCLevel
          metadata.avcprofile    = stream.videoAVCProfile

        if stream.isAudioStarted
          metadata.hasAudio        = true
          metadata.audiocodecid    = config.flv.audiocodecid # TODO
          metadata.audiodatarate   = config.audioBitrateKbps # TODO
          metadata.audiodelay      = 0
          metadata.audiosamplerate = stream.audioSampleRate
          metadata.stereo          = stream.audioChannels > 1
          metadata.audiochannels   = stream.audioChannels
          metadata.aacaot          = stream.audioObjectType

        if stream.isRecorded()
          metadata.duration = stream.durationSeconds
          # timestamp of the last tag in the recorded stream
          metadata.lasttimestamp = stream.lastTagTimestamp
      else
        logger.error "[rtmp] error: respondPlay: no such stream: #{stream.id}"
    else
      logger.error "[rtmp] error: respondPlay: stream not set for this session"

    logger.debug "[rtmp] metadata:"
    logger.debug metadata

    onMetaData = createAMF0DataMessage
      chunkStreamID: 4
      timestamp: 0
      messageStreamID: 1
      objects: [
        createAMF0Data('onMetaData'),
        createAMF0Data(metadata)
      ]
    , @chunkSize

    codecConfigs = @getCodecConfigs 0

    messages = [ setChunkSize ]
    if @stream.isRecorded()
      messages.push streamIsRecorded
    messages.push streamBegin1, playReset, playStart, rtmpSampleAccess, dataStart, onMetaData, codecConfigs

    callback null, @concatenate messages

    if @stream.isRecorded()
      @stream.play()

    # ready for playing
    @isWaitingForKeyFrame = true
    @seekedDuringPause = false
    if config.rtmpWaitForKeyFrame
      logger.info "[rtmp:client=#{@clientid}] waiting for keyframe"

  # Returns a Buffer contains both SPS and PPS
  getCodecConfigs: (timestamp=0) ->
    configMessages = []

    stream = @stream
    if not stream?
      logger.error "[rtmp] error: getCodecConfigs: stream not set for this session"
      return new Buffer []

    if stream.isVideoStarted
      if not stream.spsNALUnit? or not stream.ppsNALUnit?
        logger.error "[rtmp] error: getCodecConfigs: SPS or PPS is not present"
        return new Buffer []

      # video
      spsLen = stream.spsNALUnit.length
      ppsLen = stream.ppsNALUnit.length
      buf = new Buffer [
        # VIDEODATA tag (Appeared in Adobe's Video File Format Spec v10.1 E.4.3.1 VIDEODATA
        (1 << 4) | config.flv.videocodecid, # 1=key frame
        0x00,  # 0=AVC sequence header (configuration data)
        0x00,  # composition time
        0x00,  # composition time
        0x00,  # composition time

        # AVC decoder configuration: described in ISO 14496-15 5.2.4.1.1 Syntax
        0x01,  # version
        stream.spsNALUnit[1..3]...,
        0xff, # 6 bits reserved (0b111111) + 2 bits nal size length - 1 (0b11)
        0xe1, # 3 bits reserved (0b111) + 5 bits number of sps (0b00001)

        (spsLen >> 8) & 0xff,
        spsLen & 0xff,
        stream.spsNALUnit...,

        0x01,  # number of PPS (1)

        (ppsLen >> 8) & 0xff,
        ppsLen & 0xff,
        stream.ppsNALUnit...
      ]
      videoConfigMessage = createVideoMessage
        body: buf
        timestamp: timestamp
        chunkSize: @chunkSize
      configMessages.push videoConfigMessage

    if stream.isAudioStarted
      # audio
      # TODO: support other than AAC too?
      buf = flv.createAACAudioDataTag
        aacPacketType: flv.AAC_PACKET_TYPE_SEQUENCE_HEADER
      ascInfo = stream.audioASCInfo
      if ascInfo?
        # Flash Player won't play audio if explicit hierarchical
        # signaling of SBR is used
        if ascInfo.explicitHierarchicalSBR and config.rtmpDisableHierarchicalSBR
          logger.debug "[rtmp] converting hierarchical signaling of SBR" +
            " (AudioSpecificConfig=0x#{stream.audioSpecificConfig.toString 'hex'})" +
            " to backward compatible signaling"
          buf = buf.concat aac.createAudioSpecificConfig ascInfo
          buf = new Buffer buf
        else
          buf = Buffer.concat [
            new Buffer buf
            stream.audioSpecificConfig
          ]
        logger.debug "[rtmp] sending AudioSpecificConfig: 0x#{buf.toString 'hex'}"
      else
        buf = buf.concat aac.createAudioSpecificConfig
          audioObjectType: stream.audioObjectType
          samplingFrequency: stream.audioSampleRate
          channels: stream.audioChannels
          frameLength: 1024  # TODO: How to detect 960?
        # Convert buf from array to Buffer
        buf = new Buffer buf

      audioConfigMessage = createAudioMessage
        body: buf
        timestamp: timestamp
        chunkSize: @chunkSize
      configMessages.push audioConfigMessage

    return @concatenate configMessages

#  respondPauseRaw: (requestCommand, callback) ->
#    lastTimestamp = @stream.rtmpLastTimestamp ? 0
#
#    _result = createAMF0CommandMessage
#      chunkStreamID: 3
#      timestamp: lastTimestamp
#      messageStreamID: 0
#      command: '_result'
#      transactionID: requestCommand.transactionID
#      objects: [
#        createAMF0Data(null)
#        createAMF0Data(null)
#      ]
#
#    callback null, _result

  respondSeek: (requestCommand, callback) ->
    msec = requestCommand.objects[1].value
    logger.info "[rtmp:client=#{@clientid}] seek to #{msec / 1000} sec"
    msec = Math.floor msec

    @lastSentTimestamp = null

    if @stream?.type is avstreams.STREAM_TYPE_RECORDED
      clearQueuedRTMPMessages @stream
      _isPlaying = @isPlaying
      @isPlaying = false
      _isPaused = @stream.isPaused()
      if not _isPaused
        @stream.pause()
      @stream.seek msec / 1000, (err, actualStartTime) =>
        if err
          logger.error "seek failed: #{err}"
          return

        # restore the value of @isPlaying
        @isPlaying = _isPlaying

        seq = new Sequent

        # If the stream had not been paused, start playing
        if not _isPaused
          @stream.sendVideoPacketsSinceLastKeyFrame msec / 1000, =>
            @stream.resume()
            @seekedDuringPause = false
            seq.done()
        else
          @seekedDuringPause = true
          seq.done()

        seq.wait 1, =>
          streamEOF1 = createRTMPMessage
            chunkStreamID: 2
            timestamp: 0
            messageTypeID: 0x04  # User Control Message
            messageStreamID: 0
            body: new Buffer [
              # Stream EOF (see 7.1.7. User Control Message Events)
              0, 1,
              # Stream ID of the stream that reaches EOF
              0, 0, 0, 1
            ]

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

          streamIsRecorded = createRTMPMessage
            chunkStreamID: 2
            timestamp: 0
            messageTypeID: 0x04  # User Control Message
            messageStreamID: 0
            body: new Buffer [
              # StreamIsRecorded (see 7.1.7. User Control Message Events)
              0, 4,
              # Stream ID of the recorded stream
              0, 0, 0, 1
            ]
          , @chunkSize

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

          seekNotify = createAMF0CommandMessage
            chunkStreamID: 4
            timestamp: msec
            messageStreamID: 1
            command: 'onStatus'
            transactionID: requestCommand.transactionID
            objects: [
              createAMF0Data(null),
              createAMF0Object({
                level: 'status'
                code: 'NetStream.Seek.Notify'
                description: "Seeking #{msec} (stream ID: 1)."
                details: @stream.id
                clientid: @clientid
              })
            ]
          , @chunkSize

          playStart = createAMF0CommandMessage
            chunkStreamID: 4
            timestamp: msec
            messageStreamID: 1
            command: 'onStatus'
            transactionID: 0
            objects: [
              createAMF0Data(null),
              createAMF0Object({
                level: 'status'
                code: 'NetStream.Play.Start'
                description: "Started playing #{@stream.id}."
                details: @stream.id
                clientid: @clientid
              })
            ]
          , @chunkSize

          rtmpSampleAccess = createAMF0DataMessage
            chunkStreamID: 4
            timestamp: msec
            messageStreamID: 1
            objects: [
              createAMF0Data('|RtmpSampleAccess'),
              createAMF0Data(false),
              createAMF0Data(false)
            ]
          , @chunkSize

          # TODO: onStatus('NetStream.Data.Start')
          dataStart = createAMF0DataMessage
            chunkStreamID: 4
            timestamp: msec
            messageStreamID: 1
            objects: [
              createAMF0Data('onStatus'),
              createAMF0Object({
                code: 'NetStream.Data.Start'
              })
            ]
          , @chunkSize

          metadata =
            canSeekToEnd: false
            cuePoints   : []
            hasMetadata : true
            hasCuePoints: false

          stream = @stream

          if stream.isVideoStarted
            metadata.hasVideo      = true
            metadata.framerate     = stream.videoFrameRate
            metadata.height        = stream.videoHeight
            metadata.videocodecid  = config.flv.videocodecid # TODO
            metadata.videodatarate = config.videoBitrateKbps # TODO
            metadata.width         = stream.videoWidth
            metadata.avclevel      = stream.videoAVCLevel
            metadata.avcprofile    = stream.videoAVCProfile

          if stream.isAudioStarted
            metadata.hasAudio        = true
            metadata.audiocodecid    = config.flv.audiocodecid # TODO
            metadata.audiodatarate   = config.audioBitrateKbps # TODO
            metadata.audiodelay      = 0
            metadata.audiosamplerate = stream.audioSampleRate
            metadata.stereo          = stream.audioChannels > 1
            metadata.audiochannels   = stream.audioChannels
            metadata.aacaot          = stream.audioObjectType

          metadata.duration = stream.durationSeconds
          # timestamp of the last tag in the recorded file
          metadata.lasttimestamp = stream.lastTagTimestamp
          # timestamp of the last video key frame

          logger.debug "[rtmp] metadata:"
          logger.debug metadata

          onMetaData = createAMF0DataMessage
            chunkStreamID: 4
            timestamp: msec
            messageStreamID: 1
            objects: [
              createAMF0Data('onMetaData'),
              createAMF0Data(metadata)
            ]
          , @chunkSize

          codecConfigs = @getCodecConfigs msec

          # TODO: Should we send all video packets since last key frame?

          # Send all suite regardless of _isPaused
          callback null, @concatenate [
            streamEOF1, setChunkSize, streamIsRecorded,
            streamBegin1, seekNotify, playStart,
            rtmpSampleAccess, dataStart, onMetaData, codecConfigs
          ]
    else # live
      @respondPlay requestCommand, callback

  respondPause: (requestCommand, callback) ->
    doPause = requestCommand.objects[1].value is true
    msec = requestCommand.objects[2].value

    if doPause # playing -> pause
      @isPlaying = false
      @isWaitingForKeyFrame = false
      if @stream?.type is avstreams.STREAM_TYPE_RECORDED
        @stream.pause?()
        logger.info "[rtmp:client=#{@clientid}] stream #{@stream.id} paused at #{msec / 1000} sec (client player time)"

        streamEOF1 = createRTMPMessage
          chunkStreamID: 2
          timestamp: 0
          messageTypeID: 0x04  # User Control Message
          messageStreamID: 0
          body: new Buffer [
            # Stream EOF (see 7.1.7. User Control Message Events)
            0, 1,
            # Stream ID of the stream that reaches EOF
            0, 0, 0, 1
          ]

        pauseNotify = createAMF0CommandMessage
          chunkStreamID: 4
          timestamp: msec
          messageStreamID: 1
          command: 'onStatus'
          transactionID: requestCommand.transactionID
          objects: [
            createAMF0Data(null),
            createAMF0Object({
              level: 'status'
              code: 'NetStream.Pause.Notify'
              description: "Pausing #{@stream.id}."
              details: @stream.id
              clientid: @clientid
            })
          ]
        , @chunkSize

        callback null, @concatenate [ streamEOF1, pauseNotify ]
      else # live stream
        callback null
    else # pausing -> resume
      if @stream?.type is avstreams.STREAM_TYPE_RECORDED
        clearQueuedRTMPMessages @stream
        # RTMP 1.0 spec says that the server only sends messages with timestamps
        # greater than the specified msec, but it appears that Flash Player expects
        # to include the specified msec when msec is 0.
        if msec is 0
          seekMsec = 0
        else
          seekMsec = msec + 1
        @stream.seek seekMsec / 1000, (err, actualStartTime) =>
          if err
            logger.error "[rtmp] seek failed: #{err}"
            return

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

          if @stream.isRecorded()
            streamIsRecorded = createRTMPMessage
              chunkStreamID: 2
              timestamp: 0
              messageTypeID: 0x04  # User Control Message
              messageStreamID: 0
              body: new Buffer [
                # StreamIsRecorded (see 7.1.7. User Control Message Events)
                0, 4,
                # Stream ID of the recorded stream
                0, 0, 0, 1
              ]
            , @chunkSize

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

          unpauseNotify = createAMF0CommandMessage
            chunkStreamID: 4
            timestamp: msec
            messageStreamID: 1
            command: 'onStatus'
            transactionID: requestCommand.transactionID
            objects: [
              createAMF0Data(null),
              createAMF0Object({
                level: 'status'
                code: 'NetStream.Unpause.Notify'
                description: "Unpausing #{@stream.id}."
                details: @stream.id
                clientid: @clientid
              })
            ]
          , @chunkSize

          playStart = createAMF0CommandMessage
            chunkStreamID: 4
            timestamp: msec
            messageStreamID: 1
            command: 'onStatus'
            transactionID: 0
            objects: [
              createAMF0Data(null),
              createAMF0Object({
                level: 'status'
                code: 'NetStream.Play.Start'
                description: "Started playing #{@stream.id}."
                details: @stream.id
                clientid: @clientid
              })
            ]
          , @chunkSize

          rtmpSampleAccess = createAMF0DataMessage
            chunkStreamID: 4
            timestamp: msec
            messageStreamID: 1
            objects: [
              createAMF0Data('|RtmpSampleAccess'),
              createAMF0Data(false),
              createAMF0Data(false)
            ]
          , @chunkSize

          # TODO: onStatus('NetStream.Data.Start')
          dataStart = createAMF0DataMessage
            chunkStreamID: 4
            timestamp: msec
            messageStreamID: 1
            objects: [
              createAMF0Data('onStatus'),
              createAMF0Object({
                code: 'NetStream.Data.Start'
              })
            ]
          , @chunkSize

          metadata =
            canSeekToEnd: false
            cuePoints   : []
            hasMetadata : true
            hasCuePoints: false

          stream = @stream

          if stream.isVideoStarted
            metadata.hasVideo      = true
            metadata.framerate     = stream.videoFrameRate
            metadata.height        = stream.videoHeight
            metadata.videocodecid  = config.flv.videocodecid # TODO
            metadata.videodatarate = config.videoBitrateKbps # TODO
            metadata.width         = stream.videoWidth
            metadata.avclevel      = stream.videoAVCLevel
            metadata.avcprofile    = stream.videoAVCProfile

          if stream.isAudioStarted
            metadata.hasAudio        = true
            metadata.audiocodecid    = config.flv.audiocodecid # TODO
            metadata.audiodatarate   = config.audioBitrateKbps # TODO
            metadata.audiodelay      = 0
            metadata.audiosamplerate = stream.audioSampleRate
            metadata.stereo          = stream.audioChannels > 1
            metadata.audiochannels   = stream.audioChannels
            metadata.aacaot          = stream.audioObjectType

          metadata.duration = stream.durationSeconds
          # timestamp of the last tag in the recorded file
          metadata.lasttimestamp = stream.lastTagTimestamp
          # timestamp of the last video key frame

          logger.debug "[rtmp] metadata:"
          logger.debug metadata

          onMetaData = createAMF0DataMessage
            chunkStreamID: 4
            timestamp: msec
            messageStreamID: 1
            objects: [
              createAMF0Data('onMetaData'),
              createAMF0Data(metadata)
            ]
          , @chunkSize

          codecConfigs = @getCodecConfigs msec

          callback null, @concatenate [
            setChunkSize, streamIsRecorded, streamBegin1,
            unpauseNotify, playStart, rtmpSampleAccess,
            dataStart, onMetaData, codecConfigs
          ]

          seq = new Sequent
          @startPlaying()
          if @seekedDuringPause
            @stream.sendVideoPacketsSinceLastKeyFrame seekMsec / 1000, =>
              seq.done()
          else
            @isResuming = true
            seq.done()

          seq.wait 1, =>
            isResumed = @stream.resume()
            @seekedDuringPause = false

            if not isResumed
              logger.debug "[rtmp:client=#{@clientid}] cannot resume (EOF reached)"
            else
              logger.info "[rtmp:client=#{@clientid}] resumed at #{msec / 1000} sec (client player time)"

      else # live
        @startPlaying()
        @respondPlay requestCommand, callback, @stream?.id

  closeStream: (callback) ->
    @isPlaying = false
    @isWaitingForKeyFrame = false
    callback null

  deleteStream: (requestCommand, callback) ->
    @isPlaying = false
    @isWaitingForKeyFrame = false

    _result = createAMF0CommandMessage
      chunkStreamID: 3
      timestamp: 0
      messageStreamID: 0
      command: '_result'
      transactionID: requestCommand.transactionID
      objects: [
        createAMF0Data(null)
        createAMF0Data(null)
      ]
    callback null, _result

  handleAMFDataMessage: (dataMessage, callback) ->
    callback null
    if dataMessage.objects.length is 0
      logger.warn "[rtmp:receive] empty AMF data"
    switch dataMessage.objects[0].value
      when '@setDataFrame'
        @receiveSetDataFrame dataMessage
      else
        logger.warn "[rtmp:receive] unknown (not implemented) AMF data: #{dataMessage.objects[0].value}"
        logger.debug dataMessage
    return

  handleAMFCommandMessage: (commandMessage, callback) ->
    switch commandMessage.command
      when 'connect'
        # Retain objectEncoding for later use
        #   3=AMF3, 0=AMF0
        @objectEncoding = commandMessage.objects[0]?.value?.objectEncoding

        @respondConnect commandMessage, callback
      when 'createStream'
        @respondCreateStream commandMessage, callback
      when 'play'
        streamId = commandMessage.objects[1]?.value
        @respondPlay commandMessage, callback
      when 'closeStream'
        @closeStream callback
      when 'deleteStream'
        @deleteStream commandMessage, callback
      when 'pause'
        @respondPause commandMessage, callback
      when 'pauseRaw'
        logger.debug "[rtmp] ignoring pauseRaw"
        callback null
#        @respondPauseRaw commandMessage, callback
      # Methods used for publishing from the client
      when 'seek'
        @respondSeek commandMessage, callback
      when 'releaseStream'
        @respondReleaseStream commandMessage, callback
      when 'FCPublish'
        @respondFCPublish commandMessage, callback
      when 'publish'
        @respondPublish commandMessage, callback
      when 'FCUnpublish'
        @respondFCUnpublish commandMessage, callback
      else
        logger.warn "[rtmp:receive] unknown (not implemented) AMF command: #{commandMessage.command}"
        logger.debug commandMessage
#        @respondWithError commandMessage, callback
        callback null  # ignore

  createAck: ->
    if DEBUG_OUTGOING_RTMP_PACKETS
      logger.info "createAck"
    return createRTMPMessage
      chunkStreamID: 2
      timestamp: 0  # TODO: Is zero OK?
      messageTypeID: 3  # Acknowledgement
      messageStreamID: 0
      body: new Buffer [
        # number of bytes received so far (4 bytes)
        (@receivedBytes >>> 24) & 0xff
        (@receivedBytes >>> 16) & 0xff
        (@receivedBytes >>> 8) & 0xff
        @receivedBytes & 0xff
      ]

  handleData: (buf, callback) ->
    @scheduleTimeout()

    outputs = []
    seq = new Sequent

    if @windowAckSize?
      @receivedBytes += buf.length
      if @receivedBytes - @lastSentAckBytes > @windowAckSize / 2
        outputs.push @createAck()
        @lastSentAckBytes = @receivedBytes

    if @state is SESSION_STATE_NEW
      if @tmpBuf?
        buf = Buffer.concat [@tmpBuf, buf], @tmpBuf.length + buf.length
        @tmpBuf = null
      if buf.length < 1537
        logger.debug "[rtmp] waiting for C0+C1"
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
        logger.debug "[rtmp] waiting for C2"
        @tmpBuf = buf
        return
      @tmpBuf = null

      # TODO: should we validate C2?
#      c2Message = buf[0..1535]

      @state = SESSION_STATE_HANDSHAKE_DONE
      logger.debug "[rtmp] handshake success"

      if buf.length <= 1536
        callback null
        return

      buf = buf[1536..]

    if @state isnt SESSION_STATE_HANDSHAKE_DONE
      logger.error "[rtmp:receive] unknown session state: #{@state}"
      callback new Error "Unknown session state"
    else
      if @useEncryption
        buf = @decrypt buf

      if @tmpBuf?
        buf = Buffer.concat [@tmpBuf, buf], @tmpBuf.length + buf.length
        @tmpBuf = null

      onConsumeAllPackets = =>
        outbuf = @concatenate outputs
        if @useEncryption
          outbuf = @encrypt outbuf
        callback null, outbuf

      consumeNextRTMPMessage = =>
        if not buf?
          onConsumeAllPackets()
          return
        parseResult = @parseRTMPMessages buf
        if parseResult.consumedLen is 0  # not consumed at all
          @tmpBuf = buf
          # no message to process
          onConsumeAllPackets()
          return
        else if parseResult.consumedLen < buf.length  # consumed a part of buffer
          buf = buf[parseResult.consumedLen..]
        else  # consumed all buffers
          buf = null

        seq.reset()

        seq.wait parseResult.rtmpMessages.length, (err, output) ->
          if err?
            logger.error "[rtmp:receive] ignoring invalid packet (#{err})"
          if output?
            outputs.push output
          consumeNextRTMPMessage()

        for rtmpMessage in parseResult.rtmpMessages
          switch rtmpMessage.messageTypeID
            when 1  # Set Chunk Size
              newChunkSize = rtmpMessage.body[0] * Math.pow(256, 3) +
                (rtmpMessage.body[1] << 16) +
                (rtmpMessage.body[2] << 8) +
                rtmpMessage.body[3]
              if DEBUG_INCOMING_RTMP_PACKETS
                logger.info "[rtmp:receive] Set Chunk Size: #{newChunkSize}"
              @receiveChunkSize = newChunkSize
              seq.done()
            when 3  # Acknowledgement
              acknowledgementMessage = parseAcknowledgementMessage rtmpMessage.body
              if DEBUG_INCOMING_RTMP_PACKETS
                logger.info "[rtmp:receive] Ack: #{acknowledgementMessage.sequenceNumber}"
              seq.done()
            when 4  # User Control Message
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
                if DEBUG_INCOMING_RTMP_PACKETS
                  logger.info "[rtmp:receive] SetBufferLength: streamID=#{streamID} bufferLength=#{bufferLength}"
              else if userControlMessage.eventType is 7
                timestamp = (userControlMessage.eventData[0] << 24) +
                  (userControlMessage.eventData[1] << 16) +
                  (userControlMessage.eventData[2] << 8) +
                  userControlMessage.eventData[3]
                if DEBUG_INCOMING_RTMP_PACKETS
                  logger.info "[rtmp:receive] PingResponse: timestamp=#{timestamp}"
              else
                if DEBUG_INCOMING_RTMP_PACKETS
                  logger.info "[rtmp:receive] User Control Message"
                  logger.info userControlMessage
              seq.done()
            when 5  # Window Acknowledgement Size
              @windowAckSize = (rtmpMessage.body[0] << 24) +
                (rtmpMessage.body[1] << 16) +
                (rtmpMessage.body[2] << 8) +
                rtmpMessage.body[3]
              if DEBUG_INCOMING_RTMP_PACKETS
                logger.info "[rtmp:receive] WindowAck: #{@windowAckSize}"
              seq.done()
            when 8  # Audio Message (incoming)
              if DEBUG_INCOMING_RTMP_PACKETS
                logger.info "[rtmp:receive] Audio Message"
              audioData = @parseAudioMessage rtmpMessage.body
              if audioData.adtsFrame?
                if not @isFirstAudioReceived
                  @emit 'audio_start', @stream.id
                  @isFirstAudioReceived = true
                pts = dts = flv.convertMsToPTS rtmpMessage.timestamp
                @emit 'audio_data', @stream.id, pts, dts, audioData.adtsFrame
              seq.done()
            when 9  # Video Message (incoming)
              if DEBUG_INCOMING_RTMP_PACKETS
                logger.info "[rtmp:receive] Video Message"
              videoData = @parseVideoMessage rtmpMessage.body
              if videoData.nalUnitGlob?
                if not @isFirstVideoReceived
                  @emit 'video_start', @stream.id
                  @isFirstVideoReceived = true
                dts = rtmpMessage.timestamp
                pts = dts + videoData.info.videoDataTag.compositionTime
                pts = flv.convertMsToPTS pts
                dts = flv.convertMsToPTS dts
                @emit 'video_data', @stream.id, pts, dts, videoData.nalUnitGlob  # TODO pts, dts
              if videoData.isEOS
                logger.info "[rtmp:client=#{@clientid}] received EOS for stream: #{@stream.id}"
                stream = avstreams.get @stream.id
                if not stream?
                  logger.error "[rtmp:client=#{@clientid}] error: unknown stream: #{@stream.id}"
                stream.emit 'end'
              seq.done()
            when 15  # AMF3 data message
              try
                dataMessage = parseAMF0DataMessage rtmpMessage.body[1..]
              catch e
                logger.error "[rtmp] error: failed to parse AMF0 data message: #{e.stack}"
                logger.error "messageTypeID=#{rtmpMessage.messageTypeID} body:"
                Bits.hexdump rtmpMessage.body
                seq.done e
              if dataMessage?
                if DEBUG_INCOMING_RTMP_PACKETS
                  logger.info "[rtmp:receive] AMF3 data:"
                  logger.info dataMessage
                @handleAMFDataMessage dataMessage, (err, output) ->
                  if err?
                    logger.error "[rtmp:receive] packet error: #{err}"
                  if output?
                    outputs.push output
                  seq.done()
            when 17  # AMF3 command (0x11)
              # Does the first byte == 0x00 mean AMF0?
              commandMessage = parseAMF0CommandMessage rtmpMessage.body[1..]
              if DEBUG_INCOMING_RTMP_PACKETS
                debugMsg = "[rtmp:receive] AMF3 command: #{commandMessage.command}"
                if commandMessage.command is 'pause'
                  msec = commandMessage.objects[2].value
                  if commandMessage.objects[1].value is true
                    debugMsg += " (doPause=true msec=#{msec})"
                  else
                    debugMsg += " (doPause=false msec=#{msec})"
                else if commandMessage.command is 'seek'
                  msec = commandMessage.objects[1].value
                  debugMsg += " (msec=#{msec})"
                logger.debug debugMsg
              @handleAMFCommandMessage commandMessage, (err, output) ->
                if err?
                  logger.error "[rtmp:receive] packet error: #{err}"
                if output?
                  outputs.push output
                seq.done()
            when 18  # AMF0 data message
              try
                dataMessage = parseAMF0DataMessage rtmpMessage.body
              catch e
                logger.error "[rtmp] error: failed to parse AMF0 data message: #{e.stack}"
                logger.error "messageTypeID=#{rtmpMessage.messageTypeID} body:"
                Bits.hexdump rtmpMessage.body
                seq.done e
              if dataMessage?
                if DEBUG_INCOMING_RTMP_PACKETS
                  logger.info "[rtmp:receive] AMF0 data:"
                  logger.info dataMessage
                @handleAMFDataMessage dataMessage, (err, output) ->
                  if err?
                    logger.error "[rtmp:receive] packet error: #{err}"
                  if output?
                    outputs.push output
                  seq.done()
            when 20  # AMF0 command
              commandMessage = parseAMF0CommandMessage rtmpMessage.body
              if DEBUG_INCOMING_RTMP_PACKETS
                logger.info "[rtmp:receive] AMF0 command: #{commandMessage.command}"
              @handleAMFCommandMessage commandMessage, (err, output) ->
                if err?
                  logger.error "[rtmp:receive] packet error: #{err}"
                if output?
                  outputs.push output
                seq.done()
            else
              logger.error "----- BUG -----"
              logger.error "[rtmp:receive] received unknown (not implemented) message type ID: #{rtmpMessage.messageTypeID}"
              logger.error rtmpMessage
              packageJson = require './package.json'
              logger.error "server version: #{packageJson.version}"
              logger.error "Please report this bug along with the video file or relevant part of"
              logger.error "pcap file, and the full (uncut) output of node-rtsp-rtsp-server. Thanks."
              logger.error "https://github.com/iizukanao/node-rtsp-rtmp-server/issues"
              logger.error "---------------"
              seq.done()

      consumeNextRTMPMessage()

class RTMPServer
  constructor: (opts) ->
    @eventListeners = {}
    @port = opts?.rtmpServerPort ? 1935
    @server = net.createServer (c) =>
      c.clientId = ++clientMaxId
      sess = new RTMPSession c
      logger.info "[rtmp:client=#{sess.clientid}] connected"
      sessions[c.clientId] = sess
      sessionsCount++
      c.rtmpSession = sess
      sess.on 'data', (data) ->
        if data? and data.length > 0
          c.write data
      sess.on 'video_start', (args...) =>
        @emit 'video_start', args...
      sess.on 'audio_start', (args...) =>
        @emit 'audio_start', args...
      sess.on 'video_data', (args...) =>
        @emit 'video_data', args...
      sess.on 'audio_data', (args...) =>
        @emit 'audio_data', args...
      c.on 'close', =>
        logger.info "[rtmp:client=#{sess.clientid}] disconnected"
        if sessions[c.clientId]?
          sessions[c.clientId].teardown()
          delete sessions[c.clientId]
          sessionsCount--
        @dumpSessions()
      c.on 'error', (err) ->
        logger.error "[rtmp:client=#{sess.clientid}] socket error: #{err}"
        c.destroy()
      c.on 'data', (data) =>
        c.rtmpSession.handleData data, (err, output) ->
          if err
            logger.error "[rtmp] error: #{err}"
          else if output?
            if output.length > 0
              c.write output
      @dumpSessions()

  start: (opts, callback) ->
    serverPort = opts?.port ? @port

    logger.debug "[rtmp] starting server on port #{serverPort}"
    @server.listen serverPort, '0.0.0.0', 511, =>
      logger.info "[rtmp] server started on port #{serverPort}"
      callback?()

  stop: (callback) ->
    @server.close callback

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

  dumpSessions: ->
    logger.raw "[rtmp: #{sessionsCount} sessions]"
    for sessionID, session of sessions
      logger.raw " " + session.toString()
    if rtmptSessionsCount > 0
      logger.raw "[rtmpt: #{rtmptSessionsCount} sessions]"
      for sessionID, rtmptSession of rtmptSessions
        logger.raw " " + rtmptSession.toString()
    return

  teardownRTMPTClient: (socket) ->
    if socket.rtmptClientID?
      logger.debug "[rtmp] teardownRTMPTClient: #{socket.rtmptClientID}"
      tsession = rtmptSessions[socket.rtmptClientID]
      if tsession?
        tsession.rtmpSession?.teardown()
        delete rtmptSessions[socket.rtmptClientID]
        rtmptSessionsCount--

  updateConfig: (newConfig) ->
    config = newConfig

  # Packets must be come in DTS ascending order
  sendVideoPacket: (stream, nalUnits, pts, dts) ->
    if DEBUG_INCOMING_STREAM_DATA
      totalBytes = 0
      for nalUnit in nalUnits
        totalBytes += nalUnit.length
      logger.info "received video: stream=#{stream.id} #{totalBytes} bytes; #{nalUnits.length} NAL units (#{nalUnits.map((nalu) -> nalu[0] & 0x1f).join(',')}); pts=#{pts}"
    if dts > pts
      throw new Error "pts must be >= dts (pts=#{pts} dts=#{dts})"
    timestamp = convertPTSToMilliseconds dts

    if sessionsCount + rtmptSessionsCount is 0
      return

    message = []

    hasKeyFrame = false
    # This format may be AVCSample in 5.3.4.2.1 of ISO 14496-15
    for nalUnit in nalUnits
      nalUnitType = h264.getNALUnitType nalUnit
      if config.dropH264AccessUnitDelimiter and
      (nalUnitType is h264.NAL_UNIT_TYPE_ACCESS_UNIT_DELIMITER)
        # ignore access unit delimiters
        continue
      if nalUnitType is h264.NAL_UNIT_TYPE_IDR_PICTURE  # 5
        hasKeyFrame = true
      payloadLen = nalUnit.length
      message.push new Buffer [
        # The length of this data is specified in
        # configuration data that has already been sent
        (payloadLen >>> 24) & 0xff,
        (payloadLen >>> 16) & 0xff,
        (payloadLen >>> 8) & 0xff,
        payloadLen & 0xff,
      ]
      message.push nalUnit

    if message.length is 0
      # message is empty
      return

    # Add VIDEODATA tag
    if hasKeyFrame  # IDR picture (key frame)
      firstByte = (1 << 4) | config.flv.videocodecid
    else  # non-IDR picture (inter frame)
      firstByte = (2 << 4) | config.flv.videocodecid
    # Composition time offset: composition time (PTS) - decoding time (DTS)
    compositionTimeMs = Math.floor((pts - dts) / 90)  # convert to milliseconds
    if compositionTimeMs > 0x7fffff  # composition time is signed 24-bit integer
      compositionTimeMs = 0x7fffff
    message.unshift new Buffer [
      # VIDEODATA tag
      firstByte,
      AVC_PACKET_TYPE_NALU,
      # Composition time (signed 24-bit integer)
      # See ISO 14496-12, 8.15.3 for details
      (compositionTimeMs >> 16) & 0xff, # composition time (PTS - DTS)
      (compositionTimeMs >> 8) & 0xff,
      compositionTimeMs & 0xff,
    ]

    buf = Buffer.concat message

    queueVideoMessage stream,
      body: buf
      timestamp: timestamp
      isKeyFrame: hasKeyFrame
      compositionTime: compositionTimeMs

    stream.rtmpLastTimestamp = timestamp

    return

  sendAudioPacket: (stream, rawDataBlock, timestamp) ->
    if DEBUG_INCOMING_STREAM_DATA
      logger.info "received audio: stream=#{stream.id} #{rawDataBlock.length} bytes; timestamp=#{timestamp}"
    timestamp = convertPTSToMilliseconds timestamp

    if sessionsCount + rtmptSessionsCount is 0
      return

    # TODO: support other than AAC too?
    headerBytes = new Buffer flv.createAACAudioDataTag
      aacPacketType: flv.AAC_PACKET_TYPE_RAW

    buf = Buffer.concat [headerBytes, rawDataBlock], rawDataBlock.length + 2

    queueAudioMessage stream,
      body: buf
      timestamp: timestamp

    stream.rtmpLastTimestamp = timestamp

    return

  sendEOS: (stream) ->
    logger.debug "[rtmp] sendEOS for stream #{stream.id}"
    lastTimestamp = stream.rtmpLastTimestamp ? 0

    playComplete = createAMF0DataMessageParams
      chunkStreamID: 4
      timestamp: lastTimestamp
      messageStreamID: 1
      objects: [
        createAMF0Data('onPlayStatus'),
        createAMF0Object({
          level: 'status'
          code: 'NetStream.Play.Complete'
          duration: 0
          bytes: 0
        }),
      ]

    playStop = createAMF0CommandMessageParams
      chunkStreamID: 4  # 5?
      timestamp: lastTimestamp
      messageStreamID: 1
      command: 'onStatus'
      transactionID: 0
      objects: [
        createAMF0Data(null),
        createAMF0Object({
          level: 'status'
          code: 'NetStream.Play.Stop'
          description: "Stopped playing #{stream.id}."
          clientid: @clientid
          reason: ''
          details: stream.id
        })
      ]

    streamEOF1 =
      chunkStreamID: 2
      timestamp: 0
      messageTypeID: 0x04  # User Control Message
      messageStreamID: 0
      body: new Buffer [
        # Stream EOF (see 7.1.7. User Control Message Events)
        0, 1,
        # Stream ID of the stream that reaches EOF
        0, 0, 0, 1
      ]

    queueRTMPMessages stream, [ playComplete, playStop, streamEOF1 ],
      forceFlush: true
      hasControlMessage: true

  handleRTMPTRequest: (req, callback) ->
    # /fcs/ident2 will be handled in another place
    if (match = /^\/([^/]+)\/([^/]+)(?:\/([^\/]+))?/.exec req.uri)?
      command = match[1]
      client = match[2]
      index = match[3]
      if not index?
        index = client
      if (command is 'fcs') and (index is 'ident2')
        response = """
        HTTP/1.1 400 RTMPT command /fcs/ident2 is not supported
        Cache-Control: no-cache
        Content-Type: text/plain
        Content-Length: 0
        Connection: keep-alive


        """.replace /\n/g, '\r\n'
        callback null, response
      else if command is 'open'
        session = new RTMPTSession req.socket, =>
          rtmptSessions[session.id] = session
          rtmptSessionsCount++
          session.respondOpen req, callback
          @dumpSessions()
        session.on 'video_start', (args...) =>
          @emit 'video_start', args...
        session.on 'audio_start', (args...) =>
          @emit 'audio_start', args...
        session.on 'video_data', (args...) =>
          @emit 'video_data', args...
        session.on 'audio_data', (args...) =>
          @emit 'audio_data', args...
      else if command is 'idle'
        session = rtmptSessions[client]
        if session?
          # TODO: Do we have to sort requests by index?
          index = parseInt index
          session.respondIdle req, callback
          if session.requestBuffer?
            session.requestBuffer.nextIndex = index + 1
          else
            session.requestBuffer =
              nextIndex: index + 1
              reqs: []
        else
          callback new Error "No such session"
      else if command is 'send'
        session = rtmptSessions[client]
        if session?
          index = parseInt index
          if session.requestBuffer?
            if index > session.requestBuffer.nextIndex
              # If HTTP-tunneling (RTMPT or RTMPTE) is used, Flash Player
              # may send requests in parallel using multiple connections.
              # So we have to buffer and sort the requests.
              session.requestBuffer.reqs.push
                req     : req
                index   : index
                callback: callback
              session.requestBuffer.reqs.sort (a, b) ->
                a.index - b.index
            else if index is session.requestBuffer.nextIndex
              session.respondSend req, callback
              session.requestBuffer.nextIndex = index + 1
            else
              logger.warn "[rtmpt] received stale request: #{index}"

            # Discard old requests
            if (session.requestBuffer.reqs.length > 0) and
            (index - session.requestBuffer.reqs[0].index > RTMPT_SEND_REQUEST_BUFFER_SIZE)
                info = session.requestBuffer.reqs[0]
                if info.index is session.requestBuffer.nextIndex + 1
                  logger.warn "[rtmpt] discarded lost request: #{session.requestBuffer.nextIndex}"
                else
                  logger.warn "[rtmpt] discarded lost requests: #{session.requestBuffer.nextIndex}-#{info.index-1}"
                session.requestBuffer.nextIndex = info.index

            # Consume buffered requests
            while (session.requestBuffer.reqs.length > 0) and
            (session.requestBuffer.reqs[0].index is session.requestBuffer.nextIndex)
              info = session.requestBuffer.reqs.shift()
              # TODO: Call respondSend with setImmediate()?
              session.respondSend info.req, info.callback
              session.requestBuffer.nextIndex = info.index + 1
          else
            # TODO: Does index start at zero?
            session.requestBuffer =
              nextIndex: index + 1
              reqs: []
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
    @creationDate = new Date  # for debug
    @eventListeners = {}
    @socket = socket
    @pollingDelay = 1
    @pendingResponses = []
    @requestBuffer = null
    @rtmpSession = new RTMPSession socket
    @rtmpSession.on 'data', (data) =>
      @scheduleTimeout()
      @pendingResponses.push data
    @rtmpSession.on 'video_start', (args...) =>
      @emit 'video_start', args...
    @rtmpSession.on 'audio_start', (args...) =>
      @emit 'audio_start', args...
    @rtmpSession.on 'video_data', (args...) =>
      @emit 'video_data', args...
    @rtmpSession.on 'audio_data', (args...) =>
      @emit 'audio_data', args...
    @rtmpSession.on 'teardown', =>
      logger.info "[rtmpt:#{@rtmpSession.clientid}] received teardown"
      @close()
    generateNewSessionID (err, sid) =>
      if err
        callback err
      else
        @id = sid
        @socket.rtmptClientID = @id
        @scheduleTimeout()
        callback? null

  toString: ->
    return "#{@id}: rtmp_session=#{@rtmpSession.clientid} created_at=#{@creationDate}"

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
      logger.info "[rtmpt] session timeout: #{@id}"
      @close()
    , config.rtmptSessionTimeoutMs

  close: ->
    if @isClosed
      # already closed
      return
    logger.info "[rtmpt:#{@rtmpSession.clientid}] close"
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
        logger.error "[rtmpt:send-resp] Error: #{err}"
        callback err
      else if output?
        interval = new Buffer [ @pollingDelay ]
        allBytes = Buffer.concat [interval, output], 1 + output.length
        callback null, @createHTTPResponse allBytes
      else
        # No response from me
        allBytes = new Buffer [ @pollingDelay ]
        callback null, @createHTTPResponse allBytes

  respondClose: (req, callback) ->
    allBytes = new Buffer [ @pollingDelay ]
    @close()
    callback null, @createHTTPResponse allBytes

api =
  RTMPServer: RTMPServer

module.exports = api
