# Explicit `--source` beats discovery

Status: **OWNER DIRECTION**
Date: 2026-08-09
Applies to: high-level `zfs-backup.sh` source selection, Phase 2 composition where relevant, Phase 5 local UX, and remote enrolment source selection after the discovery/scope boundary.

## Decision

`--source` is an explicit WHAT selection, not a hint for autodiscovery.

If the operator supplies one or more source roots, the proposed CONFIG must contain **only those explicitly selected roots**. The tool must not add other first-level datasets discovered by `zfs list`, sibling datasets, or other "helpful" sources.

Examples:

```bash
./zfs-backup.sh --source=rpool/data --target=hdd/backups
```

Proposal scope:

```text
rpool/data
```

and nothing such as `rpool/ROOT`, `rpool/var-lib-vz`, `rpool/other`, etc. may be auto-added merely because discovery found it.

Multiple explicit roots are allowed in one invocation, e.g.:

```bash
./zfs-backup.sh --source=rpool/data,rpool/vmstore,hdd/dokumenty --target=hdd/backups
```

Proposal scope is exactly:

```text
rpool/data
rpool/vmstore
hdd/dokumenty
```

No other discovered source is appended.

Supporting repeated flags such as:

```bash
--source=rpool/data --source=rpool/vmstore
```

is acceptable if it is cheap; if supported it must normalize to exactly the same source list semantics as the comma-separated form. Do not build a second source-selection mechanism merely for syntax convenience.

## Zero-source case versus invalid explicit source

These are different operator intents and MUST NOT be conflated.

```text
no --source
    -> operator asks automation to propose
    -> discovery may propose source roots

--source supplied
    -> operator selected exact requested roots
    -> every requested root must validate
```

If an explicitly requested dataset does not exist or cannot be validated at the authoritative source-validation boundary, the operation must **REFUSE**. It must not fall back to discovery and it must not silently treat the invalid argument as if `--source` had been omitted.

Example:

```bash
./zfs-backup.sh --source=rpool/dtaa --target=hdd/backups
```

where `rpool/dtaa` does not exist must end with a clear failure such as:

```text
FATAL: source dataset 'rpool/dtaa' does not exist
```

It must NOT continue by discovering and proposing `rpool/data`, `rpool/ROOT`, or any other dataset.

For a multi-source request the rule is all-or-nothing:

```bash
--source=rpool/data,rpool/vmstore,rpool/nieistnieje
```

If even one explicitly requested root is invalid, **REFUSE the whole operation**. Do not install or propose a partial subset as success, because that could leave an operator believing all requested data is protected when one source was omitted.

Canonical rule:

```text
0 x --source
    -> discovery may propose sources

1..N explicit sources
    -> explicit source set is authoritative
    -> validate every requested source
    -> any invalid source = REFUSE whole operation
    -> no fallback to discovery
    -> no partial success
```

In short:

> **absence of selection enables automation; an invalid explicit selection stops automation.**

## Local versus remote boundary

The explicit-source rule must not bypass the remote enrolment/discovery/grant boundary.

### Local workflow

On the same host, the tool can validate the requested source directly:

```bash
./zfs-backup.sh --source=rpool/data --target=hdd/backups
```

Here `--source=rpool/data` is authoritative WHAT immediately after local existence/validity checks.

### Remote workflow

At the collector's initial `add-client` step, the collector does not yet authoritatively know the peer's ZFS dataset inventory or accepted grant scope. Therefore an early remote `--source` must never be treated as an already-proven dataset fact that skips peer discovery/scope approval.

Preferred simple V1 flow:

```text
collector add-client
    -> source join/discovery
    -> source scope proposal/acceptance
    -> grant/confirmed scope
    -> authoritative WHAT
```

If a future/current remote command accepts an early requested `--source`, it is only a **requested selector** until the source side confirms it. The source must discover/validate it inside the normal scope/grant boundary:

```text
requested rpool/data
    -> remote discovery/validation
    -> exists and allowed: accept as WHAT
    -> missing/not allowed: REFUSE
```

A missing remote requested dataset must not turn into a blank selection and must not trigger a wider discovery proposal as fallback.

Therefore:

```text
LOCAL explicit source
    -> validate locally
    -> authoritative WHAT

REMOTE before discovery
    -> source name may be only a requested selector, never an assumed fact
    -> discovery/scope/grant boundary still mandatory

REMOTE after accepted discovery/scope
    -> confirmed explicit source set becomes authoritative WHAT
```

## WHAT versus HOW

Source roots remain WHAT. Recursion remains HOW/policy.

```text
--source=rpool/data        = WHAT: selected source root
recursive=no|flat|atomic   = HOW: how that source is processed
```

Therefore `recursive=flat` for `rpool/data` may dynamically include descendants of that root according to CONFIG semantics, but it never authorizes adding sibling roots such as `rpool/other` to the proposal.

## Validation

Before proposal/composition, normalize and validate the explicit source list.

Conservative V1 rule:

- exact duplicate source entries: reject with a clear diagnostic or canonicalize to one entry; never create duplicate task ownership;
- parent/child overlap between explicitly listed roots: **REFUSE** rather than silently invent precedence or carve-outs;
- invalid/nonexistent source: **REFUSE**, never fallback to discovery;
- multi-source validation is atomic: one invalid requested root refuses the entire explicit set;
- unrelated explicit roots remain independent entries in the candidate CONFIG.

Do not create an include/exclude/precedence framework to resolve overlapping explicit roots. Expert bespoke topology remains a native CONFIG concern.

## Product intent

An explicit operator choice must narrow automation, never cause automation to widen the requested scope.

In short:

> **explicit source beats discovery**

and:

> **no source means propose; wrong explicit source means stop.**

This is the owner UX contract Claude should preserve when implementing the current CREATE-only/additive path and the later one-command local workflow.