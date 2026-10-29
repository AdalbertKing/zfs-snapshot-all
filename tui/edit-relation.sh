#!/bin/bash
# edit-relation.sh NAZWA -- zmiana zainstalowanej relacji w oknach whiptail ('e' na F3).
#
# Pierwsze okno: CO zmienić (właściciel 2026-10-09, uwaga 5):
#   1. Datasety -- drzewo z kratkami (X12), zapis jednym set-datasets (relacja = config)
#   2. Użyj szablonu -- gotowy szablon dla celu  (edit-relation --profile)
#   3. Harmonogram i retencja kopii w celu i źródle -- tabela    (ukryty szablon relacji, edit-relation)
#   4. Ustawienia silnika -- jak przesyłane są kopie (set-transfer; W16: historia,
#      kompresja, szyfr SSH, autodobór łącza)
#   5. Ręczna edycja konfigu                     (edit-config)
#   6. Zapisz ustawienia relacji jako szablon    (save-profile, zwykły szablon na F5)
#   7. Adres hosta -- po przeniesieniu kolektora (activate --host= --skip-final-catchup;
#      tylko relacja ze zdalnym źródłem; właściciel 2026-10-17)
# Po 2 i 3 retencję ŹRÓDŁA ustawia to samo okno-tabela co w kreatorze relacji
# (tui/retention-lib.sh; uwaga 10: dla źródła nigdy druga lista szablonów).
#
# Okno NIE ma własnej logiki: pokazuje PLAN czasownika (--plan: generacja, gen-cron,
# próba pobrania, sprawdzenie praw -- bez zmian) i po "WYKONAJ" uruchamia go z --yes.
# Czego czasownik odmawia, odmawia tu tak samo, tymi samymi słowami.
#
# UKRYTY SZABLON RELACJI (P4): "Harmonogram i retencja kopii w celu i źródle" zapisuje wybory z tabeli
# jako relacja-<NAZWA> (save-profile --hidden; F5 go nie pokazuje). Gdy plan nie
# zostanie wykonany, poprzednia treść tego pliku wraca (albo plik znika, jeśli go nie
# było) -- przerwana zmiana nie zostawia szablonu, który mówi co innego niż relacja.
#
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "edit-relation: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
. "$HERE/tui/retention-lib.sh" || { echo "edit-relation: brak $HERE/tui/retention-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
. "$HERE/tui/basket-lib.sh" || { echo "edit-relation: brak $HERE/tui/basket-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
NAME="${1:-}"
[ -n "$NAME" ] || { echo "usage: edit-relation.sh NAME" >&2; exit 2; }
WT_BACKTITLE="$(Tv 'Zmiana relacji $NAME -- kolektor $(hostname)' '$NAME' "$NAME" '$(hostname)' "$(hostname)")"
T_CHG="$(Tv 'Zmień relację $NAME' '$NAME' "$NAME")"
T_ADR="$(Tv 'Adres hosta: $NAME' '$NAME' "$NAME")"
# U65: 'c' (ręczna edycja) i 's' (zapisz jako szablon) w oknie relacji na F3 otwierają TĘ
# czynność od razu (EDIT_DO), bez listy zmian; po niej okno się kończy.
FORCE_ACTION=""; DIRECT=0
case "${EDIT_DO:-}" in config|zapisz) FORCE_ACTION="$EDIT_DO"; DIRECT=1 ;; esac
TMPD="$(mktemp -d)" || exit 1
HNAME="relacja-$NAME"     # ukryty szablon tej relacji
HIDDEN_DIRTY=0; DONE=0; HBACKUP=""; HFILE=""
restore_hidden() {
    [ "$HIDDEN_DIRTY" -eq 1 ] && [ "$DONE" -ne 1 ] || return 0
    if [ -n "$HBACKUP" ] && [ -n "$HFILE" ]; then
        cp -p "$HBACKUP" "$HFILE" 2>/dev/null
    else
        "$ZB" delete-profile "$HNAME" --yes >/dev/null 2>&1
    fi
}
trap 'restore_hidden; rm -rf "$TMPD"' EXIT

# st.tsv: stan, profil, profil źródła, peer, datasety, lustro, cel; prof.tsv: nazwa <TAB> opis (bez
# ukrytych i pochodnych -src-); prof.json.tiers: szczeble do okna retencji źródła;
# hfile.txt: plik ukrytego szablonu tej relacji (jeśli jest).
load_lists() {
    # --no-render (W1, 2026-10-12): z renderowaniem list-profiles trwal na pve9b 16,6 s,
    # bez niego 1,8 s; valid/families nie sa potrzebne do wyboru (sprawdza je czasownik).
    "$ZB" list-profiles --json --no-render >"$TMPD/prof.json" 2>"$TMPD/prof.err" || return 1
    "$PY" - "$TMPD/st.json" "$TMPD/prof.json" "$HERE/tui/zfs-tui.py" "$TMPD" "$HNAME" <<'PYEOF'
import sys, json, re, importlib.util
spec = importlib.util.spec_from_file_location("zfs_tui", sys.argv[3])
tui = importlib.util.module_from_spec(spec); spec.loader.exec_module(tui)
tui.load_lang(tui.ui_lang())     # słowa w języku okna (ZFS_TUI_LANG z wt-lib.sh)
tmpd, hname = sys.argv[4], sys.argv[5]
try:
    st = json.load(open(sys.argv[1], encoding="utf-8"))
    st = (st.get("relations") or [{}])[0]
except Exception:
    st = {}
with open(tmpd + "/st.tsv", "w", encoding="utf-8", newline="\n") as f:
    f.write("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" % (st.get("state") or "-", st.get("profile") or "-", st.get("source_profile") or "-",
                                        st.get("peer_host") or "-",
                                        # "konto@host:dataset" -> "dataset" (sam dataset do drzewa)
                                        ",".join(x.rsplit(":", 1)[-1] for x in (st.get("sources") or [])) or "-",
                                        "1" if (str(st.get("passive") or "") == "1" or st.get("mode") == "sync") else "0",
                                        st.get("client_target") or "-", st.get("mode") or "-", st.get("local_user") or "-"))
d = json.load(open(sys.argv[2], encoding="utf-8"))
rows = []
with open(tmpd + "/prof.json.tiers", "w", encoding="utf-8", newline="\n") as tf, \
     open(tmpd + "/hfile.txt", "w", encoding="utf-8", newline="\n") as hf:
    for p in d.get("profiles", []):
        n = p.get("name") or ""
        for t in p.get("tiers", []):
            if t.get("keep"):
                tf.write("%s\t%s\t%s\t%s\tkeep\n" % (n, t.get("name", "-"), t.get("pattern") or "-", t["keep"]))
            elif t.get("retain"):
                m = re.match(r"^-([hdwmy])([0-9]+)$", t["retain"])
                if m:
                    tf.write("%s\t%s\t%s\t%s\tretain:%s\n" % (n, t.get("name", "-"), t.get("pattern") or "-", m.group(2), m.group(1)))
        if n == hname:
            hf.write((p.get("file") or "") + "\n")
        if not n or "-src-" in n or p.get("hidden"):
            continue
        w = tui.profile_words(p)
        rows.append((n, w["retention"], w["mech"]))
rows.sort(key=lambda r: r[0].lower())
# Kolumny o STAŁEJ szerokości (uwaga 23, 2026-10-08): nazwa, co trzyma, [rodzaj].
wn = max([len(r[0]) for r in rows] + [1])
wr = max([len(r[1]) for r in rows] + [1])
with open(tmpd + "/prof.tsv", "w", encoding="utf-8", newline="\n") as f:
    for n, ret, mech in rows:
        f.write("%s\t%-*s  %-*s  [%s]\n" % (n, wn, n, wr, ret, mech))
PYEOF
}

geom
info "$T_CHG" "$(T 'Czytam relację i szablony...')"
"$ZB" status "$NAME" --json >"$TMPD/st.json" 2>/dev/null
load_lists || { wt --title "$(T 'Szablony niedostępne')" --msgbox "$(T 'list-profiles nie odpowiedział:\n')$(tail -3 "$TMPD/prof.err")" 12 "$W"; exit 1; }
IFS=$'\t' read -r STATE CUR_P CUR_S PEER SRCS MIRROR TGT RMODE ACCT_U <"$TMPD/st.tsv" || { STATE=-; CUR_P=-; CUR_S=-; PEER=-; SRCS=-; MIRROR=0; TGT=-; RMODE=-; ACCT_U=-; }
ACCT_U="${ACCT_U%$'\r'}"
# MIGAWKI ZDALNIE (snaponly, REV-20261017-152 runda 3; właściciel 2026-10-18: ta sama
# ścieżka 'e' co każda relacja). Szablon JEST tu retencją źródła (celu nie ma), więc
# po szablonie nie ma drugiego okna "w źródle kopii", a "Ustawienia silnika" (łącze,
# kompresja, szyfr) nie dotyczą -- nic nie jest przesyłane.
SNAPONLY=0; [ "${RMODE:-}" = snaponly ] && SNAPONLY=1
# Relacja lokalna (bez peera): źródłem jest ten host -- lista datasetów bez adresu.
SRCHOST="$(host_name "$PEER" "$NAME")"; LDS_ARGS=("$PEER"); HOST="$SRCHOST"
SRCNAME="$PEER"
if [ "$PEER" = - ]; then SRCHOST="$(T 'tego hosta') ($(hostname -s 2>/dev/null || hostname))"; LDS_ARGS=(); HOST="$SRCHOST"; SRCNAME="$(hostname -s 2>/dev/null || hostname)"; fi
[ "$CUR_P" = - ] && CUR_P=""; [ "$CUR_S" = - ] && CUR_S=""
# ADRES HOSTA (właściciel 2026-10-17): kolektor wyniesiony za VPN, źródło widać pod
# innym IP. Jedno pole, jedno WYKONAJ, potem zwykłe `activate --host=NOWY
# --skip-final-catchup --yes`: zapis adresu, sprawdzenie, że odpowiada TEN SAM host
# (klucz przypięty do aliasu, wspólna migawka), przestawienie crona. Domknięcie kopii
# starym adresem jest wcześniejszym krokiem admina (F3, F7 Uruchom teraz) -- okno za niego
# nie myśli. Literówkę w adresie poprawia się tym samym oknem: relacja zostaje wtedy
# w stanie endpoint_change_pending, a cron dalej idzie starym adresem.
address_flow() {
    local cur inst new rc
    # status NAZWA --json = {"relations":[{...}]} -- pola relacji są w relations[0].
    cur=$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); r=(d.get("relations") or [{}])[0]; print(r.get("active_endpoint") or "")' "$TMPD/st.json" 2>/dev/null)
    inst=$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); r=(d.get("relations") or [{}])[0]; print(r.get("installed_endpoint") or "")' "$TMPD/st.json" 2>/dev/null)
    case "$cur" in *:*) ;; *) cur="$PEER" ;; esac
    while :; do
        geom
        wt --title "$T_ADR" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" \
           --inputbox "$(Tv 'Nowy adres źródła $SRCNAME po przeniesieniu kolektora:\nIP albo nazwa, opcjonalnie :port.\n\nZapisany: ${cur:--}   Cron idzie przez: ${inst:--}\n\nUżywaj PO przeniesieniu, gdy nowy adres już odpowiada.' '$SRCNAME' "$SRCNAME" '${cur:--}' "${cur:--}" '${inst:--}' "${inst:--}")" 14 "$W" "${P_HOST:-$cur}" || return 0
        new="${WT_OUT// /}"
        [ -n "$new" ] || continue
        case "$new" in
            *[!A-Za-z0-9.:_-]*) wt --title "$(T 'Zły adres')" --msgbox "$(Tv ''\''$WT_OUT'\'' -- tylko litery, cyfry, kropka, myślnik, podkreślenie i :port.' '$WT_OUT' "$WT_OUT")" 8 "$W"; continue ;;
        esac
        # LISTA ZMIAN (właściciel 2026-10-19: "nie można zmienić wiele ustawień i na końcu
        # zaimplementować, tylko po jednym kroku"): adres czeka na liście, WYKONAJ jest jedno,
        # w "Zapisz zmiany". Ten sam adres co zapisany = brak zmiany.
        if [ "$new" = "$cur" ] || [ "$new" = "${cur%:22}" ]; then P_HOST=""; return 0; fi
        # E-1/E-2 (kampania na żywo, pve10 2026-10-21): adres, pod którym nic nie odpowiada,
        # szedł na listę zmian bez słowa, a po WYKONAJ activate zapisał go w rekordzie
        # (endpoint_change_pending) i padł z komunikatem o pliku zakresu. Tu, zanim cokolwiek
        # trafi na listę: czy na host:port w ogóle ktoś odpowiada (TCP, 5 s). To NIE jest
        # sprawdzenie tożsamości -- to robi activate (klucz hosta, wspólna migawka).
        local ph="${new%%:*}" pp=22
        case "$new" in *:*) pp="${new##*:}" ;; esac
        info "$T_ADR" "$(Tv 'Sprawdzam, czy pod $ph:$pp ktoś odpowiada (do 5 s)...' '$ph' "$ph" '$pp' "$pp")"
        # ADDR_PROBE: tylko testy (atrapa "odpowiada"/"nie odpowiada"); na hoście nieustawione.
        if ! { if [ -n "${ADDR_PROBE:-}" ]; then $ADDR_PROBE "$ph" "$pp"; else timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$ph" "$pp"; fi; } 2>/dev/null; then
            wt --title "$(Tv 'Adres hosta: $NAME -- brak odpowiedzi' '$NAME' "$NAME")" --msgbox "$(Tv 'Pod $ph:$pp nic nie odpowiada (połączenie TCP, 5 s).\n\nAdres NIE został zmieniony. Sprawdź adres i czy host jest\nwłączony (z linii poleceń GUI: ping $ph), potem wpisz go jeszcze raz.' '$ph' "$ph" '$pp' "$pp")" 12 "$W"
            continue
        fi
        P_HOST="$new"
        return 0
    done
}
# Wykonanie zmiany adresu (z "Zapisz zmiany"): zapis, sprawdzenie tego samego hosta, cron.
address_apply() {
    echo "\$ $ZB activate $NAME --host=$P_HOST --skip-final-catchup --yes"; echo
    "$ZB" activate "$NAME" "--host=$P_HOST" --skip-final-catchup --yes
}
# Zmiana adresu w toku: jedyne, co tu ma sens, to poprawić adres -- prosto do tego okna.
#   endpoint_change_pending -- nowy adres zapisany, niesprawdzony (np. literówka);
#   endpoint_verified       -- nowy adres nie odpowiedział, verify-endpoint wrócił do
#                              starego, activate zatrzymał się przed instalacją
#                              (zmierzone na pve10, 2026-10-17).
if { [ "$STATE" = endpoint_change_pending ] || [ "$STATE" = endpoint_verified ]; } && [ "$PEER" != - ]; then
    P_HOST=""
    address_flow
    [ -n "${P_HOST:-}" ] || exit 0
    wt --title "$T_ADR" --yes-button "$(T WYKONAJ)" --no-button "$(T Wstecz)" --defaultno \
       --yesno "$(Tv 'Relacja $NAME: nowy adres źródła $P_HOST.\nSprawdzenie, że to ten sam host, potem cron przez nowy adres.\n\nKomenda:' '$NAME' "$NAME" '$P_HOST' "$P_HOST") $(shq "$ZB") activate $NAME --host=$P_HOST --skip-final-catchup --yes" 12 "$W" || exit 1
    clear 2>/dev/null
    address_apply; rc=$?
    echo
    if [ "$rc" -eq 0 ]; then echo "$(Tv '=== Gotowe: relacja $NAME działa przez $P_HOST.' '$NAME' "$NAME" '$P_HOST' "$P_HOST")"
    else echo "$(Tv '=== Przerwane (rc=$rc) -- przyczyna wyżej. Cron dalej idzie starym adresem. Popraw adres: e na relacji.' '$rc' "$rc")"; fi
    echo "$(T 'Enter = dalej')"; [ -t 0 ] && read -r _
    exit "$rc"
fi
if [ "$STATE" != active ]; then
    wt --title "$(Tv 'Nie da się zmienić '\''$NAME'\''' '$NAME' "$NAME")" --msgbox "$(Tv 'Relacja '\''$NAME'\'' jest w stanie '\''${STATE}'\''.\nZmieniać można tylko relację zainstalowaną (active).' '$NAME' "$NAME" '${STATE}' "${STATE}")" 10 "$W"
    exit 1
fi
# Koszyk (basket-lib.sh) w "Datasety": nagłówek okien, bez "Sposób". Wyjątki jak w kreatorze,
# w każdym rodzaju relacji: drzewo -> pozycje (basket_entries) -> jedno set-datasets.
RECURSION=flat; BASKET_NO_MODE=1; BASKET_NO_EXC=0
title() { T 'Zmień relację %s -- %s' "$NAME" "$2"; }
cur_words() {   # słowa o obecnym szablonie celu
    if [ "$CUR_P" = "$HNAME" ]; then echo "$(T 'własne ustawienia relacji (tabela szczebli)')"; else echo "${CUR_P:-$(T '<nie zapisany>')}"; fi
}

# X24 (właściciel 2026-10-14): "szablon nadpisuje zmiany -- to logiczne. Brać liczby z
# szablonu, ale ostrzegać, że należy zmienić relację ręcznie w źródle." Porównuje to, co
# źródło relacji trzyma TERAZ (config, show-tiers), z liczbami szablonu PROFILE; różnice
# idą do $TMPD/srcwarn.txt (puste = nic się w źródle nie zmieni).
src_override_warning() {
    : >"$TMPD/srcwarn.txt"
    "$ZB" show-tiers "$NAME" --json >"$TMPD/stw.json" 2>/dev/null || return 0
    "$PY" - "$TMPD/stw.json" "$TMPD/prof.json.tiers" "$PROFILE" <<'PYEOF' | tr -d '\r' >"$TMPD/srcwarn.txt"
import sys, json
import os as _os
_C = json.load(open(_os.environ["ZFS_TUI_CAT"], encoding="utf-8")) if _os.environ.get("ZFS_TUI_CAT") else {}
def _(s): return _C.get(s, s)
W = {"hourly": _(u"godzinowe"), "daily": _(u"dobowe"), "weekly": _(u"tygodniowe"), "monthly": _(u"miesięczne"), "yearly": _(u"roczne")}
U = {"h": _(u"godz."), "d": _(u"dni"), "w": _(u"tyg."), "m": _(u"mies."), "y": _(u"lat")}
key = lambda n: (n or "").split("_")[-1]
try:
    src = json.load(open(sys.argv[1], encoding="utf-8")).get("source") or []
except Exception:
    sys.exit(0)
def cur(t):
    if t.get("mechanism") == "age" and t.get("retain"):
        r = t["retain"]; return "%s %s" % (r[2:], U.get(r[1:2], r[1:2]))
    return t.get("keep") or ""
tpl = {}
for l in open(sys.argv[2], encoding="utf-8"):
    f = l.rstrip("\r\n").split("\t")
    if len(f) >= 5 and f[0] == sys.argv[3]:
        tpl[key(f[1])] = f[3] if f[4] == "keep" else "%s %s" % (f[3], U.get(f[4][-1:], f[4][-1:]))
seen = []
for t in src:
    k = key(t.get("name")); c = cur(t)
    if not c or k in seen:
        continue
    seen.append(k)
    w = W.get(k, k)
    if k not in tpl:
        print(_(u"  %-11s źródło trzyma %s, szablon nie ma tego szczebla") % (w, c))
    elif tpl[k] != c:
        print(_(u"  %-11s źródło trzyma %s, szablon da %s") % (w, c, tpl[k]))
PYEOF
}

# Liczby źródła do okna: obecny szablon źródła, dopasowany po nazwie szczebla do szablonu
# celu (szczebel, którego źródło nie ma = 0). Tylko gdy cel się nie zmienił.
src_prefill() {
    SRCKEEP=""
    [ -n "$CUR_S" ] && [ "$PROFILE" = "$CUR_P" ] || return 0
    local -a v=(); local n t p k m sv
    while IFS=$'\t' read -r n t p k m; do
        [ "$n" = "$PROFILE" ] || continue
        sv=$(awk -F'\t' -v s="$CUR_S" -v t="$t" '$1==s && $2==t {print $4; exit}' "$TMPD/prof.json.tiers")
        v+=("${sv:-off}")
    done <"$TMPD/prof.json.tiers"
    [ "${#v[@]}" -gt 0 ] && SRCKEEP="$PROFILE:${v[*]}"
}

# HARMONOGRAM I RETENCJA -- wprost w CONFIGU (właściciel 2026-10-13: "config jako jedyne źródło
# prawdy"; pośrednik w postaci ukrytego szablonu odrzucony: "Ctrl+C w złym momencie i mamy stan
# nieustalony"). Szczeble czyta show-tiers z configu, ta sama tabela celu i to samo okno źródła
# co dotąd, a zapis to JEDNO wywołanie set-tiers: kopia configu, zmiana, cały config przez
# generator, jedna atomowa podmiana. Wstecz = jeden krok (tabela <- źródło <- plan <- menu).
# Wiersze "@rel" (cel) i "@rel-src" (źródło) w prof.json.tiers: szczeble z configu (rt.json) z
# NAŁOŻONYMI argumentami tabeli celu ($TMPD/rargs). Szczebel dodany w celu dostaje u źródła
# liczbę celu i trafia do $TMPD/newtiers (set-tiers sam go doda po obu stronach -- okno
# źródła ustawia mu tylko liczbę).
rel_tiers() {
    # X20 (właściciel 2026-10-14): argumenty tabeli celu się SUMUJĄ ($TMPD/rargs.acc) i
    # tabela przy powrocie (Wstecz z okna źródła) startuje od nich ($TMPD/rt-work.json), a
    # nie znów od configu -- wpisana zmiana nie ulatuje. set-tiers wykonuje argumenty po
    # kolei, więc późniejsze poprawiają wcześniejsze.
    "$PY" - "$TMPD/rt.json" "$TMPD/rargs.acc" "$TMPD/prof.json.tiers" "$TMPD/newtiers" "$TMPD/rt-work.json" <<'PYEOF'
import copy, json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
try:
    args = [l.rstrip("\r\n") for l in open(sys.argv[2], encoding="utf-8") if l.strip()]
except OSError:
    args = []
DEF = {"hourly": 24, "daily": 7, "weekly": 4, "monthly": 12, "yearly": 5}
LET = {"hourly": "h", "daily": "d", "weekly": "w", "monthly": "m", "yearly": "y"}
SEND = {"hourly": "1 * * * *", "daily": "11 1 * * *", "weekly": "21 2 * * 0", "monthly": "31 3 1 * *", "yearly": "31 3 1 1 *"}
tgt = [copy.deepcopy(t) for t in d.get("target", [])]
src = [copy.deepcopy(t) for t in d.get("source", [])]
def find(lst, n):
    for t in lst:
        if t.get("name") == n:
            return t
def word(n):
    return n.split("_")[-1]
new, cur = [], None
for a in args:
    k, _, v = a.partition("=")
    if k == "--tier":
        cur = find(tgt, v)
    elif k == "--add-tier":
        first = tgt[0] if tgt else {}
        cur = {"name": v, "pattern": "automated_" + v, "prefix": "automated_" + v + "_",
               "mechanism": first.get("mechanism", "flat"), "gfs": first.get("gfs", ""),
               "keep": "", "retain": "", "quiesce": "" if v == "hourly" else "auto,degrade",
               "send_schedule": SEND.get(v, ""), "prune_schedule": ""}
        if cur["mechanism"] == "age":
            cur["retain"] = "-%s%d" % (LET.get(v, "d"), DEF.get(v, 1))
        else:
            cur["keep"] = str(DEF.get(v, 1))
        tgt.append(cur)
        if v not in new:
            new.append(v)
    elif k == "--drop-tier":
        tgt = [t for t in tgt if t.get("name") != v]
        src = [t for t in src if t.get("name") != v]
        if v in new:
            new.remove(v)
        cur = None
    elif k == "--keep" and cur is not None:
        cur["keep"] = v; cur["retain"] = ""
    elif k == "--retain" and cur is not None:
        cur["retain"] = v; cur["keep"] = ""
    elif k == "--quiesce" and cur is not None:
        cur["quiesce"] = v
    elif k == "--method":
        for t in tgt + src:
            n = t.get("keep") or re.sub(r"^-[A-Za-z]", "", t.get("retain") or "")
            t["mechanism"] = v
            t["gfs"] = "yes" if v == "gfs" else ""
            if v == "age":
                t["retain"] = "-%s%s" % (LET.get(word(t.get("name", "")), "d"), n); t["keep"] = ""
            else:
                t["keep"] = n; t["retain"] = ""
for n in new:
    t = find(tgt, n)
    if t is not None and find(src, n) is None:
        src.append(copy.deepcopy(t))
def line(name, t):
    if t.get("keep"):
        return "%s\t%s\t%s\t%s\tkeep\n" % (name, t.get("name", "-"), t.get("pattern") or "-", t["keep"])
    m = re.match(r"^-([hdwmy])([0-9]+)$", t.get("retain") or "")
    if m:
        return "%s\t%s\t%s\t%s\tretain:%s\n" % (name, t.get("name", "-"), t.get("pattern") or "-", m.group(2), m.group(1))
    return ""
lines = [l for l in open(sys.argv[3], encoding="utf-8") if not l.startswith(("@rel\t", "@rel-src\t"))]
with open(sys.argv[3], "w", encoding="utf-8", newline="\n") as f:
    f.writelines(lines)
    for t in tgt:
        f.write(line("@rel", t))
    for t in src:
        f.write(line("@rel-src", t))
open(sys.argv[4], "w", encoding="utf-8").write(" ".join(new))
json.dump({"profiles": [{"name": "@rel", "source": "user", "used_by": 0, "description": "", "tiers": tgt}]},
          open(sys.argv[5], "w", encoding="utf-8"), ensure_ascii=False)
PYEOF
}

# U25: dwa pola karty, jak w kreatorze -- "Harmonogram" (tabela celu, bez okna źródła) i
# "Retencja źródła" (samo okno źródła). harm_flow [src]. Zmiany obu czekają osobno
# (P_RARGS, P_SARGS) i idą jednym set-tiers.
harm_flow() {
    local hs=1 rc only_src="${1:-}"
    info "$(T 'Harmonogram i retencja')" "$(T 'Czytam szczeble relacji z configu...')"
    if ! "$ZB" show-tiers "$NAME" --json >"$TMPD/rt.json" 2>"$TMPD/rt.err"; then
        wt --title "$(T 'Nie da się odczytać szczebli')" --msgbox "$(grep -E 'FATAL' "$TMPD/rt.err" | tail -1 | sed 's/^FATAL: //')" 10 "$W"
        return 0
    fi
    # Pseudoszablony "@rel" (cel) i "@rel-src" (źródło) w kształcie, który czytają tabela i
    # okno źródła: rel_tiers pisze je z configu (rt.json) i zsumowanych zmian tabeli.
    : >"$TMPD/rargs"; printf '%s\n' ${P_RARGS[@]+"${P_RARGS[@]}"} | grep . >"$TMPD/rargs.acc"; rel_tiers
    local SAVE_P="${PROFILE:-}" SAVE_S="${CUR_S:-}"
    PROFILE="@rel"; CUR_S="@rel-src"; SRCKEEP=""
    local nsrc; nsrc=$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1],encoding="utf-8")).get("source",[])))' "$TMPD/rt.json")
    if [ -n "$only_src" ]; then
        if [ "$nsrc" -eq 0 ]; then
            wt --title "$(T 'Retencja źródła')" --msgbox "$(T 'Źródło tej relacji nie ma własnej retencji (sprząta je tylko cel).')" 8 "$W"
            PROFILE="$SAVE_P"; CUR_S="$SAVE_S"; return 0
        fi
        mapfile -t RARGS <"$TMPD/rargs.acc"; hs=2
        SRCKEEP="@rel:$(awk -F'	' '$1=="@rel" {print $2}' "$TMPD/prof.json.tiers" | while read -r t; do v=$(awk -F'	' -v t="$t" '$1=="@rel-src" && $2==t {print $4; exit}' "$TMPD/prof.json.tiers"); printf '%s ' "${v:-off}"; done)"
    fi
    while :; do
        if [ "$hs" -eq 1 ]; then
            clear 2>/dev/null
            TEMPLATE_JSON="$TMPD/rt-work.json" ZFS_BACKUP="$ZB" bash "$HERE/tui/template.sh" relation "@rel" "$TMPD/rargs" "$(Tv 'Harmonogram i retencja: W CELU KOPII – $(hostname -s 2>/dev/null || hostname)' '$(hostname -s 2>/dev/null || hostname)' "$(hostname -s 2>/dev/null || hostname)")" \
                || { PROFILE="$SAVE_P"; CUR_S="$SAVE_S"; return 0; }
            cat "$TMPD/rargs" >>"$TMPD/rargs.acc"
            mapfile -t RARGS <"$TMPD/rargs.acc"
            # X15 (właściciel 2026-10-13): okno źródła widzi szczeble PO zmianach w tabeli celu --
            # dodany szczebel jest (z liczbą jak w celu), usunięty znika, liczby celu aktualne.
            rel_tiers
            hs=2; SRCKEEP=""
            [ "$nsrc" -gt 0 ] && SRCKEEP="@rel:$(awk -F'\t' '$1=="@rel" {print $2}' "$TMPD/prof.json.tiers" | while read -r t; do v=$(awk -F'\t' -v t="$t" '$1=="@rel-src" && $2==t {print $4; exit}' "$TMPD/prof.json.tiers"); printf '%s ' "${v:-off}"; done)"
        fi
        printf '%s\n' ${P_SARGS[@]+"${P_SARGS[@]}"} | grep . >"$TMPD/srcargs"
        if [ -n "$only_src" ]; then
            : >"$TMPD/srcargs"
            SRC_TITLE="$(Tv 'Retencja: W ŹRÓDLE KOPII – $SRCNAME' '$SRCNAME' "$SRCNAME")"
            SRC_ARGS_OUT="$TMPD/srcargs" SRC_NEW_TIERS="$(cat "$TMPD/newtiers" 2>/dev/null)" source_retention_editor                 || { PROFILE="$SAVE_P"; CUR_S="$SAVE_S"; return 0; }
        fi
        local -a SARGS=(); mapfile -t SARGS <"$TMPD/srcargs"
        if [ "${#RARGS[@]}" -eq 0 ] && [ "${#SARGS[@]}" -eq 0 ]; then
            wt --title "$(T 'Harmonogram i retencja')" --msgbox "$(T 'Nic nie zmieniono -- relacja zostaje, jak jest.')" 8 "$W"
            PROFILE="$SAVE_P"; CUR_S="$SAVE_S"; return 0
        fi
        ARGV=("$ZB" set-tiers "$NAME" ${RARGS[@]+"${RARGS[@]}"} ${SARGS[@]+"${SARGS[@]}"})
        info "$T_CHG" "$(T 'Liczę plan (cały config przez generator)...')"
        if ! "${ARGV[@]}" --plan >"$TMPD/plan.txt" 2>&1; then
            wt --title "$(T 'Czasownik odmówił -- nic nie zmieniono')" --msgbox "$(verb_refusal "$TMPD/plan.txt" | fold -s -w $((W - 6)))" 12 "$W"
            [ -n "$only_src" ] && hs=2 || hs=1; continue
        fi
        { echo "$(T 'PLAN -- nic jeszcze nie zostało zmienione:')"; echo
          sed -n '/^Relation .* -- tiers:/,/^plan only/p' "$TMPD/plan.txt" | grep -v '^plan only'
          echo
          grep -E '^ +[-+][0-9*]' "$TMPD/plan.txt" | grep -v 'check-snap-age' | sed -E 's/profile__[^ ]*__//; s|/[^ ]*/zfs-job\.sh "([^"]*)".* (-[HDWMY][0-9]+) *$|\1  \2|; t; s|/[^ ]*/zfs-job\.sh "([^"]*)".*|\1|' | head -40
          echo
          echo "Komenda:  $(for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done)--yes"; } >"$TMPD/plan2.txt"
        # Plan przeszedł -- zmiana czeka na liście ("Zapisz zmiany" wykona wszystko razem).
        P_TIERS=(${RARGS[@]+"${RARGS[@]}"} ${SARGS[@]+"${SARGS[@]}"}); cp "$TMPD/plan2.txt" "$TMPD/p_tiers.txt"
        P_RARGS=(${RARGS[@]+"${RARGS[@]}"})   # tabela celu otwarta drugi raz startuje od nich
        P_SARGS=(${SARGS[@]+"${SARGS[@]}"})
        P_EDIT=()
        PROFILE="$SAVE_P"; CUR_S="$SAVE_S"
        return 0
    done
}

# USTAWIENIA SILNIKA (W16, właściciel 2026-10-11): historia, kompresja, szyfr SSH i autodobór
# łącza jednej relacji. Obecne wartości z show-config; zmiany czekają w zmiennych p_*,
# dopiero "Gotowe" składa set-transfer (--plan, potem WYKONAJ = --yes). Wstecz = bez zmian.
eng_hist_words() {
    case "$1" in
        default|all) echo "$(T 'wszystkie migawki pomiędzy')" ;;
        newest)      echo "$(T 'tylko różnica do najnowszej')" ;;
        auto:*)      echo "$(Tv 'auto (po ${1#auto:} odstępach tylko różnica)' '${1#auto:}' "${1#auto:}")" ;;
        *)           echo "$1" ;;
    esac
}
eng_comp_words() {
    case "$1" in
        default) if [ "$PEER" = - ]; then echo "$(T 'nie (kopia lokalna)')"; else echo "$(T 'tak (zstd)')"; fi ;;
        zstd)    echo "zstd" ;;
        gzip)    echo "gzip (pigz)" ;;
        none)    echo "$(T nie)" ;;
        *)       echo "$1" ;;
    esac
}
ptransfer_words() {   # P_TRANSFER (--history=.. --compression=.. --cipher=.. --autotune=..) -> słowa karty
    # Kampania 2026-10-22: karta mówiła "fabryczne -> zmiana" -- nie wiadomo, CO się zmienia.
    local a out=""
    for a in "${P_TRANSFER[@]}"; do
        case "$a" in
            --history=*)     a="$(T 'historia: %s' "$(eng_hist_words "${a#*=}")")" ;;
            --compression=*) a="$(T 'kompresja: %s' "$(eng_comp_words "${a#*=}")")" ;;
            --cipher=default) a="$(T 'szyfr: domyślny SSH')" ;;
            --cipher=*)      a="$(T 'szyfr: %s' "${a#*=}")"; a="${a%%@*}" ;;
            --autotune=*)    a="$(T 'autodobór: %s' "$(case "${a#*=}" in no) T nie ;; default) T fabryczny ;; *) T tak ;; esac)")" ;;
            *) continue ;;
        esac
        out="${out:+$out, }$a"
    done
    printf '%s' "${out:-$(T zmiana)}"
}
eng_lbl() {   # etykieta pozycji menu dopełniona spacjami do 17 ZNAKÓW (printf %-17s liczy bajty, jak w card_menu)
    local s="$1"; while [ "${#s}" -lt 17 ]; do s="$s "; done; printf '%s' "$s"
}
eng_pick() {   # <tytuł> <tekst> <domyślny tag> <tag> <opis> ... -> wybór w WT_OUT; rc 1 = Wstecz
    local t="$1" x="$2" d="$3"; shift 3
    geom
    wt --title "$t" --ok-button "$(T Wybierz)" --cancel-button "$(T Wstecz)" --notags --default-item "$d" \
       --menu "$x" "$(fit $(($# / 2 + 2)))" "$W" "$(lhfit $(($# / 2)) 2)" "$@"
}
# Karta (U65, pve10 2026-10-22): ile trzyma źródło -- z CONFIGU (show-tiers), nie z nazwy
# profilu źródła: zmiana tabelą (set-tiers) zmienia liczby, a nazwa zostaje, i karta mówiła
# "tyle samo co w kopii" przy źródle trzymającym 72 z 168. Raz na okno.
srcret_words() {
    [ -s "$TMPD/tiers.json" ] || "$ZB" show-tiers "$NAME" --json >"$TMPD/tiers.json" 2>/dev/null || { rm -f "$TMPD/tiers.json"; echo "?"; return 0; }
    "$PY" - "$TMPD/tiers.json" <<'PYEOF' 2>/dev/null | tr -d '\r' || echo "?"
import json, sys
import os as _os
_C = json.load(open(_os.environ["ZFS_TUI_CAT"], encoding="utf-8")) if _os.environ.get("ZFS_TUI_CAT") else {}
def _(s): return _C.get(s, s)
W = (("hourly", _(u"godzinowe")), ("daily", _(u"dobowe")), ("weekly", _(u"tygodniowe")), ("monthly", _(u"miesięczne")), ("yearly", _(u"roczne")))
d = json.load(open(sys.argv[1], encoding="utf-8"))
# REV-20261023-171: "tyle samo" only when BOTH sides' retention-bearing tiers match as
# whole sets -- a tier dropped on the source (set-tiers --drop-src-tier=daily) left the
# target's daily unchecked, and the card said "tyle samo co w kopii" for hourly only.
def held(m):   # only the tiers that retain something
    return {n: k for n, k in m.items() if k[0] or k[1]}
tg = {t.get("name"): (t.get("keep") or "", t.get("retain") or "") for t in d.get("target") or []}
sr = {t.get("name") or "?": (t.get("keep") or "", t.get("retain") or "") for t in d.get("source") or []}
tg, sr = held(tg), held(sr)
out = []
for n, k in sr.items():
    w = next((v for s, v in W if n.endswith(s)), n)
    out.append("%s %s" % (w, k[0] or k[1]))
if sr == tg:
    print(_(u"tyle samo co w kopii"))
elif not sr:
    print(_(u"bez retencji (źródło nie przycina migawek)"))
else:
    print(", ".join(out))
PYEOF
}
# Karta (U65, pve10 2026-10-22): czekająca zmiana retencji źródła słowami -- karta mówiła
# "tyle samo co w kopii [zmiana]", czyli starą wartość przy gwiazdce nowej.
sargs_words() {   # P_SARGS (--src-tier=T --keep=N ...) -> "godzinowe 72, dobowe 3"
    local a t="" w out=""
    for a in ${P_SARGS[@]+"${P_SARGS[@]}"}; do
        case "$a" in
            --src-tier=*) t="${a#*=}" ;;
            --keep=*|--retain=*)
                case "$t" in *hourly) w="$(T godzinowe)" ;; *daily) w="$(T dobowe)" ;; *weekly) w="$(T tygodniowe)" ;;
                             *monthly) w="$(T miesięczne)" ;; *yearly) w="$(T roczne)" ;; *) w="$t" ;; esac
                out="${out:+$out, }$w ${a#*=}" ;;
            --drop-tier*) out="${out:+$out, }$t: $(T bez)" ;;
        esac
    done
    echo "${out:-?}"
}
# Karta (U65): obecne ustawienia silnika słowami; show-config raz na okno (pve10: 0,2 s).
engine_words() {
    [ -s "$TMPD/sc.json" ] || "$ZB" show-config "$NAME" --json >"$TMPD/sc.json" 2>/dev/null || { echo "?"; return 0; }
    "$PY" - "$TMPD/sc.json" "$NAME" <<'PYEOF' 2>/dev/null | tr -d '\r' || echo "?"
import sys, json
import os as _os
_C = json.load(open(_os.environ["ZFS_TUI_CAT"], encoding="utf-8")) if _os.environ.get("ZFS_TUI_CAT") else {}
def _(s): return _C.get(s, s)
names = {"history": _(u"historia"), "compression": _(u"kompresja"), "cipher": _(u"szyfr"), "autotune": _(u"autodobór"), "raw": "raw"}
out = []
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    for s in d.get("sections") or []:
        f = s.get("fields") or {}
        if s.get("kind") == "dataset" and f.get("pair_label") == sys.argv[2]:
            for k in ("history", "compression", "cipher", "autotune", "raw"):
                v = str(f.get(k) if f.get(k) is not None else "").strip()
                if v and v != "default":
                    out.append("%s %s" % (names[k], v))
            break
except Exception:
    print("?"); sys.exit(0)
print(", ".join(out) if out else _(u"fabryczne"))
PYEOF
}
engine_settings() {
    local c_h c_c c_x c_a c_r p_h p_c p_x p_a items n d v N out fab
    info "$(T 'Ustawienia silnika')" "$(T 'Czytam ustawienia relacji...')"
    if ! "$ZB" show-config "$NAME" --json >"$TMPD/sc.json" 2>"$TMPD/sc.err"; then
        wt --title "$(T 'Ustawienia silnika')" --msgbox "$(T 'show-config nie odpowiedział:\n')$(tail -3 "$TMPD/sc.err")" 12 "$W"
        return 0
    fi
    # Brak pola = ustawienie fabryczne ("default"); pierwsza sekcja dataset tej relacji.
    IFS=$'\t' read -r c_h c_c c_x c_a c_r < <("$PY" - "$TMPD/sc.json" "$NAME" <<'PYEOF'
import sys, json
out = ["default"] * 5
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    for s in d.get("sections") or []:
        f = s.get("fields") or {}
        if s.get("kind") == "dataset" and f.get("pair_label") == sys.argv[2]:
            for i, k in enumerate(("history", "compression", "cipher", "autotune", "raw")):
                v = str(f.get(k) if f.get(k) is not None else "").strip()
                if k == "autotune":
                    v = {"no": "no", "false": "no", "0": "no", "off": "no",
                         "yes": "yes", "true": "yes", "1": "yes", "on": "yes"}.get(v.lower(), v)
                if v:
                    out[i] = v.replace("\t", " ")
            break
except Exception:
    pass
print("\t".join(out))
PYEOF
)
    [ -n "${c_h:-}" ] || { c_h=default; c_c=default; c_x=default; c_a=default; }
    c_r="${c_r%$'\r'}"   # ostatnie pole: Python na Windows konczy linie CRLF
    p_h="$c_h"; p_c="$c_c"; p_x="$c_x"; p_a="$c_a"
    # Zmiana czekająca na liście -- okno startuje od niej, nie od zainstalowanej.
    for v in ${P_TRANSFER[@]+"${P_TRANSFER[@]}"}; do
        case "$v" in --history=*) p_h="${v#*=}" ;; --compression=*) p_c="${v#*=}" ;;
                     --cipher=*) p_x="${v#*=}" ;; --autotune=*) p_a="${v#*=}" ;; esac
    done
    while :; do
        geom
        # X10 (właściciel 2026-10-14): lustro (synchro) ma to samo co źródło -- "tylko różnica"
        # by temu przeczyła, więc w lustrze wiersza Historia nie ma.
        items=(); fab=" $(T '(fabryczne)')"
        [ "${MIRROR:-0}" = 1 ] || items+=(hist "$(eng_lbl "$(T Historia)")$(eng_hist_words "$p_h")$([ "$p_h" = default ] && echo "$fab")")
        # X2 (właściciel 2026-10-12): kopia LOKALNA nie ma łącza -- kompresji, szyfru SSH
        # ani autodoboru nie ma tu czego ustawiać (silnik i tak je pomija).
        if [ "$PEER" != - ]; then
            # X10: wysyłka zaszyfrowana (raw) -- szyfrowanych danych nie da się skompresować.
            case "${c_r:-default}" in yes|1|true) ;; *)
                items+=(comp "$(eng_lbl "$(T Kompresja)")$(eng_comp_words "$p_c")$([ "$p_c" = default ] && echo "$fab")") ;; esac
            v="$(T 'domyślny SSH')"; [ "$p_x" = default ] || v="$p_x"
            items+=(ciph "$(eng_lbl "$(T 'Szyfr SSH')")$v$([ "$p_x" = default ] && echo "$fab")")
            v="$(T tak)"; case "$p_a" in no) v="$(T nie)" ;; esac
            items+=(auto "$(eng_lbl "$(T 'Autodobór łącza')")$v$([ "$p_a" = default ] && echo "$fab")")
        fi
        # W17: wysyłka zaszyfrowana tylko do wglądu -- decyduje o niej pierwsza kopia,
        # zmiana = nowa kopia od zera (silniki odmawiają mieszania trybów).
        case "${c_r:-default}" in yes|1|true) items+=(raw "$(eng_lbl "$(T Szyfrowane)")$(T 'wysyłka zaszyfrowana (raw)')") ;; esac
        items+=(__reset__ "$(T 'Przywróć fabryczne')" __done__ "$(T Gotowe)")
        wt --title "$(Tv 'Ustawienia silnika: $NAME' '$NAME' "$NAME")" --ok-button "$(T Wybierz)" --cancel-button "$(T Wstecz)" --notags --default-item __done__ \
           --menu "$(T 'Jak przesyłane są kopie tej relacji.')" "$(fit $((${#items[@]} / 2 + 2)))" "$W" "$(lhfit $((${#items[@]} / 2)) 2)" "${items[@]}" || return 0
        case "$WT_OUT" in
            raw)
                wt --title "$(T 'Wysyłka zaszyfrowana')" --msgbox "$(T 'Źródło jest zaszyfrowane i kopie idą zaszyfrowane (raw): w celu leżą\nzaszyfrowane, ten host nie potrzebuje klucza.\n\nTego nie zmienia się w działającej relacji -- zmiana to nowa kopia od zera\n(usuń relację i załóż ją ponownie).')" 12 "$W"
                continue ;;
            hist)
                d="${p_h%%:*}"; [ "$d" = default ] && d=all
                eng_pick "$(T Historia)" "$(T 'Co przesyłać, gdy w celu brakuje kilku migawek.')" "$d" \
                    all    "$(T 'Wszystkie migawki pomiędzy -- pełna historia w celu')" \
                    newest "$(T 'Tylko różnica do najnowszej -- mniej miejsca, bez historii pośredniej')" \
                    auto   "$(T 'Auto -- wszystkie, a przy dużej zaległości tylko różnica')" || continue
                case "$WT_OUT" in
                    auto)
                        N=3; case "$p_h" in auto:*) N="${p_h#auto:}" ;; esac
                        while :; do
                            wt --title "$(T 'Historia: auto')" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" \
                               --inputbox "$(T 'Po ilu zgubionych przebiegach przejść na migawkę różnicową?')" 9 "$W" "$N" || continue 2
                            v="${WT_OUT// /}"
                            case "$v" in ''|*[!0-9]*) ;; *) [ "${#v}" -le 3 ] && [ "$((10#$v))" -ge 1 ] && { p_h="auto:$((10#$v))"; break; } ;; esac
                            wt --title "$(T 'Zła liczba')" --msgbox "$(Tv ''\''$WT_OUT'\'' -- podaj liczbę całkowitą od 1 do 999.' '$WT_OUT' "$WT_OUT")" 8 "$W"
                        done ;;
                    *) p_h="$WT_OUT" ;;
                esac ;;
            comp)
                eng_pick "$(T Kompresja)" "$(T 'Czy kompresować strumień kopii.')" "$p_c" \
                    default "$(T 'Fabryczna -- zdalnie zstd, lokalnie nic')" \
                    zstd    "zstd" \
                    gzip    "gzip (pigz)" \
                    none    "$(T 'Bez kompresji')" || continue
                p_c="$WT_OUT" ;;
            ciph)
                eng_pick "$(T 'Szyfr SSH')" "$(T 'Jakim szyfrem SSH idą kopie.')" "$p_x" \
                    default                       "$(T 'Domyślny SSH')" \
                    aes128-gcm@openssh.com        "$(T 'aes128-gcm (szybki na procesorach z AES-NI)')" \
                    chacha20-poly1305@openssh.com "$(T 'chacha20 (szybki bez AES-NI)')" || continue
                p_x="$WT_OUT" ;;
            auto)
                d="$p_a"; [ "$d" = default ] && d=yes
                eng_pick "$(T 'Autodobór łącza')" "$(T 'Czy silnik ma sam mierzyć łącze.')" "$d" \
                    yes "$(T 'Tak -- mierzy łącze i sam decyduje o kompresji')" \
                    no  "$(T Nie)" || continue
                p_a="$WT_OUT" ;;
            __reset__) p_h=default; p_c=default; p_x=default; p_a=default ;;
            __done__)
                ARGV=("$ZB" set-transfer "$NAME")
                [ "$p_h" = "$c_h" ] || ARGV+=("--history=$p_h")
                [ "$p_c" = "$c_c" ] || ARGV+=("--compression=$p_c")
                if [ "$PEER" != - ]; then
                    [ "$p_x" = "$c_x" ] || ARGV+=("--cipher=$p_x")
                    [ "$p_a" = "$c_a" ] || ARGV+=("--autotune=$p_a")
                fi
                [ "${#ARGV[@]}" -gt 3 ] || { P_TRANSFER=(); return 0; }
                info "$(T 'Ustawienia silnika')" "$(T 'Liczę plan...')"
                if ! "${ARGV[@]}" --plan >"$TMPD/stplan.txt" 2>&1; then
                    out="$(verb_refusal "$TMPD/stplan.txt")"
                    [ -n "$out" ] || out="$(tail -3 "$TMPD/stplan.txt")"
                    wt --title "$(T 'Czasownik odmówił -- nic nie zmieniono')" --msgbox "$(printf '%s' "$out" | fold -s -w $((W - 6)))" 12 "$W"
                    continue
                fi
                {
                    echo "$(T 'PLAN -- nic jeszcze nie zostało zmienione:')"
                    echo
                    grep "^Relation '" "$TMPD/stplan.txt"
                    echo
                    echo "Komenda:  $(for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done)--yes"
                } >"$TMPD/stplan2.txt"
                # Plan przeszedł -- na listę zmian.
                P_TRANSFER=("${ARGV[@]:3}"); cp "$TMPD/stplan2.txt" "$TMPD/p_transfer.txt"
                return 0 ;;
        esac
    done
}

# WSTECZ = JEDEN KROK (właściciel, W5, 2026-10-11): z każdego okna po menu Wstecz wraca do
# menu, nie wyrzuca z procedury. Wstecz w samym menu to krok z powrotem na F3.
# DATASETY = JEDNO WYWOŁANIE (projekt „relacja = config”, 2026-10-25): drzewo daje pozycje
# relacji (basket_entries), a zmiana to `set-datasets NAZWA --dataset=DS:flat|no ...` -- to samo
# dla każdego rodzaju relacji. P_ENT: pozycje docelowe ("DS<TAB>flat|no"), puste = bez zmiany.
ds_args() { printf '%s\n' "$P_ENT" | awk -F'\t' 'NF { printf "--dataset=%s:%s\n", $1, $2 }'; }
P_HOST=""; P_ENT=""; P_ADDED=""; P_REMOVED=""; P_EDIT=(); P_EDIT_WORDS=""; P_TIERS=(); P_RARGS=(); P_SARGS=(); P_TRANSFER=()
pending_count() {
    local n=0
    [ -n "$P_HOST" ] && n=$((n + 1))
    [ -n "$P_ENT" ] && n=$((n + 1))
    [ "${#P_EDIT[@]}" -gt 0 ] && n=$((n + 1))
    [ "${#P_TIERS[@]}" -gt 0 ] && n=$((n + 1))
    [ "${#P_TRANSFER[@]}" -gt 0 ] && n=$((n + 1))
    echo "$n"
}
# ZAPISZ ZMIANY: jeden plan wszystkich czekających zmian, jedno WYKONAJ, potem po kolei:
# adres, datasety, szablon albo tabela szczebli, ustawienia silnika. Każdy krok to zwykły
# czasownik z --yes; pierwszy, który odmówi, zatrzymuje resztę (to, co przed nim, zostaje).
save_all() {
    local n rc=0 a k=0
    {
        echo "$(T 'PLAN -- nic jeszcze nie zostało zmienione. Po WYKONAJ, po kolei:')"
        echo
        [ -n "$P_HOST" ] && { k=$((k + 1)); echo "$(Tv '$k. Adres źródła: $P_HOST  (activate --host, sprawdzenie, że to ten sam host)' '$k' "$k" '$P_HOST' "$P_HOST")"; echo; }
        if [ -n "$P_ENT" ]; then
            k=$((k + 1)); echo "$(Tv '$k. Datasety:' '$k' "$k")"
            # Kampania wariantów 2026-10-22: dataset dodany z powrotem szedł PRZYROSTOWO od kopii, która
            # tu została -- "pierwsza pełna kopia" wprowadzała w błąd.
            # Słowa z rodzaju relacji (2026-10-26): relacja bez kopii mówi o migawkach, nie o kopiach.
            if [ "${RMODE:-}" = snaponly ] || { [ "${RMODE:-}" = local ] && { [ -z "${TGT:-}" ] || [ "$TGT" = - ]; }; }; then
                for n in $P_ADDED; do echo "$(Tv '   DOJDĄ:    $n  (pierwsza migawka od razu)' '$n' "$n")"; done
                for n in $P_REMOVED; do echo "$(Tv '   ODPADNĄ:  $n  (jego migawki ZOSTAJĄ, nikt ich nie przycina)' '$n' "$n")"; done
            else
            for n in $P_ADDED; do echo "$(Tv '   DOJDĄ:    $n  (pierwsza kopia od razu; przyrostowo, gdy kopia już tu jest)' '$n' "$n")"; done
            for n in $P_REMOVED; do echo "$(Tv '   ODPADNĄ:  $n  (kopie na tym hoście ZOSTAJĄ)' '$n' "$n")"; done
            fi
            echo "$(T '   Po zmianie relacja obejmuje:')"
            printf '%s\n' "$P_ENT" | while IFS=$'\t' read -r n r; do
                [ -n "$n" ] || continue
                if [ "$r" = flat ]; then echo "     [x] $n  $(T '(z dziećmi, także przyszłymi)')"; else echo "     [-] $n  $(T '(sam dataset; dzieci tylko wymienione)')"; fi
            done
            echo
        fi
        if [ "${#P_EDIT[@]}" -gt 0 ]; then k=$((k + 1)); echo "$(T '%s. Szablon: %s -> %s' "$k" "$(cur_words)" "$P_EDIT_WORDS")"; sed -n '3,$p' "$TMPD/p_edit.txt" | grep -v '^Komenda:' | plan_words | sed 's/^/   /'; echo; fi
        if [ "${#P_TIERS[@]}" -gt 0 ]; then k=$((k + 1)); echo "$(T '%s. Harmonogram i retencja (tabela):' "$k")"; sed -n '3,$p' "$TMPD/p_tiers.txt" | grep -v '^Komenda:' | plan_words | sed 's/^/   /'; echo; fi
        if [ "${#P_TRANSFER[@]}" -gt 0 ]; then k=$((k + 1)); echo "$(Tv '$k. Ustawienia silnika:' '$k' "$k")"; grep "^Relation '" "$TMPD/p_transfer.txt" | sed 's/^/   /'; echo; fi
        echo "$(T 'Komendy:')"
        [ -n "$P_HOST" ] && echo "  $(shq "$ZB") activate $NAME --host=$P_HOST --skip-final-catchup --yes"
        [ -n "$P_ENT" ] && echo "  $(shq "$ZB") set-datasets $NAME $(ds_args | tr '\n' ' ')--yes"
        [ "${#P_EDIT[@]}" -gt 0 ] && echo "  $(shq "$ZB") edit-relation $NAME $(for a in "${P_EDIT[@]}"; do printf '%s ' "$(shq "$a")"; done)--yes"
        [ "${#P_TIERS[@]}" -gt 0 ] && echo "  $(shq "$ZB") set-tiers $NAME $(for a in "${P_TIERS[@]}"; do printf '%s ' "$(shq "$a")"; done)--yes"
        [ "${#P_TRANSFER[@]}" -gt 0 ] && echo "  $(shq "$ZB") set-transfer $NAME $(for a in "${P_TRANSFER[@]}"; do printf '%s ' "$(shq "$a")"; done)--yes"
    } >"$TMPD/saveplan.txt"
    # Właściciel 2026-10-29 („Za dużo tych okien potwierdzających”): w oknie zostają zmiany
    # słowami; pełny plan (z liniami crona) idzie do pliku obok dziennika, okno podaje ścieżkę.
    local planf="$TMPD/saveplan-full.txt"
    { cat "$TMPD/saveplan.txt"; for f in p_edit p_tiers p_transfer; do [ -s "$TMPD/$f.txt" ] && cat "$TMPD/$f.txt"; done; } >"$planf"
    if [ -n "${ZFS_TUI_LOG:-}" ]; then cp -f "$planf" "${ZFS_TUI_LOG%.log}-plan.txt" 2>/dev/null && planf="${ZFS_TUI_LOG%.log}-plan.txt"; fi
    { echo; echo "$(Tv 'Pełny plan (z liniami crona): $planf' '$planf' "$planf")"; } >>"$TMPD/saveplan.txt"
    # Enter = WYKONAJ, jak w kreatorze (U25: jedno zachowanie). Plan dłuższy niż ekran: okno
    # z przewijaniem trzyma fokus na tekście i Enter nic nie robi (zmierzone na pve10,
    # 2026-10-19) -- więc najpierw sam plan do przewinięcia (textbox_read: Tab -> Dalej na ramce),
    # potem krótkie pytanie.
    geom
    if [ "$(fold -s -w $((W - 4)) "$TMPD/saveplan.txt" | grep -c '')" -gt $((H - 6)) ]; then
        textbox_read "$(Tv 'Zmień relację $NAME -- plan wszystkich zmian' '$NAME' "$NAME")" "$TMPD/saveplan.txt" "$(T Dalej)" || return 1
        wt --title "$T_CHG" --yes-button "$(T WYKONAJ)" --no-button "$(T Wstecz)" \
           --yesno "$(Tv 'Wykonać zmiany z planu ($(pending_count))?\nWstecz = lista zmian, nic nie zmienione.' '$(pending_count)' "$(pending_count)")" 9 "$W" || return 1
    else
        yesno_text "$TMPD/saveplan.txt" "$(Tv 'Zmień relację $NAME -- plan wszystkich zmian' '$NAME' "$NAME")" "$(T WYKONAJ)" "$(T Wstecz)" || return 1
    fi
    # U64 (właściciel 2026-10-21: "czarny ekran ponad 15 sekund"): kroki biegną za oknem
    # postępu (wt-lib run_progress), wynik w oknie. Kroki idą w podpowłoce, więc to, że
    # edit-relation przeszło (DONE), wraca znacznikiem w $TMPD.
    : >"$TMPD/run.log"; rm -f "$TMPD/edit.done"
    run1() { printf '\n$ %s\n' "$*"; "$@" 2>&1; }
    apply_steps() {
        local rc=0 n
        if [ -n "$P_HOST" ]; then run1 "$ZB" activate "$NAME" "--host=$P_HOST" --skip-final-catchup --yes || rc=$?; fi
        if [ "$rc" -eq 0 ] && [ -n "$P_ENT" ]; then
            local -a _da=(); mapfile -t _da < <(ds_args)
            run1 "$ZB" set-datasets "$NAME" "${_da[@]}" --yes || rc=$?
        fi
        if [ "$rc" -eq 0 ] && [ "${#P_EDIT[@]}" -gt 0 ]; then run1 "$ZB" edit-relation "$NAME" "${P_EDIT[@]}" --yes || rc=$?; [ "$rc" -eq 0 ] && : >"$TMPD/edit.done"; fi
        if [ "$rc" -eq 0 ] && [ "${#P_TIERS[@]}" -gt 0 ]; then run1 "$ZB" set-tiers "$NAME" "${P_TIERS[@]}" --yes || rc=$?; fi
        if [ "$rc" -eq 0 ] && [ "${#P_TRANSFER[@]}" -gt 0 ]; then run1 "$ZB" set-transfer "$NAME" "${P_TRANSFER[@]}" --yes || rc=$?; fi
        return "$rc"
    }
    run_progress "$(Tv 'Zmień relację $NAME: wykonuję' '$NAME' "$NAME")" "$TMPD/run.log" apply_steps || rc=$?
    [ -e "$TMPD/edit.done" ] && DONE=1
    [ -n "${ZFS_TUI_LOG:-}" ] && { cat "$TMPD/run.log"; echo "rc=$rc"; } >>"$ZFS_TUI_LOG" 2>/dev/null
    # Sukces jednym zdaniem = linia komunikatu GUI, bez okna z <Ok> (#993, "Na pewno? i koniec");
    # dziennik dopisuje tam GUI (window_end_message). Na pve10 2026-10-29 okno zostawalo, bo
    # druga linia "Dziennik: ..." robila z sukcesu tekst wielowierszowy.
    result_box "$T_CHG" "$rc" "$TMPD/run.log" "$(Tv 'Relacja '\''$NAME'\'' zmieniona (rc=0).' '$NAME' "$NAME")" \
        "$(T 'ZATRZYMANE -- kroki przed tym, który odmówił, zostały.')"
    exit "$rc"
}
while :; do
ACTION=""
while :; do
    # U65: czynność otwarta wprost z okna relacji (EDIT_DO) już się odbyła -> koniec.
    [ "$DIRECT" -eq 1 ] && [ -z "$FORCE_ACTION" ] && { clear 2>/dev/null; exit 0; }
    geom
    np=$(pending_count)
    # KARTA RELACJI (U25, właściciel 2026-10-20): ta sama karta co kreator (card_menu w
    # wt-lib.sh), wypełniona. Stałe -- rodzaj, cel, nazwa, konto, dodatkowe -- są wpisane w
    # kopie, cron i rekord; ich zmiana to nowa relacja (Enter mówi, jak).
    _rodzaj="backup"
    if [ "$SNAPONLY" -eq 1 ]; then _rodzaj="migawki zdalne"
    elif [ "$PEER" = - ] && { [ "$TGT" = - ] || [ -z "$TGT" ]; }; then _rodzaj="migawki lokalne"
    elif [ "$PEER" = - ]; then _rodzaj="kopia lokalna"
    elif [ "${MIRROR:-0}" = 1 ]; then _rodzaj="lustro"; fi
    # _rodzaj to kod (porównywany niżej w case); na ekranie idzie jego tłumaczenie _rt.
    case "$_rodzaj" in
        "migawki zdalne")  _rt="$(T 'migawki zdalne')" ;;
        "migawki lokalne") _rt="$(T 'migawki lokalne')" ;;
        "kopia lokalna")   _rt="$(T 'kopia lokalna')" ;;
        lustro)            _rt="$(T lustro)" ;;
        *)                 _rt="$_rodzaj" ;;
    esac
    _zm="$(T '[zmiana]')"
    _ds="$(printf '%s' "$SRCS" | tr ',' '\n' | grep -vc '^-\?$')"
    # Jak w kreatorze: liczba i nazwy; adres -- ten, przez który relacja chodzi TERAZ.
    _ds="$_ds: ${SRCS//,/, }"
    _ep="$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); r=(d.get("relations") or [{}])[0]; e=r.get("active_endpoint") or ""; print(e[:-3] if e.endswith(":22") else e)' "$TMPD/st.json" 2>/dev/null | tr -d '\r')"
    _ep="${_ep:-$SRCHOST}"
    _dsp=""; [ -n "$P_ENT" ] && [ -z "$P_ADDED$P_REMOVED" ] && _dsp="  $_zm ~[x]/[-]"
    [ -n "$P_ADDED$P_REMOVED" ] && _dsp="  $_zm$(for n in $P_ADDED; do printf ' +%s' "$n"; done)$(for n in $P_REMOVED; do printf ' -%s' "$n"; done)"
    _sz="$(cur_words)"
    _pw="$(awk -F'\t' -v n="$CUR_P" '$1==n{print $2; exit}' "$TMPD/prof.tsv" 2>/dev/null | sed -e "s/^$CUR_P  *//" -e 's/  */ /g')"
    [ -n "$_pw" ] && _sz="$_sz -- $_pw"
    [ "${#P_EDIT[@]}" -gt 0 ] && _sz="$(cur_words) -> $P_EDIT_WORDS $_zm"
    [ "${#P_RARGS[@]}" -gt 0 ] && _sz="$_sz, $(T tabela) $_zm"
    # U65 (uwaga 3: "Silnik: jak w configu -- nie wiadomo co"): wartości słowami, nie "jak w configu".
    _sr="$(srcret_words)"
    [ "${#P_SARGS[@]}" -gt 0 ] && _sr="$_sr -> $(sargs_words) $_zm"
    _en="$(engine_words)"; [ "${#P_TRANSFER[@]}" -gt 0 ] && _en="$(ptransfer_words) $_zm"   # sama nowa wartość: z "stare ->" [zmiana] wypadało za kartę
    # U65 (właściciel 2026-10-21: "do kompletnej przebudowy"; makieta 2026-10-21): to, czego nie
    # da się zmienić (rodzaj, nazwa, konto, cel), stoi w NAGŁÓWKU, nie na liście; na liście tylko
    # to, co się zmienia, a zmieniona pozycja ma '*' i "[zmiana]". Pod kreską tylko zapis.
    # Kopia teraz = F7 na F3; ręczna edycja i zapis jako szablon = 'c' i 's' w oknie relacji.
    CARD_TAGS=(); CARD_NAMES=(); CARD_VALUES=(); CARD_FIXED=()
    er_row() {   # <tag> <nazwa> <wartość> <zmieniona 0/1>
        CARD_TAGS+=("$1"); CARD_VALUES+=("$3"); CARD_FIXED+=(0)
        if [ "$4" -eq 1 ]; then CARD_NAMES+=("* $2"); else CARD_NAMES+=("  $2"); fi
    }
    # U111: ten wiersz zmienia ADRES, więc adres zostaje -- z nazwą hosta przed nim
    _epn="$(host_name "${_ep%:*}" "$NAME")"; [ "$_epn" = "${_ep%:*}" ] || _ep="$_epn ($_ep)"
    if [ "$PEER" != - ]; then er_row adres "$(T Źródło)" "$_ep${P_HOST:+ -> $P_HOST $_zm}" "$([ -n "$P_HOST" ] && echo 1 || echo 0)"; fi
    er_row dane "$(T Datasety)" "$_ds$_dsp" "$([ -n "$_dsp" ] && echo 1 || echo 0)"
    er_row harmon "$(T Harmonogram)" "$_sz" "$([ "${#P_EDIT[@]}" -gt 0 ] || [ "${#P_RARGS[@]}" -gt 0 ] && echo 1 || echo 0)"
    case "$_rodzaj" in backup|"kopia lokalna")
        er_row srcret "$(T 'Retencja źródła')" "$_sr" "$([ "${#P_SARGS[@]}" -gt 0 ] && echo 1 || echo 0)" ;; esac
    # Pasywna kopia lokalna (replika pvesr, MIRROR=1): bez historii i bez łącza okno silnika
    # było puste -- "Przywróć fabryczne" i "Gotowe" (właściciel 2026-10-26, pve2-nextcloud).
    _eng=1; [ "$_rodzaj" = "kopia lokalna" ] && [ "${MIRROR:-0}" = 1 ] && _eng=0
    [ "$_eng" -eq 1 ] && case "$_rodzaj" in "migawki zdalne"|"migawki lokalne") ;; *)
        er_row silnik "$(T Silnik)" "$_en" "$([ "${#P_TRANSFER[@]}" -gt 0 ] && echo 1 || echo 0)" ;; esac
    CARD_ACT_TAGS=(wykonaj)
    if [ "$np" -gt 0 ]; then CARD_ACT_LABELS=("$(Tv 'ZAPISZ ZMIANY ($np) -- najpierw plan do potwierdzenia' '$np' "$np")")
    else CARD_ACT_LABELS=("$(T 'Zapisz zmiany (brak zmian)')"); fi
    _hdr="$_rt${SRCHOST:+ $(Tv 'z $SRCHOST' '$SRCHOST' "$SRCHOST")}   $(T nazwa) $NAME   $(T konto) $([ "$ACCT_U" = - ] && echo root || echo "$ACCT_U")"
    case "$_rodzaj" in backup|"kopia lokalna") _hdr="$_hdr   $(T cel) $TGT" ;; esac
    if [ -n "$FORCE_ACTION" ]; then
        WT_OUT="$FORCE_ACTION"; FORCE_ACTION=""
    else
    card_menu "$(Tv 'Zmiana relacji $NAME' '$NAME' "$NAME")" "$(Tv '$_hdr\nCo zmienić? Tego wyżej się nie zmienia (inaczej: nowa relacja). Zapis dopiero w "Zapisz zmiany".' '$_hdr' "$_hdr")" "${LAST_ACTION:-dane}" "$(T Wstecz)" || {
           if [ "$np" -gt 0 ]; then
               wt --title "$(T 'Porzucić zmiany?')" --yes-button "$(T Porzuć)" --no-button "$(T Wstecz)" --defaultno \
                  --yesno "$(Tv 'Na liście czeka zmian: $np. Wyjść bez zapisu?' '$np' "$np")" 8 "$W"
               [ $? -ne 0 ] && continue   # Wróć albo Esc = zostań
           fi
           clear 2>/dev/null; wt_end_nochange "$(T 'Zmień relację: przerwane, nic nie zmieniono')"; exit 1; }
    fi
    ACTION="$WT_OUT"; LAST_ACTION="$ACTION"
    case "$ACTION" in
        __sep__) LAST_ACTION=wykonaj; continue ;;
        harmon) ACTION=szablon ;;
        srcret)
            if [ "${#P_EDIT[@]}" -gt 0 ]; then
                wt --title "$(T 'Retencja źródła')" --msgbox "$(T 'Nowy szablon czeka na zapis -- liczby źródła ustawiasz w oknie zaraz po wyborze\nszablonu (Harmonogram). Najpierw zapisz zmiany, potem wróć tutaj.')" 9 "$W"
                continue
            fi
            harm_flow src; continue ;;
    esac
    [ "$ACTION" = wykonaj ] && {
        [ "$np" -gt 0 ] || { wt --title "$(T 'Zapisz zmiany')" --msgbox "$(T 'Nic nie zmieniono -- nie ma czego zapisać.')" 8 "$W"; continue; }
        save_all || continue
    }
    case "$ACTION" in
        # snaponly: tabela -> ukryty szablon relacji -> edit-relation --profile= (blok
        # "harm" w pętli kroków niżej); harm_flow czyta/zapisuje szczeble KOPII (set-tiers).
        harm) [ "$SNAPONLY" -eq 1 ] && break; harm_flow; continue ;;
        adres) address_flow; continue ;;
        szablon) break ;;
        silnik) engine_settings; continue ;;
        config)
            # edit-config (2026-10-08): edytor dostaje caly terminal, jak crontab -e;
            # czasownik sam pyta o instalacje i pokazuje, co zrobi na zrodle.
            clear 2>/dev/null
            "$ZB" edit-config "$NAME"; RC=$?
            # 3 = zamkniety bez zmian: nic do czytania, wracamy od razu (uwaga 22)
            [ "$RC" -eq 3 ] && { wt_end_nochange "$(T 'Zmień relację: przerwane, nic nie zmieniono')"; exit 0; }
            # Zainstalowane (rc=0): od razu z powrotem, bez "Enter = dalej" -- pytanie
            # "Install?" czasownika bylo jedynym potwierdzeniem (wlasciciel 2026-10-29).
            [ "$RC" -eq 0 ] && { wt_end "$(T 'Zmień relację: config zainstalowany')"; exit 0; }
            echo "$(Tv '=== edit-config zakończony (rc=$RC). Enter = dalej' '$RC' "$RC")"
            [ -t 0 ] && read -r _
            exit "$RC" ;;
        zapisz)
            # Z RELACJI SZABLON (właściciel 2026-10-09): kopia jej szablonu celu pod nową
            # nazwą, zwykła (bez znaku "ukryty") -- pojawi się na F5 i w kreatorze.
            [ -n "$CUR_P" ] || { wt --title "$(T 'Brak szablonu')" --msgbox "$(Tv 'Relacja '\''$NAME'\'' nie ma zapisanego szablonu -- nie ma czego skopiować.' '$NAME' "$NAME")" 8 "$W"; continue; }
            wt --title "$(T 'Zapisz jako szablon')" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" \
               --inputbox "$(Tv 'Nazwa nowego szablonu (litery, cyfry, . _ -).\nTrzyma i robi migawki tak jak relacja $NAME teraz: $(cur_words).' '$NAME' "$NAME" '$(cur_words)' "$(cur_words)")" 10 "$W" "$NAME-$(T szablon)" || continue
            n="${WT_OUT// /}"
            case "$n" in ''|-*|*[!A-Za-z0-9._-]*) wt --title "$(T 'Zła nazwa')" --msgbox "$(Tv ''\''$WT_OUT'\'' -- tylko litery, cyfry, kropka, myślnik, podkreślenie; na początku nie myślnik.' '$WT_OUT' "$WT_OUT")" 8 "$W"; continue ;; esac
            if awk -F'\t' -v n="$n" '$1==n{f=1} END{exit !f}' "$TMPD/prof.tsv"; then
                wt --title "$(T 'Nazwa zajęta')" --msgbox "$(Tv 'Szablon '\''$n'\'' już jest. Podaj inną nazwę.' '$n' "$n")" 8 "$W"; continue
            fi
            info "$(T 'Zapisz jako szablon')" "$(Tv 'Zapisuję szablon $n...' '$n' "$n")"
            if out=$("$ZB" save-profile "--from=$CUR_P" "--as=$n" "--description=$(Tv 'Ustawienia relacji $NAME' '$NAME' "$NAME")" 2>&1); then
                wt --title "$(T 'Szablon zapisany')" --msgbox "$(Tv 'Szablon '\''$n'\'' zapisany -- jest na F5 i w kreatorze nowej relacji.' '$n' "$n")" 8 "$W"
                load_lists
            else
                wt --title "$(T 'Czasownik odmówił -- nic nie zapisano')" --msgbox "$(printf '%s' "$out" | tail -6 | fold -s -w $((W - 6)))" 14 "$W"
            fi
            continue ;;
        dane)
            # DATASETY = TO SAMO OKNO CO W KREATORZE (W4, właściciel 2026-10-11): koszyk
            # z obecnymi datasetami relacji (z configu), dowolnie wiele zmian, potem JEDEN
            # plan i WYKONAJ (set-datasets). Bez "Sposób" (to inna relacja).
            info "$(T Datasety)" "$(Tv 'Czytam datasety z $SRCHOST...' '$SRCHOST' "$SRCHOST")"
            if ! "$ZB" list-datasets ${LDS_ARGS[@]+"${LDS_ARGS[@]}"} --json --own-snapshots >"$TMPD/ds.json" 2>"$TMPD/ds.err" \
               || ! basket_tree_from_json "$TMPD/ds.json"; then
                wt --title "$(T 'Lista datasetów niedostępna')" --msgbox "$(Tv 'list-datasets $SRCHOST nie odpowiedział:\n' '$SRCHOST' "$SRCHOST")$(tail -3 "$TMPD/ds.err")" 12 "$W"; continue
            fi
            # Obecny wybór z CONFIGU (relation-sources): pozycje -> korzenie i wyjątki w drzewie.
            # Czekająca zmiana (P_ENT) -- drzewo startuje od niej.
            "$ZB" relation-sources "$NAME" >"$TMPD/ents.tsv" 2>"$TMPD/ents.err" || : >"$TMPD/ents.tsv"
            CUR_ENT="$(sort "$TMPD/ents.tsv")"
            [ -n "$P_ENT" ] && printf '%s\n' "$P_ENT" >"$TMPD/ents.tsv"
            B_ROOT=(); B_EXCL=(); B_CLOSED=""
            while IFS=$'\t' read -r _k _r _e; do
                [ "$_k" = C ] && { B_CLOSED="${B_CLOSED:+$B_CLOSED$'\n'}$_r"; continue; }
                [ "$_k" = B ] || continue
                B_ROOT+=("$_r"); B_EXCL+=("$(printf '%s' "$_e" | tr '\037' '\n')")
            done < <(basket_from_entries "$TMPD/ds.json" "$TMPD/ents.tsv")
            # X12: relacja lokalna widzi w drzewie własny cel -- kopie nie są źródłem (X21).
            BASKET_HIDE=""; [ "$PEER" = - ] && [ "${TGT:--}" != - ] && BASKET_HIDE="$TGT"
            while :; do
                # Słowa drzewa z rodzaju relacji: "Co kopiować" / "Gdzie robić migawki".
                _bnc=0; [ "${RMODE:-}" = local ] && { [ -z "${TGT:-}" ] || [ "$TGT" = - ]; } && _bnc=1
                MODE="${RMODE:-}" NOCOPY="$_bnc" basket_step || continue 2
                printf '%s\n' "$CUR_ENT" >"$TMPD/cur-ents.tsv"
                NEW_ENT="$(basket_entries "$TMPD/ds.json" "$TMPD/cur-ents.tsv" | sort)"
                if [ "$NEW_ENT" = "$CUR_ENT" ]; then P_ENT=""; P_ADDED=""; P_REMOVED=""; continue 2; fi
                # Do pokazania na liście: co dochodzi, co odpada, co zmienia rekurencję.
                P_ADDED="$(comm -13 <(printf '%s\n' "$CUR_ENT" | cut -f1) <(printf '%s\n' "$NEW_ENT" | cut -f1) | grep .)"
                P_REMOVED="$(comm -23 <(printf '%s\n' "$CUR_ENT" | cut -f1) <(printf '%s\n' "$NEW_ENT" | cut -f1) | grep .)"
                # X21: sprawdzone PRZED WYKONAJ -- plan czasownika (bez --yes) albo jego odmowa.
                info "$(T Datasety)" "$(T 'Sprawdzam zmiany (plan czasownika, nic nie zmienia)...')"
                P_ENT="$NEW_ENT"
                _da=(); mapfile -t _da < <(ds_args)
                if ! "$ZB" set-datasets "$NAME" "${_da[@]}" >"$TMPD/dschk.txt" 2>&1; then
                    P_ENT=""; P_ADDED=""; P_REMOVED=""
                    wt --title "$(T 'Tej zmiany nie da się zrobić -- nic nie zmieniono')" --msgbox "$(verb_refusal "$TMPD/dschk.txt" | fold -s -w $((W - 6)))" 12 "$W"
                    continue
                fi
                continue 2
            done ;;
    esac
done

PROFILE="${CUR_P:-default}"; SRCPROF=""; SRCKEEP=""
step=1
while :; do
    geom
    if [ "$step" -eq 1 ] && [ "$ACTION" = szablon ]; then
        # U25: "Harmonogram" = jedno pole jak w kreatorze -- na górze "Ręcznie…" (tabela).
        items=(__manual__ "$(clip_label "$(printf '%-9s%s' '' "$(T 'Ręcznie…  tabela szczebli: sposób, szczeble, liczby, zamrażanie')")" $((W - 10)))")
        while IFS=$'\t' read -r n t; do
            [ -n "$n" ] || continue
            mark="         "; [ "$n" = "$CUR_P" ] && mark="$(T '[obecny]') "
            items+=("$n" "$(clip_label "$mark$t" $((W - 10)))")
        done <"$TMPD/prof.tsv"
        def="$PROFILE"; awk -F'\t' -v n="$def" '$1==n{f=1} END{exit !f}' "$TMPD/prof.tsv" || def="${items[2]:-${items[0]}}"
        [ "$CUR_P" = "$HNAME" ] && def=__manual__
        wt --title "$(Tv 'Zmień relację $NAME -- użyj szablonu' '$NAME' "$NAME")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" --notags --default-item "$def" \
           --menu "$(Tv 'Obecny szablon: $(cur_words)\nSekcje relacji zostaną wygenerowane od nowa z wybranego szablonu\n(retencja, harmonogramy). Dane nie są przenoszone, pełna kopia od nowa nie jest potrzebna.\nTen sam szablon = odświeżenie (rozrzut minut, retencja źródła per szczebel).' '$(cur_words)' "$(cur_words)")" \
           "$(fit $((${#items[@]} / 2 + 5)))" "$W" "$(lhfit $((${#items[@]} / 2)) 4)" "${items[@]}" || continue 2
        if [ "$WT_OUT" = __manual__ ]; then
            # Ręcznie: tabela szczebli (snaponly -- blok "harm" niżej, ukryty szablon relacji).
            if [ "$SNAPONLY" -eq 1 ]; then ACTION=harm; step=1; continue; fi
            harm_flow; continue 2
        fi
        PROFILE="$WT_OUT"; step=2; continue
    fi
    if [ "$step" -eq 1 ] && [ "$ACTION" = harm ]; then
        # Ta sama tabela co szablon na F5 (sposób, wszystkie szczeble, liczby, zamrażanie),
        # startuje z obecnego szablonu relacji; wynik = ukryty szablon relacja-<NAZWA>.
        base="${CUR_P:-default}"
        clear 2>/dev/null
        _ttl="$(Tv 'Harmonogram i retencja: W CELU KOPII – $(hostname -s 2>/dev/null || hostname)' '$(hostname -s 2>/dev/null || hostname)' "$(hostname -s 2>/dev/null || hostname)")"
        [ "$SNAPONLY" -eq 1 ] && _ttl="$(Tv 'Harmonogram i retencja: MIGAWKI NA ŹRÓDLE – $SRCNAME' '$SRCNAME' "$SRCNAME")"
        ZFS_BACKUP="$ZB" bash "$HERE/tui/template.sh" relation "$base" "$TMPD/rargs" "$_ttl" \
            || continue 2
        mapfile -t RARGS <"$TMPD/rargs"
        if [ "${#RARGS[@]}" -eq 0 ] && [ "$base" = "$HNAME" ]; then
            PROFILE="$HNAME"          # nic nie zmienione w tabeli -- szablon relacji zostaje
        else
            HFILE="$(head -1 "$TMPD/hfile.txt" 2>/dev/null)"
            if [ -n "$HFILE" ] && [ -z "$HBACKUP" ] && [ -f "$HFILE" ]; then
                HBACKUP="$TMPD/hidden.bak"; cp -p "$HFILE" "$HBACKUP"
            fi
            info "$(T 'Harmonogram i retencja kopii w celu i źródle')" "$(T 'Zapisuję ustawienia relacji...')"
            if ! out=$("$ZB" save-profile "--from=$base" "--as=$HNAME" --hidden --force ${RARGS[@]+"${RARGS[@]}"} "--description=$(Tv 'Własne ustawienia relacji $NAME' '$NAME' "$NAME")" 2>&1); then
                wt --title "$(T 'Czasownik odmówił -- nic nie zmieniono')" --msgbox "$(printf '%s' "$out" | grep -E 'FATAL' | tail -1 | sed 's/^FATAL: //' | fold -s -w $((W - 6)))" 14 "$W"
                continue
            fi
            HIDDEN_DIRTY=1
            load_lists
            [ -n "$HFILE" ] || HFILE="$(head -1 "$TMPD/hfile.txt" 2>/dev/null)"
            PROFILE="$HNAME"
        fi
        step=2; continue
    fi
    if [ "$step" -eq 2 ] && [ "$SNAPONLY" -eq 1 ]; then
        # Bez okna "w źródle kopii": szablon relacji snaponly sam jest retencją źródła.
        : >"$TMPD/srcargs"; SRCPROF=""
    elif [ "$step" -eq 2 ]; then
        if [ "$ACTION" = szablon ]; then
            src_override_warning
            if [ -s "$TMPD/srcwarn.txt" ]; then
                { echo "$(Tv 'Szablon $PROFILE ustawi liczby w ŹRÓDLE tak jak w szablonie:' '$PROFILE' "$PROFILE")"; echo; cat "$TMPD/srcwarn.txt"; echo
                  echo "$(T 'Jeśli źródło ma trzymać inaczej, zmień liczby w następnym oknie')"
                  echo "$(T '(retencja źródła) albo później w '\''Harmonogram i retencja'\''.')"; } >"$TMPD/srcwarn2.txt"
                wt --title "$(T 'Uwaga: szablon nadpisze liczby w źródle')" --ok-button "$(T Dalej)" --msgbox "$(cat "$TMPD/srcwarn2.txt")" "$(fit "$(grep -c '' "$TMPD/srcwarn2.txt")")" "$W"
            fi
        fi
        # RETENCJA ŹRÓDŁA: to samo okno-tabela co w kreatorze (uwaga 10).
        src_prefill
        SRC_TITLE="$(Tv 'Retencja: W ŹRÓDLE KOPII – $SRCNAME' '$SRCNAME' "$SRCNAME")"
        # CONFIG JAKO JEDYNE ŹRÓDŁO: bez pochodnego szablonu źródła (<P>-src-...). Szablon
        # idzie na relację ze źródłem jak cel, a różnice źródła (--src-tier...) jadą w TYM
        # SAMYM wywołaniu edit-relation -- jedna podmiana configu (X27 etap B).
        : >"$TMPD/srcargs"
        SRC_ARGS_OUT="$TMPD/srcargs" SRC_ARGS_BASE=target source_retention_editor || { step=1; continue; }
        SRCPROF=""
    fi
    SARGS=(); [ -s "$TMPD/srcargs" ] && mapfile -t SARGS <"$TMPD/srcargs"
    # X5 (wlasciciel 2026-10-12): Wstecz = JEDEN krok -- z planu (i po odmowie czasownika)
    # wraca do okna retencji zrodla, gdy bylo pokazane; inaczej do tabeli celu.
    back=1; [ "$step" -eq 2 ] && [ "${SRC_SHOWN:-0}" = 1 ] && back=2
    # X27 (właściciel 2026-10-14): szablon i liczby źródła JEDNYM zapisem -- edit-relation
    # przyjmuje słowa set-tiers i nakłada je w tej samej kopii roboczej configu.
    ARGV=("$ZB" edit-relation "$NAME" "--profile=$PROFILE" "--source-profile=$SRCPROF" ${SARGS[@]+"${SARGS[@]}"})
    info "$T_CHG" "$(T 'Liczę plan (generacja, próba pobrania, prawa na źródle)...')"
    if ! "${ARGV[@]}" --plan >"$TMPD/plan.txt" 2>&1; then
        verb_refusal "$TMPD/plan.txt" | fold -s -w $((W - 6)) >"$TMPD/why.txt"
        [ -s "$TMPD/why.txt" ] || tail -5 "$TMPD/plan.txt" >"$TMPD/why.txt"
        wt --title "$(T 'Czasownik odmówił -- nic nie zmieniono')" --msgbox "$(cat "$TMPD/why.txt")" "$(fit "$(grep -c '' "$TMPD/why.txt")")" "$W"
        # Kampania 2026-10-22: szablon z INNĄ rodziną migawek to nowa relacja -- żadna liczba
        # w oknie źródła tego nie zmieni, a Wstecz o jeden krok kręcił w kółko ostrzeżenie ->
        # tabela -> odmowa. Taka odmowa wraca do listy szablonów.
        if [ "$ACTION" = szablon ] && grep -q 'is a NEW relationship' "$TMPD/plan.txt"; then step=1; else step=$back; fi
        continue
    fi
    # Plan w skrócie: podsumowanie czasownika + linie crona TEJ relacji (-/+), każda jako
    # "minuta godzina ... | etykieta | retencja". Pełny diff jest w dzienniku.
    "$PY" - "$TMPD/plan.txt" "$NAME" <<'PYEOF' >"$TMPD/plan2.txt"
import sys, re, json
import os as _os
_C = json.load(open(_os.environ["ZFS_TUI_CAT"], encoding="utf-8")) if _os.environ.get("ZFS_TUI_CAT") else {}
def _(s): return _C.get(s, s)
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
name = sys.argv[2]
print(_(u"PLAN -- nic jeszcze nie zostało zmienione:") + u"\n")
show = False
for l in lines:
    if l.startswith(("Relation edit:", "WARNING:", "UWAGA:")):   # UWAGA: hand-edits.py w polskim oknie
        show = True
    if show:
        if not l.strip():
            show = False
            continue
        print(l)
# Tylko NOWE zadania (+) i liczba zastępowanych (-): pełne -/+ nie mieściło się w
# oknie, a okno z przewijaniem trzyma fokus na tekście i Enter nie trafia w
# WYKONAJ (zmierzone jazdą po pty na pve10, 2026-10-07). Monitory bez zmian
# rytmu (*/15) nie są wypisywane.
crontab = False
gone = 0
new = []
for l in lines:
    if "what will change in the crontab" in l:
        crontab = True; continue
    if not crontab or not re.match(r"^\s+[-+]\S", l) or (" -L %s " % name) not in l:
        continue
    sign = l.strip()[0]
    body = l.strip()[1:]
    if "check-snap-age" in body:
        continue
    if sign == "-":
        gone += 1
        continue
    f = body.split()
    when = " ".join(f[:5])
    m = re.search(r'zfs-job\.sh "([^"]*)"', body)
    lbl = m.group(1).split(" ", 1)[-1] if m else "?"
    lbl = re.sub(r"^profile__.*?__", "", lbl)
    r = re.search(r'\s(-[HDWMY]\d+)\s*$', body)
    new.append("  %-14s %s%s" % (when, lbl, ("  " + r.group(1)) if r else ""))
if new or gone:
    print(u"\n" + (_(u"Zadania tej relacji po zmianie (zastępują %d dotychczasowych):") % gone))
    for x in new:
        print(x)
else:
    print(u"\n" + _(u"Zadania w cronie: bez zmian."))
PYEOF
    if [ "$ACTION" = szablon ] && [ -s "$TMPD/srcwarn.txt" ] && [ "${#SARGS[@]}" -eq 0 ]; then
        { echo; echo "$(T 'UWAGA -- źródło dostanie liczby szablonu (w oknie źródła nic nie zmieniono):')"; cat "$TMPD/srcwarn.txt"; } >>"$TMPD/plan2.txt"
    fi
    if [ -s "$TMPD/rargs.plan" ] && [ "$PROFILE" = "$HNAME" ]; then
        { echo; echo "$(T 'Zmiany w tabeli szczebli:')"; cat "$TMPD/rargs.plan"; } >>"$TMPD/plan2.txt"
    fi
    # X6 (właściciel 2026-10-12): RĘCZNA ZMIANA CONFIGU przepadała bez słowa -- sekcje
    # relacji powstają od nowa z jej szablonu. Plan z OBECNYMI ustawieniami relacji (nic
    # nie zmienione w oknie) powinien nie zmieniać crona; to, co zmienia, to ręczne zmiany
    # w configu, które WYKONAJ nadpisze. Mówimy to na górze planu, przed WYKONAJ.
    # (2.0: GUI czyta config i aktualizuje szablon relacji -- w obie strony.)
    : >"$TMPD/hand.txt"
    if "$ZB" edit-relation "$NAME" "--profile=$CUR_P" "--source-profile=${CUR_S#-}" --plan >"$TMPD/base.txt" 2>&1; then
        "$PY" "$HERE/tui/hand-edits.py" "$TMPD/base.txt" "$NAME" >"$TMPD/hand.txt" 2>/dev/null || : >"$TMPD/hand.txt"
    fi
    if [ -s "$TMPD/hand.txt" ]; then
        { head -1 "$TMPD/plan2.txt"; echo; cat "$TMPD/hand.txt"; tail -n +2 "$TMPD/plan2.txt"; } >"$TMPD/plan3.txt" && mv "$TMPD/plan3.txt" "$TMPD/plan2.txt"
    fi
    echo >>"$TMPD/plan2.txt"
    echo "Komenda:  $(for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done)--yes" >>"$TMPD/plan2.txt"
    # Plan przeszedł -- szablon czeka na liście zmian; "Zapisz zmiany" wykona wszystko razem.
    # Szablon i tabela szczebli to dwie drogi do tego samego (sekcje od nowa) -- obowiązuje ostatnia.
    P_EDIT=("${ARGV[@]:3}"); cp "$TMPD/plan2.txt" "$TMPD/p_edit.txt"; P_TIERS=(); P_RARGS=(); P_SARGS=()
    P_EDIT_WORDS="$PROFILE"; [ "$PROFILE" = "$HNAME" ] && P_EDIT_WORDS="$(T 'własne ustawienia (tabela)')"
    continue 2
done
done
