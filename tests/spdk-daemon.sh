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
    printf 'usage: %s ZETTIDE_EXECUTABLE\n' "$0" >&2
    exit 2
fi

packages=(
    spdk_event
    spdk_event_bdev
    spdk_event_vhost_blk
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

build_dir=$(mktemp -d)
runtime_dir="$build_dir/runtime"
mkdir "$runtime_dir"
chmod 700 "$runtime_dir"
daemon_pid=
dump_log() {
    command cat "$build_dir/daemon.log" >&2
}
cleanup() {
    if [[ -n $daemon_pid ]] && kill -0 "$daemon_pid" 2>/dev/null; then
        kill -TERM "$daemon_pid"
        wait "$daemon_pid" || true
    fi
    rm -rf "$build_dir"
}
trap cleanup EXIT

LD_LIBRARY_PATH="${library_path}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$1" endpoint serve --runtime-dir "$runtime_dir" >"$build_dir/daemon.log" 2>&1 &
daemon_pid=$!
for ((attempt = 0; attempt < 1000; attempt++)); do
    if [[ -S $runtime_dir/control.sock ]]; then
        break
    fi
    if ! kill -0 "$daemon_pid" 2>/dev/null; then
        wait "$daemon_pid" || true
        dump_log
        exit 1
    fi
    sleep 0.01
done
if [[ ! -S $runtime_dir/control.sock ]]; then
    printf '%s\n' "endpoint daemon did not become ready" >&2
    dump_log
    exit 1
fi

kill -TERM "$daemon_pid"
wait "$daemon_pid"
daemon_pid=
[[ ! -e $runtime_dir/control.sock ]]
[[ -f $runtime_dir/control.sock.lock ]]
