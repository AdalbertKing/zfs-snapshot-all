#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tree.py -- DRZEWO WYBORU DATASETOW w curses: kratki jak w Eksploratorze / programach do backupu.

Wyjatek od zasady "formularze w whiptail" (wlasciciel, decyzja X12, 2026-10-12): zamiast
niezgrabnego "koszyka" (lista + Dodaj miejsce / Wyjatki / Usun) -- jedno drzewo z kratkami.
Dane dla wolajacego zostaja te same: KORZENIE (zaznaczone "miejsce" = ten dataset i wszystko
pod nim, co istnieje albo POWSTANIE) i WYJATKI przy korzeniu (datasety pod nim pomijane
razem ze wszystkim, co pod nimi).

    tree.py --spec SPEC.json --out OUT.json [--keys k1,k2,... ] [--width W] [--height H]

SPEC: {"title", "host",
       "datasets": [{"name","used":bajty|tekst|brak,"type":"filesystem"|"volume"}],  -- jak list-datasets --json
       "roots": [nazwy], "excl": {korzen: [nazwy]},        -- wybor poczatkowy
       "hide": [nazwy],      -- ukryte razem z tym, co pod nimi (cel kopii); nigdy nie widac, nie da sie zaznaczyc
       "no_exc": bool,       -- true = bez wyjatkow, tylko cale miejsca
       "show_mode": bool, "recursion": "flat"|"atomic"}
OUT:  {"action":"next"|"back", "roots":[w kolejnosci drzewa], "excl":{korzen:[posortowane wg drzewa]},
       "recursion":"flat"|"atomic"}      -- przy "back" roots/excl/recursion takie jak na starcie

MODEL: stanem sa korzenie + wyjatki; obraz jest z nich wyliczany. Dataset jest zaznaczony, gdy
lezy w korzeniu (lub jest nim) i nie lezy w wyjatku tego korzenia. Kratka [x] = zaznaczony i nic
widocznego pod nim nie jest odznaczone, [ ] = odwrotnie, [-] = czesciowo. Spacja:
  * zaznaczony korzen -> korzen znika (z wyjatkami);
  * zaznaczony pod korzeniem r -> staje sie wyjatkiem r (odmowa przy no_exc i przy trybie atomowym);
  * odznaczony przez wyjatek e -> gdy to e, wyjatek znika; inaczej odmowa ("najpierw zaznacz e");
  * odznaczony poza korzeniami (tez [-]) -> staje sie korzeniem, korzenie pod nim znikaja.
Cel kopii z "hide" lezacy pod nowym zasiegiem jest pomijany sam (wyjatek niewidoczny); gdy to
niemozliwe (no_exc, tryb atomowy) -- odmowa. Klawisz S (tylko show_mode): flat <-> atomic.

--keys: bez terminala -- nazwy klawiszy (up, down, left, right, pgup, pgdn, home, end, space,
enter, esc, plus, minus, goto:NAZWA -- kursor na dataset z rozwinietymi przodkami, tylko dla
testow -- albo jeden znak), potem wydruk ekranu i linie "MSG: ..." (kazdy
komunikat pokazany w trakcie); tak to sprawdzaja testy. Wydruk robi ta sama funkcja, co rysuje
curses (render), wiec test widzi dokladnie to, co wlasciciel.
Okno samo nie zapisuje niczego poza OUT -- zapis robi czasownik w kreatorze.
"""
import argparse
import json
import sys


def under(n, r):
    """n to r albo lezy pod r."""
    return n == r or n.startswith(r + "/")


def human(n):
    n = float(n or 0)
    for u in ("B", "K", "M", "G", "T", "P"):
        if n < 1024 or u == "P":
            return ("%d%s" % (n, u)) if u == "B" or n >= 100 else ("%.1f%s" % (n, u))
        n /= 1024.0


def used_text(v):
    if v is None or v == "":
        return ""
    try:
        return human(float(v))
    except (TypeError, ValueError, OverflowError):
        return ""


def wrap(text, width):
    """Zawijanie komunikatu po slowach; najwyzej 3 linie."""
    out, cur = [], u""
    for wd in text.split(u" "):
        if cur and len(cur) + 1 + len(wd) > width:
            out.append(cur)
            cur = wd
        else:
            cur = (cur + u" " + wd) if cur else wd
    out.append(cur)
    return out[:3]


class Tree(object):
    def __init__(self, spec):
        self.spec = spec
        self.show_mode = bool(spec.get("show_mode"))
        self.no_exc = bool(spec.get("no_exc"))
        self.recursion = "atomic" if spec.get("recursion") == "atomic" else "flat"
        hide = list(dict.fromkeys(h for h in (spec.get("hide") or []) if h))
        self.hide = set(hide)
        # tylko najwyzsze wpisy hide (pod ukrytym i tak nic nie ma)
        self.hide_min = [h for h in hide if not any(o != h and under(h, o) for o in hide)]
        self._build(spec.get("datasets") or [])
        # stan na starcie -- wraca przy "back"
        self.init = {"roots": list(spec.get("roots") or []),
                     "excl": dict((r, list(v)) for r, v in (spec.get("excl") or {}).items()),
                     "recursion": self.recursion}
        self.roots = sorted(dict.fromkeys(self.init["roots"]), key=self.tkey)
        self.excl = dict((r, list(dict.fromkeys(self.init["excl"].get(r) or []))) for r in self.roots)
        self.expanded = set(n for n in self.order if self.nodes[n]["depth"] == 0)
        for n in self.roots + [e for r in self.roots for e in self.excl[r]]:
            parts = n.split("/")
            for i in range(1, len(parts)):
                self.expanded.add("/".join(parts[:i]))
        self.msg = ""
        self.shown = []      # --keys: kazdy komunikat pokazany w trakcie (test go widzi)
        self.done = None
        self.top = 0
        self.msg_rows = []
        self.resize(80, 24)
        rows = self.rows()
        first = [r for r in self.roots if r in self.nodes]
        self.cur = first[0] if first else (rows[0] if rows else "")

    # -- drzewo z nazw: rodzic = nazwa bez ostatniego skladnika; brak rodzica na liscie = poziom 0
    def _build(self, datasets):
        names, seen, info = [], set(), {}
        for d in datasets:
            n = d.get("name") if isinstance(d, dict) else d
            if not n or n in seen or any(under(n, h) for h in self.hide):
                continue
            seen.add(n)
            names.append(n)
            info[n] = d if isinstance(d, dict) else {}
        self.nodes = {}
        for n in names:
            p = n.rsplit("/", 1)[0] if "/" in n else None
            self.nodes[n] = {"name": n, "parent": p if p in seen else None, "kids": [], "sub": [],
                             "depth": 0, "used": info[n].get("used"), "type": info[n].get("type")}
        self.tops = []
        for n in names:
            p = self.nodes[n]["parent"]
            (self.nodes[p]["kids"] if p else self.tops).append(n)
            q = p
            while q:
                self.nodes[n]["depth"] += 1
                q = self.nodes[q]["parent"]
        self.order, stack = [], list(reversed(self.tops))
        while stack:
            n = stack.pop()
            self.order.append(n)
            stack.extend(reversed(self.nodes[n]["kids"]))
        for n in reversed(self.order):
            for k in self.nodes[n]["kids"]:
                self.nodes[n]["sub"] += [k] + self.nodes[k]["sub"]
        self.pos = dict((n, i) for i, n in enumerate(self.order))

    def tkey(self, n):
        return (0, self.pos[n], n) if n in self.pos else (1, 0, n)

    def rows(self):
        out, stack = [], list(reversed(self.tops))
        while stack:
            n = stack.pop()
            out.append(n)
            if n in self.expanded:
                stack.extend(reversed(self.nodes[n]["kids"]))
        return out

    # -- model: zaznaczenie wynika z korzeni i wyjatkow
    def covering(self, n):
        """Korzenie, przez ktore n jest zaznaczony (lezy w nim i nie w jego wyjatku)."""
        return [r for r in self.roots if under(n, r)
                and not any(under(n, e) for e in self.excl.get(r, []))]

    def checked_map(self):
        return dict((n, bool(self.covering(n))) for n in self.order)

    def mark(self, n, chk):
        sub = self.nodes[n]["sub"]
        if chk[n]:
            return u"[-]" if any(not chk[s] for s in sub) else u"[x]"
        return u"[-]" if any(chk[s] for s in sub) else u"[ ]"

    def need_skip(self, n):
        """Cele kopii (hide) pod n: (blad albo "", lista do pominiecia)."""
        hs = [h for h in self.hide_min if h.startswith(n + "/")]
        if not hs:
            return u"", []
        if self.no_exc:
            return u"Pod %s leży cel kopii (%s). Zaznacz węższe miejsce." % (n, hs[0]), hs
        if self.recursion == "atomic":
            return (u"Pod %s leży cel kopii (%s); przy kopiowaniu atomowym nie da się go pominąć. "
                    u"Zaznacz węższe miejsce." % (n, hs[0])), hs
        return u"", hs

    def space(self, n):
        cov = self.covering(n)
        if cov:
            if n in cov:                      # zaznaczony korzen -> korzen znika
                self.roots.remove(n)
                self.excl.pop(n, None)
                return
            r = cov[0]
            if self.no_exc:
                self.msg = u"Tu wybiera się całe miejsca -- żeby nie kopiować %s, odznacz całe %s." % (n, r)
                return
            if self.recursion == "atomic":
                self.msg = (u"Przy kopiowaniu atomowym (-r) nie da się pominąć części gałęzi. " +
                            (u"Zmień sposób klawiszem S albo odznacz całe %s." % r if self.show_mode
                             else u"Odznacz całe %s." % r))
                return
            for r in cov:
                self.excl[r] = [e for e in self.excl.get(r, []) if not under(e, n)] + [n]
            return
        cands = [e for r in self.roots if under(n, r) for e in self.excl.get(r, []) if under(n, e)]
        if cands:
            e = min(cands, key=len)
            if e != n:
                self.msg = u"%s jest pomijany razem z %s. Zaznacz najpierw %s." % (n, e, e)
                return
            err, hs = self.need_skip(e)       # zdjecie wyjatku nie moze odslonic celu kopii
            if err:
                self.msg = err
                return
            for r in self.roots:
                if e in self.excl.get(r, []):
                    self.excl[r] = [x for x in self.excl[r] if x != e and x not in hs] + hs
            if hs:
                self.msg = u"Cel kopii %s pominięty automatycznie." % u", ".join(hs)
            return
        err, hs = self.need_skip(n)           # n poza korzeniami -> staje sie korzeniem
        if err:
            self.msg = err
            return
        for r in [r for r in self.roots if under(r, n)]:
            self.roots.remove(r)
            self.excl.pop(r, None)
        self.roots.append(n)
        self.excl[n] = list(hs)
        if hs:
            self.msg = u"Cel kopii %s pominięty automatycznie." % u", ".join(hs)

    def toggle_mode(self):
        if self.recursion == "atomic":
            self.recursion = "flat"
            return
        exc = [e for r in self.roots for e in self.excl.get(r, [])]
        if any(e not in self.hide for e in exc):
            self.msg = u"Kopiowanie atomowe (-r) nie pozwala pomijać. Zdejmij najpierw pominięte (odznaczone) datasety."
        elif exc:
            self.msg = u"Kopiowanie atomowe (-r) nie pozwala pominąć celu kopii (%s). Zaznacz węższe miejsca." % exc[0]
        else:
            self.recursion = "atomic"

    # -- klawisze
    def key(self, k):
        k = {"plus": "+", "minus": "-", " ": "space"}.get(k, k)
        if self.msg:
            self.shown.append(self.msg)
        self.msg = ""
        if k.startswith("goto:"):         # tylko --keys (testy): kursor na dataset, przodkowie rozwinieci
            n = k[5:]
            if n not in self.nodes:
                self.msg = u"goto: nie ma %s w drzewie" % n
                return
            p = self.nodes[n]["parent"]
            while p:
                self.expanded.add(p)
                p = self.nodes[p]["parent"]
            self.cur = n
            return
        rows = self.rows()
        idx = rows.index(self.cur) if self.cur in rows else 0
        nd = self.nodes.get(self.cur)
        if k == "esc":
            self.done = "back"
        elif k == "enter":
            if self.roots:
                self.done = "next"
            else:
                self.msg = u"Zaznacz co najmniej jedno miejsce (Spacja)."
        elif k in ("s", "S") and self.show_mode:
            self.toggle_mode()
        elif not rows:
            return
        elif k == "space":
            self.space(self.cur)
        elif k in ("up", "down", "pgup", "pgdn", "home", "end"):
            page = self.list_height(1)
            idx = {"up": idx - 1, "down": idx + 1, "pgup": idx - page, "pgdn": idx + page,
                   "home": 0, "end": len(rows) - 1}[k]
            self.cur = rows[max(0, min(idx, len(rows) - 1))]
        elif k in ("right", "+"):
            if nd["kids"]:
                if self.cur not in self.expanded:
                    self.expanded.add(self.cur)
                else:
                    self.cur = nd["kids"][0]
        elif k in ("left", "-"):
            if nd["kids"] and self.cur in self.expanded:
                self.expanded.discard(self.cur)
            elif nd["parent"]:
                self.cur = nd["parent"]

    def result(self):
        if self.done != "next":
            return {"action": self.done or "back", "roots": self.init["roots"],
                    "excl": self.init["excl"], "recursion": self.init["recursion"]}
        roots = sorted(self.roots, key=self.tkey)
        return {"action": "next", "roots": roots,
                "excl": dict((r, sorted(self.excl.get(r, []), key=self.tkey)) for r in roots),
                "recursion": self.recursion}

    # -- obraz
    def resize(self, width, height):
        self.w = max(78, min(width - 2, 100))
        self.h = max(14, min(height - 2, 50))

    def list_height(self, msg_lines):
        return max(3, self.h - 6 - (1 if self.show_mode else 0) - msg_lines)

    def row_text(self, n, chk, iw):
        nd = self.nodes[n]
        if nd["kids"]:
            exp = u"- " if n in self.expanded else u"+ "
        else:
            exp = u"  "
        prefix = u" " + u"  " * nd["depth"] + exp + self.mark(n, chk) + u" "
        name = n if nd["depth"] == 0 else n.rsplit("/", 1)[1]
        size = used_text(nd["used"])
        right = (u"zvol " + size).strip() if nd["type"] == "volume" else size
        avail = iw - len(prefix) - (len(right) + 2 if right else 1)
        if len(name) > avail:
            name = name[:max(1, avail - 1)] + u"…"
        left = prefix + name
        return (left.ljust(iw - len(right) - 1) + right + u" ") if right else left

    def render(self):
        w, iw = self.w, self.w - 2
        rows, chk = self.rows(), self.checked_map()
        mlines = [u" " + l for l in wrap(self.msg, iw - 2)] if self.msg else [u""]
        lh = self.list_height(len(mlines))
        idx = rows.index(self.cur) if self.cur in rows else 0
        self.top = max(0, min(self.top, len(rows) - lh))
        if idx < self.top:
            self.top = idx
        elif idx >= self.top + lh:
            self.top = idx - lh + 1
        body = [u" [x] kopiowane, razem z tym, co pod nim POWSTANIE   [-] część   [ ] nie"]
        if self.show_mode:
            body.append(u" Sposób: cała gałąź atomowo (-r)   S zmienia" if self.recursion == "atomic"
                        else u" Sposób: każdy dataset osobno (-R)   S zmienia")
        body.append(u" ↑ więcej" if self.top > 0 else u"")
        first = len(body)
        for n in rows[self.top:self.top + lh]:
            body.append(self.row_text(n, chk, iw))
        body += [u""] * (first + lh - len(body))
        body.append(u" ↓ więcej" if self.top + lh < len(rows) else u"")
        nexc = sum(1 for r in self.roots for e in self.excl.get(r, []) if e not in self.hide)
        auto = any(e in self.hide for r in self.roots for e in self.excl.get(r, []))
        body.append(u" Wybrane miejsca: %d   pominięte: %d%s" % (
            len(self.roots), nexc, u"   (cel kopii pominięty automatycznie)" if auto else u""))
        mfirst = len(body)
        body += mlines
        title = u" %s " % (self.spec.get("title") or u"Wybór datasetów")
        if len(title) > w - 4:
            title = title[:max(1, w - 6)] + u"… "
        hint = u"Spacja zaznacz  →/+ rozwiń  ←/- zwiń  Enter Dalej  Esc Wstecz" + (u"  S sposób" if self.show_mode else u"")
        top = u"┌─" + title + u"─" * max(0, w - 3 - len(title)) + u"┐"
        bot = u"└─ " + hint[:w - 6] + u" " + u"─" * max(0, w - 5 - len(hint[:w - 6])) + u"┘"
        out = [top] + [u"│" + l[:iw].ljust(iw) + u"│" for l in body] + [bot]
        self.msg_rows = [mfirst + i + 1 for i in range(len(mlines))] if self.msg else []
        focus = (first + (idx - self.top) + 1, 1, w - 1) if rows else None
        return out, focus


KEYNAMES = {"\t": "tab", " ": "space", "\n": "enter", "\r": "enter", "\x1b": "esc", "\x7f": "bs", "\x08": "bs"}


def run_curses(t):
    import curses
    import locale
    locale.setlocale(locale.LC_ALL, "")

    def main(scr):
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        curses.set_escdelay(25) if hasattr(curses, "set_escdelay") else None
        if curses.has_colors():
            curses.start_color()
            curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLUE)
            curses.init_pair(2, curses.COLOR_BLACK, curses.COLOR_CYAN)
            curses.init_pair(3, curses.COLOR_YELLOW, curses.COLOR_BLUE)
        scr.keypad(True)
        km = {curses.KEY_UP: "up", curses.KEY_DOWN: "down", curses.KEY_LEFT: "left", curses.KEY_RIGHT: "right",
              curses.KEY_PPAGE: "pgup", curses.KEY_NPAGE: "pgdn", curses.KEY_ENTER: "enter", 10: "enter", 13: "enter",
              curses.KEY_HOME: "home", curses.KEY_END: "end", 27: "esc", 32: "space"}
        while t.done is None:
            h, wd = scr.getmaxyx()
            t.resize(wd, h)
            lines, focus = t.render()
            scr.erase()
            base = curses.color_pair(1) if curses.has_colors() else curses.A_NORMAL
            y0 = max(0, (h - len(lines)) // 2)
            x0 = max(0, (wd - len(lines[0])) // 2)
            for y, l in enumerate(lines):
                if y0 + y >= h:
                    break
                try:
                    scr.addstr(y0 + y, x0, l[:wd - x0 - 1], base)
                except curses.error:
                    pass
            if focus and y0 + focus[0] < h:
                fy, a, b = focus
                try:
                    scr.addstr(y0 + fy, x0 + a, lines[fy][a:b][:wd - x0 - a - 1],
                               (curses.color_pair(2) if curses.has_colors() else curses.A_REVERSE) | curses.A_BOLD)
                except curses.error:
                    pass
            for my in t.msg_rows:
                if y0 + my < h:
                    try:
                        scr.addstr(y0 + my, x0 + 1, lines[my][1:-1][:wd - x0 - 2],
                                   (curses.color_pair(3) if curses.has_colors() else curses.A_BOLD))
                    except curses.error:
                        pass
            scr.refresh()
            ch = scr.get_wch()
            if isinstance(ch, str):
                k = KEYNAMES.get(ch, ch)
            else:
                k = km.get(ch, "")
            if k:
                t.key(k)
    curses.wrapper(main)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--keys", default=None, help="bez terminala: klawisze po przecinku, potem wydruk ekranu")
    ap.add_argument("--width", type=int, default=80)
    ap.add_argument("--height", type=int, default=24)
    a = ap.parse_args(argv)
    with open(a.spec, encoding="utf-8") as f:
        t = Tree(json.load(f))
    if a.keys is not None:
        t.resize(a.width, a.height)
        for k in [x for x in a.keys.split(",") if x != ""]:
            if t.done:
                break
            t.key({"comma": ","}.get(k, k))
        lines, focus = t.render()
        msgs = t.shown + ([t.msg] if t.msg else [])
        txt = "\n".join(lines) + "\n" + "".join("MSG: %s\n" % m for m in msgs)
        sys.stdout.buffer.write(txt.encode("utf-8"))
        sys.stdout.flush()
    else:
        run_curses(t)
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(t.result(), f, ensure_ascii=False)
    return 0 if t.done == "next" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
