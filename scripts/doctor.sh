#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# doctor.sh: report what this machine has and what is missing, with a fix hint for each.
# Changes nothing, downloads nothing. Exit status: 1 if something REQUIRED is missing or
# wrong, else 0 (optional things that are missing only print "optional").
#   make doctor            (or scripts/doctor.sh)
#
# Required to build:   Zephyr SDK (right version), west + Python >= 3.10, cmake < 4, ninja,
#                      a Zephyr tree (ZEPHYR_BASE), a west workspace.
# Optional:            Spike (to run), OpenOCD with remote_bitbang (to debug), uart_tsi
#                      (to load onto hardware), TAPEOUT_CHIPYARD (atlas_upstream tests).
#
# Every dependency can be given through an environment variable; each probe below is the
# same lookup the build itself uses:
#   ZEPHYR_SDK_INSTALL_DIR  the SDK folder          SDK_VERSION    wanted SDK version (default 1.0.0-beta1)
#   ZEPHYR_BASE             the Zephyr checkout     SPIKE          the spike binary (else PATH)
#   WS                      the west workspace      SPIKE_OPENOCD  OpenOCD with remote_bitbang
#   BSP                     this module             UART_TSI       the uart_tsi binary (else PATH)
#   TAPEOUT_CHIPYARD        tapeout-chipyard checkout (no default location)

SDK_VERSION=${SDK_VERSION:-1.0.0-beta1}
BSP=${BSP:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
bad=0

ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
opt()  { printf '  [opt ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$1"; [ -n "${2:-}" ] && printf '         fix: %s\n' "$2"; bad=1; }
hint() { printf '         %s\n' "$*"; }
# version_ge A B: true if A >= B (sort -V)
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

echo "Build requirements"

# ---- west workspace and this module ----------------------------------------------
if command -v west >/dev/null; then
  ok "west $(west --version 2>/dev/null | head -1 | sed 's/^West version: //')"
  WS=${WS:-$(west topdir 2>/dev/null)}
else
  fail "west not found" "pip install west   (inside a virtual environment; needs Python >= 3.10)"
fi
if [ -n "${WS:-}" ] && [ -d "$WS/.west" ]; then
  ok "workspace WS=$WS"
else
  fail "no west workspace (WS='${WS:-}')" "run inside a workspace (west init -l <manifest repo>; west update) or export WS=<dir with .west/>"
fi
if [ -f "$BSP/zephyr/module.yml" ]; then
  ok "BSP=$BSP"
else
  fail "chipyard-bsp not found (BSP='$BSP')" "export BSP=<dir containing zephyr/module.yml>"
fi

# ---- python -------------------------------------------------------------------------
PY=$(command -v python3 || command -v python)
if [ -n "$PY" ]; then
  pv=$("$PY" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')
  if version_ge "$pv" 3.10; then ok "python $pv ($PY)"
  else fail "python $pv is older than 3.10 ($PY)" "use a newer Python, e.g. a uv/venv environment with Python >= 3.10"; fi
  "$PY" -c 'import yaml' 2>/dev/null && ok "python module yaml (needed by scripts/run_tests.py)" \
    || fail "python module yaml missing" "pip install pyyaml"
else
  fail "python not found" "install Python >= 3.10"
fi

# ---- cmake / ninja ------------------------------------------------------------------
if command -v cmake >/dev/null; then
  cv=$(cmake --version | head -1 | sed 's/[^0-9.]*//; s/-.*//')
  if version_ge "$cv" 3.20 && ! version_ge "$cv" 4.0; then ok "cmake $cv (>= 3.20, < 4)"
  else fail "cmake $cv (need >= 3.20 and < 4 for this Zephyr)" "use the cmake from the Zephyr SDK host tools, or pip install 'cmake<4'"; fi
else
  fail "cmake not found" "pip install 'cmake<4'  (or the SDK's hosttools/.../usr/bin)"
fi
command -v ninja >/dev/null && ok "ninja $(ninja --version)" || fail "ninja not found" "pip install ninja  (or the SDK's host tools)"

# ---- Zephyr tree --------------------------------------------------------------------
# West exports ZEPHYR_BASE itself for its own commands, so an unset variable is fine as long
# as the workspace has a zephyr project.
if [ -z "${ZEPHYR_BASE:-}" ] && command -v west >/dev/null; then
  ZEPHYR_BASE=$(west list -f '{abspath}' zephyr 2>/dev/null | head -1)
  [ -n "$ZEPHYR_BASE" ] && ok "ZEPHYR_BASE not set; west finds it: $ZEPHYR_BASE"
fi
if [ -n "${ZEPHYR_BASE:-}" ] && [ -f "$ZEPHYR_BASE/Kconfig.zephyr" ]; then
  ok "ZEPHYR_BASE=$ZEPHYR_BASE"
  want=$(awk '/name: zephyr/{f=1} f&&/revision:/{print $2; exit}' "$BSP/west.yml" 2>/dev/null)
  have=$(git -C "$ZEPHYR_BASE" rev-parse HEAD 2>/dev/null)
  if [ -n "$want" ] && [ -n "$have" ]; then
    if [ "$want" = "$have" ]; then ok "Zephyr is at the SHA pinned in west.yml (${have:0:12})"
    else warn "Zephyr is at ${have:0:12}, west.yml pins ${want:0:12} (fine if you know why; west update resets it)"; fi
  fi
else
  fail "ZEPHYR_BASE not set or not a Zephyr tree ('${ZEPHYR_BASE:-}')" "export ZEPHYR_BASE=<workspace>/zephyr  (created by west update)"
fi

# ---- Zephyr SDK ---------------------------------------------------------------------
SDK=${ZEPHYR_SDK_INSTALL_DIR:-}
if [ -n "$SDK" ] && [ -d "$SDK" ]; then
  have=$(cat "$SDK/sdk_version" 2>/dev/null)
  if [ "$have" = "$SDK_VERSION" ]; then ok "Zephyr SDK $have ($SDK)"
  else fail "Zephyr SDK version is '${have:-unknown}', wanted $SDK_VERSION ($SDK)" "install SDK $SDK_VERSION, or export SDK_VERSION=$have if you know it works"; fi
  [ -x "$SDK/gnu/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-gcc" ] \
    && ok "riscv64-zephyr-elf-gcc: $("$SDK/gnu/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-gcc" -dumpversion)" \
    || fail "riscv64-zephyr-elf-gcc missing in the SDK" "run the SDK's setup.sh -t riscv64-zephyr-elf"
  [ "${ZEPHYR_TOOLCHAIN_VARIANT:-}" = zephyr ] && ok "ZEPHYR_TOOLCHAIN_VARIANT=zephyr" \
    || warn "ZEPHYR_TOOLCHAIN_VARIANT is '${ZEPHYR_TOOLCHAIN_VARIANT:-}', expected 'zephyr'"
  # Report only. SDK 1.0.0-beta1 moved these into gnu/ and llvm/; the Zephyr fork wants the flat files.
  if [ -f "$SDK/cmake/zephyr/generic.cmake" ]; then
    ok "SDK has cmake/zephyr/generic.cmake (the Zephyr fork finds its toolchain files)"
  else
    warn "SDK lacks cmake/zephyr/generic.cmake: a build will fail until the toolchain files are provided"
    hint "the BSP carries a fallback, cmake/sdk-shims/ (not used by the build yet); it must never be copied into the SDK"
  fi
else
  fail "ZEPHYR_SDK_INSTALL_DIR not set or not a directory ('$SDK')" "install the Zephyr SDK $SDK_VERSION and export ZEPHYR_SDK_INSTALL_DIR=<its folder>"
fi

echo "Optional: simulate (Spike)"
S=${SPIKE:-spike}
SP=$(command -v "$S" 2>/dev/null)
if [ -n "$SP" ]; then
  ok "Spike: $SP"
  # ISA probe (Spike has no --version): a bad --isa is rejected before the ELF is even looked at.
  # The string mirrors what cmake/spike.cmake derives from soc/chipyard/penguin/Kconfig; keep it in sync.
  isa=rv64imafdcv_zicsr_zifencei_zba_zbb_zbs_zfh_zvfh_zvfbfmin
  more=_zaamo_zalrsc_zicntr_zfbfmin_zvfbfa_zvl256b
  if [ -n "$isa" ]; then
    out=$(timeout 10 "$SP" --isa="$isa$more" /dev/null 2>&1 </dev/null | head -3)
    if printf '%s' "$out" | grep -qi 'bad --isa\|unsupported\|unknown'; then
      warn "Spike does not accept the board's ISA ($isa$more): $(printf '%s' "$out" | head -1)"
      hint "build a newer riscv-isa-sim (commit 609dbe0b or newer was verified)"
    else
      ok "Spike accepts the board's ISA string (V/VLEN 256, zfh, zvfh, zvfbfa, ...)"
    fi
  else
    warn "could not read the ISA from the board files; skipped the ISA probe"
  fi
else
  opt "Spike not found (looked for '$S'): building works; running and the test suite's run step need it"
  hint "set SPIKE=/path/to/spike, or run setup with --with-spike"
fi
if [ -n "${SPIKE_OPENOCD:-}" ] && [ -x "$SPIKE_OPENOCD" ]; then ok "SPIKE_OPENOCD=$SPIKE_OPENOCD (for west debug)"
elif command -v openocd >/dev/null; then opt "openocd on PATH; west debug needs one built with --enable-remote-bitbang (set SPIKE_OPENOCD to be sure)"
else opt "no OpenOCD with remote_bitbang (only needed for west debug on Spike): set SPIKE_OPENOCD=<path>"; fi

echo "Optional: load onto hardware"
U=${UART_TSI:-uart_tsi}
if command -v "$U" >/dev/null; then ok "uart_tsi: $(command -v "$U")"
else opt "uart_tsi not found: building works; loading an ELF onto the chip/FPGA needs a loader such as Chipyard's uart_tsi (UART_TSI=<path>)"; fi

echo "Optional: other people's tests"
if [ -n "${TAPEOUT_CHIPYARD:-}" ] && [ -f "$TAPEOUT_CHIPYARD/tests/atlas_mmio.h" ]; then ok "TAPEOUT_CHIPYARD=$TAPEOUT_CHIPYARD"
elif [ -n "${TAPEOUT_CHIPYARD:-}" ]; then warn "TAPEOUT_CHIPYARD='$TAPEOUT_CHIPYARD' has no tests/atlas_mmio.h"
else opt "TAPEOUT_CHIPYARD not set: the atlas_upstream tests are skipped (no default location)"; fi

echo
if [ "$bad" = 0 ]; then echo "doctor: everything required is in place."; else echo "doctor: something required is missing or wrong (see [FAIL] above)."; fi
exit "$bad"
