#!/usr/bin/env bash
# Shared helpers for the parallel-dispatcher scripts. Source it; do not run it.
#
# Resolves the main repo root even from inside a slot worktree, loads the
# per-project config, and computes slot ownership from the run records.

set -euo pipefail

# The main checkout, not the current worktree: `--show-toplevel` inside a slot
# would return the slot, and every slot must share one state directory.
pd_root() {
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
    echo "error: not inside a git repository" >&2
    return 1
  }
  dirname "$common"
}

# PD_ROOT lets callers that know the repo from a path (land-lock.sh, via the
# run file) skip cwd resolution: agent shells reset cwd between calls.
ROOT="${PD_ROOT:-$(pd_root)}"
STATE_DIR="$ROOT/.claude/dispatch"
RUNS_DIR="$STATE_DIR/runs"
SLOT_STATE_DIR="$STATE_DIR/slots"
CONFIG_FILE="$STATE_DIR/config.sh"
WATERMARK_FILE="$STATE_DIR/docs-watermark"

# Precedence: config file > environment > default.
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  . "$CONFIG_FILE"
fi
DISPATCH_SLOTS="${DISPATCH_SLOTS:-3}"
DISPATCH_SLOTS_DIR="${DISPATCH_SLOTS_DIR:-$(dirname "$ROOT")/$(basename "$ROOT").slots}"
DISPATCH_SLOT_SETUP="${DISPATCH_SLOT_SETUP:-}"
DISPATCH_SLOT_DEPS_FILES="${DISPATCH_SLOT_DEPS_FILES:-}"
DISPATCH_SLOT_COPY="${DISPATCH_SLOT_COPY:-}"
DISPATCH_DOCS_EVERY="${DISPATCH_DOCS_EVERY:-5}"
DISPATCH_STALE_MINUTES="${DISPATCH_STALE_MINUTES:-45}"
DISPATCH_LAND_STALE_MINUTES="${DISPATCH_LAND_STALE_MINUTES:-30}"
DISPATCH_CONFLICT_ROUNDS="${DISPATCH_CONFLICT_ROUNDS:-3}"

field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

main_branch() {
  local head_ref
  head_ref="$(git -C "$ROOT" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$head_ref" ]; then
    echo "${head_ref##*/}"
  elif git -C "$ROOT" show-ref --verify --quiet refs/heads/main; then
    echo main
  elif git -C "$ROOT" show-ref --verify --quiet refs/heads/master; then
    echo master
  else
    echo "error: cannot determine the main branch" >&2
    return 1
  fi
}

# Workers land with `git push origin HEAD:<main>`, so a remote is mandatory.
require_origin() {
  git -C "$ROOT" remote get-url origin >/dev/null 2>&1 || {
    echo "error: no 'origin' remote — parallel-dispatcher lands work by pushing to it" >&2
    return 1
  }
}

# Tasks come only from GitHub issues: a shared tracker file would be edited by
# every landing and conflict constantly. Prints the "owner/name" of the repo.
require_github() {
  command -v gh >/dev/null 2>&1 || {
    echo "error: gh (GitHub CLI) is required — parallel-dispatcher takes tasks from GitHub issues only" >&2
    return 1
  }
  gh auth status >/dev/null 2>&1 || {
    echo "error: gh is not authenticated — run 'gh auth login'" >&2
    return 1
  }
  (cd "$ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "error: $ROOT is not a GitHub repository gh can access — parallel-dispatcher needs GitHub issues" >&2
    return 1
  }
}

slot_path() { echo "$DISPATCH_SLOTS_DIR/$1"; }

# Statuses that keep a slot reserved. blocked/failed hold it so the user can
# inspect the work; setting the record to `abandoned` frees it.
slot_owner() {
  local n="$1" f status
  for f in "$RUNS_DIR"/*.md; do
    [ -e "$f" ] || continue
    [ "$(field "$f" slot)" = "$n" ] || continue
    status="$(field "$f" status)"
    case "$status" in
      running|blocked|failed) echo "$status $f"; return 0 ;;
    esac
  done
  return 1
}

is_registered_worktree() {
  git -C "$ROOT" worktree list --porcelain | grep -qxF "worktree $1"
}

ensure_state_dirs() {
  mkdir -p "$RUNS_DIR" "$SLOT_STATE_DIR"
  local exclude
  exclude="$(git -C "$ROOT" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$(dirname "$exclude")"
  grep -qxF '.claude/dispatch/' "$exclude" 2>/dev/null || echo '.claude/dispatch/' >>"$exclude"
}
