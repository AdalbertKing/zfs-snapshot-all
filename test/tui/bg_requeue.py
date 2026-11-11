#!/usr/bin/env python3
"""U185 regression: a refresh asked for while a background read is still running
(a window has just saved, Ctrl-R) must not be dropped. The running read may have
started before the change; the screen must end on a read that started after it.

Imports the shipped TUI and replaces only its collector. Nothing is executed.
Prints one line per check: "ok <name>" or "bad <name> <detail>"."""
import importlib.util
import sys
import threading
import time


def load(path):
    spec = importlib.util.spec_from_file_location("tui_under_test", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def snapshot(m, present):
    d = m.Data()
    d.status = {"relations": []}
    d.jobs = {"host": "t", "jobs": []}
    d.monitors = {"monitors": []}
    d.progress = {"transfers": []}
    d.replicas = {"replicas": [{"name": "r1", "present": present}]}
    d.stats = {}
    return d


def main():
    m = load(sys.argv[1])
    entered, release, calls = threading.Event(), threading.Event(), []
    state = {"medium": "away"}            # what the host says at the moment of the read

    def collect(_repo, _files, only=None):
        seen = state["medium"]            # the read takes its picture when it starts
        calls.append(seen)
        if len(calls) == 1:
            entered.set()
            release.wait(20)
        return snapshot(m, seen)

    m.collect = lambda _r, _f, only=None: snapshot(m, "away")   # whatever the constructor reads
    ui = m.UI("/tmp", {}, m.Chars(True), 1700000000, None)
    while getattr(ui, "_bg", None) is not None or getattr(ui, "_bgslow", None) is not None:
        ui.poll_bg(); ui.poll_slow(); time.sleep(0.02)
    m.collect = collect
    ui.screen = "replika"
    ui.refresh_bg()                       # a read already running (periodic, earlier window)
    if not entered.wait(2):
        print("bad setup background collector did not start")
        return
    state["medium"] = "available"         # the replica window formats and saves
    ui.refresh_bg()                       # the post-window request, while the first still runs
    release.set()

    def check(name, cond, detail=""):
        print(("ok %s" % name) if cond else ("bad %s %s" % (name, detail)))

    deadline = time.time() + 5
    while time.time() < deadline:
        ui.poll_bg()
        if ui.data.replicas and ui.data.replicas["replicas"][0]["present"] == "available" \
                and getattr(ui, "_bg", None) is None:
            break
        time.sleep(0.02)
    check("second-request-was-run", len(calls) >= 2, "calls=%r" % calls)
    check("screen-ends-on-post-change-read",
          ui.data.replicas["replicas"][0]["present"] == "available",
          "present=%r calls=%r" % (ui.data.replicas["replicas"][0]["present"], calls))
    check("no-request-left-queued", getattr(ui, "_bg_again", False) is False,
          "_bg_again=%r" % getattr(ui, "_bg_again", False))


if __name__ == "__main__":
    main()
