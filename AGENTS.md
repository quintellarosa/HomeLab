# HomeLab Ansible Repository — Agent Guidelines

This repository automates a personal HomeLab workstation (**Dell Precision 7550** — Intel Xeon W-10855M, 12 vCPUs, 61 GiB RAM, 3 NVMe SSDs, running Ubuntu 26.04.1 LTS) and a KVM-hosted **Windows Server 2025 Domain Controller** (`LclWinLabDomCtl`).

---

## Hard Constraints & Architectural Rules

1. **NEVER modify `roles/PostgreSQL/` without asking the user first.**
   - `roles/PostgreSQL/` must remain 100% generic (base PostgreSQL install, dynamic libvirt bridge listener discovery via `virsh net-info default`, systemd drop-in `wait-libvirt-nic.conf`).
   - All application-specific PostgreSQL tasks (roles, databases, extensions, `pg_hba.conf` pod CIDR rules, firewall rules, `ALTER SYSTEM` tuning) MUST live inside the respective application role (`AWX`, `GitLabCEOmnibus`, `Keycloak`, `Backstage`, etc.).
2. **Independent per-service PostgreSQL configuration.**
   - Never assume applications share a single PostgreSQL server. Each database-backed service has its own independent block under `all.vars.postgresql.<service>` in `inventory.yml` (`host`, `port`, `sslmode`, `database`, `user`).
   - Sharing the host PostgreSQL instance today is coincidental; every role must work if pointed at a different external PostgreSQL server.
3. **Single encrypted Ansible Vault file (`vault/vault.yml`).**
   - All secrets live in `vault/vault.yml` (loaded via `vars_files: [../vault/vault.yml]` in playbooks) and must be documented with placeholder values in `vault/vault.yml.example`.
   - Do **not** introduce `group_vars/` or `host_vars/` directories for secrets.
4. **Cross-distro Linux roles (`ansible.builtin.*` only).**
   - All Linux roles must support `Debian`, `RedHat`, and `Suse` OS families and use **only** `ansible.builtin.*` modules (no external Galaxy collection dependencies on Linux workstation roles).
   - Windows roles (`WinSvrAD`, `WinSvrDNS`, `WinSvrDHCP`) may use `ansible.windows`, `community.windows`, and `microsoft.ad`.
5. **No hardcoded `virbr0` or subnet assumptions.**
   - Derive bridge, domain, gateway, subnet, DNS, and IP ranges from `all.vars.network` in `inventory.yml` (or dynamic `virsh net-info default` discovery where appropriate).
6. **Clean Kubernetes deployments.**
   - Set `revisionHistoryLimit: 2` on custom Deployments so old ReplicaSets don't accumulate.
   - Expose web UIs over trusted HTTPS via Cilium Ingress (`ingressClassName: cilium`) + `cert-manager` (`cert-manager.io/cluster-issuer: homelab-ca`) and mount `/etc/kubernetes/homelab-root-ca.crt` into pods that make outbound HTTPS calls inside the HomeLab.

---

## Repository Structure

### Inventory (`inventory.yml`)
- `all.vars.network`: `virbr0`, domain `quintellarosa.home`, CIDR `192.168.122.0/24` (`255.255.255.0`), gateway `192.168.122.1`, DNS primary `192.168.122.2` / secondary `8.8.8.8`, ranges: `static` `.2–.100`, `dhcp` `.101–.200`, `metallb` `.240–.250`.
- `all.vars.postgresql`: independent entries for `awx`, `gitlab`, `backstage`, `keycloak`.
- `all.children`:
  - `PersonalComputers` → `DellPrecision7550` (`ansible_connection: local`, `ansible_become_exe` chooses `sudo.ws` on Ubuntu 26.04 when present, else `sudo`).
  - `DomainControllers` → `LclWinLabDomCtl` (`ansible_host: "{{ network.dns.primary }}"`, SSH + PowerShell, user `Administrator`, `~/.ssh/id_ed25519`).

### Playbooks
- `playbooks/DellPrecision7550.yml` (`hosts: DellPrecision7550`, `become: true`) — run with:
  ```bash
  ansible-playbook playbooks/DellPrecision7550.yml -K --ask-vault-pass
  ```
  Role execution order:
  1. `NetworkValidation` (validates `network` CIDR/range math via Python `ipaddress`)
  2. Desktop & tools: `EssentialTools`, `UbuntuGnomeCustomization`, `GoogleChrome`, `GoogleAntigravityIDE`, `Thunderbird`, `InSync` (`Bluetooth` commented out)
  3. Host infra: `KVM` (libvirt/QEMU, `default` NAT bridge with DHCP disabled, PCIe passthrough IOMMU + VFIO permanently binding Samsung PM9A1 NVMe `144d:a80a`), `PostgreSQL`, `Docker`
  4. Kubernetes core: `K8sMasterInstall` (kubeadm `v1.37`, containerd CRI, untainted control plane), `K8sCNICilium` (kube-proxy replacement + shared Envoy Ingress at `192.168.122.240`), `K8sMetalLB` (`192.168.122.240–.250`), `K8sCertManager` (`homelab-ca` Root CA trusted in host OS + Chrome NSS DB + `/etc/kubernetes/homelab-root-ca.crt`), `K8sStorageClass` (Rancher `local-path` default), `SplitDNS` (host `systemd-resolved` + CoreDNS forwarder for `quintellarosa.home` → `192.168.122.2`)
  5. Platform apps:
     - `AWXOperator` + `AWX` → `https://awx.quintellarosa.home` (external PG `awx`, `ReadWriteOnce` projects PVC)
     - `GitLabCEOmnibus` → `https://gitlab.quintellarosa.home` (GitLab CE `19.6.2-ce.0`, external PG `gitlabhq_production`, SSH LoadBalancer `192.168.122.241:22`)
     - `Keycloak` → `https://keycloak.quintellarosa.home` (Keycloak `26.8.2`, external PG `keycloak`, realm `homelab`, AD LDAP federation to `ldap://192.168.122.2:389`)
     - `Backstage` → `https://backstage.quintellarosa.home` (RHDH Community `1.9`, external PG `backstage` with `pluginDivisionMode: schema` + `ensureExists: false` + `ensureSchemaExists: true`, dual sign-in via Keycloak OIDC + GitLab OAuth, RBAC Admin + UI plugin)
     - `ArgoCD` → `https://argocd.quintellarosa.home` (Argo CD `v3.6.3`, Kubernetes-native/no PG, Cilium TLS termination with `server.insecure: "true"`, HomeLab CA trust, Keycloak OIDC SSO + RBAC admin mapping, `/usr/local/bin/argocd` CLI)
- `playbooks/LclWinLabDmnCtl.yml` (`hosts: localhost` for `NetworkValidation`, then `hosts: DomainControllers` for `WinSvrAD`, `WinSvrDNS`, `WinSvrDHCP`) — run with:
  ```bash
  ansible-playbook playbooks/LclWinLabDmnCtl.yml --ask-vault-pass
  ```

---

## Known Environment Gotchas & Lessons Learned

- **Ubuntu 26.04 specifics**: Uses `dracut` (wrapped by `update-initramfs -u -k all` on Debian/Ubuntu — avoid `dracut --regenerate-all` which fails on orphaned `/lib/modules/*` dirs), `sudo-rs` default (`ansible_become_exe` selects `sudo.ws`), `containerd v2.4.2`, PostgreSQL 18.
- **`psql` variable interpolation**: `psql -c` does NOT expand `:'var'` / `:"var"` placeholders; always pass SQL over stdin with `psql -f -`.
- **Jinja2 templates & inline Python**:
  - Avoid `-%}` on indented YAML templates (Ansible has `trim_blocks=True` and `-%}` eats leading spaces).
  - Never put literal `{{` or `}}` inside inline `python3 -c` scripts in Ansible tasks (Jinja2 will parse them).
- **AWX Operator**: Rewrite retired `gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0` → `quay.io/brancz/kube-rbac-proxy:v0.15.0` via Kustomize; use `projects_storage_access_mode: ReadWriteOnce` for `local-path`.
- **GitLab CE 19.6**:
  - Copy read-only mounted CA cert into `/etc/gitlab/trusted-certs/` via Ruby `FileUtils.cp` (avoid `EROFS`).
  - Set `max_locks_per_transaction = 512` (in `GitLabCEOmnibus`, not `PostgreSQL`), `monitoring_whitelist` for pod CIDR, and `organization_id` (`Organizations::Organization.default_organization.id`) when creating `Doorkeeper::Application` OAuth apps.
- **RHDH / Backstage 1.9**:
  - Mount an `emptyDir` at `/opt/app-root/src/dynamic-plugins-root` (required by `PluginScanner`).
  - Set `ensureExists: false` and `ensureSchemaExists: true` under `backend.database` so Backstage doesn't probe the `postgres` DB.
  - Place `dangerouslyAllowSignInWithoutUserInCatalog: true` inside each `signIn.resolvers` entry.
- **Argo CD v3.x**: Apply upstream `install.yaml` with `kubectl apply --server-side --force-conflicts` (CRDs exceed client-side annotation size limit).
- **Windows Server DNS (`ansible.windows` 3.3.0)**: `win_dns_zone` has an upstream bug with `replication: none` + `dynamic_update`; `WinSvrDNS` uses native `DnsServer` PowerShell cmdlets instead.

---

## Validation Workflow

Because playbooks load encrypted `vault/vault.yml`, running `ansible-playbook --syntax-check` directly on `playbooks/*.yml` requires the vault password. Validate edits safely without decrypting the vault:
1. Validate YAML syntax, Jinja2 template rendering (`trim_blocks=True`), and inline Python AST (`ast.parse`) + absence of `{{`/`}}`.
2. Confirm `roles/PostgreSQL/` contains no app-specific references.
3. Test individual roles with a temporary playbook in `--check` mode passing dummy `-e vault_*` values, and verify inventory with `ansible-inventory -i inventory.yml --graph --vars`.
