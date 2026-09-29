# Performance report — parallel-dispatcher vs dispatcher

Benchmarks run 2026-09-29 on throwaway private GitHub repos. One run per
variant, no repetitions — treat numbers as indicative, not statistical.

## Method

- Same seed per scenario for both skills (code, 6 GitHub issues, config).
- The orchestrator followed each skill's `SKILL.md` literally and started the
  next tick the moment a worker reported — `/loop` intervals are **not**
  counted. Under a real loop the single dispatcher pays one interval per task.
- **Wall-clock:** first dispatch → last push to main (docs included).
- **Tokens / tool calls:** sum over all subagents (workers + docs agents),
  from the harness usage report. Orchestrator cost excluded.
- Parallel worker slots were created and dependency-installed before timing.

## Scenarios

**Worst case — overlapping tasks** (runs A, B, C)

- Tiny `calc.py` module; every task edits `calc.py` and `test_calc.py`.
- Issues: `neg` (seeded as a stale half-done run to exercise resume), `div`,
  rename `add`→`plus` (semantic break for others), `cli.py` (depends on the
  function names), a logging convention (applies to all functions), `mod`
  (depends on an undecided `DESIGN.md` → must come back `blocked`).
- The "don't pick overlapping tasks" rule was deliberately overridden to
  force conflicts.

**Best case — independent tasks** (runs D, E)

- Six independent modules (`roman`, `wordfreq`, `matrix`, `luhn`, `rpn`,
  `intervals`), each in its own `<name>.py` + `test_<name>.py`.
- `make test` discovers `test_*.py`, so no task touches a shared file.
- No stale run, no blocked task, no conventions.

## Results

| Run | Skill | Slots | Scenario | Wall-clock | Agents | Tokens | Tool calls | Conflict rounds |
|---|---|---|---|---|---|---|---|---|
| A | parallel-dispatcher | 6 | worst | 6m50s | 7 | ~306k | 85 | 6 |
| B | dispatcher | 1 | worst | 8m07s | 6 | ~225k | 46 | 0 |
| C | parallel-dispatcher | 3 | worst | 9m07s | 8 | ~345k | 96 | 3 |
| **D** | **parallel-dispatcher** | **6** | **best** | **4m47s** | 7 | ~288k | 67 | 0 |
| E | dispatcher | 1 | best | 8m26s | 6 | ~239k | 53 | 0 |

Best case detail:

- D task phase (6 tasks) **3m17s**, docs batch 1m30s → **2.6×** faster on
  task work, **1.8×** end to end, **+21%** tokens.
- Per-agent duration: D 79–187 s (lock waits, API contention), E 64–92 s.

Worst case detail:

- A: 1.2× faster than B, +36% tokens. The resumed stale run used all 3
  conflict rounds and bounded the wall-clock (~5 min on its own).
- C: slowest. Urgent-docs gating held 2 free slots idle ~4.5 slot-minutes, and
  urgent notes arriving at different times triggered 2 docs runs.
- A and C caught one clean-rebase semantic break each (a `cli` test calling
  the renamed `add`) via the post-rebase re-test, before pushing.

## Outcome quality

All five runs ended with tests passing on main, conventions and renames
applied everywhere, and 5/5 (worst) or 6/6 (best) issues closed.

| | parallel-dispatcher | dispatcher |
|---|---|---|
| Blocked issue (`mod`) | comment on the issue asking for the decision | log only; owner not told |
| Follow-up bugs found | filed as issues (or fixed in scope) | noticed, not filed |
| Project docs | batched docs agent; complete | `wrapup` per task; often skipped (best case: no module list) |
| User's checkout | untouched (slots) | used by every worker |

## Why parallel costs more tool calls and tokens

- Separate docs agent re-orients from scratch (~8 calls, ~40k tokens).
- Landing protocol per worker: lock acquire/release, `landed-notes.sh`,
  `run-log.sh` → ~1 extra call per worker in the best case.
- Conflict rounds in the worst case: re-read colliding commits, re-resolve,
  re-test.

## Conclusions

- Parallelism pays when the backlog is **independent**: 2.6× on task work
  with 6 slots, likely closer to the slot count for tasks longer than the
  ~1–3 min used here (fixed per-agent start-up and serialized landing shrink
  relative to the work).
- With **overlapping** tasks it buys little speed and costs 35–55% more
  tokens. The pick rule "not overlapping" is what keeps real use in the good
  regime.
- Fewer slots are not a safe middle ground: C (3 slots) was slower than the
  single dispatcher on the worst case.

## Open improvements

- Drop or narrow the "hold new tasks while urgent docs run" rule — workers
  already apply urgent notes after every rebase via `landed-notes.sh`.
- Coalesce multiple urgent notes into one docs run.
- Bundle lock + rebase + test + push into one `land.sh` (−2–3 calls/worker).
- Git over SSH failed inside the Bash sandbox for several workers
  (`Permission denied (publickey)`); document it or land over HTTPS via `gh`.
