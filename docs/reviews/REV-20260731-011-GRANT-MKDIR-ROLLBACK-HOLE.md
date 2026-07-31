# REV-20260731-011 — rollback grantu nadal ma lukę po instalacji helpera

- Reviewer: ChatGPT
- Data: 2026-07-31
- Zakres: `ad5e745`, `6894b06`, `cb34e99`
- Wynik: **REV-010 response accepted; REV-009 rollback direction accepted, one fail-path still blocks closure**

## 1. Co uznaję za zamknięte

### `sqlfreeze`

Akceptuję odpowiedź na REV-010:

- wycofano twierdzenie, że okno zdarzeń dowodzi konkretnego backupu;
- caveat jest emitowany razem z wynikiem;
- jawnie opisano granularity per-instance, brak expected-set i brak dowodu restore;
- live run pokazał praktycznie, że eventy pvesr mogą dać `engaged` bez przebiegu snapsend.

Pozostawienie per-run correlation do osobnego, atomowego rozszerzenia ścieżki `snapget -q` jest właściwe. Nie należy budować teraz osobnego pseudo-gate na dwóch niezależnych wywołaniach helpera.

### rollback istniejącego grantu

Kierunek w `ad5e745` jest poprawny:

- backup wszystkich istniejących destynacji przed pierwszym zapisem;
- `did_*` ustawiane przed próbą zapisu;
- restore w odwrotnej kolejności;
- atomowe przywracanie przez plik obok + rename;
- testy fault-injection na istniejącym grancie i porównanie hashy.

To zamyka główny błąd z REV-009 dla testowanych punktów awarii.

## 2. Pozostała luka: błąd tworzenia `allow_dir` nie uruchamia rollbacku

Po udanym:

```bash
did_helper=1
install ... "$src" "$dest"
```

kod próbuje utworzyć katalog whitelisty. Ścieżka błędu nadal wygląda jak:

```bash
mkdir ... "$allow_dir" || {
    warn "could not create $allow_dir ..."
    return 1
}
```

Nie ma tam `_grant_rollback`.

Skutek przy aktualizacji istniejącego grantu:

1. stary helper zostaje zachowany w backupie;
2. nowy helper zostaje już zapisany do wspólnej uprzywilejowanej ścieżki;
3. `mkdir` zawodzi;
4. funkcja wychodzi bez przywrócenia starego helpera;
5. zostają też backup/temp artefacts tej transakcji.

Na czystym hoście analogicznie może pozostać nowo zainstalowany helper mimo komunikatu „no quiesce grant was created”. Helper bez reguły jest inert, ale stan nie jest zgodny z deklaracją „host goes back to the state it was in before the run”. Dla helpera współdzielonego przez inne relacje jest to również niezamierzona aktualizacja po nieudanej operacji jednego konta.

## 3. Wymagana poprawka i test

Każde wyjście po ustawieniu któregokolwiek `did_*` musi przechodzić przez `_grant_rollback`.

Minimalnie:

```bash
mkdir ... "$allow_dir" || {
    _grant_rollback
    warn "could not create $allow_dir ..."
    return 1
}
```

Proszę dodać fault injection dokładnie w tym miejscu i udowodnić dwa przypadki:

1. **istniejący grant** — hash helpera, whitelisty i sudoers po błędzie identyczny jak przed próbą;
2. **czysty host** — brak helpera, whitelisty, sudoers oraz katalogu/backupów utworzonych przez nieudaną próbę.

Dobrze byłoby też dodać jeden mechaniczny guard testowy: po rozpoczęciu install phase nie może istnieć `return 1` poza wspólną ścieżką rollbacku. To ograniczy kolejne podobne luki przy rozbudowie funkcji.

## 4. Decyzja review

- odpowiedź `sqlfreeze` na REV-010: **zaakceptowana**;
- architektura backup/restore grantu z `ad5e745`: **zaakceptowana co do kierunku**;
- pełne zamknięcie REV-009: **wstrzymane do poprawienia ścieżki błędu `mkdir allow_dir` i dodania testu**;
- nie rozszerzać jeszcze privileged surface o per-run SQL correlation, dopóki ta transakcja nie będzie zamknięta.
