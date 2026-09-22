#!/usr/bin/env bash
set -euo pipefail

LOCK="${LOCK:-/tmp/forgejo-standby-sync.lock}"
REMOTE="${REMOTE:-ubuntu@192.99.32.185}"
REMOTE_PORT="${REMOTE_PORT:-222}"
KEY="${KEY:-/home/hanasand/.ssh/git_standby_sync_ed25519}"
REMOTE_GIT_DIR="${REMOTE_GIT_DIR:-/home/ubuntu/git}"
LOCAL_GIT_DIR="${LOCAL_GIT_DIR:-/home/hanasand/git}"
LOG="${LOG:-/var/log/hanasand-forgejo-sync-to-ovh.log}"
FORGEJO_DATA_VOLUME="${FORGEJO_DATA_VOLUME:-git_git_data}"
RUNNER_DATA_VOLUME="${RUNNER_DATA_VOLUME:-git_runner_data}"
REMOTE_FORGEJO_DATA_PATH="${REMOTE_FORGEJO_DATA_PATH:-/var/lib/docker/volumes/git_git_data/_data}"
REMOTE_RUNNER_DATA_PATH="${REMOTE_RUNNER_DATA_PATH:-/var/lib/docker/volumes/git_runner_data/_data}"
SYNC_RUNNER_DATA="${SYNC_RUNNER_DATA:-1}"

SSH_OPTS=(-n -i "$KEY" -p "$REMOTE_PORT" -o StrictHostKeyChecking=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=6)
SSH_SCRIPT_OPTS=(-i "$KEY" -p "$REMOTE_PORT" -o StrictHostKeyChecking=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=6)
RSYNC_SSH="ssh -i $KEY -p $REMOTE_PORT -o StrictHostKeyChecking=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=6"

exec >>"$LOG" 2>&1
printf '[%s] sync start\n' "$(date -Is)"

if ! command -v flock >/dev/null 2>&1; then
    echo "flock missing" >&2
    exit 1
fi

exec 9>"$LOCK"
if ! flock -n 9; then
    printf '[%s] sync skipped: another run is active\n' "$(date -Is)"
    exit 0
fi

# A failed file sync must never start an app against a read-only database.
trap 'status=$?; if [ "$status" -ne 0 ]; then echo "sync failed; standby remains fenced"; fi' EXIT

check_standby() {
    ssh "${SSH_SCRIPT_OPTS[@]}" "$REMOTE" 'bash -se' <<'REMOTE_CHECK'
set -euo pipefail
[ "$(docker exec git_db psql -X -U git -d git -Atc "SELECT pg_is_in_recovery()")" = t ] || {
    echo "Refusing to overwrite a promoted or non-replica standby" >&2
    exit 1
}
for container in git_ui git_runner; do
    [ "$(docker inspect -f '{{.State.Running}}' "$container")" = false ] || {
        echo "$container must remain stopped until failover" >&2
        exit 1
    }
done
[ "$(docker exec git_db psql -X -U git -d git -Atc "SELECT status FROM pg_stat_wal_receiver")" = streaming ] || {
    echo "Standby WAL receiver is not streaming" >&2
    exit 1
}
REMOTE_CHECK
}

sync_volume() {
    local volume=$1
    local remote_path=$2

    docker run --rm \
        -e REMOTE_PATH="$remote_path" \
        -v "$volume:/src:ro" \
        -v "$KEY:/root/.ssh/codex_migration_ed25519:ro" \
        -v /home/hanasand/.ssh/known_hosts:/root/.ssh/known_hosts:ro \
        alpine sh -lc '
            set -euo pipefail
            apk add --no-cache rsync openssh-client >/dev/null
            rsync -aH --delete --numeric-ids --partial --info=stats2 \
                -e "ssh -i /root/.ssh/codex_migration_ed25519 -p '"$REMOTE_PORT"' -o StrictHostKeyChecking=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=6" \
                --rsync-path="sudo rsync" \
                /src/ "'"$REMOTE:${remote_path}"'/"
        '
}

cd "$LOCAL_GIT_DIR"

echo "checking streaming standby before file sync"
check_standby

echo "copying changed data files; PostgreSQL replicates independently"
sync_volume "$FORGEJO_DATA_VOLUME" "$REMOTE_FORGEJO_DATA_PATH"
if [ "$SYNC_RUNNER_DATA" = "1" ]; then
    sync_volume "$RUNNER_DATA_VOLUME" "$REMOTE_RUNNER_DATA_PATH"
fi

echo "checking streaming standby after file sync"
check_standby
# Wait for a fixed WAL position, so an idle primary is not mistaken for lag.
lsn=$(docker exec git_db psql -X -U git -d git -Atc "SELECT pg_current_wal_lsn()")
[[ "$lsn" =~ ^[0-9A-F]+/[0-9A-F]+$ ]]
caught_up=false
for _ in $(seq 1 30); do
    replayed=$(ssh "${SSH_OPTS[@]}" "$REMOTE" "docker exec git_db psql -X -U git -d git -Atc \"SELECT pg_last_wal_replay_lsn() >= '$lsn'::pg_lsn\"")
    if [ "$replayed" = t ]; then caught_up=true; break; fi
    sleep 2
done
[ "$caught_up" = true ] || { echo "Standby did not replay $lsn within 60 seconds" >&2; exit 1; }
printf '[%s] sync ok; standby replayed %s\n' "$(date -Is)" "$lsn"
