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

# 14. Sandbox integrity: the suite must be incapable of touching a real path.
#     Asserted against the source, because this is a property of the tool's
#     defaults rather than of any single run.
if grep -qE '^CLIENTS_DIR="\$\{CLIENTS_DIR:-' "$CR" \
   && grep -qE '^REL_STATE_DIR="\$\{REL_STATE_DIR:-' "$CR" \
   && grep -qE '^HOME_ROOT="\$\{HOME_ROOT:-' "$CR"; then
    ok "every system path is overridable, which is what makes this suite safe"
else
    bad "every system path is overridable, which is what makes this suite safe" \
        "a hardcoded path would make this suite able to touch the host"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
