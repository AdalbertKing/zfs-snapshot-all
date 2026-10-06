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

# --- R5-7: tiers keep the profile's offsets ----------------------------------
# pve9b (m31w4d7h24) was installed with hourly, daily, weekly and monthly all at
# :00 -- the profile has them at :01, 01:11, 02:21, 03:31. Hourly and daily then
# start in the same minute on the same datasets, the per-dataset lock lets one
# through, the other skips with rc=0: no daily copy from 2026-09-22 (pve10).
spread() {   # <send|prune> <minute> -> schedule_spread_tiers on the m31w4d7h24 tiers
    local t; t=$(mktemp)
    { echo 'set -u'
      lift schedule_with_minute
      lift schedule_shift_expr
      lift schedule_spread_tiers
      printf 'printf "profile__m__hourly	%s
profile__m__daily	%s
profile__m__weekly	%s
profile__m__monthly	%s
profile__m__odd	%s
" | schedule_spread_tiers %s %s
'           "1 * * * *" "11 1 * * *" "21 2 * * 0" "31 3 1 * *" "*/15 * * * *" "$1" "$2"; } > "$t"
    bash "$t" 2>/dev/null
    rm -f "$t"
}
got_sp="$(spread send 0)"
want_sp="$(printf '	send_schedule_profile__m__hourly = 0 * * * *
	send_schedule_profile__m__daily = 10 1 * * *
	send_schedule_profile__m__weekly = 20 2 * * 0
	send_schedule_profile__m__monthly = 30 3 1 * *
	send_schedule_profile__m__odd = 0 * * * *')"
if [ "$got_sp" = "$want_sp" ]; then
    ok "R5-7: tiers shift together -- hourly on the relationship's minute, daily/weekly/monthly keep +10/+20/+30"
else
    bad "R5-7: tiers shift together" "got: $(printf '%s' "$got_sp" | tr '	
' ' |')"
fi
got_wrap="$(spread prune 56)"
# U2 (2026-10-06): the minute that passes :59 carries the hour. This case used
# to pin "6 1" -- the daily tier moved BACK 50 minutes instead of on by 55.
if printf '%s' "$got_wrap" | grep -qx '	prune_schedule_profile__m__daily = 6 2 \* \* \*' \
   && printf '%s' "$got_wrap" | grep -qx '	prune_schedule_profile__m__weekly = 16 3 \* \* 0' \
   && printf '%s' "$got_wrap" | grep -qx '	prune_schedule_profile__m__monthly = 26 4 1 \* \*' \
   && printf '%s' "$got_wrap" | grep -qx '	prune_schedule_profile__m__hourly = 56 \* \* \* \*' \
   && printf '%s' "$got_wrap" | grep -qx '	prune_schedule_profile__m__odd = 56 \* \* \* \*'; then
    ok "U2: a shift past :59 carries the hour (daily 01:11 + 55 -> 02:06), never a minute 66 and never back into the same hour"
else
    bad "U2: a shift past :59 carries the hour" "got: $(printf '%s' "$got_wrap" | tr '
' ' |')"
fi

# The shape measured on lab-ab: relationship minute 29, so the pull ladder
# :00/01:10/02:20/03:30 lands at :29/01:39/02:49/03:59 and the prune ladder
# :20/01:30/02:40/03:50 is spread from 29 + 20 = 49 (unwrapped). Every prune
# must come AFTER its own tier's pull -- the weekly prune had been at 02:09.
spread_tiers() {   # <send|prune> <minute> <hourly> <daily> <weekly> <monthly>
    local t; t=$(mktemp)
    { echo 'set -u'
      lift schedule_with_minute
      lift schedule_shift_expr
      lift schedule_spread_tiers
      printf 'printf "h\t%s\nd\t%s\nw\t%s\nm\t%s\n" | schedule_spread_tiers %s %s\n' "$3" "$4" "$5" "$6" "$1" "$2"; } > "$t"
    bash "$t" 2>/dev/null
    rm -f "$t"
}
tmin() {   # "<min> <hour> ..." -> minutes since midnight (hour * means 0)
    local m h; read -r m h _ <<< "$1"; [ "$h" = '*' ] && h=0; echo $(( 10#$h * 60 + 10#$m ))
}
sendl="$(spread_tiers send 29 "0 * * * *" "10 1 * * *" "20 2 * * 0" "30 3 1 * *")"
prunel="$(spread_tiers prune 49 "20 * * * *" "30 1 * * *" "40 2 * * 0" "50 3 1 * *")"
u2_ok=1; u2_why=""
for tier in d w m; do
    se=$(printf '%s\n' "$sendl"  | sed -n "s/^	send_schedule_$tier = //p")
    pe=$(printf '%s\n' "$prunel" | sed -n "s/^	prune_schedule_$tier = //p")
    if [ -z "$se" ] || [ -z "$pe" ] || [ "$(tmin "$pe")" -le "$(tmin "$se")" ]; then u2_ok=0; u2_why="$u2_why $tier: pull [$se] prune [$pe];"; fi
done
if [ "$u2_ok" -eq 1 ] && printf '%s\n' "$prunel" | grep -qx '	prune_schedule_w = 9 3 \* \* 0'; then
    ok "U2: lab-ab shape (minute 29) -- every tier's prune runs AFTER its pull; weekly prune 03:09, not 02:09"
else
    bad "U2: lab-ab shape -- a prune lands before its pull" "$u2_why" "$prunel"
fi

# Midnight: a DAILY tier wraps to the next day's hour 0; a WEEKLY one does not
# (carrying it would move it to another day) and keeps the in-hour wrap. A
# negative delta carries backwards.
got_mid="$(spread_tiers send 30 "10 * * * *" "50 23 * * *" "50 23 * * 0" "15 2 1 * *")"
got_neg="$(spread_tiers send 5 "30 * * * *" "10 1 * * *" "20 2 * * 0" "30 3 1 * *")"
if printf '%s\n' "$got_mid" | grep -qx '	send_schedule_d = 10 0 \* \* \*' \
   && printf '%s\n' "$got_mid" | grep -qx '	send_schedule_w = 10 23 \* \* 0' \
   && printf '%s\n' "$got_mid" | grep -qx '	send_schedule_m = 35 2 1 \* \*' \
   && printf '%s\n' "$got_neg" | grep -qx '	send_schedule_d = 45 0 \* \* \*' \
   && printf '%s\n' "$got_neg" | grep -qx '	send_schedule_w = 55 1 \* \* 0'; then
    ok "U2: a daily tier carries across midnight, a weekly one does not move to another day, and a negative shift carries backwards"
else
    bad "U2: midnight / negative carry" "mid: $(printf '%s' "$got_mid" | tr '
' ' |')" "neg: $(printf '%s' "$got_neg" | tr '
' ' |')"
fi

# --- determinism ------------------------------------------------------------
if [ "$(pick "$NAME" "")" = "$free_pick" ] && [ "$(pick "$NAME" "")" = "$free_pick" ]; then
    ok "the same relationship always lands on the same minute"
else
    bad "the same relationship always lands on the same minute" "repeat runs disagreed"
fi

# --- THE PRUNE THAT REACHES THE SOURCE OVER SSH -----------------------------
#
# 63f69eb spread relationships "across the clock instead of stacking them on one
# minute", and its own measurement named the cost: "all at :01 and all pruning
# at :21 ... a thundering herd on the link, the source's disks and sshd". It
# gave a minute to the send and to the LOCAL prune and never touched
# append_source_prune_create -- so the one job class that opens an SSH session
# to the source, and therefore hits every item in that sentence, stayed stacked.
#
# Measured on the lab 2026-08-30, two relationships: sends :57 and :01, local
# prunes :17 and :21, and BOTH source prunes at :21 alongside the local one --
# three jobs, two of them over SSH to different hosts, in one minute. It
# reproduced identically on a rebuild, so it is deterministic.
#
# This suite had twenty cases and none of them looked at a source prune.
emit_src_prune() {   # <schedule expr> -> the emitted section
    local t; t=$(mktemp); local wf; wf=$(mktemp)
    { echo 'set -u'
      echo 'PROFILE_PRUNE_FILE=/dev/null'
      echo 'emit_source_prune_fragment() { :; }'
      echo 'is_recursive_root() { return 1; }'
      lift append_source_prune_create
      printf 'append_source_prune_create %q pve9 "# managed" %q "-p 22" hdd/labsrc /dev/null %q
'              "$wf" "acct@1.2.3.4:hdd/labsrc" "$1"
    } > "$t"
    bash "$t" >/dev/null 2>&1
    cat "$wf"; rm -f "$t" "$wf"
}

got="$(emit_src_prune "37 * * * *")"
case "$got" in
    *"prune_schedule = 37 * * * *"*)
        ok "the source-side prune carries its own minute" ;;
    *)  bad "the source-side prune carries its own minute" "$got" ;;
esac

# THE CONTROL, and it is not a formality: every source prune section written
# before this carries no schedule and inherits the template's. An emitter that
# always wrote one would silently move jobs on hosts that never asked for it.
got="$(emit_src_prune "")"
case "$got" in
    *prune_schedule*)
        bad "no expression means inherit the template, as before" "$got" ;;
    *)  ok "no expression means inherit the template, as before" ;;
esac
# ...and the section is still emitted, or the control above would pass on an
# emitter that produced nothing at all.
case "$got" in
    *"[prune:acct@1.2.3.4:hdd/labsrc]"*)
        ok "control: the section itself is still written" ;;
    *)  bad "control: the section itself is still written" "$got" ;;
esac

# THE THREE SLOTS ARE PAIRWISE 20 MINUTES APART, which is what makes this a
# spread rather than a second pile. Asserted on the arithmetic the caller uses,
# for a minute near the wrap so the modulo is exercised rather than assumed.
for base in 0 45 57; do
    lp=$(( (base + 20) % 60 ))
    sp=$(( (base + 40) % 60 ))
    if [ "$base" != "$lp" ] && [ "$lp" != "$sp" ] && [ "$base" != "$sp" ]; then
        ok "send/local-prune/source-prune are three distinct minutes (base $base -> $base/$lp/$sp)"
    else
        bad "send/local-prune/source-prune are three distinct minutes (base $base)" "$base/$lp/$sp"
    fi
done

# THE FLAG MUST NOT BE A POSITIONAL, and the first cut made it one.
# emit_remote_source_prune ends in a variadic dataset list, so a fourth
# positional in front of that list eats the first DATASET: the list came out
# empty, the function returned early, and no section was written at all.
#
# NOT re-tested here. test/zfsbackup already drives that function with its real
# dependencies, and it is what caught this -- as a CONTROL failing ("96x
# control: a readable fragment still produces the source prune section"), which
# is exactly the assertion that trap breaks. Lifting a function with that many
# dependencies into this suite would mean a stub per dependency, and a harness
# that elaborate is a second implementation to keep true, not a test.

# K3 (lab campaign, 2026-10-06): A MULTI-CADENCE SOURCE PRUNE IS SPREAD TIER
# BY TIER. With no single schedule the source prune kept the template's
# minutes -- every relationship pruned its source at :21, 01:31, ... and two
# collectors hit pve9b in the same minute. Given its base (send minute + 40,
# unwrapped), each source tier now moves by the same delta, hour carried.
emit_src_prune_tiered() {   # <base minute> -> the emitted section
    local t; t=$(mktemp); local wf; wf=$(mktemp)
    printf '[template:profile__p__src_hourly]\n\tprune_schedule = 21 * * * *\n\n[template:profile__p__src_daily]\n\tprune_schedule = 31 1 * * *\n' > "$wf"
    { echo 'set -u'
      echo 'PROFILE_PRUNE_FILE=/dev/null'
      printf 'emit_source_prune_fragment() { printf "\\tuse_template = profile__p__src_hourly,profile__p__src_daily\\n"; }\n'
      echo 'is_recursive_root() { return 1; }'
      lift schedule_with_minute
      lift schedule_shift_expr
      lift schedule_spread_tiers
      lift append_source_prune_create
      printf 'append_source_prune_create %q pve9 "# managed" %q "-p 22" hdd/labsrc /dev/null "" %q\n' \
             "$wf" "acct@1.2.3.4:hdd/labsrc" "$1"
    } > "$t"
    bash "$t" >/dev/null 2>&1
    sed -n '/^\[prune:/,$p' "$wf"; rm -f "$t" "$wf"
}
k3a="$(emit_src_prune_tiered 60)"   # relationship minute 20
k3b="$(emit_src_prune_tiered 85)"   # relationship minute 45
if printf '%s\n' "$k3a" | grep -qx '	prune_schedule_profile__p__src_hourly = 0 \* \* \* \*' \
   && printf '%s\n' "$k3a" | grep -qx '	prune_schedule_profile__p__src_daily = 10 2 \* \* \*' \
   && printf '%s\n' "$k3b" | grep -qx '	prune_schedule_profile__p__src_hourly = 25 \* \* \* \*' \
   && printf '%s\n' "$k3b" | grep -qx '	prune_schedule_profile__p__src_daily = 35 2 \* \* \*'; then
    ok "K3: a multi-cadence source prune is spread tier by tier from the third slot -- two relationships, two different minute sets, tier offsets kept, hour carried"
else
    bad "K3: multi-cadence source prune not spread" "a: $(printf '%s' "$k3a" | tr '\t\n' ' |')" "b: $(printf '%s' "$k3b" | tr '\t\n' ' |')"
fi
k3c="$(emit_src_prune_tiered "")"
case "$k3c" in
    *prune_schedule*) bad "K3: control -- without a base nothing is spread (the template's own schedule, as before)" "$k3c" ;;
    *)                ok "K3: control -- without a base nothing is spread (the template's own schedule, as before)" ;;
esac

# K3, the reader beside it: `status` printed the spread source schedules as
# SOURCES (its src match took any line containing "src" before '='). Only the
# field named src is a source.
k3cfg=$(mktemp)
printf '[dataset:x]\n\t# managed-by: zfs-backup.sh client=c\n\tsrc          = a@h:hdd/data\n[prune:a@h:hdd/data]\n\t# managed-by: zfs-backup.sh client=c\n\tprune_schedule_profile__p__src_hourly = 29 * * * *\n' > "$k3cfg"
k3t=$(mktemp)
{ lift status_sources_from_config; printf 'CRON_CONFIG=%q status_sources_from_config c\n' "$k3cfg"; } > "$k3t"
k3s=$(bash "$k3t" 2>&1); rm -f "$k3t" "$k3cfg"
if [ "$k3s" = "a@h:hdd/data" ]; then
    ok "K3: status lists the src field only -- a spread prune_schedule_<..src_hourly> line is not a source"
else
    bad "K3: status lists schedules as sources" "got=[$k3s]"
fi

echo "--------------------------------------------"
echo "stagger: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
