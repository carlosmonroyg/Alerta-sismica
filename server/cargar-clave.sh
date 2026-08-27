#!/bin/bash
# Inserta la clave privada de la cuenta de servicio en .dev.vars SIN mostrarla.
#
#     bash cargar-clave.sh ~/Downloads/clave.json
#
# Lee el campo private_key del JSON que entrega Google, lo convierte a una
# sola línea con \n literales —la forma que fcm.js sabe interpretar— y
# reemplaza la línea FCM_PRIVATE_KEY= de .dev.vars.
#
# Existe para que la credencial viaje de archivo a archivo y no pase nunca por
# la pantalla, el portapapeles compartido ni un chat.
set -e
cd "$(dirname "$0")"

JSON="${1:-}"
if [ -z "$JSON" ] || [ ! -f "$JSON" ]; then
  echo "Uso: bash cargar-clave.sh <ruta al clave.json descargado>"
  echo "Ejemplo: bash cargar-clave.sh ~/Downloads/clave.json"
  exit 1
fi
[ -f .dev.vars ] || { echo "Falta .dev.vars"; exit 1; }

# node hace el trabajo: extrae el campo y escapa los saltos de línea reales.
CLAVE=$(node -e '
const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
if (!j.private_key) { console.error("El JSON no tiene private_key"); process.exit(1); }
process.stdout.write(j.private_key.replace(/\n/g, "\\n"));
' "$JSON")

CORREO=$(node -e '
const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(j.client_email || "");
' "$JSON")

# Reescribir la línea sin volcar el valor por pantalla.
node -e '
const fs = require("fs");
const [ruta, clave, correo] = process.argv.slice(1);
let t = fs.readFileSync(ruta, "utf8");
t = t.replace(/^FCM_PRIVATE_KEY=.*$/m, "FCM_PRIVATE_KEY=" + clave);
if (correo) t = t.replace(/^FCM_CLIENT_EMAIL=.*$/m, "FCM_CLIENT_EMAIL=" + correo);
fs.writeFileSync(ruta, t);
' .dev.vars "$CLAVE" "$CORREO"

echo "Clave insertada en .dev.vars (${#CLAVE} caracteres)."
echo "Cuenta: $CORREO"
echo ""
echo "Ahora puedes borrar el JSON descargado:"
echo "    rm \"$JSON\""
