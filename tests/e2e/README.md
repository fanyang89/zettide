# Local controller/data-node E2E

This Docker Compose environment starts:

- a single-voter `zettide-controller` with persistent Raft state;
- `zettide-data-node`, which starts its DataService endpoint and durably calls
  `NodeService.RegisterNode` on the controller;
- a file-backed iSCSI LUN in the data-node container;
- an optional smoke container that verifies the controller registration and
  connects to the LUN with libiscsi (`iscsi-ls`, `iscsi-inq`,
  `iscsi-readcapacity16`, and `iscsi-md5sum`).

The local profile uses TGT as a lightweight iSCSI transport harness. It tests
service composition, registration, discovery, login-free SCSI commands, and
reads without requiring SPDK, host iSCSI kernel modules, or privileged
containers. The service containers use `seccomp=unconfined` because grpc-lite's
libxev runtime uses io_uring syscalls blocked by Docker's default seccomp
profile. Production Catalog publication remains on the SPDK path.

Run all commands from the repository root:

```sh
docker compose -f tests/e2e/docker-compose.yml up -d --build controller data-node
docker compose -f tests/e2e/docker-compose.yml run --rm --build smoke
```

Inspect the registered services or logs with:

```sh
docker compose -f tests/e2e/docker-compose.yml ps
docker compose -f tests/e2e/docker-compose.yml logs controller data-node
```

Stop the services while preserving controller and LUN data:

```sh
docker compose -f tests/e2e/docker-compose.yml down
```

Delete the local E2E state as well:

```sh
docker compose -f tests/e2e/docker-compose.yml down -v
```

The controller management, data-node control, and iSCSI ports are exposed on
localhost as `8001`, `7001`, and `3260`, respectively. The single-voter Raft
transport stays on the controller container's loopback interface. The Compose
network assigns `172.30.0.10` to the controller because the prototype data-node
client accepts an IPv4 target directly but does not yet initialize grpc-lite's
DNS resolver runtime.
