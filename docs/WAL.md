# WAL — project state log

Append-only. Newest entry at the bottom. One entry per finished lane, deploy, decision or
abandoned path. This file is the memory between sessions: the next session reads the last
entries instead of the owner re-explaining the state.

Rules:
- Write what was attempted and observed, never "fixed" or "works" without a `[source: …]`
  (commit, test, prod URL, command output). Unchecked claims say `[unverified]`.
- Keep negative results (what did not work and why): they stop the next agent repeating them.
- A decision carries its reason (`— why: …`).
- `open:` items have an owner and a done-check. Items that need the owner go under `owner:`
  — that line is the owner's queue.
- No narration. Details live in specs, stories and docs; link them.

Entry format:

Take the time from the clock, never type it: `printf '## %s · …\n' "$(date '+%Y-%m-%d %H:%M')" >> docs/WAL.md`.

```
## YYYY-MM-DD HH:MM · <story id> <short title> — <LIVE | SHADOW | ABANDONED | DECISION | WIP>
- result: … [source: …]
- decision: … — why: …
- negative: …
- cost: …
- open: … [owner: lane/agent] done = …
- owner: <question for the owner, with options and the recommended one>
- next: …
```

---
