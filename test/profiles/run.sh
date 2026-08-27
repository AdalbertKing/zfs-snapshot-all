#!/bin/bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GEN="$ROOT/gen-cron.sh"
PROFILE="$ROOT/profiles/default.conf"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail+1)); }

# A profile is ONE file since 2026-08-25. This used to check three.
if [ -r "$PROFILE" ]; then ok "default.conf exists"; else bad "default.conf missing"; fi
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
# ONE FILE, and since 2026-08-26 that is literally all it is: profiles/<name>.conf.
# The directory that used to hold it was left over from when a profile really
# was three files, and a wrapper around nothing is worse than no wrapper. The
# three artifacts the runtime consumes are still produced from it, and the suite
# splits the same way the runtime does -- so the assertions below keep testing
# the CONTENT rather than the layout it happens to be stored in.
# ---------------------------------------------------------------------------
psplit() {   # <profile file> -> echoes "<tpl> <ds> <prune> <excl>" of temp files
    local d="$1" t x p2 e
    t="$(mktemp)"; x="$(mktemp)"; p2="$(mktemp)"; e="$(mktemp)"
    profile_split_one_file "$d" "$t" "$x" "$p2" "$e" || return 1
    cat "$e" >> "$t"
    printf '%s %s %s %s' "$t" "$x" "$p2" "$e"
}
LETTERS="$(mktemp)"; bash "$GEN" --dump-tier-letters > "$LETTERS"
PSPLIT_DEFAULT=($(psplit "$ROOT/profiles/default.conf"))
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
if profile_validate_file "$PROFILE" "$GEN"; then
    ok "profile_validate_file accepts the built-in profile"
else
    bad "profile_validate_file accepts the built-in profile" "$PROFILE_ERR"
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
# profile_validate_file used to write `[ -f "$dir/x" ] && ! validate`, which
# reads as "if it exists and fails, complain" -- so a MISSING artifact returned
# SUCCESS from the production boundary and an empty directory validated clean.
# The suite could not see it, because it checked the shipped fixture's files
# exist separately -- a different property, and one B1 would not inherit.
mkprofile() {   # -> a throwaway COPY of the shipped profile, as a file, in $TMP
    local d="$TMP/prof.$$.$RANDOM.conf"
    cp "$PROFILE" "$d"
    printf '%s' "$d"
}

# REWRITTEN, not deleted, when a profile stopped being a directory (2026-08-26).
# The property these assertions were built for -- the production boundary must
# REFUSE something that is not a usable profile, rather than sail past it -- is
# exactly the property that has to survive the layout change. Only the shapes
# that can go wrong changed.
if profile_validate_file "$TMP/no-such-profile.conf" "$GEN"; then
    bad "negative: a missing profile file is refused"
else
    case "$PROFILE_ERR" in
        *"missing or unreadable"*) ok "negative: a missing profile file is refused" ;;
        *) bad "negative: a missing profile file is refused" "wrong reason: $PROFILE_ERR" ;;
    esac
fi

# A DIRECTORY is readable, so an -r test waved one through and the failure
# surfaced further in as `read: Is a directory` from the splitter -- a crash
# where a sentence belonged. Not a hypothetical input: it is precisely what the
# PREVIOUS layout left on disk, so anyone with an older host will type it.
DIRP="$TMP/olddirshape"; rm -rf "$DIRP"; mkdir -p "$DIRP"
cp "$PROFILE" "$DIRP/profile.conf"
if profile_validate_file "$DIRP" "$GEN"; then
    bad "negative: a DIRECTORY is refused with a sentence, not a read error"
else
    case "$PROFILE_ERR" in
        *"is a directory"*) ok "negative: a DIRECTORY is refused with a sentence, not a read error" ;;
        *) bad "negative: a DIRECTORY is refused with a sentence" "wrong reason: $PROFILE_ERR" ;;
    esac
fi
rm -rf "$DIRP"

# CONTROL: the real file still validates, so the two refusals above are not a
# boundary that rejects everything.
if profile_validate_file "$PROFILE" "$GEN"; then
    ok "negative control: the shipped profile file still validates"
else
    bad "negative control: the shipped profile file still validates" "$PROFILE_ERR"
fi


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
DUPP="$(mkprofile)"
printf '\n[template:standard_hourly]\n\tsend_schedule = 5 * * * *\n' >> "$DUPP"
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

# THE NAME IS THE RETENTION, and this asserts it rather than trusting the
# header comment that says so.
#
# A profile called d7h24 promises seven daily counters and twenty-four hourly
# ones. That promise is only worth something if the delsnaps line the REAL
# gen-cron renders carries exactly -D7 and -H24 and nothing else -- otherwise
# the name is decoration and an administrator picking from `ls` is being misled
# by a filename.
#
# Only profiles named in that scheme are checked; default, passive and prod
# describe themselves in prose and are covered by their own assertions.
# render_profile <profile file> <name> -> prints the cron block gen-cron makes
#
# Factored out on 2026-08-27, when profiles stopped having one shape. A ladder
# profile carries a [prune] fragment and a per-tier profile does not, and the
# caller must not have to know which: an EMPTY [prune:] section is not a
# harmless no-op -- gen-cron refuses the file, and the refusal reaches the
# assertion as "no delsnaps line", which reads like a retention bug.
render_profile() {   # <file> <name>   -> 0 and the cron block, or 1 and PROFILE_ERR
    local f="$1" n="$2" st sd sp se rt rd rp cfg
    st="$(mktemp)"; sd="$(mktemp)"; sp="$(mktemp)"; se="$(mktemp)"
    profile_split_one_file "$f" "$st" "$sd" "$sp" "$se" || { PROFILE_ERR="split"; return 1; }
    cat "$se" >> "$st"
    rt="$TMP/nm.$n.tpl"; rd="$TMP/nm.$n.ds"; rp="$TMP/nm.$n.pr"
    # $LETTERS is not optional: without it `keep = 24` never becomes -H24 and
    # gen-cron refuses every tier. Learned by leaving it out.
    profile_render_templates "$st" "$n" "$rt" "" "$LETTERS" || return 1
    profile_render_fragment  "$sd" "$n" "$rd" || return 1
    : > "$rp"
    [ -s "$sp" ] && { profile_render_fragment "$sp" "$n" "$rp" || return 1; }
    rm -f "$st" "$sd" "$sp" "$se"

    cfg="$TMP/nm.$n.conf"
    { printf '[defaults]\n\thost_label = nm\n\n'
      cat "$rt"
      printf '\n[dataset:tank/x]\n'
      sed 's/^[[:space:]]*/\t/' "$rd"
      printf '\trecursive    = no\n\tnotify       = nm\n'
      # ONLY when the profile actually has one. See the note above.
      if [ -s "$rp" ]; then
          printf '\n[prune:tank/x]\n'
          sed 's/^[[:space:]]*/\t/' "$rp"
          printf '\trecursive    = no\n\tnotify       = nm\n'
      fi
    } > "$cfg"
    bash "$GEN" -c "$cfg" 2>/dev/null
}

# THE CASE OF THE NAME IS THE SHAPE (owner rule, 2026-08-27). Lowercase means
# one family per tier, each pruned by its own counter; uppercase means the GFS
# ladder, one family under several counters. Asserted rather than left to the
# header comment, because a convention nothing checks is decoration -- and this
# one decides whether the daily tier can be frozen on its own.
#
# A FUNCTION rather than eight lines inside the loop, because the loop can only
# ever reach the LOWERCASE half: no uppercase profile is shipped, and on a
# case-insensitive filesystem (this workstation, and any macOS checkout) one
# cannot even be added next to its lowercase twin -- `D30H24.conf` and
# `d30h24.conf` are the same file, and writing one DELETES the other. Measured
# here on 2026-08-27, by deleting d30h24.conf exactly that way. So the uppercase
# half is exercised below against fixtures that never touch profiles/.
shape_verdict() {   # <name> <promised flags> <delsnaps lines> -> sets SHAPE_ERR
    local n="$1" want="$2" lines="$3" n_del n_want
    SHAPE_ERR=""
    n_del="$(printf '%s\n' "$lines" | grep -c .)"
    if printf '%s' "$n" | grep -q '[A-Z]'; then
        printf '%s' "$lines" | grep -q -- ' -G ' || SHAPE_ERR="$SHAPE_ERR $n(UPPERCASE but not a -G ladder);"
        [ "$n_del" = 1 ] || SHAPE_ERR="$SHAPE_ERR $n(UPPERCASE but $n_del prune lines);"
    else
        printf '%s' "$lines" | grep -q -- ' -G ' && SHAPE_ERR="$SHAPE_ERR $n(lowercase but rendered a -G ladder);"
        n_want="$(printf '%s' "$want" | wc -w)"
        [ "$n_del" = "$n_want" ] || SHAPE_ERR="$SHAPE_ERR $n(lowercase: $n_want counters but $n_del prune lines);"
    fi
}

name_bad=""
for f in "$ROOT"/profiles/*.conf; do
    n="$(basename "$f" .conf)"
    # the retention-named ones: letter+digits pairs, nothing else
    printf '%s' "$n" | grep -qE '^([dhwmDHWM][0-9]+)+$' || continue

    block="$(render_profile "$f" "$n")" || { name_bad="$name_bad $n(render:$PROFILE_ERR);"; continue; }
    lines="$(printf '%s\n' "$block" | grep -F 'delsnaps.sh')"
    [ -n "$lines" ] || { name_bad="$name_bad $n(no delsnaps line);"; continue; }

    # EVERY delsnaps line, not the first. A ladder puts all its counters on one
    # line; a per-tier profile puts one counter on each. Reading only the first
    # would pass a two-family profile on the strength of half its retention --
    # which is exactly what this assertion started doing on 2026-08-27, and it
    # reported the failure as "missing -D30" rather than as its own blind spot.
    want="$(printf '%s' "$n" | sed -E 's/([dhwmDHWM])([0-9]+)/ -\U\1\E\2/g')"
    for flag in $want; do
        case " $(printf '%s' "$lines" | tr '\n' ' ') " in
            *" $flag "*) : ;;
            *) name_bad="$name_bad $n(missing $flag);" ;;
        esac
    done
    # ...and NOTHING it does not promise, across all of them.
    for got in $(printf '%s' "$lines" | grep -oE ' -[HDWM][0-9]+' | sort -u); do
        case " $want " in *" $got "*) : ;; *) name_bad="$name_bad $n(unpromised$got);" ;; esac
    done

    shape_verdict "$n" "$want" "$lines"
    name_bad="$name_bad$SHAPE_ERR"
done
if [ -z "$name_bad" ]; then
    ok "naming: every retention-named profile renders exactly the counters its name promises, in the shape its case declares"
else
    bad "naming: every retention-named profile renders exactly the counters its name promises, in the shape its case declares" "$name_bad"
fi

# ---------------------------------------------------------------------------
# WHICH TIER IS FROZEN, across the whole shipped catalogue.
#
# Owner rule, 2026-08-27: the coarse tiers are coherent and the hourly one is
# not. The reason is not taste -- an hourly freeze stalls every guest on the
# host 24 times a day to buy consistency the daily tier already provides once.
#
# Checked against the CRON LINE gen-cron actually renders, not against the
# `quiesce` field in the profile: the field has to survive namespacing, template
# merging and the flags assembler before it becomes `-q`, and it is the `-q`
# that the host runs.
# ---------------------------------------------------------------------------
q_bad=""
for f in "$ROOT"/profiles/*.conf; do
    n="$(basename "$f" .conf)"
    block="$(render_profile "$f" "$n")" || { q_bad="$q_bad $n(render);"; continue; }
    while IFS= read -r sl; do
        [ -n "$sl" ] || continue
        fam="$(printf '%s' "$sl" | sed -n -E 's/.*-m "([^"]*)".*/\1/p')"
        has_q=no
        case "$sl" in *' -q '*) has_q=yes ;; esac
        case "$fam" in
            automated_hourly_)
                [ "$has_q" = no ] || q_bad="$q_bad $n(hourly is quiesced);" ;;
            automated_daily_|automated_weekly_|automated_monthly_|automated_annual_)
                [ "$has_q" = yes ] || q_bad="$q_bad $n($fam is not quiesced);" ;;
        esac
    done <<EOFQ
$(printf '%s\n' "$block" | grep -F 'snapsend.sh')
EOFQ
done
if [ -z "$q_bad" ]; then
    ok "quiesce: every shipped profile freezes its coarse tiers and never its hourly one"
else
    bad "quiesce: every shipped profile freezes its coarse tiers and never its hourly one" "$q_bad"
fi

# NEGATIVE CONTROL for the pair above, and it is not optional: both loops report
# by accumulating into a string, so a bug that rendered NOTHING -- or matched no
# line -- would leave that string empty and print PASS. These assert that the
# renderer this block depends on produced the lines it was reading.
ctrl="$(render_profile "$ROOT/profiles/prod.conf" prod)"
ctrl_snap="$(printf '%s\n' "$ctrl" | grep -cF 'snapsend.sh')"
ctrl_q="$(printf '%s\n' "$ctrl" | grep -F 'snapsend.sh' | grep -c -- ' -q ')"
check_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want $3, got $2"; fi; }
check_eq "control: prod renders four create lines for the loop to read" "$ctrl_snap" "4"
check_eq "control: ...three of which carry -q, so the loop had both cases" "$ctrl_q" "3"

# ---------------------------------------------------------------------------
# THE UPPERCASE HALF OF THE RULE, which no shipped profile can reach.
#
# Fed the delsnaps lines a ladder and a per-tier profile actually render (copied
# from the two shapes above, not invented), so the verdict is checked against
# real output shapes rather than against a string this test made up.
# ---------------------------------------------------------------------------
lad_line='21 * * * * ... /REPO/delsnaps.sh -G "tank/x" "automated_" -H24 -D30 2>"$e"; rc=$?'
per_lines='21 * * * * ... /REPO/delsnaps.sh "tank/x" "automated_hourly" -H24 2>"$e"; rc=$?
31 1 * * * ... /REPO/delsnaps.sh "tank/x" "automated_daily" -D30 2>"$e"; rc=$?'

shape_verdict D30H24 ' -D30 -H24' "$lad_line"
if [ -z "$SHAPE_ERR" ]; then ok "shape: an UPPERCASE name rendering a -G ladder is accepted"
else bad "shape: an UPPERCASE name rendering a -G ladder is accepted" "$SHAPE_ERR"; fi

shape_verdict D30H24 ' -D30 -H24' "$per_lines"
if [ -n "$SHAPE_ERR" ]; then ok "shape: an UPPERCASE name rendering per-tier prunes is refused"
else bad "shape: an UPPERCASE name rendering per-tier prunes is refused" "accepted it"; fi

shape_verdict d30h24 ' -D30 -H24' "$per_lines"
if [ -z "$SHAPE_ERR" ]; then ok "shape: a lowercase name rendering per-tier prunes is accepted"
else bad "shape: a lowercase name rendering per-tier prunes is accepted" "$SHAPE_ERR"; fi

shape_verdict d30h24 ' -D30 -H24' "$lad_line"
if [ -n "$SHAPE_ERR" ]; then ok "shape: a lowercase name rendering a -G ladder is refused"
else bad "shape: a lowercase name rendering a -G ladder is refused" "accepted it"; fi

# ---------------------------------------------------------------------------
# ...AND THE TWO CASES MAY NEVER BOTH BE SHIPPED.
#
# Not a style rule. On a case-insensitive filesystem `D30H24.conf` and
# `d30h24.conf` are ONE file: adding the second silently overwrites the first,
# and deleting it deletes both. The Linux hosts would keep them apart, so the
# breakage would appear only on a workstation checkout -- as a profile that
# quietly changed shape, which is the worst way to find out.
# ---------------------------------------------------------------------------
dup_case="$(for f in "$ROOT"/profiles/*.conf; do
                basename "$f" .conf | tr 'A-Z' 'a-z'
            done | sort | uniq -d)"
if [ -z "$dup_case" ]; then
    ok "naming: no two shipped profiles differ only in case"
else
    bad "naming: no two shipped profiles differ only in case" "$dup_case"
fi
# NEGATIVE CONTROL: the detector must actually detect. Same pipeline, a list
# that does collide.
dup_ctrl="$(printf 'd30h24\nD30H24\nprod\n' | tr 'A-Z' 'a-z' | sort | uniq -d)"
if [ -n "$dup_ctrl" ]; then ok "naming: ...and the case-collision detector detects one"
else bad "naming: ...and the case-collision detector detects one" "missed d30h24/D30H24"; fi

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
COLL1="$(mkprofile)"
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
COLL2="$(mkprofile)"
printf '\n[template:b__c]\n\tsend_schedule = 1 * * * *\n\tprefix = x_\n' >> "$COLL2"
if profile_validate_file "$COLL2" "$GEN"; then
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
FLOOR="$TMP/floors"; rm -rf "$FLOOR"; mkdir -p "$FLOOR/p" "$FLOOR/bin"
printf '#!/bin/sh\ncase " $* " in *" -l "*) printf "# BEGIN zfs-backup-managed\n# END zfs-backup-managed\n";; esac\nexit 0\n' > "$FLOOR/bin/crontab"
chmod +x "$FLOOR/bin/crontab"
sed 's/^\tkeep = 2$/\tkeep = 9/' "$ROOT/profiles/default.conf" > "$FLOOR/p/nine.conf"

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

# 6. PROVENANCE: "the operator hardened this" and "another profile says
#    otherwise" are two different facts, and the asymmetric rule only belongs to
#    the first (REV F5).
#
#    Profile A declares keep=10 and installs the floor. Profile B declares
#    keep=2. Under the direction rule alone, B's weaker number is simply kept
#    quietly -- which reproduces the very defect this whole section exists to
#    end: an operator reading profile B sees a policy in force nowhere. The code
#    could not tell A's floor from a hand-made one because the section carried
#    no signature. Now it does.
sed 's/^\tkeep = 2$/\tkeep = 2/' "$ROOT/profiles/default.conf" > "$FLOOR/p/two.conf"

# The config as profile 'nine' (keep = 9) would have left it: signed.
printf '[defaults]\n\thost_label = t\n\n[excluded:vzdump]\n\t# managed-by: zfs-backup.sh profile=nine\n\tkeep = 9\n' > "$FLOOR/owned.conf"
r="$(floor_run "$FLOOR/owned.conf" two)"
if [ "${r%%|*}" = "1" ]; then
    ok "floors: a floor SIGNED by another profile is refused on any difference, not just a weaker one"
else
    bad "floors: a floor signed by another profile is refused on any difference" "got $r"
fi

# CONTROL, and it is the whole point of the split: the SAME numbers, unsigned,
# are an operator's hardening and still stand. Without this the assertion above
# would pass against a build that refused every difference again -- which is the
# rule this tree already measured as too wide.
printf '[defaults]\n\thost_label = t\n\n[excluded:vzdump]\n\tkeep = 9\n' > "$FLOOR/unowned.conf"
r="$(floor_run "$FLOOR/unowned.conf" two)"
if [ "${r%%|*}" = "0" ] && [ "$(vz_keep "$FLOOR/unowned.conf")" = "9" ]; then
    ok "floors control: the same stronger value UNSIGNED is the operator's and is kept"
else
    bad "floors control: the same stronger value unsigned is kept" \
        "got $r, vzdump keep=$(vz_keep "$FLOOR/unowned.conf")"
fi

# ...and a floor this tool writes carries its signature, or none of the above
# can ever be true on a real host.
if grep -A2 '^\[excluded:vzdump\]' "$FLOOR/fresh.conf" | grep -q 'managed-by: zfs-backup.sh profile=nine'; then
    ok "floors: a floor this tool installs records which profile declared it"
else
    bad "floors: a floor this tool installs records which profile declared it" \
        "$(grep -A2 '^\[excluded:vzdump\]' "$FLOOR/fresh.conf")"
fi

# 5. A profile that contradicts ITSELF is refused earlier and more cheaply, and
#    the message names the profile file rather than a composed temporary.
{ cat "$ROOT/profiles/default.conf"; printf '\n[excluded:vzdump]\n\tkeep = 5\n'; } > "$FLOOR/p/selfdup.conf"
if profile_validate_file "$FLOOR/p/selfdup.conf" "$GEN"; then
    bad "floors: a profile fencing one family twice is refused"
else
    case "$PROFILE_ERR" in
        *"appears twice"*) ok "floors: a profile fencing one family twice is refused, naming the file" ;;
        *) bad "floors: a profile fencing one family twice is refused" "wrong reason: $PROFILE_ERR" ;;
    esac
fi


echo "profiles: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
