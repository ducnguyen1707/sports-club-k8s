# Wiring MySQL metrics into the existing monitoring stack

## How monitoring actually works on this cluster

Prometheus/Grafana/Alertmanager are **NOT** in Kubernetes. They run as
**Docker Compose containers on the worker host**, in `/opt/monitoring/`, all
with `network_mode: host`.

They still scrape in-cluster targets, because a cluster node's host network
namespace contains kube-proxy's iptables rules — so a **ClusterIP is reachable
from the host**. That's how Longhorn is already scraped (`10.43.29.213:9500`).

`mysqld_exporter` follows the exact same pattern: it runs as a sidecar in the
MySQL pod, and Prometheus reaches it on the `mysql` Service's ClusterIP:9104.

```
   worker host (Docker Compose)                  Kubernetes
  ┌───────────────────────────┐        ┌──────────────────────────┐
  │  prometheus  :9090        │───────▶│ mysql svc ClusterIP:9104 │
  │  grafana     :3000        │        │   └─ mysqld-exporter     │
  │  alertmanager:9093        │        │      (sidecar)           │
  │  cadvisor    :8080        │        │   └─ mysql :3306         │
  │  node-exporter :9100      │        └──────────────────────────┘
  └───────────────────────────┘
```

## Setup (run once, after the app is deployed)

**1. Get the ClusterIP** — from the master:
```bash
kubectl -n sports-club get svc mysql -o jsonpath='{.spec.clusterIP}'
```

**2. Add the scrape job** — on the **worker**, edit `/opt/monitoring/prometheus.yml`
and append to `scrape_configs:` (substitute the IP from step 1):
```yaml
  - job_name: 'mysql'
    static_configs:
      - targets: ['<MYSQL_CLUSTER_IP>:9104']
        labels:
          service: sports-club
```

**3. Add the alert rules** — append `monitoring/mysql-alerts.yml` (this repo)
into the `groups:` list of `/opt/monitoring/alerts.yml` on the worker.

**4. Reload Prometheus** (no restart needed):
```bash
sudo docker exec prometheus kill -HUP 1
# or, if that fails:
cd /opt/monitoring && sudo docker compose restart prometheus
```

**5. Verify** the target is UP:
```bash
curl -s localhost:9090/api/v1/targets?state=active \
  | jq -r '.data.activeTargets[] | select(.labels.job=="mysql") | .health'
```

## ⚠️ The ClusterIP caveat

A Service's ClusterIP is stable for that Service's lifetime, but **changes if
the Service is deleted and recreated** (e.g. `kubectl delete -k`). If the
`mysql` target goes DOWN after a teardown/redeploy, re-run step 1 and update
the IP. The same caveat already applies to the Longhorn target.

To avoid it long-term, the durable options are a NodePort (but the SG opens
30000-32767 to the world, so metrics would be public) or moving Prometheus
in-cluster with proper service discovery — a bigger change, noted as future
work rather than done here.

## Grafana dashboard

Import dashboard ID **7362** ("MySQL Overview" by Percona) — it's built for
mysqld_exporter and works with no modification.
