// watcher: a library of socket-watching coroutines, with a protocol of
// its own -- coordinated with nothing.
import net;
import slot_pool;

namespace watcher;

enum Wait  { Readable { fd: i64 }, Writable { fd: i64 } }
enum Event { Ready, Hangup }

// Send one request, then read the response. Returns the byte count that
// arrived, 0 at end of stream, or -1 if the connection went away.
coro fn wait_data(c: Conn&) -> i64 yield Wait resume Event {
    loop {
        let n = net::send(c.fd, c.outbuf);
        if n != net::AGAIN { break; }
        guard (yield Wait.Writable { fd: c.fd }) == Event.Ready else { return -1; }
    }
    loop {
        let n = net::recv(c.fd, c.inbuf);
        if n != net::AGAIN { return n; }
        guard (yield Wait.Readable { fd: c.fd }) == Event.Ready else { return -1; }
    }
}
