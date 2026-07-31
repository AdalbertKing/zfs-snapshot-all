# REV-20260731-012 — crash-safe pliki, ale kolejność aktualizacji może poszerzyć aktywny grant

- Reviewer: ChatGPT
- Zakres: `5fec1f4`, `50fe6cf`, `776ee42`, `9ab1440`
- Wynik: **CHANGES REQUIRED — aktualizacja istniejącego grantu nadal nie jest fail-closed**

## Co uznaję za zamknięte

Akceptuję:

- poprawkę ścieżki `install -d`, w tym usunięcie pustego katalogu utworzonego przed błędem;
- mechaniczny test, że każda zwykła ścieżka błędu instalacji uruchamia rollback;
- staging w katalogu docelowym i atomowe `rename(2)` zamiast zapisu uprzywilejowanych plików w miejscu;
- test `sudoers.d`, który rzeczywiście potwierdza, że nazwy zawierające kropkę są ignorowane przez używaną wersję `sudo`;
- testy `SIGKILL`, które sprawdzają brak plików częściowych.

To zamyka problem plików uciętych po `kill -9`, OOM lub utracie zasilania.

## Bloker: założenie „whitelist first = restriction” nie jest prawdziwe dla update

Commit zapisuje w kolejności:

1. nowa whitelista;
2. nowy helper;
3. nowa reguła sudoers.

Opis zakłada, że whitelista jest ograniczeniem i dlatego można ją przełączyć jako pierwszą. Dla **istniejącego aktywnego grantu** nowa lista może jednak być szersza, np. ponowny enroll dodaje dataset:

```text
stara whitelista: rpool/data/vm-106-disk-0
nowa whitelista:  rpool/data/vm-106-disk-0
                 rpool/data/vm-107-disk-0
```

Po pierwszym `rename` stara, nadal aktywna reguła sudoers i stary helper natychmiast czytają szerszą whitelistę. Jeżeli proces umrze przed kolejnymi rename, grant został **poszerzony**, mimo że transakcja nie doszła do końca.

Stwierdzenie „rule is last because it is the switch — until it lands nothing is granted” jest prawdziwe wyłącznie przy pierwszej instalacji. Przy aktualizacji finalna reguła sudoers już istnieje i jest aktywna przez cały commit.

To jest regresja względem deklarowanej gwarancji fail-closed i dotyczy dokładnie przypadku re-enroll/update, który otworzył REV-009.

## Wymagana poprawka

Najprostszy bezpieczny model dla aktualizacji istniejącego grantu:

1. atomowo wyłączyć aktywną regułę sudoers, np. przenieść ją na ignorowaną nazwę `.zqg-bak`;
2. przełączyć whitelistę;
3. przełączyć helper;
4. jako ostatni krok atomowo zainstalować nową finalną regułę sudoers.

Przerwanie w dowolnym miejscu daje wtedy brak dostępu, a nie szerszy dostęp. Chwilowa niedostępność podczas aktualizacji jest akceptowalnym fail-closed; niejawne rozszerzenie uprawnień nie jest.

Alternatywny projekt jest dopuszczalny, ale musi mechanicznie udowodnić, że przed ostatnim krokiem żadna aktywna reguła nie może użyć szerszej nowej whitelisty.

## Wymagane testy

Dodać test aktualizacji istniejącego aktywnego grantu, w którym nowa whitelista jest **szersza** od starej. Wymusić `SIGKILL`:

- po przełączeniu whitelisty;
- po przełączeniu helpera;
- przed instalacją finalnej reguły.

Po każdym przerwaniu test powinien sprawdzić nie tylko integralność plików, ale rzeczywistą efektywną granicę uprawnień: konto nie może wykonać helpera dla nowo dodanego datasetu, dopóki cały commit nie zakończy się sukcesem.

Dodatkowo warto zachować osobny test dla listy węższej, aby potwierdzić, że oba kierunki zmiany kończą się bezpiecznie.

## Decyzja review

- atomowość pojedynczych plików po crashu: **zaakceptowana**;
- cleanup i ponowne uruchomienie po przerwanym przebiegu: **zaakceptowane co do kierunku**;
- kolejność commitu pierwszej instalacji: **akceptowalna**;
- kolejność commitu aktualizacji istniejącego grantu: **zablokowana**, ponieważ może chwilowo lub trwale poszerzyć aktywne uprawnienia przed zakończeniem transakcji.

Nie włączać remote quiesce jako domyślnej funkcji profilu produkcyjnego do zamknięcia tego punktu.