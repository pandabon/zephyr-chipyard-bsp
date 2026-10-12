/*
 * SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
 *
 * Atlas host tests ported from the Atlas team's own bring-up suite.
 *
 * LICENSING: the IMEM program arrays below are copied from the course tapeout repo
 * (tests/, a fork of Chipyard); that repo is BSD-3-Clause, Copyright (c) The Regents of
 * the University of California, full text in ../LICENSE.tapeout-chipyard. The surrounding
 * Zephyr host code (I/O, timeouts, result reporting) is ours, Apache-2.0.
 *
 * CREDIT (every author of the copied material, from `git log --follow` in the course tapeout
 * repo at 48c3a7d11f6de3f0cecb33ae6a31c24ec26ff9d8, submodule sp26-atlas-acc 2ae0bef209df):
 *   - tests/atlas_alu_basic.c ................ Eric Wen, Nicolas Reed
 *   - tests/saturn_atlas_vmem_smoke.c ........ Nicolas Reed
 *   - tests/saturn_atlas_pause_resume.c ...... Nicolas Reed, kellytou
 *   - tests/saturn_atlas_buffered_optB_restart.c  Nicolas Reed
 *   - tests/saturn_atlas_buffered_optA_end_jal.c  Nicolas Reed, kellytou
 *   - tests/saturn_atlas_buffered_lower_first.c   Nicolas Reed, kellytou
 *   - Atlas kernels the IMEM arrays were assembled from (sp26-atlas-acc
 *     baremetal/assembly/saturn_atlas_cooperative/{saturn_atlas_two_phase,sab_a_to_high,sab_b}.S):
 *     Nicolas Reed, rylee4761
 * (the Atlas/Saturn team, EE194 Sp26). Our port: Jonathan Lin.
 *
 * Source of every test: tapeout-chipyard/tests/ (run by the Atlas/Saturn team in VCS on
 * EE290SimConfig and, via run_post_gate_atlas_tests.sh, on the gate-level netlist of
 * EE290TapeoutConfig). The IMEM images are copied word for word. The host code follows the
 * same algorithm with Zephyr I/O and a TIMEOUT instead of upstream's 200-million-iteration
 * spin when Atlas never signals done.
 *
 *   alu_basic        atlas_alu_basic.c          103-word ALU self-check program
 *   vmem_scalar      saturn_atlas_vmem_smoke.c  host scalar round trip in VMEM
 *   vmem_vector      saturn_atlas_vmem_smoke.c  host RVV round trip in VMEM
 *   pause_resume     saturn_atlas_pause_resume.c  Atlas -> Saturn RVV -> Atlas
 *   buffered_optB    saturn_atlas_buffered_optB_restart.c   stage B, restart
 *   buffered_optA    saturn_atlas_buffered_optA_end_jal.c   B staged while A runs
 *   buffered_lowfirst saturn_atlas_buffered_lower_first.c   B overwrites tramp.
 *
 * Output (grep-able):
 *   ATLASK <name>=PASS|FAIL|TIMEOUT      one per test
 *   ATLASK SUMMARY pass=N fail=N timeout=N of N
 *   ATLAS KERNELS=PASS|FAIL              final line, also the exit code
 *
 * Not ported (they need generated golden headers, DRAM at 0x9000_0000 or BF16/FP8 data):
 * tri_phase*, smolvla_compose*, quad_phase_large, pi0_slice, vmem_dram_dual, 8dma_rvv_vmem,
 * fp8_*_bridge, 4rung_2bank_arb, 3way_arb, dmem_sbus_dma. samples/atlas_upstream/tests.cmake
 * lists them.
 *
 * As upstream: no printk between atlas_start() and the host's concurrent IMEM staging.
 * UART/HTIF output takes thousands of cycles and the kernel's busy loop would finish first.
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/sys_io.h>
#include <riscv_vector.h>
#include <chipyard/sim_exit.h>

#if !DT_HAS_COMPAT_STATUS_OKAY(ucb_bar_atlas)
#error "No enabled ucb-bar,atlas node in the devicetree (see dts/riscv/chipyard/penguin.dtsi)"
#endif

#define ATLAS_NODE DT_COMPAT_GET_ANY_STATUS_OKAY(ucb_bar_atlas)
#define IMEM_BASE ((uintptr_t)DT_REG_ADDR_BY_NAME(ATLAS_NODE, imem))
#define IMEM_SIZE ((size_t)DT_REG_SIZE_BY_NAME(ATLAS_NODE, imem))
#define CSR_BASE  ((uintptr_t)DT_REG_ADDR_BY_NAME(ATLAS_NODE, csr))
#define VMEM_BASE ((uintptr_t)DT_REG_ADDR_BY_NAME(ATLAS_NODE, vmem))

/* CSR offsets (atlas_mmio.h / CSRFile.scala:7-18) */
#define CSR_CYCLE   0x00
#define CSR_INSTCNT 0x04
#define CSR_STATUS  0x08
#define CSR_ILL_PC  0x0C
#define CSR_DBG0    0x10
#define CSR_DBG1    0x14
#define CSR_EXEC    0x18

#define ST_HALTED(s) ((s) & 1u)
#define ST_REASON(s) (((s) >> 1) & 3u)
#define HALT_ILLEGAL 1u
#define HALT_ECALL   2u

/* Upstream ATLAS_IMEM_HALF_BYTES / 4: word index of the upper IMEM half. */
#define UPPER_HALF_WORD (IMEM_SIZE / 2 / 4)

enum res { R_PASS, R_FAIL, R_TIMEOUT };
static const char *const res_name[] = { "PASS", "FAIL", "TIMEOUT" };

static inline uint32_t csr_rd(unsigned int off) { return sys_read32(CSR_BASE + off); }
static inline void csr_wr(unsigned int off, uint32_t v) { sys_write32(v, CSR_BASE + off); }
static inline void fence_io(void) { __asm__ volatile("fence iorw, iorw" ::: "memory"); }

static inline uint64_t mcycle(void)
{
	unsigned long v;

	__asm__ volatile("csrr %0, mcycle" : "=r"(v));
	return v;
}

#define TIMEOUT_TICKS ((uint64_t)CONFIG_ATLAS_KERNELS_TIMEOUT_MCYCLES * 1000000ull)

static inline void atlas_stop(void) { csr_wr(CSR_EXEC, 0); }
static inline void atlas_start(void) { csr_wr(CSR_EXEC, 1); }
static inline void imem_wr(uint32_t word, uint32_t v) { sys_write32(v, IMEM_BASE + 4u * word); }
static inline uint32_t imem_rd(uint32_t word) { return sys_read32(IMEM_BASE + 4u * word); }

/* Stop Atlas and clear the mailboxes, which survive a restart and would mask a failure.
 * Same preamble as every upstream test.
 */
static void atlas_reset_state(void)
{
	atlas_stop();
	csr_wr(CSR_DBG0, 0);
	csr_wr(CSR_DBG1, 0);
	sys_write32(0, VMEM_BASE);
	fence_io();
}

/* Write n words to IMEM at word index base and read them back. IMEM must not be read while
 * Atlas runs, so callers use this on a halted core except in the race tests. Returns the
 * number of mismatches.
 */
static int stage_kernel(uint32_t base, const uint32_t *w, uint32_t n, const char *label)
{
	int bad = 0;

	for (uint32_t i = 0; i < n; i++) {
		imem_wr(base + i, w[i]);
	}
	fence_io();
	for (uint32_t i = 0; i < n; i++) {
		uint32_t got = imem_rd(base + i);

		if (got != w[i]) {
			printk("  IMEM MISMATCH[%s word %u]: got 0x%08x exp 0x%08x\n", label,
			       base + i, got, w[i]);
			bad++;
		}
	}
	return bad;
}

/* Wait for status.halted or the timeout. On timeout, stop the core so the next test starts
 * from a halted state. Returns true if it halted.
 */
static bool wait_halted(uint32_t *status)
{
	uint64_t t0 = mcycle();
	uint32_t st;

	do {
		st = csr_rd(CSR_STATUS);
		if (ST_HALTED(st)) {
			*status = st;
			return true;
		}
	} while (mcycle() - t0 < TIMEOUT_TICKS);
	*status = st;
	printk("  TIMEOUT waiting for status.halted (status=0x%08x, host mcycles=%llu): "
	       "forcing execControl=0\n", st, (unsigned long long)(mcycle() - t0));
	atlas_stop();
	fence_io();
	return false;
}

static void print_counters(void)
{
	printk("  atlas cycles=%u instcnt=%u\n", csr_rd(CSR_CYCLE), csr_rd(CSR_INSTCNT));
}

/* ======================================================================
 * alu_basic  (atlas_alu_basic.c)
 *
 * 103-word program: 13 blocks, each computes one ALU result, compares it with
 * a constant, and on mismatch does "csrw dbg0, x28" where x28 = block number
 * (1-based) and spins in "jal x0,0". If every block passes it writes dbg0 = 1
 * and spins too. It never ECALLs, so completion is "dbg0 != 0", not
 * status.halted, and the host must stop the core afterwards.
 *
 * Blocks (decoded from the words): 1 constant compare (42), 2 ADD, 3 SUB,
 * 4 AND, 5 OR, 6 XOR, 7 SLL, 8 SRL, 9 SLT, 10 LUI, 11 LUI+ADDI,
 * 12 ADDI(negative), 13 BNE not-taken. dbg0 = 1 is PASS; any other value is
 * the failing block number (a failure in block 1 would also show as 1 and
 * be mistaken for PASS; upstream has the same blind spot, block 1 is just
 * "ADDI x31,x0,42 == ADDI x30,x0,42").
 * ====================================================================== */
static const uint32_t alu_prog[] = {
	0x00100E13, 0x02A00F93, 0x02A00F13, 0x0DEF9063, 0x00000013, 0x00000013, 0x001E0E13,
	0x01E00093, 0x04600113, 0x00208FB3, 0x06400F13, 0x0BEF9863, 0x00000013, 0x00000013,
	0x001E0E13, 0x40110FB3, 0x02800F13, 0x0BEF9263, 0x00000013, 0x00000013, 0x001E0E13,
	0x0FF00093, 0x00F00113, 0x0020FFB3, 0x00F00F13, 0x09EF9A63, 0x00000013, 0x00000013,
	0x001E0E13, 0x0A000093, 0x00500113, 0x0020EFB3, 0x0A500F13, 0x09EF9263, 0x00000013,
	0x00000013, 0x001E0E13, 0x0FF00093, 0x00F00113, 0x0020CFB3, 0x0F000F13, 0x07EF9A63,
	0x00000013, 0x00000013, 0x001E0E13, 0x00100093, 0x00400113, 0x00209FB3, 0x01000F13,
	0x07EF9263, 0x00000013, 0x00000013, 0x001E0E13, 0x10000093, 0x00400113, 0x0020DFB3,
	0x01000F13, 0x05EF9A63, 0x00000013, 0x00000013, 0x001E0E13, 0xFFB00093, 0x00A00113,
	0x0020AFB3, 0x00100F13, 0x05EF9263, 0x00000013, 0x00000013, 0x001E0E13, 0x12345FB7,
	0x12345F37, 0x03EF9C63, 0x00000013, 0x00000013, 0x001E0E13, 0xABCDEFB7, 0x123F8F93,
	0xABCDEF37, 0x123F0F13, 0x03EF9463, 0x00000013, 0x00000013, 0x001E0E13, 0x06400093,
	0xFE208F93, 0x04600F13, 0x01EF9D63, 0x00000013, 0x00000013, 0x001E0E13, 0x3E700013,
	0x00001863, 0x00000013, 0x00000013, 0x00100093, 0xC1009073, 0x0000006F, 0x00000013,
	0x00000013, 0xC10E1073, 0x0000006F, 0x00000013, 0x00000013,
};

static enum res test_alu_basic(void)
{
	uint32_t dbg0 = 0;
	uint64_t t0;
	bool done = false;

	atlas_reset_state();
	if (stage_kernel(0, alu_prog, ARRAY_SIZE(alu_prog), "alu")) {
		return R_FAIL;
	}
	atlas_start();
	fence_io();
	t0 = mcycle();
	do {
		dbg0 = csr_rd(CSR_DBG0);
		if (dbg0 != 0) {
			done = true;
			break;
		}
	} while (mcycle() - t0 < TIMEOUT_TICKS);
	/* Counters first, then stop: the program spins forever in "jal x0,0". */
	uint32_t cyc = csr_rd(CSR_CYCLE), inst = csr_rd(CSR_INSTCNT), st = csr_rd(CSR_STATUS);

	atlas_stop();
	fence_io();
	printk("  dbg0=%u cycles=%u instcnt=%u status=0x%08x\n", dbg0, cyc, inst, st);
	if (!done) {
		printk("  TIMEOUT: dbg0 stayed 0 (Atlas never started or never reached the end)\n");
		return R_TIMEOUT;
	}
	if (dbg0 != 1) {
		printk("  ALU block %u failed (see the block list in main.c)\n", dbg0);
		return R_FAIL;
	}
	return R_PASS;
}

/* ======================================================================
 * vmem_scalar / vmem_vector  (saturn_atlas_vmem_smoke.c)
 * Host-only: no Atlas program runs. 16 scalar words at VMEM+0 with pattern
 * 0xDEAD0000|i; 64 words via RVV (vle32/vse32 strip-mined) at VMEM+0x1000
 * with pattern 0xC0DE0000|i, read back through RVV into a DRAM buffer.
 * ====================================================================== */
static enum res test_vmem_scalar(void)
{
	int bad = 0;

	atlas_stop();
	for (uint32_t i = 0; i < 16; i++) {
		sys_write32(0xDEAD0000u | i, VMEM_BASE + i * 4);
	}
	fence_io();
	for (uint32_t i = 0; i < 16; i++) {
		uint32_t got = sys_read32(VMEM_BASE + i * 4), exp = 0xDEAD0000u | i;

		if (got != exp) {
			printk("  SCALAR MISMATCH[%u]: got 0x%08x exp 0x%08x\n", i, got, exp);
			bad++;
		}
	}
	return bad ? R_FAIL : R_PASS;
}

#define NV 64
static uint32_t vsrc[NV], vdst[NV];

static enum res test_vmem_vector(void)
{
#ifdef CONFIG_ATLAS_KERNELS_VMEM_VECTOR
	const uintptr_t vmem = VMEM_BASE + 0x1000;
	int bad = 0;

	atlas_stop();
	for (uint32_t i = 0; i < NV; i++) {
		vsrc[i] = 0xC0DE0000u | i;
		vdst[i] = 0;
	}
	size_t rem = NV;
	uint32_t *sp = vsrc;
	uintptr_t vp = vmem;

	while (rem > 0) {
		size_t vl = __riscv_vsetvl_e32m1(rem);

		__riscv_vse32_v_u32m1((uint32_t *)vp, __riscv_vle32_v_u32m1(sp, vl), vl);
		rem -= vl;
		sp += vl;
		vp += vl * 4;
	}
	fence_io();
	rem = NV;
	uint32_t *dp = vdst;

	vp = vmem;
	while (rem > 0) {
		size_t vl = __riscv_vsetvl_e32m1(rem);

		__riscv_vse32_v_u32m1(dp, __riscv_vle32_v_u32m1((uint32_t *)vp, vl), vl);
		rem -= vl;
		dp += vl;
		vp += vl * 4;
	}
	for (uint32_t i = 0; i < NV; i++) {
		if (vdst[i] != vsrc[i]) {
			printk("  VECTOR MISMATCH[%u]: got 0x%08x exp 0x%08x\n", i, vdst[i],
			       vsrc[i]);
			bad++;
		}
	}
	return bad ? R_FAIL : R_PASS;
#else
	printk("  skipped (CONFIG_ATLAS_KERNELS_VMEM_VECTOR=n)\n");
	return R_PASS;
#endif
}

/* ======================================================================
 * pause_resume  (saturn_atlas_pause_resume.c)
 * Kernel selects its phase from dbg1 (CSR 0xC11):
 *   phase 0 (dbg1 == 0): VMEM[i*4] = 0xA0000000 | i for i in 0..15; dbg0 = 1; ECALL
 *   host (Saturn RVV): verify the seed, add 0x10000 to each word, re-verify
 *   phase 1 (dbg1 == 1): checks VMEM[i*4] == 0xA0010000 | i; dbg0 = 2; ECALL
 * If phase 1 finds VMEM[i] wrong (host stores not visible to Atlas) the kernel
 * jumps to its tail: dbg0 = 100 + i (i = first bad word), then ECALL. So
 * dbg0 >= 100 in phase 1 means "Atlas did not see the host's RVV stores".
 * ====================================================================== */
static const uint32_t pr_prog[] = {
	0xC11020F3, 0x00008463, 0x00000013, 0x0200006F, 0x00000013, 0xA0000137, 0x00000193,
	0x00000213, 0x01000293, 0x00416333, 0x0061A023, 0x00101067, 0x00418193, 0x00120213,
	0xFE524BE3, 0x00000013, 0x00100093, 0xC1009073, 0x00000073, 0xA0010137, 0x00000193,
	0x00000213, 0x01000293, 0x0001A303, 0x00201067, 0x004163B3, 0x00731963, 0x00000013,
	0x00418193, 0x00120213, 0xFE5249E3, 0x00000013, 0x00200093, 0xC1009073, 0x00000073,
	0x06420413, 0xC1041073, 0x00000073,
};

/* Phase check shared by both phases: halted, ECALL, expected dbg0. */
static bool phase_ok(const char *label, uint32_t want_dbg0)
{
	uint32_t st, dbg0, reason;
	bool halted = wait_halted(&st);

	dbg0 = csr_rd(CSR_DBG0);
	reason = ST_REASON(st);
	printk("  [%s] status=0x%08x halt_reason=%u dbg0=%u\n", label, st, reason, dbg0);
	if (!halted) {
		return false;
	}
	if (reason != HALT_ECALL || dbg0 != want_dbg0) {
		printk("  expected halt_reason=%u dbg0=%u\n", HALT_ECALL, want_dbg0);
		return false;
	}
	return true;
}

static int saturn_transform_vmem(void)
{
#ifdef CONFIG_ATLAS_KERNELS_VMEM_VECTOR
	static uint32_t buf[16];
	int bad = 0;
	size_t rem = 16;
	uintptr_t vp = VMEM_BASE;
	uint32_t *bp = buf;

	while (rem > 0) { /* vector load VMEM -> buf, to verify Atlas' phase-0 seed */
		size_t vl = __riscv_vsetvl_e32m1(rem);

		__riscv_vse32_v_u32m1(bp, __riscv_vle32_v_u32m1((uint32_t *)vp, vl), vl);
		rem -= vl;
		vp += vl * 4;
		bp += vl;
	}
	for (uint32_t i = 0; i < 16; i++) {
		if (buf[i] != (0xA0000000u | i)) {
			printk("  SEED MISMATCH[%u]: got 0x%08x exp 0x%08x\n", i, buf[i],
			       0xA0000000u | i);
			bad++;
		}
	}
	if (bad) {
		return bad;
	}
	rem = 16;
	vp = VMEM_BASE;
	while (rem > 0) { /* in place: VMEM[i] += 0x10000 */
		size_t vl = __riscv_vsetvl_e32m1(rem);
		vuint32m1_t v = __riscv_vle32_v_u32m1((uint32_t *)vp, vl);

		__riscv_vse32_v_u32m1((uint32_t *)vp, __riscv_vadd_vx_u32m1(v, 0x10000u, vl), vl);
		rem -= vl;
		vp += vl * 4;
	}
	fence_io();
	for (uint32_t i = 0; i < 16; i++) { /* scalar read back */
		uint32_t got = sys_read32(VMEM_BASE + i * 4);

		if (got != (0xA0010000u | i)) {
			printk("  TRANSFORM MISMATCH[%u]: got 0x%08x exp 0x%08x\n", i, got,
			       0xA0010000u | i);
			bad++;
		}
	}
	return bad;
#else
	/* Scalar stand-in for Saturn so the Atlas handshake is still tested. */
	int bad = 0;

	for (uint32_t i = 0; i < 16; i++) {
		uint32_t v = sys_read32(VMEM_BASE + i * 4);

		if (v != (0xA0000000u | i)) {
			bad++;
		}
		sys_write32(v + 0x10000u, VMEM_BASE + i * 4);
	}
	fence_io();
	return bad;
#endif
}

static enum res test_pause_resume(void)
{
	atlas_reset_state();
	if (stage_kernel(0, pr_prog, ARRAY_SIZE(pr_prog), "pause_resume")) {
		return R_FAIL;
	}
	atlas_start();
	fence_io();
	if (!phase_ok("phase 0", 1)) {
		return csr_rd(CSR_STATUS) & 1 ? R_FAIL : R_TIMEOUT;
	}
	if (saturn_transform_vmem()) {
		return R_FAIL;
	}
	csr_wr(CSR_DBG0, 0);
	csr_wr(CSR_DBG1, 1);
	fence_io();
	atlas_start();
	fence_io();
	if (!phase_ok("phase 1", 2)) {
		return csr_rd(CSR_STATUS) & 1 ? R_FAIL : R_TIMEOUT;
	}
	print_counters();
	return R_PASS;
}

/* ======================================================================
 * Buffered dual-kernel IMEM load (three variants, same kernels A and B).
 *
 * Kernel B (all variants): reads VMEM[0], expects 0xAAAAAAAA (A's marker),
 * on match dbg0 = 2 + ECALL, else dbg0 = 0xBAD + ECALL. So dbg0 == 2 proves
 * BOTH that A ran and that B ran after it.
 * Kernel A: busy-loop, then VMEM[0] = 0xAAAAAAAA, then hand over to B.
 * Trampoline: LUI x1,4 ; JALR x0,x1,0 -> jumps to byte 0x10000 (upper half).
 *
 *  optB  : A ends with dbg0=1 + ECALL; host (Atlas halted) writes B over the
 *          trampoline, execControl=1 again. Deterministic: restart dispatch.
 *  optA  : A is at IMEM[0]; host writes B at 0x10000 WHILE A busy-loops; A ends
 *          with JALR to 0x10000. Tests concurrent host-write / Atlas-fetch on
 *          the 1R1W IMEM. Timing race.
 *  lowfirst: trampoline at 0 -> A at 0x10000; host overwrites IMEM[0] with B
 *          while A runs; A ends with JALR to 0. Failure mode is reversed
 *          (lands on the trampoline, loops forever -> TIMEOUT here).
 * ====================================================================== */
static const uint32_t k_tramp[] = { 0x000040b7, 0x00008067, 0x00000013, 0x00000013 };
static const uint32_t k_b[] = {
	0x00000193, 0x0001a203, 0x00201067, 0xaaaab2b7, 0xaaa28293, 0x00521663, 0x00000013,
	0x00000013, 0x00200093, 0xc1009073, 0x00000073, 0x000010b7, 0xbad08093, 0xc1009073,
	0x00000073,
};
static const uint32_t k_a_optb[] = {
	0x00001537, 0x38850513, 0x00000593, 0x00158593, 0xfea5cfe3, 0x00000013, 0x00000013,
	0xaaaab137, 0xaaa10113, 0x00000193, 0x0021a023, 0x00201067, 0x00100093, 0xc1009073,
	0x00000073,
};
/* optA / lowfirst: LI x10,500000 busy loop; differ only in the last JALR target. */
static const uint32_t k_a_opta[] = {
	0x0007a537, 0x12050513, 0x00000593, 0x00158593, 0xfea5cfe3, 0x00000013, 0x00000013,
	0xaaaab137, 0xaaa10113, 0x00000193, 0x0021a023, 0x00201067, 0x000040b7, 0x00008067,
	0x00000013, 0x00000013,
};
static const uint32_t k_a_lowfirst[] = {
	0x0007a537, 0x12050513, 0x00000593, 0x00158593, 0xfea5cfe3, 0x00000013, 0x00000013,
	0xaaaab137, 0xaaa10113, 0x00000193, 0x0021a023, 0x00201067, 0x00000093, 0x00008067,
	0x00000013, 0x00000013,
};

/* Common verdict for B: halted by ECALL, dbg0 == 2, marker == 0xAAAAAAAA. */
static enum res buffered_verdict(void)
{
	uint32_t st;
	bool halted = wait_halted(&st);
	uint32_t dbg0 = csr_rd(CSR_DBG0), marker = sys_read32(VMEM_BASE);
	uint32_t ill = csr_rd(CSR_ILL_PC);

	printk("  status=0x%08x halt_reason=%u dbg0=%u marker=0x%08x illegal_pc=0x%x\n", st,
	       ST_REASON(st), dbg0, marker, ill);
	print_counters();
	if (!halted) {
		printk("  Atlas never halted: B staging lost the race / landed on the trampoline\n");
		return R_TIMEOUT;
	}
	if (ST_REASON(st) != HALT_ECALL) {
		printk("  halt_reason %u, expected %u (ECALL)%s\n", ST_REASON(st), HALT_ECALL,
		       ST_REASON(st) == HALT_ILLEGAL ? ": Atlas fetched a half-written IMEM word" : "");
		return R_FAIL;
	}
	if (marker != 0xAAAAAAAAu) {
		printk("  marker 0x%08x, expected 0xAAAAAAAA: kernel A never ran\n", marker);
		return R_FAIL;
	}
	if (dbg0 != 2) {
		printk("  dbg0 %u, expected 2: kernel B never completed (0xBAD = marker check failed)\n",
		       dbg0);
		return R_FAIL;
	}
	return R_PASS;
}

static enum res test_buffered_optb(void)
{
	uint32_t st, dbg0;

	atlas_reset_state();
	if (stage_kernel(0, k_tramp, ARRAY_SIZE(k_tramp), "tramp") ||
	    stage_kernel(UPPER_HALF_WORD, k_a_optb, ARRAY_SIZE(k_a_optb), "A")) {
		return R_FAIL;
	}
	atlas_start();
	fence_io();
	if (!wait_halted(&st)) {
		return R_TIMEOUT;
	}
	dbg0 = csr_rd(CSR_DBG0);
	printk("  [A] status=0x%08x halt_reason=%u dbg0=%u marker=0x%08x\n", st, ST_REASON(st),
	       dbg0, sys_read32(VMEM_BASE));
	if (ST_REASON(st) != HALT_ECALL || dbg0 != 1 || sys_read32(VMEM_BASE) != 0xAAAAAAAAu) {
		return R_FAIL;
	}
	if (stage_kernel(0, k_b, ARRAY_SIZE(k_b), "B")) {
		return R_FAIL;
	}
	csr_wr(CSR_DBG0, 0);
	fence_io();
	atlas_start();
	fence_io();
	return buffered_verdict();
}

#ifdef CONFIG_ATLAS_KERNELS_RACE_TESTS
static enum res test_buffered_opta(void)
{
	atlas_reset_state();
	if (stage_kernel(0, k_a_opta, ARRAY_SIZE(k_a_opta), "A")) {
		return R_FAIL;
	}
	atlas_start();
	fence_io();
	/* NO printk from here until B is staged (see file header). */
	if (stage_kernel(UPPER_HALF_WORD, k_b, ARRAY_SIZE(k_b), "B")) {
		return R_FAIL;
	}
	return buffered_verdict();
}

static enum res test_buffered_lowfirst(void)
{
	atlas_reset_state();
	if (stage_kernel(0, k_tramp, ARRAY_SIZE(k_tramp), "tramp") ||
	    stage_kernel(UPPER_HALF_WORD, k_a_lowfirst, ARRAY_SIZE(k_a_lowfirst), "A")) {
		return R_FAIL;
	}
	atlas_start();
	fence_io();
	/* NO printk from here until B is staged. */
	if (stage_kernel(0, k_b, ARRAY_SIZE(k_b), "B")) {
		return R_FAIL;
	}
	return buffered_verdict();
}
#endif

/* ------------------------------------------------------------------ main */

struct test {
	const char *name;
	enum res (*fn)(void);
	const char *what;
};

static const struct test tests[] = {
	{ "alu_basic", test_alu_basic, "103-word ALU self-check program, dbg0==1" },
	{ "vmem_scalar", test_vmem_scalar, "host scalar write/read 16 words in VMEM" },
	{ "vmem_vector", test_vmem_vector, "host RVV write/read 64 words in VMEM" },
	{ "pause_resume", test_pause_resume, "Atlas seeds VMEM, Saturn RVV edits it, Atlas verifies" },
	{ "buffered_optB", test_buffered_optb, "stage kernel B while halted, restart" },
#ifdef CONFIG_ATLAS_KERNELS_RACE_TESTS
	{ "buffered_optA", test_buffered_opta, "write kernel B into IMEM while A runs, A jumps to B" },
	{ "buffered_lowfirst", test_buffered_lowfirst, "overwrite IMEM[0] while A runs, A jumps to 0" },
#endif
};

int main(void)
{
	int n[3] = { 0, 0, 0 };

	printk("\n*** Atlas upstream host tests ***\n");
	printk("IMEM 0x%lx (%u B)  CSR 0x%lx  VMEM 0x%lx  timeout %d M host mcycles\n",
	       (unsigned long)IMEM_BASE, (unsigned)IMEM_SIZE, (unsigned long)CSR_BASE,
	       (unsigned long)VMEM_BASE, CONFIG_ATLAS_KERNELS_TIMEOUT_MCYCLES);
	printk("Every test prints its name first. If the console stops, that test hung the\n"
	       "bus (not a timeout: a timeout prints TIMEOUT and moves on). Run atlas_smoke\n"
	       "first if the very first access traps (no Atlas at these addresses).\n\n");
	printk("About to read Atlas status (first access) ...\n");
	printk("  status = 0x%08x (expect halted=1 after reset)\n\n", csr_rd(CSR_STATUS));

	for (size_t i = 0; i < ARRAY_SIZE(tests); i++) {
		printk("== %s: %s\n", tests[i].name, tests[i].what);
		enum res r = tests[i].fn();

		atlas_stop();
		fence_io();
		n[r]++;
		printk("ATLASK %s=%s\n\n", tests[i].name, res_name[r]);
	}

	bool ok = n[R_FAIL] == 0 && n[R_TIMEOUT] == 0;

	printk("ATLASK SUMMARY pass=%d fail=%d timeout=%d of %d\n", n[R_PASS], n[R_FAIL],
	       n[R_TIMEOUT], (int)ARRAY_SIZE(tests));
	printk("ATLAS KERNELS=%s\n", ok ? "PASS" : "FAIL");
	chipyard_sim_exit(ok ? 0 : 1);
}
