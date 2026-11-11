// ticker: a library of timer coroutines.
//
// This library declares the Wait/Event pair it was designed with.
// The pair is package-local: another timer library could reuse the same
// variant names with different meanings, and nothing in the type system
// would distinguish them once translated into a client's protocol.
import std;

namespace ticker;

enum Wait  { Timer { deadline_ns: i64 } }
enum Event { Fired, Cancelled }

// Wait one period and report when it ends, or -1 if the wait was cancelled.
// Cancellation needs an Event of its own because the only way a scheduler
// can interrupt the wait is through a yield's resume value.
coro fn tick(period_ns: i64) -> i64 yield Wait resume Event {
    let end = std::now_ns() + period_ns;
    let ev = yield Wait.Timer { deadline_ns: end };
    if ev == Event.Cancelled { return -1; }
    return end;
}
