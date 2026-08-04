# Remote Tier 1 Tests

The Ansible suite packages the controller's current Zettide working tree and
runs the complete Tier 1 gate on remote Fedora or Ubuntu hosts. Each host runs
Debug and ReleaseSafe tests, including raw loop devices and privileged POSIX
conformance suites.

## Target prerequisites

- SSH access and Python 3
- Privilege escalation through `sudo`
- Zig 0.16.0 available in `PATH`, or configured as `zettide_zig`
- Internet access for OS packages and pinned external suite checkouts
- Kernel access to FUSE and loop devices

## Inventory

Create the ignored inventory from the example and replace the documentation
addresses with real test hosts:

```sh
cp test/ansible/inventory.example.ini test/ansible/inventory.ini
```

Use SSH agent forwarding, normal SSH configuration, or Ansible Vault for
credentials. Do not store passwords or private keys in the inventory.

## Run

```sh
uv sync --locked
uv run ansible zettide_test -m ansible.builtin.ping
uv run ansible-playbook test/ansible/playbook.yml
```

Use `--limit HOST` for one target and `--ask-become-pass` when passwordless
privilege escalation is unavailable. Result archives are fetched to
`test-results/ansible/HOST-TIMESTAMP-COMMIT.tar.gz`, including command output
and external suite logs. The remote temporary workspace is removed unless
`-e zettide_keep_remote_workspace=true` is set.

## IO verification

The focused IO profile builds ReleaseSafe once, then runs deterministic fio
CRC32C verification on each configured filesystem target. It verifies data on
the live mount, runs `zettide check`, remounts, and performs a verify-only pass.
It does not overwrite raw block devices.

Configure target directories in the ignored inventory:

```ini
[zettide_test]
zettide-tier1 ansible_host=100.83.174.20 ansible_user=fanmi

[zettide_test:vars]
zettide_zig=zig
zettide_io_targets=[{"name":"pm883","tmpdir":"/mnt/pm883-1"},{"name":"optane","tmpdir":"/mnt/optane"}]
```

Run the focused profile:

```sh
uv run ansible-playbook test/ansible/io-verify.yml --limit zettide-tier1
```

Each run uses a host-wide lock and stores a timestamped result archive under
`test-results/ansible/`.

## Throughput

The throughput profile compares a direct-I/O host filesystem baseline with
cold-cache Zettide sequential reads and writes. Each phase runs for 15 seconds
after a two-second ramp. Zettide is tested with one stream and four streams,
and the profile records fio JSON, wall time, pidstat, and iostat output.
On Red Hat family hosts it also records a `perf` profile for each Zettide phase.

Configure `zettide_throughput_targets` in the ignored inventory and run:

```sh
uv run ansible-playbook test/ansible/throughput.yml --limit zettide-tier1
```

The benchmark creates sparse 8 GiB temporary images inside the configured
directories. It never writes raw block devices.

## BlobDevice

The BlobDevice profile measures the file-backed data plane without LittleFS,
object metadata, or FUSE. Configure `zettide_blob_device_targets` and run:

```sh
uv run ansible-playbook test/ansible/blob-device.yml --limit zettide-tier1
```

The workload profile measures 4 KiB QD1 IOPS and 256 KiB/1 MiB QD1 bandwidth:

```sh
uv run ansible-playbook test/ansible/blob-workload.yml --limit zettide-tier1
```

Each result reports actual operations per second, bytes per second, average
latency, and p95 latency. Latency samples cover one submitted batch; the
default workload matrix uses batch depth one, so each sample is one operation.
Write latency and IOPS measure accepted writes; durable throughput and IOPS
include the final data sync.

Use `blob-store.yml` with the same targets to include immutable blob framing,
CRC32C, allocation, commit, reopen, and verification.
Use `blob-object.yml` to include COW object maps and object-head publication.
