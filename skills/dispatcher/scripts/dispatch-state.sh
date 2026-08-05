#!/usr/bin/env bash
# Report dispatcher state for the current project: lock, active/stale runs,
# orphan dispatch branches, worktree cleanliness.
# Read-only except for creating the state dir and the git exclude entry.
set -euo pipefail

STALE_MINUTES="${DISPATCH_STALE_MINUTES:-45}"

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

if [ -d "$dir/lock" ]; then
  echo "lock: HELD owner=$(cat "$dir/lock/owner" 2>/dev/null || echo unknown)"
else
  echo "lock: free"
fi

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
  ts="$(date -u -d "$updated" +%s 2>/dev/null || echo 0)"
  age=$(( (now - ts) / 60 ))
  # Unparseable, in the future (clock skew / hand-edited), or simply old ->
  # nobody is credibly heartbeating this run.
  if [ "$ts" -eq 0 ] || [ "$age" -lt 0 ] || [ "$age" -ge "$STALE_MINUTES" ]; then
    state=STALE
  else
    state=FRESH
  fi
  echo "run: $state age_min=$age file=$f branch=$branch task=$task"
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
