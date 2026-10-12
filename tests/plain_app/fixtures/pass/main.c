/* SPDX-License-Identifier: Apache-2.0 */
/* Plain-dir fixture: no CMakeLists.txt, C + C++ + include/ + prj.conf. */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include "adder.h"

int main(void)
{
	int sum = cpp_add(2, 3);

	printk("plain_app pass fixture: cpp_add(2,3)=%d main_stack=%d\n", sum, CONFIG_MAIN_STACK_SIZE);
	/* checks that this directory's prj.conf was merged */
	return (sum == 5 && CONFIG_MAIN_STACK_SIZE == 3072) ? 0 : 1;
}
