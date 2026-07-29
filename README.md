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
├── index.html, sw.js, manifest.json, servidor.js, icon.svg   # PWA (versión web)
└── app_flutter/                                              # App nativa (Flutter/Dart)
    ├── lib/            # Código fuente (core, radar, detector de sismos, mapa, servicios)
    ├── assets/         # Audio de sirena, datos de fallas geológicas, íconos
    ├── android/        # Proyecto Android
    └── test/           # Pruebas
```

Ambas versiones comparten la misma lógica de negocio (radar, riesgo, sismógrafo, alertas) — la PWA es el prototipo original en JavaScript y `app_flutter` es el puerto nativo con más capacidades (vigilancia en segundo plano, notificaciones nativas).

## Fuente de datos

- **USGS** (Servicio Geológico de EE.UU.) — API FDSN pública, gratuita, sin clave, cobertura global incluida Colombia: `earthquake.usgs.gov/fdsnws/event/1/query`.
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

### Versión Flutter (Android/iOS)

```powershell
cd alerta-sismica/app_flutter
flutter pub get
flutter run
```

## Limitaciones honestas

- No es alerta temprana real (eso requiere redes de sensores dedicadas y latencia de segundos); es monitoreo en tiempo casi real (USGS publica eventos típicamente en 1–10 min) + detección local por acelerómetro.
- En la versión web, las notificaciones llegan mientras la app/pestaña esté abierta o instalada como PWA; el navegador no permite monitoreo en segundo plano permanente como una app nativa (la versión Flutter sí lo permite vía servicio en primer plano).
- La intensidad sentida es una estimación simplificada; para información oficial consulta al SGC.

## Licencia

Proyecto de código abierto sin fines de lucro, bajo licencia [MIT](LICENSE). Uso libre para fines educativos y de seguridad ciudadana.
