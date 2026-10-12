#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Tests for scripts/fastload_elf.py. Not in run_tests.py; run by hand:

    (west, the Zephyr SDK and spike on PATH)
    tests/scripts/fastload/test_fastload.py [--build-root ../build]

It builds samples/hello_rvv and tests/arch/rvv/vlen (a ztest) into <build-root>/fastload-*
(skipped if already built), then checks:
  1. the rewritten ELF differs from the original ONLY in the 8-byte p_memsz field
     (byte diff), and p_memsz == p_filesz afterwards;
  2. the guards refuse crafted inputs and write nothing: two PT_LOADs, missing bss symbol,
     tohost beyond filesz, a PROGBITS section in the tail, bss outside the tail, wrong machine;
     --check writes nothing; an already-trimmed ELF is copied unchanged (exit 0);
  3. Spike still boots the rewritten hello_rvv and the ztest and they PASS (exit 0).
     Spike RAM starts zeroed, so this does not cover dirty memory left by a previous
     program; that needs hardware.
Exit 0 = all pass.
"""
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BSP = os.path.realpath(os.path.join(HERE, '..', '..', '..'))
SCRIPT = os.path.join(BSP, 'scripts', 'fastload_elf.py')
BUILD_ROOT = os.path.realpath(os.path.join(BSP, '..', 'build'))
APPS = {'fastload-hello': 'samples/hello_rvv', 'fastload-vlen': 'tests/arch/rvv/vlen'}
ELFS = {}


def rd(p):
    with open(p, 'rb') as fh:
        return fh.read()


def run(*a, **kw):
    return subprocess.run(a, capture_output=True, text=True, **kw)


def build(name):
    bd = os.path.join(BUILD_ROOT, name)
    elf = os.path.join(bd, 'zephyr', 'zephyr.elf')
    if not os.path.exists(elf):
        r = run('west', 'build', '-p', 'auto', '-b', 'chipyard_penguin/penguin', '-d', bd,
                os.path.join(BSP, APPS[name]))
        assert r.returncode == 0, r.stdout[-2000:] + r.stderr[-2000:]
    return bd, elf


def parse(d):
    """Minimal independent parse for the test: returns dict of offsets we patch."""
    phoff, shoff = struct.unpack_from('<QQ', d, 0x20)
    phnum, shnum, shstr = struct.unpack_from('<HxxHH', d, 0x38)
    ph = [phoff + i * 56 for i in range(phnum)]
    secs = {}
    for i in range(shnum):
        s = shoff + i * 64
        secs[i] = s
    names = {}
    stroff = struct.unpack_from('<Q', d, shoff + shstr * 64 + 24)[0]
    for i, s in secs.items():
        n = struct.unpack_from('<I', d, s)[0]
        names[d[stroff + n:d.index(b'\0', stroff + n)].decode()] = s
    return ph, names


def find_sym(d, name):
    """(offset of st_value field, value) of symbol name."""
    _, secs = parse(d)
    sh = secs['.symtab']
    off, size, link = struct.unpack_from('<QQI', d, sh + 24)
    stroff = struct.unpack_from('<Q', d, sh_off_of_link(d, link) + 24)[0]
    for k in range(size // 24):
        n, = struct.unpack_from('<I', d, off + k * 24)
        if n and d[stroff + n:d.index(b'\0', stroff + n)].decode() == name:
            return off + k * 24 + 8, struct.unpack_from('<Q', d, off + k * 24 + 8)[0]
    raise KeyError(name)


def sh_off_of_link(d, idx):
    shoff, = struct.unpack_from('<Q', d, 0x28)
    return shoff + idx * 64


class Fastload(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix='fastload_test_')
        cls.elf = ELFS['fastload-hello']
        cls.d = rd(cls.elf)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def craft(self, name, mutate):
        d = bytearray(self.d)
        mutate(d)
        p = os.path.join(self.tmp, name + '.elf')
        with open(p, 'wb') as fh:
            fh.write(d)
        return p

    def refused(self, path, needle):
        out = path[:-4] + '.fast.elf'
        r = run(sys.executable, SCRIPT, path)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(needle, r.stderr)
        self.assertFalse(os.path.exists(out), 'refusal must write nothing')

    # ---- 1. only p_memsz changes
    def test_only_memsz_changes(self):
        out = os.path.join(self.tmp, 'h.fast.elf')
        r = run(sys.executable, SCRIPT, '-o', out, self.elf)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('saved', r.stdout)
        new = rd(out)
        self.assertEqual(len(new), len(self.d))
        ph, _ = parse(self.d)
        load = [p for p in ph if struct.unpack_from('<I', self.d, p)[0] == 1][0]
        diff = [i for i in range(len(new)) if new[i] != self.d[i]]
        self.assertTrue(diff, 'nothing changed')
        self.assertTrue(all(load + 40 <= i < load + 48 for i in diff), f'bytes outside p_memsz differ: {diff[:8]}')
        filesz, memsz = struct.unpack_from('<QQ', self.d, load + 32)
        self.assertGreater(memsz, filesz)
        self.assertEqual(struct.unpack_from('<Q', new, load + 40)[0], filesz)
        self.assertEqual(os.stat(out).st_mode & 0o777, os.stat(self.elf).st_mode & 0o777)

    def test_default_output_name_and_summary(self):
        p = self.craft('named', lambda d: None)
        r = run(sys.executable, SCRIPT, p)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.exists(os.path.join(self.tmp, 'named.fast.elf')))
        self.assertRegex(r.stdout, r'115200: .* -> .*921600: ')

    def test_check_writes_nothing(self):
        p = self.craft('chk', lambda d: None)
        r = run(sys.executable, SCRIPT, '--check', p)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, 'chk.fast.elf')))

    def test_already_trimmed_copies(self):
        p = self.craft('tr', lambda d: None)
        self.assertEqual(run(sys.executable, SCRIPT, p).returncode, 0)
        f = os.path.join(self.tmp, 'tr.fast.elf')
        o2 = os.path.join(self.tmp, 'tr2.elf')
        r = run(sys.executable, SCRIPT, '-o', o2, f)
        self.assertEqual(r.returncode, 0)
        self.assertIn('nothing to do', r.stdout)
        self.assertEqual(rd(o2), rd(f))

    def test_refuses_overwrite_of_input(self):
        p = self.craft('same', lambda d: None)
        r = run(sys.executable, SCRIPT, '-o', p, p)
        self.assertEqual(r.returncode, 1)

    # ---- 2. guards
    def test_two_pt_loads(self):
        def m(d):  # turn the PT_TLS header into a second PT_LOAD
            ph, _ = parse(bytes(d))
            tls = [p for p in ph if struct.unpack_from('<I', d, p)[0] == 7][0]
            struct.pack_into('<I', d, tls, 1)
        self.refused(self.craft('two_load', m), 'exactly one PT_LOAD')

    def test_no_pt_load(self):
        def m(d):
            ph, _ = parse(bytes(d))
            for p in ph:
                if struct.unpack_from('<I', d, p)[0] == 1:
                    struct.pack_into('<I', d, p, 0)
        self.refused(self.craft('no_load', m), 'exactly one PT_LOAD')

    def test_missing_bss_symbol(self):
        def m(d):  # rename __bss_start in .strtab (same length)
            i = -1
            while (i := d.find(b'__bss_start\0', i + 1)) >= 0:
                d[i:i + 11] = b'__bss_stxrt'
        self.refused(self.craft('no_bss_sym', m), '__bss_start not found')

    def test_tohost_beyond_filesz(self):
        def m(d):
            off, _ = find_sym(bytes(d), 'tohost')
            struct.pack_into('<Q', d, off, 0x80009000)
        self.refused(self.craft('tohost_out', m), 'tohost')

    def test_fromhost_beyond_filesz(self):
        def m(d):
            off, _ = find_sym(bytes(d), 'fromhost')
            struct.pack_into('<Q', d, off, 0x80009000)
        self.refused(self.craft('fromhost_out', m), 'fromhost')

    def test_progbits_in_tail(self):
        def m(d):  # make the noinit section PROGBITS (type 1)
            _, names = parse(bytes(d))
            struct.pack_into('<I', d, names['noinit'] + 4, 1)
        self.refused(self.craft('progbits_tail', m), 'not NOBITS')

    def test_bss_outside_tail(self):
        def m(d):
            off, _ = find_sym(bytes(d), '__bss_start')
            struct.pack_into('<Q', d, off, 0x80000100)  # inside file-backed data
        self.refused(self.craft('bss_in_file', m), 'zero-fill tail')

    def test_wrong_machine(self):
        def m(d):
            struct.pack_into('<H', d, 0x12, 62)
        self.refused(self.craft('x86', m), 'not RISC-V')

    def test_not_an_elf(self):
        p = os.path.join(self.tmp, 'junk.elf')
        with open(p, 'wb') as fh:
            fh.write(b'hello' * 100)
        self.refused(p, 'not an ELF')

    # ---- 3. Spike still boots / passes
    def spike_run(self, name):
        bd = os.path.join(BUILD_ROOT, name)
        isa = re.search(r'^SPIKE_ISA:INTERNAL=(.*)$', rd(os.path.join(bd, 'CMakeCache.txt')).decode(), re.M).group(1)
        out = os.path.join(self.tmp, name + '.fast.elf')
        r = run(sys.executable, SCRIPT, '-o', out, ELFS[name])
        self.assertEqual(r.returncode, 0, r.stderr)
        r = run('timeout', '120', 'spike', f'--isa={isa}', out)
        return r

    def test_spike_hello_rvv(self):
        r = self.spike_run('fastload-hello')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('Booting Zephyr', r.stdout + r.stderr)

    def test_spike_ztest_vlen(self):
        r = self.spike_run('fastload-vlen')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('PROJECT EXECUTION SUCCESSFUL', r.stdout + r.stderr)


if __name__ == '__main__':
    if '--build-root' in sys.argv:
        i = sys.argv.index('--build-root')
        BUILD_ROOT = os.path.realpath(sys.argv[i + 1])
        del sys.argv[i:i + 2]
    for n in APPS:
        ELFS[n] = build(n)[1]
    unittest.main(verbosity=2)
