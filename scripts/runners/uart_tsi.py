# SPDX-License-Identifier: Apache-2.0

"""West runner `uart_tsi`: load a Zephyr ELF onto a Chipyard chip behind a bring-up FPGA
with Chipyard's `uart_tsi` host tool.

uart_tsi speaks TSI over the FPGA's UART, writes the ELF into DRAM, sets hart 0's MSIP, then
stays running as the HTIF proxy: it prints the console and exits with the target's HTIF exit
code. So "flash" means load, run and watch; nothing is persistent. Registered through
`runners:` in zephyr/module.yml.

uart_tsi does not write BootAddrReg (pyuartsi does). Its only boot action is the CLINT MSIP
write in testchip_tsi_t::reset() -> tsi_t::reset(), skipped by +no_hart0_msip
(chipyard generators/testchipip/src/main/resources/testchipip/csrc/testchip_tsi.cc:52-57,
testchip_htif.cc:20).
"""

import os
import shutil
import stat
import subprocess
import sys
import tempfile

from runners.core import FileType, RunnerCaps, ZephyrBinaryRunner

DEFAULT_BAUD = 921600  # lab value; uart_tsi's own default (115200) is too slow
DEFAULT_TOOL = 'uart_tsi'
TTY_ENV = 'UART_TSI_TTY'
TOOL_ENV = 'UART_TSI'

# --check loads a 16-byte data-only ELF at DRAM 0x8000_1000 (scripts/probes/probe.S) with
# +selfcheck, which reads back what it wrote; +no_hart0_msip keeps the hart stopped.
# Baremetal-IDE's `make checktsi` form (`+init_write=... +init_read=... none`) never touches
# the link: fesvr's htif_t::start() skips reset() for the program "none"
# (riscv-isa-sim fesvr/htif.cc:85-99) and reset() runs the init accesses
# (testchipip csrc/testchip_tsi.cc:53-57).
CHECK_ARGS = ['+no_hart0_msip', '+selfcheck']
PROBES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'probes')
# --fastload loads a copy of the ELF with p_memsz = p_filesz, so fesvr does not send the
# .bss/noinit zeros (Zephyr clears .bss itself in z_prep_c). See scripts/fastload_elf.py.
FASTLOAD_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'fastload_elf.py')


class UartTsiBinaryRunner(ZephyrBinaryRunner):
    """Runner that execs Chipyard's uart_tsi host binary."""

    def __init__(self, cfg, tty, baud, tool, check, extra, fastload=False):
        super().__init__(cfg)
        self.tty = tty
        self.baud = baud
        self.tool = tool
        self.check = check
        self.extra = extra
        self.fastload = fastload

    @classmethod
    def name(cls):
        return 'uart_tsi'

    @classmethod
    def capabilities(cls):
        # tool_opt: -O passes +plusargs to uart_tsi; file: --file overrides the ELF.
        return RunnerCaps(commands={'flash'}, tool_opt=True, file=True)

    @classmethod
    def do_add_parser(cls, parser):
        parser.add_argument('--tty', default=os.environ.get(TTY_ENV),
                            help=f'serial device wired to the FPGA UART-TSI port, '
                                 f'e.g. /dev/ttyUSB1 (default: ${TTY_ENV}). '
                                 f'Not the FT-LINK port.')
        parser.add_argument('--baud', type=int, default=DEFAULT_BAUD,
                            help=f'UART-TSI baud rate; must match the FPGA '
                                 f'bitstream (default: {DEFAULT_BAUD})')
        parser.add_argument('--uart-tsi', default=os.environ.get(TOOL_ENV),
                            help=f'path of the uart_tsi binary (default: '
                                 f'${TOOL_ENV}, then `{DEFAULT_TOOL}` on PATH)')
        parser.add_argument('--check', action='store_true',
                            help='probe the link instead of running the ELF: load a '
                                 '16-byte DRAM probe ELF with +selfcheck, hart '
                                 'not started (idea: Baremetal-IDE `make checktsi`)')
        parser.add_argument('--fastload', action='store_true',
                            help='load a copy of the ELF with p_memsz = p_filesz (made by '
                                 'scripts/fastload_elf.py into the build dir) so the .bss/noinit '
                                 'zeros are not sent over the UART; the original ELF is not '
                                 'changed. Refuses if the ELF fails the script\'s guards. '
                                 'Opt-in; ignored by --check')

    @classmethod
    def do_create(cls, cfg, args):
        if not args.tty:
            raise ValueError(f'--tty is required (or set ${TTY_ENV}); it is the '
                             f'serial port on the FPGA that carries UART-TSI')
        if args.baud <= 0:
            raise ValueError('--baud must be positive')
        return UartTsiBinaryRunner(cfg, args.tty, args.baud,
                                   args.uart_tsi or DEFAULT_TOOL,
                                   args.check, args.tool_opt or [], args.fastload)

    def _image(self):
        # fesvr loads through ELF headers, so reject a non-ELF --file_type.
        ft = self.cfg.file_type
        if self.cfg.file and ft not in (None, FileType.OTHER, FileType.ELF):
            raise RuntimeError(f'uart_tsi can only load ELF files, got {ft}')
        return self.cfg.file or self.cfg.elf_file

    def _fast_image(self, elf):
        # Writes <build dir>/<stem>.fast.elf (next to the ELF if it is outside the build dir).
        # If a guard refuses, fail instead of silently loading the full ELF.
        stem = os.path.splitext(os.path.basename(elf))[0]
        outdir = self.cfg.build_dir if self.cfg.build_dir and os.path.isdir(self.cfg.build_dir) \
            else os.path.dirname(os.path.abspath(elf))
        out = os.path.join(outdir, stem + '.fast.elf')
        r = subprocess.run([sys.executable, FASTLOAD_SCRIPT, '-o', out, elf],
                           capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError('--fastload: ' + (r.stderr or r.stdout).strip() +
                               ' (drop --fastload to load the full ELF)')
        self.logger.info(r.stdout.strip())
        return out

    def _plusarg(self, opt):
        # fesvr options are +name=value; accept "x=1" as well as "+x=1".
        return opt if opt.startswith('+') else '+' + opt

    def _build_probe(self, tmpdir):
        # Built at flash time with the SDK binutils, from the same probe.S and
        # build_probes.sh as the bench bundle.
        script = os.path.join(PROBES_DIR, 'build_probes.sh')
        r = subprocess.run(['bash', script, tmpdir, 'dram'], capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError('cannot build the DRAM probe ELF (needs '
                               'riscv64-zephyr-elf-as/ld: `source env.sh`): '
                               + (r.stderr or r.stdout).strip())
        return os.path.join(tmpdir, 'dram.elf')

    def _set_clocal(self):
        # uart_tsi opens the tty without O_NONBLOCK (testchipip uart_tsi/testchip_uart_tsi.cc:49),
        # so after a USB replug (-clocal) open() waits for carrier detect forever. stty opens
        # non-blocking and can set clocal first. Real ttys only; failure is a warning.
        try:
            fd = os.open(self.tty, os.O_RDWR | os.O_NONBLOCK | os.O_NOCTTY)
        except OSError as e:
            self.logger.warning('cannot open %s to check it is a tty: %s', self.tty, e)
            return
        try:
            is_tty = os.isatty(fd)
        finally:
            os.close(fd)
        if not (is_tty and stat.S_ISCHR(os.stat(self.tty).st_mode)):
            self.logger.debug('%s is not a tty, skipping stty clocal', self.tty)
            return
        try:
            r = subprocess.run(['stty', '-F', self.tty, 'clocal'], capture_output=True, text=True)
            err = r.stderr.strip() if r.returncode else ''
        except OSError as e:
            r, err = None, str(e)
        if err or r is None:
            self.logger.warning('`stty -F %s clocal` failed (%s); uart_tsi may block in open()',
                                self.tty, err)

    def _command(self, probe=None):
        tool = shutil.which(self.tool) if os.sep not in self.tool else self.tool
        if not tool or not os.access(tool, os.X_OK):
            raise RuntimeError(
                f"uart_tsi binary '{self.tool}' not found or not executable. "
                f"It is built by Chipyard (generators/testchipip/uart_tsi) and "
                f"is not shipped here: pass --uart-tsi <path> or set ${TOOL_ENV}.")
        cmd = [tool, f'+tty={self.tty}', f'+baudrate={self.baud}']
        cmd += [self._plusarg(o) for o in self.extra]
        if self.check:
            return cmd + CHECK_ARGS + [probe]
        elf = self._image()
        if not elf or not os.path.isfile(elf):
            raise RuntimeError(f'ELF to load not found: {elf}')
        if self.fastload:
            elf = self._fast_image(elf)
        return cmd + [elf]

    def do_run(self, command, **kwargs):
        if not os.path.exists(self.tty):
            raise RuntimeError(f'--tty {self.tty} does not exist')
        self._set_clocal()
        with tempfile.TemporaryDirectory(prefix='uart_tsi_probe_') as tmp:
            probe = self._build_probe(tmp) if self.check else None
            cmd = self._command(probe)
            self.logger.info('uart_tsi %s at %d baud', 'link check (DRAM probe, selfcheck)'
                             if self.check else f'load+run {self._image()}', self.baud)
            rc = self.call(cmd)
        if rc:
            # uart_tsi exits with the target's HTIF exit code, or non-zero on a link/ELF error.
            self.logger.error('uart_tsi exited with status %d', rc)
            sys.exit(rc)
