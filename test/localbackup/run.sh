#!/bin/bash
# Tests for zfs-backup.sh local-backup -- the Phase 5 high-level LOCAL backup
# PLANNING command (read-only; stops before install). Pure/text apart from a
# stubbed `zfs`/`crontab` on PATH -- no real ZFS, no network, no crontab write.
#
#   ./test/localbackup/run.sh
#
# Pins, after REV-20260810-097:
#   F1  an explicit source must EXIST (stubbed `zfs list`); a missing source
#       hard-refuses the whole operation, no fallback, no partial plan.
#   F2  the candidate is composed ADDITIVELY over the installed target CONFIG:
#       an existing unrelated job A is byte-preserved and the rendered cron
#       carries A + the new B; an overlap with existing coverage refuses; a
#       MISSING config claimed by an installed crontab block refuses (shared
#       fail-closed guard), while a genuinely unclaimed missing config gets a
#       fresh candidate.
#   F3  the canonical public entrypoint is the bare `--source/--target` form,
#       reaching the same planning logic as the `local-backup` alias.
#   plus the already-accepted slice-1 properties (overlap self-ref, LOCAL-only,
#   same-pool factual note, profile defaulting/validation, installs nothing).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
ZB="${ZB:-$REPO/zfs-backup.sh}"
[ -r "$ZB" ] || { echo "cannot find zfs-backup.sh at $ZB" >&2; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# The transactional install below runs the REAL gen-cron.sh --install, which
# refuses unless the shared lock directory exists and is writable -- a path
# deploy.sh provisions on a real host (2775 root:zfsalert). Nothing here creates
# it, so slice 2 failed on any machine that had not been deployed to: measured on
# a CI runner and on the developer box alike, while deps.conf still declared this
# suite `needs = nothing`.
#
# CRON_LOCK_DIR is the override lib-cron.sh already honours, so pointing it into
# the fixture makes the claim true instead of relaxing the guard: the install
# still takes a real lock, in a directory this suite owns and cleans up.
export CRON_LOCK_DIR="$WORK/locks"; mkdir -p "$CRON_LOCK_DIR"
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

mkdir -p "$WORK/bin"
# zfs stub: only these datasets "exist"; the dataset is the LAST argument of
# `zfs list -H -o name -- <ds>`.
cat > "$WORK/bin/zfs" <<'EOF'
#!/bin/sh
for a in "$@"; do ds="$a"; done
case "$ds" in rpool/data|rpool/existing|rpool/other|rpool/db|rpool/vmstore|hdd/dokumenty|rpool/a|rpool/a/child) exit 0 ;;
             *) echo "cannot open '$ds': dataset does not exist" >&2; exit 1 ;; esac
EOF
# crontab stub: `-l` returns a managed block claiming $WORK/claimed.conf (only
# that path is "claimed by an installed block"); any WRITE call is recorded so
# the no-install property is checkable.
cat > "$WORK/bin/crontab" <<EOF
#!/bin/sh
case " \$* " in
  *" -l "*) printf '# BEGIN zfs-backup-managed\n# Source: %s/claimed.conf -- do not edit\n1 * * * * /bin/true\n# END zfs-backup-managed\n' "$WORK" ;;
  *) echo "WRITE \$*" >> "$WORK/crontab-writes"; echo INSTALL >> "$WORK/order" ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/zfs" "$WORK/bin/crontab"

# shellcheck disable=SC1090
source "$ZB"

run() {   # cmd_local_backup args... ; stubbed PATH, no server.conf, real profiles
    ( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" \
      cmd_local_backup "$@" ) 2>&1
}

# ---- accepted: overlap self-reference refuses, all three directions ----
for pair in "rpool/data|rpool/data/backups|target-under-source" \
            "rpool/data|rpool/data|equal"; do
    IFS='|' read -r s t label <<<"$pair"
    out="$(run --source="$s" --target="$t")"; rc=$?
    { [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'overlaps'; } \
        && ok "selfref/$label refuses" || bad "selfref/$label refuses" "rc=$rc"
done

# ---- accepted: LOCAL only, missing args, unknown profile ----
out="$(run --source="remotehost:rpool/data" --target=hdd/backups)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'LOCAL only'; } \
    && ok "local-only/remote refused" || bad "local-only/remote refused" "rc=$rc"
# capture-then-grep: this suite runs under pipefail, so `run | grep -q` would
# report SIGPIPE (run killed when grep short-circuits) as a pipeline failure.
out="$(run --target=hdd/backups)"; printf '%s' "$out" | grep -q -- '--source' \
    && ok "args/missing-source" || bad "args/missing-source" ""
out="$(run --source=rpool/data)"; printf '%s' "$out" | grep -q -- '--target' \
    && ok "args/missing-target" || bad "args/missing-target" ""

# ---- F1: source existence ----
out="$(run --source=rpool/dtaa --target=hdd/backups)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'does not exist'; } \
    && ok "F1/missing-source hard-refuses" || bad "F1/missing-source hard-refuses" "rc=$rc out=$(printf '%s' "$out"|tail -1)"
out="$(run --source=rpool/data --target=hdd/backups --config="$WORK/f1.conf")"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/data\]'; } \
    && ok "F1/existing-source proceeds" || bad "F1/existing-source proceeds" "rc=$rc"
# negative control: the existence gate is load-bearing -- the ONLY difference
# between the two runs above is the zfs stub's verdict on the same code path.
out="$(run --source=rpool/db --target=hdd/backups --profile=default --config="$WORK/f1b.conf")"; rc=$?
[ "$rc" -eq 0 ] && ok "F1/another existing source also proceeds (gate keys on zfs, not the name)" \
    || bad "F1/another existing source also proceeds" "rc=$rc"

# ---- REV-20260811-101: multi-source WHAT set semantics ----
# Canonical comma-list: two independent [dataset:] entries, and the rendered
# cron really sends BOTH roots to the target.
#
# REWRITTEN for KROK 5, not deleted. This used to additionally require the two
# sends to appear as ONE comma-joined line, because same-policy datasets merged.
# Each local source now gets its own minute, so they render as two lines -- and
# that is the point rather than a side effect: while they merged, adding a
# second source rewrote the first one's line, and the anti-deletion guard
# refused the install (measured live on pve9). The property REV-101 is about --
# two independent entries, both reaching the cron -- is unchanged and is what
# is asserted; the single-line shape was incidental to it.
out="$(run --source=rpool/data,rpool/vmstore --target=hdd/backups --config="$WORK/mc.conf")"; rc=$?
mc_data="$(printf '%s\n' "$out" | grep -cE 'snapsend\.sh -m "automated_hourly_" "rpool/data" "hdd/backups"')"
mc_vm="$(printf '%s\n' "$out" | grep -cE 'snapsend\.sh -m "automated_hourly_" "rpool/vmstore" "hdd/backups"')"
if [ "$rc" -eq 0 ] \
        && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/data\]' \
        && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/vmstore\]' \
        && [ "$mc_data" -ge 1 ] && [ "$mc_vm" -ge 1 ]; then
    ok "101/comma-list: two independent source entries, both in the rendered cron"
else
    bad "101/comma-list: two independent source entries, both in the rendered cron" \
        "rc=$rc $(printf '%s\n' "$out" | grep -E '\[dataset|snapsend' | head)"
fi
# ...and on DIFFERENT minutes, which is what keeps each line's identity stable
# when a third source joins later.
# Taken from the ENGINE call, not from the envelope: the envelope moved to
# zfs-job.sh on 2026-08-30 and a pattern anchored on its `echo ... ZFS-JOB
# BEGIN` counted zero, which reads as 'both sends on one minute' -- the exact
# failure this case exists to catch, reported for a reason that had nothing to
# do with the stagger. The minute and the engine call are what the claim is
# about; how the line is wrapped is not.
mc_min="$(printf '%s\n' "$out" | grep -E 'snapsend[.]sh -m \"automated_hourly_\"' | awk '{print $1}' | sort -u | grep -c .)"
[ "${mc_min:-0}" -ge 2 ] \
    && ok "101/comma-list: the two sends land on different minutes (no merge, stable identities)" \
    || bad "101/comma-list: the two sends land on different minutes" "distinct minutes: ${mc_min:-0}"
# one missing member in a 3-root request -> hard refuse, NO partial candidate.
out="$(run --source=rpool/data,rpool/nope,hdd/dokumenty --target=hdd/backups --config="$WORK/m3.conf")"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'does not exist' \
        && ! printf '%s\n' "$out" | grep -q '^\[dataset:rpool/data\]'; then
    ok "101/one missing member refuses the whole request, no partial candidate"
else
    bad "101/one missing member refuses the whole request, no partial candidate" "rc=$rc"
fi
# parent/child pair in the explicit set -> refuse (no invented precedence).
out="$(run --source=rpool/a,rpool/a/child --target=hdd/backups --config="$WORK/mpc.conf")"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'overlap'; } \
    && ok "101/parent-child pair in the set refuses" || bad "101/parent-child pair in the set refuses" "rc=$rc"
# exact duplicate root -> canonicalized to exactly one entry (no duplicate ownership).
out="$(run --source=rpool/data,rpool/data --target=hdd/backups --config="$WORK/mdup.conf")"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c '^\[dataset:rpool/data\]')" -eq 1 ]; } \
    && ok "101/duplicate root canonicalizes to exactly one entry" \
    || bad "101/duplicate root canonicalizes to exactly one entry" "rc=$rc entries=$(printf '%s\n' "$out" | grep -c '^\[dataset:rpool/data\]')"
# repeated --source flags -> normalized into the set, NEVER silent last-one-wins.
# (Discriminating against 9b4a6e5: the old scalar parser kept only the last flag,
# so rpool/data would be absent here.)
out="$(run --source=rpool/data --source=rpool/vmstore --target=hdd/backups --config="$WORK/mrep.conf")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/data\]' \
        && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/vmstore\]'; then
    ok "101/repeated --source flags normalize into the set (not last-one-wins)"
else
    bad "101/repeated --source flags normalize into the set (not last-one-wins)" "rc=$rc"
fi

# ---- REV-20260811-102: bounded, independent SOURCE + TARGET retention ----
# The default candidate must bound BOTH sides. Source retention = a [prune:<root>]
# per root; target retention = a [prune:<target>]. Both initialized from the same
# GFS ladder but rendered as separate, independent sections.
out="$(run --source=rpool/data --target=hdd/backups --config="$WORK/ret.conf")"; rc=$?
if [ "$rc" -eq 0 ] \
        && printf '%s\n' "$out" | grep -q '^\[prune:rpool/data\]' \
        && printf '%s\n' "$out" | grep -q '^\[prune:hdd/backups\]'; then
    ok "102/candidate carries BOTH a source [prune:root] and a target [prune:target]"
else
    bad "102/candidate carries BOTH a source [prune:root] and a target [prune:target]" \
        "rc=$rc $(printf '%s\n' "$out" | grep -E '^\[prune:' | head)"
fi
# the rendered cron has two INDEPENDENT delsnaps prune lines -- one on the source
# scope, one on the target scope -- both carrying the ladder. REV-102 F2: the
# SOURCE prune must match the source coverage. [dataset:rpool/data] is
# non-recursive (dataset.inc emits no recursion field), so the source prune is
# NON-recursive too -- delsnaps WITHOUT -R, scoped to exactly rpool/data. A
# recursive source prune (-R) would walk into children like rpool/data/vm-101 and
# could destroy automated_ snapshots owned by another/manual policy that this
# relationship never backs up. The target prune stays recursive over the store.
src_prune="$(printf '%s\n' "$out" | grep -cE 'delsnaps\.sh -G -P .*"rpool/data" "automated_" -H24 -D7 -W4 -M12')"
src_recursive="$(printf '%s\n' "$out" | grep -cE 'delsnaps\.sh -G -R .*"rpool/data" "automated_"')"
tgt_prune="$(printf '%s\n' "$out" | grep -cE 'delsnaps\.sh -G -R .*"hdd/backups" "automated_" -H24 -D7 -W4 -M12')"
if [ "$src_prune" -ge 1 ] && [ "$tgt_prune" -ge 1 ]; then
    ok "102/rendered cron prunes source AND target independently, same ladder"
else
    bad "102/rendered cron prunes source AND target independently, same ladder" "src=$src_prune tgt=$tgt_prune"
fi
# F2 negative control: the source prune must NOT be recursive, so a child dataset
# outside this relationship's (non-recursive) coverage carrying tool-owned
# snapshots is never walked into. If the source line ever renders with -R this
# fails -- the exact destructive over-reach REV-102 F2 named.
if [ "$src_recursive" -eq 0 ]; then
    ok "102 F2/source prune is NON-recursive (children outside coverage survive)"
else
    bad "102 F2/source prune is NON-recursive (children outside coverage survive)" "source rendered with -R ($src_recursive)"
fi
# only the tool-owned pattern is matched -> manual/foreign snapshots survive
# (the source prune's delsnaps pattern is "automated_", never "*").
if printf '%s\n' "$out" | grep -qE 'delsnaps\.sh -G -P .*"rpool/data" "automated_"' \
        && ! printf '%s\n' "$out" | grep -qE 'delsnaps\.sh[^\n]*"rpool/data" "\*"'; then
    ok "102/source prune is bounded to automated_ -- manual snapshots survive"
else
    bad "102/source prune is bounded to automated_ -- manual snapshots survive" ""
fi
# each root gets its OWN source prune (multi-source), plus one target prune.
out="$(run --source=rpool/data,rpool/vmstore --target=hdd/backups --config="$WORK/retm.conf")"
if printf '%s\n' "$out" | grep -q '^\[prune:rpool/data\]' \
        && printf '%s\n' "$out" | grep -q '^\[prune:rpool/vmstore\]' \
        && printf '%s\n' "$out" | grep -q '^\[prune:hdd/backups\]'; then
    ok "102/each root gets its own source prune, plus one target prune"
else
    bad "102/each root gets its own source prune, plus one target prune" \
        "$(printf '%s\n' "$out" | grep -E '^\[prune:' | tr '\n' ' ')"
fi
# negative control: the source [prune:root] is the NEW behaviour. The reviewed
# base (5423518) emitted only [prune:target]; asserting [prune:rpool/data] is
# present is therefore discriminating -- an old generator would fail it. (An
# out-of-band ZB=<old checkout> run confirms the base omits the source prune.)

# ---- REV-20260811-104 F1: source and target retention are INDEPENDENT policies ----
# Two [prune:] scopes are not enough; they must reference DISTINCT prune-template
# identities so editing one side does not change the other. Extract the candidate
# CONFIG from the plan, then prove independent editing.
out="$(run --source=rpool/data --target=hdd/backups --config="$WORK/ind.conf")"
printf '%s\n' "$out" | sed -n '/^--- kandydat CONFIG v4/,/^--- wygenerowany/p' | sed '1d;$d' > "$WORK/ind-cand.conf"
# distinct template identities: a source family (__src_keep_*) AND a target family
# (__keep_*), both present.
if grep -q '^\[template:profile__default__src_keep_hourly\]' "$WORK/ind-cand.conf" \
        && grep -q '^\[template:profile__default__keep_hourly\]' "$WORK/ind-cand.conf" \
        && grep -q 'use_template = profile__default__src_keep_' "$WORK/ind-cand.conf" \
        && grep -q 'use_template = profile__default__keep_' "$WORK/ind-cand.conf"; then
    ok "104 F1/source and target reference DISTINCT prune-template identities"
else
    bad "104 F1/source and target reference DISTINCT prune-template identities" \
        "$(grep -E '^\[template:|use_template' "$WORK/ind-cand.conf" | head)"
fi
# render helper: retain shown on the source (rpool/data) vs target (hdd/backups) line.
lb_render_retain() {  # <config> <scope> -> the -M value on that scope's prune line
    env -u REPO_DIR -u NOTIFY_SCRIPT -u WARN_SCRIPT -u DIGEST_SCRIPT -u CRON_LOG -u DIGEST_SCHEDULE \
        bash "$GEN" -c "$1" 2>/dev/null | grep -oE "\"$2\" \"automated_\" -H24 -D7 -W4 -M[0-9]+" | grep -oE 'M[0-9]+' | head -1
}
GEN="$REPO/gen-cron.sh"
# mutate ONLY the source family's monthly retain -M12 -> -M36
awk '/\[template:profile__default__src_keep_monthly\]/{f=1} f&&/retain/{sub(/-M12/,"-M36");f=0} {print}' "$WORK/ind-cand.conf" > "$WORK/mut-src.conf"
if [ "$(lb_render_retain "$WORK/mut-src.conf" 'rpool/data')" = "M36" ] \
        && [ "$(lb_render_retain "$WORK/mut-src.conf" 'hdd/backups')" = "M12" ]; then
    ok "104 F1/editing only SOURCE retention changes SOURCE, leaves TARGET unchanged"
else
    bad "104 F1/editing only SOURCE retention changes SOURCE, leaves TARGET unchanged" \
        "src=$(lb_render_retain "$WORK/mut-src.conf" 'rpool/data') tgt=$(lb_render_retain "$WORK/mut-src.conf" 'hdd/backups')"
fi
# mutate ONLY the target family's monthly retain -> the converse
awk '/\[template:profile__default__keep_monthly\]/{f=1} f&&/retain/{sub(/-M12/,"-M60");f=0} {print}' "$WORK/ind-cand.conf" > "$WORK/mut-tgt.conf"
if [ "$(lb_render_retain "$WORK/mut-tgt.conf" 'hdd/backups')" = "M60" ] \
        && [ "$(lb_render_retain "$WORK/mut-tgt.conf" 'rpool/data')" = "M12" ]; then
    ok "104 F1/editing only TARGET retention changes TARGET, leaves SOURCE unchanged"
else
    bad "104 F1/editing only TARGET retention changes TARGET, leaves SOURCE unchanged" \
        "tgt=$(lb_render_retain "$WORK/mut-tgt.conf" 'hdd/backups') src=$(lb_render_retain "$WORK/mut-tgt.conf" 'rpool/data')"
fi
# negative control: prove the distinctness is load-bearing -- if BOTH scopes shared
# one template family (the 49d547ae shape), the src mutation above would also move
# the target. Build a valid shared-shape config: drop the __src_keep_ template
# definitions and point the source prune at the target's __keep_ family.
awk '/^\[template:profile__default__src_keep_/{skip=1;next} /^\[/{skip=0} !skip' "$WORK/ind-cand.conf" \
    | sed '/^\tuse_template/ s/__src_keep_/__keep_/g' > "$WORK/shared.conf"
awk '/\[template:profile__default__keep_monthly\]/{f=1} f&&/retain/{sub(/-M12/,"-M36");f=0} {print}' "$WORK/shared.conf" > "$WORK/shared-mut.conf"
if [ "$(lb_render_retain "$WORK/shared-mut.conf" 'rpool/data')" = "M36" ] \
        && [ "$(lb_render_retain "$WORK/shared-mut.conf" 'hdd/backups')" = "M36" ]; then
    ok "104 F1/negctl: a SHARED template family couples both sides (why distinct identities matter)"
else
    bad "104 F1/negctl: a SHARED template family couples both sides" \
        "src=$(lb_render_retain "$WORK/shared-mut.conf" 'rpool/data') tgt=$(lb_render_retain "$WORK/shared-mut.conf" 'hdd/backups')"
fi

# ---- REV-20260811-106 F1: the source/target split is profile-agnostic ----
# The split must not depend on a `keep_*` naming convention. Build a VALID custom
# profile whose prune templates are named ret_* (no `keep_`), by copying the
# built-in default and renaming keep_ -> ret_ (preserves structure and tabs), then
# prove the SOURCE family is still derived and distinct.
mkdir -p "$WORK/profiles/custret"
sed 's/keep_/ret_/g' "$REPO/profiles/default.conf" > "$WORK/profiles/custret.conf"
run_custret() {  # like run(), but PROFILE_ROOT points at the temp custom profile
    ( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$WORK/profiles" \
      cmd_local_backup "$@" ) 2>&1
}
out="$(run_custret --source=rpool/data --target=hdd/backups --profile=custret --config="$WORK/cust.conf")"; rc=$?
printf '%s\n' "$out" | sed -n '/^--- kandydat CONFIG v4/,/^--- wygenerowany/p' | sed '1d;$d' > "$WORK/cust-cand.conf"
# it must actually have planned (a ret_* profile is valid input)
{ [ "$rc" -eq 0 ] && grep -q '^\[dataset:rpool/data\]' "$WORK/cust-cand.conf"; } \
    && ok "106/custom ret_* profile plans successfully" \
    || bad "106/custom ret_* profile plans successfully" "rc=$rc $(printf '%s' "$out"|tail -1)"
# distinct identities for a name that does NOT contain keep_: a SOURCE family
# (__src_ret_*) exists AND the source prune points at it, not at the target's __ret_*.
if grep -q '^\[template:profile__custret__src_ret_hourly\]' "$WORK/cust-cand.conf" \
        && grep -q '^\[template:profile__custret__ret_hourly\]' "$WORK/cust-cand.conf" \
        && grep -q 'use_template = profile__custret__src_ret_' "$WORK/cust-cand.conf" \
        && grep -q 'use_template = profile__custret__ret_' "$WORK/cust-cand.conf"; then
    ok "106 F1/custom profile gets DISTINCT source vs target template identities"
else
    bad "106 F1/custom profile gets DISTINCT source vs target template identities" \
        "$(grep -E '^\[template:|use_template' "$WORK/cust-cand.conf" | head)"
fi
# equal INITIAL retention on both sides (copied from the profile's actual policy)
if [ "$(lb_render_retain "$WORK/cust-cand.conf" 'rpool/data')" = "M12" ] \
        && [ "$(lb_render_retain "$WORK/cust-cand.conf" 'hdd/backups')" = "M12" ]; then
    ok "106 F1/custom profile: SOURCE and TARGET start from EQUAL retention"
else
    bad "106 F1/custom profile: SOURCE and TARGET start from EQUAL retention" \
        "src=$(lb_render_retain "$WORK/cust-cand.conf" 'rpool/data') tgt=$(lb_render_retain "$WORK/cust-cand.conf" 'hdd/backups')"
fi
# mutate ONLY the source family -> only the source cron line moves
awk '/\[template:profile__custret__src_ret_monthly\]/{f=1} f&&/retain/{sub(/-M12/,"-M36");f=0} {print}' \
    "$WORK/cust-cand.conf" > "$WORK/cust-mut-src.conf"
if [ "$(lb_render_retain "$WORK/cust-mut-src.conf" 'rpool/data')" = "M36" ] \
        && [ "$(lb_render_retain "$WORK/cust-mut-src.conf" 'hdd/backups')" = "M12" ]; then
    ok "106 F1/custom: editing only SOURCE changes SOURCE, TARGET unchanged"
else
    bad "106 F1/custom: editing only SOURCE changes SOURCE, TARGET unchanged" \
        "src=$(lb_render_retain "$WORK/cust-mut-src.conf" 'rpool/data') tgt=$(lb_render_retain "$WORK/cust-mut-src.conf" 'hdd/backups')"
fi
# mutate ONLY the target family -> the converse
awk '/\[template:profile__custret__ret_monthly\]/{f=1} f&&/retain/{sub(/-M12/,"-M60");f=0} {print}' \
    "$WORK/cust-cand.conf" > "$WORK/cust-mut-tgt.conf"
if [ "$(lb_render_retain "$WORK/cust-mut-tgt.conf" 'hdd/backups')" = "M60" ] \
        && [ "$(lb_render_retain "$WORK/cust-mut-tgt.conf" 'rpool/data')" = "M12" ]; then
    ok "106 F1/custom: editing only TARGET changes TARGET, SOURCE unchanged"
else
    bad "106 F1/custom: editing only TARGET changes TARGET, SOURCE unchanged" \
        "tgt=$(lb_render_retain "$WORK/cust-mut-tgt.conf" 'hdd/backups') src=$(lb_render_retain "$WORK/cust-mut-tgt.conf" 'rpool/data')"
fi
# negative control: the retired `__keep_` textual rewrite is a NO-OP on ret_* names,
# so under 799bd0d the custom SOURCE would have shared the TARGET's family. Prove
# the coupling directly: point the source prune back at the target family (what the
# no-op rewrite leaves) and show one edit moves BOTH sides.
awk '/^\[template:profile__custret__src_ret_/{skip=1;next} /^\[/{skip=0} !skip' "$WORK/cust-cand.conf" \
    | sed '/use_template/ s/__src_ret_/__ret_/g' > "$WORK/cust-shared.conf"
old_noop="$(printf 'use_template = profile__custret__ret_hourly\n' | sed 's/__keep_/__src_keep_/g')"
[ "$old_noop" = 'use_template = profile__custret__ret_hourly' ] \
    && ok "106 negctl/the old __keep_ rewrite is a no-op on a ret_* profile" \
    || bad "106 negctl/the old __keep_ rewrite is a no-op on a ret_* profile" "$old_noop"
awk '/\[template:profile__custret__ret_monthly\]/{f=1} f&&/retain/{sub(/-M12/,"-M36");f=0} {print}' \
    "$WORK/cust-shared.conf" > "$WORK/cust-shared-mut.conf"
if [ "$(lb_render_retain "$WORK/cust-shared-mut.conf" 'rpool/data')" = "M36" ] \
        && [ "$(lb_render_retain "$WORK/cust-shared-mut.conf" 'hdd/backups')" = "M36" ]; then
    ok "106 negctl/a shared family couples both sides (why the profile-agnostic split matters)"
else
    bad "106 negctl/a shared family couples both sides" \
        "src=$(lb_render_retain "$WORK/cust-shared-mut.conf" 'rpool/data') tgt=$(lb_render_retain "$WORK/cust-shared-mut.conf" 'hdd/backups')"
fi

# ---- F2: additive composition over an existing config ----
cat > "$WORK/existing.conf" <<'EOF'
[defaults]
	host_label = h
[dataset:rpool/other]
	# managed-by: zfs-backup.sh local-backup source=rpool/other
	use_template = profile__default__standard_hourly
	dst          = hdd/backups/other
	notify       = local-other
EOF
a_before="$(sed -n '/\[dataset:rpool\/other\]/,/notify       = local-other/p' "$WORK/existing.conf")"
out="$(run --source=rpool/data --target=hdd/store --config="$WORK/existing.conf")"; rc=$?
a_after="$(printf '%s\n' "$out" | sed -n '/\[dataset:rpool\/other\]/,/notify       = local-other/p')"
if [ "$rc" -eq 0 ] && [ "$a_before" = "$a_after" ] \
        && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/data\]'; then
    ok "F2/additive: existing A is byte-unchanged and B is added"
else
    bad "F2/additive: existing A is byte-unchanged and B is added" "rc=$rc"
fi
# the rendered cron carries BOTH jobs (add B, do not lose A)
sends="$(printf '%s\n' "$out" | grep -oE 'snapsend\.sh -m "automated_hourly_" "rpool/(other|data)"' | sort -u | wc -l)"
[ "$sends" -eq 2 ] && ok "F2/rendered cron carries both A and B send lines" \
    || bad "F2/rendered cron carries both A and B send lines" "distinct sends=$sends"
# the real target CONFIG on disk was not touched
[ "$(cat "$WORK/existing.conf")" = "$(printf '[defaults]\n\thost_label = h\n[dataset:rpool/other]\n\t# managed-by: zfs-backup.sh local-backup source=rpool/other\n\tuse_template = profile__default__standard_hourly\n\tdst          = hdd/backups/other\n\tnotify       = local-other')" ] \
    && ok "F2/the real target config file is not mutated by planning" \
    || bad "F2/the real target config file is not mutated by planning" ""

# overlap with existing coverage refuses (source overlaps A's own dataset)
out="$(run --source=rpool/other --target=hdd/fresh --config="$WORK/existing.conf")"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'overlap'; } \
    && ok "F2/overlap with existing coverage refuses" || bad "F2/overlap with existing coverage refuses" "rc=$rc"

# REV-20260811-098: a section scope may be a comma-separated list; the overlap
# guard must expand it and check every member, not the comma-joined blob.
cat > "$WORK/multi.conf" <<'EOF'
[defaults]
	host_label = h
[prune:rpool/other,rpool/data]
	# managed-by: zfs-backup.sh local-backup source=multi
	use_template = profile__default__keep_hourly,profile__default__keep_daily,profile__default__keep_weekly,profile__default__keep_monthly
	gfs          = yes
	gfs_pattern  = automated_
	recursive    = yes
	notify       = local-multi
EOF
# overlap with the SECOND member (rpool/data) must refuse
out="$(run --source=rpool/data --target=hdd/fresh2 --config="$WORK/multi.conf")"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'overlap'; } \
    && ok "098/overlap with a non-first member of a comma-list scope refuses" \
    || bad "098/overlap with a non-first member of a comma-list scope refuses" "rc=$rc out=$(printf '%s' "$out"|tail -1)"
# a genuinely disjoint request beside the same multi-path section still proceeds
# (guards against a lazy "any comma means conflict" implementation)
out="$(run --source=rpool/db --target=hdd/disjoint --config="$WORK/multi.conf")"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/db\]'; } \
    && ok "098/disjoint request beside a comma-list scope still proceeds" \
    || bad "098/disjoint request beside a comma-list scope still proceeds" "rc=$rc out=$(printf '%s' "$out"|tail -2)"

# missing config CLAIMED by an installed managed block refuses (fail-closed)
out="$(run --source=rpool/data --target=hdd/backups --config="$WORK/claimed.conf")"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qiE 'refusing to create|installed crontab block'; } \
    && ok "F2/missing config claimed by an installed block refuses" \
    || bad "F2/missing config claimed by an installed block refuses" "rc=$rc out=$(printf '%s' "$out"|tail -1)"

# missing config NOT claimed -> fresh candidate is allowed
out="$(run --source=rpool/data --target=hdd/backups --config="$WORK/brandnew.conf")"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/data\]'; } \
    && ok "F2/missing unclaimed config gets a fresh candidate" || bad "F2/missing unclaimed config gets a fresh candidate" "rc=$rc"

# ---- F3: the bare public entrypoint reaches the same planning logic ----
out="$( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" \
        bash "$ZB" --source=rpool/data --target=hdd/backups --config="$WORK/bare.conf" 2>&1 )"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/data\]'; } \
    && ok "F3/bare --source/--target reaches the planning logic" || bad "F3/bare --source/--target reaches the planning logic" "rc=$rc"
# the alias still works too
out="$( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" \
        bash "$ZB" local-backup --source=rpool/data --target=hdd/backups --config="$WORK/alias.conf" 2>&1 )"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/data\]'; } \
    && ok "F3/local-backup alias still reaches the same logic" || bad "F3/local-backup alias still reaches the same logic" "rc=$rc"

# ---- accepted: same-pool note vs cross-pool ----
out="$(run --source=rpool/data --target=rpool/store --config="$WORK/sp.conf")"
[ "$(printf '%s\n' "$out" | grep -c 'dziela pule')" -eq 1 ] \
    && ok "same-pool prints one factual note" || bad "same-pool prints one factual note" ""
out="$(run --source=rpool/data --target=hdd/backups --config="$WORK/xp.conf")"
printf '%s\n' "$out" | grep -q 'dziela pule' \
    && bad "cross-pool prints no note" "" || ok "cross-pool prints no note"

# ---- accepted: planning installs NOTHING (no crontab WRITE across every plan) --
if [ ! -e "$WORK/crontab-writes" ]; then
    ok "installs-nothing: crontab was never written across every plan above"
else
    bad "installs-nothing: crontab was never written across every plan above" "$(cat "$WORK/crontab-writes")"
fi

# ==============================================================================
# Slice 2 -- the transactional install (--install). Everything above pins the
# read-only planner; from here the same command is asked to actually install.
#
# The seed is stubbed, not real: what is under test is the ORDER and the
# transaction boundary, not snapsend's own behaviour, which its own suite and
# the real-ZFS proof cover. $SNAPSEND is an absolute path, so it is overridden
# in the environment rather than through PATH.
# ==============================================================================
mkdir -p "$WORK/seedbin" "$WORK/bin2"
# The shared crontab stub returns a managed block containing a foreign job line.
# The pre-install guard correctly refuses to delete it -- right behaviour, wrong
# fixture for exercising the install itself. These runs get a stub whose managed
# block still CLAIMS the config (so the claim and consistency guards are really
# exercised) but describes no job the new config would drop.
# It also has to STORE what it is given. gen-cron writes the crontab and then
# reads it back, refusing to report success if the two differ -- so a stub that
# accepts a write and keeps returning the old content makes the tool correctly
# refuse. That refusal is the product working; emulating a real crontab is the
# only way to test past it.
cat > "$WORK/bin2/crontab" <<EOF
#!/bin/sh
STORE="$WORK/crontab-store"
case " \$* " in
  *" -l "*) if [ -f "\$STORE" ]; then cat "\$STORE"
            else printf '# BEGIN zfs-backup-managed\n# Source: %s/claimed.conf -- do not edit\n# END zfs-backup-managed\n' "$WORK"; fi ;;
  *) for a in "\$@"; do f="\$a"; done
     [ -f "\$f" ] && cp "\$f" "\$STORE"
     echo "WRITE \$*" >> "$WORK/crontab-writes"; echo INSTALL >> "$WORK/order" ;;
esac
exit 0
EOF
chmod +x "$WORK/bin2/crontab"
cat > "$WORK/seedbin/snapsend-ok" <<EOF
#!/bin/sh
echo "SEED \$*" >> "$WORK/seed-calls"
echo SEED >> "$WORK/order"
exit 0
EOF
cat > "$WORK/seedbin/snapsend-fail" <<EOF
#!/bin/sh
echo "SEED \$*" >> "$WORK/seed-calls"
echo SEED >> "$WORK/order"
echo "seed exploded" >&2
exit 1
EOF
chmod +x "$WORK/seedbin/snapsend-ok" "$WORK/seedbin/snapsend-fail"

runi() {   # <snapsend stub> <stdin answer> args...
    local stub="$1" answer="$2"; shift 2
    ( PATH="$WORK/bin2:$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" \
      SNAPSEND="$WORK/seedbin/$stub" \
      cmd_local_backup "$@" ) <<< "$answer" 2>&1
}

# The crontab stub claims $WORK/claimed.conf, so that is the only config path an
# install can legitimately target here (assert_cron_config_matches_installed).
CFG="$WORK/claimed.conf"
# A pre-existing, VALID config -- not an empty file. An empty one has no
# [defaults] host_label, which gen-cron rejects, and that would test the
# scaffolding rather than the install. Writing the minimum by hand also keeps
# the additive property honest: this block must survive the install untouched.
seed_cfg() { printf '[defaults]
	host_label = testhost
' > "$CFG"; }
seed_cfg

# ---- slice-1 compatibility: without --install the command still only plans ----
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
out="$(runi snapsend-ok "" --source=rpool/data --target=hdd/backups --config="$CFG")"
{ [ ! -e "$WORK/order" ] && [ "$(wc -l < "$CFG")" -eq 2 ] && printf '%s' "$out" | grep -q -- '--install'; } \
    && ok "slice2: no --install still plans only, and says how to install" \
    || bad "slice2: no --install still plans only, and says how to install" "order=$(cat "$WORK/order" 2>/dev/null)"

# ---- declined confirmation: nothing seeded, nothing installed ----------------
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
out="$(runi snapsend-ok "n" --install --source=rpool/data --target=hdd/backups --config="$CFG")"
{ [ ! -e "$WORK/order" ] && [ "$(wc -l < "$CFG")" -eq 2 ]; } \
    && ok "slice2: a declined confirmation seeds nothing and installs nothing" \
    || bad "slice2: a declined confirmation seeds nothing and installs nothing" "order=$(cat "$WORK/order" 2>/dev/null)"

# ---- failed seed: no cron installed, config untouched, retryable -------------
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
out="$(runi snapsend-fail "t" --install --yes --source=rpool/data --target=hdd/backups --config="$CFG")"
{ grep -q SEED "$WORK/order" 2>/dev/null && ! grep -q INSTALL "$WORK/order" 2>/dev/null && [ "$(wc -l < "$CFG")" -eq 2 ]; } \
    && ok "slice2: a FAILED seed installs no cron and leaves the config untouched" \
    || bad "slice2: a FAILED seed installs no cron and leaves the config untouched" "order=$(cat "$WORK/order" 2>/dev/null)"
printf '%s' "$out" | grep -qi 'NIC nie zainstalowano' \
    && ok "slice2: the failed-seed refusal says plainly that nothing was installed" \
    || bad "slice2: the failed-seed refusal says plainly that nothing was installed" "$(printf '%s' "$out" | tail -2)"

# ---- happy path: seed BEFORE install, and the order is the contract ----------
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
out="$(runi snapsend-ok "t" --install --yes --source=rpool/data --target=hdd/backups --config="$CFG")"
{ [ "$(wc -l < "$CFG")" -gt 2 ] && grep -q "host_label = testhost" "$CFG"; } \
    && ok "slice2: a successful run installs the config and preserves the pre-existing block" \
              || bad "slice2: a successful run installs the config and preserves the pre-existing block" "$(printf '%s' "$out" | tail -3)"
# THE ordering property: seed must be established before any cron becomes
# eligible. A run that installed first and seeded after would still produce both
# lines -- only their order distinguishes the safe implementation from the unsafe
# one, which is why this asserts the sequence and not the presence.
[ "$(tr -d ' \n' < "$WORK/order" 2>/dev/null)" = "SEEDINSTALL" ] \
    && ok "slice2: the seed runs BEFORE the cron install (order, not presence)" \
    || bad "slice2: the seed runs BEFORE the cron install (order, not presence)" "order=[$(tr '\n' ',' < "$WORK/order" 2>/dev/null)]"

# ---- the seed prefix comes from the RENDER, not from a second constant -------
# The profile's own template decides it. A hardcoded copy in the install path
# would pass every test above and silently create a snapshot family the
# installed prune never matches, so the prefix itself is asserted.
grep -q -- '-m automated_hourly_' "$WORK/seed-calls" 2>/dev/null \
    && ok "slice2: the seed uses the prefix read back out of the rendered cron line" \
    || bad "slice2: the seed uses the prefix read back out of the rendered cron line" "$(cat "$WORK/seed-calls" 2>/dev/null)"

# ---- multi-root: one seed per source, still one install ----------------------
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
out="$(runi snapsend-ok "t" --install --yes --source=rpool/data,rpool/db --target=hdd/backups --config="$CFG")"
# `grep -c` prints 0 AND exits 1 on no match, so an `|| echo 0` fallback appends
# a SECOND zero and the arithmetic test dies on "0\n0". Count the lines instead.
{ [ "$({ grep -c SEED "$WORK/seed-calls" 2>/dev/null; true; } | head -1)" = 2 ] && grep -q INSTALL "$WORK/order" 2>/dev/null; } \
    && ok "slice2: two sources seed twice and install once" \
    || bad "slice2: two sources seed twice and install once" "$(cat "$WORK/seed-calls" 2>/dev/null)"

# ---- REV-20260812-112 F1: the Usage text must advertise the install verb -----
# The delivered command grew --install/--yes while the top-level Usage still
# described it as plan/preview only. Help that contradicts the tool is a defect
# in the public contract, so the contract is asserted, not just the behaviour.
usage_txt="$(usage 2>&1)"
{ printf '%s' "$usage_txt" | grep -q -- '--install'   && printf '%s' "$usage_txt" | grep -qE -- '--yes\|?-y|-y'; }     && ok "112 F1: Usage advertises --install and --yes/-y"     || bad "112 F1: Usage advertises --install and --yes/-y" "$(printf '%s' "$usage_txt" | grep -i 'source=DATASET' )"
# and the OLD unconditional claim must be gone -- the discriminating half:
# a Usage that merely LISTS --install while still saying "plan/preview only"
# would pass the assertion above and still mislead.
printf '%s' "$usage_txt" | grep -qi 'plan/preview only'     && bad "112 F1: Usage no longer claims the command is plan/preview only" "still says plan/preview only"     || ok "112 F1: Usage no longer claims the command is plan/preview only"

# ==============================================================================
# Slice 3 -- target discovery when --target is omitted.
#
# Two provenances with deliberately different power: a target recorded in
# server.conf is an operator decision and behaves like one they typed; a target
# guessed from the pool layout may be proposed and shown, but never installed
# with nobody looking.
# ==============================================================================
cat > "$WORK/bin2/zpool" <<'EOF'
#!/bin/sh
# candidate pools are whatever POOLS says; default is one non-rpool pool
printf '%s\n' ${POOLS:-rpool hdd}
EOF
chmod +x "$WORK/bin2/zpool"
cp "$WORK/bin/zfs" "$WORK/bin2/zfs" 2>/dev/null || :

rund() {   # <server.conf or -> <POOLS> args... ; discovery runs, no install
    local sc="$1" pools="$2"; shift 2
    ( PATH="$WORK/bin2:$WORK/bin:$PATH" SERVER_CONF="$sc" POOLS="$pools" \
      PROFILE_ROOT="$REPO/profiles" cmd_local_backup "$@" ) 2>&1
}

printf 'DEFAULT_TARGET=hdd/store\nCRON_CONFIG=%s/d.conf\n' "$WORK" > "$WORK/server.conf"

# ---- provenance: default (server.conf) ----
out="$(rund "$WORK/server.conf" "rpool hdd" --source=rpool/data --config="$WORK/d1.conf")"
{ printf '%s' "$out" | grep -q 'configured default' && printf '%s\n' "$out" | grep -q 'hdd/store'; } \
    && ok "slice3: an omitted --target uses server.conf's DEFAULT_TARGET and says so" \
    || bad "slice3: an omitted --target uses server.conf's DEFAULT_TARGET and says so" "$(printf '%s' "$out"|head -3)"

# ---- provenance: heuristic (one candidate pool) ----
out="$(rund "$WORK/none.conf" "rpool hdd" --source=rpool/data --config="$WORK/d2.conf")"
{ printf '%s' "$out" | grep -q 'PROPOSING' && printf '%s' "$out" | grep -q 'hdd/backups'; } \
    && ok "slice3: with no default, one candidate pool is PROPOSED and labelled a guess" \
    || bad "slice3: with no default, one candidate pool is PROPOSED and labelled a guess" "$(printf '%s' "$out"|head -3)"

# ---- ambiguity refuses, and the refusal must actually STOP the run ----
# die() inside the helper runs in a command-substitution subshell, so a caller
# that ignored the status would sail past it with an empty target. This asserts
# the refusal is terminal, not just printed.
out="$(rund "$WORK/none.conf" "rpool hdd tank" --source=rpool/data --config="$WORK/d3.conf")"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'multiple candidate pools' \
  && ! printf '%s\n' "$out" | grep -q '^\[dataset:rpool/data\]'; } \
    && ok "slice3: ambiguous pools refuse terminally -- no plan is produced" \
    || bad "slice3: ambiguous pools refuse terminally -- no plan is produced" "rc=$rc $(printf '%s' "$out"|head -2)"

# ---- a GUESSED target must not install under --yes ----
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
out="$( ( PATH="$WORK/bin2:$WORK/bin:$PATH" SERVER_CONF="$WORK/none.conf" POOLS="rpool hdd" \
          PROFILE_ROOT="$REPO/profiles" SNAPSEND="$WORK/seedbin/snapsend-ok" \
          cmd_local_backup --source=rpool/data --install --yes --config="$CFG" ) 2>&1 )"
{ printf '%s' "$out" | grep -qi 'cannot confirm a target this run GUESSED' && [ ! -e "$WORK/order" ]; } \
    && ok "slice3: --yes refuses a guessed target and installs nothing" \
    || bad "slice3: --yes refuses a guessed target and installs nothing" "order=$(cat "$WORK/order" 2>/dev/null)"

# ---- discriminating control: the block keys on PROVENANCE, not on omission ----
# Same omitted --target, same --yes -- only the provenance differs. A guard that
# simply refused "--yes when --target was omitted" would fail this.
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
printf 'DEFAULT_TARGET=hdd/backups\n' > "$WORK/server2.conf"
out="$( ( PATH="$WORK/bin2:$WORK/bin:$PATH" SERVER_CONF="$WORK/server2.conf" POOLS="rpool hdd" \
          PROFILE_ROOT="$REPO/profiles" SNAPSEND="$WORK/seedbin/snapsend-ok" \
          cmd_local_backup --source=rpool/data --install --yes --config="$CFG" ) 2>&1 )"
{ [ "$(tr -d ' \n' < "$WORK/order" 2>/dev/null)" = "SEEDINSTALL" ]; } \
    && ok "slice3: an omitted target from server.conf still installs under --yes (provenance, not omission)" \
    || bad "slice3: an omitted target from server.conf still installs under --yes (provenance, not omission)" "order=[$(tr '\n' ',' < "$WORK/order" 2>/dev/null)] $(printf '%s' "$out"|tail -2)"

# ===========================================================================
# gen-cron.sh --uninstall -- taking back what a local deployment installed.
#
# Found by running the deployment matrix on pve9, 2026-08-20: a LOCAL backup
# (one host, --source/--target, no peer) installs a managed block that nothing
# could then remove. remove-client needs a relationship; clean-relationships.sh
# correctly reports that a local backup is not one; and emptying the config is
# refused with "no send/prune/monitor rules resolved". The package could build
# something it could not take apart.
#
# Its own STATEFUL crontab stub, because the shared one above always answers
# `-l` with a block -- and the property here is precisely that the block stops
# being there. A stub that cannot represent "gone" cannot test a removal.
# ===========================================================================
# The crontab writer locks with flock. Where there is none -- Git Bash on
# Windows, where much of this tree is edited -- these five cases would fail for
# the environment rather than for the code, which is how a suite gets muted.
# Skipped loudly instead; CI runs on Linux and exercises them for real.
if ! command -v flock >/dev/null 2>&1; then
    echo "SKIP uninstall cases (no flock on this machine -- the crontab writer needs it)"
else
UWORK="$WORK/uninstall"; mkdir -p "$UWORK/bin" "$UWORK/locks"
printf '# BEGIN zfs-backup-managed\n# Source: /etc/x.conf -- do not edit\n1 * * * * /bin/true\n# END zfs-backup-managed\n7 7 * * * /root/mine.sh\n' > "$UWORK/tab"
# lib-cron writes with `crontab <file>` -- a FILENAME argument, not stdin. A
# stub that reads stdin instead silently stores an empty crontab, the writer's
# read-back correctly refuses, and the failure looks like the tool's. CI caught
# exactly that; this machine had skipped the cases for want of flock.
cat > "$UWORK/bin/crontab" <<EOF
#!/bin/sh
last=""
for a in "\$@"; do last="\$a"; done
case " \$* " in
  *" -l "*) cat "$UWORK/tab" ;;
  *) if [ -n "\$last" ] && [ -f "\$last" ]; then cat "\$last" > "$UWORK/tab"; else cat > "$UWORK/tab"; fi ;;
esac
exit 0
EOF
chmod +x "$UWORK/bin/crontab"

out=$( PATH="$UWORK/bin:$PATH" CRON_LOCK_DIR="$UWORK/locks" \
       bash "$REPO/gen-cron.sh" --uninstall 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] \
   && ! grep -q 'BEGIN zfs-backup-managed' "$UWORK/tab" \
   && grep -q '7 7 \* \* \* /root/mine.sh' "$UWORK/tab"; then
    ok "uninstall: the managed block goes, and a human's own line survives"
else
    bad "uninstall: the managed block goes, and a human's own line survives" \
        "rc=$rc out=$out tab=[$(cat "$UWORK/tab")]"
fi

# It says what it did NOT do. "Uninstalled" next to a target dataset that still
# holds every backup is the sentence an operator would misread, so the removal
# names the boundary out loud rather than leaving it implied.
if grep -q 'removed the SCHEDULE, not the backups' <<<"$out"; then
    ok "uninstall: says it removed the schedule and not the data"
else
    bad "uninstall: says it removed the schedule and not the data" "$out"
fi

# Idempotent, and honest about it: a second run is not an error and does not
# claim to have removed something.
out2=$( PATH="$UWORK/bin:$PATH" CRON_LOCK_DIR="$UWORK/locks" \
        bash "$REPO/gen-cron.sh" --uninstall 2>&1 ); rc2=$?
if [ "$rc2" -eq 0 ] && grep -q 'nothing to remove' <<<"$out2"; then
    ok "uninstall: running it twice is a no-op that says so"
else
    bad "uninstall: running it twice is a no-op that says so" "rc=$rc2 out=$out2"
fi

# NO CONFIG REQUIRED -- the usual reason to reach for this is that the config is
# already gone, so demanding one would refuse exactly when it is most needed.
if ! grep -q 'config file not found' <<<"$out"; then
    ok "uninstall: needs no config, since a missing config is why you want it"
else
    bad "uninstall: needs no config, since a missing config is why you want it" "$out"
fi

# Opposites refuse rather than resolving in some order the caller cannot see.
out3=$( PATH="$UWORK/bin:$PATH" CRON_LOCK_DIR="$UWORK/locks" \
        bash "$REPO/gen-cron.sh" --install --uninstall 2>&1 ); rc3=$?
if [ "$rc3" -ne 0 ] && grep -qi 'opposites' <<<"$out3"; then
    ok "uninstall: --install --uninstall together is refused"
else
    bad "uninstall: --install --uninstall together is refused" "rc=$rc3 out=$out3"
fi
fi   # flock present

# This one needs no flock: the refusal happens during argument checking, before
# any lock is taken, and it is the one case that must hold everywhere.
out4=$( bash "$REPO/gen-cron.sh" --install --uninstall 2>&1 ); rc4=$?
if [ "$rc4" -ne 0 ] && grep -qi 'opposites' <<<"$out4"; then
    ok "uninstall: --install --uninstall is refused before any lock is attempted"
    :
else
    bad "uninstall: --install --uninstall is refused before any lock is attempted" "rc=$rc4 out=$out4"
fi

# ===========================================================================
# --local-user on the LOCAL form.
#
# Measured on pve9 2026-08-20 while working a deployment matrix: a single-host
# deployment could only ever run as root. The local parser refused the word
# (`unknown option --local-user=zfsbackup`), setup-server provisions an account
# but deliberately records none, and cron_target_user falls back to root -- so
# `setup-server --local-user=zfsbackup` created the account and the block still
# landed in root's crontab.
#
# Everything underneath was already account-aware. The flag is the whole gap.
# ===========================================================================
# A PLAN naming an account that does not exist REFUSES, and creates nothing.
# The plan's contract is "installs nothing", and a Unix account is not nothing
# -- an earlier draft of this created the account during a plan, which on a
# Linux runner would have been a real user made by a read-only command.
# Refusing also avoids the other half: gen-cron bakes the running copy's paths
# into every line, so a preview for a non-existent account could only come from
# root's copy and would show a block that will never be installed.
out="$(run --source=rpool/data --target=hdd/backups --local-user=nosuchacct_zz --config="$WORK/lu1.conf")"; rc=$?
if [ "$rc" -ne 0 ]    && printf '%s' "$out" | grep -q 'does not exist on this host'    && printf '%s' "$out" | grep -q 'Nothing was created'    && ! printf '%s' "$out" | grep -q 'unknown option'; then
    ok "local-user: the local form accepts the flag, and a plan for a missing account refuses without creating it"
else
    bad "local-user: the local form accepts the flag, and a plan for a missing account refuses without creating it" "rc=$rc $(printf '%s' "$out" | tail -2)"
fi
if ! id -u nosuchacct_zz >/dev/null 2>&1; then
    ok "local-user: ...and the account really was not created"
else
    bad "local-user: ...and the account really was not created" "nosuchacct_zz exists after a PLAN"
fi

# THE LOADER MUST NOT CLEAR STATE IT DOES NOT OWN.
#
# read_server_conf used to set LOCAL_USER="" before it even checked whether
# server.conf was readable -- left over from when the account was a host-wide
# setting. setup-server stopped writing it, the clear stayed, and it silently
# destroyed a decision made by the caller out of a file that never mentions it.
#
# cmd_activate_client and cmd_remove_client each worked around it, which made
# the behaviour look deliberate; cmd_local_backup then gained --local-user, did
# not know to work around it, and shipped a flag that parsed, set the variable,
# and had it wiped a hundred lines later. Green CI throughout.
#
# This is the assertion that would have caught it, and it is cheap.
( LOCAL_USER=someacct; SERVER_CONF="$WORK/no-such-server.conf"; read_server_conf
  [ "${LOCAL_USER:-}" = someacct ] ) \
    && ok "read_server_conf leaves LOCAL_USER alone when there is no server.conf" \
    || bad "read_server_conf leaves LOCAL_USER alone when there is no server.conf" \
           "the loader cleared a variable server.conf never carries"
printf 'DEFAULT_TARGET=hdd/x\nCRON_CONFIG=/etc/x.conf\n' > "$WORK/sc-present.conf"
( LOCAL_USER=someacct; SERVER_CONF="$WORK/sc-present.conf"; read_server_conf
  [ "${LOCAL_USER:-}" = someacct ] && [ "$DEFAULT_TARGET" = hdd/x ] ) \
    && ok "read_server_conf still loads its OWN fields, and still leaves LOCAL_USER" \
    || bad "read_server_conf still loads its OWN fields, and still leaves LOCAL_USER" \
           "either the reset came back, or the loader stopped loading"

# ONE grammar for --local-user, not one per command. Three commands ask the
# same question -- setup-server, add-client, local-backup -- and each used to
# carry its own copy of the case statement, differing only in the prefix on the
# error. The third was written by copying the second, which is also how it
# inherited a missing LOCAL_USER restore. Asserted at the source: the pattern
# must appear once, in the shared helper.
copies=$(grep -c '\*\[!a-z0-9_-\]\* | "" | \[!a-z_\]\*' "$ZB")
if [ "$copies" -eq 1 ]; then
    ok "the --local-user grammar exists once, in one helper, not once per command"
else
    bad "the --local-user grammar exists once, in one helper, not once per command" \
        "found $copies copies of the account-name pattern"
fi

# Same grammar as add-client, so the two forms cannot drift into disagreeing
# about what an account name is.
out="$(run --source=rpool/data --target=hdd/backups --local-user=9bad --config="$WORK/lu2.conf")"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'not a valid account name'; } \
    && ok "local-user: an invalid account name is refused, in add-client's words" \
    || bad "local-user: an invalid account name is refused, in add-client's words" "rc=$rc"

# Omitted means root, and says so -- the same sentence the remote form prints,
# because it is the same decision.
out="$(run --source=rpool/data --target=hdd/backups --config="$WORK/lu3.conf")"
printf '%s' "$out" | grep -q 'will run as root' \
    && ok "local-user: omitted means root, and the run says so" \
    || bad "local-user: omitted means root, and the run says so" "$(printf '%s' "$out" | head -3)"

# `root` written literally is accepted and means root -- not an account called
# "root" to be created and delegated to.
out="$(run --source=rpool/data --target=hdd/backups --local-user=root --config="$WORK/lu4.conf")"; rc=$?
{ [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'not a valid account name'; } \
    && ok "local-user: an explicit 'root' is accepted and is not treated as an account to create" \
    || bad "local-user: an explicit 'root' is accepted and is not treated as an account to create" "rc=$rc"

# The preview must be rendered by the identity that will install it. gen-cron
# derives its paths from where it lives, so root's copy bakes /root/scripts/...
# into every line while a delegated run bakes /home/<acct>/... -- a preview from
# the wrong copy previews a block that will never exist. Asserted at the source,
# because the difference only shows on a host with a real account.
# This used to be pinned by LINE NUMBER RANGE (2800..3200), which is not the
# property -- it is where the property happened to live. Adding comments
# anywhere above shifted gencron_as_target's OWN call into the window and the
# case failed for a reason that had nothing to do with what it protects
# (2026-08-23). Now the file is walked function by function and the rule is
# stated directly: exactly one function may reach gen-cron.sh without going
# through the wrapper, and it is the wrapper itself; the previewing path must
# not. The named exceptions are commands that render a config for validation
# under the identity they already are, not a preview of someone else's block.
gencron_callers=$(awk '
    /^[a-z_][a-z0-9_]*\(\) \{/ { fn = $1; sub(/\(\).*/, "", fn) }
    /bash "\$GENCRON"/          { print fn }
' "$ZB" | sort -u)
# load_active_profile joined the list on 2026-08-25, and the distinction that
# lets it in is worth stating: this rule exists because a PREVIEW rendered by
# the wrong copy is a preview of a block that will never be installed --
# gen-cron bakes the running copy's paths into every line. load_active_profile
# does not render anything. It asks for a TABLE (--dump-tier-letters) so that
# `keep = 24` in a profile can become `retain = -H24` without this tree keeping
# a second copy of what -W means. Same class as lib-profile.sh asking for
# --dump-fields, and the same reason: one schema authority.
#
# profile_digest joins on the same ticket (2026-08-26). It asks for the SAME
# table, and for a reason that makes the rule's own point: `keep = 24` becomes
# `-H24` through that table, so the table is part of what a relationship was
# generated FROM. A digest that ignored it would call an installed policy
# unchanged after the thing that renders it had changed.
gencron_allowed="gencron_as_target
cmd_activate_client
cmd_audit_source_retention
cmd_migrate_profile
cmd_remove_client
load_active_profile
profile_digest"
gencron_unexpected=$(comm -23 <(printf '%s
' "$gencron_callers") <(printf '%s
' "$gencron_allowed" | sort))
if [ -z "$gencron_unexpected" ]; then
    ok "local-user: only known functions reach gen-cron.sh directly; previewing goes through gencron_as_target"
else
    bad "local-user: only known functions reach gen-cron.sh directly; previewing goes through gencron_as_target"         "nowy bezposredni wolajacy: $(printf '%s' "$gencron_unexpected" | tr '
' ' ')"
fi
# And the previewing path itself, named rather than located.
if ! awk '/^show_activation_proposal\(\) \{/,/^\}/' "$ZB" | grep -q 'bash "\$GENCRON"'; then
    ok "local-user: show_activation_proposal renders through gencron_as_target, not gen-cron directly"
else
    bad "local-user: show_activation_proposal renders through gencron_as_target, not gen-cron directly"         "$(awk '/^show_activation_proposal\(\) \{/,/^\}/' "$ZB" | grep -n 'bash "\$GENCRON"')"
fi

# ==============================================================================
# KROK 5 -- the SOURCE proposal when --source is omitted.
#
# Until now a local backup was refused outright without --source, which made the
# "clean host -> working backup" path start with an operator reading `zfs list`
# by hand. The proposal is a GUESS, so it carries the same rule the guessed
# target carries: it may be shown, it may be planned with, and it may not be
# installed with nobody looking.
#
# The inventory stub answers the one query the proposal makes and leaves every
# other `zfs` call to the existing stub, so the assertions above are untouched.
# ==============================================================================
mkdir -p "$WORK/bin3"
cat > "$WORK/bin3/zfs" <<'EOF'
#!/bin/sh
# `zfs list -H -o name -t filesystem,volume` (no dataset argument) is the
# inventory query; INVENTORY holds the answer. Everything else falls through to
# the existence stub, which is what every other assertion in this suite uses.
case " $* " in
  *" -t filesystem,volume "*)
      printf '%s\n' ${INVENTORY:-rpool rpool/ROOT rpool/ROOT/pve-1 rpool/swap rpool/vmstore rpool/db hdd hdd/store}
      exit 0 ;;
esac
for a in "$@"; do ds="$a"; done
case "$ds" in rpool/data|rpool/existing|rpool/other|rpool/db|rpool/vmstore|hdd/dokumenty|rpool/a|rpool/a/child|rpool/ROOT/pve-1|rpool/swap|hdd/store) exit 0 ;;
             *) echo "cannot open '$ds': dataset does not exist" >&2; exit 1 ;; esac
EOF
cp "$WORK/bin2/zpool" "$WORK/bin3/zpool"
# bin2's crontab, not bin's: this section installs, and only that stub STORES
# what it is given. gen-cron writes the crontab and reads it back, so a stub
# that keeps returning the old content makes the tool correctly refuse -- the
# product working, and the wrong fixture for testing past it.
cp "$WORK/bin2/crontab" "$WORK/bin3/crontab"
chmod +x "$WORK/bin3/zfs" "$WORK/bin3/zpool" "$WORK/bin3/crontab"

# $SNAPSEND is pinned to the same successful stub the install assertions above
# use: this section is about which SOURCE SET is installed, never about the
# transfer, and a real engine here would reach for real ZFS.
runp() {   # <INVENTORY or -> args... ; inventory stub, no server.conf
    local inv="$1"; shift
    # '-' means "the stub's default inventory". Spelled out because the stub
    # uses ${INVENTORY:-default} and a literal '-' is NOT empty: the first cut
    # passed it straight through, the stub answered with one dataset named '-',
    # and eight assertions failed against perfectly good code.
    [ "$inv" = "-" ] && inv=""
    ( PATH="$WORK/bin3:$PATH" SERVER_CONF="$WORK/no-server.conf" POOLS="rpool hdd" \
      INVENTORY="$inv" PROFILE_ROOT="$REPO/profiles" \
      SNAPSEND="$WORK/seedbin/snapsend-ok" cmd_local_backup "$@" ) 2>&1
}

# ---- the proposal happens at all, and reaches the plan ----------------------
out="$(runp "-" --target=hdd/store --config="$WORK/k5a.conf")"
{ printf '%s' "$out" | grep -q 'PROPOZYCJA z inwentarza' \
  && printf '%s' "$out" | grep -q 'rpool/vmstore' \
  && printf '%s' "$out" | grep -q 'rpool/db'; } \
    && ok "krok5: an omitted --source is PROPOSED from the ZFS inventory and reaches the plan" \
    || bad "krok5: an omitted --source is PROPOSED from the ZFS inventory and reaches the plan" "$(printf '%s' "$out"|head -8)"

# ---- every exclusion, each with the reason it must be excluded FOR ----------
# A pool root is a container; the OS root is not restorable by this tool; a swap
# zvol carries no data; the target cannot hold its own backup. A PARENT is NOT
# on this list any more -- that question moved to the hierarchy cases below,
# after it turned out to have the wrong answer here.
for pair in "rpool|pula, nie zbior danych" \
            "rpool/ROOT|system operacyjny" \
            "rpool/ROOT/pve-1|system operacyjny" \
            "rpool/swap|swap" \
            "hdd/store|cel backupu"; do
    ds="${pair%%|*}"; why="${pair##*|}"
    if printf '%s' "$out" | grep -q "pominieto $ds -- $why"; then
        ok "krok5: '$ds' is excluded from the proposal, and the reason is printed"
    else
        bad "krok5: '$ds' is excluded from the proposal, and the reason is printed" \
            "$(printf '%s' "$out" | grep pominieto | head -8)"
    fi
    printf '%s' "$out" | grep -qE "^>>>   $ds\$" \
        && bad "krok5: '$ds' must not be proposed" "it appears in the candidate list"
done

# ---- a dataset an installed section already covers is not proposed ----------
printf '[defaults]\n\thost_label = t\n\n[dataset:rpool/db]\n\tuse_template = x\n' > "$WORK/k5cov.conf"
out2="$(runp "-" --target=hdd/store --config="$WORK/k5cov.conf")"
printf '%s' "$out2" | grep -q 'pominieto rpool/db -- juz objety' \
    && ok "krok5: a dataset the installed config already covers is skipped, naming the section" \
    || bad "krok5: a dataset the installed config already covers is skipped" "$(printf '%s' "$out2"|grep pominieto|head -5)"

# ---- "already covered" is EXACT identity, because a local job is FLAT -------
# An installed [dataset:rpool/a] copies rpool/a's own blocks and nothing else.
# Testing coverage with path overlap therefore hid a new child under an
# installed parent as "already covered" -- the same silent missing coverage as
# the hierarchy finding, arrived at from the other side. Both arrangements are
# pinned, because a containment test excuses one of them whichever way it runs.
printf '[defaults]\n\thost_label = t\n\n[dataset:rpool/a]\n\tuse_template = x\n' > "$WORK/k5par.conf"
outp="$(runp "rpool/a
rpool/a/child" --target=hdd/store --config="$WORK/k5par.conf")"
{ ! printf '%s' "$outp" | grep -q 'pominieto rpool/a/child -- juz objety'; } \
    && ok "krok5/flat: a NEW CHILD under an installed flat parent is not called 'already covered'" \
    || bad "krok5/flat: a new child under an installed flat parent is not 'already covered'" "$(printf '%s' "$outp"|grep pominieto|head -4)"
printf '[defaults]\n\thost_label = t\n\n[dataset:rpool/a/child]\n\tuse_template = x\n' > "$WORK/k5chi.conf"
outc2="$(runp "rpool/a
rpool/a/child" --target=hdd/store --config="$WORK/k5chi.conf")"
{ ! printf '%s' "$outc2" | grep -q 'pominieto rpool/a -- juz objety'; } \
    && ok "krok5/flat: a PARENT candidate is not called 'already covered' by an installed child" \
    || bad "krok5/flat: a parent candidate is not 'already covered' by an installed child" "$(printf '%s' "$outc2"|grep pominieto|head -4)"
# CONTROL: a section that really IS recursive does cover its descendants, and
# saying so must still work -- otherwise the two assertions above would pass
# against a build that had simply dropped the covered check.
printf '[defaults]\n\thost_label = t\n\n[dataset:rpool/a]\n\tuse_template = x\n\trecursive    = yes\n' > "$WORK/k5rec.conf"
outr="$(runp "rpool/a
rpool/a/child" --target=hdd/store --config="$WORK/k5rec.conf")"
printf '%s' "$outr" | grep -q 'pominieto rpool/a/child -- juz objety rekurencyjna' \
    && ok "krok5/flat control: a RECURSIVE installed section does cover its descendants" \
    || bad "krok5/flat control: a recursive installed section covers its descendants" "$(printf '%s' "$outr"|grep pominieto|head -4)"

# ---- THE HIERARCHY DISCRIMINATOR -------------------------------------------
# The first cut of the proposal dropped any dataset that had a child and offered
# the children instead. A parent filesystem holds its OWN files independently of
# its children, so that turned apparent coverage into silent missing coverage --
# and this suite encoded it as expected behaviour, so it went green over a real
# hole. What follows is the discriminator that hole would not survive: a parent
# with a child must NOT vanish from the proposed coverage without the operator
# being told.
outh="$(runp "rpool/a
rpool/a/child
rpool/db" --target=hdd/store --config="$WORK/k5h.conf")"
# 1. the ambiguous subtree is refused, with the pair named
{ printf '%s' "$outh" | grep -q 'poddrzewo dwuznaczne' \
  && printf '%s' "$outh" | grep -q 'rpool/a  ->  rpool/a/child'; } \
    && ok "krok5/hierarchia: a parent/child pair is refused as an ambiguous subtree, named" \
    || bad "krok5/hierarchia: a parent/child pair is refused as an ambiguous subtree" "$(printf '%s' "$outh"|head -10)"
# 2. BOTH members leave the proposal. The parent alone would be the original
#    defect; the children alone would be the same claim in the other direction.
{ ! printf '%s' "$outh" | grep -qE '^>>>   rpool/a$' \
  && ! printf '%s' "$outh" | grep -qE '^>>>   rpool/a/child$'; } \
    && ok "krok5/hierarchia: neither the parent nor the child is proposed as if it covered the other" \
    || bad "krok5/hierarchia: neither the parent nor the child is proposed" "$(printf '%s' "$outh"|grep '>>>   '|head -5)"
# 3. the parent is NAMED -- it may not disappear without the operator being told,
#    which is the whole finding, and the explanation must be actionable.
{ printf '%s' "$outh" | grep -q -- '--source=rpool/a$' \
  && printf '%s' "$outh" | grep -q 'NIE pokrywaja'; } \
    && ok "krok5/hierarchia: the parent is named with a copyable --source= and the reason why" \
    || bad "krok5/hierarchia: the parent is named with a copyable --source=" "$(printf '%s' "$outh"|head -10)"
# 4. the REST of the host is still proposed -- one hierarchy says nothing about
#    the datasets outside it, so refusing everything would be its own defect.
printf '%s' "$outh" | grep -qE '^>>>   rpool/db$' \
    && ok "krok5/hierarchia: datasets outside the ambiguous subtree are still proposed" \
    || bad "krok5/hierarchia: datasets outside the ambiguous subtree are still proposed" "$(printf '%s' "$outh"|grep '>>>   '|head -5)"
# 5. CONTROL: the same inventory without the child proposes the parent happily,
#    so the refusal keys on the PAIR and not on the name or on some other rule.
outc="$(runp "rpool/a
rpool/db" --target=hdd/store --config="$WORK/k5i.conf")"
{ printf '%s' "$outc" | grep -q 'PROPOZYCJA z inwentarza' \
  && printf '%s' "$outc" | grep -qE '^>>>   rpool/a$'; } \
    && ok "krok5/hierarchia control: without the child, the same parent IS proposed" \
    || bad "krok5/hierarchia control: without the child, the same parent IS proposed" "$(printf '%s' "$outc"|head -6)"

# ---- nothing sensible left: refuse, and say what to do ---------------------
out3="$(runp "rpool
rpool/swap" --target=hdd/store --config="$WORK/k5b.conf")"
{ printf '%s' "$out3" | grep -q 'nothing on this host is a sensible candidate' \
  && printf '%s' "$out3" | grep -q -- '--source='; } \
    && ok "krok5: an inventory with no candidate refuses and names the flag to use" \
    || bad "krok5: an inventory with no candidate refuses and names the flag to use" "$(printf '%s' "$out3"|tail -3)"

# ---- EXPLICIT-SOURCE-BEATS-DISCOVERY: a named source is never second-guessed -
out4="$(runp "-" --source=rpool/db --target=hdd/store --config="$WORK/k5c.conf")"
{ printf '%s' "$out4" | grep -qv 'PROPOZYCJA z inwentarza' \
  && ! printf '%s' "$out4" | grep -q 'rpool/a/child'; } \
    && ok "krok5: an explicit --source is used as given -- no proposal is consulted" \
    || bad "krok5: an explicit --source is used as given" "$(printf '%s' "$out4"|head -6)"

# ---- the acceptance gate: a PROPOSED set never installs unattended ----------
rm -f "$WORK/crontab-writes"
out5="$(runp "-" --target=hdd/store --config="$WORK/k5d.conf" --install --yes)"
{ printf '%s' "$out5" | grep -q 'cannot confirm a source set this run PROPOSED' \
  && [ ! -f "$WORK/crontab-writes" ]; } \
    && ok "krok5: --yes cannot confirm a PROPOSED source set, and nothing is installed" \
    || bad "krok5: --yes cannot confirm a PROPOSED source set" "$(printf '%s' "$out5"|tail -3)" "writes: $(cat "$WORK/crontab-writes" 2>/dev/null)"

# ---- the discriminating control: the gate keys on PROVENANCE, not on --yes --
# Without this, the assertion above would pass just as well against a build that
# refused every --yes install, which is a different (and wrong) behaviour.
rm -f "$WORK/crontab-writes"
out6="$(runp "-" --source=rpool/db --target=hdd/store --config="$WORK/k5e.conf" --install --yes)"
printf '%s' "$out6" | grep -q 'cannot confirm a source set this run PROPOSED' \
    && bad "krok5 control: a NAMED source set is still allowed to install under --yes" \
           "the proposal gate fired on an explicit --source" \
    || ok "krok5 control: a NAMED source set is still allowed to install under --yes"

# ==============================================================================
# KROK 5 -- the two blockers this path was measured to have, and the two
# refusals that must survive fixing them.
#
# Both blockers were the same omission: every section local-backup writes opens
# with a "# managed-by: zfs-backup.sh local-backup <kind>=<value>" marker, and
# nothing read it back. So the tool's own [prune:<target>] from the first run
# looked exactly like a stranger's coverage -- which made a second source
# unaddable, and made repeating the identical successful command a FATAL
# instead of a no-op.
#
# The refusals are the other half and are asserted here too: reading our own
# marker must not turn into trusting any section that happens to sit at the
# same path.
# ==============================================================================
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg

# ---- first install, so there is something to repeat and to extend ----------
out="$(runi snapsend-ok "" --source=rpool/data --target=hdd/backups --config="$CFG" --install --yes)"
{ printf '%s' "$out" | grep -q 'Backup lokalny AKTYWNY' && grep -qxF '[dataset:rpool/data]' "$CFG"; } \
    && ok "krok5/blocker: the first install lands (precondition)" \
    || bad "krok5/blocker: the first install lands (precondition)" "$(printf '%s' "$out"|tail -4)"

# ---- BLOCKER 1: the identical command repeats as a clean no-op -------------
seeds_before="$(wc -l < "$WORK/seed-calls" 2>/dev/null || echo 0)"
writes_before="$(wc -l < "$WORK/crontab-writes" 2>/dev/null || echo 0)"
cfg_before="$(md5sum < "$CFG")"
out="$(runi snapsend-ok "" --source=rpool/data --target=hdd/backups --config="$CFG" --install --yes)"; rc=$?
seeds_after="$(wc -l < "$WORK/seed-calls" 2>/dev/null || echo 0)"
writes_after="$(wc -l < "$WORK/crontab-writes" 2>/dev/null || echo 0)"
cfg_after="$(md5sum < "$CFG")"
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'JUZ AKTYWNY'; } \
    && ok "krok5/blocker1: the identical successful command repeats with rc=0, not a FATAL overlap" \
    || bad "krok5/blocker1: the identical successful command repeats with rc=0" "rc=$rc $(printf '%s' "$out"|tail -3)"
# A no-op that re-seeds or rewrites cron is not a no-op: it takes a fresh
# snapshot and reinstalls a running relationship's jobs.
{ [ "$seeds_after" = "$seeds_before" ] && [ "$writes_after" = "$writes_before" ] && [ "$cfg_after" = "$cfg_before" ]; } \
    && ok "krok5/blocker1: the no-op seeds nothing, writes no crontab and leaves the config byte-identical" \
    || bad "krok5/blocker1: the no-op changes nothing" \
           "seeds $seeds_before->$seeds_after writes $writes_before->$writes_after cfg $([ "$cfg_after" = "$cfg_before" ] && echo same || echo CHANGED)"

# ---- BLOCKER 2: a second source may join the same tool-managed target ------
out="$(runi snapsend-ok "" --source=rpool/other --target=hdd/backups --config="$CFG" --install --yes)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -qxF '[dataset:rpool/data]' "$CFG" && grep -qxF '[dataset:rpool/other]' "$CFG"; } \
    && ok "krok5/blocker2: a second source joins the same managed target, the first one surviving" \
    || bad "krok5/blocker2: a second source joins the same managed target" "rc=$rc $(printf '%s' "$out"|tail -4)"
# The target's retention is emitted once per TARGET, not once per run: a second
# copy is a duplicate section gen-cron refuses, and it would discard whatever
# the operator had edited into the first.
{ [ "$(grep -cxF '[prune:hdd/backups]' "$CFG")" -eq 1 ] \
  && [ "$(grep -cE '^\[template:profile__default__src_keep_hourly\]' "$CFG")" -eq 1 ]; } \
    && ok "krok5/blocker2: the target prune and the source template family stay single" \
    || bad "krok5/blocker2: the target prune and the source template family stay single" \
           "prune=$(grep -cxF '[prune:hdd/backups]' "$CFG") tmpl=$(grep -cE '^\[template:profile__default__src_keep_hourly\]' "$CFG")"
# The mixed request -- what an operator actually types when adding one source to
# a set: name them all, and let the tool work out which is new. The installed
# one must be reported as left alone rather than counted as seeded, and it must
# not be seeded again.
seeds_before="$(wc -l < "$WORK/seed-calls" 2>/dev/null || echo 0)"
out="$(runi snapsend-ok "" --source=rpool/data,rpool/other,rpool/vmstore --target=hdd/backups --config="$CFG" --install --yes)"; rc=$?
seeds_after="$(wc -l < "$WORK/seed-calls" 2>/dev/null || echo 0)"
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'Juz bylo' \
  && printf '%s' "$out" | grep -q 'rpool/data'; } \
    && ok "krok5/blocker2: a mixed request names the sources it left alone instead of claiming it seeded them" \
    || bad "krok5/blocker2: a mixed request names the sources it left alone" "rc=$rc $(printf '%s' "$out"|tail -6)"
# Exactly ONE new seed (rpool/vmstore); the two already installed are untouched.
[ "$((seeds_after - seeds_before))" -eq 1 ] \
    && ok "krok5/blocker2: only the genuinely new source is seeded, the installed ones are not" \
    || bad "krok5/blocker2: only the genuinely new source is seeded" "seeds $seeds_before -> $seeds_after"

# ---- F3: flat parent/child, END TO END ------------------------------------
# Teaching only the PROPOSAL that a flat job covers exactly its own dataset
# produced a false green: discovery would offer a child under an installed flat
# parent, and the composition gate would then refuse the very candidate it had
# just proposed. The rule has to hold at both ends, so these assert the whole
# run -- exit code, installed CONFIG, the pre-existing job surviving, the new
# job present, and the cron actually covering both -- not the absence of a
# phrase.
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
out="$(runi snapsend-ok "" --source=rpool/a --target=hdd/backups --config="$CFG" --install --yes)"
out="$(runi snapsend-ok "" --source=rpool/a/child --target=hdd/backups --config="$CFG" --install --yes)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -qxF '[dataset:rpool/a]' "$CFG" && grep -qxF '[dataset:rpool/a/child]' "$CFG"; } \
    && ok "krok5/F3: a new CHILD joins an installed flat parent as its own job" \
    || bad "krok5/F3: a new child joins an installed flat parent" "rc=$rc $(printf '%s' "$out"|tail -4)"
blk="$(cat "$WORK/crontab-store" 2>/dev/null)"
{ printf '%s' "$blk" | grep -qE 'snapsend\.sh[^;]*"rpool/a"' \
  && printf '%s' "$blk" | grep -qE 'snapsend\.sh[^;]*"rpool/a/child"'; } \
    && ok "krok5/F3: the installed cron covers BOTH the parent and the child" \
    || bad "krok5/F3: the installed cron covers both" "$(printf '%s' "$blk" | grep -oE 'snapsend\.sh[^;]*' | head -3)"

# The mirror arrangement: installed child, parent discovered later.
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
out="$(runi snapsend-ok "" --source=rpool/a/child --target=hdd/backups --config="$CFG" --install --yes)"
out="$(runi snapsend-ok "" --source=rpool/a --target=hdd/backups --config="$CFG" --install --yes)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -qxF '[dataset:rpool/a]' "$CFG" && grep -qxF '[dataset:rpool/a/child]' "$CFG"; } \
    && ok "krok5/F3: a new PARENT joins an installed flat child as its own job" \
    || bad "krok5/F3: a new parent joins an installed flat child" "rc=$rc $(printf '%s' "$out"|tail -4)"

# And the refusal that must survive it: an installed section that really IS
# recursive does reach its descendants, so a child under it still collides.
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
printf '\n[dataset:rpool/a]\n\t# managed-by: zfs-backup.sh local-backup source=rpool/a\n\tuse_template = profile__default__standard_hourly\n\tdst          = hdd/backups\n\trecursive    = yes\n' >> "$CFG"
out="$(runi snapsend-ok "" --source=rpool/a/child --target=hdd/backups --config="$CFG" --install --yes)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'recursive'; } \
    && ok "krok5/F3: a child under a RECURSIVE installed section still refuses, naming why" \
    || bad "krok5/F3: a child under a recursive installed section still refuses" "rc=$rc $(printf '%s' "$out"|tail -3)"
seed_cfg

# ---- the refusals that must SURVIVE reading our own marker -----------------
# FOREIGN coverage at the same path is not ours, whatever it is called.
printf '\n[dataset:rpool/db]\n\tuse_template = whatever\n\tdst          = hdd/backups\n' >> "$CFG"
out="$(runi snapsend-ok "" --source=rpool/db --target=hdd/backups --config="$CFG" --install --yes)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'overlap'; } \
    && ok "krok5/refusal: an unmarked (foreign) section at the same path still refuses" \
    || bad "krok5/refusal: an unmarked (foreign) section at the same path still refuses" "rc=$rc $(printf '%s' "$out"|tail -3)"

# OURS, but pointing at a DIFFERENT target: a different request, not a rerun.
#
# Self-contained fixture on purpose. Leaning on whatever the previous
# assertions left in $CFG made this one refuse for an unrelated reason (a
# leftover section referencing a template that does not exist), which is a test
# passing on the wrong evidence -- and it only showed up once the cases around
# it were reordered.
seed_cfg
printf '\n[dataset:rpool/data]\n\t# managed-by: zfs-backup.sh local-backup source=rpool/data\n\tuse_template = profile__default__standard_hourly\n\tdst          = hdd/backups\n' >> "$CFG"
out="$(runi snapsend-ok "" --source=rpool/data --target=hdd/dokumenty --config="$CFG" --install --yes)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'overlap'; } \
    && ok "krok5/refusal: our own section with a different target still refuses (not a no-op)" \
    || bad "krok5/refusal: our own section with a different target still refuses" "rc=$rc $(printf '%s' "$out"|tail -3)"

# ==============================================================================
# The anti-deletion guard's second exemption: a MERGE is not a deletion.
#
# gen-cron merges datasets resolving to the same policy into one job line, so
# adding a second source rewrites the first source's line into a two-dataset
# one. The guard's rule -- "a line that vanishes is a job that stops" -- is a
# proxy for coverage, and on a merge the proxy is wrong: measured live on pve9,
# where adding a second local source was impossible for exactly this reason.
#
# The exemption is written against coverage, so it must hold in ONE direction
# only. These five cases are the whole contract, and three of them are the ways
# it could be got wrong.
# ==============================================================================
# absorbed <label> <lost line> <proposed line>   -- must be excused
# refused  <label> <lost line> <proposed line>   -- must NOT be excused
absorbed() { printf '%s\n' "$3" | line_coverage_absorbed "$2" \
    && ok "guard/merge: $1" || bad "guard/merge: $1" "not absorbed"; }
refused()  { printf '%s\n' "$3" | line_coverage_absorbed "$2" \
    && bad "guard/merge: $1" "absorbed, and must not have been" || ok "guard/merge: $1"; }

# Real generated shapes, redirect and all: a cron line carries quoted values
# that are NOT arguments (the stderr redirect, the notify message), and the
# first cut of the exemption counted from the end of the whole line -- which
# made it excuse a widened TARGET and refuse a widened SOURCE, exactly
# backwards. These fixtures keep that wrapper so the position logic is
# exercised the way it runs.
SND_A='1 * * * * snapsend.sh -m "automated_hourly_" "hdd/a" "hdd/store" 2>"$e"; rc=$?'
SND_AB='1 * * * * snapsend.sh -m "automated_hourly_" "hdd/a,hdd/b" "hdd/store" 2>"$e"; rc=$?'
MON_A='*/15 * * * * d=$(check-snap-age.sh "hdd/a" "automated_hourly" 90m 150m 2>&1); rc=$?'
DEL_A='21 * * * * delsnaps.sh -G -P "vzdump:2" "hdd/a" "automated_" -H24 2>"$e"; rc=$?'

absorbed "a widened SOURCE list absorbs the send line it replaced" "$SND_A" "$SND_AB"
absorbed "a widened dataset list absorbs the monitor line it replaced" "$MON_A" \
    '*/15 * * * * d=$(check-snap-age.sh "hdd/a,hdd/b" "automated_hourly" 90m 150m 2>&1); rc=$?'
absorbed "a widened SCOPE absorbs the prune line it replaced" "$DEL_A" \
    '21 * * * * delsnaps.sh -G -P "vzdump:2" "hdd/a,hdd/b" "automated_" -H24 2>"$e"; rc=$?'

# The exemption is bound to the DATASET argument. Set inclusion anywhere else
# proves nothing about coverage, and these are the four ways it could pretend to.
refused "a widened TARGET must not absorb a lost send line" "$SND_A" \
    '1 * * * * snapsend.sh -m "automated_hourly_" "hdd/a" "hdd/store,hdd/other" 2>"$e"; rc=$?'
refused "a widened PREFIX must not absorb a lost send line" "$SND_A" \
    '1 * * * * snapsend.sh -m "automated_hourly_,automated_daily_" "hdd/a" "hdd/store" 2>"$e"; rc=$?'
refused "a widened PATTERN must not absorb a lost monitor line" "$MON_A" \
    '*/15 * * * * d=$(check-snap-age.sh "hdd/a" "automated_hourly,automated_daily" 90m 150m 2>&1); rc=$?'
refused "a widened reserved-family list must not absorb a lost prune line" "$DEL_A" \
    '21 * * * * delsnaps.sh -G -P "vzdump:2,other:2" "hdd/a" "automated_" -H24 2>"$e"; rc=$?'

# ...and the shape has to be one this function can actually read.
refused "an unrecognised command gets no exemption at all" \
    '1 * * * * cudze.sh "hdd/a" "x"' '1 * * * * cudze.sh "hdd/a,hdd/b" "x"'
refused "a line that is simply gone is still a DELETION" "$SND_A" \
    '1 * * * * something else entirely'
# The dangerous direction: coverage SHRINKING must never be excused, and a
# subset test applied the wrong way round is exactly how it would be.
refused "a SHRINKING dataset list is still a deletion" "$SND_AB" "$SND_A"
refused "a changed threshold is a different job, not a merged one" "$MON_A" \
    '*/15 * * * * d=$(check-snap-age.sh "hdd/a,hdd/b" "automated_hourly" 30m 150m 2>&1); rc=$?'
refused "a changed schedule is a different job, not a merged one" "$MON_A" \
    '*/5 * * * * d=$(check-snap-age.sh "hdd/a,hdd/b" "automated_hourly" 90m 150m 2>&1); rc=$?'

# ==============================================================================
# THE DEFAULT PROFILE, HANDED TO THE SCRIPT EXPLICITLY.
#
# `--profile=default` and no --profile at all must produce the SAME deployment.
# Until the default was a named constant that could not be asserted: the literal
# "default" appeared in six places, so "what does a plain run do" was answered by
# grepping rather than by running.
#
# This is also the test that the default profile is CRYSTALLISED -- everything a
# plain deployment does is in the profile, nothing left hardwired beside it. The
# reserved-family floors were the last thing that was: a literal list in
# zfs-backup.sh, so the one policy every relationship on this estate runs under
# was the one policy the profile could not describe.
# ==============================================================================
plan_config() {   # <extra args...> -> the candidate CONFIG, normalised
    run "$@" 2>&1 \
        | sed -n '/--- kandydat CONFIG v4/,/--- wygenerowany blok crona/p' \
        | sed -E 's#/tmp/[A-Za-z0-9._]+#<TMP>#g'
}

imp="$(plan_config --source=rpool/data --target=hdd/backups --config="$WORK/id1.conf")"
exp="$(plan_config --source=rpool/data --target=hdd/backups --config="$WORK/id2.conf" --profile=default)"
if [ -n "$imp" ] && [ "$imp" = "$exp" ]; then
    ok "default: an explicit --profile=default renders the identical CONFIG to no flag at all"
else
    bad "default: an explicit --profile=default renders the identical CONFIG" \
        "$(diff <(printf '%s\n' "$imp") <(printf '%s\n' "$exp") | head -8)"
fi

# The floors are IN that config, and with the values the code used to hardwire.
# Without this the assertion above would pass just as well against a build that
# had stopped emitting them altogether -- identical, and identically wrong.
missing=""
for fam in __replicate_ vzdump __migration__; do
    printf '%s\n' "$imp" | grep -qF "[excluded:$fam]" || missing="$missing $fam"
done
if [ -z "$missing" ] && [ "$(printf '%s\n' "$imp" | grep -c 'keep = 2')" -ge 3 ]; then
    ok "default: the reserved families come from the PROFILE and keep the values the code used to hardwire"
else
    bad "default: the reserved families come from the profile with their values" \
        "brakuje:${missing:-nic} keep2=$(printf '%s\n' "$imp" | grep -c 'keep = 2')"
fi

# A profile that does NOT declare them gets no floors -- that is what "editable
# from the profile" means, and it is the half that proves the values are really
# being read rather than still hardwired somewhere.
NOFLOOR="$WORK/nofloor"
mkdir -p "$NOFLOOR/bare"
sed '/^\[excluded:/,$d' "$REPO/profiles/default.conf" > "$NOFLOOR/bare.conf"
bare="$( PROFILE_ROOT="$NOFLOOR" run --source=rpool/data --target=hdd/backups \
            --config="$WORK/id3.conf" --profile=bare 2>&1 )"
if printf '%s' "$bare" | grep -qF '[excluded:__replicate_]'; then
    bad "default: a profile that declares no reserved family gets no floor" \
        "the floors appeared anyway -- they are still coming from somewhere other than the profile"
else
    ok "default: a profile that declares no reserved family gets no floor (the values really come from the profile)"
fi

# ---- REV-20260901-132: --target='' plans snapshots AND their retention ------
#
# The no-copy shape refuses to be half a job. It must render the one-argument
# snapsend AND a bounded prune for the same family, and it must render neither
# a dst nor any target-side job -- a plan that creates snapshots and schedules
# nothing to remove them is an unbounded pool, quietly.
#
# Both profiles are checked because the retention lives in different places and
# suppressing the wrong one produced exactly that unbounded shape: `default`
# carries a [prune] fragment and its send tiers have no prune_schedule, while
# y5m12d31h24-gfs has no [prune] fragment and its tiers prune themselves.
for _p in default y5m12d31h24-gfs; do
    out="$( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" \
            bash "$ZB" --source=rpool/data --target='' --profile="$_p" --config="$WORK/nocopy-$_p.conf" 2>&1 )"; rc=$?
    _snap="$(printf '%s\n' "$out" | grep -cE 'snapsend\.sh .*"rpool/data"$')"
    _prune="$(printf '%s\n' "$out" | grep -cE 'delsnaps\.sh .*"rpool/data"')"
    if [ "$rc" -eq 0 ] && [ "$_snap" -ge 1 ] && [ "$_prune" -ge 1 ]; then
        ok "132/$_p: --target='' plans a one-argument snapshot AND its retention"
    else
        bad "132/$_p: --target='' plans a one-argument snapshot AND its retention" \
            "rc=$rc snapsend=$_snap delsnaps=$_prune"
    fi
    # ...and nothing that copies: no dst on the section this run writes, and no
    # target-side prune section, because there is no target to bound.
    if printf '%s\n' "$out" | sed -n '/^\[dataset:rpool\/data\]/,/^\[/p' | grep -q 'dst'; then
        bad "132/$_p: the no-copy section carries no dst" "$(printf '%s\n' "$out" | sed -n '/^\[dataset:rpool\/data\]/,/^\[/p')"
    else
        ok "132/$_p: the no-copy section carries no dst"
    fi
done

# ---- the same two profiles, WITH a target -----------------------------------
#
# The mirror of the block above, and the half that was never asked. Measured on
# pve9 2026-09-01 across the whole catalogue: 12 of 14 profiles could not create
# a local relationship with a target at all, `prod` and `d30` among them.
# [prune:<target>] pasted PROFILE_PRUNE_FILE verbatim, which is EMPTY for every
# profile whose tiers prune themselves, so the section carried no use_template
# and gen-cron refused the finished config:
#
#     error: [prune:hdd/backups] has no use_template
#
# Behind that refusal sat the doubling the refusal hid, which is why the second
# assertion is here and not left to the shape check: the source retention block
# ran whenever a target was given, so a fragment-less profile stated its source
# policy twice -- once through the tiers' own prune_schedule, once flat through
# the source family, the flat one undoing the ladder.
#
# ONE PRUNE PER SEND, ON THE SOURCE. That invariant holds for both profiles for
# different reasons (`default` prunes from its [prune] fragment, a ladder
# profile from its tiers), and it is the number the defect moved: 2 sends
# against 4 source prunes.
for _p in default y5m12d31h24-gfs; do
    out="$( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" \
            bash "$ZB" --source=rpool/data --target=hdd/backups --profile="$_p" --config="$WORK/tgt-$_p.conf" 2>&1 )"; rc=$?
    _snap="$(printf '%s\n' "$out" | grep -cE 'snapsend\.sh .*"rpool/data" "hdd/backups"')"
    _src="$(printf '%s\n'  "$out" | grep -cE 'delsnaps\.sh .*"rpool/data"')"
    _tgt="$(printf '%s\n'  "$out" | grep -cE 'delsnaps\.sh .*"hdd/backups"')"
    if [ "$rc" -eq 0 ] && [ "$_tgt" -ge 1 ]; then
        ok "target/$_p: a local relationship with a target renders, and bounds the store"
    else
        bad "target/$_p: a local relationship with a target renders, and bounds the store" \
            "rc=$rc target-prunes=$_tgt -- $(printf '%s\n' "$out" | grep -oE 'error:.*' | head -1)"
    fi
    if [ "$_snap" -ge 1 ] && [ "$_src" -eq "$_snap" ]; then
        ok "target/$_p: the source is pruned once per send tier, not twice"
    else
        bad "target/$_p: the source is pruned once per send tier, not twice" \
            "snapsend=$_snap source-prunes=$_src"
    fi
done

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
