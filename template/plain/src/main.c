/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Plain-folder app: no CMakeLists.txt, no Kconfig knowledge needed. Every .c/.S under this
 * folder is compiled as a Zephyr app (cmake/plain_app in the BSP); main()'s return value
 * becomes the exit code (0 = pass).
 *
 * Shows two ways to do a vector add: an RVV intrinsic loop in C, and the same thing written
 * in assembly (vadd.S) and called from C. Both must agree.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <riscv_vector.h>

#define N 37

/* In vadd.S */
extern void vadd_i32(int32_t *dst, const int32_t *a, const int32_t *b, size_t n);

static int32_t a[N], b[N], c_intr[N], c_asm[N];

int main(void)
{
	int errors = 0;
	size_t vl;

	for (int i = 0; i < N; i++) {
		a[i] = i;
		b[i] = 100 - 2 * i;
	}

	for (size_t i = 0; i < N; i += vl) {
		vl = __riscv_vsetvl_e32m1(N - i);
		vint32m1_t va = __riscv_vle32_v_i32m1(&a[i], vl);
		vint32m1_t vb = __riscv_vle32_v_i32m1(&b[i], vl);

		__riscv_vse32_v_i32m1(&c_intr[i], __riscv_vadd_vv_i32m1(va, vb, vl), vl);
	}

	vadd_i32(c_asm, a, b, N);

	for (int i = 0; i < N; i++) {
		errors += (c_intr[i] != 100 - i) + (c_asm[i] != 100 - i);
	}

	printf("template/plain: VLEN = %u bits, %d errors: %s\n",
	       (unsigned int)(__riscv_vlenb() * 8), errors, errors ? "FAIL" : "PASS");
	return errors ? 1 : 0;
}
