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
validate_fragment() { # <dataset|prune> <file>
    local kind="$1" file="$2" raw field
    while IFS= read -r raw || [ -n "$raw" ]; do
        case "$raw" in
            ''|'#'*) continue ;;
            *'['*|*']'*) return 1 ;;
        esac
        field=$(printf '%s\n' "$raw" | sed -n -E 's/^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=.*$/\1/p')
        [ -n "$field" ] || return 1
        grep -qxF "$kind $field" "$DUMP" || return 1
        case "$field" in
            src|dst|flags|pair_label|notify) return 1 ;;
        esac
        if [ "$kind" = prune ] && [ "$field" = recursive ]; then return 1; fi
    done < "$file"
}

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

echo
echo "profiles: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
