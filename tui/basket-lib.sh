# basket-lib.sh -- KOSZYK MIEJSC: wybór datasetów wspólny dla kreatorów (dołączany
# przez tui/new-relation.sh, tui/replica.sh i tui/edit-relation.sh; nie uruchamiać
# samodzielnie).
#
# Model (właściciel 2026-09-18, zmierzony na pve10<-pve11): pozycja koszyka to MIEJSCE
# -- kopiowane jest ono i wszystko, co pod nim JEST i co POWSTANIE; wyjątek to dataset
# pod miejscem, który jest pomijany; -R/-r to "jak", nie "co". Wydzielone z
# new-relation.sh 2026-10-09 (uwaga 13); od X12 (2026-10-12) wybór to jedno drzewo z
# kratkami (basket_step -> tui/tree.py).
#
# Wołający daje: wt-lib.sh (wt, geom, fit, info, clip_label; H W LH), TMPD, PY, HERE,
# title <nr> <tekst> (nagłówek okna; koszyk pyta o krok 4), HOST (nazwa w tekstach),
# RECURSION (flat|atomic). BASKET_NO_MODE=1 chowa "Sposób" (zawsze -R).
# BASKET_NO_EXC=1 nie pozwala pomijać (Zmień relację: add-source bierze cały dataset).
# BASKET_HIDE: cel kopii, ukryty w drzewie razem z tym, co pod nim.
# Stan: T_NAME/T_KIDS/T_LABEL (drzewo), B_ROOT/B_EXCL (koszyk; pominięte po jednym w linii).
T_NAME=(); T_KIDS=(); T_LABEL=()
B_ROOT=(); B_EXCL=()

# basket_tree_from_json <list-datasets --json> -> T_*[] (+ $TMPD/own.tsv: migawki spoza
# rodzin Proxmoksa na dataset, gdy JSON je ma). rc 1 = brak datasetów (powód w $TMPD/ds.err).
basket_tree_from_json() {
    "$PY" - "$1" "$TMPD/own.tsv" <<'PYEOF' | tr -d '\r' >"$TMPD/tree.tsv"
import sys, json
ds = json.load(open(sys.argv[1], encoding="utf-8")).get("datasets") or []
names = [d.get("name", "") for d in ds]
# Migawki spoza rodzin Proxmoksa, na dataset (U8: krok 6 przy synchro).
with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as of:
    for d in ds:
        # 4. kolumna: epoch najnowszej migawki rodziny (pytanie "kto je robi?", 2026-10-24)
        of.write("%s\t%d\t%d\t%d\n" % (d.get("name", ""), int(d.get("own_snapshots") or 0), int(d.get("family_snapshots") or 0),
                                     int(d.get("family_newest") or 0)))
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
    T_NAME=(); T_KIDS=(); T_LABEL=(); BASKET_DS_JSON="$1"
    local n k l
    while IFS=$'\t' read -r n k l; do
        [ -n "$n" ] || continue
        T_NAME+=("$n"); T_KIDS+=("$k"); T_LABEL+=("$l")
    done <"$TMPD/tree.tsv"
    [ "${#T_NAME[@]}" -gt 0 ] || { { T 'źródło nie ma żadnego datasetu'; echo; } >"$TMPD/ds.err"; return 1; }
    return 0
}

kids_count() { local i; for i in "${!T_NAME[@]}"; do [ "${T_NAME[$i]}" = "$1" ] && { echo "${T_KIDS[$i]}"; return; }; done; echo 0; }
describe() {    # <indeks> -> jedno zdanie o pozycji koszyka
    local r="${B_ROOT[$1]}" e="${B_EXCL[$1]}" k short x
    k="$(kids_count "$r")"; short=""
    while IFS= read -r x; do [ -n "$x" ] && short="$short${short:+, }${x#"$r"/}"; done <<<"$e"
    if [ "$k" -eq 0 ]; then T 'dziś nic pod nim; nowe skopiują się same'; echo
    elif [ -z "$short" ]; then Tv 'dziś $k pod nim; nowe skopiują się same' '$k' "$k"; echo
    else Tv 'dziś $k pod nim; BEZ: $short' '$k' "$k" '$short' "$short"; echo; fi
}
mode_words() { [ "$RECURSION" = atomic ] && T 'cała gałąź atomowo (-r)' || T 'każdy dataset osobno (-R)'; echo; }
any_excl() { local i; for i in "${!B_ROOT[@]}"; do [ -n "${B_EXCL[$i]}" ] && return 0; done; return 1; }

# basket_step -> 0 = Dalej z niepustym wyborem, 1 = Wstecz. X12 (właściciel 2026-10-12): JEDNO
# okno -- drzewo z kratkami jak w eksploratorze (tui/tree.py, curses: drugi wyjątek od whiptail,
# po grid.py) -- zamiast listy i trzech okien (Dodaj miejsce / Wyjątki / Usuń pozycję). Wynik
# ten sam co dawniej: B_ROOT (miejsca), B_EXCL (pominięte pod każdym, po jednym w linii),
# RECURSION. Zaznaczona gałąź = miejsce; odznaczona pod zaznaczoną = wyjątek. BASKET_HIDE
# (nazwy po spacji) chowa cel kopii razem z tym, co pod nim -- listy tylko poprawne wybory.
# ZFS_TREE podmienia program okna (testy: tree.py --keys, jak ZFS_GRID dla grid.py).
basket_step() {
    local mode=1 noexc=0 k a b
    { [ "${MODE:-}" = local ] || [ "${BASKET_NO_MODE:-0}" = 1 ]; } && mode=0
    [ "${BASKET_NO_EXC:-0}" = 1 ] && noexc=1
    # Kampania 2026-10-22: przy migawkach (lokalnych albo zdalnych) nic się nie kopiuje, a okno
    # pytało "Co kopiować z ...?" i mówiło "[x] kopiowane". Słowa okna z rodzaju relacji.
    local q lg=""
    q="$(Tv 'Co kopiować z $HOST?' '$HOST' "$HOST")"
    if [ "${NOCOPY:-0}" = 1 ] || [ "${MODE:-}" = snaponly ]; then
        q="$(Tv 'Gdzie robić migawki na $HOST?' '$HOST' "$HOST")"
        lg="$(T ' [x] z migawkami, razem z tym, co pod nim POWSTANIE   [-] część   [ ] bez')"
    fi
    BASKET_LEGEND="$lg" "$PY" - "$BASKET_DS_JSON" "$TMPD/tree-spec.json" "$(title 4 "$q")" "$HOST" "$mode" "$noexc" \
        "${RECURSION:-flat}" "${BASKET_HIDE:-}" "${#B_ROOT[@]}" ${B_ROOT[@]+"${B_ROOT[@]}"} ${B_EXCL[@]+"${B_EXCL[@]}"} <<'PYEOF' || return 1
import sys, json, os
ds = json.load(open(sys.argv[1], encoding="utf-8")).get("datasets") or []
n = int(sys.argv[9]); roots = sys.argv[10:10 + n]; ex = sys.argv[10 + n:10 + 2 * n]
spec = {"title": sys.argv[3], "host": sys.argv[4], "show_mode": sys.argv[5] == "1", "no_exc": sys.argv[6] == "1",
        "recursion": sys.argv[7], "hide": sys.argv[8].split(),
        "datasets": [{"name": d.get("name", ""), "used": d.get("used"), "type": d.get("type")} for d in ds],
        "roots": roots, "excl": {r: [x for x in e.split("\n") if x] for r, e in zip(roots, ex)}}
if os.environ.get("BASKET_LEGEND"):
    spec["legend"] = os.environ["BASKET_LEGEND"]
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(spec, f, ensure_ascii=False)
PYEOF
    ${ZFS_TREE:-$PY $HERE/tui/tree.py} --spec "$TMPD/tree-spec.json" --out "$TMPD/tree-out.json" || return 1
    "$PY" - "$TMPD/tree-out.json" <<'PYEOF' | tr -d '\r' >"$TMPD/tree-out.tsv" || return 1
import sys, json
o = json.load(open(sys.argv[1], encoding="utf-8"))
print("R\t" + (o.get("recursion") or "flat"))
for r in o.get("roots") or []:
    print("B\t%s\t%s" % (r, "\x1f".join((o.get("excl") or {}).get(r) or [])))
PYEOF
    B_ROOT=(); B_EXCL=()
    while IFS=$'\t' read -r k a b; do
        case "$k" in
            R) RECURSION="$a" ;;
            B) B_ROOT+=("$a"); B_EXCL+=("$(printf '%s' "$b" | tr '\037' '\n')") ;;
        esac
    done <"$TMPD/tree-out.tsv"
    [ "${#B_ROOT[@]}" -gt 0 ]
}

# H-7 (kampania 2026-10-21): pula nośnika INNEJ repliki (replab) była na liście źródeł nowej.
# Kampania 3 (2026-10-23): to samo w kreatorze kopii/migawek lokalnych (gwlive, replab jako źródła).
# Nośnik wymienny = cała jego pula; nośnik stały = katalog docelowy z poddrzewem. Z listy
# datasetów (ds.json) znikają, zanim powstanie z niej drzewo.
drop_replica_media() {   # <ds.json> <rep.json (list-replicas --json)> -- ds.json poprawiony w miejscu
    "$PY" - "$1" "$2" <<'PYEOF' || true
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    r = json.load(open(sys.argv[2], encoding="utf-8"))
except Exception:
    sys.exit(0)
hide = []
for x in r.get("replicas") or []:
    dst = (x.get("dst") or "").strip("/")
    if not dst:
        continue
    hide.append(dst.split("/")[0] if x.get("media") == "removable" else dst)
if hide:
    d["datasets"] = [x for x in d.get("datasets") or []
                     if not any(x.get("name") == h or (x.get("name") or "").startswith(h + "/") for h in hide)]
    # Stały nośnik: pula zostaje, bo może trzymać coś jeszcze. Gdy po schowaniu celu
    # nie ma w niej nic poza nim (pve10 replab -> replab/replica, przejście 2026-10-23),
    # sama pula też jest tylko nośnikiem i nie jest źródłem do wyboru.
    names = [x.get("name") or "" for x in d["datasets"]]
    pools = {h.split("/")[0] for h in hide if "/" in h}
    empty = {p for p in pools if not any(n.startswith(p + "/") for n in names)}
    d["datasets"] = [x for x in d["datasets"] if (x.get("name") or "") not in empty]
    json.dump(d, open(sys.argv[1], "w", encoding="utf-8"))
PYEOF
}
