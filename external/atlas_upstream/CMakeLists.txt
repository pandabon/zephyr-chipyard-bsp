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
# Build ONE of the Atlas team's host tests straight from their source tree
# (tapeout-chipyard/tests/*.c), nothing copied:
#
#   west build -b chipyard_penguin/penguin external/atlas_upstream -- \
#       -DATLAS_TEST=saturn_atlas_pause_resume
#
# Why not the plain_app core (cmake/plain_app/)? That core compiles every .c in
# a directory it is pointed at; the upstream tests/ directory holds ~45 files
# with their own main() each, so we need to pick exactly one file. We do reuse
# its idea (link with --wrap=main so that a returning main() ends the run with
# its value as exit code) in shim/atlas_upstream_shim.c.
#
# Variables (all optional except that ATLAS_TEST defaults to the smallest test):
#   ATLAS_TEST        test name from tests.cmake (the upstream file stem)
#   TAPEOUT_CHIPYARD  tapeout-chipyard checkout; -D or the env var of the same name.
#                     No default location: it must be given.
# The checkout is only READ. Everything generated (assembled Atlas kernels,
# golden-data headers) goes into the build directory.

cmake_minimum_required(VERSION 3.20.0)

# ---- locate upstream, pick the test (before find_package: fail early) --------------
if(NOT TAPEOUT_CHIPYARD)
  set(TAPEOUT_CHIPYARD "$ENV{TAPEOUT_CHIPYARD}")
endif()
if(TAPEOUT_CHIPYARD)
  get_filename_component(TAPEOUT_CHIPYARD "${TAPEOUT_CHIPYARD}" ABSOLUTE)
endif()
set(UP_TESTS "${TAPEOUT_CHIPYARD}/tests")
set(UP_ATLAS "${TAPEOUT_CHIPYARD}/generators/sp26-atlas-acc")
if(NOT EXISTS "${UP_TESTS}/atlas_mmio.h")
  message(FATAL_ERROR
    "TAPEOUT_CHIPYARD='${TAPEOUT_CHIPYARD}' has no tests/atlas_mmio.h. "
    "Pass -DTAPEOUT_CHIPYARD=<checkout> or export TAPEOUT_CHIPYARD. "
    "(scripts/run_tests.py skips these scenarios when the checkout is absent.)")
endif()

include(${CMAKE_CURRENT_LIST_DIR}/tests.cmake)   # defines ATLAS_ALL_TESTS + per-test facts
if(NOT ATLAS_TEST)
  set(ATLAS_TEST saturn_atlas_vmem_smoke)
endif()
if(NOT ATLAS_TEST IN_LIST ATLAS_ALL_TESTS)
  string(REPLACE ";" "\n  " _l "${ATLAS_ALL_TESTS}")
  message(FATAL_ERROR "ATLAS_TEST='${ATLAS_TEST}' is not a known test. Choose one of:\n  ${_l}")
endif()
set(_kind "${ATLAS_KIND_${ATLAS_TEST}}")
# Upstream file stem: differs from the test name only for variants that reuse a .c
get_filename_component(_stem "${ATLAS_SRC_${ATLAS_TEST}}" NAME_WE)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(atlas_upstream)

message(STATUS "atlas_upstream: test ${ATLAS_TEST} (${_kind}) from ${UP_TESTS}")

# ---- generated inputs --------------------------------------------------------------
# Kinds (inventory: tests.cmake):
#   asis    the .c only needs atlas_mmio.h (the IMEM program is an array inside the .c)
#   kernel  + kernel_<k>.h (Atlas .S assembled by the team's assembler.py) and a
#             random-data golden header; pure python (no numpy/torch)
#   torch   + golden header computed with the team's bit-exact numpy/torch models.
#             Needs `import torch`.
set(GEN_ROOT "${CMAKE_BINARY_DIR}/atlas_upstream_gen")
set(GEN_KERNELS "${GEN_ROOT}/kernels")
set(GEN_GOLDEN "${GEN_ROOT}/golden")
file(MAKE_DIRECTORY "${GEN_KERNELS}" "${GEN_GOLDEN}")
set(GEN_DIR "${UP_ATLAS}/baremetal/generators")
set(ASM_DIR "${UP_ATLAS}/baremetal/assembly/saturn_atlas_cooperative")

if(NOT PYTHON_EXECUTABLE AND Python3_EXECUTABLE)
  set(PYTHON_EXECUTABLE "${Python3_EXECUTABLE}")
endif()
# PYTHONDONTWRITEBYTECODE: do not drop __pycache__ into the READ-ONLY upstream tree.
set(PYRUN ${CMAKE_COMMAND} -E env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=${GEN_DIR}
          ${PYTHON_EXECUTABLE})
set(_gen_outputs)

if(_kind STREQUAL "kernel")
  string(REGEX REPLACE "^saturn_atlas_" "" _short "${_stem}")
  set(_kname "sas_${_short}")   # upstream: <stem> saturn_atlas_X uses kernel sas_X.S
  add_custom_command(
    OUTPUT ${GEN_KERNELS}/kernel_${_kname}.h
    COMMAND ${PYRUN} ${GEN_DIR}/gen_kernel_header.py
            ${ASM_DIR}/${_kname}.S ${_kname} ${GEN_KERNELS}/kernel_${_kname}.h
    DEPENDS ${ASM_DIR}/${_kname}.S ${GEN_DIR}/gen_kernel_header.py
            ${UP_ATLAS}/baremetal/assembler.py
    COMMENT "Assembling Atlas kernel ${_kname}.S -> kernel_${_kname}.h")
  list(APPEND _gen_outputs ${GEN_KERNELS}/kernel_${_kname}.h)
endif()

if(_kind STREQUAL "kernel" OR _kind STREQUAL "torch")
  if(_kind STREQUAL "torch")
    execute_process(COMMAND ${PYTHON_EXECUTABLE} -c "import torch"
                    RESULT_VARIABLE _rc OUTPUT_QUIET ERROR_QUIET)
    if(NOT _rc EQUAL 0)
      message(FATAL_ERROR
        "${ATLAS_TEST} needs golden headers from the team's bit-exact models, whose "
        "generators `import torch` (python: ${PYTHON_EXECUTABLE}), and torch is not "
        "installed in this environment. Needed: python packages torch + numpy in the env that runs cmake "
        "(the generators also import the team's software_models/, found via PYTHONPATH).")
    endif()
  endif()
  set(_gen "${ATLAS_GEN_${ATLAS_TEST}}")          # generator stem
  if(NOT _gen)
    set(_gen "gen_${_stem}")
  endif()
  set(_gen_args "${ATLAS_GENARGS_${ATLAS_TEST}}") # e.g. --interlude-mode native_bf16_rne
  set(_golden ${GEN_GOLDEN}/${_stem}_golden.h)   # the name the upstream .c includes
  file(GLOB_RECURSE _gen_deps CONFIGURE_DEPENDS
    ${GEN_DIR}/software_models/*.py ${UP_ATLAS}/dependencies/fpex/model/*.py)
  add_custom_command(
    OUTPUT ${_golden}
    COMMAND ${PYRUN} ${GEN_DIR}/${_gen}.py ${_gen_args} --out-header ${_golden}
    DEPENDS ${GEN_DIR}/${_gen}.py ${GEN_DIR}/gen_utils.py ${GEN_DIR}/vpu_gen_utils.py
            ${GEN_DIR}/mxu_fp8_utils.py ${_gen_deps}
    COMMENT "Generating ${_stem}_golden.h")
  list(APPEND _gen_outputs ${_golden})
endif()

if(_gen_outputs)
  add_custom_target(atlas_upstream_gen DEPENDS ${_gen_outputs})
  add_dependencies(app atlas_upstream_gen)
endif()

# ---- the test itself ---------------------------------------------------------------
# Upstream source compiled unmodified; the include order matters: upstream tests/
# supplies atlas_mmio.h, saturn_rvv_mx.h, saturn_atlas_stress_common.h.
target_sources(app PRIVATE
  ${UP_TESTS}/${ATLAS_SRC_${ATLAS_TEST}}
  shim/atlas_upstream_shim.c)
target_include_directories(app PRIVATE ${UP_TESTS} ${GEN_KERNELS} ${GEN_GOLDEN})
if(ATLAS_DEFS_${ATLAS_TEST})
  target_compile_definitions(app PRIVATE ${ATLAS_DEFS_${ATLAS_TEST}})
endif()
target_compile_definitions(app PRIVATE ATLAS_UPSTREAM_NAME="${ATLAS_TEST}")

# main() -> __wrap_main() in the shim: result line, exit code, watchdog.
zephyr_ld_options(-Wl,--wrap=main)
