# zettide-data-service-contracts

Shared data-service API contracts and authority safety model for Zettide.

The package contains no Raft, CLI, transport, or physical storage backend
dependencies. It owns the wire-neutral Replica/authority models plus the
idempotent Replica and fence operation engines and their checksummed,
fsync-backed journals.
Consumers generate protobuf bindings with their own grpc/protobuf toolchain.

```sh
zig build test
```
