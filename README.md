# zig-slab

A configurable slab allocator implemented in Zig. The library provides both
dynamic and static storage backends and optional growth logic, making it easy to
hand out stable indices for short-lived objects without paying per-insertion
allocation costs.

## Features
- Configurable safety checks (`.safe`) for bounds and usage validation
- Static or allocator-backed dynamic storage
- Optional automatic growth when the occupancy threshold is reached
- Slot-level operations: `insert`, `insertAt`, `remove`, `get`, `get_ptr`
- Simple API suited for ECS systems, job queues, or handle tables

## Getting Started

Add the module to your `build.zig`:

```zig
const slab = b.dependency("zig-slab", .{}).module("zig-slab");
const exe = b.addExecutable(.{ .name = "my-app", .root_source_file = b.path("src/main.zig") });
exe.root_module.addImport("zig-slab", slab);
```

Create a slab instance (dynamic storage example):

```zig
const Slab = createSlab(u32, .{
    .storage = .dynamic,
    .safe = true,
    .grow = .{
        .enable = true,
        .threshold = 0.75,
        .factor = 1.5,
    },
});

var slab = try Slab.initWithSize(allocator, 16);
defer slab.deinit();

const idx = try slab.insert(42);
try slab.insertAt(3, 99);
try expectEqual(try slab.get(idx), 42);
```

Static storage works without an allocator:

```zig
const StaticSlab = createSlab(MyStruct, .{
    .storage = .static,
    .size = 64,
    .safe = false, // skip bounds checks for maximum speed
});

var slab = try StaticSlab.init(null);
```

## Concurrency

`zig-slab` does not add internal synchronization. Multiple threads may interact
with the same slab as long as they coordinate to avoid touching the same slot
concurrently (e.g. by partitioning indices or protecting access with a mutex).
The unit tests include simple multithreaded scenarios to demonstrate this usage.

## Development

Run the unit tests (including multithreaded coverage):

```bash
zig build test
# or directly
zig test src/main.zig
```

The project currently targets Zig 0.15. Update the code or build scripts if you
are using a newer compiler release.
