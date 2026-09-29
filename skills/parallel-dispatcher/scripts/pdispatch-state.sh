#!/usr/bin/env bash
# Report parallel-dispatcher state: shared lock, land lock, active runs, slots,
# docs debt (batch count + urgent flags), orphan branches, root checkout state.
# Writes only inside .claude/dispatch/ (state dirs, first-run watermark) plus a
# `git fetch` so the base ref is current.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/common.sh"
MUTEX="$HOME/.claude/lib/agent-mutex.sh"

require_origin
github="$(require_github)"
ensure_state_dirs
main="$(main_branch)"
base="origin/$main"

if ! git -C "$ROOT" fetch --quiet origin 2>/dev/null; then
  echo "warn: git fetch origin failed — base ref may be behind"
fi

echo "root: $ROOT"
echo "github: $github"
echo "main_branch: $main"
echo "base: $base $(git -C "$ROOT" rev-parse --short "$base")"
echo "slots_dir: $DISPATCH_SLOTS_DIR slots=$DISPATCH_SLOTS"
echo "stale_after_minutes: $DISPATCH_STALE_MINUTES"

# The decision lock is shared with scout; agent-mutex resolves the root from
# cwd, so run it from the main checkout.
(cd "$ROOT" && bash "$MUTEX" lock && bash "$MUTEX" peer scout)
bash "$here/land-lock.sh" status "$STATE_DIR"

now="$(date -u +%s)"
declare -A branch_has_record=()
found=0
for f in "$RUNS_DIR"/*.md; do
  [ -e "$f" ] || continue
  b="$(field "$f" branch)"
  [ -n "$b" ] && branch_has_record["$b"]=1
  status="$(field "$f" status)"
  kind="$(field "$f" kind)"
  slot="$(field "$f" slot)"
  task="$(field "$f" task)"
  issue="$(field "$f" issue)"
  case "$status" in
    running)
      found=1
      # Heartbeat = file mtime; the worker proves it is alive by writing.
      age=$(( (now - $(stat -c %Y "$f")) / 60 ))
      [ "$age" -lt 0 ] && age=0
      if [ "$age" -ge "$DISPATCH_STALE_MINUTES" ]; then state=STALE; else state=FRESH; fi
      echo "run: $state kind=$kind issue=$issue slot=$slot age_min=$age attempts=$(field "$f" attempts) file=$f branch=$b task=$task"
      ;;
    blocked|failed)
      found=1
      echo "run: ${status^^} kind=$kind issue=$issue slot=$slot file=$f branch=$b task=$task (holds its slot until set to abandoned)"
      ;;
  esac
done
[ "$found" -eq 1 ] || echo "run: none active"

# Slots: status only; ensure-slots.sh is what repairs them.
git -C "$ROOT" worktree prune
for n in $(seq 1 "$DISPATCH_SLOTS"); do
  p="$(slot_path "$n")"
  if owner="$(slot_owner "$n")"; then
    echo "slot: $n busy ${owner%% *} run=${owner#* }"
  elif [ ! -d "$p" ]; then
    echo "slot: $n missing"
  elif ! is_registered_worktree "$p"; then
    echo "slot: $n broken reason=not-a-worktree path=$p"
  else
    echo "slot: $n free"
  fi
done

# Docs debt. The watermark is the last base commit whose changes the docs
# cover; on first run everything already on main counts as documented.
if [ ! -f "$WATERMARK_FILE" ]; then
  git -C "$ROOT" rev-parse "$base" >"$WATERMARK_FILE"
  echo "docs_watermark: initialized to $base"
fi
wm="$(cat "$WATERMARK_FILE")"
echo "docs_watermark: $(git -C "$ROOT" rev-parse --short "$wm")"
pending=0
for f in "$RUNS_DIR"/*.md; do
  [ -e "$f" ] || continue
  [ "$(field "$f" status)" = "completed" ] || continue
  [ "$(field "$f" kind)" = "task" ] || continue
  sha="$(field "$f" merged)"
  if [ -z "$sha" ] || ! git -C "$ROOT" cat-file -e "$sha^{commit}" 2>/dev/null; then
    echo "warn: completed run has no resolvable merged: sha file=$f"
    continue
  fi
  git -C "$ROOT" merge-base --is-ancestor "$sha" "$wm" && continue
  pending=$((pending + 1))
  docs="$(field "$f" docs)"
  case "$docs" in
    urgent*) echo "docs_urgent: file=$f sha=${sha:0:9} note=${docs#urgent}" ;;
  esac
done
echo "docs_pending: $pending every=$DISPATCH_DOCS_EVERY"

# Branches with work but no run record: abandoned by a dispatcher that died
# between creating the branch and writing the record.
for b in $(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/heads/dispatch); do
  [ -n "${branch_has_record[$b]:-}" ] && continue
  ahead="$(git -C "$ROOT" rev-list --count "$base..$b")"
  [ "$ahead" -gt 0 ] && echo "orphan_branch: $b commits_ahead=$ahead"
done

# The root checkout is the user's; workers never touch it. Report only.
echo "root_branch: $(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  echo "root_worktree: dirty"
else
  echo "root_worktree: clean behind=$(git -C "$ROOT" rev-list --count "HEAD..$base")"
fi
