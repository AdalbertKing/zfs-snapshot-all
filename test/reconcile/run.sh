#!/bin/bash
# Scope reconciliation: what the config backs up, against what exists.
#
# The failure this answers is real and from this fleet: VM 104 on pve0 ran with
# ZERO automated snapshots because it was created after the config was written,
# and nothing compared those two facts.
#
# `zfs`, `qm` and `pct` are stubbed, so the whole matrix runs with no root, no
# ZFS and no Proxmox. What is being tested is the COMPARISON, not zfs.
# Sweep result, 2026-08-08 (the debt named in the REV-20260808-072 response).
#
# I said I would not claim that the pull contract was the ONLY config-semantic
# rule living behind the --reconcile branch without establishing it. Established:
#
#   emit_send                2 refusals  -> both now in validate_transfer_semantics
#   emit_inline_prune        0
#   emit_prune_sections      0
#   emit_gfs_prune_sections  0
#   emit_bookmark_prune      0
#   emit_monitor             0
#   generate_block           0
#   install_crontab         11  -> all environment/state (flock, crontab, lock
#                                  dir, symlink, mktemp, crontab read/write),
#                                  none a config-validity rule. --reconcile
#                                  neither locks nor installs, so it correctly
#                                  does not reach them.
#
# The count was taken with emit_send as a POSITIVE CONTROL: a sweep that reports
# zero everywhere is indistinguishable from a sweep whose pattern matched
# nothing, and that has happened here more than once.
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
# Only the shapes --reconcile uses. The world file is "<dataset> [<own bytes>]",
# so EVERY branch must take column 1 only -- an earlier version stripped it in
# some branches and not others, and the names that reached the caller carried a
# trailing " 0", so no lookup ever matched.
names() { awk '{print $1}' "$TMPD_WORLD"; }
args="$*"
target="${@: -1}"
case "$args" in
    *usedbydataset*)
        awk -v d="$target" '$1==d { print ($2==""?0:$2); f=1 } END{ if(!f) print 0 }' "$TMPD_WORLD"
        exit 0 ;;
    *"-t filesystem,volume"*) names; exit 0 ;;
esac
case "$args" in
    *" -r "*) names | grep -E "^${target}(/|$)"; exit 0 ;;
esac
names | grep -qx "$target" && { echo "$target"; exit 0; }
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

# pull: a VALID pull section's own path ALREADY ends with the literal remote
# dataset name -- emit_send enforces that -- so the receive root is the section
# dataset itself.
#
# The first version of this case used [dataset:tank/incoming] with
# src=root@far:far/data, which normal cron generation REJECTS. It passed only
# because --reconcile returns before emit_send validates the suffix: a test
# whose config cannot exist proves nothing (REV-20260808-071, direction 3).
world tank tank/incoming tank/incoming/far/data tank/incoming/far/data/sub
conf_own '[defaults]
	host_label = t

[dataset:tank/incoming/far/data]
	use_template = hourly
	src          = root@far:far/data'
out="$(run)"
recv="$(printf '%s
' "$out" | awk '/received backups/{f=1;next} /^$/{f=0} f')"
case "$recv" in *"tank/incoming/far/data"*) ok "a valid pull section IS the receive root" ;;
  *) bad "a valid pull section IS the receive root" "$out" ;; esac
case "$recv" in *"tank/incoming/far/data/sub"*) ok "and its subtree is received too" ;;
  *) bad "and its subtree is received too" "$recv" ;; esac
# A pull destination is where a copy LANDS. Counting it as source-side coverage
# is backwards, and the covered count must not include it.
case "$out" in *"covered by a send job: 0 dataset(s)"*) ok "a pull destination is not source-side coverage" ;;
  *) bad "a pull destination is not source-side coverage" "$(printf '%s
' "$out" | grep covered)" ;; esac

# --- coverage comes from generated SEND entities, not from sections ----------
# A section that resolves no send schedule is not backed up, whatever else it
# carries. Calling it covered is the silence the whole tool exists to remove.
world tank tank/pruned
conf_own '[defaults]
	host_label = t
	dst        = root@far:b/t

[template:pruneonly]
	prune_schedule = 7 4 * * *
	prefix         = automated_
	retain         = -D7
	pattern        = automated_daily

[dataset:tank/pruned]
	use_template = pruneonly'
out="$(run)"
case "$out" in *UNCOVERED*tank/pruned*) ok "a prune-only dataset is NOT counted as covered" ;;
  *) bad "a prune-only dataset is NOT counted as covered" "$out" ;; esac

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


# --- rejection parity: the audit must not accept what generation refuses -----
#
# REV-20260808-072 F1. The pull suffix contract lived only inside emit_send,
# which --reconcile never reaches, so the audit could certify a config the
# generator refuses to execute. A checker more permissive than the thing it
# checks is worse than no checker: it issues a clean bill of health for
# something that cannot run.
#
# The malformed shape is the one that exposed it: the local path does not end
# with the literal remote dataset name.
conf_own '[defaults]
	host_label = t

[dataset:tank/incoming]
	use_template = hourly
	src          = root@far:far/data'
world tank tank/incoming

"$GEN" -c "$TMPD/jobs.conf" >/dev/null 2>&1
gen_rc=$?
"$GEN" -c "$TMPD/jobs.conf" --reconcile >/dev/null 2>&1
rec_rc=$?
[ "$gen_rc" -ne 0 ] && ok "normal generation rejects the malformed pull" \
                    || bad "normal generation rejects the malformed pull" "rc=$gen_rc"
[ "$rec_rc" -ne 0 ] && ok "--reconcile rejects it too (same boundary)" \
                    || bad "--reconcile rejects it too (same boundary)" "rc=$rec_rc"
# The refusal must say WHY, not merely exit non-zero -- both commands run in
# cron and their output is all an operator gets.
out="$("$GEN" -c "$TMPD/jobs.conf" --reconcile 2>&1)"
case "$out" in *"must end with the remote dataset name"*) ok "--reconcile names the contract it refused on" ;;
  *) bad "--reconcile names the contract it refused on" "$out" ;; esac


# --- structural containers (owner decision, 2026-08-08) ---------------------
#
# A parent whose children are all covered and which holds no data of its own is
# the case snapsend's -S flag is documented for: "rpool/data holds no data of
# its own and exists only to group vm-*-disk-* beneath it". Alerting on it,
# when backing the children up individually IS the design, is noise.
#
# Suppressed means not counted and not alerted -- never invisible.
world tank "tank/store 0" "tank/store/a 0" "tank/store/b 0"
conf '[dataset:tank/store/a]
	use_template = hourly

[dataset:tank/store/b]
	use_template = hourly'
out="$(run)"
case "$out" in *"structural containers"*"tank/store"*) ok "a parent whose children are all covered is a container" ;;
  *) bad "a parent whose children are all covered is a container" "$out" ;; esac
unc="$(printf '%s\n' "$out" | awk '/UNCOVERED/{f=1;next} /^$/{f=0} f')"
case "$unc" in *tank/store*) bad "a container is not counted as uncovered" "$unc" ;;
  *) ok "a container is not counted as uncovered" ;; esac
[ "$(rc)" = 0 ] && ok "containers alone leave the exit code zero" || bad "containers alone leave the exit code zero" "rc=$(rc)"

# GUARD 1: one uncovered child and it is not a solved container any more.
world tank "tank/store 0" "tank/store/a 0" "tank/store/b 0"
conf '[dataset:tank/store/a]
	use_template = hourly'
out="$(run)"
unc="$(printf '%s\n' "$out" | awk '/UNCOVERED/{f=1;next} /^$/{f=0} f')"
case "$unc" in *"tank/store"*) ok "a parent with an uncovered child stays a finding" ;;
  *) bad "a parent with an uncovered child stays a finding" "$out" ;; esac

# GUARD 2: it must hold no data OF ITS OWN. Files put directly in the parent
# have no backup, and suppressing that is exactly the blindness being avoided.
world tank "tank/store 50000000" "tank/store/a 0"
conf '[dataset:tank/store/a]
	use_template = hourly'
out="$(run)"
unc="$(printf '%s\n' "$out" | awk '/UNCOVERED/{f=1;next} /^$/{f=0} f')"
case "$unc" in *"tank/store"*) ok "a parent holding its own data is NOT suppressed" ;;
  *) bad "a parent holding its own data is NOT suppressed" "$out" ;; esac

# A leaf is never a container: no children means nothing was solved.
world tank "tank/lonely 0"
conf '[dataset:tank/other]
	use_template = hourly'
out="$(run)"
case "$out" in *UNCOVERED*tank/lonely*) ok "a childless dataset is never a container" ;;
  *) bad "a childless dataset is never a container" "$out" ;; esac

# --- -S and -X change WHICH datasets a run touches ---------------------------
# Expanding recursion with a plain `zfs list -r` claims coverage for a parent
# the engine skips (-S) or a child it filters out (-X). That is a FALSE
# NEGATIVE -- it hides an unprotected dataset -- and it is the direction that
# matters. Latent rather than live: no config in this fleet uses either flag.
world tank "tank/p 9000000" "tank/p/a 0" "tank/p/b 0"
conf '[dataset:tank/p]
	use_template = hourly
	recursive    = flat
	flags        = -S'
out="$(run)"
unc="$(printf '%s\n' "$out" | awk '/UNCOVERED/{f=1;next} /^$/{f=0} f')"
case "$unc" in *"tank/p"*) ok "-S: the skipped parent is NOT counted as covered" ;;
  *) bad "-S: the skipped parent is NOT counted as covered" "$out" ;; esac

world tank "tank/p 0" "tank/p/keep 0" "tank/p/drop 0"
conf '[dataset:tank/p]
	use_template = hourly
	recursive    = flat
	flags        = -X drop'
out="$(run)"
unc="$(printf '%s\n' "$out" | awk '/UNCOVERED/{f=1;next} /^$/{f=0} f')"
case "$unc" in *"tank/p/drop"*) ok "-X: the excluded child is NOT counted as covered" ;;
  *) bad "-X: the excluded child is NOT counted as covered" "$out" ;; esac
case "$unc" in *"tank/p/keep"*) bad "-X: the kept child is still covered" "$unc" ;;
  *) ok "-X: the kept child is still covered" ;; esac


# --- clustered -S / -X spellings (REV-20260808-074 follow-up) ----------------
#
# The engine uses getopts, so `-eS` is -e plus -S and `-SX drop$` is -S plus -X
# taking the next token. Reconciliation had its own token walker recognising
# only -S, -X and -Xpat as whole tokens, so those legal spellings were misread
# and the skipped parent or excluded child came back COVERED -- a false green.
#
# Same defect REV-069 fixed in the engines' pre-pass, hand-written a second time
# in a different file. The fix is one shared grammar, not a longer list of
# spellings.
unc_of() {   # -> the UNCOVERED block for the current config
    run | awk '/UNCOVERED/{f=1;next} /^$/{f=0} f'
}

world tank "tank/p 9000000" "tank/p/a 0" "tank/p/b 0"
conf '[dataset:tank/p]
	use_template = hourly
	recursive    = flat
	flags        = -eS'
case "$(unc_of)" in *"tank/p"*) ok "-eS: clustered skip-parent is honoured" ;;
  *) bad "-eS: clustered skip-parent is honoured" "$(unc_of)" ;; esac

world tank "tank/p 9000000" "tank/p/keep 0" "tank/p/drop 0"
conf '[dataset:tank/p]
	use_template = hourly
	recursive    = flat
	flags        = -SX drop$'
u="$(unc_of)"
case "$u" in *"tank/p/drop"*) ok "-SX <pat>: the cluster gives -S AND -X with the next token" ;;
  *) bad "-SX <pat>: the cluster gives -S AND -X with the next token" "$u" ;; esac
case "$u" in *"tank/p"$'\n'*|*"tank/p") ok "-SX <pat>: the parent is skipped too" ;;
  *) bad "-SX <pat>: the parent is skipped too" "$u" ;; esac
case "$u" in *"tank/p/keep"*) bad "-SX <pat>: the non-matching child stays covered" "$u" ;;
  *) ok "-SX <pat>: the non-matching child stays covered" ;; esac

# Argument boundary: the S inside an -X ARGUMENT is data, not skip-parent.
# Getting this wrong is the mirror image -- it would skip a parent nobody asked
# to skip, and report it as unprotected.
world tank "tank/p 0" "tank/p/fooS 0" "tank/p/other 0"
conf '[dataset:tank/p]
	use_template = hourly
	recursive    = flat
	flags        = -X fooS'
u="$(unc_of)"
case "$u" in *"tank/p/fooS"*) ok "-X fooS: the excluded child is uncovered" ;;
  *) bad "-X fooS: the excluded child is uncovered" "$u" ;; esac
case "$u" in *"tank/p"$'\n'*|*"tank/p") bad "-X fooS: S inside the ARGUMENT is not skip-parent" "$u" ;;
  *) ok "-X fooS: S inside the ARGUMENT is not skip-parent" ;; esac

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
