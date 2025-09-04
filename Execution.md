# DevOps Execution Plan — Monolithic App on Kubernetes (CI/CD + Observability)

This README is a **phased, realistic execution plan** to take the architecture below from idea → production, with clear goals, owner tasks, acceptance criteria, and checklists. Copy it into your repo as `README.md` (or `docs/DEVOPS_EXECUTION_PLAN.md`).

```
                                     +----------------+
                                     |   Developers   |
                                     +----------------+
                                             |
                                    Code Push (GitHub/GitLab)
                                             |
                                             v
                                  +-----------------------+
                                  | Continuous Integration|
                                  |    GitHub Actions     |
                                  |                       |
                                  +-----------------------+
                                             |
                                     +-------+-------+
                                     |               |
                            +--------v-----+ +-------v-------+
                            |  Unit Tests  | |  Lint/SAST     |
                            +--------------+ +---------------+
                                             |
                                             v
                                 +------------------------+
                                 |     Build Artifact     |
                                 |   (Docker Image / WAR) |
                                 +------------------------+
                                             |
                                             v
                                 +--------------------------+
                                 | Container Registry       |
                                 | (GHCR / Docker Hub /     |
                                 |  Nexus / Harbor)         |
                                 +--------------------------+
                                             |
                                             v
                                 +--------------------------+
                                 | Continuous Deployment    |
                                 |  (Helm + ArgoCD /        |
                                 |   Kustomize + FluxCD /   |
                                 |   kubectl apply)         |
                                 +--------------------------+
                                             |
                                             v
                                 +----------------------------+
                                 |    Kubernetes Cluster      |
                                 |  (Minikube / EKS / GKE)    |
                                 +----------------------------+
                                             |
                               +-------------+---------------+
                               |                             |
                    +----------v----------+       +----------v----------+
                    | Application Pod(s)  |       |      Database       |
                    | (Monolithic App)    |       | (Postgres/MySQL)    |
                    +---------------------+       +---------------------+
                               |
                               v
                    +-----------------------------+
                    | Logging & Monitoring        |
                    | (Prometheus + Grafana /     |
                    |  Loki / ELK Stack / Sentry) |
                    +-----------------------------+
```

---

## Goals & Guardrails

- **Business goal:** Ship a reliable monolithic app to Kubernetes with safe deploys (canary/blue‑green), basic SLOs, and fast rollback.
- **Guardrails:** Everything infra as code, reproducible locally (Minikube) and in cloud (EKS/GKE), with secure defaults (least privilege, secrets managed, image signing).
- **Environments:** `dev` → `staging` → `prod` with automated promotion and policy gates.

---

## Phase 0 — Foundations & Repo Layout (Week 1)

**Outcome:** Baseline repo, local cluster, and a single “hello world” deploy path.

**Deliverables**
- Repo structure:
  ```text
  .
  ├─ app/                     # application source
  ├─ ci/                      # workflows, composite actions
  ├─ deploy/Introduction.......................................................xii
  │  ├─ helm/APP/             # Helm chart for the app
  │  ├─ kustomize/            # if you choose Kustomize overlays
  │  └─ manifests/            # raw YAML (for reference/tests)
  ├─ ops/
  │  ├─ scripts/              # bootstrap, smoke tests, db migration scripts
  │  └─ runbooks/             # operational docs
  └─ docs/
  ```

**Tasks**
- Create **Minikube** dev cluster (local parity).
- Pick registry: **GHCR** (GitHub Container Registry) recommended.
- Create base **Helm chart** for app (Service, Deployment, HPA, Ingress).
- Define **branching**: `main` (protected), `develop`, `feature/*`.
- Add commit policy: Conventional Commits; required reviews on `main`.

**Acceptance Criteria**
- `make dev-up` brings up Minikube and deploys a sample image via Helm.
- `kubectl get pods -n app` shows app healthy; `/healthz` returns 200.

**Snippets**
```bash
# Start local cluster
minikube start --cpus=4 --memory=6g

# Enable ingress (nginx) locally
minikube addons enable ingress

# Create namespace & install base chart
kubectl create ns app || true
helm upgrade --install app ./deploy/helm/APP -n app \
  --set image.repository=ghcr.io/ORG/APP --set image.tag=dev
```

---

## Phase 1 — CI: Build, Test, Scan (Week 2)

**Outcome:** Every PR builds, tests, and scans before merge.

**Pipeline Stages**
1. **Checkout & Cache** (Node/Java/Maven/Gradle as applicable).
2. **Static checks**: lint, format, license header, **SAST** (CodeQL or Semgrep).
3. **Unit tests** with coverage threshold (e.g., 80%).
4. **Build image** with SBOM (Syft or buildkit), tag: `sha`, `branch-latest`.
5. **Scan image**: Trivy/Grype; fail on HIGH/CRITICAL (baseline exceptions allowed).
6. **Push to GHCR** on `main` and tags.

**Example: `.github/workflows/ci.yml` (simplified)**
```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]
jobs:
  build-test-scan:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      security-events: write
    steps:
      - uses: actions/checkout@v4

      - name: Set up JDK
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '21'

      - name: Lint & Unit Tests
        run: |
          ./gradlew check test

      - name: Build image
        run: |
          docker build -t ghcr.io/${{ github.repository }}/app:${{ github.sha }} .

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Push image
        run: |
          docker push ghcr.io/${{ github.repository }}/app:${{ github.sha }}

      - name: Image scan (Trivy)
        uses: aquasecurity/trivy-action@0.24.0
        with:
          image-ref: ghcr.io/${{ github.repository }}/app:${{ github.sha }}
          format: 'table'
          exit-code: '1'
          ignore-unfixed: true
          vuln-type: 'os,library'
```

**Acceptance Criteria**
- PRs fail when tests fail or CRITICAL vulns are found.
- Merges to `main` publish an image in GHCR with digest noted in job output.

---

## Phase 2 — CD: Helm + Argo CD (Weeks 3–4)

**Outcome:** GitOps deployment to `dev` and `staging` via Argo CD, manual promotion to `prod` with policy gates.

**Design**
- **App of Apps** pattern in Argo CD: one “platform” repo (envs, infra charts), one “app” repo (your service Helm chart + values).
- Environments with values:
  - `values-dev.yaml`: replicas=1, debug=true, lower resources.
  - `values-staging.yaml`: replicas=2, HPA min=2, canary enabled.
  - `values-prod.yaml`: replicas>=3, HPA min=3, PDB, PodSecurity, strict resources.

**Tasks**
- Install Argo CD (namespace `argocd`), expose via Ingress.
- Create Argo Apps pointing to environment directories:
  ```text
  deploy/envs/
  ├─ dev/
  │  └─ values-dev.yaml
  ├─ staging/
  │  └─ values-staging.yaml
  └─ prod/
     └─ values-prod.yaml
  ```
- Wire CI → update image tag in env repo (or use image updater controller).
- Implement **progressive delivery** (Argo Rollouts) for canary/blue‑green.

**Acceptance Criteria**
- Commit to `envs/dev` auto-syncs to cluster in <2 min.
- Canary releases in staging with metrics check before promotion.

**Snippet: Helm values toggles**
```yaml
image:
  repository: ghcr.io/ORG/APP
  tag: "sha-{{ GITHUB_SHA }}"

ingress:
  enabled: true
  hosts: [ "app-dev.local" ]

rollout:
  enabled: true
  strategy: canary
  steps:
    - setWeight: 25
    - pause: { duration: 60 }
    - setWeight: 50
    - pause: { duration: 120 }
    - setWeight: 100
```

---

## Phase 3 — Platform Add‑Ons (Weeks 5–6)

**Outcome:** Production‑readiness via security, secrets, and reliability tooling.

**Security & Supply Chain**
- **Secrets:** External Secrets Operator or SOPS‑encrypted Helm values.
- **Image signing:** Cosign; verify in admission via **Kyverno**/**OPA Gatekeeper**.
- **Policies:** Block `:latest`, require non‑root, runAsUser, readOnlyRootFS.
- **Network:** Namespaces per app, NetworkPolicies per tier, minimal egress.

**Observability**
- **Metrics:** Prometheus Operator; app exposes `/metrics` (OpenMetrics).
- **Dashboards:** Grafana with folders per env; SLOs (availability, latency).
- **Logs:** Loki (or ELK). Structured JSON logs with traceIDs.
- **Tracing:** OpenTelemetry SDK → Tempo/Jaeger.
- **Alerts:** Alertmanager rules + routing to on‑call (email/Slack).

**Reliability**
- **HPAs** on CPU & custom metrics (RPS/queue depth).
- **Readiness/liveness** probes + **startupProbe** for JVMs.
- **PodDisruptionBudget** to avoid full drain outages.
- **Backups**: Velero for cluster; DB backups (pgBackRest or mysqlpump) + restore tests.

**Acceptance Criteria**
- Policy engine rejects unsigned images and privileged pods.
- Dashboards show SLO error budget and deployment KPIs.
- Quarterly **restore drill** documented in runbooks.

---

## Phase 4 — Database Lifecycle (Week 7)

**Outcome:** Safe schema changes and data protection.

**Tasks**
- Pick migration tool (**Flyway/Liquibase**). Run on startup or CI step.
- Separate **readiness** from **migration** (job or initContainer).
- **Backup/restore** runbooks, KMS‑encrypted backups, rotation & retention.
- **Connection pooling** (pgBouncer/Hikari), health checks, max connections.

**Acceptance Criteria**
- Migrations are idempotent and replayable in dev.
- Staging backup can be restored into a scratch namespace successfully.

---

## Phase 5 — Production Hardening & Cost (Week 8)

**Outcome:** Confident prod go‑live with guardrails and budgets.

**Tasks**
- **Ingress** with TLS (LetsEncrypt/ACM), WAF if applicable.
- **Autoscaling**: cluster autoscaler (cloud), app HPA/VPA as needed.
- **Cost**: labels/annotations for showback; Kubecost or OpenCost.
- **Disaster Recovery**: RPO/RTO targets, cross‑region backup copy.
- **Game Days**: failure injection (kill pods, node drain), verify SLOs & rollback.

**Acceptance Criteria**
- Blue/green with instant rollback works in staging and prod.
- Cost dashboard per namespace; monthly budget alerting configured.

---

## Promotion Workflow

1. **PR to `main`** → CI builds & scans image → push to GHCR.
2. **Auto deploy to `dev`** (Argo CD sync) → smoke tests.
3. **Promote to `staging`** by PR bumping image tag in `envs/staging`.
4. **Canary** and SLO watch → if stable, **promote to `prod`** via PR.
5. **Tag release**; attach SBOM, image digest, change log to GitHub Release.

---

## Environments & Config Strategy

- **Config** via Helm values per env; secrets via External Secrets → vault/SM.
- **Feature flags** (Unleash/ConfigCat) for risky toggles.
- **Immutable app images**; env differences only in values, not code.

---

## Access & Security Model

- **RBAC:** separate `platform-admin`, `app-deployer`, `read-only` roles.
- **Credentials:** short‑lived tokens, no static kubeconfigs in CI.
- **Registry:** private GHCR, least‑privilege PAT or GITHUB_TOKEN.
- **Ingress Auth:** OAuth2 proxy or SSO for internal UIs.

---

## Operational Runbooks (ops/runbooks/)

- **Deploy Rollback:** `helm rollback app <REV>` or Argo CD “rollback to healthy”.
- **Incident Triage:** check service SLO panel → logs → traces → metrics.
- **DB Restore:** choose PITR timestamp → run `pgbackrest restore` → smoke test.
- **Cert Renewal:** ACME issuer status → force renew if <10 days remaining.
- **On‑call Handover:** current incidents, error budget, risky changes.

---

## Minimal Local Workflow (Developer)

```bash
# 1) Start cluster
minikube start --cpus=4 --memory=6g

# 2) Build & load local image
docker build -t app:dev .
minikube image load app:dev

# 3) Deploy with dev values
helm upgrade --install app ./deploy/helm/APP -n app \
  --set image.repository=app --set image.tag=dev

# 4) Port-forward
kubectl -n app port-forward svc/app 8080:80
curl -fsS localhost:8080/healthz
```

---

## Quality Gates & KPIs

- **Pre‑merge:** tests pass, coverage ≥ 80%, SAST no CRITICAL.
- **Pre‑prod:** canary <1% error rate over 15 min; latency p95 < 300 ms.
- **Operational:** SLO 99.9% monthly, change failure rate < 15%, MTTR < 30 min.

---

## Folder Conventions (Helm)

```
deploy/helm/APP/
├─ Chart.yaml
├─ values.yaml
├─ values-dev.yaml
├─ values-staging.yaml
├─ values-prod.yaml
└─ templates/
   ├─ deployment.yaml
   ├─ service.yaml
   ├─ ingress.yaml
   ├─ hpa.yaml
   ├─ pdb.yaml
   └─ rollout.yaml   # if using Argo Rollouts
```

---

## Troubleshooting

**Pods stuck in `ImagePullBackOff`**
- Check image name/tag/digest and registry credentials (`imagePullSecrets`).
- On Minikube, use `minikube image load` for local images.

**Readiness probe fails after deploy**
- Increase **startupProbe**; ensure DB is reachable; check migrations not blocking.

**Argo CD not syncing**
- Repo credentials/SSH key; check `Application` status and events; RBAC scope.

**TLS issues with Ingress**
- Check certificate issuer health; correct DNS to ingress controller IP; CAA records.

**DB connection spikes / timeouts**
- Pooling limits, `max_connections`, long queries; apply pgbouncer; check liveness thresholds.

**High error rate after rollout**
- Abort canary in Argo Rollouts; rollback to last stable; inspect new features behind flags.

---

## Backlog (priority‑ordered)

- [ ] Helm chart hardening: SecurityContext, PodSecurity Standards, PDB.
- [ ] External Secrets integration with cloud secret manager.
- [ ] Argo Rollouts + metric analysis (Prometheus) for canary.
- [ ] Cosign sign/verify; Kyverno policies.
- [ ] OpenTelemetry traces to Tempo; dashboards for SLOs.
- [ ] Velero backups and quarterly restore drill.
- [ ] Cost monitoring (OpenCost/Kubecost).

---

## Documentation & Links (placeholders)

- **Architecture doc:** `docs/architecture.md`
- **Runbooks:** `ops/runbooks/*.md`
- **Dashboards:** `docs/dashboards/`
- **Release notes:** GitHub Releases with SBOM + digests

---

### How to Use This Plan

1. Copy this file into your repository.
2. Tweak the language/runtime steps for your app stack (Node, Java, Python, etc.).
3. Decide on **Argo CD** vs **Flux**—the steps remain the same; use one.
4. Start at **Phase 0** and treat each phase as a sprint with the listed acceptance criteria.
5. Keep everything infra‑as‑code and automate **promotion** via PRs between envs.

---

**Maintainers:** Platform/DevOps Team
**Last updated:** 2025-08-25