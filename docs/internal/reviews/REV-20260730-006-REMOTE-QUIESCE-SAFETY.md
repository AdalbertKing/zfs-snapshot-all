# REV-20260730-006 — remote quiesce: safety contract is not yet fail-closed

- Reviewer: ChatGPT
- Data: 2026-07-30
- Zakres: `955cce0`, `6b61e0e`, `a02b8e2`, odpowiedź `cb27055`
- Wynik: **REV-005 SAFETY FIXES ACCEPTED; REMOTE QUIESCE CHANGES REQUIRED**

## 1. Co uznaję za zamknięte

Akceptuję odpowiedź na REV-005 w punktach:

- endpointy są walidowane przed zapisem i wszystkie wartości trafiają do pliku stanu przez `%q`;
- `snapget.sh -n` zwraca dodatni, maszynowy werdykt `PLAN=INCREMENTAL|FULL`, a wrapper fail-closed odrzuca wynik nieznany;
- `ACTIVE_ENDPOINT` i `INSTALLED_ENDPOINT` są rozdzielone, a stan `endpoint_change_pending` pokazuje operatorowi rozbieżność;
- poprawiono pozostający po normalnym przebiegu proces `sleep` deadmana.

To są właściwe poprawki i zamykają blokery F1/F2/F4 z REV-005.

## 2. BLOCKER: żądane quiesce może się nie udać, a snapshot i tak zostaje wykonany

Deklarowany kontrakt mówi, że `-q` ma nie dostarczać po cichu snapshotu crash-consistent. Obecna funkcja `freeze_one()` wypisuje `QERR`, lecz zwraca sukces i przebieg idzie dalej do atomowego `zfs snapshot`, między innymi gdy:

- `fsfreeze-freeze` nie powiedzie się;
- VM była już zamrożona;
- tryb nie pasuje do typu gościa;
- `pct exec ... sync` nie powiedzie się.

To oznacza, że operator wybierający application-consistent może dostać snapshot bez skutecznego quiesce przy kodzie wyjścia 0.

**Wymaganie:** zdalny skrypt musi zbierać wynik przygotowania każdego wykrytego gościa. Dla trybu `agent` każda uruchomiona VM należąca do zakresu, której nie udało się jednoznacznie zamrozić, musi zablokować snapshot. Dla `auto` należy jawnie zdefiniować semantykę, ale błąd zamrożenia wykrytej, uruchomionej VM również nie może zostać zredukowany do ostrzeżenia.

Przypadek „VM była już frozen” powinien zakończyć przebieg przed snapshotem i pozostawić VM nietkniętą; nie wolno przedstawiać takiego przebiegu jako poprawnego application-consistent backupu.

## 3. BLOCKER: brak `setsid` tylko ostrzega i kontynuuje

Kod deklaruje, że deadman jest podstawowym warunkiem bezpieczeństwa, ponieważ thaw ma przeżyć utratę połączenia. Mimo to przy braku `setsid` wypisywane jest tylko:

```text
running without the deadman safety net
```

a następnie goście mogą zostać zamrożeni.

To łamie główny kontrakt projektu.

**Wymaganie:** sprawdzenie obecności i możliwości uruchomienia deadmana musi nastąpić przed pierwszym freeze. Jeżeli bezpieczny, odłączony deadman nie może zostać uruchomiony, `-q` ma zakończyć się błędem bez zamrażania czegokolwiek.

## 4. BLOCKER: nieudany thaw usuwa stan potrzebny deadmanowi

`thaw_all()` po próbie odmrożenia wykonuje bezwarunkowo:

```bash
: > "$frozen_file"
```

Nawet jeśli `qm ... fsfreeze-thaw` zawiedzie. Skutek:

- trap może wypisać, że VM nadal jest zamrożona;
- plik zostaje wyczyszczony;
- deadman widzi pusty plik i nie podejmuje ponownej próby;
- proces może zakończyć się sukcesem.

To usuwa ostatnią automatyczną ścieżkę ratunkową dokładnie w przypadku, dla którego jest najbardziej potrzebna.

**Wymaganie:** z pliku wolno usuwać wyłącznie ID skutecznie odmrożone. Nieodmrożone ID muszą pozostać dla deadmana. Główny przebieg musi zwrócić błąd krytyczny, a komunikat ma zawierać dokładną komendę ręcznego thaw. Deadman powinien ponawiać próbę, a nie kończyć po jednej nieudanej operacji.

## 5. Wymagane testy błędów, nie tylko happy path

Live test prawidłowego freeze/snapshot/thaw i SIGKILL+deadman jest wartościowy, ale nie pokrywa powyższych gałęzi. Przed włączeniem `-q` do profilu standard wymagane są deterministyczne testy z atrapami `qm`/`pct`/`zfs`:

1. freeze zwraca błąd → `zfs snapshot` nie zostaje wywołany;
2. gość już frozen → snapshot nie zostaje wywołany;
3. brak `setsid` → nic nie zostaje zamrożone;
4. pierwszy thaw zawodzi → ID pozostaje w stanie deadmana, cały run jest błędem;
5. deadman ponawia thaw i usuwa ID dopiero po sukcesie;
6. snapshot zawodzi → trap skutecznie odmraża wszystkie goście;
7. wiele VM: częściowy freeze nie może pozostawić wcześniejszych VM zamrożonych ani wykonać snapshotu.

## 6. UX i model uprawnień

Obecna funkcja wymaga `--as=root`, dopóki nie powstanie ograniczony helper/sudo rule. To jest technicznie uczciwe, lecz nie spełnia jeszcze podstawowego UX „admina po uniwerku”: administrator nie powinien sam projektować reguły sudo ani wybierać między bezpieczeństwem klucza root i spójnością snapshotu.

Proszę nie włączać `-q` domyślnie do `standard`, dopóki nie istnieje jedna wspierana ścieżka wdrożenia uprawnień, najlepiej generowana przez `enroll/setup`, z czytelnym audytem dokładnego zakresu poleceń.

## 7. F3 z REV-005 — rekomendacja reviewerska

Dla LAN→VPN rekomenduję obowiązkowy `final-catchup` przed fizycznym odłączeniem LAN. Jest to mały koszt operacyjny, daje jednoznaczną wspólną bazę i ogranicza pierwszy transfer VPN. Workflow powinien jednak pozwalać pominąć go jawnie (`--skip-final-catchup`) z ostrzeżeniem, jeśli źródło zostało już odłączone.

## 8. Decyzja

- REV-005 F1/F2/F4: **CLOSED**.
- Remote quiesce engine: **CHANGES REQUIRED — nie włączać do profilu produkcyjnego**.
- Główne blokery: fail-open przy freeze, brak obowiązkowego deadmana oraz utrata stanu po nieudanym thaw.
- Po zamknięciu tych punktów potrzebna jest ponowna recenzja testów błędów i dopiero potem decyzja o integracji z `zfs-backup.sh`.
