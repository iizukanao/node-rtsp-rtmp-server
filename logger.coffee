# Current log level
logLevel = null

activeTags = {}

zeropad = (columns, num) ->
  num += ''
  while num.length < columns
    num = '0' + num
  num

api =
  LEVEL_DEBUG: 0
  LEVEL_INFO: 1
  LEVEL_WARN: 2
  LEVEL_ERROR: 3
  LEVEL_FATAL: 4
  LEVEL_OFF: 5

  enableTag: (tag) ->
    activeTags[tag] = true

  disableTag: (tag) ->
    delete activeTags[tag]

  print: (str, raw=false) ->
    if not raw
      d = new Date()
      msg = "#{d.getFullYear()}-#{zeropad 2, d.getMonth()+1}-" +
        "#{zeropad 2, d.getDate()} #{zeropad 2, d.getHours()}:" +
        "#{zeropad 2, d.getMinutes()}:#{zeropad 2, d.getSeconds()}." +
        "#{zeropad 3, d.getMilliseconds()} " + str
    else
      msg = str
    console.log msg

  tag: (tag, str, raw=false) ->
    if activeTags[tag]?
      api.print str, raw

  msg: (level, str, raw=false) ->
    if level >= logLevel
      api.print str, raw

  # Prints message without header
  raw: (str) ->
    api.print str, true

  setLevel: (level) ->
    logLevel = level

  getLevel: ->
    return logLevel

  debug: (str, raw=false) ->
    api.msg api.LEVEL_DEBUG, str, raw

  info: (str, raw=false) ->
    api.msg api.LEVEL_INFO, str, raw

  warn: (str, raw=false) ->
    api.msg api.LEVEL_WARN, str, raw

  error: (str, raw=false) ->
    api.msg api.LEVEL_ERROR, str, raw

  fatal: (str, raw=false) ->
    api.msg api.LEVEL_FATAL, str, raw

logLevel = api.LEVEL_DEBUG

module.exports = api
