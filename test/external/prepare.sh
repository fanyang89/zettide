#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
destination=${1:-"$script_dir/.prepared"}
jobs=${DEVDRIVE_PREPARE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')}

command -v git >/dev/null
command -v make >/dev/null
command -v autoreconf >/dev/null
command -v cc >/dev/null
mkdir -p "$destination"

fetch_suite() {
    local name=$1 url=$2 commit=$3
    local checkout="$destination/$name"
    if [[ ! -d "$checkout/.git" ]]; then
        [[ ! -e "$checkout" ]] || { echo "$checkout exists but is not a git checkout" >&2; return 1; }
        git init -q "$checkout"
        git -C "$checkout" remote add origin "$url"
    fi
    local configured_url
    configured_url=$(git -C "$checkout" remote get-url origin)
    [[ "$configured_url" == "$url" ]] || { echo "$checkout origin is $configured_url, expected $url" >&2; return 1; }
    local current=
    current=$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)
    if [[ "$current" != "$commit" ]]; then
        [[ -z $(git -C "$checkout" status --porcelain) ]] || { echo "$checkout has local changes" >&2; return 1; }
        git -C "$checkout" fetch --depth 1 origin "$commit"
        git -C "$checkout" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
    fi
    [[ $(git -C "$checkout" rev-parse HEAD) == "$commit" ]] || { echo "failed to pin $name to $commit" >&2; return 1; }
    printf 'prepared %s at %s\n' "$name" "$commit"
}

while IFS=$'\t' read -r suite url commit license extra; do
    [[ -n "$suite" && ${suite:0:1} != "#" ]] || continue
    [[ -z "$extra" && "$commit" =~ ^[0-9a-f]{40}$ && -n "$license" ]] || { echo "invalid suite pin row: $suite" >&2; exit 1; }
    fetch_suite "$suite" "$url" "$commit"
done <"$script_dir/suites.tsv"

xfstests_patch="$script_dir/xfstests-fuse-devdrive.patch"
if git -C "$destination/xfstests" apply --check "$xfstests_patch"; then
    git -C "$destination/xfstests" apply "$xfstests_patch"
elif ! git -C "$destination/xfstests" apply --reverse --check "$xfstests_patch"; then
    echo "xfstests DevDrive FUSE patch does not apply cleanly" >&2
    exit 1
fi

(
    cd "$destination/pjdfstest"
    autoreconf -ifs
    ./configure
    make -j"$jobs" pjdfstest
)

(
    cd "$destination/xfstests"
    make configure
    ./configure
    make -j"$jobs"
)

ltp_root="$destination/ltp"
ltp_bin="$ltp_root/.devdrive-bin"
mkdir -p "$ltp_bin"
while IFS=$'\t' read -r classification case_name contract reason extra; do
    [[ -n "$classification" && ${classification:0:1} != "#" ]] || continue
    [[ "$classification" == required ]] || continue
    source_file="$ltp_root/testcases/open_posix_testsuite/conformance/interfaces/$case_name.c"
    output_name=${case_name//\//_}
    cc -std=gnu11 -O2 -Wall -Wextra \
        -I"$ltp_root/testcases/open_posix_testsuite/include" \
        "$source_file" -o "$ltp_bin/$output_name"
done <"$script_dir/ltp-open-posix-cases.tsv"

printf 'external suites are ready under %s\n' "$destination"
