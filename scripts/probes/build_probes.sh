#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the TSI link-probe ELFs from probe.S with the Zephyr SDK binutils.
#   scripts/probes/build_probes.sh <out-dir> [clint|spad|dram ...]   (default: all three)
# Needs riscv64-zephyr-elf-as/ld on PATH. Used by make_bench_bundle.sh and by the uart_tsi
# runner's --check, which builds the DRAM probe at flash time. See probe.S.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?out dir}"; shift
AS="${AS:-riscv64-zephyr-elf-as}"; LD="${LD:-riscv64-zephyr-elf-ld}"
command -v "$AS" >/dev/null && command -v "$LD" >/dev/null \
  || { echo "build_probes.sh: $AS/$LD not on PATH (source env.sh)" >&2; exit 2; }
mkdir -p "$OUT"
# name  address     words  what
#  clint 0x2004000  2  hart-0 mtimecmp (on-chip, no DRAM)
#  spad  0x8000000  4  MBUS scratchpad (on-chip SRAM)
#  dram  0x80001000 4  DDR via the FPGA memory controller
build() { # name addr words
  "$AS" -march=rv64g --defsym WORDS="$3" -o "$OUT/$1.o" "$HERE/probe.S"
  "$LD" -N -nostdlib -e 0 --section-start=.data="$2" -o "$OUT/$1.elf" "$OUT/$1.o"
  rm -f "$OUT/$1.o"
}
[ $# -gt 0 ] || set -- clint spad dram
for p in "$@"; do
  case $p in
    clint) build clint 0x2004000 2 ;;
    spad)  build spad  0x8000000 4 ;;
    dram)  build dram  0x80001000 4 ;;
    *) echo "unknown probe $p" >&2; exit 2 ;;
  esac
done
