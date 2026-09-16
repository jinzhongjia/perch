//! Owned AppKit images, without an Objective-C translation unit.
const std = @import("std");
const objc = @import("objc.zig");
const image = @import("../image.zig");
const Icon = @import("../icon.zig").Icon;
const Tray = @import("../tray.zig").Tray;
const Error = @import("../tray.zig").Error;

extern var _NSConcreteStackBlock: [32]usize;
extern var NSDeviceRGBColorSpace: objc.Id;
extern fn CGContextBeginTransparencyLayer(context: *anyopaque, auxiliary_info: objc.Id) void;
extern fn CGContextEndTransparencyLayer(context: *anyopaque) void;
extern fn NSRectFillUsingOperation(rect: objc.Rect, operation: usize) void;

fn fail(owner: *Tray, diagnostic: []const u8) Error {
    owner.last_diagnostic = diagnostic;
    return error.PlatformFailure;
}

fn allocated(owner: *Tray, value: objc.Id) Error!objc.Id {
    if (value == null) {
        owner.last_diagnostic = "AppKit could not allocate an image or image representation";
        return error.OutOfMemory;
    }
    return value;
}

/// Returns a retained image. All bytes and representations are independent of
/// the input's lifetime; the caller must release the returned object.
pub fn load(owner: *Tray, icon: Icon, size: f64) Error!objc.Id {
    if (!std.math.isFinite(size) or size <= 0) return fail(owner, "The requested macOS icon size must be finite and positive");
    const autorelease_pool = objc.pool();
    defer objc.release(autorelease_pool);
    const previous_diagnostic = owner.last_diagnostic;
    const result = try loadInner(owner, icon, size, 0);
    owner.last_diagnostic = previous_diagnostic;
    return result;
}

fn loadInner(owner: *Tray, icon: Icon, size: f64, depth: usize) Error!objc.Id {
    return switch (icon) {
        .named => |name| named(owner, name, size),
        .bytes => |bytes| encoded(owner, bytes, null, size, false),
        .template => |bytes| blk: {
            const result = try encoded(owner, bytes, null, size, false);
            objc.send(void, result, "setTemplate:", .{@as(objc.BOOL, 1)});
            break :blk result;
        },
        .svg => |bytes| encoded(owner, bytes, null, size, true),
        .path => |path| blk: {
            if (std.mem.indexOfScalar(u8, path, 0) != null) return fail(owner, "An icon path cannot contain a NUL byte");
            const filename = objc.string(path);
            if (filename == null) return fail(owner, "The icon path is not valid UTF-8");
            const data = objc.send(objc.Id, objc.class("NSData"), "dataWithContentsOfFile:", .{filename});
            if (data == null) return fail(owner, "AppKit could not read the icon file");
            const length = objc.send(usize, data, "length", .{});
            const bytes = objc.send(?[*]const u8, data, "bytes", .{}) orelse return fail(owner, "The icon file is empty");
            break :blk try encoded(owner, bytes[0..length], data, size, false);
        },
        .raw => |raw| rawImage(owner, raw, size),
        .set => |members| imageSet(owner, members, size, depth),
    };
}

fn fitted(width: f64, height: f64, size: f64) objc.Size {
    const scale = size / @max(width, height);
    return .{ .width = width * scale, .height = height * scale };
}

fn resize(owner: *Tray, result: objc.Id, size: f64) Error!void {
    const original = objc.send(objc.Size, result, "size", .{});
    if (!std.math.isFinite(original.width) or !std.math.isFinite(original.height) or original.width <= 0 or original.height <= 0)
        return fail(owner, "AppKit decoded an image with invalid dimensions");
    objc.send(void, result, "setSize:", .{fitted(original.width, original.height, size)});
}

fn named(owner: *Tray, name: []const u8, size: f64) Error!objc.Id {
    const text = objc.string(name);
    if (text == null or name.len == 0) return fail(owner, "The macOS icon name must be nonempty UTF-8");
    const cls = objc.class("NSImage");
    var source: objc.Id = null;
    if (objc.send(objc.BOOL, cls, "respondsToSelector:", .{objc.sel("imageWithSystemSymbolName:accessibilityDescription:")}) != 0)
        source = objc.send(objc.Id, cls, "imageWithSystemSymbolName:accessibilityDescription:", .{ text, @as(objc.Id, null) });
    // AppKit's documented built-in names begin with NS (e.g. NSActionTemplate).
    // An unknown SF Symbol must not silently resolve an unrelated bundle asset.
    if (source == null and std.mem.startsWith(u8, name, "NS"))
        source = objc.send(objc.Id, cls, "imageNamed:", .{text});
    if (source == null) return fail(owner, "No SF Symbol or native AppKit image exists with this name on this macOS version");
    const result = try allocated(owner, objc.send(objc.Id, source, "copy", .{}));
    errdefer objc.release(result);
    try resize(owner, result, size);
    return result;
}

fn encoded(owner: *Tray, bytes: []const u8, existing_data: objc.Id, size: f64, svg_only: bool) Error!objc.Id {
    if (bytes.len == 0) return fail(owner, "The encoded icon is empty");
    const format = image.sniff(bytes);
    // Our ICO decoder deliberately publishes every size, including DIB frames
    // and their AND-mask alpha. Native decoding remains a fallback for variants
    // beyond the shared decoder's supported subset.
    if (format == .ico) {
        if (decodedImage(owner, bytes, size)) |result| return result else |err| {
            if (err == error.OutOfMemory) return err;
        }
    }
    const data = existing_data orelse objc.send(objc.Id, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, bytes.len });
    _ = try allocated(owner, data);
    const result = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSImage"), "alloc", .{}), "initWithData:", .{data});
    if (result != null) {
        if (objc.send(objc.BOOL, result, "isValid", .{}) != 0) {
            errdefer objc.release(result);
            try resize(owner, result, size);
            return result;
        }
        objc.release(result);
    }
    if (svg_only or format == .svg) {
        owner.last_diagnostic = "AppKit could not render this SVG; SVG support and supported SVG features depend on the installed macOS image decoder";
        return error.Unsupported;
    }
    if (format == .ico) return fail(owner, "Neither AppKit nor the shared ICO decoder could decode the icon");
    return decodedImage(owner, bytes, size);
}

fn decodedImage(owner: *Tray, bytes: []const u8, size: f64) Error!objc.Id {
    const frames = image.decodeAll(owner.gpa, bytes) catch |err| {
        owner.last_diagnostic = "The shared PNG/BMP/ICO decoder could not decode the icon";
        return if (err == error.OutOfMemory) error.OutOfMemory else error.PlatformFailure;
    };
    defer image.freeAll(owner.gpa, frames);
    if (frames.len == 0) return fail(owner, "The icon contains no decodable image frames");
    const logical_size = fitted(@floatFromInt(frames[0].width), @floatFromInt(frames[0].height), size);
    const result = try newImage(owner, logical_size);
    errdefer objc.release(result);
    for (frames) |frame| {
        const rep = try rawRepresentation(owner, .{ .width = frame.width, .height = frame.height, .pixels = frame.argb, .format = .argb32 });
        defer objc.release(rep);
        objc.send(void, rep, "setSize:", .{logical_size});
        objc.send(void, result, "addRepresentation:", .{rep});
    }
    return result;
}

fn newImage(owner: *Tray, size: objc.Size) Error!objc.Id {
    return allocated(owner, objc.send(objc.Id, objc.send(objc.Id, objc.class("NSImage"), "alloc", .{}), "initWithSize:", .{size}));
}

fn rawImage(owner: *Tray, raw: Icon.Raw, size: f64) Error!objc.Id {
    const rep = try rawRepresentation(owner, raw);
    defer objc.release(rep);
    const logical_size = fitted(@floatFromInt(raw.width), @floatFromInt(raw.height), size);
    objc.send(void, rep, "setSize:", .{logical_size});
    const result = try newImage(owner, logical_size);
    objc.send(void, result, "addRepresentation:", .{rep});
    return result;
}

fn rawRepresentation(owner: *Tray, raw: Icon.Raw) Error!objc.Id {
    const count = std.math.mul(usize, raw.width, raw.height) catch return fail(owner, "Raw icon dimensions overflow");
    const length = std.math.mul(usize, count, 4) catch return fail(owner, "Raw icon byte length overflows");
    if (count == 0 or raw.pixels.len != length) return fail(owner, "Raw icons require nonzero dimensions and exactly width * height * 4 bytes");
    const row_bytes = std.math.mul(usize, raw.width, 4) catch return fail(owner, "Raw icon row length overflows");
    if (row_bytes > std.math.maxInt(isize) or length > std.math.maxInt(isize)) return fail(owner, "Raw icon dimensions exceed AppKit limits");
    // NSBitmapFormatAlphaNonpremultiplied = 1 << 1; alpha-last, byte-sized
    // samples give straight RGBA, independent of host integer byte order.
    const rep = try allocated(owner, objc.send(objc.Id, objc.send(objc.Id, objc.class("NSBitmapImageRep"), "alloc", .{}), "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bitmapFormat:bytesPerRow:bitsPerPixel:", .{ @as(?*anyopaque, null), @as(isize, @intCast(raw.width)), @as(isize, @intCast(raw.height)), @as(isize, 8), @as(isize, 4), @as(objc.BOOL, 1), @as(objc.BOOL, 0), NSDeviceRGBColorSpace, @as(usize, 2), @as(isize, @intCast(row_bytes)), @as(isize, 32) }));
    errdefer objc.release(rep);
    const pixels = objc.send(?[*]u8, rep, "bitmapData", .{}) orelse return fail(owner, "AppKit allocated an image representation without pixel storage");
    if (raw.format == .rgba32) {
        @memcpy(pixels[0..length], raw.pixels);
        return rep;
    }
    for (0..count) |i| {
        const source = raw.pixels[i * 4 ..][0..4];
        const destination = pixels[i * 4 ..][0..4];
        destination.* = switch (raw.format) {
            .argb32 => .{ source[1], source[2], source[3], source[0] },
            .rgba32 => unreachable,
            .bgra32 => .{ source[2], source[1], source[0], source[3] },
        };
    }
    return rep;
}

fn imageSet(owner: *Tray, members: []const Icon, size: f64, depth: usize) Error!objc.Id {
    // The outer set may contain one further set; deeper sets (including cycles)
    // are rejected as individual bad members rather than recursed forever.
    if (depth >= 2) return fail(owner, "Icon sets may be nested only one level");
    var result: objc.Id = null;
    errdefer objc.release(result);
    var all_template = true;
    for (members) |member| {
        const source = loadInner(owner, member, size, depth + 1) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer objc.release(source);
        const reps = objc.send(objc.Id, source, "representations", .{});
        const count = objc.send(usize, reps, "count", .{});
        if (count == 0) continue;
        if (result == null) result = try newImage(owner, objc.send(objc.Size, source, "size", .{}));
        const logical_size = objc.send(objc.Size, result, "size", .{});
        for (0..count) |index| {
            const rep = objc.send(objc.Id, reps, "objectAtIndex:", .{index});
            const copied = try allocated(owner, objc.send(objc.Id, rep, "copy", .{}));
            defer objc.release(copied);
            objc.send(void, copied, "setSize:", .{logical_size});
            objc.send(void, result, "addRepresentation:", .{copied});
        }
        all_template = all_template and objc.send(objc.BOOL, source, "isTemplate", .{}) != 0;
    }
    if (result == null) return fail(owner, "The icon set contains no usable native or bitmap representations");
    objc.send(void, result, "setTemplate:", .{@as(objc.BOOL, if (all_template) 1 else 0)});
    return result;
}

// Apple Blocks ABI. AppKit copies this stack block; the helpers own the two
// images independently of Tray and of the caller's autorelease pool.
const CompositeBlock = extern struct {
    isa: *anyopaque,
    flags: i32 = 1 << 25, // BLOCK_HAS_COPY_DISPOSE
    reserved: i32 = 0,
    invoke: *const fn (*const CompositeBlock, objc.Rect) callconv(.c) objc.BOOL = drawComposite,
    descriptor: *const BlockDescriptor = &block_descriptor,
    base: objc.Id,
    overlay: objc.Id,
    template: bool,
};
const BlockDescriptor = extern struct {
    reserved: usize = 0,
    size: usize = @sizeOf(CompositeBlock),
    copy: *const fn (*CompositeBlock, *const CompositeBlock) callconv(.c) void = copyComposite,
    dispose: *const fn (*CompositeBlock) callconv(.c) void = disposeComposite,
};
const block_descriptor: BlockDescriptor = .{};

fn copyComposite(destination: *CompositeBlock, source: *const CompositeBlock) callconv(.c) void {
    destination.base = objc.retain(source.base);
    destination.overlay = objc.retain(source.overlay);
}

fn disposeComposite(block: *CompositeBlock) callconv(.c) void {
    objc.release(block.base);
    objc.release(block.overlay);
}

const zero_rect: objc.Rect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };

fn drawLayer(source: objc.Id, destination: objc.Rect, tint: bool, context: *anyopaque) void {
    if (tint) CGContextBeginTransparencyLayer(context, null);
    objc.send(void, source, "drawInRect:fromRect:operation:fraction:respectFlipped:hints:", .{ destination, zero_rect, @as(usize, 2), @as(f64, 1), @as(objc.BOOL, 0), @as(objc.Id, null) });
    if (tint) {
        objc.send(void, objc.send(objc.Id, objc.class("NSColor"), "labelColor", .{}), "setFill", .{});
        NSRectFillUsingOperation(destination, 3); // NSCompositingOperationSourceIn
        CGContextEndTransparencyLayer(context);
    }
}

fn drawComposite(block: *const CompositeBlock, destination: objc.Rect) callconv(.c) objc.BOOL {
    const graphics = objc.send(objc.Id, objc.class("NSGraphicsContext"), "currentContext", .{});
    const context = objc.send(?*anyopaque, graphics, "CGContext", .{}) orelse return 0;
    objc.send(void, graphics, "saveGraphicsState", .{});
    defer objc.send(void, graphics, "restoreGraphicsState", .{});
    const base_size = objc.send(objc.Size, block.base, "size", .{});
    const base_fit = fitted(base_size.width, base_size.height, @min(destination.size.width, destination.size.height));
    const base_rect: objc.Rect = .{ .origin = .{ .x = destination.origin.x + (destination.size.width - base_fit.width) / 2, .y = destination.origin.y + (destination.size.height - base_fit.height) / 2 }, .size = base_fit };
    drawLayer(block.base, base_rect, !block.template and objc.send(objc.BOOL, block.base, "isTemplate", .{}) != 0, context);
    const overlay_size = objc.send(objc.Size, block.overlay, "size", .{});
    const overlay_fit = fitted(overlay_size.width, overlay_size.height, @min(destination.size.width, destination.size.height) / 2);
    const overlay_rect: objc.Rect = .{ .origin = .{ .x = destination.origin.x + destination.size.width - overlay_fit.width, .y = destination.origin.y }, .size = overlay_fit };
    drawLayer(block.overlay, overlay_rect, !block.template and objc.send(objc.BOOL, block.overlay, "isTemplate", .{}) != 0, context);
    return 1;
}

/// Returns a retained, resolution-independent image with a lower-right badge.
/// AppKit invokes the drawing handler at the actual display scale. Two template
/// inputs remain a template; mixed inputs tint masks using the drawing appearance.
pub fn composite(owner: *Tray, base: objc.Id, overlay: objc.Id, size: f64) Error!objc.Id {
    if (base == null or overlay == null or !std.math.isFinite(size) or size <= 0)
        return fail(owner, "Compositing requires two images and a finite, positive icon size");
    const autorelease_pool = objc.pool();
    defer objc.release(autorelease_pool);
    const is_template = objc.send(objc.BOOL, base, "isTemplate", .{}) != 0 and objc.send(objc.BOOL, overlay, "isTemplate", .{}) != 0;
    const block: CompositeBlock = .{ .isa = @ptrCast(&_NSConcreteStackBlock), .base = base, .overlay = overlay, .template = is_template };
    const result = try allocated(owner, objc.send(objc.Id, objc.class("NSImage"), "imageWithSize:flipped:drawingHandler:", .{ objc.Size{ .width = size, .height = size }, @as(objc.BOOL, 0), &block }));
    objc.send(void, result, "setTemplate:", .{@as(objc.BOOL, if (is_template) 1 else 0)});
    // Disable cached drawing so mixed template/color images resolve dynamic
    // labelColor again when the menu bar's light/dark appearance changes.
    objc.send(void, result, "setCacheMode:", .{@as(usize, 3)}); // NSImageCacheNever
    return objc.retain(result);
}
