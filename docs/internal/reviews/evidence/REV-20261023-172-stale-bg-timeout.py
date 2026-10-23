#!/usr/bin/env python3
"""Safe reproducer for REV-20261023-172.

It imports the shipped TUI, substitutes only its read-only collector, and
observes which command UI.key() schedules.  No scheduled command is executed.
"""

import importlib.util
import sys
import threading
import time


def load(path):
    spec = importlib.util.spec_from_file_location("reviewed_tui", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def snapshot(module, name):
    data = module.Data()
    data.status = {"relations": [{"name": name, "state": "planned", "peer": "x"}]}
    data.jobs = {"host": "review", "jobs": []}
    data.monitors = {"monitors": []}
    data.progress = {"transfers": []}
    data.replicas = {"replicas": []}
    data.stats = {}
    return data


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: %s tui/zfs-tui.py" % sys.argv[0])
    module = load(sys.argv[1])
    stale = snapshot(module, "stale-relation")
    fresh = snapshot(module, "fresh-relation")
    entered = threading.Event()
    release = threading.Event()
    calls = [0]

    def fake_collect(_repo, _files, only=None):
        calls[0] += 1
        if calls[0] == 1:
            return stale
        entered.set()
        release.wait(45)
        return fresh

    module.collect = fake_collect
    ui = module.UI("/tmp", {}, module.Chars(True), 1700000000, None)
    ui.screen = "relacje"
    ui.refresh_bg()
    if not entered.wait(2):
        raise AssertionError("background collector did not start")

    started = time.monotonic()
    result = ui.key("del")
    elapsed = time.monotonic() - started
    scheduled = ui.pending_shell or ""
    alive = ui._bg[0].is_alive()
    print("elapsed=%.2f result=%s alive=%s row=%s" %
          (elapsed, result, alive, ui.rows[0]["name"]))
    print("scheduled=%s" % scheduled)

    release.set()
    ui._bg[0].join(2)
    ui.poll_bg()
    print("after_release_row=%s" % ui.rows[0]["name"])

    assert elapsed >= 29.5
    assert alive
    assert "delete-relation stale-relation --ask" in scheduled
    assert ui.rows[0]["name"] == "fresh-relation"


if __name__ == "__main__":
    main()
