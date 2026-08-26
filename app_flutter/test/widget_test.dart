import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:alerta_sismica/detector.dart';
import 'package:alerta_sismica/main.dart';
import 'package:alerta_sismica/quake_notify.dart';
import 'package:alerta_sismica/servidor.dart';
import 'package:alerta_sismica/sources.dart';

/// Simula un acelerómetro real: entrega muestras a una cadencia fija con
/// marcas de tiempo propias, para que las pruebas no dependan del reloj.
class Sim {
  Sim({this.rate = 50, double armSeconds = 45})
      : d = StaLtaDetector(sampleRate: 50, armSeconds: armSeconds);

  final double rate;
  final StaLtaDetector d;
  int _us = 1000000000;

  DetectorStatus feed(double x, {double gyro = 0}) {
    _us += (1e6 / rate).round();
    return d.process(x, gyroMag: gyro, timestampUs: _us);
  }

  /// Teléfono quieto sobre una mesa durante [segundos].
  void reposar(int segundos) {
    final rnd = math.Random(11);
    for (var i = 0; i < (segundos * rate).round(); i++) {
      feed(0.02 * (rnd.nextDouble() - 0.5));
    }
  }
}

void main() {
  test('privacidad: la ubicación se difumina antes de salir del teléfono', () {
    // Villavicencio exacto -> redondeado a 0,1° (~11 km de incertidumbre).
    expect(Servidor.difusa(4.14237), 4.1);
    expect(Servidor.difusa(-73.62661), -73.6);
    expect(Servidor.difusa(4.19), 4.2);
    // El error introducido debe ser suficiente para no revelar la casa,
    // pero no tanto como para cambiar de municipio.
    final err = haversineKm(4.14237, -73.62661,
        Servidor.difusa(4.14237), Servidor.difusa(-73.62661));
    expect(err, lessThan(12));
  });

  test('sin servidor configurado la app trabaja por su cuenta', () async {
    Servidor.baseUrl = '';
    expect(Servidor.activo, isFalse);
    // Sin servidor no se llama a la red: devuelve null y se usan los catálogos.
    expect(
        await Servidor.traerSismos(
            lat: 4.1, lon: -73.6, radiusKm: 300, minMag: 2.5),
        isNull);
    expect(await Servidor.registrar(anonId: 'x', lat: 4.1, lon: -73.6,
        radioKm: 300, minMag: 2.5), isNull);
    expect(
        await Servidor.enviarDeteccion(anonId: 'x', lat: 4.1, lon: -73.6),
        isFalse);
  });

  test('la URL del servidor se normaliza (barras finales)', () {
    Servidor.baseUrl = 'https://ejemplo.workers.dev///';
    expect(Servidor.activo, isTrue);
    Servidor.baseUrl = '   ';
    expect(Servidor.activo, isFalse);
    Servidor.baseUrl = '';
  });
  test('notificación: el payload conserva el epicentro para abrir el mapa', () {
    final q = Quake.at(
      id: 'sgc_123',
      mag: 4.2,
      lat: 4.15,
      lon: -73.63,
      depth: 12,
      time: DateTime(2026, 7, 12, 10, 30),
      place: 'Villavicencio - Meta',
      source: 'SGC',
      userLat: 4.71,
      userLon: -74.07,
    );
    // El usuario podría haberse movido: la distancia se recalcula al abrir.
    final back = decodeQuakePayload(encodeQuakePayload(q), 4.14, -73.62);
    expect(back, isNotNull);
    expect(back!.id, q.id);
    expect(back.lat, q.lat);
    expect(back.lon, q.lon);
    expect(back.place, q.place);
    expect(back.source, 'SGC');
    expect(back.dist, lessThan(5)); // ahora está prácticamente encima
    expect(quakeNotificationId(back), quakeNotificationId(q));
  });

  test('notificación: payload inválido no rompe la app', () {
    expect(decodeQuakePayload(null, 0, 0), isNull);
    expect(decodeQuakePayload('', 0, 0), isNull);
    expect(decodeQuakePayload('no-es-json', 0, 0), isNull);
    expect(decodeQuakePayload('{"id":"x"}', 0, 0), isNull);
  });

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

  test('dedup: Los Santos 2026-08-26, tal como lo sirvió el servidor', () {
    // Datos REALES de /v1/sismos. Un solo sismo publicado por los tres
    // catálogos con 1,4 s de diferencia y epicentros a 5-15 km entre sí. La
    // app lo mostraba como tres sismos de M5.1, M5.3 y M4.9.
    //
    // La lista llega ordenada por TIEMPO (así responde el servidor), no por
    // prioridad de fuente: es justo el caso que antes elegía mal al ganador.
    Quake q(String id, String fuente, double mag, int ms, double la, double lo,
            double prof) =>
        Quake.at(
          id: id,
          mag: mag,
          lat: la,
          lon: lo,
          depth: prof,
          time: DateTime.fromMillisecondsSinceEpoch(ms),
          place: 'Los Santos - Santander',
          source: fuente,
          userLat: 4.142,
          userLon: -73.627,
        );

    final merged = dedupQuakes([
      q('sgc_SGC2026quikpc', 'SGC', 5.1, 1787762716000, 6.8215, -73.114, 149),
      q('emsc_20260826_0000228', 'EMSC', 5.3, 1787762715350, 6.6909, -73.0824,
          157),
      q('usgs_us7000tbzn', 'USGS', 4.9, 1787762714599, 6.737, -73.0596, 159.9),
    ]);

    expect(merged.length, 1, reason: 'es un solo sismo, no tres');
    expect(merged.single.source, 'SGC', reason: 'la fuente oficial manda');
    expect(merged.single.mag, 5.1);
  });

  test('borde del radio: un M5.1 no se pierde porque el SGC lo situara 3 km '
      'más lejos', () {
    // Caso real. Desde Villavicencio, el sismo de Los Santos quedó a 290 km
    // según el EMSC, 295 km según el USGS y 303 km según el SGC. Con el radio
    // en 300 km, la solución oficial caía fuera y el usuario veía el M4.9 del
    // USGS en vez del M5.1 del SGC.
    Quake q(String fuente, double mag, double la, double lo, int ms) =>
        Quake.at(
          id: fuente,
          mag: mag,
          lat: la,
          lon: lo,
          depth: 150,
          time: DateTime.fromMillisecondsSinceEpoch(ms),
          place: 'Los Santos',
          source: fuente,
          userLat: 4.1420,
          userLon: -73.6266,
        );

    final merged = dedupQuakes([
      q('SGC', 5.1, 6.8215, -73.114, 1787762716000),
      q('EMSC', 5.3, 6.6909, -73.0824, 1787762715350),
      q('USGS', 4.9, 6.737, -73.0596, 1787762714599),
    ]);

    expect(merged.length, 1);
    final e = merged.single;
    expect(e.source, 'SGC', reason: 'se muestran los datos oficiales');
    expect(e.mag, 5.1);
    expect(e.dist, greaterThan(300), reason: 'el epicentro del SGC sí está fuera');
    expect(e.distMin, lessThan(300),
        reason: 'pero el del EMSC está dentro, y eso es lo que decide');

    // Con radio 300 el sismo DEBE entrar, mostrando la magnitud del SGC.
    expect(
      sismoPasaElFiltro(e, minMag: 2.5, radioKm: 300),
      isTrue,
      reason: 'un M5.1 no puede desaparecer por 3 km de desacuerdo entre agencias',
    );
    // Y un radio realmente pequeño lo sigue dejando fuera.
    expect(sismoPasaElFiltro(e, minMag: 2.5, radioKm: 100), isFalse);
  });

  test('dedup: el ganador no depende del orden de la lista', () {
    final t = DateTime(2026, 8, 26, 14, 5, 0);
    Quake q(String fuente, int desfaseS) => Quake.at(
          id: fuente,
          mag: 5.0,
          lat: 6.8,
          lon: -73.1,
          depth: 150,
          time: t.add(Duration(seconds: desfaseS)),
          place: 'x',
          source: fuente,
          userLat: 4.142,
          userLon: -73.627,
        );

    // El EMSC va primero Y es el más reciente: aun así debe ganar el SGC.
    final merged = dedupQuakes([q('EMSC', 40), q('USGS', 20), q('SGC', 0)]);
    expect(merged.length, 1);
    expect(merged.single.source, 'SGC');
  });

  test('STA/LTA: no dispara con ruido de fondo', () {
    final s = Sim();
    final rnd = math.Random(7);
    var triggered = false;
    // 60 s de ruido leve (teléfono sobre una mesa)
    for (var i = 0; i < 3000; i++) {
      if (s.feed(0.03 * (rnd.nextDouble() - 0.5)).triggered) triggered = true;
    }
    expect(triggered, isFalse);
  });

  test('etapa 2: golpes/vibración de alta frecuencia NO disparan la alarma', () {
    final s = Sim();
    s.reposar(60); // el teléfono lleva un minuto quieto: detector armado
    expect(s.d.armed, isTrue);
    // 3 s de golpeteo/arrastre: ráfagas amortiguadas a 18 Hz cada 0.15 s
    // (como golpear la mesa repetidamente o arrastrarla)
    var triggers = 0;
    final vetos = <String>[];
    for (var i = 0; i < 150; i++) {
      final t = i / 50.0;
      final tBurst = t % 0.15; // tiempo dentro de la ráfaga
      final x = 12.0 * math.exp(-tBurst / 0.04) * math.sin(2 * math.pi * 18 * t);
      final st = s.feed(x);
      if (st.triggered) triggers++;
      if (st.veto != null) vetos.add(st.veto!);
    }
    expect(triggers, 0); // nunca suena la alarma
    expect(vetos, isNotEmpty); // y fue la etapa 2 la que lo descartó
  });

  test('armado: CAMINAR con el teléfono no dispara la alarma', () {
    final s = Sim();
    final rnd = math.Random(3);
    s.reposar(60);
    expect(s.d.armed, isTrue, reason: 'debe armarse tras 45 s quieto');
    // Lo levanta y camina 20 s: oscilación de 2 Hz a 1.5 m/s² (plena banda
    // sísmica) con el brazo rotando. Esto es lo que disparaba falsas alarmas.
    var triggers = 0;
    for (var i = 0; i < 1000; i++) {
      final t = i / 50.0;
      final st = s.feed(
        1.5 * math.sin(2 * math.pi * 2 * t) + 0.1 * (rnd.nextDouble() - 0.5),
        gyro: 0.8,
      );
      if (st.triggered) triggers++;
    }
    expect(triggers, 0);
    expect(s.d.armed, isFalse, reason: 'al moverse debe desarmarse');
  });

  test('armado: caminar sin rotación (bolsillo) tampoco dispara', () {
    // Sin la señal del giroscopio, lo que salva es que el movimiento lleva
    // rato: un sismo empieza de golpe tras el reposo, caminar no.
    final s = Sim();
    s.reposar(60);
    var triggers = 0;
    for (var i = 0; i < 1500; i++) {
      final t = i / 50.0;
      if (s.feed(1.2 * math.sin(2 * math.pi * 2.2 * t)).triggered) triggers++;
    }
    // A lo sumo puede colarse el arranque (indistinguible de un sismo real),
    // pero no puede seguir alarmando durante los 30 s de caminata.
    expect(triggers, lessThanOrEqualTo(1));
  });

  test('armado: sacudir el teléfono recién levantado no dispara', () {
    final s = Sim();
    s.reposar(60);
    // Lo toma (2 s de manipulación) y lo sacude fuerte a 3 Hz
    for (var i = 0; i < 100; i++) {
      s.feed(0.6 * math.sin(2 * math.pi * 1.2 * (i / 50.0)), gyro: 1.2);
    }
    var triggers = 0;
    for (var i = 0; i < 250; i++) {
      final t = i / 50.0;
      final st = s.feed(3.0 * math.sin(2 * math.pi * 3 * t), gyro: 1.0);
      if (st.triggered) triggers++;
    }
    expect(triggers, 0);
  });

  test('el detector mide la frecuencia real del sensor y se reconfigura', () {
    // Se construye asumiendo 50 Hz pero el sensor entrega a 200 Hz: si no se
    // reconfigurara, los filtros y ventanas quedarían corridos y casi
    // cualquier movimiento parecería sismo (el fallo visto en el celular).
    final s = Sim(rate: 200);
    expect(s.d.process(0.0, timestampUs: 0).measuredRate, 50);
    var st = s.feed(0.0);
    for (var i = 0; i < 300; i++) {
      st = s.feed(0.01);
    }
    expect(st.measuredRate, closeTo(200, 10));
  });

  test('SÍ dispara: sismo real con el teléfono en reposo sobre la mesa', () {
    final s = Sim();
    s.reposar(60); // el teléfono llevaba un minuto quieto
    // 3 s de oscilación fuerte a 3 Hz (banda sísmica), sin rotación: el
    // teléfono se desplaza con la mesa, como en un sismo real.
    var triggers = 0;
    for (var i = 0; i < 150; i++) {
      final t = i / 50.0;
      if (s.feed(1.8 * math.sin(2 * math.pi * 3 * t)).triggered) triggers++;
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

  group('filtro de avisos', () {
    // Sismo a ~80 km de Villavicencio, con la magnitud que se le pida.
    Quake sismo(double mag, {double lat = 4.7110, double lon = -74.0721}) =>
        Quake.at(
          id: 'x$mag',
          mag: mag,
          lat: lat,
          lon: lon,
          depth: 10,
          time: DateTime.now(),
          place: 'prueba',
          source: 'USGS',
          userLat: 4.1420,
          userLon: -73.6266,
        );

    test('la magnitud mínima descarta lo que está por debajo', () {
      expect(
        sismoPasaElFiltro(sismo(2.9), minMag: 3.5, radioKm: 500),
        isFalse,
      );
      expect(
        sismoPasaElFiltro(sismo(3.5), minMag: 3.5, radioKm: 500),
        isTrue,
      );
    });

    test('el radio descarta lo lejano aunque supere la magnitud', () {
      // Cerca de Lima: miles de kilómetros, magnitud de sobra.
      final lejos = sismo(6.0, lat: -12.05, lon: -77.04);
      expect(
        sismoPasaElFiltro(lejos, minMag: 2.5, radioKm: 500),
        isFalse,
      );
    });

    test('sin ubicación conocida el radio no puede descartar nada', () {
      // El isolate de push arranca en frío: si no recuperó las coordenadas,
      // toda distancia se mide desde (0,0) y sería basura. Solo filtra por
      // magnitud, que sí es fiable.
      final lejos = sismo(6.0, lat: -12.05, lon: -77.04);
      expect(
        sismoPasaElFiltro(lejos,
            minMag: 2.5, radioKm: 500, conUbicacion: false),
        isTrue,
      );
    });

    test('una emergencia se salta el filtro del usuario', () {
      expect(
        sismoPasaElFiltro(sismo(4.0),
            minMag: 4.5, radioKm: 10, emergencia: true),
        isTrue,
      );
    });
  });
}
