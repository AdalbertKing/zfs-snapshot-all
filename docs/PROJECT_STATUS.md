# PROJECT_STATUS — faktyczny stan projektu

> **To jest dokument ŻYWY, nie protokół z jednego dnia.**
> Odświeżany przez implementera na końcu **każdego** etapu, zanim etap zostanie
> zgłoszony jako zrobiony. Jeżeli data poniżej jest starsza niż ostatni commit
> zmieniający zachowanie — dokument jest zepsuty i to jest defekt do zgłoszenia,
> nie drobiazg. Obowiązek jest zapisany w `CLAUDE.md` i przypomina o nim
> `./test/impact.sh` jako obowiązek ręczny `project-status`.

<!-- status-covers-digest: 019af9d04159f6bc -->
<!-- Znacznik maszynowy: skrot TRESCI wszystkich plikow, ktore deklaruja
     obowiazek project-status. Zapisywany przez ./test/impact.sh
     --refresh-status, sprawdzany przez --verify. Nie usuwac i nie zmieniac
     formatu -- to jedyne, co odroznia dokument aktualny od takiego, ktory
     tylko wyglada na aktualny.

     Byl tu wczesniej SHA ostatniego commita zmieniajacego zachowanie. Tego nie
     dalo sie sprawdzic PRZED tym commitem -- commit nie zawiera wlasnego
     skrotu -- wiec --verify uruchomiony jako bramka przed etapem raportowal
     czysto, a commit, ktory blogoslawil, ladowal nieswiezy (REV-20260807-068
     F1). Skrot tresci jest dowodliwy przed commitem i niezmieniony przez
     commit, wiec jeden przebieg dowodzi wlasnosci po obu stronach granicy. -->

- Data odświeżenia: **2026-08-11**. Stan plików, który ten blok opisuje, jest
  w znaczniku maszynowym powyżej — celowo NIE powtórzony tutaj, bo dwie
  kopie tej samej informacji to dwie rzeczy, które mogą się rozjechać.
  `gen-cron.sh` **v4.30**, `snapsend.sh` **v2.72**, `snapget.sh` **v2.69**,
  `delsnaps.sh` **v1.29**, `check-snap-age.sh` **v2.3**.

  **CO JEST WDROŻONE, A CO NIE — stan na dziś.** To jest jedyne miejsce, gdzie
  ten podział ma być aktualny; szczegóły każdej pozycji leżą w artefaktach
  kanonicznych i NIE są tu powtarzane, bo druga kopia zmiennych szczegółów
  rozjeżdża się dokładnie tak, jak rozjechał się ten blok (REV-20260809-078).

  | rzecz | stan | gdzie leży prawda |
  |---|---|---|
  | Etap 2.1 — jeden sufiks nazwy na PRZEBIEG | **wdrożone** | suita `runsuffix`, dowód na żywo w sekcji 5 |
  | Etap 2.2 — dokładnie JEDNA deklaracja rekursji na wywołanie | **wdrożone** | suita `recursion` |
  | Etap 2.3 — długie opcje `--recursive=atomic\|flat\|no` | **wdrożone** w `snapsend.sh`/`snapget.sh` (+ `--recursive` ≡ `-R` w `delsnaps.sh`/`check-snap-age.sh`) | suita `recursion` |
  | Etap 3 — ZAMROŻENIE SILNIKA | **wdrożone i domknięte** | `docs/project/ENGINE-FREEZE.md`, egzekwowane przez `./test/impact.sh` |
  | Etap 4 — `gen-cron.sh --reconcile` | **wdrożone i domknięte** (REV-071…074) | suita `reconcile`, `docs/testing/RECONCILE-*.md` |
  | Etap 5 — GRANICA profilu | **wdrożona jako kod PRODUKCYJNY** `lib-profile.sh` | REV-073/076/077, suita `profiles` |
  | Etap 5 — RENDERER profilu (`profile_render_templates`/`profile_render_fragment`, namespace `profile__<nazwa>__<szablon>`) | **wdrożony** w `lib-profile.sh`, suita `profiles` 55/55; nazwa profilu i szablonu nie może nieść `__` (REV-081 F1: kodowanie nie było różnowartościowe) | plasterek B1, krok 1 |
  | Etap 5 — RUNTIME profilu (`zfs-backup.sh` czyta profil zamiast zaszytych szablonów) | **wdrożony** (B1 krok 2): `ensure_cron_config` i `emit_client_sections` czytają wyrenderowany profil, pre-GFS **odmawia** zamiast konwertować; suita `zfsbackup` 333/333, kontrola negatywna 14 pada | `docs/design/slice-b1-plan.md` |
  | jednokierunkowe przekazanie profilu (PROFIL → generuj RAZ → CONFIG v4 → prawda wykonawcza) — re-aktywacja i przełączenie endpointu NIE regenerują polityki | **wdrożone; REV-089/090/091 ZAMKNIĘTE; Gate 3 DOMKNIĘTY przez recenzenta 2026-08-10** (Faza 3 planu prac, `docs/discussions/GATE3-PHASE35-REVIEWER-RESOLUTION-2026-08-10.md`): pierwsza aktywacja generuje z profilu jak dotąd; re-aktywacja bierze ZAINSTALOWANĄ sekcję za bazę i odświeża w miejscu wyłącznie dwa pola topologiczne (`src`, `flags`), zostawiając politykę, `pair_label`, `notify` i ręczne dopiski nietknięte; sekcje `[prune:]` nie niosą ŻADNEGO pola topologicznego, więc własna sekcja prune nie jest ruszana w ogóle (oba kształty: drabina GFS w trybie backup i per-dataset w trybie sync); `migrate-profile` przekazuje flagę pierwszej aktywacji jawnie, bo regeneracja z profilu jest całym sensem tej komendy | REV-20260809-089 + REV-20260810-090, suita `zfsbackup` sekcje 49/50 (339/339), kontrole negatywne wobec `8d0dc243…` → 328/333 i wobec `c5f04ab0…` → 335/339 |
  | zwykła re-aktywacja NIE wymaga profilu i niczego z niego nie dokleja | **wdrożone, ZAMKNIĘTE** (REV-090, dwa P1): profil jest teraz zależnością LENIWĄ, bramkowaną na granicy, która naprawdę coś generuje — `client_section_plan()` liczy plan wyłącznie z zainstalowanego configu i rekordu klienta (żaden profil nie jest czytany, żeby odpowiedzieć „czy profil jest potrzebny"), a `ensure_cron_config()` dostała parametr `needs_profile` (domyślnie 1), pod który schowano `load_active_profile` ORAZ całą pętlę doklejania szablonów. Skutek: relacja utworzona z profilu `P` daje się re-aktywować po tym, jak `P` zniknął, został przemianowany albo przestał się walidować; a szablon świadomie usunięty przez operatora nie wraca przy odświeżeniu endpointu | REV-20260810-090 (ZAMKNIĘTY) + REV-20260810-091, suity `zfsbackup` sekcje 50/51 (13 asercji przez PRAWDZIWY `cmd_activate_client()`) |
  | zwykła re-aktywacja niczego nie tworzy, nie naprawia, nie normalizuje ani nie migruje | **wdrożone, ZAMKNIĘTE** (REV-091, dwa P1): po REV-090 `ensure_cron_config()` NADAL robiła dwie rzeczy bezwarunkowo — doklejała ogólnokonfiguracyjne progi `[excluded:]` (F1) i odmawiała na configu pre-GFS (F2) — więc `needs_profile=0` wcale nie znaczyło „tylko topologia". Oba schowane pod tę samą bramkę. Sama DETEKCJA pre-GFS dalej biegnie bezwarunkowo (`PROFILE_GFS` czytają dalej kształt prune i podsumowanie aktywacji), warunkowa jest wyłącznie ODMOWA — i nadal pada wszędzie tam, gdzie polityka naprawdę jest generowana na host legacy. Skutek: host pre-GFS można odświeżyć endpointowo bez wymuszania `migrate-profile`, a próg `[excluded:]` usunięty świadomie przez operatora nie wraca | REV-20260810-091 (ZAMKNIĘTY), suita `zfsbackup` sekcja 51 (7 asercji) |
  | dodanie NOWEJ relacji nie zmienia polityki relacji już zainstalowanych | **wdrożone; REV-092 ZAMKNIĘTY, Gate 2 DOMKNIĘTY przez recenzenta 2026-08-10** (był ponownie otwarty): `[excluded:]` NIE jest sekcją niczyją — `gen-cron.sh` skleja wszystkie w jeden ogólnokonfiguracyjny `PROTECT_FLAGS` i dokleja go do KAŻDEJ generowanej linii prune w pliku. Doklejenie brakującego progu przy dodawaniu nowej relacji przepisywało więc realne polecenie prune relacji, które były tam pierwsze. Nowe `config_has_relationship_policy()` + czwarty parametr `global_policy_mode` (`auto`/`always`): świeży CONFIG dostaje domyślne progi, jawna migracja (`migrate-profile`) może je położyć celowo w podglądanej transakcji, a addytywny CREATE do zapełnionego CONFIG-u dziedziczy stan `[excluded:]` dokładnie taki, jaki jest, i niczego nie naprawia — tylko ostrzega, wymieniając brakujące progi | REV-20260810-092, suita `zfsbackup` sekcja 52 (6 asercji na RENDEROWANEJ linii `delsnaps.sh`, nie na tekście configu) |
  | Faza 3.5 — bezprefiksowy create/pasywny `-e`/jednoseriowa drabina GFS w native CONFIG | **wdrożone przez implementera, czeka na recenzenta**: nowa `resolve_field_or_omit()` (owija istniejący rozdzielacz stanów `resolve_field()`: nigdzie-nierozwiązane vs rozwiązane-ale-puste) zastąpiła `require_field` dla `prefix` i `gfs_pattern` — pominięcie pola w całym łańcuchu dziedziczenia jest teraz świadomym „bez prefiksu"/„bez wzorca GFS", obecne-ale-puste dalej odmawia bez zmian (`c90f6d1`). `pattern` NIE został ruszony. Silniki (`snapsend.sh`/`snapget.sh`/`delsnaps.sh`) już wcześniej akceptowały pustą wartość identycznie jak brak flagi — zweryfikowane czytaniem kodu, nie zmienione | `docs/discussions/PHASE35-IMPLEMENTATION-CLAUDE-2026-08-10.md`; suita `gencron` (`test/run.sh`) 67/67, kontrola negatywna wobec `8693b4e3…` → 63/67 |
  | Etap 5 — wiązanie PER-ŹRÓDŁO (jedna relacja, różne profile dla różnych źródeł) | **NIEwdrożone** — brak kompozytora; namespace jest gotowy, żeby to umożliwić | `docs/discussions/PER-SOURCE-PROFILE-SCENARIOS-2026-08-09*.md` |
  | domyślny backup ogranicza retencję ŹRÓDŁA (nie zostawia snapshotów źródła bez ograniczeń) | **CZĘŚCIOWO — REV-102 OPEN**: krok 2 (local PUSH `cmd_local_backup`) wdrożony — osobna `[prune:<root>]` z tej samej drabiny, non-recursive, tylko `automated_`; grant-guard `assert_source_prune_grant()` (fail-closed na braku `destroy`/błędzie ssh, bez poszerzania) **wylądował + test** (sekcja 55). Rozdział SOURCE/TARGET jest **profile-agnostyczny** (REV-106 IMPLEMENTED): rodzina SOURCE wyprowadzana z szablonów RZECZYWIŚCIE referowanych przez `use_template` profilu (nie z konwencji `keep_*`), fail-closed na braku; jeden współdzielony helper reużywalny przez remote-PULL. Krok 4 (local PUSH) **dowiedziony na żywym ZFS 2026-08-11** (pve1 192.168.28.9, throwaway lab): `delsnaps.sh -G` bez `-R` skasował `automated_hourly_a/b` źródła, zostawił `_c` (survivor GFS), `manual_keepme` (wzorzec) i `child@automated_hourly_child1` (non-recursive) — pełny transkrypt w design doc. Odłożone: krok 3 (remote PULL emisja w `emit_client_sections`, bramkowana grant-guardem, reużyje splitu — z nim domyka się remote-PULL połowa kroku 4), krok 5 (migracja istniejących CONFIG) | `docs/discussions/PHASE5-SOURCE-RETENTION-DESIGN-2026-08-11.md`; suity `localbackup` 42/42, `zfsbackup` 368/368 |
  | preflight nakładania pokrycia (create-only preset odmawia relacji, której ścieżka jest rodzicem/dzieckiem/dokładnym trafieniem cudzego pokrycia; fail-closed też na rekordzie nie do odczytu/parsowania; sprawdzane PRZED prawdziwym `seed`, nie tylko przy `activate-client`) | **wdrożony i dowiedziony na żywo (2026-08-09)**, kod: `coverage_conflicts`/`assert_no_coverage_overlap` w `zfs-backup.sh`, wywoływany z `cmd_seed()` i `emit_client_sections()`; suita `zfsbackup` sekcje 45/46/47/48 | REV-20260809-083/084/085/086; dowód na żywo na metropolis pve1/pve2: druga, różnie nazwana relacja (bez własnego `add-client`, dziedzicząca manifest peera pierwszej) trafia realnie do `cmd_seed()` i zostaje odrzucona z dokładnym nazwaniem konfliktu, PRZED jakąkolwiek mutacją; CONFIG/crontab/poddrzewo ZFS bit-w-bit bez zmian — pełny transkrypt w odpowiedzi REV-086 |
  | jednohostowa orkiestracja wysokopoziomowa (`--target`/`--source`, add-local) | **NIEwdrożone** — dyskusja projektowa | `docs/project/DEPLOY-SEQUENCES.md`, `docs/design/local-relation-contract.md` |
  | restore | **NIEwdrożone**, nie zaczęte | — |

  Najważniejsze dziś rozróżnienie — jedno zdanie, nie powtarzane niżej
  (REV-20260809-082 F3): **`zfs-backup.sh` czyta profil przy generowaniu
  configu, ale nikt profilu nie WYBIERA.** Jest jeden wbudowany preset i
  używają go wyłącznie nowe enrolmenty; żaden host we flocie nie został na
  niego przeniesiony i decyzja właściciela z 2026-08-09 mówi, że profil
  generuje kandydata JEDEN RAZ, po czym prawdą wykonawczą jest CONFIG v4, a
  nie profil.

  Stan wątków recenzji jest GENEROWANY i nie jest tu przepisywany:
  `docs/internal/reviews/REVIEW_LEDGER.md` oraz `docs/project/OPEN-THREADS.md`
  (`./test/reviewctl.sh --generate`). Dostawy bez recenzji:
  `docs/project/DELIVERIES.md`.

- **Stan poprzedni, 2026-08-07 (zachowany jako historia, NIE jako opis
  dzisiejszego drzewa).** Stan plików, który ten blok opisywał, jest
  w znaczniku maszynowym powyżej — celowo NIE powtórzony tutaj, bo dwie
  kopie tej samej informacji to dwie rzeczy, które mogą się rozjechać.
  `gen-cron.sh` **v4.30**, `check-snap-age.sh` **v2.2**.

  **Etap 0 WYKONANY na pve0**: sześć datasetów gości objętych kopią
  (VM 104 `debian` — **działająca, wcześniej bez żadnej kopii** — VM 103,
  VM 107 ×3, CT 105). Granty `zfs allow` nadane per dataset, pierwsze
  snapshoty wykonane, wszystkie trzy linie monitora `rc=0`. Blok crontaba
  29 → 33 linie, identyczny z renderem configu.

  **`gen-cron.sh --install` naprawione dla konta delegowanego**: blokada
  instalacyjna przeniesiona z `/var/run` (tylko root) do współdzielonego
  katalogu projektu, z tą samą dyscypliną co `lib-cron.sh`. Wcześniej konto
  będące właścicielem zarządzanego bloku **nie mogło go zainstalować**, a
  komunikat błędu twierdził nieprawdziwie, że trwa inny `--install`.

  **Pliki blokad naprawiane i audytowane, nie tylko ich katalog.** `deploy.sh`
  nadawał katalogowi blokad `2775 root:zfsalert` i na tym audyt się kończył —
  ale katalog setgid nadaje plikowi tylko **grupę**, nie **tryb**. Trzy z
  czterech hostów miały blokadę `0644 root`, przez którą konto delegowane nie
  mogło w ogóle zapisać własnego crontaba, podczas gdy `--check-only`
  raportował katalog jako poprawny. Naprawione w `cron_lock_files_repair()` i
  `cron_lock_files_audit()`; wszystkie cztery hosty doprowadzone do stanu
  poprawnego.

  Audyt sprawdza **oba** warunki: wspólna grupa **i** zapis grupy (REV-062).
  Wcześniej pilnował tylko trybu, więc plik `0664` należący do grupy `root`
  przechodził, choć konto delegowane i tak nie mogło go otworzyć — audyt nie
  weryfikował tego, co gwarantuje jego własna naprawa.

  **Świeżość tego dokumentu jest teraz sprawdzana maszynowo** przez
  `./test/impact.sh --verify` (znacznik powyżej). Obowiązek `project-status`
  przestał być prośbą.

  **Model rekurencji: ZAMKNIĘTY I WDROŻONY.** `[dataset:]` przyjmuje pole
  `recursive = no | flat | atomic`, które steruje **wszystkimi trzema** liniami
  generowanymi przez sekcję — transferem, prune'em inline i monitorem. `-r`/`-R`
  we `flags` jest błędem krytycznym, sprawdzanym równoważnie z `getopts` (formy
  sklejone `-Rv`, `-rZ` odrzucane; argument opcji, np. `-m R-daily_`, nie jest
  mylony z flagą). Silnika nie ruszano — zmiana dotyczy generatora, walidatora
  i `cron2conf.sh`.

  **Migracja floty WYKONANA 2026-08-07 14:42** przez
  `gen-cron.sh --migrate-recursion` na 192.168.11.11 (jedyny host, który jej
  wymagał). Crontab md5 **bez zmian**, właściciel i prawa zachowane, kopia
  rollback zostawiona, render identyczny z zainstalowanym blokiem.
  **Żaden zarządzany config we flocie nie niesie już `-r`/`-R` we `flags`** —
  zweryfikowane detektorem na wszystkich czterech hostach.

  **Monitor: wiek z `creation` datasetu** (REV-056, **ZAMKNIĘTA przez
  recenzenta**). Gdy nic nie pasuje do wzorca, wiek liczony jest z daty
  utworzenia datasetu i przechodzi przez tę samą drabinkę progów — świeża
  maszyna czyta się OK, trzydniowa bez kopii nadal CRITICAL. Nieodczytany
  znacznik czasu to UNKNOWN, nigdy zmyślony wiek (naprawione po obu stronach,
  łącznie z istniejącą wcześniej ścieżką pasującego snapshotu).

  **Kontrola migracji niezależna od UID-u** (REV-058, **ZAMKNIĘTA przez
  recenzenta**, `ebe951c`). Configi są `root:root 0644` w `/etc`, więc migrację
  zapisuje root — a zarządzany blok należy do konta delegowanego. Kontrola
  szuka teraz bloku po jego własnej linii `# Source:` u wszystkich użytkowników
  i **odmawia przed zapisem** przy każdej niepewności: nieczytelny crontab,
  nieczytelna lista użytkowników, dwa pasujące bloki.

  **Nowy dokument `docs/discussions/ENGINE-FINALIZATION-PROFILES-RESTORE-2026-08-07.md`
  i moja odpowiedź `ENGINE-PROFILES-RESTORE-CLAUDE-ANSWERS-2026-08-07.md` to
  DYSKUSJA PROJEKTOWA, nie stan wdrożony.** **Na dzień 2026-08-07** nic z długich
  opcji rekursji, profili ani restore nie było zaimplementowane. Zdanie jest
  prawdziwe o tamtym dniu i o żadnym późniejszym: długie opcje rekursji weszły
  w Etapie 2.3, granica profilu jest kodem produkcyjnym od REV-076/077, restore
  nadal nie istnieje. Aktualny podział — w bloku bieżącym na górze pliku.

  Otwarte, oddzielone od pracy już wykonanej: patrz sekcja 6 oraz
  `docs/project/OPEN-THREADS.md`. W skrócie — u recenzenta werdykt dla REV-057;
  u właściciela decyzje o
  `docs/OPS_MONITORING.md`, PR #4 oraz sposobie ogłaszania się równoległych
  sesji.

- **Stan poprzedni, 2026-08-07 (nieaktualny, zachowany dla historii):** commit
  `121892f`, `gen-cron.sh` v4.27 — model rekurencji przebudowany, ale migracja
  floty jeszcze **niewykonana**, a wdrożony na 192.168.11.11 generator odmawiał
  obsługi własnego configu tego hosta. Oba te zdania przestały być prawdziwe
  2026-08-07 o 14:42.
- Poprzednie odświeżenie, 2026-08-07: **pakiet hard-disable ZAMKNIĘTY przez
  recenzenta** (`REV-20260807-052`, APPROVED — zero otwartych znalezisk; zamknięte
  także REV-049, REV-050 i REV-051). Zbudowany i zweryfikowany na żywo
  2026-08-06 wieczorem: **hard-disable ZBUDOWANY
  I ZWERYFIKOWANY NA ŻYWO** (ADR-0012 `DISABLED`). Bramka `zfs-pair-gate.sh` po
  stronie peera, wpinana automatycznie przy `--join` (wymuszone polecenie w
  `authorized_keys` + własny katalog stanu relacji), orkiestracja
  `disable-client`/`enable-client` w kolejności z ADR (pauza lokalna → peer →
  odczyt zwrotny; enable odwrotnie), oraz `check-snap-age`/monitor bez zmian.
  **Właściwość, dla której to powstało, potwierdzona na żywo:** przy blokadzie
  ręcznie napisany `snapget` BEZ żadnej etykiety `-L` jest odrzucany przez
  peera (`PAIR_DISABLED`) — czego pauza logiczna z definicji nie potrafi.
  Kampania na dwóch prawdziwych relacjach (druga na osobnym LXC) znalazła i
  naprawiła trzy defekty: wyciek logu na stderr wywołującego (`6914c11`),
  wybór logu po obecności zamiast po dostarczeniu (`0d6dbf8`, REV-047),
  własność `authorized_keys` przy podmianie atomowej — lockout całego konta
  (`0058834` + fail-closed `209231c`, REV-049), plus własność katalogu stanu
  (`8f6f8c2`) i mylącą diagnostykę `verify-endpoint` (`8de89e1`).
  Suity: `pairgate` 45/45 (nowa), `zfsbackup` 291/291, reszta grafu zielona.
  Pełny materiał dowodowy: `docs/project/HARD-DISABLE-CAMPAIGN-PLAN.md`.
  OGRANICZENIE ZAPISANE WPROST: klucz relacji może sam zdjąć swoją blokadę
  (decyzja właściciela), więc `DISABLED` zatrzymuje automat, pomyłkę i ręczne
  polecenie, ale nie świadomego posiadacza klucza; każde zdjęcie trafia do
  logu na peerze.
- Data odświeżenia: **2026-08-06** (dodatkowo: **REV-20260804-045 w toku** —
  właściciel potwierdził zakres „tylko pauza logiczna"; plasterki 1-3 na main:
  `pause-client`/`resume-client` + stan w `/var/lib/zfs-snapshot-all/
  relationships/`, bramka `-L` w snapget/snapsend (SKIPPED przed jakąkolwiek
  pracą, status statystyk `skipped_paused`), pole `pair_label` w gen-cron
  (linia transferu + monitory; prune celowo NIEbramkowany — retencja chodzi
  dalej podczas pauzy) i `check-snap-age -L` (pauza = OK z nazwanym powodem,
  nie strona). JAWNE OGRANICZENIE, część kontraktu: ręczne uruchomienie BEZ
  `-L` nie jest blokowane — pauza logiczna to przełącznik orkiestracji, nie
  granica bezpieczeństwa; twardy disable po stronie peera pozostaje
  niezaimplementowany. **Plasterek 4 wykonany na żywo tego samego dnia:**
  rollout floty okazał się no-opem (wszyscy klienci na jedynym kolektorze
  byli `state=removed`; `pair_label` wejdzie naturalnie przy najbliższym
  prawdziwym `activate-client`), a test izolacji przeszedł na dwóch
  zbudowanych do tego relacjach (pa ← prawdziwy pve2, pb ← throwaway LXC
  wzorem Gate G): dokładne wygenerowane linie crona uruchamiane jako konto —
  pauza pa = SKIPPED/`skipped_paused`/zero snapshotów u źródła, pb
  transferuje normalnie, monitor pa = OK-paused (nie strona, nie cisza),
  sumy config+crontab bajt w bajt przez cały cykl, resume = przyrostowe
  nadrobienie. Kampania znalazła i naprawiła DWA realne błędy: zamek
  lib-cron tworzony z umaską roota blokował konto na zawsze (`62e190d`,
  test/cron sekcja V, 124/124) i alias known_hosts chown-owany po
  `LOCAL_USER` zamiast po ścieżce konta (`39e4ed2`, test/zfsbackup 41b,
  279/279). Pełny dowód: `docs/internal/reviews/responses/REV-20260804-045.md`.
  Znane ograniczenie projektowe potwierdzone na żywo: JEDNA relacja na parę
  hostów (drugi klient na ten sam adres peera splata manifesty po obu
  stronach; strażnik U11 poprawnie odmówił). Po
  odpowiedzi na **REV-20260806-046** —
  werdykt o dostarczalności alertów orzekał zdrowie z braku dowodów; F1/F2/F3
  IMPLEMENTED, nowa suita `alertmail`, szczegóły niżej; wcześniej: po REV-034
  w całości, po REV-033
  plasterkach 1-10 (WSZYSTKIE dziesięć z pierwotnego planu) + korekcie U9 +
  łatki T3/U2/T5 z `ENROLMENT-AGREED-2026-08-02.md`, po REV-035, po REV-036
  w całości + wszystkie follow-upy, po ad hoc `--pause`/`--resume` poza
  kolejką recenzji (przeróbka na tryb blokowy), po REV-20260804-037 w
  całości, REV-20260804-038 w całości, REV-20260804-039 w całości (F1
  disputed-with-evidence, F2/F3/F4 zamknięte), REV-20260804-040 w całości
  (UID-binding), REV-20260804-041 w całości (transakcja last-client),
  po REV-20260804-042 Gate G i Gate I zamknięte NA ŻYWO (owner wybrał
  budowę labu zamiast NEEDS-DISCUSSION), po REV-20260804-043 — P1
  korekta znaleziona przez recenzenta PRZED wdrożeniem, naprawiona i
  ponownie zweryfikowana na żywo tego samego dnia, i po
  **REV-20260804-044 — werdykt końcowy: ACCEPTED**, cała kampania Gates
  A-J zamknięta bez odpowiedzi implementera)
- Zweryfikowano przeciw: **commit niosący ten dokument** — dokument nie może
  podać własnego SHA, więc ta linia jest konwencją, nie niedopatrzeniem
- Ostatni stan floty potwierdzony na żywo: **2026-08-06 ~16:30**, CZTERY
  osiągalne hosty (metropolis pve1/pve2, 11.x pve0/pve1) na `d859af5`,
  `audit clean` na każdym, kolejki poczty puste. Po drodze audyt złapał na
  11.11 pve1 **brak `/var/lib/zfs-snapshot-all/locks`** — ta sama usterka,
  którą 2026-08-04 znalazł na pve0 (patrz niżej), naprawiona tak samo:
  pełny `bash deploy.sh` (narzędzie-właściciel katalogu, nie ręczny
  `mkdir`), katalog powstał `2775 root:zfsalert`, sumy md5 obu crontabów
  (root `976e16cd…`, zfsbackup `70e7bc0b…`) identyczne przed i po.
- Poprzedni stan floty: **2026-08-04 23:44**, trzy osiągalne
  hosty na `a567328`, `audit clean` na każdym, kolejki poczty puste.
  **Zastrzeżenie (REV-20260806-046):** tamten `audit clean` obejmował werdykt
  alertów sprzed poprawek — dowodził obecności MTA i pustej kolejki, NIE
  zdolności dostarczenia. Nie używać go jako dowodu, że poczta z tych hostów
  wychodzi; dowodem dostarczalności pozostaje wyłącznie próbka `--test-mail`
  z obserwacją kolejki (i tak ograniczona do „opuściło ten MTA")
- **Kampania enrolmentu (Gates A-J, REV-037…044): ZAMKNIĘTA.** Recenzent
  ACCEPTED w `docs/internal/reviews/REV-20260804-044-FINAL-AJ-VERDICT.md` —
  wszystkie dziesięć bramek PASS, REV-037 przez REV-043 CLOSED, zero
  otwartych findingów blokujących wydanie w tej kampanii. Odpowiedź
  implementera nie jest wymagana, chyba że kolejny commit zmieni
  zrecenzowane zachowanie lub unieważni zapisany dowód.
- **Werdykt o dostarczalności alertów (2026-08-04).** Do tej pory `deploy.sh`
  sprawdzał wyłącznie `command -v mail`, co dowodzi istnienia *klienta*, nie
  zdolności dostarczenia. Na Proxmoksie nie było tego widać, bo instalator PVE
  konfiguruje postfixa; na czystym Debianie wdrożenie kończyło się sukcesem na
  hoście, którego alerty nigdy nie wychodzą — ta sama klasa co „quiesce zwrócił
  rc=0 i nic nie zamroził". Nowe `mta_present`/`mta_name`/`mail_queue_depth`/
  `alert_delivery_verdict`: werdykt w KAŻDYM trybie, w tym `--check-only`, plus
  sprawdzenie kolejki po teście maila (dotąd „wyślij i miej nadzieję" —
  instrukcja kazała operatorowi zajrzeć do skrzynki ręcznie).
  **Postfix celowo nietykany** — decyzja właściciela: to zmiana ogólnohostowa,
  a host z działającym exim4/relayem straciłby konfigurację; wybór smarthosta i
  poświadczeń SMTP jest per instalacja. Ta sama zasada co nietykanie cudzych
  grantów ZFS i cudzych bloków crona. Świadomie NIE wnioskujemy o zdolności
  wysyłki na zewnątrz z `main.cf`: debianowe „Local only" ustawia
  `inet_interfaces=loopback-only`, co blokuje ODBIERANIE i nic nie mówi o
  wysyłce — jedynym uczciwym sygnałem jest kolejka po realnej próbie.
  **REV-20260806-046 (2026-08-06, P1): pierwsza wersja werdyktu sama orzekała
  zdrowie z braku dowodów** — dokładnie ta klasa, którą miała eliminować.
  Trzy findingi, wszystkie IMPLEMENTED, po jednym commicie na finding:
  1. **F2 (`c668b51`):** nieczytelna kolejka logowała „unverified" ale
     zwracała 0, więc host, którego kolejki nikt nie umiał obejrzeć, kończył
     `audit clean`. Do tego `postqueue`, który sam padł, wpadał w awk-owe
     `END{print 0}` i czytał się jako PUSTA kolejka, a nienumeryczne wyjście
     prześlizgiwało się obok `[ -gt 0 ]` do zdrowej gałęzi. Wszystkie trzy
     kształty teraz fail-closed: UNVERIFIED = `warn()` = `PROBLEMS` =
     `--check-only` wychodzi niezerowo.
  2. **F1 (`b4de04a`):** pusta kolejka drukowała „this host can send" —
     pewny pozytyw wywiedziony z nieobecności zakolejkowanej pracy, przy
     zablokowanym porcie 25 tak samo jak przy sprawnym relayu. Teraz:
     „prerequisites OK; actual delivery UNVERIFIED in this run".
  3. **F3 (`d859af5`):** blok test-maila wyjęty do `alert_delivery_probe()`;
     status `mail(1)` jest sprawdzany (był fire-and-forget), a opróżniona
     kolejka twierdzi tylko tyle, ile trzysekundowe spojrzenie dowodzi:
     „the message LEFT THIS MTA; recipient delivery is NOT independently
     verified" zamiast „accepted and dispatched it".
  Nowa suita **`test/alertmail/run.sh` 18/18** (zarejestrowana w grafie):
  kwartet funkcji na podstawionych `mail`/`postqueue`/`sleep` + wyjęty
  z deploy.sh oryginalny `warn()`, każdy przypadek sprawdza zgodność kodu
  powrotu, licznika `PROBLEMS` i emitowanego brzmienia; przypadki regresyjne
  F1/F2 padają na zrecenzowanej bazie `a567328` (`DEPLOY_SRC=` wspiera
  uruchomienie suity przeciw dowolnej wersji deploy.sh).
  **Dwa znaleziska produkcyjne — oba NAPRAWIONE i zweryfikowane na żywo
  2026-08-04 23:44, na polecenie właściciela wydane po zgłoszeniu.** Nowy
  werdykt zwrócił się dwukrotnie przy pierwszym uruchomieniu:
  1. **metropolis pve2: `/etc/aliases.db` nie istniał.** Sam `/etc/aliases`
     leżał tam od 2023-03-22, ale skompilowanej bazy nigdy nie zbudowano, więc
     postfix odbijał każdą przesyłkę idącą przez alias z `(alias database
     unavailable)` — w kolejce siedział bounce od 09:37 tego dnia. To nie był
     jeden zablokowany list: **każdy alert kierowany aliasem na tym hoście
     lądował w kolejce zamiast dojść.** `newaliases` + `postqueue -f`;
     zaległa wiadomość faktycznie doszła (`status=sent (250 2.0.0 Ok: queued
     as 44CB32BE0FB1)`, relay `lurk.com.pl[89.161.153.182]:25`), kolejka pusta.
  2. **pve0: brak `/var/lib/zfs-snapshot-all/locks`** (katalog nadrzędny i
     `notify-state` były na miejscu — brakowało wyłącznie tego jednego).
     Znaczyło to, że `lib-cron.sh` odmówiłby KAŻDEGO zapisu crontaba na tym
     hoście; nic tego akurat nie robiło, więc stan był niemy. Naprawione przez
     zwykły `bash deploy.sh` — narzędzie będące właścicielem tego katalogu, nie
     ręczny `mkdir` — powstał z uprawnieniami identycznymi jak na pozostałych
     hostach (`2775 root:zfsalert`). Ze względu na incydent z mutacją crontaba
     na TYM hoście (patrz historia `$0` vs `BASH_SOURCE[0]`) sumy kontrolne
     zabezpieczone przed i po: `root` `a52e3b31…` → `a52e3b31…`, `zfsbackup`
     `6b9b15c4…` → `6b9b15c4…`, 8 linii zadań bez zmian. Bajt w bajt.

  Stan floty po naprawach: `locks` OK, `aliases.db` OK, kolejka 0 i
  `audit clean` na wszystkich trzech osiągalnych hostach. Obie usterki należą
  do tej samej rodziny co reszta historii tego projektu — **nie awarie, tylko
  cisza tam, gdzie powinien być sygnał**; żadna nie zgłaszała się sama, dopóki
  `--check-only` nie zaczął pytać o dostarczalność alertów.
- **Recenzje przeniesione do `docs/internal/reviews/` (2026-08-04).** `git mv`,
  więc historia zachowana; 109 odwołań w 12 plikach przepisanych, w tym
  protokół w `CLAUDE.md`, `AGENTS.md` i `docs/AI_PROJECT_RULES.md`. Powód:
  `docs/` zawierało 52 pozycje archiwum procesu recenzyjnego wobec 5 plików
  dokumentacji właściwej — ktoś obcy otwierał katalog dokumentacji i widział
  rejestr wewnętrzny. Żadne odwołanie w `.sh` nie było ścieżką wykonywaną,
  wyłącznie komentarze, więc zmiana jest bezbehawioralna.
  **UWAGA DLA RECENZENTA:** recenzent publikuje `REV-*.md` przez commit gita.
  Nowa ścieżka to `docs/internal/reviews/` — plik wrzucony pod starą
  `docs/reviews/` odtworzy katalog i rozjedzie kanał na dwie lokalizacje.
- **Przygotowanie do publikacji (2026-08-04): licencja MIT + usunięcie wartości
  jednej instalacji z `deploy.sh`.** Trzy rzeczy, które sprawiały, że pakiet
  nadawał się do użytku wyłącznie dla autora:
  1. **Brak `LICENSE`** — formalnie nikt nie miał prawa tego użyć. Dodany MIT.
  2. **`REPO_URL` zaszyty na `AdalbertKing/zfs-snapshot-all`** — to był realny
     defekt, nie kosmetyka: KAŻDY fork wdrażał hosty, które co godzinę
     ciągnęły cudzy `main`. Własne commity nigdy nie dotarłyby na własne
     maszyny, a zmiana z upstreamu lądowałaby u nich bez recenzji. Teraz
     wyprowadzany z `git remote get-url origin` checkoutu, w którym leży sam
     `deploy.sh` — jedyna odpowiedź poprawna zarówno dla upstreamu, jak i dla
     forka. Zweryfikowane w trzech przypadkach: prawdziwy checkout (zwraca
     dokładnie dotychczasową zaszytą wartość, więc **istniejące hosty nie
     widzą żadnej zmiany**), katalog bez gita (fallback), nadpisanie ze
     środowiska (wygrywa).
  3. **`NOTIFY_EMAIL` domyślnie na adres autora** — świeża instalacja cicho
     wysyłałaby alerty obcej osobie, a operator nigdy by się nie dowiedział,
     że coś się zepsuło. Domyślnie `root` (poczta lokalna, zawsze
     dostarczalna). Bezpieczne dla floty: `/etc/zfs-alert.conf` istnieje na
     wszystkich hostach (sprawdzone na żywo) i nigdy nie jest nadpisywany, a
     jego `ZFS_ALERT_EMAIL` wygrywa w czasie działania.

  `BACKUP_USER_DATASETS="rpool/data rpool/ROOT/pve-1"` **celowo zostawione** —
  wstępna ocena mówiła, że to wartość jednej instalacji, pomiar ją obalił:
  `rpool/ROOT/pve-1` jest identyczne na trzech hostach o różnych nazwach
  (pve0, pve1, pve2), czyli to konwencja instalatora PVE, nie lokalna ścieżka.
  Dopisany komentarz wyjaśniający, skąd ta wartość, plus wskazanie
  `--datasets=` dla hostów spoza Proxmoksa. Naprawiony też placeholder
  `# Author: [Your Name]` w `snapsend.sh`/`snapget.sh`.

  Testy: 8 lokalnych suit wymaganych przez graf — `join` 82/82,
  `joinmanifest` 10/10, `joinremote` 8/8, `twins` 24/24, `draftscope` 26/26,
  `pause` 74/74, `quiescehelper` 119/119, `selfupdate` 28/28 (7 SKIP);
  łącznie 371, zero błędów. Suity wymagające roota/ZFS (`snapsend`,
  `scenarios`) i drugiego hosta (`remote`) są przez graf wywołane zmianą w
  `snapsend.sh`, ale ta zmiana to **wyłącznie jedna linia komentarza**
  (nagłówek autora) — co potwierdza niezależnie zielony wynik `twins`,
  normalizującej komentarze.
- **Scalenie `snapsend.sh`+`snapget.sh` w jeden silnik: ROZWAŻONE I ODRZUCONE
  (2026-08-04).** Zamiast tego dodano alarm dryfu (`test/twins`, suita niżej,
  kontrakt `twin-functions` w `test/deps.conf`). Powód odrzucenia, zmierzony a
  nie oszacowany: łatwa deduplikacja jest już zrobiona (`lib-zfs-snap.sh` ma 81
  funkcji i 2527 linii — więcej niż każdy z tych skryptów osobno), a to co
  zostało to nie duplikacja tylko **rozbieżność** (`process_dataset` różni się w
  450 z ~550 linii, `find_conflicting_snapshots` w 53 z 57 — push czyta lokalnie
  i pisze zdalnie, pull odwrotnie, więc kontrole bezpieczeństwa siedzą po
  przeciwnych stronach). Kluczowe ryzyko: pięć funkcji naprawdę bliskich
  identyczności ma IDENTYCZNE sygnatury i nazwy parametrów (`src_dataset`,
  `tgt_dataset`, `remote_user`, `remote_host`), a różnią się wyłącznie tym,
  której stronie doczepiane są współrzędne zdalne. Scalenie wymaga parametru
  kierunku, którego jedyny tryb awarii jest cichy i **fail-open** przy
  wykrywaniu wspólnej bazy — a `test/snapsend` jest z założenia LOCAL MODE ONLY
  (`validate_remote_host()` słusznie przerywa przy tym samym `/etc/machine-id`),
  więc suita, która miałaby to złapać, strukturalnie nie może: przy pustych
  `remote_user`/`remote_host` obie gałęzie zwijają się do tego samego wywołania.
  Uzasadnienie „scalmy przed tuningiem VPN/buforów" z 2026-07-20 również
  wygasło: pokrętła (`BUFFER_SIZE`, `MEMORY`, `BWLIMIT_FLAG`, `COMPRESS_PIPE`)
  są już wspólnymi zmiennymi w obu plikach, różni się tylko kształt potoku
  (~6 linii), a rozmiar bufora zmierzono jako nieistotny.
- Ostatnia zmiana zachowania produkcyjnego: **REV-20260804-042/043 —
  Gate G i Gate I kampanii enrolmentu zamknięte na żywo, dwa realne błędy
  znalezione i naprawione, plus jedna P1 korekta recenzenta zanim
  cokolwiek trafiło do wdrożenia.**
  1. **Gate G (route-switch): PASS na żywo.** Throwaway LXC (`/dev/zfs`
     passthrough przez cgroup — WAŻNE: bez `lxc.mount.entry`, ta
     dyrektywa psuje auto-mount `/proc` kontenera; sam cgroup allow
     wystarcza) na metropolis pve1, dwie niezależne ścieżki sieciowe
     (LAN + efemeryczny most `ip link add`, nigdy nie zapisany do
     `/etc/network/interfaces`). Pełny cykl: enroll+seed+activate po
     LAN → `final-catchup` → `set-endpoint` na drugą ścieżkę →
     `verify-endpoint` → `activate-client` → realny przyrost danych po
     nowej trasie, potwierdzony bajt w bajt. Po drodze znaleziony
     realny bug: `assert_target_block_not_clobbered` porównywał linie
     crona dosłownie, więc KAŻDA zmiana endpointu wyglądała jak cudzy
     job znikający i FATAL-owała reaktywację (`2e02a7d`). Recenzja
     złapała PRZED wdrożeniem, że ta pierwsza łatka była za
     gruboziarnista — jeden wspólny `HostKeyAlias` dla wszystkich
     jobów klienta mógł zamaskować cichą utratę JEDNEGO datasetu, jeśli
     inny dataset tego samego klienta przetrwał pod nowym adresem
     (REV-20260804-043, P1). Naprawione precyzyjnie: normalizacja
     WYŁĄCZNIE mutowalnego `host` w `-A "acct@host:path"`, reszta
     tożsamości joba (konto, source, target, harmonogram) musi się
     zgadzać dokładnie (`3a89892`). `test/zfsbackup` **260/260**
     (dokument twierdził tu `263/263` — zmierzone 2026-08-04 dwukrotnie,
     na HEAD i na `b4d1624` sprzed przeniesienia recenzji: obie dają 260,
     a suita ma `needs = nothing` i zero warunków od roota/ZFS, więc jest
     deterministyczna. Liczba 263 była błędna, nie środowiskowa),
     regresja potwierdzona (stash samej łatki → dokładnie te dwa nowe
     testy padają, reszta zielona). Gate G ponownie uruchomiony na żywo
     z poprawioną bramką — czysto, bez FATAL.
  2. **Gate I (sync na nieklastrowanej parze): PASS na żywo**, po
     korekcie metodologii ujawnionej wprost, nie wygładzonej. Pierwsza
     próba (ten sam LXC co Gate G) znalazła realny bug w `do_pair`:
     `--mode=sync` celowo nie ma `--target`, więc `PEER_TARGET` jest
     pusty, a kod tworzył `"$PEER_TARGET/$label"` bezwarunkowo dla
     KAŻDEJ roli pull — dla sync zwija się to do `/$label`, `zfs
     create -p` słusznie odmawia. Sync mode nigdy wcześniej nie parował
     się z żywą infrastrukturą. Naprawione: pomiń pre-tworzenie celu,
     gdy nie ma targetu (`d58e847`). Po naprawie ujawnił się GŁĘBSZY
     problem: privileged LXC dzieli JĄDRO i przestrzeń nazw puli z
     hostem — dla sync mode (ścieżka 1:1, bez prefiksu) "źródło" i
     "cel" okazały się DOSŁOWNIE tym samym datasetem
     (`zfs list -r hdd/backuptest_targets` pokazywał jeden wpis, nie
     dwa). Kontener nie mógł tego udowodnić strukturalnie — dwie
     zaimportowane pule o tej samej nazwie w jednym jądrze to
     sprzeczność. Owner zdecydował: zbuduj prawdziwą VM zamiast
     akceptować częściowy dowód. Zbudowano `labvm` (Debian 12
     cloud-init, WŁASNE jądro `6.1.0-51-cloud-amd64`, `zfs-dkms`
     skompilowany od zera po poprawce złego wariantu nagłówków —
     pierwsza kompilacja trafiła w `linux-headers-amd64` zamiast
     `-cloud-amd64` i dała moduł, który się nie ładował), własna pula
     `testsync` na drugim wirtualnym dysku (GUID
     `7174827982115380259`), niezależna od dopasowanej nazwą puli
     `testsync` utworzonej OSOBNO na pve1 (GUID `6403485474931656966`).
     Pełny cykl (seed + realna zmiana + druga synchronizacja)
     zweryfikowany po GUID snapshotu (identyczny po obu, naprawdę
     niezależnych stronach) i zawartości pliku. Po drodze: kolizja
     UID 1000 z prawdziwym produkcyjnym kontem `zfsbackup` w PIERWSZYM
     (już zniszczonym) kontenerze LXC — ujawniona natychmiast, brak
     trwałego wpływu (`zfs allow` na `rpool/data`/`rpool/ROOT/pve-1`
     zweryfikowany bez zmian), w drugiej próbie zapobieżona jawnym
     `UID_MIN 5000` przed jakimkolwiek `useradd`.
  3. **Sprzątanie: zero rezydualnych zmian.** VM i LXC zniszczone,
     efemeryczny most usunięty, throwaway pula `testsync` na pve1
     zniszczona z plikiem backingowym, wszystkie datasety testowe
     usunięte, klucze parowania i wpisy `known_hosts` wyczyszczone.
     Crontaby (root i `zfsbackup`) potwierdzone bajt w bajt identyczne
     z bazową linią sesji; `zfs allow` na realnych datasetach
     produkcyjnych bez zmian; `deploy.sh --check-only` → `audit clean
     on pve1`. Pełny rejestr: `docs/internal/reviews/responses/REV-20260804-042.md`,
     `docs/internal/reviews/responses/REV-20260804-043.md`.
- Wcześniej: **REV-20260804-039/040/041 —
  drugi krąg werdyktu recenzenta nad kampanią enrolmentu: cztery kolejne
  findingi, wszystkie zamknięte na żywo.**
  1. **F1 (039): przerwany `--join-remotely` — DISPUTED z dowodem, nie
     naprawiony nową maszyną stanów.** Świadomie zabity dwukrotnie w
     trakcie edycji zakresu (prawdziwy SIGTERM), potem zwykły retry TEJ
     SAMEJ komendy, bez ręcznej ingerencji: `do_pair` już ponownie używa
     istniejącego klucza (nie generuje nowego), `do_join` już traktuje
     ponowne zgłoszenie tego samego fingerprintu jako potwierdzenie, nie
     rotację — `authorized_keys` pozostał na jednej linii przez obie
     próby. Jedyna realna luka: komunikat błędu nie mówił, że retry jest
     bezpieczny — naprawione (`fef2314`).
  2. **F2 (039)/F1 (041): `remove-client` na ostatnim kliencie.** Gdy nie
     zostają żadne sekcje `[dataset:]`/`[prune:]`, `remove-client` prosi
     wspólny writer crontaba (`cron_block_remove`, ten sam co `--pause`)
     o usunięcie CAŁEGO bloku `zfs-backup-managed`, potem podmienia plik
     configu. Recenzja złapała, że nieudana podmiana pliku tylko
     ostrzegała i kontynuowała w `--unpair`/`STATE=removed` — teraz
     odmawia zamknięte, nazywa dokładnie stan mieszany, nigdy nie
     dociera do `--unpair`. `test/zfsbackup` +7 (255/255). Żywo:
     throwaway kolektor z JEDNYM klientem, crontab przed=dokładnie jeden
     zarządzany blok, po=ZERO bloków, checksum identyczny z bazową linią
     kampanii.
  3. **F3 (039)/REV-040: osierocone granty ZFS po UID.** Pierwsza wersja
     `--leave` (nowa komenda tear-down po stronie peera) zgadywała
     osierocony UID skanując `zfs allow` — recenzja złapała PRZED
     wdrożeniem, że to mogłoby odwołać cudzy grant na tym samym
     datasecie. Naprawione: trwałe `PEER_JOIN_ACCOUNT_UID` zapisywane
     przy joinie, weryfikowane przy każdym grantcie (odmowa zamknięta
     przy dryfie nazwa/UID), `--leave` używa WYŁĄCZNIE tego zapisanego
     UID. Żywo: dwa konta na jednym datasecie — obcy grant przetrwał
     nietknięty; dwa osierocone UID-y — tylko własny odwołany; legacy bez
     zapisanego UID i bez żywego konta — odmowa zamknięta, nic
     nietknięte; dryf UID/nazwy — odmowa PRZED mutacją.
  4. **F4 (039): macierz bramek.** Gate E (parent/child) i Gate H
     (idempotentna reaktywacja + odmowa przy pauzie) — PASS na żywo. Gate
     B — zamknięty dowodem z F1 powyżej. Gate G (zmiana trasy) i Gate I
     (sync na nieklastrowej parze) — jawnie NOT RUN: Gate G bo ta para
     hostów ma dokładnie jedną ścieżkę sieciową; Gate I bo metropolis i
     drugi klaster (192.168.11.x) siedzą na wzajemnie nieosiągalnych
     VPN-ach (potwierdzone w obie strony) — żaden dostępny w tej sesji
     hostpair nie jest jednocześnie nieklastrowany I wzajemnie osiągalny.
     Pełny rejestr: `docs/internal/reviews/responses/REV-20260804-039.md`.

- Wcześniej: **REV-20260804-037/038 — pełna
  żywa kampania enrolmentu (Gate A-J), osiem błędów znalezionych i
  naprawionych na żywo, zero fabrykowanych dowodów.** Kolektor pve1
  ↔ peer/source pve2 (metropolis), throwaway dataset, od czystego stanu do
  pełnego demontażu. Skrót ośmiu poprawek (każda to osobny commit, pełny
  opis w `docs/internal/reviews/responses/REV-20260804-037.md`'s Gate ledger i
  `REV-20260804-038.md`):
  1. `deploy.sh do_join()`: brakujący `local PEER_CONF_MODE` — pierwszy
     realny `--join --mode=` na żywym drugim hoście od razu się wywalił
     (`unbound variable`) w trakcie zapisu manifestu.
  2. `deploy.sh`: manifest join staje się atomowym, weryfikowanym commitem
     (render→temp→weryfikacja→rename→weryfikacja), zamiast niesprawdzanego
     `cat > plik` PO mutacjach konta/klucza (REV-038, `verify_join_manifest`,
     `test/joinmanifest` 10/10, +3 dla pola UID).
  3. `deploy.sh`: F1 z REV-037 — zdalny edytor `--join-remotely` mógł
     zgłosić fałszywy sukces po nieudanym drafcie; wydzielona
     `remote_scope_stage` z rozróżnialnymi kodami wyjścia
     (`test/joinremote` 8/8).
  4. `deploy.sh` (×2 miejsca): instrukcje `./deploy.sh --join=...`
     zakładały uruchomienie z `/root`, a skrypt leży w `$REPO_DIR` —
     dotyczyło też instrukcji ręcznych drukowanych od zawsze, pierwszy raz
     ktokolwiek wykonał je dosłownie.
  5. `zfs-backup.sh resolve_mode_datasets`: pobierał zatwierdzony plik
     zakresu pod złą etykietą (`LOAD_LABEL` = adres peera, zamiast
     `hostname -s` kolektora) — nowy globalny `COLLECTOR_LABEL`.
  6. `snapget.sh` — **KRYTYCZNE, dotyczy całej floty**: bramka
     bezpieczeństwa `-F` z plasterka 8 odmawiała KAŻDEGO pierwszego seeda
     (cel jest zawsze wstępnie tworzony pusty, co czyniło
     `target_exists()` zawsze prawdziwym).
  7. `snapget.sh` — **KRYTYCZNE, dotyczy całej floty**: `written@`
     porównywało sformatowaną wartość zfs (`"0B"`) z gołą cyfrą (`"0"`) —
     odmawiało przy KAŻDEJ zerowej rozbieżności, czyli normalnym stanie
     większości zwykłych incrementali w produkcji.
  8. `snapget.sh`: `written@` pytało o migawkę pod nazwą ŹRÓDŁA względem
     CELU — po dopasowaniu przez GUID (migawka zmieniona nazwą) cel nie
     ma migawki o tej nazwie, zapytanie zwraca `"-"`, odmowa mimo zera
     rozbieżności. Złapane przez WŁASNY istniejący test `test/snapsend`
     (sekcja guid-match), uruchomiony na żywo pierwszy raz od plasterka 8.

  `test/snapsend` **202/202** na pve1 (pierwszy przebieg od plasterka 8 —
  root+zfs nie było dostępne w sesji implementującej ten plasterek).
  Pełny cykl enrolmentu potwierdzony end-to-end: add-client → join
  (ręczny i zdalny) → draft/edit/commit-scope → seed (real transfer,
  md5 zgodny) → final-catchup (real incremental) → verify-endpoint →
  activate-client (dokładnie jeden zarządzany blok crona, reszta
  nietknięta, ręczne wykonanie jak prawdziwy cron: rc=0) → remove-client
  → pełny demontaż (crontab bajt-w-bajt jak przed testem na obu hostach,
  zero rezydualnych grantów/kont/holdów).

  **Dwie ujawnione, nienaprawione luki** (odzyskiwalne ręcznie,
  low-impact dziś): `remove-client` nie potrafi usunąć OSTATNIEGO klienta
  z configu (gen-cron.sh odmawia pustego zestawu reguł); przerwany
  `--join-remotely` może zostawić poprawnie dołączonego peera bez wpisu
  po stronie kolektora (odzyskiwalne przez ponowny `add-client`, do_join
  traktuje to jako rotację).

- Wcześniej: **REV-20260802-033 plasterek 10**
  (korekty nazewnictwa ról) — trzy komunikaty w `zfs-backup.sh`
  (`cmd_seed`, `cmd_final_catchup`, `cmd_verify_endpoint`) nazywały peera
  "the source" tuż obok już poprawnego "this collector" dla maszyny, która
  faktycznie się przenosi (ten sam defekt co U9 w subtelniejszej postaci —
  czytelnik widzi "collector relocates", a zdanie później "the source" bez
  sygnału, że to już druga strona). Zmienione na "the peer", zgodnie ze
  słownictwem używanym wszędzie indziej w pliku (`$PEER_HOST`, "the peer's
  committed scope file"). Wyłącznie literały napisów — zero zmiany
  zachowania. `zfsbackup` **249/249** (+3, sekcja 41, source-grep piny wzorem
  38a). Tym samym WSZYSTKIE dziesięć plasterków z planu REV-20260802-033
  jest zaimplementowanych; jedyne co zostaje przed wdrożeniem to żywy test
  end-to-end na dwóch hostach (zadanie stojące, patrz niżej). Odpowiedź:
  "Slice 10" w `docs/internal/reviews/responses/REV-20260802-033.md`.
- Wcześniej: **REV-20260802-033 plasterek 9**
  (zdalny `--join` + edytor zakresu przez `ssh -t`, U10) — jedna jawna,
  domyślnie WYŁĄCZONA flaga `--join-remotely` na `deploy.sh --pair`
  (przekazywana bez zmian przez `zfs-backup.sh add-client`). Po zapisaniu
  wsadu i przypięciu klucza hosta (bez zmian), gdy flaga podana: `scp` wsadu
  na peera, zdalne `ssh ... deploy.sh --join=...` (bezpieczne, bo `--join`
  od U2 nie nadaje żadnych uprawnień — zakłada tylko konto), a dla parowania
  trybowego dodatkowo `ssh -t ... deploy.sh --draft-scope=...; $EDITOR
  <plik>` — `vi` biegnie na peerze, w terminalu admina siedzącego przy
  kolektorze. Finalizacja (`--commit-scope`, grant) NIGDY nie jedzie zdalnie
  pod żadną flagą — to zostaje ręczną, jawną komendą operatora w tej samej
  sesji `ssh -t`. Manifest peera zapisuje pochodzenie zdalne
  (`PEER_JOIN_REMOTE`/`_FROM`/`_AT`/`_SESSION`, ta ostatnia przechwycona
  LOKALNIE na peerze w chwili `--join`, nie deklarowana przez kolektor) —
  nowe, opcjonalne pole wsadu `PEER_CONF_REMOTE_JOIN=yes` niesie to z
  kolektora, dopisane do ścisłej listy dozwolonych kluczy peer.conf. Każda
  nieudana próba automatyzacji ostrzega i spada do dokładnie tych samych
  ręcznych instrukcji co dotychczas — awaryjna droga ręczna zostaje.
  `join` **82/82** (+5), `zfsbackup` **246/246** (+2). Odpowiedź: addendum
  "Slice 9" w `docs/internal/reviews/responses/REV-20260802-033.md`.
- Wcześniej: **korekta U9** (model endpointu,
  naprawiona natychmiast po zgłoszeniu, nie odłożona do plasterka 9/10) —
  `ACTIVE_ENDPOINT` uogólnione ze slotu nazwanego (`lan`/`vpn`) na dosłowny
  `"host:port"` (dwukropek nigdy nie występuje w nazwie hosta, więc to
  jednoznaczny rozróżnik wobec starego kształtu, bez osobnego pola wersji).
  `set-endpoint NAME --host=HOST[:PORT]` zastępuje `--lan=`/`--vpn=` — realna
  łamiąca zmiana CLI, zero promienia rażenia dziś (żaden klient we flocie nie
  używa endpointu innego niż domyślny). Podanie adresu JUŻ aktualnego jest
  teraz no-opem (bez bramki, bez zapisu) — to czyni "trasa VPN nie wymaga
  set-endpoint" prawdą konstrukcyjną, nie tylko nawykiem operatora. Nowe pole
  `ENDPOINT_KNOWN` (lista adresów, które kiedyś zadziałały): `verify-endpoint`
  po nieudanej próbie aktualnego adresu próbuje po kolei każdego znanego
  kandydata zamiast od razu prosić operatora o nowy; adres, który odpowie,
  zostaje AWANSOWANY na `ACTIVE_ENDPOINT`, a ten, który przestał odpowiadać,
  sam staje się znanym kandydatem. Migracja rekordu legacy (pierwsze
  `set-endpoint` po aktualizacji) dokłada do `ENDPOINT_KNOWN` też uśpiony
  drugi slot (ten, który NIE był aktywny) — nic nie ginie. Naprawiono też
  drugie potwierdzone w U9 ustalenie: komunikaty `final-catchup`/`seed` już
  nie nazywają złą maszyną tej, która się przenosi ("ten kolektor", nie
  "źródło"). Koszt jednorazowy dla istniejących klientów, nazwany wprost: ich
  ostatni catch-up sprzed aktualizacji (zapisany jako `lan`/`vpn`) nie
  dopasuje się do nowego porównania dosłownego adresu przy pierwszym
  `set-endpoint` po aktualizacji — czyta się jako "brak catch-upu", fail-closed,
  nie jako zaufanie rekordowi w formacie, którego nowa bramka już nie
  rozpoznaje. `zfsbackup` **244/244** (+6 netto nad plasterkiem 8, po
  przepisaniu — nie tylko dopisaniu — fixture'ów bramki `set-endpoint` na
  nowe CLI). Odpowiedź: "U9 implemented" w
  `docs/internal/reviews/responses/REV-20260802-033.md`.
- Wcześniej: **REV-20260802-033 plasterek 8**
  (kontrakty sync: F3, U7, U8) — dwie niezależne połówki. (1) `snapget.sh`,
  `process_dataset`: `-F` przestało być bezwarunkowym domyślnym flagiem przy
  KAŻDYM odbiorze (dotyczy więc też dzisiejszego ruchu backup) — nowy
  `recv_force_flag` odmawia zamiast cicho nadpisywać, gdy cel to dysk ŻYWEGO
  guesta (`guest_disk_is_live`, reużywa `quiesce_guest_id`/
  `quiesce_guest_status` z `lib-zfs-snap.sh`, fail-closed gdy stanu nie da
  się ustalić), gdy brak wspólnego snapshotu po GUID (pełny resend wymaga
  jawnego `-f`), albo gdy `written@<wspólny>` > 0 (nazywa ilość). `-F`
  zostaje TYLKO przy kontynuacji własnej, nierozjechanej kopii, gdzie jest
  operacją pustą. Dowód (2026-08-02, klaster 192.168.11.x): `snapget.sh -r
  pve0:rpool/data/vm-100-disk-0` (sync bez drugiego argumentu) celowałoby w
  żywy dysk vsql2 (VM 100) i cofnęłoby bazę do repliki pvesr — dziś ratuje
  przed tym wyłącznie `dataset is busy` samego ZFS, nie własność
  bezpieczeństwa. (2) `deploy.sh --pair --mode=sync`: peer będący członkiem
  TEGO SAMEGO klastra PVE jest odrzucany PRZY ENROLLMENCIE (U8), zanim
  cokolwiek zostanie sparowane — sprawdzane tanio przez `/etc/pve/nodes/`
  (`PVE_NODES_DIR`, nadpisywalny jak `QUIESCE_PVE_DIR`, więc testowalny bez
  prawdziwego klastra); ograniczenie: dopasowanie po nazwie hosta, nie po
  tożsamości klastra — nazwane wprost, nie ukryte. (3) `zfs-backup.sh`:
  mapowanie F3 dla trybu sync wreszcie zaimplementowane — dotąd KAŻDE
  wywołanie `snapget.sh` z wrappera używało twardo mapowania backupowego
  (`$PEER_SAVED_TARGET/$LOAD_LABEL/$ds`), nawet dla `--mode=sync`, co dawało
  ścieżkę ze slashem na początku zamiast „ta sama ścieżka co źródło" —
  martwy kod od plasterka 5/6, nigdy nie przetestowany end-to-end. Nowe
  `snapget_local_base`/`client_local_path` to jedyne miejsce rozstrzygające
  tryb; `emit_client_sections` w trybie sync generuje jeden `[prune:$ds]` na
  dataset (`recursive = no`, bo nie ma wspólnego rodzica do zamiatania —
  inaczej byłby to ten sam wyścig `[prune:]`-pod-rekurencyjnym-`[prune:]`,
  który już raz naprawiono dla delsnaps). `zfsbackup` **238/238** (+6).
  **Korekta do plasterka 7:** U9 w `ENROLMENT-AGREED-2026-08-02.md` (ten sam
  wieczór, przed implementacją plasterka 7) już ROZSTRZYGNĄŁ, że sloty
  `lan`/`vpn` mają zniknąć z interfejsu na rzecz „jeden aktualny endpoint +
  lista znanych kandydatów" — przeoczone przy plasterku 7, potraktowane tam
  jako wciąż otwarte pytanie z samej recenzji. Nie cofnięte w już wypchniętych
  commitach plasterka 7 — zapisane jako otwarta korekta, do zrobienia razem z
  poprawką nazewnictwa ról (kolektor vs źródło), bo dotyczą tych samych pól i
  komunikatów. Odpowiedź: addendum "Slice 8" + "Correction to slice 7: U9"
  w `docs/internal/reviews/responses/REV-20260802-033.md`.
- Wcześniej: **REV-20260802-033 plasterek 7**
  (model endpointu, F4) — recenzja żądała porównania stanu maszyny stanów z
  decyzjami właściciela 13-14 ("set-endpoint tylko gdy adres faktycznie się
  zmienia") i najmniejszej korekty. Ustalenie: maszyna stanów zbudowana pod
  REV-20260730-004/005 i REV-20260731-007/008 już to spełnia strukturalnie —
  `cmd_set_endpoint` nigdy nie mutuje rekordu bez jawnego `--lan=`/`--vpn=`,
  więc trasa VPN z niezmienionym `host:port` już dziś nie wymaga żadnego
  `set-endpoint` (wystarczy ponowne `verify-endpoint`). Dwie realne luki
  naprawione zamiast przebudowy: (1) `cmd_verify_endpoint` odrzucał stderr
  `snapget.sh` (`2>/dev/null`) na każdym nieudanym sprawdzeniu — dokładnie
  tam, gdzie miałoby się pojawić rozróżnienie „ograniczenie po adresie
  źródłowym" od zwykłej awarii (istniejący diagnostyk `snapget.sh`/
  `lib-zfs-snap.sh` dla ssh exit 255 był po prostu wyrzucany); teraz stderr
  trafia do pliku tymczasowego i jest wypisywany przy niepowodzeniu. (2)
  podpowiedź po `seed` sugerowała `set-endpoint`/`verify-endpoint` jako stały
  dwuetapowy ciąg — dokładnie błąd nazwany w F4 ("administrator wymyśla lub
  powtarza adres, który się nie zmienił") — przeformułowana na warunek:
  `set-endpoint` tylko gdy SSH łączy się teraz pod innym host:port, inaczej
  od razu `verify-endpoint`. Nazewnictwo ról w komunikatach (kolektor vs
  źródło jako przenoszona maszyna) świadomie odłożone do plasterka 10.
  `zfsbackup` **232/232** (+2). Odpowiedź: addendum "Slice 7" w
  `docs/internal/reviews/responses/REV-20260802-033.md`.
- Wcześniej: **REV-20260802-033 plasterek 6**
  (kolektor: fetch/digest/generate) — `zfs-backup.sh` przestaje wymagać listy
  datasetów przy `add-client --mode=backup|sync` (alternatywa dla
  `--datasets`, przekazywana do `deploy.sh --pair` jako `--mode=`).
  `resolve_mode_datasets()`, wpięte w `load_client_and_connection` (więc
  `seed`/`final-catchup`/`verify-endpoint`/`activate-client`/`migrate-profile`
  nie potrzebują ŻADNEJ zmiany), dla klienta trybowego: pobiera przez ssh
  plik zakresu peera ORAZ jego sidecar sha256 (T3), odmawia przy
  niezgodności, czyta przez `lib-scope.sh` (`scope_read`/`scope_includes` —
  realna krawędź źródłowa, nie duplikat) i przechodzi realne liście przez
  zdalne `zfs list -r`, wypełniając `PEER_SAVED_DATASETS` dokładnie tak, jak
  robił to dotąd ręcznie podany `--peer-datasets`. `cmd_seed` pomija swoje
  dotychczasowe wywołanie `--draft-config` (specyficzne dla listy
  datasetów) dla klienta trybowego — `resolve_mode_datasets` jest jego
  odpowiednikiem sprawdzenia gotowości/łączności.
  **Ważne dla recenzenta:** wynikiem jest GOTOWY, od razu instalowany config
  (istniejący mechanizm `PROFILE_GFS`/`emit_client_sections`), nie kandydaci
  do ręcznego przeglądu jak w starszej konwencji `do_draft_config` —
  to jest model uzgodniony w dyskusji zapisanej w
  `docs/discussions/ENROLMENT-AGREED-2026-08-02.md` (scenariusz odniesienia:
  „dostaję gotowy domyślny config… i zaczyna się backup”), nie coś
  wywnioskowane z samej recenzji.
  U11 (per-sekcyjny znacznik własności): `emit_client_sections` pisze
  `# managed-by: zfs-backup.sh client=<nazwa>` jako pierwszą linię treści
  każdej wygenerowanej sekcji `[dataset:]`/`[prune:]`; `remove_managed_sections`
  usuwa sekcję tylko gdy ten znacznik się zgadza ALBO ścieżka była już
  wcześniej zapisana we WŁASNYM `MANAGED_DATASETS`/`MANAGED_PRUNE_SCOPE`
  wywołującego (to drugie jest tym, co zachowuje działanie każdego klienta
  aktywowanego przed U11 bez zmian — ich sekcje sprzed znacznika są nadal
  rozpoznawane jako własne po własnym zapisie, znacznik dochodzi przy
  najbliższym przepisaniu). Dopasowanie nagłówka bez znacznika i bez
  wcześniejszego zapisu jest ODMAWIANE, nie cicho kasowane — wygląda na
  ręcznie napisaną sekcję w tym samym miejscu.
  U6/rozstrzygnięcie pytania 2: `ensure_cron_config` dopisuje globalny próg
  `keep = 2` dla wszystkich trzech zastrzeżonych prefiksów
  (`__replicate_`, `vzdump`, `__migration__`) przez `[excluded:]`, wyłącznie
  DOKŁADAJĄC brakujący próg — silniejszy `keep` operatora nigdy nie jest
  zawężany. `zfsbackup` **230/230** (+16). Odpowiedź: addendum "Slice 6" w
  `docs/internal/reviews/responses/REV-20260802-033.md`. Wcześniej **łatki T3/U2/T5**
  (`6c930ff`, `b6d5032`) wobec `docs/discussions/ENROLMENT-AGREED-2026-08-02.md`
  — ten dokument, nie sama recenzja, jest właściwą specyfikacją mechaniki,
  do której plasterki REV-033 dążą. T3: `--commit-scope` zapisuje sha256
  pliku zakresu, z którego nadał (`<label>.scope.sha256`, world-readable) —
  kolektor (plasterek 6) porówna to przy fetchu, odmówi gdy się rozjedzie.
  U2: `--commit-scope` liczy i wypisuje CAŁY plan (grant/revoke/hold-blocked/
  gone) PRZED pierwszym `zfs allow`/`unallow`, nie odkrywa go linia po linii
  w trakcie wykonania. T5: `--draft-scope` dopisuje spis rodzin snapshotów
  (`__replicate_`, `automated_*`, `vzdump` itp.) obok inwentarza datasetów —
  zero kosztu, żadnej drugiej reprezentacji. Wszystkie trzy zweryfikowane na
  żywo na metropolis pve2 (T3/U2 na scratch datasetach, T5 na prawdziwych,
  bałaganiarskich danych produkcyjnych). `draftscope` **26/26** (+4).
  Odpowiedź: sekcja "Patches against ENROLMENT-AGREED" w
  `docs/internal/reviews/responses/REV-20260802-033.md`. Wcześniej
  **REV-20260802-033 plasterek 5** (`d839c91`) — `--pair --role=pull` przyjmuje teraz `--mode=backup|sync`
  jako alternatywę dla `--peer-datasets`: pakiet niesie `PEER_CONF_MODE`
  zamiast listy datasetów, wybór odsunięty na peera (`--draft-scope`/
  `--commit-scope`, plasterek 4). Wzajemnie wykluczające się z
  `--peer-datasets`. `--mode=sync` odmawia `--target` (F3: sync odtwarza
  ścieżki źródła jeden do jednego, brak osobnego korzenia docelowego);
  `--mode=backup` przyjmuje `--target` albo zostawia puste (domyślny cel
  "serwera" to `DEFAULT_TARGET` samego wrappera `zfs-backup.sh`, nie coś co
  `deploy.sh` wymyśla). Prawdziwa granica zaufania (`validate_peer_conf`,
  paczka przekracza hosty) sprawdzona: pakiet BEZ klucza `PEER_CONF_MODE`
  w ogóle (dokładny kształt każdej paczki sprzed tego commitu) waliduje się
  identycznie jak wcześniej — zgodność wsteczna potwierdzona osobnym
  testem, nie wywnioskowana z diffu. `join` **77/77** (+13).
  Odpowiedź: addendum "Slice 5" w
  `docs/internal/reviews/responses/REV-20260802-033.md`. Wcześniej
  **REV-20260802-033 plasterek 4** (`279303b`) — `deploy.sh --draft-scope=LABEL` generuje plik zakresu
  z prawdziwego inwentarza ZFS peera: jeden `[dataset:X]` na niesystemowy
  dataset jeden poziom pod każdą pulą (`include_parent=no`,
  `include_children=yes`), plus pełny inwentarz jako komentarz. Cenzus
  systemowy (`ROOT`, `swap`) dopasowywany WYŁĄCZNIE po ostatnim segmencie
  ścieżki, nigdy jako prefiks/podłańcuch — przykładowe korzenie z F2
  (`data`/`olds`/`LXC`) nie mogą zostać złapane przez sprytniejszą
  heurystykę. Odmawia, gdy plik zakresu już istnieje (chroni edycję w toku)
  albo manifest nie opisuje delegowanego peera pull. Zweryfikowane na żywo
  na metropolis pve2 (3 prawdziwe pule, w tym głęboko zagnieżdżona struktura
  backup-of-backup) — 9 aktywnych datasetów trafionych poprawnie, wszystkie
  3 korzenie puli + `rpool/ROOT` poprawnie wykluczone, pełny inwentarz
  (30 datasetów) zgadza się z ręcznym `zfs list -r`. `join` **64/64** (+10),
  nowa suita `draftscope` **22/22**. Odpowiedź: addendum "Slice 4" w
  `docs/internal/reviews/responses/REV-20260802-033.md`. Wcześniej
  **REV-20260802-033 plasterek 3** (`b7e0478`) — `do_commit_scope` teraz też
  ODBIERA: zbiór do odwołania to
  (poprzedni zbiór z manifestu) MINUS (obecny zbiór ze scope file) — nigdy
  wyprowadzone z tego, co `zfs allow` pokazuje dla konta teraz, co jest tym,
  co sprawia że cudzy grant na tym samym datasecie przeżywa zawężenie: nigdy
  nie jest kandydatem, nie jest oszczędzony po rozważeniu. Kandydat z aktywnym
  holdem transferu (`zfssnapall_inflight`) zostaje NIE odwołany, ostrzeżenie
  po imieniu, zapisany z powrotem w manifeście do ponowienia przy następnym
  commit. Zweryfikowane na żywo na metropolis pve2 (scratchowe datasety):
  cudzy grant przeżył, dataset z holdem przeżył i został poprawnie odwołany
  po zwolnieniu holdu przy kolejnym uruchomieniu, dataset bez holdu odwołany
  od razu, manifest zgadza się z rzeczywistym stanem po obu przebiegach.
  Sprzątnięte: scratch datasety zniszczone, `--revoke-quiesce` użyty do
  usunięcia whitelisty/reguły sudoers które ten test stworzył.
  Odpowiedź: addendum "Slice 3" w
  `docs/internal/reviews/responses/REV-20260802-033.md`. Wcześniej
  **REV-20260803-036** —
  `--pause`/`--resume` z durable-transaction hardeningiem: zapis stanu
  `--fullcron` jest teraz durable PRZED zamianą crontaba (kolejność
  odwrócona, atomowy rename, rollback stanu przy nieudanym zapisie
  crontaba — F1); dokładny bajtowy placeholder zapisany obok stanu i
  porównywany bajt-po-bajcie przy `--resume` zamiast `grep` po podłańcuchu
  (F3); tryb blokowy renderuje wszystkie bloki lokalnie i commituje JEDNYM
  zapisem przez `cron_replace_all_impl`, więc częściowa pauza/resume nie
  jest już możliwa (F2); jawny rejestr `PAUSE_KNOWN_BLOCKS` — blok
  wyglądający syntaktycznie jak nasz (np. cudzy `certbot`) nigdy nie jest
  dotykany (F4); `lib-cron.sh` sam rozpoznaje zapauzowany kształt
  (`cron_paused_guard`) i odmawia KAŻDEMU zwykłemu pisarzowi
  (`cron_block_install`/`ensure_line`/`adopt_line`, czyli też
  `gen-cron.sh --install`) nadpisania go, więc pauza przeżywa zwykły zapis
  wykonany po jej zakończeniu, nie tylko zapis współbieżny (F5). `pause`
  **74/74** (+25). Odpowiedź:
  `docs/internal/reviews/responses/REV-20260803-036.md`. Wcześniej `f6f4ce3` —
  `deploy.sh --pause`/`--resume` domyślnie zatrzymuje TYLKO bloki tego
  pakietu (zakomentowanie ciała bloku w miejscu, markery `lib-cron.sh`),
  zamiast całego crontaba; `--fullcron` przywraca dawne zamiatanie całego
  crontaba dla usera, gdy operator naprawdę chce zatrzymać wszystko;
  `--resume` sam rozpoznaje tryb, w którym dany user został zapauzowany;
  wcześniej `54de481` — pierwsza wersja `--pause`/`--resume` (tylko tryb
  pełnego crontaba), zbudowana na zamku `lib-cron.sh`;
  wcześniej `9e977f6` — `CRON_LOCK_DIR` to teraz jeden stały katalog bez
  fallbacku zależnego od wywołującego (REV-035); wcześniej `4190d83` —
  `--join` (peer pull) nie nadaje już żadnych uprawnień
  ZFS; nowa komenda `--commit-scope` nadaje dokładnie to, co wybiera plik
  zakresu (REV-033 plasterek 2); wcześniej
  `ff712df` — gramatyka i czytnik pliku zakresu, `lib-scope.sh` (REV-033
  plasterek 1); wcześniej `41afa2f` — goły `exec ... 2>/dev/null`
  w `cron_lock_acquire`/`_release` trwale kasował stderr procesu zamiast
  gasić błąd jednej próby (REV-034, złapane przy zamykaniu F3); wcześniej
  `4f1c174` — `cron_replace_all` spina `migrate-to-account` na wspólnym
  pisarzu (REV-034 F3); `cecfeaf` — wspólny blok scalany zamiast
  nadpisywany, układ markerów sprawdzany globalnie (REV-034 F1, F4);
  `224cc83` — zamek per-użytkownik zamyka wyścig (REV-034 F2); wcześniej
  `700d045` — rejestr tego, co przebieg utworzył, przestaje być **plikiem**
  (REV-032); `3d4c13f` — raport wycofania nie może **zawieść fail-open**
  (REV-031); `9fbf1df` — niekompletny zestaw jest **usuwany, nie tłumaczony**
  (REV-030); `c7ce8da` — granica zamrożenia należy do **każdej puli**, nie do
  przebiegu (REV-029); `90a06c8` — `--add-quiesce`, grant **wyłącznie
  dokładający** (REV-028); `7564f8e` — ścieżka zdalna dostaje ten sam kontrakt
  co lokalna
- Repozytorium: `AdalbertKing/zfs-snapshot-all`
- Tryb pracy: tymczasowo bezpośrednio do `main`, decyzją właściciela
- Poprzedni **uzgodniony** punkt bazowy: `388a78e` z 2026-07-30 (sekcja 8)
- Status ogólny: **Cała flota (4 hosty) pracuje z kont delegowanych, każdy host
  ma własny config w `/etc/zfs-snapshot-all/`. Kolejka recenzji pusta, dług suit
  zerowy — wszystkie odpowiedzi na REV-021…032 są w
  `docs/internal/reviews/responses/`.** REV-032 przeszedł pełen komplet suit **przed**
  wejściem na `main` (gałąź `rev-032`, klon na metropolis pve1): `quiesce`
  161/161 jako konto, `snapsend` 202/202, `scenarios` 34/34, `remote` 145/145
  jako root i 145/145 jako konto. Migracja zaczęła się 2026-08-01 18:10 na
  metropolis pve1 i przy okazji **wykryła realny defekt fail-open w lokalnym
  quiescie** (`55d33a2`) — pierwszy przebieg jako konto zrobił pięć snapshotów
  bez zamrożenia i zakończył się kodem 0.

> **Jak ten defekt został znaleziony — warto, żeby nie zniknęło.** Nie przez
> kod błędu i nie przez alert: migracja zakończyła się sukcesem, job zwrócił 0,
> a dziennik napisał „guest 106 is not running”, podczas gdy `qm status` w tej
> samej sekundzie mówił `running`. Weryfikacja polegała na przeczytaniu, co
> quiesce *zrobił*, a nie na sprawdzeniu, czy się *udało*. Gdyby zatrzymać się
> na `rc=0`, host robiłby od tej nocy kopie crash-consistent, twierdząc w logu,
> że są zamrożone.

## 1. Co jest wdrożone, gdzie i w jakiej wersji

Trzy osiągalne hosty potwierdzone na `a567328` (2026-08-04 23:44, wymuszony
`--self-update` na każdym; godzinowy pull o :15 działa niezależnie). Czwarty,
pve1 klastra 192.168.11.x, nie był w tej sesji aktualizowany — patrz uwaga o
DEGRADED rpool niżej.

**`deploy.sh --check-only` czysty na wszystkich trzech osiągalnych**
(`audit clean on pve0` / `pve1` / `pve2`), zweryfikowane 2026-08-04 23:44 po
naprawie dwóch usterek opisanych w nagłówku: brakującego katalogu blokad na
pve0 i brakującej bazy aliasów na metropolis pve2.

Repo na hostach mieszka w `/root/scripts/zfs-snapshot-all` (nie
`/root/zfs-snapshot-all`), a konto delegowane ma własny checkout w
`/home/zfsbackup/zfs-snapshot-all`.

| Host | Adres | Konto delegowane | `sudo` | grant quiesce | kto uruchamia blok |
|---|---|---|---|---|---|
| pve0 | 192.168.11.10 | `zfsbackup` | jest | **NADANY** | **`zfsbackup`** |
| pve1 | 192.168.11.11 | `zfsbackup` | jest | **NADANY** | **`zfsbackup`** |
| metropolis pve1 | 192.168.28.9 | `zfsbackup` | jest | **NADANY** | **`zfsbackup`** |
| metropolis pve2 | 192.168.28.8 | `zfsbackup` | jest | **NADANY** | **`zfsbackup`** |

**Wszystkie cztery hosty mają blok na koncie delegowanym.** Metropolis pve1 od
2026-08-01 18:10, pve2 21:44, pve1 (11.11) 23:02, pve0 23:05. W crontabie roota
zostały wszędzie trzy linie ogólnohostowe: `check-pool-capacity.sh`,
`update-control.sh --self-update` i `alert-digest.sh`. Configi mieszkają w
`/etc/zfs-snapshot-all/` — **przeniesione**, nie skopiowane.

Stan potwierdzony na żywo 2026-08-02 na wszystkich czterech: `sudo -n
zfs-quiesce-helper status` jako konto → `OK account=zfsbackup`, whitelista
niepusta, helper na miejscu, zero zadań backupowych w crontabie roota.
Liczba linii zadań na koncie: pve0 28, pve1 (11.11) 8, metropolis pve1 12,
metropolis pve2 14.

> Ta tabela do 2026-08-02 twierdziła, że klaster 192.168.11.x „nadal w całości
> na roocie i nie ma tam nawet konta delegowanego". Było to nieprawdą od
> 2026-08-01 wieczorem — migracja objęła wszystkie cztery hosty tej samej nocy,
> a dokument został odświeżony tylko w sekcjach o recenzjach. Dokładnie ten typ
> rozjazdu, o którym mówi nagłówek.

pve2 doszedł tam okrężną drogą: jego config **nie istniał** (patrz niżej),
więc najpierw trzeba go było odtworzyć z żywego crontaba `cron2conf.sh`.
Round-trip wyszedł bajt w bajt: 12 wyrenderowanych linii identycznych z
zainstalowanymi, w tej samej kolejności.

Wersje programów w drzewie:

| Program | Wersja |
|---|---:|
| `snapsend.sh` | `v2.68` |
| `snapget.sh` | `v2.65` |
| `delsnaps.sh` | `v1.28` |
| `gen-cron.sh` | `v4.25` |
| `check-snap-age.sh` | `v2.0` |
| `cron2conf.sh` | `v1.0` |

`deploy.sh`, `zfs-backup.sh`, `zfs-quiesce-helper.sh`, `update-control.sh` i
`check-pool-capacity.sh` nie mają własnej stałej `VERSION` — identyfikuje je
commit.

`cron2conf.sh` (nowy, 2026-08-01) jest odwrotnością `gen-cron.sh`: czyta już
zainstalowany blok `# BEGIN/END zfs-backup-managed` z crontaba i odtwarza
config, z którego `gen-cron.sh` wygeneruje ten sam blok z powrotem — na
wypadek zgubienia/niescommitowania pliku źródłowego, jak w przypadku pve2
niżej. Nie ma jeszcze wpisu w `deploy.sh` (nie jest kopiowany na hosty) —
uruchamiany dziś ręcznie z checkoutu deweloperskiego, tak jak został
zweryfikowany na pve1 i pve2.

### Stan grantu quiesce na hostach: DWA NADANIA, produkcyjne

**metropolis pve1 od 17:54, metropolis pve2 od 21:43** — pierwsze trwałe granty
quiesce w całej flocie, i pierwsze nadane *lokalnym* kontom tych hostów, a nie
sparowanym peerom. Na pve2 `deploy.sh` doinstalował przy okazji brakujący pakiet
`sudo`, jak zapowiada. Poniżej pve1; pve2 ma ten sam kształt, z whitelistą
`rpool/data rpool/ROOT/pve-1 hdd/vm-disks hdd/backups` i jedynym lokalnym
gościem 103 (reszta dysków pod tymi ścieżkami to repliki, których konfiguracje
żyją na pve1 — helper zgłasza je jako `kind=absent`, więc są niezamrażalne):

| Element | Wartość |
|---|---|
| konto | `zfsbackup` |
| reguła | `/etc/sudoers.d/zfs-quiesce-zfsbackup` (0440 root:root) |
| whitelista | `/etc/zfs-quiesce-allow/zfsbackup` — sześć datasetów **dokładnie tych, które nazywa config** |
| polecenie | `deploy.sh --backup-user=zfsbackup --datasets="…" --allow-quiesce` |

Zweryfikowane **jako konto**, nie jako root: `sudo -n zfs-quiesce-helper status`
→ `OK account=zfsbackup`; guesty 100, 101, 106 i 107 (te, których dyski config
backupuje) przechodzą z kodem 0; guest **102 odmówiony kodem 2** — jego dysk leży
pod `hdd/vm-disks`, ale nie jest w configu. To jest cała racja bytu wyprowadzania
whitelisty z listy datasetów zamiast z puli: gdyby `--datasets` nazwało rodzica,
konto mogłoby zamrozić maszynę, której nie ma powodu dotykać.

Ta droga nadania **nie istniała** do 2026-08-01 — `--allow-quiesce` działało
wyłącznie razem z `--join`, czyli tylko dla peera. Zdolność, o którą preflight
migracji się potykał, nie miała żadnego polecenia, które by ją nadawało
(`3831509`, doprecyzowane przez REV-022 w `32d6ed1`).

Na pve0 i pve1 (192.168.11.x) grant **jest** od migracji 2026-08-01 wieczorem —
reguła `sudoers.d`, whitelista i helper na obu. Whitelisty różnią się zakresem,
bo wyprowadza je config danego hosta: pve0 pięć datasetów
(`rpool/data`, `hdd/data/vm-101-disk-0`, `hdd/lxc/subvol-102-disk-0`,
`hdd/lxc/subvol-102-disk-1`, `hdd/backups/pve1`), pve1 (11.11) jeden
(`rpool/data`). Zdanie o „zero reguł" w tym miejscu opisywało stan sprzed
migracji i było nieaktualne od tamtego wieczora.

Pozostałości po testach z 2026-07-31 **są** i trzeba je czytać jako stan, nie
jako zero:

| Host | Co zostało | Skąd |
|---|---|---|
| pve0, pve1 (192.168.11.x) | pakiet `sudo` | przebiegi `--allow-quiesce` 14:35 i 15:45 |
| metropolis pve1 | pakiet `sudo` **oraz `/usr/local/sbin/zfs-quiesce-helper`** | pełny cykl end-to-end zakończony `--revoke-quiesce` |

To jest dokładnie stan opisany w REV-20260731-009 §5: pakiet zostaje, granta nie
ma, i od `ad5e745` kod mówi o tym wprost przy każdej takiej awarii. `--revoke`
zdejmuje **regułę** — to ona jest przełącznikiem — a binarkę helpera zostawia;
bez reguły jest ona martwym plikiem. Potwierdzone na żywo:
`runuser --user zfsbackup -- sudo -n /usr/local/sbin/zfs-quiesce-helper status 106`
→ `sudo: a password is required`.

Poprzednia wersja tej sekcji twierdziła, że helpera nie ma na żadnym hoście i że
metropolis pve1 nie ma `sudo`. Oba zdania były nieprawdziwe od 2026-07-31.

**Instalacja end-to-end: WYKONANA 2026-07-31 na metropolis** (za zgodą
właściciela). Pełny cykl `--pair` → przeniesienie paczki → `--join
--allow-quiesce` → weryfikacja granicy → aktualizacja z szerszą listą →
`--revoke-quiesce` → `--unpair` + teardown. Szczegóły i hashe w odpowiedzi na
REV-20260731-012.

Co to dało — rzeczy, których piaskownica nie umiała pokazać: prawdziwy `visudo`
przyjął regułę; konto delegowane dosięgło helpera przez sudo; guest na `rpool/data`
przeszedł, a guesty na puli `hdd` zostały odmówione; **`env_reset` udowodniony z
kontrolą nośności** (ta sama zmienna działa, gdy dociera do helpera, i nie działa
przez sudo); forma argumentowa nie pasuje do reguły i w ogóle nie startuje;
ścieżka aktualizacji z REV-012 zostawiła regułę bajt w bajt tą samą i zero
`.zqg-*`; po odwołaniu konto traci dostęp całkowicie; crontaby obu maszyn
identyczne przed i po.

Świadomie zostawione, wszystko zapowiedziane przez kod: pakiet `sudo`, binarka
helpera (współdzielona) i pusty dataset testowy w `hdd/backuptest_targets/`.

**Freeze/thaw na produkcyjnym guescie: WYKONANY 2026-07-31 21:27** na VM 106
(`vbim2`, Windows, metropolis pve1), pełną ścieżką konto delegowane → sudo →
helper:

```
przed:     thawed   21:27:19
froze VM 106 via qemu-guest-agent   rc=0
w trakcie: frozen   21:27:23      <- potwierdzone przez qm, nie deklaracją helpera
thawed VM 106                       rc=0
po:        thawed   21:27:25
```

Zamrożenie zajęło ~4 s (przygotowanie VSS), samo okno zamrożenia ~2 s. Po
wszystkim guest `running`, agent odpowiada. Test szedł w **jednym** wywołaniu z
trapem odmrażającym rootem, a termin replikacji `106-0` (co 3 h) był wcześniej
odczekany — pvesr mrozi tego samego guesta i kolizja byłaby najgorszym możliwym
momentem.

Ten sam przebieg znalazł realny błąd w `sqlfreeze`, patrz sekcja 4.

**Czego nadal nie ma:** ścieżki błędów `install`/`mv`/`visudo` oraz crash są
wyłącznie stubowane — na produkcji przeszedł happy path.

**Snapshot w oknie zamrożenia: WYKONANY 2026-08-01 18:21**, przez konto
delegowane, na wszystkich pięciu datasetach naraz (`froze VM 106 via
qemu-guest-agent` → dwa atomowe `zfs snapshot`, po jednym na pulę → `thawed VM
106`, guest `thawed` przed i po). Czyli to, czego brakowało powyżej, jest
zrobione — ale przebieg odsłonił **inny** problem, opisany niżej.

**Okno zamrożenia: NAPRAWIONE** (REV-20260801-024, `be1cfe7` + `d8bb52a`).

Defekt: VM 106 zamrożony 18:21:21, snapshot 18:21:39 — **~18 s**, z czego 16 s to
`pct exec 101 -- sync` lecący **po** zamrożeniu. VM 106 to `ostype: win10`, a VSS
zwalnia freeze po ~10 s samo z siebie. Czyli snapshot powstawał poza oknem, które
deklarował, i wszystkie kontrole to akceptowały — bo freeze *się udał*, tylko już
nie obowiązywał. Niezależne od migracji: root miał tę samą kolejność.

Poprawka ma trzy części i wszystkie trzy są potrzebne:

| | co | gdzie |
|---|---|---|
| kolejność | `quiesce_prepare` (wolne: flush kontenerów, decyzje, odmowy — **zero freeze'ów**) i osobne `quiesce_freeze_pending` tuż przed snapshotem | `lib-zfs-snap.sh` |
| ponowny odczyt | `quiesce_still_frozen` pyta każdą VM jeszcze raz **bezpośrednio przed** `zfs snapshot`; nie-zamrożona albo nieodczytywalna przerywa | `lib-zfs-snap.sh` |
| termin | `QUIESCE_MAX_WINDOW` (5 s, przy limicie VSS ~10 s), mierzony i **logowany**, przekroczenie = błąd, nie ostrzeżenie | `lib-zfs-snap.sh` |

Zmierzone na żywo po poprawce: **okno 1 s** (było 18), przy kontenerach
flushowanych 51 s — czyli dłużej niż wcześniej, i to jest właśnie sedno: ten czas
nie dotyka już okna.

> **Pierwsza wersja poprawki miała własny błąd i znalazł go dopiero pomiar.**
> `be1cfe7` startował zegar przed **wywołaniem** freeze'u, a `fsfreeze-freeze` na
> Windows wraca po ~4 s (VSS się przygotowuje — guest nie jest wtedy zamrożony).
> Produkcyjny przebieg wypisał `freeze window 5s (budget 5s)` — przeszedł
> zerowym marginesem. `d8bb52a` startuje zegar przy **pierwszym udanym**
> zamrożeniu. Znowu: wykryte przez przeczytanie liczby, nie przez test.

**Nieobjęte:** ścieżka zdalna (`snapget -q`) ma własną kopię tej logiki w
`ZFS_REMOTE_QUIESCE_SCRIPT`. Ten konkretny kształt (16 s flushu w środku okna)
nie może tam wystąpić, bo freeze/snapshot/thaw idą w jednym wywołaniu — ale nie
ma tam ani ponownego odczytu na granicy, ani terminu. Ta sama rodzina, świadomie
poza tym commitem.

## 2. Zaakceptowany rdzeń

Bez zmian wobec uzgodnienia z 2026-07-30. Przyjęte jako działające: snapshoty
ZFS; replikacja push i pull, lokalnie i przez SSH; tryb zwykły, rekurencyjny i
rozwijany per dataset; dopasowanie baz incremental po nazwie, GUID i bookmarku;
wznawianie transferów; `zfs hold` w locie; kompresja, limit pasma i autotuning;
quiesce VM/CT; retencja wiekowa, liczbowa i GFS; usuwanie osieroconych
bookmarków; monitoring wieku snapshotów i pul; generowanie zadań z INI;
praca jako root i przez konta delegowane; bootstrap i audyt hosta; `--pair`,
`--join`, rotacja, odwołanie klucza i `--unpair`; zewnętrzny kontroler
aktualizacji i rollbacku.

## 3. Transakcja nadania grantu quiesce — stan bieżący

Ta sekcja istnieje, żeby nie trzeba było odtwarzać projektu z trzech
chronologicznych odpowiedzi. **To jest opis kodu, który jest w drzewie teraz.**

`install_quiesce_grant()` operuje na trzech plikach:

```
/usr/local/sbin/zfs-quiesce-helper      kod, WSPÓŁDZIELONY przez wszystkie peery
/etc/zfs-quiesce-allow/<konto>          które guesty konto może zamrozić
/etc/sudoers.d/zfs-quiesce-<konto>      sam grant; bez niego nic nie jest nadane
```

Kolejność faz: zależności → generowanie i walidacja w `mktemp` → utworzenie
katalogu whitelisty → **sweep** pozostałości po przerwanym przebiegu → staging →
kopie zapasowe → **commit** → sprzątanie.

**Nic nie jest zapisywane w miejscu.** Każdy plik ląduje jako `<cel>.zqg-new` we
własnym katalogu docelowym i jest przemianowany na cel. `rename(2)` jest atomowy,
więc każda chwila crashu zastaje cały stary albo cały nowy plik. Staging obok
celu, a nie w `/tmp`, jest tym, co czyni z tego rename zamiast kopii przez
granicę systemu plików.

**Kolejność commitu — najpierw wyłączenie aktywnego grantu:**

```
0. mv  <reguła>            <reguła>.zqg-bak     zawieszenie grantu (tylko update)
1. mv  <whitelista>.zqg-new <whitelista>
2. mv  <helper>.zqg-new     <helper>
3. mv  <reguła>.zqg-new     <reguła>            uzbrojenie nową regułą
```

Każda przerwa daje stan o **mniejszych** uprawnieniach niż na starcie. Krok 0 jest
pomijany przy pierwszej instalacji, więc świeży enroll nie ma przerwy w dostępie.

Wcześniejsza wersja commitowała whitelistę jako pierwszą, uzasadniając to tym, że
jest „ograniczeniem". To było błędne i wyłapał to REV-20260731-012: przy
**aktualizacji** finalna reguła już istnieje i jest aktywna przez cały commit, więc
szersza whitelista działa od momentu swojego rename — a crash utrwalał poszerzenie.

Zawieszenie jest samo w sobie rename, na ignorowaną nazwę `.zqg-bak`, więc jest
atomowe i **jest** krokiem zachowania kopii dla reguły. Dlatego reguła jako jedyna
nie dostaje twardego dowiązania: `rename()` na dwie nazwy tego samego i-węzła jest
wg POSIX no-opem, więc dowiązanie sprawiłoby, że reguła zostałaby żywa przez cały
update — cichy powrót tego samego defektu, przy zielonym pakiecie testów.

Koszt: okno w trakcie aktualizacji, w którym konto nie może zamrozić niczego.
Świadomy wybór — nieudany job jest widoczny i ponawiany, po cichu poszerzony grant
nie jest.

**Przerwana aktualizacja zostaje WYŁĄCZONA i taka pozostaje**, dopóki jakiś
przebieg się nie dokończy. Sweep rozróżnia trzy przypadki: `.zqg-new` → usuń
(martwy staging); `.zqg-bak` przy istniejącym celu → usuń (kopia zbędna);
`.zqg-bak` **bez celu** → **zostaw zaparkowane**, nie uzbrajaj.

Wcześniejsza wersja przywracała taką kopię z powrotem, w obawie o utratę jedynego
egzemplarza. Wyłapał to REV-20260731-013: w momencie parkowania reguły poprzedni
przebieg zdążył już wgrać nową, **szerszą** whitelistę — więc przywrócenie starej
reguły uzbrajało ją przeciwko tej whiteliście. To samo poszerzenie, które zamknął
REV-012, przeniesione z commitu do odzyskiwania. Nic nie ginie przez parkowanie:
plik leży pod nazwą, którą sudoers.d ignoruje, a `pre_rule` liczone jest po
sweepie, więc krok 0 się pomija i nowa reguła wchodzi jako ostatnia.

**Rollback rozróżnia tworzenie od nadpisania.** `pre_*` mówi „istniał, więc
przywróć", `did_*` mówi „próbowano zapisu, więc się tym zajmij" i jest ustawiane
**przed** commitem. Dla helpera i whitelisty kopia zapasowa to **twarde
dowiązanie** do oryginalnego i-węzła — niesie treść, właściciela, tryb i xattry
przez tożsamość, nie przez kopię, która mogłaby coś zgubić. Dla reguły kopią jest
sam rename zawieszający (powód wyżej). Przywracanie to w obu przypadkach rename,
więc rollback też jest atomowy. Komunikat rozróżnia „przywrócono poprzedni grant"
od „usunięto to, co ten przebieg utworzył", a nieudane przywrócenie krzyczy
zamiast udawać sukces.

**Recovery to „uruchom ponownie".** Pozostałości są zamiatane i raportowane, nigdy
odtwarzane — funkcja i tak przepisuje wszystkie trzy cele, więc odtwarzanie połowy
intencji byłoby zgadywaniem. Jedyny wyjątek to opisane wyżej przywrócenie kopii,
która została jedyną.

**Detal nośny dla całości:** `/etc/sudoers.d` jest czytany przez sudo, a staging
reguły w środku jest bezpieczny **wyłącznie** dlatego, że sudoers.d ignoruje każdą
nazwę zawierającą kropkę. Zweryfikowane na żywym `visudo 1.9.5p2` w izolowanym
drzewie, z kontrolą negatywną. Ta sama reguła w drugą stronę: konto z kropką w
nazwie dałoby finalną regułę niewidoczną dla sudo — `pc_is_account` tego zabrania.
Ponowna weryfikacja przy każdej aktualizacji sudo jest zapisana w `deps.conf`.

Pakiet `sudo` instaluje **wyłącznie** ta funkcja, czyli tylko przy
`--allow-quiesce`. Zwykły deploy nie dotyka pakietu.

## 3b. Profil wdrożeniowy (`zfs-backup.sh`) — stan bieżący

Wysokopoziomowy przepływ ukrywa `pair`/`join`:

```
setup-server → add-client → seed → verify-endpoint → activate-client
             → status / test / migrate-profile / remove-client
```

**Dwa sposoby wyboru datasetów w `add-client` (REV-033 plasterek 6).**
`--datasets="A B"` (jak dotąd) nazywa je z góry, tu, na kolektorze.
`--mode=backup|sync` odsuwa wybór na źródło: `add-client` przekazuje
`--mode=` do `deploy.sh --pair` zamiast `--peer-datasets`, a peer wybiera
przez `--draft-scope`/edycję/`--commit-scope` na SOBIE (plik zakresu,
`lib-scope.sh` — patrz wpis "REV-20260802-033 plasterek 4" w historii
wyżej). Każda następna
komenda (`seed`, `verify-endpoint`, `activate-client`, `migrate-profile`)
wygląda identycznie dla obu ścieżek — `load_client_and_connection` woła
`resolve_mode_datasets`, które dla klienta trybowego pobiera committed
scope peera przez ssh, weryfikuje sha256 (T3) i wylicza realną listę
liści przez zdalne `zfs list -r`, wypełniając `PEER_SAVED_DATASETS`
dokładnie tak, jak zrobiłby to ręcznie podany `--peer-datasets`. Wynikiem
`activate-client` jest zawsze GOTOWY config, od razu instalowany po
potwierdzeniu — nie kandydaci do ręcznej selekcji.

**Jedna kadencja wysyłki, jedna drabina.** Na klienta generuje się: jedna linia
`snapget` per dataset (co godzinę o :01), jedna
`delsnaps -G -R <cel>/<label> "automated_" -H24 -D7 -W4 -M12` (o :21) i **jeden**
monitor na `automated_hourly`.

Wcześniejsza wersja miała cztery kadencje wysyłki obok drabiny — REV-016 wykazał,
że to łączy oba modele bez korzyści z żadnego: `-G` kubełkuje po **czasie** i nie
patrzy na prefiks, więc wysyłki dzienna/tygodniowa/miesięczna nie definiowały
żadnego tieru, tylko dokładały snapshoty i transfery, w dodatku startując o tej
samej minucie.

Progi monitora są **tylko** na najdrobniejszym tierze — monitor na
`automated_daily` pilnowałby wzorca, którego nic nie tworzy, i stałby na CRITICAL
w nieskończoność.

**Akceptacja przed instalacją.** `activate-client` pokazuje dwa diffy: proponowany
config oraz zmianę w cronie, gdzie lewa strona to **realnie zainstalowany blok**
odczytany z `crontab -l`, a nie ponowny render configu. Nieczytelny crontab
przerywa przed pytaniem — „nie dało się odczytać" to nie to samo co „jest pusty".

**Migracja starego profilu** to akcja narzędzia (`migrate-profile`), nie ręczna
edycja szablonów: usuwa stare szablony, przebudowuje aktywnych klientów tą samą
funkcją co aktywacja, waliduje, pokazuje diff i pyta raz.

**Faza 4 (2026-08-10, commit `9074fe5`): `add-client --profile=NAME`.** Wybór
profilu w momencie CREATE, walidowany (`profile_validate_dir`) zanim dojdzie
do parowania, zapisywany w rekordzie klienta. Pominięty → `default`, ścieżka
bez wyboru bez zmian. `activate-client` czyta ten wybór **wyłącznie** przy
pierwszej aktywacji (`apply_client_profile_choice()`) — reaktywacja nigdy go
nie konsultuje, ta sama jednokierunkowa granica co REV-089 dla profilu w
ogóle, więc stary rekord klienta sprzed tej zmiany (bez pola `PROFILE`) to
no-op, zero migracji. Podgląd „candidate CONFIG + cron przed instalacją" już
istniał (`show_activation_proposal`/`atomic_replace_and_install`) — nic
nowego tu nie trzeba było budować. Obecnie istnieje tylko jeden profil
(`profiles/default`), więc realna wartość na razie to sam mechanizm wyboru;
kolejne nazwane profile to osobna decyzja produktowa, nie ta zmiana.
`test/zfsbackup/run.sh` sekcja 53: 358/358 (cała suita). Nie wykonane:
`zfsbackup-live-pair` (potrzebuje dwóch żywych hostów + root — realny
`deploy.sh --pair`/`snapget.sh -n`/`gen-cron.sh --install`), zgłoszone jako
obowiązek ręczny.

**Limit pasma** `--bandwidth=N` (bajty/s, `mbuffer -r`) jest **per proces
transferu**, nie sumaryczny dla relacji. W praktyce dla pojedynczego zadania
znaczy to tyle samo: datasety w jednym wywołaniu `snapsend` idą sekwencyjnie
(snapsend.sh:2012 — bez `&`), a generator scala datasety o wspólnym
harmonogramie w jedną komendę. **Ale dwa nakładające się zadania tej samej
relacji** (np. przeciągnięty hourly i startujący daily) **sumują się do 2×N** —
dziś zamek w `snapsend` jest kluczowany na `(datasety, cel, prefiks)`, więc łapie
hourly-na-hourly, a nie hourly-na-daily. Naprawa jest w NOW (zamek kluczowany
etykietą relacji). Pułap **całego kolektora** to osobna sprawa, świadomie
odłożona — kilka relacji nadal może sumować się ponad N.

**Pełny cykl przetestowany na żywo 2026-08-01** (metropolis, pve1 jako kolektor
jako root, pve2 jako źródło): `setup-server` → `add-client` → paczka → `--join` →
`seed` (40 MB realnego transferu) → `verify-endpoint` → `activate-client` →
uruchomienie wszystkich trzech wygenerowanych linii → `remove-client` → teardown.

Wynik: 15 → 18 linii crona, **każda produkcyjna linia obecna co do znaku**, po
teardownie crontab **identyczny** ze zrzutem sprzed testu, zero pozostałości na
obu hostach. Drugi transfer był przyrostowy (cel nie urósł), drabina GFS zostawiła
najnowszy snapshot i usunęła starszy z tego samego kubełka, monitor `rc=0`.

Test znalazł **realny błąd**, którego żaden test lokalny nie mógł znaleźć: drugi
argument `snapget.sh` to baza lokalna, a wrapper podawał ścieżkę końcową — seed
lądował o poziom za głęboko, niewidoczny dla zadania crona (`base=null`, pełny
transfer w kółko), a `verify-endpoint` meldował sukces, bo szukał w tym samym złym
miejscu. Naprawione, zapięte testem parzystości z generatorem.

Nie zrobione: konto dedykowane na kolektorze **nie zostało przetestowane na żywo**
(kod jest, test przeszedł w kształcie rootowym); `migrate-profile` przetestowany
tylko w częściach składowych.

## 4. `sqlfreeze` — co dowodzi, a czego nie

`zfs-quiesce-helper sqlfreeze <id> [sekundy]` czyta zdarzenia SQL Server 3197
(„I/O is frozen") i 3198 („I/O was resumed").

Odpowiada na: *czy SQL brał udział w co najmniej jednym freeze/resume w tym
oknie*. **Nie** odpowiada na: *czy zrobił to ten konkretny backup* — zdarzenie nie
niesie tożsamości requestera. Werdykt niesie to zastrzeżenie w swoim własnym
wyjściu.

Liczenie jest **per instancja** (`MSSQLSERVER`, `MSSQL$<nazwa>`), nigdy per baza:
nazwa bazy jest w tłumaczonym tekście komunikatu, a parsowanie tłumaczeń to błąd,
który wcześniej wywrócił parser `writers`.

Nie jest wpięty w żaden automatyczny werdykt: ani w profil `standard`
`zfs-backup.sh`, ani w żadną linię crona, i żadna ścieżka kodu nie czyta jego kodu
wyjścia.

**Poprawka z 2026-07-31 wieczorem:** zastrzeżenie o korelacji było drukowane
bezwarunkowo, więc przy `verdict=no-freeze-seen` pod werdyktem „nie widziano
zamrożenia" stało zdanie „SQL uczestniczył w co najmniej jednym freeze/resume".
Sprzeczność, i to w stronę zmyślania dowodu. Wyszło dopiero na żywym guescie bez
SQL Servera — wszystkie fixture'y w testach miały zdarzenia, a asercja sprawdzała
tylko, czy notka istnieje. Notka jest teraz warunkowa, a przypadek zapięty
testem.

## 5. Testy — stan bieżący

Uruchomione lokalnie przy `55d33a2` (bez roota, bez ZFS, bez sieci). Pakiety
wskazane przez `./test/impact.sh` dla zmian tego dnia (`quiescehelper`, `join`,
`selfupdate` dla `deploy.sh`; `quiesce`, `statekey`, `tune` dla
`lib-zfs-snap.sh`) przebiegnięte ponownie przy tym commicie. **2026-08-06
(REV-046):** komplet suit wymaganych grafem dla zmiany w `deploy.sh`
przebiegnięty ponownie na diffie `a567328..HEAD` — `alertmail` 18/18 (nowa),
`draftscope` 26/26, `impact` 21/21, `join` 82/82, `joinmanifest` 10/10,
`joinremote` 8/8, `pause` 74/74, `quiescehelper` 119/119, `selfupdate` 28/28
(7 SKIP); zero błędów:

| Pakiet | Wynik | Zakres |
|---|---|---|
| `impact` | **56/56** | rozwiązywanie grafu testowego + `--verify` na prawdziwym drzewie. +15 (REV-20260807-068, **cztery rundy**): niezmiennik świeżości `PROJECT_STATUS.md` dotyczy **PROSPEKTYWNEGO DRZEWA COMMITA** — wpisów indeksu, czyli `<tryb> <obiekt> <ścieżka>`. Runda 1: SHA commita, niesprawdzalny przed własnym commitem. Runda 2 (odrzucona): skrót z drzewa roboczego, a `git commit` zapisuje indeks. Runda 3 (odrzucona): indeks, ale sam identyfikator obiektu — `git update-index --chmod=+x` zmienia prospektywny commit, nie ruszając bloba, więc bramka mówiła czysto, a commit zapisywał zmianę istotną dla zachowania (`100755`→`100644` na skrypcie produkcyjnym oznacza, że przestaje się uruchamiać). Runda 4: skrót po pełnym wpisie stage-0. Wszystko, na czym opiera się werdykt, pochodzi z indeksu: wpisy obserwowane, `PROJECT_STATUS.md` ze znacznikiem i `deps.conf`, który DEFINIUJE zbiór obserwowany. Gwarancja: po zielonym `--verify` zwykły `git commit` bez ruszania indeksu daje drzewo spełniające niezmiennik (`commit -a`, `commit <ścieżka>` i `--amend` ruszają indeks i są jawnie poza gwarancją). Każdy przypadek to osobne repozytorium git z KOPIĄ badanego skryptu, więc ta sama konstrukcja uruchamia kontrolę (`IMPACT_UNDER_TEST=`). Jeden przypadek z rundy 2 ODWRÓCONY: edycja niezainscenizowana nie wchodzi do commita, więc nie brudzi bramki. Kontrole: wobec `41bd774` padają 3 asercje (rozjazd indeks/status), wobec `c077b82` **dokładnie 1** (sam tryb) — reszta przechodzi, więc runda 4 jest addytywna | +10 (Etap 3, ZAMROŻENIE SILNIKA): `snapsend.sh`, `snapget.sh` i `lib-zfs-snap.sh` mają zapisaną linię bazową (wpis indeksu: tryb + obiekt, ten sam prymityw co niezmiennik świeżości) w `docs/project/ENGINE-FREEZE.md`. Zmiana zainscenizowana wobec pliku zamrożonego jest **odrzucana**, z nazwaniem pliku; zmiana samego trybu też. Odmowa ustępuje wyłącznie, gdy znacznik `unfreeze:` nazywa recenzję, która ISTNIEJE i nie jest jeszcze CLOSED — recenzja domknięta nie może autoryzować nowej pracy, bo już dostała odpowiedź. `--refreeze` przejmuje nową linię bazową z indeksu i **resetuje autoryzację**, żeby nie została wisieć. Plik spoza zamrożenia nie jest łapany. Świadomie NIE jest odporne na obejście: każdy może uruchomić `--refreeze` — usunięte jest wyłącznie zdarzenie CICHE, bo zmiana silnika wymaga teraz albo nazwanej recenzji, albo widocznego resetu w diffie. +11 (REV-20260808-070): zbior zamrozony to **piec** zatwierdzonych plikow (doszly `delsnaps.sh` i `check-snap-age.sh` — pierwsza wersja ZAWEZALA zatwierdzony kontrakt zamiast go zaimplementowac); autoryzacja jest ZWIAZANA ZE SCIEZKA — recenzja musi niesc recenzencki znacznik `authorizes-frozen:` wymieniajacy kazda zmieniona sciezke, bo wczesniej DOWOLNY otwarty watek przepuszczal dowolna zmiane silnika; `ENGINE-FREEZE.md` jest w grafie zaleznosci, bo to polityka wykonywalna, nie dokumentacja. Zbior zamrozony w testach jest WYPROWADZANY z dokumentu, nie spisany drugi raz |
| `gencron` | 58/58 (+2: golden `pair-label`, negatyw `pair-label-charset`) | parsowanie konfiguracji `gen-cron.sh`, golden + przypadki negatywne |
| `scope` | **34/34** | gramatyka pliku zakresu (REV-033 F2): sekcje `[dataset:]`, `include_parent`/`include_children`/`exclude`/`exclude_tree`, odmowy z numerem linii oraz decyzja „czy ten dataset jest w zakresie" |
| `cron` | **124/124** (+2 sekcja V: tryb pliku zamka, znaleziony na zywo 2026-08-06) (bez zmiany liczby — nowe funkcje ćwiczone przez `pause`) | `lib-cron.sh` — jedyny pisarz crontaba: blok zastępowany w miejscu, wszystko poza nim bajt w bajt, markery zepsute odrzucane a nie naprawiane, `crontab(1)` zaślepiony (także tryb „przyjmuje zapis i przechowuje co innego"), zamek per-użytkownik z wymuszonym przeplotem dwóch procesów (REV-034 F2, +14), całościowy zapis `cron_replace_all` z odczytem zwrotnym (REV-034 F3, +9), jeden stały katalog blokad bez fallbacku per-caller (REV-035, +8, część SKIP na tej maszynie). Od REV-036 F5 biblioteka sama rozpoznaje zapauzowany kształt (`cron_fullcron_paused`/`cron_block_paused`) i odmawia przez `cron_paused_guard` w `cron_block_install_impl`/`cron_block_ensure_line_impl`/`cron_block_remove_impl` — ćwiczone przez `pause` (sekcje S/T), nie tu |
| `profiles` | **39/39** | granica profilu (REV-073, EGZEKWOWANA od REV-076). Regula „profil nie posiada topologii” zyla wylacznie w tej suicie: zaden kod produkcyjny nie odwolywal sie do `profiles/`, a `validate_fragment` bylo zdefiniowane wewnatrz pliku testowego. Do tego `templates.conf` bylo sprawdzane tylko pod katem ksztaltu naglowka, wiec profil mogl niesc `dst` i suita przechodzila. ZMIERZONE: dopisanie `dst = hdd/evil` do wbudowanego profilu zostawia STARA suite na 22/22, a poprawiona odmawia z podaniem pliku, linii i pola. Teraz `lib-profile.sh` jest walidatorem PRODUKCYJNYM, a suita wola jego — test nie moze poblogoslawic reguly, ktorej produkcja nie wykonuje. Schemat CONFIG v4 celowo NIE zostal zawezony: `src`/`dst` w `[template:]` sa legalne i pve0 uzywa tego produkcyjnie (`[template:vm_archive]` z `dst = hdd/backups/pve1`), bo szablon to konstrukcja WDROZENIA, a profil jest szablonem OGRANICZONYM. Nazwy pol nadal czytane z `--dump-fields`, nigdy powtorzone. +6 (REV-20260809-077 F1): `profile_validate_dir` ZAWODZILA OTWARCIE na niekompletnym profilu. Napisalem `[ -f "$dir/x" ] && ! validate`, co znaczy „jesli istnieje i padnie, zglos” — wiec BRAKUJACY artefakt zwracal sukces z granicy produkcyjnej, a pusty katalog walidowal sie czysto. Suita tego nie widziala, bo sprawdzala osobno, ze pliki wbudowanego profilu istnieja — inna wlasnosc, ktorej B1 by nie odziedziczyl. Profil to DOKLADNIE trzy artefakty i kompletnosc nalezy do tej samej granicy; przeniesienie jej do wolajacego odtworzyloby problem, ktory usunela REV-076. Kontrola wobec `bd9de5a`: **4 asercje padaja** (trzy brakujace artefakty i pusty katalog); brak katalogu i kontrola pozytywna przechodza tam tez i sa pokryciem regresyjnym |
| `reviewctl` | **36/36** (PROTOCOL V2) | maszyna stanów recenzji: stan jest **wyprowadzany** z nagłówków maszynowych w plikach recenzji/odpowiedzi/domknięcia, a `REVIEW_LEDGER.md` i `OPEN-THREADS.md` są generowane. Przypina macierz akceptacji z protokołu — w tym dwa przypadki, których ręcznie utrzymywana tabela nie mogłaby złapać: akceptacja wskazująca **inny** commit niż zgłoszony, i domknięcie bez akceptacji. Dwa realne błędy w samym generatorze wyszły z tych testów, w tym fail-open: stan liczony w podstawieniu poleceń gubił błędy w podpowłoce i zapisywał ledger z rc=0. +11 (REV-20260807-067): nagłówek niosący commit musi nazywać commit **osiągalny z opublikowanej gałęzi**. Osiągalność, nie rozwiązywalność — SHA, które wywołało tę recenzję, JEST prawdziwym commitem w klonie implementera, osieroconym przez przepisanie, więc `git cat-file -e` by je przepuścił, a recenzent i tak dostawał z GitHuba „No commit found". Przypadek sieroty buduje własny wiszący commit przez `git commit-tree`, zamiast polegać na tym, który akurat istnieje lokalnie. Trzy pola: `implementation`, `reviewed-implementation`, `closed-by`. Brak repozytorium git = odmowa, nie cisza. Kontrola negatywna wobec `2620824`: **6 nowych asercji pada, 22 strukturalne przechodzą**. +6 (REV-20260808-070 F4): STAN DOSTAW. Pod wyjatkiem direct-main implementer laduje pierwszy, ale marszruta byla wyprowadzana WYLACZNIE z artefaktow REV — wiec dostawa bez REV-a byla niewidzialna: `OPEN-THREADS.md` mowil, ze nie ma nic do zrobienia, gdy Etap 3 lezal na `main` bez werdyktu. Jedna linia `<!-- delivered: <sha> opis -->` w `docs/project/DELIVERIES.md` staje sie praca przypisana recenzentowi, az zostanie wyczyszczona JAWNIE: albo recenzent otworzy REV o tym SHA, albo zapisze `no-review-required`. SHA podlega tej samej regule osiagalnosci co SHA implementacji. +2: wada znaleziona przez UZYWANIE mechanizmu — czyszczenie dostawy zalezalo od tego, ze jakis REV AKTUALNIE wskazuje ten SHA, a `reviewed-implementation` jest wskaznikiem RUCHOMYM: recenzent przesuwa go na kazde kolejne zgloszenie. Gdy watek posunal sie dalej, dostawa wracala jako niezrecenzowana — i robilaby tak juz zawsze. „Zostalo zrecenzowane” to fakt o przeszlosci i musi byc zapisany jako fakt: znacznik `<!-- reviewed-by: <sha> REV-... -->` |
| `monitor` | **24/24** (nowa, REV-056) | `check-snap-age.sh`: gdy nic nie pasuje do wzorca, wiek liczony z `creation` DATASETU przez tę samą drabinkę progów — świeży dataset czyta się OK, trzydniowy bez kopii nadal CRITICAL. Nieodczytany znacznik czasu to UNKNOWN, nigdy zmyślony wiek (dotyczy też ścieżki pasującego snapshotu, gdzie ten sam błąd siedział wcześniej). `zfs` to zaślepka w `PATH`, wszystkie czasy jako offset od jednego `NOW` — bez roota, bez ZFS-a, bez wyścigu z zegarem |
| `migrate` | **52/52** lokalnie i jako root na Linuksie, **54/54** jako konto delegowane (REV-057 + REV-058) | `gen-cron.sh --migrate-recursion`: wykrywanie przez ten sam przebieg opcji co walidator (`-m R-daily_` nietykane, `-Rv 3` rozdzielane), porównanie trójstronne z kontrolą jako pierwszą, zapis transakcyjny. Każdy przypadek odmowy sprawdza sumę kontrolną pliku źródłowego, nie tylko komunikat. Sekcja G (REV-058) odtwarza topologię root + konto delegowane zaślepkami `crontab`/`getent`/`id`: kontrola znajduje blok po linii `# Source:` u dowolnego użytkownika, a nieczytelny crontab, nieczytelna lista użytkowników i dwa pasujące bloki — odmawiają przed zapisem. D4 (nieudany zapis) wymaga nie-roota — pod rootem SKIP, bo root omija prawa katalogu |
| `cron2conf` | 10/10 | odtwarzanie configu z crontaba — round-trip przez prawdziwy `gen-cron.sh`, przypadki negatywne/ostrzegawcze |
| `localbackup` | **35/35** (Faza 5 slice 1; +6 REV-097; +2 REV-098; +5 REV-101; +5 REV-102 krok 2 lokalny; +4 REV-20260811-104 F1 niezależne szablony) | `zfs-backup.sh --source/--target` (bare, kanoniczne; `local-backup` alias) — wysokopoziomowy LOKALNY workflow source→target, wycinek PLANOWANIA (read-only, jak `restore --plan`). **REV-097:** F1 — źródło musi ISTNIEĆ w ZFS (`zfs list`, stub w teście), brakujące = twarda odmowa całości bez fallbacku; F2 — kandydat komponowany ADDYTYWNIE nad istniejącym CONFIG celu (istniejący job A zachowany bajt-w-bajt, wyrenderowany cron niesie A+B, overlap odmawia, brakujący CONFIG roszczony przez zainstalowany blok = fail-closed odmowa przez WSPÓLNY guard `assert_config_not_claimed_if_missing` wyodrębniony z `ensure_cron_config`); F3 — kanoniczne publiczne wejście to bare `--source/--target`, alias `local-backup` sięga tej samej logiki. **REV-098:** guard overlapu rozwija listy przez przecinki (`[prune:a,b,c]` — jak `config_datasets()`) i sprawdza każdego członka osobno; regresja pinuje odmowę przy overlapie z NIE-pierwszym członkiem `[prune:rpool/other,rpool/data]` + kontrolę że rozłączne żądanie obok tej samej wielościeżkowej sekcji dalej przechodzi (nie „każdy przecinek = konflikt"). Pinuje: odmowę nakładania w OBU kierunkach (cel pod źródłem, źródło pod celem, równe — backup nie może lądować w tym co backupuje; czysty test prefiksu ze `/`, odporny na `data` vs `database`), odmowę zdalnego (`:` = LOCAL only; `@host` łapie char-check), brak `--source`/`--target` i nieznany `--profile` odmawiają, kandydat CONFIG v4 renderuje się przez PRAWDZIWY `gen-cron.sh` z lokalnym `dst=` send (bez `:`) i znamespace'owanymi szablonami domyślnego profilu + drabiną GFS, jedna faktyczna nota przy wspólnej puli (nie zakaz), a planowanie NIE instaluje niczego (stub `crontab` w PATH nigdy nie wołany). Instalacja transakcyjna = kolejny wycinek. **REV-101:** multi-source WHAT — `--source=a,b,c` (i akumulacja powtórzonych flag, bez last-one-wins), każdy root walidowany (missing→refuse całości bez partiala), overlap parent/child w zbiorze odmawia, duplikat kanonizowany do jednego, po jednym `[dataset:root]` na root + jeden `[prune:target]`, gen-cron merge'uje w jedną comma-joined linię send (kształt jak golden `tiered.conf`). **REV-102 (krok 2, lokalny):** kandydat niesie teraz DWIE niezależne retencje — `[prune:root]` per root (ograniczenie `automated_hourly_` na ŹRÓDLE, drabina GFS z `prune.inc`) ORAZ `[prune:target]` (magazyn) — z tej samej drabiny przy CREATE, ale osobne edytowalne sekcje; wyrenderowany cron ma dwie osobne linie delsnaps (source i target scope), manualne snapshoty przeżywają (pattern `automated_`, nie `*`); kontrola out-of-band vs baza `5423518` = 0 sekcji source-prune (defekt), nowy kod = 1. **F2 (recenzja kroku 2):** source-prune był `recursive=yes` (→ `delsnaps -R`) mimo że `[dataset:root]` jest non-recursive — wchodził w dzieci (`root/vm-101`) i mógł kasować `automated_` spoza pokrycia relacji; poprawione na non-recursive (`delsnaps -G` bez `-R`, tylko nazwany dataset), test pinuje brak `-R` + kontrolę „dziecko przeżywa". **REV-104 F1:** source i target referowały TE SAME szablony (`profile__default__keep_*`) → edycja jednej strony zmieniała obie; teraz source dostaje odrębną rodzinę `profile__default__src_keep_*` (te same wartości przy CREATE, różna tożsamość, rename `__keep_`→`__src_keep_` namespace-agnostic). Testy: mutacja tylko source → zmiana source, target nietknięty (i odwrotnie); negctl: wspólna rodzina łączy obie (load-bearing). Remote-PULL/grant/migracja/real-ZFS = kroki 3–5 (REV-102 OPEN). Bez ZFS/sieci/crontaba |
| `configexamples` | **24/24** (nowa REV-20260810-094; +3 total-coverage guard REV-20260810-096) | runnable przykłady `docs/examples/*.conf` renderowane prawdziwym `gen-cron.sh -c`. Warstwa 1: każdy przykład (także przyszły) musi się sparsować (exit 0). Warstwa 2: przypina semantyczne własności linii, których każdy przykład uczy — niezależne liczniki `-H24`/`-D14` i BRAK drabiny GFS, per-dataset `-q agent`/`-q sync` z trzema nierozłączonymi liniami send, krótka lokalna `-H48` vs magazyn `-D90`, monitor-carrier `prune=no` emitujący `check-snap-age` bez drugiej linii `delsnaps` na tym samym zakresie, linia prune bookmarków. Krawędzie grafu: zmiana `gen-cron.sh` LUB `docs/examples/*.conf` selektuje tę suitę, suita selektuje samą siebie. Kontrola negatywna wewnątrz suity (mutacja `keep 24→99`) plus zweryfikowane osobno: cała suita wychodzi rc=1 gdy prawdziwy przykład zdryfuje. Warstwa 3 (REV-096): meta-guard trzymający rejestr `COVERED` DOKŁADNIE równym zbiorowi `docs/examples/*.conf` — dodanie 5. przykładu bez rejestracji semantyki albo wpis rejestru bez pliku = FAIL (dowiedzione: realny 5. `.conf` bez rejestracji wywala suitę). Dwie kontrole negatywne na FIXTURZE (katalog tymczasowy z nierejestrowanym `.conf`; rejestr z nazwą bez pliku), bez ruszania realnego drzewa |
| `quiesce` | **161/161** | księgowanie `-q`: własność guesta, deduplikacja, trasa uprzywilejowana lokalnej ścieżki (+10) odmowa zamiast degradacji (+14, REV-023) **oraz okno zamrożenia jako termin (+15, REV-024)** |
| `tune` | 48/48 | cache autotune `-A` |
| `twins` | **24/24** | alarm dryfu ośmiu funkcji, które `snapsend.sh` i `snapget.sh` definiują pod TĄ SAMĄ nazwą i sygnaturą (`get_sorted_snapshots`, `find_conflicting_snapshots`, `find_recursive_name_collisions`, `validate_snapshot`, `find_common_snapshot`, `create_snapshot`, `transfer_data`, `process_dataset`). Przypięty skrót na kopię; zmiana po jednej stronie bez drugiej = FAIL nazywający, która strona się ruszyła. **Nie twierdzi, że bliźniaki są równoważne** — nie są i nie powinny być (`process_dataset` różni się w 450 z ~550 linii, bo push czyta lokalnie i pisze zdalnie, a pull odwrotnie). Zmiany wyłącznie w komentarzach i białych znakach są normalizowane, żeby blessowanie nie stało się odruchem. Cztery tryby awarii zweryfikowane przy budowie: zmiana jednostronna, obustronna, sama zmiana komentarza (cisza), przemianowanie funkcji |
| `statekey` | 16/16 | klucz stanu i jego kolizje |
| `selfupdate` | 28/28 (7 SKIP) | kontroler aktualizacji i rollbacku |
| `zfsbackup` | **363/363** (zmierzone 2026-08-10; Faza 4 sekcja 53 +6 commit `9074fe5`; REV-20260810-095 sekcja 54 +5) | Faza 4 (sekcja 53, +6, commit `9074fe5`): `add-client --profile=NAME` waliduje profil (`profile_validate_dir`) przed parowaniem, zapisuje wybór w rekordzie klienta; `apply_client_profile_choice()` konsultuje go WYŁĄCZNIE przy pierwszej aktywacji, nigdy przy re-aktywacji — ta sama jednokierunkowa granica co REV-089 dla profilu w ogóle. Testy: nieznana nazwa profilu odmawia przed jakimkolwiek `deploy.sh --pair`; pominięta flaga zapisuje `default` (ścieżka bez wyboru bez zmian); realny drugi profil jest walidowany i zapisywany poprawnie; `apply_client_profile_choice` przetestowane jednostkowo dla wszystkich trzech przypadków (przyjęcie przy pierwszej aktywacji, ignorowanie przy re-aktywacji, no-op na starym rekordzie klienta bez pola `PROFILE`). +5 (REV-20260810-095, sekcja 54): dowód przez REALNY `cmd_activate_client()`, nie tylko helper — z `PROFILE_ACTIVE=default` w env, `PROFILE=alt` z rekordu przebija przez `apply_client_profile_choice` i steruje renderowanym CONFIG-iem (marker: kadencja `send_schedule = 7 * * * *`), a ta kadencja dochodzi do wygenerowanego crona przez prawdziwy `gen-cron.sh`; ścieżka default (pominięty `--profile`) daje semantykę default; reaktywacja dalej ignoruje profil (jednokierunkowa granica REV-089). Kontrola negatywna: neutralizacja `apply_client_profile_choice` w subshellu → zapisany `PROFILE` bezczynny, kandydat wraca do default. Bezpieczne na hostach z crontabem — stub `$SNAPGET` łapie workfile i wychodzi ≠0, więc run umiera na „not installing" PRZED grant-checkiem i instalacją. Nie wykonane: `zfsbackup-live-pair` (prawdziwy `deploy.sh --pair`/`snapget.sh -n`/`gen-cron.sh --install` na dwóch żywych hostach z rootem), zgłoszone jako obowiązek ręczny.

REV-20260810-092 (sekcja 52, +6): recenzent, weryfikując REV-091, znalazł niezależną pozostałość w GATE 2, nie w Fazie 3. `[excluded:]` to sekcja NICZYJA — `gen-cron.sh` skleja wszystkie w jeden `PROTECT_FLAGS` i dokleja go do KAŻDEJ generowanej linii prune w pliku — więc doklejenie brakującego progu przy dodawaniu nowej relacji przepisywało realne polecenie prune relacji już zainstalowanych, czyli łamało dokładnie tę własność, dla której Gate 2 istnieje („dodaj jedną nową niezależną relację → stare bez zmian"). Moja własna asercja z REV-091 nie mogła tego złapać: biegła na fixture zawierającym wyłącznie `[defaults]`, gdzie „instaluje progi" i „mutuje wspólną politykę" są nierozróżnialne, bo nie było czego zaburzyć. Naprawa wg czterech punktów recenzji: `config_has_relationship_policy()` (prawda, gdy istnieje jakakolwiek sekcja `[dataset:]`/`[prune:]`) plus czwarty parametr `global_policy_mode` (domyślnie `auto`, `always` dla `migrate-profile`). Gałęzi „odmów zamiast mutować" świadomie NIE zbudowałem i napisałem dlaczego: `[excluded:]` to jednolita polityka globalna, więc nowa relacja przy brakującym progu jest dokładnie w tym stanie, w którym już są wszystkie istniejące — nie ma konfiguracji, w której nowej nie da się bezpiecznie utworzyć, a stare działają dalej; krok 6 dowodu samej recenzji wymaga zresztą, żeby B powstało w tym stanie. Jedna rzecz ponad wymagane minimum, zgłoszona do odrzucenia: ścieżka odmawiająca naprawy OSTRZEGA, wymieniając brakujące progi — dziedziczenie zainstalowanej polityki jest poprawne, dziedziczenie jej po cichu nie. Asercje celowo na RENDEROWANYM poleceniu `delsnaps.sh`, nie na tekście configu: `PROTECT_FLAGS` powstaje po stronie generatora, więc równość sekcji nie testowałaby tego, co Gate 2 naprawdę obiecuje. Uboczna zmiana zachowania, nazwana wprost: ponowne uruchomienie `setup-server` na zapełnionym CONFIG-u też przestaje odtwarzać progi globalne. REV-20260810-091 (sekcja 51, +7, ZAMKNIĘTY): po REV-090 `ensure_cron_config()` nadal robiła dwie rzeczy bezwarunkowo — doklejała ogólnokonfiguracyjne progi `[excluded:]` i odmawiała na configu pre-GFS — więc `needs_profile=0` nie znaczyło „tylko topologia". Oba pod tę samą bramkę; detekcja pre-GFS zostaje bezwarunkowa (`PROFILE_GFS` czytają dalej kształt prune i podsumowanie), warunkowa jest sama odmowa. Pierwsza wersja bramki F1 była napisana jako `[ ... ] && \` przed pętlą `for` — jako OSTATNIA instrukcja funkcji ustawiałaby jej kod wyjścia na 1 przy zamkniętej bramce, czyli dokładnie ten kształt fail-open, dla którego otwarto REV-084; zamienione na jawny `if` + jawny `return 0`. Kontrola negatywna wobec `e26adc57…`: 343/346, te trzy to dokładnie nowe asercje dyskryminujące; pozostałe cztery (dwa warunki wstępne + dwie asercje, że próg i odmowa NADAL działają tam, gdzie polityka jest generowana) przechodzą po obu stronach z założenia. REV-20260810-090 (sekcja 50, +6, ZAMKNIĘTY): REV-089 zatrzymał regenerację TREŚCI sekcji, ale `cmd_activate_client()` dalej wołał `ensure_cron_config()`, która dalej bezwarunkowo ładowała profil (F1) i dalej doklejała brakujące szablony (F2). Mój dowód przy REV-089 nie mógł tego złapać: sekcja 49 wołała `emit_client_sections()` bezpośrednio i przez cały czas trzymała profil obecny i poprawny — zależność siedziała w wywołującym, którego nie przekroczyłem. LEKCJA: gdy własność brzmi „X nie zależy od Y", test musi USUNĄĆ Y; edytowanie Y i sprawdzanie, że nic się nie zmieniło, to słabsze twierdzenie wyglądające tak samo w zielonej suicie. Naprawa: profil jako zależność LENIWA, `client_section_plan()` jako jedyna implementacja podziału zachowaj/regeneruj (żaden profil nie jest czytany, żeby odpowiedzieć „czy profil jest potrzebny" — to byłoby cykliczne). Kontrola negatywna wobec `c5f04ab0…`: 335/339. REV-20260809-089 (sekcja 49, +11, ZAMKNIĘTY): `emit_client_sections()` przy KAŻDYM wywołaniu usuwał i odtwarzał wszystkie sekcje relacji z AKTUALNEGO profilu — poprawne dokładnie raz, przy CREATE, i cichy kasownik polityki przy każdej późniejszej re-aktywacji. Znalezione przez audyt ścieżki re-aktywacji pod kątem samej własności Fazy 3, spisane jako dyskusja PRZED implementacją (funkcja ma najdłuższą historię recenzji w repo: REV-034 F3, 036, 045, 033 U7/U9/U11, 083) i potwierdzone niezależnie jako REV-089 P1. Naprawa wg wymaganej korekty: pierwsza aktywacja bez zmian (pełna generacja), re-aktywacja bierze zainstalowaną sekcję za bazę i odświeża w miejscu WYŁĄCZNIE `src` i `flags`. Zbiór pól topologicznych wyprowadzony z kontraktów, nie zgadnięty: funkcja pisze od siebie cztery pola, `src`/`flags` zależą od `LOAD_ACCOUNT`/`LOAD_HOST`/`LOAD_FLAGS` (czyli dokładnie tego, co zmienia `set-endpoint`), a `pair_label`/`notify` są czystymi funkcjami nazwy relacji i ścieżki datasetu — nazwy relacji nie da się zmienić (nie ma komendy rename), a dataset o zmienionej ścieżce to inny dataset, który i tak trafia do gałęzi regeneracji; więc nadpisanie ich mogłoby zapisać wyłącznie identyczną wartość, a pozostawienie ich dodatkowo chroni edycję operatora. Sekcje `[prune:]` nie niosą żadnego pola topologicznego, więc własna sekcja prune nie jest ruszana wcale; w trybie sync `[dataset:]` i `[prune:]` leżą pod TĄ SAMĄ ścieżką, więc zachowanie jednej połowy bez drugiej pozwoliłoby prune ominąć sprawdzenie własności — stąd wymóg, żeby OBIE były własne, inaczej para jest regenerowana. Sprawdzenia znacznika własności i fail-closed bez zmian: sekcja, której klient nie jest właścicielem, nadal jest odrzucana, nigdy adoptowana po samym nagłówku. Dodano jedną NOWĄ odmowę: własna sekcja bez pola `src` nie da się odświeżyć, a ciche nic-nie-zrobienie zostawiłoby relację wskazującą stary endpoint z zerowym kodem wyjścia. `migrate-profile` przekazuje `1` jawnie — regeneracja z profilu jest całym sensem tej komendy, a odziedziczenie domyślnego `0` zamieniłoby ją w no-op (lekcja REV-088 F1 zastosowana w drugą stronę). Kontrola negatywna wobec recenzowanej bazy `8d0dc243…`: 328/333, a te 5 to dokładnie nowe asercje dyskryminujące (krok 5, 6, 6b, 7b i odmowa braku `src`). Pisząc krok 6 pierwsza wersja wyrażała dryf profilu WYMYŚLONYM polem — granica profilu je odrzuciła, więc wywołanie umierało i test „przechodziłby" udowadniając wyłącznie, że niepoprawny profil jest odrzucany; poprawione na pola PRAWDZIWE (`recursive` w `dataset.inc`, zmieniony `gfs_pattern` w `prune.inc`). REV-20260809-088 (+1 nad audytem Fazy 2): pierwsza wersja luki nr 6 (poniżej) wsadziła porównanie treści do `ensure_cron_config()`, wywoływanej przy KAŻDEJ (re)aktywacji — zamieniając regułę kolizji w momencie CREATE w stały bramkarz dryfu profilu, łamiąc jawną zasadę jednokierunkowego przekazania (PROFIL -> generuj raz -> CONFIG v4 -> prawda wykonawcza) i uzgodnioną już własność Fazy 3 ("re-aktywacja zachowuje zainstalowaną politykę"). Do tego porównanie było bajtowe, nie semantyczne, wbrew jawnemu brzmieniu Gate 2 ("identyczny szablon SEMANTYCZNIE może być użyty ponownie"). Naprawione (`20f333d9`): `ensure_cron_config()` dostała parametr `check_new_template_collision` (domyślnie 0, sprawdzenie wyłączone), `cmd_activate_client()` przekazuje `1` WYŁĄCZNIE gdy `STATE` przed wywołaniem było `endpoint_verified` (czyli to naprawdę pierwsza aktywacja NOWEJ relacji, nie re-aktywacja już aktywnej). Porównanie znormalizowane przez `profile_emit` (istniejący normalizator tej samej gramatyki pól) i posortowane — różnice w formatowaniu/kolejności pól już nie kolidują. Kontrola negatywna wobec `5f2201c5` (recenzowanej wersji z błędem): 3 z 4 nowych asercji padają z przewidzianych powodów. Przy okazji poprawiono odwołania SHA w `ACTIVE-WORK-PLAN.md`/`DELIVERIES.md` — rebase w międzyczasie zmienił hash commita, a dokumentacja nie została odświeżona (REV-088 F3). REV-20260809-086 (sekcja 48, +4): żywy dowód na metropolis pve1/pve2 pokazał, że pierwotnie planowana druga próba (ta sama nazwa klienta) odmawia na sprawdzeniu unikalności nazwy w `add-client`, PRZED `cmd_seed()` — więc wcale nie dowodziła nowego guarda z REV-085. Poprawiona kampania: druga, RÓŻNIE nazwana relacja, bez własnego `add-client`/parowania, dziedzicząca manifest peera pierwszej (jeden manifest na peera, nie na relację — sam ten fakt był nieoczekiwany), trafia realnie do `cmd_seed()` i zostaje odrzucona przez `assert_no_coverage_overlap()` z nazwaniem konfliktu; CONFIG, crontab i całe poddrzewo ZFS potwierdzone bit-w-bit bez zmian. Przy okazji znaleziony i naprawiony NIEZALEŻNY bug: `read_server_conf()` bezwarunkowo zeruje `CRON_CONFIG` PO wczytaniu rekordu klienta, więc na hoście bez `server.conf` (dokładnie ten przypadek) `remove-client` i re-aktywacja `activate-client` cicho gubiły odczytaną wartość — dla re-aktywacji oznaczałoby to zapis do ŚWIEŻO przeliczonej domyślnej ścieżki configu zamiast do faktycznie zainstalowanej. Naprawione (sekcja 48, kontrola negatywna: 4 nowe asercje padają na starym kodzie). REV-20260809-085 (sekcja 47, +4): `cmd_seed()` wykonywał PRAWDZIWY, nie-suchy odbiór `snapget.sh` bez żadnego sprawdzenia pokrycia — jedyny guard (`assert_no_coverage_overlap`) siedział wewnątrz `emit_client_sections()`, osiąganej dopiero przy `activate-client`, już PO realnym transferze. Przestrzeń nazw trybu backup to `peer_label(PEER_HOST)` (`LOAD_LABEL`), NIE nazwa klienta — więc dwie różnie nazwane relacje do tego samego peera dzielą tę samą przestrzeń `target/label`. Własna wcześniejsza teza implementera w dyskusji live-proof, że nakładanie w trybie backup jest „strukturalnie nieosiągalne", była błędna z dokładnie tego powodu. Naprawa: `cmd_seed()` liczy docelowe ścieżki kandydata zaraz po `load_client_and_connection()` (już po `resolve_mode_datasets`) i wywołuje TEN SAM `assert_no_coverage_overlap()` przed pętlą transferu — bez drugiej implementacji nakładania; guard w `emit_client_sections()` zostaje jako obrona w głębi. Pisanie testu ujawniło kolejny fakt: prawdziwy `MANAGED_PRUNE_SCOPE` klienta GFS to CAŁE poddrzewo `target/label` (rekurencyjnie) — więc dla jednego peera+targetu, gdy istnieje jedna relacja GFS, KAŻDY dataset pod tym samym peerem+targetem już jest objęty; przypadek „rozłączny" w teście musiał użyć INNEGO peera, nie innego datasetu. Kontrola negatywna wobec `f1c4b960`: stary kod wywołuje prawdziwy odbiornik (realny transfer by się wykonał), nowy odmawia z zerem wywołań. Wymagany dowód na żywo (odmowa PRZED jakimkolwiek nowym stanem po stronie odbioru) jeszcze niewykonany — patrz odpowiedź REV-085. REV-20260809-083/084 (sekcje 45/46, +18 nad 292): `coverage_conflicts()`/`assert_no_coverage_overlap()` odmawiają dodania relacji, gdy jej żądana ścieżka jest rodzicem, dzieckiem lub dokładnym trafieniem pokrycia innej AKTYWNEJ relacji — sprawdzane PRZED pierwszą mutacją working configu (sekcja 45, REV-083 F1). Naprawiona wersja: rekord, którego nie da się odczytać/sparsować (albo który parsuje się, ale nie nazywa `CLIENT_NAME`) odmawia, zamiast być cicho pominięty jako „brak konfliktu" — pierwotny `|| exit 0` był fail-open (sekcja 46, REV-084 F1). Sam ten fix ujawnił dwie kolejne wady PRZED pierwszym zielonym przebiegiem: (1) status wyjścia podpowłoki per-rekord, raz skonsumowany przez `|| { ...; return 2; }`, był statusem OSTATNIEGO `path_overlaps && printf` w pętli — dla każdego rekordu, którego OSTATNIA para ścieżek się nie nakłada, to 1 (fałsz), więc każdy zwykły rozłączny rekord raportował się jako „nieczytelny"; naprawa dodaje jawny `exit 0` na końcu podpowłoki, bo konflikty płyną przez wydrukowane linie, nie przez kod wyjścia; (2) `assert_no_coverage_overlap()` odrzucał diagnostykę `coverage_conflicts()` nazywającą zepsuty plik i zawsze umierał z tym samym ogólnym komunikatem — REV-084 wprost wymaga, żeby komunikat nazywał rekord, więc teraz go nazywa. Kontrola negatywna wobec `90bb026` (kopiowanego do korzenia repo, żeby `SCRIPT_DIR` rozwiązał biblioteki): stary kod zwraca rc=0 i brak wyjścia dla nieparsowalnego rekordu, poprawiony rc=2 z nazwaną ścieżką. Wymagany dowód na żywo z REV-083 (nadpisanie pokrycia na prawdziwym hoście, odczyt zwrotny CONFIG/crontaba) NIE wykonany w tej sesji — patrz `docs/internal/reviews/responses/REV-20260809-083.md`, sekcja „required bounded live-host proof". REV-20260804-042/043 (+8 netto): sekcja "clobber" (26) przepisana pod endpoint-normalized identity — jeden job endpoint-switch przechodzi, dwa joby tego samego klienta z jednym porzuconym pod nowym adresem nadal odmawia (kontrprzykład recenzenta), oba zachowane przechodzi, zmiana source datasetu obok endpointu NIE jest maskowana jako endpoint-only, inny klient nadal odmawia. Warstwa orkiestracji `zfs-backup.sh` (+45 tego wieczoru: wykonywalność bloku, listy przecinkowe, uprawnienia i quiesce wyprowadzane z zadań; sekcja 25 przepisana pod `cron_replace_all`, REV-034 F3). Sekcja 35 (+3, REV-036 F5 follow-up): `migrate-to-account` odmawia, gdy którykolwiek crontab jest zapauzowany (`deploy.sh --pause`) — sprawdzane na starcie preflight, przed jakąkolwiek pracą. REV-033 plasterek 6 (+16): sekcja 36 `resolve_mode_datasets` przez zaślepiony `ssh` (fetch scope+hash, weryfikacja T3, zdalny `zfs list -r`, no-op dla klienta z listą i dla klienta bez `--mode`), sekcja 37 walidacja `add-client --mode=`, plus rozszerzenie sekcji 4 (próg `keep=2` dla trzech prefiksów, idempotencja, nie zawęża silniejszego `keep`) i sekcji 5/5b (znacznik własności U11: zgodny znacznik, odmowa bez znacznika i bez wcześniejszego zapisu, zgodność wsteczna przez `MANAGED_DATASETS`, odmowa gdy znacznik nazywa innego klienta). REV-033 plasterek 7 (+2, F4): sekcja 38 — pin tekstu podpowiedzi po `seed` (już nie sugeruje `set-endpoint` jako obowiązkowego), plus `cmd_verify_endpoint` przez zaślepiony wyłącznie `$SNAPGET` (nie `ssh`) z fixture klient+manifest+przypięty klucz — potwierdza, że diagnostyka stderr nieudanego sprawdzenia (np. "CONNECTION-level failure") dociera do operatora zamiast być wyciszana. REV-033 plasterek 8 (+6, F3/U7/U8): sekcja 39 — `snapget_local_base`/`client_local_path` dla obu trybów, `emit_client_sections` (sync) generuje `[dataset:]`/`[prune:]` po gołej ścieżce źródła z `recursive = no` wszędzie, `is_previously_managed` czyta wielowartościowy `MANAGED_PRUNE_SCOPE` jako listę, `add-client --mode=sync` odmawia (U8, przez podstawiony `PVE_NODES_DIR`) / nie odmawia (brak dopasowania węzła) przy enrollmencie. Korekta U9 (+6 netto, po przepisaniu fixture'ów bramki na nowe CLI): `active_endpoint_host_port`/`endpoint_display` dla obu kształtów rekordu, no-op `set-endpoint` na już aktualnym adresie, zapis `ENDPOINT_KNOWN` przy realnym przełączeniu, wciągnięcie uśpionego slotu klienta legacy, awans `verify-endpoint` na znanego kandydata (i odwrotnie — adres, co przestał odpowiadać, sam staje się kandydatem), odmowa z wymienieniem wszystkich wypróbowanych adresów gdy żaden nie odpowiada. Plasterek 9 (+2, U10): `add-client --join-remotely` przekazuje flagę do `deploy.sh --pair` przez podstawiony `$DEPLOY` przechwytujący argv (ten sam wzorzec co `$SNAPGET` w sekcjach 38/39), obecną tylko gdy podana. Plasterek 10 (+3, korekty ról): sekcja 41 — source-grep piny na poprawioną treść trzech komunikatów (`seed`, `final-catchup`, `verify-endpoint`), gdzie "the source" mylnie nazywało peera zaraz obok już poprawnego "this collector". REV-20260804-039 F1: komunikat błędu `add-client` po nieudanym/przerwanym `--pair` mówi teraz wprost, że retry TEJ SAMEJ komendy jest bezpieczny (żywo dowiedzione, patrz nagłówek). Sekcja 23b (+7, REV-20260804-041): `remove-client` na OSTATNIM kliencie — wymuszona awaria podmiany pliku configu PO udanym usunięciu bloku crona (`mv` zaślepiony tylko dla tego jednego wywołania) potwierdza: kod wychodzi niezerowo, `deploy.sh --unpair` nigdy nie jest wywoływany (skrypt-znacznik jako dowód, nie dopasowanie tekstu), rekord klienta i stary config zostają nietknięte, komunikat nazywa dokładny stan mieszany, a retry (prawdziwy `mv`) kończy się czysto z `STATE=removed` |
| `quiescehelper` | **119/119** | granica uprzywilejowana helpera + transakcja grantu + **nadanie dla konta lokalnego (+14)** |
| `join` | **82/82** | walidacja paczki `--join`, granica zaufania; +12 dla `--commit-scope-check` (REV-033 slice 2), +10 dla `--draft-scope-check` (REV-033 plasterek 4), +13 dla `PEER_CONF_MODE`/`--mode` (REV-033 plasterek 5), +5 dla `PEER_CONF_REMOTE_JOIN`/`--join-remotely` (REV-033 plasterek 9, U10) — pole `yes`/nieznana wartość/brak (legacy), `--join-check` je wypisuje, flaga CLI się parsuje. Plasterek 3 (`b7e0478`, revoke-on-narrow) celowo BEZ testu ze stubem `zfs` — ten sam wybór co dla samej pętli grantu w plasterku 2: fałszywy `zfs` dowodziłby wierności własnemu stubowi, nie prawdziwego `zfs allow`/`unallow`/`holds`. `do_pair`'s own scp/ssh/`ssh -t` orchestration (plasterek 9) tym samym wyborem BEZ stubu — patrz addendum "Slice 9". Zweryfikowane na żywo na metropolis pve2, patrz addendum "Slice 3" w odpowiedzi REV-20260802-033 |
| `pause` | **74/74** | `deploy.sh --pause`/`--resume` na okno serwisowe (wymiana dysku, migracja VM). Domyślnie: zakomentowanie TYLKO ciała bloków tego pakietu (markery `lib-cron.sh`, jawny rejestr `PAUSE_KNOWN_BLOCKS`, obcy blok o tej samej gramatyce nietykany — REV-036 F4) w miejscu, wszystko inne w crontabie (roota i konta) chodzi dalej — jednym zapisem przez `cron_replace_all_impl`, nie po bloku (REV-036 F2). `--fullcron` przywraca dawne zachowanie: cały crontab zapisany i zastąpiony jednym placeholderem, stan zapisywany DURABLE przed zamianą crontaba (REV-036 F1) i porównywany bajt-po-bajcie przy resume (REV-036 F3). `--resume` sam rozpoznaje, w którym trybie dany user został zatrzymany; ręczna linia dopisana wewnątrz zapauzowanego bloku w oknie przeżywa resume, nie jest cicho gubiona. `lib-cron.sh` sam odmawia KAŻDEMU zwykłemu pisarzowi (nie tylko `deploy.sh`) nadpisania zapauzowanego kształtu (REV-036 F5) |
| `draftscope` | **26/26** | `deploy.sh --draft-scope` (REV-033 plasterek 4): generuje plik zakresu z prawdziwego inwentarza ZFS peera — domyślnie aktywne datasety jeden poziom pod każdą pulą, poza znanymi systemowymi (`ROOT`, `swap`) i samym korzeniem puli, plus pełny inwentarz jako komentarz. Przeciw stubowanemu `zpool`/`zfs` (ekstrakcja funkcji jak `test/pause`) — właściwy grant/`zfs allow` zostaje bez zmian nietestowany stubem (ta sama zasada co plasterek 2/3). Drugi draft dla tej samej etykiety odmawia zamiast nadpisać; host z samymi systemowymi datasetami odmawia zamiast zapisać pusty plik. +4 (ENROLMENT-AGREED T5): spis rodzin snapshotów jako komentarz obok inwentarza datasetów |
| `joinremote` | **8/8** (dokument podawał 7/7 — zmierzone 2026-08-06, suita jest deterministyczna, `needs = nothing`) | `deploy.sh`'s `remote_scope_stage` (REV-20260804-037 F1, znaleziony przez automatycznego recenzenta w trakcie kampanii live plasterka 10/zadania 26): substage draft/edit/check edytora `--join-remotely` uruchamiany przez `ssh -t`. Stary kod łączył draft i edytor gołym `;` — edytor otwierał się nawet po nieudanym drafcie (mógł stworzyć pusty/częściowy plik zakresu, który generator potem odmawia nadpisać) i `2>/dev/null` gubił jedyną diagnostykę tłumaczącą dlaczego. `$remote_ok` ustawiane od razu po `--join` nigdy nie było rewidowane — nieudany edytor tylko ostrzegał, a końcowe podsumowanie nadal nazywało zakres "zredagowanym". Naprawione: wydzielona funkcja `remote_scope_stage` (ekstrahowalna sed-range jak `do_draft_scope`) zwraca rozróżnialne kody (0=gotowe i zweryfikowane `--commit-scope-check`, 2=draft padł PRZED edytorem, 3=edytor padł, 4=zapis nie przeszedł walidacji po edycji), `do_pair`'s podsumowanie drukuje osobną instrukcję odzysku dla każdego stanu. Przeciw stubowanemu `ssh` (ta sama technika co stubowany `zpool`/`zfs` w `draftscope`): wymuszony brak drafta NIE wywołuje edytora i NIE tworzy pliku (dokładnie wada z F1), istniejący zakres pomija draft, awaria edytora/walidacji nigdy nie twierdzi "gotowe". `do_pair`/`do_join`'s prawdziwe działania (`useradd`, `zfs allow`, transfer po ssh) pozostają bez lokalnego testu z tego samego powodu co zawsze — patrz nagłówek `test/join/run.sh` |
| `pairgate` | **21/21** | `zfs-pair-gate.sh` — brama po stronie peera, stan `DISABLED` z ADR-0012 (pakiet hard-disable, krok 1 z `docs/project/HARD-DISABLE-CAMPAIGN-PLAN.md`). Testowalna bez ssh, bo sshd wnosi dokładnie dwa wejścia: argv (etykieta z `command=`) i `SSH_ORIGINAL_COMMAND`. KAŻDY przypadek data-plane każe bramie uruchomić komendę, której jedynym efektem jest utworzenie pliku, i sprawdza, że pliku NIE MA — „wypisała odmowę" nie jest dowodem, że nic się nie wykonało. Przypięte: odmowa PRZED parsowaniem (wejście nieparsowalne dostaje tę samą odmowę, nie błąd składni); tożsamość z klucza, nie z żądania (żądanie podszywające się pod inną relację niczego nie zmienia); cztery rozróżnialne kody wyjścia 91/92/93 (255 zostaje własnością ssh); nieznana relacja i zła etykieta fail-CLOSED; druga relacja działa dalej; verby kontrolne to dokładne literały, nigdy dopasowanie po prefiksie; `enable` przywraca data-plane, co dowodzone jest realnym efektem ubocznym, nie raportem samej bramy. Druga połowa — czy sshd naprawdę trasuje prawdziwy klucz przez bramę — to obowiązek ręczny `pairgate-live` |
| `pairgate` | **45/45** | brama peera `zfs-pair-gate.sh` + instalacja w `deploy.sh --join` (pakiet hard-disable). Sedno: każdy przypadek data-plane każe bramie uruchomić komendę tworzącą plik i sprawdza, że pliku NIE MA — „wypisała odmowę" nie jest dowodem. Przypięte: odmowa przed parsowaniem, tożsamość z klucza a nie z żądania, kody 91/92/93 rozróżnialne, fail-closed przy nieznanej relacji i złej etykiecie, verby kontrolne jako dokładne literały, logowanie do syslogu z zejściem do pliku wybieranym po WYNIKU a nie po obecności `logger` (REV-047 F1) i nigdy nie zanieczyszczające stderr wywołującego. Instalacja: migracja gołej linii klucza bez pozostawienia jej obok bramkowanej, cudze linie bajt w bajt, idempotencja, awaria commitu bez tknięcia pliku, i fail-closed na własności pliku — bo podmiana atomowa rootem odbiera kontu dostęp do własnego hosta (REV-049 F1) |
| `pairpause` | **18/18** | pauza logiczna relacji (REV-20260804-045): bramka `-L` w snapget.sh/snapsend.sh uruchamiana na PRAWDZIWYCH skryptach end-to-end (pozycja bramki jest testowaną własnością — pauza wychodzi z SKIPPED+`skipped_paused` PRZED zamkiem i sprawdzeniami zależności, co czyni ją dowodliwą bez roota/ZFS); etykieta niezapauzowana i brak etykiety płyną dalej (to drugie to UDOKUMENTOWANE ograniczenie, przypięte jako zachowanie); traversal odrzucony zanim jakakolwiek ścieżka jest dotknięta; `-L ''` = brak etykiety. Plus `check-snap-age -L`: pauza = OK z nazwanym powodem (nie cisza, nie strona), zepsuty próg pozostaje głośnym UNKNOWN także podczas pauzy. CLI zapisujące marker: `test/zfsbackup` sekcja 42; emisja `pair_label`: golden `pair-label` + negatyw `pair-label-charset` w suicie gencron |
| `runsuffix` | **6/6** | jeden sufiks nazwy snapshotu na PRZEBIEG, nie na dataset (Etap 2.1). Własność, od której zależy restore: zestawu snapshotów, którego nie da się zidentyfikować jako jednego przebiegu, nie da się odtworzyć jako jednego. `create_snapshot` wyekstrahowane z OBU silników, `date(1)` zaślepione tak, by zwracało INNĄ wartość przy każdym wywołaniu — dokładnie to, co robi prawdziwe poddrzewo przekraczające granicę sekundy. Przypina też KSZTAŁT nazwy, bo zależą od niego wzorce `delsnaps`, prefiksy monitora i każda zainstalowana linia crona. Licznik zaślepki żyje w PLIKU, nie w zmiennej: `$(date ...)` biegnie w podpowłoce, więc licznik na zmiennej zwracałby tę samą wartość i kontrola negatywna przeszłaby na STARYM kodzie, nie dowodząc niczego (pierwsza wersja tego testu robiła dokładnie to). Kontrola negatywna wobec `643238a`: **2 przypadki korelacji padają, 4 nietknięte przechodzą**. Korelacja end-to-end na prawdziwym ZFS-ie należy do `test/scenarios`; ta suita przypina samą decyzję o nazywaniu |

**Zintegrowana kampania po Etapie 2 — WYKONANA** (2026-08-08, metropolis pve1, kandydat `4b30447`). Pełny wynik: `docs/testing/POST-STAGE2-CAMPAIGN-RESULTS-2026-08-08.md`. **619 asercji, 0 porażek**, w tym `snapsend` 202/202, `remote` 145/145 jako konto delegowane (co domyka obowiązek ręczny `nonroot-account`), `delsnaps` 65/65, `scenarios` 36/36. Kampania znalazła jedną realną wadę — `test/pairpause` fałszywie padała na KAŻDYM hoście (asercja opierała się na kodzie wyjścia, który zależy od obecności ZFS-a); zdiagnozowane jako niezwiązane z Etapem 2 przez przebieg tej samej suity na `643238a` (identyczne 12/6) i naprawione. To był pierwszy raz, gdy ta suita w ogóle biegła na hoście.

**Dowód na żywo dla Etapu 2.1 (2026-08-08, metropolis pve1, `42fd7de`).** Kontrakt wymagał JEDNEGO scenariusza na prawdziwym ZFS-ie dowodzącego korelacji end to end — suita `scenarios` tego NIE pokrywa (sprawdzone: zero trafień na sufiks/korelację), więc dług był realny.

Drzewo robocze `hdd/rs-src` + trzy dzieci po 300 MB losowych danych, żeby przebieg trwał sekundy i naprawdę przekroczył granicę sekundy. Wywołanie długą pisownią, więc ten sam przebieg dowodzi też 2.3 na prawdziwym transferze:

```
./snapsend.sh --recursive=flat -m runcorr_ hdd/rs-src hdd/rs-dst     # 04:23:04 -> 04:23:30, rc=0
hdd/rs-src@runcorr_2026-08-08_04-23-04
hdd/rs-src/a@runcorr_2026-08-08_04-23-04
hdd/rs-src/b@runcorr_2026-08-08_04-23-04
hdd/rs-src/c@runcorr_2026-08-08_04-23-04
```

26 sekund przebiegu, **jeden sufiks na wszystkich czterech datasetach**.

Kontrola negatywna na TYM SAMYM drzewie, silnikiem z `643238a` (sprzed 2.1), przez `git worktree`:

```
./snapsend.sh -R -m oldcorr_ hdd/rs-src hdd/rs-dst2                  # 04:23:50 -> 04:24:18, rc=0
hdd/rs-src@oldcorr_2026-08-08_04-23-50
hdd/rs-src/a@oldcorr_2026-08-08_04-23-54
hdd/rs-src/b@oldcorr_2026-08-08_04-24-03
hdd/rs-src/c@oldcorr_2026-08-08_04-24-11
```

**Cztery różne sufiksy rozrzucone na 21 sekund** — dokładnie ta niekorelowalność, dla której powstał Etap 2.1, zaobserwowana, a nie wywnioskowana. Wszystkie datasety robocze zniszczone po teście, worktree usunięty.
| `reconcile` | **47/47** | `gen-cron.sh --reconcile` (uzgadnianie zakresu): co config kopiuje kontra co naprawdę istnieje. Odpowiada na awarię z tej floty, nie z wyobraźni — VM 104 na pve0 działała z ZEREM snapshotów, bo powstała po napisaniu configu, a nic tych dwóch faktów nie porównywało. `zfs`/`qm`/`pct` zaślepione, więc testowane jest PORÓWNANIE, nie zfs. Przypina, że „pokryty" znaczy **istnieje zadanie wysyłki** (dataset z samym prune jest przycinany, nie kopiowany); że audyt czyta ZADEKLAROWANE pole `recursive`, a nie zakłada, że rodzic pokrywa poddrzewo; że zadanie o nieistniejącym źródle jest zgłaszane; oraz że datasety systemowe Proxmoksa są WYPISANE I OZNACZONE, a nie po cichu wycięte — celowo odwrotny kierunek niż `deploy.sh --draft-scope`, bo tam wąski domyślny wybór jest bezpieczny, a tu przemilczenie JEST tą wadą. Przypisanie do gościa to ETYKIETA, nigdy decyzja. Zweryfikowane MUTACJĄ, nie tym, że stary kod nie zna flagi: zignorowanie pola `recursive` wywala 2 przypadki, ciche pomijanie datasetów systemowych — 1. Tryb jest READ-ONLY: nie zmienia configu, nie pisze crontaba, nie dotyka snapshotów. +11 (REV-20260808-071 F1/F2): drzewa ODEBRANE sa klasyfikowane osobno, a nie jako „nieobjete”. Audyt porownywal wylacznie z zadaniami WYSYLKI i nigdy nie pytal, co zadanie ZAPISUJE — wiec drzewo odebrane przez kolektor bylo zglaszane jako brak kopii, czyli zadanie, zeby kopia zapasowa miala kopie zapasowa; na pve2 to byla wiekszosc wyniku, a etykieta goscia czynila to jeszcze bardziej mylacym. Wyprowadzane z TOPOLOGII configu, nigdy z nazw: push z lokalnym dst -> `<dst>/<sciezka zrodla>`, push zdalny -> cel jest na peerze i NIE da sie go tu wyprowadzic (ograniczenie zgloszone, nie zgadywane), pull -> `<sekcja>/<nazwa zdalna>`. Poziomy posrednie tworzone przez odbior dopasowywane DOKLADNIE, nie poddrzewem — inaczej cokolwiek podlozone pod cel byloby po cichu rozgrzeszone. F2: kotwica systemowa obejmuje POTOMKOW (`rpool/ROOT/pve-1` to zwykly dataset rozruchowy Proxmoksa, byl zglaszany jako nieobjety), a granica, ktora dzialala, zostaje: `rpool/data/swap` nie jest POD kotwica, wiec pozostaje zwyklym znaleziskiem. Kontrole mutacyjne: odkotwiczenie dopasowania systemowego wywala granice z zagniezdzonym `swap`. +3 (REV-20260808-071, dyrektywa 3 i 4): pokrycie wyprowadzane z RZECZYWISCIE zbudowanych bytow wysylkowych i tylko z kierunku PUSH — sekcja bez rozwiazanego harmonogramu wysylki (sam prune) NIE jest pokryta, a cel PULL-a to miejsce, gdzie kopia LADUJE, wiec nie jest pokryciem zrodlowym. Poprawna sekcja pull ma sciezke konczaca sie literalna nazwa zdalnego datasetu (wymusza to `emit_send`), wiec korzeniem odbioru jest sama sekcja; poprzedni test uzywal configu, ktory normalne generowanie ODRZUCA, i przechodzil tylko dlatego, ze `--reconcile` konczy przed walidacja sufiksu. Kontrola wobec `8b578bd`: **4 nowe asercje padaja**, 25 istniejacych przechodzi. +3 (REV-20260808-072 F1): PARYTET ODMOWY — kontrakt pull-a (lokalna sciezka musi konczyc sie literalna nazwa zdalnego datasetu) zyl wylacznie w `emit_send`, do ktorego `--reconcile` nigdy nie dochodzi. Audyt mogl wiec wystawic czyste swiadectwo configowi, ktorego generator odmawia wykonac — sprawdzacz bardziej pobalzliwy niz rzecz sprawdzana jest gorszy niz brak sprawdzacza. Regula wydzielona do `pull_check` i wolana z `validate_transfer_semantics` PRZED galezia reconcile, wiec audyt i generator przyjmuja dokladnie te same wejscia. `pull_check` zwraca STATUS i ustawia globalne, nie echuje — gdyby echowala, `die` w podstawieniu polecen zabilby tylko podpowloke, czyli fail-OPEN juz raz w tym projekcie odnotowany. Kontrola wobec `96fbfbf`: padaja dokladnie 2 asercje parytetu, a „normalne generowanie odrzuca” przechodzi tam tez, bo zawsze dzialalo. +9 (decyzja wlasciciela 2026-08-08): KONTENERY STRUKTURALNE tlumione — rodzic, ktorego wszystkie dzieci sa pokryte i ktory nie trzyma wlasnych danych, to przypadek udokumentowany przez flage `-S` snapsenda. Dwie straze: JEDNO niepokryte dziecko i rodzic zostaje znaleziskiem; `usedbydataset` powyzej 1 MiB znaczy, ze ktos wlozyl pliki wprost do rodzica i te dane nie maja kopii. Tlumione = nieliczone i niealarmujace, NIGDY niewidoczne (wlasny naglowek, jak datasety systemowe). Plus poprawka FALSZYWEGO NEGATYWU: ekspansja rekursji honoruje teraz `-S` i `-X` — `zfs list -r` przypisywal pokrycie rodzicowi, ktorego silnik pomija, i dziecku, ktore odfiltrowuje. Utajone, nie czynne: zaden config w tej flocie tych flag nie uzywa. Kontrola wobec `5c5ee1e`: **5 asercji pada**, 36 przechodzi. +6 (REV-20260808-074 follow-up): KLASTROWANE pisownie `-S`/`-X`. Silnik uzywa `getopts`, wiec `-eS` to `-e` plus `-S`, a `-SX drop$` to `-S` plus `-X` biorace nastepny token. `--reconcile` mial WLASNY chodzik po tokenach, rozpoznajacy tylko `-S`, `-X` i `-Xwzor` jako cale tokeny, wiec te legalne pisownie byly zle czytane, a pominiety rodzic albo wykluczone dziecko wracalo jako POKRYTE — falszywa zielen. Ta sama wada, ktora REV-069 naprawila w pre-passie silnikow, napisana recznie drugi raz w innym pliku. Poprawka to JEDNA gramatyka: `flags_opt_pairs` robi przejscie rownowazne `getopts` i zwraca litere z argumentem, a `flags_opt_letters` jest widokiem tego samego przejscia. Kontrola wobec `5914498`: **3 asercje padaja**; pozostale 3 przechodza tam tez (stary parser poprawnie czytal `-X fooS`) i sa pokryciem regresyjnym, nie dowodem |
| `recursion` | **64/64** | dokładnie JEDNA deklaracja rekursji na wywołanie + długie opcje (Etapy 2.2 i 2.3). Na PRAWDZIWYCH silnikach: odmowa zapada przy parsowaniu argv, przed sprawdzeniem zależności, datasetu i SSH — dlatego bez roota i ZFS-a. Przypięte: `-r -R` odrzucane w OBU kolejnościach (było prawdą już wcześniej, kontrakt twierdził inaczej); powtórzenie TEGO SAMEGO trybu też odrzucane; litera rekursji jako ARGUMENT OPCJI (`-m -r`) to dana. **2.3:** `--recursive=atomic|flat|no` równoważne `-r`/`-R`/braku, `--recursive=ture` odrzucane z podaniem wartości, gołe `--recursive` odrzucane, nieznana długa opcja odrzucana; `--recursive=no -r` **odrzucane, nie zwijane do `-r`** (przypadek, który REV-060 A4 wyłapała w mojej pierwszej propozycji); mieszanie form krótkiej i długiej to dwie deklaracje; po `--` i po pierwszym pozycyjnym długie formy są danymi (obie reguły stopu `getopts`). `delsnaps`/`check-snap-age` dostają `--recursive` ≡ `-R` — testowane przez EKSTRAKCJĘ pętli argumentów, bo oba giną na braku `flock`/`zfs` ZANIM do niej dojdą, więc samo uruchomienie „przyjmuje" literówkę równie chętnie co poprawną pisownię. Kontrola negatywna wobec `bda5602`: **20 asercji pada**, 34 przechodzą. +10 (REV-20260808-069 F1): KLASTRY flag krótkich. `getopts` czyta `-em` jako `-e` i `-m`, a skoro `m:` bierze argument i nic po nim w tokenie nie zostaje, argumentem jest NASTĘPNY argv. Pierwszy pre-pass pochłaniał następny argv tylko dla tokenu długości 2, więc `-em --recursive=flat` czytał WIADOMOŚĆ jako deklarację. Sondą jest celowo NIEPOPRAWNY tryb (`ture`) — „brak błędu" niczego tu nie dowodzi, bo poprawny tryb milczy w obu interpretacjach, a druga deklaracja bywa połknięta jako argument opcji; obie moje pierwsze sondy były z tego powodu ślepe. Kontrola wobec `46b96b4`: **2 asercje padają** (`-em` w obu silnikach), reszta przechodzi — pozostałe przypadki klastrowe stary kod obsługiwał przypadkiem poprawnie |

**Dowód na żywo dla Etapu 2.3 (2026-08-08, `3d44488`).** Kontrakt wymagał JEDNEGO wywołania jako konto delegowane, dowodzącego, że **zainstalowana** kopia rozumie nową pisownię — wykonane na **wszystkich czterech hostach** (metropolis pve1/pve2, 11.x pve0/pve1), jako `zfsbackup`, na nieistniejącej puli, więc obie sondy kończą się na parsowaniu argumentów i niczego nie dotykają:

- sonda A `--recursive=ture` → `Error: --recursive= takes atomic, flat or no (got 'ture')`, rc=1 na każdym hoście — dowodzi, że wdrożona kopia PARSUJE długą opcję;
- sonda B `-em --recursive=ture` → **zero** walidacji wartości na każdym hoście — dowodzi, że poprawka REV-20260808-069 (klastry) jest wdrożona, a nie tylko zacommitowana;
- `--recursive=no -r` odrzucone jako dwie deklaracje, `snapget.sh` zachowuje się identycznie.

Sonda z NIEPOPRAWNYM trybem jest tu jedyną obserwacją rozróżniającą: poprawny tryb milczy niezależnie od tego, czy token jest daną, czy opcją. `git log` jako root na hostach 11.x odmawia przez `safe.directory` (repo należy do `zfsbackup`) — to kontrola własności po stronie roota, nie problem wdrożenia; commit odczytany jako konto delegowane.
| `alertmail` | **18/18** | audyt dostarczalności alertów `deploy.sh` (REV-20260806-046): kwartet `mta_present`/`mta_name`/`mail_queue_depth`/`alert_delivery_verdict` + aktywna sonda `alert_delivery_probe` na podstawionych `mail`/`postqueue`/`sleep`, z wyjętym z deploy.sh oryginalnym `warn()`. Klasa findingu: FAŁSZYWE ZDROWIE — werdykt nieoparty na zmierzonych dowodach. Przypięte: brak `mail(1)`/MTA i niepusta kolejka pozostają twardymi awariami zasilającymi `PROBLEMS`; kolejka nieczytelna (MTA bez obsługiwanego narzędzia, `postqueue` sam padł, wyjście nienumeryczne) jest UNVERIFIED i niezielona zamiast dawnego `log()`+`return 0`; pusta kolejka bez sondy mówi „prerequisites OK, delivery UNVERIFIED", nigdy „can send" (grep w obie strony — brak pozytywu, obecność UNVERIFIED); sonda sprawdza status `mail(1)` i po opróżnieniu kolejki twierdzi wyłącznie „LEFT THIS MTA, recipient delivery NOT independently verified". Każdy przypadek sprawdza jednocześnie kod powrotu, licznik `PROBLEMS` i brzmienie. Przypadki regresyjne F1/F2 padają na zrecenzowanej bazie `a567328` (`DEPLOY_SRC=`). Prawdziwy postfix i faktyczne dostarczenie: dowód żywy w odpowiedzi REV-046 + obowiązek ręczny `deploy-check-only` |
| `joinmanifest` | **10/10** | `deploy.sh`'s `verify_join_manifest` (REV-20260804-038, znaleziony przez automatycznego recenzenta na podstawie tego samego incydentu live co plasterek — brakujący `PEER_CONF_MODE` zostawił PUSTY manifest na dysku, a `do_join()` mimo to wypisał "Join zakonczony"). Stary kod pisał manifest bezpośrednio (`cat > "$mpath"; chmod`), bez sprawdzenia i bez atomowości, PO mutacjach konta/klucza. Naprawione: render do pliku tymczasowego w tym samym katalogu, weryfikacja odczytu wszystkich pól PRZED zaufaniem, atomowy `mv`, ponowna weryfikacja PO rename — każda awaria zwraca niezerowo z jawną diagnostyką "PARTIAL ENROLMENT" (konto/klucz mogą już istnieć, bezpiecznie powtórzyć `--join` tym samym pakietem, nigdy nie kasować konta/klucza ręcznie). Przeciw prawdziwym plikom (bez ssh/zfs/useradd): poprawny manifest weryfikuje się dokładnie; kształt incydentu live (plik pusty) jest odrzucany; pojedyncze złe pole (fingerprint, konto) jest odrzucane, co dowodzi porównania KAŻDEGO pola; brakujący plik odrzucony; manifest legacy bez `PEER_JOIN_REMOTE` weryfikuje się poprawnie, gdy nie był oczekiwany. +3 (REV-20260804-040): pole `PEER_JOIN_ACCOUNT_UID` — manifest z zapisanym UID weryfikuje się dokładnie przy zgodności, odmawia przy niezgodności, manifest legacy bez tego pola nadal weryfikuje się gdy UID nie był oczekiwany. Sama sekwencja render/write/chmod/rename w `do_join()` nadal wymaga roota (podobnie jak mutacje konta/klucza przed nią) — ten sam stały brak co zawsze |

Wymagają roota, ZFS albo drugiego hosta. **Uruchomione 2026-08-04 na metropolis
pve1 przy `4ebfa11`** (i wcześniej przy `d8bb52a`, `244ec0d`, `55d33a2`) — pierwszy
przebieg od czasu, gdy REV-20260802-033 plasterek 8 dotknął `snapget.sh`
(root+zfs nie było dostępne w sesji implementującej ten plasterek). Znalazł
na żywo dwa realne błędy istniejące od plasterka 8, oba naprawione w tej
samej kampanii co REV-20260804-037/038 (patrz tam pełny rejestr Gate A-J):
`recv_force_flag` odmawiał KAŻDEGO pierwszego seeda (cel zawsze jest
wstępnie tworzony pusty, co czyniło `target_exists()` prawdziwym zawsze),
i `written@` porównywało sformatowaną wartość (`"0B"`) z gołą cyfrą
(`"0"`), więc odmawiało też przy zerowej rozbieżności — w tym w przypadku
dopasowania po GUID, gdzie migawka na celu ma inną nazwę niż na źródle
(`written@<nazwa-źródła>` na celu zwracał `"-"`, nie liczbę):

| Pakiet | Wynik | Czego wymaga | Zakres |
|---|---|---|---|
| `snapsend` | **202/202** | root, zfs, mbuffer | silnik push/pull, semantyka flag |
| `scenarios` | **34/34** | root, zfs, mbuffer | wygenerowane linie crona uruchamiane dosłownie |
| `remote` | **145/145** | drugi host, ssh, zfs | kampania dwuhostowa, **oba klastry, root i konto**: metropolis pve1 → pve2; 192.168.11.x pve0 → pve1 (root `--peer-parent rpool`, konto `rpool/data` po obu stronach) |
| `delsnaps` | — | root, zfs | retencja, prefiksy, GFS — poza grafem dla tej zmiany |

Siedem pozycji `SKIP` w `selfupdate` to przypadki wymagające `chattr +i`, którego
to środowisko nie obsługuje.

Wszystkie pakiety wymienione w `test/deps.conf` muszą występować w tej tabeli;
pilnuje tego `test/impact/run.sh`.

Zweryfikowane na żywo 2026-07-31: `sqlfreeze` na produkcyjnym vsql2 (VM 100),
reguła kropki w `sudoers.d` (visudo 1.9.5p2, z kontrolą negatywną), akceptacja
generowanej reguły sudoers przez prawdziwy `visudo`, `deploy.sh --check-only` na
czterech hostach w obu formach hosta.

## 6. Otwarte — i u kogo leży

### Zamknięte przez recenzenta

- **REV-20260731-013 — odzyskiwanie po crashu: ZAMKNIĘTE** (REV-014). Sweep
  parkuje zaparkowaną regułę zamiast ją uzbrajać; recenzent uznał zachowanie za
  poprawnie fail-closed i przyjął, że testy mierzą efektywną granicę, a nie
  obecność plików.
- **Poprawka `sqlfreeze` (warunkowa notka): PRZYJĘTA** tą samą recenzją.
- **REV-20260731-012 — kolejność commitu: przyjęta** w REV-013.
- **Transakcja grantu wraz z odzyskiwaniem po crashu** jest przez recenzenta
  uznana za akceptowalną infrastrukturę dla **opcjonalnego** remote quiesce.

### Otwarte u implementera

- **REV-057 — zaimplementowane, czeka na werdykt.** Migracja wykonana i
  zweryfikowana; odpowiedź: `docs/internal/reviews/responses/REV-20260807-057.md`.
  REV-054, REV-055, REV-056 i REV-058 są **zamknięte przez recenzenta**.
- **Znane luki, nazwane w odpowiedziach i nadal otwarte:** (1) `cron2conf.sh`
  **nie parsuje w ogóle linii `snapget.sh`**, więc połowa round-tripu dla pull
  jest nietestowalna — usterka sprzed tych zmian, znaleziona przy budowie
  fixture'a (wątek #21d); (2) `--draft-config` nie ma testu behawioralnego, bo
  wymaga prawdziwego parowania — D1/D2 w `draftscope` to **statyczny odczyt
  `deploy.sh`**, nie uruchomienie CLI; (3) silniki transferu **nie odrzucają
  `-r -R` naraz** — wygrywa ostatnia flaga, choć generator odmawia tego w
  configu (wątek #31); (4) pod `flat` bez `-q` nazwa snapshotu jest liczona
  osobno dla każdego datasetu, więc przebieg nie jest korelowalny — jednolinijkowa
  zmiana należąca do prac przed zamrożeniem silnika (wątek #30).

### Otwarte u właściciela — decyzje, nie kod

- ~~Migracja 192.168.11.11~~ — **WYKONANA 2026-08-07 14:42** przez
  `gen-cron.sh --migrate-recursion` (REV-057). Crontab md5 **bez zmian**,
  właściciel i prawa zachowane, kopia rollback zostawiona, render identyczny z
  zainstalowanym blokiem. **Żaden config we flocie nie niesie już starego
  zapisu rekurencji** — pakiet rekurencji jest operacyjnie kompletny.
- ~~pve0: goście bez żadnej kopii~~ — **ZAŁATWIONE 2026-08-07 (Etap 0).** VM 104
  `debian` (działająca), VM 103, VM 107 (trzy datasety) i CT 105 są objęte kopią,
  granty nadane, monitor `rc=0`. Zostaje decyzja **strukturalna, nie awaryjna**:
  granty na pve0 są per dataset, więc nowy gość znów wymaga ręcznego kroku.
  Nadanie grantu na rodzicu objęłoby przyszłych automatycznie, ale poszerza
  powierzchnię uprzywilejowaną (wątek #36). Prawdziwą naprawą klasy jest
  uzgadnianie zakresu — Etap 4 planu.
- **REV-021 — zaimplementowane w `1edca10`, czeka na werdykt.** Instalacja nie
  może skasować zadań, które cel już wykonuje (`assert_target_block_not_clobbered`),
  a linie „porzucone" przez render konta trafiają do bloku ogólnohostowego
  **tylko** jeśli są rozpoznane jako ogólnohostowe — reszta zatrzymuje migrację
  z podaniem linii. Odpowiedź: `docs/internal/reviews/responses/REV-20260801-021.md`.
- **REV-018/-019/-020 — zaimplementowane w `1d5a8c4`, czekają na werdykt.**
  Bramka duplikacji porównuje teraz **tożsamość zadań**, nie ścieżkę configu
  (`job_identity()` zdejmuje katalog skryptu i log, zostawia harmonogram,
  datasety, wzorzec, retencję, quiesce i progi). Doszedł czasownik
  `zfs-backup.sh migrate-to-account <konto> [--preflight] [--yes]` z pięcioma
  fazami REV-020 F3, a linie ogólnohostowe (digest) dostały własny blok
  `# BEGIN zfs-backup-host` w crontabie roota zamiast być luźną linią, której
  nikt nie jest właścicielem. Odpowiedzi: `docs/internal/reviews/responses/REV-20260801-018.md`,
  `-019.md`, `-020.md`.
- **Świadomie NIEzrobione z REV-020 F1, i recenzent to potwierdził:** faza
  `prepare` przenosi config, ale **nie nadaje** `zfs allow` ani grantu quiesce —
  wypisuje dokładną komendę `deploy.sh` i odmawia. REV-022 („Accepted progress",
  pkt 3) nazywa tę granicę właściwą: uprzywilejowany grant zostaje w `deploy.sh`,
  nie wchodzi do `migrate-to-account`. Brakowało natomiast samego polecenia dla
  konta lokalnego — patrz punkt niżej.
- **Brakująca droga nadania: DODANA** (`3831509`, doprecyzowana przez REV-022 w
  `32d6ed1`). `--allow-quiesce` działało wyłącznie z `--join`, czyli tylko dla
  peera; własne konto delegowane hosta nie miało żadnego polecenia, które
  nadałoby mu quiesce. Teraz jest to Faza 8h zwykłego przebiegu `deploy.sh`,
  z whitelistą wyprowadzoną z tej samej listy `--datasets`, co grant `zfs allow`
  — jedna zmienna, więc „może zamrozić" nie może przerosnąć „może replikować".
- **Faza 1 (`--preflight`) PRZETESTOWANA NA ŻYWO** na metropolis pve1
  (2026-08-01, `4662b8a`), tylko odczyt, oba crontaby bajt w bajt bez zmian po
  przebiegu. Wynik zgodny co do joty z ręczną analizą: config do przeniesienia,
  brak delegacji ZFS na dokładnie czterech datasetach pod `hdd/vm-disks`, brak
  grantu quiesce przy bloku używającym `-q`, i **1 linia ogólnohostowa** (digest)
  wyliczona, nie wpisana na sztywno. Pierwszy przebieg na żywo od razu znalazł
  własny błąd: faza 1 renderowała jako konto, zanim faza 2 przeniosła config,
  więc na jedynym kształcie hosta, dla którego to pisałem, kończyła się FATAL-em.
  Naprawione w `4662b8a`, trzy testy padają na bazie.
- **Fazy 2–5 PRZETESTOWANE NA ŻYWO** w oknie serwisowym za zgodą właściciela,
  metropolis pve1, 2026-08-01 17:07–17:09. Syntetyczny blok na datasecie
  testowym, nie produkcyjne zadania. Przeszło: config **przeniesiony** do
  `/etc/zfs-snapshot-all/`, blok kolektora zdjęty z roota, digest zachowany we
  własnym bloku `# BEGIN zfs-backup-host`, blok konta zainstalowany ze ścieżkami
  konta i finalną ścieżką configu w `# Source:`, wszystkie cztery linie konta
  wykonane jako konto. Potem przebieg z wstrzykniętą awarią (crontab konta
  ustawiony `chattr +i`): crontab roota odtworzony **bajt w bajt**, config
  cofnięty. Po teardownie oba crontaby identyczne ze zrzutem sprzed testu,
  dataset testowy usunięty, zero resztek.
- **Znalezione przez ten przebieg i naprawione:** rollback twierdził „both
  crontabs restored" linijkę po ostrzeżeniu, że crontaba konta nie odtworzył
  (`d506361`) — nigdy nie był zapisany, więc nie było czego odtwarzać.
- **Migracja produkcyjnego bloku metropolis pve1: WYKONANA 2026-08-01 18:10:47–18:10:49**,
  na polecenie właściciela, po nadaniu obu brakujących zdolności. Nie na
  syntetyku — na 15 żywych liniach zadań. Wynik: root 15 → 3 linie
  (`check-pool-capacity`, `--self-update`, digest w bloku `zfs-backup-host`),
  konto 1 → 13 (`git pull` + 12 zadań), config przeniesiony do `/etc/`.
  Wszystkie 12 linii konta uruchomione ręcznie **jako konto**: sendy i prune'y
  rc=0, monitory rc=0 na własnych progach, kolejka alertów pusta. Kopie obu
  crontabów i configu zdjęte przed operacją (host + scratchpad).
- **Co ten przebieg znalazł, a czego nie znalazł żaden test ani okno serwisowe:**
  lokalny quiesce jako konto delegowane zgłaszał trzy DZIAŁAJĄCE guesty jako
  „not running", robił snapshoty bez zamrożenia i kończył się zerem. Naprawione
  w `55d33a2`, po naprawie ten sam job faktycznie mrozi VM 106 i odmraża ją.
  Zobacz też okno zamrożenia w sekcji 3 — to drugi, jeszcze nienaprawiony wniosek
  z tego samego przebiegu.
- **Nieprzetestowane na żywo:** konto, które JUŻ ma rozłączny blok zarządzany
  (temat REV-021) — pokryte tylko testami na stubach.
- ~~Test `remove-client` celujący w crontab skonfigurowanego konta~~ — **zrobione**
  (sekcja 23 pakietu `zfsbackup`). Oba warunki z dodatkowej uwagi REV-019 padają
  na `9af0003`, czyli dokładnie tym commicie, w którym poprawka wylądowała w
  niewłaściwej funkcji, i przechodzą dziś.

### Czeka na werdykt recenzenta

- **REV-20260804-042** — drugi krąg werdyktu A-J: żaden nowy defekt kodu w
  REV-041, REV-039 F1 i REV-040 zamknięte przez recenzenta. Bramki G i I
  nadal **NOT RUN** na żywo — recenzent wprost zabronił zmiany kodu, żeby
  je „zaliczyć". Odpowiedź `docs/internal/reviews/responses/REV-20260804-042.md`:
  NEEDS-DISCUSSION dla obu, bo to pytanie o infrastrukturę (druga trasa
  sieciowa / nieklastrowana para hostów), nie o implementację — patrz
  „Czeka na decyzję właściciela" niżej.
- **REV-20260801-021** (`1edca10`, `99ba1f5`) — instalacja nie może skasować
  zadań, które cel już wykonuje; tylko rozpoznane linie ogólnohostowe zostają
  w crontabie roota. Odpowiedź w `docs/internal/reviews/responses/REV-20260801-021.md`.
- **REV-20260801-022 F1** (`32d6ed1`) — `--allow-quiesce` musi nazwać konto,
  które dostaje grant, i odmówić zamiast kończyć się zerem. Odmowa przeniesiona
  na czas argumentów, czyli mocniej niż wymagała recenzja. Odpowiedź w
  `docs/internal/reviews/responses/REV-20260801-022.md`. **Nota produktowa recenzji
  (jeden przepływ zamiast trzech poleceń) przyjęta i NIEZROBIONA** — patrz
  „Czeka na decyzję właściciela".
- **`55d33a2` — nie z recenzji, ale wymaga tego samego spojrzenia.** Lokalny
  quiesce czytał „nie mogłem zapytać" jako „guest nie działa" i robił snapshoty
  bez zamrożenia, kończąc zerem. Naprawione przez nauczenie lokalnej ścieżki
  trasy przez helper (którą ścieżka zdalna miała od 2026-07-31) i przez
  odmowę zamiast degradacji.
- **REV-20260801-023** (`244ec0d`) — recenzent zauważył, że naprawiłem sondę i
  stanąłem: zostało **pięć** gałęzi, które nadal degradowały (guest już
  zamrożony, nieczytelny `fsfreeze-status`, freeze który nie wszedł, nieudany
  flush kontenera, tryb niepasujący do rodzaju guesta). Wszystkie odmawiają
  kodem 3 przed snapshotem. Nieudany thaw też kończy przebieg niezerowo i
  **zatrzymuje** guesta na liście odzysku zamiast go zapomnieć. Odpowiedź w
  `docs/internal/reviews/responses/REV-20260801-023.md`. Piąta gałąź (tryb niepasujący)
  wykracza poza literę recenzji — zaznaczone tam wprost do ewentualnego
  odrzucenia.
- **REV-20260801-026** (`5ff1b0b`) — uprawnienia ZFS wyprowadzane z wyrenderowanych
  zadań, nie z typu sekcji; komunikat naprawczy z dokładną listą datasetów.
  Odpowiedź w `docs/internal/reviews/responses/REV-20260801-026.md`.
- **REV-20260801-027** — to samo o jeden poziom wyżej: quiesce sprawdzany
  **per zadanie** przez prawdziwego helpera, jako konto, zamiast jednego
  hostowego „czy konto dosięga helpera". Zweryfikowane na żywo na wszystkich
  czterech hostach. Odpowiedź w `docs/internal/reviews/responses/REV-20260801-027.md`.
- **REV-20260801-024** (`be1cfe7` + `d8bb52a`) — okno zamrożenia jako termin, nie
  kolejność. Wszystkie pięć wymaganych zachowań, zmierzone na żywo: 18 s → 1 s.
  Odpowiedź w `docs/internal/reviews/responses/REV-20260801-024.md`. Do zważenia przez
  recenzenta: budżet 5 s oznacza, że host z kilkoma wolno mrożącymi się gośćmi
  Windows w **jednym** zadaniu legalnie go przekroczy i to zadanie padnie —
  kierunek fail-closed, ale zmiana zachowania dla konfiguracji, której nikt
  jeszcze nie próbował.
- **REV-20260801-025** (`7564f8e` + `c7ce8da`) — granica quiesce'u ma objąć
  **każdą pulę** i **ścieżkę zdalną**. Odpowiedź w
  `docs/internal/reviews/responses/REV-20260801-025.md`, **napisana z opóźnieniem i tak
  właśnie opisana**: F1 zostało bez pliku odpowiedzi, więc recenzent nie miał
  jak odróżnić „niesione" od „nieprzeczytane" i zapytał drugi raz jako REV-029.
- **REV-20260802-028** (`90a06c8`) — `--add-quiesce`: grant wyłącznie
  dokładający, idempotentny, fail-closed przy nieczytelnej whiteliście;
  `--allow-quiesce` nadal nadpisuje, bo dla **zapisu** to jest poprawne.
  Odpowiedź w `docs/internal/reviews/responses/REV-20260802-028.md`.
- **REV-20260802-029** (`c7ce8da`) — powtórka REV-025 F1: granica sprawdzana
  przed **każdą** pulą, na obu ścieżkach. Odpowiedź w
  `docs/internal/reviews/responses/REV-20260802-029.md`.
- **REV-20260802-030** (`9fbf1df`) — niekompletny zestaw quiesce jest
  **usuwany**, nie tłumaczony: rejestr tego, co przebieg utworzył, trzy wyjścia
  (komplet / nic nie zatwierdzono / **ROLLBACK INCOMPLETE**, kod 7, z nazwą
  każdego ocalałego snapshotu). Odpowiedź w
  `docs/internal/reviews/responses/REV-20260802-030.md`.
- **REV-20260802-031** (`3d4c13f`) — sam raport wycofania nie może zawieść
  fail-open. Drugi plik tymczasowy **usunięty**, nie obsłużony; nieudany zapis
  rejestru kończy się kodem 7 z nazwą snapshotu. Odpowiedź w
  `docs/internal/reviews/responses/REV-20260802-031.md`.
- **REV-20260802-032** (`700d045`, `52ec5e6`) — nieudany zapis rejestru musiał
  rozliczyć **cały** zestaw, nie tylko nazwę, która akurat nie weszła. Rozwiązane
  **inaczej niż sugerowała recenzja**: nie drugim rejestrem na to, czego pierwszy
  nie pomieścił, tylko usunięciem pliku — rejestr jest tablicą, jak od zawsze na
  ścieżce lokalnej, więc klasa błędu znika zamiast być obsługiwana. Powód
  odstępstwa jest zmierzony i opisany w odpowiedzi: każda przenośna próba
  zepsucia pliku *między pulami* kasowała też **zapis wcześniejszej puli**.
  Odpowiedź w `docs/internal/reviews/responses/REV-20260802-032.md`. **Do zważenia przez
  recenzenta:** pięć nowych asercji, które padają na `HEAD~`, to asercje
  strukturalne — część behawioralna przypina kontrakt, ale nie rozróżnia wersji,
  bo stary defekt wymagał trybu awarii, którego już nie ma. Reprodukcja defektu
  jest w odpowiedzi zamiast w suicie.

- **Ujednolicenie pisarza crontaba — W TOKU, decyzja właściciela 2026-08-02.**
  Do dziś crontaby pisało **sześć miejsc** w trzech programach, z czego dwie
  linie (`check-pool-capacity.sh`, `update-control.sh --self-update`) leżały
  **poza jakimkolwiek blokiem**, nieodróżnialne od tego, co wpisał człowiek.
  Sześć asercji w `zfs-backup.sh` to kontrole kompensujące dokładnie ten stan.
  Uzgodniony model: **jeden pisarz, kilku zlecających** — `deploy.sh` posiada
  blok `zfs-backup-host`, warstwa zadań blok `zfs-backup-managed`, a prymityw
  przyjmuje nazwę bloku jako argument, więc „nie mogę tknąć cudzych linii"
  przestaje być regułą do zapamiętania i staje się własnością jedynego wejścia.
  **Plasterek 1 (`0a14a66`): `lib-cron.sh` + `test/cron`, żaden pisarz jeszcze
  nie przełączony. Plasterek 2: `zfs-backup.sh` przełączony** — jeden czytelnik
  (`cron_read`), jeden pisarz z odczytem zwrotnym (`cron_write`, czyli
  przywracanie crontaba przestaje móc kłamać) i jeden renderer bloku
  (`cron_block_render` zamiast lokalnego `awk`). Zachowanie bez zmian poza
  dodaną weryfikacją; `zfsbackup` 207/207, `cron` 49/49.
  **Plasterek 3: `gen-cron.sh --install` przełączony** — zostaje w nim tylko
  jego własna polityka (flock oraz odmowa instalacji obok luźnych linii
  `snapsend`/`delsnaps`/`check-snap-age`, gdy bloku jeszcze nie ma). Sprawdzone
  na żywo na metropolis pve1: render **starego i nowego kodu na produkcyjnym
  configu jest identyczny** przy tym samym `REPO_DIR`, `scenarios` 34/34 na
  hoście, `gencron` 56/56, `cron2conf` 10/10, `zfsbackup` 207/207.
  Zmiana zachowania warta odnotowania: dopasowanie markera było **dosłownym
  porównaniem** z `MARKER_BEGIN`, więc blok z innym ogonem nie zostałby
  rozpoznany i dopisałby się **drugi**; biblioteka dopasowuje po nazwie, więc
  taki blok jest adoptowany.
  **Plasterek 4 ZROBIONY I WDROŻONY na wszystkich czterech hostach
  2026-08-02 ~21:00.** `deploy.sh` przeszedł na prymityw, a dwie luźne linie
  (`check-pool-capacity.sh`, `update-control.sh --self-update`) oraz linia
  auto-pull konta zostały **przeniesione do bloku `zfs-backup-host`**, z
  zachowaniem treści i harmonogramów. Po wdrożeniu na każdym z czterech hostów:
  **zero luźnych linii zadań** poza blokami, liczba zadań bez zmian
  (root 3→3 wszędzie; konta 16→16, 12→12, 28→28, 8→8), crontaby zarchiwizowane
  przed operacją.

  Dwie rzeczy warte zapamiętania z tego plasterka. **Adopcja nie przepisuje
  treści** — kto przestawił capacity na 06:00, zachowuje 06:00; zmienia się
  wyłącznie miejsce, bo `deploy.sh` obiecuje „already present, leaving it
  alone". Wyjątkiem jest linia aktualizatora, która jest **normalizowana**, bo
  sensem jest sprowadzenie trzech historycznych pisowni do jednej. Oraz:
  warunek „już aktualna, zostaw" patrzył wyłącznie na **treść**, więc na każdym
  istniejącym hoście linia aktualizatora byłaby uznana za gotową i nigdy nie
  trafiłaby do bloku — złapane dopiero podglądem na żywym crontabie, nie w
  testach.

  **Model docelowy osiągnięty:** jeden pisarz (`lib-cron.sh`), dwóch
  zlecających (`deploy.sh` → `zfs-backup-host`, warstwa zadań →
  `zfs-backup-managed`), zero linii poza blokami.
  Robione **przed** enrollmentem, żeby nowe ścieżki instalacji crona nie
  powstawały w starym modelu.
- **REV-20260802-034** — recenzja **refaktoru crontabowego**, cztery findingi
  P1, **wszystkie przyjęte, żadnego sporu**. Dwa są skutkiem moich wczorajszych
  decyzji. **F1** (`cecfeaf`): `set_host_block` przepisywał **współdzielony**
  blok z własnego, częściowego spisu — po tym, jak `deploy.sh` dołożył tam
  updater i capacity, kolejna migracja skasowałaby oba, cicho, meldując
  zdrową migrację. Recenzent trafnie nazwał też mój test: zostawiał capacity
  **luzem** poza blokiem, więc podmiana całości wyglądała nieszkodliwie.
  **F4** (`cecfeaf`): walidacja markerów była lokalna dla nazwy, więc cudzy blok
  zagnieżdżony w docelowym przechodził i ginął w całości.
  **F2 ZROBIONE**: zamek per-użytkownik na każdym mutującym wejściu
  (`cron_lock_acquire`/`_release`, wariant `_multi` sortowany po nazwie —
  deadlock niemożliwy konstrukcyjnie), `test/cron` sekcje P–S (+14), przeplot
  **wymuszony barierą**, nie ścigany czasem. Przy okazji własny błąd tej samej
  klasy co się tu ściga: `local user="$1" fd="${CRON_LOCK_FD[$user]:-}"` — bash
  rozwija obie wartości w jednej komendzie `local` przed przypisaniem, więc
  `$user` w drugim polu odwoływał się do niczego pod `set -u`, a diagnoza szła
  w `/dev/null` linijkę niżej — suita padała bez żadnego komunikatu. Naprawione
  rozbiciem na dwie instrukcje.
  **F3 ZROBIONE** (`4f1c174`+`41afa2f`): `cron_replace_all`/`_impl` —
  zamek + walidacja markerów (F4) + `cron_write` z odczytem zwrotnym — i
  wszystkie trzy bezpośrednie wywołania `crontab` w `migrate-to-account`
  (forward, rollback-root, rollback-konto) przełączone na niego. Poprawiony
  własny błąd projektowy z odpowiedzi F2: transakcja migracji NIE trzyma
  obu zamków naraz — `gencron_as_target` odpala `gen-cron.sh` jako **osobny
  proces**, który sam bierze zamek konta; trzymanie go w rodzicu
  zakleszczyłoby się o własne dziecko. Zamiast tego: sekwencja osobno
  zamykanych operacji, porządkowana istniejącym `did_root`/`did_acct`.
  Po drodze złapany drugi błąd tej samej rodziny co F2: `exec {fd}>path
  2>/dev/null` i `eval "exec $fd>&-" 2>/dev/null` w `cron_lock_acquire`/
  `_release` — goły `exec` bez komendy stosuje WSZYSTKIE swoje przekierowania
  trwale do bieżącej powłoki, więc `2>/dev/null` nie gasił błędu tej jednej
  próby, tylko trwale kasował stderr całego procesu od tej linii w dół.
  Efekt: `test/zfsbackup/run.sh` sekcja 25 traciła cały tekst rollbacku
  (`warn`/`die`, oba na stderr) z przechwyconego `$(...2>&1)`, mimo że logika
  rollbacku liczyła się poprawnie (potwierdzone osobnym kanałem debug) —
  potwierdzone też na żywym Linuksie (`BASH_XTRACEFD` odizolowany od
  zepsutego fd 2 odzyskał cały ślad). Naprawione: `: >"$path" 2>/dev/null`
  (prawdziwa komenda, przekierowanie faktycznie zakresowe) jako sprawdzenie
  zapisywalności przed trwałym `exec`, zamknięcia bez `2>/dev/null` w ogóle.
  Testy: `test/cron` **120/120** (+9 T), `test/zfsbackup` **211/211**
  (sekcja 25 zielona), plus cały graf wpływu — także `sudo
  test/scenarios/run.sh` **34/34** na metropolis pve1 (root, prawdziwy
  `flock`). **ZAMKNIĘTE i zmergowane do `main` (`db2f7fe`)**, gałąź `cron-f3`
  skasowana lokalnie i na origin. Wszystkie cztery findingi (F1, F2, F3, F4)
  ACCEPTED/IMPLEMENTED. Jedyna otwarta luka: żaden żywy host nie ma dziś
  oczekującej migracji, więc `cron_replace_all` nie był jeszcze wywołany na
  prawdziwym produkcyjnym bloku — wszystkie cztery hosty migrowały się na
  kodzie sprzed F3.
  Odpowiedź: `docs/internal/reviews/responses/REV-20260802-034.md`.
- **REV-20260803-036** — **CHANGES REQUIRED, ZROBIONE** (ten commit): pauza
  była tekstowym konwenansem, nie transakcją. Pięć findingów P1, wszystkie
  ACCEPTED/IMPLEMENTED: `--fullcron` zamieniał crontab PRZED durable
  zapisem stanu resume (F1, kolejność odwrócona + atomowy rename + rollback
  stanu przy nieudanym zapisie crontaba); tryb blokowy commitował blok po
  bloku, więc częściowy sukces zwracał `rc=0` (F2, teraz jeden render
  lokalny + jeden zapis przez `cron_replace_all_impl`); `--resume` sprawdzał
  obecność markera przez `grep`, nie dokładny kształt, więc placeholder z
  dopisaną linią cichо gubił tę linię (F3, teraz bajt-po-bajcie przeciw
  zapisanemu placeholderowi); `cron_block_names_present` traktowało KAŻDY
  syntaktycznie poprawny `# BEGIN name` jako nasz (F4, teraz jawny rejestr
  `PAUSE_KNOWN_BLOCKS`); i najważniejsze — pauza nie była egzekwowana przez
  wspólnego pisarza, więc zwykły `gen-cron.sh --install` (albo
  `cron_block_ensure_line`/`adopt_line`) mógł po cichu odtworzyć aktywny
  blok zaraz po tym, jak `--pause` zgłosiło sukces (F5, teraz
  `cron_paused_guard` w `lib-cron.sh` odmawia KAŻDEMU zwykłemu pisarzowi).
  Markery pauzy przeniesione z `deploy.sh` do `lib-cron.sh` jako
  `CRON_PAUSE_*` — jeden kanoniczny właściciel dla wszystkich trzech
  programów, które piszą crontaba. `pause` **74/74** (+25 nowych testów,
  sekcje O–V), pełen graf `./test/impact.sh`: **665/665** bez błędów
  (`cron` 123, `run.sh` 56, `join` 54, `quiescehelper` 119, `selfupdate`
  28, `zfsbackup` 211). **Żywe hosty:** `deploy.sh --self-update` uruchomiony
  na wszystkich 4 (pve0, pve1, metropolis pve1, metropolis pve2) — czysty
  fast-forward na każdym, crontab roota i konta na pve0 bajt-w-bajt
  identyczny przed/po (guard nie odpala się na zwykłym, niezapauzowanym
  crontabie). `test/pause/run.sh` (suita ze stubem, nie dotyka prawdziwego
  `crontab(1)`) na wszystkich 4: **73/74** wszędzie — jeden powtarzalny
  fałszywy fail (sekcja G zakładała brak konta delegowanego, a każdy z tych
  hostów je ma; `detect_delegated_account()` skanowała prawdziwy `/home/*`,
  czego ta rodzina testów nie stubowała). **Naprawione tego samego dnia:**
  skan jest teraz nadpisywalny przez `PAUSE_ACCOUNT_SCAN_GLOB` (ten sam wzorzec
  co `CRON_LOCK_DIR`/`PAUSE_STATE_DIR`/`CRONTAB_DIR`), suita wskazuje ścieżkę
  bez dopasowań — `pause` **74/74** ponownie. **Prawdziwy cykl
  `--pause`/`--resume` wykonany tego samego dnia**, z właścicielem obecnym
  w sesji, na metropolis pve2: oba konta (root + zfsbackup) zapauzowane,
  obce (już wyłączone) linie w crontabie roota nietknięte (F4 na żywo),
  `--resume` odzyskał oba konta bajt-w-bajt identycznie do stanu
  sprzed pauzy. Bonus: F5 zadziałał na żywo bez planowania — `--resume`
  najpierw odpala pełny przebieg `deploy.sh` (fazy 1-7), a DOPIERO POTEM
  swój dispatch resume; dwa zwykłe zapisy w tym przebiegu (linia
  auto-update, linia capacity) trafiły na wciąż zapauzowany blok i zostały
  poprawnie odrzucone, zanim resume je przywrócił chwilę później —
  dokładnie scenariusz „forced interleaving" z recenzji, tyle że w jednym
  wywołaniu zamiast dwóch procesów. `sudo ./test/scenarios/run.sh`
  uruchomiony tego samego dnia na pve2 — **34/34**, scratch dataset
  posprzątany przez własny EXIT trap suity. **Domknięta luka zakresu F5:**
  `migrate-to-account` commituje przez `cron_replace_all`, ten sam prymityw
  co pauza/resume, celowo NIE owinięty `cron_paused_guard` (bo inaczej
  pauza odmawiałaby sama sobie) — co zostawiało migrację bez ochrony przed
  cichym nadpisaniem aktywnej pauzy. Naprawione bez dotykania wspólnego
  prymitywu: `cmd_migrate_to_account` sprawdza oba crontaby
  (`cron_fullcron_paused` + `cron_block_paused` dla `zfs-backup-managed`
  i `zfs-backup-host`) na starcie preflight, przed jakąkolwiek pracą.
  `zfsbackup` **214/214** (+3, sekcja 35). **Luka zgodności placeholdera
  sprzed `bc84746`** sprawdzona na żywo na wszystkich 4 hostach — żaden nie
  ma i nigdy nie miał `/root/.zfs-snapshot-all-pause-state` (funkcja nigdy
  nie była użyta produkcyjnie przed tą sesją) — shim migracyjny świadomie
  odrzucony jako złożoność dla przypadku, który nigdy się nie zdarzył.
  **Atomowa pauza całej floty (root+konto razem) świadomie odrzucona**:
  nigdy nie wymagana przez recenzję (kryteria F2 są sformułowane per-user),
  dziś nigdy nie cicha (każda tożsamość zgłasza swój błąd po imieniu), a
  jedyny osiągalny stan mieszany po przebudowie F2 to "jedna strona
  zapauzowana, druga nie" — nie częściowa korupcja. `cron_lock_acquire_multi`
  zostaje nieużywany, gdyby przyszły incydent zmienił ten osąd.
  Odpowiedź: `docs/internal/reviews/responses/REV-20260803-036.md`.
- **REV-20260803-035** — **CHANGES REQUIRED, ZROBIONE** (`9e977f6`): zamek
  F2 był kluczowany ścieżką zależną od **tożsamości wywołującego**.
  `CRON_LOCK_DIR` = `/run` jeśli zapisywalny, inaczej `$TMPDIR`/`/tmp` — root
  zawsze widzi `/run` jako zapisywalny, delegowane konto zwykle nie, więc
  root blokował `/run/lib-cron.<user>.lock`, a `gen-cron.sh` uruchomiony
  jako to samo konto blokował `/tmp/lib-cron.<user>.lock` **na tym samym
  crontabie**. Dwa różne zamki na jednym pliku to brak zamka — dokładnie
  wyścig F2, który miał być zamknięty. Testy P–S z REV-034 nie mogły tego
  złapać, bo obie strony testu dostają ten sam `CRON_LOCK_DIR` z zewnątrz.
  Naprawione: jeden stały katalog `/var/lib/zfs-snapshot-all/locks`
  (`$ALERT_SHARED_DIR`, ta sama obróbka 2775 root:zfsalert co kolejka
  alertów), bez żadnego fallbacku — niedostępny katalog odmawia, nie wybiera
  po cichu innego miejsca. Dodana też ochrona przed symlinkiem na
  przewidywalnej ścieżce blokady. `cron` **123/123** (+8, 5 SKIP na tej
  maszynie — bity uprawnień i symlink wymagają prawdziwego Linuksa).
  **Nie sprawdzone tutaj:** prawdziwy `flock` między realnym procesem roota
  a realnym procesem konta na tym samym hoście — wymaga żywego hosta,
  zgłoszone jako zobowiązanie ręczne (Faza 4 jest idempotentna, więc
  najbliższy `deploy.sh` na dowolnym hoście to podejmie za darmo).
  Odpowiedź: `docs/internal/reviews/responses/REV-20260803-035.md`.
- **REV-20260802-033** — recenzja **projektowa**, nie defektowa: uproszczony
  enrolment ma odkrywać dane **na źródle**, trzymać jeden edytowalny plik
  zakresu i odróżniać endpoint od trasy. Recenzja wprost zabrania
  implementowania czegokolwiek przed odpowiedzią. Odpowiedź w
  `docs/internal/reviews/responses/REV-20260802-033.md`: **wszystkie pięć findingów
  ACCEPTED**, F3 i F5 z naddatkiem.
  Poprzedziła ją rozmowa właściciel ↔ implementer — dziesięć uzgodnień spisanych
  w `docs/discussions/ENROLMENT-AGREED-2026-08-02.md`, m.in. edycja pliku na
  pve2, granty osobną komendą, zawężenie odbierające tylko własne granty, sync
  odrzucany między węzłami tego samego klastra, jeden aktualny endpoint zamiast
  slotów `lan`/`vpn`, oraz online bez żadnej nowej usługi.
  **Do zważenia przez recenzenta:** inwentaryzacja pokazuje, że szew z F1 jest
  mniejszy, niż zakłada recenzja — format paczki **już dziś** toleruje brak
  zakresu (`PEER_CONF_DATASETS` nie jest kluczem wymaganym, pętla grantów nie
  robi nic na pustej liście, `--draft-config` radzi sobie z pustym manifestem).
  Nowy jest wyłącznie drugi akt: finalizacja nadająca granty z edytowanego pliku.

  **Plasterek 1 ZROBIONY** (`ff712df`): `lib-scope.sh` — gramatyka, czytnik
  (`scope_read`) i decyzja `scope_includes`, plus cztery walidatory `pc_is_*`
  przeniesione z `deploy.sh`. `scope` **34/34**.
  **Plasterek 2 ZROBIONY** (`4190d83`): `--join` przestaje nadawać dla peera
  pull — konto i klucz bez żadnych uprawnień ZFS. Nowa, osobna komenda
  `--commit-scope=<label>` czyta plik zakresu, przechodzi realnymi
  potomkami każdego korzenia (`zfs list -r`, nie dziedziczeniem `zfs allow`,
  bo dziedziczenie nie ma odpowiednika „odmowy" dla `exclude_tree`) i nadaje
  dokładnie to, co `scope_includes` wybiera; `--allow-quiesce` przeniesione
  tu razem z nadaniem. `--commit-scope-check=<label>` to sama walidacja
  formatu (manifest, rola, `as`, parsowanie) bez `zfs` i bez roota — ten sam
  kształt co `do_join_check`, i z tego samego powodu: to czyni połowę
  formatową testowalną wszędzie. Peer root i push — bez zmian.
  Testy: `join` **54/54** (+12), `quiescehelper` **119/119** (jedna asercja
  dopasowana do nowej klauzuli), `zfsbackup` 211/211, `selfupdate` 28/28.
  **Nie sprawdzone tutaj:** sam przebieg `zfs list`/`zfs allow` na realnej
  puli — wymaga żywego hosta ze świeżym `--join`/`--commit-scope`, żaden
  istniejący peer nie jest w stanie sprzed tego plasterka. Zgłoszone jako
  zobowiązanie ręczne, tym samym kształtem co ryzyko F3 w REV-034.
  Odpowiedź: `docs/internal/reviews/responses/REV-20260802-033.md` (addendum
  2026-08-03).
- **REV-20260731-011 §2 — spór.** Zakwestionowałem tezę, że ścieżka błędu
  `mkdir allow_dir` nie wywołuje rollbacku: wywołanie jest tam od `763767b`,
  dowód przez `git show 7dc4a98:deploy.sh`. Zgodziłem się warstwę niżej
  (`created_dir=0` zostawiał pusty katalog) i to naprawiłem w `5fec1f4`.
  Recenzent nie odniósł się do tego wprost w późniejszych recenzjach.

### Czeka na decyzję właściciela

- **NOWE (REV-20260804-042): Bramki G i I potrzebują infrastruktury, nie
  kodu.** Dostępne dziś cztery hosty to dokładnie dwa dwuhostowe klastry
  Proxmox (pve0/pve1 na 192.168.11.x, metropolis pve1/pve2 na
  192.168.28.x), każda para ma dokładnie jedną trasę sieciową między sobą,
  a oba VPN-y klastrów są wzajemnie nieosiągalne (patrz punkt REV-039/F4
  wyżej). Bramka G (zmiana trasy przy zachowanym endpointcie) i bramka I
  (sync na nieklastrowanej parze) nie mają więc gdzie się wykonać na
  prawdziwej infrastrukturze. Trzy opcje wypisane w
  `docs/internal/reviews/responses/REV-20260804-042.md` dla każdej bramki osobno:
  (a) dostawić prawdziwą drugą trasę/piąty host, (b) autoryzować
  odizolowane środowisko laboratoryjne na istniejącym hoście (kontenery/
  network namespace, bez dotykania produkcyjnej sieci klastra), albo
  (c) świadomie przyjąć lukę i przestać ją traktować jako blokującą.
  Żadna opcja nie wymaga zmiany kodu produkcyjnego.
- ~~Jeden przepływ zamiast trzech poleceń~~ — **ROZSTRZYGNIĘTE 2026-08-02:
  opcja (b).** Uprzywilejowany grant zostaje osobną, świadomą komendą;
  `migrate-to-account` wypisuje **jeden uporządkowany blok naprawczy** zamiast
  składać go za operatora, i sprawdza zdolności **ponownie tuż przed zapisem
  crontabów**. Opcję (c) — żeby wrapper sam wołał `deploy.sh` — odrzucono:
  jego najgorszy dzisiejszy błąd przepisuje crontab (odwracalne), po (c)
  poszerzałby grant (nikt nie zauważy). Granica `zfs-backup.sh`/`deploy.sh`
  z REV-020 F1 zostaje tam, gdzie była.

- ~~Ścieżka zdalna (`snapget -q`) bez ponownego odczytu i terminu~~ —
  **DOCIĄGNIĘTA 2026-08-02** (`7564f8e`): kolejność, ponowny odczyt na granicy,
  termin i odmowa przy nieczytelnym `fsfreeze-status`. Thaw był tam gwarantowany
  od początku (trap EXIT + deadman).
- ~~DŁUG: `snapsend`, `scenarios`, `remote` nieuruchomione~~ — **SPŁACONY
  2026-08-02 12:00–12:45.** `remote` 145/145 **dwukrotnie** — jako root i jako
  konto delegowane (to drugie z `--local-parent rpool/data`, bo domyślny scratch
  `rpool` jest pisany pod roota, a konto ma delegację tylko niżej). `snapsend`
  202/202, `scenarios` 34/34 na metropolis pve1.
- ~~Klaster 192.168.11.x bez kampanii `remote`~~ — **ZROBIONE 2026-08-02**, po
  sprawdzeniu replikacji i za zgodą właściciela. `remote` 145/145 pve0 → pve1
  (11.11), z `--peer-parent rpool`. Replikacja pvesr zweryfikowana przed
  uruchomieniem: zadania 100-0 i 106-0 co 2 h, FailCount 0, ostatni sync 14:00,
  a na pve0 wszystkie trzy repliki niosą snapshot `__replicate_*` z tej samej
  godziny — czyli obie maszyny z 11.11 dają się podnieść z hosta zapasowego.
  **Osobno do wiedzy: zadanie 101-0 (pve0 → pve1) jest WYŁĄCZONE od
  2023-10-26**, FailCount 6, ostatni sync sprzed prawie trzech lat. To druga
  strona relacji i nie dotyczy zabezpieczenia 11.11, ale VM 101 na pve0 nie ma
  repliki na sąsiedzie — tylko snapshoty retencyjne u siebie.
- ~~Luka parzystości: kampania na 11.x tylko jako root~~ — **ZAMKNIĘTA
  2026-08-02, decyzją właściciela.** Między kontami `zfsbackup` na pve0 i pve1
  (11.11) nie było zaufania ssh; oba miały już parę kluczy ed25519 z
  `deploy.sh`, brakowało wyłącznie `authorized_keys` i `known_hosts`.
  Ustanowione **dwukierunkowo**, w kształcie identycznym z metropolis (zwykły
  wpis, bez `command=`), a klucz hosta pobrany z `/etc/ssh/ssh_host_ed25519_key.pub`
  sąsiada **przez zaufany kanał roota**, nie `ssh-keyscan` — żadnego ślepego
  TOFU. `remote` **145/145** jako konto, `--local-parent rpool/data
  --peer-parent rpool/data` (oba hosty delegują kontu dokładnie ten dataset,
  z tym samym zestawem 11 czasowników co metropolis).
  **Cztery hosty mają teraz ten sam stan:** blok na koncie delegowanym, grant
  quiesce, config w `/etc/zfs-snapshot-all/`, zaufanie ssh między kontami pary
  i kampania `remote` przechodząca jako root **i** jako konto.
- ~~Ścieżka zdalna bez ponownego odczytu i terminu~~ — **DOCIĄGNIĘTA**
  (`7564f8e`), a granica objęła **każdą pulę** (`c7ce8da`, REV-029), niekompletny
  zestaw jest **usuwany** (`9fbf1df`, REV-030), a raport wycofania nie może już
  zawieść fail-open (`3d4c13f`, REV-031).
- ~~Czy migrować pozostałe hosty~~ — **ZROBIONE 2026-08-01/02: wszystkie
  cztery.** pve2 21:44, pve1 192.168.11.11 23:02, pve0 23:05. Każdy host ma
  własne konto delegowane, grant quiesce i config w `/etc/zfs-snapshot-all/`.
  Pierwszy nocny przebieg pod cronem przeszedł na wszystkich, z potwierdzeniem
  zamrożenia na granicy snapshotu (okna 1–4 s przy budżecie 5 s).
- ~~pve2: `[prune-bookmarks:rpool]` szerszy niż delegacja~~ — **ZAŁATWIONE
  2026-08-02, zawężeniem zakresu, nie poszerzeniem grantu.** Pod `rpool` na
  pve2 są dokładnie dwa poddrzewa (`rpool/ROOT/pve-1`, `rpool/data`) i oba są
  już delegowane; sam `rpool` nigdy nie trzyma bookmarków, bo bookmark powstaje
  wyłącznie na datasecie **wysyłanym**. Alternatywą było nadanie kontu pełnego
  jedenastoczasownikowego zestawu na `rpool`, czyli `destroy` nad całą pulą
  root, dla jednego prune'a. Zweryfikowane: zmieniony wyłącznie zakres w jednej
  linii crona, prune jako konto rc=0, liczba bookmarków bez zmian (4+3), survey
  zdolności czysty. Config w `zfs-cron-configs` `6cf289b`.
- **Dysk w pve1 (192.168.11.11).** Lustro `rpool` na jednym NVMe od
  2026-04-16, host z vsql2, jedyna pula na maszynie. Największa otwarta rzecz
  w projekcie i jedyna, której nie da się rozwiązać kodem.
- **`qemu-guest-agent` w VM 102 (`neth`) na metropolis pve1.** Nie działa
  wewnątrz gościa mimo `agent: 1`, więc maszyna dostała `quiesce = no`.
  Zainstalowanie agenta pozwala zdjąć tę jedną linijkę z configu.
- ~~metropolis pve2 nie ma pliku configu swojego crona~~ — **ZAŁATWIONE
  2026-08-01 21:32.** 14 produkcyjnych linii wskazywało
  `# Source: /root/gfs-install-tmp/jobs.pve2.v4.conf`, a tego katalogu nie było.
  `cron2conf.sh` odtworzył config z żywego crontaba, round-trip przez
  `gen-cron.sh` dał 12/12 linii bajt w bajt w tej samej kolejności, i dopiero
  wtedy plik został zainstalowany w `/etc/zfs-snapshot-all/jobs.pve2.v4.conf`.
  Crontab przed/po różnił się wyłącznie linią `# Source:` — liczba linii zadań
  bez zmian, 14 = 14. Guard z `c6c98c2` nie był naruszony: narzędzie nadal nie
  tworzy tego pliku samo, zrobił to człowiek po obejrzeniu diffa.
- ~~Config wewnątrz checkoutu gita~~ — **ZAŁATWIONE NA WSZYSTKICH CZTERECH
  HOSTACH 2026-08-01/02.** Configi leżały w `zfs-snapshot-all/`, nietrackowane
  i ignorowane, gdzie jedno `git clean -xdf` kasowało jedyny zapis zadań
  produkcyjnych. Każda migracja **przeniosła** swój config do
  `/etc/zfs-snapshot-all/` — nie skopiowała, więc nie ma dwóch ścieżek
  opisujących jedną pracę. Kopie są też w prywatnym `zfs-cron-configs`.
- ~~VM 102 (`neth`) na metropolis pve1 nie ma żadnego zadania snapshotowego~~ —
  **ZAŁATWIONE 2026-08-01 23:23.** Miała wyłącznie replikację pvesr `sun 01:00`
  i zero snapshotów retencyjnych: jedna kopia na pve2, nadpisywana co niedzielę,
  najgorszy punkt odtworzenia siedem dni, zero historii. Dostała te same cztery
  szablony co sąsiedzi (24/7/4/6), ale z `quiesce = no` — patrz punkt o agencie
  wyżej.
- **Korelacja per przebieg dla SQL** (REV-010 §2): odczyt najwyższego
  `EventRecordID` przed freeze i tylko nowych zdarzeń po thaw, wewnątrz jednej
  operacji zdalnej `snapget -q`. To nowa powierzchnia uprzywilejowana.
- **`--require-engaged` / `verify-sql-quiesce`** (REV-010 §3): tryb fail-closed,
  ma wejść razem z pierwszym konsumentem, nie wcześniej.
- **Uproszczenie UX wdrożenia — kryterium recenzenta, wciąż niespełnione**
  (REV-014): zwykły administrator Linuksa/ZFS ma używać **jednego** wysokopoziomowego
  przepływu enroll/remove, bez znajomości `pair`, `join`, wewnętrznych plików
  grantu i flag backendu. Akceptacja transakcji grantu **nie** czyni remote
  quiesce właściwym domyślnym ustawieniem uproszczonego wdrożenia. Powiązane z
  `docs/discussions/DEPLOY-UX-AGREED-POSITION.md`.
- **`PAIRING-DESIGN.md` Wariant B** — nadal propozycja, nie kod.
- **Automatyczna instalacja draft-configu** bez przeglądu administratora —
  odłożona.

### Znane luki, nie planowane do zamknięcia teraz

- **Test odtworzenia vsql2.** Jedyna rzecz, która dowodzi, że snapshot się
  przywraca — `engaged` z `sqlfreeze` mówi tylko, że SQL uczestniczył. Nie
  wykonany; **właściciel wykonuje go ręcznie** (decyzja z 2026-07-31), więc nie
  jest to pozycja zapomniana ani czekająca na implementera.
- **Trwałość wobec zaniku zasilania.** `rename` jest atomowy, nie trwały. Wobec
  `kill -9` i OOM projekt jest kompletny; wobec zaniku zasilania opiera się na
  systemie plików (ZFS transakcyjny, ext4 zrzuca dane przed rename na istniejący
  plik). Świadomie bez `sync`. To jest ocena, nie dowód.
- **Zamrożenie guesta na żywo** — instalacja grantu jest już przetestowana
  end-to-end (sekcja 1), ale freeze/thaw na produkcyjnym guescie nadal nie.
  VM 106 na metropolis pve1 to produkcyjny Windows `vbim2`; wymaga osobnej
  decyzji.
- **Ścieżki awarii i crash na żywym hoście** — na produkcji przeszedł happy
  path; wymuszone błędy `install`/`mv` i SIGKILL zostają w piaskownicy.
- **`-q` poza profilem `standard`** `zfs-backup.sh`, dopóki recenzent nie zamknie
  pozycji cyklu życia.
- **P2 dług testowy kontrolera aktualizacji** z uzgodnienia 2026-07-30: brak
  deterministycznego testu łączącego nieudaną aktualizację po `--resume-updates`
  z jednoczesną awarią ponownego zapisania holda; nie każdy caller prymitywów
  state/hold ma osobny scenariusz fault-injection. Otwierać ponownie przy
  materialnej zmianie `write_state_file()`, `remove_state_file()`,
  `emergency_disable()`, `do_self_update()`, `do_rollback()`, `do_resume_updates()`.

## 7. Aktualizacja i rollback

Kontroler `/root/.zfs-snapshot-all-update-state/update-control.sh` jest
instalowany **poza** checkoutem Git, więc cofnięcie repozytorium nie cofa kodu
egzekwującego hold. Cron wywołuje go bezpośrednio. `emergency_disable()` jest
fail-closed.

**Obowiązkowa zasada wydania:** zmiana `update-control.sh` wymaga po pobraniu kodu
pełnego `bash /root/scripts/zfs-snapshot-all/deploy.sh` na każdym hoście. Godzinny
self-update aktualizuje checkout, ale celowo nie nadpisuje kontrolera, który
właśnie działa.

## 8. Uzgodniony workflow

1. Właściciel wskazuje następny problem lub etap.
2. Implementer implementuje i testuje, obecnie bezpośrednio w `main`.
3. Każda materialna zmiana to osobny, czytelny commit z dowodami testów.
4. Recenzent wykonuje niezależną recenzję kodu, testów i skutków operacyjnych.
5. **Implementer odświeża ten dokument na końcu etapu**, przed zgłoszeniem go jako
   zrobiony, żeby obie strony patrzyły na ten sam stan.
6. Implementer nie zamyka findingów — zamknięcie techniczne należy do recenzenta.
7. Zamkniętych ustaleń nie otwieramy bez nowego dowodu regresji albo zmiany
   założeń.
8. Testy na żywych hostach używają sandboxów i porównania before/after wszędzie,
   gdzie mogą dotknąć crona, uprawnień albo prawdziwych datasetów.

Poprzedni uzgodniony punkt bazowy `388a78e` (2026-07-30) pozostaje ważny jako
zapis tego, co zostało wtedy wspólnie przyjęte. Ten dokument opisuje stan
bieżący; historia decyzji żyje w `docs/internal/reviews/` i `docs/internal/reviews/responses/`.
