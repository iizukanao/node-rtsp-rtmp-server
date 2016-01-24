ejs = require 'ejs'
path = require 'path'
fs = require 'fs'
zlib = require 'zlib'
spawn = require('child_process').spawn
Sequent = require 'sequent'

logger = require './logger'

# Directory to store EJS templates
TEMPLATE_DIR = "#{__dirname}/template"

# Directory to store static files
STATIC_DIR = "#{__dirname}/public"

# Filename of default file in static directory
DIRECTORY_INDEX_FILENAME = 'index.html'

# Server name which is embedded in HTTP response header
DEFAULT_SERVER_NAME = 'node-rtsp-rtmp-server'

# Response larger than this bytes is compressed
GZIP_SIZE_THRESHOLD = 300

DAY_NAMES = [
  'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'
]

MONTH_NAMES = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
]

zeropad = (width, num) ->
  num += ''
  while num.length < width
    num = '0' + num
  num

class HTTPHandler
  constructor: (opts) ->
    @serverName = opts?.serverName ? DEFAULT_SERVER_NAME
    @documentRoot = opts?.documentRoot ? STATIC_DIR

  setServerName: (name) ->
    @serverName = name

  handlePath: (filepath, req, callback) ->
    # Example implementation
    if filepath is '/crossdomain.xml'
      @respondCrossDomainXML req, callback
    else if filepath is '/ping'
      @respondText 'pong', req, callback
    else if filepath is '/list'
      opts =
        files: [ 'foo', 'bar', 'baz' ]
      fs.readFile "#{TEMPLATE_DIR}/list.ejs", {
        encoding: 'utf8'
      }, (err, template) =>
        if err
          logger.error err
          @serverError req, callback
        else
          html = ejs.render template, opts
          @respondHTML html, req, callback
    else if filepath is '/302'
      @redirect '/new-url', req, callback
    else if filepath is '/404'
      @notFound req, callback
    else if filepath is '/400'
      @badRequest req, callback
    else if filepath is '/500'
      @serverError req, callback
    else
      @respondStaticPath "#{@documentRoot}/#{filepath[1..]}", req, callback

  createHeader: (params) ->
    protocol = params.protocol ? 'HTTP/1.1'
    statusMessage = '200 OK'
    if params?.statusCode?
      if params.statusCode is 404
        statusMessage = '404 Not Found'
      else if params.statusCode is 500
        statusMessage = '500 Internal Server Error'
      else if params.statusCode is 302
        statusMessage = '302 Found'
      else if params.statusCode is 301
        statusMessage = '301 Moved Permanently'
      else if params.statusCode is 206
        statusMessage = '206 Partial Content'
      else if params.statusCode is 400
        statusMessage = '400 Bad Request'
      else if params.statusCode is 401
        statusMessage = '401 Unauthorized'
    header = """
    #{protocol} #{statusMessage}
    Date: #{api.getDateHeader()}
    Server: #{@serverName}

    """

    if params?.req?.headers.connection?.toLowerCase() is 'keep-alive'
      header += 'Connection: keep-alive\n'
    else
      header += 'Connection: close\n'

    if params?.contentLength?
      header += "Content-Length: #{params.contentLength}\n"
    if params?.location?
      header += "Location: #{params.location}\n"
    if params?.contentType?
      header += "Content-Type: #{params.contentType}\n"
    if params?.contentEncoding?
      header += "Content-Encoding: #{params.contentEncoding}\n"
    if params?.contentRange?
      header += "Content-Range: #{params.contentRange}\n"
    if params?.authenticate?
      header += "WWW-Authenticate: #{params.authenticate}\n"
    header.replace(/\n/g, '\r\n') + '\r\n'

  redirect: (path, req, callback) ->
    headerBytes = new Buffer @createHeader({
      statusCode: 302
      location: path
      req: req
      contentLength: 0
    })
    callback null, headerBytes

  notFound: (req, callback) ->
    bodyBytes = new Buffer 'Not Found', 'utf8'
    bodyLength = bodyBytes.length
    headerBytes = new Buffer @createHeader({
      statusCode: 404
      contentLength: bodyLength
      req: req
      contentType: "text/plain; charset=utf-8"
    }), 'utf8'
    allBytes = Buffer.concat [headerBytes, bodyBytes], headerBytes.length + bodyLength
    callback null, allBytes

  respondTextWithHeader: (str, req, opts, callback) ->
    textBytes = new Buffer (str+''), 'utf8'
    textLength = textBytes.length
    headerOpts =
      statusCode: 200
      contentLength: textLength
      req: req
      contentType: "text/plain; charset=utf-8"
    if opts?
      for name, value of opts
        headerOpts[name] = value
    headerBytes = new Buffer @createHeader(headerOpts), 'utf8'
    allBytes = Buffer.concat [headerBytes, textBytes], headerBytes.length + textLength
    callback null, allBytes

  respondJavaScript: (str, req, callback) ->
    @respondTextWithHeader str, req, {contentType: 'application/javascript; charset=utf-8'}, callback

  respondText: (str, req, callback) ->
    @respondTextWithHeader str, req, null, callback

  treatCompress: (bytes, req, callback) ->
    if bytes.length < GZIP_SIZE_THRESHOLD
      callback null, bytes, null
      return

    acceptEncoding = req.headers['accept-encoding']

    if not acceptEncoding?
      callback null, bytes, null
      return

    acceptEncoding = acceptEncoding.toLowerCase()

    if /\bgzip\b/.test acceptEncoding
      zlib.gzip bytes, (err, compressedBytes) ->
        if err
          callback err
        else
          callback null, compressedBytes, 'gzip'
        return
    else if /\bdeflate\b/.test acceptEncoding
      zlib.deflate bytes, (err, compressedBytes) ->
        if err
          callback err
        else
          callback null, compressedBytes, 'deflate'
    else
      callback null, bytes, null

  respondJS: (content, req, callback) ->
    contentBytes = new Buffer content, 'utf8'
    @treatCompress contentBytes, req, (err, contentBytes, encoding) =>
      if err
        callback err
        return
      contentLength = contentBytes.length
      headerBytes = new Buffer @createHeader({
        contentLength: contentLength
        req: req
        contentEncoding: encoding
        contentType: 'application/javascript'
      }), 'utf8'
      allBytes = Buffer.concat [headerBytes, contentBytes], headerBytes.length + contentLength
      callback null, allBytes

  respondHTML: (html, req, callback) ->
    htmlBytes = new Buffer html, 'utf8'
    @treatCompress htmlBytes, req, (err, htmlBytes, encoding) =>
      if err
        callback err
        return
      htmlLength = htmlBytes.length
      headerBytes = new Buffer @createHeader({
        contentLength: htmlLength
        req: req
        contentEncoding: encoding
        contentType: "text/html; charset=utf-8"
      }), 'utf8'
      allBytes = Buffer.concat [headerBytes, htmlBytes], headerBytes.length + htmlLength
      callback null, allBytes

  badRequest: (req, callback) ->
    bodyBytes = new Buffer 'Bad Request', 'utf8'
    bodyLength = bodyBytes.length
    headerBytes = new Buffer @createHeader({
      statusCode: 400
      contentLength: bodyLength
      req: req
      contentType: "text/plain; charset=utf-8"
    }), 'utf8'
    allBytes = Buffer.concat [headerBytes, bodyBytes], headerBytes.length + bodyLength
    callback null, allBytes

  serverError: (req, callback) ->
    bodyBytes = new Buffer 'Server Error', 'utf8'
    bodyLength = bodyBytes.length
    headerBytes = new Buffer @createHeader({
      statusCode: 500
      contentLength: bodyLength
      req: req
      contentType: "text/plain; charset=utf-8"
    }), 'utf8'
    allBytes = Buffer.concat [headerBytes, bodyBytes], headerBytes.length + bodyLength
    callback null, allBytes

  respondCrossDomainXML: (req, callback) ->
    content = """
    <?xml version="1.0"?>
    <!DOCTYPE cross-domain-policy SYSTEM "http://www.adobe.com/xml/dtds/cross-domain-policy.dtd">
    <cross-domain-policy>
        <site-control permitted-cross-domain-policies="all"/>
        <allow-access-from domain="*" secure="false"/>
        <allow-http-request-headers-from domain="*" headers="*" secure="false"/>
    </cross-domain-policy>

    """
    opts = { contentType: 'text/x-cross-domain-policy' }
    @respondTextWithHeader content, req, opts, callback

  respondStaticPath: (filepath, req, callback) ->
    if filepath is ''
      filepath = DIRECTORY_INDEX_FILENAME
    else if /\/$/.test filepath
      filepath += DIRECTORY_INDEX_FILENAME
    if filepath.indexOf('..') isnt -1
      @badRequest req, callback
      return
    @respondFile filepath, req, callback

  respondFile: (filepath, req, callback) ->
    fs.exists filepath, (exists) =>
      if exists
        fs.stat filepath, (err, stat) =>
          if err
            logger.error "stat error: #{filepath}"
            @serverError req, callback
            return
          seq = new Sequent
          if stat.isDirectory()
            filepath += "/#{DIRECTORY_INDEX_FILENAME}"
            fs.exists filepath, (exists) =>
              if exists
                seq.done()
              else
                @notFound req, callback
          else
            seq.done()
          seq.wait 1, =>
            fs.readFile filepath, {encoding:null, flag:'r'}, (err, contentBuf) =>
              if err
                logger.error "readFile error: #{filepath}"
                @serverError req, callback
                return
              contentRangeHeader = null
              if req.headers.range?
                if (match = /^bytes=(\d+)?-(\d+)?$/.exec req.headers.range)?
                  from = if match[1]? then parseInt(match[1]) else null
                  to = if match[2]? then parseInt(match[2]) else null
                  logger.debug "Range from #{from} to #{to}"
                  if not from? and to?  # last n bytes
                    contentRangeHeader = "bytes #{contentBuf.length-to}-#{contentBuf.length-1}/#{contentBuf.length}"
                    contentBuf = contentBuf.slice contentBuf.length-to, contentBuf.length
                  else if from? and not to?
                    if from > 0
                      contentRangeHeader = "bytes #{from}-#{contentBuf.length-1}/#{contentBuf.length}"
                      contentBuf = contentBuf.slice from, contentBuf.length
                  else if from? and to?
                    contentRangeHeader = "bytes #{from}-#{to}/#{contentBuf.length}"
                    contentBuf = contentBuf.slice from, to + 1
                else
                  logger.error "[Range spec #{req.headers.range} is not supported]"
              if err
                @serverError req, callback
                return
              contentType = 'text/html; charset=utf-8'
              doCompress = true
              if /\.m3u8$/.test filepath
                contentType = 'application/x-mpegURL'
              else if /\.ts$/.test filepath
                contentType = 'video/MP2T'
                doCompress = false
              else if /\.mp4$/.test filepath
                contentType = 'video/mp4'
                doCompress = false
              else if /\.3gpp?$/.test filepath
                contentType = 'video/3gpp'
                doCompress = false
              else if /\.jpg$/.test filepath
                contentType = 'image/jpeg'
                doCompress = false
              else if /\.gif$/.test filepath
                contentType = 'image/gif'
                doCompress = false
              else if /\.png$/.test filepath
                contentType = 'image/png'
                doCompress = false
              else if /\.swf$/.test filepath
                contentType = 'application/x-shockwave-flash'
                doCompress = false
              else if /\.css$/.test filepath
                contentType = 'text/css'
              else if /\.js$/.test filepath
                contentType = 'application/javascript'
              else if /\.txt$/.test filepath
                contentType = 'text/plain; charset=utf-8'
              if contentRangeHeader?
                statusCode = 206
              else
                statusCode = 200
              if doCompress
                @treatCompress contentBuf, req, (err, compressedBytes, encoding) =>
                  if err
                    callback err
                    return
                  header = @createHeader
                    statusCode: statusCode
                    contentType: contentType
                    contentLength: compressedBytes.length
                    req: req
                    contentRange: contentRangeHeader
                    contentEncoding: encoding
                  headerBuf = new Buffer header, 'utf8'
                  callback null, [ headerBuf, compressedBytes ]
              else
                header = @createHeader
                  statusCode: statusCode
                  contentType: contentType
                  contentLength: contentBuf.length
                  req: req
                  contentRange: contentRangeHeader
                headerBuf = new Buffer header, 'utf8'
                callback null, [ headerBuf, contentBuf ]
      else
        logger.warn "[http] Requested file not found: #{filepath}"
        @notFound req, callback

api =
  HTTPHandler: HTTPHandler

  getDateHeader: ->
    d = new Date
    "#{DAY_NAMES[d.getUTCDay()]}, #{d.getUTCDate()} #{MONTH_NAMES[d.getUTCMonth()]}" +
    " #{d.getUTCFullYear()} #{zeropad 2, d.getUTCHours()}:#{zeropad 2, d.getUTCMinutes()}" +
    ":#{zeropad 2, d.getUTCSeconds()} UTC"

  parseRequest: (str) ->
    [headerPart, body] = str.split '\r\n\r\n'

    lines = headerPart.split /\r\n/
    [method, uri, protocol] = lines[0].split /\s+/
    if protocol?
      # Split "HTTP/1.1" to "HTTP" and "1.1"
      slashPos = protocol.indexOf '/'
      if slashPos isnt -1
        protocolName = protocol[0...slashPos]
        protocolVersion = protocol[slashPos+1..]
    headers = {}
    for line, i in lines
      continue if i is 0
      continue if /^\s*$/.test line
      params = line.split ": "
      headers[params[0].toLowerCase()] = params[1]

    try
      decodedURI = decodeURIComponent uri
    catch e
      logger.error "error: failed to decode URI: #{uri}"
      return null

    return {
      method: method
      uri: decodedURI
      protocol: protocol
      protocolName: protocolName
      protocolVersion: protocolVersion
      headers: headers
      body: body
      headerBytes: Buffer.byteLength headerPart, 'utf8'
    }

module.exports = api
