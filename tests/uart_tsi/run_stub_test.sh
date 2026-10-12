#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Exercise the `uart_tsi` west runner against a stub (no hardware).
# Usage: tests/uart_tsi/run_stub_test.sh <build-dir>   (a built chipyard_penguin app)
# ZEPHYR_EXTRA_MODULES makes west use this checkout's runner when run from a git worktree.
set -u
B=${1:?build dir}
HERE=$(cd "$(dirname "$0")" && pwd)
STUB=$HERE/stub_uart_tsi.py
export ZEPHYR_EXTRA_MODULES=$(cd "$HERE/../.." && pwd)
export STUB_LOG=$(mktemp)
fail=0
t() { # name expected_rc cmd...
  local name=$1 want=$2; shift 2
  "$@" >/tmp/uart_tsi_t.out 2>&1; local rc=$?
  if [ "$rc" = "$want" ]; then echo "PASS $name (rc=$rc)"; else echo "FAIL $name rc=$rc want=$want"; cat /tmp/uart_tsi_t.out; fail=1; fi
}
F="west flash -d $B --skip-rebuild"
t "default runner, exit 0"        0 env STUB_EXIT=0 $F --uart-tsi $STUB --tty /dev/null
t "exit code 3 propagates"        3 env STUB_EXIT=3 $F --runner uart_tsi --uart-tsi $STUB --tty /dev/null
t "tty from env"                  0 env UART_TSI_TTY=/dev/null $F --uart-tsi $STUB
t "tool from env"                 0 env UART_TSI=$STUB $F --tty /dev/null
t "--check probe (builds ELF)"    0 $F --uart-tsi $STUB --tty /dev/null --check
# --fastload hands the stub <build>/zephyr.fast.elf; the default loads the original
t "--fastload loads the .fast.elf"  0 $F --uart-tsi $STUB --tty /dev/null --fastload
t "--fastload again (overwrites the copy)" 0 $F --uart-tsi $STUB --tty /dev/null --fastload
t "--fastload + --check unchanged" 0 $F --uart-tsi $STUB --tty /dev/null --check --fastload
# stty clocal runs only on a real tty: use a pty slave and a fake stty that logs its args
FAKEBIN=$(mktemp -d); printf '#!/bin/sh\necho "$@" >> %s\n' "$STUB_LOG.stty" > $FAKEBIN/stty; chmod +x $FAKEBIN/stty
t "stty clocal on a tty"          0 env PATH=$FAKEBIN:$PATH python3 -c '
import os,pty,subprocess,sys
m,s=pty.openpty(); n=os.ttyname(s)
sys.exit(subprocess.call(sys.argv[1:]+["--tty",n]))' west flash -d $B --skip-rebuild --uart-tsi $STUB
t "no stty for /dev/null"         0 env PATH=$FAKEBIN:$PATH $F --uart-tsi $STUB --tty /dev/null
grep -q -- '-F /dev/pts/[0-9]* clocal' "$STUB_LOG.stty" && [ "$(wc -l < "$STUB_LOG.stty")" = 1 ] \
  || { echo "FAIL: stty clocal not run exactly once, on the tty only"; cat "$STUB_LOG.stty" 2>&1; fail=1; }
rm -rf "$FAKEBIN" "$STUB_LOG.stty"
t "plusarg passthrough"           0 $F --uart-tsi $STUB --tty /dev/null -O +verbose -O foo=1
t "custom baud"                   0 $F --uart-tsi $STUB --tty /dev/null --baud 115200
t "missing --tty is an error"     1 env -u UART_TSI_TTY $F --uart-tsi $STUB
t "nonexistent tty is an error"   1 $F --uart-tsi $STUB --tty /dev/nonexistent
t "missing tool is an error"      1 $F --uart-tsi /nonexistent/uart_tsi --tty /dev/null
echo "--- args the stub received:"; cat "$STUB_LOG"
grep -q 'baudrate=921600' "$STUB_LOG" && grep -q 'baudrate=115200' "$STUB_LOG" \
  && grep -q '+verbose +foo=1' "$STUB_LOG" && grep -q -- '+no_hart0_msip +selfcheck /.*dram.elf' "$STUB_LOG" \
  || { echo "FAIL: stub log missing expected args"; fail=1; }
grep -q -- 'zephyr\.fast\.elf' "$STUB_LOG" || { echo "FAIL: --fastload did not hand the .fast.elf to uart_tsi"; fail=1; }
[ "$(grep -c -- 'zephyr\.elf' "$STUB_LOG")" -ge 1 ] || { echo "FAIL: default run did not load zephyr.elf"; fail=1; }
rm -f "$STUB_LOG"
exit $fail
