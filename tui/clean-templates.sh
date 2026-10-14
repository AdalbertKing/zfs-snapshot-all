#!/bin/bash
# clean-templates.sh -- sprzątanie configu z szablonów, których nic nie używa (F7 na F5).
#
# X22 (właściciel 2026-10-14): każdy szablon kiedyś zastosowany zostawia w configu swoje
# sekcje; nieużywana sekcja zmieniona ręcznie blokowała potem "Użyj szablonu". Okno NIE ma
# własnej logiki: pyta `zfs-backup.sh clean-templates` (plan) o config każdego konta, na
# którym są relacje, pokazuje, co zniknie, i po "WYKONAJ" uruchamia go z --yes.
#
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka, PYTHON.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "clean-templates: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
WT_BACKTITLE="Nieużywane kopie szablonów -- $(hostname)"
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

geom
info "Nieużywane kopie szablonów" "Sprawdzam, których kopii szablonów nic nie używa (nic nie zmieniam)..."
# Konta: root zawsze (X25) i każde konto z relacjami -- każde ma swój config.
"$ZB" status --json >"$TMPD/st.json" 2>/dev/null || :
mapfile -t USERS < <("$PY" - "$TMPD/st.json" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
# X25 (wlasciciel 2026-10-14): config ROOTA zawsze -- na hoscie bez relacji roota zostaja
# w nim szablony po dawnych relacjach (pve9b: 21), a repliki mieszkaja w nim tez.
seen = ["root"]
for r in d.get("relations") or []:
    if r.get("state") == "removed":
        continue
    u = r.get("local_user") or "root"
    if u not in seen:
        seen.append(u)
print("\n".join(seen))
PYEOF
)
cr=$'\r'; USERS=("${USERS[@]%"$cr"}")   # Python na Windows konczy linie CRLF
words() {   # profile__d30h24__daily -> "d30h24 -- dobowe"; relacja-X -> "własne ustawienia relacji X"
    "$PY" -c '
import sys
T = {"hourly": "godzinowe", "daily": "dobowe", "weekly": "tygodniowe", "monthly": "miesięczne", "yearly": "roczne"}
for t in sys.argv[1:]:
    p = t.split("__")
    if len(p) != 3:
        print("  " + t); continue
    who, tier = p[1], p[2]
    side = ""
    for pre in ("lsrc_", "src_"):
        if tier.startswith(pre):
            tier, side = tier[len(pre):], " (źródło)"
    k = tier.split("_")[-1]
    who = ("własne ustawienia relacji " + who[len("relacja-"):]) if who.startswith("relacja-") else ("szablon " + who)
    print("  %s -- %s%s" % (who, T.get(k, tier), side))
' "$@" | tr -d '\r'
}
: >"$TMPD/plan.txt"; : >"$TMPD/why.txt"; TODO=()
for u in "${USERS[@]}"; do
    rc=0; "$ZB" clean-templates "--local-user=$u" >"$TMPD/o.txt" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'Konto %s -- nie da się sprawdzić:\n  %s\n' "$u" "$(grep -E '^FATAL' "$TMPD/o.txt" | tail -1 | sed 's/^FATAL: //')" >>"$TMPD/why.txt"
        continue
    fi
    grep -q 'nic do zrobienia' "$TMPD/o.txt" && continue
    mapfile -t names < <(sed -n '/szablony, których nic nie używa/,/^plan only/p' "$TMPD/o.txt" | sed -n 's/^  \(\S\+\)$/\1/p')
    [ "${#names[@]}" -gt 0 ] || continue
    cfg="$(sed -n 's/^Config \(.*\) -- szablony, których nic nie używa.*/\1/p' "$TMPD/o.txt" | head -1)"
    { echo "Konto $u, config $cfg -- zniknie ${#names[@]}:"; words "${names[@]}"; echo; } >>"$TMPD/plan.txt"
    TODO+=("$u")
done
if [ -s "$TMPD/why.txt" ]; then
    wt --title "Nieużywane kopie szablonów -- odmowa" --msgbox "$(fold -s -w $((W - 6)) "$TMPD/why.txt")" "$(fit "$(fold -s -w $((W - 6)) "$TMPD/why.txt" | grep -c '')")" "$W"
fi
if [ "${#TODO[@]}" -eq 0 ]; then
    [ -s "$TMPD/why.txt" ] || wt --title "Nieużywane kopie szablonów" --msgbox "Nie ma nieużywanych kopii szablonów -- nic do zrobienia." 8 "$W"
    exit 0
fi
{ echo "PLAN -- nic jeszcze nie zostało zmienione."
  echo "To kopie szablonów zostawione w configu przez dawne relacje i zmiany szablonu;"
  echo "żadna relacja ich już nie używa. Szablony na liście F5 zostają, zadania w cronie"
  echo "się nie zmienią."
  echo; cat "$TMPD/plan.txt"; } >"$TMPD/plan2.txt"
yesno_text "$TMPD/plan2.txt" "Nieużywane kopie szablonów -- plan" "WYKONAJ" "Wstecz" --defaultno || exit 0
clear 2>/dev/null
RC=0
for u in "${TODO[@]}"; do
    echo "\$ $ZB clean-templates --local-user=$u --yes"; echo
    "$ZB" clean-templates "--local-user=$u" --yes 2>&1 | tee -a "$TMPD/run.log"; r=${PIPESTATUS[0]}
    [ "$r" -eq 0 ] || RC=$r
done
if [ -n "${ZFS_TUI_LOG:-}" ]; then
    { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null || :
fi
echo
if [ "$RC" -eq 0 ]; then echo "=== GOTOWE: nieużywane kopie szablonów usunięte. Enter = dalej"
else echo "=== NIE UDAŁO SIĘ (rc=$RC) -- ten config nie został zmieniony; powód w linii FATAL powyżej. Enter = dalej"; fi
[ -t 0 ] && read -r _
exit "$RC"
