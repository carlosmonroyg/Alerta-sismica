// Genera assets/audio/sirena.wav: sirena sintetizada (diente de sierra 750 Hz
// modulado ±280 Hz a 2 Hz), 6 s, 22050 Hz, 16-bit mono, pensada para loop.
// Uso: dart run tool/gen_sirena.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

void main() {
  const sr = 22050;
  const durS = 6;
  const n = sr * durS;
  final samples = Int16List(n);
  double phase = 0;
  const fadeN = sr ~/ 20; // 50 ms de fade para evitar clics al hacer loop
  for (var i = 0; i < n; i++) {
    final t = i / sr;
    final f = 750 + 280 * math.sin(2 * math.pi * 2.0 * t);
    phase += 2 * math.pi * f / sr;
    final saw = 2 * ((phase / (2 * math.pi)) % 1) - 1;
    var amp = 0.45;
    if (i < fadeN) amp *= i / fadeN;
    if (i > n - fadeN) amp *= (n - i) / fadeN;
    samples[i] = (saw * amp * 32767).round().clamp(-32768, 32767);
  }

  final dataBytes = samples.buffer.asUint8List();
  final header = BytesBuilder();
  void str(String s) => header.add(s.codeUnits);
  void u32(int v) =>
      header.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) =>
      header.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));

  str('RIFF');
  u32(36 + dataBytes.length);
  str('WAVE');
  str('fmt ');
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(sr);
  u32(sr * 2); // byte rate
  u16(2); // block align
  u16(16); // bits
  str('data');
  u32(dataBytes.length);

  final out = File('assets/audio/sirena.wav');
  out.createSync(recursive: true);
  out.writeAsBytesSync(header.toBytes() + dataBytes);
  stdout.writeln('OK: ${out.path} (${(out.lengthSync() / 1024).round()} KB)');
}
