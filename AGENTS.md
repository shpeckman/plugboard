# AGENTS.md

Orientation for AI agents working on plugboard.

## What this is

plugboard is a small application kernel for Crystal: a typed event bus, a
single-fiber event loop with a timer heap, and ownership scopes that undo
everything registered through them. Features are plugins that wire themselves
into the bus. Output is collected in a [`Bytewire`](https://github.com/shpeckman/bytewire)
buffer and flushed once per loop pass, so it can be handed directly to shards
that render into a `Bytewire`, such as [term](https://github.com/shpeckman/term).

## Repository layout

```
shard.yml                         dependencies (bytewire)
src/plugboard.cr                  entry point; requires bytewire, sync and every module
src/plugboard/fault.cr            Fault: an error raised when a second failure follows the first
src/plugboard/event.cr            Plugboard.events macro, Event union, built-in events, Message, Quiet, Action
src/plugboard/bus.cr              Bus: one Topic per registered type, untyped gate chain, deliver
src/plugboard/topic.cr            Topic(T): interceptor chain, listeners, handlers
src/plugboard/chain.cr            Chain(T): middleware pipeline with prebuilt next-procs
src/plugboard/context.cr          Context: ownership scope, registration methods, typed async, own/disown/dispose
src/plugboard/app.cr              App: run loop, queues, buffers, flush, sessions, error reporting
src/plugboard/timer.cr            Timer and Timers (indexed binary min-heap)
src/plugboard/disposable.cr       Disposable module and its slot
src/plugboard/token.cr            Token: atomic cancellation flag handed to async work
src/plugboard/disposable/effect.cr   Effect: one-shot undo
src/plugboard/disposable/session.cr  Session: setup/undo tied to the run loop
spec/spec_helper.cr               requires spec and the shard
spec/plugboard_spec.cr            the spec suite
README.md                         usage and public API reference
AGENTS.md                         this file
```

`topic.cr` and `chain.cr` have no dependency on `Bus`, `Event` or
`EVENT_TYPES`. Both are reusable on their own, so keep them that way.

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

## Working with the buffer

`App#buffer`, `App#scratch`, `Context#buffer`, `Context#scratch` and
`Plugin#buffer` return `Bytewire` directly; there is no plugboard-specific
alias. Write with chained appenders (`buf.csi.int(row).semi.int(col).char('H')`,
`buf.str(...)`, `buf.int(...)`). There is no `bbwrite` macro.

A failed write is fatal: `flush` clears the buffer in an `ensure` so it cannot
grow without bound, then lets the error unwind the loop.

## Concurrency and ownership

The loop fiber owns the bus, the timer heap, the scopes and both builders, all
of them plain arrays and deques with no locks. The README's
**Fibers and parallelism** section is the public contract; these are the
invariants behind it.

**Two queues.** `@local` is a deque the loop fiber pushes to and drains
directly. `@shared` is a deque guarded by `@mutex` that every other fiber
pushes to. `absorb` moves `@shared` into `@local` under the mutex. Both are
unbounded, so nothing blocks a producer.

**The doorbell.** `@bell` is a `Channel(Nil)` of capacity one, and `@ringing`
tracks whether a ring is in flight. A producer sets `@ringing` inside the same
critical section as its push and only sends when it was the one to set it, so
the send can never block on a full channel. The loop clears `@ringing` **before**
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
`Fiber::ExecutionContext.default_workers_count` that `async` spawns into, so a
block that holds its thread stalls neither the loop nor other workers. Workers
reach the loop only through `post`/`enqueue`, so nothing of the kernel's needs a
lock; work that shares state with other work must protect it itself. Never spawn
kernel work with bare `spawn` — it would land in the loop's own context.

It is built on first use, under `@mutex` because `async` may be called from any
fiber, and **not** in the constructor. Constructing an execution context is not
free: it carries its own event loop and so costs file descriptors (an epoll
descriptor and an eventfd on Linux) from the moment it exists, even though no
thread starts until something is spawned into it. An eager context per app
exhausts the descriptor table in any suite that builds an app per example — tui's
did, at around 190. Keep it lazy.

**Typed async.** `Context#async(work, &done)` keeps its cancel flag as a plain
closured `Bool`, not an `Atomic`, because only the loop fiber touches it: the
undo step writes it and the enqueued reply reads it. The worker fiber only
produces the value. That value crosses contexts inside the closure handed to
`enqueue`, so it is published through the queue's mutex and needs no
synchronisation of its own. Contrast `Timer#cancel`, which does need an
`Atomic` because `cancelled?` must be truthful the instant it returns from any
fiber. A failure is re-raised inside the enqueued reply rather than passed to
`report` directly, so the loop's `guard` reports it exactly once.

**Cancellation.** `Context#async(work : Proc(Token, T))` is the primary form;
the `Proc(T)` form wraps it. The lease's undo step flips `live` (loop-only, a
plain `Bool`) and cancels the `Token` (an `Atomic(Bool)`, because the worker
reads it from another thread).

**Asynchronous output.** With `async_output: true`, `flush` calls `hand_off`:
under `@lock` it takes any stored write failure and reads `@writing`; if no
write is in flight and the buffer has bytes it swaps `@buffer` and `@spare`,
sets `@writing` and sends the full builder over `@outbox` (capacity one, so the
send never blocks: there is at most one builder in flight). The writer is a
`Fiber::ExecutionContext::Isolated` built on first hand-off, because it makes
blocking writes and must own its thread. After each write it resets and shrinks
the builder, clears `@writing`, records the first failure, broadcasts `@idle`
and rings the bell so the loop renders what it deferred. `render` returns early
while `writing?`, leaving `@dirty` set — that is the frame pacing; do not move
the check after `@dirty = false`. `settle` (`flush(wait: true)`) waits on
`@idle`, hands off what remains and repeats until the buffer is empty.
`shutdown` settles, then `stop_writer` closes `@outbox` and waits for the
writer, so `run` may be called again and builds a fresh writer. The loop never
touches the builder in flight: after a swap it lives in `@spare`, which the loop
only takes back in the next `hand_off`, after `@writing` is false.

**Known costs.** `App#detach` is an `Array#delete`, O(n) in the session
count, which is always small; leave it.

**Held items and slots.** `Disposable` carries `slot`, the item's index in its
owner's `@held`, or `-1`. `own` sets it; `disown` checks that `@held[slot]` is
the same object, then leaves a `nil` hole there instead of shifting or
swapping, so removal is O(1) and the survivors keep their order — teardown must
stay newest first, which rules out swap-removal. `@holes` counts the gaps;
`compact` squeezes them out and renumbers every slot once they outnumber the
live items, keeping it amortized O(1). `dispose` pops from the end, skips
holes, and resets each item's slot before disposing it. One slot per item means
an item can have only one owner at a time.

**Consumption.** `Topic#deliver` returns whether a handler took the event, and
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
