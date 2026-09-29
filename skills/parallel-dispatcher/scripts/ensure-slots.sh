#!/usr/bin/env bash
# Make every slot worktree exist and be ready for a new run. Idempotent: safe
# on every dispatcher tick; healthy slots are left as they are.
#
# Busy slots (a running/blocked/failed run owns them) are never touched.
# Free slots are moved to the current base, cleaned, and have their untracked
# config copied in and their dependencies installed when the lockfiles changed.
#
# Prints one `slot: N free|busy|broken ...` line per slot. Exit 1 if any slot
# is broken; the others are still prepared and usable.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/common.sh"

require_origin
ensure_state_dirs
main="$(main_branch)"
base="origin/$main"
git -C "$ROOT" fetch --quiet origin
git -C "$ROOT" worktree prune

# Resolve the setup command and the files whose hash decides a reinstall.
# Explicit config wins; otherwise only unambiguous lockfiles are trusted.
setup_cmd="$DISPATCH_SLOT_SETUP"
deps_files="$DISPATCH_SLOT_DEPS_FILES"
if [ -z "$setup_cmd" ]; then
  declare -a cmds=() files=()
  has() { git -C "$ROOT" cat-file -e "$base:$1" 2>/dev/null; }
  if   has pnpm-lock.yaml;    then cmds+=("pnpm install --frozen-lockfile"); files+=(pnpm-lock.yaml)
  elif has yarn.lock;         then cmds+=("yarn install --frozen-lockfile"); files+=(yarn.lock)
  elif has package-lock.json; then cmds+=("npm ci");                         files+=(package-lock.json)
  elif has package.json;      then
    echo "error: package.json without a lockfile — set DISPATCH_SLOT_SETUP in $CONFIG_FILE" >&2; exit 2
  fi
  if   has uv.lock;     then cmds+=("uv sync --frozen");            files+=(uv.lock)
  elif has poetry.lock; then cmds+=("poetry install --no-interaction"); files+=(poetry.lock)
  elif has pyproject.toml || has requirements.txt; then
    echo "error: Python project without uv.lock/poetry.lock — set DISPATCH_SLOT_SETUP (or =none) in $CONFIG_FILE" >&2; exit 2
  fi
  if [ "${#cmds[@]}" -gt 0 ]; then
    setup_cmd="$(printf '%s && ' "${cmds[@]}")"; setup_cmd="${setup_cmd% && }"
    deps_files="${files[*]}"
  else
    setup_cmd=none
  fi
elif [ "$setup_cmd" != none ] && [ -z "$deps_files" ]; then
  echo "error: DISPATCH_SLOT_SETUP is set but DISPATCH_SLOT_DEPS_FILES is empty — list the files whose change requires a reinstall" >&2
  exit 2
fi

# Copied files must be gitignored, or a worker's `git add -A` would commit them.
for c in $DISPATCH_SLOT_COPY; do
  [ -e "$ROOT/$c" ] || { echo "error: DISPATCH_SLOT_COPY entry missing in root: $c" >&2; exit 2; }
  git -C "$ROOT" check-ignore -q "$c" || { echo "error: DISPATCH_SLOT_COPY entry is not gitignored: $c" >&2; exit 2; }
done

deps_hash() {
  local p="$1" f
  [ -n "$deps_files" ] || { echo none; return; }
  for f in $deps_files; do
    if [ -f "$p/$f" ]; then sha256sum "$p/$f"; else echo "absent $f"; fi
  done | sha256sum | cut -d' ' -f1
}

prepare_slot() {
  local n="$1" p hash_file
  p="$(slot_path "$n")"
  hash_file="$SLOT_STATE_DIR/$n.deps-hash"

  if [ ! -d "$p" ]; then
    mkdir -p "$DISPATCH_SLOTS_DIR"
    git -C "$ROOT" worktree add --quiet --detach "$p" "$base"
    rm -f "$hash_file"
    echo "info: slot $n created at $p" >&2
  elif ! is_registered_worktree "$p"; then
    # Never delete an unknown directory; it may be someone's work.
    echo "slot: $n broken reason=not-a-worktree path=$p"
    return 1
  fi

  # Leftovers from a finished or abandoned run are stashed, not destroyed.
  # The stash list is shared by all worktrees, so it stays recoverable.
  if [ -n "$(git -C "$p" status --porcelain)" ]; then
    git -C "$p" stash push --include-untracked --quiet -m "ensure-slots slot $n $(date -u +%FT%TZ)"
    echo "info: slot $n had leftover changes — stashed" >&2
  fi
  git -C "$p" checkout --quiet --detach "$base"
  git -C "$p" clean -fdq

  for c in $DISPATCH_SLOT_COPY; do
    mkdir -p "$(dirname "$p/$c")"
    cmp -s "$ROOT/$c" "$p/$c" 2>/dev/null || cp -a "$ROOT/$c" "$p/$c"
  done

  if [ "$setup_cmd" != none ]; then
    local want
    want="$(deps_hash "$p")"
    if [ "$want" != "$(cat "$hash_file" 2>/dev/null || true)" ]; then
      local log="$SLOT_STATE_DIR/$n.setup.log"
      echo "info: slot $n installing dependencies: $setup_cmd" >&2
      if ! (cd "$p" && bash -c "$setup_cmd") >"$log" 2>&1; then
        echo "slot: $n broken reason=setup-failed log=$log"
        tail -n 20 "$log" >&2
        return 1
      fi
      echo "$want" >"$hash_file"
    fi
  fi
  echo "slot: $n free path=$p"
}

rc=0
for n in $(seq 1 "$DISPATCH_SLOTS"); do
  if owner="$(slot_owner "$n")"; then
    echo "slot: $n busy ${owner%% *} run=${owner#* }"
    continue
  fi
  prepare_slot "$n" || rc=1
done
exit "$rc"
