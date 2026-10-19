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
_E_COOL="${ZFS_ALERT_COOLDOWN:-}"; _E_CAP="${ZFS_CAPACITY_THRESHOLD:-}"
# THE HOST SETTINGS FILE (2026-10-19, owner: "nowy plik ustawień z sekcjami", edited
# with F10 in the GUI). Its [alerts] and [capacity] keys win over zfs-alert.conf --
# the GUI writes only this file, so what the admin set there must be what runs --
# and the environment still wins over both (the suites pin values that way).
# Read with awk here, not lib-cron.sh's settings_get: these scripts are installed
# beside the alert queue, away from the checkout.
_ZS_FILE="${SETTINGS_FILE:-/etc/zfs-snapshot-all/settings.ini}"
_zs() {   # <section> <key> -> value or nothing
    [ -r "$_ZS_FILE" ] || return 0
    awk -F= -v s="$1" -v k="$2" '
        BEGIN { cur = "engine" }
        { sub(/#.*/, "") }
        /^[ \t]*\[[A-Za-z0-9_]+\][ \t]*$/ { cur = $0; gsub(/[][ \t]/, "", cur); next }
        { kk = $1; gsub(/^[ \t]+|[ \t]+$/, "", kk)
          if (cur == s && kk == k && NF > 1) { v = $0; sub(/^[^=]*=/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit } }' "$_ZS_FILE" 2>/dev/null
}
_v=$(_zs alerts email);        [ -n "$_v" ] && ZFS_ALERT_EMAIL="$_v"
_v=$(_zs alerts errors);       [ -n "$_v" ] && ZFS_ALERT_MODE="$_v"
_v=$(_zs alerts warnings);     [ -n "$_v" ] && ZFS_WARN_MODE="$_v"
_v=$(_zs alerts all_ok_mail);  [ -n "$_v" ] && ZFS_DIGEST_QUIET="$_v"
_v=$(_zs alerts stats_days);   [ -n "$_v" ] && ZFS_DIGEST_DAYS="$_v"
_v=$(_zs capacity threshold);  [ -n "$_v" ] && ZFS_CAPACITY_THRESHOLD="$_v"
_v=$(_zs alerts repeat_after)
case "$_v" in
    *[0-9]h) ZFS_ALERT_COOLDOWN=$(( ${_v%h} * 3600 )) ;;
    *[0-9]m) ZFS_ALERT_COOLDOWN=$(( ${_v%m} * 60 )) ;;
    *[0-9])  ZFS_ALERT_COOLDOWN="$_v" ;;
esac
unset _v
_restore_env() {
    [ -n "$_E_COOL" ]  && ZFS_ALERT_COOLDOWN="$_E_COOL"
    [ -n "$_E_CAP" ]   && ZFS_CAPACITY_THRESHOLD="$_E_CAP"
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
