# zfs-snapshot-all — esencja

Wersja angielska: [ESSENTIALS.md](../en/ESSENTIALS.md).

Pakiet robi migawki ZFS, kopiuje je na drugi host (albo na dysk), przycina według retencji i pilnuje, czy
kopie są świeże. Jeden host — **kolektor** — zarządza całością: zakłada relacje, trzyma kopie, wysyła maile.
Wszystko w bashu, zadania chodzą z crona, a do codziennej pracy jest tekstowe GUI w konsoli serwera.

## Pojęcia

| pojęcie | znaczy |
|---|---|
| **relacja** | para: kolektor + host źródłowy (albo sam kolektor), wybrane datasety i harmonogram; ma nazwę |
| rodzaje relacji | **backup** (kolektor pobiera kopie i trzyma własną historię), **lustro** (to samo co na źródle), **kopia lokalna** (na tym samym hoście), **migawki lokalne / zdalne** (same migawki, bez kopii) |
| **szablon** | ile migawek trzymać na każdym szczeblu (godzinne, dobowe, tygodniowe…); w GUI do wyboru `default`, `full`, `d7h24`, `d30h24`, `m12w4d7h24-gfs` |
| **replika** | kopia kopii na osobny nośnik (USB albo druga pula), raz na dobę w nocy |
| **strażnik** | sprawdza wiek najnowszej migawki i alarmuje, gdy kopia przestała przychodzić |

## Pierwsze uruchomienie

1. Na kolektorze, jako root: pobierz pakiet i przygotuj host.

   ```bash
   git clone https://github.com/AdalbertKing/zfs-snapshot-all.git /root/scripts/zfs-snapshot-all
   cd /root/scripts/zfs-snapshot-all
   ./deploy.sh --backup-user=zfsbackup
   ```

2. Uruchom GUI i załóż pierwszą relację: **F3 Relacje**, klawisz **Ins**. Kreator pyta o rodzaj relacji,
   host źródłowy, datasety, cel i szablon, pokazuje plan i dopiero po **WYKONAJ** cokolwiek zmienia.

   ```bash
   zfs-backup gui
   ```

   Do hosta źródłowego kolektor potrzebuje wstępu SSH jako root; pakiet na źródle kreator zainstaluje sam.

3. Sprawdź po godzinie: **F2 Zadania** (co i kiedy biegnie), **F4 Historia** (przebiegi, błędy).

## Na co dzień

| chcę… | gdzie |
|---|---|
| zobaczyć, czy kopie są aktualne | F3 Relacje — kolumna „Kopie” |
| zmienić datasety, harmonogram, retencję | F3, Enter na relacji, `e` |
| wstrzymać relację (np. przegląd serwera) | F3, Enter, F8 Pauza |
| odzyskać dane | F11 Odzysk |
| dodać replikę na dysk | F6 Replika, Ins |
| zrobić to samo z linii poleceń | [KOMENDY.md](KOMENDY.md) |

## Gdzie dalej

- [JAK-TO-DZIALA.md](JAK-TO-DZIALA.md) — jak to działa w środku, prostym językiem;
- [WDROZENIE-PROXMOX.md](WDROZENIE-PROXMOX.md) — wdrożenie krok po kroku na dwóch hostach Proxmox;
- [WDROZENIE-KOLEKTOR-DWA-ZRODLA-REPLIKA.md](WDROZENIE-KOLEKTOR-DWA-ZRODLA-REPLIKA.md) — kolektor z dwoma
  źródłami i repliką na USB, łańcuch trzech hostów;
- [ODZYSK-Z-REPLIKI.md](ODZYSK-Z-REPLIKI.md) — odzysk z dysku repliki;
- [PAUZA-I-BLOKADA.md](PAUZA-I-BLOKADA.md) — pauza i twarda blokada relacji;
- [KOMENDY.md](KOMENDY.md) — ściąga poleceń;
- instrukcja techniczna (wszystkie opcje silników, config, alerty): [REFERENCJA.md](REFERENCJA.md).
