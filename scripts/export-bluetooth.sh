#!/usr/bin/env bash
set -euo pipefail

# Export BlueZ paired devices and link keys from /var/lib/bluetooth,
# encrypt the archive with Ansible Vault, and save it to files/bluetooth.tar.gz
# so it can be safely committed to Git.
#
# Usage:
#   sudo ./scripts/export-bluetooth.sh
#   sudo ./scripts/export-bluetooth.sh --vault-password-file ~/.vault_pass

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/files"
OUT_FILE="${OUT_DIR}/bluetooth.tar.gz"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

if ! command -v ansible-vault >/dev/null 2>&1; then
  echo "ansible-vault is not installed. Install Ansible first." >&2
  exit 1
fi

if [ ! -d /var/lib/bluetooth ]; then
  echo "/var/lib/bluetooth does not exist on this host." >&2
  exit 1
fi

TMP_FILE="$(mktemp /tmp/bluetooth-export.XXXXXX.tar.gz)"
trap 'rm -f "$TMP_FILE"' EXIT

chmod 0600 "$TMP_FILE"
tar -C /var/lib/bluetooth -czf "$TMP_FILE" .

echo "Encrypting Bluetooth archive with Ansible Vault..."
ansible-vault encrypt "$@" "$TMP_FILE"

if ! head -n 1 "$TMP_FILE" | grep -q '^\$ANSIBLE_VAULT;'; then
  echo "Refusing to write output: archive does not have an Ansible Vault header." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
mv -f "$TMP_FILE" "$OUT_FILE"

if [ -n "${SUDO_USER:-}" ]; then
  chown "$SUDO_USER":"$SUDO_USER" "$OUT_FILE"
fi
chmod 0644 "$OUT_FILE"

echo "Exported Vault-encrypted Bluetooth config to $OUT_FILE ($(du -h "$OUT_FILE" | awk '{print $1}'))"
echo "Paired devices included:"
found_devices=0
for info_file in /var/lib/bluetooth/*/*/info; do
  [ -f "$info_file" ] || continue
  mac="$(basename "$(dirname "$info_file")")"
  name="$(awk -F= '/^Name=/{print $2; exit}' "$info_file")"
  echo "  - ${name:-Unknown} (${mac})"
  found_devices=1
done
if [ "$found_devices" -eq 0 ]; then
  echo "  (none found in /var/lib/bluetooth)"
fi
echo ""
echo "Safe to commit to Git: git add files/bluetooth.tar.gz"
