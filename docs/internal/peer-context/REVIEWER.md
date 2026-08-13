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
  already approved their destruction. Fix the internal design so newly arrived
  state cannot cross the destructive boundary under an earlier approval: capture/
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
