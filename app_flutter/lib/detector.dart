// Detector sísmico de DOS ETAPAS con armado por reposo.
//
// Etapa 0 — ARMADO: igual que la red de Google en Android y que MyShake
// (UC Berkeley), el teléfono solo vigila cuando lleva un rato QUIETO. Un
// teléfono en la mano, en el bolsillo o al caminar produce oscilaciones de
// 1–3 Hz sostenidas —físicamente idénticas a una onda sísmica— así que la
// única forma seria de distinguirlas es no vigilar mientras el aparato se
// está usando. Al detectar movimiento, el detector se desarma y vuelve a
// armarse tras [armSeconds] de quietud.
//
// Etapa 1 — STA/LTA con filtro pasa-banda (0.4–5 Hz), el algoritmo estándar
// en sismología (Allen, 1978): compara la energía de corto plazo contra el
// ruido de fondo de largo plazo y marca un candidato.
//
// Etapa 2 — Clasificador de descarte inspirado en MyShake (Kong et al. 2016):
//   · Giroscopio: un teléfono sobre una mesa apenas rota durante un sismo;
//     uno en la mano rota siempre. Es el discriminador más fuerte.
//   · Factor de cresta (pico/RMS): un golpe concentra la energía en un instante.
//   · Cruces por cero: un sismo se mueve a 0.5–5 Hz; el "ring" de un golpe a >10 Hz.
//   · Energía de alta frecuencia frente a la de la banda sísmica.
//
// El detector mide por su cuenta la frecuencia real de muestreo del sensor:
// Android entrega los datos al ritmo que quiere (el `samplingPeriod` es solo
// una sugerencia) y si se asume un valor fijo, los filtros y las ventanas
// quedan desplazados y CUALQUIER movimiento parece un sismo.

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

  /// true cuando el teléfono lleva quieto el tiempo necesario para vigilar.
  final bool armed;

  /// Segundos que el teléfono lleva quieto (0 si se está moviendo).
  final double stillSeconds;

  /// Frecuencia de muestreo real medida al sensor (Hz).
  final double measuredRate;

  /// true en la muestra exacta en la que se declara el evento.
  final bool triggered;

  /// Si la etapa 2 descartó un candidato, el motivo (null en caso contrario).
  final String? veto;

  const DetectorStatus({
    required this.filtered,
    required this.sta,
    required this.lta,
    required this.ratio,
    required this.ready,
    required this.armed,
    required this.stillSeconds,
    required this.measuredRate,
    required this.triggered,
    this.veto,
  });
}

class StaLtaDetector {
  StaLtaDetector({double sampleRate = 50, this.armSeconds = 45}) {
    _configure(sampleRate);
  }

  /// Segundos de quietud necesarios para que el detector quede armado.
  final double armSeconds;

  // Banda sísmica de interés.
  static const double _fHighPass = 0.4;
  static const double _fLowPass = 5.0;

  // Umbrales etapa 1. Un sismo que amerite protegerse produce sacudida
  // claramente perceptible (>>1 m/s²).
  static const double _ratioOn = 4.0;
  static const double _staMin = 0.35; // m/s² sostenidos
  static const double _peakMin = 0.5; // m/s² de pico instantáneo reciente
  static const double _sustainS = 0.5;
  static const double _cooldownS = 30;
  static const double _vetoCooldownS = 2;
  static const double _ltaFloor = 0.015; // m/s²

  // Umbrales etapa 2 (clasificador).
  static const double _crestMax = 6.0; // pico/RMS máximo de un sismo
  static const double _zcMaxPerSec = 16; // cruces/s máx (≈8 Hz)
  static const double _hfRatioMax = 1.5; // energía HF / energía banda sísmica
  static const double _stillThresh = 0.08; // m/s² para considerar "quieto"
  static const double _gyroMax = 0.35; // rad/s (~20°/s) = manipulación

  double _rate = 50;
  double _dt = 0.02;
  double _aHp = 0, _aLp = 0;
  int _staN = 25, _ltaN = 500, _sustainN = 25, _winN = 100, _gyroN = 100;

  void _configure(double rate) {
    _rate = rate.clamp(5, 1000);
    _dt = 1 / _rate;
    double alpha(double fc) {
      final rc = 1 / (2 * math.pi * fc);
      return _dt / (rc + _dt);
    }

    _aHp = alpha(_fHighPass);
    _aLp = alpha(_fLowPass);
    _staN = math.max(3, (0.5 * _rate).round());
    _ltaN = math.max(20, (10 * _rate).round());
    _sustainN = math.max(3, (_sustainS * _rate).round());
    _winN = math.max(10, (2 * _rate).round());
    _gyroN = math.max(10, (2 * _rate).round());
  }

  // ---- Medición de la frecuencia real del sensor ----
  int _lastUs = 0;
  final List<double> _dtSamples = [];
  bool _rateLocked = false;

  double _emaSlow = 0, _lp = 0;
  bool _first = true;
  final Queue<double> _staBuf = Queue(), _ltaBuf = Queue();
  double _staSum = 0, _ltaSum = 0;
  int _hot = 0, _cooldown = 0;

  // Ventanas para la etapa 2.
  final Queue<double> _win = Queue(); // señal filtrada (lp), con signo
  final Queue<double> _winHp = Queue(); // señal pasa-alto (pre-LP)
  final Queue<double> _gyroWin = Queue(); // magnitud de giro reciente

  // Máximo móvil de 0.1 s: exige que la vibración esté presente AHORA.
  final Queue<double> _recentV = Queue();

  double _stillSecs = 0;
  double _stillPeak = 0;
  double _movingSecs = 0;
  double _slowV = 0; // vibración suavizada para decidir quietud

  /// Un sismo sacude un teléfono que estaba quieto: el movimiento empezó hace
  /// muy poco. Caminar, en cambio, lleva minutos de movimiento continuo.
  static const double _onsetMaxS = 3.5;

  bool get armed => _stillSecs >= armSeconds;

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
    _gyroWin.clear();
    _recentV.clear();
    _stillSecs = 0;
    _stillPeak = 0;
    _movingSecs = 0;
    _slowV = 0;
    _lastUs = 0;
    _dtSamples.clear();
    _rateLocked = false;
  }

  /// Procesa la magnitud de aceleración lineal (m/s², sin gravedad).
  /// [gyroMag] es la magnitud de la velocidad angular (rad/s) si está disponible.
  /// [timestampUs] permite inyectar el tiempo de la muestra (para pruebas);
  /// si se omite se usa el reloj del sistema.
  DetectorStatus process(double x, {double gyroMag = 0, int? timestampUs}) {
    // --- 0) Medir la frecuencia real del sensor y reconfigurarse ---
    final nowUs = timestampUs ?? DateTime.now().microsecondsSinceEpoch;
    if (_lastUs != 0 && !_rateLocked) {
      final dt = (nowUs - _lastUs) / 1e6;
      if (dt > 0.0005 && dt < 0.5) _dtSamples.add(dt);
      if (_dtSamples.length >= 150) {
        _dtSamples.sort();
        final mediana = _dtSamples[_dtSamples.length ~/ 2];
        final real = 1 / mediana;
        _rateLocked = true;
        if ((real - _rate).abs() / _rate > 0.15) {
          _configure(real);
          // Los filtros cambian: recalibrar desde cero (se conserva el reposo).
          _first = true;
          _staBuf.clear();
          _ltaBuf.clear();
          _staSum = 0;
          _ltaSum = 0;
          _win.clear();
          _winHp.clear();
          _recentV.clear();
          _hot = 0;
        }
      }
    }
    _lastUs = nowUs;

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

    // --- Reposo / armado ---
    _slowV += 0.05 * (v - _slowV); // suavizado ~0.4 s
    if (_slowV < _stillThresh && gyroMag < _gyroMax) {
      _stillSecs += _dt;
      _movingSecs = 0;
    } else {
      if (_stillSecs > 0) _stillPeak = _stillSecs; // quietud justo antes
      _stillSecs = 0;
      _movingSecs += _dt;
    }

    // Ventanas de etapa 2.
    _win.addLast(_lp);
    _winHp.addLast(hp);
    if (_win.length > _winN) {
      _win.removeFirst();
      _winHp.removeFirst();
    }
    _gyroWin.addLast(gyroMag);
    if (_gyroWin.length > _gyroN) _gyroWin.removeFirst();

    // --- 1) STA/LTA ---
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

    _recentV.addLast(v);
    if (_recentV.length > math.max(2, (0.1 * _rate).round())) {
      _recentV.removeFirst();
    }
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
          _cooldown = (_cooldownS * _rate).round();
        } else {
          _cooldown = (_vetoCooldownS * _rate).round();
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
      armed: armed,
      stillSeconds: _stillSecs,
      measuredRate: _rate,
      triggered: triggered,
      veto: veto,
    );
  }

  /// Etapa 2: devuelve el motivo de descarte, o null si parece sismo real.
  String? _classify() {
    // 1) El teléfono debía estar en reposo ANTES del evento. Un sismo sacude
    //    un teléfono quieto (el movimiento acaba de empezar); caminar o
    //    llevarlo en la mano es movimiento continuo desde hace rato.
    final veniaEnReposo =
        _stillSecs >= armSeconds ||
        (_stillPeak >= armSeconds && _movingSecs <= _onsetMaxS);
    if (!veniaEnReposo) {
      return 'el teléfono se estaba moviendo (en la mano, bolsillo o caminando)';
    }

    // 2) Giroscopio: rotación = manipulación, no onda sísmica.
    final giroMax = _gyroWin.isEmpty ? 0.0 : _gyroWin.reduce(math.max);
    if (giroMax > _gyroMax) {
      return 'el teléfono rotó (alguien lo está manipulando)';
    }

    final n = _win.length;
    if (n < _staN) return null; // sin datos suficientes: dejar pasar

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

    // 3) Factor de cresta: un golpe seco concentra la energía en un pico.
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

    // 4) Tasa de cruces por cero de la parte activa.
    if (active > 0.1 * _rate) {
      final zcPerSec = crossings / (active / _rate);
      if (zcPerSec > _zcMaxPerSec) {
        return 'vibración de alta frecuencia (golpe u objeto vibrando)';
      }
    }

    // 5) Energía de alta frecuencia vs banda sísmica.
    final peakHp = winHp.fold<double>(0, (m, a) => a.abs() > m ? a.abs() : m);
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
