// Datos del proyecto de Firebase para las notificaciones push.
//
// NO SE ESCRIBEN AQUÍ. Se inyectan al compilar, igual que SERVIDOR_URL, para
// que el repositorio no contenga ninguna clave:
//
//     bash compilar.sh            (lee claves.env, que está fuera del repo)
//
// Si prefieres pasarlas a mano:
//     flutter build apk --release \
//         --dart-define=FIREBASE_PROJECT_ID=... \
//         --dart-define=FIREBASE_SENDER_ID=...  \
//         --dart-define=FIREBASE_APP_ID=...     \
//         --dart-define=FIREBASE_API_KEY=...
//
// CÓMO OBTENERLOS (gratis, ~5 minutos):
//   1. Entra a https://console.firebase.google.com y crea un proyecto.
//   2. Añade una app Android con el paquete: co.alertasismica.alerta_sismica
//   3. Firebase te muestra un archivo google-services.json. Ábrelo y copia:
//        FIREBASE_PROJECT_ID → project_info.project_id
//        FIREBASE_SENDER_ID  → project_info.project_number
//        FIREBASE_APP_ID     → client[0].client_info.mobilesdk_app_id
//        FIREBASE_API_KEY    → client[0].api_key[0].current_key
//
// Sin estos valores la app funciona igual que siempre pero SIN push: consulta
// los catálogos por su cuenta. No se rompe nada.
//
// Aviso honesto: estos cuatro valores NO son un secreto criptográfico —
// viajan dentro de cualquier app Android y quien tenga el APK puede leerlos.
// Firebase los protege con las reglas del proyecto, no con su ocultamiento.
// Se sacan del repositorio por higiene y para no exponer el proyecto a
// consumo ajeno, no porque filtrarlos comprometa las cuentas.
// El secreto de verdad —la cuenta de servicio— vive solo en el servidor.

class FirebaseConfig {
  static const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const messagingSenderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const apiKey = String.fromEnvironment('FIREBASE_API_KEY');

  /// true cuando los cuatro valores están completos.
  static bool get configurado =>
      projectId.isNotEmpty &&
      messagingSenderId.isNotEmpty &&
      appId.isNotEmpty &&
      apiKey.isNotEmpty;
}
