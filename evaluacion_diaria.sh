#!/bin/bash
# =============================================================================
# evaluacion_diaria.sh
# =============================================================================
#
# DESCRIPCIÓN
# -----------
# Script de evaluación diaria automática del pronóstico de calidad del aire
# generado por WRF-Chem. Diseñado para ejecutarse mediante crontab cada día
# por la mañana (se recomienda entre las 06:00 y 08:00 hora local), una vez
# que los archivos wrfout del día anterior ya estén disponibles en el servidor.
#
# El script evalúa tres días de pronóstico:
#   - Pronóstico iniciado hace 2 días → cubre ayer (Día 2 del run)
#   - Pronóstico iniciado hace 3 días → cubre ayer (Día 3 del run)
#   - Pronóstico iniciado hace 1 días → cubre hoy  (Día 1 del run)
#
# En términos de verificación:
#   FECHA_EVAL = ayer
#   Se comparan tres horizontes de pronóstico que corresponden al día de ayer:
#     mod_dia1 → run iniciado en FECHA_EVAL     (pronóstico a 24h)
#     mod_dia2 → run iniciado en FECHA_EVAL-1d  (pronóstico a 48h)
#     mod_dia3 → run iniciado en FECHA_EVAL-2d  (pronóstico a 72h)
#
# FLUJO INTERNO
# -------------
#   1. Verificar disponibilidad de los 3 archivos wrfout necesarios
#   2. Descargar observaciones del día de ayer de SINAICA (baja_CAMe.py)
#   3. Procesar observaciones (calidad_aire_pipeline.sh)
#   4. Extraer variables del modelo para los 3 archivos wrfout (extract_dia.py)
#   5. Combinar observaciones + modelo para la fecha de evaluación
#   6. Calcular métricas estadísticas (stats_dia.py)
#   7. Generar página HTML de resultados
#   8. Actualizar índice histórico del sitio web
#
# PREREQUISITOS
# -------------
#   - Python 3.8+ con: pandas, numpy, xarray, matplotlib, python-docx, dateutil
#   - R con paquete rsinaica instalado
#   - bash >= 4 (para arrays asociativos)
#   - awk, sort, sed (POSIX estándar)
#   - Los scripts auxiliares deben estar en DIR_SCRIPTS:
#       baja_CAMe.py
#       calidad_aire_pipeline.sh
#       extract_dia.py       (generado por este script si no existe)
#       stats_dia.py         (generado por este script si no existe)
#
# INSTALACIÓN EN CRONTAB
# ----------------------
# Editar crontab con:  crontab -e
# Agregar la línea (ejecuta cada día a las 07:00):
#
#   0 7 * * * /ruta/completa/a/evaluacion_diaria.sh >> /ruta/logs/cron.log 2>&1
#
# O con rotación de log por fecha:
#
#   0 7 * * * /ruta/completa/a/evaluacion_diaria.sh \
#             >> /ruta/logs/evaluacion_$(date +\%Y\%m\%d).log 2>&1
#
# ESTRUCTURA DE DIRECTORIOS
# -------------------------
# DIR_PROYECTO/
# ├── evaluacion_diaria.sh          ← este script
# ├── baja_CAMe.py
# ├── calidad_aire_pipeline.sh
# ├── extract_dia.py                ← generado automáticamente
# ├── stats_dia.py                  ← generado automáticamente
# ├── observado/                    ← CSVs consolidados de observaciones
# ├── modelo/                       ← CSVs históricos del modelo
# ├── combinado/
# │   └── ajustados/
# ├── logs/                         ← logs de cada ejecución
# ├── web/                          ← raíz del sitio web
# │   ├── index.html                ← índice histórico
# │   ├── css/
# │   │   └── estilo.css
# │   └── YYYY/
# │       └── MM/
# │           └── evaluacion_YYYY-MM-DD.html
# └── tmp/                          ← archivos temporales (se limpian al final)
#
# AUTOR
# -----
# Pipeline WRF-Chem / Red de Calidad del Aire — Centro de México
# Versión: 1.0  |  Fecha: 2026
#
# =============================================================================

set -euo pipefail

# =============================================================================
# ── SECCIÓN 1: CONFIGURACIÓN GLOBAL ──────────────────────────────────────────
# =============================================================================

# --- Rutas principales --------------------------------------------------------
DIR_PROYECTO="/home/wrf/evaluacion"          # ← CAMBIAR a la ruta del proyecto
DIR_WRF="/LUSTRE/OPERATIVO/EXTERNO-salidas/WRF-CHEM"  # ← directorio WRF-Chem
DIR_WEB="${DIR_PROYECTO}/web"                # raíz del servidor web
DIR_LOGS="${DIR_PROYECTO}/logs"
DIR_TMP="${DIR_PROYECTO}/tmp"
DIR_OBS="${DIR_PROYECTO}/observado"
DIR_MODELO="${DIR_PROYECTO}/modelo"
DIR_COMBINADO="${DIR_PROYECTO}/combinado"
DIR_AJUSTADOS="${DIR_COMBINADO}/ajustados"

# --- Ejecutables --------------------------------------------------------------
PYTHON="python3"                             # ← ajustar si se usa virtualenv
RSCRIPT="Rscript"

# --- Ciudades del dominio -----------------------------------------------------
# Formato: "NOMBRE:lat_sur:lat_norte:lon_oeste:lon_este"
declare -a CIUDADES=(
    "CDMX:19.20:19.70:-99.30:-98.85"
    "Toluca:19.23:19.39:-99.72:-99.50"
    "Puebla:18.95:19.12:-98.32:-98.10"
    "Tlaxcala:19.29:19.36:-98.26:-98.15"
    "Pachuca:20.03:20.13:-98.80:-98.67"
    "Cuernavaca:18.89:18.98:-99.26:-99.14"
    "SJdelRio:20.36:20.41:-100.01:-99.93"
)

# --- Parámetros de evaluación -------------------------------------------------
CONTAMINANTES=("o3" "PM10" "PM25")
UMBRAL_O3=135          # ppbv — umbral dicotómico NOM-020-SSA1
UMBRAL_PM10=75         # µg/m³ — promedio 24h NOM-025-SSA1
UMBRAL_PM25=45         # µg/m³ — promedio 24h NOM-025-SSA1
BOOTSTRAP_N=10000      # número de remuestras bootstrap

# --- Fechas de evaluación -----------------------------------------------------
# FECHA_EVAL: día que se evalúa = ayer
# Los tres archivos wrfout que cubren ese día son:
#   RUN_D1: iniciado en FECHA_EVAL       → su dia1 cubre FECHA_EVAL
#   RUN_D2: iniciado en FECHA_EVAL - 1d  → su dia2 cubre FECHA_EVAL
#   RUN_D3: iniciado en FECHA_EVAL - 2d  → su dia3 cubre FECHA_EVAL
FECHA_EVAL=$(date -d "yesterday" +%Y-%m-%d)
RUN_D1="${FECHA_EVAL}"
RUN_D2=$(date -d "${FECHA_EVAL} -1 day" +%Y-%m-%d)
RUN_D3=$(date -d "${FECHA_EVAL} -2 days" +%Y-%m-%d)

ANIO_EVAL=$(date -d "${FECHA_EVAL}" +%Y)
MES_EVAL=$(date -d  "${FECHA_EVAL}" +%m)
DIA_EVAL=$(date -d  "${FECHA_EVAL}" +%d)

# =============================================================================
# ── SECCIÓN 2: FUNCIONES UTILITARIAS ─────────────────────────────────────────
# =============================================================================

# Colores para log (se desactivan si no hay TTY)
if [ -t 1 ]; then
    C_GRN="\033[0;32m"; C_YLW="\033[1;33m"
    C_CYN="\033[0;36m"; C_RED="\033[0;31m"; C_RST="\033[0m"
else
    C_GRN=""; C_YLW=""; C_CYN=""; C_RED=""; C_RST=""
fi

# Timestamp para cada línea de log
ts()    { date "+%Y-%m-%d %H:%M:%S"; }
info()  { echo -e "$(ts) ${C_CYN}[INFO]${C_RST}  $*" | tee -a "${LOG_FILE}"; }
ok()    { echo -e "$(ts) ${C_GRN}[OK]${C_RST}    $*" | tee -a "${LOG_FILE}"; }
warn()  { echo -e "$(ts) ${C_YLW}[WARN]${C_RST}  $*" | tee -a "${LOG_FILE}"; }
error() { echo -e "$(ts) ${C_RED}[ERROR]${C_RST} $*" | tee -a "${LOG_FILE}" >&2; }
die()   { error "$*"; exit 1; }

# Verificar si un comando existe
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Comando requerido no encontrado: $1"
}

# Obtener ruta del wrfout según la convención del servidor
wrfout_path() {
    local fecha="$1"
    local anio; anio=$(date -d "$fecha" +%Y)
    echo "${DIR_WRF}/${anio}/wrfout_d01_${fecha}_00:00:00"
}

# =============================================================================
# ── SECCIÓN 3: INICIALIZACIÓN ────────────────────────────────────────────────
# =============================================================================

# Crear directorios si no existen
mkdir -p "${DIR_LOGS}" "${DIR_TMP}" "${DIR_OBS}" \
         "${DIR_MODELO}" "${DIR_COMBINADO}" "${DIR_AJUSTADOS}" \
         "${DIR_WEB}/css" "${DIR_WEB}/${ANIO_EVAL}/${MES_EVAL}"

# Archivo de log para esta ejecución
LOG_FILE="${DIR_LOGS}/evaluacion_${FECHA_EVAL}.log"

# Limpiar tmp de ejecuciones anteriores
rm -f "${DIR_TMP}"/*.tmp "${DIR_TMP}"/*.csv "${DIR_TMP}"/*.py 2>/dev/null || true

info "============================================================"
info " EVALUACIÓN DIARIA DE PRONÓSTICO — WRF-Chem"
info " Fecha de evaluación : ${FECHA_EVAL}"
info " Archivos wrfout analizados:"
info "   Día 1 (run ${RUN_D1}): Horizonte 24h"
info "   Día 2 (run ${RUN_D2}): Horizonte 48h"
info "   Día 3 (run ${RUN_D3}): Horizonte 72h"
info "============================================================"

# Verificar dependencias
require_cmd "${PYTHON}"
require_cmd "${RSCRIPT}"
require_cmd awk
require_cmd sort

# =============================================================================
# ── SECCIÓN 4: VERIFICAR ARCHIVOS WRFOUT ─────────────────────────────────────
# =============================================================================

info "── Etapa 1: Verificando disponibilidad de archivos WRF-Chem ──"

declare -A WRFOUT_OK=()
declare -A WRFOUT_PATH=()

for run_fecha in "${RUN_D1}" "${RUN_D2}" "${RUN_D3}"; do
    ruta=$(wrfout_path "${run_fecha}")
    WRFOUT_PATH["${run_fecha}"]="${ruta}"
    if [ -f "${ruta}" ]; then
        ok "  Encontrado: $(basename "${ruta}")"
        WRFOUT_OK["${run_fecha}"]=1
    else
        warn "  NO encontrado: ${ruta}"
        WRFOUT_OK["${run_fecha}"]=0
    fi
done

# Si ningún wrfout está disponible, abortar
n_disponibles=0
for run_fecha in "${RUN_D1}" "${RUN_D2}" "${RUN_D3}"; do
    [[ "${WRFOUT_OK[${run_fecha}]}" -eq 1 ]] && (( n_disponibles++ )) || true
done

if [ "${n_disponibles}" -eq 0 ]; then
    die "No hay archivos wrfout disponibles para ${FECHA_EVAL}. Abortando."
fi

info "  Archivos disponibles: ${n_disponibles}/3"

# =============================================================================
# ── SECCIÓN 5: DESCARGAR OBSERVACIONES ───────────────────────────────────────
# =============================================================================

info "── Etapa 2: Descargando observaciones de SINAICA ──"

# Generar script Python temporal que modifica baja_CAMe.py para descargar
# solo el día de evaluación (FECHA_EVAL)
cat > "${DIR_TMP}/baja_dia.py" << PYEOF
# Script de descarga para UN día específico
# Invoca baja_CAMe.py con fechas acotadas al día de evaluación
import sys, os

sys.path.insert(0, "${DIR_PROYECTO}")

# Parchear las fechas antes de importar
import importlib.util, types

# Leer código fuente de baja_CAMe.py
with open("${DIR_PROYECTO}/baja_CAMe.py", "r", encoding="utf-8") as fh:
    src = fh.read()

# Reemplazar el rango de fechas con el día de evaluación
from datetime import datetime
fecha_eval = datetime.strptime("${FECHA_EVAL}", "%Y-%m-%d")
fecha_fin  = datetime.strptime("${FECHA_EVAL}", "%Y-%m-%d")

import re
src = re.sub(
    r'FECHA_INICIO\s*=\s*datetime\([^)]+\)',
    f'FECHA_INICIO = datetime({fecha_eval.year}, {fecha_eval.month}, {fecha_eval.day})',
    src
)
src = re.sub(
    r'FECHA_FIN\s*=\s*.*',
    f'FECHA_FIN = datetime({fecha_fin.year}, {fecha_fin.month}, {fecha_fin.day + 1})',
    src
)

# Cambiar directorio de trabajo para que los CSV se generen en DIR_PROYECTO
os.chdir("${DIR_PROYECTO}")

exec(compile(src, "baja_CAMe.py", "exec"))
PYEOF

cd "${DIR_PROYECTO}"
if ${PYTHON} "${DIR_TMP}/baja_dia.py"; then
    ok "  Descarga de observaciones completada."
else
    warn "  Error en descarga. Se intentará continuar con observaciones anteriores."
fi

# =============================================================================
# ── SECCIÓN 6: PROCESAR OBSERVACIONES ────────────────────────────────────────
# =============================================================================

info "── Etapa 3: Procesando observaciones (separación y consolidación) ──"

cd "${DIR_PROYECTO}"

# Verificar que existan archivos calidad_aire_*.csv
shopt -s nullglob
archivos_raw=( calidad_aire_*.csv )
shopt -u nullglob

if [ ${#archivos_raw[@]} -eq 0 ]; then
    warn "  No se encontraron archivos calidad_aire_*.csv. Saltando procesamiento."
else
    info "  Archivos de observación encontrados: ${#archivos_raw[@]}"
    if bash "${DIR_PROYECTO}/calidad_aire_pipeline.sh"; then
        ok "  Pipeline de observaciones completado."
        # Copiar consolidados a observado/
        n_consolidados=0
        for f in "${DIR_PROYECTO}/consolidado/"*_consolidado.csv; do
            [ -f "$f" ] || continue
            cp "$f" "${DIR_OBS}/"
            (( n_consolidados++ )) || true
        done
        ok "  Archivos consolidados copiados a observado/: ${n_consolidados}"
    else
        warn "  Error en pipeline de observaciones."
    fi
fi

# =============================================================================
# ── SECCIÓN 7: EXTRAER VARIABLES DEL MODELO ──────────────────────────────────
# =============================================================================

info "── Etapa 4: Extrayendo variables del modelo WRF-Chem ──"

# Generar script Python de extracción para un archivo wrfout específico
cat > "${DIR_TMP}/extract_dia.py" << 'PYEOF'
#!/usr/bin/env python3
"""
extract_dia.py
Extrae O3, PM10 y PM2.5 de un archivo wrfout para una fecha y horizonte dados.
Uso: python extract_dia.py <ruta_wrfout> <fecha_run> <horizonte> <dir_salida>
  horizonte: 1 = dia1 (indices 6-29), 2 = dia2 (indices 30-53), 3 = dia3 (indices 54-71)
"""
import sys, os
import xarray as xr
import numpy as np
import pandas as pd

ruta_wrf   = sys.argv[1]
fecha_run  = sys.argv[2]
horizonte  = int(sys.argv[3])
dir_salida = sys.argv[4]

CIUDADES = [
    {"nombre": "CDMX",       "lat1": 19.20, "lon1": -99.30, "lat2": 19.70, "lon2": -98.85},
    {"nombre": "Toluca",     "lat1": 19.23, "lon1": -99.72, "lat2": 19.39, "lon2": -99.50},
    {"nombre": "Puebla",     "lat1": 18.95, "lon1": -98.32, "lat2": 19.12, "lon2": -98.10},
    {"nombre": "Tlaxcala",   "lat1": 19.29, "lon1": -98.26, "lat2": 19.36, "lon2": -98.15},
    {"nombre": "Pachuca",    "lat1": 20.03, "lon1": -98.80, "lat2": 20.13, "lon2": -98.67},
    {"nombre": "Cuernavaca", "lat1": 18.89, "lon1": -99.26, "lat2": 18.98, "lon2": -99.14},
    {"nombre": "SJdelRio",   "lat1": 20.36, "lon1": -100.01,"lat2": 20.41, "lon2": -99.93},
]

# Rangos de tiempo según horizonte (hora local UTC-6)
RANGOS = {
    1: slice(6,  30),   # Día 1: 24 horas
    2: slice(30, 54),   # Día 2: 24 horas
    3: slice(54, 72),   # Día 3: 18 horas
}

VARS_PM = {
    "PM10": ["PM10", "pm10"],
    "PM25": ["PM2_5_DRY", "PM2_5", "pm2_5_dry", "pm2_5"],
}

def encontrar_var(ds, nombres):
    for n in nombres:
        if n in ds.variables:
            return n
    return None

if not os.path.exists(ruta_wrf):
    print(f"[EXTRACT] Archivo no encontrado: {ruta_wrf}", file=sys.stderr)
    sys.exit(1)

print(f"[EXTRACT] Abriendo: {os.path.basename(ruta_wrf)} | Horizonte {horizonte}")

try:
    ds = xr.open_dataset(ruta_wrf, decode_times=False)
except Exception as e:
    print(f"[EXTRACT] Error abriendo NetCDF: {e}", file=sys.stderr)
    sys.exit(1)

rango = RANGOS[horizonte]
lat   = ds["XLAT"][0, :, :]
lon   = ds["XLONG"][0, :, :]

os.makedirs(dir_salida, exist_ok=True)

for ciudad in CIUDADES:
    mask = (
        (lat >= ciudad["lat1"]) & (lat <= ciudad["lat2"]) &
        (lon >= ciudad["lon1"]) & (lon <= ciudad["lon2"])
    )
    row = {"Fecha": fecha_run, "Ciudad": ciudad["nombre"], "horizonte": horizonte}

    # ── O3: máximo espacial del máximo temporal ──────────────────────────────
    try:
        o3_sfc  = ds["o3"].isel(bottom_top=0).where(mask) * 1000  # ppmv→ppbv
        o3_rng  = o3_sfc.isel(Time=rango)
        row["o3"] = float(o3_rng.max().values)
    except Exception as e:
        row["o3"] = float("nan")
        print(f"[EXTRACT] O3 error {ciudad['nombre']}: {e}")

    # ── PM10 y PM2.5: promedio de máximos espaciales ─────────────────────────
    for contaminante, nombres_var in VARS_PM.items():
        var_nombre = encontrar_var(ds, nombres_var)
        if var_nombre is None:
            row[contaminante] = float("nan")
            continue
        try:
            var_data = ds[var_nombre]
            if "bottom_top" in var_data.dims:
                var_sfc = var_data.isel(bottom_top=0)
            else:
                var_sfc = var_data
            var_reg = var_sfc.where(mask)
            max_esp = var_reg.max(dim=["south_north","west_east"], skipna=True)
            row[contaminante] = float(max_esp.isel(Time=rango).mean(skipna=True).values)
        except Exception as e:
            row[contaminante] = float("nan")
            print(f"[EXTRACT] {contaminante} error {ciudad['nombre']}: {e}")

    # Guardar fila en CSV por ciudad y contaminante
    for cont in ["o3", "PM10", "PM25"]:
        csv_out = os.path.join(dir_salida, f"ext_{cont}_{ciudad['nombre']}_h{horizonte}.csv")
        pd.DataFrame([{
            "Fecha": fecha_run,
            "Ciudad": ciudad["nombre"],
            "horizonte": horizonte,
            "valor": row.get(cont, float("nan"))
        }]).to_csv(csv_out, index=False)

    print(f"  {ciudad['nombre']:<12} O3={row.get('o3',float('nan')):.1f} ppbv | "
          f"PM10={row.get('PM10',float('nan')):.1f} | PM25={row.get('PM25',float('nan')):.1f} µg/m³")

ds.close()
print(f"[EXTRACT] Completado: horizonte {horizonte}")
PYEOF

# Ejecutar extracción para cada run disponible
for run_fecha in "${RUN_D1}" "${RUN_D2}" "${RUN_D3}"; do
    if [ "${WRFOUT_OK[${run_fecha}]}" -eq 0 ]; then
        warn "  Saltando run ${run_fecha} (archivo no disponible)"
        continue
    fi

    # Determinar qué horizonte de este run corresponde a FECHA_EVAL
    if   [ "${run_fecha}" = "${RUN_D1}" ]; then horizonte=1
    elif [ "${run_fecha}" = "${RUN_D2}" ]; then horizonte=2
    else horizonte=3
    fi

    info "  Extrayendo run ${run_fecha} → horizonte ${horizonte}..."
    if ${PYTHON} "${DIR_TMP}/extract_dia.py" \
            "${WRFOUT_PATH[${run_fecha}]}" \
            "${run_fecha}" \
            "${horizonte}" \
            "${DIR_TMP}/extraidos"; then
        ok "  Extracción horizonte ${horizonte} completada."
    else
        warn "  Error en extracción horizonte ${horizonte}."
    fi
done

# =============================================================================
# ── SECCIÓN 8: COMBINAR OBSERVACIONES + MODELO PARA FECHA_EVAL ───────────────
# =============================================================================

info "── Etapa 5: Combinando observaciones y modelo para ${FECHA_EVAL} ──"

cat > "${DIR_TMP}/combinar_dia.py" << PYEOF
#!/usr/bin/env python3
"""
Combina el máximo observado del día con los tres horizontes del modelo
para la fecha de evaluación. Genera un CSV por ciudad y contaminante.
"""
import os, glob
import pandas as pd
import numpy as np

FECHA_EVAL   = "${FECHA_EVAL}"
DIR_OBS      = "${DIR_OBS}"
DIR_EXTRAIDOS= "${DIR_TMP}/extraidos"
DIR_SALIDA   = "${DIR_AJUSTADOS}"
os.makedirs(DIR_SALIDA, exist_ok=True)

CIUDADES = ["CDMX","Toluca","Puebla","Tlaxcala","Pachuca","Cuernavaca","SJdelRio"]
CIUDADES_OBS = {
    "CDMX":       "Valle_de_México",
    "Toluca":     "Toluca",
    "Puebla":     "Puebla",
    "Tlaxcala":   "Tlaxcala",
    "Pachuca":    "Pachuca",
    "Cuernavaca": "Cuernavaca",
    "SJdelRio":   "San_Juan_del_Rio",
}
CONTAMINANTES = ["o3","PM10","PM25"]
CONT_OBS_NAME = {"o3":"O3","PM10":"PM10","PM25":"PM2.5"}
FACTOR_CONV   = {"o3":1000, "PM10":1, "PM25":1}  # O3: ppmv→ppbv

for cont in CONTAMINANTES:
    for ciudad in CIUDADES:
        # ── 1. Leer observaciones del día ────────────────────────────────────
        nombre_obs = CIUDADES_OBS.get(ciudad, ciudad)
        patron_obs = os.path.join(DIR_OBS, f"{nombre_obs}_{CONT_OBS_NAME[cont]}_consolidado.csv")
        archivos_obs = glob.glob(patron_obs)

        max_obs = np.nan
        if archivos_obs:
            try:
                df_obs = pd.read_csv(archivos_obs[0])
                df_obs["date"] = pd.to_datetime(df_obs["date"])
                dia = df_obs[df_obs["date"].dt.strftime("%Y-%m-%d") == FECHA_EVAL]
                if not dia.empty:
                    cols_vals = [c for c in dia.columns if c not in ("date","hour")]
                    vals = dia[cols_vals].apply(pd.to_numeric, errors="coerce")
                    factor = FACTOR_CONV.get(cont, 1)
                    max_obs = float(vals.max().max()) * factor
            except Exception as e:
                print(f"  [COMB] Error leyendo obs {ciudad}/{cont}: {e}")

        # ── 2. Leer valores del modelo por horizonte ─────────────────────────
        mod = {}
        for h in [1, 2, 3]:
            csv_ext = os.path.join(DIR_EXTRAIDOS, f"ext_{cont}_{ciudad}_h{h}.csv")
            if os.path.exists(csv_ext):
                try:
                    df_ext = pd.read_csv(csv_ext)
                    val = df_ext["valor"].iloc[0] if not df_ext.empty else np.nan
                    mod[f"mod_dia{h}"] = float(val)
                except Exception:
                    mod[f"mod_dia{h}"] = np.nan
            else:
                mod[f"mod_dia{h}"] = np.nan

        # ── 3. Guardar fila combinada ─────────────────────────────────────────
        fila = {
            "Fecha":    FECHA_EVAL,
            "Ciudad":   ciudad,
            "max_obs":  max_obs,
            "mod_dia1": mod.get("mod_dia1", np.nan),
            "mod_dia2": mod.get("mod_dia2", np.nan),
            "mod_dia3": mod.get("mod_dia3", np.nan),
        }
        csv_out = os.path.join(DIR_SALIDA, f"eval_{cont}_{ciudad}_{FECHA_EVAL}.csv")
        pd.DataFrame([fila]).to_csv(csv_out, index=False)
        print(f"  {ciudad:<12} {cont:<5} obs={max_obs:.1f if not pd.isna(max_obs) else 'NA'!s} "
              f"| d1={mod.get('mod_dia1',float('nan')):.1f} "
              f"d2={mod.get('mod_dia2',float('nan')):.1f} "
              f"d3={mod.get('mod_dia3',float('nan')):.1f}")

print("[COMB] Combinación completada.")
PYEOF

if ${PYTHON} "${DIR_TMP}/combinar_dia.py"; then
    ok "  Combinación obs+modelo completada."
else
    warn "  Error en combinación. Continuando con datos disponibles."
fi

# =============================================================================
# ── SECCIÓN 9: CALCULAR MÉTRICAS ESTADÍSTICAS ────────────────────────────────
# =============================================================================

info "── Etapa 6: Calculando métricas estadísticas ──"

cat > "${DIR_TMP}/stats_dia.py" << PYEOF
#!/usr/bin/env python3
"""
Calcula métricas de validación para el día de evaluación.
Lee los CSV de evaluacion histórica (todos los eval_*.csv disponibles)
y calcula estadísticos con ventana de los últimos 30 días para dar contexto.
Genera un JSON con los resultados que usa el generador HTML.
"""
import os, glob, json
import pandas as pd
import numpy as np

FECHA_EVAL   = "${FECHA_EVAL}"
DIR_AJUSTADOS= "${DIR_AJUSTADOS}"
DIR_SALIDA   = "${DIR_TMP}"

CIUDADES     = ["CDMX","Toluca","Puebla","Tlaxcala","Pachuca","Cuernavaca","SJdelRio"]
CONTAMINANTES= ["o3","PM10","PM25"]
UMBRAL       = {"o3": ${UMBRAL_O3}, "PM10": ${UMBRAL_PM10}, "PM25": ${UMBRAL_PM25}}
B            = ${BOOTSTRAP_N}

def metricas_continuas(obs, mod):
    """Métricas continuas básicas (sin bootstrap para evaluación diaria rápida)."""
    mask = ~(np.isnan(obs) | np.isnan(mod))
    o, m = obs[mask], mod[mask]
    if len(o) < 2:
        return {}
    bias = float(np.mean(m - o))
    rmse = float(np.sqrt(np.mean((m - o)**2)))
    mae  = float(np.mean(np.abs(m - o)))
    corr_mat = np.corrcoef(o, m)
    r    = float(corr_mat[0,1]) if corr_mat.shape == (2,2) else float("nan")
    return {"n": int(len(o)), "bias": bias, "rmse": rmse, "mae": mae, "r": r,
            "obs_mean": float(np.mean(o)), "mod_mean": float(np.mean(m))}

def metricas_dicotomicas(obs, mod, umbral):
    """Métricas dicotómicas para umbral dado."""
    mask = ~(np.isnan(obs) | np.isnan(mod))
    o, m = (obs[mask] > umbral).astype(int), (mod[mask] > umbral).astype(int)
    N = len(o)
    if N == 0:
        return {}
    H = int(np.sum((o==1)&(m==1)))
    M = int(np.sum((o==1)&(m==0)))
    F = int(np.sum((o==0)&(m==1)))
    C = int(np.sum((o==0)&(m==0)))
    sd = lambda a,b: round(a/b,3) if b>0 else None
    return {
        "umbral": umbral, "H": H, "M": M, "F": F, "C": C,
        "POD": sd(H, H+M), "FAR": sd(F, H+F),
        "CSI": sd(H, H+M+F), "PC":  sd(H+C, N),
        "TSS": round((sd(H,H+M) or 0) - (sd(F,F+C) or 0), 3),
    }

resultados = {}

for cont in CONTAMINANTES:
    resultados[cont] = {}
    for ciudad in CIUDADES:
        resultados[cont][ciudad] = {}

        # Cargar todos los CSVs de evaluación disponibles (histórico rolling)
        patron = os.path.join(DIR_AJUSTADOS, f"eval_{cont}_{ciudad}_*.csv")
        archivos = sorted(glob.glob(patron))

        if not archivos:
            resultados[cont][ciudad] = {"error": "sin_datos"}
            continue

        df = pd.concat([pd.read_csv(f) for f in archivos], ignore_index=True)
        df["Fecha"] = pd.to_datetime(df["Fecha"])
        df = df.sort_values("Fecha").drop_duplicates("Fecha")

        # Fila del día de evaluación
        fila_hoy = df[df["Fecha"].dt.strftime("%Y-%m-%d") == FECHA_EVAL]

        # Ventana 30 días para métricas de contexto
        fecha_ini = pd.to_datetime(FECHA_EVAL) - pd.Timedelta(days=30)
        df_30 = df[df["Fecha"] >= fecha_ini].dropna(subset=["max_obs","mod_dia1"])

        stats_dia = {}
        for h_key in ["mod_dia1","mod_dia2","mod_dia3"]:
            obs = df_30["max_obs"].values
            mod = df_30[h_key].values if h_key in df_30.columns else np.array([])
            if len(obs) < 2 or len(mod) < 2:
                stats_dia[h_key] = {}
                continue
            stats_dia[h_key] = {
                "continuas":   metricas_continuas(obs, mod),
                "dicotomicas": metricas_dicotomicas(obs, mod, UMBRAL[cont]),
            }

        # Valor del día
        valor_hoy = {}
        if not fila_hoy.empty:
            for col in ["max_obs","mod_dia1","mod_dia2","mod_dia3"]:
                v = fila_hoy[col].values[0] if col in fila_hoy.columns else None
                valor_hoy[col] = None if (v is None or (isinstance(v,float) and np.isnan(v))) else round(float(v),2)

        resultados[cont][ciudad] = {
            "fecha_eval": FECHA_EVAL,
            "n_historico": int(len(df_30)),
            "valor_hoy":   valor_hoy,
            "stats_30d":   stats_dia,
        }
        print(f"  {cont:<5} {ciudad:<12}: obs={valor_hoy.get('max_obs','NA')} "
              f"d1={valor_hoy.get('mod_dia1','NA')} "
              f"d2={valor_hoy.get('mod_dia2','NA')} "
              f"d3={valor_hoy.get('mod_dia3','NA')}")

# Guardar JSON
json_out = os.path.join(DIR_SALIDA, "stats_${FECHA_EVAL}.json")
with open(json_out, "w", encoding="utf-8") as fh:
    json.dump(resultados, fh, ensure_ascii=False, indent=2, default=str)
print(f"[STATS] JSON generado: {json_out}")
PYEOF

if ${PYTHON} "${DIR_TMP}/stats_dia.py"; then
    ok "  Estadísticos calculados."
else
    warn "  Error en cálculo de estadísticos."
fi

# =============================================================================
# ── SECCIÓN 10: GENERAR PÁGINA HTML ──────────────────────────────────────────
# =============================================================================

info "── Etapa 7: Generando página HTML de resultados ──"

# ── Generar CSS (solo la primera vez o si no existe) ─────────────────────────
CSS_FILE="${DIR_WEB}/css/estilo.css"
if [ ! -f "${CSS_FILE}" ]; then
cat > "${CSS_FILE}" << 'CSSEOF'
/* ── Reset y base ─────────────────────────────────────────────────────── */
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
:root {
    --azul:      #1a4f8a;
    --azul-claro:#2e78c7;
    --gris-bg:   #f4f6f9;
    --gris-brd:  #dde1e7;
    --blanco:    #ffffff;
    --texto:     #2c3e50;
    --verde:     #27ae60;
    --rojo:      #e74c3c;
    --ambar:     #f39c12;
    --morado:    #8e44ad;
    --sombra:    0 2px 8px rgba(0,0,0,.12);
}
body { font-family: 'Segoe UI', Arial, sans-serif; background: var(--gris-bg);
       color: var(--texto); line-height: 1.5; }
a { color: var(--azul-claro); text-decoration: none; }
a:hover { text-decoration: underline; }

/* ── Encabezado ───────────────────────────────────────────────────────── */
header { background: linear-gradient(135deg, var(--azul) 0%, var(--azul-claro) 100%);
         color: white; padding: 1.4rem 2rem; display: flex;
         align-items: center; gap: 1.2rem; box-shadow: var(--sombra); }
header .logo { font-size: 2.4rem; }
header h1 { font-size: 1.5rem; font-weight: 700; }
header p  { font-size: .9rem; opacity: .85; }

/* ── Navegación de pestañas ───────────────────────────────────────────── */
.tabs { display: flex; gap: .4rem; padding: .8rem 2rem 0;
        background: var(--blanco); border-bottom: 2px solid var(--gris-brd);
        flex-wrap: wrap; }
.tab-btn { padding: .5rem 1.1rem; border: none; border-radius: 6px 6px 0 0;
           background: var(--gris-bg); cursor: pointer; font-size: .88rem;
           font-weight: 600; color: var(--texto); transition: all .2s; }
.tab-btn:hover { background: #d0dff5; }
.tab-btn.active { background: var(--azul); color: white; }
.tab-pane { display: none; padding: 1.5rem 2rem; }
.tab-pane.active { display: block; }

/* ── Tarjetas de ciudad ───────────────────────────────────────────────── */
.ciudad-grid { display: grid;
               grid-template-columns: repeat(auto-fill, minmax(340px, 1fr));
               gap: 1.2rem; margin-top: 1rem; }
.ciudad-card { background: var(--blanco); border-radius: 10px;
               box-shadow: var(--sombra); overflow: hidden; }
.ciudad-card .card-header { background: var(--azul); color: white;
               padding: .7rem 1rem; font-weight: 700; font-size: 1rem;
               display: flex; align-items: center; gap: .5rem; }
.ciudad-card .card-body { padding: 1rem; }

/* ── Tabla de valores del día ─────────────────────────────────────────── */
.tabla-dia { width: 100%; border-collapse: collapse; font-size: .87rem; }
.tabla-dia th { background: var(--gris-bg); padding: .45rem .7rem;
                text-align: left; font-weight: 600;
                border-bottom: 2px solid var(--gris-brd); }
.tabla-dia td { padding: .4rem .7rem; border-bottom: 1px solid var(--gris-brd); }
.tabla-dia tr:last-child td { border-bottom: none; }

/* ── Tabla de métricas (30 días) ──────────────────────────────────────── */
.tabla-metricas { width: 100%; border-collapse: collapse;
                  font-size: .82rem; margin-top: .7rem; }
.tabla-metricas th { background: #e8edf4; padding: .38rem .6rem;
                     text-align: center; font-size: .78rem;
                     border: 1px solid var(--gris-brd); }
.tabla-metricas td { padding: .35rem .6rem; text-align: center;
                     border: 1px solid var(--gris-brd); }

/* ── Chips de horizonte ───────────────────────────────────────────────── */
.chip { display: inline-block; padding: .18rem .6rem; border-radius: 12px;
        font-size: .78rem; font-weight: 700; margin-right: .3rem; }
.chip-d1 { background: #fde8e8; color: #c0392b; }
.chip-d2 { background: #e8f5e9; color: #1a7a3a; }
.chip-d3 { background: #e3f2fd; color: #1557a0; }

/* ── Semáforo de calidad ──────────────────────────────────────────────── */
.semaforo { width: 14px; height: 14px; border-radius: 50%;
            display: inline-block; margin-right: .35rem; vertical-align: middle; }
.verde  { background: var(--verde); }
.ambar  { background: var(--ambar); }
.rojo   { background: var(--rojo); }
.gris   { background: #999; }

/* ── Sección de estadísticos ─────────────────────────────────────────── */
.stats-section { margin-top: .8rem; }
.stats-toggle { background: none; border: 1px solid var(--gris-brd);
                border-radius: 6px; padding: .3rem .8rem; font-size: .8rem;
                cursor: pointer; color: var(--azul-claro); }
.stats-toggle:hover { background: #e8edf4; }
.stats-detail { display: none; margin-top: .6rem; }
.stats-detail.open { display: block; }

/* ── Resumen general (cards de KPI) ───────────────────────────────────── */
.kpi-grid { display: grid;
            grid-template-columns: repeat(auto-fill, minmax(160px,1fr));
            gap: .9rem; margin: 1rem 0; }
.kpi { background: var(--blanco); border-radius: 10px; padding: 1rem;
       text-align: center; box-shadow: var(--sombra); }
.kpi .kpi-val { font-size: 1.9rem; font-weight: 800; color: var(--azul); }
.kpi .kpi-lbl { font-size: .78rem; color: #666; margin-top: .2rem; }

/* ── Pie de página ────────────────────────────────────────────────────── */
footer { text-align: center; padding: 1.5rem; color: #888;
         font-size: .8rem; border-top: 1px solid var(--gris-brd);
         margin-top: 2rem; }

/* ── Responsive ──────────────────────────────────────────────────────── */
@media (max-width: 600px) {
    .ciudad-grid { grid-template-columns: 1fr; }
    .kpi-grid    { grid-template-columns: repeat(2,1fr); }
    .tabs        { padding: .5rem 1rem 0; }
}
CSSEOF
    ok "  CSS generado: ${CSS_FILE}"
fi

# ── Generar HTML con Python ───────────────────────────────────────────────────
cat > "${DIR_TMP}/generar_html.py" << PYEOF
#!/usr/bin/env python3
"""Genera la página HTML de evaluación diaria a partir del JSON de estadísticos."""
import json, os, math
from datetime import datetime

FECHA_EVAL    = "${FECHA_EVAL}"
DIR_TMP       = "${DIR_TMP}"
DIR_WEB       = "${DIR_WEB}"
ANIO          = "${ANIO_EVAL}"
MES           = "${MES_EVAL}"

json_path = os.path.join(DIR_TMP, f"stats_{FECHA_EVAL}.json")
html_out  = os.path.join(DIR_WEB, ANIO, MES, f"evaluacion_{FECHA_EVAL}.html")

CIUDADES = ["CDMX","Toluca","Puebla","Tlaxcala","Pachuca","Cuernavaca","SJdelRio"]
ICONOS   = {"CDMX":"🏙️","Toluca":"🏔️","Puebla":"⛩️","Tlaxcala":"🌾",
            "Pachuca":"⛏️","Cuernavaca":"🌺","SJdelRio":"🌊"}
CONT_LABEL  = {"o3":"O₃ (ppbv)","PM10":"PM10 (µg/m³)","PM25":"PM2.5 (µg/m³)"}
H_LABEL     = {"mod_dia1":"Día 0 (+24h)","mod_dia2":"Día 1 (+48h)","mod_dia3":"Día 2 (+72h)"}
H_CHIP_CSS  = {"mod_dia1":"chip-d1","mod_dia2":"chip-d2","mod_dia3":"chip-d3"}
UMBRAL      = {"o3":${UMBRAL_O3},"PM10":${UMBRAL_PM10},"PM25":${UMBRAL_PM25}}

def fmt(v, dec=1):
    if v is None or (isinstance(v,float) and math.isnan(v)):
        return "<span style='color:#aaa'>—</span>"
    return f"{v:.{dec}f}"

def semaforo_bias(bias):
    if bias is None: return "gris"
    if abs(bias) < 10: return "verde"
    if abs(bias) < 25: return "ambar"
    return "rojo"

def semaforo_r(r):
    if r is None: return "gris"
    if r >= 0.7:  return "verde"
    if r >= 0.4:  return "ambar"
    return "rojo"

# Cargar datos
if not os.path.exists(json_path):
    print(f"[HTML] JSON no encontrado: {json_path}")
    exit(1)

with open(json_path, encoding="utf-8") as fh:
    datos = json.load(fh)

fecha_dt  = datetime.strptime(FECHA_EVAL, "%Y-%m-%d")
fecha_fmt = fecha_dt.strftime("%d de %B de %Y").capitalize()
ts_gen    = datetime.now().strftime("%Y-%m-%d %H:%M")

# ── Construir HTML ────────────────────────────────────────────────────────────
def tabs_contaminante():
    tabs = ""
    panes = ""
    for i, cont in enumerate(["o3","PM10","PM25"]):
        activo = "active" if i == 0 else ""
        tabs  += f'<button class="tab-btn {activo}" onclick="mostrarTab(\'{cont}\')" id="tab-{cont}">{CONT_LABEL[cont]}</button>\n'
        panes += f'<div class="tab-pane {activo}" id="pane-{cont}">\n'
        panes += f'  <div class="ciudad-grid">\n'

        for ciudad in CIUDADES:
            info_ciudad = datos.get(cont, {}).get(ciudad, {})
            val_hoy = info_ciudad.get("valor_hoy", {})
            stats   = info_ciudad.get("stats_30d", {})
            n_hist  = info_ciudad.get("n_historico", 0)
            icono   = ICONOS.get(ciudad,"📍")

            # Tabla de valores del día
            filas_valores = ""
            for h_key, h_lbl in H_LABEL.items():
                v_mod = val_hoy.get(h_key)
                v_obs = val_hoy.get("max_obs")
                dif   = (v_mod - v_obs) if (v_mod is not None and v_obs is not None) else None
                chip  = H_CHIP_CSS[h_key]
                filas_valores += (
                    f"<tr>"
                    f"<td><span class='chip {chip}'>{h_lbl}</span></td>"
                    f"<td>{fmt(v_obs)}</td>"
                    f"<td>{fmt(v_mod)}</td>"
                    f"<td>{fmt(dif, dec=1)}</td>"
                    f"</tr>\n"
                )

            # Tabla de métricas últimos 30 días
            filas_metricas = ""
            for h_key, h_lbl in H_LABEL.items():
                st = stats.get(h_key, {}).get("continuas", {})
                bias = st.get("bias"); r = st.get("r"); rmse = st.get("rmse")
                s_bias = semaforo_bias(bias); s_r = semaforo_r(r)
                filas_metricas += (
                    f"<tr>"
                    f"<td><span class='chip {H_CHIP_CSS[h_key]}'>{h_lbl}</span></td>"
                    f"<td><span class='semaforo {s_bias}'></span>{fmt(bias)}</td>"
                    f"<td>{fmt(rmse)}</td>"
                    f"<td><span class='semaforo {s_r}'></span>{fmt(r,2)}</td>"
                    f"</tr>\n"
                )

            # Métricas dicotómicas
            filas_dico = ""
            for h_key, h_lbl in H_LABEL.items():
                sd = stats.get(h_key, {}).get("dicotomicas", {})
                pod = sd.get("POD"); far = sd.get("FAR"); csi = sd.get("CSI")
                filas_dico += (
                    f"<tr>"
                    f"<td><span class='chip {H_CHIP_CSS[h_key]}'>{h_lbl}</span></td>"
                    f"<td>{fmt(pod,3) if pod is not None else '—'}</td>"
                    f"<td>{fmt(far,3) if far is not None else '—'}</td>"
                    f"<td>{fmt(csi,3) if csi is not None else '—'}</td>"
                    f"</tr>\n"
                )

            panes += f"""
    <div class="ciudad-card">
      <div class="card-header">{icono} {ciudad}</div>
      <div class="card-body">
        <table class="tabla-dia">
          <thead><tr>
            <th>Horizonte</th><th>Obs ({CONT_LABEL[cont].split("(")[1].rstrip(")")})</th>
            <th>Modelo</th><th>Diferencia</th>
          </tr></thead>
          <tbody>{filas_valores}</tbody>
        </table>
        <div class="stats-section">
          <button class="stats-toggle" onclick="toggleStats(this)">
            📊 Métricas últimos 30 días (n={n_hist})
          </button>
          <div class="stats-detail">
            <p style="font-size:.8rem;color:#666;margin:.5rem 0 .3rem">Métricas continuas:</p>
            <table class="tabla-metricas">
              <thead><tr><th>Horizonte</th><th>BIAS</th><th>RMSE</th><th>R</th></tr></thead>
              <tbody>{filas_metricas}</tbody>
            </table>
            <p style="font-size:.8rem;color:#666;margin:.5rem 0 .3rem">
              Métricas dicotómicas (umbral {UMBRAL[cont]}):
            </p>
            <table class="tabla-metricas">
              <thead><tr><th>Horizonte</th><th>POD</th><th>FAR</th><th>CSI</th></tr></thead>
              <tbody>{filas_dico}</tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
"""
        panes += "  </div>\n</div>\n"
    return tabs, panes


tabs_str, panes_str = tabs_contaminante()

html = f"""<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Evaluación WRF-Chem — {fecha_fmt}</title>
  <link rel="stylesheet" href="../../css/estilo.css">
</head>
<body>

<header>
  <div class="logo">🌫️</div>
  <div>
    <h1>Evaluación del Pronóstico de Calidad del Aire</h1>
    <p>Modelo WRF-Chem vs Observaciones SINAICA &nbsp;|&nbsp; Fecha de evaluación: <strong>{fecha_fmt}</strong></p>
  </div>
</header>

<main style="max-width:1400px; margin:0 auto; padding:.5rem 1rem 2rem;">

  <!-- KPIs de resumen -->
  <section style="margin-top:1.2rem;">
    <h2 style="font-size:1.1rem; color:var(--azul); margin-bottom:.7rem;">
      📋 Resumen del día
    </h2>
    <div class="kpi-grid">
      <div class="kpi">
        <div class="kpi-val">3</div>
        <div class="kpi-lbl">Horizontes evaluados<br>(+24h, +48h, +72h)</div>
      </div>
      <div class="kpi">
        <div class="kpi-val">7</div>
        <div class="kpi-lbl">Ciudades analizadas</div>
      </div>
      <div class="kpi">
        <div class="kpi-val">3</div>
        <div class="kpi-lbl">Contaminantes<br>(O₃, PM10, PM2.5)</div>
      </div>
      <div class="kpi">
        <div class="kpi-val">30d</div>
        <div class="kpi-lbl">Ventana de métricas<br>estadísticas</div>
      </div>
    </div>
    <p style="font-size:.82rem; color:#666; margin-top:.5rem;">
      <span class="semaforo verde"></span> BIAS &lt; 10 &nbsp;
      <span class="semaforo ambar"></span> BIAS 10–25 &nbsp;
      <span class="semaforo rojo"></span>  BIAS &gt; 25 &nbsp;&nbsp;|&nbsp;&nbsp;
      <span class="semaforo verde"></span> R ≥ 0.7 &nbsp;
      <span class="semaforo ambar"></span> R 0.4–0.7 &nbsp;
      <span class="semaforo rojo"></span>  R &lt; 0.4
    </p>
  </section>

  <!-- Pestañas por contaminante -->
  <section style="margin-top:1.5rem;">
    <h2 style="font-size:1.1rem; color:var(--azul); margin-bottom:.7rem;">
      🔬 Resultados por contaminante y ciudad
    </h2>
    <div class="tabs">
      {tabs_str}
    </div>
    {panes_str}
  </section>

  <!-- Navegación -->
  <section style="margin-top:2rem; padding-top:1rem; border-top:1px solid var(--gris-brd);">
    <a href="../../index.html">← Índice histórico</a>
  </section>

</main>

<footer>
  Generado automáticamente el {ts_gen} &nbsp;|&nbsp;
  Pipeline WRF-Chem / Red de Calidad del Aire — Centro de México
</footer>

<script>
function mostrarTab(cont) {{
    document.querySelectorAll('.tab-pane').forEach(p => p.classList.remove('active'));
    document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
    document.getElementById('pane-' + cont).classList.add('active');
    document.getElementById('tab-'  + cont).classList.add('active');
}}
function toggleStats(btn) {{
    const det = btn.nextElementSibling;
    det.classList.toggle('open');
    btn.textContent = det.classList.contains('open')
        ? btn.textContent.replace('📊','📉')
        : btn.textContent.replace('📉','📊');
}}
</script>
</body>
</html>"""

os.makedirs(os.path.dirname(html_out), exist_ok=True)
with open(html_out, "w", encoding="utf-8") as fh:
    fh.write(html)
print(f"[HTML] Página generada: {html_out}")
PYEOF

if ${PYTHON} "${DIR_TMP}/generar_html.py"; then
    HTML_HOY="${DIR_WEB}/${ANIO_EVAL}/${MES_EVAL}/evaluacion_${FECHA_EVAL}.html"
    ok "  HTML generado: ${HTML_HOY}"
else
    warn "  Error generando HTML del día."
fi

# =============================================================================
# ── SECCIÓN 11: ACTUALIZAR ÍNDICE HISTÓRICO ───────────────────────────────────
# =============================================================================

info "── Etapa 8: Actualizando índice histórico ──"

cat > "${DIR_TMP}/actualizar_indice.py" << PYEOF
#!/usr/bin/env python3
"""Actualiza index.html con enlace al reporte del día recién generado."""
import os, glob
from datetime import datetime

DIR_WEB    = "${DIR_WEB}"
FECHA_EVAL = "${FECHA_EVAL}"

# Recopilar todos los reportes existentes ordenados (más reciente primero)
patron   = os.path.join(DIR_WEB, "????", "??", "evaluacion_????-??-??.html")
reportes = sorted(glob.glob(patron), reverse=True)

def ruta_relativa(ruta_abs):
    return os.path.relpath(ruta_abs, DIR_WEB)

filas = ""
for ruta in reportes:
    nombre = os.path.basename(ruta).replace("evaluacion_","").replace(".html","")
    try:
        dt = datetime.strptime(nombre, "%Y-%m-%d")
        fecha_legible = dt.strftime("%d de %B de %Y").capitalize()
    except ValueError:
        fecha_legible = nombre
    rel = ruta_relativa(ruta)
    filas += f'  <tr><td><a href="{rel}">{fecha_legible}</a></td><td>{nombre}</td></tr>\n'

ts_gen = datetime.now().strftime("%Y-%m-%d %H:%M")

html_idx = f"""<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Evaluación WRF-Chem — Índice histórico</title>
  <link rel="stylesheet" href="css/estilo.css">
</head>
<body>
<header>
  <div class="logo">🌫️</div>
  <div>
    <h1>Evaluación del Pronóstico de Calidad del Aire</h1>
    <p>Índice histórico de reportes diarios &nbsp;|&nbsp; WRF-Chem vs SINAICA</p>
  </div>
</header>
<main style="max-width:900px;margin:2rem auto;padding:0 1rem 3rem;">
  <h2 style="font-size:1.1rem;color:var(--azul);margin-bottom:1rem;">
    📅 Reportes disponibles ({len(reportes)} días)
  </h2>
  <table style="width:100%;border-collapse:collapse;background:white;
                border-radius:10px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.1);">
    <thead>
      <tr style="background:var(--azul);color:white;">
        <th style="padding:.7rem 1rem;text-align:left;">Fecha</th>
        <th style="padding:.7rem 1rem;text-align:left;">Identificador</th>
      </tr>
    </thead>
    <tbody>
{filas}
    </tbody>
  </table>
</main>
<footer>Actualizado el {ts_gen}</footer>
<script>
/* Alternado de filas */
document.querySelectorAll('tbody tr:nth-child(even)')
    .forEach(r => r.style.background='#f4f6f9');
</script>
</body>
</html>"""

idx_out = os.path.join(DIR_WEB, "index.html")
with open(idx_out, "w", encoding="utf-8") as fh:
    fh.write(html_idx)
print(f"[IDX] Índice actualizado: {idx_out} ({len(reportes)} reportes)")
PYEOF

if ${PYTHON} "${DIR_TMP}/actualizar_indice.py"; then
    ok "  Índice histórico actualizado: ${DIR_WEB}/index.html"
else
    warn "  Error actualizando el índice."
fi

# =============================================================================
# ── SECCIÓN 12: LIMPIEZA Y RESUMEN FINAL ─────────────────────────────────────
# =============================================================================

info "── Limpieza de archivos temporales ──"
rm -rf "${DIR_TMP:?}"/*.tmp "${DIR_TMP}"/*.py 2>/dev/null || true
ok "  Temporales eliminados."

# Calcular duración total
DURACION=$(( $(date +%s) - $(date -d "${FECHA_EVAL}" +%s 2>/dev/null || date +%s) ))

info "============================================================"
info " EJECUCIÓN COMPLETADA"
info " Fecha evaluada  : ${FECHA_EVAL}"
info " HTML generado   : ${DIR_WEB}/${ANIO_EVAL}/${MES_EVAL}/evaluacion_${FECHA_EVAL}.html"
info " Índice web      : ${DIR_WEB}/index.html"
info " Log de sesión   : ${LOG_FILE}"
info "============================================================"

exit 0
