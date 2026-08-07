# Profiles — implementer's answers to §12

Odpowiedź na `PROFILES-NATIVE-FRAGMENTS-PLAN-2026-08-07.md`. Bez kontrpropozycji:
model natywnych fragmentów przyjmuję. Poniżej osiem odpowiedzi i trzy
zastrzeżenia, każde z dowodem z drzewa albo z dzisiejszej pracy na żywo.

---

## 1. Fragmenty natywne kontra „profil jako makro" — czy to ukryty kompilator?

**Prostsze i bezpieczniejsze, pod jednym warunkiem.**

Moja wcześniejsza propozycja mówiła „profil rozwija się do sekcji v4". Wasza jest
tym samym, tylko fragmenty **są** tekstem v4, zamiast być na niego mapowane.
Różnica jest istotna: znika tablica odwzorowań, a więc znika miejsce, w którym
dwie reprezentacje mogą się rozjechać. To ta sama lekcja co REV-054 — jedna
decyzja, jedna reprezentacja.

Warunek: **kopiuj albo odmów, nigdy nie poprawiaj.** Kompilator wchodzi tylnymi
drzwiami w chwili, gdy orkiestrator musi fragment *zmodyfikować* — przemianować
szablon, dobrać wartość, scalić pole. §9 już to przewiduje (nazwy szablonów są
finalne w pliku profilu, nikt ich nie zmienia) i to jest właściwa odpowiedź.
Proponuję zapisać ją jako regułę: jeżeli kiedykolwiek trzeba będzie fragment
dostosować, to jest odmowa z nazwaniem pola, a nie cicha korekta.

## 2. Czy da się tanio ograniczyć `dataset.inc` / `prune.inc`?

**Tak, i nie trzeba pisać nowego walidatora.** `gen-cron.sh --dump-fields` już
istnieje i wypisuje `<rodzaj> <pole>` dla całej listy dozwolonych pól — powstało
właśnie po to, żeby test mógł sprawdzić listę bez skrobania kodu.

Ograniczenie fragmentu to więc:

1. tylko linie `pole = wartość`, **żadnych nagłówków sekcji**;
2. pole musi być na liście z `--dump-fields` dla właściwego rodzaju sekcji;
3. minus jawna czarna lista pól należących do relacji: `src`, `dst`, `flags`,
   `pair_label`, `notify`.

Punkt 2 jest **wyprowadzany**, nie przepisywany, więc nie może się rozjechać z
generatorem. To około dziesięciu linii i zero nowej wiedzy o schemacie.

## 3. Czy `deploy.sh` ma nie dostawać żadnej linii profilu?

**Zgoda, i mam na to świeży dowód, nie tylko zasadę.**

Etap 0 na pve0, dzisiaj: dopisanie datasetów do configu **nie wystarczyło** —
zadanie padło na `permission denied`, bo granty na tym hoście są nadawane
per dataset. Musiałem osobno wykonać `zfs allow`.

To jest empiryczny dowód, że polityka i uprawnienie są w tym drzewie **osobnymi
władzami**. Gdyby profil mógł podać cokolwiek do `deploy.sh`, podmiana profilu
stawałaby się ścieżką poszerzenia uprawnień na peerze. Żadnego wiersza deploy.

## 4. Czy podział rekursji transferu i zakresu prune'u jest poprawny?

**Tak**, i dorzucam powód, którego w nocie nie ma.

`[dataset:] recursive` steruje **trzema** liniami (transfer, prune inline,
monitor), ale wszystkimi w obrębie **własnej ścieżki sekcji**.
`[prune:] recursive` to zamiatanie **poddrzewa**. Różny promień rażenia.

Dochodzi konkretny tryb awarii, który już wystąpił w tym projekcie: liść pod
rekurencyjnym `[prune:]` rodzicem **ściga się** z własnym prune'em, a przegrany
zgłasza „could not find any snapshots to destroy" i alarmuje. Pozwolenie
profilowi na poszerzanie zakresu prune'u odtworzyłoby ten wyścig **między
relacjami**, gdzie nikt go nie szuka.

**Zastrzeżenie do zapisania wprost:** skoro profil posiada `recursive` dla
`[dataset:]`, to profil **wpływa** na prune i monitor — w zakresie własnej
ścieżki datasetu. Nie jest prawdą, że prune należy wyłącznie do orkiestratora.
Warto to napisać, żeby za pół roku nikt nie wyprowadził z tego błędnego wniosku.

## 5. Co dokładnie ma być bazą bajtową przed wyjęciem hardkodu?

**Artefakty generowane, nie configi pisane ręcznie.** Konkretnie, dla każdego
klienta: efektywny CONFIG v4 wypisany przez `zfs-backup.sh` oraz wyrenderowany
blok crona — po jednym komplecie dla **każdego z dwóch kształtów** (backup i
sync), bo to one różnią się topologią prune'u.

Technika porównania: ta sama, która dziś dwukrotnie się sprawdziła —
**kontrola pierwsza**. Najpierw dowieść, że stan sprzed zmiany odtwarza to, co
zainstalowane; dopiero potem porównywać stan po zmianie. Bez tego zgodność „po"
nie odróżnia poprawnego refaktoru od porównania, które nie może wypaść źle.
Przy REV-055 zrobiłem to bez kontroli i dostałem diff, którego sam baseline się
nie zgadzał.

## 6. Czy `mode=backup|sync` to polityka profilu?

**Nie. To własność relacji.** Argument z regeneracji, zgodnie z prośbą:

Zmiana profilu ma być bezpieczna w dowolnym momencie — to jest cały sens
presetu. Zmiana trybu zmienia **kierunek przepływu danych i przestrzeń nazw
celu**, czyli unieważnia istniejące snapshoty i cele. Gdyby `mode` siedział w
profilu, podmiana profilu mogłaby po cichu przewrócić relację z backup na sync:
zmiana topologii przebrana za zmianę polityki.

Drugi argument: dwóch klientów na jednym kolektorze może dzielić tę samą
politykę retencji przy różnych trybach. Wspólny profil byłby wtedy niemożliwy
bez rozszczepienia go na dwa identyczne poza jednym słowem.

## 7. Czy da się uniknąć trwałego pliku pośredniego?

**Tak**, i to już działa. `gen-cron.sh -c <plik>` przyjmuje dowolną ścieżkę, a
`--migrate-recursion` renderuje dziś z pliku tymczasowego i porównuje. Czyli
`show-config` może pisać kandydata do tempa, a `gen-cron` czytać ten sam temp.
Trwały zostaje wyłącznie config kanoniczny.

**Konkretna pułapka, na którą sam wpadłem dziś rano:** zainstalowany blok crona
niesie linię `# Source: <ścieżka>`. Render z tempa wpisuje tam **ścieżkę
tymczasową**. Przy migracji musiałem tę linię normalizować przed porównaniem, a
przy instalacji byłoby gorzej — blok w produkcyjnym crontabie wskazywałby plik,
którego już nie ma.

Wniosek: albo kandydat trafia atomowo pod ścieżkę kanoniczną **przed**
instalacją, albo `# Source:` musi nazywać ścieżkę kanoniczną niezależnie od
tego, skąd renderowano. Do rozstrzygnięcia przed Slice B, nie po.

## 8. Najmniejszy pierwszy plaster

**Slice B rozbity na dwa: B1 backup, B2 sync.**

Powód praktyczny: dowód bajtowej równości i tak jest osobny dla każdego
kształtu, a jeżeli ekstrakcja się nie uda, cofa się połowę zamiast całości.
Slice A zostawiam jak jest — fixture bez zmian w runtime jest tani i wymusza
uzgodnienie własności pól przed kodem.

---

## Do §13 — ścieżka ręczna

Zgoda bez zastrzeżeń, z jedną konsekwencją, którą warto dopisać: skoro ręczny
CONFIG v4 jest pełnoprawny, to `zfs-backup.sh` **nie może być wyłącznym
właścicielem pliku configu**. Uzgodniliśmy już wcześniej znaczniki własności
sekcji z sumą kontrolną (wątek „config ownership markers"). To jest dokładnie
mechanizm, którego wymaga punkt 6 z §13 — narzędzie nie może po cichu
przepisać sekcji pisanej ręcznie tylko dlatego, że istnieje profil.

Bez tych znaczników „fail closed" z §13.6 nie da się zrealizować, bo nic nie
odróżnia sekcji wygenerowanej od ręcznej.

## Do §14 — GUI na końcu

Zgoda. Jedna uwaga praktyczna do punktu 2 (wyjście maszynowe): nie dokładajmy
`--json` teraz. Dziś jedynym konsumentem jest człowiek i testy, a każdy format
wyjścia, który powstanie bez konsumenta, zastyga w złym kształcie. Punkt 8 noty
mówi to samo o HTTP API — proponuję rozciągnąć tę samą dyscyplinę na `--json`.

Co **warto** robić już teraz i co nic nie kosztuje: trzymać identyfikatory
(klient, relacja, profil) jawne i stabilne, oraz utrzymać rozdział
plan/preview od mutacji. Jedno i drugie już mamy.

---

## Czego nie podnoszę

Nie mam zastrzeżeń do §4 (własność faktów), §8 (wybór i trwałość profilu),
§10 (bezpieczeństwo profili własnych) ani §11 poza rozbiciem Slice B. Nie widzę
w nich niczego, co wymagałoby decyzji właściciela.
