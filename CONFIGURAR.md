# Trabajar desde otro computador

Git trae **todo el código**. Lo único que no viaja son las credenciales, y es
a propósito: si estuvieran en el repositorio, cualquiera con acceso podría
enviar alertas de sismo falsas.

Son **dos archivos**. Sin ellos el proyecto compila y funciona, pero sin
servidor y sin notificaciones push.

---

## 1. `app_flutter/claves.env` — para compilar la app

```
SERVIDOR_URL=          # la URL que imprime server/desplegar.sh
FIREBASE_PROJECT_ID=   # los cuatro salen del google-services.json
FIREBASE_SENDER_ID=    # que entrega la consola de Firebase
FIREBASE_APP_ID=
FIREBASE_API_KEY=
```

Hay una plantilla lista: `cp claves.ejemplo.env claves.env` y rellenar.

**Si lo pierdes**: los cuatro de Firebase se vuelven a sacar de
[console.firebase.google.com](https://console.firebase.google.com) →
Configuración del proyecto → tus apps → `google-services.json`. La URL del
servidor la imprime `desplegar.sh`, o está en el panel de Cloudflare.

## 2. `server/.dev.vars` — para desplegar el servidor

```
ADMIN_TOKEN=           # protege /v1/simulacro y /v1/sondear
PANEL_TOKEN=           # destapa el bloque de plataforma del panel
FCM_PROJECT_ID=        # cuenta de servicio de Firebase
FCM_CLIENT_EMAIL=
FCM_PRIVATE_KEY=       # ESTA es la credencial grave
```

Plantilla: `cp .dev.vars.ejemplo .dev.vars`.

**Si lo pierdes**: los tres `FCM_*` se regeneran en Firebase → Configuración
del proyecto → Cuentas de servicio → Generar nueva clave privada. Los dos
tokens los eliges tú, pero si los cambias hay que volver a cargarlos:
`bash desplegar.sh` los sube solos desde `.dev.vars`.

---


---

