#!/bin/bash
# retention-lib.sh -- OKNO RETENCJI ŹRÓDŁA, wspólne dla kreatora relacji (krok 9) i
# "Zmień relację" (właściciel 2026-10-09, uwaga 10: "Trzeba to ujednolicić w całym
# pakiecie" -- dla źródła tylko okno z kratkami, nigdy druga lista szablonów).
#
# Wołający ustawia: ZB, PY, HERE, TMPD, W (wt-lib.sh), PROFILE (szablon celu),
# HOST (słowo do tytułu), SRC_TITLE (tytuł okna), oraz plik $TMPD/prof.json.tiers:
#   profil <TAB> szczebel <TAB> rodzina <TAB> liczba <TAB> keep|retain:<litera>
# Wynik: SRCPROF (pochodny szablon "<PROFILE>-src-<litery>" albo pusty = jak cel),
# SRCKEEP (pamięć liczb przy powrocie do okna).

tier_word() {   # <nazwa szczebla> -> słowo
    case "$1" in
        *hourly) echo "godzinowe" ;; *daily) echo "dobowe" ;; *weekly) echo "tygodniowe" ;;
        *monthly) echo "miesięczne" ;; *yearly|*annual) echo "roczne" ;; *) echo "$1" ;;
    esac
}
tier_letter() { case "$1" in *hourly) echo H ;; *daily) echo D ;; *weekly) echo W ;; *monthly) echo M ;; *yearly|*annual) echo Y ;; *) echo X ;; esac; }
age_unit() {   # <litera jednostki retain> -> słowo
    case "$1" in h) echo "godz." ;; d) echo "dni" ;; w) echo "tyg." ;; m) echo "mies." ;; y) echo "lat" ;; *) echo "$1" ;; esac
}
source_retention_editor() {   # 0 = dalej (SRCPROF ustawiony albo pusty), 1 = wstecz
    # UWAGA 2 (właściciel, 2026-10-09): bez menu szczebli z pozycją "Gotowe" (OK robiło
    # podświetloną pozycję, więc "Dalej" nie szło dalej). Teraz jedno okno-tabela.
    local -a tn=() tp=() tk=() sk=() tm=()
    local t p k m i n v name out u
    SRC_SHOWN=0     # X5: 1 = okno bylo pokazane (Wstecz z planu wraca do niego)
    while IFS=$'\t' read -r n t p k m; do
        [ "$n" = "$PROFILE" ] || continue
        k="${k%$'\r'}"; m="${m%$'\r'}"
        tn+=("$t"); tp+=("$p"); tk+=("$k"); sk+=("$k"); tm+=("${m:-keep}")
    done <"$TMPD/prof.json.tiers"
    [ "${#tn[@]}" -gt 0 ] || { SRCPROF=""; return 0; }
    SRC_SHOWN=1
    # poprzednie liczby tego samego szablonu (powrót do okna)
    if [ -n "$SRCKEEP" ] && [ "${SRCKEEP%%:*}" = "$PROFILE" ]; then read -r -a sk <<<"${SRCKEEP#*:}"; fi
    # OKNO-TABELA (właściciel 2026-10-09, jak w menedżerach migawek QNAP/Synology):
    # szczebel | tutaj (cel) | u źródła, kratka = szczebel u źródła w ogóle. tui/grid.py
    # (curses -- wyjątek od whiptail); Dalej bez zmian = źródło jak cel.
    : >"$TMPD/srcrows.tsv"
    for i in "${!tn[@]}"; do
        u=""; case "${tm[$i]}" in retain:*) u="$(age_unit "${tm[$i]#retain:}")" ;; esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$(tier_word "${tn[$i]}")" "${tk[$i]}" "${sk[$i]}" "$u" "${tp[$i]}" >>"$TMPD/srcrows.tsv"
    done
    "$PY" - "$TMPD/srcrows.tsv" "$TMPD/srcspec.json" "${SRC_TITLE:-Jak długo trzymać u źródła ($HOST)?}" <<'PYEOF'
import json, sys
rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    i, lab, here, src, unit, fam = (line.rstrip("\n").split("\t") + [""] * 6)[:6]
    rows.append({"key": i, "label": lab, "on": src != "0", "value": (here if src == "0" else src), "unit": unit,
                 "ref": ("%s %s" % (here, unit)).strip(), "q": None, "family": fam or None})
json.dump({"title": sys.argv[3], "head": [u"SZCZEBEL", u"TUTAJ (cel)", u"U ŹRÓDŁA"], "rows": rows,
           "note": [u"Źródło sprząta te same migawki co cel, tylko trzyma ich mniej albo więcej.",
                    u"Bez zmian = źródło jak cel. Kratka = szczebel u źródła w ogóle."]},
          open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
PYEOF
    clear 2>/dev/null
    # shellcheck disable=SC2086
    ${ZFS_GRID:-$PY $HERE/tui/grid.py} --spec "$TMPD/srcspec.json" --out "$TMPD/srcout.json" || return 1
    while IFS=$'\t' read -r i v; do
        [ -n "$i" ] && sk[$i]="$v"
    done < <("$PY" -c '
import json, sys
for r in json.load(open(sys.argv[1], encoding="utf-8"))["rows"]:
    print("%s\t%s" % (r["key"], r["value"] if r["on"] else "0"))' "$TMPD/srcout.json" | tr -d '\r')
    SRCKEEP="$PROFILE:${sk[*]}"
    # CONFIG JAKO JEDYNE ŹRÓDŁO (właściciel 2026-10-13): w "Zmień relację" okno nie zapisuje
    # szablonu -- oddaje argumenty set-tiers (--src-tier ...) w pliku SRC_ARGS_OUT, liczone
    # względem OBECNEGO źródła relacji (CUR_S w prof.json.tiers), nie względem celu.
    if [ -n "${SRC_ARGS_OUT:-}" ]; then
        : >"$SRC_ARGS_OUT"
        local cur
        for i in "${!tn[@]}"; do
            # SRC_ARGS_BASE=target ("Użyj szablonu"): po zastosowaniu szablonu źródło jest jak
            # cel, więc różnice liczone od liczb celu.
            if [ "${SRC_ARGS_BASE:-}" = target ]; then cur="${tk[$i]}"
            else cur=$(awk -F'\t' -v s="${CUR_S:-}" -v t="${tn[$i]}" '$1==s && $2==t {print $4; exit}' "$TMPD/prof.json.tiers"); fi
            cur="${cur:-0}"
            # X15: szczebel dodany w tabeli celu -- set-tiers doda go po obu stronach; tu tylko
            # jego liczba u źródła, zawsze (dodany dostaje inaczej liczbę domyślną).
            local isnew=0; case " ${SRC_NEW_TIERS:-} " in *" ${tn[$i]} "*) isnew=1 ;; esac
            [ "$isnew" -eq 0 ] && [ "${sk[$i]}" = "$cur" ] && continue
            if [ "${sk[$i]}" = 0 ]; then echo "--drop-src-tier=${tn[$i]}" >>"$SRC_ARGS_OUT"; continue; fi
            [ "$isnew" -eq 0 ] && [ "$cur" = 0 ] && echo "--add-src-tier=${tn[$i]}" >>"$SRC_ARGS_OUT"
            echo "--src-tier=${tn[$i]}" >>"$SRC_ARGS_OUT"
            case "${tm[$i]}" in
                retain:*) echo "--retain=-${tm[$i]#retain:}${sk[$i]}" >>"$SRC_ARGS_OUT" ;;
                *)        echo "--keep=${sk[$i]}" >>"$SRC_ARGS_OUT" ;;
            esac
        done
        SRCPROF=""
        return 0
    fi
    # nic nie zmienione -> źródło jak cel (bez osobnego profilu)
    [ "${sk[*]}" != "${tk[*]}" ] || { SRCPROF=""; return 0; }
    name="$PROFILE-src-"
    local from="$PROFILE" own=0
    # CONFIG WINS (właściciel 2026-10-13): szablon źródła WŁASNEJ relacji (relacja-<NAZWA>)
    # ma STAŁĄ nazwę -- dawniej każda zmiana liczb dawała nowy plik (pve9b: pięć wariantów
    # jednej relacji). Budowany z obecnego szablonu źródła tej relacji, gdy jest (CUR_S),
    # żeby jego wartości zostały;
    # wtedy liczby idą WSZYSTKIE, bo baza ma własne.
    case "$PROFILE" in
        relacja-*)
            own=1
            case "${CUR_S:-}" in "$PROFILE-src"*) from="$CUR_S" ;; esac ;;
    esac
    # Baza źródła musi mieć te same szczeble co cel; inaczej (szczebel dodany w celu)
    # jak dawniej -- z szablonu celu.
    if [ "$from" != "$PROFILE" ]; then
        for i in "${!tn[@]}"; do
            awk -F'\t' -v p="$from" -v t="${tn[$i]}" '$1==p && $2==t {f=1} END {exit !f}' "$TMPD/prof.json.tiers" || { from="$PROFILE"; break; }
        done
    fi
    local -a args=(--from="$from" --force)
    for i in "${!tn[@]}"; do
        if [ "${sk[$i]}" = 0 ]; then args+=(--drop-tier="${tn[$i]}"); continue; fi
        name="$name$(tier_letter "${tn[$i]}")${sk[$i]}"
        [ "$from" = "$PROFILE" ] && [ "${sk[$i]}" = "${tk[$i]}" ] && continue
        # Ten sam tryb co w szablonie celu: licznik zostaje licznikiem, wiek wiekiem.
        case "${tm[$i]}" in
            retain:*) args+=(--tier="${tn[$i]}" "--retain=-${tm[$i]#retain:}${sk[$i]}") ;;
            *)        args+=(--tier="${tn[$i]}" "--keep=${sk[$i]}") ;;
        esac
    done
    [ "$own" -eq 1 ] && name="$PROFILE-src"
    info "${SRC_TITLE:-Retencja źródła}" "Zapisuję szablon źródła $name..."
    out=$("$ZB" save-profile "${args[@]}" --as="$name" --description="Retencja ŹRÓDŁA na bazie $PROFILE (pochodny, z kreatora)" 2>&1) \
        || { wt --title "Szablon źródła odrzucony" --msgbox "$(printf '%s' "$out" | tail -6)" 14 "$W"; return 1; }
    SRCPROF="$name"
    return 0
}

# Retencja źródła słowami z nazwy profilu pochodnego <cel>-src-H24D3 -> "godzinowe 24, dobowe 3";
# inna nazwa -- ona sama. Kreator (krok "u źródła") i karta zmiany relacji (U65) mówią tak samo.
src_words_of() {   # <profil>
    local p="$1" s out="" l n
    case "$p" in *-src-*) ;; *) echo "$p"; return ;; esac
    s="${p##*-src-}"
    while [ -n "$s" ]; do
        l="${s:0:1}"; s="${s:1}"; n="${s%%[!0-9]*}"; s="${s#"$n"}"
        case "$l" in H) l=godzinowe ;; D) l=dobowe ;; W) l=tygodniowe ;; M) l=miesięczne ;; Y) l=roczne ;; *) echo "$p"; return ;; esac
        out="${out:+$out, }$l ${n:-?}"
    done
    echo "$out"
}
