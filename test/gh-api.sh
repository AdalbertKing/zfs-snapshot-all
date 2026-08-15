#!/bin/bash
# gh-api.sh -- talk to THIS repository's GitHub API, and only this one.
#
#   ./test/gh-api.sh GET  pulls/12
#   ./test/gh-api.sh GET  commits/<sha>/check-runs
#   ./test/gh-api.sh POST pulls            body.json
#   ./test/gh-api.sh PUT  pulls/12/merge   body.json
#
# Why a wrapper instead of curl at the call site:
#
# The token comes from `git credential fill`, so every call site grew a
# `TOKEN=$(printf ... | git credential fill ...)` prefix. That makes the command
# string start with a variable assignment, which a permission rule cannot match
# usefully -- the only rule that would cover it is `Bash(curl *)`, and that
# permits any URL, any method, any headers. For an unattended caller that is a
# general-purpose outbound HTTP tool with the user's GitHub credentials attached.
#
# So the URL is built here. A caller supplies a method and a path RELATIVE to this
# repository's API root; it cannot reach another repository, another host, or a
# different API. The token never appears in an argument, so it cannot end up in a
# command line, a log, or a permission prompt.
set -u

REPO_SLUG="${GH_API_REPO:-AdalbertKing/zfs-snapshot-all}"
die() { echo "gh-api: $*" >&2; exit 1; }

method="${1:-}"; path="${2:-}"; body="${3:-}"
[ -n "$method" ] && [ -n "$path" ] || die "usage: $0 <GET|POST|PATCH|PUT> <path-under-repo> [body.json]"

case "$method" in
    GET|POST|PATCH|PUT) ;;
    *) die "method '$method' is not one of GET, POST, PATCH, PUT (DELETE is deliberately not offered)" ;;
esac

# A path under this repo, nothing that can climb out of it or start a second URL.
case "$path" in
    /*|*..*|*://*|*@*) die "'$path' must be a plain path under the repository API root" ;;
    *[!A-Za-z0-9/._%~=?-]*) die "'$path' contains characters that do not belong in an API path" ;;
esac

[ -z "$body" ] || [ -f "$body" ] || die "body file '$body' does not exist"

token="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | sed -n 's/^password=//p')"
[ -n "$token" ] || die "no GitHub credential available from git credential fill"

url="https://api.github.com/repos/$REPO_SLUG/$path"
set -- -sS -X "$method" \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28"
[ -n "$body" ] && set -- "$@" -d @"$body"

curl "$@" "$url"
