# src/plugboard/app.cr
class Plugboard::App
  getter output     : IO
  getter bus        : Bus
  getter timers     : Timers
  property retained : Int32

  getter? async_output : Bool

  @root    : Context?
  @owner   : Fiber?
  @workers : Fiber::ExecutionContext?
  @outbox  : Channel(Bytewire)?
  @writer  : Fiber::ExecutionContext::Isolated?
  @failure : Exception?

  def initialize(@output : IO, *, workers : Fiber::ExecutionContext? = nil, retained : Int32 = 1 << 20,
                 @async_output : Bool = false)
    @bus       = Bus.new
    @timers    = Timers.new
    @workers   = workers
    @local     = Deque(Event | Action).new
    @shared    = Deque(Event | Action).new
    @mutex     = Sync::Mutex.new
    @bell      = Channel(Nil).new(1)
    @ringing   = false
    @sessions  = [] of Session
    @running   = Atomic(Bool).new(false)
    @stopping  = Atomic(Bool).new(false)
    @dirty     = false
    @reporting = false
    @buffer    = Bytewire.new
    @scratch   = Bytewire.new(256)
    @retained  = retained
    @root      = nil
    @owner     = nil
    @spare     = Bytewire.new
    @outbox    = nil
    @writer    = nil
    @lock      = Sync::Mutex.new
    @idle      = Sync::ConditionVariable.new(@lock)
    @writing   = false
    @failure   = nil
  end

  def running? : Bool
    @running.get
  end

  def workers : Fiber::ExecutionContext
    @mutex.synchronize do
      @workers ||= Fiber::ExecutionContext::Parallel.new("plugboard.workers", Fiber::ExecutionContext.default_workers_count)
    end
  end

  def on_loop? : Bool
    owner = @owner
    owner.nil? || Fiber.current.same?(owner)
  end

  def assert_loop : Nil
    {% if flag?(:plugboard_assert) %}
      raise "plugboard: a loop-only method was called from #{Fiber.current.name || "an unnamed fiber"}" unless on_loop?
    {% end %}
  end

  def root : Context
    @root ||= Context.new(self)
  end

  def nest : Context
    root.nest
  end

  def plugin(type : P.class, *args, **options) : P forall P
    root.plugin(type, *args, **options)
  end

  def effect(&setup : -> (-> Nil)) : Disposable
    root.effect(&setup)
  end

  def session(&setup : -> (-> Nil)) : Disposable
    root.session(&setup)
  end

  def on(type : T.class, &block : T -> Nil) : Disposable forall T
    root.on(type, &block)
  end

  def on(topic : Topic(T), &block : T -> Nil) : Disposable forall T
    root.on(topic, &block)
  end

  def handle(type : T.class, &block : T -> Bool) : Disposable forall T
    root.handle(type, &block)
  end

  def handle(topic : Topic(T), &block : T -> Bool) : Disposable forall T
    root.handle(topic, &block)
  end

  def intercept(type : T.class, &block : T, Proc(T, Nil) -> Nil) : Disposable forall T
    root.intercept(type, &block)
  end

  def intercept(&block : Event, Proc(Event, Nil) -> Nil) : Disposable
    root.intercept(&block)
  end

  def after(span : Time::Span, &block : -> Nil) : Timer
    root.after(span, &block)
  end

  def every(span : Time::Span, &block : -> Nil) : Timer
    root.every(span, &block)
  end

  def emit(event) : Bool
    assert_loop
    @dirty = true unless event.is_a?(Quiet)
    @bus.emit(event)
  end

  def post(message : Message) : Nil
    submit(MessageEvent.new(message))
  end

  def post(event : Event) : Nil
    submit(event)
  end

  def enqueue(action : -> Nil) : Nil
    submit(Action.new(action))
  end

  def async(&block : -> Message) : Nil
    workers.spawn(name: "plugboard.async") do
      post(block.call)
    rescue ex
      post(AsyncError.new(ex))
    end
  end

  def async(work : Proc(T), &done : T -> Nil) : Disposable forall T
    root.async(work, &done)
  end

  def async(work : Proc(Token, T), &done : T -> Nil) : Disposable forall T
    root.async(work, &done)
  end

  def pending : Int32
    assert_loop
    waiting = @mutex.synchronize { @shared.size }
    @local.size + waiting
  end

  def report(error : Exception) : Nil
    assert_loop
    raise error if @reporting
    event      = ErrorEvent.new(error)
    @reporting = true
    begin
      @bus.topic(ErrorEvent).emit(event)
    rescue failure
      raise Fault.new(error, failure)
    ensure
      @reporting = false
    end
    raise error unless event.handled?
  end

  def buffer : Bytewire
    assert_loop
    @buffer
  end

  def scratch : Bytewire
    assert_loop
    @scratch.reset
    @scratch
  end

  def flush(wait : Bool = false) : Nil
    assert_loop
    if @async_output
      hand_off
      settle if wait
    else
      write_now
    end
    @buffer.shrink(@retained) if @buffer.empty? && @buffer.capacity > @retained
    @scratch.shrink(@retained) if @scratch.capacity > @retained
  end

  def writing? : Bool
    @async_output && @lock.synchronize { @writing }
  end

  def invalidate : Nil
    @dirty = true
  end

  def dirty? : Bool
    @dirty
  end

  def run : Nil
    @owner = Fiber.current
    @running.set(true)
    failure = nil.as(Exception?)
    begin
      start_sessions
      flush
      until @stopping.get
        await
        drain
        render
        flush
      end
    rescue error
      failure = error
    end
    failure = shutdown(failure)
    raise failure if failure
  end

  def stop : Nil
    return if @stopping.swap(true)
    ring
  end

  def attach(session : Session) : Nil
    @sessions << session
    session.start if running?
  end

  def detach(session : Session) : Nil
    @sessions.delete(session)
  end

  private def submit(item : Event | Action) : Nil
    if Fiber.current.same?(@owner)
      @local.push(item)
      return
    end

    wake = false
    @mutex.synchronize do
      @shared.push(item)
      unless @ringing
        @ringing = true
        wake     = true
      end
    end
    @bell.send(nil) if wake
  end

  private def ring : Nil
    wake = false
    @mutex.synchronize do
      unless @ringing
        @ringing = true
        wake     = true
      end
    end
    @bell.send(nil) if wake
  end

  private def absorb : Nil
    @mutex.synchronize do
      @ringing = false
      while item = @shared.shift?
        @local.push(item)
      end
    end
  end

  private def start_sessions : Nil
    index = 0
    while index < @sessions.size
      @sessions.unsafe_fetch(index).start
      index += 1
    end
  end

  private def shutdown(failure : Exception?) : Exception?
    @sessions.dup.reverse_each do |session|
      begin
        session.stop
      rescue error
        failure ||= error
      end
    end
    @running.set(false)
    begin
      @bus.topic(StoppedEvent).emit(StoppedEvent.new)
    rescue error
      failure ||= error
    end
    begin
      flush(wait: true)
    rescue error
      failure ||= error
    end
    begin
      stop_writer
    rescue error
      failure ||= error
    end
    @owner = nil
    @stopping.set(false)
    failure
  end

  private def await : Nil
    return unless @local.empty?
    if span = @timers.delay(Time.instant)
      if span > Time::Span.zero
        select
        when @bell.receive
        when timeout(span)
        end
      end
    else
      @bell.receive
    end
    absorb
  end

  private def drain : Nil
    @timers.each_due(Time.instant) { |timer| guard { timer.fire } }
    until @stopping.get
      if item = @local.shift?
        guard { route(item) }
      else
        absorb
        break if @local.empty?
      end
    end
    guard { @bus.topic(IdleEvent).emit(IdleEvent.new) }
  end

  private def route(item : Event | Action) : Nil
    case item
    when Action
      item.action.call
    else
      emit(item)
    end
  end

  private def render : Nil
    return unless @dirty
    return if writing?
    @dirty = false
    guard { @bus.topic(RenderEvent).emit(RenderEvent.new) }
  end

  private def guard(& : -> Nil) : Nil
    yield
  rescue error
    report(error)
  end

  private def write_now : Nil
    return if @buffer.empty?
    begin
      @output.write(@buffer.written)
      @output.flush
    ensure
      @buffer.reset
    end
  end

  private def hand_off : Nil
    busy, failure = @lock.synchronize do
      found    = @failure
      @failure = nil
      {@writing, found}
    end
    if failure
      @buffer.reset
      raise failure
    end
    return if busy || @buffer.empty?
    outbox  = writer
    full    = @buffer
    @buffer = @spare
    @spare  = full
    @lock.synchronize { @writing = true }
    outbox.send(full)
  end

  private def settle : Nil
    loop do
      @lock.synchronize do
        while @writing
          @idle.wait
        end
      end
      break if @buffer.empty?
      hand_off
    end
    failure = @lock.synchronize do
      found    = @failure
      @failure = nil
      found
    end
    raise failure if failure
  end

  private def writer : Channel(Bytewire)
    @outbox ||= begin
      outbox  = Channel(Bytewire).new(1)
      @writer = Fiber::ExecutionContext::Isolated.new("plugboard.writer") { pour(outbox) }
      outbox
    end
  end

  private def pour(outbox : Channel(Bytewire)) : Nil
    while full = outbox.receive?
      failure = nil.as(Exception?)
      begin
        @output.write(full.written)
        @output.flush
      rescue error
        failure = error
      end
      full.reset
      full.shrink(@retained) if full.capacity > @retained
      @lock.synchronize do
        @writing = false
        @failure ||= failure
        @idle.broadcast
      end
      ring
    end
  end

  private def stop_writer : Nil
    outbox = @outbox || return
    outbox.close
    @writer.try(&.wait)
    @outbox = nil
    @writer = nil
  end
end
