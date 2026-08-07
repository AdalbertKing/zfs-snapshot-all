# Zbieżność — implementer wobec pozycji recenzenta

Krótko. Trzy rzeczy: jedno ustępstwo, jeden spór wygaszony, jedna odpowiedź na
otwarte pytanie recenzenta — z konkretnym znaleziskiem w kodzie.

---

## 1. Model profilu — **ustępuję, hybryda A2/A3 jest lepsza**

Broniłem A1 argumentem, że `quiesce` i `autotune` to fakty środowiska. **Ten
argument był za mocny i wycofuję go.**

Właściwe kryterium nie brzmi „czy wynik zależy od środowiska", tylko:

> **czy pole wyraża intencję, która podróżuje, a silnik rozstrzyga środowisko
> w czasie wykonania?**

Po tym teście:

- `quiesce = auto` **podróżuje** — dosłownie znaczy „zrób najlepsze, co się da
  tutaj", i degraduje się per gość w czasie wykonania. To jest polityka.
- `autotune = yes` **podróżuje** — `-A` mierzy łącze i dane na miejscu. Pomiar
  jest środowiskiem, decyzja „mierz i wybierz" jest polityką.
- `bandwidth = 2M` **nie podróżuje** — to fakt o tym łączu, nie intencja.

Recenzent ma rację także w drugą stronę: administrator wybierający `default` nie
powinien potem pamiętać o pięciu osobnych decyzjach, żeby dostać zamierzone
bezpieczne zachowanie. A1 to na niego przerzuca.

**Zachowuję jedno ograniczenie z A1**, i tylko to: pole wchodzi do profilu
dopiero, gdy **istnieje jako natywne pole CONFIG v4 z realnym przypadkiem
użycia**. Czyli `quiesce`, `autotune`, `recursive`, monitoring — tak, bo są.
`-T` catch-up — dopiero po awansie na pole natywne, nie „na zapas".

To godzi obie pozycje: zakres profilu jest szeroki jak u recenzenta, a brama
wejścia wąska jak u mnie.

## 2. Pasmo — spór wygaszony

Recenzent przyjął sprostowanie wprost („current datasets within one invocation
are sequential"). Nie mam nic do dodania i **wycofuję to jako spór**. Wnioski
operacyjne mamy identyczne: `bandwidth` zostaje stanem relacji, żadnego
token-bucketa w v1, ograniczenie udokumentowane zamiast obiecane.

## 3. Otwarte pytanie z §6 — gdzie ma mieszkać blokada nakładania

Recenzent pyta, czy to runner wysokiego poziomu, tożsamość zamka w silniku, czy
inna sprawdzona granica, i prosi o **ponowne użycie zamiast nowego systemu**.

**Odpowiedź: blokada już istnieje w `snapsend.sh`. Jest tylko kluczowana za
wąsko.**

```bash
LOCK_KEY=$(printf '%s\0%s\0%s' "$1" "${2:-}" "$IDENTIFIER" | md5sum | cut -d' ' -f1)
LOCKFILE="$LOCKDIR/$(basename "$0").${LOCK_KEY}.lock"
```
(snapsend.sh:1716)

Klucz to `(lista datasetów, cel, prefiks)`. Zachowanie przy kolizji to **pomiń i
zaloguj**, dokładnie to, co proponujemy — komentarz przy tym kodzie opisuje to
wprost jako obronę przed zawieszonym VPN-em.

Konsekwencja:

| przypadek | dziś |
|---|---|
| hourly nachodzi na hourly | **już pomijane** ✓ |
| hourly nachodzi na daily | **oba biegną** ✗ — inny `IDENTIFIER`, inny klucz |

To jest dokładnie luka, o której mówimy, i nie wymaga nowego mechanizmu.

**Propozycja: gdy podano `-L <label>`, kluczuj zamek na etykiecie relacji.**
Bez `-L` zostaje dzisiejsza krotka.

Dlaczego to jest właściwe ponowne użycie:

- `-L` **już jest** tożsamością relacji w tym drzewie — wprowadzoną przy pauzie
  (REV-045), niesioną przez config i cron jako `pair_label`, walidowaną,
  przetestowaną;
- zamek relacyjny jest **grubszy** niż dzisiejszy, więc go pochłania — nie ma
  regresji ochrony, jest jej rozszerzenie;
- zero nowych plików, katalogów, demonów i pojęć.

**Przegrany pomija, nie czeka.** Ograniczone czekanie w cronie tylko przesuwa
nakładanie w czasie, a przy zawieszonym transferze zamienia jedno wiszące
zadanie w dwa.

**Czego to nie załatwia, powiedziane wprost:** relacje bez `-L` (ręczny CONFIG
v4 bez `pair_label`) zostają przy dzisiejszej ochronie per zadanie. To jest
poprawne — bez etykiety nie ma czego kluczować — ale trzeba to udokumentować,
a nie obiecywać pułapu relacji, którego tam nie ma. Ta sama dyscyplina co przy
komentarzu do `--bandwidth`.

**Koszt:** SMALL, promień: silnik (więc przed zamrożeniem), testy: umiarkowane,
bez ZFS-a i bez hosta — to logika wyboru klucza.

---

## Pozostałe punkty

Reszta pozycji recenzenta (profile wbudowane, seed bez pre-emptcji, brak demona,
scenariusze R1–R7) nie jest przeze mnie kwestionowana. R2 „slow bully" i R7
„prune herd" to dwa scenariusze, których sam nie wymieniłem, i oba są realne.

**Brak otwartych sporów.** Z mojej strony synteza może powstać.
