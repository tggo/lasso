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

## Build — native crypto from pinned source
**What:** `make native` builds OpenSSL + libssh2 xcframeworks (iOS, Simulator, macOS) from SHA-256 pinned tarballs.
**DoD:**
- a hash mismatch aborts before compiling; `make native-verify` checks hashes only
- output lands in `Packages/LassoSSH/Artifacts/` (gitignored) with licences and PROVENANCE.txt
- `make generate`/`build` refuse to run without it and say `make native`
**Verified:** clean `make native` in 80 s, app builds against it — 2026-11-03.

## SSH — connect, auth, host-key pinning, channels (LassoSSH)
**What:** SSH session with an on-device Ed25519 key, host-key trust callback, exec, Unix-socket (streamlocal) requests, line streams and PTY.
**DoD:**
- untrusted host key aborts the connection with `hostKeyRejected`; unknown client key fails with `auth`
- fingerprint equals `ssh-keygen -l` output
- `ping` to herdr over streamlocal returns `pong`; 25 sequential requests on one connection succeed
- PTY echoes input and accepts resize
**Verified:** `make test-integration` (8 tests, real sshd + herdr 0.9.5) — 2026-11-03.

## Session — live herdr state over SSH (LassoCore)
**What:** a host link (TOFU host key, device key in Keychain, `$HOME`-resolved socket) feeding a store that mirrors herdr live.
**DoD:**
- first connect pins the host key; a different key later fails with `HostKeyMismatch`
- workspaces/agents appear after `start()`; a status change on the host shows in the store within 2 s
- agents order blocked > working > done > idle; `onStatusChange` fires for each transition
- event stream loss → backoff reconnect (1 s doubling to 30 s) and fresh snapshot
- `attach(pane:)` streams the pane terminal through `herdr agent attach` with PATH fixed for non-login sshd
**Verified:** `make test-integration` (LassoCore 6 tests incl. report_agent → blocked, attach echo) — 2026-11-03.

## App — hosts and device key
**What:** add/edit/delete hosts; one on-device Ed25519 key shown for authorized_keys.
**DoD:**
- a new host can be saved only after "Connect & show host key" succeeds and the user taps "Trust & save" (fingerprint shown)
- the key screen shows the `ssh-ed25519 …` line, a copy button and the fingerprint
- "Forget pinned key" clears the pin; the next connect shows the new fingerprint
**Verified:** —

## App — live session list
**What:** per host, workspaces with their agents (blocked first) and plain shell panes; green/yellow/red connection dot.
**DoD:**
- blocked agent appears with orange "blocked" label; list follows herdr without manual refresh
- context menus: new tab, rename/close workspace and tab, rename agent, start agent (claude/codex/pi/opencode) on a shell pane
- connection loss shows "Not connected" + Retry; the app reconnects on foreground
**Verified:** `make test-ui` against local herdr (blocked + working agents listed) — 2026-11-03.

## App — agent detail
**What:** recent pane output, composer and key bar (esc, enter, tab, shift+tab, arrows, ^C, 1/2/3, y/n).
**DoD:**
- output refreshes every 1 s while the agent works, 2.5 s otherwise
- a typed prompt reaches the pane; blocked agents get it as text + enter (agent.prompt refuses blocked agents)
**Verified:** `make test-ui`: "echo from-phone" sent from the phone executed in the pane — 2026-11-03.

## App — live terminal
**What:** full-screen libghostty terminal attached via `herdr agent attach <pane> [--takeover]`.
**DoD:**
- typing in the terminal goes to the pane; resize follows the view
- herdr's startup DA1/DA2/DECRQM probes are dropped so no `1016;2$y…` garbage lands in the pane
- shell noise before the start marker is not shown; dark theme
**Verified:** `make test-ui` screenshot build/shots/3-terminal.png clean prompt after attach — 2026-11-03.

## App — notifications
**What:** local notification when an agent becomes blocked, or done after working, while the app is not active.
**DoD:**
- from the live store while the app runs in background; from a BGAppRefresh snapshot pass otherwise (iOS decides timing)
- tapping opens that agent
- no push server, no relay
**Verified:** —
