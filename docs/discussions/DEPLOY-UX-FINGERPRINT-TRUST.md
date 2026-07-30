# Dyskusja: fingerprint jako stała weryfikacja pve2 przy zmianie LAN → VPN

- Autor uwag: ChatGPT
- Data: 2026-07-30
- Status: **DYSKUSJA — uzupełnienie dokumentów o uproszczonym deployu i scenariuszu LAN seed → VPN**

## Zasada

Jeden poprawnie i niezależnie potwierdzony fingerprint klucza hosta SSH pve2 jest wystarczającą weryfikacją jego tożsamości kryptograficznej.

Fingerprint musi zostać pozyskany kanałem niezależnym od nowo ustanawianego połączenia, np. bezpośrednio z konsoli pve2:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Następnie pve1 porównuje tę wartość z fingerprintem klucza pobranego przez `ssh-keyscan`. Zgodny klucz zostaje zapisany jako zaufany dla tej relacji.

## Skutek dla LAN i VPN

Po jednorazowym zatwierdzeniu fingerprintu zmiana endpointu:

- z adresu LAN na adres VPN;
- z adresu IP na nazwę DNS;
- na inny port SSH;
- po fizycznym przeniesieniu pve1 poza firmę

nie wymaga ponownego parowania ani ponownego potwierdzania tożsamości, o ile pve2 przedstawia ten sam klucz hosta.

Adres IP jest elementem transportu. Fingerprint klucza hosta jest elementem tożsamości.

## Stały `HostKeyAlias`

OpenSSH domyślnie wiąże wpis `known_hosts` z tekstem hosta lub adresem IP. Dlatego ten sam pve2 osiągalny jako `192.168.1.20` i później jako `10.8.0.20` może zostać potraktowany jak dwa różne hosty.

W uproszczonej warstwie orkiestracji należy użyć stałego aliasu tożsamości, np.:

```text
HostKeyAlias=zfs-client-pve2
```

Dedykowany plik `known_hosts` powinien przechowywać zatwierdzony klucz pod tym aliasem. Komenda może łączyć się z aktualnym endpointem, ale weryfikować zawsze tę samą tożsamość:

```text
-O HostKeyAlias=zfs-client-pve2
-k /etc/zfs-snapshot-all/clients/pve2/known_hosts
```

Dzięki temu przełączenie LAN → VPN nie tworzy nowego zaufania. Sprawdzany jest ten sam wcześniej zatwierdzony klucz.

## Kiedy fingerprint nie wystarcza

Fingerprint nie daje niezależnej weryfikacji, jeżeli klucz i jego fingerprint zostały pobrane tym samym niezaufanym kanałem. Potencjalny pośrednik może podać własny klucz oraz zgodny z nim fingerprint.

Niepoprawny model:

1. pierwsze połączenie z niezweryfikowanym hostem;
2. ten host podaje klucz;
3. ten sam kanał podaje fingerprint;
4. zgodność obu wartości uznawana jest za dowód tożsamości.

To potwierdza wyłącznie spójność danych dostarczonych przez tego samego rozmówcę, nie jego prawdziwą tożsamość.

## Zmiana klucza hosta

Zmiana adresu jest normalna i nie wymaga nowej akceptacji.

Zmiana fingerprintu jest zmianą tożsamości kryptograficznej i musi zatrzymać połączenie. Może być prawidłowa po:

- reinstalacji pve2;
- świadomej rotacji kluczy hosta SSH;
- odtworzeniu systemu bez zachowania `/etc/ssh/ssh_host_*`.

Nowy fingerprint wymaga ponownego niezależnego potwierdzenia przez administratora. System nie może w takiej sytuacji automatycznie przejść na `accept-new`.

## Konsekwencja dla uproszczonego UX

Użytkownik powinien wykonać jedną operację zatwierdzenia fingerprintu podczas inicjalizacji relacji. Późniejsze przełączenie endpointu z LAN na VPN powinno komunikować:

```text
Tożsamość pve2: zgodna z wcześniej zatwierdzonym fingerprintem
Endpoint: zmieniony z LAN na VPN
Ponowne parowanie: niewymagane
Pełny transfer: niewymagany
```

System nie powinien pytać o ponowne zaufanie tylko dlatego, że zmienił się adres IP.

## Rekomendacja robocza

> Jeden niezależnie potwierdzony fingerprint klucza hosta pve2 jest źródłem prawdy o jego tożsamości dla całej relacji backupowej. Wszystkie zatwierdzone endpointy LAN, VPN lub DNS mają wskazywać tę samą tożsamość przez stały `HostKeyAlias`. Nowej akceptacji wymaga zmiana klucza hosta, a nie zmiana adresu.

Dokument pozostaje wkładem do dyskusji i nie zatwierdza finalnej składni konfiguracji ani nazw komend.
