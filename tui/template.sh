#!/bin/bash
# template.sh <new|edit|delete> NAZWA -- szablon retencji w oknach whiptail (F5 Szablony:
# Ins = nowy na podstawie NAZWY, 'e' = zmiana własnego, Del = usunięcie własnego).
#
# Okno NIE ma własnej logiki: pyta o liczby, a zapis robi `zfs-backup.sh save-profile`
# (--from/--as, --tier + --keep albo --retain) i `delete-profile`. Harmonogram i sposób
# trzymania (płaski/wiekowy/GFS) oraz układ szczebli idą z szablonu bazowego -- okno
# pyta tylko o to, ile czego trzymać. Szablon fabryczny jest nie do zmiany ani usunięcia.
#
# template.sh relation BAZA PLIK [TYTUŁ] -- ta sama tabela dla RELACJI (P4, właściciel
# 2026-10-09: "Harmonogram i retencja kopii w celu i źródle" w "Zmień relację" i "Ręcznie" w kreatorze):
# bez nazwy i opisu, bez planu i zapisu -- argumenty save-profile idą do PLIK (jeden na
# linię), linie planu do PLIK.plan; zapis ukrytego szablonu relacji robi wołający.
#
# Wyjście: 0 = zrobione albo nie było czego robić, 1 = przerwane/nie wyszło, 2 = zły argument.
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka.
set -u

ACTION="${1:-}"; NAME="${2:-}"; ROUT="${3:-}"; RTITLE="${4:-}"
case "$ACTION" in new|edit|delete) ;; relation) [ -n "$ROUT" ] || { echo "usage: template.sh relation BASE FILE [TITLE]" >&2; exit 2; } ;;
    *) echo "usage: template.sh <new|edit|delete> NAME" >&2; exit 2 ;; esac
[ -n "$NAME" ] || { echo "usage: template.sh <new|edit|delete> NAME" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "template: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
WT_BACKTITLE="$(Tv 'Szablony -- kolektor $(hostname)' '$(hostname)' "$(hostname)")"
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

geom
info "$(T Szablony)" "$(T 'Czytam szablony...')"
# TEMPLATE_JSON (relacja, właściciel 2026-10-13): szczeble relacji z jej CONFIGU (show-tiers),
# podane przez wołającego w kształcie list-profiles -- bez ukrytego szablonu po drodze.
if [ -n "${TEMPLATE_JSON:-}" ] && [ -r "$TEMPLATE_JSON" ]; then cp "$TEMPLATE_JSON" "$TMPD/p.json"
else "$ZB" list-profiles --json --no-render >"$TMPD/p.json" 2>"$TMPD/p.err" || echo '{"profiles":[]}' >"$TMPD/p.json"; fi
# me.tsv: źródło, used_by, opis; tiers.tsv: szczebel, keep, retain; names.txt: wszystkie nazwy.
# Każde pole z przedrostkiem '#' (puste pola zlałyby się przy IFS=tab); przedrostek zdejmuje czytający.
"$PY" - "$TMPD/p.json" "$NAME" "$TMPD" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
name, tmpd = sys.argv[2], sys.argv[3]
def f(v):
    s = "" if v is None else str(v)
    return "#" + s.replace("\t", " ").replace("\r", " ").replace("\n", " ")
names = open(tmpd + "/names.txt", "w", encoding="utf-8")
me = open(tmpd + "/me.tsv", "w", encoding="utf-8")
tiers = open(tmpd + "/tiers.tsv", "w", encoding="utf-8")
for p in d.get("profiles", []):
    names.write((p.get("name") or "") + "\n")
    if p.get("name") == name:
        me.write("\t".join([f(p.get("source")), f(p.get("used_by")), f(p.get("description"))]) + "\n")
        for t in p.get("tiers") or []:
            tiers.write("\t".join([f(t.get("name")), f(t.get("keep")), f(t.get("retain")),
                                   f(t.get("quiesce")), f(t.get("send_schedule")), f(t.get("pattern")),
                                   f(t.get("mechanism"))]) + "\n")
PYEOF

SRC=""; USED=0; BDESC=""
if [ -s "$TMPD/me.tsv" ]; then
    IFS=$'\t' read -r SRC USED BDESC <"$TMPD/me.tsv"
    SRC="${SRC#\#}"; USED="${USED#\#}"; BDESC="${BDESC#\#}"
else
    wt --title "$(T Szablony)" --msgbox "$(Tv 'Nie ma szablonu '\''$NAME'\''.' '$NAME' "$NAME")" 8 "$W"
    exit 1
fi
case "$USED" in ''|*[!0-9]*) USED=0 ;; esac

SHADOW_MSG="$(Tv 'Plik szablonu '\''$NAME'\'' w /etc/zfs-snapshot-all/profiles ma nazwę fabrycznego i pakiet go pomija. Zmień nazwę pliku.' '$NAME' "$NAME")"

# Wspólny ogon wykonania: <komunikat sukcesu> <polecenie...>
run_cmd() {
    local okmsg="$1" a line="" RC
    shift
    for a in "$@"; do line="$line$(shq "$a") "; done
    clear 2>/dev/null
    echo "\$ $line"; echo
    "$@" 2>&1 | tee "$TMPD/run.log"; RC=${PIPESTATUS[0]}
    if [ -n "${ZFS_TUI_LOG:-}" ]; then
        { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null || :
    fi
    echo
    if [ "$RC" -eq 0 ]; then Tv '=== GOTOWE: $okmsg (rc=$RC). Enter = dalej' '$okmsg' "$okmsg" '$RC' "$RC"; echo
    else Tv '=== NIE UDAŁO SIĘ (rc=$RC) -- powód powyżej. Enter = dalej' '$RC' "$RC"; echo; fi
    [ -t 0 ] && read -r _
    exit "$RC"
}

# ---------------------------------------------------------------- usuwanie
if [ "$ACTION" = delete ]; then
    case "$SRC" in
        package) wt --title "$(T 'Szablon fabryczny')" --msgbox "$(T 'Fabrycznego szablonu nie usuniesz.')" 8 "$W"; exit 0 ;;
        shadow)  wt --title "$(T 'Szablon fabryczny')" --msgbox "$SHADOW_MSG" 10 "$W"; exit 0 ;;
    esac
    "$ZB" delete-profile "$NAME" >"$TMPD/dplan.txt" 2>&1
    if [ $? -ne 0 ]; then
        tail -5 "$TMPD/dplan.txt" | fold -s -w $((W - 6)) >"$TMPD/why.txt"
        wt --title "$(T 'Czasownik odmówił -- nic nie zmieniono')" --msgbox "$(cat "$TMPD/why.txt")" "$(fit "$(grep -c '' "$TMPD/why.txt")")" "$W"
        exit 1
    fi
    {
        cat "$TMPD/dplan.txt"
        if [ "$USED" -gt 0 ]; then
            echo
            T 'Relacje utworzone z tego szablonu zostaną i będą działać dalej. Później nie odświeżysz ich jednak przez '\''Zmień relację -> Szablon'\'', bo tego szablonu już nie będzie.'; echo
        fi
    } >"$TMPD/dtext.txt"
    yesno_text "$TMPD/dtext.txt" "$(Tv 'Usunięcie szablonu $NAME' '$NAME' "$NAME")" "$(T Usuń)" "$(T Wstecz)" --defaultno || exit 1
    run_cmd "$(Tv 'szablon '\''$NAME'\'' usunięty' '$NAME' "$NAME")" "$ZB" delete-profile "$NAME" --yes
fi

# ---------------------------------------------------------------- new / edit
if [ "$ACTION" = relation ]; then
    NEW="${RTITLE:-$(T 'Harmonogram i retencja kopii w celu i źródle')}"
    TITLE="$NEW"
elif [ "$ACTION" = edit ]; then
    case "$SRC" in
        package) wt --title "$(T 'Szablon fabryczny')" --msgbox "$(Tv 'Fabrycznego szablonu '\''$NAME'\'' nie zmienisz -- Ins na nim tworzy kopię, którą można zmienić.' '$NAME' "$NAME")" 9 "$W"; exit 0 ;;
        shadow)  wt --title "$(T 'Szablon fabryczny')" --msgbox "$SHADOW_MSG" 10 "$W"; exit 0 ;;
    esac
    NEW="$NAME"
    TITLE="$(Tv 'Zmiana szablonu $NAME' '$NAME' "$NAME")"
else
    NEW="$NAME-moj"
    TITLE="$(Tv 'Nowy szablon na podstawie $NAME' '$NAME' "$NAME")"
fi

# JEDNO OKNO-TABELA (właściciel 2026-10-09: "Uprośćmy tworzenie szablonów" -- jak w
# menedżerach migawek QNAP/Synology): nazwa, szczeble (włącz / ile trzyma / zamrażanie)
# i opis w tui/grid.py (curses -- wyjątek od whiptail, whiptail nie ma takiego wiersza).
# Potem plan i WYKONAJ jak dotąd. Zapis robi save-profile; okno niczego nie zapisuje.
GRID_CMD="${ZFS_GRID:-$PY $HERE/tui/grid.py}"
SPEC="$TMPD/spec.json"; OUTJ="$TMPD/grid.json"
"$PY" - "$TMPD/tiers.tsv" "$TMPD/names.txt" "$ACTION" "$NAME" "$NEW" "$BDESC" "$SPEC" <<'PYEOF'
import json, sys
import os as _os
_C = json.load(open(_os.environ["ZFS_TUI_CAT"], encoding="utf-8")) if _os.environ.get("ZFS_TUI_CAT") else {}
def _(s): return _C.get(s, s)
tiers, names, action, name, new, bdesc, spec = sys.argv[1:8]
WORD = [("hourly", _(u"godzinowe"), _(u"godzinowych")), ("daily", _(u"dobowe"), _(u"dobowych")), ("weekly", _(u"tygodniowe"), _(u"tygodniowych")),
        ("monthly", _(u"miesięczne"), _(u"miesięcznych")), ("yearly", _(u"roczne"), _(u"rocznych")), ("annual", _(u"roczne"), _(u"rocznych"))]
UNIT = {"h": _(u"godz."), "d": _(u"dni"), "w": _(u"tyg."), "m": _(u"mies."), "y": _(u"lat")}
def words(t):
    for suf, a, b in WORD:
        if t.endswith(suf):
            return a, b
    return t, t
# Kolejność i wartości domyślne szczebla, którego bazowy nie ma (te same co w
# save-profile --add-tier): litera wieku, ile trzymać, czy zamrażany.
CANON = [("hourly", "h", "24", False), ("daily", "d", "7", True), ("weekly", "w", "4", True),
         ("monthly", "m", "12", True), ("yearly", "y", "5", True)]
rows = []
for line in open(tiers, encoding="utf-8"):
    f = [x[1:] if x.startswith("#") else x for x in line.rstrip("\n").split("\t")]
    f += [""] * (7 - len(f))
    tn, keep, retain, q, sched, pat, mech = f[:7]
    if not tn:
        continue
    lab, glab = words(tn)
    row = {"key": tn, "label": lab, "glabel": glab, "on": True, "family": pat or None,
           "q": (bool(q) if sched else None), "base_q": bool(q), "mech": mech}
    if keep:
        row.update({"value": keep, "unit": "", "base": keep, "mode": "keep"})
    elif len(retain) > 2 and retain[0] == "-" and retain[1].isalpha() and retain[2:].isdigit():
        row.update({"value": retain[2:], "unit": UNIT.get(retain[1].lower(), retain[1]), "base": retain[2:],
                    "mode": "retain", "letter": retain[1]})
    elif sched:
        # szczebel tylko TWORZY migawki (drabina GFS je sprząta): bez liczby, ale z zamrażaniem
        row.update({"value": "-", "editable": False, "can_off": False, "mode": "none"})
    else:
        continue
    row["sched"] = bool(sched)
    # Szczebel, ktory SAM robi swoje migawki (ma harmonogram), sam je tez sprzata --
    # wylaczenie zabiera jedno i drugie, wiec nie ma czego pilnowac (wlasciciel
    # 2026-10-09, uwaga 3). Straznik rodziny zostaje tylko dla drabiny (szczebel bez
    # harmonogramu sprzata migawki innego).
    if sched:
        row["family"] = None
    rows.append(row)
# OKNO KOMPLETNE (właściciel 2026-10-09: "pokazywać również miesięczne, roczne,
# tygodniowe po prostu nie pozaznaczane"): zawsze pięć szczebli po kolei; tych,
# których bazowy nie ma, nie zaznaczono -- kratka dodaje je (save-profile --add-tier).
make = [r for r in rows if r["mode"] == "none"]
count = [r for r in rows if r["mode"] != "none"]
ladder = any(not r["sched"] for r in count)
age = next((r["letter"] for r in count if r["mode"] == "retain"), None) is not None
fam = next((r["family"] for r in count), None)
ordered = list(make)
for t, letter, dflt, dq in CANON:
    have = [r for r in count if r["key"].endswith(t) or (t == "yearly" and r["key"].endswith("annual"))]
    if have:
        ordered += have
        continue
    lab, glab = words(t)
    row = {"key": t, "label": lab, "glabel": glab, "on": False, "add": True, "value": dflt, "base": dflt,
           "family": (fam if ladder else None),
           "q": (None if ladder else dq), "base_q": dq}
    if age:
        row.update({"mode": "retain", "letter": letter, "unit": UNIT[letter]})
    else:
        row.update({"mode": "keep", "unit": ""})
    ordered.append(row)
ordered += [r for r in count if r not in ordered]
rows = ordered
# SPOSÓB LICZENIA (właściciel 2026-10-09: "brakuje w oknie wyboru (*) GFS () AGE () FLAT
# -- z wyjaśnieniem różnicy"): jeden wybór dla całego szablonu, liczby zostają;
# zapis = save-profile --method. Drabina na jednej rodzinie liczy tylko GFS.
LETTER = {"hourly": "h", "daily": "d", "weekly": "w", "monthly": "m", "yearly": "y", "annual": "y"}
for r in rows:
    if r["mode"] in ("keep", "retain"):
        r["letter"] = r.get("letter") or next((l for suf, l in LETTER.items() if r["key"].endswith(suf)), "")
        r["units"] = {"age": UNIT.get(r["letter"].lower(), "")}
base_m = "gfs" if ladder else (next((r.get("mech") for r in count if r.get("mech")), None) or ("age" if age else "flat"))
choice = {"key": "method", "label": _(u"Sposób"), "value": base_m, "base": base_m,
          "options": [{"key": "gfs", "label": u"GFS",
                       "help": [_(u"Jedna migawka na okres (godzinę, dobę, tydzień...), N okresów wstecz."),
                                _(u"Seria migawek w jednej godzinie zostawia z niej jedną.")]},
                      {"key": "age", "label": _(u"WIEK (age)"),
                       "help": [_(u"Kasuje migawki starsze niż N okresów (dobowe 7 = 7 dni)."),
                                _(u"Po przestoju zostaje mniej: stare migawki dalej się starzeją.")]},
                      {"key": "flat", "label": _(u"PŁASKI (flat)"),
                       "help": [_(u"Trzyma N najnowszych migawek szczebla, bez względu na ich wiek."),
                                _(u"Seria migawek w krótkim czasie wypycha starsze.")]}],
          "locked": (_(u"Drabina na jednej rodzinie migawek liczy tylko GFS.") if ladder else None)}
title = (_(u"Zmiana szablonu %s") % name) if action == "edit" else (_(u"Nowy szablon na podstawie %s") % name)
if action == "relation":
    title = new
s = {"title": title, "head": [_(u"SZCZEBEL"), _(u"TRZYMA"), _(u"KOHERENTNE (zamrażanie)")],
     "fields": ([] if action in ("edit", "relation") else [{"key": "name", "label": _(u"Nazwa"), "value": new}]),
     "after": ([] if action == "relation" else [{"key": "desc", "label": _(u"Opis"), "value": bdesc if action == "edit" else ""}]),
     # X19: w relacji szczeble sa z jej CONFIGU, nie z "bazowego" szablonu.
     "note": [(_(u"Liczby i sposób są z configu tej relacji; godziny zostają, jak są.") if action == "relation"
               else _(u"Harmonogram i sposób (płaski / wiek / GFS) są z bazowego.")),
              _(u"Szczebel wyłączysz tylko, gdy jego migawki sprząta inny.")],
     "rows": rows, "taken": [x.strip() for x in open(names, encoding="utf-8") if x.strip()],
     "name_key": ("" if action in ("edit", "relation") else "name"), "auto_desc": ("" if action in ("edit", "relation") else "desc"),
     "choice": choice}
json.dump(s, open(spec, "w", encoding="utf-8"), ensure_ascii=False)
PYEOF

while :; do
    clear 2>/dev/null
    # shellcheck disable=SC2086
    if ! $GRID_CMD --spec "$SPEC" --out "$OUTJ"; then
        clear 2>/dev/null; wt_end_nochange "$(T 'Szablon: przerwane, nic nie zmieniono')"; exit 1
    fi
    # Wynik -> argumenty save-profile i linie planu (python, bo to JSON; wartości to dane).
    "$PY" - "$SPEC" "$OUTJ" "$ACTION" "$TMPD" <<'PYEOF'
import json, sys
import os as _os
_C = json.load(open(_os.environ["ZFS_TUI_CAT"], encoding="utf-8")) if _os.environ.get("ZFS_TUI_CAT") else {}
def _(s): return _C.get(s, s)
spec, out, action, tmpd = sys.argv[1:5]
s = json.load(open(spec, encoding="utf-8")); o = json.load(open(out, encoding="utf-8"))
by = {r["key"]: r for r in o["rows"]}
args, plan = [], []
meth = o["fields"].get("method") or s["choice"]["base"]
MNAME = {o_["key"]: o_["label"] for o_ in s["choice"]["options"]}
if meth != s["choice"]["base"]:
    args.append("--method=%s" % meth)
    plan.append(_(u"  sposób: %s -> %s (liczby zostają)") % (MNAME[s["choice"]["base"]], MNAME[meth]))
def unit(r):
    return (r.get("units") or {}).get(meth, "")
def field(r, v):
    return ("--retain=-%s%s" % (r["letter"], v)) if meth == "age" else ("--keep=%s" % v)
for r in s["rows"]:
    g = by.get(r["key"], {})
    lab = r["label"]
    if r.get("add"):
        # szczebel, którego bazowy nie ma: zaznaczony = dodać (pola po --add-tier idą do niego)
        if not g.get("on"):
            continue
        v = g.get("value") or r["base"]
        args.append("--add-tier=%s" % r["key"])
        if v != r["base"]:
            args.append(field(r, v))
        q = r.get("q") is not None and bool(g.get("q"))
        if r.get("q") is not None and q != r["base_q"]:
            args.append("--quiesce=%s" % ("auto,degrade" if q else ""))
        plan.append(_(u"  %s: dodany, %s%s") % (lab, (u"%s %s" % (v, unit(r))).strip(),
                    (_(u", zamrażany") if q else _(u", bez zamrażania")) if r.get("q") is not None else ""))
        continue
    if r.get("can_off", True) and not g.get("on", True):
        args.append("--drop-tier=%s" % r["key"]); plan.append(_(u"  %s: wyłączony (było %s)") % (lab, r.get("base", "-")))
        continue
    if r.get("mode") in ("keep", "retain"):
        v = g.get("value") or r["base"]
        if v != r["base"]:
            args += ["--tier=%s" % r["key"], field(r, v)]
            plan.append(u"  %s: %s -> %s %s" % (lab, r["base"], v, unit(r)))
        else:
            plan.append(_(u"  %s: %s %s (bez zmian)") % (lab, v, unit(r)))
    if r.get("q") is not None and bool(g.get("q")) != r["base_q"]:
        args += ["--tier=%s" % r["key"], "--quiesce=%s" % ("auto,degrade" if g.get("q") else "")]
        plan.append(_(u"  zamrażanie %s: %s -> %s") % (lab, _("tak") if r["base_q"] else _("nie"), _("tak") if g.get("q") else _("nie")))
# Wstecz z planu wraca do tabeli z tym, co wybrano (nie od nowa).
for r in s["rows"]:
    g = by.get(r["key"], {})
    r["on"] = g.get("on", True); r["value"] = g.get("value", r.get("value")); r["q"] = g.get("q", r.get("q"))
for f in s["fields"] + s["after"]:
    f["value"] = o["fields"].get(f["key"], f["value"])
s["choice"]["value"] = meth
json.dump(s, open(spec, "w", encoding="utf-8"), ensure_ascii=False)
with open(tmpd + "/targs.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(args) + ("\n" if args else ""))
with open(tmpd + "/plan.lines", "w", encoding="utf-8") as f:
    f.write("\n".join(plan) + ("\n" if plan else ""))
with open(tmpd + "/vals.txt", "w", encoding="utf-8") as f:
    f.write(o["fields"].get("name", "") + "\n" + o["fields"].get("desc", "") + "\n")
PYEOF
    if [ "$ACTION" = relation ]; then
        tr -d '\r' <"$TMPD/targs.txt" >"$ROUT"; tr -d '\r' <"$TMPD/plan.lines" >"$ROUT.plan"
        exit 0
    fi
    mapfile -t TARGS <"$TMPD/targs.txt"
    { IFS= read -r GNAME; IFS= read -r DESC; } <"$TMPD/vals.txt"
    [ "$ACTION" = new ] && NEW="$GNAME"
    DARGS=(); [ -n "$DESC" ] && DARGS=("--description=$DESC")
    if [ "$ACTION" = edit ]; then
        [ "$DESC" = "$BDESC" ] && DARGS=()
        if [ "${#TARGS[@]}" -eq 0 ] && [ "${#DARGS[@]}" -eq 0 ]; then
            wt --title "$(Tv 'Zmiana szablonu $NAME' '$NAME' "$NAME")" --msgbox "$(T 'Nic nie zmieniono.')" 7 "$W"
            exit 0
        fi
        ARGV=("$ZB" save-profile "--from=$NAME" "--as=$NAME" --force)
    else
        ARGV=("$ZB" save-profile "--from=$NAME" "--as=$NEW")
    fi
    ARGV+=(${TARGS[@]+"${TARGS[@]}"} ${DARGS[@]+"${DARGS[@]}"})
    {
        T 'PLAN -- nic jeszcze nie zostało zapisane:'; echo
        echo
        if [ "$ACTION" = edit ]; then Tv 'Zmiana szablonu: $NAME' '$NAME' "$NAME"; echo; else Tv 'Nowy szablon: $NEW (na podstawie $NAME)' '$NEW' "$NEW" '$NAME' "$NAME"; echo; fi
        cat "$TMPD/plan.lines"
        T 'Opis: %s' "${DESC:-$(T '(brak)')}"; echo
        if [ "$ACTION" = edit ]; then Tv 'Zbudowano z niego relacji: $USED -- one zostają, jak są.' '$USED' "$USED"; echo; fi
        echo
        T 'Zbudowane relacje na podstawie szablonu pozostają niezmienione; szablon jest dla nowych relacji (i dla '\''Zmień relację -> Szablon'\'').'; echo
        echo
        printf '%s  ' "$(T 'Komenda:')"; for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done; echo
    } >"$TMPD/plan.txt"
    if yesno_text "$TMPD/plan.txt" "$TITLE -- $(T plan)" "$(T WYKONAJ)" "$(T Wstecz)" --defaultno; then
        run_cmd "$(Tv 'szablon '\''$NEW'\'' zapisany' '$NEW' "$NEW")" "${ARGV[@]}"
    fi
done
