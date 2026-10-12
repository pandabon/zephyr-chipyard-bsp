# SPDX-License-Identifier: Apache-2.0
#
# Second half of the plain-app core: adds sources, includes and the exit-on-return shim.
# Run after project().

message(STATUS "plain_app: ${PLAIN_APP_DIR} (C++: ${_plain_has_cpp})")
foreach(_f ${PLAIN_SRCS})
  message(STATUS "plain_app:   ${_f}")
endforeach()

target_sources(app PRIVATE ${PLAIN_SRCS} "${CMAKE_CURRENT_LIST_DIR}/exit_shim.c")
target_include_directories(app PRIVATE "${PLAIN_APP_DIR}")
if(IS_DIRECTORY "${PLAIN_APP_DIR}/include")
  target_include_directories(app PRIVATE "${PLAIN_APP_DIR}/include")
endif()

# Route the kernel's main() through exit_shim.c, which calls the app's main as __real_main.
zephyr_ld_options(-Wl,--wrap=main)
