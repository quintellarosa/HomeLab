#!/usr/bin/env bash
set -euo pipefail

# Safe QEMU/KVM OVMF UEFI 3-NVMe test lab for HomeLab unattended installers.
# Simulates:
#   nvme0 -> HOMELAB-WIN-DISK  (dummy Windows disk, must remain untouched)
#   nvme1 -> HOMELAB-HOME-DISK (btrfs /home with sentinel file, must remain untouched)
#   nvme2 -> HOMELAB-OS-DISK   (target OS disk, wiped and reinstalled)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_DIR="${ROOT_DIR}/build/vm"
STAGE_DIR="${ROOT_DIR}/build/ventoy-stage"
ISO_DIR="${ROOT_DIR}/build/isos"

OS_IMG="${VM_DIR}/os-disk.qcow2"
HOME_IMG="${VM_DIR}/home-disk.qcow2"
WIN_IMG="${VM_DIR}/win-disk.qcow2"
OVMF_VARS="${VM_DIR}/OVMF_VARS_4M.fd"
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_SRC="/usr/share/OVMF/OVMF_VARS_4M.fd"

ISO_FILE="${ISO_FILE:-${ISO_DIR}/ubuntu-26.10-desktop-amd64.iso}"
CIDATA_IMG="${CIDATA_IMG:-${STAGE_DIR}/cidata.img}"
HOME_RAW_DEV="${HOME_RAW_DEV:-}"
VENTOY_IMG="${VENTOY_IMG:-}"

RAM_MB="${RAM_MB:-6144}"
CPUS="${CPUS:-4}"
SSH_PORT="${SSH_PORT:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  init            Create 3 virtual NVMe disks + OVMF vars + btrfs /home seed
  boot-install    Boot installer (ISO + cidata, or VENTOY_IMG) against the 3 NVMe disks
  boot-installed  Boot the installed OS from HOMELAB-OS-DISK (without installer ISO)
  clean           Remove build/vm virtual disks

Environment overrides:
  ISO_FILE=/path/to/ubuntu.iso
  CIDATA_IMG=/path/to/cidata.img
  VENTOY_IMG=/path/to/ventoy-test.img   (boots Ventoy USB image instead of ISO+cidata)
  HOME_RAW_DEV=/dev/disk/by-id/...      (pass through a real spare SSD instead of home-disk.qcow2)
  RAM_MB=6144 CPUS=4 SSH_PORT=22220
EOF
}

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "Missing required command: $c" >&2; exit 1; }
  done
}

cmd_init() {
  require_cmd qemu-img mkfs.btrfs
  mkdir -p "$VM_DIR"

  if [ ! -f "$OVMF_VARS_SRC" ] || [ ! -f "$OVMF_CODE" ]; then
    echo "OVMF firmware not found under /usr/share/OVMF/. Install ovmf package." >&2
    exit 1
  fi

  cp -f "$OVMF_VARS_SRC" "$OVMF_VARS"
  qemu-img create -f qcow2 "$OS_IMG" 40G >/dev/null

  # Create dummy protected Windows disk
  local win_raw="${VM_DIR}/win-disk.raw"
  truncate -s 2G "$win_raw"
  mkfs.vfat -n WIN_PROTECT "$win_raw" >/dev/null
  qemu-img convert -f raw -O qcow2 "$win_raw" "$WIN_IMG"
  rm -f "$win_raw"

  # Create btrfs /home disk with sentinel file using mkfs.btrfs --rootdir (no sudo required)
  local seed_dir="${VM_DIR}/home-seed"
  local home_raw="${VM_DIR}/home-disk.raw"
  rm -rf "$seed_dir" "$home_raw"
  mkdir -p "${seed_dir}/quintellarosa/Projects"
  cat > "${seed_dir}/quintellarosa/DO_NOT_WIPE_SENTINEL.txt" <<'SENTINEL'
HomeLab /home preservation sentinel.
If this file is missing or modified after installation, /home preservation FAILED.
SENTINEL
  chown -R 1000:1000 "${seed_dir}/quintellarosa"
  truncate -s 8G "$home_raw"
  mkfs.btrfs -f -L HOME_TEST --rootdir "$seed_dir" "$home_raw" >/dev/null
  qemu-img convert -f raw -O qcow2 "$home_raw" "$HOME_IMG"
  rm -rf "$seed_dir" "$home_raw"

  echo "Initialized VM test lab in $VM_DIR:"
  echo "  OS disk (40G):   $OS_IMG (serial=HOMELAB-OS-DISK)"
  echo "  /home disk (8G): $HOME_IMG (serial=HOMELAB-HOME-DISK, label=HOME_TEST, btrfs)"
  echo "  Win disk (2G):   $WIN_IMG (serial=HOMELAB-WIN-DISK, label=WIN_PROTECT)"
}

build_nvme_args() {
  local -n _arr=$1
  _arr+=(
    -drive "if=none,id=nvme_win,file=${WIN_IMG},format=qcow2"
    -device "nvme,drive=nvme_win,serial=HOMELAB-WIN-DISK"
  )
  if [ -n "$HOME_RAW_DEV" ]; then
    echo "WARNING: Passing through physical device $HOME_RAW_DEV as /home!" >&2
    _arr+=(
      -drive "if=none,id=nvme_home,file=${HOME_RAW_DEV},format=raw,cache=none,aio=native"
      -device "nvme,drive=nvme_home,serial=HOMELAB-HOME-DISK"
    )
  else
    _arr+=(
      -drive "if=none,id=nvme_home,file=${HOME_IMG},format=qcow2"
      -device "nvme,drive=nvme_home,serial=HOMELAB-HOME-DISK"
    )
  fi
  _arr+=(
    -drive "if=none,id=nvme_os,file=${OS_IMG},format=qcow2"
    -device "nvme,drive=nvme_os,serial=HOMELAB-OS-DISK"
  )
}

pick_ssh_port() {
  if [ -n "$SSH_PORT" ]; then
    echo "$SSH_PORT"
    return
  fi
  python3 -c '
import socket
for port in (2222, 0):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", port))
        print(s.getsockname()[1])
        break
    except OSError:
        pass
    finally:
        s.close()
'
}

run_qemu() {
  require_cmd qemu-system-x86_64 python3
  local extra_args=("$@")
  local nvme_args=()
  build_nvme_args nvme_args
  local fwd_port
  fwd_port="$(pick_ssh_port)"
  echo "VM SSH forwarded on 127.0.0.1:${fwd_port} -> guest:22"

  local vga_args=(-device virtio-vga -display gtk)
  if [ "${QEMU_GL:-0}" = "1" ]; then
    vga_args=(-device virtio-vga-gl -display gtk,gl=on)
  fi

  exec qemu-system-x86_64 \
    -enable-kvm \
    -machine q35,accel=kvm \
    -cpu host \
    -smp "$CPUS" \
    -m "$RAM_MB" \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
    -drive "if=pflash,format=raw,file=${OVMF_VARS}" \
    -device qemu-xhci \
    -device usb-tablet \
    "${vga_args[@]}" \
    -serial "file:${VM_DIR}/console.log" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${fwd_port}-:22" \
    -device virtio-net-pci,netdev=net0 \
    "${nvme_args[@]}" \
    "${extra_args[@]}"
}

cmd_boot_install() {
  [ -f "$OS_IMG" ] || { echo "Run '$(basename "$0") init' first." >&2; exit 1; }
  if [ -n "$VENTOY_IMG" ]; then
    [ -e "$VENTOY_IMG" ] || { echo "VENTOY_IMG not found: $VENTOY_IMG" >&2; exit 1; }
    local ventoy_drive="if=none,id=usb_ventoy,file=${VENTOY_IMG},format=raw"
    if [ -b "$VENTOY_IMG" ]; then
      ventoy_drive="${ventoy_drive},cache=none,aio=native"
    fi
    run_qemu \
      -no-reboot \
      -drive "$ventoy_drive" \
      -device "usb-storage,drive=usb_ventoy,bootindex=1"
  else
    [ -f "$ISO_FILE" ] || { echo "ISO not found: $ISO_FILE" >&2; exit 1; }
    [ -f "$CIDATA_IMG" ] || { echo "cidata.img not found: $CIDATA_IMG (run build-ventoy.yml first)" >&2; exit 1; }
    run_qemu \
      -no-reboot \
      -cdrom "$ISO_FILE" \
      -boot order=d \
      -drive "if=none,id=usb_cidata,file=${CIDATA_IMG},format=raw" \
      -device "usb-storage,drive=usb_cidata"
  fi
}

cmd_boot_installed() {
  [ -f "$OS_IMG" ] || { echo "OS disk not found: $OS_IMG" >&2; exit 1; }
  run_qemu
}

cmd_clean() {
  rm -rf "$VM_DIR"
  echo "Removed $VM_DIR"
}

case "${1:-}" in
  init)           cmd_init ;;
  boot-install)   cmd_boot_install ;;
  boot-installed) cmd_boot_installed ;;
  clean)          cmd_clean ;;
  *)              usage; exit 1 ;;
esac
