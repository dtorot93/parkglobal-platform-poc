# ADR-004 · Crossplane v2 con XR namespaced en lugar de claims

**Estado:** aceptado

## Contexto
En Crossplane v1 la API para equipos era un *claim* namespaced que creaba un XR cluster-scoped, y para componer recursos de Kubernetes se necesitaba provider-kubernetes. Crossplane v2 (instalado: 2.4.2) introduce XR namespaced, elimina los claims para nuevas APIs y permite componer cualquier recurso de Kubernetes directamente.

## Opciones
1. XRD `apiextensions.crossplane.io/v1` con `claimNames` (modelo legado, soportado en v2).
2. **XRD `apiextensions.crossplane.io/v2` con `scope: Namespaced`**: el XR se llama `DatabaseClaim` y vive en el namespace del equipo.

## Decisión
Opción 2. El nombre `DatabaseClaim` se conserva como término de producto aunque técnicamente sea un XR.

## Consecuencias
- (+) Un objeto menos por solicitud (sin par claim/XR) y aislamiento natural por namespace: el XR solo compone recursos en su namespace.
- (+) Sin provider-kubernetes: Crossplane compone `postgresql.cnpg.io/Cluster`, `Role` y `RoleBinding` con un ClusterRole agregado (`rbac.crossplane.io/aggregate-to-crossplane`).
- (+) Argo CD sincroniza el XR directamente; la salud se calcula con una regla Lua sobre la condición `Ready`.
- (−) En AWS, los managed resources de provider-aws también deben ser namespaced (providers v2 con `.m.` en el grupo); verificar la versión del provider antes de migrar.
- (−) La composición usa `function-go-templating` (además de `function-auto-ready`) porque mapear `spec.access.readers` (array) a `subjects` de un RoleBinding no se expresa bien con patch-and-transform.
