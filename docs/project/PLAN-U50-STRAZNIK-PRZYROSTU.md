# U50 -- strażnik podejrzanego przyrostu (ransomware), tylko alarm (plan 2026-10-21)

Właściciel 2026-10-21: „Zgoda. Wpierw check. Domykamy recenzenta i potem zrób alarm” (wariant: 1.0, tylko
alarm, bez blokady kopii). Ustalenia 2026-10-15: „ransomware szyfruje, my widzimy po kaskadowym przyroście”;
„ostrożnie” -- comiesięczna konwersja baz (60 GB, ~3 h) to legalny przyrost i nie może podnosić alarmu.

## Sygnał (zmierzone na pve10 2026-10-21)

Dla przyrostu między dwiema kolejnymi migawkami datasetu dwa oszacowania z metadanych, bez wysyłania danych:

- `L` = `zfs send -nP -i @a ds@b` -- rozmiar logiczny przyrostu;
- `C` = `zfs send -nPc -i @a ds@b` -- ten sam przyrost w blokach takich, jak leżą na dysku (skompresowanych).

`L / C` to kompresowalność samego przyrostu. Lab: tekst i liczby 1,22 (dane testowe, bazy kompresują się
mocniej); dane losowe (jak szyfrogram) dokładnie 1,00.

**Alarm, gdy dla najnowszego przyrostu jednocześnie:**
1. tempo przyrostu `L / czas między migawkami` >= `factor` x mediana tempa z poprzednich przyrostów z ostatnich
   `days` dni (domyślnie 5x, 7 dni, co najmniej 3 przyrosty historii -- inaczej brak normy, brak alarmu);
2. `L` >= `min_mib` (domyślnie 1024 MiB) -- małe datasety nie alarmują od szumu;
3. `L / C` <= `max_ratio_pct` / 100 (domyślnie 1,10) -- przyrost prawie się nie kompresuje.

Konwersja baz: duży przyrost, ale kompresowalny -- warunek 3 go przepuszcza. Szyfrowanie plików: duży i
niekompresowalny -- alarm.

## Zakres

- Datasety „nasze” jak w bezpieczniku (U35): lokalne linie `delsnaps.sh` w zarządzanych blokach crontabów
  (z `-R` dzieci). Działa na źródle i na kolektorze (odebrane migawki mają te same bloki).
- Pomijane z nazwą w `--plan`: `compression=off` (każdy przyrost wygląda na niekompresowalny), za mało historii.
- Dataset z szyfrowaniem w gościu (np. BitLocker na dysku VM) ma zawsze ~1,00 -- alarm zostaje tylko na skok
  przyrostu; opisane jako ograniczenie.
- Tylko alarm: nic nie kasuje, nic nie wstrzymuje. Jeden alarm na migawkę (stan w
  `/var/lib/zfs-snapshot-all/growth-guard`), wyniki oszacowań zapamiętywane po GUID-ach pary (koszt raz).

## Ustawienia (F10, `[growth]`; kolejność jak U35: env > settings.ini > zfs-alert.conf > domyślne)

`growth.alert` off|on (domyślnie **off** -- włącza admin, jak bezpiecznik), `growth.factor` 5 (2-100),
`growth.min_mib` 1024 (1-10485760), `growth.max_ratio_pct` 110 (100-200), `growth.days` 7 (2-60). Zła wartość =
nic, kod 1, alert z nazwą (jak REV-155). Skrypt `hostscripts/growth-guard.sh`, cron co godzinę w bloku hosta,
instalowany przez deploy.

## Testy -- suita (test/alertmail, zaślepki zfs/zpool, prawdziwy skrypt)

| # | przypadek | wynik |
|---|---|---|
| T1 | `alert = off` | nic, bez wywołań `zfs send` |
| T2 | normalny przyrost (tempo jak norma) | brak alarmu |
| T3 | skok x20, kompresja 1,00, ponad `min_mib` | ALARM z datasetem, rozmiarem, tempem, współczynnikiem |
| T4 | skok x20, ale kompresja 2,5 (konwersja baz) | brak alarmu |
| T5 | skok x9, kompresja 1,00, poniżej `min_mib` | brak alarmu |
| T6 | za mało historii (3 przyrosty) | brak alarmu, w `--plan` „brak normy” |
| T7 | `compression=off` | pominięty, w `--plan` powód |
| T8 | ten sam alarm drugi raz (ta sama migawka) | jeden mail, nie dwa |
| T9 | dataset bez linii retencji / linia poza blokiem | nie badany |
| T10 | błąd `zfs list` / `zfs send -nP` / zła liczba | kod 1, alert „strażnik nie działa”, bez fałszywego „OK” |
| T11 | zła wartość ustawienia (każde z 5 i `alert = ON`) | nic, kod 1, alert z nazwą |
| T12 | kolejność env > settings > conf | jak w U35 |
| T13 | kontrola negatywna (ręczna, nie w suicie) | ten sam zestaw z atrapą skryptu i ze starszą wersją: przypadki alarmu i błędów czerwone |

## Na żywo (lab pve10, osobny dataset z lz4)

| # | przypadek | dowód |
|---|---|---|
| L1 | 5 migawek z małym przyrostem tekstowym, potem 300 MB losowych | alarm na ostatniej |
| L2 | to samo, ale 300 MB kompresowalnych (tekst) | brak alarmu |
| L3 | instalacja przez deploy: skrypt w /root/scripts, linia crona w bloku hosta | `--check-only` widzi linię |

## Wyniki (2026-10-21)

Suita `test/alertmail`: 27 wierszy `PASS growth-guard` (T1-T12, start jak w REV-20261021-157, pary mieszane,
ponowienie alarmu po nieudanym powiadomieniu, crontab nie do przeczytania) -- zielone; z atrapą skryptu (nic nie robi) 15 z pierwszych 20 czerwonych, 5 zielonych to
przypadki „bez alarmu”. Na żywo pve10 (pula z pliku, `lz4`, osobny katalog crontabów, kroki co 8 s):
L1 -- 300 MiB losowych przy normie kilku MiB: tempo 26,9x, kompresja 1,00 -- ALARM, jeden mail; L2 -- 305 MiB
danych w stylu bazy: tempo 147,8x, kompresja 7,60 -- bez alarmu. L3 (instalacja przez deploy) -- po scaleniu,
z godzinną samoaktualizacją.

Wnioski z prób: (1) `base64` z danych losowych dla `lz4` jest niekompresowalny (lz4 nie koduje entropii) --
„kompresowalny” test musi mieć powtarzalną treść; (2) tempo liczone z czasu między migawkami -- przy migawkach
w nierównych odstępach (kilka rodzin) to właściwa miara, w teście trzeba trzymać równe kroki; (3) dane już
skompresowane przez aplikację (zip, zdjęcia, wideo) wyglądają jak szyfrogram -- alarm mówi o tym wprost.

## Poprawka po pytaniu właściciela (2026-10-21: „To zadziała prawidłowo na godzinowych i dobowych migawkach?”)

Pierwsza wersja oceniała tylko NAJNOWSZĄ parę. Godzinowa o :17 i dobowa o 01:45 dają w jednej godzinie dwie pary;
szyfrowanie 01:20-01:40 ląduje w parze 01:17->01:45, a o 02:23 najnowsza jest już 01:45->02:17 -- skok przepadał
(to samo na kolektorze, gdzie migawki przychodzą paczką). Teraz oceniana jest każda para, której strażnik nie
widział, względem mediany tempa par sprzed niej; pierwszy bieg na datasecie tylko zapamiętuje historię.
Obliczenia (norma 200 MiB/h): para 60 min = 200 MiB, 28 min = 93 MiB, 32 min = 107 MiB -- tempo równe;
szyfrowanie 50 GiB w 30 min = 500x normy przy kompresji 1,00 -- alarm; konwersja 60 GB w 3 h = ok. 100x, kompresja ~3
-- bez alarmu; same dobowe migawki -- alarm do doby po zdarzeniu.
Nowe testy: godzinowe + dobowe (pary 600 s i 3000 s, niekompresowalne -- rozstrzyga tempo) bez alarmu; skok w
krótkiej parze godzinowa->dobowa -- alarm; dwie nowe migawki, skok w nie-najnowszej -- alarm za nią (stara wersja:
FAIL). Test na żywo z prawdziwym cronem na pve10 (pula `gwlive`, 2026-10-21/22): sprawdzenie po godzinie, po
„szyfrowaniu” (12:07 UTC) i po dobie (dobowa 01:40 UTC, „konwersja” 05:07 UTC).

## Poprawki po sprawdzeniu tekstu z kodem (2026-10-21)

- Błąd odczytu pojedynczego crontabu ginął w potoku -- teraz najpierw zapis do pliku, potem analiza; test.
- Para z alarmem trafiała do „ocenionych” przed wysłaniem alertu; gdy powiadomienie zawiodło, alarm przepadał --
  teraz zapis dopiero po wysłaniu, następny bieg ponawia; test.
- Treść maila: „przyrost między migawkami” (nie „najnowszy”), bo alarm może dotyczyć wcześniejszej pary.
- Warunek tempa bez pułapki `A && B || C` przy normie 0; brak zapisu stanu = alert.
- Ograniczenia dopisane: ręczna migawka minutę po godzinowej daje krótką parę -- alarm tylko, gdy w tej minucie
  przybyło >= `min_mib` niekompresowalnych danych (co samo jest podejrzane); długie szyfrowanie przez wiele par
  podnosi medianę dopiero, gdy zajmie połowę okna (7 dni godzinowych to ok. 168 par).
