# SPDX-License-Identifier: Apache-2.0
#
# `west build -t run` runs the ELF on Spike; the logic is in the module's cmake/spike.cmake.
if(CONFIG_CHIPYARD_FPGA_EMULATION)
  # Variant "vcu118": whole SoC on an FPGA. Spike has no SiFive UART model at 0x6400_0000,
  # so `run` prints an error. Load via SD card or JTAG.
  set(SUPPORTED_EMU_PLATFORMS custom)
  add_custom_target(run_custom
    COMMAND ${CMAKE_COMMAND} -E echo "ERROR: board variant chipyard_penguin/penguin/vcu118 cannot run on Spike (no sifive,uart0 model at 0x64000000; console is the VCU118 UART). Build the base target chipyard_penguin/penguin to simulate, or load this image on the FPGA (SD: scripts/mk_sdboot_image.sh, or JTAG)."
    COMMAND ${CMAKE_COMMAND} -E false
    DEPENDS ${logical_target_for_zephyr_elf}
    USES_TERMINAL
    VERBATIM
    )
  return()
endif()

# Zicntr is not in the chip's riscv,isa (rocket-chip does not implement rdtime, see
# penguin.dtsi) and stays out of -march (see the SoC Kconfig), but Spike needs it or
# cycle-counter reads trap as illegal.
#
# BF16: Zvfbfmin comes from Kconfig (GCC 14.3 accepts it). Zfbfmin and Zvfbfa are in the
# chip's riscv,isa but GCC 14.3 rejects them in -march, so only Spike is told. Zvfbfa gives
# vtype.altfmt (BF16 vector arithmetic) and needs Zfbfmin. Zvfofp8min is omitted: Spike has
# it, the compiler does not.
set(SPIKE_ISA_EXTRA zicntr zfbfmin zvfbfa)
include(${CMAKE_CURRENT_LIST_DIR}/../../../cmake/spike.cmake)

# `west flash` loads the ELF onto the chip through the bring-up FPGA (UART-TSI) and is the
# only way to get code onto it, so uart_tsi is the default runner. Spike is a CMake target
# (`west build -t run`), not a runner. Needs --tty and --uart-tsi at flash time.
board_set_flasher_ifnset(uart_tsi)
if(CONFIG_CHIPYARD_FPGA_TA)
  # Variant "vcu118_ta": the stock testchipip WithUARTTSIClient runs at 115200 baud
  # (testchipip tsi/Configs.scala:8), not 921600. `--baud` still overrides.
  board_runner_args(uart_tsi "--baud=115200")
endif()
include(${CMAKE_CURRENT_LIST_DIR}/../../../cmake/uart_tsi.cmake)
