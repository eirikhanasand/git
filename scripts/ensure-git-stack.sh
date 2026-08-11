#!/usr/bin/env bash
set -euo pipefail
cd /home/hanasand/git
/usr/bin/docker compose up -d
/usr/bin/docker compose ps
