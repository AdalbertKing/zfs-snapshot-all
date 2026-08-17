# Wdrożenie wyłącznie przez `zfs-backup.sh` — dedukcja po kampanii lab3

Status: analiza implementera dla właściciela, 2026-08-17. Wariant analizowany
zgodnie z dyspozycją: **najprostszy** — administrator zna źródła i cel, działa
w trybie remote-force. Pozostałe warianty osobno.

## 1. Co już postanowiono — i co kampania zmierzyła

Decyzja `OWNER-REMOTE-DEPLOY-UX-REDUCTION-2026-08-12.md` mówi wprost: docelowo
**jedna komenda wysokopoziomowa na kolektor**, `deploy.sh` zostaje warstwą
ekspercką. Wizja z tamtego dokumentu to dokładnie topologia dzisiejszego lab3.

Kampania zmierzyła, ile dziś kosztuje ta wizja naprawdę:

| krok | narzędzie | czy zgodny z wizją |
|---|---|---|
| konto na świeżym hoście | `deploy.sh --backup-user` | NIE — zejście do deploy |
| ogniwo backup (kolektor) | `zfs-backup.sh --source=… --install` | TAK |
| zgoda źródła | `deploy.sh --commit-scope` NA ŹRÓDLE | NIE — zejście + drugi host |
| wznowienie | ta sama komenda RUX | TAK |
| ogniwo sync bez zaufania ssh | wsad + `deploy.sh --join` + commit | NIE — trzy zejścia |
| aktywacja po naprawie crona | `zfs-backup.sh activate` | TAK |

Czyli: rdzeń jest zgodny z wizją, a **każde zejście do deploy.sh ma jedną z
dwóch przyczyn**: (a) granicę „grant nigdy zdalnie", (b) brak kanału
root-ssh kolektor→źródło.

## 2. Granica, o którą się rozbijamy — i jej uczciwa wycena

`REV-20260802-033 U10`: *finalize (`--commit-scope`, the grant) never runs
remotely, under any flag*. To była świadoma, zrecenzowana decyzja: zgodę na
eksport danych podpisuje człowiek na maszynie, która te dane ma.

Ale kampania obnażyła niewygodną prawdę o jej realnej wartości w trybie
remote: **`--join-remotely` już wykonuje działania roota na źródle** — tworzy
konto delegowane, instaluje klucz, wpina bramkę. Kanał zaufania (root ssh
operatora) jest już w użyciu. Odmowa zdalnego commitu chroni więc nie przed
kolektorem, któremu nie ufamy (ten już dostał konto), lecz wymusza **drugi
ludzki punkt styku** na drugiej maszynie — wartość ceremonialno-procesową,
nie techniczną.

Ta wartość jest realna w trybie domyślnym (literówka operatora zatrzymuje się
na człowieku przy źródle). Jest **iluzoryczna** w trybie, w którym ten sam
operator i tak zaraz wykona ssh na źródło i wklei komendę, którą podał mu
kolektor — czyli w 100% przypadków trybu remote. GUI tylko to wyostrzy:
klikający operator nie stanie się bardziej świadomy przez to, że GUI wykona
za niego ssh z komendą commit.

## 3. Propozycja: `--force-remote` (nazwa robocza — decyzja właściciela)

Zasada: **domyślna ścieżka zostaje dwudotykowa** (bezpieczny default,
granica U10 nienaruszona — po F1 jest wreszcie czytelna: odmowa nazywa czyj
ruch). Nowa flaga to jawna, głośna zgoda operatora na jednodotykowość:

```
zfs-backup.sh --source=HOST:DS --target=T --local-user=U --force-remote --install
```

Pod flagą orkiestrator, TYM SAMYM kanałem root-ssh, którego już użył join:

1. **zawęża** draft do dokładnie żądanych datasetów (po F2 draft już taki
   jest — commit podpisuje żądanie, nigdy „całą maszynę");
2. wykonuje `deploy.sh --commit-scope=<label>` na źródle;
3. zostawia na źródle głośny ślad audytowy (log + pole w manifeście:
   `GRANTED_REMOTELY_BY=<operator@collector>`);
4. odmawia wcześnie, jeśli kanał root-ssh nie istnieje — z komendą do
   nadania zaufania, nie w połowie przepływu.

Analogicznie domykane pozostałe zejścia:

- **konto lokalne**: `--local-user=U` przy nieistniejącym U tworzy je
  (wewnętrznie `deploy.sh --backup-user`) — działanie lokalne na maszynie,
  na której operator już jest rootem; osobna flaga zbędna;
- **wsad/join bez odwrotnego zaufania**: pod `--force-remote` join zawsze
  `--join-remotely`; bez flagi — dzisiejsza ścieżka wsadu.

Wynik: dwie komendy właściciela z decyzji z 12 sierpnia stają się faktem
(plus zero komend ukrytych za nimi), `deploy.sh` znika z rąk operatora,
GUI dostaje jeden czasownik na relację.

## 4. F7 — problem projektowy topologii łańcuchowej (blokuje elegancję)

Zmierzone: pve9 (ogniwo B) tworzy WŁASNE snapshoty na datasecie kopii pve1,
przeplatając dwie rodziny nazw w jednym prefiksie `automated_`. GFS na kopii
skasował świeży snapshot ogniwa A, trzymając równoległy ogniwa B. Dwóch
pisarzy, jedna rodzina nazw, jedna retencja — to nie jest bug jednego
narzędzia, tylko niedomknięta semantyka „kopia jest źródłem następnego
ogniwa".

Elegancka odpowiedź **już istnieje w pakiecie**: relacja PASYWNA
(`snapget -e` — konsumuj istniejący snapshot, nie twórz własnego; audyt już
rozpoznaje `installed_dataset_is_passive`). Ogniwo sync z kopii powinno być
pasywne: pve9 zabiera to, co ogniwo A już wytworzyło, niczego nie dopisuje,
retencją kopii włada wyłącznie środkowy host. Propozycja: `--mode=sync` przy
źródle będącym zarządzaną kopią → automatycznie pasywne (z jawnym wypisaniem
tego w podglądzie aktywacji).

## 5. Decyzje do podjęcia

1. **`--force-remote`: wchodzimy?** (moja rekomendacja: tak, w kształcie z §3
   — default dwudotykowy zostaje, flaga jest jawna i audytowana);
2. **nazwa flagi**: `--force-remote` / `--remote-grant` / `--one-touch`?
3. **F7**: sync-z-kopii = pasywny automatycznie, czy jawna flaga `--passive`?
   (rekomendacja: automatycznie + głośny wiersz w podglądzie, bo cichy wybór
   niepasywny to dokładnie dzisiejsza kolizja rodzin).

Do czasu decyzji nic z §3 nie jest implementowane; naprawy F1-F8 (PR #32) są
od tego niezależne i domykają ścieżkę dwudotykową.
