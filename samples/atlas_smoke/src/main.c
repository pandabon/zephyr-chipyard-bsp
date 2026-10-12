/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Atlas NPU first bring-up test. Raw register access only (no driver). Meant for hardware;
 * Spike has no Atlas model and traps at the first access.
 *
 * Machine-readable result lines start with "ATLAS " (grep for them).
 * Every step prints BEFORE it runs: if the console stops, the last
 * "  step:" line is the access that hung.
 *
 * Register map: atlas-npu CSRFile.scala:7-18 (offsets, status bits),
 * ScalarCore.scala:38-54 (bases). Core flow: baremetal/assembler.py:211-262.
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/sys_io.h>
#include <chipyard/sim_exit.h>

#include "kernels_gen.h"

/* Addresses come from the devicetree when it has a ucb-bar,atlas node, else
 * from Kconfig.
 */
#if DT_HAS_COMPAT_STATUS_OKAY(ucb_bar_atlas)
#define ATLAS_NODE DT_COMPAT_GET_ANY_STATUS_OKAY(ucb_bar_atlas)
#define IMEM_BASE ((uintptr_t)DT_REG_ADDR_BY_NAME(ATLAS_NODE, imem))
#define IMEM_SIZE ((size_t)DT_REG_SIZE_BY_NAME(ATLAS_NODE, imem))
#define CSR_BASE  ((uintptr_t)DT_REG_ADDR_BY_NAME(ATLAS_NODE, csr))
#define VMEM_BASE ((uintptr_t)DT_REG_ADDR_BY_NAME(ATLAS_NODE, vmem))
#define ADDR_SRC  "devicetree (ucb-bar,atlas node)"
#else
#define IMEM_BASE ((uintptr_t)CONFIG_ATLAS_SMOKE_IMEM_BASE)
#define IMEM_SIZE ((size_t)CONFIG_ATLAS_SMOKE_IMEM_SIZE)
#define CSR_BASE  ((uintptr_t)CONFIG_ATLAS_SMOKE_CSR_BASE)
#define VMEM_BASE ((uintptr_t)CONFIG_ATLAS_SMOKE_VMEM_BASE)
#define ADDR_SRC  "Kconfig (no atlas node in devicetree)"
#endif

/* CSR word offsets (CSRFile.scala:7-18) */
#define CSR_CYCLE    0x00 /* RW free-running cycle counter */
#define CSR_INSTCNT  0x04 /* RW retired scalar instructions */
#define CSR_STATUS   0x08 /* RO bit0 halted, bits[2:1] halt_reason */
#define CSR_ILL_PC   0x0C /* RO PC of illegal instruction */
#define CSR_DBG0     0x10 /* RW mailbox, kernel CSR 0xC10 */
#define CSR_DBG1     0x14 /* RW mailbox, kernel CSR 0xC11 */
#define CSR_EXEC     0x18 /* RW bit0: 1 = start, 0 = stop */

#define ST_HALTED(s) ((s) & 1u)
#define ST_REASON(s) (((s) >> 1) & 3u)
#define REASON_NONE    0
#define REASON_ILLEGAL 1
#define REASON_ECALL   2
#define REASON_EBREAK  3

static const char *const reason_name[] = { "none", "illegal", "ecall", "ebreak" };

static inline uint32_t csr_rd(unsigned int off) { return sys_read32(CSR_BASE + off); }
static inline void csr_wr(unsigned int off, uint32_t v) { sys_write32(v, CSR_BASE + off); }

static inline void fence_io(void) { __asm__ volatile("fence iorw, iorw" ::: "memory"); }

static inline uint32_t mcycle32(void)
{
	unsigned long v;

	__asm__ volatile("csrr %0, mcycle" : "=r"(v));
	return (uint32_t)v;
}

#define STEP(...) do { printk("  step: " __VA_ARGS__); printk("\n"); } while (0)

static int failures;

static void result(const char *name, bool ok)
{
	printk("ATLAS %s=%s", name, ok ? "PASS" : "FAIL");
	if (!ok) {
		failures++;
	}
}

/* Decoded dump of every CSR. Only reads; safe at any time. */
static void dump_csrs(const char *tag)
{
	uint32_t st;

	printk("--- CSR dump (%s) @ 0x%lx ---\n", tag, (unsigned long)CSR_BASE);
	printk("  cycle      = %u\n", csr_rd(CSR_CYCLE));
	printk("  instcnt    = %u\n", csr_rd(CSR_INSTCNT));
	st = csr_rd(CSR_STATUS);
	printk("  status     = 0x%08x (halted=%u halt_reason=%u/%s)\n", st, ST_HALTED(st),
	       ST_REASON(st), reason_name[ST_REASON(st)]);
	printk("  illegal_pc = 0x%08x\n", csr_rd(CSR_ILL_PC));
	printk("  dbg0       = 0x%08x\n", csr_rd(CSR_DBG0));
	printk("  dbg1       = 0x%08x\n", csr_rd(CSR_DBG1));
	printk("  execCtl    = 0x%08x (run=%u)\n", csr_rd(CSR_EXEC), csr_rd(CSR_EXEC) & 1u);
}

/* Stop the core and clear mailboxes. Safe when already halted. */
static void core_stop_clear(void)
{
	STEP("execControl=0 (stop)");
	csr_wr(CSR_EXEC, 0);
	STEP("dbg0=0");
	csr_wr(CSR_DBG0, 0);
	STEP("dbg1=0");
	csr_wr(CSR_DBG1, 0);
	fence_io();
}

/* Write a kernel image to IMEM at offset 0 with 32-bit stores. Core must be halted. */
static bool imem_load(const uint32_t *w, size_t n)
{
	bool ok = true;

	__ASSERT(n * 4 <= IMEM_SIZE, "kernel too big");
	STEP("write %u words to IMEM 0x%lx (core halted)", (unsigned)n, (unsigned long)IMEM_BASE);
	for (size_t i = 0; i < n; i++) {
		sys_write32(w[i], IMEM_BASE + 4 * i);
	}
	fence_io();
	if (IS_ENABLED(CONFIG_ATLAS_SMOKE_VERIFY_IMEM)) {
		STEP("read back IMEM (only legal while halted)");
		for (size_t i = 0; i < n; i++) {
			uint32_t got = sys_read32(IMEM_BASE + 4 * i);

			if (got != w[i]) {
				printk("  IMEM[%u] wrote 0x%08x read 0x%08x\n", (unsigned)i, w[i], got);
				ok = false;
			}
		}
	}
	return ok;
}

struct run {
	bool timeout;
	uint32_t polls, cycles;
	uint32_t status, ill_pc, dbg0, cycle, instcnt;
};

/* Start at PC 0 and wait for status.halted. Inputs (dbg1, VMEM) must be set already. */
static void core_run(struct run *r)
{
	uint32_t t0, st = 0;

	STEP("fence + dummy status read (order PBUS/SBUS writes before start)");
	fence_io();
	(void)csr_rd(CSR_STATUS);
	STEP("execControl=1 (start; PC resets to 0, halt_reason cleared)");
	t0 = mcycle32();
	csr_wr(CSR_EXEC, 1);
	STEP("poll status.halted, limit %d polls", CONFIG_ATLAS_SMOKE_POLL_LIMIT);
	r->polls = 0;
	r->timeout = true;
	while (r->polls < CONFIG_ATLAS_SMOKE_POLL_LIMIT) {
		st = csr_rd(CSR_STATUS);
		r->polls++;
		if (ST_HALTED(st)) {
			r->timeout = false;
			break;
		}
	}
	r->cycles = mcycle32() - t0;
	if (r->timeout) {
		STEP("TIMEOUT: forcing execControl=0");
		csr_wr(CSR_EXEC, 0);
		fence_io();
	}
	STEP("read status, illegal_pc, dbg0, cycle, instcnt");
	r->status = csr_rd(CSR_STATUS);
	r->ill_pc = csr_rd(CSR_ILL_PC);
	r->dbg0 = csr_rd(CSR_DBG0);
	r->cycle = csr_rd(CSR_CYCLE);
	r->instcnt = csr_rd(CSR_INSTCNT);
}

static void run_summary(const struct run *r)
{
	printk(" polls=%u host_mcycles=%u halted=%u reason=%s illegal_pc=0x%x dbg0=0x%08x "
	       "atlas_cycle=%u instcnt=%u%s",
	       r->polls, r->cycles, ST_HALTED(r->status), reason_name[ST_REASON(r->status)],
	       r->ill_pc, r->dbg0, r->cycle, r->instcnt, r->timeout ? " TIMEOUT" : "");
}

/* ------------------------------------------------------------------ tests */

/* No kernel: only host reads/writes of the CSR block, IMEM and VMEM. */
static void test_csr_rw(void)
{
	static const uint32_t pat[] = { 0xA5A5A5A5, 0x5A5A5A5A, 0x00000000 };
	bool ok = true;

	printk("== csr_rw: dbg0/dbg1 write-read-back (no kernel)\n");
	STEP("execControl=0");
	csr_wr(CSR_EXEC, 0);
	for (size_t i = 0; i < ARRAY_SIZE(pat); i++) {
		STEP("dbg0=0x%08x dbg1=0x%08x", pat[i], ~pat[i]);
		csr_wr(CSR_DBG0, pat[i]);
		csr_wr(CSR_DBG1, ~pat[i]);
		uint32_t a = csr_rd(CSR_DBG0), b = csr_rd(CSR_DBG1);

		if (a != pat[i] || b != ~pat[i]) {
			printk("  mismatch: dbg0=0x%08x dbg1=0x%08x\n", a, b);
			ok = false;
		}
	}
	result("csr_rw", ok);
	printk("\n");
}

static void test_imem_rw(void)
{
	static const uint32_t pat[] = { 0x13579BDF, 0x2468ACE0, 0xFFFFFFFF, 0x00000001 };
	/* Word 0x100 (byte 0x400): away from the kernels at word 0. */
	const uintptr_t base = IMEM_BASE + 0x400;
	bool ok = true;

	printk("== imem_rw: IMEM write-read-back at +0x400 (core halted)\n");
	STEP("execControl=0");
	csr_wr(CSR_EXEC, 0);
	STEP("write %u words", (unsigned)ARRAY_SIZE(pat));
	for (size_t i = 0; i < ARRAY_SIZE(pat); i++) {
		sys_write32(pat[i], base + 4 * i);
	}
	fence_io();
	STEP("read back");
	for (size_t i = 0; i < ARRAY_SIZE(pat); i++) {
		uint32_t g = sys_read32(base + 4 * i);

		if (g != pat[i]) {
			printk("  IMEM+0x%x wrote 0x%08x read 0x%08x\n", (unsigned)(0x400 + 4 * i),
			       pat[i], g);
			ok = false;
		}
	}
	result("imem_rw", ok);
	printk("\n");
}

static void test_vmem_rw(void)
{
	static const uint32_t pat[] = { 0xCAFEF00D, 0x0BADBEEF, 0x80000001, 0x7FFFFFFE };
	const uintptr_t base = VMEM_BASE + 0x100; /* VMEM offset 0x100, bank 0 */
	bool ok = true;

	printk("== vmem_rw: VMEM write-read-back via host window\n");
	STEP("write %u words to VMEM 0x%lx", (unsigned)ARRAY_SIZE(pat), (unsigned long)base);
	for (size_t i = 0; i < ARRAY_SIZE(pat); i++) {
		sys_write32(pat[i], base + 4 * i);
	}
	fence_io();
	STEP("read back");
	for (size_t i = 0; i < ARRAY_SIZE(pat); i++) {
		uint32_t g = sys_read32(base + 4 * i);

		if (g != pat[i]) {
			printk("  VMEM+0x%x wrote 0x%08x read 0x%08x\n", (unsigned)(0x100 + 4 * i),
			       pat[i], g);
			ok = false;
		}
	}
	result("vmem_rw", ok);
	printk("\n");
}

static void test_k_ecall(void)
{
	struct run r;
	bool ok;

	printk("== k_ecall: write dbg0=0xA71A5001 then ECALL\n");
	core_stop_clear();
	ok = imem_load(k_ecall_words, ARRAY_SIZE(k_ecall_words));
	core_run(&r);
	ok = ok && !r.timeout && ST_HALTED(r.status) && ST_REASON(r.status) == REASON_ECALL &&
	     r.dbg0 == 0xA71A5001u;
	result("k_ecall", ok);
	run_summary(&r);
	printk("\n\n");
}

static void test_k_vmem(void)
{
	const uint32_t in0 = 0x12345678, arg = 0x0F0F0F0F, sentinel = 0xDEADBEEF;
	const uint32_t expect = in0 ^ arg;
	struct run r;
	bool ok;
	uint32_t out_w1, out_w0;

	printk("== k_vmem: dbg0 = VMEM[0] ^ dbg1 ; VMEM[4] = same ; ECALL\n");
	core_stop_clear();
	ok = imem_load(k_vmem_words, ARRAY_SIZE(k_vmem_words));
	STEP("VMEM[0]=0x%08x VMEM[4]=0x%08x (sentinel)", in0, sentinel);
	sys_write32(in0, VMEM_BASE + 0);
	sys_write32(sentinel, VMEM_BASE + 4);
	STEP("dbg1=0x%08x", arg);
	csr_wr(CSR_DBG1, arg);
	core_run(&r);
	STEP("read VMEM[0], VMEM[4]");
	out_w0 = sys_read32(VMEM_BASE + 0);
	out_w1 = sys_read32(VMEM_BASE + 4);
	ok = ok && !r.timeout && ST_REASON(r.status) == REASON_ECALL && r.dbg0 == expect &&
	     out_w1 == expect && out_w0 == in0;
	result("k_vmem", ok);
	run_summary(&r);
	printk(" expect=0x%08x VMEM[0]=0x%08x VMEM[4]=0x%08x", expect, out_w0, out_w1);
	if (!ok && !r.timeout && r.dbg0 == expect && out_w1 == sentinel) {
		printk(" (dbg0 right but VMEM store never landed: store/ECALL race or VMEM path)");
	}
	printk("\n\n");
}

static void test_k_illegal(void)
{
	struct run r;
	bool ok;

	printk("== k_illegal: dbg0=0xBAD00001 then an all-zero (illegal) word at word 4\n");
	core_stop_clear();
	ok = imem_load(k_illegal_words, ARRAY_SIZE(k_illegal_words));
	core_run(&r);
	/* PC unit is not certain: word index (4) or byte address (0x10). */
	ok = ok && !r.timeout && ST_REASON(r.status) == REASON_ILLEGAL && r.dbg0 == 0xBAD00001u &&
	     (r.ill_pc == 4 || r.ill_pc == 0x10);
	result("k_illegal", ok);
	run_summary(&r);
	printk(" (illegal_pc unit: %s)\n\n",
	       r.ill_pc == 4 ? "word index" : r.ill_pc == 0x10 ? "byte address" : "UNEXPECTED");
}

int main(void)
{
	printk("\n*** Atlas smoke test ***\n");
	printk("Atlas addresses from: %s\n", ADDR_SRC);
	printk("IMEM 0x%lx (%u B)  CSR 0x%lx  VMEM 0x%lx\n", (unsigned long)IMEM_BASE,
	       (unsigned)IMEM_SIZE, (unsigned long)CSR_BASE,
	       (unsigned long)VMEM_BASE);
	printk("If the console stops or a trap prints next, the FIRST Atlas access failed:\n"
	       "no Atlas at these addresses (Spike, wrong bitstream) or the bus hangs.\n");
	printk("About to read Atlas CSR block (first access) ...\n");

	dump_csrs("before");
	printk("\n");

	test_csr_rw();
	test_imem_rw();
	test_vmem_rw();
	test_k_ecall();
	test_k_vmem();
	test_k_illegal();

	STEP("final execControl=0");
	csr_wr(CSR_EXEC, 0);
	dump_csrs("after");

	printk("ATLAS SMOKE=%s failures=%d\n", failures ? "FAIL" : "PASS", failures);
	chipyard_sim_exit(failures ? 1 : 0);
}
