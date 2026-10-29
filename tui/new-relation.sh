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
# Stan (U25, 2026-10-20): KARTA RELACJI -- pola rodzaj, źródło (host + diagnoza), datasety
# (koszyk miejsc), cel, harmonogram, retencja źródła, nazwa, konto, dodatkowe; otwierają
# się same jedno po drugim, Wstecz wraca na kartę; "Utwórz relację" -> podsumowanie ->
# plan -> wykonanie. "Same migawki" (X27 S4) to kopia lokalna BEZ celu: bez pól cel,
# retencja źródła i dodatkowe, komenda local-backup --target=''.
#
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "new-relation: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
. "$HERE/tui/basket-lib.sh" || { echo "new-relation: brak $HERE/tui/basket-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
. "$HERE/tui/retention-lib.sh" || { echo "new-relation: brak $HERE/tui/retention-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
WT_BACKTITLE="$(Tv 'Nowa relacja -- kolektor $(hostname)' '$(hostname)' "$(hostname)")"
NSTEP=10
TMPD="$(mktemp -d)" || exit 1
# Szkic ukrytego szablonu relacji ("Ręcznie" w kroku 6) znika, gdy relacja nie powstała.
MANUAL_P=""; NR_DONE=0
drop_manual_draft() {
    [ -n "$MANUAL_P" ] && [ "$NR_DONE" -ne 1 ] && "$ZB" delete-profile "$MANUAL_P" --yes >/dev/null 2>&1
    MANUAL_P=""
}
trap 'drop_manual_draft; rm -rf "$TMPD"' EXIT

# --- odpowiedzi -------------------------------------------------------------
MODE="backup"; HOST=""; PORT="22"; HOSTNAME_R=""; RECURSION="flat"; NOCOPY=0

# --- okna -------------------------------------------------------------------
# U25 (właściciel 2026-10-20): kreator to KARTA RELACJI -- wszystkie pola naraz, więc
# "Krok 4/10" nic nie mówi. Tytuł okna pola = samo pytanie; pierwszy argument (dawny
# numer kroku) zostaje, żeby wywołania się nie zmieniały.
# U66 (właściciel 2026-10-21, przebudowa): kreator KROK PO KROKU -- tytuł mówi, który to krok
# z ilu (liczą się tylko kroki tego rodzaju relacji); w podsumowaniu bez licznika.
title() {
    if [ -n "${WZ_SN:-}" ]; then T 'Nowa relacja -- krok %s z %s: %s' "$WZ_SI" "$WZ_SN" "$2"
    else T 'Nowa relacja: %s' "$2"; fi
}
# Kopia lokalna nie ma drugiego hosta: czytelniki pytamy bez adresu (= ten host).
hostport() { [ "$MODE" = local ] && return 0; [ "$PORT" = 22 ] && echo "$HOST" || echo "$HOST:$PORT"; }
# Katalog kopii pod celem (U111, 2026-10-29): NAZWA źródła, którą zgłosił host przy diagnozie
# (pve9), nie wpisany adres -- inaczej kopie lądowały w hdd/backups/192.168.28.99/...
# Silnik zapisuje go raz, przy założeniu (--landing); zmiana adresu go nie rusza.
# Nazwa źródła w TEKSTACH okien po diagnozie (U111): host zgłosił się jako pve9 -- okna mówią
# „z pve9”, a adres zostaje tam, gdzie jest poleceniem (ssh, list-datasets, komenda).
hostw() { local n="${HOSTNAME_R%%.*}"; printf '%s' "${n:-$HOST}"; }
landing() {
    local n="${HOSTNAME_R%%.*}"
    case "$n" in ''|.|..|-*|*[!A-Za-z0-9._-]*) n="$HOST" ;; esac
    printf '%s' "$n"
}

# --- krok 1: typ ------------------------------------------------------------
step_mode() {
    geom
    # Kampania 2026-10-22: w RADIOLIŚCIE Enter bierze zaznaczoną kropkę, nie podświetloną pozycję --
    # strzałka na "Lustro" i Enter dawały backup. Menu: Enter na pozycji = ta pozycja.
    local cur="$MODE"
    [ "$NOCOPY" -eq 1 ] && cur=snap
    case "$cur" in sync|local|snap|snaponly) ;; *) cur=backup ;; esac
    # Przejście 2026-10-24: opis miał 8 linii przy oknie na 10 (z listą) -- linia o migawkach
    # zdalnych nie mieściła się wcale, a ostatnia mówiła o klawiszach w treści okna (E88).
    # Teksty przez T (język okien; pilot P0 tłumaczenia).
    wt --title "$(title 1 "$(T 'Jaka relacja?')")" --ok-button "$(T Dalej)" --cancel-button "$(T Wyjdź)" --notags --default-item "$cur" \
       --menu "$(T 'Backup: ten host POBIERA migawki ze źródła i trzyma je u siebie.\nLustro: te same datasety pod tą samą ścieżką i te same migawki:\nco zniknie u źródła, zniknie też tutaj (bez własnej retencji).\nKopia lokalna: kopia na tym samym hoście, np. rpool/data -> hdd/backup.\nMigawki lokalne: migawki i ich sprzątanie w datasetach tego hosta, bez kopii.\nMigawki zdalne: ten host robi i sprząta migawki NA innym hoście, bez kopii.')" "$(fit 13)" "$W" 5 \
       backup "$(T 'Backup    (ten host pobiera ze źródła)')" \
       sync   "$(T 'Lustro    (to samo po obu stronach)')" \
       local  "$(T 'Kopia lokalna  (na tym hoście)')" \
       snap   "$(T 'Migawki lokalne  (na tym hoście, bez kopii)')" \
       snaponly "$(T 'Migawki zdalne  (na innym hoście, bez kopii)')" || return 1
    # "Same migawki" = kopia lokalna bez celu: te same kroki co Lokalnie, bez "Dokąd".
    if [ "$WT_OUT" = snap ]; then NOCOPY=1; WT_OUT=local; TARGET=""; else NOCOPY=0; fi
    if [ -n "$WT_OUT" ] && [ "$WT_OUT" != "$MODE" ]; then
        # Inna droga = inne źródło: koszyk z poprzedniej nie należy do tej.
        B_ROOT=(); B_EXCL=(); B_CLOSED=""; TREE_FOR="-"
        MODE="$WT_OUT"; [ "$MODE" = local ] || GRANT=1
    fi
    if [ "$MODE" = local ]; then
        HOST="$(hostname -s 2>/dev/null || hostname)"; PORT=22; HOSTNAME_R=""
        RECURSION=flat; GRANT=0; MANUAL=0; GQUIESCE=0
    fi
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
        wt --title "$(title 2 "$(T 'Z którego hosta?')")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" \
           --inputbox "$(T 'Adres hosta źródłowego: IP albo nazwa, opcjonalnie :port.\n\nPakiet nie musi tam jeszcze być -- następny krok to sprawdzi\ni zaproponuje instalację. Potrzebny jest tylko wstęp SSH jako root.')" \
           13 "$W" "$init" || return 1
        init="$WT_OUT"      # po odmowie pole wraca z tym, co wpisano -- do poprawienia, nie od zera
        h="${WT_OUT// /}"; p=22
        case "$h" in *:*) p="${h##*:}"; h="${h%%:*}" ;; esac
        case "$h" in ''|-*|*[!A-Za-z0-9._-]*)   # '-' na początku: ssh wziąłby to za opcję
            wt --title "$(T 'Zły adres')" --msgbox "$(Tv ''\''$WT_OUT'\'' nie wygląda na adres hosta.\nDozwolone: litery, cyfry, kropka, myślnik; opcjonalnie :port.' '$WT_OUT' "$WT_OUT")" 9 "$W"; continue ;; esac
        case "$p" in ''|*[!0-9]*)
            wt --title "$(T 'Zły port')" --msgbox "$(Tv 'Port '\''$p'\'' nie jest liczbą.' '$p' "$p")" 8 "$W"; continue ;; esac
        [ -e "$TMPD/rel.done" ] || info "$(title 2 "$(T 'Z którego hosta?')")" "$(Tv 'Sprawdzam, czy z $h nie ma już relacji...' '$h' "$h")"
        rel="$(existing_relation "$h")"
        if [ -n "$rel" ]; then
            wt --title "$(T 'Ta relacja już istnieje')" --msgbox "$(Tv 'Z hostem $h relacja już istnieje: $rel.

Z jednym hostem jest tylko jedna relacja, za to z dowolną liczbą datasetów.
Dataset do istniejącej relacji dodaje się w jej zmianie,' '$h' "$h" '$rel' "$rel")
$(T 'pozycja „Datasety”.\n\nWskaż host, z którym nie ma jeszcze relacji.')" 14 "$W"
            continue
        fi
        [ "$h" = "$HOST" ] || { B_ROOT=(); B_EXCL=(); B_CLOSED=""; }
        HOST="$h"; PORT="$p"
        return 0
    done
}

# --- krok 3: diagnoza -------------------------------------------------------
probe() {   # check-source -> zmienne C_*
    C_SSH=0; C_ERR=""; C_NAME=""; C_ZFS=0; C_POOLS=""; C_PKG=0; C_REV=""; C_DIR=""
    # U55 (kampania 2026-10-21): 15 s czarnego okna to sufit ConnectTimeout dla crona
    # (martwy host, nazwa na obcy adres -- U56). Żywy host w sieci odpowiada w 0,2-0,4 s
    # (pve10 -> pve9, zmierzone 2026-10-23); w oknie konsoli wystarczy 5 s, jak przy
    # zmianie adresu w edycji relacji. ServerAlive: host, który zamilkł w trakcie, 6 s.
    SSH_CONNECT_TIMEOUT=5 SSH_SERVER_ALIVE_INTERVAL=3 SSH_SERVER_ALIVE_COUNT=2 \
    "$ZB" check-source "$(hostport)" --json >"$TMPD/check.json" 2>"$TMPD/check.err" || true
    # Wartości ze zdalnego hosta to DANE: python wypisuje je w stałej kolejności,
    # po jednej w linii (bez znaków nowej linii), bash czyta je read -r, nigdy wykonywane.
    "$PY" - "$TMPD/check.json" <<'PYEOF' | tr -d '\r' >"$TMPD/check.vals"
import sys, json, os
_C = json.load(open(os.environ["ZFS_TUI_CAT"], encoding="utf-8")) if os.environ.get("ZFS_TUI_CAT") else {}
def _(s): return _C.get(s, s)
def one(x): return str(x or "").replace("\r", " ").replace("\n", " ")
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {"ssh": {"ok": False, "error": _(u"check-source nie zwrócił JSON-a")}}
ssh = d.get("ssh") or {}; z = d.get("zfs") or {}; p = d.get("package") or {}
for v in (1 if ssh.get("ok") else 0, one(ssh.get("error")), one(d.get("hostname")),
          1 if z.get("ok") else 0,
          one(", ".join(_(u"%s (%s, wolne %s)") % (x.get("name"), x.get("size"), x.get("free")) for x in z.get("pools") or [])),
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
# U56 (kampania 2026-10-21): "pve9" rozwiązało się na pve10 przez publiczny DNS
# (search metropolis.net) na obce adresy w internecie, ssh czekało 10 s i padło bez słowa
# dlaczego. Okno mówi, NA JAKI ADRES poszła nazwa, i ostrzega przed adresem spoza sieci.
resolve_note() {   # -> "" dla IP; "nazwa -> adres [ostrzeżenie]" dla nazwy
    local ip
    case "$HOST" in *[!0-9.]*) ;; *) return 0 ;; esac
    ip="$(getent ahostsv4 "$HOST" 2>/dev/null | awk 'NR == 1 { print $1 }')"
    if [ -z "$ip" ]; then printf '%s' "$(Tv 'nazwa $HOST się nie rozwiązuje (DNS ani /etc/hosts)' '$HOST' "$HOST")"; return 0; fi
    case "$ip" in
        10.*|192.168.*|127.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) printf '%s' "$(Tv 'nazwa $HOST -> $ip' '$HOST' "$HOST" '$ip' "$ip")" ;;
        *) printf '%s' "$(Tv 'nazwa $HOST -> $ip  (ADRES PUBLICZNY, spoza sieci lokalnej! sprawdź DNS / dopisz $HOST do /etc/hosts)' '$HOST' "$HOST" '$ip' "$ip")" ;;
    esac
}
step_diag() {   # 0 = dalej, 1 = wróć do hosta
    local facts rn
    [ "$DIAG_OK_FOR" = "$(hostport)" ] && return 0      # już sprawdzony w tym przebiegu
    rn="$(resolve_note)"
    while :; do
        geom
        info "$(title 3 "$(T 'Co jest na źródle?')")" "$(Tv 'Sprawdzam $(hostport) przez SSH jako root...' '$(hostport)' "$(hostport)")${rn:+\n$rn}\n$(T '(do 5 s)')"
        probe
        if [ "$C_SSH" -ne 1 ]; then
            # Host, który w ogóle nie odpowiada, to nie brak klucza: rada o keyscan
            # i copy-id prowadziłaby admina w złą stronę (przejście na żywo 2026-10-23).
            case "$C_ERR" in
                *"No route to host"*|*"timed out"*|*"Connection refused"*|*"Could not resolve"*|*"Network is unreachable"*)
                    wt --title "$(title 3 "$(Tv '$HOST nie odpowiada' '$HOST' "$HOST")")" --msgbox "${rn:+$rn\n\n}$(Tv 'Pod $HOST (port $PORT) nikt nie odpowiada:\n\n  $C_ERR\n\nSprawdź adres i czy host jest włączony\n(z linii poleceń GUI: ping $HOST), potem wpisz go jeszcze raz.' '$HOST' "$HOST" '$PORT' "$PORT" '$C_ERR' "$C_ERR")" 13 "$W"
                    return 1 ;;
            esac
            wt --title "$(title 3 "$(Tv '$HOST nie wpuszcza' '$HOST' "$HOST")")" --msgbox "${rn:+$rn\n\n}$(Tv 'SSH jako root@$HOST nie działa:\n\n  $C_ERR\n\nNajczęściej brakuje jednego z dwóch -- z TEGO hosta, jako root:\n\n  ssh-keyscan -p $PORT $HOST >> /root/.ssh/known_hosts\n  ssh-copy-id -p $PORT root@$HOST\n\nPo naprawie wróć tutaj.' '$HOST' "$HOST" '$PORT' "$PORT" '$C_ERR' "$C_ERR")" "$(fit 13)" "$W"
            return 1
        fi
        HOSTNAME_R="$C_NAME"
        facts="${rn:+  [i] $rn\n}$(Tv '  [+] SSH     root@$HOST odpowiada, to '\''$C_NAME'\''\n' '$HOST' "$HOST" '$C_NAME' "$C_NAME")"
        if [ "$C_ZFS" -ne 1 ]; then
            wt --title "$(title 3 "$(T 'Brak ZFS')")" --msgbox "${facts}$(Tv '  [-] ZFS     na $HOST nie ma polecenia zfs\n\nBez ZFS nie ma czego kopiować.' '$HOST' "$HOST")" 12 "$W"
            return 1
        fi
        facts="${facts}$(T '  [+] ZFS     pule:') ${C_POOLS:-$(T 'brak')}\n"
        if [ "$C_PKG" -eq 1 ]; then
            wt --title "$(title 3 "$(T 'Źródło gotowe')")" --yes-button "$(T Dalej)" --no-button "$(T Wstecz)" --yesno "${facts}$(Tv '  [+] Pakiet  $C_DIR (rewizja ${C_REV:-?})\n\nWszystko jest. Dalej: lista datasetów.' '$C_DIR' "$C_DIR" '${C_REV:-?}' "${C_REV:-?}")" 13 "$W" || return 1
            DIAG_OK_FOR="$(hostport)"
            return 0
        fi
        wt --title "$(title 3 "$(T 'Brak pakietu na źródle')")" --yes-button "$(T Zainstaluj)" --no-button "$(T Wstecz)" \
           --yesno "${facts}$(Tv '  [-] Pakiet  nie ma go w $C_DIR\n\nBez pakietu źródło nie dołączy do relacji.\n\n'\''Zainstaluj'\'' = prepare-source: git clone pakietu jako root.\nNie rusza crona, nie zakłada relacji ani kluczy.' '$C_DIR' "$C_DIR")" 16 "$W" || return 1
        info "$(Tv 'Instaluję pakiet na $HOST' '$HOST' "$HOST")" "$(Tv 'prepare-source $(hostport) ... (do minuty)' '$(hostport)' "$(hostport)")"
        if "$ZB" prepare-source "$(hostport)" --yes >"$TMPD/prep.log" 2>&1; then
            continue    # sprawdź jeszcze raz i pokaż wynik
        fi
        wt --title "$(T 'Instalacja się nie udała')" --scrolltext --textbox "$TMPD/prep.log" "$H" "$W"
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
B_ROOT=(); B_EXCL=(); B_CLOSED=""      # koszyk: korzeń, pominięte (po jednym w linii)

TREE_FOR=""; DIAG_OK_FOR=""
load_tree() {   # -> T_*[] ; rc!=0 = błąd w $TMPD/ds.err
    [ "$TREE_FOR" = "$(hostport)" ] && [ "${#T_NAME[@]}" -gt 0 ] && return 0
    local -a _lh=(); [ "$MODE" = local ] || _lh=("$(hostport)")
    "$ZB" list-datasets ${_lh[@]+"${_lh[@]}"} --json --own-snapshots >"$TMPD/ds.json" 2>"$TMPD/ds.err" || return 1
    # Na tym hoście: nośniki replik (cała pula wymiennego, katalog stałego) nie są źródłem.
    if [ "$MODE" = local ]; then
        "$ZB" list-replicas --json >"$TMPD/rep.json" 2>/dev/null || echo '{"replicas":[]}' >"$TMPD/rep.json"
        drop_replica_media "$TMPD/ds.json" "$TMPD/rep.json"
    fi
    basket_tree_from_json "$TMPD/ds.json"
    [ "${#T_NAME[@]}" -gt 0 ] || { echo "$(T 'źródło nie ma żadnego datasetu')" >"$TMPD/ds.err"; return 1; }
    TREE_FOR="$(hostport)"
}
step_datasets() {
    geom
    [ "$TREE_FOR" = "$(hostport)" ] || info "$(title 4 "$(T 'Datasety')")" "$(Tv 'Pobieram listę datasetów z $HOST...' '$HOST' "$(hostw)")"
    # load_tree zapamiętuje drzewo po hostport(); dla kopii lokalnej to "" -- tak samo.
    if ! load_tree; then
        wt --title "$(T 'Nie udało się pobrać listy')" --msgbox "$(Tv 'list-datasets $HOST:\n\n' '$HOST' "$HOST")$(tail -3 "$TMPD/ds.err" | tr -d '\r')" 12 "$W"
        return 1
    fi
    basket_step || return $?
    raw_default
}
# Kampania wariantów 2026-10-22 (W2): domyślne "wyślij zaszyfrowane" ustawiało się dopiero w
# oknie Dodatkowe -- kto kliknął Utwórz bez zaglądania tam, dostawał kopię zaszyfrowanego
# źródła ODSZYFROWANĄ na kolektorze (W17 mówi: domyślnie raw). Liczone zaraz po wyborze
# datasetów; wybór admina z okna Dodatkowe (RAW_SEEN) zostaje.
raw_default() {
    if [ "$MODE" != snaponly ] && [ "${NOCOPY:-0}" != 1 ] && basket_encrypted; then
        [ "${RAW_SEEN:-0}" = 1 ] || { RAW=1; RAW_SEEN=1; }
    else
        RAW=0
    fi
}

# --- krok 5: dokąd (tylko backup) ---------------------------------------------
# Lekcja ze starego kreatora: lista pokazywała cudze lądowiska i podgląd jeździł za
# kursorem. Tu kandydatów jest mało i każdy ma POWÓD; reszta to "inna ścieżka".
TARGET=""; PROFILE=""; RNAME=""; ACCT="root"; ACCT_OTHER=""; SRCKEEP=""
EXFAM="__replicate_,vzdump,__migration__"; GRANT=1; MANUAL=0; SRCPROF=""; RAW=0
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
    [ -e "$TMPD/targets.tsv" ] || info "$(title 5 "$(T 'Dokąd?')")" "$(T 'Sprawdzam, dokąd trafiają kopie na tym hoście...')"
    status_tsv
    while IFS=$'\t' read -r n p t _st; do      # 4. pole (stan) MUSI mieć własną zmienną: inaczej wpada do $t
        case "$t" in ''|-) continue ;; esac    # puste (relacja synchro) = "-", nie cel
        case " $seen " in *" $t "*) continue ;; esac
        seen="$seen $t"; cnt=$(awk -F'\t' -v t="$t" '$3==t' "$TMPD/rel.tsv" | grep -c .)
        items+=("$t" "$(Tv '$t   -- używają go już relacje na tym hoście: $cnt' '$cnt' "$cnt" '$t' "$t")")
        [ -n "$first" ] || first="$t"
    done <"$TMPD/rel.tsv"
    [ -e "$TMPD/targets.tsv" ] || "$ZB" list-datasets --json 2>/dev/null | "$PY" -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
# "Przegladaj..." (uwaga 1, 2026-10-08): wszystkie SYSTEMY PLIKOW tego hosta, do osobnego
# pliku -- zvol nie moze byc celem.
fs = open(sys.argv[1], "w", encoding="utf-8", newline="\n")
info = {}
for x in d.get("datasets", []):
    n = x.get("name", "")
    if n and x.get("type", "filesystem") == "filesystem":
        fs.write(n + "\n"); info[n] = [x.get("used"), x.get("avail")]
    if n.count("/") == 1 and n.rsplit("/", 1)[1].lower() in ("backups", "backup", "kopie"): print(n)
# USED/AVAIL dla okna „Dokąd -- przeglądaj” (właściciel 2026-10-29, wariant A)
json.dump(info, open(sys.argv[1] + ".info", "w", encoding="utf-8"))' "$TMPD/fs.all" | tr -d '\r' >"$TMPD/targets.tsv"
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        case " $seen " in *" $t "*) continue ;; esac
        items+=("$t" "$(Tv '$t   -- istnieje na tym hoście, jeszcze nieużywany' '$t' "$t")"); seen="$seen $t"
        [ -n "$first" ] || first="$t"
    done <"$TMPD/targets.tsv"
    # Czysty host (kampania 2026-10-19): żadnego celu do wyboru, a okno mówiło "np. hdd/backups"
    # i kazało go wpisać. Podpowiedź <pula>/backups na każdą pulę -- powstanie przy instalacji.
    if [ -z "$first" ] && [ "$MODE" != local ]; then
        while IFS= read -r t; do
            case "$t" in ''|*/*) continue ;; esac
            t="$t/backups"
            case " $seen " in *" $t "*) continue ;; esac
            items+=("$t" "$(Tv '$t   -- jeszcze nie ma, powstanie przy instalacji' '$t' "$t")"); seen="$seen $t"
            [ -n "$first" ] || first="$t"
        done <"$TMPD/fs.all" 2>/dev/null
    fi
    items+=(__browse__ "$(T 'Przeglądaj…     (wszystkie datasety tego hosta)')")
    items+=(__other__ "$(T 'Wpisz ścieżkę…  (dataset na tym hoście, może jeszcze nie istnieć)')")
    if [ -n "$TARGET" ]; then in_list "$TARGET" "${items[@]}" && first="$TARGET" || first=__other__; fi
    # Kopia lokalna nie ma poziomu hosta: ląduje pod <cel>/<pełna ścieżka źródła>.
    local lv="/$(landing)"; [ "$MODE" = local ] && lv=""
    while :; do
        geom
        wt --title "$(title 5 "$(T 'Dokąd na tym hoście?')")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" --notags --default-item "${first:-__other__}" \
           --menu "$(Tv 'Kopie wylądują pod:  <wybrane>$lv/<dataset źródła>\nnp.  ${first:-hdd/backups}$lv/${B_ROOT[0]}' '$lv' "$lv" '${first:-hdd/backups}' "${first:-hdd/backups}" '${B_ROOT[0]}' "${B_ROOT[0]}")" "$(fit $((${#items[@]} / 2 + 4)))" "$W" "$((${#items[@]} / 2))" \
           "${items[@]}" || return 1
        if [ "$WT_OUT" = __browse__ ]; then
            browse_target && target_ok && return 0
            continue
        fi
        if [ "$WT_OUT" != __other__ ]; then TARGET="$WT_OUT"; target_ok && return 0; continue; fi
        wt --title "$(title 5 "$(T 'Dokąd -- wpisz ścieżkę')")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" \
           --inputbox "$(Tv 'Dataset na TYM hoście, pod którym mają lądować kopie (np. hdd/backups).\nKopie trafią pod:  <to>$lv/<dataset źródła>' '$lv' "$lv")" 11 "$W" "$TARGET" || continue
        t="${WT_OUT// /}"
        case "$t" in ''|/*|*/|*[!A-Za-z0-9._:/-]*) wt --title "$(T 'Zła ścieżka')" --msgbox "$(Tv ''\''$WT_OUT'\'' nie wygląda na nazwę datasetu (pula/nazwa, bez / na początku i końcu).' '$WT_OUT' "$WT_OUT")" 9 "$W"; continue ;; esac
        TARGET="$t"; target_ok && return 0
    done
}
# Kampania 2026-10-22 (pve10): kopia lokalna hdd/archive -> hdd/archive/kopie przeszła cały
# kreator i odmówił dopiero plan czasownika ("overlaps source"). Ta sama reguła tutaj: cel
# równy źródłu albo z nim zagnieżdżony (w którąkolwiek stronę) -- od razu, w tym kroku.
target_ok() {   # 0 = cel pasuje; 1 = okno z powodem, TARGET bez zmian dla następnej próby
    local r
    [ "$MODE" = local ] || return 0
    for r in "${B_ROOT[@]}"; do
        case "$TARGET" in "$r"|"$r"/*) ;; *) case "$r" in "$TARGET"/*) ;; *) continue ;; esac ;; esac
        wt --title "$(title 5 "$(T 'Cel nakłada się na źródło')")" --msgbox "$(Tv '$TARGET i $r: równe albo jedno w drugim.\nKopia nie może lądować w tym, co kopiuje -- wybierz cel poza $r.' '$TARGET' "$TARGET" '$r' "$r")" 9 "$W"
        return 1
    done
    return 0
}
# "Przegladaj..." (uwaga 1): systemy plikow tego hosta. U68 (wlasciciel 2026-10-21: "to musi byc
# jednolite w calym pakiecie"): to samo drzewo co wybor datasetow, w trybie JEDNEJ pozycji
# (wczesniej plaska lista z wcieciami, nazwy obciete). Ukryte sa wnetrza ladowisk innych relacji
# (<cel>/<peer>/...): wybor tam i tak odrzucilby straznik pokrycia kilka krokow dalej.
# 0 = TARGET ustawiony, 1 = wstecz do listy.
browse_target() {
    local n t p hid=0 skip _rn _st
    [ -s "$TMPD/fs.all" ] || { wt --title "$(T 'Brak listy')" --msgbox "$(T 'Nie udało się odczytać datasetów tego hosta (list-datasets).')" 8 "$W"; return 1; }
    : >"$TMPD/fs.pick"
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        skip=0
        while IFS=$'\t' read -r _rn p t _st; do
            case "$t" in ''|-) continue ;; esac
            case "$n" in "$t/$p"|"$t/$p"/*) skip=1; break ;; esac
        done <"$TMPD/rel.tsv"
        [ "$skip" -eq 1 ] && { hid=$((hid + 1)); continue; }
        printf '%s\n' "$n" >>"$TMPD/fs.pick"
    done <"$TMPD/fs.all"
    [ -s "$TMPD/fs.pick" ] || { wt --title "$(T 'Brak datasetów')" --msgbox "$(T 'Na tym hoście nie ma datasetu, pod którym mogłyby lądować kopie.')" 8 "$W"; return 1; }
    local lv="/$(landing)"; [ "$MODE" = local ] && lv=""
    local legend="$(Tv ' Kopie trafią pod:  <wybrany>$lv/<dataset źródła>' '$lv' "$lv")"
    [ "$hid" -gt 0 ] && legend="$legend   $(Tv '(ukryto $hid kopii innych relacji)' '$hid' "$hid")"
    # Dolna linia: PRAWDZIWA ścieżka dla wiersza pod kursorem (wariant A, 2026-10-29).
    local curl="$(Tv 'Kopie trafią pod:  {cur}$lv/<dataset źródła>' '$lv' "$lv")"
    [ "$hid" -gt 0 ] && curl="$curl   $(Tv '(ukryto $hid kopii innych relacji)' '$hid' "$hid")"
    "$PY" - "$TMPD/fs.pick" "$TMPD/tree-spec.json" "$(title 5 "$(T 'Dokąd -- przeglądaj')")" "$legend" "$TARGET" "$curl" "$TMPD/fs.all.info" <<'PYEOF' || return 1
import sys, json, os
names = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
try:
    info = json.load(open(sys.argv[7], encoding="utf-8")) if os.path.exists(sys.argv[7]) else {}
except ValueError:
    info = {}
ds = []
for n in names:
    if n in info:
        ds.append({"name": n, "type": "filesystem", "used": info[n][0], "avail": info[n][1]})
    else:
        ds.append({"name": n, "type": "filesystem", "used": None})
json.dump({"title": sys.argv[3], "single": True, "selectable": names, "legend": sys.argv[4],
           "fit": True, "cursor_line": sys.argv[6],
           "roots": [sys.argv[5]] if sys.argv[5] in names else [],
           "datasets": ds},
          open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
PYEOF
    ${ZFS_TREE:-$PY $HERE/tui/tree.py} --spec "$TMPD/tree-spec.json" --out "$TMPD/tree-out.json" || return 1
    n="$("$PY" -c 'import json,sys; r=json.load(open(sys.argv[1], encoding="utf-8")).get("roots") or [""]; print(r[0])' "$TMPD/tree-out.json" | tr -d '\r')"
    [ -n "$n" ] || return 1
    TARGET="$n"
    return 0
}
in_list() { local x="$1" y; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

# --- krok 6: szablon ----------------------------------------------------------
load_profiles() {   # -> $TMPD/prof.tsv: nazwa <TAB> zdanie ; słowa z tui/zfs-tui.py (jedno źródło słów)
    [ -s "$TMPD/prof.tsv" ] && return 0
    # --no-render (W1, 2026-10-12): z renderowaniem list-profiles trwal na pve9b 16,6 s,
    # bez niego 1,8 s; valid/families nie sa potrzebne do wyboru (sprawdza je czasownik).
    "$ZB" list-profiles --json --no-render >"$TMPD/prof.json" 2>"$TMPD/prof.err" || return 1
    "$PY" - "$TMPD/prof.json" "$HERE/tui/zfs-tui.py" <<'PYEOF' | tr -d '\r' >"$TMPD/prof.tsv"
import sys, json, importlib.util
spec = importlib.util.spec_from_file_location("zfs_tui", sys.argv[2])
tui = importlib.util.module_from_spec(spec); spec.loader.exec_module(tui)
tui.load_lang(tui.ui_lang())     # słowa w języku okna (ZFS_TUI_LANG z wt-lib.sh)
d = json.load(open(sys.argv[1], encoding="utf-8"))
def short_cadence(p):
    # "co godzinę (:01), co dobę 01:11, co tydzień nd 02:21" -> "co godzinę, dobę, tydzień"
    # (po angielsku "hourly (:01), daily 01:11" -> "hourly, daily": bez wspólnego "co")
    pl = tui._(u"co dobę %s").split()[0] == "co"
    out = []
    for t in p.get("tiers", []):
        if t.get("send_schedule"):
            w = tui.cron_words(t["send_schedule"]).split()
            if pl:
                out.append(w[1] if len(w) > 1 and w[0] == "co" else " ".join(w[:2]))
            else:
                out.append(" ".join(w[:3]) if w and w[0] == "every" else (w[0] if w else "?"))
    return (("co " if pl else "") + ", ".join(out)) if out else "?"
rows = []
# Szczeble retencji do okna "Jak długo trzymać w źródle" (uwaga 19): profil, szczebel,
# rodzina, ile trzyma. Tylko szczeble z keep -- tworzące (send_schedule bez keep) nie.
# K1 (2026-10-07): także szczeble WIEKU (retain = -h24, -d7 ...): okno znało tylko keep
# i dla szablonów -age mówiło "nie ma szczebli z liczbą do zmiany". 5. kolumna = tryb:
# "keep" albo "retain:<litera jednostki>".
import re
with open(sys.argv[1] + ".tiers", "w", encoding="utf-8", newline="\n") as tf:   # newline: na Windowsie tryb tekstowy pisze CRLF
    for p in d.get("profiles", []):
        for t in p.get("tiers", []):
            if t.get("keep"):
                tf.write("%s\t%s\t%s\t%s\tkeep\n" % (p.get("name", "-"), t.get("name", "-"), t.get("pattern") or "-", t["keep"]))
            elif t.get("retain"):
                m = re.match(r"^-([hdwmy])([0-9]+)$", t["retain"])
                if m:
                    tf.write("%s\t%s\t%s\t%s\tretain:%s\n" % (p.get("name", "-"), t.get("name", "-"), t.get("pattern") or "-", m.group(2), m.group(1)))
for p in d.get("profiles", []):
    if "-src-" in (p.get("name") or ""):
        continue    # profil POCHODNY retencji źródła -- nie jest szablonem do wyboru w kroku 6
    # UKRYTY szablon relacji (relacja-<NAZWA>, P4): w pliku jest (zamrażanie, kształt
    # dla kroku 8), na liście kroku 6 -- nie (7. kolumna = 1).
    w = tui.profile_words(p)
    mech = {"flat": tui._(u"N najnowszych"), "gfs": "GFS", "age": tui._(u"wg wieku")}.get(p.get("mechanism", ""), p.get("mechanism") or "?")
    # Wiersz listy: co trzyma + mechanizm (to odróżnia d30h24 / -age / -gfs). Rytm wynika
    # z najdrobniejszego szczebla; pełne zdanie z rytmem idzie do podsumowania (3. pole).
    frozen = [t for t in p.get("tiers", []) if t.get("send_schedule") and t.get("quiesce")]
    rows.append((p.get("name", "?"), "%s  [%s]" % (w["retention"], mech), short_cadence(p), w["quiesce"], 1 if frozen else 0,
                 "ladder" if (p.get("shape") == "one-family" and p.get("mechanism") == "gfs") else "flat",
                 1 if p.get("hidden") else 0))
rows.sort(key=lambda r: (r[0] != "default", r[0].lower()))     # default na górze
for n, t, c, q, f, sh, hd in rows:
    print("%s\t%s\t%s\t%s\t%d\t%s\t%d" % (n or "-", t or "-", c or "-", q or "-", f, sh or "-", hd))
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
# [zamraża]/[drabina]), a niedopasowanie sprawdza się PO wyborze konta, w kroku 8,
# dla TEGO konta.
#
# K5 (2026-10-07): znacznik stał przy złej stronie i mówił nieprawdę. "[płaski]"
# dostawał każdy szablon poza jedną drabiną -- także -gfs (cztery rodziny, każda
# na własnej drabinie GFS), a opis okna mówił "jedna rodzina, N najnowszych, bez
# drabiny". Podział jest dobry (retencja w szczeblach -- N najnowszych, wg wieku
# albo GFS per rodzina -- kontra JEDNA drabina dla jednej rodziny w osobnej
# sekcji prune), więc zostaje; znacznik idzie na tę stronę, która ma
# ograniczenie: [drabina] (od X27 zadnego szablonu fabrycznego w tym ksztalcie).
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
# SYNCHRO Z ŁAŃCUCHA (U8, 2026-10-06). Gdy korzeń z koszyka ma już WŁASNE migawki
# (spoza vzdump/__replicate_/__migration__), źródło jest ogniwem łańcucha: ktoś inny
# je robi i przycina. Synchro ma wtedy odbierać to, co jest -- każdą rodzinę --
# i nic na źródle nie tworzyć: to jest passive-flat. Bez własnych migawek szablon
# bezprefiksowy stemplowałby gołe znaczniki czasu, więc wtedy NIE jest polecany.
# A>B>C (właściciel 2026-10-20): to samo dla BACKUPU -- c pobiera z b jego magazyn kopii
# (hdd/backups, który b dostaje z a), albo drugi kolektor za VPN dubluje pierwszy. Własne
# migawki c na kopiach b zepsułyby b przyjmowanie kopii z a. Silnik tego sam nie rozstrzyga
# (nie odróżni łańcucha od resztek tej samej relacji po eksport -> usuń -> import), więc
# kreator mówi to wprost i poleca passive-flat; decyduje admin.
sync_from_chain() {   # -> 0, gdy lustro/backup/kopia lokalna i któryś korzeń koszyka ma już migawki naszej rodziny
    # Kopia lokalna (2026-10-24, Metropolis pve2): kopiuje z repliki pvesr, której migawki robi
    # węzeł gościa -- to też łańcuch, tylko po tej samej stronie.
    [ "$MODE" = sync ] || [ "$MODE" = backup ] || is_local_copy || return 1
    local r n c f e
    for r in ${B_ROOT[@]+"${B_ROOT[@]}"}; do
        while IFS=$'\t' read -r n c f e; do
            [ "$n" = "$r" ] || continue
            # Backup i kopia lokalna: tylko NASZA rodzina (automated_*) -- ręczna migawka to nie łańcuch.
            { [ "$MODE" = backup ] || is_local_copy; } && c="${f:-0}"
            case "$c" in ''|*[!0-9]*) c=0 ;; esac
            [ "$c" -gt 0 ] && return 0
        done <"$TMPD/own.tsv" 2>/dev/null
    done
    return 1
}
REC_PROFILE=passive-flat
is_local_copy() { [ "$MODE" = local ] && [ "$NOCOPY" -eq 0 ]; }
# Kopia lokalna, która przyjmuje cudze migawki (--passive): nic na źródle nie tworzy, więc nie
# zamraża gości i nie ma retencji źródła (kampania 1.0, 2026-10-25).
is_passive_copy() { is_local_copy && sync_from_chain && [ "$(chain_ans)" = chain ]; }
# KTO ROBI TE MIGAWKI? (właściciel 2026-10-24, wariant A). Silnik nie odróżni żywego łańcucha
# od resztek starej relacji -- zmierzone na pve10<>pve11: lustro założone od nowa na migawkach
# swojej poprzedniczki wyszło PASYWNE i przestało robić migawki. Pyta więc kreator, a admin
# odpowiada na podstawie faktów (ile i jak stara najnowsza); "resztki" = --own-snapshots.
CHAIN_ANS=""; CHAIN_FOR=""
chain_ans() {   # -> chain | own | "" (brak odpowiedzi dla obecnego koszyka)
    # IFS ze spacją: CHAIN_FOR zapisano "${B_ROOT[*]}" przy zwykłym IFS, a build_argv woła tę
    # funkcję z `local IFS=,` -- przy dwóch korzeniach "a,b" != "a b" i odpowiedź ginęła
    # (kampania pve10, 2026-10-29: "robię własne" w podsumowaniu, bez --own-snapshots w komendzie).
    local IFS=' '
    [ -n "$CHAIN_ANS" ] && [ "$CHAIN_FOR" = "${B_ROOT[*]}" ] && echo "$CHAIN_ANS"
}
chain_facts() {   # -> wiersze "  dataset: N migawek automated_*, najnowsza ... (... temu)"
    local r n c f e now ago
    now=$(date +%s)
    for r in ${B_ROOT[@]+"${B_ROOT[@]}"}; do
        while IFS=$'\t' read -r n c f e; do
            [ "$n" = "$r" ] || continue
            case "$f" in ''|*[!0-9]*) f=0 ;; esac
            [ "$f" -gt 0 ] || continue
            case "$e" in ''|*[!0-9]*) e=0 ;; esac
            if [ "$e" -gt 0 ]; then
                ago=$(( (now - e) / 60 ))
                if [ "$ago" -lt 120 ]; then ago="$ago min"
                elif [ "$ago" -lt 2880 ]; then ago="$((ago / 60)) $(T 'godz.')"
                else ago="$((ago / 1440)) $(T dni)"; fi
                echo "$(Tv '  $n: migawki automated_*: $f, najnowsza $when ($ago temu)' '$n' "$n" '$f' "$f" '$when' "$(date -d "@$e" '+%Y-%m-%d %H:%M')" '$ago' "$ago")"
            else
                echo "$(Tv '  $n: migawki automated_*: $f' '$n' "$n" '$f' "$f")"
            fi
        done <"$TMPD/own.tsv" 2>/dev/null
    done
}
step_chain() {   # 0 = odpowiedź zapisana, 1 = wstecz
    local def="${CHAIN_ANS:-chain}" facts
    facts="$(chain_facts)"
    geom
    wt --title "$(title 5 "$(T 'Migawki naszej rodziny już są na źródle')")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" --notags --default-item "$def" \
       --menu "$(Tv 'Na $HOST są już migawki naszej rodziny:\n$facts\n\nKto je dziś robi? Najnowsza sprzed godziny-dwóch zwykle znaczy, że ktoś je robi.\nŁańcuch: ta relacja je PRZYJMUJE i sama niczego tam nie tworzy ani nie kasuje.\nResztki: ta relacja robi WŁASNE; stare wejdą do jej retencji i z czasem znikną.' '$HOST' "$(T 'źródle') $( [ -n "$HOST" ] && hostw || hostname -s)" '$facts' "$facts")" "$H" "$W" 2 \
       chain "$(T 'Tworzy je inny kolektor, lub inna relacja albo stary cron -- łańcuch, przyjmuję')" \
       own "$(T 'Nikt -- to resztki starej relacji, robię własne')" || return 1
    CHAIN_ANS="$WT_OUT"; CHAIN_FOR="${B_ROOT[*]}"
    # "Resztki" z wybranym wcześniej passive-flat nie robiłyby niczego -- szablon do wyboru od nowa.
    [ "$CHAIN_ANS" = own ] && [ "$PROFILE" = "$REC_PROFILE" ] && { PROFILE=""; SRCPROF=""; VIS="${VIS/ profile / }"; }
    return 0
}
# Domyślna nazwa relacji (krok 7 proponuje to samo) -- od niej nazwa szkicu "Ręcznie".
rname_default() {
    if [ -n "$RNAME" ]; then echo "$RNAME"
    elif [ "$NOCOPY" -eq 1 ]; then echo "migawki-$(printf '%s' "${B_ROOT[0]:-zrodlo}" | tr '/' '-')"
    elif [ "$MODE" = local ]; then echo "$(T lokalna)-$(printf '%s' "${B_ROOT[0]:-kopia}" | tr '/' '-')"
    else echo "${HOSTNAME_R:-$HOST}"; fi
}
# RĘCZNIE (P4, właściciel 2026-10-09: relacja "z szablonu i ręcznie"): ta sama tabela co
# szablon na F5 (sposób, wszystkie szczeble, liczby, zamrażanie); wynik = ukryty szablon
# relacja-<NAZWA> (save-profile --hidden), F5 go nie pokazuje. 0 = zapisany, 1 = wstecz.
step_manual() {
    local base out hn
    base="$PROFILE"
    case "$base" in ''|relacja-*) base="" ;; esac
    awk -F'\t' -v n="$base" '$1==n && $7!=1 {f=1} END{exit !f}' "$TMPD/prof.tsv" || base=d7h24
    awk -F'\t' -v n="$base" '$1==n {f=1} END{exit !f}' "$TMPD/prof.tsv" || base="$(awk -F'\t' '$7!=1{print $1; exit}' "$TMPD/prof.tsv")"
    hn="relacja-$(rname_default)"
    clear 2>/dev/null
    ZFS_BACKUP="$ZB" bash "$HERE/tui/template.sh" relation "$base" "$TMPD/margs" "$(title 6 "$(T 'Retencja: W CELU KOPII –') $(hostname -s 2>/dev/null || hostname)")" || return 1
    local -a margs=(); mapfile -t margs <"$TMPD/margs"
    info "$(title 6 "$(T 'Ręcznie')")" "$(T 'Zapisuję ustawienia relacji...')"
    out=$("$ZB" save-profile "--from=$base" "--as=$hn" --hidden --force ${margs[@]+"${margs[@]}"} "--description=$(T 'Własne ustawienia relacji (kreator)')" 2>&1) \
        || { wt --title "$(T 'Czasownik odmówił -- nic nie zapisano')" --msgbox "$(printf '%s' "$out" | grep -E 'FATAL' | tail -1 | sed 's/^FATAL: //' | fold -s -w $((W - 6)))" 14 "$W"; return 1; }
    [ -n "$MANUAL_P" ] && [ "$MANUAL_P" != "$hn" ] && "$ZB" delete-profile "$MANUAL_P" --yes >/dev/null 2>&1
    MANUAL_P="$hn"; PROFILE="$hn"
    rm -f "$TMPD/prof.tsv"; load_profiles
    return 0
}
step_profile() {
    local items=() n w c q f sh hd def label chain=0 lead="" has_ladder=0
    geom
    [ -s "$TMPD/prof.tsv" ] || info "$(title 6 "$(T 'Szablon')")" "$(T 'Czytam szablony retencji...')"
    if ! load_profiles; then
        wt --title "$(title 6 "$(T 'Szablon -- lista niedostępna')")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" \
           --inputbox "$(Tv 'list-profiles nie odpowiedział ($(tail -1 "$TMPD/prof.err" 2>/dev/null)).\nWpisz nazwę szablonu ręcznie (domyślny: default).' '$(tail -1 "$TMPD/prof.err" 2>/dev/null)' "$(tail -1 "$TMPD/prof.err" 2>/dev/null)")" 11 "$W" "${PROFILE:-default}" || return 1
        PROFILE="${WT_OUT// /}"; [ -n "$PROFILE" ] || PROFILE=default; FREEZE=1; return 0
    fi
    items=(__manual__ "$(clip_label "$(printf '%-15s %s' "$(T 'Ręcznie…')" "$(T 'tabela szczebli: sposób, szczeble, liczby, zamrażanie')")" $((W - 10)))")
    # passive-flat polecany tylko przy odpowiedzi "łańcuch"; przy "resztki" relacja robi własne.
    sync_from_chain && [ "$(chain_ans)" != own ] && ! is_local_copy && chain=1
    while IFS=$'\t' read -r n w c q f sh hd; do
        [ -n "$n" ] || continue
        # Ukryte (od 2026-10-22 także fabryczne spoza piątki) nie idą na listę -- z jednym
        # wyjątkiem: szablon polecany przy łańcuchu (passive-flat), bez którego zalecenie
        # wskazywałoby coś, czego nie da się wybrać.
        [ "${hd:-0}" = 1 ] && ! { [ "$chain" -eq 1 ] && [ "$n" = "$REC_PROFILE" ]; } && continue
        # ZNACZNIKI ZARAZ ZA NAZWĄ, opis retencji na końcu: przy przycięciu
        # wiersza do okna (U5) ginie koniec opisu, nigdy [zamraża]/[drabina]/[polecany]
        # -- to one rozstrzygają wybór (kroki 8 i 9).
        local marks="" mech="" kp
        kp="$(T 'trzyma %s')"; kp="${kp%'%s'}"     # "trzyma " / "keeps "
        [ "$chain" -eq 1 ] && [ "$n" = "$REC_PROFILE" ] && marks="${marks}$(T '[polecany]') "
        [ "$f" = 1 ] && marks="${marks}$(T '[zamraża]') "
        [ "$sh" = ladder ] && { marks="${marks}$(T '[drabina]') "; has_ladder=1; }
        # Kampania 3 (2026-10-22, 80x24): sposób liczenia ([N najnowszych]/[GFS]/[wg wieku])
        # stał na KOŃCU opisu i ginął przy przycięciu -- full i m12w4d7h24-gfs wyglądały
        # tak samo ("... 12 mies…"). Idzie zaraz za nazwą, jak pozostałe znaczniki.
        case "$w" in *"  ["*"]") mech="[${w##*  [}"; w="${w%  \[*}" ;; esac
        # Pytanie okna mówi już "Jak długo trzymać" -- na liście same liczby (przy 100 kolumnach
        # `full` kończył się "5…" zamiast "5 lat"; kampania 3, 2026-10-23).
        w="${w#"$kp"}"
        label="$(printf '%-15s %s%s%s' "$n" "${mech:+$mech }" "$marks" "$w")"
        # Ta sama ramka co w kroku 9 (U5): w 80 kolumnach wiersze szablonów z
        # [zamraża] [drabina] były szersze niż okno i ucinały jej prawy bok.
        items+=("$n" "$(clip_label "$label" $((W - 10)))")
    done <"$TMPD/prof.tsv"
    # Szablon domyślny nowej relacji z ustawień hosta ([new_relation] template, F10).
    def="$("$ZB" settings get new_relation.template 2>/dev/null)"
    { [ -n "$def" ] && in_list "$def" "${items[@]}"; } || def=default
    if [ "$chain" -eq 1 ] && in_list "$REC_PROFILE" "${items[@]}"; then
        def="$REC_PROFILE"
        lead="$(Tv 'Źródło ma już migawki naszej rodziny (łańcuch albo resztki starej relacji): polecany\n$REC_PROFILE -- odbiera to, co jest, i niczego tam nie tworzy.\n\n' '$REC_PROFILE' "$REC_PROFILE")"
    fi
    local tl=6; [ -n "$lead" ] && tl=9    # trzy linie wstępu więcej nad listą
    in_list "$PROFILE" "${items[@]}" && def="$PROFILE"
    [ -n "$MANUAL_P" ] && [ "$PROFILE" = "$MANUAL_P" ] && def=__manual__
    in_list "$def" "${items[@]}" || def="${items[2]}"
    geom
    local q6="$(T 'Jak długo trzymać w celu (na tym hoście)?')"
    # U32: lustro trzyma to samo co źródło -- szablon mówi, kiedy źródło robi migawki i ile trzyma.
    [ "$MODE" = sync ] && q6="$(T 'Jak długo trzymać migawki (u źródła; lustro trzyma to samo)?')"
    [ "$NOCOPY" -eq 1 ] && q6="$(T 'Jak długo trzymać migawki?')"
    if [ "$MODE" = snaponly ]; then
        # Szablon jest tu RETENCJĄ ŹRÓDŁA (celu nie ma). Drabina GFS na szczeblu
        # (np. default) jest odrzucana przy aktywacji -- polecany szablon liczony.
        q6="$(T 'Jak długo trzymać migawki na źródle?')"
        lead="${lead}$(T 'Migawki zdalne: szablon z drabiną GFS na szczeblu zostanie odrzucony przy aktywacji -- wybierz szablon liczony, np. d7h24.\n\n')"
        tl=$((tl + 3))
        [ "$def" = default ] && in_list d7h24 "${items[@]}" && def=d7h24
    fi
    wt --title "$(title 6 "$q6")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" --notags --default-item "$def" \
       --menu "${lead}$(T 'Gotowy szablon albo "Ręcznie" (tabela szczebli). [zamraża] = przed migawkami dobowymi i rzadszymi goście są zamrażani (zgoda w Zaawansowanych podsumowania).')$([ "$has_ladder" -eq 1 ] && printf '%s' "$(T ' [drabina] = jedna rodzina migawek liczona drabiną GFS (sprawdzane przy Utwórz).')") $(T 'Zmienisz później.')" "$H" "$W" "$(lhfit $((${#items[@]} / 2)) "$tl")" \
       "${items[@]}" || return 1
    if [ "$WT_OUT" = __manual__ ]; then
        step_manual || { step_profile; return $?; }
    else
        drop_manual_draft
        PROFILE="$WT_OUT"
    fi
    f="$(awk -F'\t' -v n="$PROFILE" '$1==n{print $5}' "$TMPD/prof.tsv")"
    case "$f" in 1) FREEZE=1 ;; *) FREEZE=0 ;; esac
    return 0
}

# --- krok 7: nazwa ------------------------------------------------------------
# Relacja z drugim hostem NAZYWA SIĘ JAK TEN HOST (właściciel 2026-10-29: „nazwa relacji
# miała odpowiadać hostowi po drugiej stronie i to się rozjechało” -- pole było do edycji
# i na labie powstały ab, cb, bc). Nazwa = ta, którą host zgłosił przy diagnozie; wolne
# pole zostaje tylko relacjom bez drugiego hosta (kopia lokalna) i gdy tamta nazwa jest
# zajęta albo niepoprawna.
host_rname() {   # -> nazwa relacji z drugim hostem albo nic
    [ "$MODE" != local ] && [ -n "$HOSTNAME_R" ] || return 0
    local n="${HOSTNAME_R%%.*}"
    case "$n" in ''|[-.]*|*[!A-Za-z0-9._-]*) return 0 ;; esac
    [ -s "$TMPD/rel.tsv" ] || status_tsv
    awk -F'	' -v n="$n" '$1==n{f=1} END{exit !f}' "$TMPD/rel.tsv" && return 0
    printf '%s' "$n"
}
step_name() {
    local n
    n="$(host_rname)"
    if [ -n "$n" ]; then
        RNAME="$n"
        # jedno okno z faktem zamiast pola do wpisania (krok zostaje -- numeracja kroków i
        # droga Wstecz się nie zmieniają)
        wt --title "$(title 7 "$(T 'Nazwa relacji')")" --msgbox "$(Tv 'Relacja nazywa się jak host po drugiej stronie: $n.

Relacja to para hostów -- jedna nazwa na F3, w cronie i w mailach.' '$n' "$n")" 10 "$W"
        return 0
    fi
    if [ -z "$RNAME" ] && [ "$MODE" = local ]; then
        RNAME="$(rname_default)"
    fi
    [ -n "$RNAME" ] || RNAME="${HOSTNAME_R:-$HOST}"
    while :; do
        geom
        wt --title "$(title 7 "$(T 'Nazwa relacji')")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" \
           --inputbox "$(T 'Pod tą nazwą relacja będzie widoczna na F3, w cronie i w mailach.\nLitery, cyfry, kropka, myślnik, podkreślenie; na początku nie kropka ani myślnik.')" 11 "$W" "$RNAME" || return 1
        n="${WT_OUT// /}"
        case "$n" in ''|[-.]*|*[!A-Za-z0-9._-]*) wt --title "$(T 'Zła nazwa')" --msgbox "$(Tv ''\''$WT_OUT'\'' -- dozwolone: litery, cyfry, kropka, myślnik, podkreślenie; na początku nie kropka ani myślnik.' '$WT_OUT' "$WT_OUT")" 8 "$W"; continue ;; esac
        [ -s "$TMPD/rel.tsv" ] || status_tsv
        if awk -F'\t' -v n="$n" '$1==n{f=1} END{exit !f}' "$TMPD/rel.tsv"; then
            wt --title "$(T 'Nazwa zajęta')" --msgbox "$(Tv 'Relacja o nazwie '\''$n'\'' już jest na tym hoście. Podaj inną.' '$n' "$n")" 8 "$W"; RNAME="$n"; continue
        fi
        # Nazwa USUNIĘTEJ relacji jest wolna: add-client archiwizuje jej stary rekord
        # (<nazwa>.conf.removed-<czas>) i plan to mówi. Dawniej kreator kazał ją
        # najpierw „zwolnić” przez delete-relation -- zbędny krok, który na pve9b nie
        # przechodził (uwaga 11, 2026-10-08).
        RNAME="$n"
        # Szkic "Ręcznie" nazywa się jak relacja: relacja-<NAZWA>.
        if [ -n "$MANUAL_P" ] && [ "$MANUAL_P" != "relacja-$RNAME" ]; then
            if "$ZB" save-profile "--from=$MANUAL_P" "--as=relacja-$RNAME" --hidden --force "--description=$(Tv 'Własne ustawienia relacji $RNAME' '$RNAME' "$RNAME")" >/dev/null 2>"$TMPD/mv.err"; then
                "$ZB" delete-profile "$MANUAL_P" --yes >/dev/null 2>&1
                MANUAL_P="relacja-$RNAME"; PROFILE="$MANUAL_P"; rm -f "$TMPD/prof.tsv"; load_profiles
            else
                wt --title "$(T 'Nie udało się przenieść ustawień')" --msgbox "$(tail -3 "$TMPD/mv.err")" 12 "$W"; continue
            fi
        fi
        return 0
    done
}

# --- krok 8: konto ------------------------------------------------------------
step_account() {
    local a acct_name shape cur
    while :; do
        case "$ACCT" in zfsbackup|other) cur="$ACCT" ;; *) cur=root ;; esac
        geom
        wt --title "$(title 8 "$(T 'Na jakim koncie mają chodzić zadania?')")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" --notags --default-item "$cur" \
           --menu "$(T 'Konto na TYM hoście, na którym cron będzie uruchamiał zadania tej relacji.\nKonto delegowane nie jest rootem: dostaje tylko prawa zfs do celu.')" "$(fit 8)" "$W" 3 \
           root      "$(T 'root  -- bez izolacji (tak działa większość floty dziś)')" \
           zfsbackup "$(T 'zfsbackup  -- konto delegowane (utworzone, jeśli go nie ma)')" \
           other     "$(T 'inne konto…  (podasz nazwę)')" || return 1
        [ -n "$WT_OUT" ] && ACCT="$WT_OUT"
        if [ "$ACCT" = other ]; then
            while :; do
                wt --title "$(title 8 "$(T 'Nazwa konta')")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" --inputbox "$(T 'Nazwa konta na tym hoście (zostanie utworzone, jeśli go nie ma).')" 9 "$W" "$ACCT_OTHER" || { ACCT=root; return 1; }
                a="${WT_OUT// /}"
                case "$a" in ''|root|*[!a-z0-9_-]*) wt --title "$(T 'Zła nazwa konta')" --msgbox "$(T 'Małe litery, cyfry, myślnik, podkreślenie; nie '\''root'\''.')" 8 "$W"; continue ;; esac
                ACCT_OTHER="$a"; break
            done
        fi
        acct_name="$(account_name)"
        shape="$(awk -F'\t' -v n="$PROFILE" '$1==n{print $6}' "$TMPD/prof.tsv" 2>/dev/null)"
        if account_is_flat "$acct_name" && [ "$shape" != flat ]; then
            wt --title "$(T 'Szablon nie pasuje do konta')" --msgbox "$(Tv 'Na koncie ${acct_name:-root} już działają relacje z retencją W SZCZEBLACH\n(każdy szczebel przycina się sam) -- to jest jego config. Szablonu [drabina]\n(jedna drabina GFS w osobnej sekcji) nie da się do niego dodać, czasownik\nby tego odmówił.\n\nWybierz inne konto, albo Wstecz do kroku 6 po szablon bez znacznika [drabina].' '${acct_name:-root}' "${acct_name:-root}")" "$(fit 8)" "$W"
            continue
        fi
        return 0
    done
}
# ZASZYFROWANE ŹRÓDŁO (W17, właściciel 2026-10-11): czy coś w koszyku (miejsce albo coś pod
# nim) ma encryption inne niż off. Wtedy domyślnie wysyłka zaszyfrowana (-w): kopia leży
# w celu zaszyfrowana, a kolektor nie potrzebuje klucza. list-datasets podaje "encryption".
basket_encrypted() {   # 0 = coś w koszyku jest zaszyfrowane
    [ -s "$TMPD/ds.json" ] || return 1
    "$PY" - "$TMPD/ds.json" "${B_ROOT[@]}" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
roots = sys.argv[2:]
for x in d.get("datasets") or []:
    n, e = x.get("name") or "", (x.get("encryption") or "-")
    if e not in ("off", "-", "") and any(n == r or n.startswith(r + "/") for r in roots):
        sys.exit(0)
sys.exit(1)
PYEOF
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
    # potrzebują wartości (pomijane prefiksy, inna retencja u źródła), pytają o nią
    # w NASTĘPNYM oknie -- każde z nich ma już normalne Dalej/Wstecz.
    # POMIJANE PREFIKSY nie są pozycją checklisty (W3, 2026-10-11): po checkliście ZAWSZE
    # otwiera się prefix_editor (list_editor). Wstecz z niego wraca do checklisty, a w
    # trybie local, gdzie checklisty nie ma, jest krokiem wstecz z całego kroku 9.
    local items=() on_grant=OFF on_q=OFF on_man=OFF
    while :; do
        geom
        [ "$GRANT" -eq 1 ] && on_grant=ON || on_grant=OFF
        [ "$GQUIESCE" -eq 1 ] && on_q=ON || on_q=OFF
        [ "$MANUAL" -eq 1 ] && on_man=ON || on_man=OFF
        [ "$RECURSION" = atomic ] && SRCPROF=""
        # KRÓTKIE ETYKIETY, objaśnienia nad listą (U5, 2026-10-06): etykieta
        # dłuższa niż okno rozjeżdżała ramkę checklisty (zmierzone w kroku 9 na
        # 80 kolumnach). Każda i tak przechodzi przez clip_label -- przy wąskim
        # terminalu ucięta z '…', nigdy przez ramkę.
        items=()
        [ "$MODE" = local ] || items=(grant "$(T 'Prawa na źródle nadaj stąd (SSH jako root)')" "$on_grant")
        if [ "$MODE" != local ] && [ "$FREEZE" -eq 1 ] && [ "$GRANT" -eq 1 ]; then
            items+=(quies "$(T 'Nadaj też zgodę na zamrażanie gości')" "$on_q")
        fi
        [ "$MODE" = local ] || items+=(man "$(T 'Parowanie ręczne: paczka do przeniesienia')" "$on_man")
        local enc=0 on_raw=OFF
        if [ "$MODE" != snaponly ] && basket_encrypted; then
            enc=1
            [ "${RAW_SEEN:-0}" = 1 ] || { RAW=1; RAW_SEEN=1; }
            [ "$RAW" -eq 1 ] && on_raw=ON
            items+=(raw "$(T 'Wyślij zaszyfrowane (źródło jest zaszyfrowane)')" "$on_raw")
        else
            RAW=0
        fi
        if [ "${#items[@]}" -gt 0 ]; then
            local _i
            for ((_i=1; _i<${#items[@]}; _i+=3)); do items[_i]="$(clip_label "${items[_i]}" $((W - 14)))"; done
            local _xh="$(T 'Domyślne wystarczą w zwykłej relacji.\n\nNadaj prawa stąd: bez tego instalacja się zatrzyma i poda polecenie do wpisania na źródle.\nZamrażanie: bez zgody migawki dobowe i rzadsze zostaną oznaczone '\''_crash_'\'' (bez zamrożenia gości).\nParowanie ręczne: gdy ten host nie może się połączyć ze źródłem przez SSH.')"
            [ "$enc" -eq 1 ] && _xh="$_xh\n$(T 'Zaszyfrowane: kopia leży w celu zaszyfrowana, ten host nie potrzebuje klucza.\n  Zmiana po pierwszej kopii = nowa kopia od zera.')"
            wt --title "$(title 9 "$(T 'Ustawienia dodatkowe   [Spacja przełącza]')")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" --notags --separate-output \
               --checklist "$_xh" "$(fit $((${#items[@]} / 3 + 11)))" "$W" "$((${#items[@]} / 3))" \
               "${items[@]}" || return 1
            GRANT=0; GQUIESCE=0; MANUAL=0; [ "$enc" -eq 1 ] && RAW=0
            local x
            while IFS= read -r x; do
                case "$x" in
                    grant) GRANT=1 ;;
                    quies) GQUIESCE=1 ;;
                    man)   MANUAL=1 ;;
                    raw)   RAW=1 ;;
                esac
            done <<<"$WT_OUT"
            # Zgoda na zamrażanie ma sens tylko razem z nadaniem praw stąd; gdy pozycji
            # nie było na liście, nie wolno jej cichcem zostawić włączonej.
            [ "$FREEZE" -eq 1 ] && [ "$GRANT" -eq 1 ] || GQUIESCE=0
        fi
        # Migawki zdalnie nic nie kopiują: pomijane prefiksy i retencja "w źródle
        # kopii" nie mają czego dotyczyć (szablon jest retencją źródła).
        if [ "$MODE" = snaponly ]; then EXFAM=""; SRCPROF=""; return 0; fi
        if ! prefix_editor; then
            [ "${#items[@]}" -gt 0 ] || return 1
            continue
        fi
        return 0
    done
}
# Retencja źródła -- osobne pole karty (U25), to samo okno-tabela co dotąd w kroku 9.
step_srcret() {
    if [ -z "$PROFILE" ]; then
        wt --title "$(T 'Retencja źródła')" --msgbox "$(T 'Najpierw Harmonogram: retencja źródła to liczby szczebli szablonu.')" 8 "$W"
        return 1
    fi
    [ -s "$TMPD/prof.json.tiers" ] || load_profiles
    if [ "$RECURSION" != atomic ] && [ -s "$TMPD/prof.json.tiers" ]; then
        SRC_TITLE="$(title 9 "$(T 'Retencja: W ŹRÓDLE KOPII –') $(hostw)")"
        source_retention_editor || return 1
    else
        SRCPROF=""
    fi
    return 0
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
# EDYTOR POMIJANYCH MIGAWEK (właściciel, uwagi 10+13; wzór okna: decyzja 2026-10-11,
# W3). Wcześniej jedno pole tekstowe (łatwo zgubić przecinek), potem checklista;
# teraz wspólny list_editor z wt-lib.sh: lista widoczna w tekście, "Dodaj prefiks…",
# "Usuń prefiks…", "Gotowe". Wpisuje EXFAM (po przecinku) dopiero po "Gotowe".
prefix_editor() {   # edytuje EXFAM; 0 = zapisano (może być pusta), 1 = Wstecz (bez zmian)
    local p
    LE_ITEMS=()
    local IFS=,; for p in $EXFAM; do [ -n "$p" ] && LE_ITEMS+=("$p"); done; unset IFS
    list_editor "$(title 9 "$(T 'Pomijane prefiksy')")" \
        "$(T 'Migawki, których nazwa zaczyna się od jednego z tych prefiksów, NIE są kopiowane:')" \
        "$(T '(żadne – kopiowane są wszystkie migawki)')" \
        "$(T 'Dodaj prefiks…')" "$(T 'Usuń prefiks…')" prefix_add_cb || return 1
    local IFS=,; EXFAM="${LE_ITEMS[*]}"; unset IFS
    return 0
}
prefix_add_cb() {   # 0 = LE_NEW ustawione, 1 = Wstecz
    while :; do
        geom
        wt --title "$(T 'Nowy prefiks')" --ok-button "$(T 'Dodaj')" --cancel-button "$(T Wstecz)" \
           --inputbox "$(T 'Prefiks migawek do pominięcia (bez spacji i przecinków):')" 9 "$W" "" || return 1
        case "$WT_OUT" in
            ''|*' '*|*,*) wt --title "$(T 'Zły prefiks')" --msgbox "$(Tv ''\''$WT_OUT'\'' -- bez spacji i przecinków, nie może być puste.' '$WT_OUT' "$WT_OUT")" 8 "$W"; continue ;;
        esac
        LE_NEW="$WT_OUT"; return 0
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
    if [ "$MODE" = local ]; then
        # Kopia lokalna = istniejący wsad local-backup: --source bez hosta, drzewo -R.
        ARGV=("$ZB" "--source=${B_ROOT[*]}" "--target=$TARGET" "--recursive=flat")
    elif [ "$MODE" = snaponly ]; then
        # Migawki zdalne: "[-] część" = wymienione datasety (basket_expand), nie -X -- jej
        # przycinanie (delsnaps) -X nie zna, a czasownik odmawia --exclude-* (2026-10-25).
        ARGV=("$ZB" "--source=$(hostport):$(basket_entries "$BASKET_DS_JSON" | cut -f1 | paste -sd, -)")
    else
        ARGV=("$ZB" "--source=$(hostport):${B_ROOT[*]}")
    fi
    if [ "$MODE" = sync ]; then ARGV+=("--mode=sync")
    elif [ "$MODE" = snaponly ]; then ARGV+=("--mode=snaponly")
    elif [ "$MODE" != local ]; then ARGV+=("--target=$TARGET" "--landing=$(landing)"); fi
    [ -n "$PROFILE" ] && ARGV+=("--profile=$PROFILE")
    [ -n "$SRCPROF" ] && ARGV+=("--source-profile=$SRCPROF")
    [ -n "$RNAME" ] && ARGV+=("--name=$RNAME")
    [ "$RECURSION" = atomic ] && ARGV+=("--recursive=atomic")
    for i in "${!B_ROOT[@]}"; do
        [ "$MODE" = snaponly ] && break       # wyjątki już są w liście (basket_expand)
        while IFS= read -r x; do
            [ -n "$x" ] || continue
            ARGV+=("--exclude-child=^$x${D}")
            [ "$(kids_count "$x")" -gt 0 ] && ARGV+=("--exclude-child=^$x/")
        done <<<"${B_EXCL[$i]}"
    done
    # Campaign 2026-10-22 (pve10): snaponly copies nothing, and the verb refuses what shapes a
    # copy ("--passive/--raw/--exclude-* shape a copy") -- the wizard sent the default family
    # exclusions and every "Migawki zdalne" was refused at the plan.
    if [ "$MODE" != snaponly ]; then
        [ -n "$EXFAM" ] && ARGV+=("--exclude-family=$EXFAM")
        [ "$RAW" -eq 1 ] && ARGV+=("--raw")
    fi
    # "Nikt ich nie robi -- resztki": seed i linia lustra nie robią się pasywne.
    { [ "$MODE" = sync ] || [ "$MODE" = backup ]; } && sync_from_chain && [ "$(chain_ans)" = own ] && ARGV+=("--own-snapshots")
    # Kopia lokalna z cudzych migawek (replika pvesr): przyjmuje, niczego na źródle nie tworzy ani nie kasuje.
    is_passive_copy && ARGV+=("--passive")
    a="$(account_name)"; [ -n "$a" ] && ARGV+=("--local-user=$a")
    [ "$GRANT" -eq 1 ] && ARGV+=("--grant-remotely")
    [ "$GRANT" -eq 1 ] && [ "$FREEZE" -eq 1 ] && [ "$GQUIESCE" -eq 1 ] && ARGV+=("--grant-quiesce")
    [ "$MANUAL" -eq 1 ] && ARGV+=("--manual-join")
    # "Same migawki": pusty cel z --yes czasownik przyjmuje tylko z --no-copy (słowem,
    # nie pustą zmienną). Bez niego pytał drugi raz w terminalu po WYKONAJ -- właściciel
    # 2026-10-19: "skoro przeklikaliśmy przez GUI, to oczywiste, że chcemy".
    if [ "${1:-}" = install ]; then
        if [ "$NOCOPY" -eq 1 ]; then ARGV+=("--no-copy" "--install" "--yes"); else ARGV+=("--install" "--yes"); fi
    fi
    return 0
}
cmd_lines() { local a; printf '  %s \\\n' "${ARGV[0]}"; for a in "${ARGV[@]:1}"; do printf '      %s\n' "$(shq "$a")"; done; }
cmd_oneline() { local a; for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done; }
# U31 (kampania 2026-10-19): plan kopii lokalnej (local-backup) wkleja CAŁY kandydat configu
# i CAŁY blok crona hosta -- na pve10 331 linii, w tym relacje ab i cb. W oknie zostają sekcje
# i linie crona TEJ relacji; reszta (bez zmian) liczona jednym zdaniem. Plan zdalnej relacji
# pokazuje już różnicę (show_activation_proposal) i przechodzi bez zmian.
plan_only_this() {   # <nazwa relacji> ; plan na stdin -> stdout
    awk -v n="$1" '
        function flush(   i, mine) {
            if (!nb) return
            mine = (hdr == "[relation:" n "]")
            for (i = 1; i <= nb; i++) if (buf[i] ~ "^[ \t]*(relation|pair_label)[ \t]*=[ \t]*" n "[ \t]*$") mine = 1
            if (mine) { for (i = 1; i <= nb; i++) print buf[i]; kept++ } else skipped++
            nb = 0
        }
        /^--- candidate CONFIG/ { part = "cfg"; print "--- nowe sekcje configu (tej relacji) ---"; next }
        /^--- generated cron block/ { flush(); part = "cron"; print ""; print "--- nowe linie crona (tej relacji) ---"; next }
        part == "cfg" {
            if ($0 ~ /^\[/) { flush(); hdr = $0 }
            if (hdr != "") buf[++nb] = $0
            next
        }
        part == "cron" && /^To jest wylacznie plan/ { part = "end" }
        part == "cron" {
            if ($0 ~ ("relacja-" n "__") || index($0, " -L " n " ")) print; else if ($0 ~ /^[0-9*]/) other++
            next
        }
        { print }
        END { flush()
              if (skipped || other) printf "\nBez zmian zostaje reszta: sekcje configu: %d, linie crona: %d.\n", skipped, other }'
}

# --- krok 10: podsumowanie -> plan -> wykonanie ---------------------------------
summary_text() {
    local i a; a="$(account_name)"
    if [ "$NOCOPY" -eq 1 ]; then
        echo "$(Tv 'MIGAWKI LOKALNE: $(hostname) robi i sprząta migawki u siebie, nic nie kopiuje:' '$(hostname)' "$(hostname)")"
    elif [ "$MODE" = local ]; then
        echo "$(Tv 'LOKALNIE: $(hostname) kopiuje u siebie do $TARGET/<źródło>:' '$(hostname)' "$(hostname)" '$TARGET' "$TARGET")"
    elif [ "$MODE" = sync ]; then
        echo "$(Tv 'LUSTRO: $(hostname) i $HOST' '$(hostname)' "$(hostname -s 2>/dev/null || hostname)" '$HOST' "$(hostw)")$([ "$(hostw)" = "$HOST" ] || echo " ($HOST)")$(T ' będą trzymać to samo pod tą samą ścieżką:')"
    elif [ "$MODE" = snaponly ]; then
        echo "$(Tv 'MIGAWKI ZDALNE: $(hostname) będzie robić i sprzątać migawki NA $HOST' '$(hostname)' "$(hostname -s 2>/dev/null || hostname)" '$HOST' "$(hostw)")$([ "$(hostw)" = "$HOST" ] || echo " ($HOST)")$(T ', nic nie kopiuje:')"
    else
        echo "$(Tv 'BACKUP: $(hostname) będzie POBIERAĆ z $HOST' '$(hostname)' "$(hostname -s 2>/dev/null || hostname)" '$HOST' "$(landing)")$([ "$(landing)" = "$HOST" ] || echo " ($HOST)")$(Tv ' do $TARGET/$HOST/...' '$TARGET' "$TARGET" '$HOST' "$(landing)")"
    fi
    # Z wyjątkami relacja to lista [x]/[-] (set-datasets po założeniu), jak w planie okna zmiany.
    if any_excl && [ -s "${BASKET_DS_JSON:-}" ]; then
        echo "$(T '   Relacja obejmie:')"
        basket_entries "$BASKET_DS_JSON" | while IFS=$'\t' read -r n r; do
            [ -n "$n" ] || continue
            if [ "$r" = flat ]; then echo "     [x] $n  $(T '(z dziećmi, także przyszłymi)')"; else echo "     [-] $n  $(T '(sam dataset; dzieci tylko wymienione)')"; fi
        done
    else
        for i in "${!B_ROOT[@]}"; do echo "    ${B_ROOT[$i]}  -- $(describe "$i")"; done
    fi
    echo "$(Tv 'Sposób:  $(mode_words).   Nazwa: $RNAME.   Konto: ${a:-root}.' '$(mode_words)' "$(mode_words)" '$RNAME' "$RNAME" '${a:-root}' "${a:-root}")"
    echo "$(T 'Szablon:') $( [ -n "$MANUAL_P" ] && [ "$PROFILE" = "$MANUAL_P" ] && echo "$(Tv 'Ręcznie -- $PROFILE' '$PROFILE' "$PROFILE")" || echo "$PROFILE")$( [ -s "$TMPD/prof.tsv" ] && awk -F'\t' -v n="$PROFILE" '$1==n{print "  (" $3 "; " $2 "; " $4 ")"}' "$TMPD/prof.tsv")$( [ -n "$SRCPROF" ] && echo "$(Tv '; u źródła: $SRCPROF' '$SRCPROF' "$SRCPROF")")"
    if [ "$MODE" = snaponly ] || [ "$NOCOPY" -eq 1 ]; then :    # bez kopii: prefiksy nie dotyczą
    elif [ -n "$EXFAM" ]; then echo "$(T 'Pomijane migawki z prefiksami:') ${EXFAM//,/, }."
    else echo "$(T 'Pomijane migawki: żadne (kopiowane wszystkie).')"; fi
    [ "$RECURSION" = atomic ] && echo "$(T 'U ŹRÓDŁA migawek nie sprząta nikt (tak działa atomowo) -- trzeba samemu.')"
    if sync_from_chain; then
        # Plan mówi to, co wyjdzie (kampania 2026-10-24: obiecywał "WŁASNE migawki", a lustro
        # wychodziło pasywne -- sonda przy generowaniu configu robi je pasywnym mimo szablonu).
        if is_local_copy && [ "$(chain_ans)" = chain ]; then
            echo "$(T 'PASYWNIE: migawki na źródle robi kto inny (np. replika pvesr) -- kopia je tylko przyjmuje,')"
            echo "$(T '  niczego na źródle nie tworzy ani nie kasuje (--passive); retencja dotyczy samych kopii.')"
        elif is_local_copy && [ "$(chain_ans)" = own ]; then
            echo "$(T 'WŁASNE MIGAWKI: stare migawki naszej rodziny na źródle to resztki -- kopia robi własne,')"
            echo "$(T '  stare wejdą do retencji źródła i z czasem znikną.')"
        elif [ "$(chain_ans)" = own ]; then
            echo "$(T 'WŁASNE MIGAWKI: stare migawki naszej rodziny na źródle to resztki -- ta relacja robi własne')"
            echo "$(T '  (--own-snapshots); stare wejdą do jej retencji i z czasem znikną.')"
        elif [ "$PROFILE" = "$REC_PROFILE" ]; then
            echo "$(Tv 'ŁAŃCUCH: źródło ma już migawki naszej rodziny -- ta relacja kopiuje je BEZ własnych migawek ($PROFILE).' '$PROFILE' "$PROFILE")"
        elif [ "$MODE" = sync ]; then
            echo "$(T 'ŁAŃCUCH: migawki o naszych prefiksach na źródle robi inny kolektor lub inna relacja, albo przenosi je inny mechanizm np. cluster synchro -- lustro będzie PASYWNE:')"
            echo "$(Tv '  niczego tam nie utworzy ani nie skasuje, szablon $PROFILE tego nie zmieni.' '$PROFILE' "$PROFILE")"
            echo "$(T '  Jeśli nikt ich już nie robi, kopie staną -- wtedy pole Migawki na źródle -> resztki.')"
        else
            echo "$(T 'UWAGA ŁAŃCUCH: źródło ma już migawki naszej rodziny (kopie innej relacji albo resztki starej).')"
            echo "$(Tv '  Szablon $PROFILE dołoży tam WŁASNE migawki -- na kopiach innego kolektora to psuje jego kopie.' '$PROFILE' "$PROFILE")"
            echo "$(Tv '  Bez własnych migawek: pole Harmonogram -> $REC_PROFILE.' '$REC_PROFILE' "$REC_PROFILE")"
        fi
    fi
    # G-1 (kampania 2026-10-22, pve10): lustro pisze pod TYMI SAMYMI nazwami co źródło; pve10
    # miał własny hdd/archive i seed odmówił dopiero po założeniu relacji. Mówimy to tutaj.
    if [ "$MODE" = sync ]; then
        local _r _here=""
        for _r in "${B_ROOT[@]}"; do zfs list -H -o name -- "$_r" >/dev/null 2>&1 && _here="${_here:+$_here, }$_r"; done
        if [ -n "$_here" ]; then
            echo "$(Tv 'UWAGA: na TYM hoście już jest $_here -- lustro pisze pod tą samą nazwą.' '$_here' "$_here")"
            echo "$(T '  Jeśli to nie jest wcześniejsza kopia tego źródła (wspólna migawka), seed odmówi i relacja')"
            echo "$(T '  zostanie w stanie '\''seeding'\'' -- niczego nie nadpisze. Inaczej: backup (kopie pod hdd/backups/<host>).')"
        fi
    fi
    [ "$RAW" -eq 1 ] && echo "$(T 'Wysyłka zaszyfrowana (raw): kopia leży w celu zaszyfrowana, ten host nie potrzebuje klucza.')"
    if [ "$MODE" = local ]; then
        [ "$FREEZE" -eq 1 ] && ! is_passive_copy && echo "$(T 'Zamrażanie: goście tego hosta, przed migawkami dobowymi i rzadszymi.')"
        echo
        echo "$(T 'Komenda (to samo wpisałbyś z palca):')"
        cmd_oneline; echo
        case " ${ARGV[*]} " in *" --exclude-child="*) echo "(^nazwa${D:-\$} $(T '= dokładnie ten dataset, nie łapie np. ...disk-01)')" ;; esac
        return 0
    fi
    if [ "$FREEZE" -eq 1 ]; then
        if [ "$GRANT" -eq 1 ] && [ "$GQUIESCE" -eq 1 ]; then echo "$(T 'Zamrażanie: źródło dostanie zgodę stąd (--grant-quiesce).')"
        else echo "$(T 'Zamrażanie: BEZ zgody źródła migawki wyjdą jako '\''_crash_'\'' (niezamrożone).')"; fi
    fi
    echo "$(T 'Prawa na źródle:') $( [ "$GRANT" -eq 1 ] && echo "$(T 'nadane stąd, od razu')" || echo "$(T 'zatwierdzisz SAM -- instalacja zatrzyma się i poda komendę')" )$( [ "$MANUAL" -eq 1 ] && echo "$(T '; parowanie ręczne')")"
    echo
    echo "$(T 'Komenda (to samo wpisałbyś z palca):')"
    cmd_oneline; echo
    case " ${ARGV[*]} " in *" --exclude-child="*) echo "(^nazwa${D:-\$} $(T '= dokładnie ten dataset, nie łapie np. ...disk-01)')" ;; esac
    return 0
}
# INNY KOLEKTOR JUŻ PRZYCINA TE DATASETY (uwaga 4, 2026-10-08). Aktywacja odmawia,
# gdy cudze konto zfsbackup-* ma `destroy` na źródle -- dwie retencje zjadają sobie
# bazy. Na pve9b <- pve11 odmowa przyszła dopiero po koncie, grantach i PEŁNYM seedzie
# trzech datasetów. To samo pytanie (source-pruners) pada tu, przed WYKONAJ.
# Dotyczy tylko relacji, która przycina źródło: backup, szablon nie-pasywny, nie atomowo.
# 0 = dalej, 1 = wstecz, 2 = wróć do datasetów, 3 = wróć do szablonu (pasywny)
check_pruners() {
    [ "$MODE" = backup ] || return 0
    case "$PROFILE" in passive|passive-flat) return 0 ;; esac
    [ "$RECURSION" = atomic ] && return 0
    info "$(title 10 "$(T 'Plan')")" "$(T 'Sprawdzam, czy inny kolektor nie przycina już tych datasetów...')"
    if ! "$ZB" source-pruners "$(hostport)" "${B_ROOT[@]}" >"$TMPD/pruners.tsv" 2>"$TMPD/pruners.err"; then
        wt --title "$(T 'Nie sprawdzono innych kolektorów')" --msgbox "$(Tv 'source-pruners nie odpowiedział:\n$(tail -2 "$TMPD/pruners.err")\n\nAktywacja i tak to sprawdzi -- przed instalacją crona.' '$(tail -2 "$TMPD/pruners.err")' "$(tail -2 "$TMPD/pruners.err")")" 12 "$W"
        return 0
    fi
    [ -s "$TMPD/pruners.tsv" ] || return 0
    local lst; lst=$(awk -F'\t' '{printf "    %s  -- %s\n", $1, $2}' "$TMPD/pruners.tsv")
    geom
    wt --title "$(T 'Inny kolektor już przycina te datasety')" --notags --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" \
       --menu "$(Tv 'Na $HOST migawki tych datasetów może już kasować inny kolektor:\n$lst\nDwie retencje na jednym źródle kasują sobie nawzajem bazy -- aktywacja odmówi.\nAlbo usuń tamtą relację (na tamtym kolektorze), albo:' '$HOST' "$(hostw)" '$lst' "$lst")" "$H" "$W" 2 \
       pasywnie "$(T 'Pasywnie -- bez retencji u źródła (szablon passive)')" \
       datasety "$(T 'Inne datasety -- wróć do wyboru')" || return 1
    case "$WT_OUT" in
        pasywnie) PROFILE=passive; SRCPROF=""; return 3 ;;
        datasety) return 2 ;;
    esac
    return 1
}

step_summary() {    # 0 = wykonano (RC_RUN), 1 = wstecz, 2 = do datasetów, 3 = do szablonu
    local rc
    while :; do
        geom
        # (2026-10-26) Wyjątki działają w każdym rodzaju relacji: migawki zdalne dostają listę
        # (basket_expand), a po założeniu zakres zapisuje set-datasets -- dawna blokada odpadła.
        # JEDNO OKNO (właściciel 2026-10-29: „Za dużo tych okien potwierdzających w ciągu
        # decyzyjnym”): było podsumowanie -> „Pokaż plan” -> plan do przewinięcia -> „Plan był
        # w poprzednim oknie... WYKONAJ?”. Karta przed UTWÓRZ jest już podsumowaniem; teraz
        # po UTWÓRZ jest jedno okno: zdanie po polsku, komenda, ostrzeżenia czasownika i
        # WYKONAJ. Pełny plan (sekcje configu, linie crona) idzie do pliku obok dziennika.
        build_argv install
        summary_text >"$TMPD/summary.txt"
        check_pruners; rc=$?
        case "$rc" in 0) ;; 1) return 1 ;; *) return "$rc" ;; esac     # Wstecz = karta (okna podsumowania już nie ma)
        build_argv
        info "$(title 10 "$(T 'Plan')")" "$(T 'Pytam czasownik o plan (nic nie zmienia)...')"
        "${ARGV[@]}" >"$TMPD/plan.txt" 2>&1; rc=$?
        # R2-2 (właściciel, 2026-09-24): to okno ma pokazać, CO się wykona po WYKONAJ -- pełną
        # komendę i decyzje po polsku -- a dopiero pod spodem plan czasownika. Wcześniej było
        # tu tylko angielskie "RUX plan" bez komendy, retencji źródła, pomijanych i konta.
        # Linia "--grant-remotely is noted, but --plan is read-only" myliła (grant NASTĄPI
        # po WYKONAJ), więc jej tu nie ma.
        { echo "$(T 'Po WYKONAJ uruchomi się DOKŁADNIE:')"
          build_argv install; cmd_oneline; echo; build_argv
          echo
          if [ "$NOCOPY" -eq 1 ]; then echo "$(Tv 'Cel: brak (same migawki).  Szablon: $PROFILE.' '$PROFILE' "$PROFILE")"
          # Kampania 2026-10-22: migawki zdalne dostawały zdanie lustra ("ta sama ścieżka").
          elif [ "$MODE" = snaponly ]; then echo "$(Tv 'Bez kopii: migawki na $HOST, jego datasety.  Szablon: $PROFILE.' '$HOST' "$(hostw)" '$PROFILE' "$PROFILE")"
          else echo "$(T 'Cel:') ${TARGET:-$(T '(lustro: ta sama ścieżka)')}.  $(Tv 'Trzyma tutaj: $PROFILE.  U źródła:' '$PROFILE' "$PROFILE") $(if is_passive_copy; then T 'nic (pasywnie)'; else printf '%s' "${SRCPROF:-$(T 'jak tutaj')}"; fi)."; fi
          if [ "$MODE" = snaponly ] || [ "$NOCOPY" -eq 1 ]; then :
          elif [ -n "$EXFAM" ]; then echo "$(T 'Pomijane migawki z prefiksami:') ${EXFAM//,/, }."
          else echo "$(T 'Pomijane migawki: żadne (kopiowane wszystkie).')"; fi
          echo "$(T 'Konto:') $(a="$(account_name)"; echo "${a:-root}")."
          echo
          echo "$(Tv 'Plan czasownika -- nic jeszcze nie zostało zmienione (rc=$rc):' '$rc' "$rc")"
          grep -v -- '--grant-remotely is noted' "$TMPD/plan.txt" | plan_only_this "$RNAME"; } >"$TMPD/plan2.txt"
        if [ "$rc" -ne 0 ]; then
            wt --title "$(title 10 "$(T 'Plan ODRZUCONY przez czasownik')")" --scrolltext --msgbox "$(cat "$TMPD/plan2.txt")" "$H" "$W"
            continue
        fi
        local planf="$TMPD/plan2.txt"
        if [ -n "${ZFS_TUI_LOG:-}" ]; then planf="${ZFS_TUI_LOG%.log}-plan.txt"; cp -f "$TMPD/plan2.txt" "$planf" 2>/dev/null || planf="$TMPD/plan2.txt"; fi
        # Okno: całe podsumowanie (decyzje po polsku i komenda -- testy pilnują ich słów),
        # bez pustych wierszy, ostrzeżenia czasownika i ścieżka pełnego planu; w 80x24 mieści
        # się na styk, więc bez drugiego okna z pytaniem. Angielska góra planu powtarzała to samo.
        { grep -v '^[[:space:]]*$' "$TMPD/summary.txt"
          # ostrzeżenia czasownika zostają w oknie -- to one zmieniają decyzję
          grep -E '^(!!!|WARNING|Warning|>>> .*(WARNING|warn))' "$TMPD/plan.txt" | grep -v -- '--grant-remotely is noted' | head -8
          echo "$(Tv 'Pełny plan (sekcje configu, linie crona): $planf' '$planf' "$planf")"; } >"$TMPD/plan-short.txt"
        yesno_text "$TMPD/plan-short.txt" "$(title 10 "$(T 'Plan')")" "$(T WYKONAJ)" "$(T Wstecz)" || return 1
        build_argv install
        # U66 część 2: okno postępu zamiast czarnego ekranu (wtl run_progress), potem okno wyniku.
        : >"$TMPD/run.log"
        RC_RUN=0; run_progress "$(Tv 'Nowa relacja '\''$RNAME'\'': zakładam' '$RNAME' "$RNAME")" "$TMPD/run.log" "${ARGV[@]}" || RC_RUN=$?
        # JEDNA REGUŁA DRZEWA TAKŻE PRZY TWORZENIU (relacja = config, 2026-10-26): przy jakimkolwiek
        # [-] zakres zapisany od razu jako pozycje relacji -- to samo set-datasets co w oknie zmiany,
        # w każdym rodzaju relacji. Seed powyżej szanował wyjątki, więc nic zbędnego nie przyszło.
        # Migawki zdalne zakłada się już z pozycjami drzewa (basket_entries w --source), więc
        # drugi krok nic by nie zmienił -- tylko kosztował ~30 s (kampania 2026-10-26).
        if [ "$RC_RUN" -eq 0 ] && [ "$MODE" != snaponly ] && any_excl; then
            _da=(); mapfile -t _da < <(basket_entries "$BASKET_DS_JSON" | awk -F'\t' 'NF { printf "--dataset=%s:%s\n", $1, $2 }')
            : >"$TMPD/run2.log"
            run_progress "$(Tv 'Nowa relacja '\''$RNAME'\'': zakres wg drzewa' '$RNAME' "$RNAME")" "$TMPD/run2.log" "$ZB" set-datasets "$RNAME" "${_da[@]}" --yes || RC_RUN=$?
            cat "$TMPD/run2.log" >>"$TMPD/run.log"
        fi
        # DZIENNIK DLA F3 Ins (owner note 5): TUI ustawia ZFS_TUI_LOG na
        # sciezke ~/.zfs-tui/new-relation-<stamp>.log; dopisujemy do niego, zeby wynik biegu
        # nie zniknal w $TMPD.
        if [ -n "${ZFS_TUI_LOG:-}" ] && [ -f "$TMPD/run.log" ]; then
            cat "$TMPD/run.log" >>"$ZFS_TUI_LOG" 2>/dev/null
            echo "rc=$RC_RUN" >>"$ZFS_TUI_LOG" 2>/dev/null
        fi
        [ "$RC_RUN" -eq 0 ] && NR_DONE=1
        if [ "$RC_RUN" -eq 0 ]; then
            # Sukces jednym zdaniem = linia komunikatu GUI, bez okna z <Ok>; dziennik dopisuje GUI
            # (kampania pve10, 2026-10-29: linia "Dziennik:" robila z sukcesu okno).
            result_box "$(T 'Nowa relacja: GOTOWE')" 0 "$TMPD/run.log" "$(Tv 'Relacja '\''$RNAME'\'' założona (rc=0).' '$RNAME' "$RNAME")"
        elif [ "$GRANT" -eq 0 ] && grep -q -- '--commit-scope=' "$TMPD/run.log"; then
            # To nie awaria: wybrano "zatwierdzę sam", więc instalacja MA stanąć w tym miejscu.
            cmd_oneline >"$HOME/new-relation-$RNAME.cmd" 2>/dev/null; echo >>"$HOME/new-relation-$RNAME.cmd"
            { echo "$(Tv 'ZATRZYMANE ZGODNIE Z WYBOREM -- relacja '\''$RNAME'\'' czeka na zgodę źródła.' '$RNAME' "$RNAME")"
              echo
              echo "$(Tv '1. Na $HOST, jako root:' '$HOST' "$HOST")"
              echo "   cd $C_DIR && ./$(grep -o 'deploy.sh --commit-scope=[^ ]*' "$TMPD/run.log" | tail -1)$( [ "$FREEZE" -eq 1 ] && echo ' --allow-quiesce')"
              [ "$FREEZE" -eq 1 ] && echo "$(T '   (--allow-quiesce: bez tego szablon zamrażający da migawki '\''_crash_'\'')')"
              echo
              echo "$(Tv '2. Potem TUTAJ ponów tę samą komendę (zapisana w $HOME/new-relation-$RNAME.cmd):' '$HOME' "$HOME" '$RNAME' "$RNAME")"
              echo "   $(cmd_oneline)"
            } >"$TMPD/stop.txt"
            textbox_read "$(T 'Nowa relacja: zatrzymane zgodnie z wyborem')" "$TMPD/stop.txt" "$(T 'Zamknij')"
        else
            result_box "$(T 'Nowa relacja: NIE UDAŁO SIĘ')" "$RC_RUN" "$TMPD/run.log" "" "$(Tv 'Relacja '\''$RNAME'\'' nie została założona.' '$RNAME' "$RNAME")"
        fi
        return 0
    done
}

# --- KARTA RELACJI (U25) -------------------------------------------------------
# Właściciel 2026-10-20 (symulacja docs/project/SYMULACJA-U25-OKNO-RELACJI.md, odpowiedzi
# 1 tak, 2 tak, 3 na szaro): jedno okno -- lista pól z wartościami -- dla nowej relacji i
# dla zmiany (tui/edit-relation.sh rysuje tę samą kartę). Pola otwierają się same, jedno
# po drugim, jak dawny kreator; Wstecz w oknie pola wraca na KARTĘ (nie krok w tył), a z
# karty dowolne pole poprawia się bez cofania. "Utwórz relację" = podsumowanie, plan,
# WYKONAJ (step_summary, bez zmian).
RC_RUN=1
# chain zaraz po ds (wlasciciel 2026-10-29): pytanie o migawki na ZRODLE padalo po wyborze celu
# i operator bral je za przeszkode w celu.
ORDER=(mode host ds chain target profile srcret name acct extra)
VIS=" "
field_applies() {   # <pole> -> 0, gdy pole jest w tej relacji
    case "$1" in
        host)   [ "$MODE" != local ] ;;
        target) [ "$MODE" = backup ] || { [ "$MODE" = local ] && [ "$NOCOPY" -eq 0 ]; } ;;
        # U32: lustro trzyma to, co źródło -- osobnej retencji "u źródła" nie ma.
        # Pasywna kopia lokalna nie ma retencji źródła -- migawki źródła nie są jej.
        srcret) [ "$MODE" = backup ] || { is_local_copy && ! { sync_from_chain && [ "$(chain_ans)" = chain ]; }; } ;;
        extra)  [ "$NOCOPY" -eq 0 ] ;;
        # Tylko gdy źródło ma już migawki naszej rodziny (lustro, backup).
        chain)  { [ "$MODE" = sync ] || [ "$MODE" = backup ] || is_local_copy; } && sync_from_chain ;;
        *)      return 0 ;;
    esac
}
src_words() {   # SRCPROF <cel>-src-H24D3 -> "godzinowe 24, dobowe 3" (retention-lib)
    [ -n "$SRCPROF" ] || { echo "$(T 'jak tutaj (cel)')"; return; }
    src_words_of "$SRCPROF"
}
field_value() {   # <pole> -> wartość na karcie ("" = jeszcze nie ustawione)
    local a
    case "$1" in
        mode)
            if [ "$NOCOPY" -eq 1 ]; then echo "$(T 'migawki lokalne -- na tym hoście, bez kopii')"; return; fi
            case "$MODE" in
                sync) echo "$(T 'lustro -- to samo po obu stronach')" ;;
                local) echo "$(T 'kopia lokalna -- na tym hoście')" ;;
                snaponly) echo "$(T 'migawki zdalne -- na innym hoście, bez kopii')" ;;
                *) echo "$(T 'backup -- ten host pobiera ze źródła')" ;;
            esac ;;
        host)   [ -n "$HOST" ] && [ "$DIAG_OK_FOR" = "$(hostport)" ] && echo "$(Tv '$(hostport) (${HOSTNAME_R:-?}) -- SSH, ZFS, pakiet: OK' '$(hostport)' "$(hostw)" '${HOSTNAME_R:-?}' "$(hostport)")" ;;   # U111: nazwa, adres w nawiasie
        # [-] widać już w podsumowaniu (kampania 2026-10-26): korzeń z wyjątkiem albo zamknięty.
        ds)     [ "${#B_ROOT[@]}" -gt 0 ] && echo "${#B_ROOT[@]}: $(for _i in "${!B_ROOT[@]}"; do _m=""
                    { [ -n "${B_EXCL[$_i]}" ] || printf '%s\n' "${B_CLOSED:-}" | grep -qxF -- "${B_ROOT[$_i]}"; } && _m=" [-]"
                    printf '%s%s, ' "${B_ROOT[$_i]}" "$_m"; done | sed 's/, $//')" ;;
        target) [ -n "$TARGET" ] && { [ "$MODE" = local ] && echo "$TARGET  -> $TARGET/…" || echo "$TARGET  -> $TARGET/$(landing)/…"; } ;;
        profile)
            [ -n "$PROFILE" ] || return 0
            if [ -n "$MANUAL_P" ] && [ "$PROFILE" = "$MANUAL_P" ]; then echo "$(T 'własne (tabela szczebli)')"; return; fi
            a="$(awk -F'\t' -v n="$PROFILE" '$1==n{print $2; exit}' "$TMPD/prof.tsv" 2>/dev/null)"
            echo "$PROFILE${a:+ -- $a}" ;;
        srcret) case "$VIS" in *" srcret "*) src_words ;; esac ;;
        chain)  case "$(chain_ans)" in
                    chain) echo "$(T 'przyjmowane -- robi je ktoś inny (łańcuch)')" ;;
                    own)   echo "$(T 'własne -- stare to resztki')" ;;
                esac ;;
        name)   echo "$RNAME" ;;
        acct)   a="$(account_name)"; echo "${a:-root}" ;;
        extra)
            # Kampania wariantów 2026-10-22: raw jest domyślne od kroku datasetów (raw_default), a karta
            # nieodwiedzonych Dodatkowych go nie wymieniała -- nie było widać, że kopia pójdzie zaszyfrowana.
            case "$VIS" in *" extra "*) ;; *) [ "$MODE" = local ] && echo "$(T 'pomijane:') $(printf '%s' "$EXFAM" | tr ',' '\n' | grep -c .) $(T 'prefiksy')" || echo "$(T 'prawa stąd, zgoda na zamrażanie')$([ "$RAW" -eq 1 ] && echo ", $(T 'zaszyfrowane')")$([ "$MODE" = snaponly ] || echo ", $(T 'pomijane:') $(printf '%s' "$EXFAM" | tr ',' '\n' | grep -c .) $(T 'prefiksy')")"; return ;; esac
            a=""
            [ "$MODE" != local ] && [ "$GRANT" -eq 1 ] && a="$(T 'prawa stąd')"
            [ "$GQUIESCE" -eq 1 ] && [ "$GRANT" -eq 1 ] && a="${a:+$a, }$(T 'zgoda na zamrażanie')"
            [ "$MANUAL" -eq 1 ] && a="${a:+$a, }$(T 'parowanie ręczne')"
            [ "$RAW" -eq 1 ] && a="${a:+$a, }$(T 'zaszyfrowane')"
            [ "$MODE" != snaponly ] && a="${a:+$a, }$(T 'pomijane:') $(printf '%s' "$EXFAM" | tr ',' '\n' | grep -c .) $(T 'prefiksy')"
            echo "${a:-$(T 'bez dodatków')}" ;;
    esac
}
missing_fields() {   # -> nazwy pól, bez których relacji nie da się założyć
    local m=""
    field_applies host && [ -z "$(field_value host)" ] && m="${m:+$m, }$(T 'źródło')"
    [ "${#B_ROOT[@]}" -gt 0 ] || m="${m:+$m, }$(T 'datasety')"
    field_applies target && [ -z "$TARGET" ] && m="${m:+$m, }$(T 'cel')"
    field_applies chain && [ -z "$(chain_ans)" ] && m="${m:+$m, }$(T 'migawki na źródle')"
    [ -n "$PROFILE" ] || m="${m:+$m, }$(T 'harmonogram')"
    [ -n "$RNAME" ] || m="${m:+$m, }$(T 'nazwa')"
    echo "$m"
}
run_field() {   # <pole> -> rc okna pola (0 = ustawione)
    local before rc
    case "$1" in
        mode)    before="$MODE/$NOCOPY"; step_mode; rc=$?
                 [ "$rc" -eq 0 ] && [ "$before" != "$MODE/$NOCOPY" ] && VIS=" " ;;
        host)    before="$HOST"
                 while :; do step_host || { rc=1; break; }; step_diag && { rc=0; break; }; done
                 [ "$rc" -eq 0 ] && [ "$before" != "$HOST" ] && VIS="${VIS/ ds / }"
                 # nazwa wynika z hosta -- karta ją pokazuje, osobnego okna nie trzeba
                 [ "$rc" -eq 0 ] && [ -n "$(host_rname)" ] && { RNAME="$(host_rname)"; case "$VIS" in *" name "*) ;; *) VIS="$VIS""name " ;; esac; } ;;
        ds)      step_datasets; rc=$? ;;
        target)  step_target; rc=$? ;;
        profile) before="$PROFILE"; step_profile; rc=$?
                 [ "$rc" -eq 0 ] && [ "$before" != "$PROFILE" ] && { SRCPROF=""; VIS="${VIS/ srcret / }"; } ;;
        srcret)  step_srcret; rc=$? ;;
        chain)   step_chain; rc=$? ;;
        name)    step_name; rc=$? ;;
        acct)    step_account; rc=$? ;;
        extra)   step_extra; rc=$? ;;
        *)       rc=1 ;;
    esac
    [ "$rc" -eq 0 ] && { case "$VIS" in *" $1 "*) ;; *) VIS="$VIS$1 " ;; esac; }
    return "$rc"
}
next_unvisited() {   # -> pierwsze pole w kolejności, którego jeszcze nie otwarto
    local f
    for f in "${ORDER[@]}"; do
        field_applies "$f" || continue
        case "$VIS" in *" $f "*) ;; *) echo "$f"; return 0 ;; esac
    done
    return 1
}
CARD_NAMES_OF() {
    case "$1" in
        mode) echo "$(T 'Rodzaj')" ;; host) echo "$(T 'Źródło')" ;; ds) echo "$(T 'Datasety')" ;; target) echo "$(T 'Cel')" ;;
        profile) echo "$(T 'Harmonogram')" ;; srcret) echo "$(T 'Retencja źródła')" ;; silnik) echo "$(T 'Silnik')" ;;
        chain) echo "$(T 'Migawki na źródle')" ;;
        name) echo "$(T 'Nazwa')" ;; acct) echo "$(T 'Konto')" ;; extra) echo "$(T 'Dodatkowe')" ;;
    esac
}

# ---- PROWADZĄCY (U66, przebudowa 2026-10-21) ------------------------------------------
# Właściciel: "Wstecz to wstecz", "to okno jest super, ale mylące", "do kompletnej przebudowy".
# Kroki tego rodzaju relacji po kolei, Dalej = następny, Wstecz = POPRZEDNI (z zapamiętaną
# odpowiedzią), Wstecz w kroku 1 = pytanie o przerwanie. Po ostatnim kroku PODSUMOWANIE:
# Enter na pozycji = ten krok jeszcze raz i od razu powrót do podsumowania; konto i dodatki
# siedzą w "Zaawansowane" (domyślne pasują prawie zawsze); dopiero tam "Utwórz relację".
wz_steps() {   # -> kroki bieżącego rodzaju, w kolejności
    local f out=""
    for f in mode host ds chain target profile srcret name; do field_applies "$f" && out="$out $f"; done
    echo $out
}
wz_abort() {   # 0 = przerwij; 1 = zostań ("Zostań" albo Esc)
    # Kampania 2026-10-22: Esc w tym pytaniu przerywał -- jeden Esc za dużo i całe wypełnianie
    # znikało. Esc to "nie" w pytaniu tak/nie, czyli Zostań; przerwać można tylko przyciskiem.
    wt --title "$(T 'Nowa relacja: przerwać?')" --yes-button "$(T 'Przerwij')" --no-button "$(T 'Zostań')" --defaultno \
       --yesno "$(T 'Przerwać tworzenie relacji? Nic nie zostało zmienione.')" 8 "$W"
}
wz_walk() {   # <od którego kroku> -> 0 = doszedł do końca, 1 = przerwane
    local i="$1"; local -a list
    while :; do
        read -ra list <<<"$(wz_steps)"
        [ "$i" -lt "${#list[@]}" ] || return 0
        WZ_SI=$((i + 1)); WZ_SN=${#list[@]}
        if run_field "${list[$i]}"; then
            i=$((i + 1))
        elif [ "$i" -gt 0 ]; then
            i=$((i - 1))
        elif wz_abort; then
            return 1
        fi
    done
}
wz_adv() {   # Zaawansowane: konto i dodatki; wraca do podsumowania
    local pick=acct
    while :; do
        WZ_SN=""
        CARD_TAGS=(); CARD_NAMES=(); CARD_VALUES=(); CARD_FIXED=()
        field_applies acct && { CARD_TAGS+=(acct); CARD_NAMES+=("$(T 'Konto')"); CARD_VALUES+=("$(field_value acct)"); CARD_FIXED+=(0); }
        field_applies extra && { CARD_TAGS+=(extra); CARD_NAMES+=("$(T 'Dodatkowe')"); CARD_VALUES+=("$(field_value extra)"); CARD_FIXED+=(0); }
        CARD_ACT_TAGS=(); CARD_ACT_LABELS=()
        card_menu "$(T 'Nowa relacja: zaawansowane')" "$(T 'Rzeczy, których zwykle się nie zmienia.')" "$pick" "$(T Wstecz)" || return 0
        pick="$WT_OUT"
        case "$pick" in acct|extra) run_field "$pick" ;; *) return 0 ;; esac
    done
}
wz_profile() {   # szablon z podsumowania: retencja źródła zależy od szablonu -> od razu też ona
    run_field profile && field_applies srcret && run_field srcret
    return 0
}
WZ_SN=""
wz_walk 0 || { clear 2>/dev/null; wt_end_nochange "$(T 'Nowa relacja: przerwane, nic nie zmieniono')"; exit 1; }
cur=create
while :; do
    WZ_SN=""
    read -ra WZ_LIST <<<"$(wz_steps)"
    CARD_TAGS=(); CARD_NAMES=(); CARD_VALUES=(); CARD_FIXED=()
    for f in "${WZ_LIST[@]}"; do
        CARD_TAGS+=("$f"); CARD_NAMES+=("$(CARD_NAMES_OF "$f")"); CARD_VALUES+=("$(field_value "$f")"); CARD_FIXED+=(0)
    done
    CARD_TAGS+=(adv); CARD_NAMES+=("$(T 'Zaawansowane')")
    a="$(T 'konto') $(field_value acct)"; [ "$NOCOPY" -eq 0 ] && a="$a; $(field_value extra)"
    CARD_VALUES+=("$a"); CARD_FIXED+=(0)
    miss="$(missing_fields)"
    CARD_ACT_TAGS=(create); CARD_ACT_LABELS=("$(T 'UTWÓRZ RELACJĘ -- plan, WYKONAJ')${miss:+   ($(T 'brak:') $miss)}")
    card_menu "$(T 'Nowa relacja -- podsumowanie')" "$(T 'Sprawdź. Poprawiony krok wraca tutaj, do podsumowania.')" "$cur" "$(T 'Przerwij')" \
        || { wz_abort && { clear 2>/dev/null; wt_end_nochange "$(T 'Nowa relacja: przerwane, nic nie zmieniono')"; exit 1; }; continue; }
    cur="$WT_OUT"
    case "$cur" in
        __sep__) cur=create; continue ;;
        adv)     wz_adv; cur=create; continue ;;   # po Zaawansowanych zwykle już tylko Utwórz
        create)
            if [ -n "$miss" ]; then
                wt --title "$(T 'Brakuje kroków')" --msgbox "$(Tv 'Do założenia relacji brakuje: $miss.' '$miss' "$miss")" 8 "$W"
                continue
            fi
            # Konto jest w Zaawansowanych, więc mogło nie być oglądane: niedopasowanie
            # szablonu do konta sprawdza się też tutaj, zanim plan pójdzie do czasownika.
            if account_is_flat "$(account_name)" \
               && [ "$(awk -F'\t' -v n="$PROFILE" '$1==n{print $6}' "$TMPD/prof.tsv" 2>/dev/null)" != flat ]; then
                wt --title "$(T 'Szablon nie pasuje do konta')" --msgbox "$(Tv 'Na koncie $(field_value acct) działają relacje z retencją W SZCZEBLACH, a szablon\n$PROFILE ma drabinę GFS -- czasownik by to odmówił.\n\nZmień szablon albo konto (Zaawansowane).' '$(field_value acct)' "$(field_value acct)" '$PROFILE' "$PROFILE")" 10 "$W"
                cur=profile; continue
            fi
            step_summary
            case $? in
                0) break ;;
                2) WZ_SN=""; run_field ds ;;
                3) WZ_SN=""; wz_profile ;;
            esac
            cur=create ;;
        mode)
            # Inny rodzaj = inne kroki: po zmianie przejście kroków od nowa (odpowiedzi zostają).
            before="$MODE/$NOCOPY"
            run_field mode
            if [ "$before" != "$MODE/$NOCOPY" ]; then
                wz_walk 1 || { clear 2>/dev/null; wt_end_nochange "$(T 'Nowa relacja: przerwane, nic nie zmieniono')"; exit 1; }
                cur=create
            fi ;;
        profile) wz_profile ;;
        *)  run_field "$cur" ;;
    esac
done
exit "$RC_RUN"
