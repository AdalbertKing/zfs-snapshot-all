#!/bin/bash
# replica-delete.sh NAZWA -- usuwanie repliki w oknach whiptail (Del na F6).
#
# Jak okno usuwania relacji: NIE ma własnej logiki. Pokazuje PLAN i po "WYKONAJ"
# uruchamia remove-replica z --yes. DANE NA DYSKACH ZOSTAJĄ, bez wyjątku (właściciel,
# W12, 2026-10-11): opcja "skasuj kopię na nośniku" znikła -- nośnik wymienny zwykle
# leży poza maszyną, więc i tak się nie udawała, a kasowanie kopii zapasowej przy
# okazji usuwania definicji to za łatwa strata. Kto chce wyczyścić dysk, formatuje go
# (zmiana repliki -> "Dodaj dysk"). Czasownik purge-replica-copy zostaje dla CLI.
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
    wt --title "Nie ma repliki '$NAME'" --msgbox "W configu tego kolektora nie ma [replica:$NAME]." 8 "$W"
    exit 1
fi

while :; do
    geom
    wt --title "Usuń replikę $NAME" --yes-button "Dalej" --no-button "Wstecz" \
       --yesno "Replika przestanie działać: zniknie jej sekcja i zadanie z crona.\n\nDane na dyskach repliki ZOSTAJĄ ($DST).\nŻeby je skasować, sformatuj dysk: zmiana repliki -> Dodaj dysk." 12 "$W" \
       || { clear 2>/dev/null; echo "replica-delete: przerwane, nic nie zmieniono"; exit 1; }
    {
        echo "PLAN -- nic jeszcze nie zostało zmienione:"
        echo
        echo "Replika $NAME: sekcja i zadanie z crona znikają; dane na dyskach ZOSTAJĄ."
        echo
        if [ "$UNTRIG" = yes ]; then
            echo "Reguła udev \"po włożeniu\" ZOSTANIE ZDJĘTA -- żadna inna replika z niej nie korzysta."
            echo
        fi
        echo "Komenda:"
        echo "  $(shq "$ZB") remove-replica $NAME --install --yes"
        [ "$UNTRIG" = yes ] && echo "  $(shq "$ZB") remove-media-trigger --install"
    } >"$TMPD/plan.txt"
    yesno_text "$TMPD/plan.txt" "Usuń replikę $NAME -- plan" "WYKONAJ" "Wstecz" --defaultno || continue
    clear 2>/dev/null
    echo "\$ $ZB remove-replica $NAME --install --yes"; echo
    "$ZB" remove-replica "$NAME" --install --yes 2>&1 | tee "$TMPD/run.log"; RC=${PIPESTATUS[0]}
    if [ "$RC" -eq 0 ] && [ "$UNTRIG" = yes ]; then
        echo; echo "\$ $ZB remove-media-trigger --install"
        "$ZB" remove-media-trigger --install 2>&1 | tee -a "$TMPD/run.log"; RC=${PIPESTATUS[0]}
    fi
    [ -n "${ZFS_TUI_LOG:-}" ] && { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null
    echo
    if [ "$RC" -eq 0 ]; then echo "=== GOTOWE: replika '$NAME' usunięta, dane na dyskach zostały (rc=0). Enter = dalej"
    else echo "=== NIE UDAŁO SIĘ (rc=$RC) -- powód w linii FATAL powyżej. Enter = dalej"; fi
    [ -t 0 ] && read -r _
    exit "$RC"
done
