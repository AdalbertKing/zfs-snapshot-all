#!/bin/bash
# Unit tests for the link-tuning cache in lib-zfs-snap.sh (the -A flag).
#
# Deliberately NOT an integration test. Everything here runs with no ZFS, no
# root, no network and no real host, because the part of -A that can silently go
# wrong is bookkeeping, not measurement: which file a verdict is filed under,
# whether a stale one is noticed, and what happens when a probe fails. Those are
# all decidable from a synthetic cache directory, so they belong in a suite that
# runs on the dev box too -- unlike test/snapsend/run.sh, which needs a PVE host.
#
# The one thing that IS exercised for real is tune_probe_stream, via a stub
# `zfs` on PATH. Its rates depend on wall-clock timing, so the assertions are
# properties (ratio is correct, comp never exceeds raw, the probe succeeds at
# all) rather than numbers -- see the comment at that section.
#
# Usage: ./run.sh     (override the library under test with LIB=)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="${LIB:-$REPO/lib-zfs-snap.sh}"

[ -r "$LIB" ] || { echo "cannot read lib-zfs-snap.sh at $LIB" >&2; exit 1; }
command -v md5sum >/dev/null || { echo "md5sum not found" >&2; exit 1; }

# Globals the library expects its callers to have set. VERBOSE=0 keeps log()
# quiet without stubbing it -- the real log() is what production runs, and a
# stub here could hide a crash inside it.
VERBOSE=0
SSH_OPTS=()
COMPRESS_PIPE="cat"

# shellcheck disable=SC1090
source "$LIB"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
export ZFS_SNAP_CACHE_DIR="$TMPD/cache"

PASS=0
FAIL=0
check() {
    local desc="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then
        echo "PASS $desc"; PASS=$((PASS+1))
    else
        echo "FAIL $desc"; echo "     want: [$want]"; echo "     got:  [$got]"; FAIL=$((FAIL+1))
    fi
}

NOW=$(date +%s)
V="probe_version=$TUNE_PROBE_VERSION"

# --- tune_field -------------------------------------------------------------
# Exact-key parsing. The fields deliberately share suffixes (link_mbps,
# raw_mbps, comp_mbps), which is precisely what a loose regex would confuse.

L="measured_at=100 $V ratio=2.34 raw_mbps=450 comp_mbps=300 dataset=tank/a"
check "field: ratio"                "2.34"   "$(tune_field ratio "$L")"
check "field: raw_mbps"             "450"    "$(tune_field raw_mbps "$L")"
check "field: comp_mbps"            "300"    "$(tune_field comp_mbps "$L")"
check "field: dataset keeps its /"  "tank/a" "$(tune_field dataset "$L")"
tune_field nope "$L" >/dev/null
check "field: missing key returns 1" "1" "$?"
check "field: a suffix is not a key" "" "$(tune_field mbps "$L")"
check "field: a prefix is not a key" "" "$(tune_field raw "$L")"

# --- cache keys -------------------------------------------------------------
# The whole point of the split: what shares a file and what must not.

PORT=22
sa=$(tune_stream_cache_file host1 "tank/a")
check "key: two datasets never share a stream file" "differ" \
      "$([ "$sa" != "$(tune_stream_cache_file host1 'tank/b')" ] && echo differ)"
# 'a-b' vs 'a_b' would collide under any tr-based sanitiser. This is the case
# that made hashing the dataset non-negotiable.
check "key: names differing only in punctuation do not collide" "differ" \
      "$([ "$(tune_stream_cache_file host1 'tank/a-b')" != "$(tune_stream_cache_file host1 'tank/a_b')" ] && echo differ)"
check "key: two hosts never share a stream file" "differ" \
      "$([ "$sa" != "$(tune_stream_cache_file host2 'tank/a')" ] && echo differ)"
check "key: link and stream files are distinct" "differ" \
      "$([ "$(tune_cache_file host1)" != "$sa" ] && echo differ)"
la=$(tune_cache_file host1)
PORT=2222
check "key: port is part of the link key"   "differ" "$([ "$la" != "$(tune_cache_file host1)" ] && echo differ)"
check "key: port is part of the stream key" "differ" "$([ "$sa" != "$(tune_stream_cache_file host1 'tank/a')" ] && echo differ)"
PORT=22
check "key: same dataset and host is stable across calls" "same" \
      "$([ "$sa" = "$(tune_stream_cache_file host1 'tank/a')" ] && echo same)"
# root and zfsbackup measure the same wire and the same data, so tune_apply
# strips user@ before keying. Asserted through the same expression tune_apply
# uses, since that stripping is what makes one probe serve both accounts.
r="root@host1"; z="zfsbackup@host1"
check "key: user@ is stripped, so accounts share one measurement" "same" \
      "$([ "$(tune_cache_file "${r#*@}")" = "$(tune_cache_file "${z#*@}")" ] && echo same)"

# --- tune_cache_dir ---------------------------------------------------------
check "dir: ZFS_SNAP_CACHE_DIR wins and is created" "$ZFS_SNAP_CACHE_DIR" "$(tune_cache_dir)"
check "dir: it really exists on disk" "yes" "$([ -d "$ZFS_SNAP_CACHE_DIR" ] && echo yes)"
# An unusable cache must yield empty, never a path -- tune_apply keys off that
# to stand down instead of writing somewhere unintended. A regular file in the
# way is what makes it genuinely uncreatable; a merely deep path would just be
# created by mkdir -p and prove nothing.
: > "$TMPD/blocker"
BADDIR="$TMPD/blocker/deeper"
check "dir: an uncreatable path yields empty, not a guess" "" \
      "$(ZFS_SNAP_CACHE_DIR="$BADDIR" tune_cache_dir 2>/dev/null)"

# --- tune_cache_read / write ------------------------------------------------
F="$ZFS_SNAP_CACHE_DIR/probe"

tune_cache_write "$F" "measured_at=$NOW $V link_mbps=11"
check "cache: a fresh entry is a hit" "11" "$(tune_field link_mbps "$(tune_cache_read "$F" "$NOW")")"
check "cache: write leaves no .tmp behind" "" "$(ls "$ZFS_SNAP_CACHE_DIR"/*.tmp 2>/dev/null)"

tune_cache_read "$F" "$((NOW + TUNE_CACHE_TTL - 10))" >/dev/null
check "cache: still a hit just inside the TTL" "0" "$?"
tune_cache_read "$F" "$((NOW + TUNE_CACHE_TTL + 10))" >/dev/null
check "cache: a miss once past the TTL" "1" "$?"
# A backwards clock would otherwise make an entry look infinitely fresh.
tune_cache_read "$F" "$((NOW - 3600))" >/dev/null
check "cache: a miss when the clock ran backwards" "1" "$?"

tune_cache_write "$F" "measured_at=$NOW probe_version=$((TUNE_PROBE_VERSION - 1)) link_mbps=11"
tune_cache_read "$F" "$NOW" >/dev/null
check "cache: a superseded probe_version is a miss" "1" "$?"
tune_cache_write "$F" "measured_at=$NOW link_mbps=11"
tune_cache_read "$F" "$NOW" >/dev/null
check "cache: a missing probe_version is a miss" "1" "$?"

tune_cache_write "$F" "measured_at=$NOW $V link_mbps=11"
ZFS_SNAP_RETUNE=1 tune_cache_read "$F" "$NOW" >/dev/null
check "cache: ZFS_SNAP_RETUNE=1 forces a miss" "1" "$?"
ZFS_SNAP_RETUNE=0 tune_cache_read "$F" "$NOW" >/dev/null
check "cache: ZFS_SNAP_RETUNE=0 does not" "0" "$?"

tune_cache_read "$ZFS_SNAP_CACHE_DIR/absent" "$NOW" >/dev/null
check "cache: an absent file is a miss" "1" "$?"
tune_cache_write "$F" "half a line"
tune_cache_read "$F" "$NOW" >/dev/null
check "cache: a truncated file is a miss, not a crash" "1" "$?"

# --- tune_decide ------------------------------------------------------------
# effective = min(what the pipeline produces, what the link carries), both in
# MB/s of UNCOMPRESSED data, so the two are comparable.

check "decide: slow link, good ratio -> compress" "yes" \
      "$(tune_decide 10 2.34 450 300 | cut -d' ' -f1)"
check "decide: fast link, poor ratio -> do not"   "no"  \
      "$(tune_decide 100000 1.01 450 90 | cut -d' ' -f1)"
# A ratio worth nothing is worth nothing however fast the compressor is.
check "decide: ratio 1.0 is never worth the CPU"  "no"  \
      "$(tune_decide 10 1.0 450 450 | cut -d' ' -f1)"
# Below TUNE_MARGIN_PCT the answer is no even though the gain is positive:
# a 1.02x ratio on a link-bound transfer buys ~2%, under the 5% margin.
check "decide: a gain under the margin is refused" "no" \
      "$(tune_decide 10 1.02 450 450 | cut -d' ' -f1)"
tune_decide 0 2.34 0 300 >/dev/null
check "decide: a zero rate is rejected, not divided by" "1" "$?"

# --- tune_apply -------------------------------------------------------------
# Driven entirely off pre-seeded cache files, so no probe can run. If any of
# these tests ever starts touching the network, that is the bug -- a cached
# entry must be enough.

seed() {  # seed <host> <link_mbps> [dataset ratio raw comp]...
    local host="$1" link="$2"; shift 2
    tune_cache_write "$(tune_cache_file "$host")" "measured_at=$NOW $V link_mbps=$link host=$host"
    while [ $# -ge 4 ]; do
        tune_cache_write "$(tune_stream_cache_file "$host" "$1")" \
            "measured_at=$NOW $V ratio=$2 raw_mbps=$3 comp_mbps=$4 dataset=$1"
        shift 4
    done
}

# THE regression this suite exists for: one host, one link, two datasets whose
# data compresses very differently. The old code probed DATASETS[0] and filed
# its verdict under the host, so the second dataset inherited the first one's
# answer -- and the order of the -z-less list decided which.
seed pve1 12 rpool/vm 2.34 450 454 rpool/enc 1.01 450 90
COMPRESSION=0; tune_apply root@pve1 rpool/vm;  vm=$COMPRESSION
COMPRESSION=0; tune_apply root@pve1 rpool/enc; enc=$COMPRESSION
check "apply: compressible dataset -> compression on"  "1" "$vm"
check "apply: incompressible dataset -> compression off" "0" "$enc"
check "apply: same host and link, opposite verdicts"   "yes" \
      "$([ "$vm" != "$enc" ] && echo yes)"
# Order must not matter. Reversing the list used to reverse both answers.
COMPRESSION=0; tune_apply root@pve1 rpool/enc >/dev/null; tune_apply root@pve1 rpool/vm
check "apply: verdict does not depend on which dataset came first" "1" "$COMPRESSION"

# Every failure path leaves the caller's setting alone rather than deciding.
# 7 is a value neither branch can produce, so an untouched 7 proves nothing was
# decided -- a plain 0 would be indistinguishable from a verdict of "no".
tune_cache_write "$(tune_stream_cache_file pve1 rpool/damaged)" "measured_at=$NOW $V ratio= raw_mbps= comp_mbps="
COMPRESSION=7; tune_apply root@pve1 rpool/damaged
check "apply: a damaged stream entry leaves compression untouched" "7" "$COMPRESSION"
COMPRESSION=7; ZFS_SNAP_CACHE_DIR="$BADDIR" tune_apply root@pve1 rpool/vm
check "apply: an unusable cache dir leaves compression untouched" "7" "$COMPRESSION"

# The link half is shared: seeding a second dataset for a host whose link is
# already cached must produce a verdict without any link probe. ssh is made to
# fail loudly here, so a verdict at all proves the link came from cache.
seed pve1 12 rpool/third 2.34 450 454
COMPRESSION=0
ssh() { echo "ssh must not be called" >&2; return 1; }
tune_apply root@pve1 rpool/third
unset -f ssh
check "apply: a cached link needs no probe" "1" "$COMPRESSION"

# --- tune_probe_stream ------------------------------------------------------
# Real execution against a stub `zfs`. Rates come from wall-clock timing, so the
# assertions are properties rather than numbers: the ratio is arithmetic and
# exact, while comp/raw are only required to obey the clamp. The >1.5x reject
# needs a controlled clock to trigger on demand and is not covered here.

mkdir -p "$TMPD/bin"
cat > "$TMPD/bin/zfs" <<'STUB'
#!/bin/sh
# Minimal stand-in: `list` names one snapshot, `send` emits its payload. Both
# read the LAST argument, since that is where the library puts the dataset and
# the snapshot -- positional guessing picks up a flag instead and quietly sends
# the wrong payload, which is how this stub was wrong the first time.
cmd=$1
for a in "$@"; do last=$a; done
case "$cmd" in
  list) echo "$last@stub" ;;
  send) case "$last" in
          *incompressible*) cat /dev/urandom ;;
          *)                yes 'the quick brown fox jumps over the lazy dog' ;;
        esac ;;
esac
STUB
chmod +x "$TMPD/bin/zfs"
PATH="$TMPD/bin:$PATH"
TUNE_SAMPLE_MB=1   # keep the suite fast; the arithmetic does not care

# COMPRESS_PIPE=cat is a compressor that compresses nothing: ratio must come out
# at exactly 1, which is the arithmetic identity the rate maths is built on.
COMPRESS_PIPE="cat"
out=$(tune_probe_stream "tank/incompressible")
check "probe: an incompressible stream still yields a measurement" "0" "$?"
check "probe: a no-op compressor measures a ratio of 1" "1.0000" "$(echo "$out" | cut -d' ' -f1)"
check "probe: comp never exceeds raw (the clamp holds)" "clamped" \
      "$(echo "$out" | awk '{print ($3 <= $2 * 1.0001) ? "clamped" : "leaked " $3 " > " $2}')"

if command -v gzip >/dev/null; then
    COMPRESS_PIPE="gzip -1 -c"
    out=$(tune_probe_stream "tank/compressible")
    check "probe: a compressible stream yields a measurement" "0" "$?"
    check "probe: a real compressor reports a ratio above 1" "yes" \
          "$(echo "$out" | awk '{print ($1 > 1) ? "yes" : "no (" $1 ")"}')"
    check "probe: comp never exceeds raw, even at a high ratio" "clamped" \
          "$(echo "$out" | awk '{print ($3 <= $2 * 1.0001) ? "clamped" : "leaked " $3 " > " $2}')"
else
    echo "SKIP probe: compressible cases (no gzip)"
fi

# A dataset with no snapshot cannot be sampled -- the first run of a brand new
# dataset. Must fail cleanly so tuning stands down that once.
cat > "$TMPD/bin/zfs" <<'STUB'
#!/bin/sh
case "$1" in list) : ;; esac
STUB
chmod +x "$TMPD/bin/zfs"
tune_probe_stream "tank/nosnapshot" >/dev/null 2>&1
check "probe: no snapshot to sample is a clean failure" "1" "$?"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
