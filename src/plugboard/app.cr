# src/plugboard/app.cr
class Plugboard::App
  include Scope

  getter bus    : Bus
  getter timers : Timers
  getter clock  : Clock

  @root    : Context?
  @owner   : Fiber?
  @workers : Fiber::ExecutionContext?
  @wake    : Proc(Nil)

  def initialize(*, workers : Fiber::ExecutionContext? = nil, @clock : Clock = Clock::SYSTEM)
    @bus       = Bus.new
    @timers    = Timers.new(@clock)
    @workers   = workers
    @local     = Deque(Event | Action).new
    @shared    = Deque(Event | Action).new
    @mutex     = Sync::Mutex.new
    @bell      = Channel(Nil).new(1)
    @ringing   = false
    @runs      = [] of RunScope
    @running   = Atomic(Bool).new(false)
    @stopping  = Atomic(Bool).new(false)
    @dirty     = Atomic(Bool).new(false)
    @holds     = 0
    @reporting = false
    @root      = nil
    @owner     = nil
    @jobs      = Atomic(Int32).new(0)
    @wake      = -> { ring; nil }
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

  def app : App
    self
  end

  def root : Context
    @root ||= Context.new(self)
  end

  def scope : Context
    root
  end

  def emit(event : T) : Bool forall T
    ::Plugboard.registered!(T)
    assert_loop
    @dirty.set(true, :relaxed) unless event.is_a?(Quiet)
    @bus.emit(event)
  end

  def post(event : T) : Nil forall T
    ::Plugboard.registered!(T)
    submit(event)
  end

  def enqueue(action : -> Nil) : Nil
    submit(Action.new(action))
  end

  def wake(dirty : Bool = false) : Nil
    @dirty.set(true) if dirty
    ring
  end

  def dispatch(job : Job, &work : Token -> Nil) : Nil
    assert_loop
    return unless job.live?
    token = job.token
    @jobs.add(1)
    workers.spawn(name: "plugboard.job") do
      begin
        work.call(token)
      rescue error
        enqueue(-> { job.fail(error); nil })
      ensure
        ring if @jobs.sub(1) == 1
      end
    end
  end

  def jobs : Int32
    @jobs.get
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

  def invalidate : Nil
    assert_loop
    @dirty.set(true, :relaxed)
  end

  def dirty? : Bool
    @dirty.get(:relaxed)
  end

  def hold_renders : Nil
    assert_loop
    @holds += 1
  end

  def release_renders : Nil
    assert_loop
    @holds -= 1
    ring if @holds == 0 && dirty?
  end

  def renders_held? : Bool
    @holds > 0
  end

  def run : Nil
    @owner = Fiber.current
    @running.set(true)
    failure = nil.as(Exception?)
    @clock.watch(@wake)
    begin
      start_runs
      flush
      until @stopping.get
        await
        drain
        flush(rendered: render)
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

  def dispose : Nil
    assert_loop
    root = @root || return
    stop if running?
    @root = nil
    root.dispose
  end

  def attach(run : RunScope) : Nil
    @runs << run
    run.start if running?
  end

  def detach(run : RunScope) : Nil
    @runs.delete(run)
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
    toll if wake
  end

  private def ring : Nil
    wake = false
    @mutex.synchronize do
      unless @ringing
        @ringing = true
        wake     = true
      end
    end
    toll if wake
  end

  private def toll : Nil
    select
    when @bell.send(nil)
    else
    end
  end

  private def absorb : Nil
    @mutex.synchronize do
      @ringing = false
      while item = @shared.shift?
        @local.push(item)
      end
    end
  end

  private def start_runs : Nil
    index = 0
    while index < @runs.size
      @runs.unsafe_fetch(index).start
      index += 1
    end
  end

  private def shutdown(failure : Exception?) : Exception?
    @clock.unwatch(@wake)
    @runs.dup.reverse_each do |run|
      begin
        run.stop
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
      flush(final: true)
    rescue error
      failure ||= error
    end
    @owner = nil
    @stopping.set(false)
    failure
  end

  private def await : Nil
    return unless @local.empty?
    if span = @timers.delay(@clock.now)
      if span > Time::Span.zero
        select
        when @bell.receive
        when timeout(@clock.budget(span))
        end
      end
    else
      @bell.receive
    end
    absorb
  end

  private def drain : Nil
    @timers.each_due(@clock.now) { |timer| guard { timer.fire } }
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

  private def render : Bool
    return false if @holds > 0
    return false unless @dirty.swap(false)
    guard { @bus.topic(RenderEvent).emit(RenderEvent.new) }
    true
  end

  private def guard(& : -> Nil) : Nil
    yield
  rescue error
    report(error)
  end

  private def flush(*, final : Bool = false, rendered : Bool = false) : Nil
    @bus.topic(FlushEvent).emit(FlushEvent.new(final: final, rendered: rendered))
  end
end
