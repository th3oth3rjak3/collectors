const std = @import("std");

/// Describes the memory layout of a managed object's payload.
/// The compiler emits this descriptor so the collector can
/// identify managed references within the object during tracing.
///
/// Safety invariants:
/// - `payload_size` must describe the complete object payload in bytes.
/// - `payload_alignment` must be a nonzero power of two and must
///   match the alignment required by the payload.
/// - `reference_count` must equal the number of entries accessible
///   through `reference_offsets`.
/// - Every reference offset must identify a complete managed-reference
///   field within the payload. The offset must be valid for reading a
///   pointer without extending beyond `payload_size`.
/// - `reference_offsets` must point to readable memory containing at
///   least `reference_count` entries.
/// - The descriptor and its reference-offset array must remain valid
///   for as long as any managed object uses the descriptor.
///
/// The collector may validate descriptor invariants, but it relies on
/// the compiler to provide valid pointers and accurate object layouts.
pub const GcDescriptor = extern struct {
    /// The size of the object payload in bytes.
    payload_size: usize,

    /// The required alignment of the object payload in bytes.
    payload_alignment: usize,

    /// The number of managed-reference fields described by
    /// `reference_offsets`.
    reference_count: usize,

    /// A pointer to an array of byte offsets identifying the
    /// managed-reference fields within the payload. Each offset
    /// is measured from the beginning of the payload.
    reference_offsets: [*]const usize,

    /// Returns a read-only slice containing the byte offsets of all managed-reference
    /// fields within the object payload. The slice length is determined by
    /// `reference_count`.
    pub fn getReferenceOffsets(self: *const GcDescriptor) []const usize {
        return self.reference_offsets[0..self.reference_count];
    }

    /// Validates the descriptor's structural invariants, including payload size,
    /// payload alignment, and the bounds and alignment of managed-reference offsets.
    /// This does not verify that `reference_offsets` points to readable memory.
    pub fn isValid(self: *const GcDescriptor) bool {
        if (self.payload_alignment == 0) {
            return false;
        }

        if (!std.math.isPowerOfTwo(self.payload_alignment)) {
            return false;
        }

        if (self.payload_size == 0) {
            return false;
        }

        const pointer_width = @sizeOf(usize);

        for (0..self.reference_count) |idx| {
            const offset = self.reference_offsets[idx];
            const end = std.math.add(usize, offset, pointer_width) catch {
                return false;
            };

            if (end > self.payload_size) {
                return false;
            }
        }

        return true;
    }
};

test "valid descriptor with no references" {
    const descriptor = GcDescriptor{
        .payload_size = 16,
        .payload_alignment = 8,
        .reference_count = 0,
        .reference_offsets = &.{},
    };

    try std.testing.expect(descriptor.isValid());
}

test "rejects zero payload size" {
    const descriptor = GcDescriptor{
        .payload_size = 0,
        .payload_alignment = 8,
        .reference_count = 0,
        .reference_offsets = &.{},
    };

    try std.testing.expect(!descriptor.isValid());
}

test "rejects zero payload alignment" {
    const descriptor = GcDescriptor{
        .payload_size = 16,
        .payload_alignment = 0,
        .reference_count = 0,
        .reference_offsets = &.{},
    };

    try std.testing.expect(!descriptor.isValid());
}

test "rejects non-power-of-two payload alignment" {
    const descriptor = GcDescriptor{
        .payload_size = 16,
        .payload_alignment = 3,
        .reference_count = 0,
        .reference_offsets = &.{},
    };

    try std.testing.expect(!descriptor.isValid());
}

test "accepts valid reference offset" {
    const pointer_width = @sizeOf(usize);
    const offsets = [_]usize{pointer_width};

    const descriptor = GcDescriptor{
        .payload_size = 2 * pointer_width,
        .payload_alignment = pointer_width,
        .reference_count = offsets.len,
        .reference_offsets = &offsets,
    };

    try std.testing.expect(descriptor.isValid());
}

test "rejects reference offset that extends beyond payload" {
    const pointer_width = @sizeOf(usize);
    const payload_size = 2 * pointer_width;
    const offsets = [_]usize{payload_size - pointer_width + 1};

    const descriptor = GcDescriptor{
        .payload_size = payload_size,
        .payload_alignment = pointer_width,
        .reference_count = offsets.len,
        .reference_offsets = &offsets,
    };

    try std.testing.expect(!descriptor.isValid());
}

test "getReferenceOffsets returns all offsets" {
    const offsets = [_]usize{ 0, 8, 16 };

    const descriptor = GcDescriptor{
        .payload_size = 24,
        .payload_alignment = 8,
        .reference_count = offsets.len,
        .reference_offsets = &offsets,
    };

    const result = descriptor.getReferenceOffsets();

    try std.testing.expectEqual(offsets.len, result.len);
    try std.testing.expectEqualSlices(usize, &offsets, result);
}

test "getReferenceOffsets returns a single offset" {
    const offsets = [_]usize{8};

    const descriptor = GcDescriptor{
        .payload_size = 16,
        .payload_alignment = 8,
        .reference_count = offsets.len,
        .reference_offsets = &offsets,
    };

    const result = descriptor.getReferenceOffsets();

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(usize, 8), result[0]);
}

test "getReferenceOffsets returns an empty slice when there are no references" {
    const offsets = [_]usize{};

    const descriptor = GcDescriptor{
        .payload_size = 16,
        .payload_alignment = 8,
        .reference_count = 0,
        .reference_offsets = &offsets,
    };

    const result = descriptor.getReferenceOffsets();

    try std.testing.expectEqual(@as(usize, 0), result.len);
}
