# grpc-lite

[![CI](https://github.com/fanyang89/grpc-lite/actions/workflows/ci.yml/badge.svg)](https://github.com/fanyang89/grpc-lite/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/fanyang89/grpc-lite/graph/badge.svg)](https://codecov.io/gh/fanyang89/grpc-lite)
[![Release](https://img.shields.io/github/v/release/fanyang89/grpc-lite)](https://github.com/fanyang89/grpc-lite/releases)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)
[![License](https://img.shields.io/github/license/fanyang89/grpc-lite)](LICENSE)

A lightweight, streaming-first gRPC runtime for Zig with stable C and focused C++ APIs.

grpc-lite delegates HTTP/2 framing, HPACK, stream state, and flow control to nghttp2;
libxev owns sockets and event loops. The transport keeps protobuf optional and exposes raw
wire bytes, explicit allocators, deterministic teardown, and bounded backpressure.

## Highlights

| Transport | Runtime | Integration |
| --- | --- | --- |
| Unary and full-duplex streaming | Persistent multiplexed channels | Raw Zig and stable C APIs |
| Cleartext HTTP/2 and optional TLS | IPv4 DNS through c-ares | Typed zig-protobuf adapters |
| Deadlines and cancellation | GOAWAY replacement and reconnect | Focused grpcpp-shaped C++ facade |
| ASCII and binary metadata | Graceful server drain | CMake source builds without Zig |
| Per-message identity or gzip | Multi-reactor Linux servers | Generated C++ service glue |

## Quick Start

### Zig

Add grpc-lite to `build.zig.zon`, then import its public module:

```zig
const grpc_lite = b.dependency("grpc_lite", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("grpc_lite", grpc_lite.module("grpc_lite"));
```

```zig
const grpc = @import("grpc_lite");

var channel = try grpc.Channel.init(allocator, "127.0.0.1:50051", .{});
defer channel.deinit();

var result = try channel.callUnary(
    allocator,
    "/demo.EchoService/Echo",
    protobuf_wire_bytes,
    .{},
);
defer result.deinit();
```

### C and C++

Source consumers can build the checked-in C translation directly. Zig is not required:

```cmake
include(FetchContent)
FetchContent_Declare(
  grpc_lite
  GIT_REPOSITORY https://github.com/fanyang89/grpc-lite.git
  GIT_TAG v0.4.0)
FetchContent_MakeAvailable(grpc_lite)

target_link_libraries(c_app PRIVATE grpc_lite::c)
target_link_libraries(cpp_app PRIVATE grpc_lite::grpcpp)
```

The source CMake build currently targets insecure Linux x86_64. The native Zig build
supports Linux x86_64 and arm64, with TLS available through an optional mbedTLS build.

## Compatibility

The `grpc-lite-streaming-insecure-v2` profile covers raw unary, client-streaming,
server-streaming, and bidirectional streaming. It is continuously tested against
official grpc-go peers and public HTTP/2 framing suites on x86_64 and arm64.

| Capability | Status |
| --- | --- |
| Raw unary and all streaming cardinalities | Supported |
| Typed zig-protobuf unary and streaming | Supported |
| Metadata, deadlines, gzip, GOAWAY, drain | Supported |
| TLS 1.2+, ALPN `h2`, explicit PEM credentials | Optional |
| grpcpp-shaped synchronous common API | Selected subset |
| IPv6, mTLS, retries, reflection, xDS | Out of scope |

See [the official interoperability profile](tests/official/README.md) for current cases
and results. grpc-lite does not provide grpc-core ABI compatibility or the full grpcpp
CompletionQueue, callback/reactor, generic service, or policy stack.

## Documentation

- [Zig API](docs/zig-api.md): runtime, channels, streaming, servers, TLS, and protobuf
- [C and C++ APIs](docs/c-cpp-api.md): stable ABI, source builds, grpcpp facade, and codegen
- [Development](docs/development.md): toolchain, CI, profiling, benchmarks, and dependencies
- [Official interop](tests/official/README.md): required gRPC and HTTP/2 compatibility matrix

Public types re-exported by `src/root.zig`, the installed C ABI, and installed C++
headers are the supported API surfaces. Lower-level Zig modules may change before 1.0.

## Development

```bash
mise install
mise run bootstrap
mise run check
```

See the [development guide](docs/development.md) for individual tasks and build options.

## License

[MIT](LICENSE)
