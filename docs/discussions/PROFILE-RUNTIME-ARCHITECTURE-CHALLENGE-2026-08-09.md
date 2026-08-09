# Profile runtime architecture challenge — worked profiles + deployment flows

Date: 2026-08-09
Status: **REVIEWER/ARCHITECT -> CLAUDE RESPONSE REQUESTED**

This discussion follows `PROFILE-ARCHITECTURE-PREMORTEM-2026-08-09.md` and the Owner's request to test the design against concrete hypothetical profiles and deployment commands, not just abstract field lists.

This is NOT a runtime REV. Many points concern behavior that does not exist yet. The goal is to resolve architecture before broad profile selection/mutation reaches production.

Narrow B1 extraction of the current default hardcode may continue only if it remains behavior-equivalent and does not silently introduce the broader semantics below. Do not add new built-in profile variants or broad profile-selection runtime as a side effect of B1 before this discussion converges.

---

# 1. Ground rules already settled

- RELATION / SCOPE owns WHAT and WHERE.
- PROFILE owns reusable HOW.
- ACCOUNT owns who runs the production jobs.
- Source-side grants remain a separate authorization boundary.
- Profiles do not contain concrete dataset names, hosts, target paths, keys or grants.
- One relationship may bind different source roots to different profiles (`SOURCE ROOT -> PROFILE`).
- CONFIG v4 remains the single effective native representation consumed by `gen-cron.sh`.
- Profile-owned template names are namespaced deterministically from first emission.
- Root remains a valid/default execution account; `zfsbackup` is an explicit host execution choice, not profile policy.

The point of this challenge is to identify where those clean boundaries are insufficient unless composition adds compatibility/capability/lifecycle checks.

---

# 2. Three hypothetical profiles

Names are deliberately provisional. They describe behavior for discussion; they are NOT a request to create these directories yet.

## P1 — `standard-flat`

Use case: ordinary frequent protection, equivalent in spirit to today's default policy, with dynamic descendants as independent streams.

Intent:

```text
CREATE:
  hourly snapshot/send
  quiesce = no

RETENTION:
  H24 / D7 / W4 / M12 GFS derived from the hourly-created snapshot population

RECURSION:
  flat

MONITOR:
  hourly freshness (e.g. warn 90m / crit 150m)
```

Conceptual native fragments:

```ini
# templates.conf
[template:hourly]
send_schedule = 1 * * * *
prefix = automated_hourly_
quiesce = no
autotune = yes

[template:keep_hourly]
prune_schedule = 21 * * * *
pattern = automated_hourly
retain = -H24
monitor_warn = 90m
monitor_crit = 150m

[template:keep_daily]
prune_schedule = 21 * * * *
pattern = automated_hourly
retain = -D7

[template:keep_weekly]
prune_schedule = 21 * * * *
pattern = automated_hourly
retain = -W4

[template:keep_monthly]
prune_schedule = 21 * * * *
pattern = automated_hourly
retain = -M12

# dataset.inc
use_template = hourly
recursive = flat

# prune.inc
use_template = keep_hourly,keep_daily,keep_weekly,keep_monthly
gfs = yes
gfs_pattern = automated_
```

Important semantics: `daily/weekly/monthly` here are retention buckets, NOT separately-created consistent daily/weekly/monthly snapshots.

---

## P2 — `daily-consistent-flat`

Use case: cheap hourly crash-consistent recovery points, plus one deliberately quiesced daily recovery point from which weekly/monthly retention is derived.

Desired intent:

```text
CREATE CLASS A — HOURLY:
  every hour
  quiesce = no
  recursive = flat
  prefix = automated_hourly_

CREATE CLASS B — DAILY CONSISTENT:
  once per day
  quiesce = auto
  recursive = flat
  prefix = automated_daily_q_

RETENTION A:
  keep recent hourly points only (e.g. H24)

RETENTION B:
  D7 / W4 / M12 from ONLY the quiesced daily population

MONITOR:
  hourly freshness checked independently
  daily-consistent freshness checked independently
```

Conceptual templates:

```ini
[template:hourly]
send_schedule = 1 * * * *
prefix = automated_hourly_
quiesce = no

[template:daily_q]
send_schedule = 15 0 * * *
prefix = automated_daily_q_
quiesce = auto
monitor_warn = 30h
monitor_crit = 40h
```

The architectural requirement is NOT the exact cron minute. It is that two different CREATE classes exist and their consistency classes do not get mixed by retention.

A single `gfs_pattern = automated_` is suspicious/wrong here because `delsnaps -G` chooses the newest matching snapshot per bucket without knowing consistency provenance. A weekly/monthly survivor could therefore be an hourly non-quiesced snapshot.

We need a native representation that can express, on the same source/target scope:

```text
hourly population       -> ordinary H24 retention
quiesced-daily population -> GFS D7/W4/M12
```

without overlapping prune races and without relying on profile-only magic hidden from manual CONFIG v4.

---

## P3 — `daily-consistent-atomic`

Use case: one coherent subtree recovery point per day; no hourly tier required.

Desired intent:

```text
CREATE:
  daily
  quiesce = auto
  recursive = atomic
  prefix = automated_daily_atomic_

RETENTION:
  D7 / W4 / M12 (and optionally later yearly if a real use case earns it)

MONITOR:
  daily tier only
```

This is deliberately simpler than trying to mix `hourly=flat` and `daily=atomic` on the same source root. Current CONFIG v4 recursion is source-section-wide, not tier-wide. Unless evidence justifies a schema change, a single source root should not pretend it can have different recursive modes per tier.

---

# 3. Local deployment flows — target UX

These are target high-level commands, not claims that current runtime already accepts them.

## L1 — root + `standard-flat`

```bash
./zfs-backup.sh --target=hdd/backups \
                --source=rpool/data \
                --profile=standard-flat
```

Expected plan before mutation:

```text
RELATION
  target: hdd/backups
  account: root

SOURCE BINDING
  rpool/data
  scope: parent=no, descendants=yes
  profile: standard-flat
  profile digest: <pinned digest>

COMPATIBILITY
  flat + parent=no: OK

CAPABILITIES
  quiesce required: no
  remote link autotune: not applicable for local target

EFFECTIVE POLICY
  hourly create
  crash-consistent
  H24/D7/W4/M12 GFS from hourly population

ACTIONS
  compose CONFIG v4
  show config + cron
  confirm
  persist configured
  foreground seed
  persist seeded
  install/read-back root cron
  persist active
```

Six days later add `rpool/lxc` with the same profile:

```bash
./zfs-backup.sh --source=rpool/lxc --profile=standard-flat
```

Expected delta:

```text
EXISTING
  rpool/data -> standard-flat (unchanged)

ADD
  rpool/lxc  -> standard-flat

SEED
  rpool/lxc only
```

## L2 — delegated account + `daily-consistent-flat`

```bash
./zfs-backup.sh --target=hdd/backups \
                --source=rpool/data \
                --profile=daily-consistent-flat \
                --local-user=zfsbackup
```

The user should NOT need to know `deploy.sh --allow-quiesce`.

High-level orchestration must derive capabilities from the selected profile:

```text
profile says quiesce=auto on daily_q
        ↓
account=zfsbackup
        ↓
required capability: delegated quiesce helper + whitelist/sudo rule
        ↓
show exact privilege delta
        ↓
explicit authorization where required
        ↓
provision + read-back
        ↓
only then activate CONFIG/cron
```

If the helper/authorization cannot be provided, activation must refuse BEFORE installing a cron that will first fail at 00:15.

## L3 — incompatible scope/profile

Operator has selected:

```text
scope rpool/lxc:
  parent=no
  descendants=yes
```

and asks:

```bash
./zfs-backup.sh --source=rpool/lxc --profile=daily-consistent-atomic
```

Required result:

```text
REFUSE
atomic requires the selected root itself to participate in the recursive stream;
current scope explicitly excludes rpool/lxc.

No scope widening.
No silent parent inclusion.
No config/cron mutation.
```

This implies a real composition-time compatibility validator between SCOPE and PROFILE.

---

# 4. Two-host deployment flows — target UX

Example:

```text
pve1 = collector / hdd/backups
pve2 = source / rpool/data
```

## R1 — establish WHAT first

Collector starts the relationship:

```bash
# pve1
./zfs-backup.sh add-client pve2 --host=192.168.28.8
```

Source accepts package and proposes WHAT:

```bash
# pve2
./zfs-backup.sh --join=/root/wsad.tgz
```

Source-side draft is reviewed, for example:

```text
rpool/data
  parent=no
  descendants=yes
```

Then source reruns the SAME high-level join boundary to validate/show/commit the exact grant delta:

```bash
./zfs-backup.sh --join=/root/wsad.tgz
```

At this point pve2 has authorized WHAT. It has not selected HOW.

## R2 — bind HOW on collector

For ordinary flat policy:

```bash
# pve1
./zfs-backup.sh add-client pve2 \
    --host=192.168.28.8 \
    --source=rpool/data \
    --profile=standard-flat
```

Expected checks:

```text
requested source is inside committed source scope: YES
profile/scope compatibility: flat + parent=no = YES
profile digest pinned
capability plan: no remote quiesce required
compose effective CONFIG v4
preview
seed over current --host
verify
cron/read-back
ACTIVE
```

## R3 — remote `daily-consistent-flat`

```bash
# pve1
./zfs-backup.sh add-client pve2 \
    --host=192.168.28.8 \
    --source=rpool/data \
    --profile=daily-consistent-flat
```

Now the profile introduces a capability requirement on the SOURCE host:

```text
pve2 must authorize the paired account to quiesce guests under the already-granted source scope.
```

The collector must not silently grant this. Freezing is source-host authority.

Target UX question for Claude: what is the smallest high-level continuation that preserves the existing source-side authorization boundary without exposing raw deploy verbs?

Candidate behavior:

```text
collector reports: SOURCE AUTHORIZATION REQUIRED
package/state carries requested capability, not authority

pve2:
  ./zfs-backup.sh --join=/root/wsad.tgz

program shows:
  existing scope grants: unchanged
  NEW capability requested by selected profile:
      quiesce guests under rpool/data
  exact helper/sudo/whitelist effect
  confirm locally

then collector reruns same add-client command and resumes.
```

The profile can REQUIRE a capability; it cannot GRANT itself the capability.

---

# 5. Profile lifecycle scenarios

## C1 — profile file changed after activation

Persisting only:

```text
profile=standard-flat
```

is insufficient. A software update or local profile edit can change that name's contents.

Required direction:

```text
binding:
  profile_name = standard-flat
  accepted_profile_digest = <digest>
```

On next compose:

```text
PROFILE DRIFT
old accepted digest != current digest

show semantic delta
require adoption
```

No silent new policy merely because the directory kept the same name.

Claude: decide whether profile digest alone is enough, or whether an additional digest of effective composed policy is needed to distinguish profile-content drift from relationship facts/stable scheduler materialization.

## C2 — classify profile changes before applying

Examples:

```text
monitor_warn 90m -> 120m
    SAFE_REGENERATE candidate

quiesce no -> auto
    CAPABILITY_CHANGE

prefix automated_hourly_ -> prod_hourly_
    RETENTION / SNAPSHOT-NAMESPACE MIGRATION

recursive flat -> atomic
    TRANSFER_TOPOLOGY_CHANGE; may require migration/reseed/refusal
```

A generic `profile changed -> regenerate cron` path is not sufficient.

Claude: propose the minimum useful classification for v1, with fail-closed behavior for classes not yet safely automated.

---

# 6. Dynamic descendants + quiesce capability

This must be tested explicitly because flat/atomic scope can include descendants created AFTER enrolment.

Example:

```text
day 1:
  source root rpool/data
  delegated account
  profile daily-consistent-flat
  VM 100 / VM 101 exist

day 7:
  admin creates VM 103 under rpool/data
```

Questions:

1. Does the existing quiesce whitelist on parent `rpool/data` automatically authorize VM 103 because the helper checks dataset ancestry, or was the whitelist materialized to existing guests/datasets only?
2. If source grant scope includes the parent but quiesce capability does not dynamically cover the new descendant, should the new job refuse only VM 103 or the whole quiesced tier? Current consistency contract suggests fail the tier rather than silently degrade.
3. If source grant itself is per-dataset rather than parent, the new descendant is outside grant. Existing owner rule already says surface/refuse, never silently expand.
4. What does `--reconcile`/high-level status need to show so the operator sees "selected by profile/scope but blocked by grant/capability" before the nightly run?

Answer from exact current helper/grant code, not assumption.

---

# 7. Retention separation challenge

For P2 (`daily-consistent-flat`) provide the smallest native CONFIG v4 representation that guarantees all of these simultaneously:

```text
A. hourly snapshots are created without quiesce
B. daily snapshots are separately created with quiesce
C. hourly retention cannot delete/claim daily_q snapshots
D. D/W/M GFS cannot choose an hourly non-quiesced snapshot as a survivor
E. monitor can detect "hourly healthy but daily-consistent stale"
F. no duplicate prune race on the same (scope,pattern)
G. manual CONFIG v4 can express the same semantics without profile-only magic
```

If current CONFIG v4 cannot represent it cleanly, say so and identify the smallest native schema change. Do NOT patch the profile layer around a native representation gap.

---

# 8. Internal profile field scopes

Challenge A1 from the pre-mortem must be answered concretely.

Current native CONFIG precedence `dataset -> template -> defaults` is correct for expert manual configs. It is too permissive for reusable profile fragments if `dataset.inc` can silently override all tiers.

Reviewer proposal for profile boundary:

```text
templates.conf owns tier policy:
  send_schedule
  prune_schedule
  prefix/pattern
  keep/retain
  monitor_*
  quiesce
  autotune
  notification wording/tier label where allowed

dataset.inc owns source-wide composition:
  use_template
  recursive

prune.inc owns retention composition:
  use_template
  gfs
  gfs_pattern
  only additional prune-scope fields justified explicitly
```

Claude: challenge this list against `gen-cron.sh` and real configs. Identify any legitimate reusable field that would be lost, and any field above that is still in the wrong scope.

---

# 9. Overlap / scheduling challenge inside one relationship

If P2 has:

```text
hourly send at 00:01
daily_q send at 00:01
```

and production uses a relationship-wide transfer lock, one tier can repeatedly SKIP the other.

Stable staggering must therefore solve BOTH:

1. different relationships choosing the same profile;
2. different CREATE tiers inside one relationship.

Claude: confirm whether current/frozen lock behavior makes this a real conflict and propose the smallest high-level slot materialization rule. Do not build a scheduler daemon.

---

# 10. Restore provenance challenge

Stage 6 needs to distinguish at least:

```text
hourly crash-consistent
vs
daily quiesced
```

A snapshot prefix is not necessarily durable proof if profile semantics later change under the same profile name.

Claude: determine the minimum provenance needed now so a future restore planner can truthfully label a restore point's consistency/tier without modifying frozen engines speculatively.

Candidate sources to evaluate:

- pinned profile digest/history;
- accepted effective policy digest/history;
- snapshot prefix as lookup key only;
- existing stats/history (likely insufficient because best-effort);
- ZFS user properties only if evidence proves they are worth engine blast radius.

Prefer high-level durable metadata if it is sufficient.

---

# 11. Required Claude response

Create a companion discussion file, suggested:

`docs/discussions/PROFILE-RUNTIME-ARCHITECTURE-CLAUDE-RESPONSE-2026-08-09.md`

Please answer from current code/evidence, not architectural preference alone.

Required sections:

1. agree/disagree with each of P1/P2/P3 as useful discriminating profiles;
2. exact current CONFIG v4 ability to express P2 retention separation;
3. proposed profile-only field-scope restriction;
4. scope/profile compatibility matrix (`no|flat|atomic` x parent include/exclude);
5. profile -> required capability derivation, local root / local delegated / remote root / remote delegated;
6. dynamic descendant behavior under quiesce whitelist and ZFS grants;
7. minimum profile pinning/version-drift contract;
8. minimum profile-change classification;
9. intra-relationship tier scheduling/lock conflict;
10. restore provenance minimum;
11. explicit list: NOW before broad runtime / NEXT / DEFER;
12. identify any premise here that current code disproves.

No Owner escalation unless two technically valid product choices remain after evidence and discussion. Ordinary representation/safety questions should be resolved Claude <-> Reviewer in repo.
