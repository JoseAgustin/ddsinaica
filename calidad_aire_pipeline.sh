#!/bin/bash

# ==========================================================
# calidad_aire_pipeline.sh
# ==========================================================
# Descripción:
#   Pipeline completo para el procesamiento de archivos de
#   calidad del aire. Integra dos etapas en una sola ejecución:
#
#   ETAPA 1 – Separación por contaminante
#     Lee los archivos calidad_aire_*.csv del directorio
#     actual, extrae los registros de O3, PM10 y PM2.5, y
#     genera un CSV individual por estación y contaminante
#     dentro de la carpeta salida/.
#
#   ETAPA 2 – Consolidación por ciudad y contaminante
#     Lee los archivos de salida/, identifica todas las
#     combinaciones únicas Ciudad–Contaminante y genera un
#     CSV consolidado por ciudad en consolidado/, con orden
#     cronológico estricto (fecha + hora ascendente).
#
# Convención de nombres de archivo fuente:
#   calidad_aire_<Ciudad>_<Estacion>.csv
#   La ciudad se infiere del primer segmento (separado por _)
#   del nombre de la estación dentro del archivo de salida.
#
# Salidas:
#   salida/<Estacion>_<Contaminante>.csv
#   consolidado/<Ciudad>_<Contaminante>_consolidado.csv
#
# Dependencias:
#   bash >= 4, awk (POSIX), sort, sed
#
# Uso:
#   Coloca el script en el mismo directorio que los archivos
#   calidad_aire_*.csv y ejecuta:
#     bash calidad_aire_pipeline.sh
#
# ==========================================================

set -euo pipefail

# ----------------------------------------------------------
# Colores para salida en terminal (se desactivan si no hay TTY)
# ----------------------------------------------------------
if [ -t 1 ]; then
    C_GREEN="\033[0;32m"
    C_YELLOW="\033[1;33m"
    C_CYAN="\033[0;36m"
    C_RED="\033[0;31m"
    C_RESET="\033[0m"
else
    C_GREEN="" C_YELLOW="" C_CYAN="" C_RED="" C_RESET=""
fi

info()  { echo -e "${C_CYAN}[INFO]${C_RESET}  $*"; }
ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# ----------------------------------------------------------
# Verificación previa: archivos fuente presentes
# ----------------------------------------------------------
shopt -s nullglob
fuentes=( calidad_aire_*.csv )
shopt -u nullglob

if [ ${#fuentes[@]} -eq 0 ]; then
    error "No se encontraron archivos calidad_aire_*.csv en el directorio actual."
    exit 1
fi

info "Archivos fuente detectados: ${#fuentes[@]}"

# ----------------------------------------------------------
# Directorios de trabajo
# ----------------------------------------------------------
mkdir -p salida consolidado tmp

# ==========================================================
# ETAPA 1 — Separación por contaminante
# ==========================================================
echo ""
echo -e "${C_CYAN}========================================${C_RESET}"
echo -e "${C_CYAN} ETAPA 1: Separación por contaminante   ${C_RESET}"
echo -e "${C_CYAN}========================================${C_RESET}"

total_generados=0
total_sin_datos=0

for file in "${fuentes[@]}"; do

    # Extraer nombre de estación desde el nombre del archivo
    # Ejemplo: calidad_aire_Guadalajara_Centro.csv → Guadalajara_Centro
    estacion=$(basename "$file" .csv | sed 's/^calidad_aire_//')

    info "Procesando estación: $estacion"

    header=$(head -n 1 "$file")

    for contaminante in O3 PM10 PM2.5; do

        output="salida/${estacion}_${contaminante}.csv"

        printf '%s\n' "$header" > "$output"

        # Filtrar registros del contaminante.
        # IMPORTANTE: PM10 excluye explícitamente PM2.5 para evitar
        # falsos positivos en estaciones que reportan ambos juntos.
        awk -F',' -v pol="$contaminante" '
            NR > 1 {
                id = $1
                if      (pol == "O3"    && id ~ /O3/)              print
                else if (pol == "PM10"  && id ~ /PM10/ &&
                                           id !~ /PM2\.5/)          print
                else if (pol == "PM2.5" && id ~ /PM2\.5/)           print
            }
        ' "$file" >> "$output"

        # Descartar si el archivo quedó solo con encabezado
        if [ "$(wc -l < "$output")" -eq 1 ]; then
            rm "$output"
            warn "  Sin datos para $contaminante en $estacion"
            (( total_sin_datos++ )) || true
        else
            ok "  Generado: $output"
            (( total_generados++ )) || true
        fi

    done
done

echo ""
info "Etapa 1 completada — Generados: $total_generados | Sin datos: $total_sin_datos"

# ==========================================================
# ETAPA 2 — Consolidación por ciudad y contaminante
# ==========================================================
echo ""
echo -e "${C_CYAN}============================================${C_RESET}"
echo -e "${C_CYAN} ETAPA 2: Consolidación Ciudad-Contaminante ${C_RESET}"
echo -e "${C_CYAN}============================================${C_RESET}"

lista_tmp="tmp/lista_ciudad_contaminante.txt"

# Identificar combinaciones únicas Ciudad–Contaminante
# a partir de los archivos ya generados en salida/.
# Nombre esperado: <Ciudad>_..._<Contaminante>.csv
cd salida || { error "No se puede acceder al directorio salida/"; exit 1; }

for file in *.csv; do
    [ -e "$file" ] || continue
    contaminante=$(echo "$file" | awk -F'_' '{print $NF}' | sed 's/\.csv$//')
    ciudad=$(echo "$file"       | awk -F'_' '{print $1}')
    echo "${ciudad},${contaminante}"
done | sort -u > "../$lista_tmp"

cd ..

if [ ! -s "$lista_tmp" ]; then
    warn "No se encontraron combinaciones Ciudad–Contaminante en salida/."
    rmdir tmp 2>/dev/null || true
    exit 0
fi

total_consolidados=0

while IFS=',' read -r ciudad contaminante; do

    info "Procesando: Ciudad=$ciudad | Contaminante=$contaminante"

    # Recopilar todos los archivos de las estaciones de esta ciudad
    # (compatible con bash 3.x / macOS: evita mapfile/readarray)
    archivos=()
    while IFS= read -r -d '' f; do
        archivos+=( "$f" )
    done < <(find salida -maxdepth 1 -name "${ciudad}_*_${contaminante}.csv" -print0 2>/dev/null | sort -z)

    if [ ${#archivos[@]} -eq 0 ]; then
        warn "  No existen archivos para esta combinación."
        continue
    fi

    raw_tmp="tmp/${ciudad}_${contaminante}_raw.csv"
    destino="consolidado/${ciudad}_${contaminante}_consolidado.csv"

    # ----------------------------------------------------------
    # awk: pivota múltiples estaciones en una sola tabla.
    #   Encabezado → date, hour, <estacion1>, <estacion2>, …
    #   Valores ausentes se rellenan con NA.
    #   Compatible con awk POSIX estándar (sin arrays de arrays).
    # ----------------------------------------------------------
    awk -F',' -v ciudad="$ciudad" -v pol="$contaminante" '
    BEGIN { OFS = "," }

    FNR == 1 {
        # Derivar nombre de estación a partir del nombre del archivo
        file = FILENAME
        sub(/^.*salida\//, "", file)   # quitar ruta
        sub("_" pol ".csv", "", file)  # quitar sufijo de contaminante
        sub(ciudad "_", "",   file)    # quitar prefijo de ciudad

        if (!(file in station_idx)) {
            station_idx[file]       = ++nstation
            station_name[nstation]  = file
        }
        next
    }

    {
        # Clave de registro: fecha (col 2) + hora (col 3)
        key = $2 "," $3
        data[key, station_idx[file]] = $4
        keys[key] = 1
    }

    END {
        printf "date,hour"
        for (i = 1; i <= nstation; i++)
            printf "," station_name[i]
        printf "\n"

        for (k in keys) {
            split(k, a, ",")
            printf "%s,%s", a[1], a[2]
            for (i = 1; i <= nstation; i++)
                printf "," (((k, i) in data) ? data[k, i] : "NA")
            printf "\n"
        }
    }
    ' "${archivos[@]}" > "$raw_tmp"

    # ----------------------------------------------------------
    # Ordenar cronológicamente: fecha (lexicográfico YYYY-MM-DD)
    # y hora (numérico ascendente), conservando el encabezado.
    # ----------------------------------------------------------
    {
        head -n 1 "$raw_tmp"
        tail -n +2 "$raw_tmp" | sort -t',' -k1,1 -k2,2n
    } > "$destino"

    rm "$raw_tmp"
    ok "  Generado: $destino"
    (( total_consolidados++ )) || true

done < "$lista_tmp"

# ----------------------------------------------------------
# Limpieza de temporales
# ----------------------------------------------------------
rm -f "$lista_tmp"
rmdir tmp 2>/dev/null || true

echo ""
echo -e "${C_GREEN}================================================${C_RESET}"
echo -e "${C_GREEN} Pipeline finalizado correctamente              ${C_RESET}"
echo -e "${C_GREEN}  Etapa 1 — CSVs por estación : $total_generados${C_RESET}"
echo -e "${C_GREEN}  Etapa 2 — Consolidados      : $total_consolidados${C_RESET}"
echo -e "${C_GREEN}================================================${C_RESET}"
