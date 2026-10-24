#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""hand-edits.py PLAN NAME -- reczne zmiany w configu relacji, ktore WYKONAJ nadpisze.

X6 (wlasciciel 2026-10-12): config jest zrodlem prawdy, a GUI generuje sekcje relacji od
nowa z jej szablonu -- reczna zmiana (np. minuta sprzatania 31 -> 29) przepadala bez
slowa. Wolajacy liczy plan zmiany relacji z jej OBECNYMI ustawieniami (nic nie zmienione
w oknie); kazda roznica w configu takiego planu to reczna zmiana. Ten skrypt czyta plan
i drukuje ostrzezenie (albo nic, gdy recznych zmian nie ma).

Dwie postacie planu:
  * relacja zdalna: "--- proposed config: PLIK ---" i diff -u obecny -> proponowany;
  * relacja lokalna: "Target config: PLIK" i pelny "--- candidate CONFIG ...", ktory
    porownujemy z PLIKIEM sekcja po sekcji.
Sekcje, ktore pojawiaja sie dopiero w planie (GUI je dopisze), nie sa recznymi zmianami.
"""
import json
import os
import re
import sys

# Słowa w języku okna: ten sam katalog co GUI (ścieżka z wt-lib.sh), czytany jako dane.
_C = json.load(open(os.environ["ZFS_TUI_CAT"], encoding="utf-8")) if os.environ.get("ZFS_TUI_CAT") else {}


def _(s):
    return _C.get(s, s)


TIERS = {"hourly": u"godzinowe", "daily": u"dobowe", "weekly": u"tygodniowe", "monthly": u"miesięczne", "yearly": u"roczne"}
KEYS = {"exclude_child": u"wyjątek", "send_schedule": u"godzina kopii", "prune_schedule": u"godzina sprzątania",
        "keep": u"trzyma", "retain": u"trzyma (wiek)", "schedule": u"harmonogram"}


def label(sec):
    if sec.startswith("dataset:"):
        return _(u"dataset %s") % sec[len("dataset:"):]
    m = re.match(r"template:profile__.*?__(.*)$", sec)
    if m:
        t = m.group(1)
        src = re.match(r"^l?src_", t) is not None
        t = re.sub(r"^l?src_", "", t)
        t = _(TIERS[t]) if t in TIERS else t
        return (_(u"źródło, %s") % t) if src else t
    return sec


def parse_sections(lines):
    secs, cur = {}, None
    for l in lines:
        s = l.strip()
        m = re.match(r"^\[(.+)\]$", s)
        if m:
            cur = m.group(1)
            secs.setdefault(cur, {})
            continue
        if cur is None or not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        secs[cur][k.strip()] = v.strip()
    return secs


def from_diff(lines):
    """diff -u obecny -> proponowany: '-' = obecne (reczne), '+' = to, co wpisze GUI."""
    cur, old, new = None, {}, {}
    for l in lines:
        if not l.startswith("  "):
            continue
        body = l[2:]
        if body.startswith("@@"):
            continue
        sign, text = (body[0], body[1:]) if body[:1] in "+- " else (" ", body)
        s = text.strip()
        m = re.match(r"^\[(.+)\]$", s)
        if m:
            cur = m.group(1)
            if sign == "-":
                old.setdefault(cur, {})["__section__"] = "1"
            elif sign == "+":
                new.setdefault(cur, {})["__section__"] = "1"
            continue
        if cur is None or sign == " " or not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        (old if sign == "-" else new).setdefault(cur, {})[k.strip()] = v.strip()
    return old, new


def main(argv):
    lines = open(argv[1], encoding="utf-8", errors="replace").read().splitlines()
    # X3: wyjatek, ktory czasownik sam zdejmuje (zrodlo juz go nie obejmuje), to
    # sprzatanie, nie reczna zmiana -- plan mowi to linia ">>> exception '...' dropped".
    dropped = set(re.findall(r"exception '([^']*)' dropped", "\n".join(lines)))
    rows = []
    blk = None
    for i, l in enumerate(lines):
        if l.startswith("--- proposed config:"):
            blk = []
            for x in lines[i + 1:]:
                if x.startswith("--- "):
                    break
                blk.append(x)
            break
    if blk is not None:
        old, new = from_diff(blk)
        for sec in sorted(set(old) | set(new)):
            o, n = old.get(sec, {}), new.get(sec, {})
            if o.get("__section__") and not n.get("__section__"):
                rows.append(_(u"  %s: sekcja zniknie") % label(sec))
                continue
            for k in sorted(set(o) | set(n)):
                if k == "__section__" or k not in o:
                    continue
                if o.get(k) != n.get(k) and not (k.startswith("exclude_child") and o.get(k) in dropped):
                    rows.append(u"  %s, %s:  %s -> %s" % (label(sec), _(KEYS[re.sub(r"_[0-9]+$", "", k)]) if re.sub(r"_[0-9]+$", "", k) in KEYS else k, o[k], n.get(k, _(u"(brak)"))))
    else:
        path = None
        for l in lines:
            m = re.match(r"^\s*Target config:\s+(\S+)", l)
            if m:
                path = m.group(1)
                break
        cand = []
        on = False
        for l in lines:
            if l.startswith("--- candidate CONFIG"):
                on = True
                continue
            if on and l.startswith("--- "):
                break
            if on:
                cand.append(l)
        if not path or not cand:
            return 0
        try:
            curr = parse_sections(open(path, encoding="utf-8", errors="replace").read().splitlines())
        except OSError:
            return 0
        new = parse_sections(cand)
        for sec in sorted(curr):
            if sec not in new:
                continue      # sekcja spoza tej relacji, ktorej plan nie przepisuje
            o, n = curr[sec], new[sec]
            for k in sorted(o):
                if o[k] != n.get(k) and not (k.startswith("exclude_child") and o[k] in dropped):
                    rows.append(u"  %s, %s:  %s -> %s" % (label(sec), _(KEYS[re.sub(r"_[0-9]+$", "", k)]) if re.sub(r"_[0-9]+$", "", k) in KEYS else k, o[k], n.get(k, _(u"(brak)"))))
    if rows:
        out = [_(u"UWAGA: relacja ma ustawienia inne niż jej szablon (tabela, silnik albo ręcznie w configu)."),
               _(u"Szablon zastąpi je swoimi:")] + rows + \
              [_(u"Chcesz zachować swoje wartości? Wróć (Wstecz) i popraw liczby w 'Harmonogram i retencja' zamiast zmieniać szablon."), u""]
        sys.stdout.write(u"\n".join(out) + u"\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
