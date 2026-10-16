# SPDX-License-Identifier: Apache-2.0

# kernels/*.bin and src/kernels_gen.h are GENERATED from kernels/*.S by regen_kernels.py (needs the
# Atlas team's assembler: set ATLAS_NPU_DIR or BRINGUP_CHIPYARD). They are tracked so that building
# this sample needs neither; rerun regen_kernels.py only after editing a .S file.

cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(atlas_smoke)

target_sources(app PRIVATE src/main.c)
