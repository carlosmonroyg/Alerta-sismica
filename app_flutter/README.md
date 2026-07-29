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
