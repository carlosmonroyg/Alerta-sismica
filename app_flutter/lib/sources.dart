// Fuentes de datos sísmicos: SGC (catálogo oficial de Colombia), USGS y EMSC,
// consultadas en paralelo y fusionadas con eliminación de duplicados
// (el mismo sismo suele aparecer en varios catálogos). Prioridad: SGC > USGS > EMSC.
//
// Además, EmscLiveFeed mantiene el WebSocket de EMSC/SeismicPortal abierto:
// los sismos nuevos llegan empujados en segundos, sin esperar el sondeo.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'core.dart';

const _timeout = Duration(seconds: 20);

class FetchResult {
  final List<Quake> quakes;
  final List<String> sourcesOk;
  const FetchResult(this.quakes, this.sourcesOk);
}

/// Consulta SGC + USGS + EMSC en paralelo. Nunca lanza: las fuentes caídas
/// simplemente no aparecen en [FetchResult.sourcesOk].
Future<FetchResult> fetchAllSources({
  required double lat,
  required double lon,
  required double radiusKm,
  required double minMag,
}) async {
  Future<List<Quake>?> guard(Future<List<Quake>> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return null;
    }
  }

  // El orden define la prioridad en la deduplicación.
  final results = await Future.wait([
    guard(() => _fetchSgc(lat, lon, radiusKm, minMag)),
    guard(() => _fetchUsgs(lat, lon, radiusKm, minMag)),
    guard(() => _fetchEmsc(lat, lon, radiusKm, minMag)),
  ]);
  const names = ['SGC', 'USGS', 'EMSC'];
  final ok = <String>[];
  final all = <Quake>[];
  for (var i = 0; i < results.length; i++) {
    if (results[i] != null) {
      ok.add(names[i]);
      all.addAll(results[i]!);
    }
  }
  return FetchResult(dedupQuakes(all), ok);
}

/// Fusiona sismos repetidos entre catálogos: mismo evento si ocurre a menos
/// de 120 s y 60 km de otro ya aceptado. Gana el que aparezca primero en la
/// lista (por eso las fuentes se agregan en orden de prioridad).
List<Quake> dedupQuakes(List<Quake> all) {
  final merged = <Quake>[];
  for (final q in all) {
    final isDup = merged.any((m) =>
        m.time.difference(q.time).abs().inSeconds < 120 &&
        haversineKm(m.lat, m.lon, q.lat, q.lon) < 60);
    if (!isDup) merged.add(q);
  }
  merged.sort((a, b) => b.time.compareTo(a.time));
  return merged;
}

DateTime get _cutoff => DateTime.now().toUtc().subtract(const Duration(days: 7));

// ---------------- USGS ----------------
Future<List<Quake>> _fetchUsgs(
    double lat, double lon, double radiusKm, double minMag) async {
  final url = Uri.parse(
      'https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson'
      '&latitude=$lat&longitude=$lon&maxradiuskm=${radiusKm.round()}'
      '&minmagnitude=$minMag&orderby=time&limit=120'
      '&starttime=${_cutoff.toIso8601String()}');
  final r = await http.get(url).timeout(_timeout);
  if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
  final j = jsonDecode(r.body) as Map<String, dynamic>;
  final feats = (j['features'] as List).cast<Map<String, dynamic>>();
  return feats.map((f) {
    final coords = (f['geometry']['coordinates'] as List).cast<num>();
    final props = f['properties'] as Map<String, dynamic>;
    return Quake.at(
      id: 'usgs_${f['id']}',
      mag: (props['mag'] as num?)?.toDouble() ?? 0,
      lat: coords[1].toDouble(),
      lon: coords[0].toDouble(),
      depth: coords.length > 2 ? coords[2].toDouble() : 0.0,
      time: DateTime.fromMillisecondsSinceEpoch((props['time'] as num).toInt()),
      place: (props['place'] as String?) ?? 'Ubicación desconocida',
      source: 'USGS',
      userLat: lat,
      userLon: lon,
    );
  }).toList();
}

// ---------------- SGC (Servicio Geológico Colombiano) ----------------
// El catálogo oficial devuelve páginas de 100 eventos ordenados del más
// reciente al más antiguo; el filtrado se hace del lado del cliente
// (igual que el visor oficial en sgc.gov.co/sismos).
Future<List<Quake>> _fetchSgc(
    double lat, double lon, double radiusKm, double minMag) async {
  final out = <Quake>[];
  final cutoff = _cutoff;
  for (var page = 1; page <= 3; page++) {
    final r = await http
        .post(
          Uri.parse(
              'https://apicatalogador.sgc.gov.co/api/events/search/?page=$page'),
          headers: {'Content-Type': 'application/json'},
          body: '{}',
        )
        .timeout(_timeout);
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final list =
        ((j['results'] as Map<String, dynamic>)['results'] as List?)
                ?.cast<Map<String, dynamic>>() ??
            [];
    if (list.isEmpty) break;
    var pageHasOld = false;
    for (final e in list) {
      if (e['event_type'] != 'earthquake') continue;
      final t = DateTime.tryParse('${e['utc_time']}Z');
      if (t == null) continue;
      if (t.isBefore(cutoff)) {
        pageHasOld = true;
        continue;
      }
      final mag = (e['magnitude'] as num?)?.toDouble() ?? 0;
      final qlat = (e['latitude'] as num?)?.toDouble();
      final qlon = (e['longitude'] as num?)?.toDouble();
      if (qlat == null || qlon == null || mag < minMag) continue;
      final q = Quake.at(
        id: 'sgc_${e['id']}',
        mag: mag,
        lat: qlat,
        lon: qlon,
        depth: (e['depth'] as num?)?.toDouble() ?? 0,
        time: t.toLocal(),
        place: (e['place'] as String?) ?? 'Colombia',
        source: 'SGC',
        userLat: lat,
        userLon: lon,
      );
      if (q.dist <= radiusKm) out.add(q);
    }
    if (pageHasOld) break; // ya llegamos a eventos de hace más de 7 días
  }
  return out;
}

// ---------------- EMSC ----------------
Future<List<Quake>> _fetchEmsc(
    double lat, double lon, double radiusKm, double minMag) async {
  final radiusDeg = (radiusKm / 111.0).toStringAsFixed(2);
  final url = Uri.parse(
      'https://www.seismicportal.eu/fdsnws/event/1/query?format=json'
      '&latitude=$lat&longitude=$lon&maxradius=$radiusDeg'
      '&minmagnitude=$minMag&orderby=time&limit=150'
      '&starttime=${_cutoff.toIso8601String()}');
  final r = await http.get(url).timeout(_timeout);
  if (r.statusCode == 204) return []; // EMSC responde 204 sin resultados
  if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
  final j = jsonDecode(r.body) as Map<String, dynamic>;
  final feats = (j['features'] as List).cast<Map<String, dynamic>>();
  return feats
      .map((f) => quakeFromEmscProps(
          f['properties'] as Map<String, dynamic>, lat, lon))
      .whereType<Quake>()
      .toList();
}

/// Convierte las properties de un feature EMSC (REST o WebSocket) en Quake.
Quake? quakeFromEmscProps(
    Map<String, dynamic> props, double userLat, double userLon) {
  final qlat = (props['lat'] as num?)?.toDouble();
  final qlon = (props['lon'] as num?)?.toDouble();
  final time = DateTime.tryParse((props['time'] as String?) ?? '');
  if (qlat == null || qlon == null || time == null) return null;
  return Quake.at(
    id: 'emsc_${props['unid']}',
    mag: (props['mag'] as num?)?.toDouble() ?? 0,
    lat: qlat,
    lon: qlon,
    depth: ((props['depth'] as num?)?.toDouble() ?? 0).abs(),
    time: time.toLocal(),
    place: (props['flynn_region'] as String?) ?? 'Región desconocida',
    source: 'EMSC',
    userLat: userLat,
    userLon: userLon,
  );
}

// ---------------- WebSocket EMSC en tiempo real ----------------
class EmscLiveFeed {
  EmscLiveFeed({required this.onEvent, this.onStateChange});

  /// Se invoca con las properties del evento nuevo/actualizado.
  final void Function(Map<String, dynamic> props) onEvent;
  final void Function(bool connected)? onStateChange;

  static final _uri =
      Uri.parse('wss://www.seismicportal.eu/standing_order/websocket');

  WebSocketChannel? _channel;
  Timer? _retryTimer;
  bool _stopped = false;
  bool connected = false;

  void start() {
    _stopped = false;
    _connect();
  }

  void stop() {
    _stopped = true;
    _retryTimer?.cancel();
    _channel?.sink.close();
    _setConnected(false);
  }

  void _setConnected(bool v) {
    if (connected == v) return;
    connected = v;
    onStateChange?.call(v);
  }

  void _connect() {
    if (_stopped) return;
    try {
      _channel = WebSocketChannel.connect(_uri);
      _channel!.stream.listen(
        (msg) {
          _setConnected(true);
          try {
            final j = jsonDecode(msg as String) as Map<String, dynamic>;
            final action = j['action'];
            if (action == 'create' || action == 'update') {
              final props = (j['data']
                  as Map<String, dynamic>)['properties'] as Map<String, dynamic>;
              onEvent(props);
            }
          } catch (_) {}
        },
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
        cancelOnError: true,
      );
      // Si no llega ningún mensaje, igualmente considerarse conectado
      // cuando el canal quede listo.
      _channel!.ready.then((_) => _setConnected(true)).catchError((_) {});
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _setConnected(false);
    if (_stopped) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 20), _connect);
  }
}
