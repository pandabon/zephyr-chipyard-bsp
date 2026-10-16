/* SPDX-License-Identifier: Apache-2.0
 *
 * void vadd_i32(int32_t *dst, const int32_t *a, const int32_t *b, size_t n)
 * dst[i] = a[i] + b[i], strip-mined with vsetvli so it works for any VLEN.
 * Arguments: a0 = dst, a1 = a, a2 = b, a3 = n (RISC-V calling convention).
 */
	.text
	.globl vadd_i32
	.type vadd_i32, @function
vadd_i32:
1:	beqz	a3, 2f
	vsetvli	t0, a3, e32, m1, ta, ma	/* t0 = elements this trip (<= VLMAX) */
	vle32.v	v0, (a1)
	vle32.v	v1, (a2)
	vadd.vv	v2, v0, v1
	vse32.v	v2, (a0)
	slli	t1, t0, 2		/* bytes done = t0 * 4 */
	add	a0, a0, t1
	add	a1, a1, t1
	add	a2, a2, t1
	sub	a3, a3, t0
	j	1b
2:	ret
	.size vadd_i32, .-vadd_i32
