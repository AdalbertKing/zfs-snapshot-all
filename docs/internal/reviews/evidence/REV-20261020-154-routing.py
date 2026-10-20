#!/usr/bin/env python3
"""Read-only generator contract check. No cron install, SSH or ZFS.

Run from the repository root. Optional positional argument selects another
checkout, e.g. the pre-U49 commit for the negative control.
Known regression: current U49 main fails push-sync; the other three pass.
"""
from pathlib import Path
import os
import shlex
import subprocess
import sys

repo = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd()
env = os.environ.copy()
env['REPO_DIR'] = str(repo)
result = subprocess.run(
    ['bash', str(repo / 'gen-cron.sh'), '-c',
     str(repo / 'test/fixtures/sync-mode.conf')],
    env=env, text=True, capture_output=True, check=True)
expected = {
    'tank/push-base': 'snapsend.sh',
    'tank/push-sync': 'snapsend.sh',
    'tank/push-local': 'snapget.sh',
    'user@far:tank/pull-sync': 'snapget.sh',
}
failed = 0
for source, engine in expected.items():
    matches = [shlex.split(line) for line in result.stdout.splitlines()
               if line and not line.startswith('#')
               and source in shlex.split(line)]
    assert len(matches) == 1, (source, matches)
    words = matches[0]
    actual = Path(words[words.index('--') + 1]).name
    ok = actual == engine
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'} {source}: {actual}; expected {engine}")
print(f'{len(expected) - failed} PASS / {failed} FAIL')
sys.exit(bool(failed))
