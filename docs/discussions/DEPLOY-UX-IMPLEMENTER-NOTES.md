# Uwagi implementera do dyskusji o uproszczonym deploy UX

- Autor: Claude (implementer)
- Data: 2026-07-30
- Status: **DYSKUSJA — odpowiedź na `DEPLOY-UX-SNAPGET-FIRST.md`, `DEPLOY-UX-LAN-SEED-TO-VPN.md`,
  `DEPLOY-UX-FINGERPRINT-TRUST.md` i `PROJECT_STATUS.md` §5. Nie zatwierdza żadnej nazwy komendy,
  formatu pliku ani decyzji architektonicznej.**

Zgadzam się z kierunkiem bazowym wszystkich trzech dokumentów: pve1 jako appliance zarządzający,
pve2 jako czyste źródło danych, `snapget.sh` jako domyślny silnik, stała tożsamość relacji
niezależna od adresu. Poniżej to, co mogę dodać z perspektywy kodu, który już istnieje — co jest
już gotowe do użycia bez zmian silnika, co koliduje z pułapkami już raz znalezionymi na żywo, i
gdzie widzę ryzyko sekwencjonowania pracy zaraz po zamknięciu REV-20260730-001/002.

## 1. Co z proponowanego modelu działa DZIŚ, bez zmiany silnika

Warto to nazwać wprost, żeby dyskusja o nowej warstwie orkiestracji nie zakładała pracy, która już
jest zrobiona:

- **`HostKeyAlias` (DEPLOY-UX-FINGERPRINT-TRUST §3, DEPLOY-UX-LAN-SEED §4)** — `snapget.sh`/
  `snapsend.sh` mają już `-O <opcja>` (`snapget.sh:1272`, `snapsend.sh:1477`), które trafia prosto
  do `ssh -o <opcja>`. `-O HostKeyAlias=zfs-client-pve2 -k /etc/zfs-snapshot-all/clients/pve2/known_hosts`
  działa **już teraz**, bez żadnej zmiany w silniku. `gen-cron.sh`'s `ssh_flags` już akceptuje `-O`
  w swojej allow-liście (`gen-cron.sh:511`), więc to nawet już przechodzi przez generator configu.
  To, czego brakuje, to warstwa orkiestracji, która to *generuje* automatycznie — nie nowa
  funkcjonalność w silniku.
- **Tożsamość joba jest już niezależna od hosta (DEPLOY-UX-LAN-SEED §6)** — potwierdzone w kodzie:
  `lib-zfs-snap.sh:114` `job_state_key()` liczy hash z `$(basename "$0")` + `IDENTIFIER` + `src` +
  `tgt`, **bez** `remote_host`. Lock, resume-attempts i in-flight-hold plik idą przez ten sam klucz
  (`lib-zfs-snap.sh:131,265`). Twierdzenie z dokumentu jest więc nie tylko słuszne koncepcyjnie —
  jest już zweryfikowane w kodzie. Nadal zgadzam się, że wart jest osobny test regresyjny
  LAN→VPN (§6 minimalny test akceptacyjny) — to potwierdza *zachowanie end-to-end*, nie tylko klucz
  hasha.
- **Brak montowania po stronie odbiorczej, kompresja domyślna, `-R` per-dataset** (DEPLOY-UX-SNAPGET-FIRST §6)
  — wszystkie trzy już domyślne w `snapget.sh` od dawna ([[project-nomount-default]],
  [[project-remote-compression-default]], [[project-flat-recursive-mode]] w pamięci projektu).
  Dokument to poprawnie zakłada; potwierdzam, że nic tu nie trzeba zmieniać w silniku.

## 2. Gdzie proponowany model dotyka pułapek już raz znalezionych na żywo

- **Dziedziczenie `zfs allow` (PAIRING-DESIGN.md, sekcja `--unpair`)** — `enroll`/`activate-client`
  w DEPLOY-UX-SNAPGET-FIRST §5 krok 3-4 nadaje `zfs allow` na wybranych datasetach. Już raz znaleziono
  na żywo (pve1↔pve2), że odwołanie grantu **nie znaczy** utraty dostępu, jeśli konto ma wcześniejszy,
  odziedziczony grant na przodku (`Local+Descendent`). Ten sam mechanizm działa w drugą stronę przy
  **nadawaniu**: jeśli konto `zfsbackup-pve1` na pve2 już ma grant na przodku z innej, niepowiązanej
  relacji, `enroll` może zgłosić "nadano dostęp do rpool/data" niepoprawnie sugerując, że dopiero
  teraz account coś zyskał, skoro efektywnie już miał szerszy dostęp. Rekomendacja: `activate-client`/
  `enroll` powinien sprawdzać i raportować odziedziczone granty PRZED nadaniem nowych, dokładnie tak
  jak `--unpair` już to robi przy odbieraniu.
- **`--draft-config` vs "pve1 sam odkrywa dostępne datasety" (DEPLOY-UX-SNAPGET-FIRST §4, zgodne z
  odrzuceniem Wariantu B poniżej)** — dokładnie ten mechanizm już istnieje (`--draft-config` po
  `--join`, PAIRING-DESIGN.md "Draft-config"), tylko po stronie kolektora, nie źródła. Nowa warstwa
  orkiestracji może to opakować bez zmiany logiki: `activate-client` = dzisiejszy `--draft-config`
  plus `snapget.sh -n` plus jedno potwierdzenie, zamiast trzech osobnych ręcznych kroków.
- **Puste/awaryjne `-X`/wykluczenia kończą się `exit 1` (istniejące zachowanie [[project-exclude-and-skip-parent]])**
  — jeśli nowa warstwa domyślnie odznacza część wykrytych datasetów w kroku "enroll" (checklist z
  §5 przykładu), a użytkownik odznaczy WSZYSTKIE, wynikowe wywołanie musi to rozpoznać jako "nic do
  zrobienia, nie instaluj joba" a nie przepuszczać pusty wynik do silnika, który już dziś kończy się
  `exit 1` na pustym rezultacie filtra.

## 3. Konsekwencja dla `PAIRING-DESIGN.md` — Wariant B

DEPLOY-UX-SNAPGET-FIRST §4 argumentuje wprost przeciwko modelowi, w którym pve2 buduje finalny
config (dokładnie to, co Wariant B proponował) — z tego samego powodu, dla którego ja się wtedy
wahałem: pve2 nie zna polityki pve1 (retencja, harmonogram, limity). To odpowiada na pytanie
otwarte w PAIRING-DESIGN.md „Otwarte tematy": **rekomenduję oznaczenie Wariantu B jako
superseded-by-discussion** (nie kasować — to wciąż użyteczny zapis, dlaczego ten kierunek był
rozważany i dlaczego odrzucony), na rzecz modelu z DEPLOY-UX-SNAPGET-FIRST: klucz i inicjatywa
zostają po stronie pve1 (bez zmian względem Części 1-4), ale ręczne kroki są opakowane w
`activate-client`, które **automatyzuje to, co dziś jest ręczne odczytanie draft-configu**, nie
przenosi decyzji na pve2.

## 4. Sekwencjonowanie pracy — uwaga praktyczna

`REV-20260730-002` właśnie zamknęło durable-rollback na czterech żywych hostach z zerową tolerancją
na regresję w `deploy.sh`. Rekomendacja: nowa warstwa orkiestracji (`zfs-backup` czy jak się
ostatecznie nazwie) powstaje jako **osobny, nowy plik**, który *wywołuje* `deploy.sh`/`snapget.sh`/
`gen-cron.sh` jako biblioteki/podprocesy, a nie jako zmiana w publicznym interfejsie samego
`deploy.sh`. To jest zgodne z punktem 8 DEPLOY-UX-SNAPGET-FIRST ("może to być nowy wrapper") i
minimalizuje ryzyko dotknięcia właśnie zweryfikowanego kodu self-update/rollback. Każdy nowy plik
wymaga wpisu w `test/deps.conf` (impact.sh odmawia nieopisanego pliku) — warto to założyć od
pierwszego commita, nie doklejać później.

## 5. Odpowiedzi na wybrane "Decyzje do dalszej dyskusji"

- **DEPLOY-UX-SNAPGET-FIRST §12.1 (czy pve1 sam odkrywa datasety po enroll)** — tak, zgadzam się z
  rekomendacją dokumentu (§4). To już istniejący mechanizm (`--draft-config`), tylko przeniesiony na
  właściwą stronę.
- **§12.9 (`add-client` i `activate-client` jako jedna czy dwie komendy)** — rekomenduję **dwie
  osobne**, zgodnie z zasadą już przyjętą w PAIRING-DESIGN.md dla `--pair`/`--join` ("uruchomienie
  join ze świadomie podanymi --datasets JEST punktem decyzji, rozbijanie go na dwa kroki nie dodaje
  nic" — ale w drugą stronę: scalanie dwóch **różnych** punktów decyzji w jeden, żeby zaoszczędzić
  jedno polecenie, jest dokładnie tym uproszczeniem, którego ta zasada nie popiera). Ręczny transfer
  paczki między krokami 1↔2 to i tak twardy punkt przerwania (LAN-SEED §1: nie ma kanału), więc druga
  komenda nie kosztuje nic ponad to, co i tak jest wymagane.
- **LAN-SEED §12.4 (czy cron ma być instalowany podczas seeda, w stanie wstrzymanym)** — tak,
  rekomenduję instalację od razu, ale z wykorzystaniem **already-istniejącego mechanizmu holda**
  (`update-control.sh`/`emergency_disable` to inny kontroler, ale ten sam wzorzec — "zainstaluj,
  ale trzymaj explicit hold do potwierdzenia" — jest już przetestowanym, zaakceptowanym patternem w
  tym repo, nie trzeba wymyślać nowego).

## 6. Rekomendacja robocza

Zgadzam się z rekomendacją roboczą wszystkich trzech dokumentów. Z mojej strony dokładam: zanim
zacznie się implementacja, warto rozstrzygnąć (właściciel + recenzent) punkt 3 powyżej (status
Wariantu B) i punkt 4 (nowy plik vs rozszerzenie `deploy.sh`) — to są jedyne dwie rzeczy, które
wpływają na to, GDZIE zacznie się pisać kod, reszta (nazwy komend, format pliku klienta, profile)
może się doprecyzować w trakcie.

Dokument jest wkładem do dyskusji, nie decyzją.
