# REV-20260807-054 — recursion model: one declaration per dataset

**Reviewed head:** `524121817da45f37a1def1e747a4d077b17d753e`  
**Scope:** `docs/design/recursion-model.md`, the current `gen-cron.sh`/`cron2conf.sh` contracts, and the documentation/test changes since REV-053.  
**Verdict:** **APPROVED FOR IMPLEMENTATION**, with the acceptance conditions below. Migration decision: **(a) hard reject** legacy recursion in `[dataset:] flags` once the new field lands.

## Why the design is accepted

The proposal identifies the real defect correctly. Recursion is already expanded at run time by the engines; the inconsistency is at declaration time. A `[dataset:]` section can currently make the transfer recursive by hiding `-r`/`-R` in free-form `flags`, while the inline prune is deliberately non-recursive and the associated monitoring cannot inherit the same decision. That permits the worst operational shape: a new child can be copied successfully while never being pruned or watched.

The proposed field is the right abstraction:

- `recursive = no` -> transfer, prune and monitor operate on the named dataset only;
- `recursive = flat` -> transfer uses the engine's flat recursive mode (`-R`), prune and monitor use `-R`;
- `recursive = atomic` -> transfer uses the engine's atomic recursive mode (`-r`), prune and monitor use `-R`.

Keeping `flat` and `atomic` distinct is necessary. They encode different failure/isolation and consistency guarantees; collapsing them would throw away a real engine capability.

The existing `[prune:] recursive = yes` precedent also supports making recursion a typed field rather than leaving it in free text.

## Migration decision — hard reject

Choose **(a) hard reject**, not a deprecation cycle.

The live survey found one managed config using legacy dataset recursion in `flags` (`pve1`, `rpool/data`, `-r -v 3`) and none using the dangerous `-R` shape. That makes migration bounded and observable. Once `recursive =` exists, continuing to accept `-r`/`-R` in `flags` would preserve two ways to express the same policy and would allow them to disagree — exactly the defect this change is intended to remove.

The generator should therefore refuse regeneration until the one known config is migrated. The migrated pve1 fixture must reproduce the currently installed managed crontab as a set/byte-equivalent output under the repository's existing cron2conf/gen-cron comparison rules.

## Acceptance conditions

1. **One representation only.** `[dataset:] flags` must not be able to smuggle recursion back in after `recursive =` is introduced. The rejection must be equivalent to the engine's `getopts` interpretation, not merely an exact-token check. In particular bundled short options such as `-Rv` / `-rZ` must also be refused if they contain `R` or `r`; otherwise the old split-brain representation survives under a different spelling.

2. **Both transfer directions.** Tests must pin the mapping for both generated `snapsend.sh` and `snapget.sh` lines. `flat` and `atomic` are a dataset policy, not a push-only property.

3. **All three generated surfaces move together.** For each value (`no`, `flat`, `atomic`), assert the transfer line, inline prune line, and monitor line from the same `[dataset:]` declaration. A test that checks only the send flag would miss the exact defect being fixed.

4. **Round-trip is lossless.** `cron2conf.sh` must recover `recursive = flat|atomic` from generated send lines and remove the corresponding engine flag from reconstructed free-form `flags`. Existing separate `[prune:]` jobs must remain representable; do not silently merge or delete them merely because a dataset send is recursive.

5. **Draft UX changes with the contract.** `deploy.sh --draft-config` should emit/comment the typed field rather than prose instructing the operator to put `-R` in `flags`.

6. **No engine campaign required.** This is generator/validator/recovery-tool work. Targeted `cron`, `negative`, `cron2conf`, fixture tests plus `impact.sh --verify` are sufficient unless the implementation unexpectedly touches an engine or a shared runtime abstraction.

## Documentation changes since REV-053

The generated-cron explanations added in `17bb98d`/`58e02c3` are acceptable. Pinning the alert-delivery quote to the real `deploy.sh` healthy-branch text is the correct response to the stale prose found during REV-053; no new finding there.

## Separate operational finding: thread #22

The recursion design does **not** close the live pve0 coverage gap found by the survey. VM 104 `debian` is running with zero `automated_*` snapshots, and three stopped guests are also outside automated coverage. Keep that as a separate owner decision and do not mark it solved by this generator change. It is an operational exposure today, whereas the `flags = -R` inconsistency is currently latent in the fleet.

Implementation may proceed on thread #21 under these conditions. No further design checkpoint is required before coding unless the implementation needs to change the engine semantics described above.
