# Inwentaryzacja zmiennych: od CLI do wywołania silnika

Punkt wyjścia do projektowania profili (polecenie właściciela, 2026-08-24):
**wypisać wszystkie wartości, które przechodzą od najwyższej warstwy do
najniższej w OBECNYCH wdrożeniach**, zobaczyć, które tną przez wszystkie
warstwy, a które są ustawiane niżej — i dopiero na tej podstawie zdecydować,
co **musi** być w profilu, co **może**, a co ustawiamy domyślnie.

Zmierzone na żywej relacji `k1` (`main@348b462`, kolektor pve9, źródło pve1),
nie wyczytane z kodu. Kod mówi, co *może* zostać ustawione; wdrożenie pokazuje,
co *jest*.

## Warstwy

| | warstwa | artefakt |
|---|---|---|
| **L1** | polecenie operatora | `zfs-backup.sh --source=... --target=... --passive ...` |
| **L2** | rekord relacji | `/etc/zfs-snapshot-all/clients/k1.conf` |
| **L3** | manifest parowania (per HOST) | `/etc/zfs-snapshot-all/peers/192.168.28.9.conf` |
| **L4** | profil | `profiles/passive/{templates.conf,dataset.inc,prune.inc}` |
| **L5** | CONFIG v4 | `jobs.pve9.conf`: `[defaults]`, `[template:]`, `[dataset:]`, `[prune:]`, `[excluded:]` |
| **L6** | linia crona | blok zarządzany w crontabie konta |
| **L7** | wywołanie silnika | `snapget.sh -m "" -R -K ... -X skip -e -E tmpjob_ -A -L k1 SRC TGT` |

Profil (L4) wstrzykuje się **wyłącznie w L5** — nigdy nie dotyka L2 ani L3.

## Tabela pełna

Legenda kolumny **klasa**:
**T** = tożsamość relacji (nigdy do profilu),
**D** = decyzja operatora przy tworzeniu (rekord; profil może dać domyślną),
**P** = polityka (naturalny mieszkaniec profilu),
**Z** = zaszyta domyślna (dziś nigdzie nie deklarowana).

| wartość | L1 | L2 | L3 | L4 | L5 | L7 | klasa |
|---|---|---|---|---|---|---|---|
| host źródłowy | `--source` | `PEER_HOST`, `ACTIVE_ENDPOINT` | nazwa pliku | — | `src`, alias w `flags` | argument | **T** |
| dataset źródłowy | `--source` | `REQUESTED_DATASETS` | `PEER_SAVED_DATASETS` | — | `src` | argument | **T** |
| target | `--target` | `CLIENT_TARGET` | `PEER_SAVED_TARGET` | — | ścieżka sekcji | argument | **T** |
| nazwa relacji | `--name` | `CLIENT_NAME` | — | — | `pair_label`, `notify` | `-L` | **T** |
| konto lokalne | `--local-user` | `LOCAL_USER` | `PEER_SAVED_LOCAL_USER` | — | wybór pliku i crontaba | kto uruchamia | **T** |
| konto zdalne | — | — | `PEER_SAVED_ACCOUNT` | — | `src` | argument | **T** |
| port | `--port` | `ACTIVE_ENDPOINT` | `PEER_SAVED_PORT` | — | `flags -p` | `-p` | **T** |
| klucz + known_hosts + alias | — | pochodne | pliki | — | `flags -K -k -O` | `-K -k -O` | **T** |
| tryb (backup/sync) | `--mode` | `RUX_MODE` | `PEER_SAVED_MODE` | — | kształt sekcji | — | **T** |
| rekursja | `--recursive` | `RECURSION` | — | — | `recursive` | `-R` / `-r` | **D** |
| pasywność | `--passive` | `PASSIVE` | — | wybór profilu | `flags -e` | `-e` | **D** |
| wykluczone rodziny snapshotów | `--exclude-snapshots` | `EXCLUDE_SNAP_n` | — | — | `flags -E`, `monitor_exclude` | `-E`, `-x` | **D** |
| wykluczone dzieci | `--exclude` | `EXCLUDE_n` | — | — | `flags -X` | `-X` | **D** |
| limit pasma | `--bandwidth` | `BANDWIDTH` | — | — | `flags -b` | `-b` | **D** |
| wybór profilu | `--profile` | `PROFILE` | — | — | `use_template` | pośrednio | **D** |
| prefiks snapshotu | — | — | — | `prefix` | `prefix` | `-m` | **P** |
| harmonogram wysyłki | — | — | — | `send_schedule` | `send_schedule` (sekcja nadpisuje — rozrzut) | minuta crona | **P** |
| harmonogram prune | — | — | — | `prune_schedule` | `prune_schedule` (j.w.) | minuta crona | **P** |
| retencja | — | — | — | `retain` | `retain` | `-H24 -D7 -W4 -M12` | **P** |
| wzorzec prune | — | — | — | `pattern` | `pattern` | argument `delsnaps` | **P** |
| drabina GFS | — | — | — | `gfs`, `gfs_pattern` | `gfs` | `-G` | **P** |
| progi monitora | — | — | — | `monitor_warn`, `monitor_crit` | te same | argumenty | **P** |
| harmonogram monitora | — | — | — | `monitor_schedule` | to samo | minuta crona | **P** |
| słowo w powiadomieniu | — | — | — | `notify_word` | to samo | tekst w linii | **P** |
| quiesce | — | — | — | `quiesce` | `quiesce` | `-q` | **P** |
| rodziny zarezerwowane | — | — | — | — | `[excluded:__replicate_]` itd. | `-P "__replicate_:2"` | **Z** |
| `host_label` | — | — | — | — | `[defaults] host_label` | teksty | **Z** |
| autotune `-A` | — | — | — | (`autotune=no` wyłącza) | brak pola | `-A` | **Z** |
| ścieżki logu i notify | — | — | — | — | `[defaults]` / konto | ścieżki w linii | **Z** |

## Co z tego wynika

### 0. Co profil może dziś zablokować — stan zmierzony

`lib-profile.sh` odrzuca w profilu dokładnie pięć pól:

```
PROFILE_FORBIDDEN_FIELDS='src dst flags pair_label notify'
```

plus jedną regułę szczególną: profil **nie może** nadpisać `recursive` na
sekcji `[prune:]` („a profile may not override 'recursive' on a prune
section" — topologia prune należy do wdrożenia).

Wniosek, którego się nie spodziewałem: **na sekcji `[dataset:]` profil
`recursive` ustawić MOŻE.** Czyli rekursja — którą wyżej sklasyfikowałem
jako decyzję operatora (**D**) — jest już dziś polem, o którym profil ma
prawo mieć zdanie, tylko żaden wbudowany profil z tego nie korzysta.
To jest gotowe miejsce na domyślną („profil archiwalny jest płaski"), a nie
funkcja do dopisania.

### 1. Warstwy nie mieszają się tak, jak mogłoby się wydawać

Żadna wartość klasy **T** nie przechodzi przez profil — i to jest dobrze:
`lib-profile.sh` ma `profile_field_forbidden`, które odrzuca pola należące do
relacji. Profil dotyka **wyłącznie L5**, i tylko sekcji, które sam wypełnia.

Za to **żadna wartość klasy P nie ma dziś reprezentacji w L1 ani L2.** Nie da
się przy tworzeniu relacji powiedzieć „ta jedna ma retencję 48 godzin" —
trzeba albo zrobić osobny profil, albo ręcznie edytować sekcję po fakcie.
To jest największa asymetria w obecnym układzie.

### 2. Trzy wartości są zaszyte i nikt ich nie deklaruje (klasa Z)

- **rodziny zarezerwowane** (`__replicate_`, `vzdump`, `__migration__` z `keep=2`)
  — generowane bezwarunkowo do `[excluded:]`, nie pochodzą z profilu;
- **`-A` (autotune)** — dokładane przez `gen-cron.sh` do każdej wysyłki, której
  cel jest zdalny; w profilu można je tylko **wyłączyć** (`autotune=no`), nie
  ma pola, które by je włączało — czyli domyślna jest niewidoczna w configu;
- **`host_label`** i ścieżki logu/notify — pochodne hosta i konta.

Każda z nich jest dziś rozsądna, ale **żadna nie jest widoczna w profilu**,
więc profil nie jest pełnym opisem polityki. To jest do rozstrzygnięcia:
czy profil ma móc je przesłonić, czy zostają poza nim świadomie.

### 3. Pasywność jest jednocześnie D i P — i to jest realny konflikt

`--passive` to decyzja operatora (**D**, zapisana jako `PASSIVE=1`), ale
pociąga za sobą politykę: prefiksowość, wzorzec monitora, drabinę bez
prefiksu — czyli **wybór profilu**. Dziś rozwiązane automatem („passive +
profil domyślny → profil `passive`"). Działa, ale znaczy, że jedna flaga L1
po cichu podmienia całą warstwę L4. Przy projektowaniu profili trzeba to
nazwać wprost, bo inaczej każdy nowy profil będzie musiał mieć swój wariant
pasywny.

### 4. Rozrzut harmonogramu obnażył granicę modelu

Pole wpisane do sekcji `[dataset:]`/`[prune:]` nadpisuje **każdy** tier, który
sekcja referuje. Dla profilu jednokadencyjnego (dzisiejsze wbudowane) to
działa. Dla profilu wielotierowego — jak zaparkowany `tiered` z czterema
kadencjami wysyłki (`7 * * * *`, `17 0 * * *`, `27 0 * * 0`, `37 0 1 * *`) —
jedna wartość nie może wyrazić czterech kadencji, więc rozrzut **milczy** i
wszystkie relacje z takiego profilu lądują na tych samych minutach.

To nie jest błąd rozrzutu, tylko **brak w gramatyce**: nie ma sposobu, by
powiedzieć „przesuń każdy tier tej relacji o N minut". Naturalne uzupełnienie
to pole `schedule_offset` w sekcji, dodawane przez `gen-cron.sh` do minuty
każdego renderowanego harmonogramu. `gen-cron.sh` nie jest zamrożony.

## Propozycja podziału na potrzeby etapu profili

**Do profilu (P) — obowiązkowo:** `prefix`, `send_schedule`, `prune_schedule`,
`retain`, `pattern`, `gfs`/`gfs_pattern`, `monitor_warn`, `monitor_crit`,
`monitor_schedule`, `notify_word`.

**Do profilu opcjonalnie (P, dziś Z):** rodziny zarezerwowane i ich `keep`,
`autotune`. Argument za: profil przestaje być połowicznym opisem polityki.
Argument przeciw: to są wartości chroniące przed zniszczeniem cudzych danych
(`__replicate_`), więc może właśnie nie powinny być edytowalne z profilu.
**Wymaga decyzji.**

**Nigdy do profilu (T):** wszystko, co identyfikuje relację — źródło, cel,
nazwa, konta, port, klucze, tryb. Egzekwowane dziś przez
`profile_field_forbidden`.

**Domyślne z profilu, nadpisywalne przy tworzeniu (D):** rekursja,
pasywność, wykluczenia, pasmo. Dziś idą wyłącznie z L1/L2 i profil nie ma
o nich zdania — a to jest naturalne miejsce na sensowną domyślną
(np. profil „archiwalny" domyślnie płaski i pasywny).

## Krok drugi: `default` jako jawny parametr

Dziś `PROFILE_ACTIVE=default` jest **wartością domyślną w kodzie**
(`zfs-backup.sh:96`), a nie deklaracją. Uczynienie go jawnym parametrem
odsłania, co jest naprawdę domyślne, a co zaszyte — i jest warunkiem
sensownego testowania profili, bo dopiero wtedy „brak `--profile`" znaczy coś
sprawdzalnego.
