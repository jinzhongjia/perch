//! `com.canonical.dbusmenu`: exposes a perch `Menu` as the layout tree that
//! StatusNotifierItem hosts render.
//!
//! Everything here is a pure function of the menu, so the wire output can be
//! tested without a bus.

const std = @import("std");

const image = @import("../image.zig");
const menu_mod = @import("../menu.zig");
const Menu = menu_mod.Menu;
const MenuItem = menu_mod.MenuItem;
const wire = @import("wire.zig");

pub const interface = "com.canonical.dbusmenu";
pub const object_path = "/MenuBar";

/// Protocol revision we implement.
pub const version: u32 = 3;

/// Signature of one layout node, and of the whole `GetLayout` reply.
pub const node_signature = "(ia{sv}av)";
pub const get_layout_signature = "u(ia{sv}av)";

/// The root of the tree is always id 0, which is why perch menu ids start at 1.
pub const root_id: i32 = 0;

pub const Error = wire.Writer.Error;

/// A node is either the root, standing for the menu itself, or one item.
pub const Node = union(enum) {
    root: *Menu,
    item: *const MenuItem,

    pub fn id(self: Node) i32 {
        return switch (self) {
            .root => root_id,
            .item => |item| @intCast(item.id),
        };
    }

    fn children(self: Node) ?*Menu {
        return switch (self) {
            .root => |m| m,
            .item => |item| item.submenu,
        };
    }
};

/// Resolves a dbusmenu id against `menu`.
pub fn findNode(menu: *Menu, id: i32) ?Node {
    if (id == root_id) return .{ .root = menu };
    if (id < 0) return null;
    const item = menu.find(@intCast(id)) orelse return null;
    return .{ .item = item };
}

/// The `propertyNames` argument of `GetLayout` and `GetGroupProperties`. An
/// empty list means the client wants everything.
pub const Filter = struct {
    names: []const []const u8 = &.{},

    pub const all: Filter = .{};

    pub fn wants(self: Filter, name: []const u8) bool {
        if (self.names.len == 0) return true;
        for (self.names) |candidate| {
            if (std.mem.eql(u8, candidate, name)) return true;
        }
        return false;
    }
};

/// Writes one `(ia{sv}av)` node and, unless `depth` is 0, its children.
/// A negative `depth` recurses without limit, matching `GetLayout`.
pub fn writeNode(w: *wire.Writer, node: Node, depth: i32, filter: Filter) Error!void {
    try w.structBegin();
    try w.int(i32, node.id());

    const properties = try w.arrayBegin("{sv}");
    try writeNodeProperties(w, node, filter);
    w.arrayEnd(properties);

    const children = try w.arrayBegin("v");
    if (depth != 0) {
        const next_depth = if (depth < 0) depth else depth - 1;
        if (node.children()) |sub| {
            for (sub.items.items) |*child| {
                try w.variantBegin(node_signature);
                try writeNode(w, .{ .item = child }, next_depth, filter);
            }
        }
    }
    w.arrayEnd(children);
}

/// The body of a `GetGroupProperties` reply: `a(ia{sv})`.
pub fn writeGroupProperties(
    w: *wire.Writer,
    menu: *Menu,
    ids: []const i32,
    filter: Filter,
) Error!void {
    const array = try w.arrayBegin("(ia{sv})");
    for (ids) |id| {
        const node = findNode(menu, id) orelse continue;
        try w.structBegin();
        try w.int(i32, node.id());
        const properties = try w.arrayBegin("{sv}");
        try writeNodeProperties(w, node, filter);
        w.arrayEnd(properties);
    }
    w.arrayEnd(array);
    return;
}

/// Every property perch can produce, in the order they are emitted.
pub const property_names = [_][]const u8{
    "type",
    "label",
    "enabled",
    "visible",
    "toggle-type",
    "toggle-state",
    "children-display",
    "icon-name",
    "icon-data",
    "shortcut",
    "accessible-desc",
};

/// Writes an item's `{sv}` entries, without the enclosing array.
pub fn writeNodeProperties(w: *wire.Writer, node: Node, filter: Filter) Error!void {
    for (property_names) |name| {
        if (!filter.wants(name)) continue;
        // The key has to be written before we know whether the value applies,
        // so roll back rather than moving the value afterwards.
        const mark = w.len();
        try w.dictEntryBegin();
        try w.string(name);
        if (!try writeNodeProperty(w, node, name)) w.truncate(mark);
    }
}

/// Writes just the variant holding `name`'s value, so callers that need one
/// property (`GetProperty`) can marshal it at the start of a body. Returns false
/// when this node has no such property.
pub fn writeNodeProperty(w: *wire.Writer, node: Node, name: []const u8) Error!bool {
    const item = switch (node) {
        // The root is only ever a container.
        .root => {
            if (!std.mem.eql(u8, name, "children-display")) return false;
            try w.variantString("submenu");
            return true;
        },
        .item => |item| item,
    };

    if (item.kind == .separator) {
        // A separator carries nothing but its type.
        if (!std.mem.eql(u8, name, "type")) return false;
        try w.variantString("separator");
        return true;
    }

    if (std.mem.eql(u8, name, "label")) {
        try w.variantBegin("s");
        try writeMnemonicEscaped(w, item.label);
        return true;
    }
    if (std.mem.eql(u8, name, "enabled")) {
        try w.variantBool(item.enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "visible")) {
        try w.variantBool(true);
        return true;
    }
    if (std.mem.eql(u8, name, "toggle-type")) {
        switch (item.kind) {
            .checkbox => try w.variantString("checkmark"),
            .radio => try w.variantString("radio"),
            else => return false,
        }
        return true;
    }
    if (std.mem.eql(u8, name, "toggle-state")) {
        switch (item.kind) {
            .checkbox, .radio => try w.variantInt32(@intFromBool(item.checked)),
            else => return false,
        }
        return true;
    }
    if (std.mem.eql(u8, name, "children-display")) {
        if (item.kind != .submenu) return false;
        try w.variantString("submenu");
        return true;
    }
    if (std.mem.eql(u8, name, "icon-name")) {
        const icon = item.icon orelse return false;
        const themed = icon.themedName() orelse return false;
        try w.variantString(themed);
        return true;
    }
    if (std.mem.eql(u8, name, "icon-data")) {
        const icon = item.icon orelse return false;
        // dbusmenu specifies PNG here, so bytes go straight through — but only
        // when they really are PNG. Other formats would render as nothing, and a
        // themed name is a better fallback than a broken image.
        const data = icon.encodedBytes() orelse return false;
        if (image.sniff(data) != .png) return false;
        try w.variantByteArray(data);
        return true;
    }
    if (std.mem.eql(u8, name, "shortcut")) {
        const accelerator = item.accelerator orelse return false;
        try w.variantBegin("aas");
        try writeShortcut(w, accelerator);
        return true;
    }
    if (std.mem.eql(u8, name, "accessible-desc")) {
        // dbusmenu has no tooltip property; the accessible description is the
        // closest thing hosts actually read out.
        const tooltip = item.tooltip orelse return false;
        try w.variantString(tooltip);
        return true;
    }
    return false;
}

/// dbusmenu treats `_` as the mnemonic marker, so a literal one must be doubled.
fn writeMnemonicEscaped(w: *wire.Writer, label: []const u8) Error!void {
    const extra = std.mem.count(u8, label, "_");
    if (extra == 0) return w.string(label);

    try w.int(u32, @intCast(label.len + extra));
    for (label) |c| {
        try w.byte(c);
        if (c == '_') try w.byte('_');
    }
    try w.byte(0);
}

/// `"Ctrl+Shift+Q"` becomes `[["Control", "Shift", "q"]]`.
fn writeShortcut(w: *wire.Writer, accelerator: []const u8) Error!void {
    const outer = try w.arrayBegin("as");
    const inner = try w.arrayBegin("s");

    var parts = std.mem.splitScalar(u8, accelerator, '+');
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        if (part.len == 0) continue;
        if (eqlIgnoreCase(part, "ctrl") or eqlIgnoreCase(part, "control")) {
            try w.string("Control");
        } else if (eqlIgnoreCase(part, "alt")) {
            try w.string("Alt");
        } else if (eqlIgnoreCase(part, "shift")) {
            try w.string("Shift");
        } else if (eqlIgnoreCase(part, "super") or eqlIgnoreCase(part, "meta") or eqlIgnoreCase(part, "cmd")) {
            try w.string("Super");
        } else if (part.len == 1) {
            try w.string(&[_]u8{std.ascii.toLower(part[0])});
        } else {
            try w.string(part);
        }
    }

    w.arrayEnd(inner);
    w.arrayEnd(outer);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// The `eventId` strings hosts send to `Event`.
pub const Event = enum {
    clicked,
    hovered,
    opened,
    closed,
    unknown,

    pub fn parse(name: []const u8) Event {
        return std.meta.stringToEnum(Event, name) orelse .unknown;
    }
};

// -- tests ------------------------------------------------------------------

/// Walks a `(ia{sv}av)` node, collecting ids and labels depth-first.
const Walker = struct {
    r: *wire.Reader,
    out: *std.ArrayList(Entry),
    gpa: std.mem.Allocator,

    const Entry = struct { id: i32, depth: usize, label: ?[]const u8, type_: ?[]const u8 };

    fn node(self: Walker, depth: usize) !void {
        try self.r.structBegin();
        const id = try self.r.int(i32);

        var label: ?[]const u8 = null;
        var type_: ?[]const u8 = null;
        const props_end = try self.r.arrayBegin("{sv}");
        while (self.r.pos < props_end) {
            try self.r.dictEntryBegin();
            const key = try self.r.string();
            const sig = try self.r.variantBegin();
            if (std.mem.eql(u8, key, "label")) {
                label = try self.r.string();
            } else if (std.mem.eql(u8, key, "type")) {
                type_ = try self.r.string();
            } else {
                try self.r.skip(sig);
            }
        }
        try self.out.append(self.gpa, .{ .id = id, .depth = depth, .label = label, .type_ = type_ });

        const children_end = try self.r.arrayBegin("v");
        while (self.r.pos < children_end) {
            const sig = try self.r.variantBegin();
            try std.testing.expectEqualStrings(node_signature, sig);
            try self.node(depth + 1);
        }
    }
};

fn walk(gpa: std.mem.Allocator, body: []const u8, out: *std.ArrayList(Walker.Entry)) !void {
    var r: wire.Reader = .init(body, .little);
    const walker: Walker = .{ .r = &r, .out = out, .gpa = gpa };
    try walker.node(0);
    try std.testing.expect(r.atEnd());
}

test "layout mirrors the menu tree" {
    const gpa = std.testing.allocator;

    var menu = Menu.init(gpa);
    defer menu.deinit();
    const open = try menu.addItem("Open");
    try menu.addSeparator();
    const recent = try menu.addSubmenu("Recent");
    const first = try recent.addItem("a.txt");
    const quit = try menu.addItem("Quit");

    var w: wire.Writer = .init(gpa);
    defer w.deinit();
    try writeNode(&w, .{ .root = &menu }, -1, .all);

    var entries: std.ArrayList(Walker.Entry) = .empty;
    defer entries.deinit(gpa);
    try walk(gpa, w.bytes(), &entries);

    try std.testing.expectEqual(@as(usize, 6), entries.items.len);
    try std.testing.expectEqual(root_id, entries.items[0].id);
    try std.testing.expectEqual(@as(usize, 0), entries.items[0].depth);

    try std.testing.expectEqual(@as(i32, @intCast(open)), entries.items[1].id);
    try std.testing.expectEqualStrings("Open", entries.items[1].label.?);

    try std.testing.expectEqualStrings("separator", entries.items[2].type_.?);

    try std.testing.expectEqualStrings("Recent", entries.items[3].label.?);
    try std.testing.expectEqual(@as(usize, 2), entries.items[4].depth);
    try std.testing.expectEqual(@as(i32, @intCast(first)), entries.items[4].id);

    try std.testing.expectEqual(@as(i32, @intCast(quit)), entries.items[5].id);
    try std.testing.expectEqual(@as(usize, 1), entries.items[5].depth);
}

test "depth 0 omits children and depth 1 stops after one level" {
    const gpa = std.testing.allocator;

    var menu = Menu.init(gpa);
    defer menu.deinit();
    const sub = try menu.addSubmenu("Theme");
    _ = try sub.addItem("Light");

    {
        var w: wire.Writer = .init(gpa);
        defer w.deinit();
        try writeNode(&w, .{ .root = &menu }, 0, .all);

        var entries: std.ArrayList(Walker.Entry) = .empty;
        defer entries.deinit(gpa);
        try walk(gpa, w.bytes(), &entries);
        try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    }
    {
        var w: wire.Writer = .init(gpa);
        defer w.deinit();
        try writeNode(&w, .{ .root = &menu }, 1, .all);

        var entries: std.ArrayList(Walker.Entry) = .empty;
        defer entries.deinit(gpa);
        try walk(gpa, w.bytes(), &entries);
        // Root plus "Theme", but not "Light".
        try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    }
}

test "a filter limits which properties are emitted" {
    const gpa = std.testing.allocator;

    var menu = Menu.init(gpa);
    defer menu.deinit();
    _ = try menu.addCheckbox("Verbose", true);

    var w: wire.Writer = .init(gpa);
    defer w.deinit();
    try writeNode(&w, .{ .root = &menu }, -1, .{ .names = &.{"label"} });

    var r: wire.Reader = .init(w.bytes(), .little);
    // Root: no children-display, since the filter excludes it.
    try r.structBegin();
    _ = try r.int(i32);
    var end = try r.arrayBegin("{sv}");
    try std.testing.expectEqual(end, r.pos);

    end = try r.arrayBegin("v");
    _ = try r.variantBegin();
    try r.structBegin();
    _ = try r.int(i32);
    const props_end = try r.arrayBegin("{sv}");
    try r.dictEntryBegin();
    try std.testing.expectEqualStrings("label", try r.string());
    _ = try r.variantBegin();
    try std.testing.expectEqualStrings("Verbose", try r.string());
    try std.testing.expectEqual(props_end, r.pos);
}

test "mnemonic underscores are doubled" {
    const gpa = std.testing.allocator;

    var menu = Menu.init(gpa);
    defer menu.deinit();
    _ = try menu.addItem("a_b_c");

    var w: wire.Writer = .init(gpa);
    defer w.deinit();
    try writeNode(&w, .{ .root = &menu }, -1, .{ .names = &.{"label"} });

    var entries: std.ArrayList(Walker.Entry) = .empty;
    defer entries.deinit(gpa);
    try walk(gpa, w.bytes(), &entries);
    try std.testing.expectEqualStrings("a__b__c", entries.items[1].label.?);
}

test "accelerators become dbusmenu shortcuts" {
    const gpa = std.testing.allocator;

    var w: wire.Writer = .init(gpa);
    defer w.deinit();
    try writeShortcut(&w, "Ctrl+Shift+Q");

    var r: wire.Reader = .init(w.bytes(), .little);
    const outer_end = try r.arrayBegin("as");
    const inner_end = try r.arrayBegin("s");
    try std.testing.expectEqualStrings("Control", try r.string());
    try std.testing.expectEqualStrings("Shift", try r.string());
    try std.testing.expectEqualStrings("q", try r.string());
    try std.testing.expectEqual(inner_end, r.pos);
    try std.testing.expectEqual(outer_end, r.pos);
}

test "GetGroupProperties skips unknown ids" {
    const gpa = std.testing.allocator;

    var menu = Menu.init(gpa);
    defer menu.deinit();
    const first = try menu.addItem("One");
    const second = try menu.addItem("Two");

    var w: wire.Writer = .init(gpa);
    defer w.deinit();
    const ids = [_]i32{ @intCast(first), 4242, @intCast(second) };
    try writeGroupProperties(&w, &menu, &ids, .{ .names = &.{"label"} });

    var r: wire.Reader = .init(w.bytes(), .little);
    const end = try r.arrayBegin("(ia{sv})");
    var labels: [4][]const u8 = undefined;
    var count: usize = 0;
    while (r.pos < end) {
        try r.structBegin();
        _ = try r.int(i32);
        const props_end = try r.arrayBegin("{sv}");
        while (r.pos < props_end) {
            try r.dictEntryBegin();
            _ = try r.string();
            _ = try r.variantBegin();
            labels[count] = try r.string();
        }
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("One", labels[0]);
    try std.testing.expectEqualStrings("Two", labels[1]);
}

test "a single property marshals as a standalone variant" {
    const gpa = std.testing.allocator;

    var menu = Menu.init(gpa);
    defer menu.deinit();
    const quit = try menu.add(.{ .label = "Quit", .accelerator = "Ctrl+Q" });
    const node = findNode(&menu, @intCast(quit)).?;

    // `GetProperty` replies with just this variant, so it must be readable from
    // offset 0 — the bug this guards against was slicing it out of a dict entry,
    // which left every aligned value inside at the wrong offset.
    var w: wire.Writer = .init(gpa);
    defer w.deinit();
    try std.testing.expect(try writeNodeProperty(&w, node, "label"));

    var r: wire.Reader = .init(w.bytes(), .little);
    try std.testing.expectEqualStrings("s", try r.variantBegin());
    try std.testing.expectEqualStrings("Quit", try r.string());
    try std.testing.expect(r.atEnd());

    // An aas value is the strictest case: nested arrays realign to 4.
    w.clearRetainingCapacity();
    try std.testing.expect(try writeNodeProperty(&w, node, "shortcut"));
    r = .init(w.bytes(), .little);
    try std.testing.expectEqualStrings("aas", try r.variantBegin());
    _ = try r.arrayBegin("as");
    const inner_end = try r.arrayBegin("s");
    try std.testing.expectEqualStrings("Control", try r.string());
    try std.testing.expectEqualStrings("q", try r.string());
    try std.testing.expectEqual(inner_end, r.pos);
}

test "properties that do not apply are reported, not written" {
    const gpa = std.testing.allocator;

    var menu = Menu.init(gpa);
    defer menu.deinit();
    _ = try menu.addItem("Plain");
    try menu.addSeparator();
    const node = findNode(&menu, 1).?;

    var w: wire.Writer = .init(gpa);
    defer w.deinit();
    // A plain item has no toggle state and no icon.
    try std.testing.expect(!try writeNodeProperty(&w, node, "toggle-state"));
    try std.testing.expect(!try writeNodeProperty(&w, node, "icon-data"));
    try std.testing.expect(!try writeNodeProperty(&w, node, "nonsense"));
    try std.testing.expectEqual(@as(usize, 0), w.len());

    // A separator has only "type", so rolled-back keys must leave no residue.
    const separator = findNode(&menu, 2).?;
    try writeNodeProperties(&w, separator, .all);
    var r: wire.Reader = .init(w.bytes(), .little);
    try r.dictEntryBegin();
    try std.testing.expectEqualStrings("type", try r.string());
    _ = try r.variantBegin();
    try std.testing.expectEqualStrings("separator", try r.string());
    try std.testing.expect(r.atEnd());
}

test "Event.parse maps host event ids" {
    try std.testing.expectEqual(Event.clicked, Event.parse("clicked"));
    try std.testing.expectEqual(Event.opened, Event.parse("opened"));
    try std.testing.expectEqual(Event.unknown, Event.parse("something-else"));
}
