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
[ -n "$REL" ] || { echo "użycie: browse.sh RELACJA | browse.sh --any" >&2; exit 2; }
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
  kopia wciąż zamontowana: $MNT  (ręcznie: umount $MNT)"
            left=1
        else
            rmdir "$MNT" 2>/dev/null
            MNT=""
        fi
    fi
    if [ -n "$MAPPED" ]; then
        if [ "$left" -eq 1 ]; then
            RESIDUE="$RESIDUE
  odblokowane urządzenie /dev/mapper/$MAPPED zostaje otwarte -- najpierw odmontowanie (potem: cryptsetup close $MAPPED)"
        elif [ "$LAZY" -eq 1 ]; then
            RESIDUE="$RESIDUE
  system plików był zajęty (odłączony leniwie, umount -l) -- /dev/mapper/$MAPPED zostaje otwarte; gdy nic go nie używa: cryptsetup close $MAPPED"
            left=1
        elif cryptsetup close "$MAPPED" 2>/dev/null || ! [ -e "$MAPDIR/$MAPPED" ]; then
            MAPPED=""
        else
            RESIDUE="$RESIDUE
  nie udało się zamknąć /dev/mapper/$MAPPED (odszyfrowane dane dostępne!)  (ręcznie: cryptsetup close $MAPPED)"
            left=1
        fi
    fi
    return "$left"
}
# DWA PRZEGLĄDANIA TEGO SAMEGO DYSKU (pve10, 2026-10-18: pierwsze, które skończyło, przywróciło
# snapdev i drugiemu zniknęło /dev/zd..p1 w trakcie podawania klucza). Każde przeglądanie zostawia
# znacznik hold.<pid>.<dataset>; snapdev wraca dopiero, gdy nie ma innego ŻYWEGO znacznika tego
# datasetu, a wartość sprzed przeglądania zapisuje tylko pierwszy (orig.<dataset>).
hold_key() { printf '%s' "$1" | tr '/@' '__'; }
other_holders() {   # <dataset> -> 0 gdy inne żywe przeglądanie trzyma ten dataset
    local k f p; k="$(hold_key "$1")"
    for f in "$BROOT"/hold.*."$k"; do
        [ -e "$f" ] || continue
        p="${f#"$BROOT"/hold.}"; p="${p%%.*}"
        [ "$p" = "$$" ] && continue
        kill -0 "$p" 2>/dev/null && return 0
        rm -f "$f"
    done
    return 1
}
# REV-20261021-159 F2: snapdev zmieniany TYLKO, gdy wartość i źródło sprzed zmiany dało się
# odczytać i są poprawne. Zapis oryginału (orig.<dataset>) powstaje raz -- gdy go nie ma --
# i znika WYŁĄCZNIE po udanym przywróceniu: nieudane przywrócenie zostawia go (z poleceniem
# w RESIDUE), a następne przeglądanie nie nadpisze go bieżącym "visible".
expose_snapdev() {  # <dataset> -> 0 gdy snapdev=visible i znacznik założony
    local ds="$1" k v s; k="$(hold_key "$ds")"
    mkdir -p "$BROOT" || return 1
    if ! [ -s "$BROOT/orig.$k" ]; then
        v="$(zfs get -H -o value snapdev "$ds" 2>/dev/null)" || { echo "nie da się odczytać snapdev $ds -- nic nie zmieniam" >&2; return 1; }
        s="$(zfs get -H -o source snapdev "$ds" 2>/dev/null)" || { echo "nie da się odczytać źródła snapdev $ds -- nic nie zmieniam" >&2; return 1; }
        case "$v" in hidden|visible) ;; *) echo "snapdev $ds = '$v' -- nieznana wartość, nic nie zmieniam" >&2; return 1 ;; esac
        case "$s" in local|default|received|"inherited from "*) ;; *) echo "źródło snapdev $ds = '$s' -- nieznane, nic nie zmieniam" >&2; return 1 ;; esac
        printf '%s\t%s\n' "$v" "$s" >"$BROOT/orig.$k.$$" && mv -f "$BROOT/orig.$k.$$" "$BROOT/orig.$k" \
            || { rm -f "$BROOT/orig.$k.$$"; echo "nie da się zapisać $BROOT/orig.$k -- nic nie zmieniam" >&2; return 1; }
    fi
    : >"$BROOT/hold.$$.$k"
    SNAPDEV_DS="$ds"
    zfs set snapdev=visible "$ds"
}
restore_snapdev() {   # -> 0 przywrócone albo nie było czego; 1 nie (opis w RESIDUE, stan zachowany)
    [ -n "$SNAPDEV_DS" ] || return 0
    local k was src ok=1; k="$(hold_key "$SNAPDEV_DS")"
    rm -f "$BROOT/hold.$$.$k"
    if other_holders "$SNAPDEV_DS"; then SNAPDEV_DS=""; return 0; fi   # inne przeglądanie trzyma
    if ! IFS=$'\t' read -r was src <"$BROOT/orig.$k" 2>/dev/null; then
        RESIDUE="$RESIDUE
  nie ma zapisu snapdev sprzed przeglądania ($BROOT/orig.$k) -- snapdev $SNAPDEV_DS zostawiam (sprawdź: zfs get snapdev $SNAPDEV_DS)"
        return 1
    fi
    case "$src" in
        local)                     zfs set snapdev="$was" "$SNAPDEV_DS" 2>/dev/null || ok=0 ;;
        default|"inherited from "*) zfs inherit snapdev "$SNAPDEV_DS" 2>/dev/null || ok=0 ;;
        received)                  zfs inherit -S snapdev "$SNAPDEV_DS" 2>/dev/null || ok=0 ;;
        *)                         ok=0 ;;
    esac
    if [ "$ok" -eq 1 ]; then
        rm -f "$BROOT/orig.$k"; SNAPDEV_DS=""; return 0
    fi
    RESIDUE="$RESIDUE
  snapdev na $SNAPDEV_DS NIE przywrócony (było: $was, $src; zapis w $BROOT/orig.$k)  (ręcznie: $(case "$src" in local) echo "zfs set snapdev=$was $SNAPDEV_DS" ;; *) echo "zfs inherit snapdev $SNAPDEV_DS" ;; esac))"
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
        wt --title "$TITLE" --msgbox "Nie wszystko udało się przywrócić:$RESIDUE" 14 "$W"
    fi
    return 0
}
cleanup() {
    RESIDUE=""
    unmount_all; restore_snapdev
    [ -n "$RESIDUE" ] && printf 'Przeglądaj kopię -- NIE wszystko posprzątane:%s\n' "$RESIDUE" >&2
    rm -rf "$TMPD"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ "$REL" = --any ]; then
    WT_BACKTITLE="Przeglądaj kopię na dysku -- $(hostname)"
    TITLE="Przeglądaj kopię"
else
    WT_BACKTITLE="Przeglądaj kopię relacji $REL -- $(hostname)"
    TITLE="Przeglądaj $REL"
fi
geom

if [ "$(id -u)" -ne 0 ]; then
    wt --title "$TITLE" --msgbox "Montowanie migawki wymaga roota. Uruchom GUI jako root (zfs-backup gui)." 8 "$W"
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
    wt --title "$TITLE" --msgbox "Na tym hoście nie ma kopii do przeglądania$([ "$REL" = --any ] || echo " relacji $REL")." 8 "$W"
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
    wt --title "$TITLE" --msgbox "Kopie nie mają żadnej migawki -- nie ma czego przeglądać." 8 "$W"
    exit 1
fi

# ---- montaż ro wg systemu plików: <urządzenie> <typ> -> 0, MNT ustawiony ---------------
mount_ro() {
    local dev="$1" fs="$2" opts="ro"
    mkdir -p "$BROOT" && MNT="$(mktemp -d "$BROOT/browse.XXXXXX")" || { MNT=""; echo "nie mogę utworzyć katalogu w $BROOT" >"$TMPD/mount.err"; return 1; }
    case "$fs" in
        ntfs)
            if modinfo ntfs3 >/dev/null 2>&1 || grep -qw ntfs3 /proc/filesystems; then
                mount -t ntfs3 -o ro "$dev" "$MNT" 2>"$TMPD/mount.err" && return 0
            fi
            if command -v ntfs-3g >/dev/null 2>&1; then
                ntfs-3g -o ro "$dev" "$MNT" 2>"$TMPD/mount.err" && return 0
            fi
            echo "brak sterownika NTFS (moduł ntfs3 albo pakiet ntfs-3g)" >>"$TMPD/mount.err" ;;
        ext2|ext3|ext4) mount -t "$fs" -o ro,noload "$dev" "$MNT" 2>"$TMPD/mount.err" && return 0 ;;
        xfs)            mount -t xfs -o ro,norecovery,nouuid "$dev" "$MNT" 2>"$TMPD/mount.err" && return 0 ;;
        zfs)            mount -t zfs -o ro "$dev" "$MNT" 2>"$TMPD/mount.err" && return 0 ;;
        *)              mount -o "$opts" "$dev" "$MNT" 2>"$TMPD/mount.err" && return 0 ;;
    esac
    rmdir "$MNT" 2>/dev/null; MNT=""
    return 1
}

# ---- mc w zamontowanym katalogu, potem sprzątanie ---------------------------------------
browse_and_exit() {
    local what="$1"
    clear 2>/dev/null
    echo "Zamontowane TYLKO DO ODCZYTU: $what"
    echo "  w $MNT -- skopiuj pliki w mc (lewy panel = kopia), F10 w mc kończy i odmontowuje."
    if command -v "$MC" >/dev/null 2>&1; then
        "$MC" "$MNT" "${HOME:-/root}" </dev/tty >/dev/tty 2>&1
    else
        echo
        echo "Brak programu mc (apt install mc). Zamiast niego powłoka w katalogu kopii; exit kończy i odmontowuje."
        ( cd "$MNT" && "${SHELL:-/bin/bash}" -i ) </dev/tty >/dev/tty 2>&1
    fi
    RESIDUE=""
    unmount_all; restore_snapdev
    echo
    if [ -z "$RESIDUE" ]; then
        echo "=== Odmontowane. Enter = powrót do GUI"
        read -r _ </dev/tty 2>/dev/null || true
        exit 0
    fi
    echo "=== NIE wszystko posprzątane:$RESIDUE"
    echo "Enter = powrót do GUI (przy wyjściu jeszcze jedna próba)"
    read -r _ </dev/tty 2>/dev/null || true
    exit 1
}

step=1
while :; do
    case $step in
    1)  menu=(); i=0
        while IFS=$'\t' read -r n t; do
            lbl="$n"; [ "$t" = volume ] && lbl="$n  (dysk VM)"
            menu+=("d$i" "$(clip_label "$lbl" $((W - 12)))"); i=$((i + 1))
        done <"$TMPD/cand.tsv"
        geom
        wt --title "$TITLE: który dataset?" --menu "Kopia zostanie zamontowana TYLKO DO ODCZYTU." "$H" "$W" "$(lhfit $i 1)" "${menu[@]}" || exit 0
        k="${WT_OUT#d}"
        DS="$(sed -n "$((k + 1))p" "$TMPD/cand.tsv" | cut -f1)"; TYP="$(sed -n "$((k + 1))p" "$TMPD/cand.tsv" | cut -f2)"
        step=2 ;;
    2)  zfs list -H -p -t snapshot -o name,creation -s creation -d 1 -- "$DS" 2>/dev/null \
            | tr -d '\r' | awk -F'\t' '{ n = $1; sub(/^[^@]*@/, "", n); print $2 "\t" n }' | tac | head -n 50 >"$TMPD/points.tsv"
        menu=(); i=0
        while IFS=$'\t' read -r cr nm; do
            [ -n "$cr" ] || continue
            lbl="$(date -d "@$cr" '+%Y-%m-%d %H:%M')  $nm"; [ "$i" -eq 0 ] && lbl="$lbl  (najnowsza)"
            menu+=("p$i" "$(clip_label "$lbl" $((W - 12)))"); i=$((i + 1))
        done <"$TMPD/points.tsv"
        geom
        wt --title "$TITLE: z kiedy?" --menu "$DS -- migawka do przejrzenia (czas hosta, $(date +%Z))." "$H" "$W" "$(lhfit $i 1)" "${menu[@]}" || { step=1; continue; }
        k="${WT_OUT#p}"
        SNAP="$(sed -n "$((k + 1))p" "$TMPD/points.tsv" | cut -f2)"
        if [ "$TYP" = volume ]; then step=3; else step=4; fi ;;
    3)  # ---- DYSK VM: urządzenie migawki, partycja, klucz ---------------------------------
        undo_or_warn ""
        info "$TITLE" "Wystawiam migawkę dysku jako urządzenie tylko do odczytu..."
        if ! expose_snapdev "$DS" 2>"$TMPD/sd.err"; then
            wt --title "$TITLE" --msgbox "Nie mogę wystawić migawki $DS@$SNAP jako urządzenia:\n$(head -2 "$TMPD/sd.err")" 10 "$W"
            undo_or_warn ""
            step=2; continue
        fi
        DEV="$ZVDIR/$DS@$SNAP"
        for _w in 1 2 3 4 5 6 7 8 9 10; do
            command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null
            [ -e "$DEV" ] && break; sleep 1
        done
        if ! [ -e "$DEV" ]; then
            undo_or_warn "Urządzenie $DEV nie pojawiło się (udev). Nic nie zostało zmienione w kopii."
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
            case "$pf" in BitLocker|crypto_LUKS) lbl="$lbl  (zaszyfrowana -- klucz)" ;; esac
            menu+=("q$i" "$(clip_label "$lbl" $((W - 12)))"); i=$((i + 1))
            printf '%s\t%s\n' "$pd" "$pf" >>"$TMPD/pick.tsv"
        done <"$TMPD/parts.tsv"
        if [ "$i" -eq 0 ]; then
            wt --title "$TITLE" --msgbox "Na dysku $DS@$SNAP nie ma partycji z obsługiwanym systemem plików (NTFS, ext2/3/4, xfs, vfat, exfat, btrfs; BitLocker, LUKS). LVM i RAID -- jeszcze nie." 10 "$W"
            undo_or_warn ""; step=2; continue
        fi
        wt --title "$TITLE: która partycja?" --menu "$DS@$SNAP -- tylko do odczytu." "$H" "$W" "$(lhfit $i 1)" "${menu[@]}" || { rm -f "$TMPD/pick.tsv"; undo_or_warn ""; step=2; continue; }
        k="${WT_OUT#q}"
        PDEV="$(sed -n "$((k + 1))p" "$TMPD/pick.tsv" | cut -f1)"; PFS="$(sed -n "$((k + 1))p" "$TMPD/pick.tsv" | cut -f2)"
        rm -f "$TMPD/pick.tsv"
        case "$PFS" in
            BitLocker|crypto_LUKS)
                command -v cryptsetup >/dev/null 2>&1 || { wt --title "$TITLE" --msgbox "Partycja jest zaszyfrowana, a na tym hoście nie ma cryptsetup (apt install cryptsetup-bin)." 9 "$W"; undo_or_warn ""; step=2; continue; }
                _ty=luks; _hint="hasło LUKS"
                [ "$PFS" = BitLocker ] && { _ty=bitlk; _hint="hasło BitLocker albo 48-cyfrowy klucz odzyskiwania (z myślnikami)"; }
                _name="zbrowse-$$"
                _ok=0
                while :; do
                    wt --title "$TITLE: klucz" --passwordbox "$PDEV jest zaszyfrowana ($PFS).\nPodaj $_hint.\nKlucz nie jest nigdzie zapisywany." 12 "$W" || break
                    if printf '%s' "$WT_OUT" | cryptsetup open --readonly --type "$_ty" --key-file=- "$PDEV" "$_name" 2>"$TMPD/cs.err"; then
                        _ok=1; break
                    fi
                    wt --title "$TITLE" --msgbox "Nie udało się odblokować:\n$(head -2 "$TMPD/cs.err")\nSpróbuj jeszcze raz albo Anuluj." 11 "$W"
                done
                WT_OUT=""
                [ "$_ok" -eq 1 ] || { undo_or_warn ""; step=2; continue; }
                MAPPED="$_name"
                PDEV="$MAPDIR/$_name"
                PFS="$(blkid -o value -s TYPE "$PDEV" 2>/dev/null)"
                [ -n "$PFS" ] || PFS=unknown ;;
        esac
        if ! mount_ro "$PDEV" "$PFS"; then
            wt --title "$TITLE" --msgbox "Nie udało się zamontować $PDEV ($PFS) tylko do odczytu:\n$(head -3 "$TMPD/mount.err")" 11 "$W"
            undo_or_warn ""; step=2; continue
        fi
        browse_and_exit "$DS@$SNAP, $PDEV ($PFS)" ;;
    4)  if ! mount_ro "$DS@$SNAP" zfs; then
            wt --title "$TITLE" --msgbox "Nie udało się zamontować $DS@$SNAP:\n$(head -3 "$TMPD/mount.err")" 10 "$W"
            step=2; continue
        fi
        browse_and_exit "$DS@$SNAP" ;;
    esac
done
