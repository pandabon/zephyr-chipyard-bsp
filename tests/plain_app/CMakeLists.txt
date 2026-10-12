# SPDX-License-Identifier: Apache-2.0
#
# run_tests.py and twister build the directory holding testcase.yaml, so this shim repeats
# the steps of cmake/plain_app/CMakeLists.txt. PLAIN_APP_DIR comes from extra_args, relative
# to this directory.
cmake_minimum_required(VERSION 3.20.0)

set(_core ${CMAKE_CURRENT_LIST_DIR}/../../cmake/plain_app)
include(${_core}/plain_app_pre.cmake)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(plain_app)
include(${_core}/plain_app_post.cmake)
