#!/bin/bash
# fastprune-lib.sh -- U136 FASTPRUNE, wspólne dla kreatora relacji (Zaawansowane) i
# "Zmień relację" (migawki zdalne). Właściciel 2026-11-04: Zaawansowane, „jedno pole”.
#
# Źródło bez miejsca: każdy szczebel wybranego szablonu żyje na źródle N godzin
# (retain = -h<N>, czyszczenie co godzinę); monitor zostaje tylko szczeblom częstszym niż N --
# wieku rzadszych pilnuje archiwum (kopia pasywna z repliki na kolektorze).
#
# Wołający ustawia: ZB, PY, TMPD, W (wt-lib.sh) i plik $TMPD/prof.json (list-profiles --json).
#
# Kreator: szablon fastprune to ukryta KOPIA szablonu bazowego (fp_save), użyta raz, przy
# zakładaniu. Okno zmiany relacji czyta i zmienia CONFIG (fp_cfg, fp_ops -> set-tiers) i żadnego
# szablonu nie czyta (REV-20261104-187 runda 3).

# fp_ask <obecne N albo ""> [edit] -> FP_ANS (N albo ""); rc 1 = Wstecz. Kreator: puste = bez
# krótkiej retencji. "edit" (okno zmiany relacji): puste = bez zmiany -- to okno jej nie wyłącza.
fp_ask() {
    local v="$1" ask bad
    if [ "${2:-}" = edit ]; then
        ask="$(T 'Ile godzin żyje na źródle każda migawka (wszystkie szczeble). Puste = bez zmiany.\nCzyszczenie co godzinę; monitor zostaje tylko szczeblom częstszym niż ta liczba --\nwieku rzadszych pilnuje archiwum (kopia pasywna z repliki na kolektorze).')"
        bad="$(T 'Liczba godzin: same cyfry, puste = bez zmiany.')"
    else
        ask="$(T 'Ile godzin żyje na źródle każda migawka (wszystkie szczeble). Puste = wyłączone.\nCzyszczenie co godzinę; monitor zostaje tylko szczeblom częstszym niż ta liczba --\nwieku rzadszych pilnuje archiwum (kopia pasywna z repliki na kolektorze).')"
        bad="$(T 'Liczba godzin: same cyfry, puste = wyłączone.')"
    fi
    while :; do
        geom
        wt --title "$(T 'Krótka retencja źródła')" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" \
           --inputbox "$ask" 12 "$W" "$v" || return 1
        v="${WT_OUT// /}"
        case "$v" in
            ''|0) FP_ANS=""; return 0 ;;
            *[!0-9]*) wt --title "$(T 'Zła liczba')" --msgbox "$bad" 8 "$W"; continue ;;
        esac
        v=$((10#$v))
        if [ "$v" -lt 4 ]; then
            wt --title "$(T 'Za mało')" --msgbox "$(T 'Najmniej 4 godziny: replika pvesr co 2 h musi zdążyć przenieść migawkę dwa razy.')" 8 "$W"; continue
        fi
        if [ "$v" -lt 24 ]; then
            wt --title "$(T 'Mniej niż doba')" --yes-button "$(T Dalej)" --no-button "$(T Wstecz)" \
               --yesno "$(Tv 'Migawka dobowa przeżyje na źródle tylko $v godz. Jeśli replika albo archiwum stoją dłużej, migawka zniknie, zanim trafi do archiwum.' '$v' "$v")" 10 "$W" || continue
        fi
        FP_ANS="$v"; return 0
    done
}

fp_of() {   # <szablon> -> "N base" z jego znacznika fastprune, albo nic
    "$PY" - "$TMPD/prof.json" "$1" <<'PYEOF' | tr -d '\r'
import sys, json, re
d = json.load(open(sys.argv[1], encoding="utf-8"))
for p in d.get("profiles", []):
    if p.get("name") == sys.argv[2]:
        m = re.search(r"\[fastprune (\d+) base=([^\]\s]+)\]", p.get("description") or "")
        if m:
            print(m.group(1), m.group(2))
PYEOF
}

fp_save() {   # <bazowy szablon> <N> <nazwa ukrytego> <relacja> -> 0 zapisany; 1 = błąd (okno pokazane)
    local base="$1" n="$2" name="$3" rel="$4" args=()
    mapfile -t args < <("$PY" - "$TMPD/prof.json" "$base" "$n" <<'PYEOF'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8")); name = sys.argv[2]; n = int(sys.argv[3])
def every(s):   # odstęp send_schedule w godzinach
    f = s.split()
    if len(f) < 5: return 8760
    m, h, dom, mon, dow = f[:5]
    if h == "*": return 1
    if h.startswith("*/") and h[2:].isdigit(): return int(h[2:])
    if dow != "*": return 168
    if dom == "*" and mon == "*": return 24
    if mon == "*": return 744
    return 8760
for p in d.get("profiles", []):
    if p.get("name") != name: continue
    for t in p.get("tiers", []):
        if not t.get("send_schedule"): continue
        print("--tier=" + t["name"]); print("--retain=-h%d" % n); print("--keep=")
        print("--prune_schedule=21 * * * *")
        if every(t["send_schedule"]) >= n:
            print("--monitor_warn="); print("--monitor_crit=")
PYEOF
)
    if [ "${#args[@]}" -eq 0 ]; then
        wt --title "$(T 'Krótka retencja niemożliwa')" --msgbox "$(Tv 'Szablon $PROFILE nie ma szczebli, które robią migawki -- krótka retencja nie ma czego skracać.' '$PROFILE' "$base")" 9 "$W"; return 1
    fi
    if ! "$ZB" save-profile "--from=$base" "--as=$name" --hidden --force \
         "--description=$(Tv 'Krótka retencja $FASTPRUNE h z $PROFILE (relacja $RNAME)' '$FASTPRUNE' "$n" '$PROFILE' "$base" '$RNAME' "$rel") [fastprune $n base=$base]" \
         "${args[@]}" >/dev/null 2>"$TMPD/fp.err"; then
        wt --title "$(T 'Krótka retencja: szablonu nie zapisano')" --msgbox "$(tail -4 "$TMPD/fp.err")" 14 "$W"; return 1
    fi
    return 0
}

# U136 / REV-20261104-187 runda 3: krótka retencja źródła czytana z CONFIGU relacji (show-tiers),
# nie z ukrytego szablonu: N, gdy każdy szczebel z migawkami trzyma `retain = -h<N>` (to samo N)
# i czyści co godzinę. fp_cfg <plik show-tiers.json> -> N albo nic.
fp_cfg() {
    "$PY" - "$1" <<'PYEOF' 2>/dev/null | tr -d '\r'
import sys, json, re
try:
    t = [x for x in json.load(open(sys.argv[1], encoding="utf-8")).get("target", []) if x.get("send_schedule")]
except Exception:
    sys.exit(0)
ns = set()
for x in t:
    m = re.match(r"^-h([0-9]+)$", x.get("retain") or "")
    if not m or not re.match(r"^\S+ \* \* \* \*$", x.get("prune_schedule") or ""):
        sys.exit(0)
    ns.add(m.group(1))
if len(ns) == 1:
    print(ns.pop())
PYEOF
}
# fp_ops <plik show-tiers.json> <N> -> słowa set-tiers, jedno w linii: każdy szczebel z migawkami
# trzyma N godzin i czyści co godzinę (minuta czyszczenia zostaje z configu, bez niej 21); szczebel, którego
# odstęp jest co najmniej N, traci progi monitora (U136). Reszta configu zostaje, jak jest.
fp_ops() {
    "$PY" - "$1" "$2" <<'PYEOF' 2>/dev/null | tr -d '\r'
import sys, json
n = int(sys.argv[2])
def every(c):
    f = (c or "").split()
    if len(f) < 5: return 0
    mi, h, dom, mon, dow = f[:5]
    if h == "*": return 1
    if h.startswith("*/"): return int(h[2:]) if h[2:].isdigit() else 1
    if dow != "*": return 168
    if dom != "*" and mon == "*": return 744
    if dom == "*" and mon == "*": return 24
    return 8760
for x in json.load(open(sys.argv[1], encoding="utf-8")).get("target", []):
    if not x.get("send_schedule"): continue
    print("--tier=" + x["name"]); print("--retain=-h%d" % n)
    m = ((x.get("prune_schedule") or "").split() or ["21"])[0]
    print("--prune-schedule=%s * * * *" % m)
    if every(x["send_schedule"]) >= n and (x.get("monitor_warn") or x.get("monitor_crit")):
        print("--monitor-warn="); print("--monitor-crit=")
PYEOF
}
