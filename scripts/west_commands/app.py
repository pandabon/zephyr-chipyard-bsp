# SPDX-License-Identifier: Apache-2.0
"""`west app`: a thin wrapper over `west build` and scripts/run_tests.py.

Each action runs one or two `west build` / `scripts/run_tests.py` commands and prints them
first. Plain directories of .c/.cpp files are built through cmake/plain_app/, which is
ordinary CMake and also works without this command.
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from west.commands import WestCommand

BSP_DIR = Path(__file__).resolve().parents[2]
PLAIN_APP = BSP_DIR / 'cmake' / 'plain_app'
TEMPLATE = BSP_DIR / 'template' / 'app'
DEFAULT_BOARD = 'chipyard_penguin/penguin'

DESCRIPTION = f"""\
Front door for building and running programs on a Chipyard SoC under Zephyr.

  west app new   PATH               create an app from the template
  west app build PATH               build a Zephyr app dir OR a plain dir of .c/.cpp
  west app run   [PATH]             run the built ELF on Spike (exit status = program's)
  west app test  [run_tests.py args]  run the whole BSP suite on Spike
  west app menuconfig [PATH]        Kconfig UI for the build
  west app dump  [PATH]             disassemble the ELF to <build>/zephyr/zephyr.dump
  west app clean [PATH]             delete the build directory

PATH is a directory. With a CMakeLists.txt it is built as a normal Zephyr app; otherwise
every .c/.cpp/.S under it is compiled by the wrapper app ({PLAIN_APP.relative_to(BSP_DIR)}),
using an optional prj.conf from that directory.

The build directory defaults to ./build/<basename of PATH>; override with -d. The board
defaults to {DEFAULT_BOARD}. Unrecognised options are passed to cmake (after `--`).
Examples:
  west app new ~/labs/blink && west app build ~/labs/blink && west app run ~/labs/blink
  west app build ~/baremetal/app -p -S some-snippet -D CONFIG_FOO=y
"""


class App(WestCommand):
    def __init__(self):
        super().__init__('app', 'create, build, run and test apps on the Chipyard SoC',
                         DESCRIPTION, accepts_unknown_args=True)

    def do_add_parser(self, parser_adder):
        p = parser_adder.add_parser(self.name, help=self.help,
                                    formatter_class=argparse.RawDescriptionHelpFormatter,
                                    description=self.description)
        sub = p.add_subparsers(dest='action', metavar='<action>')

        def common(sp, path=True, board=True):
            if path:
                sp.add_argument('path', nargs='?', default='.', help='app or plain directory (default: .)')
            sp.add_argument('-d', '--build-dir', help='build directory (default: ./build/<name of PATH>)')
            if board:
                sp.add_argument('-b', '--board', default=DEFAULT_BOARD,
                                help='board target (default: %(default)s)')

        sp = sub.add_parser('new', help='create an app from the template')
        sp.add_argument('path', help='directory to create (must not exist or be empty)')
        sp.add_argument('--name', help='project name (default: directory name)')

        sp = sub.add_parser('build', help='build a Zephyr app or a plain C/C++ directory')
        common(sp)
        sp.add_argument('-p', '--pristine', action='store_true', help='wipe the build dir first')
        sp.add_argument('-S', '--snippet', action='append', default=[], help='snippet (repeatable)')
        sp.add_argument('-o', '--conf', action='append', default=[], metavar='FILE',
                        help='extra Kconfig fragment (repeatable; EXTRA_CONF_FILE)')
        sp.add_argument('--overlay', action='append', default=[], metavar='FILE',
                        help='extra devicetree overlay (repeatable)')
        sp.add_argument('-D', dest='defs', action='append', default=[], metavar='VAR=VAL',
                        help='cmake definition, e.g. -D CONFIG_FOO=y (repeatable)')

        sp = sub.add_parser('run', help='run the built ELF on Spike (exit status propagates)')
        common(sp, board=False)
        sp = sub.add_parser('menuconfig', help='Kconfig UI for the build')
        common(sp, board=False)
        sp = sub.add_parser('dump', help='disassemble the ELF')
        common(sp, board=False)
        sp.add_argument('-S', '--source', action='store_true', help='interleave source (objdump -S)')
        sp.add_argument('--stdout', action='store_true', help='print instead of writing zephyr.dump')
        sp = sub.add_parser('clean', help='delete the build directory')
        common(sp, board=False)

        sp = sub.add_parser('test', help='run the BSP test suite (scripts/run_tests.py)')
        sp.add_argument('-b', '--board', default=DEFAULT_BOARD)
        return p

    # -- helpers -----------------------------------------------------------
    def _run(self, cmd, **kw):
        self.inf('+ ' + ' '.join(str(c) for c in cmd))
        r = subprocess.run([str(c) for c in cmd], **kw)
        return r

    def _west(self, *args):
        return [sys.executable, '-m', 'west', *args]

    def _build_dir(self, args):
        if args.build_dir:
            return Path(args.build_dir).resolve()
        name = Path(args.path).resolve().name
        return Path('build').resolve() / name

    def _need_build_dir(self, args):
        bd = self._build_dir(args)
        if not (bd / 'CMakeCache.txt').is_file():
            self.die(f"no build in {bd}; run `west app build {args.path}` first (or pass -d)")
        return bd

    def do_run(self, args, unknown):
        if not args.action:
            self.parser.print_help()
            return
        getattr(self, '_sim' if args.action == 'run' else '_' + args.action)(args, unknown)

    # -- actions -----------------------------------------------------------
    def _new(self, args, unknown):
        dest = Path(args.path)
        if dest.exists() and any(dest.iterdir()):
            self.die(f'{dest} exists and is not empty')
        name = args.name or dest.resolve().name
        name = ''.join(c if c.isalnum() else '_' for c in name)
        for src in TEMPLATE.rglob('*'):
            if src.is_dir():
                continue
            out = dest / src.relative_to(TEMPLATE)
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(src.read_text().replace('project(my_app)', f'project({name})'))
        self.inf(f'created {dest} (project "{name}"). Next:\n'
                 f'  west app build {dest}\n  west app run {dest}')

    def _build(self, args, unknown):
        src = Path(args.path).resolve()
        if not src.is_dir():
            self.die(f'{src} is not a directory')
        bd = self._build_dir(args)
        cmake_args = []
        if (src / 'CMakeLists.txt').is_file():
            app = src
            self.inf(f'{src}: Zephyr app (has CMakeLists.txt)')
        else:
            app = PLAIN_APP
            cmake_args.append(f'-DPLAIN_APP_DIR={src}')
            self.inf(f'{src}: plain directory, using {PLAIN_APP}')
        if args.conf:
            cmake_args.append('-DEXTRA_CONF_FILE=' + ';'.join(str(Path(c).resolve()) for c in args.conf))
        if args.overlay:
            cmake_args.append('-DEXTRA_DTC_OVERLAY_FILE=' + ';'.join(str(Path(c).resolve()) for c in args.overlay))
        cmake_args += [f'-D{d}' for d in args.defs] + unknown
        cmd = self._west('build', '-b', args.board, '-d', bd)
        if args.pristine:
            cmd += ['-p', 'always']
        for s in args.snippet:
            cmd += ['-S', s]
        cmd.append(app)
        if cmake_args:
            cmd += ['--'] + cmake_args
        if self._run(cmd).returncode:
            self.die('build failed', exit_code=1)
        self.inf(f'built: {bd}/zephyr/zephyr.elf   next: west app run {args.path}')

    def _sim(self, args, unknown):
        bd = self._need_build_dir(args)
        rc = self._run(self._west('build', '-d', bd, '-t', 'run')).returncode
        self.inf(f'simulator exit status: {rc}')
        sys.exit(rc)

    def _menuconfig(self, args, unknown):
        bd = self._need_build_dir(args)
        sys.exit(self._run(self._west('build', '-d', bd, '-t', 'menuconfig')).returncode)

    def _dump(self, args, unknown):
        bd = self._need_build_dir(args)
        elf = bd / 'zephyr' / 'zephyr.elf'
        if not elf.is_file():
            self.die(f'{elf} missing; build first')
        objdump = None
        for line in (bd / 'CMakeCache.txt').read_text().splitlines():
            if line.startswith('CMAKE_OBJDUMP:'):
                objdump = line.split('=', 1)[1]
        objdump = objdump or shutil.which('riscv64-zephyr-elf-objdump')
        if not objdump:
            self.die('objdump not found (source env.sh?)')
        cmd = [objdump, '-d'] + (['-S'] if args.source else []) + [str(elf)]
        if args.stdout:
            sys.exit(self._run(cmd).returncode)
        out = bd / 'zephyr' / 'zephyr.dump'
        with open(out, 'w') as f:
            rc = self._run(cmd, stdout=f).returncode
        self.inf(f'wrote {out}')
        sys.exit(rc)

    def _clean(self, args, unknown):
        bd = self._build_dir(args)
        if not (bd / 'CMakeCache.txt').is_file():
            self.die(f'{bd} does not look like a build directory; not deleting')
        shutil.rmtree(bd)
        self.inf(f'removed {bd}')

    def _test(self, args, unknown):
        # run_tests.py stands in for `west twister`, which aborts on the fork's Spike
        # platform schema (patches/zephyr/0004). Extra args go to it unchanged.
        cmd = [sys.executable, BSP_DIR / 'scripts' / 'run_tests.py',
               '--board', args.board] + unknown
        sys.exit(self._run(cmd).returncode)
