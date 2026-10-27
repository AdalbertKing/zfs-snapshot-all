#!/bin/bash
# Actual-entry-point negative control for REV-20261028-178.
# No ZFS state is touched: every external command is an isolated executable stub.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/run" "$TMP/conf"
export D="$TMP"

fake() { printf '%s\n' '#!/bin/bash' >"$TMP/bin/$1"; sed '1d' >>"$TMP/bin/$1"; chmod +x "$TMP/bin/$1"; }

fake id <<'EOF'
#!/bin/bash
[ "${1:-}" = -u ] && { echo 0; exit 0; }
exit 1
EOF
fake whiptail <<'EOF'
#!/bin/bash
for a in "$@"; do case "$a" in --msgbox|--infobox) exit 0 ;; esac; done
line="$(head -1 "$D/answers")"
tail -n +2 "$D/answers" >"$D/a.new"; mv "$D/a.new" "$D/answers"
case "$line" in OK\ *) printf %s "${line#OK }" >&2; exit 0 ;; *) exit 1 ;; esac
EOF
fake tree <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in --spec) spec="$2"; shift 2;; --out) out="$2"; shift 2;; *) shift;; esac; done
line="$(head -1 "$D/answers")"; tail -n +2 "$D/answers" >"$D/a.new"; mv "$D/a.new" "$D/answers"
case "$line" in OK\ d*) n="${line#OK d}";; *) exit 1;; esac
python3 - "$spec" "$out" "$n" <<'PY'
import json, sys
s=json.load(open(sys.argv[1])); a=s['selectable'][int(sys.argv[3])]
json.dump({'action':'next','roots':[a]},open(sys.argv[2],'w'))
PY
EOF
fake zfs <<'EOF'
#!/bin/bash
echo "zfs $*" >>"$D/log"; last="${@: -1}"; k="${last//\//%}"
case "$*" in
  'list -H -o name -t filesystem,volume') printf 'tank/c1\ntank/c2\n';;
  'list -H -o name,type -r -- '*) printf '%s\tfilesystem\n' "$last";;
  'list -H -t snapshot -o name -d 1 -- '*) echo "$last@s1";;
  'list -H -p -t snapshot -o name,creation,used,written -s creation -d 1 -- '*) printf '%s@s1\t1000\t1\t1\n' "$last";;
  'get -H -o value encryptionroot -- tank/c1') echo tank/key1;;
  'get -H -o value encryptionroot -- tank/c2') echo tank/key2;;
  'get -H -o value keystatus -- '*) cat "$D/ks.$k";;
  'get -H -o value keyformat -- '*) echo hex;;
  'load-key -L prompt -- '*) cat >/dev/null; echo available >"$D/ks.$k";;
  'unload-key -- '*) echo unavailable >"$D/ks.$k";;
  *) exit 1;;
esac
EOF
fake mount <<'EOF'
#!/bin/bash
echo "mount $*" >>"$D/log"
if ! [ -e "$D/failed-once" ]; then touch "$D/failed-once"; exit 1; fi
touch "$D/mounted"; exit 0
EOF
fake mountpoint <<'EOF'
#!/bin/bash
[ -e "$D/mounted" ]
EOF
fake umount <<'EOF'
#!/bin/bash
rm -f "$D/mounted"; exit 0
EOF
for x in mc clear; do printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/$x"; chmod +x "$TMP/bin/$x"; done

printf 'unavailable\n' >"$TMP/ks.tank%key1"
printf 'unavailable\n' >"$TMP/ks.tank%key2"
# First mount fails. Cancel its snapshot menu, then browse the second encryption root.
printf 'OK d0\nOK p0\nOK first\nCANCEL\nOK d1\nOK p0\nOK second\n' >"$TMP/answers"
: >"$TMP/log"

runner=(); command -v setsid >/dev/null 2>&1 && runner=(setsid -w)
PATH="$TMP/bin:$PATH" WHIPTAIL="$TMP/bin/whiptail" ZFS_TREE="$TMP/bin/tree" \
  BROWSE_MC="$TMP/bin/mc" BROWSE_ROOT="$TMP/run" ZFS_CONF_DIR="$TMP/conf" \
  "${runner[@]}" bash "$REPO/tui/browse.sh" --any </dev/null >"$TMP/out" 2>&1
rc=$?

printf 'head=%s blob=%s rc=%s key1=%s key2=%s\n' \
  "$(git -C "$REPO" rev-parse HEAD)" "$(git -C "$REPO" hash-object tui/browse.sh)" "$rc" \
  "$(cat "$TMP/ks.tank%key1")" "$(cat "$TMP/ks.tank%key2")"
grep '^zfs \(load\|unload\)-key' "$TMP/log"

if [ "$(cat "$TMP/ks.tank%key1")" != unavailable ]; then
  echo 'FAIL: tank/key1 remains loaded after exit' >&2
  exit 1
fi
[ "$(cat "$TMP/ks.tank%key2")" = unavailable ] || { echo 'FAIL: tank/key2 remains loaded after exit' >&2; exit 1; }
echo PASS
