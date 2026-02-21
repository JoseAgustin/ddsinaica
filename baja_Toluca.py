import pandas as pd
import subprocess
import os
import json
from dateutil.relativedelta import relativedelta
from datetime import datetime

# Configuración
ESTACIONES = ["Toluca Centro", "Ceboruco", "Almoloya de Juárez", "Oxtotitlán", "Metepec"]
PARAMETROS = ["PM10", "PM2.5", "O3"]
FECHA_INICIO = datetime(2025, 4, 1)
FECHA_FIN = datetime.now()
FORMATO_SALIDA = "csv"  # Puede cambiarse a "json"

def download_data_r(station_name, parameter, start_date, end_date):
    """
    Llama a R para usar rsinaica y descargar datos crudos [2].
    """
    r_script = f"""
    library(rsinaica)
    # Buscar el ID de la estación en la red de Toluca [3]
    station <- stations_sinaica[which(stations_sinaica$station_name == "{station_name}" & 
                                     stations_sinaica$network_name == "Toluca"), ]
    if(nrow(station) > 0) {{
        data <- sinaica_station_data(station$station_id, "{parameter}", "{start_date}", "{end_date}", "Crude")
        write.csv(data, "temp_data.csv", row.names = FALSE)
    }}
    """
    with open("temp_script.R", "w") as f:
        f.write(r_script)
    
    subprocess.run(["Rscript", "temp_script.R"], capture_output=True)
    
    if os.path.exists("temp_data.csv"):
        df = pd.read_csv("temp_data.csv")
        os.remove("temp_data.csv")
        return df
    return pd.DataFrame()

def process_and_save():
    for estacion in ESTACIONES:
        all_data = []
        current_date = FECHA_INICIO
        
        while current_date < FECHA_FIN:
            # Definir ventana de un mes (límite de la fuente [2])
            next_date = current_date + relativedelta(months=1)
            end_str = min(next_date, FECHA_FIN).strftime("%Y-%m-%d")
            start_str = current_date.strftime("%Y-%m-%d")
            
            for param in PARAMETROS:
                print(f"Descargando {param} para {estacion} de {start_str} a {end_str}...")
                df_month = download_data_r(estacion, param, start_str, end_str)
                
                if not df_month.empty:
                    # Cálculo de promedios de 24h para partículas [Requerimiento]
                    if param in ["CO", "NOx"]:
                        df_month['date'] = pd.to_datetime(df_month['date'])
                        # Agrupar por día para obtener el promedio de 24 horas
                        df_month = df_month.groupby(['station_id', 'date']).agg({'value': 'mean'}).reset_index()
                    
                    all_data.append(df_month)
            
            current_date = next_date

        # Consolidar y guardar por estación
        if all_data:
            final_df = pd.concat(all_data)
            filename = f"calidad_aire_{estacion.replace(' ', '_')}.{FORMATO_SALIDA}"
            
            if FORMATO_SALIDA == "csv":
                final_df.to_csv(filename, index=False)
            else:
                final_df.to_json(filename, orient="records")
            print(f"Archivo guardado: {filename}")

if __name__ == "__main__":
    process_and_save()

