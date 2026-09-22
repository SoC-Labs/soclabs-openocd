# drivers/

This directory is deliberately empty of driver source. It exists so the
tree has a place to document, per driver, where its `.c` file actually
lives -- not to hold a copy of it.

## Why no copies live here

The IP repo that owns a controller (e.g. `nanosoc-multicore-system` for
`ahb_qspi`) is the single source of truth for the OpenOCD driver that talks
to it. Vendoring a second copy of `ahb_qspi.c` into this recipe repo would
create exactly the drift this design avoids: a bugfix landing in the IP
repo's `sw/openocd/ahb_qspi.c` and never reaching the copy that actually
gets built, with no diff anywhere to notice.

Instead, `make overlay` (see `../Makefile`) symlinks each registered
driver's `.c` file, at build time, from its `_ROOT` path into the cloned
upstream tree at `build/openocd-src/$(<driver>_DEST)/<driver>.c`. **The
destination is per-driver and there is no default** — see "Adding a driver"
below. The symlink is a build artifact under `build/`, never committed, gone on
`make distclean`.

## Registered drivers

| driver     | class   | owning repo                  | path inside it                   | `_DEST`               |
|------------|---------|------------------------------|----------------------------------|-----------------------|
| `ahb_qspi` | flash   | `nanosoc-multicore-system`   | `ahb_qspi/sw/openocd/ahb_qspi.c` | `src/flash/nor`       |
| `hostio4`  | adapter | `nanosoc-ethernet-chiplet`   | `scripts/rig/eth_chiplet/openocd_hostio4/hostio4.c` | `src/jtag/drivers` |

### The default roots, and the trap in the obvious one

Read the defaults from `../Makefile`, never from here — but the one that bites
is worth stating twice:

    ahb_qspi_ROOT ?= ../nanosoc-ethernet-chiplet/nanosoc-multicore-system/ahb_qspi
    hostio4_ROOT  ?= ../nanosoc-ethernet-chiplet/scripts/rig/eth_chiplet/openocd_hostio4

**`../nanosoc-multicore-system` is NOT the right root, even though it exists.**
There is a standalone checkout at that path, on a different branch, which does
**not** carry `sw/openocd/`. Pointing at it resolves cleanly and then fails to
find the driver — which is why the Makefile spells the full path and carries a
note saying so. An earlier revision of this file documented that wrong path as
the default; if you followed it, that is why your build had no driver in it.

Override for your own layout:

    make overlay ahb_qspi_ROOT=/path/to/the/one/with/sw/openocd

## Adding a driver

**Four lines**, in `../Makefile`'s registry block:

    DRIVERS      += foo
    foo_ROOT     ?= ../path/to/foo-owning-repo
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
