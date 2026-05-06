#!/usr/bin/env bash
set -euo pipefail

FORGEJO_CONTAINER="${FORGEJO_CONTAINER:-git_ui}"
FORGEJO_CONFIG="${FORGEJO_CONFIG:-/data/gitea/conf/app.ini}"
LOG_FILE="${LOG_FILE:-/var/log/hanasand-forgejo-doctor.log}"
FIX="${FIX:-1}"
CHECKS="${CHECKS:-synchronize-repo-heads hooks authorized-keys enable-push-options}"

run_doctor() {
    local args=()
    for check in ${CHECKS}; do
        args+=(--run "$check")
    done
    if [ "$FIX" = "1" ]; then
        args+=(--fix)
    fi

    docker exec --user git "$FORGEJO_CONTAINER" \
        /usr/local/bin/gitea \
        --config "$FORGEJO_CONFIG" \
        doctor check "${args[@]}" --log-file -
}

{
    printf '[%s] forgejo doctor start fix=%s checks=%s\n' "$(date -Is)" "$FIX" "$CHECKS"
    run_doctor
    printf '[%s] forgejo doctor ok\n' "$(date -Is)"
} >>"$LOG_FILE" 2>&1
