# POSIX Nightly Gates

## Suite Pins

`test/external/suites.tsv` is the machine-readable source of truth. The current
pins are:

- pjdfstest `ededbeb2b44929972898afb87474b0937f78a877`
- xfstests `acb6d4cb84205a8e3f19ca470cfcf7bf6d93a509`
- LTP `6a60ae592cd375f004df0694efc7d50ddae9aa5e` (tag `20260130`)

The existing minimal xfstests fsx snapshot remains pinned to
`acb6d4cb84205a8e3f19ca470cfcf7bf6d93a509` under `vendor/`.

## Preparation

The upstream suites are too large for minimal source snapshots. Fetch and build
them explicitly:

```sh
bash test/external/prepare.sh
```

The script initializes one checkout per suite under
`test/external/.prepared/`, fetches only the explicit commit, checks detached
HEAD, and builds the required tools. Set `DEVDRIVE_PREPARE_JOBS` to control
parallel builds or pass another destination as the first argument. Set
`DEVDRIVE_EXTERNAL_ROOT` to that destination when running tests.

This is the only step that accesses the network. Test runners verify each local
HEAD against the pin and never invoke package managers, Git fetch, or other
network clients.

Required build tools include a C compiler, Git, Make, Autoconf, Automake, Perl
TAP Harness, and the xfstests development dependencies. Runtime tools include
FUSE3, `findmnt`, `mountpoint`, `runuser`, `timeout`, and `xfs_io`.

## Manifests

The selected cases are listed in:

- `test/external/pjdfstest-cases.tsv`
- `test/external/xfstests-cases.tsv`
- `test/external/ltp-open-posix-cases.tsv`

Every row has a classification, exact case ID, contract, and reason. The only
valid classifications are `required` and `not-applicable`. Required skips fail;
not-applicable rows explain specific cases and are not executed. Wildcards and
comma-separated or group-wide exclusions are rejected by the runner.

## Execution

```sh
zig build test-posix-privileged -Dprivileged-tests=required
zig build test-xfstests -Dexternal-tests=required
zig build test-ltp-open-posix -Dexternal-tests=required
zig build -j1 test-posix-nightly \
  -Dfuse-tests=required -Dexternal-tests=required -Dprivileged-tests=required
```

Modes are `off`, `auto`, and `required`. Privileged runners re-exec themselves
through passwordless `sudo -n` when necessary; they never prompt. They first
verify identity switching on the host, then run against an isolated DevDrive
image. An EXIT trap attempts a normal unmount, bounded wait, lazy detach, and
process termination in that order.

The aggregate nightly target uses `-j1` because xfstests identifies its test
filesystem by mount source and must not overlap another DevDrive mount.

Set `DEVDRIVE_TEST_LOG_DIR` to retain suite, mount, and xfstests result logs.
Set `DEVDRIVE_KEEP_TEST_ARTIFACTS=1` to retain a failed runner's temporary image
and mount log. Retained images can contain test-created ownership and mode data.

The nightly workflow is scheduled and manually dispatchable. It prepares the
pinned sources before invoking required mode and uploads logs even when the gate
fails.
