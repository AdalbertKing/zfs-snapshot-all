# PROJECT_STATUS — uzgodniony stan projektu

- Data uzgodnienia: 2026-07-30
- Repozytorium: `AdalbertKing/zfs-snapshot-all`
- Uzgodniony punkt bazowy `main`: `388a78e0eb66bfdae2eaef1a70f81ba7c2516059`
- Tryb pracy: tymczasowo bezpośrednio do `main`, decyzją właściciela
- Status ogólny: **GOTOWY DO DALSZEGO ROZWOJU — brak otwartych blockerów**

## 1. Stan produkcyjny

Pakiet jest operacyjnie zaakceptowany na czterech żywych hostach testowych:

- pve0 — 192.168.11.10
- pve1 — 192.168.11.11
- metropolis pve1 — 192.168.28.9
- metropolis pve2 — 192.168.28.8

Ostatni zapisany test live po zmianach testowych:

```text
selfupdate: PASS=35 FAIL=0 SKIP=0 — na każdym z czterech hostów
```

Na koniec weryfikacji hosty były zgłoszone jako:

- czysty checkout;
- brak aktywnego `update-hold`;
- dokładnie jedna aktualna linia automatycznej aktualizacji;
- brak ubocznych zmian w crontabie.

Commit `388a78e` dodaje tylko dokument odpowiedzi. Ostatnia późniejsza od akceptacji zmiana wykonywalna dotyczy wyłącznie testu `test/selfupdate/run.sh` (`b8c22b4`), nie zachowania produkcyjnego.

## 2. Zaakceptowane funkcje pakietu

Rdzeń jest przyjęty jako działający i nadający się do dalszego rozwijania:

- tworzenie snapshotów ZFS;
- replikacja push i pull, lokalnie i przez SSH;
- replikacja zwykła, rekurencyjna i rozwijana per dataset;
- dopasowanie baz incremental po nazwie, GUID i bookmarku;
- wznawianie przerwanych transferów;
- ochrona snapshotów w locie przez `zfs hold`;
- kompresja, limit pasma i autotuning łącza;
- quiesce VM/CT Proxmox;
- retencja wiekowa, liczbowa i GFS;
- usuwanie osieroconych bookmarków;
- monitoring wieku snapshotów i stanu pul;
- generowanie zadań z konfiguracji INI przez `gen-cron.sh`;
- praca jako root oraz przez delegowane konta ZFS;
- bootstrap/audyt hosta przez `deploy.sh`;
- bezpieczne `--pair`, `--join`, rotacja, odwołanie klucza i `--unpair`;
- zewnętrzny, trwały kontroler aktualizacji i rollbacku.

Aktualne wersje głównych programów:

| Program | Wersja |
|---|---:|
| `snapsend.sh` | `v2.68` |
| `snapget.sh` | `v2.64` |
| `delsnaps.sh` | `v1.28` |
| `check-snap-age.sh` | `v2.0` |
| `gen-cron.sh` | `v4.25` |

## 3. Aktualizacja i rollback

Blockery związane z trwałym rollbackiem są zamknięte.

Kontroler:

```text
/root/.zfs-snapshot-all-update-state/update-control.sh
```

jest instalowany poza checkoutem Git. Cofnięcie repozytorium nie cofa więc kodu egzekwującego hold. Cron wywołuje zewnętrzny kontroler bezpośrednio.

`emergency_disable()` działa fail-closed: gdy nie można zapisać holda, próbuje wyłączyć sam wrapper, a następnie usunąć jego dokładną linię cron.

### Obowiązkowa zasada wydania

Zmiana `update-control.sh` wymaga po pobraniu kodu wykonania na każdym hoście pełnego:

```sh
bash /root/scripts/zfs-snapshot-all/deploy.sh
```

Sam godzinny self-update aktualizuje checkout, ale celowo nie nadpisuje kontrolera, który właśnie działa poza repozytorium.

## 4. Otwarte ryzyko i dług testowy

Nie ma otwartego P0/P1 ani blockera wydania.

Pozostaje zaakceptowany P2 test debt:

- nie skonstruowano deterministycznego testu łączącego nieudaną aktualizację po `--resume-updates` z jednoczesną awarią ponownego zapisania holda;
- nie każdy caller wspólnych prymitywów state/hold jest fault-injectowany jako osobny scenariusz.

Awaria samego atomowego `rename`, odseparowana od awarii `mktemp`/write, została już dodana jako case 20 i przeszła live `35/35` na wszystkich hostach.

Dług należy ponownie otworzyć dopiero przy materialnej zmianie któregokolwiek z:

- `write_state_file()`;
- `remove_state_file()`;
- `emergency_disable()`;
- `do_self_update()`;
- `do_rollback()`;
- `do_resume_updates()`.

## 5. Świadomie niezaimplementowane kierunki

Nie należy mylić dokumentu projektowego z gotowym kodem:

- `PAIRING-DESIGN.md` — **Wariant B**, czyli inicjacja z pve1 i półautomatyczny zwrot paczki, pozostaje propozycją;
- pełna automatyczna instalacja wygenerowanego draft-configu bez przeglądu administratora pozostaje odłożona;
- decyzja, czy utrzymywać dwa warianty inicjatora parowania, nie została podjęta.

Dotychczasowy, zaimplementowany proces parowania pozostaje obowiązującym zachowaniem.

## 6. Uzgodniony workflow dalszych prac

1. Właściciel wskazuje następny problem lub etap funkcjonalny.
2. Claude implementuje i testuje, obecnie bezpośrednio w `main` zgodnie z wyjątkiem właściciela.
3. Każda materialna zmiana ma mieć osobny, czytelny commit i dowody testów.
4. ChatGPT wykonuje niezależną recenzję kodu, testów i skutków operacyjnych.
5. Zamkniętych ustaleń nie otwieramy ponownie bez nowego dowodu regresji albo zmiany założeń.
6. Testy na żywych hostach muszą używać sandboxów/throwaway state i porównania before/after wszędzie, gdzie mogą dotknąć crona, uprawnień albo prawdziwych datasetów.

## 7. Punkt startowy następnego etapu

Dalsze prace zaczynają się od `main` na `388a78e` lub nowszym potomku tego commita, przy założeniu:

- brak otwartych blockerów;
- rdzeń backupu i retencji jest zaakceptowany;
- kontroler rollbacku jest zaakceptowany;
- jedyny znany dług ma rangę P2 i nie blokuje nowych funkcji;
- `PAIRING-DESIGN.md` Wariant B nie jest jeszcze decyzją implementacyjną.
