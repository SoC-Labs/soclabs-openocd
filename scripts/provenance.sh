#!/usr/bin/env bash
# provenance.sh -- one word saying which commit a file or tree came from, for
# the build manifest.
#
#   scripts/provenance.sh tree DIR    <sha>, or <sha>-dirty if a tracked file
#                                     (or a submodule's checkout) differs from it
#   scripts/provenance.sh file FILE   <origin-url>@<sha> of the checkout FILE
#                                     is in, suffixed -dirty if FILE differs from
#                                     that commit, -untracked if git does not
#                                     track it
#
# Prints "not-in-git" when there is no commit to name. It never fails a build:
# the md5s in the manifest are the verdict, and this word only says where
# those bytes came from.
set -u
case "${1:-}" in
  tree)
    d=$2
    sha=$(git -C "$d" rev-parse -q --verify HEAD 2>/dev/null) || { echo not-in-git; exit 0; }
    if [ -n "$(git -C "$d" status --porcelain --untracked-files=no 2>/dev/null)" ]; then sha="$sha-dirty"; fi
    echo "$sha" ;;
  file)
    f=$(readlink -f "$2"); d=$(dirname "$f")
    sha=$(git -C "$d" rev-parse -q --verify HEAD 2>/dev/null) || { echo not-in-git; exit 0; }
    url=$(git -C "$d" config --get remote.origin.url 2>/dev/null || echo no-origin)
    if ! git -C "$d" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then sha="$sha-untracked"
    elif ! git -C "$d" diff --quiet HEAD -- "$f" 2>/dev/null; then sha="$sha-dirty"; fi
    echo "$url@$sha" ;;
  *) echo "usage: $0 tree DIR | file FILE" >&2; exit 2 ;;
esac
