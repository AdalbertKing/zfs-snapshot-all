#!/bin/bash
# new-relation.sh -- kreator nowej relacji jako ciąg okien whiptail.
#
# Decyzja właściciela 2026-09-16: formularze w whiptail ("stare Turbo Vision"),
# nie rysowane ręcznie w curses. Kreator NIE robi nic sam: zbiera odpowiedzi i
# składa JEDNĄ komendę `zfs-backup.sh --source=...`, tę samą, którą operator
# wpisałby z palca. Jedyny wyjątek: `prepare-source`, o który pyta wprost.
#
# Zasady okien:
#   - rozmiar z terminala (tput), nigdy na sztywno: okno większe od ekranu
#     whiptail ucina bez słowa (zmierzone: putty 80x25); każdy tekst mieści
#     się w 80 kolumnach;
#   - NEWT_COLORS z widocznym bieżącym wierszem;
#   - na liście tylko wybory, które mają sens; jeden domyślnie zaznaczony;
#   - Esc i przycisk "Wstecz" = krok wstecz; w kroku 1 = wyjście.
#
# Stan: kroki 1-4 (typ, host, diagnoza, datasety). Kroki 5-10 po pokazie.
#
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
WT="${WHIPTAIL:-whiptail}"
# Interpreter wybierany przez URUCHOMIENIE, nie przez `command -v`: nazwa, ktora
# sie rozwiazuje, nie musi dzialac (alias sklepowy na Windows).
PY=""
for c in ${PYTHON:+"$PYTHON"} python3 python; do "$c" -c 'import sys' >/dev/null 2>&1 && { PY="$c"; break; }; done
NSTEP=10

command -v "$WT" >/dev/null 2>&1 || { echo "new-relation: brak '$WT' (pakiet whiptail)" >&2; exit 1; }
[ -n "$PY" ] || { echo "new-relation: brak dzialajacego python3" >&2; exit 1; }

# Polskie znaki: newt liczy szerokości wg locale. Bez UTF-8 ramki się rozjeżdżają.
case "$(locale charmap 2>/dev/null)" in UTF-8) ;; *) export LC_ALL=C.UTF-8 ;; esac
export PYTHONIOENCODING=utf-8
export NEWT_COLORS="${NEWT_COLORS:-root=,blue window=black,white border=black,white title=black,white listbox=black,white actlistbox=white,black sellistbox=black,white actsellistbox=white,black checkbox=black,white actcheckbox=white,black button=black,cyan actbutton=white,red textbox=black,white entry=black,white label=black,white}"

TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

# --- odpowiedzi -------------------------------------------------------------
MODE="backup"; HOST=""; PORT="22"; HOSTNAME_R=""; RECURSION="flat"
DS=(); EXCL=(); DROPPED=(); CH_NAMES=()

# --- okna -------------------------------------------------------------------
geom() {   # H W LH z bieżącego terminala
    local l c
    l=$(tput lines 2>/dev/null) || l=24; c=$(tput cols 2>/dev/null) || c=80
    case "$l" in ''|*[!0-9]*) l=24 ;; esac; case "$c" in ''|*[!0-9]*) c=80 ;; esac
    H=$((l - 2)); W=$((c - 4)); [ "$W" -gt 100 ] && W=100; LH=$((H - 9))
    [ "$LH" -lt 3 ] && LH=3
    return 0
}
fit() {    # <wiersze tekstu+listy> -> wysokość okna, nie większa niż ekran
    local h=$(($1 + 7)); [ "$h" -gt "$H" ] && h=$H; echo "$h"
}
wt() {     # whiptail z odpowiedzią w WT_OUT; rc: 0 = OK, inne = wstecz
    WT_OUT=$("$WT" --backtitle "Nowa relacja -- kolektor $(hostname)" "$@" 3>&1 1>&2 2>&3)
}
info() {   # <tytuł> <tekst> -- okno bez przycisków na czas czekania
    "$WT" --backtitle "Nowa relacja -- kolektor $(hostname)" --title "$1" --infobox "$2" 7 "$W"
}
title() { printf 'Krok %s/%s: %s' "$1" "$NSTEP" "$2"; }
hostport() { [ "$PORT" = 22 ] && echo "$HOST" || echo "$HOST:$PORT"; }

# --- krok 1: typ ------------------------------------------------------------
step_mode() {
    geom
    local b=OFF s=OFF; [ "$MODE" = sync ] && s=ON || b=ON
    wt --title "$(title 1 'Jaka relacja?')" --cancel-button "Wyjdź" --notags \
       --radiolist "Backup: ten host POBIERA migawki ze źródła i trzyma je u siebie.\nSynchro: oba hosty trzymają te same datasety pod tą samą ścieżką.\n\nStrzałki = ruch, spacja = wybierz, Enter = dalej." "$(fit 7)" "$W" 2 \
       backup "Backup   (ten host pobiera ze źródła)" "$b" \
       sync   "Synchro  (to samo po obu stronach)" "$s" || return 1
    [ -n "$WT_OUT" ] && MODE="$WT_OUT"
    return 0
}

# --- krok 2: host -----------------------------------------------------------
existing_relation() {   # <host> -> nazwy relacji (nie-removed) z tym hostem
    "$ZB" status --json 2>/dev/null | "$PY" -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
h = sys.argv[1]
print(", ".join(r.get("name", "") for r in d.get("relations", [])
      if r.get("peer_host") == h and r.get("state") != "removed"))' "$1"
}
step_host() {
    local init rel h p
    init="$(hostport)"
    while :; do
        geom
        wt --title "$(title 2 'Z którego hosta?')" --cancel-button "Wstecz" \
           --inputbox "Adres hosta źródłowego: IP albo nazwa, opcjonalnie :port.\n\nPakiet nie musi tam jeszcze być -- następny krok to sprawdzi\ni zaproponuje instalację. Potrzebny jest tylko wstęp SSH jako root." \
           13 "$W" "$init" || return 1
        init="$WT_OUT"      # po odmowie pole wraca z tym, co wpisano -- do poprawienia, nie od zera
        h="${WT_OUT// /}"; p=22
        case "$h" in *:*) p="${h##*:}"; h="${h%%:*}" ;; esac
        case "$h" in ''|*[!A-Za-z0-9._-]*)
            wt --title "Zły adres" --msgbox "'$WT_OUT' nie wygląda na adres hosta.\nDozwolone: litery, cyfry, kropka, myślnik; opcjonalnie :port." 9 "$W"; continue ;; esac
        case "$p" in ''|*[!0-9]*)
            wt --title "Zły port" --msgbox "Port '$p' nie jest liczbą." 8 "$W"; continue ;; esac
        info "$(title 2 'Z którego hosta?')" "Sprawdzam, czy z $h nie ma już relacji..."
        rel="$(existing_relation "$h")"
        if [ -n "$rel" ]; then
            wt --title "Ta relacja już istnieje" --msgbox "Z hostem $h jest już relacja: $rel.\n\nRelacja to PARA HOSTÓW -- jedna na parę, z wieloma datasetami.\nDodanie datasetów do istniejącej relacji to jej modyfikacja,\na tego kreator jeszcze nie umie.\n\nPodaj host, z którym relacji nie ma." 14 "$W"
            continue
        fi
        [ "$h" = "$HOST" ] || { DS=(); EXCL=(); }
        HOST="$h"; PORT="$p"
        return 0
    done
}

# --- krok 3: diagnoza -------------------------------------------------------
probe() {   # check-source -> zmienne C_*
    C_SSH=0; C_ERR=""; C_NAME=""; C_ZFS=0; C_POOLS=""; C_PKG=0; C_REV=""; C_DIR=""
    "$ZB" check-source "$(hostport)" --json >"$TMPD/check.json" 2>"$TMPD/check.err" || true
    # Wartości ze zdalnego hosta to DANE: python wypisuje je w stałej kolejności,
    # po jednej w linii (bez znaków nowej linii), bash czyta je read -r, nigdy wykonywane.
    "$PY" - "$TMPD/check.json" <<'PYEOF' | tr -d '\r' >"$TMPD/check.vals"
import sys, json
def one(x): return str(x or "").replace("\r", " ").replace("\n", " ")
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {"ssh": {"ok": False, "error": "check-source nie zwrócił JSON-a"}}
ssh = d.get("ssh") or {}; z = d.get("zfs") or {}; p = d.get("package") or {}
for v in (1 if ssh.get("ok") else 0, one(ssh.get("error")), one(d.get("hostname")),
          1 if z.get("ok") else 0,
          one(", ".join("%s (%s, wolne %s)" % (x.get("name"), x.get("size"), x.get("free")) for x in z.get("pools") or [])),
          1 if p.get("ok") else 0, one(p.get("rev")), one(p.get("path") or d.get("repo_dir"))):
    print(v)
PYEOF
    { IFS= read -r C_SSH; IFS= read -r C_ERR; IFS= read -r C_NAME; IFS= read -r C_ZFS
      IFS= read -r C_POOLS; IFS= read -r C_PKG; IFS= read -r C_REV; IFS= read -r C_DIR; } <"$TMPD/check.vals"
    case "$C_SSH" in 0|1) ;; *) C_SSH=0 ;; esac
    case "$C_ZFS" in 0|1) ;; *) C_ZFS=0 ;; esac
    case "$C_PKG" in 0|1) ;; *) C_PKG=0 ;; esac
    [ "$C_SSH" -eq 1 ] || [ -n "$C_ERR" ] || C_ERR="$(tail -1 "$TMPD/check.err" 2>/dev/null)"
}
step_diag() {   # 0 = dalej, 1 = wróć do hosta
    local facts
    while :; do
        geom
        info "$(title 3 'Co jest na źródle?')" "Sprawdzam $(hostport) przez SSH jako root..."
        probe
        if [ "$C_SSH" -ne 1 ]; then
            wt --title "$(title 3 "$HOST nie wpuszcza")" --msgbox "SSH jako root@$HOST nie działa:\n\n  $C_ERR\n\nNajczęściej brakuje jednego z dwóch -- z TEGO hosta, jako root:\n\n  ssh-keyscan -p $PORT $HOST >> /root/.ssh/known_hosts\n  ssh-copy-id -p $PORT root@$HOST\n\nPo naprawie wróć tutaj." "$(fit 13)" "$W"
            return 1
        fi
        HOSTNAME_R="$C_NAME"
        facts="  [+] SSH     root@$HOST odpowiada, to '$C_NAME'\n"
        if [ "$C_ZFS" -ne 1 ]; then
            wt --title "$(title 3 'Brak ZFS')" --msgbox "${facts}  [-] ZFS     na $HOST nie ma polecenia zfs\n\nBez ZFS nie ma czego kopiować." 12 "$W"
            return 1
        fi
        facts="${facts}  [+] ZFS     pule: ${C_POOLS:-brak}\n"
        if [ "$C_PKG" -eq 1 ]; then
            wt --title "$(title 3 'Źródło gotowe')" --ok-button "Dalej" --msgbox "${facts}  [+] Pakiet  $C_DIR (rewizja ${C_REV:-?})\n\nWszystko jest. Dalej: lista datasetów." 13 "$W"
            return 0
        fi
        wt --title "$(title 3 'Brak pakietu na źródle')" --yes-button "Zainstaluj" --no-button "Wstecz" \
           --yesno "${facts}  [-] Pakiet  nie ma go w $C_DIR\n\nBez pakietu źródło nie dołączy do relacji.\n\n'Zainstaluj' = prepare-source: git clone pakietu jako root.\nNie rusza crona, nie zakłada relacji ani kluczy." 16 "$W" || return 1
        info "Instaluję pakiet na $HOST" "prepare-source $(hostport) ... (do minuty)"
        if "$ZB" prepare-source "$(hostport)" --yes >"$TMPD/prep.log" 2>&1; then
            continue    # sprawdź jeszcze raz i pokaż wynik
        fi
        wt --title "Instalacja się nie udała" --scrolltext --textbox "$TMPD/prep.log" "$H" "$W"
        return 1
    done
}

# --- krok 4: datasety -------------------------------------------------------
load_tree() {   # -> $TMPD/tree.tsv: name <TAB> etykieta ; rc!=0 = błąd w $TMPD/ds.err
    "$ZB" list-datasets "$(hostport)" --json >"$TMPD/ds.json" 2>"$TMPD/ds.err" || return 1
    "$PY" - "$TMPD/ds.json" <<'PYEOF' | tr -d '\r' >"$TMPD/tree.tsv"
import sys, json
ds = json.load(open(sys.argv[1], encoding="utf-8")).get("datasets") or []
names = [d.get("name", "") for d in ds]
def human(n):
    n = float(n or 0)
    for u in ("B", "K", "M", "G", "T", "P"):
        if n < 1024 or u == "P":
            return ("%d%s" % (n, u)) if u == "B" or n >= 100 else ("%.1f%s" % (n, u))
        n /= 1024.0
def kids_words(k):
    if k == 1: return "+1 podrzędny"
    if k % 10 in (2, 3, 4) and k % 100 not in (12, 13, 14): return "+%d podrzędne" % k
    return "+%d podrzędnych" % k
rows = []
for d in ds:
    n = d.get("name", ""); depth = n.count("/")
    label = ("  " * depth) + (n if depth == 0 else n.rsplit("/", 1)[1])
    kids = sum(1 for x in names if x.startswith(n + "/"))
    rows.append((n, label, human(d.get("used")), "zvol" if d.get("type") == "volume" else "", kids))
wl = max([len(r[1]) for r in rows] + [10])
for n, label, used, typ, kids in rows:
    print("%s\t%s  %7s  %-4s  %s" % (n, label.ljust(wl), used, typ, kids_words(kids) if kids else ""))
PYEOF
}
in_list() { local x="$1" y; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

pick_datasets() {
    local items=() n label st
    while IFS=$'\t' read -r n label; do
        st=OFF; in_list "$n" ${DS[@]+"${DS[@]}"} && st=ON
        items+=("$n" "$label" "$st")
    done <"$TMPD/tree.tsv"
    while :; do
        geom
        wt --title "$(title 4 "Które datasety z $HOST?")" --cancel-button "Wstecz" --notags --separate-output \
           --checklist "Strzałki = ruch, spacja = zaznacz, Enter = dalej.\nZaznaczony dataset idzie RAZEM z podrzędnymi (które pominąć -- za chwilę)." "$H" "$W" "$LH" \
           "${items[@]}" || return 1
        [ -n "$WT_OUT" ] && break
        wt --title "Nic nie zaznaczone" --msgbox "Zaznacz spacją co najmniej jeden dataset." 8 "$W"
    done
    # Zaznaczony potomek zaznaczonego przodka i tak jedzie z przodkiem.
    local all=() a b covered; DS=(); DROPPED=()
    while IFS= read -r n; do [ -n "$n" ] && all+=("$n"); done <<<"$WT_OUT"
    for a in "${all[@]}"; do
        covered=0
        for b in "${all[@]}"; do case "$a" in "$b"/*) covered=1 ;; esac; done
        if [ "$covered" -eq 1 ]; then DROPPED+=("$a"); else DS+=("$a"); fi
    done
    return 0
}
children_of_selected() {   # -> CH_NAMES[]
    local n label p; CH_NAMES=()
    while IFS=$'\t' read -r n label; do
        for p in "${DS[@]}"; do
            case "$n" in "$p"/*) CH_NAMES+=("$n") ;; esac
        done
    done <"$TMPD/tree.tsv"
}
lines_of() { local x; for x in "$@"; do printf '  %s\\n' "$x"; done; }
pick_recursion() {
    geom
    local f=OFF a=OFF note=""; [ "$RECURSION" = atomic ] && a=ON || f=ON
    [ "${#DROPPED[@]}" -gt 0 ] && note="\nOdznaczone jako zbędne (jadą z nadrzędnym):\n$(lines_of "${DROPPED[@]}")"
    wt --title "$(title 4 'Jak kopiować podrzędne?')" --cancel-button "Wstecz" --notags \
       --radiolist "Wybrane:\n$(lines_of "${DS[@]}")Podrzędnych pod nimi: ${#CH_NAMES[@]}.\n$note\nOsobno (-R): każdy podrzędny ma własne migawki; wybrane można pominąć.\nAtomowo (-r): jedna migawka na całe drzewo; pominąć się nie da." \
       "$(fit $((${#DS[@]} + ${#DROPPED[@]} + 9)))" "$W" 2 \
       flat   "Każdy podrzędny osobno (-R)  -- zalecane" "$f" \
       atomic "Całe drzewo atomowo (-r)" "$a" || return 1
    [ -n "$WT_OUT" ] && RECURSION="$WT_OUT"
    return 0
}
pick_excluded() {
    geom
    local items=() n st
    for n in "${CH_NAMES[@]}"; do
        st=OFF; in_list "$n" ${EXCL[@]+"${EXCL[@]}"} && st=ON
        items+=("$n" "$n" "$st")
    done
    wt --title "$(title 4 'Które podrzędne POMINĄĆ?')" --cancel-button "Wstecz" --notags --separate-output \
       --checklist "Zaznaczone NIE będą kopiowane. Nic nie zaznaczone = kopiuj wszystkie.\nSpacja = zaznacz, Enter = dalej." "$H" "$W" "$LH" \
       "${items[@]}" || return 1
    EXCL=()
    while IFS= read -r n; do [ -n "$n" ] && EXCL+=("$n"); done <<<"$WT_OUT"
    return 0
}
step_datasets() {
    geom
    info "$(title 4 'Datasety')" "Pobieram listę datasetów z $HOST..."
    if ! load_tree; then
        wt --title "Nie udało się pobrać listy" --msgbox "list-datasets $HOST:\n\n$(tail -3 "$TMPD/ds.err")" 12 "$W"
        return 1
    fi
    local sub=pick
    while :; do
        case "$sub" in
            pick) pick_datasets || return 1
                  children_of_selected
                  if [ "${#CH_NAMES[@]}" -eq 0 ]; then RECURSION=flat; EXCL=(); return 0; fi
                  sub=rec ;;
            rec)  if pick_recursion; then
                      if [ "$RECURSION" = atomic ]; then EXCL=(); return 0; fi
                      sub=excl
                  else sub=pick; fi ;;
            excl) if pick_excluded; then return 0; else sub=rec; fi ;;
        esac
    done
}

# --- komenda ----------------------------------------------------------------
build_argv() {   # -> ARGV[] ; na razie z kroków 1-4
    local IFS=, x
    ARGV=("$ZB" "--source=$(hostport):${DS[*]}")
    [ "$MODE" = sync ] && ARGV+=("--mode=sync")
    [ "$RECURSION" = atomic ] && ARGV+=("--recursive=atomic")
    for x in ${EXCL[@]+"${EXCL[@]}"}; do ARGV+=("--exclude-child=$x"); done
    return 0
}
step_preview() {   # tymczasowy koniec: co zebrane, bez wykonania
    geom
    build_argv
    {
        echo "Zebrane w krokach 1-4 (nic nie zostało wykonane):"
        echo
        echo "  Typ relacji : $([ "$MODE" = sync ] && echo synchro || echo backup)"
        echo "  Źródło      : $HOST${HOSTNAME_R:+ ($HOSTNAME_R)}, port $PORT"
        echo "  Datasety    :"; printf '                  %s\n' "${DS[@]}"
        echo "  Podrzędne   : $([ "$RECURSION" = atomic ] && echo 'całe drzewo atomowo (-r)' || echo 'każdy osobno (-R)')"
        echo "  Pominięte   :"; printf '                  %s\n' ${EXCL[@]+"${EXCL[@]}"}
        [ "${#EXCL[@]}" -eq 0 ] && echo "                  (żadne)"
        echo
        echo "Komenda dotąd:"
        echo
        printf '  %s \\\n' "${ARGV[0]}"; printf '      %s\n' "${ARGV[@]:1}"
        echo
        echo "Kroki 5-10 (dokąd, szablon, nazwa, konto, maski migawek, wykonanie)"
        echo "-- w budowie."
    } >"$TMPD/preview.txt"
    wt --title "Kroki 1-4 zebrane" --ok-button "Koniec" --scrolltext --textbox "$TMPD/preview.txt" "$H" "$W" || return 1
    return 0
}

# --- pętla kroków: 0 = dalej, 1 = wstecz ------------------------------------
step=mode
while :; do
    case "$step" in
        mode)    if step_mode;     then step=host;    else clear 2>/dev/null; echo "new-relation: przerwane, nic nie zmieniono"; exit 1; fi ;;
        host)    if step_host;     then step=diag;    else step=mode; fi ;;
        diag)    if step_diag;     then step=ds;      else step=host; fi ;;
        ds)      if step_datasets; then step=preview; else step=host; fi ;;
        preview) if step_preview;  then break;        else step=ds;   fi ;;
    esac
done
clear 2>/dev/null
build_argv
printf 'new-relation (kroki 1-4), komenda dotąd:\n%s\n' "${ARGV[*]}"
