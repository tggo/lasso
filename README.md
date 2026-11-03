# Lasso

Open-source (MIT) iOS client for [herdr](https://github.com/ogulcancelik/herdr), the agent-aware
terminal multiplexer. See which coding agents are blocked, answer them, and jump into a live
terminal, all from your phone over plain SSH to your own machine.

- **No accounts, no telemetry, no servers in between.** The app connects only to the hosts you
  add. [SECURITY.md](SECURITY.md) lists the rules, and `make audit` enforces them.
- **Auditable crypto.** OpenSSL and libssh2 are built from SHA-256 pinned source (`make native`).
  No prebuilt crypto is committed.
- The private key is created on the phone and never leaves it.

Lasso is not affiliated with herdr or its author, or with other herdr clients such as Heeler
and "Cowboy for Herdr".

## Features

- **Needs you.** Blocked agents across all workspaces are listed at the top, and the list updates live.
- **Workspaces, tabs and panes** mirrored from herdr. From the phone you can start Claude Code, Codex,
  pi or opencode in a pane, and create, rename or close workspaces and tabs.
- **Agent view.** Shows recent output and a composer. A key bar provides `y` `n` `1` `2` `3` ⏎ esc ⇥ ⇧⇥ arrows ^C.
- **Live terminal.** Runs `herdr agent attach` rendered by libghostty, with an option to fit the pane to the phone.
- **Local notifications** when an agent becomes blocked or finishes. No push relay is involved.
- **Host keys** are pinned on first use (you confirm the fingerprint), and a changed key refuses to connect.

## Host setup

1. Install herdr and run it (`brew install herdr`, then `herdr`).
2. Enable SSH (macOS: System Settings → General → Sharing → Remote Login).
3. In Lasso, tap 🔑, copy the command, and run it on the host. It appends the phone's key to `~/.ssh/authorized_keys`.
4. Add the host (LAN IP or Tailscale name), tap **Connect & show host key**, compare the fingerprint,
   then tap **Trust & save**.

For a named herdr session, fill in *Session name*. A custom socket goes in *Socket path*.

## Build

```sh
make bootstrap         # xcodegen, swiftlint, swiftformat, cmake + make native (~2 min)
make build             # simulator build
make test-packages     # HerdrKit / LassoSSH / LassoCore on macOS
make test-integration  # real SSH + real herdr on a throwaway local sshd (127.0.0.1:2222)
make test-ui           # simulator drives the full flow against that herdr; screenshots in build/shots
make sim-demo          # launch the app in the simulator against a local demo herdr
make audit             # the no-backdoor gate
make device            # install a Release build on a connected iPhone
```

Everything runs through the Makefile. Signing settings go in `.env` (see `.env.example`).

## Layout

| Path | What |
|---|---|
| `Packages/HerdrKit` | herdr NDJSON protocol: models and client, lenient decoding |
| `Packages/LassoSSH` | libssh2 wrapper: auth, host-key check, streamlocal, exec, PTY |
| `Packages/LassoCore` | hosts, Keychain key, SSH host link, live session store, attach filter |
| `App/Lasso` | SwiftUI app |
| `native/` | pinned sources and the build script for OpenSSL and libssh2 |
| `_bmad-output/specs/spec-lasso` | spec and stories |
| `DEFINITION_OF_DONE.md` | how each feature must behave now |
