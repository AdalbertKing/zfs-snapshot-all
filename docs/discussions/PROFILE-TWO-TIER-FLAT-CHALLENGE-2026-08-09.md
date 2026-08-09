# Two-tier flat profile challenge — baseline + harder adversary

Date: 2026-08-09
Status: REVIEWER/ARCHITECT -> CLAUDE RESPONSE REQUESTED

Owner direction remains: **reduction, not complication**.

This note gives one concrete profile-shaped policy that should be easy to express, then a harder adversary that should try to break the model. Do not answer by inventing a framework. Prefer refusal, one extra explicit binding, or manual CONFIG over inheritance/composition/macros unless current native CONFIG v4 truly cannot express the required behavior safely.

---

## 1. Baseline policy — one source root, two independent create tiers, no GFS

Source scope is relation-owned:

```text
SOURCE ROOT = rpool/data
include_parent   = no
include_children = yes
```

So `rpool/data` itself is not protected, but current and future descendants are in scope dynamically.

Reusable HOW policy:

```text
recursive = flat
GFS       = no

TIER hourly
  create cadence = hourly
  prefix         = hourly_
  retention      = 24 hourly points
  quiesce        = no

TIER daily
  create cadence = daily
  prefix         = daily_
  retention      = 30 daily points
  quiesce        = yes/auto
```

The key semantic requirement is that these are **two independent snapshot populations**:

```text
hourly_* -> retain 24

daily_*  -> retain 30
```

Daily is not selected from hourly and there is no shared GFS ladder.

Conceptual native shape:

```ini
[template:hourly]
send_schedule = 1 * * * *
prefix = hourly_
quiesce = no

[template:keep_hourly]
prune_schedule = 21 * * * *
pattern = hourly_
retain = -H24

[template:daily]
send_schedule = 15 0 * * *
prefix = daily_
quiesce = auto

[template:keep_daily]
prune_schedule = 35 0 * * *
pattern = daily_
retain = -D30
```

Dataset fragment conceptually:

```ini
use_template = hourly,daily
recursive = flat
```

Prune policy conceptually:

```ini
use_template = keep_hourly,keep_daily
gfs = no
```

Exact native spelling must follow current CONFIG v4 rather than this note if any field differs.

### Required runtime semantics

Assume descendants at configuration time:

```text
rpool/data/vm-100-disk-0
rpool/data/vm-101-disk-0
rpool/data/vm-102-disk-0
```

Hourly run at 11:01:

```text
discover descendants
-> create one hourly_* run identity across 100/101/102
-> NO quiesce
-> transfer flat, each descendant independent
```

Daily run at 00:15:

```text
discover descendants
-> quiesce the guests that require/can perform quiesce
-> create one daily_* run identity across 100/101/102
-> thaw
-> transfer flat, each descendant independent
```

If `rpool/data/vm-103-disk-0` is created tomorrow, it joins the next hourly run and next daily run automatically, subject to the existing grant/capability boundary. No CONFIG regeneration should be required merely because the descendant appeared.

### Local high-level command target

```bash
./zfs-backup.sh \
  --source=rpool/data \
  --target=hdd/backups \
  --profile=<NAME>
```

Preview should summarize the policy in human terms, not expose internal namespaced template names:

```text
SOURCE      rpool/data
PARENT      no
DESCENDANTS yes, dynamic
RECURSION   flat
GFS         no

HOURLY
  every hour
  prefix hourly_
  retain 24
  freeze no

DAILY
  every day
  prefix daily_
  retain 30
  freeze yes
```

### Remote high-level target

Source side owns WHAT/grants; collector owns profile binding HOW.

Conceptually:

```bash
# source pve2
./zfs-backup.sh --join=/root/wsad.tgz
# approve rpool/data children, parent excluded

# collector pve1
./zfs-backup.sh add-client pve2 \
  --host=192.168.28.8 \
  --source=rpool/data \
  --profile=<NAME>
```

If daily quiesce requires extra source-side authorization for a delegated account, the high-level flow may request/verify that capability, but it must not make a new user-facing subsystem out of it.

### Questions for Claude on the baseline

1. Can current CONFIG v4 represent this exact two-population/no-GFS policy without native schema changes?
2. Can current `gen-cron` render both create tiers for one `[dataset:]` with tier-specific quiesce exactly as intended?
3. Can current prune representation retain `hourly_*` by H24 and `daily_*` by D30 on the same destination without accidental overlap?
4. Does the existing relationship lock allow both schedules to coexist safely if their times are distinct? What happens if a long hourly run crosses the daily start?
5. For `flat`, does the daily quiesce implementation quiesce all relevant descendants before snapshot creation, or one descendant at a time? State the actual consistency guarantee, not the marketing phrase.
6. What happens when a new dynamic descendant appears but the delegated quiesce whitelist/grant has not yet been expanded? The acceptable answers are explicit refusal/alert/re-authorization; silent omission or silent non-quiesced daily is not acceptable.
7. What is the smallest production change needed to support this policy if it is not already expressible? Prefer one native fix over profile-only machinery.

---

## 2. Harder adversary — one child needs a stronger policy than its siblings

Now try to break the simple `SOURCE ROOT -> PROFILE` model without creating profile inheritance.

Initial tree:

```text
rpool/data
├── vm-100-disk-0
├── vm-101-disk-0
└── vm-102-disk-0
```

Base requirement for the whole dynamic subtree remains exactly the baseline above:

```text
rpool/data/*
  hourly_ every hour, retain 24, no freeze
  daily_  every day, retain 30, freeze
  flat
  parent excluded
```

After deployment, the owner decides that **only VM 101** is special because it contains an important database.

New requirement for `vm-101-disk-0` only:

```text
hourly behavior: unchanged

daily behavior:
  still daily + freeze
  retain 90 instead of 30
```

Everything else under `rpool/data/*` must remain at daily retention 30, including descendants created later.

Desired semantics:

```text
vm-100 -> H24 + D30
vm-101 -> H24 + D90
vm-102 -> H24 + D30
future vm-103 -> H24 + D30
```

There must be no double-send, double-prune, duplicate snapshot population, ambiguous ownership, or accidental removal of VM 101 from the parent's dynamic discovery without an explicit durable rule.

### Why this is the harder opponent

The simple model says:

```text
rpool/data -> one reusable HOW profile
```

The exception appears to demand either:

- a more-specific child binding;
- a carve-out/exclusion from the parent binding;
- a second relation;
- a manual CONFIG exception;
- or a new profile composition/override mechanism.

Owner direction strongly disfavors the last option.

### Reviewer counterproposal — prefer explicit carve-out over inheritance

My preferred minimal direction, if this use case is judged worth supporting, is **not** profile inheritance and not per-tier override syntax.

Use two ordinary bindings plus one explicit non-overlap rule:

```text
BINDING A
  source root = rpool/data
  parent      = no
  descendants = yes
  exclude     = rpool/data/vm-101-disk-0
  profile     = BASE

BINDING B
  source root = rpool/data/vm-101-disk-0
  parent      = yes
  descendants = no
  profile     = DB90
```

Where `BASE` and `DB90` are two complete reusable HOW policies, not parent/child profiles.

Conceptually:

```text
BASE
  hourly H24 no-freeze
  daily  D30 freeze
  flat

DB90
  hourly H24 no-freeze
  daily  D90 freeze
  no-recursion for the leaf
```

This is intentionally repetitive. Two complete profiles are cheaper and easier to reason about than an inheritance engine if the real world has only a few such policies.

If the existing scope grammar cannot express a safe carve-out cleanly, the simpler product answer may be:

```text
V1: overlapping profile bindings are refused.
For one exceptional VM use manual CONFIG v4 or a separate explicit source selection.
```

That is acceptable under the reduction rule. We should not build a hierarchy system merely to make this one example elegant.

### Questions for Claude on the adversary

1. Can the existing relation/scope model express a durable exclusion/carve-out without introducing another selector language?
2. If yes, can `flat` dynamic discovery honor that carve-out so future siblings still join automatically while VM 101 is never double-covered?
3. If no, what is simpler and safer for V1: manual CONFIG for the exceptional child, separate relation/binding, or one minimal native exclusion feature?
4. Is a child-specific retention exception actually seen in the measured four-host production configs, or is this only a hypothetical stress test? If not evidenced, do NOT implement it now.
5. Does any proposed solution increase the number of user-visible concepts? If yes, justify the reduction it buys.
6. Explicitly reject profile inheritance/composition/macros unless you can demonstrate that the measured production policies cannot be reduced safely without them.

---

## 3. Convergence criterion

The baseline should be supported with **one simple coherent profile** if native CONFIG v4 already has the required primitives.

The harder adversary should not force new architecture merely because it is possible to imagine. Preferred outcomes, in order:

```text
1. existing primitives already express it safely
2. one small native scope/binding rule expresses it safely
3. explicit manual CONFIG / separate binding for the rare exception
4. defer the scenario
5. only then consider a new abstraction
```

The goal is not maximum expressiveness. The goal is the smallest system that remains obvious to an administrator and fails closed when the requested policy cannot be represented without overlap or ambiguity.
