#!/usr/bin/env bash
# Shared mutex + cross-visibility for the dispatcher and scout skills.
#
# Both skills dispatch one background agent per project. Only one of them may be
# active at a time, so they share:
#   * one lock directory  -> .claude/agent-lock/   (held only while deciding)
#   * one activity view   -> the peer's own run/scan records (the long signal)
#
# Usage (run from anywhere inside the project):
#   agent-mutex.sh status                 # lock + both activity lines
#   agent-mutex.sh lock                   # just the "lock: ..." line
#   agent-mutex.sh peer   <dispatch|scout>  # one "peer: ..." line for that kind
#   agent-mutex.sh acquire <holder>       # exit 0 = taken, 1 = someone else has it
#   agent-mutex.sh release <holder>       # exit 0 = released, 1 = not ours
set -euo pipefail

# A lock is only held across a decision + dispatch, so anything older than this
# belongs to a session that died mid-decision and may be reclaimed.
LOCK_STALE_MINUTES="${AGENT_LOCK_STALE_MINUTES:-15}"

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
lockdir="$root/.claude/agent-lock"

now() { date -u +%s; }
iso() { date -u +%FT%TZ; }

# Keep the shared lock out of the repo without dirtying a tracked .gitignore.
ensure_excluded() {
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local exclude
  exclude="$(git -C "$root" rev-parse --git-path info/exclude)"
  # --git-path may return a path relative to the repo root, not to cwd.
  case "$exclude" in /*) ;; *) exclude="$root/$exclude" ;; esac
  mkdir -p "$(dirname "$exclude")"
  grep -qxF '.claude/agent-lock/' "$exclude" 2>/dev/null || \
    echo '.claude/agent-lock/' >>"$exclude"
}

field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

# Minutes since an ISO-8601 timestamp. Unparseable or in the future -> -1, which
# every caller treats as "nobody is credibly heartbeating this".
age_min() {
  local ts
  ts="$(date -u -d "$1" +%s 2>/dev/null || echo 0)"
  if [ "$ts" -eq 0 ]; then echo -1; return; fi
  local age=$(( ( $(now) - ts ) / 60 ))
  if [ "$age" -lt 0 ]; then echo -1; else echo "$age"; fi
}

lock_owner() { [ -f "$lockdir/owner" ] && sed -n 's/^holder=//p' "$lockdir/owner" | head -1 || echo unknown; }
lock_age()   { [ -f "$lockdir/owner" ] && age_min "$(sed -n 's/^started=//p' "$lockdir/owner" | head -1)" || echo -1; }

lock_status() {
  if [ ! -d "$lockdir" ]; then
    echo "lock: free"
    return
  fi
  local owner age
  owner="$(lock_owner)"
  age="$(lock_age)"
  if [ "$age" -lt 0 ] || [ "$age" -ge "$LOCK_STALE_MINUTES" ]; then
    echo "lock: STALE owner=$owner age_min=$age stale_after_minutes=$LOCK_STALE_MINUTES"
  else
    echo "lock: HELD owner=$owner age_min=$age"
  fi
}

# One line per kind: is the *other* skill's agent in flight right now?
# FRESH = running and heartbeating, STALE = its agent died, none = idle.
activity() {
  local kind="$1" prefix="$2" recs label stale
  case "$kind" in
    dispatch) recs="$root/.claude/dispatch/runs"; label=task
              stale="${DISPATCH_STALE_MINUTES:-45}" ;;
    scout)    recs="$root/.claude/scout/scans";   label=area
              stale="${SCOUT_STALE_MINUTES:-45}" ;;
    *) echo "unknown kind: $kind" >&2; return 2 ;;
  esac

  local -a lines=()
  local f status upd age state
  for f in "$recs"/*.md; do
    [ -e "$f" ] || continue
    status="$(field "$f" status)"
    [ "$status" = "running" ] || continue
    upd="$(field "$f" updated)"
    age="$(age_min "$upd")"
    if [ "$age" -lt 0 ] || [ "$age" -ge "$stale" ]; then state=STALE; else state=FRESH; fi
    lines+=("$prefix: $kind $state age_min=$age file=$f $label=$(field "$f" "$label")")
  done

  if [ "${#lines[@]}" -eq 0 ]; then
    echo "$prefix: $kind none"
  else
    printf '%s\n' "${lines[@]}"
  fi
}

cmd="${1:-status}"
case "$cmd" in
  status)
    echo "root: $root"
    lock_status
    activity dispatch activity
    activity scout activity
    ;;
  lock)
    lock_status
    ;;
  peer)
    activity "${2:?peer needs a kind: dispatch|scout}" peer
    ;;
  acquire)
    holder="${2:?acquire needs a holder name}"
    ensure_excluded
    mkdir -p "$(dirname "$lockdir")"
    if ! mkdir "$lockdir" 2>/dev/null; then
      age="$(lock_age)"
      if [ "$age" -lt 0 ] || [ "$age" -ge "$LOCK_STALE_MINUTES" ]; then
        echo "reclaiming stale lock: owner=$(lock_owner) age_min=$age" >&2
        rm -f "$lockdir/owner"
        rmdir "$lockdir" 2>/dev/null || true
      fi
      if ! mkdir "$lockdir" 2>/dev/null; then
        lock_status
        exit 1
      fi
    fi
    printf 'holder=%s\nstarted=%s\npid=%s\n' "$holder" "$(iso)" "$$" >"$lockdir/owner"
    echo "lock: acquired holder=$holder"
    ;;
  release)
    holder="${2:?release needs a holder name}"
    if [ ! -d "$lockdir" ]; then
      echo "lock: free (nothing to release)"
      exit 0
    fi
    owner="$(lock_owner)"
    if [ "$owner" != "$holder" ]; then
      echo "lock: NOT OURS owner=$owner holder=$holder — left alone" >&2
      exit 1
    fi
    rm -f "$lockdir/owner"
    rmdir "$lockdir"
    echo "lock: released holder=$holder"
    ;;
  *)
    echo "usage: $0 {status|lock|peer <dispatch|scout>|acquire <holder>|release <holder>}" >&2
    exit 2
    ;;
esac
