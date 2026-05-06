#!/usr/bin/env bash
set -euo pipefail

LOCK="${LOCK:-/run/hanasand-forgejo-sync-to-ovh.lock}"
REMOTE="${REMOTE:-ubuntu@192.99.32.185}"
REMOTE_PORT="${REMOTE_PORT:-222}"
KEY="${KEY:-/home/hanasand/.ssh/codex_migration_ed25519}"
REMOTE_GIT_DIR="${REMOTE_GIT_DIR:-/home/ubuntu/git}"
LOCAL_GIT_DIR="${LOCAL_GIT_DIR:-/home/hanasand/git}"
LOCAL_DUMP="${LOCAL_DUMP:-/tmp/forgejo_git.dump}"
REMOTE_DUMP="${REMOTE_DUMP:-/tmp/forgejo_git.dump}"
LOG="${LOG:-/var/log/hanasand-forgejo-sync-to-ovh.log}"
FORGEJO_DATA_VOLUME="${FORGEJO_DATA_VOLUME:-git_git_data}"
RUNNER_DATA_VOLUME="${RUNNER_DATA_VOLUME:-git_runner_data}"
REMOTE_FORGEJO_DATA_PATH="${REMOTE_FORGEJO_DATA_PATH:-/var/lib/docker/volumes/git_git_data/_data}"
REMOTE_RUNNER_DATA_PATH="${REMOTE_RUNNER_DATA_PATH:-/var/lib/docker/volumes/git_runner_data/_data}"
SYNC_RUNNER_DATA="${SYNC_RUNNER_DATA:-1}"

SSH_OPTS=(-n -i "$KEY" -p "$REMOTE_PORT" -o StrictHostKeyChecking=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=6)
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

finish() {
    local status=$?
    rm -f "$LOCAL_DUMP"
    if [ "$status" -ne 0 ]; then
        echo "sync failed, attempting to keep standby app services available"
        ssh "${SSH_OPTS[@]}" "$REMOTE" "cd '$REMOTE_GIT_DIR' && docker compose up -d git_db git runner" || true
    fi
    exit "$status"
}
trap finish EXIT

run_local_doctor() {
    if [ -x /usr/local/sbin/hanasand-forgejo-doctor ]; then
        /usr/local/sbin/hanasand-forgejo-doctor
    else
        docker exec --user git git_ui /usr/local/bin/gitea \
            --config /data/gitea/conf/app.ini \
            doctor check \
            --run synchronize-repo-heads \
            --run hooks \
            --run authorized-keys \
            --run enable-push-options \
            --fix \
            --log-file -
    fi
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

echo "repairing primary repository metadata"
run_local_doctor

echo "dumping primary database"
docker exec git_db pg_dump -U git -d git -Fc --no-owner --no-acl > "$LOCAL_DUMP"

echo "pausing standby app services"
ssh "${SSH_OPTS[@]}" "$REMOTE" "cd '$REMOTE_GIT_DIR' && docker compose stop runner git && docker compose up -d git_db"
ssh "${SSH_OPTS[@]}" "$REMOTE" 'until docker exec git_db pg_isready -U git >/dev/null 2>&1; do sleep 1; done'

echo "copying standby dump and data volumes"
rsync -a --delete -e "$RSYNC_SSH" "$LOCAL_DUMP" "$REMOTE:$REMOTE_DUMP"
sync_volume "$FORGEJO_DATA_VOLUME" "$REMOTE_FORGEJO_DATA_PATH"
if [ "$SYNC_RUNNER_DATA" = "1" ]; then
    sync_volume "$RUNNER_DATA_VOLUME" "$REMOTE_RUNNER_DATA_PATH"
fi

echo "restoring standby database"
ssh "${SSH_OPTS[@]}" "$REMOTE" "cd '$REMOTE_GIT_DIR' && docker exec git_db dropdb -U git --if-exists --force git && docker exec git_db createdb -U git git && docker exec -i git_db pg_restore -U git -d git --no-owner --no-acl < '$REMOTE_DUMP'"

echo "starting standby app services"
ssh "${SSH_OPTS[@]}" "$REMOTE" "cd '$REMOTE_GIT_DIR' && docker compose up -d git runner"

echo "checking standby health"
ssh "${SSH_OPTS[@]}" "$REMOTE" '
set -euo pipefail
for _ in $(seq 1 90); do
    ui_health=$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" git_ui 2>/dev/null || true)
    runner_state=$(docker inspect -f "{{.State.Status}}" git_runner 2>/dev/null || true)
    if [ "$ui_health" = healthy ] && [ "$runner_state" = running ] && curl -fsS http://127.0.0.1:8000/explore/repos >/dev/null; then
        docker exec --user git git_ui /usr/local/bin/gitea \
            --config /data/gitea/conf/app.ini \
            doctor check --run synchronize-repo-heads --run hooks --run authorized-keys --fix --log-file -
        docker ps --filter name=git_ --format "{{.Names}} {{.Status}}"
        exit 0
    fi
    sleep 2
done
docker ps -a --filter name=git_ --format "{{.Names}} {{.Status}}"
exit 1
'

printf '[%s] sync ok\n' "$(date -Is)"
