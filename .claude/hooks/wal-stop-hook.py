#!/usr/bin/env python3
"""Stop hook: refuse to stop while a push, deploy or finished lane is not yet in the WAL.

Usage (from .claude/settings.json):
    python3 "$CLAUDE_PROJECT_DIR/.claude/hooks/wal-stop-hook.py" docs/WAL.md

Scans this session's transcript. An "event" is a Bash call running `git push` or a deploy
command (WAL_DEPLOY_RE, default `make deploy`), or a teammate report that names a story,
a commit or a deploy. If the last event comes after the last write to the WAL file, the
hook blocks the stop once and asks for an entry.
"""
import json
import os
import re
import sys

WAL = sys.argv[1] if len(sys.argv) > 1 else "docs/WAL.md"
WAL_NAME = os.path.basename(WAL)
DEPLOY = re.compile(os.environ.get("WAL_DEPLOY_RE", r"(^|[;&|\s])make deploy"))
TEAMMATE_DONE = re.compile(r"(Story \d+(\.\d+)?|deployed|committed as|is (built|live))", re.I)


def main():
    try:
        hook = json.load(sys.stdin)
    except Exception:
        return 0
    if hook.get("stop_hook_active"):
        return 0
    path = hook.get("transcript_path")
    if not path:
        return 0

    last_event, last_wal, what = -1, -1, ""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                # cheap prefilter: transcripts reach tens of MB
                if not (WAL_NAME in line or "git push" in line or "deploy" in line
                        or "teammate-message" in line):
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get("type") not in ("user", "assistant"):
                    continue
                content = (o.get("message") or {}).get("content")
                if isinstance(content, str):
                    content = [{"type": "text", "text": content}]
                for b in content or []:
                    t = b.get("type")
                    if t == "tool_use":
                        inp = b.get("input") or {}
                        if str(inp.get("file_path", "")).endswith(WAL):
                            last_wal = i
                        cmd = str(inp.get("command", ""))
                        # an append or commit from any dir: `cd docs && … >> WAL.md`, `git -C docs commit … WAL.md`
                        if WAL_NAME in cmd and (">>" in cmd or "tee" in cmd or "commit" in cmd):
                            last_wal = i
                        elif "git push" in cmd or DEPLOY.search(cmd):
                            last_event, what = i, "push/deploy"
                    elif t == "text" and o.get("type") == "user":
                        txt = b.get("text", "")
                        if "teammate-message" in txt and "idle_notification" in txt and TEAMMATE_DONE.search(txt):
                            last_event, what = i, "teammate report"
    except OSError:
        return 0

    if last_event > last_wal:
        print(json.dumps({
            "decision": "block",
            "reason": (
                f"A {what} happened after the last {WAL} entry. Append an entry to {WAL} "
                "using the format at the top of that file (result with [source], decisions with "
                "reasons, negative results, open items with owner and done-check, owner: questions) "
                "and commit it if that folder is under git. If nothing changed the project state, "
                "append a one-line DECISION entry saying so."
            ),
        }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
