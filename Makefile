# PoC «Primer Golden Path» · ParkGlobal
SHELL := /bin/bash
CTX   := kind-parkglobal-poc
# yarn 4.13.0 vía corepack (packageManager en backstage/package.json), con caché propia del proyecto.
export COREPACK_HOME := $(CURDIR)/.corepack
export COREPACK_ENABLE_DOWNLOAD_PROMPT := 0
YARN  := corepack yarn
export GITHUB_TOKEN ?= $(shell gh auth token 2>/dev/null)

.PHONY: acceptance help bootstrap platform backstage backstage-stop e2e evidence test teardown argocd-ui validate \
        local-up events-test events-status events-demo-build events-demo-deploy events-demo registry-ui

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
	./scripts/collect-evidence.sh team-parking-core e2e-db bad-medium-db

acceptance: ## Criterios de aceptación (solo lectura) -> evidence/validacion.txt
	./scripts/acceptance.sh > evidence/validacion.txt 2>&1; cat evidence/validacion.txt

argocd-ui: ## Port-forward de Argo CD en https://localhost:8080 (admin / ver comando)
	@echo "Usuario admin. Contraseña: kubectl --context $(CTX) -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
	kubectl --context $(CTX) -n argocd port-forward svc/argocd-server 8080:80

teardown: ## Borra SOLO el clúster de la PoC (no toca evidence/ ni el repo)
	./scripts/teardown.sh

# ---------------------------------------------------------------- Proyecto 2 · Golden Path de eventos (ECST)
CI_REGISTRY_IMAGE := apicurio/apicurio-registry:3.3.4
CI_REGISTRY_URL   := http://localhost:18080/apis/ccompat/v7

local-up: ## Plataforma completa SIN GitOps (mismas olas y versiones que Argo CD) para iterar antes del push
	./scripts/local-up.sh

events-test: ## Barrera 1 en local: políticas + contratos contra un registry efímero (igual que el CI)
	kyverno test platform/kyverno/tests
	./scripts/validate-streams.sh
	./scripts/contracts/ci-registry.sh $(CI_REGISTRY_IMAGE)
	python3 scripts/contracts/check_contracts.py --registry $(CI_REGISTRY_URL)
	@echo "--- un cambio incompatible DEBE fallar:"
	@if python3 scripts/contracts/check_contracts.py --registry $(CI_REGISTRY_URL) --stream streams/tarifas/zone-tariff-state \
	    --candidate tests/contracts/zone-tariff-state-v2-breaking.avsc >/dev/null; then echo "ERROR: se aceptó"; exit 1; \
	  else echo "OK: v2 sin currency rechazada por FULL_TRANSITIVE"; fi

events-status: ## Claims, tópicos, jobs registradores y subjects
	kubectl --context $(CTX) get eventstreamclaims -A -o wide
	kubectl --context $(CTX) -n kafka get kafkatopics
	kubectl --context $(CTX) get jobs -A -l parkglobal.io/stream

events-demo-build: ## Construye la imagen de los servicios de demo y la carga en kind
	./apps/ecst-demo/build.sh

events-demo-deploy: ## Despliega Tarifas, Zonas y Consumidor C (solo referencian el ConfigMap de la plataforma)
	kubectl --context $(CTX) apply -f apps/ecst-demo/k8s/
	kubectl --context $(CTX) -n team-tarifas rollout status deploy/tarifas --timeout=180s
	kubectl --context $(CTX) -n team-zonas rollout status deploy/zonas --timeout=180s
	kubectl --context $(CTX) -n team-consumidor-c rollout status deploy/consumidor-c --timeout=180s

events-demo: ## Escenarios de la demo + evidencia en evidence/p2/ (ESC="02 07" para elegir)
	CI_REGISTRY=$(CI_REGISTRY_URL) ./scripts/events-demo.sh $(ESC)

registry-ui: ## Consola del Schema Registry en http://localhost:8888 (API en :8080)
	@echo "Registry UI: http://localhost:8888  ·  API: http://localhost:8080/apis/registry/v3"
	kubectl --context $(CTX) -n team-platform-events port-forward svc/schema-registry 8080:8080 & \
	kubectl --context $(CTX) -n team-platform-events port-forward svc/schema-registry-ui 8888:8080
