# Symulacja U38 -- widok migawek pary (2026-10-20)

Właściciel: „show-scope zrób -- tylko gdzie podpiąć i forma coś w stylu mc, ale z
widokiem migawek?”. **Nic nie jest zakodowane** -- to podgląd do decyzji.

## Gdzie

F3 Relacje -> Enter na relacji -> zakładka **Datasety** (dolny panel) -> **Enter na parze**
`źródło -> cel` otwiera okno migawek tej pary. Na F2 (Zadania) Enter na wierszu zadania
robi to samo dla jego datasetu.

Dziś Enter na parze otwiera tylko szczegóły pary; tamto okno zostaje pod F1 (Pomoc) albo
w prawym panelu -- bez zmian w reszcie ekranów.

## Jak wygląda -- dwa panele jak w mc

```
 zfs-snapshot-all            pve10 | relacja ab | para hdd/data
╔═ ŹRÓDŁO pve9b (10.98.0.2) hdd/data ═══════════════╗╔═ KOPIA pve10 hdd/backups/192.168.28.98/hdd/data ═╗
║   Migawka                     Czas    Wiek Rozm. ║║   Migawka                     Czas    Wiek Rozm. ║
║ ─────────────────────────────────────────────── ║║ ─────────────────────────────────────────────── ║
║   daily_2026-10-14_01-11     10-14 01:11  6d  2M ║║   daily_2026-10-12_01-11     10-12 01:11  8d  2M ║  <- tylko w kopii
║ = daily_2026-10-15_01-11     10-15 01:11  5d  2M ║║ = daily_2026-10-15_01-11     10-15 01:11  5d  2M ║
║   ...                                            ║║   ...                                            ║
║ = hourly_2026-10-20_17-17    10-20 17:17  1h  0B ║║ = hourly_2026-10-20_17-17    10-20 17:17  1h  0B ║  <- najnowsza wspólna = BAZA
║ > hourly_2026-10-20_18-17    10-20 18:17  0h  0B ║║                                                  ║  <- jeszcze nie skopiowana
║   [hold] hourly_2026-10-20_18-17  transfer w toku║║                                                  ║
╚══════════════════════════════════════════════════╝╚══════════════════════════════════════════════════╝
 Baza: hourly_2026-10-20_17-17 (zakładka: tak)   Źródło 52 / kopia 61 migawek   Kopia ma 9 starszych niż źródło
 ↑↓ ruch  Tab panel  Enter przeglądaj  Esc wstecz                                         (klawisze na ramce)
```

* **Wyrównane po migawce** (po GUID, nie po nazwie): ten sam wiersz po obu stronach = ta
  sama migawka. Znak w pierwszej kolumnie:
  * `=` jest po obu stronach; najnowsza taka to **baza** następnej kopii przyrostowej (w
    stopce, z informacją, czy jest zakładka -- awaryjna baza po U43);
  * `>` jest tylko u źródła -- jeszcze nie skopiowana;
  * puste po jednej stronie -- źródło już ją skasowało (kopia trzyma dłużej) albo odwrotnie.
* **Kolumny**: nazwa (bez wspólnego przedrostka `automated_`), czas utworzenia, wiek,
  rozmiar (`used` migawki -- ile zwolni jej usunięcie). `[hold]` = trwa transfer.
* **Szczeble** rozróżnia kolor nazwy (godzinowe / dobowe / tygodniowe...), bez osobnych list.
* **Enter na migawce kopii** = to, co już jest: Przeglądaj kopię (montaż tylko do odczytu +
  mc). Na migawce źródła -- informacja, że przegląda się kopię.
* **Nic nie usuwa i nic nie zmienia.** Żadnego Del. Okno jest do patrzenia; kasowanie robi
  retencja, a odzysk -- F11.

## Lustro, migawki, kopia lokalna

* Lustro: te same dwa panele (źródło i lustro); powinny być identyczne -- różnica od razu
  widać.
* Migawki lokalne / zdalne: jeden panel (nie ma kopii), te same kolumny.
* Kopia lokalna: dwa panele na tym samym hoście.

## Skąd dane

Nowy czytelnik (jak `show-scope`, tylko dla obu stron): migawki źródła po SSH kontem relacji,
migawki kopii lokalnie, połączone po GUID, jeden JSON. Czyta, nic nie pisze. `show-scope`
(dziś nieużywany przez GUI) albo zostaje jego podstawą, albo zostaje zastąpiony.

## Pytania do decyzji

1. Miejsce: Enter na parze w zakładce Datasety (F3) i na wierszu zadania (F2) -- tak?
2. Dwa panele obok siebie (mc), czy jedna lista z kolumnami „źródło | kopia”? Dwa panele
   wymagają szerszego terminala (od ~120 kolumn); przy węższym -- przełączanie Tab.
3. Pokazywać wszystkie szczeble razem (kolor), czy z filtrem szczebla (np. klawisz na ramce)?
