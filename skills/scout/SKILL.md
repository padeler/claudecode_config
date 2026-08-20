---
name: scout
description: Idempotent backlog scout. Investigates the project it is started in (markdown docs, existing issues, codebase, and the running app via Playwright/scripts/probes) to find real bugs and worthwhile improvements, then files them as small self-contained units — as GitHub issues if the project uses them, otherwise in TODOs.md. Never implements anything. Complementary to the dispatcher, which consumes what this produces. Invoke when the user says "scout", "find work", "look for bugs/improvements", or via /loop.
---

# Scout

Finds work; never does it. One scout per project at a time. Every invocation
either **does nothing** (a scan is already in flight) or **dispatches exactly one
scout agent** that investigates a single focus area and files its findings into
the project's tracker.

**Where findings go** — the state script decides and prints it as `output:`:
GitHub issues if the repo is on GitHub with issues enabled, otherwise
`TODOs.md`. Never both.

The [dispatcher](../dispatcher/SKILL.md) skill is the consumer: what scout
writes, dispatcher implements. So every item must be shaped for an autonomous
worker — self-contained, evidence-backed, and unambiguous. The two share one
mutex per project: if a dispatch worker is in flight, scout does not start, and
vice versa.

Designed to be called repeatedly — by the user or by `/loop`. Calling it twice in
a row must not produce two scouts or two copies of the same finding.

## 0. Read the state

```
bash ~/.claude/skills/scout/scripts/scout-state.sh
```

Run it from the project directory. Every `.claude/scout/...` path below is
relative to the `root:` it reports — resolve them against that, not against the
shell's cwd. It creates `.claude/scout/scans/` if needed, adds `.claude/scout/`
to `.git/info/exclude` (state stays local, the repo stays clean), and prints:
`root`, `main_branch`, `lock` (the mutex shared with the dispatcher), one `scan:`
line per active scan, a `peer: dispatch ...` line for any in-flight dispatch run,
one `covered:` line per focus area already scanned, `todos_file:`, `gh:`,
`output:`, `backlog:`, `current_branch:` and `worktree:`.

Also call `ListAgents` — it lists live agents spawned by this session (and other
local sessions), which the files cannot know about. A live *dispatch* worker
there counts too.

## 1. Decide (in order — stop at the first match)

| State | Action |
|---|---|
| `lock: HELD` | A scout or dispatcher is mid-decision. **Do nothing.** Report and exit. |
| `peer: dispatch FRESH` **or** `ListAgents` shows a live dispatch worker | A dispatch worker is in flight. **Do nothing.** Report the task and its age; the next tick will find it finished. |
| `scan: FRESH` **or** `ListAgents` shows a live scout agent | A scan is in flight. **Do nothing.** Report which area and its age. |
| `scan: STALE` | The scout agent died. Set that record to `status: abandoned`, log why, and start a **new** scan of the same area (§2) — its findings were never written, so there is nothing to resume. |
| `backlog: FULL` | The tracker named by `output:` already holds enough open work (`SCOUT_BACKLOG_MAX`, default 15). **Do nothing.** Report that the dispatcher should drain it first. |
| Nothing above | **Start a new scan** (§2). |

Only one agent per project, scout's or the dispatcher's, is ever in flight — even
though they touch different things (the worker owns the code, scout owns the
tracker). `peer: dispatch STALE` means that worker died and is not running, so it
does not block a scan; the dispatcher will resume it on its own next tick.

Take the lock before dispatching, release it once the Agent call returns:

```
bash ~/.claude/lib/agent-mutex.sh acquire scout   # non-zero exit = held, stop here
bash ~/.claude/lib/agent-mutex.sh release scout
```

The lock is one `mkdir`, shared with the dispatcher. A non-zero exit *is* the
answer — do not work around it. `acquire` reclaims a lock older than
`AGENT_LOCK_STALE_MINUTES` (15) on its own, since the lock is only ever held
across a single decision; a `lock: STALE` line means the holder's session died.

## 2. Pick the focus area

One area per scan. A narrow scan that produces two well-evidenced items beats a
whole-project sweep that produces ten guesses.

Candidate areas — keep only the ones this project actually has:

`ui-ux` · `accessibility` · `frontend-correctness` · `api-contract` ·
`backend-correctness` · `error-handling` · `data-integrity` · `performance` ·
`security-hygiene` · `test-coverage` · `config-deployment` · `dx-docs`

Choose the area that is **least recently covered** (`covered: ... cooldown` lines
are on cooldown; prefer a `cold` or unlisted area) and **most connected to the
project's stated goal** — read `README.md`, `CLAUDE.md`, `PLAN.md`, the roadmap,
and the open issues to know what that goal is. If the user named an area when
invoking the skill, use theirs.

## 3. Build the dedupe set

The scout agent must not re-file what is already known. Collect and pass it:

1. `gh issue list --state all --limit 100 --json number,title,state,labels`
   (skip if `gh` is unavailable) — a closed issue is not a fresh finding either.
2. `TODOs.md` — every item, checked and unchecked, even when `output:` is
   `github-issues`; older projects have both.
3. `PLAN.md`, `IMPLEMENTATION.md`, `ROADMAP.md` if present — known future work is
   not a finding.
4. `.claude/scout/scans/*.md` — the `## Findings` sections of past scans,
   including items that were rejected and why.

## 4. Write the scan record

`.claude/scout/scans/<UTC-timestamp>-<area>.md`:

```markdown
---
scan_id: 20260819-141230-backend-correctness
status: running
area: backend-correctness
started: 2026-08-19T14:12:30Z
updated: 2026-08-19T14:12:30Z
found: 0
---

## Log
- 14:12 dispatched (area chosen: least recently covered, touches the auth goal)

## Findings
```

## 5. Dispatch

Fill `references/scout-prompt.md` and pass it as the Agent prompt:

- `{{OUTPUT}}` is the `output:` value from §0, verbatim — the agent must not
  re-decide where findings go.
- `subagent_type: general-purpose`
- Subagents always run in the background, so scout returns immediately; the next
  invocation sees the `FRESH` scan record and does nothing.
- Fresh agent every time.

Release the lock, then report in two or three lines: the area being scanned (or
why nothing was), the scan file, and the current backlog depth.

## Hard rules

- **Scout never implements.** No production-code edits, no refactors, no "while
  I was there" fixes, no branches, no PRs. `TODOs.md` is the only repo file it
  may write, and only when `output:` says so.
- **It leaves the worktree as it found it.** In `todos-md` mode the scout commits
  `TODOs.md` itself, so a scan never leaves the dispatcher staring at a dirty
  worktree. In `github-issues` mode it touches no files at all.
- **No speculation.** An item without evidence — a file:line, a reproduction, a
  failing probe, a screenshot, a log excerpt — does not get written.
- **No duplicates.** If it is already in `TODOs.md`, an issue, or a plan, it is
  not a finding.
- **No decisions for the user.** Anything needing a product call, a design
  choice, or a dependency/architecture change goes into the report to the user,
  not into the tracker.

## Under /loop

Scout and dispatcher pair well on the same loop cadence (15–30 minutes): scout
tops the backlog up, dispatcher drains it. The mutex makes them take turns rather
than run together, so a tick that finds the other one busy is a no-op, not a
failure. The backlog cap in §1 is what keeps them balanced — do not raise it to
keep scout busy.
