#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""fastload_elf.py: copy a Zephyr ELF so it loads faster over UART-TSI.

The copy differs from the input in one 8-byte field: p_memsz of the single PT_LOAD is set
equal to p_filesz. Code, addresses, sections and symbols (so tohost/fromhost) are unchanged.

fesvr (inside uart_tsi) sends the zero-fill tail [filesz, memsz) of every PT_LOAD over the
UART (riscv-isa-sim fesvr/elfloader.cc:70-72), so load time is
memsz * 1.0195 / (baud / 10) seconds. Zephyr clears .bss itself at boot (z_prep_c ->
arch_bss_zero(), arch/riscv/core/prep_c.c, arch/common/init.c) and noinit is not expected to
be zero, so the tail can be dropped. Side effect: noinit (and .bss before z_prep_c) holds
whatever DRAM contained when you rerun without a power cycle.

Guards (on failure: message on stderr, exit 1, nothing written):
  1. ELF64, little-endian, EM_RISCV.
  2. Exactly one PT_LOAD, so "the tail" is unambiguous.
  3. vaddr == paddr (fesvr loads at p_paddr, symbols are vaddr).
  4. __bss_start and __bss_end exist and lie within [vaddr+filesz, vaddr+memsz], which shows
     the Zephyr .bss clear covers what is dropped.
  5. Every allocated section overlapping the tail is SHT_NOBITS.
  6. tohost and fromhost, if present, lie inside [vaddr, vaddr+filesz), because the host
     expects them initialised.
  7. memsz == filesz is a no-op: exit 0 and the output is a plain copy, so after any exit 0
     the output exists and is loadable.
The output path must differ from the input path.

Usage: fastload_elf.py [--check] [-o OUT] [-q] IN.elf   (default OUT: <stem>.fast.elf)
  --check  report guards, bytes saved and load times; write nothing.
Exit codes: 0 ok or nothing to do, 1 guard refused, 2 usage or unreadable/unsupported file.

References: riscv-isa-sim fesvr/elfloader.cc:70-72; System V ABI "ELF-64 Object File
Format" v1.5; RISC-V ELF psABI. Standard library only, so it runs wherever the bundle is built.
"""
import argparse
import os
import shutil
import struct
import sys

PT_LOAD = 1
SHT_SYMTAB, SHT_NOBITS = 2, 8
SHF_ALLOC = 2
EM_RISCV = 243
BAUDS = (115200, 921600)
OVERHEAD = 1.0195   # TSI framing: 20-byte header per 1 KiB chunk (fesvr tsi.h:41)


class Refused(Exception):
    pass


def load_secs(nbytes, baud):
    return nbytes * OVERHEAD / (baud / 10)


def fmt_t(s):
    return (f'{s:.1f} s' if s < 10 else f'{s:.0f} s') if s < 120 else (f'{s / 60:.1f} min' if s < 7200 else f'{s / 3600:.1f} h')


def analyse(d):
    """Check all guards on the ELF bytes d. Returns (phdr_off, filesz, memsz, notes); raises Refused."""
    if len(d) < 64 or d[:4] != b'\x7fELF':
        raise Refused('not an ELF file')
    if d[4] != 2 or d[5] != 1:
        raise Refused('guard 1: not ELF64 little-endian')
    (e_machine,) = struct.unpack_from('<H', d, 0x12)
    if e_machine != EM_RISCV:
        raise Refused(f'guard 1: e_machine {e_machine} is not RISC-V ({EM_RISCV})')
    e_phoff, e_shoff = struct.unpack_from('<QQ', d, 0x20)
    e_phentsize, e_phnum, e_shentsize, e_shnum = struct.unpack_from('<HHHH', d, 0x36)
    if e_phentsize != 56 or e_shentsize != 64:
        raise Refused('unexpected ELF64 header entry sizes')
    if e_phoff + e_phnum * 56 > len(d) or e_shoff + e_shnum * 64 > len(d):
        raise Refused('truncated ELF (headers beyond end of file)')

    loads = []
    for i in range(e_phnum):
        off = e_phoff + i * 56
        (p_type,) = struct.unpack_from('<I', d, off)
        if p_type == PT_LOAD:
            p_off, vaddr, paddr, filesz, memsz = struct.unpack_from('<QQQQQ', d, off + 8)
            loads.append((off, p_off, vaddr, paddr, filesz, memsz))
    if len(loads) != 1:
        raise Refused(f'guard 2: expected exactly one PT_LOAD, found {len(loads)}')
    off, p_off, vaddr, paddr, filesz, memsz = loads[0]
    if vaddr != paddr:
        raise Refused(f'guard 3: vaddr {vaddr:#x} != paddr {paddr:#x}')
    if p_off + filesz > len(d):
        raise Refused('truncated ELF (segment data beyond end of file)')
    if memsz < filesz:
        raise Refused(f'p_memsz {memsz:#x} < p_filesz {filesz:#x}: malformed')
    tail_lo, tail_hi = vaddr + filesz, vaddr + memsz

    secs = []
    for i in range(e_shnum):
        s = e_shoff + i * 64
        sh_type, sh_flags, sh_addr, sh_off, sh_size, sh_link = struct.unpack_from('<IQQQQI', d, s + 4)
        secs.append((sh_type, sh_flags, sh_addr, sh_off, sh_size, sh_link, s))

    # section names, for messages
    (e_shstrndx,) = struct.unpack_from('<H', d, 0x3e)

    def sec_name(idx):
        try:
            nm_off = struct.unpack_from('<I', d, secs[idx][6])[0]
            base = secs[e_shstrndx][3]
            end = d.index(b'\0', base + nm_off)
            return d[base + nm_off:end].decode('ascii', 'replace')
        except (IndexError, ValueError, struct.error):
            return f'#{idx}'

    # symbols
    syms = {}
    for (t, _, _, o, size, link, _) in secs:
        if t != SHT_SYMTAB:
            continue
        str_off = secs[link][3]
        for k in range(size // 24):
            st_name, _info, _other, _shndx, st_value, _sz = struct.unpack_from('<IBBHQQ', d, o + k * 24)
            if st_name:
                end = d.index(b'\0', str_off + st_name)
                syms.setdefault(d[str_off + st_name:end].decode('ascii', 'replace'), st_value)
    for need in ('__bss_start', '__bss_end'):
        if need not in syms:
            raise Refused(f'guard 4: symbol {need} not found (stripped ELF, or not a Zephyr image)')
    bs, be = syms['__bss_start'], syms['__bss_end']
    if filesz != memsz and not (tail_lo <= bs <= be <= tail_hi):
        raise Refused(f'guard 4: bss {bs:#x}..{be:#x} is not inside the zero-fill tail '
                      f'{tail_lo:#x}..{tail_hi:#x}')

    notes = []
    for idx, (t, fl, addr, _o, size, _l, _s) in enumerate(secs):
        if not (fl & SHF_ALLOC) or size == 0:
            continue
        if addr < tail_hi and addr + size > tail_lo and t != SHT_NOBITS:
            raise Refused(f'guard 5: section {sec_name(idx)} ({addr:#x}+{size:#x}) overlaps the '
                          f'zero-fill tail {tail_lo:#x}..{tail_hi:#x} but is not NOBITS')
        if addr >= tail_lo and addr + size <= tail_hi and t == SHT_NOBITS:
            notes.append(sec_name(idx))
    for h in ('tohost', 'fromhost'):
        if h in syms and not (vaddr <= syms[h] < tail_lo):
            raise Refused(f'guard 6: {h} at {syms[h]:#x} is outside the file-backed part '
                          f'{vaddr:#x}..{tail_lo:#x}')
    return off, filesz, memsz, notes


def main(argv=None):
    ap = argparse.ArgumentParser(description='Write a copy of a Zephyr ELF with p_memsz = p_filesz '
                                 '(skip the .bss/noinit zero-fill over UART-TSI).')
    ap.add_argument('elf')
    ap.add_argument('-o', '--out', help='output (default: <input stem>.fast.elf next to the input)')
    ap.add_argument('--check', action='store_true', help='only report; write nothing')
    ap.add_argument('-q', '--quiet', action='store_true', help='no summary line on success')
    a = ap.parse_args(argv)
    out = a.out or os.path.splitext(a.elf)[0] + '.fast.elf'
    try:
        with open(a.elf, 'rb') as fh:
            d = bytearray(fh.read())
    except OSError as e:
        print(f'fastload_elf: cannot read {a.elf}: {e}', file=sys.stderr)
        return 2
    try:
        off, filesz, memsz, notes = analyse(bytes(d))
    except Refused as e:
        print(f'fastload_elf: REFUSED {a.elf}: {e}', file=sys.stderr)
        return 1
    except (struct.error, ValueError, IndexError) as e:
        print(f'fastload_elf: cannot parse {a.elf}: {e}', file=sys.stderr)
        return 2

    saved = memsz - filesz
    if saved == 0:
        msg = f'{a.elf}: memsz == filesz, nothing to do'
        if not a.check:
            if os.path.abspath(out) != os.path.abspath(a.elf):
                shutil.copyfile(a.elf, out)
                msg += f' (copied to {out})'
        if not a.quiet:
            print(msg)
        return 0
    times = ', '.join(f'{b}: {fmt_t(load_secs(memsz, b))} -> {fmt_t(load_secs(filesz, b))}' for b in BAUDS)
    summary = (f'{a.elf}: tail {"+".join(notes) or "zero-fill"} = {saved} B saved '
               f'(memsz {memsz} -> filesz {filesz}); est. load @ {times}')
    if a.check:
        print('OK (check only) ' + summary)
        return 0
    if os.path.abspath(out) == os.path.abspath(a.elf):
        print('fastload_elf: REFUSED: output would overwrite the input', file=sys.stderr)
        return 1
    # p_memsz is at +40 in Elf64_Phdr (type4 flags4 offset8 vaddr8 paddr8 filesz8 memsz8 align8)
    struct.pack_into('<Q', d, off + 40, filesz)
    tmp = out + '.tmp'
    with open(tmp, 'wb') as fh:
        fh.write(d)
    shutil.copymode(a.elf, tmp)
    os.replace(tmp, out)
    if not a.quiet:
        print(f'wrote {out}: ' + summary.split(': ', 1)[1])
    return 0


if __name__ == '__main__':
    sys.exit(main())
