#!/usr/bin/env bash
# Report dispatcher state for the current project: shared lock, active/stale
# runs, any in-flight scout scan, orphan dispatch branches, worktree cleanliness.
# Read-only except for creating the state dir and the git exclude entry.
set -euo pipefail

STALE_MINUTES="${DISPATCH_STALE_MINUTES:-45}"
MUTEX="$HOME/.claude/lib/agent-mutex.sh"

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
dir="$root/.claude/dispatch"
runs="$dir/runs"
mkdir -p "$runs"

is_git=0
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  is_git=1
  # Keep dispatcher state out of the repo without dirtying a tracked .gitignore.
  exclude="$(git -C "$root" rev-parse --git-path info/exclude)"
  if ! grep -qxF '.claude/dispatch/' "$exclude" 2>/dev/null; then
    echo '.claude/dispatch/' >>"$exclude"
  fi
fi

main_branch="main"
if [ "$is_git" -eq 1 ]; then
  head_ref="$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$head_ref" ]; then
    main_branch="${head_ref##*/}"
  elif ! git -C "$root" show-ref --verify --quiet refs/heads/main && \
       git -C "$root" show-ref --verify --quiet refs/heads/master; then
    main_branch="master"
  fi
fi

echo "root: $root"
echo "main_branch: $main_branch"
echo "stale_after_minutes: $STALE_MINUTES"

# Lock and peer activity come from the mutex shared with the scout skill: only
# one of the two may have an agent in flight per project.
bash "$MUTEX" lock
bash "$MUTEX" peer scout

now="$(date -u +%s)"
found=0
for f in "$runs"/*.md; do
  [ -e "$f" ] || continue
  status="$(sed -n 's/^status:[[:space:]]*//p' "$f" | head -1)"
  [ "$status" = "running" ] || continue
  found=1
  updated="$(sed -n 's/^updated:[[:space:]]*//p' "$f" | head -1)"
  branch="$(sed -n 's/^branch:[[:space:]]*//p' "$f" | head -1)"
  task="$(sed -n 's/^task:[[:space:]]*//p' "$f" | head -1)"
  # The heartbeat is the file's mtime, not the self-reported `updated:` field:
  # a worker proves it is alive by writing the record, and the filesystem
  # stamps that write. Workers that type a plausible time instead of running
  # `date -u` used to drift hours ahead and read as STALE while still working.
  ts="$(stat -c %Y "$f")"
  age=$(( (now - ts) / 60 ))
  if [ "$age" -lt 0 ]; then
    # Only reachable if the system clock moved backwards; the run was just
    # touched, so treat it as alive rather than dispatching a second worker.
    echo "warn: mtime is in the future (clock skew) file=$f age_min=$age"
    age=0
  fi
  if [ "$age" -ge "$STALE_MINUTES" ]; then
    state=STALE
  else
    state=FRESH
  fi
  echo "run: $state age_min=$age file=$f branch=$branch task=$task"
  # `updated:` is kept for humans reading the record; a large divergence means
  # the worker is fabricating timestamps and its `## Log` times are unreliable.
  claimed="$(date -u -d "$updated" +%s 2>/dev/null || echo 0)"
  if [ "$claimed" -ne 0 ] && [ $(( (claimed - ts) / 60 )) -ge 5 ]; then
    echo "warn: self-reported updated: is $(( (claimed - ts) / 60 ))min ahead of mtime file=$f"
  fi
done
[ "$found" -eq 1 ] || echo "run: none active"

if [ "$is_git" -eq 1 ]; then
  for b in $(git -C "$root" for-each-ref --format='%(refname:short)' refs/heads/dispatch 2>/dev/null); do
    ahead="$(git -C "$root" rev-list --count "$main_branch..$b" 2>/dev/null || echo 0)"
    if [ "$ahead" -gt 0 ]; then
      echo "orphan_branch: $b commits_ahead=$ahead"
    fi
  done

  echo "current_branch: $(git -C "$root" rev-parse --abbrev-ref HEAD)"
  if [ -n "$(git -C "$root" status --porcelain)" ]; then
    echo "worktree: dirty"
  else
    echo "worktree: clean"
  fi
fi
