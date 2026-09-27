# drivers/

This directory holds no driver source of its own. Each subdirectory is a
**git submodule**: the repository that owns a driver, pinned at the commit this
recipe builds. Nothing here is a copy.

## Why submodules, and not copies or sibling checkouts

The IP repo that owns a controller is the single source of truth for the
OpenOCD driver that talks to it. A vendored copy of `ahb_qspi.c` here would
drift from it silently.

Until 2026-09-27 the Makefile read each driver from a sibling checkout
(`../ahb_qspi-probe-xip`, `../nanosoc-ethernet-chiplet/...`). That built
whatever those trees held, uncommitted edits included. The manifest recorded
only an md5, so no one could say which commit a binary came from. The ahb_qspi
sibling was a clone whose `origin` was a path inside the chiplet's `.git`, so
it existed only on a machine that already had the chiplet. A submodule fixes
all three: the recipe commit names the driver commit, and a fresh clone
anywhere gets the same bytes.

`make overlay` still does not copy anything. It symlinks each driver's `.c`
from its `_ROOT` into the upstream tree at
`build/openocd-src/$(<driver>_DEST)/<driver>.c`. The destination is per-driver,
and there is no default; see "Adding a driver" below.

## Registered drivers

| driver | class | submodule (owning repo) | branch that must hold the pin | pin | path inside it | `_DEST` |
|---|---|---|---|---|---|---|
| `ahb_qspi` | flash | `drivers/ahb_qspi` (`git.soton.ac.uk/soclabs/ahb_qspi`) | `master` | `1e5117e` | `sw/openocd/ahb_qspi.c` | `src/flash/nor` |
| `hostio4` | adapter | `drivers/nanosoc-ethernet-chiplet` (`github.com/SoC-Labs/NanoSoC-Ethernet-Chiplet`) | `feat/padring-boundary-scan` | `057d317` | `scripts/rig/eth_chiplet/openocd_hostio4/hostio4.c` | `src/jtag/drivers` |

**`ahb_qspi` pin, 27 Sep.** `1e5117e` is the tip of ahb_qspi's
`fix/probe-restores-xip`: a failed `flash probe` puts XiP back as it found it.
Decision D5 fast-forwards ahb_qspi `master` to it. **Until that push lands,
`make check-pins` fails on this submodule, by design**: the pin clones today
only because the fix branch holds it. The eth chiplet's own ahb_qspi pin
(`07b40f5`, frozen for tapeout through `nanosoc-multicore-system`) is older.
It does not move, and this recipe no longer reads it.

**`hostio4` home.** It lives in the chiplet repo for now (decision D6). The
submodule is the chiplet superproject only: about 17 MiB checked out, and a
37 MiB pack. `make sources` never recurses into the chiplet's own submodules,
which are vendor and tapeout trees and need credentials. **Do not clone this
recipe with `--recurse-submodules`.**

## Working with them

    make sources       # git submodule update --init, NOT recursive: each at its pin
    make check-pins    # each pin is on its branch, on the remote, now; and checked out

`make sources` is never run for you. `git submodule update` moves a submodule
back to its pin, which would silently undo a checkout you made on purpose.

To build a driver you are editing, point its root at your working checkout.
The submodule stays where it is:

    make build hostio4_ROOT=../nanosoc-ethernet-chiplet/scripts/rig/eth_chiplet/openocd_hostio4
    make build ahb_qspi_ROOT=../ahb_qspi

`make install-site` refuses to do that. The site version names a recipe
commit, so the recipe tree must be clean, every pin must pass `check-pins`,
and every driver source must be a committed, unmodified file.

To move a pin, commit in the driver's repo and push it to the branch in the
table. Then run `git -C drivers/<sub> fetch && git -C drivers/<sub> checkout
<sha>` and commit the gitlink here. Run `make check-pins` before you push the
recipe. **A pin that exists only in your checkout clones for nobody else.**

## Adding a driver

**Four lines**, in `../Makefile`'s registry block:

    DRIVERS      += foo
    foo_ROOT     ?= drivers/<submodule>          # git submodule add -b <branch> <url> drivers/<submodule>
    foo_SRC      := $(foo_ROOT)/sw/openocd/foo.c
    foo_DEST     := src/flash/nor        # or src/jtag/drivers for an adapter

**`_DEST` is not optional and has no default.** The Makefile refuses a driver
without one, deliberately: a wrong default puts an adapter in the flash
directory, where it is silently not compiled and the build still succeeds.

You also need a registration patch in `../patches/`, and **its shape depends on
the class**. A flash driver touches `src/flash/nor/Makefile.am` and
`drivers.c`. An **adapter** additionally touches `configure.ac`,
`src/jtag/drivers/Makefile.am` and `src/jtag/interfaces.c` — five files, not
three. The two are not interchangeable, and neither are the patches for master
versus the v0.12.0 pin; see `../openocd.pin`.

**Then prove it is actually in the binary:** `make verify` is a gate, not a
courtesy, because a driver that failed to register still builds and still runs.

Then:
1. Add a row to the table above.
2. Drop `../patches/000N-register-foo.patch` with foo's own three-hunk
   insertion into `Makefile.am` / `driver.h` / `drivers.c`, following
   `0001-register-ahb_qspi.patch`'s shape -- one line in each of the three
   alphabetically-sorted lists, at foo's alphabetical position (which may
   not be next to `aducm360`; check where "foo" actually sorts).
3. `make patch overlay` picks it up automatically -- the Makefile applies
   every `patches/*.patch` and overlays every name in `$(DRIVERS)`.
