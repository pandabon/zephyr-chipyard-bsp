/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Proves that a DT zephyr,memory-region node becomes a linker region + output
 * section, and that Z_GENERIC_SECTION(<region name>) places data in it.
 */
#include <zephyr/ztest.h>
#include <zephyr/devicetree.h>
#include <zephyr/linker/devicetree_regions.h>
#include <zephyr/toolchain.h>

#define SCRATCH DT_NODELABEL(fake_scratch)
#define SCRATCH_BASE ((uintptr_t)DT_REG_ADDR(SCRATCH))
#define SCRATCH_END  (SCRATCH_BASE + DT_REG_SIZE(SCRATCH))

/* No initializer: the section is NOLOAD, nothing zeroes or copies it. */
static uint8_t buf[256] Z_GENERIC_SECTION(LINKER_DT_NODE_REGION_NAME(SCRATCH));
static uint32_t word Z_GENERIC_SECTION(LINKER_DT_NODE_REGION_NAME(SCRATCH));
static uint8_t in_dram[16];

ZTEST(memregion, test_placement)
{
	zassert_true((uintptr_t)buf >= SCRATCH_BASE && (uintptr_t)&buf[sizeof(buf)] <= SCRATCH_END,
		     "buf %p outside region", buf);
	zassert_true((uintptr_t)&word >= SCRATCH_BASE && (uintptr_t)&word < SCRATCH_END,
		     "word %p outside region", &word);
	zassert_true((uintptr_t)in_dram < SCRATCH_BASE, "ordinary data must stay in DRAM");
}

ZTEST(memregion, test_rw)
{
	for (size_t i = 0; i < sizeof(buf); i++) {
		buf[i] = (uint8_t)(i ^ 0xa5);
	}
	for (size_t i = 0; i < sizeof(buf); i++) {
		zassert_equal(buf[i], (uint8_t)(i ^ 0xa5), "mismatch at %zu", i);
	}
	word = 0xdeadbeef;
	zassert_equal(word, 0xdeadbeef);
}

ZTEST_SUITE(memregion, NULL, NULL, NULL, NULL, NULL);
