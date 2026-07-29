// Pestaña Mapa (pantalla completa): epicentros reales sobre OpenStreetMap
// (flutter_map) y capa de fallas geológicas activas (base de datos mundial
// del proyecto GEM, filtrada a Colombia en assets/data/fallas.json).
// Los detalles y controles flotan sobre el mapa para máxima área de navegación.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'core.dart';

class _Fault {
  final String name, slipType;
  final List<LatLng> points;
  const _Fault(this.name, this.slipType, this.points);
}

const _slipTypeEs = {
  'Reverse': 'inversa',
  'Normal': 'normal',
  'Dextral': 'de rumbo (dextral)',
  'Sinistral': 'de rumbo (sinistral)',
  'Subduction_Thrust': 'cabalgamiento de subducción',
  'Reverse_Strike_Slip': 'inversa con rumbo',
  'Strike_Slip': 'de rumbo',
};

String _slipEs(String s) =>
    _slipTypeEs[s] ?? s.replaceAll('_', ' ').toLowerCase();

class QuakeMapView extends StatefulWidget {
  final List<Quake> quakes;
  final double lat, lon, radiusKm;
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  const QuakeMapView({
    super.key,
    required this.quakes,
    required this.lat,
    required this.lon,
    required this.radiusKm,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  State<QuakeMapView> createState() => _QuakeMapViewState();
}

class _QuakeMapViewState extends State<QuakeMapView> {
  final _controller = MapController();
  final LayerHitNotifier<String> _faultHit = ValueNotifier(null);

  List<_Fault> _faults = const [];
  bool _showFaults = true;
  _Fault? _tappedFault;

  @override
  void initState() {
    super.initState();
    _loadFaults();
  }

  Future<void> _loadFaults() async {
    try {
      final raw = await rootBundle.loadString('assets/data/fallas.json');
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final faults = list
          .map((f) => _Fault(
                (f['n'] as String?) ?? 'Falla sin nombre',
                (f['s'] as String?) ?? '',
                ((f['c'] as List).cast<List>())
                    .map((p) => LatLng(
                        (p[1] as num).toDouble(), (p[0] as num).toDouble()))
                    .toList(),
              ))
          .toList();
      if (mounted) setState(() => _faults = faults);
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant QuakeMapView old) {
    super.didUpdateWidget(old);
    // Recentrar cuando el usuario cambia de ciudad o llega el GPS.
    if (old.lat != widget.lat || old.lon != widget.lon) {
      _controller.move(LatLng(widget.lat, widget.lon), 7);
    }
  }

  Quake? get _selected {
    for (final q in widget.quakes) {
      if (q.id == widget.selectedId) return q;
    }
    return null;
  }

  void _onMapTap(LatLng tap) {
    // 1) Impacto exacto sobre la línea reportado por flutter_map.
    final hit = _faultHit.value;
    _Fault? found;
    if (hit != null && hit.hitValues.isNotEmpty) {
      final name = hit.hitValues.first;
      for (final f in _faults) {
        if (f.name == name) {
          found = f;
          break;
        }
      }
    }
    // 2) Si no hubo impacto exacto, buscar la falla más cercana con una
    //    tolerancia que depende del zoom (las líneas son muy delgadas).
    if (found == null && _showFaults && _faults.isNotEmpty) {
      final zoom = _controller.camera.zoom;
      final tolKm = 60.0 / math.pow(2, zoom - 6); // ~15 km en zoom 8
      var best = tolKm;
      for (final f in _faults) {
        for (final p in f.points) {
          final d = haversineKm(tap.latitude, tap.longitude, p.latitude, p.longitude);
          if (d < best) {
            best = d;
            found = f;
          }
        }
      }
    }
    setState(() => _tappedFault = found);
    widget.onSelect(null);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final sel = _selected;
    return Stack(children: [
      Positioned.fill(
        child: FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: LatLng(widget.lat, widget.lon),
            initialZoom: 7,
            minZoom: 4,
            maxZoom: 17,
            backgroundColor: kBg,
            onTap: (_, latLng) => _onMapTap(latLng),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'co.alertasismica.alerta_sismica',
            ),
            // Fallas geológicas activas
            if (_showFaults && _faults.isNotEmpty)
              PolylineLayer(
                hitNotifier: _faultHit,
                polylines: [
                  for (final f in _faults)
                    Polyline(
                      points: f.points,
                      color: const Color(0xFFD53E2A).withValues(alpha: .75),
                      strokeWidth: 1.8,
                      hitValue: f.name,
                    ),
                ],
              ),
            // Anillo del radio de búsqueda
            CircleLayer(circles: [
              CircleMarker(
                point: LatLng(widget.lat, widget.lon),
                radius: widget.radiusKm * 1000,
                useRadiusInMeter: true,
                color: kAccent.withValues(alpha: .05),
                borderColor: kAccent.withValues(alpha: .45),
                borderStrokeWidth: 1.5,
              ),
            ]),
            MarkerLayer(markers: [
              // Epicentros (los más viejos primero para que los recientes
              // queden encima)
              for (final q in widget.quakes.reversed)
                Marker(
                  point: LatLng(q.lat, q.lon),
                  width: 14 + q.mag * 5,
                  height: 14 + q.mag * 5,
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _tappedFault = null);
                      widget.onSelect(q.id);
                    },
                    child: _EpicenterDot(
                      color: magColor(q.mag),
                      recent: now.difference(q.time).inHours < 24,
                      selected: q.id == widget.selectedId,
                      label: q.mag >= 4 ? q.mag.toStringAsFixed(1) : null,
                    ),
                  ),
                ),
              // Usuario
              Marker(
                point: LatLng(widget.lat, widget.lon),
                width: 22,
                height: 22,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: kAccent,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: const [
                      BoxShadow(color: Colors.black45, blurRadius: 6)
                    ],
                  ),
                ),
              ),
            ]),
            const SimpleAttributionWidget(
              source: Text('OpenStreetMap · Fallas: GEM'),
            ),
          ],
        ),
      ),
      // Interruptor de la capa de fallas
      Positioned(
        top: 10,
        right: 10,
        child: _chip(
          label: '⛰️ Fallas ${_showFaults ? 'ON' : 'OFF'}',
          color: _showFaults ? const Color(0xFFD53E2A) : kPanel2,
          onTap: () => setState(() {
            _showFaults = !_showFaults;
            if (!_showFaults) _tappedFault = null;
          }),
        ),
      ),
      // Botón recentrar en el usuario
      Positioned(
        top: 10,
        left: 10,
        child: _chip(
          label: '🎯 Centrar',
          color: kPanel2,
          onTap: () =>
              _controller.move(LatLng(widget.lat, widget.lon), 7),
        ),
      ),
      // Tarjeta flotante de detalles (sismo o falla) sobre el borde inferior
      Positioned(
        left: 12,
        right: 12,
        bottom: 12,
        child: sel != null
            ? _infoCard(Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: 'M${sel.mag.toStringAsFixed(1)}',
                      style: TextStyle(
                          color: magColor(sel.mag),
                          fontWeight: FontWeight.w800)),
                  TextSpan(text: ' — ${sel.place}\n'),
                  TextSpan(
                      text:
                          '📏 A ${sel.dist.round()} km de ti · Profundidad ${sel.depth.round()} km · ${timeAgo(sel.time)} · Fuente: ${sel.source}',
                      style: const TextStyle(color: kMuted)),
                ]),
                style: const TextStyle(fontSize: 13, height: 1.5),
              ))
            : _tappedFault != null
                ? _infoCard(Text.rich(
                    TextSpan(children: [
                      TextSpan(
                          text: '⛰️ ${_tappedFault!.name}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFF97316))),
                      TextSpan(
                          text:
                              '\nFalla geológica activa${_tappedFault!.slipType.isNotEmpty ? ' · Tipo: falla ${_slipEs(_tappedFault!.slipType)}' : ''} · Fuente: GEM',
                          style: const TextStyle(color: kMuted)),
                    ]),
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ))
                : _infoCard(const Text(
                    'Toca un epicentro o una línea roja (falla geológica) para ver detalles',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: kMuted),
                  )),
      ),
    ]);
  }

  Widget _chip(
      {required String label,
      required Color color,
      required VoidCallback onTap}) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(20),
      elevation: 3,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(
            label,
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _infoCard(Widget child) => Container(
        padding: const EdgeInsets.all(12),
        width: double.infinity,
        decoration: BoxDecoration(
          color: kPanel.withValues(alpha: .93),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kLine),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10)],
        ),
        child: child,
      );
}

class _EpicenterDot extends StatelessWidget {
  final Color color;
  final bool recent, selected;
  final String? label;
  const _EpicenterDot({
    required this.color,
    required this.recent,
    required this.selected,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: recent ? .95 : .55),
        border: Border.all(
          color: selected ? Colors.white : Colors.black26,
          width: selected ? 3 : 1,
        ),
        boxShadow: recent
            ? [BoxShadow(color: color.withValues(alpha: .6), blurRadius: 10)]
            : null,
      ),
      alignment: Alignment.center,
      child: label == null
          ? null
          : Text(label!,
              style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0B1120))),
    );
  }
}
