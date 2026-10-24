const std = @import("std");

pub const region = @import("common/region.zig");

comptime {
    // Ensure that all imported declarations are
    // registered for testing purposes.
    std.testing.refAllDecls(@This());
}
