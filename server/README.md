# Servidor de Alerta Sísmica CO

Backend de recolección, consenso y alertas. Corre sobre **Cloudflare Workers +
D1**, cuyo plan gratuito cubre de sobra un piloto municipal.

## Qué resuelve

| Problema de la app sola | Cómo lo resuelve el servidor |
|---|---|
| Cada teléfono bajaba ~13 MB/día de los catálogos | Un solo cliente los consulta para todos: el usuario baja < 1 MB/mes |
| 10.000 usuarios golpearían al SGC 1,4 millones de veces al día | El SGC recibe 144 peticiones diarias en total |
| Sin avisos si el usuario apaga la vigilancia 24/7 | Push por FCM aunque la app lleve meses cerrada |
| Un golpe a la mesa es indistinguible de un sismo | Consenso: varios teléfonos cercanos a la vez |
| Nada que mostrarle a una alcaldía | Endpoint `/v1/panel` con indicadores y bitácora de alertas |

## Costos

- **Envío por FCM: gratis**, sin límite de mensajes ni de dispositivos.
- **Cloudflare Workers (gratis):** 100.000 peticiones/día y 50 sub-peticiones
  por invocación. Por eso las alertas se agrupan de a 5 temas por condición:
  un sismo se despacha en ~8 peticiones, no en cientos.
- **D1 (gratis):** 5 GB y 5 millones de lecturas al día.
- No se guardan datos crudos del acelerómetro, solo eventos puntuales
  (~200 bytes), así que el almacenamiento no crece con el uso.

## Estructura

    src/geo.js       geometría, cuadrícula difusa e intensidad
    src/fuentes.js   consulta a SGC, USGS y EMSC
    src/fcm.js       envío por Firebase Cloud Messaging (HTTP v1)
    src/index.js     rutas HTTP y sondeo programado
    schema.sql       tablas de D1

### Privacidad (Ley 1581 de 2012)

Nunca se almacenan coordenadas exactas del usuario. Se guarda una **celda de
0,25°** (~28 km) para estadísticas, y el teléfono se suscribe a una **zona de
1°** (~111 km) que es el tema de FCM. El identificador es anónimo y aleatorio,
generado en el propio teléfono.

## Desarrollo local (sin cuenta ni tarjeta)

    npm install
    npm run db:local
    npm run dev

Pruebas rápidas:

    curl http://127.0.0.1:8787/v1/salud
    curl -X POST http://127.0.0.1:8787/v1/sondear
    curl "http://127.0.0.1:8787/v1/panel?lat=4.142&lon=-73.627&radio=350"

Sin credenciales de Firebase el servidor entra en **modo prueba**: hace todo el
flujo y reporta lo que habría enviado, sin enviar nada.

## Endpoints

| Método y ruta | Para qué |
|---|---|
| `GET /v1/salud` | Estado del servicio |
| `POST /v1/dispositivos` | Registra el teléfono y devuelve su tema FCM |
| `POST /v1/detecciones` | Recibe un disparo del sismógrafo y evalúa consenso |
| `GET /v1/sismos` | Lista de sismos (`lat`, `lon`, `radio`, `dias`) |
| `GET /v1/panel` | Indicadores para el tablero de la alcaldía |
| `POST /v1/simulacro` | Lanza un simulacro municipal (requiere `ADMIN_TOKEN`) |
| `POST /v1/sondear` | Fuerza el sondeo (pruebas y administración) |

## Puesta en producción

Todo está automatizado salvo el inicio de sesión, que abre el navegador y
por eso hay que hacerlo a mano una única vez:

    cd server
    npx wrangler login       # abre el navegador; autoriza y vuelve
    bash desplegar.sh        # crea la base, carga secretos y publica

El script imprime al final la URL pública. Con ella se recompila la app para
que los teléfonos se registren solos, sin que el usuario escriba nada:

    cd ../app_flutter
    MSYS_NO_PATHCONV=1 flutter build apk --release \
        --dart-define=SERVIDOR_URL=https://TU-URL.workers.dev

En Git Bash el prefijo `MSYS_NO_PATHCONV=1` es obligatorio: sin él convierte
las dobles barras de la URL en una ruta de Windows y la app queda sin
servidor, con un fallo silencioso y difícil de ver.

### Comprobaciones tras publicar

    curl https://TU-URL.workers.dev/v1/salud    # debe decir fcm: configurado
    https://TU-URL.workers.dev/panel/           # el tablero municipal

La tarea programada empieza a correr sola, cada minuto.

### Notificaciones push (ya configuradas)

El proyecto de Firebase es `alerta-sismica-17b25`. Los cuatro valores
públicos del cliente están en `app_flutter/lib/firebase_config.dart` (no son
secretos: viajan dentro de cualquier app Android). La credencial de la
cuenta de servicio vive solo en `.dev.vars` para desarrollo y como secreto
de Cloudflare en producción; nunca en el repositorio.

Cómo se despachan las alertas:

| Severidad | Envío | Por qué |
|---|---|---|
| **Fuerte** (M≥5) | Directo por token a los teléfonos más cercanos **y** por zonas | El directo llega en ~0,4 s; el de zonas da cobertura amplia |
| Informativa | Solo por zonas, con carga de notificación | Se muestra aunque la app no pueda ejecutarse |

Las alertas fuertes van **sin** carga de `notification` a propósito: si la
llevaran, Android dibujaría el aviso y no podría ser de pantalla completa.
Al enviar solo datos, la app construye la alerta que se apodera de la
pantalla, suena con volumen de alarma y aparece sobre el bloqueo.

### Límites del plan gratuito a tener presentes

- 50 peticiones salientes por invocación: de ahí el tope de envíos directos
  (`MAX_ENVIO_DIRECTO`, 40 por omisión). Los más cercanos al epicentro van
  primero, y el resto queda cubierto por el envío por zonas.
- El envío por FCM no se cobra, ni por mensaje ni por dispositivo.
- Cloudflare Workers no puede mantener una conexión WebSocket permanente
  hacia el EMSC; por eso se consulta cada minuto. Si algún día hiciera falta
  el tiempo real estricto, habría que mover esa pieza a un servidor propio.
