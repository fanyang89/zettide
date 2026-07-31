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
target_pid=
cleanup() {
	if [[ -n $target_pid ]] && kill -0 "$target_pid" 2>/dev/null; then
		kill "$target_pid"
		wait "$target_pid" || true
	fi
	rm -rf "$build_dir"
}
trap cleanup EXIT

packages=(
	spdk_event
	spdk_event_bdev
	spdk_vhost
	spdk_event_nvmf
	spdk_bdev_modules
	spdk_env_dpdk
	spdk_nvmf
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
spdk_source=
for flag in $(pkg-config --cflags-only-I spdk_bdev_modules); do
	include=${flag#-I}
	case $include in
		*/build/include) spdk_source=${include%/build/include} ;;
	esac
done
if [[ -z $spdk_source ]]; then
	printf '%s\n' "SPDK source directory was not found" >&2
	exit 1
fi

# shellcheck disable=SC2046
"${CC:-cc}" -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -Wno-unused-parameter -Isrc -Itest \
	src/spdk/runtime.c test/spdk_runtime.c test/spdk_nvmf_target.c \
	-o "$build_dir/zettide-spdk-nvmf-target" -pthread \
	-Wl,--no-as-needed \
	$(pkg-config --cflags --libs "${packages[@]}") \
	-Wl,--as-needed

# shellcheck disable=SC2046
"${CC:-cc}" -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -Wno-unused-parameter -Isrc -Itest \
	-I"$spdk_source/module/bdev/nvme" \
	src/spdk/runtime.c src/spdk/nvme_controller.c src/spdk/bdev_endpoint.c \
	src/spdk/bdev_dispatcher.c test/spdk_runtime.c \
	test/spdk_storage_main.c "$1" -o "$build_dir/zettide-spdk-storage-test" -pthread -lubsan \
	-Wl,--no-as-needed \
	$(pkg-config --cflags --libs "${packages[@]}") \
	-Wl,--as-needed

ready_file="$build_dir/target-ready"
LD_LIBRARY_PATH="${library_path}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	"$build_dir/zettide-spdk-nvmf-target" "$ready_file" &
target_pid=$!
for ((attempt = 0; attempt < 1000; attempt++)); do
	if [[ -f $ready_file ]]; then
		break
	fi
	if ! kill -0 "$target_pid" 2>/dev/null; then
		wait "$target_pid"
		exit 1
	fi
	sleep 0.01
done
if [[ ! -f $ready_file ]]; then
	printf '%s\n' "NVMe-oF test target did not become ready" >&2
	exit 1
fi
LD_LIBRARY_PATH="${library_path}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	timeout 60 "$build_dir/zettide-spdk-storage-test"
