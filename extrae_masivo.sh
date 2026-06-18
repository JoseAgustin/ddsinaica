#!/bin/bash
# ==============================================================================
# extrae_masivo.sh
# ==============================================================================
# Descripción:
#   Extrae masivamente datos de pronóstico de calidad del aire desde archivos
#   HTML de evaluación diaria, filtrando únicamente las estaciones Pachuca y
#   Tula, y genera dos archivos CSV:
#
#     datos_diarios.csv   → valores diarios de obs, modelo y diferencia
#                           por horizonte de pronóstico
#     metricas_30dias.csv → métricas de evaluación de 30 días (continuas
#                           y dicotómicas) por horizonte de pronóstico
#
# Algoritmo general (Bloques / Split):
#   El documento HTML se descompone jerárquicamente en tres niveles:
#     Nivel 1 → Pestañas  (<div class="tab-pane">)  → un contaminante por pestaña
#     Nivel 2 → Tarjetas  (<div class="card">)       → una estación por tarjeta
#     Nivel 3 → Tablas    (<table class="td|tm">)    → datos y métricas por tabla
#
#   El parseo lo realiza un bloque Perl embebido que lee el HTML como cadena
#   única ("modo slurp"), fragmenta el texto con split() sobre los delimitadores
#   HTML y extrae los campos con expresiones regulares. Perl se escoge porque
#   maneja texto multilínea y Unicode de forma más robusta que AWK o sed puros.
#
# Estructura de directorios esperada:
#   web/2026/
#   ├── 04/
#   │   ├── evaluacion_2026-04-01.html
#   │   └── ...
#   ├── 05/
#   │   └── ...
#   └── 06/
#       └── ...
#
# Estructura interna de cada archivo HTML:
#   <div class="tab-pane" id="pane-o3">      ← pestaña por contaminante
#     <div class="card">                      ← tarjeta por estación
#       <div class="ch">⛏️ Pachuca</div>     ← nombre de la estación
#       <table class="td">                    ← tabla de datos diarios
#         <tr>
#           <td><span class="chip d1">+24 h</span></td>
#           <td>89.8</td>                     ← observación
#           <td>64.1</td>                     ← modelo
#           <td>-25.8</td>                    ← diferencia
#         </tr>
#         ...
#       </table>
#       <table class="tm">                    ← tabla de métricas continuas
#         <tr>
#           <td><span ...>+24 h</span></td>
#           <td>-25.9</td>                    ← BIAS
#           <td>57.1</td>                     ← RMSE
#           <td>0.24</td>                     ← R (correlación)
#         </tr>
#       </table>
#       <table class="tm">                    ← tabla de métricas dicotómicas
#         <tr>
#           <td><span ...>+24 h</span></td>
#           <td>0.000</td>                    ← POD  (Probability of Detection)
#           <td>—</td>                        ← FAR  (False Alarm Ratio)
#           <td>0.000</td>                    ← CSI  (Critical Success Index)
#         </tr>
#       </table>
#     </div>
#   </div>
#
# Formato de salida — datos_diarios.csv:
#   fecha,mes,ubicacion,contaminante,horizonte,observacion,modelo,diferencia
#   2026-04-01,04,Pachuca,O3,+24 h,89.8,64.1,-25.8
#
# Formato de salida — metricas_30dias.csv:
#   fecha,mes,ubicacion,contaminante,horizonte,bias,rmse,r,pod,far,csi
#   2026-04-01,04,Pachuca,O3,+24 h,-25.9,57.1,0.24,0.000,,0.000
#
# Notas sobre valores nulos:
#   El HTML representa datos faltantes con el carácter "—" (guión largo, U+2014)
#   dentro de un <span style="color:#aaa">. El script Perl los elimina y deja
#   el campo vacío en el CSV, lo que facilita la detección como NaN en Python/R.
#
# Etiqueta de prefijo (DIARIO / METRICAS):
#   El bloque Perl imprime todas las líneas hacia stdout con un prefijo textual
#   (DIARIO o METRICAS) para poder separarlas con grep en un único archivo
#   temporal (temp_datos.txt), evitando dos invocaciones de Perl por archivo.
#   El prefijo se elimina con sed antes de acumular en los CSV finales.
#
# Dependencias:
#   bash ≥ 4.0, perl ≥ 5.10, grep, sed, find, cut, basename
#   (todas disponibles en GNU/Linux sin instalación adicional)
#
# Uso:
#   bash extrae_masivo.sh
#
# Para cambiar rutas o nombres de salida, editar las variables de configuración
# en la sección "CONFIGURACIÓN" al inicio del script.
#
# Autor   : "Jose Agustin Garcia Reynoso" <agustin@atmosfera.unam.mx>
# Versión : 1.0
# ==============================================================================

# ==============================================================================
# CONFIGURACIÓN
# ==============================================================================

# Directorio raíz que contiene los subdirectorios de mes (04/, 05/, 06/)
DIR_BASE="web/2026"

# Archivos CSV de salida
CSV_DIARIO="datos_diarios.csv"     # Observación / modelo / diferencia por día
CSV_METRICAS="metricas_30dias.csv" # Métricas BIAS, RMSE, R, POD, FAR, CSI

# ==============================================================================
# INICIALIZACIÓN DE ARCHIVOS DE SALIDA
# ==============================================================================
# Se escriben los encabezados (sobrescribiendo cualquier versión previa).
# El operador > crea el archivo si no existe o lo trunca si ya existía,
# garantizando que cada ejecución comience desde cero.

echo "fecha,mes,ubicacion,contaminante,horizonte,observacion,modelo,diferencia" > "$CSV_DIARIO"
echo "fecha,mes,ubicacion,contaminante,horizonte,bias,rmse,r,pod,far,csi" > "$CSV_METRICAS"

# ==============================================================================
# BUCLE PRINCIPAL: recorrido de archivos HTML
# ==============================================================================
# find busca recursivamente todos los .html bajo DIR_BASE.
# sort garantiza orden cronológico (YYYY-MM-DD en el nombre lo permite).
# while read -r lee cada ruta sin interpretar barras invertidas (flag -r).

find "$DIR_BASE" -type f -name "*.html" | sort | while read -r archivo; do

    # --------------------------------------------------------------------------
    # Extracción de fecha y mes desde el nombre del archivo
    # --------------------------------------------------------------------------
    # basename elimina la ruta, quedando p.ej. "evaluacion_2026-04-01.html".
    # grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' extrae la primera subcadena que
    # coincide con el patrón ISO 8601 (YYYY-MM-DD).
    FECHA=$(basename "$archivo" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')

    # cut -d'-' -f2 toma el segundo campo delimitado por '-', obteniendo el mes
    # (p.ej. "04"). Esto evita depender de la ruta del directorio.
    MES=$(echo "$FECHA" | cut -d'-' -f2)

    # Guardia: si el nombre del archivo no contiene una fecha válida, se omite.
    [ -z "$FECHA" ] && continue

    echo "Procesando: $archivo"

    # --------------------------------------------------------------------------
    # Bloque Perl: parseo del HTML y extracción de datos
    # --------------------------------------------------------------------------
    # Se invoca perl -e '...' con los argumentos FECHA, MES y la ruta del
    # archivo. Perl recibe estos valores en @ARGV y nunca los interpola dentro
    # del string del script Bash (las comillas simples '...' lo previenen).
    # La salida de Perl se redirige a un archivo temporal (temp_datos.txt)
    # para separar DIARIO y METRICAS con grep en el paso siguiente.

    perl -e '
    use strict;  # Fuerza declaración de variables; evita errores silenciosos

    # Recibir argumentos desde Bash: fecha (YYYY-MM-DD), mes (MM) y ruta HTML
    my ($fecha, $mes, $file) = @ARGV;

    # ── Lectura completa del archivo (modo slurp) ──────────────────────────
    # undef $/ elimina el separador de registros de Perl, haciendo que <$fh>
    # lea el archivo entero de una sola vez como una cadena. Esto es necesario
    # porque las etiquetas HTML ocupan múltiples líneas y las regex con /s
    # (modo dotall) requieren todo el texto en memoria.
    undef $/;
    open(my $fh, "<", $file) or die "No se puede abrir $file: $!";
    my $html = <$fh>;
    close($fh);

    # ==========================================================================
    # NIVEL 1 — Separar por pestañas de contaminante
    # ==========================================================================
    # Cada contaminante (O3, PM10, PM25, SO2) ocupa un <div class="tab-pane">.
    # split() fragmenta $html en el delimitador literal "<div class=\"tab-pane"
    # (sin cerrar la etiqueta) para no consumir los atributos id= que siguen.
    # El primer elemento del array resultante es el encabezado HTML anterior
    # al primer pane; se descarta con shift.
    my @panes = split(/<div class="tab-pane/, $html);
    shift @panes;

    foreach my $pane (@panes) {

        # Identificar el contaminante desde el atributo id del pane.
        # El pane comienza con el resto de la etiqueta de apertura, p.ej.:
        #   " active" id="pane-o3">
        # La regex /^[^>]*id="pane-([^"]+)"/ captura el valor entre comillas
        # después de "pane-" sin cruzar el cierre de etiqueta (^[^>]*).
        # uc() convierte a mayúsculas: "o3" → "O3", "PM10" → "PM10".
        my $cont = "Desconocido";
        if ($pane =~ /^[^>]*id="pane-([^"]+)"/) {
            $cont = uc($1);
        }

        # ======================================================================
        # NIVEL 2 — Separar por tarjetas de estación
        # ======================================================================
        # Cada estación ocupa un <div class="card">. Se fragmenta el pane en
        # ese delimitador y se descarta el primer elemento (texto previo a la
        # primera tarjeta).
        my @cards = split(/<div class="card">/, $pane);
        shift @cards;

        foreach my $card (@cards) {

            # ------------------------------------------------------------------
            # Extraer nombre de la estación desde <div class="ch">
            # ------------------------------------------------------------------
            # El contenido es p.ej.: ⛏️ Pachuca  o  🏭 Tula
            # La regex captura el último texto antes de </div>: ([^<]+)
            # [^<]+ coincide con cualquier carácter que no sea < (evita cruzar
            # etiquetas internas), capturando solo el texto plano.
            my $ubi = "Desconocido";
            if ($card =~ /<div class="ch">.*?([^<]+)<\/div>/) {
                $ubi = $1;
                # Eliminar caracteres no ASCII (emojis UTF-8: ⛏️, 🏭, 🏙️, etc.)
                # [^\x00-\x7F] coincide con cualquier byte fuera del rango ASCII.
                $ubi =~ s/[^\x00-\x7F]//g;
                # Eliminar espacios al inicio y al final
                $ubi =~ s/^\s+|\s+$//g;
            }

            # Filtro de estación: procesar únicamente Pachuca y Tula.
            # La coincidencia es insensible a mayúsculas (/i) para mayor robustez.
            next unless ($ubi =~ /Pachuca|Tula/i);

            # ==================================================================
            # NIVEL 3a — Tabla de datos diarios  <table class="td">
            # ==================================================================
            # Estructura de cada fila de datos:
            #   <tr>
            #     <td><span class="chip d1">+24 h</span></td>  ← horizonte
            #     <td>89.8</td>                                  ← observación
            #     <td>64.1</td>                                  ← modelo
            #     <td>-25.8</td>                                 ← diferencia
            #   </tr>
            # Cuando un valor es nulo, el HTML usa:
            #   <td><span style="color:#aaa">—</span></td>
            #
            # /s (dotall): el punto . coincide también con saltos de línea,
            # necesario porque <tr> y </tr> pueden estar en líneas distintas.
            # /g (global): itera sobre todas las coincidencias en $td_content.

            if ($card =~ /<table class="td">(.*?)<\/table>/s) {
                my $td_content = $1;

                # Captura grupos: horizonte ($1), obs ($2), modelo ($3), dif ($4)
                # <span[^>]*> coincide con cualquier atributo del span (chip d1, d2…)
                while ($td_content =~ /<tr><td><span[^>]*>(.*?)<\/span><\/td><td>(.*?)<\/td><td>(.*?)<\/td><td>(.*?)<\/td><\/tr>/gs) {
                    my ($h, $o, $m, $d) = ($1, $2, $3, $4);

                    # Limpiar cada campo:
                    #   s/<[^>]+>// → elimina cualquier etiqueta HTML residual
                    #                 (p.ej. <span style="color:#aaa"> en nulos)
                    #   s/—//       → elimina el guión largo (U+2014) de nulos
                    #   s/^\s+|\s+$//g → elimina espacios marginales
                    $h =~ s/<[^>]+>|—//g; $o =~ s/<[^>]+>|—//g;
                    $m =~ s/<[^>]+>|—//g; $d =~ s/<[^>]+>|—//g;
                    $h =~ s/^\s+|\s+$//g; $o =~ s/^\s+|\s+$//g;
                    $m =~ s/^\s+|\s+$//g; $d =~ s/^\s+|\s+$//g;

                    # El prefijo "DIARIO," permite separar este tipo de línea
                    # del otro (METRICAS) con grep sobre el archivo temporal.
                    print "DIARIO,$fecha,$mes,$ubi,$cont,$h,$o,$m,$d\n";
                }
            }

            # ==================================================================
            # NIVEL 3b — Tablas de métricas  <table class="tm">
            # ==================================================================
            # Cada tarjeta contiene DOS tablas con class="tm":
            #   tms[0] → métricas continuas : BIAS, RMSE, R
            #   tms[1] → métricas dicotómicas: POD, FAR, CSI
            #
            # Se capturan ambas tablas en un único array @tms usando la regex
            # en contexto de lista (= (...) =~ //gs ), que devuelve todos los
            # grupos capturados en sucesivas coincidencias globales.
            my %metricas;   # Hash temporal: horizonte → {bias, rmse, r}
            my @tms = ($card =~ /<table class="tm">(.*?)<\/table>/gs);

            if (@tms >= 2) {

                # --------------------------------------------------------------
                # Tabla de métricas continuas (tms[0]): BIAS, RMSE, R
                # --------------------------------------------------------------
                # Se usa el mismo patrón de <tr> que en la tabla de datos.
                # Los valores se almacenan en %metricas indexados por horizonte
                # para poder unirlos con los de la tabla dicotómica.
                while ($tms[0] =~ /<tr><td><span[^>]*>(.*?)<\/span><\/td><td>(.*?)<\/td><td>(.*?)<\/td><td>(.*?)<\/td><\/tr>/gs) {
                    my ($h, $bias, $rmse, $r) = ($1, $2, $3, $4);
                    $h    =~ s/<[^>]+>|—//g;
                    $bias =~ s/<[^>]+>|—//g;
                    $rmse =~ s/<[^>]+>|—//g;
                    $r    =~ s/<[^>]+>|—//g;
                    $h    =~ s/^\s+|\s+$//g;   # Solo el horizonte necesita trim
                                                # para usarlo como clave del hash

                    # Guardar en hash: clave = horizonte limpio (p.ej. "+24 h")
                    $metricas{$h} = { bias => $bias, rmse => $rmse, r => $r };
                }

                # --------------------------------------------------------------
                # Tabla de métricas dicotómicas (tms[1]): POD, FAR, CSI
                # JOIN con %metricas mediante el horizonte como clave común
                # --------------------------------------------------------------
                # Se itera la tabla dicotómica; por cada horizonte se busca en
                # %metricas si ya existe la entrada continua del mismo horizonte.
                # Si existe (exists $metricas{$h}), se emite una línea METRICAS
                # con los seis campos combinados. Si no existe, la fila se omite
                # (caso raro, solo ocurre si la tabla continua está incompleta).
                while ($tms[1] =~ /<tr><td><span[^>]*>(.*?)<\/span><\/td><td>(.*?)<\/td><td>(.*?)<\/td><td>(.*?)<\/td><\/tr>/gs) {
                    my ($h, $pod, $far, $csi) = ($1, $2, $3, $4);
                    $h   =~ s/<[^>]+>|—//g;
                    $pod =~ s/<[^>]+>|—//g;
                    $far =~ s/<[^>]+>|—//g;
                    $csi =~ s/<[^>]+>|—//g;
                    $h   =~ s/^\s+|\s+$//g;

                    if (exists $metricas{$h}) {
                        print "METRICAS,$fecha,$mes,$ubi,$cont,$h,"
                            . "$metricas{$h}{bias},$metricas{$h}{rmse},"
                            . "$metricas{$h}{r},$pod,$far,$csi\n";
                    }
                }
            }
        }  # fin foreach $card
    }  # fin foreach $pane
' "$FECHA" "$MES" "$archivo" > temp_datos.txt
    # -------------------------------------------------------------------------
    # Separación y acumulación en los CSV finales
    # -------------------------------------------------------------------------
    # grep "^DIARIO"   → filtra solo las líneas de datos diarios
    # sed 's/^DIARIO,//' → elimina el prefijo de etiqueta (no va en el CSV)
    # >>                 → acumula (append) en el CSV sin sobrescribir el header

    grep "^DIARIO"   temp_datos.txt | sed 's/^DIARIO,//'   >> "$CSV_DIARIO"
    grep "^METRICAS" temp_datos.txt | sed 's/^METRICAS,//' >> "$CSV_METRICAS"

done  # fin while read archivo

# ==============================================================================
# LIMPIEZA Y MENSAJE FINAL
# ==============================================================================
# Se elimina el archivo temporal. La opción -f evita error si no existiera.
rm -f temp_datos.txt

echo "====================================="
echo "¡Extracción completada satisfactoriamente!"
