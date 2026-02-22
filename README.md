# 🌬️ Sistema de Descarga de Datos de Calidad del Aire — SINAICA

Herramienta Python para la descarga automatizada de datos horarios de calidad del aire desde el portal [SINAICA](https://sinaica.inecc.gob.mx) del INECC, integrando el paquete R [`rsinaica`](https://github.com/diegovalle/rsinaica).

---

## 📋 Tabla de Contenidos

- [Descripción General](#descripción-general)
- [Arquitectura del Sistema](#arquitectura-del-sistema)
- [Requisitos](#requisitos)
- [Instalación](#instalación)
- [Configuración](#configuración)
- [Uso](#uso)
- [Descripción de Funciones](#descripción-de-funciones)
- [Flujo de Ejecución](#flujo-de-ejecución)
- [Estructura de Archivos de Salida](#estructura-de-archivos-de-salida)
- [Correcciones Aplicadas](#correcciones-aplicadas)
- [Notas Técnicas](#notas-técnicas)
- [Fuentes de Datos](#fuentes-de-datos)

---

## Descripción General

Este script automatiza la consulta y descarga de datos de calidad del aire para **5 redes de monitoreo** del Sistema Nacional de Información de la Calidad del Aire (SINAICA), cubriendo **15 estaciones** en los estados de México, Puebla, Tlaxcala, Hidalgo y Morelos.

La descarga se realiza **mes a mes** para respetar el límite de rango por consulta de la API interna del portal. Cada petición mensual se ejecuta a través de un script R temporal que invoca `sinaica_station_data()` del paquete `rsinaica`; el resultado se persiste como CSV temporal, se carga a Python para su procesamiento y el archivo temporal se elimina.

```
Python (orquestación)
       │
       ▼
 temp_script.R  ──►  Rscript  ──►  SINAICA / INECC
                         │
                         ▼
                   temp_data.csv
                         │
                         ▼
               pandas (procesamiento)
                         │
                         ▼
        calidad_aire_<Red>_<Estacion>.csv / .json
```

---

## Arquitectura del Sistema

```
sinaica_descarga_redes.py
│
├── CONFIGURACION_REDES        ← Catálogo de redes y estaciones
├── PARAMETROS                 ← Contaminantes a descargar
├── FECHA_INICIO / FECHA_FIN   ← Ventana temporal de consulta
│
├── download_data_r()
│   ├── Genera  → temp_script.R   (solo código R, nunca Python)
│   ├── Ejecuta → Rscript temp_script.R
│   ├── Lee     → temp_data.csv   (si R encontró datos)
│   └── Elimina → temp_data.csv + temp_script.R  (always/finally)
│
└── process_and_save()
    ├── Itera: redes → estaciones → meses → parámetros
    ├── Llama download_data_r() por cada combinación
    ├── Aplica promedio diario 24 h a PM10 y PM2.5
    └── Consolida y guarda un archivo por estación
```

---

## Requisitos

### Python ≥ 3.8

| Librería | Versión mínima | Uso |
|---|---|---|
| `pandas` | ≥ 1.3 | Manipulación y consolidación de DataFrames |
| `python-dateutil` | ≥ 2.8 | Incremento mensual con `relativedelta` |
| `subprocess` | Estándar | Ejecución de `Rscript` como subproceso |
| `os` | Estándar | Gestión de archivos temporales |
| `datetime` | Estándar | Manejo de fechas del periodo de descarga |

### R

| Paquete | Uso |
|---|---|
| `rsinaica` | Acceso a la API del portal SINAICA |

> `Rscript` debe estar disponible en el `PATH` del sistema.

---

## Instalación

```bash
# 1. Clonar el repositorio
git clone https://github.com/JoseAgustin/ddsinaica.git
cd ddsinaica

# 2. Instalar dependencias Python
pip install pandas python-dateutil

# 3. Instalar el paquete R (desde consola R o RStudio)
# install.packages("rsinaica" )
```

---

## Configuración

Toda la configuración se realiza editando las **variables globales** en la cabecera del archivo.

### Redes y Estaciones

```python
CONFIGURACION_REDES = [
    {"red": "Toluca",     "estaciones": ["Toluca Centro", "Ceboruco",
                                         "Almoloya de Juárez", "Oxtotitlán", "Metepec"]},
    {"red": "Puebla",     "estaciones": ["Atlixco", "Las Ninfas", "Tehuacán",
                                         "San Martín Texmelucan",
                                         "Universidad Tecnológica de Puebla"]},
    {"red": "Tlaxcala",   "estaciones": ["Palacio de Gobierno", "Apizaco"]},
    {"red": "Pachuca",    "estaciones": ["Instituto Tecnológico de Pachuca",
                                         "Primaria Ignacio Zaragoza"]},
    {"red": "Cuernavaca", "estaciones": ["Cuernavaca 01"]}
]
```

| Red | Estaciones | Estado |
|---|---|---|
| Toluca | 5 | Estado de México |
| Puebla | 5 | Puebla |
| Tlaxcala | 2 | Tlaxcala |
| Pachuca | 2 | Hidalgo |
| Cuernavaca | 1 | Morelos |

> Los nombres deben coincidir **exactamente** con el catálogo `stations_sinaica` del paquete R.

### Parámetros Calidad del Aire

```python
PARAMETROS = ["PM10", "PM2.5", "O3"]
```

| Código | Contaminante | Resolución de salida | Unidades | Norma |
|---|---|---|---|---|
| `PM10` | Partículas ≤ 10 µm | Promedio diario 24 h | µg/m³ | NOM-025-SSA1-2021 |
| `PM2.5` | Partículas ≤ 2.5 µm | Promedio diario 24 h | µg/m³ | NOM-025-SSA1-2021 |
| `O3` | Ozono | Horaria | ppm | NOM-020-SSA1-2021 |

### Periodo y Formato de Salida

```python
FECHA_INICIO   = datetime(2025, 4, 1)  # Inicio fijo que se puede actualizar
FECHA_FIN      = datetime.now()         # Fin dinámico: fecha actual
FORMATO_SALIDA = "csv"                  # Alternativa: "json"
```

---

## Uso

```bash
python baja_CAMe.py
```

**Ejemplo de salida en consola:**

```
[Toluca] Consultando PM10 para Toluca Centro (2025-04-01 → 2025-05-01)...
[Toluca] Consultando PM2.5 para Toluca Centro (2025-04-01 → 2025-05-01)...
[Toluca] Consultando O3 para Toluca Centro (2025-04-01 → 2025-05-01)...

[Toluca] Consultando O3 para Toluca Centro (2026-02-01 → 2026-02-21)...
  → Archivo generado: calidad_aire_Toluca_Toluca_Centro.csv (8119 registros)

[Tlaxcala] Consultando PM2.5 para Apizaco (2026-02-01 → 2026-02-21)...
[Tlaxcala] Consultando O3 para Apizaco (2026-02-01 → 2026-02-21)...
  ⚠ Sin datos para Apizaco en la red Tlaxcala.

[Cuernavaca] Consultando PM2.5 para Cuernavaca 01 (2026-02-01 → 2026-02-21)...
[Cuernavaca] Consultando O3 para Cuernavaca 01 (2026-02-01 → 2026-02-21)...
  → Archivo generado: calidad_aire_Cuernavaca_Cuernavaca_01.csv (18170 registros)
```

---

## Descripción de Funciones

### `download_data_r()`

```python
def download_data_r(
    network_name: str,
    station_name: str,
    parameter:    str,
    start_date:   str,
    end_date:     str
) -> pd.DataFrame
```

Genera un script R, lo ejecuta como subproceso, importa el resultado a pandas y limpia todos los archivos temporales.

**Parámetros:**

| Parámetro | Tipo | Descripción |
|---|---|---|
| `network_name` | `str` | Nombre de la red — filtra `stations_sinaica` |
| `station_name` | `str` | Nombre exacto de la estación según SINAICA |
| `parameter` | `str` | Código del contaminante: `"PM10"`, `"PM2.5"`, `"O3"` |
| `start_date` | `str` | Fecha de inicio `"YYYY-MM-DD"` |
| `end_date` | `str` | Fecha de fin `"YYYY-MM-DD"` |

**Retorna:** `pd.DataFrame` con datos horarios, o `pd.DataFrame()` vacío si no hay datos o hay error.

**Archivos temporales:**

| Archivo | Creado por | Eliminado por | Garantía |
|---|---|---|---|
| `temp_script.R` | Python (`open().write()`) | Python (`os.remove()`) | Al finalizar la función |
| `temp_data.csv` | Script R (`write.csv()`) | Python (`os.remove()` en `finally`) | Siempre, aunque falle la lectura |

---

### `process_and_save()`

```python
def process_and_save() -> None
```

Función principal de orquestación. Itera sobre todas las combinaciones de red × estación × mes × parámetro, acumula los datos y genera un archivo consolidado por estación.

**Lógica de promedio diario (PM10 y PM2.5):**

```python
if param in ["PM10", "PM2.5"]:
    df_month["date"] = pd.to_datetime(df_month["date"])
    df_month = (
        df_month
        .groupby(["station_id", df_month["date"].dt.date])
        .agg({"value": "mean"})
        .reset_index()
    )
    df_month["parametro"] = param
```

---

## Flujo de Ejecución

```
process_and_save()
│
├─ Red: Toluca
│   ├─ Estación: Toluca Centro
│   │   ├─ Mes 2025-04
│   │   │   ├─ PM10  → download_data_r() → promedio 24 h → df
│   │   │   ├─ PM2.5 → download_data_r() → promedio 24 h → df
│   │   │   └─ O3    → download_data_r() → horario       → df
│   │   ├─ Mes 2025-05  (idem)
│   │   └─ ...
│   │       └─ Guardar: calidad_aire_Toluca_Toluca_Centro.csv
│   └─ Estación: Ceboruco  (idem) ...
├─ Red: Puebla     (idem) ...
├─ Red: Tlaxcala   (idem) ...
├─ Red: Pachuca    (idem) ...
└─ Red: Cuernavaca (idem) ...
```

**Estimado de peticiones** para 10 meses de periodo:

```
15 estaciones × 3 parámetros × 10 meses = 450 llamadas
Tiempo estimado de ejecución: 6 – 7 minutos (solo hay 11 estaciones con datos en el período)
```

---

## Estructura de Archivos de Salida

Un archivo por estación, en el directorio de trabajo actual.

**Convención de nombre:** `calidad_aire_<Red>_<Estacion>.<ext>`
(espacios → `_`, puntos eliminados)

```
calidad_aire_Toluca_Toluca_Centro.csv
calidad_aire_Puebla_Las_Ninfas.csv
calidad_aire_Pachuca_Primaria_Ignacio_Zaragoza.csv
```

**Columnas — O3 (datos horarios):**

| Columna | Tipo | Descripción |
|---|---|---|
| `id` | `str` | Identificador único del registro |
| `date` | `str` | Fecha `YYYY-MM-DD` |
| `hour` | `int` | Hora de la medición (0–23, hora local) |
| `value` | `float` | Valor medido |
| `valid` | `int` | Indicador de validez (1 = válido) |
| `unit` | `str` | Unidad (`ppm`, `µg/m³`) |
| `station_id` | `int` | ID numérico de la estación |
| `station_name` | `str` | Nombre de la estación |

**Columnas — PM10 / PM2.5 (promedio diario 24 h):**

| Columna | Tipo | Descripción |
|---|---|---|
| `station_id` | `int` | ID numérico de la estación |
| `date` | `date` | Fecha del promedio diario |
| `value` | `float` | Promedio de 24 horas |
| `parametro` | `str` | Código del parámetro (`PM10` o `PM2.5`) |

---

## Correcciones Aplicadas

### ✅ Bug 1 — `df_month.empty` sin verificar si es `None`

**Causa:** `download_data_r()` podía retornar `None` en ciertos casos de error. Llamar `.empty` sobre `None` lanza `AttributeError`.

```python
# ❌ ANTES — falla si df_month es None
if not df_month.empty:
```

```python
# ✅ DESPUÉS — verificación segura
if df_month is not None and not df_month.empty:
```

---

### ✅ Bug 2 — `temp_data.csv` no se eliminaba si la lectura fallaba

**Causa:** Si `pd.read_csv()` lanzaba una excepción, el `os.remove()` que venía después no se ejecutaba, dejando el archivo en disco y contaminando la siguiente iteración.

```python
# ❌ ANTES — os.remove() no se ejecuta si read_csv falla
df = pd.read_csv("temp_data.csv")
os.remove("temp_data.csv")   # ← no llega aquí si hay excepción
```

```python
# ✅ DESPUÉS — finally garantiza la eliminación siempre
try:
    df = pd.read_csv("temp_data.csv")
except Exception as exc:
    print(f"  [ERROR lectura CSV] {exc}")
finally:
    os.remove("temp_data.csv")   # siempre se ejecuta
```

---

## Notas Técnicas

### Iteración mensual
`relativedelta(months=1)` de `python-dateutil` maneja correctamente meses de distinta longitud y años bisiestos.

### Estación "Primaria Ignacio Zaragoza" (Pachuca)
No estaba en el catálogo oficial `stations_sinaica` al momento del desarrollo. Se agrega manualmente dentro del script R con `station_id = 501`.

> ⚠️ **Verificar** que `station_id = 501` corresponda al ID real en el portal SINAICA antes de ejecutar en producción.

### Tipo de datos
`"Crude"` (datos crudos, no validados) garantiza disponibilidad inmediata. Los datos `"Validated"` pueden tener rezago de semanas o meses.

### Codificación de salida
- CSV: `utf-8-sig` (UTF-8 con BOM, compatible con Excel en español)
- JSON: `force_ascii=False` (preserva caracteres especiales: tildes, ñ)

### Concurrencia
El script es **secuencial**. Para ~450 peticiones, el tiempo total puede ser de **5 a 10 minutos** dependiendo de la latencia del servidor SINAICA.

---

## Fuentes de Datos

| Recurso | URL |
|---|---|
| Portal SINAICA | https://sinaica.inecc.gob.mx |
| Paquete rsinaica (R) | https://github.com/diegovalle/rsinaica |
| Documentación rsinaica | https://hoyodesmog.diegovalle.net/rsinaica/ |
| API interna SINAICA | `POST https://sinaica.inecc.gob.mx/lib/libd/cnxn.php` |

---

> **Sobre los datos:** Los valores de tipo `"Crude"` son preliminares y no han pasado por el proceso de validación oficial del INECC. Para análisis que requieran datos definitivos, usar `"Validated"`.
