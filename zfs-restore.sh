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
[ -r "$LIBCOMMON" ] || { echo "cannot read $LIBCOMMON -- the checkout is incomplete" >&2; exit 1; }
# shellcheck disable=SC1090
source "$LIBCOMMON"

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
restore_plan_strategy() {   # <copy dataset> <original source> <copy snapshot rows>
    local copy="$1" srcpath="$2" snaps="$3"
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
    echo "  Punkt docelowy (domyslna polityka: NAJNOWSZY -> oryginalna sciezka):"
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
    local label="" want=""
    case "$tok" in
        *:*) label="${tok%%:*}"; want="${tok#*:}" ;;
        */*) want="$tok" ;;
        *)   label="$tok" ;;
    esac
    local ds l s d hit=0
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
            [ "$src_plain" = "$want" ] || [ "$src_id" = "$want" ] || [ "$copy_loc" = "$want" ] || [ "$ds" = "$want" ] || continue
        fi
        printf '%s\t%s\n' "$src_id" "$copy_loc"
        hit=1
    done
    [ "$hit" -eq 1 ] && return 0
    if [ -n "$label" ] && [ -n "$want" ]; then
        die "restore: relation '$label' does not cover dataset '$want' in $config. 'restore --plan' lists what it does cover. A name that does not resolve is an error, never a guess."
    elif [ -n "$label" ]; then
        die "restore: '$label' is not a relation label in $config (no [dataset:] section carries pair_label = $label). It is NOT treated as a hostname, deliberately -- guessing is how a recovery aims at the wrong machine. 'restore --plan' lists the labels."
    else
        die "restore: '$want' is neither a source nor a managed copy location in $config. An arbitrary dataset is never adopted as backup provenance (R-025). 'restore --plan' lists the managed locations."
    fi
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
            die "restore (odtworzenie niszczace): zrodlo '$src' jest ZDALNE. Ten czasownik dziala tylko lokalnie -- odtworzenie na zdalny host wymaga decyzji o tym, kto wykonuje zniszczenie po tamtej stronie, a tej decyzji nie ma." ;;
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
    local plan=0 dataset="" config="" snapshot="" yes=0 addr="" addr_filter=""
    for a in "$@"; do
        case "$a" in
            --plan)       plan=1 ;;
            --dataset=*)  dataset="${a#*=}" ;;
            --snapshot=*) snapshot="${a#*=}" ;;
            --config=*)   config="${a#*=}" ;;
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
    done
    if [ -n "$addr" ]; then
        read_server_conf
        local _rc_cfg="$config"; [ -n "$_rc_cfg" ] || _rc_cfg="${CRON_CONFIG:-}"
        [ -n "$_rc_cfg" ] || { _rc_cfg=$(restore_default_config); [ -r "$_rc_cfg" ] || _rc_cfg=""; }
        [ -n "$_rc_cfg" ] && [ -r "$_rc_cfg" ] || die "restore: no readable installed config to resolve '$addr' against (tried \$CRON_CONFIG and $(restore_default_config)) -- pass --config=FILE"
        local _rc_sel; _rc_sel=$(restore_resolve_token "$_rc_cfg" "$addr")
        local _rc_n; _rc_n=$(printf '%s
' "$_rc_sel" | grep -c .)
        if [ -n "$snapshot" ]; then
            # A destructive-capable form needs exactly one dataset: restoring a
            # WHOLE relation to one snapshot name would revive the false idea
            # that equal names are one atomic event (measured otherwise on pve2).
            [ "$_rc_n" -eq 1 ] || die "restore: '$addr' selects $_rc_n datasets -- with --snapshot give one dataset (label:dataset), not a whole relation"
            dataset=$(printf '%s' "$_rc_sel" | cut -f1)
        else
            plan=1
            if [ "$_rc_n" -eq 1 ]; then
                dataset=$(printf '%s' "$_rc_sel" | cut -f1)
            else
                addr_filter=$(printf '%s\n' "$_rc_sel" | cut -f1)
            fi
        fi
        config="$_rc_cfg"
    fi

    # Phase 7 slice 2: a SAFE restore is the plain verb. Destructive replacement of
    # a live dataset stays a SEPARATE verb (slice 3), never a flag on this one --
    # a --force that turns a safe command into a destructive one is exactly the
    # shape the plan refuses.
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

    echo
    echo "Plan odtworzenia (TYLKO ODCZYT -- nic nie zostalo zmienione):"
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
        restore_plan_strategy "${copy[$i]}" "${src[$i]}" "$snaps"
    done
    if [ "$shown" -eq 0 ]; then
        echo
        echo "  Nic nie pasuje do filtra '$dataset' w tym configu."
    fi
    echo
    echo "To jest wylacznie plan odczytu. Zaden dataset, snapshot ani cron nie zostal dotkniety."
}

# ------------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cmd_restore "$@"
fi
