# Publication flow — branch, Pull Request, merge

Active from 2026-08-14, when the Owner revoked the direct-main exception
(`docs/project/OWNER-DECISIONS.md`, `docs/AI_PROJECT_RULES.md`).

This file is the recipe. The *rule* lives in `AI_PROJECT_RULES.md`; this is how to
follow it without inventing a different way each time.

## The state right now, stated plainly

The rule is active. The **GitHub setting is not**: at the time of writing,
`GET /repos/AdalbertKing/zfs-snapshot-all/branches/main/protection` returns
`404 Branch not protected`, so a direct push still succeeds. Measured, not assumed
— and I know it succeeds because one of mine did, minutes after the rule landed.

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

Then open the Pull Request. From a shell with the repo's stored credentials:

```bash
TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | sed -n 's/^password=//p'); curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" https://api.github.com/repos/AdalbertKing/zfs-snapshot-all/pulls -d "{\"title\":\"<title>\",\"head\":\"<branch>\",\"base\":\"main\"}" | sed -n 's/.*"html_url": "\([^"]*pull[^"]*\)".*/\1/p'
```

The reviewer, who has API access and no filesystem, uses the same endpoint. That
is the whole reason the gate is branch protection rather than a local hook: both
roles reach it identically.

Once the required check is green, merge — or let auto-merge do it, once the repo
setting is on.

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
