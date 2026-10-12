# SPDX-License-Identifier: Apache-2.0
#
# SoC-agnostic helper: defines the `run` / `run_custom` targets that run the built ELF on
# Spike. Include it from a board.cmake:
#
#   include(${BOARD_DIR}/../../../cmake/spike.cmake)
#
# The Spike binary is -DSPIKE=..., else $SPIKE, else `spike` on PATH.
#
# The --isa string comes from the build's Kconfig (Spike 1.1 has no --varch; the vector
# length is the _zvl<N>b suffix): rv64i/rv32i, then m a f d c from RISCV_ISA_EXT_*, then v,
# then each enabled RISCV_ISA_EXT_Z* in the loop below, then _zvl<N>b from
# RISCV_VECTOR_MAX_LEN.
# The exit status is what the app passed to HTIF exit (see sim_exit.h), 0 = success.
# SPIKE_TIMEOUT (seconds, default 120) kills a hung run.

set(SUPPORTED_EMU_PLATFORMS custom)

if(NOT SPIKE)
  if(DEFINED ENV{SPIKE})
    set(SPIKE $ENV{SPIKE})
  else()
    set(SPIKE spike)
  endif()
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
# Append `_<name>` for every enabled Z* extension, so Spike models what GCC got via -march
# (Zephyr's cmake/compiler/gcc/target_riscv.cmake). Add a name when adding a
# RISCV_ISA_EXT_Z* select. Zfh/Zfhmin and Zvfh/Zvfhmin are both listed because Spike accepts
# the superset either implies.
foreach(_e ICNTR ICSR IFENCEI BA BB BC BS FH FHMIN FBFMIN VFH VFHMIN VFBFMIN
           CB CMP CMT AAMO ALRSC MMUL)
  if(CONFIG_RISCV_ISA_EXT_Z${_e})
    string(TOLOWER ${_e} _l)
    string(APPEND _spike_isa _z${_l})
  endif()
endforeach()
# Extensions the hardware has that Kconfig cannot express (selecting Zicntr breaks -march in
# this Zephyr fork). Boards list them lower-case, without the underscore, in SPIKE_ISA_EXTRA
# before including this file. Ones Kconfig already added are skipped.
foreach(_x ${SPIKE_ISA_EXTRA})
  if(NOT _spike_isa MATCHES "_${_x}(_|$)")
    string(APPEND _spike_isa _${_x})
  endif()
endforeach()
if(CONFIG_RISCV_ISA_EXT_V)
  string(APPEND _spike_isa _zvl${CONFIG_RISCV_VECTOR_MAX_LEN}b)
endif()

if(NOT SPIKE_TIMEOUT)
  set(SPIKE_TIMEOUT 120)
endif()

set(SPIKE_ISA ${_spike_isa} CACHE INTERNAL "ISA string passed to Spike")
message(STATUS "Spike: ${SPIKE} --isa=${SPIKE_ISA}")

add_custom_target(run_custom
  COMMAND ${CMAKE_COMMAND} -E env timeout ${SPIKE_TIMEOUT}
          ${SPIKE} --isa=${SPIKE_ISA} ${PROJECT_BINARY_DIR}/${KERNEL_ELF_NAME}
  WORKING_DIRECTORY ${APPLICATION_BINARY_DIR}
  DEPENDS ${logical_target_for_zephyr_elf}
  USES_TERMINAL
  )

# ---- debug (west debug / debugserver / attach) ------------------------------
# The "spike" runner (scripts/runners/spike.py) is Zephyr's openocd runner that starts Spike
# first. SPIKE_OPENOCD_CFG selects the OpenOCD config (default: the board's
# support/openocd-spike.cfg). Ports and timeouts are runner options, e.g.
#   west debug --rbb-port=9900 --gdb-port=3400 --spike-start-timeout=30
set_ifndef(SPIKE_OPENOCD_CFG ${BOARD_DIR}/support/openocd-spike.cfg)
# OpenOCD needs --enable-remote-bitbang, which the SDK's build lacks (the runner checks).
# Set -DSPIKE_OPENOCD=... or $SPIKE_OPENOCD; the default is `openocd` on PATH.
if(NOT SPIKE_OPENOCD AND DEFINED ENV{SPIKE_OPENOCD})
  set(SPIKE_OPENOCD $ENV{SPIKE_OPENOCD})
endif()
if(SPIKE_OPENOCD)
  board_runner_args(spike "--openocd=${SPIKE_OPENOCD}")
endif()
board_set_debugger_ifnset(spike)
board_runner_args(spike
  "--spike=${SPIKE}"
  "--isa=${SPIKE_ISA}"
  "--config=${SPIKE_OPENOCD_CFG}"
  "--no-load"            # Spike already loaded the ELF from its command line
  )
board_finalize_runner_args(spike)
