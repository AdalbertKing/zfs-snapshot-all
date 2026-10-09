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
. "$HERE/tui/basket-lib.sh" || { echo "new-relation: brak $HERE/tui/basket-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
. "$HERE/tui/retention-lib.sh" || { echo "new-relation: brak $HERE/tui/retention-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
WT_BACKTITLE="Nowa relacja -- kolektor $(hostname)"
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
MODE="backup"; HOST=""; PORT="22"; HOSTNAME_R=""; RECURSION="flat"

# --- okna -------------------------------------------------------------------
title() {
    if [ "$MODE" = local ]; then
        local n="$1"; [ "$n" -gt 3 ] && n=$((n - 2))
        printf 'Krok %s/8: %s' "$n" "$2"
    else
        printf 'Krok %s/%s: %s' "$1" "$NSTEP" "$2"
    fi
}
# Kopia lokalna nie ma drugiego hosta: czytelniki pytamy bez adresu (= ten host).
hostport() { [ "$MODE" = local ] && return 0; [ "$PORT" = 22 ] && echo "$HOST" || echo "$HOST:$PORT"; }

# --- krok 1: typ ------------------------------------------------------------
step_mode() {
    geom
    local b=OFF s=OFF l=OFF
    case "$MODE" in sync) s=ON ;; local) l=ON ;; *) b=ON ;; esac
    wt --title "$(title 1 'Jaka relacja?')" --ok-button "Dalej" --cancel-button "Wyjdź" --notags \
       --radiolist "Backup: ten host POBIERA migawki ze źródła i trzyma je u siebie.\nLustro: te same datasety pod tą samą ścieżką i te same migawki:\nco zniknie u źródła, zniknie też tutaj (bez własnej retencji).\nLokalnie: kopia na tym samym hoście, np. rpool/data -> hdd/backup.\n\nStrzałki = ruch, spacja = wybierz, Enter = dalej." "$(fit 8)" "$W" 3 \
       backup "Backup    (ten host pobiera ze źródła)" "$b" \
       sync   "Lustro    (to samo po obu stronach)" "$s" \
       local  "Lokalnie  (kopia na tym hoście)" "$l" || return 1
    if [ -n "$WT_OUT" ] && [ "$WT_OUT" != "$MODE" ]; then
        # Inna droga = inne źródło: koszyk z poprzedniej nie należy do tej.
        B_ROOT=(); B_EXCL=(); TREE_FOR="-"
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
            wt --title "Ta relacja już istnieje" --msgbox "Z hostem $h jest już relacja: $rel.\n\nRelacja to PARA HOSTÓW -- jedna na parę, z wieloma datasetami.\nDataset do istniejącej relacji dodaje się na F3: Enter na niej,\npotem 'e' i „Dodaj dataset ze źródła” (zfs-backup.sh add-source).\n\nTutaj podaj host, z którym relacji nie ma." 14 "$W"
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
    local -a _lh=(); [ "$MODE" = local ] || _lh=("$(hostport)")
    "$ZB" list-datasets ${_lh[@]+"${_lh[@]}"} --json --own-snapshots >"$TMPD/ds.json" 2>"$TMPD/ds.err" || return 1
    basket_tree_from_json "$TMPD/ds.json"
    [ "${#T_NAME[@]}" -gt 0 ] || { echo "źródło nie ma żadnego datasetu" >"$TMPD/ds.err"; return 1; }
    TREE_FOR="$(hostport)"
}
step_datasets() {
    geom
    [ "$TREE_FOR" = "$(hostport)" ] || info "$(title 4 'Datasety')" "Pobieram listę datasetów z $HOST..."
    # load_tree zapamiętuje drzewo po hostport(); dla kopii lokalnej to "" -- tak samo.
    if ! load_tree; then
        wt --title "Nie udało się pobrać listy" --msgbox "list-datasets $HOST:\n\n$(tail -3 "$TMPD/ds.err")" 12 "$W"
        return 1
    fi
    basket_step
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
# "Przegladaj..." (uwaga 1, 2026-10-08): wszystkie SYSTEMY PLIKOW tego hosta, do osobnego
# pliku -- zvol nie moze byc celem.
fs = open(sys.argv[1], "w", encoding="utf-8", newline="\n")
for x in d.get("datasets", []):
    n = x.get("name", "")
    if n and x.get("type", "filesystem") == "filesystem": fs.write(n + "\n")
    if n.count("/") == 1 and n.rsplit("/", 1)[1].lower() in ("backups", "backup", "kopie"): print(n)' "$TMPD/fs.all" | tr -d '\r' >"$TMPD/targets.tsv"
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        case " $seen " in *" $t "*) continue ;; esac
        items+=("$t" "$t   -- istnieje na tym hoście, jeszcze nieużywany"); seen="$seen $t"
        [ -n "$first" ] || first="$t"
    done <"$TMPD/targets.tsv"
    items+=(__browse__ "Przeglądaj…     (wszystkie datasety tego hosta)")
    items+=(__other__ "Wpisz ścieżkę…  (dataset na tym hoście, może jeszcze nie istnieć)")
    if [ -n "$TARGET" ]; then in_list "$TARGET" "${items[@]}" && first="$TARGET" || first=__other__; fi
    # Kopia lokalna nie ma poziomu hosta: ląduje pod <cel>/<pełna ścieżka źródła>.
    local lv="/$HOST"; [ "$MODE" = local ] && lv=""
    while :; do
        geom
        wt --title "$(title 5 'Dokąd na tym hoście?')" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "${first:-__other__}" \
           --menu "Kopie wylądują pod:  <wybrane>$lv/<dataset źródła>\nnp.  ${first:-hdd/backups}$lv/${B_ROOT[0]}" "$(fit $((${#items[@]} / 2 + 4)))" "$W" "$((${#items[@]} / 2))" \
           "${items[@]}" || return 1
        if [ "$WT_OUT" = __browse__ ]; then
            browse_target && return 0
            continue
        fi
        if [ "$WT_OUT" != __other__ ]; then TARGET="$WT_OUT"; return 0; fi
        wt --title "$(title 5 'Dokąd -- wpisz ścieżkę')" --ok-button "Dalej" --cancel-button "Wstecz" \
           --inputbox "Dataset na TYM hoście, pod którym mają lądować kopie (np. hdd/backups).\nKopie trafią pod:  <to>$lv/<dataset źródła>" 11 "$W" "$TARGET" || continue
        t="${WT_OUT// /}"
        case "$t" in ''|/*|*/|*[!A-Za-z0-9._:/-]*) wt --title "Zła ścieżka" --msgbox "'$WT_OUT' nie wygląda na nazwę datasetu (pula/nazwa, bez / na początku i końcu)." 9 "$W"; continue ;; esac
        TARGET="$t"; return 0
    done
}
# "Przegladaj..." (uwaga 1): plaska lista systemow plikow tego hosta, wciecie wg glebokosci.
# Ukryte sa wnetrza ladowisk innych relacji (<cel>/<peer>/...): wybor tam i tak odrzucilby
# straznik pokrycia kilka krokow dalej. 0 = TARGET ustawiony, 1 = wstecz do listy.
browse_target() {
    local items=() n t p hid=0 skip d ind _rn _st
    [ -s "$TMPD/fs.all" ] || { wt --title "Brak listy" --msgbox "Nie udało się odczytać datasetów tego hosta (list-datasets)." 8 "$W"; return 1; }
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        skip=0
        while IFS=$'\t' read -r _rn p t _st; do
            case "$t" in ''|-) continue ;; esac
            case "$n" in "$t/$p"|"$t/$p"/*) skip=1; break ;; esac
        done <"$TMPD/rel.tsv"
        [ "$skip" -eq 1 ] && { hid=$((hid + 1)); continue; }
        d="${n//[!/]/}"; ind="$(printf '%*s' $((${#d} * 2)) '')"
        items+=("$n" "$(clip_label "$ind$n" $((W - 10)))")
    done <"$TMPD/fs.all"
    [ "${#items[@]}" -gt 0 ] || { wt --title "Brak datasetów" --msgbox "Na tym hoście nie ma datasetu, pod którym mogłyby lądować kopie." 8 "$W"; return 1; }
    local note=""; [ "$hid" -gt 0 ] && note="\nUkryto $hid kopii innych relacji."
    geom
    wt --title "$(title 5 'Dokąd -- przeglądaj')" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
       --menu "Datasety tego hosta. Kopie trafią pod:  <wybrany>/$HOST/<dataset źródła>$note" \
       "$H" "$W" "$(lhfit $((${#items[@]} / 2)) 4)" "${items[@]}" || return 1
    TARGET="$WT_OUT"
    return 0
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
    mech = {"flat": "N najnowszych", "gfs": "GFS", "age": "wg wieku"}.get(p.get("mechanism", ""), p.get("mechanism") or "?")
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
# ograniczenie: [drabina] (default, Y5M12D31H24, passive).
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
sync_from_chain() {   # -> 0, gdy synchro i któryś korzeń koszyka ma własne migawki
    [ "$MODE" = sync ] || return 1
    local r n c
    for r in ${B_ROOT[@]+"${B_ROOT[@]}"}; do
        while IFS=$'\t' read -r n c; do
            [ "$n" = "$r" ] || continue
            case "$c" in ''|*[!0-9]*) c=0 ;; esac
            [ "$c" -gt 0 ] && return 0
        done <"$TMPD/own.tsv" 2>/dev/null
    done
    return 1
}
REC_PROFILE=passive-flat
# Domyślna nazwa relacji (krok 7 proponuje to samo) -- od niej nazwa szkicu "Ręcznie".
rname_default() {
    if [ -n "$RNAME" ]; then echo "$RNAME"
    elif [ "$MODE" = local ]; then echo "lokalna-$(printf '%s' "${B_ROOT[0]:-kopia}" | tr '/' '-')"
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
    ZFS_BACKUP="$ZB" bash "$HERE/tui/template.sh" relation "$base" "$TMPD/margs" "$(title 6 'Ręcznie: jak długo trzymać w celu')" || return 1
    local -a margs=(); mapfile -t margs <"$TMPD/margs"
    info "$(title 6 'Ręcznie')" "Zapisuję ustawienia relacji..."
    out=$("$ZB" save-profile "--from=$base" "--as=$hn" --hidden --force ${margs[@]+"${margs[@]}"} "--description=Własne ustawienia relacji (kreator)" 2>&1) \
        || { wt --title "Czasownik odmówił -- nic nie zapisano" --msgbox "$(printf '%s' "$out" | grep -E 'FATAL' | tail -1 | sed 's/^FATAL: //' | fold -s -w $((W - 6)))" 14 "$W"; return 1; }
    [ -n "$MANUAL_P" ] && [ "$MANUAL_P" != "$hn" ] && "$ZB" delete-profile "$MANUAL_P" --yes >/dev/null 2>&1
    MANUAL_P="$hn"; PROFILE="$hn"
    rm -f "$TMPD/prof.tsv"; load_profiles
    return 0
}
step_profile() {
    local items=() n w c q f sh hd def label chain=0 lead=""
    geom
    [ -s "$TMPD/prof.tsv" ] || info "$(title 6 'Szablon')" "Czytam szablony retencji..."
    if ! load_profiles; then
        wt --title "$(title 6 'Szablon -- lista niedostępna')" --ok-button "Dalej" --cancel-button "Wstecz" \
           --inputbox "list-profiles nie odpowiedział ($(tail -1 "$TMPD/prof.err" 2>/dev/null)).\nWpisz nazwę szablonu ręcznie (domyślny: default)." 11 "$W" "${PROFILE:-default}" || return 1
        PROFILE="${WT_OUT// /}"; [ -n "$PROFILE" ] || PROFILE=default; FREEZE=1; return 0
    fi
    items=(__manual__ "$(clip_label "$(printf '%-15s %s' 'Ręcznie…' 'tabela szczebli: sposób, szczeble, liczby, zamrażanie')" $((W - 10)))")
    sync_from_chain && chain=1
    while IFS=$'\t' read -r n w c q f sh hd; do
        [ -n "$n" ] || continue
        [ "${hd:-0}" = 1 ] && continue
        # ZNACZNIKI ZARAZ ZA NAZWĄ, opis retencji na końcu: przy przycięciu
        # wiersza do okna (U5) ginie koniec opisu, nigdy [zamraża]/[drabina]/[polecany]
        # -- to one rozstrzygają wybór (kroki 8 i 9).
        local marks=""
        [ "$chain" -eq 1 ] && [ "$n" = "$REC_PROFILE" ] && marks="${marks}[polecany] "
        [ "$f" = 1 ] && marks="${marks}[zamraża] "
        [ "$sh" = ladder ] && marks="${marks}[drabina] "
        label="$(printf '%-15s %s%s' "$n" "$marks" "$w")"
        # Ta sama ramka co w kroku 9 (U5): w 80 kolumnach wiersze szablonów z
        # [zamraża] [drabina] były szersze niż okno i ucinały jej prawy bok.
        items+=("$n" "$(clip_label "$label" $((W - 10)))")
    done <"$TMPD/prof.tsv"
    def=default
    if [ "$chain" -eq 1 ] && in_list "$REC_PROFILE" "${items[@]}"; then
        def="$REC_PROFILE"
        lead="Źródło ma już własne migawki (łańcuch): polecany $REC_PROFILE --\nodbiera każdą rodzinę źródła i niczego tam nie tworzy.\n\n"
    fi
    local tl=6; [ -n "$lead" ] && tl=9    # trzy linie wstępu więcej nad listą
    in_list "$PROFILE" "${items[@]}" && def="$PROFILE"
    [ -n "$MANUAL_P" ] && [ "$PROFILE" = "$MANUAL_P" ] && def=__manual__
    in_list "$def" "${items[@]}" || def="${items[2]}"
    geom
    wt --title "$(title 6 'Jak długo trzymać w celu (na tym hoście)?')" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$def" \
       --menu "${lead}Wszystkie szablony retencji. [zamraża] = zamraża gościa przed migawkami\ndobowymi i rzadszymi (zgoda źródła -- krok 9). [drabina] = JEDNA drabina GFS\ndla jednej rodziny, w osobnej sekcji; pozostałe trzymają retencję w każdym\nszczeblu. [drabina] nie wejdzie na konto, na którym już działa szablon z retencją\nw szczeblach (sprawdzane po wyborze konta w kroku 8). Szablon da się zmienić później." "$H" "$W" "$(lhfit $((${#items[@]} / 2)) "$tl")" \
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
step_name() {
    local n
    if [ -z "$RNAME" ] && [ "$MODE" = local ]; then
        RNAME="lokalna-$(printf '%s' "${B_ROOT[0]:-kopia}" | tr '/' '-')"
    fi
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
        # Nazwa USUNIĘTEJ relacji jest wolna: add-client archiwizuje jej stary rekord
        # (<nazwa>.conf.removed-<czas>) i plan to mówi. Dawniej kreator kazał ją
        # najpierw „zwolnić” przez delete-relation -- zbędny krok, który na pve9b nie
        # przechodził (uwaga 11, 2026-10-08).
        RNAME="$n"
        # Szkic "Ręcznie" nazywa się jak relacja: relacja-<NAZWA>.
        if [ -n "$MANUAL_P" ] && [ "$MANUAL_P" != "relacja-$RNAME" ]; then
            if "$ZB" save-profile "--from=$MANUAL_P" "--as=relacja-$RNAME" --hidden --force "--description=Własne ustawienia relacji $RNAME" >/dev/null 2>"$TMPD/mv.err"; then
                "$ZB" delete-profile "$MANUAL_P" --yes >/dev/null 2>&1
                MANUAL_P="relacja-$RNAME"; PROFILE="$MANUAL_P"; rm -f "$TMPD/prof.tsv"; load_profiles
            else
                wt --title "Nie udało się przenieść ustawień" --msgbox "$(tail -3 "$TMPD/mv.err")" 12 "$W"; continue
            fi
        fi
        return 0
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
            wt --title "Szablon nie pasuje do konta" --msgbox "Na koncie ${acct_name:-root} już działają relacje z retencją W SZCZEBLACH\n(każdy szczebel przycina się sam) -- to jest jego config. Szablonu [drabina]\n(jedna drabina GFS w osobnej sekcji) nie da się do niego dodać, czasownik\nby to odmówił ('This host reads as FLAT').\n\nWybierz inne konto, albo Wstecz do kroku 6 po szablon bez znacznika [drabina]." "$(fit 8)" "$W"
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
    local items=() on_grant=OFF on_q=OFF on_man=OFF
    local want_masks=0 defmask="__replicate_,vzdump,__migration__"
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
        [ "$MODE" = local ] || items=(grant "Prawa na źródle nadaj stąd (SSH jako root)" "$on_grant")
        if [ "$MODE" != local ] && [ "$FREEZE" -eq 1 ] && [ "$GRANT" -eq 1 ]; then
            items+=(quies "Nadaj też zgodę na zamrażanie gości" "$on_q")
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
            items+=(masks "Zmień listę pomijanych migawek" OFF)
        else
            items+=(masks "Pomijane: ${EXFAM:-żadne, kopiowane wszystkie} (zmień)" ON)
        fi
        [ "$MODE" = local ] || items+=(man "Parowanie ręczne: paczka do przeniesienia" "$on_man")
        local _i
        for ((_i=1; _i<${#items[@]}; _i+=3)); do items[_i]="$(clip_label "${items[_i]}" $((W - 14)))"; done
        local _xh="Domyślne są dobre dla zwykłej relacji. SPACJA przełącza, ENTER = Dalej.\n\nPrawa stąd: bez nich instalacja stanie i poda polecenie dla źródła.\nZamrażanie: bez zgody migawki dobowe i rzadsze wyjdą jako '_crash_'.\nParowanie ręczne: gdy ten host nie ma wstępu po SSH do źródła."
        [ "$MODE" = local ] && _xh="Domyślne są dobre. SPACJA przełącza, ENTER = Dalej."
        wt --title "$(title 9 'Ustawienia dodatkowe')" --ok-button "Dalej" --cancel-button "Wstecz" --notags --separate-output \
           --checklist "$_xh" "$(fit $((${#items[@]} / 3 + 11)))" "$W" "$((${#items[@]} / 3))" \
           "${items[@]}" || return 1
        GRANT=0; GQUIESCE=0; MANUAL=0; want_masks=0
        local keep_skip=0 x
        while IFS= read -r x; do
            case "$x" in
                grant) GRANT=1 ;;
                quies) GQUIESCE=1 ;;
                skip)  keep_skip=1 ;;
                masks) want_masks=1 ;;
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
        # Retencja źródła: zawsze jedno pytanie "tyle samo co tutaj?" (uwaga 2,
        # 2026-10-09) zamiast pozycji na liście i menu szczebli z "Gotowe".
        if [ "$RECURSION" != atomic ] && [ -s "$TMPD/prof.json.tiers" ]; then
            SRC_TITLE="$(title 9 "Jak długo trzymać u źródła ($HOST)?")"
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
        local IFS=,; for p in $base; do [ -n "$p" ] && items+=("$p" "$p" ON); done; unset IFS
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
    if [ "$MODE" = local ]; then
        # Kopia lokalna = istniejący wsad local-backup: --source bez hosta, drzewo -R.
        ARGV=("$ZB" "--source=${B_ROOT[*]}" "--target=$TARGET" "--recursive=flat")
    else
        ARGV=("$ZB" "--source=$(hostport):${B_ROOT[*]}")
    fi
    if [ "$MODE" = sync ]; then ARGV+=("--mode=sync"); elif [ "$MODE" != local ]; then ARGV+=("--target=$TARGET"); fi
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
    if [ "$MODE" = local ]; then
        echo "LOKALNIE: $(hostname) kopiuje u siebie do $TARGET/<źródło>:"
    elif [ "$MODE" = sync ]; then
        echo "LUSTRO: $(hostname) i $HOST${HOSTNAME_R:+ ($HOSTNAME_R)} będą trzymać to samo pod tą samą ścieżką:"
    else
        echo "BACKUP: $(hostname) będzie POBIERAĆ z $HOST${HOSTNAME_R:+ ($HOSTNAME_R)} do $TARGET/$HOST/..."
    fi
    for i in "${!B_ROOT[@]}"; do echo "    ${B_ROOT[$i]}  -- $(describe "$i")"; done
    echo "Sposób:  $(mode_words).   Nazwa: $RNAME.   Konto: ${a:-root}."
    echo "Szablon: $( [ -n "$MANUAL_P" ] && [ "$PROFILE" = "$MANUAL_P" ] && echo "Ręcznie -- $PROFILE" || echo "$PROFILE")$( [ -s "$TMPD/prof.tsv" ] && awk -F'\t' -v n="$PROFILE" '$1==n{print "  (" $3 "; " $2 "; " $4 ")"}' "$TMPD/prof.tsv")$( [ -n "$SRCPROF" ] && echo "; u źródła: $SRCPROF")"
    if [ -n "$EXFAM" ]; then echo "Pomijane migawki z prefiksami: ${EXFAM//,/, }."
    else echo "Pomijane migawki: żadne (kopiowane wszystkie)."; fi
    [ "$RECURSION" = atomic ] && echo "U ŹRÓDŁA migawek nie sprząta nikt (tak działa atomowo) -- trzeba samemu."
    if [ "$MODE" = local ]; then
        [ "$FREEZE" -eq 1 ] && echo "Zamrażanie: goście tego hosta, przed migawkami dobowymi i rzadszymi."
        echo
        echo "Komenda (to samo wpisałbyś z palca):"
        cmd_oneline; echo
        any_excl && echo "(^nazwa${D:-\$} = dokładnie ten dataset, nie łapie np. ...disk-01)"
        return 0
    fi
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
    info "$(title 10 'Plan')" "Sprawdzam, czy inny kolektor nie przycina już tych datasetów..."
    if ! "$ZB" source-pruners "$(hostport)" "${B_ROOT[@]}" >"$TMPD/pruners.tsv" 2>"$TMPD/pruners.err"; then
        wt --title "Nie sprawdzono innych kolektorów" --msgbox "source-pruners nie odpowiedział:\n$(tail -2 "$TMPD/pruners.err")\n\nAktywacja i tak to sprawdzi -- przed instalacją crona." 12 "$W"
        return 0
    fi
    [ -s "$TMPD/pruners.tsv" ] || return 0
    local lst; lst=$(awk -F'\t' '{printf "    %s  -- %s\n", $1, $2}' "$TMPD/pruners.tsv")
    geom
    wt --title "Inny kolektor już przycina te datasety" --notags --ok-button "Dalej" --cancel-button "Wstecz" \
       --menu "Na $HOST migawki tych datasetów może już kasować inny kolektor:\n$lst\nDwie retencje na jednym źródle kasują sobie nawzajem bazy -- aktywacja odmówi.\nAlbo usuń tamtą relację (na tamtym kolektorze), albo:" "$H" "$W" 2 \
       pasywnie "Pasywnie -- bez retencji u źródła (szablon passive)" \
       datasety "Inne datasety -- wróć do wyboru" || return 1
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
        build_argv install
        summary_text >"$TMPD/summary.txt"
        yesno_text "$TMPD/summary.txt" "$(title 10 'Podsumowanie')" "Pokaż plan" "Wstecz" || return 1
        check_pruners; rc=$?
        case "$rc" in 0) ;; 1) continue ;; *) return "$rc" ;; esac
        build_argv
        info "$(title 10 'Plan')" "Pytam czasownik o plan (nic nie zmienia)..."
        "${ARGV[@]}" >"$TMPD/plan.txt" 2>&1; rc=$?
        # R2-2 (właściciel, 2026-09-24): to okno ma pokazać, CO się wykona po WYKONAJ -- pełną
        # komendę i decyzje po polsku -- a dopiero pod spodem plan czasownika. Wcześniej było
        # tu tylko angielskie "RUX plan" bez komendy, retencji źródła, pomijanych i konta.
        # Linia "--grant-remotely is noted, but --plan is read-only" myliła (grant NASTĄPI
        # po WYKONAJ), więc jej tu nie ma.
        { echo "Po WYKONAJ uruchomi się DOKŁADNIE:"
          build_argv install; cmd_oneline; echo; build_argv
          echo
          echo "Cel: ${TARGET:-(lustro: ta sama ścieżka)}.  Trzyma tutaj: $PROFILE.  U źródła: ${SRCPROF:-jak tutaj}."
          if [ -n "$EXFAM" ]; then echo "Pomijane migawki z prefiksami: ${EXFAM//,/, }."
          else echo "Pomijane migawki: żadne (kopiowane wszystkie)."; fi
          echo "Konto: $(a="$(account_name)"; echo "${a:-root}")."
          echo
          echo "Plan czasownika -- nic jeszcze nie zostało zmienione (rc=$rc):"
          grep -v -- '--grant-remotely is noted' "$TMPD/plan.txt"; } >"$TMPD/plan2.txt"
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
        [ "$RC_RUN" -eq 0 ] && NR_DONE=1
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
        mode)    if step_mode;     then [ "$MODE" = local ] && step=ds || step=host
                 else clear 2>/dev/null; echo "new-relation: przerwane, nic nie zmieniono"; exit 1; fi ;;
        host)    if step_host;     then step=diag;    else step=mode; fi ;;
        diag)    if step_diag;     then step=ds;      else step=host; fi ;;
        ds)      if step_datasets; then step=target;  else [ "$MODE" = local ] && step=mode || step=host; fi ;;
        target)  if step_target;   then step=profile; else step=ds; fi ;;
        profile) if step_profile;  then step=name;    else [ "$MODE" = sync ] && step=ds || step=target; fi ;;
        name)    if step_name;     then step=acct;    else step=profile; fi ;;
        acct)    if step_account;  then step=extra;   else step=name; fi ;;
        extra)   if step_extra;    then step=summary; else step=acct; fi ;;
        summary) step_summary
                 case $? in 0) break ;; 2) step=ds ;; 3) step=profile ;; *) step=extra ;; esac ;;
    esac
done
exit "$RC_RUN"
