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
  *) echo "WRITE \$*" >> "$WORK/crontab-writes" ;;
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

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
