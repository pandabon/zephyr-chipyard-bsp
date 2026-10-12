# SPDX-License-Identifier: Apache-2.0
#
# First half of the plain-app core: validates PLAIN_APP_DIR, finds the sources and picks the
# Kconfig and devicetree inputs. Run before find_package(Zephyr). Included by
# CMakeLists.txt and tests/plain_app/CMakeLists.txt.

if(NOT PLAIN_APP_DIR AND PLAIN_SRC_DIR)
  set(PLAIN_APP_DIR "${PLAIN_SRC_DIR}")
elseif(PLAIN_APP_DIR AND PLAIN_SRC_DIR)
  get_filename_component(_a "${PLAIN_APP_DIR}" ABSOLUTE)
  get_filename_component(_b "${PLAIN_SRC_DIR}" ABSOLUTE)
  if(NOT _a STREQUAL _b)
    message(FATAL_ERROR "PLAIN_APP_DIR (${_a}) and PLAIN_SRC_DIR (${_b}) differ; set only one")
  endif()
endif()
if(NOT PLAIN_APP_DIR)
  message(FATAL_ERROR "PLAIN_APP_DIR is not set: pass -DPLAIN_APP_DIR=<abs dir with .c/.cpp files>")
endif()
get_filename_component(PLAIN_APP_DIR "${PLAIN_APP_DIR}" ABSOLUTE)
if(NOT IS_DIRECTORY "${PLAIN_APP_DIR}")
  message(FATAL_ERROR "PLAIN_APP_DIR '${PLAIN_APP_DIR}' is not a directory")
endif()

# --- find sources (before find_package, since C++ use feeds Kconfig) ----------
file(GLOB_RECURSE _plain_all CONFIGURE_DEPENDS
  "${PLAIN_APP_DIR}/*.c" "${PLAIN_APP_DIR}/*.cpp" "${PLAIN_APP_DIR}/*.cc"
  "${PLAIN_APP_DIR}/*.cxx" "${PLAIN_APP_DIR}/*.S")
set(PLAIN_SRCS)
set(_plain_has_cpp FALSE)
foreach(_f ${_plain_all})
  # judge the path relative to the plain dir, whose parents may be named build/
  file(RELATIVE_PATH _rel "${PLAIN_APP_DIR}" "${_f}")
  if(NOT _rel MATCHES "(^|/)(build[^/]*|\\.git)/")
    list(APPEND PLAIN_SRCS "${_f}")
    if(_f MATCHES "\\.(cpp|cc|cxx)$")
      set(_plain_has_cpp TRUE)
    endif()
  endif()
endforeach()
if(NOT PLAIN_SRCS)
  message(FATAL_ERROR "No .c/.cpp/.cc/.cxx/.S files found under ${PLAIN_APP_DIR}")
endif()

# --- Kconfig / devicetree inputs ---------------------------------------------
# Our prj.conf is the default CONF_FILE. The generated C++ fragment and the plain dir's
# prj.conf go into EXTRA_CONF_FILE ahead of anything passed with -D.
set(_plain_conf)
if(_plain_has_cpp)
  file(WRITE "${CMAKE_BINARY_DIR}/plain_cpp.conf" "CONFIG_CPP=y\nCONFIG_STD_CPP17=y\n")
  list(APPEND _plain_conf "${CMAKE_BINARY_DIR}/plain_cpp.conf")
endif()
if(EXISTS "${PLAIN_APP_DIR}/prj.conf")
  list(APPEND _plain_conf "${PLAIN_APP_DIR}/prj.conf")
endif()
if(NOT CONF_FILE)
  set(CONF_FILE "${CMAKE_CURRENT_LIST_DIR}/prj.conf")
endif()
set(EXTRA_CONF_FILE ${_plain_conf} ${EXTRA_CONF_FILE})

file(GLOB _plain_overlays "${PLAIN_APP_DIR}/*.overlay")
set(EXTRA_DTC_OVERLAY_FILE ${_plain_overlays} ${EXTRA_DTC_OVERLAY_FILE})
