#!/usr/bin/env bash
# selftest-install.sh -- does `make install PREFIX=X` put the binary it just
# built into X, and never write a manifest that vouches for a file it did not
# install?
#
#   tests/selftest-install.sh [--makefile FILE] [--no-mutants] [--keep]
#
# It runs the recipe's own fetch/patch/overlay/build/install/verify targets
# against a FAKE upstream: a git repo whose configure writes an automake-style
# Makefile ("prefix = ..." and a bindir, the two lines the real one installs
# by), and whose "binary" is a script carrying each overlaid driver's name and
# the bindir it was built for, as the real openocd carries BINDIR. So no
# network, no compiler, a few seconds.
#
# Legs, each against a fresh recipe copy with FILE as its Makefile:
#   L1  install PREFIX=A into an empty A: A/bin/openocd is the built binary,
#       built for A, and the manifest describes it.
#   L2  THE S4 CASE. B already holds an older binary that carries both driver
#       names. install PREFIX=B on the tree configured for A must install the
#       new build into B, built for B. It must never leave a manifest that
#       vouches for the seeded file. (The pre-fix Makefile installed into A,
#       hashed B's old binary, and verify passed.)
#   L3  install PREFIX=B/ (trailing slash) must not reconfigure: configure
#       strips the slash, so an unnormalised compare would clean and rebuild
#       on every run.
#   L4  install PREFIX=C CONFIGURE_FLAGS=--bindir=D, with C seeded: the binary
#       lands in D, so install must FAIL and write NO manifest into C at all.
#       This is the cmp guard's own leg: the prefix check passes here, and
#       without the cmp a manifest lands in C describing a binary that is in D.
#
# With no --no-mutants it then runs the same legs on mutants of FILE, each
# with one guard removed, and on the pre-fix Makefile (git object PRE_FIX)
# when this checkout has it. Each mutant must fail, on the leg named for it:
#   M-reconf  prefix check disabled      -> L2
#   M-noclean reconfigure without clean  -> L2 (the binary keeps the old
#             prefix: on the real tree, 2 of its 3 prefix strings stayed)
#   M-cmp     cmp before manifest gone   -> L4
#   M-slash   PREFIX not normalised      -> L3
#   pre-fix   the Makefile before S4     -> L2
# A mutant that does not change FILE, or does not parse, counts as a failure:
# it would prove nothing.
#
# Exit status: legs failed on FILE, plus mutants that survived or were broken.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MK=$HERE/../Makefile
MUTANTS=1
KEEP=0
PRE_FIX=b0d6948   # fix/driver-review-2026-09-24: the last Makefile without the S4 fix
while [ $# -gt 0 ]; do
  case "$1" in
    --makefile) MK=$2; shift 2 ;;
    --no-mutants) MUTANTS=0; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: $0 [--makefile FILE] [--no-mutants] [--keep]" >&2; exit 2 ;;
  esac
done
[ -f "$MK" ] || { echo "selftest: no Makefile at $MK" >&2; exit 2; }
MK=$(cd "$(dirname "$MK")" && pwd)/$(basename "$MK")

W=$(mktemp -d "${TMPDIR:-/tmp}/oocd-selftest.XXXXXX")
cleanup() { if [ "$KEEP" = 1 ] || [ "${BAD:-0}" -ne 0 ]; then echo "selftest: evidence kept in $W"; else rm -rf "$W"; fi; }
trap cleanup EXIT
G=(git -c user.name=selftest -c user.email=selftest@invalid -c core.hooksPath=/dev/null -c init.defaultBranch=main)

# --- fixture: fake upstream, fake drivers, fake pin and patch ---------------
U=$W/upstream
mkdir -p "$U/src/flash/nor" "$U/src/jtag/drivers"
touch "$U/src/flash/nor/.keep" "$U/src/jtag/drivers/.keep"
echo upstream > "$U/drivers.list"
printf '#!/bin/sh\nexit 0\n' > "$U/bootstrap"
cat > "$U/configure" <<'CONF'
#!/bin/sh
# Fake autoconf configure. Like the real one it honours --prefix and --bindir,
# strips trailing slashes, and writes the Makefile the install goes by.
prefix=/usr/local; bindir=
for a in "$@"; do
  case $a in
    --prefix=*) prefix=${a#--prefix=} ;;
    --bindir=*) bindir=${a#--bindir=} ;;
  esac
done
prefix=$(printf '%s' "$prefix" | sed 's:/*$::')
if [ -n "$bindir" ]; then bindir=$(printf '%s' "$bindir" | sed 's:/*$::'); else bindir='${exec_prefix}/bin'; fi
echo "configure $*" >> configure.log
cat > Makefile <<'EOF'
prefix = @PREFIX@
exec_prefix = ${prefix}
bindir = @BINDIR@
DRV = $(sort $(wildcard src/flash/nor/*.c src/jtag/drivers/*.c))
all: src/openocd
src/openocd: $(DRV)
	@{ echo '#!/bin/sh'; echo 'echo "Open On-Chip Debugger 0.12.0-selftest"'; echo 'exit 0'; \
	   for f in $(DRV); do basename $$f .c; done; echo "BINDIR=$(bindir)"; } > $@; chmod +x $@
install: all
	@mkdir -p $(bindir) $(prefix)/share/openocd/scripts
	@cp src/openocd $(bindir)/openocd
clean:
	@rm -f src/openocd
EOF
sed -i "s|@PREFIX@|$prefix|; s|@BINDIR@|$bindir|" Makefile
CONF
chmod +x "$U/bootstrap" "$U/configure"
( cd "$U" && "${G[@]}" init -q && "${G[@]}" add -A && "${G[@]}" commit -qm 'fake upstream' ) || { echo "selftest: cannot build the fake upstream" >&2; exit 2; }
echo ahb_qspi >> "$U/drivers.list"
( cd "$U" && git diff > "$W/fake.patch" && git checkout -q drivers.list )
printf 'sha: %s\n' "$(git -C "$U" rev-parse HEAD)" > "$W/fake.pin"
mkdir -p "$W/drv/ahb_qspi/sw/openocd" "$W/drv/hostio4"
echo '/* fake ahb_qspi */' > "$W/drv/ahb_qspi/sw/openocd/ahb_qspi.c"
echo '/* fake hostio4 */' > "$W/drv/hostio4/hostio4.c"

md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
mf_md5() { awk '/^binary_md5/{print $2}' "$1/share/soclabs-openocd/build.manifest" 2>/dev/null; }
seed() {  # an older build: runs, and carries both driver names, so a name check passes
  mkdir -p "$1/bin"
  printf '#!/bin/sh\nexit 0\nahb_qspi\nhostio4\nseed: an older build, not this one\n' > "$1/bin/openocd"
  chmod +x "$1/bin/openocd"
}

# rmake: the Makefile under test, in recipe copy $R, with the fixture wired in.
# The caller's make/env settings are dropped so none of them leak into a leg.
rmake() {
  env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u CONFIGURE_FLAGS -u PREFIX -u BIN -u HOST \
    make -C "$R" --no-print-directory PIN_FILE=fake.pin OPENOCD_REMOTE="$U" \
      PATCHES=patches/fake.patch ahb_qspi_ROOT="$W/drv/ahb_qspi" hostio4_ROOT="$W/drv/hostio4" \
      CONFIGURE_FLAGS= HOST= "$@" >> "$R/make.log" 2>&1
}

# run_legs NAME MAKEFILE: sets FAILED to the legs that failed ("" = all passed).
run_legs() {
  local name=$1 mf=$2 rc sm n0 n1 why
  R=$W/run-$name; FAILED=
  mkdir -p "$R/patches"
  cp "$mf" "$R/Makefile"; cp "$W/fake.pin" "$R/"; cp "$W/fake.patch" "$R/patches/"
  local A=$R/pfx/A B=$R/pfx/B C=$R/pfx/C D=$R/pfx/elsewhere/bin
  local BLT=$R/build/openocd-src/src/openocd
  leg() { local id=$1; shift; if [ -z "$*" ]; then echo "  PASS $id"; else echo "  FAIL $id: $*"; FAILED="$FAILED $id"; fi; }

  echo "== $name"
  # L1
  echo "-- L1" >> "$R/make.log"; rmake install PREFIX="$A"; rc=$?; why=
  if [ $rc -ne 0 ]; then why="install rc $rc"
  elif ! cmp -s "$BLT" "$A/bin/openocd"; then why="A/bin/openocd is not the built binary"
  elif ! grep -qx "BINDIR=$A/bin" "$BLT"; then why="binary not built for A"
  elif [ "$(mf_md5 "$A")" != "$(md5 "$BLT")" ]; then why="manifest does not describe the binary"
  fi
  leg L1 "$why"

  # L2
  seed "$B"; sm=$(md5 "$B/bin/openocd")
  echo "-- L2" >> "$R/make.log"; rmake install PREFIX="$B"; rc=$?; why=
  if [ -n "$sm" ] && [ "$(mf_md5 "$B")" = "$sm" ]; then
    why="a manifest in B vouches for the SEEDED binary (install rc $rc)"
    rmake verify BIN="$B/bin/openocd" && why="$why, and verify PASSES on it"
  elif [ $rc -ne 0 ]; then why="install rc $rc: did not reconfigure and install into B"
  elif ! cmp -s "$BLT" "$B/bin/openocd"; then why="rc 0 but B/bin/openocd is not the built binary"
  elif ! grep -qx "BINDIR=$B/bin" "$BLT"; then why="the binary in B was built for another prefix"
  elif ! rmake verify BIN="$B/bin/openocd"; then why="verify fails on B"
  fi
  leg L2 "$why"

  # L3
  n0=$(wc -l < "$R/build/openocd-src/configure.log" 2>/dev/null || echo 0)
  echo "-- L3" >> "$R/make.log"; rmake install PREFIX="$B/"; rc=$?; why=
  n1=$(wc -l < "$R/build/openocd-src/configure.log" 2>/dev/null || echo 0)
  if [ $rc -ne 0 ]; then why="install rc $rc"
  elif [ "$n1" != "$n0" ]; then why="PREFIX=B/ reconfigured an unchanged prefix ($((n1-n0)) more configure runs)"
  fi
  leg L3 "$why"

  # L4
  seed "$C"; sm=$(md5 "$C/bin/openocd")
  echo "-- L4" >> "$R/make.log"; rmake install PREFIX="$C" CONFIGURE_FLAGS="--bindir=$D"; rc=$?; why=
  if [ "$(mf_md5 "$C")" = "$sm" ]; then why="a manifest in C vouches for the SEEDED binary (install rc $rc)"
  elif [ -e "$C/share/soclabs-openocd/build.manifest" ]; then why="a manifest was written into C, which does not hold the binary it describes"
  elif [ $rc -eq 0 ]; then why="install rc 0 although the binary went to $D"
  fi
  leg L4 "$why"
}

BAD=0
run_legs makefile "$MK"
[ -z "$FAILED" ] || BAD=$((BAD + $(echo $FAILED | wc -w)))

if [ "$MUTANTS" = 1 ]; then
  # mutant NAME EXPECTED_LEG PYTHON-FREE-SED-SCRIPT: one guard removed, exactly once.
  mutant() {
    local name=$1 want=$2 file=$W/Makefile.$1
    if [ ! -s "$file" ]; then echo "== $name"; echo "  BROKEN mutant: produced no Makefile"; BAD=$((BAD+1)); return; fi
    if cmp -s "$file" "$MK"; then echo "== $name"; echo "  BROKEN mutant: identical to the Makefile under test"; BAD=$((BAD+1)); return; fi
    mkdir -p "$W/parse-$name" && cp "$file" "$W/parse-$name/Makefile" && cp "$W/fake.pin" "$W/parse-$name/"
    if ! env -u MAKEFLAGS make -C "$W/parse-$name" -n help PIN_FILE=fake.pin >/dev/null 2>&1; then
      echo "== $name"; echo "  BROKEN mutant: does not parse"; BAD=$((BAD+1)); return
    fi
    run_legs "$name" "$file"
    case " $FAILED " in
      *" $want "*) echo "  CAUGHT by$FAILED (expected $want)" ;;
      *) if [ -z "$FAILED" ]; then echo "  SURVIVED: every leg passed"; else echo "  caught by$FAILED, but NOT by $want"; fi
         BAD=$((BAD+1)) ;;
    esac
  }
  once() {  # once FILE OUT LITERAL REPLACEMENT: replace a literal line fragment exactly once
    awk -v a="$3" -v b="$4" 'BEGIN{n=0} { i=index($0,a); if(i){n++; $0=substr($0,1,i-1) b substr($0,i+length(a))} print } END{ if(n!=1) exit 3 }' "$1" > "$2" || : > "$2"
  }
  once "$MK" "$W/Makefile.M-reconf" 'if [ "$$have" != "$(PREFIX)" ]; then' 'if false; then'
  mutant M-reconf L2
  once "$MK" "$W/Makefile.M-noclean" '$(MAKE) -C $(BUILD_DIR) clean >/dev/null || exit 1;' 'true;'
  mutant M-noclean L2
  once "$MK" "$W/Makefile.M-cmp" 'if ! cmp -s "$(BUILD_DIR)/src/openocd" "$(PREFIX)/bin/openocd"; then' 'if false; then'
  mutant M-cmp L4
  once "$MK" "$W/Makefile.M-slash" 'override PREFIX  := $(abspath $(PREFIX))' '# (mutant: PREFIX not normalised)'
  mutant M-slash L3
  if git -C "$HERE/.." cat-file -e "$PRE_FIX:Makefile" 2>/dev/null; then
    git -C "$HERE/.." show "$PRE_FIX:Makefile" > "$W/Makefile.pre-fix"
    mutant pre-fix L2
  else
    echo "== pre-fix"; echo "  SKIP: $PRE_FIX is not in this checkout (a shallow clone?); the other mutants still ran"
  fi
fi

if [ $BAD -eq 0 ]; then echo "selftest: PASS"; else echo "selftest: FAIL ($BAD)"; fi
exit $BAD
