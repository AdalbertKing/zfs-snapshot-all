# REV-20260801-017 — `--local-user`: zachowanie argv oraz brakujący config na pve2

**Status:** CHANGES REQUIRED / OWNER DECISION

## Zaakceptowane

1. REV-016 został zamknięty we właściwym kierunku:
   - jedna częstotliwość send;
   - jedna drabina GFS H24/D7/W4/M12;
   - fail-closed przy nieczytelnym crontabie;
   - migracja jako operacja wysokiego poziomu `migrate-profile`, bez ręcznej edycji template’ów.
2. Guard z `c6c98c2` jest potrzebny i poprawnie chroni przed utworzeniem pustego configu pod ścieżką wskazaną przez istniejący blok crona.
3. `--local-user` jako opcja, bez automatycznej migracji istniejących instalacji root, jest właściwą decyzją kompatybilnościową.

## F1 — `gencron_as_target()` składa polecenie przez tekstowy `su -c ... $*`

Aktualna implementacja buduje pojedynczy string shella:

```bash
su -s /bin/bash - "$u" -c "NOTIFY_SCRIPT='$home/notify-fail.sh' ... bash '$GENCRON' $*"
```

To traci granice argumentów. Argument zawierający spację, wildcard, średnik, apostrof albo inny metaznak zostanie ponownie zinterpretowany przez shell konta docelowego. Nawet jeśli dzisiejsze ścieżki robocze zwykle nie mają spacji, wrapper wysokiego poziomu nie powinien opierać poprawności i bezpieczeństwa na nieudokumentowanym ograniczeniu nazw ścieżek.

Ryzyka:

- inne argv dociera do `gen-cron.sh` niż pokazał/zwalidował wrapper;
- ścieżka configu lub przyszły argument może zostać podzielony albo rozwinięty;
- przy danych kontrolowanych pośrednio przez konfigurację powstaje możliwość wstrzyknięcia polecenia;
- testy ze stubem crontab nie pokrywają rzeczywistej granicy `su` i parsowania argv.

### Wymagane

Przekazywać argumenty bez ponownego składania ich przez `$*`. Akceptowalne kierunki:

- `runuser --user "$u" -- env ... bash "$GENCRON" "$@"`;
- albo `sudo -u "$u" env ... bash "$GENCRON" "$@"`;
- jeżeli musi zostać `su -c`, zbudować argv przez jednoznaczne shell-quoting każdego argumentu (`printf %q`) i mieć testy metaznaków.

Preferowany jest wariant bez tekstowego `-c`, bo jest prostszy do audytu.

### Test zamykający

Uruchomić generator jako konto dedykowane z configiem w ścieżce zawierającej co najmniej spację i apostrof/metaznak bezpieczny dla nazwy pliku. Potwierdzić, że:

- generator dostaje dokładnie jeden argument ścieżki;
- preview i install dotyczą tego samego pliku;
- żaden dodatkowy fragment nie jest wykonywany jako polecenie;
- rollback trafia do crontaba tego samego konta.

## F2 — `--local-user` nie ma jeszcze live testu scenariuszy

Commit sam stwierdza, że `test/scenarios` nie został uruchomiony. Ta zmiana przesuwa jednocześnie:

- właściciela crontaba;
- właściciela klucza i pinned host key;
- HOME, logi i skrypty alertowe;
- tożsamość procesu instalującego cron.

To jest zbyt szeroka granica, aby uznać ją za gotową wyłącznie na podstawie golden suite. Nie włączać `--local-user` do produkcyjnego runbooka przed pełnym live pass: pair, preview, install, test send, alert path, rollback/remove.

## F3 — pve2 wymaga decyzji właściciela, nie automatycznej naprawy

Na pve2 działa 14 zadań, ale wskazany w `# Source:` config pod `/root/gfs-install-tmp/` nie istnieje. Zadania nadal działają, lecz nie można ich bezpiecznie regenerować. Guard chroni przed skasowaniem crona, ale nie odtwarza źródła.

Potrzebna decyzja właściciela:

1. odtworzyć config dokładnie z działającego bloku `crontab -l`, zachowując bieżący profil;
2. albo przeprowadzić kontrolowaną migrację do nowego profilu przez wygenerowanie propozycji i pełny diff — bez automatycznej instalacji.

Do czasu decyzji nie uruchamiać na pve2 `activate-client`, `migrate-profile` ani bezpośredniego `gen-cron --install`.

## Ocena

- REV-016: **zaakceptowane**;
- guard brakującego source configu: **zaakceptowany**;
- `--local-user` architektonicznie: **dobry kierunek, ale CHANGES REQUIRED** przez tekstowe składanie argv i brak live pass;
- pve2: **OWNER DECISION / produkcyjna blokada regeneracji**, obecne zadania pozostawić bez zmian.
