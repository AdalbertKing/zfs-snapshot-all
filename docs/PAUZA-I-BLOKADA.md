# Pauza i blokada relacji — instrukcja operatorska

Dwa różne narzędzia do dwóch różnych sytuacji. Projekt: `docs/adr/ADR-0012-pair-pause-architecture.md`
i `docs/design/pair-pause.md`. Tutaj jest tylko to, co się wpisuje i co się widzi.

## Którego użyć

| | **pauza miękka** (`pause-client`) | **blokada twarda** (`disable-client`) |
|---|---|---|
| Kto egzekwuje | kolektor (ten host) | **peer** (drugi serwer) |
| Zatrzymuje zadania z crona | tak | tak |
| Zatrzymuje ręczne polecenie **z** etykietą `-L` | tak | tak |
| Zatrzymuje ręczne polecenie **bez** `-L` | **nie** | **tak** |
| Wymaga kontaktu z peerem | nie | tak — peer musi być osiągalny (zapis, a potem osobny odczyt zwrotny) |
| Typowe użycie | okno serwisowe, wymiana dysku, głośny sąsiad na łączu | „ta relacja ma stać i nikt ma jej przypadkiem nie ruszyć" |

Obie zostawiają crona, config, klucze i granty ZFS **nietknięte** — nic nie jest przepisywane,
usuwane ani nadawane na nowo. Retencja (`delsnaps`) chodzi dalej w obu przypadkach: to, co już
się skopiowało, ma być dalej poprawnie przycinane.

**Granica, o której trzeba wiedzieć:** klucz samej relacji może zdjąć swoją blokadę
(`PAIR-CONTROL enable`). Blokada twarda zatrzymuje automat, pomyłkę i zwykłe ręczne polecenie —
nie zatrzyma kogoś, kto ma ten klucz i świadomie go użyje. Każde zdjęcie trafia do logu na peerze.

---

## Pauza miękka

```bash
zfs-backup.sh pause-client pve2 --reason='wymiana dysku w szafie'
```

```text
>>> client 'pve2' paused (PAUSED_LOCAL). Managed jobs and labeled manual runs now exit
    'SKIPPED: relationship pve2 is paused' before any snapshot/SSH work.
>>> LIMITATION: this is logical pause -- a manual snapget.sh/snapsend.sh that OMITS '-L pve2'
    is not blocked. For enforcement at the peer, including unlabeled manual commands,
    use: zfs-backup.sh disable-client pve2
```

Zdjęcie:

```bash
zfs-backup.sh resume-client pve2
```

Co widać w logu crona, gdy zadanie trafi na pauzę:

```text
2026-08-06 22:34:20 - SKIPPED: relationship pve2 is paused (resume: zfs-backup.sh resume-client pve2)
```

i w `zfs-snapshot-stats.log` — **własny status**, nigdy udawany sukces:

```json
{"time":"...","script":"snapget.sh","dataset":"...","status":"skipped_paused","duration_s":0}
```

Monitor w tym czasie nie budzi nikogo, ale też nie milczy:

```text
OK -- relationship pve2 is paused (zfs-backup.sh pause-client); staleness is expected until resume-client
```

---

## Blokada twarda

```bash
zfs-backup.sh disable-client pve2 --reason='postój do odwołania'
```

```text
>>> local pause established for 'pve2'
>>> asking the peer to disable this relationship...
>>> client 'pve2' is DISABLED: the peer refuses this relationship's data-plane commands,
    including manual ones that carry no -L.
>>> LIMIT: the relationship's own key can lift this itself (…enable-client pve2 …)
```

Kolejność jest stała i celowa: **najpierw pauza lokalna** (żeby żaden job nie wystartował w oknie
między decyzją a dotarciem informacji do peera), potem peer, na końcu **odczyt zwrotny** — bo
odpowiedź na zapis mówi tylko, co bramka sądziła, że zrobiła.

Zdjęcie — dokładnie odwrotnie: najpierw peer, weryfikacja, dopiero na końcu pauza lokalna.

```bash
zfs-backup.sh enable-client pve2
```

Gdy peer jest nieosiągalny, nic nie jest zmyślane:

```text
!!! the peer did NOT confirm the disable (ssh/gate said: …)
!!! STATE: PAUSED_LOCAL, peer NOT disabled -- scheduled jobs and labeled manual runs are stopped,
    but a manual command that omits -L would still reach the peer.
FATAL: retry the same command once the peer is reachable … it is a safe retry
```

Ponowienie jest bezpieczne: verby po stronie peera są idempotentne.

Co zobaczy ktoś, kto mimo blokady spróbuje ręcznie:

```text
PAIR_DISABLED: relationship pve2 is disabled by administrator
```

Kody wyjścia bramki — rozróżnialne, bo przez ssh to jedyna informacja, jaka wraca:

| kod | znaczenie |
|---|---|
| 91 | `PAIR_GATE_MISUSE` — zła etykieta, brak etykiety, próba sesji interaktywnej |
| 92 | `PAIR_UNKNOWN` — na tym hoście nie ma takiej relacji |
| 93 | `PAIR_DISABLED` — relacja zablokowana |
| 255 | to ssh, nie my: brak połączenia lub uwierzytelnienia |

---

## Stan

```bash
zfs-backup.sh status              # lista
zfs-backup.sh status pve2         # szczegóły
```

```text
pve2                 state=active             endpoint=192.168.28.8:22  PAUSED_LOCAL
```

```text
Klient:            pve2
Stan:              active
Pauza:             PAUSED_LOCAL od 2026-08-06 22:30:44 (powod: postój do odwołania)
                   joby i reczne uruchomienia Z etykieta '-L pve2' sa pomijane;
                   reczne uruchomienie BEZ etykiety NIE jest blokowane (pauza logiczna,
                   nie granica bezpieczenstwa). Wznowienie: ./zfs-backup.sh resume-client pve2
```

Stan po stronie peera, gdy chcesz spytać wprost:

```bash
ssh -i /root/.ssh/pairing/<peer>_ed25519 zfsbackup-<kolektor>@<peer> 'PAIR-CONTROL status'
```

```text
PAIR_STATE=DISABLED
PAIR_LABEL=pve1
DISABLED_AT=2026-08-06 22:30:51
DISABLED_FROM=192.168.28.9
```

---

## Co się zmieniło w configu i cronie

### Config — jedno pole

`activate-client` dopisuje `pair_label` do każdej sekcji, którą generuje. Ręcznie pisane sekcje
bez tego pola zachowują się dokładnie tak jak wcześniej — brak etykiety to brak bramkowania.

```ini
[dataset:hdd/backups/arc/alpha/tank/data]
	use_template = hourly
	src          = zfsbackup-arc@10.0.0.1:tank/data
	flags        = -i -K /root/.ssh/pairing/alpha_ed25519
	pair_label   = alpha
	notify       = alpha-data
```

Pole jest **dziedziczone znikąd** — ani z `[template:]`, ani z `[defaults]`. Etykieta, która
rozlałaby się po nieswoich sekcjach, oznaczałaby, że jedna pauza zatrzymuje cudzy backup.

Na `[prune:]` `pair_label` też jest dozwolone, ale dociera **wyłącznie do monitora** tej sekcji.
Sam `delsnaps` nigdy nie jest bramkowany.

### Cron — jedna flaga

Linia transferu (skrócona):

```text
59 * * * * … snapget.sh -m "automated_" -i -K …/alpha_ed25519 -A -L alpha "zfsbackup-arc@10.0.0.1:tank/data" "hdd/backups/arc/alpha" …
```

Linia monitora:

```text
*/15 * * * * d=$(… check-snap-age.sh -L alpha "hdd/backups/arc/alpha/tank/data" "automated_" 90m 3h 2>&1); …
```

Linia retencji — **celowo bez `-L`**:

```text
30 2 * * * … delsnaps.sh "hdd/backups/arc/alpha/tank/data,…" "automated_" -H24 …
```

Dwie relacje o identycznych progach nie scalą się w jedną linię monitora: `pair_label` wchodzi
do klucza grupowania. Inaczej pauza jednej wyciszałaby alarm drugiej.

### Ta sama linia po ludzku

Kto czyta te linie raz na pół roku, przy awarii, nie ma czasu odtwarzać znaczenia flag z pamięci.
Więc rozbiór tego samego przykładu, kawałek po kawałku:

```text
-i -K /root/.ssh/pairing/alpha_ed25519 -A -L alpha "zfsbackup-arc@10.0.0.1:tank/data" "hdd/backups/arc/alpha"
```

| fragment | co znaczy | skąd się wziął |
|---|---|---|
| `-i` | przy nadrabianiu zaległości **przeskocz od razu do najnowszego stanu**, zamiast przechodzić przez wszystkie snapshoty po drodze. Szybciej i mniej danych, ale na kopii nie będzie stanów pośrednich | z Twojego `flags` w configu |
| `-K …/alpha_ed25519` | loguj się na drugi serwer **tym konkretnym kluczem**. Robi to, co `ssh -i`, ale litera `i` była już zajęta (patrz wyżej), więc klucz dostał `K` | z Twojego `flags` w configu |
| `-A` | **zmierz łącze i sam zdecyduj**, czy kompresja się opłaca. Wynik pamiętany tydzień: prędkość łącza per host, podatność danych per dataset | dokłada generator, domyślnie |
| `-L alpha` | ten transfer należy do **relacji `alpha`**. Jedyny powód: gdy relacja jest zapauzowana lub zablokowana, zadanie wycofa się, zanim cokolwiek zrobi | z `pair_label` |
| `"zfsbackup-arc@10.0.0.1:tank/data"` | **skąd bierzemy**: konto `zfsbackup-arc` na `10.0.0.1`, dataset `tank/data`. Adres dosłowny — dokładnie to, co pokazuje tam `zfs list` | z `src` |
| `"hdd/backups/arc/alpha"` | **katalog bazowy, nie miejsce docelowe.** Skrypt dokleja pod spodem oryginalną ścieżkę ze źródła | z nagłówka sekcji `[dataset:]` |

Ostatni wiersz to najczęstsze nieporozumienie i realna przyczyna awarii w tym projekcie. Dane
wylądują **nie** w `hdd/backups/arc/alpha`, tylko:

```text
hdd/backups/arc/alpha/tank/data
```

Seed wpisany kiedyś o jeden poziom za głęboko sprawił, że każdy przebieg robił pełną kopię od
zera — a monitoring twierdził, że wszystko gra, bo zaglądał w to samo złe miejsce.

**Całość jednym zdaniem:** *co godzinę zabierz z `tank/data` na `10.0.0.1` to, czego jeszcze nie
mam, zaloguj się kluczem alpha, przy zaległościach skocz od razu do najnowszego stanu, sam
zdecyduj o kompresji, odłóż to pod `hdd/backups/arc/alpha` — i odpuść całkiem, jeśli relacja
`alpha` jest zapauzowana.*

---

## Strona peera — co robi `deploy.sh`

Nic nie trzeba wpisywać ręcznie: `--join` instaluje bramkę przy zakładaniu relacji.

```text
>>> pair gate installed at /usr/local/sbin/zfs-pair-gate; relationship state at /var/lib/zfs-snapshot-all/relationships/pve1
>>> installed the gated key line in /home/zfsbackup-pve1/.ssh/authorized_keys
    (forced command: /usr/local/sbin/zfs-pair-gate pve1); every other line preserved
```

Linia klucza po tej operacji:

```text
command="/usr/local/sbin/zfs-pair-gate pve1",restrict ssh-ed25519 AAAAC3Nza… 
```

Etykieta w tej linii to **nazwa kolektora**, nie nazwa klienta z kolektora — bramka rozpoznaje
relację po kluczu, więc to, jak Ty ją nazywasz u siebie, nie ma dla niej znaczenia.

Trzy rzeczy warte zapamiętania:

- bramka leży **poza** katalogiem repozytorium (`/usr/local/sbin`), żeby cofnięcie kodu nie mogło
  jej usunąć;
- pozostałe linie w `authorized_keys` — Twoje własne klucze, inne narzędzia — zostają bajt w bajt;
  podmiana jest atomowa i odmawia, jeśli nie potrafi zachować właściciela pliku;
- stary „goły" klucz tej samej relacji **nie zostaje obok** bramkowanego. Zostawiony
  uwierzytelniałby się z pominięciem bramki i każda blokada byłaby fikcją.

Zdjęcie blokady bezpośrednio na peerze, gdy kolektor nie ma jak dojść:

```bash
rm -f /var/lib/zfs-snapshot-all/relationships/<etykieta>/disabled
```

---

## Pułapki z realnych przebiegów

- **`verify-endpoint` przy zablokowanej relacji.** Jego sonda to komenda data-plane, więc peer ją
  odrzuca. Narzędzie mówi to wprost („relationship is DISABLED at the peer … This is not an
  address problem") — nie szukaj awarii sieci, tylko najpierw zdejmij blokadę.
- **`remove-client` nie sprząta peera.** Wypisuje polecenia do wykonania tam (`deploy.sh --leave=<etykieta>`)
  i to trzeba zrobić ręcznie. Pominięcie zostawia manifest, który przy następnym `--join` pod tą
  samą etykietą słusznie zablokuje enrolment jako kolizję.
- **Jedna relacja na parę hostów.** Drugi klient na ten sam adres peera splata stan po obu
  stronach. Do testów bierz osobną maszynę (choćby jednorazowy kontener).
