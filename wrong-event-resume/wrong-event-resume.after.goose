// The same fill coroutine and the same watchdog loop, under resume
// conditions. A suspension can only be resumed through the overload of the
// condition it suspended in, with the proof that overload declares: the
// checker, not convention, decides whether a resume fits the wait.
import std;
import net;
import slot_pool;

struct Conn { fd: i64, inbuf: u8[..4096] = [], outbuf: u8[..4096] = [] }
var conns = slot_pool<Conn> {};

// fill cannot continue until the descriptor will not block; the proof is
// exactly the event that woke it. A timeout cannot be delivered through
// this wait by anyone, ever: this resume signature is fill's entire
// response surface for the wait. An owned release token, where one is
// genuinely called for, would appear in exactly one condition's
// signature, paid for only by coroutines that suspend there.
struct FileWontBlock { fd: i64, flags: net::Flags };
resume if FileWontBlock -> net::Event;

fn fill(c: Conn&<u32 in conns>) -> bool {
    loop {
        let n = net::recv(c.fd, c.inbuf);
        if n != net::AGAIN { return n > 0; }
        // This suspension has one continuation -- resume<FileWontBlock> with
        // a net::Event proof. Whatever wakes fill, it is an fd event, and
        // fill is ready for it by construction.
        let ev = resume if FileWontBlock { fd: c.fd, flags: net::READ };
        if ev.hangup { return false; }
    }
}

type FillTask = suspended<fill>;
var tasks = slot_pool<FillTask> {};
var job: FillTask? = null;   // the one task, parked wherever it suspended
var deadline = 0;            // armed for the pending wait; 0 when disarmed
let watchdog_ns = 5 * 1000000000;

fn report(ok: bool) {
    print("fill finished: ", ok);
    // freeing the connection etc. elided
}

// The deadline is armed by the side that owns the watch table, at the
// moment the wait is registered: no token has to survive a trip through
// the coroutine, so there is no receiver that could drop one.
fn on_suspend(task: own FillTask, b: FileWontBlock) {
    net::watch(b.fd, b.flags);
    deadline = std::now_ns() + watchdog_ns;
    job = &tasks.take(task);
}

fn on_suspend(task: FillTask&, r: suspended::finished<FillTask>) {
    report(r.value);
    // a watchdogged fill that gives up returns false and ends here; the
    // deadline entry was disarmed by the branch that ended it, not by a
    // payload somebody forgot to inspect
}

fn run() {
    let c = conns.alloc_ref(Conn { fd: net::dial("slow-peer.internal:80") });
    resume(FillTask { c: c });
    loop {
        if job == null { return; }         // the task finished in a previous resume
        for ev in net::poll_wait() {       // (fd, flags, hangup)
            let t = job;
            if t != null {
                job = null;
                deadline = 0;              // the wait is over: the deadline entry is ours again
                resume<FileWontBlock>(tasks.release(t), ev);
            }
        }
        let t = job;
        if t != null && deadline != 0 && deadline <= std::now_ns() {
            // The watchdog fires with the same intent as in the before
            // version: tell fill its wait ran out, and hand it the abandoned
            // read's completion id. That resume has no spelling here:
            //
            //   resume<FileWontBlock>(tasks.release(t), read_id);
            //
            // does not compile: this signature's proof is a net::Event, not
            // an i64, and no Event union exists to name a Timeout variant.
            // A payload fill would never look at cannot be constructed --
            // let alone dropped in a guard comparison -- because the proof
            // type is decided by the condition, not by whoever calls.
            //
            // Ending the wait is the scheduler's own act, on its own table:
            deadline = 0;
            job = null;
            cancel(tasks.release(t));
        }
    }
}

fn main() { run(); }
