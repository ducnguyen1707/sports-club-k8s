#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Post-deploy smoke tests.
#
# Runs against the in-cluster Service via `kubectl run`, so it works without
# the Ingress hostname resolving from wherever CI happens to be running.
#
# The negative checks (404 on the SQL dump, 403 on directory listing) matter
# as much as the positive ones — the upstream repo ships its database dump
# INSIDE the web root, and that dump contains the default admin credentials.
# ---------------------------------------------------------------------------
set -euo pipefail

NS="${NS:-sports-club}"
SVC="http://sports-club-app.${NS}.svc.cluster.local"
POD="smoke-$$"
FAILED=0

cleanup() { kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> starting probe pod"
kubectl -n "$NS" run "$POD" --image=curlimages/curl:latest --restart=Never \
  --command -- sleep 300 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=90s >/dev/null

# curl inside the probe pod, returning just the HTTP status code
code() { kubectl -n "$NS" exec "$POD" -- curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1"; }

check() { # check <description> <url> <expected-code>
  local desc="$1" url="$2" want="$3" got
  got="$(code "$url" || echo 000)"
  if [ "$got" = "$want" ]; then
    printf '  PASS  %-46s %s\n' "$desc" "$got"
  else
    printf '  FAIL  %-46s got %s, want %s\n' "$desc" "$got" "$want"
    FAILED=1
  fi
}

echo "==> checks"
check "login page serves"                "$SVC/index.php"           200
check "root serves"                      "$SVC/"                    200

# Must NOT be downloadable — contains plaintext admin credentials
check "DB dump NOT public"               "$SVC/sports_club_db.sql"  404
check "pptx NOT public"                  "$SVC/SPORTS%20CLUB.pptx"  404

# Apache hardening: directory listing disabled
check "no directory listing (images/)"   "$SVC/images/"             403

# ---------------------------------------------------------------------------
# Login redirect. This specifically guards the output_buffering regression:
# 22 upstream files emit a blank line before their opening <?php tag, so with
# buffering off the header("location: ...") after a successful login is
# dropped and the user gets a blank page — while the login itself "succeeds".
# Only the SUCCESS path calls header(), so bad credentials would not catch it.
#
# Uses the default credentials. After you change the admin password (which you
# should), either set SMOKE_USER/SMOKE_PASS or set SMOKE_LOGIN=0 to skip.
# ---------------------------------------------------------------------------
if [ "${SMOKE_LOGIN:-1}" = "1" ]; then
  echo "==> login redirect"
  SMOKE_USER="${SMOKE_USER:-admin1}"
  SMOKE_PASS="${SMOKE_PASS:-admin1}"
  login_code="$(kubectl -n "$NS" exec "$POD" -- curl -s -o /dev/null -w '%{http_code}' \
      --max-time 10 -d "user_id_auth=${SMOKE_USER}&pass_key=${SMOKE_PASS}" \
      "$SVC/secure_login.php" || echo 000)"
  if [ "$login_code" = "302" ]; then
    printf '  PASS  %-46s %s\n' "successful login redirects" "$login_code"
  else
    printf '  FAIL  %-46s got %s, want 302 (output_buffering off?)\n' \
      "successful login redirects" "$login_code"
    FAILED=1
  fi
else
  echo "==> login redirect check skipped (SMOKE_LOGIN=0)"
fi

echo "==> header checks"
if kubectl -n "$NS" exec "$POD" -- curl -sI --max-time 10 "$SVC/index.php" | grep -qi '^x-powered-by'; then
  echo "  FAIL  X-Powered-By header exposed"; FAILED=1
else
  echo "  PASS  X-Powered-By hidden"
fi

echo "==> workload state"
kubectl -n "$NS" get deployment sports-club-app -o wide
kubectl -n "$NS" get statefulset mysql -o wide

echo
if [ "$FAILED" -eq 0 ]; then echo "SMOKE TESTS PASSED"; else echo "SMOKE TESTS FAILED"; fi
exit "$FAILED"
