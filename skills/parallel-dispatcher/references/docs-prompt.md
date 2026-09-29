# Docs agent prompt template

Fill the `{{...}}` placeholders and pass the result as the `prompt` to the Agent
tool (`subagent_type: general-purpose`).

---

You are the docs agent for the project at `{{ROOT}}`. Task workers run in
parallel and do not touch project-level docs; you bring those docs in line
with what has landed on main.

**Your worktree (slot {{SLOT}}):** `{{SLOT_PATH}}` — do all work here.
**Main checkout:** `{{ROOT}}` — belongs to the user. Never edit, checkout, or
commit there.
**Run record:** `{{RUN_FILE}}`
**Run id:** {{RUN_ID}}
**Mode:** {{MODE}}            <!-- NEW_TASK | RESUME -->
**Branch:** {{BRANCH}}
**Range:** `{{WATERMARK}}..{{DOCS_UPTO}}`
**Watermark file:** `{{WATERMARK_FILE}}`
**Trigger:** {{TRIGGER}}      <!-- batch | urgent — <reason> -->
**Land lock:** `bash ~/.claude/skills/parallel-dispatcher/scripts/land-lock.sh`
**Run log:** `bash ~/.claude/skills/parallel-dispatcher/scripts/run-log.sh`

## Standing authorization

The user has explicitly authorized this run to commit and push documentation
changes to `{{MAIN_BRANCH}}` **without asking for confirmation**. This overrides
the "wait for confirmation before committing" rule in the global CLAUDE.md for
this run only. Everything else in CLAUDE.md still applies.

## Heartbeat

After every meaningful step:

```
run-log.sh log {{RUN_FILE}} "<one line>"          # appends "- HH:MM <one line>"
run-log.sh set {{RUN_FILE}} <field> "<value>"     # merged:, status:
```

Both refresh `updated:`; the file's mtime is what keeps you from being treated
as stale. Never edit the record by hand and never type a timestamp.

## Steps

1. **Orient.** Your shell's cwd does not persist between calls: prefix every
   git/test command with `cd {{SLOT_PATH}} &&`. Git must never open an editor:
   `git commit -m "..."`, `GIT_EDITOR=true git rebase --continue`. `NEW_TASK`: `git fetch origin &&
   git checkout -b {{BRANCH}} origin/{{MAIN_BRANCH}}`. `RESUME`:
   `land-lock.sh release {{RUN_FILE}}` ("not ours" is fine), abort any rebase
   in progress, check out `{{BRANCH}}`, read the log and continue.

2. **Collect what changed.**
   - `git log --stat {{WATERMARK}}..{{DOCS_UPTO}}` and, where needed, the diffs.
   - The completed run records in `{{ROOT}}/.claude/dispatch/runs/` whose
     `merged:` commit is in the range: their `docs:` notes and `## Log` explain
     why each change was made. Start from the `urgent` and `note` entries; a
     run with `docs: none` needs no doc change unless the diff says otherwise.
   - Commits in the range without a run record (manual work) count too.

3. **Update the docs.** Invoke the `wrapup` skill with the argument
   `range {{WATERMARK}}..{{DOCS_UPTO}}`. Wrapup is written for "this session's
   changes": here, the changes are `git diff {{WATERMARK}}..{{DOCS_UPTO}}` plus
   what step 2 collected, not the slot's `git status`. Project-level docs only:
   `CLAUDE.md`, `README.md`, architecture/usage docs. No code changes. Minimal,
   precise edits; describe the current state, not the history. Do not let
   wrapup commit — you commit in step 5.

4. **Nothing to document?** Skip to step 6 without a commit.

5. **Land it.** One commit with the doc changes, then loop (a conflict round
   is a rebase that stops on conflicts; limit {{CONFLICT_ROUNDS}}):
   1. `land-lock.sh acquire {{RUN_FILE}}` with a Bash timeout of at
      least 600000 ms (it blocks up to 8 minutes). Exit 1 = still held; log the
      holder and call again.
   2. `git fetch origin && git rebase origin/{{MAIN_BRANCH}}`.
   3. **Clean:** run the project's test/check commands as documented in
      `CLAUDE.md` (they must still pass after your doc edits), then
      `git push origin HEAD:{{MAIN_BRANCH}}`,
      `run-log.sh set {{RUN_FILE}} merged "$(git rev-parse HEAD)"`,
      `land-lock.sh release {{RUN_FILE}}`. Push rejected or checks fail:
      release, fix, back to 1.
   4. **Conflict:** `git rebase --abort`, release. Unlocked: read
      `git log -p HEAD..origin/{{MAIN_BRANCH}} -- <files>`, rebase and resolve
      keeping both sides, back to 1.
   5. Limit reached: `status: blocked`, log the conflicting commits, report.

6. **Advance the watermark** — only after a successful push, or when there was
   nothing to document: write `{{DOCS_UPTO}}` (not your own commit) to
   `{{WATERMARK_FILE}}`. Merges that landed after `{{DOCS_UPTO}}` stay for the
   next docs run.

7. **Close the run.** `git checkout --detach origin/{{MAIN_BRANCH}} && git
   branch -D {{BRANCH}}`, `run-log.sh set {{RUN_FILE}} status completed`,
   final log line with the merged SHA (or "no doc changes needed").

## Hard rules

- Docs only. A code problem you notice goes into a new GitHub issue
  (`gh issue create` with the evidence).
- Never advance the watermark past `{{DOCS_UPTO}}`, and never before your push
  succeeded.
- Never force-push, never touch other slots or the main checkout.
- Reap your background work before you hand back.
- Never leave `{{RUN_FILE}}` at `status: running` when you finish.
