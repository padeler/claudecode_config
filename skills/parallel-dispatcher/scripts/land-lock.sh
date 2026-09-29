#!/usr/bin/env bash
# Serializes landing (rebase + test + push to main) across slot workers.
# Separate from agent-mutex.sh: that lock guards dispatch decisions, this one
# guards the push to main, and holding one must never block the other.
#
# The repo is derived from the run file's path, never from cwd: agent shells
# reset cwd between calls, and a cwd inside another repo would lock that one.
#
# Usage (from anywhere):
#   land-lock.sh status  <state_dir>                   (<root>/.claude/dispatch)
#   land-lock.sh acquire <run_file> [timeout_min]
#       waits for the lock, touching <run_file> while waiting (heartbeat).
#       Blocks up to timeout_min (default 8) — give the Bash call a timeout
#       above that. exit 0 = taken (or already ours, refreshed), 1 = timed out
#       (call again)
#   land-lock.sh release <run_file>                    exit 0 = released, 1 = not ours
set -euo pipefail

usage() {
  echo "usage: $0 {status <state_dir>|acquire <run_file> [timeout_min]|release <run_file>}" >&2
  exit 2
}

cmd="${1:-}"
arg="${2:-}"
[ -n "$cmd" ] && [ -n "$arg" ] || usage

# <root>/.claude/dispatch[/runs/<id>.md] -> <root>
case "$cmd" in
  status)
    state_dir="$(cd "$arg" && pwd)"
    ;;
  acquire|release)
    [ -f "$arg" ] || { echo "error: run file not found: $arg" >&2; exit 2; }
    runs_dir="$(cd "$(dirname "$arg")" && pwd)"
    state_dir="$(dirname "$runs_dir")"
    [ "$(basename "$runs_dir")" = runs ] || { echo "error: not a run record (expected .../.claude/dispatch/runs/*.md): $arg" >&2; exit 2; }
    run_file="$runs_dir/$(basename "$arg")"
    ;;
  *) usage ;;
esac
case "$state_dir" in
  */.claude/dispatch) ;;
  *) echo "error: not a dispatch state dir (expected <root>/.claude/dispatch): $state_dir" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PD_ROOT="$(dirname "$(dirname "$state_dir")")"
. "$here/common.sh"

lockdir="$STATE_DIR/land-lock"
POLL_SECONDS=20

iso() { date -u +%FT%TZ; }
owner() { sed -n 's/^holder=//p' "$lockdir/owner" 2>/dev/null | head -1; }

# Age from the owner file's mtime; -1 when unreadable (mid-acquire or corrupt).
age_min() {
  [ -f "$lockdir/owner" ] || { echo -1; return; }
  echo $(( ($(date -u +%s) - $(stat -c %Y "$lockdir/owner")) / 60 ))
}

try_acquire() {
  local holder="$1" age
  if ! mkdir "$lockdir" 2>/dev/null; then
    age="$(age_min)"
    [ "$age" -ge "$DISPATCH_LAND_STALE_MINUTES" ] || return 1
    echo "reclaiming stale land lock: owner=$(owner) age_min=$age" >&2
    rm -f "$lockdir/owner"
    rmdir "$lockdir" 2>/dev/null || true
    mkdir "$lockdir" 2>/dev/null || return 1
  fi
  printf 'holder=%s\nstarted=%s\n' "$holder" "$(iso)" >"$lockdir/owner"
}

case "$cmd" in
  status)
    if [ -d "$lockdir" ]; then
      echo "land_lock: HELD owner=$(owner) age_min=$(age_min) stale_after_minutes=$DISPATCH_LAND_STALE_MINUTES"
    else
      echo "land_lock: free"
    fi
    ;;
  acquire)
    holder="$(field "$run_file" run_id)"
    [ -n "$holder" ] || { echo "error: run file has no run_id: $run_file" >&2; exit 2; }
    timeout_min="${3:-8}"
    if [ "$(owner)" = "$holder" ]; then
      # A resumed run re-entering its own landing, or a refresh during long
      # checks; keep it and reset its age.
      touch "$lockdir/owner"
      echo "land_lock: already ours holder=$holder repo=$ROOT"
      exit 0
    fi
    deadline=$(( $(date -u +%s) + timeout_min * 60 ))
    waited=0
    until try_acquire "$holder"; do
      if [ "$waited" -eq 0 ]; then
        echo "land_lock: waiting — held by $(owner) age_min=$(age_min)"
        waited=1
      fi
      touch "$run_file"
      if [ "$(date -u +%s)" -ge "$deadline" ]; then
        echo "land_lock: still HELD owner=$(owner) after ${timeout_min}m — call acquire again" >&2
        exit 1
      fi
      sleep "$POLL_SECONDS"
    done
    touch "$run_file"
    echo "land_lock: acquired holder=$holder repo=$ROOT"
    ;;
  release)
    holder="$(field "$run_file" run_id)"
    [ -d "$lockdir" ] || { echo "land_lock: free (nothing to release)"; exit 0; }
    if [ "$(owner)" != "$holder" ]; then
      echo "land_lock: NOT OURS owner=$(owner) holder=$holder — left alone" >&2
      exit 1
    fi
    rm -f "$lockdir/owner"
    rmdir "$lockdir"
    echo "land_lock: released holder=$holder"
    ;;
esac
