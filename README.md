# Documentación del Script: Extracción de Datos de Calidad del Aire (SINAICA)
## Descripción General
Este script automatiza la descarga de datos horarios de contaminantes criterio (PM10, PM2.5 y O3) desde el Sistema Nacional de Información de la Calidad del Aire (SINAICA) para estaciones específicas en los estados de Puebla, Tlaxcala e Hidalgo. El desarrollo se alinea con la necesidad de fortalecer los sistemas de información y modelación atmosférica identificada en el PROAIRE de la Megalópolis 2017-2030.

Características Técnicas

- **Lenguaje:** Python 3.x (Actuando como controlador).
- **Backend de Extracción:** Lenguaje R mediante la librería `rsinaica`.
- **Manejo de Restricciones:** El script implementa un bucle mensual para superar el límite de consulta de 30 días impuesto por la API de SINAICA.
- **Procesamiento:**
    - Partículas (PM10 y PM2.5): Descarga de valores horarios crudos.
    - Ozono (O3): Descarga de valores horarios crudos.
- **Formatos de Salida:** CSV o JSON.

## Configuración de Redes y Estaciones

El script utiliza las redes oficiales analizadas por el INECC y la CAMe:
| Estado  |Red SINAICA | Estaciones Incluidas|
| ---     | --- | --- |
|Puebla   |Puebla |Atlixco*, Las Ninfas, Tehuacán, San Martín Texmelucan*, Universidad Tecnológica de Puebla (UTP) |
|Tlaxcala |Tlaxcala |Palacio de Gobierno, Apizaco |
|Hidalgo  |Pachuca |Instituto Tecnológico de Pachuca, Pachuca |


* __Estaciones identificadas como aptas para el monitoreo rural de ozono.__
## Requisitos Previos
1. R instalado con el paquete rsinaica:
2. Python 3.x con las siguientes librerías:
    - pandas
    - python-dateutil
## Estructura del Código
1. Definición de Parámetros y Tiempo
El script inicia su ejecución desde el 1 de abril de 2025. Es importante notar que, según los diagnósticos técnicos, la disponibilidad de datos en tiempo real depende de la operatividad de los equipos automáticos, los cuales presentaban una operatividad del 90% en revisiones previas.

2. Función de Extracción (`download_data_r`)
Utiliza subprocess para ejecutar un script efímero de R que filtra la tabla stations_sinaica por nombre de red y estación, asegurando que se obtengan los identificadores únicos correctos antes de invocar sinaica_station_data en modo "Crude".
3. Procesamiento y Consolidación (process_and_save)
Realiza la limpieza de datos y la agrupación diaria. Esta actividad es crítica, ya que el PROAIRE subraya que las concentraciones de partículas suelen ser los contaminantes que mayormente superan los límites normados en la Región Centro.
Ejecución
Para ejecutar el script, asegúrese de que el ejecutable de R (Rscript) esté en el PATH de su sistema:
```python baja_CAMe.py```
## Beneficios para la Gestión Atmosférica
Este script apoya directamente la Medida No. 35 del PROAIRE, la cual busca "Elaborar e implementar un sistema de inventarios de emisiones y monitoreo" que sea oportuno y confiable para la toma de decisiones en la Megalópolis. Además, facilita el suministro de datos para la Plataforma de Modelación de Calidad del Aire de la región.

---
_Nota: La precisión de los resultados está sujeta a la validación posterior de los datos por parte de las autoridades ambientales locales, según los protocolos de validación y publicación de datos del INECC._