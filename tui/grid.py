#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""grid.py -- TABELA SZCZEBLI w curses: szczebel x liczba x kratka.

Wyjatek od zasady "formularze w whiptail" (wlasciciel, 2026-10-09): whiptail nie ma
wiersza z polem liczby i dwiema kratkami, a takie okno -- jak w menedzerach migawek
QNAP/Synology -- jest "duzo bardziej intuicyjne". Wolane z kreatorow whiptail
(tui/template.sh: szablon na F5; tui/new-relation.sh: retencja u zrodla) w jednym
miejscu; reszta kreatorow zostaje w whiptail.

    grid.py --spec SPEC.json --out OUT.json [--keys k1,k2,... [--width W --height H]]

SPEC: {"title", "hint", "note": [linie], "head": [3 naglowki kolumn],
       "fields": [{"key","label","value","edit":bool}],   -- nad tabela (nazwa)
       "after":  [{"key","label","value","edit":bool}],   -- pod tabela (opis)
       "rows": [{"key","label","glabel","on":bool,"can_off":bool,"value":"24",
                 "unit":"godz.","ref":"24 godz."|null,"q":bool|null,"family":"..."}],
       "taken": [nazwy zajete], "name_key": "name", "auto_desc": "desc"|null}
OUT:  {"action":"next"|"back", "fields":{key: value}, "rows":[{"key","on","value","q"}]}

--keys: bez terminala -- nazwy klawiszy (up, down, left, right, tab, btab, space,
enter, esc, bs, albo jeden znak), potem wydruk ekranu; tak to sprawdzaja testy.
Okno samo nie zapisuje niczego poza OUT -- zapis robi czasownik w kreatorze.
"""
import argparse
import json
import re
import sys

NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")


class Grid(object):
    def __init__(self, spec):
        self.spec = spec
        self.fields = [dict(f) for f in spec.get("fields", [])]
        self.after = [dict(f) for f in spec.get("after", [])]
        self.rows = [dict(r) for r in spec.get("rows", [])]
        for r in self.rows:
            r["value"] = str(r.get("value") or "")
        self.desc_key = spec.get("auto_desc")
        self.desc_touched = False
        self.msg = ""
        self.shown = []      # --keys: kazdy komunikat pokazany w trakcie (test go widzi)
        self.done = None
        self.items = self._items()
        self.cur = 0
        # kursor startuje na pierwszej rzeczy do zmiany w tabeli (albo na nazwie)
        for i, it in enumerate(self.items):
            if it[0] in ("field",) or it[0] in ("val", "on", "q"):
                self.cur = i
                break
        self._auto_desc()

    # -- elementy, po ktorych chodzi kursor: (rodzaj, indeks, linia)
    def _items(self):
        out = []
        for i, f in enumerate(self.fields):
            if f.get("edit", True):
                out.append(("field", i, "f%d" % i))
        for i, r in enumerate(self.rows):
            if r.get("can_off", True):
                out.append(("on", i, "r%d" % i))
            if r.get("editable", True) and r.get("value") != "-":
                out.append(("val", i, "r%d" % i))
            if r.get("q") is not None:
                out.append(("q", i, "r%d" % i))
        for i, f in enumerate(self.after):
            if f.get("edit", True):
                out.append(("after", i, "a%d" % i))
        out.append(("btn", "next", "b"))
        out.append(("btn", "back", "b"))
        return out

    def _field(self, kind, i):
        return self.fields[i] if kind == "field" else self.after[i]

    def _auto_desc(self):
        if not self.desc_key or self.desc_touched:
            return
        parts, qs = [], []
        for r in self.rows:
            if r.get("on") and r.get("value") not in ("", "-", None) and r.get("glabel"):
                parts.append(u"%s %s" % (r["value"], r["glabel"]))
            if r.get("q"):
                qs.append(r.get("glabel") or r.get("label"))
        txt = u"%s; %s" % (u" + ".join(parts) or u"bez szczebli",
                           (u"zamraża: " + u", ".join(qs)) if qs else u"bez zamrażania")
        for f in self.after + self.fields:
            if f.get("key") == self.desc_key:
                f["value"] = txt

    # -- klawisze
    def key(self, k):
        if self.msg:
            self.shown.append(self.msg)
        self.msg = ""
        kind, idx, line = self.items[self.cur]
        if k in ("tab", "right") and not (k == "right" and kind in ("field", "after")):
            if k == "tab" or self._same_line(self.cur + 1, line):
                self.cur = min(self.cur + 1, len(self.items) - 1)
            return
        if k in ("btab", "left") and not (k == "left" and kind in ("field", "after")):
            if k == "btab" or self._same_line(self.cur - 1, line):
                self.cur = max(self.cur - 1, 0)
            return
        if k == "down":
            self._move_line(+1)
            return
        if k == "up":
            self._move_line(-1)
            return
        if k == "esc":
            self.done = "back"
            return
        if k == "enter":
            if kind == "btn" and idx == "back":
                self.done = "back"
            elif self.validate():
                self.done = "next"
            return
        if k == "space":
            if kind == "on":
                self.toggle_on(idx)
            elif kind == "q":
                r = self.rows[idx]
                if r.get("on"):
                    r["q"] = not r["q"]
                    self._auto_desc()
            elif kind in ("field", "after"):
                self._type(kind, idx, " ")
            return
        if k == "bs":
            if kind == "val":
                self.rows[idx]["value"] = self.rows[idx]["value"][:-1]
                self._auto_desc()
            elif kind in ("field", "after"):
                f = self._field(kind, idx)
                f["value"] = f["value"][:-1]
                if f.get("key") == self.desc_key:
                    self.desc_touched = True
            return
        if len(k) == 1 and k.isprintable():
            if kind == "val":
                if k.isdigit() and len(self.rows[idx]["value"]) < 5 and self.rows[idx].get("on"):
                    self.rows[idx]["value"] += k
                    self._auto_desc()
            elif kind in ("field", "after"):
                self._type(kind, idx, k)

    def _type(self, kind, idx, ch):
        f = self._field(kind, idx)
        if len(f["value"]) < 60:
            f["value"] += ch
        if f.get("key") == self.desc_key:
            self.desc_touched = True

    def _same_line(self, j, line):
        return 0 <= j < len(self.items) and self.items[j][2] == line

    def _move_line(self, d):
        line = self.items[self.cur][2]
        col = [it for it in self.items if it[2] == line].index(self.items[self.cur])
        j = self.cur
        while 0 <= j + d < len(self.items):
            j += d
            if self.items[j][2] != line:
                nl = self.items[j][2]
                same = [k for k, it in enumerate(self.items) if it[2] == nl]
                self.cur = same[min(col, len(same) - 1)]
                return

    def toggle_on(self, i):
        r = self.rows[i]
        if r.get("on"):
            fam = r.get("family")
            others = [x for j, x in enumerate(self.rows) if j != i and x.get("on") and fam and x.get("family") == fam]
            if fam and not others:
                self.msg = u"Tego szczebla nie da się wyłączyć: jego migawek (%s) nie sprząta żaden inny." % fam
                return
            r["on"] = False
            if r.get("q"):
                r["q"] = False
        else:
            r["on"] = True
        self._auto_desc()

    def validate(self):
        nk = self.spec.get("name_key")
        for f in self.fields + self.after:
            if f.get("key") == nk:
                v = f["value"].strip()
                if not v or not NAME_RE.match(v):
                    self.msg = u"Zła nazwa: tylko litery, cyfry, kropka, minus, podkreślenie."
                    return False
                if v in (self.spec.get("taken") or []):
                    self.msg = u"Szablon '%s' już jest -- podaj inną nazwę." % v
                    return False
                f["value"] = v
        for r in self.rows:
            if r.get("on") and r.get("value") not in ("-",) and r.get("editable", True):
                v = r["value"]
                if not v.isdigit() or int(v) < 1:
                    self.msg = u"%s: podaj liczbę większą od zera (albo wyłącz szczebel)." % r["label"]
                    return False
        return True

    def result(self):
        fields = {}
        for f in self.fields + self.after:
            fields[f["key"]] = f["value"]
        return {"action": self.done or "back", "fields": fields,
                "rows": [{"key": r["key"], "on": bool(r.get("on")), "value": r.get("value"),
                          "q": r.get("q")} for r in self.rows]}

    # -- obraz: lista linii + (linia, kolumna od, kolumna do) kursora
    def render(self, width):
        w = max(56, min(width - 4, 78))
        inner = w - 4
        lines, spans = [], {}
        hint = self.spec.get("hint") or u"↑↓ wiersz ←→ pole spacja kratka cyfry liczba Enter=Dalej Esc=Wstecz"

        def add(text, key=None, segs=None):
            lines.append(text)
            if segs:
                for kk, a, b in segs:
                    spans[kk] = (len(lines) - 1, a, b)

        add(u"")
        for i, f in enumerate(self.fields):
            lab = u" %-7s " % (f["label"] + ":")
            val = f["value"]
            add(lab + (val + u"_" * max(0, 30 - len(val))) if f.get("edit", True) else lab + val,
                segs=[(("field", i), len(lab), len(lab) + max(30, len(val)))] if f.get("edit", True) else None)
        if self.fields:
            add(u"")
        head = self.spec.get("head") or [u"SZCZEBEL", u"TRZYMA", u""]
        add(u"      %-16s %-14s %s" % tuple((head + [u"", u"", u""])[:3]))
        for i, r in enumerate(self.rows):
            on = u"[X]" if r.get("on") else u"[ ]"
            if not r.get("can_off", True):
                on = u"   "
            val = r.get("value")
            if r.get("ref") is not None:
                mid = u"%-14s" % r["ref"]
                vtxt = (u"%s %s" % (val, r.get("unit") or "")).strip() if r.get("on") else u"—"
                text = u"  %s %-16s %s %s" % (on, r["label"], mid, vtxt)
                vpos = 2 + 3 + 1 + 16 + 1 + 14 + 1
                qtxt = None
            else:
                vtxt = (u"%s %s" % (val, r.get("unit") or "")).strip() if (val not in ("", "-") and r.get("on")) else u"—"
                text = u"  %s %-16s %-13s" % (on, r["label"], vtxt)
                vpos = 2 + 3 + 1 + 16 + 1
                qtxt = (u"[X]" if r.get("q") else u"[ ]") if r.get("q") is not None else (u" — " if r.get("ref") is None else None)
                if qtxt is not None:
                    text += u" " + qtxt
            qpos = vpos + 14
            segs = [(("on", i), 2, 5), (("val", i), vpos, vpos + max(len(vtxt), 3)), (("q", i), qpos, qpos + 3)]
            add(text, segs=segs)
        add(u"")
        for i, f in enumerate(self.after):
            lab = u" %-7s " % (f["label"] + ":")
            val = f["value"]
            add(lab + val + (u"_" if f.get("edit", True) else u""),
                segs=[(("after", i), len(lab), len(lab) + max(1, len(val)))])
        for n in self.spec.get("note") or []:
            add(u" " + n)
        add(u"")
        bl = u" " * max(1, (inner - 26) // 2)
        nxt, back = u"< Dalej >", u"< Wstecz >"
        add(bl + nxt + u"      " + back,
            segs=[(("btn", "next"), len(bl), len(bl) + len(nxt)),
                  (("btn", "back"), len(bl) + len(nxt) + 6, len(bl) + len(nxt) + 6 + len(back))])
        add(u" " + self.msg if self.msg else u"")
        title = u" %s " % (self.spec.get("title") or u"Szczeble")
        top = u"┌─" + title + u"─" * max(0, w - 3 - len(title)) + u"┐"
        bot = u"└─ " + hint[:w - 6] + u" " + u"─" * max(0, w - 5 - len(hint[:w - 6])) + u"┘"
        out = [top] + [u"│" + (l[:w - 2]).ljust(w - 2) + u"│" for l in lines] + [bot]
        kind, idx, _ = self.items[self.cur]
        sp = spans.get((kind, idx))
        focus = (sp[0] + 1, sp[1] + 1, sp[2] + 1) if sp else None
        return out, focus


KEYNAMES = {"\t": "tab", " ": "space", "\n": "enter", "\r": "enter", "\x1b": "esc", "\x7f": "bs", "\x08": "bs"}


def run_curses(g):
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
              curses.KEY_BTAB: "btab", curses.KEY_BACKSPACE: "bs", curses.KEY_ENTER: "enter", 10: "enter", 13: "enter",
              9: "tab", 27: "esc", 127: "bs", 8: "bs", 32: "space"}
        while g.done is None:
            h, wd = scr.getmaxyx()
            lines, focus = g.render(wd)
            scr.erase()
            base = curses.color_pair(1) if curses.has_colors() else curses.A_NORMAL
            y0 = max(0, (h - len(lines)) // 2)
            x0 = max(0, (wd - len(lines[0])) // 2)
            for y, l in enumerate(lines):
                if y0 + y >= h - 1:
                    break
                try:
                    scr.addstr(y0 + y, x0, l[:wd - x0 - 1], base)
                except curses.error:
                    pass
            if focus:
                fy, a, b = focus
                if y0 + fy < h - 1:
                    try:
                        scr.addstr(y0 + fy, x0 + a, lines[fy][a:b], (curses.color_pair(2) if curses.has_colors() else curses.A_REVERSE) | curses.A_BOLD)
                    except curses.error:
                        pass
            if g.msg:
                try:
                    scr.addstr(min(h - 2, y0 + len(lines)), x0, g.msg[:wd - x0 - 1], (curses.color_pair(3) if curses.has_colors() else curses.A_BOLD))
                except curses.error:
                    pass
            scr.refresh()
            ch = scr.get_wch()
            if isinstance(ch, str):
                k = KEYNAMES.get(ch, ch)
            else:
                k = km.get(ch, "")
            if k:
                g.key(k)
    curses.wrapper(main)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--keys", default=None, help="bez terminala: klawisze po przecinku, potem wydruk ekranu")
    ap.add_argument("--width", type=int, default=80)
    a = ap.parse_args(argv)
    with open(a.spec, encoding="utf-8") as f:
        g = Grid(json.load(f))
    if a.keys is not None:
        for k in [x for x in a.keys.split(",") if x != ""]:
            if g.done:
                break
            g.key({"comma": ","}.get(k, k))
        lines, focus = g.render(a.width)
        msgs = g.shown + ([g.msg] if g.msg else [])
        txt = "\n".join(lines) + "\n" + "".join("MSG: %s\n" % m for m in msgs)
        sys.stdout.buffer.write(txt.encode("utf-8"))
        sys.stdout.flush()
    else:
        run_curses(g)
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(g.result(), f, ensure_ascii=False)
    return 0 if g.done == "next" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
