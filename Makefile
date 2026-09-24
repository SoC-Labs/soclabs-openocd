# soclabs-openocd/Makefile
#
# Builds upstream OpenOCD, at the commit pinned in openocd.pin, with the
# SoC Labs flash drivers registered into it via patches/*.patch. This is
# NOT a fork: `build/openocd-src` is a pristine upstream clone up to the
# `patch` step, which touches only the three files patches/*.patch touch.
# Driver .c files themselves are never copied in -- see drivers/README.md.
#
# Every step is meant to be safe to re-run: `fetch` leaves an existing
# clone alone (just re-checks the pin), `patch` detects an already-applied
# patch and skips it, `overlay` just re-links. Nothing here mutates
# anything outside $(CURDIR)/build and $(CURDIR)/install.
#
# ---------------------------------------------------------------------------
# Driver registry. Adding a SECOND driver is these two lines:
#
#   DRIVERS  += foo
#   foo_ROOT ?= ../path/to/foo-owning-repo
#
# (then add patches/000N-register-foo.patch -- see drivers/README.md)
# ---------------------------------------------------------------------------
DRIVERS       := ahb_qspi
# NOTE the path: ahb_qspi is a submodule of nanosoc-multicore-system, which is
# itself a submodule of nanosoc-ethernet-chiplet. There is ALSO a standalone
# checkout at ../nanosoc-multicore-system -- a different tree, on a different
# branch, which does NOT carry sw/openocd/. Pointing at that one resolves
# cleanly and then fails to find the driver, so name the full path explicitly.
#
# 2026-09-24: THE DEFAULT IS NOT THAT SUBMODULE. It is a checkout of ahb_qspi
# branch fix/probe-restores-xip (1e5117e: a failed `flash probe` puts XiP back
# as it found it). The eth chiplet's submission branch pins the submodule at
# 07b40f5 and that pin is frozen for tapeout, so the fix cannot reach the
# submodule path. The checkout is a clone of the branch in the submodule's own
# repository:
#   git clone -b fix/probe-restores-xip  <SRC>  ../ahb_qspi-probe-xip
# where <SRC> is
#   ../nanosoc-ethernet-chiplet/.git/modules/nanosoc-multicore-system/modules/ahb_qspi
# (A clone, not `git worktree add`: that repository's common config carries
# core.worktree, which a linked worktree would inherit.) Once a pin carries
# 1e5117e, put this back to ../nanosoc-ethernet-chiplet/nanosoc-multicore-system/ahb_qspi.
ahb_qspi_ROOT ?= ../ahb_qspi-probe-xip
ahb_qspi_SRC  := $(ahb_qspi_ROOT)/sw/openocd/ahb_qspi.c
# Where in the OpenOCD tree this driver's .c belongs. NOR flash drivers live in
# src/flash/nor; ADAPTER drivers live in src/jtag/drivers and additionally touch
# configure.ac, interface.h and interfaces.c (handled by that driver's patch,
# not here). Every driver must declare a _DEST -- there is no default, because a
# wrong default puts an adapter in the flash directory where it silently is not
# compiled.
ahb_qspi_DEST := src/flash/nor

# Second driver: a dapdirect ADAPTER, emulating a MEM-AP in software over the
# HOSTIO4/ADP link, so it lands in src/jtag/drivers rather than src/flash/nor.
# An adapter is a bigger registration than a flash driver -- its patch also
# touches configure.ac and src/jtag/interfaces.c (at v0.12.0 the adapter externs
# live in interfaces.c; master moved them to interface.h, so the two are not
# interchangeable, same as for ahb_qspi).
# ENABLED 2026-09-18, once the canonical hostio4.c carried the single-source
# guard (patches/hostio4-single-source-guard.patch, now applied upstream).
# Before that it could not be enabled here: the owning repo's copy used the
# MASTER spelling (.transport_ids), which v0.12.0's struct adapter_driver does
# not have, so a default `make build` would have failed to compile.
#
# Re-verified against the canonical file on the day it was enabled:
# gcc -fsyntax-only rc=0 at BOTH v0.12.0 and master, with the preprocessor
# taking a different branch at each. No hostio4_SRC= override is needed.
DRIVERS       += hostio4
hostio4_ROOT  ?= ../nanosoc-ethernet-chiplet/scripts/rig/eth_chiplet/openocd_hostio4
hostio4_SRC   := $(hostio4_ROOT)/hostio4.c
hostio4_DEST  := src/jtag/drivers

# ---------------------------------------------------------------------------
# Everything below this line is generic driver-registry plumbing; it should
# not need editing to add another driver.
# ---------------------------------------------------------------------------
OPENOCD_REMOTE   ?= https://github.com/openocd-org/openocd.git
PIN_FILE         := openocd.pin
PINNED_SHA       := $(strip $(shell sed -n 's/^sha:[[:space:]]*//p' $(PIN_FILE)))
BUILD_DIR        := build/openocd-src
PREFIX           ?= $(abspath install)
CONFIGURE_FLAGS  ?=
# Pin-matched: v0.12.0 puts the externs in drivers.c, master puts them in
# driver.h, so the two patches are NOT interchangeable. Keep this in step with
# openocd.pin's sha.
PATCHES          := patches/0001-register-ahb_qspi-v0.12.0.patch
# hostio4 is an ADAPTER, so its registration reaches further than a flash
# driver's: configure.ac, src/jtag/drivers/Makefile.am and src/jtag/interfaces.c
# (at v0.12.0 the adapter externs live in interfaces.c; master moved them to
# interface.h). Because it edits configure.ac, adding or removing it forces a
# re-bootstrap -- see PATCH_STAMP below.
PATCHES         += patches/0002-register-hostio4-v0.12.0.patch

# Adapter selection (--enable-cmsis-dap, --enable-ftdi, ...) is deliberately
# NOT hardcoded here: that choice belongs to whoever is planning the target
# deployment (which probe talks to which board), not to this recipe. Pass it
# via CONFIGURE_FLAGS, e.g.:
#   make build CONFIGURE_FLAGS="--enable-cmsis-dap"

# --- remote deployment -----------------------------------------------------
# The bench does not run OpenOCD on this workstation. scripts/rig/.../haps-openocd
# ssh's to $HAPS_OPENOCD_SSH (default haps-dev) and execs $HAPS_OPENOCD_BIN there.
# So "the binary carries the driver" is a claim about haps-dev, and checking it
# here proves nothing about what the bench will execute.
#
# install-remote runs THIS RECIPE on the remote host rather than copying a
# binary over: haps-dev is a different machine with its own glibc and its own
# libusb/libftdi, and a locally-linked openocd is not guaranteed to run there.
HOST          ?=
REMOTE_PREFIX ?= /opt/soclabs-openocd/0.12.0-soclabs
REMOTE_BIN    ?= $(REMOTE_PREFIX)/bin/openocd
# Where this recipe is checked out ON the remote host. NOTE: today that path
# sits under the OLD install prefix (/opt/haps-openocd-ahb_qspi) because the
# build predates the rename to /opt/soclabs-openocd. The dead install beside
# it is removable; this src/ tree is NOT -- it is the live build tree and the
# ahb_qspi.c the overlay symlink resolves to. Do not blanket-rm the parent.
REMOTE_RECIPE ?= /opt/haps-openocd-ahb_qspi/src/soclabs-openocd
SSH           ?= ssh -o BatchMode=yes

.PHONY: help fetch check-pin patch overlay build verify verify-local verify-remote \
        test install install-remote clean distclean

help:
	@echo "soclabs-openocd -- registered drivers: $(DRIVERS)"
	@echo ""
	@echo "  make fetch          clone upstream (if not already) and check out the pin"
	@echo "  make patch          apply patches/*.patch (idempotent)"
	@echo "  make overlay        symlink each driver's .c in from its owning repo"
	@echo "  make build          configure + build the binary (GATED on verify)"
	@echo "  make install        install to PREFIX (GATED on verify of the installed binary)"
	@echo "  make verify         assert every registered driver is embedded"
	@echo "  make test [BIN=..]  run the drivers' offline tests (no hardware) on a binary"
	@echo "  make clean          remove build outputs, keep the cloned+patched source"
	@echo "  make distclean      remove build/ entirely (next fetch starts fresh)"
	@echo ""
	@echo "  make install-remote HOST=haps-dev   build+install+verify ON the bench host"
	@echo "  make verify         HOST=haps-dev   assert the drivers in $(REMOTE_BIN) there"
	@echo ""
	@echo "override a driver's source: make overlay ahb_qspi_ROOT=/path/to/it"
	@echo "override upstream configure flags: make build CONFIGURE_FLAGS=\"--enable-cmsis-dap\""

check-pin:
	@if [ -z "$(PINNED_SHA)" ]; then \
		echo "check-pin: no 'sha:' line found in $(PIN_FILE) -- refusing to build against an unpinned upstream" >&2; \
		exit 1; \
	fi
	@echo "check-pin: pin is $(PINNED_SHA) (from $(PIN_FILE))"

# --- fetch: clone once, then always re-assert the pin ----------------------
fetch: check-pin
	@if [ -d $(BUILD_DIR)/.git ]; then \
		echo "fetch: $(BUILD_DIR) already exists, leaving the clone as-is (use 'make distclean' to redo it)"; \
	else \
		mkdir -p $(dir $(BUILD_DIR)); \
		git clone $(OPENOCD_REMOTE) $(BUILD_DIR); \
	fi
	@cd $(BUILD_DIR) && git fetch --quiet origin $(PINNED_SHA) 2>/dev/null; true
	@cd $(BUILD_DIR) && git checkout --quiet $(PINNED_SHA)
	@got=$$(cd $(BUILD_DIR) && git rev-parse HEAD); \
	if [ "$$got" != "$(PINNED_SHA)" ]; then \
		echo "fetch: FAILED -- $(BUILD_DIR) is at $$got, openocd.pin says $(PINNED_SHA)." >&2; \
		echo "        Refusing to build against an unverified upstream. Fix the pin or the clone." >&2; \
		exit 1; \
	fi
	@cd $(BUILD_DIR) && git submodule update --init --recursive --quiet
	@echo "fetch: $(BUILD_DIR) verified at pinned $(PINNED_SHA)"

# --- patch: apply every patches/*.patch, skipping any already applied ------
patch: fetch
	@for p in $(PATCHES); do \
		if (cd $(BUILD_DIR) && git apply --reverse --check "$(CURDIR)/$$p" 2>/dev/null); then \
			echo "patch: $$p already applied -- skipping"; \
		elif (cd $(BUILD_DIR) && git apply --check "$(CURDIR)/$$p" 2>/dev/null); then \
			echo "patch: applying $$p"; \
			(cd $(BUILD_DIR) && git apply "$(CURDIR)/$$p"); \
		else \
			echo "patch: FAILED -- $$p neither applies cleanly nor is already applied." >&2; \
			echo "        Upstream has likely drifted from the pinned commit; check openocd.pin." >&2; \
			exit 1; \
		fi; \
	done

# --- overlay: symlink each registered driver's .c in from its owning repo --
overlay: patch
	@$(foreach d,$(DRIVERS), \
		if [ ! -f "$($(d)_SRC)" ]; then \
			echo "overlay: FAILED -- $(d): '$($(d)_SRC)' not found." >&2; \
			echo "          Set $(d)_ROOT= to the checkout that owns it, e.g.:" >&2; \
			echo "            make overlay $(d)_ROOT=/path/to/it" >&2; \
			exit 1; \
		fi; \
		if [ -z "$($(d)_DEST)" ]; then \
			echo "overlay: FAILED -- $(d): no $(d)_DEST set. Declare where in the" >&2; \
			echo "          OpenOCD tree it belongs (src/flash/nor, src/jtag/drivers, ...)." >&2; \
			exit 1; \
		fi; \
		if [ ! -d "$(BUILD_DIR)/$($(d)_DEST)" ]; then \
			echo "overlay: FAILED -- $(d): '$($(d)_DEST)' is not a directory in the" >&2; \
			echo "          pinned OpenOCD tree. Upstream layout may have moved." >&2; \
			exit 1; \
		fi; \
		echo "overlay: $(d) -> $($(d)_DEST)/$(d).c  <- $($(d)_SRC)"; \
		ln -sf "$(abspath $($(d)_SRC))" "$(BUILD_DIR)/$($(d)_DEST)/$(d).c"; \
	)
	@echo "overlay: $(words $(DRIVERS)) driver(s) linked: $(DRIVERS)"

# --- build: configure + compile -------------------------------------------
# NOTE the stamp. An ADAPTER driver's patch edits configure.ac, so a tree that
# was already configured against the previous patch set has a stale configure
# script and a stale Makefile -- it would build happily and silently omit the
# new driver, which is exactly the failure `verify` exists to catch, arriving
# one step earlier. Changing PATCHES therefore forces a re-bootstrap.
PATCH_STAMP := $(BUILD_DIR)/.soclabs-patch-stamp

build: overlay
	@want="$$(cat $(PATCHES) | md5sum | cut -d' ' -f1)"; \
	got="$$(cat $(PATCH_STAMP) 2>/dev/null)"; \
	if [ "$$want" != "$$got" ] && [ -f $(BUILD_DIR)/Makefile ]; then \
		echo "build: patch set changed -- forcing re-bootstrap (configure.ac may have moved)"; \
		rm -f $(BUILD_DIR)/Makefile $(BUILD_DIR)/configure; \
	fi; \
	echo "$$want" > $(PATCH_STAMP)
	@if [ ! -x $(BUILD_DIR)/configure ]; then \
		echo "build: bootstrapping (autoreconf) $(BUILD_DIR)"; \
		(cd $(BUILD_DIR) && ./bootstrap); \
	fi
	@if [ ! -f $(BUILD_DIR)/Makefile ]; then \
		echo "build: configuring (PREFIX=$(PREFIX))"; \
		(cd $(BUILD_DIR) && ./configure --prefix=$(PREFIX) $(CONFIGURE_FLAGS)); \
	else \
		echo "build: $(BUILD_DIR)/Makefile already configured -- leaving it (distclean to reconfigure)"; \
	fi
	$(MAKE) -C $(BUILD_DIR)
	@echo "build: binary at $(BUILD_DIR)/src/openocd"
	@$(MAKE) --no-print-directory verify-local

# --- install: to PREFIX, then verify what actually landed there ------------
# The manifest records, for the binary it sits beside: that binary's own md5,
# and the md5 of each driver SOURCE it was built from. Both halves are needed.
# The driver md5s are what makes staleness detectable at all. The binary md5 is
# what stops the manifest drifting from the binary -- without it, a rebuild that
# skipped the manifest would leave a stale manifest vouching for a new binary,
# which is the same class of lie the manifest exists to catch.
MANIFEST_DIR  = $(PREFIX)/share/soclabs-openocd
MANIFEST      = $(MANIFEST_DIR)/build.manifest

install: build
	$(MAKE) -C $(BUILD_DIR) install
	@mkdir -p "$(MANIFEST_DIR)"
	@{ echo "# soclabs-openocd build manifest -- written by 'make install'."; \
	   echo "# 'make verify' compares these against the live binary and the"; \
	   echo "# CURRENT driver sources. A mismatch means the binary is stale."; \
	   echo "binary_md5 $$(md5sum '$(PREFIX)/bin/openocd' | cut -d' ' -f1)"; \
	   $(foreach d,$(DRIVERS),echo "driver $(d) $$(md5sum '$(abspath $($(d)_SRC))' | cut -d' ' -f1)";) \
	 } > "$(MANIFEST)"
	@echo "install: manifest at $(MANIFEST)"
	@$(MAKE) --no-print-directory verify-bin BIN="$(PREFIX)/bin/openocd" MANIFEST_IN="$(MANIFEST)"
	@echo "install: $(PREFIX)/bin/openocd carries: $(DRIVERS)"

# ---------------------------------------------------------------------------
# verify: THE GATE. Does the binary that will actually be run carry every
# registered driver?
#
# This is a gate and not a documentation line because of how it breaks: someone
# rebuilds without the overlay, gets a clean binary that works perfectly for
# SWD, and finds out months later when `flash write_image` reports an unknown
# driver and points at nothing. Both builds answer `openocd --version` with the
# same string (0.12.0-01004-g9ea7f3d64-dirty), so they are indistinguishable
# from outside. `build` and `install` therefore both fail on it.
#
#   make verify                 the binary in the build tree
#   make verify BIN=/path/oocd  a specific local binary
#   make verify HOST=haps-dev   $(REMOTE_BIN) on the host the bench executes
# ---------------------------------------------------------------------------
BIN ?=

verify:
	@if [ -n "$(strip $(HOST))" ]; then \
		$(MAKE) --no-print-directory verify-remote HOST="$(strip $(HOST))"; \
	elif [ -n "$(strip $(BIN))" ]; then \
		$(MAKE) --no-print-directory verify-bin BIN="$(strip $(BIN))"; \
	else \
		$(MAKE) --no-print-directory verify-local; \
	fi

verify-local:
	@$(MAKE) --no-print-directory verify-bin BIN="$(BUILD_DIR)/src/openocd"

# verify-bin: the actual assertion, against one local binary. Two questions,
# and they are NOT the same one asked twice:
#   1. is each registered driver IN this binary?      (a strings match)
#   2. was it built from the source that exists NOW?  (the manifest)
# (1) alone passed for four days while the bench ran a stale driver.
verify-bin:
	@bin="$(BIN)"; \
	if [ ! -x "$$bin" ]; then \
		echo "verify: FAILED -- '$$bin' not found or not executable. Run 'make build' first." >&2; \
		exit 1; \
	fi; \
	fail=0; \
	for d in $(DRIVERS); do \
		if strings "$$bin" | grep -qx "$$d"; then \
			echo "verify: OK   -- '$$d' embedded in $$bin"; \
		else \
			echo "verify: FAIL -- '$$d' NOT in $$bin." >&2; \
			echo "        The overlay did not run, or the registration patch did not apply." >&2; \
			echo "        This binary loads and runs normally; it fails only at flash time." >&2; \
			fail=1; \
		fi; \
	done; \
	m="$(MANIFEST_IN)"; \
	if [ -z "$$m" ]; then m="$$(dirname "$$bin")/../share/soclabs-openocd/build.manifest"; fi; \
	if [ ! -f "$$m" ]; then \
		echo "verify: WARN -- no build manifest beside $$bin; freshness NOT checked." >&2; \
		echo "        The drivers are present, but nothing records WHICH SOURCE built" >&2; \
		echo "        them. Re-run 'make install' to write one." >&2; \
	else \
		want=$$(md5sum "$$bin" | cut -d' ' -f1); \
		got=$$(awk '/^binary_md5/{print $$2}' "$$m"); \
		if [ "$$want" != "$$got" ]; then \
			echo "verify: FAIL -- the manifest does not describe this binary." >&2; \
			echo "        manifest says $$got, binary is $$want. Something rebuilt without" >&2; \
			echo "        re-installing, so the manifest is not evidence about this file." >&2; \
			fail=1; \
		else \
			$(foreach d,$(DRIVERS), \
			  rec=$$(awk -v n="$(d)" '$$1=="driver" && $$2==n {print $$3}' "$$m"); \
			  cur=$$(md5sum "$(abspath $($(d)_SRC))" 2>/dev/null | cut -d' ' -f1); \
			  if [ -n "$$cur" ] && [ "$$rec" != "$$cur" ]; then \
			    echo "verify: FAIL -- '$(d)' is STALE in this binary." >&2; \
			    echo "        built from $$rec" >&2; \
			    echo "        source is  $$cur" >&2; \
			    echo "        The driver IS present, so a name check passes -- it is the WRONG" >&2; \
			    echo "        VERSION. Re-run 'make install' (or install-remote HOST=...)." >&2; \
			    fail=1; \
			  elif [ -n "$$cur" ]; then \
			    echo "verify: OK   -- '$(d)' is current ($$cur)"; \
			  fi; ) \
		fi; \
	fi; \
	if [ $$fail -ne 0 ]; then \
		echo "verify: GATE FAILED -- refusing to call this build good." >&2; \
	fi; \
	exit $$fail

# --- test: do the drivers BEHAVE? --------------------------------------------
# verify asks whether each driver is IN the binary and CURRENT. It cannot tell
# a working driver from a broken one. test runs hostio4's test_driver_fixes.sh
# on BIN (default: the build tree's binary): one leg per fixed defect,
# including ahb_qspi's failed-probe XiP restore, plus the six hardware-proof
# steps and an 8224-byte load_image. Every far end is SOFTWARE, either
# HAPS-work's adpmon.py or the misbehaving fake_mon.py. Nothing touches a board,
# a dongle or a session. Exit status is the number of failed legs.
#   make test BIN=$(PREFIX)/bin/openocd
test:
	@bin="$(if $(strip $(BIN)),$(strip $(BIN)),$(BUILD_DIR)/src/openocd)"; \
	"$(abspath $(hostio4_ROOT))/test_driver_fixes.sh" "$$bin"

# verify-remote: the same assertion, on the host that will run the binary.
verify-remote:
	@if [ -z "$(strip $(HOST))" ]; then \
		echo "verify-remote: set HOST=, e.g. 'make verify HOST=haps-dev'" >&2; \
		exit 1; \
	fi
	@if ! $(SSH) $(HOST) true 2>/dev/null; then \
		echo "verify-remote: cannot ssh to $(HOST) non-interactively. NOT a pass -- unknown." >&2; \
		exit 1; \
	fi
	@if ! $(SSH) $(HOST) "test -x '$(REMOTE_BIN)'" 2>/dev/null; then \
		echo "verify-remote: FAIL -- $(REMOTE_BIN) is not executable on $(HOST)." >&2; \
		echo "        Run: make install-remote HOST=$(HOST)" >&2; \
		exit 1; \
	fi
	@fail=0; fresh=1; \
	for d in $(DRIVERS); do \
		if $(SSH) $(HOST) "strings '$(REMOTE_BIN)' | grep -qx $$d" 2>/dev/null; then \
			echo "verify: OK   -- '$$d' embedded in $(HOST):$(REMOTE_BIN)"; \
		else \
			echo "verify: FAIL -- '$$d' NOT in $(HOST):$(REMOTE_BIN)." >&2; \
			fail=1; \
		fi; \
	done; \
	m=$$(mktemp); \
	if ! $(SSH) $(HOST) "cat '$(REMOTE_PREFIX)/share/soclabs-openocd/build.manifest'" > "$$m" 2>/dev/null || [ ! -s "$$m" ]; then \
		echo "verify: WARN -- could not read the build manifest on $(HOST)." >&2; \
		echo "        Either it was never written (run install-remote) or the ssh" >&2; \
		echo "        failed. This is UNKNOWN, not a verdict about freshness." >&2; \
		rm -f "$$m"; fresh=0; \
	else \
		want=$$($(SSH) $(HOST) "md5sum '$(REMOTE_BIN)'" 2>/dev/null | cut -d' ' -f1); \
		got=$$(awk '/^binary_md5/{print $$2}' "$$m"); \
		if [ -z "$$want" ]; then \
			echo "verify: WARN -- could not hash $(REMOTE_BIN) on $(HOST) (ssh failed)." >&2; \
			echo "        UNKNOWN, not a verdict." >&2; \
			fresh=0; \
		elif [ "$$want" != "$$got" ]; then \
			echo "verify: FAIL -- the manifest on $(HOST) does not describe $(REMOTE_BIN)." >&2; \
			echo "        manifest says $$got, binary is $$want -- something rebuilt" >&2; \
			echo "        there without re-installing." >&2; \
			fail=1; \
		else \
			$(foreach d,$(DRIVERS), \
			  rec=$$(awk '$$1=="driver" && $$2=="$(d)" {print $$3}' "$$m"); \
			  cur=$$(md5sum "$(abspath $($(d)_SRC))" 2>/dev/null | cut -d' ' -f1); \
			  if [ -z "$$rec" ]; then \
			    echo "verify: WARN -- '$(d)' has NO entry in the manifest on $(HOST)." >&2; \
			    echo "        Absent is not the same as stale: this says nothing about" >&2; \
			    echo "        which source built it. Re-run install-remote." >&2; \
			    fresh=0; \
			  elif [ -z "$$cur" ]; then \
			    echo "verify: WARN -- cannot hash the local source for '$(d)'; skipped." >&2; \
			    fresh=0; \
			  elif [ "$$rec" != "$$cur" ]; then \
			    echo "verify: FAIL -- '$(d)' on $(HOST) is STALE." >&2; \
			    echo "        bench built from $$rec" >&2; \
			    echo "        your source is   $$cur" >&2; \
			    echo "        The driver IS present there, so a name check passes. The" >&2; \
			    echo "        bench runs the WRONG VERSION. make install-remote HOST=$(HOST)" >&2; \
			    fail=1; \
			  else \
			    echo "verify: OK   -- '$(d)' on $(HOST) is current ($$cur)"; \
			  fi; ) \
		fi; \
		rm -f "$$m"; \
	fi; \
	if [ $$fail -ne 0 ]; then \
		echo "verify: GATE FAILED -- the bench would run a binary missing or stale driver(s)." >&2; \
		echo "        Fix it on $(HOST): make install-remote HOST=$(HOST)" >&2; \
	elif [ "$$fresh" = "0" ]; then \
		echo "verify: $(HOST):$(REMOTE_BIN) carries: $(DRIVERS) -- freshness NOT established,"; \
		echo "        so this does NOT say the bench runs your current source."; \
	else \
		echo "verify: $(HOST):$(REMOTE_BIN) carries, and is CURRENT for: $(DRIVERS)"; \
	fi; \
	exit $$fail

# --- install-remote: stage + build + install + verify ON the bench host ------
# Deliberately NOT a binary copy. haps-dev has its own glibc/libusb/libftdi; a
# binary linked here is not guaranteed to run there, and a binary that will not
# start is a worse failure than one missing a driver. So this drives the same
# recipe over ssh and gates on the installed result.
#
# It DOES copy the driver sources, every time, from whichever checkout owns
# them. Before this existed, haps-dev held a detached plain copy of ahb_qspi.c
# with no provenance -- byte-identical on the day it was made and free to drift
# silently thereafter. Re-staging on every install makes the host copy a cache
# of the owning repo rather than a second source of truth.
REMOTE_SRC ?= $(REMOTE_RECIPE)/drivers-staged
SCP        ?= scp -q -o BatchMode=yes
# Point the remote build at the staged copies, so the host needs no checkout of
# the superproject the drivers live in.
REMOTE_SRC_OVERRIDES := $(foreach d,$(DRIVERS),$(d)_SRC=$(REMOTE_SRC)/$(d).c)

install-remote:
	@if [ -z "$(strip $(HOST))" ]; then \
		echo "install-remote: set HOST=, e.g. 'make install-remote HOST=haps-dev'" >&2; \
		exit 1; \
	fi
	@if ! $(SSH) $(HOST) true 2>/dev/null; then \
		echo "install-remote: cannot reach $(HOST) over ssh. This is NOT a statement" >&2; \
		echo "        about what is installed there -- the host is simply unreachable" >&2; \
		echo "        right now. Retry; a transient reset looks identical to a down host." >&2; \
		exit 1; \
	fi
	@if ! $(SSH) $(HOST) "test -f '$(REMOTE_RECIPE)/Makefile'" 2>/dev/null; then \
		echo "install-remote: reached $(HOST), but no recipe at $(REMOTE_RECIPE)." >&2; \
		echo "        Clone this repo there, or pass REMOTE_RECIPE=<path on $(HOST)>." >&2; \
		exit 1; \
	fi
	@$(SSH) $(HOST) "mkdir -p '$(REMOTE_SRC)'"
	@$(foreach d,$(DRIVERS), \
		if [ ! -f "$($(d)_SRC)" ]; then \
			echo "install-remote: FAILED -- $(d): '$($(d)_SRC)' not found locally." >&2; \
			exit 1; \
		fi; \
		echo "install-remote: staging $(d).c  <- $($(d)_SRC)"; \
		$(SCP) "$($(d)_SRC)" "$(HOST):$(REMOTE_SRC)/$(d).c" || exit 1; \
		here=$$(md5sum "$($(d)_SRC)" | cut -d' ' -f1); \
		there=$$($(SSH) $(HOST) "md5sum '$(REMOTE_SRC)/$(d).c'" | cut -d' ' -f1); \
		if [ "$$here" != "$$there" ]; then \
			echo "install-remote: FAILED -- $(d).c differs after copy ($$here vs $$there)." >&2; \
			exit 1; \
		fi; \
		echo "install-remote:   md5 $$here matches on $(HOST)"; \
	)
	@echo "install-remote: building on $(HOST) in $(REMOTE_RECIPE) (PREFIX=$(REMOTE_PREFIX))"
	$(SSH) $(HOST) "cd '$(REMOTE_RECIPE)' && $(MAKE) install PREFIX='$(REMOTE_PREFIX)' $(REMOTE_SRC_OVERRIDES)"
	@$(MAKE) --no-print-directory verify-remote HOST="$(strip $(HOST))"

# --- clean / distclean -------------------------------------------------------
clean:
	@if [ -f $(BUILD_DIR)/Makefile ]; then \
		$(MAKE) -C $(BUILD_DIR) clean; \
	else \
		echo "clean: $(BUILD_DIR) not configured, nothing to clean"; \
	fi

distclean:
	rm -rf build install
	@echo "distclean: removed build/ and install/ -- next 'make fetch' starts from nothing"
