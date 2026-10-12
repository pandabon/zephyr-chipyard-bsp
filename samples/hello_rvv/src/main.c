/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Bring-up smoke test: report VLEN and run a strip-mined vector add.
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <riscv_vector.h>
#include <chipyard/sim_exit.h>

#define N 97

static int32_t a[N], b[N], c[N];

int main(void)
{
	size_t vl;
	int errors = 0;

	for (int i = 0; i < N; i++) {
		a[i] = i;
		b[i] = 1000 - 2 * i;
	}

	for (size_t i = 0; i < N; i += vl) {
		vl = __riscv_vsetvl_e32m1(N - i);
		vint32m1_t va = __riscv_vle32_v_i32m1(&a[i], vl);
		vint32m1_t vb = __riscv_vle32_v_i32m1(&b[i], vl);

		__riscv_vse32_v_i32m1(&c[i], __riscv_vadd_vv_i32m1(va, vb, vl), vl);
	}

	for (int i = 0; i < N; i++) {
		errors += (c[i] != 1000 - i);
	}

	printk("VLEN = %u bits, CONFIG_RISCV_VECTOR_MAX_LEN = %d\n",
	       (unsigned int)(__riscv_vlenb() * 8), CONFIG_RISCV_VECTOR_MAX_LEN);
	printk("hello_rvv: %s (%d errors)\n", errors ? "FAIL" : "PASS", errors);

	chipyard_sim_exit(errors ? 1 : 0);
}
