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
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--plan' && printf '%s' "$out" | grep -q -- '--snapshot' \
  && printf '%s' "$out" | grep -q 'no public grammar yet'; } \
    && ok "slice2: bare --dataset refuses, names the two real ways in, and does not invent a third" \
    || bad "slice2: bare --dataset refuses, names the two real ways in, and does not invent a third" "rc=$rc" "$out"
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

# ==============================================================================
# The default recovery STRATEGY, computed read-only
# (OWNER-RECOVERY-DEFAULT-POLICY-2026-08-12: latest backup point -> original path).
#
# The stub below projects columns per the requested -o, instead of returning one
# fixed shape. The strategy code asks for `-o guid` and `-o name,guid` as well as
# `-o name,creation,guid`, so a stub that ignored -o would feed the parser fields
# from the wrong positions and prove nothing about it.
# ==============================================================================
mkdir -p "$WORK/bin3"
cat > "$WORK/bin3/zfs" <<ZS3
#!/bin/sh
echo "\$*" >> "$WORK/zfs-calls3"

# ---- property reads ---------------------------------------------------------
# Strict about the shape: an implementation that asked for a human-formatted
# value, or for a different property, would be reading a different fact.
if [ "\$1" = get ]; then
  case "\$*" in
    "get -Hp -o value written "*) prop=written ;;
    "get -Hp -o value used "*)    prop=used ;;
    "get -H -o value readonly "*) cat "$WORK/ro.value" 2>/dev/null || echo off; exit 0 ;;
    "get -H -o source readonly "*) cat "$WORK/ro.source" 2>/dev/null || echo default; exit 0 ;;
    *) echo "stub3: unexpected get: \$*" >&2; exit 9 ;;
  esac
  for a in "\$@"; do ds="\$a"; done
  # Two injection points for the REV-119 race. The technical snapshot names carry
  # a pid/epoch/random stamp, so a test cannot pre-seed a file per name; it seeds
  # behaviour per KIND of technical snapshot instead.
  case "\$ds" in
    *@restore-preview-*) [ "\$prop" = written ] && [ -f "$WORK/livebytes" ] && { cat "$WORK/livebytes"; exit 0; } ;;
    *@restore-commit-*)  [ "\$prop" = written ] && [ -f "$WORK/arrivebytes" ] && { cat "$WORK/arrivebytes"; exit 0; } ;;
  esac
  wkey=\$(printf '%s' "\$ds" | tr '/@' '__')
  if [ -f "$WORK/\$prop.\$wkey" ]; then
    v=\$(cat "$WORK/\$prop.\$wkey")
    [ "\$v" = FAIL ] && { echo "cannot open '\$ds'" >&2; exit 1; }
    echo "\$v"; exit 0
  fi
  [ "\$prop" = used ] && { echo 1024; exit 0; }
  echo 0; exit 0
fi

# ---- the two mutations this path is allowed to make -------------------------
# Both are recorded, so a test can assert not just THAT the path snapshots but
# that it removes what it made.
# ---- the write fence --------------------------------------------------------
# The stub MODELS the fence rather than pretending: `set readonly=on` changes what
# the next `get` returns, so a path that never set it, or that lowered it early,
# reads back the wrong value and the assertions notice.
if [ "\$1" = set ]; then
  case "\$2" in
    readonly=*) [ -f "$WORK/fencefail" ] && { echo "cannot set readonly" >&2; exit 1; }
                printf '%s' "\${2#readonly=}" > "$WORK/ro.value"
                printf 'local' > "$WORK/ro.source"
                # verifyfail models REV-119 F1.2: the property change GOES
                # THROUGH and the read-back afterwards does not agree with it.
                [ -f "$WORK/verifyfail" ] && printf 'off' > "$WORK/ro.value"
                exit 0 ;;
  esac
  echo "stub3: unexpected set: \$*" >&2; exit 9
fi
if [ "\$1" = inherit ]; then
  [ -f "$WORK/unfencefail" ] && { echo "cannot inherit" >&2; exit 1; }
  # `-S` reverts to the RECEIVED value, which is a different destination state
  # from plain inherit. The stub models both, so a path that used the wrong one
  # restores the wrong provenance and the assertion sees it.
  if [ "\$2" = "-S" ]; then
    printf 'off' > "$WORK/ro.value"; printf 'received' > "$WORK/ro.source"
  else
    printf 'off' > "$WORK/ro.value"; printf 'default' > "$WORK/ro.source"
  fi
  exit 0
fi
if [ "\$1" = snapshot ]; then
  full="\$2"; dsp=\${full%@*}
  key=\$(printf '%s' "\$dsp" | tr '/' '_')
  [ -f "$WORK/snapfail" ] && { echo "cannot create snapshot '\$full'" >&2; exit 1; }
  n=\$(cat "$WORK/snapn" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$WORK/snapn"
  printf '%s\t%s\t%s\n' "\$full" "\$((9000+n))" "\$((9900+n))" >> "$WORK/rows.\$key"
  # Another actor snapshotting the source right after our preview snapshot: the
  # exact window the commit boundary exists to close.
  case "\$full" in
    *@restore-commit-*)
      # Injected when the COMMIT snapshot is taken, i.e. after the preview
      # snapshot and after the before-set was captured. That is what "arrived
      # after the approval" means; injecting at preview time would have put the
      # intruder INTO the before-set, and the check would rightly ignore it.
      [ -f "$WORK/arrivesnap" ] && printf '%s@intruder\t9500\t9500\n' "\$dsp" >> "$WORK/rows.\$key"
      # Same wall-clock creation second as the preview snapshot, and a name that
      # sorts BEFORE it -- the exact case a position-in-a-sorted-list check loses
      # (REV-119 F1.1). The creation column is deliberately a duplicate.
      [ -f "$WORK/arrivesnap_samesecond" ] && printf '%s@intruder-samesec\t9001\t9600\n' "\$dsp" >> "$WORK/rows.\$key"
      ;;
  esac
  exit 0
fi
if [ "\$1" = destroy ]; then
  full="\$2"; dsp=\${full%@*}
  key=\$(printf '%s' "\$dsp" | tr '/' '_')
  [ -f "$WORK/destroyfail" ] && { echo "cannot destroy '\$full'" >&2; exit 1; }
  grep -v "^\$full	" "$WORK/rows.\$key" > "$WORK/rows.\$key.tmp" 2>/dev/null
  mv "$WORK/rows.\$key.tmp" "$WORK/rows.\$key"
  exit 0
fi

[ "\$1" = list ] || { echo "stub3: refusing non-list: \$*" >&2; exit 9; }
cols=""; want_snap=0
prev=""
for a in "\$@"; do
  [ "\$prev" = "-o" ] && cols="\$a"
  [ "\$a" = "snapshot" ] && want_snap=1
  prev="\$a"
  ds="\$a"
done
case "\$ds" in
  *@*)  # existence check for ONE snapshot, not a listing
        dsp=\${ds%@*}
        key=\$(printf '%s' "\$dsp" | tr '/' '_')
        grep -q "^\$ds	" "$WORK/rows.\$key" 2>/dev/null || exit 1
        echo "\$ds"; exit 0 ;;
esac
key=\$(printf '%s' "\$ds" | tr '/' '_')
if [ "\$want_snap" -eq 1 ]; then
  [ -s "$WORK/rows.\$key" ] || exit 1
  # canonical row: name<TAB>creation<TAB>guid ; project the requested columns
  awk -F'\t' -v c="\$cols" '{
      n=split(c,f,","); out=""
      for(i=1;i<=n;i++){
        v = (f[i]=="name")?\$1 : (f[i]=="creation")?\$2 : (f[i]=="guid")?\$3 : "-"
        out = (i==1)? v : out "\t" v
      }
      print out
  }' "$WORK/rows.\$key"
  exit 0
fi
grep -qx "\$ds" "$WORK/exists" 2>/dev/null || exit 1
echo "\$ds"; exit 0
ZS3
chmod +x "$WORK/bin3/zfs"

runstrat() {
    ( PATH="$WORK/bin3:$PATH" SERVER_CONF="$WORK/no-server.conf" \
      cmd_restore --config="$1" --plan ) 2>&1
}
stcfg="$WORK/strat.conf"
mkcfg "$stcfg" '\n[dataset:rpool/data]\n\tdst          = hdd/store\n'
COPY=hdd_store_rpool_data
SRC=rpool_data

# ---- source absent -> FULL, nothing to destroy ------------------------------
printf 'hdd/store/rpool/data@s1\t100\t11\n' > "$WORK/rows.$COPY"
printf 'hdd/store\nhdd/store/rpool/data\n' > "$WORK/exists"
out="$(runstrat "$stcfg")"
{ printf '%s' "$out" | grep -q 'Strategia:  FULL' && printf '%s' "$out" | grep -qi 'nie istnieje'; } \
    && ok "strategy: an absent source is FULL with nothing to destroy" \
    || bad "strategy: an absent source is FULL with nothing to destroy" "$(printf '%s' "$out"|grep -i strategia)"

# ---- source exists, no shared guid -> FULL over a live source ---------------
printf 'rpool/data@x1\t50\t99\n' > "$WORK/rows.$SRC"
printf 'hdd/store\nhdd/store/rpool/data\nrpool/data\n' > "$WORK/exists"
out="$(runstrat "$stcfg")"
{ printf '%s' "$out" | grep -q 'FULL na ISTNIEJACE' && printf '%s' "$out" | grep -qi 'niszczaca'; } \
    && ok "strategy: a live source with no common guid is FULL and flagged destructive" \
    || bad "strategy: a live source with no common guid is FULL and flagged destructive" "$(printf '%s' "$out"|grep -i strategia)"

# ---- backup ahead of source -> incremental from the GUID-proven base ---------
printf 'hdd/store/rpool/data@s1\t100\t11\nhdd/store/rpool/data@s2\t200\t22\n' > "$WORK/rows.$COPY"
printf 'rpool/data@s1\t100\t11\n' > "$WORK/rows.$SRC"
out="$(runstrat "$stcfg")"
{ printf '%s' "$out" | grep -q 'INKREMENT' && printf '%s' "$out" | grep -q 'guid=11'; } \
    && ok "strategy: a backup ahead of the source is an incremental from the proven base" \
    || bad "strategy: a backup ahead of the source is an incremental from the proven base" "$(printf '%s' "$out"|grep -iE 'strategia|baza')"

# ---- THE CASE THE LIVE LAB CAUGHT -------------------------------------------
# The source holds the backup's latest point AND two snapshots past it. No data
# needs transferring, but the source is NOT in the requested end state, so this is
# a rollback -- destructive. An implementation comparing base==latest first and
# stopping would call this "nothing to do" and hide the destruction.
printf 'hdd/store/rpool/data@s1\t100\t11\n' > "$WORK/rows.$COPY"
printf 'rpool/data@s1\t100\t11\nrpool/data@s2\t200\t22\nrpool/data@s3\t300\t33\n' > "$WORK/rows.$SRC"
out="$(runstrat "$stcfg")"
{ printf '%s' "$out" | grep -q 'SAM ROLLBACK' \
  && printf '%s' "$out" | grep -qE '^    s2$' && printf '%s' "$out" | grep -qE '^    s3$' \
  && ! printf '%s' "$out" | grep -q 'NIC DO ZROBIENIA'; } \
    && ok "strategy: a source PAST the latest backup point is a destructive rollback, not 'nothing to do'" \
    || bad "strategy: a source PAST the latest backup point is a destructive rollback, not 'nothing to do'" "$(printf '%s' "$out"|grep -iE 'strategia|^    s')"

# ---- REV-118 F1 residual: accounted-zero is UNPROVEN, never a no-op ----------
# The same fixture that used to be "the true no-op". The live lab showed written
# can read 0 while 4 MiB sits in an uncommitted txg, so a verdict resting on
# written=0 is a guess wearing a fact's clothes. This case therefore pins the
# ABSENCE of the comfortable answer, plus the reason being stated rather than the
# state merely being hedged.
printf 'rpool/data@s1\t100\t11\n' > "$WORK/rows.$SRC"
zero_out="$(runstrat "$stcfg")"
{ ! printf '%s' "$zero_out" | grep -q 'NIC DO ZROBIENIA' \
  && ! printf '%s' "$zero_out" | grep -q 'ROLLBACK' \
  && printf '%s' "$zero_out" | grep -q 'STAN ZRODLA NIEDOWIEDZIONY' \
  && printf '%s' "$zero_out" | grep -q 'written=0' \
  && printf '%s' "$zero_out" | grep -q 'txg'; } \
    && ok "strategy: written=0 is unproven, not a no-op, and says why" \
    || bad "strategy: written=0 is unproven, not a no-op, and says why" "$zero_out"

# ---- REV-118 F1: snapshots are not the only destructible source state --------
# Same fixture as the no-op control immediately above -- identical snapshot sets,
# GUID-proven base equal to the latest backup point, NOTHING newer on the source.
# The only difference is live data written after that snapshot. A preview that
# defines "blocked" as "has newer snapshots" cannot see this state and answers
# "nothing to do", hiding data loss that no snapshot can undo.
printf '4096\n' > "$WORK/written.$SRC"
out="$(runstrat "$stcfg")"
{ ! printf '%s' "$out" | grep -q 'NIC DO ZROBIENIA' \
  && printf '%s' "$out" | grep -q 'ODRZUCENIE ZYWYCH ZMIAN' \
  && printf '%s' "$out" | grep -q 'written=4096' \
  && printf '%s' "$out" | grep -qi 'ODRZUCI'; } \
    && ok "strategy: live unsnapshotted source data is named and never reads as 'nothing to do'" \
    || bad "strategy: live unsnapshotted source data is named and never reads as 'nothing to do'" "$out"

# Unproven is not the same answer as proven-dirty, and collapsing the two would
# be the lazy way to satisfy the residual: declare everything destructive and
# stop distinguishing. The zero case must NOT claim data will be discarded, and
# the dirty case must.
{ printf '%s' "$out" | grep -q 'ODRZUCI' \
  && ! printf '%s' "$zero_out" | grep -q 'ODRZUCI' \
  && ! printf '%s' "$zero_out" | grep -q 'ODRZUCENIE ZYWYCH ZMIAN'; } \
    && ok "strategy: unproven and proven-dirty stay distinct verdicts" \
    || bad "strategy: unproven and proven-dirty stay distinct verdicts" "$zero_out"

# The same state must not be swallowed by the incremental verdict either: there
# the transfer is genuinely possible, so the temptation to call it clean is real.
printf 'hdd/store/rpool/data@s1\t100\t11\nhdd/store/rpool/data@s2\t200\t22\n' > "$WORK/rows.$COPY"
out="$(runstrat "$stcfg")"
{ printf '%s' "$out" | grep -q 'INKREMENT' \
  && printf '%s' "$out" | grep -q 'written=4096' \
  && printf '%s' "$out" | grep -qi 'ODRZUCI'; } \
    && ok "strategy: an incremental over a dirty source still declares the live changes" \
    || bad "strategy: an incremental over a dirty source still declares the live changes" "$out"

# An unreadable live state is unproven too -- but for a different reason, and the
# preview has to say which. Two unprovable states with one indistinguishable
# message would leave the operator unable to tell "ZFS says nothing changed" from
# "the read failed".
printf 'FAIL\n' > "$WORK/written.$SRC"
printf 'hdd/store/rpool/data@s1\t100\t11\n' > "$WORK/rows.$COPY"
out="$(runstrat "$stcfg")"
{ printf '%s' "$out" | grep -q 'STAN ZYWY NIEDOWIEDZIONY' \
  && printf '%s' "$out" | grep -q "nie dal" \
  && ! printf '%s' "$out" | grep -q 'written=0' \
  && ! printf '%s' "$out" | grep -q 'NIC DO ZROBIENIA'; } \
    && ok "strategy: an unreadable live state is unproven for its own stated reason" \
    || bad "strategy: an unreadable live state is unproven for its own stated reason" "$out"
rm -f "$WORK/written.$SRC"

# ---- a remote source is not guessed at --------------------------------------
rcfg="$WORK/stratremote.conf"
mkcfg "$rcfg" '\n[dataset:hdd/mirror]\n\tsrc          = zfsbackup@10.0.0.9:tank/x\n'
printf 'hdd/mirror@s1\t100\t11\n' > "$WORK/rows.hdd_mirror"
out="$(runstrat "$rcfg")"
printf '%s' "$out" | grep -qi 'ZDALNE' \
    && ok "strategy: a remote source says so instead of applying the local answer" \
    || bad "strategy: a remote source says so instead of applying the local answer" "$(printf '%s' "$out"|grep -i strategia)"

# ==============================================================================
# `restore --replace` -- the DESTRUCTIVE verb, slice 1: all gates, no execution.
#
# Everything below asserts a refusal, which is the point: this slice can only
# refuse. The stub from the strategy section is reused unchanged, so any zfs call
# outside `list`/`get` would fail the run loudly -- that is how "it mutated
# nothing" is asserted rather than described.
# ==============================================================================
# Calls the internal function DIRECTLY. There is no CLI flag to go through, and
# that is the point: the owner is still deciding the public restore grammar, so
# the gates are built and tested underneath it rather than behind a flag that
# would have to be withdrawn later (R-018/R-019).
runrepl() {   # <config> [dataset] [yes]
    local c="$1" d="${2-}" y="${3-1}"
    ( PATH="$WORK/bin3:$PATH" SERVER_CONF="$WORK/no-server.conf" \
      restore_replace_internal "$d" "$c" "$y" ) 2>&1
}

# How many snapshots the source has right now. The whole REV-119 slice is judged
# on this number being the same before and after every run, whatever the run did.
srccount() { grep -c . "$WORK/rows.$SRC" 2>/dev/null || echo 0; }

reset_src() {
    rm -f "$WORK/livebytes" "$WORK/arrivebytes" "$WORK/arrivesnap" \
          "$WORK/snapfail" "$WORK/destroyfail" \
          "$WORK/fencefail" "$WORK/unfencefail" "$WORK/ro.value" "$WORK/ro.source" \
          "$WORK/arrivesnap_samesecond" "$WORK/verifyfail"
    printf 'hdd/store/rpool/data@s1\t100\t11\nhdd/store/rpool/data@s2\t200\t22\n' > "$WORK/rows.$COPY"
    printf 'rpool/data@s1\t100\t11\n' > "$WORK/rows.$SRC"
    printf 'hdd/store\nhdd/store/rpool/data\nrpool/data\n' > "$WORK/exists"
    # The call log is deliberately NOT truncated here. Assertions 9 and 10 below
    # judge the whole section, and an earlier version of this helper reset it on
    # every fixture -- which left those two checks looking at the last run only
    # and reporting "1 made, 1 destroyed" as if that were the section's total.
}
reset_src

# The gates that must fire before anything is computed.
out="$(runrepl "$stcfg")"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'nazwij co odtwarzac'; } \
    && ok "replace: refuses without a dataset instead of guessing the relationship" \
    || bad "replace: refuses without a dataset instead of guessing the relationship" "$out"

out="$(runrepl "$stcfg" rpool/nowhere)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'nie wystepuje w zadnej relacji'; } \
    && ok "replace: a dataset outside every relationship is refused, not invented" \
    || bad "replace: a dataset outside every relationship is refused, not invented" "$out"

# Two assertions were dropped here rather than rewritten: they pinned CLI-level
# refusals (--snapshot rejected because the recovery point is policy; --plan and
# --replace refusing to combine). Both belong to a public grammar the owner has
# not settled, so pinning them now would freeze a decision that is not mine. They
# come back with the flag, against whatever shape it turns out to have.

# The relationship resolves BOTH ways, source path or copy path, because an
# operator reaching for recovery may know either one.
for name in rpool/data hdd/store/rpool/data; do
    reset_src
    out="$(runrepl "$stcfg" "$name")"; rc=$?
    { [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'krok WYKONAWCZY jeszcze nie istnieje' \
      && printf '%s' "$out" | grep -q 'INKREMENT'; } \
        && ok "replace: '$name' resolves to the relationship and previews before refusing" \
        || bad "replace: '$name' resolves to the relationship and previews before refusing" "$out"
done

# The preview an operator confirms and the decision the code takes must be ONE
# computation. This asserts the path branches on the facts the printed preview
# came from.
#
# Captured from an EXIT trap, because the path ends in `die` and die exits the
# subshell: a plain line after the call never runs. The first version of this
# test wrote nothing at all, so it failed for that reason rather than the one it
# was written to catch.
reset_src
( trap 'printf "%s|%s|%s" "$RESTORE_STRATEGY" "$RESTORE_BASE_GUID" "$RESTORE_TARGET_SNAP" > "$WORK/facts"' EXIT
  PATH="$WORK/bin3:$PATH" SERVER_CONF="$WORK/no-server.conf" \
  restore_replace_internal rpool/data "$stcfg" 1 >/dev/null 2>&1 ) || true
[ "$(cat "$WORK/facts" 2>/dev/null)" = 'increment|11|s2' ] \
    && ok "replace: branches on the same computed facts the preview printed" \
    || bad "replace: branches on the same computed facts the preview printed" "$(cat "$WORK/facts" 2>/dev/null)"

# No GUID-proven base -> full replacement, which is a different mechanism with
# different risk. It must be refused by name, never quietly attempted as an
# incremental.
reset_src
printf 'rpool/data@x1\t50\t99\n' > "$WORK/rows.$SRC"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'PELNE zastapienie' \
  && ! printf '%s' "$out" | grep -q 'krok WYKONAWCZY'; } \
    && ok "replace: no proven base is refused as full replacement, not run as an increment" \
    || bad "replace: no proven base is refused as full replacement, not run as an increment" "$out"

# A remote source is refused here too. The planner merely declines to guess; the
# destructive path must decline to ACT, and say why.
reset_src
out="$(runrepl "$rcfg" hdd/mirror)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'jest ZDALNE'; } \
    && ok "replace: a remote source is refused by the destructive path" \
    || bad "replace: a remote source is refused by the destructive path" "$out"

# An ATOMIC relationship is a subtree recovered as one point in time; recovering
# one dataset out of it would silently downgrade that property.
atcfg="$WORK/atomic.conf"
mkcfg "$atcfg" '\n[dataset:rpool/data]\n\tdst          = hdd/store\n\trecursive    = atomic\n'
out="$(runrepl "$atcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'ATOMIC'; } \
    && ok "replace: an atomic relationship is refused rather than recovered one dataset at a time" \
    || bad "replace: an atomic relationship is refused rather than recovered one dataset at a time" "$out"

# A copy with no snapshots at all: refuse, and name which side is empty.
reset_src
printf '' > "$WORK/rows.$COPY"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'ani jednego snapshota'; } \
    && ok "replace: a copy with no snapshots is refused" \
    || bad "replace: a copy with no snapshots is refused" "$out"

# ==============================================================================
# REV-20260813-119 F1 -- the confirmation has to be INFORMED, and it has to stay
# true until the destructive boundary.
# ==============================================================================

# 1. The loss set is EXACT, and it is exact because the technical snapshot was
#    taken first. The stub answers `written` on a restore-preview-* snapshot with
#    this number; an implementation that read the LIVE dataset instead (the
#    REV-118 value that lags a txg) gets 0 and prints 0.
reset_src
echo 7777 > "$WORK/livebytes"
out="$(runrepl "$stcfg" rpool/data)"
{ printf '%s' "$out" | grep -q 'zbior ZMIERZONY' \
  && printf '%s' "$out" | grep -q '7777 B'; } \
    && ok "REV-119: the loss set is measured from the technical snapshot, not from the live read" \
    || bad "REV-119: the loss set is measured from the technical snapshot, not from the live read" "$out"

# 2. ...and it is shown BEFORE the question is asked. Ordering, not presence:
#    the confirmation refusal must come after the measured set in the output.
reset_src
echo 7777 > "$WORK/livebytes"
out="$(runrepl "$stcfg" rpool/data 0 </dev/null)"
set_line=$(printf '%s\n' "$out" | grep -n 'zbior ZMIERZONY' | head -1 | cut -d: -f1)
ask_line=$(printf '%s\n' "$out" | grep -n 'niepotwierdzone' | head -1 | cut -d: -f1)
{ [ -n "$set_line" ] && [ -n "$ask_line" ] && [ "$set_line" -lt "$ask_line" ]; } \
    && ok "REV-119: the measured loss set is shown BEFORE the confirmation is resolved" \
    || bad "REV-119: the measured loss set is shown BEFORE the confirmation is resolved" "set=$set_line ask=$ask_line" "$out"

# 3. An unconfirmed run leaves the source exactly as it was found -- the
#    technical snapshot is removed, not left as litter.
[ "$(srccount)" = 1 ] \
    && ok "REV-119: an unconfirmed run removes its own technical snapshot" \
    || bad "REV-119: an unconfirmed run removes its own technical snapshot" "snapshots now: $(cat "$WORK/rows.$SRC")"

# 4. THE RACE, bytes arm: data lands after the approval. The path must refuse and
#    destroy nothing -- destroying it would destroy state nobody approved.
reset_src
echo 4096 > "$WORK/arrivebytes"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'stan zrodla sie ZMIENIL' \
  && printf '%s' "$out" | grep -q 'nowe dane: 4096 B' \
  && ! printf '%s' "$out" | grep -q 'krok WYKONAWCZY'; } \
    && ok "REV-119: data arriving after the approval refuses instead of being destroyed" \
    || bad "REV-119: data arriving after the approval refuses instead of being destroyed" "$out"
[ "$(srccount)" = 1 ] \
    && ok "REV-119: the refused race still cleans up both technical snapshots" \
    || bad "REV-119: the refused race still cleans up both technical snapshots" "$(cat "$WORK/rows.$SRC")"

# 5. THE RACE, snapshot arm: another actor snapshots the source in the same
#    window. Named individually, because "something changed" is not actionable.
reset_src
touch "$WORK/arrivesnap"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'stan zrodla sie ZMIENIL' \
  && printf '%s' "$out" | grep -q 'nowy snapshot: intruder'; } \
    && ok "REV-119: a snapshot arriving after the approval is named and refuses the run" \
    || bad "REV-119: a snapshot arriving after the approval is named and refuses the run" "$out"

# 6. The control that makes 4 and 5 mean something: with nothing arriving, the
#    same path reaches the execution point. Without this, a path that always
#    refused would pass both race tests.
reset_src
out="$(runrepl "$stcfg" rpool/data)"
{ printf '%s' "$out" | grep -q 'krok WYKONAWCZY jeszcze nie istnieje' \
  && ! printf '%s' "$out" | grep -q 'ZMIENIL'; } \
    && ok "REV-119: with nothing arriving the boundary holds and the path proceeds (control)" \
    || bad "REV-119: with nothing arriving the boundary holds and the path proceeds (control)" "$out"

# 7. The measurement is never sold as a safety copy. R-017 was explicit: if the
#    restore destroys it, calling it preservation is the most dangerous kind of
#    wrong -- an operator who believes it thinks a mistake is reversible.
reset_src
echo 7777 > "$WORK/livebytes"
out="$(runrepl "$stcfg" rpool/data)"
{ printf '%s' "$out" | grep -qi 'to POMIAR, nie kopia bezpieczenstwa' \
  && ! printf '%s' "$out" | grep -qi 'zachowan'; } \
    && ok "REV-119: the technical snapshot is described as a measurement, never as preservation" \
    || bad "REV-119: the technical snapshot is described as a measurement, never as preservation" "$out"

# 8. A loss set with a hole in it is not a loss set. If the live delta cannot be
#    measured, refuse rather than ask for consent to "the above, plus unknown".
reset_src
echo FAIL > "$WORK/livebytes"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'z dziura w srodku'; } \
    && ok "REV-119: an unmeasurable live delta refuses instead of showing a partial loss set" \
    || bad "REV-119: an unmeasurable live delta refuses instead of showing a partial loss set" "$out"
[ "$(srccount)" = 1 ] \
    && ok "REV-119: that refusal also cleans up after itself" \
    || bad "REV-119: that refusal also cleans up after itself" "$(cat "$WORK/rows.$SRC")"

# 9. Every zfs call the whole section made was a read, a technical snapshot of
#    this run, or the destroy of one of those -- checked from the stub's own log
#    rather than from a comment. Nothing else may appear.
# The allowed set is enumerated rather than loosened: reads, this run's own
# technical snapshots, and the write fence -- which is `readonly` on the source
# dataset and nothing else. `zfs set` in general is NOT allowed here; a path that
# started changing other properties would show up as a stray.
strays="$(grep -vE '^(list|get) ' "$WORK/zfs-calls3" 2>/dev/null \
          | grep -vE '^(snapshot|destroy) rpool/data@restore-(preview|commit)-' \
          | grep -vE '^set readonly=(on|off) rpool/data$' \
          | grep -vE '^inherit (-S )?readonly rpool/data$' || true)"
[ -z "$strays" ] \
    && ok "replace: the section only reads, or touches technical snapshots it made itself" \
    || bad "replace: the section only reads, or touches technical snapshots it made itself" "$strays"

# 10. And every technical snapshot that was created was also destroyed.
made="$(grep -cE '^snapshot rpool/data@restore-' "$WORK/zfs-calls3" 2>/dev/null || echo 0)"
gone="$(grep -cE '^destroy rpool/data@restore-' "$WORK/zfs-calls3" 2>/dev/null || echo 0)"
{ [ "$made" -gt 0 ] && [ "$made" = "$gone" ]; } \
    && ok "replace: every technical snapshot created was destroyed again ($made made, $gone destroyed)" \
    || bad "replace: every technical snapshot created was destroyed again" "made=$made destroyed=$gone"



# ==============================================================================
# REV-119 round 2 -- the WRITE FENCE.
#
# The commit snapshot proves nothing arrived UP TO the check. It says nothing
# about the window between the check and the destructive step. A write landing
# there would be destroyed under an approval that never covered it, so the source
# has to be incapable of accepting writes rather than merely observed not to have.
# ==============================================================================

# 11. The fence goes up, and it goes up BEFORE the boundary snapshot. Ordering,
#     because a fence raised after the check leaves the same hole one step later.
reset_src
out="$(runrepl "$stcfg" rpool/data)"
fence_line=$(grep -n '^set readonly=on rpool/data$' "$WORK/zfs-calls3" | tail -1 | cut -d: -f1)
commit_line=$(grep -n '^snapshot rpool/data@restore-commit-' "$WORK/zfs-calls3" | tail -1 | cut -d: -f1)
{ [ -n "$fence_line" ] && [ -n "$commit_line" ] && [ "$fence_line" -lt "$commit_line" ]; } \
    && ok "REV-119 fence: readonly=on is set BEFORE the commit boundary snapshot" \
    || bad "REV-119 fence: readonly=on is set BEFORE the commit boundary snapshot" "fence=$fence_line commit=$commit_line"

# 12. ...and it comes back down. The dataset must not be left readonly by a run
#     that completed.
[ "$(cat "$WORK/ro.value" 2>/dev/null)" = off ] \
    && ok "REV-119 fence: the fence is lowered again when the run finishes" \
    || bad "REV-119 fence: the fence is lowered again when the run finishes" "readonly is now: $(cat "$WORK/ro.value" 2>/dev/null)"

# 13. A dataset that was ALREADY readonly=on locally must be left readonly=on --
#     restoring "off" because that is the common case would silently change a
#     deliberate setting. This is the discriminating pair for the restore logic.
reset_src
printf 'on' > "$WORK/ro.value"; printf 'local' > "$WORK/ro.source"
out="$(runrepl "$stcfg" rpool/data)"
[ "$(cat "$WORK/ro.value" 2>/dev/null)" = on ] \
    && ok "REV-119 fence: a source that was already readonly stays readonly afterwards" \
    || bad "REV-119 fence: a source that was already readonly stays readonly afterwards" "readonly is now: $(cat "$WORK/ro.value" 2>/dev/null)"

# 14. An INHERITED value goes back to inherited, not to a local copy that happens
#     to read the same today. `zfs inherit` must appear in the log, `zfs set
#     readonly=off` must not.
reset_src
out="$(runrepl "$stcfg" rpool/data)"
{ grep -q '^inherit readonly rpool/data$' "$WORK/zfs-calls3" \
  && ! grep -q '^set readonly=off rpool/data$' "$WORK/zfs-calls3"; } \
    && ok "REV-119 fence: an inherited readonly is restored by inherit, not by a local set" \
    || bad "REV-119 fence: an inherited readonly is restored by inherit, not by a local set" "$(grep -E '^(set|inherit) readonly' "$WORK/zfs-calls3" | tail -4)"

# 15. If the fence cannot be raised, refuse. Proceeding without it would mean
#     destroying state that nothing prevented from arriving.
reset_src
touch "$WORK/fencefail"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'nie udalo sie zablokowac zapisu' \
  && ! printf '%s' "$out" | grep -q 'krok WYKONAWCZY'; } \
    && ok "REV-119 fence: a fence that cannot be raised refuses the run" \
    || bad "REV-119 fence: a fence that cannot be raised refuses the run" "$out"
[ "$(srccount)" = 1 ] \
    && ok "REV-119 fence: that refusal also removes the technical snapshot" \
    || bad "REV-119 fence: that refusal also removes the technical snapshot" "$(cat "$WORK/rows.$SRC")"

# 16. If the fence cannot be LOWERED, say so loudly and fail. A production
#     dataset left readonly is a different outage from the one being fixed, and
#     an operator who is not told will debug the wrong thing.
reset_src
touch "$WORK/unfencefail"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'blokada zapisu ZOSTALA' \
  && printf '%s' "$out" | grep -q 'readonly'; } \
    && ok "REV-119 fence: a fence that cannot be lowered fails loudly and names the manual fix" \
    || bad "REV-119 fence: a fence that cannot be lowered fails loudly and names the manual fix" "$out"


# ==============================================================================
# REV-119 round 3 -- the four residuals.
# ==============================================================================

# 17. F1.1 -- an intruder snapshot created in the SAME wall-clock second as the
#     preview snapshot. Under the old position-in-a-sorted-list logic it could
#     sort BEFORE the preview snapshot and vanish from the "newer" set; a set
#     difference has no ordering in it to get wrong.
reset_src
touch "$WORK/arrivesnap_samesecond"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'stan zrodla sie ZMIENIL' \
  && printf '%s' "$out" | grep -q 'nowy snapshot: intruder-samesec'; } \
    && ok "REV-119 F1.1: a same-second intruder snapshot is still caught" \
    || bad "REV-119 F1.1: a same-second intruder snapshot is still caught" "$out"

# 18. F1.2 -- the fence property change succeeds and the VERIFICATION fails. The
#     old shape returned failure with nothing saved, leaving the source
#     read-only. The undo must be attempted with the captured state.
reset_src
touch "$WORK/verifyfail"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'nie udalo sie zablokowac zapisu'; } \
    && ok "REV-119 F1.2: an unverifiable fence refuses the run" \
    || bad "REV-119 F1.2: an unverifiable fence refuses the run" "$out"
[ "$(cat "$WORK/ro.value" 2>/dev/null)" = off ] \
    && ok "REV-119 F1.2: ...and the source is NOT left read-only by that path" \
    || bad "REV-119 F1.2: ...and the source is NOT left read-only by that path" "readonly is now: $(cat "$WORK/ro.value" 2>/dev/null)"

# 19. F1.2, the other half: the property is never touched at all until the old
#     state is in hand. An unreadable readonly means refuse before mutating.
reset_src
printf 'garbage' > "$WORK/ro.value"
before=$({ grep -c '^set readonly=on rpool/data$' "$WORK/zfs-calls3"; true; } | head -1)
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
after=$({ grep -c '^set readonly=on rpool/data$' "$WORK/zfs-calls3"; true; } | head -1)
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "nie umiem jej pozniej przywrocic" \
  && [ "$before" = "$after" ]; } \
    && ok "REV-119 F1.2: an unreadable readonly refuses BEFORE the property is touched" \
    || bad "REV-119 F1.2: an unreadable readonly refuses BEFORE the property is touched" "$out"

# 20. F1.3 -- a RECEIVED property goes back to received, not to a local override
#     with the same value. `zfs inherit -S` is the only mechanism that does that.
reset_src
printf 'off' > "$WORK/ro.value"; printf 'received' > "$WORK/ro.source"
out="$(runrepl "$stcfg" rpool/data)"
{ grep -q '^inherit -S readonly rpool/data$' "$WORK/zfs-calls3" \
  && [ "$(cat "$WORK/ro.source" 2>/dev/null)" = received ]; } \
    && ok "REV-119 F1.3: a received readonly is restored as received, not as a local override" \
    || bad "REV-119 F1.3: a received readonly is restored as received, not as a local override" "source is now: $(cat "$WORK/ro.source" 2>/dev/null); calls: $(grep -E '^(set|inherit)' "$WORK/zfs-calls3" | tail -3)"

# 21. F1.4 -- cleanup that fails must not be laundered into "the source is
#     exactly as you left it". The claim and the outcome have to agree.
reset_src
touch "$WORK/destroyfail"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] \
  && printf '%s' "$out" | grep -q 'NIE jest w stanie sprzed polecenia' \
  && ! printf '%s' "$out" | grep -q 'jest dokladnie w stanie sprzed tego polecenia'; } \
    && ok "REV-119 F1.4: a failed cleanup is reported, never called an unchanged source" \
    || bad "REV-119 F1.4: a failed cleanup is reported, never called an unchanged source" "$out"

# 22. ...and the control, so 21 is discriminating: when cleanup succeeds, the
#     path DOES get to say the source is unchanged.
reset_src
out="$(runrepl "$stcfg" rpool/data)"
{ printf '%s' "$out" | grep -q 'jest dokladnie w stanie sprzed tego polecenia' \
  && ! printf '%s' "$out" | grep -q 'NIE jest w stanie'; } \
    && ok "REV-119 F1.4: a successful cleanup may say the source is unchanged (control)" \
    || bad "REV-119 F1.4: a successful cleanup may say the source is unchanged (control)" "$out"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
