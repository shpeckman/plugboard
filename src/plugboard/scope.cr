# src/plugboard/scope.cr
module Plugboard::Scope
  abstract def scope : Context

  def nest : Context
    owner = scope
    owner.app.assert_loop
    owner.own(Context.new(owner.app, owner))
  end

  def plugin(type : P.class, *args, **options) : P forall P
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

  def defer(&undo : -> Nil) : Disposable
    owner = scope
    owner.own(Effect.new(owner, undo))
  end

  def effect(&setup : -> (-> Nil)) : Disposable
    owner = scope
    owner.app.assert_loop
    owner.own(Effect.new(owner, setup.call))
  end

  def while_running(&setup : -> (-> Nil)) : Disposable
    owner = scope
    app   = owner.app
    app.assert_loop
    run = owner.own(RunScope.new(owner, setup))
    app.attach(run) unless owner.disposed?
    run
  end

  def on(type : T.class, &block : T -> Nil) : Disposable forall T
    on(scope.app.bus.topic(type), &block)
  end

  def on(topic : Topic(T), &block : T -> Nil) : Disposable forall T
    scope.app.assert_loop
    topic.listen(block)
    defer { topic.unlisten(block) }
  end

  def handle(type : T.class, &block : T -> Bool) : Disposable forall T
    handle(scope.app.bus.topic(type), &block)
  end

  def handle(topic : Topic(T), &block : T -> Bool) : Disposable forall T
    scope.app.assert_loop
    topic.handle(block)
    defer { topic.unhandle(block) }
  end

  def observe(type : T.class, &block : T, Bool -> Nil) : Disposable forall T
    observe(scope.app.bus.topic(type), &block)
  end

  def observe(topic : Topic(T), &block : T, Bool -> Nil) : Disposable forall T
    scope.app.assert_loop
    topic.observe(block)
    defer { topic.unobserve(block) }
  end

  def intercept(type : T.class, &block : T, Proc(T, Nil) -> Nil) : Disposable forall T
    scope.app.assert_loop
    topic = scope.app.bus.topic(type)
    topic.intercept(block)
    defer { topic.unintercept(block) }
  end

  def intercept(&block : Event, Proc(Event, Nil) -> Nil) : Disposable
    scope.app.assert_loop
    gate = scope.app.bus.gate
    gate.add(block)
    defer { gate.remove(block) }
  end

  def after(span : Time::Span, &block : -> Nil) : Timer
    owner = scope
    owner.app.assert_loop
    owner.own(owner.app.timers.add(owner, span, nil, block))
  end

  def every(span : Time::Span, &block : -> Nil) : Timer
    owner = scope
    owner.app.assert_loop
    owner.own(owner.app.timers.add(owner, span, span, block))
  end

  def async(work : Proc(T), &done : T -> Nil) : Disposable forall T
    async(->(_token : Token) { work.call }, &done)
  end

  def async(work : Proc(Token, T), &done : T -> Nil) : Disposable forall T
    owner = scope
    app   = owner.app
    job   = owner.own(Job.new(owner))
    app.dispatch(job) do |token|
      value = work.call(token)
      app.enqueue(-> { job.finish { done.call(value) }; nil })
    end
    job
  end

  def async(&work : Token -> Nil) : Disposable
    owner = scope
    app   = owner.app
    job   = owner.own(Job.new(owner))
    app.dispatch(job) do |token|
      work.call(token)
      app.enqueue(-> { job.finish { }; nil })
    end
    job
  end

  def hold_render : Disposable
    app = scope.app
    app.hold_renders
    defer { app.release_renders }
  end

  def now : Time::Instant
    scope.app.clock.now
  end

  def emit(event) : Bool
    scope.app.emit(event)
  end

  def post(event) : Nil
    scope.app.post(event)
  end

  def invalidate : Nil
    scope.app.invalidate
  end
end
