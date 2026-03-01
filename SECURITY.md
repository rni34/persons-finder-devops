# Security Policy — Persons Finder

## Reporting Vulnerabilities

If you discover a security vulnerability, please report it responsibly by emailing the maintainer directly. Do not open a public GitHub issue for security vulnerabilities.

## Secrets Management

- **OPENAI_API_KEY** is stored in AWS Secrets Manager and synced to Kubernetes via External Secrets Operator (ESO) with IRSA. It is never baked into the Docker image, committed to git, or passed as a build argument.
- Kubernetes Secrets are referenced via `secretKeyRef` in the Deployment — the value never appears in manifests.
- CI/CD uses OIDC federation (`id-token: write`) for AWS authentication — no long-lived access keys.
- See `k8s/external-secret.yaml` and `terraform/secrets.tf` for implementation.

## PII Protection

User PII (names, locations) is sent to an external LLM provider. The architecture uses a defense-in-depth approach to prevent real PII from leaving the cluster:

1. **Presidio sidecar** — in-cluster PII detection and reversible tokenization (Layer 1)
2. **Network enforcement** — NetworkPolicy + Cilium FQDN egress restriction (Layer 2)
3. **Bedrock Guardrails audit** — async second-pass PII detection with CloudWatch alerting (Layer 3)

See `ARCHITECTURE.md` for the full design, threat model, and compliance mapping.

## Container Hardening

| Control | Implementation |
|---|---|
| Non-root user | `runAsUser: 1000`, `runAsGroup: 1000`, `runAsNonRoot: true` |
| Read-only filesystem | `readOnlyRootFilesystem: true` + `/tmp` emptyDir |
| No privilege escalation | `allowPrivilegeEscalation: false` |
| Minimal capabilities | `drop: ["ALL"]` |
| Seccomp profile | `seccompProfile: RuntimeDefault` |
| SA token disabled | `automountServiceAccountToken: false` |
| Signal handling | `dumb-init` as PID 1 for proper SIGTERM forwarding |
| Management port separation | Actuator endpoints on port 8081 (internal-only); app on 8080 (ALB). Prevents `/actuator/prometheus` metrics exposure to internet. |

## Vulnerability Scanning

- **Docker image**: Trivy scans for CRITICAL/HIGH CVEs on every CI run (build fails on findings)
- **Terraform IaC**: Trivy config scan for misconfigurations (build fails on findings)
- **K8s manifests**: Trivy config scan for misconfigurations (build fails on CRITICAL/HIGH findings)
- **ECR**: `scan_on_push = true` for continuous image scanning + EventBridge → SNS notification on CRITICAL findings
- **AI code review**: Claude Code security review on pull requests (semantic analysis)

## Supply Chain Security

- All GitHub Actions are pinned to full-length commit SHAs (not mutable tags)
- ECR images use immutable tags (`image_tag_mutability = "IMMUTABLE"`)
- Docker base images are pinned to specific versions (`eclipse-temurin:11.0.25_9-jre-jammy`)
- `.github/CODEOWNERS` requires review for infrastructure and security-sensitive files

## EKS API Server Access Control

- API-only authentication mode (`authentication_mode = "API"`) — disables the deprecated `aws-auth` ConfigMap. Access is managed exclusively through EKS access entries (CloudTrail-auditable, built-in validation, no ConfigMap tampering risk). This is the AWS-recommended approach per [EKS best practices](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html).
- Private endpoint enabled (`cluster_endpoint_private_access = true`) — node-to-API traffic stays within VPC
- Public endpoint restricted via `cluster_endpoint_public_access_cidrs` variable — defaults to `0.0.0.0/0` for dev, should be set to VPN/office CIDR in production
- Control plane logging enabled — all 5 types (`api`, `audit`, `authenticator`, `controllerManager`, `scheduler`)
- Envelope encryption for K8s Secrets at rest (`cluster_encryption_config`)

## VPC Flow Logs

- VPC Flow Logs enabled on all subnets — captures accepted and rejected traffic metadata
- Destination: CloudWatch Logs (30-day retention) for CloudWatch Insights querying
- Aggregation interval: 60 seconds (balance between granularity and cost)
- Required by: AWS Well-Architected SEC04-BP01, CIS AWS Foundations Benchmark 3.7, SOC 2 CC7.2
- Use cases: detect port scanning, lateral movement, data exfiltration, debug connectivity issues
- Terraform: `enable_flow_log = true` in VPC module (`terraform/main.tf`)

## Web Application Firewall (WAF)

- AWS WAFv2 WebACL attached to the internet-facing ALB via ingress annotation
- **AWSManagedRulesAmazonIpReputationList**: Blocks IPs from Amazon threat intelligence — known bots, DDoS sources, and reconnaissance IPs. Evaluated first (priority 0) to reject known-bad traffic before content inspection.
- **AWSManagedRulesCommonRuleSet**: OWASP Top 10 protections (XSS, path traversal, etc.)
- **AWSManagedRulesKnownBadInputsRuleSet**: Log4Shell, Java deserialization, host header attacks
- **AWSManagedRulesSQLiRuleSet**: SQL injection detection and blocking
- **RateLimitPerIP**: 1000 requests per 5 minutes per IP — prevents API cost abuse (each LLM call costs money) and application-layer DDoS
- CloudWatch metrics enabled for all rule groups (aggregate counts per rule)
- **Full request logging** to CloudWatch Logs (`aws-waf-logs-*`) — filtered to BLOCK actions only for cost efficiency. Captures headers, URI, source IP, and matched rule for incident investigation and false positive tuning. Authorization and Cookie headers redacted to prevent token leakage in logs.
- Terraform: `terraform/waf.tf` | K8s: `alb.ingress.kubernetes.io/wafv2-acl-arn` annotation on ingress

### ALB HTTP Desync Protection

- **`routing.http.drop_invalid_header_fields.enabled=true`**: Drops HTTP headers with field names not matching `[-A-Za-z0-9]+`. Prevents header-based request smuggling where malformed headers bypass WAF rules.
- **`routing.http.desync_mitigation_mode=strictest`**: Rejects all ambiguous HTTP requests (default `defensive` allows some). Prevents HTTP desync attacks where frontend/backend disagree on request boundaries, enabling request smuggling past WAF to the application.
- K8s: `alb.ingress.kubernetes.io/load-balancer-attributes` annotation on ingress

## Compliance Controls Inventory

Consolidated mapping of implemented security controls to compliance frameworks. For PII-specific compliance (data minimization, transfer safeguards), see [ARCHITECTURE.md §3 and §9](ARCHITECTURE.md).

### SOC 2 Trust Service Criteria

| SOC 2 Control | Requirement | Implementation | Evidence |
|---|---|---|---|
| CC6.1 | Logical access controls, encryption at rest | RBAC, `automountServiceAccountToken: false`, KMS-encrypted Terraform state, audit logs, and SNS topics | `k8s/deployment.yaml`, `terraform/backend.tf`, `terraform/guardduty.tf` |
| CC6.3 | Least privilege | All capabilities dropped, non-root (UID 1000), read-only filesystem, no SA token mount | `k8s/deployment.yaml` securityContext |
| CC6.6 | Restrict access at system boundaries | Default-deny NetworkPolicy, app-specific egress whitelist (DNS to kube-dns only + HTTPS 443), DNS tunneling mitigated | `k8s/default-deny.yaml`, `k8s/network-policy.yaml` |
| CC6.7 | Restrict data movement | PII redacted before egress via Presidio sidecar; iptables enforces fail-closed bypass prevention | [ARCHITECTURE.md §5–6](ARCHITECTURE.md) |
| CC7.1 | Detect anomalies | Trivy CVE scanning in CI (fail on CRITICAL/HIGH), ECR scan-on-push with CRITICAL finding SNS alerts, dependency review action | `.github/workflows/ci.yaml`, `terraform/ecr-scan-notifications.tf` |
| CC7.2 | Monitor system components | Prometheus metrics, four golden signals alerts, OOM/HPA alerts, VPC Flow Logs (CloudWatch), Bedrock Guardrails PII audit | `k8s/prometheus-rules.yaml`, `k8s/alertmanager-config.yaml`, `terraform/main.tf` (VPC flow logs) |
| CC7.3 | Evaluate and respond | AlertManager routes to Slack (warning) and PagerDuty (critical), GuardDuty MEDIUM+ findings routed to SNS via EventBridge, runbook procedures documented | `k8s/alertmanager-config.yaml`, `terraform/guardduty.tf`, `RUNBOOK.md` |
| CC8.1 | Change management | CI pipeline gates (build, scan, SBOM), CODEOWNERS review, SHA-pinned actions, immutable ECR tags | `.github/workflows/ci.yaml`, `.github/CODEOWNERS` |

### HIPAA Technical Safeguards (§164.312)

| HIPAA Control | Requirement | Implementation |
|---|---|---|
| Access Control §(a)(1) | Unique user identification, emergency access | IRSA for pod-level AWS access, no shared credentials, ESO for secret rotation |
| Audit Controls §(b) | Record and examine access | Presidio redaction audit logs (entity type + SHA256 hash, never raw PII), CloudWatch shipping via Fluent Bit |
| Integrity §(c)(1) | Protect data from improper alteration | Read-only container filesystem, immutable ECR image tags, Seccomp RuntimeDefault profile |
| Transmission Security §(e)(1) | Encrypt data in transit | TLS-only egress (port 443), Terraform state bucket enforces `aws:SecureTransport`, PII tokenized with AES before leaving cluster |

### GDPR Articles

| GDPR Article | Requirement | Implementation |
|---|---|---|
| Art. 5(1)(c) | Data minimization | Presidio sidecar strips PII before LLM egress — only encrypted tokens leave the cluster |
| Art. 5(1)(f) | Integrity and confidentiality | Encryption at rest (KMS), in transit (TLS), secrets via ESO from Secrets Manager |
| Art. 25 | Data protection by design | Fail-closed architecture — sidecar crash blocks requests rather than bypassing redaction |
| Art. 30 | Records of processing | Structured redaction audit logs with entity counts, types, and processing timestamps |
| Art. 44–49 | International transfer safeguards | Real PII never reaches OpenAI (US-based); only reversible tokens are transmitted |

### CIS Amazon EKS Benchmark Assessment

Controls mapped against CIS Amazon EKS Benchmark v1.4. Control plane (Section 2) is AWS-managed. Worker nodes (Section 3) use EKS managed node groups with hardened launch templates.

| CIS Control | Description | Status | Evidence |
|---|---|---|---|
| 3.x Worker Nodes | EBS encryption, IMDSv2, managed node groups, supported OS | ✅ Pass | `terraform/main.tf` — `encrypted = true`, `http_tokens = "required"`, hop limit 1, `ami_type = AL2023_x86_64_STANDARD` (AL2 EOL Nov 2025) |
| 4.1.x RBAC | No cluster-admin bindings, no wildcard Roles | ✅ Pass | No RBAC resources in repo; SA has zero K8s API access |
| 4.1.5-6 Service Accounts | Default SA not used, tokens not mounted | ✅ Pass | `k8s/deployment.yaml` — custom SA, `automountServiceAccountToken: false` |
| 4.2.x Pod Security | No privileged, no host namespaces, no escalation, non-root, drop ALL caps | ✅ Pass | `k8s/namespace.yaml` — PSS `restricted` enforced; `k8s/deployment.yaml` securityContext |
| 4.3.x Network Policies | CNI supports policies, all namespaces have policies | ✅ Pass | VPC CNI `ENABLE_NETWORK_POLICY=true` with `before_compute=true` (ensures enforcement before nodes join); `k8s/default-deny.yaml` + `k8s/network-policy.yaml` |
| 4.4.x Secrets | External storage, not in env vars (noted) | ✅ Pass | ESO + Secrets Manager + KMS; env var ref required (src/ immutable) |
| 4.6.x General | Namespaces used, security context applied, default NS avoided | ✅ Pass | `persons-finder` namespace; comprehensive securityContext; seccomp RuntimeDefault |
| 5.1.x Cluster Endpoint | Private endpoint, CIDR restriction, API-only auth | ✅ Pass | `cluster_endpoint_private_access = true`, configurable CIDR allowlist, `authentication_mode = "API"` (aws-auth ConfigMap disabled) |
| 5.2.x IAM | IRSA for service accounts | ✅ Pass | `enable_irsa = true`; ESO uses IRSA for Secrets Manager access |
| 5.3.x Encryption | K8s Secrets encrypted at rest | ✅ Pass | `cluster_encryption_config = { resources = ["secrets"] }` |
| 5.4.x IMDS | IMDSv2 required, hop limit 1 | ✅ Pass | `metadata_options` block in node group config |

### CIS Docker Benchmark Assessment

Controls mapped against CIS Docker Benchmark v1.6.0, Section 4 (Container Images and Build File Configuration). Sections 1-3 (host/daemon) are EKS-managed. Section 5 (runtime) is enforced by K8s securityContext.

| CIS Control | Description | Status | Evidence |
|---|---|---|---|
| 4.1 Non-root user | Container runs as non-root | ✅ Pass | `Dockerfile` — `USER appuser` (UID 1000), `k8s/deployment.yaml` — `runAsNonRoot: true` |
| 4.2 Trusted base images | Official, maintained base image | ✅ Pass | `eclipse-temurin:11.0.25_9-jre-jammy` — Eclipse Adoptium official image |
| 4.3 No unnecessary packages | Minimal package installation | ✅ Pass | Only `dumb-init` installed with `--no-install-recommends`; apt lists cleaned |
| 4.4 Image scanning | Vulnerability scanning in CI | ✅ Pass | Trivy container scan + SBOM generation in `.github/workflows/ci.yaml` |
| 4.5 Content trust | Image provenance verification | ⚠️ N/A | ECR immutable tags + SHA-pinned CI; Docker Content Trust not applicable for ECR |
| 4.6 HEALTHCHECK | Dockerfile HEALTHCHECK instruction | ⚠️ Skip | K8s probes (startup/liveness/readiness) replace Docker HEALTHCHECK; adding both causes duplicate health checking |
| 4.7 Update instructions | apt-get update not used alone | ✅ Pass | Combined `apt-get update && apt-get install` in single RUN |
| 4.8 setuid/setgid removal | No setuid/setgid binaries | ✅ Pass | `Dockerfile` — `find / -perm /6000 -type f -exec chmod a-s {} +` strips all suid/sgid bits |
| 4.9 COPY over ADD | No ADD instructions | ✅ Pass | All file operations use COPY |
| 4.10 No secrets in image | No hardcoded credentials | ✅ Pass | Secrets injected at runtime via ESO + Secrets Manager |
| 4.11 Verified packages | Packages from trusted sources | ✅ Pass | dumb-init from Ubuntu official repos; Gradle deps verified by checksums |

### Gaps and Recommendations

| Gap | Risk | Recommendation |
|---|---|---|
| No runtime threat detection | Container escape or crypto-mining undetected | ~~Add Falco or GuardDuty for EKS when cluster is production~~ **RESOLVED**: GuardDuty enabled with audit log monitoring + Runtime Monitoring (`terraform/guardduty.tf`). Runtime Monitoring deploys a managed security agent DaemonSet that detects OS-level container threats (crypto mining, reverse shells, container escape) that audit logs alone cannot see. MEDIUM+ findings (severity ≥ 4) routed to SNS via EventBridge for real-time alerting. |
| No automated compliance scanning | Drift from baseline undetected between audits | ~~Add Kyverno or OPA Gatekeeper for continuous policy enforcement~~ **PARTIALLY RESOLVED**: ValidatingAdmissionPolicy (K8s 1.30+ built-in, no external infrastructure) restricts container images to ECR registries across all workload types — Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs, bare Pods, and ephemeral containers (`kubectl debug`) — in PII-classified namespaces (`k8s/admission-policy.yaml`). CronJobs covered indirectly via Job validation. For full policy coverage (label requirements, resource quotas, network policy enforcement), add Kyverno or OPA Gatekeeper. |
| No data classification labels | PII handling depends on architecture knowledge, not metadata | ~~Add K8s labels (`data-classification: pii`) to pods handling sensitive data~~ **RESOLVED**: Added `data-classification: pii` label to namespace (`k8s/namespace.yaml`) and pod template (`k8s/deployment.yaml`). Enables compliance auditing (`kubectl get pods -l data-classification=pii`), future Kyverno/OPA policy targeting, and operational awareness of PII-handling workloads. |

### CIS Kubernetes Benchmark v1.8 Section 5 (Policies) Assessment

Controls mapped against CIS Kubernetes Benchmark v1.8 Section 5. Sections 1-4 (control plane, etcd, worker nodes) are EKS-managed.

| CIS Control | Description | Status | Evidence |
|---|---|---|---|
| 5.1.1 | cluster-admin only where required | ✅ Pass | No ClusterRoleBindings in repo; SA has zero K8s API access |
| 5.1.2-4 | Minimize secrets/wildcard/pod-create access | ✅ Pass | No Roles or ClusterRoles defined; app needs no K8s API access |
| 5.1.5 | Default SA not actively used, automount disabled | ✅ Pass | `k8s/namespace.yaml` — default SA patched with `automountServiceAccountToken: false` |
| 5.1.6 | SA tokens only mounted where necessary | ✅ Pass | `k8s/deployment.yaml` — `automountServiceAccountToken: false` on pod spec |
| 5.1.7-13 | system:masters, Bind/Escalate/Impersonate | ✅ Pass | No RBAC resources; no privileged bindings |
| 5.2.1 | Active policy control mechanism | ✅ Pass | PSS `restricted` enforced on app namespace (`k8s/namespace.yaml`); monitoring namespace: `privileged` enforce + `baseline` audit/warn (`terraform/monitoring.tf`) |
| 5.2.2-13 | Pod security (privileged, hostPID/IPC/Net, escalation, root, capabilities) | ✅ Pass | PSS restricted + comprehensive securityContext (drop ALL, runAsNonRoot, seccomp RuntimeDefault) |
| 5.3.1 | CNI supports NetworkPolicies | ✅ Pass | VPC CNI `ENABLE_NETWORK_POLICY=true` with `before_compute=true` in EKS addon config |
| 5.3.2 | All namespaces have NetworkPolicies | ✅ Pass | `k8s/default-deny.yaml` (deny-all) + `k8s/network-policy.yaml` (app-specific: DNS restricted to kube-dns, HTTPS 443 egress) |
| 5.4.1 | Secrets as files over env vars | ⚠️ Noted | src/ immutable — env var ref via ESO secretKeyRef is standard pattern |
| 5.4.2 | External secret storage | ✅ Pass | ESO + AWS Secrets Manager + KMS encryption (`k8s/external-secret.yaml`) |
| 5.5.1 | ImagePolicyWebhook admission controller | ✅ Pass | ValidatingAdmissionPolicy restricts images to ECR registries in PII namespaces — covers all workload types plus ephemeral containers (`k8s/admission-policy.yaml`). Built-in K8s 1.30+ — no Kyverno/OPA required. |
| 5.7.1 | Administrative namespace boundaries | ✅ Pass | Dedicated `persons-finder` namespace; default namespace not used |
| 5.7.2 | Seccomp profile set | ✅ Pass | `seccompProfile.type: RuntimeDefault` at pod level |
| 5.7.3 | SecurityContext applied | ✅ Pass | Pod + container securityContext with all CIS-recommended fields |
| 5.7.4 | Default namespace not used | ✅ Pass | All resources in `persons-finder` namespace |
