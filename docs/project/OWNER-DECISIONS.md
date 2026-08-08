# Owner decisions

This file is the escalation queue for decisions that Claude and the Reviewer cannot resolve technically between themselves.
It is **not** a review-state ledger and must never duplicate `REVIEW_LEDGER.md`.

## Escalation rule

A disagreement between Claude and the Reviewer is not automatically an Owner question.

Before escalation, both agents must use the existing REV/response discussion channel to:

1. state the disputed claim precisely;
2. provide code, tests, documentation, operational evidence or a reproducible counterexample;
3. answer the other side's strongest argument;
4. identify whether the disagreement can be decided by repository facts, tests, existing architecture, safety policy or project goals already recorded in the repo.

If evidence resolves the disagreement, the agents record the consensus in the existing artifact and continue. The Owner is not asked to arbitrate ordinary technical review.

Escalate here only when a real choice remains that requires Owner authority, for example:

- product or architecture direction with two technically valid alternatives;
- priority or scope trade-off;
- acceptance of operational/security/compatibility risk;
- intentional breaking change;
- defer-versus-fix decision;
- release/deployment timing where evidence alone cannot decide.

An escalation entry must be short and decision-ready: the question, Claude's preferred option, Reviewer's preferred option, agreed facts, material consequences of each option, and a recommended default if the Owner chooses not to expand the discussion.

Transient disagreement, wording disputes, review bookkeeping, or lack of synchronization must never be escalated to the Owner.

## Open decisions

None.

## Currently queued

Carried over from the pre-V2 thread table. Each is a real choice that repository
facts cannot settle.

| # | Item | Whose move |
|---|---|---|
| 8 | PR #4 — a SECOND implementation of logical pause | owner: confirm the close, or say what else to salvage |
| 9 | Issue #3 — enrolment contract consensus | owner+reviewer |
| 11 | Profiles + live recursion (backlog) | owner |
| 14 | `docs/OPS_MONITORING.md` untracked | owner: keep or drop |
| 15 | Two sessions built the same feature the same day | owner: decide how parallel sessions announce what they are taking |
| 36 | Grants on pve0 are per-dataset, not on the parent | owner: per-dataset (today) or parent grant |
| 32 | Plan: method + stages | owner+reviewer: approve or amend |
| 29 | Engine CLI / profiles / restore — design discussion | owner+reviewer: discuss |
| 30 | Atomic restore point — measured, and one gap | owner+reviewer: accept into the pre-freeze engine slice |

---

## ROZSTRZYGNIETE 2026-08-08 — czym jest zabezpieczenie na tym poziomie

Implementer zmierzyl, ze 24 z 29 zadan we flocie tylko snapshotuje, a wszystkie
5 pozostalych ma cel LOKALNY, i przedstawil to jako luke: "w tej flocie nie ma
ani jednej kopii poza host".

**Wlasciciel: to jest bledna przeslanka, nie luka.**

> Nikt nie powiedzial, ze zabezpieczenie to wyslanie poza host. Nie na tym
> poziomie taka ocena. Host moze miec druga pare dyskow i na niej oddzielny pool
> (tu `hdd`), i wyslanie tam snapshotow z `rpool/data` jest zabezpieczeniem.
> Replika zalatwia tu transfer miedzyhostowy.

Warstwy sa rozdzielone i kazda robi swoje:

| warstwa | przed czym chroni |
|---|---|
| snapshot lokalny | skasowanie pliku, blad w maszynie |
| kopia na DRUGA PULE tego samego hosta | utrata puli / pary dyskow |
| pvesr | smierc hosta |

Zmierzone i zgodne z tym wzorcem: `rpool/data/*` -> `hdd/backups/*` na pve2
i pve0 to kopie MIEDZY PULAMI. 11.x pve1 ma tylko jedna pule (`rpool`), wiec
kopia miedzypulowa jest tam fizycznie niemozliwa.

**Konsekwencja dla narzedzi:** `--reconcile` NIE dostaje pojecia "poziomu
ochrony" i nie ocenia, czy zabezpieczenie jest wystarczajace. Taka ocena jest
architektoniczna i nie nalezy do audytu zakresu. Propozycja implementera, zeby
rozdzielic "snapshot lokalny" od "kopia poza hostem" jako klasy w raporcie,
jest **odrzucona** — zaszywalaby opinie polityczna w mechanizmie, ktory ma
raportowac fakty.

Audyt odpowiada na pytanie "czy cokolwiek to obejmuje", nie "czy to wystarczy".

---

## ROZSTRZYGNIETE 2026-08-08 — hdd/isos na pve0

Fakty: 16 GB, zamontowany, uklad magazynu katalogowego Proxmoksa
(`dump/`, `private/`, `template/`), zalozony 2019-09-18, zero snapshotow, zadne
zadanie go nie obejmuje.

**Wlasciciel: bez kopii — na liste ignorowanych.** Obrazy instalacyjne i
szablony sa do pobrania ponownie.

**Status wykonania: NIEZROBIONE, i to swiadomie.** Mechanizmu listy
ignorowanych jeszcze nie ma. Nie buduje go teraz z dwoch powodow:

1. recenzent uwarunkowal go wprost: jawna lista ignorowanych jest do rozwazenia
   **dopiero gdy sam detektor bedzie poprawny**, a REV-20260808-074 jest wciaz
   otwarta wlasnie na jego poprawnosci (dwie wady w klasyfikacji i parsowaniu
   flag znalezione tego samego dnia);
2. ksztalt mechanizmu to **zmiana schematu CONFIG v4** albo nowy plik obok
   niego, a to decyzja projektowa, nie szczegol implementacyjny.

### Propozycja do rozstrzygniecia (wlasciciel + recenzent)

| wariant | za | przeciw |
|---|---|---|
| nowa sekcja `[ignore:<dataset>]` w CONFIG v4 | jedno zrodlo prawdy, ten sam plik co reszta polityki, `cron2conf` i migracje juz go widza | poszerza schemat, ktory wlasnie zamrozilismy pojeciowo; kazdy konsument configu musi ja umiec pominac |
| osobny plik `/etc/zfs-snapshot-all/reconcile-ignore`, jeden dataset na linie | zero zmian w schemacie, czytelne dla czlowieka, latwe do wersjonowania | drugi plik do utrzymania i do wdrozenia na hosty |

Sklaniam sie do **drugiego**: audyt zakresu to nie polityka kopii, wiec jego
lista wyjatkow nie musi mieszkac w pliku polityki — a schematu nie ruszamy w
momencie, gdy detektor jest jeszcze recenzowany.

Do czasu rozstrzygniecia `hdd/isos` **pozostaje zgloszany** przez `--reconcile`.
Zapisane tutaj, zeby decyzja nie zyla wylacznie w rozmowie.
