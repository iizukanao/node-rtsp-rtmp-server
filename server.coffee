StreamServer = require './stream_server'
Bits = require './bits'
logger = require './logger'

Bits.set_warning_fatal true
logger.setLevel logger.LEVEL_INFO

streamServer = new StreamServer

process.on 'SIGINT', =>
  console.log 'Got SIGINT'
  streamServer.stop ->
    process.kill process.pid, 'SIGTERM'

process.on 'uncaughtException', (err) ->
  streamServer.stop()
  throw err

streamServer.start()
