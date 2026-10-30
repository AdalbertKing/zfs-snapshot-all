#!/bin/bash
# clean-host-clone.sh <update-state-dir> <repo> [<repo>...]
#
# One-time maintenance, run as root on ONE host: drop the development-repo
# history the release-repo switch left in the host's checkouts (design
# DESIGN-REPO-WYDAN-2026-10-24.md section 9). Not shipped: release/MANIFEST is
# a whitelist. Copy it to the host and run it there, one host at a time, with
# the Owner's consent.
#
# REV-20261030-185: `git gc --prune=now` must never overlap a writer. A clock
# window is not exclusion, so the order here is
#   1. close every entry point: update-hold for root's updater (checked by
#      do_self_update before it touches git), and the hourly `git pull` cron
#      line of each non-root repo owner removed (crontab saved first);
#   2. only then wait until no process works in any of the repos: no cwd under
#      a repo, no command line naming a repo or an update-control verb. With the
#      entry points closed nothing new can start, so once this is empty it
#      stays empty; a run that began before step 1 is waited for, not raced;
#   3. refuse on a leftover *.lock in a repo's .git;
#   4. per repo: delete every ref but main, origin/main and origin/HEAD, expire
#      the reflogs, gc --prune=now, all as the repo's owner;
#   5. validate: fsck, HEAD, origin/main, the rollback target, and every file
#      outside .git (ignored host config included) byte for byte with owner,
#      group and mode; then a fetch that must still fast-forward;
#   6. reopen the entry points (the saved crontab back, the hold removed only
#      if this run created it).
# Any failure stops at once and keeps the barrier: the hold stays, the cron
# lines stay removed, and the message names the saved crontab.
set -Eeuo pipefail

CLEAN_WAIT="${CLEAN_WAIT:-1800}"   # seconds to wait for running updaters
CLEAN_POLL="${CLEAN_POLL:-2}"

die()  { echo "FATAL: $*" >&2; exit 1; }
log()  { echo ">>> $*"; }

[ $# -ge 2 ] || die "usage: $0 <update-state-dir> <repo> [<repo>...]"
STATE="$1"; shift
[ -d "$STATE" ] || die "no update state directory $STATE"
HOLD="$STATE/update-hold"
PREV="$STATE/previous-revision"
cd /

REPOS=()
for r in "$@"; do
    case "$r" in /*) ;; *) die "repo path must be absolute: $r" ;; esac
    [ -d "$r/.git" ] || die "no git checkout at $r"
    r=$(readlink -f "$r")   # the process scan compares resolved cwds
    REPOS+=("$r")
done

# A failed run leaves its barrier and a `barrier` file in its directory. The
# next run adopts it: the original crontabs and "this tool created the hold"
# come from that first run, so reopening restores what was there before it.
PRIOR=""
for d in "$STATE"/clean-host-clone.*; do
    [ -f "$d/barrier" ] && { PRIOR="$d"; break; }   # glob order = oldest first
done
WORK=$(mktemp -d "$STATE/clean-host-clone.$(date +%Y%m%d-%H%M%S).XXXX")
chmod 700 "$WORK"
CREATED_HOLD=0
BARRIER=""
declare -A CRON_SAVED=()
if [ -n "$PRIOR" ]; then
    log "adopting the barrier of the failed run $PRIOR"
    grep -qx 'created_hold=1' "$PRIOR/barrier" && CREATED_HOLD=1
    for f in "$PRIOR"/crontab.*; do
        case "$f" in *.new|*.tmp) continue ;; esac
        [ -f "$f" ] && CRON_SAVED[${f##*/crontab.}]="$f"
    done
fi

fail() {
    echo "FATAL: $*" >&2
    echo "FATAL: stopped with the barrier in place:${BARRIER:- none yet}" >&2
    echo "FATAL: saved state and crontabs: $WORK" >&2
    exit 1
}
trap 'fail "command failed at line $LINENO"' ERR

# The owner whose repo is root's checkout (update-hold, previous-revision); the
# suite sets it to the test user, a host never does.
ROOT_USER="${CLEAN_ROOT_USER:-root}"
owner_of() { local o; o=$(stat -c %U "$1/.git"); [ "$o" = "$ROOT_USER" ] && echo root || echo "$o"; }
as_owner() {   # <owner> <cmd...>
    local o="$1"; shift
    if [ "$o" = "$(id -un)" ]; then "$@"; else runuser -u "$o" -- "$@"; fi
}
cron_line() { printf 'cd %s && git pull --ff-only origin main' "$1"; }

# ---- 1. close the entry points --------------------------------------------
[ ! -L "$HOLD" ] || fail "$HOLD is a symlink"
if [ ! -e "$HOLD" ]; then
    t=$(mktemp "$STATE/.tmp.XXXXXX")
    printf 'clean-host-clone %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$t"
    mv -f "$t" "$HOLD"
    CREATED_HOLD=1
fi
BARRIER="$BARRIER update-hold"

read_crontab() {   # <owner> <file>: "no crontab" is empty, any other failure stops
    local err
    if err=$(crontab -u "$1" -l 2>&1 >"$2"); then return 0; fi
    case "$err" in *"no crontab for"*) : > "$2"; return 0 ;; esac
    fail "cannot read the crontab of $1: $err"
}
declare -A CRON_DONE=()
for r in "${REPOS[@]}"; do
    o=$(owner_of "$r")
    [ "$o" != root ] || continue
    [ -z "${CRON_DONE[$o]:-}" ] || continue
    CRON_DONE[$o]=1
    read_crontab "$o" "$WORK/crontab.$o.now"
    [ -n "${CRON_SAVED[$o]:-}" ] || { cp "$WORK/crontab.$o.now" "$WORK/crontab.$o"; CRON_SAVED[$o]="$WORK/crontab.$o"; }
    cp "$WORK/crontab.$o.now" "$WORK/crontab.$o.new"
    for r2 in "${REPOS[@]}"; do
        [ "$(owner_of "$r2")" = "$o" ] || continue
        grep -vF "$(cron_line "$r2")" "$WORK/crontab.$o.new" > "$WORK/crontab.$o.tmp" || true
        mv "$WORK/crontab.$o.tmp" "$WORK/crontab.$o.new"
    done
    crontab -u "$o" "$WORK/crontab.$o.new"
    for r2 in "${REPOS[@]}"; do
        [ "$(owner_of "$r2")" = "$o" ] || continue
        if crontab -u "$o" -l 2>/dev/null | grep -qF "$(cron_line "$r2")"; then
            fail "the pull line of $o for $r2 is still in its crontab"
        fi
    done
    BARRIER="$BARRIER cron-of-$o(saved:${CRON_SAVED[$o]})"
done
{ echo "created_hold=$CREATED_HOLD"; for o in "${!CRON_SAVED[@]}"; do echo "crontab=${CRON_SAVED[$o]}"; done; } > "$WORK/barrier"

# ---- 2. wait for running writers ------------------------------------------
busy() {   # prints the first process working in a repo, rc 0 if any
    local p cwd cmd r self=$$
    for p in /proc/[0-9]*; do
        p="${p#/proc/}"
        [ "$p" != "$self" ] && [ "$p" != "$BASHPID" ] || continue
        cwd=$(readlink "/proc/$p/cwd" 2>/dev/null) || cwd=""
        cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || cmd=""
        case "$cmd" in *clean-host-clone*) continue ;; esac
        case "$cmd" in
            *update-control.sh*|*"deploy.sh --self-update"*|*"deploy.sh --rollback"*|*"deploy.sh --resume-updates"*)
                echo "$p $cmd"; return 0 ;;
        esac
        for r in "${REPOS[@]}"; do
            case "$cwd/" in "$r"/*) echo "$p cwd=$cwd $cmd"; return 0 ;; esac
            case "$cmd" in *"$r"*) echo "$p $cmd"; return 0 ;; esac
        done
    done
    return 1
}
waited=0
while who=$(busy); do
    [ "$waited" -lt "$CLEAN_WAIT" ] || fail "still busy after ${CLEAN_WAIT}s: $who"
    [ "$waited" -gt 0 ] || log "waiting for: $who"
    sleep "$CLEAN_POLL"; waited=$((waited + CLEAN_POLL))
done
log "no process works in the repos"

# ---- 3. leftover locks -----------------------------------------------------
for r in "${REPOS[@]}"; do
    l=$(find "$r/.git" -maxdepth 3 -name '*.lock' -print -quit)
    [ -z "$l" ] || fail "leftover lock $l -- a git process died there; look before cleaning"
done

# ---- 4/5. clean and validate each repo ------------------------------------
inventory() {   # every path outside .git: name owner group mode size, then content hashes
    ( cd "$1" && find . -path ./.git -prune -o -printf '%P\t%U\t%G\t%m\t%s\n' | LC_ALL=C sort
      find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum )
}
n=0
for r in "${REPOS[@]}"; do
    n=$((n + 1)); o=$(owner_of "$r"); real=$(stat -c %U "$r/.git")
    g() { as_owner "$real" git -C "$r" "$@"; }
    head=$(g rev-parse HEAD)
    main=$(g rev-parse refs/heads/main)
    om=$(g rev-parse refs/remotes/origin/main)
    [ "$head" = "$main" ] || fail "$r: HEAD is not main"
    [ -z "$(g status --porcelain --untracked-files=no)" ] || fail "$r: tracked files changed"
    ! g rev-parse -q --verify refs/stash >/dev/null || fail "$r: has a stash -- someone's work"
    prev=""
    if [ "$o" = root ] && [ -s "$PREV" ]; then
        prev=$(tr -d '[:space:]' < "$PREV")
        g merge-base --is-ancestor "$prev" "$om" || fail "$r: rollback target $prev is not on origin/main"
    fi
    inventory "$r" > "$WORK/inv.$n.before"
    before=$(du -sm "$r/.git" | cut -f1)

    g for-each-ref --format='%(refname)' | while read -r ref; do
        case "$ref" in refs/heads/main|refs/remotes/origin/main|refs/remotes/origin/HEAD) ;;
            *) g update-ref -d "$ref" ;; esac
    done
    g reflog expire --expire=now --all
    g gc --prune=now --quiet

    g fsck --full --no-progress > "$WORK/fsck.$n" 2>&1 || fail "$r: fsck failed (see $WORK/fsck.$n)"
    [ "$(g rev-parse HEAD)" = "$head" ] || fail "$r: HEAD changed"
    [ "$(g rev-parse refs/remotes/origin/main)" = "$om" ] || fail "$r: origin/main changed"
    [ -z "$prev" ] || g cat-file -e "$prev^{commit}" || fail "$r: rollback target $prev lost"
    inventory "$r" > "$WORK/inv.$n.after"
    cmp -s "$WORK/inv.$n.before" "$WORK/inv.$n.after" || fail "$r: files outside .git changed (diff $WORK/inv.$n.before $WORK/inv.$n.after)"
    if [ "$o" = root ]; then
        # root's real update is update-control after the hold is gone (next :15)
        g fetch --quiet origin main
        g merge-base --is-ancestor HEAD FETCH_HEAD || fail "$r: origin main no longer fast-forwards from HEAD"
    else
        # the account's update is exactly its cron command: run it once, under the barrier
        ( cd "$r" && as_owner "$real" git pull --quiet --ff-only origin main ) || fail "$r: git pull --ff-only failed after the clean"
    fi
    log "$r: .git ${before} MB -> $(du -sm "$r/.git" | cut -f1) MB, HEAD $(printf '%.8s' "$head")"
done

# ---- 6. reopen --------------------------------------------------------------
trap - ERR
for o in "${!CRON_SAVED[@]}"; do
    crontab -u "$o" "${CRON_SAVED[$o]}" || fail "restoring the crontab of $o"
    crontab -u "$o" -l 2>/dev/null | cmp -s - "${CRON_SAVED[$o]}" || fail "the crontab of $o differs from the saved one"
done
[ "$CREATED_HOLD" = 0 ] || rm -f "$HOLD"
rm -f "$WORK/barrier"
[ -z "$PRIOR" ] || rm -f "$PRIOR/barrier"
log "done; entry points reopened"
