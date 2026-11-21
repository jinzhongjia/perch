//! The few POSIX calls the freedesktop backend makes.

const std = @import("std");
const posix = std.posix;
const system = posix.system;

pub const fd_t = posix.fd_t;
pub const pid_t = posix.pid_t;
pub const pollfd = posix.pollfd;
pub const POLL = posix.POLL;

pub fn getpid() pid_t {
    return system.getpid();
}

pub fn getuid() system.uid_t {
    return system.getuid();
}

/// Whether `pid` names a live process. On the fence it answers yes: callers
/// use this to delete a dead process's files, and deleting a live one's is
/// worse than leaving a stale one behind.
pub fn processAlive(pid: pid_t) bool {
    // Signal 0 only checks that the process exists and may be signalled.
    posix.kill(pid, @fromBackingInt(@intCast(0))) catch |err| return err != error.ProcessNotFound;
    return true;
}

/// A non-blocking self-pipe that wakes a `poll` from another thread. eventfd
/// would do on Linux, but a pipe works everywhere.
pub const Wakeup = struct {
    read_end: fd_t,
    write_end: fd_t,

    pub fn open() error{SystemResources}!Wakeup {
        var fds: [2]fd_t = undefined;
        if (posix.errno(system.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS) {
            return error.SystemResources;
        }
        return .{ .read_end = fds[0], .write_end = fds[1] };
    }

    pub fn close(self: Wakeup) void {
        _ = system.close(self.read_end);
        _ = system.close(self.write_end);
    }

    /// Safe from any thread. A full pipe already guarantees a wakeup.
    pub fn signal(self: Wakeup) void {
        const byte = [1]u8{1};
        _ = system.write(self.write_end, &byte, byte.len);
    }

    /// Empties the pipe so the next `poll` blocks again.
    pub fn drain(self: Wakeup) void {
        var buffer: [64]u8 = undefined;
        while (true) {
            const rc = system.read(self.read_end, &buffer, buffer.len);
            if (posix.errno(rc) != .SUCCESS or rc == 0) return;
        }
    }
};

test "a signalled wakeup polls readable until drained" {
    const wakeup = try Wakeup.open();
    defer wakeup.close();

    var fds = [_]pollfd{.{ .fd = wakeup.read_end, .events = POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&fds, 0));

    wakeup.signal();
    wakeup.signal();
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&fds, 0));

    wakeup.drain();
    fds[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&fds, 0));
}

test "processAlive tells our own pid from a free one" {
    try std.testing.expect(processAlive(getpid()));
    // Above every default pid_max, so nothing can be running there.
    try std.testing.expect(!processAlive(std.math.maxInt(i32)));
}
