// ticker: a library of timer coroutines.
//
// A library's suspension needs are declared here as resume conditions --
// named, typed contracts any scheduler can read, document, and fulfil.
// They are exported declarations like any other, so clients compose them
// without translating anything.
import std;

namespace ticker;

// A task suspended in TimeElapsed cannot continue until the instant
// `time` has passed. Nothing in the shape is ticker-specific, so
// coroutines from other packages can suspend in the same condition.
struct TimeElapsed { time: i64 };
fn resume<T>(task: own T, condition: suspended::awaiting<TimeElapsed>) {}

// Wait one period and report when it ends. Cancellation needs no protocol
// here: the composed task is cancelled whole by the scheduler, or simply
// ticked again never.
fn tick(period_ns: i64) -> i64 {
    let end = std::now_ns() + period_ns;
    resume if TimeElapsed { time: end };
    return end;
}
