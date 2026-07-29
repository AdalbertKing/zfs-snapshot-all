#!/bin/bash
set -o pipefail
# gen-cron.sh (run with -V for version; see git log for full changelog)
# ------------------------------------------------------------------------------
# Description: generates a crontab block for snapsend.sh/delsnaps.sh from a
# host-local INI config file, instead of hand-editing scattered cron lines.
#
# Usage: gen-cron.sh [-c CONFIG] [--install] [-V]
# Options:
#   -c <FILE>   Config file to read (default: jobs.<hostname -s>.conf next to this script)
#   --install   Install the generated block into this user's crontab (idempotent:
#               replaces the existing managed block instead of appending). Without
#               this flag, the block is only printed to stdout for review.
#   -V          Print version and exit
#
# CONFIG FORMAT v4 -- typed sections. Every section header (except [defaults])
# carries an explicit TYPE prefix, split on the first ':'. The type declares
# WHICH operations that section runs; the name after ':' is a literal ZFS path
# or a tier name. There is NO magic: a target is always a path you wrote down.
# The script never infers "same VM, two copies" -- rpool/data/vm1 and
# hdd/backups/pve1/rpool/data/vm1 are two different, unrelated objects.
#
#   [defaults]
#       host_label = pve2                 # used to auto-build notify text
#       dst        = hdd/backups/pve2     # optional -- omit for local-only (no send target)
#
#   [template:<tier>]                     # a tier's full lifecycle (cadence + retention)
#       send_schedule    = <5-field cron>  # omit if this tier never sends
#       prefix           = <snapshot name prefix passed to snapsend.sh -m>
#       notify_word      = backup          # default "backup"; e.g. "snapshot" for local jobs
#       tier_label       = <word>          # display name for the tier in notify text
#                                          # (default: the tier itself; e.g. store_hourly -> hourly)
#       notify_raw       = <literal notify-fail.sh text, bypasses auto-synthesis>
#       prune_schedule   = <5-field cron>  # omit if this tier never prunes
#       pattern          = <snapshot name prefix delsnaps.sh matches>
#       keep             = <N>             # count-based retention -> -<TIER_LETTER><N>
#       retain           = <raw delsnaps.sh flags>  # e.g. "-H24"; mutually exclusive with keep
#       notify_raw_prune = <literal notify-fail.sh text for the prune line>
#       monitor_warn     = <duration>      # e.g. 90m/3h/9d -- age of the newest snapshot
#       monitor_crit     = <duration>      # matching 'pattern' that trips WARN/CRIT. Both
#                                          # must be set together, or neither. Omit both to
#                                          # not monitor this tier. Requires 'pattern' too.
#       monitor_schedule = <5-field cron>  # default: */15 * * * * if monitor_warn/crit are set
#
#   [dataset:<zfs/path>]                  # a dataset you own end-to-end
#       use_template = <tier>[,<tier>...]  # comma list -- one dataset can span several tiers
#       notify       = <short label>
#       flags        = <snapsend.sh flags, or snapget.sh flags when 'src' is set>
#       flags_<tier> = <per-tier flags override>
#       autotune     = yes|no              # default yes; 'no' suppresses the
#                                          # automatic -A described below
#       quiesce      = no|agent|sync|auto  # default no; quiesce the Proxmox guest
#                                          # that owns this dataset before
#                                          # snapshotting it (snapsend.sh -q)
#       dst          = <target>            # PUSH: <zfs/path> is the local SOURCE,
#                                          # snapsend.sh sends TO dst (remote if it
#                                          # contains ':', else local-to-local).
#                                          # Omit entirely for a local snapshot only.
#       src          = <[user@]host:path>  # PULL: 'path' is the LITERAL,
#                                          # real name on the remote host --
#                                          # exactly what `zfs list` shows
#                                          # there, not a base (snapget.sh
#                                          # v2.61+: whichever side is READ is
#                                          # given literally; whichever side
#                                          # is WRITTEN gets an optional base.
#                                          # For a pull the remote is READ, so
#                                          # it is given literally here). The
#                                          # section's own <zfs/path> is the
#                                          # local DESTINATION as always, and
#                                          # MUST end with 'path' verbatim
#                                          # (e.g. local dataset:<zfs/path> =
#                                          # hdd/backups/x/pool/data, src =
#                                          # host:pool/data) -- generation
#                                          # dies with a clear message if it
#                                          # does not, since there is no base
#                                          # that could reconcile an
#                                          # unrelated local name with a
#                                          # fixed remote one. If <zfs/path>
#                                          # equals 'path' exactly, the
#                                          # generated call omits the local
#                                          # base entirely (sync mode).
#                                          # Setting both dst and src on the
#                                          # same section is rejected -- one
#                                          # section is one direction. A
#                                          # [defaults] 'dst' that other push
#                                          # datasets rely on is NOT
#                                          # automatically blank here: a pull
#                                          # dataset in a config that also has
#                                          # a global default dst MUST
#                                          # override it explicitly ('dst = ',
#                                          # blank) or generation refuses
#                                          # (looks ambiguous: both a resolved
#                                          # dst AND a resolved src).
#                                          # Pull datasets never group: each
#                                          # has its own literal remote name,
#                                          # so merging into one snapget.sh
#                                          # call never makes sense the way it
#                                          # does for push.
#       ...any template field can be overridden here (dst, send_schedule,
#          prune_schedule, keep, retain, notify_raw, notify_raw_prune)
#     A dataset section runs, scoped to ITS OWN path, non-recursively:
#       create(+send)  if its tiers resolve send_schedule
#       self-prune     if its tiers resolve prune_schedule (retention defined
#                      right here, at the dataset, independent of every other)
#     Datasets sharing a resolved (send_schedule,dst,prefix,flags) merge into one
#     send line; datasets sharing a resolved (prune_schedule,pattern,keep/retain)
#     merge into one prune line that lists them BY FULL PATH, non-recursively.
#     Inline prune NEVER collapses to a recursive -R sweep.
#
#   [prune:<scope>]                       # standalone, additive prune of a scope
#       use_template = <tier>[,<tier>...]  # borrows each tier's prune policy
#       recursive    = yes|no              # default no; yes -> delsnaps.sh -R (subtree)
#       clear_cut    = yes|no              # default no; yes -> delsnaps.sh -F (destroy -R clones)
#       prune        = yes|no              # default yes; no -> emit NO delsnaps line,
#                                          # making this section a monitor carrier only.
#                                          # Use for a leaf already covered by a recursive
#                                          # [prune:<parent>]: repeating the rule here would
#                                          # emit a second delsnaps line on the same schedule,
#                                          # pattern and snapshots, and the two RACE -- the
#                                          # loser reports "could not find any snapshots to
#                                          # destroy" and alerts. Requires monitor_warn/crit,
#                                          # or the section would emit nothing at all.
#       ssh_flags    = <-p/-k/-c/-K/-O only>  # SSH connection options for a REMOTE
#                                          # scope (host:dataset) -- port, known_hosts,
#                                          # cipher, private key, extra -o. See
#                                          # delsnaps.sh -c/-K/-O. Warned about (not
#                                          # rejected) on a local scope, same treatment
#                                          # as flags="-z" on a local send dst.
#       gfs          = yes|no              # default no; yes -> ONE combined
#                                          # delsnaps.sh -G line covering every
#                                          # tier in use_template at once
#                                          # (cascading GFS ladder) instead of
#                                          # one flat-count line per tier. Each
#                                          # tier's retain/keep must resolve to
#                                          # a single count flag (-H/-D/-W/-M/-Y
#                                          # <N>); age-based retain= or a mixed
#                                          # multi-flag string is rejected. Runs
#                                          # on the FIRST tier's own
#                                          # prune_schedule (list use_template
#                                          # finest-first). Each tier's own
#                                          # 'pattern' still drives ITS OWN
#                                          # monitor untouched -- gfs does not
#                                          # change monitoring, only how
#                                          # retention is grouped.
#       gfs_pattern  = <shared prefix>     # REQUIRED when gfs=yes. The ONE
#                                          # prefix the combined ladder matches
#                                          # against -- deliberately separate
#                                          # from each tier's own 'pattern',
#                                          # since the ladder has to see every
#                                          # contributing tier's snapshots to
#                                          # bucket them by elapsed time. See
#                                          # delsnaps.sh's own header ("GFS
#                                          # LADDER") for the full mechanism.
#       notify       = <short label>
#     For scopes you do NOT create locally: a backup store receiving pushes from
#     other hosts, foreign/received subtrees. Emits one delsnaps line per tier.
#     monitor_warn/monitor_crit are REJECTED on a remote (host:dataset) scope --
#     check-snap-age.sh is local-only by design (see its own header), so a monitor
#     riding a remote scope would run `zfs list` locally against a string like
#     "user@host:tank/data" and report a permanent false UNKNOWN. Run
#     check-snap-age.sh in ITS OWN cron line on the host that actually owns the
#     dataset instead.
#
#   [prune-bookmarks:<scope>]             # standalone prune of ORPHANED bookmarks
#       schedule     = <5-field cron>      # required
#       age          = <raw delsnaps.sh age flags>  # e.g. "-d30"; required, age-only
#                                          # (count-based makes no sense for bookmarks)
#       pattern      = <bookmark name prefix>  # default "tgt-" -- what
#                                          # record_send_bookmark (lib-zfs-snap.sh) names
#                                          # its own bookmarks; override only if you know why
#       recursive    = yes|no              # default no; yes -> delsnaps.sh -B -R
#       ssh_flags    = <-p/-k/-c/-K/-O only>  # same as [prune:]'s ssh_flags. The
#                                          # real use case: bookmarks from a snapget.sh
#                                          # PULL accumulate on the REMOTE source, so
#                                          # cleaning them up needs to reach that host.
#       notify       = <short label>
#     snapsend.sh/snapget.sh refresh a per-target bookmark on every successful
#     transfer, but nothing removes one for a target that stops being used --
#     this is that cleanup. No tiers/templates: bookmark pruning is a single
#     age-threshold operation on SOURCE datasets, unrelated to any send/prune
#     tier's own schedule. Pick 'age' well past the longest real backup gap you
#     expect, or an offline/paused job's still-live bookmark gets pruned too
#     early. Not monitored by check-snap-age.sh (that tool watches snapshot
#     staleness, not bookmarks) and not cross-checked against snapshot prune
#     patterns (different ZFS object type, same-scope overlap is not a hazard
#     the way it is between two snapshot-prune rules).
#
#   [excluded:<prefix>]                   # how much of a RESERVED prefix to protect
#       keep         = <N> | all           # required. How many of the NEWEST
#                                          # snapshots carrying <prefix> delsnaps.sh
#                                          # must leave alone, PER DATASET.
#     Proxmox owns __replicate_/__migration__/vzdump snapshots, and pruning one out
#     from under pvesr breaks the replication chain irreparably -- so all three
#     default to "all" (absolute protection) and stay that way unless a section
#     here says otherwise. Emits `delsnaps.sh -P "<prefix>:<keep>"` onto every
#     snapshot-prune line the config produces (never onto the -B bookmark line:
#     the guard never applied to bookmarks).
#
#     Why a count rather than a boolean: on a SOURCE, pvesr keeps exactly one of
#     its own snapshots per dataset and deletes the rest itself, so the question
#     never arises. On a BACKUP TARGET that received a replication stream (-r/-I
#     carry every snapshot the source has, not just the ones this tool made)
#     nothing prunes them and they accumulate forever, while only the newest has
#     any value for a future incremental. Absolute protection made that garbage
#     immortal.
#
#     Global, not per-scope: protection is a property of the snapshot NAME, not
#     of where it lives, and a per-scope version would let the same reserved
#     prefix be protected on one dataset and prunable on another -- exactly the
#     kind of split that goes wrong quietly.
#
#     This only RELAXES a guard; it never widens a match. An older reserved
#     snapshot still has to match the run's own 'pattern' to be deleted, so a
#     routine automated_hourly_ job cannot touch one even at keep = 0.
#
# There is no separate [monitor:] section. A staleness check (check-snap-age.sh)
# is derived AUTOMATICALLY, per tier, wherever a 'pattern' already resolves for
# pruning -- i.e. every inline [dataset:] self-prune and every [prune:<scope>]
# tier -- as long as that tier's template also sets monitor_warn/monitor_crit.
# No new syntax: monitor just rides the same (scope,pattern) pair prune already
# needed, scoped and recursive the same way that prune operation is.
#
# flags="-f" (force full send) and flags="-n" (dry-run) are rejected at generate
# time: -f in a standing cron job means destroy-and-reseed the target every run,
# -n never actually sends anything -- neither makes sense as a recurring job.
#
# flags="-z"/"-Z"/"-g" on a LOCAL dst produce a WARNING on stderr (never fatal).
# snapsend v2.32+ drops compression when both ends are the same host, so the flag
# is dead weight that misdescribes the job. stdout stays clean either way.
#
# quiesce is NOT inferred, unlike -A. Whether a guest can be frozen depends on
# what runs inside it and how much a brief write stall costs there, and neither is
# visible from a dataset name -- so it is opt-in per dataset and simply becomes
# `-q <mode>`. Warned about when combined with -e, which reuses an existing
# snapshot and so has nothing for a freeze to make consistent.
#
# -A (link auto-tuning) is ADDED automatically to every send whose resolved 'dst'
# is remote, i.e. contains ':' -- the same test snapsend.sh itself uses to decide
# whether to open an ssh connection. It measures the link and the data, then
# decides whether compressing is worth it; over a real link that is worth ~29%,
# and on a local target it can measure nothing at all, so the flag is added
# exactly where it can pay off. Not added if 'flags' already has -A, nor if it
# names a compressor explicitly (-z/-Z/-g), because an explicit flag beats -A
# inside snapsend and the line would otherwise announce a no-op every run.
# Suppress with autotune=no on the dataset, template or [defaults].
#
# Every resolved prune operation is validated against every other operation on
# the SAME literal scope: since delsnaps.sh matches by literal string prefix, a
# pattern that is a prefix of (or equal to) another pattern on that scope would
# let one tier's snapshots leak into another tier's retention run. Rejected.
#
# prune-vs-inline overlap ("B" semantics): if a recursive [prune:S] and an inline
# [dataset:X] both cover the same snapshots, BOTH lines are emitted and both run;
# net effect is the strictest keep wins. The generator does NOT guard this --
# prune priority is deliberate user discipline, not enforced magic.
###############################################################################
#BEGIN 1 [GLOBAL CONFIGURATION]
###############################################################################
VERSION='v4.24'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$SCRIPT_DIR}"
NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-/root/scripts/notify-fail.sh}"
WARN_SCRIPT="${WARN_SCRIPT:-/root/scripts/notify-warn.sh}"
DIGEST_SCRIPT="${DIGEST_SCRIPT:-/root/scripts/alert-digest.sh}"
DIGEST_SCHEDULE="${DIGEST_SCHEDULE:-0 7 * * *}"
CRON_LOG="${CRON_LOG:-/root/scripts/cron.log}"
LOCKFILE="${GEN_CRON_LOCKFILE:-/var/run/gen-cron.install.lock}"
# How many trailing lines of a failed job's output travel into the alert. Enough
# for a ZFS error plus the line that provoked it, short enough that a mail stays
# a mail even when eight datasets fail in one run.
DETAIL_LINES="${DETAIL_LINES:-8}"
MARKER_BEGIN="# BEGIN zfs-backup-managed (generated by gen-cron.sh -- do not hand-edit, re-run gen-cron.sh instead)"
MARKER_END="# END zfs-backup-managed"

declare -a JOB_LINES=()
declare -a RETAIN_LINES=()
declare -a MONITOR_LINES=()
# Global -P fragment built from [excluded:] sections; empty means "defaults".
PROTECT_FLAGS=""

SEP=$'\x1c'   # field separator inside one encoded entity string
LSEP=$'\x1e'  # entity separator inside one group's member list

declare -A INI=()
declare -a SECTION_ORDER=()
declare -A SECTION_KIND=()    # header -> defaults|template|dataset|prune
declare -A SECTION_NAME=()    # header -> the name after ':' (path/tier/scope); "" for defaults
declare -A SEEN_SECTION=()
CUR_SECTION=""

declare -A TIER_LETTER=( [hourly]=H [daily]=D [weekly]=W [monthly]=M [yearly]=Y [annual]=Y )
###############################################################################
#END 1

###############################################################################
#BEGIN 2 [HELPERS]
###############################################################################
die() { echo "gen-cron.sh: error: $*" >&2; exit 1; }
# stderr, never stdout: stdout IS the crontab block, and `gen-cron.sh > file` or
# --install must not have a diagnostic land inside it.
warn() { echo "gen-cron.sh: warning: $*" >&2; }

usage() {
    cat <<'EOF'
gen-cron.sh -- generate a crontab block for snapsend.sh/delsnaps.sh from an
INI config of typed sections (config format v4).

Usage: gen-cron.sh [-c CONFIG] [--install] [-V]
  -c <FILE>   Config file (default: jobs.<hostname -s>.conf next to this script)
  --install   Install/replace the managed block in this user's crontab
              (idempotent). Without it, the block is printed to stdout.
  -V          Print version and exit
  -h          Print this help

Section types (header split on first ':'):
  [defaults]              host_label, optional dst
  [template:<tier>]       a tier's cadence + retention policy
  [dataset:<path>]        owned dataset: create+send/pull (dst=push, src=pull)
                          + inline self-prune (own path)
  [prune:<scope>]         standalone additive prune (recursive=/clear_cut= opt-in)
  [prune-bookmarks:<scope>]  age-based cleanup of orphaned snapsend/snapget bookmarks

Staleness monitoring (check-snap-age.sh) is NOT a section type -- set
monitor_warn/monitor_crit on a [template:] and it rides every [dataset:]/
[prune:] tier that already resolves that template's 'pattern'.

See the comment header of this script for the full field reference.
EOF
}

# -A only ever pays off over a real link, and gen-cron already knows whether
# there is one -- it just resolved 'dst'. So it adds the flag itself instead of
# leaving it to be remembered per dataset: forgetting it is silent, and the whole
# point of -A is to make a decision nobody remembers to make.
#
# "Remote" is decided by the SAME test snapsend.sh/snapget.sh use: a ':' in the
# target (see their section 5B). ZFS does allow ':' inside a dataset name, so
# this is not a bulletproof reading of the string -- it is deliberately the
# CONSUMER's reading, because what decides whether -A can measure anything is
# whether the script receiving this line opens an ssh connection, not what is
# theoretically nameable.
#
# 'autotune = no' opts out. 'yes' is not the opposite of that: it means "where it
# applies", so a [defaults] covering both local and remote datasets stays valid
# instead of failing on the local ones.
#
# Validation lives in lint_autotune, NOT here: this function is called inside a
# command substitution, where die() would exit the subshell and leave the script
# running with rc=0 and the flag quietly dropped. Caught by
# negative/autotune-bad-value, which is why it is a separate call.
lint_autotune() {
    local want="$1" ctx="$2"
    case "$want" in
        ""|yes|on|1|auto|no|off|0) return 0 ;;
        *) die "$ctx: autotune='$want' -- expected yes or no" ;;
    esac
}

maybe_add_autotune() {
    local flags="$1" dst="$2" want="$3" tok
    case "$want" in
        no|off|0) printf '%s' "$flags"; return 0 ;;
    esac
    # Local target: nothing to measure, and snapsend would drop compression
    # anyway (v2.32+). '@' with no ':' is snapsend/snapget's SYNC mode (bare
    # user@host, mirrors to the identical path) -- just as remote as host:base,
    # so it must not be misread as local here.
    case "$dst" in
        *:*|*@*) ;;
        *)   printf '%s' "$flags"; return 0 ;;
    esac
    for tok in $flags; do
        case "$tok" in
            -A) printf '%s' "$flags"; return 0 ;;
            # An explicit compressor beats -A inside snapsend, which then logs
            # that it stood down. Adding -A here would emit a cron line that
            # announces a no-op on every run, so honour the flag and say nothing.
            -z|-Z|-g) printf '%s' "$flags"; return 0 ;;
        esac
    done
    if [ -n "$flags" ]; then printf '%s -A' "$flags"; else printf -- '-A'; fi
}

# quiesce = agent|fs|auto|no. Unlike -A this is NOT inferred: whether a guest can
# be frozen depends on what runs inside it and how much a brief write stall costs
# there, and neither is visible from a dataset name. So it is opt-in per dataset.
#
# Validated outside the command substitution that uses it -- see lint_autotune for
# why that separation is not optional.
#
# A pull dataset's snapshot is created on the REMOTE host (snapget.sh ssh's over
# and runs `zfs snapshot` there) -- quiescing the guest that owns it would mean
# freezing across that same ssh hop and thawing reliably even if the connection
# drops mid-run. snapsend.sh's quiesce_freeze/quiesce_thaw_all in lib-zfs-snap.sh
# only ever shell out to local `qm`/`pct`, and snapget.sh's getopts has no -q at
# all, so today this is simply rejected rather than silently generating a cron
# line snapget.sh cannot parse (illegal option -- q).
lint_quiesce() {
    local want="$1" ctx="$2" direction="$3"
    case "$want" in
        ""|no) return 0 ;;
        agent|sync|auto)
            [ "$direction" = "pull" ] && die "$ctx: quiesce='$want' on a pull dataset -- the snapshot is taken on the REMOTE host over ssh, and snapget.sh has no -q support to freeze a guest there. Quiesce only the push side of a pair, or drop 'quiesce' here."
            return 0
            ;;
        fs) die "$ctx: quiesce=fs is gone -- ZFS does not implement FIFREEZE, so no ZFS mountpoint can be frozen from the host. Use quiesce=sync for containers (a flush, not a freeze)" ;;
        *) die "$ctx: quiesce='$want' -- expected no, agent, sync or auto" ;;
    esac
}

# -e means "use the snapshot that is already there", so there is nothing being
# created for a freeze to make consistent. Emitting -q anyway would put a promise
# in the crontab that the run cannot keep.
maybe_add_quiesce() {
    local flags="$1" want="$2" tok
    case "$want" in
        ""|no) printf '%s' "$flags"; return 0 ;;
    esac
    for tok in $flags; do
        case "$tok" in
            -q) printf '%s' "$flags"; return 0 ;;
        esac
    done
    if [ -n "$flags" ]; then printf '%s -q %s' "$flags" "$want"; else printf -- '-q %s' "$want"; fi
}

# Rejects flags that never make sense in a standing/recurring cron job, and
# warns about ones that are merely dead.
#
# -z/-Z/-g on a LOCAL target is a warning, not an error: since snapsend v2.32 the
# script drops compression there anyway (the pipeline would be
# `zfs send | zstd -c | mbuffer | zstd -d -c | zfs recv` -- both ends paid for,
# with only an in-memory pipe between them), so the flag costs nothing but says
# something untrue about the job. Deliberately NOT fatal: it is harmless at
# runtime, and a regeneration that suddenly refuses to produce a crontab is worse
# than one that produces a correct crontab and tells you to tidy the config.
lint_flags() {
    local flags="$1" ctx="$2" dst="${3:-}" tok
    for tok in $flags; do
        case "$tok" in
            -f) die "$ctx: flag -f (force full send) not allowed in a recurring job -- it would destroy and re-seed the target every run" ;;
            -n) die "$ctx: flag -n (dry-run) not allowed in a recurring job -- it never actually sends anything" ;;
            -q)
                case " $flags " in
                    *" -e "*) warn "$ctx: -q has no effect together with -e -- -e reuses an existing snapshot, so there is nothing being created for a freeze to make consistent" ;;
                esac
                ;;
            -z|-Z|-g)
                # Three cases, not two. An EMPTY dst is not "a local target" --
                # it means no target at all: snapsend gets one argument, creates
                # a snapshot and transfers nothing. Saying "dst '' is local"
                # there would be literally untrue and would send someone looking
                # for a target that was never configured.
                case "$dst" in
                    *:*|*@*) ;;   # remote (host:base, or bare user@host sync mode) -- compression is real work there
                    "")  warn "$ctx: flag $tok has no effect -- this job has no 'dst', so it only creates a snapshot and never transfers anything. Drop it." ;;
                    *)   warn "$ctx: flag $tok has no effect -- dst '$dst' is local, and snapsend.sh (v2.32+) skips compression when both ends are the same host. Drop it, or point dst at a remote target." ;;
                esac
                ;;
        esac
    done
}

# Validates ssh_flags on a [prune:]/[prune-bookmarks:] section. Deliberately
# NARROW -- only -p/-k/-c/-K/-O are accepted, because everything else delsnaps.sh
# takes either has its own dedicated field already (-R -> recursive=, -F ->
# clear_cut=, -B is the section TYPE, retention -> retain=/age=) or never makes
# sense in a standing job (-n). Allowing them through ssh_flags too would be a
# second way to say the same thing, or a way to silently override what the
# dedicated field already decided -- rejected, not warned, because there is no
# legitimate reason to reach for it.
#
# On a LOCAL scope this is a WARNING, not a rejection, mirroring flags="-z" on a
# local send dst: harmless at runtime (delsnaps.sh only opens ssh for entries
# that actually look remote), but almost certainly a sign the scope itself is
# wrong -- an operator who typed ssh_flags meant to reach a host.
lint_ssh_flags() {
    local flags="$1" ctx="$2" scope="$3" tok
    [ -z "$flags" ] && return 0
    case "$scope" in
        *:*) ;;
        *) warn "$ctx: ssh_flags is set but scope '$scope' has no ':' -- delsnaps.sh only opens ssh for entries that look remote, so this has no effect unless the scope itself is missing a host prefix" ;;
    esac
    for tok in $flags; do
        case "$tok" in
            -p|-k|-c|-K|-O) ;;
            -R) die "$ctx: ssh_flags has -R -- use this section's own 'recursive = yes' instead" ;;
            -F) die "$ctx: ssh_flags has -F -- use this section's own 'clear_cut = yes' instead" ;;
            -B) die "$ctx: ssh_flags has -B -- bookmark mode is [prune-bookmarks:], not a flag to add here" ;;
            -n) die "$ctx: ssh_flags has -n (dry-run) -- never actually prunes anything as a recurring job" ;;
            -*) die "$ctx: ssh_flags has '$tok' -- only -p/-k/-c/-K/-O are accepted here (SSH connection options); retention and recursion have their own fields" ;;
        esac
    done
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}
###############################################################################
#END 2

###############################################################################
#BEGIN 3 [INI PARSING + FIELD RESOLUTION]
###############################################################################
# Parses typed sections. The raw header string (e.g. "template:hourly",
# "dataset:rpool/data/vm-106-disk-0", or "defaults") is used verbatim as the
# INI key prefix and the section's identity -- kind+name together, so a
# [dataset:X] and a [prune:X] never collide.
parse_ini() {
    local file="$1" line trimmed key val hdr kind name
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        trimmed="$(trim "$line")"
        [ -z "$trimmed" ] && continue
        if [[ "$trimmed" =~ ^\[(.+)\]$ ]]; then
            hdr="$(trim "${BASH_REMATCH[1]}")"
            if [ "$hdr" = "defaults" ]; then
                kind="defaults"; name=""
            else
                case "$hdr" in
                    *:*) : ;;
                    *) die "section '[$hdr]' has no type prefix (expected defaults, or template:/dataset:/prune: followed by a name)" ;;
                esac
                kind="$(trim "${hdr%%:*}")"
                name="$(trim "${hdr#*:}")"
                case "$kind" in
                    template|dataset|prune|prune-bookmarks|excluded) : ;;
                    *) die "unknown section type '$kind' in '[$hdr]' (expected template/dataset/prune/prune-bookmarks/excluded)" ;;
                esac
                [ -n "$name" ] || die "section '[$hdr]' has an empty name after '$kind:'"
            fi
            [ -z "${SEEN_SECTION[$hdr]+x}" ] || die "duplicate section '[$hdr]' in $file"
            SEEN_SECTION["$hdr"]=1
            CUR_SECTION="$hdr"
            SECTION_ORDER+=("$hdr")
            SECTION_KIND["$hdr"]="$kind"
            SECTION_NAME["$hdr"]="$name"
            continue
        fi
        if [[ "$trimmed" == *"="* ]] && [ -n "$CUR_SECTION" ]; then
            key="$(trim "${trimmed%%=*}")"
            val="$(trim "${trimmed#*=}")"
            [ -z "${INI[${CUR_SECTION}${SEP}${key}]+x}" ] || die "duplicate field '$key' in section '[$CUR_SECTION]' in $file -- the first value would be silently overwritten"
            INI["${CUR_SECTION}${SEP}${key}"]="$val"
        fi
    done < "$file"
}

ini_has() { [ -n "${INI[$1${SEP}$2]+x}" ]; }
ini_get() { printf '%s' "${INI[$1${SEP}$2]}"; }

# resolve_field FIELD DS TMPL DEFAULTS -- prints value, return 1 if unresolved.
# Any of DS/TMPL/DEFAULTS may be "" to skip that layer. Each is a section header.
resolve_field() {
    local field="$1" ds="$2" tmpl="$3" defaults="$4"
    if [ -n "$ds" ] && ini_has "$ds" "$field"; then ini_get "$ds" "$field"; return 0; fi
    if [ -n "$tmpl" ] && ini_has "$tmpl" "$field"; then ini_get "$tmpl" "$field"; return 0; fi
    if [ -n "$defaults" ] && ini_has "$defaults" "$field"; then ini_get "$defaults" "$field"; return 0; fi
    return 1
}

# Same as resolve_field, but for fields where a BLANK value is exactly as
# broken as a missing one -- 'pattern' and 'prefix' have no sensible empty
# meaning (unlike 'dst', where blank legitimately means "no target, snapshot
# only"). ini_has only tests whether the key exists, so "pattern = " with
# nothing after the '=' used to read as "resolved" with an empty string --
# a config typo that silently produced a delsnaps.sh line with an empty
# pattern (matches every snapshot) or a snapsend.sh -m "" (bare-timestamp
# snapshot no retention job can ever match). Use this instead of resolve_field
# wherever an empty resolved value would be just as wrong as no value at all.
require_field() {
    local field="$1" ds="$2" tmpl="$3" defaults="$4" val
    val="$(resolve_field "$field" "$ds" "$tmpl" "$defaults")" || return 1
    [ -n "$val" ] || return 1
    printf '%s' "$val"
}

# resolve_field_tiered FIELD TIER DS TMPL DEFAULTS -- checks a per-tier
# override on the dataset (field_<tier>) before falling back to resolve_field.
resolve_field_tiered() {
    local field="$1" tier="$2" ds="$3" tmpl="$4" defaults="$5"
    if [ -n "$ds" ] && ini_has "$ds" "${field}_${tier}"; then ini_get "$ds" "${field}_${tier}"; return 0; fi
    resolve_field "$field" "$ds" "$tmpl" "$defaults"
}

# resolve_keep_retain DS TMPL TIER -- sets $RESOLVED_RETAIN and returns 0 on
# success; on failure returns 1 and sets $KEEP_RETAIN_ERROR to the specific
# reason (ambiguous vs. neither set vs. unknown tier letter), or leaves it
# empty for the generic "neither resolved" case. Must be called WITHOUT
# $(...) command substitution -- it communicates via globals, and a subshell
# would silently discard both of them (subshells get copies, not references).
RESOLVED_RETAIN=""
KEEP_RETAIN_ERROR=""
resolve_keep_retain() {
    local ds="$1" tmpl="$2" tier="$3" keep="" retain="" have_keep=0 have_retain=0
    RESOLVED_RETAIN=""
    KEEP_RETAIN_ERROR=""
    if [ -n "$ds" ] && ini_has "$ds" "keep"; then keep="$(ini_get "$ds" keep)"; have_keep=1
    elif [ -n "$tmpl" ] && ini_has "$tmpl" "keep"; then keep="$(ini_get "$tmpl" keep)"; have_keep=1; fi
    if [ -n "$ds" ] && ini_has "$ds" "retain"; then retain="$(ini_get "$ds" retain)"; have_retain=1
    elif [ -n "$tmpl" ] && ini_has "$tmpl" "retain"; then retain="$(ini_get "$tmpl" retain)"; have_retain=1; fi
    if [ "$have_keep" -eq 1 ] && [ "$have_retain" -eq 1 ]; then
        KEEP_RETAIN_ERROR="both 'keep' and 'retain' resolved -- ambiguous, set only one"
        return 1
    fi
    if [ "$have_keep" -eq 0 ] && [ "$have_retain" -eq 0 ]; then
        return 1
    fi
    # A key present but BLANK ("retain = " with nothing after it) is not the
    # same as the key being absent, and ini_has only tests presence -- a config
    # typo like this used to sail through as "resolved" with an empty value,
    # producing "delsnaps.sh ... " with no threshold flag at all. Not a
    # cosmetic gap: no flags at all silently defaults to age-mode with
    # threshold=now, i.e. delete everything older than this exact instant --
    # confirmed live, it deletes virtually everything a dataset already has.
    # Treated the same as the key being missing.
    if [ "$have_keep" -eq 1 ] && [ -z "$keep" ]; then
        KEEP_RETAIN_ERROR="'keep' is set but blank"
        return 1
    fi
    if [ "$have_retain" -eq 1 ] && [ -z "$retain" ]; then
        KEEP_RETAIN_ERROR="'retain' is set but blank"
        return 1
    fi
    if [ "$have_keep" -eq 1 ]; then
        if [ -z "${TIER_LETTER[$tier]+x}" ]; then
            KEEP_RETAIN_ERROR="no retain-flag letter known for tier '$tier' -- use 'retain=' instead of 'keep=', or add it to TIER_LETTER"
            return 1
        fi
        RESOLVED_RETAIN="-${TIER_LETTER[$tier]}${keep}"
        return 0
    fi
    RESOLVED_RETAIN="$retain"
    return 0
}

notify_text() {
    local host="$1" tier="$2" kind="$3" label="$4"
    if [ -n "$label" ]; then
        printf '%s %s %s (%s)' "$host" "$tier" "$kind" "$label"
    else
        printf '%s %s %s' "$host" "$tier" "$kind"
    fi
}

# duration_seconds STR CTX -- converts "<N>m/h/d" (same shorthand check-snap-age.sh
# itself parses) to seconds, or dies with CTX prefixed. Validated here too so a
# malformed threshold fails at generate time, not silently at 3am in cron.log.
duration_seconds() {
    local s="$1" ctx="$2"
    [[ "$s" =~ ^([0-9]+)([mhd])$ ]] || die "$ctx: invalid duration '$s' (expected <N>m, <N>h, or <N>d)"
    local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
    case "$unit" in
        m) echo $((num * 60)) ;;
        h) echo $((num * 3600)) ;;
        d) echo $((num * 86400)) ;;
    esac
}

# resolve_monitor DS TMPL CTX -- sets MONITOR_WARN/MONITOR_CRIT/MONITOR_SCHEDULE
# globals and returns 0 if this tier is monitored (monitor_warn/monitor_crit
# resolved -- both, or neither: exactly one is an error). Returns 1 if neither
# resolved (tier not monitored, not an error). Must be called WITHOUT $(...)
# command substitution -- see resolve_keep_retain's comment for why.
MONITOR_WARN=""
MONITOR_CRIT=""
MONITOR_SCHEDULE=""
MONITOR_SCHEDULE_DEFAULT="*/15 * * * *"
resolve_monitor() {
    local ds="$1" tmpl="$2" ctx="$3" have_warn=0 have_crit=0
    MONITOR_WARN=""; MONITOR_CRIT=""; MONITOR_SCHEDULE=""
    if MONITOR_WARN="$(resolve_field monitor_warn "$ds" "$tmpl" "")"; then have_warn=1; fi
    if MONITOR_CRIT="$(resolve_field monitor_crit "$ds" "$tmpl" "")"; then have_crit=1; fi
    if [ "$have_warn" -eq 0 ] && [ "$have_crit" -eq 0 ]; then
        return 1
    fi
    if [ "$have_warn" -eq 0 ] || [ "$have_crit" -eq 0 ]; then
        die "$ctx: monitor_warn and monitor_crit must both be set together (only one resolved)"
    fi
    local warn_sec crit_sec
    warn_sec="$(duration_seconds "$MONITOR_WARN" "$ctx: monitor_warn")"
    crit_sec="$(duration_seconds "$MONITOR_CRIT" "$ctx: monitor_crit")"
    [ "$crit_sec" -ge "$warn_sec" ] || die "$ctx: monitor_crit ($MONITOR_CRIT) must be >= monitor_warn ($MONITOR_WARN)"
    MONITOR_SCHEDULE="$(resolve_field monitor_schedule "$ds" "$tmpl" defaults)" || MONITOR_SCHEDULE="$MONITOR_SCHEDULE_DEFAULT"
    return 0
}
###############################################################################
#END 3

###############################################################################
#BEGIN 3.5 [ENTITY BUILDING]
###############################################################################
# Walks dataset sections (create+send + inline self-prune, both scoped to the
# dataset's own path) and prune sections (standalone additive tasks). A tier
# contributes a send entity only if send_schedule resolves; an inline prune
# entity only if prune_schedule resolves (then pattern + keep/retain are
# required). A monitor entity rides along an inline/section prune entity
# whenever that tier's monitor_warn/monitor_crit also resolve (see
# resolve_monitor) -- there is no separate monitor section to walk.
build_entities() {
    ini_has defaults host_label || die "[defaults] must set host_label (used to build notify text)"
    local host_label
    host_label="$(resolve_field host_label "" "" defaults)"

    declare -ga SEND_ENTITIES=()
    declare -ga INLINE_PRUNE_ENTITIES=()
    declare -ga PRUNE_SEC_ENTITIES=()
    declare -ga GFS_PRUNE_SEC_ENTITIES=()
    declare -ga BOOKMARK_PRUNE_ENTITIES=()
    declare -ga MONITOR_ENTITIES=()
    declare -ga SCOPE_PATTERNS=()   # "scope<SEP>pattern" per resolved prune op, for overlap check

    local section kind name
    # [excluded:] first: it produces a global flag fragment that every emitted
    # delsnaps line carries, so it has to be resolved before any of them exist.
    PROTECT_FLAGS=""
    for section in "${SECTION_ORDER[@]}"; do
        [ "${SECTION_KIND[$section]}" = "excluded" ] || continue
        build_excluded_section "$section" "${SECTION_NAME[$section]}"
    done

    for section in "${SECTION_ORDER[@]}"; do
        kind="${SECTION_KIND[$section]}"
        name="${SECTION_NAME[$section]}"

        case "$kind" in
            defaults|template|excluded) continue ;;
            dataset)         build_dataset "$section" "$name" "$host_label" ;;
            prune)            build_prune_section "$section" "$name" "$host_label" ;;
            prune-bookmarks)  build_bookmark_prune_section "$section" "$name" "$host_label" ;;
        esac
    done
}

# build_excluded_section SECTION_HEADER PREFIX
# [excluded:<prefix>] with `keep = N` -- how many of the NEWEST snapshots
# carrying a Proxmox-reserved prefix delsnaps.sh must leave alone, per dataset.
# Appends to the global PROTECT_FLAGS fragment pasted onto every delsnaps line.
#
# Global rather than per-scope on purpose: protection is a property of the
# snapshot NAME, not of where it lives, and a per-scope version would let the
# same reserved prefix be protected on one dataset and prunable on another --
# which is exactly the kind of split that goes wrong quietly.
build_excluded_section() {
    local sec="$1" prefix="$2" keep
    ini_has "$sec" keep || die "[excluded:$prefix] has no 'keep' (how many NEWEST to protect: a number, or 'all')"
    keep="$(trim "$(ini_get "$sec" keep)")"
    case "$keep" in
        all|0|[1-9]|[1-9][0-9]*) ;;
        "") die "[excluded:$prefix]: 'keep' is set but blank -- use a number, or 'all'" ;;
        *) die "[excluded:$prefix]: keep='$keep' -- expected a non-negative integer or 'all'" ;;
    esac
    PROTECT_FLAGS="$PROTECT_FLAGS-P \"$prefix:$keep\" "
}

# build_dataset SECTION_HEADER DATASET_PATH HOST_LABEL
build_dataset() {
    local ds="$1" ds_path="$2" host_label="$3"

    local tier_list
    tier_list="$(resolve_field use_template "$ds" "" "")" || die "[dataset:$ds_path] has no use_template"

    local -a tiers=()
    IFS=',' read -ra tiers <<< "$tier_list"
    local tier tmpl
    for tier in "${tiers[@]}"; do
        tier="$(trim "$tier")"
        tmpl="template:${tier}"
        [ "${SECTION_KIND[$tmpl]:-}" = "template" ] || die "[dataset:$ds_path] references unknown template '$tier' (expected a [template:$tier] section)"

        # Display name for notify text -- lets an internal tier id (e.g.
        # store_hourly) surface as a friendlier word (hourly) in alerts.
        # Never affects template lookup or the keep-retain tier letter.
        local ntier
        ntier="$(resolve_field tier_label "$ds" "$tmpl" "")" || ntier="$tier"

        # ---- send ----
        local send_schedule
        if send_schedule="$(resolve_field send_schedule "$ds" "$tmpl" defaults)"; then
            local dst src prefix flags label raw_notify word notify direction remote_spec
            dst="$(resolve_field dst "$ds" "$tmpl" defaults)" || dst=""
            src="$(resolve_field src "$ds" "$tmpl" defaults)" || src=""
            if [ -n "$dst" ] && [ -n "$src" ]; then
                die "[dataset:$ds_path] tier=$tier: both 'dst' and 'src' resolved -- a dataset section pushes (dst) or pulls (src), never both. If a [defaults] dst is meant for other datasets, override it here with a blank 'dst = '."
            fi
            if [ -n "$src" ]; then
                direction="pull"
                remote_spec="$src"
                # A colon is mandatory now (v4.24+): 'src' must be a LITERAL
                # [user@]host:path, never a bare host. Sync mode is expressed
                # structurally instead (the section's own path equalling
                # 'path' exactly), so there is no bare-host shorthand left to
                # accept here -- and a bare host passed straight through
                # would land in snapget.sh's REMOTE_DATASETS position and be
                # misread as a local dataset literally named after the host.
                case "$src" in
                    *:*) ;;
                    *) die "[dataset:$ds_path] tier=$tier: src='$src' has no ':' -- must be [user@]host:path with the LITERAL remote dataset name (e.g. 'pve2:rpool/data'). Sync mode is expressed by making the section's own path equal that name exactly, not by omitting the path here." ;;
                esac
            else
                direction="push"
                remote_spec="$dst"
            fi
            prefix="$(require_field prefix "$ds" "$tmpl" defaults)" || die "[dataset:$ds_path] tier=$tier: send_schedule is set but 'prefix' did not resolve (missing, or set but blank)"
            flags="$(resolve_field_tiered flags "$tier" "$ds" "$tmpl" "")" || flags=""
            local autotune
            autotune="$(resolve_field autotune "$ds" "$tmpl" defaults)" || autotune=""
            lint_autotune "$autotune" "[dataset:$ds_path] tier=$tier"
            flags="$(maybe_add_autotune "$flags" "$remote_spec" "$autotune")"
            local quiesce
            quiesce="$(resolve_field quiesce "$ds" "$tmpl" defaults)" || quiesce=""
            lint_quiesce "$quiesce" "[dataset:$ds_path] tier=$tier" "$direction"
            flags="$(maybe_add_quiesce "$flags" "$quiesce")"
            lint_flags "$flags" "[dataset:$ds_path] tier=$tier" "$remote_spec"
            label="$(resolve_field notify "$ds" "" "")" || label=""
            raw_notify="$(resolve_field notify_raw "$ds" "$tmpl" "")" || raw_notify=""
            word="$(resolve_field notify_word "" "$tmpl" "")" || word="backup"
            if [ -n "$raw_notify" ]; then
                notify="$raw_notify"
            else
                notify="$(notify_text "$host_label" "$ntier" "$word" "$label")"
            fi
            # The 4th field carries whichever remote spec resolved (dst for push,
            # src for pull) -- 'direction' (9th field, added below) disambiguates
            # which one it is for emit_send. Kept in the SAME slot rather than
            # adding a parallel field so group_send's existing key shape needs only
            # one addition (direction itself) instead of two.
            SEND_ENTITIES+=("${ds_path}${SEP}${tier}${SEP}${send_schedule}${SEP}${remote_spec}${SEP}${prefix}${SEP}${flags}${SEP}${notify}${SEP}${label}${SEP}${direction}")
        fi

        # ---- inline self-prune (own path, non-recursive) ----
        # prune_schedule is the deliberate "yes, prune this dataset" signal.
        local prune_schedule
        if prune_schedule="$(resolve_field prune_schedule "$ds" "$tmpl" defaults)"; then
            local pattern retain_flag plabel praw pnotify
            pattern="$(require_field pattern "$ds" "$tmpl" defaults)" || die "[dataset:$ds_path] tier=$tier: prune_schedule is set but 'pattern' did not resolve (missing, or set but blank)"
            resolve_keep_retain "$ds" "$tmpl" "$tier" || die "[dataset:$ds_path] tier=$tier: ${KEEP_RETAIN_ERROR:-prune_schedule is set but neither 'keep' nor 'retain' resolved}"
            retain_flag="$RESOLVED_RETAIN"
            plabel="$(resolve_field notify "$ds" "$tmpl" "")" || plabel=""
            praw="$(resolve_field notify_raw_prune "" "$tmpl" "")" || praw=""
            if [ -n "$praw" ]; then pnotify="$praw"; else pnotify="$(notify_text "$host_label" "$ntier" "prune" "$plabel")"; fi
            INLINE_PRUNE_ENTITIES+=("${ds_path}${SEP}${tier}${SEP}${pattern}${SEP}${retain_flag}${SEP}${prune_schedule}${SEP}${pnotify}")
            SCOPE_PATTERNS+=("${ds_path}${SEP}${pattern}")

            # ---- monitor (rides this same pattern, own path, non-recursive) ----
            if resolve_monitor "$ds" "$tmpl" "[dataset:$ds_path] tier=$tier"; then
                local mnotify mbroken mwarntext
                mnotify="$(notify_text "$host_label" "$ntier" "stale" "$plabel")"
                mbroken="$(notify_text "$host_label" "$ntier" "monitor BROKEN" "$plabel")"
                mwarntext="$(notify_text "$host_label" "$ntier" "getting stale" "$plabel")"
                MONITOR_ENTITIES+=("${ds_path}${SEP}${pattern}${SEP}${MONITOR_WARN}${SEP}${MONITOR_CRIT}${SEP}${MONITOR_SCHEDULE}${SEP}0${SEP}${mnotify}${SEP}${mbroken}${SEP}${mwarntext}")
            fi
        fi
    done
}

# build_prune_section SECTION_HEADER SCOPE HOST_LABEL
build_prune_section() {
    local sec="$1" scope="$2" host_label="$3"

    local tier_list
    tier_list="$(resolve_field use_template "$sec" "" "")" || die "[prune:$scope] has no use_template"

    local recursive clearcut rec_raw cc_raw
    rec_raw="$(resolve_field recursive "$sec" "" "")" || rec_raw="no"
    cc_raw="$(resolve_field clear_cut "$sec" "" "")" || cc_raw="no"
    [ "$(trim "$rec_raw" | tr '[:upper:]' '[:lower:]')" = "yes" ] && recursive=1 || recursive=0
    [ "$(trim "$cc_raw"  | tr '[:upper:]' '[:lower:]')" = "yes" ] && clearcut=1  || clearcut=0

    local ssh_flags
    ssh_flags="$(resolve_field ssh_flags "$sec" "" "")" || ssh_flags=""
    lint_ssh_flags "$ssh_flags" "[prune:$scope]" "$scope"

    # gfs=yes: every tier in use_template contributes its retain COUNT LETTER
    # to ONE combined delsnaps.sh -G line (cascading ladder) instead of each
    # getting its own separate line summed flat. See delsnaps.sh's own header
    # ("GFS LADDER") for what -G actually does. gfs_pattern is a SEPARATE field
    # from the per-template 'pattern' on purpose: the per-template patterns
    # (automated_hourly, automated_daily, ...) stay exactly as they are and
    # keep driving each tier's own MONITOR (freshness is still checked per
    # tier, unaffected by how retention is grouped) -- gfs_pattern is the one
    # shared prefix the COMBINED ladder call matches against, which is a
    # different, wider net by design (it has to see snapshots from every
    # contributing tier to bucket them by elapsed time).
    local gfs_raw gfs=0 gfs_pattern="" gfs_retain_parts="" gfs_schedule=""
    gfs_raw="$(resolve_field gfs "$sec" "" "")" || gfs_raw="no"
    [ "$(trim "$gfs_raw" | tr '[:upper:]' '[:lower:]')" = "yes" ] && gfs=1
    if [ "$gfs" -eq 1 ]; then
        gfs_pattern="$(require_field gfs_pattern "$sec" "" defaults)" \
            || die "[prune:$scope]: gfs=yes needs 'gfs_pattern' (the ONE shared prefix the combined -G ladder matches against -- distinct from each tier's own 'pattern', which still drives its own monitor)"
    fi

    local -a tiers=()
    IFS=',' read -ra tiers <<< "$tier_list"
    local tier tmpl
    for tier in "${tiers[@]}"; do
        tier="$(trim "$tier")"
        tmpl="template:${tier}"
        [ "${SECTION_KIND[$tmpl]:-}" = "template" ] || die "[prune:$scope] references unknown template '$tier' (expected a [template:$tier] section)"

        local ntier
        ntier="$(resolve_field tier_label "$sec" "$tmpl" "")" || ntier="$tier"

        local prune_schedule pattern retain_flag plabel praw pnotify prune_raw emit_prune
        # prune=no: this section is a MONITOR carrier only. The monitor derives
        # from a (scope,pattern) pair that a prune already needed, which is
        # normally exactly right -- but a leaf sitting under a recursive
        # [prune:<parent>] is already pruned by that parent, so repeating the
        # rule here emits a SECOND delsnaps line with the same schedule, the
        # same pattern and the same retention over the same snapshots.
        # That is not the harmless no-op it looks like: the two lines race, the
        # loser finds the snapshots already gone, reports "could not find any
        # snapshots to destroy", exits non-zero and raises an alert. Seen on
        # pve2, 63 times in one day, two alerts landing in the same second.
        # (delsnaps' own lock cannot prevent it -- it is keyed on the dataset
        # list, and these two lines legitimately have different lists.)
        prune_raw="$(resolve_field prune "$sec" "$tmpl" "")" || prune_raw="yes"
        [ "$(trim "$prune_raw" | tr '[:upper:]' '[:lower:]')" = "no" ] && emit_prune=0 || emit_prune=1

        plabel="$(resolve_field notify "$sec" "$tmpl" "")" || plabel=""
        pattern="$(require_field pattern "$sec" "$tmpl" defaults)" \
            || die "[prune:$scope] tier=$tier: 'pattern' did not resolve (missing, or set but blank)"

        if [ "$emit_prune" -eq 1 ] && [ "$gfs" -eq 1 ]; then
            prune_schedule="$(resolve_field prune_schedule "$sec" "$tmpl" defaults)" || die "[prune:$scope] tier=$tier: template has no prune_schedule"
            resolve_keep_retain "$sec" "$tmpl" "$tier" || die "[prune:$scope] tier=$tier: ${KEEP_RETAIN_ERROR:-prune_schedule is set but neither 'keep' nor 'retain' resolved}"
            retain_flag="$RESOLVED_RETAIN"
            # gfs mode only takes count-based single-letter flags -- -G itself
            # rejects age flags and needs exactly one letter per tier to build
            # the ladder from, so a malformed or multi-flag retain= is caught
            # here rather than surfacing as a cryptic delsnaps.sh error later.
            [[ "$retain_flag" =~ ^-[HDWMY][0-9]+$ ]] \
                || die "[prune:$scope] tier=$tier: gfs=yes needs a single count-based retain flag (-H/-D/-W/-M/-Y followed by a number), got '$retain_flag'"
            gfs_retain_parts="${gfs_retain_parts}${retain_flag} "
            # The combined line runs on the FIRST contributing tier's own
            # schedule (by convention use_template is listed finest-first,
            # e.g. store_hourly,store_daily,store_weekly) -- the finest tier
            # needs the most frequent re-evaluation, and re-running the coarser
            # buckets' arithmetic on that same tick is cheap and idempotent.
            [ -z "$gfs_schedule" ] && gfs_schedule="$prune_schedule"
        elif [ "$emit_prune" -eq 1 ]; then
            prune_schedule="$(resolve_field prune_schedule "$sec" "$tmpl" defaults)" || die "[prune:$scope] tier=$tier: template has no prune_schedule"
            resolve_keep_retain "$sec" "$tmpl" "$tier" || die "[prune:$scope] tier=$tier: ${KEEP_RETAIN_ERROR:-prune_schedule is set but neither 'keep' nor 'retain' resolved}"
            retain_flag="$RESOLVED_RETAIN"
            praw="$(resolve_field notify_raw_prune "$sec" "$tmpl" "")" || praw=""
            if [ -n "$praw" ]; then pnotify="$praw"; else pnotify="$(notify_text "$host_label" "$ntier" "prune" "$plabel")"; fi
            PRUNE_SEC_ENTITIES+=("${scope}${SEP}${tier}${SEP}${pattern}${SEP}${retain_flag}${SEP}${prune_schedule}${SEP}${pnotify}${SEP}${recursive}${SEP}${clearcut}${SEP}${ssh_flags}")
            SCOPE_PATTERNS+=("${scope}${SEP}${pattern}")
        elif ! resolve_monitor "$sec" "$tmpl" "[prune:$scope] tier=$tier" 2>/dev/null; then
            die "[prune:$scope] tier=$tier: prune=no and no monitor_warn/monitor_crit -- the section would emit nothing at all"
        fi

        # ---- monitor (rides this same pattern, same scope/recursive as the prune) ----
        if resolve_monitor "$sec" "$tmpl" "[prune:$scope] tier=$tier"; then
            # check-snap-age.sh is local-only by design (its own header explains
            # why: a monitor is meant to run on the host that owns the schedule).
            # A remote scope handed to it would run `zfs list` locally against a
            # literal string like "user@host:tank/data" -- not a real dataset --
            # and report UNKNOWN forever, on the monitor's own schedule (as often
            # as */15). Rejected here rather than left to become that flood.
            case "$scope" in
                *:*) die "[prune:$scope] tier=$tier: monitor_warn/monitor_crit set on a REMOTE scope -- check-snap-age.sh is local-only and would report false UNKNOWN forever. Run check-snap-age.sh in its own cron line on the host that owns '$scope' instead." ;;
            esac
            local mnotify mbroken mwarntext
            mnotify="$(notify_text "$host_label" "$ntier" "stale" "$plabel")"
            mbroken="$(notify_text "$host_label" "$ntier" "monitor BROKEN" "$plabel")"
            mwarntext="$(notify_text "$host_label" "$ntier" "getting stale" "$plabel")"
            MONITOR_ENTITIES+=("${scope}${SEP}${pattern}${SEP}${MONITOR_WARN}${SEP}${MONITOR_CRIT}${SEP}${MONITOR_SCHEDULE}${SEP}${recursive}${SEP}${mnotify}${SEP}${mbroken}${SEP}${mwarntext}")
        fi
    done

    # One combined entity for the whole section, built from every tier's
    # contribution collected in the loop above -- not per-tier, because the
    # whole point of gfs=yes is ONE delsnaps.sh -G line covering every tier at
    # once instead of one line each.
    if [ "$gfs" -eq 1 ]; then
        gfs_retain_parts="$(trim "$gfs_retain_parts")"
        [ -n "$gfs_retain_parts" ] || die "[prune:$scope]: gfs=yes but no tier in use_template actually contributed a retain value (all prune=no?) -- nothing for -G to build a ladder from"
        local gpraw gpnotify
        gpraw="$(resolve_field notify_raw_prune "$sec" "" "")" || gpraw=""
        if [ -n "$gpraw" ]; then
            gpnotify="$gpraw"
        else
            local gplabel
            gplabel="$(resolve_field notify "$sec" "" "")" || gplabel=""
            gpnotify="$(notify_text "$host_label" "gfs" "prune" "$gplabel")"
        fi
        GFS_PRUNE_SEC_ENTITIES+=("${scope}${SEP}${gfs_pattern}${SEP}${gfs_retain_parts}${SEP}${gfs_schedule}${SEP}${gpnotify}${SEP}${recursive}${SEP}${clearcut}${SEP}${ssh_flags}")
        SCOPE_PATTERNS+=("${scope}${SEP}${gfs_pattern}")
    fi
}

# build_bookmark_prune_section SECTION_HEADER SCOPE HOST_LABEL
# No templates/tiers: bookmark pruning is one age-threshold operation per
# scope, unrelated to any send/prune tier's own cadence. Reads fields
# directly off the section (ini_has/ini_get), not through resolve_field's
# dataset/template/defaults layering -- there is no layering to do here.
build_bookmark_prune_section() {
    local sec="$1" scope="$2" host_label="$3"

    ini_has "$sec" schedule || die "[prune-bookmarks:$scope] has no 'schedule'"
    local schedule
    schedule="$(ini_get "$sec" schedule)"

    ini_has "$sec" age || die "[prune-bookmarks:$scope] has no 'age' (raw delsnaps.sh age flags, e.g. \"-d30\")"
    local age
    age="$(ini_get "$sec" age)"
    local tok
    for tok in $age; do
        [ "$tok" = "-n" ] && die "[prune-bookmarks:$scope]: 'age' contains -n (dry-run) -- never actually prunes anything as a recurring job"
    done

    # Unlike the two snapshot-pattern sites above, a blank value here falls
    # back to the safe default rather than dying -- this field already HAS a
    # sensible empty-means-default behaviour by design, so "pattern = " with
    # nothing after it should behave exactly like the key being absent, not
    # like an error. Blank was previously read as "resolved" with an empty
    # string, which under the same glob match (`[[ "$markname" == "${pat}"*`)
    # matches every bookmark on the scope instead of just this tool's own.
    local pattern
    pattern="$(ini_get "$sec" pattern)"
    if ! ini_has "$sec" pattern || [ -z "$pattern" ]; then pattern="tgt-"; fi

    local rec_raw recursive
    rec_raw="$(resolve_field recursive "$sec" "" "")" || rec_raw="no"
    [ "$(trim "$rec_raw" | tr '[:upper:]' '[:lower:]')" = "yes" ] && recursive=1 || recursive=0

    local label notify
    label="$(resolve_field notify "$sec" "" "")" || label=""
    notify="$(notify_text "$host_label" "bookmarks" "prune" "$label")"

    local ssh_flags
    ssh_flags="$(resolve_field ssh_flags "$sec" "" "")" || ssh_flags=""
    lint_ssh_flags "$ssh_flags" "[prune-bookmarks:$scope]" "$scope"

    BOOKMARK_PRUNE_ENTITIES+=("${scope}${SEP}${pattern}${SEP}${age}${SEP}${schedule}${SEP}${notify}${SEP}${recursive}${SEP}${ssh_flags}")
}
###############################################################################
#END 3.5

###############################################################################
#BEGIN 3.6 [GROUPING]
###############################################################################
# Send groups by (schedule, dst, prefix, flags): identical resolved cadence and
# target -> one snapsend line. Inline prune groups by (schedule, pattern,
# retain): identical retention -> one delsnaps line listing the datasets by
# full path. Prune sections are emitted one line per tier, not grouped.
group_send() {
    declare -gA SEND_GROUPS=()
    declare -ga SEND_GROUP_ORDER=()
    local e ds tier schedule dst prefix flags notify label direction key
    for e in "${SEND_ENTITIES[@]}"; do
        IFS="$SEP" read -r ds tier schedule dst prefix flags notify label direction <<< "$e"
        # direction is IN the key: a push and a pull could otherwise share an
        # identical (schedule,remote-spec,prefix,flags) tuple by coincidence and
        # merge into one line that calls the wrong script for half its members.
        key="${schedule}${SEP}${dst}${SEP}${prefix}${SEP}${flags}${SEP}${direction}"
        [ -z "${SEND_GROUPS[$key]+x}" ] && SEND_GROUP_ORDER+=("$key")
        SEND_GROUPS["$key"]+="${e}${LSEP}"
    done
}

group_inline_prune() {
    declare -gA INLINE_PRUNE_GROUPS=()
    declare -ga INLINE_PRUNE_GROUP_ORDER=()
    local e ds tier pattern retain schedule notify key
    for e in "${INLINE_PRUNE_ENTITIES[@]}"; do
        IFS="$SEP" read -r ds tier pattern retain schedule notify <<< "$e"
        key="${schedule}${SEP}${pattern}${SEP}${retain}"
        [ -z "${INLINE_PRUNE_GROUPS[$key]+x}" ] && INLINE_PRUNE_GROUP_ORDER+=("$key")
        INLINE_PRUNE_GROUPS["$key"]+="${e}${LSEP}"
    done
}

# Monitor groups by (schedule, pattern, warn, crit, recursive): identical check
# -> one check-snap-age.sh line listing the scopes by full path (comma list,
# same as check-snap-age.sh already accepts for delsnaps-style datasets lists).
group_monitor() {
    declare -gA MONITOR_GROUPS=()
    declare -ga MONITOR_GROUP_ORDER=()
    local e scope pattern warn crit schedule recursive notify broken warntext key
    for e in "${MONITOR_ENTITIES[@]}"; do
        IFS="$SEP" read -r scope pattern warn crit schedule recursive notify broken warntext <<< "$e"
        key="${schedule}${SEP}${pattern}${SEP}${warn}${SEP}${crit}${SEP}${recursive}"
        [ -z "${MONITOR_GROUPS[$key]+x}" ] && MONITOR_GROUP_ORDER+=("$key")
        MONITOR_GROUPS["$key"]+="${e}${LSEP}"
    done
}

# Bookmark-prune groups by (schedule, pattern, age, recursive, ssh_flags):
# identical cleanup rule -> one delsnaps.sh -B line listing the scopes by full
# path. ssh_flags is IN the key, not just carried along -- two remote scopes
# that happen to share schedule/pattern/age/recursive but need different SSH
# options (different port, different host) would otherwise merge into one
# delsnaps.sh line built from only the FIRST member's ssh_flags, silently
# using the wrong port/cipher/key for the other host's entries.
group_bookmark_prune() {
    declare -gA BOOKMARK_PRUNE_GROUPS=()
    declare -ga BOOKMARK_PRUNE_GROUP_ORDER=()
    local e scope pattern age schedule notify recursive sshflags key
    for e in "${BOOKMARK_PRUNE_ENTITIES[@]}"; do
        IFS="$SEP" read -r scope pattern age schedule notify recursive sshflags <<< "$e"
        key="${schedule}${SEP}${pattern}${SEP}${age}${SEP}${recursive}${SEP}${sshflags}"
        [ -z "${BOOKMARK_PRUNE_GROUPS[$key]+x}" ] && BOOKMARK_PRUNE_GROUP_ORDER+=("$key")
        BOOKMARK_PRUNE_GROUPS["$key"]+="${e}${LSEP}"
    done
}
###############################################################################
#END 3.6

###############################################################################
#BEGIN 3.7 [SAME-SCOPE PATTERN OVERLAP CHECK]
###############################################################################
# delsnaps.sh matches snapshots by literal string prefix. If two resolved prune
# operations target the SAME literal scope and one pattern is a prefix of (or
# equal to) the other, a single snapshot could match both retention rules.
# Checked on the final resolved (scope, pattern) pairs collected in build.
validate_retain_patterns() {
    local -a scopes=() patterns=()
    local pair scope pattern
    for pair in "${SCOPE_PATTERNS[@]}"; do
        IFS="$SEP" read -r scope pattern <<< "$pair"
        scopes+=("$scope")
        patterns+=("$pattern")
    done

    local n="${#scopes[@]}" i j pi pj
    for ((i = 0; i < n; i++)); do
        for ((j = i + 1; j < n; j++)); do
            [ "${scopes[$i]}" = "${scopes[$j]}" ] || continue
            pi="${patterns[$i]}"
            pj="${patterns[$j]}"
            [ "$pi" = "$pj" ] && continue   # same tier resolved twice is not a conflict
            if [[ "$pi" == "$pj"* ]] || [[ "$pj" == "$pi"* ]]; then
                die "pattern overlap for scope='${scopes[$i]}': pattern='$pi' and pattern='$pj' -- one is a prefix of (or equal to) the other, so a single snapshot could match both retention rules. Use mutually exclusive prefixes."
            fi
        done
    done
}
###############################################################################
#END 3.7

###############################################################################
#BEGIN 3.8 [EMISSION]
###############################################################################
# Appends into JOB_LINES/RETAIN_LINES (consumed unchanged by generate_block
# in BEGIN 4) rather than printing directly.
emit_send() {
    local key list ds tier schedule dst prefix flags notify label direction
    for key in "${SEND_GROUP_ORDER[@]}"; do
        list="${SEND_GROUPS[$key]}"
        local -a members=()
        IFS="$LSEP" read -ra members <<< "${list%${LSEP}}"
        IFS="$SEP" read -r ds tier schedule dst prefix flags notify label direction <<< "${members[0]}"

        # Pull never groups: 'dst' here holds 'src's raw value, a LITERAL
        # remote name, so two different local datasets could only land in the
        # same group by coincidentally pulling the identical remote source --
        # a config mistake, not something to silently merge (snapget.sh's
        # single LOCAL_BASE argument cannot place two different local
        # destinations in one call anyway).
        if [ "$direction" = "pull" ]; then
            if [ "${#members[@]}" -gt 1 ]; then
                die "[dataset:$ds] and other section(s) all resolved the identical src='$dst' -- pull datasets cannot be merged (snapget.sh needs one local destination per literal remote name). Give each a distinct remote path, or split them onto different schedules/prefixes/flags."
            fi
            local remote_name local_base
            remote_name="${dst#*:}"
            if [ "$ds" = "$remote_name" ]; then
                local_base=""
            elif [[ "$ds" == */"$remote_name" ]]; then
                local_base="${ds%/$remote_name}"
            else
                die "[dataset:$ds] direction=pull: the local path must end with the remote dataset name ('$remote_name', from src='$dst') -- e.g. local dataset:<base>/$remote_name. snapget.sh has no way to reconcile an unrelated local name with a fixed remote one."
            fi
            local cmd
            cmd="$REPO_DIR/snapget.sh -m \"$prefix\""
            [ -n "$flags" ] && cmd="$cmd $flags"
            cmd="$cmd \"$dst\""
            [ -n "$local_base" ] && cmd="$cmd \"$local_base\""
            JOB_LINES+=("$(job_cron_line "$schedule" "$cmd" "$notify")")
            continue
        fi

        local src notify_out
        if [ "${#members[@]}" -eq 1 ]; then
            src="$ds"
            notify_out="$notify"
        else
            local -a datasets=() notifies=()
            local m mds mtier msch mdst mpre mflg mnot mlab mdir
            for m in "${members[@]}"; do
                IFS="$SEP" read -r mds mtier msch mdst mpre mflg mnot mlab mdir <<< "$m"
                datasets+=("$mds")
                notifies+=("$mnot")
            done
            src="$(IFS=,; printf '%s' "${datasets[*]}")"

            local -a distinct=()
            local n found existing
            for n in "${notifies[@]}"; do
                found=0
                for existing in "${distinct[@]}"; do [ "$existing" = "$n" ] && found=1 && break; done
                [ "$found" -eq 0 ] && distinct+=("$n")
            done

            if [ "${#distinct[@]}" -eq 1 ]; then
                notify_out="${distinct[0]}"
            else
                local -a lseen=()
                local f2 e2
                for m in "${members[@]}"; do
                    IFS="$SEP" read -r mds mtier msch mdst mpre mflg mnot mlab mdir <<< "$m"
                    [ -z "$mlab" ] && continue
                    f2=0
                    for e2 in "${lseen[@]}"; do [ "$e2" = "$mlab" ] && f2=1 && break; done
                    [ "$f2" -eq 0 ] && lseen+=("$mlab")
                done
                local joined
                joined="$(IFS=+; printf '%s' "${lseen[*]}")"
                if [[ "$notify" == *"("* ]]; then
                    local host_tier="${notify%%(*}"
                    host_tier="$(trim "$host_tier")"
                    notify_out="${host_tier} (${joined})"
                else
                    notify_out="$notify"
                fi
            fi
        fi

        # Only push reaches here -- pull already emitted and 'continue'd above.
        local cmd
        cmd="$REPO_DIR/snapsend.sh -m \"$prefix\""
        [ -n "$flags" ] && cmd="$cmd $flags"
        cmd="$cmd \"$src\""
        [ -n "$dst" ] && cmd="$cmd \"$dst\""

        JOB_LINES+=("$(job_cron_line "$schedule" "$cmd" "$notify_out")")
    done
}

# One job line: run the command, keep its stderr in the cron log exactly as
# before, and on failure hand the TAIL of that output to the notify script as a
# second argument, so the daily digest can report what actually went wrong
# instead of only the label from this config.
#
# The output goes to a temp file rather than straight into the log, because the
# tail has to be read back after the command exits. A side effect worth naming:
# a job's lines now land in cron.log as one contiguous block when it finishes,
# instead of streaming while it runs -- which also means two overlapping jobs no
# longer interleave their output there.
job_cron_line() {
    local schedule="$1" cmd="$2" notify="$3"
    printf '%s e=$(mktemp); %s 2>"$e"; rc=$?; cat "$e" >>%s; [ $rc -ne 0 ] && %s "%s" "$(tail -n %s "$e")" 2>>%s; rm -f "$e"' \
        "$schedule" "$cmd" "$CRON_LOG" "$NOTIFY_SCRIPT" "$notify" "$DETAIL_LINES" "$CRON_LOG"
}

# Inline prune: one delsnaps line per (schedule,pattern,retain) group, listing
# every member dataset BY FULL PATH, non-recursively. No -R, ever.
emit_inline_prune() {
    local key list ds tier pattern retain schedule notify
    for key in "${INLINE_PRUNE_GROUP_ORDER[@]}"; do
        list="${INLINE_PRUNE_GROUPS[$key]}"
        local -a members=()
        IFS="$LSEP" read -ra members <<< "${list%${LSEP}}"
        IFS="$SEP" read -r ds tier pattern retain schedule notify <<< "${members[0]}"

        local -a targets=()
        local m mds mtier mpat mret msch mnot
        for m in "${members[@]}"; do
            IFS="$SEP" read -r mds mtier mpat mret msch mnot <<< "$m"
            targets+=("$mds")
        done
        local joined
        joined="$(IFS=,; printf '%s' "${targets[*]}")"

        local cmd="$REPO_DIR/delsnaps.sh ${PROTECT_FLAGS}\"$joined\" \"$pattern\" $retain"
        RETAIN_LINES+=("$(job_cron_line "$schedule" "$cmd" "$notify")")
    done
}

# Prune sections: one standalone delsnaps line per tier. recursive -> -R,
# clear_cut -> -F. Additive; no cross-check against inline prune (B semantics).
emit_prune_sections() {
    local e scope tier pattern retain schedule notify recursive clearcut sshflags
    for e in "${PRUNE_SEC_ENTITIES[@]}"; do
        IFS="$SEP" read -r scope tier pattern retain schedule notify recursive clearcut sshflags <<< "$e"
        local flag="" fflag="" sflag=""
        [ "$recursive" = "1" ] && flag="-R "
        [ "$clearcut" = "1" ] && fflag="-F "
        [ -n "$sshflags" ] && sflag="$sshflags "
        local cmd="$REPO_DIR/delsnaps.sh ${flag}${fflag}${sflag}${PROTECT_FLAGS}\"$scope\" \"$pattern\" $retain"
        RETAIN_LINES+=("$(job_cron_line "$schedule" "$cmd" "$notify")")
    done
}

# gfs=yes sections: one combined delsnaps.sh -G line per section, covering
# every contributing tier's retain count at once (see build_prune_section).
emit_gfs_prune_sections() {
    local e scope pattern retain schedule notify recursive clearcut sshflags
    for e in "${GFS_PRUNE_SEC_ENTITIES[@]}"; do
        IFS="$SEP" read -r scope pattern retain schedule notify recursive clearcut sshflags <<< "$e"
        local flag="" fflag="" sflag=""
        [ "$recursive" = "1" ] && flag="-R "
        [ "$clearcut" = "1" ] && fflag="-F "
        [ -n "$sshflags" ] && sflag="$sshflags "
        local cmd="$REPO_DIR/delsnaps.sh -G ${flag}${fflag}${sflag}${PROTECT_FLAGS}\"$scope\" \"$pattern\" $retain"
        RETAIN_LINES+=("$(job_cron_line "$schedule" "$cmd" "$notify")")
    done
}

# Monitor: one check-snap-age.sh line per (schedule,pattern,warn,crit,recursive)
# group, listing every member scope BY FULL PATH (comma list). recursive=1 ->
# -R, mirroring the [prune:] section it rode in on.
#
# Unlike send/prune lines (plain "cmd || notify", any failure alerts equally),
# a monitor line reads the exit code and alerts with DIFFERENT wording per
# outcome, following the Nagios convention check-snap-age.sh implements:
#
#   0 OK       -- silent.
#   1 WARNING  -- routed to $WARN_SCRIPT, which only queues it (no mail) for
#                 alert-digest.sh to summarize once a day. Not urgent enough
#                 to interrupt anyone, but worth a same-day record.
#   2 CRITICAL -- emails the "<tier> stale" text via $NOTIFY_SCRIPT: a
#                 snapshot really is too old. $NOTIFY_SCRIPT rate-limits
#                 repeats of the identical message, so a stuck CRITICAL pages
#                 once, not once per cron tick.
#   >=3        -- emails the "<tier> monitor BROKEN" text instead. This covers
#                 UNKNOWN (3) from the script itself (bad threshold, missing
#                 zfs, dataset gone) AND shell-level failures the script never
#                 got to report: 126 (not executable), 127 (not found).
#
# Splitting >=3 from 2 is the whole point: both page, but they say different
# things and need different fixes. Collapsing them (the old "exit >= 2" test)
# produced a mail claiming snapshots were stale when the truth was that the
# script had no execute bit and never ran -- and, worse, a typo'd threshold
# exits 1, which that same test swallowed silently while the check verified
# nothing at all, indefinitely.
#
# EVERY command in the line redirects stderr to $CRON_LOG, the notify calls
# included -- not just the check. cron mails whatever a job writes to stdout OR
# stderr, and the notify scripts are not silent: notify-fail.sh reports its own
# cooldown suppression ("suppressed repeat within cooldown") on stderr. With the
# redirect on the check alone, a monitor sitting at CRITICAL therefore sent a
# raw cron mail on EVERY tick -- 96 a day per monitor at */15 -- which is the
# exact flood the rate-limiting inside notify-fail.sh exists to prevent. The
# same applies to the "|| notify" job and prune lines above, for the same reason.
# Do not drop these redirects; a host with MAILTO="" set merely hides the
# symptom, and not every host has it.
emit_monitor() {
    local key list scope pattern warn crit schedule recursive notify broken warntext
    for key in "${MONITOR_GROUP_ORDER[@]}"; do
        list="${MONITOR_GROUPS[$key]}"
        local -a members=()
        IFS="$LSEP" read -ra members <<< "${list%${LSEP}}"
        IFS="$SEP" read -r scope pattern warn crit schedule recursive notify broken warntext <<< "${members[0]}"

        local -a targets=()
        local m mscope mpat mwarn mcrit msch mrec mnot mbrk mwtxt
        for m in "${members[@]}"; do
            IFS="$SEP" read -r mscope mpat mwarn mcrit msch mrec mnot mbrk mwtxt <<< "$m"
            targets+=("$mscope")
        done
        local joined
        joined="$(IFS=,; printf '%s' "${targets[*]}")"

        local flag=""
        [ "$recursive" = "1" ] && flag="-R "
        local cmd="$REPO_DIR/check-snap-age.sh ${flag}\"$joined\" \"$pattern\" $warn $crit"
        # The verdict is CAPTURED and handed to the notify script, not just
        # appended to the log. check-snap-age.sh already prints the dataset, the
        # pattern, the newest snapshot, its real age and both thresholds -- all
        # of it was going to cron.log while the mail carried only the label from
        # this config, which tells the reader nothing they can act on. It still
        # reaches cron.log too; nothing is lost.
        MONITOR_LINES+=("$schedule d=\$($cmd 2>&1); rc=\$?; [ -n \"\$d\" ] && echo \"\$d\" >>$CRON_LOG; [ \$rc -eq 1 ] && $WARN_SCRIPT \"$warntext\" \"\$d\" 2>>$CRON_LOG; [ \$rc -eq 2 ] && $NOTIFY_SCRIPT \"$notify\" \"\$d\" 2>>$CRON_LOG; [ \$rc -ge 3 ] && $NOTIFY_SCRIPT \"$broken\" \"\$d\" 2>>$CRON_LOG")
    done
}

# Bookmark prune: one delsnaps.sh -B line per (schedule,pattern,age,recursive)
# group, listing every member scope BY FULL PATH. Not monitored (check-snap-
# age.sh watches snapshot staleness, not bookmarks) and not part of the
# same-scope pattern-overlap check (different ZFS object type than snapshots).
emit_bookmark_prune() {
    local key list scope pattern age schedule notify recursive sshflags
    for key in "${BOOKMARK_PRUNE_GROUP_ORDER[@]}"; do
        list="${BOOKMARK_PRUNE_GROUPS[$key]}"
        local -a members=()
        IFS="$LSEP" read -ra members <<< "${list%${LSEP}}"
        IFS="$SEP" read -r scope pattern age schedule notify recursive sshflags <<< "${members[0]}"

        local -a targets=()
        local m mscope mpat mage msch mnot mrec msshf
        for m in "${members[@]}"; do
            IFS="$SEP" read -r mscope mpat mage msch mnot mrec msshf <<< "$m"
            targets+=("$mscope")
        done
        local joined
        joined="$(IFS=,; printf '%s' "${targets[*]}")"

        local flag="" sflag=""
        [ "$recursive" = "1" ] && flag="-R "
        [ -n "$sshflags" ] && sflag="$sshflags "
        local cmd="$REPO_DIR/delsnaps.sh -B ${flag}${sflag}\"$joined\" \"$pattern\" $age"
        RETAIN_LINES+=("$(job_cron_line "$schedule" "$cmd" "$notify")")
    done
}
###############################################################################
#END 3.8

###############################################################################
#BEGIN 4 [BLOCK GENERATION]
###############################################################################
generate_block() {
    echo "$MARKER_BEGIN"
    echo "# Source: $CONFIG -- DO NOT EDIT BY HAND, re-run gen-cron.sh instead"
    local line
    for line in "${JOB_LINES[@]}"; do echo "$line"; done
    if [ "${#JOB_LINES[@]}" -gt 0 ] && [ "${#RETAIN_LINES[@]}" -gt 0 ]; then
        echo ""
    fi
    for line in "${RETAIN_LINES[@]}"; do echo "$line"; done
    if { [ "${#JOB_LINES[@]}" -gt 0 ] || [ "${#RETAIN_LINES[@]}" -gt 0 ]; } && [ "${#MONITOR_LINES[@]}" -gt 0 ]; then
        echo ""
    fi
    for line in "${MONITOR_LINES[@]}"; do echo "$line"; done
    if [ "${#MONITOR_LINES[@]}" -gt 0 ]; then
        echo ""
        # Redirected like every other generated line: the digest is silent on
        # the happy path, but it reports a failed mail delivery on stderr, and
        # an unredirected stderr here is a cron mail -- from the very script
        # whose job is to be the only mail this host sends.
        echo "$DIGEST_SCHEDULE $DIGEST_SCRIPT 2>>$CRON_LOG"
    fi
    echo "$MARKER_END"
}
###############################################################################
#END 4

###############################################################################
#BEGIN 5 [IDEMPOTENT CRONTAB INSTALL]
###############################################################################
install_crontab() {
    command -v flock >/dev/null || die "flock command not found"
    command -v crontab >/dev/null || die "crontab command not found"

    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
        die "another gen-cron.sh --install is already running (lock: $LOCKFILE) -- retry once it finishes"
    fi

    local current
    current="$(crontab -l 2>/dev/null)" || current=""

    local begin_count end_count
    begin_count=$(printf '%s\n' "$current" | grep -Fc "$MARKER_BEGIN")
    end_count=$(printf '%s\n' "$current" | grep -Fc "$MARKER_END")

    if [ "$begin_count" -gt 1 ] || [ "$end_count" -gt 1 ]; then
        die "malformed crontab: multiple '$MARKER_BEGIN'/'$MARKER_END' pairs found -- fix manually before retrying"
    fi
    if [ "$begin_count" -ne "$end_count" ]; then
        die "malformed crontab: found $begin_count BEGIN marker(s) but $end_count END marker(s) -- fix manually before retrying"
    fi

    if [ "$begin_count" -eq 0 ] && [ -n "$current" ]; then
        local conflicts
        conflicts="$(printf '%s\n' "$current" | grep -E 'snapsend\.sh|delsnaps\.sh|check-snap-age\.sh' || true)"
        if [ -n "$conflicts" ]; then
            {
                echo "gen-cron.sh: error: crontab has no managed block yet, but already contains"
                echo "lines calling snapsend.sh/delsnaps.sh/check-snap-age.sh (listed below)."
                echo "Appending blindly would run these jobs twice on overlapping schedules --"
                echo "this is exactly what happened on pve1.11 (192.168.11.11) previously."
                echo "Remove or migrate the old lines by hand first, then re-run --install."
                echo "--- conflicting existing lines ---"
                printf '%s\n' "$conflicts"
            } >&2
            exit 1
        fi
    fi

    local new_block
    new_block="$(generate_block)"

    local new_crontab="" line in_block=0
    if [ "$begin_count" -eq 1 ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            if [ "$line" = "$MARKER_BEGIN" ]; then
                new_crontab+="$new_block"$'\n'
                in_block=1
                continue
            fi
            if [ "$line" = "$MARKER_END" ]; then
                in_block=0
                continue
            fi
            [ "$in_block" -eq 1 ] && continue
            new_crontab+="$line"$'\n'
        done <<<"$current"
    else
        if [ -n "$current" ]; then
            new_crontab="$current"$'\n\n'"$new_block"$'\n'
        else
            new_crontab="$new_block"$'\n'
        fi
    fi

    local new_crontab_norm
    new_crontab_norm="$(printf '%s' "$new_crontab")"

    if [ "$current" = "$new_crontab_norm" ]; then
        echo "gen-cron.sh: no changes -- crontab already up to date" >&2
        return 0
    fi

    printf '%s\n' "$new_crontab_norm" | crontab - || die "crontab install failed"
    echo "gen-cron.sh: crontab updated from $CONFIG" >&2
}
###############################################################################
#END 5

###############################################################################
#BEGIN 6 [MAIN]
###############################################################################
CONFIG=""
INSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        -c) CONFIG="$2"; shift 2 ;;
        --install) INSTALL=1; shift ;;
        -V|--version) echo "$VERSION"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (see -h)" ;;
    esac
done

if [ -z "$CONFIG" ]; then
    CONFIG="$SCRIPT_DIR/jobs.$(hostname -s 2>/dev/null || hostname).conf"
fi
[ -f "$CONFIG" ] || die "config file not found: $CONFIG (pass -c to specify one)"

parse_ini "$CONFIG"
[ "${#SECTION_ORDER[@]}" -gt 0 ] || die "no sections found in $CONFIG"

build_entities
group_send
group_inline_prune
group_bookmark_prune
group_monitor
validate_retain_patterns
emit_send
emit_inline_prune
emit_prune_sections
emit_gfs_prune_sections
emit_bookmark_prune
emit_monitor

# MONITOR_LINES counts too. A config made only of monitor carriers
# ([prune:<scope>] with prune = no) resolves zero send and zero prune rules by
# design, yet produces a perfectly valid crontab of staleness checks -- the
# obvious case being a host that WATCHES datasets whose retention is run
# somewhere else. Counting only send/prune rejected that config as "empty"
# while sitting on a block it had already generated. Found by a scenario test
# whose whole point was a monitor-only config.
[ "${#JOB_LINES[@]}" -gt 0 ] || [ "${#RETAIN_LINES[@]}" -gt 0 ] || [ "${#MONITOR_LINES[@]}" -gt 0 ] \
    || die "no send/prune/monitor rules resolved from $CONFIG"

if [ "$INSTALL" -eq 1 ]; then
    install_crontab
else
    generate_block
fi
###############################################################################
#END 6
