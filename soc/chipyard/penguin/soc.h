/*
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef PENGUIN_SOC_H_
#define PENGUIN_SOC_H_

/* Used by drivers/serial/uart_sifive.c */
#define SIFIVE_PERIPHERAL_CLOCK_FREQUENCY \
	(CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC * CONFIG_RTC_CLOCK_DIVIDER_VALUE)

#endif /* PENGUIN_SOC_H_ */
