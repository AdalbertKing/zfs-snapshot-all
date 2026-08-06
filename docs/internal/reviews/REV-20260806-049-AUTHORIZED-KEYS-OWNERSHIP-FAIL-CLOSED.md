# REV-20260806-049 — authorized_keys ownership preservation must fail closed

**Status:** CHANGES REQUIRED  
**Reviewed main:** `651cced6a30f1eb015de8be6131a4c1899a90217`  
**Affected implementation:** `0058834b63c83e45dd4735c1b86237ea627c8ef2`  
**Response path:** `docs/internal/reviews/responses/REV-20260806-049.md`

## Finding F1 — a failed ownership restore still commits the replacement

The live check correctly found that replacing `authorized_keys` as root without preserving ownership can lock the whole account out under `sshd` `StrictModes`.

The fix obtains the original owner and runs:

```sh
chown "$owner" "$tmp" 2>/dev/null \
    || warn "could not set ownership ... sshd may refuse the file"
```

but then continues to validate and rename the temporary file over `authorized_keys`.

Therefore the exact safety failure that motivated `0058834` remains reachable whenever `stat` or `chown` fails: the function knowingly commits a replacement that may be `root:root`, emits only a warning, and can lock unrelated operator keys out of the account. This is not a recoverable best-effort condition. The atomic writer owns the metadata invariant and must not replace the live file unless safe ownership has been established.

The added test proves only that `chown` was called. It does not prove that a failed `chown` leaves the original file byte-for-byte and metadata-intact, removes staging residue, and returns failure.

## Required correction

1. Treat inability to determine a trustworthy owner/group as a hard failure before rename.
2. Treat `chown` failure as a hard failure before rename.
3. Remove the staging file on either failure and leave the original `authorized_keys` untouched.
4. Add deterministic negative tests for:
   - `stat` failure / empty ownership result;
   - `chown` failure;
   - original file contents unchanged;
   - no `.new` residue;
   - non-zero function result.
5. Run the focused pair-gate suite and provide a negative control against `0058834`.
6. Repeat the live residue/lockout check with a deliberately failing ownership operation if it can be done safely on the throwaway account; otherwise document why the deterministic test is the safe boundary.

## Campaign decision

Step 2 is **not accepted yet**. Do not begin step 3 orchestration until this invariant is fail-closed and evidenced. A full campaign is still unnecessary at this point; focused pair-gate tests plus the ownership failure proof are sufficient.
