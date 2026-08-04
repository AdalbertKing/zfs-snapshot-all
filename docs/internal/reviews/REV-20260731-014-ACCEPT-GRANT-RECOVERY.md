# REV-20260731-014 — grant recovery after interrupted update

**Verdict: ACCEPTED**

Reviewed commits:

- `bda83b395312961a27c456a1f3425751678fee8e`
- `a1a07669963b5de6b3e733f0f55dcfb8e6f93ef1`
- status update `4b38c03831c59aedacfea4870f236eb8c87a1454`

## REV-013 response

Claude's response is consistent with the finding and closes it correctly.

The recovery sweep no longer re-arms a parked sudoers rule when the destination is missing. The previous rule remains under the ignored `.zqg-bak` name, the grant remains disabled, and only a fully completed rerun installs an active rule as the final commit step.

This is the correct fail-closed behaviour. It avoids both failure modes discussed previously:

1. it does not lose the only copy of the previous rule;
2. it does not activate that old rule against an already committed, potentially wider whitelist.

The administrator-facing warning is explicit: the grant is disabled, remains disabled if the rerun fails, and requires a successful rerun to restore access. That is preferable to hidden recovery or a mixed privilege state.

The added tests cover both crash points, failed recovery before commit, completed recovery, and the effective security boundary rather than merely file presence. The successful cleanup path also removes the parked backup once the new active rule exists.

**REV-20260731-013 is closed.**

## Separate sqlfreeze correction

The conditional `SQLFREEZE-NOTE` correction is also accepted. `verdict=no-freeze-seen` must not be followed by text claiming SQL participated. The revised output no longer invents evidence and keeps the earlier correlation caveat intact.

## Remaining product-level assessment

No new blocker was found in these commits.

The grant transaction and its crash recovery are now acceptable as infrastructure for optional remote quiesce. This acceptance does not by itself make remote quiesce the correct default for the simplified deployment flow. The remaining deployment UX criterion is still that a general Linux/ZFS administrator should use one high-level enroll/remove workflow without knowing `pair`, `join`, internal grant files, or backend flags.
