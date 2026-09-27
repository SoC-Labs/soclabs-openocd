#!/usr/bin/env bash
# selftest-pins.sh -- do `make sources` and `make check-pins` tell a pin that
# will clone for anyone from one that will not?
#
#   tests/selftest-pins.sh [--makefile FILE] [--script FILE] [--no-mutants] [--keep]
#
# Two fake driver repos behind bare "remotes" (file://), and a fake recipe
# whose .gitmodules tracks A's master and B's feat branch, the shapes of
# ahb_qspi and the chiplet. Every leg works in a fresh `git clone` of the
# recipe, because a pin that resolves in the checkout that made it proves
# nothing about anyone else's. No network.
#
#   P1  both pins on their branches: sources and check-pins pass.
#   P2  A pinned at a commit held only by a side branch (ahb_qspi 1e5117e
#       before the D5 push): sources clones it, check-pins FAILS and names
#       the side branch.
#   P2s ...and install-site refuses there, on check-pins, before building:
#       a site version must name a commit that builds anywhere.
#   P3  A pinned at a commit that was never pushed: in a fresh clone,
#       sources FAILS; in the checkout that made it, check-pins FAILS with
#       PIN WILL NOT CLONE.
#   P4  the side branch fast-forwarded into master (the D5 push): P2's clone
#       now passes check-pins, with no re-clone.
#   P5  master force-pushed back so the pin is on no branch: that clone
#       FAILS again. Its remote-tracking refs still hold the pin; only a
#       fresh fetch can tell.
#   P6  a submodule checked out at a commit other than its pin: FAILS.
#   P7  the submodule's origin is a fork whose master holds the pin, while the
#       .gitmodules URL has it only on a side branch: FAILS. A fresh clone
#       asks the .gitmodules URL, so check-pins must too.
#
# Mutants, each must fail its leg:
#   M-noancestor  check-pins: is-ancestor always true     -> P2
#   M-nofetch     check-pins: no fetch, stale refs        -> P5
#   M-nohead      check-pins: checkout-is-pin removed     -> P6
#   M-origin      check-pins: fetches origin, not the URL -> P7
#   M-noprune     check-pins: fetch without --prune       -> P5 (a deleted
#                 branch still "holds" the pin, so the verdict is misnamed)
#   M-sitenopins  Makefile: install-site skips check-pins -> P2s
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MK=$HERE/../Makefile
SCRIPT=$HERE/../scripts/check-pins.sh
MUTANTS=1 KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --makefile) MK=$2; shift 2 ;;
    --script) SCRIPT=$2; shift 2 ;;
    --no-mutants) MUTANTS=0; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: $0 [--makefile FILE] [--script FILE] [--no-mutants] [--keep]" >&2; exit 2 ;;
  esac
done
for f in "$MK" "$SCRIPT"; do [ -f "$f" ] || { echo "selftest-pins: no $f" >&2; exit 2; }; done

W=$(mktemp -d "${TMPDIR:-/tmp}/oocd-pins.XXXXXX")
cleanup() { if [ "$KEEP" = 1 ] || [ "${BAD:-0}" -ne 0 ]; then echo "selftest-pins: evidence kept in $W"; else rm -rf "$W"; fi; }
trap cleanup EXIT
# file:// submodules are refused by default since git 2.38.1; allow them for
# this fixture only, through the environment every git below inherits.
export GIT_CONFIG_COUNT=6
export GIT_CONFIG_KEY_0=protocol.file.allow  GIT_CONFIG_VALUE_0=always
export GIT_CONFIG_KEY_1=user.name            GIT_CONFIG_VALUE_1=selftest
export GIT_CONFIG_KEY_2=user.email           GIT_CONFIG_VALUE_2=selftest@invalid
export GIT_CONFIG_KEY_3=core.hooksPath       GIT_CONFIG_VALUE_3=/dev/null
export GIT_CONFIG_KEY_4=init.defaultBranch   GIT_CONFIG_VALUE_4=master
export GIT_CONFIG_KEY_5=advice.detachedHead  GIT_CONFIG_VALUE_5=false
unset MAKEFLAGS MFLAGS MAKELEVEL
q() { "$@" >/dev/null 2>&1; }

# --- remotes: A tracks master, B tracks feat -------------------------------
mkrepo() {  # mkrepo NAME BRANCH: a work clone $W/work/NAME pushed to $W/remote/NAME.git
  local n=$1 b=$2
  git init -q --bare "$W/remote/$n.git"
  git init -q -b "$b" "$W/work/$n"
  echo "$n v1" > "$W/work/$n/driver.c"
  ( cd "$W/work/$n" && git add driver.c && git commit -qm "$n v1" && git remote add origin "file://$W/remote/$n.git" && q git push -q origin "$b" )
  git -C "$W/remote/$n.git" symbolic-ref HEAD "refs/heads/$b"
}
mkrepo A master
mkrepo B feat
A0=$(git -C "$W/work/A" rev-parse HEAD)
B0=$(git -C "$W/work/B" rev-parse HEAD)
wcommit() { echo "$2" >> "$W/work/$1/driver.c"; ( cd "$W/work/$1" && git commit -qam "$2" ); git -C "$W/work/$1" rev-parse HEAD; }

# --- the recipe: this Makefile + the check-pins.sh under test, two submodules
R=$W/recipe
mkdir -p "$R/scripts" "$R/drivers/A" "$R/drivers/B"
cp "$MK" "$R/Makefile"; cp "$SCRIPT" "$R/scripts/check-pins.sh"; chmod +x "$R/scripts/check-pins.sh"
printf 'sha: 0000000000000000000000000000000000000000\n' > "$R/openocd.pin"
( cd "$R" && git init -q
  git config -f .gitmodules submodule.drivers/A.path drivers/A
  git config -f .gitmodules submodule.drivers/A.url "file://$W/remote/A.git"
  git config -f .gitmodules submodule.drivers/A.branch master
  git config -f .gitmodules submodule.drivers/B.path drivers/B
  git config -f .gitmodules submodule.drivers/B.url "file://$W/remote/B.git"
  git config -f .gitmodules submodule.drivers/B.branch feat
  git update-index --add --cacheinfo "160000,$A0,drivers/A"
  git update-index --add --cacheinfo "160000,$B0,drivers/B"
  git add Makefile openocd.pin scripts/check-pins.sh .gitmodules && git commit -qm recipe )
pin() {  # pin SUB SHA MSG: commit a new gitlink for SUB in the recipe
  ( cd "$R" && git update-index --cacheinfo "160000,$2,drivers/$1" && git commit -q --allow-empty -m "$3" )
}
fresh() { rm -rf "$1"; q git clone -q "$R" "$1"; }
LOG=$W/make.log
mk() { local d=$1; shift; make -C "$d" --no-print-directory "$@" >> "$LOG" 2>&1; }
newlog() { LOG=$W/log.$RUN.$1; : > "$LOG"; }
tell() { tail -n 3 "$LOG" | tr '\n' ' '; }
reset_fixture() {  # remotes and recipe back to A0/B0, no side branches
  local n
  for n in A B; do git -C "$W/work/$n" checkout -q "$( [ $n = A ] && echo master || echo feat )"; done
  git -C "$W/work/A" reset -q --hard "$A0"; git -C "$W/work/B" reset -q --hard "$B0"
  q git -C "$W/work/A" branch -D fix local-only
  q git -C "$W/work/A" push -q -f origin "$A0:refs/heads/master"
  q git -C "$W/work/A" push -q origin :refs/heads/fix
  q git -C "$W/work/B" push -q -f origin "$B0:refs/heads/feat"
  pin A "$A0" "reset A"; pin B "$B0" "reset B"
}

FAILED=
leg() { local id=$1; shift; if [ -z "$*" ]; then echo "  PASS $id"; else echo "  FAIL $id: $*"; FAILED="$FAILED $id"; fi; }

run_legs() {  # run_legs NAME SCRIPT MAKEFILE: the legs, with that script and Makefile in the recipe
  local c rc why side unpushed b1
  RUN=$1; FAILED=
  reset_fixture
  cp "$2" "$R/scripts/check-pins.sh"; chmod +x "$R/scripts/check-pins.sh"; cp "$3" "$R/Makefile"
  ( cd "$R" && git commit -qam "under test: $1" --allow-empty )

  # P1
  newlog P1; c=$W/c1; fresh "$c"
  mk "$c" sources; rc=$?; why=
  if [ $rc -ne 0 ]; then why="sources rc $rc: $(tell)"
  elif ! mk "$c" check-pins; then why="check-pins failed on good pins: $(tell)"
  fi
  leg P1 "$why"

  # P2: A pinned at a commit only its side branch holds
  newlog P2
  git -C "$W/work/A" checkout -q -b fix
  side=$(wcommit A "A fix")
  q git -C "$W/work/A" push -q origin fix
  git -C "$W/work/A" checkout -q master
  pin A "$side" "pin A at its fix branch"
  c=$W/c2; fresh "$c"
  mk "$c" sources; rc=$?; why=
  if [ $rc -ne 0 ]; then why="sources could not clone a pin that IS on the remote (rc $rc): $(tell)"
  elif mk "$c" check-pins; then why="check-pins PASSED a pin that is not on master"
  elif ! grep -q "NOT on 'master'.*branch 'fix'" "$LOG"; then why="failed, but did not name the side branch: $(tell)"
  fi
  leg P2 "$why"

  # P2s: install-site in that clone
  newlog P2s
  mk "$c" install-site SITE_ROOT="$W/site-$RUN"; rc=$?; why=
  if [ $rc -eq 0 ]; then why="install-site PASSED with a pin that is not on its branch"
  elif ! grep -q "check-pins: FAIL" "$LOG"; then why="refused, but not by check-pins: $(tell)"
  elif [ -n "$(ls -A "$W/site-$RUN" 2>/dev/null)" ]; then why="refused, but only after writing into the site root"
  fi
  leg P2s "$why"

  # P3: A pinned at a commit that was never pushed
  newlog P3
  git -C "$W/work/A" checkout -q -b local-only master
  unpushed=$(wcommit A "A unpushed")
  git -C "$W/work/A" checkout -q master
  pin A "$unpushed" "pin A at an unpushed commit"
  c=$W/c3; fresh "$c"
  mk "$c" sources; rc=$?; why=
  if [ $rc -eq 0 ]; then why="a fresh clone checked out a pin that was never pushed"
  else
    # give c3 the object, as the checkout that made the pin has it, then ask check-pins
    [ -e "$c/drivers/A/.git" ] || q git -C "$c" submodule update --init drivers/A
    q git -C "$c" submodule update --init drivers/B
    q git -C "$c/drivers/A" fetch -q "file://$W/work/A" local-only
    q git -C "$c/drivers/A" checkout -q "$unpushed"
    if mk "$c" check-pins; then why="check-pins PASSED a pin that exists only in this checkout"
    elif ! grep -q "PIN WILL NOT CLONE" "$LOG"; then why="failed, but not as PIN WILL NOT CLONE: $(tell)"
    fi
  fi
  leg P3 "$why"

  # P4: the D5 push: fix fast-forwarded into master. P2's clone passes, no re-clone.
  newlog P4
  q git -C "$W/work/A" merge -q --ff-only fix
  q git -C "$W/work/A" push -q origin master
  if ! mk "$W/c2" check-pins; then why="the pin is on master now, but check-pins failed: $(tell)"; else why=; fi
  leg P4 "$why"

  # P5: master force-pushed back and fix deleted: the pin is on no branch.
  # c2's remote-tracking refs still hold it; only a fresh fetch can tell.
  newlog P5
  q git -C "$W/work/A" push -q -f origin "$A0:refs/heads/master"
  q git -C "$W/work/A" push -q origin :refs/heads/fix
  if mk "$W/c2" check-pins; then why="PASSED a pin the remote no longer holds"
  elif ! grep -q "PIN WILL NOT CLONE" "$LOG"; then why="failed, but not as PIN WILL NOT CLONE: $(tell)"
  else why=; fi
  leg P5 "$why"

  # P6: good pins, but drivers/B checked out at another (pushed) commit
  newlog P6
  reset_fixture
  c=$W/c6; fresh "$c"; mk "$c" sources
  b1=$(wcommit B "B v2"); q git -C "$W/work/B" push -q origin feat
  q git -C "$c/drivers/B" fetch -q origin; q git -C "$c/drivers/B" checkout -q "$b1"
  if mk "$c" check-pins; then why="PASSED with drivers/B checked out at $b1, not its pin"
  elif ! grep -q "checked out .* but the recipe pins" "$LOG"; then why="failed, but not for the checkout: $(tell)"
  else why=; fi
  leg P6 "$why"

  # P7: A's origin in this clone is a FORK whose master holds a pin the real
  # remote (the .gitmodules URL) has only on a side branch
  newlog P7
  reset_fixture
  git -C "$W/work/A" checkout -q -b fix
  side=$(wcommit A "A fix")
  q git -C "$W/work/A" push -q origin fix
  git -C "$W/work/A" checkout -q master
  rm -rf "$W/remote/A-fork.git"; q git clone -q --bare "$W/remote/A.git" "$W/remote/A-fork.git"
  q git -C "$W/remote/A-fork.git" update-ref refs/heads/master "$side"
  pin A "$side" "pin A at its fix branch"
  c=$W/c7; fresh "$c"; mk "$c" sources
  q git -C "$c/drivers/A" remote set-url origin "file://$W/remote/A-fork.git"
  if mk "$c" check-pins; then why="PASSED because the checkout's origin (a fork) has the pin on master; a fresh clone uses the .gitmodules URL"
  elif ! grep -q "NOT on 'master' of file://$W/remote/A.git" "$LOG"; then why="failed, but not against the .gitmodules URL: $(tell)"
  else why=; fi
  leg P7 "$why"
}

BAD=0
echo "== check-pins.sh"
run_legs script "$SCRIPT" "$MK"
[ -z "$FAILED" ] || BAD=$((BAD + $(echo $FAILED | wc -w)))

if [ "$MUTANTS" = 1 ]; then
  once() {  # once OUT LITERAL REPLACEMENT [SOURCE]: SOURCE (default the script) with a fragment replaced once
    awk -v a="$2" -v b="$3" 'BEGIN{n=0} { i=index($0,a); if(i){n++; $0=substr($0,1,i-1) b substr($0,i+length(a))} print } END{ if(n!=1) exit 3 }' "${4:-$SCRIPT}" > "$1" || : > "$1"
  }
  mutant() {  # mutant NAME EXPECTED_LEG [makefile]: check-pins.NAME or Makefile.NAME in $W
    local f=$W/check-pins.$1 sc mf
    [ "${3:-}" = makefile ] && f=$W/Makefile.$1
    echo "== $1"
    if [ ! -s "$f" ] || cmp -s "$f" "$SCRIPT" || cmp -s "$f" "$MK"; then echo "  BROKEN mutant: its fragment is not in the file exactly once"; BAD=$((BAD+1)); return; fi
    if [ "${3:-}" = makefile ]; then
      sc=$SCRIPT mf=$f
      if ! make -n -f "$f" help >/dev/null 2>&1; then echo "  BROKEN mutant: does not parse"; BAD=$((BAD+1)); return; fi
    else
      sc=$f mf=$MK
      if ! bash -n "$f"; then echo "  BROKEN mutant: does not parse"; BAD=$((BAD+1)); return; fi
    fi
    run_legs "$1" "$sc" "$mf"
    case " $FAILED " in
      *" $2 "*) echo "  CAUGHT by$FAILED (expected $2)" ;;
      *) if [ -z "$FAILED" ]; then echo "  SURVIVED: every leg passed"; else echo "  caught by$FAILED, but NOT by $2"; fi; BAD=$((BAD+1)) ;;
    esac
  }
  once "$W/check-pins.M-noancestor" 'if ! git -C "$path" merge-base --is-ancestor "$pin" "$NS/$br"; then' 'if false; then'
  mutant M-noancestor P2
  once "$W/check-pins.M-nofetch" 'if ! git -C "$path" fetch -q --prune "$url" "+refs/heads/*:$NS/*"; then' 'if false; then'
  mutant M-nofetch P5
  once "$W/check-pins.M-origin" 'if ! git -C "$path" fetch -q --prune "$url" "+refs/heads/*:$NS/*"; then' 'if ! git -C "$path" fetch -q --prune origin "+refs/heads/*:$NS/*"; then'
  mutant M-origin P7
  once "$W/check-pins.M-noprune" 'if ! git -C "$path" fetch -q --prune "$url" "+refs/heads/*:$NS/*"; then' 'if ! git -C "$path" fetch -q "$url" "+refs/heads/*:$NS/*"; then'
  mutant M-noprune P5
  once "$W/check-pins.M-nohead" 'if [ "$head" != "$pin" ]; then' 'if false; then'
  mutant M-nohead P6
  once "$W/Makefile.M-sitenopins" '$(MAKE) --no-print-directory check-pins || { \' 'true || { \' "$MK"
  mutant M-sitenopins P2s makefile
fi

if [ $BAD -eq 0 ]; then echo "selftest-pins: PASS"; else echo "selftest-pins: FAIL ($BAD)"; fi
exit $BAD
