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

# A profile is ONE file since 2026-08-25. This used to check three.
if [ -r "$PROFILE/profile.conf" ]; then ok "default/profile.conf exists"; else bad "default/profile.conf missing"; fi
for f in templates.conf dataset.inc prune.inc; do
    if [ -e "$PROFILE/$f" ]; then bad "default/$f still shipped -- the three-file layout was replaced, not doubled"; else ok "default/$f is gone (one file now)"; fi
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

# ---------------------------------------------------------------------------
# ONE FILE. A profile is profiles/<name>/profile.conf, and the three artifacts
# the runtime consumes are produced from it. The suite therefore splits the
# same way the runtime does, so the validator and renderer assertions below
# keep testing what they always tested -- the content -- rather than the layout
# it used to be stored in.
# ---------------------------------------------------------------------------
psplit() {   # <profile dir> -> echoes "<tpl> <ds> <prune> <excl>" of temp files
    local d="$1" t x p2 e
    t="$(mktemp)"; x="$(mktemp)"; p2="$(mktemp)"; e="$(mktemp)"
    profile_split_one_file "$d/profile.conf" "$t" "$x" "$p2" "$e" || return 1
    cat "$e" >> "$t"
    printf '%s %s %s %s' "$t" "$x" "$p2" "$e"
}
LETTERS="$(mktemp)"; bash "$GEN" --dump-tier-letters > "$LETTERS"
PSPLIT_DEFAULT=($(psplit "$ROOT/profiles/default"))
TPL_DEFAULT="${PSPLIT_DEFAULT[0]}"
DS_DEFAULT="${PSPLIT_DEFAULT[1]}"
PR_DEFAULT="${PSPLIT_DEFAULT[2]}"

# ...and the RENDERED form, which is what a host actually installs: namespaced
# names, and `keep` already translated to the engine's own flag. The composed
# fixture below must use these, not the source: gen-cron never sees a profile's
# bare tier names, and feeding it those tests a config that cannot exist.
RND_TPL="$(mktemp)"; RND_DS="$(mktemp)"; RND_PR="$(mktemp)"
profile_render_templates "$TPL_DEFAULT" default "$RND_TPL" "" "$LETTERS" || echo "FATAL: render tpl: $PROFILE_ERR" >&2
profile_render_fragment  "$DS_DEFAULT"  default "$RND_DS"  || echo "FATAL: render ds: $PROFILE_ERR" >&2
profile_render_fragment  "$PR_DEFAULT"  default "$RND_PR"  || echo "FATAL: render prune: $PROFILE_ERR" >&2


if validate_fragment dataset "$DS_DEFAULT"; then
    ok "dataset.inc contains only native profile-owned dataset fields"
else
    bad "dataset.inc violates native field/ownership contract"
fi
if validate_fragment prune "$PR_DEFAULT"; then
    ok "prune.inc contains only native profile-owned prune fields"
else
    bad "prune.inc violates native field/ownership contract"
fi

# templates.conf carries literal CONFIG v4 sections, not a mixed mini-config --
# and since 2026-08-25 that is TWO kinds, not one. REWRITTEN rather than
# deleted: the property is "only sections a profile may own", and the reserved
# families became one of them by owner decision. They compose differently from
# templates (shared, never namespaced), which is why they are rendered to their
# own artifact -- so the rule that matters here is still that nothing else gets
# in.
if grep -E '^\[' "$TPL_DEFAULT" | grep -vqE '^\[(template|excluded):[^]]+\]$'; then
    bad "templates.conf contains a section a profile may not own"
else
    ok "templates.conf contains template sections only"
fi

# Build one complete native CONFIG v4. Relationship-owned fields and concrete
# topology are supplied by the fixture harness, not by the profile.
CAND="$TMP/candidate.conf"
{
    echo '[defaults]'
    echo 'host_label = profile-slice-a'
    cat "$RND_TPL"
    echo
    echo '[dataset:tank/profile_a]'
    cat "$RND_DS"
    echo 'notify = fixture'
    echo
    echo '[prune:tank/profile_a]'
    cat "$RND_PR"
    echo 'recursive = no'
    echo 'notify = fixture'
} > "$CAND"

if bash "$GEN" -c "$CAND" >"$TMP/rendered" 2>"$TMP/render.err"; then
    ok "default fragments compose into a CONFIG v4 accepted by gen-cron"
else
    bad "gen-cron rejects composed default profile: $(tr '\n' ' ' < "$TMP/render.err")"
fi

# Pin the current default policy. The retentions are pinned in BOTH spellings
# on purpose, because since 2026-08-25 they have two:
#
#   the profile SAYS      keep = 24        (what production writes, readable)
#   the render EMITS      retain = -H24    (what the generator takes)
#
# The translation happens in profile_render_templates, from the tier's cadence,
# because a profile's names are namespaced before the generator sees them and
# the letter can no longer be derived there. Pinning only the source would let
# the translation break silently; pinning only the render would not notice a
# profile that changed its retention.
for needle in \
    'send_schedule  = 1 * * * *' \
    'prefix         = automated_hourly_' \
    'keep           = 24' \
    'keep           = 7' \
    'keep           = 4' \
    'keep           = 12' \
    'monitor_warn   = 90m' \
    'monitor_crit   = 150m'; do
    if grep -qF "$needle" "$TPL_DEFAULT"; then ok "policy pin (profile): $needle"; else bad "missing policy pin (profile): $needle"; fi
done

# ...and the other half: the render must turn each of those into the engine's
# own flag, with the right letter for the tier's cadence.
PINRENDER="$TMP/pin-render.conf"
if profile_render_templates "$TPL_DEFAULT" default "$PINRENDER" "" "$LETTERS"; then
    for needle in 'retain         = -H24' 'retain         = -D7' 'retain         = -W4' 'retain         = -M12'; do
        if grep -qF "$needle" "$PINRENDER"; then ok "policy pin (render): $needle"; else bad "missing policy pin (render): $needle"; fi
    done
else
    bad "policy pin (render): the built-in profile does not render" "$PROFILE_ERR"
fi
if grep -qF 'use_template = standard_hourly' "$DS_DEFAULT"; then ok "dataset template pin"; else bad "dataset template pin missing"; fi
if grep -qF 'gfs          = yes' "$PR_DEFAULT" && grep -qF 'gfs_pattern  = automated_' "$PR_DEFAULT"; then
    ok "GFS policy pins"
else
    bad "GFS policy pins missing"
fi

# Negative controls: prove the contract test rejects exactly the classes the
# agreed design forbids, rather than merely accepting the shipped fixture.
cp "$DS_DEFAULT" "$TMP/bad-relation.inc"
echo 'src = user@host:tank/data' >> "$TMP/bad-relation.inc"
if validate_fragment dataset "$TMP/bad-relation.inc"; then bad "negative: relation-owned src was accepted"; else ok "negative: relation-owned src refused"; fi

cp "$PR_DEFAULT" "$TMP/bad-topology.inc"
echo 'recursive = yes' >> "$TMP/bad-topology.inc"
if validate_fragment prune "$TMP/bad-topology.inc"; then bad "negative: prune topology override was accepted"; else ok "negative: prune topology override refused"; fi

cp "$PR_DEFAULT" "$TMP/bad-unknown.inc"
echo 'not_a_real_gencron_field = yes' >> "$TMP/bad-unknown.inc"
if validate_fragment prune "$TMP/bad-unknown.inc"; then bad "negative: unknown field was accepted"; else ok "negative: unknown field refused via --dump-fields"; fi

cp "$DS_DEFAULT" "$TMP/bad-section.inc"
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
if profile_validate_templates "$TPL_DEFAULT" "$DUMPFILE"; then
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
    [ "$omit" = profile.conf ] || cp "$PROFILE/profile.conf" "$d/"
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

refuses_dir "negative: a profile without profile.conf is refused" profile.conf

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

if profile_render_templates "$TPL_DEFAULT" default "$RD/t.conf"; then
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

if profile_render_fragment "$PR_DEFAULT" default "$RD/p.inc"; then
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
printf '\n[template:standard_hourly]\n\tsend_schedule = 5 * * * *\n' >> "$DUPP/profile.conf"
if profile_render_templates "$(psplit "$DUPP" | cut -d" " -f1)" default "$RD/dup.conf"; then
    bad "render: a duplicate template inside one profile is refused"
else
    case "$PROFILE_ERR" in
        *standard_hourly*default*) ok "render: a duplicate template inside one profile is refused" ;;
        *) bad "render: a duplicate template inside one profile is refused" "$PROFILE_ERR" ;;
    esac
fi
rm -rf "$DUPP"

# A profile name that could break a section header is refused, not sanitised.
if profile_render_templates "$TPL_DEFAULT" 'bad name]' "$RD/bad.conf"; then
    bad "render: a profile name unusable in a header is refused"
else
    ok "render: a profile name unusable in a header is refused"
fi

# The property the whole scheme exists for: two profiles compose without
# colliding. Same source templates, two names, one config gen-cron accepts.
profile_render_templates "$TPL_DEFAULT" flat   "$RD/flat.conf"   || bad "render: two-profile composition (flat)"   "$PROFILE_ERR"
profile_render_templates "$TPL_DEFAULT" atomic "$RD/atomic.conf" || bad "render: two-profile composition (atomic)" "$PROFILE_ERR"
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
    cat "$TPL_DEFAULT"; printf '\n'
    cat "$TPL_DEFAULT"
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
if profile_render_templates "$(psplit "$COLL1" | cut -d" " -f1)" 'a__b' "$RD/coll1.conf"; then
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
printf '\n[template:b__c]\n\tsend_schedule = 1 * * * *\n\tprefix = x_\n' >> "$COLL2/profile.conf"
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
if profile_render_templates "$(psplit "$COLL2" | cut -d" " -f1)" default "$RD/coll2.conf"; then
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
if profile_render_templates "$TPL_DEFAULT" 'site-a' "$RD/ok1.conf"; then
    ok "injectivity: single underscores and hyphens are still accepted"
else
    bad "injectivity: single underscores and hyphens are still accepted" "$PROFILE_ERR"
fi


# ===========================================================================
# CONFIG-WIDE FLOORS: identical deduplicates, DIFFERENT refuses.
#
# An [excluded:] section is not this profile's opinion -- gen-cron folds every
# one of them into a single PROTECT_FLAGS fragment pasted onto EVERY prune line
# in the file. So one config cannot fence a family two ways, and two profiles
# that disagree about `keep` are not a merge problem: they are a question only a
# human can answer.
#
# Skipping silently -- which is what the code did until now -- means the FIRST
# profile installed wins forever while the second one's declaration is quietly
# void: an operator reading profile B sees a number in force nowhere.
# ===========================================================================
FLOOR="$TMP/floors"; rm -rf "$FLOOR"; mkdir -p "$FLOOR/p/nine" "$FLOOR/bin"
printf '#!/bin/sh\ncase " $* " in *" -l "*) printf "# BEGIN zfs-backup-managed\n# END zfs-backup-managed\n";; esac\nexit 0\n' > "$FLOOR/bin/crontab"
chmod +x "$FLOOR/bin/crontab"
sed 's/^\tkeep = 2$/\tkeep = 9/' "$ROOT/profiles/default/profile.conf" > "$FLOOR/p/nine/profile.conf"

floor_run() {   # <config file> [profile] -> "rc|<phrase hits>"
    local out rc
    out=$( ( PATH="$FLOOR/bin:$PATH"; PROFILE_ROOT="$FLOOR/p"; PROFILE_ACTIVE="${2:-nine}"; PROFILE_LOADED=""
             . "$ROOT/zfs-backup.sh" >/dev/null 2>&1
             load_active_profile
             ensure_cron_config "$1" 0 1 always ) 2>&1 ); rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | grep -c 'protects it LESS')"
}

# 1. THE DANGEROUS DIRECTION. The config fences vzdump at 2, the profile
#    requires 9: the relationship being created would run behind a guard weaker
#    than its own policy declares. Refuse, and say which way round it is.
printf '[defaults]\n\thost_label = t\n\n[excluded:vzdump]\n\tkeep = 2\n' > "$FLOOR/conflict.conf"
r="$(floor_run "$FLOOR/conflict.conf")"
if [ "$r" = "1|1" ]; then
    ok "floors: a config fencing a family MORE WEAKLY than the profile is REFUSED"
else
    bad "floors: a config fencing a family more weakly than the profile is refused" "got $r"
fi

# 1b. THE SAFE DIRECTION, and the reason this rule is asymmetric at all. The
#     first cut refused on ANY difference and broke a property this tree had
#     already decided and pinned in test/zfsbackup: "only ADDS a missing floor,
#     never narrows an operator's stronger keep" (REV-20260810-092). A floor is
#     a MINIMUM: keeping the operator's LARGER number deletes nothing anyone
#     relies on, so it is not a conflict -- it is their decision, and it stands.
printf '[defaults]\n\thost_label = t\n\n[excluded:vzdump]\n\tkeep = 30\n' > "$FLOOR/stronger.conf"
r="$(floor_run "$FLOOR/stronger.conf")"
#     Read vzdump's OWN keep rather than counting "9" anywhere in the file: the
#     profile declares three families, and the two it is NOT arguing about are
#     correctly written at 9 by this very run. Counting the whole file made this
#     assertion fail for a reason that had nothing to do with what it tests.
vz_keep() { awk '/^\[excluded:vzdump\]/{f=1;next} /^\[/{f=0} f&&/keep[ \t]*=/{sub(/.*=[ \t]*/,"");print;exit}' "$1"; }
if [ "${r%%|*}" = "0" ] && [ "$(vz_keep "$FLOOR/stronger.conf")" = "30" ] \
   && [ "$(grep -c '^\[excluded:' "$FLOOR/stronger.conf")" -eq 3 ]; then
    ok "floors: an operator's STRONGER floor is kept, not refused and not narrowed"
else
    bad "floors: an operator's stronger floor is kept" "got $r, vzdump keep=$(vz_keep "$FLOOR/stronger.conf"), sekcji=$(grep -c '^\[excluded:' "$FLOOR/stronger.conf")"
fi

# 1c. `all` is a legal keep for gen-cron (build_excluded_section) and is the
#     strongest floor expressible. Compared as strings it looks merely
#     "different" from 9 and would have been refused as a conflict; ranked, it
#     outranks every count and is simply the operator protecting more.
printf '[defaults]\n\thost_label = t\n\n[excluded:vzdump]\n\tkeep = all\n' > "$FLOOR/all.conf"
r="$(floor_run "$FLOOR/all.conf")"
if [ "${r%%|*}" = "0" ] && grep -q 'keep = all' "$FLOOR/all.conf"; then
    ok "floors: keep = all outranks every count instead of reading as a conflict"
else
    bad "floors: keep = all outranks every count" "got $r"
fi

# 1d. A keep gen-cron would itself reject is neither stronger nor weaker: it is
#     unreadable, and an unreadable floor must not be ranked as zero -- that
#     would silently read "unprotected" as "protected less" and refuse for the
#     wrong reason, or worse, pass.
printf '[defaults]\n\thost_label = t\n\n[excluded:vzdump]\n\tkeep = kilka\n' > "$FLOOR/junk.conf"
out=$( ( PATH="$FLOOR/bin:$PATH"; PROFILE_ROOT="$FLOOR/p"; PROFILE_ACTIVE=nine; PROFILE_LOADED=""
         . "$ROOT/zfs-backup.sh" >/dev/null 2>&1
         load_active_profile
         ensure_cron_config "$FLOOR/junk.conf" 0 1 always ) 2>&1 ); rc=$?
case "$rc:$out" in
    1:*"neither a count nor 'all'"*) ok "floors: an unreadable keep is refused as unreadable, not ranked as zero" ;;
    *) bad "floors: an unreadable keep is refused as unreadable" "rc=$rc: $(printf '%s' "$out" | tail -1)" ;;
esac

# 2. and NOTHING was written before the refusal. A gate that mutates before it
#    refuses is not a gate -- the first cut appended the first family and then
#    refused on the second, while its own message said nothing had changed.
if [ "$(grep -c '^\[excluded:' "$FLOOR/conflict.conf")" -eq 1 ]; then
    ok "floors: the refusal writes no floor at all (checked before written)"
else
    bad "floors: the refusal writes no floor at all" "$(grep -c '^\[excluded:' "$FLOOR/conflict.conf") sekcji [excluded:] w pliku"
fi

# 3. CONTROL: the same profile against a config that AGREES installs quietly.
#    Without this, case 1 would pass against a build that refused every floor.
printf '[defaults]\n\thost_label = t\n\n[excluded:vzdump]\n\tkeep = 9\n' > "$FLOOR/agree.conf"
r="$(floor_run "$FLOOR/agree.conf")"
if [ "${r%%|*}" = "0" ]; then
    ok "floors control: a config that AGREES is not refused (identical deduplicates)"
else
    bad "floors control: a config that agrees is not refused" "got $r"
fi

# 4. CONTROL: a fresh config gets the floors written, with the PROFILE's value.
printf '[defaults]\n\thost_label = t\n' > "$FLOOR/fresh.conf"
r="$(floor_run "$FLOOR/fresh.conf")"
if [ "${r%%|*}" = "0" ] && [ "$(grep -c 'keep = 9' "$FLOOR/fresh.conf")" -ge 3 ]; then
    ok "floors control: a fresh config is given the profile's own values"
else
    bad "floors control: a fresh config is given the profile's own values" "got $r, keep9=$(grep -c 'keep = 9' "$FLOOR/fresh.conf")"
fi

# 5. A profile that contradicts ITSELF is refused earlier and more cheaply, and
#    the message names the profile file rather than a composed temporary.
mkdir -p "$FLOOR/p/selfdup"
{ cat "$ROOT/profiles/default/profile.conf"; printf '\n[excluded:vzdump]\n\tkeep = 5\n'; } > "$FLOOR/p/selfdup/profile.conf"
if profile_validate_dir "$FLOOR/p/selfdup" "$GEN"; then
    bad "floors: a profile fencing one family twice is refused"
else
    case "$PROFILE_ERR" in
        *"appears twice"*) ok "floors: a profile fencing one family twice is refused, naming the file" ;;
        *) bad "floors: a profile fencing one family twice is refused" "wrong reason: $PROFILE_ERR" ;;
    esac
fi

echo "profiles: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
