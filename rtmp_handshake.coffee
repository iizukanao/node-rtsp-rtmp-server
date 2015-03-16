# RTMP handshake

crypto = require 'crypto'
codec_utils = require './codec_utils'
logger = require './logger'

MESSAGE_FORMAT_1       =  1
MESSAGE_FORMAT_2       =  2
MESSAGE_FORMAT_UNKNOWN = -1

RTMP_SIG_SIZE = 1536
SHA256DL = 32  # SHA256 digest length (bytes)

KEY_LENGTH = 128

RandomCrud = new Buffer [
    0xf0, 0xee, 0xc2, 0x4a,
    0x80, 0x68, 0xbe, 0xe8, 0x2e, 0x00, 0xd0, 0xd1,
    0x02, 0x9e, 0x7e, 0x57, 0x6e, 0xec, 0x5d, 0x2d,
    0x29, 0x80, 0x6f, 0xab, 0x93, 0xb8, 0xe6, 0x36,
    0xcf, 0xeb, 0x31, 0xae
]

GenuineFMSConst = "Genuine Adobe Flash Media Server 001"
GenuineFMSConstCrud = Buffer.concat [new Buffer(GenuineFMSConst, "utf8"), RandomCrud]

GenuineFPConst  = "Genuine Adobe Flash Player 001"
GenuineFPConstCrud = Buffer.concat [new Buffer(GenuineFPConst, "utf8"), RandomCrud]

GetClientGenuineConstDigestOffset = (buf) ->
  offset = buf[0] + buf[1] + buf[2] + buf[3]
  offset = (offset % 728) + 12
  offset

GetServerGenuineConstDigestOffset = (buf) ->
  offset = buf[0] + buf[1] + buf[2] + buf[3]
  offset = (offset % 728) + 776
  offset

GetClientDHOffset = (buf) ->
  offset = buf[0] + buf[1] + buf[2] + buf[3]
  offset = (offset % 632) + 772
  offset

GetServerDHOffset = (buf) ->
  offset = buf[0] + buf[1] + buf[2] + buf[3]
  offset = (offset % 632) + 8
  offset

hasSameBytes = (buf1, buf2) ->
  for i in [0...buf1.length]
    if buf1[i] isnt buf2[i]
      return false
  return true

detectClientMessageFormat = (clientsig) ->
  sdl = GetServerGenuineConstDigestOffset clientsig[772..775]
  msg = Buffer.concat [clientsig[...sdl], clientsig[sdl+SHA256DL..]], 1504
  computedSignature = codec_utils.calcHmac msg, GenuineFPConst
  providedSignature = clientsig[sdl...sdl+SHA256DL]
  if hasSameBytes computedSignature, providedSignature
    return MESSAGE_FORMAT_2

  sdl = GetClientGenuineConstDigestOffset clientsig[8..11]
  msg = Buffer.concat [clientsig[...sdl], clientsig[sdl+SHA256DL..]], 1504
  computedSignature = codec_utils.calcHmac msg, GenuineFPConst
  providedSignature = clientsig[sdl...sdl+SHA256DL]
  if hasSameBytes computedSignature, providedSignature
    return MESSAGE_FORMAT_1

  return MESSAGE_FORMAT_UNKNOWN

DHKeyGenerate = (bits) ->
  dh = crypto.getDiffieHellman 'modp2'
  dh.generateKeys()
  return dh

generateS1 = (messageFormat, dh, callback) ->
  crypto.pseudoRandomBytes RTMP_SIG_SIZE - 8, (err, randomBytes) ->
    handshakeBytes = Buffer.concat [
      new Buffer([ 0, 0, 0, 0, 1, 2, 3, 4 ]),
      randomBytes
    ], RTMP_SIG_SIZE
    if messageFormat is 1
      serverDHOffset = GetClientDHOffset handshakeBytes[1532..1535]
    else
      serverDHOffset = GetServerDHOffset handshakeBytes[768..771]

    publicKey = dh.getPublicKey()
    publicKey.copy handshakeBytes, serverDHOffset, 0, publicKey.length

    if messageFormat is 1
      serverDigestOffset = GetClientGenuineConstDigestOffset handshakeBytes[8..11]
    else
      serverDigestOffset = GetServerGenuineConstDigestOffset handshakeBytes[772..775]
    msg = Buffer.concat [
      handshakeBytes[0...serverDigestOffset],
      handshakeBytes[serverDigestOffset+SHA256DL..]
    ], RTMP_SIG_SIZE - SHA256DL
    hash = codec_utils.calcHmac msg, GenuineFMSConst
    hash.copy handshakeBytes, serverDigestOffset, 0, 32
    callback null, handshakeBytes

generateS2 = (messageFormat, clientsig, callback) ->
  if messageFormat is 1
    challengeKeyOffset = GetClientGenuineConstDigestOffset clientsig[8..11]
  else
    challengeKeyOffset = GetServerGenuineConstDigestOffset clientsig[772..775]
  challengeKey = clientsig[challengeKeyOffset..challengeKeyOffset+31]

  if messageFormat is 1
    keyOffset = GetClientDHOffset clientsig[1532..1535]
  else
    keyOffset = GetServerDHOffset clientsig[768..771]
  key = clientsig[keyOffset...keyOffset+KEY_LENGTH]

  hash = codec_utils.calcHmac challengeKey, GenuineFMSConstCrud
  crypto.pseudoRandomBytes RTMP_SIG_SIZE - 32, (err, randomBytes) ->
    signature = codec_utils.calcHmac randomBytes, hash
    s2Bytes = Buffer.concat [
      randomBytes, signature
    ], RTMP_SIG_SIZE
    callback null, s2Bytes,
      clientPublicKey: key

# Generate S0/S1/S2 combined message
generateS0S1S2 = (clientsig, callback) ->
  clientType = clientsig[0]
  clientsig = clientsig[1..]

  dh = DHKeyGenerate KEY_LENGTH * 8

  messageFormat = detectClientMessageFormat clientsig
  if messageFormat is MESSAGE_FORMAT_UNKNOWN
    logger.warn "[rtmp:handshake] warning: unknown message format, assuming format 1"
    messageFormat = 1
  generateS1 messageFormat, dh, (err, s1Bytes) ->
    generateS2 messageFormat, clientsig, (err, s2Bytes, keys) ->
      allBytes = Buffer.concat [
        new Buffer([ clientType ]),  # version (S0)
        s1Bytes,  # S1
        s2Bytes   # S2
      ], 3073
      keys.dh = dh
      callback null, allBytes, keys

module.exports =
  generateS0S1S2: generateS0S1S2
