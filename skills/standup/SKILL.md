---
name: standup
description: Reports what the dispatcher and scout have done since the last time it was called — tasks merged, scans run, items filed, what is still in flight and what needs attention. Moves a watermark so each call covers only new work. Read-only; never implements, never dispatches. Invoke when the user says "standup", "report", "what happened", "progress since last time", or via /loop.
---

# Standup

Answers one question: **what happened since the last standup?**

Reads the state the [dispatcher](../dispatcher/SKILL.md) and
[scout](../scout/SKILL.md) leave behind — run records, scan records, commits on
the main branch, tracker movement — and reports the delta. A watermark makes each
call cover only new work, so calling it twice in a row produces a full report and
then an empty one. The window is half-open — `(since, until]` — so nothing is
reported twice and nothing falls between two standups.

Read-only. It takes no lock and is never blocked by the shared mutex: reporting
on in-flight work is the point.

## 0. Collect

```
bash ~/.claude/skills/standup/scripts/standup-state.sh collect
```

Run it from the project directory. Every path it prints is absolute — read any
record you need to quote. It creates `.claude/standup/`, adds it to
`.git/info/exclude`, and prints:

| Line | Meaning |
|---|---|
| `since:` / `until:` | the window, and whether it came from the `watermark`, an `argument`, or the `default-window` (first call, `STANDUP_WINDOW_DAYS`, 7) |
| `first_standup:` | `yes` when there was no watermark — say so in the report, the window is arbitrary |
| `lock:` / `activity:` | in-flight dispatch/scout agents, straight from the shared mutex |
| `dispatch:` | one line per run record touched in the window — `status` is `completed`, `blocked`, `failed` or `running` |
| `scout:` | one line per scan record touched in the window — `status` plus `found=` |
| `commit:` | what landed on the main branch in the window |
| `branch_unmerged:` | dispatch branches with commits that never reached main |
| `issue_closed:` / `issue_opened:` | tracker movement, when `gh` is available |
| `todos:` | open count now, plus items filed and ticked in the window |

For an ad-hoc window the user asks for, pass it through instead:
`collect --since 2026-08-19T00:00:00Z`.

## 1. Compose the report

Short. A person skimming it wants to know whether the loop is healthy and
whether anything needs them. Read the `## Log` of a record only when a line needs
explaining — a `blocked` run always does.

```markdown
**Since 2026-08-13** · 3 merged · 2 scans · 5 filed

**Dispatcher**
- gh#42 refresh auth token before expiry — merged `abc1234`
- gh#51 flaky upload test — **blocked**: cannot reproduce outside CI

**Scout**
- `api-contract` — 3 filed (#61, #62, #63)
- `ui-ux` — nothing filed; two candidates rejected as duplicates

**In flight**
- dispatch gh#55 add retry budget — 12 min

**Needs you**
- gh#51 has been blocked for two runs — decide or close it
- `dispatch/38-export-csv` has 4 commits that never merged
```

Rules for the shape:

- Omit any section with nothing in it. An empty standup is one line: nothing
  happened since `<since>`.
- **Needs you** is the only section that may ask for anything, and it only lists
  what is genuinely stuck: `blocked`/`failed` runs, unmerged branches, a run on
  its second resume, a backlog that is full or empty.
- Attribute by evidence, not by guess. A commit with no matching run record is
  someone's hand-written work — say so or leave it out; do not credit it to the
  dispatcher.
- No advice on what to do next, no "the loop is working well" commentary. The
  facts and what is stuck.

## 2. Move the watermark

Only **after** the report is delivered, and only when the window came from the
watermark or the default:

```
bash ~/.claude/skills/standup/scripts/standup-state.sh mark
```

With no argument it marks the exact `until:` of the collect it follows, not the
time it happens to run, so the next window starts where this report stopped.

Never mark for a `--since` window the user asked for — that was a question about
history, not a standup, and marking would swallow work the next real standup
should cover. If the collect step failed or the report never reached the user, do
not mark: an unreported window must stay unreported.

## Hard rules

- **Never implements and never dispatches.** No code edits, no branches, no
  agents, no issue or `TODOs.md` writes, no resuming a stalled run. Anything that
  needs doing is named in **Needs you** and left there.
- Writes nothing but `.claude/standup/`.
- Does not judge the work — a `completed` run is reported as completed, without
  reviewing the diff.

## Under /loop

Longer interval than the dispatcher and scout — a standup per hour or per day,
not per tick, or every report is empty. The watermark means a missed tick costs
nothing: the next one covers both windows.
