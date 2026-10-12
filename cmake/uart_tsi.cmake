# SPDX-License-Identifier: Apache-2.0
#
# SoC-agnostic helper: registers the `uart_tsi` west runner (scripts/runners/uart_tsi.py,
# loaded through `runners:` in zephyr/module.yml) for a chip behind an FPGA. Include it from
# board.cmake:
#
#   include(${CMAKE_CURRENT_LIST_DIR}/../../../cmake/uart_tsi.cmake)
#
# --tty, --uart-tsi and --baud are `west flash` options (or $UART_TSI_TTY / $UART_TSI), not
# build settings, since they depend on the bench and USB port. A board makes the runner the
# default with board_set_flasher_ifnset(uart_tsi) and can pass defaults with
# board_runner_args(uart_tsi "--baud=921600").

board_finalize_runner_args(uart_tsi)
