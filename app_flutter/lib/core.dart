// Modelo, paleta y utilidades compartidas de Alerta Sísmica.

import 'dart:math' as math;

import 'package:flutter/material.dart';

// ---------------- Paleta (misma de la PWA) ----------------
const kBg = Color(0xFF0B1120);
const kPanel = Color(0xFF111A2E);
const kPanel2 = Color(0xFF18233C);
const kLine = Color(0xFF223050);
const kText = Color(0xFFE8EEFC);
const kMuted = Color(0xFF8FA3C8);
const kSafe = Color(0xFF22C55E);
const kWatch = Color(0xFFF59E0B);
const kDanger = Color(0xFFEF4444);
const kAccent = Color(0xFF38BDF8);
const kMagLow = Color(0xFF4ADE80);
const kMagMid = Color(0xFFFBBF24);
const kMagHigh = Color(0xFFF87171);

Color magColor(double m) => m >= 5.5 ? kMagHigh : (m >= 4 ? kMagMid : kMagLow);

// ---------------- Utilidades ----------------
double haversineKm(double la1, double lo1, double la2, double lo2) {
  const r = 6371.0;
  final d = math.pi / 180;
  final a = math.pow(math.sin((la2 - la1) * d / 2), 2) +
      math.cos(la1 * d) * math.cos(la2 * d) * math.pow(math.sin((lo2 - lo1) * d / 2), 2);
  return 2 * r * math.asin(math.sqrt(a.toDouble()));
}

double bearingRad(double la1, double lo1, double la2, double lo2) {
  final d = math.pi / 180;
  final y = math.sin((lo2 - lo1) * d) * math.cos(la2 * d);
  final x = math.cos(la1 * d) * math.sin(la2 * d) -
      math.sin(la1 * d) * math.cos(la2 * d) * math.cos((lo2 - lo1) * d);
  return math.atan2(y, x); // 0 = norte
}

/// Intensidad Mercalli aproximada sentida en la ubicación del usuario.
double feltIntensity(double mag, double distKm) =>
    1.5 * mag - 3.0 * (math.log(math.max(distKm, 5) + 10) / math.ln10) + 3.0;

String timeAgo(DateTime t) {
  final s = DateTime.now().difference(t).inSeconds;
  if (s < 60) return 'hace segundos';
  if (s < 3600) return 'hace ${s ~/ 60} min';
  if (s < 86400) return 'hace ${s ~/ 3600} h';
  final days = s ~/ 86400;
  return 'hace $days día${days > 1 ? 's' : ''}';
}

// ---------------- Modelo ----------------
class Quake {
  final String id;
  final double mag, lat, lon, depth, dist, brg, felt;
  final DateTime time;
  final String place;

  /// Catálogo de origen: 'SGC', 'USGS' o 'EMSC'.
  final String source;

  /// Distancia de la solución MÁS CERCANA de las que se fusionaron en este
  /// evento. Normalmente es [dist]; difiere cuando varios catálogos publican
  /// el mismo temblor con epicentros separados.
  ///
  /// Solo se usa para decidir si el sismo entra en el radio del usuario, y
  /// existe porque ese radio no puede depender de qué agencia acertó a poner
  /// el epicentro unos kilómetros más acá: el sismo de Los Santos del
  /// 2026-08-26 lo situaron a 290 km (EMSC), 295 km (USGS) y 303 km (SGC), y
  /// con el radio en 300 km el usuario recibía un M4.9 del USGS en vez del
  /// M5.1 oficial, solo porque la solución del SGC caía 3 km fuera.
  final double distMin;

  Quake({
    required this.id,
    required this.mag,
    required this.lat,
    required this.lon,
    required this.depth,
    required this.dist,
    required this.brg,
    required this.felt,
    required this.time,
    required this.place,
    required this.source,
    double? distMin,
  }) : distMin = distMin ?? dist;

  /// Copia el sismo cambiando solo la distancia de la solución más cercana.
  /// La usa la fusión de catálogos: los datos mostrados siguen siendo los de
  /// la fuente prioritaria, pero el radio se decide con la solución más
  /// cercana del grupo.
  Quake conDistMin(double d) => Quake(
        id: id,
        mag: mag,
        lat: lat,
        lon: lon,
        depth: depth,
        dist: dist,
        brg: brg,
        felt: felt,
        time: time,
        place: place,
        source: source,
        distMin: d,
      );

  /// Construye el sismo calculando distancia/rumbo/intensidad respecto al usuario.
  factory Quake.at({
    required String id,
    required double mag,
    required double lat,
    required double lon,
    required double depth,
    required DateTime time,
    required String place,
    required String source,
    required double userLat,
    required double userLon,
    double? distMin,
  }) {
    final dist = haversineKm(userLat, userLon, lat, lon);
    return Quake(
      id: id,
      mag: mag,
      lat: lat,
      lon: lon,
      depth: depth,
      dist: dist,
      brg: bearingRad(userLat, userLon, lat, lon),
      felt: feltIntensity(mag, dist),
      time: time,
      place: place,
      source: source,
      distMin: distMin,
    );
  }
}

// ---------------- Filtros del usuario ----------------
// Claves de SharedPreferences. Están aquí porque el isolate que atiende los
// avisos push arranca sin estado y tiene que leer los mismos ajustes que la
// pantalla principal escribe: si las claves se separan, el filtro deja de
// aplicarse justo cuando la app está cerrada.
const kPrefRadiusKm = 'radius_km';
const kPrefMinMag = 'min_mag';

/// Valores por defecto, iguales a los de la pantalla principal.
const kRadiusKmPorDefecto = 500.0;
const kMinMagPorDefecto = 2.5;

/// Decide si un sismo merece molestar al usuario según lo que configuró.
///
/// Se aplica igual en los cuatro caminos de aviso —lista, WebSocket del EMSC,
/// servicio en segundo plano y push— para que el ajuste signifique lo mismo en
/// todos. Una emergencia se salta el filtro: un sismo capaz de sentirse con
/// fuerza se avisa aunque el usuario haya subido la magnitud mínima, porque
/// ahí ya no es información, es seguridad. [conUbicacion] en falso omite el
/// criterio de distancia, que sin coordenadas no significa nada.
bool sismoPasaElFiltro(
  Quake q, {
  required double minMag,
  required double radioKm,
  bool emergencia = false,
  bool conUbicacion = true,
}) {
  if (emergencia) return true;
  if (q.mag < minMag) return false;
  // distMin y no dist: si CUALQUIERA de las soluciones fusionadas cae dentro
  // del radio, el sismo entra. Un borde duro sobre un epicentro difuso no
  // puede decidir si el usuario se entera de un M5.1.
  if (conUbicacion && q.distMin > radioKm) return false;
  return true;
}

class City {
  final String name;
  final double? lat, lon;
  final bool gps;
  const City(this.name, {this.lat, this.lon, this.gps = false});
}

const cities = [
  City('Bogotá', lat: 4.7110, lon: -74.0721),
  City('Villavicencio', lat: 4.1420, lon: -73.6266),
  City('Mi ubicación GPS', gps: true),
];

/// Zona geográfica de ~111 km que se usa como "tema" de las notificaciones
/// push. Debe coincidir EXACTAMENTE con zonaDe() del servidor
/// (server/src/geo.js): si las dos fórmulas se separan, el teléfono queda
/// suscrito a un tema al que nadie publica y deja de recibir avisos.
String zonaFcm(double lat, double lon) =>
    'z_${lat.floor()}_${lon.floor()}';

enum RiskLevel { safe, watch, danger }
