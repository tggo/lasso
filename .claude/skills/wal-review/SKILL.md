---
name: wal-review
description: Audit a project's WAL (docs/WAL.md + docs/wal-archive/) — find every open: and owner: item, check each against real evidence (git log, prod, MCP, tests, files), close the ones that are done, flag stale or orphaned ones, write the current open queue to docs/WAL-open.md, and rotate old entries into the archive. Use when the owner asks "ревізія WAL", "що відкрито", "закрий виконане у WAL", "wal review", "що чекає на мене", or at the start of a lead session when WAL-open.md is older than a day.
---

# WAL review

The WAL is append-only. Items are never edited in place: a review **appends** one entry that
closes or keeps items, and **regenerates** `docs/WAL-open.md` (a derived view, safe to
overwrite). Nothing is deleted; old entries move to `docs/wal-archive/` via the rotate script.

## Steps

1. **Rotate first** (lossless): `python3 .claude/hooks/wal-rotate.py docs/WAL.md --keep-days 7`.
2. **Collect items.** From `docs/WAL.md`, `docs/wal-archive/*.md` and the previous `docs/WAL-open.md`,
   list every `- open:` and `- owner:` line with its entry header (date + story). Drop items already
   closed by an earlier `closed:` line (match by the quoted text or `#id`).
3. **Check each item against evidence, not memory.** Pick the cheapest check that decides it:
   - commit / story: `git -C <repo> log --oneline --grep '<story>'`, `tools/lane-check.sh <story>` if present;
   - deploy / prod: health endpoint revision, curl, MCP read tools;
   - doc / file: grep the file;
   - owner question: was it answered later in the WAL or in the conversation?
   Run independent checks in parallel; for >30 items spawn ≤3 sub-agents split by story, each
   returning `item → closed|open|stale + source`.
4. **Classify.**
   - `closed` — evidence shows done. Needs a `[source: …]`.
   - `open` — not done, owner still exists, still wanted.
   - `stale` — no owner (lane gone), or superseded by a later decision, or >7 days with no movement.
     Propose: reassign, drop with reason, or ask the owner.
   - `owner` — waits on the project owner; keep the question short, with the recommended option.
5. **Append one review entry** (time from the clock):
   ```
   ## <date '+%Y-%m-%d %H:%M'> · WAL-REVIEW — DECISION
   - closed: <item, short> (from <entry date · story>) [source: …]
   - stale: <item> — <proposal> — чому: …
   - still open: N items, owner queue: M (see WAL-open.md)
   ```
   Commit: `git -C docs commit -m 'wal: review' WAL.md WAL-open.md wal-archive` (or plain `git add`+commit if docs is the repo root).
6. **Write `docs/WAL-open.md`** (overwrite): generated time; table of open items (since, story,
   item, owner, done-check, last evidence); then the owner queue; then stale proposals.
7. **Report to the owner** in their language, ≤10 lines: closed N, open N, owner queue (the actual
   questions), stale proposals needing a decision.

## Rules

- Never close without a source. Unsure → keep open and say what check would decide it.
- Never rewrite or delete WAL text; closing is an appended line.
- Do not act on the items (no deploys, no fixes) — review only. Assigning work is the lead's next step.
- Keep the review entry short; details belong in WAL-open.md.
