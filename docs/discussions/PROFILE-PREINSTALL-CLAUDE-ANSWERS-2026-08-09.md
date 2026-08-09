# Preset direction — what this deletes, answered from the current code

Answer to `PROFILE-PREINSTALL-NOT-FULL-CONFIG-2026-08-09.md` §11. Narrow, no new
framework. Nothing here changes code yet.

Short version: **this decision deletes more than it constrains, and it also
settles REV-082 F1 in the same direction the reviewer already asked for.**

## §11.1 — what can be deleted from Stage 5 C/D

| planned item | verdict |
|---|---|
| persistent `SOURCE ROOT -> PROFILE` manager | **delete.** Under one-way handoff there is nothing for it to manage. |
| profile-drift detection / adoption workflow | **delete.** It only exists if CONFIG is continuously reconstructed, which §8 forbids. |
| profile versioning, upgrade/re-adopt state machine | **delete.** Upgrading `profiles/default` must not touch an installed CONFIG (§8.1). |
| per-source carve-out / precedence machinery | **delete.** §5 permits refusing overlap instead. |
| custom profile management CLI (Stage 5 D) | **defer indefinitely.** No measured demand: not one production job on any of the four hosts uses a built-in template at all. |
| named preset **selection** at generate time | **keep.** It is the one thing the operator actually does. |
| the namespace from B1 | **keep**, and see §11.7. |

## §11.2 — does anything need `profile_name` persisted after install?

**No. Nothing in the current code reads it back.** `PROFILE_ACTIVE` is a
process-local variable used to render; it is never written to a client record,
the server conf, or the CONFIG. There is no operation today that would answer
differently if it were absent.

The only candidate I can construct is "regenerate the same preset later", and
§8.4 already says that must be an explicit operation with a preview — at which
point the operator names the preset again. So persistence buys nothing.

Recommendation: persist it **only** as provenance, and only if §11.5's marker is
adopted. Not as state.

## §11.3 — can endpoint change / re-activation / added source preserve the installed CONFIG?

**Endpoint change: already does.** `set-endpoint` changes which address the
generated job connects through and touches nothing else — not `PEER_HOST`, not
the label, not the target path, not the pinned key. `--draft-config` is called
once during `seed` and never again. No policy is reconstructed.

**Re-activation: partially, and this is the one real gap.**
`emit_client_sections()` does remove-then-add unconditionally, deliberately, so a
re-run picks up new connection details. That means a manual edit *inside a
managed section* is overwritten today. It is not silent — the activation preview
shows the diff and asks — but it is exactly the §6 failure mode if the operator
clicks through.

**Added source: yes.** Sections are per-dataset and additive; adding one does not
rewrite another.

## §11.4 — smallest mechanism against overwriting a manual edit

**Already present, and it needs extending rather than inventing.** Every
generated section carries, as its first content line:

```
# managed-by: zfs-backup.sh client=<name>
```

`remove_managed_sections()` already refuses to delete a header match that lacks
this marker — a hand-written section is never silently removed. So the ownership
concept exists and is enforced.

The gap is that the marker says *who wrote it*, not *what it was when written*.
An operator editing inside a managed section leaves the marker intact, so
regeneration replaces it.

Smallest fix, in order of cost:

1. **Nothing new** — accept that editing inside a managed section is
   unsupported, and document that manual policy goes in a section **without**
   the marker, which is already protected. This costs zero code and is probably
   correct for V1.
2. If that is too sharp: add a digest of the emitted section to the marker line
   and refuse regeneration when the section no longer matches, naming the file
   and section.

I recommend **1**, per the reduction rule. It uses a mechanism that already
exists, adds no state, and the rule is one sentence: *the tool owns marked
sections; everything else is yours.*

## §11.5 — kill drift workflow, keep provenance?

**Yes.** `generated-from = <name>,<digest>` as an inert comment is defensible
because it answers "where did this come from" during an incident. It must not be
read back by any code path. If it is never read, it cannot create a workflow.

If the reviewer prefers not to have it at all, I will not argue — it is
evidence, not mechanism.

## §11.6 — preset per new source, at the time?

**Yes, and it is strictly simpler.** Asking at generate time needs no persisted
map, no precedence rules and no reconciliation between a stored binding and an
edited CONFIG. It also makes §5's refusal unnecessary in the common case: two
sources generated at different times with different presets simply produce two
sets of sections, and the namespace from B1 already keeps their templates from
colliding.

## §11.7 — what in the architecture challenge becomes unnecessary

Everything whose premise is "the profile keeps owning the config": drift
detection, adoption, version pinning, capability plans as user-visible objects,
and the per-source precedence model.

**What survives, and why it survives is worth stating precisely:** the B1
namespace is *not* part of the persistent-binding design. It exists because two
presets generating into one CONFIG would otherwise emit duplicate
`[template:...]` sections, which `gen-cron.sh` refuses. That is true even in the
one-way model — generate twice, into one file, and the collision is the same. So
it stays, and it costs the operator nothing because nobody selects it.

## §11.8 — Kancelaria stays out of the CLI. Confirmed.

Agreed, and the measurement supports it: the fleet's policies differ in **shape**
(which tiers exist, whether anything prunes at all, recursion, quiesce), not in
tuning — removing every retention and monitor value left the signature count
unchanged at 18. A site that prunes locally faster than its logical history
because a peer holds the longer one is one more shape, and encoding shapes as
profile dimensions is the zoo §4 forbids.

Sufficient instead — native CONFIG v4 already expresses all of it:

- **short local retention, long remote history:** a `[dataset:]` whose own tiers
  retain aggressively, with the receiving side's `[prune:]` scope retaining
  longer. Two independent sections, no new concept.
- **independent hourly/daily retention without GFS:** two templates with their
  own `prune_schedule`/`pattern`/`retain`, which is exactly the pre-GFS shape —
  it is frozen as a *preset*, not removed from the schema.
- **quiesce on selected create tiers only:** `quiesce` on the `[dataset:]`,
  measured live on pve0 and pve1m today.
- **manual prune schedules/patterns:** standalone `[prune:]`, in production on
  pve2m and pve0.
- **validation and preview before install:** `gen-cron.sh -c <file>` renders and
  refuses a bad config without touching anything.

Every example above is a config shape already running on this fleet, so the
documentation can be written from measurement rather than invention.

## Where this meets REV-082 F1 — they agree

F1 says the runtime cherry-picks `use_template`/`gfs`/`gfs_pattern` out of a
fragment it validated generically, so any other valid profile field validates and
is then silently dropped.

Under this owner decision that is not merely a defect, it is the wrong shape
twice over: a hand-maintained key map is **more** machinery than copying the
fragment, and every future native field would need another edit in
`zfs-backup.sh` although `gen-cron.sh` already owns its semantics.

So the fix and the reduction rule point the same way — **compose the rendered
fragment, do not translate it** — and I intend to implement F1 that way unless
the reviewer disagrees.

I am not implementing it in this document.
