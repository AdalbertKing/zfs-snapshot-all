# lib-pairing.sh -- WHERE the pairing state of a peer lives: its manifest,
# its scope file and the sha256 the last --commit-scope granted from, the key
# the generated job authenticates with and the host key it pins. Sourced,
# never executed, by lib-backup-common.sh (for zfs-backup.sh and
# zfs-restore.sh) and by deploy.sh. It defines only the variables and the
# six functions below and needs nothing from the includer.
#
# Why one file (2026-09-03). deploy.sh --pair/--join WRITE this layout and
# zfs-backup.sh add-client/activate-client READ it, with no call between the
# two programs: each carried its own copy of the six path formulas, "kept in
# sync deliberately", with test/zfsbackup pinning parity for the one that had
# once slipped out of both the enumeration and the pin (audit C1). A layout
# that two programs must agree on is a fact about the package, not about
# either program, so it is written once and sourced twice -- the same shape
# as lib-record.sh, and for the same reason it is not lib-backup-common.sh:
# deploy.sh has its own die/warn and cannot take the common lib.

# Overridable so a root-free suite can point a program's preflight (manifest
# lookup, scope file read) at a throwaway directory instead of the real,
# root-owned one -- same technique as ZFS_QUIESCE_ALLOW_DIR in deploy.sh. The
# default is unchanged for every real invocation. deploy.sh honoured the
# override before this file existed; zfs-backup.sh hard-coded the path and
# gains the same override by sharing the definition.
PEER_STATE_DIR="${PEER_STATE_DIR:-/etc/zfs-snapshot-all/peers}"
PEER_KEY_DIR="/root/.ssh/pairing"

# A filesystem/account-name-safe label derived from the peer's address. A
# hostname can contain characters that are fine in DNS but not in a Unix
# username or a bare filename, so this is the ONE place that gets sanitised --
# the manifest path, the key file name and the proposed account name are all
# built from it, on both sides. zfs-backup.sh uses it ONLY to locate
# deploy.sh's state, never for anything it displays or builds itself.
peer_label() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'; }

peer_manifest_path() { echo "$PEER_STATE_DIR/$1.conf"; }

# REV-20260802-033 (U1/U2): the scope file lives beside the manifest, keyed by
# the same label, on the SAME host as the manifest -- this host is the source
# in a pull relationship, so it is the one that both edits the file and grants
# from it. Not part of the wsad package: it is authored here, by hand, after
# --join, never shipped.
peer_scope_path() { echo "$PEER_STATE_DIR/$1.scope"; }

# ENROLMENT-AGREED-2026-08-02 T3: the sha256 of the scope file --commit-scope
# most recently granted from, as a sidecar next to it -- not a second
# manifest (there is nothing here a parser could disagree about, just a
# hash), and not embedded in the scope file itself (which would change the
# file's own hash the moment it recorded one). The collector fetches this
# alongside the scope file and refuses to generate/activate a job config
# when the two disagree.
peer_scope_granted_hash_path() { echo "$PEER_STATE_DIR/$1.scope.sha256"; }

# Where the GENERATED job should look for the key: the local-user copy when
# there is one, otherwise root's original.
local_keyfile_path() {
    local label="$1" user="$2"
    if [ -n "$user" ]; then
        local home_dir; home_dir=$(getent passwd "$user" | cut -d: -f6)
        [ -n "$home_dir" ] && { printf '%s' "$home_dir/.ssh/pairing-${label}_ed25519"; return 0; }
    fi
    printf '%s' "$PEER_KEY_DIR/${label}_ed25519"
}

# Same question for the pinned host key. Root's job gets the per-peer file too,
# not /root/.ssh/known_hosts: that file accumulates whatever accept-new has
# recorded over the years, and pinning "one key, verified once at pair time" is
# the whole point of the -k the draft emits.
local_knownhosts_path() {
    local label="$1" user="$2"
    if [ -n "$user" ]; then
        local home_dir; home_dir=$(getent passwd "$user" | cut -d: -f6)
        [ -n "$home_dir" ] && { printf '%s' "$home_dir/.ssh/pairing-${label}_known_hosts"; return 0; }
    fi
    printf '%s' "$PEER_KEY_DIR/${label}_known_hosts"
}
