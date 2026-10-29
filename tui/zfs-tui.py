#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cztery okna nad zfs-snapshot-all: Relacje, Relacja, Transfery, Nosniki.

Owner, 2026-09-09: "Prosze zrobic te nieszczesne okna, ogarnac problemy,
sprawdzic funkcjonalnosc i sensowny wyglad tych okien oraz poprawnosc ich
dzialan."

CO TO JEST. Pelnoekranowy tryb tekstowy w sesji SSH (decyzja wlasciciela
2026-09-05: admin laczy sie z domu przez VPN i PuTTY, ma tylko tekst), w idiomie
Turbo Vision: ramki, listwa F-klawiszy, okno na wierzchu. Python 3 z biblioteki
standardowej i `curses` -- to stoi na kazdym hoscie floty (pve2/pve1 3.9.2,
pve9/pve10 3.11.2), wiec nie dokladamy zaleznosci. Jeden plik, jeden czasownik:
`zfs-backup.sh gui`.

SKAD SA DANE. Wylacznie z czytelnikow `--json` (zasada 1 dokumentu decyzji: GUI
nie skrobie tekstu): `status`, `list-jobs`, `monitor`, `progress`,
`list-replicas`, a na zadanie `show-config NAME`. Czego nie ma w JSON, tego nie
ma na ekranie -- zamiast zgadywac, ekran mowi, ze nie wie.

RYSOWANIE JEST FUNKCJA CZYSTA: STAN -> LINIE. To nie estetyka, tylko jedyny
sposob, w jaki te okna da sie sprawdzic: `plink -batch` nie daje terminala,
wiec petli curses nie da sie uruchomic z maszyny, na ktorej pisze sie testy.
`--render-once --screen X` drukuje DOKLADNIE to, co narysowalby curses, a
curses jest cienka petla, ktora te same linie wypisuje i koloruje. Suita
test/tui/run.sh patrzy na to samo, co operator.

CZEGO TE OKNA NIE ROBIA: niczego nie zmieniaja. Zadnego zapisu, zadnej komendy
poza czytelnikami. Okno relacji NAZYWA komendy CLI wlasciwe dla stanu relacji,
zeby operator wiedzial, co wpisac -- ale ich nie wykonuje (etap C/D planu).
"""

import argparse
import io
import json
import locale
import os
import re
import shlex
import signal
import subprocess
import sys
import time

# WYJSCIE ZAWSZE W UTF-8, NIEZALEZNIE OD PLATFORMY. Maszyna, na ktorej te ekrany
# sa testowane, ma konsole cp1250 i bez tej linii "spóźnione" wychodzilo jako
# "sp?nione": test porownywalby pokaleczone bajty.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

MIN_WIDTH = 80

# ---------------------------------------------------------------------------
# JĘZYK OKIEN (publikacja 1.0, właściciel 2026-10-23/24: GUI PL+EN, „sprytnie, bez dmuchania
# kodu”; komunikaty CLI zostają po angielsku). Tekst polski w kodzie jest KLUCZEM; katalog
# tui/lang/en.json (z tabeli przeglądu właściciela, tui/lang/build.py) daje angielski. Brak
# wpisu = tekst polski, nic się nie psuje. Język: --lang, potem ZFS_TUI_LANG (dziedziczą go
# okna whiptail), potem [gui] language w settings.ini (F10 Ustawienia), domyślnie ANGIELSKI
# (właściciel 2026-10-24: publikacja dla społeczności Proxmoxa; polski przełącza --lang=pl / F10).
# Katalog to DANE: json.load, nic nie jest wykonywane.
# ---------------------------------------------------------------------------
LANGS = ("pl", "en")
LANG_CAT = {}


def ui_lang(explicit=None):
    for v in (explicit, os.environ.get("ZFS_TUI_LANG")):
        if v in LANGS:
            return v
    path = os.environ.get("SETTINGS_FILE") or "/etc/zfs-snapshot-all/settings.ini"
    sec = "engine"
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if line.startswith("[") and line.endswith("]"):
                    sec = line[1:-1].strip()
                elif sec == "gui" and "=" in line and line.split("=", 1)[0].strip() == "language":
                    v = line.split("=", 1)[1].strip()
                    if v in LANGS:
                        return v
    except (OSError, UnicodeError):
        pass
    return "en"


def load_lang(lang):
    """Wczytaj katalog języka (pl = pusty: klucz jest tekstem)."""
    global LANG_CAT
    LANG_CAT = {}
    if lang != "pl":
        try:
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "lang", lang + ".json"),
                      encoding="utf-8") as fh:
                LANG_CAT = json.load(fh)
        except (OSError, ValueError):
            LANG_CAT = {}


def _(s):
    """Tekst okna w bieżącym języku; bez wpisu w katalogu -- polski."""
    return LANG_CAT.get(s, s)

# ---------------------------------------------------------------------------
# SLOWNIK EKRANU
# ---------------------------------------------------------------------------
# Werdykt monitora -> (slowo na ekranie, para kolorow curses).
#
# SLOWA, NIE ETYKIETY KONTRAKTU. Wlasciciel, 2026-09-08: "Nie rozumiem co to
# znaczy najgorszy werdykt. Nieczytelne." Kolumna mowi, CO SIE STALO z kopia.
# UNKNOWN i BEZ MONITORA sa rozne: "nie odpowiada" znaczy PYTALEM I NIE WIEM,
# "bez monitora" -- ze NIKT NIE PYTA. check-snap-age.sh pisze to w naglowku:
# monitor, ktory nigdy nie chodzi, wyglada dokladnie jak monitor mowiacy, ze
# wszystko dobrze.
VERDICTS = {
    # BLAD (2026-10-08, wlasciciel "rob 1 i 2"): ostatni bieg zadania skonczyl
    # sie bledem (rc != 0, poza 75 = pominiety przez blokade). Monitor patrzy
    # tylko na wiek kopii, wiec odmowa pobrania byla "aktualne" przez 3 godziny.
    "BLAD":         (u"błąd biegu",   1),
    "OK":           ("aktualne",      2),
    "WARNING":      (u"spóźnione",    3),
    "CRITICAL":     ("stare",         1),
    "UNKNOWN":      ("nie odpowiada", 4),
    "BEZ MONITORA": ("bez monitora",  4),
    # Start dwuetapowy (2026-10-29): monitor jeszcze nie odpowiedzial -- NIE "bez monitora".
    "SPRAWDZAM":    (u"sprawdzam…",   4),
}
VERDICT_ORDER = ["BLAD", "CRITICAL", "WARNING", "UNKNOWN", "SPRAWDZAM", "BEZ MONITORA", "OK"]

# Stan transferu z progress --json -> slowo. `verified` to `ok` podniesione po
# weryfikacji GUID (lib-zfs-snap.sh), wiec dla operatora to to samo "OK".
TRANSFER_STATES = {
    "running":  ("w toku", 3),
    "ok":       ("OK", 2),
    "verified": ("OK", 2),
    "failed":   (u"BŁĄD", 1),
}

# Cztery stany nosnika, nie flaga. Boolean obecny/nieobecny splaszczylby dwa
# srodkowe w jeden i schowalby ten jedyny grozny (dokument decyzji, sekcja 6).
MEDIA_STATES = {
    "here":         ("TU", 2, u"pula zaimportowana, replika może pisać"),
    "available":    ("Podłączony", 3, u"dysk jest podłączony, pula NIEzaimportowana -- brama zaimportuje ją przy biegu"),
    "away":         ("W SEJFIE", 4, u"nośnika nie ma w maszynie; to stan oczekiwany między wymianami"),
    "wrong_medium": ("NIE TEN DYSK", 1, u"podłączony jest dysk, ale NIE TEN. Brama odmówi replikacji; wyjęcie złego nośnika to ruch człowieka przy maszynie"),
    "unknown":      ("?", 4, u"brama nośnika (zfs-media-gate.sh) nie odpowiedziała -- stan nieznany, nie 'brak'"),
}

def replica_type_word(r):
    """U99 (wlasciciel 2026-10-27): kolumna Typ -- nosnik staly to "wewnętrzny";
    wymienny: podłączony / odłączony (stany niepewne slowami bramy)."""
    if (r.get("media") or "") == "fixed":
        return _(u"wewnętrzny")
    p = r.get("present") or "unknown"
    if p in ("here", "available"):
        return _(u"podłączony")
    if p == "away":
        return _(u"odłączony")
    return _(MEDIA_STATES.get(p, MEDIA_STATES["unknown"])[0])


def media_state_line(r, st):
    """Stan nosnika w panelu repliki (uwaga 17, 2026-10-08). Dysk w maszynie mowi tez,
    czy kopia na nim jest aktualna -- "w slocie" samo nie mowilo nic o kopii."""
    if r.get("present") in ("available", "here"):
        lc = r.get("last_current") or ""
        return u"%s -- %s" % (_(st[0]), (_(u"kopia aktualna z %s") % dshow(lc)) if lc else _(u"brak kopii"))
    return u"%s -- %s" % (_(st[0]), _(st[2]))


# Slowa, ktore curses koloruje, gdziekolwiek stoja w linii. Sa wybrane tak,
# zeby nie byly podciagami zwyklego tekstu.
COLOR_WORDS = [
    ("nie odpowiada", 4), ("bez monitora", 4), ("aktualne", 2), (u"spóźnione", 3),
    (" stare", 1), ("NIE TEN DYSK", 1), ("Podłączony", 3), ("W SEJFIE", 4), (" TU ", 2),
    (u"BŁĄD", 1), ("w toku", 3), ("PAUZA", 3), ("NIEwdro", 1), ("nieczytelny", 1),
    (u"błąd źródła", 1), (" OK ", 2), (" OK", 2),
]

def color_words():
    """COLOR_WORDS plus ich tłumaczenia (w polskim: dokładnie COLOR_WORDS). Liczone przy
    rysowaniu, bo katalog języka wchodzi dopiero po imporcie; odstępy z brzegów słowa
    zostają (" stare" -> " stale")."""
    out = list(COLOR_WORDS)
    if LANG_CAT:
        for w, pair in COLOR_WORDS:
            core = w.strip()
            t = _(core)
            if core and t != core:
                out.append((w.replace(core, t), pair))
    return out


ARROWS_UTF = {"local": u"→ tutaj", "push": u"→ {peer}", "pull": u"← {peer}",
              "snapshot": "(migawka)", "prune": u"prune"}
ARROWS_ASCII = {"local": "-> tutaj", "push": "-> {peer}", "pull": "<- {peer}",
                "snapshot": "(migawka)", "prune": "prune"}

# Wlasciciel, 2026-09-09: F2 to ZADANIA (co chodzi w cronie, z relacja i
# kierunkiem), a relacje dostaja WLASNE okno do zarzadzania (F3). Kierunek jest
# zapisany zawsze z tego hosta: lewa strona to my, prawa to peer.
#
# F5 MONITOR ZNIKL (wlasciciel, wariant b, 2026-09-24): F2 i F5 pokazywaly ten
# sam werdykt "Kopie" i wlasciciel nie widzial roznicy. Swiezosc zostaje na
# F3/F2; to, co F5 pokazywal WIECEJ (harmonogram straznika, progi, straznik bez
# zadania), przenioslo sie do panelu F2 (rel_detail_pairs, build_jobs).
# KOPIE (U82, wlasciciel 2026-10-27: "Upraszczamy"): F4 to jedno okno kopii -- przegladanie
# (Enter) i przywracanie (F9) z tej samej listy zrodel; F4 Historia weszla w F2 Przebiegi,
# F11 Odzysk w F4. F11 jest wolne.
SCREENS = [("zadania", "F2", u"Przebiegi"), ("relacje", "F3", "Relacje"), ("odzysk", "F4", u"Kopie"),
           ("szablony", "F5", "Szablony"), ("nosniki", "F6", u"Replika")]


def home_dir():
    """$HOME przed expanduser: na hoscie to to samo, a testy moga go ustawic."""
    return os.environ.get("HOME") or os.path.expanduser("~")


# R4-10 (wlasciciel 2026-09-24): eksport i import relacji domyslnie w JEDNYM
# miejscu na hoscie, obok profili uzytkownika (/etc/zfs-snapshot-all/profiles,
# PROFILE_USER_ROOT w zfs-backup.sh). Poza checkoutem: git go nie widzi, pull
# go nie nadpisze, a katalog nie zalezy od konta (dawniej $HOME -- inny dla
# roota, inny dla zfsbackup). Zmienna srodowiska -- dla testow.
def relations_dir():
    return os.environ.get("ZFS_TUI_RELATIONS_DIR") or "/etc/zfs-snapshot-all/relations"


EXPORT_SCHEMA = "zfs-backup/relation-export/"


def export_file_info(path):
    """(nazwa relacji, mtime) pliku eksportu albo None, gdy to nie eksport.
    Lista importu pokazuje TYLKO pliki eksportu (R4-9): krotsza i nie da sie
    wybrac czegos, czego czasownik i tak nie przyjmie."""
    try:
        if os.path.getsize(path) > 1024 * 1024:
            return None
        with open(path, "rb") as fh:
            doc = json.loads(fh.read().decode("utf-8", "replace"))
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict) or not str(doc.get("schema", "")).startswith(EXPORT_SCHEMA):
        return None
    try:
        mt = os.path.getmtime(path)
    except OSError:
        mt = 0
    return doc.get("name") or "?", mt


_HOSTS = None
_REL_BY_ADDR = {}


def note_relation_names(status):
    """Wlasciciel 2026-10-29: "gdy jest tylko adres, to nazwa relacji" -- relacja to para
    hostow, a jej nazwa domyslnie jest nazwa drugiego hosta. Adres (peer_host i ten, przez
    ktory chodzi teraz) -> nazwa relacji; jeden adres w dwoch relacjach -> zadnej."""
    _REL_BY_ADDR.clear()
    seen = {}
    for r in (status or {}).get("relations", []) if isinstance(status, dict) else []:
        if r.get("state") == "removed" or not r.get("name"):
            continue
        for a in {r.get("peer_host") or "", rel_addr(r)}:
            if a:
                seen.setdefault(a, set()).add(r["name"])
    for a, names in seen.items():
        if len(names) == 1:
            _REL_BY_ADDR[a] = names.pop()


def host_name(addr):
    """U111 (wlasciciel 2026-10-29, "Do kitu to jest"): adres -> nazwa hosta z /etc/hosts
    tego hosta, krotka (pve9, nie pve9.lab); gdy jej tam nie ma -- nazwa relacji z tym
    adresem; dopiero potem sam adres. Tylko plik, bez DNS: odwrotne zapytanie o obcy
    adres potrafi wisiec sekundami."""
    global _HOSTS
    if not addr or not re.match(r"^[0-9.]+$|^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*$", addr):
        return addr
    if _HOSTS is None:
        _HOSTS = {}
        try:
            with io.open(os.environ.get("ZFS_TUI_HOSTS", "/etc/hosts"), encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    f = line.split("#", 1)[0].split()
                    if len(f) < 2 or f[0] in _HOSTS:
                        continue
                    names = [n for n in f[1:] if n not in ("localhost", "localhost.localdomain")]
                    if names:
                        # pierwsza krotka nazwa wiersza, inaczej pierwsza nazwa bez domeny
                        short = [n for n in names if "." not in n]
                        _HOSTS[f[0]] = short[0] if short else names[0].split(".")[0]
        except OSError:
            pass
    return _HOSTS.get(addr) or _REL_BY_ADDR.get(addr) or addr


def side_words(ep, here=None):
    """Strona kopii po ludzku: `zfsbackup-pve10@192.168.28.99:hdd/enc` -> `pve9:hdd/enc`;
    dataset bez hosta lezy na tym hoscie -> `pve10:hdd/backups/...` (gdy `here` dane).
    Konto ssh i adres sa w zakladce Config okna relacji, nie tu."""
    if not ep or ep in ("?", "-"):
        return ep
    m = re.match(r"^(?:[^@/:\s]+@)?([A-Za-z0-9._-]+|\[[0-9A-Fa-f:]+\]):(.+)$", ep)
    if m and "/" not in m.group(1):
        return u"%s:%s" % (host_name(m.group(1).strip("[]")), m.group(2))
    return u"%s:%s" % (here, ep) if here else ep


def here_name(data):
    """Nazwa TEGO hosta (list-jobs: hostname -s), do stron `pve10:hdd/...`."""
    return ((getattr(data, "jobs", None) or {}).get("host")) or None


def rel_addr(rel):
    """Adres, przez ktory relacja chodzi TERAZ (active_endpoint bez portu); po zmianie
    adresu (kolektor za VPN) kolumna Kierunek pokazywala stary peer_host (kampania 2026-10-19)."""
    ep = (rel or {}).get("active_endpoint") or ""
    h = ep.rsplit(":", 1)[0] if ":" in ep else ep
    return h or (rel or {}).get("peer_host") or ""


def direction_of(host, peer, dirs, mode=None):
    """`pve9 → pve10` pobieram (strzalka idzie jak dane), `pve10 → pve9` wysylam,
    `pve10 ↔ pve9` w obie strony, `local` w obrebie hosta. Drugi host NAZWA z
    /etc/hosts, adres tylko gdy nazwy nie ma (U111, 2026-10-29: `pve10<192.168.28.99`
    trzeba bylo odszyfrowywac).

    ZAPISANY TRYB WYGRYWA z odczytem linii crona -- relacja synchro ciagnie
    OBIE strony PULLEM (kazdy kolektor pobiera od drugiego pod ta sama
    sciezka), wiec heurystyka z samych `dirs` widziala tylko "pull" i rysowala
    `<`, nie `<>` (owner brief, runda 2 ekranow)."""
    dirs = set(dirs)
    peer = host_name(peer)
    # Relacja lokalna (local-backup --name, 2026-10-09): zrodlo i kopia na tym
    # hoscie -- ta sama strzalka co zadania lokalne na F2.
    if mode == "local":
        # przez _(): angielskie GUI na pve2 pokazywalo "lokalnie" w kolumnie Direction (2026-10-29)
        return _(u"lokalnie")
    # snaponly: migawki robione STAD na zrodle; nic tu nie przychodzi, wiec nie
    # strzalka pobrania (REV-20261017-152 runda 3).
    if mode == "snaponly" or (dirs and set(dirs) == {"snaponly"}):
        return u"→ %s" % (peer or "?")
    if "local" in dirs or not peer:
        return _(u"lokalnie") if dirs else "?"
    if mode == "sync":
        return u"%s ↔ %s" % (host, peer)
    if "pull" in dirs and "push" in dirs:
        return u"%s ↔ %s" % (host, peer)
    if "pull" in dirs:
        return u"%s → %s" % (peer, host)
    if "push" in dirs:
        return u"%s → %s" % (host, peer)
    # Relacja jeszcze bez linii crona (np. aktywacja nie doszla do konca): rekord zna tryb,
    # a relacja zakladana przez pakiet na kolektorze POBIERA (uwaga 7, 2026-10-08).
    if mode == "backup":
        return u"%s → %s" % (peer, host)
    return u"%s ? %s" % (host, peer)


# ---------------------------------------------------------------------------
# RAMKI
# ---------------------------------------------------------------------------
class Chars(object):
    """Zestaw znakow ramek. UTF-8 to przypadek projektowy, ASCII to wymaganie
    kontraktu (zasada 10): terminal bez UTF-8 dostaje +-|= i te same slowa."""

    def __init__(self, ascii_only):
        self.ascii = ascii_only
        if ascii_only:
            self.dh, self.dv, self.dtl, self.dtr, self.dbl, self.dbr = "=", "|", "+", "+", "+", "+"
            self.sh, self.sv, self.stl, self.str_, self.sbl, self.sbr = "-", "|", "+", "+", "+", "+"
            self.dash = "-"
            self.arrows = ARROWS_ASCII
            self.right, self.left, self.ell = "->", "<-", "..."
        else:
            self.dh, self.dv, self.dtl, self.dtr, self.dbl, self.dbr = u"═", u"║", u"╔", u"╗", u"╚", u"╝"
            self.sh, self.sv, self.stl, self.str_, self.sbl, self.sbr = u"─", u"│", u"┌", u"┐", u"└", u"┘"
            self.dash = u"─"
            self.arrows = ARROWS_UTF
            self.right, self.left, self.ell = u"→", u"←", u"…"


def fit(text, n, ch=None):
    """Dokladnie n znakow: dopelnij spacjami albo utnij z wielokropkiem."""
    text = u"%s" % (text if text is not None else "")
    if len(text) <= n:
        return text + " " * (n - len(text))
    if n <= 1:
        return text[:n]
    ell = (ch.ell if ch else "...")
    if n <= len(ell):
        return text[:n]
    return text[:n - len(ell)] + ell


def fit_left(text, n, ch=None):
    """Jak fit(), ale ucina od POCZATKU: sciezki datasetow roznia sie koncem."""
    text = u"%s" % (text if text is not None else "")
    if len(text) <= n:
        return text + " " * (n - len(text))
    ell = (ch.ell if ch else "...")
    if n <= len(ell):
        return text[-n:]
    return ell + text[-(n - len(ell)):]


def wrap(text, n):
    """Lamanie po slowach do n znakow; wciecie pierwszej linii jest zachowane i
    powtorzone w kolejnych, dlugie sciezki tna sie twardo."""
    text = u"%s" % text
    indent = len(text) - len(text.lstrip(" "))
    pad = " " * min(indent, max(0, n - 10))
    out, line = [], pad
    for word in text.strip().split(" "):
        room = n - len(pad)
        while len(word) > room:
            if line.strip():
                out.append(line)
            out.append(pad + word[:room])
            word = word[room:]
            line = pad
        if not line.strip():
            line = pad + word
        elif len(line) + 1 + len(word) <= n:
            line += " " + word
        else:
            out.append(line)
            line = pad + word
    if line.strip() or not out:
        out.append(line)
    return out


def box(ch, title, body, width, double=True, footer=""):
    """Ramka o pelnej szerokosci z tytulem w gornej krawedzi.

    `body` to linie WNETRZA; kazda jest przycinana/dopelniana do width-4, bo
    ramka zabiera po dwa znaki z kazdej strony (krawedz + spacja)."""
    if double:
        h, v, tl, tr, bl, br = ch.dh, ch.dv, ch.dtl, ch.dtr, ch.dbl, ch.dbr
    else:
        h, v, tl, tr, bl, br = ch.sh, ch.sv, ch.stl, ch.str_, ch.sbl, ch.sbr
    inner = width - 2
    out = []
    top = (h + " " + title + " ") if title else ""
    top = top[:inner]
    out.append(tl + top + h * (inner - len(top)) + tr)
    for line in body:
        out.append(v + " " + fit(line, inner - 2, ch) + " " + v)
    bot = (h + " " + footer + " ") if footer else ""
    bot = bot[:inner]
    out.append(bl + bot + h * (inner - len(bot)) + br)
    return out


# ---------------------------------------------------------------------------
# CZAS I LICZBY
# ---------------------------------------------------------------------------
def human_bytes(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "?"
    if n < 0:
        return "?"
    for unit in ("B", "KiB", "MiB", "GiB", "TiB", "PiB"):
        if n < 1024 or unit == "PiB":
            if unit == "B":
                return "%d B" % n
            return ("%.1f %s" % (n, unit)).replace(".", ",")
        n /= 1024.0
    return "?"


# JEDEN ZAPIS DATY W GUI (wlasciciel 2026-10-29: "preferuję jednak wszędzie w pakiecie YYYY.MM.DD,
# a na pewno w replikach, bo mogą być rzadko puszczane"). Rok zawsze, kropki; daty z czasownikow
# przez dshow(). Nazwy migawek i pliki dziennikow bez zmian (to dane, nie zapis daty GUI).
DT_FMT = "%Y.%m.%d %H:%M"


def fmt_when(epoch, now):
    """Data i godzina w zapisie GUI (DT_FMT)."""
    try:
        epoch = int(epoch)
    except (TypeError, ValueError):
        return "?"
    if epoch <= 0:
        return "?"
    return time.strftime(DT_FMT, time.localtime(epoch))


def fmt_when_short(epoch, now):
    """Jak fmt_when(): od 2026-10-29 jeden zapis daty w calym GUI (DT_FMT)."""
    return fmt_when(epoch, now)


def fmt_next_short(epoch, now):
    """Kolumna 'Nastepny' na F2 (R3-4, uwaga wlasciciela 2026-09-24, wersja 2
    po makiecie): dzis -- tylko godzina, jutro -- 'jutro HH:MM', w tygodniu --
    dwuliterowy dzien tygodnia (pn wt sr cz pt so nd), dalej -- 'DD.MM HH:MM'.
    Krotsze niz pelne fmt_when/fmt_full, bo kolumna ma stala szerokosc 11."""
    try:
        epoch = int(epoch)
    except (TypeError, ValueError):
        return "?"
    if epoch <= 0:
        return "?"
    # Od 2026-10-29 (wlasciciel: "YYYY.MM.DD wszędzie w pakiecie") pelna data, bez
    # "jutro" i dni tygodnia -- jeden zapis daty w calym GUI (DT_FMT).
    return time.strftime(DT_FMT, time.localtime(epoch))


def parse_last_at(s):
    """'last_at' z job-stats: 'YYYY-MM-DD HH:MM' albo (przyszlosciowo) epoka --
    epoka lub None, nigdy wyjatek (R3-4, sortowanie 'wg ostatniego')."""
    if s is None:
        return None
    try:
        return int(s)
    except (TypeError, ValueError):
        pass
    try:
        return int(time.mktime(time.strptime(str(s), "%Y-%m-%d %H:%M")))
    except (ValueError, OverflowError):
        return None


def last_run_epoch_for_row(data, row):
    """Ostatni bieg wiersza F2 wg dziennika, do sortowania 'wg ostatniego'
    (R3-4): dla wiersza zgrupowanego (x2, x9...) NAJSTARSZY z grupy -- to jest
    najgorszy widoczny przypadek, nie ten, ktory akurat trafil do g['srow']."""
    if data.failed("stats"):
        return None
    cands = []
    for jj in row.get("jobs") or []:
        clabel = job_cron_label(jj)
        srow, _vol = job_stats_for(data, jj, clabel)
        if srow:
            e = parse_last_at(srow.get("last_at"))
            if e is not None:
                cands.append(e)
    return min(cands) if cands else None


_ISO_DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}:\d{2}(?::\d{2})?))?")


def dshow(v):
    """Data z czasownika ('2026-10-29 09:20:13', '2026-10-29T09:20:13+00:00') w zapisie GUI
    (DT_FMT: '2026.10.29 09:20:13'); reszta napisu (np. strefa) bez zmian, inny tekst --
    bez zmian. Nazwy migawek nie przechodza tedy (to dane ZFS)."""
    if not isinstance(v, str):
        return v
    m = _ISO_DATE_RE.match(v)
    if not m:
        return v
    return u"%s.%s.%s" % m.group(1, 2, 3) + ((u" " + m.group(4)) if m.group(4) else u"") + v[m.end():]


def fmt_full(epoch):
    try:
        epoch = int(epoch)
    except (TypeError, ValueError):
        return "?"
    if epoch <= 0:
        return "?"
    return time.strftime(DT_FMT + ":%S", time.localtime(epoch))


def fmt_dur(sec):
    try:
        sec = int(sec)
    except (TypeError, ValueError):
        return "?"
    if sec < 0:
        return "?"
    if sec < 60:
        return "%d s" % sec
    if sec < 3600:
        return "%d min" % (sec // 60)
    if sec < 86400:
        return "%d h %02d min" % (sec // 3600, (sec % 3600) // 60)
    return "%d d %d h" % (sec // 86400, (sec % 86400) // 3600)


def hsecs(sec):
    """Jak human_secs w alert-digest.sh: 47s | 9m12s | 1h26m -- te same liczby
    co w mailu, w tym samym ksztalcie."""
    try:
        sec = int(sec)
    except (TypeError, ValueError):
        return "-"
    if sec < 0:
        return "-"
    if sec < 60:
        return "%ds" % sec
    if sec < 3600:
        return "%dm%02ds" % (sec // 60, sec % 60)
    return "%dh%02dm" % (sec // 3600, (sec % 3600) // 60)


def hbytes_short(n):
    """41.9G, 6.1M, 512K -- kompaktowo, do kolumny szerokiej na 6 znakow."""
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "-"
    if n < 0:
        return "-"
    for unit in ("B", "K", "M", "G", "T", "P"):
        if n < 1024 or unit == "P":
            if unit == "B":
                return "%dB" % n
            txt = "%.1f%s" % (n, unit)
            return txt if len(txt) <= 5 else "%.0f%s" % (n, unit)
        n /= 1024.0
    return "-"


def times_cell(last, avg, mx):
    """ostatni/sredni/maks w JEDNEJ komorce, jedna jednostka dobrana do maksimum,
    zeby zmiescic sie w 11 znakach przy 80 kolumnach: '60/72/127s', '2/5/9m',
    '1.2/1.5/2.0h'."""
    vals = []
    for v in (last, avg, mx):
        try:
            vals.append(int(v))
        except (TypeError, ValueError):
            vals.append(-1)
    if all(v < 0 for v in vals):
        return "-"
    top = max(vals)
    if top < 300:
        return "/".join("-" if v < 0 else "%d" % v for v in vals) + "s"
    if top < 3 * 3600:
        return "/".join("-" if v < 0 else "%d" % ((v + 30) // 60) for v in vals) + "m"
    return "/".join("-" if v < 0 else "%.1f" % (v / 3600.0) for v in vals) + "h"


def job_cron_label(j):
    """Etykieta zadania w cronie -- to, co zfs-job.sh dostaje w cudzyslowie --
    BEZ pierwszego slowa (hosta), bo tak liczy ja digest (pola od 5.)."""
    kind = j.get("section_kind", "")
    want = ("snapsend.sh", "snapget.sh") if kind == "dataset" else ("delsnaps.sh",)
    scope = j.get("scope", "")
    # The line quotes the scope OR the other end: a pull names its SOURCE
    # ("konto@host:dataset") and, for a mirror, no local path at all. Matching
    # on the scope alone gave every mirror job the label of the block's first
    # line -- on pve10 all 12 datasets of pve9-synchro showed the stats of
    # ct-201, and a refused pull of another dataset stayed "aktualne"
    # (measured 2026-10-08).
    ends = ['"%s"' % x for x in (scope, j.get("other_end") or "") if x]
    cands = []
    for ln in j.get("cron_lines") or []:
        if not any(w in ln for w in want):
            continue
        m = re.search(r'zfs-job\.sh "([^"]+)"', ln)
        if not m:
            continue
        cands.append((any(e in ln for e in ends), m.group(1)))
    if not cands:
        return ""
    cands.sort(key=lambda c: 0 if c[0] else 1)
    parts = cands[0][1].split(" ", 1)
    return parts[1] if len(parts) > 1 else parts[0]


def job_stats_for(data, j, label):
    """(wiersz z job-stats albo None, wolumen w bajtach albo None) dla zadania."""
    st = data.stats or {}
    row = None
    for x in st.get("jobs", []):
        if label and x.get("label") == label:
            row = x
            break
    vol = None
    if j.get("section_kind") == "dataset":
        src, dst = job_src_dst(j)
        fam = family_of(j)
        if dst and dst not in ("?", "-") and ":" not in dst:
            vol = 0
            for v in st.get("volume", []):
                d = v.get("dataset", "")
                if (d == dst or d.startswith(dst + "/")) and v.get("family", "") == fam:
                    vol += int(v.get("bytes") or 0)
    return row, vol


# Znaki NAZWY datasetu (lib-scope.sh pc_is_dataset): litery, cyfry, _ . - i ':'
# -- dwukropek jest legalny W SRODKU nazwy (REV-20261027-177, runda 2).
_DS_NAME_CH = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-:")


def _transport_prefix(text, colon):
    """Czy ':' na pozycji `colon` to separator transportu konto@host:ds?
    Tylko gdy slowo przed nim (od odstepu, cudzyslowu albo poczatku) ma '@' i nie
    ma '/': '@' NIE moze wystapic w nazwie datasetu (to separator migawki), wiec
    konto@host: nie jest zgadywaniem. Goly 'host:' wyglada jak pula z dwukropkiem
    ('x:pool/foo' to legalna nazwa, lib-scope.sh pc_is_dataset) -- nie odcinamy go
    (REV-20261027-177, runda 3); gdy tozsamosci nie da sie ustalic, panel pokazuje
    caly zakres."""
    i = colon
    while i > 0 and text[i - 1] not in " \t'\"([{,=<>":
        i -= 1
    word = text[i:colon]
    return "@" in word and "/" not in word and word[0] != "@" and all(c in _DS_NAME_CH or c in "@[]" for c in word)


def scope_dataset(scope):
    """Dataset z zakresu zadania: bez prefiksu transportu (konto@host:), ale z
    dwukropkiem, ktory nalezy do nazwy ('pool/foo:bar' zostaje cale)."""
    scope = scope or "?"
    c = scope.find(":")
    if c > 0 and _transport_prefix(scope, c):
        return scope[c + 1:]
    return scope


def text_names_dataset(text, ds):
    """Czy tekst bledu NAZYWA dataset ds -- cala nazwa, nie jej kawalek
    (REV-20261027-177: 'pool/vm-10' w 'pool/vm-100', 'data' w 'metadata',
    'pool/foo' w 'pool/foo:bar').
    Przed nazwa: poczatek, znak spoza nazwy (odstep, cudzyslow...), '/' (kopia
    pod baza celu: .../pve2/rpool/ROOT/pve-1) albo ':' separatora transportu
    (host:ds, konto@host:ds -- nie dwukropek w nazwie).
    Po nazwie: koniec, '@' (migawka), znak spoza nazwy, ':' albo '.' tylko gdy
    dalej NIE ma znaku nazwy ani '/' ("pool/x: busy", "pool/x."), nigdy '/' (dziecko)."""
    if not ds or not text:
        return False
    start = 0
    while True:
        i = text.find(ds, start)
        if i < 0:
            return False
        start = i + 1
        if i > 0:
            pc = text[i - 1]
            if pc == ":":
                if not _transport_prefix(text, i - 1):
                    continue
            elif pc in _DS_NAME_CH:
                continue
        j = i + len(ds)
        if j < len(text):
            nc = text[j]
            if nc == "/":
                continue
            if nc in ".:" and j + 1 < len(text) and (text[j + 1] in _DS_NAME_CH or text[j + 1] == "/"):
                continue
            if nc in _DS_NAME_CH and nc not in ".:":
                continue
        return True


def job_run_issue(data, j):
    """(blad, wyrzucenie) zadania z job-stats: blad = (rc, kiedy, tekst), gdy
    jego NAJNOWSZY bieg sie nie udal (rc nie 0 i nie 75 -- pominiecie przez
    blokade to nie blad); wyrzucenie = (kiedy, tekst) ostatniego biegu, ktory
    cos z kopii wyrzucil (P-0, "follows its source -- discarding")."""
    if data.failed("stats"):
        return None, None
    label = job_cron_label(j)
    srow, _ = job_stats_for(data, j, label)
    ev = {}
    for x in (data.stats or {}).get("events", []):
        if label and x.get("label") == label:
            ev = x
            break
    fail = None
    if srow and str(srow.get("last_rc")) not in ("0", "75", "None"):
        fail = (srow.get("last_rc"), dshow(srow.get("last_at") or "?"), ev.get("error") or "")
    disc = (dshow(ev.get("discard_at") or "?"), ev["discard"]) if ev.get("discard") else None
    return fail, disc


def fmt_ago(epoch, now):
    try:
        d = int(now) - int(epoch)
    except (TypeError, ValueError):
        return "?"
    if d < 0:
        d = 0
    return "%s temu" % fmt_dur(d)


def _cron_field(spec, lo, hi, names=None):
    """Zbior wartosci pola crona: *, */n, a-b, a-b/n, listy, nazwy dni/miesiecy."""
    vals = set()
    for part in spec.split(","):
        part = part.strip().lower()
        if not part:
            continue
        step = 1
        if "/" in part:
            part, s = part.split("/", 1)
            step = int(s)
        if part == "*":
            a, b = lo, hi
        elif "-" in part:
            a, b = part.split("-", 1)
            a = names.get(a, a) if names else a
            b = names.get(b, b) if names else b
            a, b = int(a), int(b)
        else:
            part = names.get(part, part) if names else part
            a = b = int(part)
        if a < lo or b > hi or a > b or step < 1:
            raise ValueError(spec)
        for v in range(a, b + 1, step):
            vals.add(v)
    return vals


_DOW = {"sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6}
_MON = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7,
        "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12}


def cron_next(spec, now):
    """Nastepne odpalenie linii crona po `now` (epoch, czas lokalny), albo None.

    Semantyka crona z vixie: gdy DZIEN MIESIACA i DZIEN TYGODNIA sa oba
    ograniczone, wystarczy jeden z nich. Kroki po dniach, nie po minutach, wiec
    zadanie miesieczne liczy sie w mikrosekundach, nie w sekundach."""
    try:
        f = spec.split()
        if len(f) != 5:
            return None
        mins = _cron_field(f[0], 0, 59)
        hrs = _cron_field(f[1], 0, 23)
        dom = _cron_field(f[2], 1, 31)
        mon = _cron_field(f[3], 1, 12, _MON)
        dow = set(v % 7 for v in _cron_field(f[4], 0, 7, _DOW))
    except (ValueError, KeyError):
        return None
    dom_star, dow_star = f[2].strip() == "*", f[4].strip() == "*"
    t = time.localtime(int(now) + 60)
    y, m, d, hh, mm = t.tm_year, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min
    import calendar
    for _day in range(0, 400):
        try:
            day_epoch = time.mktime((y, m, d, 0, 0, 0, 0, 0, -1))
        except (OverflowError, ValueError):
            return None
        lt = time.localtime(day_epoch)
        wd = (lt.tm_wday + 1) % 7   # python: pon=0; cron: nd=0
        if lt.tm_mon in mon:
            if dom_star and dow_star:
                day_ok = True
            elif dom_star:
                day_ok = wd in dow
            elif dow_star:
                day_ok = lt.tm_mday in dom
            else:
                day_ok = (lt.tm_mday in dom) or (wd in dow)
            if day_ok:
                for h in sorted(hrs):
                    if _day == 0 and h < hh:
                        continue
                    for mi in sorted(mins):
                        if _day == 0 and h == hh and mi < mm:
                            continue
                        try:
                            return int(time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, h, mi, 0, 0, 0, -1)))
                        except (OverflowError, ValueError):
                            return None
        # nastepny dzien
        d += 1
        if d > calendar.monthrange(y, m)[1]:
            d = 1
            m += 1
            if m > 12:
                m = 1
                y += 1
        hh, mm = 0, 0
    return None


# ---------------------------------------------------------------------------
# CZYTELNICY
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# SZABLONY SLOWAMI. Wlasciciel, 2026-09-14: lista szablonow ma mowic, co
# szablon ROBI, nie jak sie nazywa plik. Wszystko liczone z list-profiles
# --json: harmonogram szczebla tworzacego, licznik kazdego szczebla, mechanizm,
# ksztalt, zamrazanie, progi monitora. Zero wlasnej polityki -- same slowa.
# ---------------------------------------------------------------------------
TIER_WORDS = [("hourly", u"godz."), ("daily", u"dni"), ("weekly", u"tyg."), ("monthly", u"mies."), ("yearly", u"lat")]
TIER_ADJ = [("hourly", u"godzinowe"), ("daily", u"dobowe"), ("weekly", u"tygodniowe"), ("monthly", u"miesięczne"), ("yearly", u"roczne")]
DOW = [u"nd", u"pn", u"wt", u"śr", u"cz", u"pt", u"so"]
# Dni tygodnia: osobna lista skrótów angielskich, jeden wybór wg języka okien.
DOW_EN = [u"Sun", u"Mon", u"Tue", u"Wed", u"Thu", u"Fri", u"Sat"]


def dow_word(i):
    """<0 = niedziela> -> skrót dnia w języku okien."""
    return (DOW_EN if LANG_CAT else DOW)[i % 7]


def tier_unit(name, table=TIER_WORDS):
    for suf, w in table:
        if name.endswith(suf):
            return _(w)
    return name


def cron_words(spec):
    """5 pol crona -> slowa: 'co godzinę (:01)', 'co dobę 01:11', 'co tydzień nd 02:21',
    'co miesiąc 1. dnia 03:31'; reszta wraca jak jest."""
    f = (spec or "").split()
    if len(f) != 5:
        return spec or "?"
    mi, ho, dom, mon, dow = f
    if mi.startswith("*/") and mi[2:].isdigit() and ho == "*" and dom == "*" and mon == "*" and dow == "*":
        return _(u"co %s min") % mi[2:]
    if not mi.isdigit():
        return spec
    if ho == "*" and dom == "*" and mon == "*" and dow == "*":
        return _(u"co godzinę (:%02d)") % int(mi)
    if not ho.isdigit():
        return spec
    hm = "%02d:%02d" % (int(ho), int(mi))
    if dom == "*" and mon == "*" and dow == "*":
        return _(u"co dobę %s") % hm
    if dom == "*" and mon == "*" and dow.isdigit():
        return _(u"co tydzień %s %s") % (dow_word(int(dow)), hm)
    if dom == "*" and mon == "*" and re.match(r"^[0-7](-[0-7])?(,[0-7](-[0-7])?)*$", dow):
        days = u", ".join(u"-".join(dow_word(int(x)) for x in part.split("-")) for part in dow.split(","))
        return _(u"w dni %s %s") % (days, hm)
    if dom.isdigit() and mon == "*" and dow == "*":
        return _(u"co miesiąc %s. dnia %s") % (dom, hm)
    if dom.isdigit() and mon.isdigit():
        return _(u"co rok %s.%s %s") % (dom, mon, hm)
    return spec


def profile_words(p):
    """Slownik slow o szablonie: cadence, retention, mech, shape, quiesce, monitor."""
    tiers = p.get("tiers", [])
    creators = [t for t in tiers if t.get("send_schedule")]
    cad = ", ".join(cron_words(t["send_schedule"]) for t in creators) or "?"
    ret = []
    for t in tiers:
        if t.get("keep"):
            ret.append(u"%s %s" % (t["keep"], tier_unit(t.get("name", ""))))
        elif t.get("retain"):
            r = t["retain"].lstrip("-")
            n = r[1:] if r[:1].isalpha() else r
            ret.append(u"%s %s" % (n, tier_unit(t.get("name", ""))))
    mech = {"flat": _(u"N najnowszych"), "gfs": _(u"drabina GFS"), "age": _(u"wg wieku")}.get(p.get("mechanism", ""), p.get("mechanism") or "?")
    shape = {"one-family": _(u"jedna rodzina"), "family-per-tier": _(u"osobne migawki na każdy szczebel")}.get(p.get("shape", ""), p.get("shape") or "?")
    q = [tier_unit(t.get("name", ""), TIER_ADJ) for t in tiers if t.get("quiesce")]
    quiesce = (_(u"zamraża: %s") % ", ".join(q)) if q else _(u"bez zamrażania")
    mon = ""
    for t in tiers:
        if t.get("monitor_warn") or t.get("monitor_crit"):
            mon = u"monitor %s / %s" % (t.get("monitor_warn") or "?", t.get("monitor_crit") or "?")
            break
    return {"cadence": cad, "retention": _(u"trzyma %s") % (", ".join(ret) if ret else "?"), "mech": mech,
            "shape": shape, "quiesce": quiesce, "monitor": mon or _(u"bez progów")}


def run_verb(repo, args):
    """Uruchom czytelnik i oddaj sparsowany JSON, albo blad jako tekst.

    Status wyjscia NIE jest bledem sam z siebie: `monitor` zwraca 1/2/3 jako
    WERDYKT (to jego kontrakt), wiec liczy sie to, czy wyjscie da sie sparsowac."""
    cmd = [os.path.join(repo, "zfs-backup.sh")] + args
    # Limit (REV-20261023-172, ryzyko w odpowiedzi): czytnik bez limitu, który zawisł (ssh do
    # martwego hosta, zablokowany zfs), trzymał ekran jako nieaktualny do Ctrl-R albo restartu.
    # Najdłuższy czytnik na pve10 (monitor --json) to ~6 s. Po limicie ginie cała grupa
    # procesów (czytnik odpala ssh), a odświeżenie dostaje zwykły błąd źródła.
    limit = READER_TIMEOUT()
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             start_new_session=hasattr(os, "killpg"))
    except OSError as e:
        return None, _(u"nie udało się uruchomić %s: %s") % (" ".join(args), e)
    try:
        out, errb = p.communicate(timeout=limit)
    except subprocess.TimeoutExpired:
        try:
            if hasattr(os, "killpg"):
                os.killpg(p.pid, signal.SIGKILL)
            else:
                p.kill()
        except OSError:
            pass
        p.communicate()
        return None, _(u"%s nie odpowiedział w %d s -- przerwany") % (args[0], limit)
    try:
        return json.loads(out.decode("utf-8", "replace")), None
    except ValueError:
        err = errb.decode("utf-8", "replace").strip().splitlines()
        return None, (err[-1] if err else _(u"%s nie wydał poprawnego JSON-a") % args[0])


def READER_TIMEOUT():
    """Sekundy na jeden czytnik GUI: ZFS_TUI_READER_TIMEOUT, domyślnie 60."""
    try:
        v = int(os.environ.get("ZFS_TUI_READER_TIMEOUT", "60"))
        return v if v > 0 else 60
    except ValueError:
        return 60


def load_file(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh), None
    except (OSError, ValueError) as e:
        return None, u"%s: %s" % (os.path.basename(path), e)


class Data(object):
    """Wszystko, co ekrany czytaja. Kazde zrodlo ma swoj blad, bo pusty wynik i
    zrodlo, ktore nie odpowiedzialo, to dwa rozne stany i ekran mowi ktory."""

    def __init__(self):
        self.status = self.jobs = self.monitors = self.progress = self.replicas = self.stats = None
        self.errors = {}
        self.configs = {}     # show-config NAME --json, na zadanie
        self.profiles = None  # list-profiles --json --no-render, na zadanie (kreator)
        self.datasets = {}    # list-datasets [HOST] --json, na zadanie (kreator: listy zamiast pisania)
        self.checks = {}      # check-source HOST --json, na zadanie (kreator: diagnoza swiezego zrodla)
        self.ztree = {}       # zfs-tree --json ROOT..., na zadanie (F4 Kopie, lewy panel)
        self.zsnaps = {}      # zfs-snapshots --json DS, na zadanie (F4 Kopie, prawy panel)
        self.read_at = 0
        self.host_ip = None   # R3-1: adres IP hosta do paska tytulu; None = nieznany/offline
        self.guards = None    # stan strażników hosta (U35/U50) do paska tytułu
        self.pending = set()  # czytniki drugiego etapu, ktore jeszcze nie odpowiedzialy (start)

    def failed(self, key):
        return self.errors.get(key)


def resolve_host_ip(files):
    """R3-1: IP hosta do paska tytulu. Testy/offline daja go przez --host-ip
    (`files["host_ip"]`); na zywo -- adres trasy domyslnej (`ip -4 route get`),
    bo to jest adres, pod ktorym host naprawde odpowiada, a nie pierwszy
    interfejs z listy. Nigdy nie wiesza ekranu: timeout krotki, brak polecenia
    albo bledny wynik = brak IP, nie wyjatek."""
    if files.get("host_ip"):
        return files["host_ip"]
    if files.get("offline"):
        return None
    try:
        p = subprocess.run(["ip", "-4", "route", "get", "1.1.1.1"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=2)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    m = re.search(r'\bsrc\s+(\S+)', p.stdout.decode("utf-8", "replace"))
    return m.group(1) if m else None


def collect(repo, files, only=None):
    """Czytaj z plikow (testy, podglad) albo z czasownikow. `only` = jedno zrodlo."""
    data = files.get("_data") or Data()
    files["_data"] = data
    plan = [("status", ["status", "--json"]), ("jobs", ["list-jobs", "--json"]),
            ("monitors", ["monitor", "--json"]), ("progress", ["progress", "--json"]),
            ("replicas", ["list-replicas", "--json"]), ("stats", ["job-stats", "--json", "--vol-cache=300", "--runs=%d" % PRZ_RUNS_H])]
    # RÓWNOLEGLE (P2, właściciel 2026-10-15: powrót z okna do GUI > 5 s). Pełne odświeżenie
    # zostaje (decyzja 2026-10-09: powrót zawsze odświeża), ale sześć czasowników tylko do
    # odczytu szło PO KOLEI -- zmierzone na pve10: list-jobs 6,0 s + monitor 5,6 s +
    # job-stats 2,6 s + reszta < 0,5 s. Razem trwa tyle, co najwolniejszy.
    if isinstance(only, str):
        only = (only,)
    want = [(key, args) for key, args in plan if only is None or key in only]
    live = [(key, args) for key, args in want if not files.get(key) and not files.get("offline")]
    got = {}
    if len(live) > 1:
        import threading
        def _one(k, a):
            got[k] = run_verb(repo, a)
        ths = [threading.Thread(target=_one, args=(k, a)) for k, a in live]
        for t in ths:
            t.start()
        for t in ths:
            t.join()
    for key, args in want:
        if files.get(key):
            doc, err = load_file(files[key])
        elif files.get("offline"):
            doc, err = None, None
        elif key in got:
            doc, err = got[key]
        else:
            doc, err = run_verb(repo, args)
        setattr(data, key, doc)
        data.pending.discard(key)
        if key == "status":
            note_relation_names(doc)
        if err:
            data.errors[key] = err
        else:
            data.errors.pop(key, None)
    data.host_ip = resolve_host_ip(files)
    data.guards = guard_states()
    data.read_at = int(time.time())
    return data


def load_profiles(repo, files, data):
    """Lista szablonow do kreatora. --no-render: 0,8 s zamiast 8 s na pve10
    (16 profili); `valid`/`families` nie sa potrzebne do WYBORU -- profil
    sprawdza add-client dla tego jednego, ktory zostal wybrany."""
    if data.profiles is not None:
        return data.profiles, data.errors.get("profiles")
    if files.get("profiles"):
        doc, err = load_file(files["profiles"])
    elif files.get("offline"):
        doc, err = None, None
    else:
        doc, err = run_verb(repo, ["list-profiles", "--json", "--no-render"])
    # Ukryty szablon relacji (relacja-<NAZWA>, P4 2026-10-09) nie jest szablonem do wyboru:
    # F5 go nie pokazuje (zmienia go "Zmien relacje -> Harmonogram i retencja kopii w celu i źródle").
    data.profiles = [p for p in (doc or {}).get("profiles", []) if not p.get("hidden")]
    if err:
        data.errors["profiles"] = err
    return data.profiles, err


def load_datasets(repo, files, data, host="", port=""):
    """Lista datasetow: tutaj (host pusty) albo u peera (ssh kluczem roota).
    Wlasciciel, 2026-09-14: 'albo wpisuje recznie, albo dostaje liste i wybiera'.
    Blad (peer nie wpuszcza, brak w known_hosts) wraca jako tekst -- pole dalej
    przyjmuje pisanie."""
    key = "%s:%s" % (host, port)
    if key in data.datasets:
        return data.datasets[key]
    fx = files.get("datasets_remote" if host else "datasets_local")
    if fx:
        doc, err = load_file(fx)
    elif files.get("offline"):
        doc, err = None, _(u"tryb offline: list-datasets nie uruchomiono")
    else:
        args = ["list-datasets"] + ([host] if host else []) + (["--port=%s" % port] if port else []) + ["--json"]
        doc, err = run_verb(repo, args)
    data.datasets[key] = ((doc or {}).get("datasets", []), err)
    return data.datasets[key]


_ZTREE_LOCK = None


def load_ztree(repo, files, data, roots):
    """zfs-tree --json ROOT... (F4 Kopie): datasety pod korzeniami kopii, z liczba migawek.
    Jeden naraz (blokada): wczytanie w tle po odczycie (prefetch_kopie) i F4 nie pytaja ZFS
    dwa razy o to samo -- F4 czeka na tlo i bierze jego wynik."""
    global _ZTREE_LOCK
    if _ZTREE_LOCK is None:
        import threading
        _ZTREE_LOCK = threading.Lock()
    key = tuple(roots)
    with _ZTREE_LOCK:
        return _load_ztree_locked(repo, files, data, roots, key)


def _load_ztree_locked(repo, files, data, roots, key):
    if key in data.ztree:
        return data.ztree[key]
    if files.get("zfs_tree"):
        doc, err = load_file(files["zfs_tree"])
    elif files.get("offline"):
        doc, err = None, _(u"tryb offline: zfs-tree nie uruchomiono")
    else:
        doc, err = run_verb(repo, ["zfs-tree", "--json"] + list(roots))
    data.ztree[key] = ((doc or {}).get("datasets", []), err)
    return data.ztree[key]


def load_zsnaps(repo, files, data, ds):
    """zfs-snapshots --json DS (F4 Kopie, prawy panel): migawki jak `zfs list -t snapshot`."""
    if ds in data.zsnaps:
        return data.zsnaps[ds]
    if files.get("zfs_snapshots"):
        all_, err = load_file(files["zfs_snapshots"])
        doc = {"snapshots": ((all_ or {}).get("by_dataset") or {}).get(ds, [])}
    elif files.get("offline"):
        doc, err = None, _(u"tryb offline: zfs-snapshots nie uruchomiono")
    else:
        doc, err = run_verb(repo, ["zfs-snapshots", "--json", ds])
    data.zsnaps[ds] = (doc, err)
    return data.zsnaps[ds]


def load_check(repo, files, data, host, port=""):
    """check-source HOST --json: trzy fakty (SSH, ZFS, pakiet). Host, ktory
    odmawia, to fakt w JSON-ie, nie blad czytelnika."""
    key = "%s:%s" % (host, port)
    if key in data.checks:
        return data.checks[key]
    if files.get("check_source"):
        doc, err = load_file(files["check_source"])
    elif files.get("offline"):
        doc, err = None, _(u"tryb offline: check-source nie uruchomiono")
    else:
        doc, err = run_verb(repo, ["check-source", host] + (["--port=%s" % port] if port else []) + ["--json"])
    data.checks[key] = (doc, err)
    return data.checks[key]


def load_config(repo, files, data, name):
    if name in data.configs:
        return data.configs[name]
    if files.get("config"):
        doc, err = load_file(files["config"])
    elif files.get("offline"):
        doc, err = None, None
    else:
        doc, err = run_verb(repo, ["show-config", name, "--json"])
    data.configs[name] = (doc, err)
    return data.configs[name]


# ---------------------------------------------------------------------------
# MODEL: co znacza rekordy
# ---------------------------------------------------------------------------
# RODZAJE ZADAN, KTORE "ROBIA" RELACJE: transfer z sekcji [dataset:] i migawki
# relacji `snaponly` (sekcja [snaponly:], REV-20261017-152 runda 3). Te drugie
# niczego nie kopiuja, ale to one wyznaczaja nastepny bieg, bledy biegu i rodzine.
SEND_KINDS = ("dataset", "snaponly")


def family_of(job):
    """Transfer stempluje `prefix` (`automated_daily_`), prune dopasowuje
    `pattern` (`automated_daily`) -- ta sama rodzina. Jedna pisownia: bez konca."""
    return (job.get("pattern") or job.get("prefix", "")).rstrip("_")


def mark_pending(rows, data):
    """Do drugiego etapu startu monitor jeszcze nie odpowiedzial: wiersz bez linii monitora
    mowi "sprawdzam…", nie "bez monitora" (pve10, 2026-10-29: F3 przez 10 s mowilo, ze nikt
    nie pilnuje zadnej relacji)."""
    if "monitors" in getattr(data, "pending", ()):
        for r in rows:
            if r.get("verdict") == "BEZ MONITORA" and r.get("vword") == _(VERDICTS["BEZ MONITORA"][0]):
                r["verdict"], r["vword"] = "SPRAWDZAM", _(VERDICTS["SPRAWDZAM"][0])
    return rows


def worst(verdicts):
    for v in VERDICT_ORDER:
        if v in verdicts:
            return v
    return "BEZ MONITORA"


_DS_LINE = re.compile(r"^(OK|WARNING|CRITICAL|UNKNOWN) dataset=(\S+)(.*)$")


def dataset_verdict(m, names):
    """U26 (wlasciciel 2026-10-19, zrzut: lustro po F7 dalej "stare" w kazdym wierszu):
    JEDEN monitor relacji pilnuje wielu datasetow, a jego werdykt to najgorszy z nich --
    przylozony do kazdej pary malowal 14 par na "stare" przez jeden dataset bez migawek.
    check-snap-age pisze linie na KAZDY dataset ("CRITICAL dataset=X ..."); para bierze
    najgorsza z linii swojego datasetu (i jego dzieci przy -R).
    check-snap-age pisze linie TYLKO dla datasetow nie-OK (OK -- tylko z -v; zmierzone na
    pve10 2026-10-20: CRITICAL i jedna linia hdd/db przy trzech datasetach). Wiec: monitor z
    liniami datasetow, a ten dataset bez linii = OK. Wynik bez zadnej linii datasetu (np.
    blad polaczenia) = None -- wtedy werdykt calego monitora."""
    order = {v: i for i, v in enumerate(VERDICT_ORDER)}
    best, any_line = None, False
    for ln in (m.get("reason") or "").splitlines():
        mm = _DS_LINE.match(ln.strip())
        if not mm:
            continue
        any_line = True
        ds = mm.group(2).split(":", 1)[-1]
        if any(n and (ds == n or ds.startswith(n + "/")) for n in names):
            if best is None or order.get(mm.group(1), 99) < order.get(best[0], 99):
                best = (mm.group(1), ln.strip())
    if best is None and any_line:
        return ("OK", "")
    return best


def verdict_for_job(job, monitors):
    """Werdykt dla ZADANIA: po zakresie i rodzinie, a dla pobrania po etykiecie
    (monitor pilnuje lokalnego CELU, a zakres pull to zdalne ZRODLO). Monitor wielu
    datasetow: werdykt TEGO datasetu z jego linii (dataset_verdict), nie najgorszy."""
    scope, fam = job.get("scope", ""), family_of(job)
    names = [scope] + [x for x in job_src_dst(job) if x and x not in ("?", "-") and ":" not in x]

    def pick(m):
        if len(m.get("datasets", [])) > 1 or m.get("recursive"):
            dv = dataset_verdict(m, names)
            if dv:
                return dv
        return m.get("verdict", "UNKNOWN"), m.get("reason", "")
    for m in monitors:
        if scope in m.get("datasets", []) and m.get("pattern", "").rstrip("_") == fam:
            return pick(m)
    label = job.get("label", "")
    if label:
        for m in monitors:
            if m.get("label", "") == label and m.get("pattern", "").rstrip("_") == fam:
                return pick(m)
    return "BEZ MONITORA", ""


# RODZINA PO OBU STRONACH BEZ KONCOWEGO '_' (family_of tak ja zapisuje): monitor
# relacji snaponly ma wzorzec z '_' (pve9_automated_hourly_), wiec dokladne
# porownanie dawalo "bez monitora" przy dzialajacym monitorze (pve9, 2026-10-18).
def monitors_for_job(job, monitors):
    """Jak verdict_for_job(), ale odzyskuje SAME LINIE monitora (nie tylko
    werdykt) -- panel F2 potrzebuje straznika (harmonogram, konto) i progow, a
    nie tylko slowa. Ta sama reguła dopasowania: zakres+rodzina, a dla
    pobrania (zakres zdalny) etykieta+rodzina."""
    scope, fam = job.get("scope", ""), family_of(job)
    out = [m for m in monitors if scope in m.get("datasets", []) and m.get("pattern", "").rstrip("_") == fam]
    if out:
        return out
    label = job.get("label", "")
    if label:
        return [m for m in monitors if m.get("label", "") == label and m.get("pattern", "").rstrip("_") == fam]
    return []


def transfers_for(progress, label):
    jobs = [j for j in (progress or {}).get("jobs", []) if j.get("label", "") == label]
    jobs.sort(key=lambda j: int(j.get("started_epoch") or 0), reverse=True)
    return jobs


def transfer_word(t, now):
    st = t.get("state", "")
    if st == "running":
        upd = int(t.get("updated_epoch") or 0)
        if now - upd > 60:
            return _("w toku"), _(u"bez aktualizacji od %s") % fmt_dur(now - upd)
        return _("w toku"), ""
    return _(TRANSFER_STATES.get(st, (st or "?", 0))[0]), ""


STATE_PL = {"active": u"działa", "removed": u"usunięta", "pending_enroll": u"zakładana", "seeding": u"1. kopia",
            "seed_complete": u"po 1. kopii", "endpoint_verified": u"sprawdzona"}


def pl_relacje(n):
    """1 relacja, 2-4 relacje, 5+ relacji (12-14 relacji)."""
    if n == 1:
        return _(u"1 relacja")
    if n % 10 in (2, 3, 4) and n % 100 not in (12, 13, 14):
        return _(u"%d relacje") % n
    return _(u"%d relacji") % n


def profile_word(name, rel_name=None):
    """Szablon relacji słowami: ukryty szablon relacji (relacja-<NAZWA>, P4) to
    'własne ustawienia (tabela)', nie nazwa pliku."""
    if not name:
        return "?"
    # X19 (wlasciciel 2026-10-14): szczeble zyja w CONFIGU relacji; nazwa szablonu mowi
    # tylko, z czego relacja POWSTALA -- ukryty szablon relacji to "wlasne ustawienia".
    if rel_name and name.startswith("relacja-%s" % rel_name):
        return _(u"własne ustawienia relacji")
    return name


def state_word(rel):
    s = rel.get("state", "?")
    s = _(STATE_PL.get(s, s))
    if rel.get("disabled"):
        s += _(u" WYŁĄCZONA")
    elif rel.get("paused_local"):
        s += _(" PAUZA")
    return s


def next_step(rel):
    """Co dalej z relacja, ktora nie jest aktywna -- slowami CLI, bo to jest to,
    co operator wpisze. Maszyna stanow z `zfs-backup.sh` (usage):
    pending_enroll -> seeding -> seed_complete -> endpoint_verified -> active."""
    s = rel.get("state", "")
    return {"pending_enroll": "activate NAME", "seeding": "seed NAME",
            "seed_complete": "activate NAME", "endpoint_verified": "activate-client NAME",
            "removed": "--"}.get(s, "")


# WYŁĄCZ / WŁĄCZ (właściciel 2026-10-18: "tak, ale z wyjaśnieniem, co to implikuje i
# jakie kroki admin musi zrobić, żeby włączyć z powrotem").
def disable_note(rel):
    peer = host_name(rel_addr(rel)) or "?"
    return [_(u"WYŁĄCZENIE = pauza tutaj ORAZ zamek na źródle %s:") % peer,
            _(u"  źródło ODRZUCA klucz tego kolektora, także wsadowym komendom."),
            _(u"  Kopie przestają powstawać, monitor nie alarmuje; dane po obu stronach"),
            _(u"  ZOSTAJĄ."),
            _(u"Kiedy: kolektor może być przejęty albo źródło nie może go zautoryzować"),
            _(u"  czasu, aż świadomie go włączysz. Na zwykłą przerwę wystarczy Pauza (t w poprzednim oknie)."),
            "",
            _(u"Włączenie z powrotem: F8 na tej relacji -> Włącz (enable-client)."),
            _(u"  Źródło musi być dostępne przez sieć; jeśli nie jest, polecenie pokaże, na czym"),
            _(u"  stanęło, i można je bezpiecznie powtórzyć. Potem następny bieg"),
            u"  dogania przyrostowo.",
            _(u"Ograniczenie: kluczem tej relacji da się zdjąć blokadę (źródło to loguje)"),
            _(u"  -- to blokada na przypadek zapomnianego klucza, nie na intruza.")]


ENABLE_NOTE = [u"Relacja jest WYŁĄCZONA: pauza tutaj i zamek na źródle.",
               u"Włącz zdejmuje zamek na źródle (musi być osiągalne), potem pauzę",
               u"tutaj; najbliższe zaplanowane uruchomienie dośle tylko brakujące zmiany. Gdy źródło jest",
               u"niedostępne, nic się nie zmienia i można powtórzyć."]


def finish_argv(rel):
    """Nastepny krok relacji, ktora nie jest aktywna (bez sciezki do programu):
    '1. kopia' (seeding) -> seed, reszta cyklu -> activate (wznawialne, samo
    sprawdza zrodlo i instaluje). Aktywna albo usunieta -- nic."""
    n = rel.get("name")
    s = rel.get("state", "")
    if not n or s in ("active", "removed", ""):
        return []
    if s == "seeding":
        return ["seed", n, "--yes"]
    return ["activate", n, "--yes"]


def verbs_for(rel):
    """Komendy CLI, ktore maja sens w tym stanie. NAZWANE, nie wykonywane.
    Zasada 4 dokumentu decyzji: widok pokazuje te akcje, ktore CLI dopuszcza."""
    n = rel.get("name", "NAME")
    s = rel.get("state", "")
    out = ["zfs-backup.sh show-config %s" % n, "zfs-backup.sh export-relation %s" % n]
    if s == "active":
        if rel.get("paused_local"):
            out.insert(0, "zfs-backup.sh resume-client %s" % n)
        else:
            out.insert(0, _(u"zfs-backup.sh pause-client %s [--reason=TEKST]") % n)
        if rel.get("peer_host"):
            out.append("zfs-backup.sh set-bandwidth --peer=%s --bandwidth=RATE" % rel["peer_host"])
        if rel.get("endpoint_diverged"):
            out.insert(0, "zfs-backup.sh verify-endpoint %s ; activate-client %s" % (n, n))
    elif s in ("pending_enroll", "seeding", "seed_complete", "endpoint_verified"):
        out.insert(0, _("zfs-backup.sh activate %s   (wznawialne; dokończy cykl)") % n)
    if s != "removed":
        out.append("zfs-backup.sh remove-client %s" % n)
    return out


def ch_arrow(job):
    """Kierunek zadania bez rekordu, w UTF-8; tryb ASCII odogonkowuje strzalki
    razem z reszta ekranu (deaccent)."""
    return _(ARROWS_UTF.get(job.get("direction", ""), "?")).format(peer=host_name(job.get("peer")) or "?")


def rel_type(peer, dirs, mode=None, target=None):
    """backup (jedna strona), lustro (obie), lokalna, other.

    "lustro", nie "synchro" (wlasciciel 2026-10-08: "zmien synchro na lustro w
    GUI"): dane ida w JEDNA strone, od dawcy do kolektora; od backupu rozni sie
    retencja (kopia trzyma to, co zrodlo) i miejscem (ta sama sciezka, bez bazy). W konfiguracji tryb nadal
    nazywa sie `sync` (--mode=sync); zmienia sie tylko to, co widac na ekranie.

    ZAPISANY TRYB WYGRYWA z odczytem linii crona. Relacja synchro ma wszystkie
    swoje linie w jedna strone (kolektor ciagnie do siebie, pod TA SAMA sciezke),
    wiec heurystyka "pull i push = synchro" nazywala ja backupem -- ekran F3
    pokazywal `pve9-synchro | backup`, czyli nieprawde o tym, co ta relacja robi
    (zmierzone na pve10, 2026-09-21). Rekord zna odpowiedz i `status --json` ja
    teraz podaje; heurystyka zostaje dla ZADAN, ktore rekordu nie maja.
    """
    if mode:
        # NAZWY (wlasciciel 2026-10-18): typ mowi CO, kierunek GDZIE. "Same migawki"
        # to relacja lokalna bez celu, wiec "lokalna" nie odroznialo jej od kopii.
        if mode == "local":
            return _(u"kopia lokalna") if target else _(u"migawki lokalne")
        return {"sync": _("lustro"), "snaponly": _(u"migawki zdalne")}.get(mode, mode)
    dirs = set(dirs)
    if "pull" in dirs and "push" in dirs:
        return _("lustro")
    if "pull" in dirs or "push" in dirs:
        return "backup"
    if "local" in dirs:
        return _(u"kopia lokalna")
    if "snaponly" in dirs:
        return _(u"migawki zdalne")
    return "backup" if peer and not dirs else "other"


def rel_stats(data, jobs):
    """Suma po zadaniach wysylki: biegi, bledy, czas o/s/m, wolumen (job-stats)."""
    sends = [j for j in jobs if j.get("section_kind") in SEND_KINDS]
    out = {"runs": 0, "fails": 0, "last": -1, "avg": -1, "max": -1, "vol": None, "sends": len(sends)}
    if data.failed("stats") or not sends:
        return out
    avg_w, seen = 0.0, set()
    for j in sends:
        srow, v = job_stats_for(data, j, job_cron_label(j))
        if v is not None:
            out["vol"] = (out["vol"] or 0) + v
        if not srow or id(srow) in seen:
            continue
        seen.add(id(srow))
        r = int(srow.get("runs") or 0)
        out["runs"] += r
        out["fails"] += int(srow.get("failures") or 0)
        avg_w += float(srow.get("avg_s") or 0) * r
        out["last"] = max(out["last"], int(srow.get("last_s") if srow.get("last_s") is not None else -1))
        out["max"] = max(out["max"], int(srow.get("max_s") if srow.get("max_s") is not None else -1))
    if out["runs"]:
        out["avg"] = int(round(avg_w / out["runs"]))
    return out


def build_relations(data, now):
    """Wiersze ekranu glownego: RELACJA (para hostow), nie zadanie.

    Wlasciciel, 2026-09-08: wiersz ma byc relacja. Rekord relacji jest w
    `status`, jej swiezosc w `monitor` (po etykiecie), ostatni bieg w `progress`
    (po etykiecie), nastepny bieg z harmonogramu sekcji `list-jobs` (po
    etykiecie) -- cztery czytelniki, jeden wiersz."""
    rows = []
    rels = (data.status or {}).get("relations", [])
    monitors = (data.monitors or {}).get("monitors", [])
    jobs = (data.jobs or {}).get("jobs", [])
    for rel in rels:
        name = rel.get("name", "")
        mons = [m for m in monitors if m.get("label", "") == name]
        verdict = worst([m.get("verdict", "UNKNOWN") for m in mons]) if mons else "BEZ MONITORA"
        if rel.get("state") != "active" and not mons:
            vword = "--"
        else:
            vword = _(VERDICTS.get(verdict, (verdict, 0))[0])
        reasons = [m.get("reason", "") for m in mons if m.get("reason")]
        trs = transfers_for(data.progress, name)
        last = trs[0] if trs else None
        if last:
            w, note = transfer_word(last, now)
            fin = int(last.get("finished_epoch") or last.get("updated_epoch") or 0)
            st = int(last.get("started_epoch") or 0)
            if last.get("state") == "running":
                last_txt = "%s %s" % (w, fmt_when(st, now))
            else:
                last_txt = "%s %s %s" % (w, fmt_when(fin, now), fmt_dur(fin - st) if fin and st else "")
        else:
            last_txt = _("brak zapisu")
        my_jobs = [j for j in jobs if j.get("label", "") == name]
        sends = [j for j in my_jobs if j.get("section_kind") in SEND_KINDS]
        nxt_epoch = None
        for j in sends:
            e = cron_next(j.get("schedule", ""), now)
            if e and (nxt_epoch is None or e < nxt_epoch):
                nxt_epoch = e
        if rel.get("paused_local"):
            nxt = _("-- pauza --")
        elif rel.get("state") != "active":
            nxt = next_step(rel).replace("NAME", name) or "?"
        elif nxt_epoch:
            nxt = fmt_when(nxt_epoch, now)
        elif not my_jobs:
            nxt = _("brak linii w cronie")
        else:
            nxt = "?"
        host = (data.jobs or {}).get("host") or "?"
        dirs = [x.get("direction", "") for x in my_jobs if x.get("section_kind") in SEND_KINDS]
        st = rel_stats(data, my_jobs)
        # Relacja, w ktorej ostatni bieg ktoregos zadania sie nie udal, nie jest
        # "aktualne" (2026-10-08) -- ten sam fakt, co wiersz "błąd biegu" na F2.
        if rel.get("state") == "active":
            for j in sends:
                fail, _disc = job_run_issue(data, j)
                if fail:
                    verdict = worst([verdict, "BLAD"])
                    vword = _(VERDICTS[verdict][0])
                    reasons.append(_(u"%s: ostatni bieg %s rc=%s: %s") % (
                        (j.get("scope") or "?").split(":")[-1], fail[1], fail[0], fail[2] or _(u"zobacz cron.log")))
        rows.append({
            "kind": "relation", "name": name, "rel": rel, "state": state_word(rel),
            "dir": direction_of(host, rel_addr(rel), dirs, rel.get("mode")),
            "typ": rel_type(rel.get("peer_host"), dirs, rel.get("mode"), rel.get("client_target")), "stats": st,
            "gb": "?" if data.failed("stats") else (hbytes_short(st["vol"]) if st["vol"] is not None else "-"),
            "verdict": verdict, "vword": vword, "reasons": reasons, "monitors": mons,
            "last": last, "last_txt": last_txt.strip(), "transfers": trs,
            "jobs": my_jobs, "next_epoch": nxt_epoch, "next": nxt,
        })
    # ZADANIA BEZ RELACJI: sekcje configu, ktorych nie opisuje zaden rekord (np.
    # kopie lokalne). CLI je rozroznia, wiec ekran ich nie chowa.
    rel_names = {r["name"] for r in rows}
    seen = set()
    for j in jobs:
        if j.get("label", "") in rel_names or j.get("section_kind") != "dataset":
            continue
        key = (j.get("scope", ""), j.get("direction", ""))
        if key in seen:
            continue
        seen.add(key)
        v, reason = verdict_for_job(j, monitors)
        nxt_epoch = cron_next(j.get("schedule", ""), now)
        jobs_here = [x for x in jobs if x.get("scope") == j.get("scope")]
        st = rel_stats(data, jobs_here)
        rows.append({
            "kind": "job", "name": j.get("scope", ""), "rel": None,
            "dir": direction_of((data.jobs or {}).get("host") or "?", j.get("peer") or "", [j.get("direction", "")]),
            "typ": rel_type(j.get("peer"), [j.get("direction", "")]), "stats": st,
            "gb": "?" if data.failed("stats") else (hbytes_short(st["vol"]) if st["vol"] is not None else "-"),
            "state": _("bez rekordu %s") % ch_arrow(j),
            "verdict": v, "vword": _(VERDICTS.get(v, (v, 0))[0]), "reasons": [reason] if reason else [],
            "monitors": [], "last": None, "last_txt": "--",
            "transfers": [], "jobs": [x for x in jobs if x.get("scope") == j.get("scope")],
            "next_epoch": nxt_epoch, "next": fmt_when(nxt_epoch, now) if nxt_epoch else "?",
            "job": j,
        })
    # BLOK, KTOREGO NIE DA SIE WYJASNIC, JEST WIERSZEM -- nie przypisem. Te linie
    # CHODZA; ukrycie ich to ta sama pusta ramka, przed ktora powstal list-jobs.
    for u in (data.jobs or {}).get("unreadable", []):
        rows.append({
            "kind": "unreadable", "name": _("konto %s") % u.get("account", "?"), "rel": None, "dir": "?",
            "typ": "?", "gb": "?", "stats": None,
            "state": "nieczytelny", "verdict": "UNKNOWN", "vword": _("nie odpowiada"),
            "reasons": [u.get("error", "")], "monitors": [], "last": None,
            "last_txt": _("%s linii w cronie") % u.get("lines_in_block", "?"), "transfers": [],
            "jobs": [], "next_epoch": None, "next": "?", "u": u,
        })
    # Usuniete rekordy na koncu: sa faktem, ale nie robota.
    rows.sort(key=lambda r: 1 if (r.get("rel") or {}).get("state") == "removed" else 0)
    return rows


def job_src_dst(j):
    """(źródło, cel) zadania. list-jobs daje `scope` i `other_end`, a KIERUNEK
    mówi, które jest którym: pobranie -- źródło zdalne, cel to lądowisko tutaj;
    wysyłka i kopia lokalna -- odwrotnie; porządki -- tylko cel (co przycinają)."""
    d = j.get("direction", "")
    scope, other = j.get("scope", "") or "?", j.get("other_end", "") or ""
    if d == "pull":
        return other or "?", scope
    if d in ("push", "local"):
        return scope, other or "?"
    if d == "prune":
        return "-", scope
    if d == "snaponly":
        return scope, _(u"bez kopii")
    return scope, other or "-"


KEEP_UNITS = {"H": u"godz.", "D": u"dni", "W": u"tyg.", "M": u"mies.", "Y": u"lat"}


def job_is_mirror(j):
    """-M w WLASNEJ linii pobrania tego zadania: synchro jako lustro (wlasciciel
    2026-10-06). Cel trzyma wtedy to, co zrodlo -- bez wlasnej retencji, wiec
    'Trzyma' z szablonu bylaby nieprawda."""
    tier = j.get("tier") or ""
    scope = j.get("scope") or "\0"
    for cl in j.get("cron_lines") or []:
        if "snapget.sh" in cl and tier in cl and scope in cl:
            return " -M " in cl
    return False


def keep_cell(ret):
    """Kolumna 'Trzyma' (R4-4): '-H24' -> '24 godz.', '-D7' -> '7 dni'. Sama
    liczba bylaby klamstwem: drabina GFS przycina rodzine automated_hourly
    takze szczeblem '-D7' (fikstura pve10) -- "7" przy "automated_hourly"
    czytaloby sie jak 7 godzinowych. Goly licznik (keep = 7) zostaje liczba."""
    out = []
    for t in (ret or "").split():
        t = t.lstrip("-")
        m = re.match(r"^([HDWMY])(\d+)$", t)
        if m:
            out.append(u"%s %s" % (m.group(2), _(KEEP_UNITS[m.group(1)])))
        elif t:
            out.append(t)
    return " ".join(out) or "-"


def prefix_cell(j):
    """Kolumna 'Prefiks' (R4-4): rodzina migawek tak, jak ja widac w `zfs list`
    (automated_hourly), nie nazwa szczebla ('hourly' nie mowi o czestotliwosci,
    tylko o nazwie -- pytanie wlasciciela 2026-09-24). Wzorzec '-' (pasywny,
    kazda migawka) i brak rodziny to '-'."""
    fam = family_of(j)
    return fam if fam and fam != "-" else "-"


def build_jobs(data, now):
    """Wiersze ekranu ZADANIA: jedno zadanie z crona (sekcja wysylki albo
    porzadkow), z relacja i kierunkiem. To jest to, co host naprawde robi."""
    items = []
    monitors = (data.monitors or {}).get("monitors", [])
    host = (data.jobs or {}).get("host") or "?"
    rels_by_name = {r.get("name"): r for r in (data.status or {}).get("relations", [])}
    # porzadki, ktore JUZ maja wlasna sekcje [prune:] -- ich linii zaszytej w sekcji
    # [dataset:] nie pokazujemy drugi raz (relacja, harmonogram, retencja)
    prune_sections = set((jj.get("label") or "", jj.get("schedule") or "", jj.get("retain") or jj.get("keep") or "")
                         for jj in (data.jobs or {}).get("jobs", []) if jj.get("section_kind") == "prune")
    for j in (data.jobs or {}).get("jobs", []):
        v, reason = verdict_for_job(j, monitors)
        tier = j.get("tier", "")
        if "__" in tier:
            tier = tier.rsplit("__", 1)[-1]
        kind = j.get("section_kind", "")
        ret = j.get("retain") or j.get("keep") or ""
        # R4-4 (wlasciciel 2026-09-24): Zadanie to SAMO slowo; rodzina, retencja
        # i liczba datasetow sa osobnymi kolumnami (Prefiks, Trzyma, szt.) --
        # "pobranie hourly x2" i "porzadki -H24 x2" byly nieczytelne.
        pref = prefix_cell(j)
        keep = "-"
        if kind == "prune":
            # Sekcja [prune:] ze zdalnym zakresem (konto@host:dataset) sprzata migawki
            # U ZRODLA ("zdalny prune"); z lokalnym -- tutaj ("lokalny prune").
            task = _(u"zdalny prune") if "@" in (j.get("scope") or "") else _(u"lokalny prune")
            keep = keep_cell(ret)
        else:
            # SLOWO ZGODNE Z KIERUNKIEM. Kazde zadanie transferu nazywalo sie
            # "wysylka", takze w relacji, w ktorej ten host POBIERA -- a to
            # wlasnie ta strona chodzi w labie i tak czyta ja operator
            # ("wysylka" = cos stad wychodzi). Kierunek jest w linii crona,
            # wiec nie trzeba go zgadywac (pve10, 2026-09-21).
            _d = j.get("direction", "")
            task = {"pull": _(u"pobranie"), "push": _(u"wysyłka"), "local": _(u"kopia"), "snaponly": _(u"migawka")}.get(_d, _(u"transfer"))
            if _d == "pull" and job_is_mirror(j):
                keep = _(u"lustro")
        mode = (rels_by_name.get(j.get("label") or "") or {}).get("mode")
        nxt = cron_next(j.get("schedule", ""), now)
        clabel = job_cron_label(j)
        srow, vol = job_stats_for(data, j, clabel)
        if data.failed("stats"):
            czas, gb = "?", "?"
        else:
            czas = times_cell(srow.get("last_s"), srow.get("avg_s"), srow.get("max_s")) if srow else "-"
            gb = hbytes_short(vol) if vol is not None else "-"
        # BLAD BIEGU I WYRZUCENIA (2026-10-08): monitor mowi tylko o wieku kopii.
        # Ostatni bieg, ktory sie nie udal, robi wiersz "błąd biegu"; to, co bieg
        # wyrzucil z kopii (P-0), idzie do panelu. Tylko transfer -- porzadki
        # maja swoje wiersze i swoj werdykt.
        v0, reasons0 = v, ([reason] if reason else [])
        fails, discs = [], []
        if kind != "prune":
            fail, disc = job_run_issue(data, j)
            sc = (j.get("scope") or "?").split(":")[-1]
            if fail:
                fails.append((sc, fail))
                v = "BLAD"
            if disc:
                discs.append((sc, disc))
        reasons = list(reasons0) + [_(u"ostatni bieg %s rc=%s: %s") % (f[1], f[0], f[2] or _(u"zobacz cron.log"))
                                    for _ds, f in fails]
        items.append({
            "kind": "job", "name": j.get("label") or _("(bez rel.)"), "rel": None,
            "clabel": clabel, "srow": srow, "vol": vol, "czas": czas, "gb": gb,
            "dir": direction_of(host, j.get("peer") or "", [j.get("direction", "")], mode),
            "mode": mode, "task": task, "pref": pref, "keep": keep, "cnt": 1, "tier": tier, "scope": j.get("scope", ""),
            "schedule": j.get("schedule", ""), "verdict": v, "vword": _(VERDICTS.get(v, (v, 0))[0]),
            "reasons": reasons, "fails": fails, "discards": discs, "srows": [srow] if srow else [], "next_epoch": nxt,
            "next": fmt_when(nxt, now) if nxt else "?", "job": j, "jobs": [j],
            "state": "", "last_txt": "", "monitors": [], "transfers": [], "last": None,
        })
        # SZCZEBEL, KTORY SAM SIE SPRZATA (uwaga 4, 2026-09-24). Szablon plaski (np.
        # passive-flat relacji synchro) ma pobranie i porzadki w JEDNEJ sekcji
        # [dataset:]; list-jobs daje jedno zadanie, a linia delsnaps siedzi w jego
        # cron_lines. F2 pokazywal tylko "pobranie" -- na pve10 18 linii crona
        # pve9-synchro, a porzadkow nie bylo na ekranie wcale. Osobny wiersz, z
        # harmonogramem wzietym z tej linii.
        # TYLKO WLASNA linia: cron_lines niesie linie calego BLOKU (na pve10 zadanie
        # ct-201 mialo tez linie ct-201/data...; w fiksturze sekcja dataset niosla
        # linie sekcji [prune:]) -- pierwsza z brzegu linia delsnaps liczyla cudze
        # porzadki drugi raz. Wlasna = ten sam szczebel i ten sam znacznik "(...)"
        # co linia transferu TEGO zadania. Brak dopasowania = brak wiersza.
        own_tag = ""
        raw_tier = j.get("tier") or ""
        for cl in j.get("cron_lines") or []:
            if "delsnaps.sh" not in cl and raw_tier and raw_tier in cl and (j.get("scope") or "\0") in cl:
                m = re.search(r'\(([^)]*)\)"', cl)
                own_tag = m.group(1) if m else ""
                break
        if kind == "dataset" and ret and own_tag:
            for cl in j.get("cron_lines") or []:
                if "delsnaps.sh" not in cl or raw_tier not in cl or ("(%s)" % own_tag) not in cl:
                    continue
                psched = " ".join(cl.split()[:5])
                if (j.get("label") or "", psched, ret) in prune_sections:
                    break
                pnxt = cron_next(psched, now)
                pit = dict(items[-1])
                # Etykieta WLASNEJ linii delsnaps (Przebiegi czytaja biegi po etykiecie) --
                # nie etykieta transferu, z ktorego wiersz jest skopiowany.
                _pm = re.search(r'zfs-job\.sh "([^"]+)"', cl)
                _pl = (_pm.group(1).split(" ", 1) + [""])[1] if _pm else ""
                # Statystyki TEJ linii: srow None dawal w panelu F2/F3 "brak biegow w
                # dzienniku", choc lista obok pokazywala jej biegi (przejscie GUI pve10,
                # 2026-10-28: pve9 lokalny prune hourly: enc, 144 wywolania w job-stats).
                _ps = job_stats_for(data, j, _pl)[0] if _pl else None
                _pc = ("?" if data.failed("stats") else
                       times_cell(_ps.get("last_s"), _ps.get("avg_s"), _ps.get("max_s")) if _ps else "-")
                pit.update({"task": _(u"lokalny prune"), "keep": keep_cell(ret), "schedule": psched, "czas": _pc, "gb": "-", "clabel": _pl,
                            "vol": None, "srow": _ps, "next_epoch": pnxt,
                            "next": fmt_when(pnxt, now) if pnxt else "?", "jobs": [j],
                            "verdict": v0, "vword": _(VERDICTS.get(v0, (v0, 0))[0]),
                            "reasons": list(reasons0), "fails": [], "discards": [], "srows": [_ps] if _ps else []})
                items.append(pit)
                break
    # REPLIKI NA F2 (2026-10-08, wlasciciel: "czy zadania repliki wchodza do listy
    # zadan?"). list-jobs czyta tylko sekcje relacji, wiec replik tu nie bylo, choc
    # to zadania z crona (albo "po wlozeniu") z rc, czasem i bledami -- a job-stats
    # juz je liczyl. Wiersz z list-replicas i statystyk; werdykt "bez monitora",
    # dopoki replika nie ma progu, ktory mozna przekroczyc.
    for rp in (data.replicas or {}).get("replicas", []):
        rname = rp.get("name") or "?"
        srow = replica_stats_row(data, rname)
        sched = rp.get("schedule") or "?"
        on_ins = sched == "on-insert"
        rnxt = None if on_ins else cron_next(sched, now)
        reasons = []
        if srow and str(srow.get("last_rc")) not in ("0", "None"):
            reasons.append(_(u"ostatni bieg rc=%s") % srow.get("last_rc"))
        # WERDYKT Z MONITORA REPLIKI (2026-10-08): nosnik wymienny -- linia bramy
        # (`zfs-media-gate.sh age`, etykieta = nazwa repliki, wzorzec "replica");
        # staly -- check-snap-age na kopii (dst/zrodlo) z prefiksem repliki.
        rver = "BEZ MONITORA"
        _dst = rp.get("dst") or ""
        for m in monitors:
            if (m.get("pattern") == "replica" and m.get("label") == rname) or \
               (_dst and m.get("pattern") == rp.get("prefix") and
                    any((d or "").startswith(_dst + "/") for d in m.get("datasets") or [])):
                rver = m.get("verdict") or "UNKNOWN"
                if rver != "OK" and m.get("reason"):
                    reasons.append(m["reason"])
                break
        if data.failed("stats"):
            czas = "?"
        else:
            czas = times_cell(srow.get("last_s"), srow.get("avg_s"), srow.get("max_s")) if srow else "-"
        items.append({
            "kind": "replica", "name": rname, "rel": None, "replica": rp,
            "clabel": u"replica copy (%s)" % rname, "srow": srow, "vol": None, "czas": czas, "gb": "-",
            "dir": u"%s → %s" % (host, (rp.get("dst") or "?").split("/")[0]),
            "mode": None, "task": _(u"replika"), "pref": rp.get("prefix") or "-", "keep": "-",
            "cnt": len(rp.get("sources") or []) or 1, "tier": "", "scope": rp.get("source") or "",
            # "po podłączeniu" stoi w kolumnie Następny; w Harmonogramie poszerzałoby
            # kolumnę i przy 80 znakach wypychało Trzyma z ekranu WSZYSTKIM wierszom.
            "schedule": "-" if on_ins else sched, "verdict": rver,
            "vword": _(VERDICTS.get(rver, (rver, 0))[0]), "reasons": reasons, "next_epoch": rnxt,
            "next": (_(u"po podłączeniu") if on_ins else (fmt_when(rnxt, now) if rnxt else "?")),
            "job": {}, "jobs": [], "state": "", "last_txt": "", "monitors": [], "transfers": [], "last": None,
        })
    # GRUPOWANIE: relacja synchro (albo kazda inna z kilkoma datasetami pod tym
    # samym zadaniem) miala tyle wierszy F2, ile linii crona -- ten sam blad,
    # ktory `rel_pairs` naprawil na F3 (2026-09-21). Klucz = to, co wiersz
    # OPOWIADA (relacja, kierunek, zadanie, harmonogram); scope roznicuje
    # datasety, ale nie zmienia opowiesci, wiec nie wchodzi do klucza. Werdykt
    # NAJGORSZY przez worst() -- druga kolumna VERDICTS to numer koloru, nie
    # powaga (ta sama pulapka, opisana w rel_pairs). Wolumen sumowany, kiedy
    # znany dla kazdego z grupy; kolejnosc = pierwsze wystapienie.
    grouped, order = {}, []
    for it in items:
        key = (it["name"], it["dir"], it["task"], it.get("pref"), it.get("keep"), it["schedule"])
        if key not in grouped:
            grouped[key] = it
            order.append(key)
            it["_verdicts"] = [it["verdict"]]
            it["_count"] = 1
            continue
        g = grouped[key]
        g["_count"] += 1
        g["_verdicts"].append(it["verdict"])
        g["jobs"].append(it["job"])
        g.setdefault("fails", []).extend(it.get("fails") or [])
        g.setdefault("srows", []).extend(it.get("srows") or [])
        g.setdefault("discards", []).extend(it.get("discards") or [])
        for r in it["reasons"]:
            if r not in g["reasons"]:
                g["reasons"].append(r)
        if it["next_epoch"] and (g["next_epoch"] is None or it["next_epoch"] < g["next_epoch"]):
            g["next_epoch"], g["next"] = it["next_epoch"], it["next"]
        if g.get("vol") is not None and it.get("vol") is not None:
            g["vol"] = g["vol"] + it["vol"]
            g["gb"] = hbytes_short(g["vol"])
        else:
            g["vol"], g["gb"] = None, ("?" if data.failed("stats") else "-")
        if it["czas"] not in ("-", "?") and g["czas"] in ("-", "?"):
            g["czas"] = it["czas"]
    rows = []
    for key in order:
        g = grouped[key]
        g["verdict"] = worst(g["_verdicts"])
        g["vword"] = _(VERDICTS.get(g["verdict"], (g["verdict"], 0))[0])
        g["cnt"] = g["_count"]
        del g["_verdicts"]
        del g["_count"]
        rows.append(g)
    for u in (data.jobs or {}).get("unreadable", []):
        rows.append({
            "kind": "unreadable", "name": _("konto %s") % u.get("account", "?"), "rel": None, "dir": "?",
            "task": "nieczytelny blok", "pref": "-", "keep": "-", "cnt": "",
            "scope": u.get("config") or _("(bez Source)"), "schedule": "",
            "verdict": "UNKNOWN", "vword": _("nie odpowiada"), "reasons": [u.get("error", "")],
            "next_epoch": None, "next": "?", "job": None, "jobs": [], "u": u,
            "state": "nieczytelny", "last_txt": _("%s linii w cronie") % u.get("lines_in_block", "?"),
            "monitors": [], "transfers": [], "last": None,
        })
    # STRAZNIK BEZ ZADANIA (F5 zniesiony, wariant b, uwaga 3): linia monitora,
    # ktora NIE dopasowala sie do zadnego zadania (verdict_for_job/
    # monitors_for_job) -- watchdog pilnujacy czegos, czego juz nie ma w
    # cronie. Zniknac nie moze: usuniety ekran Monitor wlasnie temu sluzyl
    # (check-snap-age.sh naglowek: monitor, ktory nigdy nie chodzi, wyglada jak
    # monitor mowiacy OK).
    matched = set()
    for j in (data.jobs or {}).get("jobs", []):
        for m in monitors_for_job(j, monitors):
            matched.add(id(m))
    # Strażnik REPLIKI ma etykietę repliki, a jej zadanie przychodzi z list-replicas,
    # nie z list-jobs -- bez tego wiersz "? strażnik bez zadania" (kampania 2026-10-09, K1).
    _repnames = {r.get("name") for r in (data.replicas or {}).get("replicas", []) if r.get("name")}
    for m in monitors:
        if id(m) in matched or (m.get("label") or "") in _repnames:
            continue
        v = m.get("verdict", "UNKNOWN")
        rel = rels_by_name.get(m.get("label") or "")
        rows.append({
            "kind": "monitor", "name": m.get("label") or _("(bez etykiety)"), "rel": None,
            "dir": direction_of(host, rel_addr(rel), [], rel.get("mode")) if rel else "?",
            "task": _(u"strażnik bez zadania"), "pref": "-", "keep": "-", "cnt": len(m.get("datasets", [])) or "",
            "scope": ",".join(m.get("datasets", [])) or "?",
            "schedule": m.get("schedule", ""), "verdict": v, "vword": _(VERDICTS.get(v, (v, 0))[0]),
            "reasons": [m.get("reason", "")] if m.get("reason") else [],
            "next_epoch": None, "next": "?", "job": None, "jobs": [], "m": m,
            "state": "", "last_txt": "", "monitors": [m], "transfers": [], "last": None,
            "czas": "-", "gb": "-", "vol": None, "tier": "",
        })
    return rows


def sort_zad_rows(rows, mode, data):
    """Widok F2 wg `mode` (R3-4, wersja 2): 0 -- relacje w tej samej kolejnosci,
    co dzis, w srodku wg najblizszego biegu (bez terminu na koniec); 1 -- os
    czasu, wszystko wg najblizszego biegu; 2 -- wg ostatniego biegu, od
    najstarszego/nieznanego (podejrzane pierwsze). `sorted()` jest stabilny,
    wiec remisy zostaja w kolejnosci wejsciowej -- to daje "ta sama kolejnosc
    relacji, co dzis" bez odrebnej logiki."""
    if mode == 1:
        return sorted(rows, key=lambda r: (r["next_epoch"] is None, r["next_epoch"] or 0))
    if mode == 2:
        def key2(r):
            e = last_run_epoch_for_row(data, r)
            return (0, 0) if e is None else (1, e)
        return sorted(rows, key=key2)
    names = []
    for r in rows:
        if r["name"] not in names:
            names.append(r["name"])
    buckets = {n: [] for n in names}
    for r in rows:
        buckets[r["name"]].append(r)
    out = []
    for n in names:
        out.extend(sorted(buckets[n], key=lambda r: (r["next_epoch"] is None, r["next_epoch"] or 0)))
    return out


# PRZEBIEGI (U79/U80, wlasciciel 2026-10-27, symulacja zaakceptowana: "Podoba mi
# sie. Koduj"). F2 i F4 to bylo to samo widziane z dwoch stron: zadanie, ktore
# juz bieglo, i to, ktore pobiegnie. Jedna os czasu z kreska "teraz": nad nia
# biegi z ostatnich PRZ_PAST_H godzin (job-stats --runs, z dziennika crona), pod
# nia nadchodzace z najblizszych PRZ_AHEAD_H (z linii crona, co najmniej jeden
# na zadanie). F8 chowa wykonane, F9 grupuje po relacji (w grupie chronologicznie).
# Lista = kiedy i z jakim skutkiem; panel = jak ustawione + ten bieg; dol =
# zrodlo -> cel tego biegu. Kazdy fakt w jednym miejscu.
PRZ_PAST_H = 12
# F6 (U130): przebiegi repliki siegaja dalej -- replika "pn-pt" ma przerwe pt->pn. Czytnik
# job-stats bierze tyle godzin biegow (pve10: 48 h ~5 s, 168 h ~12 s; idzie w drugim etapie),
# F2 nadal pokazuje PRZ_PAST_H.
PRZ_RUNS_H = 72
PRZ_AHEAD_H = 6

# ---------------------------------------------------------------------------
# PORZADEK PANELI (U21, wlasciciel 2026-10-19, symulacja zaakceptowana): LISTA =
# wybor i stan; PRAWY PANEL = fakty o zaznaczonym wierszu, ktorych lista nie ma;
# DOLNY PANEL = "dzieci" wiersza w zakladkach. Tab wchodzi do dolnego panelu,
# strzalki lewo/prawo przelaczaja zakladki, prawy panel idzie wtedy za kursorem
# (zaznaczone dziecko), Esc wraca na liste. Kazdy fakt w jednym miejscu.
# ---------------------------------------------------------------------------
TABS = {
    "zadania": [("run", u"Źródło → cel")],
    "relacje": [("ds", u"Datasety"), ("zad", u"Zadania")],
    "szablony": [("sz", u"Szczeble"), ("uz", u"Używają")],
    "nosniki": [("run", u"Przebiegi")],
    "odzysk": [("ds", u"Datasety")],
}


def group(ch, name):
    """Naglowek grupy w panelu klucz/wartosc (detail_kv rysuje go linia)."""
    return ("", name)


def times_words(last, avg, mx):
    """ostatni / sredni / maks. slowami -- panel ma miejsce, lista nie."""
    if all(hsecs(x) == "-" for x in (last, avg, mx)):
        return "-"
    return _(u"ostatni %s / średni %s / maks. %s") % (hsecs(last), hsecs(avg), hsecs(mx))


def tab_title(name, tabs, ti):
    parts = [(u"[%s]" % _(label)) if i == ti else _(label) for i, (_k, label) in enumerate(tabs)]
    return (u"%s: " % name if name else u"") + u"  ".join(parts)


def table_fit(heads, rows, inner, ch, prio=None, flex=0):
    """Kolumny na miare tresci (nie wezsze niz naglowek), odstep 2..4. Za szeroko --
    najpierw traci szerokosc kolumna `flex` (do 12 znakow), potem odpadaja kolumny
    najmniej wazne (`prio`: indeksy od najwazniejszej). Kolejnosc na ekranie
    zostaje. -> (naglowek, linie)"""
    n = len(heads)
    w = [max([len(heads[i])] + [len(u"%s" % (r[i] if r[i] is not None else "")) for r in rows]) for i in range(n)]
    keep = list(range(n))
    order = list(prio) if prio else list(range(n))

    def total(ix):
        return sum(w[i] for i in ix) + 2 * (len(ix) - 1)
    while len(keep) > 1 and total(keep) > inner:
        fx = flex if flex in keep else keep[0]
        over = total(keep) - inner
        floor = max(len(heads[fx]), 12)
        if w[fx] - over >= floor:
            w[fx] -= over
            break
        w[fx] = min(w[fx], floor)
        for i in reversed(order):
            if i in keep:
                keep.remove(i)
                break
        else:
            break
    if total(keep) > inner:
        w[keep[0]] = max(4, w[keep[0]] - (total(keep) - inner))
    gap = 2
    if len(keep) > 1:
        gap = max(2, min(4, 2 + (inner - total(keep)) // (len(keep) - 1)))
    sep = " " * gap
    hdr = sep.join(fit(heads[i], w[i]) for i in keep)
    lines = [sep.join(fit(r[i] if r[i] not in (None, "") else "-", w[i], ch) for i in keep) for r in rows]
    return hdr, lines


def render_tabbed(data, width, height, now, ch, screen, title, heads, cells, cursor, list_foot,
                  det_title, det_pairs, child, focus, pair_cursor, actions, empty_lines=(), prio=None, flex=0):
    """Ekran wg reguly U21: u gory lista (lewo) i szczegoly (prawo), na dole
    zakladki z dziecmi wiersza. `child` = None: bez dolnego panelu (F4) -- wtedy
    ponizej 150 kolumn panel idzie pod liste, jak dotad."""
    scr = Screen()
    avail = height - 2
    items = (child or {}).get("items") or []
    in_child = focus == "pairs" and child is not None and bool(items)
    if in_child:
        it = items[min(pair_cursor, len(items) - 1)]
        det_title, det_pairs = it.get("title") or det_title, it.get("pairs") or []
    stacked = child is None and width < 150
    lbw = width if stacked else max(48, int(width * 0.6))
    pw = width if stacked else width - lbw
    panel_need = len(detail_kv(ch, det_pairs, pw - 4)) + 2
    if child is None:
        top_h = avail - (min(panel_need, 12) if stacked else 0)
    else:
        # Lista nie traci, dopoki dol ma choc tercje ekranu (F5: 17 szablonow
        # zostawialo szczeblom jedna linie).
        # "rows" (U97): dol o stalej wysokosci -- wiecej pozycji przewija sie po Tab.
        need_child = (child.get("rows") or max(1, len(items))) + 4
        top_h = max(len(cells) + 4, 7, min(panel_need, avail - need_child))
        top_h = min(top_h, avail - min(need_child, max(5, avail // 3)))
    inner = lbw - 4
    hdr, lines = table_fit(heads, cells, inner, ch, prio, flex)
    list_h = max(1, top_h - 4)
    first = max(0, cursor - list_h + 1)
    # Ostatni wiersz okna zajmuje "... jeszcze N", gdy nizej sa dalsze -- kursor na nim
    # znikal (F2 otwarte przy "teraz": panel mowil o biegu, ktorego lista nie pokazywala).
    if list_h > 1 and cursor == first + list_h - 1 and len(lines) > first + list_h:
        first += 1
    body = [hdr, ch.dash * inner]
    cur_y = None
    for i in range(first, min(len(lines), first + list_h)):
        if i == cursor:
            cur_y = len(body)
        body.append(lines[i])
    if not cells:
        body += list(empty_lines)
    if len(lines) > first + list_h and list_h > 1:
        body[-1] = fit(_(u"... jeszcze %d") % (len(lines) - first - list_h + 1), inner)
    while len(body) < list_h + 2:
        body.append("")
    body = body[:list_h + 2]
    listbox = box(ch, title, body, lbw, footer=("" if in_child else list_foot))
    out = [top_bar(data, width, now, ch.ascii, len(data.errors))]
    if focus != "pairs" and cur_y is not None:
        scr.cursor_y = 2 + cur_y
    if stacked:
        ph = max(3, avail - len(listbox))
        pl = detail_kv(ch, det_pairs, pw - 4)[:ph - 2]
        while len(pl) < ph - 2:
            pl.append("")
        out += listbox + (box(ch, det_title, pl, pw, double=False) if det_pairs else [])
    else:
        pl = detail_kv(ch, det_pairs, pw - 4)[:len(listbox) - 2]
        while len(pl) < len(listbox) - 2:
            pl.append("")
        panel = box(ch, det_title, pl, pw, double=False)
        out += [fit(l, lbw) + fit(p_, pw) for l, p_ in zip(listbox, panel)]
    if child is not None:
        binner = width - 4
        ch_h = max(1, avail - top_h - 2)
        pcur = None
        if items:
            chdr, clines = table_fit(child["heads"], [x["cells"] for x in items], binner, ch, child.get("prio"), child.get("flex", 0))
            cbody = [chdr, ch.dash * binner]
            room = max(1, ch_h - 2)
            pc = min(pair_cursor, len(clines) - 1)
            cfirst = max(0, pc - room + 1)
            for i in range(cfirst, min(len(clines), cfirst + room)):
                if in_child and i == pc:
                    pcur = len(cbody)
                cbody.append(clines[i])
            if len(clines) > cfirst + room and room > 1:
                cbody[-1] = fit(_(u"... jeszcze %d") % (len(clines) - cfirst - room + 1), binner)
        else:
            cbody = wrap(child.get("empty") or _(u"brak"), binner)
        cbody = cbody[:ch_h]
        while len(cbody) < ch_h:
            cbody.append("")
        many = len(child["tabs"]) > 1
        snaps = any(it.get("relname") and it.get("pair") is not None for it in child.get("items") or [])
        cfoot = (child.get("foot") or ((_(u"m migawki   ") if snaps else u"") + u"Enter okno   " + (_(u"←→ zakładki   ") if many else u"")
                 + _(u"Esc wraca   Tab do linii poleceń"))) if in_child else ""
        bottom = box(ch, tab_title(child.get("name"), child["tabs"], child.get("ti", 0)), cbody, width, footer=cfoot)
        if pcur is not None:
            scr.cursor_y = len(out) + 1 + pcur
        out += bottom
    scr.lines = out
    for y, ln in enumerate(scr.lines):
        if y and ln and ln[0] in (ch.dtl, ch.dbl, ch.stl, ch.sbl):
            scr.titles.add(y)
    scr.bars.add(0)
    while len(scr.lines) < height - 1:
        scr.lines.append(fit("", width))
    scr.lines = scr.lines[:height - 1]
    push_key_bar(scr, screen, width, actions)
    return scr


# --- dzieci wierszy (dolny panel) ------------------------------------------
def ds_of(snap):
    return (snap or "").split("@", 1)[0]


def transfer_label(t, data):
    """Kto biegl: relacja, a gdy etykiety brak -- replika po jej celu (U21: "(bez rel.)"
    nic nie mowilo)."""
    if t.get("label"):
        return t["label"]
    tgt = t.get("target") or ""
    for r in (data.replicas or {}).get("replicas", []):
        d = r.get("dst") or "\0"
        if tgt == d or tgt.startswith(d + "/"):
            return _(u"replika %s") % r.get("name")
    return _(u"(bez relacji)")


def transfer_item(t, data, now, ch):
    wd, _note = transfer_word(t, now)
    st, fin = int(t.get("started_epoch") or 0), int(t.get("finished_epoch") or 0)
    when = (_(u"biegnie od %s") % time.strftime("%H:%M", time.localtime(st))) if t.get("state") == "running" and st \
        else fmt_when_short(fin or st, now)
    return {"cells": [when, wd, ds_of(t.get("dataset")), fmt_dur(fin - st) if fin and st else "-", transfer_data_cell(t)],
            "pairs": transfer_detail_pairs(t, now, ch, data),
            "title": u"%s -- %s" % (transfer_label(t, data), ds_of(t.get("dataset"))), "t": t}


def transfer_data_cell(t):
    tot, dn = int(t.get("total_bytes") or 0), int(t.get("done_bytes") or 0)
    if t.get("state") == "running":
        if tot > 0:
            return "%s / %s" % (human_bytes(dn), human_bytes(tot))
        return human_bytes(dn) if dn > 0 else "?"
    return human_bytes(tot) if tot > 0 else (human_bytes(dn) if dn > 0 else "-")


def iso_epoch(txt):
    """Czas z dziennika (date -Is, "2026-10-27T01:08:01+01:00") -> epoch albo None."""
    import datetime
    try:
        return int(datetime.datetime.strptime(txt[:19], "%Y-%m-%dT%H:%M:%S").replace(
            tzinfo=datetime.timezone(datetime.timedelta(hours=int(txt[19:22]), minutes=int(txt[19] + txt[23:25])))).timestamp())
    except (ValueError, IndexError, TypeError):
        return None


def run_label_of(item):
    """Etykieta biegu w dzienniku (ZFS-JOB BEGIN/END) dla wiersza zadania albo repliki."""
    if item.get("kind") == "replica":
        return (item.get("srow") or {}).get("label") or ""
    return item.get("clabel") or ""


def run_jobs(r):
    """Zadania (sekcje list-jobs) jednego biegu, po jednym na zakres: linia GFS
    przycina WSZYSTKIE szczeble jednego datasetu (pve10: cztery sekcje [prune:]
    keep_hourly..yearly, jedna linia crona) -- to jeden dataset, nie cztery."""
    jobs = r["jobs"] if r.get("jobs") is not None else \
        [j for it in r["items"] for j in (it.get("jobs") or ([it["job"]] if it.get("job") else []))]
    out, seen = [], set()
    for j in jobs:
        k = j.get("scope") or id(j)
        if k not in seen:
            seen.add(k)
            out.append(j)
    return out


def job_id_cell(its, jobs=None):
    """Kolumna Zadanie w grupie relacji: szczebel + krotkie nazwy datasetow linii."""
    names = []
    if jobs is None:
        jobs = [j for it in its for j in (it.get("jobs") or ([it["job"]] if it.get("job") else []))]
    for j in jobs:
        for x in (j.get("scope") or "").rsplit(":", 1)[-1].split(","):
            x = x.rsplit("/", 1)[-1]
            if x and x not in names:
                names.append(x)
    it0 = its[0]
    if it0.get("kind") == "replica":
        return _(u"replika %s") % it0["name"]
    tier = it0.get("tier") or ""
    short = u", ".join(names[:2]) + ((u" +%d" % (len(names) - 2)) if len(names) > 2 else u"")
    return (u"%s: %s" % (tier, short)) if tier and short else (tier or short or u"-")


def run_is_prune(it):
    """Bieg porzadkowy (lokalny/zdalny prune) -- ta sama proba co przy wolumenie biegu."""
    j = it.get("job") or (it.get("jobs") or [{}])[0]
    return j.get("section_kind") == "prune" or u"prune" in (it.get("task") or u"")


def build_runs(data, jobrows, now, show_done=True, grouped=False, past_h=PRZ_PAST_H):
    """Wiersze PRZEBIEGOW: bieg = (zadanie, chwila). Zadania z jedna linia crona
    (jedna etykieta) ida razem -- pve2: subvol-103 i ROOT/pve-1 w jednym snapget,
    jeden bieg, nie dwa. Wiersze "now" (kreska) i "grp" (naglowek relacji) sa
    tylko do czytania; kursor je przeskakuje."""
    runs_by = {}
    for x in (data.stats or {}).get("runs") or []:
        runs_by.setdefault(x.get("label") or "", []).append(x)
    for lst_ in runs_by.values():
        lst_.sort(key=lambda x: x.get("end") or x.get("start") or "")
    groups, idx, static = [], {}, []
    for it in jobrows or []:
        if it.get("kind") not in ("job", "replica"):
            static.append({"kind": "run", "static": True, "past": False, "at": None, "item": it, "items": [it], "name": it.get("name") or u"?"})
            continue
        if it.get("kind") == "replica":
            parts = [(run_label_of(it), None)]
        else:
            parts = []
            for j in it.get("jobs") or [it["job"]]:
                lb = it.get("clabel") if len(it.get("jobs") or [1]) == 1 else job_cron_label(j)
                parts.append((lb or "", j))
        for lbl, j in parts:
            key = (lbl, it.get("schedule") or "") if lbl else ("\0", id(it), id(j))
            if key in idx:
                g = groups[idx[key]]
                if it not in g[1]:
                    g[1].append(it)
                if j is not None and all(x is not j for x in g[2]):
                    g[2].append(j)
                continue
            idx[key] = len(groups)
            groups.append((lbl, [it], [j] if j is not None else None))
    out, shown = [], set()
    for lbl, its, gjobs in groups:
        it0 = its[0]
        base = {"kind": "run", "item": it0, "items": its, "jobs": gjobs, "name": it0["name"], "label": lbl}
        # Bieg z dziennika jest JEDEN na etykiete: dwa szczeble jednej linii crona (pve10:
        # pobranie hourly i daily w jednym snapget) nie dostaja go po razie (zmierzone 10-27).
        if show_done and lbl and lbl not in shown:
            shown.add(lbl)
            prev, mine = None, []
            for x in runs_by.get(lbl, []):
                st, en = iso_epoch(x.get("start") or ""), iso_epoch(x.get("end") or "")
                at = en or st
                p_end, prev = prev, (en or st)
                if at is None or at < now - past_h * 3600:
                    continue
                r = dict(base)
                r.update({"past": True, "at": at, "start": st, "end": en, "rc": x.get("rc"), "err": x.get("error") or "",
                          "prev_end": p_end})
                mine.append(r)
            # U112 (wlasciciel 2026-10-28, symulacja A): godzinowe prune to byly dwie trzecie
            # z ~200 wierszy F2 na pve10. Udane biegi jednej linii crona ida w JEDEN wiersz
            # "x N" w miejscu ostatniego; bieg z bledem, pominiety albo trwajacy zostaje
            # osobnym wierszem, zeby go nie przeoczyc.
            okr = [r for r in mine if r.get("rc") == 0]
            if run_is_prune(it0) and len(okr) > 1:
                fold = dict(okr[-1])
                fold.update({"fold_n": len(okr), "fold_from": okr[0]["at"],
                             "fold_bad": len([r for r in mine if r.get("rc") not in (0, 75, -1, None)])})
                mine = [r for r in mine if r.get("rc") != 0] + [fold]
                mine.sort(key=lambda r: r["at"])
            out += mine
        t, n = it0.get("next_epoch"), 0
        sched = it0.get("schedule") or ""
        # Z nadchodzacych prune tylko najblizszy (U112); transfery i migawki -- kazdy bieg.
        nmax = 1 if run_is_prune(it0) else 48
        while t and n < nmax and (n == 0 or t <= now + PRZ_AHEAD_H * 3600):
            r = dict(base)
            r.update({"past": False, "at": t})
            out.append(r)
            n += 1
            t = cron_next(sched, t + 60) if it0.get("kind") == "job" else None
        if n == 0:
            r = dict(base)
            r.update({"past": False, "at": None})
            out.append(r)
    key = lambda r: (r["at"] is None, r["at"] or 0)
    if not grouped:
        out.sort(key=key)
        return static + insert_now(out, now, show_done)
    names = []
    for r in out:
        if r["name"] not in names:
            names.append(r["name"])
    res = []
    for nm in names:
        mine = sorted([r for r in out if r["name"] == nm], key=key)
        bad = any(r["past"] and r.get("rc") not in (0, 75, -1, None) and not any(
            q["past"] and q["at"] > r["at"] and q.get("rc") == 0 and q["item"] is r["item"] for q in mine) for r in mine)
        res.append({"kind": "grp", "name": nm, "bad": bad, "item": mine[0]["item"]})
        res += insert_now(mine, now, show_done)
    return static + res


def insert_now(rows, now, show_done):
    """Kreska "teraz" miedzy wykonanymi a nadchodzacymi (tylko gdy wykonane widac)."""
    if not show_done or not any(r["past"] for r in rows):
        return rows
    for i, r in enumerate(rows):
        if not r["past"]:
            return rows[:i] + [{"kind": "now", "name": r["name"], "at": now}] + rows[i:]
    return rows + [{"kind": "now", "name": rows[-1]["name"], "at": now}]


def run_window_row(r):
    """U92 (wlasciciel 2026-10-27): Enter na biegu = okno TEGO biegu -- jego datasety,
    sekcje configu tych zakresow i TYLKO linia crona z jego etykieta. Calosc (wszystkie
    sekcje, caly cron) jest w oknie relacji na F3."""
    one = dict(r["item"])
    jobs = run_jobs(r) or one.get("jobs") or [one["job"]]
    lbl = r.get("label") or ""
    if lbl:
        tag = u' %s"' % lbl
        cut = []
        for j in jobs:
            own = [l for l in (j.get("cron_lines") or []) if tag in l]
            cut.append(dict(j, cron_lines=own) if own else j)
        jobs = cut
    one["jobs"], one["job"] = jobs, jobs[0]
    return one


def snaps_index(data):
    """{dataset: [(creation, written, nazwa migawki)]} z job-stats --runs (U96)."""
    st = data.stats or {}
    idx = st.get("_snaps_idx")
    if idx is None:
        idx = {}
        for x in st.get("snaps") or []:
            ds, _at, sn = (x.get("name") or "").partition("@")
            if sn:
                idx.setdefault(ds, []).append((int(x.get("creation") or 0), int(x.get("written") or 0), sn))
        st["_snaps_idx"] = idx
    return idx


def run_dataset_bytes(r, j, data):
    """Ile wniosl bieg r dla zadania j: suma `written` migawek jego rodziny na zbiorze,
    na ktorym laduja (cel; przy samych migawkach -- zrodlo), powstalych po poprzednim
    biegu tej linii i nie pozniej niz koniec tego. None = nie wiadomo (brak danych)."""
    if not r.get("past") or "snaps" not in (data.stats or {}):
        return None
    # Porzadki nie przenosza danych; cel zdalny (wysylka, zdalne migawki) mierzy sie
    # tam, nie tu -- "-", nie zero.
    if j.get("section_kind") == "prune" or u"prune" in (r["item"].get("task") or u""):
        return None
    src, dst = job_src_dst(j)
    where = dst if j.get("direction") not in ("snaponly",) else src
    if not where or where in ("-", "?") or "@" in where or ":" in where:
        return None
    fam = family_of(j) or ""
    hi = (r.get("end") or r["at"]) + 60
    lo = r.get("prev_end") or ((r.get("start") or r["at"]) - 3600)
    tot, hit = 0, False
    for ds, lst_ in snaps_index(data).items():
        if ds != where and not ds.startswith(where + "/"):
            continue
        for cr, wr, sn in lst_:
            if lo < cr <= hi and (not fam or fam == "-" or sn.startswith(fam)):
                tot += wr
                hit = True
    return tot if hit else 0


def run_bytes(r, data):
    if r.get("kind") != "run" or r.get("static") or not r.get("past"):
        return None
    vals = [run_dataset_bytes(r, j, data) for j in run_jobs(r)]
    vals = [v for v in vals if v is not None]
    return sum(vals) if vals else None


def run_result(r):
    if r.get("static"):
        return r["item"].get("vword") or u"-"
    if not r.get("past"):
        return _(u"nadchodzący")
    rc = r.get("rc")
    if rc == 0:
        # Zwiniety prune (U112): "xN" w WYNIKU, nie w Co -- przy 80 kolumnach Co znika
        # (prio tabeli), a wiersz "pve9 OK" nie mowil, ze to 12 biegow (kampania 2026-10-28).
        if r.get("fold_n"):
            return (_(u"OK \u00d7%d (błędy: %d)") % (r["fold_n"], r["fold_bad"])) if r.get("fold_bad") else \
                (u"OK \u00d7%d" % r["fold_n"])
        return u"OK"
    if rc == 75:
        return _(u"pominięty")
    if rc == -1:
        return _(u"biegnie")
    return _(u"BŁĄD rc=%s") % rc


def run_when(at):
    return time.strftime(DT_FMT, time.localtime(at)) if at else u"-"


def run_pairs(r, now, ch):
    """Grupa "Ten bieg" / "Nadchodzacy bieg" w panelu."""
    if r.get("past"):
        pairs = [group(ch, _(u"Ten bieg")), (_(u"Kiedy"), time.strftime(DT_FMT + ":%S", time.localtime(r["at"]))),
                 (_(u"Wynik"), run_result(r))]
        if r.get("start") and r.get("end"):
            pairs.append((_(u"Czas"), fmt_dur(r["end"] - r["start"])))
        if r.get("fold_n"):
            pairs.append((_(u"Zwinięte"), _(u"udane biegi: %d, od %s (ten = ostatni)") % (
                r["fold_n"], time.strftime("%H:%M", time.localtime(r["fold_from"])))))
        if r.get("rc") == 75:
            pairs.append((_(u"Powód"), _(u"pominięty: trwał inny bieg tego zadania (blokada)")))
        elif r.get("err"):
            pairs.append((_(u"Powód"), r["err"]))
        return pairs
    if not r.get("at"):
        return [group(ch, _(u"Nadchodzący bieg")), (_(u"Kiedy"), _(u"bez terminu (po włożeniu nośnika albo poza cronem)"))]
    return [group(ch, _(u"Nadchodzący bieg")), (_(u"Kiedy"), u"%s   %s" % (
        time.strftime(DT_FMT, time.localtime(r["at"])), _(u"za %s") % fmt_dur(max(0, r["at"] - now))))]


def transfer_detail_pairs(t, now, ch, data=None):
    """Panel transferu (przebiegi F2/F6), U21: bez Relacji, Trybu i Stanu (sa w
    liscie); "Poprzednia" zamiast "od @" (wlasciciel 2026-10-19). Zostal po F4
    Historia (#928), bo bieg z zapisem transferu pokazuje go na dole F2."""
    wd, note = transfer_word(t, now)
    snap = t.get("dataset", "?")
    pairs = [(_(u"Migawka"), snap.split("@", 1)[-1] if "@" in snap else snap),
             (_(u"Poprzednia"), t["base"].split("@", 1)[-1] if t.get("base") else _(u"brak -- pełna kopia"))]
    src = ds_of(snap)
    tgt = t.get("target", "?")
    peer = t.get("peer") or ""
    if peer == "local":
        peer = ""
    if t.get("direction") == "pull" and peer:
        src = u"%s:%s" % (peer, src)
    elif t.get("direction") == "push" and peer:
        tgt = u"%s:%s" % (peer, tgt)
    pairs += [(_(u"Źródło"), src), (_(u"Cel"), tgt)]
    tot, dn, wire = int(t.get("total_bytes") or 0), int(t.get("done_bytes") or 0), int(t.get("wire_bytes") or -1)
    if t.get("state") == "running":
        rate, eta = int(t.get("rate_bps") or 0), int(t.get("eta_seconds") or -1)
        prog = u"%s z %s" % (human_bytes(dn), human_bytes(tot) if tot > 0 else _(u"nieznanej wielkości"))
        if tot > 0:
            prog += u" (%d%%)" % (dn * 100 // tot)
        prog += _(u", %s/s, zostało %s") % (human_bytes(rate), fmt_dur(eta) if eta >= 0 else "?")
        pairs.append((_(u"Postęp"), prog))
    else:
        pairs.append((_(u"Dane"), human_bytes(tot) if tot > 0 else (human_bytes(dn) if dn > 0 else _(u"0 B -- nic się nie zmieniło"))))
    if wire >= 0:
        pairs.append((_(u"Na łączu"), human_bytes(wire)))
    st, fin, upd = int(t.get("started_epoch") or 0), int(t.get("finished_epoch") or 0), int(t.get("updated_epoch") or 0)
    pairs.append((_(u"Start / koniec"), u"%s / %s" % (fmt_full(st), fmt_full(fin) if fin else (u"trwa, aktualizacja %s" % fmt_ago(upd, now)))))
    if note:
        pairs.append((_(u"Uwaga"), note))
    pairs.append((_(u"Proces"), u"pid %s" % t.get("pid", "?")))
    return pairs


def run_children(r, data, now, ch):
    """Dol PRZEBIEGOW: zrodlo -> cel kazdego datasetu biegu i, dla wykonanego, to,
    co historia transferow zapisala w jego czasie (stan, dane)."""
    if r.get("kind") != "run" or r.get("static"):
        return {"items": []}
    items, seen = [], set()
    prog = (data.progress or {}).get("jobs") or []
    for j in run_jobs(r):
        if True:
            src, dst = job_src_dst(j)
            key = (src, dst)
            if key in seen:
                continue
            seen.add(key)
            s_, d_ = (src or "").rsplit(":", 1)[-1], (dst or "").rsplit(":", 1)[-1]
            t = None
            if r.get("past"):
                lo, hi = (r.get("start") or r["at"]) - 120, (r.get("end") or now) + 60
                for x in prog:
                    st_ = int(x.get("started_epoch") or 0)
                    if lo <= st_ <= hi and (ds_of(x.get("dataset")) == s_ or (x.get("target") or "") == d_):
                        t = x
                        break
            b = run_dataset_bytes(r, j, data)
            items.append({"cells": [side_words(src) or u"-", side_words(dst) or u"-", hbytes_short(b) if b is not None else u"-"],
                          "pairs": transfer_detail_pairs(t, now, ch, data) if t else [(_(u"Źródło"), side_words(src, here_name(data)) or u"-"), (_(u"Cel"), side_words(dst, here_name(data)) or u"-")],
                          "title": u"%s -- %s" % (r["name"], s_ or d_)})
    return {"items": items}


def rel_children(tab, row, data, jobrows, now, ch):
    """F3: Datasety (pary zrodlo -> cel) albo Zadania (wiersze F2 tej relacji)."""
    if tab == "zad":
        items = []
        for jr in jobrows or []:
            if jr.get("kind") != "job" or jr.get("name") != row.get("name"):
                continue
            j = jr["job"]
            items.append({"cells": [jr.get("task") or "?", jr.get("pref") or "-", cron_words(jr.get("schedule") or j.get("schedule", "")),
                                    jr.get("keep") or "-", jr.get("next_disp") or (fmt_next_short(jr["next_epoch"], now) if jr.get("next_epoch") else "-"),
                                    jr.get("vword") or "-"],
                          "pairs": job_panel_pairs(jr, data, now, ch),
                          "title": u"%s -- %s %s" % (jr["name"], jr.get("task") or "", jr.get("pref") or ""), "jobrow": jr})
        return {"heads": [_(u"Zadanie"), _(u"Prefiks migawek"), _(u"Kiedy"), _(u"Trzyma"), _(u"Następny"), _(u"Kopie")], "items": items,
                "prio": [0, 5, 4, 2, 3, 1],
                "empty": _(u"brak zadań tej relacji w cronie")}
    pairs, how = rel_pairs(row, data, now, ch)
    snaps_only = bool(pairs) and all(p_.get("dst") is None for p_ in pairs)
    items = []
    for pr in pairs:
        items.append({"cells": [pair_one(pr, ch), pr["vword"], "%d" % pr.get("tiers", 1), pr["gb"]],
                      "pairs": pair_detail_pairs(pr, row, data, now, ch),
                      "title": u"%s -- dataset %s" % (row["name"], (pr.get("dst") or pr["src"]).split()[0]), "pair": pr,
                      "relname": row.get("name")})
    empty = _(u"brak datasetów: rekord nie nazywa żadnego źródła, a w cronie nie ma linii kopii tej relacji")
    return {"how": how, "heads": [_(u"Dataset") if snaps_only else _(u"Źródło %s cel") % ch.right, _(u"Migawki") if snaps_only else _(u"Kopie"),
                      _(u"Szczeble"), _(u"Dane 7 dni")], "items": items, "prio": [0, 1, 3, 2], "empty": empty}


def pair_detail_pairs(pr, row, data, now, ch):
    """Prawy panel datasetu relacji (F3, zakladka Datasety)."""
    out = [group(ch, _(u"Co"))]
    if pr.get("dst") is None:
        out.append((_(u"Dataset"), side_words(pr["src"])))
    else:
        out += [(_(u"Źródło"), side_words(pr["src"])), (_(u"Cel"), pr["dst"])]
    out.append(group(ch, _(u"Teraz")))
    v = pr.get("vword") or "-"
    j = pr.get("job")
    if j is not None:
        _v, reason = verdict_for_job(j, (data.monitors or {}).get("monitors", []))
        age = re.search(r"age=(\S+)", reason or "")
        if age:
            v += u"   najnowsza sprzed %s" % age.group(1)
    out.append((_(u"Migawki") if pr.get("dst") is None else _(u"Kopie"), v))
    last = None
    want = (pr.get("dst") or "").split()[0] if pr.get("dst") else pr["src"].split()[0].rsplit(":", 1)[-1]
    src_ds = pr["src"].split()[0].rsplit(":", 1)[-1]
    for t in (data.progress or {}).get("jobs", []):
        if t.get("label") != row.get("name"):
            continue
        if (t.get("target") or "") == want or ds_of(t.get("dataset")) in (src_ds, want):
            if last is None or int(t.get("started_epoch") or 0) > int(last.get("started_epoch") or 0):
                last = t
    if last:
        wd, _n = transfer_word(last, now)
        st_, fin = int(last.get("started_epoch") or 0), int(last.get("finished_epoch") or 0)
        out.append((_(u"Ostatni transfer"), u"%s   %s%s" % (wd, fmt_full(fin or st_), (u"   " + fmt_dur(fin - st_)) if fin and st_ else "")))
        out.append((_(u"Najnowsza"), (last.get("dataset") or "?").split("@", 1)[-1]))
    jobs = pr.get("jobs") or ([j] if j is not None else [])
    if jobs:
        out.append(group(ch, _(u"Szczeble")))
        for jj in jobs:
            _k = keep_cell(jj.get("retain") or jj.get("keep") or "")
            out.append((family_of(jj) or "?", cron_words(jj.get("schedule", "")) + ((_(u"   trzyma %s") % _k) if _k != "-" else "")))
    out.append(group(ch, _(u"Przebiegi (%s dni)") % ((data.stats or {}).get("window_days") or 7)))
    out.append((_(u"Czas"), pr.get("czas_words") or "-"))
    out.append((_(u"Dane"), pr.get("gb") or "-"))
    return out


def tpl_children(tab, p, rows, now, ch):
    """F5: Szczeble szablonu albo relacje, ktore go uzywaja."""
    if tab == "uz":
        items = []
        for r in rows or []:
            rel = r.get("rel") or {}
            if r.get("kind") != "relation" or rel.get("state") == "removed":
                continue
            side = None
            if rel.get("profile") == p.get("name"):
                side = _(u"ten host")
            elif rel.get("source_profile") == p.get("name"):
                side = _(u"źródło")
            if side is None:
                continue
            items.append({"cells": [r["name"], side, r.get("dir") or "?"],
                          "pairs": [(_(u"Relacja"), r["name"]), (_(u"Strona"), side), (_(u"Kierunek"), r.get("dir") or "?"),
                                    (_(u"Stan"), r.get("state") or "?"), (u"Zmiana szablonu", _(u"w zmianie relacji (ekran Relacje)"))],
                          "title": _(u"%s -- relacja %s") % (p.get("name"), r["name"])})
        return {"heads": [_(u"Relacja"), _(u"Strona"), _(u"Kierunek")], "items": items,
                "empty": _(u"żadna relacja na tym hoście nie używa tego szablonu")}
    items = []
    for t in p.get("tiers", []):
        keep = t.get("keep") or (t.get("retain") or "").lstrip("-") or _(u"wg drabiny")
        when = cron_words(t["send_schedule"]) if t.get("send_schedule") else \
            (_(u"porządki %s") % cron_words(t["prune_schedule"]) if t.get("prune_schedule") else _(u"bez własnych migawek"))
        fam = (t.get("prefix") or t.get("pattern") or "-").rstrip("_")
        pairs = [(_(u"Szczebel"), tier_unit(t.get("name", ""))), (_(u"Kiedy"), when), (_(u"Trzyma"), keep),
                 (_(u"Prefiks migawek"), fam), (_(u"Zamraża"), _(u"tak") if t.get("quiesce") else _(u"nie"))]
        if t.get("monitor_warn") or t.get("monitor_crit"):
            pairs.append((_(u"Strażnik"), _(u"ostrzeżenie po %s, alarm po %s") % (t.get("monitor_warn") or "?", t.get("monitor_crit") or "?")))
        items.append({"cells": [tier_unit(t.get("name", "")), when, keep, fam], "pairs": pairs,
                      "title": _(u"%s -- szczebel %s") % (p.get("name"), tier_unit(t.get("name", "")))})
    return {"heads": [_(u"Szczebel"), _(u"Kiedy"), _(u"Trzyma"), _(u"Prefiks migawek")], "items": items, "empty": _(u"szablon bez szczebli")}


def replica_run_bytes(x, r, data):
    """Ile wniosl bieg repliki: suma `written` migawek jej prefiksu (replica_) na zrodlach,
    powstalych po poprzednim biegu i nie pozniej niz koniec tego -- to przyrost, ktory bieg
    przeslal (wlasciciel 2026-10-29: kolumna Dane byla pusta). Replika bez wlasnej migawki
    (prefix "-", historia kolektora) i brak danych = None ("-")."""
    if not x.get("past") or "snaps" not in (data.stats or {}):
        return None
    pfx = r.get("prefix") or "replica_"
    if pfx == "-":
        return None
    srcs = r.get("sources") or ([r["source"]] if r.get("source") else [])
    hi = (x.get("end") or x["at"]) + 60
    lo = x.get("prev_end") or ((x.get("start") or x["at"]) - 3600)
    tot, hit = 0, False
    for ds, lst_ in snaps_index(data).items():
        if not any(ds == sr or ds.startswith(sr + "/") for sr in srcs):
            continue
        for cr, wr, sn in lst_:
            if lo < cr <= hi and sn.startswith(pfx):
                tot += wr
                hit = True
    return tot if hit else None


def rep_children(tab, r, data, now, ch, jobrows=None):
    """F6, dolna zakladka: PRZEBIEGI tej repliki jak na F2 -- wykonane, kreska "teraz",
    nadchodzace (wlasciciel 2026-10-29, U130: "Wzór to okno jobs"). Zrodlo -> cel stoi
    w prawym panelu (grupa Co)."""
    bar = u"\u2500\u2500 " if not ch.ascii else u"-- "
    rows = [x for x in build_runs(data, jobrows or [], now, True, False, past_h=PRZ_RUNS_H)
            if x.get("kind") == "now" or (x.get("item") or {}).get("kind") == "replica"
            and (x["item"].get("replica") or {}).get("name") == r.get("name")]
    if not any(x.get("kind") == "run" for x in rows):
        rows = []
    elif not any(x.get("kind") == "run" and x.get("past") for x in rows):
        rows = [x for x in rows if x.get("kind") != "now"]
    items = []
    for x in rows:
        if x.get("kind") == "now":
            items.append({"cells": [bar + _(u"teraz %s") % time.strftime("%H:%M", time.localtime(x["at"])), u" ", u" ", u" "],
                          "pairs": [], "title": r.get("name") or u""})
            continue
        czas = fmt_dur(x["end"] - x["start"]) if x.get("past") and x.get("start") and x.get("end") else u"-"
        rb = replica_run_bytes(x, r, data)
        items.append({"cells": [run_when(x["at"]), run_result(x), czas, hbytes_short(rb) if rb is not None else u"-"],
                      "pairs": run_pairs(x, now, ch), "title": _(u"%s -- bieg") % r.get("name")})
    return {"heads": [_(u"Kiedy"), _(u"Wynik"), _(u"Czas"), _(u"Dane")], "items": items, "prio": [0, 1, 3, 2],
            "empty": _(u"brak przebiegów tej repliki w oknie %dh wstecz i %dh naprzód (dysku nie było albo nie ma harmonogramu)")
            % (PRZ_RUNS_H, PRZ_AHEAD_H)}


def odz_children(tab, item, rows, data, now, ch):
    """F11: datasety, z ktorych mozna odzyskac (kopie relacji)."""
    if item.get("kind") == "disk":
        return {"heads": [_(u"Dataset")], "items": [],
                "empty": _(u"dysk i dataset wybierzesz po Enter, w oknie Przywróć (z dysków podłączonych do tego hosta)")}
    row = next((r for r in rows or [] if r.get("kind") == "relation" and r["name"] == item["name"]), None)
    pairs, _how = rel_pairs(row, data, now, ch) if row else ([], "")
    items = []
    for pr in pairs:
        copy = pr.get("dst") or pr["src"]
        last = newest_transfer(data, item["name"], copy, pr["src"])
        nw = fmt_when_short(int(last.get("finished_epoch") or last.get("started_epoch") or 0), now) if last else "-"
        dpairs = [(_(u"Kopia"), copy), (_(u"Oryginał"), side_words(pr["src"])), (_(u"Kopie"), pr.get("vword") or "-")]
        if last:
            dpairs.append((_(u"Najnowsza"), (last.get("dataset") or "?").split("@", 1)[-1]))
        dpairs.append((_(u"Najstarsza"), _(u"w oknach Przywróć (lista migawek)")))
        items.append({"cells": [copy, nw], "pairs": dpairs, "title": u"%s -- dataset %s" % (item["name"], copy),
                      "dataset": copy, "src": pr["src"]})
    return {"heads": [_(u"Kopia"), _(u"Najnowsza")], "items": items, "empty": _(u"brak datasetów z kopią")}


def newest_transfer(data, label, copy, src):
    src_ds = (src or "").split()[0].rsplit(":", 1)[-1]
    best = None
    for t in (data.progress or {}).get("jobs", []):
        if t.get("label") != label or t.get("state") == "running":
            continue
        if (t.get("target") or "") == copy or ds_of(t.get("dataset")) in (copy, src_ds):
            if best is None or int(t.get("finished_epoch") or 0) > int(best.get("finished_epoch") or 0):
                best = t
    return best


def job_panel_pairs(row, data, now, ch):
    """Prawy panel ZADANIA (F2 i F3 zakladka Zadania), U21: tylko to, czego lista nie
    ma, grupami Co / Przebiegi / Uprawnienia, bez dopiskow w nawiasach (wlasciciel
    2026-10-19: "wystarczy: Kierunek pve9 <- 192.168.28.98")."""
    j = row["job"]
    jobs_here = row.get("jobs") or [j]
    _dir = row.get("dir") or "?"
    pairs = [group(ch, _(u"Co")), (_(u"Kierunek"), _(u"lokalnie, na tym hoście") if _dir in ("local", _(u"lokalnie")) else _dir)]
    if len(jobs_here) > 1:
        # wspolny przedrostek RAZ, potem krotkie nazwy (R3-5)
        scopes = [(jj.get("scope", "") or "?").split(":")[-1] for jj in jobs_here]
        parts = [x.split("/") for x in scopes]
        common = []
        for seg in zip(*parts):
            if len(set(seg)) != 1:
                break
            common.append(seg[0])
        if parts and len(common) >= min(len(x) for x in parts):
            common = common[:-1]
        base = "/".join(common)
        short = ["/".join(x[len(common):]) or "/".join(x) for x in parts]
        pairs.append((_(u"Zakres"), _(u"%d datasetów%s: %s") % (len(jobs_here), (_(u" w ") + base) if base else "", ", ".join(short))))
    else:
        src, dst = job_src_dst(j)
        # U111: strony `pve9:hdd/enc` / `pve10:hdd/backups/...`, bez konta i adresu
        src, dst = side_words(src, here_name(data)), side_words(dst, here_name(data))
        d = j.get("direction", "")
        if d == "snaponly":
            pairs.append((_(u"Cel"), src))
        elif d == "prune" or u"prune" in (row.get("task") or ""):
            # Porzadki szczebla plaskiego siedza w zadaniu pobrania (uwaga 4) --
            # przycinaja jego CEL; harmonogram jest wiersza, nie zadania.
            pairs.append((_(u"Cel"), dst))
        else:
            pairs += [(_(u"Źródło"), src), (_(u"Cel"), dst)]
    pairs.append((_(u"Kiedy"), cron_words(row.get("schedule") or j.get("schedule", "?"))))
    # Wiersz transferu ma w kolumnie Trzyma "-" (retencja stoi w wierszu porzadkow), ale
    # panel mowi, ile kopia trzyma -- "-" przy "ab -- pobranie" nic nie mowilo (kampania 3).
    keep = row.get("keep") if row.get("keep") not in (None, "", "-") else ""
    keep = keep or keep_cell(j.get("retain") or j.get("keep") or "") or "-"
    pairs.append((_(u"Trzyma"), keep + (u"   drabina GFS" if j.get("gfs") else "")))
    st = data.stats or {}
    win = st.get("window_days")
    pairs.append(group(ch, (_(u"Przebiegi (%s dni)") % win) if win else _(u"Przebiegi")))
    srow, srows = row.get("srow"), row.get("srows") or []
    if data.failed("stats"):
        pairs.append((_(u"Czas"), _(u"? -- job-stats nie odpowiedział")))
    elif srow:
        pairs.append((_(u"Czas"), times_words(srow.get("last_s"), srow.get("avg_s"), srow.get("max_s"))))
    else:
        pairs.append((_(u"Czas"), _(u"brak biegów w dzienniku z tego okna%s") % ("" if row.get("clabel") else _(u" -- zadania nie ma w cronie"))))
    if len(srows) > 1 and not data.failed("stats"):
        newest = max(srows, key=lambda x: x.get("last_at") or "")
        pairs.append((_(u"Wywołania"), _(u"%d, błędów %d   w %d zadaniach") % (
            sum(int(x.get("runs") or 0) for x in srows), sum(int(x.get("failures") or 0) for x in srows), len(srows))))
        pairs.append((_(u"Ostatni"), u"%s   %s" % (dshow(newest.get("last_at", "?")), u"OK" if str(newest.get("last_rc")) == "0" else _(u"BŁĄD (rc=%s)") % newest.get("last_rc"))))
    elif srow and not data.failed("stats"):
        pairs.append((_(u"Wywołania"), _(u"%s, błędów %s") % (srow.get("runs", "?"), srow.get("failures", 0))))
        pairs.append((_(u"Ostatni"), u"%s   %s" % (dshow(srow.get("last_at", "?")), u"OK" if str(srow.get("last_rc")) == "0" else _(u"BŁĄD (rc=%s)") % srow.get("last_rc"))))
    for sc, (rc, at, txt) in row.get("fails") or []:
        pairs.append((_(u"Błąd"), u"%s  %s  rc=%s  %s" % (at, sc, rc, txt or _(u"(szczegóły w cron.log)"))))
    for sc, (at, txt) in sorted(row.get("discards") or [], key=lambda d: d[1][0], reverse=True)[:6]:
        pairs.append((_(u"Wyrzucono"), u"%s  %s" % (at, txt)))
    if row.get("vol") is not None and not data.failed("stats"):
        pairs.append((_(u"Dane"), hbytes_short(row["vol"])))
    mons, seen_mon = [], set()
    for jj in jobs_here:
        for m in monitors_for_job(jj, (data.monitors or {}).get("monitors", [])):
            key = (m.get("label", ""), m.get("pattern", ""))
            if key not in seen_mon:
                seen_mon.add(key)
                mons.append(m)
    if mons:
        m0 = mons[0]
        pairs.append((_(u"Strażnik"), _(u"ostrzeżenie po %s, alarm po %s   sprawdza %s") % (
            m0.get("warn") or "?", m0.get("crit") or "?", cron_words(m0.get("schedule") or "?"))))
    pairs.append(group(ch, _(u"Uprawnienia")))
    pairs.append((_(u"Konto"), j.get("account", "?")))
    pairs.append((_(u"Config"), j.get("config", "?")))
    return pairs


def rel_panel_pairs(row, data, now, ch):
    """Prawy panel RELACJI (F3), U21: najpierw "czy OK", potem liczby z okna,
    na koncu ustawienia; Stan, Typ i Kierunek sa w liscie, harmonogram i
    retencja -- w zakladce Zadania, zrodla i cele -- w zakladce Datasety."""
    if row["kind"] != "relation":
        return rel_detail_pairs(row, data, now, ch)
    rel = row["rel"]
    pairs = []
    warns = []
    if rel.get("endpoint_diverged"):
        warns.append(_(u"cron idzie przez %s, zapisany %s -- NIEwdrożony (verify-endpoint, activate-client)")
                     % (rel.get("installed_endpoint") or "?", rel.get("active_endpoint") or "?"))
    if rel.get("paused_local"):
        warns.append(_(u"relacja wstrzymana (pause-client); starzenie się kopii jest tu oczekiwane"))
    if rel.get("state") != "active" and rel.get("state") != "removed":
        warns.append(_(u"relacja nie jest aktywna: stan %s, następny krok: %s") % (rel.get("state"), next_step(rel).replace("NAME", row["name"])))
    if rel.get("state") == "removed":
        warns.append(_(u"rekord usunięty %s; kopie na dysku nie zostały ruszone") % dshow(rel.get("removed_at") or "?"))
    if rel.get("peer_pair_state") not in ("", "NOT_ASKED", None):
        warns.append(_(u"para po drugiej stronie: %s") % rel["peer_pair_state"])
    _seen = set()
    for m in row["monitors"]:
        if m.get("engine_path_differs"):
            w = _(u"cron uruchamia program z innego miejsca (%s) niż ten, którym GUI sprawdzało stan") % m.get("engine_in_cron")
            if w not in _seen:
                _seen.add(w)
                warns.append(w)
    for w_ in warns:
        pairs.append((_(u"Uwaga"), w_))
    pairs.append(group(ch, _(u"Teraz")))
    mon = row["vword"]
    if row["reasons"]:
        # Tylko wiek najnowszej -- surowy tekst monitora (po angielsku) jest w oknie (Enter).
        age = re.search(r"age=(\S+)", row["reasons"][0])
        if age:
            mon += u"   najnowsza sprzed %s" % age.group(1)
    elif row["verdict"] == "BEZ MONITORA" and rel.get("state") == "active":
        mon += _(u"   nikt nie sprawdza, czy kopia dalej się robi")
    if row["monitors"]:
        m0 = row["monitors"][0]
        mon += _(u"   alarm po %s") % (m0.get("crit") or "?")
    pairs.append((_(u"Migawki") if rel.get("mode") == "snaponly" else _(u"Kopie"), mon))
    last = row["last"]
    # U61: "Ostatni bieg OK" (historia transferow) stal obok "błąd biegu" (job-stats).
    # Nieudany ostatni bieg ktoregos zadania wygrywa i panel mowi, KTORY dataset i dlaczego.
    # One cron line can carry several datasets (pve2, 2026-10-27: subvol-103 and
    # ROOT/pve-1 in one snapget call). Every dataset job then reads the SAME
    # failure, so it counts once, and it is pinned on a dataset only when the
    # error text names it -- the panel blamed subvol-103 for a refusal on pve-1.
    fails, by_label = [], {}
    if rel.get("state") == "active":
        for j in row["jobs"]:
            if j.get("section_kind") in SEND_KINDS:
                f, _disc = job_run_issue(data, j)
                if f:
                    sc = scope_dataset(j.get("scope"))
                    lbl = job_cron_label(j)
                    if lbl in by_label:
                        by_label[lbl][0].append(sc)
                        continue
                    by_label[lbl] = ([sc], f)
                    fails.append(by_label[lbl])
    if fails:
        scs, f = fails[0]
        named = [s for s in scs if text_names_dataset(f[2] or "", s)]
        ds = named[0] if len(named) == 1 else u", ".join(scs)
        pairs.append((_(u"Ostatni bieg"), _(u"BŁĄD   %s   rc=%s%s") % (f[1], f[0], (u"   (+%d)" % (len(fails) - 1)) if len(fails) > 1 else u"")))
        pairs.append((_(u"Przyczyna"), u"%s: %s" % (ds, f[2] or _(u"zobacz cron.log"))))
    elif last:
        w, note = transfer_word(last, now)
        st_, fin = int(last.get("started_epoch") or 0), int(last.get("finished_epoch") or 0)
        txt = u"%s   %s" % (w, fmt_full(fin if fin else st_))
        if note:
            txt += u"   " + note
        pairs.append((_(u"Ostatni bieg"), txt))
    else:
        pairs.append((_(u"Ostatni bieg"), _(u"brak wpisu w historii transferów")))
    pairs.append((_(u"Następny"), fmt_full(row["next_epoch"]) if row["next_epoch"] and not rel.get("paused_local") else row["next"]))
    sends = [j for j in row["jobs"] if j.get("section_kind") in SEND_KINDS]
    stt = row.get("stats") or {}
    days = (data.stats or {}).get("window_days") or 7
    pairs.append(group(ch, _(u"Przebiegi (%d dni)") % days))
    if data.failed("stats"):
        pairs.append((_(u"Wywołania"), _(u"? -- job-stats nie odpowiedział")))
    elif "stats" in getattr(data, "pending", ()):
        pairs.append((_(u"Wywołania"), _(VERDICTS["SPRAWDZAM"][0])))
    elif sends and stt.get("runs"):
        pairs.append((_(u"Wywołania"), _(u"%d, błędów %d") % (stt["runs"], stt.get("fails") or 0)))
        pairs.append((_(u"Czas"), times_words(stt["last"], stt["avg"], stt["max"])))
        pairs.append((_(u"Dane"), row.get("gb") or "-"))
    else:
        pairs.append((_(u"Wywołania"), _(u"brak w dziennikach z tego okna")))
    pairs.append(group(ch, _(u"Ustawienia")))
    if rel.get("mode") == "local":
        pairs.append((_(u"Źródło"), ", ".join(rel.get("sources") or []) or "?"))
        pairs.append((_(u"Cel"), rel.get("client_target") or _(SNAP_TARGET)))
    else:
        # U111: nazwa; adres i port w zakladce Config okna relacji. Rozjazd adresu
        # crona z zapisanym zostaje -- to wlasnie fakt o adresie.
        ep = host_name(rel_addr(rel)) or "?"
        if rel.get("installed_endpoint") and rel.get("installed_endpoint") != rel.get("active_endpoint"):
            ep += _(u"   w cronie: %s") % rel["installed_endpoint"]
        pairs.append((_(u"Drugi host"), ep))
        if rel.get("mode") == "snaponly":
            pairs.append((_(u"Kopia"), _(u"brak -- migawki i ich retencja zostają na źródle")))
    accts = sorted({j.get("account", "") for j in row["jobs"] if j.get("account")})
    pairs.append((_(u"Konto"), rel.get("local_user") or ", ".join(accts) or "?"))
    prof = profile_word(rel.get("profile"), rel.get("name"))
    if rel.get("source_profile"):
        prof += _(u"   źródło: %s") % rel["source_profile"]
    pairs.append((_(u"Szablon"), prof))
    if rel.get("recursion"):
        pairs.append((_(u"Sposób"), {"flat": _(u"każdy dataset osobno"), "atomic": _(u"cała gałąź atomowo")}.get(rel["recursion"], rel["recursion"])))
    if rel.get("passive") == "1":
        pairs.append((_(u"Tryb"), _(u"pasywny")))
    if rel.get("bandwidth"):
        pairs.append((_(u"Łącze"), rel["bandwidth"]))
    prunes = [j for j in row["jobs"] if j.get("section_kind") == "prune"]
    if sends or prunes:
        pairs.append((_(u"Zadania"), _(u"%d: kopie lub migawki %d, porządki %d") % (len(sends) + len(prunes), len(sends), len(prunes))))
    if rel.get("created_at"):
        pairs.append((_(u"Powstała"), dshow(rel["created_at"])))
    for key, fld in ((_(u"Pełna kopia"), "seed_completed_at"), (_(u"Aktywna od"), "activated_at"), (_(u"Usunięta"), "removed_at")):
        if rel.get(fld):
            pairs.append((key, dshow(rel[fld])))
    return pairs


def render_zadania(data, rows, cursor, width, height, now, ch, message="", show_done=True, grouped=False, focus="list", pair_cursor=0):
    host = (data.jobs or {}).get("host") or "?"
    acts = screen_actions("zadania", show_done=show_done, grouped=grouped)
    if data.failed("jobs"):
        scr = Screen()
        scr.lines = [top_bar(data, width, now, ch.ascii, len(data.errors))] + box(ch, _(u"Przebiegi na %s") % host, source_error_body(ch, "jobs", data, "list-jobs"), width)
        scr.bars.add(0)
        while len(scr.lines) < height - 1:
            scr.lines.append(fit("", width))
        scr.lines = scr.lines[:height - 1]
        push_key_bar(scr, "zadania", width, acts)
        return scr
    bar = u"|" if ch.ascii else u"\u2502"
    cells = []
    for r in rows:
        if r["kind"] == "now":
            cells.append([(u"-- " if ch.ascii else u"\u2500\u2500 ") + _(u"teraz %s") % time.strftime("%H:%M", time.localtime(r["at"])), u" ", u" ", u" ", u" ", u" "])
        elif r["kind"] == "grp":
            it = r["item"]
            cells.append([(u"> " if ch.ascii else u"\u25b8 ") + r["name"], it.get("dir") or u" ", u" ", _(u"błąd biegu") if r["bad"] else u" ", u" ", u" "])
        else:
            it = r["item"]
            # Na jednej osi czasu Co mowi tez, KTORYCH datasetow (pve10: dwa 'ab lokalny prune
            # hourly' o 07:15 -- vms i data -- byly nie do odroznienia); w grupie to robi Zadanie.
            co = (u"%s %s" % (it.get("task") or u"", u"" if grouped else job_id_cell(r["items"], r.get("jobs")))).strip() if it.get("kind") == "job" else \
                (_(u"replika") if it.get("kind") == "replica" else (it.get("task") or u"-"))
            czas = fmt_dur(r["end"] - r["start"]) if r.get("past") and r.get("start") and r.get("end") else u"-"
            when = run_when(r["at"])
            rb = run_bytes(r, data)
            cells.append([(u"    %s " % bar + when) if grouped and not r.get("static") else when,
                          job_id_cell(r["items"], r.get("jobs")) if grouped and not r.get("static") else r["name"],
                          co, run_result(r), czas, hbytes_short(rb) if rb is not None else u"-"])
    n_runs = len([r for r in rows if r["kind"] == "run"])
    title = _(u"Przebiegi na %s -- %s%s") % (
        host, _(u"wykonane %dh i nadchodzące %dh") % (PRZ_PAST_H, PRZ_AHEAD_H) if show_done else _(u"tylko nadchodzące"),
        _(u", po relacjach") if grouped else u"")
    det_title, det, child = u"", [], None
    if rows and 0 <= cursor < len(rows) and rows[cursor]["kind"] == "run":
        r = rows[cursor]
        it = r["item"]
        det_title = u"%s -- %s" % (r["name"], job_id_cell(r["items"], r.get("jobs")))
        if r.get("static"):
            det_title = u"%s -- %s" % (r["name"], it.get("task") or u"")
            det = rel_detail_pairs(it, data, now, ch)
        elif it["kind"] == "replica":
            det = run_pairs(r, now, ch) + replica_detail_pairs(it["replica"], ch, it["srow"], data.failed("stats"))
        else:
            one = dict(it)
            one["jobs"] = run_jobs(r)
            one["job"] = one["jobs"][0]
            if r.get("label") and r["label"] != it.get("clabel"):
                # panel liczy przebiegi TEJ linii crona, nie pierwszej z wiersza zadania
                srow, vol = job_stats_for(data, one["job"], r["label"])
                one.update({"clabel": r["label"], "srow": srow, "srows": [srow] if srow else [], "vol": vol, "fails": [], "discards": []})
            det = run_pairs(r, now, ch) + job_panel_pairs(one, data, now, ch)
        kids = run_children(r, data, now, ch) if not r.get("static") else {"items": []}
        child = {"name": det_title, "tabs": TABS["zadania"], "ti": 0, "items": kids["items"],
                 "heads": [_(u"Źródło"), _(u"Cel"), _(u"Dane")], "prio": [0, 1, 2], "rows": 5,
                 "empty": _(u"brak datasetów tego zadania")}
    empty = [_(u"Brak zadań zfs-backup na tym hoście (nie ma relacji albo jej config jest nieczytelny)."),
             _(u"Nową relację zakładasz na F3 Relacje: Ins.")]
    foot = (_(u"Enter pełne okno zadania   Tab do źródło → cel")) if n_runs else ""
    return render_tabbed(data, width, height, now, ch, "zadania", title,
                         [_(u"Kiedy"), _(u"Zadanie") if grouped else _(u"Relacja"), _(u"Co"), _(u"Wynik"), _(u"Czas"), _(u"Dane")], cells, cursor, foot,
                         det_title, det, child, focus, pair_cursor, acts, empty, prio=[0, 1, 3, 2, 5, 4], flex=1)


def summarize(rows):
    """Jedno zdanie o calym hoscie."""
    live = [r for r in rows if r["kind"] != "relation" or r["rel"].get("state") != "removed"]
    if not live:
        return _("brak relacji")
    counts = {}
    for r in live:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    n = plural(len(live), _("relacja"), _("relacje"), _("relacji"))
    if list(counts) == ["OK"]:
        return _("%s, wszystkie kopie aktualne") % n
    parts = ["%d %s" % (counts[v], _(VERDICTS[v][0])) for v in VERDICT_ORDER if counts.get(v)]
    return "%s: %s" % (n, ", ".join(parts))


def plural(n, one, few, many):
    """"1 relacja", "2 relacje", "5 relacji" -- ekran jest po polsku."""
    if n == 1:
        return "1 %s" % one
    last, last2 = n % 10, n % 100
    if 2 <= last <= 4 and not (12 <= last2 <= 14):
        return "%d %s" % (n, few)
    return "%d %s" % (n, many)


# ---------------------------------------------------------------------------
# EKRANY: STAN -> LINIE
# ---------------------------------------------------------------------------
class Screen(object):
    """Wynik rysowania: linie tekstu plus indeksy do pokolorowania.

    `cursor_y` -- linia z kursorem (curses odwraca ja), `bars` -- linie paskow
    (tytul i F-klawisze), `titles` -- linie krawedzi ramek."""

    def __init__(self):
        self.lines, self.cursor_y, self.bars, self.titles, self.cmd_y = [], None, set(), set(), None
        self.cursor_span = None   # (od, do): odwrocony tylko ten zakres linii (dwa panele, F4)
        self.marks = {}   # linia -> [(od, do, "active"|"key")]: pasek F (aktywne okno, cyfry)


def guard_states(settings_file=None, confs=None):
    """Stan strażników HOSTA (właściciel 2026-10-21, U35/U50): bezpiecznik pojemności
    ([capacity] guard) i strażnik przyrostu ([growth] alert) -> (on|off, on|off). To samo
    źródło, z którego czytają skrypty w cronie (alert-env.sh): settings.ini (F10), a gdy
    klucza tam nie ma -- stary zfs-alert.conf; domyślnie off. Nieczytelny plik -> "?"."""
    import os, re
    sf = settings_file or os.environ.get("SETTINGS_FILE") or "/etc/zfs-snapshot-all/settings.ini"
    confs = confs if confs is not None else ["/etc/zfs-alert.conf", "/root/scripts/zfs-alert.conf"]
    want = {("capacity", "guard"): "ZFS_GUARD", ("growth", "alert"): "ZFS_GROWTH_ALERT"}
    got = {}
    try:
        with open(sf, encoding="utf-8") as f:
            sec = "engine"
            for line in f:
                line = line.split("#", 1)[0].strip()
                m = re.match(r"^\[([A-Za-z0-9_]+)\]$", line)
                if m:
                    sec = m.group(1); continue
                if "=" in line:
                    k, v = [x.strip() for x in line.split("=", 1)]
                    if (sec, k) in want and v:
                        got.setdefault((sec, k), v)
    except FileNotFoundError:
        pass
    except OSError:
        return ("?", "?")
    for c in confs:
        if all(k in got for k in want):
            break
        try:
            with open(c, encoding="utf-8") as f:
                for line in f:
                    m = re.match(r'^\s*(ZFS_GUARD|ZFS_GROWTH_ALERT)=["\']?([A-Za-z]+)', line)
                    if m:
                        for k, var in want.items():
                            if var == m.group(1):
                                got.setdefault(k, m.group(2))
            break
        except FileNotFoundError:
            continue
        except OSError:
            return ("?", "?")
    return tuple(got.get(k, "off") for k in (("capacity", "guard"), ("growth", "alert")))


def guard_label(states):
    pl = {"on": _(u"wł."), "off": _(u"wył.")}
    cap, gro = states
    # U119: "ochrona: bezpiecznik · przyrost" bylo zargonem -- slowa mowia, co strażnik
    # ROBI (kasuje przy pelnej puli / alarmuje przy skoku danych), jak sekcje F10.
    return _(u"kasowanie przy pełnej puli: %s · alarm przyrostu: %s") % (pl.get(cap, u"?"), pl.get(gro, u"?"))


def top_bar(data, width, now, ascii_only, err_count):
    host = (data.jobs or {}).get("host") or "(host?)"
    ip = getattr(data, "host_ip", None)
    jobs = (data.jobs or {}).get("jobs", [])
    accounts = sorted({j.get("account", "") for j in jobs} |
                      {u.get("account", "") for u in (data.jobs or {}).get("unreadable", [])})
    acct = ", ".join(a for a in accounts if a) or _("(brak bloku)")
    left = " zfs-snapshot-all"
    mid = _("%s%s | konto %s%s") % (host, (" " + ip) if ip else "", acct,
                                  _(u"   ! bez odpowiedzi: %d") % err_count if err_count else "")
    right = _(u"odczyt %s ") % time.strftime("%H:%M:%S", time.localtime(data.read_at or now))
    # Stan strażników hosta przed czasem odczytu -- odpada pierwszy, gdy ciasno.
    guards = guard_label(getattr(data, "guards", None) or guard_states()) + u"   "
    if width - len(left) - len(mid) - len(right) - len(guards) >= 2:
        right = guards + right
    # Autor przy nazwie programu (właściciel 2026-10-25) -- tylko gdy zostaje miejsce;
    # odpada przed faktami i strażnikami, więc przy 80 kolumnach nagłówek się nie zmienia.
    credit = u" by Wojciech Król (Adalbert King)"
    if width - len(left) - len(credit) - len(mid) - len(right) >= 4:
        left += credit
    gap = width - len(left) - len(mid) - len(right)
    if gap < 2:
        # Ciasno: nazwa programu odpada, fakty (host, konto, blad) zostaja.
        line = fit(" " + mid + "  " + right, width)
    else:
        line = left + " " * (gap // 2) + mid + " " * (gap - gap // 2) + right
    return fit(line, width)


# KLAWISZE F (R4-1/R4-2, wlasciciel 2026-09-24): F1-F6 i F11 to GLOWNE OKNA, F12
# wyjscie, a F7/F8/F9 to AKCJE BIEZACEGO OKNA, podpisane w listwie (styl mc).
# Litery NIE sa skrotami: kazdy drukowalny znak idzie do linii polecen (bash)
# -- 'u' na F4 i 's' na F2 z rundy 3 byly martwe w prawdziwym GUI, bo petla
# curses oddawala je linii, zanim ekran je zobaczyl. Odswiez przeszlo z F9 na
# F5 (wolne po zniesieniu Monitora), zeby F9 bylo trzecia akcja okna.
def screen_actions(active, hide_gone=False, paused=False, show_done=True, grouped=False):
    """[(klawisz, podpis)] akcji okna -- JEDNO zrodlo dla listwy i dla pomocy.
    Na F3 podpis F7 mowi, co klawisz ZROBI z zaznaczona relacja: na
    wstrzymanej -- Wznow (tester R4, B6: listwa mowila Pauza, a F7 wznawial)."""
    if active == "zadania":
        return [("F7", u"Uruchom teraz", u"Uruchom"), ("F8", u"Schowaj wykonane" if show_done else u"Pokaż wykonane", u"Wykonane"),
                ("F9", u"Jedna oś czasu" if grouped else u"Grupuj po relacji", u"Grupuj")]
    if active == "relacje":
        # JEDNOLICIE (wlasciciel 2026-10-17): F7 to wszedzie "Uruchom teraz" -- na F3
        # kopia kazdego datasetu relacji jej najdrobniejszym zadaniem (run-relation).
        # Pauza przeszla na F8, Eksport i Import dziela F9 (okienko wyboru).
        return [("F7", u"Uruchom teraz", u"Uruchom"), ("F8", u"Włącz" if paused == "disabled" else (u"Wznów" if paused else u"Pauza")),
                ("F9", u"Eksport/Import", u"Plik")]
    if active == "odzysk":
        # KOPIE (U82): Enter przeglada (migawka RO + mc), F9 przywraca -- ten sam wybor zrodla.
        # F8 grupuje po relacji jak F9 na F2 (wlasciciel 2026-10-29: „tak jak F2 -- wszystkie
        # mozliwosci”); F9 zostaje Przywroc, wiec grupowanie jest tu pod F8.
        return [("F7", u"Przeglądaj", u"Przeglądaj"), ("F8", u"Jedna lista" if grouped else u"Grupuj po relacji", u"Grupuj"),
                ("F9", u"Przywróć", u"Przywróć")]
    if active == "nosniki":
        # Krótkie (3. pole) tylko, gdy pasek się nie mieści: przy 80 kolumnach F9 wypychał F10.
        # "Przywróć z dysku" przeszedł na F11 Odzysk (właściciel 2026-10-18).
        return [("F7", u"Uruchom teraz", u"Uruchom"), ("F8", u"Klucz")]
    return []


def key_bar_parts(active, width, actions=()):
    """Pasek klawiszy F (wlasciciel 2026-10-09, uwaga 4: "wszystkie informacje o
    klawiszach F w calym pakiecie na niebieskim pasku, a na dolnej ramce jedynie
    unikalne dla okna inne niz F"; "trzeba to zrobic poprawnie bez dubli").
    JEDYNE miejsce, gdzie ekran mowi o F: F1, okna F2-F6, akcje okna F7-F9, F11 Odzysk i F12 --
    zawsze wszystkie, przy kazdej szerokosci. Aktywne okno bez [nawiasow]: zaznacza
    je kolor (marks). Gdy pelny zapis sie nie miesci, zapis skrocony jak w Norton
    Commanderze: cyfra (w kolorze) + nazwa, bez litery F.
    -> (linia, [(od, do, "active"|"key")])"""
    items = [("F1", u"Pomoc", None)]
    for key, fk, label in SCREENS:
        items.append((fk, label, key))
    items += [(a[0], a[1], None) for a in actions]
    # F11 Odzysk, F12 Wyjście (właściciel 2026-10-18); F10 wolne. Kolejność numerów.
    items.append(("F10", u"Ustawienia", None))   # okno ustawień hosta (2026-10-19)
    items.append(("F12", u"Wyjście", None))
    items.sort(key=lambda it: int(it[0][1:]))
    short = dict((a[0], a[2]) for a in actions if len(a) > 2)
    # Najciasniej (80 kolumn, F3 z trzema akcjami i F11): skroty okien i wyjscia --
    # tylko gdy nic innego sie nie miesci, zeby F12 nigdy nie wypadlo z paska.
    # Listwa to dolny wiersz ekranu, a curses nie pisze w jego ostatnia kolumne (prawy dolny
    # rog) -- pasek musi sie zmiescic w width - 1 (kampania 3: F4 ucinal "Ctrl-R Odświe").
    room = width - 1
    tight = {"F2": u"Przeb", "F4": u"Kopie", "F5": u"Szabl", "F10": u"Ust", "F12": u"Wyjdź", "F6": u"Repl", "F3": u"Rel"}
    if LANG_CAT:
        tight = {"F2": u"Runs", "F4": u"Copy", "F5": u"Tmpl", "F10": u"Set", "F12": u"Quit", "F6": u"Repl", "F3": u"Rel"}
    items = [(fk, _(label), key) for fk, label, key in items]
    short = dict((k, _(v)) for k, v in short.items())
    for compact, sep, brief in ((False, u" ", False), (True, u" ", False), (True, u"", False), (True, u"", True),
                                (True, u"", "tight")):
        line, marks = u" ", []
        for fk, label, key in items:
            if brief and fk in short:
                label = short[fk]
            if brief == "tight" and fk in tight:
                label = tight[fk]
            if line.strip():
                line += sep
            start = len(line)
            num = fk[1:] if compact else fk
            line += num + (u"" if compact else u" ") + label
            if compact:
                marks.append((start, start + len(num), "key"))
            if key == active:
                marks.append((start, len(line), "active"))
        if len(line) <= room:
            break
    if room >= len(line) + 16:
        line += u"  Ctrl-R " + _(u"Odśwież")
    if room >= len(line) + 16:
        line += u"  Ctrl-O " + _(u"Konsola")
    return fit(fit(line, room), width), marks   # dopelniona do width: kazdy wiersz ma szerokosc ekranu


def show_console(stdscr):
    """Ctrl-O (U90): zejdz z okien do zwyklego ekranu terminala -- tam zostalo wyjscie
    polecen, ktore okna uruchamialy -- i wroc po dowolnym klawiszu."""
    import curses
    import termios
    import tty
    curses.def_prog_mode()
    curses.endwin()
    sys.stdout.write("\n" + _(u"-- konsola pod oknami: dowolny klawisz wraca --") + "\n")
    sys.stdout.flush()
    fd = sys.stdin.fileno()
    try:
        old = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            os.read(fd, 16)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
    except (termios.error, OSError, ValueError):
        pass
    curses.reset_prog_mode()
    stdscr.clear()
    stdscr.refresh()


def push_key_bar(scr, active, width, actions=()):
    line, marks = key_bar_parts(active, width, actions)
    scr.lines.append(line)
    y = len(scr.lines) - 1
    scr.bars.add(y)
    scr.marks[y] = marks


def key_bar(active, width, extra=""):
    """Sama linia paska (testy i stare wywolania); akcje okna przez push_key_bar."""
    return key_bar_parts(active, width)[0]


def source_error_body(ch, key, data, verb):
    """Zepsute zrodlo to komunikat, nie pusta tabela (kontrola ujemna etapu B)."""
    return [_(u"błąd źródła: %s --json nie odpowiedział poprawnym JSON-em.") % verb,
            "", fit(u"  %s" % data.errors[key], 200),
            "", _(u"Ten ekran nie ma z czego rysować. Zobacz pełny błąd komendą:"),
            # NAZWIJ KOMENDE, nie kategorie. "Uruchom czasownik recznie" kazalo
            # operatorowi zgadnac, ktory to czasownik i z jaka flaga -- a ekran
            # zna jedno i drugie. Ten sam idiom, co w odmowach CLI w tym projekcie.
            u"    zfs-backup.sh %s --json" % verb]


def detail_kv(ch, pairs, width):
    """Panel klucz: wartosc; wartosc lamana, klucz tylko przy pierwszej linii.

    Para ("", "") to PUSTY ODSTEP MIEDZY GRUPAMI (R3-3/R3-5, uwagi wlasciciela
    2026-09-24), nie zwykly wiersz -- inaczej wyszlaby z niej pusta kolumna
    klucza (same spacje szerokosci kw) zamiast prawdziwie pustej linii."""
    kw = max([len(k) for k, _ in pairs if k] + [8])
    out = []
    for k, v in pairs:
        if k == "" and v == "":
            out.append("")
            continue
        if k == "":
            # NAGLOWEK GRUPY (U21): "-- Teraz", "-- Przebiegi (7 dni)". U98 (wlasciciel 2026-10-27:
            # "panele naćpane, już raz rozdzielaliśmy pustymi wierszami"): pusta linia przed grupa.
            if out and out[-1] != "":
                out.append("")
            out.append(u"%s %s" % ((ch.sh if ch else "-") * 2, v))
            continue
        chunks = wrap(u"%s" % v, max(10, width - kw - 2)) or [""]
        for i, c in enumerate(chunks):
            out.append("%s %s" % (fit(k if i == 0 else "", kw), c))
    return out


def side_by_side(left, right, width, ch):
    """Panel obok listy: lista zajmuje tyle, ile jej ramka, panel reszte.
    Szerokosc brana Z RAMKI, nie liczona drugi raz: dwie kopie tej samej
    proporcji rozjechaly sie przy probie 65% dla F2 i lista wyszla ucieta."""
    lw = len(left[0]) if left else max(MIN_WIDTH, int(width * 0.6))
    rw = width - lw
    n = max(len(left), len(right))
    left = left + [""] * (n - len(left))
    right = right + [""] * (n - len(right))
    return [fit(l, lw) + fit(r, rw) for l, r in zip(left, right)]


# --- Relacje ---------------------------------------------------------------
def rel_detail_pairs(row, data, now, ch):
    rel = row.get("rel")
    if row["kind"] == "unreadable":
        return [("blok", "%s -- config nieczytelny, %s" % (row["name"], row["last_txt"])),
                (_(u"powód"), row["reasons"][0] if row["reasons"] else "?")]
    if row["kind"] == "monitor":
        # STRAZNIK BEZ ZADANIA (uwaga 4b, F5 zniesiony): linia monitora, ktora
        # nie dopasowala sie do zadnego zadania na F2 -- reszta jej szczegolow
        # jest tym samym, co dawal usuniety ekran Monitor.
        return monitor_detail_pairs(row["m"], ch, full=True)
    if row["kind"] == "job":
        return job_panel_pairs(row, data, now, ch)
    srcs = rel.get("sources", [])
    pairs = [(_(u"Źródła (%d)") % len(srcs), ",  ".join(side_words(x) for x in srcs) or "?")]
    tgt = rel.get("client_target", "?")
    md = rel.get("managed_datasets", [])
    pairs.append((_("Cel"), tgt + ("   -> %s" % ", ".join(md) if md else "")))
    prof = rel.get("profile") or "?"
    if rel.get("source_profile"):
        prof += _(u"   źródło: %s") % rel["source_profile"]
    rec = rel.get("recursion") or ""
    pairs.append((_("Polityka"), prof + ("   rekursja %s" % rec if rec else "")
                  + ("   pasywna" if rel.get("passive") == "1" else "")
                  + (_(u"   łącze %s") % rel["bandwidth"] if rel.get("bandwidth") else "")))
    last = row["last"]
    if last:
        w, note = transfer_word(last, now)
        st, fin = int(last.get("started_epoch") or 0), int(last.get("finished_epoch") or 0)
        mode = {"incremental": "przyrostowy", "full": _(u"pełny")}.get(last.get("mode", ""), last.get("mode", ""))
        base = last.get("base", "")
        txt = "%s  %s" % (w, fmt_full(fin if fin else st))
        if fin and st:
            txt += "  %s" % fmt_dur(fin - st)
        txt += "  %s" % mode
        if note:
            txt += "  " + note
        pairs.append((_("Ostatni bieg"), txt))
    else:
        pairs.append((_("Ostatni bieg"), _(u"brak zapisu w historii -- stan nieznany")))
    if row["next_epoch"]:
        pairs.append((_(u"Następny"), "%s  (wg crontaba, %s)" % (
            fmt_full(row["next_epoch"]), ", ".join(sorted({j.get("schedule", "") for j in row["jobs"] if j.get("section_kind") in SEND_KINDS})))))
    else:
        pairs.append((_(u"Następny"), row["next"]))
    mon = row["vword"]
    if row["monitors"]:
        m0 = row["monitors"][0]
        mon += "   progi %s / %s" % (m0.get("warn") or "?", m0.get("crit") or "?")
    if row["reasons"]:
        # Jedna linia w panelu; pelny tekst monitora jest w oknie (Enter).
        mon += "   " + row["reasons"][0].splitlines()[0]
    elif row["verdict"] == "BEZ MONITORA" and rel.get("state") == "active":
        mon += _(u"   nikt nie sprawdza, czy kopia dalej się robi")
    warns = []
    if rel.get("endpoint_diverged"):
        warns.append(_(u"cron idzie przez %s, zapisany %s -- NIEwdrożony (verify-endpoint, activate-client)")
                     % (rel.get("installed_endpoint") or "?", rel.get("active_endpoint") or "?"))
    if rel.get("paused_local"):
        warns.append(_(u"relacja wstrzymana (pause-client); starzenie się kopii jest tu oczekiwane"))
    if rel.get("state") != "active" and rel.get("state") != "removed":
        warns.append(_(u"relacja nie jest aktywna: stan %s, następny krok: %s") % (rel.get("state"), next_step(rel).replace("NAME", row["name"])))
    if rel.get("state") == "removed":
        warns.append(_(u"rekord usunięty %s; kopie na dysku nie zostały ruszone") % dshow(rel.get("removed_at") or "?"))
    # JEDNO OSTRZEZENIE NA FAKT, nie na monitor. Relacja ma monitor na kazdy
    # szczebel, wiec ta sama uwaga o innym pliku silnika wchodzila do panelu
    # cztery razy i wypychala z niego Stan, Typ i Kierunek (pve10, 2026-09-21).
    _seen = set()
    for m in row["monitors"]:
        if m.get("engine_path_differs"):
            w = _(u"cron uruchamia program z innego miejsca (%s) niż ten, którym GUI sprawdzało stan") % m.get("engine_in_cron")
            if w not in _seen:
                _seen.add(w)
                warns.append(w)
    if warns:
        pairs.append((_("Uwaga"), "  |  ".join(warns)))
    pairs.append((_(u"Migawki") if row.get("mode") == "snaponly" else _("Kopie"), mon))
    return pairs


def rel_pairs(row, data, now, ch):
    """Pary zrodlo -> cel podswietlonej relacji (dolny panel F3).

    Wlasciciel, 2026-09-11: relacji jest malo, datasetow w relacji moze byc
    duzo -- pary maja swoj panel. Prawda pochodzi z linii crona (list-jobs,
    te same wiersze co F2); relacja bez crona (pending, seeding) dostaje pary
    policzone z rekordu i JEST TO NAPISANE w tytule panelu."""
    monitors = (data.monitors or {}).get("monitors", [])
    out = []
    jobs = [j for j in row.get("jobs", []) if j.get("section_kind") in SEND_KINDS]
    if jobs:
        for j in jobs:
            src, dst = job_src_dst(j)
            # MIGAWKI (wlasciciel 2026-10-18, "nie rozumiem tej listy"): bez kopii nie ma
            # celu, wiec wiersz to sam dataset; przy migawkach zdalnych zakres crona
            # "konto@host:dataset" rozbity na dataset i host, jak mowi czlowiek.
            if j.get("direction") == "snaponly":
                _sc = j.get("scope", "") or "?"
                _h = host_name(_sc.rsplit(":", 1)[0].split("@", 1)[-1]) if ":" in _sc else ""
                src = _sc.rsplit(":", 1)[-1] + ((_(u"   na %s") % _h) if _h else "")
                dst = None
            elif dst == "-":
                dst = None
            v, _reason = verdict_for_job(j, monitors)
            if v == "BEZ MONITORA" and "monitors" in getattr(data, "pending", ()):
                v = "SPRAWDZAM"
            # U61 (kampania 2026-10-21): wiersz relacji mowil "błąd biegu", a wiersz jej
            # datasetu "aktualne" -- ten sam fakt (nieudany ostatni bieg TEGO zadania) ma
            # dawac ten sam werdykt w obu miejscach.
            if (row.get("rel") or {}).get("state") == "active":
                _fail, _disc = job_run_issue(data, j)
                if _fail:
                    v = worst([v, "BLAD"])
            srow, vol = job_stats_for(data, j, job_cron_label(j))
            if data.failed("stats"):
                czas, gb = "?", "?"
            elif "stats" in getattr(data, "pending", ()):
                czas, gb = u"…", u"…"
            else:
                czas = times_cell(srow.get("last_s"), srow.get("avg_s"), srow.get("max_s")) if srow else "-"
                gb = hbytes_short(vol) if vol is not None else "-"
            out.append({"src": src, "dst": dst, "job": j, "v": v, "vword": _(VERDICTS.get(v, (v, 0))[0]),
                         "czas": czas, "gb": gb, "vol": vol, "tiers": 1, "jobs": [j],
                         "czas_words": "?" if data.failed("stats") else (times_words(srow.get("last_s"), srow.get("avg_s"), srow.get("max_s")) if srow else "-")})
        # JEDEN WIERSZ = JEDEN DATASET, nie jedna linia crona (2026-09-21).
        # Relacja z czterema szczeblami nad jednym datasetem rysowala ten sam
        # `zrodlo -> cel` CZTERY RAZY i nazywala to "4 pary" -- osiem linii ekranu
        # na powiedzenie jednej rzeczy, i do tego nieprawdziwa liczba. Szczeble sa
        # faktem o HARMONOGRAMIE, nie o tym, co z czym jest sparowane; panel zlicza
        # je w kolumnie, werdykt bierze NAJGORSZY (zeby jeden spozniony szczebel nie
        # znikl za trzema aktualnymi), a wolumen sumuje.
        grouped, order = {}, []
        for r in out:
            key = (r["src"], r["dst"])
            if key not in grouped:
                grouped[key] = r
                order.append(key)
                continue
            g = grouped[key]
            g["tiers"] += 1
            g["jobs"].append(r["job"])
            if g.get("czas_words") in ("-", "?") and r.get("czas_words") not in ("-", "?", None):
                g["czas_words"] = r["czas_words"]
            # NAJGORSZY liczony przez worst(), nie przez druga kolumne VERDICTS --
            # ta jest numerem KOLORU (OK=2, CRITICAL=1), wiec porownanie jej dalo
            # by "najgorszy = najjasniejszy". Zlapane przy czytaniu wlasnego diffu.
            g["v"] = worst([g["v"], r["v"]])
            g["vword"] = _(VERDICTS.get(g["v"], (g["v"], 0))[0])
            if g.get("vol") is not None and r.get("vol") is not None:
                g["vol"] = g["vol"] + r["vol"]
                g["gb"] = hbytes_short(g["vol"])
            if r["czas"] not in ("-", "?") and g["czas"] in ("-", "?"):
                g["czas"] = r["czas"]
        return [grouped[k] for k in order], "wg crona"
    if row.get("kind") != "relation":
        return out, ("blok nieczytelny" if row.get("kind") == "unreadable" else "wg crona")
    rel = row.get("rel") or {}
    peer = rel.get("peer_host") or "?"
    tgt = rel.get("client_target") or "?"
    for src in rel.get("sources", []):
        bare = src.split(":", 1)[1] if ":" in src else src
        if rel.get("mode") == "snaponly" or (rel.get("mode") == "local" and not rel.get("client_target")):
            out.append({"src": bare + ((_(u"   na %s") % host_name(peer)) if rel.get("mode") == "snaponly" else ""), "dst": None,
                        "job": None, "vword": "--", "czas": "-", "gb": "-"})
            continue
        # katalog kopii z REKORDU (landing), nie z adresu: po zmianie adresu peer_host
        # i katalog sie roznia (U111)
        out.append({"src": side_words(src if ":" in src else "%s:%s" % (peer, src)), "dst": "%s/%s/%s" % (tgt, rel.get("landing") or peer, bare),
                    "job": None, "vword": "--", "czas": "-", "gb": "-"})
    return out, _("wg rekordu, nie crona")


# Cel relacji BEZ KOPII (wlasciciel 2026-10-18: "celem migawek jest ten sam dataset");
# "?" albo "brak" mylily -- cel jest, to zrodlo.
SNAP_TARGET = u"ten sam dataset (migawki, bez kopii)"


def pair_one(pr, ch):
    """Wiersz dolnego panelu F3: `zrodlo -> cel`, a bez kopii (migawki) sam dataset."""
    if pr.get("dst") is None:
        return pr["src"]
    return u"%s %s %s" % (side_words(pr["src"]), ch.right, pr["dst"])


def render_relacje(data, rows, cursor, width, height, now, ch, message="", focus="list", pair_cursor=0, jobrows=None, ti=0):
    """F3 wg reguly U21: lista relacji, panel relacji (albo zaznaczonego dziecka),
    na dole zakladki Datasety / Zadania."""
    host = (data.jobs or {}).get("host") or (data.status or {}).get("host") or "?"
    _crel = (rows[cursor].get("rel") or {}) if rows and 0 <= cursor < len(rows) else {}
    _paused = "disabled" if _crel.get("disabled") else bool(_crel.get("paused_local"))
    _acts = screen_actions("relacje", paused=_paused)
    if data.failed("status"):
        scr = Screen()
        body = source_error_body(ch, "status", data, "status")
        scr.lines = [top_bar(data, width, now, ch.ascii, len(data.errors))] + box(ch, _("Relacje na kolektorze %s") % host, body, width)
        scr.bars.add(0)
        while len(scr.lines) < height - 1:
            scr.lines.append(fit("", width))
        scr.lines = scr.lines[:height - 1]
        push_key_bar(scr, "relacje", width, _acts)
        return scr
    live = [r for r in rows if not (r["kind"] == "relation" and r["rel"].get("state") == "removed")]
    title = _("Relacje na kolektorze %s (%d)") % (host, len(live))
    cells = [[r["name"], r.get("typ") or "?", r.get("dir") or "?", r.get("state") or "", r.get("vword") or "-"] for r in rows]
    det_title, det, child = "", [], None
    if rows and 0 <= cursor < len(rows):
        r = rows[cursor]
        det_title = _(u"%s -- relacja") % r["name"]
        det = rel_panel_pairs(r, data, now, ch)
        tabs = TABS["relacje"]
        ti = ti % len(tabs)
        child = rel_children(tabs[ti][0], r, data, jobrows, now, ch)
        # Dataset policzony z REKORDU (relacja bez crona) -- tytul to mowi.
        child.update({"name": r["name"] + ((u" (%s)" % child["how"]) if child.get("how") not in (None, u"wg crona") else ""),
                      "tabs": tabs, "ti": ti})
    empty = [_(u"Brak relacji zfs-backup na tym hoście."),
             _(u"Cudze migawki (np. replikacja Proxmoxa) nie są tu pokazywane."),
             _(u"Ins = nowa relacja (kreator).")]
    foot = (_(u"Enter szczegóły   Ins nowa   Del usuń   Tab do datasetów")) if rows else _(u"Ins nowa relacja")
    return render_tabbed(data, width, height, now, ch, "relacje", title,
                         [_(u"Relacja"), _(u"Typ"), _(u"Kierunek"), _(u"Stan"), _(u"Kopie")], cells, cursor, foot,
                         det_title, det, child, focus, pair_cursor, _acts, empty, prio=[0, 4, 3, 2, 1], flex=2)


# --- Relacja (okno na wierzchu) --------------------------------------------
def compact_paths(paths):
    """["h@x:hdd/lab/a", "h@x:hdd/lab/b"] -> "h@x:hdd/lab: a, b" -- wspolny
    przedrostek RAZ (R3-5: 9 pelnych sciezek zalewalo okno). Jedna sciezka --
    bez zmian."""
    if len(paths) < 2:
        return ",  ".join(paths)
    parts = [x.split("/") for x in paths]
    common = []
    for seg in zip(*parts):
        if len(set(seg)) != 1:
            break
        common.append(seg[0])
    if len(common) >= min(len(x) for x in parts):
        common = common[:-1]
    if not common:
        return ",  ".join(paths)
    return "%s: %s" % ("/".join(common), ", ".join("/".join(x[len(common):]) for x in parts))


def host_port_words(rel):
    """U114: "Peer X   endpoint X:22" -> "X, ssh port 22"; U111 (2026-10-29): NAZWA hosta,
    adres i port tylko w zakladce Config (tam stoi rekord, slowo w slowo)."""
    return host_name(rel_addr(rel)) or "?"


def _relation_opis_lines(row, data, now, ch, w, repo=None, files=None):
    """Zakladka Opis: co/jak dlugo trzyma/czy dziala/komendy, grupami po
    pytaniu operatora, PUSTA LINIA miedzy grupami, bez linii-linijek."""
    rel = row["rel"]
    out = []
    out.extend(detail_kv(ch, [
        (_("Stan"), state_word(rel) + ("   (peer: %s)" % rel["peer_pair_state"] if rel.get("peer_pair_state") not in ("", "NOT_ASKED", None) else "")),
        (_("Kierunek"), row.get("dir") or "?"),
        (_(u"Źródło"), _(u"%s   cel %s") % (", ".join(rel.get("sources") or []) or "?", rel.get("client_target") or _(SNAP_TARGET)))
        if rel.get("mode") == "local" else
        (_("Drugi host"), host_port_words(rel) +
         ((_("   w cronie: %s") % rel.get("installed_endpoint")) if rel.get("installed_endpoint") and rel.get("installed_endpoint") != rel.get("active_endpoint") else "")),
        (_("Historia"), "  ".join(x for x in [
            _(u"utworzona %s") % dshow(rel["created_at"]) if rel.get("created_at") else "",
            _(u"pełna kopia %s") % dshow(rel["seed_completed_at"]) if rel.get("seed_completed_at") else "",
            _(u"aktywowana %s") % dshow(rel["activated_at"]) if rel.get("activated_at") else "",
            _(u"usunięta %s") % dshow(rel["removed_at"]) if rel.get("removed_at") else ""]) or "?"),
    ], w))
    out.append("")
    # "co obejmuje" (wlasciciel 2026-10-18): to samo slowo dla kopii i dla migawek.
    out.append(_(u"co obejmuje"))
    pairs = [(_(u"Źródła (%d)") % len(rel.get("sources", [])), compact_paths([side_words(x) for x in rel.get("sources", [])]) or "?")]
    # R5-3 (wlasciciel 2026-09-25): jedno slowo "Cel" zamiast "Ladowiska" plus
    # osobnego "Cel" -- JEDEN wiersz "Cele (N)" z lista datasetow docelowych;
    # przy synchro dopisek w tej samej linii.
    _sync = _(u"   (ta sama ścieżka -- lustro)") if rel.get("mode") == "sync" else ""
    if rel.get("managed_datasets"):
        pairs.append((_(u"Cele (%d)") % len(rel["managed_datasets"]), compact_paths(rel["managed_datasets"]) + _sync))
    elif rel.get("mode") == "snaponly" or (rel.get("mode") == "local" and not rel.get("client_target")):
        pairs.append((_("Cel"), _(SNAP_TARGET)))
    else:
        pairs.append((_("Cel"), (rel.get("client_target") or "") + _sync or "?"))
    if rel.get("managed_prune_scope"):
        pairs.append((_(u"Prune"), ",  ".join(rel["managed_prune_scope"])))
    if rel.get("local_user"):
        pairs.append((_("Konto"), rel["local_user"]))
    out.extend(detail_kv(ch, pairs, w))
    out.append("")
    out.append(_(u"jak długo trzyma"))
    # X19: liczby i godziny są niżej (wiersze kopii i sprzątania, z configu); szablon to
    # tylko informacja, z czego relacja powstała.
    pairs = [(_(u"Powstała z"), profile_word(rel.get("profile"), rel.get("name")))]
    if not rel.get("source_profile") and (rel.get("passive") == "1" or rel.get("mode") == "sync"):
        pairs.append((_(u"Źródło"), _(u"bez sprzątania (źródło nie kasuje)")))
    if any(job_is_mirror(j) for j in row.get("jobs") or []):
        pairs.append((_(u"Cel"), _(u"lustro źródła: trzyma to, co źródło (bez własnej retencji)")))
    if rel.get("recursion"):
        pairs.append((_(u"Sposób"), {"flat": _(u"każdy dataset osobno"), "atomic": _(u"cała gałąź atomowo")}.get(rel["recursion"], rel["recursion"])))
    if rel.get("passive") == "1":
        pairs.append((_("Tryb"), _("pasywny")))
    if rel.get("bandwidth"):
        pairs.append((_(u"Łącze"), rel["bandwidth"]))
    out.extend(detail_kv(ch, pairs, w))
    # CO I KIEDY -- slowami, z configu (to byla sekcja POLITYKA; zakladka Config
    # pokazuje te same sekcje doslownie). Bez tego "jak dlugo trzyma" mowilo tylko
    # nazwe profilu, a nie ile i kiedy (sesja, przeglad 2026-09-24).
    cfg = None
    if data is not None and repo is not None and files is not None:
        cfg, cerr = load_config(repo, files, data, row["name"])
        if cerr:
            out.append(_(u"  show-config: błąd źródła: %s") % cerr)
    if cfg:
        tmpl = {t.get("name"): t.get("fields", {}) for t in cfg.get("templates", [])}
        pol, order = {}, []       # (slowo, opis bez nazwy) -> [nazwy]; kolejnosc pierwszego wystapienia
        _mirror = any(job_is_mirror(j) for j in row.get("jobs") or [])
        for sec in cfg.get("sections", []):
            f = sec.get("fields", {})
            used = [x for x in (f.get("use_template") or "").split(",") if x]
            # KAZDY SZCZEBEL OSOBNO, z tym samym pierwszenstwem co gen-cron
            # (resolve_field_tiered): pole szczebla w sekcji (send_schedule_<szablon>,
            # zapisywane przez rozrzut U2/K3), potem pole sekcji, potem szablon.
            # Okno bralo tylko PIERWSZY szablon i jego rytm: przy relacji
            # m12w4d7h24-gfs mowilo "co: 1 * * * *", a cron pobieral o :56, 02:06,
            # 03:16 i 04:26 (pve10, 2026-10-07).
            # X27: sekcja nosi pole pod KROTKA nazwa szczebla (send_schedule_hourly,
            # prune_schedule_src_hourly), a show-config podaje szablon pelna nazwa
            # (profile__relacja-pve9__hourly). Okno bralo wtedy rytm bloku: pve9 na pve10
            # "co godzinę (:01)", cron pobieral o :13 (przejscie na zywo 2026-10-23).
            def _tf(field, u):
                if not u:
                    return None
                return f.get(field + "_" + u) or f.get(field + "_" + u.rsplit("__", 1)[-1])
            if sec.get("kind") in ("dataset", "snaponly"):
                _src, _dst = f.get("src") or "", sec.get("name") or ""
                _w = u"pobranie" if "@" in _src else (u"wysyłka" if "@" in _dst else u"kopia")
                # Bez kopii (wlasciciel 2026-10-18): wiersz robienia migawek to "migawki".
                if sec.get("kind") == "snaponly" or (rel.get("mode") == "local" and not rel.get("client_target")):
                    _w = u"migawki"
                for u in (used or [""]):
                    t = tmpl.get(u, {}) if u else {}
                    sched = _tf("send_schedule", u) or f.get("send_schedule") or t.get("send_schedule") or "?"
                    pref = f.get("prefix") or t.get("prefix") or "?"
                    _ret = f.get("retain") or f.get("keep") or t.get("retain") or t.get("keep") or ""
                    key = (_w, _(u"co: %s   migawki %s*%s") % (cron_words(sched), pref, (_(u"   trzyma %s") % keep_cell(_ret)) if _ret else ""))
                    pol.setdefault(key, []).append(sec.get("name") or "?")
                    if key not in order:
                        order.append(key)
                # X27: sekcja celu relacji sama sprząta swoje kopie (cron "hourly prune
                # (pve9-enc)"); osobnej sekcji [prune:] po tej stronie już nie ma, więc
                # bez tego wiersza okno nie mówiło o porządkach u celu wcale. Lustro nosi
                # te pola w sekcji, ale cron nie sprząta u celu (trzyma to, co źródło).
                if f.get("side") == "target" and _w != u"migawki" and not _mirror:
                    for u in used:
                        t = tmpl.get(u, {})
                        sched = _tf("prune_schedule", u) or t.get("prune_schedule")
                        if not sched:
                            continue
                        r = t.get("retain") or t.get("keep") or ""
                        key = (u"lokalny prune", _(u"trzyma %s   co: %s%s") % (keep_cell(r) if r else "?", cron_words(sched),
                                                                         "   drabina GFS" if t.get("gfs") == "yes" else ""))
                        pol.setdefault(key, []).append(sec.get("name") or "?")
                        if key not in order:
                            order.append(key)
            elif any(_tf("prune_schedule", u) for u in used) or (
                    len(used) > 1 and not f.get("prune_schedule")
                    and all(tmpl.get(u, {}).get("prune_schedule") for u in used)):
                # Drugi warunek: każdy szczebel ma swój rytm w szablonie (X27, porządki
                # u źródła): cron ma linię na szczebel, okno mówiło tylko o pierwszym.
                # Prune rozrzucony szczebel po szczeblu (K3): jedna linia na szczebel.
                _pw = u"zdalny prune" if "@" in (sec.get("name") or "") else u"lokalny prune"
                for u in used:
                    t = tmpl.get(u, {})
                    r = t.get("retain") or t.get("keep") or ""
                    sched = _tf("prune_schedule", u) or f.get("prune_schedule") or t.get("prune_schedule") or "?"
                    key = (_pw, _(u"trzyma %s   co: %s%s") % (keep_cell(r) if r else "?", cron_words(sched),
                                                           "   drabina GFS" if (t.get("gfs") or f.get("gfs")) == "yes" else ""))
                    pol.setdefault(key, []).append(sec.get("name") or "?")
                    if key not in order:
                        order.append(key)
            else:
                ret = []
                for u in used:
                    r = tmpl.get(u, {}).get("retain") or tmpl.get(u, {}).get("keep")
                    if r:
                        ret.append(r)
                if f.get("retain"):
                    ret.append(f["retain"])
                sched = f.get("prune_schedule") or (tmpl.get(used[0], {}).get("prune_schedule") if used else "") or "?"
                _pw = u"zdalny prune" if "@" in (sec.get("name") or "") else u"lokalny prune"
                key = (_pw, _(u"trzyma %s   co: %s%s") % (keep_cell(" ".join(ret)) if ret else "?", cron_words(sched),
                                                       "   drabina GFS" if f.get("gfs") == "yes" else ""))
                pol.setdefault(key, []).append(sec.get("name") or "?")
                if key not in order:
                    order.append(key)
        for key in order:
            names = pol[key]
            what = compact_paths(names) if len(names) > 1 else names[0]
            label = _(key[0]) + (_(u" (%d szt.)") % len(names) if len(names) > 1 else "")
            out.extend(detail_kv(ch, [(label, u"%s   %s" % (key[1], what))], w))
    out.append("")
    out.append(_(u"czy działa"))
    if row["monitors"]:
        for m in row["monitors"]:
            vw = _(VERDICTS.get(m.get("verdict", ""), (m.get("verdict", "?"), 0))[0])
            out.extend(detail_kv(ch, [(vw, _("%s   rodzina %s   progi %s / %s   co %s") % (
                compact_paths(m.get("datasets", [])), m.get("pattern") or "?", m.get("warn") or "?",
                m.get("crit") or "?", m.get("schedule") or "?"))], w))
            if m.get("reason"):
                # R3-5: dziewiec linii CRITICAL rozniacych sie tylko datasetem zalewalo
                # okno -- pierwsza w calosci, reszta liczba (pelne w zakladce Cron/logu)
                rl = [ln for ln in m["reason"].splitlines() if ln.strip()]
                for ln in rl[:1]:
                    out.extend(wrap("    " + ln, w))
                if len(rl) > 1:
                    out.append(_(u"    (i %d podobnych dla pozostałych datasetów)") % (len(rl) - 1))
            if m.get("paused_local"):
                out.append(_(u"    linia wstrzymana (pauza)"))
    else:
        out.append(_(u"  bez monitora -- nikt nie sprawdza, czy kopia dalej się robi"))
    last = row["last"]
    if last:
        wd, note = transfer_word(last, now)
        st_, fin = int(last.get("started_epoch") or 0), int(last.get("finished_epoch") or 0)
        txt = "%s  %s" % (wd, fmt_full(fin or st_))
        if fin and st_:
            txt += "  %s" % fmt_dur(fin - st_)
        if note:
            txt += "  " + note
        out.extend(detail_kv(ch, [(_(u"Ostatni transfer"), txt)], w))
    else:
        out.extend(detail_kv(ch, [(_(u"Ostatni transfer"), _(u"brak zapisu w historii"))], w))
    # U114 (symulacja A, 2026-10-28): bez sekcji "komendy" -- te same czynnosci sa pod
    # klawiszami na ramce, a okno potwierdzenia pokazuje polecenie przed WYKONAJ.
    return out


def _relation_cron_lines(row, ch, w):
    """Sekcja CRON okna: linie, ktore host naprawde wykona (dla zadania/pary --
    tylko jego linie, bo row["jobs"] jest zawezone)."""
    rel = row.get("rel") or {}
    out = []
    if row["jobs"]:
        out.extend(cron_lines_of(row["jobs"], w, ch))
    else:
        out.append(_(u"  brak linii w cronie dla tej etykiety") + ("" if rel.get("state") == "active" else _(u" (relacja nie jest aktywna)")))
    accts = sorted({j.get("account", "") for j in row["jobs"] if j.get("account")})
    if accts:
        out.append("")
        out.append(_(u"konto: %s") % ", ".join(accts))
    return out


def kv_config_lines(k, v, w):
    """Jedna para configu do podgladu DOSLOWNEGO. Dluga wartosc bez spacji (lista
    use_template) lamana PO PRZECINKACH, kazdy element w swojej linii, a zbyt
    dlugi kawalek -- twardo po znakach, BEZ gubienia srodka (zwykly wrap ucinal
    "profile__default__keep_monthly" do "profi...t__keep_monthly")."""
    head = u"  %s = " % k
    if len(head) + len(v) <= w:
        return [head + v]
    if "," in v and " " not in v:
        items = v.split(",")
        out = [head + items[0] + ("," if len(items) > 1 else "")]
        for i, it in enumerate(items[1:], 1):
            out.append(u"      " + it + ("," if i < len(items) - 1 else ""))
    else:
        out = [head + v]
    res = []
    for ln in out:
        while len(ln) > w:
            res.append(ln[:w])
            ln = u"      " + ln[w:]
        res.append(ln)
    return res


def config_sections_lines(cfg, w, keep_section=None, keep_template=None):
    """Sekcje configu WERBATIM (klucz=wartosc), tak jak je oddaje show-config
    --json -- read-only. `keep_section(sec)` / `keep_template(name)` zawezaja do
    jednego zadania albo pary (R4-6); bez nich -- cala relacja."""
    out = [_(u"plik: %s") % (cfg.get("config") or "?"),
           _(u"(odtworzone z show-config -- klucz=wartość, nie surowy tekst pliku)")]
    used = set()
    for sec in cfg.get("sections", []):
        if keep_section is not None and not keep_section(sec):
            continue
        out.append("")
        out.append(u"[%s:%s]" % (sec.get("kind", "?"), sec.get("name", "?")))
        f = sec.get("fields", {})
        for k in sorted(f):
            out.extend(kv_config_lines(k, f[k], w))
            if k == "use_template":
                used.update(x for x in (f[k] or "").split(",") if x)
    for t in cfg.get("templates", []):
        if t.get("name") not in used:
            continue
        if keep_template is not None and not keep_template(t.get("name")):
            continue
        out.append("")
        out.append(u"[template:%s]" % t.get("name", "?"))
        tf = t.get("fields", {})
        for k in sorted(tf):
            out.extend(kv_config_lines(k, tf[k], w))
    return out


def _relation_config_lines(row, data, ch, w, repo, files):
    """Sekcja CONFIG okna: dla relacji -- wszystkie jej sekcje; dla zadania albo
    pary (R4-6) -- tylko sekcja tego zakresu i szablon tego szczebla."""
    n = row["name"]
    if data is None or repo is None or files is None:
        return [_(u"configu nie da się odczytać w tym trybie")]
    jobs = row.get("jobs") or []
    if row["kind"] != "relation" and not (row.get("kind") == "job" and jobs and jobs[0].get("label")):
        cf = sorted({j.get("config") for j in jobs if j.get("config")})
        return [_(u"zadanie bez relacji -- show-config pokazuje tylko relacje"),
                _(u"plik: %s") % (", ".join(cf) or "?")]
    cfg, cerr = load_config(repo, files, data, n)
    if cerr:
        return [_(u"błąd źródła: %s") % cerr, u"  zfs-backup.sh show-config %s --json" % n]
    if not cfg or not cfg.get("sections"):
        return [_(u"configu jeszcze nie ma -- powstanie przy aktywacji"), "",
                _(u"podgląd: zfs-backup.sh activate %s") % n]
    if row["kind"] == "relation":
        return config_sections_lines(cfg, w)
    # Zadanie/para: sekcja o tym samym rodzaju i nazwie (= zakres z list-jobs)
    # i tylko szablon szczebla, ktory to zadanie wykonuje.
    want = {(j.get("section_kind"), j.get("scope")) for j in jobs}
    tiers = {j.get("tier") for j in jobs if j.get("tier")}
    out = config_sections_lines(cfg, w, keep_section=lambda sec: (sec.get("kind"), sec.get("name")) in want,
                                keep_template=lambda name: name in tiers)
    if len(out) == 2:
        out.append(_(u"(nie znaleziono sekcji tego zadania w configu relacji)"))
    return out


def section_header(ch, title, w):
    """'── CONFIG ─────' -- jeden wzor naglowka sekcji we wszystkich oknach (R4-7)."""
    return (ch.dash * 2 + " " + title + " " + ch.dash * max(0, w - len(title) - 4))[:w]


RELATION_TABS = (u"Opis", u"Config")


def relation_window_lines(row, data, now, ch, width, repo=None, files=None, tab=None):
    """Tresc okna szczegolow, jako linie; okno przewija sie, wiec bez limitu.

    JEDEN UKLAD dla relacji (Enter na F3), zadania (Enter na F2) i pary (Enter
    na parze w F3) -- R4-6/R4-7, wlasciciel 2026-09-24: najpierw szczegoly,
    pod nimi sekcja CONFIG, potem CRON. Zakladki Opis/Config/Cron z R3-2
    zniknely: to byla ukryta funkcja (trzeba bylo wiedziec o Tab), a okno
    zadania mialo W CRONIE bez configu. U114 (2026-10-28): okno RELACJI (tab != None)
    znow ma dwie zakladki, Opis i Config, z klawiszem lewo/prawo na ramce."""
    w = width - 4
    if row["kind"] == "relation" and tab is not None:
        # U114 (wlasciciel 2026-10-28, symulacja A): okno relacji ma dwie zakladki, Opis i
        # Config (config + cron), przelaczane strzalkami lewo/prawo podpisanymi na ramce.
        # Zakladki z R3-2 zdjete 2026-09-24, bo byly ukryte (trzeba bylo wiedziec o Tab);
        # te sa na ramce. Okno zadania (F2) zostaje jednym przewijaniem.
        if tab == 0:
            return _relation_opis_lines(row, data, now, ch, w, repo, files)
        out = [section_header(ch, "CONFIG", w)]
        out.extend(_relation_config_lines(row, data, ch, w, repo, files))
        out.extend(["", section_header(ch, "CRON", w)])
        out.extend(_relation_cron_lines(row, ch, w))
        return out
    if row["kind"] == "relation":
        out = _relation_opis_lines(row, data, now, ch, w, repo, files)
    else:
        out = []
        for k, v in rel_detail_pairs(row, data, now, ch):
            out.extend(detail_kv(ch, [(k, v)], w))
        if row["kind"] not in ("job",):
            return out
    out.extend(["", section_header(ch, "CONFIG", w)])
    out.extend(_relation_config_lines(row, data, ch, w, repo, files))
    out.extend(["", section_header(ch, "CRON", w)])
    out.extend(_relation_cron_lines(row, ch, w))
    # Bez dopisku "tylko do odczytu -- zmiana relacji: F3, Enter, 'e'" (właściciel 2026-10-19:
    # "niepotrzebne, podgląd wystarczy").
    return out


def cron_lines_of(jobs, w, ch):
    """Sekcje configu tej relacji i linie, ktore host naprawde wykona.

    Otoczka zfs-job.sh (--log/--notify/--detail) jest POMIJANA i to jest
    powiedziane: sama komenda silnika mowi, co sie stanie."""
    # R5-5 (wlasciciel 2026-09-25): KAZDY ZAKRES ZE SWOIMI LINIAMI. list-jobs
    # daje kazdemu zadaniu cron_lines calego BLOKU, a pierwsza wersja drukowala
    # je wszystkie pod pierwszym zadaniem i pomijala powtorki -- pve9-synchro
    # mialo 19 linii pod hdd/lab/ct-201 i osiem pustych naglowkow.
    # GRUPA = zadania tego samego rodzaju, zakresu i harmonogramu: drabina GFS
    # to JEDNA linia delsnaps dla czterech szczebli, wiec cztery szczeble to
    # jeden naglowek. Linia nalezy do grupy, gdy jej zakres (albo drugi koniec)
    # stoi w niej jako argument w cudzyslowie i jej rodzina tez; transfer tylko
    # do [dataset:], prune i straznik najpierw do [prune:]. Linia wielu grup
    # (straznik z lista datasetow) idzie do wspolnych na koncu.
    def _eng(ln):
        e = ln.split(" -- ", 1)[1] if " -- " in ln else " ".join(ln.split()[5:])
        return e.split(" >>")[0]

    groups, gkey = [], {}
    for j in jobs:
        k = (j.get("section_kind"), j.get("scope"), j.get("schedule"), j.get("direction"))
        if k not in gkey:
            gkey[k] = len(groups)
            groups.append([])
        groups[gkey[k]].append(j)

    def _matches(g, elems, fams):
        for j in g:
            fam = family_of(j)
            if fam and fam not in fams:
                continue
            if j.get("scope") in elems:
                return "scope"
            if j.get("other_end") and j["other_end"] in elems:
                return "end"
        return None

    def _owner(ln):
        eng = _eng(ln)
        toks = re.findall(r'"([^"]*)"', eng)
        elems = set(x for t in toks for x in t.split(","))
        fams = set(t.rstrip("_") for t in toks)
        # delsnaps -G z "automated_" tnie drabine calej rodziny: pasuje do
        # kazdego szczebla, ktorego rodzina zaczyna sie od tego prefiksu.
        fams |= set(family_of(j) for j in jobs if any(family_of(j).startswith(t) for t in toks if t.endswith("_")))
        hit = [(i, _matches(g, elems, fams)) for i, g in enumerate(groups)]
        hit = [(i, h) for i, h in hit if h]
        if "snapget.sh" in eng or "snapsend.sh" in eng:
            hit = [(i, h) for i, h in hit if groups[i][0].get("section_kind") in SEND_KINDS]
        else:
            pr = [(i, h) for i, h in hit if groups[i][0].get("section_kind") == "prune"]
            hit = pr or hit
        sc = [i for i, h in hit if h == "scope"]
        pick = sc if sc else [i for i, _h in hit]
        return pick[0] if len(pick) == 1 else None, len(pick)

    lines, seen = [], set()
    for j in jobs:
        for ln in j.get("cron_lines") or []:
            if ln not in seen:
                seen.add(ln)
                lines.append(ln)
    mine = [[] for _g in groups]
    shared = []
    for ln in lines:
        gi, nown = _owner(ln)
        if gi is None:
            shared.append((ln, nown))
        else:
            mine[gi].append(ln)

    out = []

    def _emit(ln):
        out.extend(wrap("      %s   %s" % (" ".join(ln.split()[:5]), _eng(ln)), w))

    for gi, g in enumerate(groups):
        j = g[0]
        arrow = _(ch.arrows.get(j.get("direction", ""), "?")).format(peer=j.get("peer") or "?")
        tiers = []
        for x in g:
            t = x.get("tier", "")
            if "__" in t:
                t = t.rsplit("__", 1)[-1]
            r = x.get("retain") or x.get("keep") or ""
            tiers.append(t + ((" " + r) if r else ""))
        # Nazwa szczebla w calosci (R5-5: "passive_flat_hourly…" ucinalo sie).
        out.extend(wrap("  %s  %s  %s  %s" % (arrow, j.get("schedule", "?"), ", ".join(tiers), j.get("scope", "")), w))
        for ln in mine[gi]:
            _emit(ln)
    if shared:
        n_ = max([k for _l, k in shared] + [0])
        out.append("")
        out.append(_(u"  wspólne (%s)") % (_(u"strażnik i linie obejmujące %d zakresów") % n_ if n_ > 1 else _(u"linie bez jednego właściciela")))
        for ln, _k in shared:
            _emit(ln)
    if jobs and not any(j.get("cron_lines") for j in jobs):
        out.append(_(u"  (linie crona: list-jobs bez pola cron_lines -- starszy czytelnik)"))
    return out


def pair_source_dataset(pr):
    """Dataset zrodla pary: 'konto@host:hdd/data' -> 'hdd/data', 'hdd/data   na pve9b' -> 'hdd/data'."""
    s = (pr.get("src") or "").split()[0] if pr.get("src") else ""
    return s.rsplit(":", 1)[-1]


def snap_short(n):
    """automated_hourly_2026-10-20_18-17 -> hourly_2026-10-20_18-17 (przedrostek hosta zostaje)."""
    return re.sub(r"(^|_)automated_", r"\1", n, count=1)


def snap_pair_rows(d):
    """U38: migawki obu stron wyrownane po GUID, od najstarszej. Wiersz: (znak, src|None, tgt|None).
    '=' po obu stronach, '>' tylko u zrodla (jeszcze nie skopiowana), ' ' tylko w kopii."""
    src = (d.get("source") or {}).get("snapshots") or []
    tgt = (d.get("target") or {}).get("snapshots") or []
    by = {}
    for s in src:
        by.setdefault(s.get("guid"), [None, None])[0] = s
    for t in tgt:
        by.setdefault(t.get("guid"), [None, None])[1] = t
    rows = []
    for g, (s, t) in by.items():
        c = min(x.get("creation", 0) for x in (s, t) if x)
        rows.append((c, "=" if (s and t) else (">" if s else " "), s, t))
    rows.sort(key=lambda r: r[0])
    # '>' tylko NOWSZE niz baza (najnowsza wspolna): tylko te pojda nastepna kopia przyrostowa.
    # Starsza migawka tylko u zrodla (np. replica_ z innej relacji, wykluczona rodzina) nie
    # zostanie skopiowana -- bez znaku, zeby nie udawala zaleglosci.
    last_both = max([i for i, r in enumerate(rows) if r[1] == "="] or [-1])
    out = []
    for i, (_c, m, s_, t_) in enumerate(rows):
        if m == ">" and i < last_both:
            m = " "
        out.append((m, s_, t_))
    return out


def snap_pair_summary(d, rows):
    """Stopka tresci: baza nastepnej kopii przyrostowej (najnowsza wspolna, inaczej zakladka)."""
    both = [r for r in rows if r[0] == "="]
    has_tgt = bool((d.get("target") or {}).get("dataset"))
    nsrc = sum(1 for r in rows if r[1]); ntgt = sum(1 for r in rows if r[2])
    if not has_tgt:
        return _(u"Migawki na źródle: %d (ta relacja nie robi kopii)") % nsrc
    if both:
        base = _(u"Baza następnej kopii: %s") % snap_short(both[-1][1]["snap"])
    else:
        tg = [r[2] for r in rows if r[2]]
        bm = [b for b in (d.get("source") or {}).get("bookmarks") or [] if tg and b.get("guid") == tg[-1].get("guid")]
        base = (_(u"Baza: zakładka %s (wspólnej migawki brak)") % bm[0]["name"]) if bm else _(u"Baza: BRAK -- następna kopia od zera")
    only_src = sum(1 for r in rows if r[0] == ">")
    return _(u"%s   Źródło %d / kopia %d   do skopiowania: %d") % (base, nsrc, ntgt, only_src)


def snap_cell(s, w, now):
    if not s:
        return " " * w
    age = max(0, now - int(s.get("creation") or 0))
    a = ("%dd" % (age // 86400)) if age >= 86400 else ("%dh" % (age // 3600)) if age >= 3600 else ("%dm" % (age // 60))
    t = time.strftime(DT_FMT, time.localtime(int(s.get("creation") or 0)))
    tail = "%s %4s %6s%s" % (t, a, hbytes_short(int(s.get("used") or 0)), " [hold]" if int(s.get("holds") or 0) else "")
    name_w = max(8, w - len(tail) - 1)
    return fit("%-*s %s" % (name_w, fit(snap_short(s.get("snap", "")), name_w), tail), w)


def snap_pair_lines(d, width, side, now):
    """U38 okno migawek pary: dwa panele obok siebie (zrodlo | kopia) od ~120 kolumn,
    wezej -- jeden panel naraz (Tab przelacza). Lista od NAJNOWSZEJ (gora = teraz)."""
    chrono = snap_pair_rows(d)
    rows = list(reversed(chrono))
    s_ds = (d.get("source") or {}).get("dataset", "?")
    t_ds = (d.get("target") or {}).get("dataset") or ""
    host = host_name((d.get("source") or {}).get("host")) or _(u"ten host")
    out = [fit(snap_pair_summary(d, chrono), width - 4), ""]
    for side_name in ("source", "target"):
        e = (d.get(side_name) or {}).get("error")
        if e:
            out.append(fit(_(u"BŁĄD %s: %s") % (_(u"źródła") if side_name == "source" else _(u"kopii"), e), width - 4))
    inner = width - 4
    two = bool(t_ds) and inner >= 116
    if two:
        w = (inner - 7) // 2
        out.append(fit(u"  %-*s │   %s" % (w, fit(_(u"ŹRÓDŁO %s  %s") % (host, s_ds), w), _(u"KOPIA %s") % t_ds), inner))
        for m, s, t in rows:
            out.append(u"%s %s │ %s %s" % (m, snap_cell(s, w, now), m if t else " ", snap_cell(t, w, now)))
    else:
        show_t = bool(t_ds) and side == 1
        w = inner - 3
        out.append(fit(u"  %s" % ((_(u"KOPIA %s") % t_ds) if show_t else (_(u"ŹRÓDŁO %s  %s") % (host, s_ds))), inner))
        for m, s, t in rows:
            x = t if show_t else s
            if x:
                out.append(u"%s %s" % (m, snap_cell(x, w, now)))
    if not rows:
        out.append(_(u"  (brak migawek)"))
    return out


# Nazwa okna w linii komunikatu po jego zamknieciu (window_end_message).
WINDOW_TITLES = {
    "new-relation": u"Nowa relacja", "edit-relation": u"Zmień relację", "delete-relation": u"Usuń relację",
    "add-replica": u"Replika", "remove-replica": u"Usuń replikę", "restore": u"Odzysk",
    "browse": u"Przeglądaj", "settings": u"Ustawienia", "save-profile": u"Szablon",
}


def wrap_hanging(lines, avail):
    """Kampania 3 (2026-10-22, 80x24): pomoc F1 pisana pod ~100 kolumn byla w 80 PRZYCINANA
    ("kop…", "domyś…") -- tresc ginela. Za dlugi wiersz lamany na spacji; kontynuacja wcieta
    tam, gdzie zaczyna sie opis ("  F2  Zadania    |co chodzi..."), a gdy kolumny nie ma --
    tak jak wiersz. Ogon zawinietego wiersza laczy sie z nastepnym, gdy ten jest dalszym
    ciagiem tego samego opisu (to samo wciecie) -- bez tego zostawaly sieroty ("czasy")."""
    import re
    out = []
    lines = list(lines)
    i = -1
    while i + 1 < len(lines):
        i += 1
        line = lines[i]
        if len(line) <= avail:
            out.append(line)
            continue
        m = re.match(r"^(\s*\S.{0,22}?\s{2,})(?=\S)", line)
        hang = len(m.group(1)) if m and len(m.group(1)) < avail // 2 else len(line) - len(line.lstrip(" "))
        first, rest = True, line
        while len(rest) > avail:
            cut = rest.rfind(" ", hang + 1 if not first else 1, avail + 1)
            if cut <= (hang if not first else 0):
                cut = avail
            out.append(rest[:cut].rstrip())
            rest = " " * hang + rest[cut:].lstrip()
            first = False
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        if not first and nxt[:hang].strip() == "" and nxt[hang:hang + 1].strip():
            lines[i + 1] = rest + " " + nxt.lstrip()
            continue
        out.append(rest)
    return out


def render_window(base, title, lines, scroll, width, height, ch, footer=u"Esc zamyka   strzałki/PgUp/PgDn przewijają", wrap=False):
    """Okno na wierzchu ekranu: ramka podwojna, tresc przewijana (wrap: zawijana do szerokosci)."""
    if wrap:
        lines = wrap_hanging(lines, width - 4)
    scr = Screen()
    # Pod oknem zostaje linia polecen i listwa klawiszy (wlasciciel 2026-10-18).
    keep = base.lines[-2:] if getattr(base, "cmd_y", None) is not None and len(base.lines) >= 3 else []
    inner_h = height - 3 - len(keep)
    if scroll > max(0, len(lines) - inner_h):
        scroll = max(0, len(lines) - inner_h)
    body = lines[scroll:scroll + inner_h]
    while len(body) < inner_h:
        body.append("")
    pos = ""
    if len(lines) > inner_h:
        pos = _(u"%d-%d z %d") % (scroll + 1, min(len(lines), scroll + inner_h), len(lines))
    bx = box(ch, title, body, width, footer=_(footer) + ("   " + pos if pos else ""))
    scr.lines = [base.lines[0]] + bx + keep
    scr.bars.add(0)
    if keep:
        scr.bars.add(len(scr.lines) - 1)
    scr.titles.add(1)
    scr.titles.add(len(scr.lines) - 1)
    return scr, scroll


# --- Monitor ---------------------------------------------------------------
def monitor_rows(data):
    mons = list((data.monitors or {}).get("monitors", []))
    order = {v: i for i, v in enumerate(VERDICT_ORDER)}
    mons.sort(key=lambda m: order.get(m.get("verdict", "UNKNOWN"), 9))
    return mons


def monitor_detail_pairs(m, ch, full=False):
    vw = _(VERDICTS.get(m.get("verdict", ""), (m.get("verdict", "?"), 0))[0])
    pairs = [(_("Relacja"), m.get("label") or _("(bez etykiety)")),
             (_("Datasety (%d)") % len(m.get("datasets", [])), ",  ".join(m.get("datasets", [])) or "?"),
             ("Rodzina", "%s   progi %s / %s   %s" % (m.get("pattern") or "?", m.get("warn") or "?", m.get("crit") or "?",
                                                      "rekursywnie" if m.get("recursive") else "")),
             ("Sprawdza", _("%s   konto %s") % (m.get("schedule") or "?", m.get("account") or "?"))]
    if m.get("exclude"):
        pairs.append(("Wyklucza", ", ".join(m["exclude"])))
    verdict = vw
    if m.get("reason"):
        lines = m["reason"].splitlines()
        # W panelu jedna linia (pelny tekst w oknie po Enter); w oknie wszystkie.
        verdict += "   " + (lines[0] if not full else "  |  ".join(lines))
    elif m.get("verdict") == "OK":
        verdict += _(u"   najnowsza migawka mieści się w progu")
    notes = []
    if m.get("paused_local"):
        notes.append(_(u"relacja wstrzymana -- „OK” nie znaczy, że kopie są aktualne"))
    if m.get("engine_path_differs"):
        notes.append(_(u"cron uruchamia %s, a GUI sprawdzało %s -- to różne pliki programu, wynik może nie pasować") % (m.get("engine_in_cron"), m.get("engine_run")))
    if not m.get("parsed", True):
        notes.append(_(u"linii monitora nie dało się sparsować; wynik pochodzi z kodu wyjścia"))
    if notes:
        pairs.append((_("Uwaga"), "  |  ".join(notes)))
    pairs.append(("Werdykt", verdict))
    return pairs


def render_monitor(data, cursor, width, height, now, ch, message=""):
    scr = Screen()
    top = top_bar(data, width, now, ch.ascii, len(data.errors))
    if data.failed("monitors"):
        scr.lines = [top] + box(ch, "Monitor", source_error_body(ch, "monitors", data, "monitor"), width)
    else:
        mons = monitor_rows(data)
        # PROG 150, nie 120 -- ten sam prog co F2/F4/F6 (R3-4, punkt 3); ekran
        # jest martwy (F5 zniesiony), ale wspolny prog zostaje wspolny.
        beside = width >= 150
        lbw = max(MIN_WIDTH, int(width * 0.6)) if beside else width
        inner = lbw - 4
        nw = max(8, min(20, max([len(m.get("label") or _("(bez rel.)")) for m in mons] + [8])))
        # RODZINA NIE UCINA SIE O JEDEN ZNAK. Kolumna miala na sztywno 16, a
        # `automated_monthly` ma 17 -- ekran pokazywal `automated_month…` przy
        # kazdej szerokosci (zmierzone na pve10, 2026-09-21). Bierze tyle, ile
        # potrzebuje najdluzsza rodzina, ale nie wiecej niz 20 i nigdy kosztem
        # Datasetu ponizej 20 znakow: sciezka i tak jest dluzsza niz kolumna,
        # wiec jeden znak mniej jest tam niewidoczny, a tu usuwa falszywe uciecie.
        fw, pw, vw = 16, 12, 14
        fw = max(fw, min(20, max([len(m.get("pattern") or "") for m in mons] + [fw])))
        dw = inner - (nw + fw + pw + vw + 4)
        while dw < 20 and fw > 16:
            fw -= 1
            dw = inner - (nw + fw + pw + vw + 4)
        hdr = "%s %s %s %s %s" % (fit(_("Relacja"), nw), fit(_("Dataset"), dw), fit("Rodzina", fw), fit("Progi", pw), fit(_("Kopie"), vw))
        panel_h = 0 if beside else 9
        list_h = max(3, height - 2 - 2 - panel_h - 2)
        first = 0
        if cursor >= list_h:
            first = cursor - list_h + 1
        body = [hdr, ch.dash * inner]
        cur_y = None
        for i, m in enumerate(mons[first:first + list_h], start=first):
            ds = m.get("datasets", [])
            dtxt = (ds[0] if ds else "?") + ("  +%d" % (len(ds) - 1) if len(ds) > 1 else "")
            vword = _(VERDICTS.get(m.get("verdict", ""), (m.get("verdict", "?"), 0))[0])
            if m.get("paused_local"):
                vword += _(" PAUZA")
            if i == cursor:
                cur_y = len(body)
            body.append("%s %s %s %s %s" % (fit(m.get("label") or _("(bez rel.)"), nw, ch), fit_left(dtxt, dw, ch),
                                            fit(m.get("pattern") or "?", fw, ch),
                                            fit("%s/%s" % (m.get("warn") or "?", m.get("crit") or "?"), pw, ch), fit(vword, vw, ch)))
        if not mons:
            body += [_(u"Zero linii monitora w blokach zfs-backup-managed."),
                     _(u"Kopie mogą się robić, ale NIKT nie sprawdza, czy dalej się robią.")]
        if len(mons) > first + list_h:
            body.append(u"... jeszcze %d" % (len(mons) - first - list_h))
        while len(body) < list_h + 2:
            body.append("")
        wv = (data.monitors or {}).get("worst", "?")
        title = "Monitor -- %s, najgorzej: %s" % (plural(len(mons), "linia", "linie", "linii"),
                                                 _(VERDICTS.get(wv, (wv, 0))[0]) if mons else "--")
        lb = box(ch, title, body, lbw, footer=_(u"Enter szczegóły") if mons else "")
        if cur_y is not None:
            scr.cursor_y = 2 + cur_y
        panel = []
        if mons and 0 <= cursor < len(mons):
            pw_ = (width - max(MIN_WIDTH, int(width * 0.6))) if beside else width
            pl = detail_kv(ch, monitor_detail_pairs(mons[cursor], ch), pw_ - 4)
            lim = (len(lb) - 2) if beside else (panel_h - 2)
            pl = pl[:lim]
            while len(pl) < lim:
                pl.append("")
            panel = box(ch, _(u"%s -- szczegóły") % (mons[cursor].get("label") or "linia"), pl, pw_, double=False)
        if beside and panel:
            scr.lines = [top] + side_by_side(lb, panel, width, ch)
        else:
            scr.lines = [top] + lb + panel
        scr.titles.update({1, len(lb)})
        if panel and not beside:
            scr.titles.update({len(lb) + 1, len(lb) + len(panel)})
    scr.bars.add(0)
    if message:
        scr.lines.append(fit(" " + message, width))
    while len(scr.lines) < height - 1:
        scr.lines.append(fit("", width))
    scr.lines = scr.lines[:height - 1]
    push_key_bar(scr, "monitor", width)
    return scr


# --- Nosniki ---------------------------------------------------------------
def replica_stats_row(data, name):
    """Wiersz job-stats repliki: zadanie ma etykiete "<host> replica copy (<nazwa>)",
    a job-stats trzyma ja bez hosta."""
    want = u"replica copy (%s)" % name
    for x in (data.stats or {}).get("jobs", []):
        if x.get("label") == want:
            return x
    return None


def replica_last_run(srow, stats_failed=False):
    """Kolumna "Ostatni bieg" w F6: wynik i czas ostatniego biegu z job-stats. "Wykonana"
    mowi tylko, kiedy kopia byla ostatnio aktualna -- na pve10 replika calapula
    padla 4 razy z 4 (rc=1), a lista pokazywala samo "Wykonana 22.10" (2026-10-28)."""
    if stats_failed:
        return u"?"
    if not srow:
        return u"-"
    rc = srow.get("last_rc")
    word = u"OK" if rc == 0 else (_(u"pominięty") if rc == 75 else _(u"BŁĄD rc=%s") % rc)
    at = srow.get("last_at") or ""
    return (u"%s %s" % (word, dshow(at))) if re.match(r"\d{4}-\d{2}-\d{2}", at) else word


def replica_when(r, long=False):
    """Harmonogram repliki słowami; '+ po podłączeniu', gdy replika rusza też po podłączeniu
    dysku (on_insert, P5 2026-10-09)."""
    s = r.get("schedule") or "?"
    if s == "on-insert":
        return _(u"po podłączeniu nośnika") if long else _(u"po podłączeniu")
    return s + (_(u" + po podłączeniu") if r.get("on_insert") == "yes" else "")


def replica_disks_words(r):
    """Dyski repliki po ID puli (P5): ile, albo że rozpoznawane tylko po nazwie."""
    if r.get("media") != "removable":
        return _(u"stały nośnik (pula w maszynie)")
    g = [x for x in (r.get("media_guids") or "").split(",") if x]
    if not g:
        return _(u"po nazwie puli -- ID nieznane (zmiana repliki dopisze ID podłączonego dysku)")
    return _(u"%d po ID puli: %s") % (len(g), ", ".join(g))


def replica_keep_n(r):
    """Ile wlasnych zdjec trzyma dysk: keep albo 2 (kolektor trzyma 2 najnowsze replica_,
    a dysk bez keep jest jego odbiciem)."""
    try:
        return int(str(r.get("keep") or "").strip())
    except ValueError:
        return 2


def replica_kind(r, ascii_=False):
    """X11 (wlasciciel 2026-10-12): kluczowe rozroznienie repliki = CO TRAFIA NA DYSK.
    (krotko do kolumny, pelnymi slowami do panelu)"""
    if r.get("prefix") == "-":
        return _(u"historia"), _(u"historia kolektora -- dysk dostaje migawki, które już tam są")
    n = replica_keep_n(r)
    return (_(u"migawki %s%d") % ("x" if ascii_ else u"×", n),
            _(u"własne migawki -- replika przy każdym biegu robi migawkę %s") % (r.get("prefix") or "replica_"))


def replica_disk_words(r):
    """X11: co jest na dysku, na przykladzie (ile czasu wstecz)."""
    if r.get("prefix") == "-":
        if r.get("history") and r["history"] not in ("all",):
            return _(u"tylko najnowsza migawka kolektora (historia: tylko różnica -- pośrednie nie trafiają)")
        return _(u"to samo co kolektor: wszystkie jego migawki, także pośrednie")
    n = replica_keep_n(r)
    f = (r.get("schedule") or "").split()
    span = u""
    if r.get("schedule") == "on-insert":
        span = _(u" (tyle podłączeń dysku wstecz)")
    elif len(f) == 5:
        if f[2] != "*":
            span = _(u" (ok. %d mies. wstecz)") % n
        elif f[4] != "*":
            span = _(u" (ok. %d tyg. wstecz)") % n
        elif f[1] != "*" and "/" not in f[1] and "," not in f[1]:
            span = _(u" (ok. 1 dzień wstecz)") if n == 1 else _(u" (ok. %d dni wstecz)") % n
    if n == 1:
        words = _(u"najnowsza migawka")
    elif 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        words = _(u"najnowsze migawki")
    else:
        words = _(u"najnowszych migawek")
    return u"%d %s %s%s" % (n, words, r.get("prefix") or "replica_", span)


def replica_crypt_words(r):
    """W19b + W17: nosnik zaszyfrowany kluczem z pliku i/lub kopie wysylane raw."""
    raw = str(r.get("raw") or "").lower() in ("yes", "1", "true")
    words = []
    if r.get("media_key"):
        words.append(_(u"nośnik zaszyfrowany (klucz: F8)"))
    if raw:
        words.append(_(u"kopie idą zaszyfrowane (raw), klucz zostaje u źródła"))
    return u"; ".join(words) if words else _(u"nie")


def replica_detail_pairs(r, ch, srow=None, stats_failed=False):
    """Panel repliki (F6), U21: grupy Co / Kiedy / Zdrowie, harmonogram slowami,
    JEDEN "Ostatni bieg" (bylo "Ostatnio" i "Ost. bieg" z roznymi godzinami)."""
    s = r.get("schedule") or "?"
    when = _(u"zaraz po podłączeniu dysku") if s == "on-insert" else \
        cron_words(s) + (_(u" i zaraz po podłączeniu dysku") if r.get("on_insert") == "yes" else "")
    pairs = [group(ch, _(u"Co")),
             (_(u"Rodzaj"), replica_kind(r)[1]),
             (_(u"Na dysku"), replica_disk_words(r)),
             ] + ([(_(u"Ile migawek"), _(u"nieustawione -- tyle, ile trzyma kolektor (2)"))]
                  # Bez wlasnej liczby (keep) dysk trzyma tyle, ile kolektor zostawia jako baze przyrostu.
                  if r.get("prefix") != "-" and not str(r.get("keep") or "").strip() else []) + [
             (_(u"Szyfrowane"), replica_crypt_words(r)),
             (_(u"Cel"), _(u"%s   (pula %s)") % (r.get("dst", "?"), (r.get("dst") or "?").split("/")[0]))]
    # U130 (wlasciciel 2026-10-29): zrodla repliki w panelu, nie w dolnej zakladce
    for _s in r.get("sources") or ([r["source"]] if r.get("source") else []):
        pairs.append((_(u"Źródło %s cel") % ch.right, u"%s %s %s" % (_s, ch.right, r.get("dst") or "?")))
    pairs += [(_(u"Rekurencyjnie"), _(u"tak") if r.get("recursive") == "yes" else _(u"nie")),
              (_(u"Historia"), _(u"wszystkie migawki") if (r.get("history") or "all") == "all" else r.get("history")),
             group(ch, _(u"Kiedy")),
             (_(u"Nośnik"), media_state_line(r, MEDIA_STATES.get(r.get("present", "unknown"), MEDIA_STATES["unknown"]))),
             (_(u"Kiedy"), when),
             (_(u"Dyski"), replica_disks_words(r)),
             (_(u"Ostatnio podłączony"), dshow(r.get("last_seen")) or _(u"nigdy (brak pliku last-seen bramy)")),
             group(ch, _(u"Zdrowie"))]
    if stats_failed:
        pairs.append((_(u"Ostatni bieg"), _(u"? (job-stats nie odpowiedział)")))
    elif srow:
        _rc = srow.get("last_rc")
        pairs.append((_(u"Ostatni bieg"), u"%s   %s" % (dshow(srow.get("last_at") or "?"), u"OK" if str(_rc) == "0" else _(u"BŁĄD (rc=%s)") % _rc)))
        pairs.append((_(u"Czas"), times_words(srow.get("last_s"), srow.get("avg_s"), srow.get("max_s"))))
        pairs.append((_(u"Wywołania"), _(u"%s, błędów %s") % (srow.get("runs"), srow.get("failures"))))
    else:
        pairs.append((_(u"Ostatni bieg"), _(u"brak w oknie statystyk (zadanie nie biegło albo dysku nie było)")))
    return pairs


def render_nosniki(data, cursor, width, height, now, ch, message="", focus="list", pair_cursor=0, ti=0, jobrows=None):
    if data.failed("replicas"):
        scr = Screen()
        scr.lines = [top_bar(data, width, now, ch.ascii, len(data.errors))] + box(ch, _(u"Replika"), source_error_body(ch, "replicas", data, "list-replicas"), width)
        scr.bars.add(0)
        while len(scr.lines) < height - 1:
            scr.lines.append(fit("", width))
        scr.lines = scr.lines[:height - 1]
        push_key_bar(scr, "nosniki", width, screen_actions("nosniki"))
        return scr
    reps = list((data.replicas or {}).get("replicas", []))
    cells = []
    for r in reps:
        st = MEDIA_STATES.get(r.get("present", "unknown"), MEDIA_STATES["unknown"])
        s = r.get("schedule") or "?"
        cells.append([r.get("name") or "?", replica_type_word(r), dshow((r.get("last_current") or _(u"brak"))[:16]),
                      replica_last_run(replica_stats_row(data, r.get("name")), data.failed("stats")),
                      _(u"po podłączeniu") if s == "on-insert" else cron_words(s) + (_(u" + po podłączeniu") if r.get("on_insert") == "yes" else "")])
    det_title, det, child = u"", [], None
    if reps and 0 <= cursor < len(reps):
        r = reps[cursor]
        det_title = _(u"%s -- replika") % r.get("name")
        det = replica_detail_pairs(r, ch, replica_stats_row(data, r.get("name")), data.failed("stats"))
        tabs = TABS["nosniki"]
        ti = ti % len(tabs)
        child = rep_children(tabs[ti][0], r, data, now, ch, jobrows)
        child.update({"name": r.get("name"), "tabs": tabs, "ti": ti})
    empty = [_(u"Brak sekcji [replica:] w configu tego kolektora."),
             _(u"Brak skonfigurowanych replik dla tego kolektora"),
             _(u"Ins dodaje ją w oknach; komendą wsadową: zfs-backup.sh add-replica NAZWA --source=DS --dst=PULA/BAZA")]
    if not reps:
        det_title = _(u"stany nośnika")
        det = [(_(MEDIA_STATES[k][0]), _(MEDIA_STATES[k][2])) for k in ("here", "available", "away", "wrong_medium")]
    return render_tabbed(data, width, height, now, ch, "nosniki", _(u"Repliki backupu kolektora (%d)") % len(reps),
                         [_(u"Replika"), _(u"Typ"), _(u"Wykonana"), _(u"Ostatni bieg"), _(u"Harmonogram")], cells, cursor,
                         (_(u"Enter szczegóły   Ins nowa   Del usuń   Tab do przebiegów")) if reps else _(u"Ins nowa replika"),
                         det_title, det, child, focus, pair_cursor, screen_actions("nosniki"), empty, prio=[0, 3, 1, 2, 4], flex=4)


# --- F5 Szablony (uwaga 24, 2026-10-09) ------------------------------------
TEMPLATE_KIND = {"package": u"fabryczny", "user": u"własny", "shadow": u"POMIJANY"}


def template_detail_pairs(p):
    """Panel szablonu (F5), U21: Rodzaj, Sposob, Trzyma i Uzyty sa w liscie,
    szczeble i relacje -- w zakladkach."""
    w = profile_words(p)
    pairs = []
    if p.get("source") == "shadow":
        pairs.append((_(u"Uwaga"), _(u"ma nazwę fabrycznego, pakiet go pomija; zmień nazwę pliku")))
    pairs += [(_(u"Opis"), _(p.get("description") or "-")),
              (_(u"Jak liczy"), u"%s, %s" % (w["mech"], w["shape"]))]
    if p.get("error"):
        pairs.append((_(u"Błąd"), p["error"]))
    pairs.append((_(u"Plik"), p.get("file") or "?"))
    return pairs


def render_szablony(data, cursor, width, height, now, ch, message="", rows=None, focus="list", pair_cursor=0, ti=0):
    profs = list(data.profiles or [])
    if data.failed("profiles") and not profs:
        scr = Screen()
        scr.lines = [top_bar(data, width, now, ch.ascii, len(data.errors))] + box(ch, _("Szablony"), source_error_body(ch, "profiles", data, "list-profiles"), width)
        scr.bars.add(0)
        while len(scr.lines) < height - 1:
            scr.lines.append(fit("", width))
        scr.lines = scr.lines[:height - 1]
        push_key_bar(scr, "szablony", width, screen_actions("szablony"))
        return scr
    cells = []
    for x in profs:
        w = profile_words(x)
        cells.append([x.get("name") or "?", _(TEMPLATE_KIND.get(x.get("source"), x.get("source") or "?")), w["mech"],
                      w["retention"].replace(_(u"trzyma %s") % u"", u""), str(int(x.get("used_by") or 0))])
    det_title, det, child = u"", [], None
    if profs and 0 <= cursor < len(profs):
        p = profs[cursor]
        det_title = _(u"%s -- szablon") % p.get("name")
        det = template_detail_pairs(p)
        tabs = TABS["szablony"]
        ti = ti % len(tabs)
        child = tpl_children(tabs[ti][0], p, rows, now, ch)
        child.update({"name": p.get("name"), "tabs": tabs, "ti": ti})
    return render_tabbed(data, width, height, now, ch, "szablony", _(u"Szablony retencji (%d)") % len(profs),
                         [_(u"Nazwa"), _(u"Rodzaj"), _(u"Sposób"), _(u"Trzyma"), _(u"Użyty")], cells, cursor,
                         _(u"Enter szczegóły   Ins nowy z zaznaczonego   Del usuń własny   Tab niżej"),
                         det_title, det, child, focus, pair_cursor, screen_actions("szablony"),
                         [_(u"Brak szablonów (list-profiles).")], prio=[0, 3, 2, 4, 1], flex=3)


# --- Odzysk (F11) ----------------------------------------------------------
# WLASCICIEL 2026-10-18: odzysk to osobny ekran glowny, nie litera 'p' obok "e
# zmien" w oknie relacji ani F9 na Replice -- "ktos moze sie machnac". Jedna droga:
# relacja (albo dysk) -> te same okna "Przywroc" co wczesniej (dataset, migawka,
# plan, WYKONAJ). Logika jest w `restore --ask`; ten ekran tylko wybiera skad.
def odzysk_rows(rows, data=None, now=None):
    """Relacje, z ktorych jest co odzyskac (maja kopie), plus wiersz "z innego
    dysku". Migawki lokalne i zdalne nie maja kopii -- nie ma ich na liscie."""
    out = []
    for r in rows or []:
        if r.get("kind") != "relation":
            continue
        rel = r.get("rel") or {}
        if rel.get("state") == "removed" or rel.get("mode") == "snaponly":
            continue
        if rel.get("mode") == "local" and not rel.get("client_target"):
            continue
        newest = None
        for t in ((data.progress or {}).get("jobs", []) if data is not None else []):
            if t.get("label") == r["name"] and t.get("state") != "running":
                e = int(t.get("finished_epoch") or 0)
                newest = e if newest is None or e > newest else newest
        out.append({"kind": "relation", "name": r["name"], "typ": r.get("typ") or "?", "dir": r.get("dir") or "?",
                    "stan": state_word(rel), "rel": rel, "newest": newest})
    out.append({"kind": "disk", "name": _(u"z innego dysku"), "typ": _(u"nośnik"), "dir": _(u"dysk podłączony do tego hosta"), "stan": "",
                "newest": None})
    return out


def odzysk_detail(row, copies=()):
    if row.get("kind") == "disk":
        return [(_(u"Skąd"), _(u"kopia na dysku podłączonym do tego hosta -- nośnik repliki albo dysk przyniesiony po awarii")),
                (_(u"Kiedy"), _(u"także bez relacji i bez replik, np. czysty serwer po ransomware")),
                group(None, _(u"Zgody")),
                (_(u"Na bok"), _(u"tak -- do nowego datasetu, istniejące dane nietknięte")),
                (_(u"Przeglądanie"), _(u"Enter: migawka tylko do odczytu, mc")),
                (_(u"Przywracanie"), _(u"F9: okna Przywróć -- plan i WYKONAJ"))]
    path = compact_paths(list(copies)) if copies else "?"
    return [group(None, _(u"Kopie")),
            (_(u"Ścieżka"), path),
            (_(u"Kierunek"), row.get("dir") or "?"),
            group(None, _(u"Odzysk")),
            (_(u"Na źródło"), _(u"wymaga zgody źródła (deploy.sh --allow-restore)")),
            (_(u"Na bok"), _(u"do nowego datasetu obok, oryginał nietknięty"))]


def render_odzysk(data, rows, cursor, width, height, now, ch, message="", focus="list", pair_cursor=0, ti=0, ctx=None):
    items = odzysk_rows(rows, data, now)
    cells = [[x["name"], x["typ"], fmt_when_short(x["newest"], now) if x.get("newest") else "-"] for x in items]
    det_title, det, child = u"", [], None
    if items and 0 <= cursor < len(items):
        x = items[cursor]
        det_title = _(u"%s -- odzysk") % x["name"]
        child = odz_children("ds", x, rows, data, now, ch)
        det = odzysk_detail(x, [it.get("dataset") for it in child.get("items") or [] if it.get("dataset")])
        if ctx and ctx.get("rel") == x.get("name") and (ctx.get("dataset") or ctx.get("at")):
            det = [group(ch, _(u"Wskazane")),
                   (_(u"Dataset"), ctx.get("dataset") or _(u"(wybierzesz w oknie)")),
                   (_(u"Chwila"), time.strftime(DT_FMT, time.localtime(ctx["at"])) if ctx.get("at") else _(u"najnowsza migawka"))] + det
        child.update({"name": x["name"], "tabs": TABS["odzysk"], "ti": 0})
    host = (data.jobs or {}).get("host") or ""
    return render_tabbed(data, width, height, now, ch, "odzysk", (_(u"Kopie na %s") % host).strip(),
                         [_(u"Skąd"), _(u"Rodzaj"), _(u"Najnowsza kopia")], cells, cursor, _(u"Enter przeglądaj   Tab do datasetów"),
                         det_title, det, child, focus, pair_cursor, screen_actions("odzysk"))


# --- F4 Kopie: dwa panele (wlasciciel 2026-10-28, wariant B symulacji) ------------------
# Lewy panel to ULATWIENIE: datasety kopii tego hosta, pogrupowane po relacji i replice,
# wspolny poczatek sciezki raz w naglowku grupy. Prawy panel to PRAWDA Z DYSKU: migawki
# zaznaczonego datasetu czytane na zywo, kolumny jak `zfs list -t snapshot` (NAME, USED,
# REFER, CREATION) -- widok, ktory admin zna z basha i ktoremu ufa. Enter na migawce
# montuje ja tylko do odczytu (browse --snapshot=), F9 otwiera odzysk z niej.
ZFS_DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
ZFS_MONS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def zfs_creation(epoch):
    """CREATION jak w `zfs list`: 'Wed Oct 28 10:15 2026' (niezaleznie od locale)."""
    t = time.localtime(int(epoch or 0))
    return u"%s %s %2d %2d:%02d %d" % (ZFS_DAYS[t.tm_wday], ZFS_MONS[t.tm_mon - 1], t.tm_mday, t.tm_hour, t.tm_min, t.tm_year)


def common_base(roots):
    """Wspolny poczatek sciezek (pelne segmenty, z '/' na koncu), krotszy niz kazda z nich."""
    segs = [r.split("/") for r in roots if r]
    if not segs:
        return ""
    com = []
    for parts in zip(*segs):
        if len(set(parts)) != 1:
            break
        com.append(parts[0])
    if len(com) >= min(len(s) for s in segs):
        com = com[:-1]
    return "/".join(com) + "/" if com else ""


def kopie_copy_root(dst, src):
    """Sciezka kopii na tym hoscie z pary relacji: pull podaje pelna sciezke (konczy sie
    zrodlem), kopia lokalna -- baze, pod ktora kopia lezy jako baza/zrodlo."""
    d = dst or ""
    s_ = ((src or "").split() or [""])[0].rsplit(":", 1)[-1]
    if d and s_ and d != s_ and not d.endswith("/" + s_):
        d = u"%s/%s" % (d.rstrip("/"), s_)
    return d


def kopie_groups(rows, data, now, ch):
    """Grupy lewego panelu: relacje z kopiami na tym hoscie, potem repliki (nosnik
    podlaczony -> korzenie dst/zrodlo; odlaczony -> sama grupa z uwaga)."""
    groups = []
    for x in odzysk_rows(rows, data, now):
        if x.get("kind") != "relation":
            continue
        kids = odz_children("ds", x, rows, data, now, ch).get("items") or []
        roots = []
        for it in kids:
            d = it.get("dataset") or ""
            # Kopia lokalna (pve2, 2026-10-28): para podaje jako cel BAZE (hdd/backups/pve2),
            # a kopia lezy pod baza/zrodlo -- bez tego grupa pokazywala cale drzewo bazy,
            # z kopiami innych relacji. Pull podaje pelna sciezke (konczy sie zrodlem).
            d = kopie_copy_root(d, it.get("src"))
            if d and ":" not in d and d not in roots:
                roots.append(d)
        groups.append({"kind": "relation", "name": x["name"], "word": _(u"relacja %s") % x["name"],
                       "what": u"%s  %s" % (x.get("typ") or "", x.get("dir") or ""), "roots": roots, "note": "",
                       "typ": x.get("typ") or "", "dir": x.get("dir") or ""})
    for r in ((data.replicas or {}).get("replicas") or []) if data is not None else []:
        here = r.get("present") == "here"
        srcs = r.get("sources") or [s for s in (r.get("source") or "").split(",") if s]
        roots = [u"%s/%s" % (r.get("dst", "").rstrip("/"), s) for s in srcs] if here and r.get("dst") else []
        groups.append({"kind": "replica", "name": r.get("name") or "?", "word": _(u"replika %s") % (r.get("name") or "?"),
                       "what": r.get("media") or "", "roots": roots, "typ": _(u"replika"), "dir": r.get("media") or "",
                       "note": u"" if here else _(u"nośnik niepodłączony -- podłącz go, potem Ctrl-R")})
    return groups


def kopie_items(groups, tree):
    """Wiersze lewego panelu: naglowki grup (nie do wyboru), datasety (do wyboru) i na
    koncu 'inny dysk' -- pula spoza relacji i replik (stare okna wyboru)."""
    out = []
    for g in groups:
        base = common_base(g["roots"])
        out.append({"hdr": True, "g": g, "base": base})
        seen, n0 = set(), len(out)
        for root in g["roots"]:
            for d in tree:
                nm = d.get("name") or ""
                if nm in seen or not (nm == root or nm.startswith(root + "/")):
                    continue
                seen.add(nm)
                depth = nm[len(root):].count("/")
                label = nm[len(base):] if nm == root else u"  " * depth + nm.rsplit("/", 1)[-1]
                out.append({"g": g, "ds": nm, "label": label, "snaps": int(d.get("snapshots") or 0),
                            "newest": int(d.get("newest") or 0), "type": d.get("type") or "filesystem"})
        if len(out) == n0:
            out.append({"g": g, "note": g.get("note") or _(u"brak datasetów kopii na tym hoście")})
    out.append({"any": True, "label": _(u"inny dysk -- pula spoza relacji i replik")})
    return out


def kopie_snap_items(doc, ds):
    """Prawy panel: migawki datasetu (najnowsza na gorze) jako wiersze tabeli."""
    items = []
    for s in (doc or {}).get("snapshots") or []:
        nm = s.get("name") or ""
        short = nm.split("@", 1)[1] if "@" in nm else nm
        items.append({"cells": [u"@" + short, hbytes_short(int(s.get("used") or 0)), hbytes_short(int(s.get("refer") or 0)),
                                zfs_creation(s.get("creation"))],
                      "name": nm if "@" in nm else u"%s@%s" % (ds, short), "creation": int(s.get("creation") or 0),
                      "kopie": True})
    return items


def render_kopie_tab(data, items, selix, cursor, focus, scur, snaps, snaps_err, width, height, now, ch, ctx=None, grouped=False):
    """F4 Kopie w UKLADZIE F2 (wlasciciel 2026-10-29: „Zrób go taki sam jak w jobs. To jest
    eleganckie okno”; dwa panele z drzewem: „badziewne okno”). Ta sama funkcja co F2/F3
    (render_tabbed): u gory TABELA kopii -- jeden wiersz = jeden dataset kopii -- z prawej
    fakty o wierszu, na dole zakladka Migawki (kolumny jak `zfs list -t snapshot`). Stan i
    klawisze bez zmian: Tab/Enter do migawek, Enter na migawce przeglada, F9 przywraca."""
    cells, rows = [], []
    bar = u"|" if ch.ascii else u"│"
    last_g, ccur = None, 0
    for i in selix:
        it = items[i]
        g = it.get("g")
        # GRUPY jak F2 po F9: naglowek relacji z rodzajem i kierunkiem (tylko do czytania),
        # pod nim jej kopie z wcieciem. Kursor chodzi po kopiach; ccur = jego wiersz w tabeli.
        if grouped and g is not None and g is not last_g:
            cells.append([u"%s%s  %s  %s" % (u"> " if ch.ascii else u"▸ ", g["name"], g.get("typ") or u"", g.get("dir") or u""), u" ", u" "])
            last_g = g
        if len(rows) == cursor:
            ccur = len(cells)
        rows.append(it)
        if it.get("any"):
            cells.append([_(u"inny dysk -- pula spoza relacji i replik"), u" ", u" "] if grouped
                         else [u" ", u" ", _(u"inny dysk -- pula spoza relacji i replik"), u" ", u" "])
            continue
        if it.get("note"):
            cells.append([u"  %s %s" % (bar, it["note"]), u" ", u" "] if grouped
                         else [g["name"], g.get("typ") or u" ", it["note"], u" ", u" "])
            continue
        ds = it["ds"] + (u"  (zvol)" if it.get("type") == "volume" else u"")
        when = fmt_when_short(it["newest"], now) if it.get("newest") else u"-"
        if grouped:
            cells.append([u"  %s %s" % (bar, ds), str(it.get("snaps") or 0), when])
        else:
            cells.append([g["name"], g.get("typ") or u"", ds, str(it.get("snaps") or 0), when])
    if not grouped:
        ccur = cursor
    cur = rows[cursor] if 0 <= cursor < len(rows) else {}
    det_title, det, child = u"", [], None
    if cur.get("ds"):
        g = cur["g"]
        det_title = u"%s -- %s" % (g["name"], cur["ds"].rsplit("/", 1)[-1])
        det = [group(ch, _(u"Kopia")), (_(u"Dataset"), cur["ds"]),
               (_(u"Relacja"), u"%s  %s" % (g["name"], g.get("typ") or u"")),
               (_(u"Kierunek"), g.get("dir") or u"-"),
               (_(u"Migawek"), str(cur.get("snaps") or 0)),
               (_(u"Najnowsza"), fmt_full(cur["newest"]) if cur.get("newest") else u"-")]
        if cur.get("type") == "volume":
            det.append((_(u"Rodzaj"), _(u"dysk maszyny (zvol) -- przy przeglądaniu wybierzesz partycję")))
        if ctx and (ctx.get("dataset") or ctx.get("at")) and ctx.get("rel") == g["name"]:
            det = [group(ch, _(u"Wskazane")),
                   (_(u"Dataset"), ctx.get("dataset") or _(u"(wybierzesz w oknie)")),
                   (_(u"Chwila"), time.strftime(DT_FMT, time.localtime(ctx["at"])) if ctx.get("at") else _(u"najnowsza migawka"))] + det
        sitems = []
        for x in snaps or []:
            y = dict(x)
            y["title"] = y.get("name") or u""
            # w panelu sama migawka (@...) -- pelna nazwa ds@... w waskim panelu lamala sie na dwa
            # wiersze; dataset stoi wiersz nizej i w tytule zakladki
            y["pairs"] = [group(ch, _(u"Migawka")), (_(u"Migawka"), u"@" + (y.get("name") or u"").split("@", 1)[-1]),
                          (_(u"Czas"), fmt_full(y.get("creation")) if y.get("creation") else u"-"),
                          (_(u"Dataset"), cur["ds"]), (_(u"Relacja"), g["name"])]
            sitems.append(y)
        child = {"name": cur["ds"], "tabs": [("snaps", _(u"Migawki"))], "ti": 0,
                 "heads": [u"NAME", u"USED", u"REFER", u"CREATION"], "items": sitems,
                 "empty": snaps_err or _(u"brak migawek"),
                 "foot": _(u"Enter przeglądaj   F9 przywróć   Esc wraca   Tab do linii poleceń")}
    elif cur.get("note"):
        g = cur["g"]
        det_title = g["name"]
        det = [(_(u"Relacja"), u"%s  %s" % (g["name"], g.get("typ") or u"")), (_(u"Kierunek"), g.get("dir") or u"-"),
               (_(u"Uwaga"), cur["note"])]
    elif cur.get("any"):
        det_title = _(u"inny dysk")
        det = [(_(u"Inny dysk"), _(u"najpierw zaimportuj pulę (zpool import), potem Enter"))]
    host = (data.jobs or {}).get("host") if data is not None and data.jobs else ""
    title = (_(u"Kopie na %s") % (host or u"")).strip() + (_(u", po relacjach") if grouped else u"")
    heads = ([_(u"Kopia"), _(u"Migawek"), _(u"Najnowsza")] if grouped
             else [_(u"Relacja"), _(u"Rodzaj"), _(u"Kopia"), _(u"Migawek"), _(u"Najnowsza")])
    return render_tabbed(data, width, height, now, ch, "odzysk", title, heads, cells, ccur,
                         _(u"Enter/Tab do migawek"), det_title, det, child, focus, scur, screen_actions("odzysk", grouped=grouped),
                         prio=([0, 2, 1] if grouped else [0, 2, 4, 3, 1]))


def render_kopie(data, items, sel, focus, scur, snaps, snaps_err, width, height, now, ch, ctx=None):
    """F4 Kopie: lewy panel datasety, prawy migawki (zfs list), dol szczegoly."""
    scr = Screen()
    avail = height - 2
    bot_h = 7
    top_h = max(8, avail - bot_h)
    lw = max(40, min(int(width * 0.42), width - 40))
    rw = width - lw
    linner, rinner = lw - 4, rw - 4
    mark = ">" if ch.ascii else u"▸"
    # lewy panel
    lines, cur_line = [], None
    for i, x in enumerate(items):
        if x.get("hdr"):
            if lines:
                lines.append(u"")
            g = x["g"]
            lines.append(fit(u"%s %s  %s" % (mark, g["word"], g["what"]), linner))
            if x.get("base"):
                lines.append(fit(u"  " + x["base"], linner))
            continue
        if x.get("note"):
            lines.append(fit(u"    " + x["note"], linner))
            continue
        if x.get("any"):
            lines.append(u"")
            txt = u"  " + x["label"]
        else:
            right = u"%5d  %s" % (x["snaps"], fmt_when_short(x["newest"], now) if x["newest"] else u"-")
            txt = fit(u"  " + x["label"], max(8, linner - len(right) - 1)) + u" " + right
        if i == sel:
            cur_line = len(lines)
            if focus == "pairs":
                txt = mark + txt[1:]
        lines.append(fit(txt, linner))
    body_h = top_h - 2
    first = 0
    if cur_line is not None and cur_line >= body_h:
        first = cur_line - body_h + 1
    lbody = lines[first:first + body_h]
    while len(lbody) < body_h:
        lbody.append(u"")
    host = ((data.jobs or {}).get("host") or "") if data is not None else ""
    lfoot = _(u"Enter/Tab do migawek") if focus != "pairs" else u""
    left = box(ch, (_(u"Kopie na %s") % host).strip(), lbody, lw, footer=lfoot)
    # prawy panel
    cur = items[sel] if 0 <= sel < len(items) else {}
    ds = cur.get("ds") or u""
    rbody, rcur = [], None
    if cur.get("any"):
        rbody = wrap(_(u"Pula spoza relacji i replik (np. dysk przyniesiony po awarii): Enter otwiera okna wyboru zaimportowanej puli i migawki, F9 -- odzysk z niej."), rinner)
    elif not ds:
        rbody = wrap(cur.get("note") or u"", rinner)
    elif snaps_err:
        rbody = wrap(_(u"zfs-snapshots: %s") % snaps_err, rinner)
    elif not snaps:
        rbody = wrap(_(u"%s nie ma migawek") % ds, rinner)
    else:
        hdr, rl = table_fit([u"NAME", u"USED", u"REFER", u"CREATION"], [s["cells"] for s in snaps], rinner, ch, prio=(0, 3, 1, 2), flex=0)
        rbody = [hdr, ch.dash * rinner]
        room = top_h - 4
        sc = min(scur, len(rl) - 1)
        rfirst = max(0, sc - room + 1)
        for j in range(rfirst, min(len(rl), rfirst + room)):
            if j == sc:
                rcur = len(rbody)
            rbody.append(rl[j])
    rbody = rbody[:top_h - 2]
    while len(rbody) < top_h - 2:
        rbody.append(u"")
    rtitle = u"zfs list -t snapshot %s" % ds if ds else _(u"Migawki")
    if len(rtitle) > rw - 8:
        rtitle = u"zfs list -t snapshot ..." + ds[-max(8, rw - 32):]
    rfoot = _(u"Enter przeglądaj   F9 przywróć   Esc do datasetów") if focus == "pairs" else u""
    right = box(ch, rtitle, rbody, rw, double=(focus == "pairs"), footer=rfoot)
    out = [top_bar(data, width, now, ch.ascii, len(data.errors) if data is not None else 0)]
    out += side_by_side(left, right, width, ch)
    if focus == "pairs" and rcur is not None:
        scr.cursor_y, scr.cursor_span = 2 + rcur, (lw + 2, width - 2)
    elif focus != "pairs" and cur_line is not None:
        scr.cursor_y, scr.cursor_span = 2 + cur_line - first, (2, lw - 2)
    # dol: szczegoly zaznaczonej pozycji
    det = []
    if ds:
        g = cur["g"]
        det.append((_(u"Dataset"), ds))
        if focus == "pairs" and snaps:
            s = snaps[min(scur, len(snaps) - 1)]
            det.append((_(u"Migawka"), s["name"]))
            det.append((_(u"Czas"), fmt_full(s["creation"])))
        det.append((_(u"Skąd"), u"%s  %s" % (g["word"], g["what"])))
        det.append((_(u"Rodzaj"), _(u"dysk maszyny (zvol) -- przy przeglądaniu wybierzesz partycję") if cur.get("type") == "volume"
                    else _(u"system plików")))
    elif cur.get("any"):
        det.append((_(u"Inny dysk"), _(u"najpierw zaimportuj pulę (zpool import), potem Enter")))
    pl = detail_kv(ch, det, width - 4)[:bot_h - 2]
    while len(pl) < bot_h - 2:
        pl.append(u"")
    out += box(ch, _(u"Szczegóły"), pl, width, double=False)
    scr.lines = out
    for y, ln in enumerate(scr.lines):
        if y and ln and ln[0] in (ch.dtl, ch.dbl, ch.stl, ch.sbl):
            scr.titles.add(y)
    scr.bars.add(0)
    while len(scr.lines) < height - 1:
        scr.lines.append(fit("", width))
    scr.lines = scr.lines[:height - 1]
    push_key_bar(scr, "odzysk", width, screen_actions("odzysk"))
    return scr


# --- Pomoc -----------------------------------------------------------------
HELP = [
    u"To okna do obsługi zfs-snapshot-all. Każda akcja uruchamia zwykłe polecenie zfs-backup.sh, nic więcej.",
    "",
    u"  F2  Przebiegi  biegi zadań na jednej osi czasu: nad kreską „teraz” te z",
    u"                 ostatnich 12 h (wynik, czas, powód błędu), pod nią nadchodzące.",
    u"                 Panel: ten bieg i ustawienia zadania (kierunek, źródło i cel,",
    u"                 kiedy, ile trzyma, czasy, strażnik); na dole źródło → cel.",
    u"                 F7 uruchamia zadanie z wiersza nadchodzącego, F8 chowa wykonane,",
    u"                 F9 grupuje po relacji. F4 tu = Kopie od razu na tym biegu.",
    u"  F3  Relacje    zarządzanie: Enter szczegóły (opis, CONFIG i CRON; tam 'e'",
    u"                 = Zmień relację: adres hosta, datasety, szablon, retencja",
    u"                 ile trzyma źródło, program kopiujący; 's' zapisuje ustawienia",
    u"                 relacji jako nowy szablon, 'c' otwiera config do ręcznej edycji),",
    u"                 Del usuń, F7 uruchom teraz: kopia wszystkich datasetów relacji",
    u"                 zadaniem o najkrótszym odstępie (np. godzinowym), bez pytania;",
    u"                 F8 pauza/wznów; F9 eksport/import: eksport do pliku (Enter",
    u"                 zapisuje, domyślnie w /etc/zfs-snapshot-all/relations) albo",
    u"                 import: lista plików eksportu z tego katalogu, potem wynik",
    u"                 porównania (już jest / różni się / plan), t wykonuje plan.",
    u"                 Ins i Del przełączają terminal do whiptaila i wracają tu",
    u"                 z odświeżonymi danymi: Ins -- kreator krok po kroku (backup: 7",
    u"                 kroków -- rodzaj, host, datasety, dokąd, szablon, ile trzyma",
    u"                 źródło, nazwa; Wstecz = poprzedni krok), potem podsumowanie",
    u"                 (pozycja = popraw krok; konto i dodatki w Zaawansowane) i",
    u"                 Utwórz -> plan -> WYKONAJ z oknem postępu. Del to",
    u"                 usunięcie całej relacji (źródło, nazwa, opcjonalnie kopie).",
    u"                 Pozostałe akcje: NAJPIERW komenda bash, potem 't', potem",
    u"                 wyjście na żywo. Esc zamyka okno, a proces biegnie dalej.",
    u"  F4  Kopie      kopie relacji i dysk z repliką: Enter przegląda (migawka",
    u"                 tylko do odczytu, mc, potem odmontowanie; dysk VM: partycja),",
    u"                 F9 przywraca (okna Przywróć -- dataset, cel, migawka, plan,",
    u"                 WYKONAJ). Z Przebiegów albo z datasetu relacji F4 otwiera od",
    u"                 razu tę kopię i tę chwilę.",
    u"  F5  Szablony   szablony retencji: Ins nowy na podstawie zaznaczonego,",
    u"                 Enter szczegóły ('e' zmienia własny), Del usuwa własny",
    u"  F6  Replika    repliki i 4 stany nośnika; Ins/Del/F7 uruchom/F8 klucz,",
    u"                 Enter+'e' zmiana",
    u"  F10 Ustawienia ustawienia hosta (/etc/zfs-snapshot-all/settings.ini): alerty",
    u"                 (adres, tryb, godzina maila, mail 'wszystko OK'), próg pojemności,",
    u"                 strażnik, szablon nowej relacji, aktualizacja, język GUI; wysłanie",
    u"                 maila testowego. Zapis: najpierw lista zmian, potem WYKONAJ.",
    u"                 Pasek u góry: „kasowanie przy pełnej puli” i „alarm przyrostu”",
    u"                 -- czy na tym hoście działa strażnik pojemności i strażnik",
    u"                 nagłego przyrostu danych; włączasz je w F10.",
    u"  Kierunek       strzałka idzie jak dane: pve9 → pve10 pobieram z pve9,",
    u"                 pve10 → pve9 wysyłam, pve10 ↔ pve9 obie strony, lokalnie = na tym hoście;",
    u"                 nazwy hostów z /etc/hosts, adres tylko gdy nazwy tam nie ma",
    "",
    u"  PANELE (każdy ekran): lista = wybór i stan; panel obok = fakty o",
    u"                 zaznaczonym wierszu, których nie widać na liście; na dole zakładki",
    u"                 z tym, co wiersz zawiera (F3: Datasety, Zadania; F5: Szczeble,",
    u"                 Używają; F6: Przebiegi; F4: Migawki). Tab wchodzi",
    u"                 na dół, strzałki w lewo/prawo zmieniają zakładkę, panel obok",
    u"                 pokazuje zaznaczony element, Enter jego pełne okno, Esc",
    u"                 wraca do listy, kolejny Tab do linii poleceń. Datasety relacji",
    u"                 bez wpisów w cronie pochodzą z zapisanej definicji relacji",
    u"                 (mówi to tytuł zakładki).",
    "",
    u"  LINIA POLECEŃ nad listwą klawiszy (jak w mc): pisz, Enter wykonuje na",
    u"                 pierwszym planie w katalogu repo, po komendzie Enter wraca.",
    u"                 Tab przechodzi do linii poleceń (i z powrotem do listy); w niej",
    u"                 strzałki = historia, Esc/Ctrl-U czyści. Linia jest widoczna",
    u"                 także pod oknem: potwierdzenie pokazuje w niej swoją komendę,",
    u"                 a Tab przenosi ją do linii, żeby ją poprawić przed",
    u"                 wykonaniem. Litery i cyfry NIE są skrótami klawiszowymi --",
    u"                 wszystko, co wpiszesz, trafia do linii.",
    "",
    u"  F1-F6             główne okna (F4 Kopie: przeglądanie i odzysk); F12 wyjście",
    u"  F7 F8 F9          akcje BIEŻĄCEGO okna -- podpisane TYLKO na pasku na dole",
    u"                    (wąski terminal: zapis skrócony, cyfra = klawisz F)",
    "",
    u"  strzałki          ruch po liście     PgUp PgDn Home End   szybciej",
    u"  Ctrl-R            odśwież źródła (monitor liczy na żywo, to chwilę trwa)",
    u"  Ctrl-O            konsola pod oknami: wynik ostatnich poleceń; dowolny klawisz wraca",
    u"  Esc               zamknij okno na wierzchu (w oknie także q; j k przewijają)",
    u"  Tab               następny obiekt: lista, pary (F3), linia poleceń",
    u"  F12               wyjście (litery idą do linii poleceń, więc q nie wychodzi)",
    "",
    u"Słowa w kolumnie 'Kopie':",
    u"  aktualne       najnowsza migawka mieści się w progu ostrzegawczym",
    u"  spóźnione      przekroczony próg ostrzegawczy, nie krytyczny",
    u"  stare          przekroczony próg krytyczny",
    u"  nie odpowiada  monitor PYTAŁ i nie dostał odpowiedzi (np. dataset zniknął)",
    u"  bez monitora   NIKT nie pyta: kopia się robi, nikt nie sprawdza czy dalej",
    "",
    u"Źródła: status, list-jobs, monitor, progress, list-replicas, show-config --json.",
    u"Ekran nie ma własnej kopii żadnej reguły: czego nie ma w JSON, nie ma tutaj.",
]


# ---------------------------------------------------------------------------
# STAN INTERFEJSU: klawisze -> stan, bez terminala
# ---------------------------------------------------------------------------
class UI(object):
    """Caly stan interfejsu i przejscia po klawiszach. Bez curses, zeby dalo
    sie to przetestowac sekwencja klawiszy (`--keys`)."""

    def __init__(self, repo, files, ch, now=None, exec_log=None):
        self.repo, self.files, self.ch = repo, files, ch
        # Ins na F3 oddaje terminal czasownikowi `new-relation` (okna whiptail,
        # decyzja wlasciciela 2026-09-16) i wraca TUTAJ po jego zakonczeniu.
        # Stary kreator rysowany recznie zostal usuniety 2026-09-21 -- dwie drogi
        # do tego samego ekranu to dwie drogi do utrzymania, a suita whiptaila
        # pokrywa te, ktora operator naprawde widzi.
        self.pending_nowait = False
        self.rel_names_before = None   # Ins: lista relacji sprzed oddania terminala kreatorowi
        self.now_fixed = now
        self.exec_log = exec_log   # testy: zamiast uruchamiac, zapisz komende tutaj
        self.screen = "zadania"
        self.cursor = {"zadania": 0, "relacje": 0, "monitor": 0, "szablony": 0, "nosniki": 0, "odzysk": 0}
        self.window = None        # ("relacja", row) | ("pomoc", None) | ("prompt"|"confirm"|"output", dict)
        self.scroll = 0
        self.message = ""
        self.focus = "list"       # "list" | "pairs" (dolny panel, U21) | "cmd"
        self.pair_cursor = 0
        self.ctab = {}            # ekran -> numer zakladki dolnego panelu (TABS)
        self.kopie_ctx = None   # F4 Kopie otwarte z Przebiegow/Relacji: {"rel", "dataset", "at"}
        self.zad_sort = 0   # kolejnosc zadan (F3 zakladka Zadania): relacje, w srodku wg nastepnego
        self.prz_done, self.prz_group = True, False   # F2 Przebiegi: F8 wykonane, F9 grupy
        self.kopie_group = False                      # F4 Kopie: F8 grupy (jak F9 na F2)
        # LINIA POLECEN (wlasciciel 2026-09-11: "chcemy moc w kazdej chwili
        # pisac komendy z palca"). Styl mc: kazdy drukowalny znak leci tu,
        # Enter wykonuje NA PIERWSZYM PLANIE (curses zawieszone), historia w
        # ~/.zfs-tui/history. q/r/j/k/cyfry sa skrotami TYLKO przy pustej linii.
        self.cmd = ""
        self.cmd_hist = self.load_history()
        self.hist_pos = None
        self.pending_shell = None
        self.pending_log_path = None   # Del/Ins: dziennik dla ZFS_TUI_LOG, do dopisania do message po biegu
        # Start jak powrot z okna: ekran po czterech szybkich czytnikach, monitor i job-stats
        # drugim etapem (przejscie GUI pve10, 2026-10-29: start ~14 s czekal na wszystkie szesc).
        # Pliki (testy, podglad) i --offline czytaja wszystko od razu, jak refresh_bg.
        two_stage = not (files.get("offline") or exec_log or any(files.get(k) for k in ("status", "jobs", "monitors")))
        self.data = collect(repo, files, self.FAST_READERS if two_stage else None)
        if two_stage:
            self.data.pending = set(self.SLOW_READERS)
            self._slow_want = self.SLOW_READERS
            self.start_slow()
            self.message = _(self.MON_NOTE)
        self.rows = mark_pending(build_relations(self.data, self.now()), self.data)
        self.jobrows = sort_zad_rows(mark_pending(build_jobs(self.data, self.now()), self.data), self.zad_sort, self.data)
        self.runrows = build_runs(self.data, self.jobrows, self.now(), self.prz_done, self.prz_group)
        # F2 otwiera sie PRZY "teraz" (najblizszy nadchodzacy bieg), nie na najstarszym
        # biegu sprzed 12 h (przejscie GUI pve10, 2026-10-28). Home = gora listy.
        self.cursor["zadania"] = self.run_cursor_for(None)
        self.prefetch_kopie()

    def now(self):
        return self.now_fixed if self.now_fixed is not None else int(time.time())

    def history_path(self):
        return os.path.join(home_dir(), ".zfs-tui", "history")

    def load_history(self):
        if self.exec_log:
            return []
        try:
            with io.open(self.history_path(), encoding="utf-8", errors="replace") as fh:
                return [l.rstrip("\n") for l in fh if l.strip()][-200:]
        except (IOError, OSError):
            return []

    def save_history(self):
        if self.exec_log:
            return
        try:
            d = os.path.dirname(self.history_path())
            if not os.path.isdir(d):
                os.makedirs(d)
            with io.open(self.history_path(), "w", encoding="utf-8") as fh:
                fh.write("\n".join(self.cmd_hist[-200:]) + "\n")
        except (IOError, OSError):
            pass

    def prompt_text(self):
        user = os.environ.get("USER") or os.environ.get("USERNAME") or "?"
        host = (self.data.jobs or {}).get("host") or (self.data.status or {}).get("host") or "?"
        return "%s@%s:%s$ " % (user, host, os.path.basename(self.repo.rstrip("/\\")) or "/")

    def run_cmd(self, line):
        """Enter w linii polecen. Test (exec-log) zapisuje; na zywo petla curses
        zawiesza ekran i oddaje terminal komendzie (pending_shell)."""
        line = line.strip()
        if not line:
            return "stay"
        if not self.cmd_hist or self.cmd_hist[-1] != line:
            self.cmd_hist.append(line)
        self.save_history()
        self.cmd, self.hist_pos = "", None
        if self.exec_log:
            with io.open(self.exec_log, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
            self.message = _(u"[tryb testowy] nie uruchomiono, zapisano do dziennika: ") + line
            return "stay"
        self.pending_shell = line
        return "shell"

    def start_verb_log(self, verb, line):
        """~/.zfs-tui/<verb>-<stamp>.log z naglowkiem '$ <komenda>' -- Del
        (delete-relation) i Ins (new-relation) dostaja dziennik jak
        run_detached (uwaga 5 wlasciciela: import/export go mialy, Del/Ins
        nie). Sciezka idzie do dziecka przez ZFS_TUI_LOG, zeby
        new-relation.sh/cmd_delete_relation mogly do niej dopisac swoj wlasny
        wynik."""
        logdir = os.path.join(home_dir(), ".zfs-tui")
        try:
            os.makedirs(logdir, exist_ok=True)
        except OSError:
            logdir = "/tmp"
        stamp = time.strftime("%Y%m%d-%H%M%S")
        v = "".join(c if (c.isalnum() or c in "._-") else "_" for c in verb)[:40] or "cmd"
        path = os.path.join(logdir, "%s-%s.log" % (v, stamp))
        try:
            with open(path, "wb") as hdr:
                hdr.write(("$ %s\n" % line).encode("utf-8"))
        except OSError:
            return None
        return path

    def run_dialog(self, argv, env=None):
        """Oddaj terminal dialogowi whiptail i wroc z odswiezonymi danymi.
        env: zmienne dla dialogu (U65: EDIT_DO otwiera od razu jedna czynnosc)."""
        line = " ".join(shlex.quote(x) for x in argv)
        if env:
            line = " ".join("%s=%s" % (k, shlex.quote(v)) for k, v in sorted(env.items())) + " " + line
        if self.exec_log:
            with io.open(self.exec_log, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
            self.message = _(u"[tryb testowy] nie uruchomiono, zapisano do dziennika: ") + line
            return "stay"
        line = self.window_env(argv[1] if len(argv) > 1 else "cmd", line)
        self.pending_shell, self.pending_nowait = line, True
        return "shell"

    def window_env(self, verb, line):
        """Dziennik (ZFS_TUI_LOG) i plik statusu (ZFS_TUI_STATUS) dla okna. Okno zapisuje
        do statusu swoje ostatnie slowo (wt_end w wt-lib.sh, np. "przerwane, nic nie
        zmieniono"), a GUI pokazuje je po powrocie zamiast "[rc=1] <cala linia polecenia>"
        (kampania 3, wlasciciel 2026-10-23: Esc wygladal jak blad)."""
        self.pending_title = _(WINDOW_TITLES.get(verb, verb))
        self.pending_reload = self.RELOAD_AFTER.get(verb)
        log_path = self.start_verb_log(verb, line)
        status = (log_path + ".status") if log_path else os.path.join(
            "/tmp", "zfs-tui-%d-%s.status" % (os.getpid(), time.strftime("%H%M%S")))
        try:
            os.unlink(status)
        except OSError:
            pass
        self.pending_status_path = status
        line = "ZFS_TUI_STATUS=%s %s" % (shlex.quote(status), line)
        if log_path:
            self.pending_log_path = log_path
            line = "ZFS_TUI_LOG=%s %s" % (shlex.quote(log_path), line)
            self.message = _(u"dziennik: %s") % log_path
        return line

    def window_end_message(self, rc):
        """Linia komunikatu po zamknieciu okna: jego wlasne ostatnie slowo, albo
        "zakonczone" / "zakonczone z kodem N", plus dziennik."""
        title, self.pending_title = getattr(self, "pending_title", None) or u"okno", None
        status, self.pending_status_path = getattr(self, "pending_status_path", None), None
        said = u""
        if status:
            try:
                with io.open(status, encoding="utf-8", errors="replace") as fh:
                    said = fh.readline().strip()
                    # wt_end_nochange: okno zamkniete bez zmian -- bez pelnego odswiezenia
                    if fh.readline().strip() == "nochange":
                        self.noreload_after = True
                os.unlink(status)
            except (IOError, OSError):
                said = u""
        if said:
            msg = said
        elif rc == 0:
            msg = _(u"%s: zakończone") % title
        else:
            msg = _(u"%s: zakończone z kodem %s") % (title, rc)
        log_path, self.pending_log_path = self.pending_log_path, None
        if log_path:
            msg += _(u"   dziennik: %s") % log_path
        return msg

    def rel_names(self):
        """Nazwy relacji tak, jak lista je teraz pokazuje -- do porownania PRZED i PO."""
        out = []
        for r in self.rows or []:
            n = (r.get("rel") or {}).get("name") or r.get("name")
            if n:
                out.append(n)
        return out

    def cursor_to_new(self, before):
        """Po powrocie z kreatora: kursor na relacji, ktora PRZYBYLA.

        Bez tego kursor zostawal na starym INDEKSIE, a lista jest posortowana --
        wiec po dodaniu relacji wskazywal cudzy wiersz, a panel obok pokazywal
        szczegoly nie tej relacji, ktora operator wlasnie zalozyl. Gdy przybylo
        wiecej niz jedna (albo zadna), nie zgadujemy: kursor zostaje.
        """
        new = [n for n in self.rel_names() if n not in set(before)]
        if len(new) != 1:
            return False
        try:
            self.cursor["relacje"] = self.rel_names().index(new[0])
        except ValueError:
            return False
        self.screen, self.focus = "relacje", "list"
        return True

    def run_wizard(self):
        """Ins: oddaj terminal kreatorowi whiptail i wroc na F3 z odswiezonymi danymi.
        Kreator sam konczy sie oknem z wynikiem, wiec petla nie dopytuje o Enter."""
        self.rel_names_before = self.rel_names()
        line = "%s new-relation" % shlex.quote(self.zb())
        if self.exec_log:
            with io.open(self.exec_log, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
            self.message = _(u"[tryb testowy] nie uruchomiono, zapisano do dziennika: ") + line
            return "stay"
        line = self.window_env("new-relation", line)
        self.pending_shell, self.pending_nowait = line, True
        return "shell"

    def ask_refresh(self):
        """F5 (tester R4, B7): zbieranie danych na zywym hoscie trwa kilka
        sekund (pve10: ~5,6 s). Klawisz tylko ZAMAWIA odswiezenie i wypisuje
        'odswiezam...'; petla najpierw to rysuje, potem wola run_pending()."""
        self.pending_refresh = True
        self.message = _(u"odświeżam… (czasowniki: status, list-jobs, monitor, job-stats -- kilka sekund)")

    def run_pending(self):
        if getattr(self, "pending_refresh", False):
            self.pending_refresh = False
            self.refresh()
            self.message = _(u"odświeżono %s") % time.strftime("%H:%M:%S", time.localtime(self.now()))

    # ODŚWIEŻANIE W TLE (U12/U13, właściciel 2026-10-19: "powrót do GUI trwa wszędzie
    # długo", "Esc po F7 długo wraca"). Źródła idą równolegle od P2, ale razem trwają tyle,
    # co najwolniejsze -- monitor --json, zmierzone na pve9 5,7 s. Po oknie GUI wraca OD
    # RAZU ze starymi danymi i napisem "odświeżam w tle…"; świeże dane wchodzą, gdy dojdą
    # (pętla curses pyta co 0,3 s). Fikstury i testy (offline/pliki) -- dalej od razu.
    BG_NOTE = u"   (odświeżam w tle…)"
    BG_KEY_WAIT = 30   # s: tyle klawisz po oknie czeka na świeże dane, potem przepada (REV-172)

    # POWROT W DWOCH ETAPACH (wlasciciel 2026-10-29: "Zbyt dlugo trwaja powroty z opcji do
    # glownego okna"). Zmierzone na pve10, szesc czytnikow naraz: status 0,7 s, list-replicas
    # 1,2 s, progress 2,0 s, list-jobs 2,3 s -- a monitor 4,4 s i job-stats 6,8 s. Ekran czeka
    # tylko na cztery szybkie; monitor i statystyki przebiegow dochodza drugim etapem, a do
    # tego czasu stoja ich poprzednie wartosci z dopiskiem MON_NOTE na linii komunikatu.
    SLOW_READERS = ("monitors", "stats")
    FAST_READERS = ("status", "jobs", "progress", "replicas")
    MON_NOTE = u"   (monitor i przebiegi: sprawdzam…)"
    # Co czytac po oknie, ktore cos zapisalo (zamkniecie bez zmian = nic, wt_end_nochange).
    # Brak wpisu = wszystko. Szablon zmienia tylko liste szablonow; ustawienia -- tylko status.
    RELOAD_AFTER = {"save-profile": (), "delete-profile": (), "settings": ("status",)}

    def refresh_bg(self, only=None):
        if self.files.get("offline") or self.exec_log or any(self.files.get(k) for k in ("status", "jobs", "monitors")):
            self.refresh(only)
            return
        bg = getattr(self, "_bg", None)
        if bg is not None and bg[0].is_alive():
            return
        import threading
        old = self.data
        if only is not None:
            # Odczyt celowany: reszta danych zostaje; listy czytane na zadanie odpadaja.
            old.profiles = None
            if self.screen == "szablony":
                self.ensure_profiles()
            if not only:
                return
        fast = tuple(k for k in self.FAST_READERS if only is None or k in only)
        slow = tuple(k for k in self.SLOW_READERS if only is None or k in only)
        new = Data()
        for k in self.FAST_READERS + self.SLOW_READERS:
            if k not in fast:                       # wolne i niezamowione: poprzednia wartosc
                setattr(new, k, getattr(old, k))
                if k in old.errors:
                    new.errors[k] = old.errors[k]
                if k in old.pending:                # start: jeszcze nie odpowiedzial
                    new.pending.add(k)
        files2 = dict(self.files)
        files2["_data"] = new
        box = {"full": only is None}

        def _run():
            try:
                box["data"] = collect(self.repo, files2, fast)
            except Exception as e:   # pokaż, nie wysadzaj GUI
                box["err"] = str(e)
        t = threading.Thread(target=_run)
        t.daemon = True
        t.start()
        self._bg = (t, box)
        if not (self.message or "").endswith(_(self.BG_NOTE)):
            self.message = (self.message or "") + _(self.BG_NOTE)
        if slow:
            # Drugi etap rusza dopiero PO pierwszym (poll_bg -> start_slow): pve10 ma dwa rdzenie,
            # cztery szybkie czytniki same trwaja 0,9 s, w tloku z monitorem i job-stats 6,7 s.
            self._slow_want = tuple(sorted(set(getattr(self, "_slow_want", ()) or ()) | set(slow)))

    def start_slow(self):
        slow, self._slow_want = getattr(self, "_slow_want", ()) or (), ()
        mon = getattr(self, "_bgslow", None)
        if slow and not (mon is not None and mon[0].is_alive()):
            import threading
            files3 = dict(self.files)
            files3["_data"] = Data()
            mbox = {"keys": slow}

            def _run_slow():
                try:
                    mbox["data"] = collect(self.repo, files3, slow)
                except Exception as e:
                    mbox["err"] = str(e)
            ts = threading.Thread(target=_run_slow)
            ts.daemon = True
            ts.start()
            self._bgslow = (ts, mbox)

    def slow_pending(self):
        return getattr(self, "_bgslow", None) is not None

    def poll_slow(self):
        """Drugi etap: monitor i job-stats. -> True, gdy weszly (przerysuj). Czeka, az wejdzie
        pierwszy etap -- inaczej pierwszy nadpisalby je poprzednimi wartosciami."""
        mon = getattr(self, "_bgslow", None)
        if mon is None or mon[0].is_alive() or getattr(self, "_bg", None) is not None:
            return False
        self._bgslow = None
        msg = self.message or u""
        if _(self.MON_NOTE) in msg:
            self.message = msg.replace(_(self.MON_NOTE), u"")
        d = mon[1].get("data")
        self.data.pending.difference_update(mon[1]["keys"])
        if d is None:
            self.message = (self.message or "") + _(u"   monitor nie odpowiedział: %s") % mon[1].get("err", "?")
            for k in mon[1]["keys"]:
                self.data.errors[k] = mon[1].get("err", "?")
            self.apply_data(self.data, full=False)
            return True
        for k in mon[1]["keys"]:
            setattr(self.data, k, getattr(d, k))
            if k in d.errors:
                self.data.errors[k] = d.errors[k]
            else:
                self.data.errors.pop(k, None)
        self.apply_data(self.data, full=False)
        return True

    ACTION_KEYS = ("F7", "F8", "F9", "enter", "del", "e")
    # REV-20261023-173: po NIEUDANYM odświeżeniu nie wystarcza lista klawiszy-czynności (Ins na
    # Szablonach z niej wypadł i kopiował stary szablon). Odwrotnie: przechodzą tylko klawisze,
    # które nie biorą niczego z wierszy -- ruch po liście, przełączenie ekranu (F2-F6, F11),
    # pomoc, Ctrl-R, wyjście, F10 (ustawienia hosta) i to, co linia poleceń bierze jako
    # pisanie i edycję. Klawisze F z linii poleceń idą dalej do wierszy, więc tam też stoją.
    ROW_FREE_KEYS = frozenset(("up", "down", "j", "k", "pgup", "pgdn", "home", "end", "left", "right",
                               "tab", "esc", "F1", "F10", "ctrl-r", "q", "F12")
                              + tuple(fk for _s, fk, _l in SCREENS))
    FKEYS_ALL = frozenset(("F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "ctrl-r"))

    def row_free(self, k):
        """-> True, gdy klawisz nie działa na wierszach (wolno go użyć na nieaktualnym ekranie)."""
        if k in self.ROW_FREE_KEYS:
            return True
        if k in self.FKEYS_ALL:
            return False
        if self.focus == "cmd" or self.cmd:       # linia poleceń: pisanie, edycja, Enter = polecenie admina
            return True
        # Litera bez okna i poza panelem dzieci to tekst linii poleceń ('m' w panelu działa na wierszu).
        return len(k) == 1 and k.isprintable() and self.focus != "pairs"

    def bg_pending(self):
        bg = getattr(self, "_bg", None)
        return bg is not None

    def poll_bg(self):
        """-> True, gdy dane z tła weszły (trzeba przerysować)."""
        bg = getattr(self, "_bg", None)
        if bg is None or bg[0].is_alive():
            return False
        self._bg = None
        if (self.message or "").endswith(_(self.BG_NOTE)):
            self.message = self.message[:-len(_(self.BG_NOTE))]
        data = bg[1].get("data")
        self.start_slow()
        if data is None:
            self.message = (self.message or "") + _(u"   odświeżenie w tle nie wyszło: %s") % bg[1].get("err", "?")
            self.bg_failed = True   # REV-172: wiersze zostają stare -- czynności czekają na Ctrl-R
            return True
        self.files["_data"] = data
        self.apply_data(data, full=bg[1].get("full", True))
        if self.slow_pending() and _(self.MON_NOTE) not in (self.message or u""):
            self.message = (self.message or u"") + _(self.MON_NOTE)
        before = getattr(self, "rel_names_before_bg", None)
        self.rel_names_before_bg = None
        if before is not None and self.cursor_to_new(before):
            self.message = (self.message or "") + _(u"  --  kursor na nowej relacji")
        return True

    def refresh(self, only=None):
        if only is not None:
            self.data.profiles = None           # odczyt celowany (RELOAD_AFTER): szablony od nowa
        self.apply_data(collect(self.repo, self.files, only), full=(only is None))
        if only is not None and self.screen == "szablony":
            self.ensure_profiles()

    def apply_data(self, data, full=True):
        self.data = data
        if full:
            self.bg_failed = False
            # PELNE odswiezenie czysci tez dane czytane na zadanie (wlasciciel 2026-10-09,
            # uwaga 1: "powrot do okna powinien zawsze wymuszac odswiez -- wszedzie"):
            # szablony (F5) i config relacji (panel na F3). Data jest wspoldzielona miedzy
            # odswiezeniami, wiec bez tego zapisany szablon nie pojawial sie na liscie,
            # a panel CONFIG pokazywal stan sprzed "Zmien relacje".
            self.data.profiles = None
            self.data.configs = {}
            self.data.ztree, self.data.zsnaps = {}, {}
            if self.screen == "szablony":
                self.ensure_profiles()
        prz = getattr(self, "runrows", None) or []
        old_run = prz[self.cursor["zadania"]] if self.cursor["zadania"] < len(prz) else None
        self.rows = mark_pending(build_relations(self.data, self.now()), self.data)
        self.jobrows = sort_zad_rows(mark_pending(build_jobs(self.data, self.now()), self.data), self.zad_sort, self.data)
        self.runrows = build_runs(self.data, self.jobrows, self.now(), self.prz_done, self.prz_group)
        # F2: kursor na TYM SAMYM biegu, nie na tym samym numerze wiersza. Drugi etap (job-stats)
        # dokłada wykonane biegi NAD nim -- start na pve10, 2026-10-29: "teraz" uciekło na 08:13.
        self.cursor["zadania"] = self.run_cursor_same(old_run)
        for k in self.cursor:
            # F4 liczy wiersze z drzewa kopii (zfs-tree) -- poza F4 nie czytamy go tu w glownym
            # watku: na pve10 to bylo 5 s zamrozonego "Wczytuję… 0 s" po KAZDYM oknie (zrzut stosu,
            # 2026-10-29). Drzewo czyta prefetch_kopie w tle, kursor F4 przycina kopie_state.
            if k == "odzysk" and self.screen != "odzysk":
                continue
            self.cursor[k] = min(self.cursor[k], max(0, self.count(k) - 1))
        if full:
            self.prefetch_kopie()

    def prefetch_kopie(self):
        """Kampania 2026-10-28: pierwsze F4 stalo 5,5 s z zamrozonym ekranem (pve10: zfs-tree
        po migawkach kazdego korzenia kopii). Po kazdym pelnym odczycie drzewo kopii czyta sie
        w tle, na zywo z ZFS jak dotad; F4 bierze gotowe albo czeka na tlo (load_ztree)."""
        if self.files.get("offline") or self.exec_log:
            return
        import threading

        def _run(ui=self, data=self.data):
            try:
                groups = kopie_groups(ui.rows, data, ui.now(), ui.ch)
                roots = []
                for g in groups:
                    for r in g["roots"]:
                        if r not in roots:
                            roots.append(r)
                if roots:
                    load_ztree(ui.repo, ui.files, data, roots)
            except Exception:
                pass   # F4 i tak wczyta sam
        t = threading.Thread(target=_run)
        t.daemon = True
        t.start()

    def run_cursor_same(self, old):
        """Po nowym odczycie: bieg o tej samej etykiecie i chwili (obiekty zadan sa juz nowe),
        inaczej najblizszy nadchodzacy."""
        if old is not None and old.get("kind") == "run" and old.get("label") is not None:
            for i, r in enumerate(self.runrows):
                if r.get("kind") == "run" and r.get("label") == old.get("label") and r.get("at") == old.get("at"):
                    return i
        return self.run_cursor_for(None)

    def run_cursor_for(self, old):
        """Po przebudowie Przebiegow: ten sam bieg (zadanie i chwila), inaczej
        najblizszy nadchodzacy; nigdy na kresce ani naglowku."""
        rows = self.runrows
        if old is not None and old.get("kind") == "run":
            for i, r in enumerate(rows):
                if r.get("kind") == "run" and r["item"] is old["item"] and r.get("at") == old.get("at"):
                    return i
        for i, r in enumerate(rows):
            if r.get("kind") == "run" and not r.get("past"):
                return i
        return self.run_step(0, 1)

    def run_step(self, c, d):
        """Kursor Przebiegow: przeskocz wiersze tylko do czytania (kreska, naglowek)."""
        rows = self.runrows
        if not rows:
            return 0
        c = max(0, min(c, len(rows) - 1))
        i = c
        while 0 <= i < len(rows) and rows[i].get("kind") != "run":
            i += d
        if 0 <= i < len(rows):
            return i
        i = c
        while 0 <= i < len(rows) and rows[i].get("kind") != "run":
            i -= d
        return i if 0 <= i < len(rows) else c

    def count(self, screen):
        if screen == "zadania":
            return len(self.runrows)
        if screen == "relacje":
            return len(self.rows)
        if screen == "monitor":
            return len(monitor_rows(self.data))
        if screen == "szablony":
            return len(self.data.profiles or [])
        if screen == "odzysk":
            return len(self.kopie_state()[1])
        return len((self.data.replicas or {}).get("replicas", []))

    # ------------------------------------------------------------------
    # AKCJE. Zasada 12 dokumentu decyzji i wlasciciel 2026-09-09: NAJPIERW
    # komenda bash na ekranie, potem jedno 't', potem wyjscie czasownika na
    # zywo. TUI nie ma wlasnej kopii zadnej reguly: odmowa jest odmowa
    # czasownika. Proces jest ODLACZONY (wlasna sesja, wyjscie do pliku), wiec
    # Esc zamyka okno, a seed biegnie dalej i widac go na F4.
    def zb(self):
        return os.path.join(self.repo, "zfs-backup.sh")

    def shell_line(self, argv, redirect=None):
        line = " ".join(shlex.quote(a) for a in argv)
        if redirect:
            line += " > " + shlex.quote(redirect)
        return line

    def current_relation(self, allow_removed=False):
        """Relacja pod kursorem na F3, albo powod, dla ktorego akcji nie ma."""
        if self.screen != "relacje":
            return None, _(u"akcje na relacjach są na ekranie F3 Relacje")
        if not self.rows:
            return None, _(u"brak relacji")
        r = self.rows[self.cursor["relacje"]]
        if r["kind"] != "relation":
            return None, _(u"to nie jest relacja (%s) -- akcje dotyczą rekordów relacji") % (_("zadanie bez rekordu") if r["kind"] == "job" else "nieczytelny blok")
        if r["rel"].get("state") == "removed" and not allow_removed:
            return None, _(u"relacja '%s' jest już usunięta (removed_at %s)") % (r["name"], dshow(r["rel"].get("removed_at") or "?"))
        return r, ""

    def confirm(self, title, argv, note_lines=None, redirect=None, on_yes=None, alt=None):
        line = self.shell_line(argv, redirect)
        lines = [_(u"Wykona się DOKŁADNIE to:"), ""] + wrap("  " + line, 72) + [""]
        if note_lines:
            lines += note_lines + [""]
        self.window = ("confirm", {"title": title, "lines": lines, "argv": argv, "redirect": redirect,
                                   "shell": line, "on_yes": on_yes, "alt": alt})
        self.scroll = 0

    def prompt(self, title, label, value, on_enter, error=None, footer=None):
        self.window = ("prompt", {"title": title, "label": label, "value": value, "on_enter": on_enter, "error": error,
                                  "footer": footer})
        self.scroll = 0

    def run_detached(self, title, argv, redirect=None, logname=None):
        """Uruchom czasownik w tle, wyjscie do pliku, okno pokazuje ogon pliku."""
        shell = self.shell_line(argv, redirect)
        if self.exec_log:
            with open(self.exec_log, "a", encoding="utf-8") as fh:
                fh.write(shell + "\n")
            self.window = ("output", {"title": title, "path": None, "proc": None, "shell": shell,
                                      "lines": [_(u"[tryb testowy] nie uruchomiono, zapisano do dziennika:"), "  " + shell], "rc": 0})
            self.scroll = 0
            return
        logdir = os.path.join(home_dir(), ".zfs-tui")
        try:
            os.makedirs(logdir, exist_ok=True)
        except OSError:
            logdir = "/tmp"
        stamp = time.strftime("%Y%m%d-%H%M%S")
        # Nazwa dziennika z czasownika, PRZEFILTROWANA: forma jednokomendowa ma w
        # argv[1] "--source=host:pula/dataset" -- ukosnik zrobilby z tego
        # katalog, ktorego nie ma, i akcja padala cicho (pve10, jazda 8).
        verb = logname or (argv[1] if len(argv) > 1 else "cmd")
        if verb.startswith("--"):
            verb = "nowa-relacja"
        verb = "".join(c if (c.isalnum() or c in "._-") else "_" for c in verb)[:40] or "cmd"
        path = os.path.join(logdir, "%s-%s.log" % (verb, stamp))
        try:
            # Naglowek z komenda idzie do dziennika PRZED otwarciem go dla
            # procesu (tryb dopisywania), zeby proces go nie nadpisal.
            with open(path, "wb") as hdr:
                hdr.write(("$ %s\n" % shell).encode("utf-8"))
            if redirect:
                out = open(redirect, "wb")
                err = open(path, "ab")
            else:
                out = open(path, "ab")
                err = subprocess.STDOUT
            proc = subprocess.Popen(argv, stdout=out, stderr=err, stdin=subprocess.DEVNULL,
                                    cwd=self.repo, start_new_session=True)
        except OSError as e:
            self.window = ("output", {"title": title, "path": path, "proc": None, "shell": shell,
                                      "lines": [_(u"nie udało się uruchomić: %s") % e], "rc": 127})
            self.scroll = 0
            return
        self.window = ("output", {"title": title, "path": path, "proc": proc, "shell": shell, "lines": None,
                                  "rc": None, "redirect": redirect})
        self.scroll = 0

    def output_lines(self, obj, width):
        """Ogon pliku wyjscia + stan procesu. Czytane przy kazdym rysowaniu."""
        out = wrap(u"$ " + obj["shell"], width - 4) + [""]
        if obj.get("lines") is not None:
            body = list(obj["lines"])
        else:
            body = []
            try:
                with open(obj["path"], "rb") as fh:
                    body = fh.read().decode("utf-8", "replace").splitlines()[1:]
            except OSError:
                body = [_(u"(brak pliku wyjścia: %s)") % obj["path"]]
        for ln in body:
            out.extend(wrap(ln.rstrip("\r"), width - 4) or [""])
        proc = obj.get("proc")
        rc = obj.get("rc")
        if proc is not None:
            rc = proc.poll()
            obj["rc"] = rc
        out.append("")
        if rc is None and proc is not None:
            out.append(_(u"--- trwa (pid %d). Esc zamyka okno, proces biegnie dalej; wyjście w %s") % (proc.pid, obj["path"]))
        elif rc == 0:
            out.append(_(u"--- zakończone, rc=0") + (u"   zapisano: %s" % obj["redirect"] if obj.get("redirect") else "") + (_(u"   (dziennik: %s)") % obj["path"] if obj.get("path") else ""))
        else:
            out.append(_(u"--- zakończone, rc=%s -- czasownik ODMÓWIŁ albo padł; przeczytaj powyżej") % rc + (_(u"   (dziennik: %s)") % obj["path"] if obj.get("path") else ""))
        return out

    def ensure_profiles(self):
        """Szablony czytane NA ZADANIE (list-profiles --no-render: ~1 s), nie przy kazdym
        odswiezeniu -- ten sam leniwy czytelnik, ktory ma kreator."""
        if self.data.profiles is None:
            load_profiles(self.repo, self.files, self.data)

    def run_template_dialog(self, argv):
        # Okno biegnie DOPIERO po powrocie do petli (run_dialog tylko je zamawia); szablony
        # czyta refresh() po jego zamknieciu. Czytanie ich tutaj bylo PRZED zapisem.
        return self.run_dialog(argv)

    def template_action(self, k):
        """Ins na F5: nowy szablon NA PODSTAWIE zaznaczonego; Del: usun wlasny (okna
        whiptail, tui/template.sh). Logika -- save-profile / delete-profile."""
        profs = self.data.profiles or []
        c = self.cursor["szablony"]
        if not profs or not (0 <= c < len(profs)):
            self.message = _(u"brak szablonów (list-profiles nie odpowiedział?)")
            return
        n = profs[c].get("name")
        if k == "ins":
            return self.run_template_dialog([self.zb(), "save-profile", "--ask", "--from=%s" % n])
        if k == "del":
            return self.run_template_dialog([self.zb(), "delete-profile", n, "--ask"])

    def run_job_now(self):
        """F7 na F2 (W15 2026-10-11, X9 2026-10-12): zaznaczone zadanie TERAZ -- dokladnie
        jego linia (linie) z crona, z tym samym kontem, logiem i powiadomieniem, wiec
        bieg jest taki jak nocny. Bez okna potwierdzenia (X9). Gdy to samo
        zadanie wlasnie biegnie z crona, silnik odmowi blokada -- widac to w oknie wyniku."""
        rows = self.runrows or []
        c = self.cursor["zadania"]
        if not rows or not (0 <= c < len(rows)) or rows[c].get("kind") != "run":
            self.message = _(u"brak zadań -- nie ma czego uruchomić")
            return
        if rows[c].get("past"):
            self.message = _(u"ten bieg już był -- F7 uruchamia zadanie z wiersza nadchodzącego")
            return
        if rows[c].get("static"):
            self.message = _(u"brak zadań -- nie ma czego uruchomić")
            return
        r = rows[c]["item"]
        # X23 (wlasciciel 2026-10-14): wiersz REPLIKI nie niesie linii crona (powstaje z
        # list-replicas, list-jobs replik nie zwraca) -- F7 robi to samo co F7 na F6.
        if r.get("kind") == "replica":
            n = (r.get("replica") or {}).get("name") or r.get("name")
            self.run_detached(_(u"Replika %s -- biegnie teraz") % n, [self.zb(), "run-replicas", "--name=%s" % n])
            return
        j = r.get("job") or {}
        sched = (r.get("schedule") or "").split()
        lines = [l for l in (j.get("cron_lines") or []) if sched and l.split()[:5] == sched]
        if not lines:
            self.message = _(u"ten wiersz nie ma linii w cronie (strażnik albo replika, bez harmonogramu, lub osierocony wpis) -- nie ma czego uruchomić")
            return
        acct = j.get("account") or "root"
        # ZFS_JOB_PROPAGATE_RC: okno wyniku pokazuje prawdziwy kod zadania (zfs-job dla
        # crona zawsze konczy 0 i zglasza blad powiadomieniem).
        script = "; ".join("ZFS_JOB_PROPAGATE_RC=1 " + re.sub(r"^(\S+\s+){5}", "", l) for l in lines)
        try:
            import pwd
            me = pwd.getpwuid(os.geteuid()).pw_name
        except (ImportError, KeyError, AttributeError):
            me = os.environ.get("USER", "")
        if self.exec_log:
            me = "root"      # atrapa nic nie uruchamia; GUI na hostach chodzi jako root
        if acct in ("", me):
            argv = ["/bin/sh", "-c", script]
        elif me == "root":
            argv = ["runuser", "-u", acct, "--", "/bin/sh", "-c", script]
        else:
            self.message = _(u"zadanie konta %s -- uruchomić je może też root") % acct
            return
        # X9 (wlasciciel 2026-10-12): bez okna potwierdzenia, jak F7 na replice -- bieg
        # robi dokladnie to, co nocny cron (prune tez: kasuje tylko wg retencji).
        self.run_detached(_(u"Zadanie %s -- bieg teraz (konto %s)") % (r.get("name") or "", acct), argv, logname="zadanie")

    def kopie_state(self):
        """F4 Kopie: (wiersze lewego panelu, indeksy wierszy do wyboru)."""
        groups = kopie_groups(self.rows, self.data, self.now(), self.ch)
        roots = []
        for g in groups:
            for r in g["roots"]:
                if r not in roots:
                    roots.append(r)
        tree = load_ztree(self.repo, self.files, self.data, roots)[0] if roots else []
        items = kopie_items(groups, tree)
        # Wiersz notatki (replika bez nosnika, relacja bez kopii) tez jest w tabeli -- operator
        # ma go widziec; akcji na nim nie ma (klawisze nizej).
        return items, [i for i, x in enumerate(items) if x.get("ds") or x.get("any") or x.get("note")]

    def kopie_current(self):
        items, selix = self.kopie_state()
        c = self.cursor.get("odzysk", 0)
        return items[selix[c]] if 0 <= c < len(selix) else {}

    def kopie_snaps(self, it):
        """(wiersze prawego panelu, blad) dla datasetu z lewego panelu -- na zywo, z cache."""
        if not it or not it.get("ds"):
            return [], None
        doc, err = load_zsnaps(self.repo, self.files, self.data, it["ds"])
        return kopie_snap_items(doc, it["ds"]), err

    def kopie_browse(self, it, snap):
        """Enter na migawce: zamontuj ja tylko do odczytu i otworz mc (browse --snapshot=).
        Bez migawki ('inny dysk'): stare okna wyboru (browse --any). Po przegladaniu GUI
        wraca bez pelnego przeladowania (U104): przegladanie niczego nie zmienia."""
        g = (it or {}).get("g") or {}
        who = g["name"] if g.get("kind") == "relation" else "--any"
        argv = [self.zb(), "browse", who, "--ask"]
        if snap:
            argv.append("--snapshot=%s" % snap["name"])
        self.noreload_after = True
        return self.run_dialog(argv)

    def kopie_restore(self, it, snap):
        """F9: odzysk z tej kopii i tej migawki -- okna Przywroc startuja od 'dokad'."""
        g = (it or {}).get("g") or {}
        extra = []
        if it and it.get("ds"):
            extra.append("--dataset=%s" % it["ds"])
        if snap:
            extra.append("--snapshot=%s" % snap["name"].split("@", 1)[-1])
        if g.get("kind") == "relation":
            return self.run_dialog([self.zb(), "restore", g["name"], "--ask"] + extra)
        return self.run_dialog([self.zb(), "restore", "--from-copy", "--ask"] + extra)

    def restore_action(self, row):
        """F11 ODZYSK DANYCH (właściciel 2026-10-18: odzysk nie siedzi w zmianie
        relacji ani przy zadaniach -- "ktoś może się machnąć"). Te same okna
        whiptail co wcześniej 'p' w oknie relacji i F9 na Replice; plan i pytanie
        przed nadpisaniem zadaje samo polecenie `restore`."""
        if row.get("kind") == "disk":
            return self.run_dialog([self.zb(), "restore", "--from-copy", "--ask"])
        return self.run_dialog([self.zb(), "restore", row["name"], "--ask"])

    def browse_action(self, row):
        """Enter NA F4 KOPIE -- "Przeglądaj kopię": okna tui/browse.sh przez `browse --ask`;
        migawka zamontowana tylko do odczytu, mc, odmontowanie. Otwarte z Przebiegow albo
        z datasetu relacji -- od razu ta kopia i ta chwila (--dataset=, --at=)."""
        if row.get("kind") == "disk":
            return self.run_dialog([self.zb(), "browse", "--any", "--ask"])
        argv = [self.zb(), "browse", row["name"], "--ask"]
        ctx = self.kopie_ctx or {}
        if ctx.get("rel") == row["name"]:
            if ctx.get("dataset"):
                argv.append("--dataset=%s" % ctx["dataset"])
            if ctx.get("at"):
                argv.append("--at=%d" % int(ctx["at"]))
        return self.run_dialog(argv)

    def kopie_from_here(self):
        """F4 z Przebiegow albo z Relacji: Kopie z kursorem na tej relacji i z zapamietanym
        datasetem i chwila (koniec biegu) -- Enter otwiera od razu jego migawki (U82)."""
        self.kopie_ctx = None
        rel, ds, at = None, None, None
        if self.screen == "zadania":
            c = self.cursor["zadania"]
            r = self.runrows[c] if 0 <= c < len(self.runrows) else None
            if r and r.get("kind") == "run" and not r.get("static") and r["item"].get("kind") == "job":
                rel = r["name"]
                for j in run_jobs(r):
                    dst = (job_src_dst(j)[1] or "")
                    if dst and dst not in ("-", "?") and ":" not in dst:
                        ds = dst
                        break
                if r.get("past"):
                    at = r.get("end") or r.get("at")
        else:
            c = self.cursor["relacje"]
            if 0 <= c < len(self.rows) and self.rows[c].get("kind") == "relation":
                rel = self.rows[c]["name"]
                if self.focus == "pairs":
                    info = self.child_info() or {}
                    items = info.get("items") or []
                    if items:
                        it = items[min(self.pair_cursor, len(items) - 1)]
                        dst = ((it.get("pair") or {}).get("dst") or "")
                        if dst and ":" not in dst:
                            ds = dst
        if not rel:
            return
        items, selix = self.kopie_state()
        pick = None
        for c_, i in enumerate(selix):
            g = items[i].get("g") or {}
            if g.get("kind") == "relation" and g.get("name") == rel:
                if pick is None:
                    pick = c_
                if ds and items[i].get("ds") == ds:
                    pick = c_
                    break
        if pick is None:
            self.message = _(u"relacja %s nie ma kopii na tym hoście -- nie ma czego przeglądać") % rel
            return
        self.cursor["odzysk"] = pick
        self.kopie_ctx = {"rel": rel, "dataset": ds, "at": at}
        if at:
            snaps = self.kopie_snaps(items[selix[pick]])[0]
            older = [j for j, x in enumerate(snaps) if x["creation"] <= int(at)]
            if older:
                self.screen, self.focus, self.pair_cursor = "odzysk", "pairs", older[0]

    def replica_action(self, k):
        """Klawisz akcji na F6 (repliki): Ins nowa (okna whiptail), Del usun,
        F7 uruchom zaznaczona teraz (bez pytania), F8 pokaz klucz nosnika (W19b),
        F9 przywroc z dysku (restore --from-copy --ask, takze bez replik).
        Logika jest w czasownikach."""
        if k == "ins":
            return self.run_dialog([self.zb(), "add-replica", "--ask"])
        reps = (self.data.replicas or {}).get("replicas", [])
        if k == "F9":
            self.message = _(u"przywracanie z dysku jest teraz na F4 Kopie (F9)")
            return
        c = self.cursor["nosniki"]
        if not reps or not (0 <= c < len(reps)):
            self.message = _(u"brak replik -- nie ma czego uruchomić (Ins dodaje)") if k == "F7" else _(u"brak replik")
            return
        n = reps[c].get("name")
        if k == "F7":
            # ZAZNACZONA replika, od razu, bez pytania (uwaga 18, 2026-10-08): kopia niczego
            # nie niszczy, a "t" niczego nie chronilo. Wynik w oknie, jak kazdy bieg w tle.
            self.run_detached(_(u"Replika %s -- biegnie teraz") % n, [self.zb(), "run-replicas", "--name=%s" % n])
            return
        if k == "del":
            # Okna whiptail (remove-replica --ask): plan, potem WYKONAJ; dane na
            # dyskach zostaja (W12).
            return self.run_dialog([self.zb(), "remove-replica", n, "--ask"])
        if k == "F8":
            # W19b (wlasciciel 2026-10-11): klucz zaszyfrowanego nosnika da sie pokazac
            # znowu -- to jedyna kopia, ktora moze opuscic ten serwer.
            kf = reps[c].get("media_key") or ""
            if not kf:
                self.message = _(u"replika %s nie ma zaszyfrowanego nośnika -- nie ma klucza do pokazania") % n
                return
            try:
                with open(kf, encoding="utf-8") as fh:
                    key = fh.read().strip()
            except OSError as e:
                self.message = _(u"nie da się przeczytać klucza %s: %s") % (kf, e)
                return
            self.window = ("output", {"title": _(u"Klucz nośnika repliki %s") % n, "path": None, "proc": None, "shell": "",
                                      "lines": [u"Klucz (64 znaki hex):", u"", u"  " + key, u"",
                                                _(u"Zapisz go gdzieś POZA tym serwerem. Gdy serwer przepadnie, bez klucza"),
                                                _(u"kopii z dysku nie odczytasz."), _(u"Plik: ") + kf], "rc": 0})
            self.scroll = 0
            return

    def action(self, k):
        """Klawisz akcji na F3 -> okno potwierdzenia albo komunikat."""
        # Import i nowa relacja NIE potrzebuja istniejacej relacji: na pustym
        # kolektorze -- dokladnie tam, gdzie sie importuje -- import i Ins milczaly,
        # bo ponizej najpierw szukamy zaznaczonej relacji (pve11, 2026-09-23).
        if k == "ins":
            return self.run_wizard()
        # Del dziala takze na rekordzie `removed`: tam znaczy "zwolnij nazwe / posprzataj reszte".
        r, why = self.current_relation(allow_removed=(k == "del"))
        if k == "F9":
            # F9 = Eksport/Import (2026-10-17). Bez zaznaczonej relacji -- pusty kolektor,
            # dokladnie tam, gdzie sie importuje -- od razu import, jak dawniej.
            if r is None:
                d = relations_dir()
                return self.import_files(d if os.path.isdir(d) else home_dir())
            self.window = ("choice", {"title": _(u"Relacja %s -- eksport / import") % r["name"], "cur": 0, "rel": r["name"],
                                      "items": [("eksport", _(u"Eksport relacji %s do pliku") % r["name"]),
                                                ("import", _(u"Import relacji z pliku"))]})
            self.scroll = 0
            return
        if r is None:
            self.message = why
            return
        n = r["name"]
        rel = r["rel"]
        if k == "F7":
            # UROCHOM TERAZ, jak F7 na F2 i F6: bez okna potwierdzenia (kopia niczego nie
            # niszczy), wynik w oknie wyjscia. Czasownik bierze z zainstalowanego crona
            # najdrobniejsze zadanie kazdego datasetu relacji; wstrzymanej odmawia.
            self.run_detached(_(u"Relacja %s -- kopia teraz: wymuszenie kopii wszystkich datasetów (np. przed przeniesieniem kolektora)") % n, [self.zb(), "run-relation", n], logname="relacja")
        elif k == "F8":
            if rel.get("disabled"):
                self.confirm(_(u"Włącz relację %s") % n, [self.zb(), "enable-client", n], [_(x) for x in ENABLE_NOTE])
            elif rel.get("paused_local"):
                self.confirm(_(u"Wznów relację %s") % n, [self.zb(), "resume-client", n],
                             [_(u"Zdejmuje pauzę: następny bieg z crona rusza normalnie i dogania przyrostowo.")])
            else:
                note = [_(u"Pauza LOGICZNA: linie w cronie zostają, ale nic nie wysyła i nie kasuje;"),
                        _(u"monitor nie alarmuje (pokazuje PAUZA). Cofnięcie: F8 jeszcze raz (resume-client).")]
                alt = None
                if rel.get("peer_host") and rel.get("mode") != "local":
                    # D-1 (kampania 2026-10-21): "wyjaśnienie pokaże następne okno" -- następnego
                    # okna nie było; to okno otwiera się dopiero czynnością z dołu ramki.
                    note += ["", _(u"Zamiast pauzy można WYŁĄCZYĆ relację także na źródle (lock):"),
                             _(u"przycisk „wyłącz na źródle” na dole; następne okno wyjaśni, co to zmienia.")]
                    alt = ("w", lambda: self.confirm(_(u"Wyłącz relację %s") % n, [self.zb(), "disable-client", n,
                                                     _(u"--reason=wyłączona z TUI %s") % time.strftime(DT_FMT)],
                                                     disable_note(rel)), _(u"wyłącz na źródle"))
                self.confirm(_(u"Wstrzymaj relację %s") % n, [self.zb(), "pause-client", n, _(u"--reason=z TUI %s") % time.strftime(DT_FMT)],
                             note, alt=alt)
        elif k == "del":
            # CALE usuniecie (kolektor + zrodlo + zwolnienie nazwy), w oknach whiptail:
            # samo remove-client zostawialo rekord `removed`, ktory trzymal NAZWE, wiec
            # "usun i zaloz od nowa" -- jedyna dzis droga zmiany relacji -- nie dzialalo
            # (zmierzone na pve10, 2026-09-20).
            return self.run_dialog([self.zb(), "delete-relation", n, "--ask"])

    def export_prompt(self, n):
        """Eksport relacji: pole sciezki (F9 -> Eksport)."""
        default = os.path.join(relations_dir(), "%s.export.json" % n)
        self.prompt(_(u"Eksport relacji %s") % n, _(u"Plik (istniejący zostanie nadpisany):"), default,
                    lambda path: self.export_to(n, path), footer=_(u"Enter zapisuje   Esc wraca"))

    def export_to(self, n, path):
        """R4-8: Enter w polu sciezki ZAPISUJE -- drugie potwierdzenie 't' bylo
        podwojna robota. Istniejacy plik jest nadpisywany bez pytania (decyzja
        wlasciciela). Katalog tworzony, jesli go nie ma; brak prawa zapisu to
        komunikat w tym samym polu, nie cichy blad."""
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            try:
                os.makedirs(d, exist_ok=True)
            except OSError as e:
                self.prompt(_(u"Eksport relacji %s") % n, _(u"Plik:"), path, lambda p: self.export_to(n, p),
                            _(u"nie da się utworzyć katalogu %s: %s") % (d, e.strerror or e))
                return
        self.run_detached(_(u"Eksport relacji %s") % n, [self.zb(), "export-relation", n, "--json"], redirect=path)

    # ------------------------------------------------------------------
    # KREATOR NOWEJ RELACJI (etap E). Odwzorowuje forme jednokomendowa
    # `zfs-backup.sh --source=HOST:DATASET --target=DATASET [--profile=...]`,
    # tak jak mowi dokument decyzji: pola w kolejnosci, w jakiej forma pyta,
    # szablon z listy, potem PLAN czasownika (read-only, bez --install), potem
    # pelna komenda z --install --yes do potwierdzenia. Kreator nie liczy nic
    # sam: co odmawia czasownik, odmawia tu tak samo, tymi samymi slowami.
    # ------------------------------------------------------------------
    # NOWY SZABLON (wlasciciel 2026-09-14: "albo wskazac profil z templates,
    # albo stworzyc calkiem nowy uzywajac checkboxow, radiobuttons i list").
    # Formularz = pola z BAZY (liczniki, harmonogramy, zamrazanie, progi), zapis
    # przez save-profile -- ten sam czasownik, ktory admin wpisalby z palca, z
    # jego dwiema bramkami (walidator i prawdziwy render). Mechanizm i ksztalt
    # sa z bazy: save-profile zmienia pola szczebli, nie sklada profilu z niczego.
    def profile_form_fields(self, base):
        fields = [("name", u"Nazwa nowego szablonu", "text", _(u"litery, cyfry, . _ - ; plik NAZWA.conf w /etc/zfs-snapshot-all/profiles. Nazwa w stylu d7h48 obiecuje retencję -- czasownik sprawdzi")),
                  ("desc", u"Opis", "text", _(u"jedno zdanie, co ten szablon robi (pole description)")),
                  ("base", _(u"Na bazie"), "pick", _(u"wybór z listy szablonów; z bazy idą mechanizm, kształt i wszystko, czego nie zmienisz"))]
        for t in base.get("tiers", []):
            tn = t.get("name", "")
            adj = tier_unit(tn, TIER_ADJ)
            fields.append((u"h|%s" % tn, _(u"szczebel %s (%s)") % (tn, adj), "head", ""))
            if t.get("send_schedule"):
                fields.append(("t|%s|send_schedule" % tn, _(u"  migawka co (cron)"), "cron", _(u"5 pól crona; obok słowa, jak to czyta człowiek")))
            if t.get("keep"):
                fields.append(("t|%s|keep" % tn, u"  trzymaj %s" % tier_unit(tn), "num", _(u"licznik: ile %s zostaje (0 = nic z tego szczebla)") % tier_unit(tn)))
            elif t.get("retain"):
                fields.append(("t|%s|retain" % tn, u"  trzymaj wg wieku", "text", _(u"flaga silnika, np. -h24 = młodsze niż 24 godziny")))
            if t.get("prune_schedule"):
                fields.append(("t|%s|prune_schedule" % tn, _(u"  porządki co (cron)"), "cron", _(u"kiedy kasować nadmiar")))
            if t.get("send_schedule"):
                qh = _(u"tak = auto,degrade (spójna migawka; gdy nie da się zamrozić, robi zwykłą)")
                if base.get("shape") == "one-family":
                    qh = _(u"UWAGA: jedna rodzina -- zamrażanie dotyczy KAŻDEJ migawki tego szczebla (np. 24 razy na dobę)")
                fields.append(("t|%s|quiesce" % tn, _(u"  zamrażaj system plików"), "toggle", qh))
            if t.get("monitor_warn") or t.get("monitor_crit"):
                fields.append(("t|%s|monitor_warn" % tn, _(u"  monitor: ostrzeż po"), "text", _(u"np. 90m, 30h, 8d -- kopia starsza niż to = ostrzeżenie")))
                fields.append(("t|%s|monitor_crit" % tn, _(u"  monitor: alarm po"), "text", _(u"np. 150m, 48h, 10d -- starsza niż to = alarm")))
        fields.append(("go", _(u"[ ZAPISZ ]"), "go", _(u"pokazuje komendy save-profile do potwierdzenia (nic nie jest zapisane wcześniej)")))
        return fields

    def profile_form_vals(self, base, keep=None):
        vals = {"name": (keep or {}).get("name", ""), "desc": (keep or {}).get("desc") or base.get("description", "") or "", "base": base.get("name", "")}
        for t in base.get("tiers", []):
            tn = t.get("name", "")
            for f in ("send_schedule", "keep", "retain", "prune_schedule", "monitor_warn", "monitor_crit"):
                vals["t|%s|%s" % (tn, f)] = t.get(f, "") or ""
            vals["t|%s|quiesce" % tn] = bool(t.get("quiesce"))
        return vals

    def profile_form_open(self, base, back):
        self.window = ("form", {"kind": "profile", "title": _(u"Nowy szablon na bazie: %s") % base.get("name", "?"),
                                "fields": self.profile_form_fields(base), "vals": self.profile_form_vals(base),
                                "base": base, "cur": 0, "back": back, "profiles": back[1].get("profiles") if back else None})
        self.scroll = 0

    def profile_form_rebuild(self, obj):
        """Zmiana bazy = nowe pola szczebli; nazwa i opis zostaja."""
        name = obj["vals"].get("base", "")
        base = None
        for pr in (obj.get("profiles") or []):
            if pr.get("name") == name:
                base = pr
        if base is None:
            self.message = _(u"nie ma szablonu '%s' na liście") % name
            obj["vals"]["base"] = obj["base"].get("name", "")
            return
        keep = dict(obj["vals"])
        if (keep.get("desc") or "") == (obj["base"].get("description") or ""):
            keep["desc"] = ""   # opis nieedytowany idzie za nowa baza
        obj["base"], obj["title"] = base, _(u"Nowy szablon na bazie: %s") % name
        obj["fields"], obj["vals"] = self.profile_form_fields(base), self.profile_form_vals(base, keep)
        obj["cur"] = min(obj["cur"], len(obj["fields"]) - 1)

    def profile_argvs(self, obj):
        """Lista argv save-profile: pierwsza tworzy kopie (+ opis + pierwszy
        zmieniony szczebel), kazdy kolejny zmieniony szczebel to osobne wywolanie
        --from=NOWY --as=NOWY --force (czasownik bierze JEDEN --tier na raz)."""
        vals, base = obj["vals"], obj["base"]
        name = vals["name"].strip()
        changes = []
        for t in base.get("tiers", []):
            tn = t.get("name", "")
            ch = []
            for f in ("send_schedule", "keep", "retain", "prune_schedule", "monitor_warn", "monitor_crit"):
                key = "t|%s|%s" % (tn, f)
                if key in vals and (vals[key] or "").strip() != (t.get(f, "") or ""):
                    ch.append("--%s=%s" % (f, vals[key].strip()))
            qk = "t|%s|quiesce" % tn
            if qk in vals and bool(t.get("quiesce")) != bool(vals[qk]):
                ch.append("--quiesce=%s" % ("auto,degrade" if vals[qk] else ""))
            if ch:
                changes.append((tn, ch))
        first = [self.zb(), "save-profile", "--from=%s" % base.get("name", ""), "--as=%s" % name]
        if (vals.get("desc") or "").strip() and vals["desc"].strip() != (base.get("description") or ""):
            first.append("--description=%s" % vals["desc"].strip())
        argvs = []
        if changes:
            tn, ch = changes[0]
            argvs.append(first + ["--tier=%s" % tn] + ch)
            for tn, ch in changes[1:]:
                argvs.append([self.zb(), "save-profile", "--from=%s" % name, "--as=%s" % name, "--force", "--tier=%s" % tn] + ch)
        else:
            argvs.append(first)
        return argvs, changes

    def profile_plan(self, obj):
        vals, base = obj["vals"], obj["base"]
        name = vals["name"].strip()
        if not name:
            self.message = _(u"nazwa nowego szablonu jest wymagana")
            return
        if any(not (c.isalnum() or c in "._-") for c in name) or name.startswith("."):
            self.message = _(u"nazwa: tylko litery, cyfry, kropka, podkreślnik, myślnik")
            return
        if name == base.get("name"):
            self.message = _(u"nazwa musi być inna niż baza (fabrycznego szablonu nie nadpiszemy)")
            return
        for key, _l, kind, _h in obj["fields"]:
            if kind == "cron" and len((vals.get(key) or "").split()) != 5:
                self.message = _(u"harmonogram '%s' to nie 5 pól crona") % (vals.get(key) or "")
                return
        argvs, changes = self.profile_argvs(obj)
        # Slowa o tym, co powstanie: baza z naniesionymi zmianami.
        synth = json.loads(json.dumps(base))
        synth["name"], synth["description"] = name, vals.get("desc") or base.get("description", "")
        for t in synth.get("tiers", []):
            tn = t.get("name", "")
            for f in ("send_schedule", "keep", "retain", "prune_schedule", "monitor_warn", "monitor_crit"):
                key = "t|%s|%s" % (tn, f)
                if key in vals:
                    t[f] = vals[key].strip()
            t["quiesce"] = "auto,degrade" if vals.get("t|%s|quiesce" % tn) else ""
        w = profile_words(synth)
        note = wrap(u"Szablon %s: %s · %s · %s · %s · %s · %s" % (name, w["cadence"], w["retention"], w["mech"], w["shape"], w["quiesce"], w["monitor"]), 72) + [""]
        if len(argvs) > 1:
            note += wrap(_(u"Zmienione szczeble: %s -- %d wywołania save-profile po kolei (jeden --tier na raz):") % (", ".join(tn for tn, _ in changes), len(argvs)), 72)
            for a in argvs[1:]:
                note += wrap("  " + self.shell_line(a), 72)
            note.append("")
        note += wrap(_(u"Zapis idzie do /etc/zfs-snapshot-all/profiles/%s.conf. Dwie bramki czasownika: walidator i prawdziwy render.") % name, 72)
        back_form = obj.get("back")
        argv = argvs[0] if len(argvs) == 1 else ["bash", "-c", " && ".join(self.shell_line(a) for a in argvs)]

        def on_yes():
            self.run_detached(_(u"Nowy szablon %s") % name, argv, logname="save-profile")
            self.data.profiles = None
            if back_form and back_form[0] == "form":
                back_form[1]["vals"]["profile"] = name
                back_form[1]["profiles"] = None
                back_form[1]["cur"] = 0
                self.window[1]["back_to"] = back_form
        self.confirm(_(u"Nowy szablon %s (na bazie %s)") % (name, base.get("name", "?")), argv, note, on_yes=on_yes)

    def open_profile_pick(self, obj, key, label):
        if obj.get("profiles") is None:
            obj["profiles"], obj["perr"] = load_profiles(self.repo, self.files, self.data)
        items = list(obj.get("profiles") or [])
        cur = 0
        for i, pr in enumerate(items):
            if pr.get("name") == obj["vals"][key]:
                cur = i
        self.window = ("pick", {"title": _(u"Szablon dla pola: %s") % label.strip(), "items": items, "cur": cur, "field": key, "back": self.window,
                                "allow_new": obj.get("kind") != "profile"})
        self.scroll = 0

    def form_advance(self, obj, FIELDS):
        """Enter = nastepne pole (naglowki przeskakiwane)."""
        c = obj["cur"] + 1
        while c < len(FIELDS) and FIELDS[c][2] == "head":
            c += 1
        if c < len(FIELDS):
            obj["cur"] = c

    def form_lines(self, obj, width):
        out = []
        vals = obj["vals"]
        FIELDS = obj.get("fields") or []
        lw = max(22, min(30, max(len(f[1]) for f in FIELDS)))
        for i, (key, label, kind, hint) in enumerate(FIELDS):
            mark = ">" if i == obj["cur"] else " "
            if kind == "toggle":
                shown = _("[x] tak") if vals[key] else _("[ ] nie")
            elif kind == "go":
                shown = ""
            elif kind == "head":
                out.append("")
                out.append(fit("  " + label, width - 4))
                continue
            else:
                shown = vals[key] + ("_" if i == obj["cur"] else "")
                if kind == "cron":
                    shown += u"      = %s" % cron_words(vals[key])
            if i == obj["cur"]:
                obj["_cur_y"] = len(out)
            out.append(fit("%s %-*s %s" % (mark, lw, label, shown), width - 4))
            if i == obj["cur"]:
                out.append(fit("      " + hint, width - 4))
        out.append("")
        if obj.get("kind") == "profile":
            out.append(fit(_(u" Sposób liczenia i układ migawek bierze się z szablonu bazowego -- inny = wybierz inną bazę."), width - 4))
            out.append(fit(_(u" Zapis = save-profile do /etc/zfs-snapshot-all/profiles; nic zbudowanego nie rusza."), width - 4))
            if self.message:
                out += ["", fit(u" ! " + self.message, width - 4)]
            return out
        if obj.get("perr"):
            out.append(fit(_(u" list-profiles: błąd źródła -- wpisz nazwę szablonu ręcznie (%s)") % obj["perr"][:40], width - 4))
        else:
            out.append(fit(_(u" szablonów do wyboru: %d (pole Szablon)") % len(obj.get("profiles") or []), width - 4))
        if self.message:
            out += ["", fit(u" ! " + self.message, width - 4)]
        return out

    def picker_lines(self, obj, width):
        out = []
        if obj.get("kind") == "datasets":
            nw = max(20, width - 4 - 2 - 11 - 11 - 11)
            out.append(fit("  %-*s %-10s %10s %10s" % (nw, _("dataset"), _(u"typ"), _(u"zajęte"), _(u"wolne")), width - 4))
            for i, d in enumerate(obj["items"]):
                mark = ">" if i == obj["cur"] else " "
                out.append(fit("%s %s %-10s %10s %10s" % (mark, fit_left(d.get("name", "?"), nw, self.ch), d.get("type", ""),
                                                          human_bytes(int(d.get("used") or 0)), human_bytes(int(d.get("avail") or 0))), width - 4))
            return out
        # SZABLONY SLOWAMI (wlasciciel 2026-09-14): co robi, nie jak sie nazywa.
        for i, pr in enumerate(obj["items"]):
            mark = ">" if i == obj["cur"] else " "
            w = profile_words(pr)
            out.append(fit(u"%s %-16s %s · %s · %s" % (mark, pr.get("name", "?"), w["cadence"], w["retention"], w["mech"]), width - 4))
            if i == obj["cur"]:
                out.append(fit(u"      %s · %s · %s · %s" % (w["shape"], w["quiesce"], w["monitor"], _(pr.get("description", "") or "")), width - 4))
        if not obj["items"]:
            out.append(_(u" brak szablonów (list-profiles nic nie zwrócił) -- wpisz nazwę ręcznie w polu"))
        elif obj.get("allow_new"):
            out += ["", fit(_(u" Ins = nowy szablon na bazie podświetlonego (liczniki, harmonogramy, zamrażanie, progi)"), width - 4)]
        return out

    def import_files(self, d):
        """R4-9: import zaczyna sie od LISTY plikow (jak w menedzerze plikow), a
        nie od wpisywania sciezki. '..' w gore, katalogi, pliki eksportu
        (najnowsze pierwsze, z data i nazwa relacji z pliku); ostatnia pozycja
        -- wpisanie sciezki recznie."""
        d = os.path.abspath(d)
        items = []
        parent = os.path.dirname(d)
        if parent and parent != d:
            items.append({"kind": "up", "path": parent, "label": u".."})
        try:
            names = sorted(os.listdir(d))
        except OSError as e:
            names = []
            self.message = _(u"nie da się odczytać katalogu %s: %s") % (d, e.strerror or e)
        dirs, files = [], []
        for nm in names:
            fp = os.path.join(d, nm)
            if nm.startswith("."):
                continue
            if os.path.isdir(fp):
                dirs.append({"kind": "dir", "path": fp, "label": nm + "/"})
            elif os.path.isfile(fp):
                info = export_file_info(fp)
                if info:
                    files.append({"kind": "file", "path": fp, "label": nm, "rel": info[0], "mtime": info[1]})
        files.sort(key=lambda x: -x["mtime"])
        items += dirs + files
        items.append({"kind": "manual", "path": d, "label": _(u"[ wpisz ścieżkę ręcznie ]")})
        cur = next((i for i, it in enumerate(items) if it["kind"] == "file"), len(items) - 1)
        self.window = ("files", {"title": _(u"Import relacji z pliku -- %s") % d, "dir": d, "items": items, "cur": cur,
                                 "nfiles": len(files)})
        self.scroll = 0

    def files_lines(self, obj, width):
        out = []
        w = width - 4
        fl = [it for it in obj["items"] if it["kind"] == "file"]
        # Kolumna nazwy pliku tak szeroka, jak najdluzsza nazwa -- ale nazwa
        # relacji (to, po co operator patrzy) ma sie zmiescic przy 80 kolumnach.
        relw = max([len(it["rel"]) for it in fl] + [1])
        lw = max(10, min(max([len(it["label"]) for it in fl] + [10]), w - 2 - 1 - 16 - 2 - 8 - relw))
        for i, it in enumerate(obj["items"]):
            mark = ">" if i == obj["cur"] else " "
            if it["kind"] == "file":
                when = time.strftime(DT_FMT, time.localtime(it["mtime"])) if it["mtime"] else "?"
                out.append(fit(_(u"%s %-*s %s  relacja %s") % (mark, lw, fit_left(it["label"], lw, self.ch), when, it["rel"]), w))
            else:
                out.append(fit(u"%s %s" % (mark, it["label"]), w))
        if not obj["nfiles"]:
            out += ["", fit(_(u" w tym katalogu nie ma wyeksportowanych relacji (eksport relacji z ekranu Relacje, menu Plik, zapisuje je w %s)") % relations_dir(), w)]
        return out

    def import_ask_file(self, value, error=None):
        """Krok -1 importu: sciezka do pliku eksportu."""
        self.prompt(_(u"Import relacji z pliku"), _(u"Plik eksportu:"), value, self.import_name, error)

    def import_name(self, path):
        """Krok 1 importu: plik istnieje? Pole jest podpowiedziane z "/root/", a
        dopisana wzgledna sciezka dawala /root/tmp/f8.json, ktora dochodzila do
        czasownika i tam dostawala "cannot read" (pve10, 2026-09-23) -- zla
        sciezka zostaje w polu pliku."""
        if not os.path.isfile(path):
            self.import_ask_file(path, _(u"nie ma takiego pliku: %s -- popraw ścieżkę") % path)
            return
        self.import_preview(path)

    # Czasownik bez --yes konczy PLAN tym zdaniem. Kazdy inny wynik z rc 0 to
    # werdykt bez niczego do wykonania (np. "relacja juz jest, identyczna").
    IMPORT_PLAN_MARK = u"That was a preview"

    def import_preview(self, path):
        """Krok 2 importu: WERDYKT czasownika (bez --yes). Decyduje czasownik, nie
        GUI (2026-09-23, wlasciciel: "banalne okno i operacja"): relacja juz jest
        i identyczna -> okno z wynikiem, nic do wykonania; odmowa -> okno z
        odmowa; plan -> potwierdzenie, `t` wykonuje z --yes. Krok z nazwa
        relacji zniknal: werdykt sam mowi, kiedy nazwa ma znaczenie, a --name
        zostaje w CLI (import na innym kolektorze pod inna nazwa)."""
        argv = [self.zb(), "import-relation", path]
        if self.exec_log:
            preview, rc = [_(u"[atrapa] podgląd: ") + self.shell_line(argv), self.IMPORT_PLAN_MARK], 0
        else:
            try:
                p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=self.repo)
            except OSError as e:
                self.message = _(u"nie udało się uruchomić podglądu: %s") % e
                return
            preview, rc = p.stdout.decode("utf-8", "replace").splitlines(), p.returncode
        if rc != 0 or not any(self.IMPORT_PLAN_MARK in x for x in preview):
            self.window = ("output", {"title": _(u"Import: odmowa") if rc else _(u"Import: nic do zrobienia"),
                                      "path": None, "proc": None, "shell": self.shell_line(argv),
                                      "lines": preview, "rc": rc})
            self.scroll = 0
            return
        self.confirm(_(u"Import relacji z %s") % os.path.basename(path), argv + ["--yes"],
                     [_(u"Plan (to samo, co czasownik pokazał bez --yes):"), ""] + sum((wrap("  " + x, 72) for x in preview), []))

    def key(self, k, height=24, raw=None):
        """Jeden klawisz -> nowy stan. `k` to nazwa: 'down', 'F2', 'enter', 'q', 'esc'...;
        `raw` to znak (str) dla pola tekstowego."""
        self.message = ""
        # H-3 (kampania na żywo 2026-10-21): po oknie (kreator repliki) GUI wraca od razu ze
        # STARYMI danymi i odświeża w tle (~5 s). F7 w tym czasie uruchomił starą zaznaczoną
        # replikę zamiast nowej. Czynność na wierszu czeka na świeże dane: najpierw je
        # przyjmuje, potem działa na tym, co już jest na ekranie po odświeżeniu.
        # Na żywo (drugie przejście): czekała tylko czynność -- strzałka poszła po STAREJ
        # liście, a świeże dane wróciły kursor na pierwszy wiersz i F7 znów trafił w starą
        # replikę. Więc KAŻDY klawisz po oknie czeka na świeże dane (ekran jest od razu,
        # pierwszy klawisz czeka najwyżej resztę odświeżania).
        # REV-20261023-172: czekanie ma limit, a po limicie klawisz szedł dalej po STARYCH
        # wierszach (Del na relacji sprzed zmiany). Teraz limit zamyka: klawisz przepada,
        # ekran zostaje oznaczony jako nieświeży, wyjście (q/F12) zawsze działa.
        # Wątek, który już skończył, a którego dane pętla jeszcze nie odebrała (pyta co 0,3 s),
        # też się liczy: najpierw przyjęcie danych, potem klawisz (test regresji REV-172 trafiał
        # Del w stary wiersz w tym okienku). Odświeżenie, które się NIE UDAŁO, zostawia stare
        # wiersze: czynności na wierszu czekają wtedy na udane odświeżenie (Ctrl-R).
        if not self.window:
            bg = getattr(self, "_bg", None)
            if bg is not None:
                if bg[0].is_alive():
                    bg[0].join(self.BG_KEY_WAIT)
                self.poll_bg()
                if getattr(self, "_bg", None) is not None and k not in ("q", "F12"):
                    self.message = (_(u"Dane wciąż się odświeżają (ponad %d s) -- klawisz pominięty, "
                                      u"ekran jest NIEAKTUALNY. Naciśnij klawisz ponownie, gdy zniknie "
                                      u"„odświeżam w tle”; F12 wychodzi.%s") % (self.BG_KEY_WAIT, _(self.BG_NOTE)))
                    return "stay"
            if getattr(self, "bg_failed", False) and not self.row_free(k):
                self.message = (_(u"Odświeżenie danych nie wyszło -- ekran jest NIEAKTUALNY, czynność pominięta. "
                                  u"Ctrl-R odświeża; po udanym odświeżeniu naciśnij klawisz ponownie."))
                return "stay"
        if self.window and self.window[0] == "prompt":
            obj = self.window[1]
            if k == "esc":
                self.window, self.message = None, _(u"anulowano")
            elif k == "enter":
                self.window = None
                obj["on_enter"](obj["value"])
            elif k == "bs":
                obj["value"] = obj["value"][:-1]
            elif k.startswith("text:"):
                obj["value"] += k[5:]
            elif raw and len(raw) == 1 and raw.isprintable():
                obj["value"] += raw
            return "stay"
            return "stay"
        if self.window and self.window[0] == "files":
            obj = self.window[1]
            n = len(obj["items"])
            if k in ("esc", "q"):
                self.window, self.message = None, _(u"anulowano")
            elif k in ("down", "j"):
                obj["cur"] = min(obj["cur"] + 1, n - 1)
            elif k in ("up", "k"):
                obj["cur"] = max(0, obj["cur"] - 1)
            elif k == "pgdn":
                obj["cur"] = min(obj["cur"] + 10, n - 1)
            elif k == "pgup":
                obj["cur"] = max(0, obj["cur"] - 10)
            elif k == "home":
                obj["cur"] = 0
            elif k == "end":
                obj["cur"] = n - 1
            elif k == "enter" and n:
                it = obj["items"][obj["cur"]]
                if it["kind"] in ("up", "dir"):
                    self.import_files(it["path"])
                elif it["kind"] == "manual":
                    self.import_ask_file(os.path.join(it["path"], ""))
                else:
                    self.window = None
                    self.import_name(it["path"])
            return "stay"
        if self.window and self.window[0] == "choice":
            # Okienko wyboru (F9 na F3: Eksport / Import): strzalki, Enter, Esc.
            obj = self.window[1]
            if k in ("esc", "q"):
                self.window, self.message = None, _(u"anulowano -- nic nie wykonano")
            elif k in ("down", "j"):
                obj["cur"] = min(obj["cur"] + 1, len(obj["items"]) - 1)
            elif k in ("up", "k"):
                obj["cur"] = max(0, obj["cur"] - 1)
            elif k == "enter":
                tag = obj["items"][obj["cur"]][0]
                self.window = None
                if tag == "eksport":
                    self.export_prompt(obj["rel"])
                else:
                    d = relations_dir()
                    res = self.import_files(d if os.path.isdir(d) else home_dir())
                    if res:
                        return res
            return "stay"
        if self.window and self.window[0] == "pick":
            obj = self.window[1]
            if k == "esc":
                self.window = obj["back"]
            elif k in ("down", "j"):
                obj["cur"] = min(obj["cur"] + 1, max(0, len(obj["items"]) - 1))
            elif k in ("up", "k"):
                obj["cur"] = max(0, obj["cur"] - 1)
            elif k == "enter":
                if obj["items"]:
                    obj["back"][1]["vals"][obj["field"]] = obj.get("prefix", "") + obj["items"][obj["cur"]].get("name", "")
                self.window = obj["back"]
                if obj["items"] and obj["back"][1].get("kind") == "profile" and obj["field"] == "base":
                    self.profile_form_rebuild(obj["back"][1])
            elif k == "ins" and obj.get("allow_new") and obj["items"]:
                self.profile_form_open(obj["items"][obj["cur"]], obj["back"])
            elif k == "pgdn":
                obj["cur"] = min(obj["cur"] + 10, max(0, len(obj["items"]) - 1))
            elif k == "pgup":
                obj["cur"] = max(0, obj["cur"] - 10)
            elif k == "home":
                obj["cur"] = 0
            elif k == "end":
                obj["cur"] = max(0, len(obj["items"]) - 1)
            return "stay"
        if self.window and self.window[0] == "form":
            obj = self.window[1]
            FIELDS = obj.get("fields") or []
            key, label, kind, hint = FIELDS[obj["cur"]]
            if k == "esc":
                if False:   # (kreator curses usuniety 2026-09-21; ta galaz byla jego powrotem)
                    self.window = obj["back"]   # formularz szablonu wraca do kreatora
                else:
                    self.window, self.message = None, _(u"anulowano -- nic nie wykonano")
            elif k in ("down", "up"):
                # Naglowki szczebli nie sa polami: kursor je przeskakuje.
                step = 1 if k == "down" else -1
                c = obj["cur"] + step
                while 0 <= c < len(FIELDS) and FIELDS[c][2] == "head":
                    c += step
                if 0 <= c < len(FIELDS):
                    obj["cur"] = c
            elif k == "end":
                obj["cur"] = len(FIELDS) - 1
            elif k == "home":
                obj["cur"] = 0
            elif k == "enter":
                if kind == "go" and obj.get("kind") == "profile":
                    self.profile_plan(obj)
                elif kind == "pick":
                    self.open_profile_pick(obj, key, label)
                elif kind == "toggle":
                    obj["vals"][key] = not obj["vals"][key]
                else:
                    self.form_advance(obj, FIELDS)
            elif k == "space" and kind == "toggle":
                obj["vals"][key] = not obj["vals"][key]
            elif k == "bs" and kind in ("text", "num", "cron"):
                obj["vals"][key] = obj["vals"][key][:-1]
            elif k.startswith("text:") and kind in ("text", "pick", "cron"):
                obj["vals"][key] += k[5:]
            elif k.startswith("text:") and kind == "num":
                obj["vals"][key] += "".join(c for c in k[5:] if c.isdigit())
            elif raw and len(raw) == 1 and raw.isprintable() and kind in ("text", "pick", "cron"):
                obj["vals"][key] += raw
            elif raw and len(raw) == 1 and raw.isdigit() and kind == "num":
                obj["vals"][key] += raw
            return "stay"
        if self.window and self.window[0] == "confirm":
            obj = self.window[1]
            if k in ("t", "text:t"):
                self.window = None
                if obj.get("on_yes"):
                    obj["on_yes"]()
                else:
                    self.run_detached(obj["title"], obj["argv"], obj.get("redirect"))
            elif obj.get("alt") and k == obj["alt"][0]:
                # Drugi wariant tego samego klawisza (F8: Wstrzymaj -> Wyłącz także na źródle).
                self.window = None
                obj["alt"][1]()
            elif k == "tab":
                # Komenda do linii polecen: widac ja, mozna poprawic, Enter wykona
                # na pierwszym planie. Nic nie rusza samo. Tab jak do kolejnego
                # obiektu na ekranie (wlasciciel 2026-10-18), nie litera 'e'.
                self.window, self.cmd, self.hist_pos, self.focus = None, obj["shell"], None, "cmd"
                self.message = _(u"komenda w linii poleceń -- popraw i Enter wykona (Esc czyści)")
            elif k in ("down", "j"):
                self.scroll += 1
            elif k in ("up", "k"):
                self.scroll = max(0, self.scroll - 1)
            elif k == "pgdn":
                self.scroll += max(1, height - 4)
            elif k == "pgup":
                self.scroll = max(0, self.scroll - max(1, height - 4))
            else:
                self.window, self.message = None, _(u"anulowano -- nic nie wykonano")
            return "stay"
        if self.window and self.window[0] == "migawki":
            obj = self.window[1]
            if k in ("esc", "q"):
                self.window, self.scroll = None, 0
            elif k == "tab" and obj.get("dst"):
                obj["side"] = 1 - obj.get("side", 0)
                self.scroll = 0
            elif k == "enter" and obj.get("dst"):
                # Przeglądaj kopię (montaż tylko do odczytu + mc) -- to samo okno co F4 Kopie,
                # od razu na tej kopii.
                self.window, self.scroll = None, 0
                return self.run_dialog([self.zb(), "browse", obj["name"], "--ask", "--dataset=%s" % obj["dst"]]) or "stay"
            elif k in ("down", "j"):
                self.scroll += 1
            elif k in ("up", "k"):
                self.scroll = max(0, self.scroll - 1)
            elif k == "pgdn":
                self.scroll += max(1, height - 4)
            elif k == "pgup":
                self.scroll = max(0, self.scroll - max(1, height - 4))
            return "stay"
        if self.window and self.window[0] == "output":
            if k in ("esc", "q", "enter"):
                obj = self.window[1]
                if obj.get("back_to"):
                    self.window, self.scroll = obj["back_to"], 0
                    return "stay"
                self.window, self.scroll = None, 0
                if obj.get("proc") is None:
                    # Okno tylko pokazywalo (klucz nosnika F8, odmowa importu): nic nie
                    # biegło, nic do czytania (wlasciciel 2026-10-29, Esc po F8 Klucz).
                    return "stay"
                if obj["proc"].poll() is None:
                    self.message = _(u"proces biegnie dalej (pid %d); wyjście: %s") % (obj["proc"].pid, obj["path"])
                self.refresh_bg()
                self.wait_fresh = True
            elif k in ("down", "j"):
                self.scroll += 1
            elif k in ("up", "k"):
                self.scroll = max(0, self.scroll - 1)
            elif k == "pgdn":
                self.scroll += max(1, height - 4)
            elif k == "pgup":
                self.scroll = max(0, self.scroll - max(1, height - 4))
            elif k == "end":
                self.scroll = 10 ** 6
            return "stay"
        if self.window:
            if k in ("esc", "q", "enter"):
                self.window, self.scroll = None, 0
            elif k == "e" and self.window[0] == "panel" and self.window[1].get("template"):
                # ZMIANA SZABLONU (uwaga 24): okna whiptail; fabryczny -- okno mowi, ze Ins robi kopie.
                n = self.window[1]["template"]
                self.window, self.scroll = None, 0
                return self.run_template_dialog([self.zb(), "save-profile", "--ask", "--edit=%s" % n]) or "stay"
            elif k == "e" and self.window[0] == "panel" and self.window[1].get("replica"):
                # ZMIANA REPLIKI: te same okna co Ins na F6, wypelnione.
                n = self.window[1]["replica"]
                self.window, self.scroll = None, 0
                return self.run_dialog([self.zb(), "add-replica", n, "--ask"]) or "stay"
            elif k == "d" and self.window[0] == "relacja" and self.window[1].get("kind") == "relation" \
                    and finish_argv(self.window[1].get("rel") or {}):
                # DOKONCZ (paczka A finiszu, 2026-10-18): relacja, ktora nie jest aktywna,
                # dostaje NASTEPNY KROK cyklu jako zwykle potwierdzenie (t wykonuje) --
                # zamiast komendy do przepisania z panelu. Kroki wznawialne, jak w CLI.
                rel = self.window[1]["rel"]
                self.window, self.scroll = None, 0
                self.confirm(_(u"Dokończ relację %s") % rel.get("name"), [self.zb()] + finish_argv(rel),
                             note_lines=[_(u"Stan: %s -- następny krok cyklu relacji (można powtórzyć).") % state_word(rel)])
                return "stay"
            elif k in ("s", "c") and self.window[0] == "relacja" and self.window[1].get("kind") == "relation":
                # U65 (makieta 2026-10-21): czynnosci nie sa czescia zmiany relacji -- zapis jako
                # szablon ('s') i reczna edycja konfigu ('c') otwieraja sie wprost z tego okna.
                n = self.window[1]["name"]
                self.window, self.scroll = None, 0
                return self.run_dialog([self.zb(), "edit-relation", n, "--ask"],
                                       env={"EDIT_DO": "zapisz" if k == "s" else "config"}) or "stay"
            elif k == "e" and self.window[0] == "relacja" and self.window[1].get("kind") == "relation":
                # ZMIANA RELACJI (2026-10-07): okna whiptail edit-relation, jak Del
                # dla usuwania. Litera dziala tylko w oknie na wierzchu (bez okna
                # jest tekstem linii polecen), stad 'e' w oknie szczegolow.
                n = self.window[1]["name"]
                self.window, self.scroll = None, 0
                return self.run_dialog([self.zb(), "edit-relation", n, "--ask"]) or "stay"
            elif k in ("left", "right") and self.window[0] == "relacja" and self.window[1].get("kind") == "relation":
                ob = self.window[1]
                ob["tab"] = (ob.get("tab", 0) + (1 if k == "right" else -1)) % len(RELATION_TABS)
                self.scroll = 0
            elif k in ("down", "j"):
                self.scroll += 1
            elif k in ("up", "k"):
                self.scroll = max(0, self.scroll - 1)
            elif k == "pgdn":
                self.scroll += max(1, height - 4)
            elif k == "pgup":
                self.scroll = max(0, self.scroll - max(1, height - 4))
            elif k == "home":
                self.scroll = 0
            elif k == "end":
                self.scroll = 10 ** 6
            elif k == "F1":
                self.window, self.scroll = ("pomoc", None), 0
            return "stay"
        # AKCJE OKNA NA F7 (R4-2): przelacznik transferow usunietych relacji na F4
        # (NOTE 8) i widok sortowania na F2 (R3-4). Wczesniej byly to litery 'u'
        # i 's' -- martwe w prawdziwym GUI, bo petla curses oddaje kazdy
        # drukowalny znak linii polecen. Dzialaja takze przy tekscie w linii
        # (klawisz F nie jest tekstem, wiec niczego nie zabiera).
        # Kursor zostaje na TYM SAMYM WIERSZU (ten sam obiekt), nie na tym samym
        # numerze -- inaczej przelaczenie widoku przenosiloby operatora na cudze zadanie.
        if k == "F7" and self.screen == "zadania":
            self.run_job_now()
            return "stay"
        if k == "F8" and self.screen == "odzysk":
            self.kopie_group = not self.kopie_group    # kursor zostaje na tej samej kopii
            return "stay"
        if k in ("F8", "F9") and self.screen == "zadania":
            c0 = self.cursor["zadania"]
            cur_row = self.runrows[c0] if 0 <= c0 < len(self.runrows) else None
            if k == "F8":
                self.prz_done = not self.prz_done
            else:
                self.prz_group = not self.prz_group
            self.runrows = build_runs(self.data, self.jobrows, self.now(), self.prz_done, self.prz_group)
            self.cursor["zadania"] = self.run_cursor_for(cur_row)
            return "stay"
        # LINIA POLECEN: pisanie, kasowanie, historia, wykonanie. Litera to
        # TEKST, nie skrot -- 'echo' ma dac 'echo', nie 'cho' (pve9, pty).
        if len(k) == 1 and k.isprintable():
            k = "text:" + k
        if k.startswith("text:"):
            self.cmd += k[5:]
            self.hist_pos = None
            return "stay"
        if raw and len(raw) == 1 and raw.isprintable():
            self.cmd += raw
            self.hist_pos = None
            return "stay"
        # Klawisz F dziala takze przy tekscie w linii -- nie jest tekstem. Ctrl-R
        # (odswiez, od 2026-10-09 jedyny -- F5 to Szablony) tez: przy F5 dzialalo.
        FKEYS = ("F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "ctrl-r")
        if self.focus == "cmd" and not self.cmd and k not in FKEYS:
            if k in ("esc", "tab"):
                self.focus = "list"
            elif k == "up" and self.cmd_hist:
                self.hist_pos = len(self.cmd_hist) - 1
                self.cmd = self.cmd_hist[self.hist_pos]
            return "stay"
        if self.cmd and k not in FKEYS:
            if k == "tab":
                self.focus = "list"
                return "stay"
            if k == "bs":
                self.cmd = self.cmd[:-1]
            elif k in ("esc", "ctrl-u"):
                self.cmd, self.hist_pos = "", None
            elif k == "enter":
                self.focus = "list"
                return self.run_cmd(self.cmd)
            elif k == "up" and self.cmd_hist:
                self.hist_pos = len(self.cmd_hist) - 1 if self.hist_pos is None else max(0, self.hist_pos - 1)
                self.cmd = self.cmd_hist[self.hist_pos]
            elif k == "down" and self.hist_pos is not None:
                self.hist_pos = self.hist_pos + 1
                if self.hist_pos >= len(self.cmd_hist):
                    self.cmd, self.hist_pos = "", None
                else:
                    self.cmd = self.cmd_hist[self.hist_pos]
            return "stay"
        if k in ("q", "F12"):
            return "quit"
        if k == "F10":
            # USTAWIENIA HOSTA (właściciel 2026-10-19): okna tui/settings.sh przez
            # `settings --ask`; logika (walidacja, zapis, przeliczenie crona) w czasowniku.
            return self.run_dialog([self.zb(), "settings", "--ask"]) or "stay"
        if k == "F1":
            self.window, self.scroll = ("pomoc", None), 0
            return "stay"
        # TAB = KOLEJNY OBIEKT NA EKRANIE (wlasciciel 2026-10-18): lista -> (pary na
        # F3) -> linia polecen -> lista. W linii strzalki to historia takze przy
        # pustej linii, Enter wykonuje, Esc albo Tab wraca do listy.
        if k == "tab":
            order = ["list", "pairs", "cmd"] if self.screen in TABS else ["list", "cmd"]
            cur = self.focus if self.focus in order else "list"
            self.focus = order[(order.index(cur) + 1) % len(order)]
            if self.focus == "pairs":
                self.pair_cursor = 0
            return "stay"
        # DOLNY PANEL (U21): strzalki po dzieciach, lewo/prawo -- zakladki, Enter --
        # pelne okno dziecka, Esc -- z powrotem na liste. Reszta klawiszy (F, Ins,
        # Del) dziala jak na liscie.
        if self.screen in TABS and self.focus == "pairs":
            items = (self.child_info() or {}).get("items") or []
            n, c, nav = len(items), self.pair_cursor, True
            if k in ("down", "j"):
                c = min(c + 1, max(0, n - 1))
            elif k in ("up", "k"):
                c = max(0, c - 1)
            elif k == "pgdn":
                c = min(c + 5, max(0, n - 1))
            elif k == "pgup":
                c = max(0, c - 5)
            elif k == "home":
                c = 0
            elif k == "end":
                c = max(0, n - 1)
            elif k in ("left", "right"):
                tabs = TABS[self.screen]
                self.ctab[self.screen] = (self.ctab.get(self.screen, 0) + (1 if k == "right" else -1)) % len(tabs)
                c = 0
            elif k == "esc":
                self.focus = "list"
            elif k == "enter":
                if n:
                    res = self.open_child(items[min(c, n - 1)])
                    if res:
                        return res
            elif k == "m" and n and items[min(c, n - 1)].get("relname"):
                self.open_snapshots(items[min(c, n - 1)])
            else:
                nav = False
            if nav:
                self.pair_cursor = c
                return "stay"
        # F2-F6 ZAWSZE przelaczaja okno (R4-1: F4 na F3 bylo pauza i przechwytywalo
        # Transfery). Pauza jest teraz na F8 (F7 = Uruchom teraz, jednolicie, 2026-10-17).
        if k == "F4" and self.screen in ("zadania", "relacje"):
            self.kopie_from_here()
            if self.screen == "odzysk":
                # kopie_from_here postawil kursor na migawce biegu (prawy panel) --
                # ponizsze przelaczenie ekranu zerowaloby fokus i pozycje.
                return "stay"
        for key, fk, _label in SCREENS:
            if k == fk:
                self.screen, self.focus, self.pair_cursor = key, "list", 0
                if key == "szablony":
                    self.ensure_profiles()
                return "stay"
        n = self.count(self.screen)
        c = self.cursor[self.screen]
        if k in ("down", "j"):
            c = min(c + 1, max(0, n - 1))
        elif k in ("up", "k"):
            c = max(0, c - 1)
        elif k == "pgdn":
            c = min(c + max(1, height - 12), max(0, n - 1))
        elif k == "pgup":
            c = max(0, c - max(1, height - 12))
        elif k == "home":
            c = 0
        elif k == "end":
            c = max(0, n - 1)
        elif k == "ctrl-r":
            self.ask_refresh()
        if self.screen == "zadania" and k in ("down", "j", "up", "k", "pgdn", "pgup", "home", "end"):
            c = self.run_step(c, -1 if k in ("up", "k", "pgup", "end") else 1)
        elif k in ("del", "ins") and self.screen == "szablony":
            return self.template_action(k) or "stay"
        elif k in ("F7", "F8", "F9", "del", "ins") and self.screen == "relacje":
            return self.action(k) or "stay"
        elif k in ("F7", "F8", "F9", "del", "ins") and self.screen == "nosniki":
            return self.replica_action(k) or "stay"
        elif k in ("F7", "enter", "F9") and n and self.screen == "odzysk":
            self.cursor["odzysk"] = c
            it = self.kopie_current()
            if it.get("note"):
                return "stay"      # replika bez nosnika / relacja bez kopii: nie ma czego otworzyc
            if self.focus == "pairs":
                snaps = self.kopie_snaps(it)[0]
                s_ = snaps[min(self.pair_cursor, len(snaps) - 1)] if snaps else None
                if s_ is None:
                    return "stay"
                return (self.kopie_restore(it, s_) if k == "F9" else self.kopie_browse(it, s_)) or "stay"
            if k == "F9":
                return self.kopie_restore(it, None) or "stay"
            if it.get("any"):
                return self.kopie_browse(it, None) or "stay"
            if self.kopie_snaps(it)[0]:
                self.focus, self.pair_cursor = "pairs", 0
            return "stay"
        elif k == "enter" and n:
            if self.screen == "relacje":
                self.window, self.scroll = ("relacja", self.rows[c]), 0
            elif self.screen == "zadania" and self.runrows[c].get("kind") != "run":
                pass
            elif self.screen == "zadania" and self.runrows[c].get("static"):
                self.window, self.scroll = ("relacja", self.runrows[c]["item"]), 0
            elif self.screen == "zadania" and self.runrows[c]["item"].get("kind") == "replica":
                # Wiersz repliki: ten sam panel co na F6 (z 'e' = zmiana repliki).
                jr = self.runrows[c]["item"]
                self.window, self.scroll = ("panel", {
                    "kind": "panel", "name": _(u"replika %s") % jr["name"], "replica": jr["name"],
                    "pairs": replica_detail_pairs(jr["replica"], self.ch, jr["srow"], self.data.failed("stats"))}), 0
            elif self.screen == "zadania":
                self.window, self.scroll = ("relacja", run_window_row(self.runrows[c])), 0
            else:
                # Pozostale ekrany maja panel szczegolow; Enter otwiera go jako
                # okno, zeby dlugie wartosci nie byly ucinane.
                self.window, self.scroll = ("panel", self.panel_lines()), 0
        if c != self.cursor[self.screen]:
            self.pair_cursor = 0
        self.cursor[self.screen] = c
        return "stay"

    def child_info(self):
        """Dzieci zaznaczonego wiersza w biezacej zakladce -- te same budowniczki co ekran."""
        sc, now, ch = self.screen, self.now(), self.ch
        tabs = TABS.get(sc)
        if not tabs:
            return None
        c = self.cursor.get(sc, 0)
        key = tabs[self.ctab.get(sc, 0) % len(tabs)][0]
        if sc == "zadania":
            if not (0 <= c < len(self.runrows)):
                return {"items": []}
            return run_children(self.runrows[c], self.data, now, ch)
        if sc == "relacje":
            return rel_children(key, self.rows[c], self.data, self.jobrows, now, ch) if 0 <= c < len(self.rows) else None
        if sc == "szablony":
            profs = self.data.profiles or []
            return tpl_children(key, profs[c], self.rows, now, ch) if 0 <= c < len(profs) else None
        if sc == "nosniki":
            reps = (self.data.replicas or {}).get("replicas", [])
            return rep_children(key, reps[c], self.data, now, ch) if 0 <= c < len(reps) else None
        if sc == "odzysk":
            it = self.kopie_current()
            return {"items": self.kopie_snaps(it)[0] if it and it.get("ds") else []}
        return None

    def open_snapshots(self, it):
        """U38 (wlasciciel 2026-10-20, "cos w stylu mc, z widokiem migawek"): klawisz m na
        parze = migawki obu stron wyrownane po GUID. Enter zostaje oknem zadania (R4-6)."""
        src = pair_source_dataset(it["pair"])
        d, err = run_verb(self.repo, ["pair-snapshots", it["relname"], src, "--json"])
        if not isinstance(d, dict):
            self.message = _(u"migawki pary nie do odczytania: %s") % (err or _(u"brak odpowiedzi"))
            return
        self.window, self.scroll = ("migawki", {"name": it["relname"], "src": src, "data": d, "side": 0,
                                                "dst": (d.get("target") or {}).get("dataset") or ""}), 0

    def open_child(self, it):
        """Enter na dziecku: para relacji -> okno jej zadania (config, cron), zadanie ->
        okno zadania, dataset odzysku -> okna Przywroc, reszta -> panel jako okno."""
        if it.get("pair") is not None:
            j = it["pair"].get("job")
            if j is None:
                self.message = _(u"ten dataset jest tylko w definicji relacji, nie w cronie -- nie ma zadania do pokazania")
                return None
            for jr in self.jobrows:
                if any(x is j for x in jr.get("jobs") or []):
                    one = dict(jr)
                    one.update({"job": j, "jobs": [j], "cnt": 1})
                    self.window, self.scroll = ("relacja", one), 0
                    break
            return None
        if it.get("jobrow") is not None:
            self.window, self.scroll = ("relacja", it["jobrow"]), 0
            return None
        if self.screen == "odzysk" and it.get("kopie"):
            return self.kopie_browse(self.kopie_current(), it)
        self.window, self.scroll = ("panel", {"kind": "panel", "name": it.get("title") or "", "pairs": it.get("pairs") or []}), 0
        return None

    def panel_lines(self):
        now, ch = self.now(), self.ch
        c = self.cursor[self.screen]
        if self.screen == "monitor":
            m = monitor_rows(self.data)[c]
            return {"kind": "panel", "name": "monitor %s" % (m.get("label") or ""), "pairs": monitor_detail_pairs(m, ch, full=True)}
        if self.screen == "szablony":
            pr = (self.data.profiles or [])[c]
            return {"kind": "panel", "name": _(u"szablon %s") % pr.get("name"), "pairs": template_detail_pairs(pr),
                    "template": pr.get("name")}
        rp = (self.data.replicas or {}).get("replicas", [])[c]
        return {"kind": "panel", "name": _(u"nośnik %s") % rp.get("name"),
                "pairs": replica_detail_pairs(rp, ch, replica_stats_row(self.data, rp.get("name")), self.data.failed("stats")),
                "replica": rp.get("name")}


def relation_window_lines_dispatch(ui, obj, width):
    if obj.get("kind") == "panel":
        return detail_kv(ui.ch, obj["pairs"], width - 4)
    return relation_window_lines(obj, ui.data, ui.now(), ui.ch, width, ui.repo, ui.files,
                                 tab=obj.get("tab", 0) if obj.get("kind") == "relation" else None)


# render() w UI korzysta z tej wersji, zeby okno-panel i okno-relacja szly ta sama droga.
def _ui_render(self, width, height):
    width = max(MIN_WIDTH, width)
    now = self.now()
    # Ekran jest o jedna linie nizszy: nad listwa klawiszy stoi LINIA POLECEN.
    sh = height - 1
    if self.screen == "zadania":
        base = render_zadania(self.data, self.runrows, self.cursor["zadania"], width, sh, now, self.ch, self.message,
                              show_done=self.prz_done, grouped=self.prz_group, focus=self.focus, pair_cursor=self.pair_cursor)
    elif self.screen == "relacje":
        base = render_relacje(self.data, self.rows, self.cursor["relacje"], width, sh, now, self.ch, self.message,
                              focus=self.focus, pair_cursor=self.pair_cursor, jobrows=self.jobrows,
                              ti=self.ctab.get("relacje", 0))
    elif self.screen == "monitor":
        base = render_monitor(self.data, self.cursor["monitor"], width, sh, now, self.ch, self.message)
    elif self.screen == "szablony":
        base = render_szablony(self.data, self.cursor["szablony"], width, sh, now, self.ch, self.message, rows=self.rows,
                               focus=self.focus, pair_cursor=self.pair_cursor, ti=self.ctab.get("szablony", 0))
    elif self.screen == "odzysk":
        items, selix = self.kopie_state()
        # przyciecie tutaj, nie w apply_data (tam drzewa kopii nie czytamy poza F4)
        c = self.cursor["odzysk"] = min(self.cursor["odzysk"], max(0, len(selix) - 1))
        it = items[selix[c]] if 0 <= c < len(selix) else {}
        snaps, serr = self.kopie_snaps(it) if it.get("ds") else ([], None)
        base = render_kopie_tab(self.data, items, selix, c, self.focus, self.pair_cursor,
                                snaps, serr, width, sh, now, self.ch, ctx=self.kopie_ctx, grouped=self.kopie_group)
    else:
        base = render_nosniki(self.data, self.cursor["nosniki"], width, sh, now, self.ch, self.message,
                              focus=self.focus, pair_cursor=self.pair_cursor, ti=self.ctab.get("nosniki", 0),
                              jobrows=self.jobrows)
    # LINIA POLECEN ZAWSZE NA DOLE, takze pod oknem (wlasciciel 2026-10-18: okna
    # nie na caly ekran, na dole widac bash i polecenie zlozone przez okno). Okno
    # potwierdzenia pokazuje w niej swoje polecenie; Tab przenosi je do edycji.
    if self.window and self.window[0] == "confirm":
        cl = self.prompt_text() + self.window[1].get("shell", "")
    elif self.window:
        cl = self.prompt_text() + self.cmd
    else:
        cl = self.prompt_text() + self.cmd + "_"
    if len(cl) > width:
        # Dluga komenda: widac jej KONIEC (tam sie pisze), poczatek za ellipsa.
        cl = self.ch.ell + cl[len(cl) - width + 1:]
    base.lines.insert(len(base.lines) - 1, fit(cl, width))
    base.bars = {0, len(base.lines) - 1}
    base.cmd_y = len(base.lines) - 2
    if not self.window and self.focus == "cmd":
        base.cursor_y = base.cmd_y
    if self.window:
        kind, obj = self.window
        if kind == "pomoc":
            scr, self.scroll = render_window(base, _("Pomoc"), [_(h) for h in HELP], self.scroll, width, height, self.ch, wrap=True)
        elif kind == "prompt":
            lines = ["", " " + obj["label"], "", fit("  > " + obj["value"] + "_", width - 4), ""]
            if obj.get("error"):   # w OKNIE: linia komunikatu pod oknem jest zaslonieta przez stopke okna
                lines += [fit(u" ! " + x, width - 4) for x in wrap(obj["error"], width - 8)] + [""]
            scr, self.scroll = render_window(base, obj["title"], lines, 0, width, height, self.ch,
                                             footer=obj.get("footer") or _(u"Enter dalej   Esc wraca"))
        elif kind == "confirm":
            # KLAWISZE TYLKO NA RAMCE (właściciel 2026-10-09 uwaga 4, powtórzone 10-18 U7):
            # wariant okna (F8: w = wyłącz) stoi obok "t wykonaj", nie w treści.
            _alt = obj.get("alt")
            _foot = _(u"t wykonuje   ") + (u"%s %s   " % (_alt[0], _alt[2]) if _alt and len(_alt) > 2 else "") \
                + _(u"Tab do linii poleceń   Esc wraca")
            scr, self.scroll = render_window(base, _(u"POTWIERDZENIE: ") + obj["title"], obj["lines"], self.scroll, width, height, self.ch,
                                             footer=_foot)
        elif kind == "form":
            lines = self.form_lines(obj, width)
            # Dlugi formularz (nowy szablon) przewija sie za kursorem.
            cy = obj.get("_cur_y", 0)
            fscroll = 0 if cy + 2 < height - 3 else cy + 2 - (height - 3) + 1
            scr, self.scroll = render_window(base, obj["title"], lines, fscroll, width, height, self.ch,
                                             footer=_(u"strzałki pole   spacja przełącza   Enter na [ %s ]   Esc wraca") % (u"ZAPISZ" if obj.get("kind") == "profile" else u"PLAN"))
        elif kind == "files":
            top_ = max(0, obj["cur"] - (height - 7))
            scr, self.scroll = render_window(base, obj["title"], self.files_lines(obj, width), top_, width, height, self.ch,
                                             footer=_(u"Enter wchodzi / importuje   Esc wraca   strzałki"))
        elif kind == "choice":
            lines = [fit("%s %s" % (">" if i == obj["cur"] else " ", label), width - 4) for i, (_t, label) in enumerate(obj["items"])]
            scr, self.scroll = render_window(base, obj["title"], lines, 0, width, height, self.ch,
                                             footer=_(u"Enter wybiera   Esc wraca   strzałki"))
        elif kind == "pick":
            scr, self.scroll = render_window(base, obj["title"], self.picker_lines(obj, width), self.scroll, width, height, self.ch,
                                             footer=_(u"Enter wybiera   Esc wraca bez zmiany"))
            per = 1 if obj.get("kind") == "datasets" else 2
            if obj["cur"] * per >= height - 4:
                scr, self.scroll = render_window(base, obj["title"], self.picker_lines(obj, width), obj["cur"] * per - (height - 6), width, height, self.ch,
                                                 footer=_(u"Enter wybiera   Esc wraca bez zmiany"))
        elif kind == "migawki":
            lines = snap_pair_lines(obj["data"], width, obj.get("side", 0), int(time.time()))
            two = bool(obj.get("dst")) and width - 4 >= 116
            foot = _(u"Enter przegląda kopię   Esc wraca   strzałki/PgUp/PgDn przewijają")
            if obj.get("dst") and not two:
                foot = _(u"Tab źródło/kopia   ") + foot
            if not obj.get("dst"):
                foot = _(u"Esc wraca   strzałki/PgUp/PgDn przewijają")
            scr, self.scroll = render_window(base, _(u"Migawki: relacja %s, %s") % (obj["name"], side_words(obj["src"])), lines,
                                             self.scroll, width, height, self.ch, footer=foot)
        elif kind == "output":
            lines = self.output_lines(obj, width)
            if self.scroll == 0 and obj.get("proc") is not None and obj["proc"].poll() is None:
                self.scroll = 10 ** 6   # ogon: pokazuj koniec, jak tail -f
            scr, self.scroll = render_window(base, _(u"WYJŚCIE: ") + obj["title"], lines, self.scroll, width, height, self.ch,
                                             footer=_(u"Esc zamyka okno (proces zostaje)   strzałki przewijają"))
        else:
            foot = _(u"Esc zamyka   strzałki/PgUp/PgDn przewijają")
            if obj.get("replica"):
                foot = _(u"e zmienia replikę   Esc zamyka   strzałki/PgUp/PgDn przewijają")
            if obj.get("template"):
                foot = _(u"e zmienia szablon   Esc zamyka   strzałki/PgUp/PgDn przewijają")
            if obj.get("kind") == "relation":
                _t = obj.get("tab", 0)
                # Podpowiedz lewo/prawo w TYTULE (tez ramka): w stopce przy 80 kolumnach wypychala
                # licznik wierszy "1-9 z 111".
                title = (_(u"Relacja %s") % obj["name"]) + u": " + u"  ".join(
                    (u"[%s]" % _(n)) if i == _t else _(n) for i, n in enumerate(RELATION_TABS)) + u"   ←/→"
                # Odzysk przeszedł na F11 (właściciel 2026-10-18) -- tu tylko zmiana.
                foot = _(u"e zmienia   s jako szablon   c edycja ręczna   Esc zamyka")
                if finish_argv(obj.get("rel") or {}):
                    foot = _(u"d dokańcza   e zmienia   s jako szablon   c edycja ręczna   Esc zamyka")
            elif obj.get("kind") == "job":
                title = _(u"Zadanie: %s  %s  %s") % (obj["name"], obj.get("task") or "", obj.get("pref") or "")
            else:
                title = obj["name"]
            lines = relation_window_lines_dispatch(self, obj, width)
            scr, self.scroll = render_window(base, title, lines, self.scroll, width, height, self.ch, footer=foot)
        return scr
    return base


def deaccent(text):
    """Terminal bez UTF-8 dostaje slowa bez ogonkow, nie krzaczki (zasada 10)."""
    return text.translate(_DEACCENT)


_DEACCENT = {ord(a): b for a, b in zip(u"ąćęłńóśźżĄĆĘŁŃÓŚŹŻ", u"acelnoszzACELNOSZZ")}
_DEACCENT[ord(u"→")] = ">"
_DEACCENT[ord(u"←")] = "<"
_DEACCENT[ord(u"↔")] = "<>"
_DEACCENT[ord(u"\u00d7")] = "x"
for _q in u"\u201e\u201d\u201c":   # cudzyslowy „ ” “ -> "
    _DEACCENT[ord(_q)] = '"'


def _ui_render_final(self, width, height):
    scr = _ui_render(self, width, height)
    if self.message and len(scr.lines) >= 2 and not self.window:
        # Komunikat ZAWSZE tuz nad listwa klawiszy, w miejscu linii polecen (na
        # jedna klatke; tekst linii zostaje w stanie) -- panel nie ma prawa go
        # zepchnac poza ekran (tak bylo: odmowa akcji na usunietym rekordzie znikala).
        # Z tekstem w linii polecen komunikat idzie o linie wyzej, zeby nie
        # zaslaniac tego, co uzytkownik wlasnie dostal do poprawki ('e').
        scr.lines[-3 if self.cmd else -2] = fit(" " + self.message, max(MIN_WIDTH, width))
    if self.ch.ascii:
        scr.lines = [deaccent(l) for l in scr.lines]
    return scr


UI.render = _ui_render_final


# ---------------------------------------------------------------------------
# CURSES: cienka petla nad UI
# ---------------------------------------------------------------------------
# Litery i cyfry, ktore petla curses zamienia na klawisz -- ale TYLKO w oknie
# na wierzchu (potwierdzenie: 't', 'e', 'q'; przewijanie: 'j', 'k'). Bez okna
# kazdy drukowalny znak jest tekstem linii polecen.
LETTER_KEYS = {ord("q"): "q", ord("j"): "j", ord("k"): "k", ord("t"): "t", ord("e"): "e", ord("d"): "d", ord("w"): "w", ord("s"): "s", ord("c"): "c",
               ord("?"): "F1", ord("h"): "F1"}


def live_key_name(ui, k):
    """Nazwa klawisza z --keys, przepuszczona przez TE SAME reguly co petla
    curses (R4-2). Pojedynczy drukowalny znak bez okna na wierzchu -- albo w
    polu tekstowym -- to TEKST; w innym oknie znaczy tyle, ile LETTER_KEYS,
    a spoza niej nic. Bez tego `--keys u` sprawdzal skrot, ktorego operator
    nie mogl nacisnac (runda 3: 'u' i 's' zielone w testach, martwe na zywo)."""
    if len(k) != 1 or not k.isprintable():
        return k
    if not ui.window or ui.window[0] in ("prompt", "form"):
        return "text:" + k
    return LETTER_KEYS.get(ord(k), "")


def curses_loop(ui):
    import curses

    # Bez tego ncurses liczy bajty zamiast znakow i rozjezdza kolumny.
    locale.setlocale(locale.LC_ALL, "")

    def paint(stdscr, scr, h, w):
        stdscr.erase()
        cwords = color_words()
        for y, line in enumerate(scr.lines[:h]):
            # Pelna szerokosc: inaczej prawa ramka okna nigdy nie trafia na ekran. Tylko
            # dolny wiersz bez ostatniej kolumny -- prawy dolny rog to blad curses.
            line = line[:w] if y < h - 1 else line[:w - 1]
            base = 0
            if y in scr.bars:
                base = curses.color_pair(6) if curses.has_colors() else curses.A_REVERSE
            elif y == scr.cursor_y and not scr.cursor_span:
                base = curses.A_REVERSE
            try:
                stdscr.addstr(y, 0, line, base)
            except curses.error:
                pass
            if y == scr.cursor_y and scr.cursor_span:
                a, b = scr.cursor_span
                try:
                    stdscr.addstr(y, a, line[a:b], curses.A_REVERSE)
                except curses.error:
                    pass
            # Pasek F: aktywne okno i cyfry zapisu skroconego w kolorze (bez [nawiasow]).
            for a, b, kind in scr.marks.get(y, ()):
                if a >= len(line):
                    continue
                if kind == "active":
                    attr = (curses.color_pair(7) if curses.has_colors() else curses.A_REVERSE) | curses.A_BOLD
                else:
                    attr = (curses.color_pair(8) if curses.has_colors() else curses.A_BOLD) | curses.A_BOLD
                try:
                    stdscr.addstr(y, a, line[a:b], attr)
                except curses.error:
                    pass
            if y in scr.bars or y == scr.cursor_y or not curses.has_colors():
                continue
            for word, pair in cwords:
                start = 0
                while True:
                    i = line.find(word, start)
                    if i < 0:
                        break
                    try:
                        stdscr.addstr(y, i, word, curses.color_pair(pair) | curses.A_BOLD)
                    except curses.error:
                        pass
                    start = i + len(word)
        stdscr.refresh()

    KEYMAP = dict(LETTER_KEYS)

    def main(stdscr):
        curses.curs_set(0)
        if curses.has_colors():
            curses.start_color()
            curses.use_default_colors()
            for i, fg in ((1, curses.COLOR_RED), (2, curses.COLOR_GREEN), (3, curses.COLOR_YELLOW), (4, curses.COLOR_CYAN)):
                try:
                    curses.init_pair(i, fg, -1)
                except curses.error:
                    pass
            try:
                curses.init_pair(7, curses.COLOR_YELLOW, curses.COLOR_BLUE)   # aktywne okno na pasku F
                curses.init_pair(8, curses.COLOR_WHITE, curses.COLOR_BLACK)   # cyfra w zapisie skroconym
            except curses.error:
                pass
            try:
                curses.init_pair(6, curses.COLOR_BLACK, curses.COLOR_CYAN)
            except curses.error:
                pass
        KEYMAP.update({curses.KEY_LEFT: "left", curses.KEY_RIGHT: "right", curses.KEY_DOWN: "down", curses.KEY_UP: "up", curses.KEY_NPAGE: "pgdn", curses.KEY_PPAGE: "pgup",
                       curses.KEY_HOME: "home", curses.KEY_END: "end", curses.KEY_F1: "F1", curses.KEY_F2: "F2",
                       curses.KEY_F3: "F3", curses.KEY_F4: "F4", curses.KEY_F5: "F5", curses.KEY_F6: "F6",
                       curses.KEY_F7: "F7", curses.KEY_F8: "F8", curses.KEY_IC: "ins", curses.KEY_DC: "del",
                       curses.KEY_BACKSPACE: "bs", 127: "bs", 8: "bs", curses.KEY_ENTER: "enter",
                       10: "enter", 13: "enter", 27: "esc", curses.KEY_F10: "F10", curses.KEY_F9: "F9", curses.KEY_F11: "F11", curses.KEY_F12: "F12", 9: "tab",
                       21: "ctrl-u", 18: "ctrl-r", 15: "ctrl-o"})
        stdscr.keypad(True)
        # OBA DIALEKTY STRZALEK I F-KLAWISZY, CZYTANE WPROST. keypad() wlacza w
        # terminalu tryb aplikacyjny (ESC O B), a terminal, ktory go nie honoruje
        # -- albo pty, ktore go nie widzi -- sle ESC [ B; terminfo xterm zna
        # tylko pierwszy, a curses.define_key na pve10 nic nie zmienil
        # (zmierzone 2026-09-09: 'j' przesuwal kursor, ESC [ B nie, i pauza
        # poszla na ZLY wiersz). Wiec po ESC dobieramy bajty sami, z krotkim
        # czekaniem, i mapujemy sekwencje z tablicy -- goly ESC to Esc.
        # Goly Esc ma byc natychmiastowy: ncurses czeka domyslnie 1 s na ciag
        # dalszy, a swoj ciag dalszy zbieramy sami ponizej.
        try:
            curses.set_escdelay(25)
        except (AttributeError, curses.error):
            pass
        E = chr(27)
        SEQ = {"[A": "up", "[B": "down", "OA": "up", "OB": "down", "[H": "home", "[F": "end", "OH": "home", "OF": "end",
               "[1~": "home", "[4~": "end", "[5~": "pgup", "[6~": "pgdn", "[2~": "ins", "[3~": "del",
               "OP": "F1", "OQ": "F2", "OR": "F3", "OS": "F4", "[11~": "F1", "[12~": "F2", "[13~": "F3", "[14~": "F4",
               "[15~": "F5", "[17~": "F6", "[18~": "F7", "[19~": "F8", "[20~": "F9", "[21~": "F10", "[23~": "F11", "[24~": "F12", "[[A": "F1", "[[B": "F2", "[[C": "F3", "[[D": "F4", "[[E": "F5"}

        def wch():
            """(kod, czy_znak): get_wch odroznia znak od klawisza; -1 = nic."""
            try:
                k = stdscr.get_wch()
            except curses.error:
                return -1, False
            if isinstance(k, str):
                return ord(k), True
            return k, False

        # POWRÓT BEZ STAREGO EKRANU (właściciel 2026-10-26, pve2: po oknie GUI stało ze starymi
        # danymi i napisem "odświeżam w tle" -- "user może odnieść wrażenie, że hang"). Po oknie
        # główny ekran rysuje się dopiero ze świeżymi danymi; do tego czasu widać, że trwa
        # wczytywanie (sekundy) i komunikat okna. Bezpiecznik: po BG_KEY_WAIT * 2 s rysuje stary.
        def wait_fresh(scr):
            ui.wait_fresh = False
            bg = getattr(ui, "_bg", None)
            t0 = time.time()
            while bg is not None and bg[0].is_alive() and time.time() - t0 < ui.BG_KEY_WAIT * 2:
                h, w = scr.getmaxyx()
                msg = ui.message or u""
                if msg.endswith(_(ui.BG_NOTE)):
                    msg = msg[:-len(_(ui.BG_NOTE))]
                lines = [_(u"Wczytuję aktualne dane hosta… %d s") % int(time.time() - t0)]
                if msg.strip():
                    lines += [u"", msg.strip()]
                scr.erase()
                for i, l in enumerate(lines):
                    l = l[:max(1, w - 2)]
                    try:
                        scr.addstr(max(0, h // 2 - 1) + i, max(0, (w - len(l)) // 2), l)
                    except curses.error:
                        pass
                scr.refresh()
                bg[0].join(0.3)
            ui.poll_bg()

        def read_key():
            k, is_char = wch()
            if k != 27:
                return k, None, is_char
            stdscr.nodelay(True)
            seq = ""
            try:
                deadline = time.time() + 0.15
                while time.time() < deadline and len(seq) < 6:
                    c, c_char = wch()
                    if c == -1:
                        time.sleep(0.01)
                        continue
                    if not c_char or c > 255:
                        break
                    seq += chr(c)
                    if seq in SEQ or (seq.startswith("[") and seq.endswith("~")) or (seq.startswith("O") and len(seq) == 2):
                        break
            finally:
                stdscr.nodelay(False)
            if not seq:
                return 27, None, False
            if seq in SEQ:
                return -2, SEQ[seq], False
            # Nie nasza sekwencja (np. ESC, a chwile pozniej 'q'): oddaj bajty
            # z powrotem, w kolejnosci, i zglos goly Esc. Bez tego 'q' po Esc
            # gineło i TUI wisiało -- zmierzone na pve10 2026-09-09 (jazda 6).
            for ch_ in reversed(seq):
                try:
                    curses.ungetch(ord(ch_))
                except curses.error:
                    pass
            return 27, None, False
        while True:
            if getattr(ui, "wait_fresh", False):
                wait_fresh(stdscr)
            h, w = stdscr.getmaxyx()
            if h < 10 or w < 40:
                stdscr.erase()
                try:
                    stdscr.addstr(0, 0, _("za maly terminal (%dx%d); minimum 40x10") % (w, h))
                except curses.error:
                    pass
                stdscr.refresh()
            else:
                paint(stdscr, ui.render(w, h), h, w)
            # Na ekranie transferow postep zyje: co 2 s czytamy TYLKO progress
            # (to pliki, nie komenda), i curses maluje roznice, nie ekran.
            if ui.window and ui.window[0] == "output" and ui.window[1].get("proc") is not None and ui.window[1]["proc"].poll() is None:
                stdscr.timeout(500)          # ogon pliku wyjscia zyje
            elif ui.bg_pending() or ui.slow_pending():
                stdscr.timeout(300)          # dane z tła: przerysuj, gdy dojdą
            else:
                stdscr.timeout(-1)
            k, seqname, is_char = read_key()
            if k == -1:
                ui.poll_bg()
                ui.poll_slow()
                continue
            ui.poll_bg()
            ui.poll_slow()
            if k == curses.KEY_RESIZE:
                continue
            name = seqname if k == -2 else KEYMAP.get(k)
            # U90 (wlasciciel 2026-10-27: "w całym pakiecie przycisk pokazujący, co jest pod
            # panelem"): Ctrl-O jak w mc -- konsola pod oknami, czyli wyjscie ostatnich polecen;
            # dowolny klawisz wraca. Okna wracaja same, bez "Enter = powrót".
            if name == "ctrl-o" and not (ui.window and ui.window[0] in ("prompt", "form")):
                show_console(stdscr)
                continue
            # W polu tekstowym KAZDY drukowalny znak jest wejsciem, nie klawiszem
            # skrotu -- inaczej sciezki z 'q' albo 'j' nie daloby sie wpisac.
            if ui.window and ui.window[0] == "form" and k == 32:
                ui.key("space", h)
                continue
            if ui.window and ui.window[0] in ("prompt", "form") and is_char and name not in ("esc", "enter", "bs", "up", "down") and 32 <= k < 0x110000:
                try:
                    ch_ = chr(k)
                except ValueError:
                    continue
                ui.key("text:" + ch_, h)
                continue
            # LINIA POLECEN (bez okna na wierzchu): KAZDY drukowalny znak jest
            # tekstem -- litery-skroty (q r j k h ? cyfry) dzialaja tylko w
            # oknach. Backspace/Enter/Esc/strzalki rozstrzyga UI.key po stanie linii.
            if not ui.window and is_char and 32 <= k < 0x110000:
                try:
                    ch_ = chr(k)
                except ValueError:
                    continue
                if ch_.isprintable():
                    ui.key("text:" + ch_, h)
                continue
            if name is None:
                continue
            res = ui.key(name, h)
            if res == "quit":
                return
            if getattr(ui, "pending_refresh", False):
                paint(stdscr, ui.render(w, h), h, w)
                ui.run_pending()
            if res == "shell" and ui.pending_shell:
                line, ui.pending_shell = ui.pending_shell, None
                nowait, ui.pending_nowait = ui.pending_nowait, False
                curses.endwin()
                if not nowait:
                    sys.stdout.write("$ %s\n" % line)
                    sys.stdout.flush()
                # Ctrl+C belongs to the dialog, not to us: with SIGINT left on, the GUI got
                # KeyboardInterrupt too, lost the dialog's exit code and showed "[rc=?]"
                # (owner note 8, 2026-10-08). Ignored here, restored right after -- and
                # back to default in the child: an ignored SIGINT is inherited across
                # exec, and the command would then ignore Ctrl+C as well.
                _old_int = signal.signal(signal.SIGINT, signal.SIG_IGN)
                try:
                    rc = subprocess.call(line, shell=True, cwd=ui.repo,
                                         preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
                except OSError as e:
                    rc = "?"
                    sys.stdout.write("%s\n" % e)
                finally:
                    signal.signal(signal.SIGINT, _old_int)
                if rc == 130:
                    rc = u"130, przerwane (Ctrl+C)"
                if not nowait:
                    sys.stdout.write("[rc=%s]\n" % rc)
                    sys.stdout.flush()
                stdscr.clear()
                stdscr.refresh()
                if nowait:
                    ui.message = ui.window_end_message(rc)
                else:
                    ui.message = (u"[rc=%s] %s   " % (rc, line)) + _(u"Ctrl-O pokaże wynik")
                    log_path, ui.pending_log_path = ui.pending_log_path, None
                    if log_path:
                        ui.message += _(u"   dziennik: %s") % log_path
                # Kursor na nowej relacji -- dopiero gdy świeże dane wejdą (poll_bg).
                ui.rel_names_before_bg = getattr(ui, "rel_names_before", None)
                ui.rel_names_before = None
                if getattr(ui, "noreload_after", False):
                    # U104 (wlasciciel 2026-10-28): przegladanie kopii niczego nie zmienia,
                    # wiec bez czekania na pelne odswiezenie -- dane odswieza Ctrl-R albo
                    # kolejne okno. Tak samo okno, ktore samo powiedzialo "nic nie zmieniono"
                    # (wt_end_nochange). Wszystkie inne okna nadal odswiezaja (decyzja 2026-10-09).
                    ui.noreload_after = False
                else:
                    only, ui.pending_reload = getattr(ui, "pending_reload", None), None
                    ui.refresh_bg(only)
                    ui.wait_fresh = only != ()
    curses.wrapper(main)


# ---------------------------------------------------------------------------
def want_ascii(args):
    if args.ascii:
        return True
    if args.utf8:
        return False
    for v in ("LC_ALL", "LC_CTYPE", "LANG"):
        val = os.environ.get(v)
        if val:
            return "utf" not in val.lower()
    return True


def main(argv):
    ap = argparse.ArgumentParser(description=u"Pięć okien nad zfs-snapshot-all (tylko odczyt)")
    ap.add_argument("--render-once", action="store_true", help="wydrukuj ekran jako tekst i zakoncz (testy, podglad przez ssh bez terminala)")
    ap.add_argument("--screen", default="zadania", choices=[s[0] for s in SCREENS], help="ktory ekran (z --render-once)")
    ap.add_argument("--keys", default="", help="sekwencja klawiszy po przecinku, np. down,down,enter,pgdn; 'text:abc' wpisuje tekst, 'bs' kasuje (z --render-once)")
    ap.add_argument("--exec-log", help="TESTY: zamiast uruchamiac czasowniki, dopisuj komendy do tego pliku")
    ap.add_argument("--width", type=int, default=80)
    ap.add_argument("--height", type=int, default=24)
    ap.add_argument("--now", type=int, help="epoch 'teraz' (testy: deterministyczny nastepny bieg)")
    ap.add_argument("--ascii", action="store_true", help="ramki ASCII (domyslnie: z locale)")
    ap.add_argument("--utf8", action="store_true", help="ramki UTF-8 niezaleznie od locale")
    ap.add_argument("--status", help="czytaj status --json z pliku")
    ap.add_argument("--jobs", help="czytaj list-jobs --json z pliku")
    ap.add_argument("--monitors", help="czytaj monitor --json z pliku")
    ap.add_argument("--progress", help="czytaj progress --json z pliku")
    ap.add_argument("--replicas", help="czytaj list-replicas --json z pliku")
    ap.add_argument("--stats", help="czytaj job-stats --json z pliku (czasy i wolumen jak w digescie)")
    ap.add_argument("--config", help="czytaj show-config --json z pliku (okno relacji)")
    ap.add_argument("--profiles", help="czytaj list-profiles --json --no-render z pliku (kreator)")
    ap.add_argument("--datasets-local", help="czytaj list-datasets --json (ten host) z pliku (kreator)")
    ap.add_argument("--datasets-remote", help="czytaj list-datasets HOST --json (peer) z pliku (kreator)")
    ap.add_argument("--check-source", help="czytaj check-source HOST --json z pliku (kreator: diagnoza hosta)")
    ap.add_argument("--zfs-tree", help="czytaj zfs-tree --json z pliku (F4 Kopie, lewy panel)")
    ap.add_argument("--zfs-snapshots", help="plik {\"by_dataset\": {DS: [migawki]}} zamiast zfs-snapshots --json (F4 Kopie)")
    ap.add_argument("--offline", action="store_true", help="nie uruchamiaj czasownikow; zrodla bez pliku sa puste")
    ap.add_argument("--host-ip", help="R3-1: IP hosta w pasku tytulu (testy/offline; na zywo liczony z trasy domyslnej)")
    ap.add_argument("--lang", choices=LANGS, help="window language (default: [gui] language in settings.ini, then en)")
    a = ap.parse_args(argv)
    # Okna whiptail (tui/*.sh) dziedziczą język przez środowisko.
    os.environ["ZFS_TUI_LANG"] = ui_lang(a.lang)
    load_lang(os.environ["ZFS_TUI_LANG"])
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    files = {"status": a.status, "jobs": a.jobs, "monitors": a.monitors, "progress": a.progress,
             "replicas": a.replicas, "stats": a.stats, "config": a.config, "profiles": a.profiles, "offline": a.offline,
             "datasets_local": a.datasets_local, "datasets_remote": a.datasets_remote, "check_source": a.check_source,
             "zfs_tree": a.zfs_tree, "zfs_snapshots": a.zfs_snapshots, "host_ip": a.host_ip}
    ch = Chars(want_ascii(a))
    # START BEZ PUSTEGO EKRANU (kampania 2026-10-26, pve9: ~20 s czarnego terminala): pierwszy
    # odczyt danych biegnie przed curses -- terminal mówi, co się dzieje.
    if not a.render_once and sys.stdout.isatty():
        sys.stdout.write(_(u"zfs-snapshot-all: wczytuję dane hosta (status, zadania, monitory)…") + "\n")
        sys.stdout.flush()
    ui = UI(repo, files, ch, a.now, a.exec_log)
    if a.render_once:
        ui.screen = a.screen
        if ui.screen == "szablony":
            ui.ensure_profiles()
        for k in [x for x in a.keys.split(",") if x]:
            name = live_key_name(ui, k)
            if name and ui.key(name, a.height) == "quit":
                break
            ui.run_pending()
        print("\n".join(ui.render(a.width, a.height).lines))
        return 0
    if not sys.stdout.isatty():
        sys.stderr.write(_("gui: to nie jest terminal -- uzyj --render-once, zeby zobaczyc ekran\n"))
        return 2
    curses_loop(ui)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
