// Vigilancia sísmica 24/7: foreground service que mantiene el acelerómetro
// procesando el detector STA/LTA aunque la pantalla esté apagada o la app
// cerrada. Muestra la notificación permanente obligatoria de Android con un
// consejo de prevención rotativo, y al detectar un evento dispara sirena,
// vibración y una notificación de pantalla completa.

import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vibration/vibration.dart';

import 'detector.dart';

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

/// Arranca la vigilancia. Devuelve true si el servicio quedó corriendo.
Future<bool> startSeismoWatch() async {
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
  final _detector = StaLtaDetector(sampleRate: 50);
  final _notifs = FlutterLocalNotificationsPlugin();
  AudioPlayer? _siren;
  Timer? _sirenTimer;
  DateTime _lastAlarm = DateTime.fromMillisecondsSinceEpoch(0);
  int _tipIdx = -1;
  int _sample = 0;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _notifs.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    _sub = userAccelerometerEventStream(
            samplingPeriod: const Duration(milliseconds: 20))
        .listen(_onMotion, onError: (_) {});
  }

  void _onMotion(UserAccelerometerEvent e) {
    final m = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final st = _detector.process(m);
    _sample++;
    // Estado hacia la UI (si está abierta), 1 vez por segundo.
    if (_sample % 50 == 0) {
      FlutterForegroundTask.sendDataToMain({
        'type': 'status',
        'sta': st.sta,
        'ratio': st.ratio,
        'ready': st.ready,
      });
    }
    if (st.triggered) _alarm(st);
  }

  Future<void> _alarm(DetectorStatus st) async {
    if (DateTime.now().difference(_lastAlarm).inSeconds < 60) return;
    _lastAlarm = DateTime.now();

    // Avisar a la UI por si la app está abierta (overlay rojo).
    FlutterForegroundTask.sendDataToMain({'type': 'alarm'});

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
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _sub?.cancel();
    _sirenTimer?.cancel();
    await _siren?.stop();
    await _siren?.dispose();
  }
}
