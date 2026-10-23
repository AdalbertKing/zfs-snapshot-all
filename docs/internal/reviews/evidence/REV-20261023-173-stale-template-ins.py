#!/usr/bin/env python3
"""Safe reproducer for REV-20261023-173.

Import the shipped TUI, make its read-only background collector fail, then
press Del (negative control) and Ins on the stale Templates row.  The action
sink is replaced with an in-memory recorder: no command or dialog is run.
"""
import importlib.util
import sys


def load(path):
    spec = importlib.util.spec_from_file_location("tui_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def snapshot(module, profile):
    data = module.Data()
    data.status = {"relations": []}
    data.jobs = {"host": "review", "jobs": []}
    data.monitors = {"monitors": []}
    data.progress = {"transfers": []}
    data.replicas = {"replicas": []}
    data.stats = {}
    data.profiles = [{"name": profile}]
    return data


def main():
    module = load(sys.argv[1])
    stale = snapshot(module, "stale-template")
    mode = ["stale"]

    def collect(_repo, _files, only=None):
        if mode[0] == "fail":
            raise RuntimeError("reader died")
        return stale

    module.collect = collect
    ui = module.UI("/tmp", {}, module.Chars(True), 1700000000, None)
    ui.screen = "szablony"
    mode[0] = "fail"
    ui.refresh_bg()
    ui._bg[0].join(5)

    recorded = []
    ui.run_template_dialog = lambda argv: recorded.append(argv) or "shell"

    delete_result = ui.key("del")
    delete_recorded = list(recorded)
    delete_message = ui.message

    recorded[:] = []
    insert_result = ui.key("ins")

    print("bg_failed=%r stale_profile=%s" %
          (ui.bg_failed, ui.data.profiles[0]["name"]))
    print("negative_control_del result=%s scheduled=%r blocked=%r" %
          (delete_result, delete_recorded, "NIEAKTUALNY" in delete_message))
    print("stale_ins result=%s scheduled=%r" % (insert_result, recorded))

    expected = [["/tmp/zfs-backup.sh", "save-profile", "--ask",
                 "--from=stale-template"]]
    return 1 if not (ui.bg_failed and delete_result == "stay" and
                     not delete_recorded and "NIEAKTUALNY" in delete_message and
                     insert_result == "shell" and recorded == expected) else 0


if __name__ == "__main__":
    sys.exit(main())
