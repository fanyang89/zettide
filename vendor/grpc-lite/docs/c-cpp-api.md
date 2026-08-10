# C and C++ APIs

grpc-lite provides a stable C ABI, a low-level C++ RAII API in `grpc_lite::*`, and a
focused synchronous grpcpp-shaped facade in `grpc::*`. All three use the same transport.

## Installed Package

`zig build` installs the versioned shared library, static archive, C and C++ headers,
CMake package files, and `protoc-gen-grpc_lite_cpp` under `zig-out`.

```bash
cc app.c \
  -Izig-out/include \
  -Lzig-out/lib -Wl,-rpath,"$PWD/zig-out/lib" \
  -lgrpc_lite
```

The C ABI uses opaque handles, fixed-width error codes, and pointer-length byte views.
Memory allocated by the library must be released by its matching destroy function.

Runtime initialization must happen before application threads are created and must
outlive dependent handles. The API provides:

- version and feature discovery
- owning Runtime and Metadata handles
- connected and reconnecting managed Channels
- blocking raw unary calls
- cancellable event-driven client streams
- event-driven server registration and retained cross-thread calls
- metadata, bounded backpressure, cancellation observation, and graceful drain

C and C++ callback code runs synchronously on API caller or transport threads, may run
concurrently, and must not block unless the specific synchronous facade contract permits
it.

`grpc_lite_server_call_abort` and `grpc_lite::ServerCall::Abort` make an allocation-free,
thread-safe emergency termination request for a retained server call. The reactor resets
the stream with `INTERNAL_ERROR`, or closes the connection if reset submission fails.

## Managed Channels

`grpc_lite_channel_create_managed` creates a durable Channel. Set
`allow_initial_offline` to return before the first connection succeeds. A managed Channel
reconnects with bounded exponential backoff without replaying submitted RPCs. Unsubmitted
unary calls retain their original deadlines while waiting for a connection.

Use `grpc_lite_channel_shutdown` to stop admission and active work, then
`grpc_lite_channel_wait` before exclusive destruction when calls may be concurrent.

Channel and Server options accept an optional `grpc_lite_logger` for connection recovery,
GOAWAY, startup, and drain events. The logger configuration is borrowed during handle
creation; its user data must outlive the owning handle.

## CMake Source Build

The source build compiles checked-in C translations and does not require Zig. It currently
supports insecure Linux x86_64 and produces static C transport targets:

```cmake
add_subdirectory(third_party/grpc-lite)

target_link_libraries(c_app PRIVATE grpc_lite::c)
target_link_libraries(cpp_app PRIVATE grpc_lite::grpcpp)
```

`grpc_lite::c` and `grpc_lite::c_static` both refer to the source-built static transport.
An installed package exposes the versioned shared transport through `grpc_lite::c` and
the static archive through `grpc_lite::c_static`.

nghttp2 uses the nested submodule when available and otherwise uses its pinned archive.
c-ares uses its pinned archive. Dependency mirrors can override either source; hashes are
optional for custom URLs and use CMake's `ALGO=value` format:

```bash
cmake -S . -B build \
  -DGRPC_LITE_NGHTTP2_URL=https://mirror.example/nghttp2.tar.gz \
  -DGRPC_LITE_NGHTTP2_URL_HASH=SHA256=... \
  -DGRPC_LITE_CARES_URL=https://mirror.example/c-ares.tar.gz \
  -DGRPC_LITE_CARES_URL_HASH=SHA256=...
```

Maintainers run `mise run transpile-c` after changing the Zig runtime or C++ generator.

## Low-Level C++ API

Headers under `<grpc_lite/cpp/...>` provide explicit RAII wrappers over the C ABI,
including `grpc_lite::Runtime`, `Channel`, `ClientStream`, `Server`, `Metadata`, and
`Status`. This is the event-driven API for applications that need ownership and streaming
control without using C directly.

Hostname channels require explicit Runtime ownership. Use
`grpc_lite::Runtime` with `grpc_lite::Channel::CreateManaged`, or the equivalent C API.

## Synchronous grpcpp Facade

`<grpcpp/grpcpp.h>` provides the common synchronous client and generated server shapes:

- `grpc::Status` and status codes
- `grpc::ClientContext` and `grpc::ServerContext`
- Channels and channel arguments
- unary and server-streaming client calls
- generated nested `Service` classes
- `grpc::ServerWriter<T>` with bounded response backpressure

It is source-compatible with this selected API subset, not ABI-compatible with grpcpp.
It does not provide official generated glue, CompletionQueue, callbacks/reactors, generic
services, interceptors, or grpc-core internals.

The grpcpp-shaped `grpc::CreateChannel` facade currently accepts IPv4 targets. Use the
low-level C++ or C API when hostname resolution requires explicit Runtime ownership.

## Generated Services

The protoc plugin generates synchronous unary and server-streaming stubs beside standard
protobuf C++ messages. Generated services expose both nonblocking `EventService` and a
grpcpp-shaped nested `Service` with virtual methods.

```bash
protoc -I proto \
  --cpp_out=generated \
  --plugin=protoc-gen-grpc_lite_cpp=zig-out/bin/protoc-gen-grpc_lite_cpp \
  --grpc_lite_cpp_out=generated \
  proto/echo.proto
```

Compile `echo.grpc.pb.cc` and `echo.pb.cc`, then link `grpc_lite::grpcpp` and protobuf.

Create a fresh adapter for every server instance:

```cpp
auto adapter = service.CreateEventService(executor, options);
server.RegisterService(adapter.get());
```

Keep the service, executor, and adapter alive until the Server has stopped. Drain
submitted executor work before destroying the service.

`grpc_lite::ServerExecutor` is application-owned. `Submit` must enqueue without blocking;
handlers may block only on executor threads. Rejection completes the call with
`RESOURCE_EXHAUSTED`. The facade never creates worker threads.

`SynchronousServiceOptions::admission` may provide an application-owned, nonblocking
reactor hook that rejects metadata before a call enters the executor.

Complete consumers live under `examples/cpp`. Build them against an installed prefix:

```bash
cmake -S examples/cpp -B build-cpp -G Ninja \
  -DCMAKE_PREFIX_PATH="$PWD/zig-out"
cmake --build build-cpp
```

`mise run test-consumer-cpp` packages the project, regenerates C++ sources, starts the
installed server, and runs the examples.
