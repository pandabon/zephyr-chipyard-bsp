/* SPDX-License-Identifier: Apache-2.0 */
#include "adder.h"

namespace {
template <typename T> constexpr T add(T a, T b) { return a + b; }
}

extern "C" int cpp_add(int a, int b)
{
	return add(a, b);
}
