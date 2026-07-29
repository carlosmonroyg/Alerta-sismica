// Filtra la base mundial de fallas activas del proyecto GEM
// (github.com/GEMScienceTools/gem-global-active-faults, licencia CC BY-SA)
// a la región de Colombia y países vecinos, y escribe un asset compacto.
// Uso: dart run tool/gen_fallas.dart <ruta_geojson_global>
import 'dart:convert';
import 'dart:io';

const latMin = -6.0, latMax = 15.0, lonMin = -82.0, lonMax = -64.0;

bool _inBox(num lon, num lat) =>
    lat >= latMin && lat <= latMax && lon >= lonMin && lon <= lonMax;

void main(List<String> args) {
  final src = File(args.isNotEmpty ? args[0] : '/tmp/gem_faults.geojson');
  final j = jsonDecode(src.readAsStringSync()) as Map<String, dynamic>;
  final out = <Map<String, dynamic>>[];
  var totalPoints = 0;

  for (final f in (j['features'] as List).cast<Map<String, dynamic>>()) {
    final geom = f['geometry'] as Map<String, dynamic>?;
    if (geom == null) continue;
    final props = (f['properties'] as Map<String, dynamic>?) ?? {};
    // Normalizar a lista de líneas
    final lines = <List<List<num>>>[];
    if (geom['type'] == 'LineString') {
      lines.add((geom['coordinates'] as List)
          .map((p) => (p as List).cast<num>())
          .toList());
    } else if (geom['type'] == 'MultiLineString') {
      for (final l in geom['coordinates'] as List) {
        lines.add((l as List).map((p) => (p as List).cast<num>()).toList());
      }
    }
    for (final line in lines) {
      if (!line.any((p) => _inBox(p[0], p[1]))) continue;
      // Reducir precisión a 4 decimales (~11 m) para aligerar el asset.
      final pts = line
          .map((p) => [
                double.parse(p[0].toStringAsFixed(4)),
                double.parse(p[1].toStringAsFixed(4)),
              ])
          .toList();
      totalPoints += pts.length;
      out.add({
        'n': props['name'] ?? 'Falla sin nombre',
        's': props['slip_type'] ?? '',
        'c': pts,
      });
    }
  }

  final dst = File('assets/data/fallas.json');
  dst.createSync(recursive: true);
  dst.writeAsStringSync(jsonEncode(out));
  stdout.writeln(
      'OK: ${out.length} trazas de falla, $totalPoints puntos, ${(dst.lengthSync() / 1024).round()} KB');
}
