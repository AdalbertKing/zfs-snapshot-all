#!/bin/bash
# The LINK fields: bandwidth, compression, cipher.
#
#   test/linkfields/run.sh
#
# What these three have in common is that they describe the WIRE a dataset flies
# over, not the policy it obeys and not the identity it connects with. Until the
# split they had no field of their own: the only way to say any of them was to
# hand-write the engine letter inside the free-form 'flags' string -- the same
# string that carries the pairing key, the pinned host key and the port, and
# which is relationship-owned and profile-forbidden for exactly that reason. So
# no layer above a hand edit could express "cap this peer at 2 MB/s" at all.
#
# The properties pinned here are the ones that make the split real rather than
# cosmetic:
#
#   1. each field renders EXACTLY the token an operator would have typed, so a
#      config that gains `bandwidth = 2M` produces the same engine invocation as
#      one carrying flags="... -b 2M";
#   2. ONE OPTION, ONE HOME -- the same option coming from both 'flags' and a
#      link field is refused, not merged and not silently preferred;
#   3. the duplicate check reads flags the way getopts does. A bundled `-eb 2M`
#      carries -b and must be caught; an ARGUMENT that merely looks like a
#      letter (`-m b-daily_`) carries none and must not be. Both directions are
#      asserted, because a substring rule passes one and fails the other;
#   4. an explicit compressor makes -A stand down, so the link fields must be
#      rendered BEFORE autotune is considered. Getting that order wrong emits a
#      line carrying both -A and -Z: a cron job that announces a no-op on every
#      run. Asserted with its own control (no compression -> -A comes back);
#   5. the fields are [dataset:]-only and profile-forbidden -- a policy carrier
#      is shared by datasets that do not share a destination.
#
# NEGATIVE CONTROL, run every time rather than described: every rendering
# assertion is re-run against the PREVIOUS committed gen-cron.sh, which must
# reject the same config as carrying unknown fields. A suite that would pass
# against the build before the change proves nothing about the change.
#
# No ZFS and no remote host: gen-cron.sh is a pure text tool, and the
# zfs-backup.sh helper under test here is lifted and run in isolation.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${LINKFIELDS_REPO:-$(cd "$DIR/../.." && pwd)}"
GEN="${GEN:-$REPO/gen-cron.sh}"
ZB="$REPO/zfs-backup.sh"
PROFILE_LIB="$REPO/lib-profile.sh"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; FAIL=$((FAIL+1)); }

TMPD=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPD"' EXIT

# A minimal config that renders: one tier, one dataset, one remote destination.
# EXTRA lines are appended inside the [dataset:] section, which is where every
# link field belongs.
mkconf() {   # <file> <dst> <extra lines...>
    local f="$1" dst="$2"; shift 2
    {
        printf '[defaults]\n\thost_label = lab\n\n'
        printf '[template:hourly]\n'
        printf '\tsend_schedule  = 5 * * * *\n'
        printf '\tprefix         = automated_hourly_\n'
        printf '\tnotify_word    = snapshot\n'
        printf '\tprune_schedule = 35 * * * *\n'
        printf '\tpattern        = automated_hourly\n'
        printf '\tkeep           = 24\n\n'
        printf '[dataset:tank/a]\n'
        printf '\tuse_template = hourly\n'
        printf '\tnotify       = a\n'
        [ -n "$dst" ] && printf '\tdst          = %s\n' "$dst"
        local line; for line in "$@"; do printf '\t%s\n' "$line"; done
    } > "$f"
}

# The real tool, with a deterministic environment so the caller's shell cannot
# leak paths or schedules into the rendered lines.
# Sets OUT and RC in the CALLER. Deliberately not `out=$(render ...)`: a status
# assigned inside a command substitution is set in the SUBSHELL and is gone by
# the time the caller reads it -- which is how the first cut of this suite
# managed to fail every assertion with "RC: unbound variable".
render() {   # <gen-cron path> <conf> -> sets OUT, RC
    OUT=$(env -u REPO_DIR -u NOTIFY_SCRIPT -u WARN_SCRIPT -u DIGEST_SCRIPT \
              -u CRON_LOG -u DIGEST_SCHEDULE bash "$1" -c "$2" 2>&1)
    RC=$?
}

# The generated snapsend/snapget invocation, isolated from the cron wrapper
# around it -- the assertions are about the engine command line.
# The cron line quotes its arguments, so a [^"]* capture stops at the first
# quoted value (-m "automated_hourly_") and hides everything the assertions are
# about. Take the whole tail and cut at the stderr redirection the wrapper adds.
sendline() {   # <output> -> the engine call
    printf '%s\n' "$1" | grep -o 'snapsend\.sh.*' | head -1 | sed 's/ 2>"\$e".*//'
}

# The previous committed gen-cron.sh, for the built-in negative control.
OLDGEN="$TMPD/gen-cron.old.sh"
if git -C "$REPO" show HEAD:gen-cron.sh > "$OLDGEN" 2>/dev/null && [ -s "$OLDGEN" ]; then
    HAVE_OLD=1
else
    HAVE_OLD=0
fi

REMOTE='root@10.0.0.1:hdd/kopie'

# --- 1. each field renders its own token -----------------------------------
for spec in "bandwidth    = 2M|-b 2M" \
            "compression  = zstd|-Z" \
            "compression  = gzip|-g" \
            "compression  = none|-N" \
            "cipher       = aes128-gcm@openssh.com|-c aes128-gcm@openssh.com"; do
    field="${spec%%|*}"; want="${spec##*|}"
    mkconf "$TMPD/r.conf" "$REMOTE" "$field"
    render "$GEN" "$TMPD/r.conf"; out="$OUT"; line=$(sendline "$out")
    if [ "$RC" -ne 0 ]; then
        bad "render: ${field%% *} -> $want" "exit $RC: $out"
    elif [ "${line#*"$want"}" != "$line" ]; then
        ok "render: ${field%% *} -> $want"
    else
        bad "render: ${field%% *} -> $want" "line: $line"
    fi
done

# 'default' means "whatever the engine decides for this destination" -- the same
# thing an omitted field means, so it must add no compressor letter at all.
mkconf "$TMPD/dflt.conf" "$REMOTE" "compression  = default"
render "$GEN" "$TMPD/dflt.conf"; out="$OUT"; line=$(sendline "$out")
case "$line" in
    *" -Z"*|*" -g"*|*" -N"*) bad "compression=default adds no compressor" "line: $line" ;;
    *) [ "$RC" -eq 0 ] && ok "compression=default adds no compressor" || bad "compression=default adds no compressor" "exit $RC: $out" ;;
esac

# The whole point of naming the field: same engine call as the hand-written flag.
mkconf "$TMPD/named.conf" "$REMOTE" "bandwidth    = 2M"
mkconf "$TMPD/hand.conf"  "$REMOTE" "flags        = -b 2M"
render "$GEN" "$TMPD/named.conf"; a=$(sendline "$OUT")
render "$GEN" "$TMPD/hand.conf"; b=$(sendline "$OUT")
if [ -n "$a" ] && [ "$a" = "$b" ]; then
    ok "the named field and the hand-written flag produce the identical engine call"
else
    bad "the named field and the hand-written flag produce the identical engine call" "named: $a
hand:  $b"
fi

# --- 2. one option, one home ------------------------------------------------
for spec in "flags        = -b 1M|bandwidth    = 2M|-b" \
            "flags        = -z|compression  = gzip|-z" \
            "flags        = -Z|compression  = none|-Z" \
            "flags        = -c aes128-ctr|cipher       = aes256-ctr|-c"; do
    IFS='|' read -r fl fi tok <<< "$spec"
    mkconf "$TMPD/dup.conf" "$REMOTE" "$fl" "$fi"
    render "$GEN" "$TMPD/dup.conf"; out="$OUT"
    if [ "$RC" -eq 0 ]; then
        bad "refuses ${fi%% *} while flags carries $tok" "rendered anyway: $(sendline "$out")"
    elif printf '%s' "$out" | grep -q 'one option, one home'; then
        ok "refuses ${fi%% *} while flags carries $tok"
    else
        bad "refuses ${fi%% *} while flags carries $tok" "wrong reason: $out"
    fi
done

# --- 3. the duplicate check reads flags the way getopts does ----------------
# Bundled: -eb 2M is -e -b 2M. A whole-token comparison misses it.
mkconf "$TMPD/bundle.conf" "$REMOTE" "flags        = -eb 2M" "bandwidth    = 4M"
render "$GEN" "$TMPD/bundle.conf"; out="$OUT"
if [ "$RC" -ne 0 ] && printf '%s' "$out" | grep -q 'one option, one home'; then
    ok "bundled -eb in flags is caught as a -b (getopts walk, not a token match)"
else
    bad "bundled -eb in flags is caught as a -b" "exit $RC: $out"
fi

# The other direction, and the control for the case above: an option ARGUMENT
# that happens to contain the letter is not an option. A substring rule refuses
# this one, which would make a legal config unrenderable.
mkconf "$TMPD/arg.conf" "$REMOTE" "flags        = -m b-daily_" "bandwidth    = 4M"
render "$GEN" "$TMPD/arg.conf"; out="$OUT"; line=$(sendline "$out")
if [ "$RC" -eq 0 ] && [ "${line#*-b 4M}" != "$line" ]; then
    ok "an argument containing the letter ('-m b-daily_') is not a -b"
else
    bad "an argument containing the letter is not a -b" "exit $RC: ${out:-$line}"
fi

# --- 4. an explicit compressor stands -A down ------------------------------
mkconf "$TMPD/comp.conf" "$REMOTE" "compression  = zstd"
render "$GEN" "$TMPD/comp.conf"; line=$(sendline "$OUT")
case "$line" in
    *" -A"*) bad "compression suppresses the automatic -A" "line: $line" ;;
    *)       ok "compression suppresses the automatic -A" ;;
esac
# Control: without it, -A must still be added -- otherwise the assertion above
# would pass for the wrong reason (e.g. autotune broken entirely).
mkconf "$TMPD/noa.conf" "$REMOTE" "bandwidth    = 2M"
render "$GEN" "$TMPD/noa.conf"; line=$(sendline "$OUT")
case "$line" in
    *" -A"*) ok "control: with no compressor, -A is still added" ;;
    *)       bad "control: with no compressor, -A is still added" "line: $line" ;;
esac

# --- 5. blank and malformed values -----------------------------------------
for spec in "bandwidth    =|present but blank" \
            "compression  =|present but blank" \
            "cipher       =|present but blank" \
            "bandwidth    = 20Mbps|expected an mbuffer rate" \
            "bandwidth    = -b 2M|give the RATE only" \
            "compression  = lz4|expected zstd, gzip, none or default" \
            "cipher       = -o Foo=bar|give the cipher only"; do
    field="${spec%%|*}"; want="${spec##*|}"
    mkconf "$TMPD/bad.conf" "$REMOTE" "$field"
    render "$GEN" "$TMPD/bad.conf"; out="$OUT"
    if [ "$RC" -eq 0 ]; then
        bad "refuses '$field'" "rendered anyway: $(sendline "$out")"
    elif printf '%s' "$out" | grep -qF "$want"; then
        ok "refuses '$field'"
    else
        bad "refuses '$field'" "wrong reason: $out"
    fi
done

# A cipher list is ONE ssh argument; a space means a second option is being
# smuggled in behind the -c.
mkconf "$TMPD/list.conf" "$REMOTE" "cipher       = aes128-gcm@openssh.com,aes256-ctr"
render "$GEN" "$TMPD/list.conf"; line=$(sendline "$OUT")
if [ "${line#*-c aes128-gcm@openssh.com,aes256-ctr}" != "$line" ]; then
    ok "a comma-separated cipher list is one argument and renders whole"
else
    bad "a comma-separated cipher list renders whole" "line: $line"
fi

# --- 6. the fields belong to a [dataset:], nowhere else ---------------------
for kind in template defaults; do
    if [ "$kind" = template ]; then
        mkconf "$TMPD/wrong.conf" "$REMOTE"
        sed -i 's|^\tkeep           = 24|\tkeep           = 24\n\tbandwidth      = 2M|' "$TMPD/wrong.conf"
    else
        mkconf "$TMPD/wrong.conf" "$REMOTE"
        sed -i 's|^\thost_label = lab|\thost_label = lab\n\tbandwidth  = 2M|' "$TMPD/wrong.conf"
    fi
    render "$GEN" "$TMPD/wrong.conf"; out="$OUT"
    if [ "$RC" -ne 0 ] && printf '%s' "$out" | grep -q "bandwidth"; then
        ok "'bandwidth' is refused in a [$kind:] section"
    else
        bad "'bandwidth' is refused in a [$kind:] section" "exit $RC: $out"
    fi
done

# --- 7. profile-forbidden ---------------------------------------------------
# The link belongs to a PAIR OF HOSTS. A profile does not know which link it
# will fly over, so naming these fields must not make them inheritable policy.
for f in bandwidth compression cipher; do
    if ( set -u; . "$PROFILE_LIB" >/dev/null 2>&1; profile_field_forbidden "$f" ); then
        ok "a profile may not carry '$f'"
    else
        bad "a profile may not carry '$f'" "profile_field_forbidden returned non-zero"
    fi
done
# Control: a genuine policy field must still be allowed, or the assertions above
# would pass against a function that forbids everything.
if ( set -u; . "$PROFILE_LIB" >/dev/null 2>&1; profile_field_forbidden keep ); then
    bad "control: 'keep' is still a legal profile field" "keep came back forbidden"
else
    ok "control: 'keep' is still a legal profile field"
fi

# --- 8. the record -> section writer ---------------------------------------
# set_or_remove_section_field is what keeps an installed section in step with
# the client record across a re-activation. Lifted and run in isolation: the
# question is its three cases, not whether this machine has ZFS.
lift() {   # <function name> -> its source
    awk -v want="$1() {" 'index($0, want)==1 {f=1} f{print} f&&/^\}$/{exit}' "$ZB"
}
helper_env() {   # -> a script preamble carrying the two functions and mv helper
    printf 'set -u\n'
    printf 'mv_preserving_mode() { mv "$1" "$2"; }\n'
    lift update_section_field
    lift set_or_remove_section_field
}

mksection() {   # <file> [extra field line]
    { printf '[dataset:tank/a]\n\tsrc          = a@h:tank/a\n\tflags        = -K /k\n'
      [ -n "${1:-}" ] && printf '\t%s\n' "$1"
      printf '\tpair_label   = rel\n\n[dataset:tank/b]\n\tflags        = -K /k\n'; } > "$TMPD/sec.conf"
}

# insert (field absent)
mksection
{ helper_env; printf 'set_or_remove_section_field %q "[dataset:tank/a]" bandwidth 2M\n' "$TMPD/sec.conf"; } > "$TMPD/h.sh"
bash "$TMPD/h.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'bandwidth = 2M' "$TMPD/sec.conf" \
   && [ "$(grep -c 'bandwidth' "$TMPD/sec.conf")" -eq 1 ]; then
    ok "set_or_remove_section_field inserts a missing field, once"
else
    bad "set_or_remove_section_field inserts a missing field, once" "rc=$rc
$(cat "$TMPD/sec.conf")"
fi
# and it inserted into the RIGHT section
if ! sed -n '/\[dataset:tank\/b\]/,$p' "$TMPD/sec.conf" | grep -q bandwidth; then
    ok "the insert lands in the named section, not the next one"
else
    bad "the insert lands in the named section, not the next one" "$(cat "$TMPD/sec.conf")"
fi

# update (field present)
mksection "bandwidth    = 1M"
{ helper_env; printf 'set_or_remove_section_field %q "[dataset:tank/a]" bandwidth 4M\n' "$TMPD/sec.conf"; } > "$TMPD/h.sh"
bash "$TMPD/h.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'bandwidth    = 4M' "$TMPD/sec.conf" && ! grep -q '1M' "$TMPD/sec.conf"; then
    ok "an existing field is rewritten in place"
else
    bad "an existing field is rewritten in place" "rc=$rc
$(cat "$TMPD/sec.conf")"
fi

# delete (empty value) -- an uncapped record must take the line with it
mksection "bandwidth    = 1M"
{ helper_env; printf 'set_or_remove_section_field %q "[dataset:tank/a]" bandwidth ""\n' "$TMPD/sec.conf"; } > "$TMPD/h.sh"
bash "$TMPD/h.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'bandwidth' "$TMPD/sec.conf" && grep -q 'pair_label' "$TMPD/sec.conf"; then
    ok "an emptied value deletes the field and nothing else"
else
    bad "an emptied value deletes the field and nothing else" "rc=$rc
$(cat "$TMPD/sec.conf")"
fi

# fail-closed: a header that is not in the file is an error, not a silent no-op
mksection
{ helper_env; printf 'set_or_remove_section_field %q "[dataset:tank/zzz]" bandwidth 2M\n' "$TMPD/sec.conf"; } > "$TMPD/h.sh"
bash "$TMPD/h.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 3 ]; then
    ok "a missing section header fails closed (rc=3), it does not report success"
else
    bad "a missing section header fails closed" "rc=$rc"
fi

# --- 9. THE NEGATIVE CONTROL ------------------------------------------------
# Every rendering assertion above must be impossible on the previous build.
if [ "$HAVE_OLD" -eq 1 ]; then
    caught=0 total=0
    for f in "bandwidth    = 2M" "compression  = zstd" "cipher       = aes128-ctr"; do
        total=$((total+1))
        mkconf "$TMPD/old.conf" "$REMOTE" "$f"
        render "$OLDGEN" "$TMPD/old.conf"; out="$OUT"
        [ "$RC" -ne 0 ] && caught=$((caught+1))
    done
    if [ "$caught" -eq "$total" ]; then
        ok "negative control: the previous gen-cron.sh rejects all $total link fields as unknown"
    else
        bad "negative control: the previous gen-cron.sh rejects all link fields" \
            "only $caught of $total were rejected -- these assertions would pass without the change"
    fi
else
    bad "negative control" "could not read HEAD:gen-cron.sh -- the control did not run"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
