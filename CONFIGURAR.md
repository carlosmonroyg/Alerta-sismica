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

## Cómo llevarlos al otro computador

`FCM_PRIVATE_KEY` permite **enviar notificaciones en nombre de la app**: con
ella se pueden disparar alertas de sismo falsas a todos los usuarios. Trátala
como una contraseña bancaria.

- **Bien**: un gestor de contraseñas, una memoria USB en mano, o simplemente
  generar una clave nueva en la consola de Firebase desde el otro computador
  (las claves de servicio pueden coexistir).
- **Mal**: correo, WhatsApp, Drive compartido, un mensaje a ti mismo. Quedan
  copiadas en servidores que no controlas y no se pueden borrar de verdad.

Lo más limpio, si vas a trabajar seguido en dos máquinas: **generar una clave
de servicio distinta en cada una**. Si un computador se pierde, revocas solo
esa y la otra sigue trabajando.

---

## Puesta a punto de una máquina nueva

Herramientas (las versiones con las que está probado):

| | |
|---|---|
| Flutter | 3.44.4 (canal stable) |
| JDK | 17 |
| Node | 22 |
| Android SDK | con `platform-tools` para `adb` |

Luego:

```bash
git clone https://github.com/carlosmonroyg/Alerta-sismica.git
cd Alerta-sismica

# 1. las credenciales (ver arriba)
cp app_flutter/claves.ejemplo.env app_flutter/claves.env   # y rellenar
cp server/.dev.vars.ejemplo server/.dev.vars               # y rellenar

# 2. dependencias
cd app_flutter && flutter pub get && cd ..
cd server && npm install && cd ..

# 3. sesión de Cloudflare (abre el navegador, una sola vez por máquina)
cd server && npx wrangler login

# 4. compilar
cd ../app_flutter && bash compilar.sh
```

`google-services.json` **no hace falta**: la app inicializa Firebase con los
valores de `claves.env`. Está en el repositorio ignorado por si acaso, pero no
es necesario copiarlo.

---

## Para no volver a divergir

Usa **una sola rama** (`main`) en las dos máquinas, y antes de empezar a
trabajar:

```bash
git pull origin main
```

Al terminar, `git push origin main`. Si las dos máquinas tocan lo mismo sin
sincronizar, git no pierde nada, pero toca fusionar a mano.
