#!/usr/bin/env bash
set -euo pipefail

exe=$1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zettide-cli.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

image="$tmp/image with spaces.blob"
"$exe" format "$image" --size 8MiB --name-profile portable-v1
info=$("$exe" info "$image")
[[ "$info" == *"Data mode: blob"* ]]
[[ "$info" == *"Capacity: 8.00MiB"* ]]
[[ "$info" == *"Name profile: portable-v1"* ]]
"$exe" check "$image" | grep -q '^Filesystem traversal succeeded:'

default_image="$tmp/default.blob"
"$exe" format "$default_image" --size 8MiB >/dev/null
"$exe" info "$default_image" | grep -q '^Name profile: legacy-raw$'

for removed in \
    "create $tmp/create.blob --size 8MiB" \
    "key generate $tmp/key" \
    "format $tmp/filesystem.blob --filesystem blob --size 8MiB" \
    "format $tmp/label.blob --label old --size 8MiB" \
    "format $tmp/encrypted.blob --encrypt --size 8MiB"; do
    if "$exe" $removed >/dev/null 2>&1; then
        echo "removed product option unexpectedly succeeded: $removed" >&2
        exit 1
    fi
done

if "$exe" format "$image" --size 8MiB >/dev/null 2>&1; then
    echo "existing format target unexpectedly accepted --size" >&2
    exit 1
fi
if "$exe" format "$tmp/bad.blob" --size nonsense >/dev/null 2>&1; then
    echo "invalid size unexpectedly succeeded" >&2
    exit 1
fi
if "$exe" format "$tmp/missing.blob" >/dev/null 2>&1; then
    echo "missing size unexpectedly succeeded" >&2
    exit 1
fi
if "$exe" format /dev/null >/dev/null 2>&1; then
    echo "format accepted a non-regular target" >&2
    exit 1
fi

existing="$tmp/existing.blob"
truncate -s 8MiB "$existing"
plan=$("$exe" format "$existing")
[[ "$plan" == *"Filesystem: blob"* ]]
[[ "$plan" == *"Type: regular_file"* ]]
token=$(grep '^Confirm token: ' <<<"$plan")
token=${token#Confirm token: }
if "$exe" format "$existing" --name-profile portable-v1 --confirm "$token" >/dev/null 2>&1; then
    echo "format accepted a confirmation for another name profile" >&2
    exit 1
fi
"$exe" format "$existing" --confirm "$token" >/dev/null

changed="$tmp/changed.blob"
truncate -s 8MiB "$changed"
printf first | dd of="$changed" conv=notrunc status=none
changed_plan=$("$exe" format "$changed")
changed_token=$(grep '^Confirm token: ' <<<"$changed_plan")
changed_token=${changed_token#Confirm token: }
printf second | dd of="$changed" conv=notrunc status=none
if "$exe" format "$changed" --confirm "$changed_token" >/dev/null 2>&1; then
    echo "changed target accepted stale confirmation" >&2
    exit 1
fi

legacy="$tmp/legacy.ddv"
truncate -s 8MiB "$legacy"
printf 'LFSDRV2\0' | dd of="$legacy" conv=notrunc status=none
printf 'LFSDRV2\0' | dd of="$legacy" bs=1 seek=4096 conv=notrunc status=none
for command in info check format; do
    if "$exe" "$command" "$legacy" >"$tmp/legacy.out" 2>"$tmp/legacy.err"; then
        echo "$command accepted a legacy regular file" >&2
        exit 1
    fi
    grep -q '^error: UnsupportedLegacyFormat$' "$tmp/legacy.err"
done

if [[ $(uname -s) == Linux ]]; then
    if "$exe" pool plan-create --device /dev/null --profile unprotected --filesystem blob >/dev/null 2>&1; then
        echo "pool plan accepted a filesystem selector" >&2
        exit 1
    fi
    if "$exe" pool initialize --device /dev/null --confirm invalid >/dev/null 2>&1; then
        echo "removed pool initialize command succeeded" >&2
        exit 1
    fi
fi
