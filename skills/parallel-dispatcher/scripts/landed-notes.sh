#!/usr/bin/env bash
# List the docs notes of runs that landed on main after <base>: the rules a
# worker must pick up after rebasing from <base> onto origin/<main>.
#
# Usage: landed-notes.sh <run_file> <base>
#   <run_file>  the caller's run record (locates the repo; excluded from output)
#   <base>      the commit the caller was on before rebasing, e.g. captured with
#               BASE=$(git merge-base HEAD origin/<main>)
# Prints one "landed: #<issue> <sha> docs=<docs>" line per run, then
# "urgent: N". Unmerged runs are never listed: their notes are not rules yet.
set -euo pipefail

run_file="${1:?usage: landed-notes.sh <run_file> <base>}"
base="${2:?usage: landed-notes.sh <run_file> <base>}"
[ -f "$run_file" ] || { echo "error: run file not found: $run_file" >&2; exit 2; }
runs_dir="$(cd "$(dirname "$run_file")" && pwd)"
[ "$(basename "$runs_dir")" = runs ] || { echo "error: not a run record: $run_file" >&2; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PD_ROOT="$(dirname "$(dirname "$(dirname "$runs_dir")")")"
. "$here/common.sh"

head_ref="origin/$(main_branch)"
self="$runs_dir/$(basename "$run_file")"
git -C "$ROOT" cat-file -e "$base^{commit}" 2>/dev/null || { echo "error: unknown base commit: $base" >&2; exit 2; }

urgent=0
for f in "$RUNS_DIR"/*.md; do
  [ -e "$f" ] && [ "$f" != "$self" ] || continue
  sha="$(field "$f" merged)"
  [ -n "$sha" ] || continue
  git -C "$ROOT" merge-base --is-ancestor "$sha" "$head_ref" 2>/dev/null || continue
  git -C "$ROOT" merge-base --is-ancestor "$sha" "$base" && continue
  docs="$(field "$f" docs)"
  issue="$(field "$f" issue)"
  if [ -n "$issue" ]; then label="#$issue"; else label="$(field "$f" kind)"; fi
  echo "landed: $label ${sha:0:9} docs=${docs:-none}"
  case "$docs" in urgent*) urgent=$((urgent + 1)) ;; esac
done
echo "urgent: $urgent"
