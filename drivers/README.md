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
driver's `.c` file, at build time, from its `_ROOT` path straight into the
cloned upstream tree at `build/openocd-src/src/flash/nor/<driver>.c`. The
symlink is a build artifact under `build/`, never committed, gone on
`make distclean`.

## Registered drivers

| driver     | owning repo                | path inside it                    | root variable    |
|------------|-----------------------------|------------------------------------|-------------------|
| `ahb_qspi` | `nanosoc-multicore-system` | `ahb_qspi/sw/openocd/ahb_qspi.c`   | `ahb_qspi_ROOT`   |

Default `ahb_qspi_ROOT` is `../nanosoc-multicore-system/ahb_qspi`, i.e. this
recipe repo is assumed to be checked out as a sibling of the SoC Labs
workspace that contains the `nanosoc-multicore-system` submodule. That is
a guess, not a discovered convention -- override it for your layout:

    make overlay ahb_qspi_ROOT=/path/to/nanosoc-multicore-system/ahb_qspi

## Adding a second driver

Two-line change in `../Makefile`'s driver registry block:

    DRIVERS         += foo
    foo_ROOT        ?= ../path/to/foo-owning-repo
    foo_SRC         := $(foo_ROOT)/sw/openocd/foo.c

(the `foo_SRC` line is templated from the pattern above -- if the owning
repo doesn't use `sw/openocd/<name>.c`, that's the one line to change).

Then:
1. Add a row to the table above.
2. Drop `../patches/000N-register-foo.patch` with foo's own three-hunk
   insertion into `Makefile.am` / `driver.h` / `drivers.c`, following
   `0001-register-ahb_qspi.patch`'s shape -- one line in each of the three
   alphabetically-sorted lists, at foo's alphabetical position (which may
   not be next to `aducm360`; check where "foo" actually sorts).
3. `make patch overlay` picks it up automatically -- the Makefile applies
   every `patches/*.patch` and overlays every name in `$(DRIVERS)`.
