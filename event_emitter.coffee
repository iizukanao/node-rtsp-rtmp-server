# TODO: Write tests

# EventEmitter with support for catch-all listeners and mixin
class EventEmitterModule
  # Apply EventEmitterModule to the class
  @mixin: (cls) ->
    for own name, value of EventEmitterModule.prototype
      try
        cls::[name] = value
      catch e
        throw new Error "Call EventEmitterModule.mixin() after the class definition"
    return

  # Inject EventEmitterModule into the object
  @inject: (obj) ->
    for own name, value of EventEmitterModule.prototype
      obj[name] = value
    obj.eventListeners = {}
    obj.catchAllEventListeners = []
    return

  emit: (name, data...) ->
    if @eventListeners?[name]?
      for listener in @eventListeners[name]
        listener data...
    if @catchAllEventListeners?
      for listener in @catchAllEventListeners
        listener name, data...
    return

  onAny: (listener) ->
    if @catchAllEventListeners?
      @catchAllEventListeners.push listener
    else
      @catchAllEventListeners = [ listener ]

  offAny: (listener) ->
    if @catchAllEventListeners?
      for _listener, i in @catchAllEventListeners
        if _listener is listener
          @catchAllEventListeners[i..i] = []  # remove element at index i
    return

  on: (name, listener) ->
    if not @eventListeners?
      @eventListeners = {}
    if @eventListeners[name]?
      @eventListeners[name].push listener
    else
      @eventListeners[name] = [ listener ]

  removeListener: (name, listener) ->
    if @eventListeners?[name]?
      for _listener, i in @eventListeners[name]
        if _listener is listener
          @eventListeners[i..i] = []  # remove element at index i
    return

  off: (name, listener) ->
    @removeListener arguments...

module.exports = EventEmitterModule

###
# Usage

    EventEmitterModule = require './EventEmitterModule'

    class MyClass

    EventEmitterModule.mixin MyClass

    obj = new MyClass
    obj.on 'event-a', (a, b, c) ->
      console.log "received event-a a=#{a} b=#{b} c=#{c}"

    obj.onAny (eventName, data...) ->
      console.log "received eventName=#{eventName} data=#{data}"

    obj.emit 'event-a', 111, 222, 333
    obj.emit 'event-b', 'hello'

Or you can inject EventEmitterModule into an object dynamically
(with slightly worse performance):

    class MyClass
      constructor: ->
        EventEmitterModule.inject this

    obj = new MyClass
    obj.on 'event-a', ->
      console.log "received event-a"

    obj.emit 'event-a'

###
