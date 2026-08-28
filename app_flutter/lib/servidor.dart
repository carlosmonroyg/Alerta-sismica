// Cliente del servidor de Alerta Sísmica.
//
// El servidor es opcional: si no está configurado, la app sigue funcionando
// sola contra los catálogos (como hasta ahora). Cuando sí lo está:
//   · los sismos llegan ya filtrados y fusionados → el usuario deja de bajar
//     ~13 MB/día de los catálogos;
//   · el teléfono aporta sus detecciones para el consenso comunitario;
//   · el servidor puede enviarle alertas aunque la app esté cerrada.
//
// PRIVACIDAD: la ubicación exacta nunca sale del teléfono. Antes de enviarla
// se redondea a 0,1° (~11 km), y el servidor la guarda aún más difusa.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'core.dart';

class Servidor {
  /// URL del servidor fijada al compilar:
  ///   flutter build apk --dart-define=SERVIDOR_URL=https://mi-servidor
  /// Así el usuario final no tiene que escribir nada: la app se registra
  /// sola al abrirse. Los ajustes permiten cambiarla para pruebas.
  static const porDefecto = String.fromEnvironment('SERVIDOR_URL');

  /// URL base en uso (sin barra final). Vacío = trabajar sin servidor.
  static String baseUrl = porDefecto;

  static bool get activo => baseUrl.trim().isNotEmpty;

  static const _timeout = Duration(seconds: 20);

  /// Redondea a 0,1° para no revelar la ubicación exacta del usuario.
  static double difusa(double v) => (v * 10).roundToDouble() / 10;

  static Uri _u(String ruta, [Map<String, String>? q]) =>
      Uri.parse('${baseUrl.trim().replaceAll(RegExp(r"/+$"), "")}$ruta')
          .replace(queryParameters: q);

  /// Registra el teléfono y devuelve el tema al que debe suscribirse en FCM.
  static Future<String?> registrar({
    required String anonId,
    required double lat,
    required double lon,
    required double radioKm,
    required double minMag,
    String? tokenFcm,
    String? municipio,
  }) async {
    if (!activo) return null;
    try {
      final r = await http
          .post(_u('/v1/dispositivos'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'id': anonId,
                'token': tokenFcm,
                'lat': difusa(lat),
                'lon': difusa(lon),
                'radioKm': radioKm,               
                'minMag': minMag,
                'municipio': municipio,
              }))
          .timeout(_timeout);
      if (r.statusCode != 200) return null;
      return (jsonDecode(r.body) as Map<String, dynamic>)['tema'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Reporta un disparo del sismógrafo para el consenso comunitario.
  static Future<bool> enviarDeteccion({
    required String anonId,
    required double lat,
    required double lon,
    double? intensidad,
    DateTime? ocurrio,
  }) async {
    if (!activo) return false;
    try {
      final r = await http
          .post(_u('/v1/detecciones'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'id': anonId,
                'lat': difusa(lat),
                'lon': difusa(lon),
                'intensidad': intensidad,
                'ocurrio': (ocurrio ?? DateTime.now()).millisecondsSinceEpoch,
              }))
          .timeout(_timeout);
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Sismos ya recolectados y deduplicados por el servidor.
  /// Devuelve null si no hay servidor o si falla (para caer a los catálogos).
  static Future<List<Quake>?> traerSismos({
    required double lat,
    required double lon,
    required double radiusKm,
    required double minMag,
    int dias = 7,
  }) async {
    if (!activo) return null;
    try {
      final r = await http.get(_u('/v1/sismos', {
        'lat': lat.toStringAsFixed(4),
        'lon': lon.toStringAsFixed(4),
        'radio': radiusKm.round().toString(),
        'mag': minMag.toString(),
        'dias': dias.toString(),
      })).timeout(_timeout);
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final lista = (j['sismos'] as List).cast<Map<String, dynamic>>();
      return lista
          // Defensa por si el servidor es de una versión anterior y no
          // entiende el parámetro `mag`: el filtro del usuario manda igual.
          .where((s) => ((s['mag'] as num?)?.toDouble() ?? 0) >= minMag)
          // El servidor manda distMin: la distancia de la solución más
          // cercana del grupo fusionado. Sin adoptarla, la app recalcularía
          // la distancia desde el epicentro de la fuente prioritaria y
          // volvería a descartar por radio justo lo que el servidor acababa
          // de incluir.
          .map((s) => Quake.at(
                distMin: (s['distMin'] as num?)?.toDouble(),
                id: s['id'] as String,
                mag: (s['mag'] as num).toDouble(),
                lat: (s['lat'] as num).toDouble(),
                lon: (s['lon'] as num).toDouble(),
                depth: (s['prof'] as num?)?.toDouble() ?? 0,
                time: DateTime.fromMillisecondsSinceEpoch(
                    (s['ocurrio'] as num).toInt()),
                place: (s['lugar'] as String?) ?? 'Ubicación desconocida',
                source: (s['fuente'] as String?) ?? 'SERVIDOR',
                userLat: lat,
                userLon: lon,
              ))
          .toList();
    } catch (_) {
      return null;
    }
  }
}
