#!/bin/bash
# delete-relation.sh NAZWA -- usuwanie relacji w oknach whiptail (Del na F3).
#
# Właściciel 2026-09-20: "Musi być obsłużone z GUI pauzowanie i usuwanie relacji (...)
# logicznie pakiet musi być spójny." Dialog NIE ma własnej logiki usuwania: pyta o to,
# o co pyta `zfs-backup.sh delete-relation` (źródło / nazwa / kopie), pokazuje PLAN tego
# czasownika i po "WYKONAJ" uruchamia go z --yes. To, co czasownik pomija na podstawie
# dowodu (źródło dzielone z inną relacją, rekord już `removed`), nie jest tu do wyboru.
#
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "delete-relation: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
NAME="${1:-}"
[ -n "$NAME" ] || { echo "użycie: delete-relation.sh NAZWA" >&2; exit 2; }
WT_BACKTITLE="Usuwanie relacji $NAME -- kolektor $(hostname)"
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

geom
info "Usuń relację $NAME" "Sprawdzam, co jest do usunięcia..."
if ! "$ZB" delete-relation "$NAME" >"$TMPD/plan0.txt" 2>&1; then
    wt --title "Nie da się usunąć '$NAME'" --msgbox "$(tail -5 "$TMPD/plan0.txt")" 12 "$W"
    exit 1
fi
# Co czasownik zrobi SAM z siebie, a co pominie na dowodzie -- z jego własnego planu.
line() { grep -m1 "^  $1\. " "$TMPD/plan0.txt" | sed 's/^  [0-9]\. [a-zA-Z]* *: //'; }
SRC_LINE="$(line 2)"; COPIES="$(line 4 | sed -n 's/^KEPT on this host (\(.*\)) --.*/\1/p')"
STATE="$(sed -n "s/^delete-relation '.*' (state=\([^,]*\),.*/\1/p" "$TMPD/plan0.txt")"
PEER="$(sed -n "s/^delete-relation '.*' (state=[^,]*, peer=\([^)]*\)).*/\1/p" "$TMPD/plan0.txt")"

SRC=ON; REC=ON; DATA=OFF
while :; do
    geom
    items=()
    case "$SRC_LINE" in
        skipped*) note_src="Źródło ($PEER): bez zmian -- ${SRC_LINE#skipped -- }" ;;
        *)        note_src=""; items+=(src "Posprzątaj na źródle $PEER (konto i prawa zfs)" "$SRC") ;;
    esac
    items+=(rec "Zwolnij nazwę '$NAME' (żeby dało się założyć ją od nowa)" "$REC")
    [ -n "$COPIES" ] && items+=(data "SKASUJ KOPIE na tym hoście (nieodwracalne)" "$DATA")
    head="Relacja '$NAME' (stan: ${STATE:-?}) przestanie działać: znikną jej zadania z crona."
    [ "$STATE" = removed ] && head="Relacja '$NAME' jest już usunięta -- zostało po niej to, co niżej."
    wt --title "Usuń relację $NAME -- co jeszcze?" --ok-button "Dalej" --cancel-button "Wstecz" --notags --separate-output \
       --checklist "$head\n${note_src:+$note_src\n}\n${COPIES:+Kopie na tym hoście: $COPIES\n}Spacja = zaznacz/odznacz. Kopii domyślnie NIE ruszam." "$(fit $((${#items[@]} / 3 + 6)))" "$W" "$((${#items[@]} / 3))" \
       "${items[@]}" || { clear 2>/dev/null; echo "delete-relation: przerwane, nic nie zmieniono"; exit 1; }
    SRC=OFF; REC=OFF; DATA=OFF
    while IFS= read -r x; do case "$x" in src) SRC=ON ;; rec) REC=ON ;; data) DATA=ON ;; esac; done <<<"$WT_OUT"
    ARGV=("$ZB" delete-relation "$NAME")
    case "$SRC_LINE" in skipped*) ;; *) [ "$SRC" = ON ] || ARGV+=(--keep-source) ;; esac
    [ "$REC" = ON ] || ARGV+=(--keep-record)
    [ "$DATA" = ON ] && ARGV+=(--destroy-copies)
    "${ARGV[@]}" >"$TMPD/plan.txt" 2>&1
    {
        echo "PLAN -- nic jeszcze nie zostało zmienione:"
        echo
        grep -v '^plan only' "$TMPD/plan.txt"
        echo
        echo "Komenda:  $(for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done)--yes"
    } >"$TMPD/plan2.txt"
    yesno_text "$TMPD/plan2.txt" "Usuń relację $NAME -- plan" "WYKONAJ" "Wstecz" --defaultno || continue
    clear 2>/dev/null
    echo "\$ $(for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done)--yes"; echo
    "${ARGV[@]}" --yes; RC=$?
    echo
    if [ "$RC" -eq 0 ]; then echo "=== GOTOWE: relacja '$NAME' usunięta (rc=0). Enter = dalej"
    else echo "=== USUNIĘTA Z POZOSTAŁOŚCIAMI (rc=$RC) -- linie '!!!' powyżej mówią, co zostało. Enter = dalej"; fi
    [ -t 0 ] && read -r _
    exit "$RC"
done
