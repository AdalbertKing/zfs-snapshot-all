# REV-20260730-005 — endpoint/state UX after REV-004

- Reviewer: ChatGPT
- Data: 2026-07-30
- Zakres: `b2d5adc`, `085d4c3`, `421044e`, `a57ed08`, `411689d`, `3d0b4ed`, `0f40f9e`
- Wynik: **ISTOTNY POSTĘP; CHANGES REQUIRED PRZED UZNANIEM FLOW LAN→VPN ZA GOTOWY**

## 1. Co akceptuję

Akceptuję jako zamknięte:

- stały `HostKeyAlias` oparty o `CLIENT_NAME`, niezależny od endpointu;
- jawne stany seed/verify/active i blokadę aktywacji przed `endpoint_verified`;
- realny seed bez instalacji crona;
- przełączenie endpointu z ponowną walidacją;
- backup/restore crontaba przy błędzie instalacji;
- czytelne oznaczenie `crash-consistent`;
- wyłączenie `GlobalKnownHostsFile` i `CheckHostIP` po realnych testach IP→hostname;
- czytelniejszy `status` i kategoryzację grantów.

To jest właściwy kierunek i wyraźne zbliżenie do UX dla „admina po uniwerku”.

## 2. F1 — endpoint jest zapisywany jako kod powłoki bez walidacji/quotingu (BLOCKER)

`parse_endpoint_arg()` nie waliduje hosta ani portu, a `add-client`/`set-endpoint` zapisują wartości bez shell-quotingu:

```bash
ENDPOINT_VPN_HOST=$h
ENDPOINT_VPN_PORT=$p
```

Plik klienta jest potem wykonywany przez `.`. Host zawierający spację, `;`, `$()`, backtick, `#` lub znak nowej linii może uszkodzić stan albo wykonać polecenie jako root przy kolejnym `status`, `seed`, `verify-endpoint` itd. Port także nie jest sprawdzany jako liczba 1–65535.

Wymagane:

1. walidacja hosta do bezpiecznego zestawu dla IPv4/hostname używanego w tym projekcie;
2. walidacja portu jako liczby 1–65535;
3. zapis przez `printf '%q'` albo odejście od source'owanych plików shellowych;
4. testy odrzucające co najmniej: `host;id`, `$(id)`, spację, pusty host, `:abc`, port 0 i 65536.

## 3. F2 — `verify-endpoint` rozpoznaje incremental przez brak tekstu „full send” (BLOCKER)

Obecna logika uznaje transfer za incremental, jeśli `snapget.sh -n` zakończy się 0 i output nie zawiera frazy `full send`.

To jest negatywna heurystyka zależna od tekstu. Zmiana komunikatu, inny tryb no-op, brak snapshotów lub nowa gałąź planera może dać exit 0 bez tej frazy i zostać błędnie uznana za incremental.

Wymagane jest pozytywne, maszynowo stabilne potwierdzenie jednego z wariantów:

- `snapget.sh` zwraca jawny kod/marker `PLAN=INCREMENTAL`;
- albo wrapper sprawdza konkretną wspólną bazę snapshotów po obu stronach;
- albo parser wymaga jednoznacznego komunikatu incremental i fail-closed dla wszystkiego innego.

Proszę dodać testy dla: full, incremental, no-op/already-current, brak snapshotów oraz nieznany output przy rc=0.

## 4. F3 — brak jawnego final catch-up przed relokacją

`seed` wykonuje jeden realny transfer i ustawia `seed_complete`. Potem można odłączyć host i przejść do VPN. Nie ma kroku końcowego catch-up tuż przed relokacją.

Technicznie późniejszy cron nadrobi różnicę, ale nie realizuje to uzgodnionego procesu ograniczającego pierwszy transfer przez VPN. Dla dużej i aktywnej maszyny luka między seedem a relokacją może nadal wygenerować duży incremental przez VPN.

Proszę wybrać jedno:

- dodać `final-catchup NAME` jako wymagany stan przed `set-endpoint --vpn`;
- albo jawnie połączyć catch-up z komendą przygotowującą relokację i pokazać ilość danych/plan;
- albo uzyskać decyzję właściciela, że pojedynczy seed i późniejszy incremental przez VPN są wystarczające.

## 5. F4 — po zmianie endpointu stan i faktycznie zainstalowany cron opisują różne rzeczy

Dla aktywnego klienta `set-endpoint` resetuje `STATE=seed_complete`, ale stary cron pozostaje aktywny na poprzednim endpointcie. To jest technicznie celowe, lecz `status` nie pokazuje tej rozbieżności.

Admin widzi `seed_complete`, podczas gdy backup nadal działa. Albo odwrotnie: może zakładać, że nowy endpoint już obowiązuje, choć cron nadal korzysta ze starego.

Proszę przechowywać i wyświetlać co najmniej:

```text
DESIRED_ENDPOINT=vpn
INSTALLED_ENDPOINT=lan
STATE=endpoint_change_pending
```

lub równoważny model. `status` powinien napisać jednoznacznie:

```text
Backup działa nadal przez LAN.
VPN zapisany, ale jeszcze niezweryfikowany i niewdrożony.
Następny krok: verify-endpoint pve2, potem activate-client pve2.
```

## 6. F5 — domyślny UX nadal ujawnia backend

`add-client` nadal wymaga `--datasets=` na pve1 i każe adminowi uruchomić `deploy.sh --join` na peerze. Claude jawnie oznaczył to jako deferred, więc nie blokuję tym samej maszyny stanów, ale blokuje to uznanie narzędzia za końcowy „prosty deploy”.

Następny pion UX powinien ukryć backend pod:

```text
na pve1: zfs-backup add-client pve2 --lan=...
na pve2: zfs-backup enroll /ścieżka/paczka
na pve1: zfs-backup seed pve2
```

Datasety powinny być odkryte po enroll i przedstawione do wyboru/potwierdzenia, nie przepisywane z pamięci jako obowiązkowa ścieżka.

## 7. Decyzja

- REV-004: **większość wymagań zaakceptowana jako wykonana**.
- Gotowość bezpieczeństwa: **blokują F1 i F2**.
- Gotowość LAN→VPN operacyjna: **wymaga decyzji/implementacji F3 i doprecyzowania stanu F4**.
- Gotowość „admin po uniwerku”: **nadal nie**, dopóki `deploy.sh --join` i obowiązkowe ręczne `--datasets=` pozostają publicznym flow.

Do czasu zamknięcia F1/F2 proszę nie testować z endpointami pochodzącymi z niesprawdzonego inputu i nie uznawać `endpoint_verified` za kryptograficzny dowód incremental wyłącznie na podstawie braku frazy `full send`.
