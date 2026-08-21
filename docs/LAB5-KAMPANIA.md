# Kampania wdrożeniowa 2026-08-20 — macierz sześciu kształtów

Inwentarz komend i znalezisk z przejścia całej macierzy wdrożeń na metropolis:
jedno- i dwuserwerowe, konto root i delegowane, tryb backup i sync, z jawnym
`--target` i bez, z automatycznym joinem przez SSH i z ręcznym.

Każde wdrożenie sprawdzone md5 przez klon, każda rozbiórka diffem crontabów.

## Kontrola, która działała przez cały czas

Pierwotny łańcuch `pve9 → pve2 → pve1` **zostawiony żywy przez całą kampanię**.
Nie po to, żeby oszczędzić pracy — po to, żeby był miarą. Pięć cykli
wdroż/zniszcz na trzech hostach, a łańcuch nie opuścił ani jednej godziny:

```
pve9   hdd/lab4/src              @21-01-01  @22-01-01
pve2   hdd/lab4backups/...       @20-01-01  @21-01-01  @22-01-01
pve1   hdd/lab4chain/...         @21-01-01  @22-01-01
```

Produkcyjne crontaby kont `zfsbackup` na obu kolektorach mają na koniec te same
sumy co na starcie: pve2 `7b0bc987003d`, pve1 `deec98c04a02`, pve9 `8d88b637d729`.

## Komendy, kształt po kształcie

### 1. Jednoserwerowe, root, jawny cel

```bash
[pve9]  zfs-backup.sh --source=hdd/lab5src --target=hdd/lab5dst            # plan
        zfs-backup.sh --source=hdd/lab5src --target=hdd/lab5dst --install --yes
```

Pięć linii crona: send `:01`, dwa prune `:21` (źródło i cel), dwa monitory
`*/15`. **Zero `-L`** — backup lokalny nie jest relacją, więc nie ma bramy pary.

Rozbiórka (patrz znalezisko Z1 — czasownik powstał w trakcie tej kampanii):

```bash
[pve9]  gen-cron.sh --uninstall          # blok crona
        rm /etc/zfs-snapshot-all/jobs.<host>.conf
        zfs destroy -r hdd/lab5dst
```

### 2. Jednoserwerowe, cel z proweniencji (bez `--target`)

```bash
[pve9]  zfs-backup.sh setup-server --target=hdd/lab5auto --local-user=zfsbackup
        zfs-backup.sh --source=hdd/lab5src --install --yes
```

Cel wzięty z `server.conf` i **podana proweniencja**:
`using the configured default 'hdd/lab5auto' (server.conf DEFAULT_TARGET; pass
--target= to override)`. To ważne rozróżnienie — cel *zgadnięty* nie instaluje
się pod `--yes`, cel *skonfigurowany* tak.

### 3. Dwuserwerowe, root, automatyczny join

```bash
[pve1]  zfs-backup.sh --source=192.168.28.99:hdd/lab5src --target=hdd/lab5remote \
                      --name=lab5-root --install --yes
        # zatrzymuje sie: join probuje sie sam przez SSH i staje na akceptacji zakresu
[pve9]  cat /etc/zfs-snapshot-all/peers/pve1.scope     # OBEJRZEC przed zgoda
        deploy.sh --commit-scope=pve1
[pve1]  # powtorzyc komende z gory -- wznawia
```

### 4. Dwuserwerowe, konto delegowane, ręczny join

```bash
[pve1]  zfs-backup.sh --source=192.168.28.99:hdd/lab5src --target=hdd/lab5acct \
                      --name=lab5-acct --local-user=zfsbackup --manual-join --install --yes
[pve1]  scp /root/scripts/pairing/pve1-to-192.168.28.99.tgz root@192.168.28.99:/root/
[pve9]  tar tzf /root/pve1-to-192.168.28.99.tgz && cat peer.conf   # OBEJRZEC czego zada
        deploy.sh --join=/root/pve1-to-192.168.28.99.tgz          # pyta, odpowiedz 't'
[pve1]  # powtorzyc komende z gory
```

**Kontrast wart zapamiętania:** ręczny `--join` przy akceptacji **od razu
zatwierdza** zakres (`scope accepted and committed`), podczas gdy droga
automatyczna zostawia grant jako osobny krok `--commit-scope`.

Dowód, że kształt produkcyjny jest bezpieczny — diff crontaba konta po
wdrożeniu to **wyłącznie dopisania**:

```
11a12   > 1 * * * * ... snapget.sh ... -L lab5-acct ...
16a18,19 > 21 * * * * ... delsnaps.sh ...
20a24   > */15 * * * * ... check-snap-age.sh ...
linii usunietych/zmienionych: 0
```

### 5. Tryb sync

```bash
[pve1]  zfs-backup.sh --source=192.168.28.99:hdd/lab5sync --mode=sync \
                      --name=lab5-sync --local-user=zfsbackup --install --yes
```

Mapowanie tożsamościowe potwierdzone: wylądowało na `hdd/lab5sync` — **tej samej
ścieżce co na źródle**, bez prefiksu adresu. Dla kontrastu backup z fazy 4 dał
`hdd/lab5acct/192.168.28.99/hdd/lab5src`.

## Znaleziska

### Z1. Nie było czym rozebrać wdrożenia jednoserwerowego — NAPRAWIONE

`remove-client` wymaga relacji, `clean-relationships.sh` słusznie mówi, że to
nie relacja, opróżniony config jest odrzucany, a `cron_block_remove` jest
osiągalne tylko przez `remove-client`. Pakiet potrafił zbudować coś, czego nie
potrafił rozebrać, a jedynym wyjściem była ręczna edycja crontaba — czyli to,
przed czym broni reguła jednego pisarza. Dodane `gen-cron.sh --uninstall`.

### Z2. Wdrożenie jednoserwerowe może chodzić TYLKO jako root — DO DECYZJI

Forma lokalna odrzuca `--local-user` (`FATAL: local-backup: unknown option`),
`setup-server --local-user` tworzy konto ale nie zapisuje go dla ścieżki
lokalnej (`zfs-backup.conf` niesie tylko `DEFAULT_TARGET` i `CRON_CONFIG`),
a `cron_target_user` bez `LOCAL_USER` zwraca roota. Zmierzone: blok wylądował
u roota mimo `setup-server --local-user=zfsbackup`.

### Z3. `clean-relationships.sh` był ślepy na klucze konta — NAPRAWIONE

Relacja z `--local-user` używa kluczy konta: `/home/<konto>/.ssh/pairing-<adres>_*`
— **prefiks**, gdzie root ma katalog. Narzędzie przeszukiwało tylko roota, czyli
było ślepe w kształcie produkcyjnym. Znalazło się tam pięć plików, w tym
`pairing-192.168.28.190_alias_known_hosts` — adres nieznany żadnemu configowi
ani linii crona. Osobno: `SEEN_ADDR` było zbierane i **nigdy nie raportowane**.

### Z4. Rozróżnik „join czy draft" nie rozróżniał — NAPRAWIONE

Testował `peers/<adres>.conf` na kolektorze i uznawał jego obecność za dowód, że
join przeszedł. Ten plik pisze **kolektor sam** przy `--pair`, przed jakimkolwiek
joinem, i niesie wyłącznie `PEER_SAVED_*`. Gałąź „join nie przeszedł" była
nieosiągalna, a każdy przypadek dostawał radę o `--draft-scope` — tę samą złą
radę, którą rozróżnik miał wyeliminować.

**Miało to dwa zielone testy.** Przechodziły, bo piaskownica potrafiła stworzyć
stan, którego prawdziwy system nigdy nie produkuje. Test może być bez zarzutu
wobec scenariusza, który nie istnieje — i wtedy jest gorszy niż jego brak, bo
komentarz nad nim ręczy za zachowanie.

### Z5. Self-sync przechodzi planowanie — DO DECYZJI

`--source=<własny adres> --mode=sync` daje `rc=0` i opisuje relację, w której
źródłem jest ten sam host, a ścieżka docelowa jest identyczna ze źródłową.
Straż `validate_remote_host` (porównuje `/etc/machine-id`) żyje w **silnikach**
(`snapget.sh:936`), a planer RUX jej nie woła. Zbudowałbyś całą relację przeciw
sobie — konto na peerze, klucze, linie crona — a odmowa przyszłaby dopiero przy
pierwszym uruchomieniu joba z crona. Awaria odroczona za wszystko, co kosztowne.

### Z6. Sync kopiuje to, czego nie zamawiałeś — NAJOSTRZEJSZE

Jeden enrolment z `--source=192.168.28.99:hdd/lab5sync` zreplikował na kolektor
**trzy** datasety na ścieżki tożsamościowe:

```
hdd/lab4/src    <- nalezy do relacji z pve2, nie zamawiany
hdd/lab5src     <- z wczesniejszej fazy, nie zamawiany
hdd/lab5sync    <- jedyny zamawiany
```

Trzy rzeczy składają się w łańcuch:

1. szkic zakresu na źródle **kumuluje** wpisy między enrolmentami;
2. `--join` akceptuje **cały plik**, nie tylko bieżące żądanie;
3. klient w trybie sync bierze listę datasetów z **zatwierdzonego zakresu**,
   nie z argumentu `--source`.

Czyli w trybie sync `--source=HOST:DATASET` **nie jest wyborem** — wskazuje
peera, a dostajesz wszystko, co przyznane. Na produkcji `hdd/lab4` wyląduje pod
`hdd/lab4` na kolektorze, gdzie może już istnieć coś innego o tej nazwie.

To samo wyjaśnia odmowę przy drugiej relacji sync do tego samego peera
(`would take coverage another relationship already owns`) — obie pokrywają ten
sam zbiór, więc się wykluczają. Odmowa jest poprawna; zaskakująca jest przyczyna.

### Z7. Enrolment sync otwiera edytor na peerze — DO DECYZJI

Po **udanym** automatycznym joinie ścieżka MODE-owa woła `remote_scope_stage`,
która uruchamia `${VISUAL:-${EDITOR:-vi}}` na peerze przez `ssh -t`. Zmierzone:
`vi /etc/zfs-snapshot-all/peers/pve1.scope` chodziło 8 minut ze swapem
`.pve1.scope.swp`, a przebieg stał. Edytor jest jednoznacznie interaktywny, więc
każde automatyczne uruchomienie na tym staje — to samo, co O14, w innym miejscu
wywołania. Uratował własny `timeout 500`, który sam nałożyłem.

### Z8. `remove-client` zabiera wspólny rekord parowania — DO DECYZJI

Dwie relacje do tego samego peera dzielą jeden rekord kluczowany adresem
(`peers/<adres>.conf`). Usunięcie jednej zabiera go drugiej: po
`remove-client lab5-sync` druga relacja utknęła w `STATE=seeding` z komunikatem
`no pairing manifest ... has --join run there yet?`, a `remove-client` odmawia
usunięcia klienta w stanie `seeding`. Wyjściem był ręczny rekord.

## Reguła, która się z tego wyłania

Sześć wdrożeń, osiem znalezisk, i **wszystkie osiem to ta sama rodzina**:
narzędzie twierdzi coś, czego nie sprawdziło. Manifest, który miał dowodzić
joinu, a dowodził tylko własnego istnienia. Zakres, który miał być żądaniem,
a był akumulacją. `--source`, który wygląda na wybór, a jest adresem peera.
Straż, która istnieje, ale nie tam, gdzie decyzja zapada.

Wzorzec jest jeden: **fakt lokalny użyty jako dowód faktu zdalnego**, albo
**argument użyty jako dowód zamiaru**. Warto tego szukać w następnej kolejności.
