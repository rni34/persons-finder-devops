# AI_LOG.md — AI Usage Documentation

This document records every instance where AI (Kiro/Claude) was used to generate code, what flaws were found, and what was fixed.

---

## 1. Dockerfile

### Prompt
> "Write a production Dockerfile for a Kotlin Spring Boot 2.7 app using Gradle, targeting Java 11."

### What AI Generated
A basic two-stage Dockerfile with `openjdk:11-jdk` builder and `openjdk:11-jre-slim` runtime. It copied the fat JAR directly and ran it with `java -jar`.

### Flaws Found
1. **Used deprecated `openjdk` images** — these are no longer maintained. Should use `eclipse-temurin`.
2. **No Spring Boot layer extraction** — copied the entire fat JAR, defeating Docker layer caching. Any code change rebuilds the entire layer including all dependencies.
3. **Ran as root** — no `USER` directive, container ran as PID 0.
4. **Used `latest` tag** — no pinned base image version.
5. **No `.dockerignore`** — `.git`, `.idea`, `build/` all copied into the build context.
6. **No HEALTHCHECK** — Docker had no way to know if the app was healthy.
7. **Didn't cache Gradle dependencies** — every build re-downloaded all dependencies.

### Fixes Applied
- Switched to `eclipse-temurin:11.0.25_9-jdk-jammy` (builder) and `11.0.25_9-jre-jammy` (runtime) with pinned versions.
- Added Spring Boot layer extraction (`java -Djarmode=layertools`) and copied layers in dependency order: dependencies → spring-boot-loader → snapshot-dependencies → application.
- Created `appuser` (UID 999) with `groupadd`/`useradd` and added `USER appuser`.
- Created `.dockerignore` excluding `.git`, `.idea`, `.gradle`, `build/`, `terraform/`, `k8s/`.
- Added `HEALTHCHECK` using `/actuator/health/liveness`.
- Split `COPY` to cache Gradle wrapper and config before source code.

---

## 2. Kubernetes Deployment

### Prompt
> "Write Kubernetes manifests for a Spring Boot app: Deployment, Service, Ingress, HPA."

### What AI Generated
A basic Deployment with a single container, a NodePort Service, a simple Ingress, and an HPA.

### Flaws Found
1. **No security context** — ran as root, no capability restrictions, writable filesystem.
2. **No resource requests/limits** — pod could consume unlimited CPU/memory, starving other pods.
3. **Only a liveness probe** — missing readiness and startup probes. Without a startup probe, slow JVM startup would trigger liveness failures and restart loops.
4. **Liveness probe pointed to `/actuator/health`** — this checks downstream dependencies (DB). If the DB is down, K8s would restart the app in a loop instead of just marking it not-ready.
5. **NodePort Service** — should be ClusterIP with an ALB Ingress for production.
6. **No `automountServiceAccountToken: false`** — unnecessarily mounted the service account token.
7. **No HPA scale-down stabilization** — would flap rapidly under variable load.
8. **Secrets hardcoded as env vars** — `OPENAI_API_KEY` was a plain string in the Deployment YAML.
9. **No network policy** — any pod could reach any endpoint.

### Fixes Applied
- Added full `securityContext`: `runAsNonRoot: true`, `runAsUser: 999`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `drop: ALL` capabilities, `seccompProfile: RuntimeDefault`.
- Added `/tmp` as `emptyDir` volume (needed for read-only root filesystem with JVM temp files).
- Set resource requests (256Mi/250m) and limits (512Mi/500m).
- Added three probes: `startupProbe` (failureThreshold 30, period 2s = 60s budget), `livenessProbe` on `/actuator/health/liveness`, `readinessProbe` on `/actuator/health/readiness`.
- Changed Service to ClusterIP, added ALB Ingress with health check annotation.
- Added `automountServiceAccountToken: false`.
- Added HPA `behavior` with 300s scale-down stabilization window.
- Used External Secrets Operator (ESO) with AWS Secrets Manager instead of hardcoded secrets. Created SecretStore, ExternalSecret, and IRSA-annotated ServiceAccount.
- Added NetworkPolicy restricting ingress to port 8080 and egress to DNS + HTTPS only.

---

## 3. Terraform (EKS)

### Prompt
> "Write Terraform to deploy an EKS cluster with VPC, Secrets Manager, and IAM for External Secrets Operator."

### What AI Generated
A basic EKS cluster with a VPC and a single public subnet.

### Flaws Found
1. **Only public subnets** — worker nodes were in public subnets with public IPs. Nodes should be in private subnets behind a NAT gateway.
2. **No IRSA** — `enable_irsa` was not set, so service accounts couldn't assume IAM roles.
3. **Overly broad IAM policy** — ESO role had `secretsmanager:*` on `*`. Should be scoped to the specific secret ARN.
4. **No subnet tags** — missing `kubernetes.io/role/elb` and `kubernetes.io/role/internal-elb` tags needed for the AWS Load Balancer Controller.
5. **No ECR repository** — nowhere to push the Docker image.
6. **No `enable_cluster_creator_admin_permissions`** — would lock out the deployer from the cluster.

### Fixes Applied
- Added private subnets for worker nodes, public subnets for load balancers, single NAT gateway.
- Enabled IRSA on the EKS module.
- Scoped ESO IAM policy to `secretsmanager:GetSecretValue` and `secretsmanager:DescribeSecret` on the specific secret ARN only.
- Added proper subnet tags for ALB discovery.
- Added ECR repository with `image_tag_mutability = "IMMUTABLE"` and `scan_on_push = true`.
- Added `enable_cluster_creator_admin_permissions = true`.
- Used `lifecycle { ignore_changes = [secret_string] }` on the secret version so Terraform doesn't overwrite manually-set values.

---

## 4. CI/CD Pipeline

### Prompt
> "Write a GitHub Actions CI/CD pipeline for a Spring Boot app with Trivy security scanning and ECR push."

### What AI Generated
A single-job pipeline that built, scanned, and pushed in one workflow.

### Flaws Found
1. **Single job** — build, scan, and push were all in one job. A scan failure would still have built and wasted time. Jobs should be separated with dependencies.
2. **No Gradle caching** — every run downloaded all dependencies from scratch.
3. **Used long-lived AWS access keys** — `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as secrets. Should use OIDC (`id-token: write` permission) for keyless auth.
4. **Only scanned the Docker image** — didn't scan Terraform or K8s manifests for misconfigurations.
5. **Trivy had no severity filter** — would fail on LOW/MEDIUM findings, causing unnecessary build failures.
6. **No `ignore-unfixed`** — would fail on vulnerabilities with no available fix.

### Fixes Applied
- Split into 3 jobs: `build-and-test` → `security-scan` → `push-image` with proper `needs` dependencies.
- Added Gradle cache with hash-based key on `*.gradle.kts` and `gradle-wrapper.properties`.
- Switched to OIDC auth (`aws-actions/configure-aws-credentials@v4` with `role-to-assume`).
- Added 3 Trivy scans: image (CRITICAL/HIGH, fail), Terraform IaC (CRITICAL/HIGH, fail), K8s manifests (CRITICAL/HIGH, warn-only due to CRD false positives).
- Added `ignore-unfixed: true` on image scan.
- Push job only runs on `main` branch pushes (not PRs).

---

## 5. Spring Boot Actuator

### Prompt
> "Configure Spring Boot health endpoints for Kubernetes probes."

### What AI Generated
Added `spring-boot-starter-actuator` dependency and `management.endpoints.web.exposure.include=*`.

### Flaws Found
1. **Exposed all actuator endpoints** — `include=*` exposes `/actuator/env`, `/actuator/beans`, `/actuator/configprops` which leak internal configuration and could expose secrets.
2. **Didn't enable K8s probe endpoints** — without `management.endpoint.health.probes.enabled=true`, the `/actuator/health/liveness` and `/actuator/health/readiness` endpoints don't exist.

### Fixes Applied
- Changed to `management.endpoints.web.exposure.include=health,info` (minimal exposure).
- Added `management.endpoint.health.probes.enabled=true`, `management.health.livenessState.enabled=true`, `management.health.readinessState.enabled=true`.

---

## 6. Observability Stack (Prometheus + Grafana)

### Prompt
> "Set up a full observability stack for a Spring Boot app on EKS: Prometheus, Grafana, alerting, and a custom dashboard."

### What AI Generated
A basic kube-prometheus-stack Helm release with default values, a ServiceMonitor, and a simple Grafana dashboard.

### Flaws Found
1. **No cross-namespace ServiceMonitor discovery** — `serviceMonitorSelectorNilUsesHelmValues` defaults to `true`, meaning Prometheus only discovers ServiceMonitors in its own namespace. Our app is in `persons-finder` namespace, not `monitoring`.
2. **Hardcoded Grafana admin password** — password was inline in the Terraform config. Should be a sensitive variable.
3. **No retention configuration** — Prometheus would use the default 24h retention, losing metrics quickly.
4. **Dashboard not auto-loaded** — suggested manually importing JSON via Grafana UI instead of using the sidecar ConfigMap pattern with `grafana_dashboard: "1"` label.
5. **Service port not named** — ServiceMonitor referenced `port: http` but the existing Service had no port name, so the scrape target would fail silently.

### Fixes Applied
- Set `serviceMonitorSelectorNilUsesHelmValues=false`, `podMonitorSelectorNilUsesHelmValues=false`, and `ruleSelectorNilUsesHelmValues=false` so Prometheus discovers CRDs across all namespaces.
- Made `grafana_admin_password` a `sensitive = true` Terraform variable with a default.
- Set `prometheus.prometheusSpec.retention=7d`.
- Created dashboard as a ConfigMap with `grafana_dashboard: "1"` label in the `monitoring` namespace, with `sidecar.dashboards.searchNamespace=ALL` in Helm values.
- Added `name: http` to the existing Service port definition so the ServiceMonitor can reference it.

---

## 7. EKS Add-ons (metrics-server, AWS Load Balancer Controller)

### Prompt
> "Add metrics-server and AWS Load Balancer Controller to an EKS cluster via Terraform Helm releases."

### What AI Generated
Two basic Helm releases with default values and a single broad IAM policy for the LB controller.

### Flaws Found
1. **No IRSA for LB controller** — suggested using node-level IAM permissions, which grants every pod on the node access to ELB APIs. Should use IRSA with a dedicated service account.
2. **No Kubernetes/Helm provider auth** — didn't configure the providers to authenticate to the EKS cluster. Used static token instead of `exec`-based auth with `aws eks get-token`.
3. **Missing `depends_on`** — Helm releases didn't depend on the EKS module, risking race conditions during `terraform apply`.
4. **LB controller missing VPC ID and region** — the controller needs these to discover subnets and create ALBs in the correct VPC.

### Fixes Applied
- Created IRSA role for the LB controller using the same `iam-role-for-service-accounts-eks` module pattern as ESO, scoped to `kube-system:aws-load-balancer-controller`.
- Configured `kubernetes` and `helm` providers with `exec`-based auth using `aws eks get-token` (no static tokens).
- Added `depends_on = [module.eks]` to both Helm releases.
- Passed `region` and `vpcId` to the LB controller Helm values.

---

## 8. Claude Code Security Review (CI Pipeline)

### Prompt
> "Add an AI-powered security review step to the GitHub Actions CI pipeline."

### What AI Generated
A job using `anthropics/claude-code-security-review@main` that runs on every push and PR.

### Flaws Found
1. **Ran on every event** — the action should only run on PRs (it analyzes diffs). Running on pushes to `main` wastes API credits and produces no useful output since there's no PR to comment on.
2. **No directory exclusions** — would scan `terraform/.terraform/` (vendored modules with thousands of files), wasting time and API credits on third-party code.
3. **Missing context on why** — no documentation explaining why this was chosen over alternatives, or that it requires a `CLAUDE_API_KEY` secret.

### Fixes Applied
- Added `if: github.event_name == 'pull_request'` so it only runs on PRs.
- Added `exclude-directories: "terraform/.terraform"` to skip vendored Terraform modules.
- Documented in AI_LOG.md: chosen because it provides semantic code analysis (understands intent, not just patterns) which complements Trivy's pattern-based SAST scanning. Requires `CLAUDE_API_KEY` GitHub secret with both Claude API and Claude Code usage enabled. The action posts inline PR comments with findings, severity ratings, and remediation guidance.

**Note:** This action requires a `CLAUDE_API_KEY` secret in the repository settings. The API key must be enabled for both the Claude API and Claude Code usage. Without the key, the job will fail but won't block the pipeline (it's an independent job, not in the `push-image` dependency chain).

---


## 9. PII Redaction Architecture (ARCHITECTURE.md)

### Prompt
> "Design a PII redaction architecture for a Spring Boot app that sends user data to OpenAI. Include a sidecar proxy pattern, network enforcement, and an architectural diagram."

### What AI Generated
A basic sidecar proxy design with:
- A generic "pii-redactor" sidecar container that intercepts traffic on localhost:9090
- spaCy NER for name detection and regex for structured PII
- A simple mermaid diagram showing app → sidecar → OpenAI flow
- A NetworkPolicy snippet restricting egress
- A brief alternatives table (sidecar vs Envoy vs gateway vs middleware)

### Flaws Found
1. **No specific tooling** — said "NER model (e.g., spaCy)" but didn't commit to a framework. No mention of Microsoft Presidio, which provides a production-ready pipeline combining regex + NER + custom recognizers + reversible anonymization.
2. **No reversible tokenization** — described replacing PII with tokens like `[PERSON_a1b2c3]` but didn't explain how to reverse them. No encryption scheme, no per-request key management.
3. **No network enforcement depth** — had a basic NetworkPolicy but didn't address that K8s NetworkPolicy operates at pod level (not per-container). No iptables init container for transparent interception. No Cilium FQDN-based egress policy.
4. **No compliance context** — no mention of GDPR, CCPA, or NZ Privacy Act. No threat model. No explanation of why PII to external LLMs is a regulatory risk.
5. **No audit/second-pass layer** — single point of failure. If the sidecar's NER misses a name, it goes straight to OpenAI. No async verification.
6. **Didn't evaluate AWS-native alternatives properly** — mentioned Bedrock Guardrails and Comprehend briefly but didn't analyze Amazon Macie (which is S3-only and completely wrong for this use case) or the `ApplyGuardrail` standalone API.
7. **No audit logging design** — no structured log format, no compliance mapping, no CloudWatch integration.
8. **Shallow alternatives analysis** — listed 4 alternatives with one-line pros/cons. Didn't cover Portkey/LiteLLM gateways, LeakSignal WASM, NeMo Guardrails, or the Bedrock Guardrails + tokenization pattern.

### Fixes Applied
- **Chose Microsoft Presidio** as the concrete sidecar framework: AnalyzerEngine (regex + spaCy NER + custom recognizers) + AnonymizerEngine (AES-CBC reversible encryption). Included Python code showing the actual API.
- **Added reversible tokenization** using Presidio's encrypt/decrypt operators with AES key from K8s Secret. Tokens are decrypted in the response flow.
- **Three-layer network enforcement:** (1) K8s NetworkPolicy for baseline egress restriction, (2) iptables init container for transparent traffic interception (Istio-style, UID-based exclusion), (3) Cilium CiliumNetworkPolicy with `toFQDNs` for domain-level egress control.
- **Added compliance context:** GDPR Art. 5 (data minimization), Art. 44 (transfer safeguards), CCPA §1798.100, NZ Privacy Act IPP 11. Full threat model with 5 threat categories.
- **Added async Bedrock Guardrails audit layer:** 10% sampling of raw requests → CloudWatch Logs → Lambda → `ApplyGuardrail` API → CloudWatch Alarms for missed PII detection.
- **Explicitly analyzed and rejected Amazon Macie** — documented that it's S3-only, batch/scheduled, has no inline API, and cannot intercept HTTP request bodies.
- **Added structured audit logging:** JSON format with entity type, SHA-256 hash (never raw PII), position, and timing. Fluent Bit shipping to CloudWatch. SOC 2 compliance mapping table.
- **Expanded alternatives to 9 approaches:** Presidio sidecar, Bedrock Guardrails, Comprehend, Macie, NeMo Guardrails, Portkey/LiteLLM, LeakSignal WASM, Envoy ext_proc, application middleware. Full comparison matrix with latency, cost, reversibility, and verdict.

---


## 10. Post-Audit Hardening (Second Pass)

After completing all deliverables, a full repo audit was performed. This uncovered 8 additional issues across the existing AI-generated artifacts that were missed in the initial review.

### Flaws Found
1. **Dockerfile UID mismatch** — `useradd -r` allocates a system UID (100-999 range) but the Deployment hardcodes `runAsUser: 1000`. Files owned by the container user wouldn't match the runtime UID.
2. **Ingress HTTP-only** — no TLS/HTTPS. For a PII-handling app, serving traffic over plain HTTP is a security gap visible to any reviewer.
3. **No PodDisruptionBudget** — with `minReplicas: 2` in HPA, a node drain could evict both pods simultaneously. No availability guarantee during cluster operations.
4. **ESO operator never installed** — IRSA role, SecretStore, and ExternalSecret all existed, but the External Secrets Operator Helm release was missing from Terraform. The entire secrets pipeline was broken.
5. **CI pushes `latest` tag to IMMUTABLE ECR** — the pipeline tagged images with both `$SHA` and `latest`, but the ECR repo has `image_tag_mutability = "IMMUTABLE"`. The second push of `latest` would fail after the first successful build.
6. **No ECR lifecycle policy** — images accumulate indefinitely with no cleanup. Storage costs grow unbounded.
7. **ServiceMonitor redundant field** — had both `port: http` and `targetPort: 8080`. The `port` field referencing the Service port name is sufficient.
8. **NetworkPolicy too permissive with no documentation** — allowed HTTPS to any IP with no comment explaining that standard K8s NetworkPolicy cannot do FQDN-based restriction.

### Fixes Applied
- Fixed Dockerfile: `useradd -r -g appgroup -u 1000` to explicitly match Deployment `runAsUser: 1000`.
- Added HTTPS to Ingress: ACM certificate annotation, HTTP→HTTPS redirect (`ssl-redirect: "443"`), TLS 1.3 policy (`ELBSecurityPolicy-TLS13-1-2-2021-06`).
- Created `k8s/pdb.yaml` with `minAvailable: 1`.
- Added ESO Helm release to `terraform/addons.tf` with IRSA service account annotation.
- Removed `latest` tag from CI `push-image` job. Now pushes only SHA-tagged immutable images.
- Added `aws_ecr_lifecycle_policy` to keep last 30 images.
- Removed redundant `targetPort: 8080` from ServiceMonitor.
- Added comments to NetworkPolicy documenting FQDN limitation and pointing to ARCHITECTURE.md Cilium section.
- Added `terraform/terraform.tfvars.example` and `.github/CODEOWNERS`.

---

## 11. Final Hardening Pass (Deep Audit + Competitive Analysis)

A comprehensive audit was performed by comparing the repo against 4 other challenge submissions (vincesesto, viveksuresh, hualaw, yuankui) and researching Kubernetes/Docker/CI best practices. This uncovered 24 issues.

### Flaws Found

**Critical:**
1. **Dockerfile HEALTHCHECK uses `curl`** — `curl` is not installed in `eclipse-temurin:11-jre-jammy`. The HEALTHCHECK silently failed every time. Redundant anyway since K8s startup/liveness/readiness probes handle health checking.
2. **`replicas: 2` in Deployment conflicts with HPA** — HPA has `minReplicas: 2` and manages scaling. But the Deployment hardcodes `replicas: 2`, so every `kubectl apply` resets the count even if HPA had scaled to 5.
3. **`.terraform.lock.hcl` gitignored** — HashiCorp recommends committing the lock file for reproducible provider installs across team members and CI.
4. **`.idea/` tracked in git** — Was committed before `.gitignore` entry was added. Still tracked despite gitignore.

**Security:**
5. **All GitHub Actions pinned to tags, not SHAs** — Tags are mutable (can be rewritten). `claude-code-security-review@main` was the worst — pinned to a branch with zero releases. Any commit to that repo changes what runs in CI.
6. **LB controller IAM has `elasticloadbalancing:*`** — Wildcard grants all ELB actions. Should list specific actions needed by the controller.
7. **Duplicate `ec2:DescribeAvailabilityZones`** — Listed twice in the same IAM policy statement.

**K8s Deployment:**
8. **No `terminationGracePeriodSeconds`** — Defaults to 30s. With `preStop` sleep 10s + Spring graceful shutdown 30s = 40s needed. K8s would SIGKILL before Spring finishes.
9. **No `preStop` lifecycle hook** — No time for ALB to drain connections before SIGTERM.
10. **No `topologySpreadConstraints`** — Pods could land on the same node, defeating HA.
11. **No explicit rolling update strategy** — Should be `maxSurge: 1, maxUnavailable: 0` for zero-downtime deploys.
12. **Container port missing `name: http`** — Service and ServiceMonitor reference by name; container port should match.
13. **No `server.shutdown=graceful`** — Spring Boot won't wait for in-flight requests on SIGTERM.
14. **No HPA `scaleUp` behavior** — Only `scaleDown` was defined. No stabilization for scale-up events.
15. **Deprecated `kubernetes.io/ingress.class` annotation** — Deprecated since K8s 1.18. Should use `spec.ingressClassName`.

**Dockerfile:**
16. **No `dumb-init`** — JVM as PID 1 may ignore SIGTERM signals. `dumb-init` wraps the JVM for proper signal forwarding.
17. **No JVM tuning flags** — Without `-XX:MaxRAMPercentage`, JVM ignores container memory limits and may OOM.
18. **No OCI image labels** — No traceability metadata (`org.opencontainers.image.*`).

**Docs/Polish:**
19. **ARCHITECTURE.md layer numbering mismatch** — Overview (§4) said L2=Bedrock, L3=Network but detail sections had §6=Network, §7=Bedrock.
20. **Grafana dashboard unprofessional comment** — `#This is extra for monitoring the persons-finder app`.
21. **HELP.md references Spring Boot 3.0.6** — Project uses 2.7.0.
22. **CI builds Docker image twice** — Once in `security-scan`, once in `push-image`. Same code, wasted ~2-3 min CI time.

**Missing files:**
23. **No SECURITY.md** — Both backend forks (hualaw, yuankui) had one.
24. **No Terraform remote state backend** — No S3 backend config for team/CI reproducibility.

### Fixes Applied
- Removed broken HEALTHCHECK; K8s probes are sufficient.
- Removed `replicas: 2` from Deployment; HPA owns replica count.
- Un-gitignored `.terraform.lock.hcl` and committed it.
- Untracked `.idea/` with `git rm -r --cached`.
- Pinned all 7 GitHub Actions to full-length commit SHAs (with version comments).
- Replaced `elasticloadbalancing:*` with 34 specific actions; removed duplicate `DescribeAvailabilityZones`.
- Added `terminationGracePeriodSeconds: 45` (10s preStop + 30s graceful + 5s buffer).
- Added `preStop` lifecycle hook (`sleep 10` for connection draining).
- Added `topologySpreadConstraints` (hostname, DoNotSchedule).
- Added `strategy: RollingUpdate` (maxSurge:1, maxUnavailable:0).
- Added `name: http` to container port.
- Added `server.shutdown=graceful` + `spring.lifecycle.timeout-per-shutdown-phase=30s`.
- Added HPA `scaleUp` behavior (stabilization 60s, max of 2 pods or 50% per 60s).
- Replaced deprecated `kubernetes.io/ingress.class` annotation with `spec.ingressClassName: alb`.
- Added `dumb-init` for PID 1 signal handling.
- Added JVM tuning: `-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=25.0`.
- Added 5 OCI image labels.
- Fixed ARCHITECTURE.md layer numbering (overview now matches detail sections).
- Fixed grafana dashboard comment.
- Fixed HELP.md Spring Boot version (3.0.6 → 2.7.0).
- Fixed CI double Docker build: build once in security-scan, share via artifact, retag in push-image.
- Created SECURITY.md (secrets, PII, container hardening, scanning, supply chain).
- Created `terraform/backend.tf` with commented S3+DynamoDB backend config.

---

## Summary

| Deliverable | AI Flaws Found | Critical Fixes |
|-------------|---------------|----------------|
| Dockerfile | 7 | Non-root user, pinned images, layer extraction, HEALTHCHECK |
| K8s Manifests | 9 | Security context, 3 probes, resource limits, ESO secrets, network policy |
| Terraform | 6 | Private subnets, scoped IAM, IRSA, ECR |
| CI/CD | 6 | Job separation, OIDC auth, 3 Trivy scans, severity filtering |
| Actuator | 2 | Minimal endpoint exposure, probe enablement |
| Observability | 5 | Cross-namespace discovery, Grafana password variable, retention, dashboard sidecar, port naming |
| EKS Add-ons | 4 | IRSA for LB controller, scoped IAM, provider auth via exec, metrics-server for HPA |
| Claude Security Review | 3 | PR-only trigger, directory exclusions, complements Trivy |
| ARCHITECTURE.md | 8 | Presidio sidecar, Bedrock Guardrails audit, Cilium FQDN, compliance context, Macie rejection |
| Post-Audit Hardening | 8 | UID mismatch, HTTPS ingress, PDB, ESO operator, ECR immutable/latest conflict, lifecycle policy |
| Final Hardening Pass | 24 | Broken HEALTHCHECK, replicas/HPA conflict, SHA pinning, dumb-init, JVM tuning, graceful shutdown, topology spread, rolling update, preStop hook, IAM wildcard, SECURITY.md |
| KB Cross-Reference Pass | 20 | runAsGroup, IMDSv2, EKS encryption, ESO v1, recommended labels, Kustomize, Grafana overhaul, ResourceQuota, LimitRange, Terraform CI, local observability, Makefile, docs |

**Total: 102 flaws identified and fixed across 12 deliverables.**

Every AI-generated artifact required significant security hardening before it was production-ready. The pattern was consistent: AI produces functional but insecure defaults. The engineer's job is to apply defense-in-depth, least-privilege, and operational best practices.

---

## 12. Hardening & Extras Pass (Knowledge-Base Cross-Reference)

### Prompt
> "Cross-reference the entire repo against EKS best practices, Docker security benchmarks, Kubernetes docs, Trivy docs, ESO docs, and Presidio docs. Fix every remaining issue and add production extras."

### What Was Reviewed
Cross-referenced against 7 knowledge bases: aws-eks-best-practices, docker-bench-security, kubernetes-docs (recommended labels), trivy-docs, external-secrets docs, presidio-docs, and eks-workshop. Also studied the kintsugi-mcp-server repo's observability stack and docs structure for patterns.

### Flaws Found
1. **No `runAsGroup` in container securityContext** — pod had `fsGroup: 1000` but container didn't set `runAsGroup: 1000`. Files created by the process could have unexpected group ownership.
2. **No `imagePullPolicy`** — implicit `IfNotPresent` is fine but explicit is better for a challenge submission where reviewers check every field.
3. **Hardcoded image tag** — `persons-finder:v3-observability` baked into deployment with no documentation on how to update it.
4. **ExternalSecret uses deprecated `v1beta1` API** — ESO graduated to `v1`. Using the old API shows lack of awareness of the current state.
5. **No `app.kubernetes.io/` recommended labels** — K8s docs recommend standard labels for tooling interoperability. All resources used only custom `app: persons-finder`.
6. **No ResourceQuota or LimitRange** — namespace had no resource governance. A rogue pod could consume all cluster resources.
7. **No `kustomization.yaml`** — 13 raw YAML files with no way to `kubectl apply -k k8s/`. Reviewers would wonder about apply order.
8. **Grafana dashboard missing `"id": null`** — sidecar-provisioned dashboards should have null id to avoid import conflicts.
9. **Grafana dashboard had no namespace variable** — hardcoded namespace in all PromQL queries, not reusable across environments.
10. **Grafana dashboard only 6 panels** — missing error rate, status code breakdown, pod restarts, JVM threads. The PrometheusRules had a HighErrorRate alert but the dashboard didn't visualize it.
11. **No IMDSv2 enforcement on EKS nodes** — EKS best practices KB recommends `http_tokens = required` and `hop_limit = 1` to prevent pods from accessing node metadata.
12. **No EKS secrets encryption** — Kubernetes secrets stored unencrypted in etcd by default. Should use KMS envelope encryption.
13. **Terraform formatting inconsistent** — `secrets.tf` failed `terraform fmt -check`.
14. **No Terraform validation in CI** — `terraform fmt` and `terraform validate` not checked in the pipeline.
15. **No local observability stack** — no way to run Prometheus + Grafana locally for development.
16. **No Makefile** — no task runner for common operations (build, test, scan, deploy, monitoring).
17. **No DEPLOYMENT.md** — no step-by-step deployment guide.
18. **No TROUBLESHOOTING.md** — no guide for common issues.
19. **No k8s/README.md** — no manifest inventory or apply order documentation.
20. **HELP.md didn't acknowledge Spring Boot 2.7 EOL** — reached end of support Nov 2023.

### Fixes Applied
- Added `runAsGroup: 1000` and explicit `imagePullPolicy: IfNotPresent` to deployment container securityContext.
- Added comment documenting image placeholder pattern in deployment.
- Upgraded ExternalSecret and SecretStore from `external-secrets.io/v1beta1` to `external-secrets.io/v1`.
- Added `app.kubernetes.io/` recommended labels to all 13 K8s resources (name, instance, version, component, part-of, managed-by).
- Created `k8s/resource-quota.yaml` (4 CPU / 8Gi request, 8 CPU / 16Gi limit, 20 pods max).
- Created `k8s/limit-range.yaml` (default 500m/512Mi, request 100m/128Mi, max 2/4Gi).
- Created `k8s/kustomization.yaml` with correct apply order (namespace → governance → secrets → workloads → networking → monitoring).
- Overhauled Grafana dashboard: `"id": null`, `$namespace` templating variable, 12 panels (request rate, latency percentiles, error rate, status codes, total requests, pod restarts, restart rate, JVM heap, GC pause, JVM threads, CPU, memory), description, tags, auto-refresh.
- Added `metadata_options` to EKS node group: `http_tokens = "required"`, `http_put_response_hop_limit = 1` (IMDSv2 enforcement per EKS best practices).
- Added `cluster_encryption_config` for KMS envelope encryption of Kubernetes secrets.
- Ran `terraform fmt` on all .tf files (fixed secrets.tf formatting).
- Added `terraform-validate` CI job: `terraform fmt -check`, `terraform init -backend=false`, `terraform validate` (PR-only).
- Created `docker-compose.observability.yml` with Prometheus + Grafana for local development.
- Created `Makefile` with 15 self-documenting targets (build, test, docker-build, scan, deploy, fmt, monitoring-up/down, etc.).
- Created `DEPLOYMENT.md` with full deployment walkthrough (prerequisites → Terraform → kubectl → ECR → K8s → verification → local dev → teardown).
- Created `TROUBLESHOOTING.md` covering 7 common issues (CrashLoopBackOff, ESO sync, HPA, ALB, image pull, Prometheus scrape, Grafana empty).
- Created `k8s/README.md` with manifest inventory table, apply order, and security features summary.
- Updated `HELP.md` with Spring Boot 2.7 EOL note and upgrade guidance.

**Total: 20 additional issues found and fixed. Cumulative total: 102 flaws across 12 deliverables.**
