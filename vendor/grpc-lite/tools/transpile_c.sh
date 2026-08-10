#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_dir="$project_root/transpiled"

rm -rf "$output_dir"
zig build transpile-c \
    -Dtranspile-c=true \
    -Dprotobuf=false \
    -Doptimize=ReleaseSafe \
    --prefix "$output_dir" \
    --summary all

# Zig's x86 clone assembly uses LLVM-style comments, which GNU as rejects.
perl -pi -e 's{// SYS_}{# SYS_}g' "$output_dir/src/protoc-gen-grpc_lite_cpp.c"
