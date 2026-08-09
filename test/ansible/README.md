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

## Blob FUSE fio

The Blob FUSE fio profile benchmarks only a regular-file BlobFilesystem image.
It never reads raw devices or Pool configuration. Configure one or more explicit
targets; there is no `/tmp` fallback:

```ini
[zettide_test]
zettide-pm883 ansible_host=192.0.2.20 ansible_user=tester

[zettide_test:vars]
zettide_blob_fuse_targets=[{"name":"pm883","tmpdir":"/mnt/pm883"}]
```

Run the ReleaseSafe profile for the PM883-style target:

```sh
uv run ansible-playbook test/ansible/blob-fuse-fio.yml --limit zettide-pm883
```

Each target must be an existing writable absolute directory other than `/`,
with at least 32 GiB free. A host-wide lock protects a unique temporary work
directory under that target. The profile creates a 32 GiB sparse regular-file
backing image and one 256 MiB test file, then runs one-job `io_uring` direct-I/O
cases for 1 MiB sequential QD32 and 4 KiB random QD1/QD32 reads and writes. Each
measured case runs for eight seconds after a two-second ramp and uses a fresh
clean mount without recreating the image. Result archives contain fio JSON,
per-case mount logs with `fuse_metrics`, and the final `zettide check` output.
Read cases run before write cases so read baselines survive later COW pressure.
FUSE metrics include I/O performed during the fio ramp. Faster writes can exhaust
the shared 32 GiB COW image; ENOSPC fails the profile explicitly. Increase
`zettide_blob_fuse_fio_backing_size` when needed. The file size, runtime, ramp,
and async timeout are also configurable with `zettide_blob_fuse_fio_file_size`,
`zettide_blob_fuse_fio_runtime`, `zettide_blob_fuse_fio_ramp_time`, and
`zettide_blob_fuse_fio_timeout` in inventory or with `-e`.

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

Set `-e zettide_raw_restore_original=false` to retain the successfully tested
Zettide Pool on the physical disk instead of restoring the original image. Test
failures still restore the original disk. A successful retained-Pool run keeps
the original image in the configured backup directory regardless of
`zettide_raw_keep_backup`.

Set `-e zettide_raw_fuse_fio=true` to create the physical Pool first and run
fio through its Zettide FUSE mount. This bypasses the original host filesystem
while retaining the complete Zettide Pool, LittleFS, and FUSE path. The workload
uses `io_uring` with direct I/O and covers 1 MiB sequential QD32 plus 4 KiB random
QD1, QD32, and four jobs at QD32. It uses one 2 GiB file and four 512 MiB files.
The Pool is cleanly reopened between write and read phases. Override the
`zettide_raw_fuse_fio_*` variables to change sizes or timings.

To rerun the same fio matrix against a retained Pool without backing up, wiping,
or recreating the device, add its 32-digit hexadecimal `pool_id` to
`zettide_raw_device` and run:

```sh
uv run ansible-playbook test/ansible/pool-fio.yml --limit zettide-tier1
```

The profile verifies the whole-disk serial number and Pool ID, creates missing
workload files, and mounts the Pool separately for every fio case. Each measured
mount uses `--metrics`, so its archived log contains workload-specific FUSE,
pipeline, and member transport metrics. It does not modify partition tables or
restore the original device image.

To benchmark a temporary native Blob Pool on the same physical disk while
preserving the retained LittleFS Pool, run:

```sh
uv run ansible-playbook test/ansible/blob-pool-fio.yml --limit zettide-tier1 \
  -e 'zettide_blob_pool_fio_confirm=DESTROY:/dev/nvme1n1:PHYSICAL-DISK-SERIAL'
```

This profile requires the configured raw device to contain the expected
mountable LittleFS Pool with no mounted descendants or open holders. It creates
and byte-compares a sparse full-device backup on another filesystem, replaces
the disk with an unprotected native Blob Pool, runs the physical Pool fio matrix,
then restores and byte-compares the original image. A final read-only inspection
must recover the original Pool ID and mountability. The backup is retained by
default; a power loss or `SIGKILL` can still require manual restoration.

Set `zettide_blob_pool_fio_backup_original=false` in inventory for a dedicated
test disk. The profile then skips the original Pool checks, full-device backup,
and restoration, and leaves the tested Blob Pool on the device. Serial matching,
idle-device checks, and the explicit destructive confirmation remain required.

Use the NFSv3 frontend with the same physical Blob Pool and fio matrix:

```sh
uv run ansible-playbook test/ansible/blob-pool-nfs-fio.yml --limit zettide-tier1 \
  -e 'zettide_blob_pool_fio_confirm=DESTROY:/dev/nvme1n1:PHYSICAL-DISK-SERIAL'
```

The profile builds the pinned NFS-Ganesha V13 source and `FSAL_ZETTIDE`, then
mounts each fio case through the loopback Linux NFSv3 client with 1 MiB read and
write request sizes. It does not run FUSE during the measured workload. Override
`zettide_nfs_stable_write_batch_us` to test a different stable-write batching
window; the default is 20000 microseconds and drained batches sync early.

Set `zettide_nfs_perf_case` to one fio case name to attach `perf record` to
NFS-Ganesha for that case. The archive includes `perf-<case>.data` plus self and
inclusive text reports. `zettide_nfs_perf_frequency` defaults to 199 Hz.
Use `zettide_nfs_rpc_ioq_thrd_min` and `zettide_nfs_rpc_ioq_thrd_max` to tune
the NTIRPC work pool; their defaults are 2 and 16 to bound scheduling overhead.

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

## NVMe-oF/TCP fio

The NVMe-oF profile builds the pinned `third_party/spdk` source on the remote
host, exports a 64 GiB memory-backed provider bdev over loopback TCP, connects
it through the Linux kernel NVMe/TCP initiator, and runs read-only fio cases.
It measures the provider, SPDK NVMe-oF, and kernel initiator ceiling rather
than Catalog volume or physical media performance.

```sh
uv run ansible-playbook test/ansible/nvmf-fio.yml --limit zettide-tier1
```

Override the measured and ramp durations with `zettide_nvmf_fio_runtime` and
`zettide_nvmf_fio_ramp_time`. JSON fio output, target logs, and NVMe topology
are stored in the fetched result archive.

The Catalog profile uses the same cases and export identity, but reads a real
64 GiB thin Catalog Volume from an 8 MiB temporary file-backed Pool. Unmapped
extents read as zero, so this isolates Catalog lookup, worker scheduling, and
provider overhead without accessing a physical device:

```sh
uv run ansible-playbook test/ansible/nvmf-catalog-fio.yml --limit zettide-tier1
```

The mapped profile initializes and maps a 1 GiB window from a temporary
file-backed member, then confines each fio job to a disjoint 256 MiB range.
Reads include extent translation and file-storage I/O without using a raw
block device:

```sh
uv run ansible-playbook test/ansible/nvmf-catalog-mapped-fio.yml --limit zettide-tier1
```

The Optane profile is destructive. It verifies the configured old Pool ID and
device serial, reformats the device as a Catalog-capable Pool, creates a
`benchmark` thin Volume, and initializes and maps a 1 GiB window. fio remains
read-only, but the old Pool cannot be recovered without its backup:

```sh
uv run ansible-playbook test/ansible/nvmf-catalog-optane-fio.yml --limit zettide-tier1
```

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
