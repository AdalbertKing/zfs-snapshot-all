#!/bin/bash
# replica-delete.sh NAZWA -- usuwanie repliki w oknach whiptail (Del na F6).
#
# Jak okno usuwania relacji: NIE ma własnej logiki. Pyta tylko, czy skasować też KOPIĘ
# na nośniku (domyślnie NIE -- remove-replica celowo ją zostawia), pokazuje PLAN obu
# czasowników i po "WYKONAJ" uruchamia je z --yes. Kolejność: najpierw
# purge-replica-copy (czyta sekcję [replica:] -- po remove-replica już by jej nie było),
# potem remove-replica; gdy kasowanie kopii nie wyjdzie, replika ZOSTAJE.
#
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "replica-delete: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
NAME="${1:-}"
[ -n "$NAME" ] || { echo "użycie: replica-delete.sh NAZWA" >&2; exit 2; }
WT_BACKTITLE="Usuwanie repliki $NAME -- kolektor $(hostname)"
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

geom
info "Usuń replikę $NAME" "Sprawdzam replikę i jej nośnik..."
"$ZB" list-replicas --json >"$TMPD/rep.json" 2>"$TMPD/rep.err" || echo '{"replicas":[]}' >"$TMPD/rep.json"
# rep.tsv: dst <TAB> źródła(,) <TAB> stan nośnika
"$PY" - "$TMPD/rep.json" "$NAME" >"$TMPD/rep.tsv" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
for r in d.get("replicas", []):
    if r.get("name") == sys.argv[2]:
        print("\t".join([r.get("dst") or "-", ",".join(r.get("sources") or [r.get("source") or ""]) or "-", r.get("present") or "unknown"]))
PYEOF
if ! IFS=$'\t' read -r DST SRCS PRESENT <"$TMPD/rep.tsv"; then
    wt --title "Nie ma repliki '$NAME'" --msgbox "W configu tego kolektora nie ma [replica:$NAME]." 8 "$W"
    exit 1
fi

PURGE=OFF
while :; do
    geom
    case "$PRESENT" in
        here|available)
            items=(purge "SKASUJ KOPIĘ na nośniku: $DST/{${SRCS}} (nieodwracalne)" "$PURGE")
            note="Nośnik jest w maszynie ($([ "$PRESENT" = here ] && echo zaimportowany || echo 'w slocie'))." ;;
        *)
            items=()
            note="Nośnika nie ma w maszynie -- kopii nie da się teraz skasować. Usunięcie repliki\nją zostawia; skasujesz ją później, z dyskiem w slocie:\n  zfs-backup.sh purge-replica-copy $NAME --dst=$DST --source=$SRCS" ;;
    esac
    if [ "${#items[@]}" -gt 0 ]; then
        wt --title "Usuń replikę $NAME -- co jeszcze?" --ok-button "Dalej" --cancel-button "Wstecz" --notags --separate-output \
           --checklist "Replika przestanie działać: zniknie jej sekcja i zadanie z crona.\n$note\n\nSpacja = zaznacz. Kopii domyślnie NIE ruszam." 14 "$W" 1 \
           "${items[@]}" || { clear 2>/dev/null; echo "replica-delete: przerwane, nic nie zmieniono"; exit 1; }
        PURGE=OFF; [ "$WT_OUT" = purge ] && PURGE=ON
    else
        wt --title "Usuń replikę $NAME" --yes-button "Dalej" --no-button "Wstecz" \
           --yesno "Replika przestanie działać: zniknie jej sekcja i zadanie z crona.\n\n$note" 13 "$W" \
           || { clear 2>/dev/null; echo "replica-delete: przerwane, nic nie zmieniono"; exit 1; }
    fi
    info "Usuń replikę $NAME" "Liczę plan..."
    {
        echo "PLAN -- nic jeszcze nie zostało zmienione:"
        echo
        if [ "$PURGE" = ON ]; then
            # Bez obcinania: przy kasowaniu danych plan pokazuje WSZYSTKO, co zniknie
            # (długa lista przełącza okno w przewijanie -- lepsze niż ukryta pozycja).
            echo "1. Kopia na nośniku ($DST) -- KASOWANIE, nieodwracalne:"
            "$ZB" purge-replica-copy "$NAME" 2>&1 | sed 's/^/   /' | grep -v '^   *$'
            echo
            echo "2. Replika:"
        else
            echo "Replika (kopia na nośniku ZOSTAJE):"
        fi
        echo "   zfs-backup.sh remove-replica $NAME --install"
        echo
        echo "Komendy:"
        [ "$PURGE" = ON ] && echo "  $(shq "$ZB") purge-replica-copy $NAME --yes"
        echo "  $(shq "$ZB") remove-replica $NAME --install --yes"
    } >"$TMPD/plan.txt"
    yesno_text "$TMPD/plan.txt" "Usuń replikę $NAME -- plan" "WYKONAJ" "Wstecz" --defaultno || continue
    clear 2>/dev/null
    RC=0
    if [ "$PURGE" = ON ]; then
        echo "\$ $ZB purge-replica-copy $NAME --yes"; echo
        "$ZB" purge-replica-copy "$NAME" --yes 2>&1 | tee "$TMPD/run.log"; RC=${PIPESTATUS[0]}
        if [ "$RC" -ne 0 ]; then
            echo
            echo "=== ZATRZYMANE: kasowanie kopii nie wyszło (rc=$RC) -- replika ZOSTAŁA, nic dalej nie ruszono. Enter = dalej"
            [ -n "${ZFS_TUI_LOG:-}" ] && { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null
            [ -t 0 ] && read -r _
            exit "$RC"
        fi
        echo
    fi
    echo "\$ $ZB remove-replica $NAME --install --yes"; echo
    "$ZB" remove-replica "$NAME" --install --yes 2>&1 | tee -a "$TMPD/run.log"; RC=${PIPESTATUS[0]}
    [ -n "${ZFS_TUI_LOG:-}" ] && { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null
    echo
    if [ "$RC" -eq 0 ]; then echo "=== GOTOWE: replika '$NAME' usunięta$([ "$PURGE" = ON ] && echo ' razem z kopią na nośniku') (rc=0). Enter = dalej"
    else echo "=== NIE UDAŁO SIĘ (rc=$RC) -- powód w linii FATAL powyżej. Enter = dalej"; fi
    [ -t 0 ] && read -r _
    exit "$RC"
done
