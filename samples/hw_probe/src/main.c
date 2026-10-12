/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Hardware probe: measures uncertain hardware facts in one run.
 *  - Each access that could trap or hang is announced with printk() first, so the last
 *    console line names the culprit.
 *  - A mismatch is recorded and the probe continues. Only a bus trap or hang stops it (a
 *    trap goes through Zephyr's fatal handler: message, exit 1).
 *  - Every fact is also printed as a "PROBE key=value" line.
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/version.h>
#include <riscv_vector.h>
#include <chipyard/sim_exit.h>
#include <stdint.h>
#include <string.h>

/* ---- result bookkeeping ------------------------------------------------ */

enum res { R_PASS, R_FAIL, R_WARN, R_SKIP, R_INFO };

static const char *const res_name[] = { "PASS", "FAIL", "WARN", "SKIP", "INFO" };

#define MAX_CHECKS 64
static struct {
	const char *name;
	enum res r;
} checks[MAX_CHECKS];
static int nchecks;
static int nfail;

static void record(const char *name, enum res r)
{
	if (nchecks < MAX_CHECKS) {
		checks[nchecks].name = name;
		checks[nchecks].r = r;
		nchecks++;
	}
	if (r == R_FAIL) {
		nfail++;
	}
	printk("CHECK %s: %s\n", name, res_name[r]);
}

#define PROBE(key, fmt, ...) printk("PROBE " key "=" fmt "\n", ##__VA_ARGS__)

#define SECTION(n, title) printk("\n=== SECTION %d: %s ===\n", n, title)

/* ---- CSR / MMIO helpers ------------------------------------------------ */

#define rd_csr(csr)                                                          \
	({                                                                     \
		unsigned long __v;                                             \
		__asm__ volatile("csrr %0, " #csr : "=r"(__v));                \
		__v;                                                           \
	})

static inline uint32_t rd32(uintptr_t a)
{
	return *(volatile uint32_t *)a;
}
static inline void wr32(uintptr_t a, uint32_t v)
{
	*(volatile uint32_t *)a = v;
}
static inline uint64_t rd64(uintptr_t a)
{
	return *(volatile uint64_t *)a;
}
static inline void wr64(uintptr_t a, uint64_t v)
{
	*(volatile uint64_t *)a = v;
}

/* ---- 1. identity -------------------------------------------------------- */

static void probe_identity(void)
{
	SECTION(1, "identity");
	printk("about to read misa/mvendorid/marchid/mimpid/mhartid (M-mode CSRs)\n");

	unsigned long misa = rd_csr(misa);
	unsigned long vendor = rd_csr(mvendorid);
	unsigned long arch = rd_csr(marchid);
	unsigned long imp = rd_csr(mimpid);
	unsigned long hart = rd_csr(mhartid);

	char letters[27];
	int n = 0;

	for (int i = 0; i < 26; i++) {
		if (misa & (1UL << i)) {
			letters[n++] = 'A' + i;
		}
	}
	letters[n] = '\0';

	PROBE("misa", "0x%lx", misa);
	PROBE("misa.mxl", "%lu", misa >> (sizeof(long) * 8 - 2)); /* 1=32 2=64 */
	PROBE("misa.letters", "%s", letters);
	PROBE("mvendorid", "0x%lx", vendor);
	PROBE("marchid", "0x%lx", arch);
	PROBE("mimpid", "0x%lx", imp);
	PROBE("mhartid", "%lu", hart);
	PROBE("zephyr.version", "%s", KERNEL_VERSION_STRING);
	PROBE("config.vector_max_len", "%d", CONFIG_RISCV_VECTOR_MAX_LEN);
	PROBE("config.mtime_hz", "%d", CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC);
	PROBE("config.ticks_per_sec", "%d", CONFIG_SYS_CLOCK_TICKS_PER_SEC);
	record("identity.read", R_PASS);
	record("identity.has_V", strchr(letters, 'V') ? R_PASS : R_WARN);
	record("identity.hartid0", hart == 0 ? R_PASS : R_WARN);
}

/* ---- 2. vector ---------------------------------------------------------- */

#define VN 97
static int32_t va_[VN], vb_[VN], vc_[VN];

static void probe_vector(void)
{
	SECTION(2, "vector");
	printk("about to set mstatus.VS=dirty (csrs mstatus, 0x600)\n");
	__asm__ volatile("csrs mstatus, %0" ::"r"(0x600UL));

	printk("about to execute vsetvli/csrr vlenb (illegal instruction if V is absent)\n");
	unsigned long vlenb = __riscv_vlenb();
	size_t vmax8 = __riscv_vsetvlmax_e8m1();
	size_t vmax64 = __riscv_vsetvlmax_e64m8();

	PROBE("vlenb", "%lu", vlenb);
	PROBE("vlen_bits", "%lu", vlenb * 8);
	PROBE("vlmax.e8m1", "%zu", vmax8);
	PROBE("vlmax.e64m8", "%zu", vmax64);
	record("vector.vlen_matches_config",
	       (vlenb * 8 == CONFIG_RISCV_VECTOR_MAX_LEN) ? R_PASS : R_FAIL);
	record("vector.vlmax_e8m1", vmax8 == vlenb ? R_PASS : R_FAIL);
	record("vector.vlmax_e64m8", vmax64 == vlenb ? R_PASS : R_FAIL);

	printk("about to run a strip-mined vector add (%d elements)\n", VN);
	for (int i = 0; i < VN; i++) {
		va_[i] = i;
		vb_[i] = 1000 - 2 * i;
		vc_[i] = 0;
	}
	size_t vl;

	for (size_t i = 0; i < VN; i += vl) {
		vl = __riscv_vsetvl_e32m1(VN - i);
		vint32m1_t a = __riscv_vle32_v_i32m1(&va_[i], vl);
		vint32m1_t b = __riscv_vle32_v_i32m1(&vb_[i], vl);

		__riscv_vse32_v_i32m1(&vc_[i], __riscv_vadd_vv_i32m1(a, b, vl), vl);
	}
	int errs = 0;

	for (int i = 0; i < VN; i++) {
		errs += (vc_[i] != 1000 - i);
	}
	PROBE("vector.add_errors", "%d", errs);
	record("vector.add", errs ? R_FAIL : R_PASS);
}

/* ---- 3. clocks ----------------------------------------------------------
 *
 * mtime is read with k_cycle_get_64(), i.e. the machine timer driver reading the CLINT mtime
 * at the DT address, which also checks the driver's view of the CLINT. The core side uses
 * mcycle/minstret, which exist in M-mode, unlike rdcycle/rdtime (Zicntr, counter-enable bits).
 */
static void probe_clocks(void)
{
	SECTION(3, "clocks");
	printk("about to spin for %d mtime ticks (timeout %d mcycles) reading mcycle/minstret\n",
	       CONFIG_PROBE_MTIME_WINDOW_TICKS, CONFIG_PROBE_CLOCK_TIMEOUT_CYCLES);

	uint64_t t0 = k_cycle_get_64();
	unsigned long c0 = rd_csr(mcycle);
	unsigned long i0 = rd_csr(minstret);
	uint64_t t1;
	unsigned long c1;
	bool timeout = false;

	do {
		t1 = k_cycle_get_64();
		c1 = rd_csr(mcycle);
		if (c1 - c0 > (unsigned long)CONFIG_PROBE_CLOCK_TIMEOUT_CYCLES) {
			timeout = true;
			break;
		}
	} while (t1 - t0 < CONFIG_PROBE_MTIME_WINDOW_TICKS);
	unsigned long i1 = rd_csr(minstret);

	uint64_t dt = t1 - t0;
	unsigned long dc = c1 - c0;
	unsigned long di = i1 - i0;

	PROBE("clock.mtime_ticks", "%llu", (unsigned long long)dt);
	PROBE("clock.mcycle_delta", "%lu", dc);
	PROBE("clock.minstret_delta", "%lu", di);
	if (timeout || dt == 0) {
		printk("WARN: mtime did not advance (dt=%llu): is the CLINT mtime running?\n",
		       (unsigned long long)dt);
		record("clock.mtime_ticks", R_FAIL);
		return;
	}
	/* fixed point x1000, no float printf needed */
	unsigned long ratio_m = (unsigned long)(((uint64_t)dc * 1000) / dt);
	unsigned long mhz_k = (unsigned long)(((uint64_t)dc * CONFIG_PROBE_MTIME_HZ) / dt / 1000);

	PROBE("clock.core_cycles_per_mtime_tick", "%lu.%03lu", ratio_m / 1000, ratio_m % 1000);
	PROBE("clock.implied_core_khz", "%lu", mhz_k);
	PROBE("clock.implied_core_mhz", "%lu.%03lu", mhz_k / 1000, mhz_k % 1000);
	PROBE("clock.assumed_mtime_hz", "%d", CONFIG_PROBE_MTIME_HZ);
	PROBE("clock.ipc_x1000", "%lu", dc ? (unsigned long)(((uint64_t)di * 1000) / dc) : 0);

	unsigned long exp_ratio = (unsigned long)CONFIG_PROBE_EXPECTED_CORE_MHZ * 1000000UL /
				  CONFIG_PROBE_MTIME_HZ;
	unsigned long lo = exp_ratio * 8 / 10, hi = exp_ratio * 12 / 10;

	if (ratio_m / 1000 < lo || ratio_m / 1000 > hi) {
		printk("WARN: ratio %lu is outside +-20%% of expected %lu (%d MHz / %d Hz). "
		       "Either the core clock or the mtime rate differs from the assumption "
		       "(FPGA bitstream? Spike?). Tell us the PROBE lines above.\n",
		       ratio_m / 1000, exp_ratio, CONFIG_PROBE_EXPECTED_CORE_MHZ,
		       CONFIG_PROBE_MTIME_HZ);
		record("clock.ratio_as_expected", R_WARN);
	} else {
		record("clock.ratio_as_expected", R_PASS);
	}
}

/* ---- 4. scratchpad ------------------------------------------------------ */

static int spad_pattern(uintptr_t base, size_t bytes, const char *tag)
{
	static const uint32_t pats[] = { 0x00000000, 0xFFFFFFFF, 0xAAAAAAAA, 0x55555555 };
	size_t words = bytes / 4;
	int errs = 0;

	for (unsigned p = 0; p < ARRAY_SIZE(pats) + 2; p++) {
		for (size_t i = 0; i < words; i++) {
			uint32_t v = p < ARRAY_SIZE(pats) ? pats[p]
				     : p == ARRAY_SIZE(pats) ? (uint32_t)(base + i * 4)
							      : ~(uint32_t)(base + i * 4);
			wr32(base + i * 4, v);
		}
		for (size_t i = 0; i < words; i++) {
			uint32_t v = p < ARRAY_SIZE(pats) ? pats[p]
				     : p == ARRAY_SIZE(pats) ? (uint32_t)(base + i * 4)
							      : ~(uint32_t)(base + i * 4);
			uint32_t g = rd32(base + i * 4);

			if (g != v) {
				if (errs < 4) {
					printk("  MISMATCH %s @0x%lx: wrote 0x%x read 0x%x\n", tag,
					       (unsigned long)(base + i * 4), v, g);
				}
				errs++;
			}
		}
	}
	return errs;
}

static void __maybe_unused probe_scratchpad(void)
{
	const uintptr_t base = CONFIG_PROBE_SPAD_BASE;
	const size_t size = CONFIG_PROBE_SPAD_SIZE;
	int errs = 0;

	SECTION(4, "scratchpad");
	PROBE("spad.base", "0x%lx", (unsigned long)base);
	PROBE("spad.size", "0x%lx", (unsigned long)size);
	printk("about to write/read first 1 KiB of scratchpad at 0x%lx (traps if unmapped)\n",
	       (unsigned long)base);
	errs += spad_pattern(base, 1024, "first1K");
	printk("about to write/read last 1 KiB at 0x%lx\n", (unsigned long)(base + size - 1024));
	errs += spad_pattern(base + size - 1024, 1024, "last1K");
#if defined(CONFIG_PROBE_SPAD_FULL)
	printk("about to write/read the whole scratchpad (%lu bytes)\n", (unsigned long)size);
	errs += spad_pattern(base, size, "full");
#endif
	PROBE("spad.errors", "%d", errs);
	record("spad.pattern", errs ? R_FAIL : R_PASS);

	printk("about to time 64 read passes over 1 KiB\n");
	unsigned long c0 = rd_csr(mcycle);
	uint32_t sink = 0;

	for (int r = 0; r < 64; r++) {
		for (size_t i = 0; i < 256; i++) {
			sink += rd32(base + i * 4);
		}
	}
	unsigned long dc = rd_csr(mcycle) - c0;

	PROBE("spad.read_cycles_per_word_x100", "%lu", dc * 100 / (64 * 256));
	PROBE("spad.read_sink", "0x%x", sink);
	record("spad.timing", R_INFO);
}

/* ---- Atlas addresses: devicetree if the node exists, else Kconfig ------- */

#if DT_HAS_COMPAT_STATUS_OKAY(ucb_bar_atlas)
#define ATLAS_NODE DT_COMPAT_GET_ANY_STATUS_OKAY(ucb_bar_atlas)
#define ATLAS_IMEM_BASE DT_REG_ADDR_BY_NAME(ATLAS_NODE, imem)
#define ATLAS_IMEM_SIZE DT_REG_SIZE_BY_NAME(ATLAS_NODE, imem)
#define ATLAS_CSR_BASE  DT_REG_ADDR_BY_NAME(ATLAS_NODE, csr)
#define ATLAS_VMEM_BASE DT_REG_ADDR_BY_NAME(ATLAS_NODE, vmem)
#define ATLAS_VMEM_SIZE DT_REG_SIZE_BY_NAME(ATLAS_NODE, vmem)
#define ATLAS_VMEM_BANK_SIZE \
	(DT_REG_SIZE_BY_NAME(ATLAS_NODE, vmem) / DT_PROP_OR(ATLAS_NODE, vmem_banks, 1))
#define ATLAS_ADDR_SRC "devicetree (ucb-bar,atlas node)"
#else
#define ATLAS_IMEM_BASE CONFIG_PROBE_ATLAS_IMEM_BASE
#define ATLAS_IMEM_SIZE CONFIG_PROBE_ATLAS_IMEM_SIZE
#define ATLAS_CSR_BASE  CONFIG_PROBE_ATLAS_CSR_BASE
#define ATLAS_VMEM_BASE CONFIG_PROBE_ATLAS_VMEM_BASE
#define ATLAS_VMEM_SIZE CONFIG_PROBE_ATLAS_VMEM_SIZE
#define ATLAS_VMEM_BANK_SIZE CONFIG_PROBE_ATLAS_VMEM_BANK_SIZE
#define ATLAS_ADDR_SRC "Kconfig (no atlas node in devicetree)"
#endif

/* ---- 5. Atlas ----------------------------------------------------------- */

#define AT_CSR(off) ((uintptr_t)ATLAS_CSR_BASE + (off))
#define AT_CYCLE   0x00
#define AT_INSTCNT 0x04
#define AT_STATUS  0x08
#define AT_ILLPC   0x0C
#define AT_DBG0    0x10
#define AT_DBG1    0x14
#define AT_EXEC    0x18

/* write/readback a 32-bit word, restore the old value; returns 0 if ok */
static int rw32_check(uintptr_t a, uint32_t v)
{
	uint32_t old = rd32(a);

	wr32(a, v);
	uint32_t got = rd32(a);

	wr32(a, old);
	if (got != v) {
		printk("  MISMATCH @0x%lx: wrote 0x%x read 0x%x\n", (unsigned long)a, v, got);
		return 1;
	}
	return 0;
}

static int rw64_check(uintptr_t a, uint64_t v)
{
	uint64_t old = rd64(a);

	wr64(a, v);
	uint64_t got = rd64(a);

	wr64(a, old);
	if (got != v) {
		printk("  MISMATCH64 @0x%lx: wrote 0x%lx read 0x%lx\n", (unsigned long)a,
		       (unsigned long)v, (unsigned long)got);
		return 1;
	}
	return 0;
}

static void __maybe_unused probe_atlas(void)
{
	static const struct {
		const char *n;
		unsigned off;
	} regs[] = { { "cycle", AT_CYCLE },   { "instcnt", AT_INSTCNT }, { "status", AT_STATUS },
		     { "illegal_pc", AT_ILLPC }, { "dbg0", AT_DBG0 },      { "dbg1", AT_DBG1 },
		     { "execControl", AT_EXEC } };

	SECTION(5, "atlas");
	printk("(execControl is never written by this probe; the Atlas core stays halted)\n");
	PROBE("atlas.addr_source", "%s", ATLAS_ADDR_SRC);
	PROBE("atlas.csr_base", "0x%lx", (unsigned long)ATLAS_CSR_BASE);

	printk("about to read the 7 Atlas CSRs at 0x%lx (traps/hangs if Atlas is absent)\n",
	       (unsigned long)ATLAS_CSR_BASE);
	for (unsigned i = 0; i < ARRAY_SIZE(regs); i++) {
		printk("  reading %s @0x%lx\n", regs[i].n, (unsigned long)AT_CSR(regs[i].off));
		uint32_t v = rd32(AT_CSR(regs[i].off));

		PROBE("atlas.csr", "%s=0x%x", regs[i].n, v);
	}
	record("atlas.rd_csr", R_PASS);

	uint32_t st = rd32(AT_CSR(AT_STATUS));
	bool halted = st & 1;

	PROBE("atlas.status.halted", "%u", st & 1);
	PROBE("atlas.status.halt_reason", "%u", (st >> 1) & 3);
	record("atlas.halted_at_reset", halted ? R_PASS : R_FAIL);
	if (!halted) {
		printk("WARN: Atlas is not halted at reset: IMEM will NOT be touched "
		       "(host reads of IMEM while running can hang the bus).\n");
	}

	uint32_t cy0 = rd32(AT_CSR(AT_CYCLE));
	uint32_t cy1 = rd32(AT_CSR(AT_CYCLE));

	PROBE("atlas.cycle_delta_back_to_back", "%u", cy1 - cy0);
	record("atlas.cycle_counts", (cy1 != cy0) ? R_PASS : R_WARN);

	printk("about to write/readback dbg0 and dbg1 (restored afterwards)\n");
	int e = 0;

	e += rw32_check(AT_CSR(AT_DBG0), 0xA5A5A5A5);
	e += rw32_check(AT_CSR(AT_DBG0), 0x5A5A5A5A);
	e += rw32_check(AT_CSR(AT_DBG1), 0xDEADBEEF);
	e += rw32_check(AT_CSR(AT_DBG1), 0x12345678);
	PROBE("atlas.dbg_errors", "%d", e);
	record("atlas.dbg_rw", e ? R_FAIL : R_PASS);

	const uintptr_t vb = ATLAS_VMEM_BASE;
	const uintptr_t vbank = ATLAS_VMEM_BANK_SIZE;
	const uintptr_t vend = vb + ATLAS_VMEM_SIZE;
	const struct {
		const char *n;
		uintptr_t a;
	} vm[] = { { "bank0_start", vb },
		   { "bank0_end", vb + vbank - 4 },
		   { "bank1_start", vb + vbank },
		   { "last_word", vend - 4 } };

	e = 0;
	for (unsigned i = 0; i < ARRAY_SIZE(vm); i++) {
		printk("about to 32-bit write/read VMEM %s @0x%lx\n", vm[i].n,
		       (unsigned long)vm[i].a);
		e += rw32_check(vm[i].a, 0xC0FFEE00 + i);
		e += rw32_check(vm[i].a, 0x3C3C3C3C);
	}
	PROBE("atlas.vmem32_errors", "%d", e);
	record("atlas.vmem_32bit", e ? R_FAIL : R_PASS);

	e = 0;
	for (unsigned i = 0; i < ARRAY_SIZE(vm); i++) {
		uintptr_t a = vm[i].a & ~(uintptr_t)7;

		printk("about to 64-bit write/read VMEM %s @0x%lx\n", vm[i].n, (unsigned long)a);
		e += rw64_check(a, 0x0123456789ABCDEFULL + i);
	}
	/* endianness / halves: 64-bit write must appear as two 32-bit words */
	printk("about to check 64-bit store vs two 32-bit loads at VMEM 0x%lx\n",
	       (unsigned long)vb);
	{
		uint64_t old = rd64(vb);

		wr64(vb, 0x1111111122222222ULL);
		uint32_t lo = rd32(vb), hi = rd32(vb + 4);

		wr64(vb, old);
		PROBE("atlas.vmem64_split", "lo=0x%x hi=0x%x", lo, hi);
		e += !(lo == 0x22222222 && hi == 0x11111111);
	}
	PROBE("atlas.vmem64_errors", "%d", e);
	record("atlas.vmem_64bit", e ? R_FAIL : R_PASS);

	if (!halted) {
		record("atlas.imem_rw", R_SKIP);
		return;
	}
	const uintptr_t ib = ATLAS_IMEM_BASE;
	const uintptr_t iend = ib + ATLAS_IMEM_SIZE;

	e = 0;
	printk("about to write/read IMEM words while halted (first, second, last)\n");
	printk("  IMEM first @0x%lx\n", (unsigned long)ib);
	e += rw32_check(ib, 0x00000013);
	e += rw32_check(ib, 0xFEEDF00D);
	printk("  IMEM second @0x%lx\n", (unsigned long)(ib + 4));
	e += rw32_check(ib + 4, 0x0BADCAFE);
	printk("  IMEM last @0x%lx\n", (unsigned long)(iend - 4));
	e += rw32_check(iend - 4, 0x13579BDF);
	PROBE("atlas.imem_errors", "%d", e);
	record("atlas.imem_rw", e ? R_FAIL : R_PASS);

	st = rd32(AT_CSR(AT_STATUS));
	PROBE("atlas.status_after", "0x%x", st);
	record("atlas.still_halted", (st & 1) ? R_PASS : R_FAIL);
}

/* ---- 6. DRAM size (optional, dangerous) ---------------------------------- */

static void __maybe_unused probe_dram(void)
{
	SECTION(6, "dram size");
	printk("WARNING: this section may HANG on an address nobody answers. "
	       "The last 'about to' line names it.\n");
	const uintptr_t base = CONFIG_PROBE_DRAM_BASE;
	uintptr_t highest = 0;

	for (uintptr_t off = 256UL << 20; off && off <= (4UL << 30); off <<= 1) {
		uintptr_t a = base + off;

		printk("about to touch DRAM base+0x%lx (@0x%lx)\n", (unsigned long)off,
		       (unsigned long)a);
		uint32_t old = rd32(a);
		uint32_t pat = 0xD0A00000 | (uint32_t)(off >> 20);

		wr32(a, pat);
		uint32_t got = rd32(a);

		wr32(a, old);
		PROBE("dram.touch", "off=0x%lx wrote=0x%x read=0x%x", (unsigned long)off, pat, got);
		if (got == pat) {
			highest = off;
		} else {
			printk("  no readback: stopping\n");
			break;
		}
	}
	PROBE("dram.highest_ok_offset", "0x%lx", (unsigned long)highest);
	record("dram.probe", R_INFO);
}

/* ---- main --------------------------------------------------------------- */

int main(void)
{
	printk("hw_probe: start (each risky step is announced before it runs)\n");

#if defined(CONFIG_PROBE_IDENTITY)
	probe_identity();
#endif
#if defined(CONFIG_PROBE_VECTOR)
	probe_vector();
#endif
#if defined(CONFIG_PROBE_CLOCKS)
	probe_clocks();
#endif
#if defined(CONFIG_PROBE_SCRATCHPAD)
	probe_scratchpad();
#endif
#if defined(CONFIG_PROBE_ATLAS)
	probe_atlas();
#endif
#if defined(CONFIG_PROBE_DRAM_SIZE)
	probe_dram();
#endif

	printk("\n=== SUMMARY ===\n");
	for (int i = 0; i < nchecks; i++) {
		printk("  %-32s %s\n", checks[i].name, res_name[checks[i].r]);
	}
	printk("hw_probe: %s (%d failed of %d checks)\n", nfail ? "FAIL" : "PASS", nfail, nchecks);
	chipyard_sim_exit(nfail ? 1 : 0);
}
