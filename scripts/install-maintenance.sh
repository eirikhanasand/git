#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/sbin}"
SYNC_INTERVAL="${SYNC_INTERVAL:-15min}"
DOCTOR_INTERVAL="${DOCTOR_INTERVAL:-1h}"

if [ "${EUID}" -ne 0 ]; then
    echo "Run as root." >&2
    exit 1
fi

install -d -m 0755 "$INSTALL_DIR"
install -m 0755 "$SCRIPT_DIR/forgejo-doctor.sh" "$INSTALL_DIR/hanasand-forgejo-doctor"
install -m 0755 "$SCRIPT_DIR/sync-to-ovh.sh" "$INSTALL_DIR/hanasand-forgejo-sync-to-ovh"

cat >/etc/systemd/system/hanasand-forgejo-doctor.service <<'UNIT'
[Unit]
Description=Repair Forgejo repository metadata
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hanasand-forgejo-doctor
UNIT

cat >/etc/systemd/system/hanasand-forgejo-doctor.timer <<UNIT
[Unit]
Description=Periodically repair Forgejo repository metadata

[Timer]
OnBootSec=5min
OnUnitActiveSec=${DOCTOR_INTERVAL}
Persistent=true
RandomizedDelaySec=2min
Unit=hanasand-forgejo-doctor.service

[Install]
WantedBy=timers.target
UNIT

cat >/etc/systemd/system/hanasand-forgejo-sync-to-ovh.service <<'UNIT'
[Unit]
Description=Synchronize Forgejo active data to OVH standby
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=8h
ExecStart=/usr/local/sbin/hanasand-forgejo-sync-to-ovh
UNIT

cat >/etc/systemd/system/hanasand-forgejo-sync-to-ovh.timer <<UNIT
[Unit]
Description=Periodically synchronize Forgejo active data to OVH standby

[Timer]
OnBootSec=10min
OnUnitActiveSec=${SYNC_INTERVAL}
Persistent=true
RandomizedDelaySec=3min
Unit=hanasand-forgejo-sync-to-ovh.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now hanasand-forgejo-doctor.timer hanasand-forgejo-sync-to-ovh.timer
