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
    while IFS=$'\t' read -r n t p k m; do
        [ "$n" = "$PROFILE" ] || continue
        k="${k%$'\r'}"; m="${m%$'\r'}"
        tn+=("$t"); tp+=("$p"); tk+=("$k"); sk+=("$k"); tm+=("${m:-keep}")
    done <"$TMPD/prof.json.tiers"
    [ "${#tn[@]}" -gt 0 ] || { SRCPROF=""; return 0; }
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
    # nic nie zmienione -> źródło jak cel (bez osobnego profilu)
    [ "${sk[*]}" != "${tk[*]}" ] || { SRCPROF=""; return 0; }
    name="$PROFILE-src-"
    local -a args=(--from="$PROFILE" --force)
    for i in "${!tn[@]}"; do
        if [ "${sk[$i]}" = 0 ]; then args+=(--drop-tier="${tn[$i]}"); continue; fi
        name="$name$(tier_letter "${tn[$i]}")${sk[$i]}"
        [ "${sk[$i]}" = "${tk[$i]}" ] && continue
        # Ten sam tryb co w szablonie celu: licznik zostaje licznikiem, wiek wiekiem.
        case "${tm[$i]}" in
            retain:*) args+=(--tier="${tn[$i]}" "--retain=-${tm[$i]#retain:}${sk[$i]}") ;;
            *)        args+=(--tier="${tn[$i]}" "--keep=${sk[$i]}") ;;
        esac
    done
    info "${SRC_TITLE:-Retencja źródła}" "Zapisuję szablon źródła $name..."
    out=$("$ZB" save-profile "${args[@]}" --as="$name" --description="Retencja ŹRÓDŁA na bazie $PROFILE (pochodny, z kreatora)" 2>&1) \
        || { wt --title "Szablon źródła odrzucony" --msgbox "$(printf '%s' "$out" | tail -6)" 14 "$W"; return 1; }
    SRCPROF="$name"
    return 0
}
