#!/bin/bash
# template.sh <new|edit|delete> NAZWA -- szablon retencji w oknach whiptail (F5 Szablony:
# Ins = nowy na podstawie NAZWY, 'e' = zmiana własnego, Del = usunięcie własnego).
#
# Okno NIE ma własnej logiki: pyta o liczby, a zapis robi `zfs-backup.sh save-profile`
# (--from/--as, --tier + --keep albo --retain) i `delete-profile`. Harmonogram i sposób
# trzymania (płaski/wiekowy/GFS) oraz układ szczebli idą z szablonu bazowego -- okno
# pyta tylko o to, ile czego trzymać. Szablon fabryczny jest nie do zmiany ani usunięcia.
#
# Wyjście: 0 = zrobione albo nie było czego robić, 1 = przerwane/nie wyszło, 2 = zły argument.
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka.
set -u

ACTION="${1:-}"; NAME="${2:-}"
case "$ACTION" in new|edit|delete) ;; *) echo "użycie: template.sh <new|edit|delete> NAZWA" >&2; exit 2 ;; esac
[ -n "$NAME" ] || { echo "użycie: template.sh <new|edit|delete> NAZWA" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "template: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
WT_BACKTITLE="Szablony -- kolektor $(hostname)"
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

geom
info "Szablony" "Czytam szablony..."
"$ZB" list-profiles --json --no-render >"$TMPD/p.json" 2>"$TMPD/p.err" || echo '{"profiles":[]}' >"$TMPD/p.json"
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
                                   f(t.get("quiesce")), f(t.get("send_schedule"))]) + "\n")
PYEOF

SRC=""; USED=0; BDESC=""
if [ -s "$TMPD/me.tsv" ]; then
    IFS=$'\t' read -r SRC USED BDESC <"$TMPD/me.tsv"
    SRC="${SRC#\#}"; USED="${USED#\#}"; BDESC="${BDESC#\#}"
else
    wt --title "Szablony" --msgbox "Nie ma szablonu '$NAME'." 8 "$W"
    exit 1
fi
case "$USED" in ''|*[!0-9]*) USED=0 ;; esac

SHADOW_MSG="Plik szablonu '$NAME' w /etc/zfs-snapshot-all/profiles ma nazwę fabrycznego i pakiet go pomija. Zmień nazwę pliku."

label_of() {   # nazwa szczebla -> przymiotnik do pytania
    # Także keep_daily / standard_hourly (szablony z drabiną GFS).
    case "$1" in
        *hourly) echo "godzinowych" ;; *daily) echo "dobowych" ;; *weekly) echo "tygodniowych" ;;
        *monthly) echo "miesięcznych" ;; *yearly|*annual) echo "rocznych" ;; *) echo "$1" ;;
    esac
}

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
    if [ "$RC" -eq 0 ]; then echo "=== GOTOWE: $okmsg (rc=$RC). Enter = dalej"
    else echo "=== NIE UDAŁO SIĘ (rc=$RC) -- powód powyżej. Enter = dalej"; fi
    [ -t 0 ] && read -r _
    exit "$RC"
}

# ---------------------------------------------------------------- usuwanie
if [ "$ACTION" = delete ]; then
    case "$SRC" in
        package) wt --title "Szablon fabryczny" --msgbox "Fabrycznego szablonu nie usuniesz." 8 "$W"; exit 0 ;;
        shadow)  wt --title "Szablon fabryczny" --msgbox "$SHADOW_MSG" 10 "$W"; exit 0 ;;
    esac
    "$ZB" delete-profile "$NAME" >"$TMPD/dplan.txt" 2>&1
    if [ $? -ne 0 ]; then
        tail -5 "$TMPD/dplan.txt" | fold -s -w $((W - 6)) >"$TMPD/why.txt"
        wt --title "Czasownik odmówił -- nic nie zmieniono" --msgbox "$(cat "$TMPD/why.txt")" "$(fit "$(grep -c '' "$TMPD/why.txt")")" "$W"
        exit 1
    fi
    {
        cat "$TMPD/dplan.txt"
        if [ "$USED" -gt 0 ]; then
            echo
            echo "Relacje zbudowane z tego szablonu zostają; ich późniejsze 'Zmień relację -> Szablon' nie będzie miało z czego odświeżyć."
        fi
    } >"$TMPD/dtext.txt"
    yesno_text "$TMPD/dtext.txt" "Usunięcie szablonu $NAME" "Usuń" "Wstecz" --defaultno || exit 1
    run_cmd "szablon '$NAME' usunięty" "$ZB" delete-profile "$NAME" --yes
fi

# ---------------------------------------------------------------- new / edit
if [ "$ACTION" = edit ]; then
    case "$SRC" in
        package) wt --title "Szablon fabryczny" --msgbox "Fabrycznego szablonu '$NAME' nie zmienisz -- Ins na nim tworzy kopię, którą można zmienić." 9 "$W"; exit 0 ;;
        shadow)  wt --title "Szablon fabryczny" --msgbox "$SHADOW_MSG" 10 "$W"; exit 0 ;;
    esac
    NEW="$NAME"
    TITLE="Zmiana szablonu $NAME"
else
    NEW="$NAME-moj"
    TITLE="Nowy szablon na podstawie $NAME"
fi

# Szczeble: TN/TK/TR; pytane (keep albo retain -Litera+liczba): ASK = indeksy.
# ZAMRAŻANIE (właściciel 2026-10-09: "koherentne powinien być checkbox"): TQ = quiesce
# szczebla w bazowym, QON = wybór; pytane są szczeble, które ROBIĄ migawki (mają
# send_schedule) -- tylko tam zamrożenie gościa ma sens.
TN=(); TK=(); TR=(); ASK=(); BASE=(); LET=(); NEWV=(); TQ=(); QON=(); QCAN=()
while IFS=$'\t' read -r _n _k _r _q _s; do
    _n="${_n#\#}"; _k="${_k#\#}"; _r="${_r#\#}"; _q="${_q#\#}"; _s="${_s#\#}"
    [ -n "$_n" ] || continue
    _i=${#TN[@]}
    TN+=("$_n"); TK+=("$_k"); TR+=("$_r"); BASE+=(""); LET+=(""); NEWV+=("")
    TQ+=("$_q"); QON+=("$([ -n "$_q" ] && echo 1 || echo 0)")
    [ -n "$_s" ] && QCAN+=("$_i")
    if [ -n "$_k" ]; then
        BASE[_i]="$_k"; NEWV[_i]="$_k"; ASK+=("$_i")
    elif [[ "$_r" =~ ^-([A-Za-z])([0-9]+)$ ]]; then
        LET[_i]="${BASH_REMATCH[1]}"; BASE[_i]="${BASH_REMATCH[2]}"; NEWV[_i]="${BASH_REMATCH[2]}"; ASK+=("$_i")
    fi
done <"$TMPD/tiers.tsv"
NASK=${#ASK[@]}
DESC="$BDESC"; DESC_TOUCHED=0; [ "$ACTION" = edit ] && DESC_TOUCHED=1

# Opis z wyborów: liczby i zamrażanie, zamiast tekstu bazowego, który po zmianie
# liczb kłamie ("30 dobowych..." przy 14).
auto_desc() {
    local i d="" lbl q=""
    for i in "${ASK[@]}"; do
        lbl="$(label_of "${TN[$i]}")"
        d="$d${d:+ + }${NEWV[$i]}${LET[$i]:+ (wiek)} $lbl"
    done
    for i in ${QCAN[@]+"${QCAN[@]}"}; do [ "${QON[$i]}" = 1 ] && q="$q${q:+, }$(label_of "${TN[$i]}")"; done
    printf '%s; %s' "${d:-bez zmian w liczbach}" "$([ -n "$q" ] && echo "zamraża: $q" || echo "bez zamrażania")"
}

# kroki: 0 = nazwa (tylko new), 1..NASK = szczeble, NASK+1 = zamrażanie (gdy jest co
# zamrażać), NASK+2 = opis, NASK+3 = plan
step=0; [ "$ACTION" = edit ] && step=1
QSTEP=$((NASK + 1)); DESCSTEP=$((NASK + 2)); PLANSTEP=$((NASK + 3))
ARGV=(); TARGS=()

while :; do
    geom
    if [ "$step" -eq 0 ]; then
        wt --title "$TITLE" --ok-button "Dalej" --cancel-button "Wstecz" \
           --inputbox "Nazwa nowego szablonu (litery, cyfry, . _ -). Nie może być nazwą fabrycznego." 9 "$W" "$NEW" \
           || { clear 2>/dev/null; echo "template: przerwane, nic nie zmieniono"; exit 1; }
        n="${WT_OUT// /}"
        case "$n" in ''|*[!A-Za-z0-9._-]*) wt --title "Zła nazwa" --msgbox "'$WT_OUT' -- tylko litery, cyfry, kropka, minus, podkreślenie." 8 "$W"; continue ;; esac
        if grep -qxF -- "$n" "$TMPD/names.txt"; then
            wt --title "Nazwa zajęta" --msgbox "Szablon '$n' już jest." 8 "$W"; NEW="$n"; continue
        fi
        NEW="$n"; step=1
        continue
    fi

    if [ "$step" -ge 1 ] && [ "$step" -le "$NASK" ]; then
        i="${ASK[$((step - 1))]}"
        lbl="$(label_of "${TN[$i]}")"
        lead=""; [ "$step" -eq 1 ] && lead="Harmonogram i sposób trzymania są z szablonu bazowego.\n\n"
        if wt --title "$TITLE -- $lbl" --ok-button "Dalej" --cancel-button "Wstecz" \
              --inputbox "${lead}Ile $lbl trzymać? (w bazowym: ${BASE[$i]})" "$([ "$step" -eq 1 ] && echo 11 || echo 9)" "$W" "${NEWV[$i]}"; then
            v="${WT_OUT// /}"
            case "$v" in
                ''|*[!0-9]*|0|0[0-9]*) wt --title "To nie liczba" --msgbox "Podaj liczbę całkowitą większą od zera." 8 "$W"; continue ;;
            esac
            NEWV[i]="$v"; step=$((step + 1))
        else
            if [ "$step" -eq 1 ]; then
                if [ "$ACTION" = edit ]; then clear 2>/dev/null; echo "template: przerwane, nic nie zmieniono"; exit 1; fi
                step=0
            else
                step=$((step - 1))
            fi
        fi
        continue
    fi

    if [ "$step" -eq "$QSTEP" ]; then
        if [ "${#QCAN[@]}" -eq 0 ]; then step=$DESCSTEP; continue; fi
        items=()
        for i in "${QCAN[@]}"; do
            items+=("$i" "$(label_of "${TN[$i]}")  (w bazowym: $([ -n "${TQ[$i]}" ] && echo tak || echo nie))" "$([ "${QON[$i]}" = 1 ] && echo ON || echo OFF)")
        done
        if wt --title "$TITLE -- zamrażanie gości" --ok-button "Dalej" --cancel-button "Wstecz" --notags --separate-output \
              --checklist "Które szczeble zamrażają gości przed migawką (spójne migawki)?\nSPACJA zaznacza, ENTER = Dalej. Zamrażanie potrzebuje zgody źródła." \
              "$(fit $((${#QCAN[@]} + 8)))" "$W" "${#QCAN[@]}" "${items[@]}"; then
            for i in "${QCAN[@]}"; do QON[i]=0; done
            while IFS= read -r i; do [ -n "$i" ] && QON[i]=1; done <<<"$WT_OUT"
            [ "$DESC_TOUCHED" -eq 1 ] || DESC="$(auto_desc)"
            step=$DESCSTEP
        else
            if [ "$NASK" -ge 1 ]; then step=$NASK
            elif [ "$ACTION" = edit ]; then clear 2>/dev/null; echo "template: przerwane, nic nie zmieniono"; exit 1
            else step=0; fi
        fi
        continue
    fi

    if [ "$step" -eq "$DESCSTEP" ]; then
        [ "${#QCAN[@]}" -eq 0 ] && [ "$DESC_TOUCHED" -eq 0 ] && DESC="$(auto_desc)"
        if wt --title "$TITLE -- opis" --ok-button "Dalej" --cancel-button "Wstecz" \
              --inputbox "Opis szablonu (podpowiedź z Twoich wyborów -- możesz zmienić)" 8 "$W" "$DESC"; then
            [ "$WT_OUT" != "$DESC" ] && DESC_TOUCHED=1
            DESC="$WT_OUT"; step=$PLANSTEP
        else
            if [ "${#QCAN[@]}" -gt 0 ]; then step=$QSTEP
            elif [ "$NASK" -ge 1 ]; then step=$NASK
            elif [ "$ACTION" = edit ]; then clear 2>/dev/null; echo "template: przerwane, nic nie zmieniono"; exit 1
            else step=0; fi
        fi
        continue
    fi

    # plan
    TARGS=(); PL=()
    for i in "${!TN[@]}"; do
        lbl="$(label_of "${TN[$i]}")"
        if [ -z "${BASE[$i]}" ]; then continue; fi
        if [ -n "${LET[$i]}" ]; then old="-${LET[$i]}${BASE[$i]}"; new="-${LET[$i]}${NEWV[$i]}"; else old="${BASE[$i]}"; new="${NEWV[$i]}"; fi
        if [ "${NEWV[$i]}" = "${BASE[$i]}" ]; then
            PL+=("  $lbl: $old (bez zmian)")
        else
            PL+=("  $lbl: $old -> $new")
            if [ -n "${LET[$i]}" ]; then TARGS+=("--tier=${TN[$i]}" "--retain=$new"); else TARGS+=("--tier=${TN[$i]}" "--keep=$new"); fi
        fi
    done
    for i in ${QCAN[@]+"${QCAN[@]}"}; do
        lbl="$(label_of "${TN[$i]}")"
        if [ "${QON[$i]}" = 1 ] && [ -z "${TQ[$i]}" ]; then
            PL+=("  zamrażanie $lbl: nie -> tak"); TARGS+=("--tier=${TN[$i]}" "--quiesce=auto,degrade")
        elif [ "${QON[$i]}" = 0 ] && [ -n "${TQ[$i]}" ]; then
            PL+=("  zamrażanie $lbl: tak -> nie"); TARGS+=("--tier=${TN[$i]}" "--quiesce=")
        else
            PL+=("  zamrażanie $lbl: $([ -n "${TQ[$i]}" ] && echo tak || echo nie) (bez zmian)")
        fi
    done
    DARGS=(); [ -n "$DESC" ] && DARGS=("--description=$DESC")
    if [ "$ACTION" = edit ]; then
        [ "$DESC" = "$BDESC" ] && DARGS=()
        if [ "${#TARGS[@]}" -eq 0 ] && [ "${#DARGS[@]}" -eq 0 ]; then
            wt --title "Zmiana szablonu $NAME" --msgbox "Nic nie zmieniono." 7 "$W"
            exit 0
        fi
        ARGV=("$ZB" save-profile "--from=$NAME" "--as=$NAME" --force)
    else
        ARGV=("$ZB" save-profile "--from=$NAME" "--as=$NEW")
    fi
    ARGV+=(${TARGS[@]+"${TARGS[@]}"} ${DARGS[@]+"${DARGS[@]}"})
    {
        echo "PLAN -- nic jeszcze nie zostało zapisane:"
        echo
        if [ "$ACTION" = edit ]; then echo "Zmiana szablonu: $NAME"; else echo "Nowy szablon: $NEW (na podstawie $NAME)"; fi
        if [ "${#PL[@]}" -gt 0 ]; then printf '%s\n' "${PL[@]}"; fi
        echo "Opis: ${DESC:-(brak)}"
        if [ "$ACTION" = edit ]; then echo "Zbudowano z niego relacji: $USED -- one zostają, jak są."; fi
        echo
        echo "Zbudowane relacje się nie zmieniają; szablon jest dla nowych relacji (i dla 'Zmień relację -> Szablon')."
        echo
        printf 'Komenda:  '; for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done; echo
    } >"$TMPD/plan.txt"
    if ! yesno_text "$TMPD/plan.txt" "$TITLE -- plan" "WYKONAJ" "Wstecz" --defaultno; then
        step=$DESCSTEP; continue
    fi
    run_cmd "szablon '$NEW' zapisany" "${ARGV[@]}"
done
