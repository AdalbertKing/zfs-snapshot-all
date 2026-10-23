# Plan wydania publicznego 1.0 (decyzja właściciela 2026-10-23)

## Stan, który ten plan zmienia

- Repozytorium `AdalbertKing/zfs-snapshot-all` jest **publiczne**. Drzewo i historia (ponad 4000 commitów)
  zawierają dane infrastruktury i klientów: adresy sieci (192.168.28.x, 192.168.11.x, VPN 10.98.x; około 1000
  trafień w około 150 plikach, w większości w `test/`), nazwy hostów i domen (`metropolis.net`, `kancelaria.net`,
  `lurk.com.pl`), adres publiczny przekaźnika poczty, odcisk klucza hosta, prawdziwy dziennik crona pve2 z dwóch
  dni (`test/realshape/captures/`), opisy awarii u nazwanych klientów. Sekretów (kluczy prywatnych, haseł,
  tokenów) przegląd z 2026-10-23 nie znalazł. Sam kod nie ma na sztywno prawdziwego adresu ani hosta.
- Kolektor trzyma pełny klon: na pve10 `.git` 273 MB i druga kopia dla konta `zfsbackup` 259 MB, razem około
  550 MB, przy około 4,5 MB plików, które host naprawdę wykonuje. Aktualizacja co godzinę to anonimowy `git pull`
  z publicznego adresu.

## Decyzje

1. Dwa repozytoria o różnych rolach, **bez przepisywania historii**:
   - obecne = **robocze, prywatne**: pełna historia, recenzje, error-log, testy; tu pracuje implementer i
     recenzent;
   - nowe = **publiczne, czyste**: startuje jednym commitem „Release 1.0” z tagiem `v1.0.0`; zawiera skrypty,
     GUI, profile, dokumentację użytkownika (pl i en) i testy; nie zawiera recenzji, dyskusji, notatek z labu ani
     error-loga; każde wydanie to jeden commit z eksportu repo roboczego po przeglądzie danych prywatnych
     (to import wydania, nie zmiana logiczna -- zasada „jeden commit = jedna zmiana” z
     `docs/AI_PROJECT_RULES.md` dotyczy repo roboczego, gdzie historia zostaje).
2. Dokumentacja w dwóch warstwach i dwóch językach: `docs/pl` i `docs/en`, w każdym esencja (jedna strona) i
   pełne przewodniki z instrukcją techniczną; README w katalogu głównym: krótka strona po angielsku z wejściami
   EN i PL.
3. Hosty pobierają tylko to, co wykonują: płytki klon (`--depth 1`), sparse checkout bez `test/` i dokumentów
   wewnętrznych, aktualizacja `fetch --depth 1` + `reset` zamiast `pull`, jeden checkout na host.

## Kolejność (każdy krok osobną paczką: gałąź, PR, zielone CI)

1. Dokumentacja: `docs/pl` (esencja + pełna), `docs/en` (tłumaczenie), README. Czystka polskich przewodników:
   PR #802 (gałąź `docs/cleanup-pl-en`).
2. Podmiana danych prawdziwych w testach, fixture'ach i komentarzach na neutralne (10.0.0.x, `kolektor`,
   `zrodlo-a`, domeny `example.org`), także w repo roboczym; dziennik `test/realshape/captures` przepisany albo
   zastąpiony syntetycznym. Mechaniczne: tańszy model według specyfikacji, testy muszą przejść tak samo.
3. Płytki klon i sparse checkout w `deploy.sh` (instalacja i godzinna aktualizacja), jeden checkout na host;
   najpierw lab (pve9, pve10), produkcja tylko za zgodą właściciela na każdy host.
4. Skrypt eksportu wydania (lista ścieżek publicznych, kontrola danych prywatnych przed commitem), nowe repo
   publiczne z `v1.0.0`; przełączenie adresu aktualizacji na hostach: lab, potem produkcja za zgodą.
5. Właściciel przełącza obecne repo na prywatne (ustawienia GitHuba) -- dopiero gdy żaden host nie pobiera już z
   niego aktualizacji. Wcześniej ukrycie zatrzymałoby aktualizacje floty.

## Do ustalenia przed krokiem 4

- nazwa repo publicznego i licencja (dziś `LICENSE` z autorstwem w nagłówkach silników -- potwierdzić, że zostaje);
- czy testy wymagające roota i prawdziwego ZFS idą do repo publicznego razem z CI.
