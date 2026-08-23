# 🌎 Alerta Sísmica Colombia

App gratuita y de código abierto de monitoreo sísmico en tiempo real, enfocada en **Villavicencio, Bogotá y el Piedemonte Llanero** — una de las zonas de mayor amenaza sísmica de Colombia (falla frontal de la Cordillera Oriental). Disponible como **PWA** (web instalable) y como **app nativa Flutter** (Android/iOS).

## Propósito

Colombia carece de herramientas ciudadanas, gratuitas y de fácil acceso para monitorear actividad sísmica en tiempo casi real y entender el riesgo en la ubicación de cada persona. Alerta Sísmica busca cerrar esa brecha usando datos sísmicos públicos y los sensores del propio teléfono.

Es un proyecto de **bien público, sin fines de lucro**: código abierto, sin costo de uso y sin recolección de datos personales más allá de lo estrictamente necesario para operar (ubicación aproximada, usada solo en el dispositivo).

**A quién sirve:**

- Habitantes de zonas de amenaza sísmica alta en Colombia que quieren saber qué tan expuestos están a un sismo reciente.
- Comunidades y líderes locales que necesitan una guía de supervivencia accesible en español.
- Desarrolladores o entidades (Defensa Civil, alcaldías, SGC) que quieran adaptar o reutilizar el proyecto, dado que es abierto.

## Funcionalidades

- 📡 **Radar sísmico**: visualización en vivo de los sismos alrededor del usuario (tú estás en el centro, norte arriba, anillos de distancia). Puntos con pulso = sismos de las últimas 3 horas. Toca un punto para ver detalles.
- 🚨 **Evaluación de riesgo**: calcula la intensidad estimada que cada sismo produjo en tu ubicación (atenuación magnitud/distancia) y muestra un semáforo: SIN PELIGRO / PRECAUCIÓN / PELIGRO.
- 📈 **Sismógrafo con el teléfono**: usa el acelerómetro (sensors_plus / DeviceMotion) para detectar vibración fuerte y sostenida — el mismo principio de la red de detección de Google en Android. Dispara alarma de pantalla completa, sirena y vibración.
- 🔔 **Notificaciones** cuando aparece un sismo nuevo relevante cerca de ti (los datos se refrescan cada 60 s).
- 🛟 **Guía de supervivencia**: antes / durante / después, con líneas de emergencia de Colombia (123, 132, 144).
- 📴 **Instalable**: PWA con "Añadir a pantalla de inicio" y app shell offline, o APK nativa para Android.
- 🗺️ **Mapa de fallas geológicas** y vigilancia en segundo plano (versión Flutter, `flutter_foreground_task`).

## Estructura del repositorio

```
alerta-sismica/
├── index.html, sw.js, manifest.json, servidor.js   # PWA original (prototipo web)
├── app_flutter/                                    # App Android (Flutter/Dart)
│   ├── lib/            # core, radar, detector, mapa, push, cliente del servidor
│   ├── lib/panel_main.dart   # panel municipal (Flutter Web, mismo lenguaje)
│   ├── assets/         # sirena, fallas geológicas, íconos
│   ├── android/        # proyecto Android
│   ├── test/           # pruebas (16)
│   ├── claves.ejemplo.env    # plantilla de credenciales (copiar a claves.env)
│   └── compilar.sh     # compila inyectando claves.env
└── server/                                         # Servidor (Cloudflare Workers + D1)
    ├── src/            # geo, fuentes, fcm, index (rutas y tarea programada)
    ├── schema.sql      # tablas
    ├── .dev.vars.ejemplo     # plantilla de secretos del servidor
    └── desplegar.sh    # publica todo en Cloudflare
```

Las tres piezas comparten la misma lógica: `app_flutter/lib/core.dart` define el
modelo, la paleta y las fórmulas (haversine, intensidad, zona FCM), y la app y el
panel lo importan. El servidor replica esas fórmulas en `server/src/geo.js`: si se
tocan en un lado hay que tocarlas en el otro, o el teléfono queda suscrito a una
zona a la que nadie publica.

## Fuente de datos

Tres catálogos públicos, combinados y deduplicados:

- **SGC** (Servicio Geológico Colombiano) — la fuente oficial del país. Publica solo soluciones revisadas por analista, con 30-60+ min de retraso.
- **USGS** (EE.UU.) — API FDSN pública, sin clave, cobertura global.
- **EMSC** (Europa) — la más rápida de las tres (1-7 min), la que sostiene el aviso temprano.
- El sistema de Alertas de Terremotos de **Google/Android no tiene API pública**; funciona a nivel del sistema operativo. Este proyecto replica el concepto con datos abiertos + sensores del dispositivo.
- Fuente oficial en Colombia: **Servicio Geológico Colombiano** (sgc.gov.co).

## Cómo ejecutar

### Versión web (PWA)

```powershell
cd alerta-sismica
python -m http.server 8080
# o: npx serve -p 8080
```

Abre `http://localhost:8080` (el GPS, los sensores y el service worker requieren `localhost` o HTTPS).

Para usarla en el celular, el GPS/acelerómetro/notificaciones requieren HTTPS: publica la carpeta en GitHub Pages o Netlify Drop, y en el celular abre la URL en Chrome → menú → "Añadir a pantalla de inicio".

### Versión Flutter (Android)

```bash
cd alerta-sismica/app_flutter
flutter pub get
flutter run                 # desarrollo, sin servidor ni push
```

Para compilar con servidor y notificaciones push hay que dar los valores del
despliegue propio. No están en el repositorio:

```bash
cp claves.ejemplo.env claves.env    # rellenar los valores
bash compilar.sh                    # APK de release
bash compilar.sh panel              # panel web
```

Con `claves.env` vacío la app **compila y funciona igual**, solo que sin servidor
ni push: consulta los catálogos por su cuenta, como siempre.

### Servidor

```bash
cd server
npx wrangler login          # una sola vez, abre el navegador
bash desplegar.sh           # crea la base, carga secretos y publica
```

Imprime al final la URL pública, que es la que va en `SERVIDOR_URL` de `claves.env`.
Detalles en [server/README.md](server/README.md).

## Credenciales: qué es secreto y qué no

**Nada de esto vive en el repositorio.** El historial se auditó y nunca ha
contenido una credencial.

| Archivo | Qué guarda | Riesgo si se filtra |
|---|---|---|
| `server/.dev.vars` | Clave privada de la cuenta de servicio de Firebase | **Grave.** Permite enviar notificaciones en nombre de la app: alertas de sismo falsas a todos los usuarios. |
| `app_flutter/claves.env` | URL del servidor y los 4 valores de Firebase | Bajo. Ver abajo. |
| `app_flutter/android/app/google-services.json` | Los mismos 4 valores | Bajo. |
| `*.jks`, `key.properties` | Firma de Android para Play Store | **Grave.** Quien la tenga puede publicar actualizaciones suplantando la app. |

Sobre los cuatro valores de Firebase, dicho con honestidad: **no son un secreto
criptográfico**. Viajan dentro de cualquier APK y quien descargue la app puede
extraerlos; Firebase los protege con las reglas del proyecto, no ocultándolos. Se
mantienen fuera del repositorio por higiene y para no invitar a que otros consuman
la cuota del proyecto, no porque filtrarlos comprometa las cuentas.

La que sí importa de verdad es la **cuenta de servicio**: con ella se pueden
disparar alertas falsas. Vive solo en `.dev.vars` (local) y como secreto cifrado
de Cloudflare (producción).

Si alguna vez se sube un secreto por error, quitarlo en un commit posterior **no
sirve**: queda en el historial. Hay que rotarlo en la consola que lo emitió.

## Limitaciones honestas

- No es alerta temprana real (eso requiere redes de sensores dedicadas y latencia de segundos); es monitoreo en tiempo casi real (USGS publica eventos típicamente en 1–10 min) + detección local por acelerómetro.
- En la versión web, las notificaciones llegan mientras la app/pestaña esté abierta o instalada como PWA; el navegador no permite monitoreo en segundo plano permanente como una app nativa (la versión Flutter sí lo permite vía servicio en primer plano).
- La intensidad sentida es una estimación simplificada; para información oficial consulta al SGC.

## Licencia

Proyecto de código abierto sin fines de lucro, bajo licencia [MIT](LICENSE). Uso libre para fines educativos y de seguridad ciudadana.
