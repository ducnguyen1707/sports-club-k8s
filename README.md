# Sports Club Management System — Kubernetes deployment

Deployment tooling for [shreyansh225/Sports-Club-Management-System](https://github.com/shreyansh225/Sports-Club-Management-System).

## Target environment

| | |
|---|---|
| Platform | **AWS EC2**, ap-south-1 (Mumbai) |
| Nodes | 2 x t3.medium (2 vCPU / 4 GB) |
| **Node OS** | **Rocky Linux 9.8** |
| Kubernetes | RKE2 v1.35.6+rke2r1 (pinned) |
| Runtime | containerd |
| Storage | Longhorn v1.12.0 |
| Ingress | rke2-ingress-nginx (DaemonSet, already running) |
| Monitoring | Prometheus/Grafana/Alertmanager via **Docker Compose on the worker host** (not in-cluster) |

> `runs-on: ubuntu-latest` in the workflow is **GitHub's hosted CI runner**,
> unrelated to the cluster. The image we build is Debian-based
> (`php:8.3-apache`) and runs on the Rocky nodes via containerd — a container's
> base OS need not match the host's.

Upstream is a XAMPP-era PHP/MySQL app with no container support. Everything
here adapts it for Kubernetes **without modifying the vendored source** in
`app/` — all changes are deploy-time overlays.

**Vendored upstream commit:** `f5b6ed342aafe35b9b6d37acb7424f73173ec3ce`

---

## Layout

```
app/Files/              vendored upstream — DO NOT EDIT
docker/
  Dockerfile            php:8.3-apache, mysqli + redis ext
  php-overrides/        env-var DB config replacing hardcoded credentials
k8s/
  namespace.yaml        applied once at setup (NOT by CI — see RBAC note)
  deploy-rbac.yaml      namespace-scoped ServiceAccount used by CI
  secret-template.yaml  never commit a filled-in copy
  base/                 kustomize base
  overlays/production/  hostname + image tag
ansible/
  playbooks/            resize-disk, security-hardening (verify-first), cluster-health
  inventories/          per-node EBS sizing lives here
monitoring/
  README.md             how to wire MySQL metrics into the existing stack
  mysql-alerts.yml      Prometheus alert rules for MySQL
ci/
  smoke-test.sh
  gen-deploy-kubeconfig.sh
.github/workflows/      lint → validate → build → deploy → smoke
```

---

## Things found in upstream that shaped this deployment

These are verified from the source, not assumptions:

| Finding | Handling |
|---|---|
| **`Files/sports_club_db.sql` sits inside the web root**, and contains `INSERT INTO admin VALUES ('admin1','admin1','admin1',…)` | Excluded via `.dockerignore` **and** `rm -f` in the Dockerfile. Smoke test asserts it returns **404**. |
| `Files/SPORTS CLUB.pptx` also in the web root | Same treatment |
| Docroot **must** be `Files/` — dashboard pages do `require '../../include/db_conn.php'` | `COPY app/Files/ → /var/www/html/` |
| `connect.php` connects to database **`tms`**, which doesn't exist in the dump | Override points it at `sports_club_db`. Appears to be dead code, but left working rather than broken. |
| `db_conn.php` also defines `page_protect()` — the session guard every dashboard page calls | Override copies that function **verbatim** |
| PHP 8.1 made mysqli throw exceptions; upstream checks `mysqli_connect_errno()` (pre-8.1 style) | `mysqli_report(MYSQLI_REPORT_OFF)` in the override |
| Sessions are local files, bound to `md5(HTTP_USER_AGENT)` | Redis session store, so any pod can serve any user |
| `table_view.php` calls stored procedure `countGender()` | Works: `GRANT ALL ON db.*` (from `MYSQL_USER`) includes EXECUTE |
| Passwords stored **unhashed** (`admin1/admin1`) | ⚠️ Not fixed — that's an app-logic change. **Change the default password immediately after first login.** |

---

## First-time setup

```bash
# 1. namespace
kubectl apply -f k8s/namespace.yaml

# 2. DB credentials (MySQL reads these on FIRST boot only)
kubectl create secret generic mysql-credentials -n sports-club \
  --from-literal=username=sportsclub \
  --from-literal=password="$(openssl rand -base64 24 | tr -d '/+=')" \
  --from-literal=root-password="$(openssl rand -base64 24 | tr -d '/+=')"

# 3. CI deploy identity
kubectl apply -f k8s/deploy-rbac.yaml

# 4. generate the kubeconfig for CI, add it as a repo secret
SERVER=https://<master-ip>:6443 bash ci/gen-deploy-kubeconfig.sh   # prints base64
gh secret set KUBE_CONFIG                 # paste it

# 5. make the GHCR package public (avoids needing an imagePullSecret)
#    GitHub → Packages → sports-club → Package settings → Change visibility
```

# 6. wire MySQL metrics into the existing Prometheus — see monitoring/README.md

**Ingress is currently deferred** — reach the app with a port-forward:

```bash
kubectl -n sports-club port-forward svc/sports-club-app 8080:80
```

To enable Ingress later, re-add `app-ingress.yaml` to `k8s/base/kustomization.yaml`
and set a hostname. `rke2-ingress-nginx` runs on both nodes, so pointing the
hostname at the master's Elastic IP is stable even though the app runs on the
worker (whose public IP changes on restart).

Manual deploy (CI does this automatically on `main`):
```bash
kubectl apply -k k8s/overlays/production
kubectl -n sports-club rollout status deployment/sports-club-app
bash ci/smoke-test.sh
```

---

## Pipeline

`lint → validate-manifests → build → deploy → smoke-test`

**Split across runner types on purpose:**
- **Build** runs on GitHub-hosted runners — free, unlimited on public repos,
  and it's the CPU-heavy step, so there's no reason to spend cluster capacity
  on it.
- **Deploy** uses the namespace-scoped SA credential above. It does *not* use
  a cluster-admin kubeconfig.

Efficiency choices: `concurrency` cancels superseded runs; `php -l` gates
before the ~450 MB image build; GHA layer caching on buildx; PRs build but
never push or deploy.

The `production` GitHub Environment gates the deploy — add required reviewers
in repo settings to make it a manual approval.

---

## Scaling

The app is **stateless once Redis holds sessions**, so it scales horizontally:
HPA 2→4 replicas at 70% CPU, `maxUnavailable: 0` for zero-downtime rollouts,
`topologySpreadConstraints` to spread across nodes, and a PDB (`minAvailable: 1`).

**Redis was chosen over sticky sessions deliberately.** Sticky sessions
(`sessionAffinity: ClientIP`) "work" but drop every session on that pod when it
restarts — i.e. on *every deploy*. Redis costs one 32Mi pod and makes rolling
updates actually seamless.

### Capacity — measured against requests, not limits

The **scheduler admits on `requests`**, so that is what determines whether pods fit:

| | CPU requests | Memory requests |
|---|---|---|
| MySQL + mysqld_exporter + Redis | 120m | 312Mi |
| 4 × app pods (HPA ceiling) | 200m | 384Mi |
| **Total** | **320m** of ~725m free | **696Mi** of ~2.2Gi free |

`maxReplicas: 4` fits comfortably. (An earlier version of this README said
"roughly 3 app pods" — that was computed from *limits* and was wrong.)

The master is the constrained node at ~155m CPU free, so app pods should stay on
the worker. **A third node remains the real scale-out path** — it also restores
etcd quorum and lets Longhorn use 3-way replication.

**MySQL stays at 1 replica.** Horizontal MySQL means replication and read/write
splitting the app doesn't support. Scale vertically first; this CRUD app won't
outgrow one pod for a long time. It is a single point of failure — mitigate
with etcd/Longhorn backups, not by pretending otherwise.

**Worker disk was the binding constraint and has been resolved.** At 15 GB it sat
at 83% used, leaving only ~300 MB above Longhorn's
`storageMinimalAvailablePercentage: 15` floor — pulling the ~480 MB image would
have dropped it below, making Longhorn mark the node unschedulable so that *no*
volume could be created. Resized to **25 GB** via
`ansible/playbooks/resize-disk.yml`:

| | Before | After |
|---|---|---|
| Worker filesystem | 14G, 2.4G free (84%) | 24G, 13G free (49%) |
| Longhorn available on worker | 2 Gi | **12.11 Gi** |

To grow it again, change `ebs_size_gb` in `ansible/inventories/production.ini`
and re-run the playbook.

---

## Database monitoring

MySQL runs with a **`mysqld_exporter` sidecar** (port 9104), using a dedicated
least-privilege `exporter` user created at first boot — `PROCESS`,
`REPLICATION CLIENT`, and `SELECT` on `performance_schema` only. Not root, not
the app user.

Because Prometheus lives in Docker Compose on the worker *host* rather than in
the cluster, it scrapes the exporter via the `mysql` Service's **ClusterIP** —
the same mechanism already used for Longhorn. Setup steps and the ClusterIP
caveat are in [`monitoring/README.md`](monitoring/README.md).

Grafana dashboard **7362** (Percona MySQL Overview) works as-is.

---

## Known limitations

1. **Passwords are not hashed** — upstream stores them plaintext.
2. **MySQL is a SPOF** — 1 replica.
3. **Redis restart logs everyone out** — sessions are in `emptyDir`, an
   intentional trade to avoid more Longhorn pressure.
4. **`maxReplicas: 4` exceeds real capacity** — see table above.
5. **No TLS yet** — Ingress is HTTP. cert-manager + Let's Encrypt is the
   natural follow-up once a real hostname exists.
6. **Prometheus scrapes MySQL by ClusterIP**, which changes if the Service is
   deleted and recreated. Same caveat as the existing Longhorn target — see
   `monitoring/README.md`.
