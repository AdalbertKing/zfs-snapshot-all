#!/bin/bash
# browse.sh RELACJA | browse.sh --any -- "Przeglądaj kopię" (chudy odzysk), w whiptailu.
#
# Właściciel 2026-10-18: migawka kopii zamontowana TYLKO DO ODCZYTU, `mc` do skopiowania
# plików, po wyjściu z mc odmontowanie. Nic w kopii się nie zmienia: montaż `-o ro` migawki
# (migawka i tak jest tylko do odczytu), w katalogu tymczasowym pod /run, sprzątanym zawsze
# (trap).
#
# DYSK VM (zvol), wersja light (właściciel 2026-10-18): migawka dysku wystawiona jako
# urządzenie (snapdev=visible na czas przeglądania -- urządzenie migawki jest tylko do
# odczytu), wybór partycji, montaż ro wg systemu plików (NTFS, ext2/3/4, xfs, vfat, exfat,
# btrfs); BitLocker i LUKS po podaniu klucza (cryptsetup open --readonly). Po wyjściu:
# odmontowanie, zamknięcie odblokowanego urządzenia, snapdev z powrotem jak było.
#
# Kroki: 1 który dataset, 2 która migawka, 3 (dysk VM) która partycja (+ klucz),
# 4 montaż + mc, odmontowanie.
#
# Środowisko (testy): ZFS_BACKUP, WHIPTAIL, ZFS_CONF_DIR, PYTHON, BROWSE_MC (domyślnie mc),
# BROWSE_ROOT (domyślnie /run/zfs-browse), BROWSE_MAPPER_DIR, BROWSE_ZVOL_DIR.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "browse: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
REL="${1:-}"
[ -n "$REL" ] || { echo "usage: browse.sh RELATION [--dataset=DS] [--at=EPOCH] | browse.sh --any" >&2; exit 2; }
# Wejscie z miejsca, w ktorym operator stoi (F4 Kopie z Przebiegow albo z datasetu,
# 2026-10-27): --dataset= = kopia, od ktorej zaczac (drzewo pominiete, gdy jest na
# liscie), --at= = chwila -- kursor na najnowszej migawce nie pozniejszej od niej.
# --snapshot=DS@SNAP (F4 Kopie na dwoch panelach, 2026-10-28): migawka wybrana w prawym
# panelu -- drzewo i menu migawek pominiete, od razu montowanie.
PRE_DS=""; PRE_AT=""; PRE_SNAP=""
for _a in "${@:2}"; do
    case "$_a" in
        --dataset=*) PRE_DS="${_a#*=}" ;;
        --at=*)      PRE_AT="${_a#*=}" ;;
        --snapshot=*) PRE_SNAP="${_a#*=}"
                     case "$PRE_SNAP" in *@*) ;; *) echo "browse.sh: --snapshot= takes DATASET@SNAPSHOT" >&2; exit 2 ;; esac
                     case "$PRE_SNAP" in *[!A-Za-z0-9_.:/@-]*) echo "browse.sh: not a snapshot name: '$PRE_SNAP'" >&2; exit 2 ;; esac ;;
        *) echo "browse.sh: unknown option '$_a'" >&2; exit 2 ;;
    esac
done
case "$PRE_AT" in *[!0-9]*) PRE_AT="" ;; esac
CONFDIR="${ZFS_CONF_DIR:-/etc/zfs-snapshot-all}"
MC="${BROWSE_MC:-mc}"
BROOT="${BROWSE_ROOT:-/run/zfs-browse}"
MAPDIR="${BROWSE_MAPPER_DIR:-/dev/mapper}"   # testy: katalog zamiast /dev/mapper
ZVDIR="${BROWSE_ZVOL_DIR:-/dev/zvol}"        # testy: katalog zamiast /dev/zvol
TMPD="$(mktemp -d)" || exit 1
MNT=""; MAPPED=""; SNAPDEV_DS=""; LAZY=0
RESIDUE=""   # co zostało po nieudanym sprzątaniu -- z poleceniem do ręcznego dokończenia

# REV-20261021-159 F1: stan (MNT, MAPPED) znika DOPIERO, gdy zasób naprawdę zniknął --
# inaczej wyjście (trap EXIT) nie ma czego ponowić, a ekran mówi "odmontowane" przy
# zamontowanej kopii albo otwartym, odszyfrowanym urządzeniu. Kolejność: mapper zamykany
# dopiero, gdy system plików na nim nie jest już zamontowany; odłączenie leniwe (umount -l)
# NIE dowodzi, że nikt go nie używa -- wtedy mapper zostaje otwarty i jest to zgłaszane.
is_mounted() {   # <katalog>
    # `return $?`, nie samo `return`: w pułapce EXIT gołe `return` oddaje status sprzed
    # pułapki (dokumentacja basha), więc sprzątanie przy wyjściu brało kopię za odmontowaną.
    if command -v mountpoint >/dev/null 2>&1; then mountpoint -q "$1" 2>/dev/null; return $?; fi
    awk -v m="$1" '$2 == m { f = 1 } END { exit !f }' /proc/self/mounts 2>/dev/null
}
unmount_all() {   # -> 0 nic nie zostało; 1 coś zostało (opis w RESIDUE, stan zachowany)
    local left=0
    if [ -n "$MNT" ]; then
        if is_mounted "$MNT"; then
            umount "$MNT" 2>/dev/null || { umount -l "$MNT" 2>/dev/null && LAZY=1; }
        fi
        if is_mounted "$MNT"; then
            RESIDUE="$RESIDUE
  $(Tv 'kopia wciąż zamontowana: $MNT  (ręcznie: umount $MNT)' '$MNT' "$MNT")"
            left=1
        elif rmdir "$MNT" 2>/dev/null || ! [ -d "$MNT" ]; then
            MNT=""
            if [ "$LAZY" -eq 1 ] && [ -z "$MAPPED" ]; then
                # Odłączenie leniwe: coś jeszcze używało kopii -- zwolni się, gdy ostatni proces skończy.
                RESIDUE="$RESIDUE
  $(T 'kopia była zajęta i została odłączona leniwie (umount -l) -- zwolni się, gdy ostatni proces przestanie jej używać (sprawdź: lsof +D albo fuser -vm)')"
                left=1
            fi
        else
            RESIDUE="$RESIDUE
  $(Tv 'pusty katalog po montażu nie dał się usunąć: $MNT  (ręcznie: rmdir $MNT)' '$MNT' "$MNT")"
            left=1
        fi
    fi
    if [ -n "$MAPPED" ]; then
        if [ "$left" -eq 1 ]; then
            RESIDUE="$RESIDUE
  $(Tv 'odblokowane urządzenie /dev/mapper/$MAPPED zostaje otwarte -- najpierw odmontowanie (potem: cryptsetup close $MAPPED)' '$MAPPED' "$MAPPED")"
        elif [ "$LAZY" -eq 1 ]; then
            RESIDUE="$RESIDUE
  $(Tv 'system plików był zajęty (odłączony leniwie, umount -l) -- /dev/mapper/$MAPPED zostaje otwarte; gdy nic go nie używa: cryptsetup close $MAPPED' '$MAPPED' "$MAPPED")"
            left=1
        elif cryptsetup close "$MAPPED" 2>/dev/null || ! [ -e "$MAPDIR/$MAPPED" ]; then
            MAPPED=""
        else
            RESIDUE="$RESIDUE
  $(Tv 'nie udało się zamknąć /dev/mapper/$MAPPED (odszyfrowane dane dostępne!)  (ręcznie: cryptsetup close $MAPPED)' '$MAPPED' "$MAPPED")"
            left=1
        fi
    fi
    return "$left"
}
# DWA PRZEGLĄDANIA TEGO SAMEGO DYSKU (pve10, 2026-10-18: pierwsze, które skończyło, przywróciło
# snapdev i drugiemu zniknęło /dev/zd..p1 w trakcie podawania klucza). Każde przeglądanie zostawia
# znacznik hold2.<pid>.<klucz>; snapdev wraca dopiero, gdy nie ma innego ŻYWEGO znacznika tego
# datasetu, a wartość sprzed przeglądania zapisuje tylko pierwszy (orig2.<klucz>).
# REV-20261021-160: klucz to skrót sha256 PEŁNEJ nazwy datasetu (dawne tr '/@' '__' sklejało
# tank/a_b z tank/a/b), a zapis orig2 niesie dokładną nazwę -- cudzy zapis (kolizja skrótu)
# jest odrzucany, nigdy używany ani usuwany. Sam klucz nie ma kropek: hold2.*.<klucz> nie złapie
# znacznika innego datasetu.
hold_key() { local h; h="$(printf '%s' "$1" | sha256sum)" || return 1; printf '%s' "${h:0:32}"; }
legacy_key() { printf '%s' "$1" | tr '/@' '__'; }   # klucz sprzed REV-160 -- tylko do wykrycia starych zapisów
other_holders() {   # <dataset> -> 0 gdy inne żywe przeglądanie trzyma ten dataset
    local k f p; k="$(hold_key "$1")"
    for f in "$BROOT"/hold2.*."$k"; do
        [ -e "$f" ] || continue
        p="${f#"$BROOT"/hold2.}"; p="${p%%.*}"
        [ "$p" = "$$" ] && continue
        kill -0 "$p" 2>/dev/null && return 0
        rm -f "$f"
    done
    return 1
}
# REV-20261021-159 F2: snapdev zmieniany TYLKO, gdy wartość i źródło sprzed zmiany dało się
# odczytać i są poprawne. Zapis oryginału (orig2.<klucz>: dataset, wartość, źródło) powstaje raz -- gdy go nie ma --
# i znika WYŁĄCZNIE po udanym przywróceniu: nieudane przywrócenie zostawia go (z poleceniem
# w RESIDUE), a następne przeglądanie nie nadpisze go bieżącym "visible".
# REV-20261021-161: wejście (sprawdzenie/założenie orig2, znacznik, snapdev=visible) i wyjście
# (zdjęcie znacznika, czy ktoś jeszcze trzyma, przywrócenie, usunięcie orig2) jednego datasetu
# idą pod jedną blokadą flock na lock2.<klucz> -- inaczej kończący mógł usunąć zapis, który
# wchodzący już sprawdził, a jeszcze nie założył znacznika. Bez blokady: nic nie zmieniam.
# Plik blokady zostaje (usuwanie pliku blokady samo jest wyścigiem).
# REV-20261021-162: blokada jest WIELOKROTNEGO WEJŚCIA w tym samym procesie. SIGTERM w trakcie
# przejścia pod blokadą kończy skrypt (exit 130), a pułapka EXIT woła restore_snapdev jeszcze
# raz -- druga, niezależna próba flock czekałaby na blokadę trzymaną przez nas samych i po
# BROWSE_LOCK_WAIT zostawiała dysk "visible". Ten sam proces, ten sam klucz = już ją mamy.
SNAPLOCK_FD=""; SNAPLOCK_KEY=""; SNAPLOCK_DEPTH=0
snap_lock() {   # <klucz> -> 0 z blokadą na SNAPLOCK_FD; 1 gdy się nie da
    if [ -n "$SNAPLOCK_FD" ]; then
        [ "$SNAPLOCK_KEY" = "$1" ] || return 1     # inna blokada w tym procesie -- nie powinno się zdarzyć
        SNAPLOCK_DEPTH=$((SNAPLOCK_DEPTH + 1)); return 0
    fi
    command -v flock >/dev/null 2>&1 || return 1
    { exec {SNAPLOCK_FD}>>"$BROOT/lock2.$1"; } 2>/dev/null || { SNAPLOCK_FD=""; return 1; }
    if flock -w "${BROWSE_LOCK_WAIT:-30}" "$SNAPLOCK_FD"; then SNAPLOCK_KEY="$1"; SNAPLOCK_DEPTH=1; return 0; fi
    exec {SNAPLOCK_FD}>&-; SNAPLOCK_FD=""; return 1
}
snap_unlock() {
    [ -n "$SNAPLOCK_FD" ] || return 0
    SNAPLOCK_DEPTH=$((SNAPLOCK_DEPTH - 1))
    [ "$SNAPLOCK_DEPTH" -gt 0 ] && return 0
    exec {SNAPLOCK_FD}>&-; SNAPLOCK_FD=""; SNAPLOCK_KEY=""; SNAPLOCK_DEPTH=0
}
# Tylko testy: BROWSE_TEST_PAUSE_AT=<punkt> i BROWSE_TEST_PAUSE=<prefiks> zatrzymują sesję
# w punkcie (pod blokadą), aż pojawi się <prefiks>.go. Bez tych zmiennych -- nic.
# Pauza jest jednorazowa (.done), a w .at zapisuje PID -- test może w niej wysłać sygnał, a
# ponowne wejście z pułapki EXIT już się nie zatrzyma.
test_pause() {
    [ -n "${BROWSE_TEST_PAUSE:-}" ] && [ "${BROWSE_TEST_PAUSE_AT:-}" = "$1" ] || return 0
    [ -e "$BROWSE_TEST_PAUSE.done" ] && return 0
    local n; : >"$BROWSE_TEST_PAUSE.done"; printf '%s\n' "$$" >"$BROWSE_TEST_PAUSE.at"
    for ((n = 0; n < 600; n++)); do [ -e "$BROWSE_TEST_PAUSE.go" ] && return 0; command -p sleep 0.05; done
}
expose_snapdev() {  # <dataset> -> 0 gdy snapdev=visible i znacznik założony
    local k rc
    k="$(hold_key "$1")" && [ "${#k}" -eq 32 ] || { echo "$(Tv 'nie da się policzyć klucza dla $1 (sha256sum) -- nic nie zmieniam' '$1' "$1")" >&2; return 1; }
    mkdir -p "$BROOT" || return 1
    snap_lock "$k" || { echo "$(Tv 'nie mogę zablokować $BROOT/lock2.$k (brak flock albo inne przeglądanie tego dysku trzyma blokadę za długo) -- nic nie zmieniam' '$BROOT' "$BROOT" '$k' "$k")" >&2; return 1; }
    expose_snapdev_locked "$1"; rc=$?
    snap_unlock; return "$rc"
}
expose_snapdev_locked() {
    local ds="$1" k v s d f p
    k="$(hold_key "$ds")" && [ "${#k}" -eq 32 ] || { echo "$(Tv 'nie da się policzyć klucza dla $ds (sha256sum) -- nic nie zmieniam' '$ds' "$ds")" >&2; return 1; }
    mkdir -p "$BROOT" || return 1
    # Zapisy sprzed REV-160 (orig./hold. ze sklejonym kluczem): nie wiadomo, którego z datasetów
    # o tej samej sklejonej nazwie dotyczą -- nic nie zgaduję i niczego nie usuwam.
    f="$BROOT/orig.$(legacy_key "$ds")"
    if [ -e "$f" ]; then
        echo "$(Tv 'stary zapis $f (sprzed poprawki kluczy) -- nie wiadomo, którego datasetu dotyczy; nic nie zmieniam. Sprawdź snapdev datasetów o tej nazwie (zfs get -r snapdev), przywróć ręcznie i usuń ten plik.' '$f' "$f")" >&2
        return 1
    fi
    for f in "$BROOT"/hold.*."$(legacy_key "$ds")"; do
        [ -e "$f" ] || continue
        p="${f#"$BROOT"/hold.}"; p="${p%%.*}"
        if kill -0 "$p" 2>/dev/null; then
            echo "$(Tv 'trwa przeglądanie starszą wersją (pid $p, $f) -- nic nie zmieniam, spróbuj po jego zakończeniu' '$p' "$p" '$f' "$f")" >&2
            return 1
        fi
    done
    if [ -e "$BROOT/orig2.$k" ]; then
        # Istniejący zapis (inne przeglądanie albo nieudane przywrócenie) -- tylko poprawny i tylko TEGO datasetu.
        IFS=$'\t' read -r d v s <"$BROOT/orig2.$k" 2>/dev/null || { echo "$(Tv 'zapis $BROOT/orig2.$k nieczytelny -- nic nie zmieniam' '$BROOT' "$BROOT" '$k' "$k")" >&2; return 1; }
        [ "$d" = "$ds" ] || { echo "$(Tv 'zapis $BROOT/orig2.$k należy do '\''$d'\'', nie do $ds -- nic nie zmieniam (sprawdź ręcznie)' '$BROOT' "$BROOT" '$k' "$k" '$ds' "$ds" '$d' "$d")" >&2; return 1; }
        case "$v" in hidden|visible) ;; *) echo "$(Tv 'zapis $BROOT/orig2.$k: wartość '\''$v'\'' -- nic nie zmieniam (sprawdź ręcznie)' '$BROOT' "$BROOT" '$k' "$k" '$v' "$v")" >&2; return 1 ;; esac
        case "$s" in local|default|received|"inherited from "*) ;; *) echo "$(Tv 'zapis $BROOT/orig2.$k: źródło '\''$s'\'' -- nic nie zmieniam (sprawdź ręcznie)' '$BROOT' "$BROOT" '$k' "$k" '$s' "$s")" >&2; return 1 ;; esac
    else
        v="$(zfs get -H -o value snapdev "$ds" 2>/dev/null)" || { echo "$(Tv 'nie da się odczytać snapdev $ds -- nic nie zmieniam' '$ds' "$ds")" >&2; return 1; }
        s="$(zfs get -H -o source snapdev "$ds" 2>/dev/null)" || { echo "$(Tv 'nie da się odczytać źródła snapdev $ds -- nic nie zmieniam' '$ds' "$ds")" >&2; return 1; }
        case "$v" in hidden|visible) ;; *) echo "$(Tv 'snapdev $ds = '\''$v'\'' -- nieznana wartość, nic nie zmieniam' '$ds' "$ds" '$v' "$v")" >&2; return 1 ;; esac
        case "$s" in local|default|received|"inherited from "*) ;; *) echo "$(Tv 'źródło snapdev $ds = '\''$s'\'' -- nieznane, nic nie zmieniam' '$ds' "$ds" '$s' "$s")" >&2; return 1 ;; esac
        printf '%s\t%s\t%s\n' "$ds" "$v" "$s" >"$BROOT/orig2.$k.$$" && mv -f "$BROOT/orig2.$k.$$" "$BROOT/orig2.$k" \
            || { rm -f "$BROOT/orig2.$k.$$"; echo "$(Tv 'nie da się zapisać $BROOT/orig2.$k -- nic nie zmieniam' '$BROOT' "$BROOT" '$k' "$k")" >&2; return 1; }
    fi
    test_pause expose
    : >"$BROOT/hold2.$$.$k" || { echo "$(Tv 'nie da się założyć znacznika $BROOT/hold2.$$.$k -- nic nie zmieniam' '$BROOT' "$BROOT" '$$' "$$" '$k' "$k")" >&2; return 1; }
    SNAPDEV_DS="$ds"
    zfs set snapdev=visible "$ds"
}
restore_snapdev() {   # -> 0 przywrócone albo nie było czego; 1 nie (opis w RESIDUE, stan zachowany)
    [ -n "$SNAPDEV_DS" ] || return 0
    local k rc; k="$(hold_key "$SNAPDEV_DS")"
    if ! snap_lock "$k"; then
        RESIDUE="$RESIDUE
  $(Tv 'nie mogę zablokować $BROOT/lock2.$k -- snapdev $SNAPDEV_DS zostawiam, znacznik i zapis zostają (sprawdź: zfs get snapdev $SNAPDEV_DS)' '$BROOT' "$BROOT" '$k' "$k" '$SNAPDEV_DS' "$SNAPDEV_DS")"
        return 1
    fi
    restore_snapdev_locked; rc=$?
    snap_unlock; return "$rc"
}
restore_snapdev_locked() {
    local k d was src ok=1; k="$(hold_key "$SNAPDEV_DS")"
    rm -f "$BROOT/hold2.$$.$k"
    if other_holders "$SNAPDEV_DS"; then SNAPDEV_DS=""; return 0; fi   # inne przeglądanie trzyma
    if ! IFS=$'\t' read -r d was src <"$BROOT/orig2.$k" 2>/dev/null; then
        RESIDUE="$RESIDUE
  $(Tv 'nie ma zapisu snapdev sprzed przeglądania ($BROOT/orig2.$k) -- snapdev $SNAPDEV_DS zostawiam (sprawdź: zfs get snapdev $SNAPDEV_DS)' '$BROOT' "$BROOT" '$k' "$k" '$SNAPDEV_DS' "$SNAPDEV_DS")"
        return 1
    fi
    if [ "$d" != "$SNAPDEV_DS" ]; then
        RESIDUE="$RESIDUE
  $(Tv 'zapis $BROOT/orig2.$k należy do '\''$d'\'', nie do $SNAPDEV_DS -- snapdev $SNAPDEV_DS zostawiam, zapisu nie ruszam (sprawdź: zfs get snapdev $SNAPDEV_DS)' '$BROOT' "$BROOT" '$k' "$k" '$SNAPDEV_DS' "$SNAPDEV_DS" '$d' "$d")"
        return 1
    fi
    test_pause restore
    case "$src" in
        local)                     zfs set snapdev="$was" "$SNAPDEV_DS" 2>/dev/null || ok=0 ;;
        default|"inherited from "*) zfs inherit snapdev "$SNAPDEV_DS" 2>/dev/null || ok=0 ;;
        received)                  zfs inherit -S snapdev "$SNAPDEV_DS" 2>/dev/null || ok=0 ;;
        *)                         ok=0 ;;
    esac
    if [ "$ok" -eq 1 ]; then
        rm -f "$BROOT/orig2.$k"; SNAPDEV_DS=""; return 0
    fi
    RESIDUE="$RESIDUE
  $(Tv 'snapdev na $SNAPDEV_DS NIE przywrócony (było: $was, $src; zapis w $BROOT/orig2.$k)  (ręcznie: $HOWTO)' '$SNAPDEV_DS' "$SNAPDEV_DS" '$was' "$was" '$src' "$src" '$BROOT' "$BROOT" '$k' "$k" '$HOWTO' "$(case "$src" in local) echo "zfs set snapdev=$was $SNAPDEV_DS" ;; *) echo "zfs inherit snapdev $SNAPDEV_DS" ;; esac)")"
    return 1
}
# Po kroku, który zmienił snapdev, a się nie udał: przywrócenie i -- gdy nie wyszło -- okno
# z tym, co zostało (zamiast "nic nie zostało zmienione").
undo_or_warn() {   # <tekst przy sukcesie> -> zawsze 0
    RESIDUE=""
    unmount_all; restore_snapdev   # obie próby, także gdy pierwsza zawiodła
    if [ -z "$RESIDUE" ]; then
        [ -n "$1" ] && wt --title "$TITLE" --msgbox "$1" 9 "$W"
    else
        wt --title "$TITLE" --msgbox "$(Tv 'Nie wszystko udało się posprzątać:$RESIDUE' '$RESIDUE' "$RESIDUE")" 14 "$W"
    fi
    return 0
}
# U89 (wlasciciel 2026-10-27, pve10: kopia szyfrowana "can not be mounted: Permission
# denied"): klucz zaladowany TYLKO na czas przegladania -- po odmontowaniu zdjety.
# REV-20261028-178: KEYLOADED to LISTA (wiersz na korzen) wszystkich kluczy zaladowanych przez
# ten proces -- jedna zmienna na jeden korzen gubila pierwszy, gdy po nieudanym montazu wybrano
# kopie pod innym korzeniem. Klucz zaladowany przed startem nie trafia na liste (need_key laduje
# tylko "unavailable"), wiec nigdy nie jest zdejmowany.
KEYLOADED=""
unload_key() {   # -> 0 zdjete wszystkie albo nie bylo czego; 1 nie (kazdy pozostaly w RESIDUE)
    local r left="" rc=0
    [ -n "$KEYLOADED" ] || return 0
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        if ! zfs unload-key -- "$r" 2>"$TMPD/unload.err"; then
            left="$left$r"$'\n'; rc=1
            RESIDUE="$RESIDUE
  $(Tv 'klucz wciąż załadowany: $KEY  (ręcznie: zfs unload-key $KEY)' '$KEY' "$r")"
        fi
    done <<< "$KEYLOADED"
    KEYLOADED="$left"
    return "$rc"
}
# Kopia szyfrowana bez zaladowanego klucza: zapytaj o klucz (nigdzie nie zapisywany),
# zfs load-key na korzeniu szyfrowania. -> 0 mozna montowac; 1 nie (komunikat pokazany)
need_key() {   # <dataset>
    local ds="$1" root ks kf
    root="$(zfs get -H -o value encryptionroot -- "$ds" 2>/dev/null | tr -d '\r')"
    case "$root" in ''|-) return 0 ;; esac
    ks="$(zfs get -H -o value keystatus -- "$root" 2>/dev/null | tr -d '\r')"
    [ "$ks" = unavailable ] || return 0
    kf="$(zfs get -H -o value keyformat -- "$root" 2>/dev/null | tr -d '\r')"
    if [ "$kf" = raw ]; then
        wt --title "$TITLE" --msgbox "$(Tv 'Kopia $DS jest zaszyfrowana kluczem binarnym ($ROOT). Tego klucza nie da się wpisać -- załaduj go ręcznie: zfs load-key -L file:///ścieżka $ROOT' '$DS' "$ds" '$ROOT' "$root")" 10 "$W"
        return 1
    fi
    while :; do
        wt --title "$(Tv '$TITLE: klucz' '$TITLE' "$TITLE")" --passwordbox "$(Tv 'Kopia $DS jest zaszyfrowana ($ROOT, klucz: $KF).\nPodaj klucz. Nie jest nigdzie zapisywany; po wyjściu zostanie zdjęty.' '$DS' "$ds" '$ROOT' "$root" '$KF' "$kf")" 12 "$W" || return 1
        if printf '%s' "$WT_OUT" | zfs load-key -L prompt -- "$root" 2>"$TMPD/key.err"; then
            WT_OUT=""; KEYLOADED="$KEYLOADED$root"$'\n'; return 0
        fi
        WT_OUT=""
        wt --title "$TITLE" --msgbox "$(Tv 'Klucz nie pasuje:\n$ERR\nSpróbuj jeszcze raz albo Anuluj.' '$ERR' "$(head -2 "$TMPD/key.err")")" 11 "$W"
    done
}

cleanup() {
    RESIDUE=""
    unmount_all; restore_snapdev; unload_key
    rm -rf "$TMPD"
    if [ -n "$RESIDUE" ]; then
        T 'Przeglądaj kopię -- NIE wszystko posprzątane:%s\n' "$RESIDUE" >&2
        exit 1     # w pułapce EXIT: kod wyjścia całego skryptu -- nigdy 0 przy pozostałości
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ "$REL" = --any ]; then
    WT_BACKTITLE="$(Tv 'Przeglądaj kopię na dysku -- $(hostname)' '$(hostname)' "$(hostname)")"
    # U87 (wlasciciel 2026-10-27): w naglowku okna -- po jakim hoscie chodzimy.
    TITLE="$(Tv 'Przeglądaj kopię na $(hostname)' '$(hostname)' "$(hostname)")"
else
    WT_BACKTITLE="$(Tv 'Przeglądaj kopię relacji $REL -- $(hostname)' '$REL' "$REL" '$(hostname)' "$(hostname)")"
    TITLE="$(Tv 'Przeglądaj $REL na $(hostname)' '$REL' "$REL" '$(hostname)' "$(hostname)")"
fi
geom

if [ "$(id -u)" -ne 0 ]; then
    wt --title "$TITLE" --msgbox "$(T 'Montowanie migawki wymaga roota. Uruchom GUI jako root (zfs-backup gui).')" 8 "$W"
    exit 1
fi

# ---- KROK 1: które datasety -> cand.tsv (nazwa <TAB> typ) ------------------------------
: >"$TMPD/roots"
if [ "$REL" = --any ]; then
    zfs list -H -o name -t filesystem,volume 2>/dev/null | tr -d '\r' >"$TMPD/roots"
else
    for C in "$CONFDIR"/jobs.*.conf; do
        [ -f "$C" ] || continue
        "$ZB" restore --plan "$REL" --config="$C" --json >"$TMPD/plan.json" 2>/dev/null || continue
        "$PY" - "$TMPD/plan.json" <<'PYEOF' 2>/dev/null | tr -d '\r' >>"$TMPD/roots"
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
for r in d.get("datasets") or []:
    if r.get("copy_exists") is True and r.get("copy"):
        print(r["copy"])
PYEOF
        [ -s "$TMPD/roots" ] && break
    done
fi
if ! [ -s "$TMPD/roots" ]; then
    if [ "$REL" = --any ]; then _m="$(T 'Na tym hoście nie ma kopii do przeglądania.')"
    else _m="$(Tv 'Na tym hoście nie ma kopii do przeglądania relacji $REL.' '$REL' "$REL")"; fi
    wt --title "$TITLE" --msgbox "$_m" 8 "$W"
    exit 1
fi
# każdy korzeń z dziećmi; tylko te, które mają choć jedną migawkę
sort -u "$TMPD/roots" | while IFS= read -r r; do
    [ -n "$r" ] || continue
    zfs list -H -o name,type -r -- "$r" 2>/dev/null | tr -d '\r'
done | sort -u | while IFS=$'\t' read -r n t; do
    [ -n "$n" ] || continue
    zfs list -H -t snapshot -o name -d 1 -- "$n" 2>/dev/null | grep -q . && printf '%s\t%s\n' "$n" "$t"
done >"$TMPD/cand.tsv"
if ! [ -s "$TMPD/cand.tsv" ]; then
    wt --title "$TITLE" --msgbox "$(T 'Kopie nie mają żadnej migawki -- nie ma czego przeglądać.')" 8 "$W"
    exit 1
fi

# ---- montaż ro wg systemu plików: <urządzenie> <typ> -> 0, MNT ustawiony ---------------
mount_ro() {
    local dev="$1" fs="$2" opts="ro"
    # U87: nazwa katalogu montazu mowi host, dataset i migawke -- to widac w naglowku mc.
    # U102: z datasetu tylko dwa ostatnie czlony (hdd/backups/h/hdd/data/vm1 -> data~vm1):
    # pelna sciezka kopii zjadala naglowek mc, a migawka -- jedyne, co odroznia dwa
    # montaze tego samego datasetu -- wypadala za krawedz. Pelna nazwa jest w oknie przed montazem.
    local tag ds2="${DS:-x}"
    case "$ds2" in */*/*) ds2="${ds2%/*}"; ds2="${ds2##*/}/${DS##*/}" ;; esac
    tag="$(hostname -s 2>/dev/null || hostname)_$(printf '%s' "${ds2}@${SNAP:-x}" | tr '/ ' '~_')"
    mkdir -p "$BROOT" && MNT="$(mktemp -d "$BROOT/${tag:0:150}.XXXXXX")" || { MNT=""; echo "$(Tv 'nie mogę utworzyć katalogu w $BROOT' '$BROOT' "$BROOT")" >"$TMPD/mount.err"; return 1; }
    case "$fs" in
        ntfs)
            if modinfo ntfs3 >/dev/null 2>&1 || grep -qw ntfs3 /proc/filesystems; then
                mount -t ntfs3 -o ro "$dev" "$MNT" 2>"$TMPD/mount.err" && return 0
            fi
            if command -v ntfs-3g >/dev/null 2>&1; then
                ntfs-3g -o ro "$dev" "$MNT" 2>"$TMPD/mount.err" && return 0
            fi
            echo "$(T 'brak sterownika NTFS (moduł ntfs3 albo pakiet ntfs-3g)')" >>"$TMPD/mount.err" ;;
        ext2|ext3|ext4) mount -t "$fs" -o ro,noload "$dev" "$MNT" 2>"$TMPD/mount.err" && return 0 ;;
        xfs)            mount -t xfs -o ro,norecovery,nouuid "$dev" "$MNT" 2>"$TMPD/mount.err" && return 0 ;;
        zfs)            mount -t zfs -o ro "$dev" "$MNT" 2>"$TMPD/mount.err" && return 0 ;;
        *)              mount -o "$opts" "$dev" "$MNT" 2>"$TMPD/mount.err" && return 0 ;;
    esac
    rmdir "$MNT" 2>/dev/null; MNT=""
    return 1
}

# ---- mc TYLKO DO ODCZYTU (U103, wlasciciel 2026-10-28) ---------------------------------
# mc dziala jako root, wiec dotad prawy panel mogl skasowac dowolny plik hosta, a lewy
# wyjsc z kopii na zywy system. mc biegnie we wlasnej przestrzeni montowan (unshare -m).
# U126 (wlasciciel 2026-10-29, zrzut: "mc pozwolil wyjsc na obu panelach az do root
# maszyny"): w tej przestrzeni mc dostaje WLASNY maly korzen (pivot_root). Pod "/" widac
# tylko /kopia (ta migawka, tylko do odczytu), /odzysk (jedyne miejsce zapisu) i to, bez
# czego mc nie wystartuje: usr, lib*, bin, sbin, etc -- dowiazane BEZ podmontowan (/etc/pve
# jest tam pustym katalogiem) i tylko do odczytu; /dev z kilkoma wezlami terminala, /proc
# tylko do odczytu, /tmp pusty. Pule, /root, /home, inne kopie -- niewidoczne. Root w takim
# korzeniu wyszedlby z niego przez mknod+mount, wiec mc dostaje tylko uprawnienia do
# czytania i kopiowania plikow (setpriv: dac_override, dac_read_search, chown, fowner,
# fsetid; bez sys_admin i mknod). Gdy ktorykolwiek krok sie nie uda, mc NIE startuje (bez
# cichego powrotu do zapisywalnego hosta).
mc_readonly() {   # <katalog kopii>
    local mnt="$1" leaf odz rc=0
    leaf="$(printf '%s' "${DS##*/}@${SNAP:-x}" | tr -c 'A-Za-z0-9._@-' '_')"
    odz="${BROWSE_RECOVER_DIR:-${HOME:-/root}/odzysk}/${leaf:0:120}"
    mkdir -p "$odz" "$TMPD/mcxdg" || { echo "$(Tv 'nie mogę utworzyć $DIR' '$DIR' "$odz")"; return 1; }
    echo "$(Tv '  w mc: /kopia = ta migawka (tylko do odczytu), /odzysk = $ODZ (jedyne miejsce zapisu).' '$ODZ' "$odz")"
    if [ "${BROWSE_RO_NS:-1}" = 1 ]; then
        unshare -m --propagation private -- bash -c '
            mnt="$1"; odz="$2"; xdg="$3"; mc="$4"
            set -o pipefail
            mcbin="$(command -v "$mc")" || exit 97
            command -v setpriv >/dev/null 2>&1 || exit 97
            nr="$xdg/root"
            mkdir -p "$nr" || exit 97
            mount -t tmpfs -o size=16m,mode=0755 tmpfs "$nr" || exit 97
            # system dla mc: dowiazania BEZ podmontowan, tylko do odczytu; dowiazania
            # symboliczne (usrmerge: /bin -> usr/bin) przepisane jak sa
            for d in usr lib lib32 lib64 libx32 bin sbin etc; do
                if [ -L "/$d" ]; then ln -s "$(readlink "/$d")" "$nr/$d" || exit 97
                elif [ -d "/$d" ]; then
                    mkdir "$nr/$d" && mount --bind "/$d" "$nr/$d" && mount -o remount,bind,ro "$nr/$d" || exit 97
                fi
            done
            mkdir -p "$nr/dev/pts" "$nr/proc" "$nr/tmp" "$nr/kopia" "$nr/odzysk" "$nr/.old" || exit 97
            mount -t tmpfs -o size=1m,mode=0755 tmpfs "$nr/dev" || exit 97
            mkdir -p "$nr/dev/pts" || exit 97
            for n in null zero tty random urandom full; do
                [ -e "/dev/$n" ] || continue
                touch "$nr/dev/$n" && mount --bind "/dev/$n" "$nr/dev/$n" || exit 97
            done
            mount --bind /dev/pts "$nr/dev/pts" || exit 97
            ln -s pts/ptmx "$nr/dev/ptmx"
            mount -o remount,ro,bind "$nr/dev" 2>/dev/null
            mount -t proc -o ro,nosuid,nodev,noexec proc "$nr/proc" || exit 97
            mount -t tmpfs -o size=64m,mode=1777 tmpfs "$nr/tmp" || exit 97
            mount --bind "$mnt" "$nr/kopia" && mount -o remount,bind,ro "$nr/kopia" || exit 97
            mount --bind "$odz" "$nr/odzysk" || exit 97
            cd "$nr" && pivot_root . .old || exit 97
            cd / && umount -l /.old && rmdir /.old || exit 97
            mkdir -p /tmp/.mc
            HOME=/tmp XDG_CONFIG_HOME=/tmp/.mc XDG_DATA_HOME=/tmp/.mc XDG_CACHE_HOME=/tmp/.mc \
                exec setpriv --no-new-privs \
                    --bounding-set -all,+dac_override,+dac_read_search,+chown,+fowner,+fsetid \
                    --inh-caps -all -- "$mcbin" /kopia /odzysk
        ' _ "$mnt" "$odz" "$TMPD/mcxdg" "$MC" </dev/tty >/dev/tty 2>&1 || rc=$?
        if [ "$rc" -eq 97 ]; then
            echo "$(T 'Nie udało się zbudować przestrzeni tylko do odczytu (unshare/mount) -- mc nie zostanie uruchomiony.')"
        fi
    else
        "$MC" "$mnt" "$odz" </dev/tty >/dev/tty 2>&1   # testy: BROWSE_RO_NS=0 (bez roota i unshare)
    fi
    rmdir "$odz" 2>/dev/null && rmdir "$(dirname "$odz")" 2>/dev/null
    [ -d "$odz" ] && echo "$(Tv 'Skopiowane pliki: $ODZ' '$ODZ' "$odz")"
    return 0
}

# ---- mc w zamontowanym katalogu, potem sprzątanie ---------------------------------------
browse_and_exit() {
    local what="$1"
    clear 2>/dev/null
    echo "$(Tv 'Zamontowane TYLKO DO ODCZYTU: $what' '$what' "$what")"
    echo "$(Tv '  w $MNT -- skopiuj pliki w mc (lewy panel = kopia), F10 w mc kończy i odmontowuje.' '$MNT' "$MNT")"
    if command -v "$MC" >/dev/null 2>&1; then
        mc_readonly "$MNT"
    else
        echo
        echo "$(T 'Brak programu mc (apt install mc). Zamiast niego powłoka w katalogu kopii; exit kończy i odmontowuje.')"
        ( cd "$MNT" && "${SHELL:-/bin/bash}" -i ) </dev/tty >/dev/tty 2>&1
    fi
    RESIDUE=""
    unmount_all; restore_snapdev; unload_key
    echo
    if [ -z "$RESIDUE" ]; then
        # U90 (wlasciciel 2026-10-27): bez "Enter = powrót" -- wraca samo; Ctrl-O w GUI pokaze to.
        echo "$(T '=== Odmontowane.')"
        exit 0
    fi
    echo "$(Tv '=== NIE wszystko posprzątane:$RESIDUE' '$RESIDUE' "$RESIDUE")"
    echo "$(T 'Enter = powrót do GUI (przy wyjściu jeszcze jedna próba)')"
    read -r _ </dev/tty 2>/dev/null || true
    exit 1
}

step=1
# Wskazany dataset (--dataset=, z F4 Kopie) -- drzewo pominiete, gdy jest na liscie.
if [ -n "$PRE_DS" ]; then
    TYP="$(awk -F'\t' -v d="$PRE_DS" '$1 == d { print $2; exit }' "$TMPD/cand.tsv")"
    if [ -n "$TYP" ]; then DS="$PRE_DS"; step=2; fi
fi
# Wskazana migawka (--snapshot=, prawy panel F4): prosto do montowania. Migawka, ktorej juz
# nie ma (przycieta miedzy odczytem a Enter), wraca do menu migawek jej datasetu.
if [ -n "$PRE_SNAP" ]; then
    DS="${PRE_SNAP%@*}"; SNAP="${PRE_SNAP#*@}"
    TYP="$(zfs get -H -o value type -- "$DS" 2>/dev/null | tr -d '\r')"
    if [ -n "$TYP" ] && zfs list -H -o name -t snapshot -- "$PRE_SNAP" >/dev/null 2>&1; then
        if [ "$TYP" = volume ]; then step=3; else step=4; fi
    else
        wt --title "$TITLE" --msgbox "$(Tv 'Migawki $SNAP już nie ma -- wybierz z listy.' '$SNAP' "$PRE_SNAP")" 8 "$W"
        [ -n "$TYP" ] && step=2 || { DS=""; step=1; }
    fi
fi
while :; do
    case $step in
    1)  # U68 (właściciel 2026-10-21: "zginęło okno z rozwijającymi się gałęziami; to musi być
        # jednolite w całym pakiecie"): to samo drzewo co przy wyborze datasetów do kopii, w trybie
        # JEDNEJ pozycji. Wybrać da się dataset z migawką; gałęzie nad nim są do rozwijania.
        # Wcześniej płaska lista (pve10: 66 pozycji, 32 strzałki do hdd/labbrowse/v-ntfs).
        "$PY" - "$TMPD/cand.tsv" "$TMPD/tree-spec.json" "$(Tv '$TITLE: który dataset?' '$TITLE' "$TITLE")" "${DS:-}" "$REL" <<'PYEOF' || exit 1
import sys, json
import os as _os
_C = json.load(open(_os.environ["ZFS_TUI_CAT"], encoding="utf-8")) if _os.environ.get("ZFS_TUI_CAT") else {}
def _(s): return _C.get(s, s)
names, types = [], {}
for line in open(sys.argv[1], encoding="utf-8"):
    p = line.rstrip("\n").split("\t")
    if p and p[0]:
        names.append(p[0]); types[p[0]] = p[1] if len(p) > 1 else "filesystem"
allnames = set(names)
for n in names:                       # gałęzie nad kandydatami: do nawigacji, nie do wyboru
    parts = n.split("/")
    for i in range(1, len(parts)):
        allnames.add("/".join(parts[:i]))
# U83 (pve9 2026-10-27: piec rozwiniec pustych galezi do jedynego datasetu relacji):
# galezie nad kandydatami relacji sa otwarte od razu. U88: "z innego dysku" to caly
# host -- tam drzewo zostaje zwiniete (rozwiniete bylo sciana).
spec = {"title": sys.argv[3], "single": True, "selectable": names,
        "expand_to": names[:200] if sys.argv[5] != "--any" else [],
        "legend": _(u" Kopia zostanie zamontowana TYLKO DO ODCZYTU.  · = gałąź (bez migawek), → rozwija"),
        "roots": [sys.argv[4]] if sys.argv[4] else [],
        "datasets": [{"name": n, "type": types.get(n, "filesystem"), "used": None} for n in sorted(allnames)]}
json.dump(spec, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
PYEOF
        ${ZFS_TREE:-$PY $HERE/tui/tree.py} --spec "$TMPD/tree-spec.json" --out "$TMPD/tree-out.json" || exit 0
        DS="$("$PY" -c 'import json,sys; r=json.load(open(sys.argv[1], encoding="utf-8")).get("roots") or [""]; print(r[0])' "$TMPD/tree-out.json" | tr -d '\r')"
        TYP="$(awk -F'\t' -v d="$DS" '$1 == d { print $2; exit }' "$TMPD/cand.tsv")"
        [ -n "$DS" ] && [ -n "$TYP" ] || exit 0
        step=2 ;;
    # Rozmiar migawki (właściciel 2026-10-26): "zajmuje" = used (tyle zwolni jej usunięcie),
    # "zmian" = written (tyle zmieniło się od poprzedniej migawki).
    2)  zfs list -H -p -t snapshot -o name,creation,used,written -s creation -d 1 -- "$DS" 2>/dev/null \
            | tr -d '\r' | awk -F'\t' '
                function h(b,  u, i) { split("B K M G T P", u, " "); i = 1
                    while (b >= 1024 && i < 6) { b /= 1024; i++ }
                    return (i == 1 ? sprintf("%d%s", b, u[i]) : sprintf("%.1f%s", b, u[i])) }
                { n = $1; sub(/^[^@]*@/, "", n); print $2 "\t" n "\t" h($3) "\t" h($4) }' | tac | head -n 50 >"$TMPD/points.tsv"
        menu=(); i=0; dflt=""
        while IFS=$'\t' read -r cr nm su sw; do
            [ -n "$cr" ] || continue
            # Rozmiary przed nazwą: przy oknie 100 kolumn ucina się najwyżej koniec nazwy.
            # U74 (właściciel 2026-10-27, "okno się rozjeżdża"): rozmiary o stałej szerokości,
            # żeby nazwy migawek stały w jednej kolumnie.
            su="$(printf '%6s' "$su")"; sw="$(printf '%6s' "$sw")"
            lbl="$(date -d "@$cr" '+%Y.%m.%d %H:%M')  $(Tv 'zajmuje $su, zmian $sw' '$su' "$su" '$sw' "$sw")  $nm$([ "$i" -eq 0 ] && printf '  %s' "$(T '(najnowsza)')")"
            menu+=("p$i" "$(clip_label "$lbl" $((W - 12)))")
            [ -z "$dflt" ] && [ -n "$PRE_AT" ] && [ "$cr" -le "$PRE_AT" ] && dflt="p$i"
            i=$((i + 1))
        done <"$TMPD/points.tsv"
        PRE_AT=""
        geom
        wt --title "$(Tv '$TITLE: z kiedy?' '$TITLE' "$TITLE")" ${dflt:+--default-item "$dflt"} --menu "$(Tv '$DS -- migawka do przejrzenia (czas hosta, $(date +%Z)).' '$DS' "$DS" '$(date +%Z)' "$(date +%Z)")" "$H" "$W" "$(lhfit $i 1)" "${menu[@]}" || { step=1; continue; }
        k="${WT_OUT#p}"
        SNAP="$(sed -n "$((k + 1))p" "$TMPD/points.tsv" | cut -f2)"
        if [ "$TYP" = volume ]; then step=3; else step=4; fi ;;
    3)  # ---- DYSK VM: urządzenie migawki, partycja, klucz ---------------------------------
        undo_or_warn ""
        info "$TITLE" "$(T 'Udostępniam dysk VM z migawki tylko do odczytu...')"
        if ! expose_snapdev "$DS" 2>"$TMPD/sd.err"; then
            wt --title "$TITLE" --msgbox "$(Tv 'Nie udało się udostępnić dysku z migawki $DS@$SNAP do odczytu:
$ERR' '$DS' "$DS" '$SNAP' "$SNAP" '$ERR' "$(head -2 "$TMPD/sd.err")")" 10 "$W"
            undo_or_warn ""
            step=2; continue
        fi
        DEV="$ZVDIR/$DS@$SNAP"
        for _w in 1 2 3 4 5 6 7 8 9 10; do
            command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null
            [ -e "$DEV" ] && break; sleep 1
        done
        if ! [ -e "$DEV" ]; then
            undo_or_warn "$(Tv 'Urządzenie $DEV nie pojawiło się (udev). Nic nie zostało zmienione w kopii.' '$DEV' "$DEV")"
            step=2; continue
        fi
        sleep 1; command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null
        # parts.tsv: urządzenie, system plików, rozmiar, etykieta -- rozdzielone \001, NIE tabulatorem:
        # tab to biały znak IFS i dwa pod rząd (puste pole) zlewają się w jeden. Z JSON, nie z
        # `lsblk -r`: puste pole (sam dysk bez systemu plików) przesuwało tam kolumny i rozmiar
        # "96M" stawał się "systemem plików" -- dysk trafiał do menu i montaż padał (właściciel,
        # pve10 2026-10-18).
        lsblk -J -p -o NAME,FSTYPE,SIZE,LABEL "$(readlink -f "$DEV")" 2>/dev/null | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
def walk(ds):
    for x in ds or []:
        print("\x01".join([x.get("name") or "", x.get("fstype") or "", x.get("size") or "", x.get("label") or ""]))
        walk(x.get("children"))
walk(d.get("blockdevices"))' | tr -d '\r' >"$TMPD/parts.tsv"
        menu=(); i=0
        while IFS=$'\001' read -r pd pf ps pl; do
            [ -n "$pf" ] || continue
            case "$pf" in swap|LVM2_member|linux_raid_member|zfs_member) continue ;; esac
            lbl="$pd  $pf  $ps${pl:+  $pl}"
            case "$pf" in BitLocker|crypto_LUKS) lbl="$lbl  $(T '(zaszyfrowana -- klucz)')" ;; esac
            menu+=("q$i" "$(clip_label "$lbl" $((W - 12)))"); i=$((i + 1))
            printf '%s\t%s\n' "$pd" "$pf" >>"$TMPD/pick.tsv"
        done <"$TMPD/parts.tsv"
        if [ "$i" -eq 0 ]; then
            wt --title "$TITLE" --msgbox "$(Tv 'Na dysku $DS@$SNAP nie ma partycji z obsługiwanym systemem plików (NTFS, ext2/3/4, xfs, vfat, exfat, btrfs; BitLocker, LUKS). LVM i RAID -- jeszcze nie.' '$DS' "$DS" '$SNAP' "$SNAP")" 10 "$W"
            undo_or_warn ""; step=2; continue
        fi
        # I-2 (kampania 2026-10-21): jedna partycja do wyboru = bez okna wyboru (o jeden klawisz mniej).
        if [ "$i" -eq 1 ]; then
            WT_OUT=q0
        else
            wt --title "$(Tv '$TITLE: która partycja?' '$TITLE' "$TITLE")" --menu "$(Tv '$DS@$SNAP -- tylko do odczytu.' '$DS' "$DS" '$SNAP' "$SNAP")" "$H" "$W" "$(lhfit $i 1)" "${menu[@]}" || { rm -f "$TMPD/pick.tsv"; undo_or_warn ""; step=2; continue; }
        fi
        k="${WT_OUT#q}"
        PDEV="$(sed -n "$((k + 1))p" "$TMPD/pick.tsv" | cut -f1)"; PFS="$(sed -n "$((k + 1))p" "$TMPD/pick.tsv" | cut -f2)"
        rm -f "$TMPD/pick.tsv"
        case "$PFS" in
            BitLocker|crypto_LUKS)
                command -v cryptsetup >/dev/null 2>&1 || { wt --title "$TITLE" --msgbox "$(T 'Partycja jest zaszyfrowana, a na tym hoście nie ma cryptsetup (apt install cryptsetup-bin).')" 9 "$W"; undo_or_warn ""; step=2; continue; }
                _ty=luks; _hint="$(T 'hasło LUKS')"
                [ "$PFS" = BitLocker ] && { _ty=bitlk; _hint="$(T 'hasło BitLocker albo 48-cyfrowy klucz odzyskiwania (z myślnikami)')"; }
                _name="zbrowse-$$"
                _ok=0
                while :; do
                    wt --title "$(Tv '$TITLE: klucz' '$TITLE' "$TITLE")" --passwordbox "$(Tv '$PDEV jest zaszyfrowana ($PFS).\nPodaj $_hint.\nKlucz nie jest nigdzie zapisywany.' '$PDEV' "$PDEV" '$PFS' "$PFS" '$_hint' "$_hint")" 12 "$W" || break
                    if printf '%s' "$WT_OUT" | cryptsetup open --readonly --type "$_ty" --key-file=- "$PDEV" "$_name" 2>"$TMPD/cs.err"; then
                        _ok=1; break
                    fi
                    wt --title "$TITLE" --msgbox "$(Tv 'Nie udało się odblokować:\n$ERR\nSpróbuj jeszcze raz albo Anuluj.' '$ERR' "$(head -2 "$TMPD/cs.err")")" 11 "$W"
                done
                WT_OUT=""
                [ "$_ok" -eq 1 ] || { undo_or_warn ""; step=2; continue; }
                MAPPED="$_name"
                PDEV="$MAPDIR/$_name"
                PFS="$(blkid -o value -s TYPE "$PDEV" 2>/dev/null)"
                [ -n "$PFS" ] || PFS=unknown ;;
        esac
        if ! mount_ro "$PDEV" "$PFS"; then
            wt --title "$TITLE" --msgbox "$(Tv 'Nie udało się zamontować $PDEV ($PFS) tylko do odczytu:\n$ERR' '$PDEV' "$PDEV" '$PFS' "$PFS" '$ERR' "$(head -3 "$TMPD/mount.err")")" 11 "$W"
            undo_or_warn ""; step=2; continue
        fi
        browse_and_exit "$DS@$SNAP, $PDEV ($PFS)" ;;
    4)  need_key "$DS" || { step=2; continue; }
        if ! mount_ro "$DS@$SNAP" zfs; then
            wt --title "$TITLE" --msgbox "$(Tv 'Nie udało się zamontować $DS@$SNAP:\n$ERR' '$DS' "$DS" '$SNAP' "$SNAP" '$ERR' "$(head -3 "$TMPD/mount.err")")" 10 "$W"
            # REV-20261028-178: klucz tej proby zdjety od razu, nie dopiero przy wyjsciu.
            RESIDUE=""
            unload_key || wt --title "$TITLE" --msgbox "$(Tv 'Nie wszystko udało się posprzątać:$RESIDUE' '$RESIDUE' "$RESIDUE")" 14 "$W"
            step=2; continue
        fi
        browse_and_exit "$DS@$SNAP" ;;
    esac
done
