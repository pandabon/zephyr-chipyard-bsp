/* SPDX-License-Identifier: Apache-2.0 */
/* TSI link probe payload: a few data words, no code.
 *
 * uart_tsi writes the words over TSI and `+selfcheck` reads them back and compares. With
 * +no_hart0_msip the hart never starts, so only the bus path to that address is tested.
 * (Baremetal-IDE's `make checktsi` uses `+init_write/+init_read ... none` instead, which
 * does nothing here: fesvr skips reset() for "none", htif.cc:85-99, and reset() runs the init
 * accesses, testchip_tsi.cc:53-57.) The idea of write-and-read-back is from that target.
 *
 * Built by build_probes.sh:
 *   riscv64-zephyr-elf-as --defsym WORDS=<n> probe.S
 *   riscv64-zephyr-elf-ld -N -nostdlib -e 0 --section-start=.data=<addr>
 * WORDS is the number of 32-bit words; CLINT gets 2 (hart 0's mtimecmp only, so no write
 * hits a nonexistent hart).
 */
	.section .data
	.word 0xb0bacafe, 0x12345678
	.if WORDS > 2
	.word 0xa5a5a5a5, 0x0badf00d
	.endif
