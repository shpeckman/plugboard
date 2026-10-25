# AGENTS.md

Orientation for AI agents working on plugboard.

## What this is

plugboard is a small application kernel for Crystal: a typed event bus, a
single-fiber event loop with a timer heap, and ownership scopes that undo
everything registered through them. Features are plugins that wire themselves
into the bus. The kernel owns no output: every pass ends with a `FlushEvent`,
and programs write what they collected from its listener. The shard has no
dependencies.

## Repository layout

```
shard.yml                         shard metadata; no dependencies
src/plugboard.cr                  entry point; requires sync and every module
src/plugboard/fault.cr            Fault: an error raised when a second failure follows the first
src/plugboard/event.cr            Plugboard.events and registered! macros, Event union, built-in events, Quiet, Action
src/plugboard/bus.cr              Bus: one Topic per registered type, untyped gate chain, deliver
src/plugboard/roster.cr           Roster(T): copy-on-write list behind topics and chains
src/plugboard/topic.cr            Topic(T): interceptor chain, listeners, handlers, observers
src/plugboard/chain.cr            Chain(T): middleware pipeline with prebuilt next-procs
src/plugboard/scope.cr            Scope: the registration API (nest, plugin, effect, defer, while_running, on, handle, observe, intercept, timers, async, hold_render), shared by Context and App
src/plugboard/context.cr          Context: ownership scope, own/disown/dispose
src/plugboard/plugin.cr           Plugin base class; service, slot and scoped macros
src/plugboard/app.cr              App: run loop, queues, run scopes, job dispatch, render holds, flush events, error reporting
src/plugboard/timer.cr            Timer and Timers (indexed binary min-heap)
src/plugboard/disposable.cr       Disposable module and its held_index
src/plugboard/token.cr            Token: atomic cancellation flag handed to async work
src/plugboard/disposable/effect.cr     Effect: one-shot undo
src/plugboard/disposable/run_scope.cr  RunScope: setup/undo tied to the run loop
src/plugboard/disposable/job.cr        Job: the lease of one async job, with its Token
spec/spec_helper.cr               requires spec and the shard
spec/plugboard_spec.cr            the spec suite
README.md                         usage and public API reference
AGENTS.md                         this file
```

`roster.cr`, `topic.cr` and `chain.cr` have no dependency on `Bus`, `Event` or
`EVENT_TYPES`. They are reusable on their own, so keep them that way.

## Scope and the app

Every registration method lives once, in `Plugboard::Scope`, written against
the abstract `scope : Context`. `Context#scope` is `self`; `App#scope` is
`root`. `App` defines `emit`, `post` and `invalidate` itself, which take
precedence over the `Scope` versions that forward to `scope.app`. Never add a
registration method to `App` or `Context` directly; add it to `Scope`, and an
extension shard reopens `Scope` the same way. `App#app` returns `self` so
`scope.app` reads the same on both.

`service` and `slot` define the instance on `App` and call `scoped`, which
adds the forwarding pair to `Scope`. A slot whose type is a `Plugin` defers a
clear on the attached plugin's context, guarded by `same?` so replacing the
instance first keeps the new one.

## Commands

```sh
shards install
crystal spec
crystal build --no-codegen src/plugboard.cr
crystal spec -Dplugboard_assert
```

Crystal 1.21 or newer is required. `-Dplugboard_assert` turns on the
loop-ownership assertions described below; run the suite both ways. The flag is
dedicated on purpose: Crystal sets `flag?(:debug)` in every build that carries
debug info, which is the default even with `--release`, so gating on it would
leave the checks on everywhere.

## Flushing

`App#run` emits `FlushEvent` straight to its topic after `start_runs`, at
the end of every pass (after `render`, carrying whether it rendered), and once
more with `final: true` after `StoppedEvent` in `shutdown`. It is not guarded:
an exception from a listener unwinds the loop, because a failed write is fatal.

## Rendering

`@dirty` is an `Atomic(Bool)` so `wake(dirty: true)` can set it from any fiber
before ringing. Loop-side writes (`emit`, `invalidate`) use relaxed ordering;
`render` takes it with `swap(false)`. `@holds` is a loop-only counter behind
`hold_render`: while it is positive `render` returns early and leaves the flag
set. `release_renders` rings when the count reaches zero and the app is dirty,
because a release in a `FlushEvent` listener lands after this pass's render.

## Lifecycle

`run` leaves every registration installed so it can run again. `App#dispose`
stops a running loop, drops `@root` and disposes it; the next `root` call
builds a fresh scope.

## Concurrency and ownership

The loop fiber owns the bus, the timer heap and the scopes, all of them plain
arrays and deques with no locks. The README's
**Fibers and parallelism** section is the public contract; these are the
invariants behind it.

**Two queues.** `@local` is a deque the loop fiber pushes to and drains
directly. `@shared` is a deque guarded by `@mutex` that every other fiber
pushes to. `absorb` moves `@shared` into `@local` under the mutex. Both are
unbounded, so nothing blocks a producer.

**The doorbell.** `@bell` is a `Channel(Nil)` of capacity one, and `@ringing`
tracks whether a ring is in flight. A producer sets `@ringing` inside the same
critical section as its push and only sends when it was the one to set it.
`absorb` clears `@ringing` without taking the token, so a token can still sit in
the channel when the next ring fires; `toll` therefore sends without blocking
and drops the ring when the channel is full, since the waiting token already
wakes the loop. A blocking send there deadlocks a loop that rings itself
(`release_renders`, `wake`). The loop clears `@ringing` **before**
draining, never after: that ordering is what makes a lost wake-up impossible.
A spurious wake-up — the loop drains an item whose ring is still in flight — is
harmless and expected. Do not reorder those two steps.

**The `@owner` check is deliberately unsynchronized.** `submit` compares
`Fiber.current.same?(@owner)` to pick the fast path. A stale read is safe in
both directions: a non-loop fiber can never match the value, because only the
loop fiber *is* it, so it always takes the mutex path; and the loop fiber
reading a stale `nil` just takes the mutex path too, which is slower but
equally correct. Pushing to `@shared` is correct from any fiber; `@local` is
only ever an optimization. Never make correctness depend on that comparison.

**`on_loop?` is permissive, `submit` is strict.** `on_loop?` returns true when
`@owner` is nil, because before `run` there is no loop to contend with; it
backs the loop assertions and `Timer#cancel`. `submit` must not use it — a
pre-run fast path would let two fibers race on `@local`. Keep them separate.

**Stop is an atomic flag.** `@stopping` is flipped by `stop` from any fiber and
read by `run`'s loop condition and by `drain`'s inner loop. The `drain` check is
not optional: without it a listener that posts on every event spins a pass
forever. Do not bound a pass to the items queued when it started: a pass
delivering everything handlers post along the way is what makes one cascade
one render, and the README documents it. A self-feeding listener is a
program bug, listed under **Limits**, and `stop` still breaks in. `@running` is only "is `run` in progress" for `running?`; it is not a
loop condition.

**Assertions.** `App#assert_loop` raises when a loop-only method is called from
elsewhere, and compiles to nothing without `-Dplugboard_assert`. Every loop-only public
method on `App` and `Context` calls it. Add the call when you add such a method.

**Workers.** `App#workers` is a `Fiber::ExecutionContext::Parallel` sized to
`Fiber::ExecutionContext.default_workers_count` that `dispatch` spawns into, so a
block that holds its thread stalls neither the loop nor other workers. Workers
reach the loop only through `post`/`enqueue`/`wake`, so nothing of the kernel's needs a
lock; work that shares state with other work must protect it itself. Never spawn
kernel work with bare `spawn` — it would land in the loop's own context.

It is built on first use, under `@mutex` because `workers` may be called from any
fiber, and **not** in the constructor. Constructing an execution context is not
free: it carries its own event loop and so costs file descriptors (an epoll
descriptor and an eventfd on Linux) from the moment it exists, even though no
thread starts until something is spawned into it. An eager context per app
exhausts the descriptor table in any suite that builds an app per example — tui's
did, at around 190. Keep it lazy.

**Async.** Every `Scope#async` form builds a `Job` owned by the scope and hands
it to `App#dispatch`, which skips a job that is already dead, counts it in
`@jobs` and spawns the work on `workers`. The job's live flag is a plain `Bool`,
not an `Atomic`, because only the loop fiber touches it: `dispose` writes it and
the enqueued reply reads it through `finish` or `fail`. The worker fiber only
produces the value. That value crosses contexts inside the closure handed to
`enqueue`, so it is published through the queue's mutex and needs no
synchronisation of its own. Contrast `Timer#cancel`, which does need an
`Atomic` because `cancelled?` must be truthful the instant it returns from any
fiber. A failure is re-raised inside the enqueued `fail` rather than passed to
`report` directly, so the loop's `guard` reports it exactly once. A finished
job disposes itself through `finish`, which releases its place in the scope.

**Cancellation.** `Job#dispose` cancels its `Token` (an `Atomic(Bool)`, because
the worker reads it from another thread). The `Proc(T)` form wraps the
`Proc(Token, T)` form.

**Known costs.** `App#detach` is an `Array#delete`, O(n) in the run scope
count, which is always small; leave it. `Roster#add` and `#remove` copy the
array so a dispatch in progress keeps its snapshot; registration is rare next to
delivery.

**Held items.** `Disposable` carries `held_index`, the item's index in its
owner's `@held`, or `-1`. `own` sets it, after a compile-time check that the
type includes `Disposable`; `disown` checks that `@held[held_index]` is
the same object, then leaves a `nil` hole there instead of shifting or
swapping, so removal is O(1) and the survivors keep their order — teardown must
stay newest first, which rules out swap-removal. `@holes` counts the gaps;
`compact` squeezes them out and renumbers every index once they outnumber the
live items, keeping it amortized O(1). `dispose` pops from the end, skips
holes, and resets each item's index before disposing it. One index per item
means an item can have only one owner at a time.

**Registration.** `App#emit` and `App#post` call `Plugboard.registered!(T)`,
which fails compilation for a type, or union member, missing from
`EVENT_TYPES`. It runs in a method body, where the list is complete.

**Consumption.** `Topic#deliver` runs listeners, then handlers until one takes
the event, then observers with that answer, and returns whether a handler took
it, and
`Chain#run` carries that back through its `@result` ivar because interceptor
links return `Nil` and cannot propagate it. `Chain#run` saves and restores
`@result` so a handler that re-emits the same type cannot corrupt the outer
answer. `Topic#emit` is the full path through the interceptors; `Chain` keeps
`run`, `add` and `remove`, because it is a container of links rather than an
event source.

## Quiet events

An event is a `Quiet` — the marker that stops it from marking the app dirty —
unless a listener could plausibly change what is on screen. Anything emitted on
a timer, anything that is a response to a query, and any bookkeeping tick
belongs in that category. Emitting a non-`Quiet` event on every tick makes the
app render continuously for as long as the timer runs.

## Code standards

- Compiler-friendly, performance-focused and idiomatic Crystal.
- Data-driven design.
- No comments in code, except the first line of every file, which is a comment
  holding the file's path (for example `# src/plugboard/app.cr`).
- The usage-facing API must be ergonomic.
- Prevent shotgun surgery: a change should touch as few files as possible.
- Never use `out` as an identifier.
- Do not add functionality that was not asked for.
- Deliver complete files: no stubs and no placeholders.
- Never change the `version` field in `shard.yml`.
- Keep `README.md` and `AGENTS.md` in sync with the code.
