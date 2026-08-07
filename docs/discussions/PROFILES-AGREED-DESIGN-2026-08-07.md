# Profile system — agreed design after Claude + Reviewer discussion

Date: 2026-08-07

Status: **AGREED DESIGN — implementation not started**

Sources:
- `PROFILES-NATIVE-FRAGMENTS-PLAN-2026-08-07.md` — Reviewer proposal + Owner clarifications
- `PROFILES-CLAUDE-ANSWERS-2026-08-07.md` — Implementer response

This file records the technical consensus. No Owner decision remains pending for this design.

---

## 1. Core rule: no new profile language and no profile compiler

A profile is an optional directory of **native CONFIG v4 fragments**. The fragment text uses fields already understood by `gen-cron.sh`; `zfs-backup.sh` may copy or reject it, but must not translate, rename or silently adjust it.

If a fragment would need semantic rewriting, that is a design smell: refuse or extend the underlying native CONFIG v4 contract first. Do not create a mapping layer.

`gen-cron.sh` remains the only renderer and final schema authority.

---

## 2. Profiles are optional convenience presets

Two first-class paths remain supported:

```text
profile path:
relationship facts + native profile fragments -> CONFIG v4 -> gen-cron -> engines

manual path:
administrator-authored CONFIG v4             -> gen-cron -> engines
```

The manual path is not legacy/debug/escape mode. An administrator may use no profile at all.

No fake `PROFILE=manual` object is required unless a later concrete implementation need proves otherwise.

No engine capability may exist only through a profile. Capability first belongs to CLI/config; a profile may package it afterward.

---

## 3. What a profile owns

Reusable policy only, using native CONFIG v4 fields, for example:

- template schedules and snapshot prefixes;
- GFS / flat retention policy;
- retain/keep ladder;
- dataset recursion `recursive=no|flat|atomic`;
- quiesce policy where valid;
- monitor thresholds/schedules;
- other future stable policy fields already native to CONFIG v4.

A profile may influence inline prune and monitoring through `[dataset:] recursive`, but only inside that dataset section's own path. It does **not** gain authority to widen an independent `[prune:]` scope.

---

## 4. What a profile does NOT own

### Relationship-owned

- client/relation identity;
- mode `backup|sync`;
- endpoint;
- source account;
- source/local target mapping;
- bandwidth and connection material;
- pair label;
- concrete dataset paths;
- selected profile name, when profile management is used.

`backup|sync` is explicitly **not** part of a profile. Changing a profile must be safe policy replacement; changing mode changes data direction / namespace and therefore relation topology.

### Deploy/scope-owned

- SSH keys / host trust;
- delegated account;
- `zfs allow` grants;
- committed scope/grant.

There is no profile row for `deploy.sh`. A profile must never widen peer permissions.

---

## 5. Native profile shape

Working shape:

```text
profiles/NAME/
    templates.conf       # literal CONFIG v4 [template:*] sections
    dataset.inc          # CONFIG v4 fields to copy into generated [dataset:*]
    prune.inc            # CONFIG v4 policy fields to copy into generated [prune:*]
```

Custom local profiles use the same shape in the agreed untracked local location, e.g. `profiles.local/NAME/`.

No JSON schema, no `[profile]` DSL, no raw shell command lines and no argv compiler.

An optional `scope.ini` may be considered later, but only using the existing `lib-scope.sh` grammar and never as an alternate grant authority.

---

## 6. Fragment validation without a second schema

Do not hand-maintain a duplicate allow-list.

For `dataset.inc` / `prune.inc`:

1. only `field = value` lines; no section headers;
2. allowed fields are derived from `gen-cron.sh --dump-fields` for the relevant section type;
3. subtract an explicit small ownership blacklist for relation-owned fields such as `src`, `dst`, `flags`, `pair_label`, `notify`;
4. candidate full CONFIG v4 is still validated by the real `gen-cron.sh` before any mutation.

Never `source` or `eval` profile files.

---

## 7. Prune topology remains orchestration-owned

Current safe topology must be preserved:

- backup mode can own one namespaced parent and one recursive GFS prune scope;
- sync mode may land datasets at separate top-level paths, so it uses separate non-recursive prune sections per selected dataset.

A profile supplies retention/GFS policy but cannot widen the concrete prune boundary. This avoids recreating the known leaf-vs-recursive-parent prune race and, worse, allowing it across relations.

---

## 8. Manual CONFIG and generated CONFIG may coexist only with explicit ownership

`zfs-backup.sh` is not the exclusive owner of the canonical CONFIG v4 file.

Generated sections require explicit ownership markers using the already-agreed config-ownership mechanism. The tool may rewrite only sections it can prove it owns. A colliding hand-written section must fail closed rather than be silently replaced.

This is required before profile-managed and manual operation can safely coexist.

---

## 9. Preview / canonical Source path rule

No persistent intermediate config is required.

The candidate may live in a temporary file for validation and preview. The installed cron block, however, must never record that temporary file in its `# Source:` line.

Agreed mechanism reuses the current `zfs-backup.sh` transactional pattern:

1. build candidate in temp;
2. validate candidate with `gen-cron.sh -c TEMP`;
3. preview exact config diff;
4. preview cron diff while normalising only the `# Source:` path for comparison;
5. after explicit acceptance, atomically replace the **canonical** CONFIG v4 path with the validated candidate;
6. run `gen-cron.sh -c CANONICAL --install` from that canonical path;
7. retain existing config+crontab rollback if install fails.

Therefore no new `gen-cron` option or alternate Source override is needed.

---

## 10. Required baseline before extraction

Before removing today's hardcoded standard profile, capture generated evidence for both relation shapes:

- backup;
- sync.

For each shape capture:

- effective CONFIG v4;
- rendered managed cron block.

Control comes first: prove the pre-change generator reproduces the baseline / installed state before using the baseline to claim post-change byte identity.

The comparison must have a negative control demonstrating that changing retention/GFS/recursion is detected.

---

## 11. Implementation order

### Slice A — contract + fixtures, no runtime change

Create `profiles/default/` representing today's policy exactly and tests for field ownership / validation. No production path consumes it yet.

### Slice B1 — extract hardcode for backup mode

Make the backup-shaped generation consume `profiles/default/` with byte-identical effective CONFIG v4 and cron output.

### Slice B2 — extract hardcode for sync mode

Do the same separately for the sync topology. Splitting B1/B2 limits blast radius and makes each byte-identity proof independent.

### Slice C — named profile selection + persistence

Add optional `--profile NAME`, omitted => `default` on the profile-managed path. Persist profile identity only for relationships using profile management. Regeneration/endpoints preserve it. Profile change is explicit and previewed.

### Slice D — custom local profiles

Same native-fragment shape from an untracked local directory. Invalid fields / ownership violations fail before any canonical config change.

### Slice E — small useful built-in set

Only after A-D are proven, add a deliberately small coherent set such as standard GFS, flat retention and recursive variants. Do not generate a Cartesian product merely because the engine can express it.

### Slice F — optional selector integration, only if still useful

If needed, reuse native `scope.ini` grammar. Desired selector may request/narrow scope; any request outside the committed grant is a named refusal, never silent clipping and never automatic grant widening.

---

## 12. WebGUI horizon

The product remains **batch/CLI-first**.

Future layering:

```text
WebGUI
  -> high-level CLI / plan / preview / status
  -> CONFIG v4 + scope/grant contracts
  -> gen-cron
  -> snapget / snapsend / delsnaps / monitoring
  -> ZFS
```

The WebGUI is a client of completed public contracts, not a second implementation of backup logic.

Do not add `--json` or HTTP APIs merely in anticipation of GUI. Preserve stable identifiers and plan/preview-vs-mutation separation now; design machine-readable output when a real GUI consumer exists and its required schema is known.

---

## 13. Consensus / Owner routing

Claude and Reviewer agree on the design above.

No remaining item requires Owner arbitration. Remaining questions are implementation details to be proven by tests and repository evidence.
