#!/usr/bin/env python3
"""Build tui/lang/en.json (Polish GUI text -> English) from the owner-reviewed table
docs/project/i18n/GUI-PL-EN-*.json. The Polish text as written in the code is the key;
a text missing from the catalogue simply stays Polish. Data only: the GUI reads this
file with json.load / a NUL-separated reader, never as code.

Bash literals keep their escapes in the table (\\" \\$ \\\\ \\`): the GUI sees the string
AFTER bash has read it, so for texts from tui/*.sh those four escapes are undone here.
Rows marked as code (sed/awk fragments) translate to themselves and are left out.

    python3 tui/lang/build.py [table.json] > tui/lang/en.json"""
import glob
import io
import json
import os
import re
import sys

here = os.path.dirname(os.path.abspath(__file__))
src = sys.argv[1] if len(sys.argv) > 1 else sorted(glob.glob(os.path.join(here, "..", "..", "docs", "project", "i18n", "GUI-PL-EN-*.json")))[-1]
doc = json.load(open(src, encoding="utf-8"))
rows = doc["items"] if isinstance(doc, dict) and "items" in doc else doc


def unbash(s):
    return re.sub(r'\\(["$\\`])', r"\1", s)


out = {}
for r in rows:
    pl, en = r.get("pl_code") or r.get("pl") or "", r.get("en") or ""
    if not pl or not en or en == pl:
        continue
    where = " ".join(r.get("where") or []) if isinstance(r.get("where"), list) else str(r.get("where") or "")
    keys = {pl}
    if ".sh" in where:
        keys.add(unbash(pl))
    for k in keys:
        out[k] = unbash(en) if (k != pl) else en
extra = os.path.join(here, "en.extra.json")
if os.path.exists(extra):
    for k, v in json.load(open(extra, encoding="utf-8")).items():
        if not k.startswith("_"):
            out.setdefault(k, v)
w = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", newline="\n")
json.dump(dict(sorted(out.items())), w, ensure_ascii=False, indent=0)
w.write("\n")
w.flush()
