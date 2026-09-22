#!/usr/bin/env bash
set -euo pipefail
exec bash "$(dirname -- "$(readlink -f -- "$0")")/scripts/sync-to-ovh.sh" "$@"
