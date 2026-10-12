/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * RVV platform sanity: the hardware VLEN fits the kernel's per-thread save
 * area, and vector instructions work from an ordinary thread.
 */
#include <zephyr/ztest.h>
#include <stdint.h>
#include <riscv_vector.h>

static unsigned long read_vlenb(void)
{
	unsigned long v;

	__asm__ volatile(".option push\n .option arch, +v\n"
			 "csrr %0, vlenb\n .option pop" : "=r"(v));
	return v;
}

ZTEST(rvv_vlen, test_vlen_fits_save_area)
{
	unsigned long vlenb = read_vlenb();

	TC_PRINT("vlenb=%lu => VLEN=%lu bits, CONFIG_RISCV_VECTOR_MAX_LEN=%d\n",
		 vlenb, vlenb * 8, CONFIG_RISCV_VECTOR_MAX_LEN);
	zassert_true(vlenb != 0, "vlenb is zero");
	zassert_equal(vlenb & (vlenb - 1), 0, "VLEN not a power of two");
	/* If this fails the kernel's saved_v_context buffer overflows. */
	zassert_true(vlenb * 8 <= CONFIG_RISCV_VECTOR_MAX_LEN,
		     "hardware VLEN %lu > CONFIG_RISCV_VECTOR_MAX_LEN", vlenb * 8);
}

ZTEST(rvv_vlen, test_vsetvli_vlmax)
{
	unsigned long vlenb = read_vlenb();
	unsigned long vl;

	/* VLMAX = VLEN/SEW * LMUL. AVL = -1 asks for the maximum. */
	__asm__ volatile(".option push\n .option arch, +v\n"
			 "vsetvli %0, %1, e8, m1, ta, ma\n .option pop"
			 : "=r"(vl) : "r"(-1L));
	zassert_equal(vl, vlenb, "e8/m1 vl=%lu", vl);

	__asm__ volatile(".option push\n .option arch, +v\n"
			 "vsetvli %0, %1, e32, m1, ta, ma\n .option pop"
			 : "=r"(vl) : "r"(-1L));
	zassert_equal(vl, vlenb / 4, "e32/m1 vl=%lu", vl);

	__asm__ volatile(".option push\n .option arch, +v\n"
			 "vsetvli %0, %1, e64, m8, ta, ma\n .option pop"
			 : "=r"(vl) : "r"(-1L));
	zassert_equal(vl, vlenb, "e64/m8 vl=%lu", vl);

	__asm__ volatile(".option push\n .option arch, +v\n"
			 "vsetvli %0, %1, e16, m2, ta, ma\n .option pop"
			 : "=r"(vl) : "r"(-1L));
	zassert_equal(vl, vlenb, "e16/m2 vl=%lu", vl);

	/* AVL smaller than VLMAX is returned unchanged. */
	__asm__ volatile(".option push\n .option arch, +v\n"
			 "vsetvli %0, %1, e8, m1, ta, ma\n .option pop"
			 : "=r"(vl) : "r"(3L));
	zassert_equal(vl, 3, "avl=3 vl=%lu", vl);
}

#define N 1000

static int32_t a[N], b[N], c_vec[N], c_ref[N];

ZTEST(rvv_vlen, test_vector_add_matches_scalar)
{
	for (int i = 0; i < N; i++) {
		a[i] = i * 7 - 300;
		b[i] = 100000 - i * i;
		c_ref[i] = a[i] + b[i];
		c_vec[i] = 0x5a5a5a5a;
	}

	size_t n = N;
	const int32_t *pa = a, *pb = b;
	int32_t *pc = c_vec;

	while (n > 0) {
		size_t vl = __riscv_vsetvl_e32m2(n);
		vint32m2_t va = __riscv_vle32_v_i32m2(pa, vl);
		vint32m2_t vb = __riscv_vle32_v_i32m2(pb, vl);

		__riscv_vse32_v_i32m2(pc, __riscv_vadd_vv_i32m2(va, vb, vl), vl);
		pa += vl; pb += vl; pc += vl; n -= vl;
	}

	for (int i = 0; i < N; i++) {
		zassert_equal(c_vec[i], c_ref[i], "mismatch at %d: %d != %d",
			      i, c_vec[i], c_ref[i]);
	}
}

ZTEST_SUITE(rvv_vlen, NULL, NULL, NULL, NULL, NULL);
