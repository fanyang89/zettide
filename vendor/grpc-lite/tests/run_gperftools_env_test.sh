#!/usr/bin/env bash
set -euo pipefail

executable=$1
output_dir=$2
cpu_profile="$output_dir/cpu.prof"
heap_prefix="$output_dir/heap"

rm -f "$cpu_profile" "$heap_prefix".*.heap
CPUPROFILE="$cpu_profile" HEAPPROFILE="$heap_prefix" "$executable"
test -s "$cpu_profile"
compgen -G "$heap_prefix.*.heap" >/dev/null
