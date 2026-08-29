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
	printf '%s\n' "usage: $0 ZIG_TEST_LIBRARY" >&2
	exit 2
fi

build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
socket_dir="$build_dir/sockets"
mkdir "$socket_dir"

packages=(
	spdk_event
	spdk_event_bdev
	spdk_event_nvmf
	spdk_event_vhost_blk
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

# SPDK modules register through constructors and must not be dropped as unused.
# shellcheck disable=SC2046
"${CC:-cc}" -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -Wno-unused-parameter -Iservices/data-node \
	services/data-node/spdk/runtime.c services/data-node/spdk/vhost_blk_controller.c tests/spdk_vhost_blk_controller.c \
	-o "$build_dir/zettide-spdk-vhost-blk-controller-test" -pthread \
	-Wl,--no-as-needed \
	$(pkg-config --cflags --libs "${packages[@]}") \
	-Wl,--as-needed
LD_LIBRARY_PATH="${library_path}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	timeout 30 "$build_dir/zettide-spdk-vhost-blk-controller-test" "$socket_dir"

# shellcheck disable=SC2046
"${CC:-cc}" -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -Wno-unused-parameter -Iservices/data-node \
	services/data-node/spdk/runtime.c services/data-node/spdk/bdev_provider.c services/data-node/spdk/nvmf_tcp_export.c \
	services/data-node/spdk/vhost_blk_controller.c \
	tests/spdk_vhost_export_main.c "$1" \
	-o "$build_dir/zettide-spdk-vhost-export-test" -pthread -lubsan -lstdc++ \
	-Wl,--no-as-needed \
	$(pkg-config --cflags --libs "${packages[@]}") \
	-Wl,--as-needed
LD_LIBRARY_PATH="${library_path}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	timeout 30 "$build_dir/zettide-spdk-vhost-export-test" "$socket_dir"
