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
WT_BACKTITLE="Ustawienia hosta -- $(hostname)"
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

geom
info "Ustawienia" "Czytam ustawienia hosta..."
"$ZB" settings --tsv >"$TMPD/rows.tsv" 2>"$TMPD/err" || {
    wt --title "Ustawienia" --msgbox "Nie mogę odczytać ustawień: $(tail -2 "$TMPD/err")" 10 "$W"; exit 1; }

declare -A VAL SRC KIND HELP NEW
KEYS=()
while IFS=$'\t' read -r k v s kind help; do
    [ -n "$k" ] || continue
    KEYS+=("$k"); VAL[$k]="$v"; SRC[$k]="$s"; KIND[$k]="$kind"; HELP[$k]="$help"
done <"$TMPD/rows.tsv"
[ "${#KEYS[@]}" -gt 0 ] || { wt --title "Ustawienia" --msgbox "Czasownik nie zwrócił żadnego klucza." 8 "$W"; exit 1; }

SECT_PL() { case "$1" in gui) echo "GUI" ;; alerts) echo "Alerty" ;; capacity) echo "Pojemność" ;; growth) echo "Przyrost (ransomware)" ;; replica) echo "Replika (dysk wymienny)" ;;
            monitor) echo "Strażnik" ;; new_relation) echo "Nowa relacja" ;; update) echo "Aktualizacja" ;; *) echo "$1" ;; esac; }

edit_key() {   # <key> -> NEW[key] ustawione albo bez zmian
    local k="$1" cur kind opts=() o
    cur="${NEW[$k]:-${VAL[$k]}}"; kind="${KIND[$k]}"
    geom
    case "$kind" in
        enum:*)
            for o in $(printf '%s' "${kind#enum:}" | tr ',' ' '); do
                opts+=("$o" "$o" "$([ "$o" = "$cur" ] && echo ON || echo OFF)")
            done
            wt --title "$k" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
               --radiolist "${HELP[$k]}" "$(fit $((${#opts[@]} / 3 + 2)))" "$W" "$(lhfit $((${#opts[@]} / 3)) 2)" "${opts[@]}" || return 0 ;;
        *)
            wt --title "$k" --ok-button "Dalej" --cancel-button "Wstecz" \
               --inputbox "${HELP[$k]}" 10 "$W" "$cur" || return 0 ;;
    esac
    [ -n "$WT_OUT" ] || return 0
    if [ "$WT_OUT" = "${VAL[$k]}" ]; then unset "NEW[$k]"; else NEW[$k]="$WT_OUT"; fi
}

save() {   # plan czasownika, potem WYKONAJ
    local args=() k
    for k in "${KEYS[@]}"; do [ -n "${NEW[$k]+x}" ] && args+=("$k=${NEW[$k]}"); done
    if [ "${#args[@]}" -eq 0 ]; then
        geom; wt --title "Ustawienia" --msgbox "Nic nie zmieniono -- nie ma czego zapisać." 8 "$W"; return 1
    fi
    "$ZB" settings set "${args[@]}" >"$TMPD/plan.txt" 2>&1 || {
        geom; wt --title "Czasownik odmówił -- nic nie zapisano" --msgbox "$(grep -E '^FATAL' "$TMPD/plan.txt" | tail -1 | sed 's/^FATAL: //')" 10 "$W"; return 1; }
    { echo "PLAN -- nic jeszcze nie zostało zmienione:"; echo; grep -v '^plan only' "$TMPD/plan.txt"; echo
      printf 'Komenda:  %s settings set' "$(shq "$ZB")"; for a in "${args[@]}"; do printf ' %s' "$(shq "$a")"; done; echo " --yes"; } >"$TMPD/plan2.txt"
    yesno_text "$TMPD/plan2.txt" "Ustawienia -- plan" "WYKONAJ" "Wstecz" --defaultno || return 1
    clear 2>/dev/null
    printf '$ %s settings set' "$ZB"; printf ' %s' "${args[@]}"; echo " --yes"; echo
    "$ZB" settings set "${args[@]}" --yes 2>&1 | tee "$TMPD/run.log"; RC=${PIPESTATUS[0]}
    [ -n "${ZFS_TUI_LOG:-}" ] && { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null
    echo
    if [ "$RC" -eq 0 ]; then echo "=== GOTOWE (rc=0). Enter = powrót do GUI"
    else echo "=== NIE WYSZŁO (rc=$RC) -- komunikat powyżej. Enter = powrót do GUI"; fi
    read -r _ </dev/tty 2>/dev/null || true
    exit "$RC"
}

LAST="${KEYS[0]}"
while :; do
    geom
    items=(); prev=""
    for k in "${KEYS[@]}"; do
        sec="${k%%.*}"
        # Znacznik nagłówka NIE może zaczynać się od '-': whiptail czyta "--alerts" jako swoją
        # opcję ("unknown option") i okno znika od razu (właściciel, pve10 2026-10-19).
        if [ "$sec" != "$prev" ]; then items+=("#$sec" "── $(SECT_PL "$sec") ──"); prev="$sec"; fi
        if [ -n "${NEW[$k]+x}" ]; then v="${NEW[$k]}  (było ${VAL[$k]})"; else v="${VAL[$k]}"; [ "${SRC[$k]}" = plik ] || v="$v  (${SRC[$k]})"; fi
        items+=("$k" "$(clip_label "$(printf '%-14s %s' "${k#*.}" "$v")" $((W - 10)))")
    done
    n=0; for k in "${KEYS[@]}"; do [ -n "${NEW[$k]+x}" ] && n=$((n + 1)); done
    items+=(mail "Wyślij mail próbny (na obecny adres)" zapisz "Zapisz zmiany ($n) -- plan, WYKONAJ")
    wt --title "Ustawienia hosta" --ok-button "Wybierz" --cancel-button "Wyjdź" --notags --default-item "$LAST" \
       --menu "Pozycja zmienia jedną wartość; nic nie jest zapisane przed WYKONAJ. W nawiasie: skąd jest wartość, gdy nie z pliku ustawień." \
       "$H" "$W" "$(lhfit $((${#items[@]} / 2)) 2)" "${items[@]}" \
       || { clear 2>/dev/null; echo "settings: wyjście, nic nie zapisano"; exit 1; }
    LAST="$WT_OUT"
    case "$WT_OUT" in
        \#*) ;;
        mail)
            clear 2>/dev/null
            "$ZB" settings test-mail 2>&1; echo; echo "Enter = powrót do ustawień"
            read -r _ </dev/tty 2>/dev/null || true ;;
        zapisz) save || : ;;
        *) edit_key "$WT_OUT" ;;
    esac
done
