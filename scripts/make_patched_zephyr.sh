#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Make a COPY of the workspace's zephyr/ tree with patches/zephyr/*.patch
# applied, to test the proposed fork patches without touching zephyr/.
#
# Usage: scripts/make_patched_zephyr.sh [OUT_DIR]   (default: ../build/zephyr-patched)
# Then e.g.: ZEPHYR_BASE=<OUT_DIR> west build ...
#        or: PATCHED_ZEPHYR=<OUT_DIR> the bench bundle builder (outside this repo)
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
