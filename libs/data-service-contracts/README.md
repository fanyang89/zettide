# zettide-data-service-contracts

Shared data-service API contracts and authority safety model for Zettide.

The package contains no Raft, CLI, transport, or physical storage backend
dependencies. It owns the wire-neutral Replica/authority models plus the
idempotent Replica operation engine and its checksummed, fsync-backed journal.
Consumers generate protobuf bindings with their own grpc/protobuf toolchain.

```sh
zig build test
```
