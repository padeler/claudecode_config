#!/usr/bin/env bash
# Collect what the dispatcher and scout did since the last standup, and move the
# watermark once a report has been delivered.
#
#   standup-state.sh collect [--since <iso>]   # report data; never moves the mark
#   standup-state.sh mark [<iso>]              # set the watermark (default: now)
#
# Read-only except for the state dir, the git exclude entry, and `mark`.
set -euo pipefail

# How far back the very first standup looks, with no watermark to go on.
WINDOW_DAYS="${STANDUP_WINDOW_DAYS:-7}"
# Commits are the noisiest section; keep the report short.
MAX_COMMITS="${STANDUP_MAX_COMMITS:-30}"
MUTEX="$HOME/.claude/lib/agent-mutex.sh"

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
dir="$root/.claude/standup"
mark_file="$dir/last"
mkdir -p "$dir"

is_git=0
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  is_git=1
  # Keep standup state out of the repo without dirtying a tracked .gitignore.
  exclude="$(git -C "$root" rev-parse --git-path info/exclude)"
  # --git-path may return a path relative to the repo root, not to cwd.
  case "$exclude" in /*) ;; *) exclude="$root/$exclude" ;; esac
  mkdir -p "$(dirname "$exclude")"
  if ! grep -qxF '.claude/standup/' "$exclude" 2>/dev/null; then
    echo '.claude/standup/' >>"$exclude"
  fi
fi

epoch() { date -u -d "$1" +%s 2>/dev/null || echo 0; }
field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

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

# --- mark ---------------------------------------------------------------------
if [ "${1:-collect}" = "mark" ]; then
  # Default to the `until:` of the last collect, not a fresh now: the watermark
  # must be exactly where the delivered report stopped.
  when="${2:-$(cat "$dir/pending-until" 2>/dev/null || date -u +%FT%TZ)}"
  [ "$(epoch "$when")" -ne 0 ] || { echo "unparseable timestamp: $when" >&2; exit 2; }
  prev="$(cat "$mark_file" 2>/dev/null || echo none)"
  printf '%s\n' "$when" >"$mark_file"
  printf '%s reported window %s..%s\n' "$when" "$prev" "$when" >>"$dir/history.log"
  rm -f "$dir/pending-until"
  echo "mark: $when (was $prev)"
  exit 0
fi

[ "${1:-collect}" = "collect" ] || { echo "usage: $0 {collect [--since <iso>]|mark [<iso>]}" >&2; exit 2; }
shift || true

# --- window -------------------------------------------------------------------
since=""
source_kind=""
if [ "${1:-}" = "--since" ]; then
  since="${2:?--since needs a timestamp}"
  source_kind=argument
elif [ -s "$mark_file" ]; then
  since="$(head -1 "$mark_file")"
  source_kind=watermark
else
  since="$(date -u -d "$WINDOW_DAYS days ago" +%FT%TZ)"
  source_kind="default-window days=$WINDOW_DAYS"
fi

since_e="$(epoch "$since")"
[ "$since_e" -ne 0 ] || { echo "unparseable since: $since" >&2; exit 2; }
until_ts="$(date -u +%FT%TZ)"
after="$(date -u -d "@$((since_e + 1))" +%FT%TZ)"
# An ad-hoc --since window is a question about history, not a standup: it must
# not leave a watermark behind for `mark` to pick up.
if [ "$source_kind" != argument ]; then
  printf '%s\n' "$until_ts" >"$dir/pending-until"
fi

echo "root: $root"
echo "main_branch: $main_branch"
echo "since: $since source=$source_kind"
echo "until: $until_ts"
if [ "$source_kind" = watermark ]; then
  echo "first_standup: no"
else
  echo "first_standup: yes"
fi

# In-flight work comes from the shared mutex, so "still running" means exactly
# what it means to the dispatcher and scout themselves.
if [ -x "$MUTEX" ] || [ -f "$MUTEX" ]; then
  bash "$MUTEX" status | grep -E '^(lock|activity):' || true
else
  echo "activity: unavailable (missing $MUTEX)"
fi

# --- records closed or touched inside the window -------------------------------
# One line per run/scan, oldest first. `status` is the vocabulary the workers
# write: completed | blocked | failed | abandoned | running.
records() {
  local kind="$1" recs label out
  case "$kind" in
    dispatch) recs="$root/.claude/dispatch/runs"; label=task ;;
    scout)    recs="$root/.claude/scout/scans";   label=area ;;
  esac
  out="$(
    for f in "$recs"/*.md; do
      [ -e "$f" ] || continue
      upd="$(field "$f" updated)"
      found="$(field "$f" found)"
      [ "$(epoch "$upd")" -gt "$since_e" ] || continue
      if [ "$kind" = dispatch ]; then
        printf '%s\t%s: %s updated=%s attempts=%s branch=%s %s=%s file=%s\n' \
          "$upd" "$kind" "$(field "$f" status)" "$upd" "$(field "$f" attempts)" \
          "$(field "$f" branch)" "$label" "$(field "$f" "$label")" "$f"
      else
        printf '%s\t%s: %s updated=%s found=%s %s=%s file=%s\n' \
          "$upd" "$kind" "$(field "$f" status)" "$upd" "${found:-?}" \
          "$label" "$(field "$f" "$label")" "$f"
      fi
    done | sort | cut -f2-
  )"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    echo "$kind: none in window"
  fi
}

records dispatch
records scout

# --- what actually landed ------------------------------------------------------
if [ "$is_git" -eq 1 ] && git -C "$root" show-ref --verify --quiet "refs/heads/$main_branch"; then
  total="$(git -C "$root" rev-list --count --since="$after" "$main_branch" 2>/dev/null || echo 0)"
  if [ "$total" -gt 0 ]; then
    git -C "$root" log "$main_branch" --since="$after" --date=short \
      --max-count="$MAX_COMMITS" --format='commit: %h %ad %s'
    if [ "$total" -gt "$MAX_COMMITS" ]; then
      echo "commits_truncated: total=$total shown=$MAX_COMMITS"
    fi
  else
    echo "commit: none in window"
  fi

  for b in $(git -C "$root" for-each-ref --format='%(refname:short)' refs/heads/dispatch 2>/dev/null); do
    ahead="$(git -C "$root" rev-list --count "$main_branch..$b" 2>/dev/null || echo 0)"
    if [ "$ahead" -gt 0 ]; then
      echo "branch_unmerged: $b commits_ahead=$ahead"
    fi
  done
fi

# --- tracker movement ----------------------------------------------------------
if command -v gh >/dev/null 2>&1 && [ "$is_git" -eq 1 ]; then
  gh issue list --state all --limit 200 \
    --json number,title,state,createdAt,closedAt 2>/dev/null | \
    jq -r --arg since "$since" '
      .[] | select((.closedAt // "") > $since)
          | "issue_closed: #\(.number) \(.title)"' 2>/dev/null || true
  gh issue list --state all --limit 200 \
    --json number,title,state,createdAt,closedAt 2>/dev/null | \
    jq -r --arg since "$since" '
      .[] | select(.createdAt > $since)
          | "issue_opened: #\(.number) \(.title)"' 2>/dev/null || true
fi

todo="$root/TODOs.md"
if [ -f "$todo" ]; then
  open_now="$(grep -c '^[[:space:]]*- \[ \]' "$todo" 2>/dev/null || true)"
  filed=0
  ticked=0
  if [ "$is_git" -eq 1 ]; then
    # Added checkbox lines in the window: unchecked = filed by scout,
    # checked = ticked off by a dispatch worker.
    diff_lines="$(git -C "$root" log --since="$after" -p -- TODOs.md 2>/dev/null || true)"
    filed="$(printf '%s\n' "$diff_lines" | grep -cE '^\+[[:space:]]*- \[ \]' || true)"
    ticked="$(printf '%s\n' "$diff_lines" | grep -cE '^\+[[:space:]]*- \[[xX]\]' || true)"
  fi
  echo "todos: open_now=${open_now:-0} filed_in_window=${filed:-0} ticked_in_window=${ticked:-0}"
else
  echo "todos: no file"
fi
