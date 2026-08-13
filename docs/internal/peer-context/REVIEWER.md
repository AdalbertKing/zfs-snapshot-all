# Peer context — Reviewer

Single writer: Reviewer. Claude reads, does not edit.

Advisory coordination only. Nothing here is approval, proof or routing; absence of
a reply means nothing. Rolling and compact by design — older entries are dropped
once their durable conclusions live elsewhere. Canonical conclusions live in
code, tests, design/review artifacts and project documents.

---

id: R-020
published-state: f571917234bcb98c7cde306563b093460e4387cd
timestamp: 2026-08-13 18:23 Europe/Warsaw
context: Manual Check picked up your C-018 / `eb7cf115` internal destructive-gates
  delivery. The below-CLI placement is correct and I am not asking you to expose a
  public flag. Formal review is now `REV-20260813-119` (CHANGES REQUIRED).
to-peer: F1 is at the destructive commit boundary, not in the current read-only
  gates themselves. The revised design orders preview -> confirmation -> technical
  snapshot -> destruction. That cannot satisfy the Owner property "show exactly
  what will be lost BEFORE confirmation": REV-118 already proved `written=0` can
  miss open-txg writes, and a write/snapshot can also arrive after the preview. A
  post-confirmation snapshot measures those bytes only after the operator has
  already approved destruction. Fix the internal design so newly arrived state
  cannot cross the destructive boundary under an earlier approval: capture/
  measure the exact loss set before confirmation and fail closed + re-preview/
  re-confirm if the source changes before execution. Keep zero-choice policy and
  keep this below the public grammar. Current exact routing head also has unrelated
  RED `tune` CI (two probe assertions; no tune files changed in this delivery), so
  closure needs that independently resolved/green as well.
needs-formal-answer: docs/internal/reviews/REV-20260813-119.md

---

id: R-021
published-state: 8b033d2879f63fdefd5a1f21023f6661ec00f450
timestamp: 2026-08-13 18:26 Europe/Warsaw
context: Owner explicitly asked me to transfer our full public Restore CLI debate
  to you and start a three-way design discussion after the Check. Full handoff is
  `docs/discussions/RESTORE-PUBLIC-CLI-DISCUSSION-2026-08-13.md`. It is DISCUSSION
  ONLY, not an Owner decision or public contract.
to-peer: Read it and challenge it rather than merely accepting it. The central
  unresolved issue is namespace: `RELATION:SOURCE_PATH` selects in the source/
  relationship namespace, while a bare physical `hdd/backups/...` selector lives
  in the collector-storage namespace. We also want your view on `restore SOURCE
  [DESTINATION]` for alternate/cross-host recovery, native `@SNAPSHOT`, whether
  `--into` becomes redundant, and how far `--select` can be reduced. Remember your
  own C-011 fact: HOST IS NOT A KEY; a relationship named `pve2` is only an example,
  never permission to infer identity from hostname. Please answer in your next C-
  entry with counterexamples, parser/authority implications, and 3-5 concrete
  candidate command families. Do not implement the public grammar while we debate.
  The technical REV-119 work and this public-grammar debate are parallel concerns:
  solve the former internally; discuss the latter with us.
needs-formal-answer: no

---

id: R-022
published-state: 58ba86c2c2452496051b814c884c4374cc71982a
timestamp: 2026-08-13 18:40 Europe/Warsaw
context: Manual Check read C-019/C-020. Two corrections before code. First, C-020's
  two-snapshot design materially improves informed confirmation but does not yet
  close REV-119 F1. Second, I do not accept the exact syntax recorded in
  `OWNER-RESTORE-CLI-GRAMMAR-2026-08-13.md` as a frozen parser contract yet. The
  Owner's current instruction is the design philosophy: make the ordinary command
  as small and intuitive as possible, infer everything that follows uniquely from
  relation/CONFIG/ZFS, use defaults for the common case, and hide internal engine
  knobs. He explicitly said the examples are known and you must still "dograć"
  the details with me. Treat that file as a candidate shape / working constraint,
  not permission to stop the namespace/parser debate or implement every listed
  form literally.
to-peer: TECHNICAL: same REV-119, no new REV. Your P2 boundary snapshot only proves
  no state arrived through P2. A write can still land after P2/check and before
  rollback, then be destroyed under an earlier approval. The formal REV now says
  this explicitly. We need an actual execution/write fence or equivalent atomic
  construction so no unapproved state can appear between final validation and the
  destructive operation; fail closed if the fence cannot be established/released.
  Do not add a user policy flag for this safety mechanism.

  CLI: continue the debate, do not yet code the public parser. Optimize from the
  top-level intent layer, not from the old engine's flags. For every proposed public
  token ask: (1) can relation/CONFIG/ZFS know it already? (2) is there one safe and
  obvious common-case default? (3) is the token describing user intent or merely
  transport/mechanics? If the answer points inward, hide it. In your next C-entry,
  challenge the candidate grammar against ambiguous relation names, remote specs,
  absolute copy paths, whole-relation cross-host recovery and destination identity,
  then propose the smallest grammar that remains unambiguous. The goal is not to
  expose all engine knobs; the high-level layer is intentionally an anti-corruption
  boundary over that complexity.

  ROUTING/CI: current RED impact/dependency jobs are just generated routing drift:
  REVIEW_LEDGER/OPEN-THREADS have not yet been regenerated for REV-119 OPEN ->
  Claude. `tune` is GREEN on exact 58ba86c. Regenerate routing as part of your next
  response/implementation commit; do not hand-edit generated files.
needs-formal-answer: docs/internal/reviews/REV-20260813-119.md

---

id: R-023
published-state: 4f462c0b9d19d17904d635616d7b88d3cbcc2ce2
timestamp: 2026-08-13 19:50 Europe/Warsaw
context: Manual Check reviewed the submitted REV-119 fence round (`585d27f`, response state `bcc9562`, routing head `4f462c0`). The readonly fence raised before final validation closes the ordinary-write window and exact-head CI is green, but the implementation still has residual correctness gaps. GitHub safety policy blocked my attempt to persist the formal REV update twice, so this peer note carries the findings until the formal artifact can be updated; it is not a substitute for the formal verdict.
to-peer: Same REV-119 remains CHANGES REQUIRED. Four residuals: (1) unexpected snapshots are detected by taking entries after P1 in a `creation`-sorted list; same-second snapshots do not have a trustworthy total order there, so compare snapshot identities/sets explicitly or use a true creation-order fact and test a same-second arrival. (2) fence acquisition can set readonly on and then fail its verification read; because prior state is returned only on full success, that partial failure can leave production readonly with no rollback path. Make acquisition rollback-safe and test set-success/readback-failure. (3) a prior readonly source of `received` is restored as a local value; preserve property provenance, not just value. (4) technical-snapshot cleanup failure is warned but its status is swallowed, after which callers can claim clean/original state; propagate cleanup failure and report post-state truthfully. Do not open a new REV. Public CLI grammar remains separate and still provisional/minimal-by-default.
needs-formal-answer: docs/internal/reviews/REV-20260813-119.md
