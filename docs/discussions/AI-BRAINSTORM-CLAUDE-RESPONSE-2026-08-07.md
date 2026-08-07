# Brainstorm — odpowiedź implementera

Odpowiedź na `AI-BRAINSTORM-PROFILES-SCHEDULER-RESTORE-2026-08-07.md` i brief
właściciela. Krótko, bo brief §12 wprost o to prosi.

---

## 1. Rekomendacja wykonawcza

1. **Profil = A1 (wąski preset polityki)**, nie A2, nie A3.
2. Profil niesie: harmonogramy, prefiksy, retencję/GFS, monitoring, `recursive`.
3. Wszystko inne zostaje tam, gdzie jest dziś. Nie przenosimy nic „przy okazji".
4. **Nowe pole natywne powstaje dopiero, gdy istnieje przypadek użycia** — nie
   dlatego, że profil mógłby je opakować.
5. **Harmonogram: żadnego demona, żadnej kolejki, żadnego limitera.**
6. Jedyna obrona przed nakładaniem: **blokada per relacja, przegrany pomija**.
   Projekt ma już ten wzorzec (`cron_lock_acquire`).
7. Pominięty przebieg jest **widoczny dla monitora** — wiek snapshotu rośnie.
   Nie potrzeba osobnego kanału alarmowego.
8. **Seed to nie tryb.** To ręczne wywołanie bez `-b`, którego nikt nie zapisuje.
9. `-b` zostaje **daną połączenia relacji**, nie polityką profilu.
10. Restore: **planner najpierw**, sam w sobie wart wydania. SAFE potem. Replace
    na końcu, jako osobny czasownik.
11. **Nic z tego nie wymaga zmian w silniku** poza Etapem 2, który już jest
    uzgodniony.
12. Kolejność: Etap 2 → freeze → uzgadnianie zakresu → B1 → reszta profili.
13. B1 **nie jest zablokowany** przez żadną decyzję z tej burzy mózgów, bo musi
    dać bajtowo identyczny CONFIG v4, więc i tak nie może nic dodać.
14. Największe realne zagrożenie nie jest w projekcie, tylko w tempie: dziś
    powstało **11 dokumentów dyskusyjnych i zero linii kodu produktu**.
15. Proponuję **zamknąć fazę projektową** tą syntezą i wrócić do dostarczania.

## 2. Model profilu — A1, z jedną furtką

**A1.** Powód jest kosztowy, nie estetyczny.

A2 („szeroki preset") wciąga do profilu `quiesce`, `autotune`, `-T`. Każde z
nich jest albo **faktem środowiska** (czy gość ma agenta; jakie jest łącze),
albo już zautomatyzowane (`-A` sam decyduje o kompresji). Profil, który to
niesie, kłamie na temat przenośności — ten sam profil na innym hoście da inny
efekt, a administrator nie będzie wiedział dlaczego.

A3 („komponowalne polityki, jeden widoczny profil") to **ukryty framework
pierwszeństwa**. Pytanie z noty jest retoryczne: tak, tworzy drugi język, tylko
niepisany. Odpada.

**Furtka:** A1 nie zamyka drogi do A2. Gdy jakieś pole okaże się realnie
wielokrotnie używalne, awansuje do pola natywnego i profil je opakuje. Ta droga
jest jednokierunkowa i tania. Odwrotna — wycofanie pola z configów na czterech
hostach — nie jest.

**Co zostaje poza profilem i administrator nadal robi ręcznie:** wybór
datasetów, endpoint, konto, klucze, pasmo, tryb backup/sync. To są **fakty
relacji**, nie polityka, i tak ma zostać.

## 3. Harmonogram i zasoby — minimum

**TERAZ:** blokada per relacja z pominięciem. Jedno zadanie relacji naraz.

**NIE TERAZ, i to jest decyzja, nie odłożenie:**

- demon/kolejka/limiter — nowy trwały komponent w pakiecie, który nie ma
  żadnego. Blast radius: cały host. Wartość: dzieli pasmo między zadania, które
  po blokadzie i tak nie będą się nakładać;
- globalny pułap hosta — realny problem, ale osobny. Nie udawajmy, że pułap
  relacji go rozwiązuje;
- automatyczne rozsuwanie harmonogramów — generator już rozsuwa minuty per
  tier. Dowód, że to nie wystarcza, jeszcze nie istnieje.

Uzasadnienie z kodu: `snapsend` przetwarza datasety **sekwencyjnie**
(snapsend.sh:2012, zero `&`), a generator scala datasety o wspólnym
harmonogramie w jedną komendę. Więc „N datasetów × RATE" nie występuje.
Występuje „M nakładających się **zadań**", gdzie M to zwykle 1.

## 4. Profile wbudowane — krótka lista

Tylko takie, które odpowiadają realnemu wzorcowi wdrożenia:

| profil | po co |
|---|---|
| `default` | dzisiejsze H24/D7/W4/M12 z GFS |
| `hourly-only` | maszyny, gdzie liczy się świeżość, nie historia |
| `daily-archive` | dane zimne, rzadka zmiana |
| `no-gfs` | zwykła retencja licznikowa, bez drabinki |

**Cztery, nie osiem.** Iloczyn kartezjański rekursji × retencji × kadencji daje
kilkadziesiąt kombinacji, z których administrator użyje trzech. `recursive`
zostaje polem, nie wymiarem nazw profili.

## 5. Restore — co musi być zachowane teraz

**Musi teraz:** sufiks snapshotu liczony raz na przebieg (Etap 2.1). Bez tego
`flat` bez `-q` nie jest korelowalny i restore całego poddrzewa nie ma czego
odtworzyć jako spójnego zestawu. To jedyna rzecz z restore'u, która **musi**
wejść przed zamrożeniem silnika.

**Może poczekać:** planner, SAFE, replace. Żadne z nich nie dotyka silnika.

**Zmierzone i warte zapisania:** `atomic` i `flat -q` już dziś korelują
(identyczna nazwa i `creation` w całym poddrzewie — 11.11, wszystkie pięć
datasetów `creation 1786107661`). Wspólna nazwa dowodzi wspólnego **przebiegu**,
nie punktu w czasie. Restore ma to raportować, a nie zrównywać trzy tryby.

## 6. Scenariusze administratora, których nota nie wymienia

Z dzisiejszej pracy na żywych hostach, nie z wyobraźni:

1. **Nowy gość poza grantem.** Na pve0 granty są per dataset. Dopisanie datasetu
   do configu **nie wystarczyło** — zadanie padło na uprawnieniach. Profil tego
   nie naprawi i nie powinien.
2. **Zainstalowany skrypt starszy niż repozytorium.** Godzinny `git pull` może
   nie zdążyć. Lokalny test nie rozstrzyga, czy wdrożona kopia rozumie nową
   opcję.
3. **Blokada utworzona przez roota blokuje konto na stałe.** Trzy z czterech
   hostów były dziś w tym stanie. Katalog `2775` nadaje grupę, ale **nie tryb**.
4. **Cudzy snapshot na celu znika bez śladu.** `zfs recv -F` jest bezwarunkowe,
   przebieg kończy się `rc=0`. Administrator, który trzyma cokolwiek własnego na
   serwerze kopii, straci to.
5. **Config wylicza, rzeczywistość rośnie.** VM 104 działała bez żadnej kopii,
   bo powstała po napisaniu configu. Nic tych dwóch rzeczy nie porównywało.

Numer 5 to argument za **uzgadnianiem zakresu przed profilami** — profil bez
tego dziedziczy tę samą ślepotę, tylko ładniej opakowaną.

## 7. Koszt i wartość

| pozycja | wartość | złożoność | promień | testy | tokeny | rekomendacja | prostsza wersja |
|---|---|---|---|---|---|---|---|
| Etap 2 (sufiks, jedna deklaracja, długie opcje) | HIGH | SMALL | silnik | umiarkowane + 1 ZFS | LOW | **NOW** | sam sufiks |
| Blokada per relacja | HIGH | SMALL | wysoki poziom | małe | LOW | **NOW** | — |
| Poprawka komentarza `--bandwidth` | MEDIUM | SMALL | dokumentacja | brak | LOW | **NOW** | — |
| Uzgadnianie zakresu (raport) | HIGH | MEDIUM | wysoki poziom | umiarkowane | MEDIUM | **NEXT** | sam raport, bez dopisywania |
| Profile B1 (wyjęcie hardkodu) | MEDIUM | MEDIUM | config | umiarkowane | MEDIUM | **NEXT** | — |
| Restore planner | HIGH | MEDIUM | wysoki poziom | umiarkowane | MEDIUM | **NEXT** | — |
| Restore SAFE | HIGH | MEDIUM | wysoki poziom | ZFS | MEDIUM | NEXT | — |
| Restore replace | MEDIUM | LARGE | destrukcyjny | ZFS + live | HIGH | **DEFER** | tylko planner+SAFE |
| Profile C/D (wybór, własne) | MEDIUM | MEDIUM | config | umiarkowane | MEDIUM | DEFER | — |
| Demon/kolejka/limiter | LOW | LARGE | cały host | duże | HIGH | **NIE BUDOWAĆ** | blokada per relacja |
| Globalny pułap hosta | MEDIUM | LARGE | cały host | duże | HIGH | **DEFER** | — |
| `--json` | LOW | MEDIUM | API | umiarkowane | MEDIUM | **NIE TERAZ** | — |
| Nowe pola natywne „na zapas" | LOW | SMALL | config | małe | LOW | **NIE BUDOWAĆ** | dodać, gdy będzie przypadek |
| A3 (komponowalne polityki) | LOW | LARGE | config | duże | HIGH | **NIE BUDOWAĆ** | A1 |

## 8. Kolejność

Bez zmian wobec planu zatwierdzonego przez REV-060, z jednym dopiskiem:

1. **Etap 2** — czeka na werdykt dla `8b69e1a`/`c49afd2`;
2. **blokada per relacja** — wchodzi razem z Etapem 2, ten sam obszar;
3. **freeze** silnika, z pisemną definicją;
4. **uzgadnianie zakresu** (raport);
5. **B1** — wyjęcie hardkodu, bajtowo identyczne;
6. **restore**: planner → SAFE;
7. reszta profili, jeśli nadal będzie chciana.

## 9. Czego świadomie nie budujemy

- **demona/kolejki/limitera** — blokada per relacja rozwiązuje ten sam problem
  bez nowego komponentu;
- **A3** — ukryty framework pierwszeństwa to drugi język, tylko niepisany;
- **`--json` teraz** — format bez konsumenta zastyga w złym kształcie;
- **pól natywnych na zapas** — dodanie tanie, wycofanie z czterech hostów nie;
- **trybów `lan`/`vpn`** — seed to ręczne wywołanie, nie tryb;
- **profili jako wymiaru dla `recursive`** — to pole, nie nazwa;
- **restore replace przed planner+SAFE** — kolejność ma znaczenie, bo planner
  jest wart wydania sam.

## 10. Spór z recenzentem

Jeden, techniczny, z dowodem: **przykład agregatu pasma w
`PROFILES-TRANSFER-NETWORK-POLICY` §3 nie odpowiada kodowi.** „Cztery transfery
równolegle, ~8M" zakłada zrównoleglenie, którego nie ma — `snapsend.sh:2012` to
pętla sekwencyjna bez `&`, `wait` i `xargs -P`.

To nie unieważnia problemu, tylko go przecenia: realny kształt to nakładające
się **zadania**, nie datasety. Dlatego proponuję blokadę zamiast dzielenia
pasma. Jeśli recenzent ma kontrprzykład ze zrównolegleniem w kodzie, cofam się —
ale szukałem i nie znalazłem.

---

## Uwaga o tempie

Dziś powstało **11 dokumentów dyskusyjnych** i zero linii kodu produktu. Bramka
za bramką: Etap 2 czeka na werdykt kontraktu, B1 czeka na tę syntezę.

Nie kwestionuję żadnej pojedynczej bramki — każda była uzasadniona. Ale suma
zaczyna wyglądać jak to, przed czym ostrzega §12 briefu. Proponuję, żeby ta
synteza **zamknęła fazę projektową**, a kolejne pomysły trafiały do backlogu
zamiast otwierać nowy dokument.
