# SPDX-License-Identifier: Apache-2.0
#
# Builds a bare directory of .c/.cpp/.S (no CMakeLists.txt) as a Zephyr app. Shared by the
# Makefile, `west app` and plain `west build`:
#
#   west build -b chipyard_penguin/penguin <BSP>/cmake/plain_app \
#       -- -DPLAIN_APP_DIR=/abs/path/to/dir
#
# PLAIN_APP_DIR (alias PLAIN_SRC_DIR) should be an absolute path. The directory is handled
# as follows:
#   * every *.c *.cpp *.cc *.cxx *.S below it is compiled (build*/ and .git/ are skipped);
#   * <dir> and <dir>/include are on the include path;
#   * a C++ file enables CONFIG_CPP and C++17;
#   * <dir>/prj.conf is merged over cmake/plain_app/prj.conf and <dir>/*.overlay are used as
#     devicetree overlays; -DEXTRA_CONF_FILE, -DEXTRA_DTC_OVERLAY_FILE, -DCONF_FILE and
#     -DCONFIG_FOO=y override them;
#   * the simulation ends when main() returns, with its return value as the exit code
#     (linker --wrap=main, exit_shim.c, chipyard_sim_exit() from <chipyard/sim_exit.h>).
#     Calling chipyard_sim_exit() directly also works.

cmake_minimum_required(VERSION 3.20.0)

# The logic is split into two include files so the test shim, which needs its own
# find_package/project, can reuse it.
include(${CMAKE_CURRENT_LIST_DIR}/plain_app_pre.cmake)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(plain_app)
include(${CMAKE_CURRENT_LIST_DIR}/plain_app_post.cmake)
