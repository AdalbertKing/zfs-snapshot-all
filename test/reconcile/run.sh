#!/bin/bash
# Scope reconciliation: what the config backs up, against what exists.
#
# The failure this answers is real and from this fleet: VM 104 on pve0 ran with
# ZERO automated snapshots because it was created after the config was written,
# and nothing compared those two facts.
#
# `zfs`, `qm` and `pct` are stubbed, so the whole matrix runs with no root, no
# ZFS and no Proxmox. What is being tested is the COMPARISON, not zfs.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
GEN="${GEN:-$REPO/gen-cron.sh}"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; FAIL=$((FAIL+1)); }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin"
export PATH="$TMPD/bin:$PATH"

# The world: whatever EXISTS is listed here, one dataset per line.
world() { printf '%s\n' "$@" > "$TMPD/world"; }

cat > "$TMPD/bin/zfs" <<'EOF'
#!/bin/bash
# Only the two shapes --reconcile uses.
args="$*"
case "$args" in
    *"-t filesystem,volume"*) cat "$TMPD_WORLD"; exit 0 ;;
esac
target="${@: -1}"
case "$args" in
    *" -r "*) grep -E "^${target}(/|$)" "$TMPD_WORLD"; exit 0 ;;
esac
grep -qx "$target" "$TMPD_WORLD" && { echo "$target"; exit 0; }
exit 1
EOF
chmod +x "$TMPD/bin/zfs"
export TMPD_WORLD="$TMPD/world"

conf() {   # <body>
    { printf '[defaults]\n\thost_label = t\n\tdst        = root@far:b/t\n\n'
      printf '[template:hourly]\n\tsend_schedule = 59 * * * *\n\tprefix        = automated_\n\n'
      printf '%s\n' "$1"; } > "$TMPD/jobs.conf"
}

# conf_own: the case supplies its OWN [defaults], because it is testing what
# dst/src resolve to. conf() prepends a [defaults] of its own, and two of them
# in one file is a duplicate section the generator rightly refuses -- which is
# how five of these cases failed on their first run, for a reason that had
# nothing to do with the classification under test.
conf_own() {
    # The case supplies its OWN [defaults], because dst/src are what it tests.
    # No injection magic: an earlier version tried to sed host_label into the
    # block and produced a sed with a raw newline in the replacement, which
    # fails silently enough that four cases died on "must set host_label".
    { printf '[template:hourly]
	send_schedule = 59 * * * *
	prefix        = automated_

'
      printf '%s
' "$1"; } > "$TMPD/jobs.conf"
}

run() { "$GEN" -c "$TMPD/jobs.conf" --reconcile 2>&1; }
rc()  { "$GEN" -c "$TMPD/jobs.conf" --reconcile >/dev/null 2>&1; echo $?; }

# --- a dataset nobody backs up: the VM 104 shape -----------------------------
world tank tank/covered tank/forgotten
conf '[dataset:tank/covered]
	use_template = hourly'
out="$(run)"
case "$out" in *"UNCOVERED"*tank/forgotten*) ok "an uncovered dataset is reported" ;;
  *) bad "an uncovered dataset is reported" "$out" ;; esac
case "$out" in *tank/covered*) bad "a covered dataset is not listed as uncovered" "$out" ;;
  *) ok "a covered dataset is not listed as uncovered" ;; esac
[ "$(rc)" = 1 ] && ok "an uncovered dataset makes the exit code non-zero" \
                || bad "an uncovered dataset makes the exit code non-zero" "rc=$(rc)"

# A pool root is not a workload and must not be reported forever.
case "$out" in *$'\n  tank\n'*) bad "the pool root is not reported as uncovered" "$out" ;;
  *) ok "the pool root is not reported as uncovered" ;; esac

# --- recursion is what the config DECLARES ----------------------------------
# Under recursive = flat/atomic the children are covered by the parent's job;
# under `no` they are not. This is the whole reason the audit reads the field
# instead of assuming a subtree is covered by its parent.
world tank tank/p tank/p/a tank/p/b
conf '[dataset:tank/p]
	use_template = hourly
	recursive    = flat'
[ "$(rc)" = 0 ] && ok "recursive = flat covers the children" \
                || bad "recursive = flat covers the children" "$(run)"

conf '[dataset:tank/p]
	use_template = hourly
	recursive    = no'
out="$(run)"
case "$out" in *UNCOVERED*tank/p/a*) ok "recursive = no does NOT cover the children" ;;
  *) bad "recursive = no does NOT cover the children" "$out" ;; esac

# --- the config names something ZFS does not have ---------------------------
world tank tank/real
conf '[dataset:tank/real]
	use_template = hourly

[dataset:tank/ghost]
	use_template = hourly'
out="$(run)"
case "$out" in *"DECLARED BUT ABSENT"*tank/ghost*) ok "a job whose source is gone is reported" ;;
  *) bad "a job whose source is gone is reported" "$out" ;; esac
[ "$(rc)" = 1 ] && ok "an absent declared dataset makes the exit code non-zero" \
                || bad "an absent declared dataset makes the exit code non-zero" "rc=$(rc)"

# --- system datasets are MARKED, never silently dropped ----------------------
# The opposite direction from deploy.sh --draft-scope, deliberately: there a
# narrow default is safe, here an omission is the bug being hunted.
world rpool rpool/ROOT rpool/swap rpool/data
conf '[dataset:rpool/data]
	use_template = hourly'
out="$(run)"
case "$out" in *"rpool/ROOT"*) ok "a system dataset is still listed" ;;
  *) bad "a system dataset is still listed" "$out" ;; esac
case "$out" in *UNCOVERED*) bad "a system dataset is not counted as uncovered" "$out" ;;
  *) ok "a system dataset is not counted as uncovered" ;; esac
[ "$(rc)" = 0 ] && ok "system datasets alone leave the exit code zero" \
                || bad "system datasets alone leave the exit code zero" "rc=$(rc)"

# ...but only at depth 1, and only as an exact last component. A workload
# called "swap-backups" or a nested path must never be waved through.
world rpool rpool/data rpool/data/swap rpool/swap-backups
conf '[dataset:rpool/data]
	use_template = hourly
	recursive    = no'
out="$(run)"
case "$out" in *UNCOVERED*rpool/swap-backups*) ok "a name merely containing a system name is uncovered" ;;
  *) bad "a name merely containing a system name is uncovered" "$out" ;; esac
case "$out" in *rpool/data/swap*) ok "a deeper 'swap' is not treated as the system one" ;;
  *) bad "a deeper 'swap' is not treated as the system one" "$out" ;; esac

# --- guest attribution is a LABEL, never a decision --------------------------
cat > "$TMPD/bin/qm" <<'EOF'
#!/bin/bash
case "$1" in
    list)   printf 'VMID NAME\n104 test\n' ;;
    config) printf 'scsi0: local-zfs:vm-104-disk-0,size=32G\nefidisk0: local-zfs:vm-104-disk-1,size=1M\n' ;;
esac
EOF
chmod +x "$TMPD/bin/qm"
world tank tank/vm-104-disk-0 tank/vm-104-disk-1
conf '[dataset:tank/nothing]
	use_template = hourly'
out="$(run)"
case "$out" in *"vm-104-disk-0"*"(qm/104)"*) ok "an uncovered volume is attributed to its guest" ;;
  *) bad "an uncovered volume is attributed to its guest" "$out" ;; esac
# efidisk0/tpmstate0 come from `qm config` like any other disk. Reading disk
# NAMES to decide what mattered is how I once nearly proposed destroying VM
# 107's EFI and TPM state; here the config is the source and the guest id is
# only a label.
case "$out" in *"vm-104-disk-1"*"(qm/104)"*) ok "efidisk-style volumes are attributed too" ;;
  *) bad "efidisk-style volumes are attributed too" "$out" ;; esac


# --- received trees are copies, not unprotected workloads (REV-071 F1) -------
#
# Classified from the CONFIG topology, never from names: a path is not
# "received" because it contains "backup", it is received because a job in this
# file writes there.

# push with a LOCAL dst: the target is <dst>/<source path>
world_push() {
    world tank tank/vm-1 tank/store tank/store/tank tank/store/tank/vm-1 tank/store-other
    conf_own '[defaults]
	host_label = t
	dst = tank/store

[dataset:tank/vm-1]
	use_template = hourly'
}
world_push; out="$(run)"
case "$out" in *"received backups"*"tank/store/tank/vm-1"*) ok "a dataset under the receive root is a received backup" ;;
  *) bad "a dataset under the receive root is a received backup" "$out" ;; esac
# ...and must NOT also appear as uncovered.
unc="$(printf '%s\n' "$out" | awk '/UNCOVERED/{f=1;next} /^$/{f=0} f')"
case "$unc" in *"tank/store/tank/vm-1"*) bad "a received dataset is never reported as UNCOVERED" "$unc" ;;
  *) ok "a received dataset is never reported as UNCOVERED" ;; esac
# The exact boundary: a sibling whose name merely STARTS with the root is not
# under it. tank/store-other is not beneath tank/store.
case "$unc" in *"tank/store-other"*) ok "an adjacent similarly named dataset stays UNCOVERED" ;;
  *) bad "an adjacent similarly named dataset stays UNCOVERED" "$unc" ;; esac
# The root itself is a container the job creates; it is inside the tree.
case "$out" in *"received backups"*"tank/store"*) ok "the receive root itself is classified as received" ;;
  *) bad "the receive root itself is classified as received" "$out" ;; esac

# A REMOTE dst writes on the peer, so nothing local may be classified from it.
# Guessing here is exactly the quiet classification the review forbids.
world tank tank/vm-1 tank/store
conf_own '[defaults]
	host_label = t
	dst = root@peer:tank/store

[dataset:tank/vm-1]
	use_template = hourly'
out="$(run)"
# NOTE: this case is regression cover, NOT evidence. Measured by mutation:
# removing the remote-dst guard leaves it passing, because a root built from
# "root@peer:tank/store" never matches any local dataset name anyway. It pins
# the behaviour; it does not prove the guard.
case "$out" in *UNCOVERED*tank/store*) ok "a remote dst does not classify a local path as received" ;;
  *) bad "a remote dst does not classify a local path as received" "$out" ;; esac

# pull: the local base is the section's own path, the remote name lands beneath.
world tank tank/incoming tank/incoming/far/data
conf_own '[defaults]
	host_label = t

[dataset:tank/incoming]
	use_template = hourly
	src          = root@far:far/data'
out="$(run)"
case "$out" in *"received backups"*"tank/incoming/far/data"*) ok "a pulled dataset is a received backup" ;;
  *) bad "a pulled dataset is a received backup" "$out" ;; esac

# Guest attribution must not ride on a received copy: labelling guest 103's
# BACKUP as (pct/103) is what made the false finding look authoritative.
cat > "$TMPD/bin/pct" <<'EOF'
#!/bin/bash
case "$1" in
    list)   printf 'VMID STATUS\n103 running\n' ;;
    config) printf 'rootfs: local-zfs:subvol-103-disk-0,size=8G\n' ;;
esac
EOF
chmod +x "$TMPD/bin/pct"
world tank tank/subvol-103-disk-0 tank/store tank/store/tank tank/store/tank/subvol-103-disk-0
conf_own '[defaults]
	host_label = t
	dst = tank/store

[dataset:tank/subvol-103-disk-0]
	use_template = hourly'
out="$(run)"
recv="$(printf '%s\n' "$out" | awk '/received backups/{f=1;next} /^$/{f=0} f')"
case "$recv" in *"(pct/103)"*) bad "a received copy is not labelled with the guest" "$recv" ;;
  *) ok "a received copy is not labelled with the guest" ;; esac
rm -f "$TMPD/bin/pct"

# --- system anchor AND its descendants (REV-071 F2) --------------------------
world rpool rpool/ROOT rpool/ROOT/pve-1 rpool/data rpool/data/swap rpool/swap-backups
conf '[dataset:rpool/data]
	use_template = hourly
	recursive    = no'
out="$(run)"
sys="$(printf '%s\n' "$out" | awk '/not counted/{f=1;next} /^$/{f=0} f')"
unc="$(printf '%s\n' "$out" | awk '/UNCOVERED/{f=1;next} /^$/{f=0} f')"
case "$sys" in *"rpool/ROOT/pve-1"*) ok "the boot dataset under the anchor is system-classified" ;;
  *) bad "the boot dataset under the anchor is system-classified" "$sys" ;; esac
case "$sys" in *"rpool/ROOT"*) ok "the anchor itself is still system-classified" ;;
  *) bad "the anchor itself is still system-classified" "$sys" ;; esac
# The boundary the old rule got right and must keep: depth alone is not system.
case "$unc" in *"rpool/data/swap"*) ok "a nested workload named swap stays an ordinary finding" ;;
  *) bad "a nested workload named swap stays an ordinary finding" "$unc" ;; esac
case "$unc" in *"rpool/swap-backups"*) ok "swap-backups stays an ordinary finding" ;;
  *) bad "swap-backups stays an ordinary finding" "$unc" ;; esac

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
