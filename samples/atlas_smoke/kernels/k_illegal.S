# SPDX-License-Identifier: Apache-2.0
# k_illegal.S - execute an illegal instruction to check the error path:
# status.halt_reason == 1 and illegal_pc.
#
#   word 0,1  LI x1, 0xBAD00001   (LUI + ADDI)
#   word 2    CSRW x1, 0xC10      dbg0 = 0xBAD00001 (the code before it ran)
#   word 3    NOP                 (lets the CSR write retire)
#   word 4    0x00000000          illegal: opcode bits [1:0] are 00, unused by Atlas/RV32.
#                                 assembler.py cannot emit a raw word, so regen_kernels.py
#                                 patches word 4 after assembly (@RAWWORD below).
#   word 5    ECALL               must not be reached (it would give reason 2)
#
# Expected: halt_reason = 1, illegal_pc = 4 (PC as a word index, per the Atlas docs) or 0x10
# (byte address), dbg0 = 0xBAD00001. The smoke app accepts either and prints which it saw.
#
# @RAWWORD 4 0x00000000

    LI    x1, 0xBAD00001
    CSRW  x1, 0xC10
    NOP
    NOP                      # placeholder, replaced by the raw illegal word
    ECALL
