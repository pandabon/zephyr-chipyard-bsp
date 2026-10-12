# zephyr-chipyard-bsp

Zephyr board support for the Penguin SoC (UC Berkeley EE194 Sp26 tapeout: Shuttle RV64 core, Saturn RVV
unit with VLEN 256, Atlas NPU). It is an out-of-tree Zephyr module (`chipyard-bsp`) plus a west manifest
that pins the [ucb-bar Zephyr fork](https://github.com/ucb-bar/zephyr) at `852bb170cc5`.

## Targets

| Board target | Runs on |
|---|---|
| `chipyard_penguin/penguin` | the chip (through an FPGA, UART-TSI at 921600 baud) and Spike |
| `chipyard_penguin/penguin/vcu118_ta` | the TA's VCU118 build of the Penguin RTL (50 MHz, UART-TSI at 115200 baud) |
| `chipyard_penguin/penguin/vcu118` | generic Chipyard VCU118 flow (SD-card boot, UART console); cannot run on Spike |

## Layout

```
boards/      board variants (board.cmake, devicetree per variant, OpenOCD configs)
soc/         Penguin SoC: ISA selection (Kconfig), timer, sim exit
dts/         penguin.dtsi and bindings (ucb-bar,shuttle, ucb-bar,atlas)
cmake/       spike.cmake (the `run` target), uart_tsi.cmake, plain_app/ (build a folder of .c files)
scripts/     runners (spike, uart_tsi), run_tests.py, bench.sh, make_bench_bundle.sh, fastload_elf.py, west app
samples/     hello_rvv, hw_probe, atlas_smoke, atlas_kernels, atlas_upstream
tests/       RVV, BF16, thread context switch, plain apps, debug and runner checks
snippets/    `debug` (-Og, frame pointers, asserts) and `single-cpu`
template/    starting point for your own app
patches/     proposed fixes for the Zephyr fork (see Patches)
Makefile     wrappers that print the west command they run
west.yml     west manifest
```

## Setup

The repo is the west manifest repository. Clone it into an empty directory and let west fetch the Zephyr
fork:

```sh
mkdir bringup && cd bringup
git clone https://github.com/pandabon/zephyr-chipyard-bsp     # adjust the URL if the repo lives elsewhere
west init -l zephyr-chipyard-bsp
west update                                                   # creates ./zephyr
```

The layout must be `bringup/{zephyr-chipyard-bsp, zephyr}`; the Makefile builds into `bringup/build/<app>`.

Nothing is installed by this repo. You need:

- **Zephyr SDK 1.0.0-beta1** (GCC 14.3, binutils 2.43), the only version tested. The ISA string in
  `soc/chipyard/penguin/Kconfig` relies on GCC 14.3 accepting `_zvfbfmin`. Get it from the
  [Zephyr SDK releases](https://github.com/zephyrproject-rtos/sdk-ng/releases).
- **Python 3 with west and the Zephyr requirements:** `pip install west pyyaml` and
  `pip install -r zephyr/scripts/requirements.txt`. `scripts/run_tests.py` needs `pyyaml`.
- **Spike** with V at VLEN 256 plus `zicntr`, `zfh`, `zba/zbb/zbs`, `zvfh`, `zfbfmin`, `zvfbfa`.
  `cmake/spike.cmake` derives the `--isa` string from Kconfig and `boards/chipyard/penguin/board.cmake`
  adds the extensions the compiler does not take. Tested with
  [riscv-isa-sim](https://github.com/riscv-software-src/riscv-isa-sim) at `609dbe0b` (1.1.1-dev) or newer.
  Put `spike` on `PATH` or set `SPIKE=/path/to/spike`.
- **OpenOCD built with `--enable-remote-bitbang`**, only for `west debug` on Spike (the SDK's lacks it).
  Set `SPIKE_OPENOCD`.
- **`uart_tsi`**, only for hardware: the host tool from the testchipip/Chipyard build. Put it on `PATH`, set
  `UART_TSI=/path`, or pass `--uart-tsi`.
- Optional, for the Atlas samples: `BRINGUP_CHIPYARD` (to regenerate the `atlas_smoke` kernels) and
  `TAPEOUT_CHIPYARD` (the course tapeout repo, needed to build `atlas_upstream`).

An example `env.sh` (adjust the paths):

```sh
export ZEPHYR_SDK_INSTALL_DIR=$HOME/tools/zephyr-sdk-1.0.0-beta1
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
export ZEPHYR_BASE=$HOME/bringup/zephyr
export PATH=$HOME/tools/spike/bin:$ZEPHYR_SDK_INSTALL_DIR/gnu/riscv64-zephyr-elf/bin:$PATH
export SPIKE_OPENOCD=$HOME/tools/openocd-spike/bin/openocd        # west debug only
export UART_TSI=$HOME/bringup-chipyard/.conda-env/riscv-tools/bin/uart_tsi   # hardware only
export BRINGUP_CHIPYARD=$HOME/bringup-chipyard                    # optional
export TAPEOUT_CHIPYARD=$HOME/tapeout-chipyard                    # optional
# if Spike's shared libraries are not on the default path: export LD_LIBRARY_PATH=$HOME/tools/spike/lib
```

Activate your Python environment too, so `west` is on `PATH`.

## Quick start

From `zephyr-chipyard-bsp/` with the environment set up:

```sh
make run APP=hello_rvv                          # build and run on Spike; exit code = the program's
make run APP=path/to/folder-of-c-files          # compiles every .c/.cpp; main()'s return value is the exit code
make test                                       # whole suite on Spike
make flash APP=hello_rvv TTY=/dev/ttyUSB0       # load onto the chip over UART-TSI (BOARD=..., BAUD=... for variants)
make debug APP=hello_rvv                        # debug build, then gdb on Spike through OpenOCD
make help                                       # all targets and variables
```

Each `make` target prints the `west` command it runs. `west app new|build|run|test|dump|clean` does the same
without make (`west app -h`). `template/app` is a minimal app to copy.

**Testing.** `make test ARGS='-f bf16'` filters by name or tag; `scripts/run_tests.py --list` lists the
scenarios. On a full workspace the result is `PASS=21 FAIL=0 SKIP=14 XFAIL=3`. The three XFAIL are in
`tests/known_failures.yaml`: the RVV context-switch bug, lazy V switching, and a negative test. Scenarios for
other board variants are skipped unless you pass `--board`, and scenarios that need `TAPEOUT_CHIPYARD`
(`atlas_upstream`) are skipped when it is absent.

**Hardware.** `make flash` runs `west flash` with the `uart_tsi` runner. It loads the ELF through the FPGA and
keeps running as the HTIF console proxy; nothing is persistent. `TTY` is the serial port that carries
UART-TSI, not the JTAG (FT-LINK) port. Use `BAUD=115200` with `BOARD=chipyard_penguin/penguin/vcu118_ta`.
`west flash --check` probes the link without starting the core. `--fastload` loads a copy of the ELF whose
`.bss` is not sent over the UART (`scripts/fastload_elf.py` lists the guards).

## Bench bundle

`make bundle` (`scripts/make_bench_bundle.sh [OUT_DIR]`) builds a folder and tarball of prebuilt ELFs for a
bench machine that has only `bash` and `uart_tsi`. It contains the chip set (`chipyard_penguin/penguin`), a
`vcu118_ta/` set, link probes, `bench.sh`, a `MANIFEST.txt` (failed builds are listed there) and a generated
`README-bench.md`.

```sh
export TTY=/dev/ttyUSB1          # required; compare `ls /dev/ttyUSB*` before and after replugging
./bench.sh check                 # link check: writes and reads back words, CPU not started
./bench.sh run 02_hello_rvv      # one ELF
./bench.sh all                   # every ELF in order; logs-<timestamp>/summary.txt
```

Run-time knobs: `BAUD` (921600 for the chip, 115200 in `vcu118_ta/`), `TIMEOUT` (seconds per run),
`UART_TSI`, and `FASTLOAD=1` (load the `.fast.elf` copies). Build-time knobs: `ATLAS_UPSTREAM=1`, `VCU118=1`,
`PATCHED_ZEPHYR=<dir>|none`, `VCU118_TA=0`. `hello_world`, `timer` and `test_mt_rvv` come from the course's
`zephyr-chipyard-sw` repo; set `LAB_SW=` to a checkout, otherwise those ELFs are skipped and noted in the
manifest. The `*_patched` ctx_switch ELF applies `patches/zephyr/*.patch` to a copy of `../zephyr`.

## Atlas samples

All three are build-only on Spike, which has no Atlas model, and are meant for hardware or RTL simulation.
Their output lines start with `ATLAS`.

- `samples/atlas_smoke`: raw Atlas register access, one step per line so the last line shows where a hang
  happened, plus three small kernels (`k_ecall`, `k_vmem`, `k_illegal`). The `.bin` and `.h` files are
  tracked; `regen_kernels.py` rebuilds them with the Atlas team's assembler (`ATLAS_NPU_DIR`, or
  `BRINGUP_CHIPYARD`).
- `samples/atlas_kernels`: some of the Atlas team's host tests ported to Zephyr I/O with a timeout. The IMEM
  programs are copied from the course tapeout repo (credit in the file header).
- `samples/atlas_upstream`: builds the Atlas/Saturn team's tests unmodified from `$TAPEOUT_CHIPYARD/tests`,
  one scenario per test (`-DATLAS_TEST=<name>`, list in `tests.cmake`). Tests whose golden data needs python
  `torch` are not in the default list.

## Known issues

- **RVV context switch (fork bug).** A thread preempted by an interrupt has `vl`/`vtype` overwritten because
  the vector-state save runs twice, so vector code in preemptible threads can run with the wrong element width
  and length (register contents are intact). `patches/zephyr/0005-riscv-v-make-vstate-save-idempotent.patch`
  fixes it and is not applied, so `arch.riscv.rvv.ctx_switch` is an expected failure. The fork does not
  implement lazy V switching (`ctx_switch.lazy`, expected failure).
- **PLIC driver.** The Zephyr `sifive,plic-1.0.0` driver treats `riscv,ndev` as a count that includes source 0.
  The devicetree has the true value `ndev = 1`, so source 1 (the UART) would be rejected as spurious. The
  console is polled/HTIF, so nothing uses UART interrupts yet. Set `ndev = <2>` or fix the driver before using
  them.
- **Not run on silicon.** The suite is verified on Spike. On the TA's VCU118 bitstream the UART-TSI link works
  at 115200 baud, Zephyr boots with the HTIF console, and `hello_rvv` and the VLEN test pass; the rest of the
  bench set has not been run there. `boards/chipyard/penguin/support/openocd-ftlink.cfg` (JTAG) is untested.
- Spike does not model the 64 KiB scratchpad (`SCRATCHPAD` linker region) or Atlas.

## Patches

`patches/` holds proposed fixes for the Zephyr fork. `west update` does not apply them. Apply one with, for
example, `git -C ../zephyr apply patches/zephyr/0005-*.patch`.

- `0004-boards-spike-fix-twister-platform-schema.patch`: the fork's Spike/Chipyard board YAML fails twister's
  platform schema, which aborts `west twister` for every board. This is why `scripts/run_tests.py` exists.
- `0005-riscv-v-make-vstate-save-idempotent.patch`: the context-switch bug above.

`scripts/make_patched_zephyr.sh` applies `patches/zephyr/*.patch` to a copy of `../zephyr`; the bench bundle
uses it for the stock-versus-patched ctx_switch comparison.

## Credits

Builds on the [ucb-bar Zephyr fork](https://github.com/ucb-bar/zephyr) (RVV context switch, HTIF console),
[Chipyard](https://github.com/ucb-bar/chipyard) and testchipip (`uart_tsi`), the
[Spike](https://github.com/riscv-software-src/riscv-isa-sim) ISA simulator, the course's
[Baremetal-IDE](https://github.com/ucb-ee194-tapeout/Baremetal-IDE) (front-end UX, the `checktsi` idea), and
the Atlas and Saturn teams' bring-up tests in the course tapeout repo (`atlas_kernels`, `atlas_upstream`).
Per-file credits are in the source headers.

## License

Apache-2.0, see [LICENSE](LICENSE). Files derived from other projects keep their credit in the header. The
Atlas test programs reproduced by `atlas_kernels` come from the course tapeout repo's `tests/`, which has no
per-file licence header; check reuse terms with the Atlas team before redistributing them outside the course.
