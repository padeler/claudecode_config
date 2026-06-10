#!/usr/bin/env bash
# PreToolUse hook for the Bash tool.
# Goal: every Bash command and its (live) output is logged to /tmp/claude.log,
# while still streaming to the terminal in real time (so `tail -f` works) and
# preserving the command's real exit code.
#
# Strategy:
#   1. Read the tool payload from stdin.
#   2. Append a timestamped header (the command text) to the log directly.
#   3. Rewrite the command to pipe combined stdout+stderr through `tee -a`,
#      keeping the original command's exit status via PIPESTATUS.
set -euo pipefail

readonly LOG_FILE="/tmp/claude.log"

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

# No command (non-Bash payload / empty) -> pass through untouched.
if [[ -z "$cmd" ]]; then
  exit 0
fi

# Already wired to the log (e.g. a manual `tee -a /tmp/claude.log`) -> don't
# double-wrap; pass through untouched.
if [[ "$cmd" == *"$LOG_FILE"* ]]; then
  exit 0
fi

# 2. Write the header ourselves; no need to shell-escape the command into a string.
printf '\n[%s] $ %s\n' "$(date '+%F %T')" "$cmd" >> "$LOG_FILE"

# 3. Rewrite: run the original command, tee combined output, keep its exit code.
new_cmd="{ ${cmd}
} 2>&1 | tee -a ${LOG_FILE}; exit \${PIPESTATUS[0]}"

jq -n --arg c "$new_cmd" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    updatedInput: { command: $c }
  }
}'
