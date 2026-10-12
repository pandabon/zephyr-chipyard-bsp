#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copy the workspace's zephyr/ tree and apply patches/zephyr/*.patch to the copy.
#
# Usage: scripts/make_patched_zephyr.sh [OUT_DIR]   (default: ../build/zephyr-patched)
# Then: ZEPHYR_BASE=<OUT_DIR> west build ...
#   or: PATCHED_ZEPHYR=<OUT_DIR> scripts/make_bench_bundle.sh
set -euo pipefail

BSP="$(cd "$(dirname "$0")/.." && pwd)"
WS="$(cd "$BSP/.." && pwd)"
OUT="${1:-$WS/build/zephyr-patched}"

rm -rf "$OUT" && mkdir -p "$OUT"
tar -C "$WS/zephyr" --exclude=.git -cf - . | tar -C "$OUT" -xf -
for p in "$BSP"/patches/zephyr/*.patch; do
  echo "applying $(basename "$p")"
  patch -d "$OUT" -p1 -s < "$p"
done
echo "patched copy: $OUT  (base $(git -C "$WS/zephyr" rev-parse --short HEAD))"
