# REV-20260730-003 — `zfs-backup.sh`: przegląd pierwszej implementacji uproszczonego deployu

- Reviewer: ChatGPT
- Data: 2026-07-30
- Zakres: commity `681c1a4`, `7ebfbf7`, `fe1492f`
- Kryterium nadrzędne: poprawne i bezpieczne wdrożenie przez kompetentnego administratora ogólnego, który zna Linux/SSH/ZFS, ale nie zna wnętrza projektu
- Status: **CHANGES REQUIRED — nie traktować obecnego workflow jako gotowego do wdrożenia**

## Podsumowanie

Kierunek jest właściwy: powstał osobny orkiestrator, nie ruszono publicznego interfejsu `deploy.sh`, dodano walidację przed instalacją i testy lokalnej logiki. Live test słusznie ujawnił dwa realne błędy (`keep=` oraz zastąpienie całego bloku cron z innego configu), a poprawki ograniczają ryzyko.

Obecna implementacja nadal jednak nie realizuje uzgodnionego UX LAN seed → VPN incremental i w kilku miejscach łamie ustalone wymagania bezpieczeństwa. Najważniejsze problemy są poniżej.

## F1 — BLOCKER: brak przypiętego host key nie może przechodzić do `accept-new`

W `activate-client` obecny kod robi:

```sh
[ -f "$knownhosts" ] && flags="$flags -k $knownhosts" || warn "no pinned host key ... -- job would fall back to accept-new"
```

To jest sprzeczne z uzgodnionym stanowiskiem. Nowy prosty proces ma wymagać jednego niezależnie zatwierdzonego fingerprintu i używać go dla wszystkich endpointów. Brak przypiętego klucza hosta ma być błędem blokującym, nie ostrzeżeniem.

**Wymagane:** `activate-client`, `test` i późniejsza aktywacja endpointu mają przerwać pracę, jeżeli dedykowany `known_hosts` nie istnieje albo nie zawiera oczekiwanego wpisu.

## F2 — BLOCKER: brak `HostKeyAlias`

Uzgodniony model wymaga stałej tożsamości hosta niezależnej od adresu LAN/VPN. Obecnie generowane `flags` zawierają `-K`, opcjonalnie `-k` i `-p`, ale nie zawierają:

```text
-O HostKeyAlias=zfs-client-<client_id>
```

Bez tego zmiana adresu LAN na VPN nadal jest dla OpenSSH zmianą nazwy hosta, a przypięcie jednego fingerprintu do trwałej relacji nie jest zrealizowane.

**Wymagane:** alias ma być generowany automatycznie, stabilny dla relacji i stosowany w `activate-client`, `test` oraz wygenerowanym cron jobie.

## F3 — BLOCKER UX/ARCHITEKTURA: brak faz `seed` i `VPN activation`

Obecny przepływ jest w praktyce:

```text
add-client → ręczny deploy.sh --join → activate-client → instalacja crona
```

Nie istnieją:

- rozróżnienie endpointu LAN i VPN;
- stan `seed` / `seed_complete`;
- jawny pełny seed przez LAN;
- finalny catch-up przed wyniesieniem pve1;
- zmiana aktywnego endpointu;
- test, że pierwszy transfer przez VPN będzie incremental;
- blokada instalacji crona przed pozytywnym testem VPN.

`activate-client` może zostać uruchomione jeszcze w LAN i od razu instaluje produkcyjny cron. To omija uzgodnione zabezpieczenie.

**Wymagane:** rozdzielić co najmniej:

```text
prepare/enroll → seed LAN → seed_complete → set/test VPN endpoint → activate schedule
```

Nazwy komend są drugorzędne. Istotna jest maszyna stanów i fail-closed: harmonogram nie może powstać przed potwierdzonym incremental po VPN.

## F4 — MAJOR UX: administrator nadal musi znać backend i datasety z góry

`add-client` wymaga:

```sh
--peer=HOST --datasets="A B"
```

Następnie komunikat instruuje użytkownika, aby na pve2 ręcznie uruchomił:

```sh
./deploy.sh --join=<package>
```

To nie jest jeszcze docelowy interfejs dla „admina po uniwerku”. Administrator nadal musi znać nazwę backendowego skryptu, tryb `--join` oraz ręcznie wpisać listę datasetów przed tym, zanim źródło je zatwierdzi i zanim pve1 je odkryje.

Uzgodniony kierunek był odwrotny: pve2 zatwierdza zakres, a pve1 po enroll pobiera dostępne datasety i buduje konfigurację.

**Wymagane:** prosty krok na pve2 powinien być przedstawiony jako komenda produktu, np. `zfs-backup enroll PACKAGE`, nawet jeżeli wewnętrznie wywołuje `deploy.sh --join`. Lista datasetów powinna być wybierana/akceptowana na pve2 albo odkrywana po enroll, a nie obowiązkowo ręcznie składana w pierwszej komendzie na pve1.

## F5 — BLOCKER: porównywanie wyłącznie basename pliku cron nie dowodzi, że to ten sam config

Naprawa po incydencie porównuje:

```sh
basename "$existing" = basename "$file"
```

Dwa różne pliki mogą mieć tę samą nazwę w różnych katalogach. Wtedy check przepuści instalację i nadal może zastąpić cały zarządzany blok cron zawartością innego pliku.

Przykład:

```text
/etc/zfs/jobs.conf
/root/test/jobs.conf
```

To nie są te same źródła mimo wspólnego basename.

**Wymagane:** porównywać kanoniczną ścieżkę (`readlink -f`) po rozwiązaniu ścieżki zapisanej w `# Source`, albo użyć jednoznacznego identyfikatora/config hash. Jeżeli istniejąca ścieżka jest względna i nie da się jej bezpiecznie rozwiązać, operacja ma odmówić instalacji i pokazać konkretną procedurę migracji.

## F6 — MAJOR: modyfikacja configu nie jest transakcyjna

`activate-client` dopisuje sekcje `[dataset:]` bezpośrednio do właściwego configu, a dopiero potem uruchamia walidację i dry-run. Gdy walidacja albo którykolwiek dataset zawiedzie, cron nie jest instalowany, ale config pozostaje zmieniony.

Analogicznie `remove-client` najpierw usuwa sekcje z configu, a dopiero potem wykonuje check źródła i `gen-cron.sh --install`. Jeżeli check lub instalacja zawiedzie, plik configu jest już zmieniony, a aktywny crontab pozostaje stary.

To tworzy rozjazd „plik prawdy vs stan aktywny” i utrudnia ponowienie operacji.

**Wymagane:** każdą zmianę budować na pliku tymczasowym:

1. skopiować aktualny config;
2. zmodyfikować kopię;
3. zwalidować ją;
4. wykonać dry-run;
5. pokazać diff/podsumowanie;
6. atomowo podmienić plik i zainstalować cron;
7. przy błędzie pozostawić pierwotny config i crontab bez zmian.

Dla `remove-client` potrzebny jest ten sam mechanizm oraz rollback pliku, jeśli instalacja crona nie powiedzie się.

## F7 — MAJOR UX: `status` pokazuje implementację zamiast stanu operacyjnego

`status NAME` wykonuje `cat` pliku shellowego. Użytkownik dostaje `CLIENT_NAME=`, `PEER_HOST=`, wielokrotne `STATE=` itd., zamiast odpowiedzi operacyjnej.

Docelowy status powinien pokazywać co najmniej:

```text
Klient
Stan relacji
Aktywny endpoint
Fingerprint/host key
Seed complete
Ostatnia wspólna baza
Czy kolejny transfer będzie incremental
Harmonogram aktywny/nieaktywny
Ostatni test i ostatni backup
```

To jest istotne dla prostoty: admin ma rozumieć stan, nie format wewnętrznego pliku.

## F8 — MAJOR: brak kontroli odziedziczonych `zfs allow`

Implementacja opakowuje istniejący pair/join, ale w nowym workflow nie widać jawnego raportu efektywnych i odziedziczonych grantów przed aktywacją. To było elementem uzgodnionego stanowiska po wcześniejszym incydencie z grantami na przodku.

**Wymagane:** przed komunikatem „udostępniono dataset” pokazać osobno grant tej relacji, grant istniejący oraz szerszy grant odziedziczony. Nie wolno sugerować izolacji per dataset, jeżeli konto już ma szerszy dostęp.

## F9 — MINOR, ale ważne dla utrzymania: komentarze i podsumowanie nadal mówią `keep=`, kod używa `retain=`

Nagłówek i ekran aktywacji nadal opisują profil jako `hourly keep=24, daily keep=14`, mimo że po poprawce config używa `retain=-H24/-D14`. Dla użytkownika można mówić „24 godzinowe / 14 dziennych”, ale komentarze implementacyjne powinny być zgodne z rzeczywistą składnią.

## Co jest dobre i należy zachować

- osobny plik `zfs-backup.sh`, bez rozszerzania `deploy.sh`;
- walidacja configu przed `--install`;
- jedna jawna akceptacja przed aktywacją;
- nieinstalowanie crona w pierwszym kroku;
- wykrycie i udokumentowanie realnego incydentu z jednym globalnym blokiem cron;
- testy idempotencji szablonów oraz usuwania sekcji;
- zachowanie istniejącego trybu eksperckiego jako backendu.

## Minimalny następny krok dla Claude

Proszę nie dodawać kolejnych profili ani kosmetyki przed zamknięciem F1–F6. Najpierw potrzebny jest projekt i test przepływu:

```text
setup-server
add-client / enroll bez ręcznego składania backendowych flag
seed po LAN bez crona
finalny incremental po LAN
jawna zmiana endpointu na VPN
HostKeyAlias + ten sam fingerprint
incremental test po VPN
atomowa instalacja configu i crona
```

Minimalny test end-to-end pozostaje:

```text
full LAN → incremental LAN → zmiana endpointu → incremental VPN
```

bez `-f`, bez nowego targetu, bez nowego job state i bez ponownego zaufania do host key.
