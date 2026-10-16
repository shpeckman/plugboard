# src/plugboard/context.cr
class Plugboard::Context
  include Disposable

  getter app    : App
  getter parent : Context?

  def initialize(@app : App, @parent : Context? = nil)
    @held     = [] of Disposable?
    @holes    = 0
    @disposed = false
  end

  def disposed? : Bool
    @disposed
  end

  def nest : Context
    @app.assert_loop
    own(Context.new(@app, self))
  end

  def plugin(type : P.class, *args, **options) : P forall P
    @app.assert_loop
    child = nest
    begin
      instance = type.new(child, *args, **options)
      instance.setup
      instance
    rescue error
      begin
        child.dispose
      rescue failure
        raise Fault.new(error, failure)
      end
      raise error
    end
  end

  def effect(&setup : -> (-> Nil)) : Disposable
    @app.assert_loop
    own(Effect.new(self, setup.call))
  end

  def session(&setup : -> (-> Nil)) : Disposable
    @app.assert_loop
    session = own(Session.new(self, setup))
    @app.attach(session) unless @disposed
    session
  end

  def on(type : T.class, &block : T -> Nil) : Disposable forall T
    @app.assert_loop
    topic = @app.bus.topic(type)
    topic.listen(block)
    own(Effect.new(self, -> { topic.unlisten(block) }))
  end

  def on(topic : Topic(T), &block : T -> Nil) : Disposable forall T
    @app.assert_loop
    topic.listen(block)
    own(Effect.new(self, -> { topic.unlisten(block) }))
  end

  def handle(type : T.class, &block : T -> Bool) : Disposable forall T
    @app.assert_loop
    topic = @app.bus.topic(type)
    topic.handle(block)
    own(Effect.new(self, -> { topic.unhandle(block) }))
  end

  def handle(topic : Topic(T), &block : T -> Bool) : Disposable forall T
    @app.assert_loop
    topic.handle(block)
    own(Effect.new(self, -> { topic.unhandle(block) }))
  end

  def intercept(type : T.class, &block : T, Proc(T, Nil) -> Nil) : Disposable forall T
    @app.assert_loop
    topic = @app.bus.topic(type)
    topic.intercept(block)
    own(Effect.new(self, -> { topic.unintercept(block) }))
  end

  def intercept(&block : Event, Proc(Event, Nil) -> Nil) : Disposable
    @app.assert_loop
    gate = @app.bus.gate
    gate.add(block)
    own(Effect.new(self, -> { gate.remove(block) }))
  end

  def after(span : Time::Span, &block : -> Nil) : Timer
    @app.assert_loop
    own(@app.timers.add(self, span, nil, block))
  end

  def every(span : Time::Span, &block : -> Nil) : Timer
    @app.assert_loop
    own(@app.timers.add(self, span, span, block))
  end

  def emit(event) : Bool
    @app.emit(event)
  end

  def post(event) : Nil
    @app.post(event)
  end

  def async(work : Proc(T), &done : T -> Nil) : Disposable forall T
    async(->(_token : Token) { work.call }, &done)
  end

  def async(work : Proc(Token, T), &done : T -> Nil) : Disposable forall T
    @app.assert_loop
    live  = true
    token = Token.new
    lease = own(Effect.new(self, -> { live = false; token.cancel; nil }))
    app = @app
    app.workers.spawn(name: "plugboard.async") do
      begin
        value = work.call(token)
        app.enqueue(-> {
          if live
            lease.dispose
            done.call(value)
          end
          nil
        })
      rescue error
        app.enqueue(-> {
          if live
            lease.dispose
            raise error
          end
          nil
        })
      end
    end
    lease
  end

  def buffer : Bytewire
    @app.buffer
  end

  def scratch : Bytewire
    @app.scratch
  end

  def flush(wait : Bool = false) : Nil
    @app.flush(wait)
  end

  def invalidate : Nil
    @app.invalidate
  end

  def own(item : T) : T forall T
    @app.assert_loop
    if @disposed
      item.dispose
    else
      item.slot = @held.size
      @held << item
    end
    item
  end

  def disown(item : Disposable) : Nil
    @app.assert_loop
    return if @disposed

    index = item.slot
    return unless index >= 0 && @held[index]?.same?(item)

    @held[index] = nil
    item.slot = -1
    @holes += 1
    compact if @holes * 2 > @held.size
  end

  def dispose : Nil
    return if @disposed
    @app.assert_loop
    @disposed = true
    failure   = nil.as(Exception?)
    until @held.empty?
      item = @held.pop || next
      item.slot = -1
      begin
        item.dispose
      rescue error
        failure ||= error
      end
    end
    @holes = 0
    @parent.try(&.disown(self))
    raise failure if failure
  end

  private def compact : Nil
    kept = 0
    @held.each do |entry|
      next unless entry
      entry.slot = kept
      @held[kept] = entry
      kept += 1
    end
    @held.truncate(0, kept)
    @holes = 0
  end
end
