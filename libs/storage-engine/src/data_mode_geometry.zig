const std = @import("std");

/// Geometry contract shared by Pool provisioning and the Blob format adapter.
///
/// These values are part of the existing on-disk compatibility contract. The
/// Pool layer uses them to validate `.blob` data members without importing or
/// interpreting the Blob format implementation.
pub const blob = struct {
    pub const chunk_size: u32 = 1024 * 1024;
    pub const minimum_device_size: u64 = 2 * 1024 * 1024;
};

test "blob data-mode geometry remains format compatible" {
    try std.testing.expectEqual(@as(u32, 1024 * 1024), blob.chunk_size);
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), blob.minimum_device_size);
}
