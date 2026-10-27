const std = @import("std");
const alloc = @import("allocation.zig");
const Allocation = alloc.Allocation;
const AllocationKind = alloc.AllocationKind;
const layout = @import("../common/layout.zig");
const LayoutDescriptor = layout.LayoutDescriptor;
const Ref = layout.Ref;

pub const MarkSweepCollectorError = error{
    InitializationError,
    OutOfMemory,
};

pub const MarkSweepCollector = struct {
    allocator: std.mem.Allocator,
    allocations: std.ArrayList(Allocation),

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

        return allocation.payload;
    }

    pub fn collect(self: *MarkSweepCollector, roots: []const Ref) void {
        _ = self;
        _ = roots;
    }

    pub fn deinit(self: *MarkSweepCollector) void {
        for (self.allocations.items) |*allocation| {
            allocation.deinit(self.allocator);
        }

        self.allocations.deinit(self.allocator);
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
}
