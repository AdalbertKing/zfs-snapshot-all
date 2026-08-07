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

VERSION='v1.0'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF="${IMPACT_CONF:-$SCRIPT_DIR/deps.conf}"

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

    status_freshness || rc=1
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
# REVIEW PROTOCOL V2 (docs/project/PROTOCOL.md): review state is DERIVED from
# machine facts, so there is nothing here to police any more. ledger_coherence
# and the review-head marker existed only to catch drift in a hand-maintained
# table; a generated table cannot drift from what generates it. Both deleted
# rather than kept "just in case" -- a check nobody can make fail is noise.
protocol_verify() {
    echo "== review ledger agrees with the review artifacts"
    "$REPO/test/reviewctl.sh" --verify 2>&1 | sed 's/^/  /'
    return "${PIPESTATUS[0]}"
}

STATUS_FILE="docs/PROJECT_STATUS.md"
STATUS_MARKER_RE='^<!-- status-covers-commit: ([0-9a-f]{7,40}) -->$'
status_freshness() {
    echo "== PROJECT_STATUS.md still describes the current tree"
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "  (not a git checkout -- skipped)"; return 0; }
    [ -f "$REPO/$STATUS_FILE" ] || { echo "  $STATUS_FILE is missing"; return 1; }

    local marker
    # Extracted without a backreference on purpose: take the whole matched
    # line, then strip the fixed prefix and suffix by parameter expansion.
    # Escaping a sed backreference through every layer that generates or edits
    # this file is exactly how the check silently started reading an EMPTY
    # marker and reporting a missing commit instead of a stale document.
    marker="$(grep -oE "$STATUS_MARKER_RE" "$REPO/$STATUS_FILE" 2>/dev/null | head -1)"
    marker="${marker#<!-- status-covers-commit: }"
    marker="${marker% -->}"
    if [ -z "$marker" ]; then
        echo "  $STATUS_FILE has no '<!-- status-covers-commit: <sha> -->' marker."
        echo "  Add it naming the last behaviour-changing commit the document describes."
        return 1
    fi
    git cat-file -e "${marker}^{commit}" 2>/dev/null || {
        echo "  the marker names '$marker', which is not a commit in this repository"; return 1; }

    # Which files oblige a status refresh: whatever deps.conf says, so the two
    # never disagree.
    local -a watched=()
    local f
    for f in "${!SEC_KIND[@]}"; do
        case "$f" in file:*) ;; *) continue ;; esac
        list_of "$f" manual | grep -qx project-status && watched+=("${f#file:}")
    done
    [ ${#watched[@]} -gt 0 ] || { echo "  (no file declares the project-status obligation)"; return 0; }

    local behind
    behind="$(git log --format='%h %s' "${marker}..HEAD" -- "${watched[@]}" 2>/dev/null)"
    if [ -n "$behind" ]; then
        echo "  STALE. These behaviour-changing commits landed after the marker ($marker):"
        printf '%s
' "$behind" | sed 's/^/    /'
        echo "  Refresh $STATUS_FILE and move the marker to the commit it now describes."
        return 1
    fi
    return 0
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
declare -a EXPLICIT_FILES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --all)    MODE="all" ;;
        --graph)  MODE="graph" ;;
        --verify) MODE="verify" ;;
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
    echo "No changed files${RANGE:+ in $RANGE}."
    exit 0
fi

bold "CHANGED (${#CHANGED[@]})"
printf '  %s\n' "${CHANGED[@]}"
echo

for f in "${CHANGED[@]}"; do add_file "$f"; done
print_plan
exit 0
