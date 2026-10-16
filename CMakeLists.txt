# SPDX-License-Identifier: Apache-2.0
#
# Module hook: Zephyr runs this file because zephyr/module.yml says `cmake: .`.
# No out-of-tree drivers or libraries yet; add them here, e.g. add_subdirectory_ifdef(CONFIG_FOO drivers/foo).

# Headers shared by apps and the port: <chipyard/sim_exit.h> and tc_util_user_override.h
# (Zephyr's test framework includes the latter by name).
zephyr_include_directories(include)
