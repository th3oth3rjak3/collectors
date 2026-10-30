const std = @import("std");
const alloc = @import("allocation.zig");
const Allocation = alloc.Allocation;
const AllocationKind = alloc.AllocationKind;
const layout = @import("../common/layout.zig");
const LayoutDescriptor = layout.LayoutDescriptor;
const Ref = layout.Ref;
const ObjectHeader = @import("object_header.zig").ObjectHeader;

pub const MarkSweepCollectorError = error{
    InitializationError,
    OutOfMemory,
};

pub const MarkSweepCollector = struct {
    allocator: std.mem.Allocator,
    allocations: std.ArrayList(Allocation),
    allocated_bytes: usize,
    peak_allocated_bytes: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        initial_capacity: usize,
    ) MarkSweepCollectorError!MarkSweepCollector {
        const allocations = std.ArrayList(Allocation)
            .initCapacity(allocator, initial_capacity) catch {
            return MarkSweepCollectorError.InitializationError;
        };

        return MarkSweepCollector{
            .allocator = allocator,
            .allocations = allocations,
            .allocated_bytes = 0,
            .peak_allocated_bytes = 0,
        };
    }

    pub fn alloc(
        self: *MarkSweepCollector,
        descriptor: *const LayoutDescriptor,
    ) MarkSweepCollectorError![*]u8 {
        var allocation = Allocation.init(
            self.allocator,
            descriptor,
            1,
            .single,
        ) catch {
            return MarkSweepCollectorError.OutOfMemory;
        };
        errdefer allocation.deinit(self.allocator);

        self.allocations.append(self.allocator, allocation) catch {
            return MarkSweepCollectorError.OutOfMemory;
        };

        self.allocated_bytes += allocation.size;
        self.peak_allocated_bytes = @max(self.allocated_bytes, self.peak_allocated_bytes);

        return allocation.payload;
    }

    pub fn allocArray(
        self: *MarkSweepCollector,
        descriptor: *const LayoutDescriptor,
        quantity: usize,
    ) MarkSweepCollectorError![*]u8 {
        var allocation = Allocation.init(
            self.allocator,
            descriptor,
            quantity,
            .array,
        ) catch {
            return MarkSweepCollectorError.OutOfMemory;
        };

        errdefer allocation.deinit(self.allocator);

        self.allocations.append(self.allocator, allocation) catch {
            return MarkSweepCollectorError.OutOfMemory;
        };

        self.allocated_bytes += allocation.size;
        self.peak_allocated_bytes = @max(self.allocated_bytes, self.peak_allocated_bytes);

        return allocation.payload;
    }

    pub fn collect(self: *MarkSweepCollector, roots: []const Ref) void {
        self.traceRoots(roots);
        self.sweep();
    }

    pub fn allocatedBytes(self: *const MarkSweepCollector) usize {
        return self.allocated_bytes;
    }

    pub fn peakAllocatedBytes(self: *const MarkSweepCollector) usize {
        return self.peak_allocated_bytes;
    }

    pub fn deinit(self: *MarkSweepCollector) void {
        for (self.allocations.items) |*allocation| {
            allocation.deinit(self.allocator);
        }

        self.allocations.deinit(self.allocator);
    }

    fn traceRoots(self: *MarkSweepCollector, roots: []const Ref) void {
        for (roots) |root| {
            self.traceObject(root);
        }
    }

    fn traceObject(self: *MarkSweepCollector, reference: Ref) void {
        const payload = reference orelse return;

        const header_slot: **ObjectHeader = @ptrFromInt(
            @intFromPtr(payload) - @sizeOf(Ref),
        );
        const header = header_slot.*;

        if (header.is_marked) return;
        header.is_marked = true;

        if (header.descriptor.ptr_bytes == 0 or header.quantity == 0) return;

        const stride = header.descriptor.elementStride();
        const allocation_size = if (header.quantity == 1)
            header.descriptor.size
        else
            stride * header.quantity;

        header.descriptor.scanReferences(
            @ptrCast(payload),
            allocation_size,
            self,
            visitReference,
        ) catch unreachable;
    }

    fn visitReference(context: *anyopaque, candidate: *anyopaque) void {
        const self: *MarkSweepCollector = @ptrCast(@alignCast(context));
        self.traceObject(candidate);
    }

    fn sweep(self: *MarkSweepCollector) void {
        var i: usize = 0;

        while (i < self.allocations.items.len) {
            const allocation = &self.allocations.items[i];

            if (!allocation.header.is_marked) {
                const size_removed = allocation.size;
                allocation.deinit(self.allocator);
                self.allocated_bytes -= size_removed;
                _ = self.allocations.swapRemove(i);
            } else {
                allocation.header.is_marked = false;
                i += 1;
            }
        }

        self.allocations.shrinkAndFree(self.allocator, self.allocations.items.len);
    }
};

test "alloc registers a single allocation and returns its payload" {
    const allocator = std.testing.allocator;

    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(allocator, 0);
    defer gc.deinit();

    const payload = try gc.alloc(&descriptor);

    try std.testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
    try std.testing.expectEqual(
        @intFromPtr(gc.allocations.items[0].payload),
        @intFromPtr(payload),
    );
    try std.testing.expectEqual(@as(usize, 1), gc.allocations.items[0].quantity);
    try std.testing.expectEqual(AllocationKind.single, gc.allocations.items[0].kind);
}

test "allocArray registers an array allocation" {
    const allocator = std.testing.allocator;

    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(allocator, 0);
    defer gc.deinit();

    const quantity: usize = 3;
    const payload = try gc.allocArray(&descriptor, quantity);

    try std.testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
    try std.testing.expectEqual(
        @intFromPtr(gc.allocations.items[0].payload),
        @intFromPtr(payload),
    );
    try std.testing.expectEqual(quantity, gc.allocations.items[0].quantity);
    try std.testing.expectEqual(AllocationKind.array, gc.allocations.items[0].kind);
}

test "allocArray accepts zero quantity" {
    const allocator = std.testing.allocator;

    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(allocator, 0);
    defer gc.deinit();

    _ = try gc.allocArray(&descriptor, 0);

    try std.testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
    try std.testing.expectEqual(@as(usize, 0), gc.allocations.items[0].quantity);
    try std.testing.expectEqual(AllocationKind.array, gc.allocations.items[0].kind);
}

test "deinit releases registered allocations" {
    const allocator = std.testing.allocator;

    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(allocator, 0);

    _ = try gc.alloc(&descriptor);
    _ = try gc.allocArray(&descriptor, 3);

    try std.testing.expectEqual(@as(usize, 2), gc.allocations.items.len);

    gc.deinit();
}

test "alloc cleans up allocation when registration fails" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 2 },
    );

    var gc = try MarkSweepCollector.init(failing.allocator(), 0);
    defer gc.deinit();

    try std.testing.expectError(
        MarkSweepCollectorError.OutOfMemory,
        gc.alloc(&descriptor),
    );

    try std.testing.expectEqual(@as(usize, 0), gc.allocations.items.len);
    try std.testing.expectEqual(@as(usize, 0), gc.allocatedBytes());
}

fn storeRef(payload: [*]u8, reference: Ref) void {
    const slot: *Ref = @ptrCast(@alignCast(payload));
    slot.* = reference;
}

fn storeTwoRefs(payload: [*]u8, first: Ref, second: Ref) void {
    const slots: [*]Ref = @ptrCast(@alignCast(payload));
    slots[0] = first;
    slots[1] = second;
}

fn expectMarked(gc: *MarkSweepCollector, payload: [*]u8) !void {
    for (gc.allocations.items) |allocation| {
        if (@intFromPtr(allocation.payload) == @intFromPtr(payload)) {
            try std.testing.expect(allocation.header.is_marked);
            return;
        }
    }

    return error.AllocationNotFound;
}

fn expectUnmarked(gc: *MarkSweepCollector, payload: [*]u8) !void {
    for (gc.allocations.items) |allocation| {
        if (@intFromPtr(allocation.payload) == @intFromPtr(payload)) {
            try std.testing.expect(!allocation.header.is_marked);
            return;
        }
    }

    return error.AllocationNotFound;
}

test "traceRoots with no roots leaves all objects unmarked" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const first = try gc.alloc(&descriptor);
    const second = try gc.alloc(&descriptor);

    gc.traceRoots(&.{});

    try expectUnmarked(&gc, first);
    try expectUnmarked(&gc, second);
}

test "traceRoots ignores null roots" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const payload = try gc.alloc(&descriptor);

    gc.traceRoots(&.{null});

    try expectUnmarked(&gc, payload);
}

test "traceRoots marks a single root" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const payload = try gc.alloc(&descriptor);

    gc.traceRoots(&.{@ptrCast(payload)});

    try expectMarked(&gc, payload);
}

test "traceRoots marks multiple roots" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const first = try gc.alloc(&descriptor);
    const second = try gc.alloc(&descriptor);
    const third = try gc.alloc(&descriptor);

    gc.traceRoots(&.{ @ptrCast(first), @ptrCast(second) });

    try expectMarked(&gc, first);
    try expectMarked(&gc, second);
    try expectUnmarked(&gc, third);
}

test "traceRoots handles duplicate roots" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const payload = try gc.alloc(&descriptor);
    const reference: Ref = @ptrCast(payload);

    gc.traceRoots(&.{ reference, reference, reference });

    try expectMarked(&gc, payload);
}

test "traceRoots traces one referenced object" {
    const bitmap = [_]u8{0b00000001};

    const object_descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .scalar,
    };

    const leaf_descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const parent = try gc.alloc(&object_descriptor);
    const child = try gc.alloc(&leaf_descriptor);

    storeRef(parent, @ptrCast(child));

    gc.traceRoots(&.{@ptrCast(parent)});

    try expectMarked(&gc, parent);
    try expectMarked(&gc, child);
}

test "traceRoots traces a chain of references" {
    const bitmap = [_]u8{0b00000001};

    const node_descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const first = try gc.alloc(&node_descriptor);
    const second = try gc.alloc(&node_descriptor);
    const third = try gc.alloc(&node_descriptor);

    storeRef(first, @ptrCast(second));
    storeRef(second, @ptrCast(third));
    storeRef(third, null);

    gc.traceRoots(&.{@ptrCast(first)});

    try expectMarked(&gc, first);
    try expectMarked(&gc, second);
    try expectMarked(&gc, third);
}

test "traceRoots traces multiple references from one object" {
    const bitmap = [_]u8{0b00000011};

    const parent_descriptor = LayoutDescriptor{
        .size = 2 * @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = 2 * @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .scalar,
    };

    const leaf_descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const parent = try gc.alloc(&parent_descriptor);
    const first = try gc.alloc(&leaf_descriptor);
    const second = try gc.alloc(&leaf_descriptor);

    storeTwoRefs(parent, @ptrCast(first), @ptrCast(second));

    gc.traceRoots(&.{@ptrCast(parent)});

    try expectMarked(&gc, parent);
    try expectMarked(&gc, first);
    try expectMarked(&gc, second);
}

test "traceRoots handles null references inside an object" {
    const bitmap = [_]u8{0b00000001};

    const descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const payload = try gc.alloc(&descriptor);
    storeRef(payload, null);

    gc.traceRoots(&.{@ptrCast(payload)});

    try expectMarked(&gc, payload);
}

test "traceRoots handles two objects referencing the same object" {
    const bitmap = [_]u8{0b00000001};

    const node_descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .scalar,
    };

    const leaf_descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const first = try gc.alloc(&node_descriptor);
    const second = try gc.alloc(&node_descriptor);
    const shared = try gc.alloc(&leaf_descriptor);

    storeRef(first, @ptrCast(shared));
    storeRef(second, @ptrCast(shared));

    gc.traceRoots(&.{ @ptrCast(first), @ptrCast(second) });

    try expectMarked(&gc, first);
    try expectMarked(&gc, second);
    try expectMarked(&gc, shared);
}

test "traceRoots handles a self reference" {
    const bitmap = [_]u8{0b00000001};

    const descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const payload = try gc.alloc(&descriptor);
    storeRef(payload, @ptrCast(payload));

    gc.traceRoots(&.{@ptrCast(payload)});

    try expectMarked(&gc, payload);
}

test "traceRoots handles a cycle between two objects" {
    const bitmap = [_]u8{0b00000001};

    const descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const first = try gc.alloc(&descriptor);
    const second = try gc.alloc(&descriptor);

    storeRef(first, @ptrCast(second));
    storeRef(second, @ptrCast(first));

    gc.traceRoots(&.{@ptrCast(first)});

    try expectMarked(&gc, first);
    try expectMarked(&gc, second);
}

test "traceRoots does not trace words excluded by the bitmap" {
    const bitmap = [_]u8{0b00000001};

    const descriptor = LayoutDescriptor{
        .size = 2 * @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .scalar,
    };

    const leaf_descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const parent = try gc.alloc(&descriptor);
    const child = try gc.alloc(&leaf_descriptor);

    const slots: [*]Ref = @ptrCast(@alignCast(parent));
    slots[0] = null;
    slots[1] = @ptrCast(child);

    gc.traceRoots(&.{@ptrCast(parent)});

    try expectMarked(&gc, parent);
    try expectUnmarked(&gc, child);
}

test "traceRoots does not scan pointer-free objects" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const payload = try gc.alloc(&descriptor);

    gc.traceRoots(&.{@ptrCast(payload)});

    try expectMarked(&gc, payload);
}

test "traceRoots traces every reference in a reference array" {
    const bitmap = [_]u8{0b00000001};

    const reference_descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .reference,
    };

    const leaf_descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const references = try gc.allocArray(&reference_descriptor, 3);
    const first = try gc.alloc(&leaf_descriptor);
    const second = try gc.alloc(&leaf_descriptor);
    const third = try gc.alloc(&leaf_descriptor);

    const slots: [*]Ref = @ptrCast(@alignCast(references));
    slots[0] = @ptrCast(first);
    slots[1] = @ptrCast(second);
    slots[2] = @ptrCast(third);

    gc.traceRoots(&.{@ptrCast(references)});

    try expectMarked(&gc, references);
    try expectMarked(&gc, first);
    try expectMarked(&gc, second);
    try expectMarked(&gc, third);
}

test "traceRoots handles an array containing null references" {
    const bitmap = [_]u8{0b00000001};

    const reference_descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .reference,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 3);
    defer gc.deinit();

    const references = try gc.allocArray(&reference_descriptor, 3);

    const slots: [*]Ref = @ptrCast(@alignCast(references));
    slots[0] = null;
    slots[1] = null;
    slots[2] = null;

    gc.traceRoots(&.{@ptrCast(references)});

    try expectMarked(&gc, references);
}

test "collect reclaims unreachable allocations" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    _ = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);

    gc.collect(&.{});

    try std.testing.expectEqual(@as(usize, 0), gc.allocations.items.len);
}

test "collect preserves roots and reclaims unreachable allocations" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const root = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);

    gc.collect(&.{@ptrCast(root)});

    try std.testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
    try expectUnmarked(&gc, root);
}

test "collect reclaims allocations when roots are null" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    _ = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);

    gc.collect(&.{ null, null });

    try std.testing.expectEqual(@as(usize, 0), gc.allocations.items.len);
}

test "collect preserves reachable children" {
    const bitmap = [_]u8{0b00000001};

    const node_descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .scalar,
    };

    const leaf_descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const parent = try gc.alloc(&node_descriptor);
    const child = try gc.alloc(&leaf_descriptor);
    _ = try gc.alloc(&leaf_descriptor);

    storeRef(parent, @ptrCast(child));

    gc.collect(&.{@ptrCast(parent)});

    try std.testing.expectEqual(@as(usize, 2), gc.allocations.items.len);
    try expectUnmarked(&gc, parent);
    try expectUnmarked(&gc, child);
}

test "collect preserves multiple roots" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const first = try gc.alloc(&descriptor);
    const second = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);

    gc.collect(&.{ @ptrCast(first), @ptrCast(second) });

    try std.testing.expectEqual(@as(usize, 2), gc.allocations.items.len);
    try expectUnmarked(&gc, first);
    try expectUnmarked(&gc, second);
}

test "collect preserves objects referenced by a root array" {
    const bitmap = [_]u8{0b00000001};

    const reference_descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .reference,
    };

    const leaf_descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const references = try gc.allocArray(&reference_descriptor, 3);
    const first = try gc.alloc(&leaf_descriptor);
    const second = try gc.alloc(&leaf_descriptor);
    const third = try gc.alloc(&leaf_descriptor);
    _ = try gc.alloc(&leaf_descriptor);

    const slots: [*]Ref = @ptrCast(@alignCast(references));
    slots[0] = @ptrCast(first);
    slots[1] = @ptrCast(second);
    slots[2] = @ptrCast(third);

    gc.collect(&.{@ptrCast(references)});

    try std.testing.expectEqual(@as(usize, 4), gc.allocations.items.len);
    try expectUnmarked(&gc, references);
    try expectUnmarked(&gc, first);
    try expectUnmarked(&gc, second);
    try expectUnmarked(&gc, third);
}

test "collect reclaims an unreachable array and its children" {
    const bitmap = [_]u8{0b00000001};

    const reference_descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .reference,
    };

    const leaf_descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const references = try gc.allocArray(&reference_descriptor, 1);
    const child = try gc.alloc(&leaf_descriptor);

    storeRef(references, @ptrCast(child));

    gc.collect(&.{});

    try std.testing.expectEqual(@as(usize, 0), gc.allocations.items.len);
}

test "collect preserves a child shared by multiple objects" {
    const bitmap = [_]u8{0b00000001};

    const node_descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .scalar,
    };

    const leaf_descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const first = try gc.alloc(&node_descriptor);
    const second = try gc.alloc(&node_descriptor);
    const shared = try gc.alloc(&leaf_descriptor);

    storeRef(first, @ptrCast(shared));
    storeRef(second, @ptrCast(shared));

    gc.collect(&.{ @ptrCast(first), @ptrCast(second) });

    try std.testing.expectEqual(@as(usize, 3), gc.allocations.items.len);
    try expectUnmarked(&gc, first);
    try expectUnmarked(&gc, second);
    try expectUnmarked(&gc, shared);
}

test "collect preserves reachable cycles and reclaims unreachable cycles" {
    const bitmap = [_]u8{0b00000001};

    const descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const first = try gc.alloc(&descriptor);
    const second = try gc.alloc(&descriptor);

    const unreachable_first = try gc.alloc(&descriptor);
    const unreachable_second = try gc.alloc(&descriptor);

    storeRef(first, @ptrCast(second));
    storeRef(second, @ptrCast(first));

    storeRef(unreachable_first, @ptrCast(unreachable_second));
    storeRef(unreachable_second, @ptrCast(unreachable_first));

    gc.collect(&.{@ptrCast(first)});

    try std.testing.expectEqual(@as(usize, 2), gc.allocations.items.len);
    try expectUnmarked(&gc, first);
    try expectUnmarked(&gc, second);
}

test "collect preserves a self-referencing root" {
    const bitmap = [_]u8{0b00000001};

    const descriptor = LayoutDescriptor{
        .size = @sizeOf(Ref),
        .alignment = @alignOf(Ref),
        .ptr_bytes = @sizeOf(Ref),
        .gc_data = bitmap[0..].ptr,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const payload = try gc.alloc(&descriptor);
    storeRef(payload, @ptrCast(payload));

    gc.collect(&.{@ptrCast(payload)});

    try std.testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
    try expectUnmarked(&gc, payload);
}

test "collect reclaims objects after their roots are removed" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const payload = try gc.alloc(&descriptor);

    gc.collect(&.{@ptrCast(payload)});

    try std.testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
    try expectUnmarked(&gc, payload);

    gc.collect(&.{});

    try std.testing.expectEqual(@as(usize, 0), gc.allocations.items.len);
}

test "collect handles an empty allocation list" {
    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    gc.collect(&.{});

    try std.testing.expectEqual(@as(usize, 0), gc.allocations.items.len);
}

test "collect shrinks empty allocation registry" {
    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    try gc.allocations.ensureTotalCapacityPrecise(gc.allocator, 32);

    const capacity_before = gc.allocations.capacity;
    try std.testing.expectEqual(@as(usize, 32), capacity_before);

    gc.collect(&.{});

    try std.testing.expectEqual(@as(usize, 0), gc.allocations.items.len);
    try std.testing.expectEqual(@as(usize, 0), gc.allocations.capacity);
    try std.testing.expect(gc.allocations.capacity < capacity_before);
}

test "collect shrinks allocation registry while preserving live allocations" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    try gc.allocations.ensureTotalCapacityPrecise(gc.allocator, 32);

    const live = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);

    const capacity_before = gc.allocations.capacity;

    gc.collect(&.{live});

    try std.testing.expectEqual(@as(usize, 1), gc.allocations.items.len);
    try std.testing.expectEqual(@as(usize, 1), gc.allocations.capacity);
    try std.testing.expect(gc.allocations.capacity < capacity_before);

    // The surviving allocation remains registered.
    try expectUnmarked(&gc, live);
}

test "allocatedBytes tracks single allocations" {
    const descriptor = LayoutDescriptor{
        .size = 16,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    try std.testing.expectEqual(@as(usize, 0), gc.allocatedBytes());

    _ = try gc.alloc(&descriptor);

    try std.testing.expectEqual(
        gc.allocations.items[0].size,
        gc.allocatedBytes(),
    );
}

test "allocatedBytes tracks array allocations" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    _ = try gc.allocArray(&descriptor, 4);

    try std.testing.expectEqual(
        gc.allocations.items[0].size,
        gc.allocatedBytes(),
    );
}

test "allocatedBytes decreases after collection" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const live = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);

    const live_size = gc.allocations.items[0].size;

    gc.collect(&.{live});

    try std.testing.expectEqual(live_size, gc.allocatedBytes());
}

test "allocatedBytes becomes zero after reclaiming all allocations" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    _ = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);

    gc.collect(&.{});

    try std.testing.expectEqual(@as(usize, 0), gc.allocatedBytes());
}

test "allocatedBytes accumulates multiple allocations" {
    const descriptor = LayoutDescriptor{
        .size = 16,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    _ = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);

    const expected =
        gc.allocations.items[0].size +
        gc.allocations.items[1].size +
        gc.allocations.items[2].size;

    try std.testing.expectEqual(expected, gc.allocatedBytes());
}

test "allocatedBytes tracks mixed allocations" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    _ = try gc.alloc(&descriptor);
    _ = try gc.allocArray(&descriptor, 4);
    _ = try gc.alloc(&descriptor);

    var expected: usize = 0;
    for (gc.allocations.items) |allocation| {
        expected += allocation.size;
    }

    try std.testing.expectEqual(expected, gc.allocatedBytes());
}

test "allocatedBytes tracks zero quantity array allocation" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    _ = try gc.allocArray(&descriptor, 0);

    try std.testing.expectEqual(
        gc.allocations.items[0].size,
        gc.allocatedBytes(),
    );
}

test "allocatedBytes tracks repeated collections" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const first = try gc.alloc(&descriptor);
    const second = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);

    gc.collect(&.{ first, second });

    const expected =
        gc.allocations.items[0].size +
        gc.allocations.items[1].size;

    try std.testing.expectEqual(expected, gc.allocatedBytes());

    gc.collect(&.{first});

    try std.testing.expectEqual(
        gc.allocations.items[0].size,
        gc.allocatedBytes(),
    );

    gc.collect(&.{});

    try std.testing.expectEqual(@as(usize, 0), gc.allocatedBytes());
}

test "peakAllocatedBytes tracks increasing allocations" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    try std.testing.expectEqual(@as(usize, 0), gc.peakAllocatedBytes());

    _ = try gc.alloc(&descriptor);
    const first_peak = gc.allocatedBytes();

    try std.testing.expectEqual(first_peak, gc.peakAllocatedBytes());

    _ = try gc.alloc(&descriptor);

    try std.testing.expectEqual(
        gc.allocatedBytes(),
        gc.peakAllocatedBytes(),
    );
    try std.testing.expect(gc.peakAllocatedBytes() > first_peak);
}

test "peakAllocatedBytes remains unchanged after collection" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    const live = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);

    const peak_before = gc.peakAllocatedBytes();

    gc.collect(&.{live});

    try std.testing.expect(gc.allocatedBytes() < peak_before);
    try std.testing.expectEqual(peak_before, gc.peakAllocatedBytes());
}

test "peakAllocatedBytes updates when usage exceeds previous peak" {
    const descriptor = LayoutDescriptor{
        .size = 8,
        .alignment = 8,
        .ptr_bytes = 0,
        .gc_data = null,
        .element_type = .scalar,
    };

    var gc = try MarkSweepCollector.init(std.testing.allocator, 0);
    defer gc.deinit();

    _ = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);

    const first_peak = gc.peakAllocatedBytes();

    gc.collect(&.{});

    try std.testing.expectEqual(@as(usize, 0), gc.allocatedBytes());
    try std.testing.expectEqual(first_peak, gc.peakAllocatedBytes());

    _ = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);
    _ = try gc.alloc(&descriptor);

    try std.testing.expect(gc.peakAllocatedBytes() > first_peak);
    try std.testing.expectEqual(
        gc.allocatedBytes(),
        gc.peakAllocatedBytes(),
    );
}
