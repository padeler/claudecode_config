---
name: wrapup
description: Use at the end of a work session to review what changed and update CLAUDE.md, README.md, and any other relevant documentation so it reflects the current state of the code. Invoke when the user says "wrap up", "wrapup", or asks to refresh docs before ending a session.
---

# Wrap Up

Review the work done in this session and bring the project's documentation back
in sync with the code. Make only the changes the session's work actually warrants
— do not rewrite docs wholesale or invent content.

## Steps

1. **Survey what changed.** Inspect the session's changes:
   - Run `git status` and `git diff` (and `git diff --staged`) if this is a git repo.
   - Otherwise rely on the files edited during this session.
   - Summarize, for yourself, what was added, removed, or changed in behavior.

2. **Identify docs that may be stale.** Look for and read, if present:
   - `CLAUDE.md` (and any nested `**/CLAUDE.md`)
   - `README.md` (and `README.*` variants)
   - `docs/` directory, `CHANGELOG.md`
   - Inline module/package docs or usage examples tied to changed code

3. **Update only what is now inaccurate or missing.** For each doc:
   - Fix descriptions, commands, file paths, config keys, and examples that no
     longer match the code.
   - Add documentation for genuinely new features, commands, env vars, or setup steps.
   - Remove docs for things that were deleted.
   - Keep edits minimal and surgical — match the existing tone and structure.
   - Do NOT add changelog entries or version bumps unless the project clearly
     maintains them and the change warrants it.

4. **Do not fabricate.** If something is unclear or you cannot verify it from the
   code, leave it alone and flag it rather than guessing.

5. **Report.** Give a concise summary of:
   - Which docs you updated and why.
   - Anything you noticed that looks stale but you were unsure about (so the user
     can decide).
   - Confirm if no documentation changes were needed.
