#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/grpc-lite-cmake-c-consumer.XXXXXX")
package_source="$work_dir/package"
consumer_source="$work_dir/consumer"
cleanup() {
    local status=$?
    if [[ -n "${GRPC_LITE_KEEP_E2E:-}" ]]; then
        printf 'Kept CMake C consumer work directory: %s\n' "$work_dir" >&2
    else
        rm -rf "$work_dir"
    fi
    return "$status"
}
trap cleanup EXIT

mkdir -p "$package_source" "$consumer_source"
git -C "$project_root" archive HEAD | tar -x -C "$package_source"
git -C "$project_root" diff --binary HEAD >"$work_dir/worktree.patch"
if [[ -s "$work_dir/worktree.patch" ]]; then
    git -C "$package_source" apply --whitespace=nowarn "$work_dir/worktree.patch"
fi
while IFS= read -r -d '' path; do
    mkdir -p "$package_source/$(dirname "$path")"
    cp -a "$project_root/$path" "$package_source/$path"
done < <(git -C "$project_root" ls-files --others --exclude-standard -z)
cp -R "$package_source/tests/consumer/cmake_c/." "$consumer_source/"

cmake \
    -S "$consumer_source" \
    -B "$work_dir/build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DGRPC_LITE_SOURCE_DIR="$package_source"
cmake --build "$work_dir/build"
cmake --build "$work_dir/build" --target grpc_lite_protoc_gen
ctest --test-dir "$work_dir/build" --output-on-failure
