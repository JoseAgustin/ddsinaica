# Release Notes — ddsinaica

Historial de cambios del pipeline de evaluación WRF-Chem vs SINAICA.
Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.0.0/)
y versionado semántico [SemVer](https://semver.org/lang/es/).

---

## [v2.0.0] — 2026-03-15

### Resumen ejecutivo

Esta versión representa una refactorización arquitectónica mayor del orquestador
`evaluacion_diaria.sh`. El cambio central es la **eliminación completa de la
dependencia de R y el paquete `rsinaica`**, reemplazándola por descarga HTTP
directa a través de `sinaica_descarga.sh`. Adicionalmente se introduce soporte
para argumentos opcionales de fecha (modo reproceso), reintentos automáticos en
descarga, validación de archivos descargados y un catálogo de estaciones
configurable de forma declarativa.

---

### Added

- **`conf/estaciones.conf`**: catálogo TSV de estaciones SINAICA. Define la
  correspondencia entre ID numérico de estación, ciudad del dominio WRF-Chem y
  código de contaminante. El script genera una plantilla la primera vez que se
  ejecuta si el archivo no existe.

- **Modo reproceso por argumento posicional**: el script acepta opcionalmente
  una fecha en formato `YYYY-MM-DD` como primer argumento.
  ```bash
  bash evaluacion_diaria.sh 2026-02-15
  ```
  En modo reproceso, los CSV de SINAICA ya descargados se reutilizan si son
  válidos, evitando peticiones HTTP innecesarias al servidor.

- **Función `descargar_estacion()`**: encapsula la invocación de
  `sinaica_descarga.sh` con reintentos automáticos configurables mediante
  `DESCARGA_REINTENTOS` y `DESCARGA_PAUSA`.

- **Función `validar_csv()`**: verifica que el CSV descargado tenga al menos
  `REGISTROS_MINIMOS` (18 por defecto) filas de datos antes de considerarlo
  válido. Los archivos insuficientes se marcan como fallidos y se conservan
  para diagnóstico.

- **Normalización de CSV** (Sección 6): capa de transformación que convierte
  los campos del API actual de SINAICA (`fecha`, `hora`, `valor`, `val`,
  `bandO`) al formato de primera columna que requiere el filtro `awk` de
  `calidad_aire_pipeline.sh`.

- **Variables de entorno de configuración**: `EVALUACION_DIR`, `WRF_DIR`,
  `PYTHON_BIN` y `SINAICA_TIPO` permiten parametrizar el script desde el
  entorno del crontab sin modificar el código.

- **Contador de duración de ejecución**: el resumen final registra el tiempo
  total transcurrido en formato `Xm Ys`.

- **Función `step()`**: imprime encabezados de etapa con timestamp y color que
  facilitan la navegación visual del log.

- **`requirements.txt`**: lista de dependencias Python con versiones mínimas
  para reproducibilidad del entorno.

---

### Changed

- **`evaluacion_diaria.sh` — Sección 5 (descarga de observaciones)**:
  la lógica anterior generaba un script Python temporal (`baja_dia.py`) que
  parcheaba dinámicamente el código fuente de `baja_CAMe.py` mediante
  expresiones regulares (`re.sub`) para modificar `FECHA_INICIO` y `FECHA_FIN`,
  y luego ejecutaba el resultado con `exec()`. Esta aproximación era frágil,
  dependiente de la estructura interna de `baja_CAMe.py` y requería R instalado
  en el sistema. La nueva implementación invoca directamente `sinaica_descarga.sh`
  por cada fila de `conf/estaciones.conf`, sin dependencias de R.

- **`combinar_dia.py` (Sección 9)**: ahora detecta automáticamente el nombre de
  la columna de fecha en el CSV consolidado. Acepta tanto `date` (formato generado
  por `baja_CAMe.py` vía `rsinaica`) como `fecha` (formato del API HTTP actual
  usado por `sinaica_descarga.sh`), garantizando compatibilidad retroactiva con
  consolidados históricos.

- **Rutas portables**: `DIR_PROYECTO` ya no requiere configuración manual si
  la variable de entorno `EVALUACION_DIR` no está definida; se resuelve
  automáticamente al directorio que contiene el script mediante
  `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)`.

- **Inicio de log mejorado**: el encabezado del log ahora incluye versión del
  script, modo de ejecución (AUTOMÁTICO / REPROCESO), versión de Python y
  timestamp de inicio.

- **Formato de mensajes de log**: se unifica la función `_log()` como base de
  todas las variantes (`info`, `ok`, `warn`, `error`, `step`), garantizando
  que todas escriban tanto a stdout como al archivo de log de forma consistente.

- **`extract_dia.py` (Sección 8)**: se refactorizaron las funciones de
  extracción `extraer_o3()` y `extraer_pm()` como funciones independientes con
  anotaciones de tipo, mejorando la legibilidad y testabilidad. Se unificó el
  punto de entrada con validación de argumentos explícita.

---

### Removed

- **Dependencia de R y `rsinaica`**: el script ya no invoca `Rscript` ni
  requiere que R esté instalado en el servidor operativo. `baja_CAMe.py`
  permanece en el repositorio como herramienta auxiliar para procesamiento
  histórico mensual, pero queda excluido del flujo automático diario.

- **Script temporal `baja_dia.py`**: eliminado el patrón de generar y ejecutar
  un script Python que parcheaba el código fuente de otro script en tiempo de
  ejecución. Este antipatrón era difícil de depurar y propenso a fallos silenciosos
  cuando cambiaba la estructura interna de `baja_CAMe.py`.

- **Variable `RSCRIPT`** de la Sección 1: ya no es necesaria.

- **Verificación `require_cmd "${RSCRIPT}"`**: eliminada de las comprobaciones
  de dependencias del sistema.

---

### Fixed

- **Compatibilidad de nombres de campo SINAICA**: los CSV generados por
  `sinaica_descarga.sh` usan los nombres del API actual (`fecha`, `hora`,
  `valor`), mientras que los consolidados históricos generados con `baja_CAMe.py`
  usaban los nombres del paquete R (`date`, `hour`, `value`). `combinar_dia.py`
  ahora maneja ambas convenciones sin requerir migración de archivos históricos.

- **Cálculo de duración total**: la versión anterior calculaba la duración
  incorrectamente intentando convertir `FECHA_EVAL` a epoch seconds en lugar
  de registrar el timestamp real de inicio del script. Se corrigió usando
  `TS_INICIO=$(date +%s)` al principio de la ejecución.

- **Limpieza de temporales más robusta**: se reemplazó el patrón
  `rm -f "${DIR_TMP}"/*.py` (que falla silenciosamente si no hay coincidencias
  con algunos shells) por `find "${DIR_TMP}" -maxdepth 1 -name "*.py" -delete`,
  que es portable y explícito.

- **Manejo de campos vacíos en `estaciones.conf`**: el bucle `while read` ahora
  usa `|| [[ -n "${est_id:-}" ]]` para procesar correctamente la última línea
  del archivo si no termina en salto de línea.

---

### Technical notes

#### Compatibilidad de campos del API SINAICA (2026)

El endpoint `POST https://sinaica.inecc.gob.mx/pags/datGrafs.php` devuelve
actualmente un JSON embebido en HTML con la siguiente estructura:

```json
{"id":"249O326022400","fecha":"2026-02-24","hora":0,"valor":0.009,"bandO":"","val":1}
```

Los nombres de campo difieren de los que documentaba `rsinaica` en su versión
original (`date`, `hour`, `value`, `valid`). La capa de normalización de la
Sección 6 construye el identificador de fila en el formato que espera el filtro
`awk` de `calidad_aire_pipeline.sh`:

```
<estacion_id><CONT_SINAICA><YYYYMMDD><HH>
```

Ejemplos: `249O32026022400` (filtra `id ~ /O3/`),  
`250PM102026022400` (filtra `id ~ /PM10/ && id !~ /PM2\.5/`),  
`251PM2.52026022400` (filtra `id ~ /PM2\.5/`).

#### Ventanas temporales de pronóstico

Los índices del eje `Time` del wrfout se asignan a hora local (UTC − 6) mediante
índices fijos, sin conversión de objetos datetime:

| Índice 0 | Equivale a | Día local |
|----------|-----------|-----------|
| 0 | 00:00 UTC = 18:00 local (día anterior) | — |
| 6 | 06:00 UTC = 00:00 local | inicio Día 0 |
| 30 | 06:00 UTC+1 = 00:00 local | inicio Día 1 |
| 54 | 06:00 UTC+2 = 00:00 local | inicio Día 2 |

El Día 2 tiene solo 18 horas (índices 54–71) porque el wrfout termina en la
hora 71 (18:00 UTC del tercer día del run, = 12:00 local).

#### Estación Primaria Ignacio Zaragoza (Pachuca)

Esta estación no estaba en el catálogo oficial de `rsinaica` y requería ser
agregada manualmente con `station_id = 501`. Con el nuevo esquema basado en
`conf/estaciones.conf`, el ID se configura directamente en el catálogo sin
necesidad de parches en el código. **Verificar el ID real en el portal SINAICA
antes de usar en producción.**

---

## [v1.0.0] — 2026-01-15

### Resumen

Versión inicial del pipeline operativo diario. Implementa el flujo completo
de evaluación usando `baja_CAMe.py` (R/rsinaica) para la descarga de
observaciones y genera reportes HTML diarios.

### Added

- `evaluacion_diaria.sh` v1: orquestador con 8 etapas, generación dinámica de
  scripts Python temporales para extracción, combinación, estadísticos y HTML.
- `baja_CAMe.py`: descarga masiva multi-red usando el paquete R `rsinaica`.
- `calidad_aire_pipeline.sh`: separación por contaminante y consolidación por
  ciudad en dos etapas.
- `sinaica_descarga.sh` v2.0: descarga HTTP directa por estación individual.
- `01_extrae.py`: pipeline histórico mensual con Bootstrap (B=10,000) y
  reportes Word.
- Sitio web estático con índice histórico y páginas HTML por día.

---

*Mantenido por el equipo del Pipeline WRF-Chem / Red de Calidad del Aire — Centro de México.*
