# Post-Stage-2 integrated live campaign

Date: 2026-08-07

Status: **OWNER GATE — REQUIRED AFTER CURRENT STAGE 2 CLOSES, BEFORE ENGINE FREEZE / PROFILE B1**

## 1. Why this gate exists

The last two days changed several pieces that meet in the same real execution path:

- relationship logical pause (`-L`, pair_label, pause/resume, monitoring behaviour);
- peer-side hard disable and enable orchestration;
- CONFIG v4 recursion model `recursive = no|flat|atomic`, including transfer + prune + monitor propagation;
- Stage 2 engine finalisation now in progress (run suffix once per run, recursion option normalisation, long semantic options, and any other engine-finalisation item accepted into the same package).

The repository already contains strong targeted tests and substantial live evidence for pause/hard-disable. The concern is not that nothing was tested. The concern is that the **final combined engine/config state has not yet been exercised once as one integrated package after Stage 2 is complete**.

This file therefore does NOT order a full campaign after every intermediate commit. It follows `docs/project/TEST-CAMPAIGN-POLICY.md`: finish the related package, then pay for the expensive integrated campaign once on its final commit.

## 2. What is already proven and must not be needlessly repeated

### Pair logical pause

Already live-verified on two relationships (real peer + throwaway LXC):

- paused relationship skipped before source snapshot/SSH;
- second relationship continued normally;
- monitor reported intentional pause;
- config/crontab stayed byte-identical;
- resume caught up incrementally;
- real defects were found and fixed by that campaign.

Evidence is recorded in `docs/internal/reviews/responses/REV-20260804-045.md` and `docs/PROJECT_STATUS.md`.

### Hard disable

Already live-verified end-to-end, including the property logical pause cannot provide: a manually written transfer omitting `-L` was refused by the peer while the relationship was disabled. The campaign used two real relationships and found/fixed several deployment, ownership and diagnostic defects.

Evidence is recorded in `docs/project/HARD-DISABLE-CAMPAIGN-PLAN.md`, the REV-049/050/051/052 chain, and `docs/PROJECT_STATUS.md`.

Therefore the post-Stage-2 campaign needs only a **regression smoke** for pause/hard-disable unless that smoke fails. Do not rerun their whole historical campaigns just for ceremony.

## 3. What is NOT yet fully closed

### Recursive behaviour after the recent config/engine work

The CONFIG v4 recursion migration was performed fleet-wide and generator tests cover `no|flat|atomic`, but that is not the same as a final integrated real-ZFS campaign of the completed Stage-2 tree.

Stage 2.1 itself explicitly records:

> Still owed: one real-ZFS scenario, per docs/design/stage2-engine-contract.md.

That obligation must be discharged on the final Stage-2 package, not forgotten between slices.

## 4. Timing

Do not interrupt Claude in the middle of the current Stage-2 implementation merely to run a broad campaign against an intermediate SHA.

Required order:

1. Finish all accepted Stage-2 implementation slices.
2. Run their targeted/local/negative-control tests as each slice requires.
3. Produce one final Stage-2 candidate SHA.
4. Run the integrated campaign below against **that exact SHA**.
5. Fix any finding and repeat only the affected portions plus the final required regression set.
6. Record exact evidence.
7. Only then declare the low-level engine frozen and proceed to Profile B1/high-level work.

If Stage 2 changes again after the campaign, the reviewer decides whether the changed blast radius requires repeating part or all of this campaign.

## 5. Final-commit automated gate

Against the final Stage-2 candidate:

- run `./test/impact.sh --verify`;
- run every suite selected by the impact graph for the final diff/package;
- run the dedicated Stage-2 suites and their negative controls;
- record counts, skips and failures from the final SHA, never copy counts from earlier intermediate commits.

At minimum this includes the suites owning the changed recursion/run-suffix/CLI/lock behaviour and the existing pause regression selected by the graph.

## 6. Integrated real-ZFS recursion campaign

Use scratch datasets. Do not test destructive semantics on production data.

The campaign should prove **behaviour**, not merely generated argv.

### R1 — `recursive = no`

Given a parent with at least two children:

- run the generated job for the parent in `no` mode;
- prove only the named dataset is handled;
- prove descendants are not silently transferred/pruned/monitored as recursive scope.

### R2 — `recursive = flat`

Start with parent + at least two children.

Prove:

- descendants are discovered at runtime;
- each dataset is handled independently as flat recursion specifies;
- all snapshots belonging to one invocation carry the same logical run suffix after Stage 2.1;
- snapshot creation times may differ and the evidence/report must not call flat a single atomic point in time;
- target topology/data are correct.

Then create a **new child after config generation** and rerun:

- the new child must be discovered without regenerating a frozen child list;
- prune/monitor scope must follow the same recursive policy.

### R3 — `recursive = atomic`

On the same or equivalent scratch tree:

- prove one recursive/atomic transfer semantics for the subtree;
- prove target tree and snapshot/run correlation are correct;
- prove the result is observably distinct from flat where the contract says it is distinct.

### R4 — prune + monitor follow recursion

For flat and atomic generated policies:

- prove recursive prune reaches the intended subtree;
- prove recursive monitor evaluates the intended subtree;
- prove `no` does not widen scope.

The point is to test the whole CONFIG-v4 -> gen-cron -> engine chain, not only engine flags in isolation.

### R5 — manual snapshot ownership

Create a manual technical snapshot such as:

`dataset@przedupdate`

Run the managed recursive retention path and prove the manual snapshot is not deleted merely because it is old or in the same subtree.

### R6 — both transfer directions touched by Stage 2

Because Stage 2.1 changes both `snapsend.sh` and `snapget.sh`, obtain real execution evidence for both directions where the environment permits:

- at least one real `snapsend` scenario;
- at least one real `snapget` scenario.

This need not multiply every recursion case by every host. Choose the smallest topology that discriminates the two code paths.

## 7. Pause/hard-disable regression smoke on the final Stage-2 build

Stage 2 edits the same transfer engines that carry `-L`, so run a compact live regression after the recursion campaign:

### P1 — logical pause

On one labeled scratch relationship:

- pause it;
- execute the exact generated transfer command;
- prove no source snapshot/SSH/target mutation occurs;
- prove `skipped_paused`/operator-visible pause semantics remain correct;
- resume;
- prove the next run transfers normally.

### P2 — hard disable

On one scratch relationship using the installed peer gate:

- disable it;
- prove the normal managed command is refused;
- prove a manual transfer attempt **without `-L`** is still refused by the peer;
- enable it;
- prove normal transfer returns.

If P1/P2 pass, the historical full pause/hard-disable campaigns do not need to be repeated.

If either fails, reopen the relevant campaign scope and test according to the failure, not according to this shortcut.

## 8. Stage-2-specific live obligations

Apply the risk-shaped obligations from `docs/design/stage2-engine-contract.md`:

- Stage 2.1: real ZFS run-suffix/correlation proof — mandatory;
- Stage 2.2: recursion declaration normalisation is argv parsing; targeted tests/negative controls are sufficient unless implementation unexpectedly changes environment-dependent code;
- Stage 2.3: prove the **installed** copy accepts the new long spelling under the delegated execution context where required; do not substitute a local checkout test for deployed-version compatibility.

If the accepted relationship-wide overlap-lock refinement lands in the same engine-finalisation package, include one real or otherwise discriminating overlap case that proves a second job of the same labeled relationship skips rather than streams concurrently. This does not require a new scheduler campaign.

## 9. Evidence format

Record in one closure artifact:

- final commit SHA;
- hosts used;
- scratch datasets/relationships;
- exact commands;
- exit codes;
- before/after snapshot and target state;
- proof that a newly created child was dynamically discovered in recursive mode;
- proof manual snapshot survived managed prune;
- flat vs atomic run/snapshot observations;
- pause and hard-disable smoke results;
- automated suite counts;
- negative-control results where applicable;
- teardown/residue check.

Do not report only `PASS`. The evidence must make it possible for Reviewer to distinguish whether the intended property was actually exercised.

## 10. Exit criterion

The engine/config layer may be called **frozen for the next high-level phase** only when:

1. Stage 2 implementation is complete;
2. automated final-SHA gates are green;
3. the required real-ZFS recursion/run-suffix campaign is green;
4. pause/hard-disable regression smoke is green;
5. any campaign finding is fixed and reverified;
6. the evidence artifact is committed and independently reviewed.

Only after that gate should Profile B1 / high-level collector/profile work proceed.

This is a one-time consolidation checkpoint for the recent low-level changes, not a new rule that every future small change requires a fleet-wide campaign.
