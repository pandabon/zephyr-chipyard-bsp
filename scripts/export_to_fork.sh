#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# export_to_fork.sh: generate the in-tree Penguin port for a checkout of the
# ucb-bar/zephyr fork from this BSP, so the two never drift.
#
#   scripts/export_to_fork.sh <fork-repo-path> [--commit] [--message-file FILE]
#
# The BSP stays the single source of truth. This script copies the Zephyr-appropriate
# part of it (soc/, boards/, dts/, the two bindings) into the fork layout and leaves the
# result as uncommitted changes in the fork for review. It never pushes.
#
# What is exported, and where it lands in the fork (same paths unless noted):
#   soc/chipyard/penguin/*                    SoC (Kconfig, soc.c, soc.h, soc.yml, CMakeLists.txt)
#   include/chipyard/sim_exit.h               -> soc/chipyard/penguin/include/chipyard/sim_exit.h
#   include/tc_util_user_override.h           -> soc/chipyard/penguin/include/tc_util_user_override.h
#   boards/chipyard/penguin/*  (not support/) boards chipyard_penguin, variants vcu118, vcu118_ta
#   cmake/spike.cmake                         -> boards/chipyard/penguin/spike.cmake (the `run`
#                                                target; the debug-runner tail is cut, see below)
#   dts/riscv/chipyard/penguin.dtsi           devicetree of the SoC
#   dts/bindings/accel/ucb-bar,atlas.yaml     bindings
#   dts/bindings/cpu/ucb-bar,shuttle.yaml
#   dts/bindings/vendor-prefixes.txt          only the lines `chipyard` and `ucb-bar` are merged
#                                             into the fork's own sorted list
# NOT exported (they stay in the BSP): plain_app, bare metal (support/), doctor, template,
# test runner, Makefile, samples/tests, the `spike` west runner and the OpenOCD configs.
#
# Transforms applied (everything else is a byte-for-byte copy, so the SPDX/credit headers
# and the cited sources in the comments are preserved):
#   * soc CMakeLists.txt: adds zephyr_include_directories(include) so <chipyard/sim_exit.h>
#     and tc_util_user_override.h resolve without the BSP module's include/.
#   * board.cmake: include(.../cmake/spike.cmake) -> the copy next to it.
#   * spike.cmake: everything from the "---- debug" marker on is dropped (it registers the
#     out-of-tree `spike` runner, which does not exist in the fork).
#   * board Kconfig.defconfig: comment "the module's include/" -> the in-tree location.
#   * boards/chipyard/penguin/doc/index.rst: generated (3 factual lines), like the fork's
#     other chipyard boards have; the BSP keeps no board docs in git.
#
# Idempotent: the owned directories are rebuilt from scratch each run, so a file deleted in
# the BSP disappears in the fork too; running twice on the same BSP commit changes nothing.
# Provenance is NOT stamped into the files (a sha in every file would make every re-export a
# whole-tree diff); it goes in the commit message and is printed here.
#
# --commit  commit the result in the fork (repo-local identity, no trailers), message states
#           the BSP commit. Without it the changes are only left in the working tree.

set -euo pipefail

usage() { sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

FORK=""; DO_COMMIT=0; MSGFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --commit) DO_COMMIT=1 ;;
    --message-file) MSGFILE=${2:?--message-file needs a path}; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) [ -z "$FORK" ] && FORK=$1 || usage ;;
  esac
  shift
done
[ -n "$FORK" ] || usage

BSP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FORK=$(cd "$FORK" && pwd)
git -C "$FORK" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $FORK" >&2; exit 1; }
[ -f "$FORK/VERSION" ] && [ -d "$FORK/soc" ] && [ -d "$FORK/boards/chipyard" ] \
  || { echo "$FORK does not look like the ucb-bar/zephyr fork (no VERSION, soc/ or boards/chipyard/)" >&2; exit 1; }
[ "$FORK" != "$BSP" ] || { echo "fork path is the BSP itself" >&2; exit 1; }

# ---- provenance --------------------------------------------------------------
SRC_PATHS="soc/chipyard/penguin boards/chipyard/penguin dts/riscv/chipyard/penguin.dtsi \
dts/bindings/accel/ucb-bar,atlas.yaml dts/bindings/cpu/ucb-bar,shuttle.yaml \
include/chipyard/sim_exit.h include/tc_util_user_override.h cmake/spike.cmake scripts/export_to_fork.sh"
BSP_HEAD=$(git -C "$BSP" rev-parse --short=7 HEAD)
BSP_BRANCH=$(git -C "$BSP" rev-parse --abbrev-ref HEAD)
# Last BSP commit that touched an exported source: stable across unrelated BSP commits.
# shellcheck disable=SC2086
BSP_SRC=$(git -C "$BSP" log -1 --format=%h --abbrev=7 -- $SRC_PATHS)
DIRTY=""
# shellcheck disable=SC2086
if [ -n "$(git -C "$BSP" status --porcelain -- $SRC_PATHS | grep -v '^??.*support/' || true)" ]; then
  DIRTY=" (+uncommitted changes in exported files)"
  [ "$DO_COMMIT" = 1 ] && { echo "refusing --commit: exported BSP files have uncommitted changes" >&2; exit 1; }
fi
echo "BSP:  $BSP  $BSP_BRANCH@$BSP_HEAD, exported files last changed in $BSP_SRC$DIRTY"
echo "Fork: $FORK  $(git -C "$FORK" rev-parse --abbrev-ref HEAD)@$(git -C "$FORK" rev-parse --short=11 HEAD)"

# ---- export ------------------------------------------------------------------
SOC=soc/chipyard/penguin
BRD=boards/chipyard/penguin
DST_SOC="$FORK/$SOC"; DST_BRD="$FORK/$BRD"
rm -rf "$DST_SOC" "$DST_BRD"
mkdir -p "$DST_SOC/include/chipyard" "$DST_BRD/doc" \
         "$FORK/dts/riscv/chipyard" "$FORK/dts/bindings/accel" "$FORK/dts/bindings/cpu"

# SoC (flat files only; the BSP soc dir has no subdirs)
cp "$BSP/$SOC"/* "$DST_SOC/"
cp "$BSP/include/chipyard/sim_exit.h" "$DST_SOC/include/chipyard/"
cp "$BSP/include/tc_util_user_override.h" "$DST_SOC/include/"
cat >> "$DST_SOC/CMakeLists.txt" <<'EOF'

# <chipyard/sim_exit.h> (what apps call to end a simulation) and
# tc_util_user_override.h (ztest, CONFIG_ZTEST_TC_UTIL_USER_OVERRIDE) live in include/.
zephyr_include_directories(include)
EOF

# Board: flat files only (support/ = baremetal.mk, OpenOCD configs, stays in the BSP)
for f in "$BSP/$BRD"/*; do [ -f "$f" ] && cp "$f" "$DST_BRD/"; done
cp "$BSP/cmake/spike.cmake" "$DST_BRD/spike.cmake"
# Drop the debug-runner tail of spike.cmake (out-of-tree `spike` west runner).
awk '/^# ---- debug/ {exit} {print}' "$BSP/cmake/spike.cmake" > "$DST_BRD/spike.cmake"
sed -i '1a #\n# Exported from the zephyr-chipyard-bsp copy of cmake/spike.cmake. The `west debug` section\n# (which uses the BSP'"'"'s out-of-tree `spike` runner) is not part of the in-tree board.' \
  "$DST_BRD/spike.cmake"
sed -i 's|include(${CMAKE_CURRENT_LIST_DIR}/../../../cmake/spike.cmake)|include(${CMAKE_CURRENT_LIST_DIR}/spike.cmake)|' \
  "$DST_BRD/board.cmake"
sed -i 's|^# This BSP only PRODUCES binaries|# This board only PRODUCES binaries|; s|^#   include(${BOARD_DIR}/../../../cmake/spike.cmake).*|#   include(${CMAKE_CURRENT_LIST_DIR}/spike.cmake)|' \
  "$DST_BRD/board.cmake" "$DST_BRD/spike.cmake"
sed -i "s|the override header in$|the override header in|; s|# the module's include/ makes it end the simulation with an exit code.|# soc/chipyard/penguin/include/ makes it end the simulation with an exit code.|" \
  "$DST_BRD/Kconfig.defconfig"
# The generic Spike logic is no longer reached through ../../../cmake: assert the rewrite worked.
grep -q 'CMAKE_CURRENT_LIST_DIR}/spike.cmake' "$DST_BRD/board.cmake" \
  || { echo "export: board.cmake rewrite failed" >&2; exit 1; }
cat > "$DST_BRD/doc/index.rst" <<'EOF'
.. zephyr:board:: chipyard_penguin

Overview
********

Penguin SoC (Shuttle RV64 core with Saturn RVV and the Atlas NPU), generated with Chipyard.
Variants: ``vcu118`` (whole SoC on an FPGA, UART console) and ``vcu118_ta`` (HTIF console).
`west build -t run` simulates the base board on Spike (optional, found via $SPIKE or PATH).
EOF

# DTS + bindings
cp "$BSP/dts/riscv/chipyard/penguin.dtsi" "$FORK/dts/riscv/chipyard/"
cp "$BSP/dts/bindings/accel/ucb-bar,atlas.yaml" "$FORK/dts/bindings/accel/"
cp "$BSP/dts/bindings/cpu/ucb-bar,shuttle.yaml" "$FORK/dts/bindings/cpu/"

# Vendor prefixes: merge our two entries into the fork's sorted file (not a copy).
VP="$FORK/dts/bindings/vendor-prefixes.txt"
add_prefix() {  # $1 = prefix, $2 = description, $3 = existing prefix to insert it after
  if ! grep -q "^$1[[:space:]]" "$VP"; then
    grep -q "^$3[[:space:]]" "$VP" || { echo "export: anchor '$3' missing in $VP" >&2; exit 1; }
    sed -i "/^$3[[:space:]]/a $1\t$2" "$VP"
  fi
}
add_prefix chipyard "Chipyard (UC Berkeley SoC generator framework)" chipspark
add_prefix ucb-bar  "UC Berkeley Architecture Research" ubnt

# ---- report ------------------------------------------------------------------
echo
echo "Changes in the fork working tree (review with: git -C $FORK diff / status):"
git -C "$FORK" add -N "$SOC" "$BRD" dts/riscv/chipyard/penguin.dtsi \
  dts/bindings/accel dts/bindings/cpu/ucb-bar,shuttle.yaml 2>/dev/null || true
git -C "$FORK" status --short -- "$SOC" "$BRD" dts
git -C "$FORK" diff --stat -- "$SOC" "$BRD" dts | tail -n 1

if [ "$DO_COMMIT" = 1 ]; then
  if git -C "$FORK" cat-file -e HEAD:"$SOC/soc.yml" 2>/dev/null; then
    SUBJECT="Penguin: re-export from zephyr-chipyard-bsp $BSP_SRC"
  else
    SUBJECT="Penguin: add the Penguin SoC (Shuttle + Saturn RVV + Atlas) and chipyard_penguin boards"
  fi
  if [ -n "$MSGFILE" ]; then
    MSG=$(cat "$MSGFILE")
  else
    MSG="$SUBJECT

Penguin is a new SoC, not a variant of the generic rocketchip virt_riscv SoC: a
Shuttle RV64GC core with the Saturn RISC-V vector unit (VLEN 256, Zvfh, Zvfbfmin)
and the Atlas NPU as a memory-mapped TileLink peripheral. It gets its own
soc/chipyard/penguin (SOC_PENGUIN), devicetree dts/riscv/chipyard/penguin.dtsi,
bindings ucb-bar,shuttle and ucb-bar,atlas, and boards chipyard_penguin (HTIF
console, runs on Spike) plus the variants vcu118_ta and vcu118 (FPGA).

Reused from the fork unchanged: the HTIF and SiFive UART drivers, the PLIC and
RISC-V machine timer drivers, the ucb,htif binding, the RVV code in arch/riscv.

Generated by scripts/export_to_fork.sh from zephyr-chipyard-bsp (the source of
truth), so the out-of-tree BSP and this tree do not drift. Edit the BSP, then
re-export; do not hand-edit these files here.

Exported from zephyr-chipyard-bsp $BSP_BRANCH@$BSP_HEAD (exported files last
changed in $BSP_SRC)."
  fi
  git -C "$FORK" add -A -- "$SOC" "$BRD" dts/riscv/chipyard/penguin.dtsi \
    dts/bindings/accel/ucb-bar,atlas.yaml dts/bindings/cpu/ucb-bar,shuttle.yaml \
    dts/bindings/vendor-prefixes.txt
  if git -C "$FORK" diff --cached --quiet; then
    echo "nothing to commit (fork already matches BSP $BSP_SRC)"
  else
    git -C "$FORK" commit -q -m "$MSG"
    echo "committed: $(git -C "$FORK" log -1 --oneline)"
  fi
fi
