// Detector sísmico de DOS ETAPAS:
//
// Etapa 1 — STA/LTA con filtro pasa-banda (0.4–5 Hz), el algoritmo estándar
// en sismología (Allen, 1978): compara la energía de corto plazo (~0.5 s)
// contra el ruido de fondo de largo plazo (~10 s) y marca un candidato
// cuando la relación supera el umbral de forma sostenida.
//
// Etapa 2 — Clasificador de descarte inspirado en MyShake (UC Berkeley,
// Kong et al. 2016): antes de declarar el evento, analiza la ventana de los
// últimos 2 s para distinguir un sismo real de un golpe o manipulación:
//   · Reposo previo: el teléfono debe llevar quieto los segundos anteriores
//     (igual que MyShake y Google, solo se vigilan teléfonos estacionarios).
//   · Factor de cresta (pico/RMS): un golpe concentra toda la energía en un
//     instante; un sismo la reparte.
//   · Tasa de cruces por cero (en la parte activa): un sismo se mueve a
//     0.5–5 Hz; el "ring" de un golpe vibra a >10 Hz.
//   · Energía de alta frecuencia: si lo que quitó el filtro pasa-bajo pesa
//     más que lo que dejó, era un golpe/roce, no una onda sísmica.

import 'dart:collection';
import 'dart:math' as math;

class DetectorStatus {
  /// Señal filtrada (banda sísmica), con signo — útil para graficar.
  final double filtered;

  /// Promedio de vibración a corto plazo (m/s²).
  final double sta;

  /// Promedio de vibración a largo plazo / ruido de fondo (m/s²).
  final double lta;

  /// Relación STA/LTA: >4 sostenido = candidato a evento.
  final double ratio;

  /// true cuando el LTA ya tiene suficientes muestras (calibrado).
  final bool ready;

  /// true en la muestra exacta en la que se declara el evento (pasó las 2 etapas).
  final bool triggered;

  /// Si la etapa 2 descartó un candidato, el motivo (null en caso contrario).
  final String? veto;

  const DetectorStatus({
    required this.filtered,
    required this.sta,
    required this.lta,
    required this.ratio,
    required this.ready,
    required this.triggered,
    this.veto,
  });
}

class StaLtaDetector {
  StaLtaDetector({this.sampleRate = 50});

  /// Muestras por segundo del acelerómetro.
  final double sampleRate;

  // Banda sísmica de interés.
  static const double _fHighPass = 0.4;
  static const double _fLowPass = 5.0;

  // Umbrales etapa 1. La alarma solo tiene sentido con sacudida claramente
  // perceptible (un sismo que amerite protegerse produce >>1 m/s²); umbrales
  // más bajos hacen que el simple inicio de un movimiento suave del teléfono
  // parezca un sismo débil.
  static const double _ratioOn = 4.0;
  static const double _staMin = 0.35; // m/s² sostenidos
  static const double _peakMin = 0.5; // m/s² de pico instantáneo reciente
  static const double _sustainS = 0.4;
  static const double _cooldownS = 30;
  static const double _vetoCooldownS = 2;
  static const double _ltaFloor = 0.015; // m/s²

  // Umbrales etapa 2 (clasificador anti-golpes).
  static const double _crestMax = 6.0; // pico/RMS máximo de un sismo
  static const double _zcMaxPerSec = 16; // cruces/s máx (≈8 Hz)
  static const double _hfRatioMax = 1.5; // energía HF / energía banda sísmica
  static const double _stillBlockThresh = 0.10; // m/s² para "bloque quieto"
  static const double _stillFracMin = 0.7; // fracción de bloques quietos

  late final double _aHp = _alpha(_fHighPass);
  late final double _aLp = _alpha(_fLowPass);
  late final int _staN = (0.5 * sampleRate).round();
  late final int _ltaN = (10 * sampleRate).round();
  late final int _sustainN = (_sustainS * sampleRate).round();
  late final int _winN = (2 * sampleRate).round(); // ventana etapa 2
  late final int _blockN = (0.5 * sampleRate).round(); // bloques de quietud

  double _alpha(double fc) {
    final dt = 1 / sampleRate;
    final rc = 1 / (2 * math.pi * fc);
    return dt / (rc + dt);
  }

  double _emaSlow = 0, _lp = 0;
  bool _first = true;
  final Queue<double> _staBuf = Queue(), _ltaBuf = Queue();
  double _staSum = 0, _ltaSum = 0;
  int _hot = 0, _cooldown = 0;

  // Ventanas para la etapa 2.
  final Queue<double> _win = Queue(); // señal filtrada (lp), con signo
  final Queue<double> _winHp = Queue(); // señal pasa-alto (pre-LP)

  // Máximo móvil de 0.1 s: exige que la vibración esté presente AHORA para
  // contar como "sostenida" (evita que la cola de la ventana STA mantenga
  // vivo el contador después de un empujón/golpe corto).
  final Queue<double> _recentV = Queue();

  // Historial de quietud (bloques de 0.5 s).
  final Queue<bool> _stillBlocks = Queue();
  double _blockAcc = 0;
  int _blockCount = 0;

  void reset() {
    _first = true;
    _emaSlow = 0;
    _lp = 0;
    _staBuf.clear();
    _ltaBuf.clear();
    _staSum = 0;
    _ltaSum = 0;
    _hot = 0;
    _cooldown = 0;
    _win.clear();
    _winHp.clear();
    _stillBlocks.clear();
    _blockAcc = 0;
    _blockCount = 0;
    _recentV.clear();
  }

  /// Procesa la magnitud de aceleración lineal (m/s², sin gravedad).
  DetectorStatus process(double x) {
    if (_first) {
      _emaSlow = x;
      _first = false;
    }
    // Pasa-alto: quita deriva/inclinación lenta del sensor.
    _emaSlow += _aHp * (x - _emaSlow);
    final hp = x - _emaSlow;
    // Pasa-bajo: quita alta frecuencia (golpes secos, roces, clics).
    _lp += _aLp * (hp - _lp);
    final v = _lp.abs();

    // Ventanas de etapa 2.
    _win.addLast(_lp);
    _winHp.addLast(hp);
    if (_win.length > _winN) {
      _win.removeFirst();
      _winHp.removeFirst();
    }

    // Historial de quietud.
    _blockAcc += v;
    _blockCount++;
    if (_blockCount >= _blockN) {
      _stillBlocks.addLast(_blockAcc / _blockCount < _stillBlockThresh);
      if (_stillBlocks.length > 24) _stillBlocks.removeFirst();
      _blockAcc = 0;
      _blockCount = 0;
    }

    // Etapa 1: STA/LTA.
    _staSum += v;
    _staBuf.addLast(v);
    if (_staBuf.length > _staN) _staSum -= _staBuf.removeFirst();
    _ltaSum += v;
    _ltaBuf.addLast(v);
    if (_ltaBuf.length > _ltaN) _ltaSum -= _ltaBuf.removeFirst();

    final sta = _staSum / _staBuf.length;
    final lta = math.max(_ltaSum / _ltaBuf.length, _ltaFloor);
    final ratio = sta / lta;
    final ready = _ltaBuf.length >= _ltaN ~/ 2; // ≥5 s de calibración

    // Máximo móvil de 0.1 s de la vibración instantánea.
    _recentV.addLast(v);
    if (_recentV.length > (0.1 * sampleRate).round()) _recentV.removeFirst();
    final recentMax = _recentV.fold<double>(0, math.max);

    var triggered = false;
    String? veto;
    if (_cooldown > 0) _cooldown--;
    if (ready &&
        _cooldown == 0 &&
        ratio > _ratioOn &&
        sta > _staMin &&
        recentMax > _peakMin) {
      _hot++;
      if (_hot >= _sustainN) {
        _hot = 0;
        veto = _classify();
        if (veto == null) {
          triggered = true;
          _cooldown = (_cooldownS * sampleRate).round();
        } else {
          _cooldown = (_vetoCooldownS * sampleRate).round();
        }
      }
    } else if (ratio < _ratioOn / 2 || recentMax < _peakMin / 2) {
      _hot = math.max(0, _hot - 1);
    }

    return DetectorStatus(
      filtered: _lp,
      sta: sta,
      lta: lta,
      ratio: ratio,
      ready: ready,
      triggered: triggered,
      veto: veto,
    );
  }

  /// Etapa 2: devuelve el motivo de descarte, o null si parece sismo real.
  String? _classify() {
    final n = _win.length;
    if (n < _staN) return null; // sin datos suficientes: dejar pasar

    // 1) Reposo previo: excluir los últimos 3 bloques (contienen el evento).
    if (_stillBlocks.length > 3 + 6) {
      final blocks = _stillBlocks.toList();
      final prev = blocks.sublist(0, blocks.length - 3);
      final stillFrac = prev.where((b) => b).length / prev.length;
      if (stillFrac < _stillFracMin) {
        return 'el teléfono venía en movimiento (¿en la mano o caminando?)';
      }
    }

    final win = _win.toList();
    final winHp = _winHp.toList();

    double peak = 0, sumSq = 0;
    for (final a in win) {
      final abs = a.abs();
      if (abs > peak) peak = abs;
      sumSq += a * a;
    }
    if (peak <= 0) return null;
    final rms = math.sqrt(sumSq / n);

    // 2) Factor de cresta: un golpe seco concentra la energía en un pico.
    if (rms > 0 && peak / rms > _crestMax) {
      return 'impulso seco (parece un golpe, no un sismo)';
    }

    // Parte "activa" de la ventana (donde de verdad hubo movimiento).
    final gate = 0.1 * peak;
    var crossings = 0, active = 0;
    for (var i = 1; i < n; i++) {
      final a = win[i - 1], b = win[i];
      if (a.abs() > gate || b.abs() > gate) {
        active++;
        if ((a > 0) != (b > 0)) crossings++;
      }
    }

    // 3) Tasa de cruces por cero de la parte activa.
    if (active > 0.1 * sampleRate) {
      final zcPerSec = crossings / (active / sampleRate);
      if (zcPerSec > _zcMaxPerSec) {
        return 'vibración de alta frecuencia (golpe u objeto vibrando)';
      }
    }

    // 4) Energía de alta frecuencia vs banda sísmica.
    final peakHp =
        winHp.fold<double>(0, (m, a) => a.abs() > m ? a.abs() : m);
    final gateHp = 0.1 * peakHp;
    double eHf = 0, eLf = 0;
    for (var i = 0; i < n; i++) {
      if (winHp[i].abs() > gateHp || win[i].abs() > gate) {
        final hf = winHp[i] - win[i];
        eHf += hf * hf;
        eLf += win[i] * win[i];
      }
    }
    if (eLf > 0 && eHf / eLf > _hfRatioMax) {
      return 'energía de alta frecuencia dominante (golpe o roce)';
    }

    return null; // pasó todas las pruebas: sismo probable
  }
}
