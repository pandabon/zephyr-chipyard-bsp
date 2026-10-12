# SPDX-License-Identifier: Apache-2.0
# k_vmem.S - read VMEM, combine with a host-supplied value, write VMEM and dbg0.
#
# Exercises the host<->kernel channels:
#   * dbg1 (kernel CSR 0xC11): input argument written by the host
#   * VMEM word 0 (byte offset 0): second input, seeded by the host
#   * VMEM word 1 (byte offset 4) and dbg0: outputs
#
#   result    = VMEM[0] XOR dbg1
#   VMEM[4]   = result
#   dbg0      = result
#
# The host sets VMEM[0]=0x12345678, VMEM[4]=0xDEADBEEF (a sentinel that shows a store that
# never lands) and dbg1=0x0F0F0F0F, giving result = 0x1D3B5977.
#
# Encoding and timing follow mem_scalar.S, which passes in RTL:
#   * Scalar VMEM addresses are zero-based offsets, not 0x2000_0000+offset (the Atlas
#     architecture notes say not to use 0x2000_0000), so the base register is x0.
#   * LW has a 3-cycle software-visible latency; "LW x9, x8, 0 ; DELAY 2" is the idiom before
#     the first use of the loaded value.
#   * CSRR x, 0xC11 is CSRRS x, 0xC11, x0 (read, no set), as in two_phase.S.
#   * Stores are pipelined masked writes; DELAY 8 before ECALL lets them reach VMEM before
#     the core halts (conservative; costs 8 cycles).
#   * Operand order: LW rd, rs1, imm ; SW rs2(data), rs1(base), imm.
#   * No branches, so no delay slots.

    CSRR  x6, 0xC11          # x6 = dbg1 (host argument)
    LW    x3, x0, 0          # x3 = VMEM[0]
    DELAY 2                  # load-to-use latency
    XOR   x4, x3, x6         # x4 = VMEM[0] ^ dbg1
    SW    x4, x0, 4          # VMEM[4] = x4
    CSRW  x4, 0xC10          # dbg0 = x4
    DELAY 8                  # let the pipelined store drain
    ECALL
