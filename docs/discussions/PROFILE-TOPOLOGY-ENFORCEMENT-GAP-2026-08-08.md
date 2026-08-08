# Finding for the reviewer — the profile/topology rule lives only in a test

Raised by the implementer at the owner's instruction, before Stage 5 slice B1
starts. **Not a delivery, not a REV** — I cannot open one. It is a
pre-implementation contract gap and it is cheapest now.

## The rule

REV-20260808-073 settled it: **deploy owns WHAT, the profile owns HOW.** A
profile "must not contain or select concrete dataset names and must not become
the authority for dataset/grant scope", and the ban on relationship-owned fields
(`src`, `dst`, topology, grants, endpoint/key material, raw flags) is preserved.

## What actually enforces it today: one test file

```
$ ./gen-cron.sh --dump-fields | awk '$2=="dst"||$2=="src"'
dataset dst      dataset src
defaults dst     defaults src
prune dst        prune src
template dst     template src      <-- legal in the schema
```

`[template:]` **may carry `dst` and `src`.** So `gen-cron.sh` will not object to
a profile that owns topology; by the schema it is a valid config.

The only thing that refuses those fields is `validate_fragment()` — and:

```
$ grep -rn 'profiles/' --include='*.sh' .   # excluding test/
(nothing)
$ grep -n 'validate_fragment' test/profiles/run.sh
29:validate_fragment() { # <dataset|prune> <file>
```

`validate_fragment` is **defined inside `test/profiles/run.sh`**. There is no
production validator, and no production code references `profiles/` at all —
the runtime does not exist yet.

So the rule that keeps topology out of a profile is not "in two places with one
weak". It is **in one place, and that place is a test**.

## Why this matters now rather than later

The Stage 5 profile runtime is precisely the thing that will render a profile
into a `[template:]`. When it is written it must either:

1. re-implement the rule — a **third** hand-written copy of a rule in this
   codebase, and the two previous times that happened it went wrong:
   recursion lived in three places and the generator disagreed with the engines
   (REV-054), and the flag walker was written twice with the second one wrong
   (REV-074 follow-up); or
2. reuse a validator that does not exist in production yet.

Deciding this **after** the runtime exists means changing the thing that already
renders profiles, which is what REV-073 said explicitly about ownership: fixing
it later "would be substantially more expensive and could create a second source
of truth".

## Measured on the fleet before recommending

I first wrote that narrowing the schema "could refuse a config that is running
today and I have not checked". Checked:

| host | `dst`/`src` inside a `[template:]` |
|---|---|
| metropolis pve1 | 0 |
| metropolis pve2 | 0 |
| 11.x pve0 | **1** |
| 11.x pve1 | 0 |

pve0 carries:

```ini
[template:vm_archive]
	dst           = hdd/backups/pve1
```

used by real sections `rpool/data/vm-100-disk-0` and `rpool/data/vm-106-disk-0`
— the single transfer job that host runs.

## That measurement reverses my recommendation

**A template is not a profile.** A `[template:]` is a CONFIG v4 construct the
*deployment* writes, and carrying `dst` there is a legitimate way to say "every
dataset using this template lands here". pve0 proves it in production.

A **profile** is a *restricted* template. The restriction belongs at the profile
boundary — not in the schema, which serves both.

So narrowing the schema would not merely break pve0's config. It would be
**wrong in principle**: it would collapse the very distinction REV-073 drew, by
forbidding deployment-owned topology in order to constrain profile-owned policy.

## What I am asking for

**Extract `validate_fragment` from `test/profiles/run.sh` into a production
library that the Stage 5 runtime must call**, and leave the schema alone.

That places the rule where the contract places it — at the profile boundary —
and removes the "third hand-written copy" risk, which is the concrete failure
this project hit twice today (REV-054 recursion in three places; REV-074's flag
walker written twice, second one wrong).

It does not give a structural guarantee: the runtime must still call the
validator. I looked for a way to make it structural and the measurement says
there is not one that does not also break a legitimate config. Saying that
plainly rather than proposing a guarantee I cannot deliver.

**What I need from you:** confirmation that extraction-into-production is the
shape you want before B1 starts, and whether the validator should live in its
own file or join an existing lib. I am not choosing that myself — REV-073 put
ownership questions on you and the owner.

## Sync mode — checked, and it does NOT break the contract

The owner asked whether the two-host `--mode=sync` violates the ownership split.
It does not. Sync expresses topology structurally (a bare `user@host` dst,
mirroring to the identical path), and that `dst` lives in `[defaults]` or
`[dataset:]` — deployment-owned sections. The profile is not involved.

`zfs-backup.sh` also refuses `--target` together with `--mode=sync`, and refuses
sync to a member of the same PVE cluster because pvesr would fight it for the
destination. Both are relationship-level rules sitting in the right layer.

Locally, sync is **structurally meaningless**: it mirrors to the identical path
on another host, and there is no other host. The engine already refuses a bare
`user@host` resolving to this machine — "a dataset cannot sync to itself". The
local path must therefore refuse `--mode=sync` **with the reason**, not accept
it as a no-op.
