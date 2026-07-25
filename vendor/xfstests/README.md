# xfstests fsx

`ltp/fsx.c`, `src/global.h`, and `src/statx.h` are vendored from xfstests
commit `acb6d4cb84205a8e3f19ca470cfcf7bf6d93a509`.

These files are distributed under GPL-2.0. See `LICENSES/GPL-2.0`.

The vendored `fsx.c` includes two build-compatibility changes: an explicit
`getopt.h` include and an unsigned range-distance expression accepted by Clang.
