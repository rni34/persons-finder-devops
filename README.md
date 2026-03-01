# 🛠️ Persons Finder – DevOps & SRE Challenge (AI-Augmented)

Welcome to the **Persons Finder** DevOps challenge.

**Scenario:**
The development team has finished the `persons-finder` API (a Java/Kotlin Spring Boot app that talks to an external LLM). It works on their machine. Now, **you** need to take it to production.

**Our Philosophy:** We want engineers who use AI to move fast, but who have the wisdom to verify every line.

---

## 🎯 The Mission

Your task is to Containerize, Infrastructure-as-Code (IaC), and secure this application.

### 1. 🐳 Containerization
*   Create a `Dockerfile` for the application.
*   **AI Challenge:** Ask an AI (ChatGPT/Claude) to write the Dockerfile.
*   **Audit:** The AI likely missed best practices (e.g., non-root user, multi-stage build, pinning versions). **Fix them.**
*   *Output:* An optimized `Dockerfile`.

### 2. ☁️ Infrastructure as Code (Kubernetes/Terraform)
*   Deploy this app to a local cluster (Minikube/Kind) or output Terraform for AWS/GCP.
*   **Requirements:**
    *   **Secrets:** The app needs an `OPENAI_API_KEY`. Do not bake it into the image. Show how you inject it securely (K8s Secrets, Vault, etc.).
    *   **Scaling:** Configure HPA (Horizontal Pod Autoscaler) based on CPU or custom metrics.
*   **AI Task:** Use AI to generate the K8s manifests (Deployment, Service, Ingress). **Document what you had to fix.** (Did it forget `readinessProbe`? Did it request 400 CPUs?)

### 3. 🛡️ The "AI Firewall" (Architecture)
The app sends user PII (names, bios) to an external LLM provider.
*   **Design Challenge:** Create a short architectural diagram or description (`ARCHITECTURE.md`) showing how you would secure this egress traffic.
*   **Question:** How would you implement a "PII Redaction Sidecar" or Gateway logic to prevent real names from leaving our cluster? You don't have to build it, just design the infrastructure for it.

### 4. 🤖 CI/CD & AI Usage
*   Create a CI pipeline (GitHub Actions preferred).
*   **The AI Twist:** We want to fail the build if the code "looks unsafe".
    *   Add a step in the pipeline that runs a security scanner (Trivy/Snyk) OR a mocked "AI Code Reviewer" step.

---

## 📝 Mandatory: The AI Log (`AI_LOG.md`)

We hire engineers who know how to collaborate with machines.
Please verify your work by documenting:

1.  **The Prompt:** "I asked ChatGPT: *'Write a K8s deployment for a Spring Boot app'*."
2.  **The Flaw:** "It gave me a deployment running as `root` and with no resource limits."
3.  **The Fix:** "I modified lines 12-15 to add `securityContext`."

**If you do not include this log, we will not review your submission.**

---

## ✅ Getting Started

1.  Clone this repo.
2.  Assume the code inside is a buildable Spring Boot app (or build it with `./gradlew build`).
3.  Push your solution (Dockerfile, K8s manifests/Terraform, CI configs) to your own public repository.

## 📬 Submission

Submit your repository link. We care about:
*   **Security:** How you handle the API Key.
*   **Reliability:** Probes, Limits, Scaling.
*   **AI Maturity:** Your `AI_LOG.md` (Did you blindly trust the bot, or did you engineer it?).

---

## 🏗️ Solution Overview

### Repository Structure

```
├── Dockerfile                  # Multi-stage build, non-root, JRE-slim, G1GC, dumb-init
├── Makefile                    # build, test, docker-build, scan, deploy, monitoring-up
├── k8s/                        # Kubernetes manifests (Kustomize)
│   ├── kustomization.yaml      # Apply order: namespace → secrets → workloads → scaling → network → monitoring
│   ├── namespace.yaml          # Pod Security Standards (restricted), data-classification: pii
│   ├── deployment.yaml         # Probes, seccomp, topology spread, graceful shutdown
│   ├── hpa.yaml                # CPU-based autoscaling (2–10 replicas)
│   ├── pdb.yaml                # maxUnavailable: 1
│   ├── external-secret.yaml    # ESO → AWS Secrets Manager for OPENAI_API_KEY
│   ├── admission-policy.yaml    # ValidatingAdmissionPolicy: restrict images to ECR in PII namespaces
│   ├── network-policy.yaml     # Ingress: ALB (8080) + monitoring (8081); egress: DNS + HTTPS
│   ├── default-deny.yaml       # Default-deny ingress/egress baseline
│   ├── prometheus-rules.yaml   # Four golden signals + OOM/HPA alerts + watchdog
│   └── ...                     # limit-range, resource-quota, ingress, service, grafana, alertmanager
├── terraform/                  # EKS, VPC, ECR, Secrets Manager, WAF, GuardDuty, monitoring
├── .github/
│   ├── workflows/ci.yaml       # Build → scan → SBOM → Terraform validate → AI review → ECR push
│   ├── dependabot.yml          # Gradle, Docker, GitHub Actions, Terraform ecosystems
│   └── CODEOWNERS              # Required review for infra and security-sensitive files
├── observability/              # Local Prometheus + Grafana (docker-compose)
└── docs/adr/                   # ADRs: no CPU limits, PDB strategy, subnet sizing
```

### Quick Start

```bash
make help              # Show all available commands
make build             # Build the app
make docker-build      # Build container image
make scan              # Trivy security scan
make deploy            # kubectl apply -k k8s/
make monitoring-up     # Local Prometheus + Grafana
```

### Key Documentation

| Document | Contents |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | PII redaction sidecar design, threat model, Presidio + Bedrock Guardrails |
| [DEPLOYMENT.md](DEPLOYMENT.md) | Step-by-step EKS deployment (Terraform → ECR → K8s) |
| [SECURITY.md](SECURITY.md) | Security controls inventory and compliance mapping |
| [RUNBOOK.md](RUNBOOK.md) | Incident response, scaling, upgrades, disaster recovery |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Common failure modes and debugging commands |
| [AI_LOG.md](AI_LOG.md) | AI collaboration log — prompts, flaws found, fixes applied |
| [docs/adr/](docs/adr/) | Architecture Decision Records (no CPU limits, PDB strategy, subnet sizing) |

### Key Design Decisions

- **No CPU limits** on JVM pods — CFS throttling causes latency spikes during GC/JIT ([ADR-0001](docs/adr/0001-no-cpu-limits-jvm.md))
- **Secrets via ESO** — External Secrets Operator syncs from AWS Secrets Manager; no secrets in git or images
- **Defense-in-depth networking** — default-deny + app-specific egress + Cilium FQDN policy (documented)
- **Fail-closed PII redaction** — Presidio sidecar architecture where iptables redirect ensures bypass is impossible
