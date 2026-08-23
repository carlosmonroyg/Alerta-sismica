// Notificaciones de sismos en la barra de estado.
//
// Se usan desde dos isolates distintos: la app (cuando está abierta) y el
// servicio de vigilancia 24/7 (cuando está cerrada). Ambas comparten el mismo
// id de notificación por sismo, de modo que Android nunca muestra el mismo
// evento dos veces. El payload lleva los datos del epicentro para que, al
// tocar la notificación, la app abra el mapa centrado en él.

import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'core.dart';

// Canal propio (no reutiliza el de versiones anteriores: Android no permite
// renombrar un canal ya creado en el dispositivo).
const kQuakeChannelId = 'sismos_cerca';
const kQuakeChannelName = 'Sismos cerca de ti';
const kQuakeChannelDesc =
    'Aviso en la barra de estado cuando ocurre un sismo dentro del radio elegido';

// Canal aparte para lo que sí es una emergencia. Va separado porque los
// ajustes de un canal (sonido de alarma, importancia máxima) se fijan al
// crearlo y no se pueden cambiar después; además así el usuario puede
// silenciar los avisos informativos sin perder las alertas graves.
const kEmergenciaChannelId = 'alerta_sismo_emergencia';
const kEmergenciaChannelName = 'ALERTA SÍSMICA — emergencia';
const kEmergenciaChannelDesc =
    'Sismos que pueden sentirse con fuerza en tu ubicación. Se muestran a '
    'pantalla completa, con sonido de alarma, incluso con el teléfono '
    'bloqueado o en silencio.';

/// Id estable por sismo: dos avisos del mismo evento se reemplazan en vez
/// de acumularse en la cortina de notificaciones.
int quakeNotificationId(Quake q) => 1000 + (q.id.hashCode & 0x3FFFFF);

String encodeQuakePayload(Quake q) => jsonEncode({
      'id': q.id,
      'mag': q.mag,
      'lat': q.lat,
      'lon': q.lon,
      'depth': q.depth,
      'place': q.place,
      'time': q.time.millisecondsSinceEpoch,
      'source': q.source,
    });

/// Reconstruye el sismo de un payload, recalculando distancia y rumbo
/// respecto a la ubicación actual del usuario.
Quake? decodeQuakePayload(String? payload, double userLat, double userLon) {
  if (payload == null || payload.isEmpty) return null;
  try {
    final j = jsonDecode(payload) as Map<String, dynamic>;
    if (j['id'] == null || j['lat'] == null || j['lon'] == null) return null;
    return Quake.at(
      id: j['id'] as String,
      mag: (j['mag'] as num?)?.toDouble() ?? 0,
      lat: (j['lat'] as num).toDouble(),
      lon: (j['lon'] as num).toDouble(),
      depth: (j['depth'] as num?)?.toDouble() ?? 0,
      time: DateTime.fromMillisecondsSinceEpoch((j['time'] as num).toInt()),
      place: (j['place'] as String?) ?? 'Ubicación desconocida',
      source: (j['source'] as String?) ?? '',
      userLat: userLat,
      userLon: userLon,
    );
  } catch (_) {
    return null;
  }
}

/// Muestra el aviso de un sismo dentro del radio elegido por el usuario.
/// [emergencia] permite forzar el trato de alerta grave. Lo usa el aviso que
/// llega del servidor, que ya evaluó la severidad: así el teléfono no depende
/// de conocer su propia ubicación para decidir si algo es urgente.
Future<void> showQuakeNotification(
  FlutterLocalNotificationsPlugin plugin,
  Quake q, {
  bool? emergencia,
}) async {
  // Intensidad estimada en la ubicación del usuario → urgencia del aviso.
  final fuerte = emergencia ?? (q.felt >= 4.5);
  final sentido = q.felt >= 2.5;
  final icono = fuerte ? '🚨' : (sentido ? '⚠️' : '🌎');
  final title =
      '$icono Sismo M${q.mag.toStringAsFixed(1)} a ${q.dist.round()} km de ti';
  final cuerpo = StringBuffer()
    ..write(q.place)
    ..write(' · ')
    ..write(timeAgo(q.time))
    ..write(' · prof. ${q.depth.round()} km');
  if (q.source.isNotEmpty) cuerpo.write(' · ${q.source}');
  cuerpo.write('\n');
  cuerpo.write(fuerte
      ? 'Pudo sentirse fuerte en tu zona. Atento a réplicas.'
      : sentido
          ? 'Pudo sentirse levemente en tu zona.'
          : 'Imperceptible en tu ubicación.');
  cuerpo.write(' Toca para verlo en el mapa.');

  // Un sismo que puede sentirse fuerte NO es un aviso más en la cortina: se
  // apodera de la pantalla (aunque esté bloqueada), suena con volumen de
  // alarma —así se oye incluso en silencio— y enciende el teléfono. Es el
  // mismo trato que le da Android a las alertas de terremoto de Google.
  final details = NotificationDetails(
    android: fuerte
        ? AndroidNotificationDetails(
            kEmergenciaChannelId,
            kEmergenciaChannelName,
            channelDescription: kEmergenciaChannelDesc,
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.alarm,
            // La clave del comportamiento: abre la alerta a pantalla completa
            // en vez de dejar una tarjeta en la cortina.
            fullScreenIntent: true,
            audioAttributesUsage: AudioAttributesUsage.alarm,
            visibility: NotificationVisibility.public, // visible en el bloqueo
            color: const Color.fromARGB(255, 239, 68, 68),
            colorized: true,
            ticker: title,
            styleInformation: BigTextStyleInformation(
              cuerpo.toString(),
              contentTitle: title,
            ),
          )
        : AndroidNotificationDetails(
            kQuakeChannelId,
            kQuakeChannelName,
            channelDescription: kQuakeChannelDesc,
            importance: sentido ? Importance.high : Importance.defaultImportance,
            priority: sentido ? Priority.high : Priority.defaultPriority,
            ticker: title,
            styleInformation: BigTextStyleInformation(
              cuerpo.toString(),
              contentTitle: title,
            ),
          ),
  );

  await plugin.show(
    quakeNotificationId(q),
    title,
    cuerpo.toString(),
    details,
    payload: encodeQuakePayload(q),
  );
}
