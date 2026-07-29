import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:alerta_sismica/detector.dart';
import 'package:alerta_sismica/main.dart';
import 'package:alerta_sismica/sources.dart';

void main() {
  test('dedup: fusiona el mismo sismo de varios catálogos, gana la prioridad', () {
    final t = DateTime(2026, 7, 9, 12, 0, 0);
    Quake q(String id, String source, DateTime time, double la, double lo) =>
        Quake.at(
            id: id,
            mag: 4.0,
            lat: la,
            lon: lo,
            depth: 10,
            time: time,
            place: 'x',
            source: source,
            userLat: 4.7,
            userLon: -74.1);
    final merged = dedupQuakes([
      // mismo evento visto por SGC y USGS (30 s y ~15 km de diferencia)
      q('sgc_1', 'SGC', t, 4.50, -73.90),
      q('usgs_1', 'USGS', t.add(const Duration(seconds: 30)), 4.60, -73.85),
      // evento distinto (mismo momento pero a 400 km)
      q('usgs_2', 'USGS', t, 8.00, -73.90),
    ]);
    expect(merged.length, 2);
    expect(merged.any((x) => x.id == 'sgc_1'), isTrue); // ganó el SGC
    expect(merged.any((x) => x.id == 'usgs_1'), isFalse);
  });

  test('STA/LTA: no dispara con ruido de fondo', () {
    final d = StaLtaDetector(sampleRate: 50);
    final rnd = math.Random(7);
    var triggered = false;
    // 60 s de ruido leve (teléfono sobre una mesa)
    for (var i = 0; i < 3000; i++) {
      final st = d.process(0.03 * (rnd.nextDouble() - 0.5));
      if (st.triggered) triggered = true;
    }
    expect(triggered, isFalse);
  });

  test('etapa 2: golpes/vibración de alta frecuencia NO disparan la alarma', () {
    final d = StaLtaDetector(sampleRate: 50);
    final rnd = math.Random(7);
    // 20 s de calibración con ruido leve
    for (var i = 0; i < 1000; i++) {
      d.process(0.03 * (rnd.nextDouble() - 0.5));
    }
    // 1.5 s de golpeteo/arrastre: ráfagas amortiguadas a 18 Hz cada 0.15 s
    // (como golpear la mesa repetidamente o arrastrarla)
    var triggers = 0;
    final vetos = <String>[];
    for (var i = 0; i < 150; i++) {
      final t = i / 50.0;
      final tBurst = t % 0.15; // tiempo dentro de la ráfaga
      final x = 12.0 * math.exp(-tBurst / 0.04) * math.sin(2 * math.pi * 18 * t);
      final st = d.process(x);
      if (st.triggered) triggers++;
      if (st.veto != null) vetos.add(st.veto!);
    }
    expect(triggers, 0); // nunca suena la alarma
    expect(vetos, isNotEmpty); // y fue la etapa 2 la que lo descartó
  });

  test('etapa 2: candidato tras manipulación continua queda vetado', () {
    final d = StaLtaDetector(sampleRate: 50);
    final rnd = math.Random(7);
    // 10 s quieto (calibración)
    for (var i = 0; i < 500; i++) {
      d.process(0.03 * (rnd.nextDouble() - 0.5));
    }
    // 12 s de movimiento continuo moderado (teléfono en la mano, ~1.5 Hz)
    for (var i = 0; i < 600; i++) {
      final t = i / 50.0;
      d.process(0.5 * math.sin(2 * math.pi * 1.5 * t) +
          0.05 * (rnd.nextDouble() - 0.5));
    }
    // Sacudida fuerte estando en movimiento: candidato, pero debe vetarse
    // por falta de reposo previo (política MyShake/Google).
    var triggers = 0;
    for (var i = 0; i < 150; i++) {
      final t = i / 50.0;
      final st = d.process(2.5 * math.sin(2 * math.pi * 3 * t));
      if (st.triggered) triggers++;
    }
    expect(triggers, 0);
  });

  test('STA/LTA: dispara con onda sísmica sostenida y luego respeta cooldown', () {
    final d = StaLtaDetector(sampleRate: 50);
    final rnd = math.Random(7);
    // 20 s de calibración con ruido leve
    for (var i = 0; i < 1000; i++) {
      d.process(0.03 * (rnd.nextDouble() - 0.5));
    }
    // 3 s de oscilación fuerte a 3 Hz (dentro de la banda sísmica)
    var triggers = 0;
    for (var i = 0; i < 150; i++) {
      final t = i / 50.0;
      final st = d.process(1.8 * math.sin(2 * math.pi * 3 * t));
      if (st.triggered) triggers++;
    }
    expect(triggers, 1); // dispara una sola vez (cooldown activo)
  });
  test('haversine: Bogotá–Villavicencio ≈ 75-80 km', () {
    final d = haversineKm(4.7110, -74.0721, 4.1420, -73.6266);
    expect(d, greaterThan(60));
    expect(d, lessThan(100));
  });

  test('intensidad sentida decae con la distancia', () {
    final cerca = feltIntensity(5.0, 30);
    final lejos = feltIntensity(5.0, 400);
    expect(cerca, greaterThan(lejos));
  });

  test('color por magnitud', () {
    expect(magColor(3.0), kMagLow);
    expect(magColor(4.5), kMagMid);
    expect(magColor(6.0), kMagHigh);
  });
}
