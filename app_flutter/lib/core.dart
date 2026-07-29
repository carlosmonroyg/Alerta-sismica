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
  });

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
    );
  }
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

enum RiskLevel { safe, watch, danger }
