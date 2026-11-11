# Cross-package composition

## What it demonstrates

Composing coroutines that live in *independent packages*: `ticker` (a timer library) and `watcher` (a socket library) each export a coroutine, and the `monitor` package's own coroutine composes both and is driven by `monitor`'s scheduler. In the original design the scheduler is forced to translate between the imported coroutines' `Wait`/`Event` protocols and its own; with resume conditions the imported coroutines and their suspension contracts compose directly.

Layout: each variant is three files. `ticker.goose` and `watcher.goose` (under `before/` and `after/`) hold the imported coroutines; the root file `cross-package-composition.before.goose` / `.after.goose` is the `monitor` package — its own coroutine, its scheduler, and the adapters or their absence. Compile from this directory with `goose cross-package-composition.before.goose` / `goose cross-package-composition.after.goose` (imports resolve against the root file's directory).

## Transformation summary

- Per-library protocol enums exported by nothing (`ticker::Wait/Event`, `watcher::Wait/Event`) → named resume conditions the library declares and exports (`ticker::TimeElapsed`, `watcher::FileWontBlock`), imported like any other declaration
- A third hand-merged protocol owned by the composing package (`monitor::Wait`/`monitor::Event`, incl. `FdReady`, `WakeAt`) → only the scheduler's own genuine condition (`SupervisorAnswered`); the foreign vocabularies pass through untouched
- One adapter coroutine per imported coroutine (`drive_tick`, `drive_wait_data`) plus hand-written translation tables (`as_wait`, `as_ticker_event`, `as_watcher_event`) → deleted entirely; `monitor_job` calls the libraries as plain functions
- `resume(task, Event.X)` returning an untyped pairing of "whatever it yielded" with a `suspended` flag → `resume<Condition>(task, proof)`, the condition named explicitly at each call site
- Exhaustive `match` over the merged union at every resume site (`on_yield` helper) → one `on_suspend` overload per condition
- `coro fn` / `yield` / `result()` protocol → plain `fn` / `resume if` / the finished state as an `on_suspend` overload

## Before

The two libraries were developed independently, so each declares the `Wait`/`Event` pair it was designed with — and the pairs share nothing:

[ticker's package-local Wait/Event pair](before/ticker.goose#L11-L12)

[watcher's package-local Wait/Event pair](before/watcher.goose#L11-L12)

A coroutine call requires the callee's yield type to be the caller's (its resume type must match or be absent; §4.4 of the coroutine design), so `monitor_job` cannot call `ticker::tick` or `watcher::wait_data` as they are written — their protocols don't match `monitor`'s. The composing package therefore writes, by hand:

- a third protocol of its own, a union merging what both libraries and the scheduler itself need —

  [monitor's hand-merged Wait/Event union](cross-package-composition.before.goose#L18-L24)

- four translation functions, whose match arms the checker can only confirm are exhaustive, not correct —

  [the four translation functions](cross-package-composition.before.goose#L36-L70)

- and an adapter coroutine per imported coroutine, which starts the library's frame as a value and drives it with `resume()`, translating in both directions —

  [`drive_tick` and `drive_wait_data`, one adapter per imported coroutine](cross-package-composition.before.goose#L76-L100)

Every adaptation is a convention this file invented: `Stop` "means" `ticker::Event.Cancelled` there and `watcher::Event.Hangup` here, because a scheduler's `Stop` arrived at a yield of a library that never asked to be stopped and something had to be picked. Adding an `Event` to `monitor` or a `Wait` variant to either library silently re-aims every one of these matches; the compiler flags nothing but non-exhaustiveness. Note also what the scheduler's own `match` in `on_yield` no longer sees: the libraries' distinctions were already lost in the `as_wait` translations.

## After

The libraries declare their suspension needs as named conditions — exported declarations, imported with the coroutine:

[ticker's condition: a deadline](after/ticker.goose#L14-L15)

[watcher's condition: an fd that won't block](after/watcher.goose#L13-L18)

`monitor_job` composes both with plain function calls; the libraries' internal suspensions belong to *their* conditions and reach the scheduler directly, untouched by this file:

[monitor_job: the libraries as plain calls](cross-package-composition.after.goose#L29-L37)

The scheduler's entire contract for two imported libraries plus its own suspension is one `on_suspend` overload per condition — `watcher::FileWontBlock` and `ticker::TimeElapsed` are handled exactly like `monitor`'s own `SupervisorAnswered` — and each resume site names the condition it is resuming from:

[the on_suspend overload set: imported conditions alongside our own](cross-package-composition.after.goose#L53-L70)

[each resume site naming the condition it resumes from](cross-package-composition.after.goose#L89-L100)

## Key takeaways

- In the before design, importing a coroutine drags its `Wait`/`Event` pair with it, and *someone* must reconcile the pairs: adapter coroutines, translation tables, and a merged union in the composing package. In the after design, conditions are declarations like functions — the import is the interface.
- The before design's translation tables are unchecked for meaning: exhaustiveness is compile-time, correctness is folklore. Two libraries could even export same-named variants (`Both.Wait.Timer`) with different semantics, indistinguishable after translation.
- The after design's scheduler grows by adding overloads for new conditions; a condition several libraries share is handled by one overload. Adding a library touches nothing else.
- The scheduler's state machine got smaller but more specific: `resume<Watched>(task, ev)` names what happened; `on_suspend(task, condition)` names what is needed. The merged union — and the flattening of library distinctions into it — disappears with the enums.
- Conditions compose in the other direction too: a scheduler that never heard of `ticker` can still run a coroutine that suspends in `ticker::TimeElapsed`, as long as it can fulfil the condition. This is what makes coroutine libraries shippable.
