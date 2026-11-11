#!/usr/bin/env python3
"""U176 regression (lab pve11 2026-11-09): F2/F3 find a job's runs by the label of its
own cron line. Three shapes measured there took the wrong line:
  - a snaponly relation's snapshot row took the delsnaps line's label (its snapshot
    line is `snapget.sh -s`), so its runs were never shown;
  - a daily/weekly row took the hourly line's label (first candidate wins);
  - a "lokalny prune" row made of several [dataset:] sections took the pull's label.
Control: a plain pull row still takes its snapget line.

Imports the shipped TUI; calls job_cron_label only. Prints "ok <name>" / "bad <name> ..."."""
import importlib.util
import sys


def load(path):
    spec = importlib.util.spec_from_file_location("tui_under_test", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


SO = "zfsbackup-h@10.0.0.9:hdd/u/docs"
SO_LINES = [
    '16 * * * * /r/zfs-job.sh "h1 hourly snapshot (s-docs)" -- /r/snapget.sh -s -m "automated_hourly_" -R "%s" ""' % SO,
    '26 1 * * * /r/zfs-job.sh "h1 daily snapshot (s-docs)" -- /r/snapget.sh -s -m "automated_daily_" -R "%s" ""' % SO,
    '56 * * * * /r/zfs-job.sh "h1 so_src__s__hourly prune (s-src-docs)" -- /r/delsnaps.sh -L s "%s" "automated_hourly_" 24' % SO,
    '6 1 * * * /r/zfs-job.sh "h1 so_src__s__daily prune (s-src-docs)" -- /r/delsnaps.sh -L s "%s" "automated_daily_" 7' % SO,
]
DS, SRC = "hdd/b/p/data", "zfsbackup-h@10.0.0.8:hdd/data"
DS_LINES = [
    '0 * * * * /r/zfs-job.sh "h1 p__hourly snapshot (p-data)" -- /r/snapget.sh -m "automated_hourly_" "%s" "%s"' % (SRC, DS),
    '10 1 * * * /r/zfs-job.sh "h1 p__daily snapshot (p-data)" -- /r/snapget.sh -m "automated_daily_" "%s" "%s"' % (SRC, DS),
    '20 * * * * /r/zfs-job.sh "h1 p__hourly prune (p-data)" -- /r/delsnaps.sh -L p "%s" "automated_hourly_" 24' % DS,
    '30 1 * * * /r/zfs-job.sh "h1 p__daily prune (p-data)" -- /r/delsnaps.sh -L p "%s" "automated_daily_" 7' % DS,
]


def main():
    m = load(sys.argv[1])

    def check(name, got, want):
        print(("ok %s" % name) if got == want else ("bad %s got=%r want=%r" % (name, got, want)))

    so_daily = {"section_kind": "snaponly", "tier": "snaponly__s__daily", "scope": SO, "other_end": SO, "cron_lines": SO_LINES}
    check("snaponly-snapshot-row-takes-snapshot-line-of-its-tier", m.job_cron_label(so_daily), "daily snapshot (s-docs)")
    so_prune = {"section_kind": "prune", "tier": "so_src__s__daily", "scope": SO, "other_end": SO, "cron_lines": SO_LINES}
    check("prune-section-takes-delsnaps-line-of-its-tier", m.job_cron_label(so_prune), "so_src__s__daily prune (s-src-docs)")
    ds = {"section_kind": "dataset", "tier": "p__daily", "scope": DS, "other_end": SRC, "cron_lines": DS_LINES}
    try:
        got = m.job_cron_label(ds, True)
    except TypeError as e:
        got = "TypeError: %s" % e
    check("local-prune-row-of-a-dataset-takes-delsnaps-line", got, "p__daily prune (p-data)")
    ds_h = dict(ds, tier="p__hourly")
    check("control-pull-row-takes-snapget-line", m.job_cron_label(ds_h), "p__hourly snapshot (p-data)")


if __name__ == "__main__":
    main()
