#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Generates the kubeconfig that CI uses to deploy, then prints it base64-encoded
# so you can paste it into the GitHub repo secret KUBE_CONFIG.
#
# Run this ON THE MASTER (or anywhere with cluster-admin kubectl access), once.
#
# The resulting credential is the NAMESPACE-SCOPED ServiceAccount from
# k8s/deploy-rbac.yaml — not cluster-admin. Verify with the auth can-i checks
# printed at the end.
# ---------------------------------------------------------------------------
set -euo pipefail

NS="sports-club"
SA="sports-club-deployer"
SECRET="${SA}-token"
# Public endpoint CI must reach. Pass explicitly:  SERVER=https://<ip>:6443 bash ...
SERVER="${SERVER:?set SERVER=https://<master-ip>:6443}"

command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }

echo "==> waiting for the ServiceAccount token to be populated"
for _ in $(seq 1 30); do
  TOKEN="$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [ -n "${TOKEN:-}" ] && break
  sleep 2
done
[ -n "${TOKEN:-}" ] || { echo "ERROR: token never appeared. Did you apply k8s/deploy-rbac.yaml?"; exit 1; }

TOKEN="$(echo "$TOKEN" | base64 -d)"
CA="$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.ca\.crt}')"

OUT="$(mktemp)"
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: rke2
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
users:
  - name: ${SA}
    user:
      token: ${TOKEN}
contexts:
  - name: ${SA}@rke2
    context:
      cluster: rke2
      user: ${SA}
      namespace: ${NS}
current-context: ${SA}@rke2
EOF

echo
echo "==> verifying the credential is properly scoped"
echo -n "  can deploy in ${NS} (want yes): "
KUBECONFIG="$OUT" kubectl auth can-i create deployments -n "$NS" || true
echo -n "  can read secrets (want no):    "
KUBECONFIG="$OUT" kubectl auth can-i get secrets -n "$NS" || true
echo -n "  can touch kube-system (want no): "
KUBECONFIG="$OUT" kubectl auth can-i list pods -n kube-system || true
echo -n "  can delete namespaces (want no): "
KUBECONFIG="$OUT" kubectl auth can-i delete namespaces || true

echo
echo "============================================================"
echo "Add this as GitHub repo secret  KUBE_CONFIG"
echo "  gh secret set KUBE_CONFIG"
echo "============================================================"
base64 -w0 < "$OUT"; echo
rm -f "$OUT"
