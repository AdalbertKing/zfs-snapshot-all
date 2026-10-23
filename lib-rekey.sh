# shellcheck shell=bash
# lib-rekey.sh -- A RAW RECOVERY COMES BACK LOCKED; it gets its key again here.
#
# Owner, 2026-10-23: "po odzysku raw wykonaj load-key i change-key -i automatycznie" --
# and the same whether the recovery was remote or local: a recovery is a stressful
# moment, so no extra step and no nuance for the admin.
#
# A copy received raw goes back raw, and ZFS makes every dataset received that way its
# OWN encryption root, key unavailable, keylocation=prompt (measured on pve9:
# hdd/restore/docs-raw and hdd/enc/docs2 from hdd/enc/docs). The key lives only on the
# recovered machine, so this runs as root THERE:
#   deploy.sh      -- a recovery onto this machine from another one: at --deny-restore;
#   zfs-restore.sh -- a recovery onto the machine it runs on: right after it lands.
#
# Only a dataset that is its own root, locked, with keylocation=prompt is touched, and
# only with a key file this machine already has: `load-key` succeeds only with the SAME
# key, so a dataset deliberately encrypted with another key is left alone (reported).
# Under an encrypted, open parent it then inherits that parent's key (change-key -i);
# otherwise it keeps its own root and gets the key file as keylocation, so it opens at
# boot like the original. Never fails the caller.

rekey_raw_recovered() {   # <key locations, space-separated> <dataset roots...> -> "OK <text>" / "WARN <text>" lines
    local keys="$1" _rk_ds _rk_k _rk_par _rk_pe _rk_pk _rk_done
    shift
    [ -n "$keys" ] && [ "$#" -gt 0 ] || return 0
    for _rk_ds in $( { for _rk_r in "$@"; do zfs list -H -o name -r -t filesystem,volume -- "$_rk_r" 2>/dev/null; done; } | sort -u ); do
        [ "$(zfs get -H -o value encryptionroot -- "$_rk_ds" 2>/dev/null)" = "$_rk_ds" ] || continue
        [ "$(zfs get -H -o value keystatus -- "$_rk_ds" 2>/dev/null)" = unavailable ] || continue
        # A raw receive leaves keylocation=prompt. A root with a key file of its own is
        # somebody's deliberate encryption, not a recovery -- skipped, not reported.
        [ "$(zfs get -H -o value keylocation -- "$_rk_ds" 2>/dev/null)" = prompt ] || continue
        _rk_done=""
        for _rk_k in $keys; do
            zfs load-key -L "$_rk_k" -- "$_rk_ds" 2>/dev/null || continue
            _rk_par="${_rk_ds%/*}"
            _rk_pe="$(zfs get -H -o value encryption -- "$_rk_par" 2>/dev/null)"
            _rk_pk="$(zfs get -H -o value keystatus -- "$_rk_par" 2>/dev/null)"
            if [ "$_rk_par" != "$_rk_ds" ] && [ -n "$_rk_pe" ] && [ "$_rk_pe" != off ] && [ "$_rk_pk" = available ]; then
                if zfs change-key -i -- "$_rk_ds" 2>/dev/null; then
                    echo "OK $_rk_ds opened and now inherits the key of $(zfs get -H -o value encryptionroot -- "$_rk_ds" 2>/dev/null) (it came back raw, as its own root)"
                else
                    echo "WARN $_rk_ds opened with $_rk_k, but 'zfs change-key -i' failed -- it stays its own root; it opens with that key"
                fi
            elif zfs set keylocation="$_rk_k" "$_rk_ds" 2>/dev/null; then   # no "--": zfs set takes it for a dataset
                echo "OK $_rk_ds opened with $_rk_k and keeps it as its keylocation (its parent is not encrypted, so it stays its own root)"
            else
                echo "WARN $_rk_ds opened with $_rk_k, but its keylocation could not be set -- after a reboot: zfs load-key -L $_rk_k $_rk_ds"
            fi
            _rk_done=1
            break
        done
        [ -n "$_rk_done" ] || echo "WARN $_rk_ds is locked with keylocation=prompt (a raw recovery) and no key on this machine opens it -- open it by hand: zfs load-key $_rk_ds"
    done
    return 0
}

# Every key file this machine's encryption roots point at -- what a LOCAL recovery may
# have come from. Only roots carry a keylocation; inheriting datasets say "none".
rekey_host_keys() {   # -> key locations, space-separated
    zfs get -H -o value -t filesystem,volume keylocation 2>/dev/null | grep '^file://' | sort -u | tr '\n' ' '
}
