#!/bin/bash
# impact.sh -- given a set of changed files, say exactly what has to be tested.
#
# The question this answers is not "are there tests?" but "which ones does THIS
# change oblige me to run, and what can no test cover at all?". Both halves
# matter: on 2026-07-25 a change touched delsnaps.sh, its suite was not re-run
# because nobody thought of it, and separately a green 161/161 suite hid four
# defects that only a delegated non-root run could reach.
#
# Usage:
#   ./test/impact.sh                  # uncommitted changes (working tree + index)
#   ./test/impact.sh HEAD~3           # everything since that ref
#   ./test/impact.sh HEAD~3..HEAD     # an explicit range
#   ./test/impact.sh -f a.sh -f b.sh  # ask about specific files, no git
#   ./test/impact.sh --all            # the full battery, ignoring any diff
#   ./test/impact.sh --graph          # mermaid diagram of the whole graph
#   ./test/impact.sh --verify         # drift check: does the graph match reality?
#
# Exit: 0 nothing to do / plan printed, 1 usage or verify failure.

set -o pipefail

VERSION='v1.1'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF="${IMPACT_CONF:-$SCRIPT_DIR/deps.conf}"
REVIEWCTL="${REVIEWCTL:-$SCRIPT_DIR/reviewctl.sh}"

die() { echo "impact.sh: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Config parsing. Same shape as gen-cron.sh's: [type:name] sections, key = value,
# continuation lines indented. Kept deliberately small -- this file is read by
# people at least as often as by the script.
# ---------------------------------------------------------------------------
declare -A SEC_KIND=()      # "kind:name" -> kind
declare -A FIELD=()         # "kind:name|key" -> value
declare -a SECTIONS=()

parse_conf() {
    [ -r "$CONF" ] || die "cannot read $CONF"
    local line section="" key val
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \#*|'') continue ;;
            \[*\])
                section="${line#[}"; section="${section%]}"
                [[ "$section" == *:* ]] || die "section '[$section]' has no type prefix"
                SEC_KIND[$section]="${section%%:*}"
                SECTIONS+=("$section")
                continue ;;
        esac
        # Continuation: ANY indented line. Keys start at column 0, so
        # indentation alone decides -- no guessing from the content. Looking for
        # a '=' instead would break on wrapped prose like "gets canmount=on",
        # which reads as a key named "gets canmount" and silently truncates the
        # field; and "does it contain an identifier before the '='" breaks on
        # exactly the same line. Both halves of such a sentence matter in a
        # contract, so the rule has to be structural.
        if [[ "$line" =~ ^[[:space:]] ]]; then
            [ -n "$section" ] && [ -n "${key:-}" ] || continue
            val="${line#"${line%%[![:space:]]*}"}"
            FIELD[$section|$key]+=" $val"
            continue
        fi
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"; val="${line#*=}"
        key="${key//[[:space:]]/}"
        val="${val#"${val%%[![:space:]]*}"}"
        FIELD[$section|$key]="$val"
    done < "$CONF"
}

# Split a "a, b, c" field into words on stdout.
list_of() {
    local raw="${FIELD[$1|$2]:-}"
    raw="${raw//,/ }"
    printf '%s\n' $raw
}

sections_of_kind() {
    local kind="$1" s
    for s in "${SECTIONS[@]}"; do
        [ "${SEC_KIND[$s]}" = "$kind" ] && printf '%s\n' "${s#*:}"
    done
}

# ---------------------------------------------------------------------------
# Source edges, derived from the code rather than declared. A file that sources
# another inherits its obligations: change the lib and every consumer's suite is
# in scope.
# ---------------------------------------------------------------------------
declare -A SOURCED_BY=()    # lib -> " consumer1 consumer2"

derive_source_edges() {
    local f base target
    for f in "$REPO"/*.sh; do
        [ -f "$f" ] || continue
        base="${f#$REPO/}"
        while IFS= read -r target; do
            [ -n "$target" ] || continue
            case " ${SOURCED_BY[$target]:-} " in
                *" $base "*) ;;
                *) SOURCED_BY[$target]+=" $base" ;;
            esac
        done < <(grep -oE '^[[:space:]]*(\.|source)[[:space:]]+"?\$[A-Za-z_]+/[A-Za-z0-9._-]+\.sh' "$f" \
                 | grep -oE '[A-Za-z0-9._-]+\.sh$')
    done
}

# ---------------------------------------------------------------------------
# Resolution: changed files -> suites, manual obligations, contracts
# ---------------------------------------------------------------------------
declare -A NEED_SUITE=() NEED_MANUAL=() NEED_CONTRACT=() SEEN_FILE=()
declare -a UNKNOWN_FILES=()

add_file() {
    local file="$1" via="${2:-}" item consumer
    [ -n "${SEEN_FILE[$file]:-}" ] && return 0
    SEEN_FILE[$file]=1

    if [ -z "${SEC_KIND[file:$file]:-}" ]; then
        # A section name ending in "/" covers everything beneath it. Golden
        # fixtures are the reason: test/fixtures/*.conf.expected IS the gen-cron
        # test, and listing forty of them one by one would rot within a week.
        local sec prefix
        for sec in $(sections_of_kind file); do
            case "$sec" in
                */) prefix="$sec" ;;
                *) continue ;;
            esac
            case "$file" in
                "$prefix"*) add_declared "$sec"; return 0 ;;
            esac
        done
        # Only shell files are expected to carry obligations; anything else
        # (README, a stray config) is reported separately, never guessed at.
        case "$file" in
            *.sh) UNKNOWN_FILES+=("$file") ;;
        esac
        return 0
    fi
    add_declared "$file"
}

# Pull the obligations off one declared section and follow the source edges.
add_declared() {
    local file="$1" item consumer

    while read -r item; do [ -n "$item" ] && NEED_SUITE[$item]="$file"; done < <(list_of "file:$file" suites)
    while read -r item; do [ -n "$item" ] && NEED_MANUAL[$item]="$file"; done < <(list_of "file:$file" manual)
    while read -r item; do [ -n "$item" ] && NEED_CONTRACT[$item]="$file"; done < <(list_of "file:$file" contracts)

    # Transitive: consumers of a changed lib inherit everything.
    for consumer in ${SOURCED_BY[$file]:-}; do
        add_file "$consumer" "sources $file"
    done
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
plain() { printf '%s\n' "$*"; }

print_plan() {
    local suite manual contract cmd needs why how members check other

    if [ ${#NEED_SUITE[@]} -eq 0 ] && [ ${#NEED_MANUAL[@]} -eq 0 ] && [ ${#NEED_CONTRACT[@]} -eq 0 ]; then
        plain "Nothing in the graph is affected."
        [ ${#UNKNOWN_FILES[@]} -gt 0 ] && print_unknown
        return 0
    fi

    if [ ${#NEED_SUITE[@]} -gt 0 ]; then
        bold "SUITES TO RUN"
        # Cheap-and-local first: a no-dependency suite that fails saves the trip
        # to a PVE host entirely.
        for suite in $(printf '%s\n' "${!NEED_SUITE[@]}" | sort); do
            needs="${FIELD[suite:$suite|needs]:-?}"
            [ "$needs" = "nothing" ] || continue
            cmd="${FIELD[suite:$suite|cmd]:-<undeclared>}"
            printf '  %-28s %s\n' "$cmd" "(local, no root -- because ${NEED_SUITE[$suite]} changed)"
        done
        for suite in $(printf '%s\n' "${!NEED_SUITE[@]}" | sort); do
            needs="${FIELD[suite:$suite|needs]:-?}"
            [ "$needs" = "nothing" ] && continue
            cmd="${FIELD[suite:$suite|cmd]:-<undeclared>}"
            printf '  %-28s %s\n' "$cmd" "(needs $needs -- because ${NEED_SUITE[$suite]} changed)"
        done
        echo
    fi

    if [ ${#NEED_CONTRACT[@]} -gt 0 ]; then
        bold "CONTRACTS TO RE-CHECK  (nothing in the code enforces these)"
        for contract in $(printf '%s\n' "${!NEED_CONTRACT[@]}" | sort); do
            members="${FIELD[contract:$contract|members]:-}"
            why="${FIELD[contract:$contract|why]:-}"
            check="${FIELD[contract:$contract|check]:-}"
            other=""
            for m in ${members//,/ }; do
                [ "$m" = "${NEED_CONTRACT[$contract]}" ] || other+=" $m"
            done
            plain "  $contract  (with:${other:- -})"
            plain "      why:   $why"
            plain "      check: $check"
        done
        echo
    fi

    if [ ${#NEED_MANUAL[@]} -gt 0 ]; then
        bold "MANUAL -- NO SUITE COVERS THIS"
        for manual in $(printf '%s\n' "${!NEED_MANUAL[@]}" | sort); do
            why="${FIELD[manual:$manual|why]:-}"
            how="${FIELD[manual:$manual|how]:-}"
            plain "  $manual  (because ${NEED_MANUAL[$manual]} changed)"
            plain "      why: $why"
            plain "      how: $how"
        done
        echo
    fi

    [ ${#UNKNOWN_FILES[@]} -gt 0 ] && print_unknown
    return 0
}

print_unknown() {
    bold "NOT IN THE GRAPH -- decide, do not ignore"
    local f
    for f in "${UNKNOWN_FILES[@]}"; do plain "  $f"; done
    plain "  Add a [file:<name>] section to test/deps.conf (suites= may be empty,"
    plain "  but then say why in note=)."
    echo
}

# ---------------------------------------------------------------------------
# --verify: the anti-drift check. A graph nobody validates rots into decoration.
# ---------------------------------------------------------------------------
verify() {
    local rc=0 f base s suite cmd m kind name
    echo "== files declared in the graph exist"
    for name in $(sections_of_kind file); do
        [ -e "$REPO/$name" ] || { echo "  MISSING: [file:$name] has no such file"; rc=1; }
    done

    echo "== every shell file in the repo is declared"
    # Tracked files only: an untracked scratch script in the tree is not a
    # decision anybody owes an answer for.
    while read -r f; do
        [ -n "${SEC_KIND[file:$f]:-}" ] || { echo "  UNDECLARED: $f"; rc=1; }
    done < <(git -C "$REPO" ls-files '*.sh' 2>/dev/null)

    echo "== declared suites exist and are executable"
    # The TRACKED mode is what matters, not this working copy's: git on Windows
    # does not record the executable bit, so a suite added from a dev box lands
    # on every host as 100644 and cannot be run there at all -- while `test -x`
    # passes locally and hides it. Deployment is `git pull`, so the index is the
    # thing that ships. Check it, and fall back to the filesystem outside a repo.
    local mode
    for name in $(sections_of_kind suite); do
        cmd="${FIELD[suite:$name|cmd]:-}"
        [ -n "$cmd" ] || { echo "  [suite:$name] has no cmd"; rc=1; continue; }
        # strip a leading sudo and any args
        set -- $cmd
        [ "$1" = "sudo" ] && shift
        f="${1#./}"
        [ -e "$REPO/$f" ] || { echo "  [suite:$name] cmd does not exist: $1"; rc=1; continue; }
        mode="$(git -C "$REPO" ls-files -s "$f" 2>/dev/null | awk '{print $1}')"
        if [ -n "$mode" ]; then
            [ "$mode" = "100755" ] || { echo "  [suite:$name] $f is tracked $mode, not 100755 -- it will not be executable on any host (git update-index --chmod=+x $f)"; rc=1; }
        elif git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
            # In a repo but untracked: the filesystem bit says nothing about what
            # will ship, and trusting it is how a suite reaches a host as 100644
            # twice in one day. The check below only applies outside a checkout.
            echo "  [suite:$name] $f is not staged yet -- its tracked mode cannot be verified. git add it and re-run --verify."; rc=1
        else
            [ -x "$REPO/$f" ] || { echo "  [suite:$name] cmd not executable: $1"; rc=1; }
        fi
    done

    echo "== every shipped script the hosts EXECUTE is executable in the index"
    # THE SAME LESSON AS THE SUITE CHECK ABOVE, and it took a live near-miss to
    # notice it was only half applied. zfs-job.sh went to main as 100644,
    # deployed to four checkouts as -rw-r--r--, and the generated cron line
    # invokes it DIRECTLY: every managed job on every host would have failed
    # with Permission denied. Not one job -- all of them, because the envelope
    # is shared.
    #
    # A shebang is the file SAYING it is meant to run directly, so that is the
    # rule: shebang, not a lib-*.sh (those are sourced), therefore 100755. The
    # INDEX mode, never the working copy: git on Windows records no exec bit,
    # so `chmod +x` before `git add` changes nothing and `test -x` passes
    # locally while the host gets a file it cannot run.
    local _m _f
    while read -r _m _ _ _f; do
        case "$_f" in lib-*.sh) continue ;; esac
        head -1 "$REPO/$_f" 2>/dev/null | grep -q "^#!" || continue
        [ "$_m" = 100755 ] && continue
        echo "  NOT EXECUTABLE IN THE INDEX: $_f (mode $_m) -- it has a shebang, so a host will try to run it directly. Fix with: git update-index --chmod=+x $_f"
        rc=1
    done < <(git -C "$REPO" ls-files -s "*.sh" 2>/dev/null | grep -v "/")

    echo "== CI runs every suite that needs nothing but bash"
    # The workflow used to name its suites inline, under a comment asserting the
    # list equalled the `needs = nothing` set. It did not -- 7 against 29 -- and
    # no check existed, so the gap was invisible for as long as nobody counted.
    # The 22 missing suites still had to run; they ran by hand, serially, at
    # 13-25 minutes each against seconds on a runner.
    #
    # The fix was to DERIVE the matrix, so what is verified here is that it is
    # still derived. Checking "the inline list matches the field" would only
    # restore the duplicate this removed.
    local wf="$REPO/.github/workflows/tests.yml"
    if [ ! -f "$wf" ]; then
        echo "  .github/workflows/tests.yml is missing"; rc=1
    else
        grep -q 'ci-suites.sh --json' "$wf" \
            || { echo "  tests.yml no longer derives its matrix from ./test/ci-suites.sh"; rc=1; }
        # A re-introduced literal list is the exact regression this guards.
        grep -qE '^[[:space:]]*suite:[[:space:]]*\[' "$wf" \
            && { echo "  tests.yml hardcodes a suite list again -- the matrix must come from ci-suites.sh"; rc=1; }
        local ci_n
        ci_n="$(bash "$REPO/test/ci-suites.sh" 2>/dev/null | grep -c .)"
        [ "${ci_n:-0}" -gt 0 ] \
            || { echo "  test/ci-suites.sh derived no suites -- deps.conf parse is broken"; rc=1; }
    fi

    echo "== every suite referenced by a file is declared"
    for name in $(sections_of_kind file); do
        while read -r s; do
            [ -n "$s" ] || continue
            [ -n "${SEC_KIND[suite:$s]:-}" ] || { echo "  [file:$name] names unknown suite '$s'"; rc=1; }
        done < <(list_of "file:$name" suites)
        while read -r s; do
            [ -n "$s" ] || continue
            [ -n "${SEC_KIND[manual:$s]:-}" ] || { echo "  [file:$name] names unknown manual '$s'"; rc=1; }
        done < <(list_of "file:$name" manual)
        while read -r s; do
            [ -n "$s" ] || continue
            [ -n "${SEC_KIND[contract:$s]:-}" ] || { echo "  [file:$name] names unknown contract '$s'"; rc=1; }
        done < <(list_of "file:$name" contracts)
    done

    echo "== contract membership is symmetric"
    # If a contract lists a file, that file must list the contract. Otherwise
    # editing that file would never surface the contract -- the exact failure
    # this whole thing exists to prevent.
    for name in $(sections_of_kind contract); do
        for m in ${FIELD[contract:$name|members]//,/ }; do
            [ -n "${SEC_KIND[file:$m]:-}" ] || { echo "  [contract:$name] names unknown file '$m'"; rc=1; continue; }
            case " $(list_of "file:$m" contracts | tr '\n' ' ') " in
                *" $name "*) ;;
                *) echo "  ASYMMETRIC: [contract:$name] lists $m, but [file:$m] does not list $name"; rc=1 ;;
            esac
        done
    done

    echo "== source edges found in the code are reflected in the graph"
    for name in "${!SOURCED_BY[@]}"; do
        [ -n "${SEC_KIND[file:$name]:-}" ] || { echo "  $name is sourced by${SOURCED_BY[$name]} but is not declared"; rc=1; }
    done

    no_conflict_markers || rc=1
    status_freshness || rc=1
    engine_freeze || rc=1
    protocol_verify || rc=1

    if [ $rc -eq 0 ]; then echo "graph is consistent with the tree"; else echo "GRAPH DRIFT -- fix deps.conf"; fi
    return $rc
}

# Is PROJECT_STATUS.md still true? (REV-20260807-060 A2, made mandatory by
# REV-20260807-061 F2.)
#
# The obligation `project-status` has been raised on every change for weeks and
# discharged by editing whichever paragraph had just been made stale, never by
# re-reading the document. It went stale again LESS THAN AN HOUR after a review
# closed for having fixed it. A reminder that has failed that consistently is
# not a reminder problem.
#
# Keyed off an explicit MACHINE marker, never the prose: A2 is emphatic that
# rewording the introduction must not silently disable the check. The marker
# names the last behaviour-changing commit the document describes; anything
# newer touching a project-status file means the document is describing a tree
# that no longer exists.

# Is the live ledger internally coherent? (REV-20260807-063 F1.)
#
# The status marker stops PROJECT_STATUS.md lagging a commit. It does NOT stop
# a document contradicting itself, and twice in one day these files routed a
# reader to work that was already done -- a row still naming an owner for a
# decision taken hours earlier, and an announced review head three commits
# behind the tree.
#
# Both checks below read STRUCTURE, never prose: a table column and a marker
# line, both formats this repo controls. Grepping Polish sentences for meaning
# was explicitly rejected, and rightly -- it would fail on rewording and pass
# on the thing that matters.
#
# The review protocol was reactivated after its temporary 2026-08-15 retirement,
# so its derived views are once again part of the normal gate. In PR CI the
# reachability boundary is the candidate HEAD: an implementation commit carried
# by the PR is not on origin/main yet, but must be an ancestor of what would be
# merged. Canonical publication remains a separate post-merge main read-back.
protocol_verify() {
    echo "== review ledger and routing match the publication candidate"
    if [ ! -x "$REVIEWCTL" ]; then
        echo "  reviewctl is missing or not executable: $REVIEWCTL"
        return 1
    fi
    REVIEWCTL_PUBREF=HEAD "$REVIEWCTL" --verify
}

STATUS_FILE="docs/PROJECT_STATUS.md"
RDIR_FREEZE="$REPO/docs/internal/reviews"
STATUS_MARKER_RE='^<!-- status-covers-digest: ([0-9a-f]{16}) -->$'
STATUS_LEGACY_RE='^<!-- status-covers-commit: ([0-9a-f]{7,40}) -->$'

# The invariant is over the PROSPECTIVE COMMIT -- the git index -- not over a
# commit SHA and not over the working tree.
#
# Two rounds of REV-20260807-068 got here:
#
#   round 1: the marker named the last behaviour-changing COMMIT. That cannot
#   be checked before the commit exists (a commit cannot contain its own hash),
#   so run as a pre-stage gate it reported clean and blessed a commit that
#   landed stale.
#
#   round 2: a digest over the WORKING TREE. Still wrong at the boundary,
#   because `git commit` records the INDEX. Stage a watched file, refresh the
#   status into the working tree, do NOT stage it, verify -- clean; commit --
#   stale. Same false-green, one step further along.
#
# So everything the verdict rests on is read from the index: the watched
# blobs, the PROJECT_STATUS.md that carries the marker, and the deps.conf that
# DEFINES the watched set. Mixing index-derived behaviour with a working-tree
# status or configuration is what round 2 did.
#
# The guarantee: if a normal `git commit` runs immediately after a successful
# --verify without changing the index, the committed tree satisfies the
# invariant.
#
# Not covered, deliberately: `git commit -a`, `git commit <path>` and `--amend`
# all change the index after verification. The guarantee is explicitly
# conditioned on the index not moving, and those move it.
#
# No self-reference: PROJECT_STATUS.md is not itself a watched file, so writing
# the digest into it does not change the digest.
#
# 16 hex characters. This defends against forgetting to refresh a document, not
# against an adversary constructing a collision.

# The blob a path has IN THE INDEX. Used to READ staged content (deps.conf, the
# status file); never to decide the verdict -- see index_entry.
index_blob() {   # <path> -> blob sha, or empty
    git -C "$REPO" rev-parse ":$1" 2>/dev/null
}

# The full stage-0 index ENTRY: mode and object id.
#
# The verdict is about the prospective commit TREE, and a tree entry is
# <mode> <object> <path>. Round 3 hashed the object alone, so
# `git update-index --chmod=+x snapsend.sh` changed the prospective commit while
# leaving the digest equal -- CLEAN, then a commit recording a behaviour-relevant
# change the status never covered. That is not academic: a mode bit on a new
# suite was wrong earlier the same night, and 100755 -> 100644 on a production
# script is worse, because the file simply stops running.
index_entry() {   # <path> -> "<mode> <object>", or empty
    git -C "$REPO" ls-files --stage --full-name -- "$1" 2>/dev/null         | awk 'NR==1 && $3=="0" { print $1, $2 }'
}

# The watched set as the PROSPECTIVE COMMIT defines it: parsed from the staged
# deps.conf, because a config change that adds or drops a watched file is
# itself part of what is about to land.
watched_from_index() {   # -> paths, one per line
    local rel blob
    rel="${CONF#$REPO/}"
    blob="$(index_blob "$rel")"
    [ -n "$blob" ] || return 1
    git -C "$REPO" cat-file blob "$blob" 2>/dev/null | awk '
        /^\[file:/ { f=$0; sub(/^\[file:/,"",f); sub(/\]$/,"",f); cur=f; next }
        /^\[/      { cur="" ; next }
        cur != "" && /^[ 	]*manual[ 	]*=/ {
            line=$0; sub(/^[^=]*=/,"",line)
            n=split(line, parts, ",")
            for (i=1;i<=n;i++) { gsub(/^[ 	]+|[ 	]+$/,"",parts[i]);
                                 if (parts[i]=="project-status") print cur }
        }'
}

status_digest() {   # <watched...> -> hex
    local f
    { for f in $(printf '%s
' "${@}" | sort); do
        local e; e="$(index_entry "$f")"
        if [ -n "$e" ]; then printf '%s %s
' "$e" "$f"; else printf 'ABSENT %s
' "$f"; fi
      done; } | sha256sum | cut -c1-16
}

# Which watched files changed since PROJECT_STATUS.md was last touched. Purely
# a HINT for the operator -- a digest cannot say what went into it, and the
# previous message ("these commits landed after the marker") was the one thing
# genuinely lost in the move. Never part of the verdict.
status_changed_hint() {   # <watched...>
    local commit f now before
    commit="$(git -C "$REPO" log -1 --format=%H -- "$STATUS_FILE" 2>/dev/null)"
    [ -n "$commit" ] || return 0
    for f in "$@"; do
        now="$(index_entry "$f")"
        [ -n "$now" ] || continue
        before="$(git -C "$REPO" ls-tree "$commit" -- "$f" 2>/dev/null | awk '{print $1, $3}')"
        [ -n "$before" ] || continue
        [ -n "$before" ] && [ "$now" != "$before" ] && printf '    %s
' "$f"
    done
}
# A file that is TRACKED must not carry the leftovers of a merge. Added
# 2026-08-22 after I merged them onto main myself: successive merges of
# PROJECT_STATUS.md left NESTED <<<<<<< / ======= / >>>>>>> blocks and three
# copies of the status digest, and every gate stayed green -- the digest check
# hashes the file's CONTENT, so a corrupted file simply hashes to a corrupted
# value and matches itself. Caught by review, not by CI, which is the wrong way
# round for something this mechanical.
#
# Cheap, total, and it applies to every tracked text file rather than just the
# one that happened to break.
no_conflict_markers() {
    echo "== no merge conflict markers in tracked files"
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "  (not a git checkout -- skipped)"; return 0; }
    local hits
    hits=$(git grep -n -I -E '^(<{7}|={7}|>{7})( |$)' -- . 2>/dev/null | grep -vE '^test/impact\.sh:' || true)
    [ -z "$hits" ] && return 0
    echo "  CONFLICT MARKERS. A merge was resolved by hand and not finished:"
    printf '    %s
' "$hits" | head -20
    echo "  Nothing downstream can catch this -- the status digest hashes the"
    echo "  file's content, so a broken file hashes to a broken value and agrees"
    echo "  with itself. Finish the resolution and re-run."
    return 1
}

status_freshness() {
    echo "== PROJECT_STATUS.md still describes the current tree"
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "  (not a git checkout -- skipped)"; return 0; }
    [ -f "$REPO/$STATUS_FILE" ] || { echo "  $STATUS_FILE is missing"; return 1; }

    local marker legacy status_blob
    # EVERYTHING the verdict rests on comes from the index -- that is the
    # finding. Reading the marker from the working tree while reading the
    # watched blobs from the index is precisely the split that let round 2
    # certify one tree while the commit recorded another.
    status_blob="$(index_blob "$STATUS_FILE")"
    if [ -z "$status_blob" ]; then
        echo "  $STATUS_FILE is not in the index, so the next commit would not record it."
        echo "  git add $STATUS_FILE (after ./test/impact.sh --refresh-status)"
        return 1
    fi

    # Extracted without a backreference on purpose: take the whole matched
    # line, then strip the fixed prefix and suffix by parameter expansion.
    # Escaping a sed backreference through every layer that generates or edits
    # this file is exactly how the check silently started reading an EMPTY
    # marker and reporting a missing commit instead of a stale document.
    marker="$(git -C "$REPO" cat-file blob "$status_blob" 2>/dev/null | grep -oE "$STATUS_MARKER_RE" | head -1)"
    marker="${marker#<!-- status-covers-digest: }"
    marker="${marker% -->}"

    # The watched set as the PROSPECTIVE COMMIT defines it, not as the working
    # copy of deps.conf does.
    local -a watched=()
    mapfile -t watched < <(watched_from_index)
    if [ ${#watched[@]} -eq 0 ]; then
        echo "  (no staged file declares the project-status obligation)"; return 0
    fi

    if [ -z "$marker" ]; then
        legacy="$(git -C "$REPO" cat-file blob "$status_blob" 2>/dev/null | grep -oE "$STATUS_LEGACY_RE" | head -1)"
        if [ -n "$legacy" ]; then
            echo "  $STATUS_FILE still carries the OLD commit marker: $legacy"
            echo "  That marker could not be checked before its own commit existed"
            echo "  (REV-20260807-068 F1). Replace it: ./test/impact.sh --refresh-status"
        else
            echo "  $STATUS_FILE has no '<!-- status-covers-digest: <hex> -->' marker."
            echo "  Add it with: ./test/impact.sh --refresh-status"
        fi
        return 1
    fi

    local now
    now="$(status_digest "${watched[@]}")"
    if [ "$marker" != "$now" ]; then
        echo "  STALE. The STAGED $STATUS_FILE does not describe what the next commit would record."
        echo "  recorded: $marker   current: $now"
        local hint
        hint="$(status_changed_hint "${watched[@]}")"
        if [ -n "$hint" ]; then
            echo "  Changed since $STATUS_FILE was last touched:"
            printf '%s
' "$hint"
        fi
        echo "  git add <intended changes>; ./test/impact.sh --refresh-status; git add $STATUS_FILE"
        return 1
    fi
    return 0
}

# The other half of the mechanism: without a command that writes the digest,
# the invariant is unmeetable and the operator is back to a human reminder --
# the class of thing Stage 1 existed to remove.
refresh_status() {
    local -a watched=()
    mapfile -t watched < <(watched_from_index)
    [ ${#watched[@]} -gt 0 ] || die "no staged file declares the project-status obligation (git add it first)"
    [ -f "$REPO/$STATUS_FILE" ] || die "$STATUS_FILE is missing"

    local now line tmp
    now="$(status_digest "${watched[@]}")"
    line="<!-- status-covers-digest: $now -->"
    tmp="$(mktemp)"
    # Replace either marker in place; append after the title if neither exists.
    if grep -qE "$STATUS_MARKER_RE|$STATUS_LEGACY_RE" "$REPO/$STATUS_FILE"; then
        awk -v repl="$line" '
            /^<!-- status-covers-(digest|commit): [0-9a-f]+ -->$/ && !done { print repl; done=1; next }
            { print }
        ' "$REPO/$STATUS_FILE" > "$tmp"
    else
        awk -v repl="$line" 'NR==1 { print; print ""; print repl; next } { print }'             "$REPO/$STATUS_FILE" > "$tmp"
    fi
    cat "$tmp" > "$REPO/$STATUS_FILE"
    rm -f "$tmp"
    echo "status marker refreshed: $now"
    echo "The digest is over the STAGED content, so stage this file too:"
    echo "  git add $STATUS_FILE"
    echo "Until it is staged, --verify fails -- the next commit would not record it."
}


# ---------------------------------------------------------------------------
# Engine freeze (Stage 3). docs/project/ENGINE-FREEZE.md is the definition.
# ---------------------------------------------------------------------------
#
# A freeze that is a sentence in a document is a wish. This is the mechanism.
#
# It compares each frozen file's INDEX ENTRY -- mode and object id, the
# primitive REV-20260807-068 took four rounds to arrive at -- against a recorded
# baseline, and refuses a difference unless `unfreeze:` names a review that
# exists and is not CLOSED. A closed review cannot authorise new work: it was
# answered and the answer was accepted.
#
# Not tamper-proof, and the document says so. Anyone can --refreeze. What it
# removes is the SILENT case: an engine edit cannot land without either a named
# authorising review or a visible baseline reset sitting in the diff.
FREEZE_FILE="docs/project/ENGINE-FREEZE.md"
FROZEN_RE='^<!-- frozen: [^ ]+ [0-7]{6} [0-9a-f]{40} -->$'
UNFREEZE_RE='^<!-- unfreeze: [^ ]+ -->$'

freeze_lines() {   # -> "<path> <mode> <object>" per frozen marker, from the INDEX
    local blob
    blob="$(index_blob "$FREEZE_FILE")"
    [ -n "$blob" ] || return 1
    git -C "$REPO" cat-file blob "$blob" 2>/dev/null         | grep -oE "$FROZEN_RE"         | sed -e 's|^<!-- frozen: ||' -e 's| -->$||'
}

freeze_authorised_by() {   # -> the REV named by unfreeze:, or "-"
    local blob v
    blob="$(index_blob "$FREEZE_FILE")"
    [ -n "$blob" ] || { echo "-"; return; }
    v="$(git -C "$REPO" cat-file blob "$blob" 2>/dev/null | grep -oE "$UNFREEZE_RE" | head -1)"
    v="${v#<!-- unfreeze: }"; v="${v% -->}"
    echo "${v:--}"
}

engine_freeze() {
    echo "== frozen engine files are unchanged, or an open review authorises it"
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "  (not a git checkout -- skipped)"; return 0; }
    [ -f "$REPO/$FREEZE_FILE" ] || { echo "  (no freeze in force)"; return 0; }

    local baseline moved="" path want now rev
    baseline="$(freeze_lines)" || {
        echo "  $FREEZE_FILE is not in the index, so the next commit would not record the freeze."
        return 1; }
    [ -n "$baseline" ] || { echo "  (freeze document declares no files)"; return 0; }

    while read -r path want; do
        [ -n "$path" ] || continue
        now="$(index_entry "$path")"
        [ "$now" = "$want" ] || moved="$moved $path"
    done < <(printf '%s
' "$baseline" | awk '{print $1, $2" "$3}')

    [ -n "$moved" ] || return 0

    rev="$(freeze_authorised_by)"
    if [ "$rev" = "-" ]; then
        # The message used to send the reader to the reviewer route -- "name
        # that review in the unfreeze: marker" -- which has been unusable since
        # the owner removed the reviewer on 2026-08-15. A gate that refuses you
        # and then points at a process that does not exist is worse than no
        # gate: it reads as a bug in the tool rather than a question about the
        # change. Names the live route instead (2026-08-20).
        echo "  FROZEN.$moved changed, and nothing authorises it."
        echo "  A frozen engine is the code every relationship in the fleet runs nightly."
        echo "  If the change is intended:"
        echo "    1. ./test/impact.sh --refreeze     (re-pins the baseline)"
        echo "    2. add an entry to the 'Owner-authorized refreezes' list in $FREEZE_FILE"
        echo "       -- date, files, what changed, and whether it was directed beforehand."
        echo "  Step 2 is the mechanism. Anyone can run step 1, so the baseline reset is"
        echo "  not what makes the change visible; the entry is. A refreeze with no entry"
        echo "  is the silent engine edit this freeze exists to prevent."
        return 1
    fi
    if [ ! -f "$RDIR_FREEZE/$rev.md" ] && ! ls "$RDIR_FREEZE/$rev"-*.md >/dev/null 2>&1; then
        echo "  FROZEN.$moved changed, and unfreeze: names '$rev', which is not a review in this repository."
        return 1
    fi
    if [ -f "$REPO/docs/internal/reviews/closures/$rev.md" ]; then
        echo "  FROZEN.$moved changed, and unfreeze: names '$rev', which is already CLOSED."
        echo "  A closed review cannot authorise new work. Re-take the baseline (--refreeze)"
        echo "  or name the review that asked for THIS change."
        return 1
    fi

    # REV-20260808-070 F2. "Is some review open" is not authorisation. Without
    # this, any unrelated open thread could be named to wave an arbitrary engine
    # edit through -- weaker than what the freeze document claimed.
    #
    # The permission is a REVIEWER-OWNED machine fact in the review artifact,
    # never inferred from prose, and it must name every path that moved.
    local allowed p covered_all=1 unlisted=""
    allowed=" $(freeze_authorises "$rev") "
    for p in $moved; do
        case "$allowed" in *" $p "*) ;; *) covered_all=0; unlisted="$unlisted $p" ;; esac
    done
    if [ "$covered_all" -ne 1 ]; then
        echo "  FROZEN.$unlisted changed, and '$rev' does not authorise$unlisted."
        echo "  The review must carry <!-- authorizes-frozen: <paths> --> naming every"
        echo "  frozen path it asks to change. That marker is the reviewer's to write."
        return 1
    fi
    echo "  authorised by $rev:$moved"
    return 0
}

# The reviewer-owned permission, read from the review artifact.
freeze_authorises() {   # <rev> -> space-separated paths
    local rev="$1" f v
    for f in "$RDIR_FREEZE/$rev.md" "$RDIR_FREEZE/$rev"-*.md; do
        [ -f "$f" ] || continue
        v="$(grep -oE '^<!-- authorizes-frozen:[^>]*-->' "$f" | head -1)"
        [ -n "$v" ] || continue
        v="${v#<!-- authorizes-frozen:}"; v="${v%-->}"
        printf '%s' "$v"
        return 0
    done
}

refreeze() {
    [ -f "$REPO/$FREEZE_FILE" ] || die "$FREEZE_FILE is missing"
    local baseline path tmp now
    baseline="$(grep -oE "$FROZEN_RE" "$REPO/$FREEZE_FILE" | sed -e 's|^<!-- frozen: ||' -e 's| -->$||')"
    [ -n "$baseline" ] || die "$FREEZE_FILE declares no frozen files"
    tmp="$(mktemp)"; cp "$REPO/$FREEZE_FILE" "$tmp"
    while read -r path _; do
        [ -n "$path" ] || continue
        now="$(index_entry "$path")"
        [ -n "$now" ] || die "$path is not in the index; git add it before re-taking the baseline"
        awk -v p="$path" -v e="$now" '
            $0 ~ "^<!-- frozen: " p " " { print "<!-- frozen: " p " " e " -->"; next }
            { print }' "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
        echo "  $path -> $now"
    done < <(printf '%s
' "$baseline")
    awk '/^<!-- unfreeze: /{ print "<!-- unfreeze: - -->"; next } { print }' "$tmp" > "$tmp.new"
    mv "$tmp.new" "$REPO/$FREEZE_FILE"; rm -f "$tmp"
    echo "freeze baseline re-taken from the INDEX; unfreeze reset to -"
    echo "  git add $FREEZE_FILE"
}

# ---------------------------------------------------------------------------
# --graph: mermaid, so the thing can actually be looked at
# ---------------------------------------------------------------------------
# Mermaid node ids may only hold word characters -- a path like
# "test/impact/run.sh" produces "F_test/impact/run_sh", which parses as a link
# and silently breaks the whole diagram.
node_id() { local n="$1"; printf '%s' "${n//[^a-zA-Z0-9_]/_}"; }

emit_graph() {
    local name s consumer
    echo '```mermaid'
    echo 'graph LR'
    for name in $(sections_of_kind file); do
        echo "  F_$(node_id "$name")([\"$name\"])"
    done
    for name in $(sections_of_kind suite); do
        echo "  S_$(node_id "$name")[\"suite: $name<br/>needs ${FIELD[suite:$name|needs]:-?}\"]"
    done
    for name in $(sections_of_kind manual); do
        echo "  M_$(node_id "$name"){{\"manual: $name\"}}"
    done
    for name in $(sections_of_kind contract); do
        echo "  C_$(node_id "$name")[/\"contract: $name\"/]"
    done
    for name in $(sections_of_kind file); do
        while read -r s; do [ -n "$s" ] && echo "  F_$(node_id "$name") --> S_$(node_id "$s")"; done < <(list_of "file:$name" suites)
        while read -r s; do [ -n "$s" ] && echo "  F_$(node_id "$name") -.-> M_$(node_id "$s")"; done < <(list_of "file:$name" manual)
        while read -r s; do [ -n "$s" ] && echo "  F_$(node_id "$name") ==> C_$(node_id "$s")"; done < <(list_of "file:$name" contracts)
    done
    for name in "${!SOURCED_BY[@]}"; do
        for consumer in ${SOURCED_BY[$name]}; do
            echo "  F_$(node_id "$consumer") --o F_$(node_id "$name")"
        done
    done
    echo '```'
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
MODE="diff"
RANGE=""
SUITES_ONLY=0
declare -a EXPLICIT_FILES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --all)    MODE="all" ;;
        --graph)  MODE="graph" ;;
        --verify) MODE="verify" ;;
        --refresh-status) MODE="refresh-status" ;;
        --refreeze) MODE="refreeze" ;;
        # --suites: machine-readable output for the CI gate. Prints the impacted
        # suite names, one per line, instead of the human plan. Emits the sentinel
        # __ALL__ (and nothing else) when the change cannot be selected safely --
        # a file that is not in the graph -- so a caller that greps for its own
        # name also matches __ALL__ and runs. Orthogonal to the input mode: pair
        # it with a range (`--suites origin/main...HEAD`) or with -f.
        --suites) SUITES_ONLY=1 ;;
        -f)       shift; [ $# -gt 0 ] || die "-f needs a file"; EXPLICIT_FILES+=("$1"); MODE="files" ;;
        -V|--version) echo "$VERSION"; exit 0 ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -*)       die "unknown option $1 (try --help)" ;;
        *)        RANGE="$1" ;;
    esac
    shift
done

parse_conf
derive_source_edges

case "$MODE" in
    graph)  emit_graph; exit 0 ;;
    verify) verify; exit $? ;;
    refresh-status) refresh_status; exit $? ;;
    refreeze) refreeze; exit $? ;;
esac

declare -a CHANGED=()
case "$MODE" in
    all)
        for name in $(sections_of_kind file); do CHANGED+=("$name"); done ;;
    files)
        CHANGED=("${EXPLICIT_FILES[@]#./}") ;;
    diff)
        command -v git >/dev/null || die "git not found (use -f to ask about files directly)"
        if [ -n "$RANGE" ]; then
            mapfile -t CHANGED < <(git -C "$REPO" diff --name-only "$RANGE" 2>/dev/null)
            [ ${#CHANGED[@]} -eq 0 ] && mapfile -t CHANGED < <(git -C "$REPO" diff --name-only "${RANGE}..HEAD" 2>/dev/null)
        else
            # Working tree + index + untracked: everything not yet committed.
            mapfile -t CHANGED < <( { git -C "$REPO" diff --name-only HEAD;
                                      git -C "$REPO" ls-files --others --exclude-standard; } 2>/dev/null | sort -u)
        fi ;;
esac

if [ ${#CHANGED[@]} -eq 0 ]; then
    [ "$SUITES_ONLY" = 1 ] && exit 0    # machine mode: nothing changed -> nothing to run
    echo "No changed files${RANGE:+ in $RANGE}."
    exit 0
fi

for f in "${CHANGED[@]}"; do add_file "$f"; done

if [ "$SUITES_ONLY" = 1 ]; then
    # A file the graph does not know about cannot be selected against: fall back
    # to __ALL__ so the CI gate runs every suite rather than silently skipping the
    # coverage of an untracked change. (--verify separately makes such a file fail
    # the graph job, but the gate must be safe on its own, in the same run.)
    if [ ${#UNKNOWN_FILES[@]} -gt 0 ]; then
        echo "__ALL__"
    elif [ ${#NEED_SUITE[@]} -gt 0 ]; then
        printf '%s\n' "${!NEED_SUITE[@]}" | sort
    fi
    exit 0
fi

bold "CHANGED (${#CHANGED[@]})"
printf '  %s\n' "${CHANGED[@]}"
echo
print_plan
exit 0
