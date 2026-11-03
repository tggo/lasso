# Security & trust model

Lasso exists so that a herdr remote client can be **audited end to end**. Rules the code must keep:

1. **No telemetry.** No analytics, crash reporting, ads or attribution SDKs. `make audit` enforces it.
2. **No servers of ours.** The app talks only to hosts the user adds, over SSH. Any future push relay
   is self-hostable and off by default; no relay URL ships as a default.
3. **Every outbound host is listed** in `docs/network-allowlist.txt`; `make audit` fails on any other
   hard-coded URL.
4. **Dependencies are pinned** by exact revision + checksum. Native code (OpenSSL, libssh2) is built from
   source by `make native` against SHA-256 pinned tarballs — no prebuilt crypto in git.
   Known exception: libghostty is consumed as a pinned, checksummed prebuilt (see `docs/dependencies.md`).
5. **Keys never leave the device.** SSH private keys live in the Keychain (`ThisDeviceOnly`).
   Host keys are pinned on first use and a mismatch is a hard stop.

Report vulnerabilities via a private GitHub security advisory on this repo.
