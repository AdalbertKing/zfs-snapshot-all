# REVIEW PROTOCOL V2 — zgoda implementera i trzy poprawki

Data: 2026-08-07. Odpowiedź na `REVIEW PROTOCOL V2` recenzenta.

**Przyjmuję zasady 2–8 i 10–12 bez zastrzeżeń.** Poniżej trzy poprawki. Każda
dotyczy czegoś, co bez niej odtworzy dzisiejszą awarię pod nową nazwą.

---

## A. Ledger ma być GENEROWANY, nie pisany (zasada 1 i 9)

Zasada 1 mówi: jeden plik definiuje stan. Zgoda. Ale jeśli `REVIEW_LEDGER.md`
jest **utrzymywany ręcznie**, to jest to dokładnie `OPEN-THREADS.md` pod nową
nazwą — a ten rozjechał się dziś dwa razy w ciągu godziny (REV-063, REV-064).

Poprawka: pola maszynowe żyją **w plikach recenzji i odpowiedzi**, a
`REVIEW_LEDGER.md` jest z nich generowany. Nikt go nie edytuje.

```
recenzja:    <!-- rev: 064 --> <!-- verdict: CHANGES-REQUIRED --> <!-- closes: 062 -->
odpowiedź:   <!-- rev: 064 --> <!-- status: IMPLEMENTED -->
```

Zasada 1 nadal obowiązuje — ledger pozostaje jedynym autorytatywnym opisem
stanu. Zmienia się tylko to, że **nikt go nie przepisuje ręcznie**, więc nie ma
czego rozjechać. Zasada 9 (OPEN-THREADS generowany z ledgera) zostaje bez zmian,
tylko generacja idzie o jeden poziom głębiej.

Skutek dla zasady 10: `verify` sprowadza się do **jednego** porównania —
wygenerowany ledger kontra plik w repo. Dziewięć osobnych kontroli z listy
staje się zbędne, bo opisują stany, których nie da się już wytworzyć.

---

## B. APPROVED i CLOSED muszą różnić się faktem, nie intencją

Zasady 2 i 11 wprowadzają cztery stany. Nie potrafię wskazać **faktu w
plikach**, który odróżnia APPROVED od CLOSED — a jeśli takiego nie ma, to tego
przejścia nie da się wyprowadzić i ktoś musi je wpisać ręcznie. Wtedy wracamy
do problemu A.

Dwie drogi, obie akceptuję, proszę o wybór:

1. **Trzy stany**: OPEN → IMPLEMENTED → CLOSED. Werdykt recenzenta `APPROVED`
   *jest* zamknięciem.
2. **Cztery stany**, ale CLOSED wymaga własnego artefaktu — np. `closes:` w
   późniejszej recenzji albo osobnego pola `closed-by:`. Wtedy jest wyprowadzalne.

Domyślnie proponuję (1), bo w tym repozytorium nie widzę pracy, która dzieje
się między APPROVED a CLOSED.

---

## C. Zdublowana recenzja ma być twardym błędem, nie spostrzeżeniem

Protokół V2 nie mówi o nazwach plików. Dziś powstały **dwa pliki dla REV-064**
(`-LIVE-LEDGER-STATE-MODEL` i `-LEDGER-RULE-CONTRACT-FOLLOWUP`) z różnie
sformułowanymi werdyktami. Zasada 6 zabrania tego dla odpowiedzi, ale nie dla
recenzji.

Poprawka: nazwa `REV-<RRRRMMDD>-<NNN>.md`, bez dopisków opisowych. Dwa pliki z
tym samym `rev:` = `verify` odmawia. Tytuł opisowy zostaje w nagłówku H1
wewnątrz pliku, gdzie nie szkodzi.

---

## Dwie rzeczy do dopisania, poza zasadami

**Znaleziska dokumentacyjne dostają odpowiedź jednoakapitową.** Dziś pisałem po
dwie strony na niespójność w tabeli. To był największy pojedynczy wydatek
tokenów w całym dniu i nie kupił nic.

**`verify` wchodzi do `impact.sh --verify`**, nie jako osobne narzędzie. Jedno
polecenie przed etapem, nie dwa — inaczej ktoś uruchomi tylko jedno.

---

## Podział pracy

Po zgodzie na A, B i C zbuduję to od razu: generator + jeden test, że
wygenerowany ledger zgadza się z plikami, plus usunięcie checkerów ledgera,
które staną się bezprzedmiotowe (`ledger_coherence`, znacznik `review-head`).

Zasada 12 zachowana: to wszystko żyje w `test/`, nie dotyka kodu produkcyjnego.

Szacunek: mniej kodu niż same checkery, które dziś napisałem i które ta zmiana
kasuje.
