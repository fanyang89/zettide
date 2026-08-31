const std = @import("std");
const model = @import("model.zig");
const primary_lease = @import("primary_lease.zig");

/// Computes the canonical v1 authority transcript digest. The digest field in
/// `binding` is deliberately excluded, preserving the deployed transcript.
pub fn digest(binding: model.AuthorityBinding) model.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "zettide.primary-authority.v1");
    hashField(&hasher, &binding.volume_id);
    hashField(&hasher, &binding.primary_placement_id);
    hashField(&hasher, &binding.primary_node_id);
    hashField(&hasher, &binding.lease_id);
    hashField(&hasher, &binding.holder_boot_id);
    hashU64(&hasher, binding.authority_generation);
    hashU64(&hasher, binding.write_epoch);
    hashU64(&hasher, binding.placement_revision);
    hashField(&hasher, &binding.activation_nonce);
    hashU64(&hasher, primary_lease.duration_ms);
    var result: model.Digest = undefined;
    hasher.final(&result);
    return result;
}

pub fn validate(binding: model.AuthorityBinding) !void {
    if (!std.mem.eql(u8, &binding.authority_digest, &digest(binding)))
        return error.InvalidAuthorityDigest;
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .big);
    hasher.update(&length);
    hasher.update(value);
}

fn hashU64(hasher: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    hashField(hasher, &bytes);
}

fn testId(byte: u8) model.Id {
    var value: model.Id = @splat(byte);
    value[6] = 0x70 | (byte & 0x0f);
    value[8] = 0x80 | (byte & 0x3f);
    return value;
}

test "authority digest is canonical and validates exact transcript" {
    var binding: model.AuthorityBinding = .{
        .volume_id = testId(1),
        .primary_placement_id = testId(2),
        .primary_node_id = testId(3),
        .lease_id = testId(4),
        .holder_boot_id = testId(5),
        .authority_generation = 6,
        .write_epoch = 7,
        .placement_revision = 8,
        .activation_nonce = testId(9),
        .authority_digest = undefined,
    };
    binding.authority_digest = digest(binding);
    try std.testing.expectEqual(
        @as(model.Digest, .{
            0x89, 0x7a, 0xbf, 0xb6, 0x9b, 0xff, 0xbe, 0x81,
            0x03, 0xe3, 0x4a, 0xf1, 0xdd, 0x2e, 0xf7, 0x93,
            0x00, 0xa9, 0x9a, 0xb6, 0x98, 0xab, 0xf5, 0x63,
            0xea, 0xb3, 0x6b, 0x58, 0xa5, 0xb1, 0x83, 0x19,
        }),
        binding.authority_digest,
    );
    try validate(binding);

    binding.lease_id[15] ^= 1;
    try std.testing.expectError(error.InvalidAuthorityDigest, validate(binding));
}
