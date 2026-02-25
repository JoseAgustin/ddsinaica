import pandas as pd
import subprocess
import os
from datetime import datetime
from dateutil.relativedelta import relativedelta

# =============================================================================
# CONFIGURACIÓN DE REDES Y ESTACIONES
# Cada elemento define una red de monitoreo y sus estaciones activas.
# Los nombres deben coincidir exactamente con el catálogo stations_sinaica
# del paquete R rsinaica (https://github.com/diegovalle/rsinaica).
# =============================================================================
CONFIGURACION_REDES = [
    {
        "red": "Toluca",
        "estaciones": ["Toluca Centro", "Ceboruco", "Almoloya de Juárez", "Oxtotitlán", "Metepec"]
    },
    {
        "red": "Puebla",
        "estaciones": ["Atlixco", "Las Ninfas", "Tehuacán", "San Martín Texmelucan", "Universidad Tecnológica de Puebla"]
    },
    {
        "red": "Tlaxcala",
        "estaciones": ["Palacio de Gobierno", "Apizaco"]
    },
    {
        "red": "Pachuca",
        "estaciones": ["Instituto Tecnológico de Pachuca", "Primaria Ignacio Zaragoza"]
    },
    {
        "red": "Cuernavaca",
        "estaciones": ["Cuernavaca 01"]
    },
    {
        "red": "San Juan del Rio",
        "estaciones": ["San Juan del Río"]
    }
]

# Parámetros atmosféricos a descargar
PARAMETROS = ["PM10", "PM2.5", "O3"]

# Ventana temporal de descarga
FECHA_INICIO   = datetime(2025,11, 1)  # Inicio fijo del periodo
FECHA_FIN      = datetime.now()         # Fin dinámico: fecha y hora actuales

# Formato de archivos de salida: "csv" o "json"
FORMATO_SALIDA = "csv"


def download_data_r(network_name, station_name, parameter, start_date, end_date):
    """
    Descarga datos horarios de calidad del aire desde SINAICA usando el
    paquete R rsinaica, filtrando por red y estación específicas.

    Flujo:
        1. Genera un script R temporal (temp_script.R) con los parámetros
           de consulta interpolados.
        2. Ejecuta el script con Rscript como subproceso.
        3. Si R encontró datos, escribe temp_data.csv.
        4. Lee temp_data.csv con pandas y lo elimina.
        5. Elimina temp_script.R al finalizar (siempre).

    Args:
        network_name (str): Nombre de la red (ej. "Toluca").
        station_name (str): Nombre exacto de la estación según SINAICA.
        parameter    (str): Código del contaminante ("PM10", "PM2.5", "O3").
        start_date   (str): Fecha de inicio en formato "YYYY-MM-DD".
        end_date     (str): Fecha de fin en formato "YYYY-MM-DD".

    Returns:
        pd.DataFrame: Datos horarios, o DataFrame vacío si no hay datos
                      o si ocurrió un error.
    """
    # ── Script R generado dinámicamente ──────────────────────────────────────
    # IMPORTANTE: este string contiene SOLO código R.
    # No incluir ninguna sentencia Python aquí dentro.
    r_script = f"""
    library(rsinaica)

    # Agregar manualmente estaciones que no están en el catálogo oficial.
    # "Primaria Ignacio Zaragoza" (Pachuca) no estaba en stations_sinaica
    # al momento del desarrollo. VERIFICAR que station_id = 501 sea el ID
    # real en el portal SINAICA antes de ejecutar en producción.
    if (!("Primaria Ignacio Zaragoza" %in% stations_sinaica$station_name)) {{
        nueva_estacion <- data.frame(
            station_id        = 501,
            station_name      = "Primaria Ignacio Zaragoza",
            station_code      = "PIZ",
            network_id        = 59,
            network_name      = "Pachuca",
            network_code      = "PAC",
            street            = "Samuel Carro",
            ext               = "45",
            interior          = "S/N",
            colonia           = "Periodistas",
            zip               = "42060",
            state_code        = 13,
            municipio_code    = 495,
            year_started      = "NA",
            altitude          = 2393,
            address           = "Samuel Carro 45, 42060, Pachuca, Hidalgo",
            date_validated    = "NA",
            date_validated2   = "NA",
            passed_validation = "NA",
            video             = "",
            lat               = 20.12,
            lon               = -98.74,
            date_started      = "NA",
            timezone          = "Tiempo del centro (UTC-6 todo el año)",
            street_view       = "",
            video_interior    = ""
        )
        stations_sinaica <- rbind(stations_sinaica, nueva_estacion)
    }}

    # Filtrar estación por nombre y red (ambos deben coincidir exactamente)
    station <- stations_sinaica[
        which(stations_sinaica$station_name == "{station_name}" &
              stations_sinaica$network_name == "{network_name}"), ]

    if (nrow(station) > 0) {{
        # Descarga de datos crudos (Crude) para asegurar disponibilidad reciente.
        # Los datos validados pueden tener un rezago de semanas o meses.
        data <- sinaica_station_data(
            station$station_id, "{parameter}",
            "{start_date}", "{end_date}", "Crude"
        )
        if (!is.null(data) && nrow(data) > 0) {{
            write.csv(data, "temp_data.csv", row.names = FALSE)
        }}
    }}
    """
    # ── El string R termina aquí. Todo lo que sigue es Python. ───────────────

    # Escribir el script R en disco
    with open("temp_script.R", "w", encoding="utf-8") as f:
        f.write(r_script)

    # Ejecutar Rscript y capturar salida para diagnóstico
    result = subprocess.run(
        ["Rscript", "temp_script.R"],
        capture_output=True,
        text=True
    )

    # Registrar errores de R sin interrumpir el proceso Python
    if result.returncode != 0:
        print(f"  [ERROR Rscript] Red={network_name} | Estación={station_name} "
              f"| Param={parameter}\n  {result.stderr[:400]}")

    # ── Leer resultado y limpiar archivos temporales ──────────────────────────
    df = pd.DataFrame()  # valor por defecto: DataFrame vacío

    if os.path.exists("temp_data.csv"):
        try:
            df = pd.read_csv("temp_data.csv")
        except Exception as exc:
            print(f"  [ERROR lectura CSV] {exc}")
        finally:
            os.remove("temp_data.csv")   # siempre eliminar, aunque falle la lectura

    if os.path.exists("temp_script.R"):
        os.remove("temp_script.R")       # limpiar script temporal

    return df  # único punto de retorno (vacío o con datos)


def process_and_save():
    """
    Orquesta la descarga completa iterando sobre todas las combinaciones
    de red, estación, periodo mensual y parámetro atmosférico.

    Para cada estación:
        - Itera mes a mes desde FECHA_INICIO hasta FECHA_FIN.
        - Descarga cada parámetro por mes con download_data_r().
        - Aplica promedio diario de 24 horas a PM10 y PM2.5.
        - Consolida todos los meses y parámetros en un único DataFrame.
        - Guarda el resultado en un archivo por estación.

    Returns:
        None. Los archivos se escriben en el directorio de trabajo actual.
    """
    for red_info in CONFIGURACION_REDES:
        nombre_red = red_info["red"]

        for estacion in red_info["estaciones"]:
            all_data     = []
            current_date = FECHA_INICIO

            # ── Bucle mensual ─────────────────────────────────────────────────
            # Se descarga mes a mes para respetar el límite de la API SINAICA.
            while current_date < FECHA_FIN:
                next_date = current_date + relativedelta(months=1)
                start_str = current_date.strftime("%Y-%m-%d")
                end_str   = min(next_date, FECHA_FIN).strftime("%Y-%m-%d")

                for param in PARAMETROS:
                    print(f"[{nombre_red}] Consultando {param} para "
                          f"{estacion} ({start_str} → {end_str})...")

                    df_month = download_data_r(
                        nombre_red, estacion, param, start_str, end_str
                    )

                    # Verificar explícitamente que df_month no sea None ni vacío
                    if df_month is not None and not df_month.empty:

                        # ── Promedio diario de 24 h (PM10 y PM2.5) ───────────
                        # Requerimiento normativo NOM-025-SSA1-2021:
                        # las partículas se reportan como promedio de 24 horas.
                        if param in ["PM1.0", "PM25"]:   # ← códigos corregidos
                            df_month["date"] = pd.to_datetime(df_month["date"])
                            df_month = (
                                df_month
                                .groupby(["station_id", df_month["date"].dt.date])
                                .agg({"value": "mean"})
                                .reset_index()
                            )
                            df_month["parametro"] = param  # conservar identificación

                        all_data.append(df_month)

                current_date = next_date  # avanzar al siguiente mes

            # ── Consolidar y guardar ──────────────────────────────────────────
            if all_data:
                final_df = pd.concat(all_data, ignore_index=True)

                # Nombre seguro: espacios → "_", puntos eliminados
                safe_name = (
                    f"{nombre_red}_{estacion}"
                    .replace(" ", "_")
                    .replace(".", "")
                )
                filename = f"calidad_aire_{safe_name}.{FORMATO_SALIDA}"

                if FORMATO_SALIDA == "csv":
                    final_df.to_csv(filename, index=False, encoding="utf-8-sig")
                else:
                    final_df.to_json(filename, orient="records", force_ascii=False)

                print(f"  → Archivo generado: {filename} ({len(final_df)} registros)\n")
            else:
                print(f"  ⚠ Sin datos para {estacion} en la red {nombre_red}.\n")


if __name__ == "__main__":
    process_and_save()
