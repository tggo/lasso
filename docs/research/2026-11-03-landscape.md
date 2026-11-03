# Landscape research — herdr, Heeler, Alma (2026-11-03)

Sources read: herdr @ ee5bfb5 (2026-10-29, Apache-2.0), Heeler @ v0.1.17 (Apache-2.0), alma.now docs
(fetched via summarizer — treat as secondhand).

## herdr
- Agent-aware terminal multiplexer (Rust). Workspaces → tabs → panes (`w1:p1`). Agent status:
  `idle | working | blocked | done | unknown`.
- **No network listener.** API = NDJSON over a `0600` Unix socket `~/.config/herdr/herdr.sock`
  (or `sessions/<name>/herdr.sock`; `HERDR_SOCKET_PATH`). Remote = SSH only.
- Request `{"id","method","params"}\n` → `{"id","result"}` | `{"id","error":{code,message}}` (id `""` on bad JSON).
- One request per connection; `events.subscribe` holds the connection and streams `{"event","data"}`.
- No stability guarantee → lenient decoding. Schema: `herdr api schema --json`, copy in
  `docs/reference/herdr-api.schema.json`.
- MVP methods: `ping`, `session.snapshot`, `agent.list|get|read|prompt|send_keys|start|rename|focus|wait`,
  `pane.read|send_input|split|close`, `workspace.*`, `tab.*`, `events.subscribe`.
- No public raw terminal stream: live terminal = SSH PTY running `herdr agent attach [--takeover] <pane>`.
- No approval object in the API — `blocked` is only a status.

## Heeler (independent iOS client)
- Swift 6, iOS 18, ~150k LOC. libssh2 + OpenSSL from pinned sources (prebuilt xcframeworks committed),
  libghostty (Lakr233/libghostty-spm, prebuilt), overlay nets (prebuilt third-party binaries).
- `direct-streamlocal@openssh.com` channel per request, bounded queue (sshd MaxSessions=10).
- Pairing QR carries a single-use private bootstrap key. Push via author's default relay
  `heeler-apns.bybee.dev` (sees tokens, timing, cleartext Live Activity counts).
- No telemetry found.

**Take:** streamlocal transport, lenient NDJSON, host-key pinning, source-pinned native build, E2E push design.
**Avoid:** default third-party relay, embedded overlay binaries, private key in QR, scope creep.

## Alma (closed source)
Chat-style transcripts, "needs you" list, push on stop/ask, approval buttons, queued follow-ups,
file/photo send, multiple machines, phone-width terminal with key bar.

## Feature split
MVP: hosts over SSH (Ed25519 in Keychain, TOFU fingerprint) · live agent list by status · agent output ·
prompt + keys · live terminal · local notifications · basic workspace/tab/agent management · reconnect + resnapshot.
Later: transcript chat view, approval buttons, own pairing plugin (no private key in QR), self-hostable E2E push relay
+ Live Activities, worktrees, file/photo via SFTP, iPad, jump host, system Tailscale.
