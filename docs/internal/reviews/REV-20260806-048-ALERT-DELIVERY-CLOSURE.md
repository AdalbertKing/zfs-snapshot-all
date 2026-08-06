# REV-20260806-048 — Closure of REV-20260806-046

## Verdict

**ACCEPTED — REV-046 F1/F2/F3 CLOSED.**

Reviewed range: `99f750c8..6e8607ac`.

Implementation commits:

- `c668b51` — unreadable/failed/garbage queue inspection fails closed;
- `b4de04a` — an empty queue is reported as prerequisites-ready but delivery-unverified;
- `d859af5` — active test-mail probe checks submission status and bounds a drained queue to local-MTA departure only;
- `6e8607a` — response, regression evidence, live evidence, and PROJECT_STATUS corrections.

## Independent code review

### F1 — empty queue false health

Closed. `alert_delivery_verdict()` no longer says that an empty queue proves the host can send. The success branch now states exactly what was observed: an MTA is present, no mail is queued, and actual delivery was not verified in that run. Return code 0 is retained for a passive prerequisites-ready state, while the wording prevents it from being used as proof of delivery.

The regression suite pins both sides of the contract: the output must not contain `can send`, and it must explicitly contain `UNVERIFIED`.

### F2 — unreadable queue returned clean

Closed. The reviewed implementation handles all three fail-open shapes:

1. no supported queue reader;
2. `postqueue` itself exits non-zero;
3. queue output is non-numeric.

`mail_queue_depth()` emits no synthetic zero after a failed `postqueue`, and `alert_delivery_verdict()` treats empty or non-numeric depth as `UNVERIFIED`, calls `warn()`, increments `PROBLEMS`, and returns non-zero. Therefore `--check-only` cannot end `audit clean` when the queue could not be inspected.

The use of `return 0` inside `mail_queue_depth()` after failed `postqueue` is acceptable here because the function's documented data contract is output-based: no output means unknown, and the caller explicitly fails closed on that state.

### F3 — local queue drain overstated as delivery

Closed. `alert_delivery_probe()` now:

- checks `mail(1)` exit status;
- reports a still-queued message as failure;
- reports an unreadable queue as no dispatch verdict;
- reports a drained queue only as `LEFT THIS MTA`, explicitly stating that recipient delivery is not independently verified.

No end-to-end delivery claim remains in the code path. The result is deliberately conservative where evidence is ambiguous.

## Evidence review

The new `test/alertmail/run.sh` suite covers 18 cases and is registered in `test/deps.conf` for every `deploy.sh` change. The tests include negative controls against the reviewed base for F1 and F2, not only green runs on HEAD.

Reported impact-graph results:

- alertmail 18/18;
- draftscope 26/26;
- join 82/82;
- joinmanifest 10/10;
- joinremote 8/8;
- pause 74/74;
- quiescehelper 119/119;
- selfupdate 28/28, with 7 standing environment skips;
- impact 21/21, including graph verification.

Live evidence on metropolis pve2 is consistent with the implementation: passive audit made no delivery claim; explicit test-mail observed the local queue drain; independent mail-log inspection showed relay acceptance with SMTP 250, while the tool itself stayed bounded to the weaker `LEFT THIS MTA` statement.

## Regressions and remaining risk

No new release-blocking regression identified in `99f750c8..6e8607ac`.

Residual limitations are correctly represented rather than hidden:

- passive audit cannot prove an unused route works;
- queue tools are trusted when they return successful numeric output;
- local queue drain is not end-to-end recipient acknowledgement;
- the three-second observation window is only a local dispatch signal.

These are operational limits, not unresolved defects, because the current messages and exit behavior no longer claim stronger evidence than the tool possesses.

## Active work after closure

REV-046 is closed. The separate pair-scoped pause/hard-disable design from REV-045 remains open; no response file exists yet at:

`docs/internal/reviews/responses/REV-20260804-045.md`

Next required step: implement or formally respond to REV-045, with particular attention to proving that peer-side hard disable blocks manual `snapget.sh` / `snapsend.sh` attempts that omit any local pair label, while leaving unrelated pairs operational.

No production code was modified by this review.
