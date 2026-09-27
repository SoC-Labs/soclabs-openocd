#!/usr/bin/env bash
# selftest-install.sh -- does the recipe install what it built, where it was
# told to, and publish a site version atomically and reversibly?
#
#   tests/selftest-install.sh [--makefile FILE] [--no-mutants] [--keep]
#
# It runs the recipe's own targets against a FAKE upstream: a git repo whose
# configure writes an automake-style Makefile ("prefix = ..." and a bindir, the
# lines the real one installs by), and whose "binary" is a script carrying each
# overlaid driver's name and the bindir it was built for, as the real openocd
# carries BINDIR. The fake drivers live in a git repo, and hostio4's
# test_driver_fixes.sh is a stub that logs which binary it was given. So: no
# network, no compiler, no HAPS-work, under a minute with the mutants.
#
# The fake was checked against the real tree (2026-09-27) for the three things
# it models: configure writes "prefix = <path>"; install is a byte copy of
# src/openocd; the prefix is compiled in (a reconfigure without a clean left 2
# of the real binary's 3 prefix strings at the old prefix).
#
# INSTALL legs (fresh recipe copy):
#   L1  install PREFIX=A into an empty A: A/bin/openocd is the built binary,
#       built for A, and the manifest describes it.
#   L2  THE S4 CASE. B already holds an older binary that carries both driver
#       names. install PREFIX=B on the tree configured for A must install the
#       new build into B, built for B, and never leave a manifest that vouches
#       for the seeded file. (The pre-fix Makefile installed into A, hashed B's
#       old binary, and verify passed.)
#   L3  install PREFIX=B/ (trailing slash) must not reconfigure: configure
#       strips the slash, so an unnormalised compare would clean and rebuild on
#       every run.
#   L4  install PREFIX=C CONFIGURE_FLAGS=--bindir=D, with C seeded: the binary
#       lands in D, so install must FAIL and write NO manifest into C at all.
#       The cmp guard's own leg: the prefix check passes here, and without the
#       cmp a manifest lands in C describing a binary that is in D.
#
# SITE legs (a recipe copy that is a git repo, SITE_ROOT in scratch):
#   S1  install-site builds <ver> into SITE_ROOT/<ver>, built for that prefix,
#       runs `make test` on THAT binary, and publishes nothing.
#   S2  site-publish (first): install -> <ver>, relative; no previous; verify
#       passes through the link.
#   S3  a second commit, install-site + site-publish: install -> v2,
#       previous -> v1.
#   S4  site-rollback: install -> v1, previous -> v2; again: back to v2.
#   S5  the flips are renames: strace of S3's publish and S4's rollbacks shows
#       no unlink of install or previous, and a rename onto each. (SKIP without
#       strace.)
#   S6  refusals, each leaving what is live untouched:
#       a  a tracked file modified in the recipe tree: nothing built;
#       b  HEAD's version is live: not rebuilt in place;
#       c  a driver source with an uncommitted edit: nothing built;
#       d  make test fails: install-site fails and nothing is published;
#       e  previous's binary no longer matches its manifest: no rollback.
#
# With no --no-mutants it then runs the legs on mutants of FILE, one guard
# removed each, and on the pre-fix Makefile (git object PRE_FIX) when this
# checkout has it. Each must fail on the leg named for it:
#   M-reconf   prefix check disabled                    -> L2
#   M-noclean  reconfigure without clean                -> L2
#   M-cmp      no cmp before the manifest               -> L4
#   M-slash    PREFIX not normalised                    -> L3
#   pre-fix    the Makefile before S4                   -> L2
#   M-dirty    recipe-tree check disabled               -> S6a
#   M-live     live-version check disabled              -> S6b
#   M-drvdirty driver-source check disabled             -> S6c
#   M-notest   install-site does not run make test      -> S1
#   M-rmln     publish flips by rm + ln, not rename     -> S5
#   M-rbcheck  rollback skips the integrity check       -> S6e
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
G=(git -c user.name=selftest -c user.email=selftest@invalid -c core.hooksPath=/dev/null -c init.defaultBranch=main -c advice.detachedHead=false)
STRACE=$(command -v strace || true)

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
printf 'sha: %s\ncommit-subj: fake release   [tag: v0.12.0]\n' "$(git -C "$U" rev-parse HEAD)" > "$W/fake.pin"

DRV=$W/drv
mkdir -p "$DRV/ahb_qspi/sw/openocd" "$DRV/hostio4"
echo '/* fake ahb_qspi */' > "$DRV/ahb_qspi/sw/openocd/ahb_qspi.c"
echo '/* fake hostio4 */' > "$DRV/hostio4/hostio4.c"
cat > "$DRV/hostio4/test_driver_fixes.sh" <<EOF
#!/bin/sh
# stub: records which binary make test ran on; FAKE_TEST_RC makes it fail
echo "\$1" >> "$W/drv-test.log"
exit \${FAKE_TEST_RC:-0}
EOF
chmod +x "$DRV/hostio4/test_driver_fixes.sh"
( cd "$DRV" && "${G[@]}" init -q && "${G[@]}" add -A && "${G[@]}" commit -qm 'fake drivers' ) || { echo "selftest: cannot build the fake drivers" >&2; exit 2; }

md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
mf_md5() { awk '/^binary_md5/{print $2}' "$1/share/soclabs-openocd/build.manifest" 2>/dev/null; }
seed() {  # an older build: runs, and carries both driver names, so a name check passes
  mkdir -p "$1/bin"
  printf '#!/bin/sh\nexit 0\nahb_qspi\nhostio4\nseed: an older build, not this one\n' > "$1/bin/openocd"
  chmod +x "$1/bin/openocd"
}
leg() { local id=$1; shift; if [ -z "$*" ]; then echo "  PASS $id"; else echo "  FAIL $id: $*"; FAILED="$FAILED $id"; fi; }
skip() { echo "  SKIP $1: $2"; }

# The Makefile under test, in recipe copy $R, with the fixture wired in. The
# caller's make/env settings are dropped so none of them leak into a leg.
CLEAN_ENV=(env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u CONFIGURE_FLAGS -u PREFIX -u BIN -u HOST -u SITE_ROOT -u SITE_VER)
rmake() {
  "${CLEAN_ENV[@]}" make -C "$R" --no-print-directory PIN_FILE=fake.pin OPENOCD_REMOTE="$U" \
      PATCHES=patches/fake.patch ahb_qspi_ROOT="$DRV/ahb_qspi" hostio4_ROOT="$DRV/hostio4" \
      CONFIGURE_FLAGS= HOST= "$@" >> "$R/make.log" 2>&1
}
new_recipe() {  # new_recipe DIR MAKEFILE: a recipe copy, committed, so it is "clean"
  mkdir -p "$1/patches"
  cp "$2" "$1/Makefile"; cp "$W/fake.pin" "$1/"; cp "$W/fake.patch" "$1/patches/"
  ( cd "$1" && "${G[@]}" init -q && "${G[@]}" add Makefile fake.pin patches && "${G[@]}" commit -qm recipe )
}

install_legs() {
  local rc sm n0 n1 why
  R=$W/run-$1/install; new_recipe "$R" "$2"
  local A=$R/pfx/A B=$R/pfx/B C=$R/pfx/C D=$R/pfx/elsewhere/bin
  local BLT=$R/build/openocd-src/src/openocd

  echo "-- L1" >> "$R/make.log"; rmake install PREFIX="$A"; rc=$?; why=
  if [ $rc -ne 0 ]; then why="install rc $rc"
  elif ! cmp -s "$BLT" "$A/bin/openocd"; then why="A/bin/openocd is not the built binary"
  elif ! grep -qx "BINDIR=$A/bin" "$BLT"; then why="binary not built for A"
  elif [ "$(mf_md5 "$A")" != "$(md5 "$BLT")" ]; then why="manifest does not describe the binary"
  fi
  leg L1 "$why"

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

  n0=$(wc -l < "$R/build/openocd-src/configure.log" 2>/dev/null || echo 0)
  echo "-- L3" >> "$R/make.log"; rmake install PREFIX="$B/"; rc=$?; why=
  n1=$(wc -l < "$R/build/openocd-src/configure.log" 2>/dev/null || echo 0)
  if [ $rc -ne 0 ]; then why="install rc $rc"
  elif [ "$n1" != "$n0" ]; then why="PREFIX=B/ reconfigured an unchanged prefix ($((n1-n0)) more configure runs)"
  fi
  leg L3 "$why"

  seed "$C"; sm=$(md5 "$C/bin/openocd")
  echo "-- L4" >> "$R/make.log"; rmake install PREFIX="$C" CONFIGURE_FLAGS="--bindir=$D"; rc=$?; why=
  if [ "$(mf_md5 "$C")" = "$sm" ]; then why="a manifest in C vouches for the SEEDED binary (install rc $rc)"
  elif [ -e "$C/share/soclabs-openocd/build.manifest" ]; then why="a manifest was written into C, which does not hold the binary it describes"
  elif [ $rc -eq 0 ]; then why="install rc 0 although the binary went to $D"
  fi
  leg L4 "$why"
}

site_legs() {
  local rc rc2 why v1 v2 v3 keep t
  R=$W/run-$1/site; new_recipe "$R" "$2"
  local S=$R/site-root BLT=$R/build/openocd-src/src/openocd
  ver() { echo "0.12.0-soclabs-$(git -C "$R" rev-parse HEAD | cut -c1-7)"; }
  commit() { echo "$1" >> "$R/NOTES"; ( cd "$R" && "${G[@]}" add NOTES && "${G[@]}" commit -qm "$1" ); }
  link() { readlink "$S/$1" 2>/dev/null; }
  traced() {  # traced FILE target...: a site target under strace, when there is one
    local f=$1; shift
    if [ -n "$STRACE" ]; then
      echo "-- traced $*" >> "$R/make.log"
      "${CLEAN_ENV[@]}" "$STRACE" -f -qq -s 4096 -e trace=unlink,unlinkat,rename,renameat,renameat2,rmdir -o "$f" \
        make -C "$R" --no-print-directory PIN_FILE=fake.pin OPENOCD_REMOTE="$U" \
          PATCHES=patches/fake.patch ahb_qspi_ROOT="$DRV/ahb_qspi" hostio4_ROOT="$DRV/hostio4" \
          CONFIGURE_FLAGS= HOST= SITE_ROOT="$S" "$@" >> "$R/make.log" 2>&1
    else
      rmake SITE_ROOT="$S" "$@"
    fi
  }
  atomic() {  # atomic FILE NAME...: each NAME was renamed onto, and never unlinked
    local f=$1 n; shift
    for n in "$@"; do
      if grep -E "(unlink|unlinkat|rmdir)\(.*\"$S/$n\"" "$f" >/dev/null; then echo "$n was UNLINKED before being replaced ($(basename "$f"))"; return; fi
      if ! grep -E "rename(at2?)?\(.*\"$S/$n\".*= 0" "$f" >/dev/null; then echo "no rename onto $n ($(basename "$f"))"; return; fi
    done
  }
  : > "$W/drv-test.log"

  # S1
  v1=$(ver); echo "-- S1" >> "$R/make.log"; rmake install-site SITE_ROOT="$S"; rc=$?; why=
  if [ $rc -ne 0 ]; then why="install-site rc $rc"
  elif ! cmp -s "$BLT" "$S/$v1/bin/openocd"; then why="$v1/bin/openocd is not the built binary"
  elif ! grep -qx "BINDIR=$S/$v1/bin" "$S/$v1/bin/openocd"; then why="$v1 was not built for its own prefix"
  elif ! grep -qx "$S/$v1/bin/openocd" "$W/drv-test.log"; then why="make test did not run on $v1's binary"
  elif [ -L "$S/install" ] || [ -e "$S/install" ]; then why="install-site changed what is live"
  fi
  leg S1 "$why"

  # S2
  echo "-- S2" >> "$R/make.log"; rmake site-publish SITE_ROOT="$S"; rc=$?; why=
  if [ $rc -ne 0 ]; then why="site-publish rc $rc"
  elif [ "$(link install)" != "$v1" ]; then why="install -> '$(link install)', not $v1"
  elif [ -L "$S/previous" ]; then why="a first publish made a previous link"
  elif ! rmake verify BIN="$S/install/bin/openocd"; then why="verify fails through the link"
  fi
  leg S2 "$why"

  # S3 (its publish is traced for S5)
  commit v2; v2=$(ver)
  echo "-- S3" >> "$R/make.log"; rmake install-site SITE_ROOT="$S"; rc=$?
  traced "$R/publish.strace" site-publish; rc2=$?; why=
  if [ $rc -ne 0 ] || [ $rc2 -ne 0 ]; then why="install-site rc $rc, site-publish rc $rc2"
  elif [ "$(link install)" != "$v2" ] || [ "$(link previous)" != "$v1" ]; then why="install -> '$(link install)', previous -> '$(link previous)'"
  fi
  leg S3 "$why"

  # S4 (both rollbacks are traced for S5)
  echo "-- S4" >> "$R/make.log"; traced "$R/rollback1.strace" site-rollback; rc=$?; why=
  if [ $rc -ne 0 ]; then why="site-rollback rc $rc"
  elif [ "$(link install)" != "$v1" ] || [ "$(link previous)" != "$v2" ]; then why="after rollback: install -> '$(link install)', previous -> '$(link previous)'"
  else
    traced "$R/rollback2.strace" site-rollback; rc=$?
    if [ $rc -ne 0 ]; then why="roll forward rc $rc"
    elif [ "$(link install)" != "$v2" ] || [ "$(link previous)" != "$v1" ]; then why="after roll forward: install -> '$(link install)', previous -> '$(link previous)'"
    elif ! rmake verify BIN="$S/install/bin/openocd"; then why="verify fails through the link after roll forward"
    fi
  fi
  leg S4 "$why"

  # S5
  if [ -z "$STRACE" ]; then skip S5 "no strace on PATH"
  else
    why=$(atomic "$R/publish.strace" install previous)
    [ -z "$why" ] && why=$(atomic "$R/rollback1.strace" install previous)
    [ -z "$why" ] && why=$(atomic "$R/rollback2.strace" install previous)
    leg S5 "$why"
  fi

  # S6b: HEAD is v2, and v2 is live
  keep=$(md5 "$S/$v2/bin/openocd")
  echo "-- S6b" >> "$R/make.log"; rmake install-site SITE_ROOT="$S"; rc=$?; why=
  if [ $rc -eq 0 ]; then why="rebuilt the LIVE version $v2 in place"
  elif [ "$(md5 "$S/$v2/bin/openocd")" != "$keep" ]; then why="refused, but the live binary changed"
  fi
  leg S6b "$why"

  # S6a: a new, unpublished commit v3, with a tracked file then modified
  commit v3; v3=$(ver); echo dirty >> "$R/NOTES"
  echo "-- S6a" >> "$R/make.log"; rmake install-site SITE_ROOT="$S"; rc=$?; why=
  if [ $rc -eq 0 ]; then why="built from a recipe tree with uncommitted changes"
  elif [ -e "$S/$v3" ]; then why="refused, but $v3 was built first"
  fi
  leg S6a "$why"
  git -C "$R" checkout -q NOTES

  # S6c: the recipe is clean, a driver source is not
  echo '/* uncommitted */' >> "$DRV/hostio4/hostio4.c"
  echo "-- S6c" >> "$R/make.log"; rmake install-site SITE_ROOT="$S"; rc=$?; why=
  if [ $rc -eq 0 ]; then why="built from a driver source with uncommitted changes"
  elif [ -e "$S/$v3" ]; then why="refused, but $v3 was built first"
  fi
  leg S6c "$why"
  git -C "$DRV" checkout -q hostio4/hostio4.c

  # S6d: make test fails
  echo "-- S6d" >> "$R/make.log"; FAKE_TEST_RC=1 rmake install-site SITE_ROOT="$S"; rc=$?; why=
  if [ $rc -eq 0 ]; then why="install-site passed although make test failed"
  elif [ "$(link install)" != "$v2" ]; then why="install -> '$(link install)' after a failed install-site"
  fi
  leg S6d "$why"

  # S6e: previous (v1) no longer matches its manifest
  t=$S/$v1/bin/openocd; cp -p "$t" "$W/v1.keep"; chmod u+w "$t"; echo tampered >> "$t"
  echo "-- S6e" >> "$R/make.log"; rmake site-rollback SITE_ROOT="$S"; rc=$?; why=
  if [ $rc -eq 0 ]; then why="rolled back to a binary its manifest does not describe"
  elif [ "$(link install)" != "$v2" ]; then why="refused, but install -> '$(link install)'"
  fi
  leg S6e "$why"
  cp -p "$W/v1.keep" "$t"
}

# run NAME MAKEFILE GROUPS: sets FAILED to the legs that failed.
run() {
  FAILED=; echo "== $1"
  case " $3 " in *" install "*) install_legs "$1" "$2" ;; esac
  case " $3 " in *" site "*) site_legs "$1" "$2" ;; esac
}

BAD=0
run makefile "$MK" "install site"
[ -z "$FAILED" ] || BAD=$((BAD + $(echo $FAILED | wc -w)))

if [ "$MUTANTS" = 1 ]; then
  once() {  # once OUT LITERAL REPLACEMENT: $MK with a literal fragment replaced, exactly once
    awk -v a="$2" -v b="$3" 'BEGIN{n=0} { i=index($0,a); if(i){n++; $0=substr($0,1,i-1) b substr($0,i+length(a))} print } END{ if(n!=1) exit 3 }' "$MK" > "$1" || : > "$1"
  }
  mutant() {  # mutant NAME EXPECTED_LEG GROUP
    local name=$1 want=$2 file=$W/Makefile.$1
    if [ ! -s "$file" ]; then echo "== $name"; echo "  BROKEN mutant: its fragment is not in the Makefile exactly once"; BAD=$((BAD+1)); return; fi
    if cmp -s "$file" "$MK"; then echo "== $name"; echo "  BROKEN mutant: identical to the Makefile under test"; BAD=$((BAD+1)); return; fi
    mkdir -p "$W/parse-$name" && cp "$file" "$W/parse-$name/Makefile" && cp "$W/fake.pin" "$W/parse-$name/"
    if ! env -u MAKEFLAGS make -C "$W/parse-$name" -n help PIN_FILE=fake.pin >/dev/null 2>&1; then
      echo "== $name"; echo "  BROKEN mutant: does not parse"; BAD=$((BAD+1)); return
    fi
    run "$name" "$file" "$3"
    case " $FAILED " in
      *" $want "*) echo "  CAUGHT by$FAILED (expected $want)" ;;
      *) if [ -z "$FAILED" ]; then echo "  SURVIVED: every leg passed"; else echo "  caught by$FAILED, but NOT by $want"; fi
         BAD=$((BAD+1)) ;;
    esac
  }
  once "$W/Makefile.M-reconf"  'if [ "$$have" != "$(PREFIX)" ]; then' 'if false; then'
  mutant M-reconf L2 install
  once "$W/Makefile.M-noclean" '$(MAKE) -C $(BUILD_DIR) clean >/dev/null || exit 1;' 'true;'
  mutant M-noclean L2 install
  once "$W/Makefile.M-cmp"     'if ! cmp -s "$(BUILD_DIR)/src/openocd" "$(PREFIX)/bin/openocd"; then' 'if false; then'
  mutant M-cmp L4 install
  once "$W/Makefile.M-slash"   'override PREFIX  := $(abspath $(PREFIX))' '# (mutant: PREFIX not normalised)'
  mutant M-slash L3 install
  if git -C "$HERE/.." cat-file -e "$PRE_FIX:Makefile" 2>/dev/null; then
    git -C "$HERE/.." show "$PRE_FIX:Makefile" > "$W/Makefile.pre-fix"
    mutant pre-fix L2 install
  else
    echo "== pre-fix"; echo "  SKIP: $PRE_FIX is not in this checkout (a shallow clone?); the other mutants still ran"
  fi
  once "$W/Makefile.M-dirty"    'if [ -n "$$dirty" ]; then' 'if false; then'
  mutant M-dirty S6a site
  once "$W/Makefile.M-live"     "if [ \"\$\$(readlink '\$(SITE_LINK)' 2>/dev/null)\" = \"\$(SITE_VER)\" ]; then" 'if false; then'
  mutant M-live S6b site
  once "$W/Makefile.M-drvdirty" 'if ! git -C "$$dir" diff --quiet HEAD -- "$$src"; then' 'if false; then'
  mutant M-drvdirty S6c site
  once "$W/Makefile.M-notest"   "\$(MAKE) --no-print-directory test BIN='\$(SITE_PREFIX)/bin/openocd'" 'true'
  mutant M-notest S1 site
  if [ -n "$STRACE" ]; then
    once "$W/Makefile.M-rmln"   "if ! { ln -s '\$(SITE_VER)' \"\$\$tmp\" && mv -T \"\$\$tmp\" '\$(SITE_LINK)'; }; then" "if ! { rm -f '\$(SITE_LINK)' && ln -s '\$(SITE_VER)' '\$(SITE_LINK)'; }; then"
    mutant M-rmln S5 site
  else
    echo "== M-rmln"; echo "  SKIP: no strace on PATH, so S5 cannot run"
  fi
  once "$W/Makefile.M-rbcheck"  "echo \"site-rollback: FAILED -- \$\$prev's manifest does not describe its binary.\" >&2; exit 1;" ':;'
  mutant M-rbcheck S6e site
fi

if [ $BAD -eq 0 ]; then echo "selftest: PASS"; else echo "selftest: FAIL ($BAD)"; fi
exit $BAD
