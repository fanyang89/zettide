# Block storage safety and validation

Zettide is experimental single-node VM block storage, not production-ready or
storage-node HA. Local multi-disk protection is not a substitute for backups.

## Ownership and publication

One process owns a writable Pool. Each writable Volume has one authorized
consumer; network reachability alone is not authorization. Do not permit two
independent writers or bypass Pool locks and Catalog data leases. Keep the
registry's one-endpoint-per-Pool guard until shared ownership and multi-Volume
lease coordination are implemented and tested.

The endpoint Unix control socket is owner-only. The NVMe/TCP frontend still
need an isolated trusted storage network and explicit host access configuration;
do not infer production authentication, encryption, or safe multi-writer access
from a running SPDK export.

## Retired endpoint protocols

Only `nvme_of_tcp` is accepted by the control API. The `ZETENDP1` v2 state
format and TCP frontend value `3` are unchanged; values `1` (vhost), `2` (iSCSI),
and `4` (RDMA) remain retired. v1 state implicitly described vhost endpoints
and is rejected as well. Startup reports `RetiredEndpointFrontend`, preserves
the entire state file, and does not start SPDK or open Pools for that state.
Even a mixed TCP/retired state file is rejected in full, not partially reconciled.

There is no automatic migration or deletion. Retain a backup and use the prior
version to inspect and release retired endpoints before switching versions.
Then explicitly configure TCP access policy and recreate the intended endpoints;
do not edit frontend bytes or bypass checksums. Unchanged TCP-only v2 state
continues to reconcile with the same bdev name, NQN, serial, and NSID.

Old daemon protocol flags and non-TCP benchmark settings fail before runtime or
media changes. C adapter ABI slots for transport and the retired vhost path are
retained only to reject old requests; they do not restore those capabilities.

## Provisioning and compatibility

`pool plan-create` scans the explicit whole devices. `pool create` reacquires
them exclusively, rescans, and checks a token binding geometry, disk sequence,
device order, label, protection, and Catalog mode. Mounted, held, read-only,
duplicate, incompatible, or nonempty devices are not eligible. Never bypass the
confirmation or identity checks.

Creation provisions a Catalog-mode Pool, not an initialized Catalog or Volume.
Do not advertise an uninitialized Pool as a usable VM disk. Plan tokens now use
a new versioned domain; tokens from the retired filesystem CLI are invalid.

Blob files cannot be mounted, reformatted, or converted by a filesystem CLI;
those commands are gone. Retained Member feature bits and layout/geometry
validation can identify old Blob Pools. Catalog I/O must reject their data mode,
not reinterpret their bytes or reuse retired feature values.

## Failures and recovery

Keep the existing conservative write/flush failure and freeze behavior.
Acknowledgement must follow the validated durability contract, not merely queue
submission. Local protection does not imply degraded writes, online replacement,
automatic rebuild, or failover to another node. A generation-zero Pool has no
committed Catalog root. Recovery must respect journal evidence and media
identity; do not clear uncertainty by recreating metadata.

## Gates

Run `mise run test` and `mise run check` without incremental compilation before
committing. `zig build build-spdk-tests` compiles the SPDK integration libraries
without a runtime; it does not execute them.

`zig build test-linux-block -Dblock-tests=required` uses temporary loop backing
files to verify Catalog Pool creation, rejection of invalid/stale tokens,
nonempty media protection, reopen, and read-only/mounted-device preflight.
It requires Linux, loop support, filesystem utilities, and passwordless sudo.
FUSE is not involved. `auto` may explicitly skip unavailable prerequisites;
`required` fails instead.

SPDK runtime tests and remote physical-device profiles are separate explicit
gates. They may require privileged resources or overwrite data. Never run them
on real devices without an explicit disposable target and the profile's full
identity/confirmation guards. Unit and loop tests alone do not establish
physical multi-disk durability or managed VM attachment correctness.
