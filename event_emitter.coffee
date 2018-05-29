# EventEmitter with support for catch-all listeners and mixin
# TODO: Write tests

###
# Usage

    EventEmitterModule = require './event_emitter'

    # Apply EventEmitterModule to MyClass
    class MyClass extends EventEmitterModule

    obj = new MyClass
    obj.on 'testevent', (a, b, c) ->
      console.log "received testevent a=#{a} b=#{b} c=#{c}"

    obj.onAny (eventName, data...) ->
      console.log "received eventName=#{eventName} data=#{data}"

    obj.emit 'testevent', 111, 222, 333
    obj.emit 'anotherevent', 'hello'

###

class EventEmitterModule
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
