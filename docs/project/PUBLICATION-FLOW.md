# Publication flow — branch, Pull Request, merge

Active from 2026-08-14, when the Owner revoked the direct-main exception
(`docs/project/OWNER-DECISIONS.md`, `docs/AI_PROJECT_RULES.md`).

This file is the recipe. The *rule* lives in `AI_PROJECT_RULES.md`; this is how to
follow it without inventing a different way each time.

> **Written 2026-08-14, published 2026-09-22.** It sat unmerged on a branch for
> six weeks, which is its own small illustration of the problem it describes. Every
> fact below was re-measured on the publication date; where the tree moved in the
> meantime — the API wrapper, the status digest — the recipe was rewritten rather
> than annotated, so what you read is what the tree does now.

## The state right now, stated plainly

The rule is active. The **GitHub setting is not**:
`GET /repos/AdalbertKing/zfs-snapshot-all/branches/main/protection` returns
`404 Branch not protected`, so a direct push still succeeds. Measured, not assumed
— and I know it succeeds because one of mine did, minutes after the rule landed.

**Re-measured 2026-09-22: still `404`.** Six weeks is long enough that this stops
being a deployment lag and becomes a standing fact about the estate: the gate
described here is discipline, not enforcement, and anything claiming otherwise in
a delivery note is wrong.

That gap is a deployment lag, not permission. Follow the flow anyway; the point of
the rule is that canonical `main` only moves through a verified transition, and a
server that has not yet been told to enforce it does not change what is correct.

Two things are still owed, both one-off:

- branch protection on `main` with the **`dependency graph matches the tree`**
  check required, "require a pull request" on, **0 required approvals** (GitHub
  defaults to 1, which would make the Owner click every merge), and
  "do not allow bypassing" on, or an admin token walks straight past it;
- repo Settings → General → **Allow auto-merge**, without which PRs will not merge
  themselves and the Owner is back to tapping buttons.

Until both are set, treat every step below as mandatory anyway and say so in the
delivery note rather than describing the invariant as enforced.

## The flow

```bash
git checkout -b <kind>/<short-name>          # docs/… fix/… phase7/… protocol/…
# work, commit as usual
git push -u origin <kind>/<short-name>
```

Then open the Pull Request with the repository's own API wrapper — **not** a
hand-written `curl`. `test/gh-api.sh` builds the URL itself from a path relative
to this repository and fills the credential, so a caller cannot point it at a
different repository by accident, and it refuses `DELETE` outright:

```bash
./test/gh-api.sh POST pulls pr.json
```

`pr.json` carries `title`, `head`, `base` and `body`. Write it from a file rather
than inline: a body typed into a shell string loses backslashes to the heredoc and
executes backticks, and a PR description is the one place where a mangled sentence
survives in public.

The merge, once the checks are green, is the same wrapper:

```bash
./test/gh-api.sh PUT pulls/<N>/merge merge.json    # {"merge_method":"merge","sha":"<head>"}
```

Naming the head `sha` is not decoration: it refuses to merge a branch that moved
after you read the checks.

The reviewer, who has API access and no filesystem, reaches the same endpoints.
That is the whole reason the gate is branch protection rather than a local hook:
both roles arrive at it identically.

## Before the merge: the status digest

`docs/PROJECT_STATUS.md` carries a digest that CI verifies, so the last three
commands of every delivery are fixed, in this order:

```bash
./test/impact.sh --refresh-status
git add docs/PROJECT_STATUS.md
./test/impact.sh --verify        # read the EXIT CODE, never a tail of its output
```

They must come **after the final code change**, not before it — refreshing the
digest and then touching one more file republishes a digest that no longer
describes the tree, and the check fails on the PR rather than here.

## What must not happen

- **No administrator bypass in ordinary work.** The token used here has `admin`,
  which means the gate is only as real as the discipline until "do not allow
  bypassing" is set. Treat a successful direct push as a bug in the setup, not as
  permission.
- **No force-push, no rewriting a published commit.** Unchanged from before, and
  branch protection will refuse it once enabled.
- **No merging your own protocol transition without the check passing.** The whole
  failure this replaced was a transition published faster than it was verified.

## How this interacts with `reviewctl approve` / `close`

The writer produces a *tree*; the PR publishes it. So a lifecycle transition is:

1. `./test/reviewctl.sh approve REV --implementation SHA --expected-parent SHA`
   — where `--expected-parent` is the current tip of `origin/main`, not of your
   branch. If the branch has fallen behind, the CAS is telling you the truth:
   rebase and recompute rather than publishing against facts you never saw.
2. commit, push the branch, open the PR, let the check verify the transition.
3. `close` is a **separate** PR, and its `--approval-commit` is the merge commit
   (or the commit) that actually carried the approval onto `main`. It cannot be
   computed before step 2 has landed, which is the point.

That ordering is not ceremony: it is what makes "approved" and "closed" two
publications rather than one, which is exactly what REV-120/121 got wrong.

## Phone operation

The Owner administers this estate from a phone, and that was the reason
direct-main existed at all. The replacement is automation around branches and
PRs — the recipe above run by an agent — not a weaker gate. If the flow starts
costing the Owner taps, that is a defect in the automation and should be reported
as one, not solved by turning protection off.
