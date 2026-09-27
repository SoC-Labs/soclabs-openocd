#!/usr/bin/env bash
# check-pins.sh -- will every driver pin in this recipe commit clone, for anyone,
# from the remote, and stay cloneable?
#
#   scripts/check-pins.sh        (run by `make check-pins`, from the recipe root)
#
# For each submodule in .gitmodules, the pin is the gitlink in HEAD (the commit
# the recipe names), not whatever the submodule happens to have checked out.
# It must be on the `branch` .gitmodules names, at the URL .gitmodules names,
# as that remote is NOW:
#
#   OK                    the pin is an ancestor of <branch> there
#   PIN WILL NOT CLONE    the pin is on no branch there: it was never pushed,
#                         or a force-push removed it
#   NOT on '<branch>'     the pin is there only through some other branch: it
#                         clones until that branch goes
#
# The URL is the one in .gitmodules, not the submodule's `origin`: a fresh
# clone uses the former, and a developer's origin may be a fork or a mirror
# that holds commits the real remote does not. Every branch is fetched from it
# with --prune into refs/remotes/check-pins/, so no stale or foreign ref can
# vouch for a pin. After that fetch, a pin that is not here as an object is
# on no branch at all; the check proves the object exists before asking
# merge-base, because a missing object also answers "not an ancestor" and
# would be misreported. Finally the submodule's checkout must BE the pin (what
# a build here compiles).
#
# Needs the submodules checked out (`make sources`) and network access to
# their remotes. Exit status 0 only when every pin is OK.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
[ -f .gitmodules ] || { echo "check-pins: no .gitmodules here" >&2; exit 2; }
fail=0 n=0
NS=refs/remotes/check-pins
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
  if ! git -C "$path" fetch -q --prune "$url" "+refs/heads/*:$NS/*"; then
    echo "check-pins: FAIL $path: cannot fetch $url -- UNKNOWN, which is not a pass"; fail=1; continue
  fi
  if ! git -C "$path" rev-parse -q --verify "$NS/$br^{commit}" >/dev/null; then
    echo "check-pins: FAIL $path: $url has no branch '$br'"; fail=1; continue
  fi
  if ! git -C "$path" cat-file -e "$pin^{commit}" 2>/dev/null; then
    echo "check-pins: FAIL $path: PIN WILL NOT CLONE -- $pin is on no branch of $url, and not in this checkout either"
    fail=1; continue
  fi
  if ! git -C "$path" merge-base --is-ancestor "$pin" "$NS/$br"; then
    held=$(git -C "$path" for-each-ref --contains "$pin" --format="'%(refname:lstrip=3)'" "$NS/" | tr '\n' ' ')
    if [ -z "$held" ]; then
      echo "check-pins: FAIL $path: PIN WILL NOT CLONE -- $pin is on no branch of $url. It exists only in this checkout: push it to '$br'."
    else
      echo "check-pins: FAIL $path: $pin is NOT on '$br' of $url. It clones today only because branch ${held% } holds it; when that goes, so does every build of this commit. Get it onto '$br', or change the branch in .gitmodules."
    fi
    fail=1; continue
  fi
  head=$(git -C "$path" rev-parse HEAD)
  if [ "$head" != "$pin" ]; then
    echo "check-pins: FAIL $path: checked out $head, but the recipe pins $pin. A build here would not be what this commit names: 'make sources', or commit the new pin."
    fail=1; continue
  fi
  echo "check-pins: OK   $path  $(git -C "$path" rev-parse --short=7 "$pin")  on '$br' of $url"
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$')
if [ "$n" -eq 0 ]; then echo "check-pins: FAIL: .gitmodules lists no submodules"; exit 1; fi
exit $fail
