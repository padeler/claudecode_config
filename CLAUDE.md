# Global Instructions

## Core Principles

- Clean, readable, maintainable code is preferred over short code.
- Minimal scope: implement what was asked, no overengineering.
- No silent fallbacks; fail explicitly with clear exceptions.
- Strict typing, explicit return types.
- Minimal, surgical diffs — never rewrite a file for a small change.
- Always add informative logging.

## Style

- English for all comments and documentation.
- Prefer functional style (immutability, pure functions) unless an OOP wrapper is required.
- In poorly written codebases, don't copy the anti-patterns — your additions stay clean.

## Documentation

- When unsure about a lib/tool, read the docs *for that version* — use context7 MCP or online sources.
- Markdown and comments: brief and precise, easy to parse fast.
- In markdown, prefer bullet points over prose.

## Git

- Branch per feature/fix; never commit to main. Squash on merge.
- Wait for confirmation before committing, unless told otherwise.

## Features/Bugs/Issues

- Use `gh` for issues if available and the repo is on GitHub; otherwise PLAN.md, IMPLEMENTATION.md (large work) or TODOs.md (small work).
- Wait for confirmation after creating issues/plans/todos, before implementing.

