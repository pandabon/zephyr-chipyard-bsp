/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Template app: print, then end the simulation with an exit code, which becomes the
 * simulator's exit status (0 = pass).
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <chipyard/sim_exit.h>

int main(void)
{
	printk("Hello from %s\n", CONFIG_BOARD_TARGET);

	chipyard_sim_exit(0);
}
