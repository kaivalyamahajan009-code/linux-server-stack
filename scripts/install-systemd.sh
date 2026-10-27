#!/usr/bin/env bash
# Copies the unit files to /etc/systemd/system and starts both timers.
# The units expect the project to live in /opt/linux-server-stack.

source "$(dirname "$0")/lib/common.sh"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Please run as root (sudo)."
    exit 1
fi

cp "${PROJECT_ROOT}"/systemd/linux-server-*.{service,timer} /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now linux-server-audit.timer linux-server-backup.timer

systemctl list-timers 'linux-server-*'
