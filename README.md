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

## Syncing to a Real Ventoy USB Stick

When switching from VM testing (`test_vm`) to your real notebook (`laptop`):
```bash
ansible-playbook playbooks/build-ventoy.yml \
  -e disk_profile=laptop \
  -e sync_usb_mount_dir=/media/$USER/Ventoy
```
If using a dedicated `cidata` partition on the Ventoy USB stick (recommended for Ubuntu Desktop), copy `build/ventoy-stage/autoinstall/ubuntu_26_10/user-data` and `meta-data` onto that `cidata` FAT32 partition.
