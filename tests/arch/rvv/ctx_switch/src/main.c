/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * RVV context-switch torture test (single CPU).
 *
 * Several threads each load a thread- and iteration-unique pattern into all
 * 32 vector registers, pick a thread-specific vtype/vl/vcsr, then force a
 * context switch in one of several ways while the other threads do the same
 * with *different* patterns.  After being switched back in, the thread
 * re-reads vl/vtype/vcsr and dumps v0..v31; any difference from what it
 * loaded means the kernel leaked or lost vector state.
 *
 * Between "load" and "check" a thread runs only kernel calls (no libc, no
 * printk) and the file is built with -fno-tree-vectorize, so nothing but the
 * kernel's own switch code can legitimately touch the vector unit.
 */
#include <zephyr/kernel.h>
#include <zephyr/ztest.h>
#include <zephyr/sys/atomic.h>
#include <stdint.h>
#include <string.h>

#define VLENB_MAX (CONFIG_RISCV_VECTOR_MAX_LEN / 8)
#define VBYTES    (32 * VLENB_MAX)
#define NTHREADS  4
#define STACKSZ   4096

enum mode { M_YIELD, M_SPIN, M_SLEEP, M_BLOCK, M_ROTATE };

struct tctx {
	int id;
	enum mode mode;
	bool use_fp;
	int iters;
	/* results */
	volatile int progress; /* iteration in flight, for hang diagnosis */
	int errors;
	int nvl, nvtype, nvcsr, nvreg, nfreg; /* per-kind error counts */
	int preempted;     /* times a SPIN iteration was really preempted */
	int first_iter;
	char first_what[24];
	int first_reg, first_byte;
	unsigned long first_exp, first_got;
	/* buffers */
	uint8_t vexp[VBYTES] __aligned(16);
	uint8_t vgot[VBYTES] __aligned(16);
	uint64_t fexp[32] __aligned(8);
	uint64_t fgot[32] __aligned(8);
};

static struct tctx ctx[NTHREADS];
static struct k_thread threads[NTHREADS];
static K_THREAD_STACK_ARRAY_DEFINE(stacks, NTHREADS, STACKSZ);
static struct k_sem ring[NTHREADS];
static volatile int last_runner;

#define VON  ".option push\n .option arch, +v\n "
#define VOFF " .option pop\n"

static inline unsigned long read_vlenb(void)
{
	unsigned long v;

	__asm__ volatile(VON "csrr %0, vlenb\n" VOFF : "=r"(v));
	return v;
}

#define VALL_CLOBBERS "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", \
	"v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18", "v19", "v20", "v21", "v22", \
	"v23", "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31"

/* Load v0..v31 from buf: four LMUL=8 loads cover the whole file. */
static void __noinline vload(const uint8_t *buf)
{
	__asm__ volatile(VON
		"csrw vstart, x0\n"
		"vsetvli t0, x0, e8, m8, ta, ma\n"
		"vle8.v v0, (%0)\n add %0, %0, t0\n"
		"vle8.v v8, (%0)\n add %0, %0, t0\n"
		"vle8.v v16, (%0)\n add %0, %0, t0\n"
		"vle8.v v24, (%0)\n" VOFF
		: "+r"(buf) :: "t0", "memory", VALL_CLOBBERS);
}

static void __noinline vstore(uint8_t *buf)
{
	__asm__ volatile(VON
		"csrw vstart, x0\n"
		"vsetvli t0, x0, e8, m8, ta, ma\n"
		"vse8.v v0, (%0)\n add %0, %0, t0\n"
		"vse8.v v8, (%0)\n add %0, %0, t0\n"
		"vse8.v v16, (%0)\n add %0, %0, t0\n"
		"vse8.v v24, (%0)\n" VOFF
		: "+r"(buf) :: "t0", "memory");
}

/*
 * Choose a per-thread vtype (SEW/LMUL/tail/mask policy), a partial vl and a
 * vcsr value, and return what the hardware reports.  vsetvli must come
 * after the register load because it changes how v-instructions behave.
 */
static void __noinline vset_cfg(int id, int iter, unsigned long *vl,
				unsigned long *vtype, unsigned long *vcsr)
{
	unsigned long avl = 3 + id * 5 + (iter & 7);
	unsigned long l;

	switch (id & 3) {
	case 0:
		__asm__ volatile(VON "vsetvli %0, %1, e8, m1, tu, mu\n" VOFF : "=r"(l) : "r"(avl));
		break;
	case 1:
		__asm__ volatile(VON "vsetvli %0, %1, e16, m2, ta, mu\n" VOFF : "=r"(l) : "r"(avl));
		break;
	case 2:
		__asm__ volatile(VON "vsetvli %0, %1, e32, m4, tu, ma\n" VOFF : "=r"(l) : "r"(avl));
		break;
	default:
		__asm__ volatile(VON "vsetvli %0, %1, e64, m1, ta, ma\n" VOFF : "=r"(l) : "r"(avl));
		break;
	}
	/* vcsr = vxrm[2:1] | vxsat[0] */
	unsigned long want = (unsigned long)((id + iter) & 7);

	__asm__ volatile(VON "csrw vcsr, %0\n" VOFF :: "r"(want));
	__asm__ volatile(VON "csrr %0, vl\n csrr %1, vtype\n csrr %2, vcsr\n" VOFF
			 : "=r"(*vl), "=r"(*vtype), "=r"(*vcsr));
	(void)l;
}

static void __noinline vread_cfg(unsigned long *vl, unsigned long *vtype, unsigned long *vcsr)
{
	__asm__ volatile(VON "csrr %0, vl\n csrr %1, vtype\n csrr %2, vcsr\n" VOFF
			 : "=r"(*vl), "=r"(*vtype), "=r"(*vcsr));
}

#define FREGS(X) X(0) X(1) X(2) X(3) X(4) X(5) X(6) X(7) X(8) X(9) X(10) X(11) X(12) \
	X(13) X(14) X(15) X(16) X(17) X(18) X(19) X(20) X(21) X(22) X(23) X(24) X(25) \
	X(26) X(27) X(28) X(29) X(30) X(31)
#define FLD(n) "fld f" #n ", " #n "*8(%0)\n"
#define FSD(n) "fsd f" #n ", " #n "*8(%0)\n"
#define FCL(n) "f" #n,

/*
 * Must be inlined: fs0-fs11 are callee-saved, so a non-inlined function that
 * clobbers them would restore the caller's values on return and silently undo
 * the load.
 */
static inline __always_inline void fload(const uint64_t *p)
{
	__asm__ volatile(FREGS(FLD) :: "r"(p) : FREGS(FCL) "memory");
}

static inline __always_inline void fstore(uint64_t *p)
{
	__asm__ volatile(FREGS(FSD) :: "r"(p) : "memory");
}

static void note_fail(struct tctx *c, int iter, const char *what, int reg, int byte,
		      unsigned long e, unsigned long g)
{
	if (!strcmp(what, "vl")) {
		c->nvl++;
	} else if (!strcmp(what, "vtype")) {
		c->nvtype++;
	} else if (!strcmp(what, "vcsr")) {
		c->nvcsr++;
	} else if (!strcmp(what, "vreg")) {
		c->nvreg++;
	} else {
		c->nfreg++;
	}
	if (c->errors++ == 0) {
		c->first_iter = iter;
		strncpy(c->first_what, what, sizeof(c->first_what) - 1);
		c->first_reg = reg;
		c->first_byte = byte;
		c->first_exp = e;
		c->first_got = g;
	}
}

static inline uint8_t pat(int id, int iter, int reg, int j)
{
	return (uint8_t)(id * 0x35 + reg * 0x11 + j * 7 + iter * 0x13 + 1);
}

/* The context switch under test. Returns after this thread was switched out. */
static void do_switch(struct tctx *c, enum mode m)
{
	switch (m) {
	case M_YIELD:
		k_yield();
		k_yield();
		break;
	case M_SPIN: {
		/* Busy-wait until the time slicer preempts us (someone else
		 * overwrites last_runner) or a generous timeout expires.
		 */
		int64_t end = k_uptime_ticks() + k_ms_to_ticks_ceil32(10);

		last_runner = c->id;
		while (k_uptime_ticks() < end) {
			if (last_runner != c->id) {
				c->preempted++;
				break;
			}
		}
		break;
	}
	case M_SLEEP:
		k_msleep(1);
		break;
	case M_BLOCK:
		k_sem_give(&ring[(c->id + 1) % NTHREADS]);
		k_sem_take(&ring[c->id], K_FOREVER);
		break;
	default:
		break;
	}
}

static void worker(void *p1, void *p2, void *p3)
{
	struct tctx *c = p1;
	unsigned long vlenb = read_vlenb();
	size_t nbytes = 32 * vlenb;

	for (int it = 0; it < c->iters; it++) {
		enum mode m = c->mode;

		c->progress = it;

		if (m == M_ROTATE) {
			m = (enum mode)(it % 3); /* YIELD, SPIN, SLEEP */
		}

		for (int r = 0; r < 32; r++) {
			for (unsigned long j = 0; j < vlenb; j++) {
				c->vexp[r * vlenb + j] = pat(c->id, it, r, j);
			}
		}
		if (c->use_fp) {
			for (int r = 0; r < 32; r++) {
				c->fexp[r] = 0x4000000000000000ULL ^ ((uint64_t)c->id << 40) ^
					     ((uint64_t)it << 8) ^ (uint64_t)r;
			}
			fload(c->fexp);
		}

		unsigned long evl, evtype, evcsr;

		vload(c->vexp);
		vset_cfg(c->id, it, &evl, &evtype, &evcsr);

		do_switch(c, m);

		/* --- check: nothing below may run before we have captured state --- */
		unsigned long gvl, gvtype, gvcsr;

		vread_cfg(&gvl, &gvtype, &gvcsr);
		vstore(c->vgot);
		if (c->use_fp) {
			fstore(c->fgot);
		}

		if (gvl != evl) {
			note_fail(c, it, "vl", -1, 0, evl, gvl);
		}
		if (gvtype != evtype) {
			note_fail(c, it, "vtype", -1, 0, evtype, gvtype);
		}
		if (gvcsr != evcsr) {
			note_fail(c, it, "vcsr", -1, 0, evcsr, gvcsr);
		}
		for (size_t i = 0; i < nbytes; i++) {
			if (c->vgot[i] != c->vexp[i]) {
				note_fail(c, it, "vreg", i / vlenb, i % vlenb, c->vexp[i],
					  c->vgot[i]);
				break;
			}
		}
		if (c->use_fp) {
			for (int r = 0; r < 32; r++) {
				if (c->fgot[r] != c->fexp[r]) {
					note_fail(c, it, "freg", r, 0, (unsigned long)c->fexp[r],
						  (unsigned long)c->fgot[r]);
					break;
				}
			}
		}
	}
}

static void run(const enum mode *modes, const bool *fp, int iters)
{
	memset(ctx, 0, sizeof(ctx));
	for (int i = 0; i < NTHREADS; i++) {
		k_sem_init(&ring[i], 0, K_SEM_MAX_LIMIT);
		ctx[i].id = i;
		ctx[i].mode = modes[i];
		ctx[i].use_fp = fp[i];
		ctx[i].iters = iters;
	}
	for (int i = 0; i < NTHREADS; i++) {
		k_thread_create(&threads[i], stacks[i], STACKSZ, worker, &ctx[i], NULL, NULL,
				K_PRIO_PREEMPT(1), K_FP_REGS, K_NO_WAIT);
	}
	for (int i = 0; i < NTHREADS; i++) {
		int rc = k_thread_join(&threads[i], K_SECONDS(120));

		if (rc != 0) {
			char st[48];

			TC_PRINT("thread %d stuck at iter %d, state: %s\n", i, ctx[i].progress,
				 k_thread_state_str(&threads[i], st, sizeof(st)));
		}
		zassert_ok(rc, "thread %d hung", i);
	}
	for (int i = 0; i < NTHREADS; i++) {
		struct tctx *c = &ctx[i];

		if (c->errors) {
			TC_PRINT("thread %d: %d errors; first at iter %d: %s reg=%d byte=%d "
				 "expected=0x%lx got=0x%lx\n", i, c->errors, c->first_iter,
				 c->first_what, c->first_reg, c->first_byte, c->first_exp,
				 c->first_got);
			TC_PRINT("  by kind: vl=%d vtype=%d vcsr=%d vreg=%d freg=%d\n", c->nvl,
				 c->nvtype, c->nvcsr, c->nvreg, c->nfreg);
		}
		zassert_equal(c->errors, 0, "thread %d: vector/FP state corrupted", i);
	}
}

#ifdef RVV_ONLY
#define ONLY(n) do { if (strcmp(n, RVV_ONLY)) { ztest_test_skip(); } } while (0)
#else
#define ONLY(n)
#endif

static const bool nofp[NTHREADS];
static const bool allfp[NTHREADS] = {true, true, true, true};

ZTEST(rvv_ctx_switch, test_cooperative_yield)
{
	ONLY("cooperative_yield");
	const enum mode m[NTHREADS] = {M_YIELD, M_YIELD, M_YIELD, M_YIELD};

	run(m, nofp, 3000);
}

ZTEST(rvv_ctx_switch, test_timeslice_preemption)
{
	ONLY("timeslice_preemption");
	const enum mode m[NTHREADS] = {M_SPIN, M_SPIN, M_SPIN, M_SPIN};
	int pre = 0;

	run(m, nofp, 200);
	for (int i = 0; i < NTHREADS; i++) {
		pre += ctx[i].preempted;
	}
	TC_PRINT("observed preemptions: %d\n", pre);
	/* If the slicer never fired this test proved nothing. */
	zassert_true(pre > 150, "time slicing did not preempt (%d)", pre);
}

ZTEST(rvv_ctx_switch, test_sleep)
{
	ONLY("sleep");
	const enum mode m[NTHREADS] = {M_SLEEP, M_SLEEP, M_SLEEP, M_SLEEP};

	run(m, nofp, 300);
}

ZTEST(rvv_ctx_switch, test_block_on_semaphore)
{
	ONLY("block_on_semaphore");
	const enum mode m[NTHREADS] = {M_BLOCK, M_BLOCK, M_BLOCK, M_BLOCK};

	run(m, nofp, 300);
}

ZTEST(rvv_ctx_switch, test_fp_and_v)
{
	ONLY("fp_and_v");
	const enum mode m[NTHREADS] = {M_ROTATE, M_ROTATE, M_ROTATE, M_ROTATE};

	run(m, allfp, 300);
}

ZTEST(rvv_ctx_switch, test_mixed_modes)
{
	ONLY("mixed_modes");
	const enum mode m[NTHREADS] = {M_YIELD, M_SPIN, M_SLEEP, M_ROTATE};
	const bool fp[NTHREADS] = {false, false, true, true};

	run(m, fp, 300);
}

ZTEST_SUITE(rvv_ctx_switch, NULL, NULL, NULL, NULL, NULL);
