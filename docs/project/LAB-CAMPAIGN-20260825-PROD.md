# LAB-CAMPAIGN 2026-08-25 — trzy hosty na profilu `prod`

Kampania na żywej infrastrukturze. Kolektor **pve9** dostaje **dwie** relacje,
obie na profilu `prod` (cztery samodzielne tiery, bez drabiny GFS):

- **p1**: `pve1 (192.168.28.9) → pve9`, konto `root`
- **p2**: `pve2 (192.168.28.8) → pve9`, konto `root`

**Po co akurat ten kształt.** Do dziś druga relacja na hoście z profilem
płaskim była odrzucana — `detect_profile_gfs` odpowiadał na pytanie o kształt
(„czy tiery sprzątają same siebie?"), a odmowa w `ensure_cron_config` dotyczy
pytania o nazwę (zamrożona rodzina `standard_*`). `prod` jest płaski
z definicji, więc wyglądał jak legacy. Ten lab jest **żywym dowodem** poprawki
`46cd7e0` — i jego kontrolą negatywną.

## 0. Zasady i granice

- **Produkcji nie tykamy.** pve1 i pve2 to hosty produkcyjne metropolis; lab
  dostaje wyłącznie własne drzewa (`hdd/lab1prod`, `hdd/lab2prod`). Każda
  zmiana crontaba udokumentowana diffem przed/po.
- **Żadnych holdów poza drzewami labowymi** — `zfs hold` na datasecie
  replikowanym przez pvesr zakleszcza replikację na stałe.
- **Gałąź, nie `main`.** Profil `prod` i `migrate-profile --profile=` żyją na
  `stage/profile-one-file`. pve9 dostaje **drugi, osobny checkout**
  (`/root/zfs-snapshot-all-stage`); istniejący checkout na `main` NIE jest
  ruszany. To także jedyny sposób na uczciwą kontrolę A/B — patrz P1.
- Werdykty czytamy z pola `rc=` w logu, nie ze statusu linii crona.
- Linie crona uruchamiamy **verbatim**; rekonstruowana linia nie jest dowodem.
- Po kampanii: relacje usunięte, drzewa labowe skasowane, drugi checkout
  usunięty, crontaby zdiffowane.

## 1. Stan zastany (zmierzony 2026-08-25 przed startem)

| host | adres | repo | gałąź / HEAD | datasety `lab` | crontab (root) |
|---|---|---|---|---|---|
| pve9 (kolektor) | .99 | `/root/zfs-snapshot-all` | `main` / `441efaf` | brak | 5 linii |
| pve1 (źródło A) | .9 | `/root/scripts/zfs-snapshot-all` | `main` / `f4d57e3` | brak | — |
| pve2 (źródło B) | .8 | `/root/scripts/zfs-snapshot-all` | `main` / `f4d57e3` | brak | — |

pve9: `/etc/zfs-snapshot-all/` zawiera wyłącznie `clients/` i `peers/` —
**żadnego pliku configu**. Wszystkie 20 rekordów klientów mają ostatni
`STATE=removed`. Poprzednia kampania rozebrana czysto.

Pule pve9: `hdd`, `hdd/osrc`.

## 2. Przewidywania spisane PRZED biegiem

**P1 — hipoteza główna, z kontrolą negatywną.**
Z kodem z gałęzi **obie** relacje aktywują się na jednym kolektorze `prod`.
Z kodem z `main` i **tym samym** profilem `prod` druga relacja zostanie
odrzucona komunikatem *„uses the pre-GFS profile (standard_* still carries
prune_schedule)"*. Jedna zmienna między biegami: kod. Profil, hosty, datasety
i konta identyczne.

**P2 — kształt configu.** Każda sekcja `[dataset:]` dostanie
`use_template = profile__prod__hourly,...daily,...weekly,...monthly`
i **nie powstanie żadna sekcja `[prune:]` drabiny** — w `prod` każdy tier
sprząta własną rodzinę własnym `prune_schedule`.

**P3 — rozrzutu NIE BĘDZIE, i to nie jest nowa wada.** Cztery tiery `prod`
deklarują cztery różne kadencje, więc `schedule_template_expr` zwraca pustkę
i rozrzut nie pisze `send_schedule` do sekcji (pole sekcji nadpisałoby
*każdy* tier, zwalając daily/weekly/monthly na godzinową). Skutek: obie
relacje wystartują w **tej samej** minucie profilu — send `:37`, prune `:51`.
To znana, nazwana granica, nie odkrycie. Lab ma ją **potwierdzić pomiarem**.

**P4 — okno czasowe.** W trakcie labu odpali wyłącznie tier godzinowy
(`37 * * * *`, prune `51 * * * *`). Daily/weekly/monthly uruchomię **verbatim
z crontaba**, ręcznie, bo inaczej nie ma jak ich zobaczyć.

**P5 — monitor.** Tier `monthly` nie ma progów (`monitor_warn`/`monitor_crit`
zdjęte na pve1 2026-07-22 po powodzi 480 sprawdzeń dziennie i przepisane wraz
z tym brakiem). Spodziewam się linii monitora dla hourly/daily/weekly i
**żadnej** dla monthly.

**P6 — cztery rodziny.** Na źródle powstaną `automated_hourly_*`,
`automated_daily_*`, `automated_weekly_*`, `automated_monthly_*` — osobne
prefiksy, każdy ze swoją retencją, w przeciwieństwie do `default`, gdzie jest
jedna rodzina i cztery liczniki.

## 3. Przebieg

(uzupełniane w trakcie)
