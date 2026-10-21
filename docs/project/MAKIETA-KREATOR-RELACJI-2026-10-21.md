# Makieta: nowy kreator relacji (tworzenie i zmiana) — do akceptacji

Decyzja właściciela 2026-10-21 (U66): „Do kompletnej przebudowy. Nielogiczne
i frustruje mnie to.” Obejmuje U54, U55, U57, U58, U59, U64, U65.

To jest **tylko makieta**. Nic nie jest zakodowane. Okna to whiptail, jak
dziś. Klawisze są na ramce, nie w treści okna.

## Zasady (siedem)

1. **Jeden krok = jedno pytanie.** W tytule: „Nowa relacja — krok 3 z 7”.
2. **Wstecz = poprzedni krok. Zawsze.** Odpowiedź zostaje zapamiętana. Esc
   działa jak Wstecz. „Przerwij” jest tylko w kroku 1 i w podsumowaniu.
3. **Kroki zależą od rodzaju.** Lustro nie pyta „dokąd”, migawki nie pytają
   o cel. Licznik „krok X z N” liczy tylko kroki tego rodzaju.
4. **Wszystko ma podpowiedź.** Nazwa = nazwa hosta, cel = `hdd/backups`,
   szablon = fabryczny. Enter idzie dalej z podpowiedzią.
5. **Szablony po ludzku.** „7 dni + 24 godziny”, nie `d7h24-age`. Kod
   szablonu jest drobnym drukiem.
6. **Ostatni krok = podsumowanie.** Enter na pozycji skacze do tego kroku,
   a po nim od razu wraca do podsumowania. Dopiero tam jest „Utwórz”.
7. **Po „Utwórz” okno postępu z krokami, nigdy czarny ekran.** Wszystko
   trafia do dziennika. Błąd mówi, który krok padł i co z tym zrobić.

**Zmiana relacji = ten sam kreator**, otwarty od razu na podsumowaniu, z
wypełnionymi odpowiedziami. To, czego nie da się zmienić (rodzaj, nazwa,
konto), stoi w nagłówku, a nie na liście do wyboru. Czynności takie jak
kopia teraz, pauza, eksport czy usuwanie nie są częścią zmiany i mają
własne menu (na końcu).

---

## Tworzenie — rodzaj „backup” (7 kroków)

### Krok 1 z 7 — rodzaj

```
┌──────────────── Nowa relacja — krok 1 z 7 ────────────────┐
│ Co ma robić ta relacja?                                    │
│                                                            │
│  (*) Backup         ten host pobiera kopie z innego hosta  │
│  ( ) Lustro         wierna kopia pod tą samą ścieżką       │
│  ( ) Kopia lokalna  kopia na tym samym hoście              │
│  ( ) Migawki tutaj  tylko migawki tego hosta, bez kopii    │
│  ( ) Migawki tam    migawki na innym hoście, bez kopii     │
│                                                            │
│          <Dalej>                    <Przerwij>             │
└────────────────────────────────────────────────────────────┘
```

### Krok 2 z 7 — skąd (adres) i sprawdzenie hosta

```
┌──────────────── Nowa relacja — krok 2 z 7 ────────────────┐
│ Z którego hosta pobierać kopie?                            │
│ IP albo nazwa, opcjonalnie :port                           │
│                                                            │
│ pve9______________________________________________         │
│                                                            │
│          <Dalej>                    <Wstecz>               │
└────────────────────────────────────────────────────────────┘
```

Po „Dalej” najpierw okno postępu (U55), a potem wynik (U56):

```
┌──────────── Sprawdzam host ────────────┐   ┌──────────── Host pve9 ─────────────────────┐
│ pve9 -> 192.168.28.99                  │   │ pve9 -> 192.168.28.99 (sieć lokalna)       │
│ łączę się przez ssh ... (do 10 s)      │   │  ssh        OK                             │
│                                        │   │  ZFS        OK, pule: hdd                  │
│                                        │   │  pakiet     OK                             │
└────────────────────────────────────────┘   │           <Dalej>          <Wstecz>        │
                                             └────────────────────────────────────────────┘
```

Gdy coś nie gra, okno mówi to wprost, a „Wstecz” pozwala poprawić adres:

```
│ pve9 -> 205.193.117.159 (ADRES PUBLICZNY, spoza sieci lokalnej!)          │
│  ssh        brak odpowiedzi po 10 s                                       │
│ Nazwa rozwiązała się na obcy adres. Wpisz IP albo dopisz pve9 do         │
│ /etc/hosts.                                                               │
```

### Krok 3 z 7 — co (datasety)

```
┌──────────────── Nowa relacja — krok 3 z 7 ────────────────┐
│ Które datasety z pve9 kopiować?   (spacja = zaznacz)       │
│                                                            │
│  [*] hdd/lab                 552M  (z podrzędnymi: 14)     │
│  [ ] hdd/data                 12M  (z podrzędnymi: 3)      │
│  [ ] hdd/archive              70M                          │
│                                                            │
│          <Dalej>                    <Wstecz>               │
└────────────────────────────────────────────────────────────┘
```

### Krok 4 z 7 — dokąd

```
┌──────────────── Nowa relacja — krok 4 z 7 ────────────────┐
│ Gdzie na tym hoście (pve10) trzymać kopie?                 │
│                                                            │
│  (*) hdd/backups      wolne 39G                            │
│  ( ) inny ...                                              │
│                                                            │
│ Kopie wylądują w: hdd/backups/192.168.28.99/hdd/lab        │
│          <Dalej>                    <Wstecz>               │
└────────────────────────────────────────────────────────────┘
```

### Krok 5 z 7 — jak często i jak długo (szablon, U54)

```
┌──────────────── Nowa relacja — krok 5 z 7 ────────────────┐
│ Jak często robić kopie i jak długo je trzymać?             │
│                                                            │
│  (*) Co godzinę, trzyma 24 godziny + 7 dni                 │
│  ( ) Co godzinę, trzyma 24 godziny + 30 dni                │
│  ( ) Raz na dobę, trzyma 30 dni                            │
│  ( ) Pełny: 24 godziny + 7 dni + 4 tygodnie + 12 miesięcy  │
│  ( ) Długi: ... + 5 lat                                    │
│  ( ) Moje szablony (1) ...                                 │
│                                                            │
│ Szablon: d7h24                                             │
│          <Dalej>                    <Wstecz>               │
└────────────────────────────────────────────────────────────┘
```

Wybór i Wstecz wracają do tej listy, a nie do formularza (U57). Warianty
szablonów (`-age`, `-gfs`) są w „Zaawansowane” w podsumowaniu, nie na tej
liście.

### Krok 6 z 7 — u źródła

```
┌──────────────── Nowa relacja — krok 6 z 7 ────────────────┐
│ Ile migawek zostawiać na pve9 (u źródła)?                  │
│                                                            │
│  (*) Tyle samo co w kopii                                  │
│  ( ) Mniej: 24 godziny + 3 dni   (oszczędza miejsce)       │
│  ( ) Inaczej ...                                           │
│          <Dalej>                    <Wstecz>               │
└────────────────────────────────────────────────────────────┘
```

### Krok 7 z 7 — nazwa (U58)

```
┌──────────────── Nowa relacja — krok 7 z 7 ────────────────┐
│ Nazwa relacji (widać ją w F3 i w alertach):                │
│                                                            │
│ pve9______________________________________________         │
│                                                            │
│          <Dalej>                    <Wstecz>               │
└────────────────────────────────────────────────────────────┘
```

### Podsumowanie

```
┌──────────────── Nowa relacja — podsumowanie ─────────────────────────┐
│ Sprawdź. Enter na pozycji = popraw ten krok.                          │
│                                                                       │
│   Rodzaj        backup -- pve10 pobiera z pve9                        │
│   Skąd          pve9 (192.168.28.99)   ssh, ZFS, pakiet: OK           │
│   Co            hdd/lab (z 14 podrzędnymi)                            │
│   Dokąd         hdd/backups/192.168.28.99/hdd/lab                     │
│   Kopie         co godzinę, 24 godziny + 7 dni                        │
│   U źródła      tyle samo co w kopii                                  │
│   Nazwa         pve9                                                  │
│   Zaawansowane  domyślne (konto, zamrażanie gości, silnik, ...)      │
│ ─────────────────────────────────────────────────────────────────     │
│   UTWÓRZ RELACJĘ                                                      │
│                                                                       │
│              <Wybierz>                       <Przerwij>               │
└───────────────────────────────────────────────────────────────────────┘
```

„Zaawansowane” otwiera jedno okno ze wszystkim, czego zwykły
administrator nie rusza. Każda pozycja ma tam opis po ludzku:

- konto na tym hoście (root albo osobne);
- zgoda na zamrażanie gości przy kopii;
- pomijane prefiksy migawek;
- silnik;
- limit pasma;
- wariant szablonu.

### Wykonanie (U55, U64)

```
┌──────────── Tworzę relację pve9 ────────────┐
│ [OK] konto i uprawnienia na pve9            │
│ [OK] klucz SSH i zaufanie hosta             │
│ [..] pierwsza pełna kopia hdd/lab (280M)    │
│ [  ] zadania crona                          │
│                                             │
│ Dziennik: /root/.zfs-tui/new-relation-...   │
└─────────────────────────────────────────────┘
```

Koniec: „Relacja pve9 działa. Następna kopia o 18:21.” Przy błędzie:
który krok, co znaczy, co zrobić. Stan jest czysty albo opisany.

---

## Inne rodzaje — które kroki odpadają

| rodzaj | kroki |
|---|---|
| Backup | rodzaj, skąd, co, dokąd, jak często, u źródła, nazwa (7) |
| Lustro | rodzaj, skąd, co, jak często (= u źródła), nazwa (5) — bez „dokąd”: ta sama ścieżka |
| Kopia lokalna | rodzaj, co, dokąd, jak często, nazwa (5) |
| Migawki tutaj | rodzaj, co, jak często, nazwa (4) |
| Migawki tam | rodzaj, skąd, co, jak często, nazwa (5) |

---

## Zmiana relacji (Enter na relacji w F3 → „Zmień ustawienia”)

```
┌──────────────── Zmiana relacji cb ──────────────────────────────────┐
│ Lustro z 192.168.28.96 · nazwa cb · konto root   (tego się nie      │
│ zmienia -- inaczej: nowa relacja)                                    │
│ Enter na pozycji = zmień. Zapis dopiero w ZAPISZ ZMIANY.             │
│                                                                      │
│   Adres         192.168.28.96:22                                     │
│   Co            hdd/lab                                              │
│   Kopie         co godzinę, 24 godziny + 7 dni                       │
│ * U źródła      tyle samo co w kopii -> 24 godziny + 3 dni [zmiana]  │
│   Zaawansowane  domyślne                                             │
│ ──────────────────────────────────────────────────────────────────   │
│   ZAPISZ ZMIANY (1)  -- najpierw plan do potwierdzenia               │
│                                                                      │
│              <Wybierz>                       <Wstecz>                │
└──────────────────────────────────────────────────────────────────────┘
```

Każda pozycja otwiera ten sam krok co przy tworzeniu (to samo okno, te same
słowa) i wraca tutaj. Zmieniona pozycja ma gwiazdkę i „[zmiana]”.
„Zapisz zmiany” pokazuje plan („co się stanie”), potem okno postępu jak
wyżej.

## Menu relacji (osobno od zmiany)

Enter na relacji w F3 daje panel szczegółów jak dziś, a pod nim czynności.
Te z klawiszem F są też na pasku:

```
   Zmień ustawienia          (kreator jak wyżej)
   Kopia teraz               F7
   Wstrzymaj / Wznów         F8
   Eksport / Import          F9
   Zapisz jako szablon
   Ręczna edycja konfigu     (dla zaawansowanych)
   Usuń relację              Del
```

---

## Do decyzji przy akceptacji

1. **Siedem kroków dla backupu.** Czy „u źródła” (krok 6) ma być osobnym
   krokiem, czy schować go w „Zaawansowane” z domyślnym „tyle samo co w
   kopii”? Proponuję osobny krok: od tego zależy miejsce na źródle.
2. **Konto (root / osobne).** Proponuję „Zaawansowane”, domyślnie tak jak
   dziś na tym hoście.
3. **Adres hosta** jest w zmianie na górze listy. Dziś to osobne okno
   „Adres hosta” — w nowym kreatorze to po prostu krok 2.
