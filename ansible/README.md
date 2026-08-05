# Ansible — cluster operations (IaC)

Infrastructure as Code for the **cluster itself** — disk sizing, security posture,
health diagnostics. The application is deployed by Kubernetes; this is day-2
operations on the two Rocky Linux 9 EC2 nodes underneath it.

## Setup

```bash
pip install --user ansible-core
ansible-galaxy collection install ansible.posix     # firewalld + sysctl modules
```

`ansible.cfg` in this directory sets the inventory, disables host-key prompts and
enables SSH pipelining — so run all commands **from `ansible/`**.

```bash
ansible cluster -m ping        # verify connectivity to both nodes
```

## Inventory

`inventories/production.ini` — this is where **all per-node configuration lives**.

| Host | Address | Why |
|---|---|---|
| `rke2-master` | `13.126.83.203` (Elastic IP) | stable, reachable from anywhere |
| `rke2-worker` | `172.31.34.225` (**private**) | has no Elastic IP; its public address changes on every restart |

The worker is therefore addressed by its **stable private IP** and reached via a
`ProxyCommand` through the master. That's why `ansible cluster -m ping` works from
your laptop even though `172.31.x.x` isn't routable from outside the VPC.

## Playbooks

### `resize-disk.yml` — grow a node's root volume

Handles **both halves** of a resize: the AWS API call *and* `growpart` +
`xfs_growfs` inside the OS. (Terraform only does the first; it also can't safely
own a root volume, since that belongs to `aws_instance.root_block_device` —
importing it risks Terraform proposing to *replace* a live node.)

**Sizing lives in the inventory**, so growing a node later is a one-number change:

```ini
rke2-worker ... ebs_volume_id=vol-021015865607ba4f4 ebs_size_gb=25
```

```bash
ansible-playbook playbooks/resize-disk.yml --limit worker
```

Fully idempotent — re-running when already correct reports `changed=0` and skips
the AWS call entirely, which also avoids tripping AWS's **~6 hour cooldown**
between modifications of the same volume. gp3 resizes online, so no downtime.

It detects the root device rather than assuming one: on t3 (Nitro) the kernel
sees `/dev/nvme0n1p4` even though the AWS console reports `/dev/sda1`.

### `security-hardening.yml` — verify by default, change on request

`CLUSTER_GUIDE.md` §5 records that SELinux enforcing, key-only SSH and fail2ban
are **already applied**. This is therefore a **drift detector**, not a first-time
hardening run — so the default invocation changes nothing:

```bash
ansible-playbook playbooks/security-hardening.yml              # read-only audit
ansible-playbook playbooks/security-hardening.yml --tags harden  # apply config
ansible-playbook playbooks/security-hardening.yml --tags patch   # security errata only
```

Safety properties worth knowing:
- `serial: 1` — never touches both cluster nodes at once
- **Patching is security errata only**, and excludes `rke2-*`, `kernel*`,
  `containerd*`. An unbounded `dnf update '*'` on a live Kubernetes node can pull
  a new kernel or container runtime and take the control plane down.
- **SELinux is reported, never flipped.** Changing it on a node already running
  containerd/kubelet can trigger AVC denials against unlabelled files and needs a
  relabel plus reboot — do that deliberately, not as a side effect.
- sshd changes are validated with `sshd -t` before install and applied with
  `reload`, not `restart`, so your current session survives.
- Never auto-reboots; it reports when one is required.

### `cluster-health.yml` — diagnostics

```bash
ansible-playbook playbooks/cluster-health.yml
```

Node metrics (CPU/memory/disk), RKE2 and containerd state, then Kubernetes-level
checks from the master: node readiness, unhealthy pod count, PVs, memory pressure,
recent events.

Two Rocky/RKE2-specific details it gets right:
- **containerd has no standalone systemd unit under RKE2** — it's a child of
  `rke2-server`/`rke2-agent`, so the check probes the socket at
  `/run/k3s/containerd/containerd.sock` instead of `systemctl is-active containerd`.
- The Docker Compose monitoring check uses `become`, because `rocky` is
  deliberately **not** in the `docker` group.

## Tips

```bash
ansible-playbook playbooks/<name>.yml --check      # dry run
ansible-playbook playbooks/<name>.yml --limit worker
ansible-playbook playbooks/<name>.yml -vvv         # verbose
```

## Gotchas hit while building these

- A playbook file must be a **single YAML document**. A stray `---` mid-file makes
  the whole file unparseable and *neither* play runs.
- Rocky logs SSH auth to `/var/log/secure`, not Debian's `/var/log/auth.log` — the
  fail2ban jail uses `backend = systemd` to sidestep the question entirely.
- `kernel.unprivileged_userns_clone` is a **Debian kernel patch** and does not
  exist on RHEL 9. Setting it aborts the play.
- `systemctl is-active` prints `inactive` *and* returns non-zero, so `a || b`
  chains emit both words. Use `--quiet`.
