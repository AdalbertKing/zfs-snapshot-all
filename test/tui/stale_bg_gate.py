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

    # A refresh that FAILS leaves the old rows: row actions wait for a successful one.
    mode = ["stale"]

    def collect2(_repo, _files, only=None):
        if mode[0] == "fail":
            raise RuntimeError("reader died")
        return stale if mode[0] == "stale" else fresh

    m.collect = collect2
    ui2 = m.UI("/tmp", {}, m.Chars(True), 1700000000, None)
    ui2.screen = "relacje"
    mode[0] = "fail"
    ui2.refresh_bg()
    ui2._bg[0].join(5)
    ui2.pending_shell = None
    r = ui2.key("del")
    check("failed-refresh-del-schedules-nothing",
          r == "stay" and not ui2.pending_shell and "NIEAKTUALNY" in (ui2.message or ""),
          "r=%r shell=%r msg=%r" % (r, ui2.pending_shell, ui2.message))
    check("failed-refresh-navigation-still-works", ui2.key("down") != "quit" and not ui2.pending_shell)
    # The command line takes typing, but its F keys fall through to the rows: F7 there is refused.
    ui2.focus, ui2.cmd = "cmd", ""
    ui2.key("x")
    typed = ui2.cmd == "x"
    ui2.pending_shell = None
    r7 = ui2.key("F7")
    check("failed-refresh-cmdline-types-but-F7-refused",
          typed and r7 == "stay" and not ui2.pending_shell and not ui2.window and "NIEAKTUALNY" in (ui2.message or ""),
          "typed=%r r=%r shell=%r window=%r" % (ui2.cmd, r7, ui2.pending_shell, ui2.window and ui2.window[0]))
    ui2.focus, ui2.cmd = "list", ""
    mode[0] = "fresh"
    ui2.refresh()                      # what Ctrl-R ends in (run_pending)
    ui2.pending_shell = None
    ui2.key("del")
    shell = ui2.pending_shell or ""
    check("after-successful-refresh-del-targets-fresh-row", "fresh-relation" in shell, "shell=%r" % shell)

    # REV-20261023-173: after a failed refresh EVERY row-dependent key is refused, not a
    # fixed list -- Ins on Templates copied the stale selected profile. Row-free keys
    # (navigation, screen switch) still work; after a successful refresh Ins uses the
    # fresh profile.
    def tsnap(name):
        d = snapshot(m, "r")
        d.profiles = [{"name": name}]
        return d
    tmode = ["stale"]

    def collect3(_repo, _files, only=None):
        if tmode[0] == "fail":
            raise RuntimeError("reader died")
        return tsnap("stale-template" if tmode[0] == "stale" else "fresh-template")

    m.collect = collect3
    ui3 = m.UI("/tmp", {}, m.Chars(True), 1700000000, None)
    ui3.screen = "szablony"
    tmode[0] = "fail"
    ui3.refresh_bg()
    ui3._bg[0].join(5)
    rec = []
    ui3.run_template_dialog = lambda argv: rec.append(argv) or "shell"
    r_del = ui3.key("del")
    r_ins = ui3.key("ins")
    check("failed-refresh-templates-del-and-ins-refused",
          r_del == "stay" and r_ins == "stay" and not rec and "NIEAKTUALNY" in (ui3.message or "")
          and "Ctrl-R" in (ui3.message or ""),
          "del=%r ins=%r rec=%r msg=%r" % (r_del, r_ins, rec, ui3.message))
    ui3.key("down")
    nav_ok = "NIEAKTUALNY" not in (ui3.message or "")
    ui3.key("F3")
    check("failed-refresh-row-free-keys-pass", nav_ok and ui3.screen == "relacje", "screen=%r" % ui3.screen)
    ui3.key("F5")
    tmode[0] = "fresh"
    ui3.ensure_profiles = lambda: setattr(ui3.data, "profiles", ui3.data.profiles or [{"name": "fresh-template"}])
    ui3.refresh()
    ui3.cursor["szablony"] = 0
    rec[:] = []
    ui3.key("ins")
    check("after-successful-refresh-ins-uses-fresh-profile",
          any("--from=fresh-template" in a for argv in rec for a in argv) and not any("stale-template" in a for argv in rec for a in argv),
          "rec=%r" % rec)


if __name__ == "__main__":
    main()
