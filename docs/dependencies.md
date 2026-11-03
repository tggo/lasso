# Dependencies

| Dependency | Why | How pinned | Prebuilt? |
|---|---|---|---|
| OpenSSL 3.6.x | libssh2 crypto backend | source tarball SHA-256 in `native/Sources.lock` | no — `make native` |
| libssh2 | SSH, `direct-streamlocal` channels to herdr.sock | commit + SHA-256 in `native/Sources.lock` | no — `make native` |
| libghostty (Lakr233/libghostty-spm) | terminal emulator | exact revision + SwiftPM checksum | **yes** (tracked risk: build from Ghostty source later) |

Adding a dependency: add a row here with the reason, pin it exactly, and run `make audit`.
| GhosttyTerminal transitive: MSDisplayLink | display link for the terminal | resolved version locked in Package.resolved | no |
