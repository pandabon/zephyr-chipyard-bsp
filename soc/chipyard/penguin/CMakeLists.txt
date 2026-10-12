# SPDX-License-Identifier: Apache-2.0

zephyr_sources(soc.c)
zephyr_include_directories(.)

set(SOC_LINKER_SCRIPT ${ZEPHYR_BASE}/include/zephyr/arch/riscv/common/linker.ld CACHE INTERNAL "")

# Same GCC 15 language-standard pin as Zephyr's soc/rocketchip/virt_riscv.
zephyr_compile_options(
  $<$<COMPILE_LANGUAGE:C>:-std=gnu17>
  $<$<COMPILE_LANGUAGE:CXX>:-std=gnu++17>
)
