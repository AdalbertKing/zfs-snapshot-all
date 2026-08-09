# Explicit `--source` beats discovery

Status: **OWNER DIRECTION**
Date: 2026-08-09
Applies to: high-level `zfs-backup.sh` source selection, Phase 2 composition where relevant, and Phase 5 local UX.

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

## Zero-source case

Only when the operator supplies **no `--source` at all** may the tool run discovery and propose candidate source roots.

Canonical rule:

```text
0 x --source
    -> discovery may propose sources

1..N explicit sources
    -> explicit source set is authoritative
    -> no extra datasets from discovery
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
- invalid/nonexistent source: fail clearly according to the normal source-validation boundary;
- unrelated explicit roots remain independent entries in the candidate CONFIG.

Do not create an include/exclude/precedence framework to resolve overlapping explicit roots. Expert bespoke topology remains a native CONFIG concern.

## Product intent

An explicit operator choice must narrow automation, never cause automation to widen the requested scope.

In short:

> **explicit source beats discovery**

This is the owner UX contract Claude should preserve when implementing the current CREATE-only/additive path and the later one-command local workflow.
