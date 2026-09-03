# Lab — `deploy.sh --draft-config` na prawdziwym parowaniu

Status: **DO WYKONANIA** w wątku z dostępem do floty. Ostatnia z czterech
„znanych luk" z sierpnia (PROJECT_STATUS sekcja 6, punkt (2)): `--draft-config`
nie ma testu behawioralnego, bo wymaga prawdziwego parowania (klucz relacji,
konto na peerze, `zfs list` przez ssh). `test/draftscope` D1/D2 to statyczny
odczyt `deploy.sh`. **Nigdy nie był wykonany na żywo** — w statusie nie ma
żadnego pomiaru tej komendy na hoście.

Uwaga przed startem: to jest ścieżka NISKOPOZIOMOWA (ręczne parowanie po
liście datasetów). Wysokopoziomowa (`zfs-backup.sh add-client`/`activate`)
jej nie woła — `cmd_seed` używa `resolve_mode_datasets`. Jeśli flota nigdzie
nie używa `--draft-config` (krok 0 to mierzy), wynik labu może być też
„wycofać zamiast dowodzić" — to decyzja właściciela, nie labu.

Spisany w sesji, która hostów nie widzi. Każda flaga poniżej istnieje w
`deploy.sh` (`--pair`, `--peer=`, `--role=`, `--target=`, `--peer-datasets=`,
`--local-user=`, `--port=`, `--join=`, `--leave=`, `--draft-config`); DOKŁADNĄ
sekwencję wsad/`--join` drukuje sam `--pair` — wykonać to, co wydrukuje, nie
to, co pamięta ten dokument (E32).

## Co komenda robi (z kodu, `do_draft_config`)

1. Wymaga manifestu parowania `/etc/zfs-snapshot-all/peers/<label>.conf`
   (inaczej: `no pairing for '<peer>' yet -- run --pair (and --join on the
   peer) first`) i klucza `/root/.ssh/pairing/<label>_ed25519`.
2. Rola `pull`: `ssh -i <klucz> <konto>@<peer> "zfs list -H -o name"`
   (`could not list datasets on <peer> -- has --join run there yet?` gdy konto
   jeszcze nie istnieje). Rola `push`: lokalne `zfs list`.
3. Klasyfikuje listę względem `PEER_SAVED_DATASETS` z manifestu:
   `DRAFT_ROOTS` (zadeklarowane i obecne, z liczbą potomków), `DRAFT_MISSING`
   (zadeklarowane, NIE istnieją na hoście), `DRAFT_UNCOVERED` (obecne, poza
   parowaniem, płytkie) + licznik zbyt głębokich.
4. Pisze `/root/scripts/pairing/<label>.conf.suggested` — SAME KOMENTARZE:
   stanza `# [dataset:<target>/<label>/<ds>]` per korzeń, `#   src = konto@peer:ds`,
   `#   recursive    = flat` gdy korzeń ma potomków, `#   flags = -K <klucz
   konta zadań>[ -k <pinned host key>][ -p <port>]`, `#   use_template =
   <WYBIERZ ISTNIEJACY [template:]>`; sekcja `UWAGA: zadeklarowane w
   parowaniu, ale NIE ISTNIEJA` gdy `DRAFT_MISSING`; lista nieobjętych z
   podpowiedzią `--pair --peer=… --peer-datasets="<stare> <nowy>"`.
5. Ostrzeżenia na stderr: brak kopii klucza dla `--local-user`
   (`re-run --pair with --local-user=`), brak przypiętego klucza hosta
   (`this pairing predates host-key pinning … the draft omits -k`),
   manifest bez listy datasetów (`every candidate will be listed unfiltered`).
6. Nic nie instaluje; plik jest nadpisywany przy każdym przebiegu
   (`> "$out"`, bez pytania).

## Własności do dowiedzenia (suita ich nie pokaże)

- **(A)** na prawdziwym parowaniu `pull` plik `.suggested` powstaje, korzenie
  = zadeklarowane i obecne datasety, liczba potomków się zgadza, `recursive =
  flat` tylko przy potomkach, `-K` wskazuje klucz KONTA ZADAŃ (`$HOME/.ssh/…`
  konta z `--local-user`, nie roota), `-k` obecne, `-p` NIEobecne przy porcie 22;
- **(B)** dataset zadeklarowany przy `--pair`, którego na peerze nie ma,
  ląduje pod `UWAGA … NIE ISTNIEJA`, nie jako stanza;
- **(C)** dataset obecny na peerze poza parowaniem ląduje jako nieobjęty z
  podpowiedzią `--pair … --peer-datasets=`; głębokie liczone, nie wypisane;
- **(D)** drugi przebieg nadpisuje plik treścią identyczną (diff pusty),
  `/etc/zfs-snapshot-all`, crontab i `/root/scripts/*.conf` bez zmian;
- **(E)** rola `push` (z hosta-źródła): stanzy z lokalnego `zfs list`, ten
  sam kształt nagłówka `Kandydaci LOKALNE`;
- **(F)** bez `--join` na peerze: jasna odmowa `has --join run there yet?`,
  plik NIE powstaje.

## Kroki

Host A = kolektor (np. `pve9`), host B = peer/źródło (np. `pve10`), root,
pula `hdd`. Datasety wyrzucalne.

### 0. Hold, stan przed, czy flota tego używa

```
printf 'lab draft-config %s\n' "$(date +%F)" > /root/.zfs-snapshot-all-update-state/update-hold   # na A i B
cd /root/scripts/zfs-snapshot-all && git rev-parse --short HEAD
grep -l 'draft-config' /root/scripts/cron.log /root/scripts/pairing/*.suggested 2>/dev/null   # czy ktokolwiek to kiedyś uruchomił
ls -l /root/scripts/pairing/ 2>/dev/null
ls /etc/zfs-snapshot-all/peers/
```

Na B (źródło):

```
zfs create -p hdd/lab-draft/root1/child a; zfs create hdd/lab-draft/root1/child2   # root1 ma 2 potomków
zfs create hdd/lab-draft/root2                                                       # bez potomków
zfs create -p hdd/lab-draft/outside/deep/deeper                                      # poza parowaniem, głęboki
zfs list -r hdd/lab-draft
```

### 1. (F) Odmowa przed `--join`

Na A:

```
bash deploy.sh --pair --peer=<B> --role=pull --target=hdd/lab-draft-copy \
  --peer-datasets="hdd/lab-draft/root1,hdd/lab-draft/root2,hdd/lab-draft/ghost" --local-user=zfsbackup 2>&1 | tee /tmp/lab-pair.log
# `ghost` celowo nie istnieje na B -> (B) w kroku 2.
# --pair DRUKUJE wsad i komendy dla peera. NIE wykonywać ich jeszcze.
bash deploy.sh --peer=<B> --draft-config; echo rc=$?          # oczekiwane: rc!=0, "has --join run there yet?"
ls /root/scripts/pairing/*.suggested 2>&1                       # brak pliku dla tej etykiety
```

### 2. (A)(B)(C) Draft na prawdziwym parowaniu

Na B wykonać DOKŁADNIE komendy wydrukowane przez `--pair` (dostarczenie wsadu,
`bash deploy.sh --join=<wsad>`). Potem na A:

```
bash deploy.sh --peer=<B> --draft-config 2>/tmp/lab-draft.err; echo rc=$?
cat /tmp/lab-draft.err                                          # oczekiwane: BEZ "predates host-key pinning", BEZ "unfiltered"
L=/root/scripts/pairing/<label>.conf.suggested                  # label = etykieta z --pair (peer_label adresu)
grep -n '^# \[dataset:' $L                                      # DOKLADNIE root1 i root2
grep -n 'root1 ma 2 datasetow potomnych' $L                     # (A) liczba potomkow
grep -n 'recursive    = flat' $L | wc -l                        # 1 (tylko root1)
grep -n 'flags        =' $L                                     # -K /home/zfsbackup/... , -k obecne, BEZ -p
grep -n -A2 'NIE ISTNIEJA' $L                                   # (B) ghost
grep -n 'outside' $L                                            # (C) nieobjety, plytki; deep/deeper policzone nie wypisane
grep -n 'peer-datasets=' $L                                     # podpowiedz z lista starych + <nowy>
```

### 3. (D) Idempotencja i „nic nie zainstalowane"

```
sha256sum $L > /tmp/lab-sug1; stat -c %Y $L
find /etc/zfs-snapshot-all -newer /tmp/lab-pair.log -type f     # oczekiwane: tylko to, co zapisal --pair/--join, NIC z --draft-config
crontab -l | md5sum; su zfsbackup -s /bin/bash -c 'crontab -l' | md5sum
bash deploy.sh --peer=<B> --draft-config 2>/dev/null; sha256sum -c /tmp/lab-sug1   # OK (nadpisany identyczna trescia)
crontab -l | md5sum; su zfsbackup -s /bin/bash -c 'crontab -l' | md5sum             # bez zmian
```

### 4. (E) Rola push, z drugiej strony

Na B (teraz B jest źródłem i wypycha do A) — osobne, drugie parowanie w
drugą stronę, po tym samym schemacie (`--role=push --target=<dataset na A>`),
`--join` na A, potem na B:

```
bash deploy.sh --peer=<A> --draft-config; echo rc=$?
grep -n 'Kandydaci LOKALNE\|^# \[dataset:\|flags' /root/scripts/pairing/<labelA>.conf.suggested
```

### 5. Rozbiórka

```
# na kazdym hoscie, dla kazdej etykiety labu:
bash clean-relationships.sh                                     # audyt, czyta stan z dysku
bash deploy.sh --leave=<label>                                  # strona zrodla; drukuje, co zostalo do zrobienia recznie
zfs-backup.sh remove-client ... / clean-relationships.sh --purge=<label> --yes   # wg audytu
zfs destroy -r hdd/lab-draft; zfs destroy -r hdd/lab-draft-copy 2>/dev/null
rm -f /root/scripts/pairing/<label>.conf.suggested
bash clean-relationships.sh                                     # audyt czysty
rm -f /root/.zfs-snapshot-all-update-state/update-hold          # na A i B
```

## Co zapisać w wyniku

- SHA, hosty, etykiety, pełne `--pair` i to, co wydrukował;
- wynik kroku 1 (odmowa, brak pliku);
- pełny `.suggested` z kroku 2 i `stderr`;
- sumy z kroku 3 przed/po;
- nagłówek i stanzy z kroku 4;
- krok 0: czy `--draft-config` był kiedykolwiek użyty na flocie — to
  rozstrzyga, czy komenda zostaje, czy idzie do wycofania;
- każde odstępstwo od tego runbooka.
