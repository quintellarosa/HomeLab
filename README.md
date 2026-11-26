# HomeLab

Automated, cross-distro workstation lifecycle for a multi-NVMe Linux notebook:
1. **Phase 1 (`playbooks/build-ventoy.yml`)**: Downloads and verifies distro ISOs, generates unattended install configs + `cidata` seed images with strict disk-safety checks, and stages Ventoy configuration.
2. **Phase 2 (`playbooks/workstation.yml`)**: Post-install Ansible configuration once `git`, `gh`, and `ansible` are bootstrapped on the fresh system.

## Disk Safety Contract

Drives are **never** matched by `/dev/nvmeXnY`. Both `test_vm` and `laptop` profiles in `group_vars/all/disks.yml` match:
- Target OS SSD strictly by hardware `serial` (only this disk is declared to the installer).
- Preserved `/home` (`btrfs`) strictly by `UUID` (or `LABEL` in the VM test lab) and wired via `/etc/fstab` in `late-commands`.
- Protected drives (e.g., Windows SSD) verified via `early-commands` so the installer aborts immediately on any mismatch.

## Quick Start (Safe 3-NVMe VM Testing First)

1. Create your local secrets file:
   ```bash
   cp group_vars/secrets.yml.example group_vars/secrets.yml
   openssl passwd -6
   # Paste the hash into group_vars/secrets.yml
   ```
2. Build the staged Ventoy artifacts and download/verify Ubuntu 26.10 Desktop:
   ```bash
   ansible-playbook playbooks/build-ventoy.yml
   ```
   *(Pass `-e skip_iso_download=true` when iterating only on config/templates.)*
3. Initialize and boot the 3-NVMe QEMU/KVM OVMF test lab:
   ```bash
   ./scripts/vm-test-lab.sh init
   ./scripts/vm-test-lab.sh boot-install
   ```
4. Once installation completes and shuts down, boot the installed OS and verify `/home/quintellarosa/DO_NOT_WIPE_SENTINEL.txt`, `ansible`, `git`, and `gh`:
   ```bash
   ./scripts/vm-test-lab.sh boot-installed
   ```

## Testing with a Full Ventoy + `cidata` Layout in QEMU/KVM

1. Build a virtual 3-partition Ventoy + `cidata` disk image (`test_vm` profile):
   ```bash
   sudo ./scripts/prepare-ventoy-usb.sh --image
   ```
2. Boot the VM from that Ventoy image:
   ```bash
   ./scripts/vm-test-lab.sh init
   VENTOY_IMG=build/vm/ventoy-test.img ./scripts/vm-test-lab.sh boot-install
   ./scripts/vm-test-lab.sh boot-installed
   ```

*(You can also test a physical USB stick prepared with `test_vm` by passing `VENTOY_IMG=/dev/disk/by-id/usb-...`, which typically requires `sudo` for raw block access.)*

## Syncing to a Real Ventoy USB Stick

1. Prepare the physical USB drive once with Ventoy + `cidata` using the **laptop** profile:
   ```bash
   ansible-playbook playbooks/build-ventoy.yml -e disk_profile=laptop -e skip_iso_download=true
   sudo ./scripts/prepare-ventoy-usb.sh --device /dev/disk/by-id/usb-...
   ```
2. On future config updates (without reformatting the USB stick), mount both USB partitions and sync:
   ```bash
   ansible-playbook playbooks/build-ventoy.yml \
     -e disk_profile=laptop \
     -e sync_usb_mount_dir=/media/$USER/Ventoy \
     -e sync_cidata_mount_dir=/media/$USER/cidata
   ```
