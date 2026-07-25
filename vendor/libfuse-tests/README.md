# libfuse syscall tests

`test_syscalls.c` is vendored from libfuse commit
`b45649f5195414f8a038f10ff85034e3c27ebc36`.

The test is distributed under GPL-2.0. See `LICENSE` and `GPL2.txt`.

The vendored source computes the symlink target length after `start_test()` so
the upstream single-test selector handles numbered test paths correctly.
