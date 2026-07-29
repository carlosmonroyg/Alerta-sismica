// Alerta Sísmica Colombia — versión Flutter
// Port de la PWA: radar sísmico, evaluación de riesgo, sismógrafo con
// acelerómetro, notificaciones locales y guía de supervivencia.
// Datos: USGS FDSN (earthquake.usgs.gov), actualizados cada 60 s.

import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

import 'core.dart';
import 'detector.dart';
import 'map_view.dart';
import 'seismo_service.dart';
import 'sources.dart';

export 'core.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const AlertaSismicaApp());
}

// ---------------- App ----------------
class AlertaSismicaApp extends StatelessWidget {
  const AlertaSismicaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Alerta Sísmica CO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          surface: kPanel,
          onSurface: kText,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Estado principal (equivalente a S en la PWA)
  double lat = 4.7110, lon = -74.0721;
  String cityName = 'Bogotá';
  int cityIdx = 0;
  double radiusKm = 500, minMag = 2.5;
  List<Quake> quakes = [];
  String? selectedQuakeId;
  final Set<String> knownIds = {};
  bool firstLoad = true;
  RiskLevel risk = RiskLevel.safe;
  Quake? riskHeadline;
  bool online = true;
  String statusText = 'Conectando con USGS…';
  int tab = 0;

  // Alerta a pantalla completa
  bool alertActive = false;
  bool alertIsDrill = false;
  String alertTitle = '', alertMsg = '';

  // Sirena
  final _sirenPlayer = AudioPlayer();
  Timer? _sirenTimer;

  // Vigilancia 24/7 (foreground service)
  bool bgWatchOn = false;
  final serviceStatus = ValueNotifier<String>('');

  // Simulacro
  DateTime? _drillStart;
  int drillCountdown = 0;
  double? drillLast, drillBest;

  // Preferencias e identidad anónima
  SharedPreferences? _prefs;
  String anonId = '…';

  Timer? _pollTimer;
  final _notifs = FlutterLocalNotificationsPlugin();
  bool _notifsReady = false;

  // WebSocket EMSC (sismos empujados en tiempo real)
  late final EmscLiveFeed _emscFeed = EmscLiveFeed(
    onEvent: _onEmscLiveEvent,
    onStateChange: (_) {
      if (mounted) setState(() {});
    },
  );

  @override
  void initState() {
    super.initState();
    initSeismoServiceConfig();
    FlutterForegroundTask.addTaskDataCallback(_onServiceData);
    _initNotifications();
    _loadPrefs().then((_) => _fetchQuakes());
    _initLocation();
    _refreshBgWatchState();
    _emscFeed.start();
    _pollTimer = Timer.periodic(const Duration(seconds: 60), (_) => _fetchQuakes());
  }

  // ---------------- Preferencias / ID anónimo ----------------
  Future<void> _loadPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    var id = _prefs!.getString('anon_id');
    if (id == null) {
      final rnd = math.Random.secure();
      id = List.generate(16, (_) => rnd.nextInt(16).toRadixString(16)).join();
      await _prefs!.setString('anon_id', id);
    }
    if (!mounted) return;
    setState(() {
      anonId = id!;
      radiusKm = _prefs!.getDouble('radius_km') ?? radiusKm;
      minMag = _prefs!.getDouble('min_mag') ?? minMag;
      drillLast = _prefs!.getDouble('drill_last');
      drillBest = _prefs!.getDouble('drill_best');
    });
  }

  // ---------------- Vigilancia 24/7 ----------------
  Future<void> _refreshBgWatchState() async {
    final running = await FlutterForegroundTask.isRunningService;
    if (mounted) setState(() => bgWatchOn = running);
  }

  Future<void> _toggleBgWatch(bool value) async {
    if (value) {
      final ok = await startSeismoWatch();
      if (!ok) _toast('No se pudo iniciar la vigilancia en segundo plano');
    } else {
      await stopSeismoWatch();
      serviceStatus.value = '';
    }
    _refreshBgWatchState();
  }

  void _onServiceData(Object data) {
    if (data is! Map) return;
    switch (data['type']) {
      case 'status':
        final sta = (data['sta'] as num?)?.toDouble() ?? 0;
        final ratio = (data['ratio'] as num?)?.toDouble() ?? 0;
        final ready = data['ready'] == true;
        serviceStatus.value = ready
            ? 'Vigilando · vibración ${sta.toStringAsFixed(3)} m/s² · STA/LTA ${ratio.toStringAsFixed(1)}'
            : 'Calibrando ruido de fondo…';
      case 'alarm':
        _fireAlert('¡VIBRACIÓN FUERTE DETECTADA!',
            'El sismógrafo en segundo plano registró un movimiento sostenido compatible con un sismo. Protégete AHORA.');
    }
  }

  // ---------------- Simulacro ----------------
  Future<void> _startDrill() async {
    if (drillCountdown > 0 || alertActive) return;
    for (var i = 5; i >= 1; i--) {
      if (!mounted) return;
      setState(() => drillCountdown = i);
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return;
    setState(() => drillCountdown = 0);
    _drillStart = DateTime.now();
    _fireAlert(
      'SIMULACRO DE SISMO',
      'Esto es una práctica. Reacciona como si fuera real: agáchate, cúbrete y sujétate. '
          'Cuando estés en posición segura, pulsa "Estoy a salvo".',
      drill: true,
    );
  }

  void _finishDrill() {
    if (_drillStart == null) return;
    final secs =
        DateTime.now().difference(_drillStart!).inMilliseconds / 1000.0;
    _drillStart = null;
    setState(() {
      drillLast = secs;
      if (drillBest == null || secs < drillBest!) drillBest = secs;
    });
    _prefs?.setDouble('drill_last', secs);
    _prefs?.setDouble('drill_best', drillBest!);
    _toast('🎓 Simulacro completado en ${secs.toStringAsFixed(1)} s');
  }

  // ---------------- Sirena ----------------
  Future<void> _playSiren() async {
    try {
      await _sirenPlayer.setReleaseMode(ReleaseMode.loop);
      await _sirenPlayer.play(AssetSource('audio/sirena.wav'), volume: 1);
      _sirenTimer?.cancel();
      _sirenTimer =
          Timer(const Duration(seconds: 20), () => _sirenPlayer.stop());
    } catch (_) {}
  }

  void _stopSiren() {
    _sirenTimer?.cancel();
    _sirenPlayer.stop();
  }

  /// Nombre de la ciudad/pueblo donde está el usuario (geocodificación
  /// inversa nativa de Android). Si falla, devuelve un genérico.
  Future<String> _placeName(double la, double lo) async {
    try {
      final marks = await placemarkFromCoordinates(la, lo);
      if (marks.isNotEmpty) {
        final m = marks.first;
        for (final candidate in [
          m.locality,
          m.subAdministrativeArea,
          m.administrativeArea
        ]) {
          if (candidate != null && candidate.trim().isNotEmpty) {
            return candidate.trim();
          }
        }
      }
    } catch (_) {}
    return 'tu ubicación';
  }

  /// Detecta la ubicación GPS del dispositivo al arrancar y recarga los
  /// sismos alrededor de ella. Si no hay permiso o GPS, se queda en Bogotá.
  Future<void> _initLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      // Última posición conocida primero (instantánea), luego la precisa.
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && mounted) {
        final name = await _placeName(last.latitude, last.longitude);
        if (!mounted) return;
        setState(() {
          lat = last.latitude;
          lon = last.longitude;
          cityName = name;
          cityIdx = 2;
        });
        _reload();
      }
      final p = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.medium));
      if (!mounted) return;
      final name = await _placeName(p.latitude, p.longitude);
      if (!mounted) return;
      setState(() {
        lat = p.latitude;
        lon = p.longitude;
        cityName = name;
        cityIdx = 2;
      });
      _reload();
      _toast('📍 Estás en $name');
    } catch (_) {
      // Sin GPS: seguimos con la ciudad por defecto.
    }
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onServiceData);
    _emscFeed.stop();
    _pollTimer?.cancel();
    _sirenTimer?.cancel();
    _sirenPlayer.dispose();
    super.dispose();
  }

  Future<void> _initNotifications() async {
    const init = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _notifs.initialize(init);
    final android = _notifs.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission();
    _notifsReady = granted ?? false;
  }

  Future<void> _notify(String title, String body) async {
    if (!_notifsReady) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'sismos', 'Alertas sísmicas',
        channelDescription: 'Avisos de sismos nuevos cerca de ti',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    await _notifs.show(
        DateTime.now().millisecondsSinceEpoch % 100000, title, body, details);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: kPanel2,
        duration: const Duration(seconds: 3),
      ));
  }

  // ---------------- Datos SGC + USGS + EMSC ----------------
  Future<void> _fetchQuakes() async {
    final res = await fetchAllSources(
        lat: lat, lon: lon, radiusKm: radiusKm, minMag: minMag);
    if (!mounted) return;
    if (res.sourcesOk.isEmpty) {
      setState(() {
        online = false;
        statusText = 'Sin conexión con los catálogos — reintentando…';
      });
      return;
    }
    setState(() {
      quakes = res.quakes;
      online = true;
      final now = TimeOfDay.now();
      final hh = now.hour.toString().padLeft(2, '0');
      final mm = now.minute.toString().padLeft(2, '0');
      final live = _emscFeed.connected ? ' ⚡' : '';
      statusText =
          'En vivo · ${quakes.length} sismos · ${res.sourcesOk.join("+")}$live · $hh:$mm';
    });
    _detectNewQuakes();
    _assessRisk();
  }

  /// Evento nuevo empujado por el WebSocket de EMSC (llega en segundos).
  void _onEmscLiveEvent(Map<String, dynamic> props) {
    final q = quakeFromEmscProps(props, lat, lon);
    if (q == null || q.dist > radiusKm || q.mag < minMag) return;
    if (!mounted) return;
    // Evitar duplicar un evento que ya está listado por SGC/USGS.
    final dup = quakes.any((x) =>
        x.id != q.id &&
        x.time.difference(q.time).abs().inSeconds < 120 &&
        haversineKm(x.lat, x.lon, q.lat, q.lon) < 60);
    if (dup) return;
    setState(() {
      quakes
        ..removeWhere((x) => x.id == q.id)
        ..insert(0, q)
        ..sort((a, b) => b.time.compareTo(a.time));
    });
    _detectNewQuakes();
    _assessRisk();
  }

  void _detectNewQuakes() {
    for (final q in quakes) {
      if (knownIds.contains(q.id)) continue;
      knownIds.add(q.id);
      if (firstLoad) continue;
      final ageMin = DateTime.now().difference(q.time).inMinutes;
      if (ageMin > 90) continue; // solo eventos realmente frescos
      if (q.felt >= 4.5 || (q.mag >= 5 && q.dist < 300)) {
        _fireAlert(
          'Sismo M${q.mag.toStringAsFixed(1)} — ${q.place}',
          'A ${q.dist.round()} km de ti, ${timeAgo(q.time)}. Podrías sentirlo o recibir réplicas.',
        );
      } else if (q.felt >= 2.5) {
        _notify('Sismo M${q.mag.toStringAsFixed(1)} cerca de ti',
            '${q.place} · a ${q.dist.round()} km · ${timeAgo(q.time)}');
        _toast('🌐 Nuevo sismo M${q.mag.toStringAsFixed(1)} a ${q.dist.round()} km');
      }
    }
    firstLoad = false;
  }

  void _assessRisk() {
    final now = DateTime.now();
    var newRisk = RiskLevel.safe;
    Quake? headline;
    for (final q in quakes) {
      final ageH = now.difference(q.time).inMinutes / 60.0;
      if (ageH < 6 && q.felt >= 4.5) {
        newRisk = RiskLevel.danger;
        headline = q;
        break;
      }
      if (ageH < 24 && (q.felt >= 3 || (q.mag >= 4.5 && q.dist < 200))) {
        if (newRisk != RiskLevel.danger) {
          newRisk = RiskLevel.watch;
          headline ??= q;
        }
      }
    }
    setState(() {
      risk = newRisk;
      riskHeadline = headline;
    });
  }

  // ---------------- Alertas ----------------
  Future<void> _fireAlert(String title, String msg, {bool drill = false}) async {
    if (alertActive) return;
    setState(() {
      alertActive = true;
      alertIsDrill = drill;
      alertTitle = title;
      alertMsg = msg;
    });
    if (!drill) _notify('🚨 $title', msg);
    _playSiren();
    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(
            pattern: [0, 400, 150, 400, 150, 800, 150, 400, 150, 800]);
      }
    } catch (_) {}
  }

  // ---------------- Ciudad / GPS ----------------
  Future<void> _cycleCity() async {
    cityIdx = (cityIdx + 1) % cities.length;
    final c = cities[cityIdx];
    if (c.gps) {
      _toast('Obteniendo ubicación GPS…');
      try {
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) {
          perm = await Geolocator.requestPermission();
        }
        if (perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) {
          _toast('Permiso de ubicación denegado');
          return;
        }
        final p = await Geolocator.getCurrentPosition(
            locationSettings:
                const LocationSettings(accuracy: LocationAccuracy.medium));
        final name = await _placeName(p.latitude, p.longitude);
        if (!mounted) return;
        setState(() {
          lat = p.latitude;
          lon = p.longitude;
          cityName = name;
        });
        _toast('📍 Estás en $name');
        _reload();
      } catch (_) {
        _toast('No se pudo obtener el GPS');
      }
    } else {
      setState(() {
        lat = c.lat!;
        lon = c.lon!;
        cityName = c.name;
      });
      _reload();
    }
  }

  void _reload() {
    firstLoad = true;
    knownIds.clear();
    setState(() => statusText = 'Actualizando…');
    _fetchQuakes();
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(children: [
          Column(children: [
            // En la pestaña Mapa (índice 1) el mapa ocupa toda la pantalla.
            if (tab != 1) _header(),
            if (tab != 1) _riskCard(),
            Expanded(
              child: IndexedStack(index: tab, children: [
                RadarView(
                  quakes: quakes,
                  radiusKm: radiusKm,
                  selectedId: selectedQuakeId,
                  onSelect: (id) => setState(() => selectedQuakeId = id),
                ),
                QuakeMapView(
                  quakes: quakes,
                  lat: lat,
                  lon: lon,
                  radiusKm: radiusKm,
                  selectedId: selectedQuakeId,
                  onSelect: (id) => setState(() => selectedQuakeId = id),
                ),
                _quakeList(),
                SeismoView(
                  bgWatchOn: bgWatchOn,
                  onToggleBgWatch: _toggleBgWatch,
                  serviceStatus: serviceStatus,
                  onQuakeDetected: () {
                    _fireAlert('¡VIBRACIÓN FUERTE DETECTADA!',
                        'El acelerómetro de tu teléfono registró un movimiento sostenido compatible con un sismo. Protégete AHORA.');
                  },
                ),
                _guide(),
              ]),
            ),
          ]),
          if (alertActive) _alertOverlay(),
        ]),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: tab,
        onTap: (i) => setState(() => tab = i),
        type: BottomNavigationBarType.fixed,
        backgroundColor: kPanel,
        selectedItemColor: kAccent,
        unselectedItemColor: kMuted,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.radar), label: 'Radar'),
          BottomNavigationBarItem(icon: Icon(Icons.map_outlined), label: 'Mapa'),
          BottomNavigationBarItem(icon: Icon(Icons.list_alt), label: 'Sismos'),
          BottomNavigationBarItem(icon: Icon(Icons.show_chart), label: 'Sensor'),
          BottomNavigationBarItem(icon: Icon(Icons.health_and_safety), label: 'Guía'),
        ],
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: const LinearGradient(
                colors: [Color(0xFF0EA5E9), Color(0xFF6366F1)]),
          ),
          child: const Center(child: Text('🌎', style: TextStyle(fontSize: 20))),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Alerta Sísmica CO',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            Row(children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: online ? kSafe : kDanger),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(statusText,
                    style: const TextStyle(fontSize: 11, color: kMuted),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
          ]),
        ),
        TextButton(
          onPressed: _cycleCity,
          style: TextButton.styleFrom(
            backgroundColor: kPanel2,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: kLine)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          child: Text('📍 $cityName',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: kText)),
        ),
      ]),
    );
  }

  Widget _riskCard() {
    final String icon, title, detail;
    final Color color;
    switch (risk) {
      case RiskLevel.danger:
        icon = '🚨';
        title = 'PELIGRO — ACTIVIDAD FUERTE CERCANA';
        detail =
            'M${riskHeadline!.mag.toStringAsFixed(1)} ${riskHeadline!.place}, a ${riskHeadline!.dist.round()} km, ${timeAgo(riskHeadline!.time)}. Atento a réplicas: revisa la pestaña Guía.';
        color = kDanger;
      case RiskLevel.watch:
        icon = '⚠️';
        title = 'PRECAUCIÓN — ACTIVIDAD RECIENTE';
        detail =
            'M${riskHeadline!.mag.toStringAsFixed(1)} ${riskHeadline!.place}, a ${riskHeadline!.dist.round()} km, ${timeAgo(riskHeadline!.time)}. Sin peligro inminente, mantente informado.';
        color = kWatch;
      case RiskLevel.safe:
        icon = '🛡️';
        title = 'SIN PELIGRO INMINENTE';
        detail = quakes.isEmpty
            ? 'Sin sismos registrados en ${radiusKm.round()} km esta semana cerca de $cityName.'
            : 'Actividad normal: ${quakes.length} sismo${quakes.length > 1 ? 's' : ''} leves en ${radiusKm.round()} km esta semana. Ninguno representa riesgo para $cityName.';
        color = kSafe;
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: kPanel,
        border: Border.all(color: color.withValues(alpha: .5)),
        gradient: LinearGradient(colors: [color.withValues(alpha: .14), kPanel]),
      ),
      child: Row(children: [
        Text(icon, style: const TextStyle(fontSize: 30)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(detail,
                style: const TextStyle(fontSize: 12, color: kMuted, height: 1.35)),
          ]),
        ),
      ]),
    );
  }

  Widget _quakeList() {
    if (quakes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '🌿 Sin sismos de M≥$minMag en ${radiusKm.round()} km durante los últimos 7 días.\n¡Buenas noticias!',
            textAlign: TextAlign.center,
            style: const TextStyle(color: kMuted, height: 1.5),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: quakes.length,
      itemBuilder: (_, i) {
        final q = quakes[i];
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: kPanel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kLine),
          ),
          child: ListTile(
            onTap: () => setState(() {
              selectedQuakeId = q.id;
              tab = 0;
            }),
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                  color: magColor(q.mag), borderRadius: BorderRadius.circular(12)),
              child: Center(
                child: Text(q.mag.toStringAsFixed(1),
                    style: const TextStyle(
                        color: Color(0xFF0B1120), fontWeight: FontWeight.w800)),
              ),
            ),
            title: Text(q.place, style: const TextStyle(fontSize: 13.5)),
            subtitle: Text(
                '${timeAgo(q.time)} · prof. ${q.depth.round()} km · ${q.source}',
                style: const TextStyle(fontSize: 11.5, color: kMuted)),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text('${q.dist.round()}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const Text('km', style: TextStyle(fontSize: 10, color: kMuted)),
            ]),
          ),
        );
      },
    );
  }

  Widget _guide() {
    Widget card(String title, List<String> items) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: kPanel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kLine),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final it in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('• ', style: TextStyle(color: kAccent)),
                  Expanded(
                      child: Text(it,
                          style: const TextStyle(
                              fontSize: 12.5, color: kText, height: 1.4))),
                ]),
              ),
          ]),
        );

    return ListView(padding: const EdgeInsets.symmetric(horizontal: 16), children: [
      Container(
        margin: const EdgeInsets.only(bottom: 10, top: 4),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(colors: [kAccent.withValues(alpha: .15), kPanel]),
          border: Border.all(color: kAccent.withValues(alpha: .4)),
        ),
        child: const Column(children: [
          Text('Si la tierra tiembla, recuerda:', style: TextStyle(fontSize: 13)),
          SizedBox(height: 6),
          Text('🧎 AGÁCHATE · 🛡️ CÚBRETE · ✊ SUJÉTATE',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          SizedBox(height: 6),
          Text('La mayoría de las lesiones ocurren por objetos que caen, no por el derrumbe.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: kMuted)),
        ]),
      ),
      card('🎒 ANTES — prepárate hoy', [
        'Arma un kit de emergencia: agua (3 días), linterna, pito, radio, botiquín, copia de documentos, pila externa.',
        'Define con tu familia un punto de encuentro y un contacto fuera de la ciudad.',
        'Identifica en casa las zonas seguras (bajo mesas firmes, junto a columnas) y las peligrosas (ventanas, estantes, fachadas).',
        'Asegura a la pared muebles altos y el calentador de agua.',
      ]),
      card('⚡ DURANTE — los primeros 60 segundos', [
        'Adentro: agáchate, cúbrete bajo una mesa firme y sujétate. NO corras a las escaleras ni uses el ascensor.',
        'Afuera: aléjate de edificios, postes, cables y vidrios. Zonas abiertas.',
        'En carro: detente en un lugar seguro, lejos de puentes y taludes (clave en la vía Bogotá–Villavicencio).',
        'Si estás en zona de ladera, atento a deslizamientos después del sismo.',
      ]),
      card('🩹 DESPUÉS — evita la segunda tragedia', [
        'Espera réplicas: pueden derribar estructuras ya dañadas.',
        'Corta gas y electricidad si hueles gas o hay daños. No enciendas fósforos.',
        'Evacúa por escaleras, con zapatos. Revisa grietas antes de reingresar.',
        'Usa mensajes de texto, no llamadas, para no saturar la red.',
        'Líneas en Colombia: Emergencias 123 · Cruz Roja 132 · Defensa Civil 144.',
      ]),
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kWatch.withValues(alpha: .5)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('🎓 Simulacro de sismo',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text(
            'Practica tu reacción: la alarma sonará como en un sismo real y '
            'mediremos cuánto tardas en ponerte a salvo. Ideal para practicar '
            'en familia o en simulacros del colegio o del municipio.',
            style: TextStyle(fontSize: 12, color: kMuted, height: 1.5),
          ),
          if (drillLast != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '⏱️ Última reacción: ${drillLast!.toStringAsFixed(1)} s'
                '${drillBest != null ? '   ·   🏅 Mejor: ${drillBest!.toStringAsFixed(1)} s' : ''}',
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700, color: kWatch),
              ),
            ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: drillCountdown > 0 ? kPanel2 : kWatch,
                foregroundColor:
                    drillCountdown > 0 ? kText : const Color(0xFF0B1120),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: _startDrill,
              child: Text(
                drillCountdown > 0
                    ? 'La alarma sonará en $drillCountdown…'
                    : '🚨 Iniciar simulacro',
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ]),
      ),
      Container(
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kLine),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('⚙️ Ajustes de la app',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          _settingRow(
            '🔍 Radio de búsqueda',
            DropdownButton<double>(
              value: radiusKm,
              dropdownColor: kPanel2,
              underline: const SizedBox(),
              items: const [300.0, 500.0, 1000.0, 2000.0]
                  .map((v) =>
                      DropdownMenuItem(value: v, child: Text('${v.round()} km')))
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() => radiusKm = v);
                _prefs?.setDouble('radius_km', v);
                _reload();
              },
            ),
          ),
          _settingRow(
            '📏 Magnitud mínima',
            DropdownButton<double>(
              value: minMag,
              dropdownColor: kPanel2,
              underline: const SizedBox(),
              items: const [2.0, 2.5, 3.5, 4.5]
                  .map((v) => DropdownMenuItem(value: v, child: Text('M $v')))
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() => minMag = v);
                _prefs?.setDouble('min_mag', v);
                _reload();
              },
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Datos sísmicos combinados de tres catálogos: SGC (Servicio Geológico '
            'Colombiano, fuente oficial del país), USGS (Servicio Geológico de EE.UU.) '
            'y EMSC (Centro Sismológico Euro-Mediterráneo, con conexión en tiempo '
            'real ⚡). Se actualizan cada 60 s y los duplicados se fusionan dando '
            'prioridad al SGC. Esta app es una herramienta comunitaria de apoyo y '
            'no reemplaza los canales oficiales.',
            style: TextStyle(fontSize: 11, color: kMuted, height: 1.5),
          ),
        ]),
      ),
      Container(
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kLine),
        ),
        child: Row(children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(
                  colors: [Color(0xFF0EA5E9), Color(0xFF6366F1)]),
            ),
            child: const Center(
              child: Text('CEMG',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Colors.white)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('👨‍💻 Desarrollador',
                  style: TextStyle(fontSize: 11, color: kMuted)),
              const SizedBox(height: 2),
              const Text('Carlos Eduardo Monroy Guzmán',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              const Text('📞 311 448 6732',
                  style: TextStyle(fontSize: 12, color: kMuted)),
              const SizedBox(height: 2),
              Text('🔒 ID anónimo del dispositivo: $anonId',
                  style: const TextStyle(fontSize: 10, color: kMuted)),
            ]),
          ),
        ]),
      ),
    ]);
  }

  Widget _settingRow(String label, Widget control) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(label, style: const TextStyle(fontSize: 13)), control],
        ),
      );

  Widget _alertOverlay() {
    return Positioned.fill(
      child: Container(
        color: const Color(0xF20B1120),
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (alertIsDrill)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: kWatch.withValues(alpha: .2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: kWatch),
              ),
              child: const Text('🎓 SIMULACRO — ESTO ES UNA PRÁCTICA',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w800, color: kWatch)),
            ),
          const Text('🚨', style: TextStyle(fontSize: 64)),
          const SizedBox(height: 12),
          Text(alertTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w800, color: kDanger)),
          const SizedBox(height: 10),
          Text(alertMsg,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: kText, height: 1.5)),
          const SizedBox(height: 22),
          const Text('🧎 AGÁCHATE\n🛡️ CÚBRETE\n✊ SUJÉTATE',
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 20, fontWeight: FontWeight.w800, height: 1.6)),
          const SizedBox(height: 30),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: kDanger,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            ),
            onPressed: () {
              Vibration.cancel();
              _stopSiren();
              setState(() => alertActive = false);
              _finishDrill();
            },
            child: const Text('Estoy a salvo',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
    );
  }
}

// ---------------- Radar ----------------
class RadarView extends StatefulWidget {
  final List<Quake> quakes;
  final double radiusKm;
  final String? selectedId;
  final ValueChanged<String?> onSelect;
  const RadarView({
    super.key,
    required this.quakes,
    required this.radiusKm,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  State<RadarView> createState() => _RadarViewState();
}

class _RadarViewState extends State<RadarView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Quake? get _selected {
    for (final q in widget.quakes) {
      if (q.id == widget.selectedId) return q;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final sel = _selected;
    return Column(children: [
      Expanded(
        child: LayoutBuilder(builder: (context, box) {
          final side = math.min(box.maxWidth, box.maxHeight);
          return Center(
            child: GestureDetector(
              onTapUp: (d) {
                final local = d.localPosition;
                final blips = computeBlips(widget.quakes, widget.radiusKm, side);
                RadarBlip? best;
                var bd = double.infinity;
                for (final b in blips) {
                  final dist = (b.pos - local).distance;
                  if (dist < math.max(b.size, 14) + 8 && dist < bd) {
                    bd = dist;
                    best = b;
                  }
                }
                widget.onSelect(best?.quake.id);
              },
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (_, _) => CustomPaint(
                  size: Size(side, side),
                  painter: RadarPainter(
                    quakes: widget.quakes,
                    radiusKm: widget.radiusKm,
                    sweep: _ctrl.value * 2 * math.pi,
                    selectedId: widget.selectedId,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _LegendDot(color: kMagLow, label: 'M < 4'),
          SizedBox(width: 14),
          _LegendDot(color: kMagMid, label: 'M 4–5.5'),
          SizedBox(width: 14),
          _LegendDot(color: kMagHigh, label: 'M ≥ 5.5'),
        ]),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('Toca un punto del radar para ver detalles · Tú estás en el centro',
            style: TextStyle(fontSize: 11, color: kMuted)),
      ),
      if (sel != null)
        Container(
          margin: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          padding: const EdgeInsets.all(12),
          width: double.infinity,
          decoration: BoxDecoration(
            color: kPanel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kLine),
          ),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: 'M${sel.mag.toStringAsFixed(1)}',
                  style: TextStyle(
                      color: magColor(sel.mag), fontWeight: FontWeight.w800)),
              TextSpan(text: ' — ${sel.place}\n'),
              TextSpan(
                  text:
                      '📏 A ${sel.dist.round()} km de ti · Profundidad ${sel.depth.round()} km · ${timeAgo(sel.time)} · Fuente: ${sel.source}\n',
                  style: const TextStyle(color: kMuted)),
              TextSpan(
                  text: sel.felt >= 4.5
                      ? '⚠️ Probablemente se sintió fuerte en tu zona'
                      : sel.felt >= 2.5
                          ? '🔸 Pudo sentirse levemente en tu zona'
                          : '✅ Imperceptible en tu ubicación'),
            ]),
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
        )
      else
        const SizedBox(height: 10),
    ]);
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});
  @override
  Widget build(BuildContext context) => Row(children: [
        Text('● ', style: TextStyle(color: color, fontSize: 11)),
        Text(label, style: const TextStyle(fontSize: 11, color: kMuted)),
      ]);
}

class RadarBlip {
  final Offset pos;
  final double size;
  final Quake quake;
  RadarBlip(this.pos, this.size, this.quake);
}

List<RadarBlip> computeBlips(List<Quake> quakes, double radiusKm, double side) {
  final c = side / 2;
  final maxR = c - 14;
  final out = <RadarBlip>[];
  for (final q in quakes) {
    if (q.dist > radiusKm) continue;
    final r = q.dist / radiusKm * maxR;
    final x = c + math.sin(q.brg) * r;
    final y = c - math.cos(q.brg) * r;
    out.add(RadarBlip(Offset(x, y), 4 + q.mag * 1.9, q));
  }
  return out;
}

class RadarPainter extends CustomPainter {
  final List<Quake> quakes;
  final double radiusKm, sweep;
  final String? selectedId;
  RadarPainter({
    required this.quakes,
    required this.radiusKm,
    required this.sweep,
    required this.selectedId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final c = Offset(side / 2, side / 2);
    final maxR = side / 2 - 14;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Anillos de distancia
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = kAccent.withValues(alpha: .18);
    const rings = 4;
    for (var i = 1; i <= rings; i++) {
      canvas.drawCircle(c, maxR * i / rings, ringPaint);
      _text(canvas, '${(radiusKm * i / rings).round()} km',
          Offset(c.dx, c.dy - maxR * i / rings + 4), kMuted.withValues(alpha: .7), 10);
    }
    // Cruz
    final crossPaint = Paint()
      ..strokeWidth = 1
      ..color = kAccent.withValues(alpha: .10);
    canvas.drawLine(Offset(c.dx - maxR, c.dy), Offset(c.dx + maxR, c.dy), crossPaint);
    canvas.drawLine(Offset(c.dx, c.dy - maxR), Offset(c.dx, c.dy + maxR), crossPaint);
    _text(canvas, 'N', Offset(c.dx, c.dy - maxR - 4), kMuted, 11, bold: true);

    // Barrido
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        colors: [kAccent.withValues(alpha: .28), kAccent.withValues(alpha: 0)],
        stops: const [0, .5],
        transform: GradientRotation(sweep),
      ).createShader(Rect.fromCircle(center: c, radius: maxR));
    canvas.drawCircle(c, maxR, sweepPaint);

    // Sismos
    for (final b in computeBlips(quakes, radiusKm, side)) {
      final q = b.quake;
      final ageH = (now - q.time.millisecondsSinceEpoch) / 3600000.0;
      final alpha = ageH < 1 ? 1.0 : (ageH < 24 ? 0.85 : 0.45);
      if (ageH < 3) {
        final p = (now / 900) % 1;
        canvas.drawCircle(
          b.pos,
          b.size + p * 16,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = magColor(q.mag).withValues(alpha: (1 - p) * .45),
        );
      }
      canvas.drawCircle(
          b.pos, b.size, Paint()..color = magColor(q.mag).withValues(alpha: alpha));
      if (q.id == selectedId) {
        canvas.drawCircle(
          b.pos,
          b.size,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white,
        );
      }
    }

    // Usuario en el centro con pulso
    canvas.drawCircle(c, 7, Paint()..color = kAccent);
    final up = (now / 1200) % 1;
    canvas.drawCircle(
      c,
      7 + up * 14,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = kAccent.withValues(alpha: 1 - up),
    );
  }

  void _text(Canvas canvas, String s, Offset center, Color color, double size,
      {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(
              color: color,
              fontSize: size,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy));
  }

  @override
  bool shouldRepaint(covariant RadarPainter old) => true;
}

// ---------------- Sismógrafo ----------------
class SeismoView extends StatefulWidget {
  final VoidCallback onQuakeDetected;
  final bool bgWatchOn;
  final ValueChanged<bool> onToggleBgWatch;
  final ValueNotifier<String> serviceStatus;
  const SeismoView({
    super.key,
    required this.onQuakeDetected,
    required this.bgWatchOn,
    required this.onToggleBgWatch,
    required this.serviceStatus,
  });

  @override
  State<SeismoView> createState() => _SeismoViewState();
}

class _SeismoViewState extends State<SeismoView> {
  bool on = false;
  final List<double> buf = [];
  final detector = StaLtaDetector(sampleRate: 50);
  double peak = 0, current = 0, ratio = 0;
  bool ready = false;
  StreamSubscription<UserAccelerometerEvent>? _sub;

  void _toggle() {
    if (on) {
      _sub?.cancel();
      _sub = null;
      setState(() => on = false);
      return;
    }
    buf.clear();
    peak = 0;
    ratio = 0;
    ready = false;
    detector.reset();
    try {
      _sub = userAccelerometerEventStream(
              samplingPeriod: const Duration(milliseconds: 20))
          .listen(_onMotion, onError: (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Este dispositivo no tiene acelerómetro accesible')));
        setState(() => on = false);
      }, cancelOnError: true);
      setState(() => on = true);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Este dispositivo no tiene acelerómetro accesible')));
    }
  }

  DateTime _lastVetoToast = DateTime.fromMillisecondsSinceEpoch(0);

  void _onMotion(UserAccelerometerEvent e) {
    // userAccelerometer ya excluye la gravedad: la magnitud es la vibración.
    final m = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final st = detector.process(m);
    buf.add(st.filtered.abs());
    if (buf.length > 400) buf.removeAt(0);
    if (st.sta > peak) peak = st.sta;
    if (st.triggered) widget.onQuakeDetected();
    if (st.veto != null &&
        mounted &&
        DateTime.now().difference(_lastVetoToast).inSeconds > 5) {
      _lastVetoToast = DateTime.now();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('🔨 Alarma descartada: ${st.veto}'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: kPanel2,
          duration: const Duration(seconds: 4),
        ));
    }
    if (mounted) {
      setState(() {
        current = st.sta;
        ratio = st.ratio;
        ready = st.ready;
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = !on
        ? '—'
        : !ready
            ? '⏳ Calibrando'
            : ratio > 4
                ? '🔴 FUERTE'
                : ratio > 2
                    ? '🟡 Vibrando'
                    : '🟢 Estable';
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 16), children: [
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('SISMÓGRAFO — SENSORES DE TU TELÉFONO',
            style: TextStyle(
                fontSize: 12,
                color: kMuted,
                fontWeight: FontWeight.w700,
                letterSpacing: 1)),
      ),
      // Vigilancia 24/7 en segundo plano
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: widget.bgWatchOn ? kSafe.withValues(alpha: .5) : kLine),
        ),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('🛰️ Vigilancia 24/7 en segundo plano',
                        style: TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      widget.bgWatchOn
                          ? 'El detector sigue activo con la pantalla apagada.'
                          : 'Sigue detectando aunque cierres la app o se apague la pantalla.',
                      style: const TextStyle(fontSize: 11.5, color: kMuted),
                    ),
                  ]),
            ),
            Switch(
              value: widget.bgWatchOn,
              activeTrackColor: kSafe,
              onChanged: widget.onToggleBgWatch,
            ),
          ]),
          if (widget.bgWatchOn)
            ValueListenableBuilder<String>(
              valueListenable: widget.serviceStatus,
              builder: (_, txt, _) => txt.isEmpty
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(txt,
                          style: const TextStyle(fontSize: 11, color: kSafe)),
                    ),
            ),
        ]),
      ),
      Container(
        height: 180,
        decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kLine),
        ),
        child: CustomPaint(
            size: const Size(double.infinity, 180), painter: SeismoPainter(buf)),
      ),
      const SizedBox(height: 10),
      Row(children: [
        _gauge(current.toStringAsFixed(3), 'Vibración m/s²'),
        const SizedBox(width: 8),
        _gauge(ratio.toStringAsFixed(1), 'STA/LTA'),
        const SizedBox(width: 8),
        _gauge(state, 'Estado'),
      ]),
      const SizedBox(height: 12),
      const Text(
        'Apoya el teléfono sobre una mesa o el suelo y activa el sensor. '
        'El detector trabaja en dos etapas: primero el algoritmo sismológico STA/LTA '
        'con filtro pasa-banda (0.4–5 Hz) marca los candidatos, y luego un clasificador '
        'estilo MyShake (UC Berkeley) descarta lo que no es sismo: golpes secos '
        '(factor de cresta), objetos vibrando (cruces por cero y energía de alta '
        'frecuencia) y manipulación del teléfono (reposo previo). '
        'Así funciona también la red de detección de Google en Android.',
        style: TextStyle(fontSize: 12, color: kMuted, height: 1.5),
      ),
      const SizedBox(height: 14),
      FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: on ? kPanel2 : kAccent,
          foregroundColor: on ? kText : const Color(0xFF0B1120),
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        onPressed: _toggle,
        child: Text(on ? '⏸️ Detener sismógrafo' : '▶️ Activar sismógrafo',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      ),
      const SizedBox(height: 20),
    ]);
  }

  Widget _gauge(String value, String label) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: kPanel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kLine),
          ),
          child: Column(children: [
            Text(value,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 10, color: kMuted)),
          ]),
        ),
      );
}

class SeismoPainter extends CustomPainter {
  final List<double> buf;
  SeismoPainter(this.buf);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // Rejilla
    final grid = Paint()
      ..strokeWidth = 1
      ..color = kAccent.withValues(alpha: .08);
    for (double y = 0; y < h; y += 30) {
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }
    canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2),
        Paint()..color = kMuted.withValues(alpha: .25));
    // Forma de onda espejada alrededor del centro, como un sismograma
    if (buf.length > 1) {
      final path = Path();
      for (var i = 0; i < buf.length; i++) {
        final x = i / 399 * w;
        final y = h / 2 - math.min(buf[i] * 40, h / 2 - 4) * (i.isOdd ? 1 : -1);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      final last = buf.last;
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = last > 2.5 ? kMagHigh : (last > 0.8 ? kMagMid : kMagLow),
      );
    }
  }

  @override
  bool shouldRepaint(covariant SeismoPainter old) => true;
}
