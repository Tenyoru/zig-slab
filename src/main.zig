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
        allocator: std.mem.Allocator,
        size: usize,
        buckets_size: usize,
        data: switch (cfg.storage) {
            .dynamic => []?T,
            .static => [cfg.size]?T,
        },

        pub fn init(allocator: ?std.mem.Allocator) !Self {
            switch (cfg.storage) {
                .dynamic => {
                    const alloc = allocator orelse @panic("Allocator is required for dynamic slab.");
                    if (comptime cfg.size < 0)
                        @compileError("Invalid slab size: cfg.size must be a positive integer greater than zero.");

                    const default_size = 128;
                    const size = cfg.size orelse default_size;

                    const data = try alloc.alloc(?T, size);
                    @memset(data, null);
                    return Self{
                        .allocator = alloc,
                        .data = data,
                        .size = size,
                        .buckets_size = 0,
                    };
                },
                .static => {
                    if (comptime cfg.size <= 0)
                        @compileError("Invalid slab size: cfg.size must be a positive integer greater than zero.");
                    return Self{
                        .buckets_size = undefined,
                        .allocator = undefined,
                        .data = @splat(null),
                        .size = cfg.size,
                    };
                },
            }
        }

        pub fn len(self: *Self) usize {
            return self.data.len;
        }

        pub fn deinit(self: *Self) void {
            if (cfg.storage == .dynamic) {
                self.allocator.free(self.data);
            }
        }

        inline fn checkOutOfRage(self: *Self, index: usize) !void {
            if (cfg.safe and index >= self.size) return SlabError.OutOfRange;
        }

        pub fn insertAt(self: *Self, index: usize, value: T) SlabError!void {
            try self.checkOutOfRage(index);
            if (self.data[index] != null) return SlabError.SlotOccupied;
            self.data[index] = value;
        }

        pub fn remove(self: *Self, index: usize) SlabError!void {
            if (comptime cfg.safe and self.data[index] == null) return SlabError.RemoveEmptySlot;
            self.data[index] = null;
        }

        pub fn get_ptr(self: *Self, index: usize) SlabError!*const T {
            try self.checkOutOfRage(index);

            const maybe = self.data[index] orelse return SlabError.EmptySlot;
            return &maybe;
        }

        pub fn get(self: *Self, index: usize) SlabError!T {
            try self.checkOutOfRage(index);

            return self.data[index] orelse SlabError.EmptySlot;
        }

        inline fn findFreeSlot(self: *Self) !usize {
            for (self.data, 0..) |bucket, i| {
                if (bucket == null)
                    return i;
            }
            return SlabError.SlotsAreFull;
        }

        pub fn insert(self: *Self, value: T) !usize {
            const index: usize = try self.findFreeSlot();
            self.data[index] = value;
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
    const value = try slab.get_ptr(2500);
    try expectEqual(value.*, 40);
}
