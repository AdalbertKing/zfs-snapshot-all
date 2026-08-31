#!/bin/bash
# The SCOPE fields: passive, exclude_snapshots, exclude_<n>.
#
#   test/scopefields/run.sh
#
# The second half of the split the link fields started. What was left inside
# 'flags' after the link options got their own names on 2026-08-24 was two
# unrelated things wearing one name: IDENTITY (-K/-k/-O/-p, the key, the pinned
# host key, the port) and three DECISIONS about what the relationship takes from
# its source -- whether it authors snapshots or adopts a family somebody else
# stamps (-e), which families it refuses to adopt (-E), which children it leaves
# behind (-X). Naming the three is what empties the identity sack, and 'flags'
# being profile-forbidden then follows from what it holds rather than from the
# accident that everything was in it.
#
# The properties pinned here are the ones that make the split real:
#
#   1. each field renders EXACTLY the tokens an operator would have typed, in
#      the same ORDER -- and order is asserted not because getopts cares (it
#      does not) but because a re-activated relationship whose flags reorder
#      shows up as churn in every crontab diff on the estate;
#   2. ONE OPTION, ONE HOME -- the same option arriving from both 'flags' and a
#      field is refused, not merged and not silently preferred. `passive = no`
#      alongside a hand-written -e is refused TOO, and that case is the sharper
#      one: `no` renders nothing, so there is no duplicate token to trip over,
#      just a config that reads the opposite of what it does;
#   3. the duplicate check reads 'flags' the way getopts does. A bundled `-eS`
#      carries -e and must be caught; an ARGUMENT that merely looks like a
#      letter (`-m e-daily_`, `-m E-daily_`) carries none and must not be.
#      Both directions, because a substring rule passes one and fails the other;
#   4. exclude_<n> is NUMBERED rather than comma-separated, because the value is
#      a regular expression and a regex may contain any separator a list would
#      have picked. So the suite asserts that a pattern containing a comma
#      survives, and that a GAP in the numbering is refused rather than
#      silently truncating the list;
#   5. the fields are [dataset:]-only and profile-forbidden, and the shipped
#      profiles are unaffected -- asserted, because a rule that refused
#      everything would pass every negative above.
#
# NEGATIVE CONTROL, run every time rather than described: the rendering
# assertions are re-run against the PREVIOUS committed gen-cron.sh, which must
# reject the same config as carrying unknown fields. A suite that would pass
# against the build before the change proves nothing about the change.
#
# No ZFS and no remote host: gen-cron.sh is a pure text tool.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${SCOPEFIELDS_REPO:-$(cd "$DIR/../.." && pwd)}"
GEN="${GEN:-$REPO/gen-cron.sh}"
PROFILE_LIB="$REPO/lib-profile.sh"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; FAIL=$((FAIL+1)); }

TMPD=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPD"' EXIT

REMOTE_SRC='zfsbackup@10.0.0.1:tank/a'

# A minimal PULL config that renders: one tier, one dataset, a remote source.
# EXTRA lines are appended inside the [dataset:] section, which is where every
# scope field belongs.
mkconf() {   # <file> <extra lines...>
    local f="$1"; shift
    {
        printf '[defaults]\n\thost_label = lab\n\n'
        printf '[template:hourly]\n'
        printf '\tsend_schedule  = 5 * * * *\n'
        printf '\tprefix         = automated_hourly_\n'
        printf '\tnotify_word    = snapshot\n\n'
        printf '[dataset:tank/a]\n'
        printf '\tuse_template = hourly\n'
        printf '\tnotify       = a\n'
        printf '\tdst          =\n'
        printf '\tsrc          = %s\n' "$REMOTE_SRC"
        local line; for line in "$@"; do printf '\t%s\n' "$line"; done
    } > "$f"
}

# Sets OUT and RC in the CALLER -- not `out=$(render ...)`, because a status
# assigned inside a command substitution belongs to the subshell and is gone by
# the time the caller reads it (the mistake test/linkfields records making).
render() {   # <gen-cron path> <conf>
    OUT=$(env -u REPO_DIR -u NOTIFY_SCRIPT -u WARN_SCRIPT -u DIGEST_SCRIPT \
              -u CRON_LOG -u DIGEST_SCHEDULE bash "$1" -c "$2" 2>&1)
    RC=$?
}

# The generated engine invocation, isolated from the cron wrapper around it.
sendline() {   # <output> -> the engine call
    printf '%s\n' "$1" | grep -o 'snapget\.sh.*' | head -1 | sed 's/ 2>"\$e".*//'
}

# The previous committed gen-cron.sh, for the built-in negative control.
OLDGEN="$TMPD/gen-cron.old.sh"
if git -C "$REPO" show HEAD:gen-cron.sh > "$OLDGEN" 2>/dev/null && [ -s "$OLDGEN" ]; then
    HAVE_OLD=1
else
    HAVE_OLD=0
fi

# --- 1. each field renders its own token ------------------------------------
for spec in "passive      = yes|-e" \
            "exclude_snapshots = __replicate_|-E __replicate_" \
            "exclude_1    = drop\$|-X drop\$"; do
    field="${spec%%|*}"; want="${spec##*|}"
    mkconf "$TMPD/r.conf" "$field"
    render "$GEN" "$TMPD/r.conf"; line=$(sendline "$OUT")
    if [ "$RC" -ne 0 ]; then
        bad "render: ${field%% *} -> $want" "exit $RC: $OUT"
    elif [ "${line#*"$want"}" != "$line" ]; then
        ok "render: ${field%% *} -> $want"
    else
        bad "render: ${field%% *} -> $want" "line: $line"
    fi
done

# passive = no is the absent case spelled out loud: it must add nothing.
mkconf "$TMPD/pno.conf" "passive      = no"
render "$GEN" "$TMPD/pno.conf"; line=$(sendline "$OUT")
case "$line" in
    *" -e"*) bad "passive=no adds no -e" "line: $line" ;;
    *) [ "$RC" -eq 0 ] && ok "passive=no adds no -e" || bad "passive=no adds no -e" "exit $RC: $OUT" ;;
esac

# Several families, several children -- one option per entry, not one option
# carrying a list.
mkconf "$TMPD/multi.conf" "exclude_snapshots = __replicate_,vzdump" "exclude_1    = a" "exclude_2    = b"
render "$GEN" "$TMPD/multi.conf"; line=$(sendline "$OUT")
if [ "$RC" -eq 0 ] \
   && case "$line" in *"-E __replicate_ -E vzdump"*) true ;; *) false ;; esac \
   && case "$line" in *"-X a -X b"*) true ;; *) false ;; esac; then
    ok "each entry becomes its own option, in the order written"
else
    bad "each entry becomes its own option, in the order written" "exit $RC line: $line"
fi

# THE WHOLE POINT OF NAMING THEM: the same engine call as the hand-written
# string, token for token and in the same order.
mkconf "$TMPD/named.conf" "flags        = -K /key -p 2222" \
                          "passive      = yes" \
                          "exclude_snapshots = __replicate_,vzdump" \
                          "exclude_1    = -swap\$" "exclude_2    = /tmp"
mkconf "$TMPD/hand.conf"  "flags        = -K /key -p 2222 -X -swap\$ -X /tmp -e -E __replicate_ -E vzdump"
render "$GEN" "$TMPD/named.conf"; a=$(sendline "$OUT"); rca=$RC
render "$GEN" "$TMPD/hand.conf";  b=$(sendline "$OUT"); rcb=$RC
if [ "$rca" -eq 0 ] && [ "$rcb" -eq 0 ] && [ -n "$a" ] && [ "$a" = "$b" ]; then
    ok "the named fields and the hand-written string produce the identical engine call"
else
    bad "the named fields and the hand-written string produce the identical engine call" "named($rca): $a
hand($rcb):  $b"
fi

# A pattern beginning with a dash is a LEGAL regex and must survive. The link
# fields refuse a leading dash (a rate or a cipher never starts with one); doing
# the same here would make the field unable to express what --exclude accepts.
mkconf "$TMPD/dashpat.conf" "exclude_1    = -swap\$"
render "$GEN" "$TMPD/dashpat.conf"; line=$(sendline "$OUT")
if [ "$RC" -eq 0 ] && case "$line" in *"-X -swap\$"*) true ;; *) false ;; esac; then
    ok "a pattern that legitimately begins with a dash is rendered, not refused"
else
    bad "a pattern that legitimately begins with a dash is rendered, not refused" "exit $RC line: $line"
fi

# And the reason the child excludes are numbered rather than comma-separated:
# the value is a regex, and a regex may contain the separator a list would have
# used. `x{2,3}` must arrive at the engine whole.
mkconf "$TMPD/commapat.conf" "exclude_1    = x{2,3}"
render "$GEN" "$TMPD/commapat.conf"; line=$(sendline "$OUT")
if [ "$RC" -eq 0 ] && case "$line" in *"-X x{2,3}"*) true ;; *) false ;; esac; then
    ok "a pattern containing a comma survives whole (why exclude_<n> is numbered)"
else
    bad "a pattern containing a comma survives whole (why exclude_<n> is numbered)" "exit $RC line: $line"
fi

# --- 2. one option, one home ------------------------------------------------
refuses() {   # <label> <want-substring> <extra lines...>
    local label="$1" want="$2"; shift 2
    mkconf "$TMPD/x.conf" "$@"
    render "$GEN" "$TMPD/x.conf"
    if [ "$RC" -eq 0 ]; then
        bad "$label" "accepted; line: $(sendline "$OUT")"
    elif [ "${OUT#*"$want"}" != "$OUT" ]; then
        ok "$label"
    else
        bad "$label" "refused for the wrong reason: $OUT"
    fi
}

refuses "collision: passive vs -e in flags" "one option, one home" \
        "flags        = -K /key -e" "passive      = yes"
refuses "collision: exclude_snapshots vs -E in flags" "one option, one home" \
        "flags        = -K /key -E fam" "exclude_snapshots = other"
refuses "collision: exclude_1 vs -X in flags" "one option, one home" \
        "flags        = -K /key -X drop" "exclude_1    = other"

# The sharper half of the rule. `passive = no` renders NOTHING, so there is no
# duplicate token -- and that is exactly why it has to be refused: the section
# says it is not passive and sends -e anyway.
refuses "collision: passive=no still refuses a hand-written -e" "one option, one home" \
        "flags        = -K /key -e" "passive      = no"

# --- 3. the duplicate check reads flags the way getopts does ----------------
# A bundled cluster carries every letter in it.
refuses "getopts read: bundled -eS carries -e" "one option, one home" \
        "flags        = -K /key -eS" "passive      = yes"

# ...and an option ARGUMENT is not an option. Both letters are checked, because
# a substring rule would trip on either.
for spec in "e|-m e-daily_|passive      = yes" \
            "E|-m E-daily_|exclude_snapshots = fam" \
            "X|-m X-daily_|exclude_1    = drop"; do
    letter="${spec%%|*}"; rest="${spec#*|}"; fl="${rest%%|*}"; fld="${rest#*|}"
    mkconf "$TMPD/arg.conf" "flags        = $fl" "$fld"
    render "$GEN" "$TMPD/arg.conf"
    if [ "$RC" -eq 0 ]; then
        ok "getopts read: an argument that looks like -$letter is not an option"
    else
        bad "getopts read: an argument that looks like -$letter is not an option" "exit $RC: $OUT"
    fi
done

# --- 4. the numbering is a contract, not a convention -----------------------
refuses "numbering: a gap is refused, not silently truncated" "number the exclusions from 1" \
        "exclude_1    = a" "exclude_3    = c"

# --- 5. grammar -------------------------------------------------------------
refuses "grammar: blank passive"            "present but blank" "passive      ="
refuses "grammar: passive = maybe"          "expected yes or no" "passive      = maybe"
refuses "grammar: blank exclude_snapshots"  "present but blank" "exclude_snapshots ="
refuses "grammar: stray comma"              "empty entry"       "exclude_snapshots = a,,b"
refuses "grammar: blank exclude_1"          "present but blank" "exclude_1    ="
refuses "grammar: the -X is what the field renders" "give the pattern only" "exclude_1    = -X foo"
refuses "grammar: exclude_snapshots takes a NAME" "give the family NAME only" "exclude_snapshots = -E fam"

# exclude_<n> accepts DIGITS only. `exclude_snapshots` is a field in its own
# right and must not be swallowed by the numbered arm; anything else under that
# prefix is a typo and must be rejected rather than stored and ignored.
refuses "grammar: exclude_x is not a field" "not a field gen-cron.sh reads" "exclude_x    = a"

# --- 6. ownership -----------------------------------------------------------
# [dataset:] only: there is no layer above the section that knows what a
# relationship takes from its source.
for fld in "passive      = yes" "exclude_snapshots = fam" "exclude_1    = drop"; do
    {
        printf '[defaults]\n\thost_label = lab\n\n'
        printf '[template:hourly]\n'
        printf '\tsend_schedule  = 5 * * * *\n'
        printf '\tprefix         = automated_hourly_\n'
        printf '\t%s\n\n' "$fld"
        printf '[dataset:tank/a]\n\tuse_template = hourly\n\tnotify       = a\n'
        printf '\tdst          =\n\tsrc          = %s\n' "$REMOTE_SRC"
    } > "$TMPD/tmpl.conf"
    render "$GEN" "$TMPD/tmpl.conf"
    if [ "$RC" -ne 0 ]; then
        ok "ownership: ${fld%% *} is refused in a [template:]"
    else
        bad "ownership: ${fld%% *} is refused in a [template:]" "accepted: $(sendline "$OUT")"
    fi
done

# Profile-forbidden, which is a statement about ownership and not about the
# grammar: naming these fields must not, in the same change, hand them to a
# layer with no way to override them per relationship.
if [ -r "$PROFILE_LIB" ]; then
    DUMP="$TMPD/schema"
    if bash "$GEN" --dump-fields > "$DUMP" 2>/dev/null && [ -s "$DUMP" ]; then
        for f in passive exclude_snapshots exclude_1; do
            if ( set -u; source "$PROFILE_LIB"; profile_field_forbidden "$f" ); then
                ok "ownership: '$f' is profile-forbidden"
            else
                bad "ownership: '$f' is profile-forbidden"
            fi
        done
        # The control the negatives above cannot give: a rule that refused
        # everything would pass all three. The fields the shipped profiles
        # actually carry must be untouched.
        for f in use_template gfs gfs_pattern; do
            if ( set -u; source "$PROFILE_LIB"; profile_field_forbidden "$f" ); then
                bad "ownership control: '$f' is NOT forbidden" "the forbidden rule is too wide"
            else
                ok "ownership control: '$f' is still allowed in a profile"
            fi
        done
    else
        bad "ownership: --dump-fields produced no schema"
    fi
else
    bad "ownership: cannot read $PROFILE_LIB"
fi

# --- 7. negative control ----------------------------------------------------
# Every config above that RENDERS must be REFUSED by the previous gen-cron.sh,
# which knows none of these field names. Run rather than described.
if [ "$HAVE_OLD" -eq 1 ]; then
    ctl_pass=0 ctl_fail=0
    for c in named multi dashpat commapat pno; do
        [ -f "$TMPD/$c.conf" ] || continue
        render "$OLDGEN" "$TMPD/$c.conf"
        if [ "$RC" -ne 0 ]; then ctl_pass=$((ctl_pass+1)); else ctl_fail=$((ctl_fail+1)); fi
    done
    if [ "$ctl_fail" -eq 0 ] && [ "$ctl_pass" -gt 0 ]; then
        ok "negative control: the previous gen-cron.sh refuses all $ctl_pass rendering configs"
    else
        bad "negative control: the previous gen-cron.sh refuses all rendering configs" \
            "$ctl_fail of $((ctl_pass+ctl_fail)) were ACCEPTED by the old build -- those assertions prove nothing"
    fi
else
    bad "negative control: could not extract HEAD:gen-cron.sh" "the control did not run"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
