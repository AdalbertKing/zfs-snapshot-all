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
import json
import locale
import os
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
        self.status = self.jobs = self.monitors = self.progress = self.replicas = None
        self.errors = {}
        self.configs = {}     # show-config NAME --json, na zadanie
        self.read_at = 0

    def failed(self, key):
        return self.errors.get(key)


def collect(repo, files, only=None):
    """Czytaj z plikow (testy, podglad) albo z czasownikow. `only` = jedno zrodlo."""
    data = files.get("_data") or Data()
    files["_data"] = data
    plan = [("status", ["status", "--json"]), ("jobs", ["list-jobs", "--json"]),
            ("monitors", ["monitor", "--json"]), ("progress", ["progress", "--json"]),
            ("replicas", ["list-replicas", "--json"])]
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
        rows.append({
            "kind": "relation", "name": name, "rel": rel, "state": state_word(rel),
            "dir": direction_of(host, rel.get("peer_host") or "", [x.get("direction", "") for x in my_jobs if x.get("section_kind") == "dataset"]),
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
        rows.append({
            "kind": "job", "name": j.get("scope", ""), "rel": None,
            "dir": direction_of((data.jobs or {}).get("host") or "?", j.get("peer") or "", [j.get("direction", "")]),
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
            "state": "nieczytelny", "verdict": "UNKNOWN", "vword": "nie odpowiada",
            "reasons": [u.get("error", "")], "monitors": [], "last": None,
            "last_txt": "%s linii w cronie" % u.get("lines_in_block", "?"), "transfers": [],
            "jobs": [], "next_epoch": None, "next": "?", "u": u,
        })
    # Usuniete rekordy na koncu: sa faktem, ale nie robota.
    rows.sort(key=lambda r: 1 if (r.get("rel") or {}).get("state") == "removed" else 0)
    return rows


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
        rows.append({
            "kind": "job", "name": j.get("label") or "(bez rel.)", "rel": None,
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
        nw = max(8, min(16, max([len(r["name"]) for r in rows] + [8])))
        dw = max(8, min(24, max([len(r["dir"]) for r in rows] + [8])))
        # Harmonogram jest kolumna dopiero od 100 kolumn; przy 80 zostaje w panelu.
        show_sched = width >= 100
        tw, hw, vw = 16, (12 if show_sched else 0), 13
        rest = inner - (nw + dw + tw + hw + vw + (5 if show_sched else 4))
        if rest < 12:
            dw = max(8, dw + rest - 12)
            rest = inner - (nw + dw + tw + hw + vw + (5 if show_sched else 4))
        if show_sched:
            hdr = "%s %s %s %s %s %s" % (fit("Relacja", nw), fit("Kierunek", dw), fit("Zadanie", tw), fit("Zakres", rest), fit("Harmonogram", hw), fit("Kopie", vw))
        else:
            hdr = "%s %s %s %s %s" % (fit("Relacja", nw), fit("Kierunek", dw), fit("Zadanie", tw), fit("Zakres", rest), fit("Kopie", vw))
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
            if show_sched:
                body.append("%s %s %s %s %s %s" % (fit(r["name"], nw, ch), fit(r["dir"], dw, ch), fit(r["task"], tw, ch),
                                                   fit_left(r["scope"], rest, ch), fit(r["schedule"], hw, ch), fit(r["vword"], vw, ch)))
            else:
                body.append("%s %s %s %s %s" % (fit(r["name"], nw, ch), fit(r["dir"], dw, ch), fit(r["task"], tw, ch),
                                                fit_left(r["scope"], rest, ch), fit(r["vword"], vw, ch)))
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
        self.lines, self.cursor_y, self.bars, self.titles = [], None, set(), set()


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
    parts.append(u"q Wyjście")
    line = " " + " ".join(parts)
    if extra and width >= len(line) + len(extra) + 1:
        line += " " + extra
    if width >= len(line) + 11:
        line += u" r Odśwież"
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
        pairs = [("zakres", j.get("scope", "?")),
                 ("kierunek", "%s   %s  %s" % (row.get("dir", "?"), ch.arrows.get(j.get("direction", ""), "?").format(peer=j.get("peer") or "?"),
                                              (j.get("other_end") or ""))),
                 ("harmonogram", "%s  (%s)" % (j.get("schedule", "?"), row["next"])),
                 ("szczebel", (row.get("tier") or j.get("tier") or "?") + ("  (sekcja %s)" % j.get("section_kind", "?"))),
                 ("rodzina", family_of(j) or "?"),
                 ("trzyma", (j.get("retain") or j.get("keep") or "-") + ("  drabina GFS" if j.get("gfs") else "")),
                 ("kopie", row["vword"] + ("  " + row["reasons"][0].splitlines()[0] if row["reasons"] else "")),
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


def render_relacje(data, rows, cursor, width, height, now, ch, message=""):
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
    # Szerokosci kolumn: nazwa rosnie z danymi, reszta ma stale minimum.
    beside = width >= 120
    lbw = max(MIN_WIDTH, int(width * 0.6)) if beside else width
    inner = lbw - 4
    # Kolumny rosna z danymi, a "Nastepny" dostaje reszte, nie mniej niz 10.
    nw = max(8, min(24, max([len(r["name"]) for r in rows] + [8])))
    dw = max(8, min(24, max([len(r.get("dir", "")) for r in rows] + [8])))
    sw = max(14, min(20, max([len(r["state"]) for r in rows] + [14])))
    vw = 13
    nw = max(8, min(nw, inner - (dw + sw + vw + 4) - 12))
    rest = inner - (nw + dw + sw + vw + 4)
    if rest < 12:
        dw = max(8, dw + rest - 12)
        rest = inner - (nw + dw + sw + vw + 4)
    hdr = "%s %s %s %s %s" % (fit("Relacja", nw), fit("Kierunek", dw), fit("Stan", sw), fit("Kopie", vw), fit(u"Następny", rest))
    body = [hdr, ch.dash * inner]
    if not rows:
        body += [u"Zero relacji i zero zadań na tym hoście.",
                 u"To NIE znaczy 'host nic nie robi' -- znaczy, że nie ma tu rekordu relacji",
                 u"ani bloku zfs-backup-managed w crontabie żadnego konta."]
    # Panel: pod lista przy <120 kolumnach, obok od 120.
    panel_h = 0 if beside else 9
    list_h = max(3, height - 2 - 2 - panel_h - 2)   # paski + krawedzie + panel
    first = 0
    if cursor >= list_h:
        first = cursor - list_h + 1
    cur_y = None
    for i, r in enumerate(rows[first:first + list_h], start=first):
        name = fit_left(r["name"], nw, ch) if r["kind"] == "job" else fit(r["name"], nw, ch)
        line = "%s %s %s %s %s" % (name, fit(r.get("dir", ""), dw, ch), fit(r["state"], sw, ch),
                                   fit(r["vword"], vw, ch), fit(r["next"], rest, ch))
        if i == cursor:
            cur_y = len(body)
        body.append(line)
    if len(rows) > first + list_h:
        body.append(fit(u"... jeszcze %d" % (len(rows) - first - list_h), inner))
    while len(body) < list_h + 2:
        body.append("")
    footer = (u"Enter szczegóły  F4 pauza  Del usuń  F7 eksport  F8 import  Ins nowa" if width >= 100
              else u"Enter F4:pauza Del F7:eksport F8:import Ins") if rows else ""
    listbox = box(ch, title, body, lbw, footer=footer)
    if cur_y is not None:
        scr.cursor_y = 1 + 1 + cur_y   # pasek tytulu + gorna krawedz
    scr.titles.add(1)
    scr.titles.add(len(listbox))
    panel = []
    if rows and 0 <= cursor < len(rows):
        r = rows[cursor]
        pw = (width - max(MIN_WIDTH, int(width * 0.6))) if beside else width
        ptitle = u"%s -- szczegóły" % r["name"]
        pl = detail_kv(ch, rel_detail_pairs(r, data, now, ch), pw - 4)
        if beside:
            pl = pl[:len(listbox) - 2]
            while len(pl) < len(listbox) - 2:
                pl.append("")
        else:
            pl = pl[:panel_h - 2]
            while len(pl) < panel_h - 2:
                pl.append("")
        panel = box(ch, ptitle, pl, pw, double=False)
    if beside:
        body_lines = side_by_side(listbox, panel, width, ch) if panel else listbox
        scr.lines = [top_bar(data, width, now, ch.ascii, len(data.errors))] + body_lines
    else:
        scr.lines = [top_bar(data, width, now, ch.ascii, len(data.errors))] + listbox + panel
        if panel:
            scr.titles.add(len(listbox) + 1)
    scr.bars.add(0)
    if message:
        scr.lines.append(fit(" " + message, width))
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
    u"  F2  Zadania    co chodzi w cronie: relacja, kierunek, zadanie, zakres, kopie",
    u"  F3  Relacje    zarządzanie: Enter szczegóły, F4 pauza/wznów, Del usuń,",
    u"                 F7 eksport do pliku, F8 import z pliku, Ins nowa (wkrótce)",
    u"                 Akcja: NAJPIERW komenda bash, potem 't', potem wyjście",
    u"                 na żywo. Esc zamyka okno, a proces biegnie dalej.",
    u"  F4  Transfery  co leci teraz i co skończyło się ostatnio (progress)",
    u"  F5  Monitor    każda linia monitora z werdyktem i powodem (monitor)",
    u"  F6  Nośniki    repliki na dyskach wymiennych i cztery stany nośnika",
    u"  Kierunek       lewa strona to ZAWSZE ten host: pve10>pve9 wysyłam,",
    u"                 pve10<pve9 pobieram, pve10<>pve9 obie strony, local",
    "",
    u"  strzałki / j k    ruch po liście     PgUp PgDn Home End   szybciej",
    u"  r                 odśwież źródła (monitor liczy na żywo, to chwilę trwa)",
    u"  Esc               zamknij okno na wierzchu",
    u"  q                 wyjście",
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
        self.now_fixed = now
        self.exec_log = exec_log   # testy: zamiast uruchamiac, zapisz komende tutaj
        self.screen = "zadania"
        self.cursor = {"zadania": 0, "relacje": 0, "transfery": 0, "monitor": 0, "nosniki": 0}
        self.window = None        # ("relacja", row) | ("pomoc", None) | ("prompt"|"confirm"|"output", dict)
        self.scroll = 0
        self.message = ""
        self.data = collect(repo, files)
        self.rows = build_relations(self.data, self.now())
        self.jobrows = build_jobs(self.data, self.now())

    def now(self):
        return self.now_fixed if self.now_fixed is not None else int(time.time())

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

    def current_relation(self):
        """Relacja pod kursorem na F3, albo powod, dla ktorego akcji nie ma."""
        if self.screen != "relacje":
            return None, u"akcje na relacjach są na ekranie F3 Relacje"
        if not self.rows:
            return None, u"brak relacji"
        r = self.rows[self.cursor["relacje"]]
        if r["kind"] != "relation":
            return None, u"to nie jest relacja (%s) -- akcje dotyczą rekordów relacji" % ("zadanie bez rekordu" if r["kind"] == "job" else "nieczytelny blok")
        if r["rel"].get("state") == "removed":
            return None, u"relacja '%s' jest już usunięta (removed_at %s)" % (r["name"], r["rel"].get("removed_at") or "?")
        return r, ""

    def confirm(self, title, argv, note_lines=None, redirect=None, on_yes=None):
        line = self.shell_line(argv, redirect)
        lines = [u"Wykona się DOKŁADNIE to:", ""] + wrap("  " + line, 72) + [""]
        if note_lines:
            lines += note_lines + [""]
        lines += [u"t = wykonaj      Esc / inny klawisz = anuluj"]
        self.window = ("confirm", {"title": title, "lines": lines, "argv": argv, "redirect": redirect,
                                   "shell": line, "on_yes": on_yes})
        self.scroll = 0

    def prompt(self, title, label, value, on_enter):
        self.window = ("prompt", {"title": title, "label": label, "value": value, "on_enter": on_enter})
        self.scroll = 0

    def run_detached(self, title, argv, redirect=None):
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
        path = os.path.join(logdir, "%s-%s.log" % (argv[1] if len(argv) > 1 else "cmd", stamp))
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
        r, why = self.current_relation()
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
            self.confirm(u"Usuń relację %s" % n, [self.zb(), "remove-client", n],
                         [u"Usuwa sekcje configu i linie crona TEJ relacji. KOPII na dysku nie rusza --",
                          u"to osobna, świadoma decyzja. Parowanie z peerem zostaje, jeśli używa go inna relacja."])
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
            self.message = u"kreator nowej relacji to następny etap; dziś: zfs-backup.sh add-client NAME --host=HOST --profile=... (usage)"

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
        if self.window and self.window[0] == "confirm":
            obj = self.window[1]
            if k in ("t", "text:t"):
                self.window = None
                if obj.get("on_yes"):
                    obj["on_yes"]()
                else:
                    self.run_detached(obj["title"], obj["argv"], obj.get("redirect"))
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
        if k == "q":
            return "quit"
        if k == "F1":
            self.window, self.scroll = ("pomoc", None), 0
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
        elif k in ("r", "F5r"):
            self.refresh()
            self.message = u"odświeżono %s" % time.strftime("%H:%M:%S", time.localtime(self.now()))
        elif k in ("F4", "del", "F7", "F8", "ins") and self.screen == "relacje":
            self.action(k)
            return "stay"
        elif k == "enter" and n:
            if self.screen == "relacje":
                self.window, self.scroll = ("relacja", self.rows[c]), 0
            elif self.screen == "zadania":
                self.window, self.scroll = ("relacja", self.jobrows[c]), 0
            else:
                # Pozostale ekrany maja panel szczegolow; Enter otwiera go jako
                # okno, zeby dlugie wartosci nie byly ucinane.
                self.window, self.scroll = ("panel", self.panel_lines()), 0
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
    if self.screen == "zadania":
        base = render_zadania(self.data, self.jobrows, self.cursor["zadania"], width, height, now, self.ch, self.message)
    elif self.screen == "relacje":
        base = render_relacje(self.data, self.rows, self.cursor["relacje"], width, height, now, self.ch, self.message)
    elif self.screen == "transfery":
        base = render_transfery(self.data, self.cursor["transfery"], width, height, now, self.ch, self.message)
    elif self.screen == "monitor":
        base = render_monitor(self.data, self.cursor["monitor"], width, height, now, self.ch, self.message)
    else:
        base = render_nosniki(self.data, self.cursor["nosniki"], width, height, now, self.ch, self.message)
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
                                             footer=u"t wykonaj   Esc anuluj")
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
        # Komunikat ZAWSZE tuz nad listwa klawiszy -- panel nie ma prawa go zepchnac
        # poza ekran (tak bylo: odmowa akcji na usunietym rekordzie znikala).
        scr.lines[-2] = fit(" " + self.message, max(MIN_WIDTH, width))
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
            line = fit(line, w - 1)
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
                       ord("t"): "t", ord("1"): "F2", ord("2"): "F3", ord("3"): "F4", ord("4"): "F5", ord("5"): "F6",
                       ord("?"): "F1", ord("h"): "F1"})
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
               "[15~": "F5", "[17~": "F6", "[18~": "F7", "[19~": "F8", "[[A": "F1", "[[B": "F2", "[[C": "F3", "[[D": "F4", "[[E": "F5"}

        def read_key():
            k = stdscr.getch()
            if k != 27:
                return k, None
            stdscr.nodelay(True)
            seq = ""
            try:
                deadline = time.time() + 0.15
                while time.time() < deadline and len(seq) < 6:
                    c = stdscr.getch()
                    if c == -1:
                        time.sleep(0.01)
                        continue
                    if c > 255:
                        break
                    seq += chr(c)
                    if seq in SEQ or (seq.startswith("[") and seq.endswith("~")) or (seq.startswith("O") and len(seq) == 2):
                        break
            finally:
                stdscr.nodelay(False)
            if not seq:
                return 27, None
            if seq in SEQ:
                return -2, SEQ[seq]
            # Nie nasza sekwencja (np. ESC, a chwile pozniej 'q'): oddaj bajty
            # z powrotem, w kolejnosci, i zglos goly Esc. Bez tego 'q' po Esc
            # gineło i TUI wisiało -- zmierzone na pve10 2026-09-09 (jazda 6).
            for ch_ in reversed(seq):
                try:
                    curses.ungetch(ord(ch_))
                except curses.error:
                    pass
            return 27, None
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
            k, seqname = read_key()
            if k == -1:
                if not ui.window:
                    ui.refresh("progress")
                continue
            if k == curses.KEY_RESIZE:
                continue
            name = seqname if k == -2 else KEYMAP.get(k)
            # W polu tekstowym KAZDY drukowalny znak jest wejsciem, nie klawiszem
            # skrotu -- inaczej sciezki z 'q' albo 'j' nie daloby sie wpisac.
            if ui.window and ui.window[0] == "prompt" and name not in ("esc", "enter", "bs") and 32 <= k < 0x110000:
                try:
                    ch_ = chr(k)
                except ValueError:
                    continue
                ui.key("text:" + ch_, h)
                continue
            if name is None:
                continue
            if ui.key(name, h) == "quit":
                return
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
    ap.add_argument("--config", help="czytaj show-config --json z pliku (okno relacji)")
    ap.add_argument("--offline", action="store_true", help="nie uruchamiaj czasownikow; zrodla bez pliku sa puste")
    a = ap.parse_args(argv)
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    files = {"status": a.status, "jobs": a.jobs, "monitors": a.monitors, "progress": a.progress,
             "replicas": a.replicas, "config": a.config, "offline": a.offline}
    ch = Chars(want_ascii(a))
    ui = UI(repo, files, ch, a.now, a.exec_log)
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
