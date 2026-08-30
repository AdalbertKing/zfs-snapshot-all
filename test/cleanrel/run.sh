#!/bin/bash
# Tests for clean-relationships.sh -- the relationship-trace auditor and purger.
#
# Every case below is a shape MEASURED on a real host during the 2026-08-20
# teardown, not an invented one. That is the point of the file: the tool exists
# because a hand cleanup missed things, so its tests are the things that were
# missed.
#
# Fully sandboxed: every state directory is redirected into a temp tree, which
# is also what relaxes the tool's own root requirement (that check guards the
# DEFAULT system paths, and none of them are in play here). Nothing in this
# suite can touch /etc, /var/lib, /root or an account.
#
#   ./test/cleanrel/run.sh
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
CR="${CR:-$REPO/clean-relationships.sh}"
[ -r "$CR" ] || { echo "cannot read clean-relationships.sh at $CR" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# build_tree <dir> -- the real taxonomy, in one place so every case starts from
# the same measured shape.
build_tree() {
    local T="$1"
    rm -rf "$T"; mkdir -p "$T/clients" "$T/peers" "$T/rel" "$T/keys" "$T/pairing" "$T/home"

    # LIVE collector relationship: active record, all four key files present.
    printf 'CLIENT_NAME=live-one\nPEER_HOST=10.0.0.8\nSTATE=pending_enroll\nSTATE=active\n' \
        > "$T/clients/live-one.conf"
    printf 'PEER_SAVED_ACCOUNT=zfsbackup-collector\n' > "$T/peers/10.0.0.8.conf"
    touch "$T/keys/10.0.0.8_ed25519" "$T/keys/10.0.0.8_ed25519.pub" \
          "$T/keys/10.0.0.8_known_hosts" "$T/keys/10.0.0.8_alias_known_hosts"

    # DEAD collector relationship. remove-client already ran: it took the cron
    # lines, peers/<addr>.conf and three of the four key files -- and left the
    # STATE=removed record, _alias_known_hosts (the one the cron lines used for
    # -k) and the join scaffolding.
    printf 'CLIENT_NAME=dead-one\nPEER_HOST=10.0.0.99\nSTATE=active\nSTATE=removed\n' \
        > "$T/clients/dead-one.conf"
    touch "$T/keys/10.0.0.99_alias_known_hosts" \
          "$T/pairing/10.0.0.99.conf.suggested" "$T/pairing/me-to-10.0.0.99.tgz"

    # SOURCE side, label-keyed: the manifest remove-client does NOT remove,
    # because it removes the ADDRESS-keyed one. Plus its scope and gate state.
    printf 'PEER_JOIN_ACCOUNT="zfsbackup-oldpeer"\n' > "$T/peers/oldpeer.conf"
    touch "$T/peers/oldpeer.scope" "$T/peers/oldpeer.scope.sha256"
    mkdir -p "$T/rel/oldpeer"

    # A bare gate directory with nothing else at all -- measured on the 11.x
    # pve1 host, left by a teardown that cleaned everything except this.
    mkdir -p "$T/rel/barepeer"

    # The host's OWN delegated backup account. Not a relationship, and removing
    # it would take this host's backups with it.
    mkdir -p "$T/home/zfsbackup"
}

run_cr() {   # <tree> <args...> -- echoes output, returns rc
    local T="$1"; shift
    CLIENTS_DIR="$T/clients" PEER_STATE_DIR="$T/peers" REL_STATE_DIR="$T/rel" \
    PEER_KEY_DIR="$T/keys" PAIRING_DIR="$T/pairing" HOME_ROOT="$T/home" \
    TOMBSTONE_DIR="$T/removed" ZFS_BIN="${ZFS_BIN:-zfs}" \
    DEPLOY=/nonexistent ZFSBACKUP=/nonexistent \
    bash "$CR" "$@" 2>&1
}

# ---------------------------------------------------------------------------
# 1. The audit finds every family, keyed the three different ways they are
#    actually stored. This is the property the hand cleanup lacked.
# ---------------------------------------------------------------------------
T="$WORK/t1"; build_tree "$T"
out=$(run_cr "$T"); rc=$?
if [ "$rc" -eq 3 ] \
   && grep -q 'live-one  \[LIVE\]'   <<<"$out" \
   && grep -q 'dead-one  \[ORPHAN\]' <<<"$out" \
   && grep -q 'oldpeer  \[ORPHAN\]'  <<<"$out" \
   && grep -q 'barepeer  \[ORPHAN\]' <<<"$out"; then
    ok "audit classifies all four shapes, and exits 3 because orphans exist"
else
    bad "audit classifies all four shapes, and exits 3 because orphans exist" "rc=$rc" "$out"
fi

# 2. The label-keyed manifest is the one remove-client leaves behind. If the
#    audit misses it, the tool has not solved the problem it was written for.
if grep -q "peers/oldpeer.conf" <<<"$out" && grep -q "rel/oldpeer" <<<"$out"; then
    ok "audit sees the LABEL-keyed manifest and gate dir that remove-client leaves"
else
    bad "audit sees the LABEL-keyed manifest and gate dir that remove-client leaves" "$out"
fi

# 3. _alias_known_hosts is the single key file that survives remove-client, and
#    it is the one the generated cron lines pass to -k.
if grep -q "10.0.0.99_alias_known_hosts" <<<"$out"; then
    ok "audit sees the surviving _alias_known_hosts of a removed relationship"
else
    bad "audit sees the surviving _alias_known_hosts of a removed relationship" "$out"
fi

# 4. The host's own delegated account is not a relationship. Reporting it would
#    invite an operator to delete the account their backups run as.
if ! grep -qE '^  zfsbackup  ' <<<"$out"; then
    ok "the host's own 'zfsbackup' account is not reported as a relationship"
else
    bad "the host's own 'zfsbackup' account is not reported as a relationship" "$out"
fi

# ---------------------------------------------------------------------------
# 5. Read-only by default. An audit that can change something is not an audit.
# ---------------------------------------------------------------------------
T="$WORK/t5"; build_tree "$T"
before=$(find "$T" | sort | md5sum)
run_cr "$T" >/dev/null
after=$(find "$T" | sort | md5sum)
if [ "$before" = "$after" ]; then
    ok "the default run changes nothing on disk"
else
    bad "the default run changes nothing on disk" "tree differs after an audit"
fi

# 6. --purge without --yes is still read-only, and says so.
T="$WORK/t6"; build_tree "$T"
before=$(find "$T" | sort | md5sum)
out=$(run_cr "$T" --purge-orphans)
after=$(find "$T" | sort | md5sum)
if [ "$before" = "$after" ] && grep -q 'Nothing was changed' <<<"$out"; then
    ok "--purge-orphans without --yes changes nothing and says so"
else
    bad "--purge-orphans without --yes changes nothing and says so" "$out"
fi

# ---------------------------------------------------------------------------
# 7. A LIVE relationship is refused. This is the one that matters: calling a
#    live relationship dead deletes a working backup's credentials.
# ---------------------------------------------------------------------------
T="$WORK/t7"; build_tree "$T"
out=$(run_cr "$T" --purge=live-one --yes)
if grep -qi 'refusing' <<<"$out" && [ -e "$T/clients/live-one.conf" ] \
   && [ -e "$T/keys/10.0.0.8_ed25519" ]; then
    ok "an explicit --purge of a LIVE relationship is refused, files intact"
else
    bad "an explicit --purge of a LIVE relationship is refused, files intact" "$out"
fi

# 8. ...and --purge-orphans never reaches it either.
T="$WORK/t8"; build_tree "$T"
run_cr "$T" --purge-orphans --yes >/dev/null
if [ -e "$T/clients/live-one.conf" ] && [ -e "$T/keys/10.0.0.8_ed25519" ] \
   && [ -e "$T/keys/10.0.0.8_alias_known_hosts" ] && [ -e "$T/peers/10.0.0.8.conf" ]; then
    ok "--purge-orphans leaves every artefact of the LIVE relationship alone"
else
    bad "--purge-orphans leaves every artefact of the LIVE relationship alone" \
        "surviving: $(ls "$T/clients" "$T/keys" "$T/peers" | tr '\n' ' ')"
fi

# 9. The orphans, and only the orphans, are gone.
T="$WORK/t9"; build_tree "$T"
run_cr "$T" --purge-orphans --yes >/dev/null
missing=""
for p in "clients/dead-one.conf" "keys/10.0.0.99_alias_known_hosts" \
         "pairing/10.0.0.99.conf.suggested" "pairing/me-to-10.0.0.99.tgz" \
         "peers/oldpeer.conf" "peers/oldpeer.scope" "peers/oldpeer.scope.sha256" \
         "rel/oldpeer" "rel/barepeer"; do
    [ -e "$T/$p" ] && missing="$missing $p"
done
if [ -z "$missing" ]; then
    ok "every orphaned artefact is removed, across all three keyings"
else
    bad "every orphaned artefact is removed, across all three keyings" "still present:$missing"
fi

# 10. known_hosts is never touched, and the operator is handed the command.
T="$WORK/t10"; build_tree "$T"
out=$(run_cr "$T" --purge-orphans --yes)
if grep -q 'known_hosts left alone' <<<"$out" && grep -q 'ssh-keygen -f' <<<"$out"; then
    ok "known_hosts is left alone and the ssh-keygen line is printed, not run"
else
    bad "known_hosts is left alone and the ssh-keygen line is printed, not run" "$out"
fi

# ---------------------------------------------------------------------------
# 11. A non-empty gate directory is NOT force-removed. rmdir refuses on its own,
#     so the safety sits in the tool rather than in this script's belief that
#     the directory was empty -- and a marker file in there means a disable is
#     still in force, which is not something to sweep past.
# ---------------------------------------------------------------------------
T="$WORK/t11"; build_tree "$T"
touch "$T/rel/barepeer/disabled"
out=$(run_cr "$T" --purge=barepeer --yes)
if [ -e "$T/rel/barepeer/disabled" ] && grep -qi 'NOT empty' <<<"$out"; then
    ok "a non-empty gate directory is reported, not force-removed"
else
    bad "a non-empty gate directory is reported, not force-removed" "$out"
fi

# ---------------------------------------------------------------------------
# 12. The STATE log is append-only: the LAST line is the current state. Reading
#     the first would call every removed relationship 'pending_enroll' -- and,
#     worse, reading the first of a LIVE record would call it dead.
# ---------------------------------------------------------------------------
T="$WORK/t12"; build_tree "$T"
printf 'CLIENT_NAME=revived\nPEER_HOST=10.0.0.7\nSTATE=removed\nSTATE=active\n' \
    > "$T/clients/revived.conf"
out=$(run_cr "$T")
if grep -q 'revived  \[LIVE\]' <<<"$out"; then
    ok "the LAST STATE line decides, not the first"
else
    bad "the LAST STATE line decides, not the first" "$out"
fi

# ---------------------------------------------------------------------------
# 13. The DEFAULT relationship name IS the peer's address, so on a collector
#     that took the default, the identity and the address are the same string
#     and several families resolve to the same file. Found on pve2 the moment
#     this ran on a real host: peers/192.168.28.99.conf was listed twice under
#     two family names. A duplicate in a list an operator is about to approve
#     is a list they cannot check.
# ---------------------------------------------------------------------------
T="$WORK/t13"; build_tree "$T"
printf 'CLIENT_NAME=10.0.0.55\nPEER_HOST=10.0.0.55\nSTATE=removed\n' > "$T/clients/10.0.0.55.conf"
printf 'PEER_SAVED_ACCOUNT=x\n' > "$T/peers/10.0.0.55.conf"
out=$(run_cr "$T")
dupes=$(grep -c 'peers/10.0.0.55.conf' <<<"$out")
if [ "$dupes" -eq 1 ]; then
    ok "an address-named relationship lists each file once, not once per family"
else
    bad "an address-named relationship lists each file once, not once per family" \
        "peers/10.0.0.55.conf appears $dupes times" "$out"
fi

# ---------------------------------------------------------------------------
# 14. When --leave refuses because of an in-flight hold, say what that refusal
#     assumes. Measured 2026-08-20: the hold had LEAKED from a transfer that
#     died, its snapshot's successor had already been received, and --leave's
#     own "retry once the transfer completes" was therefore a dead end. On the
#     receiving side the same interrupted transfer had left a %recv stub that
#     was failing the hourly retention -- two hours of silent breakage from one
#     event, and neither message mentioned the other.
# ---------------------------------------------------------------------------
T="$WORK/t14"; build_tree "$T"
FAKE="$WORK/fake-deploy.sh"
cat > "$FAKE" <<'EOD'
#!/bin/bash
echo "FATAL: refusing --leave='oldpeer': hdd/x has an in-flight transfer hold (zfssnapall_inflight) -- revoking access now would strand that resume."
exit 1
EOD
chmod +x "$FAKE"
out=$(CLIENTS_DIR="$T/clients" PEER_STATE_DIR="$T/peers" REL_STATE_DIR="$T/rel" \
      PEER_KEY_DIR="$T/keys" PAIRING_DIR="$T/pairing" HOME_ROOT="$T/home" \
      TOMBSTONE_DIR="$T/removed" DEPLOY="$FAKE" ZFSBACKUP=/nonexistent bash "$CR" --purge=oldpeer --yes 2>&1)
if grep -q 'assumes a transfer is RUNNING' <<<"$out" \
   && grep -q '%recv' <<<"$out" \
   && grep -q 'zfs release zfssnapall_inflight' <<<"$out" \
   && grep -q "FATAL: refusing --leave" <<<"$out"; then
    ok "an in-flight-hold refusal is quoted AND its most common cause named"
else
    bad "an in-flight-hold refusal is quoted AND its most common cause named" "$out"
fi

# 15. A refusal for any OTHER reason must not get that advice -- guessing the
#     cause is the failure mode this whole day was spent removing.
T="$WORK/t15"; build_tree "$T"
cat > "$FAKE" <<'EOD'
#!/bin/bash
echo "FATAL: refusing --leave='oldpeer': something else entirely"
exit 1
EOD
chmod +x "$FAKE"
out=$(CLIENTS_DIR="$T/clients" PEER_STATE_DIR="$T/peers" REL_STATE_DIR="$T/rel" \
      PEER_KEY_DIR="$T/keys" PAIRING_DIR="$T/pairing" HOME_ROOT="$T/home" \
      TOMBSTONE_DIR="$T/removed" DEPLOY="$FAKE" ZFSBACKUP=/nonexistent bash "$CR" --purge=oldpeer --yes 2>&1)
if ! grep -q 'assumes a transfer is RUNNING' <<<"$out" && grep -q 'something else entirely' <<<"$out"; then
    ok "a refusal with a different cause is quoted, and gets no invented advice"
else
    bad "a refusal with a different cause is quoted, and gets no invented advice" "$out"
fi

# ---------------------------------------------------------------------------
# 16. The DATA a relationship owns is reported and never removed. Measured
#     2026-08-20: hdd/lab4direct outlived its relationship, and once the client
#     record was deleted nothing on the host linked that dataset to anything.
#     Reporting it costs no `zfs` call -- both the client record and the join
#     manifest name it in plain text -- and it has to happen BEFORE the record
#     that knows about it is deleted, which is why the purge says it again.
# ---------------------------------------------------------------------------
T="$WORK/t16"; build_tree "$T"
printf 'CLIENT_NAME=withdata\nPEER_HOST=10.0.0.77\nRUX_TARGET=hdd/somebackups\nSTATE=removed\n' \
    > "$T/clients/withdata.conf"
out=$(run_cr "$T")
if grep -qE 'data +hdd/somebackups' <<<"$out"; then
    ok "the audit names the dataset a relationship owns"
else
    bad "the audit names the dataset a relationship owns" "$out"
fi
# P9: the tombstone says what SURVIVED, so it has to look. Until 2026-08-21 it
# said "DATA LEFT IN PLACE" without checking -- including for datasets destroyed
# moments earlier. `zfs` is stubbed here for the same reason as case 20: the
# tool's only use of it is a read-only existence question.
mkdir -p "$T/bin"
cat > "$T/bin/zfs" <<'EOD'
#!/bin/sh
for a in "$@"; do [ "$a" = "hdd/somebackups" ] && { echo "$a"; exit 0; }; done
exit 1
EOD
chmod +x "$T/bin/zfs"
out=$(ZFS_BIN="$T/bin/zfs" run_cr "$T" --purge=withdata --yes)
if grep -q 'DATA LEFT IN PLACE: hdd/somebackups' <<<"$out" \
   && grep -q 'zfs destroy -r hdd/somebackups' <<<"$out" \
   && [ ! -e "$T/clients/withdata.conf" ]; then
    ok "the purge removes the record, names the data it leaves, and never destroys it"
else
    bad "the purge removes the record, names the data it leaves, and never destroys it" "$out"
fi

# 16b. P9's other half, and the one that was wrong: data the record names but
#      the pool no longer has must NOT be reported as left in place. A tombstone
#      is the only thing on the host naming this data once the record is gone --
#      asserting the survival of something it never looked at is the campaign's
#      whole family, in the one output whose job is to be trusted afterwards.
T="$WORK/t16b"; build_tree "$T"; mkdir -p "$T/bin"
printf 'CLIENT_NAME=gonedata\nPEER_HOST=10.0.0.78\nRUX_TARGET=hdd/vanished\nSTATE=removed\n' \
    > "$T/clients/gonedata.conf"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/zfs"; chmod +x "$T/bin/zfs"
out=$(ZFS_BIN="$T/bin/zfs" run_cr "$T" --purge=gonedata --yes)
if grep -q 'ALREADY GONE' <<<"$out" \
   && grep -q 'hdd/vanished' <<<"$out" \
   && ! grep -q 'DATA LEFT IN PLACE' <<<"$out"; then
    ok "the purge does not claim data survived when the pool no longer has it"
else
    bad "the purge does not claim data survived when the pool no longer has it" "$out"
fi

# ---------------------------------------------------------------------------
# 17-20. The tombstone. Purging deletes the record that is the only thing on
#     the host naming the data a relationship produced -- measured 2026-08-20,
#     when hdd/lab4direct outlived its relationship and the moment
#     clients/lab4-direct.conf was gone, nothing linked those 12 MB to anything
#     at all. The record is therefore written BEFORE the removal, and the
#     removal is refused if it cannot be written.
# ---------------------------------------------------------------------------
T="$WORK/t17"; build_tree "$T"
printf 'CLIENT_NAME=withdata\nPEER_HOST=10.0.0.77\nRUX_TARGET=hdd/somebackups\nSTATE=removed\n' \
    > "$T/clients/withdata.conf"
run_cr "$T" --purge=withdata --yes >/dev/null
tomb=$(ls "$T/removed"/withdata.* 2>/dev/null | head -1)
if [ -n "$tomb" ] && grep -q '^DATA=hdd/somebackups' "$tomb" \
   && grep -q '^REMOVED_NAME=withdata' "$tomb" \
   && grep -q 'zfs destroy -r hdd/somebackups' "$tomb"; then
    ok "a purge leaves a tombstone naming the data, and the command to destroy it"
else
    bad "a purge leaves a tombstone naming the data, and the command to destroy it" \
        "tombstone=${tomb:-none}" "$(cat "$tomb" 2>/dev/null)"
fi

# 18. A relationship that owns NO data needs no tombstone -- nothing would be
#     lost. Writing one anyway would fill the directory with noise and teach an
#     operator to ignore it.
T="$WORK/t18"; build_tree "$T"
run_cr "$T" --purge=barepeer --yes >/dev/null
if [ -z "$(ls "$T/removed" 2>/dev/null)" ]; then
    ok "a relationship owning no data leaves no tombstone"
else
    bad "a relationship owning no data leaves no tombstone" "$(ls "$T/removed")"
fi

# 19. If the record cannot be written, the purge REFUSES. Deleting the last
#     thing that names this data while leaving nothing that names it is exactly
#     the failure the tombstone exists to prevent, so it must not be reachable
#     by a tool that merely warns.
T="$WORK/t19"; build_tree "$T"
printf 'CLIENT_NAME=withdata\nPEER_HOST=10.0.0.77\nRUX_TARGET=hdd/somebackups\nSTATE=removed\n' \
    > "$T/clients/withdata.conf"
: > "$T/removed"          # a FILE where the directory must go: mkdir -p fails
out=$(run_cr "$T" --purge=withdata --yes)
if grep -qi 'REFUSING to purge' <<<"$out" && [ -e "$T/clients/withdata.conf" ]; then
    ok "an unwritable tombstone refuses the purge, and the record survives"
else
    bad "an unwritable tombstone refuses the purge, and the record survives" "$out"
fi

# 20. The audit reports tombstoned data that is STILL THERE -- the claim comes
#     from the record, never from the shape of a name. `zfs` is stubbed: the
#     tool's only use of it is this read-only existence question.
T="$WORK/t20"; build_tree "$T"
mkdir -p "$T/removed" "$T/bin"
printf 'REMOVED_NAME=gone\nDATA=hdd/stillhere\nDATA=hdd/alreadygone\n' > "$T/removed/gone.20260820-000000"
cat > "$T/bin/zfs" <<'EOD'
#!/bin/sh
# exists only for hdd/stillhere
for a in "$@"; do [ "$a" = "hdd/stillhere" ] && { echo "$a"; exit 0; }; done
exit 1
EOD
chmod +x "$T/bin/zfs"
out=$(ZFS_BIN="$T/bin/zfs" run_cr "$T")
if grep -q 'DATA WITHOUT A RELATIONSHIP' <<<"$out" \
   && grep -q 'hdd/stillhere' <<<"$out" \
   && ! grep -q 'hdd/alreadygone' <<<"$out" \
   && grep -q 'zfs destroy -r hdd/stillhere' <<<"$out"; then
    ok "the audit reports tombstoned data that still exists, and only that"
else
    bad "the audit reports tombstoned data that still exists, and only that" "$out"
fi

# 21. No zfs on PATH is a skip with a reason, not an error and not silence: the
#     rest of this tool has to keep working on a host where zfs is broken,
#     which is a state it is specifically for.
T="$WORK/t21"; build_tree "$T"
mkdir -p "$T/removed"
printf 'REMOVED_NAME=gone\nDATA=hdd/stillhere\n' > "$T/removed/gone.20260820-000000"
# Named binary, not an emptied PATH: emptying PATH also removes `bash`, and a
# result that depends on what the runner happens to have installed is the flake
# test/pairgate already documents.
out=$(ZFS_BIN="$T/no-such-zfs" run_cr "$T" 2>&1)
if grep -q 'zfs is not available' <<<"$out" && grep -q 'read them by hand' <<<"$out"; then
    ok "without zfs the data check says so rather than reporting nothing"
else
    bad "without zfs the data check says so rather than reporting nothing" "$out"
fi

# ---------------------------------------------------------------------------
# 22-23. THE DELEGATED ACCOUNT'S OWN KEYS, and orphan addresses.
#
# Measured on pve1 2026-08-20, building a relationship the production way
# (--local-user): the account keeps its pairing keys in
# /home/<acct>/.ssh/pairing-<addr>_* -- a PREFIX, where root uses a directory.
# This tool scanned only root's, so on a production host it was reporting the
# half nobody uses. One of the five files there was
# `pairing-192.168.28.190_alias_known_hosts`: an address named by no config and
# no cron line, exactly what this tool exists to surface.
#
# The second half is worse and older: SEEN_ADDR was collected and never
# reported, so ANY key file whose client record had already been deleted was
# invisible -- in root's directory too.
# ---------------------------------------------------------------------------
T="$WORK/t22"; build_tree "$T"
mkdir -p "$T/home/zfsbackup/.ssh"
# keys for the LIVE relationship, in the account's own naming
touch "$T/home/zfsbackup/.ssh/pairing-10.0.0.8_ed25519" \
      "$T/home/zfsbackup/.ssh/pairing-10.0.0.8_alias_known_hosts"
# and a key for an address nothing else on the host mentions at all
touch "$T/home/zfsbackup/.ssh/pairing-10.0.0.190_alias_known_hosts"
out=$(run_cr "$T")
if grep -q 'pairing-10.0.0.8_ed25519' <<<"$out"; then
    ok "the delegated account's own key directory is scanned, not just root's"
else
    bad "the delegated account's own key directory is scanned, not just root's" "$out"
fi
if grep -q '10.0.0.190' <<<"$out" && grep -q 'pairing-10.0.0.190_alias_known_hosts' <<<"$out"; then
    ok "an address with no client record left is reported, not silently dropped"
else
    bad "an address with no client record left is reported, not silently dropped" "$out"
fi

# 24. ...and the live relationship still appears ONCE. It now has two identities
#     that both resolve (its name and its address), and reporting both would
#     double every live entry on a real host.
if [ "$(grep -c 'live-one  \[' <<<"$out")" -eq 1 ] \
   && ! grep -qE '^  10\.0\.0\.8  \[' <<<"$out"; then
    ok "a live relationship is still listed once, under its name and not also its address"
else
    bad "a live relationship is still listed once, under its name and not also its address" "$out"
fi

# 25. Sandbox integrity: the suite must be incapable of touching a real path.
#     Asserted against the source, because this is a property of the tool's
#     defaults rather than of any single run.
#     Every writable path is listed, and so is the root-check's own list --
#     TOMBSTONE_DIR was added to the tool before it was added to that check,
#     which would have let a "sandboxed" run write to /var/lib. The suite caught
#     it; this assertion is what keeps the next one from slipping through.
sandbox_missing=""
for v in CLIENTS_DIR PEER_STATE_DIR REL_STATE_DIR PEER_KEY_DIR PAIRING_DIR \
         HOME_ROOT TOMBSTONE_DIR ZFS_BIN; do
    grep -qE "^$v=\"\\\$\\{$v:-" "$CR" || sandbox_missing="$sandbox_missing $v"
done
for v in CLIENTS_DIR PEER_STATE_DIR REL_STATE_DIR PEER_KEY_DIR TOMBSTONE_DIR HOME_ROOT; do
    grep -q "\$$v:" "$CR" || sandbox_missing="$sandbox_missing $v(root-check)"
done
if [ -z "$sandbox_missing" ]; then
    ok "every system path is overridable AND in the root check, which is what makes this suite safe"
else
    bad "every system path is overridable AND in the root check, which is what makes this suite safe" \
        "not overridable / not in the root check:$sandbox_missing"
fi

# ---------------------------------------------------------------------------
# THE WIRING, NOT THE FUNCTION.
#
# drain_queued_alerts moves a purged relationship's queued findings into its
# tombstone instead of deleting them. The first cut of that change was proven by
# calling the function directly with an explicit tombstone path -- which proved
# the function and left the WIRING unproven. purge_one was clearing
# TOMBSTONE_WRITTEN *after* write_tombstone had set it, so the real call site
# always passed an empty path: findings vanished from the queue and were
# archived nowhere, while the change advertised "findings are NOT discarded".
#
# So this drives the whole verb, exactly as an operator does, and asserts BOTH
# halves: gone from the queue AND present in the tombstone. A test that only
# checked the queue would still pass on the broken version.
T="$WORK/tq"; build_tree "$T"
mkdir -p "$T/removed"
QF="$T/alert-queue.log"
printf '%s	ALERT	pve1 keep_hourly stale (dead-one)	CRITICAL dataset=x
' 1787000000 >  "$QF"
printf '%s	WARN	pve1 keep_hourly getting stale (dead-one)	WARNING dataset=x
' 1787000001 >> "$QF"
printf '%s	WARN	pve1 keep_hourly getting stale (other-rel)	WARNING dataset=y
' 1787000002 >> "$QF"

ALERT_QUEUE="$QF" run_cr "$T" --purge-orphans --yes >/dev/null 2>&1

# grep -c already prints 0 when it matches nothing; the "|| echo 0" this line
# used to carry appended a SECOND zero, so the value became two lines and the
# comparison became a syntax error -- while the measured values were exactly
# not a comparison -- so the assertion failed while the measured values were
# exactly right. Counted with true so a non-zero grep status cannot abort.
q_mine=$(grep -cF '(dead-one)' "$QF" 2>/dev/null; true)
q_other=$(grep -cF '(other-rel)' "$QF" 2>/dev/null; true)
t_arch=$(cat "$T/removed"/dead-one.* 2>/dev/null | grep -c '^QUEUED_ALERT='; true)

# This fixture's dead relationship owns no datasets, so write_tombstone writes
# nothing -- and that is the case worth pinning hardest: with nowhere to archive
# to, the findings must STAY. Deleting them would be the very "discarded"
# behaviour the change exists to prevent, and it is what the first cut did at
# every call site because the path was empty.
if [ "$q_mine" -eq 2 ] && [ "$q_other" -eq 1 ] && [ "$t_arch" -eq 0 ]; then
    ok "purge with no tombstone: findings stay queued rather than being deleted with nowhere to go"
else
    bad "purge with no tombstone: findings stay queued rather than being deleted with nowhere to go"         "w kolejce moich=$q_mine obcych=$q_other, w nagrobku=$t_arch (oczekiwano 2 / 1 / 0)"
fi

# ---------------------------------------------------------------------------
# A HOLD OUTLIVES THE RELATIONSHIP THAT PLACED IT.
#
# Measured on pve9, 2026-08-26: a `zfssnapall_inflight` hold placed on
# 2026-08-22 by a run that died was still there four days later, with zero jobs
# on the host. `zfs destroy` refused with "dataset is busy" -- which names
# neither the hold nor the tag -- and retention hit the same wall silently on
# every run.
#
# The audit could not have found it: the hold's relationship was already gone,
# so anything keyed on the relationship list misses exactly the case this
# exists for. Hence a host-wide check, and hence these cases feed it through a
# stubbed `zfs` rather than through the relationship fixtures.
# ---------------------------------------------------------------------------
T="$WORK/holds"; build_tree "$T"; mkdir -p "$T/bin"

# A zfs that reports one held snapshot, held by OUR tag.
cat > "$T/bin/zfs" <<'HELDEOD'
#!/bin/sh
case "$*" in
  *"-t snapshot userrefs"*)
      printf 'tank/a@s1\t0\n'
      printf 'tank/b@s2\t1\n'
      exit 0 ;;
  "holds -H tank/b@s2")
      printf 'tank/b@s2\tzfssnapall_inflight\t-\n'; exit 0 ;;
  "holds -H"*) exit 0 ;;
esac
exit 1
HELDEOD
chmod +x "$T/bin/zfs"
out=$(ZFS_BIN="$T/bin/zfs" run_cr "$T"); rc=$?
case "$out" in
    *"HELD SNAPSHOTS"*) ok "holds: a held snapshot is reported" ;;
    *) bad "holds: a held snapshot is reported" "$out" ;;
esac
# The exact line is now the tool's own verb, not a raw `zfs release`: since the
# review, nothing may be released without a human naming the snapshot, so the
# line handed over is the one that does that.
case "$out" in
    *"--release-hold=tank/b@s2"*) ok "holds: ...with the exact release line for that snapshot" ;;
    *) bad "holds: ...with the exact release line for that snapshot" "$out" ;;
esac
# The snapshot with userrefs=0 must not appear -- otherwise the report would be
# "every snapshot on the host" and nobody would read it.
case "$out" in
    *"tank/a@s1"*) bad "holds: an unheld snapshot is not reported" "tank/a@s1 is in the output" ;;
    *) ok "holds: an unheld snapshot is not reported" ;;
esac
# The verdict must not be clean. "nothing orphaned" while a dataset silently
# cannot be pruned is the false all-clear this tool exists to prevent.
case "$out" in
    *"held snapshots were found"*|*"HELD SNAPSHOTS"*) ok "holds: the verdict names the finding" ;;
    *) bad "holds: the verdict names the finding" "$out" ;;
esac
case "$out" in
    *"nothing orphaned -- every trace"*) bad "holds: ...and does not claim nothing is wrong" ;;
    *) ok "holds: ...and does not claim nothing is wrong" ;;
esac

# NOT OURS. pvesr and vzdump place holds too, and this project has already
# measured what touching a pvesr hold costs -- it wedges replication for good.
# A held snapshot whose tag is somebody else's must be invisible here.
cat > "$T/bin/zfs" <<'FOREIGNEOD'
#!/bin/sh
case "$*" in
  *"-t snapshot userrefs"*) printf 'tank/b@s2\t1\n'; exit 0 ;;
  "holds -H tank/b@s2") printf 'tank/b@s2\tpvesr\t-\n'; exit 0 ;;
esac
exit 1
FOREIGNEOD
chmod +x "$T/bin/zfs"
out=$(ZFS_BIN="$T/bin/zfs" run_cr "$T"); rc=$?
case "$out" in
    *"HELD SNAPSHOTS"*) bad "holds: a FOREIGN hold is not ours to report" "$out" ;;
    *) ok "holds: a FOREIGN hold is not ours to report" ;;
esac
case "$out" in
    *"held snapshots were found"*) bad "holds: ...and does not spoil the verdict" ;;
    *) ok "holds: ...and does not spoil the verdict" ;;
esac

# NEGATIVE CONTROL for the whole block: with nothing held, the section is
# absent and the verdict is clean. Without this, every assertion above would
# pass against a build that had simply stopped printing the section.
cat > "$T/bin/zfs" <<'NONEEOD'
#!/bin/sh
case "$*" in
  *"-t snapshot userrefs"*) printf 'tank/a@s1\t0\n'; exit 0 ;;
esac
exit 1
NONEEOD
chmod +x "$T/bin/zfs"
out=$(ZFS_BIN="$T/bin/zfs" run_cr "$T"); rc=$?
case "$out" in
    *"HELD SNAPSHOTS"*) bad "holds: nothing held means nothing reported" ;;
    *) ok "holds: nothing held means nothing reported" ;;
esac
# On a tree with NO relationships the exit status can only come from the hold
# check -- which is what makes it worth asserting here and nowhere above.
E="$WORK/emptytree"; mkdir -p "$E/clients" "$E/peers" "$E/rel" "$E/keys" "$E/pairing" "$E/home" "$E/removed" "$E/bin"
cp "$T/bin/zfs" "$E/bin/zfs"
out=$(ZFS_BIN="$E/bin/zfs" run_cr "$E"); rc=$?
if [ "$rc" -eq 0 ]; then ok "holds: nothing held on a bare host is a clean exit 0"
else bad "holds: nothing held on a bare host is a clean exit 0" "rc=$rc" "$out"; fi
# ...and the positive half of that same rc: one held snapshot alone turns it to 3.
cat > "$E/bin/zfs" <<'ONEEOD'
#!/bin/sh
case "$*" in
  *"-t snapshot userrefs"*) printf 'tank/b@s2	1
'; exit 0 ;;
  "holds -H tank/b@s2") printf 'tank/b@s2	zfssnapall_inflight	-
'; exit 0 ;;
esac
exit 1
ONEEOD
chmod +x "$E/bin/zfs"
out=$(ZFS_BIN="$E/bin/zfs" run_cr "$E"); rc=$?
# Still a finding, and for a reason that survived the review: whoever owns it,
# a hold nothing running claims blocks `zfs destroy` and fails retention on that
# dataset silently. What changed is that we no longer assert it is abandoned.
if [ "$rc" -eq 3 ]; then ok "holds: an unclaimed hold ALONE is enough to fail the audit"
else bad "holds: an unclaimed hold ALONE is enough to fail the audit" "rc=$rc" "$out"; fi

# ---------------------------------------------------------------------------
# THE DATASET LINE IS THE ONLY THING LINKING DATA TO A DEAD RELATIONSHIP,
# so it has to be correct and it has to say whether the data is still there.
#
# Found on pve1, 2026-08-26. These records are %q-quoted because they are
# sourced as root elsewhere, so two datasets are stored separated by an ESCAPED
# space. Splitting on whitespace reported the first one as `hdd/a/tree\` -- a
# name that is not legal ZFS and cannot be pasted into the `zfs destroy` this
# line exists to hand the operator.
#
# The carrying case is d2: an implementation that splits on whitespace produces
# a trailing backslash and fails it, while every other assertion here would
# still pass.
# ---------------------------------------------------------------------------
D="$WORK/dsnames"; mkdir -p "$D/clients" "$D/peers" "$D/rel" "$D/keys" "$D/pairing" "$D/home" "$D/removed" "$D/bin"
printf 'CLIENT_NAME=demo\nSTATE=active\nMANAGED_DATASETS=hdd/a/tree\\ hdd/a/flat\nSTATE=removed\n' > "$D/clients/demo.conf"
# tree EXISTS, flat does not -- so one report can show both labels.
# The real call passes `--` before the name, so the stub matches the shape the
# code actually uses rather than the one the test author remembered.
cat > "$D/bin/zfs" <<'DSEOD'
#!/bin/sh
case "$*" in
  *"list -H -o name"*" hdd/a/tree") exit 0 ;;
esac
exit 1
DSEOD
chmod +x "$D/bin/zfs"
out=$(ZFS_BIN="$D/bin/zfs" run_cr "$D")

# d1 -- both members are reported, not one.
n=$(printf '%s\n' "$out" | grep -c '^      data')
if [ "$n" = 2 ]; then ok "dsnames: a %q-quoted pair is reported as TWO datasets"
else bad "dsnames: a %q-quoted pair is reported as TWO datasets" "got $n" "$out"; fi

# d2 -- THE carrying assertion. Anchored to the end of the field so it cannot
# pass on a value that merely contains a backslash somewhere harmless.
if printf '%s\n' "$out" | grep -qE 'data[[:space:]]+[^[:space:]]*\\([[:space:]]|$)'; then
    bad "dsnames: no reported name ends in a backslash" "$(printf '%s' "$out" | grep data)"
else
    ok "dsnames: no reported name ends in a backslash"
fi
case "$out" in
    *"hdd/a/tree"*) ok "dsnames: the first member survives the split intact" ;;
    *) bad "dsnames: the first member survives the split intact" "$out" ;;
esac
case "$out" in
    *"hdd/a/flat"*) ok "dsnames: ...and so does the second" ;;
    *) bad "dsnames: ...and so does the second" "$out" ;;
esac

# d3 -- the audit says whether the data is STILL THERE. Without this the
# destructive verb verified and the read-only one did not, so an operator could
# not tell "gone" from "corrupted" from "still here".
case "$out" in
    *"hdd/a/tree   (PRESENT)"*) ok "dsnames: a dataset that exists is labelled PRESENT" ;;
    *) bad "dsnames: a dataset that exists is labelled PRESENT" "$(printf '%s' "$out" | grep data)" ;;
esac
case "$out" in
    *"hdd/a/flat   (ALREADY GONE)"*) ok "dsnames: a dataset that is gone is labelled ALREADY GONE" ;;
    *) bad "dsnames: a dataset that is gone is labelled ALREADY GONE" "$(printf '%s' "$out" | grep data)" ;;
esac

# THE THIRD STATE. Without it a missing `zfs` leaves the line unlabelled, and an
# unlabelled line reads exactly like a healthy one -- on the report an operator
# acts on. Reviewer, 2026-08-26: absence of the tool must never mean presence of
# the data.
out=$(ZFS_BIN="$D/bin/definitely-not-here" run_cr "$D")
case "$out" in
    *"UNVERIFIABLE"*) ok "dsnames: no zfs on the host is UNVERIFIABLE, not silence" ;;
    *) bad "dsnames: no zfs on the host is UNVERIFIABLE, not silence" "$(printf '%s' "$out" | grep data)" ;;
esac
case "$out" in
    *PRESENT*) bad "dsnames: ...and never PRESENT" "$(printf '%s' "$out" | grep data)" ;;
    *) ok "dsnames: ...and never PRESENT" ;;
esac
# A zfs that FAILS for some other reason is also unanswered, not absent.
printf '#!/bin/sh
exit 9
' > "$D/bin/brokenzfs"; chmod +x "$D/bin/brokenzfs"
out=$(ZFS_BIN="$D/bin/brokenzfs" run_cr "$D")
case "$out" in
    *"UNVERIFIABLE"*) ok "dsnames: a zfs that errors is UNVERIFIABLE, not ALREADY GONE" ;;
    *) bad "dsnames: a zfs that errors is UNVERIFIABLE, not ALREADY GONE" "$(printf '%s' "$out" | grep data)" ;;
esac
case "$out" in
    *"ALREADY GONE"*) bad "dsnames: ...and an error is not read as absence" "$(printf '%s' "$out" | grep data)" ;;
    *) ok "dsnames: ...and an error is not read as absence" ;;
esac

# d4 -- an escape this code does NOT understand is named, not half-decoded.
# A ZFS name cannot contain a backslash, so anything left after decoding means
# the value is not what the reader thinks it is.
printf 'CLIENT_NAME=odd\nSTATE=active\nMANAGED_DATASETS=hdd/a\\tweird\nSTATE=removed\n' > "$D/clients/odd.conf"
out=$(ZFS_BIN="$D/bin/zfs" run_cr "$D")
case "$out" in
    *SUSPECT*) ok "dsnames: an escape that is not the separator is flagged SUSPECT" ;;
    *) bad "dsnames: an escape that is not the separator is flagged SUSPECT" "$(printf '%s' "$out" | grep -A1 odd)" ;;
esac
case "$out" in
    *"do not paste it into a destroy"*) ok "dsnames: ...and says not to paste it into a destroy" ;;
    *) bad "dsnames: ...and says not to paste it into a destroy" ;;
esac

# NEGATIVE CONTROL: a value with NO escapes must not be flagged, or the two
# assertions above would pass against a build that flagged everything.
rm -f "$D/clients/odd.conf"
printf 'CLIENT_NAME=plain\nSTATE=active\nRUX_TARGET=hdd/a/tree\nSTATE=removed\n' > "$D/clients/plain.conf"
out=$(ZFS_BIN="$D/bin/zfs" run_cr "$D")
case "$out" in
    *SUSPECT*) bad "dsnames: an ordinary name is NOT flagged" "$(printf '%s' "$out" | grep data)" ;;
    *) ok "dsnames: an ordinary name is NOT flagged" ;;
esac

# ---------------------------------------------------------------------------
# THE SOURCE HALF DOES NOT %q-QUOTE, and that is the shape that was actually
# on a live host.
#
# Measured on pve1, 2026-08-30, tearing down a lab relationship:
#
#     PEER_JOIN_GRANTED_DATASETS="hdd/labsrc hdd/labsrc/vm-900-disk-0 ..."
#
# Double-quoted, BARE spaces. The splitter knew `\ ` and `,` and neither
# matched, so three names arrived at `zfs list` as ONE string and the audit
# answered ALREADY GONE for three datasets that were all present. The report an
# operator acts on told them to walk away from live data.
#
# d5 is the carrying assertion: a build that splits only on `\ ` and `,` gets
# ONE data line here instead of three, and every other assertion in this block
# still passes.
# ---------------------------------------------------------------------------
S="$WORK/srcnames"; mkdir -p "$S/clients" "$S/peers" "$S/rel" "$S/keys" "$S/pairing" "$S/home" "$S/removed" "$S/bin"
printf 'CLIENT_NAME=pve9\nSTATE=active\nPEER_JOIN_GRANTED_DATASETS="hdd/labsrc hdd/labsrc/vm-900-disk-0 hdd/labsrc/vm-900-disk-1"\nSTATE=removed\n' > "$S/clients/pve9.conf"
# All three EXIST -- the bug reported every one of them as gone.
#
# The stub compares the LAST ARGUMENT EXACTLY, and that is not a detail. A
# `case "$*" in *" hdd/labsrc/vm-900-disk-1")` stub matches the GLUED string
# too, because the glue ends in that same name -- so the broken build scored a
# PRESENT for one of the three and two of these assertions passed against it.
# The stub has to be as strict as the claim.
cat > "$S/bin/zfs" <<'SNEOD'
#!/bin/sh
last=""
for a in "$@"; do last="$a"; done
case "$last" in
  hdd/labsrc|hdd/labsrc/vm-900-disk-0|hdd/labsrc/vm-900-disk-1) exit 0 ;;
esac
exit 1
SNEOD
chmod +x "$S/bin/zfs"
out=$(ZFS_BIN="$S/bin/zfs" run_cr "$S")

# d5 -- three datasets, three lines.
n=$(printf '%s\n' "$out" | grep -c '^      data')
if [ "$n" = 3 ]; then ok "srcnames: a bare-space list is reported as THREE datasets"
else bad "srcnames: a bare-space list is reported as THREE datasets" "got $n" "$out"; fi

# d6 -- and the consequence that made it dangerous.
case "$out" in
    *"ALREADY GONE"*) bad "srcnames: present data is NOT reported as gone" "$(printf '%s' "$out" | grep data)" ;;
    *) ok "srcnames: present data is NOT reported as gone" ;;
esac

# d7 -- each name intact and individually verified.
for want in hdd/labsrc hdd/labsrc/vm-900-disk-0 hdd/labsrc/vm-900-disk-1; do
    case "$out" in
        *"$want   (PRESENT)"*) ok "srcnames: $want survives the split and is PRESENT" ;;
        *) bad "srcnames: $want survives the split and is PRESENT" "$(printf '%s' "$out" | grep data)" ;;
    esac
done

# d8 -- the quotes must not survive into a name that gets pasted into a destroy.
if printf '%s\n' "$out" | grep -qE 'data[[:space:]]+[^[:space:]]*"'; then
    bad "srcnames: no reported name carries a quote" "$(printf '%s' "$out" | grep data)"
else
    ok "srcnames: no reported name carries a quote"
fi

# ---------------------------------------------------------------------------
# "PROBABLY LEAKED" IS NOT A VERDICT.
#
# Reviewer, 2026-08-26: a hold may be called orphaned only against evidence --
# no running engine, no in-flight record naming it, no resume token -- and it may
# be released only in the explicit purge path.
#
# Age is deliberately NOT evidence, and these cases are what say so: the same
# hold is IN-USE, UNPROVEN or ORPHANED depending only on the state around it.
#
# HOLD_PS_CMD is pinned in every case. Left to the real `ps`, the answer would
# depend on whether a transfer happens to be running on the machine running the
# tests -- the flake test/pairgate already documents.
# ---------------------------------------------------------------------------
P="$WORK/holdproof"
mkdir -p "$P/clients" "$P/peers" "$P/rel" "$P/keys" "$P/pairing" "$P/home" "$P/removed" "$P/bin" "$P/home/acct/run"
cat > "$P/bin/zfs" <<'PROOFEOD'
#!/bin/sh
case "$*" in
  *"-t snapshot userrefs"*) printf 'tank/b@s2\t1\n'; exit 0 ;;
  "holds -H tank/b@s2") printf 'tank/b@s2\tzfssnapall_inflight\t-\n'; exit 0 ;;
  *"receive_resume_token"*) [ -n "$FAKE_RESUME" ] && { echo "1-abc"; exit 0; }; exit 0 ;;
  "release zfssnapall_inflight tank/b@s2") echo "RELEASED" >> "$FAKE_RELEASED"; exit 0 ;;
esac
exit 1
PROOFEOD
chmod +x "$P/bin/zfs"
proof_run() {   # <extra env assignments as name=value...> -- echoes output
    HOLD_PS_CMD="${PROOF_PS:-true}" FAKE_RESUME="${PROOF_RESUME:-}" \
    FAKE_RELEASED="$P/released" ZFS_BIN="$P/bin/zfs" run_cr "$P" "$@"
}

# 1. Nothing running, nothing claimed, no token -> ORPHANED.
: > "$P/released"
out=$(proof_run)
# NOT "ORPHANED". Everything this host can see has been checked and none of it
# convicts -- which is a different sentence from "nothing owns this", and after
# the review the tool says the different sentence. /var/run is not persistent,
# so the absence of an in-flight record is absence of evidence.
case "$out" in
    *"UNPROVEN"*) ok "proof: with no local evidence the verdict is UNPROVEN, not ORPHANED" ;;
    *) bad "proof: with no local evidence the verdict is UNPROVEN, not ORPHANED" "$(printf '%s' "$out" | grep -A2 HELD)" ;;
esac

# 2. An in-flight record naming THIS snapshot -> IN-USE. This is the direct
#    claim and it convicts precisely: the file names the snapshot.
printf 'tank/b@s2\n' > "$P/home/acct/run/snapget.sh.inflight-snap.deadbeef"
out=$(proof_run)
case "$out" in
    *"IN-USE"*) ok "proof: an in-flight record naming it makes it IN-USE" ;;
    *) bad "proof: an in-flight record naming it makes it IN-USE" "$(printf '%s' "$out" | grep -A2 HELD)" ;;
esac
case "$out" in
    *"ORPHANED tank/b@s2"*) bad "proof: ...and it is NOT called orphaned" ;;
    *) ok "proof: ...and it is NOT called orphaned" ;;
esac
# An in-flight record for a DIFFERENT snapshot must not protect this one --
# otherwise any transfer anywhere would make every hold untouchable.
printf 'tank/z@other\n' > "$P/home/acct/run/snapget.sh.inflight-snap.deadbeef"
out=$(proof_run)
# The property still matters: a record for ANOTHER snapshot must not make this
# one IN-USE, or any transfer anywhere would make every hold untouchable.
case "$out" in
    *"IN-USE"*) bad "proof: a record naming a DIFFERENT snapshot does not protect this one" "$(printf '%s' "$out" | grep -A2 HELD)" ;;
    *) ok "proof: a record naming a DIFFERENT snapshot does not protect this one" ;;
esac
rm -f "$P/home/acct/run/snapget.sh.inflight-snap.deadbeef"

# 3. An engine running -> UNPROVEN. Nothing here can tell which hold it owns,
#    so every verdict is withheld. Fail-closed.
out=$(PROOF_PS="printf %s\\n /usr/local/bin/snapget.sh" proof_run)
case "$out" in
    *"UNPROVEN"*) ok "proof: a running engine makes the verdict UNPROVEN" ;;
    *) bad "proof: a running engine makes the verdict UNPROVEN" "$(printf '%s' "$out" | grep -A2 HELD)" ;;
esac

# 4. A local resume token -> UNPROVEN. Some transfer means to continue.
out=$(PROOF_RESUME=1 proof_run)
case "$out" in
    *"UNPROVEN"*) ok "proof: a local resume token makes the verdict UNPROVEN" ;;
    *) bad "proof: a local resume token makes the verdict UNPROVEN" "$(printf '%s' "$out" | grep -A2 HELD)" ;;
esac
# The boundary is STATED, not implied: a token on a remote target cannot be seen.
case "$out" in
    *"REMOTE target cannot be seen"*) ok "proof: the report states what it could NOT check" ;;
    *) bad "proof: the report states what it could NOT check" ;;
esac

# 5. NOTHING is released without a human naming the snapshot.
#
# The first cut let --purge-orphans release everything it had called ORPHANED.
# Review killed it with a counterexample this suite now carries: /var/run is NOT
# persistent, so a reboot removes the in-flight record while the ZFS hold and the
# resume token on the REMOTE receiver both survive. "No local evidence" is then
# indistinguishable from "nothing owns this", and the difference is a snapshot a
# resume still needs.
: > "$P/released"
out=$(proof_run)   # audit
if [ ! -s "$P/released" ]; then ok "release: the AUDIT never releases anything"
else bad "release: the AUDIT never releases anything" "$(cat "$P/released")"; fi

# THE COUNTEREXAMPLE, as specified in the review: a hold exists, no in-flight
# file, no process -- the state a rebooted source is in -- and the receiver is
# not observable. --purge-orphans --yes must not release it.
: > "$P/released"
out=$(proof_run --purge-orphans --yes)
if [ ! -s "$P/released" ]; then ok "release: a rebooted source's hold is NOT swept by --purge-orphans"
else bad "release: a rebooted source's hold is NOT swept by --purge-orphans" "$(cat "$P/released")"; fi
case "$out" in
    *"not observable from this host"*) ok "release: ...and the verdict says the receiver could not be seen" ;;
    *) bad "release: ...and the verdict says the receiver could not be seen" "$(printf '%s' "$out" | grep -A2 HELD)" ;;
esac
case "$out" in
    *ORPHANED*) bad "release: ...and it is never called ORPHANED on this evidence" "$(printf '%s' "$out" | grep -A2 HELD)" ;;
    *) ok "release: ...and it is never called ORPHANED on this evidence" ;;
esac

# The named verb is the only way through, and it names the snapshot.
: > "$P/released"
out=$(proof_run --release-hold=tank/b@s2 --yes)
if grep -q RELEASED "$P/released" 2>/dev/null; then ok "release: --release-hold releases the one named"
else bad "release: --release-hold releases the one named" "$out"; fi
case "$out" in
    *"released zfssnapall_inflight on tank/b@s2"*) ok "release: ...and says which snapshot it released" ;;
    *) bad "release: ...and says which snapshot it released" "$out" ;;
esac

# Without --yes it is a dry run, like every other destructive path here.
: > "$P/released"
out=$(proof_run --release-hold=tank/b@s2)
if [ ! -s "$P/released" ]; then ok "release: --release-hold without --yes changes nothing"
else bad "release: --release-hold without --yes changes nothing" "$(cat "$P/released")"; fi

# The human is being asked about the FAR side only -- facts this host holds still
# refuse. An in-flight record naming it means a transfer is running NOW.
: > "$P/released"
printf 'tank/b@s2\n' > "$P/home/acct/run/snapget.sh.inflight-snap.deadbeef"
out=$(proof_run --release-hold=tank/b@s2 --yes)
rm -f "$P/home/acct/run/snapget.sh.inflight-snap.deadbeef"
if [ ! -s "$P/released" ]; then ok "release: refused when THIS host says a transfer holds it"
else bad "release: refused when THIS host says a transfer holds it" "$(cat "$P/released")"; fi
case "$out" in
    *"still running"*) ok "release: ...and says so" ;;
    *) bad "release: ...and says so" "$out" ;;
esac

# THE TWO DISCRIMINATORS THE REVIEW ASKED FOR. UNPROVEN covers three different
# causes, and only ONE of them -- "the far side cannot be seen" -- is the
# operator's to overrule. The other two are facts this host holds, and the gate
# reads a reason CODE rather than the wording of the message.
: > "$P/released"
out=$(PROOF_PS="printf %s
 /usr/local/bin/snapget.sh" proof_run --release-hold=tank/b@s2 --yes)
if [ ! -s "$P/released" ]; then ok "release: refused while a local engine is running"
else bad "release: refused while a local engine is running" "$(cat "$P/released")"; fi
case "$out" in
    *"running on this host"*) ok "release: ...and says it is THIS host saying so, not the far side" ;;
    *) bad "release: ...and says it is THIS host saying so, not the far side" "$out" ;;
esac

: > "$P/released"
out=$(PROOF_RESUME=1 proof_run --release-hold=tank/b@s2 --yes)
if [ ! -s "$P/released" ]; then ok "release: refused while a LOCAL resume token exists"
else bad "release: refused while a LOCAL resume token exists" "$(cat "$P/released")"; fi
case "$out" in
    *"receive_resume_token"*) ok "release: ...and names the token as the reason" ;;
    *) bad "release: ...and names the token as the reason" "$out" ;;
esac

# A snapshot that carries no hold of ours is refused rather than "released".
: > "$P/released"
out=$(proof_run --release-hold=tank/nothing@here --yes)
case "$out" in
    *"does not carry"*) ok "release: a snapshot without our hold is refused, not silently ok" ;;
    *) bad "release: a snapshot without our hold is refused, not silently ok" "$out" ;;
esac

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
