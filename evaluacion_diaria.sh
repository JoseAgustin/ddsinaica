#!/usr/bin/env bash
# =============================================================================
# evaluacion_diaria.sh  v2.1.0
# =============================================================================
#
# DESCRIPCIÓN
# -----------
# Orquestador del pipeline diario de evaluación del pronóstico de calidad del
# aire generado por WRF-Chem.  Compara las salidas del modelo contra
# observaciones horarias de la red SINAICA/INECC para siete ciudades del
# centro de México.
#
# A partir de la v2.1.0 la descarga de observaciones se realiza íntegramente
# mediante sinaica_descarga.sh (HTTP directo), eliminando la dependencia de
# baja_CAMe.py / R / rsinaica. Se actualizan mapeo de estaciones y combina.py
#
# FLUJO DE EJECUCIÓN
# ------------------
#   1. Validar argumentos y dependencias del sistema
#   2. Verificar disponibilidad de archivos wrfout en LUSTRE
#   3. Descargar observaciones horarias vía sinaica_descarga.sh
#   4. Validar archivos descargados (tamaño, registros mínimos)
#   5. Normalizar CSV al formato de calidad_aire_pipeline.sh
#   6. Procesar observaciones (separación + consolidación por ciudad)
#   7. Extraer O3 / PM10 / PM2.5 de cada wrfout (extract_dia.py)
#   8. Combinar observaciones + modelo por fecha (combinar_dia.py)
#   9. Calcular métricas estadísticas ventana 30 días (stats_dia.py)
#  10. Generar página HTML del día (generar_html.py)
#  11. Actualizar índice histórico web/index.html
#  12. Limpieza de temporales y registro final en log
#
# HORIZONTES DE PRONÓSTICO
# ------------------------
#   FECHA_EVAL  = ayer (o el argumento pasado)
#   RUN_D1      = FECHA_EVAL       → dia1 del run  (+24 h)
#   RUN_D2      = FECHA_EVAL − 1d  → dia2 del run  (+48 h)
#   RUN_D3      = FECHA_EVAL − 2d  → dia3 del run  (+72 h)
#
# USO
# ---
#   bash evaluacion_diaria.sh [YYYY-MM-DD]
#
#   Sin argumento : evalúa el día anterior al actual  (modo crontab)
#   Con argumento : evalúa la fecha indicada           (modo reproceso)
#
#   Ejemplos:
#     bash evaluacion_diaria.sh
#     bash evaluacion_diaria.sh 2026-03-15
#
# INSTALACIÓN EN CRONTAB
# ----------------------
#   crontab -e
#   # Ejecutar cada día a las 07:00 con log rotativo:
#   0 7 * * * /opt/wrf/evaluacion/evaluacion_diaria.sh \
#             >> /opt/wrf/evaluacion/logs/cron_$(date +\%Y\%m\%d).log 2>&1
#
# PREREQUISITOS
# -------------
#   Sistema : bash >= 4, curl, awk, sort, sed, python3 >= 3.8
#   Python  : ver requirements.txt
#   Scripts : sinaica_descarga.sh, calidad_aire_pipeline.sh
#             (deben estar en el mismo directorio que este script)
#
# VARIABLES DE ENTORNO (opcionales)
# ----------------------------------
#   EVALUACION_DIR   Ruta del proyecto        [default: directorio del script]
#   WRF_DIR          Ruta de archivos wrfout  [default: ver SECCIÓN 1]
#   PYTHON_BIN       Ejecutable Python        [default: python3]
#   SINAICA_TIPO     Tipo de datos SINAICA    [default: "" (Crude)]
#                    "" = crudos  |  V = validados  |  M = manual
#
# CONFIGURACIÓN DE ESTACIONES
# ----------------------------
#   conf/estaciones.conf  (TSV, generado automáticamente la primera vez)
#   Formato: ESTACION_ID <TAB> CIUDAD_WRF <TAB> CONT_SINAICA <TAB>
#            NOMBRE_RED  <TAB> NOMBRE_ESTACION
#
# AUTOR
# -----
#   Pipeline WRF-Chem / Red de Calidad del Aire — Centro de México
#   v2.0.0  |  2026
#
# =============================================================================

set -euo pipefail

# =============================================================================
# ── SECCIÓN 1: CONFIGURACIÓN GLOBAL ──────────────────────────────────────────
# Todas las variables configurables están aquí.  No modificar el resto
# del script salvo para correcciones de lógica.
# =============================================================================

# --------------------------------------------------------------------------
# 1.1  Rutas base
# --------------------------------------------------------------------------
# DIR_PROYECTO: directorio raíz del repositorio.
# Por defecto es el directorio que contiene este script (portable).
DIR_PROYECTO="${EVALUACION_DIR:-$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd )}"

# Raíz del almacenamiento WRF-Chem.
# Los wrfout se buscan en: ${DIR_WRF}/<ANIO>/wrfout_d01_YYYY-MM-DD_00:00:00
DIR_WRF="${WRF_DIR:-/LUSTRE/OPERATIVO/EXTERNO-salidas/WRF-CHEM}"

# --------------------------------------------------------------------------
# 1.2  Subdirectorios del proyecto
# --------------------------------------------------------------------------
DIR_SCRIPTS="${DIR_PROYECTO}"
DIR_CONF="${DIR_PROYECTO}/conf"
DIR_OBS="${DIR_PROYECTO}/observado"
DIR_MODELO="${DIR_PROYECTO}/modelo"
DIR_COMBINADO="${DIR_PROYECTO}/combinado"
DIR_AJUSTADOS="${DIR_COMBINADO}/ajustados"
DIR_LOGS="${DIR_PROYECTO}/logs"
DIR_TMP="${DIR_PROYECTO}/tmp"
DIR_WEB="${DIR_PROYECTO}/web"

# --------------------------------------------------------------------------
# 1.3  Ejecutables
# --------------------------------------------------------------------------
PYTHON="${PYTHON_BIN:-python3}"
SINAICA_SH="${DIR_SCRIPTS}/sinaica_descarga.sh"
PIPELINE_SH="${DIR_SCRIPTS}/calidad_aire_pipeline.sh"

# --------------------------------------------------------------------------
# 1.4  Ciudades del dominio WRF-Chem
# --------------------------------------------------------------------------
# Formato: "NOMBRE_MODELO:lat_sur:lat_norte:lon_oeste:lon_este"
declare -a CIUDADES_WRF=(
    "CDMX:19.20:19.70:-99.30:-98.85"
    "Toluca:19.23:19.39:-99.72:-99.50"
    "Puebla:18.95:19.12:-98.32:-98.10"
    "Tlaxcala:19.29:19.36:-98.26:-98.15"
    "Pachuca:20.03:20.13:-98.80:-98.67"
    "Cuernavaca:18.89:18.98:-99.26:-99.14"
    "SJdelRio:20.36:20.41:-100.01:-99.93"
)

# Mapeo nombre modelo → prefijo del consolidado de observaciones
declare -A CIUDAD_OBS_MAP=(
    [CDMX]="CDMX"
    [Toluca]="Toluca"
    [Puebla]="Puebla"
    [Tlaxcala]="Tlaxcala"
    [Pachuca]="Pachuca"
    [Cuernavaca]="Cuernavaca"
    [SJdelRio]="San Juan del Rio"
)

# --------------------------------------------------------------------------
# 1.5  Contaminantes y umbrales normativos
# --------------------------------------------------------------------------
# Umbrales para métricas dicotómicas:
#   O3   → NOM-020-SSA1      (135 ppbv)
#   PM10 → NOM-025-SSA1-2021 ( 75 µg/m³ promedio 24 h)
#   PM25 → NOM-025-SSA1-2021 ( 45 µg/m³ promedio 24 h)
declare -A UMBRAL=([o3]=135 [PM10]=75 [PM25]=45)
CONTAMINANTES_MODELO=("o3" "PM10" "PM25")

# --------------------------------------------------------------------------
# 1.6  Parámetros de descarga SINAICA
# --------------------------------------------------------------------------
SINAICA_TIPO="${SINAICA_TIPO:-}"    # "" = Crude; "V" = Validated; "M" = Manual
SINAICA_RANGO="1dia"               # rango por ejecución diaria
DESCARGA_REINTENTOS=3              # reintentos ante error HTTP
DESCARGA_PAUSA=2                   # segundos entre reintentos
REGISTROS_MINIMOS=18               # mínimo de horas para considerar descarga válida

# --------------------------------------------------------------------------
# 1.7  Parámetros estadísticos
# --------------------------------------------------------------------------
VENTANA_DIAS=30    # días de histórico para métricas de contexto

# --------------------------------------------------------------------------
# 1.8  Fecha de evaluación
# --------------------------------------------------------------------------
# Acepta argumento posicional $1 en formato YYYY-MM-DD.
# Sin argumento: evalúa el día anterior (modo crontab normal).
if [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    FECHA_EVAL="$1"
    MODO_EJECUCION="REPROCESO"
elif [[ -z "${1:-}" ]]; then
    FECHA_EVAL=$(date -d "yesterday" +%Y-%m-%d)
    MODO_EJECUCION="AUTOMATICO"
else
    echo "ERROR: argumento inválido '${1}'. Use YYYY-MM-DD o sin argumento." >&2
    exit 1
fi

# Derivar los tres runs que cubren FECHA_EVAL
RUN_D1="${FECHA_EVAL}"
RUN_D2=$(date -d "${FECHA_EVAL} -1 day"  +%Y-%m-%d)
RUN_D3=$(date -d "${FECHA_EVAL} -2 days" +%Y-%m-%d)

ANIO_EVAL=$(date -d "${FECHA_EVAL}" +%Y)
MES_EVAL=$( date -d "${FECHA_EVAL}" +%m)

# Marca de tiempo de inicio (para calcular duración al final)
TS_INICIO=$(date +%s)

# =============================================================================
# ── SECCIÓN 2: FUNCIONES UTILITARIAS ─────────────────────────────────────────
# =============================================================================

# --------------------------------------------------------------------------
# 2.1  Colores (se desactivan si la salida no es una TTY)
# --------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_GRN="\033[0;32m"; C_YLW="\033[1;33m"
    C_CYN="\033[0;36m"; C_RED="\033[0;31m"
    C_BLD="\033[1m";    C_RST="\033[0m"
else
    C_GRN=""; C_YLW=""; C_CYN=""; C_RED=""; C_BLD=""; C_RST=""
fi

# --------------------------------------------------------------------------
# 2.2  Funciones de log
# --------------------------------------------------------------------------
# LOG_FILE se define en la Sección 3, después de crear DIR_LOGS.
# Hasta ese momento las funciones escriben solo a stdout.
_ts()   { date "+%Y-%m-%d %H:%M:%S"; }

info()  { echo -e "$(_ts) ${C_CYN}[INFO]${C_RST}  $*" | tee -a "${LOG_FILE:-/dev/null}"; }
ok()    { echo -e "$(_ts) ${C_GRN}[OK]  ${C_RST}  $*" | tee -a "${LOG_FILE:-/dev/null}"; }
warn()  { echo -e "$(_ts) ${C_YLW}[WARN]${C_RST}  $*" | tee -a "${LOG_FILE:-/dev/null}"; }
error() { echo -e "$(_ts) ${C_RED}[ERROR]${C_RST} $*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
step()  {
    local linea
    linea="$(_ts) ${C_BLD}${C_CYN}▶  $*${C_RST}"
    echo -e "\n${linea}" | tee -a "${LOG_FILE:-/dev/null}"
}

# Abortar con mensaje y código 1
die() { error "$*"; exit 1; }

# --------------------------------------------------------------------------
# 2.3  Verificaciones de dependencias
# --------------------------------------------------------------------------
require_cmd() {
    command -v "$1" >/dev/null 2>&1 \
        || die "Dependencia no encontrada: '$1'. Verificar la instalación."
}

require_file() {
    [[ -f "$1" ]] || die "Archivo requerido no encontrado: $1"
}

# --------------------------------------------------------------------------
# 2.4  Construcción de ruta wrfout
# --------------------------------------------------------------------------
# Convención del servidor: <DIR_WRF>/<ANIO>/wrfout_d01_YYYY-MM-DD_00:00:00
wrfout_path() {
    local fecha="$1"
    local anio; anio=$(date -d "$fecha" +%Y)
    echo "${DIR_WRF}/${anio}/wrfout_d01_${fecha}_00:00:00"
}

# --------------------------------------------------------------------------
# 2.5  Descarga de una estación con reintentos
# --------------------------------------------------------------------------
# Envuelve sinaica_descarga.sh añadiendo reintentos automáticos y logging.
# Retorna 0 si la descarga fue exitosa, 1 si falló todos los reintentos.
#
# Uso: descargar_estacion <id> <param> <fecha> <archivo_csv>
descargar_estacion() {
    local est_id="$1"
    local param="$2"
    local fecha="$3"
    local destino="$4"
    local intento=1

    while (( intento <= DESCARGA_REINTENTOS )); do
        # sinaica_descarga.sh escribe sus propios mensajes a stderr;
        # los redirigimos al log para no contaminar stdout del orquestador.
        if bash "${SINAICA_SH}" \
               -e "${est_id}" \
               -p "${param}" \
               -f "${fecha}" \
               -r "${SINAICA_RANGO}" \
               ${SINAICA_TIPO:+-t "${SINAICA_TIPO}"} \
               -c \
               -o "${destino}" \
               2>>"${LOG_FILE:-/dev/null}"; then
            return 0
        fi
        warn "    Intento ${intento}/${DESCARGA_REINTENTOS} fallido (id=${est_id}, param=${param})"
        (( intento++ )) || true
        sleep "${DESCARGA_PAUSA}"
    done

    warn "    Descarga fallida tras ${DESCARGA_REINTENTOS} intentos: id=${est_id}, param=${param}"
    return 1
}

# --------------------------------------------------------------------------
# 2.6  Contar registros de un CSV (excluye encabezado)
# --------------------------------------------------------------------------
contar_registros() {
    local archivo="$1"
    [[ -f "${archivo}" ]] || { echo 0; return; }
    echo $(( $(wc -l < "${archivo}") - 1 ))
}

# --------------------------------------------------------------------------
# 2.7  Validar CSV descargado
# --------------------------------------------------------------------------
# Retorna 0 si el CSV tiene al menos REGISTROS_MINIMOS filas de datos.
validar_csv() {
    local archivo="$1"
    local n; n=$(contar_registros "${archivo}")
    if (( n >= REGISTROS_MINIMOS )); then
        return 0
    else
        warn "    CSV inválido o insuficiente: ${archivo##*/} (${n} registros, mínimo ${REGISTROS_MINIMOS})"
        return 1
    fi
}

# =============================================================================
# ── SECCIÓN 3: INICIALIZACIÓN ────────────────────────────────────────────────
# =============================================================================

# Crear árbol de directorios completo
mkdir -p \
    "${DIR_LOGS}" "${DIR_TMP}" "${DIR_CONF}" \
    "${DIR_OBS}"  "${DIR_MODELO}" \
    "${DIR_COMBINADO}" "${DIR_AJUSTADOS}" \
    "${DIR_WEB}/css" "${DIR_WEB}/${ANIO_EVAL}/${MES_EVAL}" \
    "${DIR_TMP}/raw_sinaica" "${DIR_TMP}/extraidos" \
    "${DIR_TMP}/pipeline_work"

# Definir LOG_FILE ahora que DIR_LOGS existe
LOG_FILE="${DIR_LOGS}/evaluacion_${FECHA_EVAL}.log"

# Limpiar scripts Python temporales de ejecuciones anteriores
find "${DIR_TMP}" -maxdepth 1 \( -name "*.py" -o -name "*.tmp" \) \
    -delete 2>/dev/null || true

# --------------------------------------------------------------------------
# 3.1  Verificar dependencias del sistema
# --------------------------------------------------------------------------
require_cmd bash
require_cmd curl
require_cmd awk
require_cmd sort
require_cmd python3
require_cmd "${PYTHON}"
require_file "${SINAICA_SH}"
require_file "${PIPELINE_SH}"

# --------------------------------------------------------------------------
# 3.2  Encabezado del log
# --------------------------------------------------------------------------
{
printf '%s\n' \
  "============================================================" \
  " EVALUACIÓN DIARIA WRF-Chem  v2.0.0" \
  " Modo          : ${MODO_EJECUCION}" \
  " Fecha eval    : ${FECHA_EVAL}" \
  " Run D1 (+24h) : ${RUN_D1}" \
  " Run D2 (+48h) : ${RUN_D2}" \
  " Run D3 (+72h) : ${RUN_D3}" \
  " Python        : $("${PYTHON}" --version 2>&1)" \
  " Log           : ${LOG_FILE}" \
  " Inicio        : $(date '+%Y-%m-%d %H:%M:%S')" \
  "============================================================"
} | tee -a "${LOG_FILE}"

# =============================================================================
# ── SECCIÓN 4: VERIFICAR ARCHIVOS WRFOUT ─────────────────────────────────────
# =============================================================================

step "Etapa 1 — Verificación de archivos WRF-Chem"

declare -A WRFOUT_OK=()
declare -A WRFOUT_PATH=()

for run_fecha in "${RUN_D1}" "${RUN_D2}" "${RUN_D3}"; do
    ruta=$(wrfout_path "${run_fecha}")
    WRFOUT_PATH["${run_fecha}"]="${ruta}"
    if [[ -f "${ruta}" ]]; then
        sz=$(du -sh "${ruta}" 2>/dev/null | cut -f1)
        ok "  ✓ ${run_fecha}  →  $(basename "${ruta}")  [${sz}]"
        WRFOUT_OK["${run_fecha}"]=1
    else
        warn "  ✗ ${run_fecha}  →  NO encontrado: ${ruta}"
        WRFOUT_OK["${run_fecha}"]=0
    fi
done

# Contar cuántos están disponibles; si ninguno, abortar.
n_wrfout=0
for run_fecha in "${RUN_D1}" "${RUN_D2}" "${RUN_D3}"; do
    [[ "${WRFOUT_OK[${run_fecha}]}" -eq 1 ]] && (( n_wrfout++ )) || true
done

(( n_wrfout > 0 )) || die "Ningún archivo wrfout disponible para ${FECHA_EVAL}."
info "  wrfout disponibles: ${n_wrfout}/3"

# =============================================================================
# ── SECCIÓN 5: DESCARGA DE OBSERVACIONES (sinaica_descarga.sh) ───────────────
# =============================================================================
#
# Esta sección reemplaza completamente baja_CAMe.py / R / rsinaica.
#
# Lee conf/estaciones.conf para obtener los IDs de estación y parámetros,
# luego invoca sinaica_descarga.sh por cada combinación.
# El CSV resultante tiene el esquema real del API SINAICA (2026):
#   id, fecha, hora, valor, bandO, val, estacion_id, parametro
#
# =============================================================================

step "Etapa 2 — Descarga de observaciones (sinaica_descarga.sh)"

# --------------------------------------------------------------------------
# 5.1  Generar plantilla de estaciones.conf si no existe
# --------------------------------------------------------------------------
CONF_EST="${DIR_CONF}/estaciones.conf"

if [[ ! -f "${CONF_EST}" ]]; then
    warn "  ${CONF_EST} no encontrado. Creando plantilla..."
    cat > "${CONF_EST}" << 'EOF'
# =============================================================================
# conf/estaciones.conf  —  Catálogo de estaciones SINAICA
# =============================================================================
# Formato: campos separados por TAB (no espacios)
#
#   ESTACION_ID  CIUDAD_WRF  CONT_SINAICA  NOMBRE_RED           NOMBRE_ESTACION
#
# CONT_SINAICA : O3 | PM10 | PM2.5
# CIUDAD_WRF   : CDMX | Toluca | Puebla | Tlaxcala | Pachuca | Cuernavaca | SJdelRio
#
# PASOS PARA COMPLETAR:
#   1. Ir a https://sinaica.inecc.gob.mx  →  Datos  →  buscar la estación
#   2. El ID numérico aparece en la URL (ej. estacionId=249)
#   3. Reemplazar los IDs de ejemplo (999) por los reales
#   4. Agregar / eliminar filas según necesidad
#   5. Las líneas que empiezan con # son comentarios y se ignoran
#
# Estaciones de ejemplo verificadas (IDs ilustrativos — verificar en SINAICA):
# ---------------------------------------------------------------------------
134	Cuernavaca	O3	Cuernavaca	Cuernavaca 01
134	Cuernavaca	PM10	Cuernavaca	Cuernavaca 01
134	Cuernavaca	PM2.5	Cuernavaca	Cuernavaca 01
95	Pachuca	O3	Pachuca	Instituto Tecnológico de Pachuca
95	Pachuca	PM10	Pachuca	Instituto Tecnológico de Pachuca
95	Pachuca PM2.5	Pachuca	Instituto Tecnológico de Pachuca
501	Pachuca	O3	Pachuca	Primaria Ignacio Zaragoza
484	Puebla	O3	Puebla	Atlixco
484	Puebla	PM10	Puebla	Atlixco
484	Puebla	PM2.5	Puebla	Atlixco
162	Puebla	O3	Puebla	Las Ninfas
162	Puebla	PM10	Puebla	Las Ninfas
162	Puebla	PM2.5	Puebla	Las Ninfas
485	Puebla	O3	Puebla	San Martín Texmelucan
485	Puebla	PM10	Puebla	San Martín Texmelucan
485	Puebla	PM2.5	Puebla	San Martín Texmelucan
483	Puebla	O3	Puebla	Tehuacán
483	Puebla	PM10	Puebla	Tehuacán
483	Puebla	PM2.5	Puebla	Tehuacán
406	Puebla	O3	Puebla	Universidad Tecnológica de Puebla
406	Puebla  PM10	Puebla	Universidad Tecnológica de Puebla
406	Puebla  PM2.5	Puebla	Universidad Tecnológica de Puebla
410	San Juan del Rio	O3	San Juan del Rio	San Juan del Río
410	San Juan del Rio	PM2.5	San Juan del Rio	San Juan del Río
220	Tlaxcala	O3	Tlaxcala	Palacio de Gobierno
220	Tlaxcala	PM10	Tlaxcala	Palacio de Gobierno
220	Tlaxcala	PM2.5	Tlaxcala	Palacio de Gobierno
456	Toluca	O3	Toluca	Almoloya de Juárez
456	Toluca	PM10	Toluca	Almoloya de Juárez
456	Toluca	PM2.5	Toluca	Almoloya de Juárez
123	Toluca	O3	Toluca	Ceboruco
123	Toluca	PM10	Toluca	Ceboruco
123	Toluca	PM2.5	Toluca	Ceboruco
125	Toluca	O3	Toluca	Metepec
125	Toluca	PM10	Toluca	Metepec
125	Toluca	PM2.5	Toluca	Metepec
126	Toluca	O3	Toluca	Oxtotitlán
126	Toluca	PM10	Toluca	Oxtotitlán
126	Toluca	PM2.5	Toluca	Oxtotitlán
124	Toluca	O3	Toluca	Toluca Centro
124	Toluca	PM10	Toluca	Toluca Centro
124	Toluca	PM2.5   Toluca	Toluca Centro
242	CDMX	O3	Valle de México	Ajusco Medio
242	CDMX	PM10	Valle de México	Ajusco Medio
242	CDMX	PM2.5	Valle de México	Ajusco Medio
243	CDMX	O3	Valle de México	Atizapán
243	CDMX	PM10	Valle de México	Atizapán
244	CDMX	O3	Valle de México	Camarones
244	CDMX	PM10	Valle de México	Camarones
244	CDMX	PM2.5	Valle de México	Camarones
245	CDMX	O3	Valle de México	Centro de Ciencias de la Atmósfera
245	CDMX	PM2.5	Valle de México	Centro de Ciencias de la Atmósfera
248	CDMX	O3	Valle de México	Cuajimalpa
248	CDMX	PM10	Valle de México	Cuajimalpa
249	CDMX	O3	Valle de México	Cuautitlán
249	CDMX	PM10	Valle de México	Cuautitlán
250	CDMX	O3	Valle de México	FES Acatlán
250	CDMX	PM10	Valle de México	FES Acatlán
251	CDMX	O3	Valle de México	Hospital General de México
251	CDMX	PM10	Valle de México	Hospital General de México
251	CDMX	PM2.5	Valle de México	Hospital General de México
253	CDMX	O3	Valle de México	La Presa
254	CDMX	O3	Valle de México	Los Laureles
256	CDMX	O3	Valle de México	Merced
256	CDMX	PM10	Valle de México	Merced
256	CDMX	PM2.5	Valle de México	Merced
263	CDMX	O3	Valle de México	Miguel Hidalgo
263	CDMX	PM10	Valle de México	Miguel Hidalgo
263	CDMX	PM2.5	Valle de México	Miguel Hidalgo
257	CDMX	O3	Valle de México	Montecillo
257	CDMX	PM2.5	Valle de México	Montecillo
258	CDMX	O3	Valle de México	Nezahualcóyotl
258	CDMX	PM10	Valle de México	Nezahualcóyotl
258	CDMX	PM2.5	Valle de México	Nezahualcóyotl
259	CDMX	O3	Valle de México	Pedregal
259	CDMX	PM10	Valle de México	Pedregal
259	CDMX	PM2.5	Valle de México	Pedregal
260	CDMX	O3	Valle de México	San Agustín
260	CDMX	PM10	Valle de México	San Agustín
260	CDMX	PM2.5	Valle de México	San Agustín
432	CDMX	O3	Valle de México	Santiago Acahualtepec
432	CDMX	PM2.5	Valle de México	Santiago Acahualtepec
265	CDMX	O3	Valle de México	Tlahuac
265	CDMX	PM10	Valle de México	Tlahuac
266	CDMX	O3	Valle de México	Tlalnepantla
266	CDMX	PM10	Valle de México	Tlalnepantla
266	CDMX	PM2.5	Valle de México	Tlalnepantla
267	CDMX	O3	Valle de México	Tultitlán
267	CDMX	PM10	Valle de México	Tultitlán
268	CDMX	O3	Valle de México	UAM Iztapalapa
268	CDMX	PM10	Valle de México	UAM Iztapalapa
268	CDMX	PM2.5	Valle de México	UAM Iztapalapa
269	CDMX	O3	Valle de México	UAM Xochimilco
269	CDMX	PM2.5	Valle de México	UAM Xochimilco
270	CDMX	O3	Valle de México	Villa de las Flores
270	CDMX	PM10	Valle de México	Villa de las Flores
EOF
    warn "  Plantilla creada. Editar ${CONF_EST} con los IDs reales."
fi

# --------------------------------------------------------------------------
# 5.2  Iterar sobre el catálogo y descargar
# --------------------------------------------------------------------------
DIR_RAW="${DIR_TMP}/raw_sinaica/${FECHA_EVAL}"
mkdir -p "${DIR_RAW}"

n_ok=0; n_fallo=0; n_omitido=0

while IFS=$'\t' read -r est_id ciudad_wrf cont_sinaica nombre_red nombre_est \
      || [[ -n "${est_id:-}" ]]; do

    # Ignorar comentarios y líneas en blanco
    [[ "${est_id:-}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${est_id:-}"               ]] && continue

    # Ignorar IDs de ejemplo para evitar peticiones HTTP inútiles
    if [[ "${est_id}" == "999" ]]; then
        warn "  Omitiendo ID de ejemplo (999): ${nombre_est} / ${cont_sinaica}"
        (( n_omitido++ )) || true
        continue
    fi

    # Nombre seguro del contaminante para el nombre de archivo (sin puntos)
    cont_safe="${cont_sinaica//./}"

    # Destino del CSV: raw_sinaica/<fecha>/sinaica_<id>_<cont>_<fecha>.csv
    csv_dest="${DIR_RAW}/sinaica_${est_id}_${cont_safe}_${FECHA_EVAL}.csv"

    # En modo reproceso, omitir si ya existe y tiene datos suficientes
    if [[ "${MODO_EJECUCION}" == "REPROCESO" ]] && validar_csv "${csv_dest}" 2>/dev/null; then
        info "  ↷ Reutilizando: $(basename "${csv_dest}") ($(contar_registros "${csv_dest}") reg)"
        (( n_ok++ )) || true
        continue
    fi

    info "  ↓ est=${est_id} | ${nombre_est} | ${cont_sinaica} | ${nombre_red}"

    if descargar_estacion "${est_id}" "${cont_sinaica}" "${FECHA_EVAL}" "${csv_dest}"; then
        if validar_csv "${csv_dest}"; then
            ok "    ✓ $(basename "${csv_dest}") — $(contar_registros "${csv_dest}") registros"
            (( n_ok++ )) || true
        else
            # El archivo existe pero con pocos datos: se conserva para diagnóstico
            (( n_fallo++ )) || true
        fi
    else
        (( n_fallo++ )) || true
    fi

done < "${CONF_EST}"

info "  Resultado descarga — OK: ${n_ok} | Fallidos: ${n_fallo} | Omitidos: ${n_omitido}"

if (( n_ok == 0 )); then
    warn "  Sin observaciones nuevas. Continuando con datos previos en ${DIR_OBS}."
fi

# =============================================================================
# ── SECCIÓN 6: NORMALIZACIÓN DE CSV PARA calidad_aire_pipeline.sh ────────────
# =============================================================================
#
# sinaica_descarga.sh produce CSV con los campos del API actual (2026):
#   id, fecha, hora, valor, bandO, val, estacion_id, parametro
#
# calidad_aire_pipeline.sh espera archivos llamados:
#   calidad_aire_<Ciudad>_<Estacion>.csv
# cuya primera columna identifica el contaminante (contiene O3, PM10, PM2.5).
#
# Esta sección transforma los CSV de descarga al formato esperado por el
# pipeline, construyendo un identificador de fila compatible:
#   <estacion_id><CONT><fechahora>
#
# =============================================================================

step "Etapa 3 — Normalización de CSV al formato del pipeline"

DIR_PW="${DIR_TMP}/pipeline_work"
mkdir -p "${DIR_PW}"
rm -f "${DIR_PW}"/calidad_aire_*.csv 2>/dev/null || true

n_norm=0

while IFS=$'\t' read -r est_id ciudad_wrf cont_sinaica nombre_red nombre_est \
      || [[ -n "${est_id:-}" ]]; do

    [[ "${est_id:-}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${est_id:-}"               ]] && continue
    [[ "${est_id}" == "999"           ]] && continue

    cont_safe="${cont_sinaica//./}"
    csv_src="${DIR_RAW}/sinaica_${est_id}_${cont_safe}_${FECHA_EVAL}.csv"
    [[ -f "${csv_src}" ]]                               || continue
    (( $(contar_registros "${csv_src}") > 0 )) 2>/dev/null || continue

    # Nombre de estación seguro para el nombre de archivo del pipeline
    est_safe="${nombre_est// /_}"
    # Transliterar caracteres especiales del español
    est_safe=$(echo "${est_safe}" \
      | sed 'y/áéíóúÁÉÍÓÚñÑ/aeiouAEIOUnN/')

    # Archivo destino del pipeline: calidad_aire_<Ciudad>_<Estacion>.csv
    destino_pipeline="${DIR_PW}/calidad_aire_${ciudad_wrf}_${est_safe}.csv"

    # --------------------------------------------------------------------------
    # Construir columna de identificación compatible con el filtro awk del
    # pipeline.  El pipeline filtra con:
    #   id ~ /O3/     id ~ /PM10/ && id !~ /PM2\.5/     id ~ /PM2\.5/
    #
    # Formato de la columna id que generamos:
    #   <estacion_id><CONT_SINAICA><YYYYMMDD><HH>
    # Ejemplo: 249O32026022400  →  filtra O3
    #          250PM102026022400 →  filtra PM10
    #          251PM2.52026022400 → filtra PM2.5
    # --------------------------------------------------------------------------

    # Encabezado del pipeline: station_param_id,date,hour,value,[resto...]
    HDR="station_param_id,date,hour,value,flag,valid,station_id,parametro"

    if [[ ! -f "${destino_pipeline}" ]]; then
        echo "${HDR}" > "${destino_pipeline}"
    fi

    # El CSV de sinaica_descarga.sh tiene:
    # id,fecha,hora,valor,bandO,val,estacion_id,parametro
    # Cols: 1=id  2=fecha  3=hora  4=valor  5=bandO  6=val  7=estacion_id  8=parametro
    awk -F',' -v eid="${est_id}" -v cont="${cont_sinaica}" \
        'NR==1 { next }           # saltar encabezado original
         NF < 4 { next }          # saltar filas vacías / corruptas
         {
             # Construir id compatible con el filtro awk del pipeline
             gsub(/-/,"",$2)       # YYYY-MM-DD → YYYYMMDD
             printf "%s%s%s%02d,%s,%s,%s,%s,%s,%s,%s\n",
                 eid, cont, $2, $3+0,
                 $2, $3, $4, $5, $6, eid, cont
         }' "${csv_src}" >> "${destino_pipeline}"

    (( n_norm++ )) || true

done < "${CONF_EST}"

info "  Archivos normalizados para el pipeline: ${n_norm}"

# =============================================================================
# ── SECCIÓN 7: PROCESAR OBSERVACIONES (calidad_aire_pipeline.sh) ─────────────
# =============================================================================

step "Etapa 4 — Procesamiento con calidad_aire_pipeline.sh"

shopt -s nullglob
archivos_pw=( "${DIR_PW}"/calidad_aire_*.csv )
shopt -u nullglob

if (( ${#archivos_pw[@]} == 0 )); then
    warn "  Sin archivos calidad_aire_*.csv. Se usarán observaciones previas de ${DIR_OBS}."
else
    info "  Archivos a procesar: ${#archivos_pw[@]}"

    # calidad_aire_pipeline.sh crea salida/ y consolidado/ relativos al CWD
    pushd "${DIR_PW}" > /dev/null

    if bash "${PIPELINE_SH}"; then
        ok "  Pipeline de observaciones completado."

        # Copiar consolidados al directorio canónico de observaciones
        n_cop=0
        shopt -s nullglob
        for f in "${DIR_PW}/consolidado/"*_consolidado.csv; do
            cp "${f}" "${DIR_OBS}/"
            (( n_cop++ )) || true
        done
        shopt -u nullglob
        ok "  Consolidados copiados a ${DIR_OBS}/: ${n_cop} archivos"
    else
        warn "  Error en calidad_aire_pipeline.sh. Continuando con datos previos."
    fi

    popd > /dev/null
fi

# =============================================================================
# ── SECCIÓN 8: EXTRACCIÓN DEL MODELO WRFOUT (extract_dia.py) ─────────────────
# =============================================================================

step "Etapa 5 — Extracción de variables WRF-Chem"

# Generar el script Python de extracción en tmp/
# (se regenera en cada ejecución; no hay estado entre corridas)
cat > "${DIR_TMP}/extract_dia.py" << 'PYEOF'
#!/usr/bin/env python3
"""
extract_dia.py  —  Extractor de variables de superficie de WRF-Chem.

Argumentos posicionales:
    1  ruta_wrfout          path completo al archivo NetCDF
    2  fecha_run            YYYY-MM-DD del inicio del run
    3  horizonte            1, 2 o 3
    4  dir_salida           directorio donde guardar los CSV de extracción

Salida por ciudad y contaminante:
    <dir_salida>/ext_<cont>_<ciudad>_h<horizonte>.csv
    Columnas: Fecha, Ciudad, horizonte, valor

Convenciones:
    O3   → máximo espacial del máximo temporal en la ventana (ppbv, ppmv × 1000)
    PM10 → promedio de los máximos espaciales por hora en la ventana (µg/m³)
    PM25 → ídem PM10 para PM2.5 (µg/m³)

Ventanas horarias (índices del eje Time del wrfout, hora local = UTC − 6):
    horizonte 1 → slice(6, 30)   Día 0: 00:00–23:00 local (24 h)
    horizonte 2 → slice(30, 54)  Día 1: 00:00–23:00 local (24 h)
    horizonte 3 → slice(54, 72)  Día 2: 00:00–17:00 local (18 h)
"""
import sys
import os
import xarray as xr
import numpy as np
import pandas as pd

# ── Argumentos ────────────────────────────────────────────────────────────────
if len(sys.argv) != 5:
    sys.exit("Uso: extract_dia.py <wrfout> <fecha_run> <horizonte 1|2|3> <dir_salida>")

RUTA_WRF   = sys.argv[1]
FECHA_RUN  = sys.argv[2]
HORIZONTE  = int(sys.argv[3])
DIR_SAL    = sys.argv[4]

# ── Bounding boxes por ciudad ─────────────────────────────────────────────────
CIUDADES = [
    {"nombre": "CDMX",       "lat1": 19.20, "lat2": 19.70, "lon1": -99.30, "lon2": -98.85},
    {"nombre": "Toluca",     "lat1": 19.23, "lat2": 19.39, "lon1": -99.72, "lon2": -99.50},
    {"nombre": "Puebla",     "lat1": 18.95, "lat2": 19.12, "lon1": -98.32, "lon2": -98.10},
    {"nombre": "Tlaxcala",   "lat1": 19.29, "lat2": 19.36, "lon1": -98.26, "lon2": -98.15},
    {"nombre": "Pachuca",    "lat1": 20.03, "lat2": 20.13, "lon1": -98.80, "lon2": -98.67},
    {"nombre": "Cuernavaca", "lat1": 18.89, "lat2": 18.98, "lon1": -99.26, "lon2": -99.14},
    {"nombre": "SJdelRio",   "lat1": 20.36, "lat2": 20.41, "lon1": -100.01,"lon2": -99.93},
]

RANGOS = {1: slice(6, 30), 2: slice(30, 54), 3: slice(54, 72)}

# Nombres posibles de variables PM según la versión / configuración de WRF-Chem
VARS_PM = {
    "PM10": ["PM10", "pm10"],
    "PM25": ["PM2_5_DRY", "PM2_5", "pm2_5_dry", "pm2_5"],
}


def var_disponible(ds: xr.Dataset, nombres: list) -> str | None:
    return next((n for n in nombres if n in ds.variables), None)


def extraer_o3(ds, mask, rango) -> float:
    o3 = ds["o3"].isel(bottom_top=0).where(mask) * 1000.0  # ppmv → ppbv
    return float(o3.isel(Time=rango).max(skipna=True).values)


def extraer_pm(ds, var_nombre: str, mask, rango) -> float:
    var = ds[var_nombre]
    if "bottom_top" in var.dims:
        var = var.isel(bottom_top=0)
    max_esp = var.where(mask).max(dim=["south_north", "west_east"], skipna=True)
    return float(max_esp.isel(Time=rango).mean(skipna=True).values)


# ── Apertura del dataset ───────────────────────────────────────────────────────
if not os.path.exists(RUTA_WRF):
    sys.exit(f"[EXTRACT] ERROR: {RUTA_WRF} no encontrado.")

print(f"[EXTRACT] {os.path.basename(RUTA_WRF)}  horizonte={HORIZONTE}")

try:
    ds = xr.open_dataset(RUTA_WRF, decode_times=False)
except Exception as exc:
    sys.exit(f"[EXTRACT] ERROR abriendo NetCDF: {exc}")

rango = RANGOS[HORIZONTE]
lat   = ds["XLAT"][0, :, :]
lon   = ds["XLONG"][0, :, :]
os.makedirs(DIR_SAL, exist_ok=True)

# ── Procesar cada ciudad ───────────────────────────────────────────────────────
for c in CIUDADES:
    mask = (
        (lat >= c["lat1"]) & (lat <= c["lat2"]) &
        (lon >= c["lon1"]) & (lon <= c["lon2"])
    )
    res = {}

    # O3
    try:
        res["o3"] = extraer_o3(ds, mask, rango)
    except Exception as exc:
        res["o3"] = float("nan")
        print(f"  [EXTRACT] O3 {c['nombre']}: {exc}")

    # PM10 y PM25
    for cont, nombres in VARS_PM.items():
        vn = var_disponible(ds, nombres)
        if vn is None:
            res[cont] = float("nan")
            print(f"  [EXTRACT] {cont} no encontrado en {os.path.basename(RUTA_WRF)}")
            continue
        try:
            res[cont] = extraer_pm(ds, vn, mask, rango)
        except Exception as exc:
            res[cont] = float("nan")
            print(f"  [EXTRACT] {cont} {c['nombre']}: {exc}")

    # Guardar un CSV por contaminante
    for cont_key in ["o3", "PM10", "PM25"]:
        out = os.path.join(DIR_SAL, f"ext_{cont_key}_{c['nombre']}_h{HORIZONTE}.csv")
        pd.DataFrame([{
            "Fecha": FECHA_RUN, "Ciudad": c["nombre"],
            "horizonte": HORIZONTE, "valor": res.get(cont_key, float("nan")),
        }]).to_csv(out, index=False)

    print(
        f"  {c['nombre']:<12}  "
        f"O3={res.get('o3', float('nan')):.1f} ppbv  "
        f"PM10={res.get('PM10', float('nan')):.1f}  "
        f"PM25={res.get('PM25', float('nan')):.1f} µg/m³"
    )

ds.close()
print(f"[EXTRACT] Horizonte {HORIZONTE} completado.")
PYEOF

# Ejecutar la extracción para cada run disponible
for run_fecha in "${RUN_D1}" "${RUN_D2}" "${RUN_D3}"; do
    [[ "${WRFOUT_OK[${run_fecha}]}" -eq 1 ]] || {
        warn "  Saltando run ${run_fecha} (wrfout no disponible)"
        continue
    }

    # Horizonte según posición temporal respecto a FECHA_EVAL
    if   [[ "${run_fecha}" == "${RUN_D1}" ]]; then horizonte=1
    elif [[ "${run_fecha}" == "${RUN_D2}" ]]; then horizonte=2
    else horizonte=3
    fi

    info "  run=${run_fecha}  →  horizonte ${horizonte}..."

    if "${PYTHON}" "${DIR_TMP}/extract_dia.py" \
            "${WRFOUT_PATH[${run_fecha}]}" \
            "${run_fecha}" \
            "${horizonte}" \
            "${DIR_TMP}/extraidos" >> "${LOG_FILE}" 2>&1; then
        ok "  ✓ Extracción horizonte ${horizonte} OK."
    else
        warn "  ✗ Error en extracción horizonte ${horizonte} — ver ${LOG_FILE}"
    fi
done

# =============================================================================
# ── SECCIÓN 9: COMBINAR OBSERVACIONES + MODELO (combinar_dia.py) ─────────────
# =============================================================================

step "Etapa 6 — Combinación observaciones + modelo"

cat > "${DIR_TMP}/combinar_dia.py" << PYEOF
#!/usr/bin/env python3
"""
combinar_dia.py  —  Une el máximo observado del día con los tres horizontes del modelo.

Problemas corregidos respecto a la versión anterior:
  1. Fecha del consolidado en formato YYYYMMDD (sin guiones):
       date,hour,Cuernavaca_01
       20260301,0,0.000413...
     Se normaliza a YYYY-MM-DD con pd.to_datetime(..., format="mixed") antes
     de comparar.
  2. Unidades O3: el consolidado contiene valores en ppmv (0.000413...).
     El modelo ya entrega ppbv (71.09...).
     Se aplica FACTOR_CONV["o3"] = 1000 al máximo observado.
  3. Fecha a filtrar en el observado: siempre es FECHA_EVAL (el día que se
     evalúa), independientemente del horizonte. La columna "Fecha" de cada
     ext_*.csv contiene la fecha del run, no la fecha evaluada; se usa
     FECHA_EVAL para filtrar el consolidado en los tres horizontes.

Lee:
  - ${DIR_OBS}/<Ciudad_OBS>_<Cont_OBS>_consolidado.csv
  - ${DIR_TMP}/extraidos/ext_<cont>_<ciudad>_h<n>.csv

Escribe:
  - ${DIR_AJUSTADOS}/eval_<cont>_<ciudad>_${FECHA_EVAL}.csv
    Columnas: Fecha, Ciudad, max_obs, mod_dia1, mod_dia2, mod_dia3
"""
import os
import glob
import pandas as pd
import numpy as np

FECHA_EVAL    = "${FECHA_EVAL}"
DIR_OBS       = "${DIR_OBS}"
DIR_EXTRAIDOS = "${DIR_TMP}/extraidos"
DIR_SALIDA    = "${DIR_AJUSTADOS}"
os.makedirs(DIR_SALIDA, exist_ok=True)

CIUDADES = ["CDMX","Toluca","Puebla","Tlaxcala","Pachuca","Cuernavaca","SJdelRio"]

CIUDAD_OBS = {
    "CDMX":       "${CIUDAD_OBS_MAP[CDMX]}",
    "Toluca":     "${CIUDAD_OBS_MAP[Toluca]}",
    "Puebla":     "${CIUDAD_OBS_MAP[Puebla]}",
    "Tlaxcala":   "${CIUDAD_OBS_MAP[Tlaxcala]}",
    "Pachuca":    "${CIUDAD_OBS_MAP[Pachuca]}",
    "Cuernavaca": "${CIUDAD_OBS_MAP[Cuernavaca]}",
    "SJdelRio":   "${CIUDAD_OBS_MAP[SJdelRio]}",
}
CONT_OBS_LABEL = {"o3": "O3", "PM10": "PM10", "PM25": "PM2.5"}

# O3 observado viene en ppmv → multiplicar × 1000 para obtener ppbv.
# PM10 y PM2.5 ya están en µg/m³ en ambas fuentes.
FACTOR_CONV = {"o3": 1000.0, "PM10": 1.0, "PM25": 1.0}


def detectar_formato_fecha(serie: pd.Series) -> str:
    """
    Detecta el formato de fecha inspeccionando los primeros valores no nulos.

    Lógica:
      - Si el valor contiene '-'            →  formato ISO con guiones (%Y-%m-%d)
      - Si el valor es 8 dígitos numéricos  →  formato compacto (%Y%m%d)
        Este caso cubre el bug conocido del consolidado CDMX, que contiene
        fechas desde 1997 (ej. '19970101') junto a fechas recientes ('20260305')
        porque la página de SINAICA devuelve histórico completo en algunos casos.
      - De lo contrario                     →  'mixed' (pandas infiere por fila)
    """
    muestra = serie.dropna().head(10).astype(str)
    for val in muestra:
        val = val.strip()
        if not val or val.lower() in ("nan", "nat", "none"):
            continue
        if "-" in val:
            return "%Y-%m-%d"
        if val.isdigit() and len(val) == 8:
            return "%Y%m%d"
    return "mixed"


def leer_consolidado(path: str) -> pd.DataFrame | None:
    """
    Lee un CSV consolidado de observaciones y normaliza la columna de fecha
    a dtype datetime64, manejando los siguientes formatos conocidos:

      - YYYYMMDD   (ej. 20260301): formato que genera calidad_aire_pipeline.sh
                   También presente en archivos históricos con fechas desde 1997
                   (bug conocido del sitio SINAICA para algunas estaciones/redes).
      - YYYY-MM-DD (ej. 2026-03-01): formato ISO estándar.

    El formato se detecta automáticamente a partir de una muestra de los
    primeros valores no nulos, evitando el parseo costoso fila a fila que
    usa format='mixed' sobre archivos con decenas de miles de filas.

    Retorna None si el archivo no existe o no puede leerse.
    """
    if not os.path.exists(path):
        return None
    try:
        # Leer todo como texto para evitar que pandas malinterprete fechas
        # numéricas como enteros (ej. 20260301 → int en lugar de string)
        df = pd.read_csv(path, dtype=str)
    except Exception as exc:
        print(f"  [COMB] Error leyendo {path}: {exc}")
        return None

    # Detectar columna de fecha: puede llamarse 'date' o 'fecha'
    col_f = None
    for candidate in ("date", "fecha"):
        if candidate in df.columns:
            col_f = candidate
            break
    if col_f is None:
        print(f"  [COMB] Columna de fecha no encontrada en {path}")
        return None

    # Detectar formato y parsear con el formato explícito correspondiente.
    # El uso de format= explícito es ~10× más rápido que format='mixed' o
    # infer_datetime_format sobre archivos grandes (26k+ filas como CDMX).
    fmt = detectar_formato_fecha(df[col_f])
    try:
        if fmt == "mixed":
            # Último recurso: pandas infiere el formato por cada fila
            try:
                df[col_f] = pd.to_datetime(df[col_f], format="mixed", dayfirst=False)
            except TypeError:
                # pandas < 2.0 no acepta format="mixed"
                df[col_f] = pd.to_datetime(df[col_f], infer_datetime_format=True)
        else:
            df[col_f] = pd.to_datetime(df[col_f], format=fmt)
    except Exception as exc:
        print(f"  [COMB] Error parseando fechas en {path} (formato={fmt}): {exc}")
        return None

    df.rename(columns={col_f: "date"}, inplace=True)
    return df


def max_diario_obs(df: pd.DataFrame, fecha_str: str, factor: float) -> float:
    """
    Dado el DataFrame del consolidado (columna 'date' ya normalizada),
    filtra las filas del día indicado y retorna el máximo entre todas las
    estaciones (columnas de valor) multiplicado por factor.
    """
    fecha = pd.Timestamp(fecha_str)
    dia = df[df["date"].dt.normalize() == fecha]
    if dia.empty:
        return float("nan")
    # Columnas de valores: todo excepto 'date' y 'hour'/'hora'
    cols_v = [c for c in dia.columns if c not in ("date", "hour", "hora")]
    vals = dia[cols_v].apply(pd.to_numeric, errors="coerce")
    raw_max = float(vals.max().max())
    return raw_max * factor if not np.isnan(raw_max) else float("nan")


# ── Procesar cada combinación ciudad × contaminante ───────────────────────────
for cont in ["o3", "PM10", "PM25"]:
    for ciudad in CIUDADES:

        # ── 1. Cargar y filtrar observaciones ────────────────────────────────
        nombre_obs = CIUDAD_OBS[ciudad]
        cont_obs   = CONT_OBS_LABEL[cont]
        patron     = os.path.join(DIR_OBS, f"{nombre_obs}_{cont_obs}_consolidado.csv")
        archivos   = glob.glob(patron)

        max_obs = float("nan")
        if archivos:
            df_obs = leer_consolidado(archivos[0])
            if df_obs is not None:
                max_obs = max_diario_obs(df_obs, FECHA_EVAL, FACTOR_CONV[cont])
                if np.isnan(max_obs):
                    print(f"  [COMB] Sin datos para {ciudad}/{cont} en {FECHA_EVAL} "
                          f"(archivo: {os.path.basename(archivos[0])})")
            else:
                print(f"  [COMB] No se pudo leer: {archivos[0]}")
        else:
            print(f"  [COMB] Sin archivo obs: {patron}")

        # ── 2. Leer valores del modelo por horizonte ─────────────────────────
        # Cada ext_*.csv tiene una sola fila con la fecha del run y el valor
        # extraído para ese horizonte; se toma directamente el campo 'valor'.
        mod = {}
        for h in [1, 2, 3]:
            csv_h = os.path.join(DIR_EXTRAIDOS, f"ext_{cont}_{ciudad}_h{h}.csv")
            if os.path.exists(csv_h):
                try:
                    df_h = pd.read_csv(csv_h)
                    val  = df_h["valor"].iloc[0] if not df_h.empty else float("nan")
                    mod[f"mod_dia{h}"] = float(val)
                except Exception as exc:
                    print(f"  [COMB] Error leyendo modelo h{h} {ciudad}/{cont}: {exc}")
                    mod[f"mod_dia{h}"] = float("nan")
            else:
                mod[f"mod_dia{h}"] = float("nan")

        # ── 3. Guardar fila combinada ─────────────────────────────────────────
        fila = {
            "Fecha":    FECHA_EVAL,
            "Ciudad":   ciudad,
            "max_obs":  round(max_obs, 4) if not np.isnan(max_obs) else float("nan"),
            "mod_dia1": round(mod["mod_dia1"], 4) if not np.isnan(mod["mod_dia1"]) else float("nan"),
            "mod_dia2": round(mod["mod_dia2"], 4) if not np.isnan(mod["mod_dia2"]) else float("nan"),
            "mod_dia3": round(mod["mod_dia3"], 4) if not np.isnan(mod["mod_dia3"]) else float("nan"),
        }
        csv_out = os.path.join(DIR_SALIDA, f"eval_{cont}_{ciudad}_{FECHA_EVAL}.csv")
        pd.DataFrame([fila]).to_csv(csv_out, index=False)

        # Resumen en log
        obs_s = f"{max_obs:.2f}" if not np.isnan(max_obs) else "NA"
        d1_s  = f"{mod['mod_dia1']:.2f}" if not np.isnan(mod["mod_dia1"]) else "NA"
        d2_s  = f"{mod['mod_dia2']:.2f}" if not np.isnan(mod["mod_dia2"]) else "NA"
        d3_s  = f"{mod['mod_dia3']:.2f}" if not np.isnan(mod["mod_dia3"]) else "NA"
        print(f"  {ciudad:<12} {cont:<5}  obs={obs_s:>8}  "
              f"d1={d1_s:>8}  d2={d2_s:>8}  d3={d3_s:>8}")

print("[COMB] Completado.")
PYEOF

if "${PYTHON}" "${DIR_TMP}/combinar_dia.py" >> "${LOG_FILE}" 2>&1; then
    ok "  Combinación obs+modelo completada."
else
    warn "  Error en combinación — ver ${LOG_FILE}"
fi

# =============================================================================
# ── SECCIÓN 10: CALCULAR MÉTRICAS ESTADÍSTICAS (stats_dia.py) ────────────────
# =============================================================================

step "Etapa 7 — Cálculo de métricas estadísticas (ventana ${VENTANA_DIAS} días)"

cat > "${DIR_TMP}/stats_dia.py" << PYEOF
#!/usr/bin/env python3
"""
stats_dia.py  —  Métricas de validación para la fecha de evaluación.

Carga todos los CSV en combinado/ajustados/, aplica una ventana deslizante de
${VENTANA_DIAS} días y calcula métricas continuas y dicotómicas por horizonte.
Exporta el resultado como JSON para ser consumido por generar_html.py.
"""
import os, glob, json
import pandas as pd
import numpy as np

FECHA_EVAL    = "${FECHA_EVAL}"
DIR_AJUSTADOS = "${DIR_AJUSTADOS}"
DIR_TMP       = "${DIR_TMP}"
VENTANA_DIAS  = ${VENTANA_DIAS}
UMBRAL        = {"o3": ${UMBRAL[o3]}, "PM10": ${UMBRAL[PM10]}, "PM25": ${UMBRAL[PM25]}}

CIUDADES = ["CDMX","Toluca","Puebla","Tlaxcala","Pachuca","Cuernavaca","SJdelRio"]


def metricas_continuas(obs: np.ndarray, mod: np.ndarray) -> dict:
    mask = ~(np.isnan(obs) | np.isnan(mod))
    o, m = obs[mask], mod[mask]
    if len(o) < 2:
        return {}
    r_mat = np.corrcoef(o, m)
    return {
        "n":        int(len(o)),
        "bias":     round(float(np.mean(m - o)),            3),
        "rmse":     round(float(np.sqrt(np.mean((m-o)**2))),3),
        "mae":      round(float(np.mean(np.abs(m - o))),    3),
        "r":        round(float(r_mat[0, 1]),                3),
        "obs_mean": round(float(np.mean(o)),                 3),
        "mod_mean": round(float(np.mean(m)),                 3),
    }


def metricas_dicotomicas(obs: np.ndarray, mod: np.ndarray, umbral: float) -> dict:
    mask = ~(np.isnan(obs) | np.isnan(mod))
    ob = (obs[mask] > umbral).astype(int)
    mb = (mod[mask] > umbral).astype(int)
    N  = len(ob)
    if N == 0:
        return {}
    H = int(np.sum((ob==1)&(mb==1)))
    M = int(np.sum((ob==1)&(mb==0)))
    F = int(np.sum((ob==0)&(mb==1)))
    C = int(np.sum((ob==0)&(mb==0)))
    _d = lambda a, b: round(a/b, 3) if b > 0 else None
    return {
        "umbral": umbral, "H": H, "M": M, "F": F, "C": C,
        "PC":  _d(H+C, N),
        "POD": _d(H, H+M),
        "FAR": _d(F, H+F),
        "CSI": _d(H, H+M+F),
        "TSS": round((_d(H,H+M) or 0) - (_d(F,F+C) or 0), 3),
    }


resultado = {}

for cont in ["o3","PM10","PM25"]:
    resultado[cont] = {}
    for ciudad in CIUDADES:
        archivos = sorted(glob.glob(
            os.path.join(DIR_AJUSTADOS, f"eval_{cont}_{ciudad}_*.csv")))

        if not archivos:
            resultado[cont][ciudad] = {"error": "sin_datos"}
            continue

        df = pd.concat([pd.read_csv(f) for f in archivos], ignore_index=True)
        df["Fecha"] = pd.to_datetime(df["Fecha"])
        df = df.sort_values("Fecha").drop_duplicates("Fecha")

        # Valor del día de evaluación
        fila_hoy = df[df["Fecha"].dt.strftime("%Y-%m-%d") == FECHA_EVAL]
        val_hoy  = {}
        if not fila_hoy.empty:
            for col in ["max_obs","mod_dia1","mod_dia2","mod_dia3"]:
                v = fila_hoy[col].values[0] if col in fila_hoy.columns else None
                val_hoy[col] = None if (v is None or
                    (isinstance(v, float) and np.isnan(v))) else round(float(v), 2)

        # Ventana histórica de VENTANA_DIAS días
        f_ini = pd.to_datetime(FECHA_EVAL) - pd.Timedelta(days=VENTANA_DIAS)
        df_v  = df[df["Fecha"] >= f_ini].dropna(subset=["max_obs","mod_dia1"])

        stats = {}
        for h in ["mod_dia1","mod_dia2","mod_dia3"]:
            if h not in df_v.columns:
                stats[h] = {}
                continue
            obs_a = df_v["max_obs"].values
            mod_a = df_v[h].values
            stats[h] = {
                "continuas":   metricas_continuas(obs_a, mod_a),
                "dicotomicas": metricas_dicotomicas(obs_a, mod_a, UMBRAL[cont]),
            }

        resultado[cont][ciudad] = {
            "fecha_eval":  FECHA_EVAL,
            "n_historico": int(len(df_v)),
            "valor_hoy":   val_hoy,
            "stats_30d":   stats,
        }

        v = val_hoy
        print(f"  {cont:<5} {ciudad:<12}  "
              f"obs={str(v.get('max_obs','NA')):>7}  "
              f"d1={str(v.get('mod_dia1','NA')):>7}  "
              f"d2={str(v.get('mod_dia2','NA')):>7}  "
              f"d3={str(v.get('mod_dia3','NA')):>7}")

json_out = os.path.join(DIR_TMP, f"stats_{FECHA_EVAL}.json")
with open(json_out, "w", encoding="utf-8") as fh:
    json.dump(resultado, fh, ensure_ascii=False, indent=2, default=str)
print(f"[STATS] JSON: {json_out}")
PYEOF

if "${PYTHON}" "${DIR_TMP}/stats_dia.py" >> "${LOG_FILE}" 2>&1; then
    ok "  Métricas calculadas: ${DIR_TMP}/stats_${FECHA_EVAL}.json"
else
    warn "  Error calculando métricas — ver ${LOG_FILE}"
fi

# =============================================================================
# ── SECCIÓN 11: GENERAR PÁGINA HTML (generar_html.py) ────────────────────────
# =============================================================================

step "Etapa 8 — Generación de página HTML"

# ── CSS base (se genera una sola vez) ────────────────────────────────────────
CSS_FILE="${DIR_WEB}/css/estilo.css"
if [[ ! -f "${CSS_FILE}" ]]; then
cat > "${CSS_FILE}" << 'CSSEOF'
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{--az:#1a4f8a;--azc:#2e78c7;--gr:#f4f6f9;--brd:#dde1e7;--bl:#fff;
  --tx:#2c3e50;--vd:#27ae60;--rj:#e74c3c;--am:#f39c12;--sh:0 2px 8px rgba(0,0,0,.12)}
body{font-family:'Segoe UI',Arial,sans-serif;background:var(--gr);color:var(--tx);line-height:1.5}
a{color:var(--azc);text-decoration:none}a:hover{text-decoration:underline}
header{background:linear-gradient(135deg,var(--az),var(--azc));color:#fff;
  padding:1.4rem 2rem;display:flex;align-items:center;gap:1.2rem;box-shadow:var(--sh)}
header .logo{font-size:2.4rem}header h1{font-size:1.5rem;font-weight:700}
header p{font-size:.9rem;opacity:.85}
.tabs{display:flex;gap:.4rem;padding:.8rem 2rem 0;background:var(--bl);
  border-bottom:2px solid var(--brd);flex-wrap:wrap}
.tab-btn{padding:.5rem 1.1rem;border:none;border-radius:6px 6px 0 0;
  background:var(--gr);cursor:pointer;font-size:.88rem;font-weight:600;
  color:var(--tx);transition:all .2s}
.tab-btn:hover{background:#d0dff5}.tab-btn.active{background:var(--az);color:#fff}
.tab-pane{display:none;padding:1.5rem 2rem}.tab-pane.active{display:block}
.cgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:1.2rem;margin-top:1rem}
.card{background:var(--bl);border-radius:10px;box-shadow:var(--sh);overflow:hidden}
.card .ch{background:var(--az);color:#fff;padding:.7rem 1rem;font-weight:700;
  font-size:1rem;display:flex;align-items:center;gap:.5rem}
.card .cb{padding:1rem}
.td{width:100%;border-collapse:collapse;font-size:.87rem}
.td th{background:var(--gr);padding:.45rem .7rem;text-align:left;
  font-weight:600;border-bottom:2px solid var(--brd)}
.td td{padding:.4rem .7rem;border-bottom:1px solid var(--brd)}
.tm{width:100%;border-collapse:collapse;font-size:.82rem;margin-top:.7rem}
.tm th,.tm td{padding:.38rem .6rem;text-align:center;border:1px solid var(--brd)}
.tm th{background:#e8edf4;font-size:.78rem}
.chip{display:inline-block;padding:.18rem .6rem;border-radius:12px;font-size:.78rem;font-weight:700;margin-right:.3rem}
.d1{background:#fde8e8;color:#c0392b}.d2{background:#e8f5e9;color:#1a7a3a}.d3{background:#e3f2fd;color:#1557a0}
.sem{width:12px;height:12px;border-radius:50%;display:inline-block;margin-right:.35rem;vertical-align:middle}
.vd{background:var(--vd)}.am{background:var(--am)}.rj{background:var(--rj)}.gr{background:#999}
.st-btn{background:none;border:1px solid var(--brd);border-radius:6px;
  padding:.3rem .8rem;font-size:.8rem;cursor:pointer;color:var(--azc);margin-top:.7rem}
.st-det{display:none;margin-top:.6rem}.st-det.open{display:block}
.kgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:.9rem;margin:1rem 0}
.kpi{background:var(--bl);border-radius:10px;padding:1rem;text-align:center;box-shadow:var(--sh)}
.kv{font-size:1.9rem;font-weight:800;color:var(--az)}.kl{font-size:.78rem;color:#666;margin-top:.2rem}
footer{text-align:center;padding:1.5rem;color:#888;font-size:.8rem;
  border-top:1px solid var(--brd);margin-top:2rem}
@media(max-width:600px){.cgrid{grid-template-columns:1fr}
  .kgrid{grid-template-columns:repeat(2,1fr)}.tabs{padding:.5rem 1rem 0}}
CSSEOF
    ok "  CSS generado: ${CSS_FILE}"
fi

# ── Script Python de generación HTML ─────────────────────────────────────────
cat > "${DIR_TMP}/generar_html.py" << PYEOF
#!/usr/bin/env python3
"""generar_html.py — Genera la página HTML del día desde el JSON de métricas."""
import json, os, math
from datetime import datetime

FECHA_EVAL = "${FECHA_EVAL}"
DIR_TMP    = "${DIR_TMP}"
DIR_WEB    = "${DIR_WEB}"
ANIO       = "${ANIO_EVAL}"
MES        = "${MES_EVAL}"
VENTANA    = ${VENTANA_DIAS}

json_path = os.path.join(DIR_TMP, f"stats_{FECHA_EVAL}.json")
html_out  = os.path.join(DIR_WEB, ANIO, MES, f"evaluacion_{FECHA_EVAL}.html")

CIUDADES   = ["CDMX","Toluca","Puebla","Tlaxcala","Pachuca","Cuernavaca","SJdelRio"]
ICONOS     = {"CDMX":"🏙️","Toluca":"🏔️","Puebla":"⛩️","Tlaxcala":"🌾",
              "Pachuca":"⛏️","Cuernavaca":"🌺","SJdelRio":"🌊"}
CLB        = {"o3":"O₃ (ppbv)","PM10":"PM10 (µg/m³)","PM25":"PM2.5 (µg/m³)"}
HLB        = {"mod_dia1":"+24 h","mod_dia2":"+48 h","mod_dia3":"+72 h"}
HCP        = {"mod_dia1":"d1","mod_dia2":"d2","mod_dia3":"d3"}
UMBRAL     = {"o3":${UMBRAL[o3]},"PM10":${UMBRAL[PM10]},"PM25":${UMBRAL[PM25]}}

f_  = lambda v,d=1: "<span style='color:#aaa'>—</span>" if (
    v is None or (isinstance(v,float) and math.isnan(v))) else f"{v:.{d}f}"
sb_ = lambda b: "gr" if b is None else ("vd" if abs(b)<10 else ("am" if abs(b)<25 else "rj"))
sr_ = lambda r: "gr" if r is None else ("vd" if r>=0.7 else ("am" if r>=0.4 else "rj"))

datos = {}
if os.path.exists(json_path):
    with open(json_path, encoding="utf-8") as fh:
        datos = json.load(fh)

fd  = datetime.strptime(FECHA_EVAL,"%Y-%m-%d")
flt = fd.strftime("%d de %B de %Y").capitalize()
ts  = datetime.now().strftime("%Y-%m-%d %H:%M")

tabs = ""; panes = ""

for i, cont in enumerate(["o3","PM10","PM25"]):
    act = "active" if i==0 else ""
    tabs += (f'<button class="tab-btn {act}" onclick="mTab(\'{cont}\')" '
             f'id="tab-{cont}">{CLB[cont]}</button>\n')
    panes += f'<div class="tab-pane {act}" id="pane-{cont}">\n<div class="cgrid">\n'
    for ciudad in CIUDADES:
        ic  = datos.get(cont,{}).get(ciudad,{})
        vh  = ic.get("valor_hoy",{})
        st  = ic.get("stats_30d",{})
        nh  = ic.get("n_historico",0)
        un  = CLB[cont].split("(")[1].rstrip(")")
        # tabla de valores del día
        rv = ""
        for hk,hl in HLB.items():
            vm = vh.get(hk); vo = vh.get("max_obs")
            df_ = (vm-vo) if (vm is not None and vo is not None) else None
            rv += (f"<tr><td><span class='chip {HCP[hk]}'>{hl}</span></td>"
                   f"<td>{f_(vo)}</td><td>{f_(vm)}</td><td>{f_(df_)}</td></tr>\n")
        # métricas continuas y dicotómicas
        rm = ""; rd = ""
        for hk,hl in HLB.items():
            sc = st.get(hk,{}).get("continuas",{})
            sd = st.get(hk,{}).get("dicotomicas",{})
            b=sc.get("bias"); r=sc.get("r"); rmse=sc.get("rmse")
            rm += (f"<tr><td><span class='chip {HCP[hk]}'>{hl}</span></td>"
                   f"<td><span class='sem {sb_(b)}'></span>{f_(b)}</td>"
                   f"<td>{f_(rmse)}</td>"
                   f"<td><span class='sem {sr_(r)}'></span>{f_(r,2)}</td></tr>\n")
            pod=sd.get("POD"); far=sd.get("FAR"); csi=sd.get("CSI")
            rd += (f"<tr><td><span class='chip {HCP[hk]}'>{hl}</span></td>"
                   f"<td>{f_(pod,3) if pod is not None else '—'}</td>"
                   f"<td>{f_(far,3) if far is not None else '—'}</td>"
                   f"<td>{f_(csi,3) if csi is not None else '—'}</td></tr>\n")
        panes += f"""  <div class="card">
    <div class="ch">{ICONOS.get(ciudad,'📍')} {ciudad}</div>
    <div class="cb">
      <table class="td">
        <thead><tr><th>Horizonte</th><th>Obs ({un})</th><th>Modelo</th><th>Dif.</th></tr></thead>
        <tbody>{rv}</tbody>
      </table>
      <button class="st-btn" onclick="tSt(this)">📊 Métricas {VENTANA} días (n={nh})</button>
      <div class="st-det">
        <p style="font-size:.8rem;color:#666;margin:.5rem 0 .3rem">Continuas:</p>
        <table class="tm">
          <thead><tr><th>Horizonte</th><th>BIAS</th><th>RMSE</th><th>R</th></tr></thead>
          <tbody>{rm}</tbody>
        </table>
        <p style="font-size:.8rem;color:#666;margin:.5rem 0 .3rem">
          Dicotómicas (umbral {UMBRAL[cont]}):
        </p>
        <table class="tm">
          <thead><tr><th>Horizonte</th><th>POD</th><th>FAR</th><th>CSI</th></tr></thead>
          <tbody>{rd}</tbody>
        </table>
      </div>
    </div>
  </div>
"""
    panes += "</div>\n</div>\n"

html = f"""<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>Evaluación WRF-Chem — {flt}</title>
  <link rel="stylesheet" href="../../css/estilo.css">
</head>
<body>
<header>
  <div class="logo">🌫️</div>
  <div>
    <h1>Evaluación del Pronóstico de Calidad del Aire</h1>
    <p>WRF-Chem vs SINAICA &nbsp;|&nbsp; <strong>{flt}</strong></p>
  </div>
</header>
<main style="max-width:1400px;margin:0 auto;padding:.5rem 1rem 2rem;">

  <!-- ═══════════════════════════════════════════════════════════
       DESCRIPCIÓN DE LA PÁGINA
       ═══════════════════════════════════════════════════════════ -->
  <section style="margin-top:1.4rem;background:#fff;border-radius:12px;
                  padding:1.2rem 1.6rem;box-shadow:0 2px 8px rgba(0,0,0,.08);
                  border-left:5px solid var(--az);">
    <h2 style="font-size:1rem;font-weight:700;color:var(--az);margin-bottom:.6rem;">
      ¿Qué muestra esta página?
    </h2>
    <p style="font-size:.88rem;line-height:1.7;color:#3a3a3a;margin-bottom:.7rem;">
      Esta página presenta la <strong>evaluación diaria del pronóstico de calidad del aire</strong>
      generado por el modelo meteorológico-químico <strong>WRF&#8209;Chem</strong> para
      <strong>siete zonas metropolitanas del centro de México</strong>
      (Ciudad de México, Toluca, Puebla, Tlaxcala, Pachuca, Cuernavaca y San Juan del Río).
      Los resultados del modelo se contrastan con las mediciones horarias reportadas por las
      estaciones de monitoreo de la red <strong>SINAICA&nbsp;/&nbsp;INECC</strong>
      correspondientes al día <strong>{flt}</strong>.
    </p>
    <p style="font-size:.88rem;line-height:1.7;color:#3a3a3a;margin-bottom:.7rem;">
      Se analizan tres contaminantes de interés sanitario y normativo:
    </p>
    <ul style="font-size:.88rem;line-height:1.8;color:#3a3a3a;
               padding-left:1.4rem;margin-bottom:.8rem;">
      <li>
        <strong>Ozono (O₃)</strong> — contaminante fotoquímico secundario formado por la
        reacción de precursores en presencia de luz solar. Concentraciones elevadas irritan
        las vías respiratorias y pueden agravar enfermedades cardiovasculares y pulmonares.
        El umbral de referencia utilizado es
        <strong>{UMBRAL['o3']}&nbsp;ppbv</strong> (NOM&#8209;020&#8209;SSA1).
      </li>
      <li>
        <strong>Partículas suspendidas gruesas (PM10)</strong> — partículas con diámetro
        aerodinámico ≤&nbsp;10&nbsp;µm, de origen tanto natural (polvo, suelo resuspendido)
        como antrópico (tráfico, industria). Penetran la nariz y la garganta y pueden
        alcanzar los bronquios. Umbral: <strong>{UMBRAL['PM10']}&nbsp;µg/m³</strong>
        en promedio de 24&nbsp;h (NOM&#8209;025&#8209;SSA1&#8209;2021).
      </li>
      <li>
        <strong>Partículas suspendidas finas (PM2.5)</strong> — fracción con diámetro
        ≤&nbsp;2.5&nbsp;µm, principalmente de combustión. Por su pequeño tamaño alcanzan
        los alvéolos pulmonares y pueden pasar al torrente sanguíneo, con efectos
        cardiovasculares documentados a largo plazo. Umbral:
        <strong>{UMBRAL['PM25']}&nbsp;µg/m³</strong> en 24&nbsp;h
        (NOM&#8209;025&#8209;SSA1&#8209;2021).
      </li>
    </ul>
    <p style="font-size:.88rem;line-height:1.7;color:#3a3a3a;margin-bottom:.7rem;">
      El modelo WRF&#8209;Chem produce pronósticos de hasta 72&nbsp;horas de anticipación.
      Para el día evaluado se comparan <strong>tres horizontes de pronóstico</strong>
      independientes, cada uno correspondiente a un ciclo de inicialización distinto:
    </p>
    <ul style="font-size:.88rem;line-height:1.8;color:#3a3a3a;
               padding-left:1.4rem;margin-bottom:.8rem;">
      <li><span style="display:inline-block;padding:.1rem .55rem;border-radius:10px;
          font-size:.78rem;font-weight:700;background:#fde8e8;color:#c0392b;
          margin-right:.4rem">+24&nbsp;h</span>
        Pronóstico emitido el mismo día de evaluación — mayor frescura inicial,
        horizonte de corto plazo.
      </li>
      <li><span style="display:inline-block;padding:.1rem .55rem;border-radius:10px;
          font-size:.78rem;font-weight:700;background:#e8f5e9;color:#1a7a3a;
          margin-right:.4rem">+48&nbsp;h</span>
        Pronóstico emitido un día antes — horizonte de mediano plazo operativo.
      </li>
      <li><span style="display:inline-block;padding:.1rem .55rem;border-radius:10px;
          font-size:.78rem;font-weight:700;background:#e3f2fd;color:#1557a0;
          margin-right:.4rem">+72&nbsp;h</span>
        Pronóstico emitido dos días antes — horizonte de largo plazo; permite
        evaluar la degradación de la habilidad predictiva con el tiempo.
      </li>
    </ul>
    <p style="font-size:.88rem;line-height:1.7;color:#3a3a3a;">
      Las <strong>métricas estadísticas</strong> (BIAS, RMSE, R, POD, FAR, CSI) se
      calculan sobre una ventana móvil de los últimos <strong>{VENTANA}&nbsp;días</strong>
      para proveer contexto de desempeño acumulado. El semáforo de colores
      (<span style="display:inline-block;width:10px;height:10px;border-radius:50%;
       background:#27ae60;vertical-align:middle;margin:0 3px"></span>verde
      /&nbsp;<span style="display:inline-block;width:10px;height:10px;border-radius:50%;
       background:#f39c12;vertical-align:middle;margin:0 3px"></span>ámbar
      /&nbsp;<span style="display:inline-block;width:10px;height:10px;border-radius:50%;
       background:#e74c3c;vertical-align:middle;margin:0 3px"></span>rojo)
      sintetiza visualmente la calidad del pronóstico para facilitar la interpretación
      operativa por parte del equipo técnico.
    </p>
  </section>

  <!-- ═══════════════════════════════════════════════════════════
       KPIs DE RESUMEN
       ═══════════════════════════════════════════════════════════ -->
  <section style="margin-top:1.2rem;">
    <h2 style="font-size:1.1rem;color:var(--az);margin-bottom:.7rem;">📋 Resumen</h2>
    <div class="kgrid">
      <div class="kpi"><div class="kv">3</div><div class="kl">Horizontes</div></div>
      <div class="kpi"><div class="kv">7</div><div class="kl">Ciudades</div></div>
      <div class="kpi"><div class="kv">3</div><div class="kl">Contaminantes</div></div>
      <div class="kpi"><div class="kv">{VENTANA}d</div><div class="kl">Ventana métricas</div></div>
    </div>
    <p style="font-size:.82rem;color:#666;margin-top:.5rem;">
      <span class="sem vd"></span>BIAS&lt;10 &nbsp;
      <span class="sem am"></span>BIAS 10–25 &nbsp;
      <span class="sem rj"></span>BIAS&gt;25 &nbsp;|&nbsp;
      <span class="sem vd"></span>R≥0.7 &nbsp;
      <span class="sem am"></span>R 0.4–0.7 &nbsp;
      <span class="sem rj"></span>R&lt;0.4
    </p>
  </section>
  <section style="margin-top:1.5rem;">
    <h2 style="font-size:1.1rem;color:var(--az);margin-bottom:.7rem;">🔬 Resultados</h2>
    <div class="tabs">{tabs}</div>
    {panes}
  </section>
  <section style="margin-top:2rem;padding-top:1rem;border-top:1px solid var(--brd);">
    <a href="../../index.html">← Índice histórico</a>
  </section>
</main>
<footer>Generado el {ts} &nbsp;|&nbsp; Pipeline WRF-Chem / Calidad del Aire — Centro de México</footer>
<script>
function mTab(c){{
  document.querySelectorAll('.tab-pane,.tab-btn').forEach(e=>e.classList.remove('active'));
  document.getElementById('pane-'+c).classList.add('active');
  document.getElementById('tab-'+c).classList.add('active');
}}
function tSt(b){{
  const d=b.nextElementSibling; d.classList.toggle('open');
  b.textContent=d.classList.contains('open')
    ?b.textContent.replace('📊','📉'):b.textContent.replace('📉','📊');
}}
</script>
</body>
</html>"""

os.makedirs(os.path.dirname(html_out), exist_ok=True)
with open(html_out,"w",encoding="utf-8") as fh:
    fh.write(html)
print(f"[HTML] Generado: {html_out}")
PYEOF

if "${PYTHON}" "${DIR_TMP}/generar_html.py" >> "${LOG_FILE}" 2>&1; then
    ok "  HTML: ${DIR_WEB}/${ANIO_EVAL}/${MES_EVAL}/evaluacion_${FECHA_EVAL}.html"
else
    warn "  Error generando HTML — ver ${LOG_FILE}"
fi

# =============================================================================
# ── SECCIÓN 12: ACTUALIZAR ÍNDICE HISTÓRICO ───────────────────────────────────
# =============================================================================

step "Etapa 9 — Actualización del índice histórico"

cat > "${DIR_TMP}/actualizar_indice.py" << PYEOF
#!/usr/bin/env python3
"""Actualiza web/index.html con todos los reportes disponibles."""
import os, glob
from datetime import datetime

DIR_WEB = "${DIR_WEB}"
reportes = sorted(
    glob.glob(os.path.join(DIR_WEB,"????","??","evaluacion_????-??-??.html")),
    reverse=True)

filas = ""
for r in reportes:
    n = os.path.basename(r).replace("evaluacion_","").replace(".html","")
    try:
        fl = datetime.strptime(n,"%Y-%m-%d").strftime("%d de %B de %Y").capitalize()
    except ValueError:
        fl = n
    filas += f'  <tr><td><a href="{os.path.relpath(r,DIR_WEB)}">{fl}</a></td><td>{n}</td></tr>\n'

ts = datetime.now().strftime("%Y-%m-%d %H:%M")
html = f"""<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>Evaluación WRF-Chem — Índice histórico</title>
  <link rel="stylesheet" href="css/estilo.css">
</head>
<body>
<header>
  <div class="logo">🌫️</div>
  <div>
    <h1>Evaluación del Pronóstico de Calidad del Aire</h1>
    <p>Índice histórico &nbsp;|&nbsp; WRF-Chem vs SINAICA</p>
  </div>
</header>
<main style="max-width:900px;margin:2rem auto;padding:0 1rem 3rem;">
  <h2 style="font-size:1.1rem;color:var(--az);margin-bottom:1rem;">
    📅 Reportes disponibles ({len(reportes)} días)
  </h2>
  <table style="width:100%;border-collapse:collapse;background:#fff;border-radius:10px;
                overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.1);">
    <thead>
      <tr style="background:var(--az);color:#fff;">
        <th style="padding:.7rem 1rem;text-align:left">Fecha</th>
        <th style="padding:.7rem 1rem;text-align:left">Identificador</th>
      </tr>
    </thead>
    <tbody>{filas}</tbody>
  </table>
</main>
<footer>Actualizado el {ts}</footer>
<script>
document.querySelectorAll('tbody tr:nth-child(even)').forEach(r=>r.style.background='#f4f6f9');
</script>
</body>
</html>"""

idx = os.path.join(DIR_WEB,"index.html")
with open(idx,"w",encoding="utf-8") as fh:
    fh.write(html)
print(f"[IDX] {idx}  ({len(reportes)} reportes)")
PYEOF

if "${PYTHON}" "${DIR_TMP}/actualizar_indice.py" >> "${LOG_FILE}" 2>&1; then
    ok "  Índice: ${DIR_WEB}/index.html"
else
    warn "  Error actualizando índice — ver ${LOG_FILE}"
fi

# =============================================================================
# ── SECCIÓN 13: LIMPIEZA Y RESUMEN FINAL ─────────────────────────────────────
# =============================================================================

step "Limpieza y resumen"

find "${DIR_TMP}" -maxdepth 1 \( -name "*.py" -o -name "*.tmp" \) \
    -delete 2>/dev/null || true
ok "  Archivos Python temporales eliminados."

TS_FIN=$(date +%s)
DURACION=$(( TS_FIN - TS_INICIO ))
DUR_FMT="$(( DURACION / 60 ))m $(( DURACION % 60 ))s"

{
printf '%s\n' \
  "============================================================" \
  " EJECUCIÓN COMPLETADA  v2.0.0" \
  " Fecha evaluada  : ${FECHA_EVAL}" \
  " WRF disponibles : ${n_wrfout}/3" \
  " Descarga SINAICA: OK=${n_ok} FALLO=${n_fallo} OMITIDO=${n_omitido}" \
  " HTML             : ${DIR_WEB}/${ANIO_EVAL}/${MES_EVAL}/evaluacion_${FECHA_EVAL}.html" \
  " Índice           : ${DIR_WEB}/index.html" \
  " Duración         : ${DUR_FMT}" \
  " Log              : ${LOG_FILE}" \
  "============================================================"
} | tee -a "${LOG_FILE}"

exit 0
