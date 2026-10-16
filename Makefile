# SPDX-License-Identifier: Apache-2.0
#
# Front door of the BSP checkout. All targets live in mk/user.mk (shared with the
# Makefile of an app repo that uses this BSP); run `make help`.
#
# BSP is this checkout. If west's manifest project is a DIFFERENT checkout of the
# BSP (e.g. a git worktree), Zephyr would silently build that checkout's code, so
# point ZEPHYR_MODULES at this one.

BSP := $(CURDIR)

MANIFEST_BSP := $(shell west list -f '{abspath}' manifest 2>/dev/null | head -1)
ifneq ($(MANIFEST_BSP),)
ifneq ($(realpath $(MANIFEST_BSP)),$(realpath $(BSP)))
MODULES_OVERRIDE ?= $(BSP)
endif
endif

include $(BSP)/mk/user.mk
