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

## 2026-11-03 22:34 — kickoff
- done: scaffold (Makefile, XcodeGen, HerdrKit codec, audit gate, BMAD 6.12.4, git-dod, WAL); make build/test/test-herdrkit/audit green [source: session 2026-11-03]
- decided: MIT; name Lasso (Cowboy Hero dropped — "Cowboy for Herdr" exists on App Store); iOS 18; libssh2+OpenSSL from pinned source; libghostty prebuilt (tracked risk)
- done: spec _bmad-output/specs/spec-lasso (9 CAPs, 14 stories)
- open: story 1-1 make native — owner: agent, done-check: make native produces xcframeworks
- owner: Apple team + GitHub org for publishing; push-relay ever in scope?
