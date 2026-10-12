# SPDX-License-Identifier: Apache-2.0
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(rvv_bf16)

target_sources(app PRIVATE src/main.c)
# Keep the scalar reference loops scalar.
target_compile_options(app PRIVATE -fno-tree-vectorize)
