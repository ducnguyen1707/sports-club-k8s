#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Generate the read-only kubeconfig to hand to a mentor / reviewer.
#
#   kubectl apply -f k8s/mentor-rbac.yaml
#   SERVER=https://<master-eip>:6443 bash ci/gen-mentor-kubeconfig.sh > mentor.kubeconfig
#
# stdout is the kubeconfig ONLY. All commentary and the permission checks go
# to stderr, so redirecting to a file gives a clean, usable config.
#
# THIS FILE IS A CREDENTIAL. Send it over something private (password manager,
# Signal, an encrypted attachment) — not Slack, email or a git repo.
# Revoke at any time with:
#     kubectl -n mentor-access delete secret mentor-token
# ---------------------------------------------------------------------------
set -euo pipefail

NS="mentor-access"
SA="mentor"
SECRET="mentor-token"
SERVER="${SERVER:?set SERVER=https://<master-eip>:6443}"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

echo "==> waiting for the ServiceAccount token" >&2
for _ in $(seq 1 30); do
  TOKEN="$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [ -n "${TOKEN:-}" ] && break
  sleep 2
done
[ -n "${TOKEN:-}" ] || { echo "ERROR: token never appeared. Did you apply k8s/mentor-rbac.yaml?" >&2; exit 1; }

TOKEN="$(echo "$TOKEN" | base64 -d)"
CA="$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.ca\.crt}')"

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: sports-club-rke2
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
users:
  - name: mentor
    user:
      token: ${TOKEN}
contexts:
  - name: mentor@sports-club-rke2
    context:
      cluster: sports-club-rke2
      user: mentor
      namespace: sports-club
current-context: mentor@sports-club-rke2
EOF

{
  echo
  echo "==> verifying the credential is genuinely read-only"
  printf '  %-42s ' "get nodes (want yes):";            KUBECONFIG="$OUT" kubectl auth can-i get nodes || true
  printf '  %-42s ' "list pods -A (want yes):";         KUBECONFIG="$OUT" kubectl auth can-i list pods --all-namespaces || true
  printf '  %-42s ' "read pod logs (want yes):";        KUBECONFIG="$OUT" kubectl auth can-i get pods/log -n sports-club || true
  printf '  %-42s ' "get secrets ANYWHERE (want no):";  KUBECONFIG="$OUT" kubectl auth can-i get secrets --all-namespaces || true
  printf '  %-42s ' "delete pods (want no):";           KUBECONFIG="$OUT" kubectl auth can-i delete pods --all-namespaces || true
  printf '  %-42s ' "create deployments (want no):";    KUBECONFIG="$OUT" kubectl auth can-i create deployments --all-namespaces || true
  printf '  %-42s ' "delete namespaces (want no):";     KUBECONFIG="$OUT" kubectl auth can-i delete namespaces || true
  echo
  echo "==> stdout below is the kubeconfig. Send it privately; it is a credential."
  echo "==> revoke with: kubectl -n ${NS} delete secret ${SECRET}"
  echo
} >&2

cat "$OUT"
