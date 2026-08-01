#!/bin/bash
# test/quiescehelper/run.sh -- zfs-quiesce-helper.sh
#
# The helper is a PRIVILEGE BOUNDARY: it is the one thing a delegated backup
# account is allowed to run as root on a source host, and the whole point of it
# existing is that `sudo qm` would hand over `qm guest exec` (arbitrary code in
# any guest) and `qm destroy`. So most of what is worth testing here is REFUSAL,
# not the happy path.
#
# Runs without root and without PVE: qm/pct/zfs are stubs on PATH, and the two
# filesystem roots come from $ZFS_QUIESCE_ALLOW_DIR / $ZFS_QUIESCE_PVE_DIR. In
# production sudo's env_reset strips those, and the sudoers rule deploy.sh
# writes carries no SETENV -- if that ever changes, this suite's own mechanism
# becomes the attack, so the rule is asserted below.

set -u
cd "$(dirname "$0")/../.." || exit 1
REPO="$PWD"
HELPER="$REPO/zfs-quiesce-helper.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; echo "     $2"; }

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/allow" "$WORK/pve/qemu-server" "$WORK/pve/lxc"

# vm-100 and subvol-200 live under a delegated dataset; vm-999 exists on the
# host but NOT under one -- that is the case that separates "this account may
# replicate it" from "this account may freeze it".
cat > "$WORK/bin/zfs" <<'EOF'
#!/bin/bash
root="${!#}"
case "$root" in
  rpool/data) printf 'rpool/data\nrpool/data/vm-100-disk-0\nrpool/data/subvol-200-disk-0\n' ;;
  *) exit 1 ;;
esac
EOF
cat > "$WORK/bin/qm" <<'EOF'
#!/bin/bash
echo "qm $*" >> "$TRACE"
[ "$1" = status ] && { echo "status: running"; exit 0; }
if [ "$1 $2" = "guest exec" ]; then cat "$VSSOUT"; exit 0; fi
if [ "$4" = fsfreeze-status ]; then echo '{"return":{"status":"thawed"}}'; exit 0; fi
[ -n "${QM_FAIL:-}" ] && exit 1
exit 0
EOF
cat > "$WORK/bin/pct" <<'EOF'
#!/bin/bash
echo "pct $*" >> "$TRACE"
[ "$1" = status ] && { echo "status: running"; exit 0; }
exit 0
EOF
chmod +x "$WORK/bin/zfs" "$WORK/bin/qm" "$WORK/bin/pct"
touch "$WORK/pve/qemu-server/100.conf" "$WORK/pve/qemu-server/999.conf" "$WORK/pve/lxc/200.conf"
printf '# managed\nrpool/data\n' > "$WORK/allow/backup-test"

export PATH="$WORK/bin:$PATH"
export ZFS_QUIESCE_ALLOW_DIR="$WORK/allow"
export ZFS_QUIESCE_PVE_DIR="$WORK/pve"
export TRACE="$WORK/trace"
export VSSOUT="$WORK/vss.json"
: > "$TRACE"

run() { SUDO_USER=backup-test bash "$HELPER" "$@" 2>&1; }
rc_of() { SUDO_USER=backup-test bash "$HELPER" "$@" >/dev/null 2>&1; echo $?; }

# ---- refusals: the boundary ----------------------------------------------

# A guest the account may NOT touch, even though it exists on this host.
r=$(rc_of freeze 999)
[ "$r" = 2 ] && ok "refuses a guest outside the delegated datasets" \
             || bad "refuses a guest outside the delegated datasets" "rc=$r, expected 2"

# Anything that is not a plain number dies before it can reach qm/pct. Each of
# these would be a different disaster if it were passed through.
for arg in '100;id' '$(id)' '`id`' '--' '-r' '/etc/passwd' '100 200' '' '1e2' '10.0' '+100'; do
    r=$(rc_of freeze "$arg")
    [ "$r" = 2 ] && ok "refuses malformed id '$arg'" \
                 || bad "refuses malformed id '$arg'" "rc=$r, expected 2"
done

# The verbs that do not exist must not be reachable. guest-exec is named
# explicitly because it is THE capability this script exists to withhold.
for v in guest-exec exec destroy stop shell 'freeze;id'; do
    r=$(rc_of "$v" 100)
    [ "$r" = 2 ] && ok "refuses unknown verb '$v'" \
                 || bad "refuses unknown verb '$v'" "rc=$r, expected 2"
done

# Absence of a whitelist must read as "never granted", never as "allow all".
# In a subshell: `VAR=x r=$(...)` would be TWO assignments to this shell, not an
# environment prefix, and would clobber the whitelist for every later case.
r=$(ZFS_QUIESCE_ALLOW_DIR="$WORK/nonexistent" SUDO_USER=backup-test \
        bash "$HELPER" freeze 100 >/dev/null 2>&1; echo $?)
[ "$r" = 4 ] && ok "fails closed when the account has no whitelist" \
             || bad "fails closed when the account has no whitelist" "rc=$r, expected 4"

# Nothing above may have reached qm/pct at all.
if [ ! -s "$TRACE" ]; then
    ok "no refused call reached qm/pct"
else
    bad "no refused call reached qm/pct" "trace not empty: $(tr '\n' ';' < "$TRACE")"
fi

# ---- the allowed path -----------------------------------------------------

out=$(run status); r=$?
{ [ "$r" = 0 ] && [ "${out#OK }" != "$out" ]; } \
    && ok "bare 'status' answers the privilege probe" \
    || bad "bare 'status' answers the privilege probe" "rc=$r out=$out"

out=$(run status 100)
case "$out" in
    *"kind=qemu"*"running=yes"*) ok "status reports a VM" ;;
    *) bad "status reports a VM" "$out" ;;
esac

out=$(run freeze 100)
case "$out" in *"froze VM 100"*) ok "freeze uses the guest agent for a VM" ;;
   *) bad "freeze uses the guest agent for a VM" "$out" ;; esac

out=$(run thaw 100)
case "$out" in *"thawed VM 100"*) ok "thaw uses the guest agent for a VM" ;;
   *) bad "thaw uses the guest agent for a VM" "$out" ;; esac

# A container is FLUSHED, not frozen -- ZFS has no FIFREEZE. The wording matters:
# mistaking one for the other is mistaking crash-consistent for quiesced.
out=$(run freeze 200)
case "$out" in *"flush, not a freeze"*) ok "container freeze says it is only a flush" ;;
   *) bad "container freeze says it is only a flush" "$out" ;; esac

r=$(rc_of writers 200)
[ "$r" = 3 ] && ok "writers refuses a container" \
             || bad "writers refuses a container" "rc=$r, expected 3"

# A failing qm must surface as a failure, not as a silent success -- a freeze
# that quietly did not happen is the exact failure mode this feature prevents.
r=$(QM_FAIL=1 SUDO_USER=backup-test bash "$HELPER" freeze 100 >/dev/null 2>&1; echo $?)
[ "$r" = 3 ] && ok "a failing qm freeze is reported, not swallowed" \
             || bad "a failing qm freeze is reported, not swallowed" "rc=$r, expected 3"

# ---- writers: the vsql2 case ----------------------------------------------
#
# qemu NEVER inspects individual VSS writer state (verified in qemu v7.2.0,
# v8.2.0 and master: requester.cpp calls GatherWriterStatus but there is no
# GetWriterStatus / VSS_WRITER_STATE anywhere in it), so this verb is the only
# way to see writer state from the host.
#
# The fixture below is a REAL capture from vsql2, and it is the state left by a
# SUCCESSFUL freeze -- measured 2026-07-31, writer [1] Stable immediately before
# a manual fsfreeze-freeze/thaw and [10] Failed immediately after, same instance
# id. An earlier version of this suite asserted that this same output means "a
# failed writer", which taught the helper to shout FAILED after every healthy
# backup. These cases now pin the opposite contract: report the state machine,
# render no verdict, and say so in the output.
cat > "$VSSOUT" <<'EOF'
{
   "exitcode" : 0,
   "out-data" : "Writer name: 'SqlServerWriter'\r\n   State: [10] Failed\r\n   Last error: Timed out\r\n\r\nWriter name: 'System Writer'\r\n   State: [5] Waiting for completion\r\n   Last error: No error\r\n\r\nWriter name: 'WMI Writer'\r\n   State: [1] Stable\r\n   Last error: No error\r\n"
}
EOF
out=$(run writers 100)
case "$out" in
    *"writer=SqlServerWriter"*"class=failed"*) ok "writers reports a failed writer state" ;;
    *) bad "writers reports a failed writer state" "$out" ;;
esac
# The old label. If it ever comes back, so does the false alarm.
case "$out" in
    *FAILED*) bad "writers no longer SHOUTS a verdict" "$out" ;;
    *)        ok "writers no longer SHOUTS a verdict" ;;
esac
case "$out" in
    *"writer=System Writer"*"class=transient"*) ok "a waiting writer is transient, not failed" ;;
    *) bad "a waiting writer is transient, not failed" "$out" ;;
esac
case "$out" in
    *"WRITERS total=3 stable=1 transient=1 failed=1"*) ok "writers summary counts every class" ;;
    *) bad "writers summary counts every class" "$out" ;;
esac
# The caveat travels WITH the data. Without it the counts read as a verdict,
# which is the whole defect this block exists to prevent.
case "$out" in
    *"WRITERS-NOTE writer state is not a backup verdict"*) ok "the summary ships its own caveat" ;;
    *) bad "the summary ships its own caveat" "$out" ;;
esac

# ---- writers: a LOCALISED guest -------------------------------------------
#
# vssadmin is translated. Captured live from VM 106 on pve1 (Polish Windows),
# 2026-07-31, alongside an English capture from VM 106 on metropolis pve1 -- the
# labels differ, the structure and the [N] state numbers do not. The parser that
# keyed on "Writer name:" / "State:" / "Last error:" reported total=0 here while
# vssadmin had actually succeeded. Labels are written in ASCII below; the parser
# never looks at them, which is precisely the property under test.
cat > "$VSSOUT" <<'EOF'
{
   "exitcode" : 0,
   "out-data" : "Nazwa modulu zapisujacego: 'Task Scheduler Writer'\r\n   Identyfikator modulu zapisujacego: {d61d61c8-d73a-4eee-8cdd-f6f9786b7124}\r\n   Stan: [1] Stabilne\r\n   Ostatni blad: Nie ma bledow.\r\n\r\nNazwa modulu zapisujacego: 'SqlServerWriter'\r\n   Identyfikator modulu zapisujacego: {a65faa63-5ea8-4ebc-9dbd-a0c4db26912a}\r\n   Stan: [10] Nie powiodlo sie\r\n   Ostatni blad: Przekroczono limit czasu\r\n"
}
EOF
out=$(run writers 100)
case "$out" in
    *"writer=Task Scheduler Writer"*"class=stable"*) ok "localised guest: stable writer is read" ;;
    *) bad "localised guest: stable writer is read" "$out" ;;
esac
case "$out" in
    *"writer=SqlServerWriter"*"class=failed"*) ok "localised guest: state number beats the label" ;;
    *) bad "localised guest: state number beats the label" "$out" ;;
esac
case "$out" in
    *"WRITERS total=2"*) ok "localised guest: both writers counted" ;;
    *) bad "localised guest: both writers counted" "$out" ;;
esac

# An unparseable reply must say so, not report an empty but healthy-looking set.
# "total=0" would read as "this guest has no writers", which no Windows does.
cat > "$VSSOUT" <<'EOF'
{
   "exitcode" : 0,
   "out-data" : "some future vssadmin that we cannot parse at all\r\n"
}
EOF
out=$(run writers 100)
case "$out" in
    *WRITERS-UNREADABLE*) ok "an unparseable reply is called unreadable, not empty" ;;
    *) bad "an unparseable reply is called unreadable, not empty" "$out" ;;
esac

# ---- sqlfreeze: the signal that writer state could not give -----------------
#
# SQL Server logs 3197 "I/O is frozen on database X" and 3198 "I/O was resumed".
# A balanced pair per database is the documented POSITIVE proof that the
# application-level quiesce happened -- the thing `writers` cannot tell us.
# Measured on vsql2 2026-07-31: balanced at every quiesce, including the nightly
# job (227/227 on MSSQLSERVER, 187/187 on MSSQL$SQL2019).
cat > "$VSSOUT" <<'EOF'
{
   "exitcode" : 0,
   "out-data" : "SQLFREEZE-INSTANCE MSSQLSERVER 227 227 2026-07-31T16:48:21\r\nSQLFREEZE-INSTANCE MSSQL$SQL2019 187 187 2026-07-31T16:48:21\r\n"
}
EOF
out=$(run sqlfreeze 100 3600)
case "$out" in
    *"frozen=414 resumed=414 verdict=engaged"*) ok "sqlfreeze: balanced pairs read as engaged" ;;
    *) bad "sqlfreeze: balanced pairs read as engaged" "$out" ;;
esac
case "$out" in
    *"SQLFREEZE-NOTE"*"does not prove the snapshot restores"*) ok "sqlfreeze ships its own caveat" ;;
    *) bad "sqlfreeze ships its own caveat" "$out" ;;
esac
# REV-20260731-010 §2. A window is not a correlation: on a host where pvesr,
# snapsend and a human all quiesce the same guest, a neighbouring operation's
# events inside the window read as `engaged`. The verdict line must not be
# quotable without that, so the caveat travels WITH it.
case "$out" in
    *"This is not correlated to a specific snapshot run."*)
        ok "sqlfreeze says the window is not correlated to a run" ;;
    *) bad "sqlfreeze says the window is not correlated to a run" "$out" ;;
esac
# §4: the counts are per instance, and the output must not let anyone read them
# as per database -- the database name is in translated message text, which is
# deliberately never parsed.
case "$out" in
    *"counted per instance, not per database"*)
        ok "sqlfreeze states its granularity" ;;
    *) bad "sqlfreeze states its granularity" "$out" ;;
esac

# Frozen without a matching resume is the one genuinely alarming shape: SQL held
# its I/O and something never released it.
cat > "$VSSOUT" <<'EOF'
{
   "exitcode" : 0,
   "out-data" : "SQLFREEZE-INSTANCE MSSQLSERVER 227 0 2026-07-31T16:48:21\r\n"
}
EOF
out=$(run sqlfreeze 100 3600)
case "$out" in
    *verdict=unbalanced*) ok "sqlfreeze: frozen without resumed is unbalanced" ;;
    *) bad "sqlfreeze: frozen without resumed is unbalanced" "$out" ;;
esac

# No events is not a fault -- most guests have no SQL at all.
cat > "$VSSOUT" <<'EOF'
{
   "exitcode" : 0,
   "out-data" : "SQLFREEZE-NONE\r\n"
}
EOF
out=$(run sqlfreeze 100 3600)
case "$out" in
    *verdict=no-freeze-seen*) ok "sqlfreeze: no events is reported, not failed" ;;
    *) bad "sqlfreeze: no events is reported, not failed" "$out" ;;
esac
# Found on a LIVE Windows guest that runs no SQL Server, 2026-07-31. The
# correlation caveat was unconditional, so "SQL participated in at least one VSS
# freeze/resume" printed directly under verdict=no-freeze-seen -- a flat
# contradiction, and in the direction that invents evidence. Every fixture here
# HAD events and the assertion above only checked the verdict, so the suite was
# blind to it.
case "$out" in
    *"SQL participated in at least one"*)
        bad "sqlfreeze: no-freeze-seen must not claim SQL participated" "$out" ;;
    *"no 3197/3198 events in the window"*)
        ok "sqlfreeze: no-freeze-seen must not claim SQL participated" ;;
    *)  bad "sqlfreeze: no-freeze-seen must not claim SQL participated" "no note at all: $out" ;;
esac
r=$(rc_of sqlfreeze 100 3600)
[ "$r" = 0 ] && ok "sqlfreeze: no events still exits 0" \
             || bad "sqlfreeze: no events still exits 0" "rc=$r, expected 0"

# When the guest is still working at the timeout, qm exits 0 with only a pid and
# no out-data. Reporting that as "nothing found" would be a false all-clear.
# Measured on a Server 2008 guest where PowerShell alone exceeds two minutes.
cat > "$VSSOUT" <<'EOF'
{
   "pid" : 4276
}
EOF
out=$(run sqlfreeze 100 3600)
r=$(rc_of sqlfreeze 100 3600)
case "$out" in
    *"did not answer within"*"only a pid"*) ok "sqlfreeze: a timed-out guest is not a clean result" ;;
    *) bad "sqlfreeze: a timed-out guest is not a clean result" "$out" ;;
esac
[ "$r" = 3 ] && ok "sqlfreeze: a timed-out guest fails (3)" \
             || bad "sqlfreeze: a timed-out guest fails (3)" "rc=$r, expected 3"

# The window is the ONLY caller-influenced part of the command sent to the
# guest. It must never be able to become anything but digits.
for w in abc '3600; whoami' '-1' '' '99999'; do
    r=$(rc_of sqlfreeze 100 "$w")
    [ "$r" = 2 ] || bad "sqlfreeze rejects window '$w'" "rc=$r, expected 2"
done
ok "sqlfreeze rejects every non-numeric or out-of-range window"

# And the whitelist still governs, exactly as for every other verb.
: > "$TRACE"
r=$(rc_of sqlfreeze 999 3600)
[ "$r" = 2 ] && ok "sqlfreeze refuses a guest outside the delegated datasets" \
             || bad "sqlfreeze refuses a guest outside the delegated datasets" "rc=$r, expected 2"
case "$(cat "$TRACE")" in
    *"guest exec 999"*) bad "a refused sqlfreeze never reaches the guest" "$(cat "$TRACE")" ;;
    *) ok "a refused sqlfreeze never reaches the guest" ;;
esac

# ---- the sudoers rule deploy.sh writes ------------------------------------
#
# The env overrides this suite depends on are safe ONLY because sudo strips
# them. If SETENV ever appears in that rule, a delegated account can point the
# whitelist at a file it controls and freeze anything on the host.
if grep -q 'SETENV' <(grep -A3 "ALL=(root) NOPASSWD" "$REPO/deploy.sh"); then
    bad "deploy.sh's sudoers rule carries no SETENV" "SETENV found -- the whitelist could be redirected by the caller"
else
    ok "deploy.sh's sudoers rule carries no SETENV"
fi

# ---- teardown (REV-20260731-007 §3.7) -------------------------------------
#
# A removed backup relationship must not leave privileged artifacts behind. The
# per-account pieces go; the helper is shared by every peer on the host and is
# kept, which is fine ONLY because it is stated out loud -- an operator should
# not have to work out which artifacts are shared.
TD="$WORK/teardown"
mkdir -p "$TD/etc/zfs-quiesce-allow" "$TD/etc/sudoers.d"
echo "rpool/data" > "$TD/etc/zfs-quiesce-allow/backup-test"
echo "backup-test ALL=(root) NOPASSWD: /usr/local/sbin/zfs-quiesce-helper" \
    > "$TD/etc/sudoers.d/zfs-quiesce-backup-test"
sed -e "s#/etc/zfs-quiesce-allow#$TD/etc/zfs-quiesce-allow#g" \
    -e "s#/etc/sudoers.d#$TD/etc/sudoers.d#g" "$REPO/deploy.sh" > "$TD/deploy.sh"

out=$(bash "$TD/deploy.sh" --revoke-quiesce backup-test 2>&1); r=$?
[ "$r" = 0 ] && ok "revoke: exits cleanly" || bad "revoke: exits cleanly" "rc=$r"
[ -e "$TD/etc/zfs-quiesce-allow/backup-test" ] \
    && bad "revoke: removes the whitelist" "still there" \
    || ok "revoke: removes the whitelist"
[ -e "$TD/etc/sudoers.d/zfs-quiesce-backup-test" ] \
    && bad "revoke: removes the sudoers rule" "still there" \
    || ok "revoke: removes the sudoers rule"

# Revoking something that was never granted must be a clean no-op, not an error
# -- teardown scripts run on hosts that may never have had the grant.
out=$(bash "$TD/deploy.sh" --revoke-quiesce backup-test 2>&1); r=$?
case "$out" in
    *"nothing to revoke"*) [ "$r" = 0 ] && ok "revoke: a second run is a clean no-op" \
                                        || bad "revoke: a second run is a clean no-op" "rc=$r" ;;
    *) bad "revoke: a second run is a clean no-op" "$out" ;;
esac

r=$(bash "$TD/deploy.sh" --revoke-quiesce 'bad;name' >/dev/null 2>&1; echo $?)
[ "$r" != 0 ] && ok "revoke: refuses a malformed account name" \
              || bad "revoke: refuses a malformed account name" "rc=$r"

# ---- transactional install (REV-20260731-008 F2) ---------------------------
#
# A failed `--join --allow-quiesce` must end in one of two states: fully
# installed, or nothing new left behind. The old order installed the helper and
# whitelist first and only then found out sudo was missing, leaving a
# half-built privileged feature -- not dangerous (no rule means no grant) but
# ambiguous, and ambiguity about privilege is what makes the next person guess.
#
# install_quiesce_grant is extracted and driven directly: deploy.sh cannot be
# sourced (it would run the whole provisioning body), and the point here is to
# fail at each stage in turn, which needs control over its dependencies.
TX="$WORK/tx"; mkdir -p "$TX/bin"
sed -n '/^install_quiesce_grant() {/,/^}$/p' "$REPO/deploy.sh" > "$TX/fn.sh"
[ -s "$TX/fn.sh" ] || bad "tx: could not extract install_quiesce_grant" "empty"

tx_stub_sudo() {   # tx_stub_sudo <visudo-rc>
    # The visudo stub logs what it was asked to validate. That log is the only
    # way to prove the rollback re-checked the sudoers state it left behind
    # (REV-20260731-009 §3) rather than assuming it was fine.
    cat > "$TX/bin/visudo" <<EOF
#!/bin/sh
echo "\$@" >> "$TX/visudo.log"
exit $1
EOF
    printf '#!/bin/sh\nexit 0\n' > "$TX/bin/sudo"
    chmod +x "$TX/bin/visudo" "$TX/bin/sudo"
}

tx_run() {   # tx_run <visudo-rc> <stage-fails-on> [apt-rc] [fail-mkdir] [commit-fails-on] [crash-at]
    #   apt-rc 0 = sudo is already there   1 = the install of sudo fails
    #          2 = sudo is MISSING and apt supplies it (the only path that
    #              reaches the "package left behind" notice, §5)
    #   fail-mkdir 1 = break only the `install -d` for the whitelist directory
    #   commit-fails-on = the rename that commits this destination fails
    #   crash-at        = the process DIES at that rename, running no rollback
    #
    # Staging and committing are separate injection points on purpose. A
    # staging failure happens before any destination has changed, so the
    # interesting assertion is that nothing was touched; a commit failure
    # happens after earlier destinations already changed, which is where
    # restore-versus-remove is decided.
    # TX_KEEP=1 runs against whatever is already in the sandbox, which is how
    # the update cases start from an existing grant instead of a clean host.
    local vrc="$1" failon="$2" aptrc="${3:-0}"
    [ "${TX_KEEP:-0}" -eq 1 ] || rm -rf "$TX/root"
    mkdir -p "$TX/root/etc/sudoers.d" "$TX/root/usr/local/sbin"
    : > "$TX/visudo.log"
    # Its own TMPDIR, so "the transaction left no staged file or rollback copy
    # behind" is a thing the suite can actually assert rather than assume.
    rm -rf "$TX/tmp"; mkdir -p "$TX/tmp"
    # The dependency case has to be a genuine absence: with a visudo stub on
    # PATH the install branch is never reached and the case would pass while
    # testing nothing. (MSYS has neither sudo nor visudo of its own.)
    rm -f "$TX/bin/visudo" "$TX/bin/sudo"
    [ "$aptrc" -eq 0 ] && tx_stub_sudo "$vrc"
    # faildir breaks ONLY the `install -d` that creates the whitelist directory.
    # A path substring cannot single that call out -- the directory path is also
    # a prefix of the whitelist path -- so the stub matches on the -d flag.
    # `install` fails only for the named target, so each stage can be broken in
    # isolation while the others behave normally.
    # Strips -o/-g: this box has no 'root' user, so real ownership flags fail for
    # reasons that have nothing to do with what is being tested. Fails only for
    # the named target, so each stage can be broken in isolation.
    # The commit is a rename, so breaking a commit means breaking `mv` -- but
    # only the rename that COMMITS. Matching on a `.zqg-new` source is what
    # separates it from the rename that RESTORES a .zqg-bak during rollback,
    # which must keep working or the test would be measuring the wrong failure.
    cat > "$TX/bin/mv" <<EOF
#!/bin/bash
FAILMV='${5:-}'
CRASHAT='${6:-}'
for a in "\$@"; do
    case "\$a" in
        *.zqg-new)
            [ -n "\$FAILMV" ] && case "\$a" in *\$FAILMV*) exit 1 ;; esac
            ;;
    esac
    shift_last="\$a"
done
# CRASHAT matches the DESTINATION -- the last argument -- because the commit
# order now begins by renaming the live rule ONTO its .zqg-bak name, and that
# rename has no .zqg-new source to key on.
[ -n "\$CRASHAT" ] && case "\$shift_last" in *\$CRASHAT) kill -9 \$PPID; exit 137 ;; esac
exec /usr/bin/mv "\$@"
EOF
    chmod +x "$TX/bin/mv"
    cat > "$TX/bin/install" <<EOF
#!/bin/bash
FAILON='$failon'
FAILDIR='${4:-0}'
args=()
isdir=0
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o|-g) shift 2 ;;
        -d) isdir=1; args+=("\$1"); shift ;;
        *) if [ -n "\$FAILON" ]; then case "\$1" in *\$FAILON*) exit 1 ;; esac; fi
           args+=("\$1"); shift ;;
    esac
done
if [ "\$FAILDIR" = 1 ] && [ "\$isdir" = 1 ]; then
    # Faithful to coreutils: \`install -d\` MAKES the directory and only then
    # applies owner and mode, so the realistic failure is one that has already
    # created it. A stub that just exits would leave nothing to clean up and the
    # test would pass without proving anything.
    /usr/bin/install "\${args[@]}" >/dev/null 2>&1
    exit 1
fi
exec /usr/bin/install "\${args[@]}"
EOF
    chmod +x "$TX/bin/install"
    (
        PATH="$TX/bin:$PATH"
        TMPDIR="$TX/tmp"; export TMPDIR
        REPO_DIR="$REPO"
        log()  { echo ">>> $*"; }
        warn() { echo "!!! $*" >&2; }
        apt_install_with_fallback() {
            if [ "$aptrc" -eq 2 ]; then tx_stub_sudo "$vrc"; return 0; fi
            return "$aptrc"
        }
        # shellcheck disable=SC1090
        . "$TX/fn.sh"
        # Redirect the three absolute paths into the sandbox.
        eval "$(declare -f install_quiesce_grant             | sed -e "s#/usr/local/sbin/zfs-quiesce-helper#$TX/root/usr/local/sbin/zfs-quiesce-helper#g"                   -e "s#/etc/zfs-quiesce-allow#$TX/root/etc/zfs-quiesce-allow#g"                   -e "s#/etc/sudoers.d#$TX/root/etc/sudoers.d#g")"
        install_quiesce_grant backup-test "${TX_DATASETS:-rpool/data}" > "$TX/out.log" 2>&1
        echo "rc=$?"
    )
}
tx_orphans() {
    local n=0
    [ -e "$TX/root/etc/zfs-quiesce-allow/backup-test" ] && n=$((n+1))
    [ -e "$TX/root/etc/sudoers.d/zfs-quiesce-backup-test" ] && n=$((n+1))
    echo "$n"
}

# Happy path first, so a later "no orphans" result cannot be a silent no-op.
r=$(tx_run 0 "")
if [ "$r" = "rc=0" ] && [ -e "$TX/root/etc/sudoers.d/zfs-quiesce-backup-test" ]    && [ -e "$TX/root/etc/zfs-quiesce-allow/backup-test" ]; then
    ok "tx: a clean run installs whitelist and rule"
else
    bad "tx: a clean run installs whitelist and rule" "$r"
fi

# Dependency stage: sudo cannot be installed -> nothing may be created at all.
r=$(tx_run 0 "" 1)
[ "$r" != "rc=0" ] && [ "$(tx_orphans)" = 0 ]     && ok "tx: a failed sudo install leaves no artifacts"     || bad "tx: a failed sudo install leaves no artifacts" "$r orphans=$(tx_orphans)"

# visudo rejects the rule -> the whitelist must not survive either.
r=$(tx_run 1 "")
[ "$r" != "rc=0" ] && [ "$(tx_orphans)" = 0 ]     && ok "tx: a rejected sudoers rule leaves no whitelist behind"     || bad "tx: a rejected sudoers rule leaves no whitelist behind" "$r orphans=$(tx_orphans)"

# Whitelist install fails -> no rule, no whitelist.
r=$(tx_run 0 "zfs-quiesce-allow")
[ "$r" != "rc=0" ] && [ "$(tx_orphans)" = 0 ]     && ok "tx: a failed whitelist install rolls back"     || bad "tx: a failed whitelist install rolls back" "$r orphans=$(tx_orphans)"

# Rule install fails at the very last step -> the whitelist created moments
# earlier must go too. This is the case the old code got wrong.
r=$(tx_run 0 "" 0 0 "sudoers.d")
[ "$r" != "rc=0" ] && [ "$(tx_orphans)" = 0 ]     && ok "tx: a failed rule install rolls the whitelist back too"     || bad "tx: a failed rule install rolls the whitelist back too" "$r orphans=$(tx_orphans)"

# And a retry after a failure must succeed cleanly rather than trip over
# leftovers from the failed attempt.
tx_run 1 "" >/dev/null
r=$(tx_run 0 "")
[ "$r" = "rc=0" ] && ok "tx: a retry after a failure succeeds cleanly"                   || bad "tx: a retry after a failure succeeds cleanly" "$r"

# ---- update path: an account that ALREADY holds a grant (REV-20260731-009) --
#
# Everything above starts from a clean host, which is exactly the blind spot the
# review found: rollback that only knows how to REMOVE is complete on a first
# enrolment and half a transaction on a re-enrolment. Re-running
# `--join --allow-quiesce` with a changed dataset list or a newer helper
# overwrites all three destinations, and a failure after the first replacement
# used to leave a mix of old and new that nothing put back.
#
# The seeded content is deliberately recognisable, so "unchanged" is proved by
# content and not by a file merely existing.
TX_ALLOW="$TX/root/etc/zfs-quiesce-allow/backup-test"
TX_RULE="$TX/root/etc/sudoers.d/zfs-quiesce-backup-test"
TX_HELPER="$TX/root/usr/local/sbin/zfs-quiesce-helper"

tx_seed() {   # a host where backup-test already holds a complete, valid grant
    rm -rf "$TX/root"
    mkdir -p "$TX/root/etc/sudoers.d" "$TX/root/etc/zfs-quiesce-allow" "$TX/root/usr/local/sbin"
    printf '#!/bin/sh\n# OLD helper, the version already on the host\nexit 0\n' > "$TX_HELPER"
    chmod 0755 "$TX_HELPER"
    printf '# managed by deploy.sh --join --allow-quiesce, do not edit by hand\nrpool/old-dataset\n' > "$TX_ALLOW"
    chmod 0644 "$TX_ALLOW"
    # The same text install_quiesce_grant would generate, sandbox path included:
    # the rule does not depend on the dataset list, so an update must leave it
    # byte-identical, and that is only a real assertion if it starts identical.
    printf 'backup-test ALL=(root) NOPASSWD: %s\n' "$TX_HELPER" > "$TX_RULE"
    chmod 0440 "$TX_RULE"
}
tx_h() {   # content hash of one path, or ABSENT
    [ -e "$1" ] && md5sum < "$1" | cut -d' ' -f1 || echo ABSENT
}
tx_hash3() { printf 'helper=%s allow=%s rule=%s' "$(tx_h "$TX_HELPER")" "$(tx_h "$TX_ALLOW")" "$(tx_h "$TX_RULE")"; }
tx_tree() {   # every file in the sandbox, so "changed exactly these" is checkable
    find "$TX/root" -type f | sort | while IFS= read -r f; do
        printf '%s %s\n' "$(md5sum < "$f" | cut -d' ' -f1)" "${f#"$TX/root"}"
    done
}

# 1. Fail while replacing the whitelist: the helper has already been overwritten
#    by then, so a rollback that only removes new files would leave the new
#    helper next to the old whitelist and the old rule.
tx_seed; before=$(tx_hash3)
r=$(TX_KEEP=1 tx_run 0 "" 0 0 "zfs-quiesce-allow")
if [ "$r" != "rc=0" ] && [ "$(tx_hash3)" = "$before" ]; then
    ok "tx-update: a failed whitelist replace restores all three old files"
else
    bad "tx-update: a failed whitelist replace restores all three old files" "$r
      before: $before
      after:  $(tx_hash3)"
fi

# 2. Fail at the very last step, with helper AND whitelist already replaced.
tx_seed; before=$(tx_hash3)
r=$(TX_KEEP=1 tx_run 0 "" 0 0 "sudoers.d")
if [ "$r" != "rc=0" ] && [ "$(tx_hash3)" = "$before" ]; then
    ok "tx-update: a failed rule replace restores helper and whitelist too"
else
    bad "tx-update: a failed rule replace restores helper and whitelist too" "$r
      before: $before
      after:  $(tx_hash3)"
fi

# An administrator has to be able to tell a restored grant from a removed one --
# the two leave the host in completely different states.
if grep -q "restored:" "$TX/out.log" && ! grep -q "removed what this run created" "$TX/out.log"; then
    ok "tx-update: the rollback says it RESTORED, not that it removed"
else
    bad "tx-update: the rollback says it RESTORED, not that it removed" "$(cat "$TX/out.log")"
fi

# §3: the restored sudoers state is re-validated, not assumed. The stub logs
# every invocation, so a bare `-c` after the staged `-cf <tmp>` is the proof.
if grep -qx -- "-c" "$TX/visudo.log"; then
    ok "tx-update: sudoers is re-validated after a rollback"
else
    bad "tx-update: sudoers is re-validated after a rollback" "$(cat "$TX/visudo.log")"
fi

# 3. A successful update must change the three destinations and NOTHING else.
tx_seed; before=$(tx_hash3); tree_before=$(tx_tree)
r=$(TX_KEEP=1 tx_run 0 "")
after=$(tx_hash3)
if [ "$r" = "rc=0" ] && [ "$after" != "$before" ] \
   && grep -q '^rpool/data$' "$TX_ALLOW" && ! grep -q 'old-dataset' "$TX_ALLOW" \
   && cmp -s "$TX_HELPER" "$REPO/zfs-quiesce-helper.sh"; then
    ok "tx-update: a successful update replaces helper and whitelist"
else
    bad "tx-update: a successful update replaces helper and whitelist" "$r
      $(cat "$TX_ALLOW")"
fi
# The rule text does not depend on the dataset list, so an update leaves it
# byte-identical -- and the diff below is what bounds the blast radius.
changed=$(diff <(echo "$tree_before") <(tx_tree) | grep '^[<>]' | awk '{print $3}' | sort -u)
expected=$(printf '/etc/zfs-quiesce-allow/backup-test\n/usr/local/sbin/zfs-quiesce-helper\n')
if [ "$changed" = "$expected" ]; then
    ok "tx-update: nothing outside the three destinations is touched"
else
    bad "tx-update: nothing outside the three destinations is touched" "changed: $changed"
fi

# 4. Re-running with identical content is a bounded replacement: the same three
#    files, same content, no third state.
before=$(tx_hash3); tree_before=$(tx_tree)
r=$(TX_KEEP=1 tx_run 0 "")
if [ "$r" = "rc=0" ] && [ "$(tx_hash3)" = "$before" ] && [ "$(tx_tree)" = "$tree_before" ]; then
    ok "tx-update: an identical rerun changes no content anywhere"
else
    bad "tx-update: an identical rerun changes no content anywhere" "$r
      before: $before
      after:  $(tx_hash3)"
fi

# 5. The shared helper is the case that reaches past the account being enrolled:
#    a second peer's grant must survive a failed update, and the helper those
#    other peers are using must come back at its OLD version -- they never asked
#    for an upgrade.
tx_seed
printf '# other peer\nrpool/data\n' > "$TX/root/etc/zfs-quiesce-allow/other-peer"
printf 'other-peer ALL=(root) NOPASSWD: /usr/local/sbin/zfs-quiesce-helper\n' > "$TX/root/etc/sudoers.d/zfs-quiesce-other-peer"
other_before=$(tx_h "$TX/root/etc/zfs-quiesce-allow/other-peer")
before=$(tx_hash3)
r=$(TX_KEEP=1 tx_run 0 "" 0 0 "sudoers.d")
if [ "$r" != "rc=0" ] && [ "$(tx_hash3)" = "$before" ] \
   && grep -q 'OLD helper' "$TX_HELPER" \
   && [ "$(tx_h "$TX/root/etc/zfs-quiesce-allow/other-peer")" = "$other_before" ]; then
    ok "tx-update: a failed update restores the shared helper and spares other peers"
else
    bad "tx-update: a failed update restores the shared helper and spares other peers" "$r
      before: $before
      after:  $(tx_hash3)"
fi

# ---- the mkdir failure path (REV-20260731-011 §2) --------------------------
#
# The review read this path as missing its rollback. It is not -- the call has
# been there since the REV-008 transaction work and is simply not in the diff
# under review -- but it had no fault injection of its own, which is what let the
# question stand. It has one now.
#
# The literal case §3.1 asks for, "existing full grant, mkdir fails", cannot
# happen: an account that already holds a grant has its whitelist INSIDE
# $allow_dir, so the directory necessarily exists and `[ ! -d ]` never fires.
# The reachable shape of the same concern is below: a host that already has the
# shared helper but no whitelist directory -- a revoked last account whose empty
# directory was then removed by hand.
tx_seed_helper_only() {
    rm -rf "$TX/root"
    mkdir -p "$TX/root/etc/sudoers.d" "$TX/root/usr/local/sbin"
    printf '#!/bin/sh\n# OLD helper, still used by other peers\nexit 0\n' > "$TX_HELPER"
    chmod 0755 "$TX_HELPER"
}
tx_seed_helper_only; before=$(tx_h "$TX_HELPER")
r=$(TX_KEEP=1 tx_run 0 "" 0 1)
if [ "$r" != "rc=0" ] && [ "$(tx_h "$TX_HELPER")" = "$before" ] && grep -q 'OLD helper' "$TX_HELPER"; then
    ok "tx-mkdir: a failed whitelist directory restores the previous helper"
else
    bad "tx-mkdir: a failed whitelist directory restores the previous helper" "$r
      before: $before  after: $(tx_h "$TX_HELPER")"
fi

# §3.2, clean host: nothing may survive -- not the helper this run installed
# moments earlier, and not the directory a partially-successful `install -d`
# may have created before failing on owner or mode.
r=$(tx_run 0 "" 0 1)
if [ "$r" != "rc=0" ] && [ ! -e "$TX_HELPER" ] && [ ! -e "$TX_ALLOW" ] && [ ! -e "$TX_RULE" ] \
   && [ ! -d "$TX/root/etc/zfs-quiesce-allow" ]; then
    ok "tx-mkdir: on a clean host a failed directory leaves nothing behind"
else
    bad "tx-mkdir: on a clean host a failed directory leaves nothing behind" "$r
      helper=$([ -e "$TX_HELPER" ] && echo present || echo absent) dir=$([ -d "$TX/root/etc/zfs-quiesce-allow" ] && echo present || echo absent)"
fi

# Staged files and rollback copies are part of "nothing behind" too.
if [ -z "$(ls -A "$TX/tmp" 2>/dev/null)" ]; then
    ok "tx-mkdir: no staged file or rollback copy is left in TMPDIR"
else
    bad "tx-mkdir: no staged file or rollback copy is left in TMPDIR" "$(ls -A "$TX/tmp")"
fi

# §3, the structural guard. The point of this one is not today's code but the
# next person's: once the install phase has begun, a failure exit that skips
# _grant_rollback is the exact hole this review went looking for, and it is
# cheaper to forbid mechanically than to re-audit by eye every time the function
# grows a step.
tx_guard_scan() {   # prints every `return 1` in the install phase with no rollback near it
    sed -n '/---- 4\. commit ----/,/^}$/p' "$1" | awk '
        { buf[NR] = $0 }
        /return 1/ {
            found = 0
            for (i = (NR > 4 ? NR - 4 : 1); i <= NR; i++) if (buf[i] ~ /_grant_rollback/) found = 1
            if (!found) printf "line %d: %s\n", NR, $0
        }'
}
offenders=$(tx_guard_scan "$REPO/deploy.sh")
[ -z "$offenders" ] && ok "tx-guard: every install-phase failure exit goes through the rollback" \
                    || bad "tx-guard: every install-phase failure exit goes through the rollback" "$offenders"

# A guard that cannot fail proves nothing, so it is pointed at a deliberately
# broken copy as well.
cat > "$TX/guard-bad.sh" <<'EOF'
    # ---- 4. commit ----
    did_helper=1
    install "$src" "$dest" || { warn "boom"; return 1; }
}
EOF
[ -n "$(tx_guard_scan "$TX/guard-bad.sh")" ] \
    && ok "tx-guard: the guard catches a rollback-less exit" \
    || bad "tx-guard: the guard catches a rollback-less exit" "the guard passed a file it should have failed"

# ---- crash safety: the process DIES mid-commit -----------------------------
#
# Everything above tests a step that FAILS, which runs the rollback. None of it
# says anything about a step that never returns -- kill -9, OOM, power loss --
# where no rollback runs at all. That is what staging plus rename is for, and
# the only way to test it is to actually kill the process between two renames.
#
# The mv stub kills its parent, which is the shell running the function, so no
# trap, no rollback and no cleanup happen. Exactly like the real thing.

# 1. Crash at the SECOND commit (the helper), with the whitelist already
#    committed. Every destination must hold a whole file -- the old one or the
#    new one, never a truncated one. That is the property in-place `install`
#    could not give.
tx_seed
old_helper=$(tx_h "$TX_HELPER"); old_rule=$(tx_h "$TX_RULE")
r=$(TX_KEEP=1 tx_run 0 "" 0 0 "" "sbin/zfs-quiesce-helper" 2>/dev/null)
# The rule is SUSPENDED by then, not unchanged -- that is the whole point of the
# REV-012 ordering -- so what "whole file" means for it is that its preserved
# copy is byte-identical to what was live before the run.
if [ "$r" != "rc=0" ] \
   && grep -q '^rpool/data$' "$TX_ALLOW" \
   && [ "$(tx_h "$TX_HELPER")" = "$old_helper" ] && grep -q 'OLD helper' "$TX_HELPER" \
   && [ ! -e "$TX_RULE" ] && [ "$(tx_h "$TX_RULE.zqg-bak")" = "$old_rule" ]; then
    ok "tx-crash: a crash mid-commit leaves whole files, never a partial one"
else
    bad "tx-crash: a crash mid-commit leaves whole files, never a partial one" "r=$r
      helper $(tx_h "$TX_HELPER") vs old $old_helper
      rule $(tx_h "$TX_RULE") bak $(tx_h "$TX_RULE.zqg-bak") vs old $old_rule"
fi

# The interrupted run's staging and backup files are still lying there -- that
# is the evidence the next run reads.
if [ -e "$TX_HELPER.zqg-new" ] && [ -e "$TX_ALLOW.zqg-bak" ]; then
    ok "tx-crash: the interrupted run leaves its staged and preserved files"
else
    bad "tx-crash: the interrupted run leaves its staged and preserved files" \
        "$(ls -A "$TX/root/usr/local/sbin" "$TX/root/etc/zfs-quiesce-allow" 2>&1)"
fi

# Nothing this transaction leaves in /etc/sudoers.d may be a file sudo will
# read. sudoers.d ignores names containing a '.' -- which is why the staged and
# preserved names carry one, and why pc_is_account forbids a dot in an account
# name so the FINAL name can never be ignored the same way.
offender=""
for f in "$TX/root/etc/sudoers.d"/*; do
    [ -e "$f" ] || continue
    b="${f##*/}"
    [ "$b" = "zfs-quiesce-backup-test" ] && continue
    case "$b" in *.*) ;; *) offender="$offender $b" ;; esac
done
[ -z "$offender" ] && ok "tx-crash: every leftover in sudoers.d is a name sudo ignores" \
                   || bad "tx-crash: every leftover in sudoers.d is a name sudo ignores" "$offender"

# 2. Recovery is "run it again": the next run reports the interruption, sweeps
#    the leftovers and finishes the job. No replay of a half-finished intent.
r=$(TX_KEEP=1 tx_run 0 "")
if [ "$r" = "rc=0" ] && cmp -s "$TX_HELPER" "$REPO/zfs-quiesce-helper.sh" \
   && [ ! -e "$TX_HELPER.zqg-new" ] && [ ! -e "$TX_ALLOW.zqg-bak" ] \
   && grep -q "was interrupted before it finished" "$TX/out.log"; then
    ok "tx-crash: the next run reports the interruption and completes"
else
    bad "tx-crash: the next run reports the interruption and completes" "r=$r
      $(cat "$TX/out.log")"
fi

# 3. The commit ORDER is the other half of crash safety, and REV-20260731-012
#    corrected which order that is. On an update the live rule is switched OFF
#    first, so a crash at the very next step finds the grant already inert and
#    the helper still untouched. The earlier version of this case asserted the
#    opposite -- rule unchanged, whitelist first -- which is exactly the widening
#    window the review found.
tx_seed
old_helper=$(tx_h "$TX_HELPER"); old_rule=$(tx_h "$TX_RULE")
r=$(TX_KEEP=1 tx_run 0 "" 0 0 "" "zfs-quiesce-allow/backup-test" 2>/dev/null)
if [ ! -e "$TX_RULE" ] && [ "$(tx_h "$TX_RULE.zqg-bak")" = "$old_rule" ] \
   && [ "$(tx_h "$TX_HELPER")" = "$old_helper" ]; then
    ok "tx-crash: the live rule is suspended first, helper still untouched"
else
    bad "tx-crash: the live rule is suspended first, helper still untouched" "r=$r
      rule $(tx_h "$TX_RULE") bak $(tx_h "$TX_RULE.zqg-bak") vs old $old_rule"
fi

# 4. On a clean host, a crash before the last commit must leave NO grant: the
#    rule is what grants, and it is the one thing that has not landed.
r=$(tx_run 0 "" 0 0 "" "sudoers.d/zfs-quiesce-backup-test" 2>/dev/null)
if [ ! -e "$TX_RULE" ] && [ -e "$TX_ALLOW" ] && [ -e "$TX_HELPER" ]; then
    ok "tx-crash: a crash before the last commit grants nothing"
else
    bad "tx-crash: a crash before the last commit grants nothing" \
        "rule=$([ -e "$TX_RULE" ] && echo present || echo absent)"
fi

# ---- REV-20260731-012: an update must never widen an ACTIVE grant -----------
#
# The cases above measure files. This block measures the thing that actually
# matters: the effective privilege boundary during an update of a grant that is
# already live.
#
# The defect the review found: committing the whitelist first was justified by
# calling it "a restriction", which is only true on a FIRST install. On an update
# the final sudoers rule already exists and stays active through every rename, so
# the moment a WIDER whitelist landed, the old rule and old helper could reach
# the newly added guests -- and a crash there made that permanent.
#
# The boundary is open only when BOTH hold: an active (dotless, therefore
# sudo-readable) rule exists, AND the whitelist names the new dataset. Until the
# whole commit succeeds, that combination must not appear.
tx_widened() {
    [ -e "$TX_RULE" ] || return 1                 # no active rule: cannot reach the helper
    grep -q '^rpool/data/vm-107-disk-0$' "$TX_ALLOW" 2>/dev/null
}
tx_seed_narrow() {   # a LIVE grant whose whitelist is narrower than the update's
    rm -rf "$TX/root"
    mkdir -p "$TX/root/etc/sudoers.d" "$TX/root/etc/zfs-quiesce-allow" "$TX/root/usr/local/sbin"
    printf '#!/bin/sh\n# OLD helper\nexit 0\n' > "$TX_HELPER"; chmod 0755 "$TX_HELPER"
    printf '# managed\nrpool/data/vm-106-disk-0\n' > "$TX_ALLOW"; chmod 0644 "$TX_ALLOW"
    printf 'backup-test ALL=(root) NOPASSWD: %s\n' "$TX_HELPER" > "$TX_RULE"; chmod 0440 "$TX_RULE"
}
# The update widens the list: 106 was already there, 107 is new.
tx_wide='rpool/data/vm-106-disk-0 rpool/data/vm-107-disk-0'

for point in "zqg-bak:suspending the old rule" \
             "zfs-quiesce-allow/backup-test:switching the whitelist" \
             "sbin/zfs-quiesce-helper:switching the helper"; do
    at="${point%%:*}"; what="${point#*:}"
    tx_seed_narrow
    TX_DATASETS="$tx_wide" TX_KEEP=1 tx_run 0 "" 0 0 "" "$at" >/dev/null 2>&1
    if tx_widened; then
        bad "tx-widen: a crash while $what must not widen the grant" \
            "active rule present AND the whitelist already names vm-107"
    else
        ok "tx-widen: a crash while $what must not widen the grant"
    fi
done

# And the completed update must actually take effect -- otherwise "never widens"
# would be satisfied by a function that does nothing at all.
tx_seed_narrow
r=$(TX_DATASETS="$tx_wide" TX_KEEP=1 tx_run 0 "")
if [ "$r" = "rc=0" ] && tx_widened; then
    ok "tx-widen: a completed update does grant the new dataset"
else
    bad "tx-widen: a completed update does grant the new dataset" "r=$r"
fi

# The narrowing direction has to end safely too: removing a dataset must leave
# the account unable to reach it once the update completes.
tx_seed_narrow
printf '# managed\nrpool/data/vm-106-disk-0\nrpool/data/vm-107-disk-0\n' > "$TX_ALLOW"
r=$(TX_DATASETS="rpool/data/vm-106-disk-0" TX_KEEP=1 tx_run 0 "")
if [ "$r" = "rc=0" ] && [ -e "$TX_RULE" ] && ! grep -q 'vm-107' "$TX_ALLOW"; then
    ok "tx-widen: narrowing the list completes and drops the removed dataset"
else
    bad "tx-widen: narrowing the list completes and drops the removed dataset" "r=$r"
fi

# An interrupted update leaves the grant switched OFF, which is the fail-closed
# state the review asked for -- and re-running must put it back, not leave the
# host permanently without a grant because the only copy was swept away.
tx_seed_narrow
TX_DATASETS="$tx_wide" TX_KEEP=1 tx_run 0 "" 0 0 "" "zfs-quiesce-allow/backup-test" >/dev/null 2>&1
suspended=0; [ ! -e "$TX_RULE" ] && [ -e "$TX_RULE.zqg-bak" ] && suspended=1
r=$(TX_DATASETS="$tx_wide" TX_KEEP=1 tx_run 0 "")
if [ "$suspended" = 1 ] && [ "$r" = "rc=0" ] && tx_widened; then
    ok "tx-widen: an interrupted update leaves it OFF, and a rerun restores it"
else
    bad "tx-widen: an interrupted update leaves it OFF, and a rerun restores it" \
        "suspended=$suspended r=$r"
fi

# ---- REV-20260731-013: recovery must not re-arm a mixed grant ---------------
#
# The sweep used to rename a parked .zqg-bak rule straight back whenever its
# destination was missing, on the reasoning that it was the only copy left. That
# moved the widening REV-012 closed out of the commit path and into recovery: by
# the time the rule is parked, the PREVIOUS run has already committed the new
# and possibly wider whitelist, so re-arming the old rule activates it against
# that. And if the recovering run then failed during staging, the widened state
# stayed active indefinitely.
#
# The contract now: interrupted means DISABLED, and it stays disabled until a
# run completes. The parked copy is kept, never re-armed.
tx_armed() { [ -e "$TX_RULE" ]; }          # an active, dotless -- therefore sudo-readable -- rule
tx_parked() { [ ! -e "$TX_RULE" ] && [ -e "$TX_RULE.zqg-bak" ]; }

for point in "sbin/zfs-quiesce-helper:po zatwierdzeniu whitelisty" \
             "sudoers.d/zfs-quiesce-backup-test:po whiteliscie i helperze"; do
    at="${point%%:*}"; what="${point#*:}"

    tx_seed_narrow
    TX_DATASETS="$tx_wide" TX_KEEP=1 tx_run 0 "" 0 0 "" "$at" >/dev/null 2>&1
    if tx_parked && ! tx_armed; then
        ok "tx-recover: crash $what leaves the grant parked and disabled"
    else
        bad "tx-recover: crash $what leaves the grant parked and disabled" \
            "rule=$([ -e "$TX_RULE" ] && echo obecna || echo brak) bak=$([ -e "$TX_RULE.zqg-bak" ] && echo jest || echo brak)"
    fi

    # A second enrolment that fails BEFORE commit step 0 -- here at validation,
    # since visudo rejects the staged rule. Nothing may become active.
    r=$(TX_DATASETS="$tx_wide" TX_KEEP=1 tx_run 1 "")
    if [ "$r" != "rc=0" ] && ! tx_armed && ! tx_widened; then
        ok "tx-recover: a failed rerun after crash $what activates nothing"
    else
        bad "tx-recover: a failed rerun after crash $what activates nothing" \
            "r=$r armed=$(tx_armed && echo tak || echo nie) widened=$(tx_widened && echo tak || echo nie)"
    fi

    # A second enrolment that fails during STAGING, one step later than above.
    r=$(TX_DATASETS="$tx_wide" TX_KEEP=1 tx_run 0 "sudoers.d")
    if [ "$r" != "rc=0" ] && ! tx_armed && ! tx_widened; then
        ok "tx-recover: a rerun failing in staging after crash $what activates nothing"
    else
        bad "tx-recover: a rerun failing in staging after crash $what activates nothing" "r=$r"
    fi

    # Only a run that COMPLETES may arm the grant -- and then it must be the new
    # one, not the parked old one.
    r=$(TX_DATASETS="$tx_wide" TX_KEEP=1 tx_run 0 "")
    if [ "$r" = "rc=0" ] && tx_armed && tx_widened && [ ! -e "$TX_RULE.zqg-bak" ]; then
        ok "tx-recover: only a completed rerun re-arms, and with the new grant"
    else
        bad "tx-recover: only a completed rerun re-arms, and with the new grant" "r=$r"
    fi
done

# The sweep must be unreachable from anything read-only. install_quiesce_grant is
# the only caller, and --check-only refuses to combine with --join, so an audit
# cannot reactivate a parked grant. Asserted structurally rather than by running
# deploy.sh, which would provision a host.
callers=$(grep -c '_grant_sweep' "$REPO/deploy.sh")
inside=$(sed -n '/^install_quiesce_grant() {/,/^}$/p' "$REPO/deploy.sh" | grep -c '_grant_sweep')
[ "$callers" = "$inside" ] && ok "tx-recover: nothing outside install_quiesce_grant can sweep" \
                           || bad "tx-recover: nothing outside install_quiesce_grant can sweep" \
                                  "$callers wystąpień w pliku, $inside wewnątrz funkcji"
grep -q 'cannot be combined with --pair/--join' "$REPO/deploy.sh" \
    && ok "tx-recover: --check-only cannot reach the join path at all" \
    || bad "tx-recover: --check-only cannot reach the join path at all" "brak odmowy w deploy.sh"

# §5: installing the sudo package is a host-level side effect that is left in
# place on purpose. Saying nothing about it is what makes the outcome confusing.
r=$(tx_run 0 "" 2 0 "sudoers.d")
if [ "$r" != "rc=0" ] && grep -q "'sudo' package was installed by this run and has been left in place" "$TX/out.log"; then
    ok "tx: a failure after installing sudo says the package was left behind"
else
    bad "tx: a failure after installing sudo says the package was left behind" "$r
      $(cat "$TX/out.log")"
fi
# ...and on a clean host that same failure REMOVES rather than restores.
if grep -q "removed what this run created" "$TX/out.log" && ! grep -q "restored:" "$TX/out.log"; then
    ok "tx: on a clean host the rollback says it REMOVED what it created"
else
    bad "tx: on a clean host the rollback says it REMOVED what it created" "$(cat "$TX/out.log")"
fi

# ---- --allow-quiesce on a LOCAL account (2026-08-01) -----------------------
#
# Until now the only route to a quiesce grant was `--join --allow-quiesce`,
# which grants a JOINING PEER. There was no route at all for this host's own
# delegated account -- so a managed block carrying `quiesce = auto` could be
# run by root and by nobody else, and `migrate-to-account` on metropolis pve1
# refused to move it with no command able to unblock the refusal.
#
# The grant itself is the same function, already covered above. What is new is
# the WIRING, and the two argument-time refusals that replaced the old
# join-only one.

# Both of these exit during argument validation, before deploy.sh touches
# anything -- the same reason the --revoke-quiesce checks above can run the
# real script.
out=$(bash "$REPO/deploy.sh" --allow-quiesce --check-only 2>&1); r=$?
if [ "$r" = 2 ] && case "$out" in *"--check-only"*) true ;; *) false ;; esac; then
    ok "local-quiesce: --allow-quiesce --check-only is refused (an audit installs nothing)"
else
    bad "local-quiesce: --allow-quiesce --check-only is refused (an audit installs nothing)" "rc=$r out=$out"
fi

out=$(bash "$REPO/deploy.sh" --allow-quiesce --pair --peer=192.0.2.1 2>&1); r=$?
if [ "$r" = 2 ] && case "$out" in *"not a --pair option"*) true ;; *) false ;; esac; then
    ok "local-quiesce: --allow-quiesce --pair is refused (the initiator grants nothing)"
else
    bad "local-quiesce: --allow-quiesce --pair is refused (the initiator grants nothing)" "rc=$r out=$out"
fi

# The refusal that used to make the local path impossible must be gone. Kept as
# a named check rather than deleted quietly: it was correct behaviour for a
# script that had only one grant path, and someone reading the diff should see
# that its removal was deliberate.
grep -q 'only means anything together with --join' "$REPO/deploy.sh" \
    && bad "local-quiesce: the join-only refusal is gone" "deploy.sh still refuses --allow-quiesce outside --join" \
    || ok "local-quiesce: the join-only refusal is gone"

# NO DRIFT. The whitelist decides which guests may be frozen; the zfs allow
# loop decides which datasets may be replicated. They must come from ONE list,
# or "may freeze" quietly outgrows "may replicate" -- on pve1 the difference
# between the four vm-disks in the config and their parent is a fifth guest
# nothing backs up. Asserted on the variable, so giving quiesce its own list
# later fails here instead of in production.
phase8h=$(sed -n '/log "Phase 8h: guest quiesce grant"/,/^    echo$/p' "$REPO/deploy.sh")
if printf '%s' "$phase8h" | grep -q 'install_quiesce_grant "\$USERNAME" "\$BACKUP_USER_DATASETS"' \
   && grep -q 'DATASETS=(\$BACKUP_USER_DATASETS)' "$REPO/deploy.sh"; then
    ok "local-quiesce: the whitelist and the zfs allow scope come from one variable"
else
    bad "local-quiesce: the whitelist and the zfs allow scope come from one variable" \
        "Phase 8h: $(printf '%s' "$phase8h" | grep -c install_quiesce_grant) wywolan"
fi

# A plain `bash deploy.sh` maintains every host in the fleet. It must never
# grant privilege nobody asked for, so every call site stays behind the flag.
sites=$(grep -c 'install_quiesce_grant "' "$REPO/deploy.sh")
guarded=$(grep -B4 'install_quiesce_grant "' "$REPO/deploy.sh" | grep -c 'ALLOW_QUIESCE" -eq 1')
if [ "$sites" = 2 ] && [ "$guarded" = 2 ]; then
    ok "local-quiesce: both call sites are behind --allow-quiesce (a bare re-run grants nothing)"
else
    bad "local-quiesce: both call sites are behind --allow-quiesce (a bare re-run grants nothing)" \
        "wywolan=$sites strzezonych=$guarded"
fi

# ...and must not REVOKE one either. A re-run without the flag on a host that
# already has a grant says so and leaves it alone; removing one is
# --revoke-quiesce, a separate deliberate act.
if printf '%s' "$phase8h" | grep -q 'already granted to \$USERNAME (left untouched'; then
    ok "local-quiesce: a re-run without the flag leaves an existing grant alone"
else
    bad "local-quiesce: a re-run without the flag leaves an existing grant alone" "$phase8h"
fi

# Argument time cannot know whether Phase 8 will find an account -- an existing
# one is detected, not named. Silence would read as success.
noacct=$(sed -n '/no delegated account on this host and none requested/,/^elif/p' "$REPO/deploy.sh")
printf '%s' "$noacct" | grep -q 'ALLOW_QUIESCE" -eq 1 \] && warn' \
    && ok "local-quiesce: --allow-quiesce with no account warns instead of doing nothing quietly" \
    || bad "local-quiesce: --allow-quiesce with no account warns instead of doing nothing quietly" "$noacct"

# The whitelist header is read by whoever finds the file and wonders where it
# came from. It may name the FLAG but not one of the two modes -- the local
# grant on pve1 was written with a header telling the reader to run --join.
if grep -q '^        echo "# managed by deploy.sh --allow-quiesce' "$REPO/deploy.sh"; then
    ok "local-quiesce: the whitelist header names the flag, not a mode that may not apply"
else
    bad "local-quiesce: the whitelist header names the flag, not a mode that may not apply" \
        "$(grep -n 'managed by deploy.sh' "$REPO/deploy.sh")"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
