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
    # Two different reasons, and naming the wrong one sends the next person to
    # the wrong place: root bypasses directory permissions entirely, and Git
    # Bash on Windows does not enforce them at all. Both were hit while
    # building this case.
    if [ "$(id -u)" = 0 ]; then
        echo "SKIP D4 running as root, which bypasses directory permissions -- run this suite as an unprivileged user to exercise it"
    else
        echo "SKIP D4 this filesystem does not enforce directory permissions -- verify on Linux"
    fi
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

# ---- G. the installed-block control must not depend on WHO runs it ---------
#
# REV-20260807-058. On the real fleet configs are root:root 0644 in /etc, so
# only root can commit -- but the managed block lives in the DELEGATED
# ACCOUNT's crontab. Reading only the caller's crontab made the strongest
# control vanish in the one mode that can write the file.
#
# `crontab` and `getent` are stubs on PATH so the whole root/account topology
# is reproducible without root. G_HOME/<user> holds each simulated crontab;
# G_UID decides what `id -u` the script sees via a stubbed `id`.
GD="$TMPD/g"; mkdir -p "$GD/bin" "$GD/tabs"
cat > "$GD/bin/crontab" <<'EOF'
#!/bin/bash
u=""; act=""
while [ $# -gt 0 ]; do
    case "$1" in
        -u) u="$2"; shift 2 ;;
        -l) act=l; shift ;;
        *) shift ;;
    esac
done
[ -n "$u" ] || u="$(id -un)"
[ "$act" = l ] || exit 0
case "$G_UNREADABLE" in "$u") echo "crontab: cannot read from database" >&2; exit 1 ;; esac
f="$G_TABS/$u"
[ -f "$f" ] || { echo "no crontab for $u" >&2; exit 1; }
cat "$f"
EOF
cat > "$GD/bin/getent" <<'EOF'
#!/bin/bash
[ "$1" = passwd ] || exit 2
printf '%s\n' $G_USERS | sed 's/$/:x:0:0::\/:\/bin\/sh/'
EOF
cat > "$GD/bin/id" <<'EOF'
#!/bin/bash
case "$1" in
    -u) printf '%s\n' "$G_UID" ;;
    -un) printf '%s\n' "$G_ME" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$GD/bin/crontab" "$GD/bin/getent" "$GD/bin/id"
export G_TABS="$GD/tabs" G_USERS="root zfsbackup other" G_UNREADABLE="" G_UID=0 G_ME=root

# Builds a crontab file holding a managed block whose "# Source:" names $2.
mkblock() {   # <user> <config path> [extra body line]
    { echo '# BEGIN zfs-backup-managed (generated by gen-cron.sh -- do not hand-edit, re-run gen-cron.sh instead)'
      echo "# Source: $2 -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
      [ -n "${3:-}" ] && echo "$3"
      echo '# END zfs-backup-managed'
    } > "$GD/tabs/$1"
}
# The authoritative block for a config = exactly what the pre-migration config
# renders. Produced by the real generator so the control compares like for like.
real_block() {   # <config>
    "$GEN" --internal-legacy-render -c "$1" 2>/dev/null | grep -vE '^# (BEGIN|END) zfs-backup-managed|^# Source: '
}
g_run() { PATH="$GD/bin:$PATH" "$GEN" --migrate-recursion -c "$1" 2>&1; }

# G1: root runs it, root has no block, the delegated account holds the matching
# one -- the case that was silently skipped before.
c="$TMPD/G1.conf"; mkconf "$c" '-r -v 3'
rm -f "$GD/tabs"/*; { echo '# BEGIN zfs-backup-managed (generated by gen-cron.sh -- do not hand-edit, re-run gen-cron.sh instead)'
  echo "# Source: $c -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
  real_block "$c"; echo '# END zfs-backup-managed'; } > "$GD/tabs/zfsbackup"
out="$(g_run "$c")"; rc=$?
check "G1 root finds the delegated account's block" "0" "$rc"
case "$out" in *"found in zfsbackup's crontab"*) ok "G1 names whose crontab it used" ;;
  *) bad "G1 names whose crontab it used" "$out" ;; esac
case "$out" in *"matches (control passed)"*) ok "G1 the control actually ran" ;;
  *) bad "G1 the control actually ran" "$out" ;; esac

# G2: same topology, but the installed block DIFFERS from the legacy render --
# pre-existing drift. Must refuse before writing.
c="$TMPD/G2.conf"; mkconf "$c" '-r -v 3'; before="$(sum "$c")"
rm -f "$GD/tabs"/*; mkblock zfsbackup "$c" "0 5 * * * /something/else"
out="$(g_run "$c")"; rc=$?
check "G2 drift in the delegated block refuses" "1" "$rc"
check "G2 file untouched" "$before" "$(sum "$c")"

# G3: two crontabs both claim this config. Which is authoritative is a guess.
c="$TMPD/G3.conf"; mkconf "$c" '-r -v 3'; before="$(sum "$c")"
rm -f "$GD/tabs"/*; mkblock zfsbackup "$c"; mkblock other "$c"
out="$(g_run "$c")"; rc=$?
check "G3 two matching blocks refuse as ambiguous" "1" "$rc"
check "G3 file untouched" "$before" "$(sum "$c")"
case "$out" in *"both hold a managed block"*) ok "G3 names the ambiguity" ;;
  *) bad "G3 names the ambiguity" "$out" ;; esac

# G4: a block for ANOTHER config must be ignored, not used as proof.
c="$TMPD/G4.conf"; mkconf "$c" '-r -v 3'
rm -f "$GD/tabs"/*; mkblock zfsbackup "$TMPD/some-other.conf" "0 5 * * * /something/else"
out="$(g_run "$c")"; rc=$?
check "G4 another config's block is ignored" "0" "$rc"
case "$out" in *"none -- searched every user"*) ok "G4 says it searched and found none" ;;
  *) bad "G4 says it searched and found none" "$out" ;; esac

# G5: a crontab that cannot be READ is not an empty one. Uncertainty refuses.
c="$TMPD/G5.conf"; mkconf "$c" '-r -v 3'; before="$(sum "$c")"
rm -f "$GD/tabs"/*; mkblock zfsbackup "$c"
G_UNREADABLE=other out="$(g_run "$c")"; rc=$?
check "G5 an unreadable crontab refuses" "1" "$rc"
check "G5 file untouched" "$before" "$(sum "$c")"
case "$out" in *"could not read other's crontab"*) ok "G5 names the crontab it could not read" ;;
  *) bad "G5 names the crontab it could not read" "$out" ;; esac

# G6: root, and the user list itself cannot be read -- a narrowed search that
# finds nothing looks exactly like a config that is not installed.
c="$TMPD/G6.conf"; mkconf "$c" '-r -v 3'; before="$(sum "$c")"
rm -f "$GD/tabs"/*; mkblock zfsbackup "$c"
G_USERS="" out="$(g_run "$c")"; rc=$?
check "G6 an unreadable user list refuses" "1" "$rc"
check "G6 file untouched" "$before" "$(sum "$c")"

# G7: ordinary NON-root run with its own matching block still works, and only
# its own crontab is consulted.
c="$TMPD/G7.conf"; mkconf "$c" '-r -v 3'
rm -f "$GD/tabs"/*; { echo '# BEGIN zfs-backup-managed (generated by gen-cron.sh -- do not hand-edit, re-run gen-cron.sh instead)'
  echo "# Source: $c -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
  real_block "$c"; echo '# END zfs-backup-managed'; } > "$GD/tabs/zfsbackup"
G_UID=1000 G_ME=zfsbackup out="$(g_run "$c")"; rc=$?
check "G7 non-root run uses its own block" "0" "$rc"
case "$out" in *"found in zfsbackup's crontab"*) ok "G7 the control ran" ;;
  *) bad "G7 the control ran" "$out" ;; esac

# G8: "no cron on this system" is a DECIDED state and must read differently
# from "a crontab exists and could not be read" (G5). Absence of the binary is
# proof that nothing can be installed; absence of permission is not.
#
# PATH is built from symlinks to the commands the generator actually needs, so
# `crontab` is genuinely absent whether or not this machine has one. Shadowing
# does not work here -- a real /usr/bin/crontab would still be found -- and a
# test that passes only on a machine without cron proves nothing on the hosts
# that matter.
# G8 is a STATIC check, and says so rather than pretending otherwise.
#
# The behaviour it would like to exercise -- a host with no crontab(1) at all --
# cannot be produced portably: PATH cannot un-find /usr/bin/crontab, and a
# stripped PATH built from symlinks breaks the generator's own directory
# resolution before it reaches the branch. A test that only runs on a machine
# without cron proves nothing about the hosts that matter.
#
# What the review actually requires is that "not installed" is explicit and
# distinguishable rather than inferred from absence. G4 proves the searched-and-
# found-none path behaviourally, and G5/G6 prove that uncertainty refuses. This
# pins the remaining half: the two reasons are DIFFERENT sentences, so an
# operator can tell which one they are looking at.
if grep -q 'no crontab(1), so no config can be installed anywhere' "$GEN" \
   && grep -q "searched every user's crontab" "$GEN"; then
    ok "G8 the two 'not installed' reasons are distinct, stated sentences (static)"
else
    bad "G8 the two 'not installed' reasons are distinct, stated sentences (static)" \
        "one or both reason strings are missing from $GEN"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
