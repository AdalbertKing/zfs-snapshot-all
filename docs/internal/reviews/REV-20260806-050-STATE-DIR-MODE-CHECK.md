# REV-20260806-050 — state-directory mode check accepts non-writable groups

**Status:** CHANGES REQUIRED  
**Scope:** hard-disable campaign, `install_pair_gate()` verification added in `8f6f8c2`  
**Response path:** `docs/internal/reviews/responses/REV-20260806-050.md`

## Finding F1 — group-write test examines the whole mode string

The new verification obtains a numeric mode and then checks:

```sh
case "${st%% *}" in
    *7*|*6*|*3*|*2*) : ;;   # group write present
    *) st="" ;;
esac
```

This does not inspect the group permission digit. It accepts any mode containing `7`, `6`, `3`, or `2` anywhere.

For example, mode `0755` is rendered by GNU `stat -c %a` as `755`. The pattern `*7*` matches the **owner** digit, even though the group digit is `5` and the directory is not group-writable. Modes such as `1755` and `2755` are likewise accepted for the wrong reason.

Consequently, if `chown` establishes the expected group but `chmod 0775` fails or does not take, enrolment can again finish without the warning while remote `PAIR-CONTROL enable` remains unable to remove the marker. This is the same degraded operational state the verification was intended to detect.

## Required correction

1. Extract and evaluate the actual group permission digit, not the complete mode string. Accept only group digits `2`, `3`, `6`, or `7`.
2. Add deterministic tests covering at least:
   - expected group + `775` => accepted;
   - expected group + `755` => warning;
   - expected group + `2755` or `1755` => warning;
   - wrong group + writable mode => warning;
   - `stat` failure => warning.
3. Provide a negative control showing that the non-writable-group case passes incorrectly against `8f6f8c2` and fails after the correction.
4. Re-run the directly affected gate/join suites. A destructive live rerun is not required solely for this parser correction unless the tests expose another ambiguity.

## Campaign disposition

The full live campaign supplies strong evidence for enforcement, ordering, relationship isolation, persistence, retry convergence and teardown. This finding does not invalidate those observed results. It blocks final acceptance of the enrolment health check because the newly claimed verification is not yet logically sound.

**Verdict:** `CHANGES REQUIRED` before closing hard-disable step 4.
