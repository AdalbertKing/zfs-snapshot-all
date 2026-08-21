# Konwencje pakietu — kanon

Uchwała z 2026-08-21, po audycie klasy „to samo pojęcie, inna gramatyka
zależnie od warstwy". Ten dokument jest **normatywny**: nowy kod ma się
stosować, istniejący był do niego doprowadzony w koszykach A (PR #98)
i B/C (PR tej zmiany). Rozjazdy, które ZOSTAJĄ, są wymienione na końcu —
każdy z powodem, nie z przeoczenia.

## 1. Listy datasetów

**Przecinek.** Wejście przyjmuje też spacje (`dataset_list_split`,
`lib-scope.sh`) — bo wewnętrzny format przechowywania jest spacjowy i
istniejące manifesty muszą się parsować — ale dokumentujemy i emitujemy
przecinek. Dotyczy każdej flagi przyjmującej więcej niż jeden dataset.

## 2. Konto delegowane

Dwa czasowniki, dwie flagi — to jest **rozróżnienie**, nie rozjazd:

- `--local-user=NAME` — **wybór**: jako kto mają chodzić zadania (zfs-backup
  i deploy znaczą tu to samo);
- `--backup-user=NAME` — **bootstrap**: utwórz/utrzymuj konto delegowane.

Konto nigdy nie pochodzi z `server.conf` — jest faktem relacji.

## 3. Druga maszyna

`--host` to forma zwykła (zfs-backup), `--peer` forma deploy'a (aliasowane
wzajemnie od tej uchwały), `--lan` alias historyczny. W configu `src`/`dst`
zostają — to strony transferu, nie nazwa maszyny.

**Dwukropek**: w `--source=HOST:DATASET` oddziela dataset, w
`--host=HOST:PORT` port. Zostaje (obie formy są zakorzenione), ale
`--source` z datasetem złożonym z samych cyfr ostrzega, że wygląda to na
port.

## 4. Czasowniki

- **Audyt bez skutków**: `--plan` (alias `--check-only` w deploy zostaje).
- **Wykonanie**: `--install` tam, gdzie efektem jest blok crona;
  `--apply` tam, gdzie efektem jest przepisanie configu;
  `--commit-scope` dla podpisania zakresu. Trzy słowa zostają — nazywają
  różne skutki, nie ten sam.
- Silniki działają domyślnie (`-n` = dry-run) — zamrożone i słusznie:
  to narzędzia-motory, nie planery.

## 5. Potwierdzenia

Każdy prompt przyjmuje `t|T|tak|TAK|y|Y|yes|YES`. Wszystko inne = odmowa.
Każda komenda z promptem ma `--yes` i `-y`.

## 6. Kody wyjścia

`0` czysto · `1` awaria narzędzia · `2` błąd użycia · `3` **znaleziska**
(raport, na który się reaguje — nie awaria). `check-snap-age` ma własny
kontrakt monitorowy (0/1/2/3=UNKNOWN) i jest z niego **wyłączony** — to
kontrakt Nagios-kształtny, starszy i zamrożony.

## 7. Pola configu

- `keep` = licznik (ile zatrzymać); `retain` = surowe flagi retencji
  (biała lista, patrz koszyk A3); `age` = to samo co retain w sekcji
  bookmarków. Wielka litera = licznik, mała = wiek — **wielkość litery
  zmienia znaczenie** i generator ostrzega przy podejrzanej małej.
- Rekursja: `[dataset:]` ma `no|flat|atomic` (dwa tryby wysyłki silnika);
  `[prune:]`/`[prune-bookmarks:]` mają `yes|no` (delsnaps ma jedną
  rekursję). Odmowa `flat`/`atomic` w sekcji prune tłumaczy mapowanie.
- `prefix` (co tworzę) i `pattern` (co tnę) muszą się widzieć — generator
  to krzyżowo sprawdza wszędzie tam, gdzie oba są w zasięgu.

## 8. Wersja

`--version` wszędzie. Silniki noszą własne `VERSION='vX.Y'`;
`deploy.sh`/`zfs-backup.sh` drukują SHA checkoutu — bo wdrożeniem JEST
godzinny `git pull`, więc SHA to uczciwa wersja.

## 9. Rozjazdy, które ZOSTAJĄ (i dlaczego)

| co | gdzie | dlaczego zostaje |
|---|---|---|
| `-F` = reconcile vs clear-cut | silniki | zamrożone; kontrakt z każdym crontabem floty. Bariera: lint `retain`/`age` + `ssh_flags` |
| `-H` = historia vs licznik | silniki | jw. |
| `-v N` vs `-v` bool | silniki vs delsnaps/monitor | jw.; wskazówki w deploy poprawione, kandydat na okno odmrożenia |
| pozycyjne odwrócone (snapsend/snapget) | silniki | celowe od v2.61, udokumentowane |
| delsnaps bez flag = skasuj wszystko | delsnaps | **decyzja właściciela** (filozofia admin-tool); generator odmawia wyemitowania takiej linii, ręczne użycie pozostaje na odpowiedzialność operatora |
| `3` = UNKNOWN w check-snap-age | monitor | kontrakt monitorowy, zamrożony |
| wiek `1h` przy progu `90m` | check-snap-age | zamrożony; kandydat na okno odmrożenia |
| `schedule` vs `*_schedule` | config | sekcja bookmarków ma jedno zadanie, reszta trzy; ujednolicenie = migracja configów floty za kosmetykę |
| cztery słowa na „zatrzymaj" | całość | to cztery RÓŻNE mechanizmy; słownik nazywa różnice, patrz LAB-RUNBOOK §9 |

## 10. Okno odmrożenia silnika — stanowisko

Nie odmrażać dla B/C — wszystko powyżej dało się zrobić nad silnikiem.
Odmrozić **raz**, przy zaplanowanej operacji czasów (silnik ma zwracać
czasy operacji wyższym warstwom), i w tym samym oknie zabrać kandydatów
z tabeli §9 (`-v N` w delsnaps/monitorze, format wieku w komunikatach
monitora, ewent. `-Q` w snapsend dla parytetu). Jedno okno, jedna
kampania ponownego dowodu na żywo — nie śmierć przez tysiąc odwilży.
