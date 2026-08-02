# SMB3 Profile

## Status

The Linux FUSE-to-Samba path is a feasibility gate, not a current product
frontend. Windows WinFsp and macOS macFUSE adapters are not implemented.

The gate exports one privately mounted Zettide target through an isolated Samba
instance. It proves that the existing filesystem can sustain authenticated,
encrypted SMB3 create, write, read, rename, read-only access, unmount, reopen,
and persistence. It does not modify the system Samba configuration.

## Initial Protocol Boundary

- The server accepts SMB 3.0 through SMB 3.1.1. SMB1 and SMB2 are disabled.
- Guest and anonymous access are disabled.
- Signing and encryption are mandatory.
- Authentication uses an existing host account and a Samba passdb. Zettide does
  not store account passwords.
- The exported mount is owned by the only writable `Volume` instance.
- The initial Samba configuration disables extended attributes, Windows ACL
  storage, DOS attribute storage, durable handles, and multichannel.
- Oplocks and level-2 oplocks remain enabled for protocol-cache validation.
- The share root does not follow symbolic links.

The feasibility gate uses a temporary high port so it can run without root and
without conflicting with a host SMB service. A product frontend must bind an
explicit address, detect port 445 conflicts, own its runtime state, and complete
the same checks on the production port before it is reported as available.

## Semantics Not Yet Claimed

The feasibility gate does not claim support for:

- Windows security descriptor or ACL round trips
- extended attributes, alternate data streams, or macOS resource forks
- durable or persistent handles
- SMB continuous availability, multichannel, or SMB Direct
- concurrent local writes while a share has active leases or oplocks
- case-insensitive portable names or Unicode normalization
- cross-platform container-image interoperability

These capabilities require the portable namespace profile and platform mount
adapters described by the Tier 1 roadmap.

## Test Gate

Run the real Linux gate with:

```sh
zig build test-smb3-linux -Dsmb3-tests=required
```

The test requires writable `/dev/fuse`, `fusermount3`, `mountpoint`, `ps`,
Python 3, `setsid`, `smbd`, `smbclient`, `testparm`, and `timeout`. `auto` skips
when a prerequisite is missing; `required` fails.
