const std = @import("std");
const expectEqual = std.testing.expectEqual;

/// The ObjectHeader is a special struct that sits right in front
/// of every single object we allocate on our heap.
pub const ObjectHeader = packed struct(u64) {
    /// 1 bit: True if the collector found this object is still alive.
    is_marked: bool,

    /// 31 bits: Reserved padding for future collectors (Cheney, Generational, etc.)
    padding: u31,

    /// 32 bits: The total size of this object in bytes (including this header).
    total_size: u32,
};

test "ObjectHeader fits precisely into 8 bytes" {
    // A u64 is exactly 8 bytes. Because we used 'packed struct(u64)',
    // Zig guarantees this struct is exactly 8 bytes in memory!
    try expectEqual(8, @sizeOf(ObjectHeader));
}
