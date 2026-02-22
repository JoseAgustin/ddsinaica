# 🌬️ v1.0.0 — Lanzamiento inicial

**Sistema de Descarga de Datos de Calidad del Aire · SINAICA / INECC**

---

## ¿Qué hace este release?

Primera versión estable del script de descarga automatizada de datos horarios de calidad del aire desde el portal [SINAICA](https://sinaica.inecc.gob.mx) del INECC, cubriendo 5 redes de monitoreo y 15 estaciones en el centro del país.

---

## ✨ Funcionalidades incluidas

- **Descarga multi-red y multi-estación** para las redes de Toluca, Puebla, Tlaxcala, Pachuca y Cuernavaca
- **Iteración mensual automática** desde abril 2025 hasta la fecha actual, respetando los límites de consulta de la API SINAICA
- **Parámetros descargados:** PM10, PM2.5 y O3
- **Promedio diario de 24 horas** para PM10 y PM2.5 (conforme a NOM-025-SSA1-2021)
- **Exportación en CSV o JSON**, con codificación UTF-8 compatible con Excel
- **Integración con el paquete R `rsinaica`** para acceso a la API oficial del portal
- **Registro de errores con contexto** (red, estación y parámetro) sin interrumpir la ejecución completa
- **Limpieza garantizada de archivos temporales** mediante bloques `try/finally`

---

## 🐛 Bugs corregidos respecto a versiones de desarrollo

| # | Descripción | Impacto |
|---|---|---|
| 1 | Código Python incrustado dentro del string R causaba `unexpected symbol` en `Rscript` | Crítico |
| 2 | Bloque de lectura de `temp_data.csv` estaba al nivel de módulo en lugar de dentro de la función | Crítico |
| 3 | Doble `return` consecutivo — el segundo (`return pd.DataFrame()`) era inalcanzable | Alto |
| 4 | Filtro de promedio diario usaba `"PM1.0"` y `"PM25"` en lugar de `"PM10"` y `"PM2.5"` — la condición nunca era verdadera | Alto |
| 5 | `df_month.empty` se evaluaba sin verificar primero si `df_month` era `None` | Medio |
| 6 | `temp_data.csv` no se eliminaba si `pd.read_csv()` lanzaba una excepción | Medio |

---

## 📦 Archivos de este release

| Archivo | Descripción |
|---|---|
| `sinaica_descarga_redes.py` | Script principal corregido y documentado |
| `README_sinaica_descarga.md` | Documentación técnica completa |

---

## ⚙️ Instalación rápida

```bash
pip install pandas python-dateutil
# install.packages("rsinaica")  # desde R
python sinaica_descarga_redes.py
```

---

## ⚠️ Consideraciones antes de ejecutar

- Verificar que `station_id = 501` para **"Primaria Ignacio Zaragoza"** (Pachuca) corresponda al ID real en el portal SINAICA — el valor actual es provisional.
- `Rscript` debe estar disponible en el `PATH` del sistema.
- El tiempo de ejecución estimado para el periodo completo es de **2 a 4 horas** (450 peticiones secuenciales).
- Los datos descargados son de tipo `"Crude"` (preliminares, no validados por el INECC).

---

## 📊 Cobertura

| Red | Estaciones | Estado |
|---|---|---|
| Toluca | 5 | Estado de México |
| Puebla | 5 | Puebla |
| Tlaxcala | 2 | Tlaxcala |
| Pachuca | 2 | Hidalgo |
| Cuernavaca | 1 | Morelos |

---

**Fuente de datos:** [SINAICA — INECC](https://sinaica.inecc.gob.mx) · **API:** paquete R [`rsinaica`](https://github.com/diegovalle/rsinaica) (Diego Valle-Jones)
