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

## Zatrzymania, które są POPRAWNE

| komunikat | co znaczy |
|---|---|
| `has GRANTED nothing yet` | grant to ruch strony źródłowej, zrób krok 3 |
| `manifest ... already exists with a DIFFERENT account/target` | pozostałość po starym labie, obejrzyj i odsuń |
| `join interrupted before scope acceptance` | `--join` czeka na `t`, nie ma `--yes` |
| `unknown state 'removed'` (przed poprawką) | relacja usunięta, użyj `--name=NOWA` |

## Sprzątanie po labie

```bash
[pve2]  zfs destroy -r hdd/lab4backups
[pve1]  zfs destroy -r hdd/lab4chain
[pve9]  zfs destroy -r hdd/lab4
[każdy] bash zfs-backup.sh remove-client <nazwa>
```

Odsunięte pozostałości po lab3 leżą na pve2 w `/root/lab3-residue.<timestamp>/`
— nie skasowane, na wypadek gdyby czegoś zabrakło.
