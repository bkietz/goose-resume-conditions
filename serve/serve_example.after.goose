import std;
import net;
import slot_pool;

struct Conn { fd: i64, inbuf: u8[..4096] = [], outbuf: u8[..4096] = [] }
var conns = slot_pool<Conn> {};

// The protocol from coroutine to scheduler are the conditions
// which the coroutine requires for resumption, expressed as resume
// signatures: each names a condition and the proof resuming from it yields.

struct FileWontBlock { fd: i64, flags: i32 };
resume if FileWontBlock -> net::Event;

struct TimeElapsed { time: i64 };
resume if TimeElapsed ->;

fn fill(conn: Conn&<u32 in conns>) -> bool {
    loop {
        let n = net::recv(conn.fd, conn.inbuf);
        if n != net::AGAIN { return n > 0; }
        // suspend into the FileWontBlock resume condition:
        let ev = resume if FileWontBlock { conn.fd, net::READ };
        if ev.hangup { return false; }
    }
}

fn flush(conn: Conn&<u32 in conns>) -> bool {
    loop {
        let n = net::send(conn.fd, conn.outbuf);
        if n != net::AGAIN { return n > 0; }
        let ev = resume if FileWontBlock { conn.fd, net::WRITE };
        if ev.hangup { return false; }
    }
}

fn serve(conn: Conn&<u32 in conns>) -> Conn&<u32 in conns> {
    loop {
        guard fill(conn) else { break; }
        let consumed = http::respond(conn.inbuf[..], conn.outbuf);
        guard consumed > 0;
        drop_front(conn.inbuf, consumed);
        guard flush(conn) else { break; }
        if conn.should_be_throttled() {
            resume if TimeElapsed { std::now_ns() + THROTTLE_DURATION };
        }
    }
    return conn;
}

thread_fn worker(listen_fd: i64) {
    type ServeTask = suspended<serve>;

    var tasks = slot_pool<ServeTask> {};
    var by_fd: ServeTask?[>..] = [];      // fd -> task waiting on fd
    var timers: Deadline[>..<] = [];      // a heap of (time, task)
    let timer_fd = net::make_timer();

    // Suspension handling is encapsulated in the on_suspend overload
    // set, one overload per resume condition.
    fn on_suspend(task: own ServeTask, b: FileWontBlock) {
        net::watch(b.fd, b.flags);
        by_fd[b.fd] = &tasks.take(task);
    }

    fn on_suspend(task: own ServeTask, u: TimeElapsed) {
        timers.heap_push(Deadline { u.time, &tasks.take(task) }) { l, r => l.time < r.time };
    }

    // A coroutine returning is considered a special case of suspension:
    // a coroutine which returns is considered suspended in the "return" condition.
    fn on_suspend(task: ServeTask&, r: suspended::finished<ServeTask>) {
        conns.free(conns.index_of(r.value));
    }

    loop {
        for ev in net::poll_wait(…) {
            if ev.is_new_connection {
                let conn = conns.alloc_with() { Conn { ev.fd } };
                resume(ServeTask { conn });
                // resuming from the initial state
            }

            let file_task = by_fd[ev.fd];
            if file_task != null {
                by_fd[ev.fd] = null;
                // because the file won't block anymore, resume execution with this event
                resume<FileWontBlock>(tasks.release(file_task), ev);
            }
        }

        while timers.len > 0 && timers[0].time >= std::now_ns() {
            let timer = timers.heap_pop();
            resume<TimeElapsed>(tasks.release(timer.task));
        }

        if timers.len > 0 {
            net::set_timer_for(timer_fd, timers[0].time);
        }

        // …
    }
}

fn main() {
    for i in hardware_threads() {
        thread_spawn(worker, net::listen(8080, true));  // SO_REUSEPORT
    }
    …
}
