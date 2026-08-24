#!/bin/bash
# Idempotent rerun of the four-command flow (contract of issue #9: "rerun
# resumes from durable state", "clean rerun showing idempotent resume").
#
# Repeating the flow after an interruption -- or after it already finished --
# must not stop at step 1 or step 3. Until 2026-08-24 both `add-client` and
# `seed` died on an existing relationship, so an operator (or a script)
# replaying the documented sequence hit rc=1 twice and had to know which steps
# to skip. That is not a resume.
#
# What must NOT change: a rerun asking for something DIFFERENT is still a
# refusal. Idempotence is "the same request again", not "anything goes".
#
# The state checks are exercised directly against a fabricated client record,
# because the question is the decision, not whether this machine has ZFS.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${RERUN_REPO:-$(cd "$DIR/../.." && pwd)}"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A client record as the flow leaves it once finished.
mkrec() {   # <state> <host> <target> <user> [created-endpoint]
    mkdir -p "$WORK/clients"
    cat > "$WORK/clients/rel.conf" <<REC
CLIENT_NAME=rel
PEER_HOST=$2
CLIENT_TARGET=$3
LOCAL_USER=$4
CREATED_ENDPOINT=${5:-$2:22}
STATE=$1
REC
}

# The add-client decision, lifted so the test states the inputs exactly.
addclient_decision() {   # <host> <target> <user> -> rc + first log line
    local t; t=$(mktemp)
    { echo 'set -u'
      echo 'log() { echo "LOG: $*"; }'
      echo 'die() { echo "DIE: $*"; exit 1; }'
      printf 'cpath=%q\n' "$WORK/clients/rel.conf"
      # `lan` is what add-client really has here -- the RAW --host argument.
      # Handing the test a pre-parsed lan_host is what let the first cut of
      # this fix reference a variable that does not exist yet at that point.
      printf 'name=rel\nlan=%q\ntarget=%q\nlocal_user=%q\n' "$1" "$2" "$3"
      # The gate falls back to the pairing manifest when a record predates
      # CREATED_ENDPOINT; stub the helpers so the test states its own inputs.
      printf 'peer_manifest_path() { echo %q; }
' "${MANIFEST:-/nonexistent}"
      echo 'peer_label() { echo lbl; }'
      # The block under test, verbatim from the real file, wrapped in a
      # function: it uses `local`, which bash rejects at top level -- and a
      # rejected `local` would make every case "fail" for a reason that has
      # nothing to do with the decision being tested.
      echo 'decide() {'
      awk '/^        local _prev_state$/{f=1} f{print} f&&/^        fi$/{exit}' "$REPO/zfs-backup.sh"
      echo '}'
      echo 'decide'
      echo 'echo "RC=0"'; } > "$t"
    bash "$t" 2>&1; rm -f "$t"
}

mkrec active 10.0.0.1 pool/tgt bckp

out="$(addclient_decision 10.0.0.1 pool/tgt bckp)"
case "$out" in
    *"RC=0"*|*"nothing to create"*) ok "an identical add-client rerun is a no-op" ;;
    *) bad "an identical add-client rerun is a no-op" "$(printf '%s' "$out" | head -2)" ;;
esac

out="$(addclient_decision 10.0.0.99 pool/tgt bckp)"
case "$out" in
    *DIE:*) ok "an add-client rerun naming a DIFFERENT host is refused" ;;
    *) bad "an add-client rerun naming a DIFFERENT host is refused" "$(printf '%s' "$out" | head -2)" ;;
esac

out="$(addclient_decision 10.0.0.1 pool/INNY bckp)"
case "$out" in
    *DIE:*) ok "an add-client rerun naming a DIFFERENT target is refused" ;;
    *) bad "an add-client rerun naming a DIFFERENT target is refused" "$(printf '%s' "$out" | head -2)" ;;
esac

# --- the two identity elements the first cut let through --------------------
# Both were reported by review with a discriminator; both are pinned here.

# PORT: a record created for :2222 must not accept a rerun asking for :22.
mkrec active 10.0.0.1 pool/tgt bckp 10.0.0.1:2222
out="$(addclient_decision 10.0.0.1:22 pool/tgt bckp)"
case "$out" in
    *DIE:*) ok "a rerun changing only the PORT is refused" ;;
    *) bad "a rerun changing only the PORT is refused" "$(printf '%s' "$out" | head -2)" ;;
esac

out="$(addclient_decision 10.0.0.1:2222 pool/tgt bckp)"
case "$out" in
    *"RC=0"*) ok "the SAME port is still a no-op" ;;
    *) bad "the SAME port is still a no-op" "$(printf '%s' "$out" | head -2)" ;;
esac

# ACCOUNT: an explicit --local-user=root is a request, not a wildcard.
mkrec active 10.0.0.1 pool/tgt bckp
out="$(addclient_decision 10.0.0.1 pool/tgt root)"
case "$out" in
    *DIE:*) ok "an explicit --local-user=root against a bckp record is refused" ;;
    *) bad "an explicit --local-user=root against a bckp record is refused" "$(printf '%s' "$out" | head -2)" ;;
esac

# ...and an OMITTED account still says nothing about identity.
out="$(addclient_decision 10.0.0.1 pool/tgt '')"
case "$out" in
    *"RC=0"*) ok "an OMITTED account leaves identity unchallenged" ;;
    *) bad "an OMITTED account leaves identity unchallenged" "$(printf '%s' "$out" | head -2)" ;;
esac

# The state used by the remaining cases.
mkrec active 10.0.0.1 pool/tgt bckp


# --- the fallback path, which the cases above never touch -------------------
# A record predating CREATED_ENDPOINT must still have its port checked, and the
# only durable source is the pairing manifest's PEER_SAVED_PORT. Stubbing the
# manifest away (as every case above does) would leave this whole branch
# untested -- so these two cases hand it a real file.
mkrec_nolegacy() {   # <host> <target> <user>  -- record WITHOUT CREATED_ENDPOINT
    mkdir -p "$WORK/clients"
    cat > "$WORK/clients/rel.conf" <<REC
CLIENT_NAME=rel
PEER_HOST=$1
CLIENT_TARGET=$2
LOCAL_USER=$3
STATE=active
REC
}

mkrec_nolegacy 10.0.0.1 pool/tgt bckp
printf 'PEER_SAVED_PORT=2222
' > "$WORK/manifest.conf"

MANIFEST="$WORK/manifest.conf" out="$(MANIFEST="$WORK/manifest.conf" addclient_decision 10.0.0.1:22 pool/tgt bckp)"
case "$out" in
    *DIE:*) ok "a legacy record takes its port from the pairing manifest (mismatch refused)" ;;
    *) bad "a legacy record takes its port from the pairing manifest (mismatch refused)" "$(printf '%s' "$out" | head -2)" ;;
esac

out="$(MANIFEST="$WORK/manifest.conf" addclient_decision 10.0.0.1:2222 pool/tgt bckp)"
case "$out" in
    *"RC=0"*) ok "a legacy record with a MATCHING manifest port is a no-op" ;;
    *) bad "a legacy record with a MATCHING manifest port is a no-op" "$(printf '%s' "$out" | head -2)" ;;
esac

# Neither CREATED_ENDPOINT nor a readable manifest: the endpoint cannot be
# confirmed, so this must NOT be treated as the same request.
out="$(addclient_decision 10.0.0.1:22 pool/tgt bckp)"
case "$out" in
    *DIE:*) ok "an unconfirmable endpoint fails CLOSED, not into a no-op" ;;
    *) bad "an unconfirmable endpoint fails CLOSED, not into a no-op" "$(printf '%s' "$out" | head -2)" ;;
esac

mkrec active 10.0.0.1 pool/tgt bckp


# The seed state gate, same treatment.
seed_gate() {   # <state> -> rc + message
    local t; t=$(mktemp)
    { echo 'set -u'
      echo 'log() { echo "LOG: $*"; }'
      echo 'die() { echo "DIE: $*"; exit 1; }'
      printf 'name=rel\nSTATE=%q\n' "$1"
      awk '/^    case "\$\{STATE:-\}" in$/{f=1} f{print} f&&/^    esac$/{exit}' "$REPO/zfs-backup.sh"
      echo 'echo "RC=0"'; } > "$t"
    bash "$t" 2>&1; rm -f "$t"
}

for st in seed_complete endpoint_verified active; do
    out="$(seed_gate "$st")"
    case "$out" in
        *"RC=0"*) ok "a seed rerun in state '$st' is a no-op" ;;
        *) bad "a seed rerun in state '$st' is a no-op" "$(printf '%s' "$out" | head -2)" ;;
    esac
done

for st in pending_enroll seeding; do
    out="$(seed_gate "$st")"
    case "$out" in
        *"RC=0"*) ok "a seed in state '$st' still proceeds" ;;
        *) bad "a seed in state '$st' still proceeds" "$(printf '%s' "$out" | head -2)" ;;
    esac
done

out="$(seed_gate removed)"
case "$out" in
    *DIE:*) ok "a seed in an unexpected state is still refused" ;;
    *) bad "a seed in an unexpected state is still refused" "$(printf '%s' "$out" | head -2)" ;;
esac

echo "--------------------------------------------"
echo "rerun: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
