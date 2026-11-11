// The serve example's fill coroutine, driven by a loop that also arms a
// watchdog over the connection. In the original design the Event union is
// the protocol for every suspension of every coroutine in the package: any
// task can be resumed with any Event, and the checker does not know which
// ones fill is prepared for. It is prepared for exactly one.
import std;
import net;
import slot_pool;

struct Conn { fd: i64, inbuf: u8[..4096] = [], outbuf: u8[..4096] = [] }
var conns = slot_pool<Conn> {};

// The watchdog feature added a payload to TimedOut: when the deadline
// passes, the runtime assigns the abandoned read a completion id, and the
// receiver of the event must release that read's kernel-side state with it
// (net::read_done(token)). A timeout is the only event that carries one.
//
// A realistic hardening gives the payload a checked owner -- TimedOut {
// token: own ReadOp& }, the `own` qualifier of ownership.md -- so a dropped
// token becomes a checker error rather than a leak. That fixes the leak but
// not the applicability problem, and the cost does not stay here: see fill
// below and the watchdog branch of run.
enum Wait  { Readable { fd: i64 }, Writable { fd: i64 }, Timer { deadline_ns: i64 } }
enum Event { Ready, TimedOut { token: i64 }, Hangup, Cancel }

coro fn fill(c: Conn&<u32 in conns>) -> bool yield Wait resume Event {
    loop {
        let n = net::recv(c.fd, c.inbuf);
        if n != net::AGAIN { return n > 0; }
        // Exhaustive but dangerous: every Event that is not Ready lands in
        // this else, and the resume value is dropped unread. The checker
        // sees only a total expression over the union -- nothing warns that
        // a TimedOut is inapplicable to a readability wait, and its token
        // dies on this line.
        //
        // Under the own-carrying Event above, this line stops compiling: a
        // comparison copies the resume value and the else path lets it die
        // unconsumed, and the checker rejects both for an own handle. Every
        // yield site of every coroutine sharing this union would instead bind
        // the value and destruct it with an ownership-aware match -- required
        // even at waits a timeout can never apply to -- and keeping the handle
        // alive across the next yield turns the whole frame own (ownership.md
        // §5: design A forbids it outright, design B buys it with cancel).
        guard (yield Wait.Readable { fd: c.fd }) == Event.Ready else { return false; }
    }
}

var tasks = slot_pool<fill> {};
var job = -1;             // the one task's index in tasks, -1 once it is done
var deadline = 0;         // armed whenever fill is suspended; 0 when disarmed
var read_seq = 0;         // completion ids the runtime assigns when a deadline fires
let watchdog_ns = 5 * 1000000000;

fn report(ok: bool) {
    print("fill finished: ", ok);
    // freeing the connection etc. elided
}

// (net is the hypothetical sockets module from the coroutine design's §5;
// net::read_done is part of the same sketch.)
fn run() {
    let c = conns.alloc_ref(Conn { fd: net::dial("slow-peer.internal:80") });
    job = tasks.alloc_index(fill { c: c });
    // A fresh task runs to its first suspension; whatever it yielded is the
    // wait to register -- here always the one Readable wait.
    let w, suspended = resume(tasks[job], Event.Ready);   // the first event is unused: nothing has suspended yet
    guard suspended else { report(result(tasks[job])); tasks.free(job); return; }
    net::watch(c.fd, net::READ);
    deadline = std::now_ns() + watchdog_ns;
    loop {
        for ev in net::poll_wait() {                      // (fd, flags, hangup)
            let w, suspended = resume(tasks[job], if ev.hangup { Event.Hangup } else { Event.Ready });
            guard suspended else { report(result(tasks[job])); tasks.free(job); return; }
            // fill keeps waiting on the same fd: re-arm the window
            deadline = std::now_ns() + watchdog_ns;
        }
        if deadline != 0 && deadline <= std::now_ns() {
            read_seq += 1;
            deadline = 0;
            // The watchdog fires. The maintainer's intent: tell fill its
            // wait ran out, and let it release the abandoned read. This
            // compiles without a diagnostic: TimedOut is a valid Event for
            // fill at any of its suspensions, and fill's guard is total, so
            // neither an applicability nor an exhaustiveness check speaks up.
            let w, suspended = resume(tasks[job], Event.TimedOut { token: read_seq });
            // fill compared the resume value against Event.Ready and gave up
            // as though the peer had hung up. Nobody ever calls
            // net::read_done(read_seq): the abandoned read's kernel-side
            // state is leaked -- its release rode in a payload the control
            // flow never bound, and no diagnostic was required to say so.
            guard suspended else { report(result(tasks[job])); tasks.free(job); net::close(c.fd); return; }
            // fill always finishes on a non-Ready event (every arm of its
            // guard returns false), so this resume cannot suspend again --
            // but had it, or had the task been any other coroutine of the
            // package, the same TimedOut would have compiled here all the same.
        }
    }
}

fn main() { run(); }
