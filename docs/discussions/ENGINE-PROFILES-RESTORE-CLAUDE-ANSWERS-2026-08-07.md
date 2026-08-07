# Odpowiedzi implementera na burzę mózgów z 2026-08-07

Status: **odpowiedź projektowa, zero kodu.** Dokument źródłowy
(`ENGINE-FINALIZATION-PROFILES-RESTORE-2026-08-07.md`) wprost prosi, żeby nie
implementować odruchowo — więc nic nie zostało zaimplementowane.

Każde twierdzenie o dzisiejszym zachowaniu jest zmierzone na żywo albo wskazuje
plik i linię. Tam, gdzie nie wiem, piszę że nie wiem.

---

## 1. Długie opcje rekursji — da się, ale nie wszędzie tak samo

**Tak, bez zmiany semantyki.** Blokada jest jedna i techniczna: `snapsend.sh` i
`snapget.sh` parsują przez `getopts` (snapsend.sh:1456, snapget.sh:1461), a
bashowy `getopts` **nie obsługuje długich opcji w ogóle**. Nie ma tam czego
rozszerzyć — trzeba przepisać argumenty *przed* pętlą.

`delsnaps.sh` i `check-snap-age.sh` mają własne pętle `while [ $# -gt 0 ]`, więc
tam długa opcja to dosłownie jedna gałąź `case`.

Najmniej inwazyjny kształt dla silników transferu — pre-pass tłumaczący długie
na krótkie, uruchamiany raz, przed `getopts`:

```
--recursive=atomic  ->  -r
--recursive=flat    ->  -R
--recursive=no      ->  (nic)
```

Trzy warunki, żeby to nie było pułapką:

1. **Pre-pass musi umieć przestać.** Po `--` przepisywanie się kończy, inaczej
   dataset nazwany `--recursive=flat` (absurd, ale legalny ciąg) zostaje zjedzony.
2. **Konflikt jest błędem, nie ostatnią wygraną.** `--recursive=flat -r` musi
   odmówić. Dziś `-r -R` też powinno odmawiać — sprawdziłem, **nie odmawia**,
   wygrywa ostatnia flaga. To osobna, drobna usterka do dopisania przy okazji.
3. **Wartość musi być walidowana** tą samą listą co `gen-cron`, żeby
   `--recursive=ture` nie stało się cichym `no`. Ten sam fail-open naprawialiśmy
   już w REV-054.

**Round-tripy nie ucierpią**, pod warunkiem odpowiedzi z punktu 2 poniżej.

### Czy `--recursive=no` ma być jawnym no-opem

**Tak, akceptować.** Koszt to jedna gałąź `case`, a zysk realny: generator
maszynowy nie musi mieć gałęzi „jeśli no, to pomiń flagę". Ta gałąź to dokładnie
miejsce, w którym powstają błędy typu „pominąłem flagę i pominąłem też coś
obok". Milcząca akceptacja `no` jest tańsza niż warunek u każdego wołającego.

---

## 2. Czy generowany cron ma przejść na długie opcje — **nie, na razie**

Rekomendacja: **generator nadal emituje krótkie flagi.**

Powody, w kolejności wagi:

1. **Każdy crontab we flocie zostałby przepisany.** Linie są dziś identyczne co
   do bajtu z zainstalowanymi blokami — to właśnie ta bajtowa równość była
   dowodem bezpieczeństwa migracji rekurencji (REV-055, REV-057). Zmiana formy
   emisji unieważnia ten dowód dla wszystkich hostów naraz i zamienia „zero
   niewyjaśnionych linii" w „wszystkie linie się zmieniły, sprawdź ręcznie".
2. **`cron2conf.sh` czyta kształt linii jako literalny kontrakt** (kontrakt
   `cron-line-shape` w `test/deps.conf`). Musiałby akceptować obie formy —
   czyli dwie reprezentacje tej samej decyzji, co jest dokładnie tą chorobą,
   którą REV-054 leczyła po stronie configu.
3. **Czytelność crona już została rozwiązana inaczej.** `WDROZENIE-PROXMOX.md`
   ma rozdział „Jak czytać wygenerowaną linię crona" z tabelką fragment po
   fragmencie. Linia crona jest artefaktem maszynowym; człowiek czyta config,
   gdzie źródłem prawdy jest `recursive = no|flat|atomic`.

Długie opcje mają wartość **dla człowieka piszącego polecenie ręcznie** — i tam
je dodajmy. Gdyby jednak właściciel chciał je w cronie, to jest osobna zmiana z
własną kaskadą: regeneracja + diff na czterech hostach, plus rozszerzenie
`cron2conf` o obie formy.

---

## 3. Profil a grant — profil trzyma **selektor**, nie zmaterializowany scope

Rekomendacja jednoznaczna: **profil przechowuje politykę wyboru, a nie listę
datasetów.** Powody:

- lista zmaterializowana starzeje się w tej samej chwili, w której powstaje —
  to jest dokładnie luka VM 104 na pve0 (wątek #22), tylko przeniesiona o
  poziom wyżej;
- ten sam profil ma być użyteczny na kilku hostach, a lista datasetów nie jest
  przenośna;
- grant jest własnością **relacji**, nie profilu, i musi taki zostać.

Przepływ, który proponuję:

```
selektor z profilu           ->  kandydaci (zfs list na źródle)
                             ∩
grant z enrolmentu (scope.ini)
                             =
effective scope  ->  sekcje [dataset:] dla gen-cron.sh
```

**Twarda reguła:** jeżeli selektor wskazuje cokolwiek poza grantem, to jest
**odmowa z nazwaniem konkretnych datasetów**, nigdy ciche przycięcie. Ciche
przycięcie oznacza, że operator wybrał profil „backupuj wszystko", dostał połowę
i nikt mu tego nie powiedział — czyli znowu fałszywe zdrowie, ta sama klasa
błędu co REV-046 i REV-056.

Rozszerzenie uprawnień musi iść **wyłącznie** przez istniejący workflow
`--pair`/`--join`, bo tylko on dotyka peera. Profil nie może mieć żadnej ścieżki
do `zfs allow`.

`lib-scope.sh` już ma gramatykę (`include_parent`, `include_children`,
`exclude`, `exclude_tree`) i funkcję `scope_includes` — **to jest gotowy język
selektora**. Nie wymyślajmy drugiego.

---

## 4. Minimalny model danych profilu — profil jako **makro nad configiem v4**

Rekomendacja: profil **rozwija się do istniejących sekcji v4**
(`[template:]`, `[dataset:]`, `[prune:]`) i nic poza tym. `gen-cron.sh`
pozostaje **jedynym** rendererem.

```
profil (+ relacja + selektor)  ->  effective config v4  ->  gen-cron.sh  ->  cron
                                          ^
                                   to pokazujemy operatorowi
```

Co to daje:

- **zero duplikacji logiki** — wrapper nie zna harmonogramów, retencji ani
  flag; produkuje tekst, który i tak przechodzi przez pełną walidację
  generatora, razem z odmowami, których wrapper nie musi znać;
- **punkt 4 z §2 dokumentu wychodzi za darmo**: „pokazanie rozwiniętego
  effective config/crona przed aktywacją" to wypisanie pliku pośredniego i
  `gen-cron.sh -c <plik>` bez `--install`;
- **profile predefiniowane i własne są tym samym bytem** — plik w repo kontra
  plik obok configu; różni je tylko ścieżka i to, że repo swoje aktualizuje.

Precedens już działa: `zfs-backup.sh` dziś generuje sekcje `standard_*`/`keep_*`
i `[prune:]` z `gfs`, a kontrakt `profile-config-schema` pilnuje, żeby renderem
był prawdziwy `gen-cron.sh`. Profile to rozszerzenie tego wzorca, nie nowa
warstwa.

**Czego bym pilnował:** profil nie może dostać własnego pola, które robi to samo
co pole configu pod inną nazwą. Każde pole profilu albo mapuje się 1:1, albo
jest polityką wyższego rzędu rozwijaną do kilku pól — nigdy trzecim synonimem.

---

## 5. Czy da się dziś znaleźć wspólny atomic restore point — **tak dla atomic, nie dla flat**

Zmierzone na żywo na `192.168.11.11` (`rpool/data`, polityka `atomic`):

```
rpool/data@automated_hourly_2026-08-07_15-01-01              creation 1786107661
rpool/data/vm-100-disk-0@automated_hourly_2026-08-07_15-01-01 creation 1786107661
rpool/data/vm-101-disk-0@automated_hourly_2026-08-07_15-01-01 creation 1786107661
rpool/data/vm-106-disk-0@automated_hourly_2026-08-07_15-01-01 creation 1786107661
rpool/data/vm-106-disk-1@automated_hourly_2026-08-07_15-01-01 creation 1786107661
```

**Identyczna nazwa i identyczny `creation` w całym poddrzewie.** Nazwa jest więc
dziś wystarczającym korelatorem runu dla `atomic` — bo `zfs snapshot -r` tworzy
je jednym wywołaniem.

To samo dla **`flat` z `-q`**: `quiesce_snap_suffix` jest liczony **raz** przed
zamrożeniem (snapsend.sh:1935), więc cały zbiór dostaje jedną nazwę.

**Czego brakuje — `flat` bez `-q`:** `create_snapshot` liczy
`$(date '+%Y-%m-%d_%H-%M-%S')` **osobno dla każdego datasetu**
([snapsend.sh:862](../../snapsend.sh)). Poddrzewo przekraczające granicę sekundy
dostaje **różne nazwy** i run przestaje być korelowalny.

Minimalna brakująca rzecz to więc **jedna zmiana**: policzyć sufiks raz na
przebieg i podać go do `create_snapshot`, zamiast liczyć w środku. Nie zmienia
formatu nazwy, nie zmienia niczego dla `atomic` ani dla `-q`, a `flat` staje się
korelowalny.

**Zastrzeżenie, które musi wybrzmieć:** wspólna nazwa dowodzi wspólnego
*przebiegu*, nie wspólnego *punktu w czasie*. Pod `flat` bez `-q` snapshoty i
tak powstają jeden po drugim (to jest udokumentowana właściwość trybu), więc
korelacja runu daje spójny **zestaw do przywrócenia**, a nie spójny stan
aplikacji. Obietnica „point-in-time" dla całego poddrzewa jest uczciwa tylko dla
`atomic` i dla `flat -q`. Proponuję, żeby restore to **jawnie raportował**,
zamiast udawać, że wszystkie trzy tryby są równoważne.

---

## 6. SAFE restore testowalny bez dotykania produkcji

Kluczowa obserwacja: **to już częściowo istnieje**. Scenariusz S5
(`test/scenarios/run.sh`) robi dokładnie „zniszcz źródło, odtwórz z kopii" i
sprawdza, że **odtworzony snapshot ma oryginalny GUID** — czyli strumień jest
bit-identyczny. To jest gotowe kryterium weryfikacji, nie trzeba wymyślać
nowego.

Proponowany kształt:

1. **Planner osobno od wykonania.** `restore --plan` wypisuje tabelę
   dataset → snapshot → realny timestamp → cel i **kończy się**. Planner nie
   dotyka ZFS-a poza `zfs list`. To jest artefakt, który da się dołączyć do
   zgłoszenia i przejrzeć przed czymkolwiek.
2. **Cel domyślnie w namespace restore**, nigdy nadpisanie. Kolizja z
   istniejącym datasetem to odmowa.
3. **Weryfikacja przez GUID**, jak w S5: po odtworzeniu porównać GUID-y
   odtworzonych snapshotów z tymi po stronie kopii. Zgodność GUID-ów jest
   mocniejszym dowodem niż jakiekolwiek porównanie zawartości i jest darmowa.
4. **Testowalność:** SAFE restore do namespace jest z definicji nieniszczący,
   więc może być normalnym scenariuszem w `test/scenarios` na scratch poolu —
   bez roota na produkcji, bez wyjątków.

Odpowiedź na pytanie wprost: SAFE da się realnie przetestować, bo **nie ma
trybu, w którym dotyka produkcyjnego datasetu**. Jeśli projekt SAFE wymagałby
takiego trybu, to jest to sygnał, że to już nie jest SAFE.

---

## 7. Żeby `--force` nie znaczył „zniszcz i módl się"

Rekomendacja: **`--force` w ogóle nie powinien istnieć jako nazwa tej operacji.**

Powody i propozycja:

- **Osobny czasownik, nie flaga.** `restore-replace` zamiast
  `restore --force`. Flaga dokleja się do polecenia, które operator już ma w
  historii powłoki; czasownik trzeba napisać od nowa.
- **Potwierdzenie musi nieść treść.** Nie `--yes`, tylko odbicie tego, co ginie:
  operator wpisuje nazwę datasetu albo liczbę datasetów z planu. Precedens w
  tym projekcie już jest — `zfs-backup.sh` i `deploy.sh` wymagają jawnych
  potwierdzeń przy operacjach nieodwracalnych.
- **Odmowa przy działającym gościu jest domyślna i nie ma flagi ją omijającej.**
  Zatrzymanie VM-ki to decyzja operatora, wykonywana przez niego, świadomie.
- **Pre-restore snapshot obecnego stanu przed nadpisaniem** — i to jest warunek
  wykonania, nie „jeśli wykonalne". Jeżeli nie da się go zrobić, operacja
  odmawia. Inaczej mamy nieodwracalność bez ostrzeżenia.
- **`zfs recv -F` zostaje mechanizmem** i nigdy nie jest wywoływane dlatego, że
  operator napisał „force". To rozróżnienie z §3.3 dokumentu uważam za
  najważniejsze zdanie w całej nocie: dziś `recv -F` jest **bezwarunkowe** w
  `snapsend.sh` ([snapsend.sh:1369](../../snapsend.sh)) i to jest poprawne dla
  replikacji, gdzie cel *ma* być podporządkowany. Restore ma odwrotną
  charakterystykę i nie wolno mu tego mechanizmu odziedziczyć przez przypadek.

Jedna rzecz, o której warto pamiętać przy projektowaniu FORCE, zmierzona
2026-08-07: **cel replikacji nie ma stanu, którego nie da się nadpisać** — przy
utracie wspólnej bazy snapsend robi pełny re-seed i kończy `rc=0`. Restore nie
może dziedziczyć tej „uprzejmości".

---

## Uwaga do kolejności prac z §4 dokumentu

Zgadzam się z kolejnością, z jednym doprecyzowaniem: **punkt 5 powyżej (sufiks
liczony raz na przebieg) należy do „ostatnich szlifów silnika", nie do projektu
restore.** To zmiana w `snapsend.sh`, więc powinna wejść **przed** zamrożeniem
kontraktu i dużą kaskadą, a nie po. Inaczej restore zacznie od żądania zmiany w
zamrożonej warstwie.

Poza tym nie widzę powodu, żeby cokolwiek z profili lub restore wyprzedzało
kaskadę.

## Czego nie wiem

- Czy właściciel chce, żeby restore działał także **z hosta trzeciego** (nie
  źródło, nie cel). To zmienia model uprawnień i nie ma tego w nocie.
- Jak profile mają się zachować, gdy relacja jest **spauzowana lub
  zablokowana** (REV-045/052). Podejrzewam, że aktywacja profilu na
  zablokowanej relacji powinna odmawiać, ale to decyzja właściciela.
- Czy „wszystkie datasety relacji" w §3 restore znaczy *objęte grantem*, czy
  *faktycznie backupowane*. Na pve0 to dziś dwa różne zbiory (wątek #22).
