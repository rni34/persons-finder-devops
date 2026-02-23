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

**Total: 42 flaws identified and fixed across 8 deliverables.**

Every AI-generated artifact required significant security hardening before it was production-ready. The pattern was consistent: AI produces functional but insecure defaults. The engineer's job is to apply defense-in-depth, least-privilege, and operational best practices.
