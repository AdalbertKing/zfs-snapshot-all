# REV-20260806-046 — Alert-delivery verdict infers health from missing evidence

## Verdict

**CHANGES REQUIRED — P1 operational observability regression**

Commit reviewed: `a567328d272de1753763b0c7dc13a4904045a763` (`deploy.sh: give alert delivery a verdict of its own`).

The new audit is directionally valuable, but its healthy verdict is not supported by the evidence it measures. It can report a host as able to send alerts when no delivery attempt was made, and it returns success when queue state is unreadable despite the function contract saying the opposite. This recreates the exact fail-open observability class the change intends to remove.

## F1 — Empty queue is not proof that the host can send

### Evidence

`alert_delivery_verdict()` runs in every mode, including `--check-only`, before any test message is sent. Its healthy branch is:

```bash
if [ "$q" -gt 0 ] 2>/dev/null; then
    ...
fi
log "  alert delivery: $(mta_name) present, queue empty -- this host can send"
return 0
```

An empty queue proves only that no message is currently queued. It does **not** prove successful routing, DNS/MX resolution, relay authentication, sender acceptance, recipient acceptance, or even that this host has attempted a delivery since its configuration changed.

Concrete counterexample:

1. postfix/sendmail and `mail` are installed;
2. queue is empty;
3. outbound TCP/25 is blocked, relay credentials are invalid, or routing is otherwise broken;
4. run `deploy.sh --check-only` before any message is submitted;
5. current code prints `queue empty -- this host can send` and returns healthy.

That is a confident positive verdict derived from absence of queued work, not from a successful delivery observation.

### Required correction

The passive audit must use evidence-accurate language and state:

- no mail client / no MTA: **FAIL**;
- queue depth unreadable: **UNVERIFIED** and non-zero audit result;
- queue non-empty: **FAIL/DEGRADED**;
- queue empty but no fresh delivery probe in this run: **READY/NO QUEUED MAIL, DELIVERY UNVERIFIED**, not `can send`;
- only a fresh probe with a verified dispatch outcome may produce a positive dispatch verdict.

If `--check-only` must remain side-effect free, it cannot claim successful delivery. It may report prerequisites and queue health only.

## F2 — Unreadable queue returns success contrary to the function contract

### Evidence

The comment immediately above the function states:

```text
Returns non-zero when this host cannot be shown to deliver
```

But the unreadable-queue branch does this:

```bash
if [ -z "$q" ]; then
    log "... queue depth not readable here, so dispatch is unverified"
    return 0
fi
```

The message correctly says **unverified**, but the return status and resulting `--check-only` health result say success. Because `warn()` increments the global `PROBLEMS` counter and this branch calls only `log()`, the host can still end with `audit clean` despite the audit being unable to inspect the mail queue.

This is especially relevant for an MTA that provides `sendmail(8)` but is neither postfix nor exim4: `mail_queue_depth()` deliberately emits nothing, so every such host is unverified yet passes the audit.

### Required correction

Unreadable/unsupported queue state must contribute a non-clean audit result, unless the implementation introduces a separate explicit `UNVERIFIED` aggregate status that cannot be mistaken for `audit clean`.

Do not merely change wording; align the return code/global problem accounting with the stated contract.

## F3 — The post-send queue check is not sufficient for a strong delivery claim

After a test message, `_q_after == 0` currently produces:

```text
queue empty after the send -- the MTA accepted and dispatched it
```

This is a defensible **dispatch-from-local-queue** statement, but not proof of recipient delivery. Preserve that distinction in code and documentation. A local MTA may hand the message to a smarthost that later bounces it, or may generate a bounce after the three-second observation window.

The acceptable positive statement is bounded, for example:

```text
local queue empty after submission; message left this MTA, recipient delivery not independently verified
```

Do not state or imply end-to-end delivery unless the project adds a separate external acknowledgement mechanism.

## Acceptance criteria

1. `deploy.sh --check-only` with an installed MTA and an empty queue does not print `this host can send` or any equivalent positive delivery claim.
2. Unsupported or unreadable queue inspection cannot end as `audit clean`; it produces a non-zero/problem verdict or an explicit aggregate `UNVERIFIED` state treated as non-clean.
3. Missing `mail` and missing MTA remain hard failures.
4. Non-empty queue remains a hard/degraded finding.
5. A fresh test submission distinguishes:
   - submission failure;
   - queue still non-empty;
   - local queue drained;
   - unsupported/unreadable queue.
6. Queue drained is documented as local dispatch evidence only, not proof of recipient delivery.
7. Tests include the concrete false-positive case: empty queue + no fresh send + broken/unproven outbound path must not be healthy.
8. Tests include an MTA exposing `sendmail(8)` but neither `postqueue` nor `exim4`; result must be unverified/non-clean.
9. Tests prove the function return/status and global `PROBLEMS` accounting agree with the emitted verdict.
10. Re-run the impact-required deploy suites and record exact counts.
11. Update `docs/PROJECT_STATUS.md` so the current `audit clean` claim is not used as proof of mail delivery until this finding is closed.

## Suggested tests

### Stubbed automated tests

- `mail` missing → hard failure and `PROBLEMS` increments.
- `mail` present, no sendmail provider → hard failure.
- postfix present, queue depth `3` → hard failure.
- postfix present, queue depth `0`, no probe → `UNVERIFIED/READY`, not healthy.
- sendmail provider present, queue command unsupported → non-clean unverified.
- queue command exits non-zero → non-clean unverified.
- malformed/non-numeric queue output → fail closed, no arithmetic error hidden as success.
- test submission returns non-zero → failure even if queue later appears empty.
- test submission succeeds, queue remains >0 → failure/deferred.
- test submission succeeds, queue drains → bounded `local dispatch observed`, not end-to-end delivery.

### Live evidence

On at least one real postfix host:

1. record queue baseline;
2. run passive `--check-only` and confirm it makes no positive delivery claim;
3. run explicit test-mail mode;
4. capture mail command status, queue before/after, and relevant mail-log delivery line;
5. show the final wording stays within what those observations prove.

A deliberately blocked or invalid relay test may be performed only on disposable/lab configuration; do not risk production alert routing merely to satisfy this review.

## Scope boundary

Do not configure postfix, relay credentials, DNS, firewall, or production mail routing as part of this finding. The required change is the correctness of the verdict and its audit status, not host-wide mail configuration.

## Response path

Implementer response:

```text
docs/internal/reviews/responses/REV-20260806-046.md
```
