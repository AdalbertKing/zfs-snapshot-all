#!/bin/bash
# zfs-pair-gate -- the peer-side security gate for ONE backup relationship.
#
# Why it exists
# -------------
# Logical pause (REV-20260804-045) stops MANAGED jobs: snapget/snapsend carry
# `-L <label>` and skip when the collector's own marker says paused. That is
# orchestration, and it is honest about its limit -- a human who types the
# transfer command by hand, omitting -L, is not stopped by anything.
#
# DISABLED is the other half (ADR-0012): a state on the PEER, enforced by the
# peer, so a manual command carrying no local hint at all is still refused.
# The peer can enforce it because the peer is the one being asked to read data:
# it identifies the relationship from the authenticated KEY, not from anything
# the caller says.
#
# Where the identity comes from
# -----------------------------
# The relationship label arrives as $1, from the forced-command line that root
# wrote into the account's authorized_keys at enrolment:
#
#     command="/usr/local/sbin/zfs-pair-gate <label>",restrict ssh-ed25519 AAAA...
#
# so it is a property of the KEY, not of the session. $SSH_ORIGINAL_COMMAND --
# everything the caller chose -- is never consulted before the disabled check,
# and never at all for deciding WHICH relationship this is. That ordering is
# the whole security property: a caller cannot rename itself out of a block.
#
# What it does NOT do (deliberately, for now)
# -------------------------------------------
# When the relationship is ACTIVE this gate is a pass-through: it runs the
# requested command exactly as sshd would have. It is NOT a command allowlist
# for the active case. Narrowing what an active relationship may run is a
# separate, much larger change (every zfs list/snapshot/send/hold/release/
# bookmark/destroy/receive -A/hostname/command -v shape the engine emits today,
# plus the compressor pipeline) and it would risk breaking live transfers for
# reasons having nothing to do with disable. ADR-0012 asks the gate to "check
# DISABLED before parsing or executing the requested ZFS operation" -- that is
# what this does. Tightening the ACTIVE case can come later, on its own
# evidence.
#
# When the relationship is DISABLED, only the control verbs below are allowed,
# and they cannot move data. The owner chose (2026-08-06) to keep the control
# channel reachable through this same authenticated gate rather than requiring
# an administrator physically on the peer -- both ends of every relationship in
# this estate belong to one operator, see the campaign plan. REV-045's own
# guidance sanctions exactly this shape ("a narrowly permitted resume verb
# through the same authenticated gate").
#
# WHAT THAT MEANS, PLAINLY -- do not let anyone claim more for this later:
# `PAIR-CONTROL enable` runs as the delegated account, so the relationship's
# OWN key can lift its own block. DISABLED therefore stops:
#
#   * every scheduled job of that relationship;
#   * every manual transfer command, including one that omits -L entirely
#     (proved live: snapget refused, zero snapshots created on the source);
#   * every accidental or automated re-run,
#
# and it records every lift in syslog. It is NOT a boundary against someone
# who holds the relationship key and deliberately decides to lift it: they
# can, in one command, and the log will say so. Making it that boundary needs
# a SEPARATE admin key whose forced command permits control verbs while the
# backup key never can -- considered and declined on 2026-08-06 in favour of
# the simpler operation. If the threat model ever changes, that is the change
# to make; nothing else here needs to move.
#
# Mechanically this means the relationship's state directory is writable by
# its own account (the removal below is an unlink IN that directory), while
# the parent stays root-owned so no relationship can reach another's state.
# A directory that is NOT writable makes enable fail loudly rather than
# silently pretend -- see the PAIR_CONTROL_FAILED branch.
#
# Exit codes -- stable, and deliberately distinct so the collector can tell
# these four apart (docs/design/pair-pause.md "Diagnostics"):
#
#     93  PAIR_DISABLED       the relationship exists and is disabled
#     92  PAIR_UNKNOWN        no such relationship on this host
#     91  PAIR_GATE_MISUSE    malformed invocation / missing label (a
#                             misconfigured authorized_keys line, not a caller
#                             error)
#    255  (from ssh itself)   connection or authentication failure
#
# Anything else is the wrapped command's own exit status, unchanged.

set -u

VERSION='v1.0'

RC_MISUSE=91
RC_UNKNOWN=92
RC_DISABLED=93

# Same directory the collector-side logical pause uses, on the peer this time.
# /var/lib, never /run or /tmp: a disable that a reboot silently cleared would
# be the worst possible failure mode for a security state.
RELATIONSHIPS_DIR="${RELATIONSHIPS_DIR:-/var/lib/zfs-snapshot-all/relationships}"
GATE_LOG="${GATE_LOG:-/var/log/zfs-pair-gate.log}"

# One line per decision. Never the command's data, never a key: the label, the
# time, the decision, and a coarse class of what was asked. Best-effort -- a
# gate that refuses to work because it cannot write its log would turn a log
# permission problem into a backup outage.
#
# syslog FIRST, file second. This runs as the delegated ACCOUNT (a forced
# command runs as the ssh user, not root), which cannot write a root-owned
# file in /var/log -- and an audit trail the audited principal can rewrite is
# a weak one anyway. logger(1) hands the line to the daemon, which appends it
# where the account cannot reach.
#
# The whole thing runs in a SUBSHELL with stderr closed, and that placement is
# the point: `printf >> file 2>/dev/null` does NOT hide a failure to open the
# file, because the shell reports that itself, before printf exists, on the
# shell's own stderr. Found live on metropolis pve2 2026-08-06 -- every single
# gated command answered with "/var/log/zfs-pair-gate.log: Permission denied"
# on the caller's stderr, and snapget.sh puts the tail of stderr straight into
# its alert mail. A logging detail would have become alert noise on every run.
gate_log() {
    (
        if command -v logger >/dev/null 2>&1; then
            logger -t zfs-pair-gate -- "gate=$VERSION label=${1:-?} decision=${2:-?} ${3:-}"
        else
            printf '%s gate=%s label=%s decision=%s %s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$VERSION" "${1:-?}" "${2:-?}" "${3:-}" \
                >> "$GATE_LOG"
        fi
    ) >/dev/null 2>&1 || :
}

if [ "${1:-}" = "-V" ] || [ "${1:-}" = "--version" ]; then
    echo "$VERSION"
    exit 0
fi

LABEL="${1:-}"
if [ -z "$LABEL" ]; then
    echo "PAIR_GATE_MISUSE: this gate must be invoked from an authorized_keys forced command carrying a relationship label" >&2
    gate_log "-" misuse "reason=no-label"
    exit "$RC_MISUSE"
fi
case "$LABEL" in
    *[!A-Za-z0-9._-]*)
        echo "PAIR_GATE_MISUSE: relationship label '$LABEL' is not a valid label (letters, digits, dot, dash, underscore only)" >&2
        gate_log "$LABEL" misuse "reason=bad-label"
        exit "$RC_MISUSE" ;;
esac

STATE_DIR="$RELATIONSHIPS_DIR/$LABEL"
# An unknown relationship fails CLOSED. The alternative -- treating "no state
# directory" as "not disabled, carry on" -- would mean a gate that a single
# removed directory turns off completely, which is the fail-open shape this
# project keeps finding in its own history.
if [ ! -d "$STATE_DIR" ]; then
    echo "PAIR_UNKNOWN: no relationship '$LABEL' is enrolled on this host" >&2
    gate_log "$LABEL" unknown "reason=no-state-dir"
    exit "$RC_UNKNOWN"
fi

# THE ordering that matters: the disabled marker is read before
# $SSH_ORIGINAL_COMMAND is looked at for any purpose whatsoever.
DISABLED=0
[ -f "$STATE_DIR/disabled" ] && DISABLED=1

REQ="${SSH_ORIGINAL_COMMAND:-}"

if [ "$DISABLED" -eq 1 ]; then
    # Control verbs only. The protocol is a fixed literal string, not a
    # command: there is nothing here to quote, split, or smuggle a second
    # statement into, and neither verb can read or write a dataset.
    case "$REQ" in
        "PAIR-CONTROL status")
            reason=""
            [ -r "$STATE_DIR/disabled" ] && reason=$(sed -n 's/^DISABLED_REASON="\(.*\)"$/\1/p' "$STATE_DIR/disabled" 2>/dev/null)
            at=$(sed -n 's/^DISABLED_AT="\(.*\)"$/\1/p' "$STATE_DIR/disabled" 2>/dev/null)
            printf 'PAIR_STATE=DISABLED\nPAIR_LABEL=%s\nDISABLED_AT=%s\nDISABLED_REASON=%s\n' \
                "$LABEL" "${at:-unknown}" "${reason:-}"
            gate_log "$LABEL" control "verb=status"
            exit 0 ;;
        "PAIR-CONTROL enable")
            if rm -f "$STATE_DIR/disabled"; then
                printf 'PAIR_STATE=ACTIVE\nPAIR_LABEL=%s\n' "$LABEL"
                gate_log "$LABEL" control "verb=enable result=enabled"
                exit 0
            fi
            echo "PAIR_CONTROL_FAILED: could not remove $STATE_DIR/disabled" >&2
            gate_log "$LABEL" control "verb=enable result=failed"
            exit "$RC_DISABLED" ;;
    esac
    # Everything else -- every data-plane command, every unrecognised string,
    # an empty command (an interactive shell) included.
    echo "PAIR_DISABLED: relationship $LABEL is disabled by administrator" >&2
    gate_log "$LABEL" refused "class=$(printf '%s' "$REQ" | cut -c1-40 | tr -c 'A-Za-z0-9 ._/-' '?')"
    exit "$RC_DISABLED"
fi

# ---- ACTIVE ---------------------------------------------------------------
# A control verb answered while active too, so the collector can ask "is this
# relationship disabled?" without having to be refused to find out.
case "$REQ" in
    "PAIR-CONTROL status")
        printf 'PAIR_STATE=ACTIVE\nPAIR_LABEL=%s\n' "$LABEL"
        gate_log "$LABEL" control "verb=status"
        exit 0 ;;
    "PAIR-CONTROL enable")
        printf 'PAIR_STATE=ACTIVE\nPAIR_LABEL=%s\n' "$LABEL"
        gate_log "$LABEL" control "verb=enable result=already-active"
        exit 0 ;;
esac

# An interactive session (no command) is not part of this relationship's job.
# Refusing it costs nothing -- the account is a backup principal, not a login
# -- and it keeps the key from being a general-purpose shell.
if [ -z "$REQ" ]; then
    echo "PAIR_GATE_MISUSE: this key runs backup commands for relationship $LABEL; it is not an interactive login" >&2
    gate_log "$LABEL" misuse "reason=interactive"
    exit "$RC_MISUSE"
fi

gate_log "$LABEL" allowed "class=$(printf '%s' "$REQ" | cut -c1-40 | tr -c 'A-Za-z0-9 ._/-' '?')"
# Pass-through, exactly as sshd would have run it without a forced command:
# the caller's own shell, the caller's own quoting, the caller's own exit code.
exec /bin/bash -c "$REQ"
