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

---

# Azure 3‑Tier Scalable Architecture

This document outlines a scalable, secure, and observable **3‑tier application** on **Microsoft Azure** (Web → App → Data). It includes a text‑based architecture diagram, component choices, networking layout, security controls, scaling strategies, and CI/CD flow.

---

## High‑Level Text Diagram

```
                          +-----------------------------+
                          |        Users / Clients      |
                          +---------------+-------------+
                                          |
                                          v
                                 +--------+---------+
                                 |  Azure Front Door |
                                 |  (WAF + CDN opt)  |
                                 +--------+---------+
                                          |
                                   (Public HTTPS)
                                          |
                     +--------------------+--------------------+
                     |                                         |
                     v                                         v
            +--------+---------+                       +--------+---------+
            |  App Gateway     |  (Web tier subnet)    | Azure Firewall   |
            |  (WAF, L7 LB)    |<--------------------->| (Egress control) |
            +--------+---------+       East/West       +--------+---------+
                     |                                         |
                     | (Private IP to Web pods)                |
                     v                                         v
         +-----------+------------+                   +---------+----------+
         | Azure Kubernetes       |                   |  Private DNS Zone  |
         | Service (AKS)          |                   |  + Private Endpts  |
         |  - Web Deployment      |<----------------->|   (AKS, DB, Strg)  |
         |  - App Deployment      |        VNet Peering/Links              |
         +-----------+------------+                   +---------+----------+
                     |                                             |
                     | (Service-to-service via ClusterIP/MTLS)     |
                     v                                             v
            +--------+---------+                         +---------+----------+
            | Azure Cache for  |                         | Azure SQL Database |
            | Redis (Managed)  |                         | or Cosmos DB       |
            +--------+---------+                         +---------+----------+
                     ^                                             ^
                     | (Low-latency cache)                         |
                     |                                             |
             +-------+------+                            +---------+----------+
             | Azure Storage | (Blobs/Queues)            | Azure Key Vault    |
             |  (images, etc)|-------------------------->| Secrets/Keys/Certs |
             +-------------- +   (Private Endpoint)      +--------------------+

Observability & Ops:
  Azure Monitor + Log Analytics + Application Insights (traces, metrics, logs)
  Defender for Cloud (posture, workload protection)
  Backup Vault (DB backups, snapshots)

CI/CD Path:
  Source Repo → CI (GitHub Actions/Azure DevOps) → Build & Test →
  Container Image → Azure Container Registry (ACR) →
  CD (GitOps/Actions) → AKS (Helm/Kustomize) → Progressive delivery (canary)
```

---

## Components & Responsibilities

### Web Tier

* **Azure Front Door (AFD)**: Global anycast entry, HTTP/2/3, WAF policies, caching.
* **Azure Application Gateway (WAF v2)**: Regional Layer‑7 load balancer; terminates TLS; routes to **AKS Ingress**.
* **AKS Web Pods**: Serve static UI (or NGINX) and call App APIs over internal DNS.

### App Tier

* **AKS App Pods**: Stateless services (REST/GraphQL). Use **Horizontal Pod Autoscaler (HPA)**.
* **Service Mesh (optional)**: Linkerd/Consul or AGIC/NGINX Ingress with mTLS for service‑to‑service auth.
* **Azure Cache for Redis**: Caching sessions, hot reads, rate limiting tokens.

### Data Tier

* **Azure SQL Database** (or **Cosmos DB** for globally distributed workloads). Enable **zone redundancy**.
* **Azure Storage** (Blob/File/Queue) for static assets, uploads, async processing.
* **Private Endpoints** to keep data traffic on the private network.

---

## Networking Layout

* **Hub‑and‑Spoke VNets**

  * **Hub VNet**: Azure Firewall, Bastion, shared services, Private DNS.
  * **Spoke VNet (App)**: AKS nodepools across **3 AZs**; subnets:

    * `snet-aks-nodes` (AKS nodes)
    * `snet-aks-pods` (optional if using Azure CNI powered by CNI overlay)
    * `snet-appgw` (Application Gateway)
  * **Spoke VNet (Data)**: DB, Redis, Storage PE, Key Vault PE.
* **NSGs**: Lock down subnets to necessary ports only.
* **Private DNS Zones** linked to spokes for Private Endpoint resolution (e.g., `privatelink.database.windows.net`).
* **Egress**: Force‑tunnel through **Azure Firewall**; allowlists for external APIs; use **FQDN tags** when possible.

---

## Security Controls

* **WAF** enabled on AFD and/or App Gateway (OWASP rules, custom rules, geo‑filtering).
* **Azure AD / Managed Identity** for AKS workloads to access Key Vault and Storage (no secrets in code).
* **Key Vault** for app secrets, DB credentials, TLS certs; **CSI Secret Store** driver to mount secrets into pods.
* **Defender for Cloud**: vulnerability assessment, image scanning (integrate with ACR), regulatory compliance.
* **RBAC** everywhere: Azure RBAC + AKS RBAC; separate least‑privilege roles per team.
* **Network isolation**: Private Link for DB/Storage; deny public access on data services.
* **Image provenance**: Sign images (Cosign) and enforce admission policy (Gatekeeper/Kyverno).

---

## Scalability & Resilience

* **AKS Node Pools**: Separate pools for web, app, and jobs; enable **cluster autoscaler**.
* **HPA** on Deployments (CPU/Memory/Custom metrics via KEDA or Prometheus Adapter).
* **Availability Zones**: Spread nodepools and zonal services (where supported).
* **Caching**: Redis tiering; proper TTLs; cache‑aside strategy.
* **Queueing** (optional): Use Storage Queues or Service Bus for async workloads.
* **DR/BCP**: Geo‑replication (AFD multi‑region, SQL active geo‑replication/Cosmos multi‑region); staged failover runbooks.

---

## Observability

* **Application Insights** for request traces, dependencies, and distributed tracing.
* **Azure Monitor / Log Analytics** for metrics & centralized logs; alerts on SLOs and saturation signals.
* **Dashboards**: Per‑tier golden signals (latency, errors, traffic, saturation). Synthetics via Availability tests.

---

## CI/CD Reference Flow

1. **CI** (GitHub Actions or Azure DevOps Pipelines)

   * Lint → Unit tests → SAST/Dependency scan → Build containers.
   * Push images to **Azure Container Registry (ACR)** with immutable tags (`app:v1.2.3+sha`).
2. **CD**

   * Helm charts or Kustomize overlays per environment (`dev`, `stg`, `prod`).
   * GitOps (ArgoCD/Flux) or pipeline deploy to AKS.
   * Progressive delivery (canary or blue/green) via service mesh/Ingress.
3. **Secrets**

   * Runtime secrets from **Key Vault** via CSI driver; rotate regularly.

---

## Environment Strategy

* **Envs**: `dev` (cost‑optimized), `stg` (prod‑like), `prod` (HA + WAF strict).
* Separate subscriptions or resource groups; per‑env ACR, AKS, Key Vault. Use **Management Groups** and **Policies**.

---

## Cost Levers

* AKS node sizing & autoscaler bounds; spot nodepools for non‑critical jobs.
* Redis tier selection; choose serverless or DTU tiers for SQL where viable.
* Front Door caching to cut origin egress; lifecycle policies on Blob Storage.

---

## Minimal Reference: AKS Ingress (YAML Snippet)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt
spec:
  tls:
    - hosts: ["app.example.com"]
      secretName: tls-cert
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web-service
                port:
                  number: 80
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-service
                port:
                  number: 8080
```

---

## Threat Model (Quick Checklist)

* TLS everywhere (AFD ↔ AppGW ↔ Ingress ↔ Pods) with managed certs.
* SSRF/XXE mitigations at WAF and app code; strict egress rules.
* Secret sprawl prevention: MI + Key Vault; no plain‑text in configs.
* DB least privilege (separate app users, no `dbo` in production).
* Rate limit & bot protection at AFD/AppGW; per‑client throttling in API.

---

## Ready‑to‑Use Placeholders

* **Domains**: `app.example.com`, `api.example.com`
* **VNets**: `vnet-hub`, `vnet-spoke-app`, `vnet-spoke-data`
* **Subnets**: `snet-appgw`, `snet-aks-nodes`, `snet-aks-pods`, `snet-data`
* **Resource Groups**: `rg-app-dev`, `rg-app-stg`, `rg-app-prod`

---

## Next Steps

* Pick **AKS** vs **App Service** for runtime based on container and ops maturity.
* Decide **canary vs blue/green** for prod rollouts.
* Stand up **IaC** (Terraform/Bicep) for repeatable environments.
* Enable **Defender for Cloud** and baseline WAF policies from day one.
# Azure 3‑Tier Scalable Architecture

This document outlines a scalable, secure, and observable **3‑tier application** on **Microsoft Azure** (Web → App → Data). It includes a text‑based architecture diagram, component choices, networking layout, security controls, scaling strategies, and CI/CD flow.

---

## High‑Level Text Diagram

```
                          +-----------------------------+
                          |        Users / Clients      |
                          +---------------+-------------+
                                          |
                                          v
                                 +--------+---------+
                                 |  Azure Front Door |
                                 |  (WAF + CDN opt)  |
                                 +--------+---------+
                                          |
                                   (Public HTTPS)
                                          |
                     +--------------------+--------------------+
                     |                                         |
                     v                                         v
            +--------+---------+                       +--------+---------+
            |  App Gateway     |  (Web tier subnet)    | Azure Firewall   |
            |  (WAF, L7 LB)    |<--------------------->| (Egress control) |
            +--------+---------+       East/West       +--------+---------+
                     |
                     v
         +-----------+--------------------------------------------------+
         |                  Azure Kubernetes Service (AKS)              |
         |                                                              |
         |  +----------------+   +----------------+   +----------------+|
         |  | Frontend Pods  |   | Backend Pods   |   |   Jenkins CI   ||
         |  | (UI container) |   | (API container)|   | (in-cluster)   ||
         |  +----------------+   +----------------+   +----------------+|
         |                                                              |
         |  +----------------+   +----------------+   +----------------+|
         |  |  Postgres DB   |   |   Redis Cache  |   |  ArgoCD Mgmt   ||
         |  | (statefulset)  |   | (statefulset)  |   | (GitOps sync)  ||
         |  +----------------+   +----------------+   +----------------+|
         |                                                              |
         |  +----------------+   +----------------+                     |
         |  | Prometheus     |   | Grafana        |                     |
         |  | (metrics)      |   | (dashboards)   |                     |
         |  +----------------+   +----------------+                     |
         +--------------------------------------------------------------+

Observability & Ops:
  Prometheus scrapes metrics from Pods → Grafana dashboards
  ArgoCD ensures Git‑based desired state for manifests
  Jenkins builds & pushes container images, triggers ArgoCD sync

CI/CD Path:
  Source Repo → Jenkins (CI) → Build & Test →
  Container Image → Azure Container Registry (ACR) →
  ArgoCD (CD) → AKS (Helm/Kustomize) → Progressive delivery (canary)
```

---

## Components & Responsibilities

### Web Tier

* **Azure Front Door (AFD)**: Global anycast entry, HTTP/2/3, WAF policies, caching.
* **Azure Application Gateway (WAF v2)**: Regional Layer‑7 load balancer; terminates TLS; routes to **AKS Ingress**.
* **AKS Frontend Pods**: Serve static UI and call backend APIs over internal DNS.

### App Tier

* **AKS Backend Pods**: Stateless services (REST/GraphQL). Use **Horizontal Pod Autoscaler (HPA)**.
* **Redis inside AKS**: StatefulSet + PVC; used for caching sessions, hot reads, rate limiting tokens.
* **Jenkins inside AKS**: Handles build/test pipelines, integrates with ACR.
* **ArgoCD**: GitOps engine to reconcile desired state into AKS.

### Data Tier

* **Postgres inside AKS**: StatefulSet with PersistentVolumeClaims, HA with replicas.
* **Backups**: Offloaded to Azure Managed Disks + Azure Backup or external storage.

---

## Observability

* **Prometheus** (in‑cluster) scrapes app and infra metrics.
* **Grafana** visualizes metrics and dashboards per tier.
* Alerts integrated with Azure Monitor or directly via Prometheus Alertmanager.

---

Other sections (Networking, Security, Scalability, Environment Strategy, etc.) remain the same but now reference **in‑cluster Postgres, Redis, Jenkins, ArgoCD, Prometheus, and Grafana** instead of fully managed Azure equivalents.
