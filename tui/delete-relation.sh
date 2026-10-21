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
if ! "$ZB" delete-relation "$NAME" --check-source >"$TMPD/plan0.txt" 2>&1; then
    wt --title "Nie da się usunąć '$NAME'" --msgbox "$(tail -5 "$TMPD/plan0.txt")" 12 "$W"
    exit 1
fi
# Co czasownik zrobi SAM z siebie, a co pominie na dowodzie -- z jego własnego planu.
line() { grep -m1 "^  $1\. " "$TMPD/plan0.txt" | sed 's/^  [0-9]\. [a-zA-Z]* *: //'; }
SRC_LINE="$(line 2)"; COPIES="$(line 4 | sed -n 's/^KEPT on this host (\(.*\)) --.*/\1/p')"
STATE="$(sed -n "s/^delete-relation '.*' (state=\([^,]*\),.*/\1/p" "$TMPD/plan0.txt")"
PEER="$(sed -n "s/^delete-relation '.*' (state=[^,]*, peer=\([^)]*\)).*/\1/p" "$TMPD/plan0.txt")"
LEAVE_CMD="$(printf '%s' "$SRC_LINE" | sed -n 's/.* as root: \(.*--leave=[^ ]*\).*/\1/p')"

SRC=ON; REC=ON; DATA=OFF
while :; do
    geom
    items=()
    # U16 (właściciel 2026-10-19): bez dostępu roota stąd do źródła sprzątanie źródła
    # i tak by nie wyszło (czasownik staje w połowie) -- nie proponujemy go, mówimy,
    # co zrobić ręcznie na źródle; usunięcie idzie z --keep-source.
    case "$SRC_LINE" in
        skipped*) note_src="Źródło ($PEER): bez zmian -- ${SRC_LINE#skipped -- }" ;;
        "NO root"*) note_src="Źródło ($PEER): brak dostępu roota z tego hosta -- tam zostaje konto relacji. Posprzątaj ręcznie, na $PEER jako root: $LEAVE_CMD" ;;
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
    : >"$TMPD/run.log"
    RC=0; run_progress "Usuń relację $NAME" "$TMPD/run.log" "${ARGV[@]}" --yes || RC=$?
    # Uwaga 5 (właściciel, 2026-09-24): usunięcie zostawia ślad jak import -- GUI podaje
    # ZFS_TUI_LOG z nagłówkiem "$ komenda"; tu dopisujemy przebieg kroków i rc.
    if [ -n "${ZFS_TUI_LOG:-}" ]; then
        { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null || :
    fi
    # Dwa różne niepowodzenia, dwa różne komunikaty. Odkąd nieudana połowa ŹRÓDŁA
    # zatrzymuje czasownik przed purge (REV-144), rekord ZOSTAJE -- i wtedy "usunięta
    # z pozostałościami" jest nieprawdą: nazwa nadal jest zajęta, kopie stoją, a ta
    # sama komenda jest do powtórzenia. Rozpoznajemy to po zdaniu, które wypisuje.
    if [ "$RC" -eq 0 ]; then
        { echo "GOTOWE: relacja '$NAME' usunięta (rc=0)."
          case "$SRC_LINE" in "NO root"*) echo "    Na $PEER zostało konto relacji -- tam, jako root: $LEAVE_CMD" ;; esac
        } >"$TMPD/result.txt"
        result_box "Usuń relację $NAME: GOTOWE" 0 "$TMPD/run.log" "$(cat "$TMPD/result.txt")"
    elif grep -q 'STOPPED before 3/4' "$TMPD/run.log" 2>/dev/null; then
        { echo "ZATRZYMANE: połowa na źródle nie wyszła, więc NIC dalej nie ruszono."
          echo "    Rekord relacji '$NAME' ZOSTAŁ -- nazwa jest nadal zajęta, kopie stoją."
          echo "    Gdy źródło będzie dostępne, uruchom to samo jeszcze raz."
        } >"$TMPD/result.txt"
        result_box "Usuń relację $NAME" "$RC" "$TMPD/run.log" "" "$(cat "$TMPD/result.txt")"
    else
        echo "USUNIĘTA Z POZOSTAŁOŚCIAMI -- linie '!!!' w dzienniku mówią, co zostało." >"$TMPD/result.txt"
        result_box "Usuń relację $NAME" "$RC" "$TMPD/run.log" "" "$(cat "$TMPD/result.txt")"
    fi
    exit "$RC"
done
