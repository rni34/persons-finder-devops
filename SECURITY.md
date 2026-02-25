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
| Non-root user | `runAsUser: 1000`, `runAsNonRoot: true` |
| Read-only filesystem | `readOnlyRootFilesystem: true` + `/tmp` emptyDir |
| No privilege escalation | `allowPrivilegeEscalation: false` |
| Minimal capabilities | `drop: ["ALL"]` |
| Seccomp profile | `seccompProfile: RuntimeDefault` |
| SA token disabled | `automountServiceAccountToken: false` |
| Signal handling | `dumb-init` as PID 1 for proper SIGTERM forwarding |

## Vulnerability Scanning

- **Docker image**: Trivy scans for CRITICAL/HIGH CVEs on every CI run (build fails on findings)
- **Terraform IaC**: Trivy config scan for misconfigurations (build fails on findings)
- **K8s manifests**: Trivy config scan (warnings only — CRD false positives)
- **ECR**: `scan_on_push = true` for continuous image scanning
- **AI code review**: Claude Code security review on pull requests (semantic analysis)

## Supply Chain Security

- All GitHub Actions are pinned to full-length commit SHAs (not mutable tags)
- ECR images use immutable tags (`image_tag_mutability = "IMMUTABLE"`)
- Docker base images are pinned to specific versions (`eclipse-temurin:11.0.25_9-jre-jammy`)
- `.github/CODEOWNERS` requires review for infrastructure and security-sensitive files
