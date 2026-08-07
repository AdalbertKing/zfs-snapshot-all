# Burza mózgów właściciel ↔ reviewer: ostatnie szlify silnika, profile i restore

Data: 2026-08-07

Status: **dyskusja projektowa, nie polecenie implementacji i nie recenzja REV**.

Cel tego dokumentu: przekazać implementerowi (Claude) aktualny kierunek ustalony
z właścicielem przed ostatnimi zmianami silnika i planowaną dużą kaskadą testów.
Nie implementować na podstawie samej tej noty bez przejścia przez dyskusję i
zamknięcie bieżących findingów.

---

## 1. Ostatni planowany szlif CLI silników: długie, semantyczne opcje rekursji

Właściciel zauważył zgrzyt między krótkimi `-r/-R` projektu a natywnymi
poleceniami ZFS (`zfs snapshot -r`, `zfs send -R`). Obecne znaczenie projektu
jest jednak poprawne i powinno zostać zachowane:

- `snapsend.sh` / `snapget.sh`:
  - `-r` = atomic recursive: jedno drzewo jako jedna jednostka/stream,
  - `-R` = flat recursive: runtime discovery całego subtree, każdy dataset
    transferowany niezależnie;
- `delsnaps.sh` / `check-snap-age.sh`:
  - `-R` = przejście po subtree per dataset;
  - nie istnieje sensowny tryb "atomic prune" ani "atomic age".

Nie zmieniać więc `-R` na `-r` w prune/monitor tylko dla symetrii — byłoby to
estetyczne, ale semantycznie fałszywe.

### Rekomendowany kierunek

Dodać długie, samodokumentujące aliasy, zachowując krótkie flagi dla
kompatybilności:

```text
snapsend.sh --recursive=atomic   == -r
snapsend.sh --recursive=flat     == -R
snapget.sh  --recursive=atomic   == -r
snapget.sh  --recursive=flat     == -R

delsnaps.sh       --recursive    == -R
check-snap-age.sh --recursive    == -R
```

Do rozważenia: czy `--recursive=no` ma być jawnym, akceptowanym no-opem w
transfer engines (przydatne dla maszynowo generowanych komend), czy po prostu
brak opcji ma znaczyć `no`.

`gen-cron.sh` nadal ma źródło prawdy w `recursive = no|flat|atomic`; długie
opcje są poprawą publicznego CLI i czytelności wygenerowanego crona, nie nowym
modelem konfiguracji.

Po tej zmianie właściciel chce **zamrozić niską warstwę i uruchomić dużą
kaskadę testów** przed dalszym rozwojem produktu.

---

## 2. Warstwa wysoka: profile jako kompletne szablony zachowania

Istniejące `docs/discussions/PROFILES-AGREED-2026-08-04.md` pozostaje punktem
wyjścia, ale właściciel rozszerza intencję profili.

Profil nie ma być wyłącznie paczką retencji. Ma opisywać możliwie kompletną,
wysokopoziomową politykę backupu, m.in.:

- zakres/wybór datasetów (scope/selector),
- `recursive = no|flat|atomic`,
- tryb pracy backup/sync i inne istotne tryby wysokiej warstwy,
- harmonogramy,
- prefiksy snapshotów,
- quiesce/consistency policy,
- parametry transferu, jeśli są częścią polityki (np. catch-up/compression),
- retencję,
- drabinkę GFS,
- monitoring/staleness,
- ewentualne excludes/protection rules,
- wszystkie inne ustawienia, które użytkownik powinien wybierać jako jedną
  politykę zamiast ręcznie składać z flag silnika.

Chcemy:

1. kilka **stałych, predefiniowanych profili** dostarczanych z repo;
2. **profile własne użytkownika**;
3. wybór profilu w wysokiej warstwie, bez wymagania znajomości `snapget`,
   `snapsend`, `delsnaps`, flag `-r/-R/-q` itd.;
4. możliwość pokazania operatorowi rozwiniętego effective config/crona przed
   aktywacją.

### Twarda granica bezpieczeństwa dotycząca scope

Profil może **deklarować/proponować zakres**, ale nie może sam rozszerzać
uprawnień przyznanych podczas enrolmentu.

Innymi słowy:

```text
profile desired scope
        ∩
peer/enrolment granted scope
        =
effective allowed scope
```

Jeżeli profil żąda czegoś poza grantem, system powinien odmówić albo przejść
przez jawny workflow rozszerzenia scope/grantów. Nigdy nie wolno dopuścić do
sytuacji, w której podmiana profilu po cichu zwiększa privileged surface na
peerze.

Do dalszej dyskusji z właścicielem i reviewerem: czy scope jest literalną
częścią profilu, czy profil przechowuje selector/policy (np. "całe rpool/data,
exclude ..."), a enrolment materializuje z tego bieżący scope.

---

## 3. Brakująca funkcja produktu: restore z backupu

Właściciel chce odzyskiwanie:

- wybranych datasetów **lub wszystkich datasetów relacji**;
- do wskazanego **dnia i godziny**;
- w wariancie **safe** oraz **force**.

To powinien być workflow wysokiej warstwy, nie ręczne składanie `zfs send | zfs
recv` przez administratora.

### 3.1. Wybór punktu czasu

Proponowany kontrakt:

- użytkownik podaje timestamp, np. `2026-08-06 14:30`;
- system dla każdego datasetu wybiera najnowszy kwalifikujący snapshot `<=`
  żądanego czasu;
- wynik planowania jest pokazany **przed zapisem**: dataset → snapshot → realny
  timestamp → destination;
- jeżeli dla któregoś datasetu nie ma snapshotu spełniającego warunek, restore
  całości domyślnie ma się zatrzymać, a nie tworzyć mieszankę bez ostrzeżenia.

Dla polityk `atomic` trzeba szczególnie zdefiniować spójny restore point.
Najbezpieczniejszy kierunek: restore całego atomic scope powinien wymagać
snapshotów pochodzących z tego samego logicznego runu/punktu, a nie wybierać
niezależnie `<= time` dla każdego dziecka. Jeśli dzisiejsze nazewnictwo/metadane
nie pozwalają jednoznacznie skorelować runu, to jest wymaganie projektowe do
rozwiązania przed obietnicą point-in-time restore całego atomic subtree.

### 3.2. SAFE restore — domyślne

Domyślny restore nie powinien nadpisywać aktywnego datasetu.

Preferowany model:

```text
backup snapshot
    -> nowy/staging dataset
    -> verify/list/optional mount
    -> operator decyduje co dalej
```

Przykładowo źródłowe `rpool/data/v1` może zostać odtworzone do bezpiecznego
namespace typu:

```text
rpool/restore/<relation>/<timestamp>/rpool/data/v1
```

lub do jawnie podanej ścieżki. Dokładna konwencja do dyskusji.

SAFE musi odmawiać kolizji z istniejącymi aktywnymi datasetami, chyba że
operator poda nową ścieżkę/staging.

### 3.3. FORCE restore — destrukcyjny i jawny

Force oznacza przywrócenie na właściwą/originalną ścieżkę z możliwością
nadpisania bieżącego stanu. Powinien mieć osobny, wyraźny kontrakt bezpieczeństwa:

- plan/dry-run zawsze przed zmianą;
- wykrycie uruchomionych VM/LXC należących do datasetów i domyślna odmowa;
- jawne potwierdzenie destrukcji;
- przed nadpisaniem utworzenie technicznego pre-restore snapshotu bieżącego
  stanu, jeśli jest to wykonalne i bezpieczne;
- fail-closed na niejednoznaczne mapowanie datasetu lub niespójny restore point;
- po restore weryfikacja GUID/snapshot/dataset tree i czytelny raport;
- nie mieszać "force receive" z decyzją biznesową: `zfs recv -F` jest tylko
  mechanizmem niskiej warstwy, nie zgodą operatora na utratę bieżącego stanu.

Do dyskusji: czy FORCE powinien wymagać dodatkowego przełącznika typu
`--replace-live`/`--confirm-destructive`, zamiast przeciążać słowo `--force`.

### 3.4. Kierunki transportu

Restore musi działać jako odwrotność backupu niezależnie od tego, czy backup
był wykonywany pull czy push. Wysoka warstwa powinna znać relację i mapowanie
source ↔ backup target, a operator nie powinien ręcznie konstruować endpointów
`zfs send | ssh zfs recv`.

---

## 4. Proponowana kolejność prac

1. Zamknąć bieżące findingi/reviews.
2. Ostatni mały kontrakt CLI silnika: długie opcje rekursji (po osobnym
   uzgodnieniu i testach kompatybilności).
3. **Duża kaskada testów niskiej warstwy** i freeze kontraktu engine.
4. Dyskusja/implementacja pełnego systemu profili wysokiej warstwy.
5. Osobny projekt `restore`: planner → safe restore → destructive/force restore.
6. Dopiero po tym kolejne rozszerzenia niskopoziomowego engine, chyba że testy
   odkryją błąd.

---

## 5. Pytania do Claude'a do dalszej dyskusji

Proszę nie implementować odruchowo. Najpierw odpowiedzieć projektowo:

1. Czy długie aliasy powyżej da się dodać bez zmiany istniejącej semantyki,
   `getopts` i round-tripów `gen-cron/cron2conf`? Jak najmniej inwazyjnie?
2. Czy wygenerowany cron powinien od razu przejść na długie opcje, czy przez
   jeden okres kompatybilności nadal emitować krótkie?
3. Jak pogodzić profil zawierający scope z istniejącym `scope.ini`/grantem tak,
   aby profil nigdy nie rozszerzał uprawnień bokiem?
4. Jaki minimalny model danych profilu pozwoli mieć zarówno predefiniowane, jak
   i własne profile bez kopiowania logiki `gen-cron.sh` do high-level wrappera?
5. Czy dzisiejsze snapshot names / metadata pozwalają jednoznacznie znaleźć
   wspólny atomic restore point dla całego subtree na zadany timestamp? Jeśli
   nie, czego minimalnie brakuje?
6. Jak zaprojektować restore SAFE tak, aby można było realnie przetestować
   odzysk przed dotknięciem produkcyjnego datasetu?
7. Jak zaprojektować FORCE restore tak, aby `--force` nie stał się aliasem dla
   "zniszcz bieżący stan i módl się"?

Właściciel chce te trzy obszary (ostatni CLI engine, profile, restore) omówić
wspólnie z Claude'em i reviewerem przed implementacją.
