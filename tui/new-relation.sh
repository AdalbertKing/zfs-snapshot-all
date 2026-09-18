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
        [ "$h" = "$HOST" ] || { B_ROOT=(); B_EXCL=(); }
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

# --- krok 4: datasety -- KOSZYK ---------------------------------------------
# Właściciel 2026-09-18, dwa razy tego samego dnia. O liście kratek na całym drzewie:
# "mylący" (puste kratki przy dzieciach, które i tak jadą z rodzicem). O pytaniu
# "co kopiować?" tylko dla datasetów z dziećmi: "też źle -- czysty Proxmox, wskazuję
# rpool/data, żeby kopiował maszyny, których tam jeszcze nie ma".
#
# Model, zmierzony na pve10<-pve11 (2026-09-18): pozycja koszyka to MIEJSCE -- kopiowane
# jest ono i wszystko, co pod nim JEST i co POWSTANIE, w -R i w -r tak samo. Nie ma
# "liści" i "gałęzi": to opis stanu z dzisiaj. "Sam rodzic bez dzieci" nie jest
# kształtem relacji. Dlatego dodanie miejsca nie zadaje pytań; wyjątki (tylko dla tego,
# co już istnieje) są osobną akcją koszyka; -R/-r to "jak", nie "co" -- poza krokiem 4.
T_NAME=(); T_KIDS=(); T_LABEL=()      # drzewo źródła
B_ROOT=(); B_EXCL=()                   # koszyk: korzeń, pominięte (po jednym w linii)

load_tree() {   # -> T_*[] ; rc!=0 = błąd w $TMPD/ds.err
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
    return "%d pod nim" % k
rows = []
for d in ds:
    n = d.get("name", ""); depth = n.count("/")
    label = ("  " * depth) + (n if depth == 0 else n.rsplit("/", 1)[1])
    kids = sum(1 for x in names if x.startswith(n + "/"))
    rows.append((n, kids, label, human(d.get("used")), "zvol" if d.get("type") == "volume" else ""))
wl = max([len(r[2]) for r in rows] + [10])
for n, kids, label, used, typ in rows:
    print("%s\t%d\t%s  %7s  %-4s  %s" % (n, kids, label.ljust(wl), used, typ, kids_words(kids) if kids else ""))
PYEOF
    T_NAME=(); T_KIDS=(); T_LABEL=()
    local n k l
    while IFS=$'\t' read -r n k l; do
        [ -n "$n" ] || continue
        T_NAME+=("$n"); T_KIDS+=("$k"); T_LABEL+=("$l")
    done <"$TMPD/tree.tsv"
    [ "${#T_NAME[@]}" -gt 0 ] || { echo "źródło nie ma żadnego datasetu" >"$TMPD/ds.err"; return 1; }
}
kids_count() { local i; for i in "${!T_NAME[@]}"; do [ "${T_NAME[$i]}" = "$1" ] && { echo "${T_KIDS[$i]}"; return; }; done; echo 0; }
covered() {     # <nazwa> -> 0, gdy koszyk już ją obejmuje (jest korzeniem albo leży pod korzeniem)
    local r; for r in ${B_ROOT[@]+"${B_ROOT[@]}"}; do case "$1" in "$r"|"$r"/*) return 0 ;; esac; done; return 1
}
basket_del() {  # <indeks>
    local i nr=() ne=()
    for i in "${!B_ROOT[@]}"; do [ "$i" = "$1" ] && continue; nr+=("${B_ROOT[$i]}"); ne+=("${B_EXCL[$i]}"); done
    B_ROOT=(${nr[@]+"${nr[@]}"}); B_EXCL=(${ne[@]+"${ne[@]}"})
}
resolve_under() {   # <korzeń> -> 0 = wolno dodać; pozycje POD nim wypadają po zgodzie
    local i under=() txt=""
    for i in "${!B_ROOT[@]}"; do case "${B_ROOT[$i]}" in "$1"/*) under+=("$i"); txt="$txt  ${B_ROOT[$i]}\n" ;; esac; done
    [ "${#under[@]}" -eq 0 ] && return 0
    geom
    wt --title "$1 obejmuje to, co już wybrane" --yes-button "Zastąp" --no-button "Zostaw" \
       --yesno "W koszyku są już pozycje leżące pod $1:\n\n$txt\nCała gałąź $1 je zawiera. Zastąpić je jedną pozycją $1?" "$(fit $((${#under[@]} + 6)))" "$W" || return 1
    for ((i=${#under[@]}-1; i>=0; i--)); do basket_del "${under[$i]}"; done
    return 0
}
describe() {    # <indeks> -> jedno zdanie o pozycji koszyka
    local r="${B_ROOT[$1]}" e="${B_EXCL[$1]}" k short x
    k="$(kids_count "$r")"; short=""
    while IFS= read -r x; do [ -n "$x" ] && short="$short${short:+, }${x#"$r"/}"; done <<<"$e"
    if [ "$k" -eq 0 ]; then echo "dziś nic pod nim; nowe skopiują się same"
    elif [ -z "$short" ]; then echo "dziś $k pod nim; nowe skopiują się same"
    else echo "dziś $k pod nim; BEZ: $short"; fi
}

pick_one() {    # -> PICK ; 1 = wstecz
    local items=() i
    for i in "${!T_NAME[@]}"; do
        covered "${T_NAME[$i]}" && continue
        items+=("${T_NAME[$i]}" "${T_LABEL[$i]}")
    done
    geom
    if [ "${#items[@]}" -eq 0 ]; then
        wt --title "Nie ma czego dodać" --msgbox "Koszyk obejmuje już wszystkie datasety z $HOST." 8 "$W"; return 1
    fi
    wt --title "$(title 4 "Które miejsce z $HOST kopiować?")" --ok-button "Wybierz" --cancel-button "Wstecz" --notags \
       --menu "Wybierz MIEJSCE. Kopiowane będzie ono i wszystko, co pod nim jest\nalbo POWSTANIE (np. rpool/data na czystym Proxmoxie)." "$H" "$W" "$LH" \
       "${items[@]}" || return 1
    PICK="$WT_OUT"; [ -n "$PICK" ]
}
add_flow() {    # <nazwa> -> 0 = dodano. Żadnych pytań: każde miejsce znaczy to samo.
    resolve_under "$1" || return 1
    B_ROOT+=("$1"); B_EXCL+=(""); return 0
}
with_kids() {   # -> WK[] indeksy pozycji koszyka, pod którymi dziś coś leży
    local i; WK=()
    for i in "${!B_ROOT[@]}"; do [ "$(kids_count "${B_ROOT[$i]}")" -gt 0 ] && WK+=("$i"); done
    return 0
}
except_flow() { # wyjątki dla jednej pozycji; stan obecny wraca jako odznaczone
    local idx items=() i n x st name ex=() all=()
    with_kids
    if [ "${#WK[@]}" -eq 1 ]; then idx="${WK[0]}"
    else
        for i in "${WK[@]}"; do items+=("$i" "${B_ROOT[$i]}  -- $(describe "$i")"); done
        geom
        wt --title "$(title 4 'Wyjątki -- dla którego miejsca?')" --ok-button "Wybierz" --cancel-button "Wstecz" --notags \
           --menu "Wyjątki można wskazać tylko tam, gdzie pod miejscem coś już leży." "$(fit $((${#WK[@]} + 3)))" "$W" "${#WK[@]}" \
           "${items[@]}" || return 0
        idx="$WT_OUT"
    fi
    name="${B_ROOT[$idx]}"; items=()
    for i in "${!T_NAME[@]}"; do
        n="${T_NAME[$i]}"
        case "$n" in "$name"/*) ;; *) continue ;; esac
        st=ON
        while IFS= read -r x; do [ -n "$x" ] && case "$n" in "$x"|"$x"/*) st=OFF ;; esac; done <<<"${B_EXCL[$idx]}"
        items+=("$n" "${T_LABEL[$i]}" "$st"); all+=("$n")
    done
    geom
    wt --title "$(title 4 "$name -- czego NIE kopiować?")" --cancel-button "Wstecz" --notags --separate-output \
       --checklist "Zaznaczone = kopiowane. ODZNACZ spacją to, co ma być pomijane\n(razem z tym, co pod nim). Przyszłych datasetów pominąć się nie da." "$H" "$W" "$LH" \
       "${items[@]}" || return 0
    for n in "${all[@]}"; do
        printf '%s\n' "$WT_OUT" | grep -qxF -- "$n" && continue
        st=0; for i in ${ex[@]+"${ex[@]}"}; do case "$n" in "$i"/*) st=1 ;; esac; done
        [ "$st" -eq 1 ] || ex+=("$n")       # pominięty przodek już obejmuje potomka
    done
    B_EXCL[$idx]="$(printf '%s\n' ${ex[@]+"${ex[@]}"})"
    return 0
}
remove_flow() {
    local items=() i n
    for i in "${!B_ROOT[@]}"; do items+=("$i" "${B_ROOT[$i]}  -- $(describe "$i")" OFF); done
    geom
    wt --title "$(title 4 'Usuń z koszyka')" --ok-button "Usuń zaznaczone" --cancel-button "Wstecz" --notags --separate-output \
       --checklist "Zaznacz spacją pozycje do usunięcia." "$(fit $((${#B_ROOT[@]} + 3)))" "$W" "${#B_ROOT[@]}" \
       "${items[@]}" || return 0
    for n in $(printf '%s\n' "$WT_OUT" | sort -rn); do basket_del "$n"; done
}
basket_window() {   # -> ACT = add | exc | del | next ; 1 = wstecz
    local txt="" i shown=0 max menu=()
    geom
    max=$((H - 14)); [ "$max" -lt 3 ] && max=3
    for i in "${!B_ROOT[@]}"; do
        if [ "$shown" -ge "$max" ]; then txt="$txt  … i jeszcze $((${#B_ROOT[@]} - shown))\n"; break; fi
        txt="$txt  ${B_ROOT[$i]}\n      $(describe "$i")\n"; shown=$((shown + 1))
    done
    with_kids
    menu=(add "Dodaj miejsce…")
    [ "${#WK[@]}" -gt 0 ] && menu+=(exc "Wyjątki…   (czego pod miejscem NIE kopiować)")
    menu+=(del "Usuń pozycję…" next "Dalej")
    wt --title "$(title 4 "Co kopiować z $HOST?")" --ok-button "Wybierz" --cancel-button "Wstecz" --notags --default-item next \
       --menu "Kopiowane -- wszystko, co JEST i co POWSTANIE pod:\n\n$txt" "$(fit $((shown * 2 + 9)))" "$W" "$((${#menu[@]} / 2))" \
       "${menu[@]}" || return 1
    ACT="$WT_OUT"
}
step_datasets() {
    geom
    info "$(title 4 'Datasety')" "Pobieram listę datasetów z $HOST..."
    if ! load_tree; then
        wt --title "Nie udało się pobrać listy" --msgbox "list-datasets $HOST:\n\n$(tail -3 "$TMPD/ds.err")" 12 "$W"
        return 1
    fi
    while :; do
        if [ "${#B_ROOT[@]}" -eq 0 ]; then     # pusty koszyk: od razu lista, bez pustego okna
            pick_one || return 1
            add_flow "$PICK"
            continue
        fi
        basket_window || return 1
        case "$ACT" in
            add)  if pick_one; then add_flow "$PICK"; fi ;;
            exc)  except_flow ;;
            del)  remove_flow ;;
            next) return 0 ;;   # -R/-r to "jak", nie "co": domyślnie -R, atomowo w ustawieniach zaawansowanych
        esac
    done
}

# Wzorce dla -X BEZ metaznaków powłoki. Rekord -> pole `flags` w configu -> linia
# crona, wszędzie wklejane BEZ cudzysłowów: `(`, `|` rozbiłyby komendę co noc.
# `^nazwa$` i `^nazwa/` przechodzą przez sh bez zmian (zmierzone na pve10) i nie
# łapią `nazwa1`. Kropka w nazwie zostaje kropką wzorca: nadzbiór, w praktyce ten sam.
build_argv() {   # -> ARGV[] ; na razie z kroków 1-4
    local IFS=, i x D='$'
    ARGV=("$ZB" "--source=$(hostport):${B_ROOT[*]}")
    [ "$MODE" = sync ] && ARGV+=("--mode=sync")
    [ "$RECURSION" = atomic ] && ARGV+=("--recursive=atomic")
    for i in "${!B_ROOT[@]}"; do
        while IFS= read -r x; do
            [ -n "$x" ] || continue
            ARGV+=("--exclude-child=^$x${D}")
            [ "$(kids_count "$x")" -gt 0 ] && ARGV+=("--exclude-child=^$x/")
        done <<<"${B_EXCL[$i]}"
    done
    return 0
}
shq() {   # argument tak, jak wpisałby go człowiek: apostrofy tylko tam, gdzie trzeba
    case "$1" in *[!A-Za-z0-9_./:=,@%+-]*) printf "'%s'" "$1" ;; *) printf '%s' "$1" ;; esac
}
quoted_argv() { local a; for a in "${ARGV[@]:1}"; do printf '      %s\n' "$(shq "$a")"; done; }
step_preview() {   # tymczasowy koniec: co zebrane, bez wykonania
    geom
    build_argv
    local i
    {
        echo "Zebrane w krokach 1-4 (nic nie zostało wykonane):"
        echo
        echo "  Typ relacji : $([ "$MODE" = sync ] && echo synchro || echo backup)"
        echo "  Źródło      : $HOST${HOSTNAME_R:+ ($HOSTNAME_R)}, port $PORT"
        echo "  Kopiowane   : wszystko, co jest i co powstanie pod:"
        for i in "${!B_ROOT[@]}"; do printf '      %s\n          %s\n' "${B_ROOT[$i]}" "$(describe "$i")"; done
        echo "  Sposób      : $([ "$RECURSION" = atomic ] && echo 'atomowo (-r)' || echo 'każdy dataset osobno (-R)')"
        echo
        echo "Komenda dotąd:"
        echo
        printf '  %s \\\n' "${ARGV[0]}"; quoted_argv
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
printf 'new-relation (kroki 1-4), komenda dotąd:\n'; for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done; printf '\n'
