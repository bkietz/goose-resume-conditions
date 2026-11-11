// watcher: a library of socket-watching coroutines.
//
// Its suspension needs are ordinary declarations, reusable directly by
// any client package.
import net;
import slot_pool;

namespace watcher;

struct Conn { fd: i64, inbuf: u8[..4096] = [], outbuf: u8[..4096] = [] }
var conns = slot_pool<Conn> {};

// A task suspended in FileWontBlock cannot continue until the descriptor
// `fd` will not block in the direction `flags`; the proof (`event`) says
// which event woke it. Declared once, it is reused by every fd-waiting
// coroutine -- from any package, on any scheduler that handles it.
struct FileWontBlock { fd: i64, flags: net::Flags };
fn resume<T>(task: own T, condition: suspended::awaiting<FileWontBlock>, event: net::Event) {}

// Send one request, then read the response. Returns the byte count that
// arrived, 0 at end of stream, or -1 if the connection went away.
fn wait_data(c: Conn&<u32 in conns>) -> i64 {
    loop {
        let n = net::send(c.fd, c.outbuf);
        if n != net::AGAIN { break; }
        let ev = resume if FileWontBlock { fd: c.fd, flags: net::WRITE };
        if ev.hangup { return -1; }
    }
    loop {
        let n = net::recv(c.fd, c.inbuf);
        if n != net::AGAIN { return n; }
        let ev = resume if FileWontBlock { fd: c.fd, flags: net::READ };
        if ev.hangup { return -1; }
    }
}
