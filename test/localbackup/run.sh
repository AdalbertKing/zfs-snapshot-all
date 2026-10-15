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
. "$DIR/../harness.sh"   # product_fn
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

# X27 (owner 2026-10-14): every local copy is a named relationship -- a call that names
# none gets --name=lb here, and its record (if it installs) goes to a fresh directory
# unless the caller set CLIENTS_DIR, so a rerun is not "the name is taken".
lb_args() {   # args... -> LB_ARGS with --name=lb when none was given
    LB_ARGS=("$@")
    case " $* " in *" --name="*) ;; *) LB_ARGS+=(--name=lb) ;; esac
}
run() {   # cmd_local_backup args... ; stubbed PATH, no server.conf, real profiles
    lb_args "$@"
    ( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" \
      CLIENTS_DIR="${CLIENTS_DIR:-$(mktemp -d)}" \
      cmd_local_backup "${LB_ARGS[@]}" ) 2>&1
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
# X27 (2026-10-14): both sources are ONE relationship (one [relation:] block), so
# they ride one send line per tier -- the comma list is snapsend's own argument.
mc_both="$(printf '%s\n' "$out" | grep -cE 'snapsend\.sh -m "automated_hourly_" -L lb "rpool/data,rpool/vmstore" "hdd/backups"')"
if [ "$rc" -eq 0 ] \
        && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/data\]' \
        && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/vmstore\]' \
        && [ "$mc_both" -eq 1 ]; then
    ok "101/comma-list: two independent source entries, both in the rendered cron"
else
    bad "101/comma-list: two independent source entries, both in the rendered cron" \
        "rc=$rc $(printf '%s\n' "$out" | grep -E '\[dataset|snapsend' | head)"
fi
# The KROK 5 stagger (each local source on its own minute) is gone with X27: it
# kept one source's line stable when a SECOND, unnamed run added another. Now a
# source joins a relationship through add-source, which rewrites that
# relationship's own line on purpose, and another relationship is another block.
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
# X27: the source side is the [dataset:] section itself (its tiers prune the source,
# family per tier), the target side is the landing [prune:<target>/<source>].
if [ "$rc" -eq 0 ] \
        && printf '%s\n' "$out" | sed -n '/^\[dataset:rpool\/data\]/,/^\[/p' | grep -qE '^\s*side\s*=\s*source$' \
        && printf '%s\n' "$out" | sed -n '/^\[prune:hdd\/backups\/rpool\/data\]/,/^\[/p' | grep -qE '^\s*side\s*=\s*target$'; then
    ok "102/candidate carries BOTH a source side ([dataset:root]) and a target side ([prune:target/root])"
else
    bad "102/candidate carries BOTH a source side and a target side" \
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
# X27: one prune line per tier and side, each on its own family.
src_prune="$(printf '%s\n' "$out" | grep -cE 'delsnaps\.sh -G -L lb .*"rpool/data" "automated_(hourly" -H24|daily" -D7|weekly" -W4|monthly" -M12)')"
src_recursive="$(printf '%s\n' "$out" | grep -E 'delsnaps\.sh .*"rpool/data" "automated_' | grep -c -- ' -R ')"
tgt_prune="$(printf '%s\n' "$out" | grep -cE 'delsnaps\.sh -R -L lb .*"hdd/backups/rpool/data" "automated_(hourly" -H24|daily" -D7|weekly" -W4|monthly" -M12)')"
if [ "$src_prune" -eq 4 ] && [ "$tgt_prune" -eq 4 ]; then
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
if printf '%s\n' "$out" | grep -qE 'delsnaps\.sh -G .*"rpool/data" "automated_hourly"' \
        && ! printf '%s\n' "$out" | grep -qE 'delsnaps\.sh[^\n]*"rpool/data" "\*"'; then
    ok "102/source prune is bounded to automated_ -- manual snapshots survive"
else
    bad "102/source prune is bounded to automated_ -- manual snapshots survive" ""
fi
# each root gets its OWN source prune (multi-source), plus one target prune.
out="$(run --source=rpool/data,rpool/vmstore --target=hdd/backups --config="$WORK/retm.conf")"
if printf '%s\n' "$out" | grep -qE 'delsnaps\.sh -G .*"rpool/data" "automated_hourly"' \
        && printf '%s\n' "$out" | grep -qE 'delsnaps\.sh -G .*"rpool/vmstore" "automated_hourly"' \
        && printf '%s\n' "$out" | grep -q '^\[prune:hdd/backups/rpool/data\]' \
        && printf '%s\n' "$out" | grep -q '^\[prune:hdd/backups/rpool/vmstore\]'; then
    ok "102/each root gets its own source prune, and its own landing prune on the target"
else
    bad "102/each root gets its own source prune, plus one target prune" \
        "$(printf '%s\n' "$out" | grep -E '^\[prune:' | tr '\n' ' ')"
fi

# ---- REV-20260811-104 F1: source and target retention are INDEPENDENT policies ----
# X27: one [relation:] block holds both sides. A value common to both is one field
# (`monthly.retain`); a side-specific one is `monthly.source_retain` /
# `monthly.target_retain`. Editing one side must move that side only.
# (REV-106, "the split must not depend on keep_* template names", is moot: the
# block names its sides explicitly, nothing is derived from a template name.)
out="$(run --source=rpool/data --target=hdd/backups --config="$WORK/ind.conf")"
printf '%s\n' "$out" | sed -n '/^--- kandydat CONFIG v4/,/^--- wygenerowany/p' | sed '1d;$d' > "$WORK/ind-cand.conf"
lb_render_retain() {  # <config> <scope> -> the -M value on that scope's monthly prune line
    env -u REPO_DIR -u NOTIFY_SCRIPT -u WARN_SCRIPT -u DIGEST_SCRIPT -u CRON_LOG -u DIGEST_SCHEDULE \
        bash "$GEN" -c "$1" 2>/dev/null | grep -oE "\"$2\" \"automated_monthly\" -M[0-9]+" | grep -oE 'M[0-9]+' | head -1
}
GEN="$REPO/gen-cron.sh"
if grep -qE '^\s*monthly\.retain\s*=\s*-M12$' "$WORK/ind-cand.conf" \
   && [ "$(lb_render_retain "$WORK/ind-cand.conf" 'rpool/data')" = "M12" ] \
   && [ "$(lb_render_retain "$WORK/ind-cand.conf" 'hdd/backups/rpool/data')" = "M12" ]; then
    ok "104 F1/both sides start from the profile's retention, as one common field"
else
    bad "104 F1/both sides start from the profile's retention" \
        "$(grep -E 'monthly\.' "$WORK/ind-cand.conf")"
fi
lb_side_retain() {  # <side> <value> -> the candidate with monthly split, that side at <value>
    local other; [ "$1" = source ] && other=target || other=source
    sed -E "s/^(\s*)monthly\.retain(\s*)=.*/\1monthly.$1_retain = $2\n\1monthly.${other}_retain = -M12/" "$WORK/ind-cand.conf"
}
lb_side_retain source -M36 > "$WORK/mut-src.conf"
if [ "$(lb_render_retain "$WORK/mut-src.conf" 'rpool/data')" = "M36" ] \
        && [ "$(lb_render_retain "$WORK/mut-src.conf" 'hdd/backups/rpool/data')" = "M12" ]; then
    ok "104 F1/editing only SOURCE retention changes SOURCE, leaves TARGET unchanged"
else
    bad "104 F1/editing only SOURCE retention changes SOURCE, leaves TARGET unchanged" \
        "src=$(lb_render_retain "$WORK/mut-src.conf" 'rpool/data') tgt=$(lb_render_retain "$WORK/mut-src.conf" 'hdd/backups/rpool/data')"
fi
lb_side_retain target -M60 > "$WORK/mut-tgt.conf"
if [ "$(lb_render_retain "$WORK/mut-tgt.conf" 'hdd/backups/rpool/data')" = "M60" ] \
        && [ "$(lb_render_retain "$WORK/mut-tgt.conf" 'rpool/data')" = "M12" ]; then
    ok "104 F1/editing only TARGET retention changes TARGET, leaves SOURCE unchanged"
else
    bad "104 F1/editing only TARGET retention changes TARGET, leaves SOURCE unchanged" \
        "tgt=$(lb_render_retain "$WORK/mut-tgt.conf" 'hdd/backups/rpool/data') src=$(lb_render_retain "$WORK/mut-tgt.conf" 'rpool/data')"
fi
# negative control: the COMMON field is what couples them -- edit it and both move.
sed -E 's/^(\s*monthly\.retain\s*=\s*)-M12$/\1-M36/' "$WORK/ind-cand.conf" > "$WORK/shared-mut.conf"
if [ "$(lb_render_retain "$WORK/shared-mut.conf" 'rpool/data')" = "M36" ] \
        && [ "$(lb_render_retain "$WORK/shared-mut.conf" 'hdd/backups/rpool/data')" = "M36" ]; then
    ok "104 F1/negctl: the common field couples both sides (why the split fields matter)"
else
    bad "104 F1/negctl: the common field couples both sides" \
        "src=$(lb_render_retain "$WORK/shared-mut.conf" 'rpool/data') tgt=$(lb_render_retain "$WORK/shared-mut.conf" 'hdd/backups/rpool/data')"
fi

# ---- F2: additive composition over an existing config ----
# The existing relationship A is a real one, planned by this command (X27: a hand-
# written section would need a block, and copying the block shape here would be a
# second author of it).
out="$(run --name=inna --source=rpool/other --target=hdd/backups/other --profile=d7h24 --config="$WORK/existing-src.conf")"
printf '%s\n' "$out" | sed -n '/^--- kandydat CONFIG v4/,/^--- wygenerowany/p' | sed '1d;$d' > "$WORK/existing.conf"
cp "$WORK/existing.conf" "$WORK/existing.orig"
a_before="$(sed -n '/^\[relation:inna\]/,$p' "$WORK/existing.conf")"
out="$(run --source=rpool/data --target=hdd/store --config="$WORK/existing.conf")"; rc=$?
a_after="$(printf '%s\n' "$out" | sed -n '/^--- kandydat CONFIG v4/,/^--- wygenerowany/p' | sed -n '/^\[relation:inna\]/,/^\[relation:lb\]/p' | sed '$d')"
if [ "$rc" -eq 0 ] && [ -n "$a_before" ] && [ "$(printf '%s' "$a_before" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')" = "$(printf '%s' "$a_after" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')" ] \
        && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/data\]'; then
    ok "F2/additive: existing A is byte-unchanged and B is added"
else
    bad "F2/additive: existing A is byte-unchanged and B is added" "rc=$rc" "$(diff <(printf '%s\n' "$a_before") <(printf '%s\n' "$a_after") | head -6)"
fi
# the rendered cron carries BOTH jobs (add B, do not lose A)
sends="$(printf '%s\n' "$out" | grep -oE 'snapsend\.sh -m "automated_hourly_" -L (inna|lb) "rpool/(other|data)"' | sort -u | wc -l)"
[ "$sends" -eq 2 ] && ok "F2/rendered cron carries both A and B send lines" \
    || bad "F2/rendered cron carries both A and B send lines" "distinct sends=$sends"
# the real target CONFIG on disk was not touched
cmp -s "$WORK/existing.conf" "$WORK/existing.orig" \
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
[template:multi_hourly]
	prune_schedule = 21 * * * *
	pattern        = automated_hourly
	retain         = -H24
[prune:rpool/other,rpool/data]
	# managed-by: zfs-backup.sh local-backup source=multi
	use_template = multi_hourly
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
        CLIENTS_DIR="$(mktemp -d)" bash "$ZB" --source=rpool/data --target=hdd/backups --name=lb --config="$WORK/bare.conf" 2>&1 )"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^\[dataset:rpool/data\]'; } \
    && ok "F3/bare --source/--target reaches the planning logic" || bad "F3/bare --source/--target reaches the planning logic" "rc=$rc"
# the alias still works too
out="$( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" \
        CLIENTS_DIR="$(mktemp -d)" bash "$ZB" local-backup --name=lb --source=rpool/data --target=hdd/backups --config="$WORK/alias.conf" 2>&1 )"; rc=$?
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
    lb_args "$@"
    ( PATH="$WORK/bin2:$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" \
      SNAPSEND="$WORK/seedbin/$stub" CLIENTS_DIR="${CLIENTS_DIR:-$(mktemp -d)}" \
      cmd_local_backup "${LB_ARGS[@]}" ) <<< "$answer" 2>&1
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

# ---- A' seed: --recursive reaches the FIRST snapshot too ----------------------
# Measured on pve9 2026-09-25: the cron lines had -R, the install-time seed did
# not, so the first snapshots landed on the roots only. `--yes` is refused with
# --target='' (confirmed by eye), so the answer comes on stdin.
for _r in flat:-R atomic:-r; do
    rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
    out="$(runi snapsend-ok "t" --install --source=rpool/data --target='' --recursive="${_r%%:*}" --config="$CFG")"
    if grep -qE -- "-m automated_hourly_ .* ${_r#*:} rpool/data\$" "$WORK/seed-calls" 2>/dev/null; then
        ok "A'/seed: --recursive=${_r%%:*} seeds with ${_r#*:}, like the installed line"
    else
        bad "A'/seed: --recursive=${_r%%:*} seeds with ${_r#*:}, like the installed line" "calls=$(cat "$WORK/seed-calls" 2>/dev/null) :: $(printf '%s' "$out" | tail -3)"
    fi
done

# ---- multi-root: one seed per source, still one install ----------------------
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
out="$(runi snapsend-ok "t" --install --yes --source=rpool/data,rpool/db --target=hdd/backups --config="$CFG")"
# `grep -c` prints 0 AND exits 1 on no match, so an `|| echo 0` fallback appends
# a SECOND zero and the arithmetic test dies on "0\n0". Count the lines instead.
{ [ "$({ grep -c SEED "$WORK/seed-calls" 2>/dev/null; true; } | head -1)" = 2 ] && grep -q INSTALL "$WORK/order" 2>/dev/null; } \
    && ok "slice2: two sources seed twice and install once" \
    || bad "slice2: two sources seed twice and install once" "$(cat "$WORK/seed-calls" 2>/dev/null)"

# ---- LOCAL RELATIONSHIP: --name (owner, 2026-10-09) --------------------------
# A copy on this host as a relationship like any other: sections carry
# pair_label (-L, the pause gate), each source has its own landing prune at
# <target>/<source>, the tree is copied with -R and the exclusion, the seed does
# the same, and a record with RUX_MODE=local names the COPIES as managed.
LC="$WORK/lclients"; rm -rf "$LC"
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
# X27: a named relationship is a [relation:] block; the ladder `default` has no block
# shape (owner 2026-10-14: every tier makes and counts its own), so a flat profile here.
out="$(CLIENTS_DIR="$LC" runi snapsend-ok "t" --install --yes --source=rpool/data --target=hdd/backups --recursive=flat --exclude-child='^rpool/data/vm-9$' --name=lok --profile=d7h24 --config="$CFG")"
rec="$LC/lok.conf"
# The record and the installed sections need the install, and the install needs
# flock (the crontab writer). Same rule as the uninstall cases below.
if ! command -v flock >/dev/null 2>&1; then
    echo "SKIP local relationship: record / sections / name taken (no flock on this machine -- the install needs it)"
else
if [ -f "$rec" ] && grep -qx 'RUX_MODE=local' "$rec" && grep -qx 'STATE=active' "$rec" \
   && grep -qx 'MANAGED_DATASETS=hdd/backups/rpool/data' "$rec" && grep -qx 'REQUESTED_DATASETS=rpool/data' "$rec" \
   && grep -qx 'CLIENT_TARGET=hdd/backups' "$rec" && ! grep -q '^PEER_HOST' "$rec"; then
    ok "local relationship: --name writes a record -- mode local, the COPY as managed, no peer"
else
    bad "local relationship: record" "$(cat "$rec" 2>/dev/null)" "$(printf '%s' "$out" | tail -4)"
fi
sec_ds="$(awk '/^\[dataset:rpool\/data\]/{f=1;next} /^\[/{f=0} f' "$CFG")"
sec_pr="$(awk '/^\[prune:hdd\/backups\/rpool\/data\]/{f=1;next} /^\[/{f=0} f' "$CFG")"
if printf '%s' "$sec_ds" | grep -qE '^\s*pair_label\s*=\s*lok$' && printf '%s' "$sec_ds" | grep -qE '^\s*recursive\s*=\s*flat$' \
   && printf '%s' "$sec_ds" | grep -qF 'exclude_child_1 = ^rpool/data/vm-9$' \
   && printf '%s' "$sec_pr" | grep -qE '^\s*pair_label\s*=\s*lok$' && ! grep -qxF '[prune:hdd/backups]' "$CFG"; then
    ok "local relationship: the sections carry pair_label, -R and the exclusion; the landing prune is <target>/<source>, not the whole target"
else
    bad "local relationship: sections" "$sec_ds" "$sec_pr"
fi
if grep -qE -- '-m automated_hourly_ .*-R -X \^rpool/data/vm-9\$ rpool/data hdd/backups$' "$WORK/seed-calls" 2>/dev/null; then
    ok "local relationship: the seed copies the tree with the same -R and -X as the installed line"
else
    bad "local relationship: seed" "$(cat "$WORK/seed-calls" 2>/dev/null)"
fi
out="$(CLIENTS_DIR="$LC" runi snapsend-ok "t" --install --yes --source=rpool/db --target=hdd/backups --name=lok --profile=d7h24 --config="$CFG")"
printf '%s' "$out" | grep -q "relationship 'lok' already exists on this host" \
    && ok "local relationship: a second --name=lok is refused while the first is live" \
    || bad "local relationship: name taken" "$(printf '%s' "$out" | tail -3)"
fi   # flock present
# Each refusal below on a fresh config: the install above left lok's sections in
# $CFG, and an overlap refusal would hide the one these cases are about.
# (--name with --target='' was refused until X27; a named snapshots-only
# relationship is the normal shape now -- see "named snapshots-only" below.)
rm -f "$WORK/crontab-store"; seed_cfg
out="$(CLIENTS_DIR="$LC" runi snapsend-ok "t" --source=rpool/data --target=hdd/backups --exclude-child='^x$' --config="$CFG")"
printf '%s' "$out" | grep -q -- '--exclude-child needs --recursive=flat' \
    && ok "local relationship: --exclude-child without --recursive=flat is refused" \
    || bad "local relationship: exclusion without recursion" "$(printf '%s' "$out" | tail -3)"

# remove_local_relation: only sections with BOTH the local-backup marker and
# pair_label = <name> go; another local relationship's and a hand-written one
# that merely borrows the label stay. The record is closed, the copies stay.
RL="$WORK/rmlocal"; rm -rf "$RL"; mkdir -p "$RL/clients"
cat > "$RL/c.conf" <<'EOF'
[defaults]
	host_label = t
[dataset:rpool/data]
	# managed-by: zfs-backup.sh local-backup source=rpool/data
	dst = hdd/backups
	pair_label   = lok
[prune:hdd/backups/rpool/data]
	# managed-by: zfs-backup.sh local-backup target=hdd/backups/rpool/data
	pair_label   = lok
[dataset:rpool/db]
	# managed-by: zfs-backup.sh local-backup source=rpool/db
	dst = hdd/backups
	pair_label   = other
[dataset:tank/hand]
	dst = hdd/backups
	pair_label = lok
EOF
printf 'CLIENT_NAME=lok\nRUX_MODE=local\nSTATE=active\nMANAGED_DATASETS=hdd/backups/rpool/data\nCRON_CONFIG=%s\n' "$RL/c.conf" > "$RL/clients/lok.conf"
out="$( ( CLIENTS_DIR="$RL/clients" RELATIONSHIPS_DIR="$RL/rel"
          assert_cron_config_matches_installed() { :; }; assert_no_foreign_managed_block() { :; }
          gencron_as_target() { :; }; atomic_replace_and_install() { cp "$2" "$1"; }
          cmd_remove_client lok ) 2>&1 )"
if ! grep -qxF '[dataset:rpool/data]' "$RL/c.conf" && ! grep -qxF '[prune:hdd/backups/rpool/data]' "$RL/c.conf" \
   && grep -qxF '[dataset:rpool/db]' "$RL/c.conf" && grep -qxF '[dataset:tank/hand]' "$RL/c.conf" \
   && grep -qx 'STATE=removed' "$RL/clients/lok.conf" && ! printf '%s' "$out" | grep -q 'unpair'; then
    ok "local relationship: remove-client takes only its own marked + labelled sections, closes the record, never unpairs"
else
    bad "local relationship: remove-client" "$out" "$(cat "$RL/c.conf")"
fi
# X2 (owner 2026-10-12): set-transfer refuses --compression for a LOCAL relationship,
# as it refuses --cipher -- the engine drops compression when the target is local.
# Control: --history is not refused for that reason.
printf 'CLIENT_NAME=x2\nRUX_MODE=local\nSTATE=active\nCLIENT_TARGET=hdd/backups\nREQUESTED_DATASETS=rpool/a\n' > "$RL/clients/x2.conf"
x2c=$( ( CLIENTS_DIR="$RL/clients"; cmd_set_transfer x2 --compression=zstd ) 2>&1 ); x2r=$?
x2h=$( ( CLIENTS_DIR="$RL/clients"; cmd_set_transfer x2 --history=newest ) 2>&1 )
if [ "$x2r" -ne 0 ] && printf '%s' "$x2c" | grep -qF "'x2' is a LOCAL copy -- there is no link, so --compression has nothing to act on"    && ! printf '%s' "$x2h" | grep -qF 'is a LOCAL copy'; then
    ok "local relationship: set-transfer refuses --compression (X2), --history is not refused for it"
else
    bad "local relationship: set-transfer --compression on a local copy" "rc=$x2r" "$x2c" "$x2h"
fi
# X27 (owner 2026-10-15, "Uzyj szablonu" on pve9b): set-transfer's history = newest vanished
# when the relationship was rewritten -- set-tiers rendered the block without its engine
# fields, and local-backup --replace stripped a legacy [dataset:] section that held one.
# Regression: the engine fields are read back from the block, and from a legacy section of
# the same pair_label (block wins); a relationship without them keeps none (control).
EK="$RL/engine-keep.conf"
cat > "$EK" <<'EOF'
[relation:ek]
	tiers = d30h24
	history = newest
	d30h24.send_schedule = 0 0 * * *
[relation:el]
	tiers = d30h24
[dataset:rpool/x]
	pair_label   = el
	history = newest
[dataset:rpool/y]
	pair_label   = none
	history = all
EOF
ek_out=$( ( declare -A RB=(); RB_TIERS=(); RB_KEYS=()
            relblock_engine_keep "$EK" el; printf 'el=[%s]\n' "$RB_ENGINE_KEEP"
            relblock_engine_keep "$EK" zz; printf 'zz=[%s]\n' "$RB_ENGINE_KEEP"
            relblock_load "$EK" ek; relblock_render ek 1 0 ) 2>&1 )
if printf '%s' "$ek_out" | grep -qF "el=[history"$'\t'"newest"$'\n]' \
   && printf '%s' "$ek_out" | grep -qF 'zz=[]' \
   && printf '%s' "$ek_out" | grep -qxF $'\thistory = newest'; then
    ok "relationship engine fields (history) survive a rewrite: read from the block and from a legacy section; render keeps them"
else
    bad "relationship engine fields survive a rewrite" "$ek_out"
fi
# X3 (owner 2026-10-12): an exception belongs to a source. One left behind by a
# source removed earlier (pve9b: ^hdd/vms/vm3$) is dropped when the relationship is
# read back; an exception of a source still there, and a pattern that is not an exact
# path, are kept. remove-source drops the exceptions of the source it removes.
printf 'CLIENT_NAME=x3\nRUX_MODE=local\nSTATE=active\nCLIENT_TARGET=hdd/backups\nREQUESTED_DATASETS=rpool/a\\,rpool/b\nCRON_CONFIG=%s\n' "$RL/x3.conf" > "$RL/clients/x3.conf"
cat > "$RL/x3.conf" <<'EOF'
[dataset:rpool/a]
	# managed-by: zfs-backup.sh local-backup source=rpool/a
	pair_label   = x3
	exclude_child_1 = ^rpool/a/tmp$
	exclude_child_2 = ^rpool/gone/vm3$
	exclude_child_3 = ^rpool/b/x(/|$)
	exclude_child_4 = ^rpool/z.*
EOF
x3a=$( ( CLIENTS_DIR="$RL/clients"; local_relation_argv x3 >/dev/null 2>&1; printf '%s\n' "${LRA[@]}" | grep -- '--exclude-child' ) )
x3b=$( ( CLIENTS_DIR="$RL/clients"; local_relation_argv x3 >/dev/null 2>&1
         LRA=(--source=rpool/a "${LRA[@]:1}"); lra_drop_orphan_excludes >/dev/null 2>&1; printf '%s\n' "${LRA[@]}" | grep -- '--exclude-child' ) )
if [ "$x3a" = '--exclude-child=^rpool/a/tmp$
--exclude-child=^rpool/b/x(/|$)
--exclude-child=^rpool/z.*' ] && [ "$x3b" = '--exclude-child=^rpool/a/tmp$
--exclude-child=^rpool/z.*' ]; then
    ok "local relationship: X3 -- an exception whose source is gone is dropped; one of a source still there and a non-path pattern stay"
else
    bad "local relationship: X3 orphaned exceptions" "read back: $x3a" "after removing rpool/b: $x3b"
fi
# SET-TIERS on the relationship's [relation:] BLOCK (X27, owner 2026-10-14: "Z szablonow
# powstaja configi -- jedyne zrodlo prawdy"). A count on one side splits the field into
# target_/source_; a count back to equal folds it again; a tier added in cadence order;
# a tier dropped with its per-section overrides; the last one refused; a tier switched
# off on the source (<tier>.source = no); --method on every tier; a per-section schedule
# override changed where it runs; a config the generator rejects leaves the file as it
# was; a relationship still in the old shape refused with the way out. One replace.
ST="$RL/st"; mkdir -p "$ST/clients"
printf 'CLIENT_NAME=sl\nRUX_MODE=local\nSTATE=active\nCRON_CONFIG=%s\n' "$ST/c.conf" > "$ST/clients/sl.conf"
st_conf() { cat > "$ST/c.conf" <<'EOF'
[defaults]
	host_label = t

[relation:sl]
	tiers = hourly, daily
	hourly.send_schedule = 1 * * * *
	hourly.prefix = automated_hourly_
	hourly.prune_schedule = 21 * * * *
	hourly.pattern = automated_hourly
	hourly.retain = -H24
	hourly.monitor = 90m 150m
	daily.send_schedule = 11 1 * * *
	daily.prefix = automated_daily_
	daily.prune_schedule = 31 1 * * *
	daily.pattern = automated_daily
	daily.retain = -D7
	daily.quiesce = auto,degrade

[dataset:rpool/a]
	relation     = sl
	side         = source
	dst          = hdd/backups
	pair_label   = sl
[prune:hdd/backups/rpool/a]
	relation     = sl
	side         = target
	pair_label   = sl
EOF
}
st_run() {   # <args...> -> output; config in $ST/c.conf
    ( CLIENTS_DIR="$ST/clients"
      cron_context_resolve() { CRON_CTX_FILE="$ST/c.conf"; }
      assert_cron_config_matches_installed() { :; }
      gencron_as_target() { [ -n "${ST_GEN_FAILS:-}" ] && return 1; bash "$REPO/gen-cron.sh" "$@" >/dev/null 2>&1; }
      show_activation_proposal() { :; }
      atomic_replace_and_install() { cp "$2" "$1"; }
      cmd_set_tiers sl "$@" ) 2>&1
}
st_f() { awk -v h="[$1]" -v k="$2" '$0==h{f=1;next} /^\[/{f=0} f{t=$0; sub(/^[ \t]+/,"",t); if (index(t,k" ")==1||index(t,k"=")==1){sub(/^[^=]*=[ \t]*/,"",t); print t; exit}}' "$ST/c.conf"; }
st_conf; o1=$(st_run --src-tier=hourly --keep=12 --yes)
r1t=$(st_f relation:sl hourly.target_retain); r1s=$(st_f relation:sl hourly.source_retain); r1c=$(st_f relation:sl hourly.retain)
o1b=$(st_run --src-tier=hourly --keep=24 --yes)
r1f=$(st_f relation:sl hourly.retain); r1g=$(st_f relation:sl hourly.source_retain)
if [ "$r1t" = -H24 ] && [ "$r1s" = -H12 ] && [ -z "$r1c" ] && [ "$r1f" = -H24 ] && [ -z "$r1g" ] && ! grep -q '^\[template:' "$ST/c.conf"; then
    ok "set-tiers: a count on the source splits the field (target -H24 / source -H12); equal again, it folds back to one -- all in the block, no template section"
else
    bad "set-tiers: count on one side" "split t=[$r1t] s=[$r1s] common=[$r1c]" "folded=[$r1f] left=[$r1g]" "$o1" "$o1b"
fi
st_conf; o2=$(st_run --add-tier=weekly --yes)
w_tiers=$(st_f relation:sl tiers); w_ret=$(st_f relation:sl weekly.retain); w_pre=$(st_f relation:sl weekly.prefix); w_mon=$(st_f relation:sl weekly.monitor)
o3=$(st_run --drop-tier=hourly --yes); d_tiers=$(st_f relation:sl tiers); d_left=$(grep -c '^	hourly\.' "$ST/c.conf")
st_conf; o4=$(st_run --drop-tier=hourly --drop-tier=daily --yes); r4=$?
if [ "$w_tiers" = "hourly, daily, weekly" ] && [ "$w_ret" = -W4 ] && [ "$w_pre" = automated_weekly_ ] && [ "$w_mon" = "8d 10d" ] \
   && [ "$d_tiers" = "daily, weekly" ] && [ "$d_left" = 0 ] && [ "$r4" -ne 0 ] && printf '%s' "$o4" | grep -q 'is the last tier'; then
    ok "set-tiers: --add-tier in cadence order (weekly -W4, its own family and monitor), --drop-tier takes every field of the tier, the last tier refused"
else
    bad "set-tiers: add / drop" "add: tiers=[$w_tiers] ret=$w_ret pre=$w_pre mon=[$w_mon]" "drop: tiers=[$d_tiers] left=$d_left rc4=$r4" "$o2" "$o3" "$o4"
fi
st_conf; o5=$(st_run --drop-src-tier=daily --method=age --yes)
r5off=$(st_f relation:sl daily.source); r5h=$(st_f relation:sl hourly.retain); r5d=$(st_f relation:sl daily.retain)
r5cron=$(bash "$REPO/gen-cron.sh" -c "$ST/c.conf" 2>&1)
if [ "$r5off" = no ] && [ "$r5h" = -h24 ] && [ "$r5d" = -d7 ] \
   && ! printf '%s' "$r5cron" | grep -q 'lsrc_daily' && printf '%s' "$r5cron" | grep -q 'profile__relacja-sl__daily prune'; then
    ok "set-tiers: --drop-src-tier writes daily.source = no (the source runs no daily, the target still prunes it); --method=age turns every count into an age"
else
    bad "set-tiers: source off / method" "off=[$r5off] hourly=$r5h daily=$r5d" "$o5" "$(printf '%s' "$r5cron" | grep -E 'daily' | head -4)"
fi
st_conf
awk '/^\[dataset:rpool\/a\]/{print; print "\tprune_schedule_hourly = 26 * * * *"; next} {print}' "$ST/c.conf" > "$ST/c2" && mv "$ST/c2" "$ST/c.conf"
o6=$(st_run --src-tier=hourly --prune-schedule='27 * * * *' --yes)
ov=$(st_f dataset:rpool/a prune_schedule_hourly); bp=$(st_f relation:sl hourly.prune_schedule)
st_conf; cp "$ST/c.conf" "$ST/before"; o7=$(ST_GEN_FAILS=1 st_run --tier=hourly --keep=3 --yes); r7=$?
r7same=0; cmp -s "$ST/c.conf" "$ST/before" && r7same=1
printf '[defaults]\n\thost_label = t\n[template:x]\n\tretain = -H1\n[dataset:rpool/a]\n\tuse_template = x\n\tpair_label = sl\n' > "$ST/c.conf"
o8=$(st_run --tier=x --keep=2 --yes); r8=$?
if [ "$ov" = "27 * * * *" ] && [ "$bp" = "21 * * * *" ] && [ "$r7" -ne 0 ] && [ "$r7same" = 1 ] \
   && printf '%s' "$o7" | grep -q 'gen-cron.sh rejected the changed config' && ! ls "$ST"/.zfsbackup-work.* >/dev/null 2>&1 \
   && [ "$r8" -ne 0 ] && printf '%s' "$o8" | grep -q 'still in the OLD config shape.*recreate it from a profile'; then
    ok "set-tiers: a per-section override is changed where it runs (the block keeps 21); a rejected config leaves no working copy; the old shape is refused, naming the way out"
else
    bad "set-tiers: override / rejected / old shape" "override=[$ov] block=[$bp] rc7=$r7 rc8=$r8" "$o6" "$o7" "$o8"
fi
# L2 (2026-10-09): a local relationship is CHANGED by describing it again --
# local_relation_argv reads it back (sources/target from the record, exclusions
# from its [dataset:] section), the verb changes one thing, and local-backup runs
# with --replace. Pinned without an install: the argv, and what each verb hands on.
printf 'CLIENT_NAME=l2\nRUX_MODE=local\nSTATE=active\nCLIENT_TARGET=hdd/backups\nREQUESTED_DATASETS=rpool/a\\,rpool/b\nRECURSION=flat\nPROFILE=d7h24\nCRON_CONFIG=%s\n' "$RL/l2.conf" > "$RL/clients/l2.conf"
cat > "$RL/l2.conf" <<'EOF'
[dataset:rpool/a]
	# managed-by: zfs-backup.sh local-backup source=rpool/a
	pair_label   = l2
	exclude_child_1 = ^rpool/a/tmp$
	exclude_family = vzdump
EOF
got=$( ( CLIENTS_DIR="$RL/clients"; local_relation_argv l2; printf '%s\n' "${LRA[@]}" ) 2>&1 )
want='--source=rpool/a,rpool/b
--target=hdd/backups
--name=l2
--recursive=flat
--config='"$RL/l2.conf"'
--profile=d7h24
--exclude-child=^rpool/a/tmp$
--exclude-family=vzdump'
[ "$got" = "$want" ] && ok "local relationship: local_relation_argv reads it back -- record (sources, target, recursion, profile, config) + its section's exclusions" \
                     || bad "local relationship: local_relation_argv" "$got"
lb_spy() {   # <verb args...> -> the local-backup arguments the verb handed on
    ( CLIENTS_DIR="$RL/clients"; cmd_local_backup() { printf '%s\n' "$@"; }; log() { :; }; "$@" ) 2>&1
}
got=$(lb_spy cmd_edit_relation l2 --profile=d30 --plan)
if printf '%s\n' "$got" | grep -qx -- '--profile=d30' && printf '%s\n' "$got" | grep -qx -- '--replace' \
   && ! printf '%s\n' "$got" | grep -qx -- '--install' && [ "$(printf '%s\n' "$got" | grep -c -- '^--profile=')" = 2 ]; then
    ok "local relationship: edit-relation --profile=P --plan hands local-backup the relationship plus the new profile (last wins) and --replace, no install"
else
    bad "local relationship: edit-relation on a local one" "$got"
fi
# STAGE B (owner 2026-10-13, "config jako jedyne zrodlo prawdy"): add-source / remove-source
# of a LOCAL relationship change only THAT source's sections in the config -- no rebuild of
# the rest from the profile in the record (which lost tiers set with set-tiers or by hand).
# add: [dataset:] and [prune:] cloned from a sibling, its exceptions left behind; remove:
# both sections go; refusals before anything is written; a plan writes nothing; the
# record's source list and copies follow the config.
LS="$RL/ls"; mkdir -p "$LS/clients"
ls_rec() { printf 'CLIENT_NAME=ls\nRUX_MODE=local\nSTATE=active\nCLIENT_TARGET=hdd/backups\nREQUESTED_DATASETS=rpool/a\\,rpool/b\nMANAGED_DATASETS=hdd/backups/rpool/a\\ hdd/backups/rpool/b\nCRON_CONFIG=%s\n' "$LS/c.conf" > "$LS/clients/ls.conf"; }
ls_conf() { cat > "$LS/c.conf" <<'EOF'
[template:profile__relacja-ls__daily]
	prune_schedule = 29 1 * * *
	retain         = -D5
[template:profile__relacja-ls__lsrc_daily]
	send_schedule  = 11 1 * * *
	prefix         = automated_daily_
	prune_schedule = 29 1 * * *
	pattern        = automated_daily
	retain         = -D1

[dataset:rpool/a]
	# managed-by: zfs-backup.sh local-backup source=rpool/a
	use_template = profile__relacja-ls__lsrc_daily
	dst          = hdd/backups
	recursive    = flat
	pair_label   = ls
	exclude_child_1 = ^rpool/a/tmp$
	exclude_family = vzdump
	notify       = local-a

[dataset:rpool/b]
	# managed-by: zfs-backup.sh local-backup source=rpool/b
	use_template = profile__relacja-ls__lsrc_daily
	dst          = hdd/backups
	recursive    = flat
	pair_label   = ls
	exclude_family = vzdump
	notify       = local-b

[prune:hdd/backups/rpool/a]
	# managed-by: zfs-backup.sh local-backup target=hdd/backups/rpool/a
	use_template = profile__relacja-ls__daily
	recursive    = yes
	pair_label   = ls
	notify       = local-a

[prune:hdd/backups/rpool/b]
	# managed-by: zfs-backup.sh local-backup target=hdd/backups/rpool/b
	use_template = profile__relacja-ls__daily
	recursive    = yes
	pair_label   = ls
	notify       = local-b

[dataset:rpool/other]
	dst          = hdd/backups
	pair_label   = other
EOF
}
ls_run() {   # <verb> <args...>
    ( CLIENTS_DIR="$LS/clients"
      cron_context_resolve() { CRON_CTX_FILE="$LS/c.conf"; }
      assert_cron_config_matches_installed() { :; }
      gencron_as_target() { return 0; }
      show_activation_proposal() { :; }
      atomic_replace_and_install() { cp "$2" "$1"; }
      zfs() { case "$*" in *"list -H -o name -- rpool/c"|*"list -H -o name -- rpool/a/sub"|*"list -H -o name -- rpool/other/x") return 0 ;; esac; return 1; }
      "$@" ) 2>&1
}
ls_sec() { awk -v h="[$1]" '$0==h{f=1;print;next} /^\[/{f=0} f' "$LS/c.conf"; }
ls_rec; ls_conf; cp "$LS/c.conf" "$LS/before"
ap=$(ls_run cmd_add_source ls rpool/c); ap_same=$(cmp -s "$LS/c.conf" "$LS/before" && echo yes)
ao=$(ls_run cmd_add_source ls rpool/c --yes)
nd=$(ls_sec dataset:rpool/c); np=$(ls_sec prune:hdd/backups/rpool/c)
keep_a=$(ls_sec dataset:rpool/a); keep_t=$(ls_sec template:profile__relacja-ls__daily)
if [ "$ap_same" = yes ] && printf '%s' "$nd" | grep -q 'use_template = profile__relacja-ls__lsrc_daily' && printf '%s' "$nd" | grep -q 'source=rpool/c' \
   && ! printf '%s' "$nd" | grep -q 'exclude_child' && printf '%s' "$nd" | grep -q 'exclude_family = vzdump' && printf '%s' "$nd" | grep -q 'notify       = local-c' \
   && printf '%s' "$np" | grep -q 'target=hdd/backups/rpool/c' && printf '%s' "$np" | grep -q 'use_template = profile__relacja-ls__daily' \
   && printf '%s' "$keep_a" | grep -q 'exclude_child_1 = ^rpool/a/tmp\$' && printf '%s' "$keep_t" | grep -q 'retain         = -D5' \
   && grep -q 'REQUESTED_DATASETS=rpool/a\\,rpool/b\\,rpool/c' "$LS/clients/ls.conf" \
   && grep -qx 'MANAGED_DATASETS=hdd/backups/rpool/a\\ hdd/backups/rpool/b\\ hdd/backups/rpool/c' "$LS/clients/ls.conf"; then
    ok "local relationship: add-source clones a sibling's two sections for the new source (its exceptions left behind); the tiers stay as set (-D5); a plan writes nothing; the record follows"
else
    bad "local relationship: add-source in the config" "plan same=$ap_same" "$ao" "$nd" "$np" "$(cat "$LS/clients/ls.conf")"
fi
ls_rec; ls_conf
ro=$(ls_run cmd_remove_source ls rpool/a --yes)
if ! grep -qxF '[dataset:rpool/a]' "$LS/c.conf" && ! grep -qxF '[prune:hdd/backups/rpool/a]' "$LS/c.conf" && ! grep -q 'rpool/a/tmp' "$LS/c.conf" \
   && grep -qxF '[dataset:rpool/b]' "$LS/c.conf" && grep -qxF '[dataset:rpool/other]' "$LS/c.conf" && grep -q 'retain         = -D5' "$LS/c.conf" \
   && grep -qx 'REQUESTED_DATASETS=rpool/b' "$LS/clients/ls.conf" && grep -qx 'MANAGED_DATASETS=hdd/backups/rpool/b' "$LS/clients/ls.conf" \
   && printf '%s' "$ro" | grep -q 'stays on this host'; then
    ok "local relationship: remove-source drops that source's two sections (and its exception) and nothing else; the copy stays; the record follows"
else
    bad "local relationship: remove-source in the config" "$ro" "$(cat "$LS/c.conf")" "$(cat "$LS/clients/ls.conf")"
fi
ls_rec; ls_conf; cp "$LS/c.conf" "$LS/before"
g1=$(ls_run cmd_remove_source ls rpool/zz); g2=$(ls_run cmd_add_source ls rpool/b); g3=$(ls_run cmd_add_source ls rpool/a/sub)
g4=$(ls_run cmd_add_source ls rpool/other/x); g5=$(ls_run cmd_add_source ls rpool/none)
ls_run cmd_remove_source ls rpool/a --yes >/dev/null; g6=$(ls_run cmd_remove_source ls rpool/b)
ls_conf
if printf '%s' "$g1" | grep -q 'is not a source' && printf '%s' "$g2" | grep -q 'is already in' && printf '%s' "$g3" | grep -q 'overlaps' \
   && printf '%s' "$g4" | grep -q "overlaps 'rpool/other'" && printf '%s' "$g5" | grep -q 'does not exist' && printf '%s' "$g6" | grep -q 'is the last source' \
   && cmp -s "$LS/c.conf" "$LS/before"; then
    ok "local relationship: a non-source, one already there, one inside a source or another relationship's dataset, a missing one, and the last one -- refused before anything is written"
else
    bad "local relationship: source refusals (config)" "$g1" "$g2" "$g3" "$g4" "$g5" "$g6"
fi
rm -f "$WORK/crontab-store"; seed_cfg
out="$( ( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" CLIENTS_DIR="$LC"
          cmd_local_backup --source=rpool/data --target=hdd/backups --replace --config="$CFG" ) 2>&1 )"
out2="$(CLIENTS_DIR="$LC" runi snapsend-ok "t" --source=rpool/data --target=hdd/backups --name=nosuch --replace --config="$CFG")"
if printf '%s' "$out" | grep -qE -- '--replace needs --name|--name=NAME is required' && printf '%s' "$out2" | grep -q "'nosuch' is not an active local relationship"; then
    ok "local relationship: --replace without --name, or for a relationship that does not exist, is refused"
else
    bad "local relationship: --replace refusals" "$(printf '%s' "$out" | tail -2)" "$(printf '%s' "$out2" | tail -2)"
fi
csl=""; for c in "hdd/backups/rpool:hdd/backups::local:0" "hdd/backups:hdd/backups::local:1" "hdd:hdd/backups::local:1" \
                 "t/p/x:t:p::0" "t/q:t:p::1"; do
    IFS=: read -r up tg pr md want <<< "$c"; copy_shell_level "$up" "$tg" "$pr" "$md"; got=$?
    [ "$got" = "$want" ] || csl="$csl $c(got $got)"
done
[ -z "$csl" ] && ok "local relationship: delete-relation climbs empty shells strictly below <target> for a local copy, below <target>/<peer> for a remote one" \
              || bad "local relationship: copy_shell_level" "$csl"

# ---- REV-20260812-112 F1: the Usage text must advertise the install verb -----
# The delivered command grew --install/--yes while the top-level Usage still
# described it as plan/preview only. Help that contradicts the tool is a defect
# in the public contract, so the contract is asserted, not just the behaviour.
usage_txt="$(usage 2>&1)"
# Here-strings, not `printf | grep -q`: grep -q quits at the first hit, printf
# then dies on a broken pipe, and under pipefail that reads as "no match" -- it
# went red on #471 once the Usage grew past what the pipe buffers. (The old
# pattern also carried a literal backspace byte where a word-boundary escape was meant.)
{ grep -q -- '--install' <<< "$usage_txt" && grep -qE -- '--yes\|?-y|-y' <<< "$usage_txt"; }     && ok "112 F1: Usage advertises --install and --yes/-y"     || bad "112 F1: Usage advertises --install and --yes/-y" "$(printf '%s' "$usage_txt" | grep -i 'source=DATASET' )"
# and the OLD unconditional claim must be gone -- the discriminating half:
# a Usage that merely LISTS --install while still saying "plan/preview only"
# would pass the assertion above and still mislead.
grep -qi 'plan/preview only' <<< "$usage_txt"     && bad "112 F1: Usage no longer claims the command is plan/preview only" "still says plan/preview only"     || ok "112 F1: Usage no longer claims the command is plan/preview only"

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
      PROFILE_ROOT="$REPO/profiles" CLIENTS_DIR="$(mktemp -d)" cmd_local_backup --name=lb "$@" ) 2>&1
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
          CLIENTS_DIR="$(mktemp -d)" cmd_local_backup --name=lb --source=rpool/data --install --yes --config="$CFG" ) 2>&1 )"
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
          CLIENTS_DIR="$(mktemp -d)" cmd_local_backup --name=lb --source=rpool/data --install --yes --config="$CFG" ) 2>&1 )"
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
# cmd_save_profile joins on the FIRST ticket (2026-09-07, REV-20260907-137 F1):
# it renders a config for VALIDATION under the identity it already is -- a
# candidate built from the profile, judged by the real generator, thrown away.
# Nothing is previewed for another account and nothing is installed, so the
# wrapper's reason (the account's copy bakes the account's paths into the
# block) does not apply; add-client re-validates the same profile through
# gencron_as_target when a relationship is actually built from it, which is
# where a version skew between the two copies would be caught.
gencron_allowed="gencron_as_target
cmd_activate_client
cmd_audit_source_retention
cmd_remove_client
cmd_save_profile
load_active_profile"
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
if ! product_fn "$ZB" show_activation_proposal | grep -q 'bash "\$GENCRON"'; then
    ok "local-user: show_activation_proposal renders through gencron_as_target, not gen-cron directly"
else
    bad "local-user: show_activation_proposal renders through gencron_as_target, not gen-cron directly"         "$(product_fn "$ZB" show_activation_proposal | grep -n 'bash "\$GENCRON"')"
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
    lb_args "$@"
    ( PATH="$WORK/bin3:$PATH" SERVER_CONF="$WORK/no-server.conf" POOLS="rpool hdd" \
      INVENTORY="$inv" PROFILE_ROOT="$REPO/profiles" \
      SNAPSEND="$WORK/seedbin/snapsend-ok" CLIENTS_DIR="${CLIENTS_DIR:-$(mktemp -d)}"       cmd_local_backup "${LB_ARGS[@]}" ) 2>&1
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
# X27: every run is a named relationship, so the series shares one record directory
# -- "the identical command again" has to find the relationship it made.
K5C="$WORK/k5clients"; rm -rf "$K5C"; mkdir -p "$K5C"; CLIENTS_DIR="$K5C"

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

# ---- BLOCKER 2: a second relationship may land on the same target ----------
out="$(runi snapsend-ok "" --name=lb2 --source=rpool/other --target=hdd/backups --config="$CFG" --install --yes)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -qxF '[dataset:rpool/data]' "$CFG" && grep -qxF '[dataset:rpool/other]' "$CFG"; } \
    && ok "krok5/blocker2: a second relationship lands on the same target, the first one surviving" \
    || bad "krok5/blocker2: a second relationship lands on the same target" "rc=$rc $(printf '%s' "$out"|tail -4)"
# Each relationship has its own block and its own landing prune; nothing is
# duplicated, and nothing of the first is rewritten.
{ [ "$(grep -cxF '[prune:hdd/backups/rpool/data]' "$CFG")" -eq 1 ] && [ "$(grep -cxF '[prune:hdd/backups/rpool/other]' "$CFG")" -eq 1 ] \
  && [ "$(grep -cxF '[relation:lb]' "$CFG")" -eq 1 ] && [ "$(grep -cxF '[relation:lb2]' "$CFG")" -eq 1 ]; } \
    && ok "krok5/blocker2: each relationship keeps one block and one landing prune" \
    || bad "krok5/blocker2: each relationship keeps one block and one landing prune" "$(grep '^\[' "$CFG" | tr '\n' ' ')"
# (The "mixed request" cases -- name every source, let the run work out which is
# new -- went with X27: adding a source to a relationship is add-source.)

unset CLIENTS_DIR   # the cases below are one-shot, each with a fresh record directory

# ---- F3: flat parent/child, END TO END ------------------------------------
# Teaching only the PROPOSAL that a flat job covers exactly its own dataset
# produced a false green: discovery would offer a child under an installed flat
# parent, and the composition gate would then refuse the very candidate it had
# just proposed. The rule has to hold at both ends, so these assert the whole
# run -- exit code, installed CONFIG, the pre-existing job surviving, the new
# job present, and the cron actually covering both -- not the absence of a
# phrase.
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
# X27: parent and child as TWO relationships collide on the TARGET side. Each
# relationship's landing prune <target>/<source> is recursive, so the child's copy
# (hdd/backups/rpool/a/child) would lie under the parent's landing prune and be
# pruned by two policies. Refused in both arrangements, naming the section; the
# way to copy a parent with its children is ONE relationship with --recursive=flat.
out="$(runi snapsend-ok "" --name=lbp --source=rpool/a --target=hdd/backups --config="$CFG" --install --yes)"
out="$(runi snapsend-ok "" --name=lbc --source=rpool/a/child --target=hdd/backups --config="$CFG" --install --yes)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF '[prune:hdd/backups/rpool/a] (hdd/backups/rpool/a, recursive=yes) covers requested hdd/backups/rpool/a/child' \
  && grep -qxF '[dataset:rpool/a]' "$CFG" && ! grep -qxF '[dataset:rpool/a/child]' "$CFG"; } \
    && ok "krok5/F3: a CHILD relationship under an installed parent's landing prune is refused, the parent intact" \
    || bad "krok5/F3: a child relationship under the parent's landing prune is refused" "rc=$rc $(printf '%s' "$out"|tail -4)"

# The mirror arrangement: installed child, parent requested later.
rm -f "$WORK/order" "$WORK/seed-calls" "$WORK/crontab-writes" "$WORK/crontab-store"; seed_cfg
out="$(runi snapsend-ok "" --name=lbc2 --source=rpool/a/child --target=hdd/backups --config="$CFG" --install --yes)"
out="$(runi snapsend-ok "" --name=lbp2 --source=rpool/a --target=hdd/backups --config="$CFG" --install --yes)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF '[prune:hdd/backups/rpool/a/child] (hdd/backups/rpool/a/child) lies under requested hdd/backups/rpool/a' \
  && grep -qxF '[dataset:rpool/a/child]' "$CFG" && ! grep -qxF '[dataset:rpool/a]' "$CFG"; } \
    && ok "krok5/F3: a PARENT relationship over an installed child's copy is refused, the child intact" \
    || bad "krok5/F3: a parent relationship over an installed child's copy is refused" "rc=$rc $(printf '%s' "$out"|tail -4)"

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
# Two profiles are checked because the retention once lived in different places
# and suppressing the wrong one produced exactly that unbounded shape (the old
# ladder `default` carried a [prune] fragment; y5m12d31h24-gfs prunes from its
# tiers). Since X27 both are "every tier its own family", the check stays.
for _p in default y5m12d31h24-gfs; do
    out="$( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" \
            CLIENTS_DIR="$(mktemp -d)" bash "$ZB" --source=rpool/data --target='' --profile="$_p" --name=lb --config="$WORK/nocopy-$_p.conf" 2>&1 )"; rc=$?
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

# ---- luka A' (2026-09-25): --target='' --recursive covers the children ------
#
# Without it a snapshot-only job made snapshots on the named root only, and a
# parent+child source list is refused as an overlap -- so children could not
# get snapshots at all. A passive sync collector (snapget -e) pulling those
# children ran rc=0 hourly and moved nothing (pve10 <> pve9, dead since
# 2026-09-20). One `recursive =` on the section scopes send and prune alike.
out="$( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" \
        CLIENTS_DIR="$(mktemp -d)" bash "$ZB" --source=rpool/data --target='' --profile=default --recursive=flat --name=lb --config="$WORK/nocopy-rec.conf" 2>&1 )"; rc=$?
_snapR="$(printf '%s\n' "$out" | grep -cE 'snapsend\.sh .* -R .*"rpool/data"$')"
_pruneR="$(printf '%s\n' "$out" | grep -cE 'delsnaps\.sh .* -R .*"rpool/data"')"
_pruneN="$(printf '%s\n' "$out" | grep -E 'delsnaps\.sh .*"rpool/data"' | grep -cv -- ' -R ')"
if [ "$rc" -eq 0 ] && [ "$_snapR" -ge 1 ] && [ "$_pruneR" -ge 1 ] && [ "$_pruneN" -eq 0 ]; then
    ok "A': --target='' --recursive=flat snapshots AND prunes the subtree (-R on both, no non-recursive prune left)"
else
    bad "A': --target='' --recursive=flat snapshots AND prunes the subtree" "rc=$rc snapsend-R=$_snapR delsnaps-R=$_pruneR delsnaps-bez-R=$_pruneN
$(printf '%s\n' "$out" | grep -E 'snapsend|delsnaps|FATAL' | head -5)"
fi
if printf '%s\n' "$out" | grep -q 'Retencja CELU:    (brak celu' && ! printf '%s\n' "$out" | grep -q 'Retencja CELU:    GFS'; then
    ok "A'/132-3: with no target the plan prints no target retention"
else
    bad "A'/132-3: with no target the plan prints no target retention" "$(printf '%s\n' "$out" | grep 'Retencja')"
fi
out="$( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" \
        CLIENTS_DIR="$(mktemp -d)" bash "$ZB" --source=rpool/data --target=hdd/backups --profile=default --recursive=atomic --name=lb --config="$WORK/tgt-rec.conf" 2>&1 )"; rc=$?
# flat WITH a target is allowed since 2026-10-09 (measured on pve9b, see the
# local relationship cases); atomic with a target stays refused.
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q -- "--recursive=atomic is for --target=''"; then
    ok "A': --recursive=atomic with a target is refused, with the reason"
else
    bad "A': --recursive=atomic with a target is refused, with the reason" "rc=$rc $(printf '%s\n' "$out" | tail -2)"
fi
out="$( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" \
        CLIENTS_DIR="$(mktemp -d)" bash "$ZB" --source=rpool/data --target='' --profile=default --recursive=ture --name=lb --config="$WORK/nocopy-bad.conf" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "got 'ture'"; then
    ok "A': an unknown --recursive value is fatal, not falsy"
else
    bad "A': an unknown --recursive value is fatal, not falsy" "rc=$rc $(printf '%s\n' "$out" | tail -2)"
fi

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
            CLIENTS_DIR="$(mktemp -d)" bash "$ZB" --source=rpool/data --target=hdd/backups --profile="$_p" --name=lb --config="$WORK/tgt-$_p.conf" 2>&1 )"; rc=$?
    _snap="$(printf '%s\n' "$out" | grep -cE 'snapsend\.sh .*"rpool/data" "hdd/backups"')"
    _src="$(printf '%s\n'  "$out" | grep -cE 'delsnaps\.sh .*"rpool/data"')"
    _tgt="$(printf '%s\n'  "$out" | grep -cE 'delsnaps\.sh .*"hdd/backups/rpool/data"')"
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

# K21 (owner campaign 2026-10-09): a local relationship's SOURCE retention is the
# --source-profile's, not the target's. Measured on pve9b: d30 + d30-src-D7 pruned the
# source with -D30 -- the source profile was prepared and never read for a flat
# profile. Flat: the [dataset:] tiers are the source family (-D7 on the source line,
# -D30 on the target's); control without --source-profile: both -D30.
K21P="$WORK/k21prof"; rm -rf "$K21P"; mkdir -p "$K21P"
sed -E 's/^([[:space:]]*keep[[:space:]]*=[[:space:]]*)30[[:space:]]*$/\17/' "$REPO/profiles/d30.conf" > "$K21P/d30-src-D7.conf"
k21_flags() {   # <output> <scope> -> the -D flag on that scope's delsnaps line
    printf '%s\n' "$1" | grep 'delsnaps' | grep -F "\"$2\" \"automated_daily\"" | grep -oE -- '-D[0-9]+' | head -1
}
k21o="$(PROFILE_USER_ROOT="$K21P" run --source=rpool/data --target=hdd/backups --recursive=flat --profile=d30 --source-profile=d30-src-D7 --name=k21 --config="$WORK/k21.conf")"
k21c="$(PROFILE_USER_ROOT="$K21P" run --source=rpool/data --target=hdd/backups --recursive=flat --profile=d30 --name=k21c --config="$WORK/k21c.conf")"
if [ "$(k21_flags "$k21o" rpool/data)" = -D7 ] && [ "$(k21_flags "$k21o" hdd/backups/rpool/data)" = -D30 ] \
   && [ "$(k21_flags "$k21c" rpool/data)" = -D30 ]; then
    ok "K21: local relationship -- the source is pruned by --source-profile (-D7), the target by the profile (-D30); control without it: -D30"
else
    bad "K21: source retention of a local relationship" "with: src=$(k21_flags "$k21o" rpool/data) tgt=$(k21_flags "$k21o" hdd/backups/rpool/data)" "without: src=$(k21_flags "$k21c" rpool/data)" "$(printf '%s\n' "$k21o" | grep -E 'FATAL|error' | head -3)"
fi
rm -rf "$K21P"

# W7 (owner GUI test, 2026-10-11), X27: the SECOND edit of a relationship replaces its
# [relation:] block -- the old numbers (-D30) are gone, the new ones (-D7) in, ONE block;
# another relationship's block in the same config is not touched.
W7P="$WORK/w7prof"; W7C="$WORK/w7clients"; rm -rf "$W7P" "$W7C"; mkdir -p "$W7P" "$W7C"
sed -E 's/^([[:space:]]*keep[[:space:]]*=[[:space:]]*)30[[:space:]]*$/\17/' "$REPO/profiles/d30.conf" > "$W7P/relacja-w7.conf"
printf 'CLIENT_NAME=w7\nRUX_MODE=local\nSTATE=active\nCLIENT_TARGET=hdd/backups\nREQUESTED_DATASETS=rpool/data\nCRON_CONFIG=%s\n' "$WORK/w7.conf" > "$W7C/w7.conf"
cat > "$WORK/w7.conf" <<'EOF'
[defaults]
	host_label = t

[relation:w7]
	tiers = daily
	daily.send_schedule = 11 1 * * *
	daily.prefix = automated_daily_
	daily.prune_schedule = 31 1 * * *
	daily.pattern = automated_daily
	daily.retain = -D30

[relation:w7x]
	tiers = daily
	daily.send_schedule = 12 1 * * *
	daily.prefix = automated_daily_
	daily.prune_schedule = 32 1 * * *
	daily.pattern = automated_daily
	daily.retain = -D30

[dataset:rpool/data]
	# managed-by: zfs-backup.sh local-backup source=rpool/data
	relation     = w7
	side         = source
	dst          = hdd/backups
	recursive    = flat
	pair_label   = w7
[prune:hdd/backups/rpool/data]
	# managed-by: zfs-backup.sh local-backup target=hdd/backups/rpool/data
	relation     = w7
	side         = target
	recursive    = yes
	pair_label   = w7
[dataset:rpool/other]
	relation     = w7x
	side         = source
	dst          = hdd/backups
	pair_label   = w7x
EOF
w7o="$(CLIENTS_DIR="$W7C" PROFILE_USER_ROOT="$W7P" run --source=rpool/data --target=hdd/backups --recursive=flat --profile=relacja-w7 --name=w7 --replace --config="$WORK/w7.conf")"
w7cand=$(printf '%s\n' "$w7o" | sed -n '/^--- kandydat CONFIG/,/^--- wygenerowany/p')
w7x=$(printf '%s\n' "$w7cand" | sed -n '/^\[relation:w7x\]/,/^$/p')
if [ "$(printf '%s' "$w7cand" | grep -c '^\[relation:w7\]')" = 1 ] && printf '%s' "$w7cand" | sed -n '/^\[relation:w7\]/,/^$/p' | grep -qF 'daily.retain = -D7' \
   && ! printf '%s' "$w7cand" | sed -n '/^\[relation:w7\]/,/^$/p' | grep -qF -- '-D30' && printf '%s' "$w7x" | grep -qF 'daily.retain = -D30' \
   && [ "$(k21_flags "$w7o" hdd/backups/rpool/data)" = -D7 ] && ! printf '%s' "$w7o" | grep -q 'FATAL'; then
    ok "W7/X27: a second edit replaces the relationship's [relation:w7] block (-D30 gone, -D7 in, one block); the neighbour's [relation:w7x] is untouched"
else
    bad "W7/X27: second edit of a relationship" "$w7cand" "$(printf '%s\n' "$w7o" | grep -E 'FATAL' | head -2)"
fi
rm -rf "$W7P" "$W7C" "$WORK/w7.conf"

# X27 (owner 2026-10-14, "nazwij lab-migawki"): a snapshots-only copy (--target='') is a
# named relationship too -- its block has a source side only; the cron makes and prunes
# snapshots in the source and sends nothing.
smo=$(run --source=rpool/data --target= --recursive=flat --profile=default --name=lab-migawki --config="$WORK/smo.conf")
smc=$(printf '%s\n' "$smo" | sed -n '/^--- kandydat CONFIG/,/^--- wygenerowany/p')
if printf '%s' "$smc" | grep -qxF '[relation:lab-migawki]' && printf '%s' "$smc" | grep -q 'side         = source' \
   && ! printf '%s' "$smc" | grep -q 'side         = target' && ! printf '%s' "$smc" | grep -q '^\[template:' \
   && printf '%s\n' "$smo" | grep -q 'snapsend.sh -m "automated_hourly_" -R .*"rpool/data"$' \
   && printf '%s\n' "$smo" | grep -q 'delsnaps.sh .*"rpool/data" "automated_daily"' && ! printf '%s\n' "$smo" | grep -q 'FATAL'; then
    ok "X27: a named snapshots-only relationship (--target='') -- one block, source side only, snapshots made and pruned in the source"
else
    bad "X27: named snapshots-only relationship" "$smc" "$(printf '%s\n' "$smo" | grep -E 'FATAL|snapsend|delsnaps' | head -6)"
fi
rm -f "$WORK/smo.conf"
# X22 / X27 (owner 2026-10-14): "Uzyj szablonu" on an existing relationship writes the
# profile's numbers into the relationship's OWN block -- nothing shared with another
# relationship, so a hand-changed section elsewhere cannot block it; the plan writes nothing.
X22C="$WORK/x22clients"; rm -rf "$X22C"; mkdir -p "$X22C"
printf 'CLIENT_NAME=x22\nRUX_MODE=local\nSTATE=active\nCLIENT_TARGET=hdd/backups\nREQUESTED_DATASETS=rpool/data\nRECURSION=flat\nPROFILE=d7h24\nCRON_CONFIG=%s\n' "$WORK/x22.conf" > "$X22C/x22.conf"
x22n=$(run --source=rpool/data --target=hdd/backups --recursive=flat --profile=d7h24 --name=x22 --config="$WORK/x22.conf")
printf '%s\n' "$x22n" | sed -n '/^--- kandydat CONFIG/,/^--- wygenerowany/p' | sed '1d;$d' > "$WORK/x22.conf"
cp "$WORK/x22.conf" "$WORK/x22.before"
x22o=$( ( PATH="$WORK/bin:$PATH" SERVER_CONF="$WORK/no-server.conf" PROFILE_ROOT="$REPO/profiles" CLIENTS_DIR="$X22C"; cmd_edit_relation x22 --profile=d30h24 --source-profile= --plan ) 2>&1 )
x22b=$(printf '%s\n' "$x22o" | sed -n '/^--- kandydat CONFIG/,/^--- wygenerowany/p')
if grep -qxF '[relation:x22]' "$WORK/x22.before" && printf '%s' "$x22b" | grep -qxF '[relation:x22]' && [ "$(printf '%s' "$x22b" | grep -c '^\[relation:x22\]')" = 1 ] \
   && printf '%s' "$x22b" | grep -qF 'daily.retain = -D30' && ! printf '%s' "$x22b" | grep -q '^\[template:' \
   && [ "$(k21_flags "$x22o" hdd/backups/rpool/data)" = -D30 ] && cmp -s "$WORK/x22.conf" "$WORK/x22.before"; then
    ok "X22/X27: edit-relation --profile=d30h24 rewrites the relationship's own [relation:x22] block (-D30, one block, no template section); the plan writes nothing"
else
    bad "X22/X27: Uzyj szablonu into the block" "$x22b" "tgt=$(k21_flags "$x22o" hdd/backups/rpool/data)" "$(printf '%s\n' "$x22o" | grep -E 'FATAL' | head -2)" "$(head -20 "$WORK/x22.before")"
fi
rm -rf "$X22C" "$WORK/x22.conf" "$WORK/x22.before"

# 2026-10-12, live encryption campaign on pve9b: a local and a remote relationship
# with the same profile in ONE config shared the `__src_` template names but not their
# content (the local family keeps monitors; the remote one may not), and the second
# install died. A local relationship's source family is `__lsrc_` now: the candidate
# carries it and none of the remote `__src_` names. Old code: `__src_` here.
# X27: no template sections any more -- the names live only in the cron descriptions,
# where a local source still reads __lsrc_ and never the remote __src_.
w12o="$(run --source=rpool/data --target=hdd/backups --profile=d7h24 --name=ns --config="$WORK/ns.conf")"
if printf '%s' "$w12o" | grep -q 'profile__relacja-ns__lsrc_hourly snapshot' && ! printf '%s' "$w12o" | grep -q 'profile__relacja-ns__src_' \
   && ! printf '%s' "$w12o" | sed -n '/^--- kandydat CONFIG/,/^--- wygenerowany/p' | grep -q '^\[template:'; then
    ok "local relationship: its source tiers are __lsrc_ in the cron (never the remote __src_), and the config holds no template section"
else
    bad "local relationship: source template namespace" "$(printf '%s
' "$w12o" | grep -oE 'profile__relacja-ns__[a-z_]+' | sort -u | head -8)"
fi

# W17: local-backup --raw -- an encrypted source copied encrypted (-w on the send line,
# raw = yes in its section); control without --raw: no -w.
w17o="$(run --source=rpool/data --target=hdd/backups --recursive=flat --profile=d30 --raw --name=w17 --config="$WORK/w17.conf")"
w17c="$(run --source=rpool/data --target=hdd/backups --recursive=flat --profile=d30 --name=w17c --config="$WORK/w17c.conf")"
if printf '%s\n' "$w17o" | grep 'snapsend' | grep -q ' -w ' && printf '%s' "$w17o" | grep -q 'raw          = yes' \
   && ! printf '%s\n' "$w17c" | grep 'snapsend' | grep -q ' -w '; then
    ok "W17: local-backup --raw -- raw = yes in the section, -w on the send line; control without it: no -w"
else
    bad "W17: local-backup --raw" "$(printf '%s\n' "$w17o" | grep -E 'snapsend|raw|FATAL' | head -4)" "$(printf '%s\n' "$w17c" | grep snapsend | head -1)"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
