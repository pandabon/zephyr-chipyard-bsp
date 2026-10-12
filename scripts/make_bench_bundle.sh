#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build a folder and tarball of prebuilt ELFs for the bench machine, which needs only bash
# and uart_tsi. README-bench.md inside the bundle explains how to use it.
#
#   scripts/make_bench_bundle.sh [OUT_DIR]    (west, the Zephyr SDK and Spike on PATH)
#
#   ./                chip set (board chipyard_penguin/penguin, uart_tsi at 921600 baud, unverified):
#                     hello, hw_probe, timer, RVV, ctx_switch stock vs patched, Atlas smoke
#                     and kernels
#   ./vcu118_ta/      same set for chipyard_penguin/penguin/vcu118_ta (TA's EE290VCU118Config,
#                     UART-TSI at 115200 baud on /dev/ttyUSB1; its bench.sh defaults to 115200)
# Both sets use the same numbering. Every ELF also gets a <name>.fast.elf copy where
# scripts/fastload_elf.py's guards pass, and each set gets probes/{dram,clint,spad}.elf.
#
# Environment:
#   VCU118_TA=0       skip vcu118_ta/ (default: built)
#   VCU118=1          also build vcu118/ for the generic chipyard_penguin/penguin/vcu118
#                     (SD images *.sd.bin and the candidate JTAG config). VCU118_PBUS_MHZ
#                     overrides the assumed 100 MHz bus clock.
#   ATLAS_UPSTREAM=1  also build atlas_upstream/ (and vcu118_ta/atlas_upstream/), one ELF per
#                     test from $TAPEOUT_CHIPYARD/tests: 13 tests x 2 variants. Tests whose
#                     golden headers need python torch are skipped unless torch imports.
#   PATCHED_ZEPHYR=D  Zephyr copy with patches/zephyr/*.patch applied, for the *_patched ELFs.
#                     Default: built by make_patched_zephyr.sh into ../build/zephyr-patched.
#                     PATCHED_ZEPHYR=none skips them.
#   BUNDLE_CMAKE_ARGS='-DZEPHYR_MODULES=...'   passed to every build (needed when this
#                     checkout is a git worktree).
#   LAB_SW=DIR        zephyr-chipyard-sw checkout providing hello_world, timer and
#                     test_mt_rvv (default: sibling of this repo). If absent those ELFs are
#                     skipped and noted in MANIFEST.txt.
#   BUNDLE_BUILD=DIR  scratch build directory (default <workspace>/build/bench).
#   BUNDLE_JOBS=N     parallel builds (default 8).
#
# A failed build is recorded in MANIFEST.txt ("BUILD FAILED") and the script continues.
set -euo pipefail

BSP="$(cd "$(dirname "$0")/.." && pwd)"
WS="$(cd "$BSP/.." && pwd)"
OUT="${1:-$WS/bench-bundle-$(date +%Y%m%d-%H%M)}"
BUILD="${BUNDLE_BUILD:-$WS/build/bench}"
BOARD=chipyard_penguin/penguin
TA_BOARD=chipyard_penguin/penguin/vcu118_ta
LAB_SW="${LAB_SW:-$WS/zephyr-chipyard-sw}"
SW="$LAB_SW/samples"
[ -d "$SW" ] || echo "warning: lab samples not found at $SW (set LAB_SW=<zephyr-chipyard-sw checkout>); hello_world, timer and test_mt_rvv will be skipped" >&2
mkdir -p "$OUT" "$BUILD"

# ---- the patched Zephyr copy for the stock-vs-patched ctx_switch comparison --------
if [ -z "${PATCHED_ZEPHYR:-}" ]; then
  PATCHED_ZEPHYR="$WS/build/zephyr-patched"
  echo "== making patched Zephyr copy: $PATCHED_ZEPHYR"
  "$BSP/scripts/make_patched_zephyr.sh" "$PATCHED_ZEPHYR" >"$BUILD/patched_zephyr.log" 2>&1 \
    || { echo "   make_patched_zephyr.sh FAILED, see $BUILD/patched_zephyr.log"; PATCHED_ZEPHYR=none; }
fi

# name | app dir | extra west build args | extra cmake -D args | ZEPHYR_BASE override
# Numbers give the run order, simplest first. 08 and 09 are unused (removed tests) and
# numbers are not reused.
APPS=(
  "01_hello_world|$SW/hello_world||"
  "02_hello_rvv|$BSP/samples/hello_rvv||"
  "03_test_vlen|$BSP/tests/arch/rvv/vlen||"
  "04_timer|$SW/timer|-S single-cpu|"
  "05_test_ctx_switch|$BSP/tests/arch/rvv/ctx_switch||"
  "06_test_mt_rvv|$SW/test_mt_rvv|-S single-cpu|"
  "10_hw_probe|$BSP/samples/hw_probe||"
  "20_atlas_smoke|$BSP/samples/atlas_smoke||"
  "21_atlas_kernels|$BSP/samples/atlas_kernels||"
)
[ "$PATCHED_ZEPHYR" != none ] && APPS+=("07_test_ctx_switch_patched|$BSP/tests/arch/rvv/ctx_switch|||$PATCHED_ZEPHYR")

MANIFEST="$OUT/MANIFEST.txt"
{
  echo "bench bundle built $(date -Is)"
  echo "bsp $(git -C "$BSP" rev-parse --short HEAD)$(git -C "$BSP" diff --quiet || echo -dirty)"
  echo "zephyr $(git -C "$WS/zephyr" rev-parse --short HEAD)"
  echo
} > "$MANIFEST"

# Extra cmake args need exactly one "--" separator.
cmake_args() { # <extra -D args>
  local a="${BUNDLE_CMAKE_ARGS:-}${BUNDLE_CMAKE_ARGS:+ }${1:-}"
  [ -n "$a" ] && echo "-- $a"
}

# Each job writes $BUILD/<name>.result ("OK <line>", "SKIP ..." or "FAIL ...");
# the manifest is assembled from those afterwards so lines stay in run order.
JOBS="${BUNDLE_JOBS:-8}"
wait_for_slot() { while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done; }

# one_build <result-id> <label> <board> <build-dir> <app> <west-extra> <cmake-extra> <zephyr-base> <dest.elf>
one_build() {
  local id="$1" label="$2" board="$3" bdir="$4" app="$5" extra="$6" cm="$7" zbase="$8" dest="$9"
  echo "== $label ($board${zbase:+, ZEPHYR_BASE=$zbase})"
  rm -f "$BUILD/$id.result"
  if [ ! -d "$app" ]; then   # lab samples are missing in a plain clone
    echo "   SKIPPED: $app does not exist"
    echo "SKIP $label SKIPPED (source $app not found; set LAB_SW=)" >"$BUILD/$id.result"
    return 0
  fi
  # shellcheck disable=SC2046,SC2086
  if ZEPHYR_BASE="${zbase:-$ZEPHYR_BASE}" west build -p -b "$board" -d "$BUILD/$bdir" "$app" $extra \
       $(cmake_args "$cm") >"$BUILD/$bdir.log" 2>&1; then
    cp "$BUILD/$bdir/zephyr/zephyr.elf" "$dest"
    printf 'OK %-34s board=%-30s load=%7s B  sha256=%s\n' "$label" "$board" \
      "$(riscv64-zephyr-elf-size "$dest" | awk 'NR==2{print $1+$2}')" "$(sha256sum "$dest" | cut -c1-16)" \
      >"$BUILD/$id.result"
  else
    echo "   BUILD FAILED: $label, see $BUILD/$bdir.log"
    echo "FAIL $label BUILD FAILED (see $BUILD/$bdir.log)" >"$BUILD/$id.result"
  fi
}

RESULTS=()   # result ids in manifest order
build_set() { # <label-prefix> <board> <build-prefix> <dest-dir>
  local prefix="$1" board="$2" bp="$3" dest="$4" entry name app extra cm zbase
  mkdir -p "$dest"
  for entry in "${APPS[@]}"; do
    IFS='|' read -r name app extra cm zbase <<<"$entry"
    wait_for_slot
    one_build "$bp$name" "${prefix}$name.elf" "$board" "$bp$name" "$app" "$extra" "$cm" "$zbase" \
      "$dest/$name.elf" &
    RESULTS+=("$bp$name")
  done
}

# ---- chip set (top level) ----------------------------------------------------------
# 00: plain rv64gc Zephyr for the generic spike_riscv64 board (no V, no Zb*). If only this
# boots, the penguin configuration is the suspect.
one_build 00_fallback_hello_rv64gc 00_fallback_hello_rv64gc.elf spike_riscv64 00_fallback_hello_rv64gc \
  "$SW/hello_world" "" "" "" "$OUT/00_fallback_hello_rv64gc.elf" &
RESULTS+=(00_fallback_hello_rv64gc)
build_set "" "$BOARD" "" "$OUT"

# ---- vcu118_ta set: TA's bitstream (VCU118_TA=0 to skip) ---------------------------
TA_START=${#RESULTS[@]}
if [ "${VCU118_TA:-1}" = 1 ]; then
  build_set "vcu118_ta/" "$TA_BOARD" "vcu118_ta_" "$OUT/vcu118_ta"
  # The TA bitstream's UART-TSI runs at 115200 on CP2105 interface 1 (/dev/ttyUSB1);
  # 921600 gets no reply.
  sed 's/^BAUD="${BAUD:-921600}"/BAUD="${BAUD:-115200}"/' "$BSP/scripts/bench.sh" > "$OUT/vcu118_ta/bench.sh"
  grep -q 'BAUD:-115200' "$OUT/vcu118_ta/bench.sh" || { echo "BAUD default rewrite failed"; exit 1; }
  chmod +x "$OUT/vcu118_ta/bench.sh"
  "$BSP/scripts/probes/build_probes.sh" "$OUT/vcu118_ta/probes"
fi

# ---- optional: Atlas team tests built from their source (ATLAS_UPSTREAM=1) --------
# One ELF per test, named <test>.elf.
if [ "${ATLAS_UPSTREAM:-0}" = 1 ]; then
  AU_TESTS=$(sed -n 's/^atlas_test(\([A-Za-z0-9_]*\) *\(asis\|kernel\)).*/\1/p' \
               "$BSP/samples/atlas_upstream/tests.cmake")
  if python3 -c 'import torch' 2>/dev/null; then
    AU_TESTS="$AU_TESTS $(sed -n 's/^atlas_test(\([A-Za-z0-9_]*\) *torch).*/\1/p' \
               "$BSP/samples/atlas_upstream/tests.cmake")"
  fi
  au_set() { # <label-prefix> <board> <build-prefix> <dest-dir>
    local t; mkdir -p "$4"
    for t in $AU_TESTS; do
      wait_for_slot
      one_build "$3au_$t" "$1atlas_upstream/$t.elf" "$2" "$3au_$t" "$BSP/samples/atlas_upstream" "" \
        "-DATLAS_TEST=$t" "" "$4/$t.elf" &
      RESULTS+=("$3au_$t")
    done
  }
  AU_START=${#RESULTS[@]}
  au_set "" "$BOARD" "" "$OUT/atlas_upstream"
  [ "${VCU118_TA:-1}" = 1 ] && au_set "vcu118_ta/" "$TA_BOARD" "vcu118_ta_" "$OUT/vcu118_ta/atlas_upstream"
fi
wait

# Manifest, in run order. The rv64gc fallback is board independent (HTIF only), so
# vcu118_ta/ gets a copy.
for i in "${!RESULTS[@]}"; do
  [ "$i" = "$TA_START" ] && { echo; echo "vcu118_ta variant (HTIF over UART-TSI, bench.sh defaults to BAUD=115200):"; } >>"$MANIFEST"
  line="$(cat "$BUILD/${RESULTS[$i]}.result")"
  case "$line" in OK\ *) echo "${line#OK }" >>"$MANIFEST" ;; SKIP\ *) echo "${line#SKIP }" >>"$MANIFEST" ;;
                  *) echo "${line#FAIL }" >>"$MANIFEST" ;; esac
done
[ -d "$OUT/vcu118_ta" ] && [ -f "$OUT/00_fallback_hello_rv64gc.elf" ] && cp "$OUT/00_fallback_hello_rv64gc.elf" "$OUT/vcu118_ta/"

# ---- optional: GENERIC board variant for the whole SoC on a VCU118 (VCU118=1) ------
if [ "${VCU118:-0}" = 1 ]; then
  VB=chipyard_penguin/penguin/vcu118
  VAPPS=(
    "01_hello_world|$SW/hello_world"
    "02_hello_rvv|$BSP/samples/hello_rvv"
    "03_test_vlen|$BSP/tests/arch/rvv/vlen"
    "10_hw_probe|$BSP/samples/hw_probe"
  )
  mkdir -p "$OUT/vcu118"
  echo >>"$MANIFEST"; echo "vcu118 variant (UART console, PBUS ${VCU118_PBUS_MHZ:-100} MHz):" >>"$MANIFEST"
  for entry in "${VAPPS[@]}"; do
    IFS='|' read -r name app <<<"$entry"
    echo "== vcu118/$name ($VB)"
    [ -d "$app" ] || { echo "   SKIPPED: $app does not exist (LAB_SW?)"; echo "vcu118/$name SKIPPED (source not found)" >>"$MANIFEST"; continue; }
    # shellcheck disable=SC2046
    if ! west build -p -b "$VB" -d "$BUILD/vcu118_$name" "$app" -- \
         ${BUNDLE_CMAKE_ARGS:-} \
         $([ -n "${VCU118_PBUS_MHZ:-}" ] && echo "-DCONFIG_CHIPYARD_FPGA_PBUS_MHZ=$VCU118_PBUS_MHZ") \
         >"$BUILD/vcu118_$name.log" 2>&1; then
      echo "   BUILD FAILED, see $BUILD/vcu118_$name.log"; echo "vcu118/$name BUILD FAILED" >>"$MANIFEST"; continue
    fi
    cp "$BUILD/vcu118_$name/zephyr/zephyr.elf" "$OUT/vcu118/$name.elf"
    "$BSP/scripts/mk_sdboot_image.sh" "$OUT/vcu118/$name.elf" "$OUT/vcu118/$name.sd.bin" >/dev/null
    printf '%-34s image=%7s B  sha256=%s\n' "vcu118/$name.sd.bin" "$(stat -c %s "$OUT/vcu118/$name.sd.bin")" \
      "$(sha256sum "$OUT/vcu118/$name.sd.bin" | cut -c1-16)" >>"$MANIFEST"
  done
  cp "$BSP/boards/chipyard/penguin/support/openocd-ftlink.cfg" "$OUT/vcu118/openocd-ftlink.cfg"
  cp "$BSP/boards/chipyard/penguin/support/openocd-vcu118.cfg" "$OUT/vcu118/openocd-vcu118.cfg"
  cp "$BSP/scripts/mk_sdboot_image.sh" "$OUT/vcu118/"
fi

# ---- fast-load copies: <name>.fast.elf next to every ELF -----------------------
# Probes are skipped (data-only, tiny). An ELF that fastload_elf.py's guards refuse gets no
# copy, and MANIFEST.txt says so.
{
  echo
  echo "fast-load copies (FASTLOAD=1 ./bench.sh run <name>; est. load time before -> after):"
} >>"$MANIFEST"
FL_OK=0; FL_SKIP=0
while IFS= read -r e; do
  rel="${e#"$OUT"/}"
  if msg="$(python3 "$BSP/scripts/fastload_elf.py" "$e" 2>&1)"; then
    FL_OK=$((FL_OK+1)); echo "  ${msg#wrote $OUT/}" | sed "s|$OUT/||g" >>"$MANIFEST"
  else
    FL_SKIP=$((FL_SKIP+1)); echo "  SKIPPED $rel (no .fast.elf): $(echo "$msg" | tr '\n' ' ' | sed "s|$OUT/||g")" >>"$MANIFEST"
  fi
done < <(find "$OUT" -name '*.elf' ! -name '*.fast.elf' ! -path '*/probes/*' | sort)
echo "  $FL_OK written, $FL_SKIP skipped" >>"$MANIFEST"

# README-bench.md is generated here so it matches the script.
write_readme() { cat >"$1" <<'README'
# Bench bundle

Prebuilt Zephyr ELFs for the Penguin SoC plus `bench.sh`, which loads them over UART-TSI
with `uart_tsi` and logs the output. Needs only bash and `uart_tsi`, no Zephyr toolchain.

## Contents

- `MANIFEST.txt`: commit, sizes and sha256 of each ELF, anything that FAILED or was
  SKIPPED, and the estimated saving of each fast-load copy. Read it first.
- `NN_name.elf`: the chip set (board `chipyard_penguin/penguin`), numbered in suggested
  run order. `00_fallback_hello_rv64gc.elf` is plain rv64gc Zephyr: if only that boots, the
  Penguin configuration is the suspect.
- `NN_name.fast.elf`: same program with `p_memsz = p_filesz`, so the loader does not send
  the .bss zeros over the UART (used with `FASTLOAD=1`).
- `probes/{dram,clint,spad}.elf`: data-only ELFs for `bench.sh check`.
- `vcu118_ta/`: the same set built for the TA's VCU118 bitstream, with its own `bench.sh`
  whose default baud is 115200.
- `atlas_upstream/` (built with ATLAS_UPSTREAM=1): one ELF per Atlas team test.
- `penguin-jtag-ftlink.cfg`: candidate OpenOCD config, untested.

## Running

    export TTY=/dev/ttyUSB1          # required; `ls /dev/ttyUSB*` before and after replugging
    ./bench.sh check                 # link check: writes and reads back words, CPU not started
    ./bench.sh run 02_hello_rvv      # one ELF (name with or without .elf)
    ./bench.sh all                   # every *.elf in this directory, in order

Logs go to `logs-<timestamp>/` next to the script (`summary.txt` has one PASS/FAIL line each).

## Knobs (environment variables)

- `TTY`: serial device (required).
- `BAUD`: 921600 for the chip (default in this folder); 115200 for the TA's VCU118 bitstream
  (default in `vcu118_ta/`).
- `TIMEOUT`: seconds per run (default 120; 600 for ctx_switch unless set).
- `CHECK_TIMEOUT`: seconds per probe in `check` (default 20).
- `FASTLOAD=1`: load `<name>.fast.elf` when present instead of `<name>.elf`. Opt-in; the
  log says which file was loaded.
- `UART_TSI`: path to the `uart_tsi` binary (default: on PATH).

Nothing here has been run on the chip itself yet.
README
}

cp "$BSP/scripts/bench.sh" "$OUT/bench.sh"
# link-probe ELFs for `bench.sh check` (see scripts/probes/probe.S)
"$BSP/scripts/probes/build_probes.sh" "$OUT/probes"
cp "$BSP/boards/chipyard/penguin/support/openocd-ftlink.cfg" "$OUT/penguin-jtag-ftlink.cfg"  # candidate, untested
write_readme "$OUT/README-bench.md"
chmod +x "$OUT/bench.sh"
tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
echo
cat "$MANIFEST"
grep -q 'BUILD FAILED' "$MANIFEST" && echo "WARNING: some builds failed (see above)"
echo "bundle: $OUT.tar.gz"
