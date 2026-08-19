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
#     The five paths that end up inside every generated line. All optional, all
#     absolute, all overridden by the environment variable of the same name in
#     upper case (env > config > default). Set them when the jobs do NOT run as
#     root: the defaults live under /root/scripts, which a delegated account can
#     neither read nor write, and the result is a working backup whose alerting
#     silently goes nowhere.
#       repo_dir      = /home/zfsbackup/zfs-snapshot-all   # default: this script's dir
#       notify_script = /home/zfsbackup/notify-fail.sh     # default: /root/scripts/notify-fail.sh
#       warn_script   = /home/zfsbackup/notify-warn.sh     # default: /root/scripts/notify-warn.sh
#       digest_script = /home/zfsbackup/alert-digest.sh    # default: /root/scripts/alert-digest.sh
#                       'none' emits NO digest line. There is one digest per
#                       host by design; a delegated account's block opts out
#                       this way, since deploy.sh gives such an account its own
#                       notify-fail/notify-warn but deliberately not the digest.
#       cron_log      = /home/zfsbackup/cron.log           # default: /root/scripts/cron.log
#
#   Unknown field names are REJECTED, in every section type. Until 2026-07-29
#   they were stored and never looked at, so a typo -- or a field that never
#   existed, as deploy.sh's --draft-config emitted for months -- produced a
#   config that generated cleanly and did not do what it said.
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
#       pair_label   = <name>              # REV-045: the zfs-backup.sh client
#                                          # this dataset's jobs belong to.
#                                          # Becomes -L on the transfer line
#                                          # and on this dataset's monitor, so
#                                          # pause-client skips both. Dataset/
#                                          # prune-section scope only (never
#                                          # inherited); on a [prune:] it
#                                          # reaches ONLY the monitor -- prune
#                                          # itself keeps running while paused.
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
#       recursive    = no | flat | atomic  # default no; SCOPE of every line this
#                                          # section generates -- see below.
#                                          # Section-scope only: never inherited
#                                          # from a template or [defaults].
#       ...any template field can be overridden here (dst, send_schedule,
#          prune_schedule, keep, retain, notify_raw, notify_raw_prune)
#     A dataset section runs scoped to ITS OWN path, or -- if 'recursive' says
#     so -- to its whole subtree:
#       create(+send)  if its tiers resolve send_schedule
#       self-prune     if its tiers resolve prune_schedule (retention defined
#                      right here, at the dataset, independent of every other)
#
#     'recursive' drives ALL THREE generated lines from one declaration
#     (REV-20260807-054). It has to: the old shape could only make the
#     TRANSFER recursive, by hiding -r/-R in free-form 'flags', while the
#     inline prune and the monitor stayed on the named dataset -- so a newly
#     created child was replicated forever, never pruned, never watched, and
#     every run reported success. -r/-R in 'flags' is now a hard error.
#
#       value    transfer              inline prune       monitor
#       no       this dataset          this dataset       this dataset
#       flat     snapsend/snapget -R   delsnaps -R        check-snap-age -R
#       atomic   snapsend/snapget -r   delsnaps -R        check-snap-age -R
#
#     flat = each descendant is its own job (one child failing does not stop
#     its siblings; -X/-S filters apply; per-dataset bookmarks). atomic = the
#     subtree in ONE stream at ONE point in time, failing as a unit. delsnaps
#     and check-snap-age have no atomic mode and need none -- retention and
#     staleness are per-dataset questions either way.
#
#     Datasets sharing a resolved (send_schedule,dst,prefix,flags) merge into one
#     send line; datasets sharing a resolved
#     (prune_schedule,pattern,keep/retain,recursive) merge into one prune line
#     that lists them BY FULL PATH. Recursion is never INFERRED from a shared
#     parent: a list of separately named datasets stays a list, because
#     collapsing it to a sweep would prune snapshots nobody named.
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
VERSION='v4.30'

# Legacy-render mode, used ONLY by --migrate-recursion to produce the
# before-migration baseline it compares against. Assigned unconditionally here
# so an inherited environment variable of the same name cannot preset it, and
# reachable only via an undocumented argument that is refused together with
# --install -- so it can render to stdout and can never write a crontab. It
# does not weaken the v4.27 rejection for any normal run.
MIGRATE_LEGACY=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The single crontab writer. Sourced from beside this script, not from
# $REPO_DIR: REPO_DIR names where the JOBS live (it can be overridden to point
# at an account's checkout), while the library must be the one that came with
# this copy of gen-cron.sh.
[ -r "$SCRIPT_DIR/lib-cron.sh" ] || { echo "gen-cron.sh: cannot read $SCRIPT_DIR/lib-cron.sh -- the checkout is incomplete" >&2; exit 1; }
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib-cron.sh"

# Captured BEFORE defaulting, because "was this given?" cannot be recovered
# afterwards -- once REPO_DIR holds SCRIPT_DIR there is no telling whether the
# environment said so or the default did.
REPO_DIR_ENV="${REPO_DIR:-}"
NOTIFY_SCRIPT_ENV="${NOTIFY_SCRIPT:-}"
WARN_SCRIPT_ENV="${WARN_SCRIPT:-}"
DIGEST_SCRIPT_ENV="${DIGEST_SCRIPT:-}"
CRON_LOG_ENV="${CRON_LOG:-}"

REPO_DIR="${REPO_DIR:-$SCRIPT_DIR}"
NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-/root/scripts/notify-fail.sh}"
WARN_SCRIPT="${WARN_SCRIPT:-/root/scripts/notify-warn.sh}"
DIGEST_SCRIPT="${DIGEST_SCRIPT:-/root/scripts/alert-digest.sh}"
DIGEST_SCHEDULE="${DIGEST_SCHEDULE:-0 7 * * *}"
CRON_LOG="${CRON_LOG:-/root/scripts/cron.log}"
# The install lock lives in the project's SHARED lock directory, not /var/run.
#
# /var/run is root-only, and the managed block belongs to the DELEGATED
# ACCOUNT -- so the default path made `gen-cron.sh --install` unusable by the
# very identity that owns what it installs. Worse, a single earlier root-side
# run left a root-owned 0644 file there that the account could not open even
# once, permanently. Hit live on pve0 2026-08-07 while covering its uncovered
# guests, and the same shape lib-cron.sh already documents from metropolis
# pve1 2026-08-06.
#
# No fallback to the old path if the shared directory is missing: lib-cron.sh
# refuses in that case anyway (cron_lock_acquire), so --install already fails
# there -- this only moves the failure earlier, with a message that names the
# fix. A silent fallback would split the lock namespace, which is exactly what
# a lock exists to prevent.
LOCKFILE="${GEN_CRON_LOCKFILE:-$CRON_LOCK_DIR/gen-cron.install.lock}"
# How many trailing lines of a failed job's output travel into the alert. Enough
# for a ZFS error plus the line that provoked it, short enough that a mail stays
# a mail even when eight datasets fail in one run.
DETAIL_LINES="${DETAIL_LINES:-8}"
MARKER_NAME="zfs-backup-managed"
MARKER_TAIL="(generated by gen-cron.sh -- do not hand-edit, re-run gen-cron.sh instead)"
MARKER_BEGIN="# BEGIN $MARKER_NAME $MARKER_TAIL"
MARKER_END="# END $MARKER_NAME"

RECONCILE=0
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
# and runs `zfs snapshot` there), so quiescing it means freezing across that same
# ssh hop and thawing reliably even if the connection drops mid-run. That used to
# be rejected outright, because snapget.sh had no -q at all and generating the
# flag anyway would only have produced a cron line it could not parse.
#
# snapget.sh v2.65 implements it (see the REMOTE QUIESCE section in
# lib-zfs-snap.sh): the whole freeze/snapshot/thaw runs in ONE remote invocation
# carrying its own EXIT trap and a detached deadman, which is what makes the thaw
# survive a lost connection. So pull is allowed now -- with one caveat this
# generator CAN check and one it cannot:
#
#   can  -- `sync` on a pull dataset is still refused below: the container
#           fallback is a `pct exec` flush, and there is no reason to schedule
#           one across an ssh hop when the same host could push instead.
#   cannot -- whether the SOURCE account is privileged enough. `qm`/`pct` need
#           root there (measured: a delegated account cannot even read
#           /etc/pve/qemu-server/<id>.conf), and this generator has no way to
#           know which account the job will authenticate as, let alone what it
#           may run. snapget.sh checks it at RUN time and fails loudly rather
#           than silently taking a crash-consistent snapshot -- which is the
#           right place for it, but means a config can generate cleanly here and
#           still need `--as=root` (or a sudo rule) on the peer to work.
lint_quiesce() {
    local want="$1" ctx="$2" direction="$3"
    case "$want" in
        ""|no) return 0 ;;
        agent|auto)
            return 0
            ;;
        sync)
            [ "$direction" = "pull" ] && die "$ctx: quiesce='sync' on a pull dataset -- sync is the CONTAINER fallback (a 'pct exec <id> -- sync' flush, not a freeze), and running it across an ssh hop buys nothing a push job on that host would not do better. Use quiesce=agent/auto for VMs, or run this dataset as a push job."
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

# The OPTION LETTERS in a free-form flags string, one per line, read the way
# the engine's own `getopts` reads them (REV-20260807-054 acceptance
# condition 1).
#
# Scanning for a whole token like "-R" is not equivalent and never was: getopts
# accepts bundled short options, so `-Rv 3` means -R -v 3, and a check that
# only ever compares complete tokens lets the exact same policy back in under
# a different spelling. It is also wrong in the other direction -- an option
# ARGUMENT is not an option, and `-m -R-daily_` carries no -R at all.
#
# So this walks characters and consults the engine's own optstrings for which
# letters take an argument. The two engines differ (snapget has -Q, snapsend
# has neither), and the union is used deliberately: a letter that takes an
# argument in EITHER engine must consume one here, or a pull-side flags string
# would be mis-scanned by a push-side reading of it. Being too eager to treat
# something as an argument can only ever make this MISS a letter, so the
# recursion check that depends on it is written to fail closed separately.
#
#   arg-taking (union): m l v j p k q Q T o x c b X K O L
#   boolean    (union): e z Z g N r R n i H u U f w V A F S
FLAGS_ARG_LETTERS='mlvjpkqQToxcbXKOL'
# One grammar, two views. flags_opt_pairs does the getopts-equivalent walk and
# yields "<letter><TAB><argument>"; flags_opt_letters is the letters-only view of
# the SAME walk, so there is no second implementation to keep in step.
#
# REV-20260808-074 follow-up: --reconcile had grown its own token walker that
# recognised only `-S`, `-X` and `-Xpat` as whole tokens. Legal clustered
# spellings the engine accepts -- `-eS`, `-SX drop$` -- were misread, and the
# skipped parent or excluded child came back COVERED. That is the same defect
# REV-20260808-069 fixed in the engines' own pre-pass, rewritten by hand a
# second time. Hence: extract, do not re-implement.
flags_opt_pairs() {   # <flags string> -> "<letter>	<argument>" per option
    local tok rest c want_arg=0 pending=""
    for tok in $1; do
        if [ "$want_arg" -eq 1 ]; then
            printf '%s	%s
' "$pending" "$tok"; want_arg=0; pending=""; continue
        fi
        case "$tok" in
            --) break ;;          # end of options, same as getopts
            -?*) rest="${tok#-}" ;;
            *) continue ;;        # a positional, or an argument we did not consume
        esac
        while [ -n "$rest" ]; do
            c="${rest%"${rest#?}"}"
            rest="${rest#?}"
            case "$FLAGS_ARG_LETTERS" in
                *"$c"*)
                    # The argument is the remainder of this token if there is
                    # one, otherwise the next token. Either way nothing left in
                    # this token is an option letter.
                    if [ -n "$rest" ]; then
                        printf '%s	%s
' "$c" "$rest"; rest=""
                    else
                        pending="$c"; want_arg=1
                    fi
                    ;;
                *) printf '%s	
' "$c" ;;
            esac
        done
    done
}

flags_opt_letters() {   # <flags string> -> option letters, one per line
    flags_opt_pairs "$1" | cut -f1
}

# Splits legacy recursion OUT of a flags string, using the same option walk as
# flags_opt_letters (REV-20260807-057 contract 1: detection must not be a
# substring rule that mistakes `-m R-daily_` for recursion).
#
# Sets SR_REC to atomic|flat|"" and SR_REST to what remains. When no recursion
# is present SR_REST is the INPUT, byte for byte -- reconstructing an unchanged
# string would let whitespace drift in, and this function's output is written
# back into a live config file.
#
# Bundled forms are split rather than refused (`-Rv 3` -> flat + `-v 3`,
# `-rZ` -> atomic + `-Z`), because refusing them would leave a legal config
# with no migration path.
split_recursion_flags() {   # <flags>  -> 0 ok / 1 refused (SR_ERR set)
    SR_REC=""; SR_REST=""; SR_ERR=""
    local tok rest c kept want_arg=0 found=0 no_more_opts=0 want
    local -a out=()
    for tok in $1; do
        if [ "$want_arg" -eq 1 ] || [ "$no_more_opts" -eq 1 ]; then
            want_arg=0; out+=("$tok"); continue
        fi
        case "$tok" in
            --)  no_more_opts=1; out+=("$tok"); continue ;;
            -?*) ;;
            *)   out+=("$tok"); continue ;;
        esac
        rest="${tok#-}"; kept=""
        while [ -n "$rest" ]; do
            c="${rest%"${rest#?}"}"; rest="${rest#?}"
            case "$c" in
                r|R)
                    [ "$c" = r ] && want=atomic || want=flat
                    if [ -n "$SR_REC" ] && [ "$SR_REC" != "$want" ]; then
                        SR_ERR="both -r and -R appear in the same flags string ('$1') -- these are different modes and guessing which was meant is not migration"
                        return 1
                    fi
                    SR_REC="$want"; found=1; continue ;;
            esac
            kept="$kept$c"
            case "$FLAGS_ARG_LETTERS" in
                *"$c"*)
                    # The remainder of this token is that option's argument.
                    kept="$kept$rest"
                    [ -n "$rest" ] || want_arg=1
                    rest=""
                    ;;
            esac
        done
        [ -n "$kept" ] && out+=("-$kept")
    done
    if [ "$found" -eq 0 ]; then SR_REST="$1"; return 0; fi
    SR_REST="${out[*]}"
    return 0
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
    local flags="$1" ctx="$2" dst="${3:-}" tok letters
    letters="$(flags_opt_letters "$flags")"
    for tok in $letters; do
        case "$tok" in
            r|R)
                # REV-20260807-054: recursion is 'recursive =' and nothing else.
                # Accepting it here as well would leave two ways to say the same
                # thing, free to disagree -- and they DID disagree: this flag
                # only ever reached the transfer, while the inline prune and the
                # monitor generated from the same section stayed non-recursive,
                # so a new child was copied forever and never pruned or watched.
                local want=flat
                [ "$tok" = r ] && want=atomic
                die "$ctx: flag -$tok in 'flags' -- recursion is no longer expressed as a transfer flag. Use this section's own 'recursive = $want' instead, which also makes the prune and the monitor recursive. See docs/design/recursion-model.md"
                ;;
            f) die "$ctx: flag -f (force full send) not allowed in a recurring job -- it would destroy and re-seed the target every run" ;;
            n) die "$ctx: flag -n (dry-run) not allowed in a recurring job -- it never actually sends anything" ;;
            q)
                case "$letters" in
                    *e*) warn "$ctx: -q has no effect together with -e -- -e reuses an existing snapshot, so there is nothing being created for a freeze to make consistent" ;;
                esac
                ;;
            z|Z|g)
                tok="-$tok"
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

# ---------------------------------------------------------------------------
# Which field names each section kind actually READS.
#
# The parser has always stored every key it saw and only ever asked for the ones
# it knows, so a name it does not know disappeared without a word. That is not a
# theoretical tidiness problem: deploy.sh's --draft-config spent its whole life
# emitting `tiers = ...`, a field that exists nowhere in this script, and the
# only symptom was gen-cron dying with "has no use_template" -- naming a field
# the admin had never been told to write, on a line they had never typed.
#
# The lists mirror the resolve_field/require_field/ini_has call sites; a field
# is listed for a kind when that kind's section is one of the places the lookup
# for it looks. Verified against every live v4 config and every fixture before
# it was turned on -- see PROJECT notes; the v3 files (prune_root) are not live
# and are not expected to pass.
declare -A FIELD_OK=()
_allow_fields() {
    local kind="$1"; shift
    local f; for f in "$@"; do FIELD_OK["${kind}${SEP}${f}"]=1; done
}
# Everything a [template:] can carry, and therefore everything a [dataset:] or
# [prune:] may override on itself.
POLICY_FIELDS="send_schedule prune_schedule prefix pattern keep retain
               tier_label notify notify_raw notify_raw_prune notify_word
               monitor_warn monitor_crit monitor_schedule
               dst src autotune quiesce flags"
# shellcheck disable=SC2086
_allow_fields defaults  host_label repo_dir notify_script warn_script \
                        digest_script cron_log $POLICY_FIELDS
# shellcheck disable=SC2086
_allow_fields template  $POLICY_FIELDS
# pair_label names the RELATIONSHIP (zfs-backup.sh client) a section belongs
# to (REV-20260804-045). On a [dataset:] it reaches the transfer command
# (-L) and that dataset's staleness monitor; on a [prune:] it reaches ONLY
# the section's staleness monitor -- the delsnaps line itself is never
# gated, because retention of what already landed stays correct while a
# relationship is paused; only new transfers and the alarms about their
# absence stop. Deliberately NOT in POLICY_FIELDS: no template/defaults
# inheritance -- a label that silently spread to unrelated sections would
# make one pause skip a stranger's backup.
# shellcheck disable=SC2086
_allow_fields dataset   use_template pair_label recursive $POLICY_FIELDS
# shellcheck disable=SC2086
_allow_fields prune     use_template recursive clear_cut prune ssh_flags \
                        gfs gfs_pattern pair_label $POLICY_FIELDS
_allow_fields prune-bookmarks schedule age pattern recursive ssh_flags notify
_allow_fields excluded  keep

# The single most useful thing to say about a rejected field is "you put it in
# the wrong kind of section", which is a different mistake from "you misspelled
# it" and needs a different fix.
field_valid_elsewhere() {
    local field="$1" k out=""
    for k in defaults template dataset prune prune-bookmarks excluded; do
        [ -n "${FIELD_OK[${k}${SEP}${field}]+x}" ] && out="$out [$k:]"
    done
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# The five paths that end up INSIDE every generated cron line. They were
# settable only through the environment, which meant a config could not describe
# its own host: every line said /root/scripts/*, and a job running as a
# delegated account cannot read notify-fail.sh there nor write cron.log there.
# The failure is quiet in the worst way -- the backup itself works, and only the
# alerting silently goes nowhere.
#
# Precedence: environment > [defaults] > built-in. The environment stays on top
# because that is the ad-hoc, this-one-run override (and what the test harness
# uses); the config is the durable, per-host answer.
#
# Absolute paths only. A relative one would resolve against cron's working
# directory, not the admin's, which is a different directory on every run.
apply_path_settings() {
    _path_setting REPO_DIR      repo_dir       "$REPO_DIR_ENV"
    _path_setting NOTIFY_SCRIPT notify_script  "$NOTIFY_SCRIPT_ENV"
    _path_setting WARN_SCRIPT   warn_script    "$WARN_SCRIPT_ENV"
    _path_setting DIGEST_SCRIPT digest_script  "$DIGEST_SCRIPT_ENV"
    _path_setting CRON_LOG      cron_log       "$CRON_LOG_ENV"
}
_path_setting() {
    local var="$1" field="$2" envval="$3" val
    ini_has defaults "$field" || return 0
    val="$(trim "$(ini_get defaults "$field")")"
    # Blank is rejected rather than ignored, same as pattern=/retain=/prefix=:
    # a field someone bothered to write and left empty is a mistake, not a way
    # of asking for the default.
    [ -n "$val" ] || die "[defaults] has '$field' but it is blank -- give it an absolute path, or remove the line to keep the default"
    case "$val" in
        /*) ;;
        # 'none' is the one non-path value, and only for digest_script: it means
        # "emit no digest line at all". Accepted here so the config field and the
        # DIGEST_SCRIPT environment variable behave identically -- a setting that
        # works one way and is rejected the other is a trap for whoever meets the
        # rejecting half first.
        none) [ "$field" = digest_script ] || die "[defaults] $field='none' is only meaningful for digest_script" ;;
        *) die "[defaults] $field='$val' must be an absolute path -- a relative one resolves against cron's working directory, not yours" ;;
    esac
    # Checked even when the environment is about to out-rank it. Validating only
    # the value that wins would mean a broken config line errors exclusively on
    # the host that happens NOT to set the variable -- which is the worst place
    # to find out, and invisible to a test harness that exports all five.
    [ -n "$envval" ] || printf -v "$var" '%s' "$val"
}

validate_field_names() {
    local key hdr field kind elsewhere
    for key in "${!INI[@]}"; do
        hdr="${key%%${SEP}*}"
        field="${key#*${SEP}}"
        kind="${SECTION_KIND[$hdr]:-}"
        [ -n "$kind" ] || continue
        [ -n "${FIELD_OK[${kind}${SEP}${field}]+x}" ] && continue
        # flags_<tier>: a per-tier override of 'flags', so the tier part cannot
        # be enumerated ahead of time.
        case "$field" in flags_*) [ "$kind" = "dataset" ] && continue ;; esac
        elsewhere="$(field_valid_elsewhere "$field")"
        if [ -n "$elsewhere" ]; then
            die "[$hdr] has '$field', which gen-cron.sh does not read in a [$kind:] section (it is valid in:$elsewhere). Move it, or remove it -- left here it does nothing at all."
        fi
        die "[$hdr] has '$field', which is not a field gen-cron.sh reads anywhere. Check the spelling against the field reference in this script's header. Until now an unknown field was stored and silently ignored, which is why a typo could look like a working config."
    done
}

# resolve_field FIELD DS TMPL DEFAULTS -- prints value, return 1 if unresolved.
# Any of DS/TMPL/DEFAULTS may be "" to skip that layer. Each is a section header.
resolve_field() {
    local field="$1" ds="$2" tmpl="$3" defaults="$4"
    if [ -n "$ds" ] && ini_has "$ds" "$field"; then ini_get "$ds" "$field"; return 0; fi
    if [ -n "$tmpl" ] && ini_has "$tmpl" "$field"; then ini_get "$tmpl" "$field"; return 0; fi
    if [ -n "$defaults" ] && ini_has "$defaults" "$field"; then ini_get "$defaults" "$field"; return 0; fi
    return 1
}

# Same as resolve_field(), but for fields where a BLANK value is exactly as
# broken as a missing one -- 'pattern' has no sensible empty meaning (unlike
# 'dst', where blank legitimately means "no target, snapshot only"). ini_has
# only tests whether the key exists, so "pattern = " with nothing after the
# '=' used to read as "resolved" with an empty string -- a config typo that
# silently produced a delsnaps.sh line with an empty pattern (matches every
# snapshot). Callers use this function, instead of resolve_field(), in any
# case where an empty resolved value would be just as wrong as no value at
# all. 'prefix' and 'gfs_pattern' used to be in this category too (c90f6d1);
# Phase 3.5 gave them a sensible empty/omitted meaning of their own -- see
# resolve_field_or_omit(), defined further down -- so they no longer call
# this function.
require_field() {
    local field="$1" ds="$2" tmpl="$3" defaults="$4" val
    val="$(resolve_field "$field" "$ds" "$tmpl" "$defaults")" || return 1
    [ -n "$val" ] || return 1
    printf '%s' "$val"
}

# Phase 3.5: distinguishes "unresolved anywhere in the inheritance chain"
# (deliberate, accepted absence -- prints "", returns 0, exactly the same
# empty output resolve_field() itself would give a caller that ignored its
# own failure) from "resolved but blank" (a config typo, refused exactly the
# way require_field() has always refused it -- c90f6d1 stays fixed). Only
# for fields that have both an accepted native "not set at all" meaning AND
# a c90f6d1-shaped blank-typo risk: 'prefix' (no-prefix create/existing) and
# 'gfs_pattern' (prefixless single-series GFS ladder). 'pattern' is NOT one
# of these -- it has no accepted omitted meaning and must keep calling
# require_field().
resolve_field_or_omit() {
    local field="$1" ds="$2" tmpl="$3" defaults="$4" val
    if val="$(resolve_field "$field" "$ds" "$tmpl" "$defaults")"; then
        [ -n "$val" ] || return 1
        printf '%s' "$val"
    fi
    return 0
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

    # REV-20260804-045: the relationship (zfs-backup.sh client) this
    # dataset's jobs belong to. Dataset-scope only (no template/defaults
    # inheritance -- a label that silently spread to unrelated datasets
    # would make one pause skip a stranger's backup). Validated to the same
    # charset as the scripts' own -L, because it becomes an -L argument and
    # a state-directory name.
    local pair_label
    pair_label="$(resolve_field pair_label "$ds" "" "")" || pair_label=""
    if [ -n "$pair_label" ]; then
        case "$pair_label" in
            *[!A-Za-z0-9._-]*) die "[dataset:$ds_path]: pair_label='$pair_label' -- letters, digits, dot, dash, underscore only (it becomes snapget/snapsend/check-snap-age -L and a directory name under /var/lib/zfs-snapshot-all/relationships)" ;;
        esac
    fi

    # REV-20260807-054: recursion, declared ONCE for the whole section. The
    # three lines a [dataset:] can generate -- transfer, inline prune, monitor
    # -- all read this, which is the entire point: the old shape let the
    # transfer be recursive (via 'flags = -R') while the prune and the monitor
    # could not be, so a newly created child was replicated forever and never
    # pruned or watched, and the run looked healthy the whole time.
    #
    # Section scope only, like pair_label and like [prune:]'s own 'recursive':
    # a template that silently made an unrelated dataset recursive would be
    # the same class of accident, in the direction that destroys snapshots.
    #
    # An unrecognised value is fatal rather than falsy. "recursive = ture"
    # meaning "no" is precisely the fail-open this whole review exists to
    # remove, and a blank value is a question nobody answered.
    local ds_recursive rec_raw
    if rec_raw="$(resolve_field recursive "$ds" "" "")"; then
        case "$(trim "$rec_raw" | tr '[:upper:]' '[:lower:]')" in
            no)     ds_recursive=no ;;
            flat)   ds_recursive=flat ;;
            atomic) ds_recursive=atomic ;;
            '')     die "[dataset:$ds_path]: 'recursive' is blank -- a blank field is not a default, it is a question nobody answered (say no, flat or atomic)" ;;
            *)      die "[dataset:$ds_path]: recursive = '$rec_raw' -- expected 'no' (this dataset only), 'flat' (each descendant as its own job, snapsend/snapget -R) or 'atomic' (the subtree in one stream, -r). See docs/design/recursion-model.md" ;;
        esac
    else
        ds_recursive=no
    fi
    # Baseline render for --migrate-recursion: the legacy spelling lives in the
    # section's 'flags', so it has to be read HERE, before the tier loop, for
    # the same reason 'recursive' is -- it decides the prune and monitor scope
    # for the whole section, not just for whichever tier happens to be first.
    if [ "$MIGRATE_LEGACY" -eq 1 ]; then
        local legacy_raw
        legacy_raw="$(resolve_field flags "$ds" "" "")" || legacy_raw=""
        if [ -n "$legacy_raw" ]; then
            split_recursion_flags "$legacy_raw" || die "[dataset:$ds_path]: $SR_ERR"
            if [ -n "$SR_REC" ]; then
                [ "$ds_recursive" = no ] || die "[dataset:$ds_path]: has BOTH 'recursive = $ds_recursive' and legacy recursion in flags -- ambiguous, refusing rather than picking one"
                ds_recursive="$SR_REC"
            fi
        fi
    fi

    local rec_send_flag=""
    case "$ds_recursive" in
        flat)   rec_send_flag="-R" ;;
        atomic) rec_send_flag="-r" ;;
    esac
    # delsnaps.sh and check-snap-age.sh have no atomic mode and need none:
    # retention and staleness are per-dataset questions even when the transfer
    # that fed them was one atomic stream. -R is correct for both under either
    # recursive value.
    local rec_scope=0
    [ "$ds_recursive" = no ] || rec_scope=1

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
        # Captured for the create/prune agreement check below. Reset PER TIER:
        # 'prefix' is declared inside the send branch, so a tier that does not
        # send would otherwise still see the previous tier's value and be
        # checked against a family it never creates.
        local tier_created_prefix="" tier_creates=0
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
            # Phase 3.5: 'prefix' omitted across the whole ds/tmpl/defaults
            # chain is now the deliberate no-prefix case (a bare-timestamp
            # create, or an -e passive pickup of an already-named existing
            # snapshot) -- resolves to "", which reaches snapsend.sh/
            # snapget.sh as an explicit -m "" (identical to -m never given).
            # A key that IS present but blank is still refused, unchanged.
            prefix="$(resolve_field_or_omit prefix "$ds" "$tmpl" defaults)" || die "[dataset:$ds_path] tier=$tier: 'prefix' resolved to a blank value -- omit the field entirely for no-prefix, do not set it to nothing"
            tier_created_prefix="$prefix"; tier_creates=1
            flags="$(resolve_field_tiered flags "$tier" "$ds" "$tmpl" "")" || flags=""
            local autotune
            autotune="$(resolve_field autotune "$ds" "$tmpl" defaults)" || autotune=""
            lint_autotune "$autotune" "[dataset:$ds_path] tier=$tier"
            flags="$(maybe_add_autotune "$flags" "$remote_spec" "$autotune")"
            local quiesce
            quiesce="$(resolve_field quiesce "$ds" "$tmpl" defaults)" || quiesce=""
            lint_quiesce "$quiesce" "[dataset:$ds_path] tier=$tier" "$direction"
            flags="$(maybe_add_quiesce "$flags" "$quiesce")"
            # Baseline render for --migrate-recursion: the recursion VALUE was
            # already taken from these flags before the tier loop; here the
            # letters are only stripped out, so lint_flags sees what a migrated
            # config would give it.
            if [ "$MIGRATE_LEGACY" -eq 1 ]; then
                split_recursion_flags "$flags" || die "[dataset:$ds_path] tier=$tier: $SR_ERR"
                flags="$SR_REST"
            fi
            lint_flags "$flags" "[dataset:$ds_path] tier=$tier" "$remote_spec"
            # PREPENDED, where a hand-written flags string would have carried it
            # (the engines take options in any order, but an operator reading a
            # generated line should meet the scope decision before the details).
            # Added after lint_flags on purpose: the lint refuses -r/-R coming
            # from the CONFIG, and must not trip over the one this generator
            # puts there itself.
            [ -n "$rec_send_flag" ] && flags="$rec_send_flag${flags:+ $flags}"
            # Appended to 'flags' rather than carried as a tuple field of its
            # own: flags are part of the send group key, so two relationships
            # can never merge into one cron line that a single pause would
            # have to half-skip -- and emit_send needs no change at all.
            [ -n "$pair_label" ] && flags="${flags:+$flags }-L $pair_label"
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
            # A tier that creates AND prunes must be able to prune what it
            # creates. delsnaps.sh matches by prefix, so the created name has to
            # START WITH the pruned prefix; otherwise this tier's own snapshots
            # are unreachable by its own retention -- they accumulate without
            # bound while every send and every prune still reports success, and
            # the rule instead consumes whichever family DOES match. Same silent
            # shape as REV-20260807-054, caught at generate time.
            #
            # Only when this tier actually creates a NAMED family: prefixless
            # (Phase 3.5) resolves prefix to "" for a bare-timestamp create or an
            # -e passive pickup, where the names come from upstream and 'pattern'
            # is rightly unrelated to anything we stamp.
            #
            # Compared as a LITERAL substring, not with `case ... in "$pattern"*)`:
            # a case arm GLOBS the pattern, so a 'pattern' carrying * ? or [
            # would satisfy the check while delsnaps.sh -- which matches
            # literally -- still matches nothing. That would pass exactly the
            # configs this guard exists to catch.
            if [ "$tier_creates" -eq 1 ] && [ -n "$tier_created_prefix" ] \
               && [ "${tier_created_prefix:0:${#pattern}}" != "$pattern" ]; then
                die "[dataset:$ds_path] tier=$tier: this tier creates snapshots named '${tier_created_prefix}...' but prunes ones matching '${pattern}' -- delsnaps.sh matches by prefix, so nothing this tier creates is ever pruned by this tier, and the created family grows without bound. Make 'pattern' a prefix of 'prefix' (usually they are equal); if this tier is deliberately meant to prune ANOTHER family, give it its own [prune:] section instead."
            fi
            resolve_keep_retain "$ds" "$tmpl" "$tier" || die "[dataset:$ds_path] tier=$tier: ${KEEP_RETAIN_ERROR:-prune_schedule is set but neither 'keep' nor 'retain' resolved}"
            retain_flag="$RESOLVED_RETAIN"
            plabel="$(resolve_field notify "$ds" "$tmpl" "")" || plabel=""
            praw="$(resolve_field notify_raw_prune "" "$tmpl" "")" || praw=""
            if [ -n "$praw" ]; then pnotify="$praw"; else pnotify="$(notify_text "$host_label" "$ntier" "prune" "$plabel")"; fi
            INLINE_PRUNE_ENTITIES+=("${ds_path}${SEP}${tier}${SEP}${pattern}${SEP}${retain_flag}${SEP}${prune_schedule}${SEP}${pnotify}${SEP}${rec_scope}")
            SCOPE_PATTERNS+=("${ds_path}${SEP}${pattern}")

            # ---- monitor (rides this same pattern and the same scope) ----
            if resolve_monitor "$ds" "$tmpl" "[dataset:$ds_path] tier=$tier"; then
                local mnotify mbroken mwarntext
                mnotify="$(notify_text "$host_label" "$ntier" "stale" "$plabel")"
                mbroken="$(notify_text "$host_label" "$ntier" "monitor BROKEN" "$plabel")"
                mwarntext="$(notify_text "$host_label" "$ntier" "getting stale" "$plabel")"
                MONITOR_ENTITIES+=("${ds_path}${SEP}${pattern}${SEP}${MONITOR_WARN}${SEP}${MONITOR_CRIT}${SEP}${MONITOR_SCHEDULE}${SEP}${rec_scope}${SEP}${mnotify}${SEP}${mbroken}${SEP}${mwarntext}${SEP}${pair_label}")
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

    # REV-20260804-045: reaches ONLY this section's staleness monitor below.
    # The delsnaps line itself is never gated by logical pause -- see the
    # comment at the field allow-list.
    local pair_label
    pair_label="$(resolve_field pair_label "$sec" "" "")" || pair_label=""
    if [ -n "$pair_label" ]; then
        case "$pair_label" in
            *[!A-Za-z0-9._-]*) die "[prune:$scope]: pair_label='$pair_label' -- letters, digits, dot, dash, underscore only (it becomes check-snap-age -L and a directory name under /var/lib/zfs-snapshot-all/relationships)" ;;
        esac
    fi

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
        # Phase 3.5: 'gfs_pattern' omitted across the section/defaults chain
        # is now the deliberate prefixless-ladder case -- resolves to "",
        # reaching delsnaps.sh as an explicit empty positional PATTERN
        # argument, matching every otherwise-eligible snapshot on the scope
        # (subject to the same protected-prefix/overlap guards as always). A
        # key that IS present but blank is still refused, unchanged.
        gfs_pattern="$(resolve_field_or_omit gfs_pattern "$sec" "" defaults)" \
            || die "[prune:$scope]: 'gfs_pattern' resolved to a blank value -- omit the field entirely for an intentional prefixless GFS ladder, do not set it to nothing"
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
            MONITOR_ENTITIES+=("${scope}${SEP}${pattern}${SEP}${MONITOR_WARN}${SEP}${MONITOR_CRIT}${SEP}${MONITOR_SCHEDULE}${SEP}${recursive}${SEP}${mnotify}${SEP}${mbroken}${SEP}${mwarntext}${SEP}${pair_label}")
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
    local e ds tier pattern retain schedule notify recursive key
    for e in "${INLINE_PRUNE_ENTITIES[@]}"; do
        IFS="$SEP" read -r ds tier pattern retain schedule notify recursive <<< "$e"
        # 'recursive' is IN the key. A delsnaps.sh line carries -R or it does
        # not, for every dataset it names -- so merging a recursive dataset
        # with a non-recursive one would silently give one of them the wrong
        # scope, either leaving descendants unpruned or pruning descendants
        # nobody asked about.
        key="${schedule}${SEP}${pattern}${SEP}${retain}${SEP}${recursive}"
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
    local e scope pattern warn crit schedule recursive notify broken warntext pairlbl key
    for e in "${MONITOR_ENTITIES[@]}"; do
        IFS="$SEP" read -r scope pattern warn crit schedule recursive notify broken warntext pairlbl <<< "$e"
        # pair_label is IN the key (REV-045): two relationships sharing a
        # threshold shape must not merge into one check-snap-age line --
        # pausing one would silence the staleness alarm of the other.
        key="${schedule}${SEP}${pattern}${SEP}${warn}${SEP}${crit}${SEP}${recursive}${SEP}${pairlbl}"
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
# The pull transfer contract, in ONE place so every caller applies it.
#
# REV-20260808-072 F1: this rule used to live only inside emit_send, which
# --reconcile never reaches. So the audit could certify a config that normal
# generation refuses to execute -- a checker that is more permissive than the
# thing it checks, which is worse than no checker.
#
# Returns status and sets globals rather than echoing, deliberately. If it
# echoed, every caller would write `x="$(pull_check ...)"` and a `die` inside
# that command substitution would kill only the SUBSHELL -- the fail-OPEN
# already recorded in this project once.
PULL_LOCAL_BASE=""
PULL_ERR=""
pull_check() {   # <local dataset> <src value>  -> 0 valid, 1 invalid
    local ds="$1" src="$2" remote_name="${2#*:}"
    PULL_LOCAL_BASE=""; PULL_ERR=""
    if [ "$ds" = "$remote_name" ]; then
        return 0
    elif [[ "$ds" == */"$remote_name" ]]; then
        PULL_LOCAL_BASE="${ds%/$remote_name}"
        return 0
    fi
    PULL_ERR="[dataset:$ds] direction=pull: the local path must end with the remote dataset name ('$remote_name', from src='$src') -- e.g. local dataset:<base>/$remote_name. snapget.sh has no way to reconcile an unrelated local name with a fixed remote one."
    return 1
}

# Every semantic check a config must pass before ANY consumer trusts it.
# Called before the --reconcile branch as well as before emission, so the audit
# and the generator accept exactly the same inputs.
validate_transfer_semantics() {
    local key list ds tier schedule dst prefix flags notify label direction
    for key in "${SEND_GROUP_ORDER[@]+"${SEND_GROUP_ORDER[@]}"}"; do
        list="${SEND_GROUPS[$key]}"
        local -a members=()
        IFS="$LSEP" read -ra members <<< "${list%${LSEP}}"
        IFS="$SEP" read -r ds tier schedule dst prefix flags notify label direction <<< "${members[0]}"
        [ "$direction" = "pull" ] || continue
        if [ "${#members[@]}" -gt 1 ]; then
            die "[dataset:$ds] and other section(s) all resolved the identical src='$dst' -- pull datasets cannot be merged (snapget.sh needs one local destination per literal remote name). Give each a distinct remote path, or split them onto different schedules/prefixes/flags."
        fi
        pull_check "$ds" "$dst" || die "$PULL_ERR"
    done
}

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
            local local_base
            pull_check "$ds" "$dst" || die "$PULL_ERR"
            local_base="$PULL_LOCAL_BASE"
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
#
# BEGIN/END markers (added 2026-08-17 after a live finding). On 2026-08-09 the
# weekly job for pve2's CT 103 fired, exited in under a second and left NO trace
# in ANY of this project's three instruments at once: nothing in cron.log (the
# script never reached its first `log` call), no record in the stats log (it
# never reached `emit_stats`, which fires even for skipped_lock/skipped_paused),
# and no failure mail (rc was never non-zero). The dataset went 14 days without
# a weekly copy and the only reason anyone ever learned of it was check-snap-age
# escalating to CRITICAL five days later.
#
# The structural cause is that every instrument lives INSIDE the engine, so a
# run that dies before the engine really starts is invisible to all of them
# simultaneously. The only place that can witness such a death is the cron line
# itself, which is why the markers belong here and not in snapsend/delsnaps.
#
# BEGIN without a matching END is the signature of exactly that class, and it is
# greppable: `grep ZFS-JOB cron.log`. Two lines per run is a deliberate cost --
# one line carrying only the exit code would still have recorded nothing on
# 2026-08-09, because the failure happened before any exit code existed.
#
# `date -Is` rather than a `date +FORMAT`: cron treats an unescaped `%` in a
# command as end-of-command plus stdin, so a format string here would silently
# truncate every job line in the crontab.
#
# The mktemp fallback closes the one concrete silent-death mechanism identified
# while investigating: bare `e=$(mktemp)` leaves `$e` EMPTY when mktemp fails, an
# empty redirect target makes `2>"$e"` fail, and a failed redirection means the
# command never runs at all -- silently, with no output to carry the reason. The
# fallback lands beside the cron log instead, which is normally a different
# filesystem from TMPDIR, so a full /tmp can no longer swallow a backup whole.
job_cron_line() {
    local schedule="$1" cmd="$2" notify="$3"
    printf '%s echo "$(date -Is) ZFS-JOB BEGIN %s" >>%s; e=$(mktemp 2>/dev/null) || e=%s.err.$$; %s 2>"$e"; rc=$?; cat "$e" >>%s; echo "$(date -Is) ZFS-JOB END %s rc=$rc" >>%s; [ $rc -ne 0 ] && %s "%s" "$(tail -n %s "$e")" 2>>%s; rm -f "$e"' \
        "$schedule" "$notify" "$CRON_LOG" "$CRON_LOG" "$cmd" "$CRON_LOG" \
        "$notify" "$CRON_LOG" "$NOTIFY_SCRIPT" "$notify" "$DETAIL_LINES" "$CRON_LOG"
}

# Inline prune: one delsnaps line per (schedule,pattern,retain,recursive) group,
# listing every member dataset BY FULL PATH.
#
# -R appears here only when the section said 'recursive =' (REV-20260807-054).
# It is never inferred: a group of separately named datasets that happen to
# share a parent is still a list, not a subtree, and collapsing it to a sweep
# would prune snapshots nobody named.
emit_inline_prune() {
    local key list ds tier pattern retain schedule notify recursive
    for key in "${INLINE_PRUNE_GROUP_ORDER[@]}"; do
        list="${INLINE_PRUNE_GROUPS[$key]}"
        local -a members=()
        IFS="$LSEP" read -ra members <<< "${list%${LSEP}}"
        IFS="$SEP" read -r ds tier pattern retain schedule notify recursive <<< "${members[0]}"

        local -a targets=()
        local m mds mtier mpat mret msch mnot mrec
        for m in "${members[@]}"; do
            IFS="$SEP" read -r mds mtier mpat mret msch mnot mrec <<< "$m"
            targets+=("$mds")
        done
        local joined
        joined="$(IFS=,; printf '%s' "${targets[*]}")"

        local rflag=""
        [ "$recursive" = "1" ] && rflag="-R "
        local cmd="$REPO_DIR/delsnaps.sh ${rflag}${PROTECT_FLAGS}\"$joined\" \"$pattern\" $retain"
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
    local key list scope pattern warn crit schedule recursive notify broken warntext pairlbl
    for key in "${MONITOR_GROUP_ORDER[@]}"; do
        list="${MONITOR_GROUPS[$key]}"
        local -a members=()
        IFS="$LSEP" read -ra members <<< "${list%${LSEP}}"
        IFS="$SEP" read -r scope pattern warn crit schedule recursive notify broken warntext pairlbl <<< "${members[0]}"

        local -a targets=()
        local m mscope mpat mwarn mcrit msch mrec mnot mbrk mwtxt mplbl
        for m in "${members[@]}"; do
            IFS="$SEP" read -r mscope mpat mwarn mcrit msch mrec mnot mbrk mwtxt mplbl <<< "$m"
            targets+=("$mscope")
        done
        local joined
        joined="$(IFS=,; printf '%s' "${targets[*]}")"

        local flag="" lflag=""
        [ "$recursive" = "1" ] && flag="-R "
        # REV-045: while the relationship is paused, its staleness IS the
        # expected state -- check-snap-age -L reports OK-paused instead of
        # paging every monitor interval for a backup that was stopped on
        # purpose. Resume restores normal thresholds with no other change.
        [ -n "$pairlbl" ] && lflag="-L $pairlbl "
        local cmd="$REPO_DIR/check-snap-age.sh ${flag}${lflag}\"$joined\" \"$pattern\" $warn $crit"
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
# The block as it is PRINTED: markers included, because stdout is documented to
# be the crontab block itself (`gen-cron.sh > file` has to produce something
# installable).
generate_block() {
    echo "$MARKER_BEGIN"
    generate_block_body
    echo "$MARKER_END"
}

# The same content WITHOUT the markers -- what lib-cron.sh installs, since the
# markers are the library's business and it refuses a body carrying its own
# (a nested marker would make the next block's extent ambiguous).
generate_block_body() {
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
    # digest_script = none: emit no digest line at all. There is exactly ONE
    # digest per host by design -- two would mean two mails a day -- and a
    # delegated account's crontab is the case that needs to opt out: deploy.sh
    # gives such an account its own notify-fail/notify-warn but deliberately
    # does NOT copy alert-digest.sh to it, precisely so root stays the only
    # sender. Without this switch that account's block would schedule a digest
    # script that is not there.
    if [ "${#MONITOR_LINES[@]}" -gt 0 ] && [ "$DIGEST_SCRIPT" != "none" ]; then
        echo ""
        # Redirected like every other generated line: the digest is silent on
        # the happy path, but it reports a failed mail delivery on stderr, and
        # an unredirected stderr here is a cron mail -- from the very script
        # whose job is to be the only mail this host sends.
        echo "$DIGEST_SCHEDULE $DIGEST_SCRIPT 2>>$CRON_LOG"
    fi
}
###############################################################################
#END 4

###############################################################################
#BEGIN 5 [IDEMPOTENT CRONTAB INSTALL]
###############################################################################
install_crontab() {
    command -v flock >/dev/null || die "flock command not found"
    command -v crontab >/dev/null || die "crontab command not found"

    # Same discipline as lib-cron.sh's cron_lock_acquire, and for the same
    # reasons -- this used to be a bare `exec 200>"$LOCKFILE"` whose failure
    # was then reported as "another --install is already running", which was
    # simply untrue: nothing was running, the file could not be opened. A lock
    # that misdiagnoses its own failure sends the operator looking for a
    # process that does not exist.
    local lockdir; lockdir="$(dirname "$LOCKFILE")"
    [ -d "$lockdir" ] && [ -w "$lockdir" ] \
        || die "the lock directory $lockdir is missing or not writable by $(id -un 2>/dev/null || echo '?') -- refusing to install rather than locking somewhere another writer would not look. Run deploy.sh to (re)create it (2775 root:zfsalert)."
    # A predictable path in a directory writable by more than one identity is
    # where a symlink can be pre-planted to redirect the open below.
    [ -L "$LOCKFILE" ] && die "$LOCKFILE is a symlink -- refusing to lock through it"
    # Probe with a scoped redirect first: a trailing 2>/dev/null on a bare
    # `exec` would apply to the whole shell permanently, not to the attempt.
    if ! : >"$LOCKFILE" 2>/dev/null; then
        die "could not open the lock file $LOCKFILE$([ -e "$LOCKFILE" ] && printf ' -- it exists but is not writable by %s. A lock file created by an earlier root-side run with a 0644 umask does this; fix once with: chmod 664 %s' "$(id -un 2>/dev/null || echo '?')" "$LOCKFILE")"
    fi
    # The truncate above used the CALLER's umask. Root usually gets here first
    # on a fresh host, and a 0644 root-owned file then locks the account out of
    # its own crontab for good. The setgid group directory scopes WHO shares
    # the lock; the file has to be group-writable for that to mean anything.
    chmod 664 "$LOCKFILE" 2>/dev/null || :
    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
        die "another gen-cron.sh --install is already running (lock: $LOCKFILE) -- retry once it finishes"
    fi

    local me; me=$(id -un)

    # The one check that is gen-cron's own policy rather than the writer's: a
    # crontab with no managed block but with loose snapsend/delsnaps lines in it
    # is somebody's hand-built schedule. Installing next to it runs both, on
    # overlapping schedules -- which is what happened on 192.168.11.11 -- so it
    # refuses and names the lines.
    #
    # Deliberately BEFORE the install: lib-cron.sh preserves everything outside
    # its block, which is exactly why it would happily leave those lines running.
    local current
    current=$(mktemp) || die "mktemp failed"
    cron_read "$me" "$current" || { rm -f "$current"; die "$CRON_ERR"; }
    if ! grep -qE '^# BEGIN zfs-backup-managed' "$current" && [ -s "$current" ]; then
        local conflicts
        conflicts="$(grep -E 'snapsend\.sh|delsnaps\.sh|check-snap-age\.sh' "$current" || true)"
        if [ -n "$conflicts" ]; then
            {
                echo "gen-cron.sh: error: crontab has no managed block yet, but already contains"
                echo "lines calling snapsend.sh/delsnaps.sh/check-snap-age.sh (listed below)."
                echo "Appending blindly would run these jobs twice on overlapping schedules --"
                echo "this is exactly what happened on pve1.11 (192.168.11.11) previously."
                echo "Remove or migrate the old lines by hand first, then re-run --install."
                echo "--- conflicting existing lines ---"
                printf '%s
' "$conflicts"
            } >&2
            rm -f "$current"
            exit 1
        fi
    fi
    rm -f "$current"

    # Everything else -- locating the block, refusing a malformed one, keeping
    # every other line byte for byte, writing and reading back -- belongs to the
    # single writer. This function used to do all of it again, in its own way.
    local body
    body=$(mktemp) || die "mktemp failed"
    generate_block_body > "$body" || { rm -f "$body"; die "could not render the block"; }
    local rc=0
    cron_block_install "$me" zfs-backup-managed "$body" "$MARKER_TAIL" || rc=$?
    rm -f "$body"
    if [ "$rc" -ne 0 ]; then
        die "$CRON_ERR"
    fi
    if [ "${CRON_CHANGED:-1}" -eq 0 ]; then
        echo "gen-cron.sh: no changes -- crontab already up to date" >&2
        return 0
    fi
    echo "gen-cron.sh: crontab updated from $CONFIG" >&2
}
###############################################################################
#END 5

###############################################################################
#BEGIN 5b [RECURSION SCHEMA MIGRATION]  (REV-20260807-057)
#
# v4.27 hard-rejects `-r`/`-R` inside a [dataset:]'s 'flags'. That rejection is
# correct, but on its own it left a live config that the installed generator
# refuses -- the next administrator trying to REPAIR something would meet the
# refusal at the worst moment. This is the bounded path from the old accepted
# representation to the new one.
#
# It migrates the config and NOTHING else. It never touches the crontab: if the
# migrated config reproduces the installed block, there is nothing to install.
###############################################################################

# Rewrites the config text. Returns the new text on stdout, and sets
# MIG_REPORT (one "section<TAB>value" line per migrated section).
migrate_rewrite() {   # <config file>
    local file="$1" line key val sec="" indent
    local n=0
    MIG_REPORT=""
    MIG_COUNT=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n+1))
        case "$line" in
            '['*']')
                sec=""
                case "$line" in
                    '[dataset:'*) sec="${line#[dataset:}"; sec="${sec%]}" ;;
                esac
                printf '%s\n' "$line"
                continue ;;
        esac
        # Only a 'flags' assignment inside a [dataset:] section is a candidate.
        # Whitespace around the key and the '=' is free-form in live configs
        # (pve2 has "flags         = -e -v 3"), so it is matched, not assumed.
        if [ -n "$sec" ]; then
            key="${line%%=*}"
            if [ "$key" != "$line" ]; then
                local bare="$key"
                bare="${bare#"${bare%%[![:space:]]*}"}"
                bare="${bare%"${bare##*[![:space:]]}"}"
                if [ "$bare" = flags ]; then
                    val="${line#*=}"
                    val="${val#"${val%%[![:space:]]*}"}"
                    val="${val%"${val##*[![:space:]]}"}"
                    if ! split_recursion_flags "$val"; then
                        MIG_ERR="line $n, [dataset:$sec]: $SR_ERR"
                        return 1
                    fi
                    if [ -n "$SR_REC" ]; then
                        # Reuse the line's own indentation AND its '=' column,
                        # so the migrated file keeps the shape its author gave
                        # it. These configs align their values; leaving two
                        # lines out of column makes a hand-maintained file look
                        # machine-mangled, which is how people stop trusting
                        # the tool that touched it.
                        indent="${line%%[![:space:]]*}"
                        local eqcol pad
                        eqcol=$(( ${#key} - ${#indent} ))
                        pad=$(( eqcol - 9 )); [ "$pad" -lt 1 ] && pad=1     # 9 = len("recursive")
                        printf '%s%s%*s= %s\n' "$indent" "recursive" "$pad" "" "$SR_REC"
                        # A flags value that is now empty loses its line
                        # entirely -- "flags = " is not a tidier way to say
                        # nothing, it is a field someone will wonder about.
                        if [ -n "$SR_REST" ]; then
                            pad=$(( eqcol - ${#bare} )); [ "$pad" -lt 1 ] && pad=1
                            printf '%s%s%*s= %s\n' "$indent" "$bare" "$pad" "" "$SR_REST"
                        fi
                        MIG_REPORT="${MIG_REPORT}${sec}	${SR_REC}
"
                        MIG_COUNT=$((MIG_COUNT+1))
                        continue
                    fi
                fi
            fi
        fi
        printf '%s\n' "$line"
    done < "$file"
    return 0
}

# Renders a config to its managed block, NORMALISED for comparison. $1 =
# config, $2 = 1 for the legacy baseline. Runs this same script as a child so
# the two renders cannot share global state.
#
# Two lines are dropped, and neither is cosmetic:
#   - the BEGIN/END markers, because cron_block_read returns the block's
#     CONTENTS and comparing content against a marked-up render would differ
#     every time, for a reason that has nothing to do with the migration;
#   - "# Source: <path>", because the migrated config is rendered from a temp
#     file. Left in, every migration would look like a change to the one line
#     that only ever names where the config was read from.
migrate_normalise() { grep -vE '^# (BEGIN|END) zfs-backup-managed|^# Source: '; }

migrate_render() {   # <config> <legacy 0|1>  -> normalised block on stdout
    local self="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
    if [ "$2" -eq 1 ]; then
        "$self" --internal-legacy-render -c "$1" | migrate_normalise
    else
        "$self" -c "$1" | migrate_normalise
    fi
}

# Finds the ONE installed managed block that belongs to <config>, whoever owns
# the crontab it lives in (REV-20260807-058 F1).
#
# The problem this solves: on this fleet configs are root:root 0644 in /etc, so
# only root can commit a migration -- but the managed block belongs to the
# DELEGATED ACCOUNT. Reading only the current user's crontab meant the
# strongest control was unavailable in the only mode that can write the file,
# and the command degraded to a weaker two-way proof while still committing.
# A two-way proof preserves pre-existing drift, which is exactly what the
# three-way structure exists to catch.
#
# Binding key is the block's own "# Source:" line. Candidates: this user, plus
# every passwd user when running as root -- `getent passwd` rather than a cron
# spool path, because the spool location is distro-specific and a wrong guess
# would silently narrow the search.
#
# Sets MCB_BLOCK / MCB_USER. Returns 0 found, 1 none anywhere, 2 refuse (MCB_ERR).
migrate_find_control_block() {   # <config file>
    local file="$1" canon who cur src n=0
    MCB_BLOCK=""; MCB_USER=""; MCB_ERR=""; MCB_WHY=""
    canon="$(readlink -f "$file" 2>/dev/null || printf '%s' "$file")"

    # No cron at all is a DECIDED state, not an uncertain one: nothing can be
    # installed on a system with no crontab(1), so "not installed" is proved
    # rather than assumed. Kept distinct from "a crontab exists and could not
    # be read", which is uncertainty and must refuse (REV-058 §8).
    if ! command -v crontab >/dev/null 2>&1; then
        MCB_WHY="this system has no crontab(1), so no config can be installed anywhere"
        return 1
    fi

    local -a users=()
    users+=("$(id -un)")
    if [ "$(id -u)" = 0 ]; then
        local list
        if ! list="$(getent passwd 2>/dev/null | cut -d: -f1)" || [ -z "$list" ]; then
            # Refusing rather than falling back to "just me": a narrowed search
            # that finds nothing is indistinguishable from a config that is
            # genuinely not installed, and one of those may be committed safely
            # while the other may not.
            MCB_ERR="running as root but the user list could not be read (getent passwd) -- cannot prove which crontab holds this config's installed block"
            return 2
        fi
        while IFS= read -r who; do
            [ -n "$who" ] && [ "$who" != "$(id -un)" ] && users+=("$who")
        done <<< "$list"
    fi

    MCB_WHY="searched every user's crontab"
    cur="$(mktemp)" || { MCB_ERR="mktemp failed"; return 2; }
    for who in "${users[@]}"; do
        if ! cron_read "$who" "$cur"; then
            # An unreadable crontab is not an empty one. Treating it as empty
            # here is precisely how the proof would go missing again.
            rm -f "$cur"
            MCB_ERR="could not read ${who}'s crontab, so the installed state cannot be proved: ${CRON_ERR:-unknown error}"
            return 2
        fi
        cron_block_locate "$cur" zfs-backup-managed || continue
        [ "$CRON_B" -gt 0 ] && [ "$CRON_E" -gt $((CRON_B+1)) ] || continue
        local body
        body="$(sed -n "$((CRON_B+1)),$((CRON_E-1))p" "$cur")"
        src="$(printf '%s\n' "$body" | sed -n 's/^# Source: \(.*\) -- DO NOT EDIT.*$/\1/p' | head -1)"
        [ -n "$src" ] || continue
        [ "$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")" = "$canon" ] || continue
        n=$((n+1))
        if [ "$n" -gt 1 ]; then
            rm -f "$cur"
            MCB_ERR="two crontabs (${MCB_USER} and ${who}) both hold a managed block naming $file -- which one is authoritative is a guess, so nothing is migrated"
            return 2
        fi
        MCB_BLOCK="$body"; MCB_USER="$who"
    done
    rm -f "$cur"
    [ "$n" -eq 1 ] && return 0
    return 1
}

migrate_recursion() {   # <config file>
    local file="$1"
    [ -w "$file" ] || die "cannot write $file -- migration would not be able to commit"

    local work
    work="$(mktemp)" || die "could not create a work file"
    # shellcheck disable=SC2064
    trap "rm -f '$work' '$work.base' '$work.mig'" EXIT

    # NOT in a command substitution: that runs the rewriter in a subshell, and
    # MIG_COUNT/MIG_REPORT would be set in a shell that then exits.
    if ! migrate_rewrite "$file" > "$work"; then
        die "refusing to migrate: ${MIG_ERR:-unrepresentable input}"
    fi

    if [ "$MIG_COUNT" -eq 0 ]; then
        echo "$file: no legacy recursion in any [dataset:] 'flags' -- nothing to migrate."
        return 0
    fi

    # ---- the three-way comparison, control FIRST ---------------------------
    # A comparison whose baseline is not itself verified proves nothing. That
    # mistake was made by hand during REV-055 and caught only because the
    # control differed; it is mechanised here so it cannot be skipped.
    echo "checking that the migration changes nothing that runs..."
    migrate_render "$file" 1 > "$work.base" 2>/dev/null \
        || die "could not render the CURRENT config even in legacy mode -- aborting before touching anything"
    migrate_render "$work" 0 > "$work.mig" 2>/dev/null \
        || die "the migrated config does not generate -- aborting, $file is untouched"

    if ! diff -q "$work.base" "$work.mig" >/dev/null; then
        echo "REFUSED: the migrated config would generate a DIFFERENT crontab block." >&2
        diff "$work.base" "$work.mig" >&2
        die "$file is untouched"
    fi
    echo "  before/after render: identical"

    # Control: does the CURRENT config still describe what is installed? If it
    # does not, that mismatch predates this migration and is the operator's to
    # resolve -- migrating on top of it would silently adopt the drift.
    #
    # Only when the installed block actually CAME FROM this config. The block
    # records that in its own "# Source:" line, which is exactly what it is
    # for. Comparing against whatever this user happens to have installed would
    # abort every migration of a second config, a staging copy or a test
    # fixture with a "pre-existing drift" message that is simply untrue --
    # found by running this suite as the delegated account on a host whose
    # crontab holds a different config's block.
    local installed rc_find=0
    migrate_find_control_block "$file" || rc_find=$?
    case "$rc_find" in
        2) echo "REFUSED: $MCB_ERR" >&2; die "$file is untouched" ;;
        1) echo "  installed crontab block: none -- ${MCB_WHY}; there is no installed state to prove, proceeding" ;;
        0) installed="$(printf '%s\n' "$MCB_BLOCK" | migrate_normalise)"
           echo "  installed crontab block: found in ${MCB_USER}'s crontab" ;;
    esac
    if [ -n "$installed" ]; then
        if diff -q <(printf '%s\n' "$installed") "$work.base" >/dev/null 2>&1; then
            echo "  installed crontab block: matches (control passed)"
        else
            echo "NOTE: the installed managed block does not match what this config renders," >&2
            echo "      and that is true BEFORE the migration as well -- so it is pre-existing" >&2
            echo "      drift, not something this migration would cause. Resolve it first:" >&2
            echo "      the usual cause is a render environment (REPO_DIR/CRON_LOG/NOTIFY_SCRIPT/" >&2
            echo "      WARN_SCRIPT/DIGEST_SCRIPT) different from the one the block was made with." >&2
            die "$file is untouched"
        fi
    fi

    # ---- transactional commit ----------------------------------------------
    local backup stage
    backup="${file}.pre-recursion.$(date +%Y%m%d-%H%M%S)"
    cp -p "$file" "$backup" || die "could not write the rollback copy $backup"
    stage="${file}.migrating.$$"
    # cp -p first so the staged file inherits owner and mode from the original;
    # the content is then overwritten in place, and the rename carries both.
    cp -p "$file" "$stage" || die "could not stage the new config"
    cat "$work" > "$stage" || { rm -f "$stage"; die "could not write the staged config"; }
    # Read back before the rename: a short write here becomes a live config.
    if ! diff -q "$stage" "$work" >/dev/null; then
        rm -f "$stage"
        die "the staged config does not match what was validated -- $file is untouched"
    fi
    mv -f "$stage" "$file" || die "could not commit the migrated config (rollback copy: $backup)"

    echo
    echo "$file: MIGRATED"
    printf '%s' "$MIG_REPORT" | while IFS="	" read -r s v; do
        [ -n "$s" ] && echo "  [dataset:$s] -> recursive = $v"
    done
    echo "  rollback copy: $backup"
    echo "  crontab: NOT touched -- the generated block is unchanged, so there is nothing to install."
    return 0
}

###############################################################################
#BEGIN 6 [MAIN]
###############################################################################
CONFIG=""
INSTALL=0
MIGRATE=0

while [ $# -gt 0 ]; do
    case "$1" in
        -c) CONFIG="$2"; shift 2 ;;
        --install) INSTALL=1; shift ;;
        --migrate-recursion) MIGRATE=1; shift ;;
        --reconcile) RECONCILE=1; shift ;;
        # Undocumented, and deliberately so: it renders a PRE-v4.27 config as
        # the baseline --migrate-recursion compares against. Refused together
        # with --install below, so it can only ever reach stdout.
        --internal-legacy-render) MIGRATE_LEGACY=1; shift ;;
        -V|--version) echo "$VERSION"; exit 0 ;;
        # Prints "<kind> <field>" for every accepted field and exits. Exists so
        # the suite can check the allow-list against the lookups in the code
        # WITHOUT re-parsing this file's source text -- a check that scrapes the
        # declaration would break on a line continuation rather than on a real
        # drift, and a test that fails for formatting reasons gets muted.
        --dump-fields)
            for _k in "${!FIELD_OK[@]}"; do printf '%s %s\n' "${_k%%${SEP}*}" "${_k#*${SEP}}"; done | sort
            exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (see -h)" ;;
    esac
done

[ "$MIGRATE_LEGACY" -eq 1 ] && [ "$INSTALL" -eq 1 ] \
    && die "--internal-legacy-render cannot be combined with --install: it renders a config shape this version refuses, and must never reach a crontab"
[ "$MIGRATE" -eq 1 ] && [ "$INSTALL" -eq 1 ] \
    && die "--migrate-recursion migrates the CONFIG only and never installs -- run --install separately if you actually want to reinstall"

###############################################################################
# --reconcile: what the config backs up, against what actually exists
###############################################################################
#
# The failure this answers, from this fleet and not from imagination: VM 104 on
# pve0 ran with ZERO automated snapshots because it was created after the config
# was written, and nothing ever compared those two facts. A config enumerates;
# reality grows.
#
# READ-ONLY. It never edits a config, never writes a crontab, never touches a
# snapshot. It reports and sets an exit code.
#
# "Covered" means A SEND JOB EXISTS -- not "some rule mentions it". A dataset
# with only a prune rule is being trimmed, not backed up, and calling that
# covered would reproduce the exact silence being hunted.
#
# System datasets are LISTED AND MARKED, never silently dropped. deploy.sh's
# --draft-scope excludes them because it decides what to ACTIVATE by default,
# where a narrow default is the safe direction. Here the dangerous direction is
# the opposite: an omission is invisible, and invisibility is the whole bug. So
# the audit shows them and says why it is not counting them.

RECONCILE_SYSTEM_NAMES="ROOT swap"

# A system ANCHOR is a depth-1 dataset whose LAST component is exactly one of
# the names above -- never a substring, so a workload called "swap-backups" or
# "rootfs" is never mistaken for Proxmox's own.
reconcile_is_system_anchor() {   # <dataset>
    local ds="$1" n
    case "$ds" in */*/*) return 1 ;; */*) ;; *) return 1 ;; esac
    for n in $RECONCILE_SYSTEM_NAMES; do
        [ "${ds##*/}" = "$n" ] && return 0
    done
    return 1
}

# The anchor AND everything beneath it. REV-20260808-071 F2: `rpool/ROOT/pve-1`
# is the ordinary Proxmox boot dataset and was being reported as an uncovered
# workload, because the old rule matched the anchor only.
#
# The boundary that must survive: depth alone does not make something system.
# `rpool/data/swap` is deeper than an anchor but is not BENEATH one, so it stays
# an ordinary finding -- which is the whole reason the check is anchored rather
# than matching the last component anywhere in the path.
reconcile_is_system() {   # <dataset>
    local ds="$1" anchor="${1%%/*}/${1#*/}" head
    reconcile_is_system_anchor "$ds" && return 0
    case "$ds" in */*/*) ;; *) return 1 ;; esac
    head="${ds%%/*}/$(printf '%s' "${ds#*/}" | cut -d/ -f1)"
    reconcile_is_system_anchor "$head" && return 0
    return 1
}

# Guest attribution, for a report a human can act on. ATTRIBUTION ONLY -- it
# labels a finding, it never decides one, which is why matching on names is
# acceptable here and was not when I once read disk names to decide what was an
# orphan and nearly proposed destroying VM 107's EFI and TPM state.
#
# The volume names come from `qm config` / `pct config`, which is authoritative
# for every disk a guest has, including efidisk0 and tpmstate0.
declare -A RECONCILE_GUEST_OF=()

reconcile_guest_map() {
    command -v qm >/dev/null 2>&1 || command -v pct >/dev/null 2>&1 || return 0
    local tool listcmd id vol base
    for tool in qm pct; do
        command -v "$tool" >/dev/null 2>&1 || continue
        while read -r id _; do
            case "$id" in ''|*[!0-9]*) continue ;; esac
            while IFS= read -r vol; do
                base="${vol##*/}"; base="${base##*:}"
                [ -n "$base" ] && RECONCILE_GUEST_OF["$base"]="$tool/$id"
            done < <("$tool" config "$id" 2>/dev/null \
                     | sed -n 's/^[a-z]*[0-9]*:[[:space:]]*\([^,]*\).*/\1/p')
        done < <("$tool" list 2>/dev/null | tail -n +2)
    done
}

reconcile_label() {   # <dataset> -> " (qm/104)" or ""
    local g="${RECONCILE_GUEST_OF[${1##*/}]:-}"
    [ -n "$g" ] && printf ' (%s)' "$g"
}

# Received trees: what THIS host's jobs WRITE, as opposed to what they read.
#
# REV-20260808-071 F1. The first version compared against send jobs only and
# never asked what any job writes, so a collector's received tree came back as
# "exists, and no send job backs it up" -- demanding that a backup be backed up.
# On pve2 that was most of the output, and the guest label made it read as
# "guest 103 is unprotected" when that dataset IS guest 103's copy.
#
# Derived from the CONFIG topology, never from names. A path is not classified
# as received because it contains "backup"; it is classified because a job in
# this file writes there.
#
#   push, LOCAL dst   ->  <dst>/<source path>          derivable here
#   push, REMOTE dst  ->  the target is on the PEER     NOT derivable here
#   pull, src=h:R     ->  <section path>/<R>            derivable here
#
# The middle row is a real limit and is reported rather than guessed: an inbound
# push is declared in the SENDING host's config, which this host does not have.
# Inventing a rule for it would be exactly the quiet-classification the review
# forbids.
reconcile_receive_roots() {   # -> one root per line
    local e ds tier sched remote rest
    for e in "${SEND_ENTITIES[@]+"${SEND_ENTITIES[@]}"}"; do
        IFS="$SEP" read -r ds tier sched remote rest <<< "$e"
        [ -n "$ds" ] || continue
        case "$rest" in
            *"${SEP}pull") 
                # A VALID pull section's own path ALREADY ends with the literal
                # remote dataset name -- emit_send enforces that contract -- so
                # the local receive root is the section dataset itself.
                #
                # REV-20260808-071 interim direction 3: my first version wrote
                # <section>/<remote name>, and the test that "proved" it used a
                # config normal generation REJECTS. It passed only because
                # --reconcile returns before emit_send validates the suffix. A
                # test that cannot exist as a real config proves nothing.
                printf '%s
' "$ds" ;;
            *)
                # push: only a LOCAL destination lands on this host. A remote
                # one writes on the peer and is not derivable here -- reported
                # as a limit rather than guessed.
                [ -n "$remote" ] || continue
                case "$remote" in *:*|*@*) continue ;; esac
                printf '%s/%s
' "$remote" "$ds" ;;
        esac
    done
}

# The container levels a receive creates on its way to the root: `tank/store`
# and `tank/store/tank` on the way to `tank/store/tank/vm-1`. They exist only
# because the job writes through them, so calling them unprotected workloads is
# the same false finding one level up.
#
# Matched EXACTLY by the caller, never as a subtree. Declaring `tank/store` a
# receive root outright would be simpler and would quietly absolve anything an
# operator later put beneath it, including a real workload. `tank/store-other`
# and `tank/store/something-else` must still be found.
reconcile_receive_structure() {   # <root>... -> ancestor paths, one per line
    local r p rest
    for r in "$@"; do
        [ -n "$r" ] || continue
        p="${r%%/*}"
        rest="${r#*/}"
        while :; do
            case "$rest" in
                */*) p="$p/${rest%%/*}"; rest="${rest#*/}"; printf '%s
' "$p" ;;
                *)   break ;;
            esac
        done
    done
}

# A structural container: every child is covered, and it holds no data of its
# own. `rpool/data` and `hdd/vm-disks` are the fleet's examples -- they exist
# only to group vm-*-disk-* beneath them.
#
# Owner decision 2026-08-08: suppress these. The reasoning is the project's own:
# snapsend's -S flag is documented as exactly this case, "the container case:
# rpool/data holds no data of its own and exists only to group vm-*-disk-*
# beneath it". Alerting that a container has no snapshot, when backing up its
# children individually is the deliberate design, is noise.
#
# TWO guards, because "suppress the parent" done carelessly hides real data:
#
#   * EVERY child must be covered. One uncovered child and the parent stays a
#     finding, because then it is not a solved container.
#   * It must hold no data OF ITS OWN -- usedbydataset above a small floor means
#     somebody put files directly in it, and that data has no backup.
#
# Suppressed means "not counted and not alerted", NOT invisible: they are
# printed under their own heading, like the system datasets.
RECONCILE_CONTAINER_MAX_OWN=1048576   # 1 MiB: an empty ZFS filesystem is ~100 KiB

reconcile_is_container() {   # <dataset> ; needs COVERED_LIST in the caller
    local ds="$1" child own kids=0
    own="$(zfs get -Hp -o value usedbydataset -- "$ds" 2>/dev/null)"
    case "$own" in ''|*[!0-9]*) return 1 ;; esac
    [ "$own" -gt "$RECONCILE_CONTAINER_MAX_OWN" ] && return 1
    while IFS= read -r child; do
        [ -n "$child" ] || continue
        [ "$child" = "$ds" ] && continue
        kids=$((kids+1))
        [ -n "${covered[$child]:-}" ] || return 1
    done < <(zfs list -H -o name -r -- "$ds" 2>/dev/null)
    [ "$kids" -gt 0 ]
}

do_reconcile() {
    command -v zfs >/dev/null 2>&1 || die "--reconcile needs zfs on this host"

    local -A covered=()
    local section ds mode line
    local -a missing=()

    # Coverage is derived from the send entities the generator ACTUALLY built,
    # and only from PUSH ones.
    #
    # REV-20260808-071 interim direction 4: the first version walked every
    # [dataset:] section and called it covered before asking whether any tier
    # resolves a send schedule -- so a prune-only or monitor-only section looked
    # backed up. It also counted a PULL section's local destination as
    # source-side coverage, which is backwards: that path is where a copy
    # LANDS.
    local e etier esched eremote eprefix eflags enotify elabel edir
    for e in "${SEND_ENTITIES[@]+"${SEND_ENTITIES[@]}"}"; do
        IFS="$SEP" read -r ds etier esched eremote eprefix eflags enotify elabel edir <<< "$e"
        [ -n "$ds" ] || continue
        [ "$edir" = "pull" ] && continue
        if ! zfs list -H -o name -- "$ds" >/dev/null 2>&1; then
            case " ${missing[*]-} " in *" $ds "*) ;; *) missing+=("$ds") ;; esac
            continue
        fi
        mode="$(resolve_field recursive "dataset:$ds" "" "" || true)"
        case "$mode" in
            flat|atomic)
                # -S and -X change WHICH datasets the run actually touches, so
                # coverage has to honour them. Expanding with a plain
                # `zfs list -r` claims coverage for a parent the engine skips
                # (-S) or for a child it filters out (-X) -- a FALSE NEGATIVE,
                # the direction that hides an unprotected dataset. Latent
                # rather than live today: no config in this fleet uses either.
                local skip_parent=0 oletter oarg
                local -a excl=()
                while IFS="$(printf '	')" read -r oletter oarg; do
                    case "$oletter" in
                        S) skip_parent=1 ;;
                        X) [ -n "$oarg" ] && excl+=("$oarg") ;;
                    esac
                done < <(flags_opt_pairs "$eflags")
                while IFS= read -r line; do
                    [ -n "$line" ] || continue
                    [ "$skip_parent" -eq 1 ] && [ "$line" = "$ds" ] && continue
                    local rx dropped=0
                    for rx in "${excl[@]+"${excl[@]}"}"; do
                        printf '%s' "$line" | grep -Eq -- "$rx" && { dropped=1; break; }
                    done
                    [ "$dropped" -eq 1 ] && continue
                    covered["$line"]=1
                done < <(zfs list -H -o name -r -- "$ds" 2>/dev/null) ;;
            *)  covered["$ds"]=1 ;;
        esac
    done

    reconcile_guest_map

    local -a recv_roots=() recv_struct=()
    mapfile -t recv_roots < <(reconcile_receive_roots | sort -u)
    mapfile -t recv_struct < <(reconcile_receive_structure "${recv_roots[@]+"${recv_roots[@]}"}" | sort -u)

    local -a uncovered=() systems=() received=() containers=()
    while IFS= read -r ds; do
        [ -n "$ds" ] || continue
        case "$ds" in */*) ;; *) continue ;; esac      # a pool root is not a workload
        [ -n "${covered[$ds]:-}" ] && continue
        local r hit=0
        for r in "${recv_roots[@]+"${recv_roots[@]}"}"; do
            [ -z "$r" ] && continue
            if [ "$ds" = "$r" ] || case "$ds" in "$r"/*) true ;; *) false ;; esac; then hit=1; break; fi
        done
        if [ "$hit" -eq 0 ]; then
            for r in "${recv_struct[@]+"${recv_struct[@]}"}"; do
                [ "$ds" = "$r" ] && { hit=1; break; }
            done
        fi
        if [ "$hit" -eq 1 ];        then received+=("$ds")
        elif reconcile_is_system "$ds";    then systems+=("$ds")
        elif reconcile_is_container "$ds"; then containers+=("$ds")
        else                                    uncovered+=("$ds"); fi
    done < <(zfs list -H -o name -t filesystem,volume 2>/dev/null | sort)

    echo "=== scope reconciliation: $CONFIG on $(hostname -s 2>/dev/null || hostname)"
    echo
    echo "covered by a send job: ${#covered[@]} dataset(s)"
    echo

    if [ "${#uncovered[@]}" -gt 0 ]; then
        echo "UNCOVERED -- exists, and no send job backs it up:"
        for ds in "${uncovered[@]}"; do printf '  %s%s\n' "$ds" "$(reconcile_label "$ds")"; done
        echo
    fi
    if [ "${#received[@]}" -gt 0 ]; then
        echo "received backups -- a job in this config WRITES here, so these are copies,"
        echo "not unprotected workloads:"
        for ds in "${received[@]}"; do printf '  %s
' "$ds"; done
        echo
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "DECLARED BUT ABSENT -- the config names it, ZFS does not have it:"
        for ds in "${missing[@]}"; do printf '  %s\n' "$ds"; done
        echo "  (a job pointing at nothing fails nightly, or worse, quietly does nothing)"
        echo
    fi
    if [ "${#containers[@]}" -gt 0 ]; then
        echo "not counted -- structural containers: every child is covered and they hold no"
        echo "data of their own (snapsend's -S case). Listed so the omission is visible:"
        for ds in "${containers[@]}"; do printf '  %s
' "$ds"; done
        echo
    fi
    if [ "${#systems[@]}" -gt 0 ]; then
        echo "not counted -- Proxmox system datasets ($RECONCILE_SYSTEM_NAMES), listed so the"
        echo "omission is visible rather than assumed:"
        for ds in "${systems[@]}"; do printf '  %s\n' "$ds"; done
        echo
    fi

    if [ "${#uncovered[@]}" -eq 0 ] && [ "${#missing[@]}" -eq 0 ]; then
        echo "OK -- every dataset on this host is either covered or a named system dataset."
        return 0
    fi
    echo "NOT OK -- ${#uncovered[@]} uncovered, ${#missing[@]} declared but absent."
    return 1
}

if [ -z "$CONFIG" ]; then
    CONFIG="$SCRIPT_DIR/jobs.$(hostname -s 2>/dev/null || hostname).conf"
fi
[ -f "$CONFIG" ] || die "config file not found: $CONFIG (pass -c to specify one)"

if [ "$MIGRATE" -eq 1 ]; then
    migrate_recursion "$CONFIG"
    exit 0
fi

parse_ini "$CONFIG"
[ "${#SECTION_ORDER[@]}" -gt 0 ] || die "no sections found in $CONFIG"
validate_field_names
apply_path_settings

build_entities
group_send
group_inline_prune
group_bookmark_prune
group_monitor
validate_retain_patterns
validate_transfer_semantics

if [ "${RECONCILE:-0}" -eq 1 ]; then
    do_reconcile
    exit $?
fi

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
