# REV-20260801-015 — activation preview must compare against the live crontab

**Verdict: CHANGES REQUIRED**

The new `activate-client` preview is the right UX direction: the administrator now sees the proposed config and schedule before accepting. The two views are useful and the correction of the remote-quiesce wording is accurate.

There are two fail-closed gaps in `show_activation_proposal()`.

## 1. The screen says "what will change in crontab", but `before` is not the current crontab

`before` is generated from the current config file:

```bash
bash "$GENCRON" -c "$cronfile" ... > "$before"
```

It is not captured from `crontab -l`. Therefore any real drift between the config and the installed managed block is invisible. The preview can say:

```text
(bez zmian -- linie crona beda identyczne jak teraz)
```

while `gen-cron --install` will in fact change the live crontab.

This matters precisely in the recovery/admin cases the simplified workflow must handle: manual edits, an older interrupted deployment, a config copied from another host, or a stale managed block. Consent must be against the state that will actually be modified, not against a second rendering of the desired state.

**Required:** build the left side from the currently installed managed block (or preview the complete `crontab -l` before/after using the same merge logic as `--install`). Preserve unrelated cron lines, but show every line the install will add, remove or replace.

At minimum add a test where config A renders schedule X, the live crontab contains schedule Y, and the proposed config is still A. The preview must show Y→X, not `bez zmian`.

## 2. Failure to render the existing config is ignored

The proposed config is checked explicitly, but the existing side is an unguarded AND-list:

```bash
[ -f "$cronfile" ] && bash "$GENCRON" -c "$cronfile" ... > "$before"
```

If the current config exists but is invalid, the function may continue with an empty/partial `before` and present a plausible diff instead of stopping. That violates the stated fail-closed behavior.

**Required:** if the current config exists and cannot be rendered, abort the preview with a clear message and touch nothing. Add a regression test for invalid existing config as well as invalid proposed config.

## UX acceptance criterion

The operator should be able to trust one statement:

> This is the exact config and exact live cron change that accepting will apply.

Until the left side comes from the live installed state and both render paths fail closed, the new prompt does not yet meet that criterion.
