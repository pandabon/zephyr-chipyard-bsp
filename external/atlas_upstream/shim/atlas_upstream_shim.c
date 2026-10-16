/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * CREDIT: the tests this sample builds, and the generators/assembler it calls, are
 * the Atlas/Saturn team's work, used unmodified from the course tapeout repo (tapeout-chipyard)
 * (tests/, generators/sp26-atlas-acc/baremetal/), commit
 * 48c3a7d11f6de3f0cecb33ae6a31c24ec26ff9d8, submodule sp26-atlas-acc 2ae0bef209df. git authors of tests/: kellytou
 * ("T.K."), Eric Wen, Nicolas Rakela (Herrera), Nicolas Reed; sp26-atlas-acc
 * baremetal: kellytou, Nicolas Reed, jason.tang, Eric Wen, nicorakela. The build
 * logic mirrors tests/CMakeLists.txt there. We own only the files in this directory.
 *
 * Glue between the Atlas team's baremetal tests (compiled unmodified) and Zephyr.
 *
 *  - Startup/exit: upstream links with htif.ld and -specs=htif_nano.specs, whose crt0 calls
 *    main() and writes its return value to HTIF `tohost`. Zephyr calls main() from a thread,
 *    so the build links with --wrap=main (see CMakeLists.txt) and __wrap_main() below runs
 *    the upstream main() and ends the run with its return value (0 = pass).
 *  - printf() goes to the board's console through picolibc; rdcycle works in M-mode.
 *  - Memory: both linker scripts place the program at 0x80000000 (ram0). The tests' DRAM
 *    window ATLAS_DRAM_BASE 0x90000000 is plain pointer access.
 *  - Timeouts: some upstream loops wait very long (200 million polls) or forever, so a
 *    watchdog thread (Kconfig ATLAS_UPSTREAM_TIMEOUT_S) stops Atlas and reports TIMEOUT.
 *
 * Output lines, in addition to upstream's own:
 *   ATLASUP <test> PASS | FAIL rc=<n> | TIMEOUT after <s> s
 * Upstream's final "PASS: ..." line is the reference result; main() returns nonzero on any
 * failure, so the exit code agrees.
 */
#include <stdio.h>
#include <zephyr/kernel.h>
#include <chipyard/sim_exit.h>

#include "atlas_mmio.h"   /* upstream header: ATLAS_CSR_BASE etc. */

#ifndef ATLAS_UPSTREAM_NAME
#define ATLAS_UPSTREAM_NAME "unknown"
#endif

extern int __real_main(void);

/* Cooperative priority (-1), so it preempts the busy-polling main thread (priority 0) when
 * its sleep expires. */
static void watchdog(void *a, void *b, void *c)
{
	(void)a; (void)b; (void)c;
	k_sleep(K_SECONDS(CONFIG_ATLAS_UPSTREAM_TIMEOUT_S));
	atlas_stop();   /* execControl = 0 */
	printf("ATLASUP %s TIMEOUT after %d s\n", ATLAS_UPSTREAM_NAME,
	       CONFIG_ATLAS_UPSTREAM_TIMEOUT_S);
	chipyard_sim_exit(124);
}
K_THREAD_DEFINE(atlas_wd, 1024, watchdog, NULL, NULL, NULL, -1, 0, 0);

int __wrap_main(void)
{
	printf("ATLASUP %s start\n", ATLAS_UPSTREAM_NAME);
	int rc = __real_main();

	if (rc == 0) {
		printf("ATLASUP %s PASS\n", ATLAS_UPSTREAM_NAME);
	} else {
		printf("ATLASUP %s FAIL rc=%d\n", ATLAS_UPSTREAM_NAME, rc);
	}
	chipyard_sim_exit(rc);
}
