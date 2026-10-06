# PoC «Primer Golden Path» · ParkGlobal
SHELL := /bin/bash
CTX   := kind-parkglobal-poc
# yarn 4.13.0 vía corepack (packageManager en backstage/package.json), con caché propia del proyecto.
export COREPACK_HOME := $(CURDIR)/.corepack
export COREPACK_ENABLE_DOWNLOAD_PROMPT := 0
YARN  := corepack yarn
export GITHUB_TOKEN ?= $(shell gh auth token 2>/dev/null)

.PHONY: help bootstrap platform backstage backstage-stop e2e evidence test teardown argocd-ui validate

help: ## Lista los objetivos
	@grep -E '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

bootstrap: ## Clúster kind + Argo CD + secreto del repo + app-of-apps
	./scripts/bootstrap.sh

platform: ## Espera a que la plataforma (GitOps) quede Synced/Healthy
	./scripts/wait-platform.sh
	kubectl --context $(CTX) get xrd,compositions,functions

backstage: ## Arranca Backstage en segundo plano (log en evidence/raw/backstage.log)
	cd backstage && $(YARN) install --immutable >/dev/null && (nohup $(YARN) start > ../evidence/raw/backstage.log 2>&1 &)
	@echo "Backstage: http://localhost:3000 (backend :7007). Log: evidence/raw/backstage.log"

backstage-stop: ## Detiene Backstage
	-pkill -f 'backstage-cli repo start' ; pkill -f 'backstage-cli package start'

test: ## Pruebas unitarias de las políticas Kyverno
	kyverno test platform/kyverno/tests

validate: ## Dry-run en servidor de los fixtures (admisión)
	@for f in tests/fixtures/invalid-*.yaml; do \
	  kubectl --context $(CTX) apply --dry-run=server -f "$$f" >/dev/null 2>&1 && echo "ERROR: $$f fue aceptado" || echo "OK rechazado: $$f"; done
	kubectl --context $(CTX) apply --dry-run=server -f tests/fixtures/valid-claim.yaml

e2e: ## Solicitud por PR + espera Ready + lead time (NAME=e2e-db)
	./scripts/request-db.sh parking-core $(or $(NAME),e2e-db) small dev CC-PARK-01
	kubectl --context $(CTX) -n team-parking-core wait databaseclaim/$(or $(NAME),e2e-db) --for=condition=Ready --timeout=900s
	./scripts/measure-lead-time.sh team-parking-core $(or $(NAME),e2e-db)

evidence: ## Recolecta evidencia en evidence/
	./scripts/collect-evidence.sh

argocd-ui: ## Port-forward de Argo CD en https://localhost:8080 (admin / ver comando)
	@echo "Usuario admin. Contraseña: kubectl --context $(CTX) -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
	kubectl --context $(CTX) -n argocd port-forward svc/argocd-server 8080:80

teardown: ## Borra SOLO el clúster de la PoC (no toca evidence/ ni el repo)
	./scripts/teardown.sh
