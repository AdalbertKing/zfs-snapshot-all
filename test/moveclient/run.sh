#!/bin/bash
# move-to-client: the relationship's machine is replaced, and the COPY stays put.
#
# WHY THIS IS ITS OWN SUITE. Its subject is three pure transforms and one
# refusal, and every one of them is cheap to exercise -- while the verb they
# belong to lives in zfs-backup.sh, whose suite takes a quarter of an hour on a
# developer machine. A guard that is expensive to test is a guard that gets
# tested once.
#
# WHAT IT CAN HONESTLY COVER. The transforms (flags, marker, header) are pure
# text and are covered exactly. The GUID PROOF is covered through stubbed `zfs`
# and `ssh`, which means it is the LOGIC that is asserted -- "a missing snapshot
# refuses, a mismatched guid refuses, a match passes" -- and not that ZFS
# behaves as expected. That distinction is the whole reason this project runs
# labs, and it is written here rather than left for a reader to assume.
#
# Runs anywhere: no root, no ZFS, no network.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZB="${ZB:-$REPO/zfs-backup.sh}"
[ -r "$ZB" ] || { echo "cannot read zfs-backup.sh at $ZB" >&2; exit 1; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
BIN="$TMPD/bin"; mkdir -p "$BIN"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ $# -gt 1 ] && echo "     $2"; FAIL=$((FAIL+1)); }
check() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "want [$2] got [$3]"; fi; }

# The three transforms, lifted out of the file and run directly. Extracted by
# name rather than by sourcing the whole script, which would run its dispatch.
eval "$(sed -n '/^move_reflag() {/,/^}/p'           "$ZB")"
eval "$(sed -n '/^section_retag_client() {/,/^}/p'  "$ZB")"
eval "$(sed -n '/^section_rename_header() {/,/^}/p' "$ZB")"
eval "$(sed -n '/^local_newest_snapshot() {/,/^}/p' "$ZB")"
eval "$(sed -n '/^move_guid_proof() {/,/^}/p'       "$ZB")"

# ---------------------------------------------------------------------------
# 1. THE FLAGS: swap the transport, keep everything else byte for byte
#
# Rewriting the whole field would be easier and would silently drop the
# bandwidth cap and anything else a profile put there. That is the failure this
# asserts against, not the happy path.
# ---------------------------------------------------------------------------
LOAD_KEYFILE=/home/zfsbackup/.ssh/pairing-10.0.0.2_ed25519
LOAD_ALIAS_KH=/home/zfsbackup/.ssh/pairing-10.0.0.2_alias_known_hosts
LOAD_ALIAS=zfs-client-new

OLDF="-K /home/zfsbackup/.ssh/pairing-10.0.0.1_ed25519 -k /home/zfsbackup/.ssh/pairing-10.0.0.1_alias_known_hosts -O HostKeyAlias=zfs-client-old -O GlobalKnownHostsFile=/dev/null -O CheckHostIP=no -b 5000000 -A"
NEWF="$(move_reflag "$OLDF" new)"

case "$NEWF" in
    *"pairing-10.0.0.2_ed25519"*) ok "flags: the key becomes the destination's" ;;
    *) bad "flags: the key becomes the destination's" "$NEWF" ;;
esac
case "$NEWF" in
    *"pairing-10.0.0.2_alias_known_hosts"*) ok "flags: so does the pinned known_hosts" ;;
    *) bad "flags: so does the pinned known_hosts" "$NEWF" ;;
esac
case "$NEWF" in
    *"HostKeyAlias=zfs-client-new"*) ok "flags: and the host-key alias" ;;
    *) bad "flags: and the host-key alias" "$NEWF" ;;
esac
# THE ONE THAT MATTERS. A transport swap that eats the transfer policy is a
# silent change to how much bandwidth the estate uses at 3am.
case "$NEWF" in
    *"-b 5000000"*) ok "flags: the bandwidth cap SURVIVES the swap" ;;
    *) bad "flags: the bandwidth cap SURVIVES the swap" "$NEWF" ;;
esac
case "$NEWF" in
    *"-A"*) ok "flags: ...and so does autotune" ;;
    *) bad "flags: ...and so does autotune" "$NEWF" ;;
esac
case "$NEWF" in
    *"10.0.0.1"*) bad "flags: nothing of the OLD machine is left" "$NEWF" ;;
    *) ok "flags: nothing of the OLD machine is left" ;;
esac
# A config that never carried -L must not grow one here: gen-cron adds it from
# pair_label, and two sources for the same flag is how they come to disagree.
case "$NEWF" in
    *" -L "*) bad "flags: an absent -L is not invented" "$NEWF" ;;
    *) ok "flags: an absent -L is not invented" ;;
esac

# ---------------------------------------------------------------------------
# 2. THE MARKER: re-tagging it IS the hand-over
# ---------------------------------------------------------------------------
CFG="$TMPD/jobs.conf"
mk_cfg() {
    cat > "$CFG" <<'CFGEOF'
[dataset:hdd/copy/old/pool/data]
	# managed-by: zfs-backup.sh client=old
	src          = acct@10.0.0.1:pool/data
	pair_label   = old
[prune:acct@10.0.0.1:pool/data]
	# managed-by: zfs-backup.sh client=old
	ssh_flags    = -K /k -k /kh -O HostKeyAlias=zfs-client-old
	pair_label   = old
[dataset:hdd/somebody/else]
	# managed-by: zfs-backup.sh client=stranger
	src          = acct@10.0.0.9:pool/x
CFGEOF
}

mk_cfg
section_retag_client "$CFG" "[dataset:hdd/copy/old/pool/data]" old new
check "marker: the section is re-tagged" "0" "$?"
check "marker: ...to the new client" "1" "$(grep -c 'client=new' "$CFG")"
# THE NEIGHBOUR. A re-tag that reaches into another section would hand over a
# relationship nobody named.
check "marker: a stranger's section is untouched" "1" "$(grep -c 'client=stranger' "$CFG")"

mk_cfg
section_retag_client "$CFG" "[dataset:hdd/copy/old/pool/data]" nobody new
check "marker: a marker that is not there refuses (3), it does not silently pass" "3" "$?"
# Two, because the fixture has a [dataset:] and a [prune:] both tagged `old`.
check "marker: ...and the file is unchanged" "2" "$(grep -c 'client=old' "$CFG")"

# ---------------------------------------------------------------------------
# 3. THE HEADER: a source-side prune scope carries the peer INSIDE it
# ---------------------------------------------------------------------------
mk_cfg
section_rename_header "$CFG" "[prune:acct@10.0.0.1:pool/data]" "[prune:acct@10.0.0.2:pool/data]"
check "header: a source-side prune scope is renamed" "0" "$?"
check "header: ...to the new peer" "1" "$(grep -c '^\[prune:acct@10.0.0.2:pool/data\]$' "$CFG")"
check "header: ...and the old header is gone" "0" "$(grep -c '^\[prune:acct@10.0.0.1:pool/data\]$' "$CFG")"

mk_cfg
section_rename_header "$CFG" "[prune:nosuch]" "[prune:other]"
check "header: renaming a header that is not there refuses (3)" "3" "$?"

# ---------------------------------------------------------------------------
# 4. THE GUID PROOF -- the whole safety of the verb
#
# Stubbed zfs and ssh, so what is asserted is the LOGIC: a missing snapshot
# refuses, a mismatched guid refuses, a match passes. That ZFS preserves a guid
# across send/recv is a property of ZFS and is proven on a lab, not here.
# ---------------------------------------------------------------------------
cat > "$BIN/zfs" <<'ZSTUB'
#!/bin/sh
case "$*" in
    *"-t snapshot"*)  echo "hdd/copy@auto_2026-08-28" ;;
    *"guid hdd/copy@auto_2026-08-28"*) echo "$LOCAL_GUID" ;;
    *) exit 1 ;;
esac
ZSTUB
chmod +x "$BIN/zfs"
cat > "$BIN/ssh" <<'SSTUB'
#!/bin/sh
[ -n "$REMOTE_GUID" ] && { echo "$REMOTE_GUID"; exit 0; }
exit 0
SSTUB
chmod +x "$BIN/ssh"
export PATH="$BIN:$PATH"
LOAD_SSH_OPTS=(-o BatchMode=yes)

# EXPORTED, and assigned on their own line. `A=1 B=2 out=$(...)` is an
# assignment LIST -- there is no command for the prefix to apply to -- so the
# first version set these in this shell and the stub, a separate process, never
# saw them. Every proof below then failed on "could not read the guid", and one
# of them PASSED anyway: "a DIFFERENT guid refuses" was green because the local
# read had failed, not because a mismatch was detected. R6, exactly.
export LOCAL_GUID REMOTE_GUID
LOCAL_GUID=111; REMOTE_GUID=111
out="$(move_guid_proof hdd/copy pool/data acct@host 2>&1)"; rc=$?
check "proof: a matching guid passes" "0" "$rc"
check "proof: ...and says nothing when it passes" "" "$out"

LOCAL_GUID=111; REMOTE_GUID=222
out="$(move_guid_proof hdd/copy pool/data acct@host 2>&1)"; rc=$?
check "proof: a DIFFERENT guid under the same name refuses" "1" "$rc"
case "$out" in
    *"DIFFERENT snapshot"*) ok "proof: ...and says it is the same name, other data" ;;
    *) bad "proof: ...and says it is the same name, other data" "$out" ;;
esac

LOCAL_GUID=111; REMOTE_GUID=""
out="$(move_guid_proof hdd/copy pool/data acct@host 2>&1)"; rc=$?
check "proof: an absent snapshot on the destination refuses" "1" "$rc"
case "$out" in
    *"has not been recovered there"*) ok "proof: ...and names what is missing" ;;
    *) bad "proof: ...and names what is missing" "$out" ;;
esac

# AN UNREADABLE ANSWER IS A REFUSAL, NEVER A PASS. This is the shape that cost
# the 2026-08-27 restore lab eight defects: a step that cannot ask, and reads
# silence as "fine".
cat > "$BIN/zfs" <<'ZSTUB2'
#!/bin/sh
exit 1
ZSTUB2
chmod +x "$BIN/zfs"
out="$(move_guid_proof hdd/copy pool/data acct@host 2>&1)"; rc=$?
check "proof: a copy whose snapshots cannot be read refuses" "1" "$rc"

# ---------------------------------------------------------------------------
# 5. THE REFUSALS the verb makes before it touches anything
# ---------------------------------------------------------------------------
zb() { bash "$ZB" move-to-client "$@" 2>&1; }

case "$(zb)" in *"uzycie:"*) ok "cli: no arguments prints the usage" ;; *) bad "cli: no arguments prints the usage" ;; esac
case "$(zb a)" in *"uzycie:"*) ok "cli: one relationship is not a move" ;; *) bad "cli: one relationship is not a move" ;; esac
case "$(zb a a)" in *"onto itself"*) ok "cli: a relationship onto itself is refused" ;; *) bad "cli: a relationship onto itself is refused" ;; esac
case "$(zb a b c)" in *"Got a third"*) ok "cli: a third address is refused" ;; *) bad "cli: a third address is refused" ;; esac
case "$(zb a b --nope)" in *"unknown option"*) ok "cli: an unknown option is refused" ;; *) bad "cli: an unknown option is refused" ;; esac
case "$(CLIENTS_DIR=$TMPD/none zb aaa bbb)" in
    *"no relationship record for 'aaa'"*) ok "cli: an unknown source relationship is refused by name" ;;
    *) bad "cli: an unknown source relationship is refused by name" ;;
esac

# ---------------------------------------------------------------------------
# 6. REV-20260829-123 F1 -- the ownership records must be PREPARED AND PROVEN
#    before a single live byte is replaced.
#
# The verb used to install the config and both crontabs first and append to the
# records afterwards, with a failed append reduced to a warning. A read-only
# records directory would then leave the new sections installed while the
# destination's record said it owned nothing -- and the command carried on to
# pause the old relationship and print success over it.
#
# Exercised through the real verb with an UNWRITABLE records directory, which
# is the cheapest honest injection: it makes the preparation fail, and the
# assertion is that nothing downstream ran.
# ---------------------------------------------------------------------------
RO="$TMPD/ro"; mkdir -p "$RO"
cat > "$RO/aaa.conf" <<'RECEOF'
CLIENT_NAME=aaa
CRON_CONFIG=/nonexistent/jobs.conf
RECEOF
cp "$RO/aaa.conf" "$RO/bbb.conf"
chmod 0555 "$RO" 2>/dev/null || :

# THESE FOUR DO NOT DISCRIMINATE against the reviewed SHA, and saying so is the
# point. On 3a78b1dc the verb also refuses here -- earlier, at config
# resolution, for a different reason -- so they pass on both. They still pin
# something worth pinning (a refusal never pauses and never prints success),
# but the byte-restoration proof the review asks for needs the verb driven all
# the way to publication, which needs a real config, real records, a real
# crontab and the account's gen-cron. That is a lab, and it is run as one; see
# the manual obligation moveclient-live.
#
# The two assertions after them DO discriminate, and they are the ordering
# itself -- which is what criterion 1 actually asks for.
out="$(CLIENTS_DIR="$RO" zb aaa bbb --yes)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "F1: a move that cannot prepare its records refuses"
else bad "F1: a move that cannot prepare its records refuses" "rc=0"; fi
case "$out" in
    *"nothing has been changed"*|*"no readable installed config"*)
        ok "F1: ...and says nothing was changed" ;;
    *)  bad "F1: ...and says nothing was changed" "$(printf '%s' "$out" | tail -2)" ;;
esac
# THE ONE THAT MATTERS: whatever it refused on, it must not have gone on to
# pause the relationship or announce success.
case "$out" in
    *"PAUSED"*) bad "F1: ...and did NOT pause the old relationship" "it paused" ;;
    *) ok "F1: ...and did NOT pause the old relationship" ;;
esac
case "$out" in
    *">>> done."*) bad "F1: ...and did NOT print the successful final state" "it did" ;;
    *) ok "F1: ...and did NOT print the successful final state" ;;
esac
chmod 0755 "$RO" 2>/dev/null || :

# STRUCTURAL, and it is what the reviewer's criterion 1 actually asks for: the
# record contents are written before atomic_replace_and_install is called at
# all. Asserted on the source, because no stub can prove an ordering that only
# shows itself when a disk fills up mid-command.
_seq="$(awk '/^cmd_move_to_client\(\)/,/^}/' "$ZB")"
_prep=$(printf '%s
' "$_seq" | grep -n 'to_tmp="$(mktemp' | head -1 | cut -d: -f1)
_inst=$(printf '%s
' "$_seq" | grep -n 'atomic_replace_and_install' | head -1 | cut -d: -f1)
if [ -n "$_prep" ] && [ -n "$_inst" ] && [ "$_prep" -lt "$_inst" ]; then
    ok "F1: the records are prepared BEFORE the config is replaced"
else
    bad "F1: the records are prepared BEFORE the config is replaced" "prepare=$_prep install=$_inst"
fi
# ...and a failed rename rolls the config and both records back rather than
# leaving the install standing.
case "$_seq" in
    *"NOTHING was moved"*) ok "F1: a failed record rename rolls everything back" ;;
    *) bad "F1: a failed record rename rolls everything back" "no rollback path found" ;;
esac

# ---------------------------------------------------------------------------
# A PAUSED DESTINATION WOULD RECEIVE A SCHEDULE THAT DOES NOT RUN
#
# Found on the moveclient-live lab, 2026-08-29, and only because the lab ran the
# verb TWICE. The first move pauses its source; move back later and that source
# is the destination, still paused. It takes the sections, the crontab installs,
# the verb prints "'alfa' carries the schedule" -- and every job carrying
# '-L alfa' exits SKIPPED, because the pause is a property of the label they now
# hold. Measured on pve9: snapget answered
#
#     SKIPPED: relationship alfa is paused (resume: zfs-backup.sh resume-client alfa)
#
# on the very line the hand-over had just installed. The tool announced a
# successful hand-over of an inert schedule -- false health, announced as
# success, which is the shape this package keeps finding.
#
# Refused rather than resumed: a paused destination is the NORMAL state while a
# machine is being restored onto, so lifting it silently would be the tool
# overruling the transaction the administrator opened.
# ---------------------------------------------------------------------------
PAUSEDIR="$TMPD/rels"
mkdir -p "$PAUSEDIR/bbb"
: > "$PAUSEDIR/bbb/paused"
mkdir -p "$TMPD/cli"
printf 'CLIENT_NAME=aaa\nCRON_CONFIG=/nonexistent/jobs.conf\n' > "$TMPD/cli/aaa.conf"
printf 'CLIENT_NAME=bbb\nCRON_CONFIG=/nonexistent/jobs.conf\n' > "$TMPD/cli/bbb.conf"

out="$(CLIENTS_DIR="$TMPD/cli" RELATIONSHIPS_DIR="$PAUSEDIR" zb aaa bbb --yes)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "paused destination: the move refuses"
else bad "paused destination: the move refuses" "rc=0"; fi
case "$out" in
    *"is PAUSED"*) ok "PAUSED DESTINATION: NAMED AS THE REASON" ;;
    *) bad "PAUSED DESTINATION: NAMED AS THE REASON" "$(printf '%s' "$out" | tail -1)" ;;
esac
case "$out" in
    *"exits SKIPPED"*) ok "paused destination: ...saying what the handed schedule would do" ;;
    *) bad "paused destination: ...saying what the handed schedule would do" "$(printf '%s' "$out" | tail -1)" ;;
esac
case "$out" in
    *"resume-client bbb"*) ok "paused destination: ...and naming the command that ends it" ;;
    *) bad "paused destination: ...and naming the command that ends it" "$(printf '%s' "$out" | tail -1)" ;;
esac
# THE REFUSAL MUST COME BEFORE ANYTHING ELSE IS JUDGED. These records point at a
# config that does not exist, so a build without this check refuses too -- for
# the WRONG reason. Asserting the reason is what makes this discriminate.
case "$out" in
    *"no readable installed config"*) bad "paused destination: refused for the pause, not for the config" "$out" ;;
    *) ok "paused destination: refused for the pause, not for the config" ;;
esac

# THE NEGATIVE SIDE: an unpaused destination gets past this check and fails
# later, on its own merits. Without it the assertions above would also pass
# against a build that refused every move.
rm -f "$PAUSEDIR/bbb/paused"
out="$(CLIENTS_DIR="$TMPD/cli" RELATIONSHIPS_DIR="$PAUSEDIR" zb aaa bbb --yes)"
case "$out" in
    *"is PAUSED"*) bad "unpaused destination: NOT refused for a pause" "$out" ;;
    *) ok "unpaused destination: NOT refused for a pause" ;;
esac

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
