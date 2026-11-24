# Narración del video · Proyecto 2 · Golden Path de eventos

Voz: ElevenLabs. Sin cámara ni subtítulos. Duración estimada: **unos 5 minutos y medio** (18 segmentos, ~840 palabras).
El texto para pegar en ElevenLabs, sin las notas visuales, está en [narracion-elevenlabs.txt](narracion-elevenlabs.txt).

| Parte | Segmentos | Imagen |
|---|---|---|
| 1 · Qué se hizo | 01–04 | Animación HTML |
| 2 · Cómo se hizo | 05–09 | Animación HTML |
| 3 · En qué beneficia (prueba en vivo) | 10–16 | Grabación real de la demo en la terminal |
| 4 · Cierre | 17–18 | Animación HTML |

Las cifras que se dicen son las medidas en la evidencia (`evidence/p2/`). En la parte 3 la voz no dice milisegundos exactos: los muestra la pantalla, y cambian en cada ejecución.

---

## Parte 1 · Qué se hizo

### 01 · Apertura
**Imagen:** título. La tarjeta «Parte 1: DatabaseClaim» se desplaza y aparece «Parte 2: EventStreamClaim».

> En la primera parte del proyecto, ParkGlobal estrenó su plataforma interna con un primer camino dorado: pedir una base de datos en autoservicio. En esta segunda parte, la plataforma crece con una nueva capacidad: publicar eventos de estado gobernados, también en autoservicio.

### 02 · El problema
**Imagen:** aparecen las cifras de una en una: 0 esquemas, 1 de 20 tópicos compactados, 2 de 42 servicios.

> El punto de partida era un Kafka sin contratos. No había ningún esquema registrado, solo uno de veinte tópicos del dominio de Zonas estaba compactado, y apenas dos de cuarenta y dos servicios declaraban sus eventos. Nadie sabía con certeza quién consumía qué, ni si un cambio iba a romper a otro equipo.

### 03 · El caso de Tarifas
**Imagen:** flujo actual animado. Tarifas, reloj de 5 s, el aviso viaja y se encienden en rojo las 4 llamadas REST de vuelta.

> Un ejemplo concreto. Cuando Tarifas cambia un precio, solo publica un aviso de que algo cambió, y lo hace después de esperar cinco segundos fijos. Para conocer el precio nuevo, Zonas y el Consumidor C tienen que llamar de vuelta: cuatro o más llamadas síncronas por cada cambio. Y si Tarifas está caído, el cambio simplemente se pierde.

### 04 · La solución
**Imagen:** el mismo flujo se transforma. Las flechas rojas desaparecen y el evento lleva la tarifa completa a dos copias locales.

> La solución combina dos ideas. La primera es un patrón llamado Event-Carried State Transfer: el evento ya no avisa, sino que lleva el estado completo de la tarifa. Cada consumidor guarda su propia copia local y deja de llamar de vuelta. La segunda es convertir eso en un producto de la plataforma, para que cualquier equipo pueda publicar un stream así sin ser experto en Kafka.

## Parte 2 · Cómo se hizo

### 05 · Lo que declara el equipo
**Imagen:** el archivo `EventStreamClaim`, con los campos resaltados uno a uno. Al lado, tachados: particiones, retención, compatibilidad, serializadores.

> El equipo solo declara qué quiere publicar, en un recurso llamado EventStreamClaim: el dueño, el dominio, la entidad, la clave, quiénes lo consumen y el contrato de datos en formato Avro. Son siete campos obligatorios y un archivo de contrato. No elige particiones, ni retención, ni compatibilidad, ni serializadores.

### 06 · El camino
**Imagen:** el archivo recorre el pipeline: pull request, integración continua, auto-merge, Argo CD, Kyverno y Crossplane.

> Ese archivo entra por un pull request. La integración continua valida las políticas y prueba el contrato contra un registro de esquemas temporal. Si todo cumple, el cambio se integra solo, sin revisión humana. Después, Argo CD lo sincroniza con el clúster, Kyverno vuelve a validar las reglas al momento de crearlo, y Crossplane hace el trabajo pesado.

### 07 · Lo que crea la plataforma
**Imagen:** Crossplane se divide en tres cajas: Strimzi y Kafka, Apicurio, configuración. Abajo, un enlace a la base de datos de la parte 1.

> Crossplane crea tres cosas por el equipo: un tópico compactado en Kafka, con Strimzi; el contrato registrado en Apicurio, con compatibilidad total y transitiva; y la configuración de conexión, que se entrega al dueño y a cada consumidor. Incluso la base de datos del registro de esquemas se pidió con el camino dorado de la primera parte.

### 08 · Dos decisiones con evidencia
**Imagen:** a la izquierda, la matriz del spike (JSON Schema en rojo, Avro en verde). A la derecha, dos escudos: «CI» y «Registry 409».

> Dos decisiones se tomaron con evidencia. Primero, Avro en lugar de JSON Schema: en las pruebas, JSON Schema con esta política no permitía agregar ni un campo opcional. Segundo, dos barreras contra los cambios que rompen: una en la integración continua y otra en el propio registro de esquemas, por si alguien se salta la primera.

### 09 · Probado con un pull request real
**Imagen:** línea de tiempo del PR #6: 0 s abierto, 26 s CI en verde, 31 s integrado, 2 min 34 s Ready.

> Todo esto se probó con un pull request real. La integración continua pasó en veintiséis segundos, el cambio se integró solo a los treinta y un segundos, y el stream quedó listo en el clúster dos minutos y medio después de abrir el pull request. Casi todo ese tiempo es la espera de Argo CD revisando el repositorio.

## Parte 3 · En qué beneficia (demo en vivo)

### 10 · Transición
**Imagen:** portada de la demo en la terminal.

> Ahora veamos la plataforma funcionando, en vivo, sobre un clúster local.

### 11 · Autoservicio
**Imagen:** paso 1/6. Se aplica el claim y aparecen los ✔ con sus tiempos.

> Primero se crea un stream nuevo desde cero. En segundos, la plataforma deja listos el tópico, el contrato y la configuración de los consumidores. El equipo no abrió ningún ticket ni esperó a otro equipo.

### 12 · Límites
**Imagen:** paso 2/6. Dos solicitudes RECHAZADAS con el mensaje de Kyverno.

> El autoservicio tiene límites. Si un equipo intenta publicar en el dominio de otro, o declara datos personales, Kyverno lo rechaza y explica por qué. Las reglas son código, no una revisión manual.

### 13 · El evento trae el estado
**Imagen:** paso 3/6. El precio llega a Zonas y al Consumidor C; «Llamadas de vuelta: 0».

> Ahora Tarifas cambia un precio. Zonas y el Consumidor C lo reciben en milisegundos y lo guardan en su copia local. El Consumidor C arma por su cuenta la jerarquía de ciudad, zonas y tarifa. Las llamadas de vuelta a Tarifas pasan de cuatro o más a cero.

### 14 · Disponibilidad
**Imagen:** paso 4/6. Tarifas en 0 réplicas; los dos consumidores responden.

> Ahora apagamos Tarifas por completo. Los consumidores siguen respondiendo con el último precio y siguen tomando decisiones, porque ya no dependen de que el productor esté disponible.

### 15 · Un cambio que rompe
**Imagen:** paso 5/6. FALLA en el chequeo del CI y HTTP 409 en el registry, ambos con `[currency at /fields/6]`.

> ¿Y si alguien borra un campo que otros equipos usan? La validación de la integración continua lo rechaza y señala el campo exacto. Si alguien se la salta y va directo al registro, recibe un error cuatrocientos nueve. La versión rota no se registra.

### 16 · Evolucionar sin romper
**Imagen:** paso 6/6. Se registra la v2; el lector v1 y el lector v2 leen el mismo mensaje.

> Gobernar no significa congelar. Un campo nuevo y opcional se acepta en segundos. Un productor escribe con la versión dos, y un consumidor que todavía usa la versión uno sigue leyendo el mismo mensaje, sin cambiar nada.

## Parte 4 · Cierre

### 17 · Beneficios
**Imagen:** tres columnas que aparecen en orden: Equipos, Consumidores, Organización.

> En resumen, los beneficios. Para los equipos: publicar un stream deja de ser un trabajo manual y pasa a ser un archivo que la plataforma resuelve sola. Para los consumidores: cero llamadas de vuelta, ninguna espera artificial, y siguen operando aunque el productor se caiga. Para la organización: contratos versionados, cambios que rompen detenidos antes de llegar a producción, y reglas que se cumplen solas.

### 18 · Cierre
**Imagen:** frase final: «El equipo declara qué publica. La plataforma resuelve el cómo.»

> La idea de fondo es reducir la carga cognitiva de los desarrolladores: el equipo declara qué publica, y la plataforma resuelve el cómo. Como siguientes pasos, quedan probar la plantilla en Backstage y agregar autenticación y permisos al bus de eventos.

---

## Cómo generar la voz en ElevenLabs

1. **Modelo:** Multilingual v2, o v3 si lo tienes. Usa una voz en español con el acento que prefieras y la misma voz para todos los segmentos.
2. **Ajustes de partida:** estabilidad cerca de 50 % y similitud cerca de 75 %.
3. **Un audio por segmento:** pega cada bloque de `narracion-elevenlabs.txt` por separado y descárgalo como `01.mp3`, `02.mp3` … `18.mp3`. Así ajusto cada escena a la duración exacta de su audio, y si una frase suena mal regeneras solo esa.
4. **Dónde dejarlos:** en `docs/p2/video/voz/`, o avísame la ruta.

Si un término suena mal, cámbialo solo en el texto de ElevenLabs por una escritura fonética:

| Término | Si se pronuncia mal, escribir |
|---|---|
| Kyverno | Kaiverno |
| Argo CD | Argo si di |
| Apicurio | Apicurio (suele salir bien) |
| Strimzi | Strímsi |
| EventStreamClaim | Ivent Strim Cleim |
| Event-Carried State Transfer | Ivent Carried Steit Transfer |
| Avro | Avro (suele salir bien) |

---

## Cómo se arma el video (`render/`)

| Archivo | Qué hace |
|---|---|
| `render/animacion.html` | Animación de las partes 1, 2 y 4, y reproductor de la terminal grabada (parte 3). Tiene un reloj virtual: `seek(t)` dibuja el instante `t`, así cada cuadro es reproducible |
| `render/demo-rec/` | Sesión **real** de `demo.sh` grabada con `script` (salida y tiempos). Las esperas largas se aceleran en pantalla con un aviso «esperas reales acortadas ×N» |
| `render/build.py` | Mide cada audio de `voz/` y arma la línea de tiempo: cada escena dura lo que su audio |
| `render/capture.mjs` | Node de Windows + Chrome sin interfaz: captura los cuadros y los pasa a ffmpeg |
| `render/make_video.sh` | Orquesta todo: cuadros, mezcla de audio normalizada a −16 LUFS y montaje final en `video-p2.mp4` |

```bash
cd docs/p2/video/render
./make_video.sh                      # video completo (~10 min)
./make_video.sh stills 20,60,120     # capturas para revisar en build/stills/
# vista previa en el navegador (sin audio): abrir render/build/index.html#play
```

Si cambias un audio, solo vuelves a correr `./make_video.sh`: la línea de tiempo se recalcula sola. Para grabar de nuevo la demo:
`script -q -T render/demo-rec/timing -O render/demo-rec/raw -c "stty cols 110 rows 30; AUTO=2 docs/p2/video/demo.sh"` desde la raíz del repo.
