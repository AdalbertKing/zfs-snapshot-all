#!/usr/bin/env python3
"""Klawisze przez PRAWDZIWA petle curses (R4-2), nie przez --keys.

Runda 3: 'u' na F4 i 's' na F2 przeszly wszystkie testy --render-once --keys
i byly martwe w GUI, bo petla curses oddaje kazdy drukowalny znak linii
polecen, zanim ekran go zobaczy. Ten skrypt uruchamia zfs-tui.py w pty,
naciska klawisze tak, jak terminal je wysyla (ESC [ 18 ~ to F7), i czyta to,
co program narysowal PO KAZDYM klawiszu.

  pty-keys.py <tui> <klawisze> -- <argumenty tui...>

<klawisze> po przecinku: F2..F10 albo pojedynczy znak. Wypisuje jeden blok
na klawisz: '=== <klawisz>' i tekst narysowany po nim (bez sekwencji ESC).
Kod wyjscia 2 = brak pty (np. Windows) -- suita to pomija i MOWI o tym.
"""
import os
import re
import select
import sys
import time

try:
    import pty
    import fcntl
    import struct
    import termios
except ImportError:
    sys.exit(2)

SEQ = {"F1": "\x1bOP", "F2": "\x1bOQ", "F3": "\x1bOR", "F4": "\x1bOS", "F5": "\x1b[15~", "F6": "\x1b[17~",
       "F7": "\x1b[18~", "F8": "\x1b[19~", "F9": "\x1b[20~", "F10": "\x1b[21~", "esc": "\x1b", "enter": "\r"}
ANSI = re.compile(r"\x1b(\[[0-9;?]*[A-Za-z@]|\][^\x07]*\x07|[()][0-9A-B]|[=>78]|O.)")


def drain(fd, quiet=0.6, limit=8.0):
    out, t0, last = b"", time.time(), time.time()
    while time.time() - t0 < limit:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            last = time.time()
        elif time.time() - last > quiet:
            break
    return ANSI.sub("", out.decode("utf-8", "replace"))


def main():
    tui, keys = sys.argv[1], sys.argv[2]
    rest = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm"
        os.environ.setdefault("LANG", "C.UTF-8")
        os.execvp(sys.executable, [sys.executable, tui] + rest)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 160, 0, 0))
    print("=== start")
    print(drain(fd, quiet=1.0))
    for k in [x for x in keys.split(",") if x]:
        os.write(fd, SEQ.get(k, k).encode("utf-8"))
        print("=== %s" % k)
        print(drain(fd))
    os.write(fd, SEQ["F10"].encode())
    drain(fd, quiet=0.3, limit=3)
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
