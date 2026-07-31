# REV-20260731-010 — `sqlfreeze`: dobry sygnał diagnostyczny, ale jeszcze nie dowód konkretnego backupu

- Reviewer: ChatGPT
- Data: 2026-07-31
- Zakres: `c37ffcb`, `7dc4a98`, stan po `REV-20260731-009`
- Wynik: **DIAGNOSTIC IMPROVEMENT ACCEPTED; PROOF CLAIM CHANGES REQUIRED; REV-009 STILL OPEN**

## 1. Co akceptuję

Zmiana `writers` jest prawidłowa:

- parser nie zależy już od angielskich etykiet `vssadmin`;
- nie interpretuje stanu writera jako werdyktu poprawności backupu;
- nieczytelna odpowiedź daje `WRITERS-UNREADABLE`, zamiast pozornie zdrowego `total=0`;
- dopasowanie po numerze `VSS_WRITER_STATE` jest właściwsze niż po przetłumaczonym tekście.

Nowy `sqlfreeze` jest wartościowym narzędziem diagnostycznym. Numery eventów 3197/3198 są znacznie lepszym sygnałem niż stan writera po zakończeniu operacji, a walidacja okna i stała komenda ograniczają nową powierzchnię uprzywilejowaną.

## 2. Główna rozbieżność: okno czasowe nie koreluje zdarzeń z konkretnym backupem

Obecna implementacja odpowiada na pytanie:

> czy w ostatnich N sekundach SQL zanotował zbilansowane zdarzenia freeze/resume?

Nie odpowiada jeszcze na pytanie:

> czy **ten właśnie** snapshot/backup wywołał i objął ten freeze?

Na `vsql2` równolegle działają pvesr, snapsend i testy ręczne. Zdarzenia z wcześniejszej operacji mieszczące się w oknie mogą dać `verdict=engaged`, nawet jeśli aktualnie oceniany quiesce nie uruchomił SQL albo nie doszedł do snapshotu. Zbilansowane sumy z 20 godzin również nie dowodzą przyporządkowania każdej pary do każdego pojedynczego backupu.

Dlatego zdanie:

> „nightly backup IS application-consistent for SQL”

jest obecnie mocniejsze niż dowód.

### Wymagane zachowanie

`sqlfreeze` może pozostać ręcznym narzędziem z opisem:

```text
SQL participated in at least one VSS freeze/resume within the selected window.
This is not correlated to a specific snapshot run.
```

Jeżeli ma być używane jako dowód konkretnego joba, potrzebna jest korelacja w ramach jednej operacji, np.:

1. przed freeze zapisać najwyższy `EventRecordID` lub dokładny czas graniczny;
2. wykonać freeze → snapshot → thaw;
3. po thaw odczytać wyłącznie nowe eventy 3197/3198;
4. wymagać co najmniej jednej poprawnej pary dla oczekiwanych instancji/baz;
5. brak pary ma blokować deklarację `application-consistent`.

Najbezpieczniej wykonać to wewnątrz tego samego zdalnego przebiegu, aby obcy job nie mógł wypełnić okna pomiędzy niezależnymi wywołaniami.

## 3. `no-freeze-seen` nie może być sukcesem, gdy polecenie pełni funkcję proof gate

Dla ręcznej diagnostyki `no-freeze-seen` z rc=0 jest akceptowalne jako neutralny wynik. Jeśli jednak wrapper lub profil użyje `sqlfreeze` do potwierdzania application consistency, ten wynik musi być fail-closed i mieć niezerowy status.

Proszę rozdzielić semantykę:

- `sqlfreeze` jako raport: może zwrócić neutralne `no-freeze-seen`;
- przyszły `verify-sql-quiesce` / tryb `--require-engaged`: `engaged` albo błąd.

## 4. Grupowanie i oczekiwany zakres

Opis mówi „balanced pair per database”, ale prezentowany wynik agreguje liczniki per instancja. Proszę ujednolicić dokumentację z rzeczywistą granularnością i jawnie opisać:

- czy parsowane są bazy, instancje czy oba poziomy;
- czy jedna poprawna baza wystarcza do `engaged`;
- jak traktowane są bazy offline, restoring lub chwilowo niedostępne;
- czy lista oczekiwanych instancji jest znana przed operacją.

Bez tego `engaged` może oznaczać tylko „coś w SQL uczestniczyło”, a nie „cały zamierzony zakres został zamrożony”.

## 5. Nadal otwarty REV-009

Nie znalazłem odpowiedzi ani commita zamykającego `REV-20260731-009-GRANT-UPDATE-ROLLBACK.md`.

Nadal wymagany jest test ponownego enroll/update na **istniejącym działającym grancie**, z fault injection po nadpisaniu każdego z trzech artefaktów i porównaniem hashy przed/po:

- helper;
- whitelista konta;
- sudoers.

Rollback usuwający tylko pliki nowo utworzone nie jest transakcją dla aktualizacji istniejącego grantu.

Proszę najpierw zamknąć ten punkt przed dalszym rozszerzaniem powierzchni helpera.

## 6. Decyzja review

- lokalizacyjna i semantyczna poprawka `writers`: **ACCEPTED**;
- `sqlfreeze` jako ręczny raport diagnostyczny: **ACCEPTED WITH CAVEAT**;
- `sqlfreeze` jako dowód konkretnego backupu: **CHANGES REQUIRED**;
- twierdzenie, że konkretny nightly job jest dowiedziony jako application-consistent: **NOT YET SUPPORTED**;
- `REV-009` rollback aktualizacji grantu: **STILL OPEN**;
- nie włączać automatycznego werdyktu SQL do profilu `standard`, dopóki korelacja nie będzie związana z konkretnym przebiegiem.
