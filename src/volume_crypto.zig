const std = @import("std");

const Aes256 = std.crypto.core.aes.Aes256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Argon2 = std.crypto.pwhash.argon2;

pub const master_key_length: usize = 32;
pub const salt_length: usize = 32;
pub const verifier_length: usize = 32;
pub const sector_size: usize = 512;

pub const Cipher = enum(u16) {
    aes_256_xts = 1,
};

pub const Kdf = enum(u16) {
    raw_key = 1,
    argon2id = 2,
};

pub const Config = struct {
    cipher: Cipher = .aes_256_xts,
    kdf: Kdf,
    data_unit_size: u32 = sector_size,
    salt: [salt_length]u8,
    argon_time: u32 = 0,
    argon_memory_kib: u32 = 0,
    argon_parallelism: u24 = 0,
    verifier: [verifier_length]u8,

    pub fn validate(self: Config) !void {
        if (self.cipher != .aes_256_xts or self.data_unit_size != sector_size)
            return error.UnsupportedEncryptionConfig;
        if (std.mem.allEqual(u8, &self.salt, 0)) return error.InvalidEncryptionConfig;
        switch (self.kdf) {
            .raw_key => if (self.argon_time != 0 or self.argon_memory_kib != 0 or
                self.argon_parallelism != 0) return error.InvalidEncryptionConfig,
            .argon2id => {
                if (self.argon_time == 0 or self.argon_time > 10 or
                    self.argon_memory_kib < 8 or self.argon_memory_kib > 1024 * 1024 or
                    self.argon_parallelism == 0 or self.argon_parallelism > 16)
                    return error.InvalidEncryptionConfig;
            },
        }
    }
};

pub const Credential = union(Kdf) {
    raw_key: *const [master_key_length]u8,
    argon2id: []const u8,

    pub fn kind(self: Credential) Kdf {
        return std.meta.activeTag(self);
    }
};

pub const Prepared = struct {
    config: Config,
    context: Context,
};

pub fn prepare(
    allocator: std.mem.Allocator,
    io: std.Io,
    credential: Credential,
) !Prepared {
    var config: Config = .{
        .kdf = credential.kind(),
        .salt = undefined,
        .verifier = undefined,
    };
    while (true) {
        try io.randomSecure(&config.salt);
        if (!std.mem.allEqual(u8, &config.salt, 0)) break;
    }
    if (credential == .argon2id) {
        config.argon_time = 2;
        config.argon_memory_kib = 64 * 1024;
        config.argon_parallelism = 1;
    }
    const keys = try deriveKeys(allocator, io, config, credential);
    defer secureZero(DerivedKeys, &keys);
    config.verifier = makeVerifier(config, keys.verifier);
    return .{ .config = config, .context = Context.init(keys.xts) };
}

pub const Context = struct {
    data_encrypt: @TypeOf(Aes256.initEnc(@splat(0))),
    data_decrypt: @TypeOf(Aes256.initDec(@splat(0))),
    tweak_encrypt: @TypeOf(Aes256.initEnc(@splat(0))),

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
        credential: Credential,
    ) !Context {
        try config.validate();
        if (credential.kind() != config.kdf) return error.EncryptionCredentialTypeMismatch;
        const keys = try deriveKeys(allocator, io, config, credential);
        defer secureZero(DerivedKeys, &keys);
        const expected = makeVerifier(config, keys.verifier);
        if (!std.crypto.timing_safe.eql([verifier_length]u8, expected, config.verifier))
            return error.InvalidEncryptionCredential;
        return init(keys.xts);
    }

    fn init(key: [64]u8) Context {
        return .{
            .data_encrypt = Aes256.initEnc(key[0..32].*),
            .data_decrypt = Aes256.initDec(key[0..32].*),
            .tweak_encrypt = Aes256.initEnc(key[32..64].*),
        };
    }

    pub fn encrypt(self: *const Context, output: []u8, input: []const u8, data_unit: u64) !void {
        try self.crypt(output, input, data_unit, true);
    }

    pub fn decrypt(self: *const Context, output: []u8, input: []const u8, data_unit: u64) !void {
        try self.crypt(output, input, data_unit, false);
    }

    pub fn deinit(self: *Context) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }

    fn crypt(
        self: *const Context,
        output: []u8,
        input: []const u8,
        data_unit: u64,
        encrypting: bool,
    ) !void {
        if (output.len != input.len or input.len < 16 or input.len % 16 != 0)
            return error.InvalidDataUnit;
        var tweak_input: [16]u8 = @splat(0);
        std.mem.writeInt(u64, tweak_input[0..8], data_unit, .little);
        var tweak: [16]u8 = undefined;
        self.tweak_encrypt.encrypt(&tweak, &tweak_input);
        var offset: usize = 0;
        while (offset < input.len) : (offset += 16) {
            var mixed: [16]u8 = undefined;
            for (&mixed, input[offset..][0..16], &tweak) |*byte, source, mask|
                byte.* = source ^ mask;
            var transformed: [16]u8 = undefined;
            if (encrypting)
                self.data_encrypt.encrypt(&transformed, &mixed)
            else
                self.data_decrypt.decrypt(&transformed, &mixed);
            for (output[offset..][0..16], &transformed, &tweak) |*byte, source, mask|
                byte.* = source ^ mask;
            multiplyByX(&tweak);
        }
    }
};

const DerivedKeys = struct {
    xts: [64]u8,
    verifier: [32]u8,
};

fn deriveKeys(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    credential: Credential,
) !DerivedKeys {
    try config.validate();
    if (credential.kind() != config.kdf) return error.EncryptionCredentialTypeMismatch;
    var master: [master_key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &master);
    switch (credential) {
        .raw_key => |key| master = key.*,
        .argon2id => |passphrase| {
            if (passphrase.len == 0) return error.EmptyPassphrase;
            try Argon2.kdf(allocator, &master, passphrase, &config.salt, .{
                .t = config.argon_time,
                .m = config.argon_memory_kib,
                .p = config.argon_parallelism,
            }, .argon2id, io);
        },
    }
    var prk = HkdfSha256.extract(&config.salt, &master);
    defer std.crypto.secureZero(u8, &prk);
    var result: DerivedKeys = undefined;
    HkdfSha256.expand(&result.xts, "zettide-volume-xts-v1", prk);
    HkdfSha256.expand(&result.verifier, "zettide-volume-verifier-v1", prk);
    return result;
}

fn makeVerifier(config: Config, key: [32]u8) [verifier_length]u8 {
    var material: [52]u8 = @splat(0);
    std.mem.writeInt(u16, material[0..2], @intFromEnum(config.cipher), .little);
    std.mem.writeInt(u16, material[2..4], @intFromEnum(config.kdf), .little);
    std.mem.writeInt(u32, material[4..8], config.data_unit_size, .little);
    std.mem.writeInt(u32, material[8..12], config.argon_time, .little);
    std.mem.writeInt(u32, material[12..16], config.argon_memory_kib, .little);
    std.mem.writeInt(u32, material[16..20], config.argon_parallelism, .little);
    @memcpy(material[20..52], &config.salt);
    var verifier: [verifier_length]u8 = undefined;
    HmacSha256.create(&verifier, &material, &key);
    return verifier;
}

fn multiplyByX(tweak: *[16]u8) void {
    var carry: u8 = 0;
    for (tweak) |*byte| {
        const next = byte.* >> 7;
        byte.* = (byte.* << 1) | carry;
        carry = next;
    }
    if (carry != 0) tweak[0] ^= 0x87;
}

fn secureZero(comptime T: type, value: *const T) void {
    std.crypto.secureZero(u8, @constCast(std.mem.asBytes(value)));
}

test "AES-256-XTS matches NIST CAVP data-unit sequence vector" {
    const key = try decodeHex(64, "ef010ca1a3663e32534349bc0bae62232a1573348568fb9ef41768a7674f507a727f98755397d0e0aa32f830338cc7a926c773f09e57b357cd156afbca46e1a0");
    const plaintext = try decodeHex(32, "ed98e01770a853b49db9e6aaf88f0a41b9b56e91a5a2b11d40529254f5523e75");
    const expected = try decodeHex(32, "ca20c55e8dc149687d2541de39c3df6300bb5a163c10ced3666b1357db8bd39d");
    var context = Context.init(key);
    defer context.deinit();
    var ciphertext: [plaintext.len]u8 = undefined;
    try context.encrypt(&ciphertext, &plaintext, 187);
    try std.testing.expectEqualSlices(u8, &expected, &ciphertext);
    var recovered: [plaintext.len]u8 = undefined;
    try context.decrypt(&recovered, &ciphertext, 187);
    try std.testing.expectEqualSlices(u8, &plaintext, &recovered);
}

test "raw key config rejects wrong credentials" {
    const key: [master_key_length]u8 = @splat(0x42);
    var prepared = try prepare(std.testing.allocator, std.testing.io, .{ .raw_key = &key });
    defer prepared.context.deinit();
    var opened = try Context.open(std.testing.allocator, std.testing.io, prepared.config, .{ .raw_key = &key });
    defer opened.deinit();
    const wrong: [master_key_length]u8 = @splat(0x43);
    try std.testing.expectError(
        error.InvalidEncryptionCredential,
        Context.open(std.testing.allocator, std.testing.io, prepared.config, .{ .raw_key = &wrong }),
    );
    try std.testing.expectError(
        error.EncryptionCredentialTypeMismatch,
        Context.open(std.testing.allocator, std.testing.io, prepared.config, .{ .argon2id = "secret" }),
    );
}

test "passphrase config derives a reopenable context" {
    var config: Config = .{
        .kdf = .argon2id,
        .salt = @splat(0x5a),
        .argon_time = 1,
        .argon_memory_kib = 8,
        .argon_parallelism = 1,
        .verifier = undefined,
    };
    const credential: Credential = .{ .argon2id = "correct horse battery staple" };
    const keys = try deriveKeys(std.testing.allocator, std.testing.io, config, credential);
    defer secureZero(DerivedKeys, &keys);
    config.verifier = makeVerifier(config, keys.verifier);
    var context = try Context.open(std.testing.allocator, std.testing.io, config, credential);
    defer context.deinit();
    try std.testing.expectError(
        error.InvalidEncryptionCredential,
        Context.open(std.testing.allocator, std.testing.io, config, .{ .argon2id = "wrong" }),
    );
}

fn decodeHex(comptime length: usize, text: *const [length * 2:0]u8) ![length]u8 {
    var bytes: [length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, text);
    return bytes;
}
