/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Plain apps are linked with -Wl,--wrap=main, so the kernel's call to main() lands here.
 * This runs the app's main() and ends the simulation with its return value; otherwise a
 * returning main() leaves Zephyr idling until the simulator times out.
 */
#include <chipyard/sim_exit.h>

extern int __real_main(void);

int __wrap_main(void)
{
	chipyard_sim_exit(__real_main());
}
