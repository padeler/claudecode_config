# Global Instructions

## Core Principles
- Avoid adding silent fallback logic; fail explicitly and throw clear exceptions.
- Prioritize strict typing and explicit return types.
- Keep diffs as minimal and surgically precise as possible—do not rewrite entire files for a minor change.
- always add logging and clear logs

## Style & Convention
- Write all code comments and documentation in English.
- Prefer functional programming principles (immutability, pure functions) unless an OOP wrapper is strictly required.
- Implement features with minimal code. Do not overengineer.
- If the codebase you are working on is poorly coded, don't follow bad examples and anti-patterns. Your additions should always be high quality, clean code.

## Running commands

Bash command logging to `/tmp/claude.log` is automatic via a `PreToolUse` hook
(`~/.claude/hooks/log-bash-command.sh`, registered in `~/.claude/settings.json`).
The hook appends a timestamped header with the command, then streams the
command's combined stdout/stderr through `tee -a /tmp/claude.log` so the output
can be followed live with `tail -f /tmp/claude.log`. Do not add manual
`tee`/redirects for this — the hook handles it (and skips any command that
already references `/tmp/claude.log`).

- The hook cannot know your intent, so when a command's purpose isn't obvious
  from the command itself, state it in your message before running it.
