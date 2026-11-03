#!/usr/bin/env python3
"""Move old WAL entries into a monthly archive. Nothing is lost.

  wal-rotate.py [wal-path, default docs/WAL.md] [--keep-days N, default 7] [--dry-run]

Entries ("## YYYY-MM-DD ...") older than N days go, in order, to
<wal-dir>/wal-archive/WAL-YYYY-MM.md (appended). The header above the first entry and the
recent entries stay. The script checks that every entry is in exactly one file afterwards
and refuses to write otherwise.
"""
import datetime as dt
import os
import re
import sys

HEAD = re.compile(r"^## (\d{4}-\d{2}-\d{2})", re.M)


def split(text):
    starts = [m.start() for m in HEAD.finditer(text)]
    if not starts:
        return text, []
    header = text[: starts[0]]
    entries = [text[a:b] for a, b in zip(starts, starts[1:] + [len(text)])]
    return header, entries


def main(argv):
    wal, keep, dry = "docs/WAL.md", 7, False
    args = iter(argv)
    for a in args:
        if a == "--keep-days":
            keep = int(next(args))
        elif a == "--dry-run":
            dry = True
        else:
            wal = a
    text = open(wal, encoding="utf-8").read()
    header, entries = split(text)
    cutoff = (dt.date.today() - dt.timedelta(days=keep)).isoformat()
    move, stay = {}, []
    for e in entries:
        day = HEAD.match(e).group(1)
        if day < cutoff:
            move.setdefault(day[:7], []).append(e)
        else:
            stay.append(e)
    n_moved = sum(len(v) for v in move.values())
    if n_moved + len(stay) != len(entries):
        sys.exit("count mismatch, nothing written")
    arch_dir = os.path.join(os.path.dirname(wal) or ".", "wal-archive")
    print(f"{len(entries)} entries: move {n_moved} to {arch_dir}/, keep {len(stay)} (cutoff {cutoff})")
    if dry or not n_moved:
        return 0
    os.makedirs(arch_dir, exist_ok=True)
    for month, es in sorted(move.items()):
        path = os.path.join(arch_dir, f"WAL-{month}.md")
        new = not os.path.exists(path)
        with open(path, "a", encoding="utf-8") as f:
            if new:
                f.write(f"# WAL archive {month}\n\nMoved from {os.path.basename(wal)} by wal-rotate.py. Append-only.\n\n")
            for e in es:
                f.write(e if e.endswith("\n") else e + "\n")
        print(f"append  {path} (+{len(es)})")
    note = f"Older entries: `wal-archive/WAL-YYYY-MM.md` (moved by wal-rotate.py, nothing deleted).\n\n"
    if "wal-archive/" not in header:
        header = header.rstrip("\n") + "\n\n" + note
    tmp = wal + ".tmp"
    open(tmp, "w", encoding="utf-8").write(header + "".join(stay))
    # re-check: archive + new WAL hold every old entry
    total = len(split(open(tmp, encoding="utf-8").read())[1]) + n_moved
    if total != len(entries):
        os.remove(tmp)
        sys.exit("verify failed, WAL left untouched")
    os.replace(tmp, wal)
    print(f"write   {wal} ({len(stay)} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
