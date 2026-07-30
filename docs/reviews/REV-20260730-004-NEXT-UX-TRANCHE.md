# REV-20260730-004 — następny etap `zfs-backup.sh`: stała relacja i LAN seed → VPN

- Reviewer: ChatGPT
- Data: 2026-07-30
- Zakres: commity `f560705`, `927aad6`, odpowiedź `01f7c70`
- Wynik: **SAFETY TRANCHE ACCEPTED; PRODUCT UX STILL CHANGES REQUIRED**

## 1. Co uznaję za zamknięte

Akceptuję wykonane poprawki bezpieczeństwa:

- brak przypiętego host key jest błędem blokującym;
- generowane joby używają `HostKeyAlias` i aliasowego `known_hosts`;
- porównanie źródła crontaba używa kanonicznej ścieżki;
- modyfikacje configu są wykonywane na working copy, a realny plik jest podmieniany dopiero po walidacji, dry-runie i potwierdzeniu;
- live test potwierdził, że nieudana walidacja nie dotyka produkcyjnego configu;
- live test aktywacji/usunięcia wykazał ograniczony diff crontaba;
- brakujące template'y są uzupełniane niezależnie.

To jest istotny postęp i właściwa reakcja na REV-003.

## 2. Najważniejsza pozostała wada architektoniczna

Obecny `HostKeyAlias` jest nadal budowany z `label`, a `label` jest budowany z `PEER_HOST`:

```text
PEER_HOST=192.168.11.11
label=192.168.11.11
HostKeyAlias=zfs-client-192.168.11.11
target=.../192.168.11.11/...
manifest=.../192.168.11.11.conf
```

To nie jest stała tożsamość relacji. Po zmianie endpointu LAN na VPN zmienią się alias, manifest i target albo kod będzie musiał dalej udawać, że stary adres LAN jest aktualnym hostem.

**Następny etap musi najpierw odwiązać tożsamość od endpointu.**

Minimalny model:

```text
CLIENT_NAME=pve2                 # stała tożsamość użytkowa
RELATION_ID=<uuid lub stabilny id>
ACTIVE_ENDPOINT=lan
ENDPOINT_LAN_HOST=192.168.11.11
ENDPOINT_LAN_PORT=22
ENDPOINT_VPN_HOST=10.8.0.11
ENDPOINT_VPN_PORT=22
HOST_KEY_ALIAS=zfs-client-pve2   # stały
TARGET_BASE=hdd/backups/pve2     # stały
```

Adres nie może już uczestniczyć w nazwie aliasu, targetu, klienta ani logicznego joba.

## 3. Wymagany workflow następnego etapu

Proszę nie rozwijać teraz kolejnych profili ani kosmetyki. Następny implementowany pion powinien być kompletnym, minimalnym scenariuszem:

```text
setup-server
add-client pve2 --lan-endpoint=192.168.11.11
peer enroll
seed pve2
final-catchup pve2
set-endpoint pve2 --vpn=10.8.0.11
verify-vpn pve2
activate-client pve2
```

Nazwy są robocze. Wymagane zachowanie:

1. `add-client` tworzy stałą relację opartą na `CLIENT_NAME`, nie na IP.
2. Fingerprint potwierdzony podczas LAN jest używany po VPN bez ponownego TOFU.
3. `seed` wykonuje rzeczywisty pełny transfer ręcznie, bez instalacji crona.
4. `final-catchup` potwierdza wspólną bazę przed relokacją.
5. Zmiana endpointu modyfikuje wyłącznie adres/port transportu.
6. `verify-vpn` musi wykonać SSH + host-key verification + `snapget -n` i potwierdzić, że pełny transfer nie jest wymagany.
7. Dopiero po stanie `vpn_verified` wolno zainstalować cron.
8. Próba `activate-client` w stanie wcześniejszym ma kończyć się czytelnym fail-closed.

Proponowana minimalna maszyna stanów:

```text
pending_enroll
ready_for_seed
seeding
seed_complete
vpn_configured
vpn_verified
active
```

Nie wymagam tej dokładnej gramatyki, ale wymagam równoważnych bramek.

## 4. `add-client --datasets=` i peer-side `deploy.sh --join`

To nadal nie spełnia filtra „admin po uniwerku”. Admin nie powinien znać backendowego `deploy.sh --join` ani przepisywać listy datasetów z pamięci.

Docelowy prosty przebieg powinien wyglądać jak:

```text
na pve1: zfs-backup add-client pve2 --lan-endpoint=...
na pve2: zfs-backup enroll /ścieżka/paczka
na pve1: zfs-backup activate-client pve2
```

Po enroll pve1 powinien pobrać listę faktycznie udostępnionych datasetów i pokazać wybór/podsumowanie. Backend może nadal używać `deploy.sh --join`, ale nie może być publicznym krokiem podstawowego UX.

Jeżeli w pierwszej iteracji CLI nie ma interaktywnego wyboru, dopuszczam jawne `--datasets=` jako tryb zaawansowany, ale nie jako jedyną ścieżkę domyślną.

## 5. `zfs allow` — surowy dump nie może być jedyną kontrolą

Pokazanie grantów na każdym przodku jest przydatne diagnostycznie, ale zdanie „pozostawia ocenę adminowi” jest zbyt słabe dla prostego UX. Admin ogólny nie powinien ręcznie interpretować kilku bloków `zfs allow` przy każdym wdrożeniu.

Minimalne wymaganie następnego etapu:

- parser rozpoznaje, czy konto ma grant na dokładnym datasecie;
- parser wykrywa jakikolwiek grant na przodku i wyświetla jednoznaczne ostrzeżenie:

```text
UWAGA: konto ma szerszy odziedziczony dostęp z rpool.
Ta relacja nie jest izolowana do rpool/data.
```

Nie należy automatycznie usuwać obcych grantów. Surowy dump może pozostać pod `--verbose`.

## 6. Niespełniony wymóg spójnych snapshotów

Live test prawidłowo wykazał, że `quiesce=agent` nie działa w obecnym pull. Dobrze, że wymaganie nie zostało ukryte.

Jednocześnie nie uznaję tego za kosmetyczny brak. Produkt musi jawnie rozróżnić:

- `crash-consistent` — obecny pull bez remote quiesce;
- `application-consistent` — wymaga nowej funkcji remote quiesce albo trybu push.

Profil `standard` nie powinien sugerować spójności aplikacyjnej. W podsumowaniu aktywacji ma być czytelnie:

```text
Spójność snapshotu: crash-consistent
Guest Agent freeze: niedostępny w trybie pull
```

Decyzja właściciela jest potrzebna, czy dla podstawowego produktu crash-consistent jest akceptowalne, czy remote quiesce jest wymaganiem przed uznaniem workflow za gotowy.

## 7. Dodatkowa uwaga o rollbacku instalacji

`atomic_replace_and_install()` zakłada, że nieudany `gen-cron.sh --install` nie zmienił crontaba. To może być prawdą przy dzisiejszej implementacji, ale komentarz „crontab was NOT changed” jest mocniejszy niż dowód wynikający z samego kodu wrappera.

Proszę dodać test/fault injection potwierdzający jedną z dwóch gwarancji:

1. `gen-cron.sh --install` jest atomowy i przy niezerowym exit nie zmienia crontaba; albo
2. wrapper zapisuje poprzedni crontab i odtwarza go przy każdym niepowodzeniu instalacji.

W produkcyjnym narzędziu bezpieczniejsza jest opcja 2.

## 8. Decyzja review

- Poprawki bezpieczeństwa z REV-003: **zaakceptowane**.
- `zfs-backup.sh` jako kompletny prosty deploy: **nadal niezaakceptowany**.
- Następny wymagany etap: **stała relacja + jawna maszyna stanów LAN seed → VPN → cron**.
- Nie wykonywać kolejnych testów aktywacji na produkcyjnych datasetach; używać wyłącznie throwaway datasets i diffów config/crontab do czasu zamknięcia punktu 7.
