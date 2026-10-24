# Remote block tests

The Ansible suite stages the current working tree on Fedora or Ubuntu hosts,
runs Debug and ReleaseSafe block checks, and fetches result archives. It does
not implement or validate a cluster, filesystem service, or managed VM lifecycle.

## Prerequisites

- SSH access, Python 3, and privilege escalation through `sudo`.
- Zig 0.17.0 in the remote `PATH`, or configured as `zettide_zig`.
- OS package access; loop devices for the default block gate.
- SPDK profiles additionally require the initialized `vendor/spdk` source and
  the appropriate kernel transports. No FUSE or POSIX conformance suite is needed.

## Run

From `tests/automation/`, use the existing environment:

```sh
uv sync --locked
cp inventory.example.ini inventory.ini
uv run ansible-playbook playbook.yml --limit HOST
```

The default `block` profile runs portable tests, block-format cross-compilation,
and the required Linux loop-device gate. Use SSH configuration, agent forwarding,
or Ansible Vault for credentials, never plaintext inventory secrets.

Results are fetched to `test-results/ansible/HOST-TIMESTAMP-COMMIT.tar.gz`.
The remote workspace is retained if archiving or fetching fails, or when
`-e zettide_keep_remote_workspace=true` is set.

## Retained protocol profiles

| Entry point | Purpose |
| --- | --- |
| `nvmf-fio.yml` | Standard NVMe/TCP target baseline |
| `nvmf-catalog-fio.yml` | Catalog Volume export |
| `nvmf-catalog-mapped-fio.yml` | Mapped Catalog data path |
| `nvmf-catalog-rxe-fio.yml` | Transitional Catalog RDMA adapter |
| `nvmf-catalog-optane-fio.yml` | Explicitly configured physical Catalog Pool |
| `iscsi-catalog-fio.yml` | Transitional Catalog iSCSI adapter |

NVMe/TCP is the primary product direction. Additional protocol profiles remain
component validation only, not a promise to deliver several parallel products.

**Physical profiles may overwrite disk data or Catalog metadata.** Read the
selected task and script, use disposable devices, and satisfy their exact
path/serial/Pool identity guards. The default profile uses temporary loop backing
files, not physical disks. Do not run hardware profiles implicitly.

Filesystem, CSI, shared-file benchmarks, destructive Blob Pool lifecycle tests,
and scheduled raw Blob Pool performance harnesses have been removed. Their
former profile names are rejected before staging or package installation.
