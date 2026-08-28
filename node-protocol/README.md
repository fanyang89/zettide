# zettide-node-protocol

Shared node-local data protocol and authority safety model for Zettide.

The package contains no Raft, CLI, transport, or storage backend dependencies.
Consumers generate protobuf bindings with their own grpc/protobuf toolchain.

```sh
zig build test
```
