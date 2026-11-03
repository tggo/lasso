# Definition of Done — living spec of herdr-ios

A **point-in-time snapshot** of how this project is supposed to behave *right now*.
It is the source of truth for "is it working correctly?" — not a changelog.

**Rule:** every change that adds or alters observable behaviour MUST add or update
its entry here, **in the same commit** as the code. One entry per feature:

- **What** — one line: the feature / behaviour.
- **DoD** — observable acceptance criteria (what a human or QA can check), not
  implementation detail.
- **Verified** — how it was confirmed (a real measurement) + date, or `—`.

Keep entries terse. When behaviour changes, **edit the existing entry** — never
append a second one. Group by area; new areas go at the bottom.

**Never invent a DoD.** If the acceptance criteria are not clear, ASK and record
the answer — a guessed criterion is worse than none.

---

## Build — Makefile toolchain
**What:** the project builds, tests and audits through make only.
**DoD:**
- `make build` builds the app for the iOS 18 simulator from a clean clone after `make bootstrap`
- `make test` and `make test-packages` pass
- `make audit` fails on a tracking-SDK reference, a hard-coded host not in `docs/network-allowlist.txt`, or a remote package not pinned by exact revision
**Verified:** `make build`, `make test`, `make test-herdrkit` (4 tests), `make audit` green — 2026-11-03.

## Protocol — herdr NDJSON codec (HerdrKit)
**What:** encodes requests and decodes herdr responses/errors/events leniently.
**DoD:**
- a request encodes to exactly one line `{"id","method","params"}\n`
- `result`, `error` (incl. empty id) and `event` lines decode; unknown fields don't fail decoding
**Verified:** `make test-herdrkit` — 2026-11-03.
