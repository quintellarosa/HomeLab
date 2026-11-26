#!/usr/bin/env bash
set -euo pipefail

# Build and populate a 3-partition Ventoy + cidata disk (virtual raw image OR physical USB drive).
# Layout:
#   Partition 1 (Ventoy, exFAT) : /iso/<distro>.iso, /ventoy/ventoy.json, /autoinstall/...
#   Partition 2 (VTOYEFI)       : Ventoy EFI bootloader
#   Partition 3 (cidata, FAT32) : /user-data, /meta-data (for Ubuntu unattended install)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENTOY_VERSION="${VENTOY_VERSION:-1.1.18}"
VENTOY_CACHE_DIR="${ROOT_DIR}/build/ventoy"
STAGE_DIR="${ROOT_DIR}/build/ventoy-stage"
ISO_DIR="${ROOT_DIR}/build/isos"
ISO_NAME="${ISO_NAME:-ubuntu-26.10-desktop-amd64.iso}"
DISTRO_KEY="${DISTRO_KEY:-ubuntu_26_10}"
RESERVE_MB="${RESERVE_MB:-32}"
IMAGE_SIZE="${IMAGE_SIZE:-12G}"

MODE=""
TARGET=""
ASSUME_YES=0
SYNC_ONLY=0

usage() {
  cat <<EOF
Usage:
  sudo $(basename "$0") --image [path]        Create/refresh a virtual Ventoy+cidata raw image (default: build/vm/ventoy-test.img)
  sudo $(basename "$0") --device /dev/sdX     Format and populate a real USB drive (DESTRUCTIVE on target drive)

Options:
  --size 12G          Virtual image size when using --image (default: 12G)
  --distro ubuntu_26_10
  --iso ubuntu-26.10-desktop-amd64.iso
  --ventoy-version 1.1.18
  --sync-only         Update staged configs (and ISO only if size differs) without reformatting
  --yes               Skip confirmation prompt (only with --device)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      MODE="image"
      if [ -n "${2:-}" ] && [[ "${2}" != --* ]]; then
        TARGET="$2"
        shift 2
      else
        TARGET="${ROOT_DIR}/build/vm/ventoy-test.img"
        shift
      fi
      ;;
    --device)
      MODE="device"
      TARGET="${2:-}"
      shift 2
      ;;
    --size)
      IMAGE_SIZE="${2:-}"
      shift 2
      ;;
    --distro)
      DISTRO_KEY="${2:-}"
      shift 2
      ;;
    --iso)
      ISO_NAME="${2:-}"
      shift 2
      ;;
    --ventoy-version)
      VENTOY_VERSION="${2:-}"
      shift 2
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --sync-only)
      SYNC_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

[ -n "$MODE" ] || { usage; exit 1; }
[ -n "$TARGET" ] || { echo "Missing target path/device." >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  echo "This script needs root for Ventoy2Disk.sh, losetup, and mounting partitions. Run with sudo." >&2
  exit 1
fi

for cmd in curl tar sha256sum losetup sgdisk mkfs.vfat partprobe udevadm lsblk rsync; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

ISO_PATH="${ISO_DIR}/${ISO_NAME}"
USER_DATA="${STAGE_DIR}/autoinstall/${DISTRO_KEY}/user-data"
META_DATA="${STAGE_DIR}/autoinstall/${DISTRO_KEY}/meta-data"
AUTOINSTALL_YAML="${STAGE_DIR}/autoinstall/${DISTRO_KEY}/autoinstall.yaml"
VENTOY_JSON="${STAGE_DIR}/ventoy/ventoy.json"

for req in "$ISO_PATH" "$USER_DATA" "$META_DATA" "$VENTOY_JSON"; do
  [ -f "$req" ] || { echo "Required file not found: $req (run 'ansible-playbook playbooks/build-ventoy.yml' first)" >&2; exit 1; }
done

LOOPDEV=""
MNT_VENTOY=""
MNT_CIDATA=""

cleanup() {
  set +e
  if [ -n "$MNT_VENTOY" ] && mountpoint -q "$MNT_VENTOY"; then umount "$MNT_VENTOY"; fi
  if [ -n "$MNT_CIDATA" ] && mountpoint -q "$MNT_CIDATA"; then umount "$MNT_CIDATA"; fi
  [ -n "$MNT_VENTOY" ] && rmdir "$MNT_VENTOY" 2>/dev/null
  [ -n "$MNT_CIDATA" ] && rmdir "$MNT_CIDATA" 2>/dev/null
  if [ -n "$LOOPDEV" ]; then losetup -d "$LOOPDEV" 2>/dev/null; fi
}
trap cleanup EXIT

part_path() {
  local dev="$1" num="$2"
  if [[ "$dev" =~ (loop|nvme|mmcblk)[0-9]+$ ]]; then
    echo "${dev}p${num}"
  else
    echo "${dev}${num}"
  fi
}

download_ventoy() {
  local tarball="ventoy-${VENTOY_VERSION}-linux.tar.gz"
  local url="https://github.com/ventoy/Ventoy/releases/download/v${VENTOY_VERSION}/${tarball}"
  local sha_url="https://github.com/ventoy/Ventoy/releases/download/v${VENTOY_VERSION}/sha256.txt"
  local extract_dir="${VENTOY_CACHE_DIR}/ventoy-${VENTOY_VERSION}"

  mkdir -p "$VENTOY_CACHE_DIR"
  if [ ! -f "${VENTOY_CACHE_DIR}/sha256.txt" ]; then
    curl -fsSL "$sha_url" -o "${VENTOY_CACHE_DIR}/sha256.txt"
  fi

  local expected_sha
  expected_sha="$(awk -v f="$tarball" '$2 == f || $2 == "*"f { print $1; exit }' "${VENTOY_CACHE_DIR}/sha256.txt")"
  [ "${#expected_sha}" -eq 64 ] || { echo "Could not find SHA-256 for $tarball" >&2; exit 1; }

  if [ ! -f "${VENTOY_CACHE_DIR}/${tarball}" ]; then
    echo "Downloading ${tarball}..."
    curl -fL "$url" -o "${VENTOY_CACHE_DIR}/${tarball}"
  fi

  echo "${expected_sha}  ${VENTOY_CACHE_DIR}/${tarball}" | sha256sum -c -

  if [ ! -x "${extract_dir}/Ventoy2Disk.sh" ]; then
    tar -C "$VENTOY_CACHE_DIR" -xzf "${VENTOY_CACHE_DIR}/${tarball}"
  fi
  VENTOY_DIR="$extract_dir"
}

if [ "$SYNC_ONLY" -ne 1 ]; then
  download_ventoy
fi

WORK_DEV=""
if [ "$MODE" = "image" ]; then
  mkdir -p "$(dirname "$TARGET")"
  if [ "$SYNC_ONLY" -ne 1 ]; then
    rm -f "$TARGET"
    truncate -s "$IMAGE_SIZE" "$TARGET"
  fi
  [ -f "$TARGET" ] || { echo "Image not found for --sync-only: $TARGET" >&2; exit 1; }
  LOOPDEV="$(losetup -fP --show "$TARGET")"
  WORK_DEV="$LOOPDEV"
else
  TARGET="$(readlink -f "$TARGET")"
  [ -b "$TARGET" ] || { echo "Not a block device: $TARGET" >&2; exit 1; }

  # Refuse non-removable or internal NVMe/SATA drives unless explicitly USB/removable
  TRAN="$(lsblk -ndo TRAN "$TARGET" 2>/dev/null || true)"
  RM="$(lsblk -ndo RM "$TARGET" 2>/dev/null || true)"
  if [ "$TRAN" != "usb" ] && [ "$RM" != "1" ]; then
    echo "Refusing target $TARGET (TRAN='$TRAN', RM='$RM') — does not look like a USB removable drive." >&2
    exit 1
  fi

  echo "Target USB drive details:"
  lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,RM,MOUNTPOINT "$TARGET"
  if [ "$SYNC_ONLY" -ne 1 ] && [ "$ASSUME_YES" -ne 1 ]; then
    read -r -p "ALL DATA on $TARGET will be ERASED. Type YES to continue: " confirm
    [ "$confirm" = "YES" ] || { echo "Aborted."; exit 1; }
  fi

  # Unmount any mounted partitions on the USB stick
  for p in $(lsblk -lnpo PATH "$TARGET" | tail -n +2); do
    umount "$p" 2>/dev/null || true
  done
  WORK_DEV="$TARGET"
fi

if [ "$SYNC_ONLY" -ne 1 ]; then
  echo "Installing Ventoy ${VENTOY_VERSION} (GPT, reserve ${RESERVE_MB}MB for cidata) on ${WORK_DEV}..."
  (cd "$VENTOY_DIR" && printf 'y\ny\n' | sh ./Ventoy2Disk.sh -I -g -r "$RESERVE_MB" "$WORK_DEV")

  partprobe "$WORK_DEV" || true
  udevadm settle

  echo "Creating partition 3 (cidata, FAT32) in reserved trailing space..."
  sgdisk -n 3:0:0 -t 3:0700 -c 3:cidata "$WORK_DEV"
  partprobe "$WORK_DEV" || true
  udevadm settle
fi

PART1="$(part_path "$WORK_DEV" 1)"
PART3="$(part_path "$WORK_DEV" 3)"
for p in "$PART1" "$PART3"; do
  [ -b "$p" ] || { echo "Expected partition $p did not appear." >&2; exit 1; }
done

if [ "$SYNC_ONLY" -ne 1 ]; then
  mkfs.vfat -n cidata "$PART3" >/dev/null
fi

MNT_VENTOY="$(mktemp -d)"
MNT_CIDATA="$(mktemp -d)"
mount "$PART1" "$MNT_VENTOY"
mount "$PART3" "$MNT_CIDATA"

echo "Copying staged Ventoy configs and ISO (${ISO_NAME}) to partition 1..."
mkdir -p "${MNT_VENTOY}/ventoy" "${MNT_VENTOY}/iso" "${MNT_VENTOY}/autoinstall/${DISTRO_KEY}"
cp -f "$VENTOY_JSON" "${MNT_VENTOY}/ventoy/ventoy.json"
cp -f "$AUTOINSTALL_YAML" "${MNT_VENTOY}/autoinstall/${DISTRO_KEY}/autoinstall.yaml"
cp -f "$USER_DATA" "${MNT_VENTOY}/autoinstall/${DISTRO_KEY}/user-data"
cp -f "$META_DATA" "${MNT_VENTOY}/autoinstall/${DISTRO_KEY}/meta-data"
rsync --info=progress2 -rth --size-only --no-perms --no-owner --no-group --modify-window=2 "$ISO_PATH" "${MNT_VENTOY}/iso/${ISO_NAME}"

echo "Copying user-data and meta-data to cidata partition 3..."
cp -f "$USER_DATA" "${MNT_CIDATA}/user-data"
cp -f "$META_DATA" "${MNT_CIDATA}/meta-data"

sync

if [ "$MODE" = "image" ] && [ -n "${SUDO_USER:-}" ]; then
  chown "$SUDO_USER":"$SUDO_USER" "$TARGET"
  chown -R "$SUDO_USER":"$SUDO_USER" "$VENTOY_CACHE_DIR"
fi

echo "Done! Partition layout:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$WORK_DEV"
