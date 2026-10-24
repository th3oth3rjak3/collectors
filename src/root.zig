const std = @import("std");

pub const region = @import("common/region.zig");
pub const descriptor = @import("common/descriptor.zig");
pub const mark_sweep_header = @import("mark_sweep/object_header.zig");
pub const mark_sweep_gc = @import("mark_sweep/collector.zig");

comptime {
    // Ensure that all imported declarations are
    // registered for testing purposes.
    std.testing.refAllDecls(@This());
}
