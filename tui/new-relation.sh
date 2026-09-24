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
# Stan: 10 kroków -- typ, host, diagnoza, co kopiować (koszyk miejsc), dokąd, szablon,
# nazwa, konto, ustawienia dodatkowe, podsumowanie -> plan -> wykonanie.
#
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "new-relation: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
WT_BACKTITLE="Nowa relacja -- kolektor $(hostname)"
NSTEP=10
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

# --- odpowiedzi -------------------------------------------------------------
MODE="backup"; HOST=""; PORT="22"; HOSTNAME_R=""; RECURSION="flat"

# --- okna -------------------------------------------------------------------
title() { printf 'Krok %s/%s: %s' "$1" "$NSTEP" "$2"; }
hostport() { [ "$PORT" = 22 ] && echo "$HOST" || echo "$HOST:$PORT"; }

# --- krok 1: typ ------------------------------------------------------------
step_mode() {
    geom
    local b=OFF s=OFF; [ "$MODE" = sync ] && s=ON || b=ON
    wt --title "$(title 1 'Jaka relacja?')" --ok-button "Dalej" --cancel-button "Wyjdź" --notags \
       --radiolist "Backup: ten host POBIERA migawki ze źródła i trzyma je u siebie.\nSynchro: oba hosty trzymają te same datasety pod tą samą ścieżką.\n\nStrzałki = ruch, spacja = wybierz, Enter = dalej." "$(fit 7)" "$W" 2 \
       backup "Backup   (ten host pobiera ze źródła)" "$b" \
       sync   "Synchro  (to samo po obu stronach)" "$s" || return 1
    [ -n "$WT_OUT" ] && MODE="$WT_OUT"
    return 0
}

# --- krok 2: host -----------------------------------------------------------
existing_relation() {   # <host> -> nazwy relacji (nie-removed) z tym hostem
    status_tsv
    awk -F'\t' -v h="$1" '$2==h{printf "%s%s", (n++ ? ", " : ""), $1}' "$TMPD/rel.tsv"
}
step_host() {
    local init rel h p
    init="$(hostport)"
    while :; do
        geom
        wt --title "$(title 2 'Z którego hosta?')" --ok-button "Dalej" --cancel-button "Wstecz" \
           --inputbox "Adres hosta źródłowego: IP albo nazwa, opcjonalnie :port.\n\nPakiet nie musi tam jeszcze być -- następny krok to sprawdzi\ni zaproponuje instalację. Potrzebny jest tylko wstęp SSH jako root." \
           13 "$W" "$init" || return 1
        init="$WT_OUT"      # po odmowie pole wraca z tym, co wpisano -- do poprawienia, nie od zera
        h="${WT_OUT// /}"; p=22
        case "$h" in *:*) p="${h##*:}"; h="${h%%:*}" ;; esac
        case "$h" in ''|*[!A-Za-z0-9._-]*)
            wt --title "Zły adres" --msgbox "'$WT_OUT' nie wygląda na adres hosta.\nDozwolone: litery, cyfry, kropka, myślnik; opcjonalnie :port." 9 "$W"; continue ;; esac
        case "$p" in ''|*[!0-9]*)
            wt --title "Zły port" --msgbox "Port '$p' nie jest liczbą." 8 "$W"; continue ;; esac
        [ -e "$TMPD/rel.done" ] || info "$(title 2 'Z którego hosta?')" "Sprawdzam, czy z $h nie ma już relacji..."
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
    [ "$DIAG_OK_FOR" = "$(hostport)" ] && return 0      # już sprawdzony w tym przebiegu
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
            wt --title "$(title 3 'Źródło gotowe')" --yes-button "Dalej" --no-button "Wstecz" --yesno "${facts}  [+] Pakiet  $C_DIR (rewizja ${C_REV:-?})\n\nWszystko jest. Dalej: lista datasetów." 13 "$W" || return 1
            DIAG_OK_FOR="$(hostport)"
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

TREE_FOR=""; DIAG_OK_FOR=""
load_tree() {   # -> T_*[] ; rc!=0 = błąd w $TMPD/ds.err
    [ "$TREE_FOR" = "$(hostport)" ] && [ "${#T_NAME[@]}" -gt 0 ] && return 0
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
    TREE_FOR="$(hostport)"
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
    wt --title "$(title 4 "Które miejsce z $HOST kopiować?")" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
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
        wt --title "$(title 4 'Wyjątki -- dla którego miejsca?')" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
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
    wt --title "$(title 4 " --ok-button "Dalej"$name -- czego NIE kopiować?")" --cancel-button "Wstecz" --notags --separate-output \
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
is_excluded() { # <indeks> <nazwa> -> 0, gdy nazwa jest pomijana (sama albo przez przodka)
    local x
    while IFS= read -r x; do [ -n "$x" ] && case "$2" in "$x"|"$x"/*) return 0 ;; esac; done <<<"${B_EXCL[$1]}"
    return 1
}
entry_lines() { # <indeks> <ile nazw kopiowanych pokazać> -> 2-3 wiersze o pozycji koszyka
    # Zwarty zapis: na terminalu 24-wierszowym lista "po jednym w wierszu" chowała pomijane
    # pod "... i jeszcze 2". POMIJANE są więc ZAWSZE wypisane w całości; skraca się tylko
    # listę kopiowanych.
    local r="${B_ROOT[$1]}" cap="$2" i n kept="" nk=0 more=0 excl=""
    for i in "${!T_NAME[@]}"; do
        n="${T_NAME[$i]}"; case "$n" in "$r"/*) ;; *) continue ;; esac
        if is_excluded "$1" "$n"; then
            # potomek pominiętego przodka nie wymaga własnej wzmianki
            [ "${n%/*}" != "$r" ] && is_excluded "$1" "${n%/*}" && continue
            excl="$excl${excl:+, }${n#"$r"/}"
        elif [ "$nk" -lt "$cap" ]; then kept="$kept${kept:+, }${n#"$r"/}"; nk=$((nk + 1))
        else more=$((more + 1)); fi
    done
    printf '  %s   (+ wszystko, co pod nim POWSTANIE)\n' "$r"
    if [ -z "$kept" ] && [ -z "$excl" ]; then printf '      dziś nic pod nim\n'
    else
        [ -n "$kept" ] && printf '      dziś pod nim: %s%s\n' "$kept" "$( [ "$more" -gt 0 ] && echo " … i $more innych")"
        [ -z "$kept" ] && printf '      dziś pod nim: nic, co byłoby kopiowane\n'
    fi
    [ -n "$excl" ] && printf '      POMIJANE: %s\n' "$excl"
    return 0
}
mode_words() { [ "$RECURSION" = atomic ] && echo "cała gałąź atomowo (-r)" || echo "każdy dataset osobno (-R)"; }
any_excl() { local i; for i in "${!B_ROOT[@]}"; do [ -n "${B_EXCL[$i]}" ] && return 0; done; return 1; }
mode_flow() {   # -R/-r: JEDNO na relację; atomowo wyklucza wyjątki, więc pyta, zanim je zdejmie
    geom
    local f=OFF a=OFF i; [ "$RECURSION" = atomic ] && a=ON || f=ON
    wt --title "$(title 4 'Sposób kopiowania')" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
       --radiolist "To ustawienie jest JEDNO na całą relację.\n\nOsobno: każdy dataset ma własne migawki; awaria jednego nie zatrzymuje\nreszty. Atomowo: jedna migawka całej gałęzi w tej samej chwili, ale\nnie da się wtedy nic pominąć ani sprzątać migawek u źródła." "$(fit 10)" "$W" 2 \
       flat   "Każdy dataset osobno (-R)  -- zalecane" "$f" \
       atomic "Cała gałąź atomowo (-r)" "$a" || return 0
    [ -n "$WT_OUT" ] || return 0
    if [ "$WT_OUT" = atomic ] && any_excl; then
        wt --title "Atomowo nie pozwala pomijać" --yes-button "Zdejmij wyjątki" --no-button "Wstecz" \
           --yesno "W koszyku są wyjątki, a przy kopiowaniu atomowym nie da się nic pominąć.\n\nZdjąć wszystkie wyjątki i przejść na atomowo?" 11 "$W" || return 0
        for i in "${!B_ROOT[@]}"; do B_EXCL[$i]=""; done
    fi
    RECURSION="$WT_OUT"
}
basket_window() {   # -> ACT = add | exc | mode | del | next ; 1 = wstecz
    local txt="" i lines=0 avail cap menu=() block n
    geom
    avail=$((H - 13)); [ "$avail" -lt 4 ] && avail=4
    cap=6; [ "${#B_ROOT[@]}" -gt 2 ] && cap=3
    for i in "${!B_ROOT[@]}"; do
        block="$(entry_lines "$i" "$cap")"; n=$(printf '%s\n' "$block" | fold -s -w $((W - 4)) | grep -c '')
        if [ $((lines + n)) -gt "$avail" ] && [ "$lines" -gt 0 ]; then
            txt="$txt  … i jeszcze miejsc: $((${#B_ROOT[@]} - i))\n"; lines=$((lines + 1)); break
        fi
        txt="$txt${block//$'\n'/\\n}\n"; lines=$((lines + n))
    done
    with_kids
    menu=(add "Dodaj miejsce…")
    [ "${#WK[@]}" -gt 0 ] && menu+=(exc "Wyjątki…   (czego pod miejscem NIE kopiować)")
    menu+=(mode "Sposób: $(mode_words) -- zmień…" del "Usuń pozycję…" next "Dalej")
    wt --title "$(title 4 "Co kopiować z $HOST?")" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item next \
       --menu "Kopiowane będzie:\n\n$txt" "$(fit $((lines + 8)))" "$W" "$((${#menu[@]} / 2))" \
       "${menu[@]}" || return 1
    ACT="$WT_OUT"
}
step_datasets() {
    geom
    [ "$TREE_FOR" = "$(hostport)" ] || info "$(title 4 'Datasety')" "Pobieram listę datasetów z $HOST..."
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
            exc)  if [ "$RECURSION" = atomic ]; then
                      geom
                      wt --title "Przy atomowo nie da się pomijać" --msgbox "Sposób kopiowania to teraz: $(mode_words).\nJedna migawka całej gałęzi nie ma gdzie niczego odfiltrować.\n\nŻeby wskazać wyjątki, zmień najpierw Sposób na 'każdy dataset osobno'." 12 "$W"
                  else except_flow; fi ;;
            mode) mode_flow ;;
            del)  remove_flow ;;
            next) return 0 ;;
        esac
    done
}

# --- krok 5: dokąd (tylko backup) ---------------------------------------------
# Lekcja ze starego kreatora: lista pokazywała cudze lądowiska i podgląd jeździł za
# kursorem. Tu kandydatów jest mało i każdy ma POWÓD; reszta to "inna ścieżka".
TARGET=""; PROFILE=""; RNAME=""; ACCT="root"; ACCT_OTHER=""; SRCKEEP=""
EXFAM="__replicate_,vzdump,__migration__"; GRANT=1; MANUAL=0; SRCPROF=""
# Zamrażanie ma DWIE połowy (zmierzone pve10 <- pve9b, 2026-09-20): szablon, który każe
# zamrażać, ORAZ zgoda źródła, żeby konto kolektora mogło zamrażać jego gości. Bez zgody
# każda "zamrażana" migawka wychodzi jako automated_<szczebel>_crash_<czas>.
GQUIESCE=1
# PAMIĘĆ NA CZAS JEDNEGO PRZEBIEGU. Czytelniki odpowiadają po 5-12 s; bez tego każde
# "Wstecz" i ponowne "Dalej" kazało czekać od nowa (zmierzone jazdą: cofnięcie z kroku 7
# do 6 = 9 s na "Czytam szablony"). Stan hosta nie zmienia się w trakcie klikania.
status_tsv() {  # -> $TMPD/rel.tsv: nazwa <TAB> peer <TAB> target <TAB> stan <TAB> szablon <TAB> konto (relacje nie-removed)
    # Puste pole staje sie "-": IFS=$'\t' read TRAKTUJE TAB jak biala spacje w IFS
    # i ZLEPIA sasiadujace puste pola w jeden separator (zmierzone: uwaga wlasciciela
    # nr 11 -- relacja synchro z pustym client_target zesunela pole "stan" (active)
    # do zmiennej celu w kroku 5, ktory zaproponowal "active" jako dataset docelowy
    # -- zywe na pve11). Kazdy czytelnik nizej testuje pole na "" LUB "-".
    [ -e "$TMPD/rel.done" ] && return 0
    : >"$TMPD/rel.done"
    "$ZB" status --json 2>/dev/null | "$PY" -c '
import sys, json
def x(v): return v if v else "-"
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in d.get("relations", []):
    print("%s\t%s\t%s\t%s\t%s\t%s" % (x(r.get("name")), x(r.get("peer_host")), x(r.get("client_target")),
          x(r.get("state")), x(r.get("profile")), x(r.get("local_user"))))' | tr -d '\r' >"$TMPD/rel.all"
    awk -F'\t' '$4!="removed"' "$TMPD/rel.all" >"$TMPD/rel.tsv"
    awk -F'\t' '$4=="removed"{print $1}' "$TMPD/rel.all" >"$TMPD/rel.removed"
}
step_target() {
    [ "$MODE" = sync ] && return 0
    local items=() t n cnt first="" seen="" p _st
    [ -e "$TMPD/targets.tsv" ] || info "$(title 5 'Dokąd?')" "Sprawdzam, dokąd trafiają kopie na tym hoście..."
    status_tsv
    while IFS=$'\t' read -r n p t _st; do      # 4. pole (stan) MUSI mieć własną zmienną: inaczej wpada do $t
        case "$t" in ''|-) continue ;; esac    # puste (relacja synchro) = "-", nie cel
        case " $seen " in *" $t "*) continue ;; esac
        seen="$seen $t"; cnt=$(awk -F'\t' -v t="$t" '$3==t' "$TMPD/rel.tsv" | grep -c .)
        items+=("$t" "$t   -- używają go już relacje na tym hoście: $cnt")
        [ -n "$first" ] || first="$t"
    done <"$TMPD/rel.tsv"
    [ -e "$TMPD/targets.tsv" ] || "$ZB" list-datasets --json 2>/dev/null | "$PY" -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for x in d.get("datasets", []):
    n = x.get("name", "")
    if n.count("/") == 1 and n.rsplit("/", 1)[1].lower() in ("backups", "backup", "kopie"): print(n)' | tr -d '\r' >"$TMPD/targets.tsv"
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        case " $seen " in *" $t "*) continue ;; esac
        items+=("$t" "$t   -- istnieje na tym hoście, jeszcze nieużywany"); seen="$seen $t"
        [ -n "$first" ] || first="$t"
    done <"$TMPD/targets.tsv"
    items+=(__other__ "Inna ścieżka…   (wpiszesz dataset na tym hoście)")
    if [ -n "$TARGET" ]; then in_list "$TARGET" "${items[@]}" && first="$TARGET" || first=__other__; fi
    while :; do
        geom
        wt --title "$(title 5 'Dokąd na tym hoście?')" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "${first:-__other__}" \
           --menu "Kopie wylądują pod:  <wybrane>/$HOST/<dataset źródła>\nnp.  ${first:-hdd/backups}/$HOST/${B_ROOT[0]}" "$(fit $((${#items[@]} / 2 + 4)))" "$W" "$((${#items[@]} / 2))" \
           "${items[@]}" || return 1
        if [ "$WT_OUT" != __other__ ]; then TARGET="$WT_OUT"; return 0; fi
        wt --title "$(title 5 'Dokąd -- inna ścieżka')" --ok-button "Dalej" --cancel-button "Wstecz" \
           --inputbox "Dataset na TYM hoście, pod którym mają lądować kopie (np. hdd/backups).\nKopie trafią pod:  <to>/$HOST/<dataset źródła>" 11 "$W" "$TARGET" || continue
        t="${WT_OUT// /}"
        case "$t" in ''|/*|*/|*[!A-Za-z0-9._:/-]*) wt --title "Zła ścieżka" --msgbox "'$WT_OUT' nie wygląda na nazwę datasetu (pula/nazwa, bez / na początku i końcu)." 9 "$W"; continue ;; esac
        TARGET="$t"; return 0
    done
}
in_list() { local x="$1" y; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

# --- krok 6: szablon ----------------------------------------------------------
load_profiles() {   # -> $TMPD/prof.tsv: nazwa <TAB> zdanie ; słowa z tui/zfs-tui.py (jedno źródło słów)
    [ -s "$TMPD/prof.tsv" ] && return 0
    "$ZB" list-profiles --json >"$TMPD/prof.json" 2>"$TMPD/prof.err" || return 1
    "$PY" - "$TMPD/prof.json" "$HERE/tui/zfs-tui.py" <<'PYEOF' | tr -d '\r' >"$TMPD/prof.tsv"
import sys, json, importlib.util
spec = importlib.util.spec_from_file_location("zfs_tui", sys.argv[2])
tui = importlib.util.module_from_spec(spec); spec.loader.exec_module(tui)
d = json.load(open(sys.argv[1], encoding="utf-8"))
def short_cadence(p):
    # "co godzinę (:01), co dobę 01:11, co tydzień nd 02:21" -> "co godzinę, dobę, tydzień"
    out = []
    for t in p.get("tiers", []):
        if t.get("send_schedule"):
            w = tui.cron_words(t["send_schedule"]).split()
            out.append(w[1] if len(w) > 1 and w[0] == "co" else " ".join(w[:2]))
    return ("co " + ", ".join(out)) if out else "?"
rows = []
# Szczeble retencji do okna "Jak długo trzymać w źródle" (uwaga 19): profil, szczebel,
# rodzina, ile trzyma. Tylko szczeble z keep -- tworzące (send_schedule bez keep) nie.
with open(sys.argv[1] + ".tiers", "w", encoding="utf-8", newline="\n") as tf:   # newline: na Windowsie tryb tekstowy pisze CRLF
    for p in d.get("profiles", []):
        for t in p.get("tiers", []):
            if t.get("keep"):
                tf.write("%s\t%s\t%s\t%s\n" % (p.get("name", "-"), t.get("name", "-"), t.get("pattern") or "-", t["keep"]))
for p in d.get("profiles", []):
    if "-src-" in (p.get("name") or ""):
        continue    # profil POCHODNY retencji źródła -- nie jest szablonem do wyboru w kroku 6
    w = tui.profile_words(p)
    mech = {"flat": "N najnowszych", "gfs": "GFS", "age": "wg wieku"}.get(p.get("mechanism", ""), p.get("mechanism") or "?")
    # Wiersz listy: co trzyma + mechanizm (to odróżnia d30h24 / -age / -gfs). Rytm wynika
    # z najdrobniejszego szczebla; pełne zdanie z rytmem idzie do podsumowania (3. pole).
    frozen = [t for t in p.get("tiers", []) if t.get("send_schedule") and t.get("quiesce")]
    rows.append((p.get("name", "?"), "%s  [%s]" % (w["retention"], mech), short_cadence(p), w["quiesce"], 1 if frozen else 0,
                 "ladder" if (p.get("shape") == "one-family" and p.get("mechanism") == "gfs") else "flat"))
rows.sort(key=lambda r: (r[0] != "default", r[0].lower()))     # default na górze
for n, t, c, q, f, sh in rows:
    print("%s\t%s\t%s\t%s\t%d\t%s" % (n or "-", t or "-", c or "-", q or "-", f, sh or "-"))
PYEOF
    [ -s "$TMPD/prof.tsv" ]
}
FREEZE=1
# KONTO MA KSZTAŁT (nie cały kolektor). Zmierzone na pve10, 2026-09-20: gdy jakaś
# ŻYWA relacja już używa szablonu PŁASKIEGO (jedna rodzina na szczebel), aktywacja
# szablonu-drabiny (GFS) jest ODMAWIANA ("This host reads as FLAT ... refusing to
# create ... with NO RETENTION AT ALL"). Configi są jednak per KONTO (root =
# jobs.<host>.conf, konto X = jobs.<host>.X.conf) -- czasownik odmawia dla konta
# relacji, nie dla hosta. Zmierzone na pve11, 2026-09-23: relacja SYNCHRO na
# koncie root miała szablon płaski, a kreator -- filtrując krok 6 po całym hoście
# -- nie zaproponował ŻADNEJ drabiny kontu zfsbackup, choć czasownik by ją przyjął
# (inny config, inne konto). Dlatego krok 6 pokazuje WSZYSTKIE szablony (właściciel
# 2026-09-20: "jeśli jest to w szablonie, to musi być widoczne"; oznaczone
# [zamraża]/[płaski]), a niedopasowanie sprawdza się PO wyborze konta, w kroku 8,
# dla TEGO konta.
account_is_flat() {    # <konto: "" = root> -> 0, gdy żywa relacja NA TYM KONCIE używa szablonu płaskiego
    local want="$1" n p t st pr lu fp
    [ "$want" != root ] || want=""
    status_tsv
    while IFS=$'\t' read -r n p t st pr lu; do
        [ "$st" = removed ] && continue
        case "$pr" in ''|-) continue ;; esac
        case "$lu" in ''|-) lu="" ;; esac
        [ "$lu" = "$want" ] || continue
        fp=$(awk -F'\t' -v n="$pr" '$1==n{print $6}' "$TMPD/prof.tsv")
        [ "$fp" = flat ] && return 0
    done <"$TMPD/rel.all"
    return 1
}
step_profile() {
    local items=() n w c q f sh def label
    geom
    [ -s "$TMPD/prof.tsv" ] || info "$(title 6 'Szablon')" "Czytam szablony retencji..."
    if ! load_profiles; then
        wt --title "$(title 6 'Szablon -- lista niedostępna')" --ok-button "Dalej" --cancel-button "Wstecz" \
           --inputbox "list-profiles nie odpowiedział ($(tail -1 "$TMPD/prof.err" 2>/dev/null)).\nWpisz nazwę szablonu ręcznie (domyślny: default)." 11 "$W" "${PROFILE:-default}" || return 1
        PROFILE="${WT_OUT// /}"; [ -n "$PROFILE" ] || PROFILE=default; FREEZE=1; return 0
    fi
    items=()
    while IFS=$'\t' read -r n w c q f sh; do
        [ -n "$n" ] || continue
        label="$(printf '%-15s %s' "$n" "$w")"
        [ "$f" = 1 ] && label="$label  [zamraża]"
        [ "$sh" = flat ] && label="$label  [płaski]"
        items+=("$n" "$label")
    done <"$TMPD/prof.tsv"
    def=default
    in_list "$PROFILE" "${items[@]}" && def="$PROFILE"
    in_list "$def" "${items[@]}" || def="${items[0]}"
    geom
    wt --title "$(title 6 'Jak długo trzymać w celu (na tym hoście)?')" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$def" \
       --menu "Wszystkie szablony retencji. [zamraża] = zamraża gościa przed migawkami\ndobowymi i rzadszymi (zgoda źródła -- krok 9). [płaski] = jedna rodzina,\nN najnowszych, bez drabiny GFS -- takiego wymaga konto, na którym już\ndziała inny płaski szablon (sprawdzane po wyborze konta w kroku 8).\nSzablon da się zmienić później." "$H" "$W" "$(lhfit $((${#items[@]} / 2)) 6)" \
       "${items[@]}" || return 1
    PROFILE="$WT_OUT"
    f="$(awk -F'\t' -v n="$PROFILE" '$1==n{print $5}' "$TMPD/prof.tsv")"
    case "$f" in 1) FREEZE=1 ;; *) FREEZE=0 ;; esac
    return 0
}

# --- krok 7: nazwa ------------------------------------------------------------
step_name() {
    local n
    [ -n "$RNAME" ] || RNAME="${HOSTNAME_R:-$HOST}"
    while :; do
        geom
        wt --title "$(title 7 'Nazwa relacji')" --ok-button "Dalej" --cancel-button "Wstecz" \
           --inputbox "Pod tą nazwą relacja będzie widoczna na F3, w cronie i w mailach.\nLitery, cyfry, kropka, myślnik, podkreślenie." 11 "$W" "$RNAME" || return 1
        n="${WT_OUT// /}"
        case "$n" in ''|*[!A-Za-z0-9._-]*) wt --title "Zła nazwa" --msgbox "'$WT_OUT' -- dozwolone: litery, cyfry, kropka, myślnik, podkreślenie." 8 "$W"; continue ;; esac
        [ -s "$TMPD/rel.tsv" ] || status_tsv
        if awk -F'\t' -v n="$n" '$1==n{f=1} END{exit !f}' "$TMPD/rel.tsv"; then
            wt --title "Nazwa zajęta" --msgbox "Relacja o nazwie '$n' już jest na tym hoście. Podaj inną." 8 "$W"; RNAME="$n"; continue
        fi
        if grep -qxF -- "$n" "$TMPD/rel.removed" 2>/dev/null; then
            # Zmierzone na pve10: bez tego plan odpowiadał "removed and cannot be revived",
            # a kreator i tak pokazywał WYKONAJ.
            RNAME="$n"
            wt --title "Nazwę '$n' trzyma USUNIĘTA relacja" --yes-button "Zwolnij nazwę" --no-button "Inna nazwa" \
               --yesno "Relacja '$n' została kiedyś usunięta, ale jej stary rekord nadal trzyma nazwę\n(program nie wskrzesza usuniętych relacji).\n\n'Zwolnij nazwę' = zfs-backup.sh delete-relation $n --yes: usuwa stary rekord\ni sprząta po nim na źródle, jeśli coś tam zostało. Kopii na dysku nie rusza." 14 "$W" || continue
            info "Zwalniam nazwę $n" "delete-relation $n --yes ..."
            if "$ZB" delete-relation "$n" --yes >"$TMPD/free.log" 2>&1; then
                rm -f "$TMPD/rel.done"; status_tsv
            else
                wt --title "Nie udało się zwolnić nazwy" --msgbox "$(tail -6 "$TMPD/free.log")" 14 "$W"; continue
            fi
        fi
        RNAME="$n"; return 0
    done
}

# --- krok 8: konto ------------------------------------------------------------
step_account() {
    local r=OFF z=OFF o=OFF a acct_name shape
    while :; do
        case "$ACCT" in zfsbackup) z=ON ;; other) o=ON ;; *) r=ON ;; esac
        geom
        wt --title "$(title 8 'Na jakim koncie mają chodzić zadania?')" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
           --radiolist "Konto na TYM hoście, z którego cron będzie pobierał kopie.\nKonto delegowane nie jest rootem: dostaje tylko prawa zfs do celu." "$(fit 8)" "$W" 3 \
           root      "root  -- bez izolacji (tak działa większość floty dziś)" "$r" \
           zfsbackup "zfsbackup  -- konto delegowane (zostanie utworzone)" "$z" \
           other     "inne konto…  (podasz nazwę)" "$o" || return 1
        [ -n "$WT_OUT" ] && ACCT="$WT_OUT"
        r=OFF; z=OFF; o=OFF
        if [ "$ACCT" = other ]; then
            while :; do
                wt --title "$(title 8 'Nazwa konta')" --ok-button "Dalej" --cancel-button "Wstecz" --inputbox "Nazwa konta na tym hoście (zostanie utworzone, jeśli go nie ma)." 9 "$W" "$ACCT_OTHER" || { ACCT=root; return 1; }
                a="${WT_OUT// /}"
                case "$a" in ''|root|*[!a-z0-9_-]*) wt --title "Zła nazwa konta" --msgbox "Małe litery, cyfry, myślnik, podkreślenie; nie 'root'." 8 "$W"; continue ;; esac
                ACCT_OTHER="$a"; break
            done
        fi
        acct_name="$(account_name)"
        shape="$(awk -F'\t' -v n="$PROFILE" '$1==n{print $6}' "$TMPD/prof.tsv" 2>/dev/null)"
        if account_is_flat "$acct_name" && [ "$shape" != flat ]; then
            wt --title "Szablon nie pasuje do konta" --msgbox "Na koncie ${acct_name:-root} już działają relacje z szablonem PŁASKIM\n(jedna rodzina na szczebel, bez drabiny GFS) -- to jest jego config.\nSzablonu-drabiny (GFS) nie da się do niego dodać, czasownik by to\nodmówił ('This host reads as FLAT').\n\nWybierz inne konto, albo Wstecz do kroku 6 po szablon płaski." "$(fit 8)" "$W"
            continue
        fi
        return 0
    done
}
account_name() { case "$ACCT" in zfsbackup) echo zfsbackup ;; other) echo "$ACCT_OTHER" ;; *) echo "" ;; esac; }

# --- krok 9: ustawienia dodatkowe ---------------------------------------------
step_extra() {
    # LISTA JEST ODPOWIEDZIĄ, przyciski to Dalej i Wstecz -- decyzja właściciela
    # 2026-09-20: "Ma byc przycisk Dalej, wstecz a wybiera sie enterem na liscie".
    # Poprzednio to był edytor ustawień: menu, którego PIERWSZY WIERSZ ("Bez zmian,
    # dalej") był wyjściem naprzód. Właściciel nazwał to potworkiem i miał rację --
    # wiersz udawał ustawienie, a po zmianie czegokolwiek niżej czytał się jak
    # "odrzuć to, co wybrałeś". Whiptail (newt 0.52.23, ZMIERZONE) ma dokładnie dwa
    # przyciski: OK i Cancel -- nie ma trzeciego, więc ekran, który jednocześnie
    # EDYTUJE pozycje i ma Dalej, jest w tym narzędziu niewykonalny. Stąd checklista:
    # spacja przełącza, Enter = Dalej, Esc/Wstecz = krok w tył. Pozycje, które
    # potrzebują wartości (własne maski, inna retencja u źródła), pytają o nią
    # w NASTĘPNYM oknie -- każde z nich ma już normalne Dalej/Wstecz.
    local items=() on_grant=OFF on_q=OFF on_srcp=OFF on_man=OFF
    local want_masks=0 want_srcp=0 defmask="__replicate_,vzdump,__migration__"
    while :; do
        geom
        [ "$GRANT" -eq 1 ] && on_grant=ON || on_grant=OFF
        [ "$GQUIESCE" -eq 1 ] && on_q=ON || on_q=OFF
        [ -n "$SRCPROF" ] && on_srcp=ON || on_srcp=OFF
        [ "$MANUAL" -eq 1 ] && on_man=ON || on_man=OFF
        [ "$RECURSION" = atomic ] && { SRCPROF=""; on_srcp=OFF; }
        items=(grant "Prawa na źródle nadaj STĄD, przez SSH jako root -- bez tego instalacja stanie i poda komendę do wykonania na źródle" "$on_grant")
        if [ "$FREEZE" -eq 1 ] && [ "$GRANT" -eq 1 ]; then
            items+=(quies "Nadaj też zgodę na ZAMRAŻANIE gości -- bez niej migawki dobowe i rzadsze wyjdą jako '_crash_'" "$on_q")
        fi
        # POMIJANE MIGAWKI: jedna pozycja, nie dwie. Dopóki lista jest domyślna,
        # "skip" pokazuje ją wprost i "masks" tylko otwiera edytor (odznaczone).
        # Gdy lista już się różni od domyślnej (bo operator ją zmienił), pozycja
        # "skip" znika -- jest już czym modyfikować, nie czym się zgadzać -- a
        # "masks" mówi wprost, co jest pomijane, i jest zaznaczona (właściciel,
        # uwagi 10+13: zgubiona przecinkiem maska w polu tekstowym -> edytor
        # zamiast wpisywania z palca, lista pokazuje aktualny stan).
        if [ "$EXFAM" = "$defmask" ]; then
            items+=(skip "Pomijaj migawki Proxmoxa: $EXFAM" ON)
            items+=(masks "Modyfikuj lub dodaj pomijane migawki po prefiksach" OFF)
        else
            items+=(masks "Pomijane migawki: ${EXFAM:-żadne (kopiowane wszystkie)}  (Modyfikuj lub dodaj)" ON)
        fi
        if [ "$RECURSION" != atomic ]; then
            items+=(srcp "Inna retencja u źródła (na $HOST) niż tutaj -- wybierzesz w następnym oknie" "$on_srcp")
        fi
        items+=(man "Parowanie RĘCZNE: paczka do przeniesienia (gdy ten host nie ma wstępu po SSH)" "$on_man")
        wt --title "$(title 9 'Ustawienia dodatkowe')" --ok-button "Dalej" --cancel-button "Wstecz" --notags --separate-output \
           --checklist "Domyślne są dobre dla zwykłej relacji. SPACJA przełącza, ENTER = Dalej." "$(fit $((${#items[@]} / 3 + 7)))" "$W" "$((${#items[@]} / 3))" \
           "${items[@]}" || return 1
        GRANT=0; GQUIESCE=0; MANUAL=0; want_masks=0; want_srcp=0
        local keep_skip=0 x
        while IFS= read -r x; do
            case "$x" in
                grant) GRANT=1 ;;
                quies) GQUIESCE=1 ;;
                skip)  keep_skip=1 ;;
                masks) want_masks=1 ;;
                srcp)  want_srcp=1 ;;
                man)   MANUAL=1 ;;
            esac
        done <<<"$WT_OUT"
        # Zgoda na zamrażanie ma sens tylko razem z nadaniem praw stąd; gdy pozycji
        # nie było na liście, nie wolno jej cichcem zostawić włączonej.
        [ "$FREEZE" -eq 1 ] && [ "$GRANT" -eq 1 ] || GQUIESCE=0
        if [ "$EXFAM" = "$defmask" ] && [ "$keep_skip" -eq 0 ] && [ "$want_masks" -eq 0 ]; then
            EXFAM=""
        elif [ "$want_masks" -eq 1 ]; then
            prefix_editor || continue
        fi
        if [ "$want_srcp" -eq 1 ] && [ "$RECURSION" != atomic ] && [ -s "$TMPD/prof.json.tiers" ]; then
            source_retention_editor || continue
        else
            SRCPROF=""
        fi
        return 0
    done
}
# RETENCJA ŹRÓDŁA = SAME LICZBY (właściciel, uwaga 19, 2026-09-24). Wcześniej operator
# wybierał CAŁY profil źródła i dwa razy wybrał taki, który kasuje inną rodzinę niż cel
# ('prunes a different snapshot FAMILY' -- odmowa dopiero na końcu). Teraz: szczeble
# profilu CELU z jego liczbami jako podpowiedzią; operator zmienia liczby, a profil
# źródła powstaje z profilu celu czasownikiem save-profile (te same rodziny z
# konstrukcji; jego trzy bramki sprawdzają wynik). 0 = brak szczebla (--drop-tier),
# dozwolone tylko, gdy rodzinę sprząta inny szczebel -- inaczej źródło trzymałoby ją
# w nieskończoność. Nazwa deterministyczna: <cel>-src-<litery i liczby>; te same liczby
# = ten sam profil, nadpisywany identyczną treścią.
tier_word() {   # <nazwa szczebla> -> słowo
    case "$1" in
        *hourly) echo "godzinowe" ;; *daily) echo "dobowe" ;; *weekly) echo "tygodniowe" ;;
        *monthly) echo "miesięczne" ;; *yearly|*annual) echo "roczne" ;; *) echo "$1" ;;
    esac
}
tier_letter() { case "$1" in *hourly) echo H ;; *daily) echo D ;; *weekly) echo W ;; *monthly) echo M ;; *yearly|*annual) echo Y ;; *) echo X ;; esac; }
source_retention_editor() {
    local -a tn=() tp=() tk=() sk=()
    local t p k i n items v ok name out
    while IFS=$'\t' read -r n t p k; do
        [ "$n" = "$PROFILE" ] || continue
        k="${k%$'\r'}"
        tn+=("$t"); tp+=("$p"); tk+=("$k"); sk+=("$k")
    done <"$TMPD/prof.json.tiers"
    [ "${#tn[@]}" -gt 0 ] || { wt --title "Retencja źródła" --msgbox "Szablon $PROFILE nie ma szczebli z liczbą do zmiany." 8 "$W"; return 1; }
    # poprzednie liczby tego samego szablonu (powrót do okna)
    if [ -n "$SRCKEEP" ] && [ "${SRCKEEP%%:*}" = "$PROFILE" ]; then read -r -a sk <<<"${SRCKEEP#*:}"; fi
    while :; do
        items=()
        for i in "${!tn[@]}"; do
            items+=("$i" "$(printf '%-12s cel %-4s -> źródło %s' "$(tier_word "${tn[$i]}")" "${tk[$i]}" "$([ "${sk[$i]}" = 0 ] && echo 'brak' || echo "${sk[$i]}")")")
        done
        items+=(ok "Gotowe")
        geom
        wt --title "$(title 9 "Jak długo trzymać w źródle (na $HOST)?")" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item ok \
           --menu "Te same szczeble co tutaj ($PROFILE) -- zmień tylko liczby.\n0 = źródło nie trzyma tego szczebla wcale." "$(fit $((${#tn[@]} + 6)))" "$W" "$((${#tn[@]} + 1))" \
           "${items[@]}" || return 1
        if [ "$WT_OUT" != ok ]; then
            i="$WT_OUT"
            wt --title "$(tier_word "${tn[$i]}") u źródła" --ok-button "Dalej" --cancel-button "Wstecz" \
               --inputbox "Ile $(tier_word "${tn[$i]}") trzymać na $HOST (tutaj: ${tk[$i]}; 0 = bez tego szczebla):" 9 "$W" "${sk[$i]}" || continue
            v="${WT_OUT// /}"
            case "$v" in ''|*[!0-9]*) wt --title "To nie liczba" --msgbox "Podaj liczbę całkowitą, 0 albo więcej." 8 "$W"; continue ;; esac
            v=$((10#$v))
            if [ "$v" -eq 0 ]; then
                ok=0
                for n in "${!tn[@]}"; do [ "$n" != "$i" ] && [ "${tp[$n]}" = "${tp[$i]}" ] && [ "${sk[$n]}" != 0 ] && ok=1; done
                [ "$ok" -eq 1 ] || { wt --title "Tego szczebla nie da się wyłączyć" --msgbox "Rodziny ${tp[$i]} nie sprząta żaden inny szczebel -- bez niego źródło\ntrzymałoby te migawki w nieskończoność. Zostaw co najmniej 1." 9 "$W"; continue; }
            fi
            sk[$i]="$v"
            continue
        fi
        SRCKEEP="$PROFILE:${sk[*]}"
        # nic nie zmienione -> źródło jak cel (bez osobnego profilu)
        [ "${sk[*]}" != "${tk[*]}" ] || { SRCPROF=""; return 0; }
        name="$PROFILE-src-"
        local -a args=(--from="$PROFILE" --force)
        for i in "${!tn[@]}"; do
            [ "${sk[$i]}" = 0 ] && { args+=(--drop-tier="${tn[$i]}"); continue; }
            name="$name$(tier_letter "${tn[$i]}")${sk[$i]}"
        done
        info "$(title 9 'Retencja źródła')" "Zapisuję szablon źródła $name..."
        out=$("$ZB" save-profile "${args[@]}" --as="$name" --description="Retencja ŹRÓDŁA na bazie $PROFILE (pochodny, z kreatora)" 2>&1) \
            || { wt --title "Szablon źródła odrzucony" --msgbox "$(printf '%s' "$out" | tail -6)" 14 "$W"; continue; }
        for i in "${!tn[@]}"; do
            [ "${sk[$i]}" = 0 ] || [ "${sk[$i]}" = "${tk[$i]}" ] && continue
            out=$("$ZB" save-profile --from="$name" --as="$name" --force --tier="${tn[$i]}" --keep="${sk[$i]}" 2>&1) \
                || { wt --title "Szablon źródła odrzucony" --msgbox "$(printf '%s' "$out" | tail -6)" 14 "$W"; continue 2; }
        done
        SRCPROF="$name"
        return 0
    done
}
# EDYTOR POMIJANYCH MIGAWEK (właściciel, uwagi 10+13). Wcześniej to było jedno
# pole tekstowe -- łatwo było zgubić przecinek ("__migration___tmp" zamiast
# "__migration__,_tmp"). Checklista pokazuje, co jest pomijane, ODZNACZ, żeby
# przestać; "Dodaj nowy prefiks…" otwiera pole na kolejny -- bez ryzyka
# przepisywania całej listy z pamięci.
prefix_editor() {   # edytuje EXFAM; 0 = zapisano (może być pusta), 1 = Wstecz (bez zmian)
    local base items=() p new kept=() want_add=0 x
    base="$EXFAM"; [ -n "$base" ] || base="$defmask"
    while :; do
        items=()
        local IFS=,; for p in $base; do [ -n "$p" ] && items+=("$p" "" ON); done; unset IFS
        items+=(__add__ "Dodaj nowy prefiks…" OFF)
        geom
        wt --title "Pomijane migawki -- prefiksy" --ok-button "Dalej" --cancel-button "Wstecz" --notags --separate-output \
           --checklist "Zaznaczone prefiksy są pomijane. ODZNACZ, żeby przestać pomijać.\n'Dodaj nowy prefiks…' otwiera pole na kolejny." "$(fit $((${#items[@]} / 3 + 4)))" "$W" "$((${#items[@]} / 3))" \
           "${items[@]}" || return 1
        want_add=0; kept=()
        while IFS= read -r x; do
            case "$x" in __add__) want_add=1 ;; '') ;; *) kept+=("$x") ;; esac
        done <<<"$WT_OUT"
        if [ "$want_add" -eq 1 ]; then
            while :; do
                wt --title "Nowy prefiks" --ok-button "Dalej" --cancel-button "Wstecz" \
                   --inputbox "Nowy prefiks (bez spacji i przecinków):" 9 "$W" "" || break
                new="$WT_OUT"
                case "$new" in ''|*' '*|*,*) wt --title "Zły prefiks" --msgbox "'$WT_OUT' -- bez spacji i przecinków, nie może być puste." 8 "$W"; continue ;; esac
                kept+=("$new"); break
            done
            local IFS=,; base="${kept[*]}"; unset IFS
            continue
        fi
        local IFS=,; EXFAM="${kept[*]}"; unset IFS
        return 0
    done
}

# --- komenda ----------------------------------------------------------------
# Wzorce dla -X BEZ metaznaków powłoki. Rekord -> pole `flags` w configu -> linia
# crona, wszędzie wklejane BEZ cudzysłowów: `(`, `|` rozbiłyby komendę co noc.
# `^nazwa$` i `^nazwa/` przechodzą przez sh bez zmian i nie łapią `nazwa1`
# (zmierzone od kreatora do celu, pve10 <- pve11, 2026-09-19). Kropka w nazwie
# zostaje kropką wzorca: nadzbiór, w praktyce ten sam.
build_argv() {   # [install] -> ARGV[]
    local IFS=, i x D='$' a
    ARGV=("$ZB" "--source=$(hostport):${B_ROOT[*]}")
    if [ "$MODE" = sync ]; then ARGV+=("--mode=sync"); else ARGV+=("--target=$TARGET"); fi
    [ -n "$PROFILE" ] && ARGV+=("--profile=$PROFILE")
    [ -n "$SRCPROF" ] && ARGV+=("--source-profile=$SRCPROF")
    [ -n "$RNAME" ] && ARGV+=("--name=$RNAME")
    [ "$RECURSION" = atomic ] && ARGV+=("--recursive=atomic")
    for i in "${!B_ROOT[@]}"; do
        while IFS= read -r x; do
            [ -n "$x" ] || continue
            ARGV+=("--exclude-child=^$x${D}")
            [ "$(kids_count "$x")" -gt 0 ] && ARGV+=("--exclude-child=^$x/")
        done <<<"${B_EXCL[$i]}"
    done
    [ -n "$EXFAM" ] && ARGV+=("--exclude-family=$EXFAM")
    a="$(account_name)"; [ -n "$a" ] && ARGV+=("--local-user=$a")
    [ "$GRANT" -eq 1 ] && ARGV+=("--grant-remotely")
    [ "$GRANT" -eq 1 ] && [ "$FREEZE" -eq 1 ] && [ "$GQUIESCE" -eq 1 ] && ARGV+=("--grant-quiesce")
    [ "$MANUAL" -eq 1 ] && ARGV+=("--manual-join")
    [ "${1:-}" = install ] && ARGV+=("--install" "--yes")
    return 0
}
cmd_lines() { local a; printf '  %s \\\n' "${ARGV[0]}"; for a in "${ARGV[@]:1}"; do printf '      %s\n' "$(shq "$a")"; done; }
cmd_oneline() { local a; for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done; }

# --- krok 10: podsumowanie -> plan -> wykonanie ---------------------------------
summary_text() {
    local i a; a="$(account_name)"
    if [ "$MODE" = sync ]; then
        echo "SYNCHRO: $(hostname) i $HOST${HOSTNAME_R:+ ($HOSTNAME_R)} będą trzymać to samo pod tą samą ścieżką:"
    else
        echo "BACKUP: $(hostname) będzie POBIERAĆ z $HOST${HOSTNAME_R:+ ($HOSTNAME_R)} do $TARGET/$HOST/..."
    fi
    for i in "${!B_ROOT[@]}"; do echo "    ${B_ROOT[$i]}  -- $(describe "$i")"; done
    echo "Sposób:  $(mode_words).   Nazwa: $RNAME.   Konto: ${a:-root}."
    echo "Szablon: $PROFILE$( [ -s "$TMPD/prof.tsv" ] && awk -F'\t' -v n="$PROFILE" '$1==n{print "  (" $3 "; " $2 "; " $4 ")"}' "$TMPD/prof.tsv")$( [ -n "$SRCPROF" ] && echo "; u źródła: $SRCPROF")"
    echo "Pomijane migawki: ${EXFAM:-żadne (kopiowane wszystkie)}"
    [ "$RECURSION" = atomic ] && echo "U ŹRÓDŁA migawek nie sprząta nikt (tak działa atomowo) -- trzeba samemu."
    if [ "$FREEZE" -eq 1 ]; then
        if [ "$GRANT" -eq 1 ] && [ "$GQUIESCE" -eq 1 ]; then echo "Zamrażanie: źródło dostanie zgodę stąd (--grant-quiesce)."
        else echo "Zamrażanie: BEZ zgody źródła migawki wyjdą jako '_crash_' (niezamrożone)."; fi
    fi
    echo "Prawa na źródle: $( [ "$GRANT" -eq 1 ] && echo "nadane stąd, od razu" || echo "zatwierdzisz SAM -- instalacja stanie i poda komendę" )$( [ "$MANUAL" -eq 1 ] && echo "; parowanie ręczne")"
    echo
    echo "Komenda (to samo wpisałbyś z palca):"
    cmd_oneline; echo
    any_excl && echo "(^nazwa${D:-\$} = dokładnie ten dataset, nie łapie np. ...disk-01)"
    return 0
}
step_summary() {    # 0 = wykonano (RC_RUN), 1 = wstecz
    local rc
    while :; do
        geom
        build_argv install
        summary_text >"$TMPD/summary.txt"
        yesno_text "$TMPD/summary.txt" "$(title 10 'Podsumowanie')" "Pokaż plan" "Wstecz" || return 1
        build_argv
        info "$(title 10 'Plan')" "Pytam czasownik o plan (nic nie zmienia)..."
        "${ARGV[@]}" >"$TMPD/plan.txt" 2>&1; rc=$?
        { echo "PLAN -- nic jeszcze nie zostało zmienione (rc=$rc):"; echo; cat "$TMPD/plan.txt"; } >"$TMPD/plan2.txt"
        if [ "$rc" -ne 0 ]; then
            wt --title "$(title 10 'Plan ODRZUCONY przez czasownik')" --scrolltext --msgbox "$(cat "$TMPD/plan2.txt")" "$H" "$W"
            continue
        fi
        yesno_text "$TMPD/plan2.txt" "$(title 10 'Plan')" "WYKONAJ" "Wstecz" || continue
        build_argv install
        clear 2>/dev/null
        echo "\$ $(cmd_oneline)"; echo
        "${ARGV[@]}" 2>&1 | tee "$TMPD/run.log"; RC_RUN=${PIPESTATUS[0]}
        # DZIENNIK DLA F3 Ins (owner note 5): TUI ustawia ZFS_TUI_LOG na
        # sciezke ~/.zfs-tui/new-relation-<stamp>.log przed oddaniem terminala
        # tu; dopisujemy do niego, zeby wynik biegu nie zniknal w $TMPD.
        if [ -n "${ZFS_TUI_LOG:-}" ] && [ -f "$TMPD/run.log" ]; then
            cat "$TMPD/run.log" >>"$ZFS_TUI_LOG" 2>/dev/null
            echo "rc=$RC_RUN" >>"$ZFS_TUI_LOG" 2>/dev/null
        fi
        echo
        if [ "$RC_RUN" -eq 0 ]; then echo "=== GOTOWE: relacja '$RNAME' założona (rc=0). Enter = dalej"
        elif [ "$GRANT" -eq 0 ] && grep -q -- '--commit-scope=' "$TMPD/run.log"; then
            # To nie awaria: wybrano "zatwierdzę sam", więc instalacja MA stanąć w tym miejscu.
            echo "=== ZATRZYMANE ZGODNIE Z WYBOREM -- relacja '$RNAME' czeka na zgodę źródła."
            echo "    1. Na $HOST, jako root:   cd $C_DIR && ./$(grep -o 'deploy.sh --commit-scope=[^ ]*' "$TMPD/run.log" | tail -1)$( [ "$FREEZE" -eq 1 ] && echo ' --allow-quiesce')"
            [ "$FREEZE" -eq 1 ] && echo "       (--allow-quiesce: bez tego szablon zamrażający da migawki '_crash_')"
            echo "    2. Potem TUTAJ ponów tę samą komendę (zapisana w $HOME/new-relation-$RNAME.cmd):"
            cmd_oneline >"$HOME/new-relation-$RNAME.cmd" 2>/dev/null; echo >>"$HOME/new-relation-$RNAME.cmd"
            echo "       $(cmd_oneline)"
            echo "    Enter = dalej"
        else echo "=== NIE UDAŁO SIĘ (rc=$RC_RUN) -- przeczytaj powyżej. Enter = dalej"; fi
        [ -t 0 ] && read -r _
        return 0
    done
}

# --- pętla kroków: 0 = dalej, 1 = wstecz ------------------------------------
RC_RUN=1
step=mode
while :; do
    case "$step" in
        mode)    if step_mode;     then step=host;    else clear 2>/dev/null; echo "new-relation: przerwane, nic nie zmieniono"; exit 1; fi ;;
        host)    if step_host;     then step=diag;    else step=mode; fi ;;
        diag)    if step_diag;     then step=ds;      else step=host; fi ;;
        ds)      if step_datasets; then step=target;  else step=host; fi ;;
        target)  if step_target;   then step=profile; else step=ds; fi ;;
        profile) if step_profile;  then step=name;    else [ "$MODE" = sync ] && step=ds || step=target; fi ;;
        name)    if step_name;     then step=acct;    else step=profile; fi ;;
        acct)    if step_account;  then step=extra;   else step=name; fi ;;
        extra)   if step_extra;    then step=summary; else step=acct; fi ;;
        summary) if step_summary;  then break;        else step=extra; fi ;;
    esac
done
exit "$RC_RUN"
