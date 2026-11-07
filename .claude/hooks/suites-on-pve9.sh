#!/bin/bash
# PreToolUse hook (Bash): suites and impact.sh do not run on the Windows box.
# Owner 2026-11-03 ("zero suit na Windowsie") and 2026-11-07 ("Miales nie robic na
# Windows tylko na pve9"): one suite costs 13-25 min here and can lie; impact.sh
# --verify did not finish in 5 min. A rule written down was broken twice; this
# hook is what enforces it. Allowed here: bash -n, impact.sh --refreeze /
# --refresh-status (seconds, they write the index), anything sent over plink/ssh.
# Exit 2 = the call is refused and the message goes back to the session.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) exit 0 ;; esac
# Fail closed on the parser: without python the raw JSON is matched (the patterns still hit it).
in=$(cat)
cmd=$(printf '%s' "$in" | python -c 'import sys,json; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null) || cmd=$in
[ -n "$cmd" ] || exit 0
printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])(plink|ssh)[[:space:]]' && exit 0
refuse() {
    echo "REFUSED (owner rule, .claude/hooks/suites-on-pve9.sh): $1 does not run on this Windows box. Run it on the pve9 clone (plink root@192.168.28.99 ...) or let CI run it. Here: bash -n, cut-out cases, impact.sh --refreeze / --refresh-status." >&2
    exit 2
}
RUN='(^|[;&|(][[:space:]]*)(timeout[[:space:]]+[0-9]+[[:space:]]+)?(bash[[:space:]]+)?(\./)?'
if printf '%s' "$cmd" | grep -Eq "${RUN}test/impact\.sh" \
   && ! printf '%s' "$cmd" | grep -Eq 'test/impact\.sh[[:space:]]+--(refreeze|refresh-status|help)'; then
    refuse "test/impact.sh (suite list / --verify)"
fi
# test/<suite>/run.sh, the top-level gencron suite test/run.sh, and `cd test/<suite> && ./run.sh`.
if printf '%s' "$cmd" | grep -Eq "${RUN}test/([^/[:space:]]+/)?run\.sh"    || printf '%s' "$cmd" | grep -Eq 'cd[[:space:]]+(\./)?test(/[^[:space:];&|]+)?[[:space:]]*(&&|;)[[:space:]]*(bash[[:space:]]+)?\./run\.sh'; then
    refuse "a test suite (test/<suite>/run.sh)"
fi
exit 0
