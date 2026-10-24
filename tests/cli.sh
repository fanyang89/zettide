#!/usr/bin/env bash
set -euo pipefail

exe=$1
tmp_root=${TMPDIR:-$HOME/tmp}/opencode
mkdir -p "$tmp_root"
tmp=$(mktemp -d "$tmp_root/zettide-cli.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

help=$("$exe" --help)
[[ "$help" == *"zettide pool plan-create"* ]]
[[ "$help" == *"Catalog data mode"* ]]
if grep -Eq 'zettide (format|info|check|mount|unmount|serve)|pool mount|name-profile|scheduled-replicated' <<<"$help"; then
    echo "help advertises a retired filesystem operation" >&2
    exit 1
fi

# Removed commands must fail without touching an existing image or creating paths.
image="$tmp/image with spaces.blob"
printf 'BLOB: legacy data must survive rejected commands\n' >"$image"
cp "$image" "$tmp/expected"
for command in format info check mount unmount serve; do
    if "$exe" "$command" "$image" >"$tmp/out" 2>"$tmp/err"; then
        echo "retired command unexpectedly succeeded: $command" >&2
        exit 1
    fi
    grep -q '^error: InvalidCommand$' "$tmp/err"
    cmp "$image" "$tmp/expected"
done

if [[ $(uname -s) == Linux ]]; then
    expect_error() {
        local expected=$1
        shift
        if "$exe" "$@" >"$tmp/out" 2>"$tmp/err"; then
            echo "invalid block command unexpectedly succeeded: $*" >&2
            exit 1
        fi
        grep -qx "error: $expected" "$tmp/err"
    }
    expect_error InvalidArguments pool mount "$image"
    expect_error UnknownOption pool plan-create --device "$image" --name-profile portable-v1
    expect_error UnknownOption pool plan-create --device "$image" --filesystem blob
    expect_error InvalidProfile pool plan-create --device "$image" --profile scheduled-replicated
    expect_error MissingConfirmation pool create --device "$image" --profile unprotected
    expect_error DuplicateOption pool create --device "$image" --confirm first --confirm second
    expect_error UnknownOption pool plan-create --device "$image" --confirm invalid
    expect_error InvalidMemberCount pool plan-create
    expect_error UnsupportedPoolWidth pool plan-create --device "$image" --profile replicated
    expect_error UnsupportedPoolWidth pool plan-create --device "$image" --device "$image" --profile unprotected
    expect_error MissingOptionValue pool plan-create --device
    if "$exe" endpoint serve >"$tmp/out" 2>"$tmp/err"; then
        echo "endpoint serve accepted missing runtime configuration" >&2
        exit 1
    fi
    grep -Eq '^error: (SpdkSupportNotEnabled|MissingRuntimeDirectory)$' "$tmp/err"
    cmp "$image" "$tmp/expected"
fi
