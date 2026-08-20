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
# canonical comma-list: two independent [dataset:] entries, and the rendered cron
# carries both roots (gen-cron merges same-policy datasets into one comma-joined
# send, the established multi-dataset shape -- see fixtures/tiered.conf golden).
out="$(run --source=rpool/data,rpool/vmstore --target=hdd/backups --config="$WORK/mc.conf")"; rc=$?
if [ "$rc" -eq 0 ] \
        && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/data\]' \
        && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/vmstore\]' \
        && printf '%s\n' "$out" | grep -qE 'snapsend\.sh -m "automated_hourly_" "rpool/data,rpool/vmstore" "hdd/backups"'; then
    ok "101/comma-list: two independent source entries, both in the rendered cron"
else
    bad "101/comma-list: two independent source entries, both in the rendered cron" \
        "rc=$rc $(printf '%s\n' "$out" | grep -E '\[dataset|snapsend' | head)"
fi
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
sed 's/keep_/ret_/g' "$REPO/profiles/default/templates.conf" > "$WORK/profiles/custret/templates.conf"
cp "$REPO/profiles/default/dataset.inc"                        "$WORK/profiles/custret/dataset.inc"
sed 's/keep_/ret_/g' "$REPO/profiles/default/prune.inc"      > "$WORK/profiles/custret/prune.inc"
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
cat > "$UWORK/bin/crontab" <<EOF
#!/bin/sh
case " \$* " in
  *" -l "*) cat "$UWORK/tab" ;;
  *) cat > "$UWORK/tab" ;;
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
else
    bad "uninstall: --install --uninstall is refused before any lock is attempted" "rc=$rc4 out=$out4"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
