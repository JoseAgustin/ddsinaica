#!/usr/bin/env bash
# =============================================================================
# sinaica_descarga.sh v2.0
# Descarga datos de calidad del aire desde SINAICA/INECC
#
# Endpoint verificado (marzo 2026):
#   POST https://sinaica.inecc.gob.mx/pags/datGrafs.php
#
# Estructura JSON real de la respuesta (verificada con curl):
#   var dat = [
#     {"id":"249O326022400","fecha":"2026-02-24","hora":0,
#      "valor":0.009,"bandO":"","val":1}, ...
#   ];
#
# DIFERENCIAS respecto al paquete R rsinaica (version antigua):
#   Campo antiguo  ->  Campo actual (2026)
#   "date"         ->  "fecha"
#   "hour"         ->  "hora"
#   "value"        ->  "valor"
#   "valid"        ->  "val"
#   (nuevo)        ->  "bandO"  (bandera de calidad)
#
# Uso:
#   bash sinaica_descarga.sh -e 249 -p O3   -f 2026-02-24 -r 1dia
#   bash sinaica_descarga.sh -e 271 -p PM10 -f 2026-01-01 -r 1mes -t V
#   bash sinaica_descarga.sh -e 249 -p O3   -f 2026-02-24 -r 1dia -o datos.json
#   bash sinaica_descarga.sh -e 249 -p O3   -f 2026-02-24 -r 1dia -c -o datos.csv
#
# Opciones:
#   -e  ID de la estacion              [requerido]
#   -p  Codigo del contaminante        [requerido]
#       PM10 PM2.5 O3 CO NO2 SO2 NO NOx TMP HR PB RS PP PST etc.
#   -f  Fecha inicio YYYY-MM-DD        [requerido]
#   -r  Rango de la consulta           [requerido]
#       1dia | 1semana | 2semanas | 1mes | 1anio | 2anios
#   -t  Tipo de datos (default "")     [opcional]
#       "" Crude (default)  V Validated  M Manual
#   -o  Archivo de salida              [opcional, default stdout]
#   -c  Exportar como CSV (requiere python3)
#   -v  Verbose (cabeceras HTTP)
#   -h  Mostrar ayuda
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $1" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1" >&2; }

ESTACION_ID=""
PARAM=""
FECHA_INI=""
RANGO=""
TIPO_DATOS=""
ARCHIVO_SALIDA=""
CONVERTIR_CSV=0
VERBOSE=0

URL="https://sinaica.inecc.gob.mx/pags/datGrafs.php"
USER_AGENT="Mozilla/5.0 (compatible; sinaica_descarga/2.0)"

while getopts "e:p:f:r:t:o:cvh" opt; do
  case $opt in
    e) ESTACION_ID="$OPTARG" ;;
    p) PARAM="$OPTARG" ;;
    f) FECHA_INI="$OPTARG" ;;
    r) RANGO="$OPTARG" ;;
    t) TIPO_DATOS="$OPTARG" ;;
    o) ARCHIVO_SALIDA="$OPTARG" ;;
    c) CONVERTIR_CSV=1 ;;
    v) VERBOSE=1 ;;
    h) grep "^#" "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) error "Opcion desconocida. Use -h para ayuda." ;;
  esac
done

# -- Validaciones -------------------------------------------------------------
[ -z "$ESTACION_ID" ] && error "Se requiere -e <estacionId>. Ej: -e 249"
[ -z "$PARAM"       ] && error "Se requiere -p <param>. Ej: -p O3"
[ -z "$FECHA_INI"   ] && error "Se requiere -f <fecha> YYYY-MM-DD. Ej: -f 2026-02-24"
[ -z "$RANGO"       ] && error "Se requiere -r <rango>: 1dia|1semana|2semanas|1mes|1anio|2anios"

echo "$FECHA_INI" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || \
  error "fechaIni '$FECHA_INI' no esta en formato YYYY-MM-DD"

case "$RANGO" in
  1dia|1semana|2semanas|1mes|1anio|2anios) ;;
  *) error "Rango invalido. Use: 1dia | 1semana | 2semanas | 1mes | 1anio | 2anios" ;;
esac

case "$TIPO_DATOS" in
  ""|V|M) ;;
  *) error "tipoDatos invalido. Use: '' Crude | V Validated | M Manual" ;;
esac

TIPO_LABEL="Crude (crudos, no validados)"
[ "$TIPO_DATOS" = "V" ] && TIPO_LABEL="Validated (validados)"
[ "$TIPO_DATOS" = "M" ] && TIPO_LABEL="Manual"

info "POST $URL"
info "estacionId=${ESTACION_ID} | param=${PARAM} | fechaIni=${FECHA_INI} | rango=${RANGO} | tipoDatos='${TIPO_DATOS}' (${TIPO_LABEL})"

CURL_EXTRA=""
[ $VERBOSE -eq 1 ] && CURL_EXTRA="--verbose"

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# -- Peticion HTTP ------------------------------------------------------------
# Campos y endpoint verificados contra el servidor real (marzo 2026).
# La respuesta es HTML con el JSON embebido como variable JavaScript:
#   var dat = [{"id":"...","fecha":"...","hora":N,"valor":N,"bandO":"","val":N},...];
HTTP_CODE=$(curl \
  --silent --show-error --insecure \
  --request POST \
  $CURL_EXTRA \
  --url "$URL" \
  --header "User-Agent: $USER_AGENT" \
  --header "Referer: https://sinaica.inecc.gob.mx/data.php" \
  --header "X-Requested-With: XMLHttpRequest" \
  --data-urlencode "estacionId=${ESTACION_ID}" \
  --data-urlencode "param=${PARAM}" \
  --data-urlencode "fechaIni=${FECHA_INI}" \
  --data-urlencode "rango=${RANGO}" \
  --data-urlencode "tipoDatos=${TIPO_DATOS}" \
  --write-out "%{http_code}" \
  --output "$TMPFILE")

if [ "$HTTP_CODE" != "200" ]; then
  error "HTTP $HTTP_CODE — $(head -c 200 "$TMPFILE")"
fi
info "HTTP $HTTP_CODE OK"

RAW_HTML=$(cat "$TMPFILE")

# -- Extraer JSON del HTML ----------------------------------------------------
# El HTML contiene la variable JS:
#   var dat = [{...},{...},...];
# grep -o  : extrae la linea completa con el array
# primer sed : elimina el prefijo "var dat = "
# segundo sed: elimina el ";" final
if ! echo "$RAW_HTML" | grep -q "var dat"; then
  warn "Sin datos: la respuesta no contiene 'var dat'."
  warn "Estacion=${ESTACION_ID} | Param=${PARAM} | Fecha=${FECHA_INI} | Rango=${RANGO}"
  info "Preview HTML: $(echo "$RAW_HTML" | head -c 500)"
  JSON_LIMPIO="[]"
else
  JSON_LIMPIO=$(echo "$RAW_HTML" \
    | grep -o 'var dat = \[.\{0,\}\];' \
    | sed 's/^var dat = //' \
    | sed 's/;$//')

  if [ "$JSON_LIMPIO" = "[]" ] || [ -z "$JSON_LIMPIO" ]; then
    warn "Array vacio. Sin datos para el periodo solicitado."
    JSON_LIMPIO="[]"
  fi
fi

# -- Contar registros ---------------------------------------------------------
# Se cuenta por "hora" (campo actual) — NO por "hour" (nombre antiguo del paquete R).
N_REGISTROS=0
if [ "$JSON_LIMPIO" != "[]" ]; then
  N_REGISTROS=$(echo "$JSON_LIMPIO" | grep -o '"hora"' | wc -l | tr -d ' ')
  ok "$N_REGISTROS registros descargados."
else
  warn "0 registros."
fi

# -- Salida: CSV o JSON -------------------------------------------------------
#
# Logica de prioridad:
#   -c          -> convierte a CSV, nombre automatico
#   -c -o f.csv -> convierte a CSV, guarda en f.csv  (o f.csv si pasan .json)
#   -o f.json   -> guarda JSON en f.json
#   (ninguno)   -> imprime JSON a stdout
#
if [ $CONVERTIR_CSV -eq 1 ] && [ "$JSON_LIMPIO" != "[]" ]; then
  # Determinar nombre del archivo CSV de salida
  if [ -n "$ARCHIVO_SALIDA" ]; then
    # Si el usuario paso -o archivo.json -> cambiar extension a .csv
    # Si ya paso .csv -> usarlo tal cual
    CSV_SALIDA="${ARCHIVO_SALIDA%.*}.csv"
  else
    CSV_SALIDA="sinaica_${ESTACION_ID}_${PARAM}_${FECHA_INI}_${RANGO}.csv"
  fi

  if command -v python3 > /dev/null 2>&1; then
    # Escribir JSON en archivo temporal para pasarlo a python sin problemas de escape
    JSON_TMP=$(mktemp)
    echo "$JSON_LIMPIO" > "$JSON_TMP"

    python3 /dev/stdin "$JSON_TMP" "$CSV_SALIDA" "$ESTACION_ID" "$PARAM" << 'PYTHON'
import json, csv, sys

json_file = sys.argv[1]
csv_file  = sys.argv[2]
estacion  = sys.argv[3]
parametro = sys.argv[4]

with open(json_file, encoding="utf-8") as f:
    data = json.load(f)

if not data:
    print("Sin datos para convertir.", file=sys.stderr)
    sys.exit(0)

# Columnas: campos del JSON + contexto (estacion_id, parametro)
cols = list(data[0].keys()) + ["estacion_id", "parametro"]

# utf-8-sig = UTF-8 con BOM, compatible con Excel en espanol
with open(csv_file, "w", newline="", encoding="utf-8-sig") as f:
    writer = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
    writer.writeheader()
    for row in data:
        row["estacion_id"] = estacion
        row["parametro"]   = parametro
        writer.writerow(row)

print(f"CSV guardado: {csv_file} ({len(data)} filas)", file=sys.stderr)
PYTHON

    rm -f "$JSON_TMP"
    ok "CSV guardado en: $CSV_SALIDA ($N_REGISTROS registros)"

  else
    warn "python3 no disponible — guardando como JSON en su lugar."
    FALLBACK="${CSV_SALIDA%.*}.json"
    echo "$JSON_LIMPIO" > "$FALLBACK"
    ok "JSON guardado en: $FALLBACK"
  fi

elif [ -n "$ARCHIVO_SALIDA" ]; then
  # Sin -c: guardar JSON en el archivo indicado con -o
  echo "$JSON_LIMPIO" > "$ARCHIVO_SALIDA"
  ok "JSON guardado en: $ARCHIVO_SALIDA ($N_REGISTROS registros)"

else
  # Sin -c ni -o: imprimir JSON a stdout
  echo "$JSON_LIMPIO"
fi

# Pausa aleatoria: replica Sys.sleep(runif(1, max=0.5)) del paquete R
PAUSA=$(awk 'BEGIN{srand(); printf "%.2f\n", rand() * 0.5}')
sleep "$PAUSA"
