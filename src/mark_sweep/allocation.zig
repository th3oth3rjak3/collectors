const std = @import("std");
const LayoutDescriptor = @import("../common/layout.zig").LayoutDescriptor;
const Ref = @import("../common/layout.zig").Ref;
const ObjectHeader = @import("object_header.zig").ObjectHeader;

/// Any error produced while creating an allocation
pub const AllocationError = error{
    /// Produced when trying to allocate zero elements, which is a logical
    /// error.
    ZeroSizedAllocation,
    /// Produced when `AllocationKind.single` is selected
    /// and element quantity is not 1.
    AllocationKindMismatch,
    /// Occurs when there's not enough memory to create
    /// the new allocation.
    OutOfMemory,
};

/// Helps to distinguish between a single element allocation
/// and an array containing a single object.
const AllocationKind = enum {
    single,
    array,
};

/// Records an allocation created by the garbage collector.
/// The allocation is used for bookkeeping and to free memory
/// later during the reclamation phase.
pub const Allocation = struct {
    /// The start address of the allocation requested by the garbage collector.
    /// This is the pointer that should be used to free the allocation.
    start: [*]u8,
    /// The total size of the initial allocation, used to free the memory.
    size: usize,
    /// The alignment of the requested allocation.
    alignment: std.mem.Alignment,
    /// The `header` is used during marking and to lookup descriptor information
    /// for tracing.
    header: *ObjectHeader,
    /// A pointer to the payload data.
    payload: [*]u8,
    /// The number of objects created for this allocation.
    /// When `quantity` is greater than 1 and the `descriptor.element_type`
    /// is `reference`, this quantity can be used to find the individual references
    /// for tracing and sweeping.
    quantity: usize,
    /// Single object or a collection.
    kind: AllocationKind,

    /// Initialize an `Allocation` for a given `quantity` of elements.
    ///
    /// ### Safety
    /// * When the `descriptor.element_type` is scalar, this method uses `descriptor.elementStride`
    ///   to ensure enough space exists between elements for padding and alignment purposes. The caller
    ///   must ensure that they place the actual objects at the appropriate locations after allocation
    ///   occurs. When `deinit` is called later, any scalar values stored in the array are deleted.
    /// * When the `descriptor.element_type` is reference and `kind` is single this method reserves enough
    ///   space for the entire object and a header.
    /// * When the `descriptor.element_type` is reference and `kind` is array, this method reserves
    ///   enough space for `quantity * @sizeOf(Ref)` objects plus a header. For collections, the caller
    ///   is responsible to place the values at the given reference locations from the start of the payload.
    pub fn init(allocator: std.mem.Allocator, descriptor: *const LayoutDescriptor, quantity: usize, kind: AllocationKind) AllocationError!Allocation {
        if (quantity == 0) {
            return AllocationError.ZeroSizedAllocation;
        }

        if (quantity > 1 and kind == .single) {
            return AllocationError.AllocationKindMismatch;
        }

        if (quantity == 1 and kind == .single) {
            return allocate_single_element(allocator, descriptor);
        }

        return allocate_collection(allocator, descriptor, quantity);
    }

    fn allocate_single_element(allocator: std.mem.Allocator, descriptor: *const LayoutDescriptor) AllocationError!Allocation {
        // Reserve enough space for the header. On 64-bit systems, Ref will be 8 bytes.
        // If the alignment is less than 8 bytes for the descriptor, we still need 8 byte alignment
        // for the header.
        // When the alignment is greater than 8 bytes, we still need to reserve enough space for the
        // header, but we should reserve excess in order to make sure the payload is aligned
        // correctly. This will likely result in wasted padding space.
        const pointer_width = @sizeOf(Ref);
        const header_space: usize = @max(pointer_width, descriptor.alignment);

        const object_header_alloc = allocator.create(ObjectHeader) catch {
            return AllocationError.OutOfMemory;
        };
        // If allocating the remaining space fails later, we must
        // free the header memory.
        errdefer allocator.destroy(object_header_alloc);

        object_header_alloc.* = ObjectHeader{
            .descriptor = descriptor,
            .is_marked = false,
        };

        const total_space = try allocationSize(header_space, descriptor.size, 1);

        const allocated_memory = allocator.alloc(u8, total_space) catch {
            return AllocationError.OutOfMemory;
        };

        const allocated_memory_addr = @intFromPtr(allocated_memory.ptr);

        const aligned_addr = std.mem.alignForward(usize, allocated_memory_addr, header_space);
        const payload_start = aligned_addr + header_space;
        const header_start = payload_start - pointer_width;

        const payload_ptr: [*]u8 = @ptrFromInt(payload_start);
        const header_ptr: **ObjectHeader = @ptrFromInt(header_start);
        header_ptr.* = object_header_alloc;

        const start: [*]u8 = @ptrCast(allocated_memory);

        const alignment = std.mem.Alignment.fromByteUnits(header_space);

        return Allocation{
            .start = start,
            .size = total_space,
            .alignment = alignment,
            .header = object_header_alloc,
            .payload = payload_ptr,
            .quantity = 1,
            .kind = .single,
        };
    }

    fn allocate_collection(allocator: std.mem.Allocator, descriptor: *const LayoutDescriptor, quantity: usize) AllocationError!Allocation {
        // Reserve enough space for the header. On 64-bit systems, Ref will be 8 bytes.
        // If the alignment is less than 8 bytes for the descriptor, we still need 8 byte alignment
        // for the header.
        // When the alignment is greater than 8 bytes, we still need to reserve enough space for the
        // header, but we should reserve excess in order to make sure the payload is aligned
        // correctly. This will likely result in wasted padding space.
        const pointer_width = @sizeOf(Ref);
        const header_space: usize = @max(pointer_width, descriptor.alignment);

        const object_header_alloc = allocator.create(ObjectHeader) catch {
            return AllocationError.OutOfMemory;
        };
        // If allocating the remaining space fails later, we must
        // free the header memory.
        errdefer allocator.destroy(object_header_alloc);

        object_header_alloc.* = ObjectHeader{
            .descriptor = descriptor,
            .is_marked = false,
        };

        // Calculate the space required if scalar or Ref type
        const element_size = if (descriptor.element_type == .scalar) descriptor.elementStride() else @sizeOf(Ref);

        const total_space = try allocationSize(header_space, element_size, quantity);

        const allocated_memory = allocator.alloc(u8, total_space) catch {
            return AllocationError.OutOfMemory;
        };

        const allocated_memory_addr = @intFromPtr(allocated_memory.ptr);

        const aligned_addr = std.mem.alignForward(usize, allocated_memory_addr, header_space);
        const payload_start = aligned_addr + header_space;
        const header_start = payload_start - pointer_width;

        const payload_ptr: [*]u8 = @ptrFromInt(payload_start);
        const header_ptr: **ObjectHeader = @ptrFromInt(header_start);
        header_ptr.* = object_header_alloc;

        const start: [*]u8 = @ptrCast(allocated_memory);

        const alignment = std.mem.Alignment.fromByteUnits(header_space);

        return Allocation{
            .start = start,
            .size = total_space,
            .alignment = alignment,
            .header = object_header_alloc,
            .payload = payload_ptr,
            .quantity = quantity,
            .kind = .array,
        };
    }

    /// Deinitialize the allocation. This method does not
    /// deallocate reference objects stored in array-like allocations.
    /// It is assumed that individual objects that are stored in an array
    /// have their own allocation record and will be cleaned up on their own.
    pub fn deinit(self: *Allocation, allocator: std.mem.Allocator) void {
        allocator.destroy(self.header);
        allocator.free(self.start[0..self.size]);
    }
};

fn allocationSize(
    header_space: usize,
    element_size: usize,
    quantity: usize,
) AllocationError!usize {
    const header_size: usize = std.math.mul(usize, header_space, 2) catch {
        return AllocationError.OutOfMemory;
    };

    const payload_size: usize = std.math.mul(usize, element_size, quantity) catch {
        return AllocationError.OutOfMemory;
    };

    return std.math.add(usize, header_size, payload_size) catch {
        return AllocationError.OutOfMemory;
    };
}

test "single allocation has sufficient space and aligned payload" {
    const allocator = std.testing.allocator;

    const descriptor = LayoutDescriptor{
        .size = 13,
        .alignment = 64,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var allocation = try Allocation.init(
        allocator,
        &descriptor,
        1,
        .single,
    );
    defer allocation.deinit(allocator);

    const pointer_width = @sizeOf(Ref);
    const header_space: usize = @max(pointer_width, descriptor.alignment);
    const expected_size = (header_space * 2) + descriptor.size;

    // The allocation reserves enough space.
    try std.testing.expectEqual(expected_size, allocation.size);

    // The payload meets the descriptor's alignment requirement.
    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(allocation.payload) % descriptor.alignment,
    );

    // The payload fits entirely within the allocated block.
    const allocation_start = @intFromPtr(allocation.start);
    const allocation_end = allocation_start + allocation.size;
    const payload_start = @intFromPtr(allocation.payload);
    const payload_end = payload_start + descriptor.size;

    try std.testing.expect(payload_start >= allocation_start);
    try std.testing.expect(payload_end <= allocation_end);

    // The header pointer is stored immediately before the payload.
    const header_slot: **ObjectHeader = @ptrFromInt(
        payload_start - pointer_width,
    );

    try std.testing.expectEqual(allocation.header, header_slot.*);

    // The header describes this object's layout.
    try std.testing.expectEqual(descriptor.size, allocation.header.descriptor.size);
    try std.testing.expectEqual(descriptor.alignment, allocation.header.descriptor.alignment);
    try std.testing.expect(!allocation.header.is_marked);
}

test "single allocation supports alignments smaller than pointer width" {
    const allocator = std.testing.allocator;

    const descriptor = LayoutDescriptor{
        .size = 4,
        .alignment = 1,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var allocation = try Allocation.init(
        allocator,
        &descriptor,
        1,
        .single,
    );
    defer allocation.deinit(allocator);

    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(allocation.payload) % descriptor.alignment,
    );

    const header_slot: **ObjectHeader = @ptrFromInt(
        @intFromPtr(allocation.payload) - @sizeOf(Ref),
    );

    try std.testing.expectEqual(allocation.header, header_slot.*);
}

test "single allocation rejects zero quantity" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    try std.testing.expectError(
        AllocationError.ZeroSizedAllocation,
        Allocation.init(std.testing.allocator, &descriptor, 0, .single),
    );
}

test "single allocation rejects quantity greater than one" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    try std.testing.expectError(
        AllocationError.AllocationKindMismatch,
        Allocation.init(std.testing.allocator, &descriptor, 2, .single),
    );
}

test "single allocation frees header when payload allocation fails" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 1 },
    );

    try std.testing.expectError(
        AllocationError.OutOfMemory,
        Allocation.init(
            failing.allocator(),
            &descriptor,
            1,
            .single,
        ),
    );
}

test "scalar array reserves space for every element and aligns payload" {
    const allocator = std.testing.allocator;

    const descriptor = LayoutDescriptor{
        .size = 13,
        .alignment = 16,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    const quantity: usize = 3;
    const stride = descriptor.elementStride();
    const expected_payload_size = stride * quantity;

    var allocation = try Allocation.init(
        allocator,
        &descriptor,
        quantity,
        .array,
    );
    defer allocation.deinit(allocator);

    try std.testing.expectEqual(quantity, allocation.quantity);
    try std.testing.expectEqual(AllocationKind.array, allocation.kind);
    try std.testing.expectEqual(descriptor.size, allocation.header.descriptor.size);
    try std.testing.expectEqual(descriptor.alignment, allocation.header.descriptor.alignment);

    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(allocation.payload) % descriptor.alignment,
    );

    const allocation_start = @intFromPtr(allocation.start);
    const allocation_end = allocation_start + allocation.size;
    const payload_start = @intFromPtr(allocation.payload);
    const payload_end = payload_start + expected_payload_size;

    try std.testing.expect(payload_start >= allocation_start);
    try std.testing.expect(payload_end <= allocation_end);
}

test "reference array reserves one Ref slot per element" {
    const allocator = std.testing.allocator;

    const descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .reference,
    };

    const quantity: usize = 3;
    const expected_payload_size = quantity * @sizeOf(Ref);

    var allocation = try Allocation.init(
        allocator,
        &descriptor,
        quantity,
        .array,
    );
    defer allocation.deinit(allocator);

    try std.testing.expectEqual(quantity, allocation.quantity);
    try std.testing.expectEqual(AllocationKind.array, allocation.kind);

    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(allocation.payload) % @alignOf(Ref),
    );

    const allocation_start = @intFromPtr(allocation.start);
    const allocation_end = allocation_start + allocation.size;
    const payload_start = @intFromPtr(allocation.payload);
    const payload_end = payload_start + expected_payload_size;

    try std.testing.expect(payload_start >= allocation_start);
    try std.testing.expect(payload_end <= allocation_end);

    const header_slot: **ObjectHeader = @ptrFromInt(
        payload_start - @sizeOf(Ref),
    );
    try std.testing.expectEqual(allocation.header, header_slot.*);
}

test "array of one element remains an array allocation" {
    const allocator = std.testing.allocator;

    const descriptor = LayoutDescriptor{
        .size = 4,
        .alignment = 4,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var allocation = try Allocation.init(
        allocator,
        &descriptor,
        1,
        .array,
    );
    defer allocation.deinit(allocator);

    try std.testing.expectEqual(AllocationKind.array, allocation.kind);
    try std.testing.expectEqual(@as(usize, 1), allocation.quantity);
}

test "array allocation rejects zero quantity" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    try std.testing.expectError(
        AllocationError.ZeroSizedAllocation,
        Allocation.init(
            std.testing.allocator,
            &descriptor,
            0,
            .array,
        ),
    );
}

test "array allocation frees header when payload allocation fails" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 1 },
    );

    try std.testing.expectError(
        AllocationError.OutOfMemory,
        Allocation.init(
            failing.allocator(),
            &descriptor,
            3,
            .array,
        ),
    );
}

test "deinitializing reference array does not free referenced objects" {
    const allocator = std.testing.allocator;

    const object_descriptor = LayoutDescriptor{
        .size = @sizeOf(u64),
        .alignment = @alignOf(u64),
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    const ref_descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .reference,
    };

    // Create the referenced object first.
    var object = try Allocation.init(
        allocator,
        &object_descriptor,
        1,
        .single,
    );
    defer object.deinit(allocator);

    const value: u64 = 42;
    @as(*u64, @ptrCast(@alignCast(object.payload))).* = value;

    // Create an array containing a reference to that object.
    var array = try Allocation.init(
        allocator,
        &ref_descriptor,
        2,
        .array,
    );

    const refs: [*]Ref = @ptrCast(@alignCast(array.payload));
    refs[0] = @ptrCast(object.payload);
    refs[1] = null;

    // Deinitializing the array must not destroy the referenced object.
    array.deinit(allocator);

    // The original object is still valid.
    try std.testing.expectEqual(
        value,
        @as(*u64, @ptrCast(@alignCast(object.payload))).*,
    );
}

test "single allocation returns OutOfMemory when header allocation fails" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );

    try std.testing.expectError(
        AllocationError.OutOfMemory,
        Allocation.init(failing.allocator(), &descriptor, 1, .single),
    );
}

test "array allocation returns OutOfMemory when header allocation fails" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );

    try std.testing.expectError(
        AllocationError.OutOfMemory,
        Allocation.init(failing.allocator(), &descriptor, 3, .array),
    );
}

test "scalar array elements fit at their expected strides" {
    const allocator = std.testing.allocator;

    const descriptor = LayoutDescriptor{
        .size = 13,
        .alignment = 16,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    const quantity: usize = 3;
    const stride = descriptor.elementStride();

    var allocation = try Allocation.init(
        allocator,
        &descriptor,
        quantity,
        .array,
    );
    defer allocation.deinit(allocator);

    const payload_start = @intFromPtr(allocation.payload);
    const allocation_end = @intFromPtr(allocation.start) + allocation.size;

    for (0..quantity) |i| {
        const element_start = payload_start + i * stride;
        const element_end = element_start + descriptor.size;

        try std.testing.expectEqual(
            @as(usize, 0),
            element_start % descriptor.alignment,
        );
        try std.testing.expect(element_end <= allocation_end);
    }
}

test "reference array stores independent references in every slot" {
    const allocator = std.testing.allocator;

    const descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .reference,
    };

    var allocation = try Allocation.init(
        allocator,
        &descriptor,
        3,
        .array,
    );
    defer allocation.deinit(allocator);

    const refs: [*]Ref = @ptrCast(@alignCast(allocation.payload));

    refs[0] = @ptrFromInt(0x1000);
    refs[1] = null;
    refs[2] = @ptrFromInt(0x2000);

    try std.testing.expectEqual(@as(usize, 0x1000), @intFromPtr(refs[0]));
    try std.testing.expectEqual(@as(?*anyopaque, null), refs[1]);
    try std.testing.expectEqual(@as(usize, 0x2000), @intFromPtr(refs[2]));
}

test "array allocation rejects payload size overflow" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    try std.testing.expectError(
        AllocationError.OutOfMemory,
        Allocation.init(
            std.testing.allocator,
            &descriptor,
            std.math.maxInt(usize),
            .array,
        ),
    );
}

test "single allocation rejects total size overflow" {
    const descriptor = LayoutDescriptor{
        .size = std.math.maxInt(usize),
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    try std.testing.expectError(
        AllocationError.OutOfMemory,
        Allocation.init(
            std.testing.allocator,
            &descriptor,
            1,
            .single,
        ),
    );
}

test "array allocation rejects doubled header size overflow" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = @as(usize, 1) << (@bitSizeOf(usize) - 1),
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    try std.testing.expectError(
        AllocationError.OutOfMemory,
        Allocation.init(
            std.testing.allocator,
            &descriptor,
            1,
            .array,
        ),
    );
}
