// monitor: composes coroutines from the ticker and watcher libraries into
// one task, and schedules that task.
//
// With resume conditions, an imported coroutine's suspension needs are
// ordinary declarations that arrive with the import. monitor_job calls
// the libraries as plain functions -- no adapters -- and the scheduler
// answers each condition (its own and the imported ones) with a single
// on_suspend overload.
//
// Compile from the example directory: goose cross-package-composition.after.goose
import std;
import net;
import slot_pool;
import after.ticker;     // brings ticker::tick and ticker::TimeElapsed
import after.watcher;    // brings watcher::wait_data and watcher::FileWontBlock

namespace monitor;

// monitor's own condition: monitor_job cannot continue until the
// supervisor has answered; the proof carries the verdict.
resume if SupervisorAnswered -> bool;

enum Status { Polling, PeerDown, Stopped }
let poll_period_ns = 30 * 1000000000;

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

// The scheduler's task type and state (one job here; the loop below is
// the point).
type MonitorTask = suspended<monitor_job>;
var tasks = slot_pool<MonitorTask> {};
struct Deadline { time: i64, task: MonitorTask&<u32 in tasks> }
var by_fd: MonitorTask?[>..] = [];           // fd -> the task waiting on it
var timers: Deadline[>..<] = [];             // a heap of (deadline, task)
var awaiting_verdict: MonitorTask? = null;   // a task parked at SupervisorAnswered
var stop_requested = false;                  // the supervisor's verdict (set outside this sketch)

// Suspension handling is one overload per condition. The two imported
// conditions are handled exactly like our own: a new library's conditions
// would ship here as more overloads, and a condition two libraries share
// (any fd-waiting coroutine's FileWontBlock) reuses the same one.
fn on_suspend(task: own MonitorTask, b: watcher::FileWontBlock) {
    net::watch(b.fd, b.flags);
    by_fd[b.fd] = &tasks.take(task);
}

fn on_suspend(task: own MonitorTask, t: ticker::TimeElapsed) {
    timers.heap_push(Deadline { time: t.time, task: &tasks.take(task) }) { l, r => l.time < r.time };
}

fn on_suspend(task: own MonitorTask, s: SupervisorAnswered) {
    awaiting_verdict = &tasks.take(task);
}

// A coroutine returning is just another suspended state; this handler
// does not take ownership of the finished task.
fn on_suspend(task: MonitorTask&, r: suspended::finished<MonitorTask>) {
    report(r.value);
}

fn report(s: Status) {
    print("monitor job finished: ", s);
    // freeing the connection etc. elided
}

// One job, started by run(). A fuller loop would accept connections and
// start a task per job; the protocol handling is the point here.
// (net is the hypothetical sockets module from the coroutine design's §5.)
fn run() {
    let c = watcher::conns.alloc_ref(watcher::Conn { fd: net::dial("config.internal:80") });
    resume(MonitorTask { c: c, period_ns: poll_period_ns });
    loop {
        for ev in net::poll_wait() {                         // (fd, flags, hangup)
            let t = by_fd[ev.fd];
            if t != null {
                by_fd[ev.fd] = null;
                // the fd will not block any more; the event says what happened
                resume<watcher::FileWontBlock>(tasks.release(t), ev);
            }
        }
        while timers.len > 0 && timers[0].time <= std::now_ns() {
            let d = timers.heap_pop();
            resume<ticker::TimeElapsed>(tasks.release(d.task));
        }
        // the supervisor answers asynchronously; here, at the next spin
        let v = awaiting_verdict;
        awaiting_verdict = null;
        if v != null {
            resume<SupervisorAnswered>(tasks.release(v), stop_requested);
        }
    }
}

fn ::main() { run(); }
