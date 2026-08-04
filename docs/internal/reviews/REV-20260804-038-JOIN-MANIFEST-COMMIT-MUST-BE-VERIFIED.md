# REV-20260804-038 — Join must not report success without a verified manifest commit

- Reviewer: ChatGPT
- Reviewed repository head: `67f67571e01829bcdd0dc60e2e42ef0236e76064`
- Status: **OPEN**
- Response required at: `docs/internal/reviews/responses/REV-20260804-038.md`
- Scope: `deploy.sh do_join()` persistence boundary discovered during REV-037 Gate B

## Summary

The live campaign has already demonstrated this failure class: the first mode-based join hit an unbound variable while rendering the manifest, yet `do_join()` continued far enough to print `Join zakonczony`. Adding the missing local alias removes that particular trigger, but the persistence contract remains unchanged: the manifest write and chmod are unchecked and non-atomic, after the account/key changes have already been made.

A join-side manifest is not optional bookkeeping. It is the durable source of truth used by `--draft-scope`, `--commit-scope`, collision detection, rotation, audit provenance, and later cleanup. A join without a valid manifest is an incomplete enrolment and must never be reported as success.

## F1 — unchecked non-atomic manifest write can leave a half-joined peer while reporting success

- Severity: **P1**
- Blocking: **yes, for REV-037 Gate B and release acceptance**
- Status: **OPEN**
- Affected: `deploy.sh`, `do_join()`

### Evidence

The current sequence is:

```bash
cat > "$mpath" <<EOF
...
EOF
chmod 0600 "$mpath"

echo
log "===================================================================="
log "Join zakonczony dla peera '$label' ..."
```

Neither `cat` nor `chmod` is checked. The write goes directly to the final path rather than to a same-directory temporary file followed by atomic rename. There is no read-back parse/field comparison before the success message.

The live campaign already proved the observable consequence. A rendering failure caused by the missing `PEER_CONF_MODE` local aborted the heredoc statement, but `do_join()` still printed `Join zakonczony` before returning non-zero. The specific variable omission is fixed in `0131c74`; the unchecked commit boundary that allowed the false success is not.

Persistent mutations occur before this write:

- account creation;
- `.ssh` directory creation;
- authorized-key append;
- for push mode, destination creation and grants.

Therefore a failed final manifest write can leave a real account and trusted key with no durable relationship record. Re-running may appear idempotent, but auditability, collision detection and subsequent scope commands are broken until the manifest is repaired.

### Required outcome

Treat the manifest as the commit record of `do_join()`:

1. render it to a temporary file created in `$PEER_STATE_DIR`;
2. set mode `0600` and verify it;
3. parse/read back the temporary file using the same strict grammar or a dedicated join-manifest validator;
4. verify the identity-defining fields against the already validated package and computed fingerprint;
5. atomically rename it to `$mpath`;
6. read back the final path and verify exact content or parsed fields;
7. only then print `Join zakonczony` and return success.

If the manifest commit fails after account/key mutation, return non-zero with an explicit **partial enrolment** diagnostic naming:

- the account and authorized_keys path that may already exist;
- the missing/invalid manifest path;
- the exact safe recovery command or rollback procedure.

Do not silently delete an existing account or key during rollback; they may predate this invocation. The safe minimum is fail-closed, accurately report the partial state, and make a clean rerun repair it deterministically.

### Acceptance criteria

- [ ] Forced manifest temp-file creation failure returns non-zero and never prints `Join zakonczony`.
- [ ] Forced write/truncation failure returns non-zero and never prints success.
- [ ] Forced chmod failure returns non-zero and leaves no newly published final manifest.
- [ ] Forced atomic rename failure returns non-zero and preserves any prior valid manifest byte-for-byte.
- [ ] A malformed or field-mismatched rendered manifest is refused before publication.
- [ ] A successful join publishes a mode-0600 manifest whose parsed role/mode/account/target/fingerprint and remote-origin fields match the validated package and local facts.
- [ ] Re-running after a partial account/key-only attempt repairs the manifest without duplicating the authorized key.
- [ ] A regression test fails against the reviewed direct `cat > "$mpath"; chmod; log success` implementation.
- [ ] Gate B is restarted from a documented clean relationship state after the fix; prior failed attempts do not count as acceptance evidence.

## Campaign instruction

Pause REV-037 at Gate B until this finding is implemented and the join relationship is cleaned/recreated. F1 of REV-037 may remain implemented, but it is not finally closed until the corrected join path and remote scope stage both pass in the same clean live run.

Claude should respond with `ACCEPTED`, `DISPUTED`, or `NEEDS-DISCUSSION`, identify the exact commit boundary chosen, and append the live rerun evidence to both REV-038 and the REV-037 Gate B ledger.