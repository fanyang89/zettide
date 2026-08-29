# Local controller/data-node E2E

This Docker Compose environment starts:

- a single-voter `zettide-controller` with persistent Raft state;
- a one-shot bootstrap job that creates a controller Pool and publishes its ID
  through a shared volume;
- three `zettide-data-node` instances in distinct failure domains; each registers
  its Node/file Member, advances durable heartbeat incarnation, and reports capacity;
- one file-backed iSCSI LUN in each data-node container;
- an optional smoke container that creates a Volume, verifies real DataService
  reconciliation reaches `ACTIVE` with allocated capacity on all three Members,
  records the initial write epoch and heartbeat incarnations, and connects to
  node 1's independent TGT LUN
  with libiscsi (`iscsi-ls`, `iscsi-inq`,
  `iscsi-readcapacity16`, and `iscsi-md5sum`).

The local profile uses TGT as a lightweight iSCSI transport harness. It tests
service composition, three-node Node/Member registration, fresh capacity
heartbeats, Replica/fence/recovery/ready reconciliation, discovery, login-free
SCSI commands, and reads without requiring SPDK, host
iSCSI kernel modules, or privileged containers. The TGT LUN and registered file
Member intentionally use separate backing files, so the SCSI checks are an
orthogonal transport smoke—not managed Volume or Replica data-path coverage.
A second smoke can restart every controller/data-node process, verify Replica
recovery/reconciliation and heartbeat reincarnation, and wait for authority replacement
at a strictly higher write epoch.
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
`7001`–`7003`, and host iSCSI ports are `3261`–`3263`. The single-voter Raft
transport stays on the controller container's loopback interface. The Compose
network assigns `172.30.0.10` to the controller because the prototype data-node
client accepts an IPv4 target directly but does not yet initialize grpc-lite's
DNS resolver runtime.
