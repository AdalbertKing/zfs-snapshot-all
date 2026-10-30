#!/bin/bash
set -Eeuo pipefail
TARGET_REPO=${TARGET_REPO:?}
TARGET_SHA=${TARGET_SHA:?}
[ "$(git -C "$TARGET_REPO" rev-parse HEAD)" = "$TARGET_SHA" ] || exit 2
T=$(mktemp -d)
PIDS=()
cleanup() {
    : > "$T/release-first" 2>/dev/null || true
    for p in "${PIDS[@]:-}"; do kill -CONT "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done
    rm -rf -- "$T"
}
trap cleanup EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare -b main "$T/origin.git"
git init -q -b main "$T/seed"
printf 'a\n' > "$T/seed/a"
git -C "$T/seed" add a
git -C "$T/seed" commit -q -m A
git -C "$T/seed" push -q "$T/origin.git" main
git clone -q "$T/origin.git" "$T/repo"
mkdir -p "$T/state" "$T/bin" "$T/locks"
cat > "$T/bashenv" <<EOF
git() {
    if printf '%s\n' "\$*" | grep -q 'reflog expire' && mkdir '$T/stop.once' 2>/dev/null; then
        printf '%s\n' "\$BASHPID" > '$T/cleaner.pid'
        : > '$T/first.at-reflog'
        while [ ! -e '$T/release-first' ]; do :; done
    fi
    command git "\$@"
}
EOF
cat > "$T/bin/crontab" <<EOF
#!/bin/bash
if [ "\${1:-}" = -u ]; then shift 2; fi
if [ "\${1:-}" = -l ]; then cat '$T/cron'; exit 0; fi
cp "\$1" '$T/cron'
EOF
chmod +x "$T/bin/crontab"
printf '15 * * * * cd %s && git pull --ff-only origin main >>%s/log 2>&1\n' "$T/repo" "$T" > "$T/cron"
export PATH="$T/bin:$PATH" CRON_LOCK_DIR="$T/locks" BASH_ENV="$T/bashenv"
export CLEAN_LIB_CRON="$TARGET_REPO/lib-cron.sh" CLEAN_WAIT=10 CLEAN_POLL=1
bash "$TARGET_REPO/release/clean-host-clone.sh" "$T/state" "$T/repo" >"$T/one.log" 2>&1 &
ONE=$!; PIDS+=("$ONE")
for _ in $(seq 1 100); do [ -e "$T/first.at-reflog" ] && break; sleep 0.05; done
[ -e "$T/first.at-reflog" ] || { echo 'first cleaner did not reach reflog point'; exit 2; }
CLEANER=$(cat "$T/cleaner.pid"); PIDS+=("$CLEANER")
kill -0 "$CLEANER" 2>/dev/null || { echo 'first cleaner was not waiting'; exit 2; }
bash "$TARGET_REPO/release/clean-host-clone.sh" "$T/state" "$T/repo" >"$T/two.log" 2>&1 &
TWO=$!; PIDS+=("$TWO")
wait "$TWO"
hold=no; [ -e "$T/state/update-hold" ] && hold=yes
cron_pull=no; grep -qF "cd $T/repo && git pull --ff-only origin main" "$T/cron" && cron_pull=yes
barriers=$(find "$T/state" -name barrier -type f | wc -l)
first_state=""; kill -0 "$CLEANER" 2>/dev/null && first_state=waiting-before-gc
printf 'sha=%s\nfirst_cleaner_state=%s\nhold=%s\ncron_pull=%s\nbarriers=%s\n' "$TARGET_SHA" "$first_state" "$hold" "$cron_pull" "$barriers"
if [ "$first_state" = waiting-before-gc ] && [ "$hold" = no ] && [ "$cron_pull" = yes ] && [ "$barriers" -eq 0 ]; then
    echo 'FAIL: second cleaner reopened every entry point and deleted the first cleaner barrier while the first cleaner was still active before gc'
    exit 1
fi
echo 'PASS: concurrent cleaner remained excluded'
