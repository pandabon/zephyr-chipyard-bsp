#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Non-interactive check of the debug chain (Spike -> OpenOCD -> gdb).
#   tests/debug/smoke.sh <build-dir built with -S debug>
# Needs west, gdb and spike on PATH, and an OpenOCD with remote_bitbang
# (SPIKE_OPENOCD=/path/to/openocd). Exit 0 if every expected pattern was found.
set -u
BUILD=${1:?usage: smoke.sh <build-dir>}
LOG=$(mktemp)
G=(--gdb-init='set pagination off' --gdb-init='set confirm off')
timeout "${SMOKE_TIMEOUT:-90}" west debug -d "$BUILD" --skip-rebuild "${G[@]}" \
  ${SMOKE_PORT_ARGS:-} \
  --gdb-init='info registers pc sp' \
  --gdb-init='break main' --gdb-init='continue' --gdb-init='bt' \
  --gdb-init='info registers pc sp a0' \
  --gdb-init='print/x $vlenb' --gdb-init='info registers vlenb' \
  --gdb-init='print/x $mstatus' \
  --gdb-init='set $mstatus = $mstatus & ~8' \
  --gdb-init='next' --gdb-init='next' --gdb-init='next' --gdb-init='next' \
  --gdb-init='stepi' --gdb-init='x/i $pc' --gdb-init='info registers pc' \
  --gdb-init='set $mstatus = $mstatus | 8' \
  --gdb-init='break 41' --gdb-init='continue' --gdb-init='info locals' \
  --gdb-init='quit' </dev/null >"$LOG" 2>&1
rc=$?
sed -n '/^Remote debugging/,$p' "$LOG"
fail=0
for pat in 'Breakpoint 1, main' 'vlenb +0x20' '=> 0x'; do
  grep -Eq "$pat" "$LOG" || { echo "MISSING: $pat"; fail=1; }
done
if pgrep -x 'spike|openocd' >/dev/null; then echo "LEAKED spike/openocd"; fail=1; fi
rm -f "$LOG"
echo "west rc=$rc fail=$fail"
exit $((fail || rc))
