import std;
import net;
import slot_pool;

struct Conn { fd: i64, inbuf: u8[..4096] = [], outbuf: u8[..4096] = [] }
var conns = slot_pool<Conn> {};

// The protocol between coroutines and the loop is two flat ADTs the library
// defines. A different loop (io_uring, IOCP, a game's frame tick) defines its own.
enum Wait  { Readable { fd: i64 }, Writable { fd: i64 }, Timer { deadline_ns: i64 }, Any }
enum Event { Ready, Timeout, Hangup, Cancel }

// Waiting is the only colored code. recv appends into the limited array and
// returns the byte count, 0 at end of stream, or net::AGAIN.
coro fn fill(c: Conn&<u32 in conns>) -> bool resume Event {
    loop {
        let n = net::recv(c.fd, c.inbuf);
        if n != net::AGAIN { return n > 0; }
        // There's no way to tell from here which Event variants might be emitted;
        // each suspension point must handle them exhaustively.
        guard (yield Wait.Readable { fd: c.fd }) == Event.Ready else { return false; }
    }
}

coro fn flush(c: Conn&<u32 in conns>) -> bool resume Event {
    loop {
        let n = net::send(c.fd, c.outbuf);
        if n != net::AGAIN { return n > 0; }
        guard (yield Wait.Writable { fd: c.fd }) == Event.Ready else { return false; }
    }
}

// The handler is straight-line code; the parser is an ordinary function over
// slices (sans-I/O), usable from blocking code just as well.
coro fn serve(c: Conn&<u32 in conns>) resume Event {
    loop {
        guard fill(c) else { return; }
        let consumed = http::respond(c.inbuf[..], c.outbuf);   // parses, writes a reply
        guard consumed > 0 else { continue; }                  // need more bytes
        drop_front(c.inbuf, consumed);                         // keeps the unparsed tail
        guard flush(c) else { return; }
        if conn.should_be_throttled() {
            yield Wait.Timer { std::now_ns() + THROTTLE_DURATION };
        }
    }
}

// The loop. Frames live in a pool beside the connections; the loop keeps a
// table from fd to frame index for the events the kernel hands back.
var tasks = slot_pool<serve> {};
var by_fd: i64[>..] = [];                                 // fd -> index into tasks, or -1
var timers: Deadline[>..] = [];                           // a heap of (deadline, task)
var ready: i64[>..<] = [];                                // tasks to resume next round

fn run(listen_fd: i64) {
    loop {
        for ev in net::poll_wait(…) {                      // (fd, readable/writable/hangup)
            let i = by_fd[ev.fd];
            let w, suspended = resume(tasks[i], if ev.hangup { Event.Hangup } else { Event.Ready });

            // We have no way to know at this point which Wait variants might be
            // yielded, so we must handle them exhaustively here

            guard suspended else {
                conns.free(conns.index_of(tasks[i].c)); tasks.free(i); net::close(ev.fd);
                continue;
            }
            match w {
                Readable r => net::watch(r.fd, net::READ, i),
                Writable r => net::watch(r.fd, net::WRITE, i),
                Timer t    => timers.heap_push(Deadline { at: t.deadline_ns, task: i }),
                Any        => ready.push(i),
            }
        }
        
        while timers.len > 0 && timers[0].at >= std::now_ns() {
            let timer = timers.heap_pop();
            let i = timer.i
            let w, suspended = resume(tasks[i]);

            // Each resume() call site produces a `Wait`, so every resume call site
            // needs to reiterate their exhaustive handling
            // (or extract an `on_suspend`-like function).

            guard suspended else {
                conns.free(conns.index_of(tasks[i].c)); tasks.free(i); net::close(ev.fd);
                continue;
            }
            match w {
                Readable r => net::watch(r.fd, net::READ, i),
                Writable r => net::watch(r.fd, net::WRITE, i),
                Timer t    => timers.heap_push(Deadline { at: t.deadline_ns, task: i }),
                Any        => ready.push(i),
            }
        }

        if timers.len > 0 {
            net::set_timer_for(timer_fd, timers[0].time);
        }

        // …
    }
}

// Thread-per-core: each worker is a program instance with its own copies of
// conns, tasks and by_fd (§11.2), accepting on its own SO_REUSEPORT socket.
thread_fn worker(listen_fd: i64) { run(listen_fd); }

fn main() {
    for i in hardware_threads() { thread_spawn(worker, net::listen(8080, true)); }   // SO_REUSEPORT
    …
}
