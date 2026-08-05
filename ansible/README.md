# Ansible for Cluster Management

Infrastructure as Code for cluster operations — not for the app (that's Kubernetes), but for the **cluster itself** (security patches, hardening, monitoring, day-2 operations).

## Why Ansible instead of Terraform?

- **Terraform:** state-based, infrastructure-focused. Great for EC2 instances, security groups, networking.
- **Ansible:** task-based, configuration-focused. Great for running commands, configuring services, applying patches across nodes.

**This repo uses both:** Terraform/CloudFormation manages EC2 infra (in progress); Ansible manages the cluster's Linux config and Kubernetes operations.

## Quick start

```bash
# Install Ansible
pip install ansible

# Verify connectivity
ansible -i inventories/production.ini all -m ping

# Run security hardening
ansible-playbook -i inventories/production.ini playbooks/security-hardening.yml

# Check cluster health
ansible-playbook -i inventories/production.ini playbooks/cluster-health.yml
```

## Inventory

Two inventories:

| File | Purpose |
|---|---|
| `inventories/production.ini` | Real cluster — master + worker in ap-south-1 |
| `inventories/local.ini` | Test against localhost (for dry-runs, testing) |

**Hosts in production:**
- `rke2-master` — 13.126.83.203 (EIP, stable)
- `rke2-worker` — 172.31.34.225 (private IP, changes on restart)

**Update the worker IP if it changes** (no Elastic IP attached to it). The master's EIP is stable.

## Playbooks

### `security-hardening.yml`

Hardens both master and worker:
- Updates system packages (security patches)
- Configures firewalld (80, 443, 6443 inbound)
- SSH hardening (no root login, no password auth, no X11)
- SELinux enforcing mode
- fail2ban for SSH brute-force protection
- Audit logging for Kubernetes-critical paths
- Kernel hardening (rp_filter, namespace restrictions)

**Run before initial deployment or after a security incident:**
```bash
ansible-playbook -i inventories/production.ini playbooks/security-hardening.yml
```

**Idempotent:** safe to run multiple times. Only changes state if needed.

### `cluster-health.yml`

Diagnostics and monitoring — two parts:

**Part 1: Node-level metrics (runs on all nodes)**
- CPU/memory/disk usage
- Containerd and RKE2 systemd status
- Service restart counts (sign of crashes)

**Part 2: Kubernetes diagnostics (runs on master only)**
- Node readiness status
- Pod health (count of non-Running pods)
- PersistentVolume status
- Memory pressure conditions
- Recent cluster events

**Run on-demand for troubleshooting:**
```bash
ansible-playbook -i inventories/production.ini playbooks/cluster-health.yml
```

**Example output:**
```
Node: rke2-master
CPU Usage: 42.5%
Memory Usage: 68.3%
Disk Usage: 48%
Containerd: active
RKE2: active

=== NODE STATUS ===
rke2-master     True
rke2-worker     True

=== UNHEALTHY PODS ===
Count: 0

=== RECENT EVENTS ===
...
```

## Roles (future structure)

Roles organize playbooks by function. Create `roles/` subdirectories:

| Role | Purpose |
|---|---|
| `security/` | Firewall, fail2ban, SELinux, audit logging |
| `monitoring/` | Prometheus config, log aggregation setup |
| `updates/` | Security patches, version upgrades |

Currently playbooks are flat; move them into roles when complexity grows.

## Extending Ansible

### Add a new playbook

1. Create `playbooks/my-playbook.yml`
2. Define tasks, handlers, variables
3. Test on `local.ini` first:
   ```bash
   ansible-playbook -i inventories/local.ini playbooks/my-playbook.yml
   ```
4. Run against production:
   ```bash
   ansible-playbook -i inventories/production.ini playbooks/my-playbook.yml
   ```

### Add a new host

Update `inventories/production.ini`:
```ini
[worker]
rke2-worker-1  ansible_host=<IP>  ansible_user=rocky  ansible_ssh_private_key_file=~/.ssh/rke2-mumbai.pem
rke2-worker-2  ansible_host=<IP>  ansible_user=rocky  ansible_ssh_private_key_file=~/.ssh/rke2-mumbai.pem
```

Then target that host:
```bash
ansible-playbook -i inventories/production.ini -l rke2-worker-2 playbooks/security-hardening.yml
```

## Tips

**Dry-run (check mode):**
```bash
ansible-playbook -i inventories/production.ini playbooks/security-hardening.yml --check
```
Shows what *would* change without applying it.

**Limit to one host:**
```bash
ansible-playbook -i inventories/production.ini playbooks/cluster-health.yml -l rke2-master
```

**Run with extra verbosity:**
```bash
ansible-playbook -i inventories/production.ini playbooks/cluster-health.yml -vvv
```

**SSH key not in default location?**
```bash
ansible-playbook -i inventories/production.ini playbooks/security-hardening.yml \
  -e "ansible_ssh_private_key_file=/path/to/key.pem"
```

## Security

- **Inventories contain sensitive IPs** — git-ignore them if they ever contain secrets (they currently don't; passwords/keys are in keyfiles)
- **SSH keys:** store in `~/.ssh/` with mode `0600`, never commit them
- **Playbook outputs:** may contain IPs/versions in logs — be careful if sharing with others
- **Idempotency:** all playbooks are idempotent (safe to re-run)

## Next steps

1. **Terraform for EC2 automation** — spin up/down nodes, manage security groups
2. **GitOps loop** — a cron job that `ansible-playbook cluster-health.yml` and reports to a Slack channel
3. **Pre-deploy validation** — run `--check` mode in CI before approving a deploy
