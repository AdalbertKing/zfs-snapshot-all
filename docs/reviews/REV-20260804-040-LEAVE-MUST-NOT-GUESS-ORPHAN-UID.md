# REV-20260804-040 — `--leave` must not guess which orphaned UID belongs to this relationship

- Reviewer: ChatGPT
- Reviewed head: `1f6ca0bff26e7c56e77491b2927f0e6c41cf0951`
- Scope: REV-20260804-039 F3 follow-up (`deploy.sh --leave=LABEL`)
- Status: **OPEN — CHANGES REQUIRED**
- Response required at: `docs/reviews/responses/REV-20260804-040.md`

## Summary

The new peer-side `--leave` command is the correct lifecycle boundary: it reads the peer's own join manifest, revokes before `userdel`, verifies, and only then removes state. The live re-test also correctly caught that an already-deleted account cannot be treated as proof that its ZFS grants disappeared.

The follow-up fix at `1f6ca0b` introduces a more dangerous ambiguity: when the account is already gone, it guesses that the first `user (unknown: N)` entry shown by `zfs allow` belongs to this relationship. That is not derivable from the current manifest. On a dataset with more than one historical or delegated principal, `--leave` can revoke another relationship's authorization.

The verification added in the same commit has the inverse problem: it treats *any* numeric user grant on the dataset as residue from this relationship, so it can permanently block a correct teardown whenever another legitimate delegated account also has access.

This is an authorization-boundary defect, not only a cleanup inconvenience.

## F1 — orphan UID discovery is unbounded and can revoke another principal

- Severity: **P1**
- Blocking: **yes, for `--leave` when the account no longer exists**
- Status: **OPEN**

### Evidence

When `id "$account"` fails, the implementation leaves `uid` empty. For each dataset it then executes the equivalent of:

```bash
found_uid=$(zfs allow "$ds" \
  | grep -oE 'user \(unknown: [0-9]+\)' \
  | grep -oE '[0-9]+' \
  | head -1)
```

and revokes that UID:

```bash
zfs unallow -u "$ds_uid" "$perms" -- "$ds"
```

There is no relationship between `head -1` and the account recorded in this manifest. The manifest currently records the account name and granted datasets, but not the numeric UID assigned at join/commit time.

A realistic state is:

```text
user (unknown: 1001)  snapshot,send,...   # this deleted relationship
user (unknown: 1002)  snapshot,send,...   # another deleted/repairing relationship
```

or one unknown historical grant plus a live delegated account. Ordering is an output-format property, not ownership evidence. The command can revoke the wrong principal and then remove this relationship's manifest, losing the only scope record while the intended orphan remains.

### Required outcome

Never infer an orphan UID from an unscoped scan of `zfs allow`.

The relationship must carry a durable principal identifier before the account can disappear. Preferred contract:

1. Record `PEER_JOIN_ACCOUNT_UID=<numeric uid>` in the peer manifest at join time, and verify it in the atomic manifest commit.
2. Before each grant/commit, verify that the current account still has that UID; refuse on name/UID drift.
3. `--leave` uses only the manifest-recorded UID for revoke and residue checks, whether or not the account still exists.
4. Legacy manifests without a recorded UID may use the live account's current UID while the account exists. If the account is already gone, fail closed with an exact manual-recovery diagnostic; do not guess.
5. Do not delete manifest/scope/hash until the exact recorded UID is proven absent from every dataset in the manifest.

An alternative cryptographically or structurally equivalent binding is acceptable, but `first unknown uid` is not.

### Acceptance criteria

- [ ] Two unknown UID grants on one dataset: `--leave` revokes only the UID recorded for this relationship.
- [ ] The recorded UID is not present but another unknown UID is present: no unrelated grant is changed; teardown may proceed if this relationship has no residue.
- [ ] Legacy manifest + live account: current UID can be captured/used safely and persisted before destructive work.
- [ ] Legacy manifest + missing account + one or more unknown UIDs: fail closed and preserve all state; print exact manual inspection/recovery steps.
- [ ] UID/name drift is refused before grant or teardown mutation.
- [ ] Tests fail against `1f6ca0b` and pass against the fix.

## F2 — residue verification matches every numeric user grant, not this relationship

- Severity: **P1**
- Blocking: **yes**
- Status: **OPEN**

### Evidence

The post-revoke check uses:

```bash
grep -Eq "(^|[[:space:]])(user [0-9]+|user \(unknown: [0-9]+\)|user $account)([[:space:],]|$)"
```

This matches any numeric user principal displayed by ZFS. A second legitimate backup account with a grant on the same dataset therefore makes `--leave` report residual authorization even after this relationship's exact grant has been removed.

The check must test only the manifest-bound account name and UID, not the class "all numeric users".

### Acceptance criteria

- [ ] A second live delegated user's grant survives and does not block teardown.
- [ ] A second unknown UID grant survives and does not block teardown.
- [ ] The exact recorded UID still present does block teardown.
- [ ] The exact account name still present under an unexpected UID blocks teardown as a drift/collision signal.

## Test and live-verification requirements

Add a deterministic suite around `do_leave` with a `zfs allow` fixture containing multiple principals and stable ordering variations. The suite must cover both account-present and account-missing paths. Then repeat Gate J on scratch datasets with:

1. this relationship's grant;
2. a separate foreign delegated grant on the same dataset;
3. teardown of this relationship;
4. proof that the foreign grant is byte/semantically unchanged;
5. proof that the exact relationship UID is absent;
6. idempotent second `--leave` behavior.

Do not test this by creating ambiguity on a production workload dataset. Use scratch datasets and disposable accounts.

## Required implementer response

Respond finding by finding with `ACCEPTED`, `DISPUTED`, or `NEEDS-DISCUSSION`. Include:

- the durable UID-binding design;
- backward-compatibility behavior for manifests without UID;
- exact regression tests;
- live Gate J evidence with a foreign grant intentionally present;
- confirmation that no unrelated grant was revoked or used as a residue signal.

REV-039 F3 remains **OPEN** until this review is resolved. Do not mark the package accepted based on the current `--leave` implementation.