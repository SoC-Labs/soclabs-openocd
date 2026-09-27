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
#   foo_ROOT ?= drivers/<submodule of the repo that owns foo.c>
#
# (then add the submodule, and patches/000N-register-foo.patch -- see
# drivers/README.md)
#
# The default roots are SUBMODULES of this recipe (.gitmodules), checked out by
# `make sources` at the commit the recipe pins, and `make check-pins` proves
# each pin is on its branch on the remote. So a recipe commit names the driver
# sources exactly, and a fresh clone builds the same thing on any machine.
# Until 2026-09-27 the roots were sibling checkouts (../ahb_qspi-probe-xip,
# ../nanosoc-ethernet-chiplet/...): whatever those held got built, uncommitted
# edits included, and the ahb_qspi one was a clone whose origin was a path
# inside the chiplet's .git. Pointing a root at a working checkout is still
# the way to build a driver you are editing:
#   make build hostio4_ROOT=../nanosoc-ethernet-chiplet/scripts/rig/eth_chiplet/openocd_hostio4
# ---------------------------------------------------------------------------
DRIVERS       := ahb_qspi
# ahb_qspi's own repository, pinned at 1e5117e: its fix/probe-restores-xip tip
# (a failed `flash probe` puts XiP back as it found it) and, once pushed, the
# tip of its master (decision D5, 27 Sep: a fast-forward). The eth chiplet's
# frozen tapeout pin (07b40f5, via nanosoc-multicore-system) is older and does
# not move; this recipe no longer builds from the chiplet's copy.
ahb_qspi_ROOT ?= drivers/ahb_qspi
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
# Its home is the chiplet repo (decision D6, 27 Sep), pinned at 057d317 on
# feat/padring-boundary-scan. The submodule is the chiplet superproject only
# (~17 MiB checked out): `make sources` never recurses into its submodules.
DRIVERS       += hostio4
hostio4_ROOT  ?= drivers/nanosoc-ethernet-chiplet/scripts/rig/eth_chiplet/openocd_hostio4
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
# Normalised, because `build` compares it with the prefix the tree was
# configured for, and configure strips a trailing slash: PREFIX=/x/ would
# otherwise never match /x, and every build would clean and reconfigure.
override PREFIX  := $(abspath $(PREFIX))
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

.PHONY: help sources check-pins fetch check-pin patch overlay build verify verify-local \
        verify-remote test selftest install install-remote clean distclean

help:
	@echo "soclabs-openocd -- registered drivers: $(DRIVERS)"
	@echo ""
	@echo "  make sources        check out the driver submodules at their pins (never recursive)"
	@echo "  make check-pins     prove each driver pin is on its .gitmodules branch, on the remote"
	@echo "  make fetch          clone upstream (if not already) and check out the pin"
	@echo "  make patch          apply patches/*.patch (idempotent)"
	@echo "  make overlay        symlink each driver's .c in from its owning repo"
	@echo "  make build          configure + build the binary (GATED on verify)"
	@echo "  make install        install to PREFIX (GATED on verify of the installed binary)"
	@echo "  make verify         assert every registered driver is embedded"
	@echo "  make test [BIN=..]  run the drivers' offline tests (no hardware) on a binary"
	@echo "  make selftest       test this recipe's install, site and pin logic (all fakes, ~70 s)"
	@echo "  make clean          remove build outputs, keep the cloned+patched source"
	@echo "  make distclean      remove build/ entirely (next fetch starts fresh)"
	@echo ""
	@echo "  make install-site   build+install+verify+test into $(SITE_ROOT)/$(SITE_VER)"
	@echo "  make site-publish   atomically point $(SITE_ROOT)/install at it (old one -> previous)"
	@echo "  make site-rollback  atomically point install back at previous"
	@echo "  make site-status    where install and previous point, and the versions there"
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

# --- sources / check-pins: the driver submodules ------------------------------
# sources checks out every submodule in .gitmodules at the commit this recipe
# pins. NOT recursive, on purpose: nanosoc-ethernet-chiplet's own submodules
# are vendor and tapeout trees the recipe never reads, and some need
# credentials. It is also never run implicitly: `git submodule update` moves a
# submodule back to its pin, which would silently undo a checkout a driver
# developer made on purpose.
#
# check-pins asks the question a fresh clone will ask: is each pin on the
# branch .gitmodules names, on the remote, NOW? A pin that exists only in
# this checkout clones here and nowhere else. A pin held only by a side
# branch clones until that branch is deleted. It fetches every branch first
# (--prune), so a stale remote-tracking ref cannot vouch for a pin that a
# force-push has since removed. It also fails when a submodule's checkout is
# not its pin, because that is not what the recipe commit describes.
SUBMODULES := $(shell git config -f .gitmodules --get-regexp '^submodule\..*\.path$$' 2>/dev/null | awk '{print $$2}')

sources:
	@if [ -z "$(strip $(SUBMODULES))" ]; then \
		echo "sources: FAILED -- no submodules in .gitmodules" >&2; exit 1; \
	fi
	@if ! git -c submodule.recurse=false submodule update --init -- $(SUBMODULES); then \
		echo "sources: FAILED -- a submodule did not check out at its pin." >&2; \
		echo "        If git said the commit was not in what it fetched, that PIN WILL NOT" >&2; \
		echo "        CLONE: it was never pushed, or its branch was rewritten. Run" >&2; \
		echo "        'make check-pins' in a checkout that has the commit to see which." >&2; \
		exit 1; \
	fi
	@git submodule status -- $(SUBMODULES)

check-pins:
	@"$(CURDIR)/scripts/check-pins.sh"

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
			echo "          If that is a submodule path, run 'make sources' first." >&2; \
			echo "          Otherwise set $(d)_ROOT= to the checkout that owns it:" >&2; \
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

# NOTE the prefix check, which runs first. configure runs once per tree, and
# the prefix it was given is where the sub-make's `install` copies to. Without
# the check, `make install PREFIX=B` on a tree configured for A installed into
# A, then wrote B's manifest for whatever binary B already held -- and verify
# passed, because that binary had the driver names and the manifest now
# described it. The check reads the prefix from the generated Makefile, the
# same line the sub-make installs by. On a mismatch it also cleans: OpenOCD
# and jimtcl compile the prefix into the binary (BINDIR, PKGDATADIR, jim's
# library path), and reconfiguring alone recompiles none of it. The clean runs
# before the Makefile goes, so a configure that then fails leaves nothing
# built for the old prefix behind.
build: overlay
	@if [ -f $(BUILD_DIR)/Makefile ]; then \
		have="$$(sed -n 's/^prefix = //p' $(BUILD_DIR)/Makefile)"; \
		if [ "$$have" != "$(PREFIX)" ]; then \
			echo "build: tree is configured for prefix '$$have', not PREFIX=$(PREFIX)"; \
			echo "build:   cleaning and reconfiguring (the prefix is compiled into the binary)"; \
			$(MAKE) -C $(BUILD_DIR) clean >/dev/null || exit 1; \
			rm -f $(BUILD_DIR)/Makefile; \
		fi; \
	fi
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
		echo "build: $(BUILD_DIR)/Makefile already configured for $(PREFIX) -- leaving it"; \
		echo "       (CONFIGURE_FLAGS are NOT re-applied to a configured tree; distclean to change them)"; \
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

# The cmp is the second half of the prefix fix, and it does not depend on the
# first. Whatever the sub-make did, the manifest may only be written for a
# file that IS the binary just built. So it is checked against the build tree
# before anything is written, and the md5 is taken from the build tree. A
# bindir or exec_prefix in CONFIGURE_FLAGS sends the binary somewhere other
# than $(PREFIX)/bin with the prefix check satisfied; this refuses that too.
install: build
	$(MAKE) -C $(BUILD_DIR) install
	@if ! cmp -s "$(BUILD_DIR)/src/openocd" "$(PREFIX)/bin/openocd"; then \
		echo "install: FAILED -- $(PREFIX)/bin/openocd is not the binary just built" >&2; \
		echo "         ($(BUILD_DIR)/src/openocd). The sub-make installed somewhere else:" >&2; \
		echo "         check CONFIGURE_FLAGS for --bindir or --exec-prefix." >&2; \
		echo "         No manifest written: it would vouch for whatever file is there." >&2; \
		exit 1; \
	fi
	@mkdir -p "$(MANIFEST_DIR)"
	@{ echo "# soclabs-openocd build manifest -- written by 'make install'."; \
	   echo "# 'make verify' compares these against the live binary and the"; \
	   echo "# CURRENT driver sources. A mismatch means the binary is stale."; \
	   echo "binary_md5 $$(md5sum '$(BUILD_DIR)/src/openocd' | cut -d' ' -f1)"; \
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

# --- selftest: does THIS MAKEFILE install what it built? ----------------------
# test asks whether the drivers behave; selftest asks whether the recipe's own
# logic tells the truth: install puts the binary it built into PREFIX, and the
# site targets build a new version without touching the live one, flip the
# link by rename, roll back, and refuse what they should. It runs this
# Makefile against a fake upstream (a configure that writes an automake-style
# "prefix = " line, and an install rule that copies to $(bindir)), so it needs
# no network, no compiler and no HAPS-work. It then runs the legs on mutants
# of this Makefile, one guard removed each, and on the pre-fix Makefile. Every
# mutant must fail on its own leg. Exit status is non-zero if a leg fails or a
# mutant survives. About a minute; tests/selftest-install.sh --help lists the
# legs and mutants.
#
# The second half, selftest-pins.sh, does the same for sources and check-pins:
# fake driver remotes, fresh clones, a pin on a side branch, an unpushed pin,
# the side branch merged, a force-push that removes the pin, and a submodule
# checked out away from its pin. About 15 s.
selftest:
	@rc=0; \
	"$(CURDIR)/tests/selftest-install.sh" --makefile "$(CURDIR)/Makefile" || rc=1; \
	"$(CURDIR)/tests/selftest-pins.sh" --makefile "$(CURDIR)/Makefile" --script "$(CURDIR)/scripts/check-pins.sh" || rc=1; \
	exit $$rc

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

# --- site install: versioned prefixes behind one `install` symlink -----------
# The shared install every bench user gets with no variable set. The contract
# is ONE path: haps-openocd's LBIN_SITE is $(SITE_ROOT)/install/bin/openocd,
# and modulefile/1.0 looks in $(SITE_ROOT)/install. What that path resolves
# to changes only by renaming a symlink over it, which is atomic: a new
# session gets the old binary or the new one, never neither. A session
# already running keeps the inode it started with.
#
#   make install-site   build, install, verify and test into $(SITE_ROOT)/$(SITE_VER).
#                       A NEW prefix: nothing any user runs changes.
#   make site-publish   point install at $(SITE_VER); the old target becomes `previous`
#   make site-rollback  point install at `previous` (run it again to roll forward)
#   make site-status    where install and previous point, and every version there
#
# SITE_VER names the recipe commit, so install-site refuses a recipe tree with
# uncommitted changes (a submodule moved off its pin shows up there too), a
# driver pin that fails check-pins, and a driver source that is not a
# committed, unmodified file in a git checkout: any of those would ship to
# every user under a name that does not describe it. A version that is live is never rebuilt in
# place. The first publish has no `previous`; undoing it is removing the
# install link, which puts every user back on their own rung (haps-openocd
# falls through to the per-user build).
SITE_ROOT   ?= /research/CAD/soclabs-openocd
OPENOCD_VER ?= $(or $(shell sed -n 's/.*\[tag: v\([0-9][0-9.]*\)\].*/\1/p' $(PIN_FILE)),g$(shell printf %.7s '$(PINNED_SHA)'))
RECIPE_SHA  := $(shell git -C '$(CURDIR)' rev-parse --verify -q HEAD 2>/dev/null)
SITE_VER    ?= $(OPENOCD_VER)-soclabs-$(shell printf %.7s '$(RECIPE_SHA)')
SITE_PREFIX  = $(SITE_ROOT)/$(SITE_VER)
SITE_LINK    = $(SITE_ROOT)/install
SITE_PREV    = $(SITE_ROOT)/previous

.PHONY: install-site site-publish site-rollback site-status

install-site:
	@if [ -z "$(RECIPE_SHA)" ]; then \
		echo "install-site: FAILED -- $(CURDIR) is not a git checkout; $(SITE_VER) needs a commit to name." >&2; \
		exit 1; \
	fi
	@dirty=$$(git -C '$(CURDIR)' status --porcelain --untracked-files=no); \
	if [ -n "$$dirty" ]; then \
		echo "install-site: FAILED -- the recipe tree has uncommitted changes:" >&2; \
		echo "$$dirty" | sed 's/^/          /' >&2; \
		echo "        $(SITE_VER) would name $(RECIPE_SHA) and not describe what was built." >&2; \
		exit 1; \
	fi
	@if [ -n "$(strip $(SUBMODULES))" ]; then \
		$(MAKE) --no-print-directory check-pins || { \
			echo "install-site: FAILED -- a driver pin will not clone for everyone (above)." >&2; \
			echo "        A site version names a recipe commit; that commit must build anywhere." >&2; \
			exit 1; }; \
	fi
	@$(foreach d,$(DRIVERS), \
		src=$$(readlink -f "$($(d)_SRC)"); dir=$$(dirname "$$src"); \
		if ! git -C "$$dir" ls-files --error-unmatch -- "$$src" >/dev/null 2>&1; then \
			echo "install-site: FAILED -- $(d): '$($(d)_SRC)' is not a tracked file in a git checkout." >&2; \
			exit 1; \
		fi; \
		if ! git -C "$$dir" diff --quiet HEAD -- "$$src"; then \
			echo "install-site: FAILED -- $(d): '$$src' has uncommitted changes." >&2; \
			exit 1; \
		fi; \
		echo "install-site: $(d) = $$(git -C "$$dir" rev-parse --short=7 HEAD) of $$(git -C "$$dir" config --get remote.origin.url || echo '(no origin)'), md5 $$(md5sum "$$src" | cut -d' ' -f1)"; \
	)
	@if [ "$$(readlink '$(SITE_LINK)' 2>/dev/null)" = "$(SITE_VER)" ]; then \
		echo "install-site: FAILED -- $(SITE_VER) is LIVE: $(SITE_LINK) points at it." >&2; \
		echo "        A live prefix is never rebuilt in place. Commit the change; the new" >&2; \
		echo "        commit names a new prefix." >&2; \
		exit 1; \
	fi
	@mkdir -p '$(SITE_ROOT)'
	@echo "install-site: building $(SITE_VER) into $(SITE_PREFIX)"
	$(MAKE) --no-print-directory install PREFIX='$(SITE_PREFIX)'
	@chmod -R u=rwX,go=rX '$(SITE_PREFIX)'
	$(MAKE) --no-print-directory test BIN='$(SITE_PREFIX)/bin/openocd'
	@echo "install-site: $(SITE_PREFIX) is built, verified and tested. Nothing live has changed."
	@echo "install-site: publish it with:  make site-publish SITE_ROOT=$(SITE_ROOT)"

# Atomic: the new link is made beside the old one and renamed over it
# (mv -T is rename(2)). Not `ln -sfn`: EL8's coreutils 8.30 happens to rename
# a temporary link over too (strace shows it), but POSIX does not require
# that, and an ln that unlinks first leaves a window where a starting session
# finds no binary. The explicit rename does not depend on which ln is on PATH.
# The target is the bare version name, so the tree stays valid if SITE_ROOT
# is ever moved or mounted elsewhere.
site-publish:
	@if [ -e '$(SITE_LINK)' ] && [ ! -L '$(SITE_LINK)' ]; then \
		echo "site-publish: FAILED -- $(SITE_LINK) exists and is not a symlink. Move it aside by hand." >&2; \
		exit 1; \
	fi
	@$(MAKE) --no-print-directory verify-bin BIN='$(SITE_PREFIX)/bin/openocd'
	@cur=$$(readlink '$(SITE_LINK)' 2>/dev/null); \
	if [ "$$cur" = "$(SITE_VER)" ]; then \
		echo "site-publish: $(SITE_VER) is already live -- nothing to do"; exit 0; \
	fi; \
	tmp='$(SITE_ROOT)/.install.new.'$$$$; \
	if ! { ln -s '$(SITE_VER)' "$$tmp" && mv -T "$$tmp" '$(SITE_LINK)'; }; then \
		rm -f "$$tmp"; echo "site-publish: FAILED to flip $(SITE_LINK)" >&2; exit 1; \
	fi; \
	echo "site-publish: $(SITE_LINK) -> $(SITE_VER)   (was: $${cur:-nothing})"; \
	if [ -n "$$cur" ]; then \
		tmp='$(SITE_ROOT)/.previous.new.'$$$$; \
		ln -s "$$cur" "$$tmp" && mv -T "$$tmp" '$(SITE_PREV)' || { rm -f "$$tmp"; exit 1; }; \
		echo "site-publish: $(SITE_PREV) -> $$cur   (undo: make site-rollback SITE_ROOT=$(SITE_ROOT))"; \
	else \
		echo "site-publish: first publish, so no previous. Undo: rm $(SITE_LINK)"; \
	fi
	@$(MAKE) --no-print-directory verify-bin BIN='$(SITE_LINK)/bin/openocd'

# Rollback checks the target's integrity (its manifest describes its binary),
# not its freshness: verify-bin would call an older version STALE against this
# checkout's driver sources, which is the point of rolling back to it.
site-rollback:
	@if [ -e '$(SITE_LINK)' ] && [ ! -L '$(SITE_LINK)' ]; then \
		echo "site-rollback: FAILED -- $(SITE_LINK) exists and is not a symlink." >&2; exit 1; \
	fi
	@prev=$$(readlink '$(SITE_PREV)' 2>/dev/null); cur=$$(readlink '$(SITE_LINK)' 2>/dev/null); \
	if [ -z "$$prev" ]; then \
		echo "site-rollback: FAILED -- no $(SITE_PREV) link, so nothing to roll back to." >&2; \
		echo "        After a FIRST publish, undo is: rm $(SITE_LINK)" >&2; \
		exit 1; \
	fi; \
	case "$$prev" in /*) d=$$prev ;; *) d='$(SITE_ROOT)'/$$prev ;; esac; \
	if [ ! -x "$$d/bin/openocd" ]; then \
		echo "site-rollback: FAILED -- $$d/bin/openocd is not executable." >&2; exit 1; \
	fi; \
	if [ "$$(md5sum < "$$d/bin/openocd" | cut -d' ' -f1)" != "$$(awk '/^binary_md5/{print $$2}' "$$d/share/soclabs-openocd/build.manifest" 2>/dev/null)" ]; then \
		echo "site-rollback: FAILED -- $$prev's manifest does not describe its binary." >&2; exit 1; \
	fi; \
	tmp='$(SITE_ROOT)/.install.new.'$$$$; \
	if ! { ln -s "$$prev" "$$tmp" && mv -T "$$tmp" '$(SITE_LINK)'; }; then \
		rm -f "$$tmp"; echo "site-rollback: FAILED to flip $(SITE_LINK)" >&2; exit 1; \
	fi; \
	echo "site-rollback: $(SITE_LINK) -> $$prev   (was: $${cur:-nothing})"; \
	if [ -n "$$cur" ]; then \
		tmp='$(SITE_ROOT)/.previous.new.'$$$$; \
		ln -s "$$cur" "$$tmp" && mv -T "$$tmp" '$(SITE_PREV)' || { rm -f "$$tmp"; exit 1; }; \
		echo "site-rollback: $(SITE_PREV) -> $$cur   (run site-rollback again to roll forward)"; \
	fi

site-status:
	@echo "site-status: $(SITE_ROOT)"
	@echo "  install  -> $$(readlink '$(SITE_LINK)' 2>/dev/null || echo '(none)')"
	@echo "  previous -> $$(readlink '$(SITE_PREV)' 2>/dev/null || echo '(none)')"
	@echo "  this checkout builds: $(SITE_VER)"
	@for d in '$(SITE_ROOT)'/*/; do \
		d=$${d%/}; [ -d "$$d" ] && [ ! -L "$$d" ] || continue; \
		b="$$d/bin/openocd"; m="$$d/share/soclabs-openocd/build.manifest"; \
		if [ ! -x "$$b" ]; then s="NO BINARY"; \
		elif [ "$$(md5sum < "$$b" | cut -d' ' -f1)" = "$$(awk '/^binary_md5/{print $$2}' "$$m" 2>/dev/null)" ]; then s="manifest matches"; \
		else s="MANIFEST DOES NOT DESCRIBE THE BINARY"; fi; \
		echo "  version  $$(basename "$$d"): $$s"; \
	done

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
