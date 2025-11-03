const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const SlabError = error{
    OutOfRange,
    SlotOccupied,
    EmptySlot,
    SlotsAreFull,
    RemoveEmptySlot,
    GrowNotNeeded,
};

const SlabConfig = struct {
    safe: bool = true,
    storage: enum {
        dynamic,
        static,
    } = .dynamic,
    size: comptime_int = 0,
    grow: struct {
        enable: bool = true,
        threshold: comptime_float = 0.7,
        factor: comptime_float = 1.5,
    } = .{},
};

pub fn createSlab(comptime T: type, comptime cfg: SlabConfig) type {
    return struct {
        const Self = @This();
        backend: switch (cfg.storage) {
            .dynamic => struct {
                data: []?T,
                allocator: std.mem.Allocator,
                occupied_count: if (cfg.grow.enable) usize else void,
            },
            .static => struct {
                data: [cfg.size]?T,
            },
        },

        pub fn init(allocator: ?std.mem.Allocator) !Self {
            switch (cfg.storage) {
                .dynamic => {
                    const alloc = allocator orelse @panic("Allocator is required for dynamic slab.");
                    if (comptime cfg.size < 0)
                        @compileError("Invalid slab size: cfg.size must be a positive integer greater than zero.");

                    const default_size = 128;
                    const size = if (comptime cfg.size == 0) default_size else cfg.size;

                    return Self.initWithSize(alloc, size);
                },
                .static => {
                    if (comptime cfg.size <= 0)
                        @compileError("Invalid slab size: cfg.size must be a positive integer greater than zero.");
                    return Self{
                        .backend = .{
                            .data = @splat(null),
                        },
                    };
                },
            }
        }

        pub fn initWithSize(allocator: std.mem.Allocator, size: usize) !Self {
            if (comptime cfg.storage == .static) {
                @panic("Slab initialization failed: 's_init' requires dynamic storage. Set 'SlabConfig.storage = .dynamic'.");
            }

            const slots = try allocator.alloc(?T, size);
            @memset(slots, null);
            return Self{
                .backend = .{
                    .allocator = allocator,
                    .data = slots,
                    .occupied_count = if (comptime cfg.grow.enable) 0,
                },
            };
        }

        pub inline fn len(self: *Self) usize {
            return self.backend.data.len;
        }

        inline fn data(self: *Self) []?T {
            return self.backend.data[0..];
        }

        //copy
        pub inline fn at(self: *Self, index: usize) ?T {
            return self.data()[index];
        }

        pub fn deinit(self: *Self) void {
            if (cfg.storage == .dynamic) {
                self.backend.allocator.free(self.data());
            }
        }

        inline fn checkOutOfRage(self: *Self, index: usize) !void {
            if (cfg.safe and index >= self.len()) return SlabError.OutOfRange;
        }

        pub fn remove(self: *Self, index: usize) SlabError!void {
            if (cfg.safe and self.data()[index] == null) return SlabError.RemoveEmptySlot;
            self.data()[index] = null;
        }

        pub fn get_ptr(self: *Self, index: usize) SlabError!*const T {
            try self.checkOutOfRage(index);

            const maybe = self.data()[index] orelse return SlabError.EmptySlot;
            return &maybe;
        }

        pub fn get(self: *Self, index: usize) SlabError!T {
            try self.checkOutOfRage(index);

            return self.data()[index] orelse SlabError.EmptySlot;
        }

        pub fn findFreeSlot(self: *Self) !usize {
            for (self.data(), 0..) |slot, i| {
                if (slot == null)
                    return i;
            }
            return SlabError.SlotsAreFull;
        }

        pub fn insertAt(self: *Self, index: usize, value: T) !void {
            if (comptime cfg.grow.enable and cfg.storage == .dynamic) {
                if (self.len() < index) {
                    try self.grow(getFactor(index));
                } else {
                    try self.maybeGrow();
                }
            } else {
                try self.checkOutOfRage(index);
            }

            if (self.data()[index] != null) return SlabError.SlotOccupied;
            self.maybeIncrementOccupied();
            self.data()[index] = value;
        }

        pub fn insert(self: *Self, value: T) !usize {
            try self.maybeGrow();
            const index: usize = try self.findFreeSlot();
            self.data()[index] = value;
            self.maybeIncrementOccupied();
            return index;
        }

        inline fn maybeIncrementOccupied(self: *Self) void {
            if (comptime cfg.grow.enable and cfg.storage == .dynamic) {
                self.backend.occupied_count += 1;
            }
        }

        inline fn getFactor(size: usize) usize {
            return @intFromFloat(std.math.ceil(@as(f64, @floatFromInt(size)) * cfg.grow.factor));
        }

        fn maybeGrow(self: *Self) !void {
            if (comptime cfg.grow.enable == false or cfg.storage == .static) return;

            const usage: f64 = @as(f64, @floatFromInt(self.backend.occupied_count)) / @as(f64, @floatFromInt(self.len()));
            if (usage < cfg.grow.threshold) return;

            try self.grow(getFactor(self.len()));
        }

        fn grow(self: *Self, size: usize) !void {
            if (size <= self.len()) return SlabError.GrowNotNeeded;

            const old_data = self.data();
            const new_data = try self.backend.allocator.alloc(?T, size);
            @memcpy(new_data[0..old_data.len], old_data[0..]);
            @memset(new_data[old_data.len..], null);
            self.backend.allocator.free(old_data);
            self.backend.data = new_data;
        }
    };
}

test "init static" {
    const Slab = createSlab(u32, .{
        .storage = .static,
        .size = 10,
        .safe = false,
    });

    var slab = try Slab.init(std.testing.allocator);
    defer slab.deinit();

    for (0..slab.len()) |i| {
        try slab.insertAt(i, @as(u32, @intCast(i)));
    }
}

test "init dynamic" {
    const Slab = createSlab(u32, .{
        .storage = .dynamic,
        .size = 10,
        .safe = true,
        .grow = .{ .enable = false },
    });

    var slab = try Slab.init(std.testing.allocator);
    defer slab.deinit();
    try expectEqual(slab.len(), 10);
    for (0..slab.len()) |i| {
        const err = slab.get(i) catch |e| e;
        try expectEqual(err, SlabError.EmptySlot);
    }
}

test "initWithSize" {
    const Slab = createSlab(u32, .{
        .storage = .dynamic,
        .safe = true,
        .grow = .{ .enable = false },
    });

    var slab = try Slab.initWithSize(std.testing.allocator, 10);
    defer slab.deinit();
    try expectEqual(slab.len(), 10);

    for (0..slab.len()) |i| {
        const err = slab.get(i) catch |e| e;
        try expectEqual(err, SlabError.EmptySlot);
    }
}

test "get" {
    const Slab = createSlab(u32, .{ .storage = .dynamic, .safe = true });
    var slab = try Slab.initWithSize(std.testing.allocator, 3);
    defer slab.deinit();

    try slab.insertAt(1, 42);

    try expectEqual(try slab.get(1), 42);
    try expectEqual(slab.get(0) catch |e| e, SlabError.EmptySlot);
    try expectEqual(slab.get(10) catch |e| e, SlabError.OutOfRange);
}

test "get_ptr" {
    const Slab = createSlab(u32, .{ .storage = .dynamic, .safe = true });
    var slab = try Slab.initWithSize(std.testing.allocator, 2);
    defer slab.deinit();

    try slab.insertAt(0, 123);
    const ptr = try slab.get_ptr(0);
    try expectEqual(ptr.*, 123);

    try expectEqual(slab.get_ptr(1) catch |e| e, SlabError.EmptySlot);
    try expectEqual(slab.get_ptr(99) catch |e| e, SlabError.OutOfRange);
}

test "insert" {
    const Slab = createSlab(u32, .{
        .storage = .dynamic,
        .safe = true,
        .grow = .{ .enable = false },
    });
    var slab = try Slab.initWithSize(std.testing.allocator, 2);
    defer slab.deinit();

    const in0 = try slab.insert(5);
    const in1 = try slab.insert(10);
    try expectEqual(try slab.get(in0), 5);
    try expectEqual(try slab.get(in1), 10);

    try expectEqual(slab.insert(99) catch |e| e, SlabError.SlotsAreFull);
}

test "insertAt" {
    const Slab = createSlab(u32, .{
        .storage = .dynamic,
        .safe = true,
        .grow = .{ .enable = false },
    });
    var slab = try Slab.initWithSize(std.testing.allocator, 2);
    defer slab.deinit();

    try slab.insertAt(1, 99);
    try expectEqual(try slab.get(1), 99);
    try expectEqual(slab.insertAt(1, 88) catch |e| e, SlabError.SlotOccupied);
    try expectEqual(slab.insertAt(10, 1) catch |e| e, SlabError.OutOfRange);
}

test "remove" {
    const Slab = createSlab(u32, .{ .storage = .dynamic, .safe = true });
    var slab = try Slab.initWithSize(std.testing.allocator, 2);
    defer slab.deinit();

    try slab.insertAt(0, 111);
    try slab.remove(0);
    try expectEqual(slab.get(0) catch |e| e, SlabError.EmptySlot);

    try expectEqual(slab.remove(0) catch |e| e, SlabError.RemoveEmptySlot);
}

test "findFreeSlot" {
    const Slab = createSlab(u32, .{ .storage = .dynamic });
    var slab = try Slab.initWithSize(std.testing.allocator, 1);
    defer slab.deinit();

    const idx = try slab.findFreeSlot();
    try expectEqual(idx, 0);
    try slab.insertAt(idx, 1);

    try expectEqual(slab.findFreeSlot() catch |e| e, SlabError.SlotsAreFull);
}

test "len, data, at return correct info" {
    const Slab = createSlab(u32, .{ .storage = .dynamic });
    var slab = try Slab.initWithSize(std.testing.allocator, 3);
    defer slab.deinit();

    try expectEqual(slab.len(), 3);
    try slab.insertAt(2, 77);
    try expectEqual(slab.at(2).?, 77);
    try expectEqual(slab.data()[2].?, 77);
}

test "concurrent insertAt writes unique slots" {
    const thread_count = 8;
    const items_per_thread = 32;
    const total_slots = thread_count * items_per_thread;

    const Slab = createSlab(u32, .{
        .storage = .dynamic,
        .safe = true,
        .grow = .{ .enable = false },
    });

    var slab = try Slab.initWithSize(std.testing.allocator, total_slots);
    defer slab.deinit();

    const ThreadContext = struct {
        slab: *Slab,
        start: usize,
        count: usize,
        base_value: u32,
    };

    const Worker = struct {
        fn run(ctx: *ThreadContext) void {
            var i: usize = 0;
            while (i < ctx.count) : (i += 1) {
                const index = ctx.start + i;
                const value = ctx.base_value + @as(u32, @intCast(i));
                ctx.slab.insertAt(index, value) catch |err| {
                    std.debug.panic("insertAt failed: {s}", .{@errorName(err)});
                };
            }
        }
    };

    var contexts: [thread_count]ThreadContext = undefined;
    var threads: [thread_count]std.Thread = undefined;

    for (0..thread_count) |tid| {
        const start_index = tid * items_per_thread;
        contexts[tid] = .{
            .slab = &slab,
            .start = start_index,
            .count = items_per_thread,
            .base_value = @as(u32, @intCast(start_index)),
        };
        threads[tid] = try std.Thread.spawn(.{}, Worker.run, .{&contexts[tid]});
    }

    for (threads) |thread| {
        thread.join();
    }

    for (contexts) |ctx| {
        var i: usize = 0;
        while (i < ctx.count) : (i += 1) {
            const index = ctx.start + i;
            const expected = ctx.base_value + @as(u32, @intCast(i));
            try expectEqual(expected, try slab.get(index));
        }
    }
}

test "concurrent remove clears slots" {
    const thread_count = 6;
    const items_per_thread = 24;
    const total_slots = thread_count * items_per_thread;

    const Slab = createSlab(u32, .{
        .storage = .dynamic,
        .safe = true,
        .grow = .{ .enable = false },
    });

    var slab = try Slab.initWithSize(std.testing.allocator, total_slots);
    defer slab.deinit();

    for (0..total_slots) |i| {
        try slab.insertAt(i, @as(u32, @intCast(i)));
    }

    const ThreadContext = struct {
        slab: *Slab,
        start: usize,
        count: usize,
    };

    const Worker = struct {
        fn run(ctx: *ThreadContext) void {
            var i: usize = 0;
            while (i < ctx.count) : (i += 1) {
                const index = ctx.start + i;
                ctx.slab.remove(index) catch |err| {
                    std.debug.panic("remove failed: {s}", .{@errorName(err)});
                };
            }
        }
    };

    var contexts: [thread_count]ThreadContext = undefined;
    var threads: [thread_count]std.Thread = undefined;

    for (0..thread_count) |tid| {
        const start_index = tid * items_per_thread;
        contexts[tid] = .{
            .slab = &slab,
            .start = start_index,
            .count = items_per_thread,
        };
        threads[tid] = try std.Thread.spawn(.{}, Worker.run, .{&contexts[tid]});
    }

    for (threads) |thread| {
        thread.join();
    }

    for (0..total_slots) |i| {
        try expectEqual(SlabError.EmptySlot, slab.get(i) catch |err| err);
    }
}
