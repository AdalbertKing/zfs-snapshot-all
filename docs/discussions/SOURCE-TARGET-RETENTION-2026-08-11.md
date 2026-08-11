# Source vs target retention — owner/reviewer design discussion

Status: WORKING AGREEMENT / implementation not authorised by this document alone
Date: 2026-08-11
Related: REV-20260811-102

## Problem

The current default creates managed hourly snapshots but bounds retention only on the backup/store side. That can fill a production source pool. REV-102 treats this as P1 and blocks the Phase 5 transactional installer.

## Owner proposal — accepted as the baseline direction

The preset should initially offer the SAME retention policy on both sides. This is a safe, unsurprising starting proposal: no side is unbounded and the operator does not need to understand a hidden asymmetry before first use.

Crucially, equality exists ONLY at candidate-generation time.

After rendering, CONFIG v4 must contain two independent policies:

- SOURCE retention — controls tool-owned snapshots on the source;
- TARGET/STORE retention — controls the retained history on the backup store.

There must be no runtime linkage, inheritance, `target = source`, profile drift authority, or later automatic re-synchronisation between the two. CONFIG v4 remains runtime truth after acceptance.

For the current default, the simplest starting proposal is to render the same ladder on both sides (currently 24 hourly / 7 daily / 4 weekly / 12 monthly). The exact numbers remain an owner product-policy choice; the architectural requirement is bounded + initially equal + independently editable.

## Editing/acceptance UX

The high-level workflow must make the split visible before installation.

Conceptually the proposal should read like:

    SOURCE retention: 24H / 7D / 4W / 12M
    TARGET retention: 24H / 7D / 4W / 12M

The candidate CONFIG that is offered/opened for editing must contain separate native CONFIG rules for those two policies. An administrator can therefore change only the store, e.g.:

    SOURCE: 24H / 7D / 4W / 12M
    TARGET: 24H / 30D / 12M / 3Y

or, for a space-constrained source:

    SOURCE: 24H / 7D
    TARGET: 24H / 30D / 12M / 3Y

After the edit, the candidate must be revalidated and the FINAL config + cron diff shown before confirmation. A profile is not consulted again after install.

This is deliberately not a new profile dimension. It is one preset producing an editable native CONFIG candidate.

## Control-plane ownership

Collector/pve1 owns the schedule and CONFIG for BOTH retentions.

Remote source pruning must NOT install an autonomous cron on the source. Collector cron reaches the source over the already-established relationship SSH channel and executes the source prune there.

CONFIG v4/gen-cron already has the required primitive: a remote `[prune:<host:dataset>]` scope plus `ssh_flags` generates remote `delsnaps.sh`. Prefer extending composition around that existing primitive over inventing a new retention language or scheduler.

The remote destructive boundary must use the relationship's pinned identity/key and exact accepted/granted scope. No broad root SSH cleanup and no silently widened grants.

## Timing — when this lands

REV-102 is a prerequisite to the Phase 5 transactional installer.

Order:

1. Keep Phase 5 install/commit slice blocked.
2. Correct preset/candidate composition so new CREATE operations contain independent bounded SOURCE + TARGET retention.
3. Wire remote PULL source retention from collector cron through the existing remote prune primitive.
4. Prove local and remote behavior on real ZFS: source ages out, target-only old snapshots survive, manual/foreign snapshots survive, next transfer remains incremental.
5. Resolve the EXISTING-CONFIG migration question below without violating CONFIG-as-runtime-truth.
6. Close REV-102.
7. Resume Phase 5 transactional install (preview/edit -> seed -> atomic CONFIG -> cron install/read-back -> active).

This correction should not be postponed until restore or an optional post-product phase: installing a one-command backup with an unbounded source default would bake a known P1 operational hazard into the product.

## Existing CONFIGs — must not be silently rewritten

Changing the preset fixes NEW CREATE only. Existing installed relationships were handed off from profile to native CONFIG and must remain independent of later profile edits.

Therefore an existing CONFIG that creates `automated_hourly_*` on a source but has no matching bounded source retention needs an explicit, previewed migration/audit path. Ordinary endpoint reactivation must NOT become the migration mechanism.

Open design question for Claude/reviewer: find the smallest mechanism that:

- detects existing managed sources lacking source-retention;
- shows the exact source-prune sections/cron lines that would be added;
- requires explicit operator acceptance;
- does not reconstruct unrelated installed policy from today's profile;
- is idempotent and leaves already-customized source retention untouched.

Avoid a permanent new public workflow verb unless there is no smaller safe migration boundary.

## Incremental-base safety

Source retention must not destroy the transfer chain. The implementation must prove that after source pruning:

- older target-only snapshots remain;
- a valid common base/bookmark survives as required;
- the next transfer remains incremental;
- a long outage/paused relationship has an explicit safe behavior rather than silently deleting the only useful base.

The repository already has per-target bookmark machinery; use/prove it if it provides the needed property rather than adding a second mechanism.

## Questions Claude should answer before implementation is considered complete

1. What exact native CONFIG sections will represent SOURCE and TARGET retention for local PUSH and remote PULL?
2. How will remote prune reuse the existing relationship SSH key, host-key pinning and granted scope?
3. Does the current source-side grant already include exactly the destroy capability needed by remote prune; if not, what is the narrowest grant change?
4. How is the incremental base/bookmark protected across source pruning and a backup outage longer than the source window?
5. What is the smallest explicit migration path for already-installed CONFIGs lacking source retention?
6. How will the Phase 5 candidate be made editable, then revalidated and re-previewed before commit, without introducing another configuration representation?

## Non-goals

- no autonomous source cron;
- no source/target runtime coupling;
- no profile inheritance/composition framework;
- no automatic rewriting of already-installed CONFIG from a changed profile;
- no pruning of manual/foreign snapshot prefixes;
- no implementation of offline rotating target replicas in this slice.
