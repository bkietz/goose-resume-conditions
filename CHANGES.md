# Differences from the original coroutine proposal

This file lists each difference between this proposal and the original
coroutine design, [`docs/design/coroutines.md`](../goose/docs/design/coroutines.md).
Every pair of snippets comes from this repository's worked examples
(`serve/`, `cross-package-composition/`, `wrong-event-resume/`,
`lazy-sequence/`), so each claim can be checked against code.

## 1. Composition across packages: adapter coroutines → imported conditions

**Problem.** Calling a foreign coroutine from a coroutine whose
yield/resume types differ is illegal in the original design (§4.4). The
composing package must invent a third merged protocol, write an adapter
per imported coroutine, and maintain hand-checked translation tables
between the protocols. The shared union then makes a mismatch in meaning
unavoidable: an Event relevant only to one coroutine must be translated
into something deliverable to every other -- the ticker knows neither
sockets nor hangups, yet the adapter still owes an arm translating the
scheduler's `Hungup` into `ticker::Event`.

**Solution.** A library's conditions are declarations that import with the
coroutine. A condition means the same thing everywhere it is
suspended on, so no translation is needed. The scheduler answers each
condition with an `on_suspend` overload: a coroutine gaining a new
condition costs the scheduler one added overload. Reusable `on_suspend`
fragments are similarly importable. Composition needs neither adapters
nor a merged union.

**Before** (`cross-package-composition/cross-package-composition.before.goose`)
```goose
// One adapter per imported coroutine: start its frame as a value, drive
// it with resume(), and translate both ways.
coro fn drive_tick(period_ns: i64) -> i64 yield Wait resume Event {
    var inner = ticker::tick { period_ns };
    var lib_ev = ticker::Event.Fired;   // the first resume's event is unused
    loop {
        let raw, suspended = resume(inner, lib_ev);
        guard suspended else { return result(inner); }
        // Hand the library's Wait up in our protocol, then bring the
        // scheduler's Event back down in the library's.
        let up = as_wait(raw);
        let our_ev = yield up;
        lib_ev = as_ticker_event(our_ev);
    }
}
```

**After** (`cross-package-composition/cross-package-composition.after.goose`)
```goose
// The composed coroutine: plain calls, no adapters. The suspensions
// inside the library calls belong to the libraries' conditions and reach
// the scheduler directly, untouched by this file.
fn monitor_job(c: watcher::Conn&<u32 in watcher::conns>, period_ns: i64) -> Status {
    loop {
        let n = watcher::wait_data(c);
        if n <= 0 { return Status.PeerDown; }
        ticker::tick(period_ns);
        let verdict = resume if SupervisorAnswered {};
        if verdict { return Status.Stopped; }
    }
}
```

## 2. The scheduler protocol: two shared enums → resume signatures

**Problem.** The pair of unions doesn't say which Events may answer which
Waits; that relationship is a convention the reader must reconstruct from
the whole program, and nothing checks it (a scheduler can deliver any
variant to any suspension -- see
[`wrong-event-resume/`](wrong-event-resume/README.md)).

**Solution.** A resume signature declares a condition and, after `->`, the
type of proof resuming from it yields: the wait's response surface is a
checked declaration that can be named, documented, and imported.

**Before** (`serve/serve_example.before.goose`)
```goose
// The protocol between coroutines and the loop is two flat ADTs the library
// defines. A different loop (io_uring, IOCP, a game's frame tick) defines its own.
enum Wait  { Readable { fd: i64 }, Writable { fd: i64 }, Timer { deadline_ns: i64 }, Any }
enum Event { Ready, Timeout, Hangup, Cancel }
```

**After** (`serve/serve_example.after.goose`)
```goose
// The protocol from coroutine to scheduler are the conditions
// which the coroutine requires for resumption, expressed as resume
// signatures: each names a condition and the proof resuming from it yields.
struct FileWontBlock { fd: i64, flags: i32 }
resume if FileWontBlock -> net::Event;

struct TimeElapsed { time: i64 }
resume if TimeElapsed ->;
```

### 2.1. A meaningful M:N mapping of reusable protocol types can still be expressed

For example, in the original serve example there is a 2:2 mapping
between `Wait.{Readable, Writable}` and `Event.{Ready, Hangup}`: either wait can be
answered by either event. This 2:2 mapping could be expressed using resume conditions
by splitting the `FileWontBlock` resume condition into read/write-specific conditions
and replacing the forwarded `net::Event` with a dedicated proof type for those conditions:
```goose
struct FileReadable { fd: i64 }
struct FileWritable { fd: i64 }
enum FileResult { Ready, Hangup }

resume if FileReadable -> FileResult;
resume if FileWritable -> FileResult;

fn fill(conn: Conn&<u32 in conns>) -> bool {
    // ...
    let result = resume if FileReadable { conn.fd };
    if result == FileResult.Hangup { return false; }
    // ...
}
```
It is only required that conditions *opt into* M:N mappings.
By default, coroutines are insulated from handling events irrelevant to them.

## 3. Fulfilling conditions: matches at every resume site → `on_suspend` handlers

**Problem.** In the original design the scheduler sees only an opaque
`Wait` value and must decide what it means everywhere it resumes; the
serve example literally reiterates the same match at each call site, and
any new loop or resume site must repeat the interpretation or drift from
it.

**Solution.** The fulfillment logic for a condition exists once, as an
`on_suspend` overload; a scheduler implements the conditions its tasks
use, and adding a task type or a loop site reuses that code instead of
rewiring it.

**Before** (`serve/serve_example.before.goose`)
```goose
// Each resume() call site produces a `Wait`, so every resume call site
// needs to reiterate their exhaustive handling
// (or extract an `on_suspend`-like function).
match w {
    Readable r => net::watch(r.fd, net::READ, i),
    Writable r => net::watch(r.fd, net::WRITE, i),
    Timer t    => timers.heap_push(Deadline { at: t.deadline_ns, task: i }),
    Any        => ready.push(i),
}
```

**After** (`serve/serve_example.after.goose`)
```goose
// Suspension handling is encapsulated in the on_suspend overload
// set, one overload per resume condition.
fn on_suspend(task: own ServeTask, b: FileWontBlock) {
    net::watch(b.fd, b.flags);
    by_fd[b.fd] = &tasks.take(task);
}

fn on_suspend(task: own ServeTask, u: TimeElapsed) {
    timers.heap_push(Deadline { u.time, &tasks.take(task) }) { l, r => l.time < r.time };
}
```

## 4. Suspension: the `yield` keyword → `resume if`

**Problem.** `yield` carries the generator-sequence connotation of Python
and JavaScript, which is not what Goose targets with coroutines -- and
what a suspension returns is whatever variant the driver's convention
happened to send, untyped by the suspension point itself.

**Solution.** `resume if` reads as what the suspension is, a requirement
("cannot resume until ... "). The suspended value is the requirement's
payload, and the expression's value after resumption is the proof -- typed
exactly as the condition's resume signature declares.

**Before**
```goose
guard (yield Wait.Readable { fd: c.fd }) == Event.Ready else { return false; }
```

**After** (`serve/serve_example.after.goose`)
```goose
// suspend into the FileWontBlock resume condition:
let ev = resume if FileWontBlock { conn.fd, net::READ };
if ev.hangup { return false; }
```

## 5. Resuming: an Event argument and a paired return → a named condition and a proof

**Problem.** From `resume(f, Event.X)` no reader (and no type checker) can
tell what the task was waiting for or whether `Event.X` answers it; the
condition is chosen by whoever calls, against a union every suspension
accepts.

**Solution.** The call names the condition it is resuming from and the
compiler knows which resume signature governs -- so the resume variant is
known, not just the union of all resume variants.

**Before**
```goose
let w, suspended = resume(tasks[i], if ev.hangup { Event.Hangup } else { Event.Ready });
```

**After** (`serve/serve_example.after.goose`)
```goose
// because the file won't block anymore, resume execution with this event
resume<FileWontBlock>(tasks.release(file_task), ev);
```

## 6. Finishing: `result()` and per-site checks → one more suspension case

**Problem.** The original needs two builtins (`resume` returns the running
flag, `result(f)` reads a finished frame and aborts otherwise) and a
finished-check at every resume site.

**Solution.** Finishing is just the terminal suspension: its handling is
written once per task type in an `on_suspend` handler -- which, unlike the
others, does not take ownership, because the task is over -- and no
`resume()` site re-arms the logic.

**Before** (`serve/serve_example.before.goose`)
```goose
guard suspended else {                       // at every resume() call site
    conns.free(conns.index_of(tasks[i].c)); tasks.free(i); net::close(ev.fd);
    continue;
}
```

**After** (`serve/serve_example.after.goose`)
```goose
// A coroutine returning is considered a special case of suspension:
// a coroutine which returns is considered suspended in the "return" condition.
fn on_suspend(task: ServeTask&, r: suspended::finished<ServeTask>) {
    conns.free(conns.index_of(r.value));
}
```

## 7. Coroutine declarations: `coro fn` → plain `fn`

**Problem.** The declaration adds nothing the compiler cannot derive --
whether a function suspends is statically detectable -- while it colors
every HOF declaration: in the original design, a HOF had to be marked to
accept a yielding block (`arr.map() { yield it; }` does not compile,
because `map` is not declared `coro fn`).

**Solution.** Coroutines are plain functions containing a `resume if` or
calling one. The async-ness cannot spread stealthily either: outside a
coroutine, a coroutine can only be called by constructing a task, so an
accidental suspension surfaces as a checker error naming the call stack.
The suspension handling still travels one condition at a time, so no
function "becomes async" without its callers seeing a condition land.

**Before** (`serve/serve_example.before.goose`)
```goose
coro fn fill(c: Conn&<u32 in conns>) -> bool resume Event { ... }   // `resume` may also be omitted there
```

**After** (`serve/serve_example.after.goose`)
```goose
fn fill(c: Conn&<u32 in conns>) -> bool { ... }
```

## 8. Abandonment: free drops → owned tasks and `cancel()`

**Problem.** A dropped half-finished frame forfeits whatever its in-flight
wait was promised -- the original design calls that costless, but it is
silent: no check, no cleanup, no record.

**Solution.** Tasks are owned (`own_one` slots, `take`/`release`), so "a
task which is neither resumed nor cancelled" is a checker error, and
`cancel()` discharges the obligation by finishing the coroutine. That same
ownership is what makes `defer` across suspension points well-defined: the
frame can neither be forgotten nor forked.

**Before** (`lazy-sequence/lazy-sequence.before.goose`)
```goose
    var ns = naturals { };      // a plain frame value: no pool, no ownership
    ...
                guard p.value < n else {
                    // Abandoning the endless inner: dropping the frame with
                    // ours costs nothing (§4.10) -- no cancellation
                    // protocol, no handler, nothing to check. Halting an
                    // unfinished coroutine is the caller's silent choice.
                    return;
                }
```

**After** (`lazy-sequence/lazy-sequence.after.goose`)
```goose
    var hold = own_one<Inner> {};    // parks the inner task between requests
    ...
        guard value < n else {
            cancel(hold.release());  // abandoning the endless inner, safely
            return;
        }
```

## 9. Cancellation: an `Event.Cancel` convention → the `cancel(task)` builtin

**Problem.** A cooperative-cancel value is a per-library convention
delivered through the same union everything else travels in, so it
competes with the protocol: a scheduler mid-refactor can hand a task a
stop it reads as something else (a stop masquerading as a hangup -- see
[`wrong-event-resume/`](wrong-event-resume/README.md)), and a payload
carried on such an event is one guard comparison away from a leak.

**Solution.** `cancel(task)` is one builtin, independent of any protocol:
it finishes the coroutine through the pending `resume if` -- running any
active defers -- and frees the caller from inventing a stop variant per
task type.

**Before**
```goose
// Cooperative cancellation is a resume value (Event.Cancel) -- the body
// sees it at its yield and acts on by returning. A library can make it a
// convention; nothing ties the convention to any scheduler.
```

**After** (`cross-package-composition/cross-package-composition.after.goose`)
```goose
cancel(tasks.release(t));
```
