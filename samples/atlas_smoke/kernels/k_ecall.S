# SPDX-License-Identifier: Apache-2.0
# k_ecall.S - minimal Atlas kernel: write a signature to dbg0, then halt.
#
# Checks that IMEM was written correctly, the core fetched word 0 after execControl=1, a
# scalar ALU op and a CSR write work, and ECALL halts with status.halt_reason == 2.
# Expected: dbg0 = 0xA71A5001, status.halted = 1, status.halt_reason = 2 (ecall).
#
# Encoding (assembler.py):
#   LI x1, imm32   expands to LUI + ADDI (2 words) since the value exceeds 12 bits.
#   CSRW x1, 0xC10 is CSRRW x0, 0xC10, x1. 0xC10 is dbg0, visible to the host at CSR offset
#                  0x10 (CSRFile.scala, ScalarISA.scala:151).
#   ECALL          halts the core; PC is not advanced and there is no resume.
# No branches (no delay slots) and no loads (no load-use delay). The pipeline is in order, so
# the CSR write retires before ECALL.

    LI    x1, 0xA71A5001
    CSRW  x1, 0xC10
    ECALL
