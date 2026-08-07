#!/bin/bash
# Regression tests for `gen-cron.sh --migrate-recursion` (REV-20260807-057).
#
# No ZFS, no root, no network: the migration reads and rewrites a config file
# and shells out to this same generator to render. Everything below is
# deterministic.
#
# What these pin is not "the rewriter produces nice text" but the two
# properties the review actually asked for:
#   - it never changes what runs (the render before and after must match), and
#   - every refusal leaves the source config byte-identical.
# Each failure case therefore checks the file's checksum, not just the message.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="${GEN:-$DIR/../../gen-cron.sh}"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; FAIL=$((FAIL+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want='$2' got='$3'"; fi; }

TMPD="$(mktemp -d)"
trap 'chmod -R u+w "$TMPD" 2>/dev/null; rm -rf "$TMPD"' EXIT

# A config that renders cleanly, parameterised only by its flags line.
mkconf() {   # <file> <flags line content, or empty to omit>
    { echo '[defaults]'
      printf '\thost_label = t\n\n'
      echo '[template:hourly]'
      printf '\tsend_schedule  = 7 * * * *\n'
      printf '\tprefix         = automated_\n'
      printf '\tpattern        = automated_\n'
      printf '\tprune_schedule = 30 2 * * *\n'
      printf '\tkeep           = 24\n\n'
      echo '[dataset:tank/data]'
      printf '\tuse_template = hourly\n'
      [ -n "${2:-}" ] && printf '\tflags        = %s\n' "$2"
      printf '\tnotify       = d\n'
    } > "$1"
}

sum() { md5sum "$1" | cut -d' ' -f1; }
field() { grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" | sed -E 's/^[[:space:]]*[a-z_]+[[:space:]]*=[[:space:]]*//'; }

# ---- A. the mapping ---------------------------------------------------------
run_case() {   # <name> <input flags> <want recursive> <want flags, "" = line gone>
    local name="$1" c="$TMPD/$1.conf"
    mkconf "$c" "$2"
    local out rc
    out="$("$GEN" --migrate-recursion -c "$c" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then bad "$name migrates" "rc=$rc: $out"; return; fi
    check "$name -> recursive = $3" "$3" "$(field "$c" recursive)"
    check "$name -> flags = ${4:-<gone>}" "$4" "$(field "$c" flags)"
}

run_case A1-plain-r      '-r -v 3'   atomic '-v 3'
run_case A2-plain-R      '-R -v 3'   flat   '-v 3'
run_case A3-bundled-Rv   '-Rv 3'     flat   '-v 3'
run_case A4-bundled-rZ   '-rZ'       atomic '-Z'
run_case A5-only-r       '-r'        atomic ''
run_case A6-r-among-many '-e -u -r -v 3' atomic '-e -u -v 3'

# ---- B. what must NOT be migrated ------------------------------------------
# An option ARGUMENT containing r/R is not recursion. A substring rule would
# migrate both of these and corrupt a working config.
for t in "B1-arg-with-R:-m R-daily_" "B2-arg-is-R:-v R"; do
    name="${t%%:*}"; flags="${t#*:}"
    c="$TMPD/$name.conf"; mkconf "$c" "$flags"
    before="$(sum "$c")"
    out="$("$GEN" --migrate-recursion -c "$c" 2>&1)"; rc=$?
    check "$name rc=0" "0" "$rc"
    check "$name file untouched" "$before" "$(sum "$c")"
    case "$out" in *"nothing to migrate"*) ok "$name says nothing to migrate" ;;
      *) bad "$name says nothing to migrate" "$out" ;; esac
done

# ---- C. idempotence ---------------------------------------------------------
c="$TMPD/C.conf"; mkconf "$c" '-r -v 3'
"$GEN" --migrate-recursion -c "$c" >/dev/null 2>&1
after_first="$(sum "$c")"
out="$("$GEN" --migrate-recursion -c "$c" 2>&1)"; rc=$?
check "C1 second run rc=0" "0" "$rc"
check "C2 second run changes nothing" "$after_first" "$(sum "$c")"

# ---- D. refusals leave the source byte-identical ---------------------------
# D1: both modes in one flags string. Guessing which was meant is not migration.
c="$TMPD/D1.conf"; mkconf "$c" '-r -R -v 3'; before="$(sum "$c")"
out="$("$GEN" --migrate-recursion -c "$c" 2>&1)"; rc=$?
check "D1 both -r and -R refused" "1" "$rc"
check "D1 file untouched" "$before" "$(sum "$c")"
case "$out" in *"both -r and -R"*) ok "D1 names the reason" ;; *) bad "D1 names the reason" "$out" ;; esac

# D2: legacy flags AND the typed field together -- ambiguous by construction.
c="$TMPD/D2.conf"; mkconf "$c" '-r -v 3'
sed -i 's|^\tuse_template = hourly|\tuse_template = hourly\n\trecursive    = flat|' "$c"
before="$(sum "$c")"
out="$("$GEN" --migrate-recursion -c "$c" 2>&1)"; rc=$?
check "D2 typed field + legacy flags refused" "1" "$rc"
check "D2 file untouched" "$before" "$(sum "$c")"

# D3: a config that cannot render at all. The baseline render runs FIRST and
# fails, so nothing is written -- this is the "abort before touching anything"
# guarantee, exercised through a reachable input rather than a stub.
c="$TMPD/D3.conf"; mkconf "$c" '-r -v 3'
sed -i 's|^\tuse_template = hourly|\tuse_template = nosuchtier|' "$c"
before="$(sum "$c")"
out="$("$GEN" --migrate-recursion -c "$c" 2>&1)"; rc=$?
check "D3 unrenderable config refused" "1" "$rc"
check "D3 file untouched" "$before" "$(sum "$c")"
case "$out" in *"aborting before touching anything"*) ok "D3 says it aborted early" ;;
  *) bad "D3 says it aborted early" "$out" ;; esac

# D4: commit cannot publish (directory not writable). The rollback copy and the
# staged file both live beside the config, so this is the realistic failure --
# a full filesystem or a read-only /etc looks exactly like this.
mkdir -p "$TMPD/ro"; c="$TMPD/ro/D4.conf"; mkconf "$c" '-r -v 3'
before="$(sum "$c")"
chmod 0555 "$TMPD/ro"
# Probe first. On a filesystem that cannot enforce directory permissions (this
# suite also runs from Git Bash on Windows, and test/cron already SKIPs on the
# same class of limitation) the write below would succeed and the case would
# assert nothing -- reporting a pass there would be worse than skipping.
if (: > "$TMPD/ro/.probe") 2>/dev/null; then
    rm -f "$TMPD/ro/.probe"; chmod 0755 "$TMPD/ro"
    echo "SKIP D4 this filesystem does not enforce directory permissions -- verify on Linux"
else
    out="$("$GEN" --migrate-recursion -c "$c" 2>&1)"; rc=$?
    chmod 0755 "$TMPD/ro"
    check "D4 unpublishable commit refused" "1" "$rc"
    check "D4 file untouched" "$before" "$(sum "$c")"
fi

# ---- E. the point of the whole exercise ------------------------------------
# Before: the current generator refuses the config. After: it accepts it, and
# the rendered block is identical. Without the second half, a migration that
# quietly changed the schedule would still "pass".
c="$TMPD/E.conf"; mkconf "$c" '-r -v 3'
"$GEN" -c "$c" >/dev/null 2>&1
check "E1 pre-migration config is REFUSED by this generator" "1" "$?"
base="$("$GEN" --internal-legacy-render -c "$c" 2>/dev/null | grep -v '^# Source: ')"
"$GEN" --migrate-recursion -c "$c" >/dev/null 2>&1
"$GEN" -c "$c" >/dev/null 2>&1
check "E2 migrated config is ACCEPTED" "0" "$?"
mig="$("$GEN" -c "$c" 2>/dev/null | grep -v '^# Source: ')"
if [ "$base" = "$mig" ]; then ok "E3 rendered block is byte-identical across the migration"
else bad "E3 rendered block is byte-identical across the migration" "$(diff <(printf '%s\n' "$base") <(printf '%s\n' "$mig") | head -6)"; fi

# E4: the legacy render is a comparison tool, not a back door -- it must never
# be able to write a crontab.
out="$("$GEN" --internal-legacy-render --install -c "$c" 2>&1)"; rc=$?
check "E4 legacy render refuses --install" "1" "$rc"
case "$out" in *"never reach a crontab"*) ok "E4 says why" ;; *) bad "E4 says why" "$out" ;; esac

# ---- F. the file a human has to keep reading -------------------------------
c="$TMPD/F.conf"; mkconf "$c" '-r -v 3'
"$GEN" --migrate-recursion -c "$c" >/dev/null 2>&1
# A literal tab, not "\t": grep -E does not read that as one, and a check that
# silently matches nothing is a check that passes for the wrong reason.
if grep -qE "^$(printf '\t')recursive    = atomic$" "$c" \
   && grep -qE "^$(printf '\t')flags        = -v 3$" "$c"; then
    ok "F1 inserted fields keep the file's indentation and '=' column"
else
    bad "F1 inserted fields keep the file's indentation and '=' column" "$(grep -nE 'recursive|flags' "$c")"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
