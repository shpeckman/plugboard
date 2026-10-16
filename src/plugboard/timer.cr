# src/plugboard/timer.cr
class Plugboard::Timer
  include Disposable

  getter deadline     : Time::Instant
  getter serial       : UInt64
  property heap_index : Int32

  @action : (-> Nil)?
  @period : Time::Span?

  def initialize(@owner : Context, @timers : Timers, @deadline : Time::Instant,
                 @period : Time::Span?, @action : (-> Nil)?, @serial : UInt64)
    @cancelled  = Atomic(Bool).new(false)
    @heap_index = -1
  end

  def cancel : Nil
    return if @cancelled.swap(true)
    @action = nil
    app     = @owner.app
    if app.on_loop?
      detach
    else
      app.enqueue(-> { detach })
    end
  end

  def dispose : Nil
    cancel
  end

  def cancelled? : Bool
    @cancelled.get
  end

  def fire : Nil
    action = @action || return
    cancel unless @period
    action.call
  end

  def advance(now : Time::Instant) : Bool
    period = @period || return false
    return false if cancelled?
    following = @deadline + period
    @deadline = following > now ? following : now + period
    true
  end

  @[AlwaysInline]
  def before?(other : Timer) : Bool
    @deadline < other.deadline || (@deadline == other.deadline && @serial < other.serial)
  end

  private def detach : Nil
    @timers.remove(self)
    @owner.disown(self)
  end
end

class Plugboard::Timers
  def initialize
    @heap   = [] of Timer
    @due    = [] of Timer
    @serial = 0_u64
  end

  def add(owner : Context, span : Time::Span, period : Time::Span?, action : -> Nil) : Timer
    timer = Timer.new(owner, self, Time.instant + span, period, action, @serial &+= 1)
    insert(timer)
    timer
  end

  def remove(timer : Timer) : Nil
    slot = timer.heap_index
    return if slot < 0
    timer.heap_index = -1
    last = @heap.pop
    return if last.same?(timer)
    place(last, slot)
    sink(rise(slot))
  end

  def delay(now : Time::Instant) : Time::Span?
    first = @heap.first? || return nil
    first.deadline > now ? first.deadline - now : Time::Span.zero
  end

  def each_due(now : Time::Instant, & : Timer -> Nil) : Nil
    return if @heap.empty? || @heap.unsafe_fetch(0).deadline > now
    batch = @due
    while (first = @heap.first?) && first.deadline <= now
      remove(first)
      batch << first
    end
    begin
      index = 0
      while index < batch.size
        timer = batch.unsafe_fetch(index)
        index += 1
        next if timer.cancelled?
        yield timer
        insert(timer) if timer.advance(now)
      end
    ensure
      batch.clear
    end
  end

  private def insert(timer : Timer) : Nil
    @heap << timer
    timer.heap_index = @heap.size - 1
    rise(timer.heap_index)
  end

  @[AlwaysInline]
  private def place(timer : Timer, slot : Int32) : Nil
    @heap.unsafe_put(slot, timer)
    timer.heap_index = slot
  end

  private def rise(slot : Int32) : Int32
    timer = @heap.unsafe_fetch(slot)
    while slot > 0
      above = (slot - 1) // 2
      other = @heap.unsafe_fetch(above)
      break unless timer.before?(other)
      place(other, slot)
      slot = above
    end
    place(timer, slot)
    slot
  end

  private def sink(slot : Int32) : Int32
    timer = @heap.unsafe_fetch(slot)
    count = @heap.size
    loop do
      child = slot * 2 + 1
      break if child >= count
      child += 1 if child + 1 < count && @heap.unsafe_fetch(child + 1).before?(@heap.unsafe_fetch(child))
      other = @heap.unsafe_fetch(child)
      break unless other.before?(timer)
      place(other, slot)
      slot = child
    end
    place(timer, slot)
    slot
  end
end
