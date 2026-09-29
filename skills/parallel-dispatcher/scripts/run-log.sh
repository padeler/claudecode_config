#!/usr/bin/env bash
# Heartbeat + edit helper for run records. Every call refreshes `updated:` with
# the real UTC time, which (through the file's mtime) is the run's heartbeat.
#
# Usage:
#   run-log.sh log <run_file> <message>        append "- HH:MM <message>" to ## Log
#   run-log.sh set <run_file> <field> <value>  set a frontmatter field (added if absent)
#   run-log.sh touch <run_file>                heartbeat only
set -euo pipefail

cmd="${1:?usage: run-log.sh log|set|touch <run_file> ...}"
file="${2:?run file required}"
[ -f "$file" ] || { echo "error: run file not found: $file" >&2; exit 2; }

# Replace (or insert before the closing ---) one frontmatter field.
set_field() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp "$file.XXXXXX")"
  awk -v key="$key" -v value="$value" '
    BEGIN { fm = 0; done = 0 }
    /^---$/ {
      fm++
      if (fm == 2 && !done) { print key ": " value; done = 1 }
      print; next
    }
    fm == 1 && index($0, key ":") == 1 && !done { print key ": " value; done = 1; next }
    { print }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

case "$cmd" in
  log)
    msg="${3:?log needs a message}"
    printf -- '- %s %s\n' "$(date -u +%H:%M)" "$msg" >>"$file"
    ;;
  set)
    key="${3:?set needs a field}"
    value="${4?set needs a value}"
    [ "$key" = updated ] && { echo "error: updated: is managed by this script" >&2; exit 2; }
    set_field "$key" "$value"
    ;;
  touch) ;;
  *) echo "usage: run-log.sh {log|set|touch} <run_file> ..." >&2; exit 2 ;;
esac
set_field updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "run-log: $cmd ok ($(basename "$file"))"
