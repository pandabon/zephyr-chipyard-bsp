/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * End a simulation (Spike, Verilator, FireSim...) with an exit code. The SoC layer implements
 * it with an HTIF "tohost" write. Without an HTIF host (CONFIG_CHIPYARD_SIM_EXIT_HTIF=n, e.g.
 * the VCU118 variant) it prints "*** EXIT <code> ***" on the console and halts in a wfi loop.
 */

#ifndef CHIPYARD_SIM_EXIT_H_
#define CHIPYARD_SIM_EXIT_H_

#include <zephyr/toolchain.h>

/** Stop the simulation; the simulator process exits with @p code. Never returns. */
FUNC_NORETURN void chipyard_sim_exit(int code);

#endif /* CHIPYARD_SIM_EXIT_H_ */
