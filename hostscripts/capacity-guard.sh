#!/bin/bash
# capacity-guard.sh -- BEZPIECZNIK POJEMNOŚCI (U35, właściciel 2026-10-20).
#
# Wzór: a-tassa, gdzie cron przy zajętości 89 % kasuje najstarsze migawki. Tutaj tak
# samo, ale tylko to, co bezpiecznie usunąć:
#   - tylko NASZE rodziny: [<prefiks>_]automated_<szczebel>_... (nie __replicate_ pvesr,
#     nie vzdump, nie replica_, nie cudze ani ręczne migawki);
#   - nigdy migawka pod hold (np. zfssnapall_inflight -- trwa transfer);
#   - w każdym datasecie i szczeblu zostaje N najnowszych (guard_min_keep, domyślnie 2):
#     najnowsze to wspólna baza z drugą stroną relacji -- jej usunięcie = pełna kopia od
#     zera akurat wtedy, gdy brakuje miejsca;
#   - od NAJDROBNIEJSZEGO szczebla (godzinowe, dobowe, tygodniowe, miesięczne, roczne),
#     w szczeblu od najstarszej -- nie "najstarsze w ogóle", które zjadałyby najpierw
#     roczne i miesięczne, czyli najcenniejszą historię;
#   - po każdym usunięciu pomiar zajętości (zpool sync); stop poniżej guard_target albo,
#     gdy nie ma już czego bezpiecznie usunąć -- wtedy alert "nie dało się".
#
# Ustawienia (settings.ini [capacity], F10; środowisko wygrywa -- alert-env.sh):
#   guard = off|on (ZFS_GUARD, domyślnie off -- decyzja właściciela), guard_at = 89
#   (ZFS_GUARD_AT), guard_target = 85 (ZFS_GUARD_TARGET), guard_min_keep = 2
#   (ZFS_GUARD_MIN_KEEP).
# Użycie: capacity-guard.sh [--plan]  -- --plan: co by poszło, nic nie usuwa (działa
# także przy guard = off).
# Działa na źródle i na kolektorze (właściciel 2026-10-20: "W źródle i w celu").
set -u
PLAN=0
case "${1:-}" in --plan) PLAN=1 ;; "") ;; *) echo "użycie: capacity-guard.sh [--plan]" >&2; exit 2 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -r "$HERE/alert-env.sh" ] && . "$HERE/alert-env.sh"
GUARD="${ZFS_GUARD:-off}"
AT="${ZFS_GUARD_AT:-89}";       case "$AT" in ''|*[!0-9]*) AT=89 ;; esac
TARGET="${ZFS_GUARD_TARGET:-85}"; case "$TARGET" in ''|*[!0-9]*) TARGET=85 ;; esac
KEEP="${ZFS_GUARD_MIN_KEEP:-2}"; case "$KEEP" in ''|*[!0-9]*|0) KEEP=2 ;; esac
[ "$TARGET" -lt "$AT" ] || TARGET=$((AT - 1))
NOTIFY="${ZFS_NOTIFY_SCRIPT:-/root/scripts/notify-fail.sh}"
HOST="$(hostname -s 2>/dev/null || hostname)"

if [ "$GUARD" != on ] && [ "$PLAN" -eq 0 ]; then exit 0; fi

# Jeden bezpiecznik naraz: cron co 15 min, a czyszczenie dużej puli trwa.
exec 9>"${ZFS_GUARD_LOCK:-/run/lock/zfs-capacity-guard.lock}" 2>/dev/null && flock -n 9 2>/dev/null || { [ "$PLAN" -eq 1 ] || exit 0; }

say() { echo "$(date '+%Y-%m-%d %H:%M:%S') capacity-guard: $*"; }
alert() {   # <temat> <treść>
    if [ -x "$NOTIFY" ]; then "$NOTIFY" "$1" "$2" 2>/dev/null && return 0; fi
    command -v mail >/dev/null 2>&1 && printf '%s\n' "$2" | mail -s "[ZFS CAPACITY] $1" "${ZFS_ALERT_EMAIL:-root}" 2>/dev/null
    return 0
}
cap_of() { zpool list -H -o capacity "$1" 2>/dev/null | tr -d '% '; }
tier_rank() { case "$1" in hourly) echo 1 ;; daily) echo 2 ;; weekly) echo 3 ;; monthly) echo 4 ;; yearly) echo 5 ;; *) echo 9 ;; esac; }

# Kandydaci w puli: "szczebel<TAB>creation<TAB>nazwa" dla naszych rodzin bez holdów,
# poza N najnowszymi w (dataset, rodzina). Kolejność: szczebel, potem najstarsze.
candidates() {   # <pula>
    zfs list -H -p -t snapshot -o name,creation,userrefs -r "$1" 2>/dev/null \
    | awk -F'\t' -v keep="$KEEP" '
        {
            n = $1; ds = n; sub(/@.*/, "", ds); s = n; sub(/^[^@]*@/, "", s)
            if (!match(s, /^([A-Za-z0-9.-]+_)?automated_(hourly|daily|weekly|monthly|yearly)_/)) next
            t = s; sub(/^([A-Za-z0-9.-]+_)?automated_/, "", t); sub(/_.*/, "", t)
            fam = substr(s, 1, RLENGTH)
            if ($3 + 0 > 0) { held[ds SUBSEP fam]++ ; next }   # pod hold -- nietykalna
            k = ds SUBSEP fam; cnt[k]++; NAME[k, cnt[k]] = n; CR[k, cnt[k]] = $2; TIER[k] = t
        }
        END {
            for (k in cnt) {
                # NAJNOWSZE zostają: sortuj po creation, wypisz wszystkie poza "keep" ostatnimi
                m = cnt[k]
                for (i = 1; i <= m; i++) { o[i] = i }
                for (i = 2; i <= m; i++) { j = i; while (j > 1 && CR[k, o[j-1]] + 0 > CR[k, o[j]] + 0) { x = o[j]; o[j] = o[j-1]; o[j-1] = x; j-- } }
                for (i = 1; i <= m - keep; i++) print TIER[k] "\t" CR[k, o[i]] "\t" NAME[k, o[i]]
            }
        }' \
    | while IFS=$'\t' read -r t c n; do printf '%s\t%s\t%s\n' "$(tier_rank "$t")" "$c" "$n"; done \
    | sort -t "$(printf '\t')" -k1,1n -k2,2n | cut -f3
}

rc=0
for pool in $(zpool list -H -o name 2>/dev/null); do
    cap="$(cap_of "$pool")"; case "$cap" in ''|*[!0-9]*) continue ;; esac
    if [ "$PLAN" -eq 0 ] && [ "$cap" -lt "$AT" ]; then continue; fi
    list="$(candidates "$pool")"
    if [ "$PLAN" -eq 1 ]; then
        echo "Pula $pool: zajętość ${cap}%, bezpiecznik ${GUARD} (czyści od ${AT}% do ${TARGET}%, zostaje ${KEEP} najnowszych w szczeblu)"
        if [ -z "$list" ]; then echo "  nic do usunięcia (tylko najnowsze, migawki pod hold albo cudze)"; continue; fi
        echo "  usuwałby w tej kolejności, aż zajętość spadnie poniżej ${TARGET}%:"
        printf '%s\n' "$list" | head -40 | sed 's/^/    /'
        [ "$(printf '%s\n' "$list" | grep -c .)" -gt 40 ] && echo "    ... razem $(printf '%s\n' "$list" | grep -c .)"
        continue
    fi
    say "pula $pool ${cap}% >= ${AT}% -- czyszczę do ${TARGET}%"
    gone=""; n=0
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        if zfs destroy "$s" 2>/dev/null; then
            n=$((n + 1)); gone="$gone
  $s"
            say "usunięta $s"
        else
            say "nie dało się usunąć $s (pomijam)"
            continue
        fi
        zpool sync "$pool" 2>/dev/null
        cap="$(cap_of "$pool")"
        case "$cap" in ''|*[!0-9]*) break ;; esac
        [ "$cap" -lt "$TARGET" ] && break
    done <<EOF
$list
EOF
    if [ "$cap" -lt "$TARGET" ] 2>/dev/null; then
        say "pula $pool teraz ${cap}% -- usunięto migawek: $n"
        alert "$HOST: bezpiecznik wyczyścił pulę $pool (${cap}%)" "Pula $pool przekroczyła ${AT}%. Bezpiecznik usunął najstarsze migawki (sztuk: $n) (od najdrobniejszego szczebla, ${KEEP} najnowsze w każdym zostały) i zajętość spadła do ${cap}%.
Usunięte:$gone"
    else
        rc=1
        say "pula $pool dalej ${cap}% -- usunięto migawek: $n, więcej bezpiecznie się nie da"
        alert "$HOST: bezpiecznik NIE zwolnił puli $pool (${cap}%)" "Pula $pool: ${cap}% (próg ${AT}%, cel ${TARGET}%). Usunięto migawek: $n; zostały tylko najnowsze (${KEEP} w szczeblu), migawki pod hold i nie nasze (np. __replicate_, vzdump, ręczne).
Potrzebna decyzja człowieka: więcej miejsca, krótsza retencja albo usunięcie danych.
Usunięte:${gone:- nic}"
    fi
done
exit "$rc"
