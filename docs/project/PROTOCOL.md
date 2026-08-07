# Protokół komunikacji — właściciel / recenzent / implementer

Krótki celowo. Dłuższy protokół to kolejny dokument do rozjechania.

## Problem, który to zamyka

2026-08-07 cztery recenzje (059, 061-F2, 063, 064) dotyczyły wyłącznie naszej
buchalterii: nieaktualnego statusu, sprzecznego ledgera, reguły niezgodnej z
checkerem. Do tego dwie recenzje o tym samym ID pod dwiema nazwami plików.

Przyczyna: **stan koordynacji był prozą utrzymywaną ręcznie**, a checkery
pilnowały prozy. Poprawka to usunięcie ręcznej roboty, nie kolejny checker.

## Zasada

**Jedno źródło prawdy: pliki recenzji i odpowiedzi. Ledger jest generowany.**

Nikt nie edytuje tabeli wątków ręcznie. `OPEN-THREADS.md` powstaje z plików —
jeśli generacja i plik w repo się różnią, to błąd, a nie temat do dyskusji.

## Format — trzy pola, nic więcej

Każda recenzja zaczyna się blokiem HTML-owego komentarza:

```
<!-- rev: 064 -->
<!-- verdict: CHANGES-REQUIRED -->      # albo APPROVED
<!-- closes: 062,063 -->                # albo: closes: -
```

Każda odpowiedź implementera:

```
<!-- rev: 064 -->
<!-- status: IMPLEMENTED -->            # albo DISPUTED, NEEDS-DISCUSSION
```

Nazwa pliku: `REV-<RRRRMMDD>-<NNN>.md` i `responses/REV-<RRRRMMDD>-<NNN>.md`.
**Bez dopisków opisowych.** Dwa pliki z tym samym `rev:` to twardy błąd —
dokładnie tak powstały dziś dwie kopie REV-064.

## Stan wątku wynika z plików, nie z opinii

| jest recenzja | jest odpowiedź | zamknięta przez późniejszą recenzję | stan | czyj ruch |
|---|---|---|---|---|
| tak | nie | — | OPEN | implementer |
| tak | tak | nie | IMPLEMENTED | recenzent |
| tak | dowolnie | tak | CLOSED | — |

Nie ma innych stanów. Nie ma ręcznego przypisywania.

Wątki właściciela (decyzje, nie recenzje) to osobny, krótki plik
`docs/project/OWNER-DECISIONS.md` — tylko to, na co czeka właściciel, jedna
linia na pozycję. Nic tam nie wchodzi automatycznie.

## Co przestajemy robić

- **Pełny plik odpowiedzi dla znalezisk dokumentacyjnych.** Znalezisko, które
  nie zmienia kodu, dostaje odpowiedź jednoakapitową. Dziś pisałem po dwie
  strony na literówkę w tabeli.
- **Ręczna edycja ledgera.** Zniknęła cała klasa błędów, o które poszły
  REV-063 i REV-064.
- **Recenzje o recenzjach.** Jeśli werdykt dotyczy wyłącznie naszego procesu,
  a nie kodu ani produkcji, idzie jako jedna linia w `PROTOCOL-NOTES`, nie
  jako REV z pełną obsługą.

## Co zostaje bez zmian

Wszystko, co dotyczy kodu i produkcji: kontrakt przed implementacją, kontrole
negatywne z obiema liczbami, dowód na żywym hoście jako konto delegowane,
`impact.sh` i graf zależności. To działa i nie jest przedmiotem tej zmiany.

## Do uzgodnienia z recenzentem

1. Zgoda na blok trzech pól i sztywną nazwę pliku.
2. Zgoda, że ledger jest generowany i nikt go nie edytuje.
3. Zgoda, że znaleziska procesowe nie dostają pełnej obsługi REV.

Po zgodzie: generator + jeden test, że wygenerowany ledger zgadza się z plikami.
Reszta checkerów ledgera znika — nie będzie czego pilnować.
