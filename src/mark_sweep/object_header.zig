const LayoutDescriptor = @import("../common/layout.zig").LayoutDescriptor;

/// An `ObjectHeader` contains the information
/// about an allocated payload object that is
/// managed by the garbage collector. A pointer to
/// this header will always be exactly `@sizeOf(usize)` bytes
/// before the payload header. On a 64-bit system, that means
/// a simple subtraction of 8 bytes from the payload address
/// will be a pointer to this object header.
pub const ObjectHeader = struct {
    /// The layout details for the payload object.
    descriptor: *const LayoutDescriptor,
    /// A mark bit to be used by the collector during
    /// root scanning to verify liveness.
    is_marked: bool = false,
};
