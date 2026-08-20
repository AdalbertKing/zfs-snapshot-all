# Lab: postawienie łańcucha i sprawdzenie go — komendy

Dokładnie to, co uruchomiłem 2026-08-20 na metropolis, w kolejności, razem
z miejscami, w których narzędzie się **zatrzymuje i czeka na człowieka**.

Łańcuch: `pve9 (192.168.28.99) → pve2 (192.168.28.8) → pve1 (192.168.28.9)`.

Konwencja niżej: `[pve9]` znaczy „uruchom to na tym hoście".

---

## 0. Rozpoznanie — zanim cokolwiek ruszysz

```bash
[każdy host]  zpool list
              git -C /root/scripts/zfs-snapshot-all rev-parse --short HEAD
              ls -A /etc/zfs-snapshot-all/
              ls -A /etc/zfs-snapshot-all/clients/
              grep -cE '^[0-9*]' /var/spool/cron/crontabs/*
```

Czego szukasz: czy hosty są na tej samej rewizji, czy nie ma pozostałości po
poprzednim labie (`clients/*.conf` ze `STATE=removed`, pliki `.zfsbackup-work.*`,
manifesty w `peers/`).

**Pozostałości blokują.** U mnie zablokowały dwa razy — patrz krok 3.

## 1. Dane źródłowe

```bash
[pve9]  zfs create -p hdd/lab4/src
        dd if=/dev/urandom of=/hdd/lab4/src/plik1.bin bs=1M count=8 status=none
        dd if=/dev/urandom of=/hdd/lab4/src/plik2.bin bs=1M count=4 status=none
        sync
        md5sum /hdd/lab4/src/*.bin      # ZAPISZ TE SUMY — to punkt odniesienia
```

## 2. Plan — nie dotyka żadnego hosta

```bash
[pve2]  cd /root/scripts/zfs-snapshot-all
        bash zfs-backup.sh --source=192.168.28.99:hdd/lab4/src \
                           --target=hdd/lab4backups
```

Bez `--install` to czysty odczyt. Pokazuje nazwę relacji, tryb, etapy.
**Przeczytaj i dopiero potem instaluj.**

## 3a. DROGA KRÓTKA — jedna komenda zamiast czterech

Jeśli masz kanał root-ssh z kolektora na źródło, `--grant-remotely` robi całość
naraz: zakłada konto, **przyznaje zakres na źródle** i aktywuje.

```bash
[kolektor]  bash zfs-backup.sh --source=192.168.28.99:hdd/lab4/src2 \
                               --target=hdd/lab4direct --name=lab4-direct \
                               --grant-remotely --install --yes
```

Sprawdzone na żywo 2026-08-20: od zera do `STATE=active` w jednym przebiegu,
md5 zgodne. Czego ta flaga **nie** robi: nie przyznaje niczego szerszego niż
żądanie (zakres budowany z linii poleceń), nie nadpisze cudzego oczekującego
szkicu (odmawia), i bez kanału root-ssh odmawia **zanim** cokolwiek zmieni.
Źródło zapisuje `GRANTED_REMOTELY_BY`, czyli od kogo przyszła zgoda.

Domyślnie jest wyłączona, bo przyznanie zakresu to decyzja strony źródłowej.
Krok 3 niżej to ta domyślna, dwustronna droga — użyj jej, gdy nie chcesz albo
nie możesz decydować za źródło.

## 3. Instalacja — zatrzyma się na grancie

```bash
[pve2]  bash zfs-backup.sh --source=192.168.28.99:hdd/lab4/src \
                           --target=hdd/lab4backups --install --yes
```

Kończy się `FATAL: the source ... has GRANTED nothing yet`. **To nie jest błąd.**
Przyznanie zakresu jest decyzją strony źródłowej i nigdy nie wykonuje się zdalnie.

Zanim przyznasz — **obejrzyj, co ma zostać przyznane**:

```bash
[pve9]  cat /etc/zfs-snapshot-all/peers/pve2.scope
```

Szukasz sekcji `[dataset:...]`. Ma tam być **tylko** to, co backupujesz.
Jeśli widzisz cokolwiek produkcyjnego — nie przyznawaj.

```bash
[pve9]  cd /root/scripts/zfs-snapshot-all
        bash deploy.sh --commit-scope=pve2
```

Potem **powtórz dokładnie tę samą komendę** z kroku 3 na pve2. Wznowi.

## 4. Drugi skok — to samo, w drugą stronę

```bash
[pve1]  cd /root/scripts/zfs-snapshot-all
        bash zfs-backup.sh --source=192.168.28.8:hdd/lab4backups/192.168.28.99/hdd/lab4/src \
                           --target=hdd/lab4chain --name=lab4-pve2 --install --yes
```

`--name=` jest tu **konieczne**, jeśli host miał już kiedyś relację z tym peerem
i została usunięta: stan `removed` jest terminalny i domyślna nazwa się o niego
rozbije.

Gdy zdalny join nie przejdzie automatycznie, narzędzie wypisze wsad i dwie
komendy. Wtedy:

```bash
[pve1]  scp /root/scripts/pairing/pve1-to-192.168.28.8.tgz root@192.168.28.8:/root/
[pve2]  cd /root/scripts/zfs-snapshot-all
        bash deploy.sh --join=/root/pve1-to-192.168.28.8.tgz
```

`--join` **pyta o akceptację zakresu i nie ma żadnego `--yes`** — to celowe,
przyjęcie zakresu jest decyzją bezpieczeństwa. Przeczytaj wypisany
`[dataset:...]`, potem odpowiedz `t`.

Potem znowu: **powtórz komendę z początku kroku 4 na pve1**.

## 5. Weryfikacja — czy dane naprawdę doszły

**Nigdy nie montuj datasetu-kopii.** Odebrane datasety nie są montowane
i montowanie ich psuje wykrywanie rozbieżności. Użyj klonu:

```bash
[kolektor]  S=$(zfs list -H -t snapshot -o name -s creation -r <cel> | tail -1)
            zfs clone -o mountpoint=/mnt/check "$S" <pool>/check
            md5sum /mnt/check/*.bin        # porównaj z krokiem 1
            zfs destroy <pool>/check
```

## 6. Weryfikacja — czy lab nie tknął produkcji

```bash
[kolektor]  # 1. granty tylko na liściach laba, zero na produkcji
            for d in hdd/vm-disks hdd/backups rpool/data rpool/ROOT; do
                echo "$d -> $(zfs allow $d 2>/dev/null | grep -c zfsbackup-)"
            done
            # 2. produkcyjny crontab nietknięty
            grep -cE '^[0-9*]' /var/spool/cron/crontabs/zfsbackup
            grep -o 'Source: [^ ]*' /var/spool/cron/crontabs/zfsbackup
            # 3. blok laba osobno
            grep -o 'Source: [^ ]*' /var/spool/cron/crontabs/root
```

Zadania laba idą do crontaba **roota** i osobnego configu (`jobs.<host>.conf`),
produkcja zostaje na koncie `zfsbackup` i swoim configu (`jobs.<host>.v4.conf`).
Konta labowe nazywają się `zfsbackup-<peer>` — jeśli któreś pojawi się w wyniku
punktu 1, coś jest nie tak.

## 7. Obserwacja przez kilka cykli — czy to naprawdę chodzi

Jednorazowy przebieg dowodzi, że **da się** zrobić kopię. Nie dowodzi, że
harmonogram działa. To sprawdza się dopiero po kilku godzinach:

```bash
[kolektor]  zfs list -H -t snapshot -o name,creation -s creation -r <cel>
            grep -c 'ZFS-JOB' /root/scripts/cron.log
            cd /root/scripts/zfs-snapshot-all
            ./check-snap-age.sh -R -L <relacja> "<cel>" "automated_hourly" 90m 150m; echo $?
```

Czego szukasz: **jeden snapshot na godzinę o `:01`**, monitor `rc=0`, markery
`ZFS-JOB` parami BEGIN/END. Zmierzone 2026-08-20: 15:01, 16:01, 17:01 — równo.

**Jeśli monitor pójdzie na WARN, to nie musi być awaria.** Przy zepsutej
wysyłce monitor POWINIEN ostrzec po ~90 minutach; to dowód, że działa. Rozróżnij
„nie ma nowych snapshotów, monitor milczy" (źle) od „nie ma nowych snapshotów,
monitor krzyczy" (dobrze).

## 8. Strefy czasowe — sprawdź, zanim uznasz coś za opóźnienie

Nazwę snapshotu nadaje **kolektor**, a `creation` zapisuje **źródło**. Jeśli
hosty są w różnych strefach, na źródle nazwa i `creation` się rozjadą:

```bash
[źródło]  zfs list -H -t snapshot -o name,creation -r <dataset> | tail -3
```

Zmierzone: pve9 w `+0000`, kolektory w `+0200` — snapshot nazwany
`..._17-01-01` ma na pve9 `creation` 15:01. **Z kolektora tego nie widać**, bo
tam obie wartości są w tej samej strefie. Monitor to nie dotyczy (czyta
`creation`), ale `restore --plan` zgłosi rozjazd nazwa↔`creation`.

`zfs-backup.sh` ostrzega o tym przy enrolmencie. Wyrównaj `timedatectl
set-timezone` na obu hostach albo świadomie to zaakceptuj.

## 9. Trzy pauzy — którą wybrać

Nie są wariantami tej samej rzeczy. Różnią się tym, **co** zatrzymują i **kto**
może to cofnąć.

```bash
# a) PAUZA ZADANIA -- caly host, na czas prac sprzetowych
[host]  bash deploy.sh --pause          # komentuje ciala blokow w OBU crontabach
        bash deploy.sh --resume         # odkomentowuje

# b) MIEKKA PAUZA RELACJI -- jedna relacja, decyzja lokalna
[kolektor]  bash zfs-backup.sh pause-client <nazwa> --reason="..."
            bash zfs-backup.sh resume-client <nazwa>

# c) TWARDA PAUZA RELACJI -- peer odmawia, tez komend bez -L
[kolektor]  bash zfs-backup.sh disable-client <nazwa> --reason="..."
            bash zfs-backup.sh enable-client <nazwa>
```

Czego się spodziewać, zmierzone 2026-08-20:

- **(a) nie da się zawęzić do jednego użytkownika.** `pause_targets` zawsze
  zwraca roota **i** konto delegowane. Na hoście, gdzie lab siedzi w crontabie
  roota a produkcja na koncie, `--pause` zatrzyma jedno i drugie. Testuj tam,
  gdzie nie ma produkcji.
- **(a) robi po drodze pełne wdrożenie** i przy `--resume` wypisuje dwa `!!!`
  o linijkach crona, których nie mógł zapisać — łącznie z „this host would stop
  picking up updates". To fałszywy alarm, wznowienie osiem linii niżej działa.
- **(b) nie rusza crontaba w ogóle** (sprawdzone `diff`-em: identyczny) i **nie
  zatrzymuje retencji** — linie `delsnaps` nie mają `-L` i chodzą dalej, także
  ta kasująca po źródle. Monitor za to milczy z uzasadnieniem, nie zalewa.
- **(c) wymaga sprawnego katalogu stanu u peera.** Jeśli
  `/var/lib/zfs-snapshot-all/relationships/<label>/` nie ma grupy konta bramy,
  `disable` **poległ** — nie `enable`, jak twierdziły starsze komunikaty:

```bash
[peer]  stat -c '%a %U:%G' /var/lib/zfs-snapshot-all/relationships/<label>
        # ma byc: 2775 root:zfsbackup-<peer>, NIE root:zfsalert
        chown root:zfsbackup-<peer> /var/lib/zfs-snapshot-all/relationships/<label>
        chmod 0775 /var/lib/zfs-snapshot-all/relationships/<label>
```

Sprawdzenie, że twarda pauza naprawdę trzyma — uruchom ręcznie **bez** `-L`,
musi wrócić `PAIR_DISABLED`:

```bash
[kolektor]  ./snapget.sh -m "test_manual_" -K <klucz> ... "<konto>@<peer>:<zrodlo>" "<cel>"
            # oczekiwane: PAIR_DISABLED: relationship ... is disabled by administrator
```

## Zatrzymania, które są POPRAWNE

| komunikat | co znaczy |
|---|---|
| `has GRANTED nothing yet` | grant to ruch strony źródłowej, zrób krok 3 |
| `manifest ... already exists with a DIFFERENT account/target` | pozostałość po starym labie, obejrzyj i odsuń |
| `join interrupted before scope acceptance` | `--join` czeka na `t`, nie ma `--yes` |
| `unknown state 'removed'` (przed poprawką) | relacja usunięta, użyj `--name=NOWA` |

## Sprzątanie po labie — pełna, sprawdzona kolejność

Skryptu robiącego to jednym poleceniem **nie ma** (`clean_all` jest dopiero
zaplanowany). Poniżej kolejność wykonana i zmierzona 2026-08-20; po niej trzy
hosty były sterylne, a produkcja nietknięta.

**Kolejność ma znaczenie.** Najpierw kolektor, potem źródło: `remove-client`
wypisuje, którą komendę uruchomić po drugiej stronie.

```bash
# 1. KOLEKTOR -- kasuje linie crona, peers/<ip>.conf, klucze, .tgz
[kolektor]  bash zfs-backup.sh remove-client <nazwa>

# 2. ZRODLO -- cofa granty ZFS, kasuje konto z katalogiem domowym, manifest, scope
[zrodlo]    bash deploy.sh --leave=<etykieta>
```

Uwaga: jeśli host jest **jednocześnie** kolektorem i źródłem (środek łańcucha),
potrzebuje obu — łatwo przeoczyć `--leave` na hoście, o którym myślisz „to
przecież kolektor".

> **Kolejność jest nieodwracalna: `--leave` PRZED sprzątaniem ręcznym.**
> Manifest `peers/<etykieta>.conf` jest mapą, z której `--leave` czyta, co cofnąć
> i kogo usunąć. Skasuj go najpierw, a narzędzie odmówi:
>
> ```
> FATAL: no join manifest for 'pve9' at /etc/zfs-snapshot-all/peers/pve9.conf
>        -- nothing to leave (was --join even run here under this label?)
> ```
>
> Odmowa jest poprawna — narzędzie nie zgaduje — ale konto zostaje wtedy poza
> jego zasięgiem i trzeba je usunąć ręcznie, czyli dokładnie tym, czego reguła
> whitelisty ma unikać. Zrobiłem ten błąd 2026-08-20 na pve1.

**Listę `--leave` wyprowadzaj z KONT na hoście, nie z topologii łańcucha.**
Rozebrałem trzy relacje, które sam zbudowałem, i przegapiłem konto
`zfsbackup-pve9` na pve1 — zostało po starszym labie, w którym pve1 było
źródłem. Miało żywy klucz i powłokę przy zerze grantów. Pytanie do zadania na
każdym hoście brzmi „jakie konta `zfsbackup-*` tu są i czym każde z nich jest
uzasadnione", a nie „jakie relacje ja budowałem":

```bash
[każdy]  ls -d /home/zfsbackup-* 2>/dev/null
         # dla każdego: id <konto>, zfs allow, grep w crontabach i /etc
```

### 3. Reszta — czego narzędzia nie sprzątają

Zanim skasujesz cokolwiek ręcznie, **sprawdź, że produkcja tego nie używa**:

```bash
[każdy]  crontab -l -u zfsbackup | grep -icE 'lab4|-L '     # ma byc 0
         grep -licE 'lab4' /etc/zfs-snapshot-all/jobs.*.conf # ma byc pusto
         zfs list -H -o name,origin | awk '$2!="-"'          # klony
         # holdy na kazdym snapshocie datasetu labowego
```

Potem, **whitelistą po dokładnych nazwach, nigdy `grep -i test`**:

```bash
rm -f /etc/zfs-snapshot-all/clients/<nazwa>.conf          # zostaje ze STATE=removed
rm -f /etc/zfs-snapshot-all/peers/<etykieta>.conf         # peers/ jest kluczowane
rm -f /etc/zfs-snapshot-all/peers/<etykieta>.scope*       #   DWOJAKO: po IP i etykiecie
rm -rf /var/lib/zfs-snapshot-all/relationships/<etykieta>
rm -f /root/.ssh/pairing/<ip>_alias_known_hosts           # jedyny klucz, ktory przezyl
rm -f /root/scripts/pairing/*
zfs destroy -r <pool>/<dataset labowy>
```

`known_hosts` zostaje celowo — narzędzie samo to mówi i podaje `ssh-keygen -R`.
To nasz zapis o tym, kim oni są, nie uprawnienie dla nich.

### 4. Weryfikacja, że host jest sterylny

```bash
[każdy]  ls -A /etc/zfs-snapshot-all/clients/ /etc/zfs-snapshot-all/peers/ \
                /var/lib/zfs-snapshot-all/relationships/ /root/.ssh/pairing/
         ls -d /home/zfsbackup-* 2>/dev/null
         crontab -l -u zfsbackup | md5sum   # PORÓWNAJ z sumą sprzed rozbiórki
```

Wszystkie listy puste, konta per-peer żadne, md5 produkcji **bez zmian**.

Uwaga o katalogach domowych: konto może już nie istnieć, a katalog zostać — i po
recyklingu UID należeć do **innego, żywego** konta. Sprawdzaj `id <nazwa>`, nie
właściciela katalogu; puste pole powłoki z `getent passwd` nie jest dowodem.

Odsunięte pozostałości po lab3 leżą na pve2 w `/root/lab3-residue.<timestamp>/`
— nie skasowane, na wypadek gdyby czegoś zabrakło.
