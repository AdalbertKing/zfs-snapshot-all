#!/bin/bash
set -uo pipefail

SUT="${1:-./zfs-backup.sh}"
[ -r "$SUT" ] || { echo "usage: $0 /path/to/zfs-backup.sh" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
touch "$WORK/client.conf"
CAPTURE="$WORK/ssh.args"

# Load the production command, then replace only durable-record reads and the
# network boundary. No remote command is executed and no product file is written.
# shellcheck disable=SC1090
source "$SUT"
client_conf_path() { printf '%s\n' "$WORK/client.conf"; }
record_get() { printf '%s\n' backup; }
record_load() {
    PEER_HOST=lan.example
    STATE=active
    ACTIVE_ENDPOINT=vpn.example:2222
    REQUESTED_DATASETS=pool/old
    RUX_MODE=backup
}
rux_root_ssh() {
    printf '%s %s\n' "$1" "$2" > "$CAPTURE"
    return 255
}

read -r active_host active_port <<< "$(
    PEER_HOST=lan.example
    ACTIVE_ENDPOINT=vpn.example:2222
    active_endpoint_host_port
)"

set +e
( cmd_add_source rel pool/new --yes ) > "$WORK/output" 2>&1
rc=$?
set -e
read -r attempted_host attempted_port < "$CAPTURE"

printf 'active_endpoint=%s:%s\n' "$active_host" "$active_port"
printf 'attempted_endpoint=%s:%s\n' "$attempted_host" "$attempted_port"
printf 'command_rc=%s\n' "$rc"

if [ "$active_host:$active_port" = vpn.example:2222 ] \
   && [ "$attempted_host:$attempted_port" = lan.example:2222 ] \
   && [ "$rc" -ne 0 ]; then
    echo 'REPRODUCED: add-source mixed the original host with the active endpoint port'
    exit 0
fi

echo 'NOT REPRODUCED'
cat "$WORK/output"
exit 1
