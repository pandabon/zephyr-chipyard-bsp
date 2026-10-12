#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Stand-in for Chipyard's `uart_tsi`, for testing the west runner without hardware.
Pass it with --uart-tsi.

Checks the argument shape the runner must produce
    uart_tsi +tty=<dev> +baudrate=<n> [+plusargs...] <elf>
reads the ELF header, prints a fake console line and exits with $STUB_EXIT (default 0).
With +selfcheck and +no_hart0_msip (the runner's --check) it prints fesvr-style selfcheck
lines and exits 0. A "none" program or +init_read is rejected: that form is a no-op because
fesvr's htif.cc start() skips reset(). Arguments are appended to $STUB_LOG if set.
"""
import os
import sys

args = sys.argv[1:]
if os.environ.get('STUB_LOG'):
    with open(os.environ['STUB_LOG'], 'a') as f:
        f.write(' '.join(args) + '\n')

plus = [a for a in args if a.startswith('+')]
pos = [a for a in args if not a.startswith('+')]
opts = dict(a[1:].partition('=')[::2] for a in plus)


def die(msg):
    print(f'stub uart_tsi: {msg}', file=sys.stderr)
    sys.exit(64)


if 'tty' not in opts or not opts['tty']:
    die('missing +tty=')
if not opts.get('baudrate', '').isdigit():
    die('missing/invalid +baudrate=')
if len(pos) != 1:
    die(f'expected exactly one ELF (or "none"), got {pos}')

if 'init_read' in opts or pos[0] == 'none':
    die('the +init_read / "none" probe is a no-op with this fesvr; use an ELF + +selfcheck')

try:
    with open(pos[0], 'rb') as f:
        hdr = f.read(64)
        if hdr[:4] != b'\x7fELF':
            die(f'{pos[0]} is not an ELF')
        # A --fastload image must have p_memsz == p_filesz in its PT_LOAD.
        # Elf64_Phdr: filesz at +32, memsz at +40.
        if pos[0].endswith('.fast.elf'):
            import struct
            phoff, = struct.unpack_from('<Q', hdr, 0x20)
            phnum, = struct.unpack_from('<H', hdr, 0x38)
            f.seek(phoff)
            for _ in range(phnum):
                ph = f.read(56)
                if struct.unpack_from('<I', ph)[0] == 1:
                    fsz, msz = struct.unpack_from('<QQ', ph, 32)
                    if fsz != msz:
                        die(f'{pos[0]}: PT_LOAD memsz {msz} != filesz {fsz}, not a fast-load image')
except OSError as e:
    die(str(e))

if 'selfcheck' in opts:
    if 'no_hart0_msip' not in opts:
        die('check mode needs +no_hart0_msip')
    print(f'UART-TSI: Loading ELF {pos[0]} ... Done')
    print('UART-TSI: Performing self check of region ... Done')
    sys.exit(0)

print(f"[stub] loaded {pos[0]} over {opts['tty']} @ {opts['baudrate']} baud; hart0 kicked")
print('*** Booting Zephyr OS build (stub console) ***')
code = int(os.environ.get('STUB_EXIT', '0'))
print(f'[stub] HTIF exit code {code}')
sys.exit(code)
