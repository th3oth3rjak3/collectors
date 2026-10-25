const std = @import("std");

const POINTER_SIZE: usize = @sizeOf(*anyopaque);
const REF_ALIGNMENT: usize = @alignOf(Ref);

/// A nullable pointer-sized value that the runtime treats as a managed reference.
///
/// The bitmap describes *which words* are references. The collector still has
/// to validate each non-null value against its own allocation table before
/// marking it; this module does not decide whether a pointer is managed.
pub const Ref = ?*anyopaque;

/// Describes an object type's memory layout for garbage collection.
///
/// `size` and `alignment` describe the object's payload. `ptr_bytes`
/// specifies the prefix that may contain managed references, and `gc_data`
/// is a bitmap identifying which pointer-sized words in that prefix
/// contain references.
///
/// Bitmap format:
/// - Each bit describes one pointer-sized word.
/// - Bit 0 describes the first word, bit 1 the second, and so on.
/// - Bits are ordered least-significant first within each byte.
/// - A set bit indicates a managed reference; a clear bit indicates
///   ordinary data.
/// - `gc_data` describes `ptr_bytes / @sizeOf(usize)` words.
///   Bytes beyond `ptr_bytes` are not scanned.
///
/// The descriptor and bitmap are shared, immutable metadata that may be
/// emitted by a compiler or constructed by a runtime.
pub const LayoutDescriptor = extern struct {
    /// Payload bytes occupied by one element.
    size: usize,

    /// Required alignment of an element's starting address. The allocator is
    /// responsible for satisfying this for each element/object.
    alignment: usize,

    /// Size in bytes of the payload prefix that may contain managed references.
    /// `gc_data` describes this region one pointer-sized word at a time. No
    /// managed references may occur beyond this prefix. Must not exceed `size`
    /// and must be a multiple of pointer size.
    ptr_bytes: usize,

    /// Pointer bitmap describing which pointer-sized words contain managed
    /// references. Its length is `ptr_bytes / @sizeOf(usize)` bits, rounded up
    /// to bytes. No separate length field is needed. Null indicates a
    /// pointer-free type.
    gc_data: ?[*]const u8,

    /// Validate fields whose values are directly checkable. This cannot prove
    /// that `gc_data` is readable or that a compiler/runtime emitted truthful
    /// layout metadata; those are descriptor-producer obligations.
    pub fn validate(self: *const LayoutDescriptor) LayoutError!void {
        if (self.size == 0) return error.InvalidSize;
        if (!std.math.isPowerOfTwo(self.alignment)) return error.InvalidAlignment;
        if (self.ptr_bytes > self.size) return error.InvalidPtrBytes;
        if (self.ptr_bytes % POINTER_SIZE != 0) {
            return error.InvalidPtrBytes;
        }
        if (self.ptr_bytes != 0 and self.alignment < REF_ALIGNMENT) {
            return error.InvalidAlignment;
        }

        if (self.ptr_bytes == 0) {
            if (self.gc_data != null) return error.UnexpectedBitmap;
        } else if (self.gc_data == null) {
            return error.MissingBitmap;
        }
    }

    /// Returns the number of bytes needed to store the pointer bitmap.
    ///
    /// Each bit describes one pointer-sized word in the `ptr_bytes` prefix.
    /// Since a byte holds 8 bits, the bitmap needs one byte for every 8 words,
    /// plus one extra byte if any words remain.
    pub fn bitmapByteCount(self: *const LayoutDescriptor) usize {
        const pointer_words = self.ptr_bytes / POINTER_SIZE;
        const full_bytes = pointer_words / 8;
        const has_remaining_words = pointer_words % 8 != 0;
        const extra_byte: usize = if (has_remaining_words) 1 else 0;

        return full_bytes + extra_byte;
    }

    /// Distance between starts of adjacent inline elements. Payload size and
    /// starting alignment are independent, so an element with a 12-byte payload
    /// and 8-byte alignment has a 16-byte element stride when placed in an array.
    /// This is derived, not stored in every descriptor. Requires a validated
    /// descriptor.
    pub fn elementStride(self: *const LayoutDescriptor) LayoutError!usize {
        const remainder = self.size % self.alignment;
        if (remainder == 0) return self.size;

        const padding = self.alignment - remainder;
        if (self.size > std.math.maxInt(usize) - padding) {
            return error.SizeOverflow;
        }
        return self.size + padding;
    }

    /// Scans an object payload or a contiguous allocation of repeated elements,
    /// reporting each non-null reference found.
    ///
    /// `allocation_size` is the logical payload size.
    /// Repeated elements occupy `elementStride() * count` bytes.
    ///
    /// Safety preconditions:
    /// - `self` is valid and remains readable, including its bitmap.
    /// - `payload[0..allocation_size]` is readable for the duration of this call.
    /// - Every bitmap-marked slot contains an initialized nullable pointer.
    /// - The payload base satisfies `self.alignment`.
    /// - The world is stopped, so payload bytes cannot change while being read.
    ///
    /// The mark phase handles foreign pointers and exact allocation-base lookup.
    pub fn scanReferences(
        self: *const LayoutDescriptor,
        payload: [*]const u8,
        allocation_size: usize,
        context: *anyopaque,
        visit: VisitFn,
    ) ScanError!void {
        if (self.ptr_bytes == 0) return;
        if (allocation_size < self.size) return error.AllocationTooSmall;
        if (@intFromPtr(payload) % self.alignment != 0) {
            return error.MisalignedPayload;
        }

        // For a single payload, the logical extent may be `size` even if size is
        // not alignment-rounded. For repeated elements, storage uses aligned stride.
        const stride = try self.elementStride();
        const element_count = if (allocation_size == self.size)
            1
        else blk: {
            if (allocation_size % stride != 0) return error.InvalidAllocationSize;
            break :blk allocation_size / stride;
        };

        const bitmap = self.gc_data.?;
        const pointer_words = self.ptr_bytes / POINTER_SIZE;
        var element_index: usize = 0;
        while (element_index < element_count) : (element_index += 1) {
            const element_offset = element_index * stride;
            var word_index: usize = 0;
            while (word_index < pointer_words) : (word_index += 1) {
                const byte = bitmap[word_index / 8];
                const bit: u3 = @intCast(word_index % 8);
                const mask = @as(u8, 1) << bit;
                if ((byte & mask) == 0) continue;

                const slot_offset = element_offset + word_index * POINTER_SIZE;

                const slot: *const Ref = @ptrCast(@alignCast(&payload[slot_offset]));
                const candidate = slot.*;

                if (candidate) |pointer| visit(context, pointer);
            }
        }
    }
};

pub const LayoutError = error{
    InvalidSize,
    InvalidAlignment,
    InvalidPtrBytes,
    MissingBitmap,
    UnexpectedBitmap,
    SizeOverflow,
};

pub const ScanError = LayoutError || error{
    AllocationTooSmall,
    InvalidAllocationSize,
    MisalignedPayload,
};

/// Called for each non-null reference identified by the bitmap.
///
/// The callback normally looks up `candidate` in the collector's allocation
/// table and marks it if it is the exact base pointer of a managed allocation.
/// It must not mutate the payload while scanning is in progress.
pub const VisitFn = *const fn (context: *anyopaque, candidate: *anyopaque) void;

const Capture = struct {
    values: [8]Ref = @splat(null),
    count: usize = 0,
};

fn captureReference(context: *anyopaque, candidate: *anyopaque) void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.values[capture.count] = candidate;
    capture.count += 1;
}

fn writeRef(bytes: []u8, offset: usize, value: Ref) void {
    @memcpy(bytes[offset..][0..POINTER_SIZE], std.mem.asBytes(&value));
}

test "pointer-free layouts need no bitmap" {
    const layout = LayoutDescriptor{
        .size = 12,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
    };

    try layout.validate();
    try std.testing.expectEqual(@as(usize, 0), layout.bitmapByteCount());
    try std.testing.expectEqual(@as(usize, 16), try layout.elementStride());
}

test "payload size need not be a multiple of alignment" {
    const bitmap = [_]u8{0b0000_0001};
    const layout = LayoutDescriptor{
        .size = @sizeOf(usize) + @sizeOf(u32),
        .alignment = @alignOf(usize),
        .ptr_bytes = @sizeOf(usize),
        .gc_data = &bitmap,
    };

    try layout.validate();
    try std.testing.expectEqual(
        @sizeOf(usize) + @sizeOf(u32),
        layout.size,
    );
    try std.testing.expectEqual(
        std.mem.alignForward(usize, layout.size, layout.alignment),
        try layout.elementStride(),
    );
}

test "rejects malformed descriptor fields" {
    const bitmap = [_]u8{1};

    const zero_size = LayoutDescriptor{
        .size = 0,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
    };
    try std.testing.expectError(error.InvalidSize, zero_size.validate());

    const bad_alignment = LayoutDescriptor{
        .size = 12,
        .alignment = 3,
        .ptr_bytes = 0,
        .gc_data = null,
    };
    try std.testing.expectError(error.InvalidAlignment, bad_alignment.validate());

    const bad_ptr_bytes = LayoutDescriptor{
        .size = @sizeOf(usize),
        .alignment = @alignOf(usize),
        .ptr_bytes = @sizeOf(usize) + 1,
        .gc_data = &bitmap,
    };
    try std.testing.expectError(error.InvalidPtrBytes, bad_ptr_bytes.validate());

    const missing_bitmap = LayoutDescriptor{
        .size = @sizeOf(usize),
        .alignment = @alignOf(usize),
        .ptr_bytes = @sizeOf(usize),
        .gc_data = null,
    };
    try std.testing.expectError(error.MissingBitmap, missing_bitmap.validate());
}

test "bitmap visits pointer words and skips scalar words" {
    const Mixed = extern struct {
        first: Ref,
        scalar_that_looks_like_a_pointer: usize,
        second: Ref,
    };

    // Word 0 is a pointer, word 1 is scalar, word 2 is a pointer.
    const bitmap = [_]u8{0b0000_0101};
    const layout = LayoutDescriptor{
        .size = @sizeOf(Mixed),
        .alignment = @alignOf(Mixed),
        .ptr_bytes = 3 * @sizeOf(usize),
        .gc_data = &bitmap,
    };

    var first_object: u8 = 1;
    var second_object: u8 = 2;
    var decoy_object: u8 = 3;
    const first_ref: Ref = @ptrCast(&first_object);
    const second_ref: Ref = @ptrCast(&second_object);

    const value = Mixed{
        .first = first_ref,
        .scalar_that_looks_like_a_pointer = @intFromPtr(&decoy_object),
        .second = second_ref,
    };

    var capture = Capture{};
    try layout.scanReferences(
        @ptrCast(&value),
        @sizeOf(Mixed),
        &capture,
        captureReference,
    );

    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expect(capture.values[0] == first_ref);
    try std.testing.expect(capture.values[1] == second_ref);
}

test "one element bitmap is reused for a collection allocation" {
    const Element = extern struct {
        next: Ref,
        number: usize,
    };
    const bitmap = [_]u8{0b0000_0001};
    const layout = LayoutDescriptor{
        .size = @sizeOf(Element),
        .alignment = @alignOf(Element),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = &bitmap,
    };

    var a: u8 = 10;
    var b: u8 = 20;
    var c: u8 = 30;
    const expected = [_]Ref{
        @ptrCast(&a),
        @ptrCast(&b),
        @ptrCast(&c),
    };
    const elements = [_]Element{
        .{ .next = expected[0], .number = 101 },
        .{ .next = expected[1], .number = 202 },
        .{ .next = expected[2], .number = 303 },
    };

    var capture = Capture{};
    try layout.scanReferences(
        @ptrCast(&elements),
        @sizeOf(@TypeOf(elements)),
        &capture,
        captureReference,
    );

    try std.testing.expectEqual(expected.len, capture.count);
    for (expected, 0..) |reference, i| {
        try std.testing.expect(capture.values[i] == reference);
    }
}

test "repeated elements use aligned starts without padding the descriptor size" {
    const bitmap = [_]u8{0b0000_0001};
    const payload_size = @sizeOf(usize) + @sizeOf(u32);
    const alignment = @alignOf(usize);
    const layout = LayoutDescriptor{
        .size = payload_size,
        .alignment = alignment,
        .ptr_bytes = @sizeOf(usize),
        .gc_data = &bitmap,
    };
    const stride = comptime std.mem.alignForward(usize, payload_size, alignment);
    try std.testing.expectEqual(stride, try layout.elementStride());

    var a: u8 = 1;
    var b: u8 = 2;
    const first_ref: Ref = @ptrCast(&a);
    const second_ref: Ref = @ptrCast(&b);

    // Two payloads, each beginning on an aligned stride. The payload bytes per
    // element remain `payload_size`; inter-element padding is not in the type.
    var storage: [2 * stride]u8 align(@alignOf(usize)) = @splat(0);
    writeRef(storage[0..], 0, first_ref);
    writeRef(storage[0..], stride, second_ref);

    var capture = Capture{};
    try layout.scanReferences(
        @ptrCast(&storage),
        storage.len,
        &capture,
        captureReference,
    );

    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expect(capture.values[0] == first_ref);
    try std.testing.expect(capture.values[1] == second_ref);
}

test "rejects non-element-sized collection storage" {
    const bitmap = [_]u8{1};
    const layout = LayoutDescriptor{
        .size = @sizeOf(usize),
        .alignment = @alignOf(usize),
        .ptr_bytes = @sizeOf(usize),
        .gc_data = &bitmap,
    };

    var storage: [@sizeOf(usize) + 1]u8 align(@alignOf(usize)) = @splat(0);
    var capture = Capture{};
    try std.testing.expectError(
        error.InvalidAllocationSize,
        layout.scanReferences(
            @ptrCast(&storage),
            storage.len,
            &capture,
            captureReference,
        ),
    );
}

test "rejects reference layout with insufficient alignment" {
    if (REF_ALIGNMENT == 1) return error.SkipZigTest;

    const bitmap = [_]u8{0b0000_0001};
    const layout = LayoutDescriptor{
        .size = POINTER_SIZE,
        .alignment = 1,
        .ptr_bytes = POINTER_SIZE,
        .gc_data = &bitmap,
    };

    try std.testing.expectError(
        error.InvalidAlignment,
        layout.validate(),
    );
}

test "rejects misaligned payload base" {
    if (REF_ALIGNMENT == 1) return error.SkipZigTest;

    const bitmap = [_]u8{0b0000_0001};
    const layout = LayoutDescriptor{
        .size = POINTER_SIZE,
        .alignment = REF_ALIGNMENT,
        .ptr_bytes = POINTER_SIZE,
        .gc_data = &bitmap,
    };
    try layout.validate();

    var storage: [POINTER_SIZE + 1]u8 align(REF_ALIGNMENT) = @splat(0);
    var capture = Capture{};

    try std.testing.expectError(
        error.MisalignedPayload,
        layout.scanReferences(
            @ptrCast(&storage[1]),
            POINTER_SIZE,
            &capture,
            captureReference,
        ),
    );
}

test "reference slots stay aligned across padded elements" {
    const element_alignment = REF_ALIGNMENT * 2;
    const payload_size = 2 * POINTER_SIZE + @sizeOf(u32);
    const stride = comptime std.mem.alignForward(
        usize,
        payload_size,
        element_alignment,
    );

    // Only word 1 contains a reference; word 0 must be ignored.
    const bitmap = [_]u8{0b0000_0010};
    const layout = LayoutDescriptor{
        .size = payload_size,
        .alignment = element_alignment,
        .ptr_bytes = 2 * POINTER_SIZE,
        .gc_data = &bitmap,
    };
    try layout.validate();

    try std.testing.expectEqual(
        stride,
        try layout.elementStride(),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        POINTER_SIZE % REF_ALIGNMENT,
    );

    var first_target: u8 = 1;
    var second_target: u8 = 2;
    var decoy_target: u8 = 3;

    const first_ref: Ref = @ptrCast(&first_target);
    const second_ref: Ref = @ptrCast(&second_target);
    const decoy_ref: Ref = @ptrCast(&decoy_target);

    var storage: [2 * stride]u8 align(element_alignment) = @splat(0);

    // Element 0: decoy in word 0, real reference in word 1.
    writeRef(storage[0..], 0, decoy_ref);
    writeRef(storage[0..], POINTER_SIZE, first_ref);

    // Element 1: same layout, beginning at the padded stride.
    writeRef(storage[0..], stride, decoy_ref);
    writeRef(storage[0..], stride + POINTER_SIZE, second_ref);

    var capture = Capture{};
    try layout.scanReferences(
        @ptrCast(&storage),
        storage.len,
        &capture,
        captureReference,
    );

    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expect(capture.values[0] == first_ref);
    try std.testing.expect(capture.values[1] == second_ref);
}
