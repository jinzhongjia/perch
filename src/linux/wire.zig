//! D-Bus wire format marshalling.
//!
//! The format is described in the D-Bus specification: every value is aligned to
//! its natural boundary *relative to the start of the message*, and the padding
//! bytes must be zero. Bodies always begin at an 8-aligned offset, so a body can
//! be marshalled on its own and concatenated afterwards.

const std = @import("std");
const assert = std.debug.assert;

pub const Endian = std.builtin.Endian;

/// Single-character type codes used in signatures.
pub const Type = enum(u8) {
    byte = 'y',
    boolean = 'b',
    int16 = 'n',
    uint16 = 'q',
    int32 = 'i',
    uint32 = 'u',
    int64 = 'x',
    uint64 = 't',
    double = 'd',
    string = 's',
    object_path = 'o',
    signature = 'g',
    unix_fd = 'h',
    array = 'a',
    struct_begin = '(',
    struct_end = ')',
    dict_begin = '{',
    dict_end = '}',
    variant = 'v',
};

/// Alignment of a value whose signature starts with `code`.
pub fn alignOf(code: u8) error{Malformed}!usize {
    return switch (code) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 'h', 's', 'o', 'a' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => error.Malformed,
    };
}

/// Length in bytes of the first complete type in `sig`.
pub fn typeLen(sig: []const u8) error{Malformed}!usize {
    if (sig.len == 0) return error.Malformed;
    switch (sig[0]) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h', 'v' => return 1,
        'a' => return 1 + try typeLen(sig[1..]),
        '(', '{' => {
            const close: u8 = if (sig[0] == '(') ')' else '}';
            var depth: usize = 0;
            for (sig, 0..) |c, i| {
                switch (c) {
                    '(', '{' => depth += 1,
                    ')', '}' => {
                        depth -= 1;
                        if (depth == 0) {
                            if (c != close) return error.Malformed;
                            return i + 1;
                        }
                    },
                    else => {},
                }
            }
            return error.Malformed;
        },
        else => return error.Malformed,
    }
}

/// Marshals values into a growable buffer. Always little-endian; the header
/// advertises `'l'` to match.
pub const Writer = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub const Error = std.mem.Allocator.Error;

    pub fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn bytes(self: *const Writer) []const u8 {
        return self.buf.items;
    }

    pub fn len(self: *const Writer) usize {
        return self.buf.items.len;
    }

    pub fn clearRetainingCapacity(self: *Writer) void {
        self.buf.clearRetainingCapacity();
    }

    /// Drops everything written past `mark`, for rolling back a value that
    /// turned out not to apply. Never move a marshalled value to a different
    /// offset: alignment is relative to the start of the message.
    pub fn truncate(self: *Writer, mark: usize) void {
        self.buf.shrinkRetainingCapacity(mark);
    }

    /// Zero-fills up to the next multiple of `alignment`.
    pub fn pad(self: *Writer, alignment: usize) Error!void {
        const rem = self.buf.items.len % alignment;
        if (rem != 0) try self.buf.appendNTimes(self.gpa, 0, alignment - rem);
    }

    pub fn raw(self: *Writer, data: []const u8) Error!void {
        try self.buf.appendSlice(self.gpa, data);
    }

    pub fn byte(self: *Writer, value: u8) Error!void {
        try self.buf.append(self.gpa, value);
    }

    pub fn int(self: *Writer, comptime T: type, value: T) Error!void {
        try self.pad(@sizeOf(T));
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, value, .little);
        try self.buf.appendSlice(self.gpa, &tmp);
    }

    pub fn boolean(self: *Writer, value: bool) Error!void {
        try self.int(u32, @intFromBool(value));
    }

    pub fn double(self: *Writer, value: f64) Error!void {
        try self.int(u64, @bitCast(value));
    }

    /// `s` and `o`: length-prefixed and nul-terminated.
    pub fn string(self: *Writer, value: []const u8) Error!void {
        try self.int(u32, @intCast(value.len));
        try self.buf.appendSlice(self.gpa, value);
        try self.buf.append(self.gpa, 0);
    }

    pub fn objectPath(self: *Writer, value: []const u8) Error!void {
        try self.string(value);
    }

    /// `g`: a single length byte, then nul-terminated.
    pub fn signature(self: *Writer, value: []const u8) Error!void {
        try self.byte(@intCast(value.len));
        try self.buf.appendSlice(self.gpa, value);
        try self.buf.append(self.gpa, 0);
    }

    pub const Array = struct { len_at: usize, start: usize };

    /// Arrays are a byte count followed by the elements; the count excludes the
    /// padding inserted before the first element, which is why it is patched in
    /// by `arrayEnd`.
    pub fn arrayBegin(self: *Writer, element_signature: []const u8) Error!Array {
        try self.pad(4);
        const len_at = self.buf.items.len;
        try self.buf.appendNTimes(self.gpa, 0, 4);
        try self.pad(alignOf(element_signature[0]) catch unreachable);
        return .{ .len_at = len_at, .start = self.buf.items.len };
    }

    pub fn arrayEnd(self: *Writer, array: Array) void {
        const byte_len: u32 = @intCast(self.buf.items.len - array.start);
        std.mem.writeInt(u32, self.buf.items[array.len_at..][0..4], byte_len, .little);
    }

    /// Structs and dict entries are 8-aligned with no length prefix.
    pub fn structBegin(self: *Writer) Error!void {
        try self.pad(8);
    }

    pub fn dictEntryBegin(self: *Writer) Error!void {
        try self.pad(8);
    }

    /// Writes a variant's signature; the caller writes the value next.
    pub fn variantBegin(self: *Writer, value_signature: []const u8) Error!void {
        try self.signature(value_signature);
    }

    pub fn variantString(self: *Writer, value: []const u8) Error!void {
        try self.variantBegin("s");
        try self.string(value);
    }

    pub fn variantObjectPath(self: *Writer, value: []const u8) Error!void {
        try self.variantBegin("o");
        try self.objectPath(value);
    }

    pub fn variantBool(self: *Writer, value: bool) Error!void {
        try self.variantBegin("b");
        try self.boolean(value);
    }

    pub fn variantInt32(self: *Writer, value: i32) Error!void {
        try self.variantBegin("i");
        try self.int(i32, value);
    }

    pub fn variantUint32(self: *Writer, value: u32) Error!void {
        try self.variantBegin("u");
        try self.int(u32, value);
    }

    pub fn variantByteArray(self: *Writer, value: []const u8) Error!void {
        try self.variantBegin("ay");
        const array = try self.arrayBegin("y");
        try self.raw(value);
        self.arrayEnd(array);
    }

    /// A `{sv}` entry holding a string.
    pub fn dictStringVariantString(self: *Writer, key: []const u8, value: []const u8) Error!void {
        try self.dictEntryBegin();
        try self.string(key);
        try self.variantString(value);
    }

    pub fn dictStringVariantBool(self: *Writer, key: []const u8, value: bool) Error!void {
        try self.dictEntryBegin();
        try self.string(key);
        try self.variantBool(value);
    }

    pub fn dictStringVariantInt32(self: *Writer, key: []const u8, value: i32) Error!void {
        try self.dictEntryBegin();
        try self.string(key);
        try self.variantInt32(value);
    }

    pub fn dictStringVariantByteArray(self: *Writer, key: []const u8, value: []const u8) Error!void {
        try self.dictEntryBegin();
        try self.string(key);
        try self.variantByteArray(value);
    }
};

pub const ReadError = error{Malformed};

/// Unmarshals values from a message body. Slices point into the source buffer.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    endian: Endian = .little,

    pub fn init(data: []const u8, endian: Endian) Reader {
        return .{ .data = data, .endian = endian };
    }

    pub fn atEnd(self: *const Reader) bool {
        return self.pos >= self.data.len;
    }

    pub fn remaining(self: *const Reader) usize {
        return self.data.len - self.pos;
    }

    /// Skips padding. The specification requires the skipped bytes to be zero.
    pub fn pad(self: *Reader, alignment: usize) ReadError!void {
        const rem = self.pos % alignment;
        if (rem == 0) return;
        const skip_n = alignment - rem;
        if (self.remaining() < skip_n) return error.Malformed;
        for (self.data[self.pos..][0..skip_n]) |b| if (b != 0) return error.Malformed;
        self.pos += skip_n;
    }

    pub fn take(self: *Reader, n: usize) ReadError![]const u8 {
        if (self.remaining() < n) return error.Malformed;
        defer self.pos += n;
        return self.data[self.pos..][0..n];
    }

    pub fn byte(self: *Reader) ReadError!u8 {
        return (try self.take(1))[0];
    }

    pub fn int(self: *Reader, comptime T: type) ReadError!T {
        try self.pad(@sizeOf(T));
        const slice = try self.take(@sizeOf(T));
        return std.mem.readInt(T, slice[0..@sizeOf(T)], self.endian);
    }

    pub fn boolean(self: *Reader) ReadError!bool {
        return switch (try self.int(u32)) {
            0 => false,
            1 => true,
            else => error.Malformed,
        };
    }

    pub fn double(self: *Reader) ReadError!f64 {
        return @bitCast(try self.int(u64));
    }

    pub fn string(self: *Reader) ReadError![]const u8 {
        const n = try self.int(u32);
        const value = try self.take(n);
        if (try self.byte() != 0) return error.Malformed;
        return value;
    }

    pub fn objectPath(self: *Reader) ReadError![]const u8 {
        return self.string();
    }

    pub fn signature(self: *Reader) ReadError![]const u8 {
        const n = try self.byte();
        const value = try self.take(n);
        if (try self.byte() != 0) return error.Malformed;
        return value;
    }

    /// Start of an array; returns the offset one past its last element.
    pub fn arrayBegin(self: *Reader, element_signature: []const u8) ReadError!usize {
        const byte_len = try self.int(u32);
        try self.pad(try alignOf(element_signature[0]));
        if (self.remaining() < byte_len) return error.Malformed;
        return self.pos + byte_len;
    }

    pub fn structBegin(self: *Reader) ReadError!void {
        try self.pad(8);
    }

    pub fn dictEntryBegin(self: *Reader) ReadError!void {
        try self.pad(8);
    }

    /// Reads a variant's signature; the caller reads the value next.
    pub fn variantBegin(self: *Reader) ReadError![]const u8 {
        return self.signature();
    }

    /// Discards one complete value of type `sig`, however deeply nested.
    pub fn skip(self: *Reader, sig: []const u8) ReadError!void {
        if (sig.len == 0) return error.Malformed;
        switch (sig[0]) {
            'y' => _ = try self.byte(),
            'b' => _ = try self.int(u32),
            'n' => _ = try self.int(i16),
            'q' => _ = try self.int(u16),
            'i', 'h' => _ = try self.int(i32),
            'u' => _ = try self.int(u32),
            'x' => _ = try self.int(i64),
            't' => _ = try self.int(u64),
            'd' => _ = try self.int(u64),
            's', 'o' => _ = try self.string(),
            'g' => _ = try self.signature(),
            'v' => {
                const inner = try self.variantBegin();
                // A variant holds exactly one complete type.
                if (try typeLen(inner) != inner.len) return error.Malformed;
                try self.skip(inner);
            },
            'a' => {
                const element = sig[1..];
                const element_len = try typeLen(element);
                const end = try self.arrayBegin(element);
                while (self.pos < end) try self.skip(element[0..element_len]);
                if (self.pos != end) return error.Malformed;
            },
            '(', '{' => {
                const total = try typeLen(sig);
                try self.pad(8);
                var inner = sig[1 .. total - 1];
                while (inner.len > 0) {
                    const n = try typeLen(inner);
                    try self.skip(inner[0..n]);
                    inner = inner[n..];
                }
            },
            else => return error.Malformed,
        }
    }
};

test "typeLen handles nesting" {
    try std.testing.expectEqual(@as(usize, 1), try typeLen("s"));
    try std.testing.expectEqual(@as(usize, 2), try typeLen("as"));
    try std.testing.expectEqual(@as(usize, 5), try typeLen("a{sv}"));
    try std.testing.expectEqual(@as(usize, 10), try typeLen("(ia{sv}av)x"));
    try std.testing.expectError(error.Malformed, typeLen("a"));
    try std.testing.expectError(error.Malformed, typeLen("(s"));
}

test "scalars round-trip with correct padding" {
    var w: Writer = .init(std.testing.allocator);
    defer w.deinit();

    try w.byte(7);
    try w.int(u32, 0xdeadbeef); // must land at offset 4
    try w.int(u64, 42); // must land at offset 8
    try w.string("hello");
    try w.boolean(true);

    try std.testing.expectEqual(@as(u8, 0), w.bytes()[1]);
    try std.testing.expectEqual(@as(u8, 0xef), w.bytes()[4]);

    var r: Reader = .init(w.bytes(), .little);
    try std.testing.expectEqual(@as(u8, 7), try r.byte());
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), try r.int(u32));
    try std.testing.expectEqual(@as(u64, 42), try r.int(u64));
    try std.testing.expectEqualStrings("hello", try r.string());
    try std.testing.expectEqual(true, try r.boolean());
    try std.testing.expect(r.atEnd());
}

test "array of dict entries round-trips" {
    var w: Writer = .init(std.testing.allocator);
    defer w.deinit();

    const array = try w.arrayBegin("{sv}");
    try w.dictStringVariantString("label", "Quit");
    try w.dictStringVariantBool("enabled", true);
    try w.dictStringVariantInt32("toggle-state", 1);
    w.arrayEnd(array);

    var r: Reader = .init(w.bytes(), .little);
    const end = try r.arrayBegin("{sv}");
    var seen: usize = 0;
    while (r.pos < end) {
        try r.dictEntryBegin();
        const key = try r.string();
        const value_sig = try r.variantBegin();
        switch (seen) {
            0 => {
                try std.testing.expectEqualStrings("label", key);
                try std.testing.expectEqualStrings("s", value_sig);
                try std.testing.expectEqualStrings("Quit", try r.string());
            },
            1 => {
                try std.testing.expectEqualStrings("enabled", key);
                try std.testing.expectEqual(true, try r.boolean());
            },
            else => {
                try std.testing.expectEqualStrings("toggle-state", key);
                try std.testing.expectEqual(@as(i32, 1), try r.int(i32));
            },
        }
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expectEqual(end, r.pos);
}

test "skip walks over values it does not understand" {
    var w: Writer = .init(std.testing.allocator);
    defer w.deinit();

    // (i a{sv} av) — the dbusmenu layout shape.
    try w.structBegin();
    try w.int(i32, 3);
    const props = try w.arrayBegin("{sv}");
    try w.dictStringVariantString("type", "separator");
    w.arrayEnd(props);
    const children = try w.arrayBegin("v");
    try w.variantString("child");
    w.arrayEnd(children);
    try w.int(u32, 0xcafe); // sentinel after the value we skip

    var r: Reader = .init(w.bytes(), .little);
    try r.skip("(ia{sv}av)");
    try std.testing.expectEqual(@as(u32, 0xcafe), try r.int(u32));
    try std.testing.expect(r.atEnd());
}

test "padding must be zero" {
    var bad: [8]u8 = @splat(0);
    bad[0] = 1; // a byte, then a u32 whose padding is dirty
    bad[1] = 0xff;
    var r: Reader = .init(&bad, .little);
    try std.testing.expectEqual(@as(u8, 1), try r.byte());
    try std.testing.expectError(error.Malformed, r.int(u32));
}
