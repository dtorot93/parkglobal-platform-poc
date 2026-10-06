# Versiones fijadas de la PoC

Registradas el 2026-10-05 en la Mac de referencia (`uname -m` = arm64). Nada usa `latest`.

## Herramientas locales

| Herramienta | Versión |
|---|---|
| Docker Engine | 20.10.23 (≈7,7 GB RAM, 6 CPU asignados) |
| kind | v0.31.0 |
| kubectl (cliente) | v1.37.1 (Homebrew; el de Docker Desktop 1.25 queda detrás en el PATH) |
| helm | v4.1.3+gc94d381 |
| git | 2.50.1 |
| gh | 2.92.0 |
| node | v22.12.0 |
| corepack | 0.29.4 |
| yarn | 4.13.0 vía corepack (`packageManager`), `COREPACK_HOME=.corepack`; la yarn 1.22 global no se usa |
| kyverno CLI | 1.19.1 |
| argocd CLI | v3.5.2+e258ee2.dirty |
| yq | v4.54.1 |
| gitleaks | 8.30.1 |

## Clúster y plataforma

| Componente | Origen | Versión |
|---|---|---|
| Nodo kind | kindest/node | v1.35.0@sha256:452d707d… (default de kind v0.31.0) |
| Argo CD | chart argo/argo-cd | 10.9.6 (app v3.5.3) |
| Crossplane | chart crossplane-stable/crossplane | 2.4.2 |
| Kyverno | chart kyverno/kyverno | 3.9.1 (app v1.19.1) |
| CloudNativePG | chart cnpg/cloudnative-pg | 0.29.1 (operador 1.30.1) |
| PostgreSQL | imagen por defecto de CNPG 1.30.1 | fijada por la versión del operador (ghcr.io/cloudnative-pg/postgresql) |
| function-go-templating | xpkg.crossplane.io/crossplane-contrib | v0.13.0 |
| function-auto-ready | xpkg.crossplane.io/crossplane-contrib | v0.7.0 |
| Cliente psql (prueba de conectividad) | postgres | 16.10-alpine (multi-arch) |

## Backstage

| Componente | Versión |
|---|---|
| @backstage/create-app | 0.9.2 |
| Release de Backstage | 1.55.0 |
| @backstage/plugin-catalog-backend-module-github | 0.14.0 |
| @yarnpkg/core (resolution) | 4.9.1; la 4.9.2 se publicó con un parche local de `got` inexistente y rompe `yarn install` |

## CI (GitHub Actions)

| Componente | Versión |
|---|---|
| Runner | ubuntu-24.04 |
| actions/checkout | v7.0.1 |
| kyverno CLI | v1.19.1 |
| kubeconform | v0.8.0 |
