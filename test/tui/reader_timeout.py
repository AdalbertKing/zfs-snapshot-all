#!/usr/bin/env python3
"""GUI reader limit: run_verb() against a stub zfs-backup.sh that hangs with a child
(like an ssh to a dead host) must return an error within the limit and leave no
process behind; a normal reader still returns its JSON. Prints "ok <name>" or
"bad <name> <detail>" per check. POSIX only (process groups)."""
import importlib.util
import os
import sys
import tempfile
import time


def main():
    spec = importlib.util.spec_from_file_location("tui_under_test", sys.argv[1])
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    repo = tempfile.mkdtemp()
    pidf = os.path.join(repo, "child.pid")
    stub = os.path.join(repo, "zfs-backup.sh")
    with open(stub, "w") as fh:
        fh.write('#!/bin/bash\ncase "$1" in\n'
                 '  hang) sleep 300 & echo $! > "%s"; wait ;;\n'
                 '  *) echo \'{"ok": true}\' ;;\n'
                 'esac\n' % pidf)
    os.chmod(stub, 0o755)
    os.environ["ZFS_TUI_READER_TIMEOUT"] = "1"

    def check(name, cond, detail=""):
        print(("ok %s" % name) if cond else ("bad %s %s" % (name, detail)))

    t0 = time.monotonic()
    doc, err = m.run_verb(repo, ["hang", "--json"])
    dt = time.monotonic() - t0
    check("hung-reader-returns-error-within-limit",
          doc is None and err and "nie odpowiedział w 1 s" in err and dt < 5, "dt=%.1f err=%r" % (dt, err))
    alive = True
    try:
        child = int(open(pidf).read().strip())
        time.sleep(0.2)
        os.kill(child, 0)
    except (OSError, ValueError):
        alive = False
    check("hung-reader-child-killed", not alive)
    doc, err = m.run_verb(repo, ["status", "--json"])
    check("normal-reader-still-returns-json", doc == {"ok": True} and err is None, "doc=%r err=%r" % (doc, err))


if __name__ == "__main__":
    main()
