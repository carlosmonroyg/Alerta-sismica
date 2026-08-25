// Notificaciones push (Firebase Cloud Messaging).
//
// Es el camino de menor consumo de batería que existe en Android: el sistema
// ya mantiene UNA conexión persistente compartida por todas las apps, y el
// aviso viaja por ahí. El teléfono no abre sockets propios, no sondea y no
// necesita un servicio en primer plano para enterarse de un sismo.
//
// El servidor es quien mantiene el WebSocket del EMSC y consulta los catálogos
// —una sola vez para todos— y despacha el aviso a la ZONA afectada. Una zona
// mide ~111 km: dentro de ella caben usuarios con radios y magnitudes mínimas
// muy distintas, así que EL FILTRO FINAL LO APLICA SIEMPRE EL TELÉFONO, tanto
// con la app abierta como con la app cerrada.
//
// Todo esto es opcional: si el proyecto de Firebase no está configurado
// (ver firebase_config.dart), la app sigue funcionando como siempre.

import 'package:flutter/foundation.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core.dart';
import 'firebase_config.dart';
import 'quake_notify.dart';

/// Última ubicación conocida, guardada para que el isolate de segundo plano
/// (que arranca sin estado) pueda calcular distancias.
const kPrefUltLat = 'ult_lat';
const kPrefUltLon = 'ult_lon';

/// Maneja los avisos que llegan con la app cerrada o en segundo plano.
///
/// Cuando el mensaje trae `notification`, Android ya mostró el aviso por su
/// cuenta: no se duplica. Solo se dibuja el nuestro para mensajes de datos.
@pragma('vm:entry-point')
Future<void> manejarMensajeEnSegundoPlano(RemoteMessage mensaje) async {
  if (mensaje.notification != null) return;
  try {
    await Firebase.initializeApp(options: Push._opciones);
    final notifs = FlutterLocalNotificationsPlugin();
    await notifs.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      // El permiso ya lo pidió la app al arrancar; aquí solo hay que poder
      // dibujar el aviso, no volver a preguntar desde un isolate de fondo.
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    ));
    await crearCanalesDeSismo(notifs);

    // Este isolate arranca en frío: no hereda nada de la app. Sin recuperar la
    // última ubicación conocida, la distancia se calcularía desde el punto
    // (0,0) —en el golfo de Guinea— y ningún sismo parecería cercano.
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble(kPrefUltLat) ?? 0;
    final lon = prefs.getDouble(kPrefUltLon) ?? 0;
    final conUbicacion = lat != 0 || lon != 0;

    final q = Push.sismoDesdeMensaje(mensaje.data, lat, lon);
    if (q == null) return;

    // El servidor ya juzgó la severidad; si además conocemos la ubicación,
    // basta con que cualquiera de los dos criterios la considere grave.
    final delServidor = '${mensaje.data['emergencia']}' == '1';
    final grave = delServidor || (conUbicacion && q.felt >= 4.5);

    // El servidor difunde a toda la zona (~111 km) sin saber qué configuró
    // cada quien. Sin este filtro, subir la magnitud mínima a M3.5 no servía
    // de nada con la app cerrada: seguían llegando TODOS los sismos.
    if (!sismoPasaElFiltro(
      q,
      minMag: prefs.getDouble(kPrefMinMag) ?? kMinMagPorDefecto,
      radioKm: prefs.getDouble(kPrefRadiusKm) ?? kRadiusKmPorDefecto,
      emergencia: grave,
      conUbicacion: conUbicacion,
    )) {
      return;
    }

    await showQuakeNotification(notifs, q, emergencia: grave);
  } catch (_) {
    // Nunca dejar caer el manejador: perderíamos avisos posteriores.
  }
}

class Push {
  static const _opciones = FirebaseOptions(
    apiKey: FirebaseConfig.apiKey,
    appId: FirebaseConfig.appId,
    messagingSenderId: FirebaseConfig.messagingSenderId,
    projectId: FirebaseConfig.projectId,
  );

  static bool activo = false;
  static String? token;
  static String? temaSuscrito;

  /// Arranca el push. Devuelve el token del dispositivo, o null si no se pudo
  /// (proyecto sin configurar, sin permiso o sin servicios de Google).
  static Future<String?> iniciar({
    required void Function(Map<String, dynamic> datos) alRecibirEnPrimerPlano,
    required void Function(Map<String, dynamic> datos) alTocarAviso,
  }) async {
    if (!FirebaseConfig.configurado) return null;
    try {
      await Firebase.initializeApp(options: _opciones);
      final msg = FirebaseMessaging.instance;

      final permiso = await msg.requestPermission(alert: true, badge: false);
      if (permiso.authorizationStatus == AuthorizationStatus.denied) {
        return null;
      }

      FirebaseMessaging.onBackgroundMessage(manejarMensajeEnSegundoPlano);
      FirebaseMessaging.onMessage.listen((m) => alRecibirEnPrimerPlano(m.data));
      FirebaseMessaging.onMessageOpenedApp.listen((m) => alTocarAviso(m.data));

      // La app pudo abrirse tocando un aviso estando cerrada.
      final inicial = await msg.getInitialMessage();
      if (inicial != null) alTocarAviso(inicial.data);

      token = await msg.getToken();
      activo = token != null;
      return token;
    } catch (_) {
      activo = false;
      return null;
    }
  }

  /// Se suscribe a la zona que asignó el servidor (una zona ≈ 111 km).
  /// Al mudarse, se da de baja de la anterior para no recibir avisos ajenos.
  static Future<void> suscribirAZona(String? tema) async {
    if (!activo || tema == null || tema == temaSuscrito) {
      debugPrint('PUSH omitido · activo=$activo tema=$tema actual=$temaSuscrito');
      return;
    }
    try {
      final anterior = temaSuscrito;
      if (anterior != null) {
        await FirebaseMessaging.instance.unsubscribeFromTopic(anterior);
      }
      await FirebaseMessaging.instance.subscribeToTopic(tema);
      temaSuscrito = tema;
      debugPrint('PUSH suscrito al tema $tema');
    } catch (e) {
      debugPrint('PUSH fallo al suscribir a $tema: $e');
    }
  }

  /// Convierte los datos del mensaje en un sismo, calculando la distancia
  /// respecto a la ubicación del usuario.
  static Quake? sismoDesdeMensaje(
      Map<String, dynamic> datos, double userLat, double userLon) {
    final lat = double.tryParse('${datos['lat']}');
    final lon = double.tryParse('${datos['lon']}');
    final ocurrio = int.tryParse('${datos['ocurrio']}');
    if (lat == null || lon == null || ocurrio == null) return null;
    return Quake.at(
      id: '${datos['id'] ?? 'push'}',
      mag: double.tryParse('${datos['mag']}') ?? 0,
      lat: lat,
      lon: lon,
      depth: double.tryParse('${datos['prof']}') ?? 0,
      time: DateTime.fromMillisecondsSinceEpoch(ocurrio),
      place: '${datos['lugar'] ?? 'Ubicación desconocida'}',
      source: '${datos['fuente'] ?? 'SERVIDOR'}',
      userLat: userLat,
      userLon: userLon,
    );
  }
}
