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
`test-results/ansible/HOST.tar.gz`, including command output and external suite
logs. The remote temporary workspace is removed after log collection unless
`-e zettide_keep_remote_workspace=true` is set.
