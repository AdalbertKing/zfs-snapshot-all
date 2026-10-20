# Symulacja U25 -- jedno okno tworzenia i zmiany relacji (2026-10-19)

Uwaga właściciela 10-19: „gdy tworzę relację i modyfikuję -- okno ma być to samo i mieć identyczną
funkcjonalność. Scal te dwie czynności. Tworzenie nowej relacji jest o niebo lepsze niż potem jej modyfikacja.”

**Nic nie jest zakodowane.** To tylko podgląd ekranów do decyzji.

## Pomysł w jednym zdaniu

Jedno okno: **karta relacji**, czyli lista pól z wartościami. Ins otwiera kartę pustą, a „e” otwiera tę samą
kartę z wypełnionymi polami. Każde pole otwiera to samo okno co dziś w kreatorze (drzewo datasetów, lista
szablonów, tabela szczebli, okno silnika, adres) i po wyborze wraca na kartę. Zapis jest jeden, na dole karty:
plan wszystkich zmian i jedno WYKONAJ.

Różnice między „nowa” i „zmiana” są tylko trzy:

1. **Nowa relacja**: pierwsze puste pole otwiera się samo, więc Enter, Enter, Enter prowadzi jak dziś kreator.
   Wstecz w oknie pola wraca na kartę, nie do poprzedniego kroku.
2. **Zmiana relacji**: niektóre pola są **stałe**. Rodzaj, nazwa, cel i konto są wpisane w kopie, cron i
   rekord. Ich zmiana to nowa relacja. Takie pole jest szare i ma dopisek „(stałe)”, a Enter na nim mówi dlaczego.
3. **Zapis**: dla nowej relacji uruchamia polecenie kreatora (jedno, jak dziś). Dla zmiany uruchamia czasowniki
   zmian po kolei, jak dziś w „Zapisz zmiany”.

## Ekran 1 -- Ins (nowa relacja), zaraz po otwarciu

Otwarte samo pierwsze pole „Rodzaj” (to samo okno co dziś krok 1). Po wyborze „Backup” karta wygląda tak:

```
 Nowa relacja -- kolektor pve10
 ┌──────────────────────────────── Relacja (nowa) ─────────────────────────────────┐
 │                                                                                  │
 │   Rodzaj          backup -- ten host pobiera ze źródła                           │
 │ > Źródło          …                                                              │
 │   Datasety        …                                                              │
 │   Cel             …                                                              │
 │   Harmonogram     …        (szablon albo tabela szczebli)                        │
 │   Retencja źródła …                                                              │
 │   Silnik          fabryczne (historia: wszystkie, kompresja zstd)                │
 │   Nazwa           …                                                              │
 │   Konto           root                                                           │
 │   Dodatkowe       prawa stąd, zgoda na zamrażanie, pomijane: __replicate_ …       │
 │   ─────────────────────────────────────────                                      │
 │   Utwórz relację -- plan, WYKONAJ          (brak: źródło, datasety, cel, nazwa)  │
 │                                                                                  │
 ├──────────────────────────────────────────────────────────────────────────────────┤
 │                       <Wybierz>                    <Wyjdź>                        │
 └──────────────────────────────────────────────────────────────────────────────────┘
```

Kursor stoi na pierwszym pustym polu, a jego okno otwiera się od razu: „Źródło” to adres i sprawdzenie hosta,
jak dziś kroki 2-3. Po każdym polu karta wraca z kursorem na następnym pustym. Kto chce, przeskakuje
strzałkami i poprawia dowolne pole bez cofania się po krokach.

## Ekran 2 -- Ins, wszystko wypełnione

```
 Nowa relacja -- kolektor pve10
 ┌──────────────────────────────── Relacja (nowa) ─────────────────────────────────┐
 │                                                                                  │
 │   Rodzaj          backup -- ten host pobiera ze źródła                           │
 │   Źródło          192.168.28.98 (pve9b) -- SSH, ZFS, pakiet: OK                  │
 │   Datasety        3: hdd/data, hdd/db, hdd/home                                  │
 │   Cel             hdd/backups  -> hdd/backups/192.168.28.98/…                    │
 │   Harmonogram     d7h24 -- co godzinę, dobę; trzyma 24 godz., 7 dni              │
 │   Retencja źródła godzinowe 24, dobowe 3                                         │
 │   Silnik          fabryczne                                                      │
 │   Nazwa           ab                                                             │
 │   Konto           root                                                           │
 │   Dodatkowe       prawa stąd, zgoda na zamrażanie, pomijane: 3 prefiksy           │
 │   ─────────────────────────────────────────                                      │
 │ > Utwórz relację -- plan, WYKONAJ                                                │
 │                                                                                  │
 ├──────────────────────────────────────────────────────────────────────────────────┤
 │                       <Wybierz>                    <Wyjdź>                        │
 └──────────────────────────────────────────────────────────────────────────────────┘
```

„Utwórz relację” otwiera plan (ten sam co dziś krok 10). Enter na planie to WYKONAJ.

## Ekran 3 -- „e” na istniejącej relacji: TA SAMA karta

```
 Zmiana relacji ab -- kolektor pve10
 ┌──────────────────────────────── Relacja ab ─────────────────────────────────────┐
 │                                                                                  │
 │   Rodzaj          backup                                       (stałe)           │
 │ > Źródło          192.168.28.98 -> 10.98.0.2 [zmiana]                            │
 │   Datasety        3  [zmiana] +hdd/vms -hdd/db                                   │
 │   Cel             hdd/backups                                  (stałe)           │
 │   Harmonogram     d7h24 -- trzyma 24 godz., 7 dni                                │
 │   Retencja źródła godzinowe 24, dobowe 3                                         │
 │   Silnik          historia: tylko różnica  [zmiana]                              │
 │   Nazwa           ab                                           (stałe)           │
 │   Konto           root                                         (stałe)           │
 │   Dodatkowe       pomijane: 3 prefiksy                                           │
 │   ─────────────────────────────────────────                                      │
 │   Zapisz zmiany (3) -- plan, WYKONAJ                                             │
 │   Ręczna edycja konfigu (jak crontab -e) -- od razu, osobno                      │
 │   Zapisz ustawienia relacji jako szablon (F5)                                    │
 │                                                                                  │
 ├──────────────────────────────────────────────────────────────────────────────────┤
 │                       <Wybierz>                    <Wstecz>                       │
 └──────────────────────────────────────────────────────────────────────────────────┘
```

* **Źródło** przy zmianie to dzisiejsze „Adres hosta”: to samo pole co przy tworzeniu, z tym samym
  sprawdzeniem hosta (SSH, ZFS, pakiet). Przy zmianie dochodzi warunek, że to ten sam host.
* **Harmonogram** to jedno pole zamiast dwóch dzisiejszych pozycji („Szablon” i „Harmonogram i retencja”).
  Otwiera listę szablonów z pozycją „Ręcznie…” (tabela szczebli) na górze, dokładnie jak krok 6 kreatora.
* **Retencja źródła** to osobne pole w obu trybach, czyli to samo okno-tabela co dziś.
* **Dodatkowe** przy zmianie pokazuje tylko to, co da się zmienić bez zakładania od nowa: pomijane prefiksy.
  „Prawa stąd” i „zgoda na zamrażanie” dotyczą tylko zakładania, więc przy zmianie ich nie ma.
* Enter na polu „(stałe)”:

```
 ┌────────────────────── Cel -- stałe ──────────────────────┐
 │ Cel hdd/backups jest wpisany w ścieżki kopii, cron        │
 │ i rekord relacji. Inny cel = nowa relacja:                │
 │ F9 Eksport, Del, Ins z nowym celem (kopie zostają).       │
 │                           <Ok>                            │
 └───────────────────────────────────────────────────────────┘
```

## Lustro i pozostałe rodzaje: ta sama karta, mniej pól

| pole            | backup | lustro              | kopia lokalna | migawki lokalne | migawki zdalne |
|-----------------|--------|---------------------|---------------|-----------------|----------------|
| Źródło          | tak    | tak                 | --            | --              | tak            |
| Datasety        | tak    | tak                 | tak           | tak             | tak            |
| Cel             | tak    | -- (ta sama ścieżka)| tak           | --              | --             |
| Harmonogram     | tak    | tak (*)             | tak           | tak             | tak            |
| Retencja źródła | tak    | -- (*)              | tak           | --              | --             |
| Silnik          | tak    | bez „Historia”      | tylko historia| --              | --             |

(*) Lustro trzyma to samo co źródło (U32). Dlatego ma jedno pole „Harmonogram i retencja”, które dotyczy
źródła, a nie dwa okna „tutaj / u źródła”.

## Co znika

* Numeracja „Krok 4/10”: karta pokazuje wszystko naraz, więc numer nic nie mówi.
* Cofanie się „Wstecz” krok po kroku przez kreator: wraca się na kartę i wybiera pole.
* Osobne pozycje „Szablon” i „Harmonogram i retencja” w oknie zmiany (jedno pole jak w kreatorze).
* „Adres hosta -- po przeniesieniu kolektora”: to jest teraz pole „Źródło”.

## Pytania do decyzji

1. Czy przy nowej relacji pola mają się otwierać same jedno po drugim (Enter, Enter… jak kreator)? Druga
   możliwość: karta czeka, aż wybierzesz pole.
2. Czy „Harmonogram” to ma być jedno pole (szablon albo tabela), jak na ekranie 3?
3. Czy „stałe” pola mają być widoczne na szaro z wyjaśnieniem? Druga możliwość: w ogóle ich nie pokazywać.
