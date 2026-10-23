const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Owns a continguous bump-allocation region.
///
/// Memory returned by `Region.reserve` is uninitialized. Calling
/// `Region.reset` invalidates every reservation previously returned
/// by the region.
pub const Region = struct {
    memory: []u8,
    offset: usize,
    /// The region now securely owns its backing allocator
    allocator: std.mem.Allocator,

    pub fn init(backing_allocator: std.mem.Allocator, capacity: usize) !Region {
        const memory = try backing_allocator.alloc(u8, capacity);
        return Region{
            .memory = memory,
            .offset = 0,
            .allocator = backing_allocator,
        };
    }

    /// Bulletproof cleanup: No parameters needed, zero chance of an allocator mismatch!
    pub fn deinit(self: *Region) void {
        self.allocator.free(self.memory);
    }

    pub fn allocate(self: *Region, size: usize) ?usize {
        if (size == 0) return null;

        const aligned_size = std.mem.alignForward(usize, size, 16);

        if (self.offset + aligned_size > self.memory.len) {
            return null;
        }

        const allocated_offset = self.offset;
        self.offset += aligned_size;
        return allocated_offset;
    }
};

test "Region handles allocation and cleanups gracefully" {
    const allocator = std.testing.allocator;

    // Need to allocate at least 16 bytes for it to be aligned.
    var reg = try Region.init(allocator, 24);
    defer reg.deinit();

    const offset = reg.allocate(4);
    try expectEqual(@as(?usize, 0), offset);
}

test "Region won't allocate when misaligned" {
    const allocator = std.testing.allocator;
    var region = try Region.init(allocator, 14); // less than 16 byte alignment.
    defer region.deinit();

    const offset = region.allocate(4);
    try expectEqual(null, offset); // Couldn't allocate 16 bytes in a 14 byte capacity.
}
