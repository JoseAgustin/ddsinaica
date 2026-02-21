import pandas as pd
import subprocess
import os
from datetime import datetime
from dateutil.relativedelta import relativedelta

# Configuración de Redes y Estaciones según requerimiento técnico
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
    }
]

PARAMETROS = ["PM10", "PM2.5", "O3"]
FECHA_INICIO = datetime(2025, 4, 1) # Fecha solicitada (Nota: requiere que llegue el tiempo actual a esta fecha)
FECHA_FIN = datetime.now()
FORMATO_SALIDA = "csv"  # Puede cambiarse a "json"

def download_data_r(network_name, station_name, parameter, start_date, end_date):
    """
    Llama a R para usar rsinaica filtrando por Red y Estación específica.
    """
    r_script = f"""
    library(rsinaica)
    # Filtrar por nombre de estación y nombre de la red específica según metadatos de SINAICA
    station <- stations_sinaica[which(stations_sinaica$station_name == "{station_name}" & 
                                     stations_sinaica$network_name == "{network_name}"), ]
    if(nrow(station) > 0) {{
        # Descarga de datos crudos (Crude) para asegurar disponibilidad reciente
        data <- sinaica_station_data(station$station_id, "{parameter}", "{start_date}", "{end_date}", "Crude")
        if(!is.null(data)) {{
            write.csv(data, "temp_data.csv", row.names = FALSE)
        }}
    }}
    """
    with open("temp_script.R", "w") as f:
        f.write(r_script)
    
    # Ejecución del subproceso de R
    subprocess.run(["Rscript", "temp_script.R"], capture_output=True)
    
    if os.path.exists("temp_data.csv"):
        df = pd.read_csv("temp_data.csv")
        os.remove("temp_data.csv")
        return df
    return pd.DataFrame()

def process_and_save():
    for red_info in CONFIGURACION_REDES:
        nombre_red = red_info["red"]
        for estacion in red_info["estaciones"]:
            all_data = []
            current_date = FECHA_INICIO
            
            # Bucle mensual para respetar restricciones de consulta de la API (un mes máximo)
            while current_date < FECHA_FIN:
                next_date = current_date + relativedelta(months=1)
                end_str = min(next_date, FECHA_FIN).strftime("%Y-%m-%d")
                start_str = current_date.strftime("%Y-%m-%d")
                
                for param in PARAMETROS:
                    print(f"[{nombre_red}] Consultando {param} para {estacion} ({start_str} a {end_str})...")
                    df_month = download_data_r(nombre_red, estacion, param, start_str, end_str)
                    
                    if not df_month.empty:
                        # Requerimiento: Promedios de 24h para partículas (PM10 y PM2.5)
                        if param in ["PM1.0", "PM25"]:
                            df_month['date'] = pd.to_datetime(df_month['date'])
                            # Agrupación por día para obtener el promedio diario
                            df_month = df_month.groupby(['station_id', df_month['date'].dt.date]).agg({'value': 'mean'}).reset_index()
                        
                        all_data.append(df_month)
                
                current_date = next_date

            # Consolidación final por estación
            if all_data:
                final_df = pd.concat(all_data)
                safe_name = f"{nombre_red}_{estacion}".replace(" ", "_").replace(".", "")
                filename = f"calidad_aire_{safe_name}.{FORMATO_SALIDA}"
                
                if FORMATO_SALIDA == "csv":
                    final_df.to_csv(filename, index=False)
                else:
                    final_df.to_json(filename, orient="records")
                print(f"--- Archivo generado: {filename} ---")
            else:
                print(f"No se encontraron datos para {estacion} en la red {nombre_red}.")

if __name__ == "__main__":
    process_and_save()