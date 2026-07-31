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

tx_run() {   # tx_run <visudo-rc> <install-fails-on> [apt-rc]
    local vrc="$1" failon="$2" aptrc="${3:-0}"
    rm -rf "$TX/root"; mkdir -p "$TX/root/etc/sudoers.d" "$TX/root/usr/local/sbin"
    # The dependency case has to be a genuine absence: with a visudo stub on
    # PATH the install branch is never reached and the case would pass while
    # testing nothing. (MSYS has neither sudo nor visudo of its own.)
    rm -f "$TX/bin/visudo" "$TX/bin/sudo"
    if [ "$aptrc" -eq 0 ]; then
        printf '#!/bin/sh
exit %s
' "$vrc" > "$TX/bin/visudo"
        printf '#!/bin/sh
exit 0
' > "$TX/bin/sudo"
        chmod +x "$TX/bin/visudo" "$TX/bin/sudo"
    fi
    # `install` fails only for the named target, so each stage can be broken in
    # isolation while the others behave normally.
    # Strips -o/-g: this box has no 'root' user, so real ownership flags fail for
    # reasons that have nothing to do with what is being tested. Fails only for
    # the named target, so each stage can be broken in isolation.
    cat > "$TX/bin/install" <<EOF
#!/bin/bash
FAILON='$failon'
args=()
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o|-g) shift 2 ;;
        *) if [ -n "\$FAILON" ]; then case "\$1" in *\$FAILON*) exit 1 ;; esac; fi
           args+=("\$1"); shift ;;
    esac
done
exec /usr/bin/install "\${args[@]}"
EOF
    chmod +x "$TX/bin/install"
    (
        PATH="$TX/bin:$PATH"
        REPO_DIR="$REPO"
        log()  { echo ">>> $*"; }
        warn() { echo "!!! $*" >&2; }
        apt_install_with_fallback() { return "$aptrc"; }
        # shellcheck disable=SC1090
        . "$TX/fn.sh"
        # Redirect the three absolute paths into the sandbox.
        eval "$(declare -f install_quiesce_grant             | sed -e "s#/usr/local/sbin/zfs-quiesce-helper#$TX/root/usr/local/sbin/zfs-quiesce-helper#g"                   -e "s#/etc/zfs-quiesce-allow#$TX/root/etc/zfs-quiesce-allow#g"                   -e "s#/etc/sudoers.d#$TX/root/etc/sudoers.d#g")"
        install_quiesce_grant backup-test "rpool/data" >/dev/null 2>&1
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
r=$(tx_run 0 "sudoers.d")
[ "$r" != "rc=0" ] && [ "$(tx_orphans)" = 0 ]     && ok "tx: a failed rule install rolls the whitelist back too"     || bad "tx: a failed rule install rolls the whitelist back too" "$r orphans=$(tx_orphans)"

# And a retry after a failure must succeed cleanly rather than trip over
# leftovers from the failed attempt.
tx_run 1 "" >/dev/null
r=$(tx_run 0 "")
[ "$r" = "rc=0" ] && ok "tx: a retry after a failure succeeds cleanly"                   || bad "tx: a retry after a failure succeeds cleanly" "$r"

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
