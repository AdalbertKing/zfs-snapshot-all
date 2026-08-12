#!/bin/bash
# Tests for `zfs-backup.sh restore --plan` -- Phase 7 slice 1, the READ-ONLY
# restore planner.
#
#   ./test/restore/run.sh
#
# Pure/text: a stubbed `zfs` on PATH, no real ZFS, no network, no crontab. The
# stub also records every invocation, so "this command only reads" is asserted
# rather than asserted-in-a-comment.
#
# The pair that carries the whole slice is the creation-vs-name pair. The planner
# exists because nobody can currently say what would be restored, and a planner
# that reported the timestamp embedded in the snapshot NAME would answer that
# question with a story instead of a fact. So one fixture has a snapshot whose
# name disagrees with its ZFS `creation`, and one has a snapshot where they agree;
# an implementation that read the name passes neither, and an implementation that
# warned unconditionally passes the first and fails the second.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
ZB="${ZB:-$REPO/zfs-backup.sh}"
[ -r "$ZB" ] || { echo "cannot find zfs-backup.sh at $ZB" >&2; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

mkdir -p "$WORK/bin"
# zfs stub. Records every call; answers snapshot listings from $WORK/snaps.<key>.
# Deliberately answers ONLY `list` -- any other subcommand is recorded and fails,
# so a write would be both visible and fatal.
cat > "$WORK/bin/zfs" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/zfs-calls"
case " \$1 " in
  " list ") ;;
  *) echo "stub: refusing non-list zfs call: \$*" >&2; exit 9 ;;
esac
# REV-20260812-113 F1: the stub now REQUIRES the explicit depth selector. The
# permissive version answered any listing shape, which is what let an unproven
# selector reach a live host in the first place. Drop \`-d 1\` from the planner and
# every snapshot assertion below goes red instead of silently passing.
case " \$* " in
  *" -t snapshot "*)
      case " \$* " in
        *" -d 1 "*) ;;
        *) echo "stub: snapshot listing without an explicit depth selector: \$*" >&2; exit 1 ;;
      esac ;;
esac
for a in "\$@"; do ds="\$a"; done
key=\$(printf '%s' "\$ds" | tr '/' '_')
if [ -f "$WORK/snaps.\$key" ]; then cat "$WORK/snaps.\$key"; exit 0; fi
exit 1
EOF
chmod +x "$WORK/bin/zfs"

# shellcheck disable=SC1090
source "$ZB"

run() {   # <config> args...
    local cfg="$1"; shift
    ( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" \
      cmd_restore --config="$cfg" "$@" ) 2>&1
}

mkcfg() {   # <file> <body...>
    # Capture the path BEFORE shifting: after the shift $1 is the body, and
    # writing to "$1" then means writing to a file named by the config text.
    # That bug made several assertions below pass for the wrong reason before it
    # was caught -- fixtures need the same suspicion as product code.
    local f="$1"; shift
    printf '[defaults]\n\thost_label = t\n' > "$f"
    printf '%b' "$@" >> "$f"
}

# ---- the verb is deliberately narrow -----------------------------------------
cfg="$WORK/basic.conf"
mkcfg "$cfg" '\n[dataset:rpool/data]\n\tdst          = hdd/store\n'

# Slice 2 changed this message on purpose: the verb now also does a safe restore,
# so bare `restore` points at BOTH ways in. What must not change is that it never
# silently defaults to doing something -- it refuses and makes the planner
# discoverable.
out="$(run "$cfg")"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--plan'; } \
    && ok "bare restore refuses and points at --plan rather than doing something" \
    || bad "bare restore refuses and points at --plan rather than doing something" "rc=$rc"

out="$(run "$cfg" --plan --bogus)"; rc=$?
[ "$rc" -ne 0 ] && ok "an unknown option refuses" || bad "an unknown option refuses" "rc=$rc"

out="$( ( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" cmd_restore --plan ) 2>&1 )"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'no cron config known'; } \
    && ok "no config and no server.conf refuses rather than guessing" \
    || bad "no config and no server.conf refuses rather than guessing" "rc=$rc"

empty="$WORK/empty.conf"; mkcfg "$empty" '\n'
out="$(run "$empty" --plan)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'nothing to restore from'; } \
    && ok "a config describing no relationship says so instead of printing an empty plan" \
    || bad "a config describing no relationship says so instead of printing an empty plan" "rc=$rc"

# ---- where the copy actually lives -------------------------------------------
# local push: snapsend recreates the source path UNDER the target, so the copy of
# rpool/data backed up to hdd/store is hdd/store/rpool/data. Getting this wrong
# would send an operator looking in the wrong place during a recovery.
out="$(run "$cfg" --plan)"
printf '%s' "$out" | grep -q 'hdd/store/rpool/data' \
    && ok "local push: the copy path nests the source under the target" \
    || bad "local push: the copy path nests the source under the target" "$(printf '%s' "$out"|grep -i kopia)"

pull="$WORK/pull.conf"
mkcfg "$pull" '\n[dataset:hdd/mirror]\n\tsrc          = zfsbackup@10.0.0.9:tank/x\n'
out="$(run "$pull" --plan)"
{ printf '%s' "$out" | grep -q 'zfsbackup@10.0.0.9:tank/x' && printf '%s' "$out" | grep -qE 'Kopia:[[:space:]]+hdd/mirror$'; } \
    && ok "remote pull: the local dataset IS the copy, the remote is the source" \
    || bad "remote pull: the local dataset IS the copy, the remote is the source" "$(printf '%s' "$out"|grep -iE 'zrodlo|kopia')"

# ---- THE PAIR: creation, never the name --------------------------------------
# name says 2026-01-01 03:00:00, ZFS creation says 2026-06-15 12:00:00.
printf 'hdd/store/rpool/data@automated_hourly_2026-01-01_03-00-00\t%s\t7771\n' "$(date -d '2026-06-15 12:00:00' +%s)" \
    > "$WORK/snaps.hdd_store_rpool_data"
out="$(run "$cfg" --plan)"
{ printf '%s' "$out" | grep -q '2026-06-15 12:00:00' \
  && printf '%s' "$out" | grep -qi 'UWAGA'; } \
    && ok "a snapshot whose name lies is shown at its REAL creation time, and flagged" \
    || bad "a snapshot whose name lies is shown at its REAL creation time, and flagged" "$(printf '%s' "$out"|grep -A2 Snapshoty)"

# negative control: name and creation agree -> the same code path must stay quiet.
# Without this, an implementation that flagged every snapshot would pass above.
printf 'hdd/store/rpool/data@automated_hourly_2026-06-15_12-00-00\t%s\t7772\n' "$(date -d '2026-06-15 12:00:00' +%s)" \
    > "$WORK/snaps.hdd_store_rpool_data"
out="$(run "$cfg" --plan)"
{ printf '%s' "$out" | grep -q '2026-06-15 12:00:00' \
  && ! printf '%s' "$out" | grep -qi 'UWAGA'; } \
    && ok "a snapshot whose name agrees with creation is NOT flagged (control)" \
    || bad "a snapshot whose name agrees with creation is NOT flagged (control)" "$(printf '%s' "$out"|grep -A2 Snapshoty)"

# a snapshot carrying no timestamp in its name at all must not be flagged either.
printf 'hdd/store/rpool/data@manual-before-upgrade\t%s\t7773\n' "$(date -d '2026-06-15 12:00:00' +%s)" \
    > "$WORK/snaps.hdd_store_rpool_data"
out="$(run "$cfg" --plan)"
{ printf '%s' "$out" | grep -q 'manual-before-upgrade' && ! printf '%s' "$out" | grep -qi 'UWAGA'; } \
    && ok "a name with no embedded timestamp is listed, not flagged" \
    || bad "a name with no embedded timestamp is listed, not flagged" "$(printf '%s' "$out"|grep -A2 Snapshoty)"

# ---- honest about an absent copy ---------------------------------------------
rm -f "$WORK/snaps.hdd_store_rpool_data"
out="$(run "$cfg" --plan)"
printf '%s' "$out" | grep -qi 'BRAK' \
    && ok "a copy that does not exist is reported as nothing to restore from" \
    || bad "a copy that does not exist is reported as nothing to restore from" ""

# ---- the filter ---------------------------------------------------------------
two="$WORK/two.conf"
mkcfg "$two" '\n[dataset:rpool/data]\n\tdst          = hdd/store\n\n[dataset:rpool/other]\n\tdst          = hdd/store\n'
out="$(run "$two" --plan --dataset=rpool/other)"
{ printf '%s' "$out" | grep -q 'rpool/other' && ! printf '%s' "$out" | grep -qE 'Zrodlo:[[:space:]]+rpool/data$'; } \
    && ok "--dataset selects one relationship" || bad "--dataset selects one relationship" "$(printf '%s' "$out"|grep -i zrodlo)"
out="$(run "$two" --plan --dataset=rpool/nosuch)"
printf '%s' "$out" | grep -qi 'Nic nie pasuje' \
    && ok "a filter that matches nothing says so instead of printing an empty plan" \
    || bad "a filter that matches nothing says so instead of printing an empty plan" ""

# ---- READ-ONLY, asserted from the recorded calls ------------------------------
# Every zfs invocation across every run above must be a `list`. The stub fails any
# other subcommand, so a write would also have been fatal -- this checks the record
# as well, because a future change could reach ZFS through some other path.
if [ -f "$WORK/zfs-calls" ] && grep -qv '^list ' "$WORK/zfs-calls" 2>/dev/null; then
    bad "read-only: every zfs call was a list" "$(grep -v '^list ' "$WORK/zfs-calls" | head -3)"
else
    ok "read-only: every zfs call across every plan was a list"
fi

# ==============================================================================
# Planner map: guid + consistency (OWNER-RECOVERY-FLAT-ATOMIC-SEMANTICS-2026-08-12)
#
# The planner must emit {dataset -> snapshot, guid, creation, consistency}, and
# consistency must come from the installed CONFIG and from nothing else.
# ==============================================================================
printf 'hdd/store/rpool/data@automated_hourly_2026-06-15_12-00-00\t%s\t991\n' "$(date -d '2026-06-15 12:00:00' +%s)" \
    > "$WORK/snaps.hdd_store_rpool_data"

out="$(run "$cfg" --plan)"
printf '%s' "$out" | grep -q 'guid=991' \
    && ok "planner: the recovery point carries its guid" \
    || bad "planner: the recovery point carries its guid" "$(printf '%s' "$out"|grep -A2 Snapshoty)"

# ---- consistency comes from CONFIG: flat ------------------------------------
{ printf '%s' "$out" | grep -qi 'INDEPENDENT' && printf '%s' "$out" | grep -qi 'frontier' \
  && ! printf '%s' "$out" | grep -qi 'ATOMIC'; } \
    && ok "planner: a CONFIG without recursive=atomic reports an INDEPENDENT frontier" \
    || bad "planner: a CONFIG without recursive=atomic reports an INDEPENDENT frontier" "$(printf '%s' "$out"|grep -i spojnosc)"

# ---- consistency comes from CONFIG: atomic ----------------------------------
acfg="$WORK/atomic.conf"
mkcfg "$acfg" '\n[dataset:rpool/data]\n\tdst          = hdd/store\n\trecursive    = atomic\n'
out="$(run "$acfg" --plan)"
{ printf '%s' "$out" | grep -qi 'ATOMIC' && printf '%s' "$out" | grep -qi 'punkt odtworzenia'; } \
    && ok "planner: recursive = atomic in CONFIG reports an ATOMIC recovery point" \
    || bad "planner: recursive = atomic in CONFIG reports an ATOMIC recovery point" "$(printf '%s' "$out"|grep -i spojnosc)"

# ---- THE MEASURED TRAP, encoded ---------------------------------------------
# On pve2 two datasets in different subtrees share the snapshot name
# automated_hourly_2026-08-11_23-37-01 while their creation times differ by one
# second: one snapsend run names every dataset from a single clock read. A planner
# that inferred atomicity from matching names would announce a recovery point that
# never existed. Here two relationships carry the SAME snapshot name under a FLAT
# CONFIG; the verdict must stay INDEPENDENT for both.
tcfg="$WORK/twin.conf"
mkcfg "$tcfg" '\n[dataset:rpool/data]\n\tdst          = hdd/store\n\n[dataset:rpool/db]\n\tdst          = hdd/store\n'
printf 'hdd/store/rpool/data@automated_hourly_2026-08-11_23-37-01\t1786484223\t111\n' > "$WORK/snaps.hdd_store_rpool_data"
printf 'hdd/store/rpool/db@automated_hourly_2026-08-11_23-37-01\t1786484222\t222\n'   > "$WORK/snaps.hdd_store_rpool_db"
out="$(run "$tcfg" --plan)"
{ [ "$(printf '%s\n' "$out" | grep -ci 'INDEPENDENT')" -eq 2 ] \
  && ! printf '%s' "$out" | grep -qi 'ATOMIC' \
  && printf '%s' "$out" | grep -q 'guid=111' && printf '%s' "$out" | grep -q 'guid=222'; } \
    && ok "planner: identical snapshot NAMES across datasets do not promote a flat set to atomic" \
    || bad "planner: identical snapshot NAMES across datasets do not promote a flat set to atomic" \
           "$(printf '%s' "$out"|grep -iE 'spojnosc|guid=')"

# and the same pair under an ATOMIC config must report atomic -- so the verdict is
# demonstrably keyed on CONFIG, not on the snapshots, which are identical here.
tacfg="$WORK/twinatomic.conf"
mkcfg "$tacfg" '\n[dataset:rpool/data]\n\tdst          = hdd/store\n\trecursive    = atomic\n\n[dataset:rpool/db]\n\tdst          = hdd/store\n\trecursive    = atomic\n'
out="$(run "$tacfg" --plan)"
{ [ "$(printf '%s\n' "$out" | grep -ci 'ATOMIC')" -ge 2 ] && ! printf '%s' "$out" | grep -qi 'INDEPENDENT'; } \
    && ok "planner: the SAME snapshots under an atomic CONFIG report atomic (verdict keyed on CONFIG)" \
    || bad "planner: the SAME snapshots under an atomic CONFIG report atomic (verdict keyed on CONFIG)" \
           "$(printf '%s' "$out"|grep -i spojnosc)"
rm -f "$WORK/snaps.hdd_store_rpool_db"

# ==============================================================================
# Phase 7 slice 2 -- the SAFE restore, after REV-20260812-114.
#
# Ownership is a fact, not an inference. The receive lands in a per-attempt
# staging dataset; only a verified result is promoted to the public path with
# `zfs rename`, which refuses an existing destination (proved live on pve1:
# rc=1, source kept, destination untouched). So the destructive TOCTOU is gone:
# cleanup can only ever target this attempt's own staging name.
#
# Two contract reversals from the first cut, both deliberate:
#   * the early collision check is now only an ergonomic short-circuit. It proves
#     nothing and nothing depends on it.
#   * namespace ancestors are created and NOT removed. The first cut destroyed its
#     own scaffolding to keep retries clean; staging keeps them clean anyway, and
#     ancestor removal is exactly the case where ownership cannot be proven.
# ==============================================================================
mkdir -p "$WORK/bin2"
cat > "$WORK/bin2/zfs" <<ZSTUB
#!/bin/sh
echo "\$*" >> "$WORK/zfs-calls2"
k() { printf '%s' "\$1" | tr '/@' '__'; }
case "\$1" in
  list)
      for a in "\$@"; do ds="\$a"; done
      case " \$* " in
        *" -t snapshot "*)
            grep -q "^\$ds@" "$WORK/ds" 2>/dev/null || exit 1
            grep "^\$ds@" "$WORK/ds"; exit 0 ;;
        *)  grep -qx "\$ds" "$WORK/ds" 2>/dev/null || exit 1
            echo "\$ds"; exit 0 ;;
      esac ;;
  get)
      for a in "\$@"; do ds="\$a"; done
      v=\$(cat "$WORK/guid.\$(k "\$ds")" 2>/dev/null)
      [ -n "\$v" ] || v="-"
      echo "\$v"; exit 0 ;;
  create)
      for a in "\$@"; do ds="\$a"; done
      echo "\$ds" >> "$WORK/ds"
      case "\$ds" in */*) echo "\${ds%/*}" >> "$WORK/ds" ;; esac
      exit 0 ;;
  send)
      echo STREAM; exit 0 ;;
  recv|receive)
      cat >/dev/null
      if [ -n "\${FAIL_RECV:-}" ]; then echo "recv exploded" >&2; exit 1; fi
      for a in "\$@"; do ds="\$a"; done
      echo "\$ds" >> "$WORK/ds"
      echo "\$ds@s1" >> "$WORK/ds"
      printf '%s' "\${RECV_GUID:-111}" > "$WORK/guid.\$(k "\$ds@s1")"
      # INJECT_LANDING models ANOTHER actor creating the final landing path after
      # this run's collision check has already passed -- the REV-114 race.
      if [ -n "\${INJECT_LANDING:-}" ]; then
        echo "\${INJECT_LANDING}" >> "$WORK/ds"
        echo "\${INJECT_LANDING}@foreign" >> "$WORK/ds"
      fi
      exit 0 ;;
  rename)
      src=\$2; dst=\$3
      if grep -qx "\$dst" "$WORK/ds" 2>/dev/null; then
        echo "cannot rename '\$src': dataset already exists" >&2; exit 1
      fi
      grep -v "^\$src" "$WORK/ds" > "$WORK/ds.n" 2>/dev/null || :
      mv "$WORK/ds.n" "$WORK/ds"
      echo "\$dst" >> "$WORK/ds"
      echo "\$dst@s1" >> "$WORK/ds"
      printf '%s' "\$(cat "$WORK/guid.\$(k "\$src@s1")" 2>/dev/null)" > "$WORK/guid.\$(k "\$dst@s1")"
      exit 0 ;;
  destroy)
      if [ -n "\${FAIL_DESTROY:-}" ]; then echo "destroy refused" >&2; exit 1; fi
      for a in "\$@"; do ds="\$a"; done
      grep -v "^\$ds" "$WORK/ds" > "$WORK/ds.n" 2>/dev/null || :
      mv "$WORK/ds.n" "$WORK/ds"; exit 0 ;;
esac
exit 0
ZSTUB
chmod +x "$WORK/bin2/zfs"

scfg="$WORK/safe.conf"
mkcfg "$scfg" '\n[dataset:rpool/data]\n\tdst          = hdd/store\n'
LAND=hdd/restore/rpool/data
reset_ds() {
    # The pool exists, as on any real host.
    printf 'hdd\nhdd/store/rpool/data\nhdd/store/rpool/data@s1\n' > "$WORK/ds"
    printf '111' > "$WORK/guid.hdd_store_rpool_data_s1"
    rm -f "$WORK/zfs-calls2"
}
runs() {
    ( PATH="$WORK/bin2:$PATH" SERVER_CONF="$WORK/no-server.conf" \
      cmd_restore --config="$scfg" "$@" ) 2>&1
}

# ---- the landing path -------------------------------------------------------
a=$(restore_landing_path hdd/store/rpool/data rpool/data)
b=$(restore_landing_path hdd/store/tank/data  tank/data)
{ [ "$a" = "$LAND" ] && [ "$b" != "$a" ]; } \
    && ok "slice2: the landing path keeps the full source path, so two sources cannot collide" \
    || bad "slice2: the landing path keeps the full source path, so two sources cannot collide" "a=$a b=$b"

# ---- the verb refuses what it does not do -----------------------------------
reset_ds
out="$(runs --dataset=rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'separate verb'; } \
    && ok "slice2: no --plan and no --snapshot refuses and names the separate verb" \
    || bad "slice2: no --plan and no --snapshot refuses and names the separate verb" "rc=$rc"
out="$(runs --snapshot=s1)"; rc=$?
[ "$rc" -ne 0 ] && ok "slice2: --snapshot without --dataset refuses" \
                || bad "slice2: --snapshot without --dataset refuses" "rc=$rc"
out="$(runs --dataset=rpool/data --snapshot=nosuch --yes)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'does not exist'; } \
    && ok "slice2: a snapshot that is not on the copy refuses" \
    || bad "slice2: a snapshot that is not on the copy refuses" "rc=$rc"

# ---- the early collision check still short-circuits -------------------------
reset_ds
echo "$LAND" >> "$WORK/ds"
out="$(runs --dataset=rpool/data --snapshot=s1 --yes)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'already exists' \
  && grep -qx "$LAND" "$WORK/ds" \
  && ! grep -q '^destroy' "$WORK/zfs-calls2" 2>/dev/null \
  && ! grep -q '^send' "$WORK/zfs-calls2" 2>/dev/null; } \
    && ok "slice2: a landing that already exists refuses before transferring anything, and survives" \
    || bad "slice2: a landing that already exists refuses before transferring anything, and survives" "rc=$rc"

# ---- happy path: staged, verified, promoted ---------------------------------
reset_ds
out="$(runs --dataset=rpool/data --snapshot=s1 --yes)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi 'Odtworzenie OK' && grep -qx "$LAND" "$WORK/ds"; } \
    && ok "slice2: a good restore is promoted to the public landing path" \
    || bad "slice2: a good restore is promoted to the public landing path" "rc=$rc $(printf '%s' "$out"|tail -2)"
grep -q 'restore-staging-' "$WORK/ds" \
    && bad "slice2: no staging dataset survives a successful restore" "$(grep 'restore-staging-' "$WORK/ds")" \
    || ok "slice2: no staging dataset survives a successful restore"
grep -q '^rename ' "$WORK/zfs-calls2" \
    && ok "slice2: promotion goes through zfs rename, whose refusal is ZFS's own atomicity" \
    || bad "slice2: promotion goes through zfs rename, whose refusal is ZFS's own atomicity" ""

# ---- THE REV-114 RACE CONTROL ------------------------------------------------
# Another actor creates the final landing AFTER this run's collision check has
# passed. The old implementation would have destroyed it. Required: the restore
# fails, the injected dataset survives, and no destroy targets it or an ancestor
# containing it.
reset_ds
out="$(INJECT_LANDING="$LAND" runs --dataset=rpool/data --snapshot=s1 --yes)"; rc=$?
race_ok=1
[ "$rc" -ne 0 ] || race_ok=0
printf '%s' "$out" | grep -qi 'appeared while this restore was running' || race_ok=0
grep -qx "$LAND" "$WORK/ds" || race_ok=0
# no destroy may name the landing, nor any ancestor that contains it
while read -r c; do
    case "$c" in
        destroy*" $LAND"|destroy*" hdd/restore"|destroy*" hdd/restore/rpool"|destroy*" hdd") race_ok=0 ;;
    esac
done < "$WORK/zfs-calls2"
[ "$race_ok" -eq 1 ] \
    && ok "slice2 REV-114: a landing created by another actor mid-run survives, and is never a destroy target" \
    || bad "slice2 REV-114: a landing created by another actor mid-run survives, and is never a destroy target" \
           "rc=$rc destroys=[$(grep '^destroy' "$WORK/zfs-calls2" | tr '\n' ';')]"
# and this run's own staging is still cleaned up, because THAT one it owns
grep -q 'restore-staging-' "$WORK/ds" \
    && bad "slice2 REV-114: the lost race still cleans up this attempt's own staging" "$(grep 'restore-staging-' "$WORK/ds")" \
    || ok "slice2 REV-114: the lost race still cleans up this attempt's own staging"

# ---- a failed receive leaves NOTHING of this attempt behind -----------------
reset_ds
out="$(FAIL_RECV=1 runs --dataset=rpool/data --snapshot=s1 --yes)"; rc=$?
{ [ "$rc" -ne 0 ] && ! grep -q 'restore-staging-' "$WORK/ds" && ! grep -qx "$LAND" "$WORK/ds"; } \
    && ok "slice2: a failed receive leaves no staging and no landing, so a retry is not stranded" \
    || bad "slice2: a failed receive leaves no staging and no landing, so a retry is not stranded" "rc=$rc ds=$(cat "$WORK/ds")"

# ---- GUID mismatch fails even though the pipeline succeeded -----------------
reset_ds
out="$(RECV_GUID=999 runs --dataset=rpool/data --snapshot=s1 --yes)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'guid mismatch' \
  && ! grep -q 'restore-staging-' "$WORK/ds" && ! grep -qx "$LAND" "$WORK/ds"; } \
    && ok "slice2: a clean pipeline with the WRONG guid still fails, and never reaches the public path" \
    || bad "slice2: a clean pipeline with the WRONG guid still fails, and never reaches the public path" "rc=$rc"

# ---- ancestors are deliberately NOT removed ---------------------------------
# The reversal from the first cut. Removing scaffolding is the one cleanup whose
# ownership cannot be proven, and staging already keeps retries clean.
grep -qx 'hdd/restore' "$WORK/ds" \
    && ok "slice2: namespace ancestors survive a failed attempt -- unprovable ownership is not cleaned up" \
    || bad "slice2: namespace ancestors survive a failed attempt -- unprovable ownership is not cleaned up" "hdd/restore was destroyed"

# ---- cleanup that itself fails: explicit incomplete state, no success claim --
reset_ds
out="$(RECV_GUID=999 FAIL_DESTROY=1 runs --dataset=rpool/data --snapshot=s1 --yes)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'could not be removed' \
  && printf '%s' "$out" | grep -q 'restore-staging-'; } \
    && ok "slice2: a cleanup that fails names this attempt's staging dataset and never claims success" \
    || bad "slice2: a cleanup that fails names this attempt's staging dataset and never claims success" "rc=$rc $(printf '%s' "$out"|tail -1)"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
