// monitor: composes coroutines from the ticker and watcher libraries into
// one task, and schedules that task.
//
// The imported libraries suspend in their own Wait/Event enums, so this
// package must own the reconciliation: a third Wait/Event protocol of its
// own, one adapter coroutine per imported coroutine, and hand-written
// mappings in both directions between every protocol involved.
//
// Compile from the example directory: goose cross-package-composition.before.goose
import std;
import net;
import slot_pool;
import before.ticker;
import before.watcher;

namespace monitor;

// The scheduler's protocol. It can be neither ticker's (which knows
// nothing of sockets) nor watcher's (which knows nothing of timers):
// composing the two forces this third, hand-merged union. Every foreign
// Wait must land in it and every foreign Event must be derivable from
// its enum, by hand.
enum Wait  { FdReady { fd: i64, flags: net::Flags }, WakeAt { deadline_ns: i64 }, CheckIn }
enum Event { Ready, TimedOut, Hungup, Stop }

enum Status { Polling, PeerDown, Stopped }
let poll_period_ns = 30 * 1000000000;

// --- The translations. Each match is exhaustive over one whole protocol,
// and exhaustiveness is all the checker confirms: which library Event a
// given monitor Event *means* is a convention this file invented. Adding
// an Event to monitor -- or to either library -- forces every one of
// these matches to be re-audited by hand, since the arm that was correct
// yesterday may now silently misfire.

// scheduler Event -> ticker Event
fn as_ticker_event(ev: Event) -> ticker::Event {
    match ev {
        Ready    => ticker::Event.Fired,        // a fd wakeup cannot end a timer; we must still pick
        TimedOut => ticker::Event.Fired,
        Hungup   => ticker::Event.Cancelled,    // no socket ever speaks to a timer; guess anyway
        Stop     => ticker::Event.Cancelled,
    }
}

// scheduler Event -> watcher Event
fn as_watcher_event(ev: Event) -> watcher::Event {
    match ev {
        Ready    => watcher::Event.Ready,
        TimedOut => watcher::Event.Ready,       // read as spurious, by convention
        Hungup   => watcher::Event.Hangup,
        Stop     => watcher::Event.Hangup,      // a stop masquerades as the peer disconnecting
    }
}

// library Wait -> scheduler Wait; the two libraries' vocabularies collide
// here (watcher's two fd Waits collapse into one, and ticker::Wait.Timer
// and a hypothetical watcher timer variant would become indistinguishable)
fn as_wait(w: ticker::Wait) -> Wait {
    match w {
        Timer t => WakeAt { deadline_ns: t.deadline_ns },   // same payload, renamed
    }
}

fn as_wait(w: watcher::Wait) -> Wait {
    match w {
        Readable r => FdReady { fd: r.fd, flags: net::READ },
        Writable r => FdReady { fd: r.fd, flags: net::WRITE },
    }
}

// --- The adapters. A coroutine can only be *called* from a coroutine
// whose yield/resume types match its own (§4.4), so every imported
// coroutine needs one: start its frame as a value, drive it with
// resume(), translate in both directions.
coro fn drive_tick(period_ns: i64) -> i64 yield Wait resume Event {
    var inner = ticker::tick { period_ns };
    var lib_ev = ticker::Event.Fired;   // the first resume runs tick to its first yield; the event is unused
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

coro fn drive_wait_data(c: watcher::Conn&<u32 in watcher::conns>) -> i64 yield Wait resume Event {
    var inner = watcher::wait_data { c };
    var lib_ev = watcher::Event.Ready;  // unused on the first resume, as above
    loop {
        let raw, suspended = resume(inner, lib_ev);
        guard suspended else { return result(inner); }
        let up = as_wait(raw);
        let our_ev = yield up;
        lib_ev = as_watcher_event(our_ev);
    }
}

// The composed coroutine. Only the CheckIn suspension is genuinely ours;
// the libraries' suspensions surface through the adapters above, already
// flattened into this package's union.
coro fn monitor_job(c: watcher::Conn&<u32 in watcher::conns>, period_ns: i64) -> Status yield Wait resume Event {
    loop {
        let n = drive_wait_data(c);
        if n <= 0 { return Status.PeerDown; }
        let end = drive_tick(period_ns);
        if end < 0 { return Status.Stopped; }   // a cancelled tick: stop before polling again
        let ev = yield Wait.CheckIn;            // supervision check-in
        // Which Events *can* arrive at a CheckIn is implicit; anything but
        // Stop is read as "carry on".
        if ev == Event.Stop { return Status.Stopped; }
    }
}

// --- The scheduler. It sees only its own protocol -- but solely because
// the adapters paid to normalize the foreign ones, and its match below is
// already over the merged union, where the libraries' distinctions were
// lost in translation.
var tasks = slot_pool<monitor_job> {};
struct Deadline { at: i64, task: i64 }
var by_fd: i64[>..] = [];                   // fd -> index into tasks, or -1
var timers: Deadline[>..] = [];             // a heap of (deadline, task)
var checkins: i64[>..<] = [];               // tasks parked at Wait.CheckIn
var stop_requested = false;                 // the supervisor's verdict (set outside this sketch)

// One place for the exhaustive match -- but each resume() call site above
// still routes through it, exactly like the serve example's duplicated
// matches it exists to prevent.
fn on_yield(i: i64, w: Wait) {
    match w {
        FdReady f => { net::watch(f.fd, f.flags); by_fd[f.fd] = i; }
        WakeAt t  => timers.heap_push(Deadline { at: t.deadline_ns, task: i }) { l, r => l.at < r.at },
        CheckIn   => checkins.push(i),
    }
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
    resume(monitor_job { c: c, period_ns: poll_period_ns }, Event.Ready);   // the first event is unused: nothing has suspended yet
    loop {
        for ev in net::poll_wait() {                        // (fd, flags, hangup)
            let i = by_fd[ev.fd];
            by_fd[ev.fd] = -1;
            let w, suspended = resume(tasks[i], if ev.hangup { Event.Hungup } else { Event.Ready });
            guard suspended else { report(result(tasks[i])); tasks.free(i); continue; }
            on_yield(i, w);
        }
        while timers.len > 0 && timers[0].at <= std::now_ns() {
            let d = timers.heap_pop();
            let w, suspended = resume(tasks[d.task], Event.TimedOut);
            guard suspended else { report(result(tasks[d.task])); tasks.free(d.task); continue; }
            on_yield(d.task, w);
        }
        if checkins.len > 0 {
            // the supervisor answers asynchronously; here, at the next spin
            let i = checkins.pop();
            let w, suspended = resume(tasks[i], if stop_requested { Event.Stop } else { Event.Ready });
            guard suspended else { report(result(tasks[i])); tasks.free(i); continue; }
            on_yield(i, w);
        }
    }
}

fn ::main() { run(); }
