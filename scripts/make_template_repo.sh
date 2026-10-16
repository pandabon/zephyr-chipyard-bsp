#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Generate the starter repo for people who write programs for a Chipyard SoC with this BSP
# (the "zephyr-chipyard-app" repo). The repo is GENERATED from this BSP's template/ folder and
# mk/user.mk, so the BSP stays the single source of truth; nothing is maintained by hand twice.
#
#   scripts/make_template_repo.sh [--bsp-url URL] [--bsp-rev REV] [--force] <outdir>
#
#   --bsp-url  where west fetches the BSP from (default: https://github.com/pandabon/zephyr-chipyard-bsp)
#   --bsp-rev  branch, tag or SHA of the BSP to pin (default: main)
#   --force    write into a non-empty <outdir>
# Environment: BSP_URL, BSP_REV work as the options.
#
# What it writes into <outdir> (a git-less folder; `git init` it yourself):
#   west.yml        imports the BSP (import: true pulls in the Zephyr fork pin from the BSP's own west.yml)
#   Makefile        a few lines: finds the BSP with west, includes its mk/user.mk (make, make run, ...)
#   CMakeLists.txt  builds src/ through the BSP's plain_app core (any .c/.S in src/, main()'s return = exit code)
#   prj.conf        Kconfig for the app, with the common knobs commented
#   src/            from template/plain/   (main.c, vadd.S)
#   README.md, .gitignore
set -eu

BSP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
URL=${BSP_URL:-https://github.com/pandabon/zephyr-chipyard-bsp}
REV=${BSP_REV:-main}
FORCE=0
OUT=

while [ $# -gt 0 ]; do
  case $1 in
    --bsp-url) URL=$2; shift 2 ;;
    --bsp-rev) REV=$2; shift 2 ;;
    --force)   FORCE=1; shift ;;
    -h|--help) sed -n '2,/^set -eu/p' "$0" | sed 's/^# \{0,1\}//; /^set -eu/d'; exit 0 ;;
    -*) echo "error: unknown option $1" >&2; exit 2 ;;
    *)  OUT=$1; shift ;;
  esac
done
[ -n "$OUT" ] || { echo "usage: $0 [--bsp-url URL] [--bsp-rev REV] [--force] <outdir>" >&2; exit 2; }
for d in template/plain/src template/plain/prj.conf mk/user.mk; do
  [ -e "$BSP/$d" ] || { echo "error: $BSP/$d not found; is this the BSP?" >&2; exit 2; }
done
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT")" ] && [ "$FORCE" != 1 ]; then
  echo "error: $OUT is not empty (use --force to write into it)" >&2; exit 2
fi
mkdir -p "$OUT/src"

cat > "$OUT/west.yml" <<EOT
# SPDX-License-Identifier: Apache-2.0
# West manifest of this app repo. It pulls in the Chipyard BSP, and through the BSP's own
# west.yml the pinned Zephyr fork, so a user needs nothing else.
#   mkdir ws && cd ws && git clone <this repo> app && west init -l app && west update
manifest:
  projects:
    - name: chipyard-bsp          # the name the Makefile and CMake look for
      url: $URL
      path: zephyr-chipyard-bsp
      revision: $REV              # pin a tag or SHA for reproducible builds
      import: true
EOT

cat > "$OUT/Makefile" <<'EOT'
# SPDX-License-Identifier: Apache-2.0
# make              build this app for the Penguin SoC
# make run          build, then run on Spike (if installed)
# make doctor       check your tools;  make help  for everything
# The targets live in the BSP (mk/user.mk); this file only says where the BSP is.
BSP ?= $(shell west list -f '{abspath}' chipyard-bsp 2>/dev/null | head -1)
ifeq ($(BSP),)
$(error chipyard-bsp not found: run `west update` in the workspace, or set BSP=<dir>)
endif
APP ?= $(CURDIR)
DEFAULT_TARGET := build
include $(BSP)/mk/user.mk
EOT

cat > "$OUT/CMakeLists.txt" <<'EOT'
# SPDX-License-Identifier: Apache-2.0
#
# Builds every .c/.S in src/ as a Zephyr app through the BSP's "plain app" core: no CMake to
# write, and main()'s return value is the exit code. To add libraries, drivers or a normal
# Zephyr CMakeLists instead, replace this file with an ordinary Zephyr app (target_sources(app ...)).
cmake_minimum_required(VERSION 3.20.0)

# Where is the BSP? `make` exports CHIPYARD_BSP; plain `west build` asks west.
if(NOT CHIPYARD_BSP)
  set(CHIPYARD_BSP "$ENV{CHIPYARD_BSP}")
endif()
if(NOT CHIPYARD_BSP)
  execute_process(COMMAND west list -f {abspath} chipyard-bsp
                  OUTPUT_VARIABLE CHIPYARD_BSP OUTPUT_STRIP_TRAILING_WHITESPACE
                  WORKING_DIRECTORY ${CMAKE_CURRENT_LIST_DIR})
endif()
if(NOT EXISTS "${CHIPYARD_BSP}/cmake/plain_app/plain_app_pre.cmake")
  message(FATAL_ERROR "chipyard-bsp not found (CHIPYARD_BSP='${CHIPYARD_BSP}'). Run `west update`, or pass -DCHIPYARD_BSP=<dir>.")
endif()

set(PLAIN_APP_DIR ${CMAKE_CURRENT_LIST_DIR}/src)
include(${CHIPYARD_BSP}/cmake/plain_app/plain_app_pre.cmake)     # before find_package(Zephyr)
list(PREPEND EXTRA_CONF_FILE ${CMAKE_CURRENT_LIST_DIR}/prj.conf)  # this app's Kconfig
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(app)
include(${CHIPYARD_BSP}/cmake/plain_app/plain_app_post.cmake)    # after project()
EOT

cp "$BSP/template/plain/prj.conf" "$OUT/prj.conf"
cp "$BSP/template/plain/src/"* "$OUT/src/"

cat > "$OUT/.gitignore" <<'EOT'
build/
__pycache__/
EOT

cat > "$OUT/README.md" <<'EOT'
# zephyr-chipyard-app

A starting point for programs that run on a Chipyard SoC (first: the **Penguin** chip, a Shuttle RISC-V
core with a Saturn vector unit) using the [Chipyard Zephyr BSP](https://github.com/pandabon/zephyr-chipyard-bsp).
It has a small Zephyr program (`src/`).

## Get started

You need the [Zephyr SDK](https://github.com/zephyrproject-rtos/sdk-ng/releases) 1.0.0-beta1, Python >= 3.10
with `west`, `cmake` (below 4) and `ninja`. [Spike](https://github.com/riscv-software-src/riscv-isa-sim)
is optional: without it you can build, but not run.

```sh
mkdir ws && cd ws
git clone <this repo> app
west init -l app          # the workspace is ws/, this repo is its manifest
west update               # fetches the BSP and the Zephyr fork
cd app
make doctor               # tells you what is missing and how to fix it
make run                  # build and run on Spike (make alone only builds)
```

## What is here

| Path | What |
|---|---|
| `src/main.c`, `src/vadd.S` | Your program: C plus an assembly function called from it (a vector add). Every `.c`/`.S` in `src/` is built; `main()`'s return value is the exit code (0 = pass) |
| `prj.conf` | Zephyr settings. Common knobs are commented, e.g. `CONFIG_MAIN_STACK_SIZE` |
| `west.yml` | Pulls in the BSP (change `revision` to pin a tag or SHA) |
| `Makefile`, `CMakeLists.txt` | A few lines each; the real logic lives in the BSP |

## Commands

```sh
make                      # build src/ for chipyard_penguin/penguin
make run                  # ... and run it on Spike; the exit status is the program's
make debug                # gdb on Spike (needs an OpenOCD with remote_bitbang)
make BOARD=chipyard_penguin/penguin/vcu118_ta     # another board variant
make doctor               # check your setup
make help                 # all targets and variables
```

Every build ends with two lines: the path of the ELF and an example command to load it onto
hardware with `uart_tsi` (a loader that is not part of this repo).

## Environment

| Variable | Meaning |
|---|---|
| `ZEPHYR_SDK_INSTALL_DIR` | Zephyr SDK folder |
| `ZEPHYR_BASE` | the Zephyr checkout that `west update` created (`ws/zephyr`) |
| `SPIKE` | path to `spike` (else `spike` on `PATH`); `SPIKE_TIMEOUT`, `SPIKE_EXTRA_ARGS` also work |
| `WS`, `BSP` | workspace and BSP folders; normally found with `west` |

`make doctor` checks all of these.
EOT

echo "wrote $OUT (BSP: $URL @ $REV)"
echo "next: mkdir ws; move/clone it to ws/app; cd ws; west init -l app; west update; cd app; make doctor; make run"
