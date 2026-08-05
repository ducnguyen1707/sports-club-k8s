# Security & Compliance

Three layers of security in this deployment:

1. **Code scanning** — SonarQube/SonarCloud for PHP vulnerabilities and code quality
2. **Image scanning** — Trivy for container layer vulnerabilities and software composition
3. **Infrastructure as Code** — Ansible for cluster hardening and patch management

---

## 1. Code Scanning (SonarQube / SonarCloud)

Runs after `lint` stage in the pipeline. Scans PHP code for:
- Security vulnerabilities (SQL injection, XSS, hardcoded secrets)
- Code smells (complexity, duplication, maintainability)
- Bug risks (null pointer, logic errors)

### Setup (one-time)

1. **Create a SonarCloud account** (free for public repos):
   - Go to https://sonarcloud.io
   - Sign in with GitHub
   - Authorize the app
   - Create a new organization (or use personal)

2. **Create a project** in SonarCloud:
   - Project key: `sports-club-k8s`
   - Link to GitHub repo `ducnguyen1707/sports-club-k8s`

3. **Generate token** in SonarCloud:
   - Account Settings → Security → Generate Tokens
   - Copy the token

4. **Add to GitHub repo secrets**:
   ```bash
   gh secret set SONAR_TOKEN -b "<token-from-sonarcloud>"
   ```

### Configure quality gates

In SonarCloud project settings:
- **Quality Gate:** set minimum coverage, security ratings
- **Fail Pipeline:** if desired, enable "Automatically fail when gate is not passed"

### View results

After a build on `main`:
1. Go to **Security** tab in GitHub
2. Click **Code scanning** — shows SonarQube findings
3. Go to SonarCloud dashboard for full report

### What to expect

First run may find issues (baseline). Common ones:
- Hardcoded passwords (the `admin1/admin1` default)
- Missing input validation
- SQL injection risks

These are documented as known limitations in the upstream app. **Fix real security issues; flag others in the Quality Gate as "won't fix" with justification.**

---

## 2. Image Scanning (Trivy)

Runs after `build` stage. Scans the Docker image for:
- OS package vulnerabilities (glibc, openssl, etc.)
- Application dependency CVEs
- Known malware signatures

Generates two artifacts:
- **SARIF report** — uploaded to GitHub Security tab, shows per-layer breakdown
- **SBOM (Software Bill of Materials)** — JSON list of all software in the image, useful for compliance

### Setup (automatic with workflow)

The workflow already does this. Just review results after builds.

### Ignore false positives

Edit `.trivyignore` to exclude known non-issues:
```
# Transient dependency in build layer, removed in final image
CVE-2023-12345

# Accepted risk: used in monitoring only, not exposed
CVE-2024-67890
```

### Gating

Currently **informational only** — scans don't block deploy. To gate on CRITICAL:

Edit `.github/workflows/deploy.yml`, in `scan-image` step:
```yaml
- name: Fail on critical vulnerabilities
  run: |
    # Exit non-zero if any CRITICAL found
    if grep -q '"severity": "CRITICAL"' trivy-results.sarif; then
      echo "CRITICAL vulnerabilities detected. See SARIF for details."
      exit 1
    fi
```

### View results

1. **GitHub Security tab** → Code scanning → filter by "trivy"
2. **Artifacts** (GitHub Actions) → `sbom-<tag>.json` for supply chain info
3. **Trivy SARIF format** — integrates with other tools (DefectDojo, GitLab, etc.)

---

## 3. Infrastructure Hardening (Ansible)

Day-2 operations and cluster-level security. See `ansible/README.md` for full details.

**Key playbooks:**
- `security-hardening.yml` — firewall, SSH hardening, SELinux, fail2ban, audit logging
- `cluster-health.yml` — diagnostics, node metrics, Kubernetes health checks

**Run periodically (or after incidents):**
```bash
ansible-playbook -i ansible/inventories/production.ini ansible/playbooks/security-hardening.yml
```

---

## 4. Runtime Security (Future)

Not yet implemented, but recommended follow-ups:

| Tool | Purpose | Where |
|---|---|---|
| **Falco** | Detects anomalous pod behavior at runtime | in-cluster, DaemonSet |
| **Network Policies** | Restricts pod-to-pod traffic | Kubernetes manifests |
| **Pod Security Standards** | Prevents privileged escalation | admission controller |
| **OWASP ZAP** | Dynamic app security testing | post-deploy smoke test |
| **Vault** | Secrets rotation, dynamic creds | in-cluster or external |

---

## Security checklist

- [ ] SonarCloud project created and token added to GitHub
- [ ] First image scan baseline reviewed (SBOM artifact saved)
- [ ] `.trivyignore` updated with known non-issues
- [ ] `ansible-playbook security-hardening.yml` run on cluster
- [ ] Firewall rules reviewed (port 1194 for OpenVPN if used)
- [ ] SSH key file permissions: `chmod 600 ~/.ssh/rke2-mumbai.pem`
- [ ] No hardcoded secrets in code (check with SonarQube)
- [ ] Default password changed immediately after first login
- [ ] etcd encrypted at rest (built into RKE2)
- [ ] RBAC enforced (no cluster-admin in regular kubeconfigs)

---

## Incident response

If a vulnerability is disclosed:

1. **Trivy scan identifies it** → GitHub Security tab shows findings
2. **Review criticality** → CVSS score, affected component, exploitability
3. **Patch or mitigate:**
   - Patch: update base image, rebuild, deploy new version
   - Mitigate: add `.trivyignore` entry with justification
4. **Verify fix:** re-run Trivy scan, confirm SARIF is clean
5. **Document:** link incident to commit/PR for audit trail

---

## Compliance references

- **CIS Kubernetes Benchmark** — RKE2 is hardened against this by default
- **NIST 800-190** — container security (what Trivy checks against)
- **OWASP Top 10** — app-level vulnerabilities (what SonarQube checks against)
- **PCI DSS** — if handling payment data (out of scope for this app)

Cluster-specific hardening already applied to both nodes is recorded in the
operator's cluster guide (not in this repo); `ansible/playbooks/security-hardening.yml`
verifies it and reports drift.
