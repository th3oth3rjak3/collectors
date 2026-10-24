/// Describes the memory layout of a managed object's payload.
/// The compiler emits this descriptor so the collector can
/// identify managed references within the object during tracing.
pub const GcDescriptor = extern struct {
    /// The size of the object payload in bytes.
    payload_size: u64,

    /// The required alignment of the object payload in bytes.
    payload_alignment: u32,

    /// The number of managed-reference fields described by
    /// `reference_offsets`.
    reference_count: u32,

    /// A pointer to an array of byte offsets identifying the
    /// managed-reference fields within the payload. Each offset
    /// is measured from the beginning of the payload.
    reference_offsets: [*]const u32,
};
