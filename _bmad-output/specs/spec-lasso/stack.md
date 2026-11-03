# Stack

| Layer | Choice |
|---|---|
| App | SwiftUI, iOS 18, Observation, XcodeGen `project.yml` |
| `Packages/HerdrKit` | NDJSON codec, typed models (snapshot, agent, pane), lenient `JSONValue` |
| `Packages/LassoSSH` | Swift wrapper over libssh2: session, auth, host-key check, `direct-streamlocal` and exec+PTY channels, bounded channel queue (sshd MaxSessions=10) |
| `native/` | `Sources.lock` + `build.sh` → OpenSSL/libssh2 xcframeworks (gitignored output) via `make native` |
| Terminal | libghostty (libghostty-spm, exact revision) |
| Storage | Keychain (keys, pinned host keys); local file for host list; no iCloud backup of secrets |
| Quality | swiftlint, swiftformat, `make audit`, git-dod commit gate, WAL |
