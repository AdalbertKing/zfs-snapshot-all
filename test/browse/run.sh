#!/bin/bash
# test/browse/run.sh -- tui/browse.sh (przegladaj kopie), uruchamiany JAKO WYSLANY (`browse.sh --any`),
# na atrapach: zadnego prawdziwego zfs/mount/cryptsetup/urzadzen.
#
# REV-20261021-159: F1 (stan MNT/MAPPED znika dopiero, gdy zasob zniknal; umount -l nie dowodzi
# zamkniecia mappera) i F2 (snapdev zmieniany tylko po odczytaniu wartosci i zrodla; zapis orig.*
# znika wylacznie po udanym przywroceniu; dwa przegladania tego samego dysku).
# REV-20261021-160: klucz zapisu z pelnej nazwy datasetu -- tank/a_b i tank/a/b to dwa zapisy;
# dwa przeplecione przegladania przez punkt wejscia (atrapa mount wstrzymuje sesje), oba porzadki.
# REV-20261021-161: ten sam dataset, dwie sesje, pauza testowa (BROWSE_TEST_PAUSE_AT) pod blokada:
# wchodzacy po sprawdzeniu orig2, a przed znacznikiem; kończacy przed przywroceniem. Wymaga flock.
# REV-20261021-162: SIGTERM w pauzie przywracania (pod blokada) -- pulapka EXIT musi przywrocic
# snapdev bez drugiego flock na wlasnej blokadzie. Pauza jest jednorazowa, sygnal idzie raz.
#
# /dev/tty: browse_and_exit uruchamia mc z </dev/tty >/dev/tty; Enter z /dev/tty czyta TYLKO po
# niepelnym sprzataniu (od U90 czyste odmontowanie wychodzi bez czekania). Bez terminala
# sterujacego otwarcie /dev/tty konczy sie bledem, a skrypt idzie dalej (mc i read maja
# `|| true`/ignorowany rc) -- to wlasnie chcemy. Z terminalem sterujacym `read` by wisial, wiec
# skrypt idzie pod `setsid -w` (bez ctty), jesli setsid jest. Napis "=== Odmontowane" idzie na
# stdout, nie na tty, wiec jest w $D/out. Wyjatek: przypadek 39 (run_pty) daje skryptowi prawdziwy
# terminal, zeby sprawdzic, ze czyste wyjscie NIE czeka na Enter.
PASS=0; FAIL=0
ok(){ echo "PASS $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FB="$(mktemp -d)"; D=""
trap 'rm -rf "$FB" ${D:+"$D"}' EXIT
export TERM="${TERM:-xterm}"
export ZFS_TUI_LANG=pl   # okna po polsku niezależnie od settings.ini hosta (asercje niżej są po polsku)

mkfake(){ cat >"$FB/$1"; chmod +x "$FB/$1"; }

# ---- atrapy (wszystkie czytaja $D ze srodowiska) ----------------------------------------
mkfake id <<'EOF'
#!/bin/bash
[ "${1:-}" = -u ] && { echo 0; exit 0; }
exec "$(PATH=/usr/bin:/bin command -v id)" "$@"
EOF
mkfake whiptail <<'EOF'
#!/bin/bash
for ((i = 1; i <= $#; i++)); do [ "${!i}" = --title ] && { j=$((i + 1)); printf '%s\n' "${!j}" >>"$D/titles"; }; done
# F4 Kopie (2026-10-27): zapis --default-item oraz pozycji menu (tag <TAB> opis), zeby test widzial,
# na ktorej migawce stanal kursor i jak wygladaja etykiety. --menu: tekst, wysokosc, szerokosc, wysokosc listy, potem pary tag/opis.
for ((i = 1; i <= $#; i++)); do
    case "${!i}" in
        --default-item) j=$((i + 1)); printf '%s\n' "${!j}" >>"$D/dflt" ;;
        --menu) for ((j = i + 5; j < $#; j += 2)); do k=$((j + 1)); printf '%s\t%s\n' "${!j}" "${!k}" >>"$D/menus"; done ;;
    esac
done
for ((i = 1; i <= $#; i++)); do
    case "${!i}" in
        --msgbox|--infobox|--gauge) j=$((i + 1)); printf '%s\n' "${!j}" >>"$D/msgs"; exit 0 ;;
    esac
done
[ -s "$D/answers" ] || exit 1
line="$(head -n 1 "$D/answers")"
tail -n +2 "$D/answers" >"$D/answers.new"; mv -f "$D/answers.new" "$D/answers"
case "$line" in
    "OK "*) printf '%s' "${line#OK }" >&2; exit 0 ;;
    *) exit 1 ;;
esac
EOF
mkfake zfs <<'EOF'
#!/bin/bash
echo "zfs $*" >>"$D/log"
last="${@: -1}"
SV="$D/snapdev_value"; SS="$D/snapdev_source"
if [ -e "$D/per_ds" ]; then k="${last%%@*}"; k="${k//\//%}"; SV="$D/sdv.$k"; SS="$D/sds.$k"; fi
case "$*" in
    "list -H -o name -t filesystem,volume") awk '{ print $1 }' "$D/datasets" ;;
    "list -H -o name,type -r -- "*) awk -v x="$last" '$1 == x { printf "%s\t%s\n", $1, $2 }' "$D/datasets" ;;
    "list -H -t snapshot -o name -d 1 -- "*) echo "$last@s1" ;;
    "list -H -p -t snapshot -o name,creation,used,written -s creation -d 1 -- "*)
        # $D/snaps (nazwa<TAB>creation<TAB>used<TAB>written, rosnaco po creation) = wlasne migawki testu
        if [ -e "$D/snaps" ]; then awk -F'\t' -v d="$last" '{ printf "%s@%s\t%s\t%s\t%s\n", d, $1, $2, $3, $4 }' "$D/snaps"
        else printf '%s@s1\t100\n' "$last"; fi ;;
    # --snapshot=DS@SNAP (F4 Kopie, prawy panel): typ datasetu z $D/datasets (brak wpisu = pusto + rc 1) i
    # istnienie migawki (s1 albo wpis w $D/snaps; inna = rc 1, czyli "juz jej nie ma").
    "get -H -o value type -- "*)
        t="$(awk -v x="$last" '$1 == x { print $2; exit }' "$D/datasets" 2>/dev/null)"
        [ -n "$t" ] || exit 1
        echo "$t" ;;
    "list -H -o name -t snapshot -- "*)
        s="${last#*@}"
        [ "$s" = s1 ] && exit 0
        [ -e "$D/snaps" ] && awk -F'\t' -v s="$s" '$1 == s { f = 1 } END { exit !f }' "$D/snaps" && exit 0
        exit 1 ;;
    "get -H -o value snapdev "*) [ -e "$D/fail_get" ] && exit 1; cat "$SV" ;;
    "get -H -o source snapdev "*) [ -e "$D/fail_get" ] && exit 1; cat "$SS" ;;
    # U89: kopia szyfrowana. $D/enc_root = korzen szyfrowania (brak pliku = "-", czyli bez szyfrowania),
    # $D/keystatus (domyslnie available), $D/keyformat (domyslnie passphrase). load-key czyta klucz ze STDIN
    # i zapisuje go w $D/loadkey.stdin (do porownania); unload-key zdejmuje klucz.
    # REV-178: $D/enc_map (wiersz "dataset korzen") = kilka korzeni; stan klucza korzenia w
    # $D/ks.<korzen z / -> %>, gdy taki plik jest (inaczej wspolny $D/keystatus); $D/unload_fail = unload-key pada.
    "get -H -o value encryptionroot -- "*)
        if [ -e "$D/enc_map" ]; then awk -v x="$last" '$1 == x { print $2 }' "$D/enc_map"
        else cat "$D/enc_root" 2>/dev/null || echo -; fi ;;
    "get -H -o value keystatus -- "*) KS="$D/ks.${last//\//%}"; [ -e "$KS" ] || KS="$D/keystatus"; cat "$KS" 2>/dev/null || echo available ;;
    "get -H -o value keyformat -- "*) cat "$D/keyformat" 2>/dev/null || echo passphrase ;;
    "load-key -L prompt -- "*)
        cat >"$D/loadkey.stdin"
        [ -e "$D/loadkey_fail" ] && { echo "Key load error: Incorrect key provided." >&2; exit 1; }
        KS="$D/ks.${last//\//%}"; [ -e "$KS" ] || KS="$D/keystatus"; echo available >"$KS" ;;
    "unload-key -- "*)
        [ -e "$D/unload_fail" ] && { echo "cannot unload key: dataset is busy" >&2; exit 1; }
        KS="$D/ks.${last//\//%}"; [ -e "$KS" ] || KS="$D/keystatus"; echo unavailable >"$KS" ;;
    "set snapdev=visible "*)
        [ -e "$D/fail_set_visible" ] && exit 1
        echo visible >"$SV"
        if ! [ -e "$D/no_device" ]; then mkdir -p "$(dirname "$D/zvol/$last@s1")"; touch "$D/zvol/$last@s1"; fi ;;
    "set snapdev="*)
        [ -e "$D/fail_restore" ] && exit 1
        v="${2#snapdev=}"; echo "$v" >"$SV" ;;
    "inherit snapdev "*|"inherit -S snapdev "*)
        [ -e "$D/fail_restore" ] && exit 1
        echo hidden >"$SV" ;;
    *) exit 1 ;;
esac
exit 0
EOF
mkfake mount <<'EOF'
#!/bin/bash
echo "mount $*" >>"$D/log"
dir="${@: -1}"
# REV-178: $D/mount_fail_once = pierwszy montaz pada (plik znika), nastepny przechodzi.
[ -e "$D/mount_fail_once" ] && { rm -f "$D/mount_fail_once"; echo "mount: unsupported state" >&2; exit 32; }
touch "$D/mounted$(printf %s "$dir" | tr / _)"
# TESTID ustawione = sesja stoi zamontowana (jak w mc; prawdziwe mc bez /dev/tty nie rusza), az test
# pozwoli jej isc dalej (go.<id>).
if [ -n "${TESTID:-}" ]; then
    echo "$PPID" >"$D/mpid.$TESTID"   # PID browse.sh (mount_ro wola mount bez podpowloki) -- dla testu sygnalu
    touch "$D/inmc.$TESTID"
    for ((n = 0; n < 400; n++)); do [ -e "$D/go.$TESTID" ] && break; /bin/sleep 0.05 2>/dev/null || /usr/bin/sleep 0.05; done
fi
exit 0
EOF
mkfake mountpoint <<'EOF'
#!/bin/bash
dir="${@: -1}"
[ -e "$D/mounted$(printf %s "$dir" | tr / _)" ]
EOF
mkfake umount <<'EOF'
#!/bin/bash
echo "umount $*" >>"$D/log"
dir="${@: -1}"; mk="$D/mounted$(printf %s "$dir" | tr / _)"
if [ "${1:-}" = -l ]; then
    [ -e "$D/lazy_ok" ] || exit 1
    rm -f "$mk"; exit 0
fi
[ -e "$D/umount_fail" ] && exit 1
rm -f "$mk"; exit 0
EOF
mkfake cryptsetup <<'EOF'
#!/bin/bash
echo "cryptsetup $*" >>"$D/log"
case "$1" in
    open) cat >/dev/null; mkdir -p "$D/mapper"; touch "$D/mapper/${@: -1}"; exit 0 ;;
    close) [ -e "$D/close_fail" ] && exit 1; rm -f "$D/mapper/$2"; exit 0 ;;
esac
exit 1
EOF
mkfake lsblk <<'EOF'
#!/bin/bash
echo "lsblk $*" >>"$D/log"
fs="$(cat "$D/partfs")"
printf '{"blockdevices":[{"name":"/dev/zd0","fstype":null,"size":"1G","label":null,"children":[{"name":"/dev/zd0p1","fstype":"%s","size":"1G","label":null}]}]}\n' "$fs"
EOF
mkfake blkid <<'EOF'
#!/bin/bash
echo ext4
EOF
mkfake readlink <<'EOF'
#!/bin/bash
[ "${1:-}" = -f ] && { echo "$2"; exit 0; }
exec "$(PATH=/usr/bin:/bin command -v readlink)" "$@"
EOF
# U68: wybór datasetu to drzewo (tree.py) w trybie jednej pozycji. Atrapa rozumie te same
# odpowiedzi co dawne menu: "OK dN" = N-ty wybieralny dataset (kolejność cand.tsv), inna = Esc.
mkfake tree <<'EOF'
#!/bin/bash
spec=""; out=""
while [ $# -gt 0 ]; do case "$1" in --spec) spec="$2"; shift 2 ;; --out) out="$2"; shift 2 ;; *) shift ;; esac; done
cp "$spec" "$D/tree-spec.last" 2>/dev/null
line="$(head -n 1 "$D/answers")"; tail -n +2 "$D/answers" >"$D/answers.new"; mv -f "$D/answers.new" "$D/answers"
case "$line" in "OK d"*) k="${line#OK d}" ;; *) printf '{"action":"back","roots":[]}' >"$out"; exit 1 ;; esac
python3 - "$spec" "$out" "$k" <<'P'
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8")); sel = s.get("selectable") or []
k = int(sys.argv[3])
json.dump({"action": "next", "roots": [sel[k]] if k < len(sel) else []}, open(sys.argv[2], "w"))
P
EOF
# F4 Kopie: tryb relacji (browse.sh REL ...) pyta zfs-backup.sh restore --plan o datasety kopii;
# atrapa oddaje te z $D/plan-copies (po jednym w linii), wszystkie "copy_exists".
mkfake zb <<'EOF'
#!/bin/bash
echo "zb $*" >>"$D/log"
if [ "${1:-}" = restore ] && [ "${2:-}" = --plan ]; then
    python3 - "$D/plan-copies" <<'P'
import json, sys
c = [l.strip() for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
print(json.dumps({"datasets": [{"copy": x, "copy_exists": True} for x in c]}))
P
    exit 0
fi
exit 1
EOF
for n in udevadm modinfo clear sleep mc; do
    printf '#!/bin/bash\nexit 0\n' >"$FB/$n"; chmod +x "$FB/$n"
done

# ---- pomocniki --------------------------------------------------------------------------
errs=()
new_case(){   # <nazwa>: swiezy $D z atrapami
    CASE="$1"; errs=()
    [ -n "$D" ] && rm -rf "$D"
    D="$(mktemp -d)"; export D
    mkdir -p "$D/run" "$D/mapper" "$D/zvol" "$D/conf"
    cp -r "$FB" "$D/bin"
    : >"$D/log"; : >"$D/msgs"; : >"$D/answers"
}
fs_case(){ printf 'tank/fs filesystem\n' >"$D/datasets"; printf 'OK d0\nOK p0\n' >"$D/answers"; }
vol_case(){   # <partfs>: dysk VM, snapdev hidden/local
    printf 'tank/vol volume\n' >"$D/datasets"; printf '%s\n' "$1" >"$D/partfs"
    printf 'hidden\n' >"$D/snapdev_value"; printf 'local\n' >"$D/snapdev_source"
    printf 'OK d0\nOK p0\n' >"$D/answers"
    [ "$1" = crypto_LUKS ] && printf 'OK secret\n' >>"$D/answers"
    return 0
}
run_script(){   # -> rc w $rc, stdout+stderr w $D/out
    local runner=()
    command -v setsid >/dev/null 2>&1 && runner=(setsid -w)
    # BROWSE_RO_NS=0: przestrzen tylko-do-odczytu wymaga roota i unshare; testy ida zwyklym torem mc.
    # BROWSE_RECOVER_DIR: prawy panel mc (2. argument) = $D/odz/<dataset@migawka>, nie ~/odzysk.
    PATH="$D/bin:$PATH" WHIPTAIL="$D/bin/whiptail" BROWSE_MC="$D/bin/mc" BROWSE_ROOT="$D/run" ZFS_TREE="$D/bin/tree" \
        BROWSE_MAPPER_DIR="$D/mapper" BROWSE_ZVOL_DIR="$D/zvol" ZFS_CONF_DIR="$D/conf" BROWSE_RO_NS=0 BROWSE_RECOVER_DIR="$D/odz" \
        "${runner[@]}" bash "$REPO/tui/browse.sh" --any </dev/null >"$D/out" 2>&1
    rc=$?
}
run_any(){   # [opcje browse.sh...] -> rc w $rc, stdout+stderr w $D/out; jak run_script, ale z opcjami (np. --snapshot=DS@SNAP)
    local runner=()
    command -v setsid >/dev/null 2>&1 && runner=(setsid -w)
    PATH="$D/bin:$PATH" WHIPTAIL="$D/bin/whiptail" BROWSE_MC="$D/bin/mc" BROWSE_ROOT="$D/run" ZFS_TREE="$D/bin/tree" \
        BROWSE_MAPPER_DIR="$D/mapper" BROWSE_ZVOL_DIR="$D/zvol" ZFS_CONF_DIR="$D/conf" BROWSE_RO_NS=0 BROWSE_RECOVER_DIR="$D/odz" \
        "${runner[@]}" bash "$REPO/tui/browse.sh" --any "$@" </dev/null >"$D/out" 2>&1
    rc=$?
}
run_rel(){   # [opcje browse.sh...] -> rc w $rc, stdout+stderr w $D/out; tryb RELACJI (rel1), nie --any
    local runner=()
    command -v setsid >/dev/null 2>&1 && runner=(setsid -w)
    PATH="$D/bin:$PATH" WHIPTAIL="$D/bin/whiptail" BROWSE_MC="$D/bin/mc" BROWSE_ROOT="$D/run" ZFS_TREE="$D/bin/tree" ZFS_BACKUP="$D/bin/zb" \
        BROWSE_MAPPER_DIR="$D/mapper" BROWSE_ZVOL_DIR="$D/zvol" ZFS_CONF_DIR="$D/conf" BROWSE_RO_NS=0 BROWSE_RECOVER_DIR="$D/odz" \
        "${runner[@]}" bash "$REPO/tui/browse.sh" rel1 "$@" </dev/null >"$D/out" 2>&1
    rc=$?
}
rel_case(){   # <dataset kopii...>: kopie relacji rel1 (filesystem), plan z atrapy zb; migawki z $D/snaps, jesli test je poda
    local c; : >"$D/plan-copies"; : >"$D/datasets"; : >"$D/conf/jobs.t.conf"
    for c in "$@"; do printf '%s\n' "$c" >>"$D/plan-copies"; printf '%s filesystem\n' "$c" >>"$D/datasets"; done
}
snaps3(){   # trzy migawki: creation 1000/2000/3000 (rosnaco), rozmiary o roznej dlugosci
    printf 'xsnap-1\t1000\t0\t0\nxsnap-2\t2000\t2048\t1024\nxsnap-3\t3000\t10485760\t5368709120\n' >"$D/snaps"
}
key(){ printf '%s' "$1" | sha256sum | cut -c1-32; }
run_bg(){   # <id> [pauza]: sesja w tle, wstrzymana po montazu (i w punkcie <pauza>); rc w $D/rc.<id>
    local runner=()
    command -v setsid >/dev/null 2>&1 && runner=(setsid -w)
    ( BROWSE_TEST_PAUSE_AT="${2:-}" BROWSE_TEST_PAUSE="${2:+$D/p.$1}" PATH="$D/bin:$PATH" WHIPTAIL="$D/bin/whiptail" BROWSE_MC="$D/bin/mc" BROWSE_ROOT="$D/run" ZFS_TREE="$D/bin/tree" \
        BROWSE_MAPPER_DIR="$D/mapper" BROWSE_ZVOL_DIR="$D/zvol" ZFS_CONF_DIR="$D/conf" BROWSE_RO_NS=0 BROWSE_RECOVER_DIR="$D/odz" TESTID="$1" \
        "${runner[@]}" bash "$REPO/tui/browse.sh" --any </dev/null >"$D/out.$1" 2>&1
      echo $? >"$D/rc.$1" ) &
}
waitf(){ local n; for ((n = 0; n < 300; n++)); do [ -e "$1" ] && return 0; sleep 0.1; done; errs+=("nie doczekalem sie $1"); return 1; }
start_ds(){   # <id> <dataset> <value> <source>: sesja na datasecie, czeka zamontowana
    local k="${2//\//%}"
    printf '%s volume\n' "$2" >"$D/datasets"
    printf '%s\n' "$3" >"$D/sdv.$k"; printf '%s\n' "$4" >"$D/sds.$k"
    printf 'OK d0\nOK p0\n' >"$D/answers"
    run_bg "$1"; waitf "$D/inmc.$1"
}
enter(){   # <id> [pauza]: kolejna sesja na tank/vol (wartosci juz w sdv/sds), bez czekania
    printf 'tank/vol volume\n' >"$D/datasets"; printf 'OK d0\nOK p0\n' >"$D/answers"
    run_bg "$1" "${2:-}"
}
still_running(){   # <id> <opis>: po 1.5 s sesja nadal stoi (czeka na blokade)
    sleep 1.5; [ -e "$D/rc.$1" ] && errs+=("$2: sesja $1 skonczyla, zamiast czekac na blokade: $(tail -2 "$D/out.$1")"); return 0
}
same_end(){   # wspolne sprawdzenie po wyscigu na tank/vol (oryginal hidden)
    [ "$(cat "$D/rc.A" 2>/dev/null)" = 0 ] || errs+=("rc A=$(cat "$D/rc.A" 2>/dev/null): $(tail -3 "$D/out.A")")
    [ "$(cat "$D/rc.B" 2>/dev/null)" = 0 ] || errs+=("rc B=$(cat "$D/rc.B" 2>/dev/null): $(tail -3 "$D/out.B")")
    [ "$(cat "$D/sdv.tank%vol")" = hidden ] || errs+=("tank/vol po wszystkim: $(cat "$D/sdv.tank%vol") (bylo hidden)")
    ls "$D"/run/orig* "$D"/run/hold* >/dev/null 2>&1 && errs+=("zostaly zapisy: $(ls "$D/run")")
    grep -q "NIE wszystko" "$D/out.A" "$D/out.B" 2>/dev/null && errs+=("pozostalosc zgloszona")
    return 0
}
race_enter(){   # <zrodlo> <nazwa>: B stoi po sprawdzeniu orig2, A konczy, B rusza
    new_case "$2"
    touch "$D/per_ds"; printf 'ext4\n' >"$D/partfs"
    start_ds A tank/vol hidden "$1"
    enter B expose; waitf "$D/p.B.at"
    touch "$D/go.A"; still_running A "A przy B miedzy sprawdzeniem a znacznikiem"
    touch "$D/p.B.go"; waitf "$D/inmc.B"; waitf "$D/rc.A"
    finish B; same_end
}
finish(){ touch "$D/go.$1"; waitf "$D/rc.$1"; }
interleave(){   # <pierwszy konczy> <drugi konczy>
    new_case "$3"
    touch "$D/per_ds"; printf 'ext4\n' >"$D/partfs"
    start_ds A tank/a_b hidden local
    start_ds B tank/a/b visible local
    finish "$1"; finish "$2"
    [ "$(cat "$D/rc.A" 2>/dev/null)" = 0 ] || errs+=("rc A=$(cat "$D/rc.A" 2>/dev/null): $(tail -3 "$D/out.A")")
    [ "$(cat "$D/rc.B" 2>/dev/null)" = 0 ] || errs+=("rc B=$(cat "$D/rc.B" 2>/dev/null): $(tail -3 "$D/out.B")")
    [ "$(cat "$D/sdv.tank%a_b")" = hidden ] || errs+=("tank/a_b po wszystkim: $(cat "$D/sdv.tank%a_b") (bylo hidden)")
    [ "$(cat "$D/sdv.tank%a%b")" = visible ] || errs+=("tank/a/b po wszystkim: $(cat "$D/sdv.tank%a%b") (bylo visible)")
    lg '^zfs get -H -o value snapdev tank/a_b$'; lg '^zfs get -H -o value snapdev tank/a/b$'
    nolg '^zfs set snapdev=hidden tank/a/b'; nolg '^zfs inherit'
    lg '^zfs set snapdev=hidden tank/a_b$'
    ls "$D"/run/orig* "$D"/run/hold* >/dev/null 2>&1 && errs+=("zostaly zapisy: $(ls "$D/run")")
    fin
}
has(){ grep -qF -- "$2" "$D/$1" || errs+=("brak '$2' w $1"); }
hasnt(){ grep -qF -- "$2" "$D/$1" && errs+=("jest '$2' w $1"); return 0; }
lg(){ grep -qE -- "$1" "$D/log" || errs+=("brak w log: $1"); }
nolg(){ grep -qE -- "$1" "$D/log" && errs+=("jest w log: $1"); return 0; }
rc0(){ [ "$rc" -eq 0 ] || errs+=("rc=$rc, oczekiwano 0"); }
rcnz(){ [ "$rc" -ne 0 ] || errs+=("rc=0, oczekiwano != 0"); }
nomarker(){ ls "$D"/mounted* >/dev/null 2>&1 && errs+=("kopia wciaz oznaczona jako zamontowana"); return 0; }
fin(){ if [ ${#errs[@]} -eq 0 ]; then ok "$CASE"; else bad "$CASE" "${errs[@]}"; fi; }

# ---- F1: zasob znika zanim stan zniknie ---------------------------------------------------
new_case "1 filesystem: normalny sukces"
fs_case; run_script
rc0; has out "=== Odmontowane"; hasnt out "NIE wszystko"; nomarker; fin

new_case "2 filesystem: zwykle umount pada, lazy przechodzi -> odlaczona, ale zgloszona (nie 'Odmontowane'), rc!=0"
fs_case; touch "$D/umount_fail" "$D/lazy_ok"; run_script
rcnz; has out "odłączona leniwie"; hasnt out "=== Odmontowane"; nomarker; fin

new_case "3 filesystem: umount i lazy padaja -> kopia zostaje, ponowna proba przy EXIT"
fs_case; touch "$D/umount_fail"; run_script
rcnz; has out "NIE wszystko posprzątane"; has out "kopia wciąż zamontowana"; hasnt out "=== Odmontowane"
[ "$(grep -c '^umount ' "$D/log")" -ge 3 ] || errs+=("umount probowany < 3 razy: $(grep -c '^umount ' "$D/log")")
fin

new_case "4 LUKS: cryptsetup close pada -> mapper zostaje, ostrzezenie"
vol_case crypto_LUKS; touch "$D/close_fail"; run_script
rcnz; has out "nie udało się zamknąć"; has out "cryptsetup close"
compgen -G "$D/mapper/zbrowse-*" >/dev/null || errs+=("mapper zniknal mimo close_fail")
[ "$(grep -c '^cryptsetup close' "$D/log")" -ge 2 ] || errs+=("brak ponownej proby cryptsetup close przy wyjsciu: $(grep -c '^cryptsetup close' "$D/log")")
fin

new_case "5 LUKS: close przechodzi -> mapper pusty, snapdev wrocil"
vol_case crypto_LUKS; run_script
rc0; has out "=== Odmontowane"
[ -z "$(ls -A "$D/mapper")" ] || errs+=("mapper nie pusty: $(ls "$D/mapper")")
[ "$(cat "$D/snapdev_value")" = hidden ] || errs+=("snapdev=$(cat "$D/snapdev_value"), oczekiwano hidden")
fin

new_case "6 LUKS: odlaczenie leniwe -> mapper zostaje otwarty, bez cryptsetup close"
vol_case crypto_LUKS; touch "$D/umount_fail" "$D/lazy_ok"; run_script
rcnz; has out "odłączony leniwie"
compgen -G "$D/mapper/zbrowse-*" >/dev/null || errs+=("mapper zamkniety mimo umount -l")
nolg '^cryptsetup close'
fin

# ---- F2: snapdev ----------------------------------------------------------------------------
new_case "7 snapdev: oryginal local hidden wraca, zapis orig znika"
vol_case ext4; run_script
rc0; has out "=== Odmontowane"
[ "$(cat "$D/snapdev_value")" = hidden ] || errs+=("snapdev=$(cat "$D/snapdev_value")")
lg '^zfs set snapdev=hidden tank/vol'
ls "$D"/run/orig* >/dev/null 2>&1 && errs+=("orig* zostal")
fin

new_case "8 snapdev: oryginal odziedziczony -> zfs inherit"
vol_case ext4; printf 'inherited from tank\n' >"$D/snapdev_source"; run_script
rc0
lg '^zfs inherit snapdev tank/vol'; nolg '^zfs set snapdev=hidden'
ls "$D"/run/orig* >/dev/null 2>&1 && errs+=("orig* zostal")
fin

new_case "9 snapdev: odczyt poczatkowy pada -> nic nie zmieniam"
vol_case ext4; touch "$D/fail_get"; run_script
has msgs "nie da się odczytać snapdev"; nolg '^zfs set snapdev=visible'
fin

new_case "10 snapdev: set visible pada -> bez montazu, wartosc bez zmian"
vol_case ext4; touch "$D/fail_set_visible"; run_script
hasnt out "=== Odmontowane"; nolg '^mount '
[ "$(cat "$D/snapdev_value")" = hidden ] || errs+=("snapdev=$(cat "$D/snapdev_value")")
fin

new_case "11 snapdev: brak urzadzenia + nieudane przywrocenie -> nie 'Nic nie zostało zmienione', zapis zostaje"
vol_case ext4; touch "$D/no_device" "$D/fail_restore"; run_script
hasnt msgs "Nic nie zostało zmienione"
cat "$D/msgs" "$D/out" | grep -qF "NIE przywrócony" || errs+=("brak 'NIE przywrócony' w msgs/out")
[ -e "$D/run/orig2.$(key tank/vol)" ] || errs+=("zapis orig2 tank/vol zniknal mimo nieudanego przywrocenia")
fin

new_case "12 snapdev: drugi zywy trzymajacy -> brak przywrocenia, orig zostaje"
vol_case ext4
sleep 30 & H=$!
touch "$D/run/hold2.$H.$(key tank/vol)"; printf 'tank/vol\thidden\tlocal\n' >"$D/run/orig2.$(key tank/vol)"
run_script
kill "$H" 2>/dev/null; wait "$H" 2>/dev/null
rc0; nolg '^zfs set snapdev=hidden'; nolg '^zfs inherit'
[ -e "$D/run/orig2.$(key tank/vol)" ] || errs+=("orig2 tank/vol zniknal mimo drugiego trzymajacego")
fin

new_case "13 pozostalosc, potem powrot do menu i Anuluj -> kod wyjscia nadal != 0"
vol_case ext4; touch "$D/no_device" "$D/fail_restore"; run_script
rcnz; has out "NIE wszystko posprzątane"; fin

new_case "14 zapis orig istnieje, ale jest pusty -> nic nie zmieniam (bez nadpisania)"
vol_case ext4; mkdir -p "$D/run"; : >"$D/run/orig2.$(key tank/vol)"; run_script
grep -q '^zfs set snapdev=visible' "$D/log" && errs+=("snapdev=visible mimo pustego zapisu")
[ -e "$D/run/orig2.$(key tank/vol)" ] && ! [ -s "$D/run/orig2.$(key tank/vol)" ] || errs+=("pusty zapis zostal nadpisany albo usuniety")
fin

# ---- REV-20261021-160: rozne datasety o sklejanej dawniej nazwie ---------------------------
interleave A B "15 tank/a_b (hidden) i tank/a/b (visible) naraz, A konczy pierwszy -> kazdy wraca do SWOJEJ wartosci"
interleave B A "16 to samo, B konczy pierwszy -> kazdy wraca do SWOJEJ wartosci"

new_case "17 stary zapis orig.tank_a_b (sprzed poprawki) -> nic nie zmieniam, zapis zostaje"
vol_case ext4; printf 'tank/a/b volume\n' >"$D/datasets"; printf 'visible\tlocal\n' >"$D/run/orig.tank_a_b"; run_script
nolg '^zfs set snapdev=visible'; has msgs "stary zapis"
[ "$(cat "$D/run/orig.tank_a_b")" = "$(printf 'visible\tlocal')" ] || errs+=("stary zapis zmieniony albo usuniety")
fin

new_case "18 zapis orig2 pod kluczem B nalezy do innego datasetu -> nic nie zmieniam, zapis zostaje"
vol_case ext4; printf 'tank/a/b volume\n' >"$D/datasets"
printf 'tank/inny\thidden\tlocal\n' >"$D/run/orig2.$(key tank/a/b)"; run_script
nolg '^zfs set snapdev=visible'; has msgs "należy do 'tank/inny'"
grep -q '^tank/inny' "$D/run/orig2.$(key tank/a/b)" || errs+=("cudzy zapis zmieniony albo usuniety")
fin

# ---- REV-20261021-161: ten sam dataset, wejscie i wyjscie pod jedna blokada --------------
if command -v flock >/dev/null 2>&1; then
race_enter local "19 tank/vol: B sprawdzil orig2, A konczy, B zaklada znacznik -> A czeka, nie przywraca; B przywraca hidden"
lg '^zfs set snapdev=hidden tank/vol$'; [ "$(grep -c '^zfs set snapdev=hidden' "$D/log")" = 1 ] || errs+=("przywrocen: $(grep -c '^zfs set snapdev=hidden' "$D/log") (oczekiwano 1, przez B)")
fin

race_enter "inherited from tank" "20 to samo, oryginal odziedziczony -> jedno zfs inherit (przez B), bez set hidden"
[ "$(grep -c '^zfs inherit snapdev tank/vol$' "$D/log")" = 1 ] || errs+=("zfs inherit: $(grep -c '^zfs inherit snapdev tank/vol$' "$D/log") (oczekiwano 1)")
nolg '^zfs set snapdev=hidden'; fin

new_case "21 odwrotnie: A stoi przed przywroceniem, B wchodzi -> B czeka; A przywraca i usuwa zapis, B czyta od nowa"
touch "$D/per_ds"; printf 'ext4\n' >"$D/partfs"
printf 'tank/vol volume\n' >"$D/datasets"; printf 'hidden\n' >"$D/sdv.tank%vol"; printf 'local\n' >"$D/sds.tank%vol"
printf 'OK d0\nOK p0\n' >"$D/answers"; run_bg A restore; waitf "$D/inmc.A"
touch "$D/go.A"; waitf "$D/p.A.at"
enter B; still_running B "B przy A przed przywroceniem"
[ -e "$D/inmc.B" ] && errs+=("B zamontowal, gdy A trzymal blokade")
touch "$D/p.A.go"; waitf "$D/rc.A"; waitf "$D/inmc.B"
finish B; same_end
[ "$(grep -c '^zfs get -H -o value snapdev tank/vol$' "$D/log")" = 2 ] || errs+=("odczytow snapdev: $(grep -c '^zfs get -H -o value snapdev tank/vol$' "$D/log") (oczekiwano 2: B czyta po A)")
fin

new_case "22 blokada trzymana przez kogos innego -> nic nie zmieniam (bez snapdev=visible, bez zapisu)"
vol_case ext4
( flock 9; : >"$D/locked"; sleep 4 ) 9>>"$D/run/lock2.$(key tank/vol)" &
lk=$!; waitf "$D/locked"
export BROWSE_LOCK_WAIT=1; run_script; unset BROWSE_LOCK_WAIT
nolg '^zfs set snapdev=visible'; has msgs "nie mogę zablokować"
ls "$D"/run/orig2.* "$D"/run/hold2.* >/dev/null 2>&1 && errs+=("powstal zapis mimo braku blokady: $(ls "$D/run")")
wait "$lk" 2>/dev/null; fin

new_case "23 martwy znacznik + poprawny zapis -> znacznik sprzatniety, hidden przywrocony z zapisu"
vol_case ext4; printf 'visible\n' >"$D/snapdev_value"
bash -c 'exit 0' & dead=$!; wait "$dead"
touch "$D/run/hold2.$dead.$(key tank/vol)"; printf 'tank/vol\thidden\tlocal\n' >"$D/run/orig2.$(key tank/vol)"
run_script
rc0; [ "$(cat "$D/snapdev_value")" = hidden ] || errs+=("snapdev po wszystkim: $(cat "$D/snapdev_value") (zapis mowil hidden)")
ls "$D"/run/orig2.* "$D"/run/hold2.* >/dev/null 2>&1 && errs+=("zostaly zapisy: $(ls "$D/run")")
fin
term_restore(){   # <zrodlo> <nazwa>: A w pauzie przywracania dostaje jeden SIGTERM
    new_case "$2"
    touch "$D/per_ds"; printf 'ext4\n' >"$D/partfs"
    printf 'tank/vol volume\n' >"$D/datasets"; printf 'hidden\n' >"$D/sdv.tank%vol"; printf '%s\n' "$1" >"$D/sds.tank%vol"
    printf 'OK d0\nOK p0\n' >"$D/answers"; run_bg A restore; waitf "$D/inmc.A"
    touch "$D/go.A"; waitf "$D/p.A.at"
    local t0=$SECONDS
    kill -TERM "$(cat "$D/p.A.at")"; waitf "$D/rc.A"
    [ $((SECONDS - t0)) -lt 10 ] || errs+=("sprzatanie po SIGTERM trwalo $((SECONDS - t0)) s (czekalo na wlasna blokade?)")
    [ "$(cat "$D/rc.A" 2>/dev/null)" != 0 ] || errs+=("rc po SIGTERM = 0, oczekiwano != 0")
    [ "$(cat "$D/sdv.tank%vol")" = hidden ] || errs+=("snapdev po SIGTERM: $(cat "$D/sdv.tank%vol") (oczekiwano hidden)")
    ls "$D"/run/orig* "$D"/run/hold* >/dev/null 2>&1 && errs+=("zostaly zapisy: $(ls "$D/run")")
    grep -q "nie mogę zablokować" "$D/out.A" && errs+=("sprzatanie nie wzielo wlasnej blokady")
    [ -e "$D/p.A.go" ] && errs+=("test zwolnil pauze -- mial tylko wyslac sygnal")
    return 0
}
term_restore local "24 SIGTERM podczas przywracania pod blokada -> EXIT przywraca hidden bez samozakleszczenia"
[ "$(grep -c '^zfs set snapdev=hidden tank/vol$' "$D/log")" = 1 ] || errs+=("set hidden: $(grep -c '^zfs set snapdev=hidden tank/vol$' "$D/log") (oczekiwano 1)")
fin

term_restore "inherited from tank" "25 to samo, oryginal odziedziczony -> jedno zfs inherit, bez set hidden"
[ "$(grep -c '^zfs inherit snapdev tank/vol$' "$D/log")" = 1 ] || errs+=("zfs inherit: $(grep -c '^zfs inherit snapdev tank/vol$' "$D/log") (oczekiwano 1)")
nolg '^zfs set snapdev=hidden'; fin
else
    echo "SKIP 19-25: brak flock (REV-161/162 wymagaja flock; uruchom na hoscie albo w CI)"
fi

# ---- U68: wybór datasetu = drzewo w trybie jednej pozycji -------------------------------
new_case "26 U68: wybór datasetu to drzewo (single), wybieralne = datasety z migawką, gałęzie nad nimi do nawigacji"
printf 'tank/fs filesystem\n' >"$D/datasets"; printf 'OK d0\nOK p0\n' >"$D/answers"; run_script
python3 - "$D/tree-spec.last" <<'P' >"$D/spec.chk" 2>&1
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
names = [d["name"] for d in s["datasets"]]
print("single=%s sel=%s tank=%s fs=%s" % (s.get("single"), s.get("selectable"), "tank" in names, "tank/fs" in names))
P
grep -q "single=True sel=\['tank/fs'\] tank=True fs=True" "$D/spec.chk" || errs+=("spec drzewa: $(cat "$D/spec.chk")")
has out "=== Odmontowane"; fin

# ---- I-2: jedna partycja = bez okna wyboru partycji ----------------------------------------
new_case "27 I-2: dysk VM z jedna partycja -- bez okna 'która partycja?', montuje od razu"
: >"$D/titles"; vol_case ext4; run_script
grep -q 'która partycja' "$D/titles" && errs+=("okno wyboru partycji przy jednej partycji: $(cat "$D/titles")")
has out "=== Odmontowane"; fin

# ---- F4 Kopie (2026-10-27): browse.sh REL [--dataset=DS] [--at=EPOCH] -----------------------
new_case "28 --dataset= z listy kandydatow: drzewo pominiete, od razu menu migawek TEGO datasetu"
rel_case tank/c1 tank/c2; snaps3; printf 'OK p0\n' >"$D/answers"
run_rel --dataset=tank/c2
rc0
[ ! -e "$D/tree-spec.last" ] || errs+=("drzewo uruchomione mimo --dataset= z listy kandydatow")
lg '^zfs list -H -p -t snapshot -o name,creation,used,written -s creation -d 1 -- tank/c2$'
lg '^mount -t zfs -o ro tank/c2@xsnap-3 '; nolg '^mount .* tank/c1@'
has out "=== Odmontowane"; fin

new_case "29 kontrola: --dataset= spoza kandydatow -> drzewo jednak sie otwiera (pierwsza pozycja drzewa)"
rel_case tank/c1 tank/c2; snaps3; printf 'OK d0\nOK p0\n' >"$D/answers"
run_rel --dataset=tank/nie-ma
rc0
[ -e "$D/tree-spec.last" ] || errs+=("drzewo nie uruchomione, choc --dataset= nie jest kandydatem")
lg '^mount -t zfs -o ro tank/c1@xsnap-3 '
has out "=== Odmontowane"; fin

at_case(){   # <opis> <--at=> <oczekiwany --default-item albo "-" = brak>; migawki 1000/2000/3000, najnowsza = p0
    new_case "$1"
    rel_case tank/c1; snaps3; printf 'OK p0\n' >"$D/answers"
    run_rel --dataset=tank/c1 "--at=$2"
    rc0
    if [ "$3" = - ]; then
        [ ! -s "$D/dflt" ] || errs+=("--default-item=$(cat "$D/dflt") mimo chwili sprzed wszystkich migawek")
    else
        [ "$(cat "$D/dflt" 2>/dev/null)" = "$3" ] || errs+=("--default-item=$(cat "$D/dflt" 2>/dev/null), oczekiwano $3")
    fi
    fin
}
at_case "30 --at=2500 (miedzy 2000 a 3000) -> kursor na najnowszej migawce nie pozniejszej: p1 (xsnap-2)" 2500 p1
at_case "31 --at=2000 (rowno z migawka) -> p1: nie pozniejsza = wlacznie" 2000 p1
at_case "32 --at=9999 (po wszystkich) -> p0, najnowsza" 9999 p0
at_case "33 --at=500 (przed wszystkimi) -> brak --default-item" 500 -

new_case "34 rozmiary migawek do prawej, szerokosc 6 -> nazwy migawek zaczynaja sie w tej samej kolumnie"
rel_case tank/c1; snaps3; printf 'OK p0\n' >"$D/answers"
run_rel --dataset=tank/c1
rc0
[ "$(grep -c . "$D/menus")" -eq 3 ] || errs+=("pozycji menu: $(grep -c . "$D/menus") (oczekiwano 3)")
has menus 'zajmuje     0B, zmian     0B'; has menus 'zajmuje   2.0K, zmian   1.0K'; has menus 'zajmuje  10.0M, zmian   5.0G'
cols="$(awk -F'\t' '{ print index($2, "xsnap-") }' "$D/menus" | sort -u)"
{ [ "$(printf '%s\n' "$cols" | grep -c .)" -eq 1 ] && [ "${cols:-0}" -gt 1 ]; } || errs+=("kolumna nazwy migawki rozna albo brak: $(printf '%s' "$cols" | tr '\n' ' ')")
fin

new_case "35 drzewo: spec niesie expand_to = kandydaci (galezie nad nimi otwarte od razu)"
rel_case tank/c1 tank/c2; printf 'OK d0\nOK p0\n' >"$D/answers"
run_rel
python3 - "$D/tree-spec.last" <<'P' >"$D/spec.chk" 2>&1
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
print("expand=%s sel=%s" % (s.get("expand_to"), s.get("selectable")))
P
grep -q "expand=\['tank/c1', 'tank/c2'\] sel=\['tank/c1', 'tank/c2'\]" "$D/spec.chk" || errs+=("spec drzewa: $(cat "$D/spec.chk")")
fin

# ---- 2026-10-27 (U87-U90): tytul z hostem, katalog montazu, drzewo --any, wyjscie bez Entera, klucz ---
HN="$(hostname)"; HS="$(hostname -s 2>/dev/null || hostname)"

new_case "36 U87: tytul okna --any niesie host: 'Przeglądaj kopię na HOST'"
: >"$D/titles"; fs_case; run_script
rc0
grep -qF "Przeglądaj kopię na $HN: z kiedy?" "$D/titles" || errs+=("tytul --any: $(cat "$D/titles")")
fin

new_case "36b U87: tytul okna relacji niesie host: 'Przeglądaj rel1 na HOST'"
: >"$D/titles"; rel_case tank/c1; snaps3; printf 'OK p0\n' >"$D/answers"; run_rel --dataset=tank/c1
rc0
grep -qF "Przeglądaj rel1 na $HN: z kiedy?" "$D/titles" || errs+=("tytul relacji: $(cat "$D/titles")")
fin

new_case "37 U87: katalog montazu = <host -s>_<dataset z / -> ~>@<migawka>.XXXXXX (nie 'browse.XXXXXX')"
fs_case; run_script
rc0
MNTDIR="$(grep '^mount -t zfs -o ro tank/fs@s1 ' "$D/log" | awk '{ print $NF }')"
case "${MNTDIR##*/}" in
    "${HS}_tank~fs@s1."??????) ;;
    *) errs+=("katalog montazu: '${MNTDIR:-brak wiersza mount w logu}' (oczekiwano ${HS}_tank~fs@s1.XXXXXX)") ;;
esac
case "$MNTDIR" in "$D/run/"*) ;; *) errs+=("katalog montazu poza BROWSE_ROOT: '$MNTDIR'") ;; esac
fin

new_case "37b U102: gleboki dataset -> w nazwie katalogu tylko dwa ostatnie czlony"
printf 'hdd/backups/h/data/vm1 filesystem\n' >"$D/datasets"; printf 'OK d0\nOK p0\n' >"$D/answers"; run_script
rc0
MNTDIR="$(grep '^mount -t zfs -o ro hdd/backups/h/data/vm1@s1 ' "$D/log" | awk '{ print $NF }')"
case "${MNTDIR##*/}" in
    "${HS}_data~vm1@s1."??????) ;;
    *) errs+=("katalog montazu: '${MNTDIR:-brak wiersza mount w logu}' (oczekiwano ${HS}_data~vm1@s1.XXXXXX)") ;;
esac
fin

new_case "38 U88: --any -> spec drzewa ma pusty expand_to (caly host zwiniety); relacja zachowuje kandydatow (test 35)"
fs_case; run_script
python3 - "$D/tree-spec.last" <<'P' >"$D/spec.chk" 2>&1
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
print("expand=%s sel=%s" % (s.get("expand_to"), s.get("selectable")))
P
grep -q "expand=\[\] sel=\['tank/fs'\]" "$D/spec.chk" || errs+=("spec drzewa --any: $(cat "$D/spec.chk")")
fin

# U90: po czystym odmontowaniu 'Odmontowane.' i wyjscie 0 BEZ czytania z tty. run_script ma </dev/null i
# brak ctty, wiec `read </dev/tty` konczy sie bledem i NIE odroznia starego kodu od nowego. Tu skrypt
# dostaje PRAWDZIWY terminal sterujacy (pty), na ktorym nikt nie pisze: stary kod wisi na `read` do limitu.
run_pty(){   # [opcje browse.sh...] -> rc w $rc (124 = wisi na tty, 2 = brak pty), wyjscie terminala w $D/out; bez opcji: --any
    PATH="$D/bin:$PATH" WHIPTAIL="$D/bin/whiptail" BROWSE_MC="$D/bin/mc" BROWSE_ROOT="$D/run" ZFS_TREE="$D/bin/tree" \
        BROWSE_MAPPER_DIR="$D/mapper" BROWSE_ZVOL_DIR="$D/zvol" ZFS_CONF_DIR="$D/conf" BROWSE_RO_NS=0 BROWSE_RECOVER_DIR="$D/odz" \
        python3 - "$REPO/tui/browse.sh" "$D/out" "$@" <<'P'
import os, select, sys, time
try:
    import pty
except ImportError:
    sys.exit(2)
script, outp = sys.argv[1], sys.argv[2]
args = sys.argv[3:] or ["--any"]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", script] + args)
buf, rc, t0 = b"", None, time.time()
while time.time() - t0 < 20:
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        try:
            buf += os.read(fd, 65536)
        except OSError:
            pass
    p, st = os.waitpid(pid, os.WNOHANG)
    if p:
        rc = os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128
        break
if rc is None:
    os.kill(pid, 9)
    os.waitpid(pid, 0)
    rc = 124
open(outp, "wb").write(buf)
sys.exit(rc)
P
    rc=$?
}
new_case "39 U90: czyste odmontowanie na terminalu -> '=== Odmontowane.' i wyjscie 0 bez czekania na Enter, bez 'Enter = powrot'"
fs_case; run_pty
if [ "$rc" -eq 2 ]; then
    echo "SKIP 39: brak modulu pty -- wyjscie bez Entera sprawdza CI"
else
    rc0; has out "=== Odmontowane."; hasnt out "Enter = powrót"
    [ "$rc" -ne 124 ] || errs+=("browse.sh wisi na read z tty po czystym odmontowaniu (20 s)")
    fin
fi

# U89: kopia szyfrowana -- klucz tylko na czas przegladania. Atrapa zfs: encryptionroot=tank/c1,
# keystatus=unavailable, keyformat z $D/keyformat.
enc_case(){   # <keyformat> <odpowiedzi...>: dataset tank/c1 zaszyfrowany, klucz niezaladowany
    fs_case_enc_fmt="$1"; shift
    printf 'tank/c1 filesystem\n' >"$D/datasets"
    printf 'tank/c1\n' >"$D/enc_root"; printf 'unavailable\n' >"$D/keystatus"; printf '%s\n' "$fs_case_enc_fmt" >"$D/keyformat"
    : >"$D/answers"; local a; for a in "$@"; do printf '%s\n' "$a" >>"$D/answers"; done
}
new_case "40 U89: kopia szyfrowana (hex), klucz niezaladowany -> passwordbox, zfs load-key -L prompt z kluczem na STDIN przed montazem, unload-key po odmontowaniu"
enc_case hex "OK d0" "OK p0" "OK s3cret-key"
run_script
rc0; has out "=== Odmontowane."
lg '^zfs load-key -L prompt -- tank/c1$'; lg '^zfs unload-key -- tank/c1$'
[ "$(cat "$D/loadkey.stdin" 2>/dev/null)" = "s3cret-key" ] || errs+=("klucz na stdin load-key: '$(cat "$D/loadkey.stdin" 2>/dev/null)'")
grep -q 's3cret-key' "$D/log" && errs+=("klucz wyciekl do argumentow polecen (log)")
nl="$(grep -n '^zfs load-key' "$D/log" | head -1 | cut -d: -f1)"; nm="$(grep -n '^mount -t zfs' "$D/log" | head -1 | cut -d: -f1)"
nu="$(grep -n '^umount ' "$D/log" | head -1 | cut -d: -f1)"; nk="$(grep -n '^zfs unload-key' "$D/log" | head -1 | cut -d: -f1)"
{ [ -n "$nl" ] && [ -n "$nm" ] && [ -n "$nu" ] && [ -n "$nk" ] && [ "$nl" -lt "$nm" ] && [ "$nm" -lt "$nu" ] && [ "$nu" -lt "$nk" ]; } \
    || errs+=("kolejnosc load-key($nl) < mount($nm) < umount($nu) < unload-key($nk)")
fin

new_case "41 U89: kopia szyfrowana kluczem raw -> komunikat z 'zfs load-key', ani load-key, ani montazu, ani unload-key"
enc_case raw "OK d0" "OK p0"
run_script
rc0; has msgs "zfs load-key"
nolg '^zfs load-key'; nolg '^mount '; nolg '^zfs unload-key'
fin

new_case "42 U89: zly klucz -> komunikat i ponowne pytanie; po Anuluj bez montazu i bez unload-key (klucza nie zaladowano)"
enc_case hex "OK d0" "OK p0" "OK zly" "NIE"
touch "$D/loadkey_fail"
run_script
has msgs "Klucz nie pasuje"
lg '^zfs load-key -L prompt -- tank/c1$'; nolg '^mount '; nolg '^zfs unload-key'
fin

# ---- F4 Kopie, dwa panele (2026-10-28): browse.sh --any|REL --snapshot=DS@SNAP ----------------
# Migawka wybrana w prawym panelu: bez drzewa i bez menu migawek, prosto do montowania. Atrapa zfs
# odpowiada na `get -H -o value type -- DS` i `list -H -o name -t snapshot -- DS@SNAP` (s1 albo $D/snaps).
new_case "43 --snapshot=tank/fs@s1: montuje te migawke tylko do odczytu, bez drzewa i bez menu migawek"
fs_case; : >"$D/answers"; run_any --snapshot=tank/fs@s1
rc0; has out "=== Odmontowane"
[ ! -e "$D/tree-spec.last" ] || errs+=("drzewo uruchomione mimo --snapshot=")
[ ! -s "$D/menus" ] || errs+=("menu migawek mimo --snapshot=: $(cat "$D/menus")")
lg '^zfs get -H -o value type -- tank/fs$'; lg '^zfs list -H -o name -t snapshot -- tank/fs@s1$'
lg '^mount -t zfs -o ro tank/fs@s1 '; nolg '^zfs list -H -p -t snapshot'
fin

new_case "44 --snapshot=tank/vol@s1 (zvol): od razu krok partycji -- snapdev visible, mount partycji, snapdev wraca, bez drzewa i menu"
vol_case ext4; : >"$D/answers"; run_any --snapshot=tank/vol@s1
rc0; has out "=== Odmontowane"
[ ! -e "$D/tree-spec.last" ] || errs+=("drzewo uruchomione mimo --snapshot=")
[ ! -s "$D/menus" ] || errs+=("menu migawek mimo --snapshot=: $(cat "$D/menus")")
lg '^zfs set snapdev=visible tank/vol'; lg '^mount .* /dev/zd0p1 '
[ "$(cat "$D/snapdev_value")" = hidden ] || errs+=("snapdev po wszystkim: $(cat "$D/snapdev_value") (bylo hidden)")
fin

new_case "45 --snapshot= migawka, ktorej juz nie ma -> komunikat 'już nie ma', potem menu migawek TEGO datasetu"
fs_case; printf 'OK p0\n' >"$D/answers"; run_any --snapshot=tank/fs@gone
rc0; has msgs "już nie ma"; has msgs "tank/fs@gone"
[ -s "$D/menus" ] || errs+=("brak menu migawek po komunikacie")
has menus "s1"
[ ! -e "$D/tree-spec.last" ] || errs+=("drzewo uruchomione, choc dataset istnieje (powinno byc menu migawek)")
lg '^zfs list -H -o name -t snapshot -- tank/fs@gone$'
lg '^zfs list -H -p -t snapshot -o name,creation,used,written -s creation -d 1 -- tank/fs$'; lg '^mount -t zfs -o ro tank/fs@s1 '
fin

new_case "46 --snapshot= dataset, ktorego juz nie ma -> komunikat 'już nie ma', potem drzewo wyboru datasetu"
fs_case; run_any --snapshot=tank/gone@s1
rc0; has msgs "już nie ma"
[ -e "$D/tree-spec.last" ] || errs+=("drzewo nie uruchomione po komunikacie o brakujacym datasecie")
lg '^zfs get -H -o value type -- tank/gone$'; nolg '^zfs list -H -o name -t snapshot -- tank/gone@s1$'
lg '^mount -t zfs -o ro tank/fs@s1 '
fin

new_case "47 --snapshot=bad (bez @) -> rc 2, komunikat, nic nie zamontowane"
fs_case; run_any --snapshot=bad
[ "$rc" -eq 2 ] || errs+=("rc=$rc, oczekiwano 2")
has out "takes DATASET@SNAPSHOT"; nolg '^mount '; nolg '^zfs '
fin

new_case "48 --snapshot= ze znakiem spoza nazwy migawki (;) -> rc 2, nic nie zamontowane ani nie uruchomione"
fs_case; run_any '--snapshot=tank/fs@s1;touch'
[ "$rc" -eq 2 ] || errs+=("rc=$rc, oczekiwano 2")
has out "not a snapshot name"; nolg '^mount '; nolg '^zfs '
fin

# Katalog odzysku (prawy panel mc): powstaje przed mc, znika po wyjsciu, gdy pusty; z plikiem zostaje i
# wyjscie to mowi. mc dostaje /dev/tty, wiec te dwa przypadki ida pod pty (jak 39); atrapa mc zapisuje
# swoje argumenty i to, czy 2. argument byl katalogiem, a z MC_WRITE tworzy w nim plik.
mc_fake(){
    cat >"$D/bin/mc" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" "$2" >"$D/mcargs"
[ -d "$2" ] && touch "$D/mc.dirthere"
[ -n "${MC_WRITE:-}" ] && : >"$2/odzyskany.txt"
exit 0
EOF
    chmod +x "$D/bin/mc"
}
new_case "49 katalog odzysku: powstaje dla mc (2. argument = \$D/odz/fs@s1), po wyjsciu znika razem z rodzicem, gdy pusty; bez 'Skopiowane pliki'"
fs_case; : >"$D/answers"; mc_fake; run_pty --any --snapshot=tank/fs@s1
if [ "$rc" -eq 2 ]; then
    echo "SKIP 49: brak modulu pty -- katalog odzysku sprawdza CI"
else
    rc0; has out "=== Odmontowane."
    [ -e "$D/mc.dirthere" ] || errs+=("2. argument mc nie byl katalogiem w chwili uruchomienia: $(cat "$D/mcargs" 2>/dev/null)")
    [ "$(sed -n 2p "$D/mcargs" 2>/dev/null)" = "$D/odz/fs@s1" ] || errs+=("2. argument mc: '$(sed -n 2p "$D/mcargs" 2>/dev/null)' (oczekiwano $D/odz/fs@s1)")
    case "$(sed -n 1p "$D/mcargs" 2>/dev/null)" in "$D/run/"*) ;; *) errs+=("1. argument mc: '$(sed -n 1p "$D/mcargs" 2>/dev/null)' (oczekiwano katalog pod $D/run/)") ;; esac
    [ ! -e "$D/odz" ] || errs+=("katalog odzysku zostal mimo braku plikow: $(ls -A "$D/odz")")
    hasnt out "Skopiowane pliki"
    fin
fi

new_case "50 katalog odzysku: mc zapisal plik w prawym panelu -> katalog zostaje z plikiem, wyjscie mowi 'Skopiowane pliki: ...'"
fs_case; : >"$D/answers"; mc_fake; MC_WRITE=1 run_pty --any --snapshot=tank/fs@s1
if [ "$rc" -eq 2 ]; then
    echo "SKIP 50: brak modulu pty -- katalog odzysku sprawdza CI"
else
    rc0; has out "=== Odmontowane."
    [ -f "$D/odz/fs@s1/odzyskany.txt" ] || errs+=("plik z mc zniknal albo katalog usuniety: $(ls -AR "$D/odz" 2>&1 | head -3)")
    has out "Skopiowane pliki: $D/odz/fs@s1"
    fin
fi


# REV-20261028-178: kazdy klucz zaladowany przez ten proces zdjety, zanim proba sie skonczy --
# takze po nieudanym montazu, przy drugim korzeniu, sygnale i nieudanym unload-key; klucz
# zaladowany przed startem zostaje.
cnt(){ grep -cE -- "$1" "$D/log"; }
ksis(){ [ "$(cat "$D/$1")" = "$2" ] || errs+=("$1 = $(cat "$D/$1"), oczekiwano $2"); }
new_case "51 REV-178: montaz pada zaraz po load-key -> unload-key od razu (raz), przed wyjsciem; klucz zdjety"
enc_case hex "OK d0" "OK p0" "OK k1"
touch "$D/mount_fail_once"
run_script
has msgs "Nie udało się zamontować"
lg '^zfs load-key -L prompt -- tank/c1$'
[ "$(cnt '^zfs unload-key -- tank/c1$')" = 1 ] || errs+=("unload-key tank/c1: $(cnt '^zfs unload-key -- tank/c1$') razy, oczekiwano 1")
nm="$(grep -n '^mount -t zfs' "$D/log" | head -1 | cut -d: -f1)"; nk="$(grep -n '^zfs unload-key' "$D/log" | head -1 | cut -d: -f1)"
{ [ -n "$nm" ] && [ -n "$nk" ] && [ "$nm" -lt "$nk" ]; } || errs+=("kolejnosc nieudany mount($nm) < unload-key($nk)")
ksis keystatus unavailable; hasnt out "NIE wszystko"
fin

new_case "52 REV-178: po nieudanym montazu druga kopia pod INNYM korzeniem -> oba klucze zdjete (pierwszy nie ginie)"
printf 'tank/a/c1 filesystem\ntank/b/c2 filesystem\n' >"$D/datasets"
printf 'tank/a/c1 tank/a\ntank/b/c2 tank/b\n' >"$D/enc_map"
printf 'unavailable\n' >"$D/ks.tank%a"; printf 'unavailable\n' >"$D/ks.tank%b"
printf 'OK d0\nOK p0\nOK k1\nNIE\nOK d1\nOK p0\nOK k2\n' >"$D/answers"
touch "$D/mount_fail_once"
run_script
rc0; has out "=== Odmontowane."
lg '^zfs load-key -L prompt -- tank/a$'; lg '^zfs load-key -L prompt -- tank/b$'
lg '^zfs unload-key -- tank/a$'; lg '^zfs unload-key -- tank/b$'
ksis ks.tank%a unavailable; ksis ks.tank%b unavailable
fin

new_case "53 REV-178: klucz zaladowany PRZED startem -> ani load-key, ani unload-key; zostaje zaladowany"
enc_case hex "OK d0" "OK p0"
printf 'available\n' >"$D/keystatus"
run_script
rc0; has out "=== Odmontowane."
nolg '^zfs load-key'; nolg '^zfs unload-key'; ksis keystatus available
fin

new_case "54 REV-178: unload-key pada po przegladaniu -> rc!=0, korzen i polecenie reczne nazwane"
enc_case hex "OK d0" "OK p0" "OK k1"
touch "$D/unload_fail"
run_script
rcnz; has out "klucz wciąż załadowany: tank/c1"; has out "zfs unload-key tank/c1"; hasnt out "=== Odmontowane."
fin

new_case "55 REV-178: montaz pada, unload-key tez -> okno z korzeniem, ponowna proba przy wyjsciu, rc!=0"
enc_case hex "OK d0" "OK p0" "OK k1"
touch "$D/mount_fail_once" "$D/unload_fail"
run_script
rcnz; has msgs "klucz wciąż załadowany: tank/c1"; has out "klucz wciąż załadowany: tank/c1"
[ "$(cnt '^zfs unload-key -- tank/c1$')" = 2 ] || errs+=("unload-key tank/c1: $(cnt '^zfs unload-key -- tank/c1$') razy, oczekiwano 2 (od razu i przy EXIT)")
fin

new_case "56 REV-178: SIGTERM w trakcie przegladania -> EXIT odmontowuje i zdejmuje klucz, rc!=0"
enc_case hex "OK d0" "OK p0" "OK k1"
run_bg S; waitf "$D/inmc.S" && kill -TERM "$(cat "$D/mpid.S")"; touch "$D/go.S"; waitf "$D/rc.S"
[ "$(cat "$D/rc.S" 2>/dev/null)" != 0 ] || errs+=("rc po SIGTERM = 0, oczekiwano != 0")
lg '^zfs unload-key -- tank/c1$'; ksis keystatus unavailable; nomarker
fin

echo "browse: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
