# soclabs-openocd

A build recipe for upstream OpenOCD with SoC Labs's own NOR flash drivers
registered into it. It is not, itself, an OpenOCD distribution: it's the
three files (a patch, a pin, a Makefile) that turn a plain upstream clone
into one.

## This is NOT a fork

OpenOCD has no runtime driver-plugin mechanism -- a driver has to be
compiled into the binary, there's no `.so` you can drop in later. That
sounds like it forces a fork, but it doesn't: every line the patches add
is a **registration entry**, each into an already alphabetically-sorted
list. Not one line of upstream logic is altered. For the flash driver on
master, that is three one-line insertions, each next to the existing
`aducm360` entry:

| file | inserted line |
|---|---|
| `src/flash/nor/Makefile.am` | `%D%/ahb_qspi.c \` |
| `src/flash/nor/driver.h` | `extern const struct flash_driver ahb_qspi_flash;` |
| `src/flash/nor/drivers.c` | `&ahb_qspi_flash,` |

That's `patches/0001-register-ahb_qspi.patch` in full. At the pin it is two
files rather than three, because v0.12.0 keeps the `extern` in `drivers.c`
instead of `driver.h`.

Registering an **adapter** costs more than registering a flash driver, so with
`hostio4` on as well the real total is larger. Measured in the patched tree,
`git diff --stat` against the pinned commit after `make patch`:

    configure.ac                 | 11 +++++++++++
    src/flash/nor/Makefile.am    |  1 +
    src/flash/nor/drivers.c      |  2 ++
    src/jtag/drivers/Makefile.am |  3 +++
    src/jtag/interfaces.c        |  6 ++++++
    5 files changed, 23 insertions(+)

**23 insertions, 0 deletions, across 5 files, all of them registration.** No
upstream implementation file is edited, no upstream commit is reverted,
reordered or reworded, and the driver sources themselves are symlinked in by
`make overlay` rather than copied -- see `drivers/README.md`.

The design intent: **drivers live in the repo that owns the IP** (e.g.
`ahb_qspi.c` lives in `nanosoc-multicore-system`, next to the RTL it
talks to) and **this repo owns only the recipe** that registers whichever
drivers it's told about into a real OpenOCD checkout. See
`drivers/README.md` for how a driver's source is located, and how to
register a second one.

## What you will NOT get from a stock distro OpenOCD

apt/yum/brew OpenOCD, and a plain `git clone` of upstream, do not and
will not carry the `ahb_qspi` driver -- it exists nowhere upstream. If
`openocd -c "flash list"` (or `strings $(which openocd) | grep ahb_qspi`)
comes up empty, that is expected of any binary this recipe didn't build.
Only a binary built via `make build` in this repo (or an install produced
from one) carries it.

## Status: `ahb_qspi` PROVEN ON SILICON; `hostio4` built and shipped, never run

Updated 2026-09-22.

| | |
|---|---|
| Builds against **v0.12.0** (`9ea7f3d`) -- **this is the pin**, see `openocd.pin` | yes, 0 warnings at the project's own `-Werror` |
| Also builds against OpenOCD **master** (`c2fc07b`) -- *not* the pin, separate patch | yes, 0 warnings |
| Drivers registered in the binary | yes -- `strings openocd` contains `ahb_qspi` **and** `hostio4` |
| `flash bank ... ahb_qspi` accepted at runtime | yes (fails on a missing target, NOT "unknown flash driver") |
| Installed on the bench | yes -- `/opt/soclabs-openocd/0.12.0-soclabs/bin/openocd` |
| Gate run against that binary, on that host | yes -- `make verify HOST=haps-dev DRIVERS="ahb_qspi hostio4"` rc=0, re-run 2026-09-22 |
| **Has `ahb_qspi` erased or programmed a real part?** | **YES -- 2026-09-18, HAPS-SX. Details below.** |
| **Has `hostio4` ever run against hardware?** | **NO. Compiled in and listed; no board has ever answered it.** |

The pin is v0.12.0 deliberately: haps-dev runs 0.12.0, and building master there
would put a different OpenOCD on the bench than every existing config and script
was validated against, for no gain. `openocd.pin` is the authority on this and
carries the full reasoning; the master patch exists only so the same sources
stay buildable if the pin ever moves.

### `ahb_qspi` on silicon, 2026-09-18

Board `01_pl` on the HAPS-SX bench, driven over SWD through a `mem_ap` target --
no CPU halted, no CPU examined. `flash probe` identified the part from its JEDEC
ID against OpenOCD's shared `flash_devices[]`: a Winbond W25Q32FW (`0xef6016`),
4096 KiB, cache managed. Then `flash info`, `flash erase_sector 0 63 63`, two
`flash fillw`s placed either side of a 256-byte page boundary (`0xdeadbeef` at
`0x243f0000`, `0xcafef00d` at `0x243f0100`), and a 512-byte `flash read_bank`
that came back byte-exact with one distinct pattern per page. Addressing and
page-boundary handling are therefore right, not merely un-contradicted. The BOOT
header at sector 0 was never touched.

It did not work first time, and the reason is worth carrying:

> **`.read` was left NULL on purpose, and that segfaulted OpenOCD on first
> contact.** `segfault at 0 ip 0000000000000000` is a call through a NULL
> function pointer, not a data dereference. `flash_driver_read()`
> (`core.c:109`) calls `bank->driver->read()` with no null check and no
> fallback -- unlike `flash_driver_verify()` (`core.c:132`), which guards with
> a ternary. So `.verify` may be NULL and `.read` may not. Everything reading
> through the flash API hit it (`flash fillw`'s readback, `flash read_bank`,
> `flash verify_image`); plain `mdw` did not, because a target read never
> enters the flash driver, which is why the read path looked healthy right up
> until it wasn't. The fix is one line -- `.read = default_flash_read` -- and
> it is in the driver (`ahb_qspi` `c97deb2`). All 58 other NOR drivers in-tree
> assign it.

### `hostio4`: on the bench binary, not on a board

`hostio4` is an **adapter** driver -- a software MEM-AP over the HOSTIO4/ADP
link -- not a flash driver, so it overlays into `src/jtag/drivers` and its
registration patch reaches `configure.ac` and `src/jtag/interfaces.c` as well as
a `Makefile.am`.

Its registry lines in the Makefile are **enabled**, and have been since
2026-09-18 (`306e146`). They were commented out before that for one reason,
since removed: the canonical `hostio4.c` used master's `.transport_ids`
spelling, which v0.12.0's `struct adapter_driver` does not have, so a default
`make build` would have failed to compile. `patches/hostio4-single-source-guard.patch`
put an `#ifdef TRANSPORT_DAPDIRECT_SWD` around it so one source builds at both
revisions; it was applied upstream (nanosoc-ethernet-chiplet `1c805fb`), which
is what let the registry turn on, and why no `hostio4_SRC=` override is needed.

The bench binary carries both drivers, provable on demand:

    make verify HOST=haps-dev DRIVERS="ahb_qspi hostio4"   -> rc=0

**That is a claim about the binary and nothing else.** `adapter list` naming
`hostio4` says the driver linked and registered. No board has ever answered it,
there is no capture from one, and the first-contact procedure has not been run.
Do not read the row above as hardware evidence; only the `ahb_qspi` row is.

## The four build steps

```
make fetch     # clone upstream, check out the commit openocd.pin names
make patch     # apply patches/*.patch (idempotent: skips if already applied)
make overlay   # symlink each driver's .c in from the repo that owns it
make build     # ./bootstrap (if needed) && ./configure && make
```

Then `make verify` to check the resulting binary actually carries the
registered driver(s), and `make clean` / `make distclean` to tear down.
`make help` lists every target and every override variable. None of
these steps require or perform a commit, push, or any write outside this
repo's own `build/` and `install/` directories (both gitignored /
created fresh, never tracked).

Adapter selection (which JTAG/SWD probe OpenOCD talks through -- e.g.
CMSIS-DAP for a DAPLink probe) is intentionally left to `CONFIGURE_FLAGS`
rather than hardcoded: that decision belongs to whoever plans the actual
bench/board deployment, not to this recipe.

## The build gate: what stops a driverless binary shipping

`verify` is a GATE, not a report. `build` and `install` both fail on it.

It exists because of the specific way this breaks. Someone rebuilds without the
overlay step, gets a perfectly good OpenOCD that does SWD, attaches, halts and
single-steps exactly as expected -- and discovers months later, when
`flash write_image` says the driver is unknown, that the flash half was never
in the binary. Nothing before that moment distinguishes the two builds:

    $ openocd --version
    Open On-Chip Debugger 0.12.0-01004-g9ea7f3d64-dirty

is what BOTH answer, because upstream's `guess-rev.sh` derives that string from
the pinned upstream commit and knows nothing about an overlaid driver. So the
version string cannot be the check, and a line in a document is not a check at
all. The binary itself is asked:

    make verify                  # the binary in the build tree
    make verify BIN=/some/openocd
    make verify HOST=haps-dev    # the binary the BENCH will execute

The last form is the one that matters. The bench does not run OpenOCD on your
workstation -- `haps-openocd` ssh's to `$HAPS_OPENOCD_SSH` and execs
`$HAPS_OPENOCD_BIN` there -- so a local pass says nothing about what will
actually run. `verify HOST=` asserts every registered driver over ssh, and
treats "cannot reach the host" as UNKNOWN (failure), never as a pass.

The gate has been shown to discriminate, which is the only thing that makes a
check worth having. On 2026-09-17, against the bench binary of the day:

    make verify HOST=haps-dev                            -> rc=0, ahb_qspi found
    make verify HOST=haps-dev DRIVERS="ahb_qspi hostio4" -> rc=2, hostio4 absent

Same host, same file, one driver present and one genuinely not: it separated
them. It then caught a real defect rather than a hypothetical one. When
`hostio4` was enabled in the registry, the `PATCHES +=` line was left commented
out -- and that is a *silent* failure, not a loud one: the overlay still linked
`hostio4.c` in and `make build` still succeeded, but `configure.ac` and
`interfaces.c` were unpatched, so the driver was never compiled or registered.
Only the gate said so: `verify: FAIL -- 'hostio4' NOT in
build/openocd-src/src/openocd` (`306e146`).

Since 2026-09-18 both drivers are in the bench binary, so that first pair no
longer separates anything -- re-run 2026-09-22:

    make verify HOST=haps-dev DRIVERS="ahb_qspi hostio4" -> rc=0, both embedded
    make verify HOST=haps-dev DRIVERS="not_a_driver"     -> rc=2, GATE FAILED

The second line is there so the check can still be seen failing. A check that
cannot fail proves nothing.

## Deploying to the bench

    make install-remote HOST=haps-dev

This does NOT copy a binary. haps-dev has its own glibc, libusb and libftdi,
and a binary linked on your workstation is not guaranteed to start there -- a
binary that will not start is a worse failure than one missing a driver. So it
drives this same recipe over ssh and gates on the installed result.

It DOES copy the driver sources, every time, from whichever checkout owns them,
into `$(REMOTE_SRC)` on the host, and md5-checks each one after transfer.
Before this existed the bench held a detached plain copy of `ahb_qspi.c` with
no provenance: byte-identical on the day it was made, and free to drift
silently from then on. Re-staging on every install makes the host copy a cache
of the owning repo rather than a second source of truth. A consequence worth
knowing: the host needs no checkout of the superproject the drivers live in.

## Layout

```
soclabs-openocd/
  README.md              this file
  openocd.pin             upstream URL + pinned commit SHA + why that pin
  patches/
    0001-register-ahb_qspi-v0.12.0.patch   registers ahb_qspi at the PIN
    0001-register-ahb_qspi.patch           the same, against master
    0002-register-hostio4-v0.12.0.patch    registers the hostio4 ADAPTER
    hostio4-single-source-guard.patch      NOT in PATCHES: belongs upstream,
                                            already applied there; kept as the
                                            record of that change
  drivers/
    README.md            where each driver's .c actually lives, and how
                          to register a second one
  Makefile                fetch / patch / overlay / build / verify / clean
  modulefile/
    1.0                   Environment Modules file: prepends the built
                          bin/ to PATH for users who load it, touches
                          nothing for users who don't
```

`build/` and `install/` are created by the Makefile and are not part of
this layout as shipped -- they're generated, local, and disposable
(`make distclean` removes both).

## Using the driver (the part you need if you did not build it)

A driver compiled into a binary is useless until OpenOCD is (a) *that* binary and
(b) told there is a flash bank. Two steps, neither of which changes anything
shared.

### 1. Run the right OpenOCD

On the HAPS-SX bench, `haps-openocd` honours an environment variable -- no edit
to the tool, the modulefile, or any shared config:

```sh
export HAPS_OPENOCD_BIN=/opt/soclabs-openocd/0.12.0-soclabs/bin/openocd
haps-openocd holders          # is the probe free? check BEFORE taking it
haps-openocd up nanosoc
```

`haps-openocd:116` reads `${HAPS_OPENOCD_BIN:-openocd}` and execs it verbatim on
haps-dev, so an absolute path bypasses PATH entirely. It is never written to the
shared or per-user conf files, so nobody can set it for everyone by accident.
The sibling knob `HAPS_HWSERVER_BIN` works the same way and is documented in the
`haps-dev` modulefile.

Off the bench, just put the built `bin/` first on PATH, or invoke it by path.

> **If you find `/opt/haps-openocd-ahb_qspi` on the bench, do not delete it
> wholesale.** It is two different things sharing a parent. The install beside
> it (`0.12.0-ahb_qspi/`) is dead and removable; `src/` is the LIVE build tree
> this recipe drives, and removing it destroys the build. The installed binary
> does not depend on the old prefix either way -- its data path is self-relative
> (`bin/../share/openocd`), so the old-prefix strings you will find in it with
> `strings` are build-tree artefacts, not a runtime dependency.

### 2. Declare the flash bank

```tcl
flash bank <name> ahb_qspi <xip_base> 0 0 0 <target> [ctrl_base] [no_cache]
```

For the nanoSoC multicore SoC, added to `cfg/nanosoc.cfg` after the `mem_ap`
target:

```tcl
flash bank nanosoc.flash ahb_qspi 0x24000000 0 0 0 nanosoc.mem 0x21000000
```

- `<xip_base>` is the **XiP window**, not the controller. Reads go through it:
  the driver sets `.read = default_flash_read`, a plain `target_read_buffer()`
  from `bank->base`, which is also what gdb's memory map and `flash verify_image`
  use. It must be *assigned*, not left NULL -- see the silicon section above for
  what NULL does.
- `[ctrl_base]` defaults to `0x21000000`. The CG092 cache is assumed at
  `ctrl_base + 0x1000`; pass `no_cache` for an integration without one.
- `<target>` can be a `mem_ap` target -- no CPU needs to be halted or examined.

### 3. Use it

```
flash probe 0                             # expect the JEDEC-matched part and size
flash info 0
flash read_bank 0 /tmp/pre.bin 0 4096     # BACK UP before anything destructive
flash erase_sector 0 0 0
flash read_bank 0 /tmp/erased.bin 0 4096  # expect 0xFF
flash write_image /path/to/image.bin 0x24000000
```

`program`, `flash write_image` and `gdb load` to a flash address all work only
because the bank exists -- see "What you will NOT get from a stock distro
OpenOCD" above.

### Things that will surprise you

- **The bank reports 4 MB even on a 32 MB part.** `SPI_ADDR` is 22 bits, so the
  controller cannot address beyond 4 MB on any platform. The driver clamps and
  warns rather than offering addresses the hardware cannot produce. A PYNQ-Z2's
  Pmod SF3 is 32 MB with 28 MB unreachable.
- **Three platforms, three different flash parts.** PYNQ-Z2 is a Micron
  N25Q256A (`0x20BA19`), HAPS-SX a Winbond W25Q32FW (`0xEF6016`), and the
  SST26VF064B in the simulation VIP is fitted on none of them. `probe` keys on
  the JEDEC ID against OpenOCD's shared `flash_devices[]` table, so it sorts
  itself out -- but do not assume the geometry from the testbench.
- **Keep writes to 16-byte multiples for now.** The controller's WDATA window is
  16 bytes and only lengths in {1,2,3,4,8,12,16} are verified; the driver's
  header documents this as a known gap on the transmit path.
- **`flash probe` at `CLK_DIV=1` can garble RDID** (measured on silicon). The
  driver raises the divider for the ID read and restores it, so this should not
  bite -- but it is why the probe is slower than you might expect.
- **If probe returns `0x000000`/`0xffffff`**, the part may be in deep power-down,
  which only a `0xAB` clears. The driver does NOT issue it; a board was once
  declared dead for five runs over this.
