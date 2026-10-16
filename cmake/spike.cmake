# SPDX-License-Identifier: Apache-2.0
#
# SoC-agnostic helper: define the `run` / `run_custom` build targets that launch
# the built ELF on Spike. Include it from a board.cmake (path relative to the board dir):
#
#   include(${BOARD_DIR}/../../../cmake/spike.cmake)
#
# Spike is OPTIONAL: building never needs it. It is looked up with a soft find_program
# at configure time (like Zephyr's cmake/emu/qemu.cmake); if missing, configure still
# succeeds and only `run` fails, saying what to do.
#
# Spike binary (first hit wins): -DSPIKE=..., the SPIKE environment variable, `spike` on
# PATH. The result is baked into build.ninja: after changing $SPIKE or PATH, reconfigure
# (west build -p auto).
#
# Knobs (CMake variable, environment variable, or both):
#   SPIKE_TIMEOUT     seconds before a hung run is killed (default 120). Also read from
#                     the environment when `run` executes (scripts/run_tests.py relies on it).
#   SPIKE_EXTRA_ARGS  extra Spike arguments (space separated) placed before the ELF, e.g.
#                     "--extlib=x.so --device=y,0x1000". Baked via -D and also read from
#                     the environment when `run` executes. Plumbing only.
#
# The --isa string is derived from Kconfig (Spike 1.1 has no --varch; the vector length
# is the _zvl<N>b suffix): rv64i/rv32i, then m a f d c from RISCV_ISA_EXT_*, then v, then
# every enabled RISCV_ISA_EXT_Z* in the loop below, then _zvl<N>b from RISCV_VECTOR_MAX_LEN.
# Exit status is what the app passed to HTIF exit (see sim_exit.h); 0 = success.

set(SUPPORTED_EMU_PLATFORMS custom)

# -DSPIKE > env SPIKE > "spike". find_program also accepts a full path.
if(NOT SPIKE)
  if(DEFINED ENV{SPIKE})
    set(SPIKE $ENV{SPIKE})
  else()
    set(SPIKE spike)
  endif()
endif()
# find_program caches its result; forget it so a changed $SPIKE/PATH is seen.
unset(SPIKE_EXE CACHE)
find_program(SPIKE_EXE NAMES ${SPIKE})
if(SPIKE_EXE)
  set(_spike_cmd ${SPIKE_EXE})
else()
  set(_spike_cmd ${SPIKE})
endif()

if(CONFIG_64BIT)
  set(_spike_isa rv64i)
else()
  set(_spike_isa rv32i)
endif()
foreach(_e M A F D C)
  if(CONFIG_RISCV_ISA_EXT_${_e})
    string(TOLOWER ${_e} _l)
    string(APPEND _spike_isa ${_l})
  endif()
endforeach()
if(CONFIG_RISCV_ISA_EXT_V)
  string(APPEND _spike_isa v)
endif()
# Z* extensions: append `_<name>` for every enabled Zephyr ISA symbol, so Spike models
# what GCC was told via -march (Zephyr's cmake/compiler/gcc/target_riscv.cmake). Add a
# name here when adding a RISCV_ISA_EXT_Z* select. Zfh/Zfhmin and Zvfh/Zvfhmin are both
# listed on purpose: Spike accepts the superset implied by either.
foreach(_e ICNTR ICSR IFENCEI BA BB BC BS FH FHMIN FBFMIN VFH VFHMIN VFBFMIN
           CB CMP CMT AAMO ALRSC MMUL)
  if(CONFIG_RISCV_ISA_EXT_Z${_e})
    string(TOLOWER ${_e} _l)
    string(APPEND _spike_isa _z${_l})
  endif()
endforeach()
# Extensions the hardware has but Kconfig cannot express (e.g. Zicntr: selecting it
# breaks -march in this Zephyr fork). Boards list them lower-case, without the leading
# underscore, in SPIKE_ISA_EXTRA before including this file.
foreach(_x ${SPIKE_ISA_EXTRA})
  if(NOT _spike_isa MATCHES "_${_x}(_|$)")
    string(APPEND _spike_isa _${_x})
  endif()
endforeach()
if(CONFIG_RISCV_ISA_EXT_V)
  string(APPEND _spike_isa _zvl${CONFIG_RISCV_VECTOR_MAX_LEN}b)
endif()

if(NOT SPIKE_TIMEOUT)
  if(DEFINED ENV{SPIKE_TIMEOUT})
    set(SPIKE_TIMEOUT $ENV{SPIKE_TIMEOUT})
  else()
    set(SPIKE_TIMEOUT 120)
  endif()
endif()
separate_arguments(_spike_extra NATIVE_COMMAND "${SPIKE_EXTRA_ARGS}")

set(SPIKE_ISA ${_spike_isa} CACHE INTERNAL "ISA string passed to Spike")

if(SPIKE_EXE)
  message(STATUS "Spike: ${SPIKE_EXE} --isa=${SPIKE_ISA}")
  # sh -c script: $0 = spike, $1 = the ELF, $@ = --isa and the baked extra arguments.
  # SPIKE_TIMEOUT / SPIKE_EXTRA_ARGS in the environment of the `run` step override/extend them.
  set(_spike_script
      "elf=\$1; shift; exec timeout \"\${SPIKE_TIMEOUT:-${SPIKE_TIMEOUT}}\" \"\$0\" \"\$@\" \$SPIKE_EXTRA_ARGS \"\$elf\"")
  add_custom_target(run_custom
    COMMAND sh -c "${_spike_script}" ${SPIKE_EXE}
            ${PROJECT_BINARY_DIR}/${KERNEL_ELF_NAME}
            --isa=${SPIKE_ISA} ${_spike_extra}
    WORKING_DIRECTORY ${APPLICATION_BINARY_DIR}
    DEPENDS ${logical_target_for_zephyr_elf}
    USES_TERMINAL
    VERBATIM
    )
else()
  message(STATUS "Spike not found ('${SPIKE}'): building works, `run` will say what to do")
  # A `run` that explains instead of failing with "No such file or directory".
  add_custom_target(run_custom
    COMMAND ${CMAKE_COMMAND} -E echo "ERROR: Spike not found (looked for '${SPIKE}'): set SPIKE=/path/to/spike or run setup with --with-spike. Building does not need Spike; only `run` does. If you just installed it, reconfigure (west build -p auto)."
    COMMAND ${CMAKE_COMMAND} -E false
    DEPENDS ${logical_target_for_zephyr_elf}
    USES_TERMINAL
    VERBATIM
    )
endif()

# ---- debug (west debug / debugserver / attach) ------------------------------
# The "spike" west runner (scripts/spike_runner.py, registered in zephyr/module.yml) is
# Zephyr's openocd runner plus "start Spike first". OpenOCD config: SPIKE_OPENOCD_CFG
# (default: the board's support/openocd-spike.cfg). Ports/timeouts are runner options:
#   west debug --rbb-port=9900 --gdb-port=3400 --spike-start-timeout=30
set_ifndef(SPIKE_OPENOCD_CFG ${BOARD_DIR}/support/openocd-spike.cfg)
# OpenOCD must be built with --enable-remote-bitbang (the Zephyr SDK's is not; the runner
# checks). Use -DSPIKE_OPENOCD=... or the SPIKE_OPENOCD environment variable; default is
# `openocd` on PATH.
if(NOT SPIKE_OPENOCD AND DEFINED ENV{SPIKE_OPENOCD})
  set(SPIKE_OPENOCD $ENV{SPIKE_OPENOCD})
endif()
if(SPIKE_OPENOCD)
  board_runner_args(spike "--openocd=${SPIKE_OPENOCD}")
endif()
board_set_debugger_ifnset(spike)
board_runner_args(spike
  "--spike=${_spike_cmd}"
  "--isa=${SPIKE_ISA}"
  "--config=${SPIKE_OPENOCD_CFG}"
  "--no-load"            # Spike already loaded the ELF from its command line
  )
board_finalize_runner_args(spike)
