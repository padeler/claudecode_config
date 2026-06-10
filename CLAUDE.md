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

