const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const SlabError = error{
    OutOfRange,
    SlotOccupied,
    EmptySlot,
    SlotsAreFull,
    RemoveEmptySlot,
};

const SlabConfig = struct {
    safe: bool = true,
    storage: enum {
        dynamic,
        static,
    },
    size: comptime_int = 0,
};

pub fn createSlab(comptime T: type, comptime cfg: SlabConfig) type {
    return struct {
        const Self = @This();
        backend: switch (cfg.storage) {
            .dynamic => struct {
                data: []?T,
                allocator: std.mem.Allocator,
                buckets_size: usize,
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
                    const size = cfg.size orelse default_size;

                    const slots = try alloc.alloc(?T, size);
                    @memset(slots, null);
                    return Self{
                        .backend = .{
                            .allocator = alloc,
                            .data = slots,
                            .buckets_size = 0,
                        },
                    };
                },
                .static => {
                    if (comptime cfg.size <= 0)
                        @compileError("Invalid slab size: cfg.size must be a positive integer greater than zero.");
                    return Self{
                        // ..data = @splat(null),
                        .backend = .{
                            .data = @splat(null),
                        },
                    };
                },
            }
        }

        pub inline fn len(self: *Self) usize {
            return self.backend.data.len;
        }

        inline fn data(self: *Self) []?T {
            return self.backend.data[0..];
        }

        //copy
        inline fn at(self: *Self, index: usize) ?T {
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

        pub fn insertAt(self: *Self, index: usize, value: T) SlabError!void {
            try self.checkOutOfRage(index);
            if (self.data()[index] != null) return SlabError.SlotOccupied;
            self.data()[index] = value;
        }

        pub fn remove(self: *Self, index: usize) SlabError!void {
            if (comptime cfg.safe and self.data()[index] == null) return SlabError.RemoveEmptySlot;
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
            for (self.data(), 0..) |bucket, i| {
                if (bucket == null)
                    return i;
            }
            return SlabError.SlotsAreFull;
        }

        pub fn insert(self: *Self, value: T) !usize {
            const index: usize = try self.findFreeSlot();
            if (self.data()[index] != null) return SlabError.SlotOccupied;
            self.data()[index] = value;
            return index;
        }
    };
}

test "init static" {
    const Slab = createSlab(u32, .{ .storage = .static, .size = 3000, .safe = false });
    var slab = try Slab.init(null);
    try slab.insertAt(2500, 25);
    const value = @constCast(try slab.get_ptr(2500));
    try expectEqual(value.*, 25);
}

test "init dynamic" {
    const Slab = createSlab(u32, .{ .storage = .static, .size = 3000, .safe = false });
    var slab = try Slab.init(std.testing.allocator);
    slab.deinit();
    try slab.insertAt(2500, 40);
    const value = try slab.get(2500);
    try expectEqual(value, 40);
}
