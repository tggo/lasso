---
id: SPEC-lasso
companions:
  - stack.md
  - herdr-protocol.md
  - ../../../SECURITY.md
  - ../../../docs/dependencies.md
sources:
  - ../../../docs/research/2026-11-03-landscape.md
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete contract for what to build, test, and validate.

# Lasso — open-source iOS client for herdr

## Why

Vision + trust gap. herdr runs coding agents on the owner's machine and reaches the outside world only over SSH. Existing phone clients are either closed (Alma, Cowboy for Herdr) or ship default third-party relays and prebuilt overlay binaries (Heeler). Lasso is an MIT client small enough to audit: it talks only to hosts the user adds, carries no telemetry, and the build is reproducible from pinned sources.

## Capabilities

- **CAP-1**
  - **intent:** User adds a host (address, port, user) and authenticates with an Ed25519 key generated on the device.
  - **success:** The public key can be copied into `authorized_keys`. The first connection shows the host-key fingerprint and pins it. A changed fingerprint refuses to connect.
- **CAP-2**
  - **intent:** User sees every herdr agent on a host, grouped by workspace and ordered blocked > working > done > idle.
  - **success:** A status change on the host appears in the list within 2 s without a manual refresh.
- **CAP-3**
  - **intent:** User reads an agent's recent output.
  - **success:** The detail view shows the same last N lines as `herdr agent read <pane> --source recent`.
- **CAP-4**
  - **intent:** User sends a prompt or keys (enter, esc, ctrl+c, tab, shift+tab, arrows) to an agent.
  - **success:** A prompt sent from the phone is visible in the agent's pane, and a blocked agent unblocks after its answer is sent.
- **CAP-5**
  - **intent:** User opens a live terminal on a pane, with a key bar and an optional takeover.
  - **success:** Typing in the terminal behaves as in a desktop attach. Rotation resizes the PTY.
- **CAP-6**
  - **intent:** User is notified when an agent becomes blocked or done while the app is backgrounded.
  - **success:** A local notification fires for a blocked transition and opens that agent when tapped.
- **CAP-7**
  - **intent:** User starts an agent and creates, renames, or closes a workspace or tab.
  - **success:** Each action is reflected in `herdr` on the host and in the app's list.
- **CAP-8**
  - **intent:** The app survives network loss and app suspension.
  - **success:** After the network returns, state matches a fresh `session.snapshot` with no stale agents.
- **CAP-9**
  - **intent:** Anyone can rebuild and audit the app from source.
  - **success:** `make native && make build && make audit` passes on a clean clone. `make audit` fails on an injected analytics SDK or an unlisted host.

## Constraints

- No telemetry, analytics, crash-reporting, or ads SDKs. No servers operated by us. Every hard-coded host is listed in `docs/network-allowlist.txt`. All three are enforced by `make audit`.
- SSH only. Crypto comes from libssh2 and OpenSSL built from SHA-256-pinned source (`make native`). No prebuilt crypto is committed.
- The only accepted prebuilt is libghostty, pinned by exact revision and checksum and tracked in `docs/dependencies.md`.
- SSH private keys live in the Keychain as `ThisDeviceOnly` and never leave the device. Host keys are pinned on first use (TOFU), and a mismatch stops the connection.
- The herdr API has no stability guarantee, so decoding is lenient and an unknown field or event never crashes the app.
- Every build, test, and release step runs through the Makefile. Logic lives in local Swift packages that test with `swift test`.
- iOS 18+, SwiftUI, and Swift 6 with complete strict concurrency.

## Non-goals

- Chat view built from agent transcripts, and approval buttons (both later).
- A pairing plugin, a push relay, or Live Activities (later; any relay must be self-hostable and off by default).
- Worktrees, SFTP file and photo upload, a dedicated iPad layout, jump hosts, and embedded overlay networks (Tailscale and similar).
- Accounts, sign-in, or any backend of our own.

## Success signal

The owner installs a TestFlight build and adds their Mac over Tailscale or LAN. From the phone they answer a blocked Claude Code agent and watch it resume in the live terminal. A third party can reproduce the build and see `make audit` pass.

## Assumptions

- Hosts run OpenSSH with stream-local forwarding allowed, which is the default. If it is not, the app falls back to running `herdr api` over an exec channel.

## Open Questions

- Which Apple team and which GitHub org/account will publish it?
- Push while the app is killed needs our own APNs relay. Is that ever in scope, or do we stay with local notifications only?
