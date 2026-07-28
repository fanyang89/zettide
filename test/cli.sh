#!/usr/bin/env bash
set -euo pipefail

exe=$1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zettide-cli.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

image="$tmp/image with spaces.ddv"
"$exe" create "$image" --size 1MiB --label "CLI Test"
info=$("$exe" info "$image")
[[ "$info" == *"Label: CLI Test"* ]]
[[ "$info" == *"Capacity: 1.00MiB"* ]]
[[ "$info" == *"Encrypted: no"* ]]
"$exe" check "$image" | grep -q '^Filesystem traversal succeeded:'

default_image="$tmp/default-label.ddv"
"$exe" create "$default_image" --size 1MiB >/dev/null
"$exe" info "$default_image" | grep -q '^Label: Zettide$'

if "$exe" create "$image" --size 1MiB >/dev/null 2>&1; then
    echo "duplicate create unexpectedly succeeded" >&2
    exit 1
fi
if "$exe" create "$tmp/bad.ddv" --size nonsense >/dev/null 2>&1; then
    echo "invalid size unexpectedly succeeded" >&2
    exit 1
fi
if "$exe" create "$tmp/missing.ddv" >/dev/null 2>&1; then
    echo "missing size unexpectedly succeeded" >&2
    exit 1
fi

if [[ "$(uname -s)" == "Linux" ]]; then
    if "$exe" device inspect /dev/null >/dev/null 2>&1; then
        echo "character device unexpectedly passed inspection" >&2
        exit 1
    fi
fi

cp "$image" "$tmp/corrupt.ddv"
printf X | dd of="$tmp/corrupt.ddv" bs=1 seek=0 conv=notrunc status=none
printf Y | dd of="$tmp/corrupt.ddv" bs=1 seek=4096 conv=notrunc status=none
if "$exe" check "$tmp/corrupt.ddv" >/dev/null 2>&1; then
    echo "corrupt container unexpectedly passed check" >&2
    exit 1
fi
