const std = @import("std");
const Icon = @import("icon.zig").Icon;

pub const MenuItem = struct {
    /// Stable identifier handed back to `Handler.on_activate`. Ids are unique
    /// within the whole menu tree, submenus included.
    pub const Id = u32;

    pub const Kind = enum { normal, checkbox, radio, separator, submenu };

    id: Id = 0,
    kind: Kind = .normal,
    label: []const u8 = "",
    tooltip: ?[]const u8 = null,
    /// Platform-agnostic accelerator, e.g. `"Ctrl+Shift+Q"`. On macOS `Ctrl`
    /// is rendered as Command unless `Meta` is spelled out explicitly.
    accelerator: ?[]const u8 = null,
    icon: ?Icon = null,
    enabled: bool = true,
    /// Only read for `.checkbox` and `.radio`.
    checked: bool = false,
    /// Radio items sharing a group toggle as a set.
    radio_group: u16 = 0,
    /// Owned by the parent `Menu`; only set for `.submenu`.
    submenu: ?*Menu = null,
};

/// A menu tree. Labels and other slices are borrowed, not copied — keep them
/// alive for as long as the menu is attached to a `Tray`.
///
/// Submenus hold a pointer back to their parent, so the root must not be moved
/// or copied once `addSubmenu` has been called on it.
pub const Menu = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(MenuItem) = .empty,
    /// Submenus allocated by `addSubmenu`, freed by `deinit`.
    children: std.ArrayList(*Menu) = .empty,
    /// Null for the root, which owns the id counter for the whole tree.
    parent: ?*Menu = null,
    next_id: MenuItem.Id = 1,

    pub fn init(gpa: std.mem.Allocator) Menu {
        return .{ .gpa = gpa };
    }

    /// The menu that owns the id counter for this tree.
    fn root(self: *Menu) *Menu {
        var current = self;
        while (current.parent) |p| current = p;
        return current;
    }

    pub fn deinit(self: *Menu) void {
        for (self.children.items) |child| {
            child.deinit();
            self.gpa.destroy(child);
        }
        self.children.deinit(self.gpa);
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    fn takeId(self: *Menu, requested: MenuItem.Id) MenuItem.Id {
        const owner = self.root();
        if (requested != 0) {
            if (requested >= owner.next_id) owner.next_id = requested + 1;
            return requested;
        }
        defer owner.next_id += 1;
        return owner.next_id;
    }

    /// Appends `item`, assigning an id when `item.id` is left at 0. Separators
    /// get ids too: platforms address every row, and id 0 is reserved for the
    /// menu itself on Linux.
    pub fn add(self: *Menu, item: MenuItem) !MenuItem.Id {
        var copy = item;
        copy.id = self.takeId(item.id);
        try self.items.append(self.gpa, copy);
        return copy.id;
    }

    pub fn addItem(self: *Menu, label: []const u8) !MenuItem.Id {
        return self.add(.{ .label = label });
    }

    pub fn addSeparator(self: *Menu) !void {
        _ = try self.add(.{ .kind = .separator });
    }

    pub fn addCheckbox(self: *Menu, label: []const u8, checked: bool) !MenuItem.Id {
        return self.add(.{ .kind = .checkbox, .label = label, .checked = checked });
    }

    pub fn addRadio(self: *Menu, label: []const u8, group: u16, checked: bool) !MenuItem.Id {
        return self.add(.{ .kind = .radio, .label = label, .radio_group = group, .checked = checked });
    }

    /// Appends a submenu and returns it for further population. The returned
    /// pointer stays valid until this menu is deinitialised.
    pub fn addSubmenu(self: *Menu, label: []const u8) !*Menu {
        const child = try self.gpa.create(Menu);
        errdefer self.gpa.destroy(child);
        child.* = .{ .gpa = self.gpa, .parent = self };

        try self.children.append(self.gpa, child);
        errdefer _ = self.children.pop();

        _ = try self.add(.{ .kind = .submenu, .label = label, .submenu = child });
        return child;
    }

    /// Depth-first lookup across the whole tree.
    pub fn find(self: *Menu, id: MenuItem.Id) ?*MenuItem {
        if (id == 0) return null;
        for (self.items.items) |*item| {
            if (item.id == id) return item;
            if (item.submenu) |sub| {
                if (sub.find(id)) |hit| return hit;
            }
        }
        return null;
    }

    pub fn setEnabled(self: *Menu, id: MenuItem.Id, enabled: bool) bool {
        const item = self.find(id) orelse return false;
        item.enabled = enabled;
        return true;
    }

    pub fn setLabel(self: *Menu, id: MenuItem.Id, label: []const u8) bool {
        const item = self.find(id) orelse return false;
        item.label = label;
        return true;
    }

    /// Checks `id`, clearing siblings that share its radio group.
    pub fn setChecked(self: *Menu, id: MenuItem.Id, checked: bool) bool {
        const item = self.find(id) orelse return false;
        item.checked = checked;
        if (checked and item.kind == .radio) self.clearGroup(item.radio_group, id);
        return true;
    }

    fn clearGroup(self: *Menu, group: u16, keep: MenuItem.Id) void {
        for (self.items.items) |*item| {
            if (item.kind == .radio and item.radio_group == group and item.id != keep) {
                item.checked = false;
            }
            if (item.submenu) |sub| sub.clearGroup(group, keep);
        }
    }
};

test "ids are unique across the tree" {
    var menu = Menu.init(std.testing.allocator);
    defer menu.deinit();

    const open = try menu.addItem("Open");
    try menu.addSeparator();
    const sub = try menu.addSubmenu("Recent");
    const first = try sub.addItem("a.txt");
    const quit = try menu.addItem("Quit");

    try std.testing.expect(open != first);
    try std.testing.expect(first != quit);
    try std.testing.expectEqualStrings("a.txt", menu.find(first).?.label);
    try std.testing.expect(menu.find(9999) == null);
    // Id 0 stands for the menu itself, never an item.
    try std.testing.expect(menu.find(0) == null);
    for (menu.items.items) |item| try std.testing.expect(item.id != 0);
}

test "explicit ids do not collide with generated ones" {
    var menu = Menu.init(std.testing.allocator);
    defer menu.deinit();

    _ = try menu.add(.{ .label = "Pinned", .id = 100 });
    const generated = try menu.addItem("Other");
    try std.testing.expectEqual(@as(MenuItem.Id, 101), generated);
}

test "radio selection clears its group only" {
    var menu = Menu.init(std.testing.allocator);
    defer menu.deinit();

    const light = try menu.addRadio("Light", 1, true);
    const dark = try menu.addRadio("Dark", 1, false);
    const other = try menu.addRadio("Compact", 2, true);

    try std.testing.expect(menu.setChecked(dark, true));
    try std.testing.expect(!menu.find(light).?.checked);
    try std.testing.expect(menu.find(dark).?.checked);
    try std.testing.expect(menu.find(other).?.checked);
}
