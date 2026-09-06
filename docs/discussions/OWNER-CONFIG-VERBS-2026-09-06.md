# Czasowniki zmiany polityki relacji — ustalenia i zlecenie

Status: **ZLECONE przez właściciela 2026-09-06.** Wykonanie w osobnym wątku,
z dostępem do katalogu roboczego i GitHuba. Ten dokument ma pozwolić tamtemu
wątkowi zacząć na zimno, bez ponownego wyprowadzania faktów. Wszystko poniżej
jest zmierzone w drzewie, nie wspomniane z pamięci; przyczyną tej ostrożności
jest E38 w `docs/internal/IMPLEMENTER-ERROR-LOG.md`.

## 1. Po co, skoro polityka jest już zmienialna

Zmiana retencji i harmonogramu **działa dziś**: edycja configu, `gen-cron.sh -c
FILE` jako podgląd i walidacja, `--install` jako zastosowanie (§4 dokumentu
`OWNER-GUI-DECISION-2026-09-04.md`). Czasownik nie dodaje zdolności, tylko
przenosi tę ścieżkę spod ręki pod program.

Powód jest doktrynalny, nie wygodowy. Bez czasownika TUI musiałoby samo
edytować INI, czyli nosić **drugą kopię wiedzy o schemacie pól** — dokładnie ten
kształt, który ten projekt tępi kontraktami w `test/deps.conf` i który
zafundował nam REV-20260904-134. Czasownik zostawia schemat w jednym miejscu i
utrzymuje w mocy zasadę „GUI nie omija odmów i nie ma własnej kopii żadnej
reguły”.

## 2. Co już istnieje — nie pisać tego jeszcze raz

**Zapis pola w sekcji.** `set_or_remove_section_field <plik> <nagłówek> <pole>
<wartość>` w `zfs-backup.sh` jest w pełni ogólny: aktualizuje pole gdy jest,
wstawia gdy go nie ma, usuwa przy pustej wartości. Reszta pliku przechodzi przez
`awk` wiersz po wierszu, więc **komentarze i ręcznie pisane sekcje przeżywają**,
a `mv_preserving_mode` zachowuje uprawnienia. Zwraca 3, gdy nagłówka nie ma.
Trzech konsumentów dzisiaj: pasmo przy aktywacji, `cmd_set_bandwidth` i
`cmd_move_to_client` (pole `pair_label`).

**Bezpieczny wzorzec edycji**, gotowy do skopiowania z `cmd_set_bandwidth`:

1. `mktemp` pliku roboczego **obok** configu, `cp -p` oryginału,
2. `set_or_remove_section_field` na kopii,
3. walidacja przez render: `gencron_as_target -c "$workfile"` — nie goły
   `gen-cron`, bo render musi mieć ścieżki i konto celu,
4. odmowa z oryginałem **nietkniętym**, gdy render odrzuci,
5. dopiero potem podmiana i instalacja.

**Lista dozwolonych pól per typ sekcji.** `gen-cron.sh` ma ją jako tablicę
`FIELD_OK`, budowaną helperem `_allow_fields <kind> <pola…>`, z nazwanymi
zbiorami `POLICY_FIELDS` i `DEFAULTS_POLICY_FIELDS`. Egzekwuje ją
`validate_field_names`, a `test/run.sh` **już** wyskrobuje tę listę z tekstu
`gen-cron.sh` i na niej asercjonuje. Typów sekcji jest **sześć**:
`[defaults]`, `[template:<tier>]`, `[dataset:<ścieżka>]`, `[prune:<zakres>]`,
`[prune-bookmarks:<zakres>]` i `[replica:<nazwa>]` (§2b — `usage` wymienia
tylko pięć, co wprowadziło w błąd pierwszą wersję tego dokumentu).

**Które sekcje należą do relacji.** Sekcje niosą pole `pair_label` nazywające
relację (REV-20260804-045); dociera ono do komendy transferu, do monitora
i do linii `delsnaps`. `cmd_move_to_client` już skanuje config po tym polu, więc
selektor nie jest do wymyślenia, tylko do ponownego użycia.

**Podgląd i zastosowanie.** `gen-cron.sh -c FILE` renderuje zarządzany blok na
stdout i kończy niezerowo przy każdym błędzie, czyli podgląd i walidacja w
jednym. `--install` podmienia blok idempotentnie. `--reconcile` porównuje w
trybie tylko do odczytu, co config kopiuje, z tym, co istnieje.

## 2b. Repliki — wzorzec, który już istnieje

Właściciel, 2026-09-06: „zapomnieliśmy o replice”. Słusznie, i ta luka chowała
**precedens, który powinien narzucić kształt nowemu czasownikowi.**

Repliki nie są relacjami. Mieszkają w `[replica:NAZWA]`, szóstym rodzaju sekcji,
z własną listą pól: `_allow_fields replica source dst schedule prefix notify
media recursive flags history`. Sekcje te **nie niosą `pair_label`**, więc
selektor z §4 ich nie znajdzie i nie powinien.

Najważniejsze: **`add-replica` jest upsertem.** Usage mówi wprost: „Every field
is a flag, and add-replica is an upsert”. Czyli zmiana harmonogramu czy prefiksu
repliki to ponowne wywołanie tego samego czasownika z inną flagą, a
`replica_section_upsert` robi to na sekcji przez `awk`. Repliki mają więc pełną
drogę edycji, której relacjom brakuje.

Konsekwencje dla tego zlecenia, wiążące:

1. **`set-policy` ma naśladować gramatykę `add-replica`**, a nie wymyślać drugą.
   Jedna forma w pakiecie: nazwane flagi, ta sama komenda zakłada i zmienia.
2. **Pola `[replica:]` idą do grupy „ma własny czasownik”** z §5 i `set-policy`
   ma na nie odmawiać, kierując do `add-replica`. Dwie drogi do jednego pola to
   dwie prawdy.
3. **Kontrola ujemna**: `set-policy` na nazwie, która jest repliką a nie
   relacją, musi odmówić i nazwać `add-replica`.

Znalezisko przy okazji, do osobnego rozstrzygnięcia: `usage` w `gen-cron.sh`
wymienia pięć rodzajów sekcji i **pomija `[replica:]`** (zmierzone 2026-09-06:
zero wystąpień słowa w całym `usage`). To właśnie stąd wzięła się luka w
pierwszej wersji tego dokumentu. Uzupełnienie tej listy jest tanie i nie należy
do tego zlecenia, ale ktoś powinien to zrobić.

## 3. Czego brakuje

Wyłącznie warstwy nad tym: powierzchni czasownika, **własnej listy pól, które
czasownik wolno ustawiać**, diffu wobec zainstalowanego bloku i odmów.

## 4. Proponowany kształt

```
zfs-backup.sh set-policy KLIENT [--pole=wartość …] [--preview] [--yes]
zfs-backup.sh show-config KLIENT [--json]
```

- **selekcja sekcji** po `pair_label` = nazwa relacji, jak w `move-to-client`;
- **zastosowanie**: kopia robocza → `set_or_remove_section_field` per pole →
  `gencron_as_target` → diff wobec zainstalowanego bloku → podmiana →
  `--install`;
- `--preview` kończy po diffie i niczego nie instaluje;
- `show-config --json` jest stroną odczytu, której i tak potrzebuje ekran
  ustawień TUI; pokrywa się z etapem A planu GUI.

Jeden czasownik z nazwanymi opcjami, nie czasownik na pole. To ten sam wybór,
co przy ujednoliceniu gramatyki flag i przy `record_load`: jeden mechanizm
zamiast N doraźnych.

## 5. Lista pól czasownika — to jest praca projektowa

Musi być **wyprowadzona z `FIELD_OK`, nie przepisana ręcznie.** Przepisana
rozjedzie się przy pierwszym nowym polu w `gen-cron.sh`; wyprowadzona plus
asercja „każde pole czasownika jest w `FIELD_OK`” pada w suicie, a nie na
hoście. Precedens jest świeży: `record_field_allowed` z REV-20260904-134 i jego
kontrola wyprowadzająca pisarzy z tekstu programów.

Od `FIELD_OK` trzeba potem **odjąć** trzy rozłączne grupy i każdemu odjęciu dać
własny komunikat odmowy:

| grupa | przykłady | dlaczego nie przez `set-policy` |
|---|---|---|
| ma własny czasownik | `bandwidth` (`set-bandwidth`), `pair_label` (`move-to-client`), **cała sekcja `[replica:]`** (`add-replica`, upsert) | dwie drogi do jednego pola to dwie prawdy; czasownik ma kierować do istniejącego |
| własność profilu | pola, które profil pisze do `[dataset]`/`[prune]` | decyzja właściciela 2026-09-01: pole z dwóch miejsc naraz to twarda odmowa `gen-cron`; profil ma pozostać jedynym autorem |
| poszerza zakres | lista datasetów, `src`/`dst` w sposób obejmujący nowe źródło | dowodem zakresu jest plik scope po stronie źródła z sygnaturą sha256, której kolektor nie napisze; odmowa ma nazywać `--commit-scope` |

Reszta, czyli rdzeń: `send_schedule`, `prune_schedule`, `keep`, `retain`,
`prefix`, `pattern`, `quiesce`, `autotune`, `monitor_warn`, `monitor_crit`,
`monitor_schedule`, `monitor_exclude`, `exclude_family`, `gfs`, `passive`.
Ostateczny podział jest do rozstrzygnięcia w tamtym wątku **przez odczyt
`FIELD_OK` i `POLICY_FIELDS`**, nie przez tę tabelę; ta tabela mówi, jakie są
kategorie, nie jaki jest wynik.

## 6. Odmowy wymagane, każda z kontrolą

1. pole nieznane albo nieczytane w tym typie sekcji → komunikat `gen-cron`,
   nie własny;
2. pole czytane przez `gen-cron`, ale nieustawiane przez czasownik → odmowa
   nazywająca powód i drogę zastępczą;
3. wartość, której render nie przyjmuje → oryginał **bajt w bajt** taki sam;
4. relacja bez sekcji o tym `pair_label` → odmowa mówiąca, że config nie opisuje
   tej relacji;
5. edycja poszerzająca zakres → odmowa nazywająca `--commit-scope` na źródle;
6. brak `--yes` przy zastosowaniu → zatrzymanie po diffie;
7. nazwa, która jest repliką a nie relacją → odmowa nazywająca `add-replica`
   (§2b).

## 7. Obowiązki dowodowe

- sekcja w `test/zfsbackup` z kontrolami z §6, każda dyskryminująca, w tym
  ta o replice;
- asercja wyprowadzająca: pola czasownika ⊆ `FIELD_OK`, wyskrobane z
  `gen-cron.sh`, wzorem istniejącej asercji w `test/run.sh`;
- kontrola, że **ręcznie dopisany komentarz przeżywa** edycję;
- kontrola, że odrzucona wartość zostawia plik bajt w bajt;
- `./test/impact.sh --verify` uruchomione **bez potoku** (E37);
- lab na parze pve9 → pve10: zmiana retencji, dowód że crontab zmienił się
  dokładnie tak, jak pokazał podgląd, i że następny bieg to honoruje; runbook
  jako `docs/discussions/LAB-…`, wynik dopisany po przebiegu.

## 8. Poza zakresem tego zlecenia

- **`remove-source KLIENT DATASET`**, czyli zwężenie zakresu. Osobna sprawa,
  3–5 dni plus lab i najpewniej REV, bo musi rozstrzygnąć, co dzieje się z
  danymi już leżącymi na celu. Leży na liście odłożonych w
  `docs/project/ACTIVE-WORK-PLAN.md`.
- **Poszerzenie zakresu** zostaje operacją dwumaszynową. Żaden czasownik na
  kolektorze tego nie zdejmie i nie należy takiego projektować.

## 9. Wycena

Kalibracja z drzewa, nie z podręcznika (E35): `set-bandwidth` i `set-endpoint`
weszły po jednym commicie, każdy w jeden dzień, i robią ten sam taniec na
jednym polu.

| element | dni |
|---|---|
| `set-policy`: lista pól, selektor po `pair_label`, diff, odmowy, testy | 2–3 |
| `show-config --json` | 0,5–1 (zero, jeśli etap A planu GUI zrobi to wcześniej) |
| lab i runbook | 1 |
| dokumentacja, `deps.conf`, `PROJECT_STATUS` | 0,5 |
| **razem** | **4–6** |

Dni idą na listę dozwoleń i kontrole dyskryminujące, nie na objętość kodu.
Ekran ustawień w planie GUI spada po tym z 4–6 dni do 2–3, bo staje się
formularzem nad czasownikiem zamiast edytorem INI z własną walidacją, więc
koszt krańcowy to realnie 1–3 dni.

## 10. Od czego zacząć w tamtym wątku

```bash
sed -n '/^set_or_remove_section_field()/,/^}/p' zfs-backup.sh
sed -n '/^cmd_set_bandwidth()/,/^}/p'          zfs-backup.sh   # wzorzec edycji
grep -n 'set_or_remove_section_field' zfs-backup.sh            # trzech konsumentów
grep -n 'FIELD_OK\|_allow_fields\|POLICY_FIELDS' gen-cron.sh   # lista pól
sed -n '/^validate_field_names()/,/^}/p'       gen-cron.sh
grep -n 'pair_label' zfs-backup.sh gen-cron.sh                 # selektor sekcji
```

Przed pierwszą zmianą: sekcja 1 `docs/internal/IMPLEMENTER-ERROR-LOG.md`,
`docs/AI_PROJECT_RULES.md` i świeży `docs/internal/reviews/REVIEW_LEDGER.md`
z opublikowanego `main`.
