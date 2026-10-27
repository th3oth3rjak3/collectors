const std = @import("std");
const Allocation = @import("allocation.zig").Allocation;

pub const MarkSweepCollectorError = error{
    InitializationError,
};

pub const MarkSweepCollector = struct {
    allocator: std.mem.Allocator,
    allocations: std.ArrayList(Allocation),

    pub fn init(allocator: std.mem.Allocator, initial_capacity: usize) MarkSweepCollectorError!MarkSweepCollector {
        const allocations: std.ArrayList(Allocation) = .initCapacity(allocator, initial_capacity) catch {
            return MarkSweepCollectorError.InitializationError;
        };

        return MarkSweepCollector{
            .allocator = allocator,
            .allocations = allocations,
        };
    }

    pub fn deinit(self: *MarkSweepCollector) void {
        for (self.allocations) |allocation| {
            _ = allocation; // deinit allocation
        }

        self.allocations.deinit(self.allocator);
    }
};
