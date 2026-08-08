#!/bin/bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GEN="$ROOT/gen-cron.sh"
PROFILE="$ROOT/profiles/default"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail+1)); }

for f in templates.conf dataset.inc prune.inc; do
    if [ -r "$PROFILE/$f" ]; then ok "default/$f exists"; else bad "default/$f missing"; fi
done

DUMP="$TMP/fields"
if bash "$GEN" --dump-fields >"$DUMP" 2>"$TMP/dump.err"; then
    ok "gen-cron --dump-fields is available"
else
    bad "gen-cron --dump-fields failed: $(tr '\n' ' ' < "$TMP/dump.err")"
fi

# Native fragment validator for the CONTRACT TEST only. Runtime validation is
# intentionally not implemented in Slice A. The accepted schema comes from the
# real generator; only ownership exclusions live here.
# The contract test calls the PRODUCTION validator. REV-20260808-076 point 7:
# runtime and test must share one path, so a test cannot bless a rule that
# production never executes -- which is exactly what happened here, where the
# only implementation of the ownership rule lived in this file.
. "$ROOT/lib-profile.sh"
DUMPFILE="$(mktemp)"; trap 'rm -f "$DUMPFILE"' EXIT
profile_schema_dump "$GEN" "$DUMPFILE" || { echo "cannot read the field schema: $PROFILE_ERR"; exit 1; }

validate_fragment() { profile_validate_fragment "$1" "$2" "$DUMPFILE"; }

if validate_fragment dataset "$PROFILE/dataset.inc"; then
    ok "dataset.inc contains only native profile-owned dataset fields"
else
    bad "dataset.inc violates native field/ownership contract"
fi
if validate_fragment prune "$PROFILE/prune.inc"; then
    ok "prune.inc contains only native profile-owned prune fields"
else
    bad "prune.inc violates native field/ownership contract"
fi

# templates.conf must be literal CONFIG v4 templates, not a mixed mini-config.
if grep -E '^\[' "$PROFILE/templates.conf" | grep -vqE '^\[template:[^]]+\]$'; then
    bad "templates.conf contains a non-template section"
else
    ok "templates.conf contains template sections only"
fi

# Build one complete native CONFIG v4. Relationship-owned fields and concrete
# topology are supplied by the fixture harness, not by the profile.
CAND="$TMP/candidate.conf"
{
    echo '[defaults]'
    echo 'host_label = profile-slice-a'
    cat "$PROFILE/templates.conf"
    echo
    echo '[dataset:tank/profile_a]'
    cat "$PROFILE/dataset.inc"
    echo 'notify = fixture'
    echo
    echo '[prune:tank/profile_a]'
    cat "$PROFILE/prune.inc"
    echo 'recursive = no'
    echo 'notify = fixture'
} > "$CAND"

if bash "$GEN" -c "$CAND" >"$TMP/rendered" 2>"$TMP/render.err"; then
    ok "default fragments compose into a CONFIG v4 accepted by gen-cron"
else
    bad "gen-cron rejects composed default profile: $(tr '\n' ' ' < "$TMP/render.err")"
fi

# Pin the current default policy before extraction. These are the values in the
# zfs-backup.sh hardcode at Slice A; B1/B2 must prove byte identity separately.
for needle in \
    'send_schedule  = 1 * * * *' \
    'prefix         = automated_hourly_' \
    'retain         = -H24' \
    'retain         = -D7' \
    'retain         = -W4' \
    'retain         = -M12' \
    'monitor_warn   = 90m' \
    'monitor_crit   = 150m'; do
    if grep -qF "$needle" "$PROFILE/templates.conf"; then ok "policy pin: $needle"; else bad "missing policy pin: $needle"; fi
done
if grep -qF 'use_template = standard_hourly' "$PROFILE/dataset.inc"; then ok "dataset template pin"; else bad "dataset template pin missing"; fi
if grep -qF 'gfs          = yes' "$PROFILE/prune.inc" && grep -qF 'gfs_pattern  = automated_' "$PROFILE/prune.inc"; then
    ok "GFS policy pins"
else
    bad "GFS policy pins missing"
fi

# Negative controls: prove the contract test rejects exactly the classes the
# agreed design forbids, rather than merely accepting the shipped fixture.
cp "$PROFILE/dataset.inc" "$TMP/bad-relation.inc"
echo 'src = user@host:tank/data' >> "$TMP/bad-relation.inc"
if validate_fragment dataset "$TMP/bad-relation.inc"; then bad "negative: relation-owned src was accepted"; else ok "negative: relation-owned src refused"; fi

cp "$PROFILE/prune.inc" "$TMP/bad-topology.inc"
echo 'recursive = yes' >> "$TMP/bad-topology.inc"
if validate_fragment prune "$TMP/bad-topology.inc"; then bad "negative: prune topology override was accepted"; else ok "negative: prune topology override refused"; fi

cp "$PROFILE/prune.inc" "$TMP/bad-unknown.inc"
echo 'not_a_real_gencron_field = yes' >> "$TMP/bad-unknown.inc"
if validate_fragment prune "$TMP/bad-unknown.inc"; then bad "negative: unknown field was accepted"; else ok "negative: unknown field refused via --dump-fields"; fi

cp "$PROFILE/dataset.inc" "$TMP/bad-section.inc"
echo '[dataset:tank/evil]' >> "$TMP/bad-section.inc"
if validate_fragment dataset "$TMP/bad-section.inc"; then bad "negative: section header was accepted in .inc"; else ok "negative: section header refused in .inc"; fi

# --- templates.conf is validated FIELD BY FIELD (REV-20260808-076 F1) --------
#
# It used to be checked only for section-header shape and then composed into a
# config gen-cron accepts -- and `template dst` IS legal in that schema, because
# an ordinary deployment template may carry topology. So a profile could smuggle
# topology past the contract suite. Measured before the fix: adding
# `dst = hdd/evil` to the built-in profile left this suite at 22/22.
tconf() {   # <body> -> a templates.conf in $TMP
    printf '[template:t]\n\tprefix = automated_\n%s\n' "$1" > "$TMP/t.conf"
    printf '%s' "$TMP/t.conf"
}
refuses_t() {   # <label> <body>
    if profile_validate_templates "$(tconf "$2")" "$DUMPFILE"; then
        bad "$1"
    else
        ok "$1"
    fi
}

refuses_t "negative: dst in templates.conf refused"   '	dst = hdd/evil'
refuses_t "negative: src in templates.conf refused"   '	src = root@far:tank/x'
refuses_t "negative: raw flags in templates.conf refused" '	flags = -e -u'
refuses_t "negative: pair_label in templates.conf refused" '	pair_label = prod'
refuses_t "negative: notify in templates.conf refused" '	notify = somebody'
refuses_t "negative: unknown field in templates.conf refused" '	nosuchfield = 1'
refuses_t "negative: a non-template section refused" '[dataset:tank/x]
	prefix = automated_'

# The positive control that keeps the fix honest: policy fields still pass.
if profile_validate_templates "$(tconf '	retain = -H24')" "$DUMPFILE"; then
    ok "positive: a policy-only templates.conf is accepted"
else
    bad "positive: a policy-only templates.conf is accepted" "$PROFILE_ERR"
fi

# And the real shipped profile must still validate through the same path.
if profile_validate_templates "$PROFILE/templates.conf" "$DUMPFILE"; then
    ok "the built-in profile's templates.conf passes the production validator"
else
    bad "the built-in profile's templates.conf passes the production validator" "$PROFILE_ERR"
fi
if profile_validate_dir "$PROFILE" "$GEN"; then
    ok "profile_validate_dir accepts the built-in profile"
else
    bad "profile_validate_dir accepts the built-in profile" "$PROFILE_ERR"
fi

# --- the schema must NOT be narrowed (REV-076 point 4) ----------------------
#
# A deployment-owned [template:] with dst is legitimate and runs in production:
# pve0 has [template:vm_archive] with dst = hdd/backups/pve1 feeding two real
# dataset sections. Narrowing gen-cron's schema to constrain profiles would
# break it, so this pins that gen-cron still accepts it.
cat > "$TMP/deploy.conf" <<'EOF'
[defaults]
	host_label = t

[template:vm_archive]
	send_schedule = 1 * * * *
	prefix        = automated_
	dst           = hdd/backups/pve1

[dataset:rpool/data/vm-100-disk-0]
	use_template = vm_archive
EOF
if "$GEN" -c "$TMP/deploy.conf" >/dev/null 2>&1; then
    ok "positive: an ordinary deployment [template:] with dst still renders"
else
    bad "positive: an ordinary deployment [template:] with dst still renders"
fi


echo

# --- a profile is exactly three artifacts (REV-20260809-077 F1) --------------
#
# profile_validate_dir used to write `[ -f "$dir/x" ] && ! validate`, which
# reads as "if it exists and fails, complain" -- so a MISSING artifact returned
# SUCCESS from the production boundary and an empty directory validated clean.
# The suite could not see it, because it checked the shipped fixture's files
# exist separately -- a different property, and one B1 would not inherit.
mkprofile() {   # <which to omit|-> -> a profile dir in $TMP
    local omit="$1" d="$TMP/prof.$$"
    rm -rf "$d"; mkdir -p "$d"
    [ "$omit" = templates.conf ] || cp "$PROFILE/templates.conf" "$d/"
    [ "$omit" = dataset.inc ]    || cp "$PROFILE/dataset.inc"    "$d/"
    [ "$omit" = prune.inc ]      || cp "$PROFILE/prune.inc"      "$d/"
    printf '%s' "$d"
}
refuses_dir() {   # <label> <omitted artifact>
    local d; d="$(mkprofile "$2")"
    if profile_validate_dir "$d" "$GEN"; then
        bad "$1"
    else
        case "$PROFILE_ERR" in
            *"$2"*) ok "$1" ;;
            *) bad "$1" "refused, but the message does not name $2: $PROFILE_ERR" ;;
        esac
    fi
    rm -rf "$d"
}

refuses_dir "negative: a profile without templates.conf is refused" templates.conf
refuses_dir "negative: a profile without dataset.inc is refused"    dataset.inc
refuses_dir "negative: a profile without prune.inc is refused"      prune.inc

EMPTYD="$TMP/emptyprof"; rm -rf "$EMPTYD"; mkdir -p "$EMPTYD"
if profile_validate_dir "$EMPTYD" "$GEN"; then
    bad "negative: an EMPTY profile directory is refused"
else
    ok "negative: an EMPTY profile directory is refused"
fi
rm -rf "$EMPTYD"

if profile_validate_dir "$TMP/no-such-profile-dir" "$GEN"; then
    bad "negative: a missing profile directory is refused"
else
    ok "negative: a missing profile directory is refused"
fi

# The positive control that keeps the completeness rule honest: all three
# present and valid still passes through the same call.
COMPLETE="$(mkprofile -)"
if profile_validate_dir "$COMPLETE" "$GEN"; then
    ok "positive: a complete profile still validates"
else
    bad "positive: a complete profile still validates" "$PROFILE_ERR"
fi
rm -rf "$COMPLETE"


echo "profiles: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
