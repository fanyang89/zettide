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

formatted="$tmp/formatted.ddv"
"$exe" format "$formatted" --size 8MiB --label "Format Test"
"$exe" info "$formatted" | grep -q '^Label: Format Test$'
"$exe" check "$formatted" | grep -q '^Filesystem traversal succeeded:'

existing="$tmp/existing.ddv"
truncate -s 8MiB "$existing"
plan=$("$exe" format "$existing" --label "Existing Test")
[[ "$plan" == *"Type: regular_file"* ]]
[[ "$plan" == *"Contains data: no"* ]]
token=$(printf '%s\n' "$plan" | grep '^Confirm token: ' | cut -d' ' -f3)
"$exe" format "$existing" --label "Existing Test" --confirm "$token"
"$exe" info "$existing" | grep -q '^Label: Existing Test$'

changed="$tmp/changed.ddv"
truncate -s 8MiB "$changed"
printf first | dd of="$changed" conv=notrunc status=none
changed_plan=$("$exe" format "$changed")
changed_token=$(printf '%s\n' "$changed_plan" | grep '^Confirm token: ' | cut -d' ' -f3)
printf second | dd of="$changed" conv=notrunc status=none
if "$exe" format "$changed" --confirm "$changed_token" >/dev/null 2>&1; then
    echo "changed target unexpectedly accepted stale confirmation" >&2
    exit 1
fi

if "$exe" format "$tmp/unaligned.ddv" --size 7340033 >/dev/null 2>&1; then
    echo "unaligned format size unexpectedly succeeded" >&2
    exit 1
fi
if "$exe" format "$formatted" --size 8MiB >/dev/null 2>&1; then
    echo "existing format target unexpectedly accepted --size" >&2
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
