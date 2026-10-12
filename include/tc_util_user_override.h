/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Included by <zephyr/tc_util.h> when CONFIG_ZTEST_TC_UTIL_USER_OVERRIDE=y (the board
 * Kconfig.defconfig enables it).
 *
 * Stock ztest prints "PROJECT EXECUTION SUCCESSFUL/FAILED" and then idles, leaving the
 * simulator running. This TC_END_REPORT is upstream's plus an exit with code 0 on pass, 1 on
 * fail.
 */

#ifndef CHIPYARD_TC_UTIL_USER_OVERRIDE_H_
#define CHIPYARD_TC_UTIL_USER_OVERRIDE_H_

#include <chipyard/sim_exit.h>

#define TC_END_REPORT(result)                                              \
	do {                                                               \
		PRINT_LINE;                                                \
		TC_PRINT_RUNID;                                            \
		TC_END(result, "PROJECT EXECUTION %s\n",                   \
		       (result) == TC_PASS ? "SUCCESSFUL" : "FAILED");     \
		chipyard_sim_exit((result) == TC_PASS ? 0 : 1);            \
	} while (false)

#endif /* CHIPYARD_TC_UTIL_USER_OVERRIDE_H_ */
