# spec/plugboard_spec.cr
require "./spec_helper"

struct Note
  getter value : Int32

  def initialize(@value : Int32)
  end
end

struct Answer
  include Plugboard::Quiet
end

Plugboard.events Note, Answer

class Doubler < Plugboard::Plugin
  def setup : Nil
    ctx.intercept(Note) { |note, nxt| nxt.call(Note.new(note.value * 2)) }
  end
end

class Collector < Plugboard::Plugin
  getter values = [] of Int32

  def initialize(ctx : Plugboard::Context, @offset : Int32 = 0)
    super(ctx)
  end

  def setup : Nil
    ctx.on(Note) { |note| @values << note.value + @offset }
  end
end

class Suite < Plugboard::Plugin
  getter! collector : Collector

  def setup : Nil
    ctx.plugin(Doubler)
    @collector = ctx.plugin(Collector, offset: 1)
  end
end

class Journal < Plugboard::Plugin
  getter lines = [] of String

  def setup : Nil
    ctx.while_running do
      @lines << "start"
      -> { @lines << "stop"; nil }
    end
  end
end

class Breaker < Plugboard::Plugin
  def setup : Nil
    ctx.effect { -> { undo } }
    raise "setup failed"
  end

  private def undo : Nil
    raise "undo failed"
  end
end

class Dock < Plugboard::Plugin
end

class Banner
  getter text : String

  def initialize(@text : String)
  end
end

Plugboard.service journal : Journal
Plugboard.slot dock : Dock
Plugboard.slot banner : Banner

module Plugboard::Scope
  def tally(into : Array(String), label : String) : Plugboard::Disposable
    into << "+#{label}"
    defer { into << "-#{label}"; nil }
  end
end

private def bare : Plugboard::App
  Plugboard::App.new
end

private def flop : Int32
  raise "work failed"
end

private def cycle(app : Plugboard::App, duration : Time::Span = 60.milliseconds) : Nil
  spawn app.run
  sleep duration
  app.stop
  sleep 40.milliseconds
end

describe Plugboard::Context do
  it "removes a plugin's registrations when it is disposed" do
    app = bare
    collector = app.plugin(Collector)
    app.emit(Note.new(1))
    collector.dispose
    app.emit(Note.new(2))
    collector.values.should eq [1]
    collector.ctx.disposed?.should be_true
  end

  it "disposes child plugins with their parent" do
    app = bare
    suite = app.plugin(Suite)
    app.emit(Note.new(3))
    suite.dispose
    app.emit(Note.new(4))
    suite.collector.values.should eq [7]
    seen = [] of Int32
    app.on(Note) { |note| seen << note.value }
    app.emit(Note.new(5))
    seen.should eq [5]
  end

  it "undoes effects in reverse order" do
    app = bare
    order = [] of Int32
    scope = app.nest
    scope.effect { -> { order << 1; nil } }
    scope.effect { -> { order << 2; nil } }
    inner = scope.nest
    inner.effect { -> { order << 3; nil } }
    scope.effect { -> { order << 4; nil } }
    scope.dispose
    order.should eq [4, 3, 2, 1]
  end

  it "releases a single effect without touching the rest" do
    app = bare
    seen = [] of Int32
    first = app.on(Note) { |note| seen << note.value }
    second = app.on(Note) { |note| seen << note.value * 10 }
    first.dispose
    app.emit(Note.new(2))
    seen.should eq [20]
    second.dispose
    app.emit(Note.new(3))
    seen.should eq [20]
  end

  it "releases one of many held items without touching the rest" do
    app = bare
    scope = app.nest
    disposed = 0
    effects = Array.new(10_000) { scope.effect { -> { disposed += 1; nil } } }
    effects[5_000].dispose
    disposed.should eq 1
    effects[4_999].held_index.should be >= 0
    effects[5_001].held_index.should be >= 0
    effects[5_000].held_index.should eq -1
    scope.dispose
    disposed.should eq 10_000
  end

  it "keeps reverse teardown order after items in the middle are released" do
    app = bare
    scope = app.nest
    order = [] of Int32
    held = (1..8).map { |index| scope.effect { -> { order << index; nil } } }
    held[1].dispose
    held[2].dispose
    held[4].dispose
    held[5].dispose
    held[6].dispose
    order.clear
    scope.dispose
    order.should eq [8, 4, 1]
  end

  it "keeps dispatching when a listener disposes itself" do
    app = bare
    seen = [] of String
    scope = app.nest
    scope.on(Note) do
      seen << "once"
      scope.dispose
    end
    app.on(Note) { seen << "always" }
    app.emit(Note.new(1))
    app.emit(Note.new(2))
    seen.should eq ["once", "always", "always"]
  end

  it "runs interceptors in order and lets them swallow events" do
    app = bare
    seen = [] of Int32
    app.plugin(Doubler)
    gate = app.intercept(Note) { |note, nxt| nxt.call(note) if note.value < 10 }
    app.on(Note) { |note| seen << note.value }
    app.emit(Note.new(2))
    app.emit(Note.new(7))
    gate.dispose
    app.emit(Note.new(7))
    seen.should eq [4, 14]
  end

  it "offers events to handlers until one takes them" do
    app = bare
    taken = [] of String
    app.handle(Note) do |note|
      taken << "first" if note.value.even?
      note.value.even?
    end
    app.handle(Note) do |note|
      taken << "second"
      true
    end
    app.handle(Note) do |note|
      taken << "third"
      true
    end
    app.emit(Note.new(2))
    app.emit(Note.new(3))
    taken.should eq ["first", "second"]
  end

  it "passes every emitted event through wildcard interceptors" do
    app = bare
    kinds = [] of String
    seen = [] of Int32
    app.on(Note) { |note| seen << note.value }
    capture = app.intercept do |event, nxt|
      kinds << event.class.name
      nxt.call(event) unless event.is_a?(Note) && event.value == 0
    end
    app.emit(Note.new(0))
    app.emit(Note.new(1))
    app.emit(Answer.new)
    capture.dispose
    app.emit(Note.new(0))
    kinds.should eq ["Note", "Note", "Answer"]
    seen.should eq [1, 0]
  end

  it "cancels timers with their scope" do
    app = bare
    fired = [] of String
    scope = app.nest
    scope.after(20.milliseconds) { fired << "scoped" }
    app.after(20.milliseconds) { fired << "root" }
    scope.dispose
    cycle(app)
    fired.should eq ["root"]
  end

  it "reports a disposal failure alongside the error that caused it" do
    app = bare
    fault = expect_raises(Plugboard::Fault) { app.plugin(Breaker) }
    fault.primary.message.should eq "setup failed"
    fault.secondary.message.should eq "undo failed"
    fault.cause.try(&.message).should eq "setup failed"
  end
end

describe Plugboard::Topic do
  it "owns a listener on a standalone topic" do
    app = bare
    topic = Plugboard::Topic(Int32).new
    seen = [] of Int32
    scope = app.nest
    scope.on(topic) { |value| seen << value }
    topic.emit(1)
    scope.dispose
    topic.emit(2)
    seen.should eq [1]
    topic.empty?.should be_true
  end

  it "owns a handler on a standalone topic" do
    app = bare
    topic = Plugboard::Topic(Int32).new
    taken = [] of Int32
    lease = app.handle(topic) do |value|
      taken << value
      value.even?
    end
    topic.emit(2).should be_true
    topic.emit(3).should be_false
    lease.dispose
    topic.emit(4).should be_false
    taken.should eq [2, 3]
    topic.size.should eq 0
  end

  it "disposes a topic subscription made on a disposed scope" do
    app = bare
    topic = Plugboard::Topic(Int32).new
    scope = app.nest
    scope.dispose
    seen = 0
    scope.on(topic) { seen += 1 }
    topic.emit(1)
    seen.should eq 0
    topic.empty?.should be_true
  end

  it "removes one registration of a proc registered twice" do
    topic = Plugboard::Topic(Int32).new
    seen = 0
    listener = ->(value : Int32) { seen += value; nil }
    topic.listen(listener)
    topic.listen(listener)
    topic.unlisten(listener)
    topic.emit(1)
    seen.should eq 1
    topic.size.should eq 1
  end

  it "counts listeners and handlers but not interceptors" do
    topic = Plugboard::Topic(Int32).new
    topic.empty?.should be_true
    topic.intercept(->(value : Int32, nxt : Proc(Int32, Nil)) { nxt.call(value) })
    topic.empty?.should be_true
    topic.size.should eq 0
    topic.listen(->(value : Int32) { })
    topic.handle(->(value : Int32) { false })
    topic.size.should eq 2
    topic.empty?.should be_false
  end
end

describe Plugboard::Bus do
  it "reports whether a handler took the event" do
    app = bare
    app.emit(Note.new(1)).should be_false
    app.on(Note) { }
    app.emit(Note.new(1)).should be_false
    gate = app.handle(Note) { |note| note.value.even? }
    app.emit(Note.new(1)).should be_false
    app.emit(Note.new(2)).should be_true
    gate.dispose
    app.emit(Note.new(2)).should be_false
  end

  it "reports consumption through an interceptor chain" do
    app = bare
    app.handle(Note) { true }
    app.emit(Note.new(1)).should be_true
    swallow = app.intercept(Note) { |note, nxt| nxt.call(note) if note.value > 0 }
    app.emit(Note.new(1)).should be_true
    app.emit(Note.new(0)).should be_false
    swallow.dispose
    app.emit(Note.new(0)).should be_true
  end
end

describe Plugboard::App do
  it "starts run scopes with the run loop and stops them in reverse" do
    app = bare
    lines = [] of String
    app.while_running do
      lines << "a on"
      -> { lines << "a off"; nil }
    end
    late = app.while_running do
      lines << "b on"
      -> { lines << "b off"; nil }
    end
    lines.should be_empty
    cycle(app)
    lines.should eq ["a on", "b on", "b off", "a off"]
    late.dispose
    cycle(app)
    lines.should eq ["a on", "b on", "b off", "a off", "a on", "a off"]
  end

  it "starts a run scope immediately when added to a running app" do
    app = bare
    lines = [] of String
    app.after(10.milliseconds) do
      mode = app.while_running do
        lines << "on"
        -> { lines << "off"; nil }
      end
      lines << "added"
      mode.dispose
      lines << "disposed"
    end
    cycle(app)
    lines.should eq ["on", "added", "off", "disposed"]
  end

  it "ends every pass with a flush and the loop with a final one" do
    app = bare
    trail = [] of String
    app.on(Note) { |note| trail << "n#{note.value}" }
    app.on(Plugboard::RenderEvent) { trail << "render" }
    app.on(Plugboard::StoppedEvent) { trail << "stopped" }
    app.on(Plugboard::FlushEvent) { |flush| trail << (flush.final? ? "final" : "flush") }
    app.post(Note.new(1))
    app.post(Note.new(2))
    cycle(app)
    trail.first(5).should eq ["flush", "n1", "n2", "render", "flush"]
    trail.last(2).should eq ["stopped", "final"]
    trail.count("final").should eq 1
  end

  it "installs services on first use and clears them on disposal" do
    app = bare
    app.journal?.should be_nil
    journal = app.journal
    app.journal.should be(journal)
    app.root.journal.should be(journal)
    cycle(app)
    journal.lines.should eq ["start", "stop"]
    journal.dispose
    app.journal?.should be_nil
  end

  it "renders once per batch and only for events that are not replies" do
    app = bare
    renders = 0
    stops = 0
    app.on(Plugboard::RenderEvent) { renders += 1 }
    app.on(Plugboard::StoppedEvent) { stops += 1 }
    app.post(Answer.new)
    cycle(app)
    renders.should eq 0
    app.post(Note.new(1))
    app.post(Note.new(2))
    cycle(app)
    renders.should eq 1
    stops.should eq 2
  end

  it "tracks whether a render is pending" do
    app = bare
    app.dirty?.should be_false
    app.emit(Answer.new)
    app.dirty?.should be_false
    app.emit(Note.new(1))
    app.dirty?.should be_true
    cycle(app)
    app.dirty?.should be_false
    app.invalidate
    app.dirty?.should be_true
  end

  it "queues more events than a bounded channel would hold before the loop starts" do
    app = bare
    seen = [] of Int32
    app.on(Note) { |note| seen << note.value }
    200.times { |index| app.post(Note.new(index)) }
    app.pending.should eq 200
    cycle(app)
    seen.size.should eq 200
    seen.first.should eq 0
    seen.last.should eq 199
  end

  it "never blocks in stop, however much is queued with no loop running" do
    app = bare
    app.on(Note) { }
    5_000.times { |index| app.post(Note.new(index)) }
    elapsed = Time.measure { app.stop }
    elapsed.should be < 100.milliseconds
    app.pending.should eq 5_000
    app.running?.should be_false
  end

  it "leaves the loop promptly when stopped while loaded" do
    app = bare
    seen = 0
    app.on(Note) { seen += 1 }
    10_000.times { |index| app.post(Note.new(index)) }
    spawn app.run
    sleep 10.milliseconds
    app.stop
    sleep 60.milliseconds
    app.running?.should be_false
    seen.should be > 0
  end

  it "keeps the loop alive while fire-and-forget work occupies a worker" do
    app = bare
    release = Atomic(Bool).new(false)
    value = 0
    app.on(Note) { |note| value = note.value }
    app.after(20.milliseconds) { release.set(true) }
    app.after(5.milliseconds) do
      app.async do
        limit = Time.instant + 500.milliseconds
        while !release.get && Time.instant < limit
        end
        app.post(Note.new(release.get ? 1 : 0))
      end
    end
    cycle(app, 200.milliseconds)
    value.should eq 1
  end

  it "routes a fire-and-forget failure through the error policy" do
    app = bare
    errors = [] of String
    app.on(Plugboard::ErrorEvent) do |event|
      errors << (event.error.message || "")
      event.handle
    end
    app.after(5.milliseconds) { app.async { flop } }
    cycle(app)
    errors.should eq ["work failed"]
  end

  it "releases a finished fire-and-forget lease and cancels a disposed one" do
    app = bare
    finished = nil.as(Plugboard::Disposable?)
    cancelled = Atomic(Bool).new(false)
    app.after(5.milliseconds) do
      finished = app.async { }
      lease = app.async do |token|
        limit = Time.instant + 500.milliseconds
        while !token.cancelled? && Time.instant < limit
        end
        cancelled.set(token.cancelled?)
      end
      app.after(10.milliseconds) { lease.dispose }
    end
    cycle(app, 200.milliseconds)
    finished.as(Plugboard::Job).live?.should be_false
    cancelled.get.should be_true
  end

  it "cancels a timer from another fiber" do
    app = bare
    fired = 0
    timer = app.every(10.milliseconds) { fired += 1 }
    spawn app.run
    sleep 45.milliseconds
    done = Channel(Nil).new
    spawn do
      timer.cancel
      done.send(nil)
    end
    done.receive
    timer.cancelled?.should be_true
    seen = fired
    seen.should be > 0
    sleep 60.milliseconds
    app.stop
    sleep 40.milliseconds
    fired.should eq seen
  end

  {% if flag?(:plugboard_assert) %}
    it "rejects a loop-only call from another fiber while the loop runs" do
      app = bare
      caught = Channel(String?).new(1)
      app.after(10.milliseconds) do
        spawn(name: "intruder") do
          app.emit(Note.new(1))
          caught.send(nil)
        rescue error
          caught.send(error.message)
        end
      end
      spawn app.run
      message = caught.receive
      app.stop
      sleep 40.milliseconds
      message.should eq "plugboard: a loop-only method was called from intruder"
    end
  {% end %}

  it "surfaces the original error when an error listener raises" do
    app = bare
    app.on(Plugboard::ErrorEvent) { raise "listener failed" }
    app.after(10.milliseconds) { raise "original" }
    fault = expect_raises(Plugboard::Fault) { app.run }
    fault.primary.message.should eq "original"
    fault.secondary.message.should eq "listener failed"
    fault.cause.try(&.message).should eq "original"
  end

  it "keeps the loop running when an error listener handles the error" do
    app = bare
    errors = [] of String
    seen = 0
    app.on(Plugboard::ErrorEvent) do |event|
      errors << (event.error.message || "")
      event.handle
    end
    app.on(Note) { seen += 1 }
    app.after(10.milliseconds) { raise "recovered" }
    app.after(30.milliseconds) { app.emit(Note.new(1)) }
    cycle(app)
    errors.should eq ["recovered"]
    seen.should eq 1
  end

  it "delivers a typed async result on the loop" do
    app = bare
    seen = 0
    onloop = nil.as(Bool?)
    app.after(5.milliseconds) do
      app.async(-> { 21 }) do |value|
        seen = value * 2
        onloop = app.on_loop?
      end
    end
    cycle(app)
    seen.should eq 42
    onloop.should be_true
  end

  it "drops a typed async result when the lease is disposed first" do
    app = bare
    seen = 0
    app.after(5.milliseconds) do
      app.async(-> { 1 }) { |value| seen = value }.dispose
    end
    cycle(app)
    seen.should eq 0
  end

  it "drops a typed async result when the owning scope is disposed" do
    app = bare
    seen = 0
    scope = app.nest
    app.after(5.milliseconds) do
      scope.async(-> { 1 }) { |value| seen = value }
      scope.dispose
    end
    cycle(app)
    seen.should eq 0
  end

  it "routes a typed async failure through the error policy" do
    app = bare
    errors = [] of String
    notes = 0
    app.on(Plugboard::ErrorEvent) do |event|
      errors << (event.error.message || "")
      event.handle
    end
    app.on(Note) { notes += 1 }
    work = Proc(Int32).new { flop }
    app.after(5.milliseconds) { app.async(work) { |value| notes += value } }
    app.after(40.milliseconds) { app.emit(Note.new(1)) }
    cycle(app, 80.milliseconds)
    errors.should eq ["work failed"]
    notes.should eq 1
  end

  it "raises out of run when a typed async failure goes unhandled" do
    app = bare
    work = Proc(Int32).new { flop }
    app.after(5.milliseconds) { app.async(work) { |value| } }
    expect_raises(Exception, "work failed") { app.run }
  end

  it "runs typed async work off the loop" do
    app = bare
    release = Atomic(Bool).new(false)
    value = 0
    work = -> {
      limit = Time.instant + 500.milliseconds
      while !release.get && Time.instant < limit
      end
      release.get ? 1 : 0
    }
    app.after(5.milliseconds) { app.async(work) { |result| value = result } }
    app.after(40.milliseconds) { release.set(true) }
    cycle(app, 200.milliseconds)
    value.should eq 1
  end

  it "builds no worker context until async needs one" do
    apps = Array.new(512) { Plugboard::App.new }
    apps.size.should eq 512
    apps.last.pending.should eq 0
  end

  it "takes a worker context from the caller" do
    workers = Fiber::ExecutionContext::Concurrent.new("spec.workers")
    app = Plugboard::App.new(workers: workers)
    app.workers.should be(workers)
  end

  it "cancels the token of a disposed async lease" do
    app = bare
    cancelled = Atomic(Bool).new(false)
    called = false
    work = ->(token : Plugboard::Token) {
      limit = Time.instant + 500.milliseconds
      while !token.cancelled? && Time.instant < limit
      end
      cancelled.set(token.cancelled?)
      1
    }
    app.after(5.milliseconds) do
      lease = app.async(work) { |_value| called = true }
      app.after(10.milliseconds) { lease.dispose }
    end
    cycle(app, 200.milliseconds)
    cancelled.get.should be_true
    called.should be_false
  end

  it "renders when woken dirty from another fiber" do
    app = bare
    renders = 0
    app.on(Plugboard::RenderEvent) { renders += 1 }
    spawn app.run
    sleep 10.milliseconds
    done = Channel(Nil).new
    spawn do
      app.wake(dirty: true)
      done.send(nil)
    end
    done.receive
    sleep 30.milliseconds
    app.stop
    sleep 40.milliseconds
    renders.should eq 1
  end

  it "holds renders until the last hold is released" do
    app = bare
    trail = [] of String
    app.on(Plugboard::RenderEvent) { trail << "render" }
    app.on(Plugboard::FlushEvent) { |flush| trail << "drawn" if flush.rendered? }
    first = nil.as(Plugboard::Disposable?)
    second = nil.as(Plugboard::Disposable?)
    app.after(5.milliseconds) do
      first = app.hold_render
      second = app.hold_render
      app.emit(Note.new(1))
    end
    app.after(20.milliseconds) do
      trail << "one"
      first.try(&.dispose)
    end
    app.after(35.milliseconds) do
      trail << "two"
      app.renders_held?.should be_true
      second.try(&.dispose)
    end
    cycle(app, 80.milliseconds)
    trail.should eq ["one", "two", "render", "drawn"]
    app.renders_held?.should be_false
  end

  it "renders when a hold is released by an action posted from another fiber" do
    app = bare
    renders = 0
    app.on(Plugboard::RenderEvent) { renders += 1 }
    app.after(5.milliseconds) do
      hold = app.hold_render
      app.invalidate
      posted = Channel(Nil).new
      spawn do
        app.enqueue(-> { hold.dispose; nil })
        posted.send(nil)
      end
      posted.receive
    end
    cycle(app, 60.milliseconds)
    renders.should eq 1
    app.running?.should be_false
  end

  it "disposes its root scope and starts over with a fresh one" do
    app = bare
    seen = [] of Int32
    collector = app.plugin(Collector)
    journal = app.journal
    root = app.root
    app.dispose
    collector.ctx.disposed?.should be_true
    root.disposed?.should be_true
    app.journal?.should be_nil
    app.root.should_not be(root)
    app.on(Note) { |note| seen << note.value }
    app.emit(Note.new(1))
    seen.should eq [1]
    collector.values.should be_empty
    journal.ctx.disposed?.should be_true
  end
end

describe Plugboard::Scope do
  it "reaches an extension from the app and from any scope" do
    app = bare
    trail = [] of String
    app.tally(trail, "root")
    scope = app.nest
    scope.tally(trail, "inner")
    scope.dispose
    app.dispose
    trail.should eq ["+root", "+inner", "-inner", "-root"]
  end

  it "runs a deferred undo when its scope is disposed" do
    app = bare
    trail = [] of String
    scope = app.nest
    scope.defer { trail << "undone" }
    trail.should be_empty
    scope.dispose
    trail.should eq ["undone"]
  end

  it "attaches a plugin slot and clears it when the plugin is disposed" do
    app = bare
    app.dock?.should be_nil
    expect_raises(Exception, "plugboard: no Dock is attached as dock") { app.dock }
    dock = app.plugin(Dock)
    app.dock = dock
    app.dock.should be(dock)
    app.nest.dock.should be(dock)
    dock.dispose
    app.dock?.should be_nil
  end

  it "attaches a plain slot until it is replaced" do
    app = bare
    app.banner = Banner.new("first")
    app.root.banner.text.should eq "first"
    app.banner = nil
    app.root.banner?.should be_nil
  end

  it "keeps a replaced plugin slot when the old plugin goes away" do
    app = bare
    old = app.plugin(Dock)
    app.dock = old
    fresh = app.plugin(Dock)
    app.dock = fresh
    old.dispose
    app.dock.should be(fresh)
  end

  it "tells observers whether a handler took the event" do
    app = bare
    trail = [] of String
    app.observe(Note) { |note, taken| trail << "#{note.value}:#{taken}" }
    app.handle(Note) { |note| trail << "handler"; note.value.even? }
    app.emit(Note.new(1))
    app.emit(Note.new(2))
    trail.should eq ["handler", "1:false", "handler", "2:true"]
  end

  it "marks a flush as rendered only on a pass that rendered" do
    app = bare
    flushes = [] of Bool
    app.on(Plugboard::FlushEvent) { |flush| flushes << flush.rendered? unless flush.final? }
    app.after(5.milliseconds) { app.emit(Note.new(1)) }
    app.after(20.milliseconds) { app.emit(Answer.new) }
    cycle(app)
    flushes.first(2).should eq [false, true]
    flushes.count(true).should eq 1
  end
end
