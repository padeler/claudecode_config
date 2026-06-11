#!/usr/bin/env bash
# Colorizing viewer for /tmp/claude.log (the Bash-command log produced by
# log-bash-command.sh). Keeps the on-disk log plain; all color is applied here
# at display time so grep/jq/copy-paste of the raw file stay clean.
#
# Usage:
#   viewlog.sh           # follow the log (like `tail -f`), colorized
#   viewlog.sh -a        # show the whole file from the top, then follow
#   viewlog.sh -n 200    # follow, starting from the last 200 lines
#
# Highlights:
#   - command headers ("[ts] $ cmd")  -> bold cyan, with a dim rule above
#   - error-ish output lines           -> red
#   - warning-ish output lines         -> yellow
#   - everything else                  -> default
#
# Implementation note: colorization is done in a bash `while read` loop on
# purpose. The system awk on Debian/Ubuntu is mawk, which block-buffers its
# *input*; piped through `tail -f` it shows nothing until a full block arrives.
# `read` is line-buffered, so a live follow updates line by line.
set -euo pipefail

readonly LOG_FILE="${CLAUDE_LOG_FILE:-/tmp/claude.log}"

tail_args=(-n 10 -f)
force_color=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--all)   tail_args=(-n +1 -f) ;;
    -n)         tail_args=(-n "$2" -f); shift ;;
    -c|--color) force_color=1 ;;    # force color even when stdout isn't a tty (e.g. `| less -R`)
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# ANSI codes (only emit if stdout is a terminal, unless -c is given, so a
# piped/redirected view stays plain and greppable by default).
if [[ -t 1 || "$force_color" == 1 ]]; then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  CYAN=$'\033[36m'; RED=$'\033[31m'; YELLOW=$'\033[33m'
else
  RESET=''; BOLD=''; DIM=''; CYAN=''; RED=''; YELLOW=''
fi
readonly RULE="${DIM}──────────────────────────────────────────────────────${RESET}"

# Fail explicitly if the log isn't there yet rather than hanging silently.
if [[ ! -e "$LOG_FILE" ]]; then
  printf 'viewlog: %s does not exist yet\n' "$LOG_FILE" >&2
  exit 1
fi

# Regexes. The header pattern matches the exact format written by the hook:
# "[YYYY-MM-DD HH:MM:SS] $ ".
readonly RE_HEADER='^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] \$ '
readonly RE_ERROR='([Ee]rror|ERROR|[Ff]ail(ed|ure)?|FAIL|[Tt]raceback|[Ee]xception|fatal|panic|[Dd]enied|[Nn]ot found)'
readonly RE_WARN='([Ww]arn(ing)?|WARN|[Dd]eprecat)'

tail "${tail_args[@]}" "$LOG_FILE" | while IFS= read -r line; do
  if [[ "$line" =~ $RE_HEADER ]]; then
    printf '%s\n%s%s%s\n' "$RULE" "$BOLD$CYAN" "$line" "$RESET"
  elif [[ "$line" =~ $RE_ERROR ]]; then
    printf '%s%s%s\n' "$RED" "$line" "$RESET"
  elif [[ "$line" =~ $RE_WARN ]]; then
    printf '%s%s%s\n' "$YELLOW" "$line" "$RESET"
  else
    printf '%s\n' "$line"
  fi
done
