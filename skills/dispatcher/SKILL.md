---
name: dispatcher
description: Idempotent work dispatcher. Checks whether a dispatched agent is already working on this project; if not, resumes the most recent unfinished run or picks one self-contained pending task (GitHub issue or markdown TODO/PLAN) and dispatches a subagent to implement, wrap up, commit, merge to main and push. Invoke when the user says "dispatch", "dispatcher", or via /loop for continuous autonomous work.
---

# Dispatcher

One dispatched worker per project at a time. Every invocation either **does
nothing** (work is already in flight) or **dispatches exactly one worker**.
Finishing an unfinished run always beats starting a new one.

The dispatcher and the [scout](../scout/SKILL.md) share one mutex per project:
if a scout scan is in flight, the dispatcher does not start, and vice versa.

Designed to be called repeatedly — by the user or by `/loop`. Calling it twice
in a row must not produce two workers.

## 0. Read the state

```
bash ~/.claude/skills/dispatcher/scripts/dispatch-state.sh
```

Run it from the project directory. Every `.claude/dispatch/...` path below is
relative to the `root:` it reports — resolve them against that, not against the
shell's cwd. It creates `.claude/dispatch/runs/` if
needed, adds `.claude/dispatch/` to `.git/info/exclude` (state stays local, the
repo stays clean), and prints: `root`, `main_branch`, `lock` (the mutex shared
with scout), one `run:` line per active run, a `peer: scout ...` line for any
in-flight scout scan, any `orphan_branch:`, `current_branch:`, and `worktree:`.

Also call `ListAgents` — it lists live agents spawned by this session (and other
local sessions), which the files cannot know about. A live *scout* agent there
counts too.

## 1. Decide (in order — stop at the first match)

| State | Action |
|---|---|
| `lock: HELD` | A dispatcher or scout is mid-decision. **Do nothing.** Report and exit. |
| `peer: scout FRESH` **or** `ListAgents` shows a live scout agent | A scout scan is in flight. **Do nothing.** Report the area and its age; the next tick will find it finished. |
| `run: FRESH` **or** `ListAgents` shows a live dispatch agent | Work is in flight. **Do nothing.** Report which task and its age. |
| `run: STALE` | Unfinished run — the worker died (token limit, crash, session end). **Resume it** (§2). Oldest first. |
| `orphan_branch:` with no run record | Abandoned work from an earlier run. **Reconstruct a run record** from the branch's commits and resume it (§2). |
| Nothing above | **Start a new task** (§3). |

`worktree: dirty` on `main` with no active run means someone is working by hand
— do nothing and say so. `peer: scout STALE` means that scout agent died and is
not running, so it does not block a dispatch. Never take the lock away from a
`HELD` state or lower `DISPATCH_STALE_MINUTES` to force a dispatch; if the user
wants that, they will say so.

Take the lock before dispatching, release it once the Agent call returns:

```
bash ~/.claude/lib/agent-mutex.sh acquire dispatcher   # non-zero exit = held, stop here
bash ~/.claude/lib/agent-mutex.sh release dispatcher
```

The lock is one `mkdir`, shared with scout. A non-zero exit *is* the answer — do
not work around it. `acquire` reclaims a lock older than
`AGENT_LOCK_STALE_MINUTES` (15) on its own, since the lock is only ever held
across a single decision; a `lock: STALE` line means the holder's session died.

## 2. Resume an unfinished run

Read the run record in full. Its `## Log` is the previous worker's handoff.
Dispatch with `MODE: RESUME`, the same `branch:` and `task:`, and set the
record's `updated:` to now so the new worker owns the heartbeat.

If a run record has already been resumed twice and still stalls, set it to
`status: failed`, log why, and report it to the user instead of resuming a third
time.

## 3. Pick a new task

Look, in this order:

1. `gh issue list --state open --assignee "" --json number,title,labels,body`
   (skip if `gh` is unavailable or the repo is not on GitHub). Prefer issues
   labelled `ready`/`good first issue`; skip `blocked`, `needs-discussion`, and
   anything already assigned.
2. `TODOs.md`, `PLAN.md`, `IMPLEMENTATION.md` in the project root — unchecked
   items.
3. `TODO`/`FIXME` comments in the code, only if the above are empty.

Pick **one** task that is:

- **self-contained** — implementable and verifiable without input from the user,
- **completable** in a single agent run,
- **unambiguous** — the desired outcome is stated, not guessed.

Nothing qualifies? Report "no dispatchable work" and exit. Do not invent work,
do not split a large task to make it fit, do not pick a vague one and interpret
it. Anything needing a decision goes back to the user.

Then write `.claude/dispatch/runs/<UTC-timestamp>-<slug>.md`:

```markdown
---
run_id: 20260805-141230-fix-token-refresh
status: running
task: "gh#42 — Refresh auth token before expiry"
source: github-issue        # github-issue | markdown | code-todo
branch: dispatch/42-fix-token-refresh
attempts: 1
started: 2026-08-05T14:12:30Z
updated: 2026-08-05T14:12:30Z
---

## Log
- 14:12 dispatched (new task)
```

If the task is a GitHub issue, comment on it that it has been picked up.

## 4. Dispatch

Fill `references/worker-prompt.md` and pass it as the Agent prompt:

- `subagent_type: general-purpose`
- Subagents always run in the background, so the dispatcher returns immediately;
  the next invocation sees the `FRESH` run record and does nothing.
- Fresh agent every time. Never `SendMessage` a dead worker back to life — a run
  that died on a token limit needs a clean context, which is exactly what the
  run record's log is for.

Release the lock, then report in two or three lines: what was dispatched (or
why nothing was), the run file, and the branch.

## Under /loop

Pick an interval matched to how long a task takes — 15–30 minutes is sane. Each
tick is a cheap state check; the expensive work happens in the background
worker. Do not shorten the interval to "check on" a running worker.

Dispatcher and scout can share the same loop: the mutex makes them take turns
rather than run together, so a tick that finds the other one busy is a no-op, not
a failure.
