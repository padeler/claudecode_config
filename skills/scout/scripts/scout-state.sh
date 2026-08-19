#!/usr/bin/env bash
# Report scout state for the current project: lock, active/stale scans, focus
# areas already covered, current backlog size, worktree cleanliness.
# Read-only except for creating the state dir and the git exclude entry.
set -euo pipefail

STALE_MINUTES="${SCOUT_STALE_MINUTES:-45}"
COOLDOWN_DAYS="${SCOUT_AREA_COOLDOWN_DAYS:-7}"
BACKLOG_MAX="${SCOUT_BACKLOG_MAX:-15}"

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
dir="$root/.claude/scout"
scans="$dir/scans"
mkdir -p "$scans"

is_git=0
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  is_git=1
  # Keep scout state out of the repo without dirtying a tracked .gitignore.
  exclude="$(git -C "$root" rev-parse --git-path info/exclude)"
  # --git-path may return a path relative to the repo root, not to cwd.
  case "$exclude" in /*) ;; *) exclude="$root/$exclude" ;; esac
  mkdir -p "$(dirname "$exclude")"
  if ! grep -qxF '.claude/scout/' "$exclude" 2>/dev/null; then
    echo '.claude/scout/' >>"$exclude"
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
echo "area_cooldown_days: $COOLDOWN_DAYS"

if [ -d "$dir/lock" ]; then
  echo "lock: HELD owner=$(cat "$dir/lock/owner" 2>/dev/null || echo unknown)"
else
  echo "lock: free"
fi

now="$(date -u +%s)"
active=0
for f in "$scans"/*.md; do
  [ -e "$f" ] || continue
  status="$(sed -n 's/^status:[[:space:]]*//p' "$f" | head -1)"
  [ "$status" = "running" ] || continue
  active=1
  updated="$(sed -n 's/^updated:[[:space:]]*//p' "$f" | head -1)"
  area="$(sed -n 's/^area:[[:space:]]*//p' "$f" | head -1)"
  ts="$(date -u -d "$updated" +%s 2>/dev/null || echo 0)"
  age=$(( (now - ts) / 60 ))
  # Unparseable, in the future (clock skew / hand-edited), or simply old ->
  # nobody is credibly heartbeating this scan.
  if [ "$ts" -eq 0 ] || [ "$age" -lt 0 ] || [ "$age" -ge "$STALE_MINUTES" ]; then
    state=STALE
  else
    state=FRESH
  fi
  echo "scan: $state age_min=$age file=$f area=$area"
done
[ "$active" -eq 1 ] || echo "scan: none active"

# Coverage: last finished scan per area, newest first. Areas listed here are on
# cooldown unless nothing else is left.
cutoff=$(( now - COOLDOWN_DAYS * 86400 ))
for f in "$scans"/*.md; do
  [ -e "$f" ] || continue
  status="$(sed -n 's/^status:[[:space:]]*//p' "$f" | head -1)"
  [ "$status" = "running" ] && continue
  area="$(sed -n 's/^area:[[:space:]]*//p' "$f" | head -1)"
  updated="$(sed -n 's/^updated:[[:space:]]*//p' "$f" | head -1)"
  found="$(sed -n 's/^found:[[:space:]]*//p' "$f" | head -1)"
  ts="$(date -u -d "$updated" +%s 2>/dev/null || echo 0)"
  fresh=cold
  [ "$ts" -gt "$cutoff" ] && fresh=cooldown
  echo "covered: $area $fresh last=$updated status=$status found=${found:-0}"
done | sort -u

todo="$root/TODOs.md"
todo_items=0
if [ -f "$todo" ]; then
  todo_items="$(grep -c '^[[:space:]]*- \[ \]' "$todo" 2>/dev/null || true)"
  todo_items="${todo_items:-0}"
  echo "todos_file: $todo open_items=$todo_items"
else
  echo "todos_file: none"
fi

# The project "uses GitHub issues" when gh works here and the repo has issues
# enabled. That decides where findings are filed.
gh_issues=0
gh_enabled=false
if command -v gh >/dev/null 2>&1 && [ "$is_git" -eq 1 ] && \
   gh repo view --json hasIssuesEnabled --jq '.hasIssuesEnabled' 2>/dev/null | grep -qx true; then
  gh_enabled=true
  gh_issues="$(gh issue list --state open --limit 200 --json number --jq 'length' 2>/dev/null || echo 0)"
  echo "gh: available issues_enabled=true open_issues=$gh_issues"
else
  echo "gh: unavailable"
fi

if [ "$gh_enabled" = true ]; then
  echo "output: github-issues"
  open_items="$gh_issues"
else
  echo "output: todos-md path=$todo"
  open_items="$todo_items"
fi

if [ "$open_items" -ge "$BACKLOG_MAX" ]; then
  echo "backlog: FULL open_items=$open_items max=$BACKLOG_MAX"
else
  echo "backlog: ok open_items=$open_items max=$BACKLOG_MAX"
fi

if [ "$is_git" -eq 1 ]; then
  echo "current_branch: $(git -C "$root" rev-parse --abbrev-ref HEAD)"
  if [ -n "$(git -C "$root" status --porcelain)" ]; then
    echo "worktree: dirty"
  else
    echo "worktree: clean"
  fi
fi
