#!/usr/bin/env python3
"""Read-only reviewer evidence: an age monitor can miss every pvesr deletion.
Run from the repository root:
  python3 docs/internal/reviews/evidence/REV-20261017-152-timing.py
Uses the shipped monitor suite's fake zfs/ssh and the actual monitor; no network,
real ZFS, wall-clock waiting, or production configuration changes are involved.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import time

root = Path.cwd()
world = Path(tempfile.mkdtemp(prefix="rev152-timing-"))
try:
    (world / "bin").mkdir()
    (world / "z").mkdir()
    suite = (root / "test/monitor/run.sh").read_text()
    for name, delimiter in (("zfs", "STUB"), ("ssh", "SSH")):
        anchor = f'cat > "$TMPD/bin/{name}" <<\'{delimiter}\'\n'
        body = suite.split(anchor, 1)[1].split(f"\n{delimiter}\n", 1)[0]
        script = world / "bin" / name
        script.write_text(body)
        script.chmod(0o755)
    env = os.environ.copy()
    env.update(PATH=str(world / "bin") + ":" + env["PATH"],
               ZSTUB_DIR=str(world / "z"), ZSTUB_ROOT=str(world / "hosts"),
               SSH_LOG=str(world / "ssh.log"))
    for key in list(env):
        if key.startswith("SSH_") and key != "SSH_LOG":
            env.pop(key)
        if key.startswith("ZSTUB_") and key not in ("ZSTUB_DIR", "ZSTUB_ROOT"):
            env.pop(key)
    (world / "z/datasets").write_text("tank/guest\n")
    (world / "z/epoch.tank_guest").write_text(str(int(time.time()) - 864000))
    (world / "z/snaps.tank_guest").write_text("pve2_automated_hourly_fresh\n")

    def read_age(age_minutes):
        (world / "z/epoch.tank_guest_pve2_automated_hourly_fresh").write_text(
            str(int(time.time()) - age_minutes * 60))
        return subprocess.run(
            ["bash", str(root / "check-snap-age.sh"), "-v",
             "root@srcA:tank/guest", "pve2_automated_hourly_", "90m", "150m"],
            env=env, text=True, capture_output=True)

    # Snapshot at :01 hourly; monitor at :00/:15/:30/:45. Every 3h at
    # :00, pvesr deletes the locally created points just AFTER the monitor read.
    # The next :01 snapshot exists before the next monitor at :15. Hence the
    # stale surviving common point is never sampled. This is an ordering model
    # of the read states, not a simulation or execution of ZFS receive itself.
    rows = []
    for minute in range(0, 361, 15):
        latest = ((minute - 1) // 60) * 60 + 1
        age = minute - latest
        result = read_age(age)
        assert result.returncode == 0, (minute, age, result.stdout, result.stderr)
        rows.append((minute, age, result.returncode))
    print("25 actual monitor reads: all OK; ages 14..59 min.")
    print("Two 3h pvesr cycles; the sampled state sequence can repeat indefinitely.")
    print("First ticks:", rows[:5], "cycle boundary:", rows[12:15])
    result = read_age(240)
    assert result.returncode == 2, (result.returncode, result.stdout, result.stderr)
    print("Control: sampling the old surviving point in the deletion window is CRITICAL (rc 2).")
finally:
    shutil.rmtree(world)
