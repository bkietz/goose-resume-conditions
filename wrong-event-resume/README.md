# Wrong-event resume

## What it demonstrates

The serve example's `fill` coroutine handles only `Event.Ready`: its `guard` treats *every other* variant as "the fd failed". Under the original design that is exhaustive and therefore silent — the checker cannot tell an applicable resume from an inapplicable one, so a scheduler that delivers `Event.TimedOut` to `fill`'s readiness wait compiles without a diagnostic, even though `TimedOut` carries a resource token that the guard then drops on the floor. With resume conditions, the attempted wrong resume is a compile error at the call site.

## Transformation summary

- A shared `Event` union deliverable to any suspension (`Ready`, `TimedOut { token }`, `Hangup`, `Cancel`) → one resume signature per condition; a wait's response surface is exactly what its condition declares
- `guard (yield Wait.Readable { .. }) == Event.Ready else return false` — total over the union, so it silently absorbs a `TimedOut` and drops its payload → `let ev = resume if FileWontBlock { .. }` — only fd events can arrive, and only through the declared proof type
- The watchdog branch resumes the task with `Event.TimedOut { token }`; the token dies in the guard's comparison (leaked) → the same intent is `resume<FileWontBlock>(task, read_id)`, which **does not compile**; the scheduler instead ends the wait by owning the deadline entry itself and calling `cancel(task)`
- A resource (the completion id of the abandoned read) must survive a round trip through the coroutine to be released → the deadline never enters the coroutine at all; the scheduler arms and disarms it around one `on_suspend`/resume pair
- A realistic hardening of the before design — `TimedOut { token: own ReadOp& }`, per ownership.md — would close the leak, but forces an ownership-aware destruct at every yield of every coroutine sharing the enum; under conditions the cost lands only in the one condition whose proof carries the handle

## Before

`enum Wait`/`enum Event` are the package's whole protocol; the watchdog feature smuggled a resource into one variant, and nothing records which Events which coroutines are prepared for:

[the shared protocol, with a resource in TimedOut](wrong-event-resume.before.goose#L13-L24)

`fill`'s suspension point is exhaustive over the union but prepared for none of it: any non-`Ready` event is read as "fd failed" and the resume value is dropped unread:

[exhaustive but dangerous: the guard absorbs every variant](wrong-event-resume.before.goose#L30-L44)

The watchdog branch therefore compiles as written. `TimedOut` is a valid `Event` for `fill` at any of its suspensions; the checker accepts the resume; `fill`'s guard swallows the event, returns `false`, and the connection is torn down as though the peer had hung up — while the abandoned read's token (and its kernel-side state) is leaked, its release having ridden in a payload no control flow ever bound:

[the inapplicable resume, accepted silently -- and the leak](wrong-event-resume.before.goose#L77-L91)

## After

`fill`'s wait declares its entire response surface: the condition's resume signature is the only continuation the suspension has, and its proof type is `net::Event` — a timeout is not expressible as a response to a readiness wait, by anyone, ever:

[the condition: one continuation, one proof type](wrong-event-resume.after.goose#L12-L19)

[only fd events can wake fill, and it is ready for each by construction](wrong-event-resume.after.goose#L25-L29)

The same watchdog intent, attempted in the scheduler, is now the highlighted error — the commented-out call does not compile because the proof type is decided by the condition, not by whoever calls:

[the wrong resume rejected; the correct one owns its own table](wrong-event-resume.after.goose#L75-L90)

Ending the wait is instead an act on the scheduler's own state: the deadline entry is armed in `on_suspend` (when the wait is registered) and disarmed by the branch that ends it — the token never makes the round trip through the coroutine, so there is no receiver that could drop it.

## Would checked ownership patch the before design?

The leak, at least, is patchable. Give the payload a checked owner — `TimedOut { token: own ReadOp& }`, the `own` qualifier of [ownership.md](../../goose/docs/design/ownership.md) — and "the compiler never copies an `own` value and never lets one die unconsumed": a guard that drops the token becomes a checker error, not a leak. But the guarantee is bought at every suspension point, not just the watchdog's:

- `fill`'s comparison stops compiling: comparing the resume value copies an `own` value, and the `else` path lets it die unconsumed, and the checker rejects both. Every yield site must instead bind the value and destruct the whole union with an ownership-aware match whose branches agree on consuming the handle.
- That machinery lands at every suspension point of every coroutine sharing the enum — including waits a timeout can never apply to. The applicability problem does not go away; it becomes mandatory ownership bookkeeping inside the coroutines, which is the code bloat this example's guard pattern was avoiding.
- Keeping the handle across a later yield is a further decision: under design A of ownership.md §5 an `own` local may not cross a yield at all, and under design B any frame that holds one turns `own` itself — neither copiable nor droppable, with generated `cancel` machinery — for every coroutine of the package, whatever it waits for.
- An enum carrying `own` payloads is an own-holding container, the boundary ownership.md flags as needing extra checker help.

Under resume conditions the same safety falls out locally: an owned release token lives in exactly one condition's resume signature, so only coroutines suspending in that condition pay for it — and when the scheduler owns the token outright, as this example's deadline does, it never crosses a suspension boundary at all.

## Key takeaways

- Exhaustiveness is not applicability: a `match`/`guard` that is total over `Event` satisfies the checker while handling none of the variants correctly. The original design has no way to distinguish `resume(f, Event.TimedOut)` at a readability wait from a semantically valid one.
- A resume value nobody binds is a resource nobody frees. Dropping a payload-bearing variant by control flow leaks silently — exactly the leak class the user of a protocol cannot see and the checker does not flag.
- With resume conditions, the fit between what a task waits for and what resuming it says is checked at each call site: `resume<FileWontBlock>(task, proof)` is the only continuation, and its proof type is fixed by the condition's resume signature. "Resuming with an Event the coroutine is not prepared for" is not a runtime hazard to document; it is a type error to fix.
- The after design does not lose the watchdog: killing a slow task is `cancel(task)` (its own safe exit, per the proposal), and a *timed read* — a wait that genuinely can time out — would be expressed by declaring a condition whose proof says which happened. The contract becomes visible in the library that offers it, not smuggled into a scheduler branch.
- `net::read_done` in the before file is part of the hypothetical `net` sketch, like `net::dial` and `net::watch`; it exists only to give the dropped payload a defensible resource behind it.
