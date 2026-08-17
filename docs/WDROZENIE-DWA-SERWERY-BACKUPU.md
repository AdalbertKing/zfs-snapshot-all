# Wdrożenie: backup + zdublowany serwer backupu (łańcuch trzech hostów)

Instrukcja spisana z **faktycznie wykonanych komend** kampanii lab3
(2026-08-17): `pve2 →(backup)→ pve1 →(sync)→ pve9`, gdzie pve9 to świeży
Debian 12 (cloud image) w VM. Każda komenda poniżej została uruchomiona na
żywych hostach; wyjścia skrócone do istoty. Wersja kodu: `main` ≥ PR #35.

Topologia i role:

```
pve2 (źródło)          pve1 (serwer backupu)        pve9 (dublet)
hdd/lab3/src   ──────► hdd/lab3backups/…/src ─────► hdd/lab3backups/…/src
        ogniwo A: backup            ogniwo B: sync (pasywny)
```

## 0. Wymagania wstępne

**Świeży host (dublet) — pakiety.** Obraz cloud Debiana nie ma ani ZFS, ani
crona (tabela zależności od PR #32 łapie brak `crontab`):

```bash
# na pve9 (świeży Debian):
sed -i 's/Components: main$/Components: main contrib/' /etc/apt/sources.list.d/debian.sources
apt-get update
apt-get install -y qemu-guest-agent linux-headers-cloud-amd64 zfs-dkms zfsutils-linux cron git
# UWAGA: flavor nagłówków musi odpowiadać jądru (cloud-amd64!) — generyczne
# nagłówki budują moduł, którego modprobe nie znajdzie.
zpool create hdd /dev/sdb        # nazwa puli MUSI odpowiadać pve1 (sync = te same ścieżki)
mkdir -p /root/scripts && cd /root/scripts
git clone https://github.com/AdalbertKing/zfs-snapshot-all.git
```

**Strefa czasowa.** Wyrównaj z flotą, inaczej nazwy snapshotów niosą inny
czas niż `creation` (aktywacja ostrzega o rozjeździe):

```bash
timedatectl set-timezone Europe/Warsaw
```

**Kanał root-ssh operatora** (dla `--grant-remotely` i `--join-remotely`):
kolektor musi móc `ssh root@źródło` w BatchMode, z pinem w
`/root/.ssh/known_hosts`. Dla ogniwa B (pve9 → pve1) założony tak:

```bash
# na pve9:
ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
# klucz publiczny dopisać do /root/.ssh/authorized_keys na pve1, potem:
ssh-keyscan -t ed25519 192.168.28.9 >> /root/.ssh/known_hosts
ssh -o BatchMode=yes root@192.168.28.9 'echo KANAL-OK'
```

**Dane testowe** (przy wdrożeniu produkcyjnym ten krok odpada — źródłem są
istniejące datasety):

```bash
# na pve2:
zfs create -p hdd/lab3/src
dd if=/dev/urandom of=/hdd/lab3/src/dane.bin bs=1M count=64
md5sum /hdd/lab3/src/dane.bin        # zanotuj: ab0c4933…
```

## 1. Ogniwo A — backup (jedna komenda na kolektorze)

```bash
# na pve1:
/root/scripts/zfs-snapshot-all/zfs-backup.sh \
    --source=192.168.28.8:hdd/lab3/src \
    --target=hdd/lab3backups \
    --local-user=zfsbackup \
    --grant-remotely --yes --install
```

Co robi ta jedna komenda (wszystko w niej):

1. tworzy konto `zfsbackup`, jeśli go nie ma (głośna linia w logu);
2. paruje + wykonuje join na źródle (konto delegowane `zfsbackup-pve1`,
   klucz, bramka) kanałem root-ssh;
3. **`--grant-remotely`**: zapisuje na źródle scope RÓWNY ŻĄDANIU i wykonuje
   tam `deploy.sh --commit-scope` (ślad audytowy `GRANTED_REMOTELY_BY` w
   manifeście źródła). Bez tej flagi: przepływ dwudotykowy — komenda
   zatrzyma się z instrukcją, co wykonać na źródle, a jej ponowienie
   WZNAWIA;
4. seed (pierwszy pełny transfer), weryfikacja grantów i endpointu;
5. podgląd zmian crontaba → instalacja bloku zarządzanego do crontaba
   KONTA (`zfsbackup`), z adopcją istniejącego configu hosta, jeśli
   crontab już niesie blok produkcyjny (sekcje DOŁĄCZAJĄ, nic nie znika).

Weryfikacja ogniwa A:

```bash
# na pve1:
md5sum /hdd/lab3backups/192.168.28.8/hdd/lab3/src/dane.bin   # == md5 źródła
zfs get -H -o value guid hdd/lab3backups/192.168.28.8/hdd/lab3/src@<snap>
# na pve2 ten sam snapshot — GUID identyczny:
zfs get -H -o value guid hdd/lab3/src@<snap>
```

## 2. Ogniwo B — dublet (jedna komenda na drugim kolektorze)

```bash
# na pve9:
/root/scripts/zfs-snapshot-all/zfs-backup.sh \
    --source=192.168.28.9:hdd/lab3backups/192.168.28.8/hdd/lab3/src \
    --mode=sync \
    --local-user=zfsbackup \
    --grant-remotely --yes --install
```

`--mode=sync` = mapowanie tożsamościowe (ta sama ścieżka na dublecie — stąd
wymóg tej samej nazwy puli). Ponieważ źródło ogniwa B **już niesie rodzinę
`automated_*`** (wytwarza ją ogniwo A), relacja zostaje wykryta jako
**PASYWNA**: `snapget -e` konsumuje najnowszy istniejący snapshot, niczego
na źródle nie tworzy i nie przycina — retencja rodziny zostaje przy pve1.
Harmonogram pasywny to `:31` (pół godziny za producentem), progi monitora
3h/5h (kadencja łańcucha). Podgląd aktywacji mówi o pasywności wprost.

Weryfikacja końca łańcucha:

```bash
# na pve9:
zfs mount hdd/lab3backups/192.168.28.8/hdd/lab3/src   # kopie są noauto
md5sum /hdd/lab3backups/192.168.28.8/hdd/lab3/src/dane.bin   # == md5 źródła
```

Dowód przyrostu: dopisz plik na pve2, odczekaj rundę `:01` (ogniwo A) i
`:31` (ogniwo B), md5 nowego pliku identyczne na trzech hostach. Przebiegi
widać w logu po markerach:

```bash
grep ZFS-JOB /home/zfsbackup/cron.log | tail    # BEGIN/END rc=… per przebieg
```

## 3. Demontaż (kolejność ma znaczenie)

```bash
# kolektor (dla każdego ogniwa):
zfs-backup.sh remove-client <NAZWA>       # czyści też blok crona i rekord parowania
rm -f /etc/zfs-snapshot-all/clients/<NAZWA>.conf
rm -rf /var/lib/zfs-snapshot-all/relationships/<NAZWA>
# źródło:
deploy.sh --leave=<etykieta-kolektora>    # konto delegowane, granty, manifest, scope
rm -rf /var/lib/zfs-snapshot-all/relationships/<etykieta>   # luka --leave, patrz TODO
# datasety laboratoryjne: zfs destroy -r …
```

## 4. Co poszło nie tak w kampanii i jak jest naprawione

Każdy punkt = realna awaria z tego wdrożenia; wszystkie naprawy na `main`.

| warstwa | objaw | przyczyna → naprawa |
|---|---|---|
| F1 | seed umiera surowym `permission denied` | weryfikacja scope porównywała żądanie z żądaniem; teraz z COMMITEM (fetch+sha256), odmowa nazywa czyj ruch (PR #32) |
| F2 | źródło miało podpisać zgodę na 4 gałęzie przy prośbie o 1 dataset | draft ACTIVE = dokładnie żądanie z manifestu joina (PR #32) |
| F3 | joby do crontaba ROOTA, config w checkoutcie gita | konto z manifestu parowania; domyślny config `/etc/zfs-snapshot-all/` (PR #32) |
| F5 | „all dependencies present" na hoście BEZ crona | `check_dep crontab` (PR #32) |
| F6 | pve9 w UTC — nazwy snapshotów kłamią o czasie | ostrzeżenie TZ przy aktywacji (PR #32) |
| F7 | dwa ogniwa pisały jedną rodzinę snapshotów; GFS skasował wspólną bazę OBU ogniw w 80 min | sync z istniejącej rodziny = PASYWNY (PR #32) |
| F8 | prune źródłowy padał co godzinę `permission denied` mimo grantu `destroy` | delegacja ZFS wymaga też `mount` do destroy; hint delsnaps wybierany z prawdziwego stderr (PR #32) |
| w.4 | „could not render" bez powodu | workfile 0600 nieczytelny dla konta → chmod 0644; stderr renderu przestał być połykany (PR #33) |
| w.5 | aktywacja chce KASOWAĆ 12 produkcyjnych linii | adopcja Source zainstalowanego bloku przed defaultem (PR #34); strażnik utraty jobów ślepy na markery-świadki (PR #35) |

Trzy strażnik zadziałały po drodze zgodnie z projektem: odmowa pełnego
resendu bez `-f`, odmowa instalacji kasującej joby (2026-07-30), fail-closed
`--leave` przy niedomkniętym unallow.
