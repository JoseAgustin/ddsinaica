# Release Notes — ddsinaica

Historial de cambios del pipeline de evaluación WRF-Chem vs SINAICA.
Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.0.0/)
y versionado semántico [SemVer](https://semver.org/lang/es/).

---

## [v2.4.0] — 2026-03-15

### Resumen ejecutivo

Incorporación de dióxido de azufre (SO₂) como cuarto contaminante evaluado
en el pipeline. El cambio involucra 20 puntos del script distribuidos en todas
las secciones que referencian la lista de contaminantes: configuración global,
catálogo de estaciones, extracción del wrfout, combinación obs+modelo, cálculo
de métricas y generación del HTML.

---

### Added

- **SO₂ como cuarto contaminante** (`evaluacion_diaria.sh`, todas las secciones).

  **Sección 1 — Configuración global:**
  - `CONTAMINANTES_MODELO`: se añade `"SO2"`.
  - `UMBRAL[SO2]=130`: umbral dicotómico de 130 ppbv en promedio de 24 h,
    equivalente a 0.13 ppm según la **NOM-022-SSA1-2010**. Se añadió el
    comentario normativo junto a O3, PM10 y PM2.5.

  **Sección 5 — `conf/estaciones.conf`:**
  - Se actualiza el comentario `CONT_SINAICA` para incluir `SO2`.
  - Se añaden 5 registros SO2 en la sección Tula (uno por estación: IDs 442,
    87, 502, 82, 83), llevando el total del catálogo de 114 a **119 registros**.
    Tula es la ciudad del dominio con fuentes primarias de SO₂ (refinería
    Pemex + termoeléctrica CFE); para las demás ciudades SINAICA devolverá
    array vacío si la estación no mide SO₂, sin generar error en el pipeline.

  **Sección 8 — `extract_dia.py`:**
  - Se crea el diccionario `VARS_GAS` para variables de gas traza en ppmv
    que requieren conversión ×1000 a ppbv (análogo a `VARS_PM` para partículas):
    ```python
    VARS_GAS = {"SO2": ["so2", "SO2", "so2_a"]}
    ```
    Los nombres alternativos cubren las convenciones de nomenclatura de las
    versiones CB05 (`so2`), SAPRC99 (`SO2`) y mecanismos con aerosol (`so2_a`)
    de WRF-Chem.
  - Se añade un bucle de extracción para `VARS_GAS` entre el bloque de O3 y
    el de PM, usando `isel(bottom_top=0) * 1000.0` igual que `extraer_o3()`.
  - `"SO2"` se añade a `cont_key` y al print de resumen por ciudad.

  **Sección 9 — `combinar_dia.py`:**
  - `CONT_OBS_LABEL["SO2"] = "SO2"`: nombre del contaminante en el consolidado.
  - `FACTOR_CONV["SO2"] = 1000.0`: conversión ppmv → ppbv, igual que O3.
    Se añade comentario explícito sobre qué contaminantes requieren conversión.
  - `"SO2"` añadido al bucle `for cont in [...]`.

  **Sección 10 — `stats_dia.py`:**
  - `UMBRAL["SO2"]` expandido a partir de `${UMBRAL[SO2]}`.
  - `"SO2"` añadido al bucle `for cont in [...]`.

  **Sección 11 — `generar_html.py`:**
  - `CLB["SO2"] = "SO₂ (ppbv)"`: etiqueta de pestaña y unidades.
  - `UMBRAL["SO2"]` expandido.
  - `"SO2"` añadido al bucle `for i, cont in enumerate([...])` — genera
    una cuarta pestaña en la página de resultados.
  - KPI "Contaminantes" actualizado de **3** a **4**.
  - Descripción narrativa de la página HTML: "tres contaminantes" → **"cuatro
    contaminantes"**; se añade bullet con descripción sanitaria, fuentes de
    emisión y norma del SO₂, con mención explícita a la zona de Tula de
    Allende como fuente primaria en el dominio de evaluación.
  - Texto introductorio actualizado para incluir **Tula de Allende** en la
    lista de zonas metropolitanas evaluadas.

---

### Technical notes

#### Variables SO₂ en WRF-Chem

El nombre de la variable en el netCDF del wrfout depende del mecanismo
fotoquímico configurado en el run de WRF-Chem:

| Mecanismo | Nombre de variable |
|-----------|-------------------|
| CB05, CB6 | `so2` (minúsculas) |
| SAPRC99, SAPRC07 | `SO2` (mayúsculas) |
| CB05 + aerosol | `so2_a` |

`var_disponible()` itera la lista `["so2", "SO2", "so2_a"]` y devuelve el
primer nombre encontrado en el dataset. Si ninguno está presente, el valor
se registra como `NaN` y se imprime una advertencia `[EXTRACT]`.

#### Conversión de unidades SO₂ observado

SINAICA reporta SO₂ en ppmv (igual que O3). El campo `FACTOR_CONV["SO2"]
= 1000.0` convierte el máximo diario del consolidado a ppbv antes de
combinarlo con el valor extraído del modelo, que también está en ppbv tras
aplicar `* 1000.0` en `extract_dia.py`.

#### Umbral normativo SO₂

La NOM-022-SSA1-2010 establece un límite de 0.13 ppm en promedio de 24 h
para protección de la salud. El equivalente en ppbv es:
`0.13 ppm × 1000 = 130 ppbv`. Este es el valor usado para las métricas
dicotómicas (POD, FAR, CSI, TSS, PC).

---

## [v2.3.0] — 2026-03-15

### Resumen ejecutivo

Ampliación del dominio de evaluación con una nueva ciudad (**Tula de Allende**)
y una estación adicional en Pachuca. La nueva ciudad requirió actualizar de forma
coordinada ocho puntos del script: las listas de ciudades en Bash y en los cuatro
scripts Python generados en tiempo de ejecución, el catálogo de estaciones, el
mapa de prefijos de consolidado y la sección descriptiva de la página HTML.

---

### Added

- **Nueva ciudad: Tula** (`evaluacion_diaria.sh`, Secciones 1, 5, 8, 9, 10 y 11).
  Se incorpora la zona metropolitana de Tula de Allende / Tepeji del Río al
  dominio de evaluación. Cambios realizados en todos los puntos del script donde
  se enumera la lista de ciudades:

  | Sección | Elemento modificado | Detalle |
  |---------|-------------------|---------|
  | 1 — Config | `CIUDADES_WRF` | Bounding box `19.8920–20.1825 N`, `99.4447–99.0890 W` |
  | 1 — Config | `CIUDAD_OBS_MAP` | `[Tula]="Tula"` |
  | 5 — Descarga | `conf/estaciones.conf` | Nueva sección con 5 estaciones verificadas |
  | 8 — Extracción | `CIUDADES` en `extract_dia.py` | Bbox para extracción del wrfout |
  | 9 — Combinación | `CIUDADES` + `CIUDAD_OBS` en `combinar_dia.py` | Lista y dict de mapeo |
  | 10 — Métricas | `CIUDADES` en `stats_dia.py` | Lista para cálculo de estadísticos |
  | 11 — HTML | `CIUDADES` + `ICONOS` en `generar_html.py` | Lista y emoji 🏭 (indicativo industrial) |

  Estaciones de la red Tula incluidas en `conf/estaciones.conf`
  (IDs verificados en el portal SINAICA):

  | ID | Red | Estación | Contaminantes |
  |----|-----|----------|--------------|
  | 442 | Tula | Universidad Tecnológica de Tula Tepeji | O3, PM10, PM2.5 |
  | 87 | Tepeji | Primaria Melchor Ocampo | O3, PM10, PM2.5 |
  | 502 | Tula | Primaria Venustiano Carranza | O3, PM10, PM2.5 |
  | 82 | Atitalaquia | Centro de Salud | O3, PM10, PM2.5 |
  | 83 | Atotonilco | Primaria Revolución | O3, PM10, PM2.5 |

  Total: 15 registros en el catálogo (5 estaciones × 3 contaminantes).

- **Nueva estación en Pachuca: Mineral de la Reforma** (ID=495).
  Se agrega la estación de la red Mineral de la Reforma al catálogo de
  estaciones de Pachuca, que pasa de 4 a 7 registros:

  | ID | Red | Estación | Contaminantes |
  |----|-----|----------|--------------|
  | 495 | Mineral de la Reforma | Mineral de la Reforma | O3, PM10, PM2.5 |

  El catálogo completo de Pachuca queda con 3 estaciones y 7 registros
  (Primaria Ignacio Zaragoza solo para O3, Instituto Tecnológico de Pachuca
  e Mineral de la Reforma para O3 + PM10 + PM2.5).

---

### Technical notes

#### Resumen del catálogo de estaciones tras v2.3.0

| Ciudad | Estaciones | Registros |
|--------|:----------:|:---------:|
| CDMX / Valle de México | 27 | 54 |
| Toluca | 5 | 15 |
| Puebla | 5 | 15 |
| **Tula** | **5** | **15** |
| Pachuca | **3** | **7** |
| Tlaxcala | 1 | 3 |
| Cuernavaca | 1 | 3 |
| San Juan del Río | 1 | 2 |
| **Total** | **48** | **114** |

#### Icono de Tula (🏭)

El emoji 🏭 se eligió para la ciudad de Tula por su relevancia como zona
industrial con presencia de la refinería Miguel Hidalgo (Pemex) y la central
termoeléctrica Francisco Pérez Ríos (CFE), que son fuentes de emisión
primarias de SO₂, NOₓ y partículas en la región. La zona es de interés
prioritario en estudios de calidad del aire del centro de México por la
magnitud y continuidad de sus emisiones industriales.

#### Cobertura de la bounding box de Tula

El rectángulo `19.8920–20.1825 N / 99.4447–99.0890 W` cubre los municipios
de Tula de Allende, Tepeji del Río, Atitalaquia y Atotonilco de Tula, donde
se ubican las cinco estaciones de la red de monitoreo. Esta área es adyacente
al dominio de CDMX pero suficientemente separada para tratarse como ciudad
independiente en el pipeline de extracción del wrfout.

---

## [v2.2.0] — 2026-03-15

### Resumen ejecutivo

Corrección del mapeo de nombres de ciudad entre el orquestador y los archivos
consolidados de observaciones, más sustitución completa de la plantilla de
`conf/estaciones.conf` por el catálogo real de estaciones verificadas en el
portal SINAICA en marzo de 2026. Ambos cambios eran necesarios para que la
combinación obs + modelo produjera resultados válidos en todas las ciudades.

---

### Added

- **Catálogo completo de 96 estaciones verificadas en `conf/estaciones.conf`**
  (plantilla embebida en `evaluacion_diaria.sh`, Sección 5).
  Se reemplazaron las 16 entradas de ejemplo (varias con ID de marcador `999`)
  por el catálogo verificado en el portal SINAICA en marzo de 2026.
  El catálogo cubre las siete ciudades del dominio:

  | Ciudad | Estaciones | Registros en catálogo |
  |--------|:----------:|:---------------------:|
  | CDMX / Valle de México | 27 | 54 |
  | Toluca | 5 | 15 |
  | Puebla | 5 | 15 |
  | Tlaxcala | 1 | 3 |
  | Pachuca | 2 | 4 |
  | Cuernavaca | 1 | 3 |
  | San Juan del Río | 1 | 2 |
  | **Total** | **42** | **96** |

  Notas del catálogo:
  - La estación **Primaria Ignacio Zaragoza** (Pachuca, ID=501) se conserva
    solo para O3 ya que no reporta PM en el portal.
  - La estación **San Juan del Río** (ID=410) no reporta PM10; se incluyen
    únicamente O3 y PM2.5.
  - Las estaciones sin PM2.5 disponible en SINAICA (La Presa, Los Laureles,
    Tlahuac, Tultitlán, Cuajimalpa, Atizapán, FES Acatlán, entre otras) se
    registran solo con los contaminantes activos.
  - Se eliminaron todas las entradas con ID=999 (marcadores de plantilla)
    que generaban advertencias `[WARN]` en cada ejecución sin producir
    datos descargados.
  - Durante la incorporación del catálogo se detectaron y corrigieron
    6 irregularidades de formato en el documento fuente (separadores de
    espacio en lugar de tabulador, campo de contaminante fusionado con el
    nombre de ciudad, valor `San Juan del Rio` en la columna `CIUDAD_WRF`
    que debía ser `SJdelRio`). El catálogo embebido en el script usa
    tabuladores estrictos en todas las columnas.

---

### Fixed

- **`declare -A CIUDAD_OBS_MAP` — prefijos erróneos impedían encontrar los
  consolidados de observaciones para CDMX y San Juan del Río**
  (`evaluacion_diaria.sh`, Sección 1).

  `combinar_dia.py` construye la ruta del archivo consolidado como:
  ```
  <DIR_OBS>/<CIUDAD_OBS_MAP[ciudad]>_<Contaminante>_consolidado.csv
  ```
  Dos entradas del mapa usaban nombres heredados del paquete R `rsinaica`
  que no coincidían con los prefijos que genera `calidad_aire_pipeline.sh`
  a partir de la columna `CIUDAD_WRF` del catálogo de estaciones:

  | Clave | Valor anterior | Valor corregido | Causa del error |
  |-------|---------------|-----------------|-----------------|
  | `[CDMX]` | `"Valle_de_Mexico"` | `"CDMX"` | `rsinaica` llamaba "Valle de México" a la red; el nuevo pipeline usa la clave interna `CDMX` |
  | `[SJdelRio]` | `"San_Juan_del_Rio"` | `"San_Juan_del_Rio"` | Sin cambio — valor ya correcto |

  Con `[CDMX]="Valle_de_Mexico"`, `glob()` no encontraba el archivo
  `CDMX_O3_consolidado.csv` y devolvía lista vacía, dejando `max_obs = NaN`
  para CDMX en todos los contaminantes. Como CDMX es la primera ciudad en
  el bucle y el error era silencioso, el efecto se propagaba aparentemente
  al resto de las ciudades en los logs resumidos.

---

### Technical notes

#### Por qué `CIUDAD_WRF` define el prefijo del consolidado

`calidad_aire_pipeline.sh` toma el valor de la segunda columna del catálogo
de estaciones (`CIUDAD_WRF`) como prefijo del archivo consolidado de salida:

```
observado/<CIUDAD_WRF>_<Contaminante>_consolidado.csv
```

Por tanto `CIUDAD_OBS_MAP` debe mapear exactamente al valor de `CIUDAD_WRF`
usado en `conf/estaciones.conf`. El nombre de la red en SINAICA (columna 4,
ej. "Valle de México") es solo informativo y no afecta los nombres de
archivo.

#### Compatibilidad con consolidados históricos generados con `rsinaica`

Los archivos generados con `baja_CAMe.py` / `rsinaica` pueden tener el
prefijo `Valle_de_Mexico_` en lugar de `CDMX_`. Para migrarlos:
```bash
cd observado/
for f in Valle_de_Mexico_*; do
    mv "$f" "CDMX_${f#Valle_de_Mexico_}"
done
```
Alternativamente, mantener `[CDMX]="Valle_de_Mexico"` si se conservan los
archivos con el nombre original y no se quieren renombrar.

---

## [v2.1.0] — 2026-03-15

### Resumen ejecutivo

Versión de corrección y consolidación posterior al lanzamiento de v2.0.0.
Resuelve tres defectos detectados en producción que impedían la combinación
correcta de observaciones y modelo en `combinar_dia.py`, añade un filtro de
saneamiento de datos en la descarga de SINAICA ante respuestas con más registros
de los esperados, e incorpora una descripción técnico-sanitaria contextualizada
directamente en la página HTML de resultados.

---

### Added

- **Sección descriptiva en la página HTML de resultados**
  (`generar_html.py`, Sección 11 de `evaluacion_diaria.sh`).
  Se agregó un bloque informativo fijo inmediatamente debajo del encabezado y
  antes de los KPIs numéricos. El contenido se genera dinámicamente a partir
  de las variables del script (`{flt}`, `{UMBRAL['o3']}`, `{VENTANA}`, etc.)
  y comprende:
  - Descripción del propósito de la página, el modelo WRF-Chem, las siete
    ciudades del dominio y la fuente de observaciones (SINAICA/INECC).
  - Caracterización sanitaria y normativa de cada contaminante (O₃, PM10,
    PM2.5): mecanismo de formación o emisión, vías de ingreso al organismo,
    efectos en salud documentados y umbral normativo de referencia
    (NOM-020-SSA1, NOM-025-SSA1-2021).
  - Explicación de los tres horizontes de pronóstico (+24 h, +48 h, +72 h)
    con los mismos chips de color que aparecen en las tablas de resultados.
  - Guía de lectura del semáforo de métricas (verde/ámbar/rojo) con los
    criterios de BIAS y R reproducidos en línea.

  Los umbrales y la ventana estadística son dinámicos: si se modifican en la
  Sección 1 del script, la descripción de la página los refleja
  automáticamente sin edición adicional. La sección usa exclusivamente estilos
  en línea (`style=`), sin clases nuevas en `estilo.css`, por lo que las
  páginas ya publicadas en fechas anteriores no se ven afectadas.

- **Filtro anti-desbordamiento en `sinaica_descarga.sh`**
  (bloque Python interno, opción `-c`).
  El endpoint `POST /pags/datGrafs.php` devuelve en ocasiones más de 24
  registros al solicitar `rango=1dia`, incluyendo datos del día anterior de
  forma no solicitada (bug conocido del servidor SINAICA). Cuando el JSON
  descargado supera las 24 filas, el script ahora conserva únicamente las
  que corresponden a la `fecha` más reciente del lote (las últimas 24 horas),
  descartando el remanente antes de escribir el CSV. El encabezado se
  preserva siempre. El recorte se registra en stderr con la etiqueta
  `[TRIM]`:
  ```
  [TRIM] 48 registros recibidos → conservando 24
         (fecha=2026-03-05, descartados 24 del día anterior)
  ```
  El filtro es inerte cuando el JSON tiene ≤ 24 filas (caso normal sin
  desbordamiento).

---

### Fixed

- **`combinar_dia.py` — la combinación obs + modelo producía `NaN` para
  todas las ciudades y contaminantes** (`evaluacion_diaria.sh`, Sección 9).
  Se identificaron y corrigieron tres defectos independientes que actuaban
  en cascada:

  1. **Parseo de fecha en formato `YYYYMMDD` (sin guiones)**.
     El consolidado generado por `calidad_aire_pipeline.sh` almacena las
     fechas sin separadores (`20260301`). `pd.to_datetime()` sin argumento
     `format=` interpretaba estos valores como enteros, produciendo fechas
     incorrectas (o errores silenciosos) que hacían que el filtro por
     `FECHA_EVAL` devolviera siempre un DataFrame vacío. Se introdujo la
     función `leer_consolidado()` que lee la columna de fecha como
     `dtype=str` y aplica el formato explícito correcto antes de parsear.

  2. **Conversión de unidades de O₃ (ppmv → ppbv)**.
     Los archivos consolidados almacenan O₃ en ppmv (valores del orden de
     `0.000413`), mientras que el modelo entrega ppbv (`71.09`). El factor
     de conversión `FACTOR_CONV["o3"] = 1000.0` estaba definido pero no se
     aplicaba porque el filtro de fecha (bug 1) fallaba antes de llegar a
     esa línea. Con el parseo corregido, la multiplicación × 1000 ahora se
     ejecuta en todos los casos.

  3. **Comparación de fechas con `dt.strftime()` sustituida por
     `dt.normalize()`**.
     La comparación de cadenas `df[col_f].dt.strftime("%Y-%m-%d") == FECHA_EVAL`
     es frágil ante microsegundos o zonas horarias residuales en el índice
     datetime. Se reemplazó por
     `df["date"].dt.normalize() == pd.Timestamp(FECHA_EVAL)`, que opera
     sobre objetos `datetime64` truncados a día y es robusto en cualquier
     contexto.

- **`combinar_dia.py` — consolidado de CDMX no se filtraba correctamente
  por el historial desde 1997** (`evaluacion_diaria.sh`, Sección 9).
  El archivo `CDMX_O3_consolidado.csv` contiene 26 271 líneas con fechas
  desde el 1 de enero de 1997, consecuencia de un bug del sitio SINAICA que
  devuelve el histórico completo para algunas redes. La función
  `leer_consolidado()` introducida en la corrección anterior usaba
  `format="mixed"`, que obliga a pandas a inferir el formato fila a fila
  resultando hasta 10× más lento sobre archivos grandes, con riesgo de
  interrupción por timeout en el entorno crontab.
  Se añadió la función `detectar_formato_fecha()` que inspecciona los
  primeros 10 valores no nulos de la columna y determina el formato una sola
  vez, permitiendo el parseo vectorizado:

  | Muestra detectada | Formato asignado | Velocidad relativa |
  |-------------------|-----------------|-------------------|
  | `19970101` (8 dígitos sin guiones) | `%Y%m%d` | ~10× más rápido |
  | `2026-03-05` (ISO con guiones) | `%Y-%m-%d` | ~10× más rápido |
  | Otro patrón | `mixed` (fallback) | línea base |

  Con `format="%Y%m%d"` explícito, las 26 k filas del histórico de CDMX se
  convierten en un único paso vectorizado y el filtro por `FECHA_EVAL`
  localiza correctamente los registros recientes al final del archivo.

---

### Technical notes

#### Interacción en cascada de los tres bugs de `combinar_dia.py`

Los tres defectos corregidos actuaban en cascada: el fallo de parseo de
fecha (bug 1) hacía que `dia.empty` fuese siempre `True`, con lo que
`max_obs` quedaba como `NaN` para todas las ciudades. Esto enmascaraba los
bugs 2 y 3, que nunca llegaban a ejecutarse. La combinación resultante
contenía únicamente valores `NaN`, lo que aguas abajo producía métricas
vacías y una página HTML sin datos numéricos, sin generar ningún error
explícito en el log.

#### Criterio del umbral de recorte en `sinaica_descarga.sh`

El umbral de 24 registros para activar `[TRIM]` se eligió porque
`rango=1dia` debe devolver exactamente 24 observaciones horarias (horas
0–23). Cualquier valor superior indica inequívocamente que el servidor
incluyó al menos un día adicional. Cuando hay huecos en las mediciones
(menos de 24 horas reportadas para la fecha solicitada), el filtro es
inerte y el CSV conserva todas las filas disponibles sin pérdida de
información.

---

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

---


*Mantenido por el equipo del Pipeline WRF-Chem / Red de Calidad del Aire — Centro de México.*
