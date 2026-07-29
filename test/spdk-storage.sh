#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Linux ]]; then
	printf '%s\n' "SPDK is only supported on Linux" >&2
	exit 1
fi
if [[ -z ${PKG_CONFIG_PATH:-} ]]; then
	printf '%s\n' "PKG_CONFIG_PATH must reference an SPDK build" >&2
	exit 1
fi
if [[ $# -ne 1 ]]; then
	printf 'usage: %s TEST_LIBRARY\n' "$0" >&2
	exit 1
fi

build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT

packages=(
	spdk_event
	spdk_event_bdev
	spdk_bdev_modules
	spdk_env_dpdk
	spdk_sock_modules
	spdk_syslibs
)
pkg-config --exists "${packages[@]}"

library_path=
for flag in $(pkg-config --libs-only-L "${packages[@]}"); do
	path=${flag#-L}
	library_path=${library_path:+$library_path:}$path
done

# SPDK and DPDK modules register through constructors and must not be dropped.
# shellcheck disable=SC2046
"${CC:-cc}" -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -Wno-unused-parameter -Isrc -Itest \
	src/spdk/runtime.c src/spdk/bdev_endpoint.c src/spdk/bdev_dispatcher.c test/spdk_runtime.c \
	test/spdk_storage_main.c "$1" -o "$build_dir/zettide-spdk-storage-test" -pthread -lubsan \
	-Wl,--no-as-needed \
	$(pkg-config --cflags --libs "${packages[@]}") \
	-Wl,--as-needed
LD_LIBRARY_PATH="${library_path}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	timeout 60 "$build_dir/zettide-spdk-storage-test"
