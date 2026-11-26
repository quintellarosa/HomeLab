#!/usr/bin/env bash
set -euo pipefail

# Export BlueZ paired devices and link keys from /var/lib/bluetooth into gitignored secrets/.
# Run once on your working laptop with sudo:
#   sudo ./scripts/export-bluetooth.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/secrets"
OUT_FILE="${OUT_DIR}/bluetooth.tar.gz"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

if [ ! -d /var/lib/bluetooth ]; then
  echo "/var/lib/bluetooth does not exist on this host." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
tar -C /var/lib/bluetooth -czf "$OUT_FILE" .

if [ -n "${SUDO_USER:-}" ]; then
  chown "$SUDO_USER":"$SUDO_USER" "$OUT_DIR" "$OUT_FILE"
fi
chmod 0700 "$OUT_DIR"
chmod 0600 "$OUT_FILE"

echo "Exported Bluetooth config to $OUT_FILE ($(du -h "$OUT_FILE" | awk '{print $1}'))"
