# EventEmitter with support for catch-all listeners and mixin
# TODO: Write tests

###
# Usage

Extend EventEmitterModule class to use its features.

    EventEmitterModule = require './event_emitter'

    class MyClass extends EventEmitterModule

    obj = new MyClass
    obj.on 'testevent', (a, b, c) ->
      console.log "received testevent a=#{a} b=#{b} c=#{c}"

    obj.onAny (eventName, data...) ->
      console.log "received by onAny: eventName=#{eventName} data=#{data}"

    obj.emit 'testevent', 111, 222, 333
    obj.emit 'anotherevent', 'hello'

Alternatively, you can add EventEmitterModule features to
an existing class with `mixin`.

    class MyClass

    # Add EventEmitterModule features to MyClass
    EventEmitterModule.mixin MyClass

    obj = new MyClass
    obj.on 'testevent', ->
      console.log "received testevent"

    obj.emit 'testevent'

Also, EventEmitterModule can be injected dynamically into
an object, but with slightly worse performance.

    class MyClass
      constructor: ->
        EventEmitterModule.inject this

    obj = new MyClass
    obj.on 'testevent', ->
      console.log "received testevent"

    obj.emit 'testevent'
###

class EventEmitterModule
  # Apply EventEmitterModule to the class
  @mixin: (cls) ->
    proto = EventEmitterModule.prototype
    for name in Object.getOwnPropertyNames(proto)
      if name is 'constructor'
        continue
      try
        cls::[name] = proto[name]
      catch e
        throw new Error "Call EventEmitterModule.mixin() after the class definition"
    return

  # Inject EventEmitterModule into the object
  @inject: (obj) ->
    proto = EventEmitterModule.prototype
    for name in Object.getOwnPropertyNames(proto)
      if name is 'constructor'
        continue
      obj[name] = proto[name]
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
