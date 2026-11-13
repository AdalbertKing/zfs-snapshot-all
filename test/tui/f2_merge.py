#!/usr/bin/env python3
"""U166 + U171 regression (pve1 SITE-C 2026-11-09, mockup accepted the same day).

U166: F2 runs read newest first -- upcoming on top, the "now" line, past below; the cursor
starts on the first past run right under "now". Upcoming runs only from the next
PRZ_AHEAD_H hours.
U171: three cron lines of one relation at one time (snapget -s on hdd/data, rpool/ROOT,
rpool/data) are ONE row "snapshot hourly: 3 datasety": worst result, longest time,
"PADŁ 1/3" when one failed; collapsed by default, also on failure; Enter expands it to
one row per dataset with the full ZFS path and collapses it again.
Controls: a relation with one dataset is a plain row without a marker; all three OK
reads "OK 3/3".

Imports the shipped TUI and replaces only its collector. Prints "ok <name>" / "bad <name> ...".
"""
import datetime
import importlib.util
import sys
import time


def load(path):
    spec = importlib.util.spec_from_file_location("tui_under_test", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


UTC = datetime.timezone.utc
NOW = int(datetime.datetime(2026, 11, 9, 20, 22, tzinfo=UTC).timestamp())
DS = ["hdd/data", "rpool/ROOT", "rpool/data"]


def iso(h, mi, s):
    return datetime.datetime(2026, 11, 9, h, mi, s, tzinfo=UTC).strftime("%Y-%m-%dT%H:%M:%S+00:00")


def jobrow(name, task, tier, ds, sched, nxt):
    lbl = "pve1 %s %s (%s)" % (tier, task.split()[0], ds.replace("/", "-"))
    j = {"scope": "zfsbackup@10.0.0.10:%s" % ds, "section_kind": "snaponly", "tier": tier}
    return {"kind": "job", "name": name, "task": task, "tier": tier, "jobs": [j], "job": j, "clabel": lbl,
            "schedule": sched, "next_epoch": nxt}


def snapshot(m):
    d = m.Data()
    d.status = {"relations": []}
    d.jobs = {"host": "pve1", "jobs": []}
    d.monitors = {"monitors": []}
    d.progress = {"transfers": []}
    d.replicas = {"replicas": []}
    d.stats = {}
    return d


def main():
    m = load(sys.argv[1])
    m.collect = lambda _r, _f, only=None: snapshot(m)
    ui = m.UI("/tmp", {}, m.Chars(True), NOW, None)
    while getattr(ui, "_bg", None) is not None or getattr(ui, "_bgslow", None) is not None:
        ui.poll_bg(); ui.poll_slow(); time.sleep(0.02)
    ui.now = lambda: NOW

    def check(name, cond, detail=""):
        print(("ok %s" % name) if cond else ("bad %s %s" % (name, detail)))

    def setup(fail):
        jr = [jobrow("pve0", "snapshot", "hourly", d, "44 * * * *", NOW + 22 * 60) for d in DS]
        jr.append(jobrow("solo", "snapshot", "hourly", "tank/solo", "30 * * * *", NOW + 8 * 60))
        jr.append(jobrow("pve0", "snapshot", "daily", "hdd/data", "10 16 * * *", NOW + 20 * 3600))
        runs = []
        for i, j in enumerate(jr[:3]):
            for h in (18, 19):
                rc = 1 if (fail and h == 19 and DS[i] == "rpool/data") else 0
                runs.append({"label": j["clabel"], "start": iso(h, 44, 1), "end": iso(h, 44, 2 + i), "rc": rc,
                             "error": "boom" if rc else ""})
        runs.append({"label": jr[3]["clabel"], "start": iso(19, 30, 1), "end": iso(19, 30, 5), "rc": 0})
        ui.data.stats = {"runs": runs}
        ui.jobrows = jr
        ui.prz_open = set()
        try:
            ui.runrows = m.build_runs(ui.data, jr, NOW, True, False, opened=ui.prz_open)
        except TypeError:      # the TUI before U171 (negative control)
            ui.runrows = m.build_runs(ui.data, jr, NOW, True, False)
        ui.screen = "zadania"
        ui.cursor["zadania"] = ui.run_cursor_for(None)

    def text():
        scr = m.render_zadania(ui.data, ui.runrows, ui.cursor["zadania"], 200, 40, NOW, ui.ch)
        return "\n".join(scr.lines)

    setup(False)
    rows = ui.runrows
    kinds = [(r["kind"], r.get("past"), bool(r.get("agg"))) for r in rows]
    ni = [i for i, r in enumerate(rows) if r["kind"] == "now"]
    ats = [r["at"] for r in rows if r["kind"] == "run"]
    check("u166-newest-first", ats == sorted(ats, reverse=True), "ats=%r" % ats)
    check("u166-upcoming-above-now-past-below", len(ni) == 1 and all(not r["past"] for r in rows[:ni[0]])
          and all(r["past"] for r in rows[ni[0] + 1:]), "kinds=%r" % kinds)
    check("u166-cursor-right-under-now", ni and ui.cursor["zadania"] == ni[0] + 1, "cur=%r now=%r" % (ui.cursor["zadania"], ni))
    check("u166-no-upcoming-beyond-6h", not any(r.get("item", {}).get("tier") == "daily" for r in rows if r["kind"] == "run"),
          "daily row shown")
    aggs = [r for r in rows if r.get("agg") and r["past"]]
    up = [r for r in rows if r.get("agg") and not r["past"]]
    check("u171-three-lines-one-row", len(aggs) == 2 and up and all(len(r["agg"]) == 3 for r in aggs + up)
          and not any(r["kind"] == "run" and r["name"] == "pve0" and not r.get("agg") for r in rows),
          "aggs=%r" % [(r["at"], len(r["agg"])) for r in aggs])
    t = text()
    check("u171-row-says-3-datasets", "> snapshot hourly: 3 datasety" in t, t)
    check("u171-all-ok-reads-ok-3-3", "OK 3/3" in t, t)
    check("u171-longest-time", bool(aggs) and m.fmt_dur(aggs[0]["end"] - aggs[0]["start"]) == m.fmt_dur(3), "agg=%r" % aggs[:1])
    solo = [r for r in rows if r["kind"] == "run" and r["name"] == "solo"]
    check("control-one-dataset-is-plain-row", solo and not any(r.get("agg") for r in solo)
          and not any("> snapshot hourly: solo" in ln for ln in t.splitlines()), "solo=%r" % solo)

    setup(True)
    c = ui.cursor["zadania"]
    r = ui.runrows[c]
    check("u171-failure-padl-1-3-collapsed", r.get("agg") and m.run_result(r) == u"BŁĄD 1/3"
          and not any(x.get("child") for x in ui.runrows), "res=%r" % m.run_result(r))
    ui.key("enter", 40)
    rows = ui.runrows
    c = ui.cursor["zadania"]
    kids = rows[c + 1:c + 4]
    check("u171-enter-expands-full-paths", rows[c].get("agg") and rows[c].get("open") and [x.get("child") for x in kids] == [True] * 3
          and [x["jobs"][0]["scope"].rsplit(":", 1)[-1] for x in kids] == DS, "kids=%r" % [(x.get("child"), x.get("label")) for x in kids])
    t = text()
    check("u171-expanded-text", "v snapshot hourly: 3 datasety" in t and "    rpool/data" in t and "BŁĄD rc=1" in t, t)
    check("u171-window-not-opened", ui.window is None, "window=%r" % (ui.window,))
    ui.key("enter", 40)
    check("u171-enter-collapses", not any(x.get("child") for x in ui.runrows) and ui.runrows[ui.cursor["zadania"]].get("agg"),
          "rows=%r" % [x["kind"] for x in ui.runrows])

    # U189 (lab pve11 2026-11-11, Owner: 5-minute threshold): lines of one relation spread over
    # the first FREE minutes (:00 :01 :03 -- :02 taken by another job) are ONE row, the time of
    # an upcoming row is the earliest line's. Control: the same relation's line at :20
    # (17 minutes after :03) stays its own row.
    sp = [(0, "hdd/data"), (1, "hdd/docs"), (3, "hdd/mail"), (20, "hdd/fz0a")]
    jr = [jobrow("pve9b", "pull", "hourly", d, "%d * * * *" % mi, NOW - 22 * 60 + (60 + mi) * 60) for mi, d in sp]
    runs = [{"label": j["clabel"], "start": iso(h, mi, 1), "end": iso(h, mi, 3), "rc": 0}
            for (mi, _d), j in zip(sp, jr) for h in (18, 19)]
    ui.data.stats = {"runs": runs}
    ui.jobrows = jr
    ui.prz_open = set()
    try:
        ui.runrows = m.build_runs(ui.data, jr, NOW, True, False, opened=ui.prz_open)
    except TypeError:
        ui.runrows = m.build_runs(ui.data, jr, NOW, True, False)
    rr = [r for r in ui.runrows if r["kind"] == "run"]
    past = [r for r in rr if r["past"]]
    upc = [r for r in rr if not r["past"]]
    big = [r for r in rr if len(r.get("agg") or ()) == 3]
    fz = [r for r in rr if not r.get("agg") and r["jobs"][0]["scope"].endswith("hdd/fz0a")]
    first_up = [r for r in upc if r.get("agg")][:1]
    check("u189-spread-minutes-one-row", len(past) == 4 and len(big) >= 3 and len(fz) >= 3,
          "rows=%r" % [(r["at"], len(r.get("agg") or ()), r["past"]) for r in rr])
    check("u189-upcoming-time-is-earliest", bool(first_up) and first_up[0]["at"] % 3600 == 0,
          "at=%r" % [r["at"] % 3600 for r in first_up])


if __name__ == "__main__":
    main()
