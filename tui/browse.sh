#!/bin/bash
# browse.sh RELACJA | browse.sh --any -- "Przeglądaj kopię" (chudy odzysk), w whiptailu.
#
# Właściciel 2026-10-18: migawka kopii zamontowana TYLKO DO ODCZYTU, `mc` do skopiowania
# plików, po wyjściu z mc odmontowanie. Nic w kopii się nie zmienia: montaż `-o ro` migawki
# (migawka i tak jest tylko do odczytu), w katalogu tymczasowym pod /run, sprzątanym zawsze
# (trap). Na razie datasety PLIKOWE (LXC, katalogi); zvol (VM) -- odmowa z wyjaśnieniem.
#
# Kroki: 1 który dataset (kopie relacji na tym hoście; --any: każdy dataset plikowy z
# migawkami), 2 która migawka (najnowsza pierwsza), 3 montaż + mc, odmontowanie.
#
# Środowisko (testy): ZFS_BACKUP, WHIPTAIL, ZFS_CONF_DIR, PYTHON, BROWSE_MC (domyślnie mc),
# BROWSE_ROOT (domyślnie /run/zfs-browse).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "browse: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
REL="${1:-}"
[ -n "$REL" ] || { echo "użycie: browse.sh RELACJA | browse.sh --any" >&2; exit 2; }
CONFDIR="${ZFS_CONF_DIR:-/etc/zfs-snapshot-all}"
MC="${BROWSE_MC:-mc}"
BROOT="${BROWSE_ROOT:-/run/zfs-browse}"
TMPD="$(mktemp -d)" || exit 1
MNT=""
cleanup() {
    if [ -n "$MNT" ]; then
        umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null
        rmdir "$MNT" 2>/dev/null
    fi
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
: >"$TMPD/cand.tsv"
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

step=1
while :; do
    case $step in
    1)  menu=(); i=0
        while IFS=$'\t' read -r n t; do
            lbl="$n"; [ "$t" = volume ] && lbl="$n  (dysk VM -- jeszcze nie)"
            menu+=("d$i" "$(clip_label "$lbl" $((W - 12)))"); i=$((i + 1))
        done <"$TMPD/cand.tsv"
        geom
        wt --title "$TITLE: który dataset?" --menu "Kopia zostanie zamontowana TYLKO DO ODCZYTU." "$H" "$W" "$(lhfit $i 1)" "${menu[@]}" || exit 0
        k="${WT_OUT#d}"
        DS="$(sed -n "$((k + 1))p" "$TMPD/cand.tsv" | cut -f1)"; TYP="$(sed -n "$((k + 1))p" "$TMPD/cand.tsv" | cut -f2)"
        if [ "$TYP" = volume ]; then
            wt --title "$TITLE" --msgbox "$DS to dysk maszyny wirtualnej (zvol). Przeglądanie plików wewnątrz dysku VM będzie w następnej rundzie -- na razie tylko datasety plikowe (LXC, katalogi)." 10 "$W"
            continue
        fi
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
        step=3 ;;
    3)  mkdir -p "$BROOT" && MNT="$(mktemp -d "$BROOT/browse.XXXXXX")" || { MNT=""; wt --title "$TITLE" --msgbox "Nie mogę utworzyć katalogu w $BROOT." 8 "$W"; exit 1; }
        if ! mount -t zfs -o ro "$DS@$SNAP" "$MNT" 2>"$TMPD/mount.err"; then
            wt --title "$TITLE" --msgbox "Nie udało się zamontować $DS@$SNAP:\n$(head -3 "$TMPD/mount.err")" 10 "$W"
            rmdir "$MNT" 2>/dev/null; MNT=""
            step=2; continue
        fi
        clear 2>/dev/null
        echo "Zamontowane TYLKO DO ODCZYTU: $DS@$SNAP"
        echo "  w $MNT -- skopiuj pliki w mc (lewy panel = kopia), F10 w mc kończy i odmontowuje."
        if command -v "$MC" >/dev/null 2>&1; then
            "$MC" "$MNT" "${HOME:-/root}" </dev/tty >/dev/tty 2>&1
        else
            echo
            echo "Brak programu mc (apt install mc). Zamiast niego powłoka w katalogu kopii; exit kończy i odmontowuje."
            ( cd "$MNT" && "${SHELL:-/bin/bash}" -i ) </dev/tty >/dev/tty 2>&1
        fi
        umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null
        rmdir "$MNT" 2>/dev/null; MNT=""
        echo
        echo "=== Odmontowane. Enter = powrót do GUI"
        read -r _ </dev/tty 2>/dev/null || true
        exit 0 ;;
    esac
done
