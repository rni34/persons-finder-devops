# Persons Finder — Common Commands
# Usage: make <target>
# Run `make help` to see all available targets.

.DEFAULT_GOAL := help
SHELL := /bin/bash

# ---------- Variables ----------
IMAGE_NAME ?= persons-finder
IMAGE_TAG  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "latest")
# Set ECR_REPO from terraform output: ECR_REPO=$$(cd terraform && terraform output -raw ecr_repository_url) make docker-push
ECR_REPO   ?= $(shell cd terraform && terraform output -raw ecr_repository_url 2>/dev/null || echo "REPLACE_WITH_ECR_URL")
# Pin Trivy version — :latest is a supply chain risk. Local scan targets mount the
# Docker socket and full source code; a compromised image could exfiltrate secrets.
# Update: check https://github.com/aquasecurity/trivy/releases
TRIVY_IMAGE ?= aquasec/trivy:0.69.1

# ---------- Build ----------

.PHONY: build
build: ## Build the application with Gradle
	chmod +x gradlew && ./gradlew build --no-daemon

.PHONY: test
test: ## Run tests
	chmod +x gradlew && ./gradlew test --no-daemon

.PHONY: clean
clean: ## Clean build artifacts
	chmod +x gradlew && ./gradlew clean --no-daemon

# ---------- Docker ----------

.PHONY: docker-build
docker-build: ## Build Docker image
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

.PHONY: docker-push
docker-push: ## Push Docker image to ECR
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(ECR_REPO):$(IMAGE_TAG)
	docker push $(ECR_REPO):$(IMAGE_TAG)

# ---------- Security ----------

.PHONY: scan
scan: docker-build ## Run Trivy security scan on Docker image
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
		$(TRIVY_IMAGE) image --severity CRITICAL,HIGH --ignore-unfixed $(IMAGE_NAME):$(IMAGE_TAG)

.PHONY: scan-k8s
scan-k8s: ## Run Trivy scan on K8s manifests
	docker run --rm -v $(PWD):/src $(TRIVY_IMAGE) config /src/k8s/

.PHONY: scan-tf
scan-tf: ## Run Trivy scan on Terraform
	docker run --rm -v $(PWD):/src $(TRIVY_IMAGE) config /src/terraform/

# ---------- Kubernetes ----------

.PHONY: deploy
deploy: ## Apply K8s manifests via Kustomize
	kubectl apply -k k8s/

.PHONY: undeploy
undeploy: ## Delete K8s resources
	kubectl delete -k k8s/ --ignore-not-found

# ---------- Terraform ----------

.PHONY: fmt
fmt: ## Format Terraform files
	cd terraform && terraform fmt -recursive

.PHONY: fmt-check
fmt-check: ## Check Terraform formatting
	cd terraform && terraform fmt -check -recursive

.PHONY: tf-validate
tf-validate: ## Validate Terraform configuration
	cd terraform && terraform init -backend=false && terraform validate

# ---------- Observability ----------

.PHONY: monitoring-up
monitoring-up: ## Start local Prometheus + Grafana stack
	docker compose -f docker-compose.observability.yml up -d
	@echo "Prometheus: http://localhost:9090"
	@echo "Grafana:    http://localhost:3000 (admin/admin)"

.PHONY: monitoring-down
monitoring-down: ## Stop local observability stack
	docker compose -f docker-compose.observability.yml down

# ---------- Help ----------

.PHONY: help
help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-16s\033[0m %s\n", $$1, $$2}'
