# REV-20260806-051 — pair gate must reject dot-segment labels

**Reviewed head:** `4fecbc2b371e4125efd6c5aba42bdf13026d8d90`  
**Scope:** hard-disable package steps 2–4, including gate installation, orchestration, REV-049 and REV-050 follow-ups  
**Response path:** `docs/internal/reviews/responses/REV-20260806-051.md`

## Verdict

**CHANGES REQUIRED.** Steps 2–4 are otherwise coherent and the evidence is strong, but the gate’s identity validator still accepts the special path components `.` and `..`. Because the label is then appended directly to `RELATIONSHIPS_DIR`, `..` can resolve to an existing parent directory and bypass the intended `PAIR_UNKNOWN` failure.

REV-049 and REV-050 are accepted as correctly implemented; this is a separate finding in the gate’s own fail-closed identity boundary.

## What was accepted

- **REV-049 CLOSED:** `write_gated_key_line()` now fails before rename when ownership cannot be determined or restored, preserving the original `authorized_keys` byte-for-byte.
- **REV-050 CLOSED:** `gate_state_dir_ok()` now checks the actual group permission digit rather than matching any `7` in the rendered mode.
- Hard-disable ordering is correct: disable establishes local pause before peer state, enable clears and verifies peer state before lifting local pause.
- The full live campaign demonstrates the core enforcement property: a hand-written transfer omitting `-L` is refused at the peer, while a second relationship remains unaffected.
- The ADR wording now accurately describes this as a peer-side enforcement gate with self-enable by the relationship key, not a security boundary against deliberate key use.

## F1 / P1 — `.` and `..` are valid under the current character-only check

Current gate validation rejects only characters outside `[A-Za-z0-9._-]`:

```sh
case "$LABEL" in
    *[!A-Za-z0-9._-]*) ... ;;
esac

STATE_DIR="$RELATIONSHIPS_DIR/$LABEL"
if [ ! -d "$STATE_DIR" ]; then
    ... PAIR_UNKNOWN ...
fi
```

That means both `.` and `..` pass validation.

For `LABEL=..`, with the normal root `/var/lib/zfs-snapshot-all/relationships`, the computed state directory is:

```text
/var/lib/zfs-snapshot-all/relationships/..
```

which resolves to `/var/lib/zfs-snapshot-all` and normally exists. The unknown-relationship guard therefore succeeds for an identity that is not a relationship. If no `disabled` file happens to exist in that parent, the gate enters ACTIVE mode and executes `SSH_ORIGINAL_COMMAND`.

The installation side has the same shape:

```sh
mkdir -p "$PAIR_GATE_STATE_DIR/$label"
want="command=\"$PAIR_GATE_PATH $label\",restrict $pub"
```

so it does not independently prevent such a forced-command line. The current test covers `../alpha`, which is rejected because of `/`, but does not cover the slash-free special components `.` and `..`.

### Impact

This breaks the gate’s stated contract that malformed or unknown key-bound identities fail closed before any caller-controlled command runs. The normal enrolment flow may not intentionally generate `..`, but this boundary must also survive a stale, manually edited, migrated, or otherwise malformed `authorized_keys` line. A single special component must not turn a misconfiguration into an ACTIVE pass-through.

### Required correction

Use one strict relationship-label validator in both the gate and installer. At minimum it must:

- reject empty labels;
- reject `.` and `..` explicitly;
- reject `/` and every character outside the existing allowed set;
- preserve all currently valid real labels;
- run before any path is constructed or any forced-command line is rendered.

A stronger option is to centralize the exact grammar already used for client/relationship identities, but do not source a mutable library from the forced-command gate unless that dependency is itself part of the deployment and rollback contract.

### Required tests

Add deterministic regressions proving:

1. `LABEL=.` returns `PAIR_GATE_MISUSE/91`, and the requested command does not run;
2. `LABEL=..` returns `PAIR_GATE_MISUSE/91`, even though the parent directory exists, and the requested command does not run;
3. `write_gated_key_line` / `install_pair_gate` refuses both labels without changing `authorized_keys` or creating/changing the parent state directory;
4. ordinary dotted labels such as `site.a` remain accepted;
5. negative control: the `..` execution case fails against reviewed head `4fecbc2`.

Run `pairgate`, the join-related graph-selected suites, and `impact.sh --verify`. A new full two-host campaign is not required for this parser-only correction unless the fix changes the installation or forced-command shape beyond label validation.

## Closure state

- REV-049: **CLOSED**
- REV-050: **CLOSED**
- hard-disable steps 2–4: **IMPLEMENTED, closure blocked only by F1 above**
- orchestration may remain in the tree, but the package must not be declared fully closed until the gate and installer reject dot-segment identities.
