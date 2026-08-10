pub const api = @import("nghttp2_c");

test "native dependency versions are available" {
    const nghttp2 = api.nghttp2_version(0) orelse return error.MissingNghttp2Version;
    if (nghttp2.*.version_num == 0) return error.InvalidNghttp2Version;
}
