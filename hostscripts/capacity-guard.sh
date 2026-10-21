#!/bin/bash
# capacity-guard.sh -- BEZPIECZNIK POJEMNOŚCI (U35, właściciel 2026-10-20).
#
# Wzór: a-tassa, gdzie cron przy zajętości 89 % kasuje najstarsze migawki. Tutaj tak
# samo, ale tylko to, co bezpiecznie usunąć -- i każda niepewność oznacza NIC NIE
# USUWAĆ (GitHub #655, audyt 2026-10-20):
#   - WŁASNOŚĆ z zarządzanych linii crona, nie z nazwy: migawka jest „nasza” tylko gdy
#     lokalna linia delsnaps.sh w bloku zfs-backup-managed któregoś crontaba tego hosta
#     obejmuje jej dataset (wprost albo jako dziecko przy -R) i jej nazwa zaczyna się od
#     JAWNEGO wzorca tej linii. Linia z pustym wzorcem ("" -- wszystko, co nie chronione przez -P) nie
#     daje prawa kasowania; linia zdalna (host:dataset), -B (zakładki) i -n też nie;
#   - nigdy migawka pod hold (np. zfssnapall_inflight -- trwa transfer);
#   - nigdy NAJNOWSZA migawka datasetu (dowolna nazwa): po stronie celu silnik bierze za
#     bazę najnowszą wspólną, a gdy źródło jej nie ma -- zakładkę o GUID głowy celu;
#   - nigdy migawka wskazana przez zakładkę #tgt-* (baza, którą silnik zapisał po
#     udanym transferze);
#   - dataset, który jest ŹRÓDŁEM transferu -- lokalna linia snapsend.sh / lokalna
#     snapget.sh z celem albo zakres peera (/etc/zfs-snapshot-all/peers/*.scope: tu
#     ciągnie zdalny kolektor): każdy cel linii musi mieć SWOJĄ zakładkę (nazwa jak w
#     silniku: tgt- + md5(cel lądowania, -j)); u peera -- co najmniej jedna #tgt-;
#     transfer -r zakładki nie zapisuje. Brak = baza nieznana = w tym datasecie nic.
#     Chronione wszystko od najstarszej wymaganej zakładki w górę;
#   - w każdym datasecie i rodzinie zostaje dodatkowo N najnowszych (guard_min_keep, 2);
#   - od NAJDROBNIEJSZEGO szczebla (godzinowe, dobowe, tygodniowe, miesięczne, roczne),
#     w szczeblu od najstarszej;
#   - po każdym usunięciu pomiar zajętości (zpool sync); stop poniżej guard_target albo,
#     gdy nie ma już czego bezpiecznie usunąć -- wtedy alert "nie dało się". Nieudany
#     zpool sync albo nieczytelna zajętość = koniec biegu, żadnego kolejnego usunięcia;
#   - progi spoza zakresu (guard_at 50-99, guard_target 40-98 i poniżej guard_at,
#     guard_min_keep 1-100) albo guard inny niż on/off = nic, kod 1, alert z nazwą;
#   - błąd odczytu crontabów, `zfs list` (migawki, zakładki) albo linia transferu, której
#     nie rozumiemy = pula nietknięta, alert, kod 1. Nie „nic do usunięcia”. Dotyczy puli
#     powyżej progu: poniżej progu bezpiecznik nic nie czyta (w --plan -- każdej puli).
#
# Ustawienia (settings.ini [capacity], F10; alert-env.sh): kolejność ważności
# środowisko > settings.ini > zfs-alert.conf > domyślne.
#   guard = off|on (ZFS_GUARD, domyślnie off -- decyzja właściciela), guard_at = 89
#   (ZFS_GUARD_AT), guard_target = 85 (ZFS_GUARD_TARGET), guard_min_keep = 2
#   (ZFS_GUARD_MIN_KEEP).
# Użycie: capacity-guard.sh [--plan]  -- --plan: co by poszło, nic nie usuwa (działa
# także przy guard = off).
# Działa na źródle i na kolektorze (właściciel 2026-10-20: "W źródle i w celu").
set -u
PLAN=0
case "${1:-}" in --plan) PLAN=1 ;; "") ;; *) echo "użycie: capacity-guard.sh [--plan]" >&2; exit 2 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -r "$HERE/alert-env.sh" ] && . "$HERE/alert-env.sh"
GUARD="${ZFS_GUARD:-off}"
AT="${ZFS_GUARD_AT:-89}"
TARGET="${ZFS_GUARD_TARGET:-85}"
KEEP="${ZFS_GUARD_MIN_KEEP:-2}"
NOTIFY="${ZFS_NOTIFY_SCRIPT:-/root/scripts/notify-fail.sh}"
CRONDIR="${ZFS_GUARD_CRONTABS:-/var/spool/cron/crontabs}"
PEERDIR="${ZFS_GUARD_PEERS:-/etc/zfs-snapshot-all/peers}"
HOST="$(hostname -s 2>/dev/null || hostname)"

say() { echo "$(date '+%Y-%m-%d %H:%M:%S') capacity-guard: $*"; }
alert() {   # <temat> <treść>
    if [ -x "$NOTIFY" ]; then "$NOTIFY" "$1" "$2" 2>/dev/null && return 0; fi
    command -v mail >/dev/null 2>&1 && printf '%s\n' "$2" | mail -s "[ZFS CAPACITY] $1" "${ZFS_ALERT_EMAIL:-root}" 2>/dev/null
    return 0
}

case "$GUARD" in on|off) ;; *)
    say "guard = '$GUARD' -- dozwolone on albo off; nic nie robię"
    [ "$PLAN" -eq 1 ] || alert "$HOST: bezpiecznik -- złe ustawienie guard" "guard = '$GUARD' (ZFS_GUARD / [capacity] guard). Dozwolone: on, off. Bezpiecznik nic nie usunął."
    exit 1 ;;
esac
if [ "$GUARD" != on ] && [ "$PLAN" -eq 0 ]; then exit 0; fi

# PROGI SPRAWDZANE, NIE PODMIENIANE (REV-20261021-155 F1): guard_at=0/guard_target=0
# przechodziły parsowanie, cel spadał do -1 i pętla usuwała wszystko, co wolno. Zakresy
# z rejestru F10 (zfs-backup.sh, capacity.*). Zła wartość z dowolnego źródła (env,
# settings.ini, zfs-alert.conf) = nic nie usuwam, kod 1, alert z nazwą ustawienia --
# także w --plan (bez alertu). Niższe źródło nie zastępuje złej wartości wyższego.
bad_setting=""
in_range() {   # <wartość> <min> <max>
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 3 ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}
in_range "$AT" 50 99         || bad_setting="$bad_setting guard_at='$AT' (50-99)"
in_range "$TARGET" 40 98     || bad_setting="$bad_setting guard_target='$TARGET' (40-98)"
in_range "$KEEP" 1 100       || bad_setting="$bad_setting guard_min_keep='$KEEP' (1-100)"
if [ -z "$bad_setting" ] && [ "$TARGET" -ge "$AT" ]; then
    bad_setting=" guard_target='$TARGET' nie jest poniżej guard_at='$AT'"
fi
if [ -n "$bad_setting" ]; then
    say "złe ustawienia:$bad_setting -- nic nie usuwam"
    [ "$PLAN" -eq 1 ] || alert "$HOST: bezpiecznik -- złe ustawienia" "Bezpiecznik nic nie usunął. Złe ustawienia (ZFS_GUARD_* / [capacity] w settings.ini / zfs-alert.conf):$bad_setting"
    exit 1
fi

# Jeden bezpiecznik naraz: cron co 15 min, a czyszczenie dużej puli trwa.
exec 9>"${ZFS_GUARD_LOCK:-/run/lock/zfs-capacity-guard.lock}" 2>/dev/null && flock -n 9 2>/dev/null || { [ "$PLAN" -eq 1 ] || exit 0; }
cap_of() { zpool list -H -o capacity "$1" 2>/dev/null | tr -d '% '; }
WORK="$(mktemp -d 2>/dev/null)" || { say "brak katalogu tymczasowego -- nic nie robię"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# ---- 1. Własność i źródła transferów z zarządzanych bloków crontabów -----------
# Wynik (TAB): OWN ds rec wzorzec | SRC ds rec | BAD powód. Tokeny w cudzysłowach
# czytane wprost (bez eval); polecenie kończy się na przekierowaniu albo ';'.
# BAD dotyczy tylko linii transferu: niezrozumiana linia retencji tylko NIE daje
# własności (mniej usuwania), a niezrozumiana linia transferu mogłaby ukryć bazę.
read_managed() {
    [ -d "$CRONDIR" ] && [ -r "$CRONDIR" ] && [ -x "$CRONDIR" ] || { echo "nie da się czytać $CRONDIR"; return 1; }
    local f
    for f in "$CRONDIR"/*; do
        [ -e "$f" ] || continue
        [ -r "$f" ] || { echo "nie da się czytać $f"; return 1; }
        awk '/^# BEGIN zfs-backup-managed/ { on = 1; next } /^# END zfs-backup-managed/ { on = 0; next } on' "$f" \
            || { echo "błąd odczytu $f"; return 1; }
    done > "$WORK/managed"
    awk -F'\n' '
    function tok(s,    i, c, t, out, n) {   # -> T[1..n], zwraca n; -1 = nie umiem
        n = 0; i = 1
        while (i <= length(s)) {
            c = substr(s, i, 1)
            if (c == " " || c == "\t") { i++; continue }
            if (c == "\"") {
                t = ""; i++
                while (i <= length(s) && substr(s, i, 1) != "\"") { if (substr(s, i, 1) == "\\") return -1; t = t substr(s, i, 1); i++ }
                if (i > length(s)) return -1
                i++; T[++n] = t; continue
            }
            t = ""
            while (i <= length(s) && substr(s, i, 1) != " " && substr(s, i, 1) != "\t") { t = t substr(s, i, 1); i++ }
            if (t ~ /^(2>|>|;|\||&)/) break
            if (t ~ /["\\]/) return -1                   # dane, nie powłoka: $ i ^ w -X zostają
            T[++n] = t
        }
        return n
    }
    function emit_list(kind, list, rec, pat, dst,    a, m, k) {
        m = split(list, a, ",")
        for (k = 1; k <= m; k++) {
            if (a[k] == "" || a[k] ~ /:/) continue          # zdalny -- nie nasz lokalnie
            if (kind == "OWN") print "OWN\t" a[k] "\t" rec "\t" pat
            else print "SRC\t" a[k] "\t" rec "\t" dst
        }
    }
    {
        line = $0
        if ((p = index(line, "/delsnaps.sh ")) > 0) {
            n = tok(substr(line, p + 13)); if (n < 0) next
            rec = 0; skip = 0; i = 1
            while (i <= n && T[i] ~ /^-/) {
                o = T[i]
                if (o == "-R" || o == "--recursive") rec = 1
                else if (o == "-B" || o == "-n") skip = 1
                else if (o == "-F" || o == "-G" || o == "-v" || o == "--verbose") { }
                else if (o ~ /^-[pkcKOPL]$/) i++
                else if (o ~ /^-[pkcKOPL]./) { }
                else { skip = 1; break }                     # nie rozumiem -- bez własności
                i++
            }
            if (skip || i + 1 > n) next
            ds = T[i]; m = split(T[i + 1], pp, ",")
            for (k = 1; k <= m; k++) if (pp[k] != "") emit_list("OWN", ds, rec, pp[k], "")
            next
        }
        eng = ""
        if ((p = index(line, "/snapsend.sh ")) > 0) { eng = "send"; rest = substr(line, p + 13) }
        else if ((p = index(line, "/snapget.sh ")) > 0) { eng = "get"; rest = substr(line, p + 12) }
        if (eng == "") next
        n = tok(rest); if (n < 0) { print "BAD\tlinia transferu z nieczytelnymi cudzysłowami"; next }
        argopts = (eng == "send") ? "mlvjpkqToxcbXKOLE" : "mlvjpkTqQoxcbXKOLE"
        known = (eng == "send") ? "mezZgNlvrRtniHjuUfwVpkAqToxcbFXSKOLE" : "mezZgNlvrRtniHjuUfwVpkATqQoxcbFMXSKOLEs"
        rec = 0; atomic = 0; sonly = 0; id = ""; i = 1; bad = 0
        while (i <= n && T[i] ~ /^-./) {
            o = substr(T[i], 2); j = 1
            while (j <= length(o)) {
                c = substr(o, j, 1)
                if (index(known, c) == 0) { bad = 1; break }
                if (c == "R") rec = 1
                if (c == "r") { rec = 1; atomic = 1 }
                if (c == "s") sonly = 1
                if (index(argopts, c) > 0) {
                    if (j < length(o)) v = substr(o, j + 1); else { i++; v = T[i] }
                    if (c == "j") id = v
                    break
                }
                j++
            }
            if (bad) break
            i++
        }
        if (bad) { print "BAD\tnieznana opcja w linii " eng; next }
        if (i > n) { print "BAD\tlinia " eng " bez argumentów"; next }
        src = T[i]; dst = (i + 1 <= n) ? T[i + 1] : ""
        if (eng == "get" && (src ~ /:/ || sonly)) next      # pull albo same migawki: źródło nie tutaj
        if (dst == "") next                                  # same migawki: nic nie jest wysyłane
        emit_list("SRC", src, rec, "", dst "\t" id "\t" atomic)
    }' "$WORK/managed" > "$WORK/facts" || { echo "błąd analizy linii crona"; return 1; }
    # Źródło PULL dla zdalnego kolektora nie ma tu linii transferu (kolektor ciągnie i
    # sam prunuje źródło przez ssh), ale ma trwały zapis udostępnienia: zakres peera
    # z --commit-scope. Każdy peer to co najmniej jeden cel z własną zakładką #tgt-.
    local sc
    for sc in "$PEERDIR"/*.scope; do
        [ -e "$sc" ] || continue
        [ -r "$sc" ] || { echo "nie da się czytać $sc"; return 1; }
        awk -v peer="$(basename "$sc" .scope)" '
            /^\[dataset:.*\]$/ { if (ds != "") print "SRC\t" ds "\t" ch "\tpeer:" peer "\t\t0"; ds = $0; sub(/^\[dataset:/, "", ds); sub(/\]$/, "", ds); ch = 0; next }
            /^[ \t]*include_children[ \t]*=[ \t]*yes/ { ch = 1 }
            END { if (ds != "") print "SRC\t" ds "\t" ch "\tpeer:" peer "\t\t0" }' "$sc" >> "$WORK/facts" \
            || { echo "błąd odczytu $sc"; return 1; }
    done
    return 0
}

# ---- 2. Kandydaci w puli -----------------------------------------------------------
# Wynik: "C<TAB>ranga<TAB>creation<TAB>nazwa" i "B<TAB>dataset<TAB>powód" (zablokowane).
# Kod 1 = odczyt puli nie wyszedł w całości -- wtedy nic.
candidates() {   # <pula>
    local pool="$1" to=""
    command -v timeout >/dev/null 2>&1 && to="timeout ${ZFS_GUARD_TIMEOUT:-600}"
    $to zfs list -H -p -t snapshot -o name,creation,userrefs,guid -r "$pool" > "$WORK/snaps" 2> "$WORK/snaps.err" \
        || { echo "zfs list migawek puli $pool: $(head -1 "$WORK/snaps.err")"; return 1; }
    $to zfs list -H -p -t bookmark -o name,guid,creation -r "$pool" > "$WORK/marks" 2> "$WORK/marks.err" \
        || { echo "zfs list zakładek puli $pool: $(head -1 "$WORK/marks.err")"; return 1; }
    awk -F'\t' -v keep="$KEEP" -v facts="$WORK/facts" -v marks="$WORK/marks" '
        function under(ds, root, rec) { return ds == root || (rec && index(ds, root "/") == 1) }
        function rank(p) { return p ~ /hourly/ ? 1 : p ~ /daily/ ? 2 : p ~ /weekly/ ? 3 : p ~ /monthly/ ? 4 : p ~ /yearly|annual/ ? 5 : 9 }
        # Nazwa zakładki, którą silnik zapisuje po udanym transferze (lib-zfs-snap.sh
        # bookmark_target_tag): tgt- + 8 znaków md5(<cel lądowania>\0<-j>).
        function tag(tgt, id,    c, h) {
            if ((tgt SUBSEP id) in TAGC) return TAGC[tgt, id]
            c = "printf '\''%s\\0%s'\'' '\''" tgt "'\'' '\''" id "'\'' | md5sum"
            h = ""; c | getline h; close(c)
            return TAGC[tgt, id] = "tgt-" substr(h, 1, 8)
        }
        # Cel lądowania źródła ds dla danego dst (jak silniki składają ścieżkę):
        # host:baza -> baza/ds; gołe user@host (lustro) -> ds; lokalny dst -> dst/ds.
        function landing(ds, dst,    b) {
            if (dst ~ /:/) { b = dst; sub(/^[^:]*:/, "", b); return (b == "") ? ds : b "/" ds }
            if (dst ~ /@/) return ds
            return dst "/" ds
        }
        BEGIN {
            while ((getline l < facts) > 0) {
                split(l, f, "\t")
                if (f[1] == "OWN") { no++; ORoot[no] = f[2]; ORec[no] = f[3]; OPat[no] = f[4] }
                else if (f[1] == "SRC") { ns++; SRoot[ns] = f[2]; SRec[ns] = f[3]; SDst[ns] = f[4]; SId[ns] = f[5]; SAt[ns] = f[6] }
            }
            while ((getline l < marks) > 0) {
                nf = split(l, f, "\t")
                if (nf != 3 || f[1] !~ /#/ || f[2] !~ /^[0-9]+$/ || f[3] !~ /^[0-9]+$/) { print "E\tzły wiersz zakładki: " l; bad = 1; continue }
                d = f[1]; sub(/#.*/, "", d); m = f[1]; sub(/^[^#]*#/, "", m)
                if (m ~ /^tgt-/) {
                    MK[d]++; MG[d, f[2]] = 1; MC[d, m] = f[3]
                    if (!(d in MOLD) || f[3] + 0 < MOLD[d] + 0) MOLD[d] = f[3]
                }
            }
        }
        # Dla datasetu ds: 0 = nie źródło; 1 = źródło, FLOOR[ds] ustawione; 2 = zablokowany (BL).
        function source_state(ds,    k, need, t, fl) {
            if (ds in SST) return SST[ds]
            need = 0; fl = ""
            for (k = 1; k <= ns; k++) {
                if (!under(ds, SRoot[k], SRec[k])) continue
                need = 1
                if (SAt[k] == 1) { BL[ds] = "transfer atomowy (-r) -- silnik nie zapisuje zakładki, baza nieznana"; return SST[ds] = 2 }
                if (SDst[k] ~ /^peer:/) {
                    if (!(ds in MOLD)) { BL[ds] = "udostępniony peerowi " substr(SDst[k], 6) " bez zakładki #tgt- -- baza nieznana"; return SST[ds] = 2 }
                    t = MOLD[ds]
                } else {
                    tg = tag(landing(ds, SDst[k]), SId[k])
                    if (!((ds, tg) in MC)) { BL[ds] = "brak zakładki #" tg " dla celu " SDst[k] " -- baza nieznana"; return SST[ds] = 2 }
                    t = MC[ds, tg]
                }
                if (fl == "" || t + 0 < fl + 0) fl = t
            }
            if (!need) return SST[ds] = 0
            FLOOR[ds] = fl
            return SST[ds] = 1
        }
        {
            if (NF != 4 || $1 !~ /@/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/) { print "E\tzły wiersz migawki: " $0; bad = 1; next }
            ns_++; N[ns_] = $1; CR[ns_] = $2; REF[ns_] = $3; GU[ns_] = $4
            ds = $1; sub(/@.*/, "", ds); DS[ns_] = ds
            if (!(ds in HEAD) || $2 + 0 > CR[HEAD[ds]] + 0) HEAD[ds] = ns_
        }
        END {
            if (bad) exit 3
            for (x = 1; x <= ns_; x++) {
                ds = DS[x]; s = N[x]; sub(/^[^@]*@/, "", s)
                best = ""
                for (k = 1; k <= no; k++)
                    if (under(ds, ORoot[k], ORec[k]) && index(s, OPat[k]) == 1 && length(OPat[k]) > length(best)) best = OPat[k]
                if (best == "") continue                       # nie nasza
                if (REF[x] + 0 > 0) continue                   # pod hold
                # Najnowsza w datasecie i baza transferu LICZĄ SIĘ do N najnowszych
                # rodziny, ale nigdy nie trafiają na listę (PROT).
                if (HEAD[ds] == x) PROT[x] = 1
                # Źródło transferu: każdy cel musi mieć SWOJĄ zakładkę (dokładna nazwa;
                # u peera -- jakakolwiek #tgt-), inaczej dataset zablokowany. Chronione
                # wszystko od najstarszej z tych zakładek w górę: gdy ostatnie odświeżenie
                # zakładki zawiodło, baza jest nowsza od niej -- i dalej chroniona.
                st = source_state(ds)
                if (st == 2) continue
                if (st == 1 && CR[x] + 0 >= FLOOR[ds] + 0) PROT[x] = 1
                if ((ds, GU[x]) in MG) PROT[x] = 1             # każda zakładka #tgt- chroni swoją migawkę
                k2 = ds SUBSEP best; cnt[k2]++; I[k2, cnt[k2]] = x; R[k2] = rank(best)
            }
            for (ds in BL) print "B\t" ds "\t" BL[ds]
            for (k2 in cnt) {
                m = cnt[k2]
                for (i = 1; i <= m; i++) o[i] = I[k2, i]
                for (i = 2; i <= m; i++) { j = i; while (j > 1 && CR[o[j-1]] + 0 > CR[o[j]] + 0) { t = o[j]; o[j] = o[j-1]; o[j-1] = t; j-- } }
                for (i = 1; i <= m - keep; i++) if (!(o[i] in PROT)) print "C\t" R[k2] "\t" CR[o[i]] "\t" N[o[i]]
            }
        }' "$WORK/snaps" > "$WORK/cand" || { grep '^E' "$WORK/cand" | head -1 | cut -f2; [ -s "$WORK/cand" ] || echo "błąd analizy migawek puli $pool"; return 1; }
    return 0
}

rc=0
facts_err=""
facts_err="$(read_managed)" || facts_err="${facts_err:-błąd odczytu crontabów}"
if [ -z "$facts_err" ] && grep -q '^BAD' "$WORK/facts"; then facts_err="$(grep '^BAD' "$WORK/facts" | head -1 | cut -f2)"; fi
if [ -z "$facts_err" ] && ! grep -q '^OWN' "$WORK/facts"; then facts_err="brak lokalnych linii retencji z jawnym wzorcem -- nie wiem, które migawki są nasze"; fi

pools="$(zpool list -H -o name 2>/dev/null)" || { say "zpool list nie działa"; exit 1; }
for pool in $pools; do
    cap="$(cap_of "$pool")"; case "$cap" in ''|*[!0-9]*) continue ;; esac
    if [ "$PLAN" -eq 0 ] && [ "$cap" -lt "$AT" ]; then continue; fi
    [ "$PLAN" -eq 1 ] && echo "Pula $pool: zajętość ${cap}%, bezpiecznik ${GUARD} (czyści od ${AT}% do ${TARGET}%, zostaje ${KEEP} najnowszych w rodzinie)"
    err="$facts_err"
    [ -z "$err" ] && { err="$(candidates "$pool")" || { err="${err:-odczyt puli nie wyszedł}"; }; }
    if [ -n "$err" ]; then
        rc=1
        if [ "$PLAN" -eq 1 ]; then echo "  NIC nie usunie: $err"; continue; fi
        say "pula $pool ${cap}% >= ${AT}% -- NIC nie usuwam: $err"
        alert "$HOST: bezpiecznik NIE zadziałał na puli $pool (${cap}%)" "Pula $pool: ${cap}% (próg ${AT}%). Bezpiecznik nic nie usunął, bo nie mógł bezpiecznie ustalić, co wolno usunąć:
$err
Potrzebna decyzja człowieka."
        continue
    fi
    list="$(grep '^C' "$WORK/cand" | sort -t "$(printf '\t')" -k2,2n -k3,3n | cut -f4)"
    blocked="$(grep '^B' "$WORK/cand" | cut -f2,3 | sed 's/\t/: /')"
    if [ "$PLAN" -eq 1 ]; then
        [ -n "$blocked" ] && printf '  zablokowane (bazy transferu nieznane):\n%s\n' "$(printf '%s\n' "$blocked" | sed 's/^/    /')"
        if [ -z "$list" ]; then echo "  nic do usunięcia (tylko najnowsze, bazy transferu, migawki pod hold albo nie nasze)"; continue; fi
        echo "  usuwałby w tej kolejności, aż zajętość spadnie poniżej ${TARGET}%:"
        printf '%s\n' "$list" | head -40 | sed 's/^/    /'
        [ "$(printf '%s\n' "$list" | grep -c .)" -gt 40 ] && echo "    ... razem $(printf '%s\n' "$list" | grep -c .)"
        continue
    fi
    say "pula $pool ${cap}% >= ${AT}% -- czyszczę do ${TARGET}%"
    gone=""; n=0
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        if zfs destroy "$s" 2>/dev/null; then
            n=$((n + 1)); gone="$gone
  $s"
            say "usunięta $s"
        else
            say "nie dało się usunąć $s (pomijam)"
            continue
        fi
        # TWARDY STOP (REV-20261021-155 F2): bez udanego zpool sync i czytelnej zajętości
        # nie wiadomo, czy następne nieodwracalne usunięcie jest potrzebne. Koniec biegu
        # -- żadnego kolejnego zfs destroy, także na innych pulach; to, co już usunięte,
        # idzie w alercie.
        stop=""
        if ! zpool sync "$pool" 2>/dev/null; then stop="zpool sync $pool zawiódł"
        else
            cap="$(cap_of "$pool")"
            case "$cap" in ''|*[!0-9]*) stop="zajętość puli $pool po usunięciu nieczytelna ('$cap')" ;; esac
        fi
        if [ -n "$stop" ]; then
            say "STOP: $stop -- usunięto migawek: $n, dalej nic nie usuwam"
            alert "$HOST: bezpiecznik ZATRZYMANY na puli $pool" "Bezpiecznik przerwał czyszczenie puli $pool: $stop. Bez pomiaru nie wolno usuwać dalej.
Usunięte do tej chwili:$gone"
            exit 1
        fi
        [ "$cap" -lt "$TARGET" ] && break
    done <<EOF
$list
EOF
    if [ "$cap" -lt "$TARGET" ] 2>/dev/null; then
        say "pula $pool teraz ${cap}% -- usunięto migawek: $n"
        alert "$HOST: bezpiecznik wyczyścił pulę $pool (${cap}%)" "Pula $pool przekroczyła ${AT}%. Bezpiecznik usunął najstarsze migawki (sztuk: $n) (od najdrobniejszego szczebla; najnowsze, bazy transferu i ${KEEP} najnowsze w każdej rodzinie zostały) i zajętość spadła do ${cap}%.
Usunięte:$gone"
    else
        rc=1
        say "pula $pool dalej ${cap}% -- usunięto migawek: $n, więcej bezpiecznie się nie da"
        alert "$HOST: bezpiecznik NIE zwolnił puli $pool (${cap}%)" "Pula $pool: ${cap}% (próg ${AT}%, cel ${TARGET}%). Usunięto migawek: $n; zostały tylko najnowsze, bazy transferu, ${KEEP} w rodzinie, migawki pod hold i nie nasze (np. __replicate_, vzdump, ręczne, rodziny bez jawnego wzorca w retencji).${blocked:+
Zablokowane datasety (bazy transferu nieznane):
$blocked}
Potrzebna decyzja człowieka: więcej miejsca, krótsza retencja albo usunięcie danych.
Usunięte:${gone:- nic}"
    fi
done
exit "$rc"
