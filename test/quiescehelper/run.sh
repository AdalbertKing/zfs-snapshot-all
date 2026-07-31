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
# GetWriterStatus / VSS_WRITER_STATE anywhere in it). So a dead SqlServerWriter
# yields a snapshot that reports success and is not application-consistent.
# This verb is the only way to see it -- and its classification has to keep
# "Waiting for completion" OUT of the failure count, or it would alert after
# every successful backup and get switched off.
cat > "$VSSOUT" <<'EOF'
{
   "exitcode" : 0,
   "out-data" : "Writer name: 'SqlServerWriter'\r\n   State: [10] Failed\r\n   Last error: Timed out\r\n\r\nWriter name: 'System Writer'\r\n   State: [5] Waiting for completion\r\n   Last error: No error\r\n\r\nWriter name: 'WMI Writer'\r\n   State: [1] Stable\r\n   Last error: No error\r\n"
}
EOF
out=$(run writers 100)
case "$out" in
    *"writer=SqlServerWriter"*"class=FAILED"*) ok "writers flags a failed writer" ;;
    *) bad "writers flags a failed writer" "$out" ;;
esac
case "$out" in
    *"writer=System Writer"*"class=in-progress"*) ok "writers does NOT call a waiting writer failed" ;;
    *) bad "writers does NOT call a waiting writer failed" "$out" ;;
esac
case "$out" in
    *"WRITERS total=3 failed=1 in_progress=1"*) ok "writers summary counts only real failures" ;;
    *) bad "writers summary counts only real failures" "$out" ;;
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

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
