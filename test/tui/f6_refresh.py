#!/usr/bin/env python3
"""U180 regression: entering F6 (Repliki) reads the replica list again -- the medium
state on the screen is the one at the moment of entry, not the one from the last read
(lab 2026-11-09: a disk pulled minutes earlier still read "connected").
Control: entering another screen asks for no replica read.

Imports the shipped TUI and replaces only its collector and refresh_bg. Nothing is
executed. Prints one line per check: "ok <name>" or "bad <name> <detail>"."""
import importlib.util
import sys
import time


def load(path):
    spec = importlib.util.spec_from_file_location("tui_under_test", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def snapshot(m):
    d = m.Data()
    d.status = {"relations": []}
    d.jobs = {"host": "t", "jobs": []}
    d.monitors = {"monitors": []}
    d.progress = {"transfers": []}
    d.replicas = {"replicas": [{"name": "r1", "present": "here"}]}
    d.stats = {}
    return d


def main():
    m = load(sys.argv[1])
    m.collect = lambda _r, _f, only=None: snapshot(m)
    ui = m.UI("/tmp", {}, m.Chars(True), 1700000000, None)
    while getattr(ui, "_bg", None) is not None or getattr(ui, "_bgslow", None) is not None:
        ui.poll_bg(); ui.poll_slow(); time.sleep(0.02)
    asked = []
    ui.refresh_bg = lambda only=None: asked.append(only)

    def check(name, cond, detail=""):
        print(("ok %s" % name) if cond else ("bad %s %s" % (name, detail)))

    ui.screen = "zadania"
    ui.key("F3", 40)
    check("other-screen-no-replica-read", not any(o and "replicas" in o for o in asked), "asked=%r" % asked)
    del asked[:]
    ui.key("F6", 40)
    check("f6-entry-reads-replicas", ui.screen == "nosniki" and ("replicas",) in asked,
          "screen=%r asked=%r" % (ui.screen, asked))


if __name__ == "__main__":
    main()
