#!/bin/bash
# The schedule stagger: which minute a new relationship is placed on, and which
# minutes it must treat as already taken.
#
# Relationships created from one profile used to inherit one literal
# send_schedule and all fire in the same minute -- a thundering herd on the
# link, the source's disks and sshd. The stagger picks a free minute once, at
# create, and writes it into the section.
#
# Two review findings are pinned here, both reproduced before they were fixed:
#
#   1. the collision collector kept only ^[0-9]+$ minute fields, so a valid
#      `*/15` job was invisible and a relationship hashing to 15 was placed
#      straight on top of it;
#   2. a section field overrides EVERY tier use_template references, so writing
#      one staggered value collapsed a daily tier onto the hourly one.
#
# The functions are extracted and run in isolation -- the question is their
# logic, not whether this machine has cron, zfs or a fleet.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${STAGGER_REPO:-$(cd "$DIR/../.." && pwd)}"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; FAIL=$((FAIL+1)); }

lift() {   # <function name> -> its source, or nothing if the build predates it
    # Plain string match on the opening line: an awk regex here needs escapes
    # that differ between awk builds, and getting them wrong made every case
    # "fail" for a reason that had nothing to do with the code under test.
    awk -v want="$1() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$REPO/zfs-backup.sh"
}

# --- the minute-field expander ---------------------------------------------
expand() {   # <field> -> space-separated minutes
    local t; t=$(mktemp)
    { echo 'set -u'; lift schedule_expand_minutes
      printf 'schedule_expand_minutes %q\n' "$1"; } > "$t"
    bash "$t" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
    rm -f "$t"
}
chk_expand() {   # <label> <field> <expected>
    local got; got=$(expand "$2")
    [ "$got" = "$3" ] && ok "$1" || bad "$1" "field '$2' -> '$got', wanted '$3'"
}

ALL_MINUTES="$(seq 0 59 | tr '\n' ' ' | sed 's/ $//')"
chk_expand "a literal minute expands to itself"          "7"        "7"
chk_expand "a step expands to every minute it fires in"  "*/15"     "0 15 30 45"
chk_expand "a list expands to its members"               "1,31"     "1 31"
chk_expand "a range expands to its span"                 "10-13"    "10 11 12 13"
chk_expand "a stepped range expands correctly"           "0-59/20"  "0 20 40"
# '*' is the one that bit: unquoted in a for-loop it is glob-expanded into
# filenames, so the commonest wildcard silently produced nothing.
chk_expand "a bare '*' expands to the whole hour"        "*"        "$ALL_MINUTES"
chk_expand "a nonsense field contributes nothing"        "abc"      ""

# --- placement: a taken minute must not be reused ---------------------------
# schedule_pick_minute hashes the name, then probes upwards for a free minute.
# Stub the collector so the test states exactly which minutes are occupied.
pick() {   # <name> <taken minutes, space separated> -> chosen minute
    local t; t=$(mktemp)
    { echo 'set -u'
      echo 'log() { :; }'
      printf 'TAKEN=%q\n' "$2"
      echo 'schedule_taken_minutes() { printf "%s\n" $TAKEN; }'
      lift schedule_pick_minute
      printf 'schedule_pick_minute %q\n' "$1"; } > "$t"
    bash "$t" 2>/dev/null
    rm -f "$t"
}

NAME=rel1
free_pick="$(pick "$NAME" "")"
if printf '%s' "$free_pick" | grep -qE '^[0-9]+$'; then
    ok "an empty host yields a numeric minute"
else
    bad "an empty host yields a numeric minute" "got '$free_pick'"
fi

# The discriminator for finding 1: occupy exactly the minute the hash lands on
# and require the placement to move off it.
same_pick="$(pick "$NAME" "$free_pick")"
if [ -n "$free_pick" ] && [ "$same_pick" != "$free_pick" ]; then
    ok "a taken minute is not reused"
else
    bad "a taken minute is not reused" "hash minute '$free_pick' was chosen again as '$same_pick'"
fi

# And the same through the REAL collector shape: a '*/15' job occupies 0/15/30/45,
# so a relationship must never be placed on any of them.
step_taken="$(expand '*/15')"
step_pick="$(pick "$NAME" "$step_taken")"
case " $step_taken " in
    *" $step_pick "*) bad "a '*/15' job blocks all four of its minutes" "chose $step_pick, occupied: $step_taken" ;;
    *) ok "a '*/15' job blocks all four of its minutes" ;;
esac

# --- the collector itself ---------------------------------------------------
# The discriminator for review finding 1, at the level where it actually bit:
# schedule_taken_minutes reading a REAL crontab line. A `*/15` transfer job
# occupies four minutes; the pre-fix collector kept only ^[0-9]+$ fields and
# reported none of them.
collect() {   # <crontab text> -> the minutes the collector reports
    local t; t=$(mktemp)
    { echo 'set -u'
      printf 'CRONTAB_TEXT=%q\n' "$1"
      echo 'cron_known_accounts() { echo root; }'
      echo 'cron_read() { printf "%s
" "$CRONTAB_TEXT" > "$2"; }'
      lift schedule_expand_minutes
      lift schedule_taken_minutes
      echo 'schedule_taken_minutes | sort -un | tr "
" " " | sed "s/ $//"'; } > "$t"
    bash "$t" 2>/dev/null
    rm -f "$t"
}

STEP_LINE='*/15 * * * * /opt/zfs/snapget.sh -m "" pool/a pool/b'
got_collect="$(collect "$STEP_LINE")"
if [ "$got_collect" = "0 15 30 45" ]; then
    ok "the collector sees every minute a '*/15' job fires in"
else
    bad "the collector sees every minute a '*/15' job fires in"         "reported '$got_collect', wanted '0 15 30 45'"
fi

MIXED_LINE='23 * * * * /opt/zfs/snapsend.sh pool/a pool/b
*/20 * * * * /opt/zfs/snapget.sh pool/c pool/d
5 3 * * * /usr/bin/something-else'
got_mixed="$(collect "$MIXED_LINE")"
if [ "$got_mixed" = "0 20 23 40" ]; then
    ok "the collector mixes literal and stepped jobs, and ignores non-engine lines"
else
    bad "the collector mixes literal and stepped jobs, and ignores non-engine lines"         "reported '$got_mixed', wanted '0 20 23 40'"
fi

# --- the cadence lookup -----------------------------------------------------
# schedule_template_expr must actually FIND the tier's cadence. It never did:
# the rendered fragment already carries `use_template = profile__P__tier`, and
# the lookup prefixed the namespace a second time, so every call returned
# empty. #148 hid that behind a default hourly cadence; #149 turned it into
# "emit nothing" -- no stagger at all. The discriminator is that a rendered
# fragment (namespaced) and a raw one (not) must BOTH resolve.
expr_for() {   # <use_template value> -> the cadence found, or nothing
    local t; t=$(mktemp); local d; d=$(mktemp -d)
    printf '	use_template = %s
' "$1" > "$d/ds.inc"
    printf '[template:profile__p__hourly]
	send_schedule  = 4 * * * *\n' > "$d/tpl"
    { echo 'set -u'
      echo 'log() { :; }'
      printf 'PROFILE_DS_FILE=%q\n' "$d/ds.inc"
      printf 'PROFILE_TPL_FILE=%q\n' "$d/tpl"
      echo 'PROFILE_PRUNE_FILE=""'
      echo 'PROFILE_LOADED=1'
      echo 'PROFILE_ACTIVE=p'
      awk -v want="profile_name_of() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$REPO/zfs-backup.sh"
      awk -v want="profile_template_section() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$REPO/zfs-backup.sh"
      lift schedule_template_expr
      echo 'schedule_template_expr send'; } > "$t"
    bash "$t" 2>/dev/null
    rm -rf "$t" "$d"
}

for form in "profile__p__hourly" "hourly"; do
    got="$(expr_for "$form")"
    if [ "$got" = "4 * * * *" ]; then
        ok "the cadence is found for use_template='$form'"
    else
        bad "the cadence is found for use_template='$form'" "got '$got', wanted '4 * * * *'"
    fi
done

# --- REV-20260827-122 F1, one site further on ---------------------------------
# PROFILE_ACTIVE can be a PATH. cmd_migrate_profile sets it from `--profile=`,
# which accepts one, and writes that same string into the client record that
# load_client_profile later reads back. This lookup built
#     [template:profile__${PROFILE_ACTIVE}__hourly]
# raw, so a path produced [template:profile__/tmp/x/p.conf__hourly], matched
# nothing, and fell through `continue` -- the empty answer whose cost the block
# above already records: no stagger at all, both relationships on the template's
# own minute.
#
# profile_name_of is lifted with the function under test, not stubbed: the fix
# CALLS it, so a harness without it would return empty for the fixed code too
# and this assertion would pass for the wrong reason.
expr_for_active() {   # <PROFILE_ACTIVE> <use_template form> -> the cadence
    local t; t=$(mktemp); local d; d=$(mktemp -d)
    printf '\tuse_template = %s\n' "$2" > "$d/ds.inc"
    printf '[template:profile__p__hourly]\n\tsend_schedule  = 4 * * * *\n' > "$d/tpl"
    { echo 'set -u'
      echo 'log() { :; }'
      printf 'PROFILE_DS_FILE=%q\n' "$d/ds.inc"
      printf 'PROFILE_TPL_FILE=%q\n' "$d/tpl"
      echo 'PROFILE_PRUNE_FILE=""'
      echo 'PROFILE_LOADED=1'
      printf 'PROFILE_ACTIVE=%q\n' "$1"
      awk -v want="profile_name_of() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$REPO/zfs-backup.sh"
      awk -v want="profile_template_section() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$REPO/zfs-backup.sh"
      lift schedule_template_expr
      echo 'schedule_template_expr send'; } > "$t"
    bash "$t" 2>/dev/null
    rm -rf "$t" "$d"
}
got="$(expr_for_active p hourly)"
if [ "$got" = "4 * * * *" ]; then ok "control: a bare profile name still finds the cadence"
else bad "control: a bare profile name still finds the cadence" "got '$got'"; fi
got="$(expr_for_active /tmp/whatever/p.conf hourly)"
if [ "$got" = "4 * * * *" ]; then ok "F1: a profile named by PATH still finds the cadence (no silent loss of stagger)"
else bad "F1: a profile named by PATH still finds the cadence" "got '$got' -- the path was interpolated into the template name"; fi
# ...and a RELATIVE path, which is what an operator actually types.
got="$(expr_for_active ./profiles/p.conf hourly)"
if [ "$got" = "4 * * * *" ]; then ok "F1: ...and by a relative path"
else bad "F1: ...and by a relative path" "got '$got'"; fi


# --- diagnostics must not become the value ---------------------------------
# Both helpers are CAPTURED by their caller ( x=$(schedule_...) ), and log()
# writes to STDOUT. A diagnostic printed there is returned as the value and
# written into the config -- `send_schedule = 17 schedule: '...' differs ...`.
# So these cases deliberately install a log() that behaves like the real one.
two_tier_expr() {   # -> what schedule_template_expr returns when tiers disagree
    local t; t=$(mktemp); local d; d=$(mktemp -d)
    printf '	use_template = profile__p__hourly,profile__p__daily\n' > "$d/ds.inc"
    { printf '[template:profile__p__hourly]
	send_schedule  = 4 * * * *\n'
      printf '[template:profile__p__daily]
	send_schedule  = 2 3 * * *\n'; } > "$d/tpl"
    { echo 'set -u'
      echo 'log() { echo ">>> $*"; }'      # the REAL log: stdout
      printf 'PROFILE_DS_FILE=%q\n' "$d/ds.inc"
      printf 'PROFILE_TPL_FILE=%q\n' "$d/tpl"
      echo 'PROFILE_PRUNE_FILE=""'
      echo 'PROFILE_LOADED=1'
      echo 'PROFILE_ACTIVE=p'
      awk -v want="profile_name_of() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$REPO/zfs-backup.sh"
      awk -v want="profile_template_section() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$REPO/zfs-backup.sh"
      lift schedule_template_expr
      echo 'schedule_template_expr send'; } > "$t"
    bash "$t" 2>/dev/null
    rm -rf "$t" "$d"
}

got_two="$(two_tier_expr)"
if [ -z "$got_two" ]; then
    ok "disagreeing tiers yield NOTHING, not a diagnostic string"
else
    bad "disagreeing tiers yield NOTHING, not a diagnostic string"         "returned '$got_two' -- this value would be written into the config"
fi

saturated_pick() {   # -> what schedule_pick_minute returns with every minute taken
    local t; t=$(mktemp)
    { echo 'set -u'
      echo 'log() { echo ">>> $*"; }'      # the REAL log: stdout
      echo 'schedule_taken_minutes() { seq 0 59; }'
      lift schedule_pick_minute
      echo 'schedule_pick_minute rel1'; } > "$t"
    bash "$t" 2>/dev/null
    rm -f "$t"
}

got_sat="$(saturated_pick)"
# The WHOLE value must be digits. A line-anchored grep would happily match the
# second line of a polluted capture (diagnostic first, minute after) and call
# it a pass -- which is exactly how the first version of this case was blind.
if [ -n "$got_sat" ] && case "$got_sat" in *[!0-9]*) false ;; *) true ;; esac; then
    ok "a saturated host still yields a bare minute, not a diagnostic string"
else
    bad "a saturated host still yields a bare minute, not a diagnostic string"         "returned '$got_sat' -- this value would become the cron minute"
fi

# --- determinism ------------------------------------------------------------
if [ "$(pick "$NAME" "")" = "$free_pick" ] && [ "$(pick "$NAME" "")" = "$free_pick" ]; then
    ok "the same relationship always lands on the same minute"
else
    bad "the same relationship always lands on the same minute" "repeat runs disagreed"
fi

echo "--------------------------------------------"
echo "stagger: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
