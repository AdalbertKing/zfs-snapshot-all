#!/bin/bash
# test/browse/run.sh -- tui/browse.sh (przegladaj kopie), uruchamiany JAKO WYSLANY (`browse.sh --any`),
# na atrapach: zadnego prawdziwego zfs/mount/cryptsetup/urzadzen.
#
# REV-20261021-159: F1 (stan MNT/MAPPED znika dopiero, gdy zasob zniknal; umount -l nie dowodzi
# zamkniecia mappera) i F2 (snapdev zmieniany tylko po odczytaniu wartosci i zrodla; zapis orig.*
# znika wylacznie po udanym przywroceniu; dwa przegladania tego samego dysku).
# REV-20261021-160: klucz zapisu z pelnej nazwy datasetu -- tank/a_b i tank/a/b to dwa zapisy;
# dwa przeplecione przegladania przez punkt wejscia (atrapa mount wstrzymuje sesje), oba porzadki.
#
# /dev/tty: browse_and_exit uruchamia mc z </dev/tty >/dev/tty i czyta Enter z /dev/tty. Bez
# terminala sterujacego otwarcie /dev/tty konczy sie bledem, a skrypt idzie dalej (mc i read maja
# `|| true`/ignorowany rc) -- to wlasnie chcemy. Z terminalem sterujacym `read` by wisial, wiec
# skrypt idzie pod `setsid -w` (bez ctty), jesli setsid jest. Napis "=== Odmontowane" idzie na
# stdout, nie na tty, wiec jest w $D/out.
PASS=0; FAIL=0
ok(){ echo "PASS $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL $1"; shift; printf '  %s\n' "$@"; FAIL=$((FAIL+1)); }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FB="$(mktemp -d)"; D=""
trap 'rm -rf "$FB" ${D:+"$D"}' EXIT
export TERM="${TERM:-xterm}"

mkfake(){ cat >"$FB/$1"; chmod +x "$FB/$1"; }

# ---- atrapy (wszystkie czytaja $D ze srodowiska) ----------------------------------------
mkfake id <<'EOF'
#!/bin/bash
[ "${1:-}" = -u ] && { echo 0; exit 0; }
exec "$(PATH=/usr/bin:/bin command -v id)" "$@"
EOF
mkfake whiptail <<'EOF'
#!/bin/bash
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
    "list -H -p -t snapshot -o name,creation -s creation -d 1 -- "*) printf '%s@s1\t100\n' "$last" ;;
    "get -H -o value snapdev "*) [ -e "$D/fail_get" ] && exit 1; cat "$SV" ;;
    "get -H -o source snapdev "*) [ -e "$D/fail_get" ] && exit 1; cat "$SS" ;;
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
touch "$D/mounted$(printf %s "$dir" | tr / _)"
# TESTID ustawione = sesja stoi zamontowana (jak w mc; prawdziwe mc bez /dev/tty nie rusza), az test
# pozwoli jej isc dalej (go.<id>).
if [ -n "${TESTID:-}" ]; then
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
    printf 'OK d0\nOK p0\nOK q0\n' >"$D/answers"
    [ "$1" = crypto_LUKS ] && printf 'OK secret\n' >>"$D/answers"
    return 0
}
run_script(){   # -> rc w $rc, stdout+stderr w $D/out
    local runner=()
    command -v setsid >/dev/null 2>&1 && runner=(setsid -w)
    PATH="$D/bin:$PATH" WHIPTAIL="$D/bin/whiptail" BROWSE_MC="$D/bin/mc" BROWSE_ROOT="$D/run" \
        BROWSE_MAPPER_DIR="$D/mapper" BROWSE_ZVOL_DIR="$D/zvol" ZFS_CONF_DIR="$D/conf" \
        "${runner[@]}" bash "$REPO/tui/browse.sh" --any </dev/null >"$D/out" 2>&1
    rc=$?
}
key(){ printf '%s' "$1" | sha256sum | cut -c1-32; }
run_bg(){   # <id>: sesja w tle, wstrzymana po montazu; rc w $D/rc.<id>
    local runner=()
    command -v setsid >/dev/null 2>&1 && runner=(setsid -w)
    ( PATH="$D/bin:$PATH" WHIPTAIL="$D/bin/whiptail" BROWSE_MC="$D/bin/mc" BROWSE_ROOT="$D/run" \
        BROWSE_MAPPER_DIR="$D/mapper" BROWSE_ZVOL_DIR="$D/zvol" ZFS_CONF_DIR="$D/conf" TESTID="$1" \
        "${runner[@]}" bash "$REPO/tui/browse.sh" --any </dev/null >"$D/out.$1" 2>&1
      echo $? >"$D/rc.$1" ) &
}
waitf(){ local n; for ((n = 0; n < 300; n++)); do [ -e "$1" ] && return 0; sleep 0.1; done; errs+=("nie doczekalem sie $1"); return 1; }
start_ds(){   # <id> <dataset> <value> <source>: sesja na datasecie, czeka zamontowana
    local k="${2//\//%}"
    printf '%s volume\n' "$2" >"$D/datasets"
    printf '%s\n' "$3" >"$D/sdv.$k"; printf '%s\n' "$4" >"$D/sds.$k"
    printf 'OK d0\nOK p0\nOK q0\n' >"$D/answers"
    run_bg "$1"; waitf "$D/inmc.$1"
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

echo "browse: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
