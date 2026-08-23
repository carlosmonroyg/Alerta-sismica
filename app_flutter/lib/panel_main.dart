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
class DatosPanel {
  final int total, sentidos, dispositivos, detecciones, alertas, comunitarios;
  final Quake? masCercano, mayor;
  final Map<String, int> porDia;
  final List<Quake> lista;
  final DateTime generado;

  const DatosPanel({
    required this.total,
    required this.sentidos,
    required this.dispositivos,
    required this.detecciones,
    required this.alertas,
    required this.comunitarios,
    required this.masCercano,
    required this.mayor,
    required this.porDia,
    required this.lista,
    required this.generado,
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
    final p = j['plataforma'] as Map<String, dynamic>;
    return DatosPanel(
      total: (s['total'] as num?)?.toInt() ?? 0,
      sentidos: (s['sentidos'] as num?)?.toInt() ?? 0,
      dispositivos: (p['dispositivos'] as num?)?.toInt() ?? 0,
      detecciones: (p['detecciones'] as num?)?.toInt() ?? 0,
      alertas: (p['alertas'] as num?)?.toInt() ?? 0,
      comunitarios: (p['eventosComunitarios'] as num?)?.toInt() ?? 0,
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
  double radio = 350;
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
      final r = await http.get(_apiUri(
          'v1/panel?lat=${m.lat}&lon=${m.lon}&radio=${radio.round()}'));
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
      _tituloSeccion('Situación del municipio', filtro: true),
      _rejilla([
        _kpi('Sismos en 30 días', '${d.total}',
            'Dentro de ${radio.round()} km del casco urbano'),
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
      _tituloSeccion('Plataforma ciudadana'),
      _rejilla([
        _kpi('Teléfonos vinculados', '${d.dispositivos}',
            'Ciudadanos que reciben alertas'),
        _kpi('Detecciones ciudadanas', '${d.detecciones}',
            'Disparos del sismógrafo de los teléfonos'),
        _kpi('Eventos por consenso', '${d.comunitarios}',
            'Confirmados por varios teléfonos a la vez'),
        _kpi('Alertas despachadas', '${d.alertas}',
            'Avisos enviados en el periodo'),
      ]),
      _tituloSeccion('Actividad'),
      LayoutBuilder(builder: (context, c) {
        final angosto = c.maxWidth < 900;
        final graficas = [
          Expanded(
            flex: angosto ? 0 : 155,
            child: _tarjeta(
              'Sismos por día',
              'Últimos 30 días',
              SizedBox(
                  height: 200,
                  child: CustomPaint(
                      painter: BarrasDiarias(d.porDia), size: Size.infinite)),
            ),
          ),
          Expanded(
            flex: angosto ? 0 : 100,
            child: _tarjeta(
              'Distribución por magnitud',
              'Escala local del SGC',
              SizedBox(
                  height: 200,
                  child: CustomPaint(
                      painter: BarrasMagnitud(d.lista), size: Size.infinite)),
            ),
          ),
        ];
        if (angosto) {
          return Column(
              children: graficas
                  .map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: (e).child))
                  .toList());
        }
        return IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            graficas[0],
            const SizedBox(width: 12),
            graficas[1],
          ]),
        );
      }),
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

  Widget _tituloSeccion(String texto, {bool filtro = false, String? nota}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 30, 0, 12),
      child: Row(children: [
        Text(texto.toUpperCase(),
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: _mutedP)),
        if (nota != null) ...[
          const SizedBox(width: 12),
          Text(nota, style: const TextStyle(fontSize: 12, color: _mutedP)),
        ],
        const Spacer(),
        if (filtro) _filtroRadio(),
      ]),
    );
  }

  Widget _filtroRadio() {
    return Row(children: [
      const Text('RADIO',
          style: TextStyle(
              fontSize: 11, letterSpacing: 1, color: _mutedP)),
      const SizedBox(width: 8),
      for (final r in [100.0, 200.0, 350.0])
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: _botonRadio(r),
        ),
    ]);
  }

  Widget _botonRadio(double r) {
    final activo = radio == r;
    return Material(
      color: activo ? _accentP : _surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          setState(() => radio = r);
          _cargar();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: activo ? _accentP : _lineP),
          ),
          child: Text('${r.round()} km',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: activo ? _surface : _ink2)),
        ),
      ),
    );
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

  Widget _kpi(String etiqueta, String valor, String sub, {String? unidad}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _lineP),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(etiqueta.toUpperCase(),
            style: const TextStyle(
                fontSize: 10.5,
                letterSpacing: .9,
                color: _mutedP,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(valor,
                  style: const TextStyle(
                      fontFamily: _mono,
                      fontSize: 30,
                      height: 1.05,
                      fontWeight: FontWeight.w700)),
              if (unidad != null) ...[
                const SizedBox(width: 3),
                Text(unidad,
                    style: const TextStyle(
                        fontSize: 14, color: _mutedP, fontWeight: FontWeight.w600)),
              ],
            ]),
        const SizedBox(height: 6),
        Text(sub,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: _mutedP)),
      ]),
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
      const Text('Anillos cada 100 km',
          style: TextStyle(fontSize: 12.5, color: _mutedP)),
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
            'Alerta Sísmica CO · Carlos Eduardo Monroy Guzmán (CEMG) · 311 448 6732',
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

// ---------------- Gráfica: distribución por magnitud ----------------
class BarrasMagnitud extends CustomPainter {
  final List<Quake> lista;
  BarrasMagnitud(this.lista);

  static const _bins = [
    ('< 2,0', 0),
    ('2,0–2,9', 0),
    ('3,0–3,9', 1),
    ('4,0–4,9', 2),
    ('≥ 5,0', 3),
  ];

  int _bin(double m) =>
      m < 2 ? 0 : (m < 3 ? 1 : (m < 4 ? 2 : (m < 5 ? 3 : 4)));

  @override
  void paint(Canvas canvas, Size size) {
    const mL = 34.0, mR = 8.0, mT = 10.0, mB = 34.0;
    final valores = List<int>.filled(5, 0);
    for (final q in lista) {
      valores[_bin(q.mag)]++;
    }
    final max = math.max(4, valores.fold<int>(0, math.max));
    final paso = max <= 8 ? 2 : (max <= 20 ? 5 : (max <= 60 ? 15 : 25));
    final plotW = size.width - mL - mR, plotH = size.height - mT - mB;
    final bw = plotW / 5;
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

    for (var i = 0; i < 5; i++) {
      final v = valores[i];
      final x = mL + i * bw + bw * .18;
      final w = bw * .64;
      if (v > 0) {
        final h = math.max(2.0, (v / max) * plotH);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(x, mT + plotH - h, w, h),
            topLeft: const Radius.circular(2.5),
            topRight: const Radius.circular(2.5),
          ),
          Paint()..color = _seis[_bins[i].$2],
        );
        _texto(canvas, '$v', Offset(x + w / 2 - 15, mT + plotH - h - 16),
            _mutedP, 10.5,
            ancho: 30, alineado: TextAlign.center, negrita: true);
      }
      _texto(canvas, _bins[i].$1, Offset(x + w / 2 - 26, size.height - 28),
          _mutedP, 10.5,
          ancho: 52, alineado: TextAlign.center);
    }
    _texto(canvas, 'Magnitud', Offset(size.width / 2 - 30, size.height - 14),
        _mutedP, 10.5,
        ancho: 60, alineado: TextAlign.center);
  }

  @override
  bool shouldRepaint(covariant BarrasMagnitud old) => old.lista != lista;
}

// ---------------- Mapa de epicentros y fallas ----------------
class MapaSismico extends CustomPainter {
  final List<Quake> sismos;
  final List<List<List<double>>> fallas;
  final Municipio municipio;

  MapaSismico({
    required this.sismos,
    required this.fallas,
    required this.municipio,
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

    // Anillos de distancia
    final anillo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _lineP;
    for (final km in [100, 200, 300]) {
      final r = km * kmPx;
      _circuloPunteado(canvas, Offset(cx, cy), r, anillo);
      _texto(canvas, '$km km', Offset(cx - 20, cy - r + 4), _mutedP, 11,
          ancho: 40, alineado: TextAlign.center);
    }

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
      old.sismos != sismos || old.fallas != fallas;
}

/// Dibuja texto en un Canvas (utilidad compartida por las gráficas).
void _texto(Canvas canvas, String s, Offset pos, Color color, double tam,
    {double ancho = 80,
    TextAlign alineado = TextAlign.left,
    bool negrita = false}) {
  final tp = TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        color: color,
        fontSize: tam,
        fontFamily: _mono,
        fontWeight: negrita ? FontWeight.w700 : FontWeight.w400,
      ),
    ),
    textDirection: TextDirection.ltr,
    textAlign: alineado,
  )..layout(maxWidth: ancho);
  tp.paint(canvas, pos);
}
