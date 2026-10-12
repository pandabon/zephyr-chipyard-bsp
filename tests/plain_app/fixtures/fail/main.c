/* SPDX-License-Identifier: Apache-2.0 */
/* Plain-dir fixture: main() returns 3; the run must fail with exit code 3. */
#include <zephyr/sys/printk.h>

int main(void)
{
	printk("plain_app fail fixture: returning 3\n");
	return 3;
}
