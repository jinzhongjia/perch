//! The small Objective-C ABI surface needed by the native macOS backend.
//! Arguments must carry their C ABI types; objc_msgSend itself is not variadic.
const std = @import("std");
const builtin = @import("builtin");

pub const Id = ?*anyopaque;
pub const Sel = *anyopaque;
pub const Class = *anyopaque;
pub const BOOL = i8;
pub const Point = extern struct { x: f64, y: f64 };
pub const Size = extern struct { width: f64, height: f64 };
pub const Rect = extern struct { origin: Point, size: Size };

pub extern "objc" fn objc_getClass(name: [*:0]const u8) ?Class;
pub extern "objc" fn sel_registerName(name: [*:0]const u8) Sel;
pub extern "objc" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra: usize) ?Class;
pub extern "objc" fn objc_registerClassPair(cls: Class) void;
pub extern "objc" fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) bool;
pub extern "objc" fn class_addMethod(cls: Class, selector: Sel, implementation: *const anyopaque, types: [*:0]const u8) bool;
pub extern "objc" fn object_getInstanceVariable(object: Id, name: [*:0]const u8, value: *?*anyopaque) ?*anyopaque;
pub extern "objc" fn object_setInstanceVariable(object: Id, name: [*:0]const u8, value: ?*anyopaque) ?*anyopaque;
extern "objc" fn objc_msgSend() callconv(.c) void;
extern "objc" fn objc_msgSend_stret() callconv(.c) void;

pub fn class(name: [:0]const u8) Class {
    return objc_getClass(name) orelse @panic("required macOS class is unavailable");
}

pub fn sel(name: [:0]const u8) Sel {
    return sel_registerName(name);
}

pub fn send(comptime R: type, receiver: Id, comptime name: [:0]const u8, args: anytype) R {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    const Fn = comptime blk: {
        var params: [fields.len + 2]type = undefined;
        params[0] = Id;
        params[1] = Sel;
        for (fields, 2..) |field, i| {
            switch (@typeInfo(field.type)) {
                .comptime_int, .comptime_float, .null => @compileError("objc arguments need explicit ABI types"),
                else => {},
            }
            params[i] = field.type;
        }
        break :blk @Fn(&params, &@as([params.len]std.builtin.Type.Fn.Param.Attributes, @splat(.{})), R, .{ .@"callconv" = .c });
    };
    // x86_64 returns NSRect through an indirect result pointer. arm64 has one
    // message entry point; its normal C ABI supplies the indirect result in x8.
    const stret = builtin.cpu.arch == .x86_64 and switch (@typeInfo(R)) {
        .@"struct" => @sizeOf(R) > 16,
        else => false,
    };
    const function: *const Fn = @ptrCast(if (stret) &objc_msgSend_stret else &objc_msgSend);
    return @call(.auto, function, .{ receiver, sel(name) } ++ args);
}

pub fn addMethod(cls: Class, name: [:0]const u8, implementation: anytype, types: [:0]const u8) bool {
    const pointer = switch (@typeInfo(@TypeOf(implementation))) {
        .@"fn" => &implementation,
        .pointer => implementation,
        else => @compileError("Objective-C implementation must be a C function"),
    };
    return class_addMethod(cls, sel(name), @ptrCast(pointer), types);
}

/// Autoreleased, so callers establish a pool around batches of native work.
pub fn string(text: []const u8) Id {
    const allocated = send(Id, class("NSString"), "alloc", .{});
    const result = send(Id, allocated, "initWithBytes:length:encoding:", .{ text.ptr, text.len, @as(usize, 4) });
    return send(Id, result, "autorelease", .{});
}

pub fn utf8(value: Id) []const u8 {
    const ptr = send(?[*:0]const u8, value, "UTF8String", .{}) orelse return "";
    const len = send(usize, value, "lengthOfBytesUsingEncoding:", .{@as(usize, 4)});
    return ptr[0..len];
}

pub fn retain(value: Id) Id {
    return send(Id, value, "retain", .{});
}

pub fn release(value: Id) void {
    send(void, value, "release", .{});
}

pub fn pool() Id {
    return send(Id, send(Id, class("NSAutoreleasePool"), "alloc", .{}), "init", .{});
}
