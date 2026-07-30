#!/bin/bash
# update-control.sh -- self-update/rollback/resume control plane, deployed
# OUTSIDE the git checkout it manages.
#
# REV-20260730-001 F1: the hold/rollback logic used to live entirely inside
# $REPO_DIR/deploy.sh -- the exact tree `--rollback` runs `git reset --hard`
# on. Rolling back from a post-fix revision to a pre-fix one checked out the
# OLD deploy.sh, which knew nothing about the (new, or any) hold, so the very
# next hourly cron tick undid the rollback within the hour. Reproduced live on
# all 4 hosts (pve0/pve1 11.x + metropolis pve1/pve2).
#
# Fix: this file is deployed by deploy.sh's Phase 7 into $UPDATE_STATE_DIR,
# which is root-private (0700) and lives OUTSIDE $REPO_DIR -- `git reset
# --hard $REPO_DIR` cannot touch it no matter what revision is being rolled
# back to or from. Once deployed, BOTH the hourly cron line and deploy.sh's
# own --self-update/--rollback/--resume-updates dispatch exec THIS file
# instead of running the logic built into whatever $REPO_DIR happens to be.
# A rollback can put arbitrarily old (or no) update-control awareness into
# $REPO_DIR/deploy.sh; it cannot touch this copy, so the hold is enforced by
# the same reviewed code regardless of what is checked out.
#
# deploy.sh substitutes the two placeholders below for the host's real paths
# every time it deploys a fresh copy of this file. Manual/test invocation
# overrides them with REPO_DIR/UPDATE_STATE_DIR environment variables,
# exactly like deploy.sh's own self-update test harness does -- see
# test/selfupdate/run.sh.
set -uo pipefail

# Not "$0": when test/selfupdate/run.sh `source`s this file from a differently
# named test-harness script (to reach emergency_disable directly without
# triggering the dispatch at the bottom), "$0" is the SOURCING script's own
# name, not this file's path -- but BASH_SOURCE[0] is always bash's own
# resolved path to whatever file is currently being read, sourced or executed
# alike. Using "$0" here caused a live miss on pve0 (2026-07-30): a test
# invocation shaped `bash -c 'source "$f"; ...'` left $0 as the literal string
# "bash", so emergency_disable's crontab-fallback ran `grep -vF "bash"` for
# real and silently dropped the unrelated `SHELL=/bin/bash` header line from
# the live crontab (restored by hand immediately after).
SELF="${BASH_SOURCE[0]}"

REPO_DIR="${REPO_DIR:-__REPO_DIR__}"
UPDATE_STATE_DIR="${UPDATE_STATE_DIR:-__UPDATE_STATE_DIR__}"
PREV_REV_FILE="$UPDATE_STATE_DIR/previous-revision"
UPDATE_HOLD_FILE="$UPDATE_STATE_DIR/update-hold"

log()  { echo ">>> $*"; }
warn() { echo "!!! $*" >&2; }
die()  { echo "FATAL: $*" >&2; exit 1; }

# Identical semantics to deploy.sh's own copies (kept in sync deliberately --
# see the comment at deploy.sh's UPDATE_STATE_DIR block). Fails closed: a
# symlinked or group/world-writable state directory is treated as
# untrustworthy and stops the caller rather than being used anyway.
ensure_update_state_dir() {
    if [ -L "$UPDATE_STATE_DIR" ]; then
        warn "$UPDATE_STATE_DIR is a symlink -- refusing to follow it. Remove it by hand and re-run: ls -la $UPDATE_STATE_DIR"
        return 1
    fi
    if [ -e "$UPDATE_STATE_DIR" ] && [ ! -d "$UPDATE_STATE_DIR" ]; then
        warn "$UPDATE_STATE_DIR exists and is not a directory -- refusing to use it."
        return 1
    fi
    if [ ! -e "$UPDATE_STATE_DIR" ]; then
        mkdir -m 0700 -p "$UPDATE_STATE_DIR" || { warn "mkdir -p $UPDATE_STATE_DIR failed"; return 1; }
    fi
    local _mode
    _mode=$(stat -c '%a' "$UPDATE_STATE_DIR" 2>/dev/null) || { warn "cannot stat $UPDATE_STATE_DIR"; return 1; }
    if [ $(( 0${_mode} & 0022 )) -ne 0 ]; then
        warn "$UPDATE_STATE_DIR is group- or world-writable (mode $_mode) -- refusing to trust it as update-control state. Fix: chmod 0700 $UPDATE_STATE_DIR"
        return 1
    fi
    return 0
}

write_state_file() {
    local dst="$1" content="$2" tmp
    if [ -L "$dst" ]; then
        warn "$dst is a symlink -- refusing to write through it. Remove it by hand: ls -la $dst"
        return 1
    fi
    tmp=$(mktemp "$UPDATE_STATE_DIR/.tmp.XXXXXX" 2>/dev/null) || { warn "mktemp in $UPDATE_STATE_DIR failed"; return 1; }
    if ! printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
        warn "write to $tmp failed"; rm -f "$tmp"; return 1
    fi
    if ! mv -f "$tmp" "$dst" 2>/dev/null; then
        warn "rename $tmp -> $dst failed"; rm -f "$tmp"; return 1
    fi
    return 0
}

read_state_file() {
    local src="$1"
    if [ -L "$src" ]; then
        warn "$src is a symlink -- refusing to read through it. Remove it by hand: ls -la $src"
        return 1
    fi
    [ -f "$src" ] || return 1
    cat "$src" 2>/dev/null
}

remove_state_file() {
    local dst="$1"
    if [ -L "$dst" ]; then
        warn "$dst is a symlink, not the state file this script wrote -- refusing to remove it automatically. Inspect and remove by hand: ls -la $dst"
        return 1
    fi
    [ -e "$dst" ] || return 0
    rm -f "$dst" 2>/dev/null
}

# REV-20260730-001 F2: several branches used to just `warn` when the hold
# write itself failed, leaving the hourly cron entry free to keep retrying --
# the opposite of the required fail-closed default. This is the last-resort
# escalation for exactly that situation: try the normal hold file first, and
# if that cannot be written, try progressively more drastic ways to make sure
# the next scheduled invocation cannot advance the checkout anyway.
emergency_disable() {
    local reason="$1"
    if write_state_file "$UPDATE_HOLD_FILE" "$reason"; then
        return 0
    fi
    warn "could not write the update hold at $UPDATE_HOLD_FILE -- attempting an emergency circuit breaker instead"
    if chmod 000 "$SELF" 2>/dev/null; then
        warn "removed exec permission on $SELF -- the hourly cron line will now fail closed instead of retrying. Fix $UPDATE_STATE_DIR by hand, then: chmod 0700 $SELF"
        return 0
    fi
    if crontab -l 2>/dev/null | grep -vF "$SELF" | crontab - 2>/dev/null; then
        warn "removed the hourly cron line invoking $SELF as a last-resort circuit breaker -- re-add it by hand once $UPDATE_STATE_DIR is fixed"
        return 0
    fi
    warn "CRITICAL: could not write a hold, could not disable $SELF, could not remove its cron line -- $UPDATE_STATE_DIR needs immediate manual attention or this host will keep retrying hourly"
    return 1
}

do_self_update() {
    [ -d "$REPO_DIR/.git" ] || die "no git checkout at $REPO_DIR"
    ensure_update_state_dir || { warn "refusing to update: $UPDATE_STATE_DIR is not safe to use as update-control state"; return 1; }

    if [ -L "$UPDATE_HOLD_FILE" ]; then
        warn "$UPDATE_HOLD_FILE is a symlink -- treating update-control state as tampered with, refusing to update. Resolve by hand: ls -la $UPDATE_HOLD_FILE"
        return 1
    fi
    if [ -e "$UPDATE_HOLD_FILE" ]; then
        log "updates are HELD ($(read_state_file "$UPDATE_HOLD_FILE")) -- not updating. Resume with: $SELF --resume-updates"
        return 0
    fi
    if [ -L "$PREV_REV_FILE" ]; then
        warn "$PREV_REV_FILE is a symlink -- treating update-control state as tampered with, refusing to update. Resolve by hand: ls -la $PREV_REV_FILE"
        return 1
    fi

    git -C "$REPO_DIR" fetch --quiet origin main 2>/dev/null \
        || { warn "fetch failed -- leaving $REPO_DIR on its current revision"; return 1; }

    local current target
    current=$(git -C "$REPO_DIR" rev-parse HEAD) || return 1
    target=$(git -C "$REPO_DIR" rev-parse FETCH_HEAD) || return 1

    local dirty
    dirty=$(git -C "$REPO_DIR" status --porcelain 2>&1)

    if [ "$current" = "$target" ]; then
        [ -n "$dirty" ] && warn "$REPO_DIR has uncommitted changes -- nothing to update, but this is worth a look: git -C $REPO_DIR status"
        log "already at $(printf '%.8s' "$current") -- nothing to update"
        return 0
    fi

    if [ -n "$dirty" ]; then
        warn "$REPO_DIR is not clean -- refusing to update to $(printf '%.8s' "$target"). Running a mix of reviewed and unreviewed local code as root is exactly what this check exists to prevent. Resolve by hand: git -C $REPO_DIR status"
        return 1
    fi

    local prior=""
    if [ -e "$PREV_REV_FILE" ]; then
        prior=$(read_state_file "$PREV_REV_FILE") || { warn "could not read $PREV_REV_FILE -- refusing to update with an unreadable rollback point"; return 1; }
    fi
    write_state_file "$PREV_REV_FILE" "$current" \
        || { warn "could not durably record $current at $PREV_REV_FILE -- refusing to activate $(printf '%.8s' "$target") without a working rollback point"; return 1; }

    if ! git -C "$REPO_DIR" merge --ff-only "$target" >/dev/null 2>&1; then
        # F2: pointer-restoration failure after a bad fast-forward used to
        # only `warn`, leaving the hourly cron entry able to retry with an
        # uncertain rollback pointer. Escalate through emergency_disable.
        local _restore_ok=1
        if [ -n "$prior" ]; then
            write_state_file "$PREV_REV_FILE" "$prior" || _restore_ok=0
        else
            remove_state_file "$PREV_REV_FILE" || _restore_ok=0
        fi
        if [ "$_restore_ok" -eq 0 ]; then
            warn "fast-forward to $(printf '%.8s' "$target") failed AND the rollback pointer at $PREV_REV_FILE could not be restored -- state is uncertain, holding automatic updates"
            emergency_disable "held automatically: rollback-pointer restore failed after a bad fast-forward on $(date '+%Y-%m-%d %H:%M:%S')" \
                || warn "emergency circuit breaker also failed -- $UPDATE_STATE_DIR needs manual attention before the next hourly run"
        fi
        warn "fast-forward to $(printf '%.8s' "$target") failed -- still on $(printf '%.8s' "$current"). Local modifications in $REPO_DIR are the usual cause: git -C $REPO_DIR status"
        return 1
    fi
    log "updated $(printf '%.8s' "$current") -> $(printf '%.8s' "$target") (rollback point recorded)"
    return 0
}

do_rollback() {
    [ -d "$REPO_DIR/.git" ] || die "no git checkout at $REPO_DIR"
    ensure_update_state_dir || die "$UPDATE_STATE_DIR is not safe to use as update-control state -- see above"
    local target
    target=$(read_state_file "$PREV_REV_FILE") || die "no previous revision recorded at $PREV_REV_FILE (or it is not a plain file) -- nothing to roll back to. Pick a revision by hand: git -C $REPO_DIR log --oneline"
    [ -n "$target" ] || die "$PREV_REV_FILE is empty -- nothing to roll back to"
    local from
    from=$(git -C "$REPO_DIR" rev-parse HEAD) || die "cannot resolve current HEAD in $REPO_DIR"
    git -C "$REPO_DIR" cat-file -e "${target}^{commit}" 2>/dev/null \
        || die "recorded revision $target is not in $REPO_DIR -- resolve by hand"

    write_state_file "$UPDATE_HOLD_FILE" \
        "rollback $(printf '%.8s' "$from") -> $(printf '%.8s' "$target") started $(date '+%Y-%m-%d %H:%M:%S')" \
        || die "could not record an update hold at $UPDATE_HOLD_FILE -- refusing to roll back without one. Fix $UPDATE_STATE_DIR and retry."

    if ! git -C "$REPO_DIR" reset --hard "$target" >/dev/null 2>&1; then
        # F2: this used to discard the re-write's own failure (2>/dev/null,
        # no check). If the reset itself failed AND the hold message can't
        # even be refreshed, escalate instead of silently trusting the
        # original (now possibly stale) hold to still be doing its job.
        emergency_disable "rollback to $(printf '%.8s' "$target") FAILED at $(date '+%Y-%m-%d %H:%M:%S') -- checkout may be inconsistent, held for manual investigation" \
            || warn "emergency circuit breaker also failed after a failed reset -- $UPDATE_STATE_DIR needs manual attention immediately"
        die "git reset --hard $target failed -- automatic updates remain HELD, investigate $REPO_DIR by hand"
    fi

    write_state_file "$UPDATE_HOLD_FILE" \
        "rolled back from $(printf '%.8s' "$from") to $(printf '%.8s' "$target") on $(date '+%Y-%m-%d %H:%M:%S')" \
        || warn "rollback succeeded but could not refresh the hold message at $UPDATE_HOLD_FILE (the hold from before the reset is still in place)"

    log "rolled back $(printf '%.8s' "$from") -> $(printf '%.8s' "$target")"
    log "AUTOMATIC UPDATES ARE NOW HELD -- without this the next hourly run would pull the same revision straight back."
    log "When the fix is on main:  $SELF --resume-updates"
    return 0
}

do_resume_updates() {
    ensure_update_state_dir || die "$UPDATE_STATE_DIR is not safe to use as update-control state -- see above"
    if [ -L "$UPDATE_HOLD_FILE" ]; then
        die "$UPDATE_HOLD_FILE is a symlink -- refusing to touch it. Resolve by hand: ls -la $UPDATE_HOLD_FILE"
    fi

    local had_hold=0 hold_content=""
    if [ -e "$UPDATE_HOLD_FILE" ]; then
        had_hold=1
        hold_content=$(read_state_file "$UPDATE_HOLD_FILE")
        log "removing update hold ($hold_content)"
        remove_state_file "$UPDATE_HOLD_FILE" || die "could not remove $UPDATE_HOLD_FILE -- hold left in place, refusing to update"
        [ -e "$UPDATE_HOLD_FILE" ] && die "removal of $UPDATE_HOLD_FILE did not take effect -- hold left in place, refusing to update"
    else
        log "no update hold in place -- nothing to resume"
    fi

    do_self_update
    local rc=$?
    # F2: an explicit --resume-updates that turns around and fails must not
    # leave the host silently eligible for hourly retries -- restore the hold
    # (or escalate) rather than defaulting open.
    if [ "$rc" -ne 0 ] && [ "$had_hold" -eq 1 ]; then
        warn "the explicit update after --resume-updates failed -- restoring the hold rather than leaving automatic updates enabled"
        emergency_disable "restored after a failed --resume-updates on $(date '+%Y-%m-%d %H:%M:%S') -- previous hold was: $hold_content" \
            || warn "emergency circuit breaker also failed after a failed resume -- automatic updates may retry hourly. Investigate $UPDATE_STATE_DIR by hand."
    fi
    return "$rc"
}

# Guarded so test/selfupdate/run.sh can `source` this file to reach the
# functions above (e.g. emergency_disable) without also running the dispatch
# below -- a real invocation (`bash update-control.sh --self-update`, or cron
# exec'ing it directly) always has BASH_SOURCE[0] == $0 and is unaffected.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --self-update)    do_self_update;    exit $? ;;
        --rollback)       do_rollback;       exit $? ;;
        --resume-updates) do_resume_updates; exit $? ;;
        *) die "usage: $0 --self-update|--rollback|--resume-updates" ;;
    esac
fi
