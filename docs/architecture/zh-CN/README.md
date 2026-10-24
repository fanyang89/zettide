# Zettide architecture

Zettide is scoped to single-node VM block storage with its own engine and local
multi-disk protection. [ADR 0005](../../decisions/0005-single-node-vm-block-storage.md)
replaces the former filesystem/distributed product architecture.

```text
External virtualization consumer
    -> host-facing block export
    -> services/data-node (SPDK, endpoint owner, local management)
    -> libs/storage-engine (Catalog Volume, extent map, Pool/Member)
    -> local physical disks
```

One process owns a writable Pool. The engine does not start sockets, own SPDK
runtime state, or depend on product management services. Local Pool authority
and journal recovery are retained; they are not a cluster controller.

The current endpoint daemon is the starting point for local block service
composition. No replacement distributed controller or metadata service is
required. Multiple hosts may use distinct Volumes, but the baseline does not
permit concurrent writers to one Volume or provide storage-node HA.

See [scope and implementation status](00-scope-and-status.md) for current limits,
including the one-endpoint-per-Pool restriction. Format contracts are documented
in [Member/Pool](../../v3-format.md),
[Catalog](../../v3-multivolume-format.md), and
[control rollover](../../v3-control-rollover-format.md).

See [component boundaries](component-dependencies.md) and
[block safety](../../block-safety.md) for retained ownership and failure rules.
Obsolete filesystem/distributed architecture chapters have been removed. The
superseded ADRs and repository history record the former product direction.
