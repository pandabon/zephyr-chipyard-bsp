/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * BF16 vector instructions on the Penguin (Shuttle + Saturn) ISA, checked against scalar C
 * references. Covers the compiler/assembler flags, the Spike --isa string and the
 * instruction behaviour.
 *
 *  1. vfwcvtbf16.f.f.v   bf16 -> f32, widening conversion   (Zvfbfmin)
 *  2. vfncvtbf16.f.f.w   f32 -> bf16, narrowing, RNE        (Zvfbfmin)
 *  3. vfwmacc.vv  with vtype.altfmt=1: bf16*bf16 + f32 -> f32 (Zvfbfa)
 *  4. vfadd.vv    with vtype.altfmt=1: bf16 + bf16 -> bf16   (Zvfbfa)
 *
 * About vfwmaccbf16 (Zvfbfwma): the chip's riscv,isa does not list Zvfbfwma
 * (only zvfbfmin and zvfbfa), and Spike refuses vfwmaccbf16 unless Zvfbfwma is
 * enabled. Zvfbfa's altfmt form of vfwmacc (case 3) does the same job, so that
 * is what we test. Spike's behaviour is the reference for the semantics:
 * riscv-isa-sim riscv/v_ext_macros.h (VI_VFP_VV_LOOP_WIDE e16 case, altfmt
 * selects bf16_to_f32) at commit 609dbe0b, and riscv/vector_unit.cc:95-135
 * (vtype bit 8 = altfmt, legal with Zvfbfa).
 *
 * Toolchain notes (SDK 1.0-beta1, GCC 14.3 / binutils 2.43): the assembler knows
 * vfwcvtbf16/vfncvtbf16 under Zvfbfmin (selected in the SoC Kconfig). It has
 * no Zvfbfa, so vtype.altfmt is set by building the vtype value by hand and
 * using `vsetvl` (register form). vtype layout: vlmul[2:0], vsew[5:3], vta[6],
 * vma[7], altfmt[8] (bit 8 per the Spike source above; RISC-V Zvfbfa spec).
 */
#include <zephyr/ztest.h>
#include <stdint.h>
#include <string.h>

#define N 37 /* not a multiple of VL (16 for e16/m1 at VLEN 256) */

/* vtype: e16, m1, ta, ma, with and without altfmt (see header comment) */
#define VT_E16_M1_TA_MA    ((1UL << 3) | (1UL << 6) | (1UL << 7))
#define VT_E16_M1_TA_MA_ALT (VT_E16_M1_TA_MA | (1UL << 8))

/* ---- scalar references --------------------------------------------------- */

static float bf16_to_f32(uint16_t h)
{
	uint32_t b = (uint32_t)h << 16;
	float f;

	memcpy(&f, &b, 4);
	return f;
}

/* f32 -> bf16, round to nearest even, NaN -> canonical NaN. */
static uint16_t f32_to_bf16(float f)
{
	uint32_t b;

	memcpy(&b, &f, 4);
	if ((b & 0x7fffffffu) > 0x7f800000u) {
		return 0x7fc0;
	}
	b += 0x7fffu + ((b >> 16) & 1u);
	return (uint16_t)(b >> 16);
}

static uint32_t fbits(float f)
{
	uint32_t b;

	memcpy(&b, &f, 4);
	return b;
}

/* ---- vector helpers (one strip-mined chunk per call) ----------------------- */

static size_t vec_widen(const uint16_t *in, float *out, size_t n)
{
	size_t vl;

	__asm__ volatile(
		"vsetvli %[vl], %[n], e16, m1, ta, ma\n"
		"vle16.v v4, (%[in])\n"
		"vfwcvtbf16.f.f.v v8, v4\n"
		"vse32.v v8, (%[out])\n"
		: [vl] "=&r"(vl)
		: [n] "r"(n), [in] "r"(in), [out] "r"(out)
		: "memory", "v4", "v8", "v9");
	return vl;
}

static size_t vec_narrow(const float *in, uint16_t *out, size_t n)
{
	size_t vl;

	__asm__ volatile(
		"vsetvli %[vl], %[n], e16, m1, ta, ma\n"
		"vle32.v v8, (%[in])\n"
		"vfncvtbf16.f.f.w v4, v8\n"
		"vse16.v v4, (%[out])\n"
		: [vl] "=&r"(vl)
		: [n] "r"(n), [in] "r"(in), [out] "r"(out)
		: "memory", "v4", "v8", "v9");
	return vl;
}

/* acc[i] += a[i] * b[i]  (bf16 x bf16 -> f32), Zvfbfa altfmt widening MAC. */
static size_t vec_wmacc_alt(const uint16_t *a, const uint16_t *b, float *acc,
			    size_t n)
{
	size_t vl, vt = VT_E16_M1_TA_MA_ALT, tmp;

	__asm__ volatile(
		"vsetvl %[vl], %[n], %[vt]\n"      /* e16, m1, altfmt=1 */
		"vle16.v v4, (%[a])\n"
		"vle16.v v6, (%[b])\n"
		"vle32.v v8, (%[acc])\n"
		"vfwmacc.vv v8, v4, v6\n"
		"vse32.v v8, (%[acc])\n"
		"vsetvli %[tmp], zero, e8, m1, ta, ma\n" /* altfmt back to 0 */
		: [vl] "=&r"(vl), [tmp] "=&r"(tmp)
		: [n] "r"(n), [vt] "r"(vt), [a] "r"(a), [b] "r"(b),
		  [acc] "r"(acc)
		: "memory", "v4", "v6", "v8", "v9");
	return vl;
}

/* out[i] = a[i] + b[i] in bf16, Zvfbfa altfmt vfadd. */
static size_t vec_add_alt(const uint16_t *a, const uint16_t *b, uint16_t *out,
			  size_t n)
{
	size_t vl, vt = VT_E16_M1_TA_MA_ALT, tmp;

	__asm__ volatile(
		"vsetvl %[vl], %[n], %[vt]\n"
		"vle16.v v4, (%[a])\n"
		"vle16.v v6, (%[b])\n"
		"vfadd.vv v8, v4, v6\n"
		"vse16.v v8, (%[out])\n"
		"vsetvli %[tmp], zero, e8, m1, ta, ma\n"
		: [vl] "=&r"(vl), [tmp] "=&r"(tmp)
		: [n] "r"(n), [vt] "r"(vt), [a] "r"(a), [b] "r"(b),
		  [out] "r"(out)
		: "memory", "v4", "v6", "v8");
	return vl;
}

/* ---- test data ------------------------------------------------------------- */

static uint16_t bf_a[N], bf_b[N], bf_out[N], bf_ref[N];
static float f_in[N], f_out[N], f_ref[N];

static void fill(void)
{
	for (int i = 0; i < N; i++) {
		/* values around 1: exponents -2..3, both signs, a few zeros */
		float x = (float)(i - 18) * 0.37f;
		float y = (float)(9 - i) * 0.21f + 0.5f;

		bf_a[i] = f32_to_bf16(x);
		bf_b[i] = f32_to_bf16(y);
		f_in[i] = (float)(i - 18) * 1.0371f; /* needs real rounding */
	}
	bf_a[3] = 0x0000;          /* +0 */
	bf_a[4] = 0x8000;          /* -0 */
	bf_b[5] = 0x0000;
	/* exact RNE ties: 1 + 2^-8 -> 1.0 (even), 1 + 3*2^-8 -> 1 + 2^-6 (even) */
	f_in[6] = 1.00390625f;
	f_in[7] = 1.01171875f;
	f_in[8] = -1.00390625f;
	/* specials: +inf, -inf, large finite that rounds up to inf */
	f_in[9] = __builtin_inff();
	f_in[10] = -__builtin_inff();
	f_in[11] = 3.3961776e38f;  /* 0x7f7fffff-ish region: rounds to inf */
	f_in[12] = 1e-39f;         /* f32 subnormal */
}

ZTEST(rvv_bf16, test_isa_has_bf16)
{
#ifndef CONFIG_RISCV_ISA_EXT_ZVFBFMIN
	ztest_test_fail();
#endif
	/* Reaching this point means the build accepted -march with zvfbfmin and
	 * Spike accepted the --isa; the other tests check the behaviour. */
	zassert_equal(f32_to_bf16(1.0f), 0x3f80, "scalar ref self-check");
}

ZTEST(rvv_bf16, test_vfwcvtbf16_matches_scalar)
{
	fill();
	for (size_t i = 0; i < N;) {
		i += vec_widen(&bf_a[i], &f_out[i], N - i);
	}
	for (int i = 0; i < N; i++) {
		zassert_equal(fbits(f_out[i]), fbits(bf16_to_f32(bf_a[i])),
			      "i=%d bf16=0x%04x got 0x%08x want 0x%08x", i,
			      bf_a[i], fbits(f_out[i]),
			      fbits(bf16_to_f32(bf_a[i])));
	}
}

ZTEST(rvv_bf16, test_vfncvtbf16_matches_scalar)
{
	fill();
	for (size_t i = 0; i < N;) {
		i += vec_narrow(&f_in[i], &bf_out[i], N - i);
	}
	for (int i = 0; i < N; i++) {
		uint16_t want = f32_to_bf16(f_in[i]);

		zassert_equal(bf_out[i], want,
			      "i=%d f32=0x%08x got 0x%04x want 0x%04x", i,
			      fbits(f_in[i]), bf_out[i], want);
	}
}

ZTEST(rvv_bf16, test_vfwmacc_altfmt_matches_scalar)
{
	fill();
	for (int i = 0; i < N; i++) {
		f_out[i] = (float)i * 0.125f;
		f_ref[i] = __builtin_fmaf(bf16_to_f32(bf_a[i]),
					  bf16_to_f32(bf_b[i]), f_out[i]);
	}
	for (size_t i = 0; i < N;) {
		i += vec_wmacc_alt(&bf_a[i], &bf_b[i], &f_out[i], N - i);
	}
	for (int i = 0; i < N; i++) {
		zassert_equal(fbits(f_out[i]), fbits(f_ref[i]),
			      "i=%d got 0x%08x want 0x%08x", i, fbits(f_out[i]),
			      fbits(f_ref[i]));
	}
}

ZTEST(rvv_bf16, test_vfadd_altfmt_matches_scalar)
{
	fill();
	for (int i = 0; i < N; i++) {
		/* both inputs have 8 significant bits and similar exponents, so
		 * the f32 sum is exact and one rounding to bf16 is the whole
		 * story (no double rounding in the reference). */
		bf_ref[i] = f32_to_bf16(bf16_to_f32(bf_a[i]) +
					bf16_to_f32(bf_b[i]));
	}
	for (size_t i = 0; i < N;) {
		i += vec_add_alt(&bf_a[i], &bf_b[i], &bf_out[i], N - i);
	}
	for (int i = 0; i < N; i++) {
		zassert_equal(bf_out[i], bf_ref[i],
			      "i=%d a=0x%04x b=0x%04x got 0x%04x want 0x%04x", i,
			      bf_a[i], bf_b[i], bf_out[i], bf_ref[i]);
	}
}

ZTEST_SUITE(rvv_bf16, NULL, NULL, NULL, NULL, NULL);
