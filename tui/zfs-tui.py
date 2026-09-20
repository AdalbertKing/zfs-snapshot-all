#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Piec okien nad zfs-snapshot-all: Relacje, Relacja, Transfery, Monitor, Nosniki.

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
    "OK":           ("aktualne",      2),
    "WARNING":      (u"spóźnione",    3),
    "CRITICAL":     ("stare",         1),
    "UNKNOWN":      ("nie odpowiada", 4),
    "BEZ MONITORA": ("bez monitora",  4),
}
VERDICT_ORDER = ["CRITICAL", "WARNING", "UNKNOWN", "BEZ MONITORA", "OK"]

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
    "available":    ("W SLOCIE", 3, u"dysk jest w slocie, pula NIEzaimportowana -- brama zaimportuje ją przy biegu"),
    "away":         ("W SEJFIE", 4, u"nośnika nie ma w maszynie; to stan oczekiwany między wymianami"),
    "wrong_medium": ("NIE TEN DYSK", 1, u"w slocie jest dysk, ale NIE TEN. Brama odmówi replikacji; wyjęcie złego nośnika to ruch człowieka przy maszynie"),
    "unknown":      ("?", 4, u"brama nośnika (zfs-media-gate.sh) nie odpowiedziała -- stan nieznany, nie 'brak'"),
}

# Slowa, ktore curses koloruje, gdziekolwiek stoja w linii. Sa wybrane tak,
# zeby nie byly podciagami zwyklego tekstu.
COLOR_WORDS = [
    ("nie odpowiada", 4), ("bez monitora", 4), ("aktualne", 2), (u"spóźnione", 3),
    (" stare", 1), ("NIE TEN DYSK", 1), ("W SLOCIE", 3), ("W SEJFIE", 4), (" TU ", 2),
    (u"BŁĄD", 1), ("w toku", 3), ("PAUZA", 3), ("NIEwdro", 1), ("nieczytelny", 1),
    (u"błąd źródła", 1), (" OK ", 2), (" OK", 2),
]

ARROWS_UTF = {"local": u"→ tutaj", "push": u"→ {peer}", "pull": u"← {peer}",
              "snapshot": "(migawka)", "prune": u"porządki"}
ARROWS_ASCII = {"local": "-> tutaj", "push": "-> {peer}", "pull": "<- {peer}",
                "snapshot": "(migawka)", "prune": "porzadki"}

# Wlasciciel, 2026-09-09: F2 to ZADANIA (co chodzi w cronie, z relacja i
# kierunkiem), a relacje dostaja WLASNE okno do zarzadzania (F3). Kierunek jest
# zapisany zawsze z tego hosta: lewa strona to my, prawa to peer.
SCREENS = [("zadania", "F2", "Zadania"), ("relacje", "F3", "Relacje"), ("transfery", "F4", "Transfery"),
           ("monitor", "F5", "Monitor"), ("nosniki", "F6", u"Nośniki")]


def home_dir():
    """$HOME przed expanduser: na hoscie to to samo, a testy moga go ustawic."""
    return os.environ.get("HOME") or os.path.expanduser("~")


def direction_of(host, peer, dirs):
    """`pve10>pve9` wysylam, `pve10<pve9` pobieram, `pve10<>pve9` w obie strony,
    `local` w obrebie hosta. Lewa strona to ZAWSZE ten host."""
    dirs = set(dirs)
    if "local" in dirs or not peer:
        return "local" if dirs else "?"
    if "pull" in dirs and "push" in dirs:
        return "%s<>%s" % (host, peer)
    if "pull" in dirs:
        return "%s<%s" % (host, peer)
    if "push" in dirs:
        return "%s>%s" % (host, peer)
    return "%s?%s" % (host, peer)


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


def fmt_when(epoch, now):
    """Czas po ludzku: dzis tylko godzina, inaczej data i godzina."""
    try:
        epoch = int(epoch)
    except (TypeError, ValueError):
        return "?"
    if epoch <= 0:
        return "?"
    t, n = time.localtime(epoch), time.localtime(now)
    if t[:3] == n[:3]:
        return time.strftime("%H:%M", t)
    return time.strftime("%Y-%m-%d %H:%M", t)


def fmt_full(epoch):
    try:
        epoch = int(epoch)
    except (TypeError, ValueError):
        return "?"
    if epoch <= 0:
        return "?"
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(epoch))


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
    cands = []
    for ln in j.get("cron_lines") or []:
        if not any(w in ln for w in want):
            continue
        m = re.search(r'zfs-job\.sh "([^"]+)"', ln)
        if not m:
            continue
        cands.append((scope and (('"%s"' % scope) in ln), m.group(1)))
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


def tier_unit(name, table=TIER_WORDS):
    for suf, w in table:
        if name.endswith(suf):
            return w
    return name


def cron_words(spec):
    """5 pol crona -> slowa: 'co godzinę (:01)', 'co dobę 01:11', 'co tydzień nd 02:21',
    'co miesiąc 1. dnia 03:31'; reszta wraca jak jest."""
    f = (spec or "").split()
    if len(f) != 5:
        return spec or "?"
    mi, ho, dom, mon, dow = f
    if not mi.isdigit():
        return spec
    if ho == "*" and dom == "*" and mon == "*" and dow == "*":
        return u"co godzinę (:%02d)" % int(mi)
    if not ho.isdigit():
        return spec
    hm = "%02d:%02d" % (int(ho), int(mi))
    if dom == "*" and mon == "*" and dow == "*":
        return u"co dobę %s" % hm
    if dom == "*" and mon == "*" and dow.isdigit():
        return u"co tydzień %s %s" % (DOW[int(dow) % 7], hm)
    if dom.isdigit() and mon == "*" and dow == "*":
        return u"co miesiąc %s. dnia %s" % (dom, hm)
    if dom.isdigit() and mon.isdigit():
        return u"co rok %s.%s %s" % (dom, mon, hm)
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
    mech = {"flat": u"N najnowszych", "gfs": u"drabina GFS", "age": u"wg wieku"}.get(p.get("mechanism", ""), p.get("mechanism") or "?")
    shape = {"one-family": u"jedna rodzina", "family-per-tier": u"rodzina na szczebel"}.get(p.get("shape", ""), p.get("shape") or "?")
    q = [tier_unit(t.get("name", ""), TIER_ADJ) for t in tiers if t.get("quiesce")]
    quiesce = (u"zamraża: %s" % ", ".join(q)) if q else u"bez zamrażania"
    mon = ""
    for t in tiers:
        if t.get("monitor_warn") or t.get("monitor_crit"):
            mon = u"monitor %s / %s" % (t.get("monitor_warn") or "?", t.get("monitor_crit") or "?")
            break
    return {"cadence": cad, "retention": u"trzyma " + (", ".join(ret) if ret else "?"), "mech": mech,
            "shape": shape, "quiesce": quiesce, "monitor": mon or u"bez progów"}


def run_verb(repo, args):
    """Uruchom czytelnik i oddaj sparsowany JSON, albo blad jako tekst.

    Status wyjscia NIE jest bledem sam z siebie: `monitor` zwraca 1/2/3 jako
    WERDYKT (to jego kontrakt), wiec liczy sie to, czy wyjscie da sie sparsowac."""
    cmd = [os.path.join(repo, "zfs-backup.sh")] + args
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        return None, u"nie udało się uruchomić %s: %s" % (" ".join(args), e)
    try:
        return json.loads(p.stdout.decode("utf-8", "replace")), None
    except ValueError:
        err = p.stderr.decode("utf-8", "replace").strip().splitlines()
        return None, (err[-1] if err else u"%s nie wydał poprawnego JSON-a" % args[0])


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
        self.read_at = 0

    def failed(self, key):
        return self.errors.get(key)


def collect(repo, files, only=None):
    """Czytaj z plikow (testy, podglad) albo z czasownikow. `only` = jedno zrodlo."""
    data = files.get("_data") or Data()
    files["_data"] = data
    plan = [("status", ["status", "--json"]), ("jobs", ["list-jobs", "--json"]),
            ("monitors", ["monitor", "--json"]), ("progress", ["progress", "--json"]),
            ("replicas", ["list-replicas", "--json"]), ("stats", ["job-stats", "--json"])]
    for key, args in plan:
        if only and key != only:
            continue
        if files.get(key):
            doc, err = load_file(files[key])
        elif files.get("offline"):
            doc, err = None, None
        else:
            doc, err = run_verb(repo, args)
        setattr(data, key, doc)
        if err:
            data.errors[key] = err
        else:
            data.errors.pop(key, None)
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
    data.profiles = (doc or {}).get("profiles", [])
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
        doc, err = None, u"tryb offline: list-datasets nie uruchomiono"
    else:
        args = ["list-datasets"] + ([host] if host else []) + (["--port=%s" % port] if port else []) + ["--json"]
        doc, err = run_verb(repo, args)
    data.datasets[key] = ((doc or {}).get("datasets", []), err)
    return data.datasets[key]


def load_check(repo, files, data, host, port=""):
    """check-source HOST --json: trzy fakty (SSH, ZFS, pakiet). Host, ktory
    odmawia, to fakt w JSON-ie, nie blad czytelnika."""
    key = "%s:%s" % (host, port)
    if key in data.checks:
        return data.checks[key]
    if files.get("check_source"):
        doc, err = load_file(files["check_source"])
    elif files.get("offline"):
        doc, err = None, u"tryb offline: check-source nie uruchomiono"
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
def family_of(job):
    """Transfer stempluje `prefix` (`automated_daily_`), prune dopasowuje
    `pattern` (`automated_daily`) -- ta sama rodzina. Jedna pisownia: bez konca."""
    return (job.get("pattern") or job.get("prefix", "")).rstrip("_")


def worst(verdicts):
    for v in VERDICT_ORDER:
        if v in verdicts:
            return v
    return "BEZ MONITORA"


def verdict_for_job(job, monitors):
    """Werdykt dla ZADANIA: po zakresie i rodzinie, a dla pobrania po etykiecie
    (monitor pilnuje lokalnego CELU, a zakres pull to zdalne ZRODLO)."""
    scope, fam = job.get("scope", ""), family_of(job)
    for m in monitors:
        if scope in m.get("datasets", []) and m.get("pattern", "") == fam:
            return m.get("verdict", "UNKNOWN"), m.get("reason", "")
    label = job.get("label", "")
    if label:
        for m in monitors:
            if m.get("label", "") == label and m.get("pattern", "") == fam:
                return m.get("verdict", "UNKNOWN"), m.get("reason", "")
    return "BEZ MONITORA", ""


def transfers_for(progress, label):
    jobs = [j for j in (progress or {}).get("jobs", []) if j.get("label", "") == label]
    jobs.sort(key=lambda j: int(j.get("started_epoch") or 0), reverse=True)
    return jobs


def transfer_word(t, now):
    st = t.get("state", "")
    if st == "running":
        upd = int(t.get("updated_epoch") or 0)
        if now - upd > 60:
            return "w toku", u"bez aktualizacji od %s" % fmt_dur(now - upd)
        return "w toku", ""
    return TRANSFER_STATES.get(st, (st or "?", 0))[0], ""


def state_word(rel):
    s = rel.get("state", "?")
    if rel.get("paused_local"):
        s += " PAUZA"
    return s


def next_step(rel):
    """Co dalej z relacja, ktora nie jest aktywna -- slowami CLI, bo to jest to,
    co operator wpisze. Maszyna stanow z `zfs-backup.sh` (usage):
    pending_enroll -> seeding -> seed_complete -> endpoint_verified -> active."""
    s = rel.get("state", "")
    return {"pending_enroll": "activate NAME", "seeding": "seed NAME",
            "seed_complete": "activate NAME", "endpoint_verified": "activate-client NAME",
            "removed": "--"}.get(s, "")


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
            out.insert(0, "zfs-backup.sh pause-client %s [--reason=TEKST]" % n)
        out.append("zfs-backup.sh set-bandwidth --peer=%s --bandwidth=RATE" % (rel.get("peer_host") or "HOST"))
        if rel.get("endpoint_diverged"):
            out.insert(0, "zfs-backup.sh verify-endpoint %s ; activate-client %s" % (n, n))
    elif s in ("pending_enroll", "seeding", "seed_complete", "endpoint_verified"):
        out.insert(0, "zfs-backup.sh activate %s   (wznawialne; dokończy cykl)" % n)
    if s != "removed":
        out.append("zfs-backup.sh remove-client %s" % n)
    return out


def ch_arrow(job):
    """Kierunek zadania bez rekordu, w UTF-8; tryb ASCII odogonkowuje strzalki
    razem z reszta ekranu (deaccent)."""
    return ARROWS_UTF.get(job.get("direction", ""), "?").format(peer=job.get("peer") or "?")


def rel_type(peer, dirs):
    """backup (jedna strona), synchro (obie), lokalna, other -- z linii crona."""
    dirs = set(dirs)
    if "pull" in dirs and "push" in dirs:
        return "synchro"
    if "pull" in dirs or "push" in dirs:
        return "backup"
    if "local" in dirs:
        return "lokalna"
    return "backup" if peer and not dirs else "other"


def rel_stats(data, jobs):
    """Suma po zadaniach wysylki: biegi, bledy, czas o/s/m, wolumen (job-stats)."""
    sends = [j for j in jobs if j.get("section_kind") == "dataset"]
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
            vword = VERDICTS.get(verdict, (verdict, 0))[0]
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
            last_txt = "brak zapisu"
        my_jobs = [j for j in jobs if j.get("label", "") == name]
        sends = [j for j in my_jobs if j.get("section_kind") == "dataset"]
        nxt_epoch = None
        for j in sends:
            e = cron_next(j.get("schedule", ""), now)
            if e and (nxt_epoch is None or e < nxt_epoch):
                nxt_epoch = e
        if rel.get("paused_local"):
            nxt = "-- pauza --"
        elif rel.get("state") != "active":
            nxt = next_step(rel).replace("NAME", name) or "?"
        elif nxt_epoch:
            nxt = fmt_when(nxt_epoch, now)
        elif not my_jobs:
            nxt = "brak linii w cronie"
        else:
            nxt = "?"
        host = (data.jobs or {}).get("host") or "?"
        dirs = [x.get("direction", "") for x in my_jobs if x.get("section_kind") == "dataset"]
        st = rel_stats(data, my_jobs)
        rows.append({
            "kind": "relation", "name": name, "rel": rel, "state": state_word(rel),
            "dir": direction_of(host, rel.get("peer_host") or "", dirs),
            "typ": rel_type(rel.get("peer_host"), dirs), "stats": st,
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
            "state": "bez rekordu %s" % ch_arrow(j),
            "verdict": v, "vword": VERDICTS.get(v, (v, 0))[0], "reasons": [reason] if reason else [],
            "monitors": [], "last": None, "last_txt": "--",
            "transfers": [], "jobs": [x for x in jobs if x.get("scope") == j.get("scope")],
            "next_epoch": nxt_epoch, "next": fmt_when(nxt_epoch, now) if nxt_epoch else "?",
            "job": j,
        })
    # BLOK, KTOREGO NIE DA SIE WYJASNIC, JEST WIERSZEM -- nie przypisem. Te linie
    # CHODZA; ukrycie ich to ta sama pusta ramka, przed ktora powstal list-jobs.
    for u in (data.jobs or {}).get("unreadable", []):
        rows.append({
            "kind": "unreadable", "name": "konto %s" % u.get("account", "?"), "rel": None, "dir": "?",
            "typ": "?", "gb": "?", "stats": None,
            "state": "nieczytelny", "verdict": "UNKNOWN", "vword": "nie odpowiada",
            "reasons": [u.get("error", "")], "monitors": [], "last": None,
            "last_txt": "%s linii w cronie" % u.get("lines_in_block", "?"), "transfers": [],
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
    return scope, other or "-"


def build_jobs(data, now):
    """Wiersze ekranu ZADANIA: jedno zadanie z crona (sekcja wysylki albo
    porzadkow), z relacja i kierunkiem. To jest to, co host naprawde robi."""
    rows = []
    monitors = (data.monitors or {}).get("monitors", [])
    host = (data.jobs or {}).get("host") or "?"
    for j in (data.jobs or {}).get("jobs", []):
        v, reason = verdict_for_job(j, monitors)
        tier = j.get("tier", "")
        if "__" in tier:
            tier = tier.rsplit("__", 1)[-1]
        kind = j.get("section_kind", "")
        ret = j.get("retain") or j.get("keep") or ""
        # Krotko i po ludzku: "wysylka hourly" (rodzina bez automated_),
        # "porzadki -D7" (co trzyma). Nazwa szczebla jest w panelu.
        fam = family_of(j).replace("automated_", "") or tier or "?"
        if kind == "prune":
            task = u"porządki " + (ret if ret else fam)
        else:
            task = u"wysyłka " + fam
        nxt = cron_next(j.get("schedule", ""), now)
        clabel = job_cron_label(j)
        srow, vol = job_stats_for(data, j, clabel)
        if data.failed("stats"):
            czas, gb = "?", "?"
        else:
            czas = times_cell(srow.get("last_s"), srow.get("avg_s"), srow.get("max_s")) if srow else "-"
            gb = hbytes_short(vol) if vol is not None else "-"
        rows.append({
            "kind": "job", "name": j.get("label") or "(bez rel.)", "rel": None,
            "clabel": clabel, "srow": srow, "vol": vol, "czas": czas, "gb": gb,
            "dir": direction_of(host, j.get("peer") or "", [j.get("direction", "")]),
            "task": task, "tier": tier, "scope": j.get("scope", ""),
            "schedule": j.get("schedule", ""), "verdict": v, "vword": VERDICTS.get(v, (v, 0))[0],
            "reasons": [reason] if reason else [], "next_epoch": nxt,
            "next": fmt_when(nxt, now) if nxt else "?", "job": j, "jobs": [j],
            "state": "", "last_txt": "", "monitors": [], "transfers": [], "last": None,
        })
    for u in (data.jobs or {}).get("unreadable", []):
        rows.append({
            "kind": "unreadable", "name": "konto %s" % u.get("account", "?"), "rel": None, "dir": "?",
            "task": "nieczytelny blok", "scope": u.get("config") or "(bez Source)", "schedule": "",
            "verdict": "UNKNOWN", "vword": "nie odpowiada", "reasons": [u.get("error", "")],
            "next_epoch": None, "next": "?", "job": None, "jobs": [], "u": u,
            "state": "nieczytelny", "last_txt": "%s linii w cronie" % u.get("lines_in_block", "?"),
            "monitors": [], "transfers": [], "last": None,
        })
    return rows


def render_zadania(data, rows, cursor, width, height, now, ch, message=""):
    scr = Screen()
    host = (data.jobs or {}).get("host") or "?"
    top = top_bar(data, width, now, ch.ascii, len(data.errors))
    if data.failed("jobs"):
        scr.lines = [top] + box(ch, u"Zadania na %s" % host, source_error_body(ch, "jobs", data, "list-jobs"), width)
    else:
        beside = width >= 120
        lbw = max(MIN_WIDTH, int(width * 0.6)) if beside else width
        inner = lbw - 4
        # Wlasciciel, 2026-09-11: kolumna Zakres znika z listy -- sciezka jest
        # zawsze dluga i nigdy sie nie miesci. Zrodlo i cel sa w panelu, w
        # calosci. Miejsce po niej dostana czasy z digestu (ostatni / sredni /
        # maks / GB), gdy czasownik je wystawi; do tego czasu Harmonogram jest
        # kolumna zawsze, a Kierunek i Zadanie nie sa ucinane.
        # Wlasciciel, 2026-09-11: w miejsce Zakresu -- czasy jak w mailu
        # (ostatni/sredni/maks, jedna komorka) i GB. Przy 80 kolumnach
        # Harmonogram zostaje w panelu, Kierunek dostaje to, co zostanie.
        nw = max(8, min(16, max([len(r["name"]) for r in rows] + [8])))
        tw = max(12, min(20, max([len(r["task"]) for r in rows] + [12])))
        cw, gw, vw = 11, 5, 13
        show_sched = width >= 100
        hw = 13 if show_sched else 0
        ncol = 7 if show_sched else 6
        dw = inner - (nw + tw + cw + gw + vw + hw + (ncol - 1))
        dmax = max([len(r["dir"]) for r in rows] + [8])
        if dw > dmax:
            tw = min(tw + (dw - dmax), 24)
            dw = inner - (nw + tw + cw + gw + vw + hw + (ncol - 1))
        dw = max(8, dw)
        cols = [fit("Relacja", nw), fit("Kierunek", dw), fit("Zadanie", tw)]
        if show_sched:
            cols.append(fit("Harmonogram", hw))
        cols += [fit(u"Czas o/ś/m", cw), fit("GB", gw), fit("Kopie", vw)]
        hdr = " ".join(cols)
        body = [hdr, ch.dash * inner]
        panel_h = 0 if beside else 9
        list_h = max(3, height - 2 - 2 - panel_h - 2)
        first = 0
        if cursor >= list_h:
            first = cursor - list_h + 1
        cur_y = None
        for i, r in enumerate(rows[first:first + list_h], start=first):
            if i == cursor:
                cur_y = len(body)
            cells = [fit(r["name"], nw, ch), fit(r["dir"], dw, ch), fit(r["task"], tw, ch)]
            if show_sched:
                cells.append(fit(r["schedule"], hw, ch))
            cells += [fit(r.get("czas", "-"), cw, ch), fit(r.get("gb", "-"), gw, ch), fit(r["vword"], vw, ch)]
            body.append(fit(" ".join(cells), inner))
        if not rows:
            body += [u"Zero zadań wyprowadzonych z zainstalowanych bloków.",
                     u"To NIE znaczy 'host nic nie robi' -- znaczy, że nie ma tu bloku",
                     u"zfs-backup-managed albo jego config jest nieczytelny."]
        if len(rows) > first + list_h:
            body.append(u"... jeszcze %d" % (len(rows) - first - list_h))
        while len(body) < list_h + 2:
            body.append("")
        n_rel = len({r["name"] for r in rows if r["kind"] == "job"})
        lb = box(ch, u"Zadania na %s (%s, %s)" % (host, plural(len([r for r in rows if r["kind"] == "job"]), "zadanie", "zadania", u"zadań"),
                                                    plural(n_rel, "relacja", "relacje", "relacji")), body, lbw,
                 footer=u"Enter szczegóły" if rows else "")
        if cur_y is not None:
            scr.cursor_y = 2 + cur_y
        panel = []
        if rows and 0 <= cursor < len(rows):
            r = rows[cursor]
            pw_ = (width - lbw) if beside else width
            pl = detail_kv(ch, rel_detail_pairs(r, data, now, ch), pw_ - 4)
            lim = (len(lb) - 2) if beside else (panel_h - 2)
            pl = pl[:lim]
            while len(pl) < lim:
                pl.append("")
            panel = box(ch, u"%s -- szczegóły" % (r["name"] if r["kind"] == "job" else r["name"]), pl, pw_, double=False)
        if beside and panel:
            scr.lines = [top] + side_by_side(lb, panel, width, ch)
        else:
            scr.lines = [top] + lb + panel
        scr.titles.update({1, len(lb)})
    scr.bars.add(0)
    if message:
        scr.lines.append(fit(" " + message, width))
    while len(scr.lines) < height - 1:
        scr.lines.append(fit("", width))
    scr.lines = scr.lines[:height - 1]
    scr.lines.append(key_bar("zadania", width))
    scr.bars.add(len(scr.lines) - 1)
    return scr


def summarize(rows):
    """Jedno zdanie o calym hoscie."""
    live = [r for r in rows if r["kind"] != "relation" or r["rel"].get("state") != "removed"]
    if not live:
        return "brak relacji"
    counts = {}
    for r in live:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    n = plural(len(live), "relacja", "relacje", "relacji")
    if list(counts) == ["OK"]:
        return "%s, wszystkie kopie aktualne" % n
    parts = ["%d %s" % (counts[v], VERDICTS[v][0]) for v in VERDICT_ORDER if counts.get(v)]
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


def top_bar(data, width, now, ascii_only, err_count):
    host = (data.jobs or {}).get("host") or "(host?)"
    jobs = (data.jobs or {}).get("jobs", [])
    accounts = sorted({j.get("account", "") for j in jobs} |
                      {u.get("account", "") for u in (data.jobs or {}).get("unreadable", [])})
    acct = ", ".join(a for a in accounts if a) or "(brak bloku)"
    left = " zfs-snapshot-all"
    mid = "%s | konto %s%s" % (host, acct, u"   ! bez odpowiedzi: %d" % err_count if err_count else "")
    right = u"odczyt %s " % time.strftime("%H:%M:%S", time.localtime(data.read_at or now))
    gap = width - len(left) - len(mid) - len(right)
    if gap < 2:
        # Ciasno: nazwa programu odpada, fakty (host, konto, blad) zostaja.
        line = fit(" " + mid + "  " + right, width)
    else:
        line = left + " " * (gap // 2) + mid + " " * (gap - gap // 2) + right
    return fit(line, width)


def key_bar(active, width, extra=""):
    """Listwa F-klawiszy. Przy 80 kolumnach miesci sie DOKLADNIE, wiec kazde
    slowo tu jest policzone; przy szerszym terminalu dochodzi odswiezenie."""
    parts = ["F1 Pomoc"]
    for key, fk, label in SCREENS:
        parts.append(("[%s %s]" if key == active else "%s %s") % (fk, label))
    parts.append(u"F10 Wyjście")
    line = " " + " ".join(parts)
    if len(line) > width:
        line = line[1:]
    if extra and width >= len(line) + len(extra) + 1:
        line += " " + extra
    if width >= len(line) + 12:
        line += u" F9 Odśwież"
    return fit(line, width)


def source_error_body(ch, key, data, verb):
    """Zepsute zrodlo to komunikat, nie pusta tabela (kontrola ujemna etapu B)."""
    return [u"błąd źródła: %s --json nie odpowiedział poprawnym JSON-em." % verb,
            "", fit(u"  %s" % data.errors[key], 200),
            "", u"Ten ekran nie ma z czego rysować. Uruchom czasownik ręcznie, żeby zobaczyć pełny błąd."]


def detail_kv(ch, pairs, width):
    """Panel klucz: wartosc; wartosc lamana, klucz tylko przy pierwszej linii."""
    kw = max([len(k) for k, _ in pairs] + [8])
    out = []
    for k, v in pairs:
        chunks = wrap(u"%s" % v, max(10, width - kw - 2)) or [""]
        for i, c in enumerate(chunks):
            out.append("%s %s" % (fit(k if i == 0 else "", kw), c))
    return out


def side_by_side(left, right, width, ch):
    """Panel obok listy od ~120 kolumn: lista dostaje 60%, panel reszte."""
    lw = max(MIN_WIDTH, int(width * 0.6))
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
                (u"powód", row["reasons"][0] if row["reasons"] else "?")]
    if row["kind"] == "job":
        j = row["job"]
        src, dst = job_src_dst(j)
        # Kolejnosc = to, po co wlasciciel otwiera panel (2026-09-11): zrodlo,
        # cel, potem czasy i wolumen jak w mailu; reszta nizej (przy 80
        # kolumnach panel ma 7 linii, calosc jest w oknie po Enter).
        pairs = [(u"źródło", src), ("cel", dst)]
        st = data.stats or {}
        win = st.get("window_days", "?")
        srow = row.get("srow")
        if data.failed("stats"):
            pairs.append(("czas", u"job-stats --json nie odpowiedział -- czasy i wolumen nieznane"))
        elif srow:
            pairs.append(("czas", u"ostatni %s / średni %s / maks %s   (jak w mailu)" % (
                hsecs(srow.get("last_s")), hsecs(srow.get("avg_s")), hsecs(srow.get("max_s")))))
        else:
            pairs.append(("czas", u"brak biegów tego zadania w dzienniku w oknie %s dni%s" % (
                win, "" if row.get("clabel") else u" (nie ma jego linii w cronie)")))
        if row.get("vol") is not None and not data.failed("stats"):
            pairs.append(("wolumen", u"%s zapisane w migawkach %s w oknie %s dni" % (
                hbytes_short(row["vol"]), family_of(j) or "?", win)))
        if srow and not data.failed("stats"):
            pairs.append(("biegi", u"%s w oknie %s dni, błędów %s, ostatni %s rc=%s" % (
                srow.get("runs", "?"), win, srow.get("failures", 0), srow.get("last_at", "?"), srow.get("last_rc", "?"))))
        pairs += [("kopie", row["vword"] + ("  " + row["reasons"][0].splitlines()[0] if row["reasons"] else "")),
                  ("harmonogram", "%s  (%s)" % (j.get("schedule", "?"), row["next"])),
                  ("szczebel", (row.get("tier") or j.get("tier") or "?") + ("  (sekcja %s)" % j.get("section_kind", "?"))),
                  ("rodzina", family_of(j) or "?"),
                  ("trzyma", (j.get("retain") or j.get("keep") or "-") + ("  drabina GFS" if j.get("gfs") else "")),
                  ("kierunek", "%s   %s" % (row.get("dir", "?"), ch.arrows.get(j.get("direction", ""), "?").format(peer=j.get("peer") or "?"))),
                  ("konto", "%s   config %s" % (j.get("account", "?"), j.get("config", "?")))]
        return pairs
    srcs = rel.get("sources", [])
    pairs = [(u"Źródła (%d)" % len(srcs), ",  ".join(srcs) or "?")]
    tgt = rel.get("client_target", "?")
    md = rel.get("managed_datasets", [])
    pairs.append(("Cel", tgt + ("   -> %s" % ", ".join(md) if md else "")))
    prof = rel.get("profile") or "?"
    if rel.get("source_profile"):
        prof += u"   źródło: %s" % rel["source_profile"]
    rec = rel.get("recursion") or ""
    pairs.append(("Polityka", prof + ("   rekursja %s" % rec if rec else "")
                  + ("   pasywna" if rel.get("passive") == "1" else "")
                  + (u"   łącze %s" % rel["bandwidth"] if rel.get("bandwidth") else "")))
    last = row["last"]
    if last:
        w, note = transfer_word(last, now)
        st, fin = int(last.get("started_epoch") or 0), int(last.get("finished_epoch") or 0)
        mode = {"incremental": "przyrostowy", "full": u"pełny"}.get(last.get("mode", ""), last.get("mode", ""))
        base = last.get("base", "")
        txt = "%s  %s" % (w, fmt_full(fin if fin else st))
        if fin and st:
            txt += "  %s" % fmt_dur(fin - st)
        txt += "  %s" % mode
        if note:
            txt += "  " + note
        pairs.append(("Ostatni bieg", txt))
    else:
        pairs.append(("Ostatni bieg", u"brak zapisu w historii -- to NIE znaczy 'bez awarii', tylko 'nie wiadomo'"))
    if row["next_epoch"]:
        pairs.append((u"Następny", "%s  (wg crontaba, %s)" % (
            fmt_full(row["next_epoch"]), ", ".join(sorted({j.get("schedule", "") for j in row["jobs"] if j.get("section_kind") == "dataset"})))))
    else:
        pairs.append((u"Następny", row["next"]))
    mon = row["vword"]
    if row["monitors"]:
        m0 = row["monitors"][0]
        mon += "   progi %s / %s" % (m0.get("warn") or "?", m0.get("crit") or "?")
    if row["reasons"]:
        # Jedna linia w panelu; pelny tekst monitora jest w oknie (Enter).
        mon += "   " + row["reasons"][0].splitlines()[0]
    elif row["verdict"] == "BEZ MONITORA" and rel.get("state") == "active":
        mon += u"   nikt nie sprawdza, czy kopia dalej się robi"
    warns = []
    if rel.get("endpoint_diverged"):
        warns.append(u"cron idzie przez %s, zapisany %s -- NIEwdrożony (verify-endpoint, activate-client)"
                     % (rel.get("installed_endpoint") or "?", rel.get("active_endpoint") or "?"))
    if rel.get("paused_local"):
        warns.append(u"relacja wstrzymana (pause-client); starzenie się kopii jest tu oczekiwane")
    if rel.get("state") != "active" and rel.get("state") != "removed":
        warns.append(u"relacja nie jest aktywna: stan %s, następny krok: %s" % (rel.get("state"), next_step(rel).replace("NAME", row["name"])))
    if rel.get("state") == "removed":
        warns.append(u"rekord usunięty %s; kopie na dysku nie zostały ruszone" % (rel.get("removed_at") or "?"))
    for m in row["monitors"]:
        if m.get("engine_path_differs"):
            warns.append(u"cron woła inny plik silnika (%s) niż ten, który tu policzono" % m.get("engine_in_cron"))
    if warns:
        pairs.append(("Uwaga", "  |  ".join(warns)))
    pairs.append(("Kopie", mon))
    return pairs


def rel_pairs(row, data, now, ch):
    """Pary zrodlo -> cel podswietlonej relacji (dolny panel F3).

    Wlasciciel, 2026-09-11: relacji jest malo, datasetow w relacji moze byc
    duzo -- pary maja swoj panel. Prawda pochodzi z linii crona (list-jobs,
    te same wiersze co F2); relacja bez crona (pending, seeding) dostaje pary
    policzone z rekordu i JEST TO NAPISANE w tytule panelu."""
    monitors = (data.monitors or {}).get("monitors", [])
    out = []
    jobs = [j for j in row.get("jobs", []) if j.get("section_kind") == "dataset"]
    if jobs:
        for j in jobs:
            src, dst = job_src_dst(j)
            v, _reason = verdict_for_job(j, monitors)
            srow, vol = job_stats_for(data, j, job_cron_label(j))
            if data.failed("stats"):
                czas, gb = "?", "?"
            else:
                czas = times_cell(srow.get("last_s"), srow.get("avg_s"), srow.get("max_s")) if srow else "-"
                gb = hbytes_short(vol) if vol is not None else "-"
            out.append({"src": src, "dst": dst, "job": j, "vword": VERDICTS.get(v, (v, 0))[0], "czas": czas, "gb": gb})
        return out, "wg crona"
    if row.get("kind") != "relation":
        return out, ("blok nieczytelny" if row.get("kind") == "unreadable" else "wg crona")
    rel = row.get("rel") or {}
    peer = rel.get("peer_host") or "?"
    tgt = rel.get("client_target") or "?"
    for src in rel.get("sources", []):
        bare = src.split(":", 1)[1] if ":" in src else src
        out.append({"src": src if ":" in src else "%s:%s" % (peer, src), "dst": "%s/%s/%s" % (tgt, peer, bare),
                    "job": None, "vword": "--", "czas": "-", "gb": "-"})
    return out, "wg rekordu, nie crona"


def rel_panel_pairs(row, data, now, ch):
    """Prawy panel F3 jako TABELA: jeden fakt w wierszu, klucz | wartosc.
    Wlasciciel, 2026-09-12: "Popatrz na to jak czytajacy czlowiek. Kolumny i
    wiersze" -- zlepione zdania w jednej wartosci sa nieczytelne. Zrodla i cel
    sa na dole, w parach."""
    if row["kind"] != "relation":
        return rel_detail_pairs(row, data, now, ch)
    rel = row["rel"]
    pairs = []
    st = state_word(rel)
    if rel.get("peer_pair_state") not in ("", "NOT_ASKED", None):
        st += "   (peer: %s)" % rel["peer_pair_state"]
    pairs.append(("Stan", st))
    warns = []
    if rel.get("endpoint_diverged"):
        warns.append(u"cron idzie przez %s, zapisany %s -- NIEwdrożony (verify-endpoint, activate-client)"
                     % (rel.get("installed_endpoint") or "?", rel.get("active_endpoint") or "?"))
    if rel.get("paused_local"):
        warns.append(u"relacja wstrzymana (pause-client); starzenie się kopii jest tu oczekiwane")
    if rel.get("state") != "active" and rel.get("state") != "removed":
        warns.append(u"relacja nie jest aktywna: stan %s, następny krok: %s" % (rel.get("state"), next_step(rel).replace("NAME", row["name"])))
    if rel.get("state") == "removed":
        warns.append(u"rekord usunięty %s; kopie na dysku nie zostały ruszone" % (rel.get("removed_at") or "?"))
    for m in row["monitors"]:
        if m.get("engine_path_differs"):
            warns.append(u"cron woła inny plik silnika (%s) niż ten, który tu policzono" % m.get("engine_in_cron"))
    for w_ in warns:
        # OSTRZEZENIE TUZ POD STANEM: panel bywa niski i ucina koniec.
        pairs.append(("Uwaga", w_))
    pairs.append(("Typ", row.get("typ") or "?"))
    pairs.append(("Kierunek", row.get("dir") or "?"))
    pairs.append(("Peer", rel.get("peer_host") or "?"))
    pairs.append(("Endpoint", (rel.get("active_endpoint") or "?")
                  + (("   w cronie: %s" % rel["installed_endpoint"]) if rel.get("installed_endpoint") and rel.get("installed_endpoint") != rel.get("active_endpoint") else "")))
    accts = sorted({j.get("account", "") for j in row["jobs"] if j.get("account")})
    pairs.append(("Konto", rel.get("local_user") or ", ".join(accts) or "?"))
    pairs.append(("Profil", (rel.get("profile") or "?") + ((u"   u źródła: %s" % rel["source_profile"]) if rel.get("source_profile") else "")))
    if rel.get("recursion"):
        pairs.append(("Rekursja", rel["recursion"]))
    if rel.get("passive") == "1":
        pairs.append(("Tryb", "pasywny"))
    if rel.get("bandwidth"):
        pairs.append((u"Łącze", rel["bandwidth"]))
    sends = [j for j in row["jobs"] if j.get("section_kind") == "dataset"]
    prunes = [j for j in row["jobs"] if j.get("section_kind") == "prune"]
    if sends:
        scheds = sorted({j.get("schedule", "") for j in sends if j.get("schedule")})
        fams = sorted({family_of(j) for j in sends if family_of(j)})
        pairs.append((u"Wysyłka", "%s   rodzina %s" % (", ".join(scheds) or "?", ", ".join(fams) or "?")))
    if prunes:
        here = [j for j in prunes if j.get("direction") == "prune"]
        there = [j for j in prunes if j.get("direction") != "prune"]

        def line_of(js):
            ret = " ".join(x for x in [(j.get("retain") or j.get("keep") or "") for j in js] if x) or "?"
            sch = sorted({j.get("schedule", "") for j in js if j.get("schedule")})
            return "%s   trzyma %s%s" % (", ".join(sch) or "?", ret, "   drabina GFS" if any(j.get("gfs") for j in js) else "")
        pairs.append((u"Porządki", line_of(here or prunes)))
        if here and there:
            pairs.append((u"U źródła", line_of(there)))
    last = row["last"]
    if last:
        w, note = transfer_word(last, now)
        st_, fin = int(last.get("started_epoch") or 0), int(last.get("finished_epoch") or 0)
        mode = {"incremental": "przyrostowy", "full": u"pełny"}.get(last.get("mode", ""), last.get("mode", ""))
        txt = "%s   %s" % (w, fmt_full(fin if fin else st_))
        if fin and st_:
            txt += "   %s" % fmt_dur(fin - st_)
        txt += "   %s" % mode
        if note:
            txt += "   " + note
        pairs.append(("Ostatni", txt))
    else:
        pairs.append(("Ostatni", u"brak zapisu w historii (nie wiadomo, nie 'OK')"))
    if row["next_epoch"]:
        pairs.append((u"Następny", "%s   (wg crontaba)" % fmt_full(row["next_epoch"])))
    else:
        pairs.append((u"Następny", row["next"]))
    mon = row["vword"]
    if row["monitors"]:
        m0 = row["monitors"][0]
        mon += "   progi %s / %s" % (m0.get("warn") or "?", m0.get("crit") or "?")
    if row["reasons"]:
        mon += "   " + row["reasons"][0].splitlines()[0]
    elif row["verdict"] == "BEZ MONITORA" and rel.get("state") == "active":
        mon += u"   nikt nie sprawdza, czy kopia dalej się robi"
    pairs.append(("Kopie", mon))
    # STATYSTYKA Z OKNA DIGESTU (job-stats): trzy wiersze, nie jedno zdanie.
    stt = row.get("stats") or {}
    days = (data.stats or {}).get("window_days") or 7
    if data.failed("stats"):
        pairs.append(("Biegi %dd" % days, u"? -- job-stats nie odpowiedział"))
    elif sends:
        if stt.get("runs"):
            pairs.append(("Biegi %dd" % days, "%d" % stt["runs"] + (u"   błędy %d" % stt["fails"] if stt["fails"] else "")))
            pairs.append((u"Czas o/ś/m", times_cell(stt["last"], stt["avg"], stt["max"])))
        else:
            pairs.append(("Biegi %dd" % days, u"brak w dziennikach z tego okna"))
        pairs.append(("Wolumen", row.get("gb") or "-"))
    npairs, _how = rel_pairs(row, data, now, ch)
    pairs.append(("Datasety", u"%s   lądowisk %d" % (plural(len(npairs), "para", "pary", "par"), len(rel.get("managed_datasets") or []))))
    for key, fld in (("Utworzona", "created_at"), ("Zasiew", "seed_completed_at"), ("Aktywowana", "activated_at"), (u"Usunięta", "removed_at")):
        if rel.get(fld):
            pairs.append((key, rel[fld]))
    return pairs


def render_relacje(data, rows, cursor, width, height, now, ch, message="", focus="list", pair_cursor=0):
    """F3 w trzech panelach (szkic wlasciciela, 2026-09-11): u gory lista
    relacji (lewo) i szczegoly (prawo), na dole pary zrodlo -> cel."""
    scr = Screen()
    host = (data.jobs or {}).get("host") or (data.status or {}).get("host") or "?"
    if data.failed("status"):
        body = source_error_body(ch, "status", data, "status")
        scr.lines = [top_bar(data, width, now, ch.ascii, len(data.errors))] + box(ch, "Relacje na kolektorze %s" % host, body, width)
        scr.bars.add(0)
        while len(scr.lines) < height - 1:
            scr.lines.append(fit("", width))
        scr.lines = scr.lines[:height - 1]
        scr.lines.append(key_bar("relacje", width))
        scr.bars.add(len(scr.lines) - 1)
        return scr
    live = [r for r in rows if not (r["kind"] == "relation" and r["rel"].get("state") == "removed")]
    title = "Relacje na kolektorze %s (%d)" % (host, len(live))
    r = rows[cursor] if rows and 0 <= cursor < len(rows) else None
    pairs, how = rel_pairs(r, data, now, ch) if r is not None else ([], "")
    binner = width - 4
    wide = width >= 100
    # Para na jednej linii, gdy sie miesci; inaczej zrodlo i pod nim cel.
    tail_w = (13 + 1 + 11 + 1 + 5) if wide else 0
    plines_of = []
    for pr in pairs:
        one = u"%s %s %s" % (pr["src"], ch.right, pr["dst"])
        if len(one) + (tail_w + 1 if wide else 0) <= binner:
            plines_of.append([one])
        else:
            plines_of.append([pr["src"], u"  %s %s" % (ch.right, pr["dst"])])
    # PODZIAL (wlasciciel 2026-09-12: "co gdy datasetow bedzie dwadziescia?"):
    # gora dostaje tyle, ile potrzebuje lista i panel szczegolow, dol -- CALA
    # reszte ekranu. Na malym terminalu dol ma nie mniej niz 4 linie.
    avail = height - 2                      # pasek tytulu + listwa klawiszy
    lbw = max(48, int(width * 0.6))
    pw = width - lbw
    panel_rows = rel_panel_pairs(rows[cursor], data, now, ch) if r is not None else []
    panel_need = len(detail_kv(ch, panel_rows, pw - 4)) + 2
    # Gdy par jest wiecej, niz zostaje miejsca, PARY WYGRYWAJA z panelem
    # (panel ucina koniec, calosc jest w oknie Enter); lista nigdy nie traci.
    need_pairs = sum(len(x) for x in plines_of) + 2
    top_h = max(len(rows) + 4, 7, min(panel_need, avail - need_pairs))
    top_h = min(top_h, avail - 4)
    bot_h = avail - top_h
    inner = lbw - 4
    # Kolumny: Relacja, Kierunek, Stan zawsze; Kopie i Nastepny, gdy sie mieszcza.
    nw = max(8, min(24, max([len(r["name"]) for r in rows] + [8])))
    dw = max(8, min(24, max([len(r.get("dir", "")) for r in rows] + [8])))
    sw = max(7, min(20, max([len(r["state"]) for r in rows] + [7])))
    tw = max(7, min(8, max([len(r_.get("typ", "")) for r_ in rows] + [7])))
    cols = [("Relacja", nw, "name"), ("Kierunek", dw, "dir"), ("Stan", sw, "state")]
    used = nw + dw + sw + 2
    if inner - used >= tw + 1:
        cols.insert(2, ("Typ", tw, "typ"))
        used += tw + 1
    if inner - used >= 14:
        cols.append(("Kopie", 13, "vword"))
        used += 14
    if inner - used >= 7:
        cols.append(("GB", 6, "gb"))
        used += 7
    if inner - used >= 9:
        cols.append((u"Następny", inner - used - 1, "next"))
        used = inner
    else:
        # Stan dostaje reszte, zeby wiersz byl pelny.
        t_, w_, k_ = cols[-1]
        cols[-1] = (t_, w_ + (inner - used), k_)
    hdr = " ".join(fit(t, w) for t, w, _k in cols)
    body = [hdr, ch.dash * inner]
    if not rows:
        body += [u"Zero relacji i zero zadań na tym hoście.",
                 u"To NIE znaczy 'host nic nie robi' -- znaczy, że nie ma tu",
                 u"rekordu relacji ani bloku zfs-backup-managed w crontabie."]
    list_h = max(3, top_h - 4)
    first = 0
    if cursor >= list_h:
        first = cursor - list_h + 1
    cur_y = None
    for i, rr in enumerate(rows[first:first + list_h], start=first):
        cells = []
        for _t, w, k in cols:
            v = rr.get(k, "") or ""
            cells.append(fit_left(v, w, ch) if (k == "name" and rr["kind"] == "job") else fit(v, w, ch))
        if i == cursor:
            cur_y = len(body)
        body.append(" ".join(cells))
    if len(rows) > first + list_h:
        body.append(fit(u"... jeszcze %d" % (len(rows) - first - list_h), inner))
    while len(body) < list_h + 2:
        body.append("")
    body = body[:list_h + 2]
    listbox = box(ch, title, body, lbw, footer=(u"Tab: pary" if rows else ""))
    if cur_y is not None and focus == "list":
        scr.cursor_y = 1 + 1 + cur_y   # pasek tytulu + gorna krawedz
    scr.titles.add(1)
    scr.titles.add(len(listbox))
    # PRAWY PANEL: szczegoly bez zrodla i celu (te sa na dole).
    pl = []
    ptitle = ""
    if r is not None:
        ptitle = u"%s -- szczegóły" % r["name"]
        pl = detail_kv(ch, panel_rows, pw - 4)
    pl = pl[:len(listbox) - 2]
    while len(pl) < len(listbox) - 2:
        pl.append("")
    panel = box(ch, ptitle, pl, pw, double=False)
    top = [fit(l, lbw) + fit(p_, pw) for l, p_ in zip(listbox, panel)]
    # DOLNY PANEL: pary zrodlo -> cel, jedna pod druga; od 100 kolumn z kopiami,
    # czasem i GB per para (te same liczby co F2).
    plines = []
    ph = max(1, bot_h - 2)
    # Przewijanie parami: pierwsza widoczna para tak, zeby kursor byl w oknie.
    pfirst = 0
    while pfirst < pair_cursor and sum(len(x) for x in plines_of[pfirst:pair_cursor + 1]) > ph:
        pfirst += 1
    pcur_y = None
    if r is not None and not pairs:
        plines.append(u"brak par: rekord nie nazywa żadnego źródła, a w cronie nie ma linii wysyłki tej relacji")
    shown = 0
    for i in range(pfirst, len(pairs)):
        pr, ls = pairs[i], plines_of[i]
        if len(plines) + len(ls) > ph:
            break
        if i == pair_cursor and focus == "pairs":
            pcur_y = len(plines)
        for n_, l in enumerate(ls):
            if wide and n_ == len(ls) - 1:
                tail = "%s %s %s" % (fit(pr["vword"], 13, ch), fit(pr["czas"], 11, ch), fit(pr["gb"], 5, ch))
                plines.append(fit(l, binner - len(tail) - 1, ch) + " " + tail)
            else:
                plines.append(fit(l, binner, ch))
        shown += 1
    if pfirst + shown < len(pairs):
        more = u"... jeszcze %d" % (len(pairs) - pfirst - shown)
        if len(plines) < ph:
            plines.append(more)
        else:
            plines[-1] = fit(more, binner)
    plines = plines[:ph]
    while len(plines) < ph:
        plines.append("")
    btitle = (u"Datasety relacji %s: %s, %s" % (r["name"], plural(len(pairs), "para", "pary", "par"), how)) if r is not None else "Datasety"
    if wide and pairs:
        btitle += u"   [źródło %s cel | Kopie | Czas o/ś/m | GB]" % ch.right
    bfoot = (u"Enter szczegóły  F4 pauza  Del usuń  F7 eksport  F8 import  Ins nowa  Tab pary" if width >= 100
             else u"Enter F4:pauza Del F7:eksport F8:import Ins Tab") if rows else ""
    if focus == "pairs":
        bfoot = u"Enter = to zadanie na F2   Tab wraca do relacji   strzałki"
    bottom = box(ch, btitle, plines, width, footer=bfoot)
    if pcur_y is not None:
        scr.cursor_y = 1 + len(top) + 1 + pcur_y
    scr.lines = [top_bar(data, width, now, ch.ascii, len(data.errors))] + top + bottom
    scr.titles.add(len(top) + 1)
    scr.bars.add(0)
    while len(scr.lines) < height - 1:
        scr.lines.append(fit("", width))
    scr.lines = scr.lines[:height - 1]
    scr.lines.append(key_bar("relacje", width))
    scr.bars.add(len(scr.lines) - 1)
    return scr


# --- Relacja (okno na wierzchu) --------------------------------------------
def relation_window_lines(row, data, now, ch, width, repo=None, files=None):
    """Tresc okna relacji, jako linie; okno przewija sie, wiec bez limitu."""
    w = width - 4
    out = []
    H = lambda t: out.extend(["", (ch.dash * 2 + " " + t + " " + ch.dash * max(0, w - len(t) - 4))[:w]])
    if row["kind"] != "relation":
        for k, v in rel_detail_pairs(row, data, now, ch):
            out.extend(detail_kv(ch, [(k, v)], w))
        j = row.get("job")
        if j:
            H("W CRONIE")
            out.extend(cron_lines_of(row["jobs"], w, ch))
        return out
    rel = row["rel"]
    n = row["name"]
    out.extend(detail_kv(ch, [
        ("Stan", state_word(rel) + ("   (peer: %s)" % rel["peer_pair_state"] if rel.get("peer_pair_state") not in ("", "NOT_ASKED", None) else "")),
        ("Peer", "%s   endpoint %s%s" % (rel.get("peer_host") or "?", rel.get("active_endpoint") or "?",
                                          ("   w cronie: %s" % rel.get("installed_endpoint")) if rel.get("installed_endpoint") and rel.get("installed_endpoint") != rel.get("active_endpoint") else "")),
        ("Historia", "  ".join(x for x in [
            "utworzona %s" % rel["created_at"] if rel.get("created_at") else "",
            "zasiew %s" % rel["seed_completed_at"] if rel.get("seed_completed_at") else "",
            "aktywowana %s" % rel["activated_at"] if rel.get("activated_at") else "",
            u"usunięta %s" % rel["removed_at"] if rel.get("removed_at") else ""]) or "?"),
    ], w))
    H("ZAKRES")
    pairs = [(u"Źródła (%d)" % len(rel.get("sources", [])), ",  ".join(rel.get("sources", [])) or "?"),
             ("Cel", rel.get("client_target") or "?")]
    if rel.get("managed_datasets"):
        pairs.append((u"Lądowiska", ",  ".join(rel["managed_datasets"])))
    if rel.get("managed_prune_scope"):
        pairs.append((u"Porządki", ",  ".join(rel["managed_prune_scope"])))
    if rel.get("local_user"):
        pairs.append(("Konto", rel["local_user"]))
    out.extend(detail_kv(ch, pairs, w))
    H("POLITYKA")
    pairs = [("Profil", rel.get("profile") or "?")]
    if rel.get("source_profile"):
        pairs.append((u"Profil źródła", rel["source_profile"]))
    if rel.get("recursion"):
        pairs.append(("Rekursja", rel["recursion"]))
    if rel.get("passive") == "1":
        pairs.append(("Tryb", "pasywny"))
    if rel.get("bandwidth"):
        pairs.append((u"Łącze", rel["bandwidth"]))
    out.extend(detail_kv(ch, pairs, w))
    cfg = None
    if data is not None and repo is not None and files is not None:
        cfg, cerr = load_config(repo, files, data, n)
        if cerr:
            out.append(u"  show-config: błąd źródła: %s" % cerr)
    if cfg:
        tmpl = {t.get("name"): t.get("fields", {}) for t in cfg.get("templates", [])}
        for s in cfg.get("sections", []):
            f = s.get("fields", {})
            used = [x for x in (f.get("use_template") or "").split(",") if x]
            if s.get("kind") == "dataset":
                sched = f.get("send_schedule") or (tmpl.get(used[0], {}).get("send_schedule") if used else "") or "?"
                pref = f.get("prefix") or (tmpl.get(used[0], {}).get("prefix") if used else "") or "?"
                out.extend(detail_kv(ch, [(u"wysyłka", u"%s   co: %s   stempel %s" % (s.get("name"), sched, pref))], w))
            else:
                ret = []
                for u in used:
                    r = tmpl.get(u, {}).get("retain") or tmpl.get(u, {}).get("keep")
                    if r:
                        ret.append(r)
                if f.get("retain"):
                    ret.append(f["retain"])
                sched = f.get("prune_schedule") or (tmpl.get(used[0], {}).get("prune_schedule") if used else "") or "?"
                out.extend(detail_kv(ch, [(u"porządki", u"%s   trzyma %s   co: %s%s" % (
                    s.get("name"), " ".join(ret) or "?", sched,
                    "   drabina GFS" if f.get("gfs") == "yes" else ""))], w))
    H("KOPIE (monitor)")
    if row["monitors"]:
        for m in row["monitors"]:
            vw = VERDICTS.get(m.get("verdict", ""), (m.get("verdict", "?"), 0))[0]
            out.extend(detail_kv(ch, [(vw, "%s   rodzina %s   progi %s / %s   co %s" % (
                ", ".join(m.get("datasets", [])), m.get("pattern") or "?", m.get("warn") or "?",
                m.get("crit") or "?", m.get("schedule") or "?"))], w))
            if m.get("reason"):
                for ln in m["reason"].splitlines():
                    out.extend(wrap("    " + ln, w))
            if m.get("paused_local"):
                out.append(u"    linia wstrzymana (pauza)")
    else:
        out.append(u"  bez monitora -- nikt nie sprawdza, czy kopia dalej się robi")
    H("TRANSFERY (ostatnie)")
    if row["transfers"]:
        for t in row["transfers"][:6]:
            wd, note = transfer_word(t, now)
            st, fin = int(t.get("started_epoch") or 0), int(t.get("finished_epoch") or 0)
            out.append(fit("  %-6s %s  %s  %s  %s" % (
                wd, fmt_full(fin or st), fmt_dur(fin - st) if fin and st else "",
                {"incremental": "przyrostowy", "full": u"pełny"}.get(t.get("mode", ""), t.get("mode", "")),
                fit_left(t.get("dataset", ""), max(10, w - 50), ch)), w))
    else:
        out.append("  brak zapisu w historii")
    H("W CRONIE")
    if row["jobs"]:
        out.extend(cron_lines_of(row["jobs"], w, ch))
    else:
        out.append(u"  brak linii w cronie dla tej etykiety" + ("" if rel.get("state") == "active" else u" (relacja nie jest aktywna)"))
    H("KOMENDY CLI DLA TEGO STANU (nazwane, nie wykonywane)")
    for v in verbs_for(rel):
        out.append("  " + v)
    return out


def cron_lines_of(jobs, w, ch):
    """Sekcje configu tej relacji i linie, ktore host naprawde wykona.

    Otoczka zfs-job.sh (--log/--notify/--detail) jest POMIJANA i to jest
    powiedziane: sama komenda silnika mowi, co sie stanie."""
    out = []
    seen = set()
    for j in jobs:
        arrow = ch.arrows.get(j.get("direction", ""), "?").format(peer=j.get("peer") or "?")
        ret = j.get("retain") or j.get("keep") or ""
        tier = j.get("tier", "")
        if "__" in tier:
            tier = tier.rsplit("__", 1)[-1]
        out.append(fit("  %s %-13s %-20s %s" % (fit(arrow, 16, ch), j.get("schedule", "?"), fit(tier + ((" " + ret) if ret else ""), 20, ch),
                                               fit_left(j.get("scope", ""), max(10, w - 54), ch)), w))
        for ln in j.get("cron_lines") or []:
            if ln in seen:
                continue
            seen.add(ln)
            sched = " ".join(ln.split()[:5])
            engine = ln.split(" -- ", 1)[1] if " -- " in ln else " ".join(ln.split()[5:])
            engine = engine.split(" >>")[0]
            out.extend(wrap("      %s   %s" % (sched, engine), w))
    if jobs and not any(j.get("cron_lines") for j in jobs):
        out.append(u"  (linie crona: list-jobs bez pola cron_lines -- starszy czytelnik)")
    return out


def render_window(base, title, lines, scroll, width, height, ch, footer=u"Esc zamyka   strzałki/PgUp/PgDn przewijają"):
    """Okno na wierzchu ekranu: ramka podwojna, tresc przewijana."""
    scr = Screen()
    inner_h = height - 3
    if scroll > max(0, len(lines) - inner_h):
        scroll = max(0, len(lines) - inner_h)
    body = lines[scroll:scroll + inner_h]
    while len(body) < inner_h:
        body.append("")
    pos = ""
    if len(lines) > inner_h:
        pos = "%d-%d z %d" % (scroll + 1, min(len(lines), scroll + inner_h), len(lines))
    bx = box(ch, title, body, width, footer=footer + ("   " + pos if pos else ""))
    scr.lines = [base.lines[0]] + bx
    scr.bars.add(0)
    scr.titles.add(1)
    scr.titles.add(len(scr.lines) - 1)
    return scr, scroll


# --- Transfery -------------------------------------------------------------
def build_transfers(data, now):
    jobs = list((data.progress or {}).get("jobs", []))
    running = [j for j in jobs if j.get("state") == "running"]
    done = [j for j in jobs if j.get("state") != "running"]
    running.sort(key=lambda j: int(j.get("started_epoch") or 0), reverse=True)
    done.sort(key=lambda j: int(j.get("finished_epoch") or j.get("updated_epoch") or 0), reverse=True)
    return running, done


def transfer_row(t, now, cols, ch):
    nw, dw, mw, pw, sw, tw = cols
    wd, note = transfer_word(t, now)
    mode = {"incremental": "przyrost.", "full": u"pełny"}.get(t.get("mode", ""), t.get("mode", "?"))
    tot, dn = int(t.get("total_bytes") or 0), int(t.get("done_bytes") or 0)
    if t.get("state") == "running":
        if tot > 0:
            prog = "%d%% %s" % (dn * 100 // tot, human_bytes(tot))
        elif dn > 0:
            prog = human_bytes(dn)
        else:
            prog = "?"
        when = fmt_ago(t.get("updated_epoch"), now)
    else:
        prog = human_bytes(tot) if tot > 0 else (human_bytes(dn) if dn > 0 else "-")
        st, fin = int(t.get("started_epoch") or 0), int(t.get("finished_epoch") or 0)
        when = "%s %s" % (fmt_when(fin or st, now), fmt_dur(fin - st) if fin and st else "")
    ds = t.get("dataset", "").split("@", 1)[0]
    return "%s %s %s %s %s %s" % (fit(t.get("label") or "(bez rel.)", nw, ch), fit_left(ds, dw, ch), fit(mode, mw, ch),
                                  fit(prog, pw, ch), fit(wd, sw, ch), fit(when, tw, ch))


def transfer_detail_pairs(t, now, ch):
    wd, note = transfer_word(t, now)
    pairs = [("Relacja", t.get("label") or "(bez etykiety relacji)"),
             ("Migawka", t.get("dataset", "?")),
             ("Cel", "%s %s   (%s, %s)" % (ch.right, t.get("target", "?"), t.get("direction", "?"), t.get("peer") or "lokalnie")),
             ("Tryb", "%s%s" % ({"incremental": "przyrostowy", "full": u"pełny"}.get(t.get("mode", ""), t.get("mode", "?")),
                                 ("   od @" + t["base"].split("@", 1)[-1]) if t.get("base") else "   (brak wspólnej bazy)"))]
    tot, dn, wire = int(t.get("total_bytes") or 0), int(t.get("done_bytes") or 0), int(t.get("wire_bytes") or -1)
    b = "%s / %s" % (human_bytes(dn), human_bytes(tot) if tot > 0 else "nieznane")
    b += u"   na łączu: %s" % (human_bytes(wire) if wire >= 0 else u"niemierzalne (mbuffer nie raportuje)")
    pairs.append(("Bajty", b))
    if t.get("state") == "running":
        rate, eta = int(t.get("rate_bps") or 0), int(t.get("eta_seconds") or -1)
        pairs.append(("Tempo", "%s/s   ETA %s" % (human_bytes(rate), fmt_dur(eta) if eta >= 0 else "?")))
    st, fin, upd = int(t.get("started_epoch") or 0), int(t.get("finished_epoch") or 0), int(t.get("updated_epoch") or 0)
    txt = "%s  start %s" % (wd, fmt_full(st))
    if fin:
        txt += "  koniec %s  (%s)" % (fmt_full(fin), fmt_dur(fin - st))
    else:
        txt += "  aktualizacja %s" % fmt_ago(upd, now)
    if note:
        txt += "  -- " + note
    pairs.append(("Stan", txt))
    pairs.append(("Proces", "pid %s   job %s" % (t.get("pid", "?"), (t.get("job") or "?")[:12])))
    return pairs


def render_transfery(data, cursor, width, height, now, ch, message=""):
    scr = Screen()
    top = top_bar(data, width, now, ch.ascii, len(data.errors))
    if data.failed("progress"):
        scr.lines = [top] + box(ch, "Transfery", source_error_body(ch, "progress", data, "progress"), width)
    else:
        running, done = build_transfers(data, now)
        allrows = running + done
        beside = width >= 120
        lbw = max(MIN_WIDTH, int(width * 0.6)) if beside else width
        inner = lbw - 4
        nw = max(8, min(20, max([len(t.get("label") or "(bez rel.)") for t in allrows] + [8])))
        mw, pw, sw, tw = 9, 12, 7, 16
        dw = inner - (nw + mw + pw + sw + tw + 5)
        cols = (nw, dw, mw, pw, sw, tw)
        hdr = "%s %s %s %s %s %s" % (fit("Relacja", nw), fit("Dataset", dw), fit("Tryb", mw), fit("Dane", pw), fit("Stan", sw), fit("Kiedy", tw))
        panel_h = 0 if beside else 9
        # Kazda ramka = wiersze + naglowek + kreska + 2 krawedzie. Suma ramek i
        # panelu ma sie zmiescic w wysokosci minus dwa paski -- inaczej panel
        # spada poza ekran (tak bylo w pierwszej wersji: 25 linii na 24).
        avail = height - 2 - panel_h
        run_rows = min(len(running), max(1, avail // 3 - 4)) if running else 1
        run_h = run_rows + 4
        done_h = avail - run_h
        rbody = [hdr, ch.dash * inner]
        cur_y = None
        if running:
            for i, t in enumerate(running[:run_rows]):
                if i == cursor:
                    cur_y = ("run", len(rbody))
                rbody.append(transfer_row(t, now, cols, ch))
        else:
            rbody.append(u"nic nie leci teraz")
        runbox = box(ch, "W toku (%d)" % len(running), rbody, lbw)
        dbody = [hdr, ch.dash * inner]
        list_h = max(1, done_h - 4)
        di = cursor - len(running)
        first = 0
        if di >= list_h:
            first = di - list_h + 1
        for i, t in enumerate(done[first:first + list_h], start=first):
            if i == di:
                cur_y = ("done", len(dbody))
            dbody.append(transfer_row(t, now, cols, ch))
        if not done:
            dbody.append(u"brak zapisów w historii transferów")
        if len(done) > first + list_h and list_h > 1:
            dbody[-1] = fit(u"... jeszcze %d" % (len(done) - first - list_h + 1), inner)
        while len(dbody) < list_h + 2:
            dbody.append("")
        donebox = box(ch, u"Zakończone (%d)" % len(done), dbody, lbw,
                      footer=u"Enter szczegóły" if allrows else "")
        left = runbox + donebox
        if cur_y:
            which, y = cur_y
            scr.cursor_y = 1 + (1 + y if which == "run" else len(runbox) + 1 + y)
        panel = []
        if allrows and 0 <= cursor < len(allrows):
            t = allrows[cursor]
            pw_ = (width - max(MIN_WIDTH, int(width * 0.6))) if beside else width
            pl = detail_kv(ch, transfer_detail_pairs(t, now, ch), pw_ - 4)
            lim = (len(left) - 2) if beside else (panel_h - 2)
            pl = pl[:lim]
            while len(pl) < lim:
                pl.append("")
            panel = box(ch, u"transfer -- szczegóły", pl, pw_, double=False)
        if beside and panel:
            scr.lines = [top] + side_by_side(left, panel, width, ch)
        else:
            scr.lines = [top] + left + panel
        for y, ln in enumerate(scr.lines):
            if ln and ln[0] in (ch.dtl, ch.dbl, ch.stl, ch.sbl):
                scr.titles.add(y)
    scr.bars.add(0)
    if message:
        scr.lines.append(fit(" " + message, width))
    while len(scr.lines) < height - 1:
        scr.lines.append(fit("", width))
    scr.lines = scr.lines[:height - 1]
    scr.lines.append(key_bar("transfery", width))
    scr.bars.add(len(scr.lines) - 1)
    return scr


# --- Monitor ---------------------------------------------------------------
def monitor_rows(data):
    mons = list((data.monitors or {}).get("monitors", []))
    order = {v: i for i, v in enumerate(VERDICT_ORDER)}
    mons.sort(key=lambda m: order.get(m.get("verdict", "UNKNOWN"), 9))
    return mons


def monitor_detail_pairs(m, ch, full=False):
    vw = VERDICTS.get(m.get("verdict", ""), (m.get("verdict", "?"), 0))[0]
    pairs = [("Relacja", m.get("label") or "(bez etykiety)"),
             ("Datasety (%d)" % len(m.get("datasets", [])), ",  ".join(m.get("datasets", [])) or "?"),
             ("Rodzina", "%s   progi %s / %s   %s" % (m.get("pattern") or "?", m.get("warn") or "?", m.get("crit") or "?",
                                                      "rekursywnie" if m.get("recursive") else "")),
             ("Sprawdza", "%s   konto %s" % (m.get("schedule") or "?", m.get("account") or "?"))]
    if m.get("exclude"):
        pairs.append(("Wyklucza", ", ".join(m["exclude"])))
    verdict = vw
    if m.get("reason"):
        lines = m["reason"].splitlines()
        # W panelu jedna linia (pelny tekst w oknie po Enter); w oknie wszystkie.
        verdict += "   " + (lines[0] if not full else "  |  ".join(lines))
    elif m.get("verdict") == "OK":
        verdict += u"   najnowsza migawka mieści się w progu"
    notes = []
    if m.get("paused_local"):
        notes.append(u"relacja wstrzymana -- OK z pauzy to nie dowód pokrycia")
    if m.get("engine_path_differs"):
        notes.append(u"cron woła %s, a tu policzono %s -- inny plik silnika" % (m.get("engine_in_cron"), m.get("engine_run")))
    if not m.get("parsed", True):
        notes.append(u"linii monitora nie dało się sparsować; werdykt pochodzi z kodu wyjścia")
    if notes:
        pairs.append(("Uwaga", "  |  ".join(notes)))
    pairs.append(("Werdykt", verdict))
    return pairs


def render_monitor(data, cursor, width, height, now, ch, message=""):
    scr = Screen()
    top = top_bar(data, width, now, ch.ascii, len(data.errors))
    if data.failed("monitors"):
        scr.lines = [top] + box(ch, "Monitor", source_error_body(ch, "monitors", data, "monitor"), width)
    else:
        mons = monitor_rows(data)
        beside = width >= 120
        lbw = max(MIN_WIDTH, int(width * 0.6)) if beside else width
        inner = lbw - 4
        nw = max(8, min(20, max([len(m.get("label") or "(bez rel.)") for m in mons] + [8])))
        fw, pw, vw = 16, 12, 14
        dw = inner - (nw + fw + pw + vw + 4)
        hdr = "%s %s %s %s %s" % (fit("Relacja", nw), fit("Dataset", dw), fit("Rodzina", fw), fit("Progi", pw), fit("Kopie", vw))
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
            vword = VERDICTS.get(m.get("verdict", ""), (m.get("verdict", "?"), 0))[0]
            if m.get("paused_local"):
                vword += " PAUZA"
            if i == cursor:
                cur_y = len(body)
            body.append("%s %s %s %s %s" % (fit(m.get("label") or "(bez rel.)", nw, ch), fit_left(dtxt, dw, ch),
                                            fit(m.get("pattern") or "?", fw, ch),
                                            fit("%s/%s" % (m.get("warn") or "?", m.get("crit") or "?"), pw, ch), fit(vword, vw, ch)))
        if not mons:
            body += [u"Zero linii monitora w blokach zfs-backup-managed.",
                     u"Kopie mogą się robić, ale NIKT nie sprawdza, czy dalej się robią."]
        if len(mons) > first + list_h:
            body.append(u"... jeszcze %d" % (len(mons) - first - list_h))
        while len(body) < list_h + 2:
            body.append("")
        wv = (data.monitors or {}).get("worst", "?")
        title = "Monitor -- %s, najgorzej: %s" % (plural(len(mons), "linia", "linie", "linii"),
                                                 VERDICTS.get(wv, (wv, 0))[0] if mons else "--")
        lb = box(ch, title, body, lbw, footer=u"Enter szczegóły" if mons else "")
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
            panel = box(ch, u"%s -- szczegóły" % (mons[cursor].get("label") or "linia"), pl, pw_, double=False)
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
    scr.lines.append(key_bar("monitor", width))
    scr.bars.add(len(scr.lines) - 1)
    return scr


# --- Nosniki ---------------------------------------------------------------
def replica_detail_pairs(r, ch):
    st = MEDIA_STATES.get(r.get("present", "unknown"), MEDIA_STATES["unknown"])
    pairs = [(u"Źródła (%d)" % len(r.get("sources", [])), ",  ".join(r.get("sources", [])) or r.get("source") or "?"),
             ("Cel", "%s %s   (pula %s)" % (ch.right, r.get("dst", "?"), (r.get("dst") or "?").split("/")[0])),
             ("Harmonogram", "%s   stempel %s%s%s" % (
                 {"on-insert": u"po włożeniu nośnika"}.get(r.get("schedule"), r.get("schedule") or "?"),
                 r.get("prefix") or "?", "   rekursywnie" if r.get("recursive") == "yes" else "",
                 "   historia: %s" % r["history"] if r.get("history") and r["history"] != "all" else "")),
             (u"Nośnik", "%s -- %s" % (st[0], st[2])),
             ("Ostatnio", r.get("last_seen") or u"nigdy nie widziany (brak pliku last-seen bramy)")]
    return pairs


def render_nosniki(data, cursor, width, height, now, ch, message=""):
    scr = Screen()
    top = top_bar(data, width, now, ch.ascii, len(data.errors))
    if data.failed("replicas"):
        scr.lines = [top] + box(ch, u"Nośniki", source_error_body(ch, "replicas", data, "list-replicas"), width)
    else:
        reps = list((data.replicas or {}).get("replicas", []))
        beside = width >= 120
        lbw = max(MIN_WIDTH, int(width * 0.6)) if beside else width
        inner = lbw - 4
        nw = max(8, min(16, max([len(r.get("name") or "?") for r in reps] + [8])))
        sw, mw, lw = 12, 13, 10
        dw = inner - (nw + sw + mw + lw + 4)
        hdr = "%s %s %s %s %s" % (fit("Replika", nw), fit(u"Źródło %s cel" % ch.right, dw), fit("Harmonogram", sw), fit(u"Nośnik", mw), fit("Widziany", lw))
        panel_h = 0 if beside else 9
        list_h = max(3, height - 2 - 2 - panel_h - 2)
        body = [hdr, ch.dash * inner]
        cur_y = None
        for i, r in enumerate(reps[:list_h]):
            st = MEDIA_STATES.get(r.get("present", "unknown"), MEDIA_STATES["unknown"])
            sd = "%s %s %s" % (r.get("source") or "?", ch.right, r.get("dst") or "?")
            if i == cursor:
                cur_y = len(body)
            body.append("%s %s %s %s %s" % (fit(r.get("name"), nw, ch), fit(sd, dw, ch),
                                            fit({"on-insert": u"po włożeniu"}.get(r.get("schedule"), r.get("schedule") or "?"), sw, ch),
                                            fit(st[0], mw, ch), fit((r.get("last_seen") or "nigdy")[:10], lw, ch)))
        if not reps:
            body += [u"Brak sekcji [replica:] w configu tego kolektora.",
                     u"Ten host nie replikuje na nośniki wymienne; to nie jest błąd, tylko brak konfiguracji.",
                     u"Dodaje się ją przez: zfs-backup.sh add-replica NAZWA --source=DS --dst=PULA/BAZA"]
        while len(body) < list_h + 2:
            body.append("")
        lb = box(ch, u"Repliki na nośnikach wymiennych (%d)" % len(reps), body,
                 lbw, footer=u"Enter szczegóły" if reps else "")
        if cur_y is not None:
            scr.cursor_y = 2 + cur_y
        panel = []
        if reps and 0 <= cursor < len(reps):
            pw_ = (width - max(MIN_WIDTH, int(width * 0.6))) if beside else width
            pl = detail_kv(ch, replica_detail_pairs(reps[cursor], ch), pw_ - 4)
            lim = (len(lb) - 2) if beside else (panel_h - 2)
            pl = pl[:lim]
            while len(pl) < lim:
                pl.append("")
            panel = box(ch, u"%s -- szczegóły" % reps[cursor].get("name"), pl, pw_, double=False)
        elif not reps:
            legend = [u"Cztery stany nośnika, nie flaga obecny/nieobecny:"]
            for k in ("here", "available", "away", "wrong_medium"):
                legend.extend(wrap("  %-13s %s" % (MEDIA_STATES[k][0], MEDIA_STATES[k][2]), width - 4))
            lim = panel_h - 2 if not beside else len(lb) - 2
            legend = legend[:lim]
            while len(legend) < lim:
                legend.append("")
            pw_ = (width - max(MIN_WIDTH, int(width * 0.6))) if beside else width
            panel = box(ch, "legenda", [fit(l, pw_ - 4) for l in legend], pw_, double=False)
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
    scr.lines.append(key_bar("nosniki", width))
    scr.bars.add(len(scr.lines) - 1)
    return scr


# --- Pomoc -----------------------------------------------------------------
HELP = [
    u"Okna nad zfs-snapshot-all. Akcje wołają czasowniki CLI, nic więcej.",
    "",
    u"  F2  Zadania    co chodzi w cronie: relacja, kierunek, zadanie, czasy i GB jak",
    u"                 w mailu (ostatni/średni/maks, okno digestu), kopie",
    u"  F3  Relacje    zarządzanie: Enter szczegóły, F4 pauza/wznów, Del usuń,",
    u"                 F7 eksport do pliku, F8 import z pliku, Ins nowa relacja",
    u"                 (kreator w 7 krokach, same listy: host -> diagnoza (SSH, ZFS,",
    u"                 pakiet; brak pakietu = prepare-source) -> datasety (wiele,",
    u"                 drzewo) -> dokąd -> szablon słowami -> nazwa -> konto ->",
    u"                 zaawansowane -> zdanie + komenda -> plan -> 't';",
    u"                 Enter na źródle/celu = lista datasetów zamiast pisania;",
    u"                 szablony opisane słowami, Ins na liście = nowy szablon)",
    u"                 Akcja: NAJPIERW komenda bash, potem 't', potem wyjście",
    u"                 na żywo. Esc zamyka okno, a proces biegnie dalej.",
    u"  F4  Transfery  co leci teraz i co skończyło się ostatnio (progress)",
    u"  F5  Monitor    każda linia monitora z werdyktem i powodem (monitor)",
    u"  F6  Nośniki    repliki na dyskach wymiennych i cztery stany nośnika",
    u"  Kierunek       lewa strona to ZAWSZE ten host: pve10>pve9 wysyłam,",
    u"                 pve10<pve9 pobieram, pve10<>pve9 obie strony, local",
    "",
    u"  F3 w trzech panelach: lista relacji, szczegóły, a na dole pary",
    u"                 źródło → cel podświetlonej relacji (z linii crona; relacja",
    u"                 bez crona ma pary z rekordu i tytuł to mówi). Tab przenosi",
    u"                 kursor na pary; Enter na parze skacze do tego zadania na F2.",
    "",
    u"  LINIA POLECEŃ nad listwą klawiszy (jak w mc): pisz, Enter wykonuje na",
    u"                 pierwszym planie w katalogu repo, po komendzie Enter wraca.",
    u"                 Strzałki przy niepustej linii = historia, Esc/Ctrl-U czyści.",
    u"                 W potwierdzeniu akcji 'e' wrzuca pokazaną komendę do linii,",
    u"                 żeby ją poprawić przed wykonaniem. Cyfry i litery nie są",
    u"                 skrótami na ekranach -- wszystko, co piszesz, idzie do linii.",
    "",
    u"  strzałki          ruch po liście     PgUp PgDn Home End   szybciej",
    u"  F9 / Ctrl-R       odśwież źródła (monitor liczy na żywo, to chwilę trwa)",
    u"  Esc               zamknij okno na wierzchu (w oknie także q; j k przewijają)",
    u"  F10               wyjście (litery idą do linii poleceń, więc q nie wychodzi)",
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

    def __init__(self, repo, files, ch, now=None, exec_log=None, wizard="whiptail"):
        self.repo, self.files, self.ch = repo, files, ch
        # Ins na F3: "whiptail" = czasownik new-relation (okna-klocki, decyzja wlasciciela
        # 2026-09-16), terminal oddany kreatorowi i powrot TUTAJ po jego zakonczeniu;
        # "curses" = stary kreator rysowany recznie, zostaje tylko dla swojej suity.
        self.wizard = wizard
        self.pending_nowait = False
        self.rel_names_before = None   # Ins: lista relacji sprzed oddania terminala kreatorowi
        self.now_fixed = now
        self.exec_log = exec_log   # testy: zamiast uruchamiac, zapisz komende tutaj
        self.screen = "zadania"
        self.cursor = {"zadania": 0, "relacje": 0, "transfery": 0, "monitor": 0, "nosniki": 0}
        self.window = None        # ("relacja", row) | ("pomoc", None) | ("prompt"|"confirm"|"output", dict)
        self.scroll = 0
        self.message = ""
        self.focus = "list"       # F3: "list" (relacje) | "pairs" (dolny panel par)
        self.pair_cursor = 0
        # LINIA POLECEN (wlasciciel 2026-09-11: "chcemy moc w kazdej chwili
        # pisac komendy z palca"). Styl mc: kazdy drukowalny znak leci tu,
        # Enter wykonuje NA PIERWSZYM PLANIE (curses zawieszone), historia w
        # ~/.zfs-tui/history. q/r/j/k/cyfry sa skrotami TYLKO przy pustej linii.
        self.cmd = ""
        self.cmd_hist = self.load_history()
        self.hist_pos = None
        self.pending_shell = None
        self.data = collect(repo, files)
        self.rows = build_relations(self.data, self.now())
        self.jobrows = build_jobs(self.data, self.now())

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
            self.message = u"[atrapa] nie uruchomiono, komenda zapisana do dziennika testu: " + line
            return "stay"
        self.pending_shell = line
        return "shell"

    def run_dialog(self, argv):
        """Oddaj terminal dialogowi whiptail i wroc z odswiezonymi danymi."""
        line = " ".join(shlex.quote(x) for x in argv)
        if self.exec_log:
            with io.open(self.exec_log, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
            self.message = u"[atrapa] nie uruchomiono, komenda zapisana do dziennika testu: " + line
            return "stay"
        self.pending_shell, self.pending_nowait = line, True
        return "shell"

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
            self.message = u"[atrapa] nie uruchomiono, komenda zapisana do dziennika testu: " + line
            return "stay"
        self.pending_shell, self.pending_nowait = line, True
        return "shell"

    def refresh(self, only=None):
        self.data = collect(self.repo, self.files, only)
        self.rows = build_relations(self.data, self.now())
        self.jobrows = build_jobs(self.data, self.now())
        for k in self.cursor:
            self.cursor[k] = min(self.cursor[k], max(0, self.count(k) - 1))

    def count(self, screen):
        if screen == "zadania":
            return len(self.jobrows)
        if screen == "relacje":
            return len(self.rows)
        if screen == "transfery":
            r, d = build_transfers(self.data, self.now())
            return len(r) + len(d)
        if screen == "monitor":
            return len(monitor_rows(self.data))
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
            return None, u"akcje na relacjach są na ekranie F3 Relacje"
        if not self.rows:
            return None, u"brak relacji"
        r = self.rows[self.cursor["relacje"]]
        if r["kind"] != "relation":
            return None, u"to nie jest relacja (%s) -- akcje dotyczą rekordów relacji" % ("zadanie bez rekordu" if r["kind"] == "job" else "nieczytelny blok")
        if r["rel"].get("state") == "removed" and not allow_removed:
            return None, u"relacja '%s' jest już usunięta (removed_at %s)" % (r["name"], r["rel"].get("removed_at") or "?")
        return r, ""

    def confirm(self, title, argv, note_lines=None, redirect=None, on_yes=None):
        line = self.shell_line(argv, redirect)
        lines = [u"Wykona się DOKŁADNIE to:", ""] + wrap("  " + line, 72) + [""]
        if note_lines:
            lines += note_lines + [""]
        lines += [u"t = wykonaj      e = do linii poleceń (popraw i Enter)      Esc / inny klawisz = anuluj"]
        self.window = ("confirm", {"title": title, "lines": lines, "argv": argv, "redirect": redirect,
                                   "shell": line, "on_yes": on_yes})
        self.scroll = 0

    def prompt(self, title, label, value, on_enter):
        self.window = ("prompt", {"title": title, "label": label, "value": value, "on_enter": on_enter})
        self.scroll = 0

    def run_detached(self, title, argv, redirect=None, logname=None):
        """Uruchom czasownik w tle, wyjscie do pliku, okno pokazuje ogon pliku."""
        shell = self.shell_line(argv, redirect)
        if self.exec_log:
            with open(self.exec_log, "a", encoding="utf-8") as fh:
                fh.write(shell + "\n")
            self.window = ("output", {"title": title, "path": None, "proc": None, "shell": shell,
                                      "lines": [u"[atrapa] nie uruchomiono, komenda zapisana do dziennika testu:", "  " + shell], "rc": 0})
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
                                      "lines": [u"nie udało się uruchomić: %s" % e], "rc": 127})
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
                body = [u"(brak pliku wyjścia: %s)" % obj["path"]]
        for ln in body:
            out.extend(wrap(ln.rstrip("\r"), width - 4) or [""])
        proc = obj.get("proc")
        rc = obj.get("rc")
        if proc is not None:
            rc = proc.poll()
            obj["rc"] = rc
        out.append("")
        if rc is None and proc is not None:
            out.append(u"--- trwa (pid %d). Esc zamyka okno, proces biegnie dalej; wyjście w %s" % (proc.pid, obj["path"]))
        elif rc == 0:
            out.append(u"--- zakończone, rc=0" + (u"   zapisano: %s" % obj["redirect"] if obj.get("redirect") else "") + (u"   (dziennik: %s)" % obj["path"] if obj.get("path") else ""))
        else:
            out.append(u"--- zakończone, rc=%s -- czasownik ODMÓWIŁ albo padł; przeczytaj powyżej" % rc + (u"   (dziennik: %s)" % obj["path"] if obj.get("path") else ""))
        return out

    def action(self, k):
        """Klawisz akcji na F3 -> okno potwierdzenia albo komunikat."""
        # Del dziala takze na rekordzie `removed`: tam znaczy "zwolnij nazwe / posprzataj reszte".
        r, why = self.current_relation(allow_removed=(k == "del"))
        if r is None:
            self.message = why
            return
        n = r["name"]
        rel = r["rel"]
        if k == "F4":
            if rel.get("paused_local"):
                self.confirm(u"Wznów relację %s" % n, [self.zb(), "resume-client", n],
                             [u"Zdejmuje pauzę: następny bieg z crona rusza normalnie i dogania przyrostowo."])
            else:
                self.confirm(u"Wstrzymaj relację %s" % n, [self.zb(), "pause-client", n, "--reason=z TUI %s" % time.strftime("%Y-%m-%d %H:%M")],
                             [u"Pauza LOGICZNA: linie w cronie zostają, ale nic nie wysyła i nie kasuje;",
                              u"monitor mówi OK z pauzy. Odwrotność: F4 na tej relacji jeszcze raz (resume-client)."])
        elif k == "del":
            # CALE usuniecie (kolektor + zrodlo + zwolnienie nazwy), w oknach whiptail:
            # samo remove-client zostawialo rekord `removed`, ktory trzymal NAZWE, wiec
            # "usun i zaloz od nowa" -- jedyna dzis droga zmiany relacji -- nie dzialalo
            # (zmierzone na pve10, 2026-09-20).
            return self.run_dialog([self.zb(), "delete-relation", n, "--ask"])
        elif k == "F7":
            default = os.path.join(home_dir(), "%s.export.json" % n)
            self.prompt(u"Eksport relacji %s" % n, u"Plik (Enter = zatwierdź, Esc = anuluj):", default,
                        lambda path: self.confirm(u"Eksport relacji %s" % n, [self.zb(), "export-relation", n, "--json"],
                                                  [u"Deklaracje (to, co człowiek podał) plus argv do odtworzenia. Bez stanu, historii, ścieżek hosta."],
                                                  redirect=path))
        elif k == "F8":
            default = os.path.join(home_dir(), "")
            self.prompt(u"Import relacji z pliku", u"Plik eksportu (Enter = podgląd, Esc = anuluj):", default, self.import_preview)
        elif k == "ins":
            if self.wizard == "curses":
                self.wizard_open()
            else:
                return self.run_wizard()

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
        fields = [("name", u"Nazwa nowego szablonu", "text", u"litery, cyfry, . _ - ; plik NAZWA.conf w /etc/zfs-snapshot-all/profiles. Nazwa w stylu d7h48 obiecuje retencję -- czasownik sprawdzi"),
                  ("desc", u"Opis", "text", u"jedno zdanie, co ten szablon robi (pole description)"),
                  ("base", u"Na bazie", "pick", u"Enter = lista szablonów; z bazy idą mechanizm, kształt i wszystko, czego nie zmienisz")]
        for t in base.get("tiers", []):
            tn = t.get("name", "")
            adj = tier_unit(tn, TIER_ADJ)
            fields.append((u"h|%s" % tn, u"szczebel %s (%s)" % (tn, adj), "head", ""))
            if t.get("send_schedule"):
                fields.append(("t|%s|send_schedule" % tn, u"  migawka co (cron)", "cron", u"5 pól crona; obok słowa, jak to czyta człowiek"))
            if t.get("keep"):
                fields.append(("t|%s|keep" % tn, u"  trzymaj %s" % tier_unit(tn), "num", u"licznik: ile %s zostaje (0 = nic z tego szczebla)" % tier_unit(tn)))
            elif t.get("retain"):
                fields.append(("t|%s|retain" % tn, u"  trzymaj wg wieku", "text", u"flaga silnika, np. -h24 = młodsze niż 24 godziny"))
            if t.get("prune_schedule"):
                fields.append(("t|%s|prune_schedule" % tn, u"  porządki co (cron)", "cron", u"kiedy kasować nadmiar"))
            if t.get("send_schedule"):
                qh = u"tak = auto,degrade (spójna migawka; gdy nie da się zamrozić, robi zwykłą)"
                if base.get("shape") == "one-family":
                    qh = u"UWAGA: jedna rodzina -- zamrażanie dotyczy KAŻDEJ migawki tego szczebla (np. 24 razy na dobę)"
                fields.append(("t|%s|quiesce" % tn, u"  zamrażaj system plików", "toggle", qh))
            if t.get("monitor_warn") or t.get("monitor_crit"):
                fields.append(("t|%s|monitor_warn" % tn, u"  monitor: ostrzeż po", "text", u"np. 90m, 30h, 8d -- kopia starsza niż to = ostrzeżenie"))
                fields.append(("t|%s|monitor_crit" % tn, u"  monitor: alarm po", "text", u"np. 150m, 48h, 10d -- starsza niż to = alarm"))
        fields.append(("go", u"[ ZAPISZ ]", "go", u"Enter: komendy save-profile do potwierdzenia (nic nie zapisane przed 't')"))
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
        self.window = ("form", {"kind": "profile", "title": u"Nowy szablon na bazie: %s" % base.get("name", "?"),
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
            self.message = u"nie ma szablonu '%s' na liście" % name
            obj["vals"]["base"] = obj["base"].get("name", "")
            return
        keep = dict(obj["vals"])
        if (keep.get("desc") or "") == (obj["base"].get("description") or ""):
            keep["desc"] = ""   # opis nieedytowany idzie za nowa baza
        obj["base"], obj["title"] = base, u"Nowy szablon na bazie: %s" % name
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
            self.message = u"nazwa nowego szablonu jest wymagana"
            return
        if any(not (c.isalnum() or c in "._-") for c in name) or name.startswith("."):
            self.message = u"nazwa: tylko litery, cyfry, kropka, podkreślnik, myślnik"
            return
        if name == base.get("name"):
            self.message = u"nazwa musi być inna niż baza (pakietowego szablonu nie nadpiszemy)"
            return
        for key, _l, kind, _h in obj["fields"]:
            if kind == "cron" and len((vals.get(key) or "").split()) != 5:
                self.message = u"harmonogram '%s' to nie 5 pól crona" % (vals.get(key) or "")
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
            note += wrap(u"Zmienione szczeble: %s -- %d wywołania save-profile po kolei (jeden --tier na raz):" % (", ".join(tn for tn, _ in changes), len(argvs)), 72)
            for a in argvs[1:]:
                note += wrap("  " + self.shell_line(a), 72)
            note.append("")
        note += wrap(u"Zapis idzie do /etc/zfs-snapshot-all/profiles/%s.conf. Dwie bramki czasownika: walidator i prawdziwy render." % name, 72)
        back_form = obj.get("back")
        argv = argvs[0] if len(argvs) == 1 else ["bash", "-c", " && ".join(self.shell_line(a) for a in argvs)]

        def on_yes():
            self.run_detached(u"Nowy szablon %s" % name, argv, logname="save-profile")
            self.data.profiles = None
            if back_form and back_form[0] in ("form", "wiz"):
                back_form[1]["vals"]["profile"] = name
                back_form[1]["profiles"] = None
                back_form[1]["cur"] = 0
                self.window[1]["back_to"] = back_form
        self.confirm(u"Nowy szablon %s (na bazie %s)" % (name, base.get("name", "?")), argv, note, on_yes=on_yes)

    # ------------------------------------------------------------------
    # KREATOR NA LISTACH (makieta wlasciciela, 2026-09-14): jedna regula klawiszy
    # na wszystkie kroki -- strzalki wybieraja, Enter wybiera/zaznacza/idzie
    # dalej, Esc wraca, pisanie filtruje liste. Relacja = para hostow: "nowa"
    # to host, z ktorym relacji jeszcze nie ma; hosty z relacja sa szare (ich
    # datasety to modyfikacja, ktorej CLI nie umie). Po hoscie DIAGNOZA
    # (check-source: SSH, ZFS, pakiet) i jedna akcja (prepare-source), potem
    # datasety z listy (wiele, drzewo), dokad, szablon slowami, nazwa, konto
    # (root / zfsbackup / inne), zaawansowane, podsumowanie zdaniem + komenda.
    WIZ_ORDER = ["mode", "host", "diag", "ds", "target", "profile", "name", "acct", "adv", "summary"]
    WIZ_TITLES = {"mode": u"Typ relacji", "host": u"Z którego hosta?", "diag": u"Sprawdzam host", "ds": u"Które datasety?", "target": u"Dokąd trafi kopia?",
                  "profile": u"Jak często i ile trzymać?", "name": u"Jak nazwać relację?", "acct": u"Kto ma uruchamiać kopie?",
                  "adv": u"Zaawansowane (zwykle bez zmian)", "summary": u"Podsumowanie"}
    WIZ_STEPNO = {"mode": 1, "host": 2, "diag": 2, "ds": 2, "target": 3, "profile": 4, "name": 5, "acct": 6, "adv": 7, "summary": 8}
    WIZ_NSTEP = 8
    # Domyslne maski = migawki, ktore robi sam Proxmox i sam je sprzata:
    # replikacja pvesr (__replicate_<job>_<czas>__), vzdump, migracja na zywo.
    # Kopiowanie ich nie ma sensu, a ich zniknieciu u zrodla nie ma co placzac.
    WIZ_EXFAM_DEFAULT = "__replicate_,vzdump,__migration__"
    WIZ_MODES = [("backup", u"backup    pobranie na ten host: kopie pod <cel>/<peer>/…, retencja tutaj (add-client)"),
                 ("sync", u"synchro   obie strony trzymają to samo pod TĄ SAMĄ ścieżką, bez celu (--mode=sync)")]
    WIZ_ACCTS = [("root", u"root -- bez izolacji (tak działa większość floty dziś)"),
                 ("zfsbackup", u"zfsbackup -- konto delegowane (zostanie utworzone, dostanie zfs allow)"),
                 ("other", u"inne konto -- podasz nazwę")]

    def this_host(self):
        return (self.data.jobs or {}).get("host") or (self.data.status or {}).get("host") or "?"

    def wizard_open(self):
        profiles, perr = load_profiles(self.repo, self.files, self.data)
        vals = {"mode": "backup", "host": "", "hostname": "", "port": "", "ds": [], "excl": [], "target": "", "profile": "default", "name": "",
                "acct": "zfsbackup", "other": "", "srcprof": "", "grant": False, "manual": False, "recursion": "flat", "exfam": self.WIZ_EXFAM_DEFAULT}
        self.window = ("wiz", {"kind": "wiz", "step": "mode", "cur": 0, "filter": "", "typing": None, "text": "",
                               "vals": vals, "profiles": profiles, "perr": perr})
        self.scroll = 0

    def wiz_goto(self, obj, step):
        obj["step"], obj["cur"], obj["filter"], obj["typing"], obj["text"] = step, 0, "", None, ""
        self.message = ""
        if step == "name":
            obj["typing"], obj["text"] = "name", obj["vals"]["name"] or obj["vals"]["hostname"] or obj["vals"]["host"].replace(".", "-")
        if step == "target" and obj["vals"]["target"]:
            items = self.wiz_items(obj)
            for i, it in enumerate(items):
                if it.get("key") == obj["vals"]["target"]:
                    obj["cur"] = i
        if step == "profile":
            items = self.wiz_items(obj)
            for i, it in enumerate(items):
                if it.get("key") == obj["vals"]["profile"]:
                    obj["cur"] = i

    def wiz_hosts(self):
        """Hosty do wyboru: peery z rekordow (szare -- relacja juz jest) i 'inny host'."""
        rels = {}
        for r in self.rows:
            if r["kind"] == "relation" and r["rel"].get("state") != "removed" and r["rel"].get("peer_host"):
                rels.setdefault(r["rel"]["peer_host"], []).append(r["name"])
        out = []
        for h in sorted(rels):
            out.append({"key": h, "ok": False, "text": u"%s  %s" % (fit(h, 16), u"relacje: %s -- kolejne datasety to modyfikacja relacji (CLI jeszcze nie umie)" % ", ".join(rels[h]))})
        out.append({"key": "__other__", "ok": True, "text": u"%s  wpisz adres; pakiet nie musi tam być" % fit(u"inny host…", 16)})
        return out

    def wiz_ds_tree(self, obj):
        items, err = load_datasets(self.repo, self.files, self.data, obj["vals"]["host"], obj["vals"]["port"])
        names = [d.get("name", "") for d in items]
        out = []
        for d in items:
            n = d.get("name", "")
            kids = sum(1 for x in names if x.startswith(n + "/"))
            out.append({"name": n, "depth": n.count("/"), "kids": kids, "used": int(d.get("used") or 0), "type": d.get("type", "")})
        return out, err

    def wiz_items(self, obj):
        """Linie kroku jako lista: wybieralne (sel) i informacyjne. Filtr zaweza wybieralne."""
        v, st, f = obj["vals"], obj["step"], obj["filter"].lower()
        items = []
        if st == "mode":
            items = [{"key": k, "sel": True, "text": t} for k, t in self.WIZ_MODES]
        elif st == "host":
            items = [dict(x, sel=True) for x in self.wiz_hosts()]
        elif st == "diag":
            doc, err = load_check(self.repo, self.files, self.data, v["host"], v["port"])
            d = doc or {}
            if err:
                items = [{"key": "back", "sel": True, "text": u"Wróć (check-source nie odpowiedział: %s)" % err}]
            elif not (d.get("ssh") or {}).get("ok"):
                items = [{"key": "back", "sel": True, "text": u"Wróć (najpierw wstęp SSH, patrz wyżej)"}]
            elif (d.get("package") or {}).get("ok"):
                items = [{"key": "go", "sel": True, "text": u"Dalej: lista datasetów na %s" % v["host"]}]
            else:
                items = [{"key": "install", "sel": True, "text": u"Zainstaluj pakiet na %s  (prepare-source: git clone jako root; bez crona, bez relacji)" % v["host"]},
                         {"key": "back", "sel": True, "text": u"Wróć"}]
        elif st == "ds":
            tree, err = self.wiz_ds_tree(obj)
            items = [{"key": "go", "sel": True, "text": u"Dalej z zaznaczonymi (%d%s)" % (len(v["ds"]), (u", wyłączone %d" % len(v["excl"])) if v["excl"] else "")},
                     {"key": "rec", "sel": True, "text": u"Podrzędne zaznaczonego rodzica: %s" % (
                         u"-R  każdy osobnym strumieniem (flat), wyłączenia ✗ dozwolone -- zalecane" if v["recursion"] == "flat"
                         else u"-r  jeden strumień (atomic): bez wyłączeń, bez retencji u źródła")}]
            if err:
                items.append({"key": "manual", "sel": True, "text": u"Lista niedostępna (%s) -- wpisz ścieżki ręcznie" % err})
            for d in tree:
                covered = any(d["name"].startswith(x + "/") for x in v["ds"])
                excl = d["name"] in v["excl"] or any(d["name"].startswith(x + "/") for x in v["excl"])
                mark = u"✓" if d["name"] in v["ds"] else (u"✗" if (covered and excl) else (u"·" if covered else " "))
                txt = u"%s %s%s" % (mark, "  " * d["depth"], d["name"].rsplit("/", 1)[-1] if d["depth"] else d["name"])
                extra = u"%s  %s%s" % (hbytes_short(d["used"]), d["type"], (u"  +%d podrzędne" % d["kids"]) if d["kids"] else "")
                if covered:
                    extra += u"  (wyłączony -X)" if excl else u"  (w rodzicu; Enter = wyłącz)"
                items.append({"key": d["name"], "sel": True, "text": fit(txt, 46) + " " + extra, "full": d["name"]})
        elif st == "target":
            loc, err = load_datasets(self.repo, self.files, self.data)
            if err:
                items.append({"key": "manual", "sel": True, "text": u"Lista niedostępna (%s) -- wpisz ścieżkę ręcznie" % err})
            for d in loc:
                items.append({"key": d.get("name", ""), "sel": True, "text": u"%s %9s %9s" % (fit(d.get("name", ""), 46), hbytes_short(int(d.get("used") or 0)), hbytes_short(int(d.get("avail") or 0)))})
        elif st == "profile":
            if obj.get("profiles") is None:
                obj["profiles"], obj["perr"] = load_profiles(self.repo, self.files, self.data)
            names = [pr.get("name") for pr in (obj.get("profiles") or [])]
            if v["profile"] and v["profile"] not in names:
                # Szablon zapisany przed chwila (albo wpisany recznie): lista z
                # list-profiles jeszcze go nie ma -- ma byc wybieralny, nie znikac.
                items.append({"key": v["profile"], "sel": True, "text": u"%s (zapisany przed chwilą albo wpisany ręcznie; czasownik sprawdzi)" % fit(v["profile"], 16)})
            for pr in (obj.get("profiles") or []):
                w = profile_words(pr)
                items.append({"key": pr.get("name", "?"), "sel": True, "text": u"%s %s · %s · %s" % (fit(pr.get("name", "?"), 16), w["cadence"], w["retention"], w["mech"]),
                              "sub": u"%s · %s · %s · %s" % (w["shape"], w["quiesce"], w["monitor"], pr.get("description", "") or "")})
            if obj.get("perr"):
                items.append({"key": "manual", "sel": True, "text": u"list-profiles: błąd źródła (%s) -- wpisz nazwę szablonu ręcznie" % obj["perr"][:40]})
        elif st == "acct":
            items = [{"key": k, "sel": True, "text": t} for k, t in self.WIZ_ACCTS]
        elif st == "adv":
            items = [{"key": "go", "sel": True, "text": u"Bez zmian, dalej"},
                     {"key": "port", "sel": True, "text": u"%s %s" % (fit(u"Port SSH peera", 30), v["port"] or "22")},
                     {"key": "srcprof", "sel": True, "text": u"%s %s" % (fit(u"Retencja u źródła", 30), v["srcprof"] or u"taka sama jak tutaj (%s)" % v["profile"])},
                     {"key": "grant", "sel": True, "text": u"%s %s" % (fit(u"Uprawnienia na peerze", 30), u"nadaj zdalnie: tak" if v["grant"] else u"nadaj zdalnie: nie (JOIN zrobi to przy pierwszym połączeniu)")},
                     {"key": "manual", "sel": True, "text": u"%s %s" % (fit(u"Parowanie", 30), u"ręczne: pakiet do przeniesienia" if v["manual"] else u"przez ssh (automatyczne)")},
                     {"key": "rec", "sel": True, "text": u"%s %s" % (fit(u"Podrzędne datasety", 30), u"-R  każdy osobno (flat)" if v["recursion"] == "flat" else u"-r  jednym strumieniem (atomic)")},
                     {"key": "exfam", "sel": True, "text": u"%s %s" % (fit(u"Pomijaj migawki o nazwach od…", 30), v["exfam"] or u"(żadnych)")}]
        elif st == "summary":
            items = [{"key": "plan", "sel": True, "text": u"Pokaż plan  (czasownik bez --install: nic nie zmienia)"},
                     {"key": "run", "sel": True, "text": u"Wykonaj  (plan, potem komenda z --install --yes do potwierdzenia)"}]
        if f and st in ("host", "ds", "target", "profile"):
            items = [it for i, it in enumerate(items) if (st == "ds" and i < 2) or it.get("key", "").lower().find(f) >= 0 or it.get("text", "").lower().find(f) >= 0]
        return items

    def wiz_answers(self, obj):
        v, st = obj["vals"], obj["step"]
        o = self.WIZ_ORDER.index(st)
        a = []
        if o > 0:
            a.append(u"typ: %s" % (u"synchro" if v["mode"] == "sync" else u"backup"))
        if o > 3:
            a.append(u"skąd: %s (%s%s)" % (v["host"], ", ".join(v["ds"]) or "?", (u"; bez %s" % ", ".join(v["excl"])) if v["excl"] else ""))
        if o > 4 and v["mode"] != "sync":
            a.append(u"dokąd: %s" % v["target"])
        if o > 5:
            a.append(u"szablon: %s" % v["profile"])
        if o > 6:
            a.append(u"nazwa: %s" % (v["name"] or "(z hosta)"))
        if o > 7:
            a.append(u"konto: %s" % (self.wiz_account(v) or "root"))
        return a

    def wiz_account(self, v):
        return "" if v["acct"] == "root" else ("zfsbackup" if v["acct"] == "zfsbackup" else v["other"].strip())

    def wizard_argv(self, vals, install):
        v = vals
        host = v["host"].strip() + ((":" + v["port"].strip()) if v["port"].strip() and v["port"].strip() != "22" else "")
        a = [self.zb(), "--source=%s:%s" % (host, ",".join(v["ds"]))]
        if v.get("mode") == "sync":
            a.append("--mode=sync")
        else:
            a.append("--target=%s" % v["target"].strip())
        if v.get("profile"):
            a.append("--profile=%s" % v["profile"])
        if v.get("srcprof"):
            a.append("--source-profile=%s" % v["srcprof"])
        if v.get("name"):
            a.append("--name=%s" % v["name"].strip())
        if v.get("recursion") and v["recursion"] != "flat":
            a.append("--recursive=%s" % v["recursion"])
        for x in v.get("excl", []):
            a.append("--exclude-child=%s" % x)
        if v.get("exfam"):
            a.append("--exclude-family=%s" % v["exfam"])
        if self.wiz_account(v):
            a.append("--local-user=%s" % self.wiz_account(v))
        if v.get("grant"):
            a.append("--grant-remotely")
        if v.get("manual"):
            a.append("--manual-join")
        if install:
            a += ["--install", "--yes"]
        return a

    def wiz_profile(self, obj):
        for pr in (obj.get("profiles") or []):
            if pr.get("name") == obj["vals"]["profile"]:
                return pr
        return None

    def wiz_summary(self, obj, width):
        v, host = obj["vals"], self.this_host()
        pr = self.wiz_profile(obj)
        w = profile_words(pr) if pr else None
        n = len(v["ds"])
        what = u"migawki %s" % (u"datasetu %s" % v["ds"][0] if n == 1 else u"%d datasetów (%s)" % (n, ", ".join(v["ds"])))
        acct = self.wiz_account(v) or "root"
        if v["excl"]:
            what += u" bez %s" % ", ".join(v["excl"])
        if v["mode"] == "sync":
            where = u"%s i %s będą trzymać %s pod tą samą ścieżką po obu stronach" % (host, v["host"], what)
        else:
            where = u"%s pobierze %s z hosta %s do %s/%s/…" % (host, what, v["host"], v["target"], v["host"])
        if w:
            sent = u"%s %s, %s (%s, %s). %s. Monitor: %s." % (
                w["cadence"][0].upper() + w["cadence"][1:], where, w["retention"].replace("trzyma ", u"trzymając "), w["mech"], w["shape"],
                w["quiesce"][0].upper() + w["quiesce"][1:], w["monitor"].replace("monitor ", ""))
        else:
            sent = u"%s wg szablonu %s." % (where, v["profile"])
        out = wrap(sent, width - 6)
        out += wrap(u"Relacja: %s. Zadania na %s jako %s%s. Na peerze konto zfsbackup-%s (tworzy JOIN).%s%s%s" % (
            v["name"] or u"(z nazwy hosta)", host, acct, (u" (port %s)" % v["port"]) if v["port"].strip() and v["port"] != "22" else "", host,
            (u" Retencja u źródła: %s." % v["srcprof"]) if v["srcprof"] else "", u" Parowanie ręczne." if v["manual"] else "",
            u" Podrzędne jednym strumieniem (-r, atomic)." if v["recursion"] == "atomic" else u" Podrzędne osobno (-R)." if any(True for _ in v["ds"]) else ""), width - 6)
        if v.get("exfam"):
            out += wrap(u"Migawki o nazwach od %s nie będą kopiowane." % u" i ".join(u"„%s…”" % x for x in v["exfam"].split(",")), width - 6)
        out += ["", u"Komenda:"] + wrap("  " + self.shell_line(self.wizard_argv(v, True)), width - 6)
        return out

    def wiz_lines(self, obj, width):
        """Linie okna kreatora i indeks linii z kursorem."""
        v, st = obj["vals"], obj["step"]
        out, cur_line = [], None
        W = width - 4
        ans = self.wiz_answers(obj)
        if ans:
            out += [fit("  " + x, W) for x in wrap(u"   ".join(ans), W - 2)] + [""]
        if obj["typing"]:
            label = {"host": u"Adres hosta", "name": u"Nazwa relacji", "other": u"Nazwa konta", "port": u"Port SSH peera", "exfam": u"Pomijaj migawki o nazwach od…", "ds": u"Ścieżki datasetów (po przecinku)", "target": u"Lokalny dataset-rodzic", "profile": u"Nazwa szablonu"}[obj["typing"]]
            hint = {"host": u"np. 10.0.0.9 -- po Enterze kreator sprawdzi SSH, ZFS i pakiet na tym hoście",
                    "name": u"propozycja z nazwy hosta; relacja jest hosta, nie datasetu",
                    "other": u"konto zostanie utworzone, jeśli go nie ma", "port": u"puste = 22",
                    "exfam": u"początki nazw po przecinku; domyślnie migawki Proxmoxa (replikacja pvesr, vzdump, migracja). Puste = kopiuj wszystkie (--exclude-family)",
                    "ds": u"np. hdd/data,hdd/home", "target": u"np. hdd/backups", "profile": u"nazwa pliku szablonu"}[obj["typing"]]
            cur_line = len(out)
            out.append(fit(u"> %s %s_" % (fit(label, 30), obj["text"]), W))
            out += ["", fit("  " + hint, W)]
        else:
            if st == "diag":
                doc, err = load_check(self.repo, self.files, self.data, v["host"], v["port"])
                d = doc or {}
                ssh, zfs, pkg = d.get("ssh") or {}, d.get("zfs") or {}, d.get("package") or {}
                out.append(fit(u"  %s%s" % (v["host"], (u"   (%s)" % d["hostname"]) if d.get("hostname") else ""), W))
                if err:
                    out.append(fit(u"    check-source nie odpowiedział: %s" % err, W))
                else:
                    out.append(fit(u"    SSH jako root .............. %s" % (u"OK   klucz roota %s jest tam zaufany" % self.this_host() if ssh.get("ok") else u"BRAK %s" % (ssh.get("error") or "?")), W))
                    pools = ", ".join(u"%s %s (wolne %s)" % (x.get("name"), x.get("size"), x.get("free")) for x in (zfs.get("pools") or []))
                    out.append(fit(u"    ZFS ........................ %s" % ((u"OK   " + pools) if zfs.get("ok") else (u"?    nie sprawdzono (brak SSH)" if not ssh.get("ok") else u"BRAK zfs albo żadnej puli")), W))
                    out.append(fit(u"    pakiet zfs-snapshot-all .... %s" % ((u"OK   %s (rev %s)" % (pkg.get("path"), pkg.get("rev") or "?")) if pkg.get("ok") else (u"?    nie sprawdzono (brak SSH)" if not ssh.get("ok") else u"BRAK %s nie istnieje" % (d.get("repo_dir") or ""))), W))
                    out.append("")
                    if not ssh.get("ok"):
                        out += [fit(u"  Bez wstępu SSH kreator nie zrobi nic na tym hoście. Klucz roota to Twoja decyzja, nie kreatora:", W),
                                fit(u"    ssh-copy-id root@%s        (na %s, z linii poleceń)" % (v["host"], self.this_host()), W),
                                fit(u"  potem Esc i jeszcze raz ten host.", W)]
                    elif not pkg.get("ok"):
                        out += [fit(u"  Bez pakietu JOIN na źródle nie ma czego uruchomić. Instalacja = to, co runbook robi ręcznie:", W),
                                fit(u"    git clone … %s   na %s przez SSH roota (gdy host nie widzi GitHuba: bundlem z %s)" % (d.get("repo_dir") or "", v["host"], self.this_host()), W)]
                    if not zfs.get("ok") and ssh.get("ok"):
                        out.append(fit(u"  ! bez ZFS nie ma czego kopiować -- to nie jest źródło dla tego programu", W))
                out.append("")
            if st == "ds":
                out.append(fit(u"  %s %s" % (fit(u"  dataset (drzewo)", 46), u"zajęte  typ            Enter = zaznacz/odznacz  ✓ wybrany  · w rodzicu"), W))
            if st == "target":
                items0 = self.wiz_items(obj)
                if items0 and v["ds"] and 0 <= obj["cur"] < len(items0) and items0[obj["cur"]].get("key") != "manual":
                    # Ladowisko dla PODSWIETLONEGO celu, zanim padnie Enter -- nad lista, zeby bylo widac.
                    tgt = items0[obj["cur"]]["key"]
                    for i, d in enumerate(v["ds"][:4]):
                        out.append(fit(u"  %s%s/%s/%s" % (u"kopie wylądują w: " if i == 0 else u"                  ", tgt, v["host"], d), W))
                    if len(v["ds"]) > 4:
                        out.append(fit(u"                  … i %d więcej" % (len(v["ds"]) - 4), W))
                    out.append(fit(u"  (konwencja <cel>/<peer>/<ścieżka>; plan czasownika to potwierdzi)", W))
                    out.append("")
                out.append(fit(u"  %s %9s %9s" % (fit("dataset", 46), u"zajęte", "wolne"), W))
            if st == "summary":
                out += [fit("  " + x, W) for x in self.wiz_summary(obj, width)] + [""]
            items = self.wiz_items(obj)
            if obj["cur"] >= len(items):
                obj["cur"] = max(0, len(items) - 1)
            for i, it in enumerate(items):
                if i == obj["cur"]:
                    cur_line = len(out)
                out.append(fit((">" if i == obj["cur"] else " ") + " " + it["text"], W))
                if st == "profile" and i == obj["cur"] and it.get("sub"):
                    out.append(fit("      " + it["sub"], W))
            if not items:
                out.append(fit(u"  nic nie pasuje do filtru „%s” -- Backspace" % obj["filter"], W))
            if obj["filter"]:
                out += ["", fit(u"  filtr: %s_" % obj["filter"], W)]
        if self.message:
            out += ["", fit(u"  ! " + self.message, W)]
        return out, cur_line

    def wiz_key(self, obj, k, height):
        v, st = obj["vals"], obj["step"]
        items = self.wiz_items(obj)
        it = items[obj["cur"]] if 0 <= obj["cur"] < len(items) else None
        if obj["typing"]:
            t = obj["text"]
            if k == "esc":
                if obj["typing"] == "name":
                    self.wiz_goto(obj, "profile")
                else:
                    obj["typing"], obj["text"] = None, ""
            elif k == "bs":
                obj["text"] = t[:-1]
            elif k.startswith("text:"):
                obj["text"] += k[5:]
            elif k == "enter":
                self.message = ""
                t = t.strip()
                ty = obj["typing"]
                if ty == "host":
                    if not t:
                        self.message = u"podaj adres"
                        return
                    v["host"], v["hostname"] = t, ""
                    self.wiz_goto(obj, "diag")
                elif ty == "name":
                    v["name"] = t
                    self.wiz_goto(obj, "acct")
                    obj["cur"] = 1
                elif ty == "other":
                    if not t:
                        self.message = u"podaj nazwę konta"
                        return
                    v["other"] = t
                    self.wiz_goto(obj, "adv")
                elif ty == "port":
                    v["port"] = t if t and t != "22" else ""
                    obj["typing"], obj["text"], obj["cur"] = None, "", 1
                elif ty == "exfam":
                    v["exfam"] = ",".join(x.strip() for x in t.split(",") if x.strip())
                    obj["typing"], obj["text"], obj["cur"] = None, "", 6
                elif ty == "ds":
                    v["ds"] = [x.strip() for x in t.split(",") if x.strip()]
                    if not v["ds"]:
                        self.message = u"podaj co najmniej jedną ścieżkę"
                        return
                    self.wiz_goto(obj, "target")
                elif ty == "target":
                    if not t:
                        self.message = u"podaj ścieżkę"
                        return
                    v["target"] = t
                    self.wiz_goto(obj, "profile")
                elif ty == "profile":
                    if not t:
                        self.message = u"podaj nazwę szablonu"
                        return
                    v["profile"] = t
                    self.wiz_goto(obj, "name")
            return
        if k in ("down", "j"):
            obj["cur"] = min(obj["cur"] + 1, max(0, len(items) - 1))
        elif k in ("up", "k"):
            obj["cur"] = max(0, obj["cur"] - 1)
        elif k == "pgdn":
            obj["cur"] = min(obj["cur"] + max(1, height - 8), max(0, len(items) - 1))
        elif k == "pgup":
            obj["cur"] = max(0, obj["cur"] - max(1, height - 8))
        elif k == "home":
            obj["cur"] = 0
        elif k == "end":
            obj["cur"] = max(0, len(items) - 1)
        elif k == "bs":
            obj["filter"] = obj["filter"][:-1]
            obj["cur"] = 0
        elif k.startswith("text:") and st in ("host", "ds", "target", "profile"):
            obj["filter"] += k[5:]
            obj["cur"] = 0
        elif k == "ins" and st == "profile" and it and it.get("key") != "manual":
            pr = self.wiz_profile(obj) if it.get("key") == v["profile"] else [p for p in (obj.get("profiles") or []) if p.get("name") == it.get("key")][0]
            self.profile_form_open(pr, self.window)
        elif k == "esc":
            self.message = ""
            if obj["filter"]:
                obj["filter"] = ""
                return
            o = self.WIZ_ORDER.index(st)
            if o == 0:
                self.window, self.message = None, u"anulowano -- nic nie wykonano"
                return
            prev = self.WIZ_ORDER[o - 1]
            if prev == "diag":
                prev = "host"
            if prev == "target" and v["mode"] == "sync":
                prev = "ds"
            self.wiz_goto(obj, prev)
        elif k == "enter":
            self.message = ""
            if it is None:
                return
            key = it.get("key")
            if st == "mode":
                v["mode"] = key
                self.wiz_goto(obj, "host")
            elif st == "host":
                if key == "__other__":
                    obj["typing"], obj["text"] = "host", ""
                elif not it.get("ok", True):
                    self.message = u"z %s relacja już jest; kolejne datasety = modyfikacja relacji (CLI jeszcze nie umie)" % key
                else:
                    v["host"], v["hostname"] = key, ""
                    self.wiz_goto(obj, "diag")
            elif st == "diag":
                if key == "back":
                    self.wiz_goto(obj, "host")
                elif key == "go":
                    doc, _e = load_check(self.repo, self.files, self.data, v["host"], v["port"])
                    v["hostname"] = (doc or {}).get("hostname") or ""
                    self.wiz_goto(obj, "ds")
                elif key == "install":
                    argv = [self.zb(), "prepare-source", v["host"]] + (["--port=%s" % v["port"]] if v["port"] else []) + ["--yes"]
                    back = self.window
                    hk = "%s:%s" % (v["host"], v["port"])

                    def on_yes():
                        self.run_detached(u"Instalacja pakietu na %s" % v["host"], argv, logname="prepare-source")
                        self.data.checks.pop(hk, None)   # diagnoza od nowa po instalacji
                        self.window[1]["back_to"] = back
                    self.confirm(u"Zainstaluj pakiet na %s" % v["host"], argv,
                                 [u"git clone tego samego repozytorium, co tutaj, do /root/scripts/zfs-snapshot-all na %s, jako root przez SSH." % v["host"],
                                  u"Gdy host nie widzi origin: bundle tego checkoutu idzie przez scp. Nic więcej: bez crona, bez relacji, bez kluczy."],
                                 on_yes=on_yes)
            elif st == "ds":
                if key == "go":
                    if not v["ds"]:
                        self.message = u"zaznacz co najmniej jeden dataset (Enter na linii)"
                        return
                    self.wiz_goto(obj, "profile" if v["mode"] == "sync" else "target")
                elif key == "rec":
                    if v["recursion"] == "flat" and v["excl"]:
                        self.message = u"-r (atomic) nie ma czego filtrować: najpierw cofnij wyłączenia (%s), silnik odmawia -X pod -r" % ", ".join(v["excl"])
                        return
                    v["recursion"] = "atomic" if v["recursion"] == "flat" else "flat"
                elif key == "manual":
                    obj["typing"], obj["text"] = "ds", ",".join(v["ds"])
                else:
                    if any(key.startswith(x + "/") for x in v["ds"]):
                        # Dziecko zaznaczonego rodzica: Enter wylacza (-X) i wlacza z powrotem.
                        if v["recursion"] == "atomic":
                            self.message = u"pod -r (atomic) nie da się wyłączyć podrzędnego -- przełącz na -R"
                            return
                        if key in v["excl"]:
                            v["excl"].remove(key)
                        else:
                            v["excl"] = [x for x in v["excl"] if not x.startswith(key + "/")] + [key]
                        return
                    if key in v["ds"]:
                        v["ds"].remove(key)
                        v["excl"] = [x for x in v["excl"] if not x.startswith(key + "/")]
                    else:
                        v["ds"] = [x for x in v["ds"] if not x.startswith(key + "/")] + [key]
                        v["excl"] = [x for x in v["excl"] if x != key]
            elif st == "target":
                if key == "manual":
                    obj["typing"], obj["text"] = "target", v["target"]
                else:
                    v["target"] = key
                    self.wiz_goto(obj, "profile")
            elif st == "profile":
                if key == "manual":
                    obj["typing"], obj["text"] = "profile", v["profile"]
                else:
                    v["profile"] = key
                    self.wiz_goto(obj, "name")
            elif st == "acct":
                v["acct"] = key
                if key == "other":
                    obj["typing"], obj["text"] = "other", v["other"]
                else:
                    self.wiz_goto(obj, "adv")
            elif st == "adv":
                if key == "go":
                    self.wiz_goto(obj, "summary")
                elif key == "port":
                    obj["typing"], obj["text"] = "port", v["port"] or "22"
                elif key == "exfam":
                    obj["typing"], obj["text"] = "exfam", v["exfam"]
                elif key == "srcprof":
                    items_ = list(obj.get("profiles") or [])
                    self.window = ("pick", {"title": u"Retencja u źródła (Esc = taka sama jak tutaj)", "items": items_, "cur": 0, "field": "srcprof", "back": self.window, "allow_new": False})
                    self.scroll = 0
                elif key == "grant":
                    v["grant"] = not v["grant"]
                elif key == "manual":
                    v["manual"] = not v["manual"]
                elif key == "rec":
                    if v["recursion"] == "flat" and v["excl"]:
                        self.message = u"-r (atomic) nie ma czego filtrować: najpierw cofnij wyłączenia w kroku datasetów"
                        return
                    v["recursion"] = "atomic" if v["recursion"] == "flat" else "flat"
            elif st == "summary":
                if key == "plan":
                    self.wizard_show_plan(obj)
                else:
                    self.wizard_plan(obj["vals"])

    def wizard_show_plan(self, obj):
        argv = self.wizard_argv(obj["vals"], False)
        if self.exec_log:
            lines, rc = [u"[atrapa] plan: " + self.shell_line(argv)], 0
        else:
            try:
                p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=self.repo)
                lines, rc = p.stdout.decode("utf-8", "replace").splitlines(), p.returncode
            except OSError as e:
                self.message = u"nie udało się uruchomić planu: %s" % e
                return
        self.window = ("output", {"title": u"Plan (read-only, bez --install) -- Esc wraca do kreatora", "path": None, "proc": None,
                                  "shell": self.shell_line(argv), "lines": lines, "rc": rc, "back_to": self.window})
        self.scroll = 0

    def wizard_plan(self, vals):
        """Wykonaj: czasownik bez --install jest read-only i mowi, co by zrobil; potem potwierdzenie."""
        if not vals["host"].strip() or not vals["ds"] or (vals["mode"] != "sync" and not vals["target"].strip()):
            self.message = u"kreator: skąd (host i datasety) i dokąd są wymagane"
            return
        argv = self.wizard_argv(vals, False)
        if self.exec_log:
            plan = [u"[atrapa] plan: " + self.shell_line(argv)]
        else:
            try:
                p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=self.repo)
                plan = p.stdout.decode("utf-8", "replace").splitlines()
            except OSError as e:
                self.message = u"nie udało się uruchomić planu: %s" % e
                return
            if p.returncode != 0:
                self.window = ("output", {"title": u"Plan odmówił -- popraw odpowiedzi (Esc wraca do kreatora)", "path": None, "proc": None,
                                          "shell": self.shell_line(argv), "lines": plan, "rc": p.returncode, "back_to": self.window})
                self.scroll = 0
                return
        self.confirm(u"Nowa relacja %s z %s" % (vals["name"].strip() or "(z hosta)", vals["host"].strip()), self.wizard_argv(vals, True),
                     [u"Plan czasownika (read-only, bez --install):", ""] + sum((wrap("  " + x, 72) for x in plan), []) +
                     ["", u"--install --yes: enrol (join przez ssh) -> seed -> activate, wznawialne tą samą komendą."])

    def open_profile_pick(self, obj, key, label):
        if obj.get("profiles") is None:
            obj["profiles"], obj["perr"] = load_profiles(self.repo, self.files, self.data)
        items = list(obj.get("profiles") or [])
        cur = 0
        for i, pr in enumerate(items):
            if pr.get("name") == obj["vals"][key]:
                cur = i
        self.window = ("pick", {"title": u"Szablon dla pola: %s" % label.strip(), "items": items, "cur": cur, "field": key, "back": self.window,
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
                shown = "[x] tak" if vals[key] else "[ ] nie"
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
            out.append(fit(u" Nowy szablon powstaje z bazy: mechanizm i kształt są z bazy (inny = inna baza).", width - 4))
            out.append(fit(u" Zapis = save-profile do /etc/zfs-snapshot-all/profiles; nic zbudowanego nie rusza.", width - 4))
            out.append(fit(u" strzałki = pole, pisz = wartość, spacja = przełącz, Enter na [ ZAPISZ ], Esc = wróć", width - 4))
            if self.message:
                out += ["", fit(u" ! " + self.message, width - 4)]
            return out
        if obj.get("perr"):
            out.append(fit(u" list-profiles: błąd źródła -- wpisz nazwę szablonu ręcznie (%s)" % obj["perr"][:40], width - 4))
        else:
            out.append(fit(u" szablonów do wyboru: %d (Enter na polu Profil)" % len(obj.get("profiles") or []), width - 4))
        out.append(fit(u" strzałki = pole, pisz = wartość, Backspace, spacja = przełącz, Enter na [ PLAN ], Esc = anuluj", width - 4))
        if self.message:
            out += ["", fit(u" ! " + self.message, width - 4)]
        return out

    def picker_lines(self, obj, width):
        out = []
        if obj.get("kind") == "datasets":
            nw = max(20, width - 4 - 2 - 11 - 11 - 11)
            out.append(fit("  %-*s %-10s %10s %10s" % (nw, "dataset", "typ", u"zajęte", "wolne"), width - 4))
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
                out.append(fit(u"      %s · %s · %s · %s" % (w["shape"], w["quiesce"], w["monitor"], pr.get("description", "") or ""), width - 4))
        if not obj["items"]:
            out.append(u" brak szablonów (list-profiles nic nie zwrócił) -- wpisz nazwę ręcznie w polu")
        elif obj.get("allow_new"):
            out += ["", fit(u" Ins = nowy szablon na bazie podświetlonego (liczniki, harmonogramy, zamrażanie, progi)", width - 4)]
        return out

    def import_preview(self, path):
        """Krok 1 importu: to, co czasownik drukuje BEZ --yes, jako podglad."""
        argv = [self.zb(), "import-relation", path]
        if self.exec_log:
            preview = [u"[atrapa] podgląd: " + self.shell_line(argv)]
        else:
            try:
                p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=self.repo)
                preview = p.stdout.decode("utf-8", "replace").splitlines()
                if p.returncode != 0:
                    self.window = ("output", {"title": u"Import: podgląd odmówił", "path": None, "proc": None,
                                              "shell": self.shell_line(argv), "lines": preview, "rc": p.returncode})
                    self.scroll = 0
                    return
            except OSError as e:
                self.message = u"nie udało się uruchomić podglądu: %s" % e
                return
        self.confirm(u"Import relacji z %s" % os.path.basename(path), argv + ["--yes"],
                     [u"Podgląd (to samo, co czasownik pokazał bez --yes):", ""] + sum((wrap("  " + x, 72) for x in preview), []))

    def key(self, k, height=24, raw=None):
        """Jeden klawisz -> nowy stan. `k` to nazwa: 'down', 'F2', 'enter', 'q', 'esc'...;
        `raw` to znak (str) dla pola tekstowego."""
        self.message = ""
        if self.window and self.window[0] == "prompt":
            obj = self.window[1]
            if k == "esc":
                self.window, self.message = None, u"anulowano"
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
        if self.window and self.window[0] == "wiz":
            self.wiz_key(self.window[1], k, height)
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
                if obj.get("back") and obj["back"][0] == "wiz":
                    self.window = obj["back"]   # formularz szablonu wraca do kreatora
                else:
                    self.window, self.message = None, u"anulowano -- nic nie wykonano"
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
            elif k in ("e", "text:e"):
                # Komenda do linii polecen: widac ja, mozna poprawic, Enter wykona
                # na pierwszym planie. Nic nie rusza samo.
                self.window, self.cmd, self.hist_pos = None, obj["shell"], None
                self.message = u"komenda w linii poleceń -- popraw i Enter wykona (Esc czyści)"
            elif k in ("down", "j"):
                self.scroll += 1
            elif k in ("up", "k"):
                self.scroll = max(0, self.scroll - 1)
            elif k == "pgdn":
                self.scroll += max(1, height - 4)
            elif k == "pgup":
                self.scroll = max(0, self.scroll - max(1, height - 4))
            else:
                self.window, self.message = None, u"anulowano -- nic nie wykonano"
            return "stay"
        if self.window and self.window[0] == "output":
            if k in ("esc", "q", "enter"):
                obj = self.window[1]
                if obj.get("back_to"):
                    self.window, self.scroll = obj["back_to"], 0
                    return "stay"
                self.window, self.scroll = None, 0
                if obj.get("proc") is not None and obj["proc"].poll() is None:
                    self.message = u"proces biegnie dalej (pid %d); wyjście: %s" % (obj["proc"].pid, obj["path"])
                self.refresh()
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
        FKEYS = ("F1", "F2", "F3", "F4", "F5", "F6", "F10")
        if self.cmd and k not in FKEYS:
            if k == "bs":
                self.cmd = self.cmd[:-1]
            elif k in ("esc", "ctrl-u"):
                self.cmd, self.hist_pos = "", None
            elif k == "enter":
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
        if k in ("q", "F10"):
            return "quit"
        if k == "F1":
            self.window, self.scroll = ("pomoc", None), 0
            return "stay"
        if k == "tab" and self.screen == "relacje":
            self.focus = "pairs" if self.focus == "list" else "list"
            return "stay"
        if self.screen == "relacje" and self.focus == "pairs" and self.rows:
            row = self.rows[self.cursor["relacje"]]
            pairs, _how = rel_pairs(row, self.data, self.now(), self.ch)
            n = len(pairs)
            c = self.pair_cursor
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
            elif k == "esc":
                self.focus = "list"
            elif k == "enter" and n:
                j = pairs[c].get("job")
                if j is None:
                    self.message = u"ta para jest z rekordu, nie z crona -- nie ma zadania na F2"
                else:
                    for i, jr in enumerate(self.jobrows):
                        if jr.get("job") is j:
                            self.cursor["zadania"], self.screen, self.focus = i, "zadania", "list"
                            break
            elif k in ("F4", "del", "F7", "F8", "ins"):
                res = self.action(k)
                if res:
                    return res
            else:
                for key, fk, _label in SCREENS:
                    if k == fk and k != "F4":
                        self.screen, self.focus = key, "list"
            self.pair_cursor = c
            return "stay"
        # F4 na F3 to PAUZA, nie ekran Transfery (tam prowadzi F4 z innych ekranow):
        # tak stoi w makiecie wlasciciela i w listwie stopki.
        for key, fk, _label in SCREENS:
            if k == fk and not (k == "F4" and self.screen == "relacje"):
                self.screen = key
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
        elif k in ("F9", "ctrl-r", "F5r"):
            self.refresh()
            self.message = u"odświeżono %s" % time.strftime("%H:%M:%S", time.localtime(self.now()))
        elif k in ("F4", "del", "F7", "F8", "ins") and self.screen == "relacje":
            return self.action(k) or "stay"
        elif k == "enter" and n:
            if self.screen == "relacje":
                self.window, self.scroll = ("relacja", self.rows[c]), 0
            elif self.screen == "zadania":
                self.window, self.scroll = ("relacja", self.jobrows[c]), 0
            else:
                # Pozostale ekrany maja panel szczegolow; Enter otwiera go jako
                # okno, zeby dlugie wartosci nie byly ucinane.
                self.window, self.scroll = ("panel", self.panel_lines()), 0
        if self.screen == "relacje" and c != self.cursor["relacje"]:
            self.pair_cursor = 0
        self.cursor[self.screen] = c
        return "stay"

    def panel_lines(self):
        now, ch = self.now(), self.ch
        c = self.cursor[self.screen]
        if self.screen == "transfery":
            r, d = build_transfers(self.data, now)
            t = (r + d)[c]
            return {"kind": "panel", "name": "transfer %s" % (t.get("label") or ""), "pairs": transfer_detail_pairs(t, now, ch)}
        if self.screen == "monitor":
            m = monitor_rows(self.data)[c]
            return {"kind": "panel", "name": "monitor %s" % (m.get("label") or ""), "pairs": monitor_detail_pairs(m, ch, full=True)}
        rp = (self.data.replicas or {}).get("replicas", [])[c]
        return {"kind": "panel", "name": u"nośnik %s" % rp.get("name"), "pairs": replica_detail_pairs(rp, ch)}


def relation_window_lines_dispatch(ui, obj, width):
    if obj.get("kind") == "panel":
        return detail_kv(ui.ch, obj["pairs"], width - 4)
    return relation_window_lines(obj, ui.data, ui.now(), ui.ch, width, ui.repo, ui.files)


# render() w UI korzysta z tej wersji, zeby okno-panel i okno-relacja szly ta sama droga.
def _ui_render(self, width, height):
    width = max(MIN_WIDTH, width)
    now = self.now()
    # Ekran jest o jedna linie nizszy: nad listwa klawiszy stoi LINIA POLECEN.
    sh = height - 1
    if self.screen == "zadania":
        base = render_zadania(self.data, self.jobrows, self.cursor["zadania"], width, sh, now, self.ch, self.message)
    elif self.screen == "relacje":
        base = render_relacje(self.data, self.rows, self.cursor["relacje"], width, sh, now, self.ch, self.message,
                              focus=self.focus, pair_cursor=self.pair_cursor)
    elif self.screen == "transfery":
        base = render_transfery(self.data, self.cursor["transfery"], width, sh, now, self.ch, self.message)
    elif self.screen == "monitor":
        base = render_monitor(self.data, self.cursor["monitor"], width, sh, now, self.ch, self.message)
    else:
        base = render_nosniki(self.data, self.cursor["nosniki"], width, sh, now, self.ch, self.message)
    if not self.window:
        cl = self.prompt_text() + self.cmd + "_"
        if len(cl) > width:
            # Dluga komenda: widac jej KONIEC (tam sie pisze), poczatek za ellipsa.
            cl = self.ch.ell + cl[len(cl) - width + 1:]
        base.lines.insert(len(base.lines) - 1, fit(cl, width))
        base.bars = {0, len(base.lines) - 1}
        base.cmd_y = len(base.lines) - 2
    if self.window:
        kind, obj = self.window
        if kind == "pomoc":
            scr, self.scroll = render_window(base, "Pomoc", HELP, self.scroll, width, height, self.ch)
        elif kind == "prompt":
            lines = ["", " " + obj["label"], "", fit("  > " + obj["value"] + "_", width - 4), "",
                     u" Klawisze: pisz, Backspace kasuje, Enter zatwierdza, Esc anuluje."]
            scr, self.scroll = render_window(base, obj["title"], lines, 0, width, height, self.ch, footer=u"Enter dalej   Esc anuluj")
        elif kind == "confirm":
            scr, self.scroll = render_window(base, u"POTWIERDZENIE: " + obj["title"], obj["lines"], self.scroll, width, height, self.ch,
                                             footer=u"t wykonaj   e do linii poleceń   Esc anuluj")
        elif kind == "wiz":
            lines, cur = self.wiz_lines(obj, width)
            inner_h = height - 3
            wscroll = 0
            if cur is not None and cur >= inner_h - 2:
                wscroll = cur - (inner_h - 2) + 1
            st = obj["step"]
            title = u"Nowa relacja -- krok %d/%d: %s" % (self.WIZ_STEPNO[st], self.WIZ_NSTEP, self.WIZ_TITLES[st])
            foot = u"↑↓ wybór   Enter = %s   Esc = %s%s" % (u"zaznacz / dalej" if st == "ds" else u"wybierz i dalej",
                                                             u"anuluj" if st == "mode" and not obj["typing"] else u"wstecz",
                                                             u"   pisz = filtruj listę" if st in ("host", "ds", "target", "profile") and not obj["typing"] else "")
            if st == "profile" and not obj["typing"]:
                foot += u"   Ins = nowy szablon"
            scr, self.scroll = render_window(base, title, lines, wscroll, width, height, self.ch, footer=foot)
            if cur is not None:
                scr.cursor_y = 2 + cur - wscroll
            return scr
        elif kind == "form":
            lines = self.form_lines(obj, width)
            # Dlugi formularz (nowy szablon) przewija sie za kursorem.
            cy = obj.get("_cur_y", 0)
            fscroll = 0 if cy + 2 < height - 3 else cy + 2 - (height - 3) + 1
            scr, self.scroll = render_window(base, obj["title"], lines, fscroll, width, height, self.ch,
                                             footer=u"Enter na [ ZAPISZ ] = dalej   Esc = wróć")
        elif kind == "pick":
            scr, self.scroll = render_window(base, obj["title"], self.picker_lines(obj, width), self.scroll, width, height, self.ch,
                                             footer=u"Enter wybiera   Esc wraca bez zmiany")
            per = 1 if obj.get("kind") == "datasets" else 2
            if obj["cur"] * per >= height - 4:
                scr, self.scroll = render_window(base, obj["title"], self.picker_lines(obj, width), obj["cur"] * per - (height - 6), width, height, self.ch,
                                                 footer=u"Enter wybiera   Esc wraca bez zmiany")
        elif kind == "output":
            lines = self.output_lines(obj, width)
            if self.scroll == 0 and obj.get("proc") is not None and obj["proc"].poll() is None:
                self.scroll = 10 ** 6   # ogon: pokazuj koniec, jak tail -f
            scr, self.scroll = render_window(base, u"WYJŚCIE: " + obj["title"], lines, self.scroll, width, height, self.ch,
                                             footer=u"Esc zamyka okno (proces zostaje)   strzałki przewijają")
        else:
            title = (u"Relacja %s" % obj["name"]) if obj.get("kind") == "relation" else obj["name"]
            lines = relation_window_lines_dispatch(self, obj, width)
            scr, self.scroll = render_window(base, title, lines, self.scroll, width, height, self.ch)
        return scr
    return base


def deaccent(text):
    """Terminal bez UTF-8 dostaje slowa bez ogonkow, nie krzaczki (zasada 10)."""
    return text.translate(_DEACCENT)


_DEACCENT = {ord(a): b for a, b in zip(u"ąćęłńóśźżĄĆĘŁŃÓŚŹŻ", u"acelnoszzACELNOSZZ")}
_DEACCENT[ord(u"→")] = ">"
_DEACCENT[ord(u"←")] = "<"


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
def curses_loop(ui):
    import curses

    # Bez tego ncurses liczy bajty zamiast znakow i rozjezdza kolumny.
    locale.setlocale(locale.LC_ALL, "")

    def paint(stdscr, scr, h, w):
        stdscr.erase()
        for y, line in enumerate(scr.lines[:h]):
            line = line[:w - 1]
            base = 0
            if y in scr.bars:
                base = curses.color_pair(6) if curses.has_colors() else curses.A_REVERSE
            elif y == scr.cursor_y:
                base = curses.A_REVERSE
            try:
                stdscr.addstr(y, 0, line, base)
            except curses.error:
                pass
            if y in scr.bars or y == scr.cursor_y or not curses.has_colors():
                continue
            for word, pair in COLOR_WORDS:
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

    KEYMAP = {}

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
                curses.init_pair(6, curses.COLOR_BLACK, curses.COLOR_CYAN)
            except curses.error:
                pass
        KEYMAP.update({curses.KEY_DOWN: "down", curses.KEY_UP: "up", curses.KEY_NPAGE: "pgdn", curses.KEY_PPAGE: "pgup",
                       curses.KEY_HOME: "home", curses.KEY_END: "end", curses.KEY_F1: "F1", curses.KEY_F2: "F2",
                       curses.KEY_F3: "F3", curses.KEY_F4: "F4", curses.KEY_F5: "F5", curses.KEY_F6: "F6",
                       curses.KEY_F7: "F7", curses.KEY_F8: "F8", curses.KEY_IC: "ins", curses.KEY_DC: "del",
                       curses.KEY_BACKSPACE: "bs", 127: "bs", 8: "bs", curses.KEY_ENTER: "enter",
                       10: "enter", 13: "enter", 27: "esc", ord("q"): "q", ord("j"): "j", ord("k"): "k", ord("r"): "r",
                       ord("t"): "t", ord("e"): "e", ord("1"): "F2", ord("2"): "F3", ord("3"): "F4", ord("4"): "F5", ord("5"): "F6",
                       ord("?"): "F1", ord("h"): "F1", curses.KEY_F10: "F10", curses.KEY_F9: "F9", 9: "tab",
                       21: "ctrl-u", 18: "ctrl-r"})
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
               "[15~": "F5", "[17~": "F6", "[18~": "F7", "[19~": "F8", "[20~": "F9", "[21~": "F10", "[[A": "F1", "[[B": "F2", "[[C": "F3", "[[D": "F4", "[[E": "F5"}

        def wch():
            """(kod, czy_znak): get_wch odroznia znak od klawisza; -1 = nic."""
            try:
                k = stdscr.get_wch()
            except curses.error:
                return -1, False
            if isinstance(k, str):
                return ord(k), True
            return k, False

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
            h, w = stdscr.getmaxyx()
            if h < 10 or w < 40:
                stdscr.erase()
                try:
                    stdscr.addstr(0, 0, "za maly terminal (%dx%d); minimum 40x10" % (w, h))
                except curses.error:
                    pass
                stdscr.refresh()
            else:
                paint(stdscr, ui.render(w, h), h, w)
            # Na ekranie transferow postep zyje: co 2 s czytamy TYLKO progress
            # (to pliki, nie komenda), i curses maluje roznice, nie ekran.
            if ui.window and ui.window[0] == "output" and ui.window[1].get("proc") is not None and ui.window[1]["proc"].poll() is None:
                stdscr.timeout(500)          # ogon pliku wyjscia zyje
            else:
                stdscr.timeout(2000 if ui.screen == "transfery" and not ui.window else -1)
            k, seqname, is_char = read_key()
            if k == -1:
                if not ui.window:
                    ui.refresh("progress")
                continue
            if k == curses.KEY_RESIZE:
                continue
            name = seqname if k == -2 else KEYMAP.get(k)
            # W polu tekstowym KAZDY drukowalny znak jest wejsciem, nie klawiszem
            # skrotu -- inaczej sciezki z 'q' albo 'j' nie daloby sie wpisac.
            if ui.window and ui.window[0] == "form" and k == 32:
                ui.key("space", h)
                continue
            if ui.window and ui.window[0] in ("prompt", "form", "wiz") and is_char and name not in ("esc", "enter", "bs", "up", "down") and 32 <= k < 0x110000:
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
            if res == "shell" and ui.pending_shell:
                line, ui.pending_shell = ui.pending_shell, None
                nowait, ui.pending_nowait = ui.pending_nowait, False
                curses.endwin()
                if not nowait:
                    sys.stdout.write("$ %s\n" % line)
                    sys.stdout.flush()
                try:
                    rc = subprocess.call(line, shell=True, cwd=ui.repo)
                except (OSError, KeyboardInterrupt) as e:
                    rc = "?"
                    sys.stdout.write("%s\n" % e)
                if not nowait:
                    sys.stdout.write("[rc=%s]  Enter wraca do okien\n" % rc)
                    sys.stdout.flush()
                    try:
                        sys.stdin.readline()
                    except (IOError, KeyboardInterrupt):
                        pass
                stdscr.clear()
                stdscr.refresh()
                ui.refresh()
                ui.message = u"[rc=%s] %s" % (rc, line)
                before = getattr(ui, "rel_names_before", None)
                ui.rel_names_before = None
                if before is not None and ui.cursor_to_new(before):
                    ui.message = u"[rc=%s] %s  --  kursor na nowej relacji" % (rc, line)
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
    ap.add_argument("--wizard", choices=("whiptail", "curses"), default="whiptail",
                    help="Ins na F3: whiptail = zfs-backup.sh new-relation (domyslnie); curses = stary kreator (tylko jego suita)")
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
    ap.add_argument("--offline", action="store_true", help="nie uruchamiaj czasownikow; zrodla bez pliku sa puste")
    a = ap.parse_args(argv)
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    files = {"status": a.status, "jobs": a.jobs, "monitors": a.monitors, "progress": a.progress,
             "replicas": a.replicas, "stats": a.stats, "config": a.config, "profiles": a.profiles, "offline": a.offline,
             "datasets_local": a.datasets_local, "datasets_remote": a.datasets_remote, "check_source": a.check_source}
    ch = Chars(want_ascii(a))
    ui = UI(repo, files, ch, a.now, a.exec_log, a.wizard)
    if a.render_once:
        ui.screen = a.screen
        for k in [x for x in a.keys.split(",") if x]:
            if ui.key(k, a.height) == "quit":
                break
        print("\n".join(ui.render(a.width, a.height).lines))
        return 0
    if not sys.stdout.isatty():
        sys.stderr.write("gui: to nie jest terminal -- uzyj --render-once, zeby zobaczyc ekran\n")
        return 2
    curses_loop(ui)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
