#!/usr/bin/env python3
"""Ekran 1: co ten host robi i czy to jest swieze.

Owner, 2026-09-08: "Rob ekran 1 TUI".

DLACZEGO PYTHON, W PAKIECIE PISANYM W BASHU. Dwa powody, oba zmierzone.
Czytelniki wydaja JSON, a parser JSON-a w bashu to recznie pisany parser --
dokladnie ten ksztalt, ktory ten pakiet tepi kontraktami. I `python3` z modulem
`curses` jest na kazdym hoscie floty (pve2 i pve1: 3.9.2, pve10: 3.11.2,
sprawdzone 2026-09-08), wiec nie dokladamy zaleznosci, tylko uzywamy tej, ktora
juz tam stoi. Cala reszta pakietu zostaje bashem; to jest JEDEN plik i wchodzi
sie do niego jednym czasownikiem `zfs-backup.sh gui`.

RYSOWANIE JEST FUNKCJA CZYSTA, i to nie jest estetyka -- to jedyny sposob, w
jaki moge ten ekran sprawdzic. `plink -batch` nie daje terminala, wiec petli
curses nie da sie z tej maszyny uruchomic na hoscie. Wiec: `render()` bierze
STAN i zwraca LINIE, `--render-once` drukuje dokladnie to, co pokazalby ekran,
a curses jest cienka petla, ktora te same linie wypisuje. Test sprawdza
`render()`, a operator moze zobaczyc ekran przez zwykle ssh.

CZEGO TEN EKRAN NIE ROBI: nie zmienia niczego. Zadnego zapisu, zadnej komendy
poza dwoma czytelnikami. Klawisze to ruch, odswiezenie i wyjscie.
"""

import argparse
import json
import os
import subprocess
import sys
import time

WIDTH = 80

# Werdykt monitora -> (etykieta, para kolorow curses). UNKNOWN i BEZ MONITORA sa
# rozne: pierwszy znaczy "pytalem, nie wiem", drugi "nikt nie pyta". Silnik ma
# na to wlasne zdanie ("a monitor that never runs looks exactly like a monitor
# that says everything is fine") i ekran nie ma prawa ich zlac w jedno.
VERDICTS = {
    "OK":            ("OK",        2),
    "WARNING":       ("UWAGA",     3),
    "CRITICAL":      ("KRYTYCZNY", 1),
    "UNKNOWN":       ("NIEZNANY",  4),
    "BEZ MONITORA":  ("BEZ MON.",  4),
}

ARROWS = {
    "local":    "-> tutaj",
    "push":     "-> {peer}",
    "pull":     "<- {peer}",
    "snapshot": "(migawka)",
    "prune":    "porzadki",
}


def run_verb(repo, args):
    """Uruchom czytelnik i oddaj sparsowany JSON, albo blad jako tekst.

    Status wyjscia NIE jest bledem sam z siebie: `monitor` zwraca 1/2/3 jako
    WERDYKT (to jego kontrakt), wiec liczy sie to, czy wyjscie da sie sparsowac.
    """
    cmd = [os.path.join(repo, "zfs-backup.sh")] + args
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        return None, "nie udalo sie uruchomic %s: %s" % (" ".join(args), e)
    try:
        return json.loads(p.stdout.decode("utf-8", "replace")), None
    except ValueError:
        err = p.stderr.decode("utf-8", "replace").strip().splitlines()
        return None, (err[-1] if err else "%s nie wydal poprawnego JSON-a" % args[0])


def family_of(job):
    """Rodzina do POROWNANIA i do POKAZANIA, w jednej pisowni.

    Transfer stempluje `prefix` (`automated_daily_`), prune dopasowuje `pattern`
    (`automated_daily`) -- ta sama rodzina, roznica jednego podkreslenia. W
    wierszu CLI to nie przeszkadza, bo wiersz jest sam; na ekranie sasiaduja i
    czytaja sie jak dwie rozne rodziny. Wiec jedna pisownia: bez konca.
    """
    return (job.get("pattern") or job.get("prefix", "")).rstrip("_")


def verdict_for(job, monitors):
    """Werdykt monitora dla tego zadania, albo BEZ MONITORA.

    Dopasowanie jest po ZAKRESIE I RODZINIE, nie po samej nazwie: jedna linia
    monitora obejmuje kilka datasetow (silnik drukuje wiersz na dataset), a ten
    sam dataset moze miec dwie rodziny o roznych progach. Dopasowanie po samym
    datasecie pokazaloby werdykt godzinowy przy wierszu dobowym.
    """
    scope = job.get("scope", "")
    fam = family_of(job)
    for m in monitors:
        if scope in m.get("datasets", []) and m.get("pattern", "") == fam:
            return m.get("verdict", "UNKNOWN"), m.get("reason", "")
    # DRUGI KLUCZ: ETYKIETA RELACJI. Dla POBRANIA monitorowany jest lokalny CEL,
    # a zakres zadania to zdalne ZRODLO -- dopasowanie po samej sciezce nie ma
    # jak ich polaczyc i wiersz pull wychodzil "BEZ MONITORA", chociaz monitor
    # istnial. gen-cron stempluje linie monitora etykieta relacji (-L) wlasnie
    # po to, zeby dalo sie ja przypisac; to jest ten sam klucz, nie nowy.
    label = job.get("label", "")
    if label:
        for m in monitors:
            if m.get("label", "") == label and m.get("pattern", "") == fam:
                return m.get("verdict", "UNKNOWN"), m.get("reason", "")
    return "BEZ MONITORA", ""


def build_rows(jobs_doc, mon_doc):
    """Stan ekranu: lista wierszy plus naglowek. Bez rysowania."""
    rows = []
    monitors = (mon_doc or {}).get("monitors", [])
    for j in (jobs_doc or {}).get("jobs", []):
        v, reason = verdict_for(j, monitors)
        arrow = ARROWS.get(j.get("direction", ""), "?")
        rows.append({
            "kind": "job",
            "account": j.get("account", ""),
            "arrow": arrow.format(peer=j.get("peer") or "?"),
            "tier": j.get("tier", ""),
            "scope": j.get("scope", ""),
            "family": family_of(j),
            "schedule": j.get("schedule", ""),
            "verdict": v,
            "reason": reason,
            "job": j,
        })
    # BLOK, KTOREGO NIE DA SIE WYJASNIC, JEST WIERSZEM -- nie przypisem. Te
    # linie CHODZA; ukrycie ich tutaj to ta sama pusta ramka, przed ktora ten
    # czasownik powstal.
    for u in (jobs_doc or {}).get("unreadable", []):
        rows.append({
            "kind": "unreadable",
            "account": u.get("account", ""),
            "arrow": "!",
            "tier": "",
            "scope": u.get("config") or "(blok bez naglowka Source)",
            # LICZBA LINII IDZIE W KOLUMNE, nie tylko w stopke: to jedyna liczba,
            # ktora mowi ILE tu chodzi bez wyjasnienia, a stopka pokazuje sie
            # dopiero dla wiersza pod kursorem.
            "family": "%s linii" % u.get("lines_in_block", "?"),
            "schedule": "%s linii" % u.get("lines_in_block", "?"),
            "verdict": "UNKNOWN",
            "reason": u.get("error", ""),
            "job": None,
        })
    return rows


def header_lines(jobs_doc, mon_doc, err):
    """Trzy fakty, ktore musza byc widoczne zawsze: host, konto, config.

    Zmierzone na produkcji 2026-09-08: crontab roota nie mial ani jednego bloku
    zarzadzanego, a konto delegowane mialo blok z JEDENASTOMA liniami. Operator
    zalogowany jako root, patrzacy na "swoj" swiat, zobaczylby pustke na hoscie
    robiacym jedenascie zadan. Wiec konto jest w naglowku, nie w ustawieniach.
    """
    host = (jobs_doc or {}).get("host") or "(host nieznany)"
    jobs = (jobs_doc or {}).get("jobs", [])
    accounts = sorted({j.get("account", "") for j in jobs} |
                      {u.get("account", "") for u in (jobs_doc or {}).get("unreadable", [])})
    configs = sorted({j.get("config", "") for j in jobs if j.get("config")})
    worst = (mon_doc or {}).get("worst", "UNKNOWN")
    l1 = " %s | konto: %s | najgorszy werdykt: %s" % (
        host, ", ".join(a for a in accounts if a) or "(brak)", VERDICTS.get(worst, (worst, 0))[0])
    # Sciezka configu obcinana od POCZATKU: konczy sie nazwa pliku, ktora
    # odroznia jeden config od drugiego, a zaczyna katalogiem, ktory na kazdym
    # hoscie jest ten sam.
    cfg = configs[0] if len(configs) == 1 else (
        "%d rozne configi" % len(configs) if configs else "(nieznany)")
    if len(cfg) > WIDTH - 11:
        cfg = "..." + cfg[-(WIDTH - 14):]
    l2 = " config: %s" % cfg
    if err:
        l2 = " " + err[:WIDTH - 2]
    return [l1[:WIDTH], l2[:WIDTH]]


def render(rows, hdr, cursor, height=24, message=""):
    """STAN -> LINIE. Zadnego terminala, zadnego wejscia, zadnych efektow."""
    out = []
    out.append("=" * WIDTH)
    out.extend(hdr)
    out.append("=" * WIDTH)
    out.append(" %-9s %-9s %-26s %-16s %-9s" % ("KIERUNEK", "SZCZEBEL", "ZAKRES", "RODZINA", "STAN"))
    out.append("-" * WIDTH)
    body = max(3, height - 9)
    first = 0
    if cursor >= body:
        first = cursor - body + 1
    if not rows:
        out.append(" Zero zadan wyprowadzonych z zainstalowanych blokow.")
        out.append(" To NIE znaczy 'host nic nie robi' -- znaczy, ze nie ma tu bloku")
        out.append(" zfs-backup-managed albo jego config jest nieczytelny.")
    for i, r in enumerate(rows[first:first + body], start=first):
        mark = ">" if i == cursor else " "
        label = VERDICTS.get(r["verdict"], (r["verdict"], 0))[0]
        out.append("%s%-9s %-9s %-26s %-16s %-9s" % (
            mark, r["arrow"][:9], r["tier"][:9], r["scope"][-26:], (r["family"] or "")[:16], label))
    out.append("-" * WIDTH)
    if message:
        out.append(" " + message[:WIDTH - 2])
    elif rows and 0 <= cursor < len(rows):
        cur = rows[cursor]
        detail = cur["reason"] or ("harmonogram %s   konto %s" % (cur["schedule"], cur["account"]))
        out.append(" " + detail[:WIDTH - 2])
    else:
        out.append("")
    out.append(" q wyjscie   r odswiez   strzalki ruch   Enter szczegoly wiersza")
    return out


def collect(repo, jobs_file=None, mon_file=None):
    err = None
    if jobs_file:
        jobs_doc = json.load(open(jobs_file))
    else:
        jobs_doc, err = run_verb(repo, ["list-jobs", "--json"])
    if mon_file:
        mon_doc = json.load(open(mon_file))
    else:
        mon_doc, merr = run_verb(repo, ["monitor", "--json"])
        err = err or merr
    return jobs_doc, mon_doc, err


def curses_loop(repo, jobs_file, mon_file):
    import curses

    def main(stdscr):
        curses.curs_set(0)
        curses.use_default_colors()
        for i, fg in ((1, curses.COLOR_RED), (2, curses.COLOR_GREEN),
                      (3, curses.COLOR_YELLOW), (4, curses.COLOR_CYAN)):
            try:
                curses.init_pair(i, fg, -1)
            except curses.error:
                pass
        cursor, message = 0, ""
        jobs_doc, mon_doc, err = collect(repo, jobs_file, mon_file)
        rows = build_rows(jobs_doc, mon_doc)
        while True:
            h, w = stdscr.getmaxyx()
            lines = render(rows, header_lines(jobs_doc, mon_doc, err), cursor, h, message)
            stdscr.erase()
            for y, line in enumerate(lines[:h - 1]):
                attr = 0
                for name, (label, pair) in VERDICTS.items():
                    if line.rstrip().endswith(label) and pair:
                        attr = curses.color_pair(pair)
                try:
                    stdscr.addstr(y, 0, line[:w - 1], attr)
                except curses.error:
                    pass
            stdscr.refresh()
            k = stdscr.getch()
            message = ""
            if k in (ord("q"), 27):
                return
            elif k in (curses.KEY_DOWN, ord("j")) and cursor < len(rows) - 1:
                cursor += 1
            elif k in (curses.KEY_UP, ord("k")) and cursor > 0:
                cursor -= 1
            elif k in (ord("r"), curses.KEY_F5):
                jobs_doc, mon_doc, err = collect(repo, jobs_file, mon_file)
                rows = build_rows(jobs_doc, mon_doc)
                cursor = min(cursor, max(0, len(rows) - 1))
                message = "odswiezono %s" % time.strftime("%H:%M:%S")
            elif k in (10, 13, curses.KEY_ENTER) and rows:
                r = rows[cursor]
                # Ekran 2 jeszcze nie istnieje. Zamiast martwego klawisza --
                # rekord tego wiersza, doslownie, bo to jest to, co ma front end.
                message = json.dumps(r["job"] or {"nieczytelne": r["reason"]},
                                     ensure_ascii=False)[:WIDTH - 2]
    curses.wrapper(main)


def main(argv):
    ap = argparse.ArgumentParser(description="Ekran 1: zadania tego hosta i ich swiezosc")
    ap.add_argument("--render-once", action="store_true",
                    help="wydrukuj ekran jako tekst i zakoncz (testy, i podglad przez ssh bez terminala)")
    ap.add_argument("--jobs", help="czytaj list-jobs --json z pliku zamiast uruchamiac czasownik")
    ap.add_argument("--monitors", help="czytaj monitor --json z pliku")
    ap.add_argument("--height", type=int, default=24)
    a = ap.parse_args(argv)
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if a.render_once:
        jobs_doc, mon_doc, err = collect(repo, a.jobs, a.monitors)
        rows = build_rows(jobs_doc, mon_doc)
        print("\n".join(render(rows, header_lines(jobs_doc, mon_doc, err), 0, a.height)))
        return 0
    if not sys.stdout.isatty():
        sys.stderr.write("gui: to nie jest terminal -- uzyj --render-once, zeby zobaczyc ekran\n")
        return 2
    curses_loop(repo, a.jobs, a.monitors)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
