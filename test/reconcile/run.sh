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

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
