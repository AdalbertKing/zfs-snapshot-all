#!/bin/bash
# replica-delete.sh NAZWA -- usuwanie repliki w oknach whiptail (Del na F6).
#
# Jak okno usuwania relacji: NIE ma własnej logiki. Pokazuje PLAN i po "WYKONAJ"
# uruchamia remove-replica z --yes. DANE NA DYSKACH ZOSTAJĄ, bez wyjątku (właściciel,
# W12, 2026-10-11): opcja "skasuj kopię na nośniku" znikła -- nośnik wymienny zwykle
# leży poza maszyną, więc i tak się nie udawała, a kasowanie kopii zapasowej przy
# okazji usuwania definicji to za łatwa strata. Kto chce wyczyścić dysk, formatuje go
# (zmiana repliki -> "Dodaj dysk"). Czasownika do kasowania kopii na nośniku nie ma
# (właściciel 2026-10-18: "nie chcemy tego").
#
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "replica-delete: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
NAME="${1:-}"
[ -n "$NAME" ] || { echo "usage: replica-delete.sh NAME" >&2; exit 2; }
WT_BACKTITLE="$(Tv 'Usuwanie repliki $NAME -- kolektor $(hostname)' '$NAME' "$NAME" '$(hostname)' "$(hostname)")"
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

geom
info "$(Tv 'Usuń replikę $NAME' '$NAME' "$NAME")" "$(T 'Sprawdzam replikę i jej nośnik...')"
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
# Czy po usunięciu TEJ repliki jakakolwiek inna rusza po włożeniu dysku? Jeśli nie, a reguła
# udev jest na hoście, plan ją zdejmuje (właściciel 2026-10-18: wyłączyć to, co się włączyło).
OTHERS_ON=$("$PY" - "$TMPD/rep.json" "$NAME" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
print("yes" if any(r.get("name") != sys.argv[2] and (r.get("schedule") == "on-insert" or r.get("on_insert") == "yes")
                   for r in d.get("replicas", [])) else "no")
PYEOF
)
RULES="${ZFS_REPLICA_RULES:-/etc/udev/rules.d/90-zfs-replica.rules}"
UNTRIG=no
[ "$OTHERS_ON" = no ] && grep -qs 'Managed by zfs-backup.sh install-media-trigger' "$RULES" && UNTRIG=yes
if ! IFS=$'\t' read -r DST SRCS PRESENT <"$TMPD/rep.tsv"; then
    wt --title "$(Tv 'Nie ma repliki '\''$NAME'\''' '$NAME' "$NAME")" --msgbox "$(Tv 'W configu tego kolektora nie ma [replica:$NAME].' '$NAME' "$NAME")" 8 "$W"
    exit 1
fi

while :; do
    geom
    wt --title "$(Tv 'Usuń replikę $NAME' '$NAME' "$NAME")" --yes-button "$(T Dalej)" --no-button "$(T Wstecz)" \
       --yesno "$(Tv 'Replika przestanie działać: zniknie jej sekcja i zadanie z crona.\n\nDane na dyskach repliki ZOSTAJĄ ($DST).\nŻeby je skasować, sformatuj dysk: zmiana repliki -> Dodaj dysk.' '$DST' "$DST")" 12 "$W" \
       || { clear 2>/dev/null; wt_end_nochange "$(T 'Usuń replikę: przerwane, nic nie zmieniono')"; exit 1; }
    {
        echo "$(T 'PLAN -- nic jeszcze nie zostało zmienione:')"
        echo
        echo "$(Tv 'Replika $NAME: sekcja i zadanie z crona znikają; dane na dyskach ZOSTAJĄ.' '$NAME' "$NAME")"
        echo
        if [ "$UNTRIG" = yes ]; then
            echo "$(T 'Reguła udev "po podłączeniu" ZOSTANIE ZDJĘTA -- żadna inna replika z niej nie korzysta.')"
            echo
        fi
        echo "$(T 'Komenda:')"
        echo "  $(shq "$ZB") remove-replica $NAME --install --yes"
        [ "$UNTRIG" = yes ] && echo "  $(shq "$ZB") remove-media-trigger --install"
    } >"$TMPD/plan.txt"
    yesno_text "$TMPD/plan.txt" "$(Tv 'Usuń replikę $NAME -- plan' '$NAME' "$NAME")" "$(T WYKONAJ)" "$(T Wstecz)" --defaultno || continue
    : >"$TMPD/run.log"
    RC=0; run_progress "$(Tv 'Usuń replikę $NAME' '$NAME' "$NAME")" "$TMPD/run.log" "$ZB" remove-replica "$NAME" --install --yes || RC=$?
    if [ "$RC" -eq 0 ] && [ "$UNTRIG" = yes ]; then
        run_progress "$(Tv 'Usuń replikę $NAME' '$NAME' "$NAME")" "$TMPD/run.log" "$ZB" remove-media-trigger --install || RC=$?
    fi
    [ -n "${ZFS_TUI_LOG:-}" ] && { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null
    if [ "$RC" -eq 0 ]; then
        Tv 'GOTOWE: replika '\''$NAME'\'' usunięta, dane na dyskach zostały (rc=0).' '$NAME' "$NAME" >"$TMPD/result.txt"
        result_box "$(Tv 'Usuń replikę $NAME: GOTOWE' '$NAME' "$NAME")" 0 "$TMPD/run.log" "$(cat "$TMPD/result.txt")"
    else
        T 'Replika nie została usunięta.' >"$TMPD/result.txt"
        result_box "$(Tv 'Usuń replikę $NAME' '$NAME' "$NAME")" "$RC" "$TMPD/run.log" "" "$(cat "$TMPD/result.txt")"
    fi
    exit "$RC"
done
