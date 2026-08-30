const std = @import("std");

const protocol = @import("zettide_data_service_contracts");

pub const Id = protocol.Id;
pub const Key = [32]u8;
pub const Tag = [32]u8;
pub const Challenge = [32]u8;

pub const source_node_metadata = "x-zettide-source-node-bin";
pub const challenge_metadata = "x-zettide-challenge-bin";
pub const authentication_metadata = "x-zettide-authentication-bin";
pub const response_authentication_metadata = "x-zettide-response-authentication-bin";

const domain = "zettide.replica-rpc-auth.v1\x00";
const response_domain = "zettide.replica-rpc-response-auth.v1\x00";
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const PeerKey = struct {
    node_id: Id,
    key: Key,
};

pub const Metadata = struct {
    key: []const u8,
    value: []const u8,
};

pub const SignedMetadata = struct {
    source_node_id: Id,
    challenge: Challenge,
    tag: Tag,

    pub fn entries(self: *const SignedMetadata) [3]Metadata {
        return .{
            .{ .key = source_node_metadata, .value = &self.source_node_id },
            .{ .key = challenge_metadata, .value = &self.challenge },
            .{ .key = authentication_metadata, .value = &self.tag },
        };
    }
};

pub const VerifiedRequest = struct {
    source_node_id: Id,
    challenge: Challenge,
};

pub const Authenticator = struct {
    allocator: std.mem.Allocator,
    local_node_id: Id,
    peers: []PeerKey,

    pub fn init(
        allocator: std.mem.Allocator,
        local_node_id: Id,
        peers: []const PeerKey,
    ) !Authenticator {
        if (isZero(&local_node_id)) return error.InvalidLocalNodeId;
        if (peers.len == 0) return error.EmptyPeerKeySet;
        const owned = try allocator.dupe(PeerKey, peers);
        errdefer {
            for (owned) |*peer| std.crypto.secureZero(u8, &peer.key);
            allocator.free(owned);
        }
        for (owned, 0..) |peer, index| {
            if (isZero(&peer.node_id) or std.mem.eql(u8, &peer.node_id, &local_node_id))
                return error.InvalidPeerNodeId;
            if (isZero(&peer.key)) return error.InvalidPeerKey;
            for (owned[0..index]) |previous| {
                if (std.mem.eql(u8, &previous.node_id, &peer.node_id))
                    return error.DuplicatePeerNodeId;
                if (std.mem.eql(u8, &previous.key, &peer.key))
                    return error.DuplicatePeerKey;
            }
        }
        return .{
            .allocator = allocator,
            .local_node_id = local_node_id,
            .peers = owned,
        };
    }

    pub fn deinit(self: *Authenticator) void {
        for (self.peers) |*peer| std.crypto.secureZero(u8, &peer.key);
        self.allocator.free(self.peers);
        self.* = undefined;
    }

    pub fn verify(
        self: *const Authenticator,
        metadata: anytype,
        method_path: []const u8,
        request_bytes: []const u8,
    ) !VerifiedRequest {
        const source_bytes = try exactlyOne(metadata, source_node_metadata);
        const challenge_bytes = try exactlyOne(metadata, challenge_metadata);
        const supplied_tag_bytes = try exactlyOne(metadata, authentication_metadata);
        if (source_bytes.len != @sizeOf(Id) or challenge_bytes.len != @sizeOf(Challenge) or
            supplied_tag_bytes.len != @sizeOf(Tag))
            return error.InvalidAuthenticationMetadata;

        var source_node_id: Id = undefined;
        @memcpy(&source_node_id, source_bytes);
        const peer = self.findPeer(source_node_id) orelse return error.UnknownPeer;
        const expected = sign(
            peer.key,
            source_node_id,
            self.local_node_id,
            challenge_bytes[0..@sizeOf(Challenge)].*,
            method_path,
            request_bytes,
        );
        var supplied: Tag = undefined;
        @memcpy(&supplied, supplied_tag_bytes);
        if (!std.crypto.timing_safe.eql(Tag, expected, supplied))
            return error.AuthenticationFailed;
        return .{
            .source_node_id = source_node_id,
            .challenge = challenge_bytes[0..@sizeOf(Challenge)].*,
        };
    }

    pub fn responseTag(
        self: *const Authenticator,
        source_node_id: Id,
        challenge: Challenge,
        method_path: []const u8,
        request_bytes: []const u8,
        status_code: u8,
        status_message: []const u8,
        response_bytes: []const u8,
    ) !Tag {
        const peer = self.findPeer(source_node_id) orelse return error.UnknownPeer;
        return signResponse(
            peer.key,
            source_node_id,
            self.local_node_id,
            challenge,
            method_path,
            request_bytes,
            status_code,
            status_message,
            response_bytes,
        );
    }

    fn findPeer(self: *const Authenticator, node_id: Id) ?PeerKey {
        for (self.peers) |peer| {
            if (std.mem.eql(u8, &peer.node_id, &node_id)) return peer;
        }
        return null;
    }
};

pub fn signedMetadata(
    source_node_id: Id,
    target_node_id: Id,
    challenge: Challenge,
    key: Key,
    method_path: []const u8,
    request_bytes: []const u8,
) SignedMetadata {
    return .{
        .source_node_id = source_node_id,
        .challenge = challenge,
        .tag = sign(key, source_node_id, target_node_id, challenge, method_path, request_bytes),
    };
}

fn sign(
    key: Key,
    source_node_id: Id,
    target_node_id: Id,
    challenge: Challenge,
    method_path: []const u8,
    request_bytes: []const u8,
) Tag {
    var method_length: [4]u8 = undefined;
    std.mem.writeInt(u32, &method_length, @intCast(method_path.len), .big);
    var request_length: [8]u8 = undefined;
    std.mem.writeInt(u64, &request_length, @intCast(request_bytes.len), .big);

    var mac = HmacSha256.init(&key);
    mac.update(domain);
    mac.update(&method_length);
    mac.update(method_path);
    mac.update(&source_node_id);
    mac.update(&target_node_id);
    mac.update(&challenge);
    mac.update(&request_length);
    mac.update(request_bytes);
    var tag: Tag = undefined;
    mac.final(&tag);
    return tag;
}

pub fn verifyResponse(
    source_node_id: Id,
    target_node_id: Id,
    challenge: Challenge,
    key: Key,
    metadata: anytype,
    method_path: []const u8,
    request_bytes: []const u8,
    status_code: u8,
    status_message: []const u8,
    response_bytes: []const u8,
) !void {
    const supplied_bytes = try exactlyOne(metadata, response_authentication_metadata);
    if (supplied_bytes.len != @sizeOf(Tag)) return error.InvalidAuthenticationMetadata;
    var supplied: Tag = undefined;
    @memcpy(&supplied, supplied_bytes);
    const expected = signResponse(
        key,
        source_node_id,
        target_node_id,
        challenge,
        method_path,
        request_bytes,
        status_code,
        status_message,
        response_bytes,
    );
    if (!std.crypto.timing_safe.eql(Tag, expected, supplied))
        return error.AuthenticationFailed;
}

fn signResponse(
    key: Key,
    source_node_id: Id,
    target_node_id: Id,
    challenge: Challenge,
    method_path: []const u8,
    request_bytes: []const u8,
    status_code: u8,
    status_message: []const u8,
    response_bytes: []const u8,
) Tag {
    var method_length: [4]u8 = undefined;
    std.mem.writeInt(u32, &method_length, @intCast(method_path.len), .big);
    var request_length: [8]u8 = undefined;
    std.mem.writeInt(u64, &request_length, @intCast(request_bytes.len), .big);
    var status_message_length: [4]u8 = undefined;
    std.mem.writeInt(u32, &status_message_length, @intCast(status_message.len), .big);
    var response_length: [8]u8 = undefined;
    std.mem.writeInt(u64, &response_length, @intCast(response_bytes.len), .big);

    var mac = HmacSha256.init(&key);
    mac.update(response_domain);
    mac.update(&method_length);
    mac.update(method_path);
    mac.update(&source_node_id);
    mac.update(&target_node_id);
    mac.update(&challenge);
    mac.update(&request_length);
    mac.update(request_bytes);
    mac.update(&.{status_code});
    mac.update(&status_message_length);
    mac.update(status_message);
    mac.update(&response_length);
    mac.update(response_bytes);
    var tag: Tag = undefined;
    mac.final(&tag);
    return tag;
}

fn exactlyOne(metadata: anytype, name: []const u8) ![]const u8 {
    var found: ?[]const u8 = null;
    for (metadata) |entry| {
        if (!std.mem.eql(u8, entry.key, name)) continue;
        if (found != null) return error.DuplicateAuthenticationMetadata;
        found = entry.value;
    }
    return found orelse error.MissingAuthenticationMetadata;
}

fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn testId(seed: u8) Id {
    var id: Id = @splat(0);
    id[0] = seed;
    id[15] = seed ^ 0xa5;
    return id;
}

fn testKey(seed: u8) Key {
    var key: Key = undefined;
    for (&key, 0..) |*byte, index| byte.* = seed +% @as(u8, @intCast(index));
    return key;
}

test "authenticated metadata binds peers method and exact request bytes" {
    const source = PeerKey{ .node_id = testId(1), .key = testKey(9) };
    const target = testId(9);
    var authenticator = try Authenticator.init(std.testing.allocator, target, &.{source});
    defer authenticator.deinit();

    const method = "/zettide.controller.v1.ReplicaTransport/Prepare";
    const request = "serialized protobuf request";
    const challenge: Challenge = @splat(0x5c);
    const signed = signedMetadata(source.node_id, target, challenge, source.key, method, request);
    const entries = signed.entries();
    const verified = try authenticator.verify(&entries, method, request);
    try std.testing.expectEqual(source.node_id, verified.source_node_id);
    try std.testing.expectEqual(signed.challenge, verified.challenge);
    try std.testing.expectError(error.AuthenticationFailed, authenticator.verify(&entries, method, "changed"));
    try std.testing.expectError(error.AuthenticationFailed, authenticator.verify(&entries, "/wrong", request));

    const wrong_target = signedMetadata(source.node_id, testId(8), challenge, source.key, method, request);
    const wrong_target_entries = wrong_target.entries();
    try std.testing.expectError(
        error.AuthenticationFailed,
        authenticator.verify(&wrong_target_entries, method, request),
    );

    const response_tag = try authenticator.responseTag(source.node_id, challenge, method, request, 0, "", "response");
    const response_metadata = [_]Metadata{.{
        .key = response_authentication_metadata,
        .value = &response_tag,
    }};
    try verifyResponse(source.node_id, target, challenge, source.key, &response_metadata, method, request, 0, "", "response");
    try std.testing.expectError(
        error.AuthenticationFailed,
        verifyResponse(source.node_id, target, challenge, source.key, &response_metadata, method, request, 0, "", "changed"),
    );
    try std.testing.expectError(
        error.AuthenticationFailed,
        verifyResponse(source.node_id, target, challenge, source.key, &response_metadata, method, request, 9, "failed", "response"),
    );
    const fresh_challenge: Challenge = @splat(0x6c);
    try std.testing.expectError(
        error.AuthenticationFailed,
        verifyResponse(source.node_id, target, fresh_challenge, source.key, &response_metadata, method, request, 0, "", "response"),
    );
}

test "authentication rejects unknown peers and duplicate metadata" {
    const source = PeerKey{ .node_id = testId(2), .key = testKey(3) };
    const target = testId(9);
    var authenticator = try Authenticator.init(std.testing.allocator, target, &.{source});
    defer authenticator.deinit();

    const challenge: Challenge = @splat(0x6d);
    const unknown_id = testId(7);
    const signed = signedMetadata(unknown_id, target, challenge, testKey(7), "/method", "request");
    const entries = signed.entries();
    try std.testing.expectError(error.UnknownPeer, authenticator.verify(&entries, "/method", "request"));

    const valid = signedMetadata(source.node_id, target, challenge, source.key, "/method", "request");
    const valid_entries = valid.entries();
    const duplicate = [_]Metadata{
        valid_entries[0],
        valid_entries[0],
        valid_entries[1],
    };
    try std.testing.expectError(
        error.DuplicateAuthenticationMetadata,
        authenticator.verify(&duplicate, "/method", "request"),
    );
}

test "invalid peer key configuration scrubs duplicated secret bytes" {
    var backing: [1024]u8 = @splat(0xcc);
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    const local: Id = @splat(0x11);
    const secret: Key = @splat(0xab);
    try std.testing.expectError(
        error.InvalidPeerNodeId,
        Authenticator.init(fixed.allocator(), local, &.{.{
            .node_id = local,
            .key = secret,
        }}),
    );
    try std.testing.expect(std.mem.indexOf(u8, &backing, &secret) == null);
}

test "peer key configuration rejects zero local peer and duplicate identities" {
    try std.testing.expectError(
        error.InvalidLocalNodeId,
        Authenticator.init(std.testing.allocator, @splat(0), &.{.{ .node_id = testId(1), .key = testKey(1) }}),
    );
    try std.testing.expectError(
        error.InvalidPeerNodeId,
        Authenticator.init(std.testing.allocator, testId(9), &.{.{ .node_id = @splat(0), .key = testKey(1) }}),
    );
    try std.testing.expectError(
        error.InvalidPeerKey,
        Authenticator.init(std.testing.allocator, testId(9), &.{.{ .node_id = testId(1), .key = @splat(0) }}),
    );
    const source = PeerKey{ .node_id = testId(1), .key = testKey(1) };
    try std.testing.expectError(
        error.DuplicatePeerNodeId,
        Authenticator.init(std.testing.allocator, testId(9), &.{ source, source }),
    );
    try std.testing.expectError(
        error.DuplicatePeerKey,
        Authenticator.init(std.testing.allocator, testId(9), &.{ source, .{ .node_id = testId(2), .key = source.key } }),
    );
    try std.testing.expectError(
        error.InvalidPeerNodeId,
        Authenticator.init(std.testing.allocator, source.node_id, &.{source}),
    );
}
