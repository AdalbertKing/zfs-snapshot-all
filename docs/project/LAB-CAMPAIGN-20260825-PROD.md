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
  (`/root/zfs-stage`); istniejący checkout na `main` NIE jest
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

## 3. Przebieg i wyniki

Wersja kodu na kolektorze: **osobny** checkout `/root/zfs-stage` z gałęzi
`stage/profile-one-file`. Checkout `main` (`/root/zfs-snapshot-all`) **nie był
ruszany** przez całą kampanię.

### 3.1 ZNALEZISKO F1 — `prod` nie potrafił utworzyć PIERWSZEJ relacji

Pierwsza komenda, pierwsza relacja:

```
gen-cron.sh: error: [prune:hdd/prodlab-k1/192.168.28.9] has no use_template
P1 EXIT=1
```

`PROFILE_GFS` to odpowiedź `detect_profile_gfs` o **zainstalowanym configu**.
Świeży config nic nie mówi, więc odpowiedź brzmi „drabina" — i drabina profilu
płaskiego została zaplanowana, wyemitowana i odrzucona za brak `use_template`.

Czternaście asercji jednostkowych tego nie złapało, bo ćwiczyły
`ensure_cron_config` (szablony, odmowa zamrożonego kształtu). Drabinę emituje
warstwę dalej `emit_client_sections`, i nic nie przejechało tej ścieżki
profilem płaskim po świeżym configu. **Lab znalazł to w trzy minuty.**

Poprawka `3f25b8e`: `profile_declares_ladder()` pyta o jedyną rzecz, która nie
może być błędna — czy profil, który ma zostać **zapisany**, niesie fragment
`[prune]`. `prod` nie niesie, bo jego tiery sprzątają własne rodziny.

### 3.2 P1 POTWIERDZONE — z żywą kontrolą negatywną

Kontroli **nie dało się** zrobić na `main`: `main` poprzedza jednoplikowy format
profilu i odmawia `profiles/prod` po nazwie pliku (`templates.conf is missing`).
Zrobiona więc na **opublikowanym commicie tej samej gałęzi**, jeden przed
rozdzieleniem kształtu od nazwy — jedna zmienna, wszystko inne identyczne.

| kod | druga relacja `p2` |
|---|---|
| `1420ea9` (przed rozdzieleniem) | **FATAL:** *„uses the pre-GFS profile (standard_* still carries prune_schedule), which is frozen"* — EXIT=1 |
| `3f25b8e` (po) | `client 'p2' is active` — EXIT=0 |

Komunikat odmowy nazywał rodzinę `standard_*`, której w tym pliku nie ma.
`prod` był profilem **jednej relacji na host**, i nie dotyczyło to migracji —
to zwykła ścieżka `activate-client` dla drugiego klienta.

### 3.3 P2, P5, P6 — potwierdzone pomiarem

Crontab pve9: **+23 linie** (diff `/root/cron9.pre` → `/root/cron9.post`),
produkcyjne linie nietknięte.

- **8 linii `snapget`** = 2 relacje × 4 tiery.
- **4 linie `delsnaps`**, i to nie jest brak retencji dla `p2` — gen-cron
  **scalił** oba datasety w jedno wywołanie na tier:
  `"hdd/prodlab-k1/.../at,hdd/prodlab-k2/.../at" "automated_hourly" -H24`.
- **6 linii monitora** = 2 relacje × 3 tiery. **Żadnej dla `monthly`** —
  dokładnie tak, jak profil został przepisany z pve1 (P5).
- **Żadnej sekcji `[prune:]` drabiny** — cztery osobne `delsnaps`, każdy na
  swojej rodzinie z własnym licznikiem: `-H24`, `-D7`, `-W4`, `-M6` (P2).
- Cztery rodziny na kolektorze: `automated_hourly_`, `_daily_`, `_weekly_`,
  `_monthly_` (P6).

### 3.4 P3 potwierdzone — rozrzutu nie ma, i silnik to mówi

```
>>> schedule: 'send_schedule' differs between the tiers this profile references
    -- leaving it to the profile rather than collapsing them onto one cadence
```

Obie relacje stoją na minutach profilu (send `:37`, prune `:51`). To znana
granica, nie odkrycie: pole zapisane w SEKCJI nadpisuje **każdy** tier, więc
jedna wartość zwaliłaby daily/weekly/monthly na kadencję godzinową.

### 3.5 ZNALEZISKO F2 — scalona linia prune niesie JEDNĄ etykietę

Cztery linie `delsnaps` pokrywają oba datasety, ale powiadomienie każdej z nich
mówi `(p1-at)`. Awaria przy sprzątaniu datasetu **p2** zgłosi się pod nazwą
relacji **p1**. Niska waga, ale to ta sama klasa co „nigdy nie obwiniaj złej
rzeczy". Nie naprawione.

### 3.6 ZNALEZISKO F3 — trzy z czterech tierów `prod` nie powstają na koncie delegowanym

Bieg **verbatim** wszystkich ośmiu linii, obie relacje, przed nadaniem quiesce:

```
hourly  (p1-at) rc=0      hourly  (p2-at) rc=0
daily   (p1-at) rc=1      daily   (p2-at) rc=1
weekly  (p1-at) rc=1      weekly  (p2-at) rc=1
monthly (p1-at) rc=1      monthly (p2-at) rc=1
```

```
Quiesce[192.168.28.8]: this account cannot quiesce guests on the source host:
it is not root, and /usr/local/sbin/zfs-quiesce-helper is not usable through sudo.
Quiesce: refusing to continue with unquiesced snapshots
```

Symetrycznie na **dwóch niezależnych hostach**. `prod` ma `quiesce = auto` na
daily/weekly/monthly; konto delegowane nie może zamrozić gościa, więc snapshot
**nie powstaje w ogóle** i zostaje wyłącznie tier godzinowy.

**To jest dokładnie scenariusz, który właściciel opisał przy dyskusji o pliku
`.ini`** — „gdy się nie powiedzie, nie powstanie; po 24 h okaże się, że brakuje
mi trwałego snapshotu żyjącego 7 dni" — odtworzony na żywej infrastrukturze,
a nie wyobrażony. `docs/design/quiesce-degrade.md` ma teraz pomiar za sobą.

Kontrola pozytywna, jedna zmienna (`deploy.sh --commit-scope=pve9
--allow-quiesce` na obu źródłach):

```
hourly/daily/weekly/monthly (p1-at) rc=0    (p2-at) rc=0
```

Osiem z ośmiu. Linie prune: 4/4 `rc=0`. Monitory czytane **z rc narzędzia**, nie
ze statusu linii crona (ten kończy się testem `[ $rc -ge 3 ]` i jest fałszywy
przy zdrowym stanie): **6/6 `rc=0`**.

## 4. Co ZOSTAJE żywe (do rozbiórki)

Lab **chodzi** — celowo, żeby zobaczyć tiki godzinowe.

**pve9 (192.168.28.99)**
- `/root/zfs-stage` — checkout gałęzi. **Zainstalowane linie crona wskazują na
  ten katalog** (`/root/zfs-stage/snapget.sh`), więc nie wolno go usunąć przed
  rozbiórką relacji.
- relacje `p1`, `p2` aktywne; `/etc/zfs-snapshot-all/jobs.pve9.conf`
- 23 linie crona; kopia sprzed: `/root/cron9.pre`
- datasety `hdd/prodlab-k1`, `hdd/prodlab-k2`

**pve1 (192.168.28.9) i pve2 (192.168.28.8) — PRODUKCJA**
- drzewa labowe `hdd/lab1prod`, `hdd/lab2prod`
- delegacja ZFS na 3 datasety do `zfsbackup-pve9`
- **nadanie quiesce** dla `zfsbackup-pve9` (whitelist + reguła sudoers).
  Zdejmuje się: `deploy.sh --revoke-quiesce=zfsbackup-pve9`

Produkcyjne linie crona i datasety produkcyjne **nietknięte** na obu hostach.
