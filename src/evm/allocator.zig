const std = @import("std");
const builtin = @import("builtin");

/// zesu_allocator — the allocator used for zesu's internal allocations.
///
/// Runtime-injectable singleton. The 268 internal `get()` call sites across the EVM
/// and stateless modules all read this one global, so a consumer installs its
/// allocator once at startup with `set()` and every downstream allocation observes it.
///
/// If never set:
///   - native targets default to std.heap.c_allocator (zesu's own apps/tools/tests),
///   - freestanding targets panic — a zkVM guest MUST install an allocator before use.
///
/// Injection happens at runtime, not build time, so the single exposed `zesu_allocator`
/// module works for every target without rewiring the build graph. Examples:
///   zesu_allocator.set(fixed_buffer.allocator());   // zkVM guest heap region
///   zesu_allocator.set(arena.allocator());          // native tests
///
/// Lifetime: the backing allocator state (FixedBufferAllocator/arena/…) must outlive every
///   `get()` call — in practice for the whole program/guest lifetime.
/// Concurrency: on hosted targets the allocator is per thread: `set()` applies to the calling
///   thread, so executions on different threads can each use their own allocator. A thread that
///   never calls `set()` gets the default. Freestanding targets (zkVM guests: single-threaded, no
///   thread-local storage) keep one global.
const per_thread = builtin.os.tag != .freestanding;
var current_global: ?std.mem.Allocator = null;
threadlocal var current_thread: ?std.mem.Allocator = null;

inline fn current() *?std.mem.Allocator {
    return if (per_thread) &current_thread else &current_global;
}

/// Install the allocator returned by subsequent `get()` calls (on this thread, when hosted).
pub fn set(allocator: std.mem.Allocator) void {
    current().* = allocator;
}

pub fn get() std.mem.Allocator {
    return current().* orelse defaultAllocator();
}

fn defaultAllocator() std.mem.Allocator {
    // Explicit if/else so the comptime-known target prunes the untaken branch: on freestanding
    // `std.heap.c_allocator` (which references libc malloc/free) is never analyzed.
    if (builtin.target.os.tag == .freestanding) {
        @panic("zesu allocator not set: call zesu_allocator.set() before use");
    } else {
        return std.heap.c_allocator;
    }
}

test "set applies to the calling thread" {
    var buf_a: [64]u8 = undefined;
    var fba_a = std.heap.FixedBufferAllocator.init(&buf_a);
    set(fba_a.allocator());
    defer current().* = null;

    const Worker = struct {
        fn run(main_ptr: *anyopaque, saw_own: *bool) void {
            // A new thread starts with the default, not the allocator another thread set.
            saw_own.* = get().ptr != main_ptr;
            var buf_b: [64]u8 = undefined;
            var fba_b = std.heap.FixedBufferAllocator.init(&buf_b);
            set(fba_b.allocator());
            saw_own.* = saw_own.* and get().ptr == @as(*anyopaque, @ptrCast(&fba_b));
        }
    };
    var saw_own = false;
    const t = try std.Thread.spawn(.{}, Worker.run, .{ @as(*anyopaque, @ptrCast(&fba_a)), &saw_own });
    t.join();
    try std.testing.expect(saw_own);
    // The worker's set() did not change this thread's allocator.
    try std.testing.expect(get().ptr == @as(*anyopaque, @ptrCast(&fba_a)));
}
