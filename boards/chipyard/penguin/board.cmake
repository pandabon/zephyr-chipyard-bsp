# SPDX-License-Identifier: Apache-2.0
#
# `west build -t run` / twister run the ELF on Spike; the generic logic (ISA string from
# Kconfig, SPIKE override) is in cmake/spike.cmake.
#
# This BSP only produces binaries (and runs them on Spike); loading onto hardware is a
# separate loader, e.g. Chipyard's `uart_tsi`. Every build ends by printing the ELF path and
# an example load line (a target in the default `all` build, so west and make both show it).
# The baud rate is the only per-board fact: the chip's bring-up FPGA runs UART-TSI at 921600,
# the TA's VCU118 bitstream at 115200 (testchipip tsi/Configs.scala:8, stock
# WithUARTTSIClient). It is a CMake variable, not Kconfig, because no firmware uses it.
set(PENGUIN_ELF ${PROJECT_BINARY_DIR}/${KERNEL_ELF_NAME})
if(CONFIG_CHIPYARD_FPGA_TA)
  set(PENGUIN_LOAD_BAUD 115200)
else()
  set(PENGUIN_LOAD_BAUD 921600)
endif()
if(CONFIG_CHIPYARD_FPGA_EMULATION)
  set(PENGUIN_LOAD_HINT "load: this variant boots from an SD image or JTAG (not UART-TSI); see your loader's docs")
else()
  set(PENGUIN_LOAD_HINT "load on hardware (example): uart_tsi +tty=<tty> +baudrate=${PENGUIN_LOAD_BAUD} ${PENGUIN_ELF}")
endif()
add_custom_target(elf_load_hint ALL
  COMMAND ${CMAKE_COMMAND} -E echo "ELF: ${PENGUIN_ELF}"
  COMMAND ${CMAKE_COMMAND} -E echo "${PENGUIN_LOAD_HINT}"
  COMMENT "ELF location and hardware load hint"
  VERBATIM
  )
# Order it after the final link: needs a target-level dependency, and the ELF target does
# not exist yet while board.cmake is read, so add it at the end of the top-level CMake run.
cmake_language(DEFER CALL add_dependencies elf_load_hint ${logical_target_for_zephyr_elf})

if(CONFIG_CHIPYARD_FPGA_EMULATION)
  # Variant "vcu118": whole SoC on an FPGA. Spike has no SiFive UART model at
  # 0x6400_0000, so it cannot run this image; `run` explains instead of
  # silently printing nothing. Load via SD card or JTAG.
  set(SUPPORTED_EMU_PLATFORMS custom)
  add_custom_target(run_custom
    COMMAND ${CMAKE_COMMAND} -E echo "ERROR: board variant chipyard_penguin/penguin/vcu118 cannot run on Spike (no sifive,uart0 model at 0x64000000; console is the VCU118 UART). Build the base target chipyard_penguin/penguin to simulate, or load this image on the FPGA (SD card or JTAG; the loader is not part of this BSP)."
    COMMAND ${CMAKE_COMMAND} -E false
    DEPENDS ${logical_target_for_zephyr_elf}
    USES_TERMINAL
    VERBATIM
    )
  return()
endif()

# Zicntr is not in the chip's riscv,isa (rdtime is not implemented in rocket-chip, see
# penguin.dtsi) and is kept out of Kconfig/-march (see soc Kconfig), but apps that read the
# cycle counter trap as illegal on Spike without it, so tell Spike directly.
#
# BF16: Zvfbfmin comes from Kconfig (GCC 14.3 accepts it). Zfbfmin and Zvfbfa are in the
# chip's riscv,isa but GCC 14.3 rejects them in -march, so only Spike is told. Zvfbfa gives
# vtype.altfmt (BF16 vector arithmetic) and needs Zfbfmin. Zvfofp8min (OFP8 conversions) is
# likewise compiler-less but in Penguin's riscv,isa (generator + the FPGA's generated DTS).
set(SPIKE_ISA_EXTRA zicntr zfbfmin zvfbfa zvfofp8min)
include(${CMAKE_CURRENT_LIST_DIR}/../../../cmake/spike.cmake)

