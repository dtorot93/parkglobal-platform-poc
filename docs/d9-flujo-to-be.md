# D9 · Flujo To-Be del Golden Path «Solicitar base de datos PostgreSQL»

Lo que el desarrollador ve: un formulario de 6 campos. Lo que la plataforma orquesta: 9 pasos invisibles.

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Desarrollador (team-parking-core)
    participant BS as Backstage (Scaffolder)
    participant GH as GitHub (repo GitOps)
    participant CI as GitHub Actions + Kyverno CLI
    participant AR as Argo CD (ApplicationSet)
    participant KY as Kyverno (admisión)
    participant XP as Crossplane v2 (Composition)
    participant PG as CloudNativePG
    participant K8S as Secret + RBAC

    Dev->>BS: Formulario: nombre, equipo, centro de costo, tamaño, entorno
    BS->>BS: 1. Genera databaseclaim.yaml y catalog-info.yaml
    BS->>GH: 2. Abre PR claim/<name> (auditable; reemplaza el ticket)
    GH->>CI: pull_request sobre claims/**
    CI->>CI: 3. kyverno test + kyverno apply (shift-left)
    alt Viola una política
        CI-->>GH: Check rojo con el mensaje de la política; no se integra
    else Cumple
        CI->>GH: 4. gh pr merge --squash (sin revisión humana)
    end
    AR->>GH: 5. Detecta el cambio en main (pull, ≤30 s)
    AR->>KY: Aplica DatabaseClaim en team-<team>
    KY->>KY: 6. Valida de nuevo y agrega etiquetas FinOps
    KY->>XP: Admitido
    XP->>PG: 7. Compone Cluster (perfil small/medium)
    XP->>K8S: 7. Compone Role + RoleBinding para spec.access.readers
    PG->>K8S: 8. Crea la base y publica el Secret <name>-app
    PG-->>XP: Cluster Ready=True
    XP-->>AR: 8. status.endpoint, status.secretRef, Ready=True
    BS->>GH: 9. Descubre claims/**/catalog-info.yaml (cada 1 min)
    BS-->>Dev: Resource en el catálogo, vinculado al equipo propietario
```

**Leyenda:** Backstage, GitHub y Argo CD ya existen en ParkGlobal (componentes existentes). La XRD, la Composition, las políticas y la plantilla son nuevas en la TVP. En AWS, CloudNativePG se sustituye por Aurora + Secrets Manager (roadmap de la composición, ADR-002).

**Lectura:** el desarrollador solo interactúa con el paso 1. Las dos barreras de gobierno (pasos 3 y 6) usan las mismas políticas, así que nada que viole FinOps o seguridad llega al clúster, y la revisión humana deja de ser el cuello de botella de F1.
