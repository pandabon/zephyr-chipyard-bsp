#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Load prebuilt ELFs onto the chip through the bring-up FPGA with uart_tsi and log the
# output. Needs only bash and uart_tsi.
#
#   ./bench.sh check                 # link check with probes/{dram,clint,spad}.elf; CPU not started
#   ./bench.sh run 02_hello_rvv      # one ELF (with or without .elf)
#   ./bench.sh all                   # every *.elf in this directory, in order
#
# Env: TTY (required, e.g. /dev/ttyUSB1), UART_TSI (default: uart_tsi on PATH),
#      BAUD (default 921600; vcu118_ta/ gets 115200), TIMEOUT seconds per run (default 120,
#      600 for ctx_switch), CHECK_TIMEOUT seconds per probe (default 20),
#      FASTLOAD=1 loads <name>.fast.elf when present (p_memsz = p_filesz, so the .bss zeros
#      are not sent over the UART; see scripts/fastload_elf.py). Off by default.
# The link check is adapted from the course Baremetal-IDE `make checktsi`
# (https://github.com/ucb-ee194-tapeout/Baremetal-IDE).
#
# clocal is set before uart_tsi starts: its open() has no O_NONBLOCK and waits for carrier
# detect after a USB replug (testchip_uart_tsi.cc:49). Output goes through a pty (`script`)
# so uart_tsi's block-buffered stdout survives the `timeout` kill.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
: "${TTY:?set TTY, e.g. TTY=/dev/ttyUSB1 (ls /dev/ttyUSB* before/after replugging)}"
UART_TSI="${UART_TSI:-uart_tsi}"
BAUD="${BAUD:-921600}"   # make_bench_bundle.sh rewrites this to 115200 in vcu118_ta/
[ -n "${TIMEOUT:-}" ] && TIMEOUT_SET=1
TIMEOUT="${TIMEOUT:-120}"
LOGS="$HERE/logs-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
command -v "$UART_TSI" >/dev/null || { echo "uart_tsi not found (set UART_TSI=/path/to/uart_tsi)"; exit 2; }
echo "tty=$TTY baud=$BAUD uart_tsi=$(command -v "$UART_TSI")"

# stty opens non-blocking, so it can set clocal before uart_tsi's blocking open().
# Only warn on failure (missing stty, non-tty path).
stty -F "$TTY" clocal 2>/dev/null || echo "warning: 'stty -F $TTY clocal' failed; uart_tsi may block in open()"

# tsi_run <timeout-s> <uart_tsi args...>: returns uart_tsi's exit status (124 = timeout).
# Runs on a pty via util-linux `script -e`; on a plain pipe the block-buffered stdout is
# lost when `timeout` kills it. Falls back to a pipe if `script` is missing.
tsi_run() {
  local t="$1"; shift
  if command -v script >/dev/null; then
    local cmd; printf -v cmd '%q ' "$UART_TSI" "$@"
    timeout -k 5 "$t" script -qfec "$cmd" /dev/null </dev/null
  else
    timeout -k 5 "$t" "$UART_TSI" "$@" </dev/null
  fi
}

# pick_elf <elf>: the file to load; <name>.fast.elf if FASTLOAD=1 and it exists.
# Messages go to stderr so $(...) captures only the path.
pick_elf() {
  local elf="$1" fast="${1%.elf}.fast.elf"
  if [ "${FASTLOAD:-0}" = 1 ]; then
    if [ -f "$fast" ]; then echo "$fast"; return; fi
    echo "FASTLOAD=1 but no $(basename "$fast"): loading the full $(basename "$elf")" >&2
  fi
  echo "$elf"
}

run_one() {
  local elf="$1" name; name="$(basename "$elf" .elf)"
  local load; load="$(pick_elf "$elf")"
  # ctx_switch is the slowest ELF; give it more time unless TIMEOUT is set.
  local t="$TIMEOUT"
  if [ -z "${TIMEOUT_SET:-}" ]; then case "$name" in *ctx_switch*) t=600 ;; esac; fi
  echo "=== $name  ($(date +%T))" | tee -a "$LOGS/summary.txt"
  echo "    loading: $(basename "$load")$([ "$load" != "$elf" ] && echo '  (FASTLOAD: .bss/noinit zeros not sent)')" | tee -a "$LOGS/summary.txt"
  tsi_run "$t" +tty="$TTY" +baudrate="$BAUD" "$load" 2>&1 | tee "$LOGS/$name.log"
  local rc=${PIPESTATUS[0]}
  case $rc in
    0)   res=PASS ;;
    124) res="TIMEOUT(${t}s)" ;;
    *)   res="FAIL(rc=$rc)" ;;
  esac
  echo "    -> $res" | tee -a "$LOGS/summary.txt"
}

case "${1:-}" in
  check)
    # Load a probe ELF and read it back (+selfcheck) without starting the CPU
    # (+no_hart0_msip). Baremetal-IDE's `+init_write/+init_read ... none` form is a no-op
    # with this fesvr (htif.cc:85-99, testchip_tsi.cc:53-57); see scripts/probes/probe.S.
    # DRAM goes first. If CLINT and the scratchpad answer but DRAM does not, the link is fine.
    pd="$HERE/probes"; [ -d "$pd" ] || { echo "no probes/ next to bench.sh"; exit 2; }
    ct="${CHECK_TIMEOUT:-20}"; fails=0
    for p in dram clint spad; do
      [ -f "$pd/$p.elf" ] || { echo "probe $p: missing $pd/$p.elf" | tee -a "$LOGS/check.txt"; fails=1; continue; }
      tsi_run "$ct" +tty="$TTY" +baudrate="$BAUD" +no_hart0_msip +selfcheck "$pd/$p.elf" \
        >"$LOGS/check-$p.log" 2>&1
      rc=$?
      if [ $rc = 0 ] && grep -q 'Performing self check.*Done' "$LOGS/check-$p.log" \
         && ! grep -q 'Self check failed' "$LOGS/check-$p.log"; then res=PASS
      elif [ $rc = 124 ]; then res="FAIL (timeout ${ct}s: no reply)"
      else res="FAIL (rc=$rc: $(grep -m1 -E 'Self check failed|rror' "$LOGS/check-$p.log" | tr -d '\r'))"; fi
      [ "$res" = PASS ] || fails=1
      printf '%-6s %s\n' "$p" "$res" | tee -a "$LOGS/check.txt"
    done
    echo "link check: $([ $fails = 0 ] && echo 'all PASS' || echo 'FAILED (see check-*.log)')"
    [ $fails = 0 ] || { echo "logs: $LOGS"; exit 1; } ;;
  run)
    elf="$HERE/${2%.elf}.elf"; [ -f "$elf" ] || { echo "no such ELF: $elf"; exit 2; }
    run_one "$elf" ;;
  all)
    for elf in "$HERE"/*.elf; do
      case "$elf" in *.fast.elf) continue ;; esac   # only loaded with FASTLOAD=1
      run_one "$elf"
    done
    echo; cat "$LOGS/summary.txt" ;;
  *)
    sed -n '2,15p' "$0"; exit 2 ;;
esac
echo "logs: $LOGS"
