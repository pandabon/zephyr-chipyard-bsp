# SPDX-License-Identifier: Apache-2.0
"""west runner "spike": debug a Zephyr ELF on Spike through OpenOCD.

    gdb  --(GDB remote, :3333)-->  OpenOCD  --(remote_bitbang, :9824)-->  Spike

This is Zephyr's `openocd` runner plus starting Spike first and killing it afterwards:

  * west debugserver : Spike + OpenOCD; attach gdb yourself.
  * west debug       : Spike + OpenOCD + gdb (Spike has already loaded the ELF).
  * west attach      : like debug, without `load`.

All openocd runner options still apply. Registered through `runners:` in
zephyr/module.yml.
"""

import shutil
import signal
import subprocess
import threading
import time

from runners.core import RunnerCaps
from runners.openocd import OpenOcdBinaryRunner

DEFAULT_RBB_PORT = 9824
DEFAULT_START_TIMEOUT = 10.0


def _raise_interrupt(signum, frame):
    raise KeyboardInterrupt()


class SpikeBinaryRunner(OpenOcdBinaryRunner):
    '''Spike (rbb) + OpenOCD + gdb.'''

    def __init__(self, cfg, spike='spike', isa=None, rbb_port=DEFAULT_RBB_PORT,
                 spike_args=None, start_timeout=DEFAULT_START_TIMEOUT,
                 no_halted=False, **openocd_kwargs):
        super().__init__(cfg, **openocd_kwargs)
        self.spike = spike
        self.isa = isa
        self.rbb_port = rbb_port
        self.spike_args = spike_args or []
        self.start_timeout = start_timeout
        self.halted = not no_halted
        self.spike_proc = None

    @property
    def thread_info_enabled(self):
        # The stock runner passes `-rtos Zephyr` for CONFIG_DEBUG_THREAD_INFO=y, but OpenOCD's
        # Zephyr support (src/rtos/zephyr.c) aborts on a riscv target with "Could not find
        # target in Zephyr compatibility list" (OpenOCD 0.12.0 and master).
        return False

    @classmethod
    def name(cls):
        return 'spike'

    @classmethod
    def capabilities(cls):
        # Spike loads the ELF itself.
        return RunnerCaps(commands={'debug', 'debugserver', 'attach'})

    @classmethod
    def do_add_parser(cls, parser):
        super().do_add_parser(parser)
        parser.add_argument('--spike', default='spike',
                            help='spike binary (default: from -DSPIKE/$SPIKE/PATH at build time)')
        parser.add_argument('--isa', help='Spike --isa string (derived from Kconfig by CMake)')
        parser.add_argument('--rbb-port', type=int, default=DEFAULT_RBB_PORT,
                            help=f'TCP port Spike listens on for OpenOCD (default {DEFAULT_RBB_PORT})')
        parser.add_argument('--spike-arg', action='append', default=[],
                            help='extra argument for Spike, repeatable (e.g. --spike-arg=-m0x80000000:0x4000000)')
        parser.add_argument('--spike-start-timeout', type=float, default=DEFAULT_START_TIMEOUT,
                            help=f'seconds to wait for Spike to listen (default {DEFAULT_START_TIMEOUT:g})')
        parser.add_argument('--no-halted', action='store_true',
                            help='do not pass --halted: Spike starts running the program at once')

    @classmethod
    def do_create(cls, cfg, args):
        return SpikeBinaryRunner(
            cfg, spike=args.spike, isa=args.isa, rbb_port=args.rbb_port,
            spike_args=args.spike_arg, start_timeout=args.spike_start_timeout,
            no_halted=args.no_halted,
            pre_init=args.cmd_pre_init, reset_halt_cmd=args.cmd_reset_halt,
            pre_load=args.cmd_pre_load, erase_cmd=args.cmd_erase, load_cmd=args.cmd_load,
            verify_cmd=args.cmd_verify, post_verify=args.cmd_post_verify,
            do_verify=args.verify, do_verify_only=args.verify_only, do_erase=args.erase,
            tui=args.tui, config=args.config, serial=args.serial,
            use_elf=args.use_elf, no_halt=args.no_halt, no_init=args.no_init,
            no_targets=args.no_targets, tcl_port=args.tcl_port,
            telnet_port=args.telnet_port, gdb_port=args.gdb_port,
            gdb_client_port=args.gdb_client_port, gdb_init=args.gdb_init,
            no_load=args.no_load, target_handle=args.target_handle,
            rtt_port=args.rtt_port, rtt_server=args.rtt_server)

    # -- Spike lifecycle --------------------------------------------------

    def _check_openocd(self):
        # The SDK's OpenOCD lacks remote_bitbang and its own error is a long adapter list.
        exe = self.openocd_cmd[0]
        self.require(exe)
        out = self.check_output([exe, '-c', 'adapter list', '-c', 'shutdown'],
                                stderr=subprocess.STDOUT).decode()
        if 'remote_bitbang' not in out:
            raise RuntimeError(
                f'{exe} was built without remote_bitbang, which Spike debugging needs. '
                'Build OpenOCD with --enable-remote-bitbang and pass it with '
                '--openocd=PATH (or -DSPIKE_OPENOCD / $SPIKE_OPENOCD at build time). '
                'See README.md, "Debugging".')

    def _start_spike(self):
        if shutil.which(self.spike) is None:
            raise RuntimeError(
                f'Spike not found ({self.spike!r}): set SPIKE=/path/to/spike (then reconfigure) '
                'or pass --spike=PATH, or run setup with --with-spike.')
        if self.elf_name is None:
            raise ValueError('Cannot debug; no .elf specified')
        cmd = [self.spike]
        if self.isa:
            cmd.append(f'--isa={self.isa}')
        cmd.append(f'--rbb-port={self.rbb_port}')
        if self.halted:
            cmd.append('--halted')
        cmd += self.spike_args + [self.elf_name]

        self.logger.info(f'Starting Spike (rbb port {self.rbb_port}): ' + ' '.join(cmd))
        self.spike_proc = self.popen_ignore_int(cmd, stdout=subprocess.PIPE,
                                          stderr=subprocess.STDOUT, text=True)

        # Spike accepts one rbb client, so do not probe the port by connecting. Wait for its
        # "Listening for remote bitbang connection" banner instead. Spike's output, including
        # the HTIF console, is relayed to west's log with a "spike: " prefix.
        listening = threading.Event()

        def pump():
            for line in self.spike_proc.stdout:
                if 'Listening' in line:
                    listening.set()
                self.logger.info('spike: ' + line.rstrip())

        threading.Thread(target=pump, daemon=True).start()
        deadline = time.monotonic() + self.start_timeout
        while not listening.wait(0.1):
            if self.spike_proc.poll() is not None:
                raise RuntimeError(
                    f'Spike exited (status {self.spike_proc.returncode}) before listening; '
                    f'is port {self.rbb_port} already in use? Try --rbb-port.')
            if time.monotonic() > deadline:
                raise RuntimeError(f'Spike did not listen within {self.start_timeout:g}s')

    def _stop_spike(self):
        p = self.spike_proc
        if p is None or p.poll() is not None:
            return
        p.terminate()
        try:
            p.wait(5)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()

    def do_run(self, command, **kwargs):
        self._check_openocd()
        # Make SIGTERM/SIGHUP unwind through `finally` like Ctrl-C, so Spike is not orphaned.
        for sig in (signal.SIGTERM, getattr(signal, 'SIGHUP', None)):
            if sig is not None:
                signal.signal(sig, _raise_interrupt)
        try:
            self._start_spike()
            # Passes the port to the OpenOCD config; this -c comes before the -f config.
            self.openocd_cmd += ['-c', f'set SPIKE_RBB_PORT {self.rbb_port}']
            super().do_run(command, **kwargs)
        finally:
            self._stop_spike()
