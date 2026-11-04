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

## 2026-11-03 23:23 — MVP built
- done: Epic 1 make native (OpenSSL 3.6.3 + libssh2 1.11.1 from pinned tarballs) + LassoSSH [source: make test-integration, 8 tests]
- done: HerdrKit client + LassoCore (TOFU, Keychain key, live store, attach filter) [source: make test-integration, LassoCore 9 tests incl. real herdr 0.9.5]
- done: app — hosts, Needs-you list, agent detail, libghostty terminal, local notifications [source: make test-ui screenshots build/shots]
- done: UI review fixes applied (blocked-first, answer keys first, contrast, confirmations, probe reset)
- done: Release installed on iPhone 16 Pro via make device [source: devicectl apps list shows dev.lasso.Lasso]
- done: repo github.com/tggo/lasso created PRIVATE, pushed; CI running
- decided: agent.prompt refuses blocked agents → blocked answers go as pane.send_input text+enter
- decided: herdr attach startup probes (DA1/DA2/DECRQM) dropped for 2 s after attach, else replies land in the pane
- negative: agent.read/agent.send_keys fail on non-agent panes → use pane.read/pane.send_input everywhere
- open: notifications on a real device unverified (owner: agent, done-check: blocked agent → banner on iPhone)
- owner: make repo public when ready: gh repo edit tggo/lasso --visibility public --accept-visibility-change-consequences
- owner: authorize phone key on your Mac (key screen → Copy command) and add the host to try it for real

## 2026-11-03 23:29 — CI first run
- negative: CI run 41721278092 failed — LassoCore integration process exited with signal 11 during storeSeesWorkspaceAndAgentStatusLive [source: gh run view 41721278092 --log-failed]
- done: local ASan + TSan runs of CoreIntegration clean (0 TSan warnings); found and fixed a test assumption (other blocked agents in session) [source: swift test --sanitize=thread, 3/3 pass]
- open: is the CI segfault reproducible? — owner: agent, done-check: run 41722199411 green or crash backtrace captured

## 2026-11-03 23:33 — CI debugging
- negative: CI run 41722199411 segfaulted again in storeSeesWorkspaceAndAgentStatusLive [source: gh run view --log-failed]
- negative: not reproducible locally, including on an empty herdr session [source: swift test --filter CoreIntegration, 3/3 pass]
- decided: CI now prints Swift backtraces and the herdr/sshd logs on failure, because no backtrace = no diagnosis
- open: CI segfault root cause — owner: agent, done-check: run 41722817008 backtrace read and fix green

## 2026-11-03 23:38 — CI segfault fix
- done: backtrace from run 41722817008 showed the crash in SSHConnection.unixLines, with a pointer overwritten by JSON bytes [source: gh run log, "Bad pointer dereference at 0x6c223a2264692…"]
- decided: event stream now uses non-blocking libssh2 reads plus poll(250 ms), because resuming blocking reads after LIBSSH2_ERROR_TIMEOUT is unsafe
- done: local integration tests green and 3x ASan green [source: make test-integration]
- open: CI green on run 41723607778 — owner: agent, done-check: gh run view shows success

## 2026-11-03 23:44 — CI
- done: integration step green after the non-blocking fix [source: run 41723607778, step Integration passed]
- negative: App build failed on Xcode 16.4 (libghostty uses UIGlassEffect from the iOS 26 SDK)
- decided: CI selects the newest Xcode 26; README states that Xcode 26 is the minimum to build
- open: full CI green — owner: agent, done-check: next run success
- closed: full CI green (audit, lint, package tests, integration with real herdr, app build on Xcode 26) [source: gh run 41724552076 success]

## 2026-11-04 09:31 — host drafts, icon; Herdr.app is a different backend
- done: save unverified host drafts, key shown when herdr down, friendly socket error, app icon (Flux on gpu0); installed on iPhone [source: commit dde0605, make test-ui green]
- found: owner runs Herdr.app (herdr-app 0.1.10, herdr-core JSON-RPC at ~/.local/state/herdr-core/default/default.sock), not herdr 0.9.5; `ping` unknown there, Lasso cannot talk to it yet [source: nc probe of sockets]
- owner: support herdr-core backend in Lasso, or run plain `herdr` on the Mac?

## 2026-11-04 09:42 — Herdr.app backend
- done: Herdr.app (herdr-core JSON-RPC + desktop socket + hc attach) auto-detected; TUI path unchanged; installed on iPhone [source: commit f613ff3; make test-integration HerdrAppIntegration + make test-ui testHerdrAppSessionList green against live Herdr.app]
- mistake: first version targeted herdr TUI 0.9.5 (brew) without checking which herdr the owner runs; owner uses herdr.dev Herdr.app
- closed: owner question on backend choice — support Herdr.app [source: owner message]
- owner: verify on phone against macstudio (Address, user ruslan, leave Session/Socket empty)

## 2026-11-04 10:08 — agent view readability; Mac lag investigation
- done: agent output cleanup + lighter polling, installed on iPhone [source: commit 32a9eef, make test-ui green]
- found: simulated phone load (app ls + terminal.read every 150 ms) adds no Herdr.app CPU, 1-4 ms per call; lag cause unknown [source: scratchpad load.py]
- owner: reproduce the typing lag with the phone connected; 1 Hz CPU monitor is recording
