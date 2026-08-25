# Alerta Sísmica Colombia — App Flutter

Versión nativa (Android/iOS) de [Alerta Sísmica Colombia](../README.md): radar sísmico, evaluación de riesgo, sismógrafo con acelerómetro, notificaciones y guía de supervivencia. Ver el README principal del proyecto para propósito, funcionalidades y fuentes de datos completas.

## Requisitos

- Flutter SDK (`^3.12.2` — ver `pubspec.yaml`)
- Android Studio / SDK para compilar en Android

## Ejecutar en desarrollo

```powershell
flutter pub get
flutter run
```

## Generar APK

```powershell
flutter build apk --release
```

## Estructura de `lib/`

- `main.dart` — punto de entrada y pantalla principal
- `core.dart` — modelos y lógica compartida (cálculo de riesgo, colores, tema)
- `seismo_service.dart` — consumo de la API USGS
- `detector.dart` — sismógrafo por acelerómetro
- `map_view.dart` — radar/mapa de sismos
- `sources.dart` — fuentes de datos y fallas geológicas
- `quake_notify.dart` — canales y avisos en la barra de estado
- `push.dart` — notificaciones push (FCM), incluido el isolate de segundo plano

## iOS

El proyecto iOS existe (`ios/`) y el código Dart ya está adaptado, pero **iOS
no es Android con otro icono**: el sistema impone límites que cambian lo que la
app puede prometer.

| Función | Android | iOS |
|---|---|---|
| Sismógrafo con la app cerrada | Servicio en primer plano, 24/7 | **No existe.** iOS suspende la app a los segundos. Solo con la app abierta. |
| Sondeo de catálogos en segundo plano | Cada 2 min | **No fiable.** `BGAppRefreshTask` corre cuando el sistema quiere. |
| Aviso con la app cerrada | Push + servicio propio | **Solo push (APNs).** Es el único camino. |
| Alerta que se apodera de la pantalla | `fullScreenIntent` | No existe. Se usa `timeSensitive`, que atraviesa los modos de concentración. |
| Sonar con el teléfono en silencio | Canal con sonido de alarma | Requiere el permiso *Critical Alerts*, que Apple concede caso por caso. |

Por eso en iOS el interruptor de «Vigilancia 24/7» aparece deshabilitado y con
una explicación, en vez de ofrecer algo que el sistema no va a cumplir.

### Qué falta para compilarlo

Nada de esto se puede hacer desde Windows: **Apple solo permite compilar y
firmar desde macOS con Xcode** (o un runner macOS en la nube).

1. **Mac con Xcode** — `flutter build ipa` o `flutter run -d <iphone>`.
2. **Cuenta de Apple Developer** (99 USD/año) para firmar y para la clave APNs.
3. **App iOS en Firebase**, registrada con el bundle `co.alertasismica.alertaSismica`
   — distinto del de Android (`co.alertasismica.alerta_sismica`), porque iOS no
   admite guiones bajos. Descarga `GoogleService-Info.plist` a `ios/Runner/` y
   **no lo subas al repositorio**, igual que `google-services.json`.
4. **Clave APNs** (`.p8`) cargada en Firebase → Cloud Messaging. Sin ella el
   push no llega a ningún iPhone, y sin push iOS se queda sin avisos.
5. En Xcode, capacidades **Push Notifications** y **Time Sensitive Notifications**.

## Cómo se decide qué se notifica

Un sismo llega por cuatro caminos —la lista de catálogos, el WebSocket del
EMSC, el servicio en segundo plano y el push del servidor— y los cuatro pasan
por `sismoPasaElFiltro()` (`core.dart`), que aplica el radio y la magnitud
mínima que el usuario eligió en Ajustes. Un sismo que puede sentirse con
fuerza (intensidad ≥ 4.5 o `emergencia=1` del servidor) se salta el filtro: en
ese punto deja de ser información y pasa a ser seguridad.

El servidor difunde a ZONAS de ~111 km, dentro de las cuales conviven usuarios
con ajustes distintos, así que **el filtro final siempre lo aplica el
teléfono**. Por eso los avisos de sismo se mandan como mensaje de solo datos:
si llevaran carga de `notification`, Android los dibujaría antes de que la app
pudiera descartarlos.

Hay tres canales de notificación, y la importancia de cada uno se fija al
crearlo (Android ignora cambios posteriores, de ahí que sean tres y no uno):

| Canal | Cuándo | Comportamiento |
|---|---|---|
| `sismos_lejanos` | imperceptible en tu ubicación | en la cortina, sin sonido |
| `sismos_sentidos` | intensidad ≥ 2.5 | suena y asoma en pantalla |
| `alerta_sismo_emergencia` | intensidad ≥ 4.5 | pantalla completa, sonido de alarma |
