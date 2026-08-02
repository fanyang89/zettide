#!/usr/bin/env bash
set -euo pipefail

exe=$1
pty_passphrase_exec=${2:-}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zettide-cli.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

image="$tmp/image with spaces.ddv"
"$exe" create "$image" --size 1MiB --label "CLI Test"
info=$("$exe" info "$image")
[[ "$info" == *"Label: CLI Test"* ]]
[[ "$info" == *"Capacity: 1.00MiB"* ]]
[[ "$info" == *"Name profile: legacy-raw"* ]]
[[ "$info" == *"Encrypted: no"* ]]
"$exe" check "$image" | grep -q '^Filesystem traversal succeeded:'

default_image="$tmp/default-label.ddv"
"$exe" create "$default_image" --size 1MiB >/dev/null
"$exe" info "$default_image" | grep -q '^Label: Zettide$'

portable_image="$tmp/portable.ddv"
"$exe" create "$portable_image" --size 1MiB --name-profile portable-v1 >/dev/null
"$exe" info "$portable_image" | grep -q '^Name profile: portable-v1$'

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
if "$exe" create "$tmp/unknown-profile.ddv" --size 1MiB --name-profile unknown >/dev/null 2>&1; then
    echo "unknown name profile unexpectedly succeeded" >&2
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
if "$exe" format "$existing" --label "Existing Test" --name-profile portable-v1 --confirm "$token" >/dev/null 2>&1; then
    echo "format accepted a confirmation for another name profile" >&2
    exit 1
fi
"$exe" format "$existing" --label "Existing Test" --confirm "$token"
"$exe" info "$existing" | grep -q '^Label: Existing Test$'

portable_formatted="$tmp/portable-formatted.ddv"
"$exe" format "$portable_formatted" --size 8MiB --name-profile portable-v1 >/dev/null
"$exe" info "$portable_formatted" | grep -q '^Name profile: portable-v1$'

portable_existing="$tmp/portable-existing.ddv"
truncate -s 8MiB "$portable_existing"
portable_plan=$("$exe" format "$portable_existing" --name-profile portable-v1)
portable_token=$(printf '%s\n' "$portable_plan" | grep '^Confirm token: ' | cut -d' ' -f3)
"$exe" format "$portable_existing" --name-profile portable-v1 --confirm "$portable_token" >/dev/null
"$exe" info "$portable_existing" | grep -q '^Name profile: portable-v1$'

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

key_file="$tmp/workspace.key"
"$exe" key generate "$key_file" >/dev/null
[[ $(wc -c <"$key_file") -eq 32 ]]
if [[ $(uname -s) == Linux ]]; then
    [[ $(stat -c '%a' "$key_file") == 600 ]]
fi
if "$exe" key generate "$key_file" >/dev/null 2>&1; then
    echo "key generation replaced an existing file" >&2
    exit 1
fi

short_key="$tmp/short.key"
printf short >"$short_key"
chmod 600 "$short_key"
if "$exe" format "$tmp/short-key.ddv" --size 8MiB --encrypt --key-file "$short_key" >/dev/null 2>&1; then
    echo "format accepted a short key file" >&2
    exit 1
fi
insecure_key="$tmp/insecure.key"
cp "$key_file" "$insecure_key"
chmod 644 "$insecure_key"
if "$exe" format "$tmp/insecure-key.ddv" --size 8MiB --encrypt --key-file "$insecure_key" >/dev/null 2>&1; then
    echo "format accepted an insecure key file" >&2
    exit 1
fi
key_link="$tmp/key-link"
ln -s "$key_file" "$key_link"
if "$exe" format "$tmp/symlink-key.ddv" --size 8MiB --encrypt --key-file "$key_link" >/dev/null 2>&1; then
    echo "format accepted a symlink key file" >&2
    exit 1
fi
if [[ $(uname -s) == Linux ]]; then
    key_fifo="$tmp/key-fifo"
    mkfifo "$key_fifo"
    set +e
    timeout 5s "$exe" format "$tmp/fifo-key.ddv" --size 8MiB --encrypt --key-file "$key_fifo" >/dev/null 2>&1
    fifo_status=$?
    set -e
    if [[ $fifo_status -eq 0 || $fifo_status -eq 124 ]]; then
        echo "format did not promptly reject a FIFO key file" >&2
        exit 1
    fi
fi
if "$exe" format "$tmp/missing-credential.ddv" --size 8MiB --encrypt >/dev/null 2>&1; then
    echo "encrypted format accepted no credential" >&2
    exit 1
fi
if "$exe" format "$tmp/missing-encrypt.ddv" --size 8MiB --key-file "$key_file" >/dev/null 2>&1; then
    echo "format accepted a key without --encrypt" >&2
    exit 1
fi

encrypted="$tmp/encrypted.ddv"
"$exe" format "$encrypted" --size 8MiB --label "Encrypted Test" --encrypt --key-file "$key_file" >/dev/null
encrypted_info=$("$exe" info "$encrypted")
[[ "$encrypted_info" == *"Label: Encrypted Test"* ]]
[[ "$encrypted_info" == *"Encrypted: yes"* ]]
if "$exe" check "$encrypted" >/dev/null 2>&1; then
    echo "check unexpectedly unlocked an encrypted target" >&2
    exit 1
fi

if [[ $(uname -s) == Linux && -x "$pty_passphrase_exec" ]]; then
    passphrase_image="$tmp/passphrase.ddv"
    "$pty_passphrase_exec" 2 "test passphrase" "test passphrase" -- \
        "$exe" format "$passphrase_image" --size 8MiB --encrypt --passphrase >/dev/null
    "$exe" info "$passphrase_image" | grep -q '^Encrypted: yes$'
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
