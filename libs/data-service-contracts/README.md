# zettide-data-service-contracts

Shared data-service API contracts and authority safety model for Zettide.

The package contains no Raft, CLI, transport, or storage backend dependencies.
Consumers generate protobuf bindings with their own grpc/protobuf toolchain.

```sh
zig build test
```
