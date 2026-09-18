# Claude Code config

## Notes

### Log hook

To enable the hook:

1. Add this section in CLAUDE.md:
```markdown 
## Running commands

- A `PreToolUse` hook (`~/.claude/hooks/log-bash-command.sh`, registered in `~/.claude/settings.json`) logs every bash command and its combined output to `/tmp/claude.log` (follow live with `tail -f`). Never add manual `tee`/redirects for this.
- The hook can't know intent — state a command's purpose in your message when it isn't obvious from the command itself.
```

2. Enable the hook in settings:

```json
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/home/padeler/.claude/hooks/log-bash-command.sh",
            "statusMessage": "Logging command to /tmp/claude.log"
          }
        ]
      }
    ]
  },
```
