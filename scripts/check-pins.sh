#!/usr/bin/env bash
# check-pins.sh -- will every driver pin in this recipe commit clone, for anyone,
# from the remote, and stay cloneable?
#
#   scripts/check-pins.sh        (run by `make check-pins`, from the recipe root)
#
# For each submodule in .gitmodules, the pin is the gitlink in HEAD (the commit
# the recipe names), not whatever the submodule happens to have checked out.
# It must be on the `branch` .gitmodules names, on the remote as it is NOW:
#
#   OK                    the pin is an ancestor of origin/<branch>
#   PIN WILL NOT CLONE    the pin is on no branch of the remote: it was never
#                         pushed, or a force-push removed it
#   NOT on origin/<br>    the pin is on the remote only through some other
#                         branch: it clones until that branch goes
#
# Every branch is fetched with --prune first, so a stale remote-tracking ref
# cannot vouch for a pin the remote no longer holds. After that fetch, a pin
# that is not here as an object is on no branch at all; the check proves the
# object exists before asking merge-base, because a missing object also
# answers "not an ancestor" and would be misreported. Finally the submodule's
# checkout must BE the pin (what a build here compiles).
#
# Needs the submodules checked out (`make sources`) and network access to
# their remotes. Exit status 0 only when every pin is OK.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
[ -f .gitmodules ] || { echo "check-pins: no .gitmodules here" >&2; exit 2; }
fail=0 n=0
while read -r key path; do
  n=$((n + 1))
  name=${key#submodule.}; name=${name%.path}
  url=$(git config -f .gitmodules --get "submodule.$name.url")
  br=$(git config -f .gitmodules --get "submodule.$name.branch")
  pin=$(git ls-tree HEAD -- "$path" | awk '$2 == "commit" {print $3}')
  if [ -z "$pin" ]; then
    echo "check-pins: FAIL $path: HEAD has no gitlink there"; fail=1; continue
  fi
  if [ -z "$br" ]; then
    echo "check-pins: FAIL $path: .gitmodules names no branch, so there is nothing to hold the pin"; fail=1; continue
  fi
  if [ ! -e "$path/.git" ]; then
    echo "check-pins: FAIL $path: not checked out -- run 'make sources' first"; fail=1; continue
  fi
  if ! git -C "$path" fetch -q --prune origin '+refs/heads/*:refs/remotes/origin/*'; then
    echo "check-pins: FAIL $path: cannot fetch $url -- UNKNOWN, which is not a pass"; fail=1; continue
  fi
  if ! git -C "$path" rev-parse -q --verify "refs/remotes/origin/$br^{commit}" >/dev/null; then
    echo "check-pins: FAIL $path: $url has no branch '$br'"; fail=1; continue
  fi
  if ! git -C "$path" cat-file -e "$pin^{commit}" 2>/dev/null; then
    echo "check-pins: FAIL $path: PIN WILL NOT CLONE -- $pin is on no branch of $url, and not in this checkout either"
    fail=1; continue
  fi
  if ! git -C "$path" merge-base --is-ancestor "$pin" "refs/remotes/origin/$br"; then
    held=$(git -C "$path" branch -r --contains "$pin" --format='%(refname:short)' | tr '\n' ' ')
    if [ -z "$held" ]; then
      echo "check-pins: FAIL $path: PIN WILL NOT CLONE -- $pin is on no branch of $url. It exists only in this checkout: push it to $br."
    else
      echo "check-pins: FAIL $path: $pin is NOT on origin/$br. It clones today only because ${held% } holds it; when that branch goes, so does every build of this commit. Get it onto $br, or change $br in .gitmodules."
    fi
    fail=1; continue
  fi
  head=$(git -C "$path" rev-parse HEAD)
  if [ "$head" != "$pin" ]; then
    echo "check-pins: FAIL $path: checked out $head, but the recipe pins $pin. A build here would not be what this commit names: 'make sources', or commit the new pin."
    fail=1; continue
  fi
  echo "check-pins: OK   $path  $(git -C "$path" rev-parse --short=7 "$pin")  on origin/$br of $url"
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$')
if [ "$n" -eq 0 ]; then echo "check-pins: FAIL: .gitmodules lists no submodules"; exit 1; fi
exit $fail
