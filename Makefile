# SPDX-License-Identifier: Apache-2.0
#
# Thin wrappers around west and the other tools. make builds nothing itself; each target
# echoes the command it runs. `make help` lists the equivalent west command for each.
#
# Target names and variable style (TTY=, BINARY, "make tsi-run/checktsi") are borrowed
# from Baremetal-IDE's Makefile (https://github.com/ucb-ee194-tapeout/Baremetal-IDE).

SHELL := /bin/bash
.DEFAULT_GOAL := help

BSP := $(CURDIR)
WS  := $(abspath $(BSP)/..)

# ---- variables (all can be given on the command line: make build APP=...) -----
BOARD      ?= chipyard_penguin/penguin
APP        ?=
# APP is a sample/test dir (has CMakeLists.txt), a plain folder of .c/.cpp files, or a
# sample name such as hello_rvv (= samples/hello_rvv).
APP_DIR    := $(if $(APP),$(if $(wildcard $(APP)/.),$(abspath $(APP)),$(if $(wildcard $(BSP)/samples/$(APP)/.),$(BSP)/samples/$(APP),$(abspath $(APP)))))
APP_NAME   := $(notdir $(APP_DIR))
BUILD      ?= $(WS)/build/$(APP_NAME)
TTY        ?= $(UART_TSI_TTY)
BAUD       ?=
UART_TSI   ?=
SNIPPET    ?=
EXTRA_CONF ?=
CMAKE_ARGS ?=
ARGS       ?=
JOBS       ?= 8
OUT        ?=

# west's "manifest" project points at one BSP checkout. When building from another checkout
# (a git worktree), tell Zephyr which module dir to use.
MANIFEST_BSP := $(shell west list -f '{abspath}' manifest 2>/dev/null | head -1)
ifneq ($(realpath $(MANIFEST_BSP)),$(realpath $(BSP)))
ifneq ($(MANIFEST_BSP),)
MODULES_OVERRIDE ?= $(BSP)
endif
endif

# a folder without CMakeLists.txt builds through cmake/plain_app
ifeq ($(wildcard $(APP_DIR)/CMakeLists.txt),)
SRC_DIR    := $(BSP)/cmake/plain_app
PLAIN_ARGS := -DPLAIN_APP_DIR=$(APP_DIR)
else
SRC_DIR    := $(APP_DIR)
endif
CMAKE_FLAGS := $(PLAIN_ARGS) \
  $(if $(MODULES_OVERRIDE),-DZEPHYR_MODULES="$(MODULES_OVERRIDE)") \
  $(if $(EXTRA_CONF),-DEXTRA_CONF_FILE="$(EXTRA_CONF)") $(CMAKE_ARGS)

.PHONY: help build run flash debug test bundle clean need-env need-app

help:
	@echo "Chipyard Zephyr BSP: make front door (each target prints the command it runs)"
	@echo
	@echo "  target  what it does                              west / tool equivalent"
	@echo "  build   compile APP for BOARD                     west build -p auto -b BOARD -d BUILD SRC [-- -D..]"
	@echo "  run     build, then run on Spike (exit = program) west build -d BUILD -t run"
	@echo "  flash   build, load onto the chip via UART-TSI    west flash -d BUILD --tty TTY [--baud BAUD]"
	@echo "  debug   build, then gdb on Spike via OpenOCD      west debug -d BUILD   (build with SNIPPET=debug)"
	@echo "  test    the whole BSP suite on Spike              scripts/run_tests.py -j JOBS --board BOARD"
	@echo "  bundle  bench bundle of prebuilt ELFs             scripts/make_bench_bundle.sh [OUT]"
	@echo "  clean   delete APP's build dir                    rm -rf BUILD (only if it is a build dir)"
	@echo
	@echo "Variables (current value):"
	@echo "  APP=<dir|sample name>  sample dir, plain folder of .c/.cpp, or e.g. hello_rvv   [$(APP)]"
	@echo "  BOARD=                 e.g. chipyard_penguin/penguin/vcu118_ta                   [$(BOARD)]"
	@echo "  BUILD=                 build dir                  [default $(WS)/build/<app name>]"
	@echo "  TTY= BAUD=             flash only; /dev/ttyUSBn, baud (runner default 921600; vcu118_ta 115200)"
	@echo "  UART_TSI=              path to the uart_tsi tool (flash), else the runner searches PATH"
	@echo "  SNIPPET= EXTRA_CONF= CMAKE_ARGS= ARGS=   extra west snippet / Kconfig file / cmake -D / raw west args"
	@echo "  JOBS= (test)  OUT= (bundle dir)   Examples:"
	@echo "    make run APP=hello_rvv"
	@echo "    make run APP=template/app"
	@echo "    make build APP=~/labs/mine BOARD=chipyard_penguin/penguin/vcu118_ta"
	@echo "    make flash APP=hello_rvv TTY=/dev/ttyUSB1"
	@echo "    make test ARGS='-f bf16'      make -n bundle      ATLAS_UPSTREAM=1 make bundle"

need-env:
	@command -v west >/dev/null || { echo "error: west not found; install/activate west, the Zephyr SDK and Spike (see README.md)"; exit 2; }

need-app:
	@test -n "$(APP)" || { echo "error: set APP=<dir or sample name> (try: make help)"; exit 2; }
	@test -d "$(APP_DIR)" || { echo "error: APP '$(APP)' is not a directory"; exit 2; }

build: need-env need-app
	@echo "==> build $(APP_DIR) ($(if $(PLAIN_ARGS),plain folder via cmake/plain_app,Zephyr app)) for $(BOARD)"
	west build -p auto -b $(BOARD) -d $(BUILD) $(foreach s,$(SNIPPET),-S $(s)) $(ARGS) $(SRC_DIR) -- $(CMAKE_FLAGS)

run: build
	@echo "==> run on Spike (ISA string is derived from Kconfig)"
	west build -d $(BUILD) -t run

flash: build
	@test -n "$(TTY)" || { echo "error: set TTY=/dev/ttyUSBn (or export UART_TSI_TTY); see README.md"; exit 2; }
	@echo "==> load onto the chip through the bring-up FPGA with uart_tsi (nothing is persistent)"
	west flash -d $(BUILD) --tty $(TTY) $(if $(BAUD),--baud $(BAUD)) $(if $(UART_TSI),--uart-tsi $(UART_TSI)) $(ARGS)

debug: need-env need-app
	@test -f $(BUILD)/CMakeCache.txt || $(MAKE) --no-print-directory build APP=$(APP) SNIPPET="$(or $(SNIPPET),debug)"
	@echo "==> gdb on Spike via OpenOCD (needs SPIKE_OPENOCD with remote_bitbang, see README.md)"
	west debug -d $(BUILD) $(ARGS)

test: need-env
	@echo "==> whole BSP suite on Spike; ARGS='-f text' filters"
	scripts/run_tests.py -j $(JOBS) --board $(BOARD) $(ARGS)

bundle: need-env
	@echo "==> bench bundle (README.md, 'Bench bundle'); env knobs: ATLAS_UPSTREAM=1 VCU118=1 PATCHED_ZEPHYR=dir"
	scripts/make_bench_bundle.sh $(OUT)

clean: need-app
	@test -f $(BUILD)/CMakeCache.txt || { echo "error: $(BUILD) is not a build directory; not deleting"; exit 2; }
	rm -rf $(BUILD)
