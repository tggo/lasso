# Lasso — agent guide

Open-source (MIT) SwiftUI iOS 18+ client for herdr. Remote access is **SSH only**: herdr's API is NDJSON
over a local Unix socket, reached through `direct-streamlocal@openssh.com` channels.

## Rules
- **Everything goes through the Makefile.** If you need a new command, add a target; don't document raw
  xcodebuild invocations.
- **Before calling work done:** `make test-packages && make test && make lint && make audit` all green.
- **No backdoors.** No analytics/crash/ads SDKs, no hard-coded hosts outside `docs/network-allowlist.txt`,
  no unpinned or new prebuilt dependencies without a row in `docs/dependencies.md`. Read SECURITY.md.
- Logic lives in local Swift packages (`Packages/*`) that test with `swift test`; the app target is thin UI.
- herdr has no stability guarantee: decode leniently (`JSONValue`), never crash on unknown fields.
  Reference schema: `docs/reference/herdr-api.schema.json`.
- Planning uses BMAD: specs/epics/stories in `_bmad-output/`. Research in `docs/research/`.
- Communicate with the owner in Ukrainian; code, commits and docs in English.

<!-- git-dod:start -->
## Definition of Done + git-as-log (skill `git-dod`)

Two artifacts, never conflated: `DEFINITION_OF_DONE.md` = the living **SPEC**
("how it must behave now", one entry per feature, edited in place); **git history
= the LOG** — per-file "why" via `git log --follow -- <file>`. There is no
separate worklog file.

- Behaviour change → update that feature's `DEFINITION_OF_DONE.md` entry **in the
  same commit** as the code. **Never invent a DoD — if the criteria are unclear, ASK.**
- `feat` / `fix` commit messages MUST carry `Why:` and `Expected:` lines, and every
  commit must use a canonical type (enforced by the `commit-msg` hook).
- Hook missing? `make hooks` (or `bash install.sh --yes` from a git-dod checkout).
  Never bypass with `--no-verify`; fix the message instead.

Full playbook: skill `git-dod` (`.claude/skills/git-dod/SKILL.md`).
<!-- git-dod:end -->

<!-- wal:start -->
## WAL — project state log

- `docs/WAL.md` is the state between sessions. A new session reads its last ~10 entries before anything else.
- After every finished lane, push, deploy, decision or abandoned path, the session that owns the project (the lead, when there are lanes) appends an entry in the format at the top of the file and commits it if that folder is under git.
- Lanes and sub-agents do not write the WAL; they report, the lead distils.
- Claims carry a `[source: …]` or `[unverified]`; negative results stay; questions for the owner go on `owner:` lines.
- A Stop hook (`.claude/hooks/wal-stop-hook.py`) blocks stopping while a push, deploy or finished lane report is not yet logged.
- Entry time comes from `date '+%Y-%m-%d %H:%M'`, never typed by hand (typed times drift).
- Items are closed only by an appended entry (`- closed: … [source]`), never by editing old text; the `wal-review` skill does the audit, writes `WAL-open.md` and rotates old entries to `wal-archive/` (nothing deleted).
<!-- wal:end -->
