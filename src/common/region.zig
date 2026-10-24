const std = @import("std");
const expect = std.testing.expect;
const t = std.testing;

/// Maximum alignment guaranteed for memory returned by a region.
pub const HEAP_ALIGNMENT: usize = 16;

pub const RegionError = error{
    /// A region requires a non-zero capacity.
    ZeroCapacity,
    /// The requested region capacity cannot form a valid layout.
    InvalidAllocationLayout,
    /// The host allocator could not allocate the requested region.
    AllocationFailure,
    /// A reservation attempted to reserve zero bytes.
    ZeroSizedReservation,
    /// A reservation requires alignment that the region cannot
    /// guarantee.
    UnsupportedAlignment,
    /// Alignment was zero or not a power of two.
    InvalidAlignment,
    /// Reservation alignment or size arithmetic overflowed.
    ReservationArithmeticOverflow,
    /// A reservation does not fit in the remaining region
    /// capacity.
    OutOfSpace,
};

/// Owns a continguous bump-allocation region.
///
/// Memory returned by `Region.reserve` is uninitialized. Calling
/// `Region.reset` invalidates every reservation previously returned
/// by the region.
pub const Region = struct {
    memory: []u8,
    raw_memory: []u8,
    offset: usize,
    backing_allocator: std.mem.Allocator,

    /// Initializes a new allocation region backed by the host allocator.
    ///
    /// ### Safety and Invariants
    /// * **Non-Zero Invariant:** `requested_capacity` must be greater than zero.
    /// * **Pointer Provenance:** The total allocation size, including alignment
    ///   padding, must be strictly less than `std.math.maxInt(isize)`. This
    ///   ensures the region's capacity remains within the range representable
    ///   by `isize`.
    /// * **Ownership:** On success, ownership of the backing allocation is
    ///   transferred to the returned `Region`. The caller must eventually
    ///   invoke `deinit()` to release the allocation.
    /// * **Alignment:** The backing allocation includes additional space to
    ///   ensure the region's starting address is aligned to `HEAP_ALIGNMENT`.
    ///
    /// ### Error Returns
    /// * `error.ZeroCapacity` if `requested_capacity == 0`.
    /// * `error.InvalidAllocationLayout` if `requested_capacity + HEAP_ALIGNMENT`
    ///   would be greater than or equal to `std.math.maxInt(isize)`.
    /// * `error.AllocationFailure` if the backing allocator cannot allocate
    ///   the required memory.
    pub fn init(backing_allocator: std.mem.Allocator, requested_capacity: usize) RegionError!Region {
        if (requested_capacity == 0) {
            return RegionError.ZeroCapacity;
        }

        const max_size = @as(usize, std.math.maxInt(isize));

        if (requested_capacity >= max_size - HEAP_ALIGNMENT) {
            return RegionError.InvalidAllocationLayout;
        }

        // We add the `HEAP_ALIGNMENT` to the `requested_capacity`
        // so that we have enough spare room to align the start
        // of the region memory on an address that's aligned
        // to the `HEAP_ALIGNMENT` value.
        const oversized_capacity = requested_capacity + HEAP_ALIGNMENT;

        const raw_memory = backing_allocator.alloc(u8, oversized_capacity) catch {
            return RegionError.AllocationFailure;
        };

        const raw_addr = @intFromPtr(raw_memory.ptr);
        const aligned_addr = std.mem.alignForward(usize, raw_addr, HEAP_ALIGNMENT);

        const aligned_ptr: [*]u8 = @ptrFromInt(aligned_addr);
        const memory = aligned_ptr[0..requested_capacity];

        return Region{
            .raw_memory = raw_memory,
            .memory = memory,
            .offset = 0,
            .backing_allocator = backing_allocator,
        };
    }

    /// Deinitialize the memory allocated in the init method.
    ///
    /// ### Safety
    /// * Deinit must only be called once.
    /// * Once called, the region is no longer usable.
    pub fn deinit(self: *Region) void {
        self.backing_allocator.free(self.raw_memory);
    }

    /// Returns this region's total capacity in bytes.
    pub fn capacity(self: *Region) usize {
        return self.memory.len;
    }

    /// Returns the number of bytes already reserved.
    pub fn allocated(self: *Region) usize {
        return self.offset;
    }

    /// Returns the number of bytes available for future reservations.
    pub fn remaining(self: *Region) usize {
        return self.capacity() - self.allocated();
    }

    /// Reserves `size` bytes of uninitialized memory.
    ///
    /// ### Safety and Invariants
    /// * **Alignment:** The requested `alignment` must not exceed `HEAP_ALIGNMENT`.
    /// * **Cursor Position:** A failed reservation leaves the allocation cursor unchanged.
    ///
    /// ### Error Returns
    /// * `RegionError.ZeroSizedReservation` if `size == 0`
    /// * `RegionError.UnsupportedAlignment` if `alignment > HEAP_ALIGNMENT`
    /// * `RegionError.ReservationArithmeticOverflow` if the aligned offet plus the `size`
    /// would cause integer overflow.
    /// * `RegionError.OutOfSpace` if the aligned offset plus the `size` exceeds `capacity()`
    /// * `RegionError.InvalidAlignment` if the alignment requested is not a power of two or zero.
    pub fn reserve(self: *Region, size: usize, alignment: usize) RegionError!usize {
        if (size == 0) {
            return RegionError.ZeroSizedReservation;
        }

        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) {
            return RegionError.InvalidAlignment;
        }

        if (alignment > HEAP_ALIGNMENT) {
            return RegionError.UnsupportedAlignment;
        }

        const new_pointer = std.mem.alignForward(usize, self.offset, alignment);

        const end_offset = std.math.add(usize, new_pointer, size) catch {
            return RegionError.ReservationArithmeticOverflow;
        };

        if (end_offset > self.capacity()) {
            return RegionError.OutOfSpace;
        }

        self.offset = end_offset;
        return new_pointer;
    }

    /// Resets the internal pointer back to the start of the memory region.
    ///
    /// ### Safety
    /// * Calling this method invalidates all previous reservations provided
    /// by this region.
    /// * The region is still usable for future reservations.
    pub fn reset(self: *Region) void {
        self.offset = 0;
    }
};

test "Region aligns reservations correctly" {
    const allocator = std.testing.allocator;

    var region = try Region.init(allocator, 12);
    defer region.deinit();

    const offset = try region.reserve(4, 8);
    // Since the offset starts at 0, the pointer should be zero
    try t.expectEqual(0, offset);
    // Since the pointer is at zero, and size is 4, would should have allocated 4
    try t.expectEqual(4, region.allocated());

    const next_offset = try region.reserve(4, 8);
    // Since the offset was at 4, alignment of 8 should make the new
    // pointer start at 8.
    try t.expectEqual(8, next_offset);
    // Since the size is still four, then the new offset should be 12
    try t.expectEqual(12, region.allocated());
}

test "Region rejects initial capacity of zero" {
    const allocator = std.testing.allocator;
    const result = Region.init(allocator, 0);
    try t.expectError(RegionError.ZeroCapacity, result);
}

test "Region rejects invalid capacity greater than the max isize" {
    const allocator = std.testing.allocator;
    const result = Region.init(allocator, @as(usize, std.math.maxInt(isize)));
    try t.expectError(RegionError.InvalidAllocationLayout, result);
}

test "Region is not created when allocation fails" {
    const allocator = std.testing.failing_allocator;
    const result = Region.init(allocator, 100);
    try t.expectError(RegionError.AllocationFailure, result);
}

test "Region does not reserve zero size" {
    const allocator = std.testing.allocator;
    var region = try Region.init(allocator, 100);
    defer region.deinit();
    const result = region.reserve(0, 8);
    try t.expectError(RegionError.ZeroSizedReservation, result);
    try t.expectEqual(0, region.allocated());
}

test "Region does not reserve when alignment too large" {
    const allocator = std.testing.allocator;
    var region = try Region.init(allocator, 100);
    defer region.deinit();
    const result = region.reserve(10, 32); // 32 > 16
    try t.expectError(RegionError.UnsupportedAlignment, result);
    try t.expectEqual(0, region.allocated());
}

test "Region does not reserve when size overflows" {
    const allocator = std.testing.allocator;
    var region = try Region.init(allocator, 100);
    defer region.deinit();
    // reserve some space so the pointer is not at zero
    const first = try region.reserve(50, 8);
    try t.expectEqual(0, first);
    try t.expectEqual(50, region.allocated());

    const result = region.reserve(std.math.maxInt(usize), 8);
    try t.expectError(RegionError.ReservationArithmeticOverflow, result);
    try t.expectEqual(50, region.allocated());
}

test "Region does not allocate when out of space" {
    const allocator = std.testing.allocator;
    var region = try Region.init(allocator, 100);
    defer region.deinit();
    const result = region.reserve(101, 8);
    try t.expectError(RegionError.OutOfSpace, result);
    try t.expectEqual(0, region.allocated());
}

test "Region does not allocate when alignment is zero" {
    const allocator = std.testing.allocator;
    var region = try Region.init(allocator, 100);
    defer region.deinit();
    const result = region.reserve(10, 0);
    try t.expectError(RegionError.InvalidAlignment, result);
    try t.expectEqual(0, region.allocated());
}

test "Region does not allocate when alignment is not power of two" {
    const allocator = std.testing.allocator;
    var region = try Region.init(allocator, 100);
    defer region.deinit();
    const result = region.reserve(10, 3); // alignment of 3;
    try t.expectError(RegionError.InvalidAlignment, result);
    try t.expectEqual(0, region.allocated());
}

test "Region aligns actual addresses for every supported alignment" {
    const allocator = std.testing.allocator;
    var region = try Region.init(allocator, 128);
    defer region.deinit();

    const alignments = [_]usize{ 1, 2, 4, 8, 16 };

    for (alignments) |alignment| {
        const offset = try region.reserve(1, alignment);
        const address = @intFromPtr(region.memory.ptr + offset);

        try t.expectEqual(@as(usize, 0), address % alignment);
    }
}

test "Region allows a reservation to exactly fill its capacity" {
    const allocator = std.testing.allocator;
    var region = try Region.init(allocator, 16);
    defer region.deinit();

    const offset = try region.reserve(16, 16);

    try t.expectEqual(@as(usize, 0), offset);
    try t.expectEqual(@as(usize, 16), region.allocated());
    try t.expectEqual(@as(usize, 0), region.remaining());
}

test "Region rejects a reservation when alignment padding exceeds capacity" {
    const allocator = std.testing.allocator;
    var region = try Region.init(allocator, 9);
    defer region.deinit();

    const first = try region.reserve(1, 1);
    try t.expectEqual(@as(usize, 0), first);

    const result = region.reserve(8, 8);

    try t.expectError(RegionError.OutOfSpace, result);
    try t.expectEqual(@as(usize, 1), region.allocated());
}

test "Region reset allows memory to be reserved again" {
    const allocator = std.testing.allocator;
    var region = try Region.init(allocator, 16);
    defer region.deinit();

    _ = try region.reserve(12, 4);

    region.reset();

    try t.expectEqual(@as(usize, 0), region.allocated());
    try t.expectEqual(@as(usize, 16), region.remaining());

    const offset = try region.reserve(16, 16);

    try t.expectEqual(@as(usize, 0), offset);
    try t.expectEqual(@as(usize, 16), region.allocated());
}

test "Region rejects non-power-of-two alignment without changing state" {
    const allocator = std.testing.allocator;
    var region = try Region.init(allocator, 32);
    defer region.deinit();

    _ = try region.reserve(5, 1);
    const previous_offset = region.allocated();

    const result = region.reserve(4, 3);

    try t.expectError(RegionError.InvalidAlignment, result);
    try t.expectEqual(previous_offset, region.allocated());
}

test "Region rejects unsupported power-of-two alignment without changing state" {
    const allocator = std.testing.allocator;
    var region = try Region.init(allocator, 32);
    defer region.deinit();

    _ = try region.reserve(5, 1);
    const previous_offset = region.allocated();

    const result = region.reserve(4, 32);

    try t.expectError(RegionError.UnsupportedAlignment, result);
    try t.expectEqual(previous_offset, region.allocated());
}

test "Region rejects capacity at the maximum permitted allocation boundary" {
    const allocator = std.testing.allocator;
    const max_size = @as(usize, std.math.maxInt(isize));

    const result = Region.init(allocator, max_size - HEAP_ALIGNMENT);

    try t.expectError(RegionError.InvalidAllocationLayout, result);
}
