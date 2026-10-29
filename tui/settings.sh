#!/bin/bash
# settings.sh -- okno "Ustawienia" (F10 w GUI) nad plikiem ustawień hosta.
#
# Właściciel 2026-10-19: "nowy plik ustawień z sekcjami", "ustawienia F10". Okno NIE ma
# własnej logiki: listę kluczy, wartości i ich źródło bierze z `zfs-backup.sh settings
# --tsv`, zmiany zbiera na liście (jak zmiana repliki, U8), a "Zapisz" pokazuje PLAN
# `settings set K=V ...` i po WYKONAJ uruchamia go z --yes. Walidacja, zapis pliku i
# przeliczenie crona są w czasowniku. "Mail próbny" = `settings test-mail`.
#
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "settings: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
WT_BACKTITLE="$(T 'Ustawienia hosta -- %s' "$(hostname)")"
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

geom
info "$(T Ustawienia)" "$(T 'Czytam ustawienia hosta...')"
"$ZB" settings --tsv >"$TMPD/rows.tsv" 2>"$TMPD/err" || {
    wt --title "$(T Ustawienia)" --msgbox "$(Tv 'Nie mogę odczytać ustawień: $ERR' '$ERR' "$(tail -2 "$TMPD/err")")" 10 "$W"; exit 1; }

declare -A VAL SRC KIND HELP NEW
KEYS=()
while IFS=$'\t' read -r k v s kind help; do
    [ -n "$k" ] || continue
    KEYS+=("$k"); VAL[$k]="$v"; SRC[$k]="$s"; KIND[$k]="$kind"; HELP[$k]="${TCAT[$help]-$help}"   # opis z rejestru czasownika = dane; tłumaczony jako klucz katalogu
done <"$TMPD/rows.tsv"
[ "${#KEYS[@]}" -gt 0 ] || { wt --title "$(T Ustawienia)" --msgbox "$(T 'Czasownik nie zwrócił żadnego klucza.')" 8 "$W"; exit 1; }

SECT_PL() { case "$1" in gui) echo "GUI" ;; alerts) T Alerty ;; capacity) T Pojemność ;; growth) T 'Przyrost (ransomware)' ;; replica) T 'Replika (dysk wymienny)' ;;
            monitor) T Strażnik ;; new_relation) T 'Nowa relacja' ;; update) T Aktualizacja ;; *) echo "$1" ;; esac; }

edit_key() {   # <key> -> NEW[key] ustawione albo bez zmian
    local k="$1" cur kind opts=() o
    cur="${NEW[$k]:-${VAL[$k]}}"; kind="${KIND[$k]}"
    geom
    case "$kind" in
        enum:*)
            for o in $(printf '%s' "${kind#enum:}" | tr ',' ' '); do
                opts+=("$o" "$o")
            done
            # Menu, nie radiolista: w radioliście Enter bierze zaznaczoną kropkę, nie podświetloną
            # pozycję (kampania 2026-10-22) -- jednolicie z kreatorem i odzyskiem.
            wt --title "$k" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" --notags --default-item "$cur" \
               --menu "${HELP[$k]}" "$(fit $((${#opts[@]} / 2 + 6)))" "$W" "$(lhfit $((${#opts[@]} / 2)) 2)" "${opts[@]}" || return 0 ;;
        profile)
            # U54 (właściciel, A.4 2026-10-21: "pole wpisywane -- łatwo o błąd; wybór z listy
            # szablonów poproszę"): lista z list-profiles, bez ukrytych i pochodnych (-src-).
            "$ZB" list-profiles --json --no-render 2>/dev/null | "$PY" -c '
import json, sys, os
_C = json.load(open(os.environ["ZFS_TUI_CAT"], encoding="utf-8")) if os.environ.get("ZFS_TUI_CAT") else {}
def _(s): return _C.get(s, s)
d = json.load(sys.stdin)
rows = [p for p in d.get("profiles") or [] if not p.get("hidden") and "-src-" not in (p.get("name") or "")]
rows.sort(key=lambda p: (p.get("source") != "package", p.get("name") != "default", p.get("name") or ""))
for p in rows:
    own = "" if p.get("source") == "package" else _("  [własny]")
    print("%s\t%s%s" % (p.get("name"), _(p.get("description") or "").replace("\t", " "), own))
' | tr -d '\r' >"$TMPD/prof.tsv"
            [ -s "$TMPD/prof.tsv" ] || { wt --title "$k" --msgbox "$(T 'Nie mogę odczytać listy szablonów (list-profiles).')" 8 "$W"; return 0; }
            local n d
            while IFS=$'\t' read -r n d; do
                opts+=("$n" "$(clip_label "$(printf '%-16s %s' "$n" "$d")" $((W - 12)))")
            done <"$TMPD/prof.tsv"
            awk -F'\t' -v c="$cur" '$1==c{f=1} END{exit !f}' "$TMPD/prof.tsv" || cur="$(head -n 1 "$TMPD/prof.tsv" | cut -f1)"
            wt --title "$k" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" --notags --default-item "$cur" \
               --menu "${HELP[$k]}" "$(fit $((${#opts[@]} / 2 + 7)))" "$W" "$(lhfit $((${#opts[@]} / 2)) 2)" "${opts[@]}" || return 0 ;;
        *)
            wt --title "$k" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" \
               --inputbox "${HELP[$k]}" 10 "$W" "$cur" || return 0 ;;
    esac
    [ -n "$WT_OUT" ] || return 0
    if [ "$WT_OUT" = "${VAL[$k]}" ]; then unset "NEW[$k]"; else NEW[$k]="$WT_OUT"; fi
}

save() {   # plan czasownika, potem WYKONAJ
    local args=() k
    for k in "${KEYS[@]}"; do [ -n "${NEW[$k]+x}" ] && args+=("$k=${NEW[$k]}"); done
    if [ "${#args[@]}" -eq 0 ]; then
        geom; wt --title "$(T Ustawienia)" --msgbox "$(T 'Nic nie zmieniono -- nie ma czego zapisać.')" 8 "$W"; return 1
    fi
    "$ZB" settings set "${args[@]}" >"$TMPD/plan.txt" 2>&1 || {
        geom; wt --title "$(T 'Czasownik odmówił -- nic nie zapisano')" --msgbox "$(verb_refusal "$TMPD/plan.txt")" 10 "$W"; return 1; }
    { T 'PLAN -- nic jeszcze nie zostało zmienione:'; echo; echo; grep -v '^plan only' "$TMPD/plan.txt"; echo
      printf '%s  %s settings set' "$(T 'Komenda:')" "$(shq "$ZB")"; for a in "${args[@]}"; do printf ' %s' "$(shq "$a")"; done; echo " --yes"; } >"$TMPD/plan2.txt"
    yesno_text "$TMPD/plan2.txt" "$(T 'Ustawienia -- plan')" "$(T WYKONAJ)" "$(T Wstecz)" --defaultno || return 1
    : >"$TMPD/run.log"
    RC=0; run_progress "$(T Ustawienia)" "$TMPD/run.log" "$ZB" settings set "${args[@]}" --yes || RC=$?
    [ -n "${ZFS_TUI_LOG:-}" ] && { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null
    if [ "$RC" -eq 0 ]; then
        T 'Zapisano.' >"$TMPD/result.txt"; echo >>"$TMPD/result.txt"
        result_box "$(T 'Ustawienia: GOTOWE')" 0 "$TMPD/run.log" "$(cat "$TMPD/result.txt")"
    else
        T 'Nie zapisano.' >"$TMPD/result.txt"; echo >>"$TMPD/result.txt"
        result_box "$(T Ustawienia)" "$RC" "$TMPD/run.log" "" "$(cat "$TMPD/result.txt")"
    fi
    exit "$RC"
}

# U120: opis klucza jest trzecią kolumną po kluczu (16) i wartości (26); przy limicie 100
# kolumn z wt-lib zostawało mu ~45 znaków i ucinał się w pół słowa. To okno bierze pełną
# szerokość terminala (do 160); klucze zostają nazwami z settings.ini -- to je admin wpisuje.
geom_wide() { local c; geom; c=$(tput cols 2>/dev/null) || c=80; case "$c" in ''|*[!0-9]*) c=80 ;; esac
              W=$((c - 4)); [ "$W" -gt 160 ] && W=160; return 0; }
# Właściciel 2026-10-29 (zrzut F10): „brzydkie i poucinane. Złam linię opisów i zmieść tekst
# w 3 kolumnie. Drugą kolumnę oddal od pierwszej -- zlewa się”. Pozycja menu whiptail ma jedną
# linię, więc dalszy ciąg opisu to osobne pozycje „+klucz” (wybór otwiera to samo ustawienie).
# Łamanie po ZNAKACH (${#}), nie bajtach -- polskie litery mają w UTF-8 po dwa bajty.
wrap_words() {   # <szerokość> <tekst> -> linie
    local w="$1" line="" word; local -a ws
    read -ra ws <<< "$2"          # bez rozwijania * w opisach jako wzorca plików
    for word in "${ws[@]}"; do
        if [ -z "$line" ]; then line="$word"
        elif [ $(( ${#line} + 1 + ${#word} )) -le "$w" ]; then line="$line $word"
        else printf '%s\n' "$line"; line="$word"; fi
    done
    [ -n "$line" ] && printf '%s\n' "$line"
    return 0
}
LAST="${KEYS[0]}"
while :; do
    geom_wide
    items=(); prev=""
    for k in "${KEYS[@]}"; do
        sec="${k%%.*}"
        # Znacznik nagłówka NIE może zaczynać się od '-': whiptail czyta "--alerts" jako swoją
        # opcję ("unknown option") i okno znika od razu (właściciel, pve10 2026-10-19).
        # U53 (właściciel, A.4: "słabo czytelne -- bloki oddziel, dodaj kolumnę z opisem"):
        # pusta linia przed każdą sekcją poza pierwszą, opis klucza jako trzecia kolumna.
        if [ "$sec" != "$prev" ]; then
            [ -n "$prev" ] && items+=("#_$sec" " ")
            items+=("#$sec" "── $(SECT_PL "$sec") ──"); prev="$sec"
        fi
        case "${SRC[$k]}" in default) sw="$(T domyślne)" ;; *) sw="${SRC[$k]}" ;; esac
        if [ -n "${NEW[$k]+x}" ]; then v="${NEW[$k]}  ($(T było) ${VAL[$k]})"; else v="${VAL[$k]}"; [ "${SRC[$k]}" = file ] || v="$v  ($sw)"; fi
        # Wyrównanie po ZNAKACH: printf %-Ns liczy bajty, a "(domyślne)" ma polską literę.
        c1="${k#*.}"; while [ "${#c1}" -lt 18 ]; do c1="$c1 "; done
        c2="$(clip_label "$v" 26)"; while [ "${#c2}" -lt 26 ]; do c2="$c2 "; done
        pad="                                                "          # 18 + 4 + 26 = szerokość kolumn 1-2
        dw=$(( W - 10 - 18 - 4 - 26 - 2 )); [ "$dw" -lt 20 ] && dw=20
        first=1; i=0
        while IFS= read -r dl; do
            if [ "$first" = 1 ]; then items+=("$k" "$c1    $c2  $dl"); first=0
            else i=$((i + 1)); items+=("+$i$k" "$pad  $dl"); fi
        done < <(wrap_words "$dw" "${HELP[$k]}")
        [ "$first" = 1 ] && items+=("$k" "$c1    $c2")
    done
    n=0; for k in "${KEYS[@]}"; do [ -n "${NEW[$k]+x}" ] && n=$((n + 1)); done
    items+=("#_" " " mail "$(T 'Wyślij mail próbny (na obecny adres)')" zapisz "$(Tv 'Zapisz zmiany ($n) -- plan, WYKONAJ' '$n' "$n")")
    wt --title "$(T 'Ustawienia hosta')" --ok-button "$(T Wybierz)" --cancel-button "$(T Wyjdź)" --notags --default-item "$LAST" \
       --menu "$(T 'Wybierz pozycję, aby zmienić jej wartość. Nic nie zostanie zapisane, dopóki nie wybierzesz „Zapisz zmiany” i WYKONAJ. Nawias przy wartości mówi, skąd ona pochodzi, jeśli nie ma jej w pliku ustawień.')" \
       "$H" "$W" "$(lhfit $((${#items[@]} / 2)) 3)" "${items[@]}" \
       || { clear 2>/dev/null; wt_end_nochange "$(T 'Ustawienia: wyjście, nic nie zapisano')"; exit 1; }
    LAST="$WT_OUT"
    case "$WT_OUT" in
        \#*) ;;
        +*) LAST="$(printf '%s' "$WT_OUT" | sed 's/^+[0-9]*//')"; edit_key "$LAST" ;;   # dalszy ciąg opisu = to samo ustawienie
        mail)
            clear 2>/dev/null
            "$ZB" settings test-mail 2>&1; echo; echo "$(T 'Enter = powrót do ustawień')"
            read -r _ </dev/tty 2>/dev/null || true ;;
        zapisz) save || : ;;
        *) edit_key "$WT_OUT" ;;
    esac
done
