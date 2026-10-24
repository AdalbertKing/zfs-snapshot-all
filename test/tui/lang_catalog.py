#!/usr/bin/env python3
"""GUI language catalogue: every literal handed to T (bash) or _() (Python) in tui/ has an
entry in tui/lang/en.json, and the file is a flat {str: str} map. A text wrapped for
translation without an English entry would silently stay Polish in the English GUI.
Prints "ok <name>" / "bad <name> <detail>"."""
import ast
import json
import os
import re
import sys

repo = sys.argv[1]
cat = json.load(open(os.path.join(repo, "tui", "lang", "en.json"), encoding="utf-8"))
print("ok catalog-is-flat-str-map" if all(isinstance(k, str) and isinstance(v, str) and k for k, v in cat.items())
      else "bad catalog-is-flat-str-map")

missing = []
tui = os.path.join(repo, "tui")
for fn in sorted(os.listdir(tui)):
    p = os.path.join(tui, fn)
    if fn.endswith(".sh"):
        for no, line in enumerate(open(p, encoding="utf-8"), 1):
            if line.lstrip().startswith("#"):
                continue
            # T 'literal'  /  $(T 'literal' ...)  /  T Word  (single-quoted or a bare word only:
            # a double-quoted argument would be expanded before the lookup)
            for m in re.finditer(r"(?:^|[\s(;])T\s+(?:'([^']*)'|([A-Za-ząćęłńóśźżĄĆĘŁŃÓŚŹŻ]+)(?=[\s)]))", line):
                k = m.group(1) if m.group(1) is not None else m.group(2)
                if k not in cat:
                    missing.append("%s:%d %r" % (fn, no, k[:60]))
    elif fn.endswith(".py"):
        src = open(p, encoding="utf-8").read()
        for m in re.finditer(r"\b_\(\s*u?(\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')\s*\)", src):
            k = ast.literal_eval(m.group(1))
            if k not in cat:
                missing.append("%s %r" % (fn, k[:60]))
print("ok every-wrapped-literal-has-an-entry" if not missing
      else "bad every-wrapped-literal-has-an-entry %s" % "; ".join(missing[:10]))
