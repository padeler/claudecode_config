---
name: parallel-dispatcher
description: Parallel variant of the dispatcher. Keeps a fixed pool of git worktree slots (default 3) per project and fills free slots with background workers, each implementing one self-contained GitHub issue and landing it on main through a serialized rebase-test-push. Resumes stale runs first, and periodically dispatches a docs agent that brings project docs up to date. Requires gh and a GitHub repo. Idempotent. Invoke when the user says "parallel dispatch", "parallel-dispatcher", or via /loop.
---

# Parallel dispatcher

Up to `DISPATCH_SLOTS` workers per project, one per worktree **slot**. Every
invocation fills free slots (resume > docs > new task) or does nothing.
Calling it twice in a row must not put two workers in one slot or on one task.

Do not use it and the single [dispatcher](../dispatcher/SKILL.md) on the same
project — they share `.claude/dispatch/runs/` but not the slot model.

## Requirements

- `gh` installed and authenticated, and the repo on GitHub with an `origin`
  remote. `pdispatch-state.sh` exits with an error otherwise — stop and report
  it; there is no fallback.
- **Tasks come only from GitHub issues.** `TODOs.md`, `PLAN.md`, code `TODO`s
  are not task sources: every landing would edit a shared tracker file, and
  parallel landings then conflict on it constantly. Pair with a scout in
  `github-issues` mode, never `todos-md`.

## Layout

- Slots: `../<repo>.slots/1..N` — persistent worktrees, never removed. Idle
  slots sit on a detached HEAD at `origin/<main>` with dependencies installed.
- State: `<root>/.claude/dispatch/` (git-excluded)
  - `runs/*.md` — run records, one per run
  - `config.sh` — optional per-project settings (below)
  - `docs-watermark` — last base commit the project docs cover
  - `land-lock/` — serializes pushes to main
  - `slots/N.deps-hash`, `slots/N.setup.log`
- The main checkout (`root`) is the user's. Workers never touch it.
- Record edits after creation go through `scripts/run-log.sh` (`log`, `set`,
  `touch`); it stamps `updated:` with the real time.
- Workers call `scripts/land-lock.sh` (serialized push) and
  `scripts/landed-notes.sh` (docs notes of runs landed since a base commit).

Config (`config.sh` > environment > default):

| Variable | Default | Meaning |
|---|---|---|
| `DISPATCH_SLOTS` | 3 | slot count = max parallel workers |
| `DISPATCH_SLOTS_DIR` | `../<repo>.slots` | where slots live |
| `DISPATCH_SLOT_SETUP` | auto from lockfile | install command, or `none` |
| `DISPATCH_SLOT_DEPS_FILES` | auto | files whose change triggers a reinstall; required with an explicit setup |
| `DISPATCH_SLOT_COPY` | — | gitignored files copied from root (`.env ...`) |
| `DISPATCH_DOCS_EVERY` | 5 | undocumented merges that trigger a docs run |
| `DISPATCH_STALE_MINUTES` | 45 | run heartbeat timeout |
| `DISPATCH_LAND_STALE_MINUTES` | 30 | land lock reclaim age |
| `DISPATCH_CONFLICT_ROUNDS` | 3 | conflict rounds before a run goes `blocked` |

## 0. Read the state

```
bash ~/.claude/skills/parallel-dispatcher/scripts/pdispatch-state.sh
```

Prints `root`, `github`, `main_branch`, `base`, `lock` (shared with scout), `peer: scout`,
`land_lock`, one `run:` line per running/blocked/failed run, one `slot:` line
per slot (`free|busy|missing|broken`), `docs_watermark`, `docs_urgent:` lines,
`docs_pending`, `orphan_branch:` lines and the root checkout state.

Also call `ListAgents` — live agents the files cannot know about.

If `root_worktree: clean` and `behind>0` on the main branch, fast-forward it
(`git -C <root> pull --ff-only`) so the user's checkout stays current. Dirty or on another branch: leave it alone.

## 1. Decide

Stop immediately — do nothing, report — if:

- `lock: HELD` (a dispatcher or scout is mid-decision), or
- `peer: scout FRESH` / a live scout in `ListAgents` (a scan is in flight).

Otherwise take the lock:

```
bash ~/.claude/lib/agent-mutex.sh acquire dispatcher   # run from root; non-zero = held, stop
```

Then prepare the slots **before** any dispatch:

```
bash ~/.claude/skills/parallel-dispatcher/scripts/ensure-slots.sh
```

It creates missing slots, resets free ones to the base (stashing leftovers,
never deleting), copies `DISPATCH_SLOT_COPY`, and reinstalls dependencies when
the lockfiles changed. Busy slots are untouched. Exit 2 = configuration error
(e.g. no clear install command): release the lock and report the message to
the user. `broken` slots are skipped and reported; the rest are usable.
Installs may take minutes; the lock is reclaimable after 15.

Fill the slots, in this order, until no candidate or no `free` slot is left:

| # | Candidate | Slot |
|---|---|---|
| 1 | `run: STALE` — worker died. **Resume** (§2), oldest first. | its own (busy) slot |
| 2 | `orphan_branch:` without a record — reconstruct a record (issue number from the `dispatch/<n>-…` branch name, log from its commits) and resume it. | a free slot |
| 3 | `docs_urgent:` lines you agree with (§5), and no docs run FRESH. **Docs run.** | a free slot |
| 4 | `docs_pending >= every`, or `docs_pending > 0` and nothing else is dispatchable, and no docs run FRESH. **Docs run.** | a free slot |
| 5 | **New task** (§3), one per free slot. | a free slot |

`run: FRESH` rows are in flight — never touch them. `run: BLOCKED`/`FAILED`
hold their slot until the user resolves them or sets `status: abandoned`;
report them every tick. A slot `broken` for several ticks goes to the user.

Release the lock after the last Agent call:

```
bash ~/.claude/lib/agent-mutex.sh release dispatcher
```

Never force the lock, lower staleness thresholds, or reuse a busy slot to
squeeze out a dispatch. If the user wants that, they will say so.

## 2. Resume a run

Read the record in full; its `## Log` is the handoff. Bump `attempts:` and log
the resume with `scripts/run-log.sh` (`set <file> attempts N`, `log <file>
"resumed"`) — that write refreshes `updated:` and the mtime, the heartbeat the
new worker inherits. Dispatch with `MODE: RESUME` into the record's `slot:`,
same `branch:`.

A run that has already been resumed twice and stalls again: set
`status: failed`, log why, report it instead of resuming a third time.

## 3. Pick a new task

The only source:

```
gh issue list --state open --search "no:assignee" --json number,title,labels,body
```

(`--assignee ""` is ignored by gh and lists assigned issues too.) Prefer `ready` / `good first issue`; skip `blocked`, `needs-discussion`, and
anything assigned. No open issue qualifies → report "no dispatchable work".

Each pick must be:

- **self-contained**, **completable in one run**, **unambiguous** — as for the
  single dispatcher; nothing qualifies → report "no dispatchable work";
- **unclaimed** — unassigned, and no record with that `issue:` in
  `running`/`blocked`/`failed`;
- **not overlapping** — unlikely to edit the same files or area as a run in
  flight or another pick of this tick. When in doubt, leave it for a later
  tick; a free slot is cheaper than a conflict loop.

Write `.claude/dispatch/runs/<UTC-timestamp>-<slug>.md`:

```markdown
---
run_id: 20260805-141230-fix-token-refresh
status: running
kind: task                  # task | docs
issue: 42
task: "Refresh auth token before expiry"
branch: dispatch/42-fix-token-refresh
slot: 2
attempts: 1
started: 2026-08-05T14:12:30Z
updated: 2026-08-05T14:12:30Z
docs:                       # none | note — … | urgent — …  (worker fills)
merged:                     # sha on main (worker fills)
---

## Log
- 14:12 dispatched (new task, slot 2)
```

Writing the record reserves the slot. Claim the issue so no other dispatcher
or human picks it: `gh issue edit 42 --add-assignee @me` and a comment that
run `<run_id>` picked it up in slot N. A blocked run leaves it assigned; the
user unassigns when they set the record to `abandoned`.

## 4. Dispatch

- Task runs: fill `references/worker-prompt.md` (`{{ISSUE}}` = the number).
- Docs runs: fill `references/docs-prompt.md`.
- `subagent_type: general-purpose`, background, a fresh agent every time.
  Never `SendMessage` a dead worker back to life.

Report in a few lines: what went into which slot (or why nothing did), run
files, branches, and anything blocked, failed or broken.

## 5. Docs runs

Workers never edit `CLAUDE.md`, `README.md` or project-level docs and never run
`wrapup`. A docs agent does, over the range `docs-watermark..origin/<main>`.

- **Batch trigger:** `docs_pending >= DISPATCH_DOCS_EVERY`, or undocumented
  merges left when the backlog is otherwise empty.
- **Urgent trigger:** a worker set `docs: urgent — <why>`. You judge it: it is
  urgent only if later tasks will go wrong without it (new convention, moved or
  renamed module/API/config others use, changed build/test/run command, new
  constraint). Disagree → rewrite the field to `note — …` and log why.
  While an urgent docs run is pending or in flight, avoid starting new tasks in
  the affected area.
- One docs run at a time. It covers the whole range, not only the flagged
  commit, and resets the batch count.

Record: `kind: docs`, `task: "docs up to <sha>"`, `docs_upto: <full sha of
origin/main now>`, branch `dispatch/docs-<timestamp>`. The agent lands like a
worker and, only after its push, writes `docs_upto` (not its own commit) to
`docs-watermark` — merges that landed while it ran stay undocumented.

## Under /loop

15–30 minutes. Each tick is a cheap state check plus slot fill; the work runs
in the background workers. Scout shares the decision lock but blocks on any
FRESH dispatch run, so with busy slots it rarely gets a turn.
