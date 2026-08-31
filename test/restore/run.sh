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
# Since the 2026-08-17 split the restore code lives in zfs-restore.sh; the ZB
# override is kept (same spelling) so negative controls against an older tree
# still work. zfs-backup.sh forwards `restore` here, so this suite exercising
# zfs-restore.sh directly covers both public spellings.
ZB="${ZB:-$REPO/zfs-restore.sh}"
[ -r "$ZB" ] || { echo "cannot find zfs-restore.sh at $ZB" >&2; exit 1; }
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

# The wording moved on 2026-08-27: this path had its OWN copy of the config
# rule (CRON_CONFIG, else jobs.<host>.conf) and could not see a delegated
# account's file, so it now calls restore_pick_config like every other path.
# What is pinned is the substance -- it refuses, and it names what to pass --
# rather than the sentence that used to carry it.
out="$( ( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" cmd_restore --plan ) 2>&1 )"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'no readable installed config'; } \
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
  # Fails ONLY the boundary snapshot. Deliberately not folded into snapfail:
  # failing the preview snapshot exercises a pre-mutation property (nothing has
  # been touched yet), while failing this one is the first failure that happens
  # with the fence already up.
  case "\$full" in
    *@restore-commit-*) [ -f "$WORK/commitsnapfail" ] && { echo "cannot create snapshot '\$full'" >&2; exit 1; } ;;
  esac
  n=\$(cat "$WORK/snapn" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$WORK/snapn"
  printf '%s\t%s\t%s\t%s\n' "\$full" "\$((9000+n))" "\$((9900+n))" "\$((9000+n))" >> "$WORK/rows.\$key"
  # Another actor snapshotting the source right after our preview snapshot: the
  # exact window the commit boundary exists to close.
  case "\$full" in
    *@restore-commit-*)
      # Injected when the COMMIT snapshot is taken, i.e. after the preview
      # snapshot and after the before-set was captured. That is what "arrived
      # after the approval" means; injecting at preview time would have put the
      # intruder INTO the before-set, and the check would rightly ignore it.
      [ -f "$WORK/arrivesnap" ] && printf '%s@intruder\t9500\t9500\t9500\n' "\$dsp" >> "$WORK/rows.\$key"
      # Same wall-clock creation second as the preview snapshot, and a name that
      # sorts BEFORE it -- the exact case a position-in-a-sorted-list check loses
      # (REV-119 F1.1). The creation column is deliberately a duplicate.
      [ -f "$WORK/arrivesnap_samesecond" ] && printf '%s@intruder-samesec\t9001\t9600\t9501\n' "\$dsp" >> "$WORK/rows.\$key"
      # REV-120 F1: a BOOKMARK arriving in the same window. \`zfs bookmark\` is not a
      # userland write, so readonly=on does not keep it out -- and \`zfs rollback -r\`
      # destroys it. It must be caught by the confirmation boundary, exactly like an
      # intruding snapshot.
      [ -f "$WORK/arrivebm" ] && printf '%s#intruder-bm\t9500\t9700\t9502\n' "\$dsp" >> "$WORK/bmarks.\$key"
      ;;
  esac
  exit 0
fi
if [ "\$1" = destroy ]; then
  full="\$2"
  [ -f "$WORK/destroyfail" ] && { echo "cannot destroy '\$full'" >&2; exit 1; }
  # setdestroyfail fails ONLY the approved-set call, which is the one carrying a
  # comma list, and leaves the single-name cleanup destroys working. Folding it
  # into destroyfail would make the cleanup fail too, and the assertion would then
  # be about litter rather than about where "nothing was destroyed" ends.
  case "\$full" in
    *,*) [ -f "$WORK/setdestroyfail" ] && { echo "cannot destroy '\$full': dataset is busy" >&2; exit 1; } ;;
  esac
  # REV-120 round 2 models BOTH real shapes, and the difference matters:
  #   ds@a,b,c  -- one atomic call removing several snapshots (measured: works)
  #   ds#name   -- one bookmark at a time (measured: the comma form is
  #                snapshot-only, `bookmark 'ds#b1,b2' does not exist`)
  case "\$full" in
    *#*) dsp=\${full%#*}; key=\$(printf '%s' "\$dsp" | tr '/' '_')
         case "\${full#*#}" in
           *,*) echo "bookmark '\$full' does not exist." >&2; exit 1 ;;
         esac
         grep -q "^\$full	" "$WORK/bmarks.\$key" 2>/dev/null || { echo "bookmark '\$full' does not exist." >&2; exit 1; }
         grep -v "^\$full	" "$WORK/bmarks.\$key" > "$WORK/bmarks.\$key.tmp" 2>/dev/null
         mv "$WORK/bmarks.\$key.tmp" "$WORK/bmarks.\$key"
         exit 0 ;;
  esac
  dsp=\${full%@*}; key=\$(printf '%s' "\$dsp" | tr '/' '_')
  list=\${full#*@}
  # All or none, like the real call: verify every name first.
  IFS=','; for n in \$list; do
    grep -q "^\$dsp@\$n	" "$WORK/rows.\$key" 2>/dev/null || {
      unset IFS; echo "could not find any snapshots to destroy; check snapshot names." >&2; exit 1; }
  done; unset IFS
  IFS=','; for n in \$list; do
    grep -v "^\$dsp@\$n	" "$WORK/rows.\$key" > "$WORK/rows.\$key.tmp" 2>/dev/null
    mv "$WORK/rows.\$key.tmp" "$WORK/rows.\$key"
  done; unset IFS
  exit 0
fi

# ---- the three execution primitives -----------------------------------------
# Modelled against the SAME rows store, so a test can assert the destructive
# effect (blockers gone, target arrived, guid) and not merely that a command ran.
# rollback -r <ds>@<snap>: every snapshot AND BOOKMARK whose createtxg is greater
# than <snap>'s is destroyed. That is what removes the approved blockers and this
# run's own technical snapshots -- and, until REV-120, also removed bookmarks nobody
# had been shown.
#
# createtxg, not creation, because that is what ZFS itself compares. Measured on
# pve0 (zfs-2.1.9): @s1 and @s2 created in the same wall-clock second carry
# createtxg 42609087 and 42609088, and a rollback to @s1 with #bm1/#bm2/#bm3 present
# left exactly #bm1 -- the one whose createtxg equals the target's.
if [ "\$1" = rollback ]; then
  # REV-120 round 2: the contract is a NON-recursive rollback. \`-r\` is refused
  # outright rather than modelled, so reintroducing it turns every destructive
  # assertion red instead of quietly restoring the race this REV removed.
  for a in "\$@"; do
    [ "\$a" = "-r" ] || [ "\$a" = "-R" ] && { echo "stub3: recursive rollback is not part of this contract: \$*" >&2; exit 9; }
    full="\$a"
  done
  [ -f "$WORK/rollbackfail" ] && { echo "cannot rollback" >&2; exit 1; }
  dsp=\${full%@*}; key=\$(printf '%s' "\$dsp" | tr '/' '_')
  bc=\$(awk -F'\t' -v n="\$full" '\$1==n{print (\$4!=""?\$4:\$2)}' "$WORK/rows.\$key")
  [ -n "\$bc" ] || { echo "no such snapshot '\$full'" >&2; exit 1; }
  # ZFS's own guard, measured on 2.1.9 and 2.2.2: anything newer than the target
  # -- snapshot OR bookmark -- and the command refuses, names it, and destroys
  # NOTHING, live data included.
  newer=\$( { awk -F'\t' -v bc="\$bc" '((\$4!=""?\$4:\$2)+0)>(bc+0){print \$1}' "$WORK/rows.\$key"
             [ -f "$WORK/bmarks.\$key" ] && awk -F'\t' -v bc="\$bc" '((\$4!=""?\$4:\$2)+0)>(bc+0){print \$1}' "$WORK/bmarks.\$key"; } )
  if [ -n "\$newer" ]; then
    echo "cannot rollback to '\$full': more recent snapshots or bookmarks exist" >&2
    echo "use '-r' to force deletion of the following snapshots and bookmarks:" >&2
    printf '%s\n' "\$newer" >&2
    exit 1
  fi
  # rollbackleak models the C-006/C-007 class the acceptance test exists for:
  # the command returns 0 and the state is still wrong. Here one blocker appears.
  if [ -f "$WORK/rollbackleak" ]; then cat "$WORK/rollbackleak" >> "$WORK/rows.\$key"; fi
  exit 0
fi
# send emits a tiny "stream" carrying only what recv needs: the target snapshot's
# bare name, its guid and its CREATION. A real send carries the data; identity and
# creation are what the acceptance test is about, so the stub carries those.
if [ "\$1" = send ]; then
  [ -f "$WORK/sendfail" ] && { echo "send failed" >&2; exit 1; }
  for a in "\$@"; do last="\$a"; done
  key=\$(printf '%s' "\${last%@*}" | tr '/' '_')
  g=\$(awk -F'\t' -v n="\$last" '\$1==n{print \$3}' "$WORK/rows.\$key")
  c=\$(awk -F'\t' -v n="\$last" '\$1==n{print \$2}' "$WORK/rows.\$key")
  printf '%s\t%s\t%s\n' "\${last#*@}" "\$g" "\$c"
  exit 0
fi
# recv lands the streamed snapshot on the destination with the streamed guid --
# unless recvguid overrides it, which models a clean pipeline that produced the
# WRONG identity (the case the GUID acceptance test exists to catch).
#
# The received row keeps the STREAM's creation and gets a fresh local createtxg.
# That is real ZFS behaviour and it is the reason REV-120 F2 matters: a received
# snapshot's creation comes from the sending host's clock, so it can tie with a
# local snapshot's second while their transaction order is not in doubt at all.
if [ "\$1" = recv ] || [ "\$1" = receive ]; then
  for a in "\$@"; do dst="\$a"; done
  IFS= read -r line || line=""
  [ -f "$WORK/recvfail" ] && { echo "recv failed" >&2; exit 1; }
  snap=\$(printf '%s' "\$line" | cut -f1)
  g=\$(printf '%s' "\$line" | cut -f2)
  c=\$(printf '%s' "\$line" | cut -f3)
  [ -n "\$c" ] || c=999999
  [ -f "$WORK/recvguid" ] && g=\$(cat "$WORK/recvguid")
  t=\$(cat "$WORK/txgn" 2>/dev/null || echo 990000); t=\$((t+1)); echo "\$t" > "$WORK/txgn"
  key=\$(printf '%s' "\$dst" | tr '/' '_')
  printf '%s@%s\t%s\t%s\t%s\n' "\$dst" "\$snap" "\$c" "\$g" "\$t" >> "$WORK/rows.\$key"
  exit 0
fi

[ "\$1" = list ] || { echo "stub3: refusing non-list: \$*" >&2; exit 9; }
cols=""; want_snap=0; want_bm=0; sorted=0
prev=""
for a in "\$@"; do
  [ "\$prev" = "-o" ] && cols="\$a"
  [ "\$prev" = "-s" ] && [ "\$a" = creation ] && sorted=1
  [ "\$a" = "snapshot" ] && want_snap=1
  [ "\$a" = "bookmark" ] && want_bm=1
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
# Canonical row for both stores: name<TAB>creation<TAB>guid<TAB>createtxg.
# createtxg falls back to creation when the fixture does not say -- the two agree
# for ordinary locally-made snapshots, and the fixtures that care about the
# difference state it.
project() {   # <file>
  awk -F'\t' -v c="\$cols" '{
      n=split(c,f,","); out=""
      for(i=1;i<=n;i++){
        v = (f[i]=="name")?\$1 : (f[i]=="creation")?\$2 : (f[i]=="guid")?\$3 \
            : (f[i]=="createtxg")?((\$4!="")?\$4:\$2) : "-"
        out = (i==1)? v : out "\t" v
      }
      print out
  }' "\$1"
}
# \`-s creation\` is HONOURED, and its tie-break is deliberate. Real ZFS gives no
# order at all to rows sharing a creation second; the stub picks one (name,
# ascending) so a fixture can put the adverse row last on purpose. Code that
# concludes anything from the last line of this listing is then provably wrong
# rather than accidentally right (REV-120 F2).
order() {   # <file> -> stdout
  if [ "\$sorted" -eq 1 ]; then sort -t'	' -k2,2n -k1,1 "\$1"; else cat "\$1"; fi
}
if [ "\$want_bm" -eq 1 ]; then
  # bmarkfail models a listing that cannot be read -- which must never be treated
  # as "there are no bookmarks".
  [ -f "$WORK/bmarkfail" ] && { echo "cannot list bookmarks" >&2; exit 1; }
  # Measured on pve0 (zfs-2.1.9): a dataset with no bookmarks lists EMPTY and
  # exits 0. So absence is a successful empty answer, not a failure.
  if [ -s "$WORK/bmarks.\$key" ]; then
    order "$WORK/bmarks.\$key" > "$WORK/o.\$\$"; project "$WORK/o.\$\$"; rm -f "$WORK/o.\$\$"
  fi
  # latebm models a bookmark appearing AFTER the confirmation boundary has read the
  # bookmark set and BEFORE the destructive command -- the one window the boundary
  # cannot cover. The boundary makes exactly two \`-o name\` reads (the before-set and
  # the after-set), so injecting right after the SECOND leaves the executor's own
  # re-measurement as the only thing that can still catch it.
  if [ -f "$WORK/latebm" ] && [ "\$cols" = name ]; then
    lc=\$(cat "$WORK/latebmn" 2>/dev/null || echo 0); lc=\$((lc+1)); echo "\$lc" > "$WORK/latebmn"
    [ "\$lc" -eq 2 ] && printf '%s#late-bm\t9800\t9810\t9800\n' "\$ds" >> "$WORK/bmarks.\$key"
  fi
  # execbm goes one window further in, and it is the window REV-120 round 2 is
  # about: AFTER the executor's own exact-set validation and BEFORE the
  # destructive commands. Nothing can detect it any more -- the only thing that
  # can save the object is a command shape incapable of consuming it. The
  # \`name,createtxg\` reads are, in order: the planner (1), the executor's
  # exact-set check (2), the final verification (3). Injecting after 2 puts the
  # bookmark exactly where no check will ever look again.
  if [ -f "$WORK/execbm" ] && [ "\$cols" = name,createtxg ]; then
    ec=\$(cat "$WORK/execbmn" 2>/dev/null || echo 0); ec=\$((ec+1)); echo "\$ec" > "$WORK/execbmn"
    [ "\$ec" -eq 2 ] && printf '%s#exec-bm\t9900\t9910\t9900\n' "\$ds" >> "$WORK/bmarks.\$key"
  fi
  exit 0
fi
if [ "\$want_snap" -eq 1 ]; then
  [ -s "$WORK/rows.\$key" ] || exit 1
  order "$WORK/rows.\$key" > "$WORK/o.\$\$"; project "$WORK/o.\$\$"; rm -f "$WORK/o.\$\$"
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
          "$WORK/arrivesnap_samesecond" "$WORK/verifyfail" "$WORK/commitsnapfail" \
          "$WORK/rollbackfail" "$WORK/sendfail" "$WORK/recvfail" "$WORK/recvguid" \
          "$WORK/written.$SRC" \
          "$WORK/bmarks.$SRC" "$WORK/bmarks.$COPY" "$WORK/bmarkfail" \
          "$WORK/arrivebm" "$WORK/latebm" "$WORK/latebmn" "$WORK/rollbackleak" \
          "$WORK/execbm" "$WORK/execbmn" "$WORK/setdestroyfail"
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
# operator reaching for recovery may know either one. With a clean boundary and
# --yes it now runs to completion: previews INKREMENT, executes, and reports done.
for name in rpool/data hdd/store/rpool/data; do
    reset_src
    out="$(runrepl "$stcfg" "$name")"; rc=$?
    { [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'INKREMENT' \
      && printf '%s' "$out" | grep -q 'ODTWORZENIE ZAKONCZONE'; } \
        && ok "replace: '$name' resolves to the relationship, previews and executes" \
        || bad "replace: '$name' resolves to the relationship, previews and executes" "rc=$rc" "$out"
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
#    same path crosses the boundary and RUNS to completion. Without this, a path
#    that always refused at the boundary would pass both race tests. The boundary
#    holding is now proven by the restore actually finishing, not by a placeholder.
reset_src
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'ODTWORZENIE ZAKONCZONE' \
  && ! printf '%s' "$out" | grep -q 'ZMIENIL'; } \
    && ok "REV-119: with nothing arriving the boundary holds and the restore completes (control)" \
    || bad "REV-119: with nothing arriving the boundary holds and the restore completes (control)" "rc=$rc" "$out"

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

# The whole-suite mutation audit (every zfs call was allowed; no technical
# snapshot survived) moved to the END of the file: now that execution exists, the
# destructive primitives run in the sections below too, and the audit is stronger
# read across the entire suite than across this section alone.

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
#     an operator who is not told will debug the wrong thing. Now that execution
#     exists, a clean boundary here RESTORES the source and only then fails to
#     lower the fence: the restore SUCCEEDED, but the housekeeping did not, and the
#     two facts are kept apart so the operator is sent to fix the readonly and not
#     to doubt the recovery.
reset_src
touch "$WORK/unfencefail"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'readonly' \
  && printf '%s' "$out" | grep -qi 'odtworzenie sie POWIODLO' \
  && ! printf '%s' "$out" | grep -q 'jest dokladnie w stanie sprzed tego polecenia'; } \
    && ok "REV-119 fence: a completed restore that cannot lower the fence says so loudly and names the fix" \
    || bad "REV-119 fence: a completed restore that cannot lower the fence says so loudly and names the fix" "rc=$rc" "$out"


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
#     exactly as you left it". The claim and the outcome have to agree. This is a
#     property of the REFUSAL path, where the technical snapshots are removed by
#     `zfs destroy`; a declined confirmation exercises it without executing.
reset_src
touch "$WORK/destroyfail"
out="$(runrepl "$stcfg" rpool/data 0 </dev/null)"; rc=$?
{ [ "$rc" -ne 0 ] \
  && printf '%s' "$out" | grep -q 'NIE jest w stanie sprzed polecenia' \
  && ! printf '%s' "$out" | grep -q 'jest dokladnie w stanie sprzed tego polecenia'; } \
    && ok "REV-119 F1.4: a failed cleanup is reported, never called an unchanged source" \
    || bad "REV-119 F1.4: a failed cleanup is reported, never called an unchanged source" "$out"

# 22. ...and the control, so 21 is discriminating: when a declined run's cleanup
#     succeeds, the path DOES get to say the source is unchanged.
reset_src
out="$(runrepl "$stcfg" rpool/data 0 </dev/null)"
{ printf '%s' "$out" | grep -q 'jest dokladnie w stanie sprzed tego polecenia' \
  && ! printf '%s' "$out" | grep -q 'NIE jest w stanie'; } \
    && ok "REV-119 F1.4: a successful cleanup may say the source is unchanged (control)" \
    || bad "REV-119 F1.4: a successful cleanup may say the source is unchanged (control)" "$out"


# ==============================================================================
# REV-119 F1.2 residual -- a failed fence restoration must reach the final claim.
#
# Two independent things can be left behind on the source: the readonly property
# and the technical snapshots. An earlier version knew about the second only, so
# a run that failed to put readonly back but did remove its snapshots told the
# operator the source was exactly as they had left it.
# ==============================================================================

# 23. Fence set succeeds, verification fails, restoration ALSO fails, snapshot
#     cleanup succeeds. Nonzero exit, the readonly remediation is printed, and
#     the exact-state claim must NOT appear.
reset_src
touch "$WORK/verifyfail" "$WORK/unfencefail"
printf 'off' > "$WORK/ro.value"; printf 'default' > "$WORK/ro.source"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] \
  && printf '%s' "$out" | grep -q "NIE jest w stanie sprzed polecenia" \
  && printf '%s' "$out" | grep -q "readonly" \
  && printf '%s' "$out" | grep -q 'zfs inherit readonly rpool/data' \
  && ! printf '%s' "$out" | grep -q 'jest dokladnie w stanie sprzed tego polecenia'; } \
    && ok "REV-119 F1.2: a failed fence restoration blocks the exact-state claim and names the fix" \
    || bad "REV-119 F1.2: a failed fence restoration blocks the exact-state claim and names the fix" "$out"

# 24. The same on the ARRIVAL refusal path, which is the one an operator is most
#     likely to hit for real: state showed up, we refuse -- and if putting the
#     fence back failed too, that has to reach the final message as well.
reset_src
touch "$WORK/arrivebytes_x"; echo 4096 > "$WORK/arrivebytes"; touch "$WORK/unfencefail"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] \
  && printf '%s' "$out" | grep -q 'stan zrodla sie ZMIENIL' \
  && printf '%s' "$out" | grep -q "NIE jest w stanie sprzed polecenia" \
  && ! printf '%s' "$out" | grep -q 'jest dokladnie w stanie sprzed tego polecenia'; } \
    && ok "REV-119 F1.2: the arrival refusal also reports a failed fence restoration" \
    || bad "REV-119 F1.2: the arrival refusal also reports a failed fence restoration" "$out"

# 25. Both left behind at once -- readonly AND a snapshot -- must both be named.
#     One message that mentions only the one it happens to check first would send
#     the operator to fix half of it. Driven off the ARRIVAL refusal so the
#     technical snapshots are still present (a rollback would have taken them) and
#     the failing `zfs destroy` leaves one behind while the fence stays up.
reset_src
echo 4096 > "$WORK/arrivebytes"; touch "$WORK/unfencefail" "$WORK/destroyfail"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] \
  && printf '%s' "$out" | grep -q "readonly" \
  && printf '%s' "$out" | grep -q "techniczne snapshoty"; } \
    && ok "REV-119 F1.2: both leftovers are named when both happen" \
    || bad "REV-119 F1.2: both leftovers are named when both happen" "$out"

# 26. And the control that keeps 23-25 honest: with everything working on a
#     declined run, the path still says the source is exactly as it was. An
#     implementation that simply stopped making the claim would pass all three
#     above.
reset_src
out="$(runrepl "$stcfg" rpool/data 0 </dev/null)"
{ printf '%s' "$out" | grep -q 'jest dokladnie w stanie sprzed tego polecenia' \
  && ! printf '%s' "$out" | grep -q 'NIE jest w stanie'; } \
    && ok "REV-119 F1.2: a clean declined run still makes the exact-state claim (control)" \
    || bad "REV-119 F1.2: a clean declined run still makes the exact-state claim (control)" "$out"


# 27. The one branch none of 23-26 reached: the BOUNDARY snapshot fails to be
#     created, with the fence already up, and putting the fence back fails too.
#     Deliberately not folded into the generic snapfail: failing the PREVIEW
#     snapshot proves a pre-mutation property (nothing has been touched yet),
#     while this is the first failure that happens with the property changed.
reset_src
touch "$WORK/commitsnapfail" "$WORK/unfencefail"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ printf '%s' "$out" | grep -q 'nie udalo sie zamknac granicy zatwierdzenia' \
  && [ "$rc" -ne 0 ] \
  && printf '%s' "$out" | grep -q 'readonly' \
  && printf '%s' "$out" | grep -q 'zfs inherit readonly rpool/data' \
  && ! printf '%s' "$out" | grep -q 'jest dokladnie w stanie sprzed tego polecenia'; } \
    && ok "REV-119 F1.2: a failed boundary snapshot reports the fence it could not put back" \
    || bad "REV-119 F1.2: a failed boundary snapshot reports the fence it could not put back" "$out"
[ "$(srccount)" = 1 ] \
    && ok "REV-119 F1.2: ...and the preview snapshot is still cleaned up on that branch" \
    || bad "REV-119 F1.2: ...and the preview snapshot is still cleaned up on that branch" "$(cat "$WORK/rows.$SRC")"

# ==============================================================================
# EXECUTION -- the destructive step itself (R-026, the internal slice after
# REV-119 closure). One GUID-anchored rollback for every reachable strategy, plus
# an incremental receive when the recovery point is ahead of the source.
#
# rollback / send / recv are modelled against the same rows store the reads use,
# so these assert the EFFECT (blockers gone, target arrived, guid matches) and not
# merely that a command ran. The live-ZFS end-to-end proof is separate; this pins
# the branching and the truthful failure/cleanup semantics.
# ==============================================================================

# EX1. Increment: the recovery point is ahead of the source. The source is rolled
#      back to the common base and the delta is received. Success is verified by
#      GUID -- the source's newest snapshot must carry the target guid (22 here).
#      This is also the strong control for the arrival tests: a clean boundary now
#      RUNS to completion rather than reaching a placeholder.
reset_src
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
head_guid="$(grep '^rpool/data@' "$WORK/rows.$SRC" | tail -1 | cut -f3)"
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'ODTWORZENIE ZAKONCZONE' \
  && grep -q '^rpool/data@s2	' "$WORK/rows.$SRC" \
  && [ "$head_guid" = 22 ] \
  && ! grep -q 'restore-' "$WORK/rows.$SRC"; } \
    && ok "EXEC increment: source rolled to base, delta received, newest snapshot carries the target guid" \
    || bad "EXEC increment: source rolled to base, delta received, newest snapshot carries the target guid" \
           "rc=$rc head=$head_guid rows=[$(tr '\n' ';' < "$WORK/rows.$SRC")]" "$out"

# EX2. Rollback-only: the source already holds the recovery point but has moved
#      PAST it. No transfer; the blockers newer than the base are destroyed and the
#      source lands back on the recovery point (guid 11).
reset_src
printf 'hdd/store/rpool/data@s1\t100\t11\n' > "$WORK/rows.$COPY"
printf 'rpool/data@s1\t100\t11\nrpool/data@s2\t200\t22\nrpool/data@s3\t300\t33\n' > "$WORK/rows.$SRC"
sends_before=$(grep -c '^send ' "$WORK/zfs-calls3" 2>/dev/null || echo 0)
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
sends_after=$(grep -c '^send ' "$WORK/zfs-calls3" 2>/dev/null || echo 0)
head_guid="$(grep '^rpool/data@' "$WORK/rows.$SRC" | tail -1 | cut -f3)"
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'ODTWORZENIE ZAKONCZONE' \
  && ! grep -q '^rpool/data@s2	' "$WORK/rows.$SRC" \
  && ! grep -q '^rpool/data@s3	' "$WORK/rows.$SRC" \
  && [ "$head_guid" = 11 ] \
  && [ "$sends_before" = "$sends_after" ]; } \
    && ok "EXEC rollback: blockers destroyed, source back on the recovery point, no transfer" \
    || bad "EXEC rollback: blockers destroyed, source back on the recovery point, no transfer" \
           "rc=$rc head=$head_guid sends=$sends_before/$sends_after rows=[$(tr '\n' ';' < "$WORK/rows.$SRC")]" "$out"

# EX3. Discard-live: base == latest, no newer snapshot, but live writes after it.
#      Rolling back to the base discards those live changes; still no transfer.
reset_src
printf 'hdd/store/rpool/data@s1\t100\t11\n' > "$WORK/rows.$COPY"
printf 'rpool/data@s1\t100\t11\n' > "$WORK/rows.$SRC"
printf '4096\n' > "$WORK/written.$SRC"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
head_guid="$(grep '^rpool/data@' "$WORK/rows.$SRC" | tail -1 | cut -f3)"
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'ODTWORZENIE ZAKONCZONE' \
  && [ "$head_guid" = 11 ]; } \
    && ok "EXEC discard-live: a source with live changes is rolled back to the recovery point" \
    || bad "EXEC discard-live: a source with live changes is rolled back to the recovery point" "rc=$rc head=$head_guid" "$out"
rm -f "$WORK/written.$SRC"

# EX4. A clean pipeline that produced the WRONG identity still fails -- the GUID
#      acceptance test is the authority, not the transfer's exit code. The source
#      has been rolled back, so this is a destruction-began failure: never claim it
#      is unchanged.
reset_src
printf '999' > "$WORK/recvguid"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'weryfikacja GUID zawiodla' \
  && printf '%s' "$out" | grep -q 'NIE jest w stanie sprzed polecenia' \
  && ! printf '%s' "$out" | grep -q 'ODTWORZENIE ZAKONCZONE'; } \
    && ok "EXEC guid: a clean pipeline with the wrong guid fails and never claims an unchanged source" \
    || bad "EXEC guid: a clean pipeline with the wrong guid fails and never claims an unchanged source" "rc=$rc" "$out"

# EX5. A failed transfer AFTER the rollback: the source is left on the common base,
#      short of the target. That is real destruction without completion, and the
#      report says so rather than claiming the source is unchanged.
reset_src
touch "$WORK/recvfail"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'COFNIETE do wspolnej bazy' \
  && printf '%s' "$out" | grep -q 'NIE jest w stanie sprzed polecenia' \
  && ! printf '%s' "$out" | grep -q 'jest dokladnie w stanie sprzed tego polecenia'; } \
    && ok "EXEC transfer-fail: a broken receive after the rollback reports partial destruction, not a clean source" \
    || bad "EXEC transfer-fail: a broken receive after the rollback reports partial destruction, not a clean source" "rc=$rc" "$out"

# EX6a/EX6b. Where "nothing was destroyed" now ends, exactly.
#
# This pair used to be one assertion, and REV-120 round 2 moved the line it
# tested. The destructive step is no longer a single atomic rollback, so "the
# rollback failed" no longer implies "nothing was destroyed". Rewritten to the new
# contract rather than loosened -- the boundary is still asserted, it just sits
# somewhere else, and that somewhere is worth pinning precisely because it is the
# price this REV paid for the safety property.
#
# EX6a: the ONE call that removes the approved snapshots fails. It is all-or-none,
#       and it is the first destructive act, so nothing was destroyed and the
#       exact-state claim is still allowed.
reset_src
touch "$WORK/setdestroyfail"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'NIC nie zniszczono' \
  && printf '%s' "$out" | grep -q 'jest dokladnie w stanie sprzed tego polecenia' \
  && ! printf '%s' "$out" | grep -q 'NIE jest w stanie sprzed polecenia'; } \
    && ok "EXEC set-destroy-fail: the all-or-none destroy of the approved set fails, destroys nothing, and may claim an unchanged source" \
    || bad "EXEC set-destroy-fail: the all-or-none destroy of the approved set fails, destroys nothing, and may claim an unchanged source" "rc=$rc" "$out"
rm -f "$WORK/setdestroyfail"

# EX6b: the rollback fails AFTER those destroys. The approved objects are gone, so
#       this is a partial failure and the exact-state claim is forbidden. Same verb
#       as EX6a, opposite claim -- which is the whole discrimination.
reset_src
touch "$WORK/rollbackfail"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'NIE jest w stanie sprzed polecenia' \
  && ! printf '%s' "$out" | grep -q 'jest dokladnie w stanie sprzed tego polecenia'; } \
    && ok "EXEC rollback-fail: a rollback failing after the approved destroys is a PARTIAL failure, never an unchanged source" \
    || bad "EXEC rollback-fail: a rollback failing after the approved destroys is a PARTIAL failure, never an unchanged source" "rc=$rc" "$out"

# ==============================================================================
# REV-20260814-120 F1 -- BOOKMARKS are part of what the rollback destroys, so they
# are part of what the operator approves.
#
# `zfs rollback -r` applies its newer-than-target test to snapshots AND bookmarks:
# measured on pve0 (zfs-2.1.9), rolling back to @s1 with #bm1/#bm2/#bm3 present left
# only #bm1, the one whose createtxg equals the target's. The planner enumerated
# snapshots only, so the primitive could destroy a bookmark that never appeared in
# the measured loss set -- silently widening the approved destructive set, which is
# the property REV-119's confirmation boundary exists to hold.
#
# A bookmark costs no space, so none of this shows up in the byte total. What it
# costs is the anchor for a future incremental send, which is exactly the kind of
# loss an operator has to be asked about rather than told about afterwards.
# ==============================================================================

# bmnew is newer than the base by createtxg (250 > 100) and bmold is older (50).
# Both exist for every assertion below, so "names the right one" and "leaves the
# other alone" are the same run rather than two fixtures.
bmfixture() {
    reset_src
    printf 'rpool/data#bmnew\t250\t77\t250\nrpool/data#bmold\t50\t66\t50\n' > "$WORK/bmarks.$SRC"
}

# BM1. The measured loss set NAMES the newer bookmark, before the question is asked,
#      and does not name the older one. This is the acceptance boundary: the set the
#      operator approves has to be the set the rollback destroys.
bmfixture
out="$(runrepl "$stcfg" rpool/data 0 </dev/null)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'bookmark  bmnew' \
  && ! printf '%s' "$out" | grep -q 'bmold'; } \
    && ok "REV-120 F1: the measured loss set names the newer bookmark and not the older one" \
    || bad "REV-120 F1: the measured loss set names the newer bookmark and not the older one" "rc=$rc" "$out"

# BM2. Declining leaves it intact. A bookmark shown as "to be destroyed" and then
#      destroyed anyway on a refusal would be the worst of both.
grep -q '^rpool/data#bmnew	' "$WORK/bmarks.$SRC" \
    && ok "REV-120 F1: declining the confirmation leaves the bookmark intact" \
    || bad "REV-120 F1: declining the confirmation leaves the bookmark intact" "$(cat "$WORK/bmarks.$SRC")"

# BM3. Confirmed: the approved bookmark is gone and the older one survives. This is
#      the EFFECT, not the wording -- the stub models what ZFS was measured doing.
bmfixture
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'ODTWORZENIE ZAKONCZONE' \
  && ! grep -q '^rpool/data#bmnew	' "$WORK/bmarks.$SRC" \
  && grep -q '^rpool/data#bmold	' "$WORK/bmarks.$SRC"; } \
    && ok "REV-120 F1: an approved run destroys the newer bookmark and keeps the older one" \
    || bad "REV-120 F1: an approved run destroys the newer bookmark and keeps the older one" \
           "rc=$rc bookmarks=[$(tr '\n' ';' < "$WORK/bmarks.$SRC")]" "$out"

# BM4. CONTROL. A source whose only bookmark is NOT newer than the base must not be
#      told it is losing one. Without this, an implementation that listed every
#      bookmark unconditionally would pass BM1 and BM3.
reset_src
printf 'rpool/data#bmold\t50\t66\t50\n' > "$WORK/bmarks.$SRC"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'BOOKMARKI' \
  && ! printf '%s' "$out" | grep -q 'bookmark  bmold' \
  && grep -q '^rpool/data#bmold	' "$WORK/bmarks.$SRC"; } \
    && ok "REV-120 F1: a bookmark older than the base is neither announced nor destroyed (control)" \
    || bad "REV-120 F1: a bookmark older than the base is neither announced nor destroyed (control)" \
           "rc=$rc bookmarks=[$(tr '\n' ';' < "$WORK/bmarks.$SRC")]" "$out"

# BM5. FAIL CLOSED. A bookmark listing that cannot be read is not "no bookmarks".
#      Both are an empty string in a shell variable and opposite facts to an
#      operator about to destroy data, so the run refuses before its first mutation.
reset_src
touch "$WORK/bmarkfail"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'pelnego zbioru snapshotow i bookmarkow' \
  && ! printf '%s' "$out" | grep -q 'krok WYKONAWCZY' \
  && [ "$(srccount)" = 1 ]; } \
    && ok "REV-120 F1: an unreadable bookmark listing refuses instead of reading as 'none'" \
    || bad "REV-120 F1: an unreadable bookmark listing refuses instead of reading as 'none'" "rc=$rc" "$out"

# BM6. A bookmark arriving after the approval, inside the window the commit boundary
#      covers. readonly=on does not keep it out -- `zfs bookmark` is no more a
#      userland write than `zfs snapshot` is -- so the boundary has to see it.
reset_src
touch "$WORK/arrivebm"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'stan zrodla sie ZMIENIL' \
  && printf '%s' "$out" | grep -q 'nowy bookmark: intruder-bm' \
  && ! printf '%s' "$out" | grep -q 'krok WYKONAWCZY' \
  && grep -q 'intruder-bm' "$WORK/bmarks.$SRC"; } \
    && ok "REV-120 F1: a bookmark arriving after the approval is caught by the commit boundary and survives" \
    || bad "REV-120 F1: a bookmark arriving after the approval is caught by the commit boundary and survives" "rc=$rc" "$out"

# BM7. ...and one arriving AFTER the boundary, in the last window before the
#      destructive command, is caught by the executor's own re-measurement: the set
#      about to be destroyed is compared for exact equality against the approved one.
#      Nothing is destroyed, so the exact-state claim is still allowed.
reset_src
touch "$WORK/latebm"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'NIE jest tym zatwierdzonym' \
  && printf '%s' "$out" | grep -q 'late-bm' \
  && printf '%s' "$out" | grep -q 'NIC nie zniszczono' \
  && printf '%s' "$out" | grep -q 'jest dokladnie w stanie sprzed tego polecenia' \
  && grep -q 'late-bm' "$WORK/bmarks.$SRC" \
  && [ "$(srccount)" = 1 ]; } \
    && ok "REV-120 F1: a bookmark arriving after the boundary is caught before destruction, and nothing is destroyed" \
    || bad "REV-120 F1: a bookmark arriving after the boundary is caught before destruction, and nothing is destroyed" "rc=$rc" "$out"

# BM7b. REV-120 ROUND 2, the required discrimination. The bookmark arrives one
#       window further in: AFTER the executor's own exact-set validation and
#       BEFORE the destructive commands. No check can see it any more, so the
#       only thing that can save it is a command shape incapable of consuming it.
#
#       Required result: the late bookmark SURVIVES, the run fails truthfully, and
#       it never claims an approved destructive completion. It is a partial
#       failure and says so -- the approved objects were destroyed by name before
#       the rollback refused, and pretending otherwise would be the same
#       laundering REV-119 F1.4 removed.
#
#       Against the round-1 implementation (`zfs rollback -r`) the bookmark is
#       silently destroyed and the run reports success, which is the whole point.
reset_src
touch "$WORK/execbm"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] \
  && grep -q '^rpool/data#exec-bm	' "$WORK/bmarks.$SRC" \
  && printf '%s' "$out" | grep -q 'NIE usunieto' \
  && printf '%s' "$out" | grep -q 'NIE jest w stanie sprzed polecenia' \
  && ! printf '%s' "$out" | grep -q 'ODTWORZENIE ZAKONCZONE' \
  && ! printf '%s' "$out" | grep -q 'jest dokladnie w stanie sprzed tego polecenia'; } \
    && ok "REV-120 r2: a bookmark arriving after the LAST validation survives, and the run fails truthfully" \
    || bad "REV-120 r2: a bookmark arriving after the LAST validation survives, and the run fails truthfully" \
           "rc=$rc bookmarks=[$(tr '\n' ';' < "$WORK/bmarks.$SRC")]" "$out"

# BM7c. The same run's other half: the approved objects WERE destroyed. Without
#       this the assertion above would also pass an implementation that refused
#       before touching anything, which is a different (and unattainable) contract.
{ ! grep -q 'restore-preview-' "$WORK/rows.$SRC" && ! grep -q 'restore-commit-' "$WORK/rows.$SRC"; } \
    && ok "REV-120 r2: ...and the approved objects had already been destroyed, which is why it is a PARTIAL failure" \
    || bad "REV-120 r2: ...and the approved objects had already been destroyed, which is why it is a PARTIAL failure" "$(cat "$WORK/rows.$SRC")"

# BM7d. The shape itself is the guarantee, so it is asserted directly: no call in
#       the whole suite may be a recursive rollback. The stub refuses `-r` outright,
#       so this is belt and braces on the call log -- the property REV-120 round 2
#       exists to establish is "execution cannot widen the approved set", and that
#       is a statement about which commands are issued, not about their timing.
grep -q '^rollback -r ' "$WORK/zfs-calls3" \
    && bad "REV-120 r2: no recursive rollback is ever issued" "$(grep '^rollback -r ' "$WORK/zfs-calls3" | head -2)" \
    || ok "REV-120 r2: no recursive rollback is ever issued"

# BM8. The read-only plan shows it too, so an operator sees the bookmark loss while
#      still deciding, not only inside the destructive verb.
bmfixture
out="$(runstrat "$stcfg")"
{ printf '%s' "$out" | grep -q 'BOOKMARKI' && printf '%s' "$out" | grep -q 'bmnew' \
  && ! printf '%s' "$out" | grep -q 'bmold'; } \
    && ok "REV-120 F1: the read-only plan announces the bookmarks a recovery would destroy" \
    || bad "REV-120 F1: the read-only plan announces the bookmarks a recovery would destroy" "$out"

# ==============================================================================
# REV-20260814-120 F2 -- the final check is anchored on IDENTITY, never on the last
# row of a creation-sorted listing.
#
# `creation` is a wall-clock second and this project keeps measuring duplicates of
# it -- including on pve0 while gathering the evidence for this very review, where
# @s1 and @s2 came back with the same creation and createtxg 42609087/42609088. So
# `-s creation | tail -1` is not a statement about which snapshot is the head; it is
# a statement about which of two equal rows ZFS happened to print last.
#
# The stub therefore HONOURS `-s creation` with a documented tie-break, and the
# fixtures below put the adverse row last on purpose. Both cases are correct
# restores that the old check would have reported as failures.
# ==============================================================================

# GX1. ROLLBACK strategy. The source holds a peer snapshot made in the same second
#      as the recovery point but one transaction earlier, and its name sorts after.
reset_src
printf 'hdd/store/rpool/data@aa-base\t100\t11\n' > "$WORK/rows.$COPY"
printf 'rpool/data@aa-base\t100\t11\t100\nrpool/data@zz-peer\t100\t55\t90\nrpool/data@s9\t300\t33\t300\n' > "$WORK/rows.$SRC"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
# The tie is read from the FINAL state, which is what the acceptance test judges:
# the last row of a creation-sorted listing is the PEER, not the recovery point.
tie_guid="$( ( PATH="$WORK/bin3:$PATH" zfs list -H -p -t snapshot -o name,guid -s creation -d 1 rpool/data ) | tail -1 | cut -f2)"
{ [ "$tie_guid" = 55 ] && [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | grep -q 'ODTWORZENIE ZAKONCZONE' \
  && grep -q '^rpool/data@zz-peer	' "$WORK/rows.$SRC" \
  && ! grep -q '^rpool/data@s9	' "$WORK/rows.$SRC"; } \
    && ok "REV-120 F2: rollback -- a same-second peer sorting last does not turn a correct restore into a failure" \
    || bad "REV-120 F2: rollback -- a same-second peer sorting last does not turn a correct restore into a failure" \
           "tie_guid=$tie_guid rc=$rc rows=[$(tr '\n' ';' < "$WORK/rows.$SRC")]" "$out"

# GX2. CONTROL on the same fixture: the check must verify the whole required final
#      state, not merely that the target is present somewhere. rollbackleak models a
#      rollback that returns 0 and leaves a newer snapshot behind -- the C-006/C-007
#      class. Without this, "does the target guid exist" would pass GX1 too.
reset_src
printf 'hdd/store/rpool/data@aa-base\t100\t11\n' > "$WORK/rows.$COPY"
printf 'rpool/data@aa-base\t100\t11\t100\nrpool/data@zz-peer\t100\t55\t90\nrpool/data@s9\t300\t33\t300\n' > "$WORK/rows.$SRC"
printf 'rpool/data@leak\t400\t44\t400\n' > "$WORK/rollbackleak"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'weryfikacja stanu koncowego zawiodla' \
  && printf '%s' "$out" | grep -q 'leak' \
  && printf '%s' "$out" | grep -q 'NIE jest w stanie sprzed polecenia' \
  && ! printf '%s' "$out" | grep -q 'ODTWORZENIE ZAKONCZONE'; } \
    && ok "REV-120 F2: a rollback that returns 0 and leaves something newer is a post-destruction failure" \
    || bad "REV-120 F2: a rollback that returns 0 and leaves something newer is a post-destruction failure" "rc=$rc" "$out"

# GX3. INCREMENT strategy, same defect, different route. `zfs recv` preserves the
#      stream's creation and assigns a fresh local createtxg, so a received recovery
#      point carries the SENDING host's clock. Tying with a local snapshot's second
#      is therefore ordinary rather than exotic -- and here the local peer (itself
#      received by an earlier recovery, which is why its creation and createtxg do
#      not agree in order) sorts last and carries a different guid.
reset_src
printf 'hdd/store/rpool/data@aa-base\t100\t11\nhdd/store/rpool/data@bb-target\t500\t22\n' > "$WORK/rows.$COPY"
printf 'rpool/data@aa-base\t100\t11\t100\nrpool/data@zz-peer\t500\t55\t90\n' > "$WORK/rows.$SRC"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
tie_guid="$( ( PATH="$WORK/bin3:$PATH" zfs list -H -p -t snapshot -o name,guid -s creation -d 1 rpool/data ) | tail -1 | cut -f2)"
{ [ "$rc" -eq 0 ] && [ "$tie_guid" = 55 ] \
  && printf '%s' "$out" | grep -q 'ODTWORZENIE ZAKONCZONE' \
  && grep -q '^rpool/data@bb-target	' "$WORK/rows.$SRC"; } \
    && ok "REV-120 F2: increment -- a received recovery point tying on creation is still verified by identity" \
    || bad "REV-120 F2: increment -- a received recovery point tying on creation is still verified by identity" \
           "rc=$rc tie_guid=$tie_guid rows=[$(tr '\n' ';' < "$WORK/rows.$SRC")]" "$out"

# ==============================================================================
# REV-20260814-121 -- the DEFAULT recovery point must be a fact, not a list
# position.
#
# Same unsound rule as REV-120 F2, one step earlier and with worse consequences:
# F2 decided whether the restore had landed, this decides WHERE it lands. The axis
# stays `creation` (capture time, which is what the owner's policy means); what
# changes is that a shared maximum refuses instead of resolving by whatever order
# ZFS happened to print.
# ==============================================================================

# RP1. Two copy snapshots share the maximum creation, adverse names. Refuse, name
#      both candidates, and do it in the PREVIEW -- before any mutation, fence or
#      confirmation.
reset_src
printf 'hdd/store/rpool/data@aa-one\t500\t71\nhdd/store/rpool/data@zz-two\t500\t72\n' > "$WORK/rows.$COPY"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'NIEJEDNOZNACZNY' \
  && printf '%s' "$out" | grep -q 'aa-one' && printf '%s' "$out" | grep -q 'zz-two' \
  && ! printf '%s' "$out" | grep -q 'DO ZNISZCZENIA' \
  && ! grep -q 'restore-preview-' "$WORK/rows.$SRC" \
  && [ "$(srccount)" = 1 ]; } \
    && ok "REV-121: a tied maximum creation refuses, names both candidates, and mutates nothing" \
    || bad "REV-121: a tied maximum creation refuses, names both candidates, and mutates nothing" "rc=$rc" "$out"

# RP2. CONTROL: a unique maximum still selects the expected GUID and runs. Without
#      this, an implementation that refused whenever a copy had more than one
#      snapshot would pass RP1.
reset_src
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'guid=22' \
  && ! printf '%s' "$out" | grep -q 'NIEJEDNOZNACZNY' \
  && printf '%s' "$out" | grep -q 'ODTWORZENIE ZAKONCZONE'; } \
    && ok "REV-121: a unique maximum creation still selects the expected recovery point (control)" \
    || bad "REV-121: a unique maximum creation still selects the expected recovery point (control)" "rc=$rc" "$out"

# RP3. The tie only matters at the MAXIMUM. Two older snapshots sharing a second,
#      with a unique newest above them, is not ambiguous -- refusing there would be
#      a verb that stops working on any busy backup.
reset_src
printf 'hdd/store/rpool/data@aa-old\t100\t81\nhdd/store/rpool/data@zz-old\t100\t82\nhdd/store/rpool/data@newest\t900\t83\n' > "$WORK/rows.$COPY"
printf 'rpool/data@aa-old\t100\t81\t100\n' > "$WORK/rows.$SRC"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'guid=83' \
  && ! printf '%s' "$out" | grep -q 'NIEJEDNOZNACZNY'; } \
    && ok "REV-121: a tie BELOW the maximum is not an ambiguity (control)" \
    || bad "REV-121: a tie BELOW the maximum is not an ambiguity (control)" "rc=$rc" "$out"

# RP4. Unreadable capture times are an ambiguity too, not an empty maximum. Same
#      fail-closed direction as the unproven loss set.
reset_src
printf 'hdd/store/rpool/data@s1\tnotatime\t11\n' > "$WORK/rows.$COPY"
out="$(runrepl "$stcfg" rpool/data)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'NIEJEDNOZNACZNY'; } \
    && ok "REV-121: a copy whose capture times cannot be read refuses instead of picking one" \
    || bad "REV-121: a copy whose capture times cannot be read refuses instead of picking one" "rc=$rc" "$out"

# RP5. The rule is gone from the source, not just from the behaviour: no `tail -1`
#      may remain in recovery-target selection. Asserted on the code, because the
#      next person to add a listing there will reach for it again.
sel="$(sed -n '/^restore_plan_strategy()/,/^}/p' "$ZB" | grep -v '^[[:space:]]*#' | grep -n 'tail -1' || true)"
[ -z "$sel" ] \
    && ok "REV-121: no tail -1 over a creation-ordered listing remains in the planner" \
    || bad "REV-121: no tail -1 over a creation-ordered listing remains in the planner" "$sel"

# ==============================================================================
# Whole-suite mutation audit. Moved here from the slice-1 section because the
# destructive primitives now run below too, so reading the WHOLE log is a stronger
# statement than reading one section. Every zfs call the destructive path ever made
# was a read, one of this run's own technical snapshots, the write fence, or one of
# the three execution primitives on the source/copy. The allowed set is ENUMERATED,
# not loosened: a path that started touching any other dataset or property shows up
# as a stray.
# ==============================================================================
strays="$(grep -vE '^(list|get) ' "$WORK/zfs-calls3" 2>/dev/null \
          | grep -vE '^snapshot rpool/data@restore-(preview|commit)-' \
          | grep -vE '^destroy rpool/data[@#]' \
          | grep -vE '^set readonly=(on|off) rpool/data$' \
          | grep -vE '^inherit (-S )?readonly rpool/data$' \
          | grep -vE '^rollback rpool/data@' \
          | grep -vE '^send -i ' \
          | grep -vE '^recv rpool/data$' || true)"
[ -z "$strays" ] \
    && ok "audit: across the whole suite the destructive path only read, fenced, or ran its own primitives" \
    || bad "audit: across the whole suite the destructive path only read, fenced, or ran its own primitives" "$strays"


# ---------------------------------------------------------------------------
# THE PUBLIC ADDRESS RESOLVER (owner grammar 2026-08-13, R-025).
#
# The rule under test is the one that disarms the destructive ambiguity: a name
# that does not resolve is an ERROR, never a guess. The three R-025 refusals
# are pinned as discriminators, because each one is a door to restoring onto
# the wrong machine if it ever silently opens.
# ---------------------------------------------------------------------------
RSV="$WORK/resolver.conf"
cat > "$RSV" <<'CONF'
[dataset:hdd/backups/192.168.28.8/rpool/data]
	# managed-by: zfs-backup.sh client=pve2
	src          = acct@192.168.28.8:rpool/data
	pair_label   = pve2

[dataset:hdd/backups/192.168.28.8/tank/vm]
	# managed-by: zfs-backup.sh client=pve2
	src          = acct@192.168.28.8:tank/vm
	pair_label   = pve2

[dataset:rpool/data2]
	# managed-by: zfs-backup.sh client=local
	dst          = hdd/localcopy
	pair_label   = lokalny
CONF

rsv() {   # <token> -> stdout lines; rc
    ( set +u; VERBOSE=0
      source "$ZB" 2>/dev/null
      restore_resolve_token "$RSV" "$1" 2>&1 )
}

out=$(rsv pve2); rc=$?
if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] \
   && printf '%s\n' "$out" | grep -q "acct@192.168.28.8:rpool/data	hdd/backups/192.168.28.8/rpool/data"; then
    ok "resolver: a bare label selects the WHOLE relation, identity printed AS RECORDED"
else
    bad "resolver: a bare label selects the WHOLE relation, identity printed AS RECORDED" "rc=$rc out=$out"
fi

out=$(rsv pve2:tank/vm); rc=$?
if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] \
   && printf '%s\n' "$out" | grep -q "^acct@192.168.28.8:tank/vm	"; then
    ok "resolver: label:dataset selects exactly that dataset of that relation"
else
    bad "resolver: label:dataset selects exactly that dataset of that relation" "rc=$rc out=$out"
fi

out=$(rsv hdd/localcopy/rpool/data2); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "^rpool/data2	"; then
    ok "resolver: a managed copy path resolves verbatim"
else
    bad "resolver: a managed copy path resolves verbatim" "rc=$rc out=$out"
fi

# R-025 refusal 1: transport addressing is not a public address.
out=$(rsv "acct@192.168.28.8:rpool/data"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "transport addressing is not part"; then
    ok "resolver R-025/1: user@host:dataset is refused outright"
else
    bad "resolver R-025/1: user@host:dataset is refused outright" "rc=$rc out=$out"
fi

# R-025 refusal 2: a bare word never falls back to being a hostname.
out=$(rsv pve9); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "NOT treated as a hostname"; then
    ok "resolver R-025/2: an unknown bare word refuses, never a hostname guess"
else
    bad "resolver R-025/2: an unknown bare word refuses, never a hostname guess" "rc=$rc out=$out"
fi

# R-025 refusal 3: an arbitrary local dataset is never adopted as provenance.
out=$(rsv rpool/scratch/vm-999); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "never adopted as backup provenance"; then
    ok "resolver R-025/3: an unmanaged POOL/PATH refuses"
else
    bad "resolver R-025/3: an unmanaged POOL/PATH refuses" "rc=$rc out=$out"
fi

# And the near-miss inside a real relation: right label, wrong dataset.
out=$(rsv pve2:rpool/ROOT); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "does not cover dataset"; then
    ok "resolver: right label + unknown dataset refuses and says which half failed"
else
    bad "resolver: right label + unknown dataset refuses and says which half failed" "rc=$rc out=$out"
fi


# ---------------------------------------------------------------------------
# ':' IS LEGAL INSIDE A ZFS DATASET NAME (#132 reviewer discriminator).
#
# The first resolver split every colon-bearing token as label:dataset before
# considering a verbatim managed path, so a legal copy location
# `.../pool/data:archive` -- sitting right there in CONFIG -- was refused as
# relation 'hdd/backups/...' + dataset 'archive'. The seven original resolver
# tests were green the whole time, because none used a colon-bearing name.
#
# The rule stays "never guess": exact verbatim match wins; if BOTH readings
# resolve, that is genuine ambiguity and it refuses naming both.
RSC="$WORK/colon.conf"
cat > "$RSC" <<'CONF'
[dataset:hdd/backups/client/pool/data:archive]
	src          = acct@10.0.0.1:pool/data:archive
	pair_label   = pve2

[dataset:hdd/plain/archive]
	src          = acct@10.0.0.1:archive
	pair_label   = hdd/backups/client/pool/data
CONF

rsc() { ( set +u; VERBOSE=0; source "$ZB" 2>/dev/null; restore_resolve_token "$RSC" "$1" 2>&1 ); }

out=$(rsc "hdd/backups/client/pool/data:archive"); rc=$?
# the second section's pair_label makes BOTH readings resolve -> must refuse
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "ambiguous"; then
    ok "resolver: a token matching BOTH a managed path and label:dataset refuses as ambiguous"
else
    bad "resolver: a token matching BOTH a managed path and label:dataset refuses as ambiguous" "rc=$rc out=$out"
fi

# with the contrived label removed, the verbatim path must win
sed -i 's|pair_label   = hdd/backups/client/pool/data$|pair_label   = inny|' "$RSC"
out=$(rsc "hdd/backups/client/pool/data:archive"); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "pool/data:archive"; then
    ok "resolver: a legal colon-bearing managed copy resolves verbatim"
else
    bad "resolver: a legal colon-bearing managed copy resolves verbatim" "rc=$rc out=$out"
fi

# and the ordinary label:dataset reading still works on the same config
out=$(rsc "pve2:pool/data:archive"); rc=$?
if [ "$rc" -eq 0 ]; then
    ok "resolver: label:dataset still resolves when the dataset half itself carries a colon"
else
    bad "resolver: label:dataset still resolves when the dataset half itself carries a colon" "rc=$rc out=$out"
fi

# ============================================================================
# WHICH DATASETS OF THE RELATIONSHIP -- `--source` / `--target`, comma-separated
#
# Owner decision 2026-08-26: a VM with four virtual disks is four datasets and
# ONE recovery. Reviewer contract the same day: one namespace per invocation, and
# the WHOLE list resolves before anything is shown.
#
# The pair that carries this block is sc5/sc6: the same dataset named on the
# wrong side must be refused in BOTH directions. An implementation that let a
# member match either side would pass every other case here.
# ============================================================================
SC="$WORK/scope"; mkdir -p "$SC"
cat > "$SC/cfg" <<'CFGEOF'
[defaults]
	host_label = coll
[template:h]
	send_schedule = 0 * * * *
	prefix        = a_
[dataset:hdd/store]
	use_template = h
	src          = root@pve2:rpool/data/vm-101-disk-0
	pair_label   = pve2
[dataset:hdd/store2]
	use_template = h
	src          = root@pve2:rpool/data/vm-101-disk-1
	pair_label   = pve2
[dataset:hdd/other]
	use_template = h
	src          = root@pve1:rpool/data/x
	pair_label   = pve1
CFGEOF

# ---------------------------------------------------------------------------
# WHY --plan APPEARS ON THESE CALLS, AND DID NOT USE TO
#
# Until 2026-08-27 a resolved scope was FORCED into plan mode: `--at` or
# `--source/--target` set plan=1 unconditionally, because nothing downstream
# could act on a resolved scope. These assertions were written against that, and
# they inspect plan output ("Zrodlo:", "WYBRANO", the strategy captions) while
# passing no --plan.
#
# That forcing is gone deliberately. The scope resolves and then RUNS, which is
# the whole point of the verb, and it is proven on live hosts (pve9 -> pve1,
# 2026-08-27, nine variants). So the assertions below have to ask for the plan
# they are reading -- and the fact that they are read-only is now something the
# call says rather than something the program imposes.
#
# The behaviour they used to pin -- "a scope never writes" -- is not silently
# dropped. It is inverted and pinned the other way, at the foot of this section:
# a scoped call WITHOUT --plan must reach the per-dataset runner. Deleting the
# old assertion without adding that one would have left the change untested in
# both directions.
# ---------------------------------------------------------------------------
sc_run() { PATH="$WORK/bin:$PATH" bash "$ZB" "$@" --plan --config="$SC/cfg" 2>&1; }
sc_ok() {   # <desc> <expected substring> <args...>
    local desc="$1" want="$2"; shift 2
    local out; out="$(sc_run "$@")"
    case "$out" in *"$want"*) ok "$desc" ;; *) bad "$desc" "want: $want" "got: $(printf '%s' "$out" | head -2)" ;; esac
}
sc_refuses() {   # <desc> <expected substring of the refusal> <args...>
    local desc="$1" want="$2"; shift 2
    local out; out="$(sc_run "$@")"; local rc=$?
    if [ "$rc" -eq 0 ]; then bad "$desc" "expected a refusal, got rc=0"; return; fi
    case "$out" in *"$want"*) ok "$desc" ;; *) bad "$desc" "want: $want" "got: $(printf '%s' "$out" | head -2)" ;; esac
}

# The case the decision exists for: two disks of one VM, one command.
out="$(sc_run pve2 --target rpool/data/vm-101-disk-0,rpool/data/vm-101-disk-1)"
n="$(printf '%s\n' "$out" | grep -c 'Zrodlo:')"
if [ "$n" = 2 ]; then ok "scope: two disks of one VM in ONE command"
else bad "scope: two disks of one VM in ONE command" "expected 2 datasets in the plan, got $n"; fi
# ...and it must not have quietly included the relationship's other members or
# another relationship's. Two, exactly two.
case "$out" in
    *"rpool/data/x"*) bad "scope: ...and nothing from another relationship" "rpool/data/x is in the plan" ;;
    *) ok "scope: ...and nothing from another relationship" ;;
esac

# The same two, named on the collector side instead. Same plan.
out2="$(sc_run pve2 --source hdd/store,hdd/store2)"
n2="$(printf '%s\n' "$out2" | grep -c 'Zrodlo:')"
if [ "$n2" = 2 ]; then ok "scope: the same two named on the collector side"
else bad "scope: the same two named on the collector side" "expected 2, got $n2"; fi

# The "mutually exclusive" assertion that stood here was removed with the rule
# itself on 2026-08-26: it was the reviewer's tightening of an approved UX, not
# the owner's decision, and it made the explicit both-sides form impossible to
# write. What replaces it is the f3 block at the foot of this file, which proves
# both sides ARE accepted and that they are checked pair by pair.
sc_refuses "scope: a doubled comma is a refusal, not a shorter list" \
    "empty entry" pve2 --target rpool/data/vm-101-disk-0,,rpool/data/vm-101-disk-1

# REV-20260827-122 F2. The doubled-comma case above passed on the reviewed SHA
# and hid the one next to it: the loop ran `while [ -n "$rest" ]`, so a list
# ending in a comma resolved its last real member, emptied the tail, and left
# BEFORE it could build the empty member the refusal was written for. The guard
# named the hole and the loop shape decided it was unreachable.
#
# ON b0a3a289b7bfd2a9e89b8de75c5d600e382f6c0d these accept a SHORTER list:
#   trailing-comma accepted=1 src=... copy=...
# while the doubled and leading cases refuse there too -- which is exactly why
# the existing coverage stayed green over it.
sc_refuses "scope: a TRAILING comma is a refusal, not a shorter list" \
    "empty entry" pve2 --target rpool/data/vm-101-disk-0,
sc_refuses "scope: ...on --source as well" \
    "empty entry" pve2 --source hdd/store,
sc_refuses "scope: a LEADING comma is a refusal" \
    "empty entry" pve2 --target ,rpool/data/vm-101-disk-0
sc_refuses "scope: ...on --source as well" \
    "empty entry" pve2 --source ,hdd/store
sc_refuses "scope: a list that is nothing but a comma is a refusal" \
    "empty entry" pve2 --target ,
# A trailing comma after a MULTI-member list is the shape an unfinished edit
# actually takes -- the operator wrote two disks and was about to write a third.
sc_refuses "scope: a trailing comma after two members is still a refusal" \
    "empty entry" pve2 --target rpool/data/vm-101-disk-0,rpool/data/vm-101-disk-1,

# ...and it refuses BEFORE anything is planned. Acceptance criterion 2: no plan
# output, so no confirmation, no fence, no snapshot, nothing downstream can have
# run. Checked on the output rather than assumed from the exit code.
out="$(sc_run pve2 --target rpool/data/vm-101-disk-0, 2>&1)"
n="$(printf '%s\n' "$out" | grep -c 'Zrodlo:')"
if [ "$n" = 0 ]; then ok "scope: a trailing comma refuses BEFORE any plan is shown"
else bad "scope: a trailing comma refuses BEFORE any plan is shown" "$n plan lines were printed"; fi

# THE OTHER DIRECTION OF THE SAME CHANGE. A scoped call with no --plan must not
# print a plan and stop: it must reach the per-dataset runner. Before 2026-08-27
# it planned and returned, and every assertion above passed either way -- which
# is exactly how a contract change slips through a suite that only pins one side
# of it.
#
# Asserted on the RUNNER's own output, not on an exit code: this fixture has no
# snapshots, so the run correctly gets as far as "nothing to restore from" and
# reports it per dataset. That is the runner speaking, and the planner never
# produces those lines.
mkdir -p "$SC/rel/pve2" && : > "$SC/rel/pve2/paused"
out="$(PATH="$WORK/bin:$PATH" RELATIONSHIPS_DIR="$SC/rel" bash "$ZB" pve2 --target rpool/data/vm-101-disk-0,rpool/data/vm-101-disk-1 --config="$SC/cfg" 2>&1)"
case "$out" in
    # EITHER of the runner's two reports proves the point, and the point is that
    # the planner was not what answered. Since the relation-level pre-flight (D,
    # owner 2026-08-30) this snapshot-less fixture refuses in the pre-flight
    # instead of reaching the per-dataset loop -- still the runner speaking, and
    # the planner produces neither string.
    *"per-dataset result"*|*"REFUSED before anything was touched"*)
        ok "scope: without --plan the scope RUNS, it does not plan" ;;
    *) bad "scope: without --plan the scope RUNS, it does not plan" \
           "expected the per-dataset runner's report" "got: $(printf '%s' "$out" | head -2)" ;;
esac
n="$(printf '%s\n' "$out" | grep -c 'Zrodlo:')"
if [ "$n" = 0 ]; then ok "scope: ...and prints no plan while doing it"
else bad "scope: ...and prints no plan while doing it" "$n plan lines were printed by a run"; fi

# THE PRECONDITION, BOTH WAYS ROUND. Owner decision 2026-08-27: a restore needs
# the target's grant AND the relationship's schedule stood down. The run above
# proves it proceeds when the pause is in place; this proves it refuses when it
# is not, and that it refuses BEFORE touching anything.
out="$(PATH="$WORK/bin:$PATH" RELATIONSHIPS_DIR="$SC/rel-none" bash "$ZB" pve2 --target rpool/data/vm-101-disk-0 --config="$SC/cfg" 2>&1)"
case "$out" in
    *"could NOT pause"*) ok "pause: a restore that cannot stand the schedule down refuses" ;;
    *) bad "pause: a restore that cannot stand the schedule down refuses" "got: $(printf '%s' "$out" | head -2)" ;;
esac
case "$out" in
    *"per-dataset result"*) bad "pause: ...and refuses BEFORE the runner touches a dataset" "the runner ran anyway" ;;
    *) ok "pause: ...and refuses BEFORE the runner touches a dataset" ;;
esac
case "$out" in
    *"pause-client pve2"*) ok "pause: ...and names the command that unblocks it" ;;
    *) bad "pause: ...and names the command that unblocks it" "got: $(printf '%s' "$out" | head -3)" ;;
esac

# ===========================================================================
# CROSS-HOST: recovering onto a DIFFERENT machine (owner grammar 2026-08-13,
# opened 2026-08-28)
#
#   restore A    B        every dataset of A onto B's machine, SAME paths
#   restore A:ds B:ds2    that dataset (and its subtree) onto B, under ds2
#
# B is a RELATION LABEL, never a hostname. That is what keeps this inside
# R-025: the destination is a machine this collector is already paired with,
# has already pinned, and can already ask for a grant -- there is no way to
# name a machine it has never met.
#
# The fixture's two relations are pve2 (two datasets) and pve1 (one), so
# "pve2 onto pve1's machine" is expressible without inventing anything.
# ===========================================================================

# The refusals first, because every one of them is a recovery that would
# otherwise land somewhere nobody wrote down.
xh() { PATH="$WORK/bin:$PATH" bash "$ZB" "$@" --config="$SC/cfg" 2>&1; }
xh_refuses() {   # <desc> <substring> <args...>
    local desc="$1" want="$2"; shift 2
    local out; out="$(xh "$@")"; local rc=$?
    if [ "$rc" -eq 0 ]; then bad "$desc" "expected a refusal, got rc=0"; return; fi
    case "$out" in *"$want"*) ok "$desc" ;; *) bad "$desc" "want: $want" "got: $(printf '%s' "$out" | head -2)" ;; esac
}

xh_refuses "xhost: a destination that is not a relation is refused, not read as a host" \
    "is not one this host records" pve2 nosuchrelation
xh_refuses "xhost: a transport address is refused as a destination" \
    "not a transport address" pve2 root@pve3
xh_refuses "xhost: --plan and a destination are refused together" \
    "The planner reads" pve2 pve1 --plan
# REPLACED, not deleted (owner decision 2026-08-30). This case used to assert
# that --target with a destination is REFUSED, and that refusal pointed the
# operator at `label:dataset` -- the spelling the owner had already retired,
# because ':' is legal inside a ZFS dataset name. So the one form an operator
# needs for "one disk of this VM, onto a different machine" was reachable only
# through the ambiguous spelling. The flags are the grammar in every form now;
# what stays refused is naming the datasets twice.
out="$(xh pve2 pve1 --target rpool/data/vm-101-disk-0)"
case "$out" in
    *"select datasets WITHIN one relationship"*)
        bad "xhost: --target WITH a destination is the grammar now, not a refusal" "$out" ;;
    *) ok "xhost: --target WITH a destination is the grammar now, not a refusal" ;;
esac
# THE PUBLIC-CLI PAIR FOR REV-20260831-128. The helper cases in onto.sh pin the
# arithmetic; these two pin the GRAMMAR, which is the thing an operator types.
# Two selected datasets and one --onto is a cardinality mistake -- the omitted
# second path -- and used to be silently reinterpreted as "rebase the whole
# relationship", building destinations nobody stated.
xh_refuses "xhost: two selected datasets and ONE --onto refuses at the CLI"     "same length" pve2 pve1 --target rpool/data/vm-101-disk-0,rpool/data/vm-101-disk-1 --onto hdd/x
# The other half: the identical single --onto with NO selection is the
# whole-relation form and must NOT hit that refusal.
out="$(xh pve2 pve1 --onto hdd/x)"
case "$out" in
    *"same length"*) bad "xhost: ...while the same one --onto with no selection is the whole-relation form" "$out" ;;
    *) ok "xhost: ...while the same one --onto with no selection is the whole-relation form" ;;
esac
xh_refuses "xhost: --onto without a destination is refused" \
    "no destination relationship was given" pve2 --onto hdd/data
xh_refuses "xhost: --onto and the retired colon spelling are refused together" \
    "--onto is the one that stays" pve2:rpool/data pve1:hdd/data --onto hdd/data
# The colon still WORKS for one release, and says so. Deprecating in silence is
# how two spellings stay alive; deleting outright breaks a spelling that is in
# this project's own documents and in the 2026-08-28 campaign transcript.
out="$(xh pve2:rpool/data pve1:rpool/data)"
case "$out" in
    *"retired spelling"*) ok "xhost: the colon spelling warns and names what replaces it" ;;
    *) bad "xhost: the colon spelling warns and names what replaces it" "$(printf '%s' "$out" | head -3)" ;;
esac
xh_refuses "xhost: --snapshot and a destination are refused together" \
    "resolved on the SOURCE relation's copy" pve2 pve1 --snapshot=x
xh_refuses "xhost: a half-specified pair is refused (source names a dataset, destination does not)" \
    "a half-specified pair" pve2:rpool/data/vm-101-disk-0 pve1
xh_refuses "xhost: ...and the other way round" \
    "Either name both sides" pve2 pve1:rpool/other
xh_refuses "xhost: three addresses are refused" \
    "one relation to read, at most one to write" pve2 pve1 pve0

# THE MAPPING. Asserted on the runner's per-dataset report, which names the
# DESTINATION -- the machine being written to -- rather than the recorded
# source. The fixture has no snapshots, so each dataset gets as far as "no
# snapshot to restore from"; that is the runner speaking, and it prints the
# address the recovery was aimed at, which is the thing under test.
#
# The pause is satisfied with a REAL marker for the destination relation,
# because the destination is the machine at risk and its schedule is the one
# that has to stand down.
mkdir -p "$SC/rel/pve1" && : > "$SC/rel/pve1/paused"
out="$(PATH="$WORK/bin:$PATH" RELATIONSHIPS_DIR="$SC/rel" bash "$ZB" pve2 pve1 --config="$SC/cfg" 2>&1)"
case "$out" in
    *"root@pve1:rpool/data/vm-101-disk-0"*) ok "xhost: a bare pair keeps the SOURCE path on the destination machine" ;;
    *) bad "xhost: a bare pair keeps the SOURCE path on the destination machine" "got: $(printf '%s' "$out" | grep -E 'OK|NOT DONE' | head -2)" ;;
esac
case "$out" in
    *"root@pve1:rpool/data/vm-101-disk-1"*) ok "xhost: ...for every dataset of the relation, not just the first" ;;
    *) bad "xhost: ...for every dataset of the relation, not just the first" "got: $(printf '%s' "$out" | grep -E 'OK|NOT DONE' | head -2)" ;;
esac
# ...and it must not have aimed at the ORIGINAL machine, which is the failure
# this whole form exists to avoid: a cross-host recovery that quietly went home.
case "$out" in
    *"root@pve2:rpool/data"*) bad "xhost: ...and nothing was aimed at the source machine" "pve2 appears as a destination" ;;
    *) ok "xhost: ...and nothing was aimed at the source machine" ;;
esac

out="$(PATH="$WORK/bin:$PATH" RELATIONSHIPS_DIR="$SC/rel" bash "$ZB" pve2:rpool/data/vm-101-disk-0 pve1:rpool/elsewhere --config="$SC/cfg" 2>&1)"
case "$out" in
    *"root@pve1:rpool/elsewhere"*) ok "xhost: a named pair lands on the named destination path" ;;
    *) bad "xhost: a named pair lands on the named destination path" "got: $(printf '%s' "$out" | grep -E 'OK|NOT DONE' | head -2)" ;;
esac
case "$out" in
    *"vm-101-disk-1"*) bad "xhost: ...and only the dataset that was named" "the sibling came along" ;;
    *) ok "xhost: ...and only the dataset that was named" ;;
esac

# THE HAND-OVER SENTENCE. A cross-host recovery leaves the data on one machine
# and the backup pointing at another, and that split is silent -- the old
# relationship keeps running and looks healthy. Owner decision 2026-08-28: the
# run says so and names the next step; it does not compose the hand-over into
# itself.
# DRIVEN DIRECTLY, and the reason is a contract change rather than convenience.
# These two used to read the fixture run above, which reached the report because
# a copy with no snapshots still got as far as the per-dataset loop. Since the
# relation-level pre-flight (D, owner 2026-08-30) that fixture refuses before the
# loop -- correctly, because a run that touched nothing has no hand-over to
# announce. Rather than make the refusal print a sentence that would be false,
# the report is exercised on its own state, which is what these two ever tested.
ho="$(
    log() { shift; printf '%s
' "$*"; }
    RESTORE_SOURCE_LABEL=pve2
    RESTORE_RELATION_LABEL=pve1
    RESTORE_SCOPE_SRC=("rpool/data/vm-101-disk-0")
    RESTORE_SCOPE_DEST=("root@pve1:rpool/elsewhere")
    # WHAT LANDED, because the first sentence now follows it. The runner appends
    # here only for a dataset it verified, so an empty list means nothing reached
    # that machine -- see the nothing-landed case below.
    RESTORE_LANDED=("root@pve1:rpool/elsewhere")
    eval "$(awk 'index($0, "restore_report_handover() {")==1 {f=1} f{print} f&&/^[}]$/{exit}' "$ZB")"
    restore_report_handover
)"
case "$ho" in
    *"went to a DIFFERENT machine"*) ok "xhost: the run says the recovery went elsewhere" ;;
    *) bad "xhost: the run says the recovery went elsewhere" "got: $ho" ;;
esac
case "$ho" in
    *"move-to-client pve2 pve1"*) ok "xhost: ...and names the step that switches the backup over" ;;
    *) bad "xhost: ...and names the step that switches the backup over" "got: $ho" ;;
esac
# The control that keeps those two honest: same report, destination on the SAME
# machine, must say nothing at all.
ho_same="$(
    log() { shift; printf '%s
' "$*"; }
    RESTORE_SOURCE_LABEL=pve2
    RESTORE_RELATION_LABEL=pve2
    RESTORE_SCOPE_SRC=("rpool/data/vm-101-disk-0")
    RESTORE_SCOPE_DEST=("rpool/data/vm-101-disk-0")
    RESTORE_LANDED=("rpool/data/vm-101-disk-0")
    eval "$(awk 'index($0, "restore_report_handover() {")==1 {f=1} f{print} f&&/^[}]$/{exit}' "$ZB")"
    restore_report_handover
)"
if [ -z "$ho_same" ]; then ok "xhost: ...and says nothing when the destination is the same machine"
else bad "xhost: ...and says nothing when the destination is the same machine" "$ho_same"; fi

# ---- NOTHING LANDED: the block still prints, the first sentence changes -------
# It is printed on failed runs on purpose -- a partial recovery leaves the same
# split. What it must not do is OPEN with "the data is there". Measured on the
# lab, 2026-08-31: a run that recovered nothing announced the data was on the
# other machine and named the command to hand the backup over to it. Following
# that points the schedule at a machine holding nothing.
ho_none="$(
    log() { shift; printf '%s
' "$*"; }
    RESTORE_SOURCE_LABEL=pve2
    RESTORE_RELATION_LABEL=pve1
    RESTORE_SCOPE_SRC=("rpool/data/vm-101-disk-0")
    RESTORE_SCOPE_DEST=("root@pve1:rpool/elsewhere")
    RESTORE_LANDED=()
    eval "$(awk 'index($0, "restore_report_handover() {")==1 {f=1} f{print} f&&/^[}]$/{exit}' "$ZB")"
    restore_report_handover
)"
case "$ho_none" in
    *"the data is there"*) bad "xhost: A RUN THAT LANDED NOTHING MUST NOT SAY THE DATA IS THERE" "$ho_none" ;;
    *) ok "xhost: A RUN THAT LANDED NOTHING MUST NOT SAY THE DATA IS THERE" ;;
esac
case "$ho_none" in
    *"NOTHING landed"*) ok "xhost: ...it says nothing landed, and why that matters" ;;
    *) bad "xhost: ...it says nothing landed, and why that matters" "$ho_none" ;;
esac
case "$ho_none" in
    *"went to a DIFFERENT machine"*) ok "xhost: ...while still naming the split, which is why the block exists" ;;
    *) bad "xhost: ...while still naming the split, which is why the block exists" "$ho_none" ;;
esac
# And the claim its own caller falsifies one line later.
case "$ho$ho_none" in
    *"stays paused"*) bad "xhost: ...and never claims the relationship stays paused, which the next line undoes" "$ho$ho_none" ;;
    *) ok "xhost: ...and never claims the relationship stays paused, which the next line undoes" ;;
esac
# NEGATIVE CONTROL, and it is the one that makes the two above mean something: a
# recovery back onto the relation's own machine has no hand-over to do and must
# not say it does.
out="$(PATH="$WORK/bin:$PATH" RELATIONSHIPS_DIR="$SC/rel2" bash "$ZB" pve2 --config="$SC/cfg" 2>&1)"
mkdir -p "$SC/rel2/pve2" && : > "$SC/rel2/pve2/paused"
out="$(PATH="$WORK/bin:$PATH" RELATIONSHIPS_DIR="$SC/rel2" bash "$ZB" pve2 --config="$SC/cfg" 2>&1)"
case "$out" in
    *"went to a DIFFERENT machine"*) bad "xhost control: a same-machine recovery says nothing about a hand-over" "it did" ;;
    *) ok "xhost control: a same-machine recovery says nothing about a hand-over" ;;
esac


# POSITIVE CONTROL, and it is what makes the six refusals above mean something:
# a well-formed list of the same length still resolves completely, in the order
# written. Without this, a parser that refused every list would pass all of them.
out="$(sc_run pve2 --target rpool/data/vm-101-disk-0,rpool/data/vm-101-disk-1)"
n="$(printf '%s\n' "$out" | grep -c 'Zrodlo:')"
if [ "$n" = 2 ]; then ok "scope control: the same list WITHOUT the trailing comma still resolves both"
else bad "scope control: the same list without the trailing comma resolves both" "expected 2, got $n"; fi
first="$(printf '%s\n' "$out" | grep 'Zrodlo:' | head -1)"
case "$first" in
    *vm-101-disk-0*) ok "scope control: ...and in the order written" ;;
    *) bad "scope control: ...and in the order written" "$first" ;;
esac

sc_refuses "scope: the same dataset twice is a refusal" \
    "appears twice" pve2 --target rpool/data/vm-101-disk-0,rpool/data/vm-101-disk-0
# sc5/sc6 -- the discriminating pair. Each name is legal in the OTHER namespace,
# so an implementation that matched either side would accept both.
sc_refuses "scope: a collector-side name is refused by --target" \
    "if you meant where the copy lives, that is --source" pve2 --target hdd/store
sc_refuses "scope: a host-side name is refused by --source" \
    "if you meant the name on the machine being restored, that is --target" pve2 --source rpool/data/vm-101-disk-0
sc_refuses "scope: a dataset of ANOTHER relationship is refused" \
    "is not a dataset of relation 'pve2'" pve2 --target rpool/data/x
sc_refuses "scope: the relationship has to be named too" \
    "select datasets WITHIN a relationship" --target rpool/data/vm-101-disk-0
sc_refuses "scope: label:dataset AND a flag is two ways of saying scope" \
    "already names a dataset" pve2:rpool/data/vm-101-disk-0 --target rpool/data/vm-101-disk-1
sc_refuses "scope: a flag whose value is the next flag is refused" \
    "needs a value" pve2 --target --plan
# The space form is what both recorded contracts spell, so it is not optional.
sc_ok "scope: --target takes its value as the next word" \
    "rpool/data/vm-101-disk-0" pve2 --target rpool/data/vm-101-disk-0

# ============================================================================
# --at -- a recovery point in wall-clock time, resolved PER DATASET
#
# Reviewer rule 4, 2026-08-26. Three properties, each with its own case, and the
# fixture is built from the SAME `date -d` the code uses so the test cannot pass
# by agreeing with itself about what "2026-08-10 12:00" means.
#
# The case that carries the block is `at1`: the wanted snapshot is neither the
# newest nor the oldest. An implementation that took the newest, or the last
# line, or the lexically greatest name passes nothing here.
# ============================================================================
AT="$WORK/at"; mkdir -p "$AT/bin"
AT_E="$(date -d '2026-08-10 12:00' +%s)"
cat > "$AT/cfg" <<'ATCFG'
[defaults]
	host_label = coll
[template:h]
	send_schedule = 0 * * * *
	prefix        = a_
[dataset:hdd/store]
	use_template = h
	src          = root@pve2:rpool/data/vm-101-disk-0
	pair_label   = pve2
[dataset:hdd/store2]
	use_template = h
	src          = root@pve2:rpool/data/vm-101-disk-1
	pair_label   = pve2
[dataset:hdd/tie]
	use_template = h
	src          = root@pve2:rpool/data/vm-101-disk-2
	pair_label   = pve2
ATCFG
# hdd/store  : one BEFORE, one just before (the answer), one AFTER
# hdd/store2 : nothing at or before the moment
# hdd/tie    : two sharing the greatest creation at or before it
cat > "$AT/bin/zfs" <<ATSTUB
#!/bin/bash
E=$AT_E
for a in "\$@"; do ds="\$a"; done
case "\$*" in
  *"-t snapshot"*)
    case "\$ds" in
      hdd/store)  printf '%s@old\t%s\tG1\n'    "\$ds" "\$((E-86400))"
                  printf '%s@WANTED\t%s\tG2\n' "\$ds" "\$((E-3600))"
                  printf '%s@toonew\t%s\tG3\n' "\$ds" "\$((E+86400))" ;;
      hdd/store2) printf '%s@onlynew\t%s\tG9\n' "\$ds" "\$((E+3600))" ;;
      hdd/tie)    printf '%s@twinA\t%s\tGA\n'  "\$ds" "\$((E-3600))"
                  printf '%s@twinB\t%s\tGB\n'  "\$ds" "\$((E-3600))" ;;
    esac ;;
esac
exit 0
ATSTUB
chmod +x "$AT/bin/zfs"

at_out="$(PATH="$AT/bin:$PATH" bash "$ZB" pve2 --at '2026-08-10 12:00' --plan --config="$AT/cfg" 2>&1)"
at_rc=$?

# at1 -- neither the newest nor the oldest.
case "$at_out" in
    *"WYBRANO WANTED"*) ok "at: picks the greatest creation AT OR BEFORE the moment" ;;
    *) bad "at: picks the greatest creation AT OR BEFORE the moment" "$(printf '%s' "$at_out" | grep -E 'WYBRANO|PUNKT' | head -3)" ;;
esac
case "$at_out" in
    *"WYBRANO toonew"*) bad "at: ...and never a snapshot from AFTER it" "picked toonew" ;;
    *) ok "at: ...and never a snapshot from AFTER it" ;;
esac
# The guid and the real creation travel with the choice: the operator has to be
# able to check what they were given without trusting the name.
case "$at_out" in
    *"guid=G2"*) ok "at: ...and reports the chosen snapshot's guid and real creation" ;;
    *) bad "at: ...and reports the chosen snapshot's guid and real creation" "$(printf '%s' "$at_out" | grep creation= | head -2)" ;;
esac
# The heading, because four disks of one VM is exactly where somebody assumes
# they were handed one instant.
case "$at_out" in
    *"PER-DATASET FRONTIER"*) ok "at: says PER-DATASET FRONTIER in a heading, not a footnote" ;;
    *) bad "at: says PER-DATASET FRONTIER in a heading, not a footnote" ;;
esac
# A dataset with nothing old enough is that dataset's error, and the run goes on.
case "$at_out" in
    *"BRAK -- ten dataset nie ma snapshotu"*) ok "at: a dataset with nothing old enough is named" ;;
    *) bad "at: a dataset with nothing old enough is named" ;;
esac
case "$at_out" in
    *"WYBRANO WANTED"*) ok "at: ...and the OTHER datasets are still planned" ;;
    *) bad "at: ...and the OTHER datasets are still planned" ;;
esac
# A tie is fail-closed: the name is not a tie-breaker.
case "$at_out" in
    *"NIEJEDNOZNACZNE"*) ok "at: a tie on the greatest creation refuses to choose" ;;
    *) bad "at: a tie on the greatest creation refuses to choose" ;;
esac
case "$at_out" in
    *"WYBRANO twinA"*|*"WYBRANO twinB"*) bad "at: ...and does NOT break the tie by name" "picked one of the twins" ;;
    *) ok "at: ...and does NOT break the tie by name" ;;
esac
# Owner decision 7: incomplete is not clean. The exit status is the only part of
# this a cron job reads.
if [ "$at_rc" -ne 0 ]; then ok "at: an incomplete plan exits non-zero"
else bad "at: an incomplete plan exits non-zero" "rc=0"; fi

# The positive control for that status: when every dataset resolves, rc is 0 --
# otherwise the assertion above would pass against a plan that always failed.
at_ok_out="$(PATH="$AT/bin:$PATH" bash "$ZB" pve2 --target rpool/data/vm-101-disk-0 --at '2026-08-10 12:00' --plan --config="$AT/cfg" 2>&1)"
at_ok_rc=$?
if [ "$at_ok_rc" -eq 0 ]; then ok "at: a plan that resolves everything exits 0"
else bad "at: a plan that resolves everything exits 0" "rc=$at_ok_rc" "$(printf '%s' "$at_ok_out" | tail -3)"; fi

# A time nobody can parse is a refusal, not a silent "now".
at_bad="$(PATH="$AT/bin:$PATH" bash "$ZB" pve2 --at 'wczoraj o poludniu' --config="$AT/cfg" 2>&1)"
case "$at_bad" in
    *"is not a time this system can read"*) ok "at: an unparseable time is refused" ;;
    *) bad "at: an unparseable time is refused" "$(printf '%s' "$at_bad" | head -2)" ;;
esac
# Two ways of naming a recovery point is one too many.
at_both="$(PATH="$AT/bin:$PATH" bash "$ZB" pve2 --at '2026-08-10 12:00' --snapshot=x --config="$AT/cfg" 2>&1)"
case "$at_both" in
    *"both name a recovery point"*) ok "at: --at and --snapshot together are refused" ;;
    *) bad "at: --at and --snapshot together are refused" "$(printf '%s' "$at_both" | head -2)" ;;
esac

# ============================================================================
# REVIEW 2026-08-26 on a22f08a4 -- F1, F2, F3.
# ============================================================================

# --- F1: assert the RESOLVED VALUES, not the number of rows -----------------
# The reported defect was not there -- the file carries a real TAB and the split
# was measured correct -- but the criticism of the test stands: counting
# `Zrodlo:` lines cannot tell a correct pair from a mangled one, and a mangled
# pair is exactly what a `\t`-that-is-really-`t` would produce.
f1_out="$(PATH="$AT/bin:$PATH" bash "$ZB" pve2 --target rpool/data/vm-101-disk-0 --plan --config="$SC/cfg" 2>&1)"
case "$f1_out" in
    *"root@pve2:rpool/data/vm-101-disk-0"*) ok "f1: the ORIGINAL side resolves to its exact recorded value" ;;
    *) bad "f1: the ORIGINAL side resolves to its exact recorded value" "$(printf '%s' "$f1_out" | grep Zrodlo | head -2)" ;;
esac
case "$f1_out" in
    *"hdd/store"*) ok "f1: the COPY side resolves to its exact recorded value" ;;
    *) bad "f1: the COPY side resolves to its exact recorded value" "$(printf '%s' "$f1_out" | grep -i kopia | head -2)" ;;
esac
# The shape a broken tab-split would produce, named so the assertion cannot pass
# by accident on a truncated value.
# Anchored to the END of the line. The first cut looked for "Zrodlo:     roo"
# as a SUBSTRING -- which the correct value `root@pve2:...` also contains, so it
# failed against working code. That is the other way a test can be wrong.
if printf '%s
' "$f1_out" | grep -qE '^[[:space:]]*(Zrodlo|Kopia):[[:space:]]+(roo|ore)[[:space:]]*$'; then
    bad "f1: and is not truncated at the letter t" "found a value cut down to roo or ore"
else
    ok "f1: and is not truncated at the letter t"
fi

# --- F2: the strategy classifies the point --at CHOSE -----------------------
# A LOCAL (push) relationship, because the strategy short-circuits on a remote
# source and would prove nothing.
F2="$WORK/f2"; mkdir -p "$F2/bin"
F2_E="$(date -d '2026-08-10 12:00' +%s)"
cat > "$F2/cfg" <<'F2CFG'
[defaults]
	host_label = coll
[template:h]
	send_schedule = 0 * * * *
	prefix        = a_
[dataset:rpool/data/x]
	use_template = h
	dst          = hdd/backup
	pair_label   = loc
F2CFG
cat > "$F2/bin/zfs" <<F2STUB
#!/bin/bash
E=$F2_E
for a in "\$@"; do ds="\$a"; done
case "\$*" in
  *"-t snapshot"*)
      printf '%s@WANTED\t%s\tG2\n' "\$ds" "\$((E-3600))"
      printf '%s@toonew\t%s\tG3\n' "\$ds" "\$((E+86400))" ;;
  *) exit 1 ;;
esac
exit 0
F2STUB
chmod +x "$F2/bin/zfs"

f2_out="$(PATH="$F2/bin:$PATH" bash "$ZB" loc --at '2026-08-10 12:00' --plan --config="$F2/cfg" 2>&1)"
# The block under "Punkt docelowy" is what the confirmation would be about.
f2_point="$(printf '%s\n' "$f2_out" | sed -n '/Punkt docelowy/,+1p' | tail -1)"
case "$f2_point" in
    *WANTED*guid=G2*) ok "f2: the strategy classifies the point --at chose" ;;
    *) bad "f2: the strategy classifies the point --at chose" "got: $f2_point" ;;
esac
case "$f2_point" in
    *toonew*) bad "f2: ...and never the newest one, which is AFTER the moment" "got: $f2_point" ;;
    *) ok "f2: ...and never the newest one, which is AFTER the moment" ;;
esac
# The caption over it stated a POLICY. Under --at that policy is not in force,
# and a right answer under a wrong caption is still an untrue preview.
case "$f2_out" in
    *"domyslna polityka: NAJNOWSZY"*) bad "f2: the caption does not still claim the default-newest policy" ;;
    *) ok "f2: the caption does not still claim the default-newest policy" ;;
esac
# NEGATIVE CONTROL: without --at the default policy is in force and says so, and
# the newest IS the point -- otherwise the two assertions above would pass
# against a build that had simply stopped classifying anything.
f2_plain="$(PATH="$F2/bin:$PATH" bash "$ZB" loc --plan --config="$F2/cfg" 2>&1)"
f2_ppoint="$(printf '%s\n' "$f2_plain" | sed -n '/Punkt docelowy/,+1p' | tail -1)"
case "$f2_ppoint" in
    *toonew*) ok "f2: without --at the newest is still the point" ;;
    *) bad "f2: without --at the newest is still the point" "got: $f2_ppoint" ;;
esac
case "$f2_plain" in
    *"domyslna polityka: NAJNOWSZY"*) ok "f2: ...and the default caption is still shown" ;;
    *) bad "f2: ...and the default caption is still shown" ;;
esac
# When --at resolved nothing for a dataset, no strategy is computed at all.
f2_none="$(PATH="$AT/bin:$PATH" bash "$ZB" pve2 --target rpool/data/vm-101-disk-1 --at '2026-08-10 12:00' --plan --config="$AT/cfg" 2>&1)"
case "$f2_none" in
    *"Strategia:  (POMINIETA"*) ok "f2: a dataset --at could not resolve gets NO strategy" ;;
    *) bad "f2: a dataset --at could not resolve gets NO strategy" "$(printf '%s' "$f2_none" | grep Strategia | head -2)" ;;
esac

# --- F3: both sides may be stated, and then they are PAIRED -----------------
# The mutual exclusion was the reviewer's tightening of an approved UX and was
# withdrawn. All three forms work; stating both is not remapping.
f3_both="$(PATH="$AT/bin:$PATH" bash "$ZB" pve2 --source hdd/store,hdd/store2 --target rpool/data/vm-101-disk-0,rpool/data/vm-101-disk-1 --plan --config="$SC/cfg" 2>&1)"
f3_n="$(printf '%s\n' "$f3_both" | grep -c 'Zrodlo:')"
if [ "$f3_n" = 2 ]; then ok "f3: both sides stated explicitly is accepted"
else bad "f3: both sides stated explicitly is accepted" "expected 2 datasets, got $f3_n" "$(printf '%s' "$f3_both" | head -3)"; fi

f3_swap="$(PATH="$AT/bin:$PATH" bash "$ZB" pve2 --source hdd/store,hdd/store2 --target rpool/data/vm-101-disk-1,rpool/data/vm-101-disk-0 --config="$SC/cfg" 2>&1)"
case "$f3_swap" in
    *"pair 1 does not match the recorded relationship"*) ok "f3: a crossed pair is refused, not silently sorted out" ;;
    *) bad "f3: a crossed pair is refused, not silently sorted out" "$(printf '%s' "$f3_swap" | head -2)" ;;
esac
f3_len="$(PATH="$AT/bin:$PATH" bash "$ZB" pve2 --source hdd/store --target rpool/data/vm-101-disk-0,rpool/data/vm-101-disk-1 --config="$SC/cfg" 2>&1)"
case "$f3_len" in
    *"read as PAIRS, in order, so the two lists have to be the same length"*) ok "f3: lists of different lengths are refused" ;;
    *) bad "f3: lists of different lengths are refused" "$(printf '%s' "$f3_len" | head -2)" ;;
esac
# And the single-sided forms still work, both ways round.
f3_s="$(PATH="$AT/bin:$PATH" bash "$ZB" pve2 --source hdd/store --plan --config="$SC/cfg" 2>&1)"
case "$f3_s" in *"vm-101-disk-0"*) ok "f3: --source alone still works" ;; *) bad "f3: --source alone still works" ;; esac
f3_t="$(PATH="$AT/bin:$PATH" bash "$ZB" pve2 --target rpool/data/vm-101-disk-0 --plan --config="$SC/cfg" 2>&1)"
case "$f3_t" in *"vm-101-disk-0"*) ok "f3: --target alone still works" ;; *) bad "f3: --target alone still works" ;; esac

# ============================================================================
# --at must not cost the COMMON BASE (review follow-up, 2026-08-26)
#
# The first fix for F2 handed restore_plan_strategy a single row -- the one --at
# chose. That got the target right and destroyed every base candidate, because
# the SAME listing is walked a second time to find the newest snapshot whose GUID
# also exists on the source. A dataset with a perfectly good older common base
# was then classified "FULL on a live source -- no common base", which is the
# opposite of the truth and, for a destructive verb, the dangerous direction.
#
# The discriminator the reviewer specified, verbatim: the source carries G1, the
# copy has G1/G2/G3, --at picks G2, and the preview must show target G2 AND
# common base G1 -- never FULL/no-base.
# ============================================================================
BB="$WORK/base"; mkdir -p "$BB/bin"
BB_E="$(date -d '2026-08-10 12:00' +%s)"
cat > "$BB/cfg" <<'BBCFG'
[defaults]
	host_label = coll
[template:h]
	send_schedule = 0 * * * *
	prefix        = a_
[dataset:rpool/data/x]
	use_template = h
	dst          = hdd/backup
	pair_label   = loc
BBCFG
# The source EXISTS and carries only G1. Every query the strategy makes is
# answered in the shape it actually asks for -- an earlier draft of this stub
# answered the `name,createtxg` query with three fields, and the run then
# reported the base snapshot itself as a blocker. A stub that answers a
# different question is a test that proves a different thing.
cat > "$BB/bin/zfs" <<BBSTUB
#!/bin/bash
E=$BB_E
args="\$*"
case "\$args" in
  "list -H -o name rpool/data/x")                exit 0 ;;
  *"-o guid -d 1 rpool/data/x")                  echo G1; exit 0 ;;
  *"-o name,guid,createtxg -d 1 rpool/data/x")   printf 'rpool/data/x@old\tG1\t100\n'; exit 0 ;;
  *"-o name,createtxg -d 1 rpool/data/x")        printf 'rpool/data/x@old\t100\n'; exit 0 ;;
  *"-t bookmark"*)                               exit 0 ;;
  *"-o name,creation,guid"*"hdd/backup/rpool/data/x")
      printf 'hdd/backup/rpool/data/x@old\t%s\tG1\n'    "\$((E-7200))"
      printf 'hdd/backup/rpool/data/x@WANTED\t%s\tG2\n' "\$((E-3600))"
      printf 'hdd/backup/rpool/data/x@toonew\t%s\tG3\n' "\$((E+86400))"
      exit 0 ;;
  *"written"*)                                   echo 0; exit 0 ;;
esac
exit 1
BBSTUB
chmod +x "$BB/bin/zfs"

bb_out="$(PATH="$BB/bin:$PATH" bash "$ZB" loc --at '2026-08-10 12:00' --plan --config="$BB/cfg" 2>&1)"
bb_point="$(printf '%s\n' "$bb_out" | sed -n '/Punkt docelowy/,+1p' | tail -1)"
case "$bb_point" in
    *WANTED*guid=G2*) ok "base: --at still selects the target it chose" ;;
    *) bad "base: --at still selects the target it chose" "got: $bb_point" ;;
esac
bb_base="$(printf '%s\n' "$bb_out" | sed -n '/Wspolna baza/,+1p' | tail -1)"
case "$bb_base" in
    *guid=G1*) ok "base: the OLDER common base survives --at" ;;
    *) bad "base: the OLDER common base survives --at" "got: $bb_base" ;;
esac
case "$bb_out" in
    *"Wspolnej bazy NIE MA"*) bad "base: and is never reported as FULL/no-base" ;;
    *) ok "base: and is never reported as FULL/no-base" ;;
esac
case "$bb_out" in
    *"INKREMENT"*) ok "base: so the classification is INKREMENT, not a full replacement" ;;
    *) bad "base: so the classification is INKREMENT, not a full replacement" "$(printf '%s' "$bb_out" | grep Strategia | head -1)" ;;
esac
# A snapshot from AFTER the moment must not become the base either -- the filter
# is "at or before", and it applies to both uses of the listing.
case "$bb_base" in
    *guid=G3*|*toonew*) bad "base: a snapshot from after the moment is not a base" "got: $bb_base" ;;
    *) ok "base: a snapshot from after the moment is not a base" ;;
esac
# NEGATIVE CONTROL for the whole block: without --at the newest IS the target and
# the base is still found, so these assertions are about --at and not about the
# strategy having stopped working.
bb_plain="$(PATH="$BB/bin:$PATH" bash "$ZB" loc --plan --config="$BB/cfg" 2>&1)"
bb_ppoint="$(printf '%s\n' "$bb_plain" | sed -n '/Punkt docelowy/,+1p' | tail -1)"
case "$bb_ppoint" in
    *toonew*guid=G3*) ok "base: without --at the newest is the target, as before" ;;
    *) bad "base: without --at the newest is the target, as before" "got: $bb_ppoint" ;;
esac


# The relation-level failure policy (D + B) lives in its own file so a negative
# control can run those cases alone against a mutated tree, in seconds. See its
# header. Sourced, so its cases count in this suite's totals exactly as before.
# What an unreadable relationship record is called, and what an incomplete one
# is called -- separate file for the same reason as relpolicy.sh, its header
# says which.
. "$DIR/records.sh"

# `--onto`: the rebase arithmetic behind a cross-host recovery. Its own file for
# the same reason as the two above.
. "$DIR/onto.sh"

# `--from-copy`: the address that needs no relationship record, for when those
# records are the thing that was lost.
. "$DIR/fromcopy.sh"

# The three-state contract of the recovery-point probe. The classification it
# feeds is deliberately NOT asserted in any suite -- see this file's header.
. "$DIR/hasguid.sh"

# The check that CLOSES a run: did the target land on the recovery point. Asked
# as identity, after a lab campaign caught it asking as accounting.
. "$DIR/offpoint.sh"

# The probe that decides whether a rollback runs at all. Union of "bytes written"
# and "snapshots newer", after a lab --at run found the second half missing.
. "$DIR/ahead.sh"

# A failed `create` destroyed nothing if nothing is there -- demoted on proof
# only, after a lab run reported an untouched machine as needing a person.
. "$DIR/createfail.sh"

. "$DIR/relpolicy.sh"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
