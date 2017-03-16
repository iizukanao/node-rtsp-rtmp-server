url = require 'url'

config = require './config'
StreamServer = require './stream_server'
Bits = require './bits'
logger = require './logger'

Bits.set_warning_fatal true
logger.setLevel logger.LEVEL_INFO

streamServer = new StreamServer

# Uncomment this block if you use Basic auth for RTSP
#streamServer.setAuthenticator (username, password, callback) ->
#  # If isAuthenticated is true, access is allowed
#  isAuthenticated = false
#
#  # Replace here
#  if (username is 'user1') and (password is 'password1')
#    isAuthenticated = true
#
#  callback null, isAuthenticated

streamServer.setLivePathConsumer (uri, callback) ->
  pathname = url.parse(uri).pathname?[1..]

  isAuthorized = true

  if isAuthorized
    callback null # Accept access
  else
    callback new Error 'Unauthorized access' # Deny access

if config.recordedDir?
  streamServer.attachRecordedDir config.recordedDir

process.on 'SIGINT', =>
  console.log 'Got SIGINT'
  streamServer.stop ->
    process.kill process.pid, 'SIGTERM'

process.on 'uncaughtException', (err) ->
  streamServer.stop()
  throw err

streamServer.start()
