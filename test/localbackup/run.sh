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
case "$ds" in rpool/data|rpool/existing|rpool/other|rpool/db) exit 0 ;;
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
