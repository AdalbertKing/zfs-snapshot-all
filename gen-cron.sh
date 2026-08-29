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
#     Beyond those, [defaults] carries only the policy fields whose lookup
#     actually reaches it: send_schedule, prune_schedule, prefix, pattern, dst,
#     src, autotune, quiesce, monitor_schedule and gfs_pattern. Retention
#     (keep/retain), the staleness thresholds (monitor_warn/monitor_crit), the
#     notify wording fields and 'flags' are per-tier and stop at the template --
#     writing them here is refused rather than silently ignored (2026-08-20).
#
#   Every schedule field (send_schedule, prune_schedule, monitor_schedule and
#   [prune-bookmarks:]'s 'schedule') must be exactly 5 crontab fields, with each
#   field in range. Nothing checked this until 2026-08-20: "0 2 *" generated
#   cleanly and shifted the command into the time fields, and the only thing
#   that ever objected was crontab(1) at --install time -- which rejects the
#   whole crontab, so one bad line takes the good ones with it. The @daily-style
#   shorthands are not accepted: cron2conf.sh and job_identity both read the
#   generated line assuming a five-field prefix.
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
#                                          # Where the SAME tier also sends,
#                                          # monitor_warn must be LONGER than
#                                          # that tier's own longest gap
#                                          # between runs -- gen-cron walks a
#                                          # real calendar over send_schedule
#                                          # to find it, so weekly is 7 days,
#                                          # monthly is 31 and Mon-Fri is 72
#                                          # hours. A threshold at or below
#                                          # that alarms on a healthy job every
#                                          # cycle and never on a fault; it is
#                                          # refused. Not checked where the
#                                          # cadence is not in this file (a
#                                          # [prune:] scope, or a dataset tier
#                                          # that only receives).
#       monitor_schedule = <5-field cron>  # default: */15 * * * * if monitor_warn/crit are set
#
#   [dataset:<zfs/path>]                  # a dataset you own end-to-end
#       use_template = <tier>[,<tier>...]  # comma list -- one dataset can span several tiers
#       notify       = <short label>
#       flags        = <snapsend.sh flags, or snapget.sh flags when 'src' is set>
#       flags_<tier> = <per-tier flags override>
#       send_schedule_<tier>  = <per-tier send cadence override>
#       prune_schedule_<tier> = <per-tier prune cadence override>
#       bandwidth    = <mbuffer rate>      # LINK fields: what the transfer does
#       compression  = zstd|gzip|none|default  # to the WIRE, named instead of
#       cipher       = <ssh -c argument>   # hand-written into 'flags'. Section
#                                          # only -- no template/defaults layer,
#                                          # and profile-forbidden: a policy
#                                          # carrier is shared by datasets that
#                                          # do not share a destination.
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
#       quiesce      = no|agent|sync|auto[,strict|,degrade]  # default no; quiesce
#                                          # the Proxmox guest. A failed freeze
#                                          # degrades to a crash-consistent
#                                          # snapshot unless ',strict' is named.
#                    [,degrade]            # that owns this dataset before
#                                          # snapshotting it (snapsend.sh -q).
#                                          # ',degrade' says what to do when the
#                                          # freeze cannot happen: take the set
#                                          # anyway, crash-consistent, named
#                                          # <family>_crash_<timestamp>, and exit
#                                          # 8 so cron reports it. Without it a
#                                          # failed freeze means NO snapshot.
#                                          # A failed thaw stays fatal either way.
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
#          prune_schedule, keep, retain, notify_raw) EXCEPT the two the
#          synthesized text takes from the tier itself: notify_word and
#          notify_raw_prune are read from the [template:] only, so setting them
#          on a dataset is refused rather than quietly doing nothing.
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
#                                          # bucket them by elapsed time. That
#                                          # requirement is ENFORCED: every
#                                          # contributing tier's 'pattern' must
#                                          # start with gfs_pattern, or
#                                          # generation refuses. Omitting the
#                                          # field is the prefixless ladder ("",
#                                          # matches everything) and always
#                                          # satisfies it. See delsnaps.sh's own
#                                          # header ("GFS LADDER") for the full
#                                          # mechanism.
#                                          # Inheritable from [defaults], so a
#                                          # host running one ladder prefix
#                                          # across several [prune:] sections
#                                          # writes it once.
#       notify       = <short label>
#     For scopes you do NOT create locally: a backup store receiving pushes from
#     other hosts, foreign/received subtrees. Emits one delsnaps line per tier.
#     A [prune:] never sends, so the transfer-side fields are refused here
#     (2026-08-20): send_schedule, prefix, dst, src, autotune, quiesce, flags
#     and notify_raw belong to a [dataset:]/[template:], and 'ssh_flags' -- not
#     'flags' -- is how a remote scope's connection is configured.
#     The yes/no fields here and on [prune-bookmarks:] (recursive, clear_cut,
#     gfs, prune) accept ONLY 'yes' or 'no', any case. Until 2026-08-20 they
#     were compared against the literal "yes", so 'ture' -- or a blank value --
#     silently meant no: a declared subtree sweep became a single dataset, and a
#     declared cascading ladder became flat per-tier lines, both at rc=0.
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
  --uninstall Remove the managed block from this user's crontab and stop.
              Needs no -c: the usual reason to want this is that the config
              is gone or wrong. Removes the SCHEDULE only -- the config file
              and the datasets are named and left alone.
  -V          Print version and exit
  -h          Print this help

  --reconcile          READ-ONLY: compare what the config backs up against what
                       actually exists on this host, and exit non-zero if a
                       dataset has no SEND job. "Covered" means a send job
                       exists -- a dataset with only a prune rule is being
                       trimmed, not backed up. Answers a real failure: a guest
                       created after the config was written ran with zero
                       automated snapshots because nothing ever compared those
                       two facts. Needs zfs on this host. Edits nothing.
  --migrate-recursion  Rewrite a pre-v4.27 config that spelled recursion as
                       -r/-R inside a free-form `flags` into the section's own
                       `recursive =`, and show the before/after crontab so the
                       result can be diffed before it is installed. One-off
                       migration, not a routine mode.

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

# quiesce = agent|sync|auto|no, each optionally with ',degrade'. Unlike -A this
# is NOT inferred: whether a guest can
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
    local want="$1" ctx="$2" direction="$3" mode="$1" qual=""
    # `<mode>[,strict|,degrade]` (docs/design/quiesce-degrade.md). The qualifier
    # is split off HERE so every rule below keeps reading a bare mode -- in
    # particular the pull/sync rule, which must reject `sync,degrade` on a pull
    # for exactly the reason it rejects `sync`. The engines parse the same
    # grammar with quiesce_parse_mode (lib-zfs-snap.sh); this is the config-time
    # half, and the two must accept the same set or a config would generate
    # cleanly and fail at run time.
    #
    # Since the owner's 2026-08-27 direction the DEFAULT is to degrade -- a
    # failed freeze still produces a snapshot, named `_crash_` and exiting 8 --
    # so `,degrade` is accepted and redundant, and `,strict` is the field that
    # actually changes anything: it restores the old refusal.
    case "$want" in
        *,*)
            mode="${want%%,*}"
            qual="${want#*,}"
            case "$qual" in
                degrade|strict) ;;
                *) die "$ctx: quiesce='$want' -- ',$qual' is not a qualifier. There are two, and each may appear at most once: ',strict' takes NO snapshot when the freeze fails, and ',degrade' takes a crash-consistent one -- which is the default since 2026-08-27, so writing it changes nothing." ;;
            esac
            case "$mode" in
                no) die "$ctx: quiesce='no,$qual' -- ',$qual' says what to do when a freeze FAILS, and 'no' never freezes, so the pair asks for nothing. Either name the mode you want quiesced, or drop the field." ;;
            esac ;;
    esac
    # `want` stays the RAW field from here on, so every message below quotes what
    # the operator actually wrote; the rules read `mode`, which is the same thing
    # with any qualifier removed.
    case "$mode" in
        ""|no) return 0 ;;
        agent|auto)
            return 0
            ;;
        sync)
            [ "$direction" = "pull" ] && die "$ctx: quiesce='$want' on a pull dataset -- sync is the CONTAINER fallback (a 'pct exec <id> -- sync' flush, not a freeze), and running it across an ssh hop buys nothing a push job on that host would not do better. Use quiesce=agent/auto for VMs, or run this dataset as a push job."
            return 0
            ;;
        fs) die "$ctx: quiesce=fs is gone -- ZFS does not implement FIFREEZE, so no ZFS mountpoint can be frozen from the host. Use quiesce=sync for containers (a flush, not a freeze)" ;;
        *) die "$ctx: quiesce='$want' -- expected no, agent, sync or auto, each optionally with ',strict' or ',degrade'" ;;
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

# ------------------------------------------------------------------------------
# LINK FIELDS -- bandwidth, compression, cipher.
# ------------------------------------------------------------------------------
# These three describe the LINK a dataset flies over. They are not the policy it
# obeys (retention, schedules, prefixes) and not the identity it connects with
# (keys, pinned host key, port), and until now they had no field of their own:
# the only way to express any of them was to hand-write the engine letter inside
# the free-form 'flags' string -- the same string that carries the pairing key
# and the host-key alias. That single sack is why 'flags' is relationship-owned
# and profile-forbidden, and therefore why no layer above a hand edit could say
# "cap this peer at 2 MB/s" at all.
#
# Naming them does not move the decision, it just gives it a home: each field
# renders exactly the token an operator would have typed, so a section carrying
# `bandwidth = 2500k` produces the same engine invocation as one carrying
# flags="... -b 2500k".
#
# [dataset:] ONLY, deliberately. A [template:]/[defaults] is a policy carrier
# shared by every dataset that names it, and those datasets do not share a
# destination -- the same retention serves a gigabit LAN and a 20 Mbit VPN. A
# link value inherited from a policy layer would be applied to links nobody
# looked at, which is the opposite of what naming the field is for.
#
# ONE OPTION, ONE HOME. If 'flags' already carries the letter one of these
# fields renders, that is REFUSED rather than merged, deduplicated or silently
# preferred. Two sources of truth for one engine option is precisely the
# condition this split exists to end, and picking a winner would hide it.
#
# Sets LINK_CONFLICT to the offending letter when it returns 0.
link_flag_letter_present() {   # <flags> <letters, as one string> -> 0 when present
    LINK_CONFLICT=""
    local have
    for have in $(flags_opt_letters "$1"); do
        case "$2" in *"$have"*) LINK_CONFLICT="$have"; return 0 ;; esac
    done
    return 1
}

# Validated OUTSIDE the command substitution that renders -- see lint_autotune
# for why that separation is not optional (a die() inside $( ) exits the
# subshell and leaves the run going with the flag quietly dropped).
#
# The accepted rate spec is snapsend.sh's own (its -b validation, "expected an
# mbuffer rate"): digits with an optional b/k/M/G suffix, BYTES per second.
# Refusing the same strings here means a typo is caught while generating rather
# than mid-transfer on the first run, after the snapshot has been taken.
lint_link_bandwidth() {   # <value> <flags> <ctx>
    local val="$1" flags="$2" ctx="$3"
    [ -z "$val" ] && die "$ctx: 'bandwidth' is present but blank -- give it an mbuffer rate (e.g. 2500k), or remove the line to keep the link uncapped"
    case "$val" in
        -*) die "$ctx: bandwidth='$val' -- give the RATE only; the '-b' is what this field renders for you" ;;
    esac
    [[ "$val" =~ ^[0-9]+[bkKmMgG]?$ ]] \
        || die "$ctx: bandwidth='$val' -- expected an mbuffer rate: a plain number of BYTES per second, or one with a b/k/M/G suffix (e.g. 2M, 500k). Note BYTES, not bits: a 20 Mbps link is 2M."
    link_flag_letter_present "$flags" b \
        && die "$ctx: 'bandwidth' is set and 'flags' already carries -b -- one option, one home. Drop the -b from 'flags' and keep the field."
    return 0
}

# zstd/gzip/none, spelled as compressors rather than as letters. 'default' and
# an omitted field are the same thing: whatever the engine decides for this
# destination (compression is on by default over a remote link, off locally).
#
# A local destination is NOT warned about here, deliberately: this field renders
# -Z/-g into the flags string, and lint_flags -- which runs after the render --
# already says exactly that about a compressor on a local dst. Saying it twice
# for one condition trains an operator to skim warnings, and the field's job is
# to be indistinguishable from the hand-written letter it replaces.
lint_link_compression() {   # <value> <flags> <ctx>
    local val="$1" flags="$2" ctx="$3"
    case "$val" in
        zstd|gzip|none|default) ;;
        "") die "$ctx: 'compression' is present but blank -- expected zstd, gzip, none or default, or remove the line" ;;
        *) die "$ctx: compression='$val' -- expected zstd, gzip, none or default" ;;
    esac
    link_flag_letter_present "$flags" zZgN \
        && die "$ctx: 'compression' is set and 'flags' already carries -$LINK_CONFLICT -- one option, one home. Drop the compressor letter from 'flags' and keep the field."
    return 0
}

# The ssh cipher list, passed straight through to ssh -c. Not enumerated here:
# which ciphers exist is the local OpenSSH build's answer, not this generator's,
# and an allow-list would go stale against a host we cannot see. Only the shape
# is checked -- one token, no spaces, no leading dash -- so a mistyped field
# cannot smuggle a second ssh option in behind the -c.
lint_link_cipher() {   # <value> <flags> <ctx> <dst-or-src spec>
    local val="$1" flags="$2" ctx="$3" spec="$4"
    [ -z "$val" ] && die "$ctx: 'cipher' is present but blank -- name a cipher (e.g. aes128-gcm@openssh.com), or remove the line"
    case "$val" in
        -*) die "$ctx: cipher='$val' -- give the cipher only; the '-c' is what this field renders for you" ;;
        *[[:space:]]*) die "$ctx: cipher='$val' -- one ssh -c argument, no spaces (a comma-separated list is one argument: 'a,b')" ;;
        *[!A-Za-z0-9,@.=_-]*) die "$ctx: cipher='$val' -- expected an ssh cipher name or comma-separated list" ;;
    esac
    link_flag_letter_present "$flags" c \
        && die "$ctx: 'cipher' is set and 'flags' already carries -c -- one option, one home. Drop the -c from 'flags' and keep the field."
    case "$spec" in
        *:*|*@*) ;;
        *) warn "$ctx: cipher=$val on a LOCAL destination -- no ssh connection is opened for a local send, so this has no effect" ;;
    esac
    return 0
}

# The renderers. Deliberately dumb: every decision was made in the lint above,
# so these cannot fail and are safe inside a command substitution.
add_link_flags() {   # <flags> <bandwidth> <compression> <cipher> -> flags
    local flags="$1" bw="$2" comp="$3" ciph="$4"
    case "$comp" in
        zstd) flags="${flags:+$flags }-Z" ;;
        gzip) flags="${flags:+$flags }-g" ;;
        none) flags="${flags:+$flags }-N" ;;
    esac
    [ -n "$ciph" ] && flags="${flags:+$flags }-c $ciph"
    [ -n "$bw" ] && flags="${flags:+$flags }-b $bw"
    printf '%s' "$flags"
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

# cron2conf.sh carries a byte-identical copy of this, deliberately -- it is
# deployed standalone and sources nothing. It reads back what this script
# emits, so the two must agree on what "trimmed" means or the round-trip stops
# round-tripping. Its copy carries the full reasoning; this note exists so the
# pair is visible from BOTH ends rather than only one.
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
                    template|dataset|prune|prune-bookmarks|replica|excluded) : ;;
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
#
# That mirroring was stated here from the start but was not actually true, in
# BOTH directions, until 2026-08-20:
#
#   granted but never read -- the whole of POLICY_FIELDS was handed to every
#   kind wholesale, while the real lookups are narrower. `monitor_warn` and
#   `monitor_crit` in [defaults] generated rc=0 and produced ZERO monitor
#   lines: resolve_monitor reads ds->tmpl and stops. `flags` in [defaults] was
#   dropped the same way, so `flags = -w` at the top of a file silently changed
#   nothing about what went over the wire. This is the exact failure the
#   paragraph above describes -- config that generates cleanly and does not do
#   what it says -- except reached with a KNOWN field in a position nobody
#   reads, which the unknown-field guard by definition cannot catch.
#
#   read but never granted -- build_prune_section resolves `gfs_pattern` with
#   `defaults` as its last layer, but the allow-list refused the field there,
#   so that layer was unreachable code.
#
# The lists below are therefore split per kind rather than sharing one blanket
# set. They remain HAND-maintained: scraping the layer dimension out of the
# call sites means knowing which builder function each call sits in, and a
# scraper that guessed wrong would produce a FALSE rejection of a working
# config -- the one failure mode this file cannot trade for tidiness. Adding a
# lookup at a new layer means adding the field to that kind's list here.
declare -A FIELD_OK=()
_allow_fields() {
    local kind="$1"; shift
    local f; for f in "$@"; do FIELD_OK["${kind}${SEP}${f}"]=1; done
}
# Everything a [template:] can carry. A template is a pure policy carrier and
# every one of these is read from the template layer, so this list and the
# template allow-list are the same set by construction.
POLICY_FIELDS="send_schedule prune_schedule prefix pattern keep retain
               tier_label notify notify_raw notify_raw_prune notify_word
               monitor_warn monitor_crit monitor_schedule monitor_exclude
               dst src autotune quiesce flags"
# The subset whose lookup actually reaches [defaults] as its last layer.
# Deliberately absent: keep/retain and monitor_warn/monitor_crit (per-tier by
# nature -- resolve_keep_retain and resolve_monitor stop at the template), the
# notify_* wording fields and tier_label (per-tier display text), and flags
# (its tiered lookup stops at the template too -- naming that helper in prose
# here would be read as a field by the allow-list test in test/run.sh, which
# scrapes "<helper> <word>" out of this file and does not know comments from
# code). gfs_pattern is here and NOT in POLICY_FIELDS: only [prune:] reads it,
# but it does read it from defaults.
DEFAULTS_POLICY_FIELDS="send_schedule prune_schedule prefix pattern
                        dst src autotune quiesce monitor_schedule gfs_pattern"
# shellcheck disable=SC2086
_allow_fields defaults  host_label repo_dir notify_script warn_script \
                        digest_script cron_log $DEFAULTS_POLICY_FIELDS
# shellcheck disable=SC2086
_allow_fields template  $POLICY_FIELDS
# media = removable  -- THIS TARGET IS A DISK THAT GETS UNPLUGGED.
#
# Owner's shape, 2026-08-28, modelled on FerroBackup's replica: a source may
# have several replica targets and some of them are pools on disks carried away
# to a safe. For those, the transfer is bracketed --
#
#     zfs-media-gate.sh attach  ->  the engine  ->  zfs-media-gate.sh detach
#
# -- so the pool is imported before the write and exported after it, and the
# disk can be pulled the moment the run ends.
#
# THE POINT OF THE FIELD IS THE ABSENT CASE. Without it, a target that is not
# there is a failed job and an alert; with it, it is a disk in a safe. The gate
# exits 1, the generated line reads that and skips, and nothing alarms. One
# replica being away must not affect the other two.
#
# Anything other than `removable` is refused rather than ignored: a typo here
# would silently produce an ordinary job that alerts every night the disk is
# out.
#
# pair_label names the RELATIONSHIP (zfs-backup.sh client) a section belongs
# to (REV-20260804-045). It reaches the transfer command, the staleness
# monitor, AND the delsnaps line -- every job this package puts in a crontab
# for that relationship.
#
# THE PRUNE LINE USED TO BE UNGATED, AND THAT REASONING IS WORTH KEEPING,
# because it was right about the case it considered and wrong about the one
# it did not. It said: "retention of what already landed stays correct while
# a relationship is paused; only new transfers and the alarms about their
# absence stop." True for an ordinary pause. False for the reason a pause is
# most needed.
#
# Measured on the lab, 2026-08-27: during a restore campaign the source-side
# prune fired at :21, applied its GFS ladder to a source the restore had just
# rolled back, and destroyed the recovery point itself. The relationship was
# left with no common snapshot at all. "Retention stays correct" assumed the
# data underneath it was not moving; a restore is exactly when it is.
#
# Owner direction, 2026-08-27: "pausa ma wstrzymac wszelkie operacje cronowe
# naszego pakietu z prunem wlacznie." delsnaps.sh gained -L for it and the
# freeze was lifted for that change.
#
# NOT by disabling cron: the host's crontab carries jobs that are not ours,
# and stopping the daemon to pause one relationship stops those too. The
# switch stays per relationship, inside our own jobs.
#
# Deliberately NOT in POLICY_FIELDS: no template/defaults inheritance -- a
# label that silently spread to unrelated sections would make one pause skip
# a stranger's backup.
# A [dataset:] reads all of POLICY_FIELDS off itself except the two wording
# fields build_dataset deliberately takes from the TEMPLATE only: notify_word
# (the noun in the synthesized text, a property of the tier) and
# notify_raw_prune (the prune line's literal text, likewise).
DATASET_POLICY_FIELDS="send_schedule prune_schedule prefix pattern keep retain
                       tier_label notify notify_raw
                       monitor_warn monitor_crit monitor_schedule monitor_exclude
                       dst src autotune quiesce flags"
# A [prune:] section does not send. send_schedule, prefix, dst, src, autotune,
# quiesce and flags are transfer-side fields build_prune_section never looks at,
# so accepting them here only ever meant a line that does nothing. notify_raw is
# the SEND line's literal text; the prune line's is notify_raw_prune, which is
# read. notify_word is template-only here as well.
PRUNE_POLICY_FIELDS="prune_schedule pattern keep retain
                     tier_label notify notify_raw_prune
                     monitor_warn monitor_crit monitor_schedule monitor_exclude"
# bandwidth/compression/cipher are the LINK fields (see link_flag_letter_present):
# [dataset:] only, never POLICY_FIELDS -- a policy carrier is shared by datasets
# that do not share a destination, so there is no layer above the section where
# a link value would be true for everything that inherited it.
# shellcheck disable=SC2086
_allow_fields dataset   use_template pair_label recursive media \
                        bandwidth compression cipher $DATASET_POLICY_FIELDS
# shellcheck disable=SC2086
_allow_fields prune     use_template recursive clear_cut prune ssh_flags \
                        gfs gfs_pattern pair_label $PRUNE_POLICY_FIELDS
_allow_fields prune-bookmarks schedule age pattern recursive ssh_flags notify pair_label

# [replica:<name>] -- ANOTHER COPY OF WHAT THIS HOST ALREADY HOLDS.
#
# Owner's shape, 2026-08-28/29, modelled on FerroBackup: a source may have
# SEVERAL replica targets -- three in the case that prompted this, two of them
# weekly rotating disks and one a quarterly disk in a safe.
#
# WHY A SECTION TYPE AND NOT ANOTHER dst ON [dataset:]. A [dataset:] section is
# keyed by its path and there can only be one per path, so three replicas of one
# source cannot be spelled there at all -- `duplicate section` (measured while
# building the pve9 lab, 2026-08-29). Loosening that key was the alternative and
# it is the worse one: managed-by ownership, the staleness monitor, prune
# co-location, reconcile and cron2conf all assume one section per dataset, and
# every one of them would have to learn a second answer.
#
# A replica is also a different KIND of job, which is what makes the separate
# type honest rather than a workaround:
#   * it has no staleness monitor -- freshness is a property of the primary
#     copy, and alerting twice on one late backup is how alerts get ignored;
#   * it does not prune its source; the source is our own copy, pruned by
#     whatever already owns it;
#   * it belongs to no client relationship, so it carries no pair_label and no
#     managed-by marker;
#   * and there are N of them, which is the whole point.
#
# The name in the header is just a label -- it names the medium, not a dataset.
_allow_fields replica  source dst schedule prefix notify media recursive flags history
_allow_fields excluded  keep

# The single most useful thing to say about a rejected field is "you put it in
# the wrong kind of section", which is a different mistake from "you misspelled
# it" and needs a different fix.
field_valid_elsewhere() {
    local field="$1" k out=""
    for k in defaults template dataset prune prune-bookmarks replica excluded; do
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
        # flags_<tier>, send_schedule_<tier>, prune_schedule_<tier>: per-tier
        # overrides whose tier part cannot be enumerated ahead of time. The two
        # schedules joined flags on 2026-08-26 so that a multi-cadence profile
        # can be spread across the clock without one section-level value
        # flattening every tier it names.
        case "$field" in
            flags_*|send_schedule_*|prune_schedule_*)
                [ "$kind" = "dataset" ] && continue ;;
        esac
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
        # keep is a COUNT and nothing else. Unvalidated it rode straight into
        # the flag ("-M${keep}"), so keep=abc produced -Mabc and surfaced as a
        # delsnaps parse error at 3 a.m. instead of here. Same class as the
        # retain lint below: this field builds arguments for the one tool whose
        # empty default is destructive, so its inputs get checked at the desk.
        case "$keep" in
            *[!0-9]*) KEEP_RETAIN_ERROR="'keep = $keep' is not a number -- keep takes a plain count (how many of this tier to retain)"; return 1 ;;
            0) KEEP_RETAIN_ERROR="'keep = 0' would keep nothing of this tier -- if that is really meant, say it with an explicit retain= flag, not a count of zero"; return 1 ;;
        esac
        RESOLVED_RETAIN="-${TIER_LETTER[$tier]}${keep}"
        return 0
    fi
    # Basket A3. retain reaches delsnaps.sh VERBATIM after the positionals, and
    # this was the one raw-flag field with no lint at all: ssh_flags refuses
    # everything outside its whitelist (and refuses -F by name), the bookmark
    # age field refuses -n, retain refused NOTHING. delsnaps' option surface
    # includes -F (clear-cut: zfs destroy -R, takes linked clones with it) and
    # a bare default that deletes everything -- so a typo here is not a syntax
    # error, it is a different operation.
    #
    # The whitelist is the retention flags and only those: lowercase = AGE
    # (delete older than N units), uppercase = COUNT (keep newest N), number
    # attached. One shape, no exceptions -- gfs=yes narrows it further to a
    # single uppercase flag, and that stricter check stays where it is.
    # Both spellings delsnaps' own parser accepts are legal here: '-h12' and
    # '-h 12'. The second is not hypothetical -- jobs.11.11.v4.conf carries
    # 'retain = -h 12' live, and the first version of this lint refused it.
    # Caught by rendering every fleet config as the regression control BEFORE
    # the change shipped, which is the whole argument for that control.
    local _tok _pending=""
    for _tok in $retain; do
        if [ -n "$_pending" ]; then
            case "$_tok" in
                ''|*[!0-9]*)
                    KEEP_RETAIN_ERROR="'retain = $retain': '$_pending' needs a number and '$_tok' is not one"; return 1 ;;
            esac
            _pending=""
            continue
        fi
        case "$_tok" in
            -[yYmMwWdDhH])
                _pending="$_tok" ;;
            -[yYmMwWdDhH][0-9]*)
                case "${_tok:2}" in *[!0-9]*)
                    KEEP_RETAIN_ERROR="'retain = $retain': '$_tok' has a malformed count"; return 1 ;;
                esac ;;
            *)
                KEEP_RETAIN_ERROR="'retain = $retain': '$_tok' is not a retention flag. This field takes only -y/-m/-w/-d/-h (AGE: delete snapshots older than N) or -Y/-M/-W/-D/-H (COUNT: keep the newest N), e.g. -D7, '-h 12', or '-H24 -D7'. Anything else is an OPERATION flag to delsnaps.sh (-F there means zfs destroy -R) and does not belong in a retention field"
                return 1 ;;
        esac
    done
    if [ -n "$_pending" ]; then
        KEEP_RETAIN_ERROR="'retain = $retain': '$_pending' at the end has no number"; return 1
    fi
    # The unit trap next door (basket A7): monitor_warn=90m two lines above a
    # retain=-m3 -- the first m is MINUTES, the second MONTHS. And on the tier
    # whose own letter this is, the case of one character flips the meaning:
    # keep=3 / retain=-M3 keeps three, retain=-m3 deletes everything older
    # than three months. A warning rather than a refusal, because age mode on
    # a monthly tier is a legitimate thing to want -- what is not legitimate
    # is meaning one and silently getting the other.
    if [ -n "${TIER_LETTER[$tier]+x}" ]; then
        local _lo; _lo=$(printf '%s' "${TIER_LETTER[$tier]}" | tr '[:upper:]' '[:lower:]')
        case " $retain " in
            *" -${_lo}"[0-9]*)
                warn "tier=$tier: 'retain = $retain' uses lowercase -${_lo}, which is AGE mode -- delete snapshots OLDER than that many. Keeping that many is keep= or uppercase -${TIER_LETTER[$tier]}. Proceeding as written." ;;
        esac
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

# lint_cron_schedule SPEC CTX FIELD -- a crontab time specification, checked at
# generate time.
#
# Nothing checked these until 2026-08-20. send_schedule = "0 2 *" generated with
# rc=0 and emitted
#
#   0 2 * echo "$(date -Is) ZFS-JOB BEGIN ..." >>/root/scripts/cron.log; ...
#
# where cron reads the command's own first tokens as the month and day-of-week
# fields. SIX fields is worse than three: the command then starts with a bare
# '*', which the shell glob-expands against the job's working directory before
# running whatever comes back. The only gate was crontab(1) itself at --install
# time -- the latest possible moment, on the far side of the host boundary, and
# it rejects the WHOLE crontab rather than the line at fault.
#
# Exactly five fields. The @daily/@reboot shorthands are deliberately NOT
# accepted even though cron takes them: cron2conf.sh parses the generated line's
# shape back into config and job_identity keys off it, and both assume a
# five-field prefix. "0 0 * * *" costs nothing and keeps one grammar.
#
# The per-field check is permissive about STRUCTURE -- lists, ranges, steps and
# the three-letter month/day names all pass -- and strict only about the
# alphabet and the numeric ranges. A validator that invented a restriction cron
# does not have would reject a working config, which is a worse failure than the
# hole it closes.
_cron_num_ok() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}
# _cron_field_ok FIELD LO HI NAMES_ALTERNATION
_cron_field_ok() {
    local f="$1" lo="$2" hi="$3" names="$4" item base step a b x
    [ -n "$f" ] || return 1
    local -a items=()
    # read -ra rather than word-splitting an unquoted expansion: a bare '*' is a
    # legal cron field and would be pathname-expanded against the working
    # directory, which is how a validator ends up passing or failing on what
    # happens to be sitting next to the script.
    IFS=',' read -ra items <<< "$f"
    for item in ${items[@]+"${items[@]}"}; do
        [ -n "$item" ] || return 1
        base="${item%%/*}"
        if [ "$base" != "$item" ]; then
            step="${item#*/}"
            _cron_num_ok "$step" 1 "$hi" || return 1
        fi
        [ "$base" = '*' ] && continue
        if [ "${base#*-}" != "$base" ]; then
            a="${base%%-*}"; b="${base#*-}"
        else
            a="$base"; b="$base"
        fi
        for x in "$a" "$b"; do
            if [ -n "$names" ] && printf '%s' "$x" | grep -qiE "^($names)$"; then continue; fi
            _cron_num_ok "$x" "$lo" "$hi" || return 1
        done
    done
    return 0
}
lint_cron_schedule() {
    local spec="$1" ctx="$2" field="$3"
    local -a f=()
    read -ra f <<< "$spec"
    [ "${#f[@]}" -eq 5 ] || die "$ctx: $field = '$spec' -- a crontab time specification is exactly 5 fields (minute hour day-of-month month day-of-week), this has ${#f[@]}. Too few shifts the command into the time fields; too many leaves the command starting with a leftover field. cron would only reject it at install time, and then it rejects the whole crontab."
    _cron_field_ok "${f[0]}" 0 59 ""                                    || die "$ctx: $field = '$spec' -- minute field '${f[0]}' is not valid (0-59, with * , - and / )"
    _cron_field_ok "${f[1]}" 0 23 ""                                    || die "$ctx: $field = '$spec' -- hour field '${f[1]}' is not valid (0-23, with * , - and / )"
    _cron_field_ok "${f[2]}" 1 31 ""                                    || die "$ctx: $field = '$spec' -- day-of-month field '${f[2]}' is not valid (1-31, with * , - and / )"
    _cron_field_ok "${f[3]}" 1 12 "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec" \
                                                                        || die "$ctx: $field = '$spec' -- month field '${f[3]}' is not valid (1-12 or jan..dec, with * , - and / )"
    _cron_field_ok "${f[4]}" 0 7  "sun|mon|tue|wed|thu|fri|sat" \
                                                                        || die "$ctx: $field = '$spec' -- day-of-week field '${f[4]}' is not valid (0-7 where both 0 and 7 are Sunday, or sun..sat, with * , - and / )"
}

# ---------------------------------------------------------------------------
# How long a schedule can legitimately stay silent.
#
# A staleness monitor measures the age of the newest matching snapshot. Right
# after a run that age is zero; just before the next run it equals the gap
# between two consecutive fires. So a monitor_warn no larger than the LONGEST
# such gap alarms on a perfectly healthy job, every cycle, forever. That is not
# hypothetical: a */15 monitor against thresholds sized for the wrong cadence
# produced 384 mails in one night on this estate, and the same shape has now
# been hit three separate times. Both numbers are in gen-cron's hand at
# generate time, so it is the right place to refuse.
#
# _cron_name2num NAME NAMES_ALTERNATION -- three-letter month/day names to their
# numbers, passthrough for anything already numeric.
_cron_name2num() {
    local v="$1" names="$2" i=1 n
    [ -n "$names" ] || { printf '%s' "$v"; return 0; }
    case "$v" in ''|*[!0-9]*) ;; *) printf '%s' "$v"; return 0 ;; esac
    local -a list=()
    IFS='|' read -ra list <<< "$names"
    # months are 1-based, weekdays 0-based; the alternation's own order decides,
    # which is why the caller passes the list in calendar order.
    [ "${list[0]}" = "sun" ] && i=0
    for n in ${list[@]+"${list[@]}"}; do
        [ "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" = "$n" ] && { printf '%s' "$i"; return 0; }
        i=$((i + 1))
    done
    printf '%s' "$v"
}
# _cron_expand FIELD LO HI NAMES -- every value the field matches, one per line.
# Assumes lint_cron_schedule already accepted the field.
_cron_expand() {
    local f="$1" lo="$2" hi="$3" names="$4" item base step a b i
    local -a items=()
    IFS=',' read -ra items <<< "$f"
    for item in ${items[@]+"${items[@]}"}; do
        base="${item%%/*}"; step=1
        [ "$base" != "$item" ] && step="${item#*/}"
        if [ "$base" = '*' ]; then
            a="$lo"; b="$hi"
        elif [ "${base#*-}" != "$base" ]; then
            a="$(_cron_name2num "${base%%-*}" "$names")"
            b="$(_cron_name2num "${base#*-}" "$names")"
        else
            a="$(_cron_name2num "$base" "$names")"
            # vixie reads "N/step" as "N-max/step", not as the single value N.
            if [ "$step" -gt 1 ]; then b="$hi"; else b="$a"; fi
        fi
        [ "$a" -le "$b" ] || continue
        for ((i = a; i <= b; i += step)); do printf '%s\n' "$i"; done
    done
}
# cron_max_gap_minutes SPEC -- the longest gap between two consecutive fires,
# observed over a fixed two-year window (2028-2029, so both a leap February and
# an ordinary one are in it). Echoes nothing when the window holds fewer than
# two fires.
#
# An OBSERVED gap is a real gap, so this is a lower bound on the true worst
# case even where the window cannot see the whole cycle (a Feb-29-only schedule
# fires once here and is therefore skipped rather than guessed at). Refusing
# only on a lower bound is what keeps the check free of false rejections.
#
# The calendar is walked arithmetically rather than by calling date(1) 731
# times: on the hosts that would be 731 processes per monitored tier, and this
# runs inside a generator that is expected to be instant.
declare -A CRON_GAP_CACHE=()
cron_max_gap_minutes() {
    local spec="$1"
    if [ -n "${CRON_GAP_CACHE[$spec]+x}" ]; then printf '%s' "${CRON_GAP_CACHE[$spec]}"; return 0; fi
    local -a f=(); read -ra f <<< "$spec"

    local -A mset=() hset=() domset=() monset=() dowset=()
    local v
    while read -r v; do [ -n "$v" ] && mset[$v]=1; done < <(_cron_expand "${f[0]}" 0 59 "")
    while read -r v; do [ -n "$v" ] && hset[$v]=1; done < <(_cron_expand "${f[1]}" 0 23 "")
    while read -r v; do [ -n "$v" ] && domset[$v]=1; done < <(_cron_expand "${f[2]}" 1 31 "")
    while read -r v; do [ -n "$v" ] && monset[$v]=1; done < <(_cron_expand "${f[3]}" 1 12 "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec")
    while read -r v; do [ -n "$v" ] && dowset[$((v % 7))]=1; done < <(_cron_expand "${f[4]}" 0 7 "sun|mon|tue|wed|thu|fri|sat")

    # Fire times inside a matching day, ascending by construction.
    local -a fires=(); local h m
    for ((h = 0; h < 24; h++)); do
        [ -n "${hset[$h]+x}" ] || continue
        for ((m = 0; m < 60; m++)); do
            [ -n "${mset[$m]+x}" ] || continue
            fires+=($((h * 60 + m)))
        done
    done
    [ "${#fires[@]}" -gt 0 ] || { CRON_GAP_CACHE[$spec]=""; return 0; }

    # vixie's day rule: when BOTH day-of-month and day-of-week are restricted,
    # a day matches if EITHER does. Otherwise both must.
    local dom_r=1 dow_r=1
    [ "${f[2]}" = '*' ] && dom_r=0
    [ "${f[4]}" = '*' ] && dow_r=0

    local -a mlen=(0 31 29 31 30 31 30 31 31 30 31 30 31)   # 2028 is a leap year
    local y mo d dow=6 dayidx=0 prev_day=-1 total=0 gap max=0
    for y in 2028 2029; do
        [ "$y" = 2029 ] && mlen[2]=28
        for ((mo = 1; mo <= 12; mo++)); do
            for ((d = 1; d <= mlen[mo]; d++)); do
                local hit=0
                if [ -n "${monset[$mo]+x}" ]; then
                    if [ "$dom_r" -eq 1 ] && [ "$dow_r" -eq 1 ]; then
                        { [ -n "${domset[$d]+x}" ] || [ -n "${dowset[$dow]+x}" ]; } && hit=1
                    else
                        { [ -z "${domset[$d]+x}" ] || [ -z "${dowset[$dow]+x}" ]; } || hit=1
                    fi
                fi
                if [ "$hit" -eq 1 ]; then
                    if [ "$prev_day" -ge 0 ]; then
                        gap=$(( (dayidx - prev_day) * 1440 - fires[${#fires[@]}-1] + fires[0] ))
                        [ "$gap" -gt "$max" ] && max="$gap"
                    fi
                    prev_day="$dayidx"
                    total=$((total + ${#fires[@]}))
                fi
                dow=$(( (dow + 1) % 7 )); dayidx=$((dayidx + 1))
            done
        done
    done
    if [ "$total" -lt 2 ]; then CRON_GAP_CACHE[$spec]=""; printf ''; return 0; fi
    # Gaps inside one day, on any matching day they are the same.
    local i
    for ((i = 1; i < ${#fires[@]}; i++)); do
        gap=$(( fires[i] - fires[i-1] ))
        [ "$gap" -gt "$max" ] && max="$gap"
    done
    CRON_GAP_CACHE[$spec]="$max"
    printf '%s' "$max"
}

# duration_seconds STR CTX -- converts "<N>m/h/d" (same shorthand check-snap-age.sh
# itself parses) to seconds, or dies with CTX prefixed. Validated here too so a
# malformed threshold fails at generate time, not silently at 3am in cron.log.
#
# The double VALIDATION is the point above; the duplicated 60/3600/86400 TABLE
# is the price. check-snap-age.sh holds two more copies of it (parse_duration
# and, inverted, fmt_duration) and cannot source anything -- it is the monitor,
# deployed and run standalone, and it is a frozen engine besides. So three
# copies stay, and the rule is that the GRAMMAR is one thing: if <N>m/h/d ever
# grows a unit, it grows in all three or a threshold this generator accepts
# becomes one the monitor rejects at 3am. Noted 2026-08-20, after a duplication
# sweep read the untold half as an oversight.
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
# resolve_bool_field FIELD SECTION TEMPLATE CONTEXT DEFAULT(0|1)
# A yes/no field, read strictly, answered in $BOOL_FIELD.
#
# These were all `= "yes"` after a trim+lowercase, which means every OTHER
# spelling -- a typo included -- meant "no", silently, with rc=0. On these
# sections that is not a harmless default:
#
#   recursive = ture   on a [prune:] turns a declared subtree sweep into a
#                      single dataset. Every child stops being pruned, and the
#                      only visible difference is a delsnaps line without -R.
#   gfs       = ture   turns one cascading ladder into N flat per-tier lines,
#                      which is a different retention shape, not a smaller one.
#
# [dataset:]'s own 'recursive' has been fatal-on-unknown since REV-20260807-054
# -- "an unrecognised value is fatal rather than falsy... precisely the
# fail-open this whole review exists to remove" -- and these are the sections
# that reform did not reach.
#
# Communicates via a global and must be called WITHOUT $(...), for the reason
# spelled out at lint_autotune: die() inside a command substitution kills only
# the subshell, leaving the script running at rc=0 with the value quietly
# dropped. A validator that can be silently skipped is worse than none.
BOOL_FIELD=0
resolve_bool_field() {
    local field="$1" sec="$2" tmpl="$3" ctx="$4" raw
    BOOL_FIELD="$5"
    raw="$(resolve_field "$field" "$sec" "$tmpl" "")" || return 0
    case "$(trim "$raw" | tr '[:upper:]' '[:lower:]')" in
        yes) BOOL_FIELD=1 ;;
        no)  BOOL_FIELD=0 ;;
        '')  die "$ctx: '$field' is blank -- a blank field is not a default, it is a question nobody answered (say yes or no)" ;;
        flat|atomic)
             # Basket B3, and only for the recursion field -- this function is
             # generic and 'gfs = flat' deserves the generic refusal, not a
             # lecture about send modes. Recursion is no|flat|atomic on a
             # [dataset:] (the engines have two recursion modes) but yes|no on
             # a [prune:]/[prune-bookmarks:], because delsnaps has exactly one
             # recursion (-R, a subtree walk). The word arriving here is almost
             # always a [dataset:] habit; name the mapping, not just 'expected
             # yes'.
             if [ "$field" = recursive ]; then
                 die "$ctx: $field = '$raw' -- this section's recursion is yes|no, not no|flat|atomic. delsnaps.sh has exactly ONE recursion mode (a subtree walk, its -R); 'flat' and 'atomic' are SEND modes and only a [dataset:] section chooses between them. If you meant 'recurse over the subtree', say ${field} = yes."
             fi
             die "$ctx: $field = '$raw' -- expected 'yes' or 'no'." ;;
        *)   die "$ctx: $field = '$raw' -- expected 'yes' or 'no'. Until 2026-08-20 every other spelling silently meant 'no', which is how a one-letter typo turned a declared policy into its opposite while generation still reported success." ;;
    esac
}

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
    lint_cron_schedule "$MONITOR_SCHEDULE" "$ctx" monitor_schedule
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
    declare -ga REPLICA_ENTITIES=()
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
            replica)          build_replica_section "$section" "$name" "$host_label" ;;
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

    # media = removable: this target is a disk that gets unplugged. Anything
    # else is refused rather than ignored -- a typo here would silently produce
    # an ordinary job that alerts every night the disk is out, which is the
    # exact noise this field exists to remove.
    local media
    media="$(resolve_field media "$ds" "" "")" || media=""
    case "$media" in
        ''|removable) ;;
        *) die "[dataset:$ds_path]: media='$media' -- the only value is 'removable' (the target is a disk that gets unplugged, so the run is bracketed by zpool import/export and an absent disk is a skip rather than a failure). Leave the field out for an ordinary target." ;;
    esac

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
        # Captured for the create/prune agreement check and the monitor-vs-
        # cadence check below. Reset PER TIER: 'prefix' and 'send_schedule' are
        # both declared inside the send branch, so a tier that does not send
        # would otherwise still see the previous tier's values and be checked
        # against a family it never creates, at a cadence it never runs.
        local tier_created_prefix="" tier_creates=0 tier_send_schedule=""
        local send_schedule
        # PER TIER, like flags. A [dataset:] carrying several tiers with several
        # cadences could not be staggered before: a single section-level
        # send_schedule overrides EVERY tier it references, so writing one minute
        # would have collapsed daily/weekly/monthly onto the hourly cadence. The
        # spreader therefore wrote nothing at all, and every `prod` relationship
        # on a collector fired in the same minute (measured on pve9: two
        # relationships, two seconds apart).
        #
        # The tiered resolver was generic from the day it was written, and had
        # exactly one caller until now. This is the second.
        #
        # Its NAME is deliberately not written next to a following word here.
        # The allow-list test scrapes "<helper> <word>" out of this file and
        # cannot tell a comment from code, so naming the helper in prose invents
        # a field -- which is what the paragraph a few hundred lines up warns
        # about, and what my first version of this comment did ("... has been
        # generic" produced a field called `has`).
        if send_schedule="$(resolve_field_tiered send_schedule "$tier" "$ds" "$tmpl" defaults)"; then
            lint_cron_schedule "$send_schedule" "[dataset:$ds_path] tier=$tier" send_schedule
            tier_send_schedule="$send_schedule"
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
            # LINK FIELDS -- resolved from the [dataset:] section only (see the
            # block above link_flag_letter_present for why no template/defaults
            # layer), and rendered BEFORE -A is considered on purpose: an
            # explicit compressor makes snapsend's autotune stand down, and
            # maybe_add_autotune already knows that. Rendering them afterwards
            # would emit a line carrying both -A and -Z -- a cron line that
            # announces a no-op on every run.
            #
            # The lookup below returns 1 for an ABSENT field and prints "" for a
            # present but blank one. Those are different mistakes and the lints
            # say so, hence reading the status instead of collapsing both into
            # `|| x=""`.
            #
            # (The helper is deliberately not named in this sentence: the
            # allow-list test in test/run.sh scrapes "<helper> <word>" out of
            # this file, so prose naming it turns the next word into a field
            # that does not exist. The file says so a few hundred lines up, and
            # CI caught me doing it anyway.)
            local link_bw="" link_comp="" link_ciph=""
            if link_bw="$(resolve_field bandwidth "$ds" "" "")"; then
                lint_link_bandwidth "$link_bw" "$flags" "[dataset:$ds_path] tier=$tier"
            else link_bw=""; fi
            if link_comp="$(resolve_field compression "$ds" "" "")"; then
                lint_link_compression "$link_comp" "$flags" "[dataset:$ds_path] tier=$tier"
            else link_comp=""; fi
            if link_ciph="$(resolve_field cipher "$ds" "" "")"; then
                lint_link_cipher "$link_ciph" "$flags" "[dataset:$ds_path] tier=$tier" "$remote_spec"
            else link_ciph=""; fi
            flags="$(add_link_flags "$flags" "$link_bw" "$link_comp" "$link_ciph")"
            local autotune
            autotune="$(resolve_field autotune "$ds" "$tmpl" defaults)" || autotune=""
            lint_autotune "$autotune" "[dataset:$ds_path] tier=$tier"
            flags="$(maybe_add_autotune "$flags" "$remote_spec" "$autotune")"
            local quiesce
            quiesce="$(resolve_field quiesce "$ds" "$tmpl" defaults)" || quiesce=""
            # ONLY when the tier said nothing. Reviewer contract, 2026-08-26: the
            # host file is a fallback for silence, never a widening of something
            # explicit -- a tier that says `auto` keeps meaning fail-closed
            # `auto`, and no host default may quietly turn it into
            # `auto,degrade`. That is why this tests for empty rather than
            # merging, and why it runs BEFORE lint_quiesce: whatever the host
            # file supplies has to survive exactly the same grammar as a value
            # written in the config.
            [ -n "$quiesce" ] || quiesce="$(settings_get quiesce "")"
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
            SEND_ENTITIES+=("${ds_path}${SEP}${tier}${SEP}${send_schedule}${SEP}${remote_spec}${SEP}${prefix}${SEP}${flags}${SEP}${notify}${SEP}${label}${SEP}${direction}${SEP}${media}${SEP}${pair_label}")
        fi

        # ---- inline self-prune (own path, non-recursive) ----
        # prune_schedule is the deliberate "yes, prune this dataset" signal.
        local prune_schedule
        # Per tier for the same reason as send_schedule above -- a flat profile
        # prunes from its tiers, so its prune minutes need spreading too.
        if prune_schedule="$(resolve_field_tiered prune_schedule "$tier" "$ds" "$tmpl" defaults)"; then
            lint_cron_schedule "$prune_schedule" "[dataset:$ds_path] tier=$tier" prune_schedule
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
            INLINE_PRUNE_ENTITIES+=("${ds_path}${SEP}${tier}${SEP}${pattern}${SEP}${retain_flag}${SEP}${prune_schedule}${SEP}${pnotify}${SEP}${rec_scope}${SEP}${pair_label}")
            SCOPE_PATTERNS+=("${ds_path}${SEP}${pattern}")

            # ---- monitor (rides this same pattern and the same scope) ----
            if resolve_monitor "$ds" "$tmpl" "[dataset:$ds_path] tier=$tier"; then
                # A threshold no larger than this tier's own longest silence
                # alarms on a healthy job, every cycle, forever. Only checkable
                # where the CADENCE is known, which is exactly here: this tier
                # both sends and monitors, so the schedule that refreshes the
                # snapshot and the threshold that judges its age are the same
                # config's business.
                #
                # Deliberately NOT extended to [prune:] sections or to a
                # dataset tier with no send_schedule. There the family arrives
                # from upstream -- another host's push, a pvesr chain -- and
                # its cadence is not in this file. Guessing it is how a monitor
                # that is correctly sized for a two-hop chain would get
                # refused.
                #
                # The comparison is against a LOWER bound on the true worst
                # gap (see cron_max_gap_minutes), and it is strict: equality
                # already means the alarm fires exactly as the next run is due.
                if [ -n "$tier_send_schedule" ]; then
                    local gap_min warn_sec
                    gap_min="$(cron_max_gap_minutes "$tier_send_schedule")"
                    if [ -n "$gap_min" ]; then
                        warn_sec="$(duration_seconds "$MONITOR_WARN" "[dataset:$ds_path] tier=$tier: monitor_warn")"
                        [ "$warn_sec" -gt "$((gap_min * 60))" ] || die "[dataset:$ds_path] tier=$tier: monitor_warn ($MONITOR_WARN) is not longer than this tier's own longest gap between runs (${gap_min}m, from send_schedule '$tier_send_schedule') -- a healthy job reaches exactly that age just before every run, so this monitor would alert on every cycle and never on a real fault. Raise monitor_warn above ${gap_min}m with room for the run itself, or take the schedule down to the cadence the threshold assumes."
                    fi
                fi
                local mnotify mbroken mwarntext
                mnotify="$(notify_text "$host_label" "$ntier" "stale" "$plabel")"
                mbroken="$(notify_text "$host_label" "$ntier" "monitor BROKEN" "$plabel")"
                mwarntext="$(notify_text "$host_label" "$ntier" "getting stale" "$plabel")"
                # monitor_exclude (declared-passive, 2026-08-23): comma-separated name
                # PREFIXES this monitor must not see -- neither satisfying
                # freshness nor raising it. Reaches check-snap-age.sh as -x
                # flags. Resolved like every other tier field (ds overrides
                # template); absent = empty = the monitor sees everything,
                # exactly as before.
                local mexcl; mexcl="$(resolve_field_or_omit monitor_exclude "$ds" "$tmpl" "")" || mexcl=""
                MONITOR_ENTITIES+=("${ds_path}${SEP}${pattern}${SEP}${MONITOR_WARN}${SEP}${MONITOR_CRIT}${SEP}${MONITOR_SCHEDULE}${SEP}${rec_scope}${SEP}${mnotify}${SEP}${mbroken}${SEP}${mwarntext}${SEP}${pair_label}${SEP}${mexcl}")
            fi
        fi
    done
}

# build_prune_section SECTION_HEADER SCOPE HOST_LABEL
build_prune_section() {
    local sec="$1" scope="$2" host_label="$3"

    local tier_list
    tier_list="$(resolve_field use_template "$sec" "" "")" || die "[prune:$scope] has no use_template"

    local recursive clearcut
    resolve_bool_field recursive "$sec" "" "[prune:$scope]" 0; recursive="$BOOL_FIELD"
    resolve_bool_field clear_cut "$sec" "" "[prune:$scope]" 0; clearcut="$BOOL_FIELD"

    local ssh_flags
    ssh_flags="$(resolve_field ssh_flags "$sec" "" "")" || ssh_flags=""
    lint_ssh_flags "$ssh_flags" "[prune:$scope]" "$scope"

    # REV-20260804-045 said this reached ONLY the staleness monitor, because the
    # delsnaps line was never gated by the logical pause. That stopped being
    # true when delsnaps.sh gained -L: the label now reaches BOTH the monitor
    # and the prune, and the prune exits before any listing, SSH or destroy
    # while the pause stands. Corrected under REV-20260829-124 F2 -- a comment
    # describing the opposite of the code is how the next reader reintroduces
    # the gap.
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
    local gfs gfs_pattern="" gfs_retain_parts="" gfs_schedule=""
    resolve_bool_field gfs "$sec" "" "[prune:$scope]" 0; gfs="$BOOL_FIELD"
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

        local prune_schedule pattern retain_flag plabel praw pnotify emit_prune
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
        resolve_bool_field prune "$sec" "$tmpl" "[prune:$scope] tier=$tier" 1; emit_prune="$BOOL_FIELD"

        plabel="$(resolve_field notify "$sec" "$tmpl" "")" || plabel=""
        pattern="$(require_field pattern "$sec" "$tmpl" defaults)" \
            || die "[prune:$scope] tier=$tier: 'pattern' did not resolve (missing, or set but blank)"

        # Basket A4, the [prune:] half. build_dataset already refuses a tier
        # that CREATES one family and prunes another; a [prune:] section does
        # not create, so that guard never sees it -- but when its tier's own
        # template carries a 'prefix', the template is declaring which family
        # it is about, and a pattern that cannot see that family is the same
        # silent divergence: the family the template creates elsewhere grows
        # without bound while this prune reports success against whatever DOES
        # match. Checked only from the section/template pair, never [defaults]
        # -- a defaults-level prefix is a send-side convenience, and judging a
        # section that legitimately prunes an upstream family against it would
        # refuse correct configs.
        local _tpl_prefix
        _tpl_prefix="$(resolve_field prefix "$sec" "$tmpl" "")" || _tpl_prefix=""
        if [ -n "$_tpl_prefix" ] && [ "${_tpl_prefix:0:${#pattern}}" != "$pattern" ]; then
            die "[prune:$scope] tier=$tier: this tier's template names the family 'prefix = $_tpl_prefix' but prunes 'pattern = $pattern' -- delsnaps.sh matches by literal prefix, so this prune can never touch that family. Make 'pattern' a prefix of 'prefix' (usually they are equal), or drop 'prefix' from a template that is only about pruning."
        fi

        if [ "$emit_prune" -eq 1 ] && [ "$gfs" -eq 1 ]; then
            # This tier is about to hand the ladder a bucket letter and a count.
            # For that to mean anything the ladder has to be able to SEE this
            # tier's snapshots -- delsnaps.sh matches by literal prefix, so the
            # tier's 'pattern' must start with 'gfs_pattern'. Otherwise the
            # count is applied to whichever family gfs_pattern DOES match, and
            # this tier's own family is pruned by nothing at all while its
            # monitor -- which keeps using its own 'pattern' -- stays green
            # because fresh snapshots do keep arriving. Same silent shape as the
            # create/prune disagreement guarded in build_dataset.
            #
            # An omitted gfs_pattern (Phase 3.5 prefixless ladder) is the empty
            # string, which is a prefix of everything, so it passes here without
            # a special case -- correctly: an empty pattern matches every
            # snapshot on the scope, which is exactly what prefixless means.
            #
            # Only CONTRIBUTING tiers are checked. A prune=no tier is a monitor
            # carrier that gives the ladder nothing, so its pattern is its own
            # business.
            if [ "${pattern:0:${#gfs_pattern}}" != "$gfs_pattern" ]; then
                die "[prune:$scope] tier=$tier: this tier feeds the gfs ladder but its 'pattern' ('$pattern') does not start with 'gfs_pattern' ('$gfs_pattern') -- delsnaps.sh matches by prefix, so the ladder never sees this tier's snapshots. Its retention count would be spent on whatever gfs_pattern does match, and '$pattern' snapshots would be pruned by nothing while their monitor stays green. Make 'gfs_pattern' a common prefix of every tier in use_template (e.g. 'automated_' for automated_hourly/automated_daily), or omit it entirely for a prefixless ladder."
            fi
            prune_schedule="$(resolve_field prune_schedule "$sec" "$tmpl" defaults)" || die "[prune:$scope] tier=$tier: template has no prune_schedule"
            lint_cron_schedule "$prune_schedule" "[prune:$scope] tier=$tier" prune_schedule
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
            lint_cron_schedule "$prune_schedule" "[prune:$scope] tier=$tier" prune_schedule
            resolve_keep_retain "$sec" "$tmpl" "$tier" || die "[prune:$scope] tier=$tier: ${KEEP_RETAIN_ERROR:-prune_schedule is set but neither 'keep' nor 'retain' resolved}"
            retain_flag="$RESOLVED_RETAIN"
            praw="$(resolve_field notify_raw_prune "$sec" "$tmpl" "")" || praw=""
            if [ -n "$praw" ]; then pnotify="$praw"; else pnotify="$(notify_text "$host_label" "$ntier" "prune" "$plabel")"; fi
            PRUNE_SEC_ENTITIES+=("${scope}${SEP}${tier}${SEP}${pattern}${SEP}${retain_flag}${SEP}${prune_schedule}${SEP}${pnotify}${SEP}${recursive}${SEP}${clearcut}${SEP}${ssh_flags}${SEP}${pair_label}")
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
            local mexcl; mexcl="$(resolve_field_or_omit monitor_exclude "$sec" "$tmpl" "")" || mexcl=""
            MONITOR_ENTITIES+=("${scope}${SEP}${pattern}${SEP}${MONITOR_WARN}${SEP}${MONITOR_CRIT}${SEP}${MONITOR_SCHEDULE}${SEP}${recursive}${SEP}${mnotify}${SEP}${mbroken}${SEP}${mwarntext}${SEP}${pair_label}${SEP}${mexcl}")
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
        GFS_PRUNE_SEC_ENTITIES+=("${scope}${SEP}${gfs_pattern}${SEP}${gfs_retain_parts}${SEP}${gfs_schedule}${SEP}${gpnotify}${SEP}${recursive}${SEP}${clearcut}${SEP}${ssh_flags}${SEP}${pair_label}")
        SCOPE_PATTERNS+=("${scope}${SEP}${gfs_pattern}")
    fi
}

# build_bookmark_prune_section SECTION_HEADER SCOPE HOST_LABEL
# No templates/tiers: bookmark pruning is one age-threshold operation per
# scope, unrelated to any send/prune tier's own cadence. Reads fields
# directly off the section (ini_has/ini_get), not through resolve_field's
# dataset/template/defaults layering -- there is no layering to do here.
# build_replica_section SECTION_HEADER NAME HOST_LABEL
#
# [replica:<name>] -- one more copy of a dataset this host already holds, most
# often onto a disk that gets unplugged. See the field allow-list above for why
# this is a section type of its own rather than a second dst on [dataset:].
#
# Deliberately NOT inherited from [template:]. A template carries a backup
# policy -- retention tiers, prune schedules, a monitor -- and a replica has
# none of those; letting it use_template would mean silently ignoring most of
# what the template says, which is how a config comes to mean something other
# than it reads.
build_replica_section() {
    local sec="$1" name="$2" host_label="$3"

    case "$name" in
        ''|*[!A-Za-z0-9._-]*) die "[replica:$name]: the name is a label for the medium -- letters, digits, dot, dash, underscore only (it becomes the notify text and the media gate's state file name)" ;;
    esac

    ini_has "$sec" source || die "[replica:$name] has no 'source' -- name the dataset on THIS host to copy (a replica copies what we already hold; it does not reach for a remote)"
    local source; source="$(ini_get "$sec" source)"
    case "$source" in
        */*) ;;
        *) die "[replica:$name]: source='$source' is a pool name, not a dataset -- name the dataset to copy" ;;
    esac
    case "$source" in
        *[!A-Za-z0-9._:/-]*|-*) die "[replica:$name]: source='$source' is not a valid ZFS dataset name" ;;
    esac

    ini_has "$sec" dst || die "[replica:$name] has no 'dst' -- the base dataset on the target medium, e.g. usbrep1/replica"
    local dst; dst="$(ini_get "$sec" dst)"
    # LOCAL ONLY, and refused rather than quietly accepted. A remote replica is
    # a backup relationship and belongs in [dataset:] with a pair_label, where
    # it gets the monitor and the pause a remote link needs. Accepting a
    # user@host here would produce a job with neither.
    case "$dst" in
        *:*) die "[replica:$name]: dst='$dst' names a remote target. A replica is a LOCAL copy of what this host already holds; a copy onto another machine is a backup relationship and belongs in a [dataset:] section with a pair_label, so that it gets the staleness monitor and the pause that a remote link needs." ;;
    esac
    case "$dst" in
        */*) ;;
        *) die "[replica:$name]: dst='$dst' is a pool name, not a dataset. Name the base dataset the administrator prepares on the medium (e.g. ${dst}/replica) -- that dataset existing is what tells the gate the RIGHT disk is in the slot, and a pool root cannot say that." ;;
    esac
    case "$dst" in
        *[!A-Za-z0-9._:/-]*|-*) die "[replica:$name]: dst='$dst' is not a valid ZFS dataset name" ;;
    esac
    # The source cannot be inside its own target, or every run would copy the
    # previous run's copy.
    case "$dst" in
        "$source"|"$source"/*) die "[replica:$name]: dst='$dst' is inside source='$source' -- each run would copy the previous run's copy" ;;
    esac
    case "$source" in
        "$dst"/*) die "[replica:$name]: source='$source' is inside dst='$dst' -- the target holds the source" ;;
    esac

    ini_has "$sec" schedule || die "[replica:$name] has no 'schedule'"
    local schedule; schedule="$(ini_get "$sec" schedule)"
    lint_cron_schedule "$schedule" "[replica:$name]" schedule

    # A FAMILY OF ITS OWN, and this is the owner's point (2026-08-28): the
    # replica's snapshots must not be mistaken for the source's. They exist on
    # the copy and not on the machine the data came from, so sharing the
    # incoming family's prefix would make the collector's own retention and
    # staleness reasoning answer for snapshots it never took.
    local prefix; prefix="$(resolve_field prefix "$sec" "" "")" || prefix=""
    [ -n "$prefix" ] || die "[replica:$name] has no 'prefix' -- a replica takes its own snapshot family, separate from the one it is copying, so that the copy's snapshots are never confused with the source's"
    case "$prefix" in
        *[!A-Za-z0-9._-]*) die "[replica:$name]: prefix='$prefix' -- letters, digits, dot, dash, underscore only (it becomes part of a snapshot name)" ;;
    esac

    # Composed here, like every other section type, so the emitter has nothing
    # to assemble and $host_label does not have to be in scope at emit time.
    local label notify
    label="$(resolve_field notify "$sec" "" "")" || label=""
    [ -n "$label" ] || label="$name"
    notify="$(notify_text "$host_label" "replica" "copy" "$label")"

    local media; media="$(resolve_field media "$sec" "" "")" || media=""
    case "$media" in
        ''|removable) ;;
        *) die "[replica:$name]: media='$media' -- the only value is 'removable' (the target is a disk that gets unplugged, so the run is bracketed by zpool import/export and an absent disk is a skip rather than a failure). Leave the field out for a target that is always there." ;;
    esac

    local recursive; resolve_bool_field recursive "$sec" "" "[replica:$name]" 0; recursive="$BOOL_FIELD"

    local flags; flags="$(resolve_field flags "$sec" "" "")" || flags=""
    lint_flags "$flags" "[replica:$name]"

    # history -- HOW MUCH OF THE GAP TRAVELS, when a common snapshot survived.
    #
    # Owner's question, 2026-08-29: for a disk that was in a safe for a quarter,
    # dragging every snapshot in between may be exactly wrong -- or exactly the
    # point. There is no default that is right for both of his own disks:
    #
    #   * the weekly rotating pair carries the current state, and the snapshots
    #     that happened while it was in the drawer are cheap but pointless;
    #   * the quarterly disk IS the archive, and the full history is arguably
    #     the whole reason for fetching it out.
    #
    # So it is stated, not guessed. `all` keeps zfs send -I, the default this
    # package has always had; `newest` is -i; `auto:N` is -T N, which measures
    # the gap in the DATASET'S OWN snapshot intervals rather than wall-clock.
    #
    # It only bites when a common snapshot still exists. Once retention has
    # eaten it the engine falls back to the bookmark anchor, and a bookmark
    # carries no data -- the send is one diff whatever this field says.
    #
    # THE COST, because a field that hides it would be worse than no field: with
    # `newest` or `auto`, the copy gets HOLES. Snapshots taken between two
    # visits of the medium never reach it. What is already on the disk stays.
    local history hist_flags=""
    history="$(resolve_field history "$sec" "" "")" || history=""
    case "$history" in
        ''|all)   hist_flags="" ;;
        newest)   hist_flags="-i" ;;
        auto:*)   local _n="${history#auto:}"
                  case "$_n" in
                      ''|*[!0-9]*) die "[replica:$name]: history='$history' -- auto: takes a count of the dataset's own snapshot intervals, e.g. auto:3" ;;
                  esac
                  [ "$_n" -gt 0 ] 2>/dev/null || die "[replica:$name]: history='$history' -- auto:0 would switch on the first run, which is what 'newest' says plainly"
                  hist_flags="-T $_n" ;;
        auto)     die "[replica:$name]: history='auto' needs the count it switches at, e.g. auto:3 -- how many of this dataset's own snapshot intervals may pass before the run stops carrying intermediates" ;;
        *)        die "[replica:$name]: history='$history' -- expected 'all' (every snapshot in between, zfs send -I, the default), 'newest' (only the diff to the newest, -i) or 'auto:N' (-T N: let the engine decide, measured in this dataset's own snapshot intervals)" ;;
    esac
    # TWO ANSWERS TO ONE QUESTION IS A REFUSAL, not a precedence rule. Somebody
    # who wrote both meant one of them, and picking for them is how a config
    # comes to mean something other than it reads.
    if [ -n "$hist_flags" ]; then
        case " $flags " in
            *" -i "*|*" -T "*) die "[replica:$name]: history='$history' and 'flags' both decide how much of the gap travels ('$flags'). Say it once -- keep 'history' and drop -i/-T from flags." ;;
        esac
    fi

    REPLICA_ENTITIES+=("${name}${SEP}${source}${SEP}${dst}${SEP}${schedule}${SEP}${prefix}${SEP}${notify}${SEP}${media}${SEP}${recursive}${SEP}${hist_flags}${SEP}${flags}")
}

build_bookmark_prune_section() {
    local sec="$1" scope="$2" host_label="$3"

    ini_has "$sec" schedule || die "[prune-bookmarks:$scope] has no 'schedule'"
    local schedule
    schedule="$(ini_get "$sec" schedule)"
    lint_cron_schedule "$schedule" "[prune-bookmarks:$scope]" schedule

    ini_has "$sec" age || die "[prune-bookmarks:$scope] has no 'age' (raw delsnaps.sh age flags, e.g. \"-d30\")"
    local age
    age="$(ini_get "$sec" age)"
    # Same whitelist as retain= (basket A3), for the same reason: this string
    # reaches delsnaps.sh verbatim, and "only -n is refused" left every
    # operation flag -- including -F, clear-cut -- valid in a field named
    # 'age'. The -n refusal keeps its own specific message because a dry-run
    # here has a specific consequence (a job that never prunes), not just a
    # wrong shape.
    local tok _age_pending=""
    for tok in $age; do
        [ "$tok" = "-n" ] && die "[prune-bookmarks:$scope]: 'age' contains -n (dry-run) -- never actually prunes anything as a recurring job"
        if [ -n "$_age_pending" ]; then
            case "$tok" in
                ''|*[!0-9]*) die "[prune-bookmarks:$scope]: 'age' -- '$_age_pending' needs a number and '$tok' is not one" ;;
            esac
            _age_pending=""
            continue
        fi
        case "$tok" in
            -[yYmMwWdDhH])
                _age_pending="$tok" ;;
            -[yYmMwWdDhH][0-9]*)
                case "${tok:2}" in *[!0-9]*)
                    die "[prune-bookmarks:$scope]: 'age' token '$tok' has a malformed count" ;;
                esac ;;
            *)
                die "[prune-bookmarks:$scope]: 'age' token '$tok' is not a retention flag (takes -y/-m/-w/-d/-h or -Y/-M/-W/-D/-H with a number, e.g. -d30 or '-d 30'). Operation flags do not belong here" ;;
        esac
    done
    [ -n "$_age_pending" ] && die "[prune-bookmarks:$scope]: 'age' -- '$_age_pending' at the end has no number"

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

    local recursive
    resolve_bool_field recursive "$sec" "" "[prune-bookmarks:$scope]" 0; recursive="$BOOL_FIELD"

    local label notify
    label="$(resolve_field notify "$sec" "" "")" || label=""
    notify="$(notify_text "$host_label" "bookmarks" "prune" "$label")"

    local ssh_flags
    ssh_flags="$(resolve_field ssh_flags "$sec" "" "")" || ssh_flags=""
    lint_ssh_flags "$ssh_flags" "[prune-bookmarks:$scope]" "$scope"

    # The same relationship gate as every other prune line. A bookmark is what
    # a restore falls back to when the snapshot itself is gone, so a bookmark
    # prune still running through a recovery can take the last thing standing.
    local pair_label
    pair_label="$(resolve_field pair_label "$sec" "" "")" || pair_label=""
    if [ -n "$pair_label" ]; then
        case "$pair_label" in
            *[!A-Za-z0-9._-]*) die "[prune-bookmarks:$scope]: pair_label='$pair_label' -- letters, digits, dot, dash, underscore only (it becomes delsnaps -L and a directory name under /var/lib/zfs-snapshot-all/relationships)" ;;
        esac
    fi
    BOOKMARK_PRUNE_ENTITIES+=("${scope}${SEP}${pattern}${SEP}${age}${SEP}${schedule}${SEP}${notify}${SEP}${recursive}${SEP}${ssh_flags}${SEP}${pair_label}")
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
        IFS="$SEP" read -r ds tier schedule dst prefix flags notify label direction media plabel <<< "$e"
        # direction is IN the key: a push and a pull could otherwise share an
        # identical (schedule,remote-spec,prefix,flags) tuple by coincidence and
        # merge into one line that calls the wrong script for half its members.
        # 'media' is IN the key. The import/export bracket wraps the whole cron
        # line, so a removable target merged with an ordinary one would either
        # export a pool the other job still needs, or skip that other job every
        # time the disk is out. They are different lines by construction.
        key="${schedule}${SEP}${dst}${SEP}${prefix}${SEP}${flags}${SEP}${direction}${SEP}${media}${SEP}${plabel}"
        [ -z "${SEND_GROUPS[$key]+x}" ] && SEND_GROUP_ORDER+=("$key")
        SEND_GROUPS["$key"]+="${e}${LSEP}"
    done
}

group_inline_prune() {
    declare -gA INLINE_PRUNE_GROUPS=()
    declare -ga INLINE_PRUNE_GROUP_ORDER=()
    local e ds tier pattern retain schedule notify recursive pairlbl key
    for e in "${INLINE_PRUNE_ENTITIES[@]}"; do
        IFS="$SEP" read -r ds tier pattern retain schedule notify recursive pairlbl <<< "$e"
        # 'recursive' is IN the key. A delsnaps.sh line carries -R or it does
        # not, for every dataset it names -- so merging a recursive dataset
        # with a non-recursive one would silently give one of them the wrong
        # scope, either leaving descendants unpruned or pruning descendants
        # nobody asked about.
        #
        # 'notify' is in the key for exactly the same reason, one field later.
        # The render below takes its label from members[0] and drops the rest,
        # so a group spanning two relationships was swept correctly and
        # REPORTED under one name. Measured on pve9, 2026-08-25: two prod
        # relationships, four merged prune lines, every one of them announcing
        # itself as "(p1-at)" -- a failure pruning p2's dataset would have sent
        # an operator to look at p1. The estate has paid for misattributed
        # alerts before (never blame the data for a link failure), and a
        # retention job that names the wrong relationship is the same defect
        # wearing the retention hat.
        #
        # MERGE ONLY WHAT CAN BE REPORTED AS ONE THING. The cost is one prune
        # line per relationship per tier instead of one per tier -- which is
        # what the SEND side already emits, so the two sides now match rather
        # than one of them quietly folding relationships together.
        # pair_label joins the key for the same reason 'notify' did one field
        # earlier: the line carries ONE -L, so a group spanning two
        # relationships would gate both on one of them -- and a pause taken for
        # a restore would leave the other relationship's retention running
        # under a label that says it is stopped. In practice 'notify' already
        # separates them; this makes the property structural rather than
        # incidental to how the notify text happens to be built.
        key="${schedule}${SEP}${pattern}${SEP}${retain}${SEP}${recursive}${SEP}${notify}${SEP}${pairlbl}"
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
        IFS="$SEP" read -r scope pattern warn crit schedule recursive notify broken warntext pairlbl mexcl <<< "$e"
        # pair_label is IN the key (REV-045): two relationships sharing a
        # threshold shape must not merge into one check-snap-age line --
        # pausing one would silence the staleness alarm of the other.
        # mexcl is part of the key: two monitors that differ only in what they
        # must NOT see cannot share one line -- merging them would silently
        # apply one relation's blind spots to the other.
        key="${schedule}${SEP}${pattern}${SEP}${warn}${SEP}${crit}${SEP}${recursive}${SEP}${pairlbl}${SEP}${mexcl}"
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
    local e scope pattern age schedule notify recursive sshflags pairlbl key
    # EVERY field is named. `read` puts the unread remainder in the LAST
    # variable, so a reader one name short does not fail -- it silently glues
    # the extra field onto ssh_flags. That is what happened here when
    # pair_label was appended to this tuple: the rendered line carried
    # `-p 2222<SEP>relacja1` as if it were a port. Third time in this file for
    # the same family; see the error log's R3 and E21.
    for e in "${BOOKMARK_PRUNE_ENTITIES[@]}"; do
        IFS="$SEP" read -r scope pattern age schedule notify recursive sshflags pairlbl <<< "$e"
        # pair_label is IN the key: -L becomes part of the emitted command, so
        # two scopes belonging to different relationships cannot share a line.
        key="${schedule}${SEP}${pattern}${SEP}${age}${SEP}${recursive}${SEP}${sshflags}${SEP}${pairlbl}"
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
# A [prune-bookmarks:] scope that covers the SOURCE of a removable replica.
#
# `record_send_bookmark` leaves one bookmark per target, named tgt-<8 hex>, on
# the SOURCE dataset. For an ordinary target that bookmark is a convenience. For
# a disk that gets unplugged it is the whole feature: when the medium comes back
# after the collector's retention has pruned the last common snapshot, that
# bookmark is the only thing left anchoring an incremental send. Without it the
# next run is a full re-seed, which on the ten-terabyte case this was built for
# is the difference between minutes and days.
#
# And -B is aimed squarely at it. Its whole premise is that a bookmark nobody
# refreshed within the threshold is orphaned -- true for a decommissioned VM,
# false for a disk in a safe, which is refreshed only when it is plugged in. A
# medium rotated quarterly against `-d30` is indistinguishable, to -B, from a
# job that no longer exists.
#
# WARN, DO NOT REFUSE, AND DO NOT QUIETLY EXCLUDE. Both tempting alternatives
# take the decision away from the administrator: a refusal blocks a config that
# may be exactly what was meant, and a silent exclusion leaves a prune rule that
# does not do what it says. Say what the collision is and let the person who
# owns the disks decide.
validate_media_anchor_prune() {
    local e ds media _f
    local b scope pattern age recursive _g hit
    local -a removable=()
    for e in "${SEND_ENTITIES[@]+"${SEND_ENTITIES[@]}"}"; do
        IFS="$SEP" read -r ds _f _f _f _f _f _f _f _f media _f <<< "$e"
        [ "$media" = removable ] && removable+=("$ds")
    done
    [ "${#removable[@]}" -gt 0 ] || return 0

    for b in "${BOOKMARK_PRUNE_ENTITIES[@]+"${BOOKMARK_PRUNE_ENTITIES[@]}"}"; do
        IFS="$SEP" read -r scope pattern age _g _g recursive _g _g <<< "$b"
        # Could this pattern match a name of the form tgt-<hash>? delsnaps
        # matches by literal string prefix, so either the pattern is a prefix of
        # "tgt-" (it matches every anchor) or "tgt-" is a prefix of the pattern
        # (it matches some of them). Anything else cannot touch an anchor and is
        # not worth a word.
        case "tgt-" in
            "$pattern"*) : ;;
            *) case "$pattern" in "tgt-"*) : ;; *) continue ;; esac ;;
        esac
        for ds in "${removable[@]}"; do
            hit=0
            [ "$scope" = "$ds" ] && hit=1
            [ "$recursive" = "1" ] && case "$ds" in "$scope"/*) hit=1 ;; esac
            [ "$hit" -eq 1 ] || continue
            warn "[prune-bookmarks:$scope] covers '$ds', the source of a replica onto REMOVABLE media, and its pattern '$pattern' can match the tgt- anchor bookmark that replica depends on."
            warn "  That anchor is refreshed only when the disk is plugged in, so a medium rotated less often than '$age' looks orphaned to -B and is pruned. The next sync after the disk returns is then a FULL re-seed instead of an increment."
            warn "  Not refused, and nothing has been excluded for you: narrow the scope, lengthen the age past your longest rotation, or accept the re-seed. It is your disk rotation, not the generator's to guess."
        done
    done
}

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
        IFS="$SEP" read -r ds tier schedule dst prefix flags notify label direction media plabel <<< "${members[0]}"
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
        IFS="$SEP" read -r ds tier schedule dst prefix flags notify label direction media plabel <<< "${members[0]}"

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
            cmd="$(media_bracket "$media" "$local_base" "${plabel:-$label}" "$cmd")"
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
                IFS="$SEP" read -r mds mtier msch mdst mpre mflg mnot mlab mdir mmed mplb <<< "$m"
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
                    IFS="$SEP" read -r mds mtier msch mdst mpre mflg mnot mlab mdir mmed mplb <<< "$m"
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
        # The LANDING dataset, not just the pool: snapsend composes dst/src, and
        # WHAT IDENTIFIES THE MEDIUM IS THE BASE, NOT THE LANDING PATH.
        #
        # This used to hand the gate "$dst/$src" -- where the write actually
        # lands -- on the theory that checking the real destination is the
        # honest check. It is the opposite. That leaf is created BY the engine,
        # so on a freshly prepared disk it does not exist yet, and the gate
        # answered the very first sync with "pool is imported but DATASET is not
        # on it -- it is the wrong one". The right disk, refused as the wrong
        # one, and under the status rules above that refusal alerts. A new
        # removable disk could never be seeded. Proven live on pve0, 2026-08-29.
        #
        # The base is what the administrator creates once when preparing the
        # disk, so it exists before the first write and stays for the life of
        # the medium: exactly the property an identity check needs. A different
        # disk carrying a pool of the same name but not that dataset is still
        # caught, which is the case the check exists for. Where the base IS the
        # pool root the test degrades to presence, which is honest.
        _mb_target="$dst"
        cmd="$(media_bracket "$media" "$_mb_target" "${plabel:-$label}" "$cmd")"

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
# THE IMPORT/EXPORT BRACKET around one job whose target is a removable disk.
#
# Returns the command unchanged for an ordinary target, so every existing line
# is byte-identical and this can only affect a section that asked for it.
#
# The shape is `if attach; then ENGINE; fi; detach`, and each piece of that is
# deliberate:
#
#   * A SUBSHELL, and that is not cosmetic. job_cron_line puts this into a slot
#     built for ONE command: `CMD 2>"$e"; rc=$?`. This used to emit a bare
#     `if ...; fi; detach` sequence there, and both halves of the wrapper then
#     bound to the LAST command only -- so the engine's stderr never reached
#     "$e" (it went to cron's own stderr, i.e. the mail flood this package
#     exists to stop) and `rc=$?` was detach's status. Proven live on pve0,
#     2026-08-29: the engine exited 1 and the line reported 0.
#   * detach runs OUTSIDE the `if`, so a failed transfer still puts the pool
#     back. A disk left imported after a failure is a disk somebody unplugs.
#   * THE STATUS IS CHOSEN, NOT INHERITED. The whole point of this field is to
#     separate the one silence that is correct from every noise that is not:
#       attach 0 -> the engine ran, and the LINE reports what the ENGINE said;
#       attach 1 -> the disk is in a safe. Silence. This case, and only this;
#       attach 2 -> the WRONG disk is in the slot, or the import could not be
#                   recorded. Not an absent medium, and it alerts.
#     A bracket returning 0 for all three suppresses real backup failures,
#     which is worse than having no bracket at all.
#   * detach's failure raises too, when nothing worse already has: the pool is
#     still imported on a disk somebody is about to unplug, and its DO NOT
#     UNPLUG lands in the mail body. A confusing alert after a good transfer
#     beats silence about a replica about to be corrupted.
#
# The pool is the first component of the target path -- that is what gets
# imported, and the full path is passed as --dataset so the gate can tell an
# absent disk from the WRONG disk in the slot.
media_bracket() {   # <media field> <target path> <label> <command> [source] [prefix]
    local media="$1" target="$2" label="$3" cmd="$4" src="${5:-}" pref="${6:-}"
    [ "$media" = removable ] || { printf '%s' "$cmd"; return 0; }
    [ -n "$target" ] || { printf '%s' "$cmd"; return 0; }
    local pool="${target%%/*}"
    [ -n "$pool" ] || { printf '%s' "$cmd"; return 0; }
    local gate="$REPO_DIR/zfs-media-gate.sh"
    # --source/--prefix let attach answer 'is there anything to copy' on the
    # SOURCE, before the medium is touched at all. The window in which pulling
    # this disk can hang the host is exactly the window in which its pool is
    # imported, so a run with nothing to send should not open one.
    local srcopt=""
    [ -n "$src" ] && [ -n "$pref" ] && srcopt=" --source $src --prefix $pref"
    printf '( %s attach %s %s --dataset %s%s; a=$?; if [ $a -eq 0 ]; then %s; m=$?; elif [ $a -eq 1 ]; then m=0; else m=$a; fi; %s detach %s %s; d=$?; [ $m -ne 0 ] && exit $m; exit $d )' \
        "$gate" "$pool" "${label:-media}" "$target" "$srcopt" "$cmd" "$gate" "$pool" "${label:-media}"
}

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
    local key list ds tier pattern retain schedule notify recursive pairlbl
    for key in "${INLINE_PRUNE_GROUP_ORDER[@]}"; do
        list="${INLINE_PRUNE_GROUPS[$key]}"
        local -a members=()
        IFS="$LSEP" read -ra members <<< "${list%${LSEP}}"
        IFS="$SEP" read -r ds tier pattern retain schedule notify recursive pairlbl <<< "${members[0]}"

        local -a targets=()
        local m mds mtier mpat mret msch mnot mrec mlbl
        for m in "${members[@]}"; do
            IFS="$SEP" read -r mds mtier mpat mret msch mnot mrec mlbl <<< "$m"
            targets+=("$mds")
        done
        local joined
        joined="$(IFS=,; printf '%s' "${targets[*]}")"

        local rflag="" lflag=""
        [ "$recursive" = "1" ] && rflag="-R "
        [ -n "$pairlbl" ] && lflag="-L $pairlbl "
        local cmd="$REPO_DIR/delsnaps.sh ${rflag}${lflag}${PROTECT_FLAGS}\"$joined\" \"$pattern\" $retain"
        RETAIN_LINES+=("$(job_cron_line "$schedule" "$cmd" "$notify")")
    done
}

# Prune sections: one standalone delsnaps line per tier. recursive -> -R,
# clear_cut -> -F. Additive; no cross-check against inline prune (B semantics).
emit_prune_sections() {
    local e scope tier pattern retain schedule notify recursive clearcut sshflags pairlbl
    for e in "${PRUNE_SEC_ENTITIES[@]}"; do
        IFS="$SEP" read -r scope tier pattern retain schedule notify recursive clearcut sshflags pairlbl <<< "$e"
        local flag="" fflag="" sflag="" lflag=""
        [ "$recursive" = "1" ] && flag="-R "
        [ "$clearcut" = "1" ] && fflag="-F "
        [ -n "$sshflags" ] && sflag="$sshflags "
        [ -n "$pairlbl" ] && lflag="-L $pairlbl "
        local cmd="$REPO_DIR/delsnaps.sh ${flag}${fflag}${lflag}${sflag}${PROTECT_FLAGS}\"$scope\" \"$pattern\" $retain"
        RETAIN_LINES+=("$(job_cron_line "$schedule" "$cmd" "$notify")")
    done
}

# gfs=yes sections: one combined delsnaps.sh -G line per section, covering
# every contributing tier's retain count at once (see build_prune_section).
emit_gfs_prune_sections() {
    local e scope pattern retain schedule notify recursive clearcut sshflags pairlbl
    for e in "${GFS_PRUNE_SEC_ENTITIES[@]}"; do
        IFS="$SEP" read -r scope pattern retain schedule notify recursive clearcut sshflags pairlbl <<< "$e"
        local flag="" fflag="" sflag="" lflag=""
        [ "$recursive" = "1" ] && flag="-R "
        [ "$clearcut" = "1" ] && fflag="-F "
        [ -n "$sshflags" ] && sflag="$sshflags "
        [ -n "$pairlbl" ] && lflag="-L $pairlbl "
        local cmd="$REPO_DIR/delsnaps.sh -G ${flag}${fflag}${lflag}${sflag}${PROTECT_FLAGS}\"$scope\" \"$pattern\" $retain"
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
        IFS="$SEP" read -r scope pattern warn crit schedule recursive notify broken warntext pairlbl mexcl <<< "${members[0]}"

        local -a targets=()
        local m mscope mpat mwarn mcrit msch mrec mnot mbrk mwtxt mplbl
        for m in "${members[@]}"; do
            IFS="$SEP" read -r mscope mpat mwarn mcrit msch mrec mnot mbrk mwtxt mplbl mexcl2 <<< "$m"
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
        # -x exclusions ride ahead of the positional args; comma list from the
        # config's monitor_exclude, one flag per prefix. Empty = no flags,
        # byte-identical line to before the field existed.
        local xflags="" _mx
        if [ -n "${mexcl:-}" ]; then
            for _mx in ${mexcl//,/ }; do xflags+="-x $_mx "; done
        fi
        local cmd="$REPO_DIR/check-snap-age.sh ${flag}${lflag}${xflags}\"$joined\" \"$pattern\" $warn $crit"
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
# One cron line per [replica:] section. Never grouped: each replica names its
# own medium, and the import/export bracket wraps the whole line, so merging two
# would either export a pool the other still needs or skip the other every time
# one disk is out. That is the same reason 'media' sits in the send group key.
emit_replicas() {
    local e name source dst schedule prefix notify media recursive hist flags cmd
    for e in "${REPLICA_ENTITIES[@]+"${REPLICA_ENTITIES[@]}"}"; do
        IFS="$SEP" read -r name source dst schedule prefix notify media recursive hist flags <<< "$e"
        cmd="$REPO_DIR/snapsend.sh -m \"$prefix\""
        [ "$recursive" = "1" ] && cmd="$cmd -R"
        [ -n "$hist" ] && cmd="$cmd $hist"
        [ -n "$flags" ] && cmd="$cmd $flags"
        cmd="$cmd \"$source\" \"$dst\""
        cmd="$(media_bracket "$media" "$dst" "$name" "$cmd" "$source" "$prefix")"
        JOB_LINES+=("$(job_cron_line "$schedule" "$cmd" "$notify")")
    done
}

emit_bookmark_prune() {
    local key list scope pattern age schedule notify recursive sshflags pairlbl
    for key in "${BOOKMARK_PRUNE_GROUP_ORDER[@]}"; do
        list="${BOOKMARK_PRUNE_GROUPS[$key]}"
        local -a members=()
        IFS="$LSEP" read -ra members <<< "${list%${LSEP}}"
        IFS="$SEP" read -r scope pattern age schedule notify recursive sshflags pairlbl <<< "${members[0]}"

        local -a targets=()
        local m mscope mpat mage msch mnot mrec msshf mlbl
        for m in "${members[@]}"; do
            IFS="$SEP" read -r mscope mpat mage msch mnot mrec msshf mlbl <<< "$m"
            targets+=("$mscope")
        done
        local joined
        joined="$(IFS=,; printf '%s' "${targets[*]}")"

        local flag="" sflag="" lflag=""
        [ "$recursive" = "1" ] && flag="-R "
        [ -n "$sshflags" ] && sflag="$sshflags "
        # -L goes AFTER -R, matching the other three prune shapes. The order
        # is not cosmetic: cron2conf.sh parses these lines back into a config by
        # literal flag position, and its own comment pins "-L follows -R". Emit
        # them the other way round and the inverse tool silently misreads the
        # scope.
        #
        # -L at all, because this was the ONE prune shape missing it. The owner's
        # requirement was that a pause stops every cron operation of this
        # package, prune included; bookmark prune is the shape that destroys
        # the #tgt- anchors a removable replica needs to come back as an
        # increment, so it was the worst possible one to leave running.
        [ -n "$pairlbl" ] && lflag="-L $pairlbl "
        local cmd="$REPO_DIR/delsnaps.sh -B ${flag}${lflag}${sflag}\"$joined\" \"$pattern\" $age"
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
    # NO DIGEST LINE HERE ANY MORE (2026-08-22). It used to be emitted at this
    # point, gated on `[ "${#MONITOR_LINES[@]}" -gt 0 ] && digest_script != none`,
    # and that gate is where pve9 went silent: 15 findings queued since the
    # previous day with `alert-digest` in ZERO crontabs.
    #
    # Every party was behaving correctly. There is ONE digest per host by
    # design, run by root, reading the queue BOTH accounts write; a delegated
    # account must opt out because deploy.sh deliberately never copies
    # alert-digest.sh to it. But a host whose only relationship lives in a
    # delegated account has no root block at all -- so the one party allowed to
    # schedule the digest was never asked, while the account that was asked was
    # right to decline. A boundary, not a bug in any line.
    #
    # The digest was never relationship-scoped in the first place: it summarises
    # the HOST's findings, on the HOST's schedule, into the HOST's one mail a
    # day. So it lives with the other host-level jobs -- the capacity check and
    # the auto-pull -- in deploy.sh's `zfs-backup-host` block, installed by
    # ADOPT so a hand-moved schedule survives. Emitting it from here as well
    # would give a host two digests, which is what pve1 had.
    #
    # digest_script is still parsed (an existing config naming it must not
    # break), and `none` still reads as "this account is not the sender" -- it
    # simply no longer has a line to suppress, because this function no longer
    # writes one.
    :
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
    # A host whose managed block still carries the pre-2026-08-22 digest line
    # LOSES it here: this install rewrites the block and generate_block_body no
    # longer writes one. That is the intended migration -- the digest is a HOST
    # job now, installed into deploy.sh's own block by adopt -- but the two are
    # not scheduled together. Deployment is an hourly `git pull`, not an hourly
    # deploy.sh, so between this install and whenever someone next runs deploy.sh
    # the host queues findings and mails nothing, saying nothing about it. That
    # is precisely how pve9 went silent for months.
    #
    # A warning, not a refusal: the line is legitimately leaving, and blocking
    # every host's first install after the change would be the worse failure.
    if awk '/^# BEGIN zfs-backup-managed/ { inblock = 1 }
            /^# END zfs-backup-managed/   { inblock = 0 }
            inblock && /alert-digest/     { found = 1 }
            END { exit !found }' "$current"; then
        {
            echo "gen-cron.sh: WARNING: this crontab's managed block still contains the daily"
            echo "alert digest, and this install REMOVES it. Since 2026-08-22 the digest is a"
            echo "host-level job that deploy.sh installs in its own block, not a relationship"
            echo "job -- a host that had both was sending two."
            echo "Until deploy.sh runs here, this host queues findings and mails NOTHING,"
            echo "silently. Run ./deploy.sh on this host right after this install."
        } >&2
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
#   - the BEGIN/END markers, because the lib's block readers return the block's
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
UNINSTALL=0
MIGRATE=0

while [ $# -gt 0 ]; do
    case "$1" in
        -c) CONFIG="$2"; shift 2 ;;
        --install) INSTALL=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
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
        # Same reason as --dump-fields, for the other table a profile has to
        # agree with. A profile may write the ergonomic `keep = 24`, but its
        # tier names are NAMESPACED before they reach this file, so the letter
        # can no longer be derived here -- the profile renderer derives it and
        # emits `retain`. Asking for the table instead of copying it keeps one
        # authority: a letter added here is available there the same day, and a
        # second copy cannot quietly disagree about what -W means.
        --dump-tier-letters)
            for _k in "${!TIER_LETTER[@]}"; do printf '%s %s\n' "$_k" "${TIER_LETTER[$_k]}"; done | sort
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
        # NAMED, not "whatever is left ends in pull". This matched the TAIL of
        # the tuple, so appending a field to it -- media, 2026-08-29 -- made
        # every pull section stop being recognised, silently, in a coverage
        # report whose whole job is to say what is not covered. The suite caught
        # it; the shape did not have to be catchable.
        IFS="$SEP" read -r ds tier sched remote _prefix _flags _notify _label _dir _rest <<< "$e"
        [ -n "$ds" ] || continue
        case "${SEP}${_dir}" in
            "${SEP}pull") 
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
        # Same reason as above: edir was the LAST variable, so read gave it the
        # whole remainder once the tuple grew.
        IFS="$SEP" read -r ds etier esched eremote eprefix eflags enotify elabel edir _erest <<< "$e"
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
    # 3, not 1 (basket B10). 1 is what die() exits with, so a script driving
    # --reconcile could not tell "there are uncovered datasets" from "gen-cron
    # crashed before it looked" -- and the two demand opposite reactions: a
    # report to act on, versus a report that never happened. clean-relationships
    # already draws this exact line (3 = orphans found); adopted here as the
    # package convention: 0 clean, 1 broken, 2 usage, 3 findings.
    return 3
}

# --uninstall runs BEFORE the config is required, and that is the point of it.
#
# gen-cron.sh WRITES the managed block, and until now nothing could take it
# back. A relationship could be torn down (`remove-client` calls
# cron_block_remove when the last one goes), but a LOCAL backup -- one host,
# --source/--target, no peer -- installed a block that no verb could remove:
# remove-client needs a relationship, clean-relationships.sh correctly reports
# it is not one, and an emptied config is refused ("no send/prune/monitor rules
# resolved"). Measured on pve9 2026-08-20 while working through a deployment
# matrix. The writer of a thing should be able to unwrite it.
#
# No config needed, deliberately: the common reason to want this is that the
# config is already gone, or wrong, or the one thing you are trying to get rid
# of. Requiring it would refuse exactly when it is most needed.
#
# Scope is the block and nothing else. The config file and the datasets are
# NAMED and left, the same stance the package takes everywhere -- remove-client
# with known_hosts, clean-relationships.sh with data.
if [ "$UNINSTALL" -eq 1 ]; then
    [ "$INSTALL" -eq 1 ] && die "--install and --uninstall are opposites -- pick one"
    command -v crontab >/dev/null || die "crontab command not found"
    # Same guard install_crontab already has, and for a reason worth repeating:
    # without it, a missing flock surfaces from the lock helper as "could not
    # acquire the crontab lock within 10s -- another writer is holding it",
    # which sends the operator hunting for a process that does not exist. A
    # missing tool and a contended lock are different problems.
    command -v flock >/dev/null || die "flock command not found"
    _me=$(id -un)
    if ! cron_block_remove "$_me" zfs-backup-managed; then
        die "$CRON_ERR"
    fi
    if [ "${CRON_CHANGED:-1}" -eq 0 ]; then
        echo "gen-cron.sh: no managed block in ${_me}'s crontab -- nothing to remove" >&2
        exit 0
    fi
    echo "gen-cron.sh: managed block removed from ${_me}'s crontab" >&2
    echo "gen-cron.sh: the config and the datasets are untouched. This removed the SCHEDULE, not the backups." >&2
    [ -n "$CONFIG" ] && [ -f "$CONFIG" ] && \
        echo "gen-cron.sh:   config still at $CONFIG -- delete it by hand if this deployment is really finished" >&2
    exit 0
fi

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
validate_media_anchor_prune
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
emit_replicas
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
