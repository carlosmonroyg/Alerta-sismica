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
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';

import 'core.dart';
import 'detector.dart';
import 'map_view.dart';
import 'firebase_config.dart';
import 'push.dart';
import 'quake_notify.dart';
import 'seismo_service.dart';
import 'servidor.dart';
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
  String servidorUrl = '';
  String? temaFcm;

  // Encuadre del mapa al tocar una notificación
  MapFocus? mapFocus;
  int _focusSeq = 0;

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
    _iniciarPush();
    _loadPrefs().then((_) => _fetchQuakes(full: true));
    _initLocation();
    _refreshBgWatchState();
    // El trabajo que hace el teléfono se decide al cargar las preferencias,
    // según haya servidor o no (ver _ajustarFuentes).
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
      radiusKm = _prefs!.getDouble(kPrefRadiusKm) ?? radiusKm;
      minMag = _prefs!.getDouble(kPrefMinMag) ?? minMag;
      // Lo que el usuario haya configurado manda; si no, el valor de compilación.
      // Ojo: una preferencia guardada como cadena VACÍA no es lo mismo que
      // "sin preferencia". Si no hay nada útil guardado, manda la URL fijada
      // al compilar; así el usuario final nunca tiene que escribirla.
      final guardado = _prefs!.getString('servidor_url')?.trim() ?? '';
      servidorUrl = guardado.isEmpty ? Servidor.porDefecto : guardado;
      Servidor.baseUrl = servidorUrl;
      debugPrint('SERVIDOR compilado=[${Servidor.porDefecto}] '
          'enUso=[$servidorUrl] activo=${Servidor.activo}');
      drillLast = _prefs!.getDouble('drill_last');
      drillBest = _prefs!.getDouble('drill_best');
    });
    await saveWatchConfig(
      lat: lat,
      lon: lon,
      radiusKm: radiusKm,
      minMag: minMag,
      anonId: anonId,
      servidorUrl: servidorUrl,
    );
    await _registrarEnServidor();
    await _suscribirZonaLocal();
    _ajustarFuentes();
  }

  Future<void> _abrirPanelMunicipal() async {
    if (!Servidor.activo) return;
    final base = servidorUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$base/panel').replace(
      queryParameters: {
        'municipio': cityName,
        'lat': lat.toStringAsFixed(4),
        'lon': lon.toStringAsFixed(4),
      },
    );
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok) _toast('No se pudo abrir el panel');
  }

  /// Suscribe el teléfono a la zona donde está. No depende del servidor:
  /// la zona se calcula con la misma fórmula, así el push funciona apenas
  /// se conoce la ubicación.
  Future<void> _suscribirZonaLocal() async {
    // El isolate que atiende los avisos con la app cerrada arranca sin estado:
    // necesita esta ubicación guardada para calcular la distancia al sismo.
    await _prefs?.setDouble(kPrefUltLat, lat);
    await _prefs?.setDouble(kPrefUltLon, lon);
    await Push.suscribirAZona(zonaFcm(lat, lon));
    if (mounted) setState(() {});
  }

  /// Enciende las notificaciones push. Es el camino de menor consumo:
  /// Android ya mantiene una conexión compartida por todas las apps, así
  /// que el aviso llega sin que el teléfono abra nada propio.
  Future<void> _iniciarPush() async {
    final t = await Push.iniciar(
      alRecibirEnPrimerPlano: _sismoPorPush,
      alTocarAviso: (datos) {
        final q = Push.sismoDesdeMensaje(datos, lat, lon);
        if (q != null) _mostrarEnMapa(q);
      },
    );
    if (t == null || !mounted) return;
    debugPrint('Push activo · token ${t.substring(0, 12)}…'
        ' (${t.length} caracteres)');
    setState(() {});
    // Registrar el token en el servidor (si lo hay) y suscribirse a la zona.
    await _registrarEnServidor();
    await _suscribirZonaLocal();
  }

  /// Sismo empujado por el servidor con la app abierta.
  void _sismoPorPush(Map<String, dynamic> datos) {
    if (datos['tipo'] == 'simulacro') {
      _fireAlert('SIMULACRO DE SISMO',
          'Practica: agáchate, cúbrete y sujétate. Pulsa "Estoy a salvo" al terminar.',
          drill: true);
      return;
    }
    // Consenso comunitario: varios teléfonos sintieron la misma sacudida a la
    // vez. No viene de un catálogo sino de acelerómetros, así que NO trae
    // magnitud, y al pasar por el filtro se descartaba en silencio: con la app
    // abierta este aviso no llegaba nunca. Va antes del filtro porque no hay
    // magnitud que comparar contra el umbral.
    if (datos['tipo'] == 'consenso') {
      final n = int.tryParse('${datos['dispositivos']}') ?? 0;
      _fireAlert(
        '⚠️ Movimiento detectado cerca de ti',
        '${n > 1 ? '$n teléfonos registraron' : 'Varios teléfonos registraron'}'
            ' una sacudida simultánea. Si lo sentiste, protégete.',
      );
      return;
    }
    final q = Push.sismoDesdeMensaje(datos, lat, lon);
    if (q == null) return;
    if (!_pasaElFiltro(q, emergencia: '${datos['emergencia']}' == '1')) return;
    if (knownIds.contains(q.id)) return;
    knownIds.add(q.id);
    setState(() {
      quakes
        ..removeWhere((x) => x.id == q.id)
        ..insert(0, q)
        ..sort((a, b) => b.time.compareTo(a.time));
    });
    if (_notifsReady) showQuakeNotification(_notifs, q);
    if (q.felt >= 4.5) {
      _fireAlert('Sismo M${q.mag.toStringAsFixed(1)} — ${q.place}',
          'A ${q.dist.round()} km de ti. Podrías sentirlo o recibir réplicas.');
    } else {
      _toastQuake(q);
    }
    _assessRisk();
  }

  /// Centra el mapa en un sismo concreto.
  void _mostrarEnMapa(Quake q) {
    if (!mounted) return;
    setState(() {
      if (!quakes.any((x) => x.id == q.id)) {
        quakes
          ..insert(0, q)
          ..sort((a, b) => b.time.compareTo(a.time));
      }
      tab = 1;
      selectedQuakeId = q.id;
      mapFocus = MapFocus(q.lat, q.lon, ++_focusSeq);
    });
  }

  /// Da de alta el teléfono en el servidor (si está configurado).
  Future<void> _registrarEnServidor() async {
    if (!Servidor.activo || anonId == '…') return;
    final tema = await Servidor.registrar(
      anonId: anonId,
      lat: lat,
      lon: lon,
      radioKm: radiusKm,
      minMag: minMag,
      municipio: cityName,
      tokenFcm: Push.token,
    );
    if (mounted && tema != null) setState(() => temaFcm = tema);
    // El servidor asigna una zona; el teléfono se suscribe a ella y a
    // partir de ahí los avisos llegan por push, sin gastar batería.
    await Push.suscribirAZona(tema);
  }

  /// Configura el servidor de la plataforma (opcional).
  Future<void> _configurarServidor() async {
    final ctrl = TextEditingController(text: servidorUrl);
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kPanel,
        title: const Text(
          'Servidor de la plataforma',
          style: TextStyle(fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Al conectarlo, los sismos llegan ya procesados y el teléfono '
              'deja de descargar los catálogos completos. Déjalo vacío para '
              'que la app funcione por su cuenta.',
              style: TextStyle(fontSize: 12, color: kMuted, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autocorrect: false,
              keyboardType: TextInputType.url,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'https://alerta-sismica.workers.dev',
                hintStyle: TextStyle(color: kMuted, fontSize: 12),
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (url == null) return;
    setState(() {
      servidorUrl = url;
      Servidor.baseUrl = url;
      temaFcm = null;
    });
    await _prefs?.setString('servidor_url', url);
    _ajustarFuentes();
    if (url.isEmpty) {
      _toast('Servidor desconectado — la app trabaja por su cuenta');
    } else {
      await _registrarEnServidor();
      _toast(
        temaFcm != null
            ? '🛰️ Conectado al servidor · zona $temaFcm'
            : 'No se pudo conectar con el servidor',
      );
    }
    _reload();
  }

  /// Decide cuánto trabajo hace el teléfono por su cuenta.
  ///
  /// CON servidor: él mantiene el WebSocket del EMSC y consulta los
  /// catálogos una sola vez para todos, así que el teléfono no abre
  /// conexiones propias ni sondea seguido. Es la diferencia entre una radio
  /// que despierta miles de veces al día y una que apenas se usa.
  ///
  /// SIN servidor: la app hace ese trabajo sola (más batería y más datos).
  void _ajustarFuentes() {
    _pollTimer?.cancel();
    if (Servidor.activo) {
      _emscFeed.stop();
    } else {
      _emscFeed.start();
    }
    _pollTimer = Timer.periodic(
      Duration(seconds: Servidor.activo ? 300 : 120),
      (_) => _fetchQuakes(),
    );
  }

  Future<void> _refreshBgWatchState() async {
    final running = await FlutterForegroundTask.isRunningService;
    if (mounted) setState(() => bgWatchOn = running);
  }

  Future<void> _toggleBgWatch(bool value) async {
    if (value) {
    await saveWatchConfig(
        lat: lat,
        lon: lon,
        radiusKm: radiusKm,
        minMag: minMag,
        anonId: anonId,
        servidorUrl: servidorUrl,
      );
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
        final ready = data['ready'] == true;
        final armed = data['armed'] == true;
        final still = (data['still'] as num?)?.toDouble() ?? 0;
        serviceStatus.value = !ready
            ? 'Calibrando ruido de fondo…'
            : armed
            ? '🛡️ Armado · quieto hace ${still.round()} s · vibración ${sta.toStringAsFixed(3)} m/s²'
            : '✋ En uso — se arma cuando dejes el teléfono quieto '
                  '(${(45 - still).clamp(0, 45).round()} s)';
      case 'alarm':
        _fireAlert(
          '¡VIBRACIÓN FUERTE DETECTADA!',
          'El sismógrafo en segundo plano registró un movimiento sostenido compatible con un sismo. Protégete AHORA.',
        );
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
      _sirenTimer = Timer(
        const Duration(seconds: 20),
        () => _sirenPlayer.stop(),
      );
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
          m.administrativeArea,
        ]) {
          if (candidate != null && candidate.trim().isNotEmpty) {
            return candidate.trim();
          }
        }
      }
    } catch (_) {}
    return 'tu ubicación';
  }

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
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      );
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
    } catch (_) {}
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
      // En iOS el permiso se pide aquí, no al mostrar el primer aviso. Se
      // desactiva la petición automática para hacerla abajo y quedarnos con
      // la respuesta: si el usuario dice que no, la app tiene que saberlo.
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _notifs.initialize(
      init,
      onDidReceiveNotificationResponse: (r) => _openQuakeFromPayload(r.payload),
    );
    final android = _notifs
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final ios = _notifs
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    // Cada plataforma resuelve SOLO su implementación; la otra es null. Pedir
    // el permiso únicamente por la vía de Android dejaba `_notifsReady` en
    // false para siempre en iOS: la app no habría mostrado un solo aviso.
    final granted = android != null
        ? await android.requestNotificationsPermission()
        : await ios?.requestPermissions(alert: true, badge: false, sound: true);
    _notifsReady = granted ?? false;
    // Declarar los canales antes de necesitarlos: Android descarta en silencio
    // cualquier aviso dirigido a un canal que todavía no existe, y el primer
    // sismo de una instalación nueva suele llegar por push.
    await crearCanalesDeSismo(_notifs);
    // Desde Android 14 las alertas que se apoderan de la pantalla requieren
    // un permiso aparte, pensado para apps de alarma y emergencia. Sin él, un
    // sismo fuerte quedaría como una tarjeta más en la cortina.
    try {
      await android?.requestFullScreenIntentPermission();
    } catch (_) {}
    // La app pudo abrirse por un toque en la notificación (estando cerrada).
    final launch = await _notifs.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      _openQuakeFromPayload(launch!.notificationResponse?.payload);
    }
  }

  /// Abre el mapa centrado en el epicentro del sismo de la notificación.
  void _openQuakeFromPayload(String? payload) {
    final q = decodeQuakePayload(payload, lat, lon);
    if (q == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        // Si el sismo aún no está en la lista (llegó por el servicio), agregarlo.
        if (!quakes.any((x) => x.id == q.id)) {
          quakes
            ..insert(0, q)
            ..sort((a, b) => b.time.compareTo(a.time));
        }
        tab = 1; // pestaña Mapa
        selectedQuakeId = q.id;
        mapFocus = MapFocus(q.lat, q.lon, ++_focusSeq);
      });
      // Si el sismo es fuerte, la app no se abrió porque el usuario tocara un
      // aviso: se abrió sola, apoderándose de la pantalla. Lo primero que debe
      // ver no es un mapa, son las instrucciones para protegerse.
      if (q.felt >= 4.5) {
        _fireAlert(
          'Sismo M${q.mag.toStringAsFixed(1)} — ${q.place}',
          'A ${q.dist.round()} km de ti. Protégete AHORA y mantente atento a '
              'las réplicas.',
        );
      }
    });
  }

  Future<void> _notify(String title, String body) async {
    if (!_notifsReady) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'sismos',
        'Alertas sísmicas',
        channelDescription: 'Avisos de sismos nuevos cerca de ti',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    await _notifs.show(
      DateTime.now().millisecondsSinceEpoch % 100000,
      title,
      body,
      details,
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          backgroundColor: kPanel2,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  // ---------------- Datos SGC + USGS + EMSC ----------------
  /// [full] descarga el historial completo de 7 días (al abrir la app o al
  /// cambiar de ciudad/filtros). Las recargas periódicas son livianas: el API
  /// del SGC ignora todo filtro y devuelve 88 KB por página, así que basta la
  /// primera —donde están los eventos nuevos— y se fusiona con lo que ya hay.
  Future<void> _fetchQuakes({bool full = false}) async {
    // El servidor ya entrega los sismos fusionados y deduplicados: usarlo
    // le ahorra al usuario descargar los catálogos completos (~13 MB/día).
    if (Servidor.activo) {
      // La magnitud mínima viaja con la petición: sin ella el servidor
      // devolvía TODO su catálogo dentro del radio y la lista contradecía el
      // ajuste del usuario (además de disparar un aviso por cada micro-sismo).
      final delServidor = await Servidor.traerSismos(
        lat: lat,
        lon: lon,
        radiusKm: radiusKm,
        minMag: minMag,
        dias: 7,
      );
      if (delServidor != null && mounted) {
        setState(() {
          // dedupQuakes TAMBIÉN aquí: el camino del servidor era el único que
          // no fusionaba, y como es el que se usa cuando hay servidor, un
          // mismo sismo llegaba tres veces —una por catálogo— con tres
          // magnitudes distintas. El servidor ya lo fusiona, pero la app no
          // debe depender de qué versión tenga desplegada.
          quakes = _filtrados(dedupQuakes(delServidor));
          online = true;
          final now = TimeOfDay.now();
          final hh = now.hour.toString().padLeft(2, '0');
          final mm = now.minute.toString().padLeft(2, '0');
          statusText =
              'En vivo · ${quakes.length} sismos · servidor 🛰️ · $hh:$mm';
        });
        _detectNewQuakes();
        _assessRisk();
        return;
      }
      // Si el servidor no responde, se cae a los catálogos directos.
    }
    final res = await fetchAllSources(
      lat: lat,
      lon: lon,
      radiusKm: radiusKm,
      minMag: minMag,
      sgcMaxPages: full ? 3 : 1,
    );
    if (!mounted) return;
    if (res.sourcesOk.isEmpty) {
      setState(() {
        online = false;
        statusText = 'Sin conexión con los catálogos — reintentando…';
      });
      return;
    }
    final limite = DateTime.now().subtract(const Duration(days: 7));
    setState(() {
      quakes = _filtrados(
        full
            ? res.quakes
            : dedupQuakes([
                ...res.quakes,
                ...quakes,
              ]).where((q) => q.time.isAfter(limite)),
      );
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
    if (q == null || !_pasaElFiltro(q)) return;
    if (!mounted) return;
    // Evitar duplicar un evento que ya está listado por SGC/USGS.
    final dup = quakes.any(
      (x) =>
          x.id != q.id &&
          x.time.difference(q.time).abs().inSeconds < 120 &&
          haversineKm(x.lat, x.lon, q.lat, q.lon) < 60,
    );
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

  /// Los ajustes del usuario aplicados a un sismo concreto. Vive aquí para que
  /// los tres caminos de aviso —lista, WebSocket y push— decidan igual.
  bool _pasaElFiltro(Quake q, {bool emergencia = false}) => sismoPasaElFiltro(
        q,
        minMag: minMag,
        radioKm: radiusKm,
        // Un sismo que puede sentirse con fuerza no lo silencia un ajuste.
        emergencia: emergencia || q.felt >= 4.5,
      );

  /// ÚNICA PUERTA DE ENTRADA a la lista que se muestra.
  ///
  /// La lista alimenta a la vez el listado, el radar y el mapa, así que basta
  /// con que un sismo se cuele en ella para que aparezca en los tres sitios
  /// contradiciendo el ajuste. Antes el filtro se aplicaba en cada camino por
  /// separado —y cada camino nuevo era una fuga en potencia—; ahora todo lo
  /// que entra pasa por aquí.
  List<Quake> _filtrados(Iterable<Quake> lista) =>
      lista.where(_pasaElFiltro).toList();

  void _detectNewQuakes() {
    for (final q in quakes) {
      if (knownIds.contains(q.id)) continue;
      knownIds.add(q.id);
      if (firstLoad) continue;
      final ageMin = DateTime.now().difference(q.time).inMinutes;
      if (ageMin > 90) continue; // solo eventos realmente frescos
      // Radio Y magnitud mínima: el ajuste de magnitud se ignoraba aquí, así
      // que subirlo a M3.5 no cambiaba nada y seguían avisándose todos.
      if (!_pasaElFiltro(q)) continue;

      if (_notifsReady) showQuakeNotification(_notifs, q);

      if (q.felt >= 4.5 || (q.mag >= 5 && q.dist < 300)) {
        _fireAlert(
          'Sismo M${q.mag.toStringAsFixed(1)} — ${q.place}',
          'A ${q.dist.round()} km de ti, ${timeAgo(q.time)}. Podrías sentirlo o recibir réplicas.',
        );
      } else {
        _toastQuake(q);
      }
    }
    firstLoad = false;
  }

  /// Aviso dentro de la app con acceso directo al mapa.
  void _toastQuake(Quake q) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '🌎 Sismo M${q.mag.toStringAsFixed(1)} a ${q.dist.round()} km · ${q.place}',
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: kPanel2,
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Ver mapa',
            textColor: kAccent,
            onPressed: () => setState(() {
              tab = 1;
              selectedQuakeId = q.id;
              mapFocus = MapFocus(q.lat, q.lon, ++_focusSeq);
            }),
          ),
        ),
      );
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
  Future<void> _fireAlert(
    String title,
    String msg, {
    bool drill = false,
  }) async {
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
          pattern: [0, 400, 150, 400, 150, 800, 150, 400, 150, 800],
        );
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
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
          ),
        );
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
    // El servicio en segundo plano usa la misma ubicación y filtros.
    saveWatchConfig(
      lat: lat,
      lon: lon,
      radiusKm: radiusKm,
      minMag: minMag,
      anonId: anonId,
      servidorUrl: servidorUrl,
    );
    _registrarEnServidor();
    _fetchQuakes(full: true);
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // En la pestaña Mapa (índice 1) el mapa ocupa toda la pantalla.
                if (tab != 1) _header(),
                if (tab != 1) _riskCard(),
                Expanded(
                  child: IndexedStack(
                    index: tab,
                    children: [
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
                        focus: mapFocus,
                      ),
                      _quakeList(),
                      SeismoView(
                        bgWatchOn: bgWatchOn,
                        onToggleBgWatch: _toggleBgWatch,
                        serviceStatus: serviceStatus,
                        onQuakeDetected: () {
                          Servidor.enviarDeteccion(
                            anonId: anonId,
                            lat: lat,
                            lon: lon,
                          );
                          _fireAlert(
                            '¡VIBRACIÓN FUERTE DETECTADA!',
                            'El acelerómetro de tu teléfono registró un movimiento sostenido compatible con un sismo. Protégete AHORA.',
                          );
                        },
                      ),
                      _guide(),
                    ],
                  ),
                ),
              ],
            ),
            if (alertActive) _alertOverlay(),
          ],
        ),
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
          BottomNavigationBarItem(
            icon: Icon(Icons.map_outlined),
            label: 'Mapa',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.list_alt), label: 'Sismos'),
          BottomNavigationBarItem(
            icon: Icon(Icons.show_chart),
            label: 'Sensor',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.health_and_safety),
            label: 'Guía',
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(
                colors: [Color(0xFF0EA5E9), Color(0xFF6366F1)],
              ),
            ),
            child: const Center(
              child: Text('🌎', style: TextStyle(fontSize: 20)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Alerta Sísmica CO',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: online ? kSafe : kDanger,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        statusText,
                        style: const TextStyle(fontSize: 11, color: kMuted),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _cycleCity,
            style: TextButton.styleFrom(
              backgroundColor: kPanel2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: kLine),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            child: Text(
              '📍 $cityName',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: kText,
              ),
            ),
          ),
        ],
      ),
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
        gradient: LinearGradient(
          colors: [color.withValues(alpha: .14), kPanel],
        ),
      ),
      child: Row(
        children: [
          Text(icon, style: const TextStyle(fontSize: 30)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: const TextStyle(
                    fontSize: 12,
                    color: kMuted,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
                color: magColor(q.mag),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  q.mag.toStringAsFixed(1),
                  style: const TextStyle(
                    color: Color(0xFF0B1120),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            title: Text(q.place, style: const TextStyle(fontSize: 13.5)),
            subtitle: Text(
              '${timeAgo(q.time)} · prof. ${q.depth.round()} km · ${q.source}',
              style: const TextStyle(fontSize: 11.5, color: kMuted),
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${q.dist.round()}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const Text('km', style: TextStyle(fontSize: 10, color: kMuted)),
              ],
            ),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          for (final it in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('• ', style: TextStyle(color: kAccent)),
                  Expanded(
                    child: Text(
                      it,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: kText,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 10, top: 4),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(
              colors: [kAccent.withValues(alpha: .15), kPanel],
            ),
            border: Border.all(color: kAccent.withValues(alpha: .4)),
          ),
          child: const Column(
            children: [
              Text(
                'Si la tierra tiembla, recuerda:',
                style: TextStyle(fontSize: 13),
              ),
              SizedBox(height: 6),
              Text(
                '🧎 AGÁCHATE · 🛡️ CÚBRETE · ✊ SUJÉTATE',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 6),
              Text(
                'La mayoría de las lesiones ocurren por objetos que caen, no por el derrumbe.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: kMuted),
              ),
            ],
          ),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '🎓 Simulacro de sismo',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
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
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: kWatch,
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: drillCountdown > 0 ? kPanel2 : kWatch,
                    foregroundColor: drillCountdown > 0
                        ? kText
                        : const Color(0xFF0B1120),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: _startDrill,
                  child: Text(
                    drillCountdown > 0
                        ? 'La alarma sonará en $drillCountdown…'
                        : '🚨 Iniciar simulacro',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.only(bottom: 20),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: kPanel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kLine),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '⚙️ Ajustes de la app',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              _settingRow(
                '🔍 Radio de búsqueda',
                DropdownButton<double>(
                  value: radiusKm,
                  dropdownColor: kPanel2,
                  underline: const SizedBox(),
                  items: const [300.0, 500.0, 1000.0, 2000.0]
                      .map(
                        (v) => DropdownMenuItem(
                          value: v,
                          child: Text('${v.round()} km'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => radiusKm = v);
                    _prefs?.setDouble(kPrefRadiusKm, v);
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
                      .map(
                        (v) => DropdownMenuItem(value: v, child: Text('M $v')),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => minMag = v);
                    _prefs?.setDouble(kPrefMinMag, v);
                    _reload();
                  },
                ),
              ),
              const SizedBox(height: 4),
              InkWell(
                onTap: _configurarServidor,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '🛰️ Servidor de la plataforma',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                      Text(
                        Servidor.activo
                            ? (temaFcm != null
                                  ? 'zona $temaFcm'
                                  : 'configurado')
                            : 'sin conectar',
                        style: TextStyle(
                          fontSize: 12,
                          color: Servidor.activo ? kSafe : kMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 18, color: kMuted),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('🔔 Avisos push',
                          style: TextStyle(fontSize: 13)),
                    ),
                    Text(
                      Push.activo
                          ? (Push.temaSuscrito != null
                              ? 'zona ${Push.temaSuscrito}'
                              : 'activos')
                          : (FirebaseConfig.configurado
                              ? 'conectando…'
                              : 'sin configurar'),
                      style: TextStyle(
                          fontSize: 12,
                          color: Push.activo ? kSafe : kMuted,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              if (Servidor.activo)
                InkWell(
                  onTap: _abrirPanelMunicipal,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('📊 Panel del municipio',
                              style: TextStyle(fontSize: 13)),
                        ),
                        const Text('para autoridades',
                            style: TextStyle(fontSize: 11.5, color: kMuted)),
                        const SizedBox(width: 6),
                        const Icon(Icons.open_in_new, size: 16, color: kMuted),
                      ],
                    ),
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
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.only(bottom: 20),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: kPanel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kLine),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF0EA5E9), Color(0xFF6366F1)],
                  ),
                ),
                child: const Center(
                  child: Text(
                    'CEMG',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '👨‍💻 Desarrollador',
                      style: TextStyle(fontSize: 11, color: kMuted),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Carlos Eduardo Monroy Guzmán',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '📧 carlosmonroyeg91@gmail.com',
                      style: TextStyle(fontSize: 12, color: kMuted),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '🔒 ID anónimo del dispositivo: $anonId',
                      style: const TextStyle(fontSize: 10, color: kMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _settingRow(String label, Widget control) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        control,
      ],
    ),
  );

  Widget _alertOverlay() {
    return Positioned.fill(
      child: Container(
        color: const Color(0xF20B1120),
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (alertIsDrill)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: kWatch.withValues(alpha: .2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: kWatch),
                ),
                child: const Text(
                  '🎓 SIMULACRO — ESTO ES UNA PRÁCTICA',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: kWatch,
                  ),
                ),
              ),
            const Text('🚨', style: TextStyle(fontSize: 64)),
            const SizedBox(height: 12),
            Text(
              alertTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: kDanger,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              alertMsg,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: kText, height: 1.5),
            ),
            const SizedBox(height: 22),
            const Text(
              '🧎 AGÁCHATE\n🛡️ CÚBRETE\n✊ SUJÉTATE',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 30),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: kDanger,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 16,
                ),
              ),
              onPressed: () {
                Vibration.cancel();
                _stopSiren();
                setState(() => alertActive = false);
                _finishDrill();
              },
              child: const Text(
                'Estoy a salvo',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
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
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
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
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final side = math.min(box.maxWidth, box.maxHeight);
              return Center(
                child: GestureDetector(
                  onTapUp: (d) {
                    final local = d.localPosition;
                    final blips = computeBlips(
                      widget.quakes,
                      widget.radiusKm,
                      side,
                    );
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
            },
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _LegendDot(color: kMagLow, label: 'M < 4'),
              SizedBox(width: 14),
              _LegendDot(color: kMagMid, label: 'M 4–5.5'),
              SizedBox(width: 14),
              _LegendDot(color: kMagHigh, label: 'M ≥ 5.5'),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            'Toca un punto del radar para ver detalles · Tú estás en el centro',
            style: TextStyle(fontSize: 11, color: kMuted),
          ),
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
              TextSpan(
                children: [
                  TextSpan(
                    text: 'M${sel.mag.toStringAsFixed(1)}',
                    style: TextStyle(
                      color: magColor(sel.mag),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  TextSpan(text: ' — ${sel.place}\n'),
                  TextSpan(
                    text:
                        '📏 A ${sel.dist.round()} km de ti · Profundidad ${sel.depth.round()} km · ${timeAgo(sel.time)} · Fuente: ${sel.source}\n',
                    style: const TextStyle(color: kMuted),
                  ),
                  TextSpan(
                    text: sel.felt >= 4.5
                        ? '⚠️ Probablemente se sintió fuerte en tu zona'
                        : sel.felt >= 2.5
                        ? '🔸 Pudo sentirse levemente en tu zona'
                        : '✅ Imperceptible en tu ubicación',
                  ),
                ],
              ),
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          )
        else
          const SizedBox(height: 10),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text('● ', style: TextStyle(color: color, fontSize: 11)),
      Text(label, style: const TextStyle(fontSize: 11, color: kMuted)),
    ],
  );
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
      _text(
        canvas,
        '${(radiusKm * i / rings).round()} km',
        Offset(c.dx, c.dy - maxR * i / rings + 4),
        kMuted.withValues(alpha: .7),
        10,
      );
    }
    // Cruz
    final crossPaint = Paint()
      ..strokeWidth = 1
      ..color = kAccent.withValues(alpha: .10);
    canvas.drawLine(
      Offset(c.dx - maxR, c.dy),
      Offset(c.dx + maxR, c.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(c.dx, c.dy - maxR),
      Offset(c.dx, c.dy + maxR),
      crossPaint,
    );
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
        b.pos,
        b.size,
        Paint()..color = magColor(q.mag).withValues(alpha: alpha),
      );
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

  void _text(
    Canvas canvas,
    String s,
    Offset center,
    Color color,
    double size, {
    bool bold = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
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
  double peak = 0, current = 0, ratio = 0, stillSecs = 0, rate = 50;
  bool ready = false, armed = false;
  StreamSubscription<UserAccelerometerEvent>? _sub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  double _gyroMag = 0;

  void _toggle() {
    if (on) {
      _sub?.cancel();
      _sub = null;
      _gyroSub?.cancel();
      _gyroSub = null;
      setState(() => on = false);
      return;
    }
    buf.clear();
    peak = 0;
    ratio = 0;
    ready = false;
    armed = false;
    stillSecs = 0;
    detector.reset();
    try {
      _gyroSub =
          gyroscopeEventStream(
            samplingPeriod: const Duration(milliseconds: 40),
          ).listen((e) {
            _gyroMag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
          }, onError: (_) {});
      _sub =
          userAccelerometerEventStream(
            samplingPeriod: const Duration(milliseconds: 20),
          ).listen(
            _onMotion,
            onError: (_) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Este dispositivo no tiene acelerómetro accesible',
                  ),
                ),
              );
              setState(() => on = false);
            },
            cancelOnError: true,
          );
      setState(() => on = true);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Este dispositivo no tiene acelerómetro accesible'),
        ),
      );
    }
  }

  DateTime _lastVetoToast = DateTime.fromMillisecondsSinceEpoch(0);

  void _onMotion(UserAccelerometerEvent e) {
    // userAccelerometer ya excluye la gravedad: la magnitud es la vibración.
    final m = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final st = detector.process(m, gyroMag: _gyroMag);
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
        ..showSnackBar(
          SnackBar(
            content: Text('🔨 Alarma descartada: ${st.veto}'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: kPanel2,
            duration: const Duration(seconds: 4),
          ),
        );
    }
    if (mounted) {
      setState(() {
        current = st.sta;
        ratio = st.ratio;
        ready = st.ready;
        armed = st.armed;
        stillSecs = st.stillSeconds;
        rate = st.measuredRate;
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _gyroSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = !on
        ? '—'
        : !ready
        ? '⏳ Calibrando'
        : !armed
        ? '✋ En uso'
        : ratio > 4
        ? '🔴 FUERTE'
        : ratio > 2
        ? '🟡 Vibrando'
        : '🟢 Vigilando';
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'SISMÓGRAFO — SENSORES DE TU TELÉFONO',
            style: TextStyle(
              fontSize: 12,
              color: kMuted,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ),
        // Vigilancia 24/7 en segundo plano
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          decoration: BoxDecoration(
            color: kPanel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: widget.bgWatchOn ? kSafe.withValues(alpha: .5) : kLine,
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '🛰️ Vigilancia 24/7 en segundo plano',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          // En iOS el interruptor no puede cumplir lo que
                          // promete: el sistema suspende la app al cerrarla.
                          // Vale más decirlo que ofrecer algo que no ocurre.
                          !vigilanciaEnSegundoPlanoDisponible
                              ? 'No disponible en iPhone: el sistema suspende la '
                                  'app al cerrarla. Los sismos te llegan igual '
                                  'por notificación.'
                              : widget.bgWatchOn
                                  ? 'El detector sigue activo con la pantalla apagada.'
                                  : 'Sigue detectando aunque cierres la app o se apague la pantalla.',
                          style: const TextStyle(fontSize: 11.5, color: kMuted),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: widget.bgWatchOn,
                    activeTrackColor: kSafe,
                    // null deja el interruptor visiblemente deshabilitado.
                    onChanged: vigilanciaEnSegundoPlanoDisponible
                        ? widget.onToggleBgWatch
                        : null,
                  ),
                ],
              ),
              if (widget.bgWatchOn)
                ValueListenableBuilder<String>(
                  valueListenable: widget.serviceStatus,
                  builder: (_, txt, _) => txt.isEmpty
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            txt,
                            style: const TextStyle(fontSize: 11, color: kSafe),
                          ),
                        ),
                ),
            ],
          ),
        ),
        Container(
          height: 180,
          decoration: BoxDecoration(
            color: kPanel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kLine),
          ),
          child: CustomPaint(
            size: const Size(double.infinity, 180),
            painter: SeismoPainter(buf),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _gauge(current.toStringAsFixed(3), 'Vibración m/s²'),
            const SizedBox(width: 8),
            _gauge(ratio.toStringAsFixed(1), 'STA/LTA'),
            const SizedBox(width: 8),
            _gauge(state, 'Estado'),
          ],
        ),
        const SizedBox(height: 10),
        // Estado de armado: la clave para que no alerte con cualquier movimiento.
        if (on)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kPanel,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: armed
                    ? kSafe.withValues(alpha: .55)
                    : kWatch.withValues(alpha: .55),
              ),
            ),
            child: Row(
              children: [
                Text(armed ? '🛡️' : '✋', style: const TextStyle(fontSize: 22)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        armed
                            ? 'ARMADO — el teléfono está quieto y vigilando'
                            : 'EN USO — no vigila mientras lo mueves',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: armed ? kSafe : kWatch,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        armed
                            ? 'Quieto hace ${stillSecs.round()} s · sensor a ${rate.round()} Hz'
                            : 'Déjalo quieto sobre una superficie firme: se arma en '
                                  '${(45 - stillSecs).clamp(0, 45).round()} s',
                        style: const TextStyle(fontSize: 11, color: kMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        const Text(
          'Apoya el teléfono sobre una mesa o el suelo y actívalo. Igual que la red '
          'de detección de Google en Android, el sismógrafo solo vigila cuando el '
          'teléfono lleva un rato QUIETO: caminar o tenerlo en la mano produce '
          'oscilaciones de 1–3 Hz idénticas a una onda sísmica, así que la única '
          'forma seria de no dar falsas alarmas es no vigilar mientras se usa.\n\n'
          'Cuando está armado, el detector trabaja en dos etapas: el algoritmo '
          'sismológico STA/LTA con filtro pasa-banda (0.4–5 Hz) marca los candidatos, '
          'y un clasificador estilo MyShake (UC Berkeley) descarta lo que no es sismo: '
          'giroscopio (si el teléfono rota, alguien lo está manipulando), golpes secos '
          '(factor de cresta), objetos vibrando (cruces por cero y energía de alta '
          'frecuencia) y falta de reposo previo.',
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
          child: Text(
            on ? '⏸️ Detener sismógrafo' : '▶️ Activar sismógrafo',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _gauge(String value, String label) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kLine),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 10, color: kMuted)),
        ],
      ),
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
    canvas.drawLine(
      Offset(0, h / 2),
      Offset(w, h / 2),
      Paint()..color = kMuted.withValues(alpha: .25),
    );
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
