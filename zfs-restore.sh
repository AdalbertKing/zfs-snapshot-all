#!/bin/bash
set -uo pipefail
# ------------------------------------------------------------------------------
# zfs-restore.sh -- the restore surface of zfs-snapshot-all. Split out of
# zfs-backup.sh on 2026-08-17 (owner decision): restore is the one operation
# whose active side writes onto production data -- the inverse of every other
# verb in this tree -- so it lives in its own program. zfs-backup.sh never
# destroys client data; when it grows again, it grows HERE.
#
# The code below is the Phase 7 work moved verbatim, not rewritten: the
# read-only planner (`--plan`), the safe side-restore into <pool>/restore/,
# and the internal destructive engine (restore_replace_internal /
# restore_execute) which still has NO public door -- the CLI grammar and the
# client-side grant are owner decisions still pending, see
# docs/design/client-granted-restore.md.
#
# Public surface (unchanged by the split; zfs-backup.sh forwards `restore`
# here, so both spellings work):
#   zfs-restore.sh --plan [--dataset=DATASET] [--config=FILE]
#   zfs-restore.sh --dataset=DATASET --snapshot=NAME [--config=FILE] [--yes]
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared with zfs-backup.sh: die/warn, the server conf, and the installed-config
# field reader. Sourced, not copied -- see lib-backup-common.sh's header.
LIBCOMMON="$SCRIPT_DIR/lib-backup-common.sh"
# The transport. snapsend.sh is the push engine, and a restore is that engine
# driven in the other direction -- so it arrives with bookmarks, resume tokens,
# compression, the bandwidth cap and the PVE-reserved-snapshot refusal already
# proven, and the frozen file is not touched. Overridable so a suite can point
# it at a recorder instead of a transfer.
RESTORE_ENGINE="${RESTORE_ENGINE:-$SCRIPT_DIR/snapsend.sh}"

# THE CONNECTION IS HANDED IN, not rebuilt here.
#
# A restore under push opens ssh to the machine being written to, and the key,
# the known_hosts file and the port for that relationship are things zfs-backup.sh
# already resolves (load_client_and_connection). Deriving them a second time in
# this file would be two sources of truth about which key reaches which host --
# and the failure mode of getting that wrong is a recovery aimed at the wrong
# machine.
#
# So the caller exports RESTORE_SSH_OPTS as a plain string and this splits it.
# Deliberately word-split: these are ssh flags, none of which can contain a
# space in this project (paths are under /etc and /home, both space-free by the
# installer's own rules), and an array cannot cross an `exec` boundary.
#
# Empty is legitimate: a LOCAL restore opens no connection at all.
SSH_OPTS=()

# Datasets whose target was rolled back during this run. Declared here, at file
# scope, because restore_report_backup_cost reads its length under `set -u` and
# an array that only exists when a rollback happened would make the ordinary
# no-rollback run die on the closing report.
RESTORE_ROLLED_BACK=()
RESTORE_LANDED=()
# Set when the whole-relation scope was expanded to one entry per dataset, so
# the engine does not also recurse over what the scope already lists.
RESTORE_SCOPE_EXPANDED=0
# Whether the engine command built for the current dataset carries -r. The
# verification after it must measure exactly what was sent, no more.
RESTORE_ENGINE_RECURSED=0
if [ -n "${RESTORE_SSH_OPTS:-}" ]; then
    # shellcheck disable=SC2206
    SSH_OPTS=(${RESTORE_SSH_OPTS})
fi

# The rest of this file speaks in `echo`; the restore executor was written
# against lib-zfs-snap.sh's `log <level> <message>`, which this script does not
# source. Found on the lab, not in the suites -- every harness defined its own
# log() stub, so the absence was invisible to all of them. That is the whole
# argument for testing a transfer on real hosts.
#
# STDERR on purpose: restore_grant_parse and restore_point_unique have their
# value read through $( ), and a diagnostic printed on stdout would BECOME the
# value -- silently, and in the direction that looks like success.
log() {   # <level> <message...>
    local lvl="${1:-0}"; shift
    [ "${VERBOSE:-1}" -ge "$lvl" ] && printf '%s
' "$*" >&2
    return 0
}
[ -r "$LIBCOMMON" ] || { echo "cannot read $LIBCOMMON -- the checkout is incomplete" >&2; exit 1; }
# shellcheck disable=SC1090
source "$LIBCOMMON"

# `die` FROM INSIDE A COMMAND SUBSTITUTION HAD TO END THE PROGRAM, AND DID NOT.
#
# lib-backup-common.sh's die is `echo >&2; exit 1`, which is correct in the main
# shell and a no-op everywhere this file actually uses it: `config="$(pick ...)"`
# runs pick in a SUBSHELL, so the exit kills the subshell, the assignment gets
# the empty string, and the caller carries on.
#
# Measured on the lab, 2026-08-27, running `restore lab1 --plan` on a real
# collector. It printed THREE consecutive FATALs -- no config, then "'lab1' is
# not a relation label in ''" (note the empty config it had already refused
# over), then "no cron config known" -- and exited 0. A recovery verb that
# prints FATAL and returns success is worse than one that crashes.
#
# Fixed here rather than in the shared lib: this is the program where continuing
# past a refusal writes onto production data, and the same change to
# zfs-backup.sh's ~9000 lines is not something a lab evening can prove safe.
# The general case is worth a review; this file cannot wait for it.
#
# $$ is the MAIN shell's pid even inside $( ); $BASHPID is the current shell's.
# They differ exactly when we are in a subshell, which is the case that used to
# fail open. Proven both ways before shipping: with the kill the caller's next
# line does not run and the status is 1; without it the line runs and the status
# is 0.
RESTORE_MAIN_PID=$$
trap 'exit 1' TERM
die() {
    echo "FATAL: $*" >&2
    [ "$BASHPID" = "$RESTORE_MAIN_PID" ] || kill -TERM "$RESTORE_MAIN_PID" 2>/dev/null
    exit 1
}

# ------------------------------------------------------------------------------
# A RELATIONSHIP NAME MUST IDENTIFY ONE RELATIONSHIP
# ------------------------------------------------------------------------------
# Reviewer rule 2 (2026-08-26): the only identifier is the exact `CLIENT_NAME` in
# exactly one record under $CLIENTS_DIR, and the record's FILE NAME must agree
# with it. If two records claim the same name, or a record and its filename
# disagree, the resolver REFUSES before anything is planned.
#
# Why this is a separate check rather than a second resolver: restore_resolve_token
# below already resolves an address, and it resolves it against `pair_label` in
# the INSTALLED CONFIG -- which zfs-backup.sh writes from the very same
# CLIENT_NAME (`pair_label   = $name`, four emit sites). So the two agree on the
# STRING and differ on which file is the authority. Writing a second parser that
# read the records directly would give this program two ways to interpret the
# same argument, which is the failure the typed-result requirement exists to
# prevent -- and it would lose what the config-side resolver knows and the rule
# does not mention: a ZFS dataset name may legally contain a colon, so
# `.../pool/data:archive` is a real address that a naive `${tok%%:*}` split
# destroys (found on #132, and still guarded below).
#
# What was genuinely missing is the INTEGRITY half, and only that is added here:
# the config can only be as trustworthy as the records it was generated from, and
# nothing checked that the records still identify one relationship each.
#
# NOT SOURCED, deliberately. zfs-backup.sh sources these records as root by
# design, but this function's whole job is to decide whether they can be trusted;
# executing them to find out would be the wrong order. Two fields are read as
# text, and a name that is not a plain identifier is refused, not interpreted.
restore_relations_sane() {
    [ -d "$CLIENTS_DIR" ] || return 0        # no records here: nothing to contradict
    local f base name
    for f in "$CLIENTS_DIR"/*.conf; do
        # remove-client renames a tombstone to `<name>.conf.removed-<stamp>`, so
        # the glob already excludes them. An empty directory leaves the pattern
        # unexpanded, which `-e` catches.
        [ -e "$f" ] || continue
        base="${f##*/}"; base="${base%.conf}"
        # LAST wins: these records are append-only. zfs-backup.sh re-states a
        # field instead of rewriting the file, so the first CLIENT_NAME line is
        # the relationship as it was at creation, not as it is.
        name="$(sed -n 's/^CLIENT_NAME=//p' "$f" 2>/dev/null | tail -1)"
        [ -n "$name" ] || die "restore: relationship record $f carries no CLIENT_NAME -- refusing to plan against a record that cannot say what it is."
        case "$name" in
            *[!A-Za-z0-9._-]*)
                die "restore: relationship record $f has CLIENT_NAME='$name', which is not a plain identifier. Refusing rather than interpreting it." ;;
        esac
        # This one comparison is the whole guarantee. The reviewer asked for two
        # refusals -- a name/filename mismatch AND two records claiming one name
        # -- but the second cannot happen once the first holds: two files in one
        # directory cannot share a filename, so agreeing with the filename IS
        # uniqueness. A loop looking for duplicates would be unreachable code
        # wearing the costume of a safety check.
        [ "$name" = "$base" ] || die "restore: relationship record $f says CLIENT_NAME='$name' but is filed as '$base'. One of the two is wrong, and either answer would resolve a different relationship from the one the operator named. Fix the record or the filename before restoring."
    done
    return 0
}

# ------------------------------------------------------------------------------
# Phase 7 slice 1 -- `restore --plan`. READ-ONLY. Touches nothing but `zfs list`.
#
# The plan's own justification for shipping this alone: "dziś nikt nie wie, co by
# się odtworzyło" -- today nobody knows what would be restored. So this answers
# exactly that and stops: which dataset, which snapshots exist for it, when they
# were REALLY taken, and where a restore would land.
#
# "Really" is the load-bearing word. The timestamp shown is ZFS's own `creation`
# property, never the one embedded in the snapshot NAME. Those two can disagree --
# a renamed snapshot, a manually created one following the automated naming
# convention, a clock that was wrong when the name was built -- and a restore plan
# that reads the name is telling the operator a story rather than a fact. Where
# they disagree by more than a couple of minutes this says so out loud, because
# that disagreement is itself something the operator needs to know before choosing
# a recovery point.
#
# Backup locations are derived from the INSTALLED CONFIG, which is runtime truth
# here as everywhere else in this tool:
#   * local push  `[dataset:S]` + `dst = T`  -> the copy of S lives at T/S
#     (snapsend recreates the source path under the target, as slice 2's live
#     proof showed: hdd/backuptest/p5src -> hdd/backuptest/p5store/hdd/backuptest/p5src)
#   * remote pull `[dataset:L]` + `src = acct@host:R` -> L already IS the local copy
#
# No restore verb, no namespace creation, no ZFS write of any kind: those are
# slices 2 and 3 of Phase 7 and they are deliberately not started here.
restore_name_timestamp() {   # <snapshot name> -> epoch, or nothing
    # The convention every generated prefix uses: ..._YYYY-MM-DD_HH-MM-SS
    local n="$1" stamp
    stamp=$(printf '%s' "$n" | sed -n -E 's/.*_([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2}).*/\1 \2:\3:\4/p')
    [ -n "$stamp" ] || return 0
    date -d "$stamp" +%s 2>/dev/null || true
}

# Phase 7 slice 2 -- the SAFE restore. Writes to ZFS, and every guard below exists
# because of that.
#
# Failed-attempt semantics, agreed with the reviewer before this was written
# (peer-context R-005/C-007). No state machine, no marker, no lifecycle: the run
# owns exactly what it created.
#
#   1. the collision refusal runs FIRST, before anything is created, so a
#      pre-existing landing dataset is never touched and never adopted;
#   2. therefore a landing dataset present at the end of a failed attempt was
#      created by THIS run -- and this run destroys it, so a retry starts clean
#      instead of being stranded behind the refusal in (1);
#   3. cleanup destroys only what this run created. A dataset that existed before
#      the attempt is never a cleanup candidate, whatever the failure was;
#   4. if cleanup itself fails the run does not claim success, and names the exact
#      dataset the operator has to deal with.
#
# Acceptance is BOTH conditions, never one: the send/receive pipeline must succeed
# with its failure propagated, AND the restored snapshot's guid must equal the
# source's. A matching guid after a failed pipeline is not a restore, and a clean
# exit code with a different guid is not the data that was asked for.
cmd_restore_safe() {   # <dataset> <snapshot> <config> <yes>
    local want_ds="$1" snap="$2" config="$3" yes="$4"
    [ -n "$want_ds" ] || die "restore: --snapshot needs --dataset=<source or copy> so there is no doubt which relationship is being restored"

    read_server_conf
    [ -n "$config" ] || config="${CRON_CONFIG:-}"
    [ -n "$config" ] || die "restore: no cron config known -- pass --config=FILE or run setup-server"
    [ -r "$config" ] || die "restore: cannot read $config"

    # Same derivation as the planner, deliberately: one idea of where copies live.
    local ds d s src="" copy=""
    for ds in $(sed -n -E 's/^\[dataset:(.+)\]$/\1/p' "$config" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'); do
        d="$(installed_dataset_field "$config" "$ds" dst)"
        s="$(installed_dataset_field "$config" "$ds" src)"
        if [ -n "$d" ]; then
            if [ "$ds" = "$want_ds" ] || [ "${d}/${ds}" = "$want_ds" ]; then src="$ds"; copy="${d}/${ds}"; break; fi
        elif [ -n "$s" ]; then
            if [ "$ds" = "$want_ds" ] || [ "$s" = "$want_ds" ]; then src="${s#*:}"; copy="$ds"; break; fi
        fi
    done
    [ -n "$copy" ] || die "restore: '$want_ds' is not a source or a copy in $config -- run 'restore --plan' to see what is restorable"

    zfs list -H -o name -t snapshot -d 1 "$copy" 2>/dev/null | grep -qFx -- "${copy}@${snap}" \
        || die "restore: '${copy}@${snap}' does not exist. Run 'restore --plan --dataset=$want_ds' for the recovery points that actually exist."

    local landing; landing="$(restore_landing_path "$copy" "$src")"

    # (1) COLLISION FIRST. Nothing has been created at this point, so a refusal
    # here leaves the system exactly as it was found.
    if zfs list -H -o name "$landing" >/dev/null 2>&1; then
        die "restore: '$landing' already exists. Refusing -- this command never overwrites and never picks a different name for you, because a restore that quietly lands somewhere adjacent is a restore nobody looks at again. Inspect it, then remove or rename it and re-run."
    fi

    echo
    echo "Bezpieczne odtworzenie (do namespace restore -- produkcja NIE jest dotykana):"
    echo "  Kopia:      ${copy}@${snap}"
    echo "  Zrodlo:     $src   (oryginalna sciezka -- NIE jest celem)"
    echo "  Wyladuje w: $landing"
    echo
    if [ "$yes" -ne 1 ]; then
        local ans
        read -rp "Odtworzyc? [t/N] " ans
        case "$ans" in t|T|tak|TAK|y|Y|yes|YES) ;; *) die "not confirmed -- nothing was created" ;; esac
    fi

    local src_guid; src_guid="$(zfs get -H -o value guid "${copy}@${snap}" 2>/dev/null)"
    [ -n "$src_guid" ] && [ "$src_guid" != "-" ] \
        || die "restore: could not read the guid of '${copy}@${snap}' -- refusing to start a restore whose result could not be verified"

    # REV-20260812-114 F1. The previous shape inferred ownership from time: the
    # collision check ran first, therefore anything present later was ours. That
    # is a TOCTOU, and the consequence was destructive -- if another actor created
    # the landing path between the check and the receive, the failure path would
    # have run `zfs destroy -r` on a dataset this run never made. Temporal
    # ordering is not an ownership proof.
    #
    # Ownership is now a FACT, not an inference. The receive lands in a staging
    # dataset whose name is unique to this attempt; nothing else can plausibly own
    # that name, so destroying it is always provably safe. Only after the guid is
    # verified is it promoted to the predictable public path with `zfs rename`,
    # which fails if the destination exists -- so a concurrent collision fails
    # closed through ZFS's own atomicity rather than through a check we performed
    # earlier and hoped was still true.
    #
    # The early collision check above is kept, but it is now only an ergonomic
    # short-circuit: it saves transferring gigabytes into a doomed attempt. It
    # proves nothing and nothing depends on it.
    local ns_root="${landing%%/*}/restore"
    local staging="${ns_root}/restore-staging-$$-$(date +%s)-${RANDOM}"
    local failure=""

    # Ancestors are created and then DELIBERATELY NOT removed. The previous cut
    # destroyed the scaffolding it had built, to keep a retry clean -- but with
    # staging a retry is clean anyway, and ancestor removal is precisely the case
    # where ownership cannot be proven. An empty dataset inside the restore
    # namespace is harmless and strands nothing; destroying one somebody else just
    # created is not. The safer choice now costs nothing, so it wins.
    zfs create -p "${landing%/*}" || die "restore: could not create the restore namespace '${landing%/*}' -- nothing was received, nothing was left behind"

    if zfs list -H -o name "$staging" >/dev/null 2>&1; then
        die "restore: staging dataset '$staging' already exists, which should be impossible for a name unique to this attempt. Refusing rather than reusing it."
    fi

    if ! zfs send "${copy}@${snap}" | zfs recv -u "$staging"; then
        failure="the send/receive pipeline failed"
    fi

    if [ -z "$failure" ]; then
        local got_guid; got_guid="$(zfs get -H -o value guid "${staging}@${snap}" 2>/dev/null)"
        if [ -z "$got_guid" ] || [ "$got_guid" = "-" ]; then
            failure="the received snapshot has no readable guid"
        elif [ "$got_guid" != "$src_guid" ]; then
            failure="guid mismatch -- source $src_guid, received $got_guid; this is NOT the data that was asked for"
        fi
    fi

    # Promotion. `zfs rename` refuses an existing destination, so a landing path
    # that appeared while this attempt was running loses the race safely: we fail,
    # and the competing dataset is never touched, adopted, renamed around or
    # destroyed.
    if [ -z "$failure" ]; then
        if ! zfs rename "$staging" "$landing" 2>/dev/null; then
            failure="'$landing' appeared while this restore was running -- promotion refused. The other dataset was left exactly as it is"
        fi
    fi

    if [ -n "$failure" ]; then
        warn "restore FAILED: $failure"
        # The ONLY cleanup candidate is this attempt's own staging dataset. The
        # landing path is never a candidate, because after the race above we can
        # no longer prove we created it -- and that is the whole point of F1.
        case "$staging" in
            "$ns_root"/restore-staging-*) ;;
            *) die "restore: internal guard -- refusing to clean up '$staging', which is not this attempt's staging path under '$ns_root'." ;;
        esac
        if zfs list -H -o name "$staging" >/dev/null 2>&1; then
            if zfs destroy -r "$staging" 2>/dev/null; then
                die "restore failed ($failure). This attempt's staging dataset was removed; nothing else was touched, and re-running is clean."
            fi
            die "restore failed ($failure) AND this attempt's staging dataset could not be removed. '$staging' is still there and is NOT a valid restore -- remove it by hand. Nothing at '$landing' was touched."
        fi
        die "restore failed ($failure). Nothing was left behind."
    fi

    echo
    echo "Odtworzenie OK."
    echo "  Powstalo:   $landing"
    echo "  Snapshot:   ${landing}@${snap}"
    echo "  GUID:       $src_guid (zgodny ze zrodlem -- zweryfikowany, nie zalozony)"
    echo "  Produkcja:  nietknieta. Zastapienie zywego datasetu to osobny czasownik, ktorego jeszcze nie ma."
}

restore_landing_path() {   # <copy dataset> <original source> -> landing path
    # Derived, predictable, and deliberately NOT the original path: a safe restore
    # must never be able to overwrite production by default. It lands beside the
    # copy, under a fixed `restore` namespace, carrying the source path so an
    # operator can see at a glance what it is.
    # The FULL source path is kept, pool included. Stripping the pool collapsed
    # rpool/data and tank/data onto one landing path -- two different recoveries
    # racing for the same destination, and the second one refused for a reason
    # that would look like a bug. Caught by reading the derivation's output, not
    # by a test, which is why the suite now pins it.
    local copy="$1" src="$2"
    printf '%s/restore/%s\n' "${copy%%/*}" "$src"
}

# Phase 7 -- the DEFAULT recovery strategy, computed and shown, never executed here.
#
# The Owner's default recovery intent (OWNER-RECOVERY-DEFAULT-POLICY-2026-08-12) is
# "restore the LATEST valid backup recovery point back into the ORIGINAL source
# path", and the operator is explicitly not supposed to choose ZFS transport
# mechanics. Something therefore has to decide between incremental and full, and
# that decision has to be visible BEFORE anything destructive exists to run it --
# which is what this does. Read-only: `zfs list` only, no writes, no verb.
#
# The base is proven by GUID, never by name: policy step 2 says so, and the
# measured reason is the same one that governs consistency -- one snapsend run
# names every dataset from a single clock read, so equal names across datasets
# prove nothing about identity.
# Prints the strategy, and publishes it as facts for a caller that has to ACT on
# it rather than show it. The destructive verb reads these instead of re-deriving
# the same answer, so the preview an operator confirms and the decision the code
# takes cannot drift apart -- they are the same computation, run once.
RESTORE_STRATEGY=""      # remote | full-absent | full-live | increment | rollback | discard-live | unproven
RESTORE_BASE_GUID=""     # the GUID-proven common base, empty when there is none
RESTORE_TARGET_SNAP=""   # the recovery point: the backup's latest snapshot, bare name
RESTORE_TARGET_GUID=""
RESTORE_BLOCKERS=""      # source snapshots newer than the base, full names, one per line
RESTORE_BLOCK_BOOKMARKS="" # source BOOKMARKS newer than the base, full names, one per line
RESTORE_COPY_BASE_SNAP="" # the base snapshot on the COPY (full name), the increment's `from`
RESTORE_SRC_BASE_SNAP=""  # the base snapshot on the SOURCE (full name), the rollback target
RESTORE_SRC_BASE_TXG=""   # its createtxg -- the ONE order `zfs rollback` itself uses
RESTORE_SET_STATE=unproven # ok once the complete newer-than-base set is proven
restore_plan_strategy() {   # <copy dataset> <original source> <copy snapshot rows> [point label]
    local copy="$1" srcpath="$2" snaps="$3"
    # $4 exists because the heading below used to state a POLICY, and under --at
    # that policy is not the one in force. A preview that classifies the right
    # snapshot under a caption naming a different rule is still telling the
    # operator something untrue.
    local point_label="${4:-domyslna polityka: NAJNOWSZY -> oryginalna sciezka}"
    RESTORE_STRATEGY=""; RESTORE_BASE_GUID=""; RESTORE_TARGET_SNAP=""
    RESTORE_TARGET_GUID=""; RESTORE_BLOCKERS=""; RESTORE_BLOCK_BOOKMARKS=""
    RESTORE_COPY_BASE_SNAP=""; RESTORE_SRC_BASE_SNAP=""; RESTORE_SRC_BASE_TXG=""
    RESTORE_SET_STATE=unproven

    # A pull relationship's original source lives on another host. Determining its
    # strategy needs that host, which is an SSH read this read-only slice does not
    # take. Say so rather than implying the local answer applies.
    case "$srcpath" in
        *:*) echo "  Strategia:  (zrodlo '$srcpath' jest ZDALNE -- ustalenie strategii wymaga odpytania tamtego hosta; ten wycinek tego nie robi)"
             RESTORE_STRATEGY=remote
             return 0 ;;
    esac

    # REV-121: the DEFAULT recovery point is the newest capture time, and "newest"
    # has to be a fact rather than a list position.
    #
    # `creation` stays the axis on purpose. It is the operator-meaningful thing --
    # when this data was captured -- and the owner's policy is written in those
    # terms. `createtxg` is not a substitute: on a backup copy every snapshot
    # arrived by receive, so local transaction order is ARRIVAL order, and silently
    # switching to it would change the policy from "latest capture" to "last
    # delivered" without anyone deciding that.
    #
    # What changes is what happens when the axis does not decide. `creation` has
    # one-second resolution and this project has now measured duplicates on real
    # hosts, so `tail -1` over that ordering answers "which equal row did ZFS print
    # last", which is not an administrator's intent. When the maximum is shared,
    # the verb refuses and names the candidates instead of picking one -- the same
    # fail-closed direction the rest of this path takes: where the program cannot
    # derive the intent, it must not invent one.
    local maxc tied ntied latest latest_guid
    maxc="$(printf '%s\n' "$snaps" | awk -F'\t' 'NF>=3 && $2 ~ /^[0-9]+$/ {if(($2+0)>(m+0)) m=$2} END{print m+0}')"
    tied="$(printf '%s\n' "$snaps" | awk -F'\t' -v m="$maxc" 'NF>=3 && $2 ~ /^[0-9]+$/ && ($2+0)==(m+0){print $1"\t"$3}')"
    ntied="$(printf '%s\n' "$tied" | grep -c .)"
    if [ "$ntied" -ne 1 ]; then
        RESTORE_STRATEGY=ambiguous
        echo "  Punkt docelowy: NIEJEDNOZNACZNY -- nie wybieram."
        if [ "$ntied" -eq 0 ]; then
            echo "    Zaden snapshot kopii '$copy' nie ma czytelnego czasu powstania, wiec nie ma"
            echo "    z czego wyznaczyc najnowszego punktu."
        else
            echo "    $ntied snapshotow kopii dzieli ten sam czas powstania (creation=$maxc):"
            printf '%s\n' "$tied" | while IFS="$(printf '\t')" read -r tn tg; do
                [ -n "$tn" ] && echo "      ${tn#*@}  guid=$tg"
            done
            echo "    'creation' ma rozdzielczosc jednej sekundy, wiec ktory z nich jest"
            echo "    NAJNOWSZY nie wynika z niczego poza przypadkowa kolejnoscia listy. Wybor"
            echo "    zgadniety tutaj wyznaczylby punkt, do ktorego cofnieto by zrodlo, wiec nie"
            echo "    jest zgadywany. Rozstrzygnij po stronie kopii albo wskaz punkt jawnie."
        fi
        return 0
    fi
    latest="${tied%%	*}"
    latest_guid="${tied##*	}"
    RESTORE_TARGET_SNAP="${latest#*@}"; RESTORE_TARGET_GUID="$latest_guid"
    echo "  Punkt docelowy ($point_label):"
    echo "    ${latest#*@}  guid=$latest_guid"

    if ! zfs list -H -o name "$srcpath" >/dev/null 2>&1; then
        RESTORE_STRATEGY=full-absent
        echo "  Strategia:  FULL -- zrodlo '$srcpath' nie istnieje, wiec nie ma czego niszczyc"
        echo "              ani z czym robic przyrostu. Odtworzenie stworzy je od zera."
        return 0
    fi

    # The common base is the NEWEST backup snapshot whose guid also exists on the
    # source. Everything on the source newer than it is what blocks an incremental
    # receive -- and is exactly what the destructive step would have to remove.
    local srcguids base_snap="" base_guid="" sguid
    srcguids="$(zfs list -H -p -t snapshot -o guid -d 1 "$srcpath" 2>/dev/null)"
    local sname screat sg
    while IFS=$'\t' read -r sname screat sg; do
        [ -n "$sg" ] || continue
        printf '%s\n' "$srcguids" | grep -qxF -- "$sg" && { base_snap="$sname"; base_guid="$sg"; }
    done <<< "$snaps"

    if [ -z "$base_guid" ]; then
        RESTORE_STRATEGY=full-live
        echo "  Strategia:  FULL na ISTNIEJACE zrodlo -- zaden snapshot kopii nie ma guida"
        echo "              obecnego na '$srcpath'. Wspolnej bazy NIE MA, wiec przyrost jest"
        echo "              niemozliwy, a pelne odtworzenie zastapiloby zywe zrodlo. To jest"
        echo "              operacja niszczaca i nalezy do osobnego czasownika, ktorego nie ma."
        return 0
    fi

    RESTORE_BASE_GUID="$base_guid"
    # The destructive step must ACT on this base, not re-derive it. Publish both
    # sides as facts: the COPY's base snapshot is the increment's `from`; the
    # SOURCE's base snapshot (found by the SAME guid, never by name) is the
    # rollback target. Resolving them here rather than in the executor is what
    # keeps the loss set the operator confirmed and the command the code runs the
    # one same computation.
    RESTORE_COPY_BASE_SNAP="$base_snap"
    # REV-120 F2: the base is resolved by guid, and its `createtxg` comes back with
    # it. Everything downstream -- the loss set, the pre-destruction revalidation and
    # the final acceptance test -- is anchored on that number rather than on position
    # in a list sorted by `creation`. Two snapshots of one dataset cannot share a
    # createtxg (ZFS refuses to make two in one transaction group), while `creation`
    # is a wall-clock second that the project has repeatedly measured as duplicated.
    # It is also the exact order `zfs rollback` uses internally to decide what it
    # destroys, so the set this code approves and the set ZFS acts on are computed
    # from the same fact.
    #
    # Exactly one row may carry the base guid. Zero means the base vanished between
    # two reads; more than one is impossible on a healthy pool -- either way the
    # answer is "unproven", never "pick the first".
    local srcbase
    srcbase="$(zfs list -H -p -t snapshot -o name,guid,createtxg -d 1 "$srcpath" 2>/dev/null \
               | awk -F'\t' -v g="$base_guid" '$2==g{print $1"\t"$3}')"
    if [ "$(printf '%s\n' "$srcbase" | grep -c .)" -eq 1 ]; then
        RESTORE_SRC_BASE_SNAP="${srcbase%%	*}"
        RESTORE_SRC_BASE_TXG="${srcbase##*	}"
    fi
    echo "  Wspolna baza (dowiedziona GUID-em, nie nazwa):"
    echo "    ${base_snap#*@}  guid=$base_guid"

    # What stands in the way, named precisely. Two different kinds of source-side
    # state can be destroyed by a recovery, and the preview has to know both before
    # it picks a verdict:
    #
    #   1. snapshots newer than the common base -- a set, named individually below;
    #   2. writes made after the source's newest snapshot, which live in no snapshot
    #      at all and are therefore invisible to (1).
    #
    # This is computed BEFORE deciding the strategy, and the live lab is why. An
    # earlier cut checked base==latest first and reported "nothing to do" for a
    # source carrying two snapshots NEWER than the backup's latest point. That was
    # wrong: the requested end state is the source AT that point, and a source that
    # has moved past it is not in that state. No data needs transferring, but the
    # source still has to be rolled back -- which is destructive, and calling it
    # "nothing to do" would have hidden exactly the destruction the operator must
    # approve.
    # REV-120 F1/F2: the set is derived by createtxg comparison, and it covers
    # BOOKMARKS as well as snapshots.
    #
    # Two defects lived in the previous derivation, and both are the same mistake
    # made about different objects:
    #
    #   * it walked a list sorted by `creation` and took everything positioned after
    #     the base. Equal creation seconds are real here, so a genuinely newer
    #     snapshot could sort BEFORE the base and never enter the loss set -- while
    #     `zfs rollback -r`, which compares createtxg, would destroy it anyway.
    #   * it never looked at bookmarks at all. `zfs rollback -r` destroys newer
    #     bookmarks too: its check and its destroy pass both iterate snapshots AND
    #     bookmarks. Measured on pve0 (zfs-2.1.9): rolling back to @s1 with #bm1/#bm2/
    #     #bm3 present left only #bm1, the one whose createtxg equals the base's.
    #     A bookmark holds no bytes, so its loss never showed up in the byte total --
    #     but it is the anchor for a future incremental send, and destroying one under
    #     an approval that never mentioned it is exactly the widening REV-119's
    #     confirmation boundary exists to forbid.
    #
    # A listing that fails leaves the set UNPROVEN rather than empty. "I could not
    # read it" and "there is nothing there" are the same value in a shell variable
    # and opposite facts to an operator about to destroy data.
    local blockers="" bookmarks="" setstate=ok snaprows bmrows
    if [ -n "$RESTORE_SRC_BASE_TXG" ]; then
        snaprows="$(zfs list -H -p -t snapshot -o name,createtxg -d 1 "$srcpath" 2>/dev/null)" || setstate=unproven
        bmrows="$(zfs list -H -p -t bookmark -o name,createtxg -d 1 "$srcpath" 2>/dev/null)"  || setstate=unproven
        blockers="$(printf '%s\n' "$snaprows" | awk -F'\t' -v t="$RESTORE_SRC_BASE_TXG" 'NF>=2 && ($2+0)>(t+0){print $1}')"
        bookmarks="$(printf '%s\n' "$bmrows"  | awk -F'\t' -v t="$RESTORE_SRC_BASE_TXG" 'NF>=2 && ($2+0)>(t+0){print $1}')"
    else
        setstate=unproven
    fi
    RESTORE_BLOCKERS="$blockers"
    RESTORE_BLOCK_BOOKMARKS="$bookmarks"
    RESTORE_SET_STATE="$setstate"

    # Kind (2): live, unsnapshotted state. `written` is ZFS's own accounting of the
    # space written to the dataset since its most recent snapshot, so this is a
    # native ZFS fact and not a second state authority invented here. A source can
    # sit exactly on the common base, carry no newer snapshot whatsoever, and still
    # hold writes that a destructive recovery would discard; the snapshot set above
    # cannot see them.
    #
    # Measured limitation, pve1 / zfs-2.1.9: `written` reflects the last COMMITTED
    # txg. 4 MiB written to a lab dataset still read written=0 -- through a
    # sync(1) -- until the txg landed (that pool commits roughly once a minute, not
    # the 5s default). Forcing a commit to close the window was rejected: `zpool
    # sync` is a pool-wide write and this verb advertises itself as read-only.
    #
    # REV-118 F1 residual draws the consequence I had stopped one step short of:
    # if written=0 can be stale, then written=0 PROVES NOTHING about the current
    # state, and a no-op verdict resting on it is a guess wearing a fact's clothes.
    # So there are only two honest classes here -- proven dirty, and unproven --
    # and both an accounted-zero and a failed read fall in the second. The verb
    # therefore has no no-op answer at all: it can say "nothing is accounted", never
    # "nothing is there". Closing the gap needs a fact this read cannot supply
    # (the pool's open-txg dirty accounting via kstat would, at the cost of a
    # Linux/OpenZFS-specific assumption); until one is chosen, conservative is the
    # only defensible direction.
    local live_written live_state
    live_written="$(zfs get -Hp -o value written "$srcpath" 2>/dev/null)"
    case "$live_written" in
        ''|*[!0-9]*) live_state=unreadable  ;;
        0)           live_state=unaccounted ;;
        *)           live_state=dirty       ;;
    esac

    if [ "$base_guid" = "$latest_guid" ]; then
        if [ -z "$blockers" ] && [ "$live_state" = dirty ]; then
            RESTORE_STRATEGY=discard-live
            echo "  Strategia:  ODRZUCENIE ZYWYCH ZMIAN, bez transferu -- zrodlo stoi na zadanym"
            echo "              punkcie i nie ma nowszych snapshotow, ale po nim zapisano dane."
            echo "              Powrot do zadanego stanu oznacza ich utrate. Nic sie nie przesyla."
        elif [ -z "$blockers" ]; then
            RESTORE_STRATEGY=unproven
            echo "  Strategia:  STAN ZRODLA NIEDOWIEDZIONY, traktowany jako potencjalnie NISZCZACY"
            echo "              -- zrodlo stoi na zadanym punkcie i nie ma nowszych snapshotow, ale"
            echo "              biezacego stanu zywego nie da sie tu dowiesc (szczegol nizej)."
            echo "              'Nic do zrobienia' byloby odpowiedzia na wiare, wiec jej nie ma."
        else
            RESTORE_STRATEGY=rollback
            echo "  Strategia:  SAM ROLLBACK, bez transferu -- zrodlo MA juz najnowszy punkt kopii,"
            echo "              ale przeszlo poza niego. Zeby wrocic do zadanego stanu, ponizsze"
            echo "              snapshoty zrodla musza zniknac. Nic sie nie przesyla."
        fi
    else
        RESTORE_STRATEGY=increment
        echo "  Strategia:  INKREMENT od wspolnej bazy do najnowszego punktu."
    fi

    if [ -n "$blockers" ]; then
        echo "  BLOKUJE / DO USUNIECIA (snapshoty zrodla NOWSZE niz wspolna baza):"
        printf '%s\n' "$blockers" | sed 's/.*@/    /'
    fi
    if [ -n "$bookmarks" ]; then
        echo "  BLOKUJE / DO USUNIECIA (BOOKMARKI zrodla NOWSZE niz wspolna baza):"
        printf '%s\n' "$bookmarks" | sed 's/.*#/    /'
        echo "  Bookmark nie zajmuje miejsca, wiec nie widac go w bajtach -- ale jest NOWSZY niz"
        echo "  punkt docelowy, wiec odtworzenie musi go usunac (dopoki istnieje, ZFS odmawia"
        echo "  cofniecia zrodla). Bookmark jest punktem zaczepienia przyszlego wysylania"
        echo "  przyrostowego, wiec jego strata jest nieodwracalna tak samo jak strata snapshota."
    fi
    if [ -n "$blockers" ] || [ -n "$bookmarks" ]; then
        echo "  To jest operacja NISZCZACA dla powyzszych obiektow zrodla i wymaga jawnego"
        echo "  potwierdzenia. Czasownik, ktory ja wykonuje, jeszcze nie istnieje."
    fi
    if [ "$setstate" != ok ]; then
        echo "  ZBIOR STRAT NIEDOWIEDZIONY: nie udalo sie ustalic pelnej listy snapshotow i"
        echo "  bookmarkow zrodla nowszych niz wspolna baza. Powyzsza lista moze byc NIEPELNA;"
        echo "  operacja niszczaca na tym stanie jest niedopuszczalna."
    fi

    case "$live_state" in
        dirty)
            echo "  ZYWE ZMIANY PO OSTATNIM SNAPSHOCIE ZRODLA: ZFS rozlicza written=$live_written B"
            echo "  zapisanych na '$srcpath' po jego najnowszym snapshocie. Tych danych NIE MA w"
            echo "  zadnym snapshocie, wiec nie da sie ich odzyskac po fakcie -- odtworzenie"
            echo "  niszczace je ODRZUCI. Ten stan sam w sobie czyni operacje niszczaca, nawet"
            echo "  gdyby zaden snapshot nie blokowal." ;;
        unreadable)
            echo "  STAN ZYWY NIEDOWIEDZIONY: odczyt wlasciwosci 'written' dla '$srcpath' nie dal"
            echo "  liczby. NIE twierdze, ze nic nie blokuje -- traktuj operacje jako niszczaca"
            echo "  do czasu, az stan zywy zostanie potwierdzony." ;;
        unaccounted)
            echo "  STAN ZYWY NIEDOWIEDZIONY: ZFS nie rozlicza zadnych zmian zapisanych po"
            echo "  ostatnim snapshocie zrodla (written=0)."
            echo "  To NIE jest dowod stanu biezacego: 'written' pokazuje ostatni ZATWIERDZONY"
            echo "  txg. Zmierzone (pve1, zfs-2.1.9): 4 MiB zapisane i przepuszczone przez"
            echo "  sync(1) dalej pokazywaly written=0, az do commitu txg -- na tej puli okolo"
            echo "  minuty pozniej. Zapis sprzed chwili jest wiec dla tego odczytu niewidoczny."
            echo "  Przed operacja niszczaca potwierdz, ze zrodlo jest bezczynne." ;;
    esac
}

# Every backup relationship the installed CONFIG describes, one per line:
#
#   <original source> <TAB> <copy location> <TAB> <kind> <TAB> <consistency>
#
# One authority, because there are now two callers. `--plan` builds its table from
# this and the destructive path resolves a single dataset through it; a second copy of the
# derivation would be a second idea of where a backup lives, and the destructive
# verb is the last place that should disagree with the preview.
restore_relations() {   # <config>
    local config="$1" ds d s rec
    for ds in $(sed -n -E 's/^\[dataset:(.+)\]$/\1/p' "$config" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'); do
        d="$(installed_dataset_field "$config" "$ds" dst)"
        s="$(installed_dataset_field "$config" "$ds" src)"
        # Consistency comes from the installed CONFIG and from nothing else. The
        # recovery contract forbids inferring it from snapshot names, prefixes,
        # hierarchy shape or close creation times, and the reason is measured: on
        # pve2 two datasets in different subtrees share the name
        # automated_hourly_2026-08-11_23-37-01 while their creation times differ by
        # a second. They were never one atomic event. A planner that read names
        # would have announced a recovery point that never existed.
        rec="$(installed_dataset_field "$config" "$ds" recursive)"
        rec="$(printf '%s' "$rec" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        [ "$rec" = atomic ] && rec=atomic || rec=independent
        if [ -n "$d" ]; then
            printf '%s\t%s\t%s\t%s\n' "$ds" "${d}/${ds}" "local push -> $d" "$rec"
        elif [ -n "$s" ]; then
            printf '%s\t%s\t%s\t%s\n' "$s" "$ds" "remote pull <- $s" "$rec"
        fi
    done
}

# The technical snapshots this path takes are removed on EVERY exit, including
# every refusal. Destroying them is provably safe in the sense REV-114 settled for
# the staging dataset: they carry a name unique to this run, and this run created
# them seconds earlier -- so ownership is a fact here rather than an inference
# from ordering. A failure to remove one is reported and never silently swallowed;
# a leftover snapshot on a production source is somebody's confusing evening.
# The write fence (REV-119, second round).
#
# The commit-boundary snapshot proves nothing ARRIVED up to the moment it was
# taken. It says nothing about the window between that check and the destructive
# step, and a write landing there would be destroyed under an approval that never
# covered it. Closing that window needs the source to be incapable of accepting
# writes, not merely observed not to have taken any.
#
# `readonly=on` is the ZFS mechanism for exactly that: the dataset rejects writes
# while it is set, for filesystems and ZVOLs alike, and it does NOT block the
# snapshot, rollback or receive this path needs -- those are not userland writes.
#
# It is a property change on a production dataset, so it is captured and restored
# precisely: a value that was inherited goes back to inherited, not to a local
# copy that happens to have the same value today.
# REV-119 F1.2: capture is SEPARATE from mutation, and comes first. The previous
# shape read the old state and changed the property inside one function, so a
# verification that came back unreadable left the caller holding a failure and no
# idea what to put back -- and a production source stuck read-only. Nothing may
# touch the property until the caller is holding what it takes to undo it.
# ---------------------------------------------------------------------------
# THE PUBLIC ADDRESS RESOLVER (owner grammar of 2026-08-13, R-025 constraints).
#
#   restore pve2                  whole relation
#   restore pve2:rpool/data       one dataset of that relation
#   restore hdd/backups/...       a managed copy/source path, verbatim
#
# The rule that disarms the dangerous ambiguity: A NAME THAT DOES NOT RESOLVE
# IS AN ERROR, NEVER A GUESS. No fallback from unknown relation to hostname, no
# DNS, no ssh probe -- the failure mode of guessing is a destructive recovery
# aimed at the wrong machine. R-025 sharpened three edges, all enforced here:
#   1. user@HOST:DATASET is refused outright -- transport and account mechanics
#      do not belong on the public surface;
#   2. a bare word is ONLY a relation label (pair_label in the installed
#      CONFIG). It is never treated as a hostname;
#   3. a POOL/PATH must be a source or copy the installed CONFIG already knows.
#      An arbitrary local dataset is never adopted as backup provenance.
#
# Output: one "src<TAB>copy" line per selected dataset. Every refusal is die,
# with the reason and the safe next step named.
# The installed CONFIG, found the way the rest of the tooling names it.
#
# read_server_conf can only learn CRON_CONFIG from server.conf, and server.conf
# is vestigial -- measured absent on every live host -- so on a real machine the
# public spelling died with "no readable installed config" the first time it was
# driven (pve9, 2026-08-23) while /etc/zfs-snapshot-all/jobs.pve9.conf sat right
# there. Falling back to that path is NOT guessing in the R-025 sense: it is a
# deterministic LOCAL file naming convention every other part of this tooling
# writes and reads, not a network address inferred from a name. If the file is
# not there either, the refusal still says exactly what to pass.
# THE CONFIG BELONGS TO AN ACCOUNT, NOT ONLY TO A HOST.
#
# This returned `jobs.<host>.conf` and nothing else, which is root's historical
# name. Since the fleet moved to delegated accounts (2026-08-01) the installed
# file is `jobs.<host>.<account>.conf` -- zfs-backup.sh's default_cron_config
# has said so since LAB6-F2, and this was a second, older implementation of the
# same rule that never learned it.
#
# Measured on the lab, 2026-08-27: `restore lab1 --plan` on pve9 refused with
# "tried [...] /etc/zfs-snapshot-all/jobs.pve9.conf" while
# /etc/zfs-snapshot-all/jobs.pve9.zfsbackup.conf sat in the same directory. The
# public restore surface was unusable on every host in this estate.
#
# Candidates, most specific first, one per line. The accounts come from OUR OWN
# records -- the peer manifests and client records this host wrote -- never from
# /home or passwd: an account exists for reasons unrelated to this project, and
# treating one as ours because it has a home directory is a local fact standing
# in for a decision (the reasoning cron_known_accounts already carries).
restore_config_candidates() {
    local h; h=$(hostname -s 2>/dev/null || hostname)
    local f u
    {
        printf '%s
' "/etc/zfs-snapshot-all/jobs.${h}.conf"
        for f in /etc/zfs-snapshot-all/peers/*.conf; do
            [ -r "$f" ] || continue
            u=$( . "$f" >/dev/null 2>&1; printf '%s' "${PEER_SAVED_LOCAL_USER:-}" )
            [ -n "$u" ] && [ "$u" != root ] && printf '%s
' "/etc/zfs-snapshot-all/jobs.${h}.${u}.conf"
        done
        for f in "$CLIENTS_DIR"/*.conf; do
            [ -r "$f" ] || continue
            u=$( . "$f" >/dev/null 2>&1; printf '%s' "${LOCAL_USER:-}" )
            [ -n "$u" ] && [ "$u" != root ] && printf '%s
' "/etc/zfs-snapshot-all/jobs.${h}.${u}.conf"
        done
    } 2>/dev/null | awk 'NF && !seen[$0]++'
}

# Kept as the name the refusals quote: the historical, host-only spelling.
restore_default_config() {
    local h; h=$(hostname -s 2>/dev/null || hostname)
    printf '%s' "/etc/zfs-snapshot-all/jobs.${h}.conf"
}

restore_resolve_token() {   # <config> <token>
    local config="$1" tok="$2"
    case "$tok" in
        *@*)
            die "restore: '$tok' looks like user@host:dataset -- transport addressing is not part of the public restore surface (R-025). Address the backup by its relation: 'restore <label>' or 'restore <label>:<dataset>'; labels come from 'restore --plan'." ;;
    esac
    # ZFS dataset names legally contain ':' (pc_is_dataset accepts it), so a
    # token with a colon is AMBIGUOUS between label:dataset and a verbatim
    # managed path -- the reviewer's discriminator on #132: a legal copy
    # location `.../pool/data:archive` was split at the first colon and refused
    # while sitting right there in CONFIG. The rule stays "never guess":
    #   1. an EXACT verbatim match against the managed locations wins -- it is
    #      deterministic and local;
    #   2. otherwise the label:dataset reading applies;
    #   3. if BOTH readings resolve, that is a genuine ambiguity and it
    #      REFUSES, naming the two readings -- a guess here aims a recovery.
    local label="" want=""
    case "$tok" in
        *:*)
            if restore_resolve_try "$config" "" "$tok" >/dev/null; then
                if restore_resolve_try "$config" "${tok%%:*}" "${tok#*:}" >/dev/null; then
                    die "restore: '$tok' is ambiguous -- it matches a managed location verbatim AND parses as relation '${tok%%:*}' + dataset '${tok#*:}', which also resolves. Refusing to choose: use 'restore --plan' to see both and address the one you mean unambiguously."
                fi
                restore_resolve_try "$config" "" "$tok"
                return 0
            fi
            label="${tok%%:*}"; want="${tok#*:}" ;;
        */*) want="$tok" ;;
        *)   label="$tok" ;;
    esac
    restore_resolve_try "$config" "$label" "$want" && return 0
    restore_resolve_fail "$config" "$label" "$want"
}

# The matching core, shared by both readings. Prints "src<TAB>copy" per hit;
# returns 1 (silently) when nothing matches -- the CALLER owns the refusal
# wording, because which reading failed decides what the operator is told.
# $4 is the NAMESPACE, and it is what `--source`/`--target` buy over the loose
# positional form. Empty (every existing caller) keeps the old behaviour: a token
# may match either side, which is right when the operator did not say which side
# they meant. `copy` matches only the collector-side location, `orig` only the
# name on the machine being restored. Saying which side you mean is the whole
# point of naming the flag, so the flags must not fall back to "either".
restore_resolve_try() {   # <config> <label> <want> [namespace: ""|copy|orig]
    local config="$1" label="$2" want="$3" ns="${4:-}"
    local ds l s d hit=1
    for ds in $(sed -n -E 's/^\[dataset:(.+)\]$/\1/p' "$config"); do
        s="$(installed_dataset_field "$config" "$ds" src)"
        d="$(installed_dataset_field "$config" "$ds" dst)"
        l="$(installed_dataset_field "$config" "$ds" pair_label)"
        local src_id copy_loc
        if [ -n "$d" ]; then src_id="$ds"; copy_loc="${d}/${ds}"
        elif [ -n "$s" ]; then src_id="$s"; copy_loc="$ds"
        else continue; fi
        # src may carry acct@host: transport. It is stripped for MATCHING the
        # user's token (nobody addresses a backup by its transport), but the
        # value PRINTED is the recorded one -- that is what the plan filter and
        # cmd_restore_safe compare against: internal plumbing handed to internal
        # calls, never an address accepted from the user. The first cut printed
        # the stripped form and the very first end-to-end run of `restore pve2`
        # matched nothing -- the resolver and the plan disagreed about identity
        # spelling. One spelling, the recorded one, everywhere.
        local src_plain="${src_id#*@}"; src_plain="${src_plain#*:}"
        if [ -n "$label" ] && [ "$l" != "$label" ]; then continue; fi
        if [ -n "$want" ]; then
            # A DESCENDANT OF A RECURSIVE RELATIONSHIP IS A MEMBER OF IT.
            #
            # The config records one section per relationship, and a recursive
            # one covers a whole subtree under a single recorded name. Matching
            # only the recorded string meant `--target` could name the parent
            # and nothing else -- so on this estate, where a relationship is a
            # VM's disks under one parent, the flag that exists to scope a
            # recovery to some of them could not name any of them.
            #
            # Measured on the lab, 2026-08-27:
            #   restore lab1 --target hdd/labsrc/vm-900-disk-0
            #   FATAL: 'hdd/labsrc/vm-900-disk-0' is not a dataset of relation
            #          'lab1'
            # ...pointing at `restore --plan`, which lists the parent only, so
            # the advice named a list that could not contain the answer. And the
            # case it locked out is the ordinary one: one disk of a VM is
            # damaged, the other has hours of good writes on it, and restoring
            # the whole relation rolls both back.
            #
            # A DERIVATION, not a guess (R-025's line). Both sides of a
            # recursive relationship carry the same subtree shape, so the
            # child's copy location is the recorded copy plus the same relative
            # path -- arithmetic on two recorded facts, no probing, no
            # inference. Fenced to sections whose own `recursive` field says the
            # subtree is covered: for a non-recursive one the child genuinely is
            # not a member, and it still matches only what it records.
            local _rel="" _matched=0
            case "$ns" in
                copy) [ "$copy_loc" = "$want" ] && _matched=1 ;;
                orig) { [ "$src_plain" = "$want" ] || [ "$src_id" = "$want" ]; } && _matched=1 ;;
                *)    { [ "$src_plain" = "$want" ] || [ "$src_id" = "$want" ] || [ "$copy_loc" = "$want" ] || [ "$ds" = "$want" ]; } && _matched=1 ;;
            esac
            if [ "$_matched" -eq 0 ]; then
                local _recur; _recur="$(installed_dataset_field "$config" "$ds" recursive)"
                case "$_recur" in
                    yes|flat|1|true)
                        case "$ns" in
                            copy) [ "${want#"$copy_loc"/}"  != "$want" ] && _rel="${want#"$copy_loc"/}" ;;
                            orig) [ "${want#"$src_plain"/}" != "$want" ] && _rel="${want#"$src_plain"/}" ;;
                            *)    if   [ "${want#"$src_plain"/}" != "$want" ]; then _rel="${want#"$src_plain"/}"
                                  elif [ "${want#"$copy_loc"/}"  != "$want" ]; then _rel="${want#"$copy_loc"/}"
                                  fi ;;
                        esac ;;
                esac
                [ -n "$_rel" ] || continue
                # The copy has to be there. A descendant that was never captured
                # is a typo, or a dataset created after the last backup, and both
                # deserve "this relation does not cover it" rather than a plan
                # that reaches the transfer before finding there is nothing to
                # send. Asked only when the copy is LOCAL: a remote one would put
                # an ssh round trip inside a resolver that has to stay a pure
                # function of the config, and the per-dataset step already
                # refuses on a copy with no snapshot.
                case "$copy_loc" in
                    *@*|*:*) : ;;
                    *) zfs list -H -o name "${copy_loc}/${_rel}" >/dev/null 2>&1 || continue ;;
                esac
                src_id="${src_id}/${_rel}"
                copy_loc="${copy_loc}/${_rel}"
            fi
        fi
        printf '%s\t%s\n' "$src_id" "$copy_loc"
        hit=0
    done
    return "$hit"
}

restore_resolve_fail() {   # <config> <label> <want> -> always dies
    local config="$1" label="$2" want="$3"
    if [ -n "$label" ] && [ -n "$want" ]; then
        die "restore: relation '$label' does not cover dataset '$want' in $config. 'restore --plan' lists what it does cover. A name that does not resolve is an error, never a guess."
    elif [ -n "$label" ]; then
        die "restore: '$label' is not a relation label in $config (no [dataset:] section carries pair_label = $label). It is NOT treated as a hostname, deliberately -- guessing is how a recovery aims at the wrong machine. 'restore --plan' lists the labels."
    else
        die "restore: '$want' is neither a source nor a managed copy location in $config. An arbitrary dataset is never adopted as backup provenance (R-025). 'restore --plan' lists the managed locations."
    fi
}

# ------------------------------------------------------------------------------
# WHICH DATASETS OF THE RELATIONSHIP
# ------------------------------------------------------------------------------
# Owner decision, 2026-08-26 (docs/project/OWNER-RESTORE-SCOPE-2026-08-26.md):
#
#     restore RELATION                       the whole relationship
#     restore RELATION --target a,b,c        those datasets, named on this host
#     restore RELATION --source x,y,z        those datasets, named on the collector
#
# A VM with four virtual disks is four datasets and is ONE object to whoever is
# recovering it: four commands would mean four previews, four destructive
# confirmations, and a window in which the machine is half restored.
#
# THE COMMA IS SAFE BY MEASUREMENT, not by convention. ZFS refuses it in a
# dataset name outright (pve9, 2026-08-26):
#
#     cannot create 'hdd/przecinek,test': invalid character ',' in name
#
# so a comma can never occur inside a member and splitting on it cannot destroy a
# legal name. That is precisely the property `:` lacks -- a colon IS legal inside
# a dataset name, which is what made `pve2:rpool/data` ambiguous.
#
# THE NAMESPACES ARE NOT MIXED WITHIN A LIST. Each list is resolved in its own,
# so the mistake this removes -- two of a VM's disks named on the collector and
# two on the host, in one list, with a plan that still looks complete -- cannot
# be written. Naming BOTH lists is allowed and is something else entirely: the
# operator stating explicitly what the two sides already are, checked pair by
# pair against the record.
#
# And the whole list resolves BEFORE anything is shown, let alone done. A plan
# that is right about three disks and silent about the fourth is not a plan.
RESTORE_SCOPE_NS=""        # copy | orig | "" when the whole relationship is meant
declare -a RESTORE_SCOPE_SRC=() RESTORE_SCOPE_COPY=()

# Which installed config a restore reads. Extracted because the scope path below
# needs the same answer as the address path, and two copies of "try --config,
# then $CRON_CONFIG, then the default" would be two ways to read a different file
# from the one the preview described.
restore_pick_config() {   # <explicit --config or ""> <what for> -> prints the path
    # TWO statements. `local want="$1" c="$want"` leaves c EMPTY -- bash expands
    # every word on the line before the builtin assigns any of them. Written
    # about in this project on 2026-08-20 (pool_health's cache key), again this
    # morning (quiesce_parse_mode rejecting the bare `auto`), and again here.
    # It always fails in the safe-looking direction, which is why it survives
    # reading and only dies to a positive control.
    local want="$1" what="$2" c
    c="$want"
    [ -n "$c" ] || c="${CRON_CONFIG:-}"
    if [ -z "$c" ]; then
        local -a found=()
        local cand
        while IFS= read -r cand; do
            [ -r "$cand" ] && found+=("$cand")
        done < <(restore_config_candidates)
        # More than one is a QUESTION, not a default. Two accounts on one host
        # each carry their own relationships, and picking for the operator would
        # aim a recovery using the other one's records. Refuse and name them.
        if [ "${#found[@]}" -gt 1 ]; then
            die "restore: this host has more than one installed config and nothing in this command says which:
$(printf '    %s
' "${found[@]}")Each belongs to a different account and carries different relationships, so choosing for you could aim a recovery by the wrong records. Name it: --config=<path>. Nothing was read and nothing was changed."
        fi
        [ "${#found[@]}" -eq 1 ] && c="${found[0]}"
    fi
    [ -n "$c" ] && [ -r "$c" ] || die "restore: no readable installed config to resolve $what against -- tried \$CRON_CONFIG and these, none readable:
$(restore_config_candidates | sed 's/^/    /')Pass --config=FILE."
    printf '%s' "$c"
}

restore_scope_resolve() {   # <config> <label> <namespace> <comma list>
    local config="$1" label="$2" ns="$3" list="$4"
    RESTORE_SCOPE_SRC=(); RESTORE_SCOPE_COPY=(); RESTORE_SCOPE_NS="$ns"
    [ -n "$list" ] || return 0

    local rest="$list" member hits n src copy i
    local -a seen_in=()
    # Split on commas WITHOUT `read -a`/IFS games: a member is everything up to
    # the next comma, and the loop ends when there is no comma left. Nothing here
    # can be tripped by whitespace, because a ZFS name cannot contain any.
    while [ -n "$rest" ]; do
        case "$rest" in
            *,*) member="${rest%%,*}"; rest="${rest#*,}" ;;
            *)   member="$rest"; rest="" ;;
        esac
        # An empty member means a stray or doubled comma. Skipping it silently
        # would turn `a,,b` into a two-dataset plan the operator did not write,
        # and `a,b,` into one they might have meant to extend.
        [ -n "$member" ] || die "restore: the dataset list contains an empty entry ('$list') -- a stray or doubled comma. Every member must name a dataset; refusing rather than restoring a list that is not the one written."

        # Duplicate INPUT, before resolution: two identical names are either a
        # typo or a copy-paste, and neither is a reason to plan the same
        # destructive operation twice.
        for (( i=0; i<${#seen_in[@]}; i++ )); do
            [ "${seen_in[$i]}" = "$member" ] && die "restore: '$member' appears twice in the dataset list. Refusing rather than planning the same recovery twice."
        done
        seen_in+=("$member")

        hits="$(restore_resolve_try "$config" "$label" "$member" "$ns")" || \
            restore_scope_fail "$config" "$label" "$member" "$ns"
        n="$(printf '%s\n' "$hits" | grep -c .)"
        [ "$n" -eq 1 ] || die "restore: '$member' matches $n datasets of relation '$label' in $config, and a recovery needs exactly one. Refusing rather than choosing; 'restore --plan' lists them."

        IFS="$(printf '\t')" read -r src copy <<< "$hits"
        # Two DIFFERENT inputs that land on the same dataset -- possible because a
        # member may be named on either side and the mapping is not injective in
        # every config. Caught here rather than at execution, where the second
        # one would arrive after the first had already rewritten the target.
        for (( i=0; i<${#RESTORE_SCOPE_SRC[@]}; i++ )); do
            if [ "${RESTORE_SCOPE_SRC[$i]}" = "$src" ]; then
                die "restore: '$member' resolves to the same dataset as an earlier entry in the list ($src). Refusing: the second one would arrive after the first had already rewritten it."
            fi
        done
        RESTORE_SCOPE_SRC+=("$src"); RESTORE_SCOPE_COPY+=("$copy")
    done
    return 0
}

# BOTH sides named. Each list is resolved in its OWN namespace -- so the
# namespaces are still not mixed WITHIN a list -- and then the two results are
# compared position by position. Equal length, and pair i of one must be pair i
# of the other.
#
# Positional, not set-wise, and that is deliberate: if the operator writes the
# disks in a different order on the two sides they have said something they did
# not mean, and quietly sorting it out for them would hide exactly the mistake
# this form exists to let them state precisely.
restore_scope_pair() {   # <config> <label> <source list> <target list>
    local config="$1" label="$2" slist="$3" tlist="$4"
    local -a p_src=() p_copy=()
    local i n

    restore_scope_resolve "$config" "$label" copy "$slist"
    p_src=(${RESTORE_SCOPE_SRC[@]+"${RESTORE_SCOPE_SRC[@]}"})
    p_copy=(${RESTORE_SCOPE_COPY[@]+"${RESTORE_SCOPE_COPY[@]}"})

    restore_scope_resolve "$config" "$label" orig "$tlist"

    n="${#p_src[@]}"
    [ "$n" -eq "${#RESTORE_SCOPE_SRC[@]}" ] || die "restore: --source names $n dataset(s) and --target names ${#RESTORE_SCOPE_SRC[@]}. When both sides are given they are read as PAIRS, in order, so the two lists have to be the same length. Refusing rather than deciding which of them is the real scope."

    for (( i=0; i<n; i++ )); do
        if [ "${p_src[$i]}" != "${RESTORE_SCOPE_SRC[$i]}" ]; then
            die "restore: pair $((i + 1)) does not match the recorded relationship. --source position $((i + 1)) belongs to '${p_src[$i]}', but --target position $((i + 1)) names '${RESTORE_SCOPE_SRC[$i]}'. Stating both sides says explicitly what they already ARE; it does not remap one onto the other. Either fix the order, or give one side and let the record supply the other."
        fi
    done
    # Identical by the loop above, so either array is the answer; keep the one the
    # single-sided path also leaves behind, so everything downstream reads one shape.
    return 0
}

# The refusal wording depends on WHICH namespace was asked for -- an operator who
# wrote --target and gets told "not a managed copy location" is being answered a
# question they did not ask.
restore_scope_fail() {   # <config> <label> <member> <namespace>
    local config="$1" label="$2" member="$3" ns="$4"
    case "$ns" in
        copy) die "restore: '$member' is not a copy location of relation '$label' in $config. --source names the dataset AS IT EXISTS ON THE COLLECTOR; if you meant the name on the machine being restored, that is --target. 'restore --plan' lists both." ;;
        orig) die "restore: '$member' is not a dataset of relation '$label' in $config. --target names the dataset AS IT EXISTS ON THE MACHINE BEING RESTORED; if you meant where the copy lives, that is --source. 'restore --plan' lists both." ;;
        *)    restore_resolve_fail "$config" "$label" "$member" ;;
    esac
}

# ------------------------------------------------------------------------------
# A RECOVERY POINT IN WALL-CLOCK TIME
# ------------------------------------------------------------------------------
# The operator thinks "the state at noon yesterday", not in snapshot names. So
# `--at` takes a time and each dataset gets the snapshot with the greatest ZFS
# `creation` AT OR BEFORE it.
#
# THREE RULES, and each of them is a refusal to tell a comforting story:
#
#   1. `creation`, NEVER the name. A snapshot called `automated_daily_2026-08-10_...`
#      can have been created at some other time entirely -- renamed, made by hand
#      following the convention, or taken while the clock was wrong. The planner
#      already shouts when the two disagree by more than two minutes; selecting on
#      the name would quietly pick the story over the fact.
#   2. PER-DATASET FRONTIER, not a point in time. Every dataset resolves its own
#      answer, and under a comma list -- four disks of one VM -- that is exactly
#      the case where somebody will assume otherwise. The output says so in a
#      heading, not in a footnote.
#   3. A TIE IS FAIL-CLOSED. Two snapshots sharing the greatest `creation` at or
#      before the time is genuinely ambiguous, and the snapshot NAME is not a
#      tie-breaker -- picking the lexically later one would be rule 1 smuggled
#      back in through the ordering.
#
# Reads the same `name<TAB>creation<TAB>guid` listing the planner already fetches,
# so there is no second query and no second idea of what the snapshots are.
restore_at_pick() {   # <epoch> <listing> -> prints the chosen row; 1 = none, 2 = tie
    local want="$1" listing="$2"
    local sname screat sguid best="" bestc="" ties=0
    while IFS=$'\t' read -r sname screat sguid; do
        [ -n "$sname" ] || continue
        case "$screat" in ''|*[!0-9]*) continue ;; esac
        [ "$screat" -le "$want" ] || continue
        if [ -z "$bestc" ] || [ "$screat" -gt "$bestc" ]; then
            bestc="$screat"; best="$sname	$screat	$sguid"; ties=1
        elif [ "$screat" -eq "$bestc" ]; then
            ties=$((ties + 1))
        fi
    done <<< "$listing"
    [ -n "$best" ] || return 1
    [ "$ties" -eq 1 ] || return 2
    printf '%s\n' "$best"
    return 0
}

# `date -d` is what turns the operator's words into an epoch, and it is
# deliberately the ONLY thing that does: inventing a second date grammar here
# would mean two answers to "what does 'yesterday 12:00' mean".
restore_at_epoch() {   # <what the operator wrote> -> prints epoch, or dies
    local raw="$1" e
    e="$(date -d "$raw" +%s 2>/dev/null)" || e=""
    case "$e" in
        ''|*[!0-9]*) die "restore: --at '$raw' is not a time this system can read. date(1) parses it, so anything it takes works -- '2026-08-10 12:00', 'yesterday 12:00', '2 hours ago'. Refusing rather than guessing which moment was meant." ;;
    esac
    printf '%s' "$e"
}

restore_fence_capture() {   # <dataset> -> prints "<value> <source>"
    local ds="$1" val srcp
    val="$(zfs get -H -o value readonly "$ds" 2>/dev/null)"
    srcp="$(zfs get -H -o source readonly "$ds" 2>/dev/null)"
    case "$val" in on|off) ;; *) return 1 ;; esac
    [ -n "$srcp" ] || return 1
    printf '%s %s' "$val" "$srcp"
}

restore_fence_raise() {   # <dataset>; the caller must already hold the captured state
    local ds="$1"
    zfs set readonly=on "$ds" 2>/dev/null || return 1
    # Verify rather than trust the exit code: the point of a fence is that it is
    # UP, and `set` reporting success is not the same statement.
    [ "$(zfs get -H -o value readonly "$ds" 2>/dev/null)" = on ] || return 1
}

# REV-119 F1.3: value equality is not state restoration. A property that arrived
# with a received stream has provenance `received`, and putting the same VALUE
# back with `zfs set` converts it into a local override -- the value looks right
# and the state is not. `zfs inherit -S` is the one that reverts to the received
# value, so provenance decides the mechanism, not convenience.
restore_fence_lower() {   # <dataset> <previous value> <previous source>
    local ds="$1" val="$2" srcp="$3" rc=0 now nowsrc
    case "$srcp" in
        local)    zfs set readonly="$val" "$ds"   2>/dev/null || rc=1 ;;
        received) zfs inherit -S readonly "$ds"   2>/dev/null || rc=1 ;;
        *)        zfs inherit readonly "$ds"      2>/dev/null || rc=1 ;;
    esac

    # Read back. A `zfs` call that reports success and leaves the fence up is
    # exactly the case this whole helper exists to catch.
    if [ "$rc" -eq 0 ]; then
        now="$(zfs get -H -o value readonly "$ds" 2>/dev/null)"
        nowsrc="$(zfs get -H -o source readonly "$ds" 2>/dev/null)"
        [ "$now" = "$val" ] || rc=1
        # Provenance is checked in the one direction that is both meaningful and
        # not dependent on parent names: something that was NOT a local override
        # must not have become one.
        if [ "$rc" -eq 0 ] && [ "$srcp" != local ] && [ "$nowsrc" = local ]; then rc=1; fi
    fi

    [ "$rc" -eq 0 ] || {
        echo "UWAGA: nie udalo sie przywrocic wlasciwosci 'readonly' na '$ds' -- dataset moze byc nadal readonly=on. Stan sprzed: wartosc '$val', pochodzenie '$srcp'. Przywroc recznie:" >&2
        case "$srcp" in
            local)    echo "  zfs set readonly=$val $ds" >&2 ;;
            received) echo "  zfs inherit -S readonly $ds" >&2 ;;
            *)        echo "  zfs inherit readonly $ds" >&2 ;;
        esac
        return 1
    }
    return 0
}

# REV-119 F1.4: this REPORTS its outcome. The previous version warned on failure
# and returned success anyway, so callers went on to tell the operator that the
# source was exactly as they had left it -- while a run-owned snapshot was still
# sitting on it. A cleanup that cannot be trusted to say it failed is worse than
# no cleanup, because it launders a leftover into a clean bill of health.
restore_drop_tech_snapshots() {   # <source dataset> <snapshot names...>
    local src="$1"; shift
    local s rc=0
    for s in "$@"; do
        [ -n "$s" ] || continue
        zfs list -H -o name -t snapshot "${src}@${s}" >/dev/null 2>&1 || continue
        zfs destroy "${src}@${s}" >/dev/null 2>&1 || {
            echo "UWAGA: nie udalo sie usunac technicznego snapshota '${src}@${s}' -- usun go recznie: zfs destroy ${src}@${s}" >&2
            rc=1
        }
    done
    return "$rc"
}

# One exit point for every refusal after the technical snapshots exist, so that
# "nothing was destroyed" and "the source is exactly as you left it" are two
# separate claims and the second is only made when it is true.
#
# REV-119 F1.2 residual: there are TWO independent things that can be left behind,
# and the first version of this helper only knew about one. A failed `readonly`
# restoration was swallowed with `|| true` at the call site, and then this function
# -- seeing that the snapshots had gone -- told the operator the source was exactly
# as they had left it, while it sat there read-only. That is the same laundering
# defect F1.4 fixed for snapshots, committed again one layer up.
#
# So the exact-state claim now requires BOTH facts, and the caller has to state
# what happened to the fence rather than being allowed to forget.
restore_die_after_cleanup() {   # <source> <fence: ok|dirty> <message> <snapshot names...>
    local src="$1" fence="$2" msg="$3"; shift 3
    local snaps=ok
    restore_drop_tech_snapshots "$src" "$@" || snaps=dirty

    if [ "$fence" = ok ] && [ "$snaps" = ok ]; then
        die "$msg Zrodlo '$src' jest dokladnie w stanie sprzed tego polecenia."
    fi

    local left=""
    [ "$fence" = dirty ] && left="wlasciwosc 'readonly' (szczegoly i komenda naprawcza wyzej)"
    [ "$snaps" = dirty ] && left="${left:+$left oraz }techniczne snapshoty tego przebiegu (wypisane wyzej)"
    die "$msg UWAGA: '$src' NIE jest w stanie sprzed polecenia -- zostalo do naprawienia recznie: $left."
}
# ------------------------------------------------------------------------------
# restore_one -- ONE dataset, from the copy back onto the machine it came from
# What the TARGET already has. Under push the machine being written to is on the
# far side, so the classification create/rewind/replace cannot be made from the
# copy alone -- restore_plan_strategy says exactly that and returns `remote`.
#
# One ssh, two reads, and nothing written: does the dataset exist, and what is
# the GUID of its newest snapshot. That is the whole question, because it is the
# same question snapsend will answer for itself a moment later when it looks for
# a common base -- this asks it early only so the right MODE can be named in the
# grant check before anything is sent.
#
# Prints "absent", or the head GUID. Empty output means the host could not be
# asked, which the caller must treat as unclassifiable rather than as absent --
# "I could not reach it" and "there is nothing there" differ by an entire
# destroyed dataset.
# THREE ANSWERS, NOT TWO, AND SILENCE IS NOT ONE OF THEM.
#
# This used to print `absent`, or a GUID, or NOTHING for a dataset that exists
# and holds no snapshots. Nothing is also what an unreachable host prints, so
# the caller -- whose own comment says "'I could not reach it' and 'there is
# nothing there' differ by an entire destroyed dataset" -- collapsed the two.
#
# Measured on the lab, 2026-08-27. A dataset was recreated empty at the target
# path, which is a real disaster shape: something rebuilt the guest and the copy
# is now the only history there is. The restore refused with "the host did not
# answer". The host had answered, immediately and correctly. The right reading
# is a target with no common base -- `replace`, a mode the grant governs and can
# refuse for a stated reason, rather than a transport error that sends the
# operator to go and look at the network.
#
#   absent             the dataset is not there
#   bare               it is there and holds no snapshots -- no common base
#   <guid>             its newest snapshot
#   (empty, non-zero)  the question could not be asked
restore_remote_state() {   # <account@host:dataset> -> "absent" | "bare" | <guid> | nothing
    local spec="$1" peer="${1%%:*}" ds="${1#*:}"
    [ -n "$peer" ] && [ -n "$ds" ] && [ "$peer" != "$spec" ] || return 1
    ssh -n ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$peer" \
        "zfs list -H -o name '$ds' >/dev/null 2>&1 || { echo absent; exit 0; }; \
         g=\$(zfs list -H -p -t snapshot -o guid -s creation -d 1 '$ds' 2>/dev/null | tail -1); \
         [ -n \"\$g\" ] && echo \"\$g\" || echo bare" 2>/dev/null
}
# WHICH DATASETS OF THE SUBTREE DIFFER FROM THE RECOVERY POINT?
#
# This asked a narrower question -- "does it hold a snapshot NEWER than the
# point" -- and that question has a false negative that costs the entire
# recovery. Measured on the lab, 2026-08-27, on the most ordinary disaster
# there is: files deleted from a live filesystem, no snapshot taken since.
#
#   hdd/labsrc: newest snapshot = the recovery point
#               written@<point> = 73728
#
# No snapshot was newer, so nothing was ahead, so no rollback ran; the engine
# then had a zero-length increment to send and exited 0; and the run reported
# "all 1 dataset(s) in scope recovered" over a filesystem that still had the
# damage in it and the deleted files still missing. Success, reported, having
# changed nothing.
#
# `written@<point>` answers the question that actually matters, and answers both
# halves of it at once: it is non-zero when snapshots exist after the point AND
# when the live filesystem has diverged from it -- which is the same thing from
# the restore's side, because both are state that has to go before the dataset
# is at that point again. `zfs rollback` removes either.
#
# It also answers a third case honestly: "-" means the dataset does not have
# that snapshot at all, so there is no point to roll back TO. Those are skipped
# here and caught by the verification after the run instead, where the right
# answer is "this dataset was not recovered", not "roll it back to something it
# does not have".
#
# Prints the datasets that differ, one per line. Empty means none does. A failed
# read prints nothing AND returns non-zero, so the caller can tell "nothing to
# do" from "I could not ask" -- they differ by an entire skipped rollback.
restore_remote_ahead() {   # <account@host> <target root> <recovery point name> [depth: "" = subtree, "-d 0" = itself]
    local peer="$1" root="$2" point="$3" depth="${4-}"
    ssh -n ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$peer" "
        for d in \$(zfs list -H -o name $depth -r '$root' 2>/dev/null); do
            w=\$(zfs get -Hp -o value 'written@$point' \"\$d\" 2>/dev/null)
            case \"\$w\" in ''|-|0) continue ;; esac
            echo \"\$d\"
        done
        exit 0" 2>/dev/null
}

# IS EVERY DATASET OF THE SUBTREE ACTUALLY AT THE RECOVERY POINT NOW?
#
# Asked after the engine, because "the engine exited 0" and "the machine holds
# the data again" are not the same sentence, and the lab has now produced a run
# where the first was true and the second was false.
#
# The measure is the same property, read again: at the point means
# `written@<point>` is exactly 0 -- no snapshot after it and nothing written
# since. Anything else is named and the dataset is reported NOT recovered.
#
#   0     at the point
#   >0    still diverged -- the recovery did not land
#   -     the dataset does not have that snapshot at all
#   ''    could not be read
#
# Prints one "<dataset> <reason>" line per dataset that is NOT at the point.
# Silence means every one of them is.
restore_remote_off_point() {   # <account@host> <target root> <recovery point name> [depth: "" = subtree, "-d 0" = itself]
    local peer="$1" root="$2" point="$3" depth="${4-}"
    ssh -n ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$peer" "
        for d in \$(zfs list -H -o name $depth -r '$root' 2>/dev/null); do
            w=\$(zfs get -Hp -o value 'written@$point' \"\$d\" 2>/dev/null)
            case \"\$w\" in
                0)  ;;
                -)  echo \"\$d does not have that snapshot\" ;;
                '') echo \"\$d could not be read\" ;;
                *)  echo \"\$d still differs from it by \$w bytes\" ;;
            esac
        done
        exit 0" 2>/dev/null
}


# ------------------------------------------------------------------------------
#
# This is the step that writes. Everything above it decides whether it may, and
# everything below it is snapsend.sh doing what it already does.
#
# The order is the design, and it is not arrangeable: nothing is asked of the
# far side until the near side has proved it knows exactly what it would send.
#
#   1. the recovery point, resolved from the COPY's snapshots
#   2. the point is unambiguous under the ENGINE's own matching rule
#   3. the mode, CLASSIFIED from the data (never an operator choice)
#   4. the grant, read from the target, requiring that exact mode
#   5. the command, with flags DERIVED from the classification
#   6. the engine
#
# Steps 1-3 are local and free. Step 4 is the only question asked of another
# machine, and it is asked once the answer can be acted on -- asking first would
# mean holding a permission while still deciding what to do with it.
#
# THE MODE MAPPING, from the planner's strategy to the three the grant names:
#
#   full-absent                          -> create    nothing there to lose
#   increment | rollback | discard-live   -> rewind    a GUID-proven base exists
#   full-live | unproven                  -> replace   no valid base; full overwrite
#   ambiguous | remote | anything else    -> refuse
#
# `rollback` and `discard-live` remove divergent state, which is destructive in
# the ordinary sense -- but they are `rewind` here because a proven common base
# is what makes them a rewind rather than an overwrite, and that distinction is
# the one owner decision 4 draws. `unproven` lands in `replace` deliberately:
# unproven means the base could not be established, and sending an increment
# from a base nobody proved is the one failure that corrupts instead of refusing.
restore_one() {   # <copy dataset> <original source, account@host:dataset or local>
    local copy="$1" src="$2"
    RESTORE_ONE_VERDICT=""

    # ---- 1. the recovery point --------------------------------------------
    # Rows, not names: restore_plan_strategy needs creation and guid, and --at
    # resolves by creation because that is when the data was captured. A name
    # can disagree with it -- measured on this estate, where two hosts in
    # different timezones write different names for the same instant.
    local rows snaps point
    rows=$(zfs list -H -p -t snapshot -o name,creation,guid -s creation -d 1 "$copy" 2>/dev/null)
    if [ -z "$rows" ]; then
        RESTORE_ONE_VERDICT="the copy '$copy' has no snapshot to restore from"
        log 0 "restore: $src -- ${RESTORE_ONE_VERDICT}. Nothing was changed."
        return 1
    fi
    snaps=$(printf '%s\n' "$rows" | awk -F'\t' '{print $1}' | awk -F'@' '{print $2}')

    if [ -n "${RESTORE_AT_EPOCH:-}" ]; then
        # Per dataset, nearest at-or-before -- for a FLAT relation each dataset
        # has its own frontier, so "the state at 12:00" is not one instant across
        # the subtree. A tie refuses rather than picking by list order.
        local _row
        _row="$(restore_at_pick "$RESTORE_AT_EPOCH" "$rows")"; local _prc=$?
        case "$_prc" in
            0) point="$(printf '%s' "$_row" | awk -F'\t' '{print $1}' | awk -F'@' '{print $2}')" ;;
            2) RESTORE_ONE_VERDICT="two snapshots share the newest creation time at or before --at, so the recovery point is a tie"
               log 0 "restore: $src -- ${RESTORE_ONE_VERDICT}. Refusing rather than resolving it by list order."
               return 1 ;;
            *) RESTORE_ONE_VERDICT="nothing on '$copy' was captured at or before --at"
               log 0 "restore: $src -- ${RESTORE_ONE_VERDICT}. Nothing was changed."
               return 1 ;;
        esac
    else
        point="${RESTORE_POINT_NAME:-}"
        [ -n "$point" ] || point="$(printf '%s\n' "$snaps" | tail -1)"
    fi

    # ---- 2. unambiguous under the engine's rule ----------------------------
    if ! restore_point_unique "$point" "$snaps"; then
        RESTORE_ONE_VERDICT="the recovery point '$point' is not unambiguous on '$copy'"
        return 1
    fi

    # ---- 3. the mode, classified ------------------------------------------
    # The strategy is computed HERE rather than handed in, so the runner needs
    # to know nothing about it and one dataset's classification cannot leak into
    # the next. The listing is filtered to the chosen point: a strategy derived
    # from snapshots NEWER than the recovery point would answer a different
    # question than the one being asked.
    local mode
    case "$src" in
        *:*)
            # REMOTE target: ask it. restore_plan_strategy answers `remote` here
            # by design -- it is the read-only planner and does not open ssh.
            local _st _guid
            _st="$(restore_remote_state "$src")"
            if [ -z "$_st" ]; then
                RESTORE_ONE_VERDICT="could not read the state of '$src' -- the host did not answer"
                log 0 "restore: $src -- ${RESTORE_ONE_VERDICT}. Refusing: 'I could not reach it' and 'there is nothing there' differ by an entire destroyed dataset."
                return 1
            fi
            if [ "$_st" = absent ]; then
                RESTORE_STRATEGY=full-absent
            elif [ "$_st" = bare ]; then
                # There, and empty. No snapshot means no common base can
                # exist, so this is a full overwrite of live data --
                # `replace`, the one mode the grant withholds by default.
                RESTORE_STRATEGY=full-live
            else
                # A common base exists when the target's head GUID is one this
                # copy also carries at or before the recovery point. That is the
                # same proof snapsend will require; asking early only names the
                # mode for the grant.
                _guid="$(printf '%s\n' "$rows" | awk -F'\t' -v g="$_st" '$3 == g {print; exit}')"
                if [ -z "$_guid" ]; then
                    RESTORE_STRATEGY=full-live
                else
                    # The target's head is a snapshot this copy also has. Where
                    # it sits RELATIVE TO THE RECOVERY POINT decides everything:
                    #
                    #   at or before the point -> an increment carries it forward
                    #   AFTER the point        -> going back, which no send can
                    #                             do. The target has to be rolled
                    #                             back, and that DESTROYS the
                    #                             snapshots between.
                    #
                    # Getting this wrong is not a failed transfer, it is a
                    # transfer that cannot exist: `zfs send -I A..B` with B older
                    # than A. Measured on the lab, where restoring to 15:51 while
                    # the target sat at 16:51 classified as `increment` and would
                    # have asked the engine for a stream backwards in time.
                    # THE WHOLE SUBTREE, not the root. A root sitting at the
                    # recovery point says nothing about its children, and the
                    # lab proved it: after one restore the root was at the point
                    # and both children were still ahead, so a root-only check
                    # said `increment`, skipped the rollback, and called the run
                    # a success over untouched damage.
                    #
                    # And "differs from", not "is ahead of". The narrower
                    # question missed the commonest disaster of all -- files
                    # deleted from a live filesystem with no snapshot taken
                    # since -- because nothing was newer, so nothing was ahead,
                    # so no rollback ran and the run reported success over the
                    # damage. See restore_remote_ahead's own header.
                    local _ahead
                    # Same depth rule as the verification below: when every
                    # dataset is its own scope entry, this one answers for
                    # itself. A parent would otherwise be rolled back because a
                    # child differs, and that child is about to be handled on
                    # its own line.
                    local _adepth=""
                    if [ "${RESTORE_SCOPE_EXPANDED:-0}" -eq 1 ]; then _adepth="-d 0"; fi
                    # THE EXIT STATUS, NOT ONLY THE STRING.
                    #
                    # restore_remote_ahead's own header promises the caller can
                    # tell "nothing differs" from "I could not ask" -- empty and
                    # zero versus empty and non-zero. The caller then tested
                    # `[ -n "$_ahead" ]` and threw the status away, so an ssh
                    # that never answered read as a target that needs nothing:
                    # no rollback, an empty increment, and a clean report over
                    # untouched damage.
                    #
                    # The same shape as F14 two hours earlier, in the same file:
                    # a function that carefully distinguishes two cases, and a
                    # caller that collapses them again. Writing the distinction
                    # into the probe is half the work; the half that decides
                    # anything is reading it.
                    local _arc
                    _ahead="$(restore_remote_ahead "${src%%:*}" "${src#*:}" "$point" "$_adepth")"; _arc=$?
                    if [ "$_arc" -ne 0 ]; then
                        RESTORE_ONE_VERDICT="could not ask '$src' whether it differs from $point"
                        log 0 "restore: $src -- ${RESTORE_ONE_VERDICT}. Refusing: an unanswered question is not a clean target, and treating it as one is how a restore reports success over damage it never looked at."
                        return 1
                    fi
                    if [ -n "$_ahead" ]; then
                        RESTORE_STRATEGY=rollback
                        RESTORE_ROLLBACK_TO="$point"
                        log 1 "restore: differs from $point on the target: $(printf '%s' "$_ahead" | tr '\n' ' ')"
                    else
                        RESTORE_STRATEGY=increment
                    fi
                fi
            fi ;;
        *)
            if [ -z "${RESTORE_STRATEGY_PINNED:-}" ]; then
                local _cut
                _cut="$(printf '%s\n' "$rows" | awk -F'\t' -v p="${copy}@${point}" '
                    { print } $1 == p { exit }')"
                restore_plan_strategy "$copy" "$src" "$_cut" "$point" >/dev/null 2>&1 || :
            fi ;;
    esac
    case "${RESTORE_STRATEGY:-}" in
        full-absent)                        mode=create ;;
        increment|rollback|discard-live)    mode=rewind ;;
        full-live|unproven)                 mode=replace ;;
        ambiguous)
            RESTORE_ONE_VERDICT="the recovery point on '$copy' is ambiguous, so no mode can be classified"
            log 0 "restore: $src -- ${RESTORE_ONE_VERDICT}. Refusing: guessing would destroy state under a decision nobody took."
            return 1 ;;
        *)
            RESTORE_ONE_VERDICT="no strategy was established for '$src' (got '${RESTORE_STRATEGY:-<none>}')"
            log 0 "restore: $src -- ${RESTORE_ONE_VERDICT}. Refusing to act on an undetermined state."
            return 1 ;;
    esac

    # ---- 4. the grant ------------------------------------------------------
    # The one question asked of the far side. A LOCAL target needs none: the
    # machine at risk is this one, and whoever is running this already has root
    # on it -- which is the whole argument the pull form would have rested on.
    local host="${src%%:*}"
    case "$src" in
        *:*)
            local answer
            answer="$(restore_grant_ask "$host")" || answer=""
            if ! restore_grant_require "${RESTORE_LABEL:-}" "$answer" "$mode" "$host"; then
                RESTORE_ONE_VERDICT="'$host' does not grant '$mode' for this relationship"
                return 1
            fi ;;
        *)  log 1 "restore: $src is on this machine, so no grant is asked for -- the host at risk is the one running this." ;;
    esac

    # ---- 4b. replace needs the target UNMOUNTED, and only replace does -----
    #
    # `replace` is the mode with no common base, so the engine runs a full send
    # with -f: destroy the target and recreate it. Destroying a MOUNTED dataset
    # unmounts it first, and on Linux a delegated account cannot unmount even
    # with full `zfs allow` -- so on the delegated fleet this mode could be
    # granted, classified and refused by physics, several seconds in.
    #
    # Measured on the lab, 2026-08-27. The grant said replace, the mode
    # classified as replace, and the engine came back with:
    #
    #     cannot create 'hdd/labsrc/vm-900-disk-1': dataset already exists
    #     Hint: [...] -f requires root on 192.168.28.9.
    #
    # That hint is true and it is a dead end: nobody can "run it as root on
    # 192.168.28.9" -- the collector reaches that machine through a forced
    # command as the relationship account, by design. What is actually needed is
    # ONE unmount, by root, on the machine being recovered. The same restore then
    # goes through as the delegated account, which is how the second attempt
    # succeeded.
    #
    # Asked BEFORE the engine, not diagnosed after it: a destructive mode that
    # cannot complete should change nothing at all, and the operator should get
    # the one command that unblocks it rather than a hint pointing nowhere.
    # Only on `replace`: the other modes do not destroy the dataset, and paying
    # an ssh round trip on every ordinary recovery to answer a question only
    # this one asks would be a cost for nothing.
    if [ "$mode" = replace ]; then
        case "$src" in
            *:*)
                local _tgt_ds="${src#*:}" _ms
                _ms="$(ssh -n ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$host" \
                       "zfs list -H -o mounted,type '$_tgt_ds'" 2>/dev/null)"
                case "$_ms" in
                    "")  log 1 "restore: could not read whether '$_tgt_ds' is mounted on '$host' -- going ahead; the engine will say if it cannot proceed." ;;
                    yes*filesystem)
                        RESTORE_ONE_VERDICT="'$_tgt_ds' is MOUNTED on '$host', and 'replace' destroys and recreates it"
                        log 0 "restore: $src -- ${RESTORE_ONE_VERDICT}. Nothing was changed."
                        log 0 "restore: destroying a mounted dataset unmounts it first, and on Linux a delegated account cannot unmount -- with or without 'zfs allow'. This is not something this side can work around."
                        log 0 "restore: one command, as root ON $host, and then re-run this restore unchanged:"
                        log 0 "restore:     zfs unmount '$_tgt_ds'"
                        log 0 "restore: nothing else needs root: the transfer itself runs as the relationship account."
                        return 1 ;;
                esac ;;
        esac
    fi

    # ---- 5. the command ----------------------------------------------------
    if ! restore_engine_argv "$copy" "$src" "$point" "$mode"; then
        RESTORE_ONE_VERDICT="could not build the engine command for mode '$mode'"
        return 1
    fi

    # ---- 6a. going backwards, if that is what was asked --------------------
    # A recovery point OLDER than what the target holds cannot be reached by
    # sending: the snapshots in between have to go. This is the destructive half
    # of a restore, it is why `rewind` is a mode the grant names, and it happens
    # only after that grant has been read and required.
    #
    # -r on the rollback, and -R on nothing: `zfs rollback -r` destroys the
    # snapshots and bookmarks NEWER than the one named, on that dataset. Each
    # dataset of a subtree needs its own, because rollback is not recursive over
    # children -- so the loop is remote and explicit rather than implied.
    if [ "${RESTORE_STRATEGY:-}" = rollback ] && [ -n "${RESTORE_ROLLBACK_TO:-}" ]; then
        local _peer="${src%%:*}" _tgt="${src#*:}" _ds _list _failed=0
        log 0 "restore: $src -- the target differs from $point (snapshots after it, writes since it, or both); rolling it back to reach that point. Whatever came after is destroyed."

        # TWO ssh calls, and no remote command substitution in either.
        #
        # The first version put `$(zfs list ...)` inside the remote command. It
        # expanded HERE, on the collector, where that dataset does not exist --
        # so the loop was empty, nothing was rolled back, and the run reported
        # success. What made it look like it had worked was the engine's own
        # `recv -F` rolling back the one dataset it received into.
        #
        # Measured on the lab: the parent came back to the recovery point and
        # both children kept the damage, while the report said all recovered.
        # A quoting mistake that silently narrows a destructive operation to a
        # third of its scope is exactly the kind this project keeps paying for,
        # so the substitution is gone rather than escaped more carefully.
        local _rdepth=""
        if [ "${RESTORE_SCOPE_EXPANDED:-0}" -eq 1 ]; then _rdepth="-d 0"; fi
        _list="$(ssh -n ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$_peer" "zfs list -H -o name $_rdepth -r '$_tgt'" 2>/dev/null)"
        if [ -z "$_list" ]; then
            RESTORE_ONE_VERDICT="could not list '$_tgt' on '$_peer' to roll it back"
            log 0 "restore: $src -- ${RESTORE_ONE_VERDICT}. Nothing was changed."
            return 1
        fi
        # Every dataset of the subtree, by name, one command. `zfs rollback` is
        # not recursive over children -- -r there means "destroy the snapshots
        # newer than this one", not "descend" -- so each needs its own.
        while IFS= read -r _ds; do
            [ -n "$_ds" ] || continue
            if ! ssh -n ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$_peer" \
                 "zfs rollback -r '${_ds}@${RESTORE_ROLLBACK_TO}'" 2>/dev/null; then
                # A dataset that never had this snapshot is not a failure: a
                # child added after the recovery point legitimately has no such
                # point to return to. One that HAS it and refuses is.
                if ssh -n ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$_peer" \
                   "zfs list -H -o name '${_ds}@${RESTORE_ROLLBACK_TO}'" >/dev/null 2>&1; then
                    log 0 "restore:   $_ds -- rollback to $RESTORE_ROLLBACK_TO REFUSED"
                    _failed=1
                else
                    log 1 "restore:   $_ds has no $RESTORE_ROLLBACK_TO -- nothing to roll back to, left alone"
                fi
            else
                log 1 "restore:   $_ds rolled back to $RESTORE_ROLLBACK_TO"
            fi
        done <<< "$_list"
        if [ "$_failed" -eq 1 ]; then
            RESTORE_ONE_VERDICT="the target could not be rolled back to $point (the datasets are named above)"
            log 0 "restore: $src -- ${RESTORE_ONE_VERDICT}. Nothing further was attempted."
            return 1
        fi
        # Recorded so the run can close by saying what this costs the BACKUP.
        # Rolling the source back to $point leaves the copy holding snapshots
        # the source no longer has, and the next pull of this relationship
        # refuses on exactly that -- correctly, because -F would destroy them.
        # A recovery that silently leaves the machine's protection jammed is
        # half an operation; the operator finds out at the next backup, or at
        # the next monitor alarm, or not at all.
        RESTORE_ROLLED_BACK+=("$src")
    fi

    # ---- 6. the engine -----------------------------------------------------
    log 0 "restore: $src <- $copy@$point  [$mode]"
    # The engine warns that a dataset with children is being sent without -r.
    # True, and not a problem here: those children are separate entries in this
    # run, each with its own classification and its own line in the report. Said
    # before the warning appears, so the operator is not left deciding whether a
    # recovery just skipped half the machine.
    if [ "${RESTORE_SCOPE_EXPANDED:-0}" -eq 1 ] && [ "${RESTORE_ENGINE_RECURSED:-0}" -eq 0 ]; then
        log 1 "restore:   (children of $copy, if any, are their own entries in this run -- the engine's 'neither -r nor -R' warning below is expected)"
    fi
    log 1 "restore:   ${RESTORE_ENGINE:-snapsend.sh} ${RESTORE_ENGINE_ARGV[*]}"
    if [ "${RESTORE_DRY_RUN:-0}" -eq 1 ]; then
        RESTORE_ONE_VERDICT="dry run -- the command above was NOT executed"
        return 1
    fi
    if bash "${RESTORE_ENGINE:?the engine path is not set}" "${RESTORE_ENGINE_ARGV[@]}"; then
        # "THE ENGINE EXITED 0" AND "THE MACHINE HOLDS THE DATA AGAIN" ARE NOT
        # THE SAME SENTENCE, and the lab has produced a run where the first was
        # true and the second was false: a zero-length increment sent to a
        # dataset whose live filesystem still had the damage in it. Every
        # protection in this file sat upstream of that -- the grant was read,
        # the mode was classified, the point was proved unambiguous -- and none
        # of them is a measurement of the result.
        #
        # So the result is measured. Every dataset of the subtree must be AT the
        # recovery point: written@<point> exactly 0. Anything else is named, and
        # the dataset is reported NOT recovered, which is what it is.
        #
        # A LOCAL target is skipped only because the remote probe is what exists;
        # the same measurement locally is the next slice, not a decision that it
        # does not matter.
        case "$src" in
            *:*)
                local _off
                # MEASURED OVER EXACTLY WHAT WAS SENT. When the scope lists
                # every dataset separately, the parent's entry is the parent and
                # nothing else -- verifying its whole subtree judged it on
                # children that are their own entries, still queued, and made
                # the verdict depend on loop order. Measured on the lab: the
                # parent reported NOT DONE while both its children were
                # recovered two lines further down.
                local _vdepth=""
                [ "${RESTORE_ENGINE_RECURSED:-0}" -eq 1 ] || _vdepth="-d 0"
                local _orc
                _off="$(restore_remote_off_point "${src%%:*}" "${src#*:}" "$point" "$_vdepth")"; _orc=$?
                if [ "$_orc" -ne 0 ]; then
                    # Same rule on the way out. "I could not check" is not
                    # "it is fine", and this is the last chance to say so.
                    RESTORE_ONE_VERDICT="the engine reported success and the result could NOT be verified -- '$src' did not answer"
                    log 0 "restore: $src -- ${RESTORE_ONE_VERDICT}. Reporting it as not done: the transfer may well have worked, and nobody here has seen that it did."
                    return 1
                fi
                if [ -n "$_off" ]; then
                    RESTORE_ONE_VERDICT="the engine reported success but the target is NOT at $point"
                    log 0 "restore: $src -- ${RESTORE_ONE_VERDICT}:"
                    printf '%s\n' "$_off" | while IFS= read -r _l; do
                        [ -n "$_l" ] && log 0 "restore:   $_l"
                    done
                    log 0 "restore: reporting this as NOT recovered. A run that changed nothing must not be indistinguishable from one that worked."
                    return 1
                fi ;;
        esac
        RESTORE_ONE_VERDICT="$mode from $point"
        return 0
    fi
    # The engine's own diagnosis has already gone to stderr; do not paraphrase
    # it. What is added here is WHICH dataset it belonged to, because the caller
    # is looping and the operator is reading one report at the end.
    RESTORE_ONE_VERDICT="the engine failed on '$mode' from $point (its own message is above)"
    return 1
}

# ------------------------------------------------------------------------------
# THE WHOLE-RELATION RUN -- continue past a failure, and report per dataset
# What the recovery cost the BACKUP, said out loud at the end of the run.
#
# Measured on the lab, 2026-08-27: a restore rolled the source back an hour, the
# recovery was correct and complete, and the NEXT hourly pull of that same
# relationship refused -- because the copy still held the snapshot of the period
# that had just been rolled away, and continuing would have destroyed it. That
# refusal is right. What was wrong is that nothing said it was coming: the
# restore reported a clean run and left the machine's protection jammed until
# somebody read a cron log.
#
# So the run closes by naming it. Not a warning about a risk -- a statement of a
# state that now exists, with the two ways out and what each one costs.
restore_report_backup_cost() {
    [ "${#RESTORE_ROLLED_BACK[@]}" -gt 0 ] || return 0
    local d
    log 0 "restore: ---- what this costs the backup ----"
    log 0 "restore: the source was rolled back, so the copy on this collector now holds snapshots the source no longer has, for:"
    for d in "${RESTORE_ROLLED_BACK[@]}"; do
        log 0 "restore:   $d"
    done
    log 0 "restore: the next backup of this relationship WILL REFUSE, naming those snapshots. That refusal is correct: they are the only remaining copy of the period the source rolled away."
    log 0 "restore: two ways out, and they are not equivalent --"
    log 0 "restore:   keep them: park the copy (zfs rename) or clone it aside, then let the pull start a fresh lineage. Nothing is lost."
    log 0 "restore:   discard them: zfs destroy each one on the copy, then re-run the pull. The account that owns the relationship can do that -- no root, and nothing is re-sent. The period that was rolled away then exists nowhere."
    log 0 "restore: the refusal itself names the snapshots, so no list has to be reconstructed. -f would also clear it, by destroying the copy and re-sending every byte, and -f needs root."

}

# A RECOVERED FILESYSTEM THAT IS NOT MOUNTED IS NOT YET USABLE, AND THE RUN
# USED TO END WITHOUT MENTIONING IT.
#
# Measured on the lab, 2026-08-27, restoring a dataset the disaster had removed
# entirely. It came back with the right mountpoint and the right properties, the
# run reported "all 1 dataset(s) in scope recovered" -- and /hdd/labsrc/
# vm-900-disk-1 did not exist, because the dataset was not mounted.
#
# The cause is not a bug to fix silently: `canmount=noauto` travels in the
# stream from the copy, and the collector sets it deliberately so that twenty
# machines' filesystems do not mount themselves over each other on one host.
# The right value on the copy is the wrong value on the machine being recovered,
# and the stream cannot know which side it is landing on.
#
# So this REPORTS rather than mounts. A recovery is not the moment to mount
# something automatically: the operator may want to look before the guest does,
# the mountpoint may be occupied, and `canmount=noauto` may be exactly what that
# dataset is supposed to carry. What they must not have to discover for
# themselves is that the data is there and invisible.
#
# ZVOLs are skipped -- they have no mountpoint and nothing to say.
restore_report_mount_state() {
    [ "${#RESTORE_LANDED[@]}" -gt 0 ] || return 0
    local d peer ds line name typ cm mnt said=0
    for d in "${RESTORE_LANDED[@]}"; do
        case "$d" in
            *:*) peer="${d%%:*}"; ds="${d#*:}" ;;
            *)   peer="";        ds="$d" ;;
        esac
        local out
        if [ -n "$peer" ]; then
            out="$(ssh -n ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$peer" "zfs list -H -o name,type,canmount,mounted -r '$ds'" 2>/dev/null)"
        else
            out="$(zfs list -H -o name,type,canmount,mounted -r "$ds" 2>/dev/null)"
        fi
        # An unreadable answer is not "everything is mounted". Say which it was.
        if [ -z "$out" ]; then
            log 0 "restore: could not read the mount state of '$d' after recovering it -- the data landed, but whether it is reachable is unverified."
            said=1
            continue
        fi
        while IFS=$'\t' read -r name typ cm mnt; do
            [ "$typ" = filesystem ] || continue
            [ "$mnt" = no ] || continue
            if [ "$said" -eq 0 ]; then
                log 0 "restore: ---- recovered, and not mounted ----"
                said=1
            fi
            log 0 "restore:   $name (canmount=$cm) -- the data is there and the mountpoint is empty until it is mounted."
        done <<< "$out"
    done
    [ "$said" -eq 1 ] || return 0
    log 0 "restore: canmount=noauto travels in the stream from the copy, where it is correct -- a collector must not mount twenty machines' filesystems over each other. On the machine being recovered it is usually not what you want."
    log 0 "restore: mount one now with:  zfs mount <dataset>    and to have it come back at boot:  zfs set canmount=on <dataset>"
    log 0 "restore: not done for you on purpose: a recovery is not the moment to mount something without being asked."
}

# ------------------------------------------------------------------------------
#
# Owner decision 7 (OWNER-RESTORE-GRANT-AND-MODES-2026-08-26). The implementer
# recommended stopping at the first failure; the owner overruled, and the
# reasoning is what makes continuing safe rather than merely convenient:
#
#   a recovery is not a deployment. Stopping at the first failure leaves the
#   operator with a half-restored machine AND no information about the rest, at
#   the moment they most need the complete picture. Continuing produces the same
#   partial state plus the map.
#
# Two obligations follow, and they are not decoration:
#
#   * the report is a PER-DATASET VERDICT, never a count. "7/10" tells an
#     operator nothing they can act on at 3am; the three names do;
#   * the exit status distinguishes "everything" from "not everything". Nine of
#     ten is not ten, and on a machine being recovered the exit status is the
#     part a wrapper reads.
#
# TWO CODES, not three. 0 means every dataset in scope was recovered; 1 means it
# was not. The planner already uses exactly that contract for an incomplete
# `--at`, and a third code separating "some" from "none" would be a contract the
# owner did not ask for -- the distinction that matters operationally is in the
# report, where it can name datasets instead of counting them.
#
# An EMPTY scope is a refusal, not a clean run. "Nothing matched" exiting 0 is
# how a mistyped scope becomes a recovery someone believes happened.
restore_run_scope() {   # uses RESTORE_SCOPE_COPY[] / RESTORE_SCOPE_SRC[]
    local n="${#RESTORE_SCOPE_SRC[@]}" i rc ok_n=0 bad_n=0
    local -a verdict=()
    # NOT local: restore_one appends to it. Reset here so a second call in one
    # process cannot inherit the first call's list.
    RESTORE_ROLLED_BACK=()
    RESTORE_LANDED=()

    if [ "$n" -eq 0 ]; then
        log 0 "restore: the scope resolved to no datasets at all. That is not a completed recovery -- refusing rather than reporting a clean run over nothing."
        return 1
    fi

    # restore_one is the per-dataset step, and it is the NEXT slice. Refusing
    # here rather than noting the gap in a comment: a function that calls an
    # undefined one fails at the moment it is first used, which for a recovery
    # verb is the worst moment there is. Structural, so it cannot be forgotten
    # -- and it disappears on its own the day the step exists.
    if ! declare -F restore_one >/dev/null 2>&1; then
        log 0 "restore: the per-dataset step is not built yet, so this cannot recover anything. Nothing was changed. (restore_one, the next slice.)"
        return 1
    fi


    for (( i=0; i<n; i++ )); do
        RESTORE_ONE_VERDICT=""
        # The failure of one dataset must not end the run: that is the whole of
        # decision 7. `|| :` is deliberate and is the only place in this
        # function where a non-zero status is not propagated immediately.
        restore_one "${RESTORE_SCOPE_COPY[$i]}" "${RESTORE_SCOPE_SRC[$i]}"; rc=$?
        if [ "$rc" -eq 0 ]; then
            ok_n=$((ok_n + 1))
            RESTORE_LANDED+=("${RESTORE_SCOPE_SRC[$i]}")
            verdict+=("OK       ${RESTORE_SCOPE_SRC[$i]}   ${RESTORE_ONE_VERDICT:-recovered}")
        else
            bad_n=$((bad_n + 1))
            verdict+=("NOT DONE ${RESTORE_SCOPE_SRC[$i]}   ${RESTORE_ONE_VERDICT:-no reason recorded}")
        fi
    done

    # Printed on EVERY path, including the one where nothing worked. A run that
    # recovered nothing still owes the operator the map of what it tried.
    log 0 "restore: per-dataset result"
    for (( i=0; i<${#verdict[@]}; i++ )); do
        log 0 "restore:   ${verdict[$i]}"
    done

    restore_report_mount_state
    restore_report_backup_cost

    if [ "$bad_n" -eq 0 ]; then
        log 0 "restore: all $ok_n dataset(s) in scope recovered."
        return 0
    fi
    if [ "$ok_n" -eq 0 ]; then
        log 0 "restore: NOTHING was recovered -- all $bad_n dataset(s) are named above with the reason."
        return 1
    fi
    log 0 "restore: PARTIAL -- $ok_n recovered, $bad_n did not. The machine is in a mixed state and the datasets that did NOT recover are named above. Exit status is non-zero for exactly that reason: nine of ten is not ten."
    return 1
}


# ------------------------------------------------------------------------------
# DRIVING THE ENGINE -- what a restore actually runs, and the guard in front of it
# ------------------------------------------------------------------------------
#
# The transport is `snapsend.sh`, at the owner's direction: restore under push is
# the push engine run in the other direction, so it arrives with bookmarks,
# resume tokens, compression, the bandwidth cap and the PVE-reserved-snapshot
# refusal already proven. No new transfer code, and the frozen engine is not
# touched.
#
# THE KNOB WAS ALREADY THERE, and it is worth recording how close this came to a
# needless change to a frozen file. `-e` is documented as "use existing latest
# snapshot", which reads like "the newest, and you get no say". The
# implementation filters the candidate list by `-m` FIRST and takes the newest of
# what survives (snapsend.sh, the `if [ -n "$MESSAGE" ]` block inside the
# USE_EXISTING_SNAPSHOT branch). So a FULL snapshot name passed as `-m` leaves
# exactly one candidate, and that one is sent. Measured before relying on it.
#
# WHICH MAKES THE MATCH RULE PART OF THIS CONTRACT. The engine selects with
# `grep "^$MESSAGE"` -- a REGEX, anchored only at the front. Every name this
# project generates is regex-inert, but a passive relationship adopts names from
# a foreign system, and a `.` in one of those matches any character. Measured:
# against `snap.2026`, `snapX2026` and `snap.2026b`, the pattern `^snap.2026`
# matches all three.
#
# So the layer that CHOOSES the recovery point must prove the choice is
# unambiguous before handing it over, using the engine's own rule rather than an
# approximation of it. A restore that silently sent a different snapshot than the
# one the operator picked is the failure this guard exists for, and it would look
# like success.
restore_point_unique() {   # <exact snapshot name> <candidate names, one per line> -> 0 = unambiguous
    local want="$1" candidates="$2" hits
    [ -n "$want" ] || { log 0 "restore: no recovery point was chosen -- refusing to let the engine pick one"; return 1; }

    # The engine's own selector, verbatim. Not `grep -F`, not `=`: this must
    # answer the question "what will snapsend do", and snapsend uses a regex.
    hits="$(printf '%s\n' "$candidates" | grep -c "^$want" 2>/dev/null)" || hits=0
    case "$hits" in
        1)  return 0 ;;
        0)  log 0 "restore: the chosen recovery point '$want' matches no snapshot on the copy. Nothing was changed."
            return 1 ;;
    esac
    log 0 "restore: '$want' matches $hits snapshots on the copy, not one. The engine selects with a regular expression anchored at the front (grep \"^\$MESSAGE\"), so a name carrying '.' or another metacharacter can cover its neighbours -- and sending a different snapshot than the one chosen would look exactly like success. Refusing. The matches are:"
    printf '%s\n' "$candidates" | grep "^$want" 2>/dev/null | while IFS= read -r _m; do
        log 0 "restore:   $_m"
    done
    return 1
}

# The mode is a CLASSIFICATION, never an operator choice (owner decision 4,
# OWNER-RESTORE-GRANT-AND-MODES-2026-08-26): the data says which of the three
# this is, the grant says whether it is permitted, and only then does the engine
# get flags. Deriving the flags HERE, from the same classification the grant was
# checked against, is what stops there being two truths about one run -- the
# planner's and the command line's.
#
#   create   target absent            -> ordinary send; snapsend creates it
#   rewind   common base, GUID-proven -> ordinary incremental; snapsend finds it
#   replace  no valid base            -> -f, which destroys the target and sends full
#
# `-e` and `-m <exact name>` are on every form: a restore never creates a
# snapshot on the copy, and never lets the engine choose the point.
restore_engine_argv() {   # <copy dataset> <account@host:dataset> <exact snapshot> <mode>
    local copy="$1" target="$2" point="$3" mode="$4"
    [ -n "$copy" ]   || { log 0 "restore: no copy dataset to send from"; return 1; }
    [ -n "$target" ] || { log 0 "restore: no target to send to"; return 1; }
    [ -n "$point" ]  || { log 0 "restore: no recovery point"; return 1; }

    RESTORE_ENGINE_ARGV=()
    case "$mode" in
        create|rewind) ;;
        replace)       RESTORE_ENGINE_ARGV+=(-f) ;;
        *) log 0 "restore: '$mode' is not a restore mode -- refusing to build a command for an undefined one"; return 1 ;;
    esac
    # -t: the target is an EXACT dataset, not a base to append the copy's name
    # under. Without it the engine writes hdd/data/hdd/backups/<peer>/hdd/data --
    # measured on the lab before the flag existed.
    # RECURSION. A relationship that covers a subtree must restore the subtree:
    # sending only the parent leaves every child exactly as the disaster left it,
    # while reporting success -- measured on the lab, where the two disks of the
    # VM kept their damage and the run said "all datasets recovered".
    #
    # -r, not -R: one atomic recursive stream lands the whole subtree under the
    # exact target, which is what -t means. -R expands into independent datasets
    # each needing its own name, which is the mapping -t switches off, so the
    # engines refuse that pair.
    #
    # For a restore the atomic form is the stronger guarantee, not a weaker one:
    # the operator asked for the state at a point, and -r gives exactly that
    # across the subtree rather than per dataset.
    #
    # ...unless the SCOPE already lists every descendant, in which case each of
    # them is its own entry with its own classification and its own report, and
    # -r here would send the subtree a second time under a parent that is
    # already at the point. One dataset, one stream. See the expansion in
    # cmd_restore's whole-relation branch for why the scope grew.
    RESTORE_ENGINE_RECURSED=0
    if [ "${RESTORE_SCOPE_EXPANDED:-0}" -ne 1 ] \
       && zfs list -H -o name -d 1 "$copy" 2>/dev/null | grep -qv "^${copy}$"; then
        RESTORE_ENGINE_ARGV+=(-r)
        RESTORE_ENGINE_RECURSED=1
    fi
    RESTORE_ENGINE_ARGV+=(-t -e -m "$point" )
    # The relationship's own key, in the engine's flag spelling. Word-split
    # deliberately: these are flags and paths, none of which carry a space in
    # this project. Empty for a local restore, which opens no connection.
    if [ -n "${RESTORE_ENGINE_SSH:-}" ]; then
        # shellcheck disable=SC2206
        RESTORE_ENGINE_ARGV+=(${RESTORE_ENGINE_SSH})
    fi
    RESTORE_ENGINE_ARGV+=("$copy" "$target")
    return 0
}

# Ask the target what it permits. ONE question, over the relationship's own ssh
# path, answered by zfs-pair-gate -- which derives the relationship from the KEY,
# so this cannot ask about a relationship it does not hold a key for.
#
# Fails CLOSED and silently here: an unreachable host, a refused command, a
# timeout and a host that answered nothing all produce the same empty string,
# and restore_grant_parse then refuses. The diagnosis belongs to the caller,
# which knows which dataset it was for; a message printed here would arrive
# without that context and be repeated per dataset.
restore_grant_ask() {   # <account@host> -> the gate's answer, or nothing
    local peer="$1"
    [ -n "$peer" ] || return 1
    ssh -n ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$peer" "PAIR-CONTROL status" 2>/dev/null
}


# Phase 7 -- the destructive execution step itself, INTERNAL ONLY.
#
# Everything before this has proven the strategy, measured and confirmed the loss
# set, raised the write fence and shown the commit boundary held. This is the one
# place that actually destroys and rebuilds source state. It runs with the fence
# already UP, which is safe and verified live (pve0, zfs-2.1.9): neither
# `zfs rollback` nor incremental `zfs recv` is a userland write, so readonly=on
# does not block them -- it only blocks the ordinary writers the fence exists to
# keep out.
#
# The primitive for every reachable strategy is: destroy exactly the approved
# objects, then a NON-recursive rollback to the base.
#
#   rollback / discard-live / unproven -- the recovery point ALREADY exists on the
#       source (base guid == target guid), so landing the source back on it IS the
#       whole operation. The approved blockers and this run's own technical
#       snapshots are destroyed by name, the approved bookmarks likewise, and the
#       rollback then discards the live writes. Cleanup afterwards is a no-op.
#
#   increment -- the same sequence lands the source exactly on the common base;
#       one incremental receive base..target then rebuilds it to the recovery
#       point. The source is at the base and fenced, so a plain `recv` applies
#       cleanly (verified live).
#
# It used to be one `zfs rollback -r`, which was atomic and convenient and wrong:
# `-r` decides for itself what is newer than the base, so it could consume an
# object that appeared after the operator approved the set (REV-120, both rounds).
# Naming the objects gives that up for a property worth more than atomicity --
# execution cannot widen the approved set, by construction rather than by timing.
#
# Acceptance is by GUID, never by exit code (C-006/C-007): the snapshot carrying
# RESTORE_TARGET_GUID must exist on the source afterwards and nothing may be newer
# than it, or the run FAILED however cleanly the commands returned. A partial
# incremental leaves the source rolled back to the base but short of the target --
# that is real destruction without completion, and the caller says so rather than
# claiming a clean source.
#
# REV-120 F2: the acceptance test resolves the target by IDENTITY and then checks
# the required final state around it. It used to read `-s creation | tail -1` and
# call that the head, which is a guess whenever two snapshots share a creation
# second -- the boundary condition this project keeps measuring in the wild. A
# correct restore could be reported as a partial failure, or an incorrect one
# accepted, depending on which of two equal-valued rows `zfs list` happened to
# print last. Nothing here infers order from `creation` any more.
#
# Three outcomes, so the caller can be exact about what the operator is holding:
#   0 -- verified success.
#   1 -- failed with NOTHING destroyed: every precondition and the exact-set
#        measurement come first, and the one call that removes the approved
#        snapshots removes all of them or none. The caller may make the
#        unchanged-source claim.
#   2 -- failed AFTER destruction began. Since REV-120 round 2 this includes a
#        late unapproved object making the non-recursive rollback refuse: the
#        approved objects are gone, the late one is untouched, and the source is
#        NOT as it was found. Also a broken incremental or a failed final check.
# A diagnosis is printed to stderr. The caller owns the fence and the
# technical-snapshot cleanup.
# ------------------------------------------------------------------------------
# THE GRANT CHECK -- the collector reading the target's permission to overwrite it
# ------------------------------------------------------------------------------
#
# Owner decision, 2026-08-26/27: the COLLECTOR starts a restore and writes onto
# the machine being recovered. So the machine at risk is not the one running the
# command, and the only thing standing between "restore me when I ask" and
# "overwrite me whenever you like" is a fact that machine published itself:
# a restore grant (deploy.sh --allow-restore, see test/restoregrant).
#
# WHAT MAKES THIS PARSER SECURITY CODE RATHER THAN STRING HANDLING: its input
# arrives from ANOTHER MACHINE, over ssh, and the decision it produces is
# "may I destroy that machine's data". Every ambiguity therefore resolves to NO.
# The shapes that must not be readable as a yes:
#
#   * two RESTORE_GRANT_MODES lines -- a peer that answers twice has not
#     answered once, and taking either would be picking on the peer's behalf;
#   * an answer whose PAIR_LABEL is not the relationship we asked about -- the
#     gate derives the label from the KEY, so a mismatch means the answer is
#     about something else and cannot authorise this;
#   * `present` with no modes, modes with no `present`, or a modes value
#     carrying anything but lowercase letters and single spaces;
#   * no answer at all, an empty answer, an ssh banner with nothing in it.
#
# The ONLY yes is: exactly one PAIR_LABEL matching, exactly one
# RESTORE_GRANT=present, exactly one well-formed RESTORE_GRANT_MODES.
restore_grant_parse() {   # <label we asked about> <the peer's answer> -> modes, or nothing (rc 1)
    local want_label="$1" answer="$2" labels modes present

    [ -n "$answer" ] || return 1

    # Exactly one of each key. `grep -c` on an anchored pattern, so a line the
    # peer indented or appended text to does not count -- the gate emits these
    # at column zero and nothing else may look like them.
    labels=$(printf '%s\n' "$answer" | grep -c '^PAIR_LABEL=')
    [ "$labels" -eq 1 ] || return 1
    # An EMPTY want_label means "whatever the key bound". Measured on the lab:
    # the collector does not record the peer-side label anywhere -- the peer
    # chose it at join time and kept it -- so demanding a match was a check that
    # could never pass in production.
    #
    # The property it protected survives by a stronger mechanism than a string
    # comparison: zfs-pair-gate derives the label from the KEY in its forced
    # command, never from anything the caller says. An answer therefore concerns
    # the relationship whose key opened the connection, and this side chose that
    # key from the relationship record. A peer cannot answer about a different
    # relationship even if it wanted to. When the caller DOES know the label it
    # is still required to match -- then the comparison is free.
    if [ -n "$want_label" ]; then
        [ "$(printf '%s
' "$answer" | sed -n 's/^PAIR_LABEL=//p')" = "$want_label" ] || return 1
    fi

    present=$(printf '%s\n' "$answer" | grep -c '^RESTORE_GRANT=present$')
    [ "$present" -eq 1 ] || return 1

    [ "$(printf '%s\n' "$answer" | grep -c '^RESTORE_GRANT_MODES=')" -eq 1 ] || return 1
    modes=$(printf '%s\n' "$answer" | sed -n 's/^RESTORE_GRANT_MODES=//p')

    # Whitelist. This value decides whether data gets destroyed; it came off a
    # wire; and it is about to be compared against a mode name. Anything that is
    # not lowercase letters and single spaces is not something this project
    # writes, so it is not a grant.
    case "$modes" in
        ''|*[!a-z\ ]*|' '*|*' ') return 1 ;;
        *'  '*)                  return 1 ;;
    esac
    printf '%s' "$modes"
    return 0
}

# -> 0 when the peer's answer authorises <mode> for <label>; 1 otherwise, having
#    said exactly what is missing and where to fix it.
#
# The remedy is always a command to run ON THE TARGET, never here. That is the
# whole point: this side cannot grant itself anything, so the message must send
# the operator to the machine that can.
restore_grant_require() {   # <label> <peer answer> <needed mode> <target host, for the message>
    local label="$1" answer="$2" need="$3" host="${4:-the target host}" modes
    # THE LABEL IN THE MESSAGE COMES FROM THE ANSWER, because the caller does
    # not have one. restore_grant_parse accepts an empty label deliberately --
    # the collector never records the peer-side name, which the peer chose at
    # join time -- and every refusal below then interpolated that empty string
    # straight into the remedy it printed:
    #
    #     restore: '...' grants relationship '' only 'create rewind'
    #     restore:     deploy.sh --allow-restore= --replace
    #
    # Measured on the lab, 2026-08-27. The command is not merely unhelpful: an
    # empty --allow-restore= is the exact input that fell past the grant dispatch
    # in deploy.sh and started reinstalling the host (error log E1). The refusal
    # was telling the operator to run it.
    #
    # zfs-pair-gate puts PAIR_LABEL in its answer and derives it from the KEY in
    # its own forced command, so it is the authoritative name and it is already
    # here. Used only for DISPLAY -- the authorisation decision is unchanged and
    # still belongs to restore_grant_parse.
    local shown="$label"
    if [ -z "$shown" ]; then
        shown="$(printf '%s
' "$answer" | sed -n 's/^PAIR_LABEL=//p' | head -1)"
    fi
    local grant_cmd
    if [ -n "$shown" ]; then
        grant_cmd="deploy.sh --allow-restore=$shown"
    else
        # Still nothing. Then the message must not fabricate a command: name the
        # one step that produces the missing word.
        shown="<unknown -- that machine did not name it>"
        grant_cmd="deploy.sh --allow-restore=<the label that machine knows this relationship by; PAIR-CONTROL status there prints it>"
    fi
    case "$need" in
        create|rewind|replace) ;;
        *) log 0 "restore: '$need' is not a restore mode -- refusing rather than asking for something undefined"; return 1 ;;
    esac

    if ! modes="$(restore_grant_parse "$label" "$answer")"; then
        log 0 "restore: '$host' did not publish a usable restore grant for relationship '$shown', so it has NOT agreed to be written to. Nothing was changed."
        log 0 "restore: if that machine really is the one to recover, grant it THERE, as root:"
        if [ "$need" = replace ]; then
            log 0 "restore:     $grant_cmd --replace"
            log 0 "restore: '--replace' is required here because this recovery would DESTROY data that machine holds now. Without it a grant only permits writing where there is free space."
        else
            log 0 "restore:     $grant_cmd"
        fi
        log 0 "restore: this side cannot grant itself anything -- that is what makes the grant worth having."
        return 1
    fi

    case " $modes " in
        *" $need "*) return 0 ;;
    esac

    log 0 "restore: '$host' grants relationship '$shown' only '$modes', and this recovery needs '$need'. Nothing was changed."
    if [ "$need" = replace ]; then
        log 0 "restore: 'replace' DESTROYS data that is on that machine now and puts an older copy in its place. It is never implied by a grant -- it is named in one, deliberately, when nothing is broken:"
        log 0 "restore:     $grant_cmd --replace     (run as root ON $host)"
    else
        log 0 "restore:     $grant_cmd     (run as root ON $host)"
    fi
    return 1
}

restore_execute() {   # <src> <copy> <this run's own technical snapshots, full names...>
    local src="$1" copy="$2"; shift 2
    local own="" s
    for s in "$@"; do [ -n "$s" ] && own="${own}${s}"$'\n'; done

    # Preconditions FIRST, all before the rollback, so a failure here is a clean 1.
    [ -n "$RESTORE_SRC_BASE_SNAP" ] && [ -n "$RESTORE_SRC_BASE_TXG" ] || {
        echo "restore-exec: brak snapshotu bazowego na zrodle '$src' -- nie wiem, do ktorego punktu cofnac. Nic nie zmieniono." >&2
        return 1
    }
    [ "$RESTORE_SET_STATE" = ok ] || {
        echo "restore-exec: zbior obiektow nowszych niz baza na '$src' nie zostal dowiedziony, wiec nie wiem, co ten rollback zniszczy. Nic nie zmieniono." >&2
        return 1
    }
    if [ "$RESTORE_STRATEGY" = increment ]; then
        [ -n "$RESTORE_COPY_BASE_SNAP" ] && [ -n "$RESTORE_TARGET_SNAP" ] || {
            echo "restore-exec: brak nazwy snapshotu bazy kopii lub punktu docelowego -- nie moge zlozyc przyrostu. Nic nie zmieniono." >&2
            return 1
        }
    fi

    # REV-120 F1: the last thing before the destructive command is a re-measurement
    # of what it will actually destroy, compared for EXACT EQUALITY against what the
    # operator approved.
    #
    # The confirmation boundary above proves the source had not changed as of the
    # commit snapshot. This closes the only window left after it, and it is the
    # window where a bookmark can still appear: `readonly=on` fences userland
    # writes, and `zfs bookmark` is not one -- no more than `zfs snapshot` is. So
    # the fence cannot be the argument here; a measurement can.
    #
    # The approved set is the blockers and bookmarks the operator saw, plus this
    # run's own technical snapshots, which are newer than the base and which the
    # rollback therefore also takes. Anything else present, or anything approved
    # that has since disappeared, means the destructive set is no longer the
    # approved one -- refuse, before destroying anything, and let the operator
    # re-run against the state that actually exists.
    local approved observed exsnap exbm
    approved="$(printf '%s\n%s\n%s' "$RESTORE_BLOCKERS" "$RESTORE_BLOCK_BOOKMARKS" "$own" | grep -v '^$' | sort)"
    exsnap="$(zfs list -H -p -t snapshot -o name,createtxg -d 1 "$src" 2>/dev/null)" || {
        echo "restore-exec: nie udalo sie odczytac snapshotow '$src' tuz przed zniszczeniem -- nie potwierdze, ze zbior do zniszczenia jest tym zatwierdzonym. Nic nie zmieniono." >&2
        return 1
    }
    exbm="$(zfs list -H -p -t bookmark -o name,createtxg -d 1 "$src" 2>/dev/null)" || {
        echo "restore-exec: nie udalo sie odczytac bookmarkow '$src' tuz przed zniszczeniem -- 'zfs rollback -r' kasuje rowniez je, wiec bez tej listy nie znam zbioru strat. Nic nie zmieniono." >&2
        return 1
    }
    observed="$(printf '%s\n%s\n' "$exsnap" "$exbm" \
                | awk -F'\t' -v t="$RESTORE_SRC_BASE_TXG" 'NF>=2 && ($2+0)>(t+0){print $1}' | sort)"
    if [ "$approved" != "$observed" ]; then
        echo "restore-exec: zbior do zniszczenia NIE jest tym zatwierdzonym -- stan zrodla '$src' zmienil sie po potwierdzeniu." >&2
        printf '%s\n' "$observed" | grep -v '^$' | grep -F -x -v -f <(printf '%s\n' "$approved") \
            | sed 's/^/    doszlo (NIE zatwierdzone, zostaloby zniszczone): /' >&2
        printf '%s\n' "$approved" | grep -v '^$' | grep -F -x -v -f <(printf '%s\n' "$observed") \
            | sed 's/^/    zniklo (zatwierdzone, juz go nie ma): /' >&2
        echo "restore-exec: nic nie zniszczono. Uruchom ponownie -- zobaczysz aktualny zbior i zdecydujesz na nim." >&2
        return 1
    fi

    # ---- destruction, shaped so that it CANNOT reach an unapproved object -----
    #
    # REV-120 round 2. The measurement above narrows the window; it cannot close
    # it. `zfs rollback -r` decides for itself what is newer than the base, so a
    # bookmark created in the microseconds after the measurement was destroyed
    # unapproved -- and no amount of re-reading fixes that, because the read and
    # the destruction are still two separate moments. The shape of the commands
    # has to carry the property instead of the timing.
    #
    # Every destructive call below is therefore one of exactly two kinds:
    #
    #   * `zfs destroy` naming the approved objects EXPLICITLY. It can only ever
    #     touch what it names, whatever arrives meanwhile.
    #   * a NON-recursive `zfs rollback`, whose own semantics refuse when any
    #     newer snapshot or bookmark exists. ZFS itself is the guard, evaluated
    #     inside the command rather than before it.
    #
    # Measured on zfs-2.1.9 and zfs-2.2.2: the non-recursive refusal names the
    # offending objects, destroys nothing, and leaves live data in place.
    #
    # The snapshots go in ONE call -- `zfs destroy ds@a,b,c` removes them together,
    # so the bulk of the loss set keeps the atomicity the recursive rollback had,
    # and the most likely failure (a hold, a busy dataset) still happens before
    # anything is destroyed. Bookmarks cannot join it: measured, the comma form is
    # snapshot-only (`bookmark 'ds#b1,b2' does not exist`), so they go one by one.
    #
    # The price is honest and named in the response: destruction now begins before
    # the rollback, so a late arrival is a partial failure (2) rather than a clean
    # refusal (1). Approved objects are destroyed; unapproved ones cannot be. That
    # is the trade the previous shape had backwards.
    #
    # ZFS's own stderr is deliberately NOT suppressed on the execution primitives,
    # unlike the read/probe calls above. This is the one place where a failure is
    # both destructive and hard to diagnose, and "it failed" without ZFS's reason
    # ("dataset is busy", "more recent snapshots or bookmarks exist") sends the
    # operator debugging blind at the worst possible moment.
    local snapnames="" b
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        snapnames="${snapnames:+$snapnames,}${b#*@}"
    done <<< "$(printf '%s\n%s' "$RESTORE_BLOCKERS" "$own" | grep -v '^$')"

    local destroyed=0
    if [ -n "$snapnames" ]; then
        if ! zfs destroy "${src}@${snapnames}"; then
            echo "restore-exec: nie udalo sie usunac zatwierdzonych snapshotow zrodla ('${src}@${snapnames}'). To jedno wywolanie obejmujace caly zbior, wiec albo zniknely wszystkie, albo zaden -- ZFS zglosil blad, czyli nie zniknal zaden. Nic nie zniszczono." >&2
            return 1
        fi
        destroyed=1
    fi
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        if ! zfs destroy "$b"; then
            echo "restore-exec: nie udalo sie usunac zatwierdzonego bookmarka '$b'. Bookmarkow nie da sie usunac jednym wywolaniem (skladnia z przecinkiem dziala tylko dla snapshotow), wiec czesc zatwierdzonego zbioru moze byc juz usunieta." >&2
            [ "$destroyed" -eq 1 ] && return 2
            return 1
        fi
        destroyed=1
    done <<< "$RESTORE_BLOCK_BOOKMARKS"

    # The recovery point is now the newest snapshot on the source, so a plain
    # rollback is legal -- and it is the guard: if anything newer than the base
    # appeared after the measurement above, ZFS refuses here and destroys nothing,
    # including the late object.
    if ! zfs rollback "$RESTORE_SRC_BASE_SNAP"; then
        if [ "$destroyed" -eq 1 ]; then
            echo "restore-exec: ZFS odmowil cofniecia zrodla do '$RESTORE_SRC_BASE_SNAP' (powod wyzej) -- na zrodle jest cos NOWSZEGO niz punkt docelowy, czego nie bylo w zatwierdzonym zbiorze. Tego obiektu NIE usunieto i nie zostanie usuniety. Zatwierdzony zbior zostal juz jednak usuniety, wiec zrodlo NIE jest w stanie sprzed polecenia." >&2
            return 2
        fi
        echo "restore-exec: cofniecie zrodla do '$RESTORE_SRC_BASE_SNAP' nie powiodlo sie (powod wyzej). Nic nie zniszczono." >&2
        return 1
    fi

    # Past this line the source HAS been rolled back -- any failure is a 2.
    # increment: the rollback landed the source on the common base; rebuild it up
    # to the recovery point with one incremental receive.
    if [ "$RESTORE_STRATEGY" = increment ]; then
        if ! zfs send -i "$RESTORE_COPY_BASE_SNAP" "${copy}@${RESTORE_TARGET_SNAP}" | zfs recv "$src"; then
            echo "restore-exec: przyrostowy transfer '${RESTORE_COPY_BASE_SNAP} .. ${copy}@${RESTORE_TARGET_SNAP}' -> '$src' nie powiodl sie. Zrodlo zostalo COFNIETE do wspolnej bazy, ale NIE doprowadzone do punktu docelowego." >&2
            return 2
        fi
    fi

    # Acceptance test (REV-120 F2). Two facts, both required, neither inferred from
    # ordering:
    #
    #   1. the snapshot carrying RESTORE_TARGET_GUID EXISTS on the source -- looked
    #      up by identity, and exactly one row may carry it;
    #   2. nothing on the source is newer than it -- no snapshot, no bookmark --
    #      measured by createtxg against that row's own createtxg.
    #
    # Together those are the required final state. The old check asked whether the
    # LAST row of a creation-sorted listing carried the target guid, which answers
    # neither question when two rows share a creation second: a correct restore
    # could be reported as a partial failure because the peer sorted last, and the
    # verdict would depend on ZFS's incidental tie ordering rather than on identity.
    #
    # Everything here runs after the rollback, so every failure is a 2 -- including
    # a read that fails. An unverifiable final state is not a success.
    local vsnap vbm tline tcount ttxg newer
    vsnap="$(zfs list -H -p -t snapshot -o name,guid,createtxg -d 1 "$src" 2>/dev/null)" || {
        echo "restore-exec: nie udalo sie odczytac snapshotow '$src' po operacji -- stanu koncowego NIE potwierdzono. Zrodlo zostalo juz zmienione." >&2
        return 2
    }
    vbm="$(zfs list -H -p -t bookmark -o name,createtxg -d 1 "$src" 2>/dev/null)" || {
        echo "restore-exec: nie udalo sie odczytac bookmarkow '$src' po operacji -- stanu koncowego NIE potwierdzono. Zrodlo zostalo juz zmienione." >&2
        return 2
    }
    tline="$(printf '%s\n' "$vsnap" | awk -F'\t' -v g="$RESTORE_TARGET_GUID" '$2==g{print $1"\t"$3}')"
    tcount="$(printf '%s\n' "$tline" | grep -c .)"
    if [ "$tcount" -ne 1 ]; then
        if [ "$tcount" -eq 0 ]; then
            echo "restore-exec: weryfikacja GUID zawiodla -- na '$src' NIE MA snapshotu o guidzie '$RESTORE_TARGET_GUID' (punkt docelowy '${RESTORE_TARGET_SNAP}'). Stan zrodla NIE jest potwierdzony jako punkt docelowy." >&2
        else
            echo "restore-exec: weryfikacja GUID zawiodla -- guid '$RESTORE_TARGET_GUID' wystepuje na '$src' $tcount razy, wiec tozsamosc punktu docelowego jest niejednoznaczna. Stan zrodla NIE jest potwierdzony." >&2
        fi
        return 2
    fi
    ttxg="${tline##*	}"
    newer="$( { printf '%s\n' "$vsnap" | awk -F'\t' 'NF>=3{print $1"\t"$3}'
                printf '%s\n' "$vbm"   | awk -F'\t' 'NF>=2{print $1"\t"$2}'; } \
              | awk -F'\t' -v t="$ttxg" 'NF>=2 && ($2+0)>(t+0){print $1}')"
    if [ -n "$newer" ]; then
        echo "restore-exec: weryfikacja stanu koncowego zawiodla -- punkt docelowy '$RESTORE_TARGET_SNAP' (guid $RESTORE_TARGET_GUID) jest na '$src', ale cos jest od niego NOWSZE:" >&2
        printf '%s\n' "$newer" | sed 's/^/    /' >&2
        echo "restore-exec: zrodlo NIE stoi na zadanym punkcie. Zostalo juz zmienione." >&2
        return 2
    fi
    return 0
}

# Phase 7, the destructive recovery path -- resolves, gates, measures, confirms,
# fences, and now EXECUTES. INTERNAL ONLY.
#
# The owner's default recovery is "latest valid backup -> the original source
# path", which means destroying source state. This resolves the relationship,
# refuses everything it cannot prove it understands, prints the same preview
# `--plan` prints, measures and confirms the loss set, fences the source, checks
# the commit boundary held, and then -- via restore_execute -- performs the
# destructive step and verifies the result by GUID.
#
# NOT REACHABLE FROM THE CLI, on purpose (R-018/R-019/R-026). The owner is still
# deciding the public restore selector/destination grammar, so committing a flag
# now would freeze a surface that is not theirs yet -- and a public flag is much
# harder to withdraw than to add. The internal primitive and its tests are settled
# and can be built underneath it; the door on top gets hung when the owner has
# decided what shape it is. The suite calls this function directly.
#
# The confirmation is real now that the destruction it guards exists: it is shown
# the ZMIERZONY loss set (measured from a technical snapshot, per REV-119 F1) and
# then asked, unless --yes was given.
#
# REV-119 F1: the confirmation boundary MUST take a technical snapshot before it
# can state the loss set exactly -- see the block further down. Every technical
# snapshot is removed again on every exit path (the execution step destroys them
# by name, as part of the approved set), so a refusal still leaves the source
# byte-identical to how it was found and a success leaves nothing of this run
# behind.
restore_replace_internal() {   # <dataset> <config> <yes>
    local dataset="$1" config="$2" yes="$3"
    [ -n "$dataset" ] || die "restore (odtworzenie niszczace): nazwij co odtwarzac (dataset zrodla albo kopii). Bez tego nie ma pytania."

    read_server_conf
    [ -n "$config" ] || config="${CRON_CONFIG:-}"
    [ -n "$config" ] || die "restore (odtworzenie niszczace): no cron config known -- pass --config=FILE or run setup-server"
    [ -r "$config" ] || die "restore (odtworzenie niszczace): cannot read $config"

    local a b c d src="" copy="" kind="" cons="" hits=0
    while IFS=$'\t' read -r a b c d; do
        [ -n "$a" ] || continue
        if [ "$a" = "$dataset" ] || [ "$b" = "$dataset" ]; then
            src="$a"; copy="$b"; kind="$c"; cons="$d"; hits=$((hits+1))
        fi
    done <<< "$(restore_relations "$config")"
    [ "$hits" -ne 0 ] || die "restore (odtworzenie niszczace): '$dataset' nie wystepuje w zadnej relacji backupu w $config -- 'restore --plan' pokaze te, ktore istnieja"
    # More than one match is not something to resolve by picking the first. Two
    # relationships naming the same path mean the CONFIG disagrees with itself
    # about where that data lives, and guessing which one to restore FROM is the
    # last guess anybody wants made on their behalf.
    [ "$hits" -eq 1 ] || die "restore (odtworzenie niszczace): '$dataset' pasuje do $hits relacji w $config -- nie zgaduje ktora; nazwij dokladny dataset zrodla albo kopii"

    # An atomic relationship is a SUBTREE recovered as one point in time. This
    # verb recovers one dataset, so running it against an atomic relationship
    # would silently turn a point-in-time recovery into a per-dataset one -- the
    # exact confusion R-013 made the planner spell out.
    [ "$cons" != atomic ] || die "restore (odtworzenie niszczace): '$src' jest w relacji ATOMIC (spojne poddrzewo w jednym punkcie czasu), a ten czasownik odtwarza pojedynczy dataset. Odtworzenie tylko jego zlamaloby wlasnosc, dla ktorej ta relacja jest atomowa. Odtwarzanie poddrzew nie istnieje."

    local snaps
    snaps=$(zfs list -H -p -t snapshot -o name,creation,guid -s creation -d 1 "$copy" 2>/dev/null) || snaps=""
    [ -n "$snaps" ] || die "restore (odtworzenie niszczace): kopia '$copy' nie ma ani jednego snapshota, wiec nie ma z czego odtwarzac"

    echo
    echo "ODTWORZENIE NISZCZACE -- podglad. Nic nie zostalo jeszcze zmienione."
    echo "  Zrodlo:     $src   (CEL odtworzenia: to jego stan zostanie zmieniony)"
    echo "  Kopia:      $copy  (zrodlo danych)"
    echo "  Relacja:    $kind"
    restore_plan_strategy "$copy" "$src" "$snaps"
    echo

    case "$RESTORE_STRATEGY" in
        remote)
            die "restore (odtworzenie niszczace): zrodlo '$src' jest ZDALNE, a zdalny wykonawca jeszcze nie istnieje. To, czego brakowalo tu wczesniej -- KTO wykonuje zniszczenie po tamtej stronie -- jest juz rozstrzygniete: kolektor zaczyna, a maszyna zagrozona publikuje zgode (deploy.sh --allow-restore). Sprawdzenie tej zgody jest zbudowane i przetestowane (restore_grant_require). Brakuje ostatniego kawalka: samego przeslania i zniszczenia po tamtej stronie. Nic nie zmieniono." ;;
        full-absent|full-live)
            die "restore (odtworzenie niszczace): nie ma wspolnej bazy dowiedzionej GUID-em, wiec jedyna droga jest PELNE zastapienie -- inny mechanizm i inne ryzyko niz przyrost. Nie istnieje w tym wycinku i nie bedzie udawane przyrostem." ;;
        ambiguous)
            die "restore (odtworzenie niszczace): punkt docelowy na kopii '$copy' jest NIEJEDNOZNACZNY (szczegoly wyzej). Ten czasownik cofa zrodlo do jednego punktu, wiec zgadniecie ktorego zniszczyloby stan pod decyzje, ktorej nikt nie podjal. Nic nie zmieniono." ;;
        increment|rollback|discard-live|unproven) ;;
        *)  die "restore (odtworzenie niszczace): nie ustalono strategii dla '$src' -- odmawiam dzialania na nieokreslonym stanie" ;;
    esac

    # REV-120 F1: the loss set has to be COMPLETE before it can be shown, and its
    # completeness is a fact the planner either established or did not. Refuse here,
    # before the first mutation, rather than presenting a list that may be missing
    # the very object this run would destroy.
    [ -n "$RESTORE_SRC_BASE_SNAP" ] && [ -n "$RESTORE_SRC_BASE_TXG" ] \
        || die "restore (odtworzenie niszczace): nie udalo sie jednoznacznie wskazac snapshotu bazowego na '$src' po guidzie $RESTORE_BASE_GUID. Bez niego nie wiem, do ktorego punktu cofnac ani co jest od niego nowsze. Nic nie zmieniono."
    [ "$RESTORE_SET_STATE" = ok ] \
        || die "restore (odtworzenie niszczace): nie udalo sie ustalic pelnego zbioru snapshotow i bookmarkow '$src' nowszych niz wspolna baza. 'zfs rollback -r' kasuje jedne i drugie, wiec bez tej listy pytanie o zgode dotyczyloby zbioru, ktorego nikt nie zna. Nic nie zmieniono."

    # ---- REV-119 F1: the confirmation has to be INFORMED -------------------
    #
    # The read-only preview above cannot state the live loss exactly, and REV-118
    # is the proof: `written` on a live dataset reflects the last committed txg,
    # so a write made seconds ago is invisible to it. Asking for approval on that
    # basis asks the operator to approve a set nobody has measured.
    #
    # A snapshot is a committed point, so taking one BEFORE the loss set is shown
    # turns the estimate into a fact. That is a mutation, and it reverses this
    # path's earlier "not even a snapshot" rule -- deliberately: the mutation is
    # what buys the property, and there is no read-only way to buy it.
    #
    # It is NOT preservation and must never be described as such: it is part of
    # the set the execution step destroys by name. It is a measurement, and the
    # operator text says measurement.
    local stamp="$$-$(date +%s)-${RANDOM}"
    local preview_snap="restore-preview-$stamp" commit_snap="restore-commit-$stamp"

    zfs snapshot "${src}@${preview_snap}" 2>/dev/null \
        || die "restore (odtworzenie niszczace): nie udalo sie zrobic technicznego snapshota '${src}@${preview_snap}'. Bez niego nie umiem podac DOKLADNEGO zbioru strat, a pytanie o zgode na niezmierzony zbior nie jest zgoda swiadoma. Nic nie zmieniono."

    # REV-119 F1.1: the snapshot SET, captured as identities. The previous version
    # decided what was new by position in a list sorted by wall-clock `creation`,
    # which is not a total order -- two snapshots made in the same second can come
    # back in either order, so an intruder could sort BEFORE the preview snapshot
    # and never appear in the "newer" set. That is not a display problem: an
    # intervening snapshot also shortens the interval the byte measurement covers,
    # so the run could come back green while measuring the wrong window.
    #
    # A set difference has no ordering in it at all, so there is nothing to get
    # wrong.
    #
    # REV-120 F1: the same capture covers BOOKMARKS. The fence does not keep them
    # out -- `zfs bookmark` is no more a userland write than `zfs snapshot` is --
    # and `zfs rollback -r` destroys the newer ones, so a bookmark arriving after
    # the approval is state that would be destroyed without ever having been shown.
    local snapset_before bmset_before
    snapset_before="$(zfs list -H -t snapshot -o name -d 1 "$src" 2>/dev/null | sort)"
    bmset_before="$(zfs list -H -t bookmark -o name -d 1 "$src" 2>/dev/null | sort)"

    local live_exact
    live_exact="$(zfs get -Hp -o value written "${src}@${preview_snap}" 2>/dev/null)"
    case "$live_exact" in ''|*[!0-9]*) live_exact="" ;; esac

    echo "  DO ZNISZCZENIA -- zbior ZMIERZONY, nie oszacowany:"
    local b used total=0
    if [ -n "$RESTORE_BLOCKERS" ]; then
        while IFS= read -r b; do
            [ -n "$b" ] || continue
            used="$(zfs get -Hp -o value used "$b" 2>/dev/null)"
            case "$used" in ''|*[!0-9]*) used=0 ;; esac
            printf '    snapshot  %-40s %s B\n' "${b#*@}" "$used"
            total=$((total + used))
        done <<< "$RESTORE_BLOCKERS"
    fi
    # REV-120 F1: bookmarks are part of the destructive set, so they are part of the
    # set the operator approves. They contribute 0 B by construction -- a bookmark is
    # a createtxg and a guid, nothing more -- so the byte total stays exact; what is
    # lost is the ability to send incrementally from that point ever again, which the
    # line says instead of pretending the loss is measured in bytes.
    if [ -n "$RESTORE_BLOCK_BOOKMARKS" ]; then
        while IFS= read -r b; do
            [ -n "$b" ] || continue
            printf '    bookmark  %-40s %s B\n' "${b#*#}" 0
        done <<< "$RESTORE_BLOCK_BOOKMARKS"
        echo "      (bookmark nie zajmuje miejsca, ale jest nowszy niz punkt docelowy, wiec"
        echo "       zostanie usuniety -- tracisz punkt zaczepienia przyszlego wysylania"
        echo "       przyrostowego, bezpowrotnie)"
    fi
    if [ -n "$live_exact" ]; then
        printf '    dane zapisane po ostatnim snapshocie zrodla:   %s B\n' "$live_exact"
        total=$((total + live_exact))
        echo "      (zamrozone w '${preview_snap}' -- to POMIAR, nie kopia bezpieczenstwa:"
        echo "       odtworzenie niszczy rowniez ten snapshot)"
    else
        # Refuse rather than show a set with a hole in it. An operator cannot give
        # informed consent to "everything above, plus an unknown amount".
        restore_die_after_cleanup "$src" ok \
            "restore (odtworzenie niszczace): nie udalo sie zmierzyc danych zapisanych po ostatnim snapshocie '$src'. Nie pokaze zbioru strat z dziura w srodku. Nic nie zniszczono." \
            "$preview_snap"
    fi
    printf '    RAZEM: %s B\n' "$total"
    echo

    if [ "$yes" -ne 1 ]; then
        local ans
        read -rp "Zniszczyc powyzsze i odtworzyc '$src' z kopii? [t/N] " ans
        case "$ans" in
            t|T|tak|TAK|y|Y|yes|YES) ;;
            *) restore_die_after_cleanup "$src" ok \
                   "restore (odtworzenie niszczace): niepotwierdzone -- nic nie zniszczono." \
                   "$preview_snap" ;;
        esac
    fi

    # ---- the commit boundary -----------------------------------------------
    #
    # An accurate preview at T1 does not stay true. A write or a snapshot can
    # arrive between the preview and the destructive step, and destroying it
    # would destroy state nobody approved -- the same TOCTOU shape REV-114 found
    # in the safe path, in a place where the consequence is worse.
    #
    # The fence goes up FIRST. Raising it after the check would leave the same
    # window open one step further along: the check would prove nothing arrived,
    # and a write could still land before the fence. With the fence up first, the
    # check below covers the only window that remains -- preview to fence -- and
    # nothing can be added after it.
    #
    # REV-119 F1.2: capture BEFORE mutating. Everything after this line has enough
    # saved state to put the property back, including the path where the fence
    # went up but could not be verified.
    local fence_state fence_val fence_src fence_after=ok
    fence_state="$(restore_fence_capture "$src")" || {
        restore_die_after_cleanup "$src" ok \
            "restore (odtworzenie niszczace): nie udalo sie odczytac wlasciwosci 'readonly' na '$src', wiec nie umiem jej pozniej przywrocic i nie zaczne jej zmieniac. Nic nie zniszczono." \
            "$preview_snap"
    }
    fence_val="${fence_state%% *}"; fence_src="${fence_state##* }"

    if ! restore_fence_raise "$src"; then
        # The set may have gone through and only the verification failed, so the
        # undo is attempted unconditionally rather than guessed at.
        fence_after=ok
        restore_fence_lower "$src" "$fence_val" "$fence_src" || fence_after=dirty
        restore_die_after_cleanup "$src" "$fence_after" \
            "restore (odtworzenie niszczace): nie udalo sie zablokowac zapisu na '$src' (readonly=on). Bez tej blokady nie umiem zagwarantowac, ze miedzy sprawdzeniem a zniszczeniem nikt nic nie dopisze. Nic nie zniszczono." \
            "$preview_snap"
    fi

    zfs snapshot "${src}@${commit_snap}" 2>/dev/null || {
        fence_after=ok
        restore_fence_lower "$src" "$fence_val" "$fence_src" || fence_after=dirty
        restore_die_after_cleanup "$src" "$fence_after" \
            "restore (odtworzenie niszczace): nie udalo sie zamknac granicy zatwierdzenia na '$src'. Nic nie zniszczono." \
            "$preview_snap"
    }

    local arrived unexpected unexpected_bm snapset_after bmset_after
    arrived="$(zfs get -Hp -o value written "${src}@${commit_snap}" 2>/dev/null)"
    snapset_after="$(zfs list -H -t snapshot -o name -d 1 "$src" 2>/dev/null | sort)"
    bmset_after="$(zfs list -H -t bookmark -o name -d 1 "$src" 2>/dev/null | sort)"
    unexpected="$(printf '%s\n' "$snapset_after" \
                  | grep -F -x -v -f <(printf '%s\n' "$snapset_before") \
                  | grep -v -x -F "${src}@${commit_snap}")"
    unexpected_bm="$(printf '%s\n' "$bmset_after" \
                     | grep -F -x -v -f <(printf '%s\n' "$bmset_before"))"

    case "$arrived" in ''|*[!0-9]*) arrived=ARRIVED ;; esac
    if [ "$arrived" != 0 ] || [ -n "$unexpected" ] || [ -n "$unexpected_bm" ]; then
        fence_after=ok
        restore_fence_lower "$src" "$fence_val" "$fence_src" || fence_after=dirty
        echo "  PO ZATWIERDZENIU stan zrodla sie ZMIENIL:" >&2
        [ "$arrived" != 0 ] && echo "    nowe dane: ${arrived} B zapisane po podgladzie" >&2
        [ -n "$unexpected" ] && printf '    nowy snapshot: %s\n' "${unexpected#*@}" >&2
        [ -n "$unexpected_bm" ] && printf '    nowy bookmark: %s\n' "${unexpected_bm#*#}" >&2
        restore_die_after_cleanup "$src" "$fence_after" \
            "restore (odtworzenie niszczace): zatwierdziles zbior strat, ktory juz nie opisuje zrodla. NIC nie zniszczono. Uruchom ponownie -- zobaczysz aktualny zbior i zdecydujesz na nim." \
            "$preview_snap" "$commit_snap"
    fi

    # ---- execution ---------------------------------------------------------
    # The fence is UP and the commit boundary held. Perform the destructive step.
    # The fence comes down LAST, after execution, whichever way it went -- a
    # production dataset silently left readonly is a different outage from the one
    # this path was called to fix.
    # This run's own technical snapshots are handed over rather than re-derived: the
    # executor's exact-set check has to tell them apart from an intruder, and the
    # only authority on which ones are ours is the code that created them.
    restore_execute "$src" "$copy" "${src}@${preview_snap}" "${src}@${commit_snap}"; local erc=$?

    if [ "$erc" -eq 1 ]; then
        # Nothing was destroyed: every precondition and the exact-set measurement
        # come first, and the one call that removes the approved snapshots removes
        # all of them or none. This is an ordinary refusal, so once the fence is
        # down and this run's technical snapshots are gone, the source is exactly
        # as it was found -- and restore_die_after_cleanup makes that claim only when
        # both are true.
        fence_after=ok
        restore_fence_lower "$src" "$fence_val" "$fence_src" || fence_after=dirty
        restore_die_after_cleanup "$src" "$fence_after" \
            "restore (odtworzenie niszczace): krok wykonawczy nie ruszyl (szczegoly wyzej) -- NIC nie zniszczono." \
            "$preview_snap" "$commit_snap"
    fi

    if [ "$erc" -ne 0 ]; then
        # erc == 2: destruction has begun, so the source is NOT as it was found and
        # the exact-state claim is never made on this path. Bring the fence down and
        # clean this run's snapshots (a partial rollback may have left them), then
        # report honestly and stop.
        fence_after=ok
        restore_fence_lower "$src" "$fence_val" "$fence_src" || fence_after=dirty
        local snaps_left=ok
        restore_drop_tech_snapshots "$src" "$preview_snap" "$commit_snap" || snaps_left=dirty
        local extra=""
        [ "$fence_after" = dirty ] && extra=" Ponadto nie udalo sie zdjac blokady zapisu (readonly) ze zrodla -- komenda naprawcza wyzej."
        [ "$snaps_left" = dirty ] && extra="${extra} Techniczne snapshoty tego przebiegu pozostaly (wypisane wyzej)."
        die "restore (odtworzenie niszczace): krok WYKONAWCZY nie zakonczyl sie sukcesem (szczegoly wyzej). Zrodlo '$src' zostalo czesciowo zmienione i NIE jest w stanie sprzed polecenia -- sprawdz jego snapshoty i biezacy stan zanim ponowisz.${extra}"
    fi

    # Success. The execution step already destroyed this run's technical snapshots
    # by name, so cleanup is normally a no-op -- but it still reports honestly if
    # anything survived, and the fence still has to come down.
    fence_after=ok
    restore_fence_lower "$src" "$fence_val" "$fence_src" || fence_after=dirty
    local snaps_left=ok
    restore_drop_tech_snapshots "$src" "$preview_snap" "$commit_snap" || snaps_left=dirty

    echo
    echo "ODTWORZENIE ZAKONCZONE: '$src' odtworzono do punktu '${RESTORE_TARGET_SNAP}' (guid ${RESTORE_TARGET_GUID}). Potwierdzone tozsamoscia: snapshot o tym GUID-zie jest na zrodle i nic na zrodle nie jest od niego nowsze."
    if [ "$fence_after" = ok ] && [ "$snaps_left" = ok ]; then
        echo "Blokada zapisu zdjeta; technicznych snapshotow tego przebiegu nie pozostalo."
        return 0
    fi
    # The restore succeeded; housekeeping did not fully. Keep the two facts apart --
    # a single sentence would send the operator to fix only half of it.
    [ "$fence_after" = dirty ] && echo "UWAGA: odtworzenie sie POWIODLO, ale nie udalo sie zdjac blokady zapisu (readonly=on) ze zrodla '$src' -- komenda naprawcza wyzej. To osobna awaria od tej, ktora naprawiales." >&2
    [ "$snaps_left" = dirty ] && echo "UWAGA: odtworzenie sie POWIODLO, ale techniczny snapshot tego przebiegu pozostal (wypisany wyzej) -- usun go recznie." >&2
    return 3
}

cmd_restore() {
    # Before the options are even read: a host whose relationship records do not
    # identify one relationship each cannot answer "which relationship is X",
    # and every path below eventually asks that. Reviewer rule 2, 2026-08-26.
    restore_relations_sane
    local plan=0 dataset="" config="" snapshot="" yes=0 addr="" addr_filter=""
    local scope_src="" scope_tgt="" scope_ns="" scope_list="" at_raw="" at_epoch=""
    # A SHIFTING loop, not `for a in "$@"`, so an option may take its value as the
    # next word. Both recorded contracts spell it that way -- `--target
    # rpool/data/x` -- and an operator typing a recovery at three in the morning
    # should not have to remember which of the two spellings this program takes.
    # `need_val` refuses a flag whose value is missing or is itself the next
    # flag: `--target --plan` silently taking "--plan" as a dataset name is the
    # kind of thing that ends with a refusal nobody can explain.
    local a
    need_val() {   # <flag> <next word or "">
        case "${2:-}" in
            ""|-*) die "restore: $1 needs a value -- a dataset path, or several separated by commas" ;;
        esac
    }
    while [ "$#" -gt 0 ]; do
        a="$1"
        case "$a" in
            --plan)       plan=1 ;;
            --dataset=*)  dataset="${a#*=}" ;;
            --dataset)    need_val --dataset "${2:-}"; dataset="$2"; shift ;;
            # Wall-clock, not a snapshot name (OWNER-RESTORE-CLI-GRAMMAR-2026-08-13).
            --at=*)       at_raw="${a#*=}" ;;
            --at)         need_val --at "${2:-}"; at_raw="$2"; shift ;;
            # Owner decision 2026-08-26: the datasets of a relationship are named
            # by an exact path, in ONE namespace, several of them separated by
            # commas -- a VM with four virtual disks is one recovery, not four.
            --source=*)   scope_src="${a#*=}" ;;
            --source)     need_val --source "${2:-}"; scope_src="$2"; shift ;;
            --target=*)   scope_tgt="${a#*=}" ;;
            --target)     need_val --target "${2:-}"; scope_tgt="$2"; shift ;;
            --snapshot=*) snapshot="${a#*=}" ;;
            --snapshot)   need_val --snapshot "${2:-}"; snapshot="$2"; shift ;;
            --config=*)   config="${a#*=}" ;;
            --config)     need_val --config "${2:-}"; config="$2"; shift ;;
            --yes|-y)     yes=1 ;;
            --*) die "restore: unknown option $a" ;;
            *)
                # Positional token: the public address (relation label,
                # label:dataset, or a managed path). Resolved AFTER the loop,
                # when --config is known. One address per invocation -- a
                # second positional is the cross-host destination, which
                # follows under R-025 once this door is reviewed.
                [ -z "$addr" ] || die "restore: got two addresses ('$addr' and '$a') -- the cross-host destination form is not open yet (R-025 sequencing); one address per call"
                addr="$a" ;;
        esac
        shift
    done
    # THREE forms, per the owner's decision: --source alone, --target alone, or
    # BOTH stated explicitly. A short-lived "mutually exclusive" rule was written
    # here on 2026-08-26 and withdrawn the same day -- it was the reviewer's
    # tightening of an approved UX, not the owner's decision, and it made the
    # explicit form impossible to write.
    #
    # What both-sides does NOT become is free remapping onto an arbitrary target:
    # the pairs are POSITIONAL and every pair must match the recorded mapping.
    # Saying both sides is the operator being explicit about what they already
    # are, not asking for them to be changed.
    if [ -n "$at_raw" ] && [ -n "$snapshot" ]; then
        die "restore: --at and --snapshot both name a recovery point. --snapshot is one exact name for one dataset; --at is a time, resolved per dataset. Give one."
    fi
    [ -n "$at_raw" ] && at_epoch="$(restore_at_epoch "$at_raw")"

    local scope_any=0
    if   [ -n "$scope_src" ] && [ -n "$scope_tgt" ]; then scope_any=1
    elif [ -n "$scope_src" ]; then scope_any=1; scope_ns=copy; scope_list="$scope_src"
    elif [ -n "$scope_tgt" ]; then scope_any=1; scope_ns=orig; scope_list="$scope_tgt"
    fi

    if [ "$scope_any" -eq 1 ]; then
        [ -n "$addr" ] || die "restore: --source/--target select datasets WITHIN a relationship, so the relationship has to be named too: restore <relation> --target <dataset>[,<dataset>...]"
        # The relationship name stands ALONE now. `label:dataset` said the same
        # thing a second way, and two ways to say one thing is how they come to
        # disagree.
        case "$addr" in
            *:*) die "restore: '$addr' already names a dataset, and --source/--target name datasets too. Give the relationship on its own: restore ${addr%%:*} --target <dataset>[,<dataset>...]" ;;
        esac
        read_server_conf
        config="$(restore_pick_config "$config" "'$addr'")"
        # THE WHOLE LIST, BEFORE ANYTHING IS SHOWN. A plan that is right about
        # three of a VM's disks and silent about the fourth is not a plan, and
        # this refuses without having touched anything.
        if [ -n "$scope_src" ] && [ -n "$scope_tgt" ]; then
            restore_scope_pair "$config" "$addr" "$scope_src" "$scope_tgt"
        else
            restore_scope_resolve "$config" "$addr" "$scope_ns" "$scope_list"
        fi
        [ "${#RESTORE_SCOPE_SRC[@]}" -gt 0 ] || die "restore: the dataset list resolved to nothing"
        if [ -n "$snapshot" ]; then
            [ "${#RESTORE_SCOPE_SRC[@]}" -eq 1 ] || die "restore: --snapshot names ONE recovery point and this list selects ${#RESTORE_SCOPE_SRC[@]} datasets. Equal snapshot names are not one atomic event (measured on pve2), so a shared name across several datasets would claim something untrue. Restore them one at a time, or use --at, which resolves per dataset and says so."
            dataset="${RESTORE_SCOPE_SRC[0]}"
        elif [ "$plan" -eq 1 ]; then
            addr_filter="$(printf '%s\n' "${RESTORE_SCOPE_SRC[@]}")"
        else
            # THE DOOR. Until now a resolved scope was forced into plan mode,
            # because nothing could act on it -- `plan=1` sat here with no
            # explanation because there was no alternative to explain.
            #
            # `--plan` is the read-only mode and stays exactly what it was. Its
            # ABSENCE now means do it: the operator named a relationship, named
            # the datasets, optionally named a time, and the machine at risk has
            # already published a grant saying this collector may write to it.
            # Asking again here would be the fourth time the same question is
            # put, and the first three were asked when nothing was on fire.
            RESTORE_AT_EPOCH="$at_epoch"
            restore_run_scope
            return $?
        fi
        addr=""
    fi

    if [ -n "$addr" ]; then
        read_server_conf
        local _rc_cfg; _rc_cfg="$(restore_pick_config "$config" "'$addr'")"
        local _rc_sel; _rc_sel=$(restore_resolve_token "$_rc_cfg" "$addr")
        local _rc_n; _rc_n=$(printf '%s
' "$_rc_sel" | grep -c .)
        if [ -n "$snapshot" ]; then
            # A destructive-capable form needs exactly one dataset: restoring a
            # WHOLE relation to one snapshot name would revive the false idea
            # that equal names are one atomic event (measured otherwise on pve2).
            [ "$_rc_n" -eq 1 ] || die "restore: '$addr' selects $_rc_n datasets -- with --snapshot give one dataset (label:dataset), not a whole relation"
            dataset=$(printf '%s' "$_rc_sel" | cut -f1)
        elif [ "$plan" -eq 1 ]; then
            if [ "$_rc_n" -eq 1 ]; then
                dataset=$(printf '%s' "$_rc_sel" | cut -f1)
            else
                addr_filter=$(printf '%s\n' "$_rc_sel" | cut -f1)
            fi
        else
            # THE WHOLE RELATION. Naming it alone means every dataset it covers
            # -- which is what an operator recovering a machine actually asks
            # for, and the form the owner's grammar puts first.
            #
            # It builds the same scope arrays a --source/--target list produces,
            # so there is one runner, one per-dataset step and one report for
            # every shape of this verb. The alternative -- a second loop for the
            # whole-relation case -- is how two paths come to disagree about
            # what a failure means.
            RESTORE_SCOPE_SRC=(); RESTORE_SCOPE_COPY=()
            local _wr_s _wr_c
            while IFS="$(printf '\t')" read -r _wr_s _wr_c; do
                [ -n "$_wr_s" ] || continue
                RESTORE_SCOPE_SRC+=("$_wr_s"); RESTORE_SCOPE_COPY+=("$_wr_c")
                # EVERY DATASET OF THE SUBTREE, EACH ON ITS OWN.
                #
                # The recorded name covers a subtree, and this used to hand that
                # one name to the runner and rely on the engine's recursive
                # stream to carry the children. Measured on the lab, 2026-08-27,
                # that fails in a way nothing upstream can see: the rollback
                # brings the PARENT to the recovery point, which makes the
                # recursive incremental from that parent a zero-length stream,
                # and a child sitting BEHIND the point is never sent anything.
                # The engine exits 0 over it.
                #
                # The child got behind by a supported operation -- an earlier
                # `restore <relation> --target <one disk>`, which is the whole
                # reason --target exists. So the state is not exotic; it is what
                # using this tool produces.
                #
                # One dataset per entry makes each one its own question, which is
                # what every other decision in this file already is: classified
                # on its own state, granted on its own mode, reported on its own
                # line. A child behind the point is then simply an increment.
                #
                # Only when the copy is LOCAL. A remote copy would need an ssh
                # round trip here, and the collector case -- where the copies are
                # local by construction -- is the one this estate runs.
                case "$_wr_c" in
                    *@*|*:*) : ;;
                    *)  local _sub
                        while IFS= read -r _sub; do
                            [ -n "$_sub" ] || continue
                            [ "$_sub" = "$_wr_c" ] && continue
                            RESTORE_SCOPE_COPY+=("$_sub")
                            RESTORE_SCOPE_SRC+=("${_wr_s}${_sub#"$_wr_c"}")
                            RESTORE_SCOPE_EXPANDED=1
                        done < <(zfs list -H -o name -r "$_wr_c" 2>/dev/null) ;;
                esac
            done <<< "$_rc_sel"
            RESTORE_AT_EPOCH="$at_epoch"
            restore_run_scope
            return $?
        fi
        config="$_rc_cfg"
    fi

    # `--at` used to force plan mode, because a recovery point was something the
    # verb could describe and not reach. It reaches it now: the point is resolved
    # per dataset by creation, proved unambiguous under the engine's own matching
    # rule, and the target is rolled back to it when it sits further forward.
    #
    # The note this replaces said destructive recovery "has no public grammar
    # yet -- the owner is still deciding it". He decided: the collector starts,
    # the machine at risk publishes a grant naming the modes, and `--plan` is the
    # read-only half of the same verb rather than a different one.

    if [ "$plan" -ne 1 ]; then
        [ -n "$snapshot" ] || die "restore: give --plan to see what could be restored, or --snapshot=NAME (with --dataset=) to restore one safely into the restore namespace. Destructive recovery of the original path has no public grammar yet -- the owner is still deciding it."
        cmd_restore_safe "$dataset" "$snapshot" "$config" "$yes"
        return
    fi

    read_server_conf
    [ -n "$config" ] || config="${CRON_CONFIG:-}"
    [ -n "$config" ] || { config=$(restore_default_config); [ -r "$config" ] || config=""; }
    [ -n "$config" ] || die "restore --plan: no cron config known -- pass --config=FILE or run setup-server"
    [ -r "$config" ] || die "restore --plan: cannot read $config"

    # Collect (source, copy-location, kind) triples from the installed CONFIG.
    local -a src=() copy=() kind=() cons=()
    local a b c d
    while IFS=$'\t' read -r a b c d; do
        [ -n "$a" ] || continue
        src+=("$a"); copy+=("$b"); kind+=("$c"); cons+=("$d")
    done <<< "$(restore_relations "$config")"
    [ "${#src[@]}" -gt 0 ] && [ -n "${src[0]:-}" ] || die "restore --plan: $config describes no backup relationship, so there is nothing to restore from"

    local at_missing=0 at_ambig=0 at_row_ok=""
    echo
    echo "Plan odtworzenia (TYLKO ODCZYT -- nic nie zostalo zmienione):"
    if [ -n "$at_epoch" ]; then
        echo
        echo "  PER-DATASET FRONTIER -- NIE atomowy stan calej relacji."
        echo "  Kazdy dataset dostaje WLASNY najpozniejszy snapshot z chwili"
        echo "  $(date -d "@$at_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$at_epoch") lub wczesniejszej. Czasy ponizej moga sie roznic"
        echo "  i to NIE jest blad -- to jest to, co naprawde zostalo zapisane."
        echo "  Wybor idzie po wlasciwosci ZFS 'creation', NIGDY po nazwie snapshotu."
    fi
    echo "  Config:     $config"
    [ -n "$dataset" ] && echo "  Filtr:      $dataset"
    local i shown=0
    for i in "${!src[@]}"; do
        if [ -n "$dataset" ]; then
            [ "${src[$i]}" = "$dataset" ] || [ "${copy[$i]}" = "$dataset" ] || continue
        fi
        # A whole-relation address narrows the plan to the datasets the resolver
        # selected -- `restore pve2` must not print other relations' rows.
        if [ -n "$addr_filter" ]; then
            printf '%s\n' "$addr_filter" | grep -qxF -- "${src[$i]}" || continue
        fi
        shown=$((shown + 1))
        echo
        echo "  Zrodlo:     ${src[$i]}"
        echo "  Relacja:    ${kind[$i]}"
        echo "  Kopia:      ${copy[$i]}"
        local snaps
        # `-d 1` is explicit on purpose (REV-20260812-113 F1). Measured on
        # zfs-2.1.9-pve1 the default already behaves identically -- it returns this
        # dataset's own snapshots, does NOT leak a child's, and works with the pool's
        # `listsnapshots=off` -- so nothing was broken. But that is one ZFS version,
        # the only one I can measure, and the finding is about depending on a default
        # at the planner's core lookup. Naming the depth costs nothing and removes the
        # version-dependence instead of re-measuring it on every upgrade.
        # guid rides the SAME list call rather than a `zfs get` per snapshot --
        # verified live on zfs-2.1.9: name,creation,guid returns three tab-separated
        # fields, rc=0. One process per dataset instead of one per recovery point.
        snaps=$(zfs list -H -p -t snapshot -o name,creation,guid -s creation -d 1 "${copy[$i]}" 2>/dev/null) || snaps=""
        if [ -z "$snaps" ]; then
            echo "  Snapshoty:  BRAK -- ta kopia nie istnieje albo nie ma snapshotow. Nie ma z czego odtwarzac."
            continue
        fi
        if [ "${cons[$i]}" = atomic ]; then
            echo "  Spojnosc:   ATOMIC (punkt odtworzenia) -- z CONFIG 'recursive = atomic'."
            echo "              Wszyscy wybrani czlonkowie musza isc z TEGO SAMEGO punktu."
        else
            echo "  Spojnosc:   INDEPENDENT (frontier, NIE punkt w czasie) -- kazdy dataset ma"
            echo "              wlasny najnowszy snapshot; czasy ponizej moga sie roznic i to nie jest blad."
        fi
        at_row_ok=""
        if [ -n "$at_epoch" ]; then
            local at_row at_rc
            at_row="$(restore_at_pick "$at_epoch" "$snaps")"; at_rc=$?
            case "$at_rc" in
                0)
                    local an ac ag
                    IFS="$(printf '\t')" read -r an ac ag <<< "$at_row"
                    # NOT just the chosen row. The strategy uses this listing
                    # TWICE: once to pick the target (the newest in it) and once
                    # to walk it for the newest snapshot whose GUID also exists
                    # on the source -- the common base an incremental needs.
                    # Handing it a single row got the target right and destroyed
                    # every base candidate, so a dataset with a perfectly good
                    # older common base was classified "FULL on a live source --
                    # no common base" (found in review, 2026-08-26).
                    #
                    # Filtered to creation <= the chosen one: everything after
                    # the requested moment is excluded from being either target
                    # or base, and every legal older candidate stays. The maximum
                    # of what remains IS the chosen row -- a tie at that creation
                    # was already refused above -- so the strategy's own "pick the
                    # newest" lands on exactly the point --at chose.
                    at_row_ok="$(printf '%s
' "$snaps" | awk -F'	' -v c="$ac" 'NF>=3 && $2 ~ /^[0-9]+$/ && ($2+0) <= (c+0)')"
                    echo "  PUNKT --at:  ZADANO $(date -d "@$at_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$at_epoch")"
                    printf '               WYBRANO %s\n' "${an#*@}"
                    printf '               creation=%s  guid=%s\n' "$(date -d "@$ac" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ac")" "${ag:--}"
                    ;;
                1)
                    echo "  PUNKT --at:  BRAK -- ten dataset nie ma snapshotu z chwili $(date -d "@$at_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$at_epoch") ani wczesniejszego."
                    echo "               To jest BLAD TEGO DATASETU. Pozostale sa dalej planowane, a koncowy status przebiegu bedzie niezerowy."
                    at_missing=$((at_missing + 1))
                    ;;
                2)
                    echo "  PUNKT --at:  NIEJEDNOZNACZNE -- kilka snapshotow ma ten sam, najpozniejszy czas utworzenia w tej chwili."
                    echo "               Odmowa wyboru: nazwa snapshotu NIE jest rozstrzygajaca (patrz --at powyzej)."
                    echo "               Wskaz konkretny snapshot recznie albo podaj inna chwile."
                    at_ambig=$((at_ambig + 1))
                    ;;
            esac
        fi
        echo "  Snapshoty (czas z wlasciwosci ZFS 'creation', nie z nazwy):"
        local line sname screat sguid nts human flag
        while IFS=$'\t' read -r sname screat sguid; do
            [ -n "$sname" ] || continue
            human=$(date -d "@$screat" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$screat")
            flag=""
            nts=$(restore_name_timestamp "${sname#*@}")
            if [ -n "$nts" ]; then
                local delta=$(( nts > screat ? nts - screat : screat - nts ))
                [ "$delta" -gt 120 ] && flag="   <-- UWAGA: nazwa mowi $(date -d "@$nts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null), ZFS mowi $human"
            fi
            printf '    %s  guid=%-22s %s%s\n' "$human" "${sguid:--}" "${sname#*@}" "$flag"
        done <<< "$snaps"
        # THE POINT --at CHOSE, not the newest one. Until this line existed the
        # same preview could print `WYBRANO WANTED` and then classify
        # CREATE/REWIND/REPLACE against the newest snapshot on the dataset --
        # including one from AFTER the requested moment. Two answers to one
        # question, in one screen, and the operator has no way to tell which of
        # them the confirmation is about.
        #
        # And when --at resolved NOTHING, the classifier does not run at all: a
        # strategy computed for the default latest would silently be the answer
        # to a question the operator did not ask.
        if [ -n "$at_epoch" ]; then
            if [ -n "$at_row_ok" ]; then
                restore_plan_strategy "${copy[$i]}" "${src[$i]}" "$at_row_ok"                     "wybrany przez --at, NIE najnowszy -> oryginalna sciezka"
            else
                echo "  Strategia:  (POMINIETA -- --at nie wskazal punktu dla tego datasetu; nic nie jest klasyfikowane)"
            fi
        else
            restore_plan_strategy "${copy[$i]}" "${src[$i]}" "$snaps"
        fi
    done
    if [ "$shown" -eq 0 ]; then
        echo
        echo "  Nic nie pasuje do filtra '$dataset' w tym configu."
    fi
    echo
    echo "To jest wylacznie plan odczytu. Zaden dataset, snapshot ani cron nie zostal dotkniety."
    # Owner decision 7 (OWNER-RESTORE-GRANT-AND-MODES-2026-08-26): a run that
    # could not answer for every dataset continues and REPORTS, but it does not
    # exit 0. Nine of ten is not ten, and the exit status is the only part of
    # this a cron job reads.
    if [ "$at_missing" -gt 0 ] || [ "$at_ambig" -gt 0 ]; then
        echo
        echo "PODSUMOWANIE --at: $at_missing dataset(ow) bez snapshotu z tej chwili, $at_ambig niejednoznacznych."
        echo "Plan jest NIEPELNY. Status niezerowy, zeby nie zostalo to zapisane jako czysty przebieg."
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cmd_restore "$@"
fi
