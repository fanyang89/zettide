# Local controller/data-node E2E

This Docker Compose environment starts:

- a single-voter `zettide-controller` with persistent Raft state;
- a one-shot bootstrap job that creates a controller Pool and publishes its ID
  through a shared volume;
- three `zettide-data-node` instances in distinct failure domains; each registers
  its Node/file Member plus a distinct internal Replica endpoint and pinned
  generation-1 signing key, loads receiver-scoped development keys and an
  owner-only deterministic development signing seed, advances durable heartbeat incarnation, and
  reports capacity;
- one file-backed iSCSI LUN in each data-node container;
- an optional smoke container that creates a Volume, verifies real DataService
  reconciliation reaches `ACTIVE` with allocated capacity on all three Members,
  records the initial write epoch and heartbeat incarnations, and connects to
  node 1's independent TGT LUN
  with libiscsi (`iscsi-ls`, `iscsi-inq`,
  `iscsi-readcapacity16`, and `iscsi-md5sum`).

The local profile uses TGT as a lightweight iSCSI transport harness. It tests
service composition, three-node Node/Member/Replica-endpoint/signing-key registration,
unauthenticated Replica PREPARE/COMMIT/INSPECT rejection, fresh capacity
heartbeats, Replica ensure plus canonical write-participant configuration,
fence/recovery/ready
reconciliation, discovery, login-free SCSI commands, and
reads without requiring SPDK, host
iSCSI kernel modules, or privileged containers. The TGT LUN and registered file
Member intentionally use separate backing files, so the SCSI checks are an
orthogonal transport smoke—not managed Volume or Replica data-path coverage.
A second smoke can restart every controller/data-node process, verify Replica
recovery/reconciliation, heartbeat reincarnation, and unchanged pinned signing
keys, and wait for authority replacement at a strictly higher write epoch. A
separate bounded registration-migration gate seeds controller state through real
RPCs and starts the real data-node daemons over endpoint-first, key-first, and
already-atomically-filled Node records.
The service containers use `seccomp=unconfined` because grpc-lite's
libxev runtime uses io_uring syscalls blocked by Docker's default seccomp
profile. Production Catalog publication remains on the SPDK path.

Run all commands from the repository root:

```sh
docker compose -f tests/e2e/docker-compose.yml up -d --build \
  controller bootstrap data-node-1 data-node-2 data-node-3
docker compose -f tests/e2e/docker-compose.yml run --rm --build smoke
```

To exercise process restart, state recovery, lease expiry, and primary failover
without deleting the named volumes:

```sh
docker compose -f tests/e2e/docker-compose.yml restart \
  controller data-node-1 data-node-2 data-node-3
docker compose -f tests/e2e/docker-compose.yml run --rm \
  --entrypoint /usr/local/bin/zettide-e2e-restart-smoke smoke
```

Run the registration migration gate independently; it uses disposable Compose
volumes and cleans them up when complete:

```sh
tests/e2e/registration-migration.sh
```

The gate proves the actual daemon `submitNodeRegistration` path reads fresh
`GetNode` state instead of trusting a stale legacy dedup response, converges the
three supported fill orderings, and rejects a conflicting signing seed without
changing the pinned key.

The smoke's `ACTIVE / HEALTHY` assertion is a controller lifecycle assertion:
the controller reaches it only through its readiness action, while direct
`InspectPrimary.current_active/current_admitting` remains an internal binding-
scoped diagnostic whose authority binding is intentionally not exposed by the
public controller API. The real data-node readiness flags and signed write
lifecycle are covered by `zig build test-controller`; the Docker smoke does not
claim a separate public runtime-readiness API.

The failover check normally takes at least the configured 30-second lease
window. It requires the new Volume write epoch to exceed the value captured by
the initial smoke.

Inspect the registered services or logs with:

```sh
docker compose -f tests/e2e/docker-compose.yml ps
docker compose -f tests/e2e/docker-compose.yml logs \
  controller bootstrap data-node-1 data-node-2 data-node-3
```

Stop the services while preserving controller and LUN data:

```sh
docker compose -f tests/e2e/docker-compose.yml down
```

Delete the local E2E state as well:

```sh
docker compose -f tests/e2e/docker-compose.yml down -v
```

The controller management port is `8001`; data-node control ports are
`7001`–`7003`, internal Replica listeners use container port `7443`, and host
iSCSI ports are `3261`–`3263`. Replica RPC is explicitly plaintext in this local
profile, with application-layer pairwise HMAC authentication and independently
verifiable Ed25519 write evidence; it is not a production confidentiality or
key-rotation configuration. The single-voter Raft
transport stays on the controller container's loopback interface. The Compose
network assigns `172.30.0.10` to the controller because the prototype data-node
client accepts an IPv4 target directly but does not yet initialize grpc-lite's
DNS resolver runtime.
