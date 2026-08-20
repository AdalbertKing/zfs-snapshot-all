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
. "${PROFLIB:-$ROOT/lib-profile.sh}"
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


# ---- Slice B1: rendering a profile into effective CONFIG v4 -----------------
#
# Namespacing is the requirement from PER-SOURCE-PROFILE-SCENARIOS: two profiles
# bound in one relationship compose into ONE config, and gen-cron refuses a
# duplicate [template:NAME]. These cases pin the mapping, the reference rewrite
# and the two refusals that keep it safe.

RD="$TMP/render"; mkdir -p "$RD"

if profile_render_templates "$ROOT/profiles/default" default "$RD/t.conf"; then
    ok "render: the built-in profile renders its templates"
else
    bad "render: the built-in profile renders its templates" "$PROFILE_ERR"
fi

if grep -q '^\[template:profile__default__standard_hourly\]$' "$RD/t.conf"; then
    ok "render: template sections carry the deterministic namespace"
else
    bad "render: template sections carry the deterministic namespace"
fi

# The bare name must NOT survive: a host's own hand-written [template:standard_hourly]
# is somebody else's policy, and binding to it is the failure this prevents.
if grep -q '^\[template:standard_hourly\]$' "$RD/t.conf"; then
    bad "render: the bare template name does not survive rendering"
else
    ok "render: the bare template name does not survive rendering"
fi

if profile_render_fragment "$ROOT/profiles/default/prune.inc" default "$RD/p.inc"; then
    ok "render: a fragment renders"
else
    bad "render: a fragment renders" "$PROFILE_ERR"
fi

# Every reference rewritten, none left bare -- a half-rewritten list would
# resolve some tiers to this profile and some to whatever the host already has.
if grep -q 'use_template = profile__default__keep_hourly,profile__default__keep_daily,profile__default__keep_weekly,profile__default__keep_monthly' "$RD/p.inc"; then
    ok "render: every use_template reference is rewritten, in order"
else
    bad "render: every use_template reference is rewritten, in order" "$(grep use_template "$RD/p.inc")"
fi

# Non-template lines are carried through untouched -- gfs=/gfs_pattern= are the
# policy the profile exists to supply.
if grep -q '^gfs *= *yes' "$RD/p.inc" && grep -q '^gfs_pattern *= *automated_' "$RD/p.inc"; then
    ok "render: policy fields other than use_template are untouched"
else
    bad "render: policy fields other than use_template are untouched"
fi

# A reference this profile does not define is REFUSED rather than passed
# through. This is the structural half of "never silently bind to an unrelated
# hand-written template": an unknown name cannot be referenced at all.
UNK="$TMP/unknown-ref.inc"
printf 'use_template = keep_hourly,not_mine\n' > "$UNK"
if profile_render_fragment "$UNK" default "$RD/u.inc"; then
    bad "render: a reference the profile does not define is refused"
else
    case "$PROFILE_ERR" in
        *not_mine*) ok "render: a reference the profile does not define is refused" ;;
        *) bad "render: a reference the profile does not define is refused" "$PROFILE_ERR" ;;
    esac
fi

# A duplicate inside one profile is caught HERE, naming the profile. gen-cron
# would also refuse the composed file, but its message names only a temporary
# path and tells the operator nothing about which profile produced it.
DUPP="$(mkprofile -)"
printf '\n[template:standard_hourly]\n\tsend_schedule = 5 * * * *\n' >> "$DUPP/templates.conf"
if profile_render_templates "$DUPP" default "$RD/dup.conf"; then
    bad "render: a duplicate template inside one profile is refused"
else
    case "$PROFILE_ERR" in
        *standard_hourly*default*) ok "render: a duplicate template inside one profile is refused" ;;
        *) bad "render: a duplicate template inside one profile is refused" "$PROFILE_ERR" ;;
    esac
fi
rm -rf "$DUPP"

# A profile name that could break a section header is refused, not sanitised.
if profile_render_templates "$ROOT/profiles/default" 'bad name]' "$RD/bad.conf"; then
    bad "render: a profile name unusable in a header is refused"
else
    ok "render: a profile name unusable in a header is refused"
fi

# The property the whole scheme exists for: two profiles compose without
# colliding. Same source templates, two names, one config gen-cron accepts.
profile_render_templates "$ROOT/profiles/default" flat   "$RD/flat.conf"   || bad "render: two-profile composition (flat)"   "$PROFILE_ERR"
profile_render_templates "$ROOT/profiles/default" atomic "$RD/atomic.conf" || bad "render: two-profile composition (atomic)" "$PROFILE_ERR"
{
    printf '[defaults]\n\thost_label = t\n\tdst = hdd/backups\n\n'
    cat "$RD/flat.conf"; printf '\n'; cat "$RD/atomic.conf"
    printf '\n[dataset:rpool/data]\n\tuse_template = profile__flat__standard_hourly\n\trecursive = flat\n'
    printf '\n[dataset:rpool/lxc]\n\tuse_template = profile__atomic__standard_hourly\n\trecursive = atomic\n'
} > "$RD/composed.conf"
if bash "$GEN" -c "$RD/composed.conf" >/dev/null 2>&1; then
    ok "render: two profiles compose into one config gen-cron accepts"
else
    bad "render: two profiles compose into one config gen-cron accepts" "$(bash "$GEN" -c "$RD/composed.conf" 2>&1 | tail -2)"
fi

# ...and the negative that proves the collision is real rather than assumed:
# the same two profiles WITHOUT namespacing are refused by gen-cron.
{
    printf '[defaults]\n\thost_label = t\n\tdst = hdd/backups\n\n'
    cat "$ROOT/profiles/default/templates.conf"; printf '\n'
    cat "$ROOT/profiles/default/templates.conf"
    printf '\n[dataset:rpool/data]\n\tuse_template = standard_hourly\n'
} > "$RD/collide.conf"
if bash "$GEN" -c "$RD/collide.conf" >/dev/null 2>&1; then
    bad "render: WITHOUT namespacing the same two profiles collide"
else
    ok "render: WITHOUT namespacing the same two profiles collide"
fi


# ---- REV-081 F1: the encoding must be INJECTIVE, not merely separated -------
#
# The first version concatenated with `__` and called that disjoint identity.
# It is not, and the counterexample is exact:
#
#     profile "a__b", template "c"    -> profile__a__b__c
#     profile "a",    template "b__c" -> profile__a__b__c
#
# Two distinct pairs, one section identity -- the collision the namespace exists
# to prevent, moved from the native names into the separator.
#
# First: DEMONSTRATE the collision from the encoding itself rather than assert
# it. If these two ever stop being equal the rejection rule below is guarding
# nothing and this case says so.
n1="$(profile_ns_name 'a__b' 'c')"
n2="$(profile_ns_name 'a' 'b__c')"
if [ "$n1" = "$n2" ]; then
    ok "injectivity: the bare encoding really does collide ($n1)"
else
    bad "injectivity: the bare encoding really does collide" "n1=$n1 n2=$n2"
fi

# The contract chosen is option 2 from the review: a restricted naming domain
# in which the separator cannot occur inside either component. So BOTH members
# of the colliding pair are refused at the boundary, before rendering -- which
# is why "both profiles independently validate" cannot hold here and is not
# claimed.
COLL1="$(mkprofile -)"
if profile_render_templates "$COLL1" 'a__b' "$RD/coll1.conf"; then
    bad "injectivity: a profile NAME carrying the separator is refused"
else
    case "$PROFILE_ERR" in
        *"$PROFILE_NS_SEP"*|*separator*) ok "injectivity: a profile NAME carrying the separator is refused" ;;
        *) bad "injectivity: a profile NAME carrying the separator is refused" "$PROFILE_ERR" ;;
    esac
fi
rm -rf "$COLL1"

# The other half: a native TEMPLATE name carrying the separator. Refused at
# validation, so such a profile never reaches a runtime at all...
COLL2="$(mkprofile -)"
printf '\n[template:b__c]\n\tsend_schedule = 1 * * * *\n\tprefix = x_\n' >> "$COLL2/templates.conf"
if profile_validate_dir "$COLL2" "$GEN"; then
    bad "injectivity: a TEMPLATE name carrying the separator is refused at validation"
else
    case "$PROFILE_ERR" in
        *b__c*) ok "injectivity: a TEMPLATE name carrying the separator is refused at validation" ;;
        *) bad "injectivity: a TEMPLATE name carrying the separator is refused at validation" "$PROFILE_ERR" ;;
    esac
fi
# ...and refused again at the render boundary, because rendering is what
# actually encodes the name and must not depend on a caller having validated.
if profile_render_templates "$COLL2" default "$RD/coll2.conf"; then
    bad "injectivity: a TEMPLATE name carrying the separator is refused at render too"
else
    case "$PROFILE_ERR" in
        *b__c*) ok "injectivity: a TEMPLATE name carrying the separator is refused at render too" ;;
        *) bad "injectivity: a TEMPLATE name carrying the separator is refused at render too" "$PROFILE_ERR" ;;
    esac
fi
rm -rf "$COLL2"

# The rule must not be wider than the defect: single underscores are how every
# built-in template is named, and a hyphenated profile name is ordinary.
if profile_render_templates "$ROOT/profiles/default" 'site-a' "$RD/ok1.conf"; then
    ok "injectivity: single underscores and hyphens are still accepted"
else
    bad "injectivity: single underscores and hyphens are still accepted" "$PROFILE_ERR"
fi



###############################################################################
# PROFILE "tiered" -- the four-family, flat-counter shape.
#
# Every assertion below is one the DEFAULT profile would FAIL, which is the
# point: "profiles/tiered exists and validates" would also pass against a copy
# of default, and would pin nothing. What distinguishes the two profiles is the
# emitted block, so that is what is asserted -- and it is asserted through the
# REAL gen-cron.sh, because "the fragment parses" is the appearance this
# project keeps mistaking for the property (REV-20260809-082 V1).
###############################################################################
TI="$ROOT/profiles/tiered"

if profile_validate_dir "$TI" "$GEN"; then
    ok "tiered: validates against the production validator"
else
    bad "tiered: validates against the production validator" "$PROFILE_ERR"
fi

TD="$TMP/tiered"; mkdir -p "$TD"
if profile_render_templates "$TI" tiered "$TD/tpl.conf" \
   && profile_render_fragment "$TI/dataset.inc" tiered "$TD/ds.inc" \
   && profile_render_fragment "$TI/prune.inc" tiered "$TD/pr.inc"; then
    ok "tiered: renders"
else
    bad "tiered: renders" "$PROFILE_ERR"
fi

{
    printf '[defaults]\n\thost_label = tprof\n\n'
    cat "$TD/tpl.conf"
    printf '\n[dataset:tank/backups/c1/rpool/data]\n'
    cat "$TD/ds.inc"
    printf '\tsrc          = zfsbackup@10.0.0.1:rpool/data\n\tpair_label   = c1\n\tnotify       = c1-data\n'
    printf '\n[prune:tank/backups/c1]\n'
    cat "$TD/pr.inc"
    printf '\trecursive    = yes\n\tpair_label   = c1\n\tnotify       = c1\n'
} > "$TD/cand.conf"

TOUT="$TD/out.txt"
if bash "$GEN" -c "$TD/cand.conf" > "$TOUT" 2>"$TD/err.txt"; then
    ok "tiered: the composed config is accepted by the REAL gen-cron.sh"
else
    bad "tiered: the composed config is accepted by the REAL gen-cron.sh" "$(head -2 "$TD/err.txt")"
fi

# FOUR families created, one per tier. The default profile creates ONE.
n=$(grep -c 'snapget.sh' "$TOUT")
if [ "$n" -eq 4 ]; then ok "tiered: four send lines, one per tier"
else bad "tiered: four send lines, one per tier" "got $n"; fi

miss=""
for p in automated_hourly_ automated_daily_ automated_weekly_ automated_monthly_; do
    grep -q -- "-m \"$p\"" "$TOUT" || miss="$miss $p"
done
if [ -z "$miss" ]; then ok "tiered: each tier stamps its own family prefix"
else bad "tiered: each tier stamps its own family prefix" "missing:$miss"; fi

# quiesce from daily upwards, never on hourly. A freeze costs a write stall in
# the guest; paying it 24x a day for a snapshot that lives 24 hours is the
# trade this profile deliberately does not make.
hq=$(grep 'snapget.sh' "$TOUT" | grep -c -- '-m "automated_hourly_".*-q')
oq=$(grep 'snapget.sh' "$TOUT" | grep -cE -- '-m "automated_(daily|weekly|monthly)_".*-q auto')
if [ "$hq" -eq 0 ] && [ "$oq" -eq 3 ]; then
    ok "tiered: quiesce on daily/weekly/monthly, never on hourly"
else
    bad "tiered: quiesce on daily/weekly/monthly, never on hourly" "hourly-with-q=$hq daily+=$oq"
fi

# FLAT counters, one delsnaps line per family -- and NO ladder. This is the
# assertion that would fail against the default profile, which emits exactly
# one `delsnaps.sh -G`.
n=$(grep -c 'delsnaps.sh' "$TOUT")
g=$(grep -c 'delsnaps.sh -G' "$TOUT")
if [ "$n" -eq 4 ] && [ "$g" -eq 0 ]; then
    ok "tiered: four flat prune lines and no GFS ladder"
else
    bad "tiered: four flat prune lines and no GFS ladder" "delsnaps=$n with -G=$g"
fi

miss=""
for r in '"automated_hourly" -H24' '"automated_daily" -D7' '"automated_weekly" -W4' '"automated_monthly" -M6'; do
    grep -qF -- "$r" "$TOUT" || miss="$miss [$r]"
done
if [ -z "$miss" ]; then ok "tiered: each family is pruned by its own counter"
else bad "tiered: each family is pruned by its own counter" "missing:$miss"; fi

# Per-tier monitors -- and none on monthly, which production removed on
# 2026-07-22 after a ~35d threshold fired against every dataset using the tier.
n=$(grep -c 'check-snap-age.sh' "$TOUT")
mm=$(grep -c 'check-snap-age.sh.*automated_monthly' "$TOUT")
if [ "$n" -eq 3 ] && [ "$mm" -eq 0 ]; then
    ok "tiered: a monitor per tier except monthly"
else
    bad "tiered: a monitor per tier except monthly" "monitors=$n monthly=$mm"
fi

# The two profiles must stay DISTINGUISHABLE. If someone edits tiered into a
# copy of default this goes red, where every assertion above would still pass
# on a single-family ladder that happened to keep the tier names.
if ! diff -q "$TI/prune.inc" "$ROOT/profiles/default/prune.inc" >/dev/null; then
    ok "tiered: prune policy differs from default"
else
    bad "tiered: prune policy differs from default" "the two prune.inc are identical"
fi

echo "profiles: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
