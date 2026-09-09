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

SCREENS = [("relacje", "F2", "Relacje"), ("transfery", "F3", "Transfery"),
           ("monitor", "F4", "Monitor"), ("nosniki", "F5", u"Nośniki")]


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
        rows.append({
            "kind": "relation", "name": name, "rel": rel, "state": state_word(rel),
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
            "state": "bez rekordu (%s)" % j.get("direction", "?"),
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
            "kind": "unreadable", "name": "konto %s" % u.get("account", "?"), "rel": None,
            "state": "config nieczytelny", "verdict": "UNKNOWN", "vword": "nie odpowiada",
            "reasons": [u.get("error", "")], "monitors": [], "last": None,
            "last_txt": "%s linii w cronie" % u.get("lines_in_block", "?"), "transfers": [],
            "jobs": [], "next_epoch": None, "next": "?", "u": u,
        })
    # Usuniete rekordy na koncu: sa faktem, ale nie robota.
    rows.sort(key=lambda r: 1 if (r.get("rel") or {}).get("state") == "removed" else 0)
    return rows


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
    mid = "%s | konto %s" % (host, acct)
    right = u"odczyt %s%s " % (time.strftime("%H:%M:%S", time.localtime(data.read_at or now)),
                               u"  ! %d źródła bez odpowiedzi" % err_count if err_count else "")
    gap = width - len(left) - len(mid) - len(right)
    if gap < 2:
        line = fit(left + "  " + mid + "  " + right, width)
    else:
        line = left + " " * (gap // 2) + mid + " " * (gap - gap // 2) + right
    return fit(line, width)


def key_bar(active, width, extra=""):
    """Listwa F-klawiszy. Przy 80 kolumnach miesci sie DOKLADNIE, wiec kazde
    slowo tu jest policzone; przy szerszym terminalu dochodzi odswiezenie."""
    parts = ["F1 Pomoc"]
    for key, fk, label in SCREENS:
        parts.append(("[%s %s]" if key == active else "%s %s") % (fk, label))
    if extra:
        parts.append(extra)
    parts.append(u"q Wyjście")
    line = " " + " ".join(parts)
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
                 ("kierunek", ch.arrows.get(j.get("direction", ""), "?").format(peer=j.get("peer") or "?")
                  + "  " + (j.get("other_end") or "")),
                 ("harmonogram", "%s  (%s)" % (j.get("schedule", "?"), row["next"])),
                 ("rodzina", family_of(j) or "?"),
                 ("kopie", row["vword"] + ("  " + row["reasons"][0] if row["reasons"] else ""))]
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
        scr.lines = box(ch, "Relacje na kolektorze %s" % host, body, width)
        return scr
    live = [r for r in rows if not (r["kind"] == "relation" and r["rel"].get("state") == "removed")]
    title = "Relacje na kolektorze %s (%d)" % (host, len(live))
    # Szerokosci kolumn: nazwa rosnie z danymi, reszta ma stale minimum.
    beside = width >= 120
    lbw = max(MIN_WIDTH, int(width * 0.6)) if beside else width
    inner = lbw - 4
    nw = max(8, min(24, max([len(r["name"]) for r in rows] + [8])))
    sw = 14
    vw = 13
    lw = 18
    rest = inner - (nw + sw + vw + lw + 4)
    if rest < 10:
        lw = max(12, lw + rest - 10)
        rest = inner - (nw + sw + vw + lw + 4)
    hdr = "%s %s %s %s %s" % (fit("Relacja", nw), fit("Stan", sw), fit("Kopie", vw), fit("Ostatni wynik", lw), fit(u"Następny", rest))
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
        line = "%s %s %s %s %s" % (fit(r["name"], nw, ch), fit(r["state"], sw, ch),
                                   fit(r["vword"], vw, ch), fit(r["last_txt"], lw, ch), fit(r["next"], rest, ch))
        if i == cursor:
            cur_y = len(body)
        body.append(line)
    if len(rows) > first + list_h:
        body.append(fit(u"... jeszcze %d" % (len(rows) - first - list_h), inner))
    while len(body) < list_h + 2:
        body.append("")
    footer = u"Enter szczegóły" if rows else ""
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
    scr.lines.append(key_bar("relacje", width, u"Enter Więcej"))
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
    b += u"   na łączu: %s" % (human_bytes(wire) if wire >= 0 else u"niemierzalne (mbuffer nie raportuje w tym trybie)")
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
        avail = height - 2 - panel_h
        run_h = min(len(running) + 3, max(4, avail // 3)) if running else 3
        done_h = avail - run_h
        rbody = [hdr, ch.dash * inner]
        cur_y = None
        if running:
            for i, t in enumerate(running[:run_h - 2]):
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
        if len(done) > first + list_h:
            dbody.append(u"... jeszcze %d" % (len(done) - first - list_h))
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
    scr.lines.append(key_bar("transfery", width, u"Enter Więcej"))
    scr.bars.add(len(scr.lines) - 1)
    return scr


# --- Monitor ---------------------------------------------------------------
def monitor_rows(data):
    mons = list((data.monitors or {}).get("monitors", []))
    order = {v: i for i, v in enumerate(VERDICT_ORDER)}
    mons.sort(key=lambda m: order.get(m.get("verdict", "UNKNOWN"), 9))
    return mons


def monitor_detail_pairs(m, ch):
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
        verdict += "   " + "  |  ".join(m["reason"].splitlines())
    elif m.get("verdict") == "OK":
        verdict += u"   najnowsza migawka mieści się w progu"
    pairs.append(("Werdykt", verdict))
    notes = []
    if m.get("paused_local"):
        notes.append(u"relacja wstrzymana -- OK z pauzy to nie dowód pokrycia")
    if m.get("engine_path_differs"):
        notes.append(u"cron woła %s, a tu policzono %s -- inny plik silnika" % (m.get("engine_in_cron"), m.get("engine_run")))
    if not m.get("parsed", True):
        notes.append(u"linii monitora nie dało się sparsować; werdykt pochodzi z kodu wyjścia")
    if notes:
        pairs.append(("Uwaga", "  |  ".join(notes)))
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
    scr.lines.append(key_bar("monitor", width, u"Enter Więcej"))
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
        sw, mw, lw = 16, 13, 17
        dw = inner - (nw + sw + mw + lw + 4)
        hdr = "%s %s %s %s %s" % (fit("Replika", nw), fit(u"Źródło %s cel" % ch.right, dw), fit("Harmonogram", sw), fit(u"Nośnik", mw), fit("Ostatnio widziany", lw))
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
                                            fit(st[0], mw, ch), fit(r.get("last_seen") or "nigdy", lw, ch)))
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
    scr.lines.append(key_bar("nosniki", width, u"Enter Więcej"))
    scr.bars.add(len(scr.lines) - 1)
    return scr


# --- Pomoc -----------------------------------------------------------------
HELP = [
    u"Pięć okien nad zfs-snapshot-all. Wszystko tylko do odczytu.",
    "",
    u"  F2  Relacje    co ten kolektor robi z innymi maszynami, czy kopie są aktualne",
    u"  Enter          okno relacji: zakres, polityka, monitor, transfery, linie",
    u"                 crona i komendy CLI dla jej stanu (nazwane, NIE wykonywane)",
    u"  F3  Transfery  co leci teraz i co skończyło się ostatnio (progress)",
    u"  F4  Monitor    każda linia monitora z werdyktem i powodem (monitor)",
    u"  F5  Nośniki    repliki na dyskach wymiennych i cztery stany nośnika",
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

    def __init__(self, repo, files, ch, now=None):
        self.repo, self.files, self.ch = repo, files, ch
        self.now_fixed = now
        self.screen = "relacje"
        self.cursor = {"relacje": 0, "transfery": 0, "monitor": 0, "nosniki": 0}
        self.window = None        # ("relacja", row) | ("pomoc", None)
        self.scroll = 0
        self.message = ""
        self.data = collect(repo, files)
        self.rows = build_relations(self.data, self.now())

    def now(self):
        return self.now_fixed if self.now_fixed is not None else int(time.time())

    def refresh(self, only=None):
        self.data = collect(self.repo, self.files, only)
        self.rows = build_relations(self.data, self.now())
        for k in self.cursor:
            self.cursor[k] = min(self.cursor[k], max(0, self.count(k) - 1))

    def count(self, screen):
        if screen == "relacje":
            return len(self.rows)
        if screen == "transfery":
            r, d = build_transfers(self.data, self.now())
            return len(r) + len(d)
        if screen == "monitor":
            return len(monitor_rows(self.data))
        return len((self.data.replicas or {}).get("replicas", []))

    def key(self, k, height=24):
        """Jeden klawisz -> nowy stan. `k` to nazwa: 'down', 'F2', 'enter', 'q', 'esc'..."""
        self.message = ""
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
        for key, fk, _label in SCREENS:
            if k == fk:
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
        elif k == "enter" and n:
            if self.screen == "relacje":
                self.window, self.scroll = ("relacja", self.rows[c]), 0
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
            return {"kind": "panel", "name": "monitor %s" % (m.get("label") or ""), "pairs": monitor_detail_pairs(m, ch)}
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
    if self.screen == "relacje":
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


def _ui_render_final(self, width, height):
    scr = _ui_render(self, width, height)
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
                       curses.KEY_F3: "F3", curses.KEY_F4: "F4", curses.KEY_F5: "F5", curses.KEY_ENTER: "enter",
                       10: "enter", 13: "enter", 27: "esc", ord("q"): "q", ord("j"): "j", ord("k"): "k", ord("r"): "r",
                       ord("1"): "F2", ord("2"): "F3", ord("3"): "F4", ord("4"): "F5", ord("?"): "F1", ord("h"): "F1"})
        stdscr.keypad(True)
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
            stdscr.timeout(2000 if ui.screen == "transfery" and not ui.window else -1)
            k = stdscr.getch()
            if k == -1:
                ui.refresh("progress")
                continue
            if k == curses.KEY_RESIZE:
                continue
            name = KEYMAP.get(k)
            if name == "esc":
                # Esc moze byc poczatkiem sekwencji; PuTTY wysyla F-klawisze jako
                # ESC [ .. ktore keypad() juz zlozyl, wiec goly ESC to Esc.
                pass
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
    ap.add_argument("--screen", default="relacje", choices=[s[0] for s in SCREENS], help="ktory ekran (z --render-once)")
    ap.add_argument("--keys", default="", help="sekwencja klawiszy po przecinku, np. down,down,enter,pgdn (z --render-once)")
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
    ui = UI(repo, files, ch, a.now)
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
