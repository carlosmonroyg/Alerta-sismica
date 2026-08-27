// Panel municipal de gestión del riesgo sísmico — Flutter Web.
//
// Es la vista para el Consejo Municipal de Gestión del Riesgo (CMGRD), no para
// el ciudadano: indicadores agregados, cobertura de la plataforma y evidencia
// para los informes. Se compila con:
//
//   flutter build web -t lib/panel_main.dart --release
//
// Comparte con la app `core.dart` (haversine, intensidad, paleta y el modelo
// Quake), de modo que servidor, app y panel usan exactamente los mismos
// criterios. Los datos los entrega el servidor en /v1/panel.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'core.dart';

void main() {
  runApp(const PanelApp());
}

/// Municipio a mostrar, tomado de la URL: ?municipio=Acacías&lat=3.99&lon=-73.76
class Municipio {
  final String nombre;
  final double lat, lon;
  const Municipio(this.nombre, this.lat, this.lon);

  factory Municipio.desdeUrl() {
    final p = Uri.base.queryParameters;
    return Municipio(
      p['municipio'] ?? 'Villavicencio',
      double.tryParse(p['lat'] ?? '') ?? 4.142,
      double.tryParse(p['lon'] ?? '') ?? -73.627,
    );
  }
}

// ---------------- Paleta del panel ----------------
// Tono institucional claro: se proyecta en reuniones y se imprime a PDF.
const _ground = Color(0xFFEDF0F4);
const _surface = Color(0xFFFFFFFF);
const _ink = Color(0xFF101A28);
const _ink2 = Color(0xFF3B4A5F);
const _mutedP = Color(0xFF5B6B82);
const _lineP = Color(0xFFD5DDE7);
const _lineSoft = Color(0xFFE6ECF3);
const _accentP = Color(0xFF0C6E92);
const _faultP = Color(0xFFB4402F);
const _goodP = Color(0xFF1B8A55);
const _critP = Color(0xFFB32B27);

// Rampa secuencial por magnitud (un solo tono, claro → oscuro).
const _seis = [
  Color(0xFF9FD3E3),
  Color(0xFF59AAC6),
  Color(0xFF1D7FA3),
  Color(0xFF0B4F68),
];
int pasoMag(double m) => m >= 5 ? 3 : (m >= 4 ? 2 : (m >= 3 ? 1 : 0));

const _mono = 'monospace';

class PanelApp extends StatelessWidget {
  const PanelApp({super.key});

  @override
  Widget build(BuildContext context) {
    final muni = Municipio.desdeUrl();
    return MaterialApp(
      title: 'Sala Sísmica · ${muni.nombre}',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _ground,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _accentP,
          brightness: Brightness.light,
        ).copyWith(surface: _surface),
        textTheme: Typography.blackMountainView.apply(
          bodyColor: _ink,
          displayColor: _ink,
        ),
      ),
      home: PanelPage(municipio: muni),
    );
  }
}

/// Datos que entrega el servidor en /v1/panel.
/// Un tramo del reparto porcentual (por fuente, magnitud o distancia).
class Reparto {
  final String clave;
  final int n;
  final double pct;
  const Reparto(this.clave, this.n, this.pct);

  static List<Reparto> lista(dynamic v) => ((v as List?) ?? [])
      .cast<Map<String, dynamic>>()
      .map((e) => Reparto(
            (e['clave'] as String?) ?? '',
            (e['n'] as num?)?.toInt() ?? 0,
            (e['pct'] as num?)?.toDouble() ?? 0,
          ))
      .toList();
}

/// Cifras de la plataforma. Solo llegan con la clave del panel: revelan el
/// tamaño real del despliegue, que no es información pública.
class Plataforma {
  final int dispositivos, activos7d, detecciones, alertas, comunitarios;
  final double activosPct;
  const Plataforma({
    required this.dispositivos,
    required this.activos7d,
    required this.activosPct,
    required this.detecciones,
    required this.alertas,
    required this.comunitarios,
  });

  static Plataforma? desdeJson(dynamic v) {
    if (v is! Map) return null;
    return Plataforma(
      dispositivos: (v['dispositivos'] as num?)?.toInt() ?? 0,
      activos7d: (v['activos7d'] as num?)?.toInt() ?? 0,
      activosPct: (v['activosPct'] as num?)?.toDouble() ?? 0,
      detecciones: (v['detecciones'] as num?)?.toInt() ?? 0,
      alertas: (v['alertas'] as num?)?.toInt() ?? 0,
      comunitarios: (v['eventosComunitarios'] as num?)?.toInt() ?? 0,
    );
  }
}

class DatosPanel {
  final int total, sentidos;
  final double sentidosPct;
  final Quake? masCercano, mayor;
  final Map<String, int> porDia;
  final List<Quake> lista;
  final DateTime generado;
  final List<Reparto> porFuente, porMagnitud, porDistancia;
  /// null cuando no hay mes anterior con datos: no se inventa una cifra.
  final double? variacionPct;
  final int variacionAnterior;
  /// Solo con la clave del panel.
  final Plataforma? plataforma;

  const DatosPanel({
    required this.total,
    required this.sentidos,
    required this.sentidosPct,
    required this.masCercano,
    required this.mayor,
    required this.porDia,
    required this.lista,
    required this.generado,
    required this.porFuente,
    required this.porMagnitud,
    required this.porDistancia,
    required this.variacionPct,
    required this.variacionAnterior,
    required this.plataforma,
  });

  static Quake? _quake(Map<String, dynamic>? s, double lat, double lon) {
    if (s == null) return null;
    return Quake.at(
      id: (s['id'] as String?) ?? '',
      mag: (s['mag'] as num?)?.toDouble() ?? 0,
      lat: (s['lat'] as num).toDouble(),
      lon: (s['lon'] as num).toDouble(),
      depth: (s['prof'] as num?)?.toDouble() ?? 0,
      time: DateTime.fromMillisecondsSinceEpoch((s['ocurrio'] as num).toInt()),
      place: (s['lugar'] as String?) ?? '',
      source: (s['fuente'] as String?) ?? '',
      userLat: lat,
      userLon: lon,
    );
  }

  factory DatosPanel.desdeJson(Map<String, dynamic> j, double lat, double lon) {
    final s = j['sismos'] as Map<String, dynamic>;
    final pr = (j['proporciones'] as Map<String, dynamic>?) ?? const {};
    final va = (pr['variacion'] as Map<String, dynamic>?) ?? const {};
    final se = (pr['sentidos'] as Map<String, dynamic>?) ?? const {};
    return DatosPanel(
      total: (s['total'] as num?)?.toInt() ?? 0,
      sentidos: (s['sentidos'] as num?)?.toInt() ?? 0,
      sentidosPct: (se['pct'] as num?)?.toDouble() ?? 0,
      masCercano: _quake(s['masCercano'] as Map<String, dynamic>?, lat, lon),
      mayor: _quake(s['mayor'] as Map<String, dynamic>?, lat, lon),
      porDia: ((s['porDia'] as Map?) ?? {})
          .map((k, v) => MapEntry(k as String, (v as num).toInt())),
      lista: ((j['lista'] as List?) ?? [])
          .cast<Map<String, dynamic>>()
          .map((e) => _quake(e, lat, lon)!)
          .toList(),
      generado: DateTime.fromMillisecondsSinceEpoch(
          (j['generado'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch),
      porFuente: Reparto.lista(pr['porFuente']),
      porMagnitud: Reparto.lista(pr['porMagnitud']),
      porDistancia: Reparto.lista(pr['porDistancia']),
      variacionPct: (va['pct'] as num?)?.toDouble(),
      variacionAnterior: (va['anterior'] as num?)?.toInt() ?? 0,
      plataforma: Plataforma.desdeJson(j['plataforma']),
    );
  }
}

class PanelPage extends StatefulWidget {
  final Municipio municipio;
  const PanelPage({super.key, required this.municipio});

  @override
  State<PanelPage> createState() => _PanelPageState();
}

class _PanelPageState extends State<PanelPage> {
  DatosPanel? datos;
  bool enLinea = false;

  /// Radio con el que se pidieron los datos que se están mostrando.
  double radio = 350;

  /// Radio que el usuario está arrastrando ahora mismo. Se separa de [radio]
  /// para que el círculo del mapa siga al dedo sin lanzar una petición por
  /// cada píxel: los datos se recargan al soltar.
  double? radioArrastre;

  /// El que manda para dibujar.
  double get radioVista => radioArrastre ?? radio;

  static const radioMin = 50.0, radioMax = 500.0;

  List<List<List<double>>> fallas = const [];

  @override
  void initState() {
    super.initState();
    _cargarFallas();
    _cargar();
    // El servidor consulta los catálogos cada minuto; el panel lo sigue.
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 60));
      if (!mounted) return false;
      await _cargar();
      return true;
    });
  }

  /// Trazas de fallas activas (GEM), recortadas a la región del panel.
  Future<void> _cargarFallas() async {
    try {
      final r = await http.get(Uri.parse('fallas.json'));
      if (r.statusCode != 200) return;
      final lista = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
      final out = lista
          .map((f) => (f['c'] as List)
              .cast<List>()
              .map((p) => [(p[0] as num).toDouble(), (p[1] as num).toDouble()])
              .toList())
          .toList();
      if (mounted) setState(() => fallas = out);
    } catch (_) {}
  }

  /// La API cuelga de la raíz del servidor (el panel se sirve bajo /panel/),
  /// por eso la ruta debe ser absoluta. Con ?api=https://otro-host se puede
  /// apuntar a un servidor distinto si el panel se aloja aparte.
  static Uri _apiUri(String ruta) {
    final base = Uri.base.queryParameters['api'];
    if (base != null && base.isNotEmpty) {
      final limpio = base.replaceAll(RegExp(r'/+$'), '');
      return Uri.parse('$limpio/$ruta');
    }
    return Uri.parse('/$ruta');
  }

  Future<void> _cargar() async {
    final m = widget.municipio;
    try {
      // La clave viaja tal cual desde la URL del navegador: destapa el bloque
      // de plataforma. Sin ella el panel funciona igual, solo con lo público.
      final clave = Uri.base.queryParameters['clave'] ?? '';
      final r = await http.get(_apiUri('v1/panel?lat=${m.lat}&lon=${m.lon}'
          '&radio=${radio.round()}'
          '${clave.isEmpty ? '' : '&clave=${Uri.encodeQueryComponent(clave)}'}'));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        datos = DatosPanel.desdeJson(j, m.lat, m.lon);
        enLinea = true;
      });
      web.document.title = 'Sala Sísmica · ${m.nombre}';
    } catch (_) {
      if (mounted) setState(() => enLinea = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          _barra(),
          Expanded(
            child: SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 56),
                    child: datos == null ? _cargando() : _contenido(),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _cargando() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 80),
        child: Center(child: CircularProgressIndicator()),
      );

  // ---------------- Barra superior ----------------
  Widget _barra() {
    final m = widget.municipio;
    return Container(
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(bottom: BorderSide(color: _lineP)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _accentP,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(Icons.show_chart, color: _surface, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Sala Sísmica · ${m.nombre}',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const Text(
                        'CONSEJO MUNICIPAL DE GESTIÓN DEL RIESGO DE DESASTRES',
                        style: TextStyle(
                            fontSize: 11, color: _mutedP, letterSpacing: .4),
                      ),
                    ]),
              ),
              if (datos != null)
                _chip('Actualizado ${_hora(datos!.generado)}', _mutedP),
              const SizedBox(width: 8),
              _chip(enLinea ? 'En vivo' : 'Sin conexión',
                  enLinea ? _goodP : _critP),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _chip(String texto, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: .45)),
        ),
        child: Text(texto,
            style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 1,
                fontWeight: FontWeight.w700,
                color: color)),
      );

  // ---------------- Contenido ----------------
  Widget _contenido() {
    final d = datos!;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // El control va arriba del todo y a lo ancho: no filtra solo el mapa,
      // determina todas las cifras que siguen.
      const SizedBox(height: 20),
      _controlRadio(),
      _tituloSeccion('Situación del municipio'),
      _rejilla([
        _kpi(
            'Sismos en 30 días',
            '${d.total}',
            d.variacionPct == null
                ? 'Dentro de ${radio.round()} km del casco urbano'
                : '${d.variacionPct! >= 0 ? '+' : ''}${_pct(d.variacionPct!)}'
                    ' frente a los 30 días anteriores (${d.variacionAnterior})'),
        _kpi(
            'Epicentro más cercano',
            d.masCercano == null ? '—' : '${d.masCercano!.dist.round()}',
            d.masCercano == null
                ? 'Sin registros en el periodo'
                : 'M${d.masCercano!.mag.toStringAsFixed(1)} · ${d.masCercano!.place}',
            unidad: d.masCercano == null ? null : 'km'),
        _kpi(
            'Mayor magnitud',
            d.mayor == null ? '—' : 'M${d.mayor!.mag.toStringAsFixed(1)}',
            d.mayor == null
                ? '—'
                : '${d.mayor!.dist.round()} km · ${_fecha(d.mayor!.time)}'),
        _kpi('Potencialmente sentidos', '${d.sentidos}',
            'Intensidad estimada ≥ III en el casco urbano'),
      ]),
      _tituloSeccion('Composición de los sismos registrados'),
      LayoutBuilder(builder: (context, c) {
        final angosto = c.maxWidth < 900;
        final bloques = [
          _repartoTarjeta('Por catálogo', 'Quién reportó cada evento', d.porFuente),
          _repartoTarjeta('Por magnitud', 'Escala local del SGC', d.porMagnitud),
          _repartoTarjeta(
              'Por distancia', 'Desde el casco urbano', d.porDistancia),
        ];
        if (angosto) {
          return Column(
              children: bloques
                  .map((b) => Padding(
                      padding: const EdgeInsets.only(bottom: 14), child: b))
                  .toList());
        }
        return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < bloques.length; i++) ...[
                Expanded(child: bloques[i]),
                if (i < bloques.length - 1) const SizedBox(width: 14),
              ]
            ]);
      }),
      if (d.plataforma != null) ...[
        _tituloSeccion('Plataforma ciudadana'),
        _rejilla([
          _kpi('Teléfonos vinculados', '${d.plataforma!.dispositivos}',
              '${d.plataforma!.activos7d} activos en 7 días'
              ' (${_pct(d.plataforma!.activosPct)})'),
          _kpi('Detecciones ciudadanas', '${d.plataforma!.detecciones}',
              'Disparos del sismógrafo de los teléfonos'),
          _kpi('Eventos por consenso', '${d.plataforma!.comunitarios}',
              'Confirmados por varios teléfonos a la vez'),
          _kpi('Alertas despachadas', '${d.plataforma!.alertas}',
              'Avisos enviados en el periodo'),
        ]),
      ],
      _tituloSeccion('Actividad'),
      // Antes había aquí un segundo gráfico de magnitudes. Se quitó porque se
      // alimentaba de la lista recortada a 500 eventos y contradecía a la
      // tarjeta 'Por magnitud', que sí cuenta el periodo completo: dos cifras
      // distintas para el mismo dato en la misma pantalla.
      _tarjeta(
        'Sismos por día',
        'Últimos 30 días · ${d.total} eventos en ${radio.round()} km',
        SizedBox(
            height: 220,
            child: CustomPaint(
                painter: BarrasDiarias(d.porDia), size: Size.infinite)),
      ),
      _tituloSeccion('Epicentros y fallas activas'),
      _tarjeta(
        null,
        null,
        LayoutBuilder(builder: (context, c) {
          final angosto = c.maxWidth < 820;
          final mapa = AspectRatio(
            aspectRatio: 1000 / 958,
            child: CustomPaint(
              painter: MapaSismico(
                sismos: d.lista,
                fallas: fallas,
                municipio: widget.municipio,
                radio: radioVista,
              ),
              size: Size.infinite,
            ),
          );
          if (angosto) {
            return Column(children: [mapa, const SizedBox(height: 16), _leyenda()]);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: mapa),
            const SizedBox(width: 18),
            SizedBox(width: 240, child: _leyenda()),
          ]);
        }),
      ),
      _tituloSeccion('Últimos eventos',
          nota: d.lista.isEmpty
              ? null
              : '15 más recientes de ${d.lista.length} en ${radio.round()} km'),
      _tarjeta(null, null, _tabla(d.lista)),
      const SizedBox(height: 28),
      _pie(),
    ]);
  }

  /// Encabezado de sección: rótulo a la izquierda y una regla fina que ocupa
  /// el resto del ancho. La regla no decora — separa bloques sin necesidad de
  /// encajonar cada uno en su tarjeta, que es lo que recargaba la vista.
  Widget _tituloSeccion(String texto, {String? nota}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 34, 0, 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Text(texto.toUpperCase(),
            style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
                color: _ink2)),
        if (nota != null) ...[
          const SizedBox(width: 12),
          Flexible(
            child: Text(nota,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: _mutedP)),
          ),
        ],
        const SizedBox(width: 16),
        const Expanded(child: Divider(height: 1, thickness: 1, color: _lineSoft)),
      ]),
    );
  }

  /// Control del radio de análisis.
  ///
  /// Sustituye a tres botones fijos (100/200/350 km) que obligaban a elegir
  /// entre saltos arbitrarios. Con el deslizador el círculo del mapa sigue al
  /// dedo en tiempo real y los datos se recargan al soltar, no en cada píxel.
  Widget _controlRadio() {
    final r = radioVista;
    // Área realmente cubierta. Es el dato que hace entender por qué pasar de
    // 300 a 400 km no es "un poco más": la superficie crece al cuadrado.
    final area = math.pi * r * r;
    final arrastrando = radioArrastre != null;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _lineSoft),
      ),
      child: LayoutBuilder(builder: (context, c) {
        final angosto = c.maxWidth < 620;
        final lectura = Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${r.round()}',
                style: TextStyle(
                    fontFamily: _mono,
                    fontSize: 38,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: arrastrando ? _accentP : _ink)),
            const SizedBox(width: 4),
            const Text('km',
                style: TextStyle(
                    fontSize: 15, color: _mutedP, fontWeight: FontWeight.w600)),
          ],
        );

        final etiquetas = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('RADIO DE ANÁLISIS',
                style: TextStyle(
                    fontSize: 10.5,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w600,
                    color: _mutedP)),
            const SizedBox(height: 6),
            lectura,
            const SizedBox(height: 4),
            Text('${_miles(area.round())} km² cubiertos',
                style: const TextStyle(fontSize: 11.5, color: _mutedP)),
          ],
        );

        final deslizador = Column(children: [
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              activeTrackColor: _accentP,
              inactiveTrackColor: _lineP,
              thumbColor: _surface,
              overlayColor: _accentP.withValues(alpha: .12),
              activeTickMarkColor: _accentP.withValues(alpha: .45),
              inactiveTickMarkColor: _lineP,
              valueIndicatorColor: _ink,
              trackShape: const RoundedRectSliderTrackShape(),
              thumbShape: const _AnilloThumb(),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
              showValueIndicator: ShowValueIndicator.never,
            ),
            child: Slider(
              value: r.clamp(radioMin, radioMax),
              min: radioMin,
              max: radioMax,
              divisions: ((radioMax - radioMin) / 10).round(),
              onChanged: (v) => setState(() => radioArrastre = v),
              onChangeEnd: (v) {
                setState(() {
                  radio = v;
                  radioArrastre = null;
                });
                _cargar();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final m in [50, 200, 350, 500])
                  Text('$m',
                      style: const TextStyle(
                          fontFamily: _mono, fontSize: 10.5, color: _mutedP)),
              ],
            ),
          ),
        ]);

        if (angosto) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            etiquetas,
            const SizedBox(height: 4),
            deslizador,
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(width: 190, child: etiquetas),
          const SizedBox(width: 24),
          Expanded(child: deslizador),
        ]);
      }),
    );
  }

  /// 1234567 -> 1.234.567 (separador de miles en español).
  static String _miles(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
      b.write(s[i]);
    }
    return b.toString();
  }

  Widget _rejilla(List<Widget> hijos) {
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth < 860 ? 2 : 4;
      const gap = 12.0;
      final ancho = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: hijos.map((h) => SizedBox(width: ancho, child: h)).toList(),
      );
    });
  }

  /// Indicador. Sin borde: la cifra es lo que debe leerse desde el fondo de
  /// una sala de reuniones, y encajonar cada dato en una caja con marco hacía
  /// competir el contenedor con el contenido.
  Widget _kpi(String etiqueta, String valor, String sub, {String? unidad}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(etiqueta.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 10,
                letterSpacing: 1.05,
                color: _mutedP,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(valor,
                  style: const TextStyle(
                      fontFamily: _mono,
                      fontSize: 34,
                      height: 1,
                      letterSpacing: -1,
                      fontWeight: FontWeight.w700,
                      color: _ink)),
              if (unidad != null) ...[
                const SizedBox(width: 4),
                Text(unidad,
                    style: const TextStyle(
                        fontSize: 14, color: _mutedP, fontWeight: FontWeight.w600)),
              ],
            ]),
        const SizedBox(height: 8),
        Text(sub,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, height: 1.35, color: _mutedP)),
      ]),
    );
  }

  /// Porcentaje con una decimal y coma decimal, como se escribe en español.
  static String _pct(double v) =>
      '${v.toStringAsFixed(1).replaceAll('.', ',')} %';

  /// Reparto porcentual en barras horizontales. Se prefiere a un anillo
  /// porque aquí las etiquetas son largas y las proporciones muy desiguales:
  /// en un anillo, un tramo de 0,4 % es invisible; en barra sigue leyéndose.
  Widget _repartoTarjeta(String titulo, String sub, List<Reparto> datos) {
    final maximo = datos.fold<double>(0, (m, r) => r.pct > m ? r.pct : m);
    return _tarjeta(
      titulo,
      sub,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: datos.isEmpty
            ? [
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Text('Sin registros en el periodo',
                      style: TextStyle(fontSize: 13, color: _mutedP)),
                )
              ]
            : [
                for (final r in datos)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(r.clave,
                                  style: const TextStyle(fontSize: 12.5)),
                            ),
                            Text('${r.n}',
                                style: const TextStyle(
                                    fontSize: 12.5, color: _mutedP)),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 54,
                              child: Text(_pct(r.pct),
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        // La barra se escala al tramo mayor, no al 100 %: con
                        // un catálogo que aporta el 99 % los demás quedarían
                        // como una línea invisible.
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: maximo <= 0 ? 0 : r.pct / maximo,
                            minHeight: 6,
                            backgroundColor: _lineSoft,
                            valueColor:
                                const AlwaysStoppedAnimation(_accentP),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
      ),
    );
  }

  Widget _tarjeta(String? titulo, String? sub, Widget hijo) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _lineP),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (titulo != null)
          Text(titulo,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        if (sub != null)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 14),
            child: Text(sub, style: const TextStyle(fontSize: 12, color: _mutedP)),
          ),
        hijo,
      ]),
    );
  }

  Widget _leyenda() {
    Widget item(Widget marca, String texto) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            marca,
            const SizedBox(width: 9),
            Expanded(
                child: Text(texto,
                    style: const TextStyle(fontSize: 12.5, color: _ink2))),
          ]),
        );
    Widget punto(Color c) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle));
    Widget titulo(String t) => Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 6),
          child: Text(t.toUpperCase(),
              style: const TextStyle(
                  fontSize: 10.5,
                  letterSpacing: .9,
                  color: _mutedP,
                  fontWeight: FontWeight.w700)),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      titulo('Magnitud'),
      item(punto(_seis[0]), 'M < 3,0'),
      item(punto(_seis[1]), 'M 3,0 – 3,9'),
      item(punto(_seis[2]), 'M 4,0 – 4,9'),
      item(punto(_seis[3]), 'M ≥ 5,0'),
      titulo('Geología'),
      item(Container(width: 18, height: 2, color: _faultP), 'Falla activa'),
      titulo('Referencia'),
      item(punto(_accentP), 'Casco urbano'),
      item(
          Container(width: 9, height: 9, color: _ink2.withValues(alpha: .55)),
          'Ciudad principal'),
      item(
          Container(
            width: 18,
            height: 10,
            decoration: BoxDecoration(
              color: _accentP.withValues(alpha: .10),
              border: Border.all(color: _accentP.withValues(alpha: .75)),
            ),
          ),
          'Radio de análisis'),
      Text('Anillos cada ${_pasoAnillo(radioVista).round()} km',
          style: const TextStyle(fontSize: 12.5, color: _mutedP)),
    ]);
  }

  Widget _tabla(List<Quake> lista) {
    if (lista.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: Text(
            'Todavía no hay sismos registrados en este radio.\n'
            'El servidor consulta los catálogos cada minuto.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: _mutedP),
          ),
        ),
      );
    }
    final filas = [...lista]..sort((a, b) => b.time.compareTo(a.time));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 38,
        dataRowMinHeight: 40,
        dataRowMaxHeight: 44,
        horizontalMargin: 12,
        headingTextStyle: const TextStyle(
            fontSize: 10.5,
            letterSpacing: .9,
            fontWeight: FontWeight.w700,
            color: _mutedP),
        dividerThickness: 1,
        columns: const [
          DataColumn(label: Text('FECHA Y HORA LOCAL')),
          DataColumn(label: Text('MAGNITUD')),
          DataColumn(label: Text('LUGAR')),
          DataColumn(label: Text('FUENTE')),
          DataColumn(label: Text('DISTANCIA'), numeric: true),
          DataColumn(label: Text('PROF.'), numeric: true),
        ],
        rows: filas.take(15).map((q) {
          final p = pasoMag(q.mag);
          return DataRow(cells: [
            DataCell(Text(_fecha(q.time),
                style: const TextStyle(fontFamily: _mono, fontSize: 12.5))),
            DataCell(Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                  color: _seis[p], borderRadius: BorderRadius.circular(6)),
              child: Text('M${q.mag.toStringAsFixed(1)}',
                  style: TextStyle(
                      fontFamily: _mono,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: p >= 2 ? Colors.white : const Color(0xFF04222E))),
            )),
            DataCell(Text(q.place, style: const TextStyle(fontSize: 13))),
            DataCell(Text(q.source, style: const TextStyle(fontSize: 13))),
            DataCell(Text('${q.dist.round()} km',
                style: const TextStyle(fontFamily: _mono, fontSize: 12.5))),
            DataCell(Text('${q.depth.round()} km',
                style: const TextStyle(fontFamily: _mono, fontSize: 12.5))),
          ]);
        }).toList(),
      ),
    );
  }

  Widget _pie() {
    const estilo = TextStyle(fontSize: 12, color: _mutedP, height: 1.5);
    const fuerte = TextStyle(
        fontSize: 12, color: _ink2, height: 1.5, fontWeight: FontWeight.w600);
    return Container(
      padding: const EdgeInsets.only(top: 18),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _lineP)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text.rich(TextSpan(children: const [
          TextSpan(text: 'Fuentes. ', style: fuerte),
          TextSpan(
              text: 'Catálogo sísmico del Servicio Geológico Colombiano '
                  '(soluciones revisadas por analista), USGS y EMSC. Trazas de '
                  'fallas activas: GEM Global Active Faults (CC BY-SA). La '
                  'intensidad se estima con una atenuación simplificada por '
                  'magnitud y distancia.',
              style: estilo),
        ])),
        const SizedBox(height: 8),
        Text.rich(TextSpan(children: const [
          TextSpan(text: 'Alcance. ', style: fuerte),
          TextSpan(
              text: 'El sistema no constituye alerta temprana ni reemplaza los '
                  'canales oficiales del SGC y la UNGRD: es una herramienta de '
                  'monitoreo, preparación y evidencia para la gestión municipal '
                  'del riesgo. La ubicación de los ciudadanos se maneja de forma '
                  'anonimizada por cuadrículas, conforme a la Ley 1581 de 2012.',
              style: estilo),
        ])),
        const SizedBox(height: 8),
        const Text(
            'Alerta Sísmica CO · Carlos Eduardo Monroy Guzmán (CEMG) 📧 carlosmonroyeg91@gmail.com · ',
            style: estilo),
      ]),
    );
  }

  static String _fecha(DateTime d) {
    const meses = [
      'ene', 'feb', 'mar', 'abr', 'may', 'jun',
      'jul', 'ago', 'sep', 'oct', 'nov', 'dic'
    ];
    final dd = d.day.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$dd ${meses[d.month - 1]} · $hh:$mm';
  }

  static String _hora(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// Pulgar del deslizador: un anillo, no un disco.
///
/// El disco macizo por omisión tapa la marca donde está posado y obliga a
/// soltar para leer el valor. El anillo deja ver la pista por debajo, que es
/// justo lo que se está ajustando.
class _AnilloThumb extends SliderComponentShape {
  const _AnilloThumb();

  static const _r = 11.0;

  @override
  Size getPreferredSize(bool enabled, bool isDiscrete) =>
      const Size.fromRadius(_r);

  @override
  void paint(PaintingContext context, Offset centro,
      {required Animation<double> activationAnimation,
      required Animation<double> enableAnimation,
      required bool isDiscrete,
      required TextPainter labelPainter,
      required RenderBox parentBox,
      required SliderThemeData sliderTheme,
      required TextDirection textDirection,
      required double value,
      required double textScaleFactor,
      required Size sizeWithOverflow}) {
    final canvas = context.canvas;
    // Sombra suave para despegarlo de la pista.
    canvas.drawCircle(centro.translate(0, 1), _r,
        Paint()..color = _ink.withValues(alpha: .10));
    canvas.drawCircle(centro, _r, Paint()..color = sliderTheme.thumbColor!);
    canvas.drawCircle(
        centro,
        _r - 1.25,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = sliderTheme.activeTrackColor!);
  }
}

// ---------------- Gráfica: sismos por día ----------------
class BarrasDiarias extends CustomPainter {
  final Map<String, int> porDia;
  BarrasDiarias(this.porDia);

  @override
  void paint(Canvas canvas, Size size) {
    const mL = 34.0, mR = 6.0, mT = 10.0, mB = 26.0;
    final hoy = DateTime.now();
    final dias = List.generate(30, (i) {
      final d = hoy.subtract(Duration(days: 29 - i));
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
    });
    final valores = dias.map((d) => porDia[d] ?? 0).toList();
    final max = math.max(4, valores.fold<int>(0, math.max));
    final paso = max <= 8 ? 2 : (max <= 20 ? 5 : (max <= 60 ? 15 : 25));

    final plotW = size.width - mL - mR, plotH = size.height - mT - mB;
    final bw = plotW / dias.length;
    double y(num v) => mT + plotH - (v / max) * plotH;

    final grid = Paint()
      ..color = _lineSoft
      ..strokeWidth = 1;
    for (var g = 0; g <= max; g += paso) {
      canvas.drawLine(Offset(mL, y(g)), Offset(size.width - mR, y(g)), grid);
      _texto(canvas, '$g', Offset(mL - 7, y(g) - 6), _mutedP, 10.5,
          alineado: TextAlign.right, ancho: 30);
    }
    canvas.drawLine(
        Offset(mL, mT + plotH), Offset(size.width - mR, mT + plotH), grid);

    final barra = Paint()..color = _seis[2];
    for (var i = 0; i < dias.length; i++) {
      final v = valores[i];
      if (v <= 0) continue;
      final h = math.max(2.0, (v / max) * plotH);
      final x = mL + i * bw + bw * .16;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x, mT + plotH - h, bw * .68, h),
          topLeft: const Radius.circular(2.5),
          topRight: const Radius.circular(2.5),
        ),
        barra,
      );
    }
    const meses = [
      'ene', 'feb', 'mar', 'abr', 'may', 'jun',
      'jul', 'ago', 'sep', 'oct', 'nov', 'dic'
    ];
    for (var i = 0; i < dias.length; i += 5) {
      final d = hoy.subtract(Duration(days: 29 - i));
      _texto(canvas, '${d.day} ${meses[d.month - 1]}',
          Offset(mL + i * bw - 8, size.height - 18), _mutedP, 10.5,
          ancho: 46);
    }
  }

  @override
  bool shouldRepaint(covariant BarrasDiarias old) => old.porDia != porDia;
}


// ---------------- Mapa de epicentros y fallas ----------------
/// Separación entre anillos de referencia, según el radio elegido.
///
/// Vive fuera del pintor porque la leyenda anuncia este mismo número: si cada
/// uno lo calculara por su cuenta, acabarían discrepando.
double _pasoAnillo(double radio) => radio <= 120
    ? 25
    : radio <= 250
        ? 50
        : 100;

/// Ciudades de referencia para poder situarse en el mapa.
///
/// Sin ellas el panel es un diagrama abstracto: trazas de falla y puntos sobre
/// un fondo vacío. Con ellas, quien lo ve en un consejo municipal reconoce
/// dónde está mirando.
///
/// `nivel` 1 se rotula siempre; el 2 solo si su etiqueta cabe sin pisar otra
/// —el Eje Cafetero tiene tres capitales a menos de 60 km y sus nombres se
/// solapan a cualquier escala.
const _ciudades = <({String nombre, double lat, double lon, int nivel})>[
  (nombre: 'Bogotá', lat: 4.711, lon: -74.072, nivel: 1),
  (nombre: 'Medellín', lat: 6.244, lon: -75.581, nivel: 1),
  (nombre: 'Cali', lat: 3.452, lon: -76.532, nivel: 1),
  (nombre: 'Bucaramanga', lat: 7.119, lon: -73.123, nivel: 1),
  (nombre: 'Villavicencio', lat: 4.142, lon: -73.627, nivel: 1),
  (nombre: 'Ibagué', lat: 4.439, lon: -75.232, nivel: 2),
  (nombre: 'Neiva', lat: 2.927, lon: -75.289, nivel: 2),
  (nombre: 'Pereira', lat: 4.813, lon: -75.696, nivel: 2),
  (nombre: 'Manizales', lat: 5.070, lon: -75.517, nivel: 2),
  (nombre: 'Armenia', lat: 4.534, lon: -75.681, nivel: 2),
  (nombre: 'Tunja', lat: 5.535, lon: -73.368, nivel: 2),
  (nombre: 'Popayán', lat: 2.444, lon: -76.614, nivel: 2),
  (nombre: 'Florencia', lat: 1.614, lon: -75.607, nivel: 2),
  (nombre: 'Yopal', lat: 5.338, lon: -72.395, nivel: 2),
  (nombre: 'Quibdó', lat: 5.692, lon: -76.658, nivel: 2),
  (nombre: 'Sogamoso', lat: 5.714, lon: -72.933, nivel: 2),
  (nombre: 'Granada', lat: 3.546, lon: -73.708, nivel: 2),
  (nombre: 'San José del Guaviare', lat: 2.572, lon: -72.641, nivel: 2),
];

class MapaSismico extends CustomPainter {
  final List<Quake> sismos;
  final List<List<List<double>>> fallas;
  final Municipio municipio;

  /// Radio de análisis en km. Se dibuja resaltado sobre los anillos de
  /// referencia, y sigue al deslizador mientras se arrastra.
  final double radio;

  MapaSismico({
    required this.sismos,
    required this.fallas,
    required this.municipio,
    required this.radio,
  });

  static const latMin = 0.9, latMax = 7.4, lonMin = -77.0, lonMax = -70.2;

  @override
  void paint(Canvas canvas, Size size) {
    // Sin recorte, las trazas de falla que salen del recuadro se dibujarían
    // encima del resto del panel.
    canvas.clipRect(Offset.zero & size);
    final kx = size.width / (lonMax - lonMin);
    final ky = kx / math.cos(4.15 * math.pi / 180);
    double px(double lon) => (lon - lonMin) * kx;
    double py(double lat) => (latMax - lat) * ky;
    final kmPx = ky / 111;

    final cx = px(municipio.lon), cy = py(municipio.lat);

    // Retícula de coordenadas. Va debajo de todo y muy tenue: su trabajo es
    // dar escala y orientación, no competir con los datos.
    final malla = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _lineSoft;
    for (var lon = lonMin.ceil(); lon <= lonMax.floor(); lon++) {
      final x = px(lon.toDouble());
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), malla);
      _texto(canvas, '${lon.abs()}°O', Offset(x + 3, size.height - 14),
          _mutedP.withValues(alpha: .55), 9, ancho: 34);
    }
    for (var lat = latMin.ceil(); lat <= latMax.floor(); lat++) {
      final y = py(lat.toDouble());
      if (y < 0 || y > size.height) continue;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), malla);
      _texto(canvas, '$lat°N', Offset(4, y + 3),
          _mutedP.withValues(alpha: .55), 9, ancho: 30);
    }

    // Anillos de referencia. El paso se adapta al radio elegido: con 500 km
    // tres anillos fijos de 100/200/300 dejaban vacía la mitad del mapa, y
    // con 50 km no se distinguía ninguno.
    final paso = _pasoAnillo(radio);
    final anillo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _lineP;
    for (var km = paso; km < radio - paso * .35; km += paso) {
      final r = km * kmPx;
      _circuloPunteado(canvas, Offset(cx, cy), r, anillo);
      _texto(canvas, '${km.round()} km', Offset(cx - 22, cy - r + 4), _mutedP, 10.5,
          ancho: 44, alineado: TextAlign.center);
    }

    // El radio de análisis, resaltado: relleno tenue y borde continuo. Es el
    // límite que decide qué entra en TODAS las cifras del panel, así que se
    // distingue de los anillos de referencia, que solo sirven para medir.
    final rSel = radio * kmPx;
    canvas.drawCircle(Offset(cx, cy), rSel,
        Paint()..color = _accentP.withValues(alpha: .055));
    canvas.drawCircle(
        Offset(cx, cy),
        rSel,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = _accentP.withValues(alpha: .75));
    _texto(canvas, '${radio.round()} km', Offset(cx - 30, cy - rSel - 16),
        _accentP, 11.5, ancho: 60, alineado: TextAlign.center, negrita: true);

    // Fallas activas
    final trazo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = _faultP.withValues(alpha: .72);
    for (final f in fallas) {
      if (f.length < 2) continue;
      final path = Path()..moveTo(px(f[0][0]), py(f[0][1]));
      for (var i = 1; i < f.length; i++) {
        path.lineTo(px(f[i][0]), py(f[i][1]));
      }
      canvas.drawPath(path, trazo);
    }

    // Ciudades de referencia.
    //
    // El rótulo del propio municipio se reserva primero para que ninguna
    // ciudad se lo pise: es el punto que el usuario vino a mirar.
    final ocupado = <Rect>[
      Rect.fromLTWH(cx + 10, cy - 10, municipio.nombre.length * 6.6 + 8, 16),
    ];
    final orden3 = [..._ciudades]..sort((a, b) => a.nivel.compareTo(b.nivel));
    for (final c in orden3) {
      final x = px(c.lon), y = py(c.lat);
      if (x < 2 || x > size.width - 2 || y < 2 || y > size.height - 2) continue;
      // No repetir el municipio si ya está dibujado como casco urbano.
      if ((x - cx).abs() < 6 && (y - cy).abs() < 6) continue;

      canvas.drawRect(Rect.fromCenter(center: Offset(x, y), width: 4.5, height: 4.5),
          Paint()..color = _ink2.withValues(alpha: .55));

      final caja = Rect.fromLTWH(x + 5, y - 6, c.nombre.length * 5.4 + 4, 12);
      final choca = ocupado.any((r) => r.overlaps(caja));
      // El nivel 1 se rotula aunque choque: son las capitales que dan la
      // orientación general y sin ellas el mapa vuelve a ser abstracto.
      if (c.nivel > 1 && choca) continue;
      if (caja.right > size.width) continue;

      _texto(canvas, c.nombre, Offset(x + 5, y - 6),
          _ink2.withValues(alpha: .8), 9.5, ancho: 120, mono: false);
      ocupado.add(caja);
    }

    // Epicentros: los más antiguos primero
    final orden = [...sismos]..sort((a, b) => a.time.compareTo(b.time));
    for (final q in orden) {
      final r = 2.6 + q.mag * 1.7;
      canvas.drawCircle(
          Offset(px(q.lon), py(q.lat)), r, Paint()..color = _seis[pasoMag(q.mag)]);
      canvas.drawCircle(
        Offset(px(q.lon), py(q.lat)),
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = _surface,
      );
    }

    // Casco urbano
    canvas.drawCircle(Offset(cx, cy), 7, Paint()..color = _accentP);
    canvas.drawCircle(
      Offset(cx, cy),
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = _surface,
    );
    _texto(canvas, municipio.nombre, Offset(cx + 12, cy - 8), _ink, 12,
        ancho: 160, negrita: true);
  }

  void _circuloPunteado(Canvas canvas, Offset c, double r, Paint p) {
    const trozos = 90;
    for (var i = 0; i < trozos; i += 2) {
      final a1 = (i / trozos) * 2 * math.pi;
      final a2 = ((i + 1) / trozos) * 2 * math.pi;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), a1, a2 - a1, false, p);
    }
  }

  @override
  bool shouldRepaint(covariant MapaSismico old) =>
      // El radio va primero: es lo que cambia en cada fotograma mientras se
      // arrastra el deslizador. Sin comparar esto, el círculo se quedaría
      // congelado hasta que llegaran datos nuevos del servidor.
      old.radio != radio || old.sismos != sismos || old.fallas != fallas;
}

/// Dibuja texto en un Canvas (utilidad compartida por las gráficas).
void _texto(Canvas canvas, String s, Offset pos, Color color, double tam,
    {double ancho = 80,
    TextAlign alineado = TextAlign.left,
    bool negrita = false,
    // Las cifras van en monoespaciada para que alineen; los topónimos no,
    // que ahí solo estorba a la lectura.
    bool mono = true}) {
  final tp = TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        color: color,
        fontSize: tam,
        fontFamily: mono ? _mono : null,
        fontWeight: negrita ? FontWeight.w700 : FontWeight.w400,
      ),
    ),
    textDirection: TextDirection.ltr,
    textAlign: alineado,
  )..layout(maxWidth: ancho);
  tp.paint(canvas, pos);
}
