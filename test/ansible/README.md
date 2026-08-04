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

## Physical raw device

The raw-device profile temporarily destroys an entire physical disk. It checks
the configured whole-disk serial number and requires a command-line confirmation
that includes both the path and serial. The disk must have exactly one mounted
descendant, that mount must have an `/etc/fstab` entry, and the backup directory
must be on another filesystem with more free space than the disk capacity.

Configure the device in the ignored inventory:

```ini
[zettide_test:vars]
zettide_raw_device={"path":"/dev/nvme1n1","serial":"PHYSICAL-DISK-SERIAL","mountpoint":"/mnt/raw-test","backup_dir":"/mnt/backup"}
```

Run with the exact destructive confirmation:

```sh
uv run ansible-playbook test/ansible/raw-device.yml --limit zettide-tier1 \
  -e 'zettide_raw_device_confirm=DESTROY:/dev/nvme1n1:PHYSICAL-DISK-SERIAL'
```

The remote test unmounts the original filesystem, creates and byte-compares a
sparse full-device image, zeroes the disk, and exercises an unprotected Zettide
pool. It verifies writable persistence, exclusive-open protection, reopen, and
read-only enforcement. An exit trap restores and byte-compares the original
device image before remounting the original filesystem, including after test
failures or an SSH disconnect.

Backups are retained by default. Set `-e zettide_raw_keep_backup=false` to
delete the image only after both the test and restoration succeed. A host power
loss or `SIGKILL` can prevent automatic restoration; use the retained image for
manual recovery. The default async limit is 24 hours; increase
`zettide_raw_timeout` when the backup, test, and restoration passes may exceed
that time. This profile does not run fio by default and is not part of the
default Tier 1 gate.

Set `-e zettide_raw_fio=true` to run a direct `io_uring` fio matrix against the
empty raw disk before pool creation. The matrix covers 1 MiB sequential I/O and
4 KiB random I/O at QD1, QD32, and four jobs at QD32. It uses the first 64 GiB,
runs each case for 20 seconds after a 5-second ramp, and archives JSON results.
Override `zettide_raw_fio_size`, `zettide_raw_fio_runtime`, or
`zettide_raw_fio_ramp_time` as needed. Raw fio writes are destructive and remain
protected by the same image backup and restoration lifecycle.

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

The workload profile measures 4 KiB single-operation latency, 4 KiB batch-32
POSIX vectored IOPS, 4 KiB io_uring with 32 ring-inflight SQEs, and 256 KiB/1
MiB single-operation bandwidth:

```sh
uv run ansible-playbook test/ansible/blob-workload.yml --limit zettide-tier1
```

Each result reports actual operations per second, bytes per second, average
latency, and p95 latency. Latency samples cover one submitted batch; the
Batch-depth-one cases sample one operation. The batch-32 case samples one
32-operation request. POSIX uses one vectored syscall; io_uring submits up to
32 independent SQEs. Ring inflight does not imply the storage device executes
the same physical queue depth.
Write latency and IOPS measure accepted writes; durable throughput and IOPS
include the final data sync. `operation_transport_*` fields snapshot the data
path before that final sync.

Use `blob-store.yml` with the same targets to include immutable blob framing,
CRC32C, allocation, commit, reopen, and verification.
Use `blob-object.yml` to include COW object maps and object-head publication.
