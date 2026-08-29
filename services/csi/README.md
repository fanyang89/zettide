# Zettide CSI Node Service

`services/csi/` contains the current `fuse.csi.zettide.io` Node service and its
container image. It is a **partial, static filesystem integration**, not a full
Zettide CSI driver.

## Current capability

The service implements:

- CSI Identity: `GetPluginInfo`, `GetPluginCapabilities`, and `Probe`;
- CSI Node: `NodeGetInfo`, `NodeGetCapabilities`, `NodePublishVolume`, and
  `NodeUnpublishVolume`;
- static `zettide://filesystem/<uuid>` identity validation through
  `zettide info`;
- foreground `zettide mount` ownership with read-only support;
- persisted publication records, exclusive state-directory locking, FUSE
  process recovery, CSI service restart recovery, and conservative unpublish;
- source and publish-path confinement below configured roots.

`NodePublishVolume` currently accepts `SINGLE_NODE_WRITER`,
`SINGLE_NODE_SINGLE_WRITER`, and `SINGLE_NODE_READER_ONLY`; multi-node writer
modes are rejected. The current service accepts a regular Blob file below `--source-root`; it does
not assemble a raw multi-member Pool. `MaxVolumesPerNode` is currently one.

## Explicit exclusions

The service does not implement:

- CSI Controller RPCs or dynamic provisioning;
- Catalog block volumes, NVMf, or iSCSI attachment;
- NFS staging or export management;
- snapshots, clones, expansion, topology provisioning, or multi-node writers;
- controller-backed Publication authority or access-generation fencing.

The repository's NFS CSI kind profile uses the pinned upstream NFS CSI driver
against Zettide's NFS frontend. It is separate from this FUSE Node service.

## Build and test

Go 1.26.5 is pinned by the local `mise.toml`.

```sh
mise trust
mise install
mise run check
```

The check runs formatting verification, `go vet`, unit tests, and a static
`zettide-csi-node` build. The destructive/container integration profile is
owned by the repository automation:

```text
tests/fuse-csi-kind.sh
tests/automation/csi-fuse-kind.yml
```

It requires Linux, Docker, kind, kubectl, `/dev/fuse`, and the privileges needed
to create mounts inside the kind node. The profile verifies publish/unpublish,
read-only behavior, FUSE child recovery, CSI pod restart recovery, cleanup, and
a final `zettide check`.

## Runtime

The executable defaults to `unix:///csi/csi.sock` and requires a stable
`--node-id`. Production deployments must provide persistent `--state-dir`, an
allowed static target root, the kubelet publish root, the `zettide` executable,
and `fusermount3`. The container image expects those binaries to be staged under
`services/csi/bin/` before build; the automation task performs that staging.

Paths, PIDs, mountpoints, and Kubernetes Node names are runtime observations,
not storage identity. The stable volume handle remains
`zettide://filesystem/<uuid>`.
