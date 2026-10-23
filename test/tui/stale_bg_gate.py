#!/usr/bin/env python3
"""REV-20261023-172 regression: a key pressed while the post-window refresh is
still running past the wait limit must schedule nothing on the old rows; once
the fresh data is in, the same key acts on the fresh row.

Imports the shipped TUI and replaces only its collector (two in-memory
snapshots and an event), the reviewer's evidence shape. Nothing is executed.
Prints one line per check: "ok <name>" or "bad <name> <detail>"."""
import importlib.util
import sys
import threading


def load(path):
    spec = importlib.util.spec_from_file_location("tui_under_test", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def snapshot(m, name):
    d = m.Data()
    d.status = {"relations": [{"name": name, "state": "active", "peer": "x"}]}
    d.jobs = {"host": "t", "jobs": []}
    d.monitors = {"monitors": []}
    d.progress = {"transfers": []}
    d.replicas = {"replicas": []}
    d.stats = {}
    return d


def main():
    m = load(sys.argv[1])
    m.UI.BG_KEY_WAIT = 0.3            # the limit itself is not under test, its expiry is
    stale, fresh = snapshot(m, "stale-relation"), snapshot(m, "fresh-relation")
    entered, release, calls = threading.Event(), threading.Event(), [0]

    def collect(_repo, _files, only=None):
        calls[0] += 1
        if calls[0] == 1:
            return stale
        entered.set()
        release.wait(20)
        return fresh

    m.collect = collect
    ui = m.UI("/tmp", {}, m.Chars(True), 1700000000, None)
    ui.screen = "relacje"
    ui.refresh_bg()
    if not entered.wait(2):
        print("bad setup background collector did not start")
        return

    def check(name, cond, detail=""):
        print(("ok %s" % name) if cond else ("bad %s %s" % (name, detail)))

    for key in ("del", "F7", "down"):
        ui.pending_shell = None
        r = ui.key(key)
        check("stale-%s-schedules-nothing" % key,
              r == "stay" and not ui.pending_shell and not ui.window and ui._bg is not None
              and "NIEAKTUALNY" in (ui.message or ""),
              "r=%r shell=%r window=%r msg=%r" % (r, ui.pending_shell, ui.window and ui.window[0], ui.message))
    check("stale-rows-still-shown", ui.rows[0]["name"] == "stale-relation", ui.rows[0]["name"])

    release.set()
    if ui._bg is not None:
        ui._bg[0].join(5)
    ui.pending_shell = None
    r = ui.key("del")
    shell = ui.pending_shell or ""
    check("fresh-del-targets-fresh-row",
          ui._bg is None and "fresh-relation" in shell and "stale-relation" not in shell,
          "r=%r shell=%r" % (r, shell))
    check("fresh-data-cleared-caches", ui.data.configs == {} and ui.data.profiles is None)


if __name__ == "__main__":
    main()
