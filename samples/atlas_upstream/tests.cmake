# SPDX-License-Identifier: Apache-2.0
#
# CREDIT: the tests this sample builds, and the generators/assembler it calls, are
# the Atlas/Saturn team's work, used unmodified from the course tapeout repo (tapeout-chipyard)
# (tests/, generators/sp26-atlas-acc/baremetal/), commit
# 48c3a7d11f6de3f0cecb33ae6a31c24ec26ff9d8, submodule sp26-atlas-acc 2ae0bef209df. git authors of tests/: kellytou
# ("T.K."), Eric Wen, Nicolas Rakela (Herrera), Nicolas Reed; sp26-atlas-acc
# baremetal: kellytou, Nicolas Reed, jason.tang, Eric Wen, nicorakela. The build
# logic mirrors tests/CMakeLists.txt there. We own only the files in this directory.
#
# Inventory of the upstream host tests (tapeout-chipyard/tests/), one entry per test name.
# Included by CMakeLists.txt.
#
#   ATLAS_KIND_<t>     asis | kernel | torch   (see CMakeLists.txt)
#   ATLAS_SRC_<t>      upstream .c to compile
#   ATLAS_GEN_<t>      (torch, optional) generator script stem in baremetal/generators/;
#                      default gen_<upstream .c stem>
#   ATLAS_GENARGS_<t>  (torch) extra generator arguments
#   ATLAS_DEFS_<t>     extra -D for the upstream .c (upstream's CMake does the same for its
#                      "_nosaturn" variant)

set(ATLAS_ALL_TESTS)
macro(atlas_test name kind)
  list(APPEND ATLAS_ALL_TESTS ${name})
  set(ATLAS_KIND_${name} ${kind})
  set(ATLAS_SRC_${name} ${name}.c)
endmacro()

# --- builds as-is: the Atlas program is an array inside the .c ----------------
atlas_test(atlas_alu_basic                    asis)
atlas_test(saturn_atlas_vmem_smoke            asis)
atlas_test(saturn_atlas_pause_resume          asis)
atlas_test(saturn_atlas_pi0_slice             asis)
atlas_test(saturn_atlas_buffered_optA_end_jal asis)
atlas_test(saturn_atlas_buffered_lower_first  asis)
atlas_test(saturn_atlas_buffered_optB_restart asis)

# --- assembled Atlas kernel + random golden (python only) ---------------------
# These also use DRAM at ATLAS_DRAM_BASE 0x9000_0000.
atlas_test(saturn_atlas_vmem_3way_arb         kernel)
atlas_test(saturn_atlas_4rung_2bank_arb       kernel)
atlas_test(saturn_atlas_vmem_dram_dual        kernel)
atlas_test(saturn_atlas_dmem_sbus_dma         kernel)
atlas_test(saturn_atlas_8dma_rvv_vmem         kernel)
atlas_test(saturn_atlas_8dma_rvv_vmem_nosaturn kernel)
set(ATLAS_SRC_saturn_atlas_8dma_rvv_vmem_nosaturn saturn_atlas_8dma_rvv_vmem.c)
set(ATLAS_DEFS_saturn_atlas_8dma_rvv_vmem_nosaturn SAS_T2_SKIP_SATURN=1)

# --- golden headers from torch-based bit-exact models -------------------------
atlas_test(saturn_atlas_smolvla_compose              torch)
atlas_test(saturn_atlas_smolvla_compose_large        torch)
atlas_test(saturn_atlas_tri_phase                    torch)
atlas_test(saturn_atlas_tri_phase_large              torch)
atlas_test(saturn_atlas_fp8_quantize_bridge          torch)
atlas_test(saturn_atlas_fp8_dequant_bridge           torch)
atlas_test(saturn_atlas_quad_phase_large             torch)
# The "native bf16" twins use the base generator with a different interlude mode
atlas_test(saturn_atlas_smolvla_compose_native_bf16  torch)
set(ATLAS_GEN_saturn_atlas_smolvla_compose_native_bf16 gen_saturn_atlas_smolvla_compose)
set(ATLAS_GENARGS_saturn_atlas_smolvla_compose_native_bf16 --interlude-mode native_bf16_rne)
atlas_test(saturn_atlas_tri_phase_native_bf16        torch)
set(ATLAS_GEN_saturn_atlas_tri_phase_native_bf16 gen_saturn_atlas_tri_phase)
set(ATLAS_GENARGS_saturn_atlas_tri_phase_native_bf16 --interlude-mode native_bf16_rne)
