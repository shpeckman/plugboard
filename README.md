# plugboard

A small application kernel for Crystal: a typed event bus, an event loop with
timers, and scopes that undo everything registered through them. Features are
written as plugins that wire themselves into the bus and are removed cleanly
when disposed.

It is built for programs that react to events, such as terminal applications.
The kernel writes nothing itself: each pass ends with a `FlushEvent`, the point
at which a program sends out whatever it collected.

```crystal
require "plugboard"

struct Greeting
  getter name : String

  def initialize(@name : String)
  end
end

Plugboard.events Greeting

app = Plugboard::App.new
app.on(Greeting) { |event| puts "hello #{event.name}" }
app.post(Greeting.new("world"))
app.after(1.second) { app.stop }
app.run
```

## Contents

- [Installation](#installation)
- [Events](#events)
- [Listening, handling and intercepting](#listening-handling-and-intercepting)
- [Scopes](#scopes)
- [Plugins](#plugins)
- [Services and slots](#services-and-slots)
- [Run scopes](#run-scopes)
- [Timers](#timers)
- [The run loop](#the-run-loop)
- [Flushing](#flushing)
- [Background work](#background-work)
- [Errors](#errors)
- [Fibers and parallelism](#fibers-and-parallelism)
- [API reference](#api-reference)
- [Limits](#limits)
- [Development](#development)

## Installation

Add the shard to `shard.yml` and run `shards install`:

```yaml
dependencies:
  plugboard:
    github: shpeckman/plugboard
```

Crystal 1.21 or newer is required. The shard has no dependencies.

## Events

An event is any struct or class you register with `Plugboard.events`. There is
no base class to inherit from.

```crystal
struct Tick
end

struct Resized
  getter cols : Int32
  getter rows : Int32

  def initialize(@cols : Int32, @rows : Int32)
  end
end

Plugboard.events Tick, Resized
```

Registration happens at compile time. Once the whole program has been read,
plugboard builds the `Plugboard::Event` union from every registered type and
gives each type its own topic on the bus, so dispatch needs no hash lookup and
no casting.

Types are resolved from the top level, so give the full path for a type inside
a module: `Plugboard.events MyApp::Tick`. Emitting or posting a type that was
never registered fails to compile with a message naming the type.

There are two ways to send an event:

| Call              | When it is delivered               | Where it may be called from |
|-------------------|------------------------------------|-----------------------------|
| `app.emit(event)` | Immediately, before `emit` returns | The loop's fiber only       |
| `app.post(event)` | On the loop's next pass            | Any fiber                   |

`emit` returns whether a handler took the event, so a caller can fall back to
its own behaviour when nothing did. `post` returns nothing, since the event has
not been delivered yet.

Include `Plugboard::Quiet` in an event type to mark it as bookkeeping that
changes nothing visible. Emitting any other event marks the app dirty, which
triggers a [render](#the-run-loop).

The rule of thumb: an event is `Quiet` unless a listener could plausibly change
what is on screen. Anything emitted on a timer, a reply to a query, and any
bookkeeping tick belongs in that category.

To mark a type you do not own, such as an event from another shard, reopen it
and include the module. That is one line per type, and it can live anywhere in
your program, because Crystal applies a reopening to the whole program:

```crystal
struct OtherShard::Ack
  include Plugboard::Quiet
end
```

## Listening, handling and intercepting

Each event type has three kinds of hook. All of them return a disposable; call
`dispose` on it to remove the hook.

```crystal
app.on(Resized) { |event| puts "#{event.cols}x#{event.rows}" }

app.handle(Resized) { |event| event.cols < 20 }

app.observe(Resized) { |event, taken| puts "unhandled" unless taken }

app.intercept(Resized) do |event, pass|
  pass.call(event) if event.rows > 0
end
```

- **`on`** registers a listener. Every listener sees every event, before any
  handler, so it cannot tell whether the event will be taken.
- **`handle`** registers a handler. Handlers are offered the event in
  registration order, after the listeners, and the first one to return `true`
  stops the rest and makes `emit` return `true`.
- **`observe`** registers an observer. Observers run last, after the handlers,
  and receive whether one of them took the event.
- **`intercept`** registers middleware that runs before listeners and handlers.
  It receives the event and a proc. Call the proc to pass the event on, with
  the same event or a replacement, or do not call it to swallow the event.

`intercept` without a type sees every event of every type, before the typed
interceptors:

```crystal
app.intercept do |event, pass|
  pass.call(event) unless event.is_a?(Tick)
end
```

A dispatch always runs on the hooks as they were when it started. A hook that
removes itself, or another hook, takes effect from the next event. Order within
one dispatch is fixed: interceptors, listeners, handlers, observers.

## Scopes

A `Plugboard::Context` is an ownership scope. Everything registered through it
is undone, in reverse order, when the scope is disposed. The registration
methods live in the `Plugboard::Scope` module, which both `Context` and `App`
include; on an app they act on its root scope.

```crystal
scope = app.nest
scope.on(Tick) { puts "tick" }
scope.every(1.second) { app.emit(Tick.new) }
scope.effect do
  puts "opened"
  -> { puts "closed"; nil }
end
file = File.open("/tmp/log", "a")
scope.defer { file.close }
scope.dispose
```

`effect` runs its block at once and keeps the returned proc as the undo step.
`defer` registers an undo step for work that is already done. `scope.nest`
creates a child that is disposed with its parent. `own` adopts any object that
includes `Plugboard::Disposable`; anything else fails to compile.

Releasing one item early — disposing an `Effect`, cancelling a `Timer`,
disposing a child scope — costs the same however many items the scope holds,
and the rest are still undone newest first. Each `Disposable` records where its
scope keeps it, so an item can be owned by **one scope at a time**. To move an
item, `disown` it first.

### Extending scopes

Reopen `Plugboard::Scope` to add a scoped helper once and reach it from the app
and from every scope. Inside, `scope` is the context the call acts on:

```crystal
module Plugboard::Scope
  def log_lifetime(name : String) : Plugboard::Disposable
    puts "#{name} up"
    defer { puts "#{name} down" }
  end
end

app.log_lifetime("root")
app.nest.log_lifetime("child")
```

### Standalone topics

`Topic(T)` has no dependency on the bus, the `Event` union or
`Plugboard.events`, so it works on its own as an observer with the same
listener, handler and interceptor model. Use it for notifications that belong
to one object rather than to the whole program — a value that changed, a widget
callback — where putting them on the bus would be too broad.

`on` and `handle` take a topic in place of a type, so those subscriptions are
owned by a scope exactly like the bus ones:

```crystal
class Reading
  getter topic = Plugboard::Topic(Float64).new

  def value=(value : Float64) : Nil
    @topic.emit(value) unless @topic.empty?
  end
end

sensor = Reading.new
scope.on(sensor.topic) { |value| puts "now #{value}" }
scope.dispose
```

`topic.empty?` and `topic.size` let an owner skip the work of building a value
when nobody is listening.

## Plugins

A plugin is a class that receives its own scope and wires itself up in `setup`.

```crystal
class Clock < Plugboard::Plugin
  def initialize(ctx : Plugboard::Context, @rate : Time::Span)
    super(ctx)
  end

  def setup : Nil
    ctx.every(@rate) { ctx.emit(Tick.new) }
  end
end

clock = app.plugin(Clock, 250.milliseconds)
clock.dispose
```

`app.plugin(Type, *args, **options)` creates a child scope, builds the plugin
with it, calls `setup`, and returns the instance. If either step raises, the
scope is disposed before the error continues. Disposing a plugin disposes its
scope, which removes everything the plugin registered, including plugins it
installed through `ctx.plugin`.

## Services and slots

A service is a plugin with a single shared instance, created on first use.

```crystal
class Counter < Plugboard::Plugin
  getter ticks = 0

  def setup : Nil
    ctx.on(Tick) { @ticks += 1 }
  end
end

Plugboard.service counter : Counter

app.counter.ticks
app.counter?
```

The declaration adds `counter`, which installs the service if needed and returns
it, and `counter?`, which returns it only if it is installed, to the app and to
every scope. Disposing the service clears it, and the next call to `counter`
installs a fresh one.

A slot is a shared instance that the program builds itself and attaches:

```crystal
class Screen
  getter cols = 80
end

Plugboard.slot screen : Screen

app.screen = Screen.new
app.nest.screen.cols
app.screen?
```

The declaration adds `screen=` to the app, and `screen` and `screen?` to the
app and to every scope. `screen` raises when nothing is attached. When the type
is a `Plugin`, disposing the attached plugin clears the slot, unless another
instance has been attached since.

Declare a service or a slot after its class, since the type is resolved where
the declaration appears.

## Run scopes

A run scope is an effect tied to the run loop. Its setup runs when the loop
starts and its undo runs when the loop stops, so it suits state that must not
outlive the run, such as terminal modes.

```crystal
app.while_running do
  print "\e[?1049h"
  -> { print "\e[?1049l"; nil }
end
```

Run scopes start in the order they were added and stop in reverse. One added
while the loop is running starts at once. Every run scope is stopped on the way
out, even when the loop ends with an error or another one's undo raises.

## Timers

```crystal
once  = app.after(500.milliseconds) { puts "late" }
pulse = app.every(100.milliseconds) { app.emit(Tick.new) }
once.cancel
pulse.cancel
```

Timers are kept in one deadline heap inside the loop. No fiber is spawned per
timer, and a cancelled timer is removed immediately. They fire only while the
loop is running; one created earlier keeps its deadline and fires once the loop
starts.

`every` schedules each tick from the previous deadline, so the rate does not
drift with the time the callback takes. If the loop falls behind by more than a
period, the missed ticks are skipped.

A timer belongs to the scope that created it and is cancelled with that scope.

Timers and the loop read time from the app's clock, a `Plugboard::Clock` passed
as `App.new(clock: …)`; `Plugboard::Clock::SYSTEM` is the default. A
clock answers `now`, says how long the loop may sleep for a deadline
(`budget`), and calls the procs registered with `watch` when it jumps, so a
test clock can stand still and wake the loop when it is moved. `ctx.now`
returns the clock's current instant.

## The run loop

`app.run` blocks until `app.stop` is called. Each pass does the following:

1. Waits for a posted event or the next timer deadline.
2. Fires the timers that are due.
3. Delivers everything that has been posted, including what handlers post
   along the way.
4. Emits `Plugboard::IdleEvent`.
5. Emits `Plugboard::RenderEvent`, only if the app is dirty and no render
   hold is active.
6. Emits `Plugboard::FlushEvent`.

The app becomes dirty when a non-`Quiet` event is emitted, when
`app.invalidate` is called on the loop, or when `app.wake(dirty: true)` is
called from any fiber. Many events in one pass therefore produce one render.

`app.stop` takes effect at once: it sets a flag and wakes the loop, so it never
blocks and never waits for room in a queue. The loop finishes the step it is on
and returns, which means events still queued when `stop` is called are
abandoned rather than delivered. Anything that must happen on the way out
belongs in a run scope's undo step or a `StoppedEvent` listener.

The loop also emits a `FlushEvent` once the run scopes have started, before the
first pass. On the way out it stops the run scopes, emits `Plugboard::StoppedEvent`
and then a final `FlushEvent`, whose `final?` is true. `run` can be called again
afterwards: plugins, services, timers and run scopes stay installed.

`app.dispose` tears the app down: it stops the loop if it is running and
disposes the root scope, which removes every plugin, service, timer, run scope
and registration. The next use of the app builds a fresh root scope.

The queue is unbounded, so posting never blocks the producer, including before
`run` has started. `app.pending` reports how much is waiting.

## Flushing

plugboard keeps no output of its own. A program collects what it writes during
a pass — into a buffer, a builder, a list of draw commands — and sends it out
when the loop says the pass is over:

```crystal
pending = [] of String
app.on(Tick) { pending << "tick" }
app.on(Plugboard::FlushEvent) do |flush|
  pending.each { |line| puts line }
  pending.clear
  STDOUT.flush if flush.final?
end
```

`FlushEvent` comes after `RenderEvent`, so a frame rendered on this pass is
complete when it arrives, and `rendered?` says whether one was. The last one, emitted after `StoppedEvent`, has
`final?` set: anything written on the way out — by a run scope's undo or a
`StoppedEvent` listener — is collected by then, and a listener that writes on
another thread should wait for that write to finish before returning.

An exception raised by a `FlushEvent` listener is not reported as an
`ErrorEvent`: it unwinds the loop, since output that cannot be written leaves
nothing to recover.

To pace rendering to a slow output, take a render hold while a write is in
flight and dispose it when the write lands:

```crystal
hold = nil.as(Plugboard::Disposable?)
app.on(Plugboard::FlushEvent) do |flush|
  next unless flush.rendered?
  hold = app.hold_render
  app.async do
    STDOUT.flush
    app.enqueue(-> { hold.try(&.dispose); nil })
  end
end
```

While any hold is active the loop skips `RenderEvent` but keeps the app dirty.
Releasing the last hold wakes the loop if the app is dirty, so it renders the
latest state once the output can take it.

## Background work

`ctx.async` runs work in a worker fiber. The block form is fire and forget; the
work reaches the loop by posting events:

```crystal
struct Loaded
  getter lines : Int32

  def initialize(@lines : Int32)
  end
end

Plugboard.events Loaded

app.on(Loaded) { |event| puts "#{event.lines} lines" }
app.async { app.post(Loaded.new(File.read_lines("/etc/hosts").size)) }
```

The work does not run in the loop's execution context. Each app owns a
`Fiber::ExecutionContext::Parallel` named `plugboard.workers`, sized to
`Fiber::ExecutionContext.default_workers_count` (the `CRYSTAL_WORKERS`
environment variable, or the number of logical CPUs), so work that holds its
thread — CPU work, a blocking system call — stalls neither the loop nor the
other workers. Pass a context of your own to size it differently, or to share
one between several apps:

```crystal
app = Plugboard::App.new(workers: Fiber::ExecutionContext::Parallel.new("workers", 4))
```

Because workers run in parallel with each other, anything two blocks share must
be protected — prefer passing values in and returning results over sharing
state, or use `Sync::Exclusive(T)` / `Sync::Shared(T)`.

`app.workers` is also the right place to spawn a long-lived producer of your
own, such as a fiber that reads a socket and posts what it finds.

The context is built the first time it is asked for, not in the constructor, and
then lives as long as the app. An execution context carries its own event loop,
which costs file descriptors, so a program that builds many short-lived apps
should pass one shared context rather than letting each app make its own. An app
that never touches `async` or `workers` builds none at all.

### One reply to one caller

When the result belongs to the call site that asked for it, pass the work as a
proc and take the reply in a block:

```crystal
lease = ctx.async(->{ File.read_lines("/etc/hosts").size }) do |lines|
  puts "#{lines} lines"
end
```

The work runs in the worker context and the block runs on the loop. The result
is published through the same mutex the queue uses, so the block sees it safely
without any locking of your own.

### Leases, failures and cancellation

Every form returns a lease, a `Plugboard::Job`, owned by the scope. Disposing
it, or disposing the scope, drops the reply and any failure: work already in
flight still finishes, but the reply block is never called. A lease releases
itself once its work is done.

If the work raises, the exception is re-raised on the loop and goes through
[the error policy](#errors). There is one rule for every form.

Disposing a lease cannot stop work that is already running, but it cancels the
lease's `Plugboard::Token`. Take the token as the work's argument and the work
can stop itself:

```crystal
lease = ctx.async(->(token : Plugboard::Token) {
  total = 0
  files.each do |file|
    break if token.cancelled?
    total += File.size(file)
  end
  total
}) { |total| puts total }

ctx.async do |token|
  until token.cancelled?
    sleep 10.milliseconds
  end
end
```

`token.cancelled?` is an atomic read, cheap enough to check inside a loop.

`async` registers on a scope, so it must be called from the loop's fiber.

## Errors

An exception raised while the loop delivers an event, runs a callback, fires a
timer or renders is reported as a `Plugboard::ErrorEvent`. Call `handle` on it
to keep the loop running.

```crystal
app.on(Plugboard::ErrorEvent) do |event|
  STDERR.puts event.error.message
  event.handle
end
```

If no listener handles it, the loop shuts down in the usual way and `run`
raises the original exception.

An exception raised by an error listener is not reported again, and it never
replaces the error it was reporting. Instead `report` raises a
`Plugboard::Fault` carrying both: `#primary` is the original error, which is
also the fault's `cause`, and `#secondary` is the listener's. `Context#plugin`
uses the same type when a plugin's setup fails and disposing its scope then
fails too.

## Fibers and parallelism

The kernel is owned by the fiber that calls `run`. It keeps the bus, the timer
heap and the scopes in plain arrays and deques, with no locks, because only that one fiber touches them.

These methods are safe to call from any fiber, in any execution context:

| Call               | What makes it safe                                  |
|--------------------|-----------------------------------------------------|
| `app.post`         | Hands the event to a mutex-guarded queue            |
| `app.enqueue`      | Same queue; runs a proc on the loop                 |
| `app.wake`         | An atomic dirty flag, then a wake-up                |
| `app.stop`         | An atomic flag, then a wake-up                      |
| `timer.cancel`     | An atomic flag; the heap edit is deferred to the loop |
| `token.cancel`     | An atomic flag                                      |

Everything else must be called from the loop's fiber: `emit`, `on`, `handle`,
`observe`, `intercept`, `after`, `every`, `plugin`, `nest`, `effect`, `defer`,
`while_running`, `async`, `hold_render`, `invalidate`, `own`, `disown`,
`dispose`, `report` and `pending`. In practice
that means from inside a listener, handler, timer, run scope or plugin. Build
with `-Dplugboard_assert` and each of them raises when called from anywhere
else. The checks are off otherwise, in debug and release builds alike; turn
them on for your test suite and for a development build.

This contract is per fiber, not per thread, so it holds whether or not the
program opts into parallelism — but how much a violation costs depends on
that choice. In a concurrent context, calling a loop-only method from another
fiber interleaves badly. Once `Fiber::ExecutionContext.default` has been resized
past a parallelism of one, or the loop shares a context with fibers that run in
parallel, the same call is a data race. The `-Dplugboard_assert` checks are
the cheap way to find out before it matters.

The worker context is separate from the loop's, so `async` work runs in
parallel with the loop, and with each other, by design. It communicates with
the loop only through `post`, `enqueue` and `wake`, so nothing of the kernel's
needs a lock.

Events posted from the loop's own fiber skip the mutex and go straight to a
local deque. Both queues are unbounded: a producer is never blocked, and
posting before `run` has started is safe at any volume.

## API reference

Everything below lives in the `Plugboard` module. Unless an entry says
otherwise, a method must be called from the loop's fiber (see
[Fibers and parallelism](#fibers-and-parallelism)).

### Macros

`Plugboard.events(*types)`  
Registers event types.  
Each becomes a member of `Plugboard::Event` and gets its own topic.  
Registering a type twice is harmless.  

`Plugboard.service(name : Type)`  
Declares a service.  
Adds `App#name`, `App#name?` and the same pair to `Scope`.  
`Type` must be a `Plugin` whose constructor needs only the context, and must be declared before this line.  

`Plugboard.slot(name : Type)`  
Declares a slot for an instance the program attaches.  
Adds `App#name=`, and `#name` (raises when empty) and `#name?` to `App` and `Scope`.  
When `Type` is a `Plugin`, disposing the attached instance clears the slot.  

`Plugboard.scoped(name, type)`  
Adds `#name` and `#name?` to `Scope`, forwarding to the app. Used by `service` and `slot`.  

`Plugboard.registered!(type)`  
Fails compilation unless `type`, or every member of a union `type`, is a registered event. Used inside `emit` and `post`.  

### Scope

The registration API, included by both `Context` and `App`. Every method acts
on `#scope`: the context itself, or the app's root scope. Each registration is
owned by that scope and returns a `Disposable` that removes it. Reopen the
module to add helpers of your own.

`#scope : Context`  
The scope the methods act on.  

`#nest : Context`  
A new child scope, disposed with this one.  

`#plugin(type : P.class, *args, **options) : P`  
Creates a child scope, builds `type` with it and the given arguments, calls `setup`, and returns the instance.  
Disposes the child scope if either step raises.  

`#effect(&setup : -> (-> Nil)) : Disposable`  
Runs `setup` now and keeps its result as the undo step.  

`#defer(&undo : -> Nil) : Disposable`  
Keeps `undo` as an undo step, for work already done.  

`#while_running(&setup : -> (-> Nil)) : Disposable`  
Runs `setup` when the loop starts, or now if it is running, and its result when the loop stops.  

`#on(type : T.class, &block : T -> Nil)`, `#on(topic : Topic(T), &block)`  
Adds a listener for `T`, or to a standalone topic.  

`#handle(type : T.class, &block : T -> Bool)`, `#handle(topic : Topic(T), &block)`  
Adds a handler. Returning `true` stops later handlers.  

`#observe(type : T.class, &block : T, Bool -> Nil)`, `#observe(topic : Topic(T), &block)`  
Adds an observer, called after the handlers with whether one took the event.  

`#intercept(type : T.class, &block : T, Proc(T, Nil) -> Nil)`  
Adds an interceptor for `T`. Call the proc to pass the event on.  

`#intercept(&block : Event, Proc(Event, Nil) -> Nil)`  
Adds an interceptor for every event sent through `emit` or `post`.  

`#after(span : Time::Span, &block : -> Nil) : Timer`  
Calls the block once, `span` from now.  

`#every(span : Time::Span, &block : -> Nil) : Timer`  
Calls the block every `span`, first after one `span`.  

`#async(&work : Token -> Nil) : Disposable`  
Runs `work` in the worker context, fire and forget.  

`#async(work : Proc(T), &done : T -> Nil) : Disposable`  
Runs `work` in the worker context and calls `done` with its result on the loop.  

`#async(work : Proc(Token, T), &done : T -> Nil) : Disposable`  
As above, and passes `work` the lease's `Token`.  

For every `async`: a failure is re-raised on the loop and goes through `report`; disposing the lease, or its scope, drops the reply and the failure and cancels the token.  

`#hold_render : Disposable`  
Holds back `RenderEvent` until disposed. Holds nest; see [Flushing](#flushing).  

`#now : Time::Instant`  
The app clock's current instant.  

`#emit(event)`, `#post(event)`, `#invalidate`  
Same as on `App`.  

### App

The application: owns the bus, the timers, the queue and the root scope.
Includes `Scope`.

**Construction and lifecycle**

`App.new(*, workers : Fiber::ExecutionContext? = nil, clock : Clock = Clock::SYSTEM) : App`  
Creates an app.  
`workers` is where `async` work runs; the default is a `Fiber::ExecutionContext::Parallel` named `plugboard.workers`, sized to `default_workers_count` and built on first use.  
`clock` is where timers and the loop read the time; see [Timers](#timers).  

`#run : Nil`  
Starts the run scopes and runs the loop until stopped.  
Stops the run scopes, emits `StoppedEvent` and a final `FlushEvent` on the way out, then raises the first error if there was one.  
May be called again afterwards.  

`#stop : Nil`  
Stops the loop at the next step and wakes it.  
Events still queued are abandoned.  
Never blocks; safe from any fiber.  

`#dispose : Nil`  
Stops the loop if it is running and disposes the root scope.  
The next use builds a fresh root scope.  

`#running? : Bool`  
Whether `run` is in progress.  

`#on_loop? : Bool`  
Whether the calling fiber owns the loop.  
True before `run` has started, since there is no loop to contend with.  

`#assert_loop : Nil`  
Raises unless `on_loop?`.  
Compiled out unless the program is built with `-Dplugboard_assert`.  

`#workers : Fiber::ExecutionContext`  
The context `async` work runs in.  

`#clock : Clock`  
The clock the app was built with.  

`#app : App`  
The app itself, so `scope.app` works on both an app and a context.  

**Sending events**

`#emit(event : T) : Bool`  
Delivers a registered event immediately.  
Returns whether a handler took it.  
Marks the app dirty unless the type includes `Quiet`.  

`#post(event : T) : Nil`  
Queues a registered event for the loop's next pass.  
Safe from any fiber.  

`#enqueue(action : -> Nil) : Nil`  
Queues a proc to run on the loop.  
Safe from any fiber.  

`#pending : Int32`  
How many events and procs are waiting to be delivered.  

`#jobs : Int32`  
How many `async` jobs are running right now. The loop is woken when the last one finishes.  

**Rendering**

`#invalidate : Nil`  
Requests a `RenderEvent` on this pass.  

`#wake(dirty : Bool = false) : Nil`  
Wakes the loop, marking the app dirty first when `dirty` is true.  
Safe from any fiber.  

`#dirty? : Bool`  
Whether a `RenderEvent` is pending.  

`#renders_held? : Bool`  
Whether a render hold is active.  

**Errors**

`#report(error : Exception) : Nil`  
Emits an `ErrorEvent` and raises `error` unless a listener handled it.  
Raises a `Fault` if a listener raises, so the original error is never lost.  
The loop calls this for you; call it to route an error you caught yourself through the same policy.  

**Low level**

`#root : Context`  
The root scope.  

`#bus : Bus`  
The event bus.  

`#timers : Timers`  
The timer heap.  

`#attach(run : RunScope) : Nil`, `#detach(run : RunScope) : Nil`  
Add a run scope to the run or remove it. Used by `while_running` and `RunScope#dispose`.  

`#dispatch(job : Job, &work : Token -> Nil) : Nil`  
Runs `work` on `workers` for a live lease and counts it in `jobs`; a failure is re-raised on the loop unless the lease was disposed. Used by `async`.  

`#hold_renders : Nil`, `#release_renders : Nil`  
The counter behind `hold_render`. Releasing the last hold wakes the loop if the app is dirty.  

### Context

An ownership scope. Includes `Disposable` and `Scope`. Obtain one from
`App#root`, `#nest` or `Plugin#ctx`.

`#app : App`  
The app this scope belongs to.  

`#parent : Context?`  
The enclosing scope, `nil` for the root.  

`#own(item : T) : T`  
Makes this scope own `item`.  
`T` must include `Disposable`, or compilation fails.  
If the scope is already disposed, `item` is disposed at once.  
An item must not be owned by two scopes at once.  

`#disown(item : Disposable) : Nil`  
Stops owning `item` without disposing it. Constant time.  
Does nothing if this scope does not own `item`.  

`#dispose : Nil`  
Disposes everything owned, newest first, then detaches from the parent.  
Finishes even if an item raises, then raises the first error.  
Does nothing the second time.  

`#disposed? : Bool`  
Whether `dispose` has run.  

`Context.new(app : App, parent : Context? = nil) : Context`  
Creates a detached scope.  
Prefer `nest`, which also registers the child with its parent.  

### Plugin

Abstract base class for plugins. Includes `Disposable`.

`Plugin.new(ctx : Context)`  
Stores the scope.  
Subclasses that define `initialize` must take the context first and call `super(ctx)`.  

`#setup : Nil`  
Called once after construction.  
Override it to register hooks.  
Does nothing by default.  

`#ctx : Context`  
The plugin's own scope.  

`#dispose : Nil`  
Disposes the plugin's scope.  

### Disposable

A module with one abstract method, `#dispose : Nil`. Include it in a type to
let a scope own it through `Context#own`.

It also carries `#held_index : Int32`, the item's position in the scope that
owns it, or `-1` when no scope does. `Context` maintains it; never set it
yourself.

The kernel's own disposables:

`Effect`  
Created by `on`, `handle`, `observe`, `intercept`, `effect`, `defer` and `hold_render`.  
`#dispose` runs the undo step once.  

`RunScope`  
Created by `while_running`.  
`#dispose` stops it if started and removes it from the run.  
`#start` and `#stop` are called by the loop.  

`Job`  
Created by `async`.  
`#dispose` drops the reply and cancels `#token`.  
`#live? : Bool` is false once the job has finished or been disposed.  

`Timer`  
Created by `after` and `every`.  
See below.  

`Context`  
Created by `nest`.  
See above.  

`Plugin`  
Created by `plugin`.  
See above.  

### Timer

`#cancel : Nil`  
Removes the timer.  
Its block will not be called again, from the moment `cancel` returns.  
Off the loop's fiber the heap edit is deferred to the loop, so the call never touches a structure the loop owns.  
Does nothing the second time.  
Safe from any fiber.  

`#cancelled? : Bool`  
Whether the timer was cancelled.  
True as soon as `cancel` returns, wherever it was called from.  
A one-shot timer counts as cancelled once it has fired.  

`#dispose : Nil`  
Same as `cancel`.  

`#deadline : Time::Instant`  
When the timer fires next.  

`#serial`, `#heap_index`, `#fire`, `#advance` and `#before?` are used by the
timer heap and are not meant to be called.  

### Token

A cancellation flag handed to `async` work.

`#cancel : Nil`  
Cancels the token. Safe from any fiber.  

`#cancelled? : Bool`  
Whether the token was cancelled. An atomic read, safe from any fiber.  

### Event types

`Event` (alias)  
The union of every registered event type.  

`Quiet` (module)  
Marker.  
Emitting a type that includes it does not mark the app dirty.  

`IdleEvent` (struct)  
Emitted once per pass, after the queue is empty and before rendering.  

`RenderEvent` (struct)  
Emitted once per pass if the app is dirty and no render hold is active.  

`FlushEvent` (struct)  
Emitted at the end of every pass, once after the run scopes start, and once more after `StoppedEvent`.  
`#final? : Bool` is true only for that last one.  
`#rendered? : Bool` is true when the pass emitted a `RenderEvent`.  

`StoppedEvent` (struct)  
Emitted once when `run` ends, after the run scopes have stopped.  

`ErrorEvent` (class)  
Carries an error raised on the loop.  
`#error : Exception`, `#handle : Nil`, `#handled? : Bool`.  

`Fault` (class)  
An `Exception` raised when a second failure follows the one being handled.  
`#primary : Exception` is the original and is also the fault's `cause`; `#secondary : Exception` is the failure that came after.  

`EVENT_TYPES` (macro constant)  
The registered types, readable in macros as `::Plugboard::EVENT_TYPES`.  
Complete only once the whole program has been read, so use it inside a method body or `macro finished`.  

The loop sends `IdleEvent`, `RenderEvent`, `FlushEvent`, `StoppedEvent` and `ErrorEvent`
straight to their topics. Typed interceptors, listeners, handlers and observers
see them; the untyped `intercept` does not.

### Bus, Topic, Chain and Roster

The machinery behind `on`, `handle`, `observe` and `intercept`. Registrations
made here directly are not owned by any scope, so prefer the `Scope` methods.

`Bus#topic(type : T.class) : Topic(T)`  
The topic for a registered type.  

`Bus#emit(event) : Bool`  
Sends an event through the untyped interceptors, then to its topic.  
Returns whether a handler took it.  

`Bus#deliver(event : Event) : Bool`  
Sends an event to its topic, skipping the untyped interceptors.  

`Bus#gate : Chain(Event)`  
The untyped interceptor chain.  

`Topic(T)#emit(event : T) : Bool`  
Sends an event through the topic's interceptors, then delivers it.  
Returns `false` when an interceptor swallows the event, since no handler saw it.  

`Topic(T)#deliver(event : T) : Bool`  
Calls every listener, then the handlers until one returns `true`, then every observer with that answer.  
Returns whether a handler took it.  

`Topic(T)#listen(listener)`, `#unlisten(listener)`  
Adds or removes a `T -> Nil` proc.  

`Topic(T)#handle(handler)`, `#unhandle(handler)`  
Adds or removes a `T -> Bool` proc.  

`Topic(T)#observe(observer)`, `#unobserve(observer)`  
Adds or removes a `T, Bool -> Nil` proc.  

`Topic(T)#intercept(link)`, `#unintercept(link)`  
Adds or removes a `Proc(T, Proc(T, Nil), Nil)`.  

`Topic(T)#size : Int32`, `#empty? : Bool`  
How many listeners, handlers and observers are registered, and whether there are none.  
Interceptors are not counted.  

`Chain(T)#add(link)`, `#remove(link)`  
Adds or removes an interceptor.  

`Chain(T)#run(event : T) : Bool`  
Runs the interceptors, then the sink, and returns what the sink returned.  
Returns `false` when an interceptor does not pass the event on.  

`Chain(T)#sink`, `#sink=`  
The `T -> Bool` proc called at the end of the chain.  

`Chain(T)#empty? : Bool`  
Whether the chain has no interceptors.  

`Roster(T)`  
The copy-on-write list behind topics and chains: `#add`, `#remove`, `#each`, `#size`, `#empty?`, `#to_a`.  
`#each` walks the list as it was when the walk started.  

Removal compares procs and removes the first match only, so keep the proc you
registered in order to remove it; a proc registered twice needs two removals.

### Internal types

`Timers` and `Action` are public only because the loop needs them. Their
methods may change without notice.

## Limits

- Events must be registered at compile time. Emitting or posting a type that
  was never passed to `Plugboard.events` fails to compile.
- Handlers have no priority. They run in registration order.
- The queue is unbounded by design, so a producer that outruns the loop grows
  it rather than being held back. Watch `app.pending` if that matters.
- `app.stop` abandons whatever is still queued.
- A pass delivers everything handlers post along the way, so a listener that
  posts in reply to every event it sees, including its own, keeps one pass
  going: timers, `IdleEvent` and rendering wait until something calls `stop`.
  That is a feedback loop in the program, not something the loop can repair
  without giving up one render per cascade.

## Development

```sh
shards install
crystal spec
crystal spec -Dplugboard_assert
```

## License

MIT