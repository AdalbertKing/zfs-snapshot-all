# Transfer/network policy — odpowiedzi na bramkę §8

Odpowiedź na `PROFILES-TRANSFER-NETWORK-POLICY-2026-08-07.md`. Sześć pytań,
odpowiedzi z kodu. **Jedna z nich koryguje przesłankę noty**, więc zaczynam od niej.

---

## 2 (najpierw, bo zmienia obraz) — czy `-b` jest per transfer?

**Tak, `-b` jest per proces.** Ale przykład z §3 — „cztery transfery równolegle,
agregat ~8M" — **nie odpowiada temu, co robi kod**.

Zmierzone w drzewie: `snapsend.sh` przetwarza datasety w **pętli sekwencyjnej**
(`for dataset in "${DATASETS[@]}"`, snapsend.sh:2012). Zero `&`, zero `wait`,
zero `xargs -P`. W jednym wywołaniu transfery idą **jeden po drugim**.

Więc dla pojedynczej linii crona — a tak wygląda dziś każda relacja, bo
generator scala datasety o wspólnym harmonogramie w **jedną** komendę — `-b`
jest efektywnym pułapem relacji, nie pułapem na dataset.

**Prawdziwe źródło współbieżności jest inne i warto je nazwać dokładnie:**

1. **dwie różne linie tej samej relacji** nachodzące na siebie w czasie —
   np. hourly o :01 wciąż trwa, gdy o :12 startuje daily;
2. **dwie różne relacje** (dwóch klientów) na tym samym kolektorze;
3. **prune/monitor** równolegle do transferu — te nie zużywają pasma sieci.

Czyli problem jest realny, ale ma inny kształt: nie „N datasetów × RATE", tylko
„M nakładających się **zadań** × RATE", gdzie M jest zwykle 1, czasem 2.

To zmienia wycenę poprawki. Nie potrzebujemy dzielnika przez liczbę datasetów
odkrywanych w czasie wykonania — potrzebujemy czegoś, co ogranicza **nakładanie
się zadań**.

## 1 — co mierzy `-A`, a czego nie kontroluje

Z nagłówka `snapsend.sh` i zmierzonych danych z 2026-07-22:

**Mierzy:** prędkość łącza (raz na host na przebieg) i współczynnik kompresji
(per dataset, na prawdziwej próbce `zfs send`). Cache 7 dni.

**Decyduje o jednej rzeczy:** czy włączyć kompresję. Nic więcej.

**Czego NIE kontroluje:** poziomu zstd (mierzone: warte ~2%, więc stałe),
rozmiaru bufora mbuffer (mierzone: 16M/128M/1G nierozróżnialne), **ani pasma**.
Dwie formuły doboru bufora były próbowane i **obie obalone pomiarem**.

Ważne dla tej dyskusji: **`-A` nie jest mechanizmem ograniczania pasma i nigdy
nim nie będzie.** Mierzy łącze po to, żeby zdecydować o kompresji. Nie należy go
przeciążać rolą regulatora.

Druga rzecz: `-b` **zaniża pomiar `-A`** — skoro `-b` ogranicza mbuffer, to
sonda widzi wolniejsze łącze, niż jest naprawdę. To już wiemy, ale przy
projektowaniu agregatu trzeba pamiętać, że te dwa mechanizmy nie są niezależne.

## 3 — najmniejszy poprawny agregat

Skoro współbieżność bierze się z **nakładających się zadań**, a nie z datasetów,
to najtańszym poprawnym rozwiązaniem jest **wykluczenie nakładania**, nie
dzielenie pasma.

Propozycja: **blokada per relacja** na czas transferu. Zadanie tej samej relacji,
które zastanie blokadę, **nie czeka i nie dzieli pasma — kończy się jako
pominięte**, z komunikatem i kodem wyjścia odróżnialnym od błędu.

Dlaczego to, a nie współdzielony limiter:

- projekt **ma już** dokładnie ten wzorzec (`LOCKDIR`, `cron_lock_acquire`,
  zamek per użytkownik z ograniczonym czekaniem). Nie wprowadzamy nowego bytu;
- „N zadań dzieli 2M" wymaga procesu-regulatora żyjącego między zadaniami, czyli
  demona. To jest duży, nowy, trwały komponent — w pakiecie, który dotąd nie ma
  żadnego;
- pominięte zadanie jest **widoczne** dla monitora (snapshot się nie pojawi,
  wiek rośnie), więc „ciche zwolnienie" nie przechodzi niezauważone. Ten
  mechanizm już działa.

Wtedy `-b RATE` znaczy dokładnie to, co obiecuje: **jedno zadanie naraz na
relację, więc RATE jest pułapem relacji**. Zdanie w komentarzu staje się prawdziwe
zamiast być mocniejsze od mechanizmu.

**Czego to nie rozwiązuje i trzeba powiedzieć wprost:** dwie *różne* relacje na
jednym kolektorze nadal sumują się do 2×RATE. Pułap globalny hosta to osobny
problem i osobna decyzja; nie udawajmy, że pułap relacji go załatwia.

## 4 — LAN seed kontra VPN produkcyjny

Zgoda co do kierunku: **żadnych magicznych slotów `lan`/`vpn`.**

Obserwacja z kodu: to jest w istocie **różnica jednorazowa kontra cykliczna**.
Seed robi się raz, ręcznie, pod nadzorem. Produkcja chodzi z crona.

Najtańsza poprawna odpowiedź: **`-b` w ogóle nie należy do profilu ani do seedu**
— należy do zapisu relacji, i to jako właściwość **połączenia**, tak jak klucz i
port. Seed przez LAN to nie inna polityka, tylko **ręczne wywołanie bez `-b`**,
którego nikt nie zapisuje.

Jeśli kiedyś okaże się, że relacja naprawdę ma dwa trwałe endpointy o różnej
przepustowości, to jest to dwie różne dane połączenia, a nie dwa tryby profilu.
Nie projektujmy tego, zanim taki przypadek wystąpi.

## 5 — które decyzje transferu zasługują na własne pola CONFIG v4

Kryterium, które proponuję: **pole natywne dostaje to, co jest wielokrotnie
używalną polityką i czego nie da się wyrazić inaczej.** Nie wszystko, co jest
flagą.

| flaga | do pola natywnego? | dlaczego |
|---|---|---|
| `-A` autotune | **tak**, już jest (`autotune=`) | polityka, nie połączenie |
| `-T` catch-up | **tak** | próg zachowania, wielokrotnie używalny |
| kompresja `-z/-Z/-g` | **nie osobno** — `-A` już o tym decyduje | dodanie ręcznego pokrętła obok automatu daje dwie władze nad jedną decyzją |
| `-b` pasmo | **nie** | właściwość łącza tej relacji, nie polityki |
| `-K/-k/-p/-O` | **nie** | materiał połączenia |
| `-i/-H` | **do rozważenia później** | dziś rzadkie, brak dowodu potrzeby |

Zasada, którą chcę zapisać: **pole natywne powstaje, gdy istnieje realny
przypadek użycia, nie „bo profil mógłby to opakować".** Dodanie pola jest tanie;
usunięcie po tym, jak trafi do configów na czterech hostach — nie.

## 6 — `flags` i czytelność profilu domyślnego

Zgoda z §6 w całości: żadnych dowolnych `flags` w profilu. Materiał połączenia
zostaje przy relacji, a to, co jest wielokrotnie używalne, **awansuje do pola
natywnego** i dopiero wtedy profil je opakowuje.

Do §7 dodam jedno: profil domyślny powinien mieć **komentarz przy każdej grupie
polityk także wtedy, gdy grupa jest pusta**. Dziś `dataset.inc` celowo nie
zawiera `recursive`, a `prune.inc` celowo nie zawiera `recursive` — z zupełnie
różnych powodów. Bez komentarza to wygląda jak przeoczenie i ktoś „naprawi".
Fixture'y Slice A już tak robią i to jest właściwy wzorzec.

---

## Wpływ na Slice B1

**Żadnego blokującego.** Wszystkie sześć odpowiedzi dotyczy pól, których profil
domyślny dziś nie niesie. B1 wyjmuje hardkod retencji i musi dać **bajtowo
identyczny** CONFIG v4 — a to znaczy, że nie może dodać żadnego z omawianych pól.

Proponuję więc: **B1 idzie**, a agregat pasma (pytanie 3) jest osobnym plastrem
po Etapie 2, bo dotyka silnika i podlega zamrożeniu.

Jedyne, co bym zrobił **przed** B1, to poprawił nieprawdziwy komentarz przy
`--bandwidth` — dziś obiecuje pułap relacji, którego nie gwarantuje. To jedna
linijka i ta sama klasa co fałszywe „this host can send", które usuwaliśmy dziś
rano.
