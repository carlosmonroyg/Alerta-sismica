#!/bin/bash
# Compila la app inyectando los valores de claves.env, que queda fuera del
# repositorio. Así ninguna clave vive en el código.
#
#     bash compilar.sh          # APK de release
#     bash compilar.sh panel    # panel web (Flutter Web)
set -e
cd "$(dirname "$0")"

if [ ! -f claves.env ]; then
  echo "Falta claves.env. Créalo a partir de la plantilla:"
  echo "    cp claves.ejemplo.env claves.env"
  echo "y rellena los valores (la URL la imprime server/desplegar.sh)."
  exit 1
fi

# Se leen sin 'source' para que un valor con espacios o símbolos no se
# interprete como código.
DEFINES=""
while IFS= read -r linea; do
  case "$linea" in \#*|"") continue;; esac
  CLAVE="${linea%%=*}"
  VALOR="${linea#*=}"
  [ -z "$VALOR" ] && continue
  DEFINES="$DEFINES --dart-define=$CLAVE=$VALOR"
done < claves.env

if [ -z "$DEFINES" ]; then
  echo "aviso: claves.env no tiene ningún valor; se compila sin servidor ni push."
fi

# MSYS_NO_PATHCONV: en Git Bash, sin esto las dobles barras de las URL se
# convierten en rutas de Windows y la app queda apuntando a la nada.
export MSYS_NO_PATHCONV=1

if [ "$1" = "panel" ]; then
  echo "Compilando el panel web..."
  flutter build web -t lib/panel_main.dart --release --base-href=/panel/ $DEFINES
  echo "Listo: build/web  (cópialo a ../server/publico/panel/)"
else
  echo "Compilando el APK de release..."
  flutter build apk --release $DEFINES
  echo "Listo: build/app/outputs/flutter-apk/app-release.apk"
fi
