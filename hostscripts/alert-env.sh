# alert-env.sh -- the alert scripts' shared config/env preamble. Sourced, never
# executed, by notify-fail.sh, notify-warn.sh, alert-digest.sh and (on its
# fallback path) check-pool-capacity.sh, from the directory each of them is
# installed in: root's /root/scripts, a delegated account's $HOME. deploy.sh
# installs it beside them from this file, byte for byte.
#
# Until 2026-09-03 this text was a deploy.sh variable interpolated into three
# generated scripts, because a script generated from a heredoc had nothing to
# source. Now that the scripts are files in the checkout, so is this.
# The ENVIRONMENT wins over the config file. Sourcing the config last looks
# harmless until you notice these are exactly the knobs a test sets: a run with
# ZFS_ALERT_QUEUE pointed at a scratch file silently used the PRODUCTION queue
# instead -- summarised it, mailed it and deleted it. Snapshot the env values
# before the config can overwrite them, then put them back.
_E_MODE="${ZFS_ALERT_MODE:-}"; _E_WMODE="${ZFS_WARN_MODE:-}"
_E_QUEUE="${ZFS_ALERT_QUEUE:-}"; _E_EMAIL="${ZFS_ALERT_EMAIL:-}"
_E_STATE="${ZFS_ALERT_STATE_DIR:-}"
# The two digest knobs obey the same rule. They did not: the file won for them
# while the environment won for the five above, so the SAME config had two
# precedence rules depending on which key you touched -- which is the kind of
# thing that costs an hour when a test run quietly reads production settings.
_E_DAYS="${ZFS_DIGEST_DAYS:-}"; _E_QUIET="${ZFS_DIGEST_QUIET:-}"
CONF="${ZFS_ALERT_CONF:-}"
if [ -z "$CONF" ]; then
    # /etc first: /root is 0700, so a delegated service account (see
    # phase 8) cannot read anything under it. The old in-/root
    # location stays as a fallback so an un-migrated host keeps working.
    for c in /etc/zfs-alert.conf /root/scripts/zfs-alert.conf; do
        [ -r "$c" ] && { CONF="$c"; break; }
    done
fi
# shellcheck disable=SC1090
[ -n "$CONF" ] && . "$CONF"
_restore_env() {
    [ -n "$_E_MODE" ]  && ZFS_ALERT_MODE="$_E_MODE"
    [ -n "$_E_WMODE" ] && ZFS_WARN_MODE="$_E_WMODE"
    [ -n "$_E_QUEUE" ] && ZFS_ALERT_QUEUE="$_E_QUEUE"
    [ -n "$_E_EMAIL" ] && ZFS_ALERT_EMAIL="$_E_EMAIL"
    [ -n "$_E_STATE" ] && ZFS_ALERT_STATE_DIR="$_E_STATE"
    [ -n "$_E_DAYS" ]  && ZFS_DIGEST_DAYS="$_E_DAYS"
    [ -n "$_E_QUIET" ] && ZFS_DIGEST_QUIET="$_E_QUIET"
    return 0
}
_restore_env
