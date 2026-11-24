# Guion del video · Proyecto 2 · Golden Path de eventos

Duración aproximada: **4 minutos y medio**. El video responde tres preguntas: qué se hizo, cómo se hizo y qué mejoró.

## Antes de grabar (5 min)

1. Abre Docker Desktop y espera a que arranque.
2. En WSL, revisa el entorno. Debe terminar en «Listo para grabar»:
   ```bash
   cd ~/maestria/plataformas/proyecto/parkglobal-platform-poc
   docs/p2/video/demo.sh preparar
   ```
3. Abre las láminas y presiona F11:
   ```bash
   explorer.exe "$(wslpath -w docs/p2/video/laminas.html)"
   ```
4. Pon la terminal en pantalla completa (F11) y sube la fuente con Ctrl y +. Necesita al menos 110 columnas y 30 filas.
   Lanza la demo y déjala en su portada:
   ```bash
   docs/p2/video/demo.sh
   ```
5. En OBS: fuente «Captura de pantalla», 1920×1080, micrófono activo. Haz una prueba de 10 segundos y escúchala.
6. Activa «No molestar» en Windows. Deja este guion en el celular o en otro monitor.
7. Empieza con la lámina 1 en pantalla. Cambias entre láminas y terminal con Alt+Tab, dos veces en todo el video.

Teclas: en las láminas, flecha derecha. En la terminal, Enter **una sola vez** cuando aparezca `[Enter]`.

---

## Qué se hizo

### 0:00 · Lámina 1 · Presentación

> Hola, soy Daniel. En la primera parte construimos un Golden Path para pedir bases de datos en autoservicio. En esta segunda parte extendí la plataforma con una nueva capacidad: publicar eventos de estado gobernados, también en autoservicio.

### 0:17 · Lámina 2 · El problema

> El diagnóstico de ParkGlobal mostró un Kafka sin contratos: cero esquemas registrados, un solo tópico compactado de veinte, y solo dos de cuarenta y dos servicios declaran sus eventos. Además, el evento de tarifas solo avisa que algo cambió. Eso obliga a hacer cuatro o más llamadas síncronas por cada cambio, después de una espera fija de cinco segundos.

## Cómo se hizo

### 0:45 · Lámina 3 · Arquitectura

> Reutilicé la plataforma de la primera parte. El equipo declara un EventStreamClaim, Kyverno lo valida y Crossplane lo convierte en tres cosas: un tópico compactado en Kafka con Strimzi, un contrato Avro en Apicurio y la configuración de cada equipo. Incluso la base de datos del registry se pidió con el Golden Path de la parte uno. Backstage y GitOps están implementados como código; hoy muestro el núcleo, corriendo en un clúster local.

**Alt+Tab a la terminal.**

### 1:15 · Enter → paso 1 · Autoservicio

Presiona Enter y empieza a hablar enseguida. Este paso tarda entre 4 y 36 segundos y los ✔ aparecen solos.

> Creo un stream nuevo en vivo. Esto es todo lo que escribe el desarrollador: dueño, dominio, entidad, clave, versión del contrato y consumidores. No elige particiones, retención, compatibilidad ni serializadores. La plataforma crea el tópico compactado, registra el contrato con compatibilidad total y transitiva, y le entrega la configuración al dueño y a cada consumidor. El claim solo queda Ready cuando la plataforma verifica todo eso.

### 1:50 · Enter → paso 2 · Guardrails

> El autoservicio necesita límites. Si Zonas intenta declarar un stream en el dominio de Tarifas, Kyverno lo rechaza y le explica por qué. Lo mismo si declara datos personales. Las reglas dejaron de depender de una revisión manual: son políticas como código.

## Qué mejoró

### 2:10 · Enter → paso 3 · ECST

> Ahora el caso de negocio. Tarifas cambia un precio y publica el estado completo de la zona. Zonas y el Consumidor C lo reciben en milisegundos y lo guardan en su copia local. El Consumidor C arma la jerarquía de ciudad, zonas y tarifa uniendo por referencia. Y pasamos de cuatro o más llamadas de vuelta a cero.

### 2:37 · Enter → paso 4 · Disponibilidad

> También mejora la disponibilidad. Apago Tarifas por completo, y los dos consumidores siguen respondiendo con el último precio y tomando decisiones, porque ya no dependen de que el productor esté arriba.

### 2:55 · Enter → paso 5 · Cambio incompatible

> ¿Qué pasa si un desarrollador borra el campo moneda? El chequeo que usa el CI, ejecutado aquí en local, falla y señala el campo exacto. Y si alguien se salta el CI y va directo al registry, recibe un error cuatrocientos nueve. La versión rota nunca se registra.

### 3:17 · Enter → paso 6 · Evolución

Este paso tarda unos 8 segundos.

> Gobernar no es congelar. Agrego un campo opcional con valor por defecto y la versión dos se registra en segundos. Un productor escribe con la versión dos: el consumidor nuevo ve el campo y el antiguo sigue leyendo sin cambios. Por esto elegí Avro: en las pruebas, JSON Schema con esta misma política rechazaba agregar campos opcionales en los modelos abierto y cerrado.

**Cuando termines de hablar, Alt+Tab a las láminas sin presionar Enter. Flecha derecha.**

### 3:50 · Lámina 4 · Antes y ahora

> En resumen: crear un stream pasó de ser manual a un claim que queda listo en menos de un minuto. El JSON sin versión pasó a ser un contrato registrado. Los cambios que rompen se detienen antes de llegar a los consumidores. Y desaparecen las llamadas de vuelta, la espera fija y la dependencia de que Tarifas esté disponible.

### 4:15 · Lámina 5 · Cierre

> La mejora de fondo es menos carga cognitiva extrínseca: el equipo aporta siete campos y su contrato, y la plataforma resuelve el cómo. Como siguientes pasos quedan probar el flujo GitOps de punta a punta y agregar autenticación y permisos al bus. Muchas gracias.

**Detén la grabación. Luego vuelve a la terminal y presiona Enter para restaurar el entorno.**

---

## Si algo sale mal

| Situación | Qué hacer |
|---|---|
| Un paso muestra ✘ | La demo restaura sola. Corre `demo.sh preparar` y vuelve a lanzarla |
| Quieres repetir la toma | Ctrl+C, espera «Entorno restaurado» y lanza la demo otra vez: cada toma crea un stream nuevo |
| Quieres ensayar sin teclado | `AUTO=20 docs/p2/video/demo.sh` |
| El paso 1 sigue esperando cuando terminaste de hablar | Haz una pausa, o corta la espera al editar |

## Qué no decir (no está demostrado)

- «El PR se integra solo» o «Argo CD lo despliega»: ese flujo no se ha ejecutado para la parte 2.
- «Queda listo en 4,5 segundos»: el claim tarda entre 4 y 36 segundos en quedar Ready.
- «Nadie puede escribir en un tópico ajeno»: Kyverno controla quién **declara** un stream. El bus de la PoC no tiene autenticación ni ACL.
- «Es imposible publicar un evento inválido»: el control está en el serializador y en el registry. Kafka no valida los mensajes.
- «Los números de la empresa mejoraron»: el «antes» viene del diagnóstico y el «ahora» se midió en la PoC.
