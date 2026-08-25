#!/bin/bash
# Despliegue de Alerta Sísmica en Cloudflare (plan gratuito).
#
# Antes de ejecutarlo hay que haber iniciado sesión una sola vez:
#     npx wrangler login
#
# Este script hace el resto: crea la base de datos, aplica el esquema, carga
# los secretos desde .dev.vars y publica el servidor con el panel.
set -e

cd "$(dirname "$0")"
echo "== Alerta Sísmica · despliegue =="
echo ""

# ---------- 1. Comprobar sesión ----------
echo "[1/6] Comprobando la sesión de Cloudflare..."
if ! npx wrangler whoami 2>&1 | grep -qi "You are logged in\|associated with the email"; then
  echo ""
  echo "  No hay sesión iniciada. Ejecuta primero:"
  echo "      npx wrangler login"
  echo "  (se abre el navegador; autoriza y vuelve aquí)"
  exit 1
fi
echo "      sesión activa"

# ---------- 2. Base de datos ----------
echo "[2/6] Base de datos D1..."
ID_ACTUAL=$(grep -oE 'database_id = "[^"]*"' wrangler.toml | cut -d'"' -f2)
if [ "$ID_ACTUAL" = "local-dev-placeholder" ] || [ -z "$ID_ACTUAL" ]; then
  echo "      creando 'alerta_sismica'..."
  SALIDA=$(npx wrangler d1 create alerta_sismica 2>&1 || true)
  NUEVO_ID=$(echo "$SALIDA" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  if [ -z "$NUEVO_ID" ]; then
    # Puede existir de un intento anterior: se busca en la lista.
    NUEVO_ID=$(npx wrangler d1 list 2>/dev/null | grep "alerta_sismica" | grep -oE "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" | head -1)
  fi
  if [ -z "$NUEVO_ID" ]; then
    echo "      ERROR: no se pudo obtener el identificador de la base."
    echo "      Salida de Cloudflare:"; echo "$SALIDA" | tail -5
    exit 1
  fi
  sed -i "s|database_id = \"[^\"]*\"|database_id = \"$NUEVO_ID\"|" wrangler.toml
  echo "      creada e inscrita en wrangler.toml"
else
  echo "      ya configurada ($ID_ACTUAL)"
fi

# ---------- 3. Esquema ----------
echo "[3/6] Aplicando el esquema a la base remota..."
npx wrangler d1 execute alerta_sismica --remote --file=./schema.sql --yes > /dev/null 2>&1 \
  || npx wrangler d1 execute alerta_sismica --remote --file=./schema.sql > /dev/null
echo "      tablas creadas"

# ---------- 4. Secretos ----------
echo "[4/6] Cargando secretos desde .dev.vars..."
if [ ! -f .dev.vars ]; then
  echo "      ERROR: falta .dev.vars con las credenciales de Firebase."
  exit 1
fi
for CLAVE in ADMIN_TOKEN PANEL_TOKEN FCM_PROJECT_ID FCM_CLIENT_EMAIL FCM_PRIVATE_KEY; do
  VALOR=$(grep "^$CLAVE=" .dev.vars | head -1 | cut -d= -f2-)
  if [ -z "$VALOR" ]; then
    echo "      aviso: $CLAVE está vacío, se omite"
    continue
  fi
  printf '%s' "$VALOR" | npx wrangler secret put "$CLAVE" > /dev/null 2>&1
  echo "      $CLAVE cargado"
done

# ---------- 5. Panel ----------
echo "[5/6] Comprobando el panel..."
if [ ! -f publico/panel/main.dart.js ]; then
  echo "      no está compilado; compilando ahora..."
  (cd ../app_flutter && MSYS_NO_PATHCONV=1 flutter build web -t lib/panel_main.dart --release --base-href=/panel/ > /dev/null)
  rm -f ../app_flutter/build/web/canvaskit/*.symbols ../app_flutter/build/web/canvaskit/*/*.symbols 2>/dev/null || true
  mkdir -p publico/panel
  cp -r ../app_flutter/build/web/. publico/panel/
  cp panel/fallas.json publico/panel/fallas.json
fi
echo "      panel listo"

# ---------- 6. Publicar ----------
echo "[6/6] Publicando..."
SALIDA=$(npx wrangler deploy 2>&1)
echo "$SALIDA" | tail -6
URL=$(echo "$SALIDA" | grep -oE 'https://[a-zA-Z0-9.-]+\.workers\.dev' | head -1)

echo ""
echo "=========================================="
if [ -n "$URL" ]; then
  echo " SERVIDOR PUBLICADO"
  echo "   API   : $URL/v1/salud"
  echo "   Panel : $URL/panel/"
  echo ""
  echo " Ahora recompila la app apuntando ahí:"
  echo "   cd ../app_flutter"
  echo "   MSYS_NO_PATHCONV=1 flutter build apk --release \\"
  echo "       --dart-define=SERVIDOR_URL=$URL"
else
  echo " Publicado, pero no se detectó la URL en la salida."
  echo " Búscala arriba o en el panel de Cloudflare."
fi
echo "=========================================="
