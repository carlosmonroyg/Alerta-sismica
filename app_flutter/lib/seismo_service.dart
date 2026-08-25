// Vigilancia sísmica 24/7: foreground service que mantiene el acelerómetro
// procesando el detector STA/LTA aunque la pantalla esté apagada o la app
// cerrada. Muestra la notificación permanente obligatoria de Android con un
// consejo de prevención rotativo, y al detectar un evento dispara sirena,
// vibración y una notificación de pantalla completa.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vibration/vibration.dart';

import 'core.dart';
import 'detector.dart';
import 'quake_notify.dart';
import 'servidor.dart';
import 'sources.dart';

// Claves de configuración compartidas con la app (ubicación y filtros del
// usuario) para que el servicio pueda consultar los catálogos por su cuenta.
const kCfgLat = 'w_lat';
const kCfgLon = 'w_lon';
const kCfgRadius = 'w_radius';
const kCfgMinMag = 'w_minmag';
const kCfgAnonId = 'w_anonid';
const kCfgServidor = 'w_servidor';

/// Guarda la configuración de vigilancia para el isolate del servicio.
Future<void> saveWatchConfig({
  required double lat,
  required double lon,
  required double radiusKm,
  required double minMag,
  String anonId = '',
  String servidorUrl = '',
}) async {
  try {
    await FlutterForegroundTask.saveData(key: kCfgLat, value: lat);
    await FlutterForegroundTask.saveData(key: kCfgLon, value: lon);
    await FlutterForegroundTask.saveData(key: kCfgRadius, value: radiusKm);
    await FlutterForegroundTask.saveData(key: kCfgMinMag, value: minMag);
    await FlutterForegroundTask.saveData(key: kCfgAnonId, value: anonId);
    await FlutterForegroundTask.saveData(key: kCfgServidor, value: servidorUrl);
  } catch (_) {}
}

const kConsejosDelDia = [
  '🎒 Ten lista tu mochila de emergencia: agua, linterna, pito y botiquín.',
  '🧎 Si tiembla: agáchate, cúbrete y sujétate. No corras a las escaleras.',
  '📍 Define hoy el punto de encuentro con tu familia.',
  '🔦 Guarda una linterna junto a la cama, no dependas del celular.',
  '🏠 Identifica las zonas seguras de tu casa: bajo mesas firmes, junto a columnas.',
  '📵 Tras un sismo usa mensajes de texto, no llamadas: la red se satura.',
  '🚪 Asegura a la pared los muebles altos y el calentador.',
  '☎️ Emergencias en Colombia: 123 · Cruz Roja 132 · Defensa Civil 144.',
];

/// Configura las opciones del servicio. Llamar una vez desde main().
void initSeismoServiceConfig() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'vigilancia_sismica',
      channelName: 'Vigilancia sísmica activa',
      channelDescription:
          'Notificación permanente del monitoreo sísmico en segundo plano',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(60000),
      autoRunOnBoot: true,
      allowWakeLock: true,
      allowWifiLock: false,
    ),
  );
}

/// Si el teléfono puede vigilar con la app cerrada.
///
/// SOLO ANDROID. Todo esto se apoya en un servicio en primer plano, un
/// concepto que iOS no tiene: allí el sistema suspende la app a los pocos
/// segundos de salir de ella, y no hay manera de dejar el acelerómetro
/// leyendo ni de sondear los catálogos. En iOS el único aviso que llega con
/// la app cerrada es el push, que lo entrega el sistema por APNs sin que la
/// app necesite estar viva.
///
/// Se comprueba con `defaultTargetPlatform` y no con `Platform.isAndroid`
/// porque `dart:io` no existe en la web, donde también se compila el panel.
bool get vigilanciaEnSegundoPlanoDisponible =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Arranca la vigilancia. Devuelve true si el servicio quedó corriendo.
Future<bool> startSeismoWatch() async {
  // En iOS no hay servicio que arrancar: mejor decirlo que fallar callando.
  if (!vigilanciaEnSegundoPlanoDisponible) return false;
  try {
    // Pedir al usuario excluir la app de la optimización de batería para
    // que Android no mate el servicio de madrugada.
    final ignoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!ignoring) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  } catch (_) {}
  await FlutterForegroundTask.startService(
    serviceId: 256,
    notificationTitle: '🌎 Vigilancia sísmica activa',
    notificationText: kConsejosDelDia[DateTime.now().hour % kConsejosDelDia.length],
    callback: startSeismoTaskCallback,
  );
  return FlutterForegroundTask.isRunningService;
}

Future<bool> stopSeismoWatch() async {
  await FlutterForegroundTask.stopService();
  return !(await FlutterForegroundTask.isRunningService);
}

@pragma('vm:entry-point')
void startSeismoTaskCallback() {
  FlutterForegroundTask.setTaskHandler(SeismoTaskHandler());
}

class SeismoTaskHandler extends TaskHandler {
  StreamSubscription<UserAccelerometerEvent>? _sub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  double _gyroMag = 0;
  final _detector = StaLtaDetector(sampleRate: 50);
  final _notifs = FlutterLocalNotificationsPlugin();
  AudioPlayer? _siren;
  Timer? _sirenTimer;
  DateTime _lastAlarm = DateTime.fromMillisecondsSinceEpoch(0);
  int _tipIdx = -1;
  int _sample = 0;

  // Sondeo de catálogos con la app cerrada.
  final Set<String> _knownIds = {};
  bool _firstPoll = true, _polling = false;
  int _cycle = 0;
  EmscLiveFeed? _live;
  double _lat = 0, _lon = 0, _radiusKm = 500, _minMag = 2.5;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _notifs.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    ));
    await crearCanalesDeSismo(_notifs);
    _sub = userAccelerometerEventStream(
            samplingPeriod: const Duration(milliseconds: 20))
        .listen(_onMotion, onError: (_) {});
    // El giroscopio distingue manipulación de onda sísmica: un teléfono sobre
    // una mesa se desplaza durante un sismo, pero apenas rota.
    _gyroSub = gyroscopeEventStream(
            samplingPeriod: const Duration(milliseconds: 40))
        .listen((e) {
      _gyroMag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    }, onError: (_) {});

    // Canal en tiempo real del EMSC: los sismos llegan empujados en segundos,
    // sin esperar al siguiente sondeo. Es lo que hace útil la app cerrada.
    _live = EmscLiveFeed(onEvent: _onLiveEvent)..start();
  }

  /// Sismo empujado por el WebSocket del EMSC (app cerrada).
  Future<void> _onLiveEvent(Map<String, dynamic> props) async {
    if (_lat == 0 && _lon == 0) return; // aún sin ubicación configurada
    final q = quakeFromEmscProps(props, _lat, _lon);
    if (q == null) return;
    if (!sismoPasaElFiltro(q, minMag: _minMag, radioKm: _radiusKm)) return;
    if (_knownIds.contains(q.id)) return;
    _knownIds.add(q.id);
    if (DateTime.now().difference(q.time).inMinutes > 90) return;
    try {
      if (await FlutterForegroundTask.isAppOnForeground) return;
    } catch (_) {}
    await showQuakeNotification(_notifs, q);
  }

  void _onMotion(UserAccelerometerEvent e) {
    final m = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final st = _detector.process(m, gyroMag: _gyroMag);
    _sample++;
    // Estado hacia la UI (si está abierta), ~1 vez por segundo.
    if (_sample % 50 == 0) {
      FlutterForegroundTask.sendDataToMain({
        'type': 'status',
        'sta': st.sta,
        'ratio': st.ratio,
        'ready': st.ready,
        'armed': st.armed,
        'still': st.stillSeconds,
        'rate': st.measuredRate,
      });
    }
    if (st.triggered) _alarm(st);
  }

  Future<void> _alarm(DetectorStatus st) async {
    if (DateTime.now().difference(_lastAlarm).inSeconds < 60) return;
    _lastAlarm = DateTime.now();

    // Avisar a la UI por si la app está abierta (overlay rojo).
    FlutterForegroundTask.sendDataToMain({'type': 'alarm'});

    // Aportar la detección al consenso comunitario: un golpe afecta a un
    // teléfono, un sismo a muchos a la vez.
    await _reportarDeteccion(st);

    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(
            pattern: [0, 400, 150, 400, 150, 800, 150, 400, 150, 800]);
      }
    } catch (_) {}

    try {
      _siren ??= AudioPlayer();
      await _siren!.setReleaseMode(ReleaseMode.loop);
      await _siren!.play(AssetSource('audio/sirena.wav'), volume: 1);
      _sirenTimer?.cancel();
      _sirenTimer = Timer(const Duration(seconds: 20), () => _siren?.stop());
    } catch (_) {}

    await _notifs.show(
      1,
      '🚨 ¡VIBRACIÓN FUERTE DETECTADA!',
      'El sismógrafo registró movimiento sostenido compatible con un sismo. '
          'Agáchate, cúbrete y sujétate.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'alarma_sismica',
          'Alarma sísmica',
          channelDescription: 'Alarma al detectar vibración fuerte sostenida',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          fullScreenIntent: true,
        ),
      ),
    );
  }

  Future<void> _reportarDeteccion(DetectorStatus st) async {
    try {
      final url =
          await FlutterForegroundTask.getData<String>(key: kCfgServidor) ?? '';
      final anon =
          await FlutterForegroundTask.getData<String>(key: kCfgAnonId) ?? '';
      if (url.isEmpty || anon.isEmpty || (_lat == 0 && _lon == 0)) return;
      Servidor.baseUrl = url;
      await Servidor.enviarDeteccion(
        anonId: anon,
        lat: _lat,
        lon: _lon,
        intensidad: st.sta,
      );
    } catch (_) {}
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Rotar el consejo de prevención en la notificación permanente.
    final idx = DateTime.now().hour % kConsejosDelDia.length;
    if (idx != _tipIdx) {
      _tipIdx = idx;
      FlutterForegroundTask.updateService(
        notificationTitle: '🌎 Vigilancia sísmica activa',
        notificationText: kConsejosDelDia[idx],
      );
    }
    // Consultar los catálogos aunque la app esté cerrada: así el usuario
    // recibe el aviso en la barra de estado sin tener que abrirla.
    _pollCatalogs();
  }

  Future<void> _pollCatalogs() async {
    if (_polling) return;
    _polling = true;
    try {
      final lat = await FlutterForegroundTask.getData<double>(key: kCfgLat);
      final lon = await FlutterForegroundTask.getData<double>(key: kCfgLon);
      if (lat == null || lon == null) return; // sin ubicación aún
      final radiusKm =
          await FlutterForegroundTask.getData<double>(key: kCfgRadius) ?? 500;
      final minMag =
          await FlutterForegroundTask.getData<double>(key: kCfgMinMag) ?? 2.5;
      _lat = lat;
      _lon = lon;
      _radiusKm = radiusKm;
      _minMag = minMag;

      // Frecuencia por fuente según su retraso real de publicación (medido):
      // EMSC ~9 min y además llega por WebSocket, USGS ~18 min, SGC ~30-60 min
      // (solo publica soluciones revisadas por un analista). Consultarlas cada
      // minuto no adelantaría nada y gastaría datos del usuario.
      final fuentes = <String>{};
      if (_firstPoll || _cycle % 2 == 0) fuentes.add('USGS'); //  ~2 min
      if (_firstPoll || _cycle % 10 == 0) fuentes.add('SGC'); // ~10 min
      if (_firstPoll || _cycle % 15 == 0) fuentes.add('EMSC'); // respaldo del WS
      _cycle++;
      if (fuentes.isEmpty) return;

      final res = await fetchAllSources(
        lat: lat,
        lon: lon,
        radiusKm: radiusKm,
        minMag: minMag,
        sgcMaxPages: 1, // los eventos nuevos van al inicio de la página 1
        only: fuentes,
        // Para alertar solo importan las últimas horas, no el historial.
        window: const Duration(hours: 3),
      );
      if (res.sourcesOk.isEmpty) return;

      // Si la app está abierta, ella misma avisa: evitar el aviso duplicado.
      var appVisible = false;
      try {
        appVisible = await FlutterForegroundTask.isAppOnForeground;
      } catch (_) {}

      for (final q in res.quakes) {
        if (_knownIds.contains(q.id)) continue;
        _knownIds.add(q.id);
        if (_firstPoll) continue; // la primera pasada solo memoriza
        // El mismo criterio que aplica la app abierta, para que el ajuste
        // signifique lo mismo esté la app en pantalla o cerrada.
        if (!sismoPasaElFiltro(q, minMag: minMag, radioKm: radiusKm)) continue;
        if (DateTime.now().difference(q.time).inMinutes > 90) continue;
        if (appVisible) continue;
        await showQuakeNotification(_notifs, q);
      }
      if (_knownIds.length > 400) {
        _knownIds.removeAll(_knownIds.take(_knownIds.length - 400).toList());
      }
      _firstPoll = false;
    } catch (_) {
      // Sin red o catálogos caídos: se reintenta en el siguiente ciclo.
    } finally {
      _polling = false;
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    _live?.stop();
    await _sub?.cancel();
    await _gyroSub?.cancel();
    _sirenTimer?.cancel();
    await _siren?.stop();
    await _siren?.dispose();
  }
}
