#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
taylor_mensual.py
=================
Genera diagramas de Taylor mensuales para la evaluación del modelo WRF-Chem
contra observaciones de la red SINAICA/INECC.

Cada punto en el diagrama representa una combinación única de:
    Ciudad + Contaminante + Horizonte de pronóstico
Ejemplo: "Pachuca PM10 24h", "Tula SO2 48h", "CDMX O3 72h"

Metodología (Taylor 2001 — Taylor, K.E., 2001, JGR-Atmospheres):
    ─────────────────────────────────────────────────────────────
    • Eje radial   : desviación estándar normalizada del modelo (σ_mod / σ_obs)
    • Eje angular  : θ = arccos(R), R = correlación de Pearson
    • CRMSE        : distancia del punto al punto de referencia (σ_obs/σ_obs = 1, θ=0)
      CRMSE = √(σ_mod² + σ_obs² - 2·σ_mod·σ_obs·R)   [valores sin normalizar]
      → normalizado: CRMSE_n = √(r² + 1 - 2r·R), r = σ_mod/σ_obs
    • Punto de referencia: (r=1, θ=0) — representa las observaciones perfectas
    • Los valores se normalizan por σ_obs para comparar entre contaminantes.

Control de calidad de datos observados (datos sin curar de SINAICA):
    ─────────────────────────────────────────────────────────────────
    Los datos de SINAICA se usan en modo "crudo" (sin validar). Esto introduce
    dos clases de problemas que se corrigen antes de calcular estadísticos:

    1. Valores negativos — físicamente imposibles en todos los contaminantes.
       Se eliminan los pares (obs, mod) donde obs < 0 o mod < 0.
       Umbrales de validez mínima configurables por contaminante (LIMITES_VALIDOS).

    2. Valores extraordinarios en PM2.5 — observaciones >120 µg/m³ en datos
       crudos son casi siempre artefactos de sensor, no episodios reales.
       Se aplica un filtro IQR (rango intercuartílico) que elimina puntos
       fuera de [Q1 − k·IQR, Q3 + k·IQR], con k configurable (default 3.0).
       El umbral fijo de 500 µg/m³ actúa como techo absoluto adicional.

Formato de entrada (combinado/ajustados/):
    eval_<CONT>_<Ciudad>_YYYY-MM-DD.csv
    Columnas: Fecha, Ciudad, max_obs, mod_dia1, mod_dia2, mod_dia3

    Ejemplo: eval_PM10_Pachuca_2026-06-17.csv
    Fecha,Ciudad,max_obs,mod_dia1,mod_dia2,mod_dia3
    2026-06-17,Pachuca,45.0617,11.7382,11.3944,13.6731

Salidas por mes (YYYY-MM):
    taylor_YYYY_MM.png        — Diagrama de Taylor
    estadisticas_taylor.csv   — Resumen estadístico completo

Uso:
    # Procesar todos los CSV en el directorio actual:
    python3 taylor_mensual.py

    # Especificar directorio de entrada y salida:
    python3 taylor_mensual.py --entrada combinado/ajustados --salida resultados/taylor

    # Solo un mes específico:
    python3 taylor_mensual.py --mes 2026-04

    # Filtrar ciudades:
    python3 taylor_mensual.py --ciudades Pachuca Tula CDMX
    python3 taylor_mensual.py --ciudades "Pachuca,Tula,CDMX"

    # Ajustar umbral absoluto de PM2.5 (default 500 µg/m³):
    python3 taylor_mensual.py --umbral-pm25 300

    # Ajustar factor IQR para detección de outliers (default 3.0):
    python3 taylor_mensual.py --iqr-factor 2.5

    # Mostrar ayuda:
    python3 taylor_mensual.py --help

Ciudades del dominio WRF-Chem (ver ddsinaica/README.md):
    CDMX, Cuernavaca, Pachuca, Puebla, SJdelRio, Tlaxcala, Toluca, Tula

Dependencias:
    pip install pandas numpy matplotlib scipy

Autor  : Adaptado para el pipeline ddsinaica (José Agustín García Reynoso)
Versión: 1.2.0  (2026-07) — control de calidad: negativos y outliers PM2.5
"""

import argparse
import glob
import os
import re
import sys
import warnings
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import matplotlib
matplotlib.use("Agg")           # Sin display — necesario en HPC/crontab
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors
import numpy as np
import pandas as pd
from scipy import stats

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURACIÓN GLOBAL
# ──────────────────────────────────────────────────────────────────────────────

# Mínimo de pares obs/mod válidos requeridos por serie para incluirse en el diagrama
MIN_PARES = 5

# ── Control de calidad de datos observados (datos crudos SINAICA) ─────────────
#
# 1. Límites físicos mínimos y máximos por contaminante.
#    Cualquier valor de obs O mod fuera del rango [min, max] se descarta.
#    El par completo (obs, mod) se elimina si alguno de los dos falla.
#
#    O3   : no negativo; máx operativo ~300 ppbv (episodios extremos conocidos)
#    PM10 : no negativo; máx operativo ~1000 µg/m³
#    PM25 : no negativo; máx operativo configurable (default 500 µg/m³ como techo)
#    SO2  : no negativo; máx operativo ~1000 ppbv (fuentes industriales)
#
LIMITES_VALIDOS = {
    #          (min_obs, max_obs,  min_mod, max_mod)  — unidades nativas del pipeline
    "O3":   (0.0,  300.0,  0.0,  300.0),
    "PM10": (0.0, 1000.0,  0.0, 1000.0),
    "PM25": (0.0,  500.0,  0.0,  500.0),   # techo absoluto; IQR lo refina
    "SO2":  (0.0, 1000.0,  0.0, 1000.0),
}

# 2. Filtro IQR para outliers en observaciones de PM2.5.
#    Se aplica SOLO a la columna max_obs de PM2.5 (el modelo no tiene este problema).
#    Un punto se elimina si: obs < Q1 - k*IQR  o  obs > Q3 + k*IQR
#    con k = IQR_FACTOR (configurable vía --iqr-factor).
#    k=3.0 (default) es un criterio conservador: solo elimina outliers extremos.
#    k=1.5 es el criterio boxplot estándar (más agresivo).
#
CONTAMINANTES_FILTRO_IQR = {"PM25"}   # aplicar IQR solo a estos contaminantes
IQR_FACTOR = 3.0                       # factor multiplicador (configurable en CLI)

# Catálogo oficial de ciudades del dominio WRF-Chem (ver ddsinaica/README.md)
CIUDADES_DOMINIO = [
    "CDMX", "Cuernavaca", "Pachuca", "Puebla",
    "SJdelRio", "Tlaxcala", "Toluca", "Tula",
]

# Normalización de nombre de ciudad → forma canónica (insensible a mayúsculas/acentos comunes)
_CIUDADES_NORM = {c.lower(): c for c in CIUDADES_DOMINIO}
# Alias frecuentes que pueden aparecer escritos de otra forma
_CIUDADES_NORM.update({
    "sjdelrio":      "SJdelRio",
    "san juan del rio": "SJdelRio",
    "san_juan_del_rio": "SJdelRio",
    "cdmx":          "CDMX",
    "ciudad de mexico": "CDMX",
    "valle de mexico":  "CDMX",
})

# Horizontes de pronóstico y sus etiquetas cortas
HORIZONTES = {
    "mod_dia1": "24h",
    "mod_dia2": "48h",
    "mod_dia3": "72h",
}

# Contaminantes reconocidos y sus unidades para leyenda
UNIDADES_CONT = {
    "O3":   "ppbv",
    "PM10": "µg/m³",
    "PM25": "µg/m³",
    "SO2":  "ppbv",
}

# Paleta de colores por contaminante
COLORES_CONT = {
    "O3":   "#1f77b4",   # Azul
    "PM10": "#d62728",   # Rojo
    "PM25": "#ff7f0e",   # Naranja
    "SO2":  "#9467bd",   # Violeta
}

# Marcadores por horizonte
MARKERS_HOR = {
    "24h": "o",    # círculo
    "48h": "s",    # cuadrado
    "72h": "^",    # triángulo
}

# Tamaño de los marcadores
MARKER_SIZE = 70

# Radio máximo del diagrama (en unidades normalizadas)
MAX_RADIO = 1.65

# Resolución de salida en DPI
DPI = 150

# ──────────────────────────────────────────────────────────────────────────────
# CONTROL DE CALIDAD DE DATOS
# ──────────────────────────────────────────────────────────────────────────────

def limpiar_serie(
    obs: np.ndarray,
    mod: np.ndarray,
    contaminante: str,
) -> Tuple[np.ndarray, np.ndarray, Dict[str, int]]:
    """
    Aplica control de calidad a un par de series (observado, modelo) antes
    de calcular estadísticos de Taylor.

    Pasos (en orden):
    -----------------
    1. Eliminar NaN / Inf en obs o mod.
    2. Aplicar límites físicos por contaminante (LIMITES_VALIDOS):
       se descarta el par si obs < min_obs, obs > max_obs,
       mod < min_mod o mod > max_mod.
       Esto captura valores negativos e implausiblemente altos en AMBAS series.
    3. Para contaminantes en CONTAMINANTES_FILTRO_IQR (PM2.5):
       filtro IQR sobre la serie de observaciones.
       Se elimina el par si obs < Q1 - k·IQR  o  obs > Q3 + k·IQR.

    Parámetros
    ----------
    obs           : array de observaciones del día (max diario observado)
    mod           : array del modelo (mismo horizonte, misma longitud que obs)
    contaminante  : clave del contaminante ("O3", "PM10", "PM25", "SO2")

    Retorna
    -------
    obs_limpio, mod_limpio : arrays filtrados (mismo tamaño)
    resumen : dict con conteos {
        "n_original"   : pares antes del filtro,
        "n_nan"        : eliminados por NaN/Inf,
        "n_limites"    : eliminados por límites físicos,
        "n_iqr"        : eliminados por filtro IQR (solo PM2.5),
        "n_final"      : pares válidos tras todos los filtros,
    }
    """
    obs = np.asarray(obs, dtype=float)
    mod = np.asarray(mod, dtype=float)
    n_original = len(obs)

    # ── Paso 1: eliminar NaN / Inf ────────────────────────────────────────────
    mask_nan = np.isfinite(obs) & np.isfinite(mod)
    obs, mod = obs[mask_nan], mod[mask_nan]
    n_nan = n_original - len(obs)

    # ── Paso 2: límites físicos por contaminante ──────────────────────────────
    lim = LIMITES_VALIDOS.get(contaminante)
    if lim is not None:
        min_obs, max_obs, min_mod, max_mod = lim
        mask_lim = (
            (obs >= min_obs) & (obs <= max_obs) &
            (mod >= min_mod) & (mod <= max_mod)
        )
        n_antes_lim = len(obs)
        obs, mod = obs[mask_lim], mod[mask_lim]
        n_limites = n_antes_lim - len(obs)
    else:
        n_limites = 0

    # ── Paso 3: filtro IQR sobre observaciones (solo contaminantes indicados) ─
    n_iqr = 0
    if contaminante in CONTAMINANTES_FILTRO_IQR and len(obs) >= 4:
        q1, q3 = np.percentile(obs, [25, 75])
        iqr = q3 - q1
        if iqr > 0:                         # IQR=0 → serie constante, sin filtrar
            lim_inf = q1 - IQR_FACTOR * iqr
            lim_sup = q3 + IQR_FACTOR * iqr
            mask_iqr = (obs >= lim_inf) & (obs <= lim_sup)
            n_antes_iqr = len(obs)
            obs, mod = obs[mask_iqr], mod[mask_iqr]
            n_iqr = n_antes_iqr - len(obs)

    resumen = {
        "n_original": n_original,
        "n_nan":      n_nan,
        "n_limites":  n_limites,
        "n_iqr":      n_iqr,
        "n_final":    len(obs),
    }
    return obs, mod, resumen


# ──────────────────────────────────────────────────────────────────────────────
# FUNCIONES DE CÁLCULO ESTADÍSTICO
# ──────────────────────────────────────────────────────────────────────────────

def calcular_estadisticas(
    obs: np.ndarray,
    mod: np.ndarray,
    contaminante: str = "",
) -> Optional[Dict]:
    """
    Aplica control de calidad y calcula las métricas estadísticas para el
    diagrama de Taylor.

    Parámetros
    ----------
    obs           : array de observaciones (máx. diario observado, valores crudos).
    mod           : array del modelo (mismo horizonte de pronóstico).
    contaminante  : clave del contaminante ("O3", "PM10", "PM25", "SO2").
                    Se usa para seleccionar los límites físicos y el filtro IQR.

    Retorna
    -------
    dict con las claves:
        n        — pares válidos tras control de calidad
        n_orig   — pares antes del filtro
        n_nan    — eliminados por NaN/Inf
        n_lim    — eliminados por límites físicos
        n_iqr    — eliminados por filtro IQR (solo PM2.5)
        sigma_obs— desviación estándar de las observaciones
        sigma_mod— desviación estándar del modelo
        r        — sigma_mod / sigma_obs  (razón normalizada)
        R        — correlación de Pearson
        theta    — arccos(R) en radianes
        CRMSE    — RMSE centrado (sin normalizar, mismas unidades que obs)
        CRMSE_n  — CRMSE normalizado por sigma_obs
        RMSE     — RMSE convencional
        BIAS     — sesgo medio (mod − obs)
        MAE      — error absoluto medio
    o None si no hay suficientes pares válidos.
    """
    # ── Control de calidad ────────────────────────────────────────────────────
    obs, mod, qc = limpiar_serie(np.asarray(obs, float), np.asarray(mod, float),
                                 contaminante)

    if qc["n_nan"] > 0 or qc["n_limites"] > 0 or qc["n_iqr"] > 0:
        pass   # El reporte detallado se hace en procesar_mes con print [QC]

    n = qc["n_final"]
    if n < MIN_PARES:
        return None      # Insuficientes datos tras el filtro

    # ── Estadísticos de Taylor ────────────────────────────────────────────────
    sigma_obs = float(np.std(obs, ddof=1))
    sigma_mod = float(np.std(mod, ddof=1))

    if sigma_obs < 1e-10:
        warnings.warn("σ_obs ≈ 0; serie de observaciones constante.", RuntimeWarning)
        return None

    R, p_valor = stats.pearsonr(obs, mod)
    R     = float(np.clip(R, -1.0, 1.0))
    theta = float(np.arccos(R))
    r     = sigma_mod / sigma_obs

    CRMSE_n = float(np.sqrt(r**2 + 1.0 - 2.0 * r * R))
    CRMSE   = float(CRMSE_n * sigma_obs)
    RMSE    = float(np.sqrt(np.mean((mod - obs)**2)))
    BIAS    = float(np.mean(mod - obs))
    MAE     = float(np.mean(np.abs(mod - obs)))

    return {
        "n":         n,
        "n_orig":    qc["n_original"],
        "n_nan":     qc["n_nan"],
        "n_lim":     qc["n_limites"],
        "n_iqr":     qc["n_iqr"],
        "sigma_obs": sigma_obs,
        "sigma_mod": sigma_mod,
        "r":         r,
        "R":         R,
        "p_valor":   p_valor,
        "theta":     theta,
        "CRMSE":     CRMSE,
        "CRMSE_n":   CRMSE_n,
        "RMSE":      RMSE,
        "BIAS":      BIAS,
        "MAE":       MAE,
    }


# ──────────────────────────────────────────────────────────────────────────────
# FUNCIONES DE LECTURA DE DATOS
# ──────────────────────────────────────────────────────────────────────────────

def normalizar_ciudad(nombre: str) -> Optional[str]:
    """
    Convierte un nombre de ciudad escrito por el usuario a su forma canónica
    del catálogo del dominio WRF-Chem. Retorna None si no se reconoce.
    """
    return _CIUDADES_NORM.get(nombre.strip().lower())


def parsear_lista_ciudades(valor) -> Optional[List[str]]:
    """
    Parsea el argumento --ciudades en una lista de nombres canónicos.

    Acepta:
        - None                          → todas las ciudades
        - str con coma y/o espacios      "Pachuca,Tula,CDMX" / "Pachuca Tula"
        - list[str] (resultado de argparse nargs="+")  ["Pachuca", "Tula"]

    Aborta con mensaje de error si alguna ciudad no es reconocida.
    """
    if not valor:
        return None

    if isinstance(valor, str):
        crudos = [t for t in re.split(r"[,\s]+", valor.strip()) if t]
    else:
        # Lista proveniente de argparse (nargs="+"); cada elemento puede
        # además contener comas, p. ej. ["Pachuca,Tula"]
        crudos = []
        for item in valor:
            crudos.extend(t for t in re.split(r"[,\s]+", item.strip()) if t)

    canonicas = []
    invalidas = []

    for c in crudos:
        c_norm = normalizar_ciudad(c)
        if c_norm is None:
            invalidas.append(c)
        elif c_norm not in canonicas:
            canonicas.append(c_norm)

    if invalidas:
        sys.exit(
            f"[ERROR] Ciudad(es) no reconocida(s): {invalidas}\n"
            f"        Ciudades válidas: {CIUDADES_DOMINIO}"
        )

    return canonicas



def parsear_nombre_archivo(ruta: str) -> Optional[Tuple[str, str]]:
    """
    Extrae contaminante y ciudad del nombre del archivo CSV.

    Formato esperado: eval_<CONT>_<Ciudad>_YYYY-MM-DD.csv
    Ejemplo:          eval_PM10_Pachuca_2026-06-17.csv → ("PM10", "Pachuca")

    Retorna None si el nombre no coincide con el patrón.
    """
    nombre = Path(ruta).stem    # quita extensión
    patron = r"^eval_([A-Za-z0-9]+)_(.+)_\d{4}-\d{2}-\d{2}$"
    m = re.match(patron, nombre)
    if not m:
        return None
    contaminante = m.group(1).upper()
    ciudad_cruda = m.group(2)
    ciudad = normalizar_ciudad(ciudad_cruda) or ciudad_cruda   # conserva original si no está en catálogo
    return contaminante, ciudad


def leer_csv(ruta: str) -> pd.DataFrame | None:
    """
    Lee un CSV del pipeline y valida sus columnas mínimas.

    Columnas requeridas: Fecha, Ciudad, max_obs, mod_dia1, mod_dia2, mod_dia3
    """
    columnas_req = {"Fecha", "Ciudad", "max_obs", "mod_dia1", "mod_dia2", "mod_dia3"}
    try:
        df = pd.read_csv(ruta, parse_dates=["Fecha"])
    except Exception as e:
        warnings.warn(f"No se pudo leer '{ruta}': {e}", RuntimeWarning)
        return None

    faltantes = columnas_req - set(df.columns)
    if faltantes:
        warnings.warn(
            f"'{ruta}' omitido — columnas faltantes: {faltantes}", RuntimeWarning
        )
        return None
    return df


def agrupar_datos_por_mes(
    directorio: str,
    ciudades_filtro: Optional[List[str]] = None,
) -> dict:
    """
    Lee todos los CSV válidos en ``directorio`` y los organiza en un diccionario:

        datos[mes_str][ciudad][contaminante] → pd.DataFrame acumulado

    donde mes_str tiene el formato "YYYY-MM".

    Parámetros
    ----------
    directorio      : ruta a combinado/ajustados (o equivalente)
    ciudades_filtro : lista de ciudades canónicas a incluir; None = todas

    El acumulado de todos los días del mes en una sola serie larga permite
    calcular las estadísticas mensuales de Taylor.
    """
    patron_glob = os.path.join(directorio, "eval_*.csv")
    archivos    = sorted(glob.glob(patron_glob))

    if not archivos:
        sys.exit(
            f"[ERROR] No se encontraron archivos 'eval_*.csv' en '{directorio}'.\n"
            f"        Verifique la ruta con --entrada."
        )

    datos = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    n_leidos     = 0
    n_filtrados  = 0

    for ruta in archivos:
        meta = parsear_nombre_archivo(ruta)
        if meta is None:
            warnings.warn(
                f"'{os.path.basename(ruta)}' omitido — nombre no reconocido.",
                RuntimeWarning,
            )
            continue

        contaminante, ciudad = meta

        # ── Filtro de ciudades solicitadas por el usuario ──────────────────
        if ciudades_filtro is not None and ciudad not in ciudades_filtro:
            n_filtrados += 1
            continue

        df = leer_csv(ruta)
        if df is None:
            continue

        # Agregar columnas de metadatos al DataFrame para trazabilidad
        df["_contaminante"] = contaminante
        df["_ciudad"]       = ciudad

        # Determinar mes del primer registro (todos los del archivo son del mismo día)
        mes_str = df["Fecha"].dt.strftime("%Y-%m").iloc[0]

        datos[mes_str][ciudad][contaminante].append(df)
        n_leidos += 1

    print(f"[INFO] Archivos CSV procesados: {n_leidos}")
    if ciudades_filtro is not None:
        print(f"[INFO] Archivos excluidos por filtro de ciudad: {n_filtrados}")
        print(f"[INFO] Ciudades solicitadas: {ciudades_filtro}")
    print(f"[INFO] Meses encontrados: {sorted(datos.keys())}")

    if n_leidos == 0:
        sys.exit(
            f"[ERROR] Ninguna combinación ciudad/archivo coincidió con el filtro.\n"
            f"        Ciudades solicitadas: {ciudades_filtro}"
        )

    return datos


# ──────────────────────────────────────────────────────────────────────────────
# CONSTRUCCIÓN DEL DIAGRAMA DE TAYLOR
# ──────────────────────────────────────────────────────────────────────────────

def configurar_ejes_taylor(ax: plt.Axes, max_radio: float) -> None:
    """
    Dibuja la cuadrícula polar del diagrama de Taylor sobre ``ax``.

    Incluye:
    - Arcos de desviación estándar normalizada (0.25, 0.5, 0.75, 1.0, 1.25, 1.5)
    - Líneas de correlación (R = 0.1, 0.2, …, 0.9, 0.95, 0.99)
    - Arcos de CRMSE centrada (líneas de nivel en distancia al punto de ref.)
    - Punto y línea de referencia (observaciones)
    """
    ax.set_aspect("equal")

    # ── Semiciclo exterior ───────────────────────────────────────────────────
    theta_full = np.linspace(0, np.pi / 2, 300)    # primer cuadrante

    # Arco exterior del diagrama
    ax.plot(
        max_radio * np.cos(theta_full),
        max_radio * np.sin(theta_full),
        color="black", lw=1.0, ls="-",
    )

    # ── Arcos de σ normalizada ───────────────────────────────────────────────
    radios_std = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5]
    for r in radios_std:
        if r > max_radio:
            break
        ax.plot(
            r * np.cos(theta_full),
            r * np.sin(theta_full),
            color="gray", lw=0.6, ls="--", zorder=1,
        )
        ax.text(
            r, -0.07, f"{r:.2f}",
            ha="center", va="top", fontsize=7, color="gray",
        )

    # Eje horizontal (Y = 0)
    ax.axhline(0, color="black", lw=0.8, ls="-")

    # ── Líneas radiales de correlación ──────────────────────────────────────
    valores_R = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 0.99]
    for R_val in valores_R:
        theta_R = np.arccos(R_val)
        ax.plot(
            [0, max_radio * np.cos(theta_R)],
            [0, max_radio * np.sin(theta_R)],
            color="lightblue", lw=0.7, ls="--", zorder=1,
        )
        # Etiqueta en el borde del arco
        x_lbl = (max_radio + 0.07) * np.cos(theta_R)
        y_lbl = (max_radio + 0.07) * np.sin(theta_R)
        ax.text(
            x_lbl, y_lbl, f"{R_val:.2f}",
            ha="center", va="center", fontsize=6.5, color="steelblue",
            rotation=-np.degrees(theta_R) + 90,
        )

    # ── Arcos de CRMSE normalizada (distancia al punto de ref.) ─────────────
    x_ref, y_ref = 1.0, 0.0     # punto de referencia normalizado
    valores_crmse = [0.25, 0.5, 0.75, 1.0]
    for c in valores_crmse:
        theta_c = np.linspace(0, np.pi, 500)
        xc = x_ref + c * np.cos(theta_c)
        yc = y_ref + c * np.sin(theta_c)
        # Recortar al primer cuadrante y dentro del radio máximo
        mask_c = (xc >= 0) & (np.sqrt(xc**2 + yc**2) <= max_radio) & (yc >= 0)
        if mask_c.any():
            ax.plot(
                xc[mask_c], yc[mask_c],
                color="green", lw=0.6, ls=":", zorder=1, alpha=0.7,
            )
            # Etiqueta en el arco
            idx_mid = np.where(mask_c)[0][len(np.where(mask_c)[0]) // 2]
            ax.text(
                xc[idx_mid], yc[idx_mid], f"{c:.2f}",
                ha="center", va="center", fontsize=6, color="darkgreen",
                bbox=dict(fc="white", ec="none", alpha=0.5, pad=0.5),
            )

    # ── Punto y marcador de referencia (observaciones) ───────────────────────
    ax.plot(1.0, 0.0, "k*", ms=14, zorder=6, label="Observaciones (REF)")
    ax.annotate(
        "REF",
        xy=(1.0, 0.0), xytext=(1.05, 0.08),
        fontsize=8, color="black",
        arrowprops=dict(arrowstyle="-", color="black", lw=0.8),
    )

    # ── Etiquetas de ejes ────────────────────────────────────────────────────
    ax.set_xlabel("Desviación estándar normalizada (σ_mod / σ_obs)", fontsize=9)
    ax.set_ylabel("Desviación estándar normalizada (σ_mod / σ_obs)", fontsize=9)

    # Eje X e Y solo positivos
    ax.set_xlim(-0.05, max_radio + 0.18)
    ax.set_ylim(-0.12, max_radio + 0.18)
    ax.set_xticks([])
    ax.set_yticks([])

    # Texto de ejes angulares (R y σ)
    ax.text(
        max_radio / 2, -0.1, "σ normalizada",
        ha="center", va="top", fontsize=8, color="gray",
    )
    ax.text(
        -0.03, max_radio / 2, "σ normalizada",
        ha="right", va="center", fontsize=8, color="gray",
        rotation=90,
    )

    # Anotación CRMSE
    ax.text(
        0.02, 0.98, "⟶ verde punteado = CRMSE normalizado",
        transform=ax.transAxes, fontsize=6.5, va="top", color="darkgreen", alpha=0.8,
    )
    ax.text(
        0.02, 0.94, "⟶ azul punteado = correlación de Pearson R",
        transform=ax.transAxes, fontsize=6.5, va="top", color="steelblue", alpha=0.8,
    )


def graficar_taylor_mensual(
    mes_str: str,
    registros: List[dict],
    dir_salida: str,
    ciudades_filtro: Optional[List[str]] = None,
) -> None:
    """
    Genera y guarda el diagrama de Taylor para un mes.

    Parámetros
    ----------
    mes_str   : "YYYY-MM"
    registros : lista de diccionarios con claves:
        ciudad, contaminante, horizonte, estadisticas (dict de calcular_estadisticas)
    dir_salida: directorio donde se guardan las imágenes
    ciudades_filtro : ciudades incluidas en esta corrida (None = todas);
                       se usa para anotar el título y el nombre del archivo.
    """
    if not registros:
        print(f"[WARN] {mes_str}: sin datos suficientes para generar diagrama.")
        return

    fig, ax = plt.subplots(figsize=(10, 9))
    configurar_ejes_taylor(ax, MAX_RADIO)

    # ── Graficar cada punto ───────────────────────────────────────────────────
    puntos_legend = {}   # etiqueta → handle de matplotlib, para leyenda manual

    for reg in registros:
        st   = reg["estadisticas"]
        cont = reg["contaminante"]
        hor  = reg["horizonte"]
        ciud = reg["ciudad"]

        color  = COLORES_CONT.get(cont, "black")
        marker = MARKERS_HOR.get(hor, "D")

        x = st["r"] * np.cos(st["theta"])
        y = st["r"] * np.sin(st["theta"])

        # Punto en el diagrama
        sc = ax.scatter(
            x, y,
            c=color, marker=marker, s=MARKER_SIZE,
            edgecolors="white", linewidths=0.6, zorder=5, alpha=0.85,
        )

        # Etiqueta del punto: Ciudad + horizonte
        etiqueta = f"{ciud}\n{hor}"
        ax.annotate(
            etiqueta,
            xy=(x, y), xytext=(x + 0.04, y + 0.02),
            fontsize=5.5, color=color, zorder=6,
        )

        # Acumular handles únicos para la leyenda
        key_cont = f"{cont} ({UNIDADES_CONT.get(cont, '?')})"
        if key_cont not in puntos_legend:
            h = ax.scatter(
                [], [], c=color, marker="o", s=50,
                edgecolors="white", linewidths=0.6, label=key_cont,
            )
            puntos_legend[key_cont] = h

    # ── Leyenda de horizontes (marcadores) ────────────────────────────────────
    leyenda_hor = [
        plt.scatter([], [], c="gray", marker=MARKERS_HOR[h], s=50, label=h)
        for h in MARKERS_HOR
    ]

    # Combinar leyendas
    handles = list(puntos_legend.values()) + leyenda_hor
    legend1 = ax.legend(
        handles=handles,
        loc="upper right",
        fontsize=7,
        title="Contaminante / Horizonte",
        title_fontsize=7.5,
        framealpha=0.9,
        edgecolor="gray",
    )
    ax.add_artist(legend1)

    # ── Título y metadatos ────────────────────────────────────────────────────
    anio, mes = mes_str.split("-")
    nombre_mes = {
        "01": "Enero",   "02": "Febrero",  "03": "Marzo",
        "04": "Abril",   "05": "Mayo",     "06": "Junio",
        "07": "Julio",   "08": "Agosto",   "09": "Septiembre",
        "10": "Octubre", "11": "Noviembre","12": "Diciembre",
    }.get(mes, mes)

    n_puntos = len(registros)
    if ciudades_filtro:
        subtitulo_ciudades = f"Ciudades: {', '.join(ciudades_filtro)}"
    else:
        subtitulo_ciudades = "Todas las ciudades del dominio"

    ax.set_title(
        f"Diagrama de Taylor — {nombre_mes} {anio}\n"
        f"Evaluación WRF-Chem vs SINAICA  |  {n_puntos} combinaciones Ciudad×Cont×Horizonte\n"
        f"{subtitulo_ciudades}",
        fontsize=11, pad=12,
    )

    # Nota metodológica
    fig.text(
        0.01, 0.01,
        "Valores normalizados por σ_obs  |  Referencia: Taylor (2001) JGR-Atmospheres  |  "
        f"Mín. pares válidos = {MIN_PARES}",
        fontsize=6, style="italic", color="gray",
    )

    plt.tight_layout()

    # ── Guardar ───────────────────────────────────────────────────────────────
    os.makedirs(dir_salida, exist_ok=True)
    if ciudades_filtro:
        sufijo = "_" + "-".join(ciudades_filtro)
    else:
        sufijo = ""
    nombre_png = f"taylor_{anio}_{mes}{sufijo}.png"
    ruta_png   = os.path.join(dir_salida, nombre_png)
    fig.savefig(ruta_png, dpi=DPI, bbox_inches="tight")
    plt.close(fig)
    print(f"[OK]   Diagrama guardado: {ruta_png}")


# ──────────────────────────────────────────────────────────────────────────────
# EXPORTACIÓN DEL CSV DE ESTADÍSTICAS
# ──────────────────────────────────────────────────────────────────────────────

def exportar_estadisticas(
    mes_str: str,
    registros: List[dict],
    dir_salida: str,
    ciudades_filtro: Optional[List[str]] = None,
) -> None:
    """
    Escribe el CSV de estadísticas mensuales de Taylor.

    Columnas de salida:
        mes, ciudad, contaminante, horizonte,
        n, n_orig, n_nan, n_lim, n_iqr,       ← control de calidad
        sigma_obs, sigma_mod, r_norm, R,
        BIAS, RMSE, MAE, CRMSE, CRMSE_n, p_valor

    ciudades_filtro : si se proporcionó, se añade un sufijo al nombre del
                       CSV para no mezclar resultados de distintas corridas
                       filtradas con el acumulado de "todas las ciudades".
    """
    if not registros:
        return

    filas = []
    for reg in registros:
        st = reg["estadisticas"]
        filas.append({
            "mes":          mes_str,
            "ciudad":       reg["ciudad"],
            "contaminante": reg["contaminante"],
            "horizonte":    reg["horizonte"],
            # ── Control de calidad ──────────────────────────────────────────
            "n":            st["n"],
            "n_orig":       st["n_orig"],
            "n_nan":        st["n_nan"],
            "n_lim":        st["n_lim"],
            "n_iqr":        st["n_iqr"],
            # ── Estadísticos Taylor ─────────────────────────────────────────
            "sigma_obs":    round(st["sigma_obs"], 4),
            "sigma_mod":    round(st["sigma_mod"], 4),
            "r_norm":       round(st["r"],         4),
            "R":            round(st["R"],          4),
            "BIAS":         round(st["BIAS"],       4),
            "RMSE":         round(st["RMSE"],       4),
            "MAE":          round(st["MAE"],        4),
            "CRMSE":        round(st["CRMSE"],      4),
            "CRMSE_n":      round(st["CRMSE_n"],    4),
            "p_valor":      round(st["p_valor"],    6),
        })

    df_out = pd.DataFrame(filas).sort_values(
        ["ciudad", "contaminante", "horizonte"]
    ).reset_index(drop=True)

    os.makedirs(dir_salida, exist_ok=True)
    if ciudades_filtro:
        sufijo = "_" + "-".join(ciudades_filtro)
    else:
        sufijo = ""
    nombre_csv = f"estadisticas_taylor{sufijo}.csv"
    ruta_csv   = os.path.join(dir_salida, nombre_csv)

    # Modo append si el archivo ya existe (para acumular varios meses)
    modo     = "a" if os.path.exists(ruta_csv) else "w"
    cabecera = not os.path.exists(ruta_csv)
    df_out.to_csv(ruta_csv, mode=modo, header=cabecera, index=False)
    print(f"[OK]   Estadísticas escritas: {ruta_csv}  ({len(df_out)} filas)")


# ──────────────────────────────────────────────────────────────────────────────
# PROCESAMIENTO PRINCIPAL POR MES
# ──────────────────────────────────────────────────────────────────────────────

def procesar_mes(
    mes_str: str,
    datos_mes: dict,
    dir_salida: str,
    ciudades_filtro: Optional[List[str]] = None,
) -> None:
    """
    Consolida los datos de un mes, calcula estadísticas y genera salidas.

    datos_mes : datos[ciudad][contaminante] → lista de DataFrames diarios
    ciudades_filtro : lista de ciudades incluidas en esta corrida (solo para
                       metadatos del título/nombre de archivo); None = todas
    """
    registros_ok = []
    n_series     = 0
    n_omitidos   = 0
    # Acumuladores de control de calidad para el resumen final del mes
    qc_total = {"n_nan": 0, "n_lim": 0, "n_iqr": 0}

    for ciudad, conts in sorted(datos_mes.items()):
        for cont, lista_df in sorted(conts.items()):

            # Concatenar todos los días del mes en una sola serie
            df_mes = pd.concat(lista_df, ignore_index=True)
            df_mes = df_mes.sort_values("Fecha").reset_index(drop=True)

            obs = df_mes["max_obs"].values

            for col_mod, hor_label in HORIZONTES.items():
                n_series += 1
                mod = df_mes[col_mod].values

                # Pasar el contaminante para aplicar QC específico
                st = calcular_estadisticas(obs, mod, contaminante=cont)

                etiq = f"{ciudad} {cont} {hor_label}"
                if st is None:
                    print(
                        f"[WARN] {mes_str} | {etiq}: "
                        f"pares insuficientes (<{MIN_PARES}) o σ_obs≈0 — omitido."
                    )
                    n_omitidos += 1
                    continue

                # Reportar descarte de datos si hubo filtrado QC
                if st["n_nan"] + st["n_lim"] + st["n_iqr"] > 0:
                    desc = []
                    if st["n_nan"] > 0:
                        desc.append(f"NaN/Inf={st['n_nan']}")
                    if st["n_lim"] > 0:
                        desc.append(f"límites físicos={st['n_lim']}")
                    if st["n_iqr"] > 0:
                        desc.append(f"outliers IQR={st['n_iqr']}")
                    print(
                        f"[QC]   {mes_str} | {etiq}: "
                        f"{st['n_orig'] - st['n']} pares descartados "
                        f"({', '.join(desc)}) → quedan {st['n']}/{st['n_orig']}"
                    )
                    qc_total["n_nan"] += st["n_nan"]
                    qc_total["n_lim"] += st["n_lim"]
                    qc_total["n_iqr"] += st["n_iqr"]

                registros_ok.append({
                    "ciudad":       ciudad,
                    "contaminante": cont,
                    "horizonte":    hor_label,
                    "estadisticas": st,
                    "etiqueta":     etiq,
                })

    total_descartados = sum(qc_total.values())
    print(
        f"[INFO] {mes_str}: {n_series} series evaluadas, "
        f"{len(registros_ok)} válidas, {n_omitidos} omitidas."
    )
    if total_descartados > 0:
        print(
            f"[QC]   {mes_str}: total pares descartados en el mes — "
            f"NaN/Inf={qc_total['n_nan']}, "
            f"límites físicos={qc_total['n_lim']}, "
            f"outliers IQR={qc_total['n_iqr']}"
        )

    graficar_taylor_mensual(mes_str, registros_ok, dir_salida, ciudades_filtro)
    exportar_estadisticas(mes_str, registros_ok, dir_salida, ciudades_filtro)


# ──────────────────────────────────────────────────────────────────────────────
# PUNTO DE ENTRADA
# ──────────────────────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    """Parsea los argumentos de la línea de comandos."""
    parser = argparse.ArgumentParser(
        prog="taylor_mensual.py",
        description=(
            "Genera diagramas de Taylor mensuales para la evaluación del modelo "
            "WRF-Chem contra observaciones SINAICA/INECC.\n\n"
            "Lee archivos del tipo eval_<CONT>_<Ciudad>_YYYY-MM-DD.csv "
            "del directorio combinado/ajustados y produce:\n"
            "  taylor_YYYY_MM.png       — Diagrama de Taylor\n"
            "  estadisticas_taylor.csv  — Resumen estadístico completo"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--entrada", "-i",
        default="combinado/ajustados",
        metavar="DIR",
        help="Directorio con los CSV de evaluación (default: combinado/ajustados)",
    )
    parser.add_argument(
        "--salida", "-o",
        default=".",
        metavar="DIR",
        help="Directorio de salida para PNG y CSV (default: directorio actual)",
    )
    parser.add_argument(
        "--mes", "-m",
        default=None,
        metavar="YYYY-MM",
        help="Procesar solo este mes (ej: 2026-04). Por defecto procesa todos.",
    )
    parser.add_argument(
        "--ciudades", "-c",
        default=None,
        nargs="+",
        metavar="CIUDAD",
        help=(
            "Una o varias ciudades a incluir, separadas por espacio (o coma dentro "
            f"de un solo argumento). Catálogo válido: {', '.join(CIUDADES_DOMINIO)}. "
            "Por defecto procesa todas las ciudades disponibles."
        ),
    )
    parser.add_argument(
        "--min-pares", "-p",
        type=int,
        default=MIN_PARES,
        metavar="N",
        help=f"Mínimo de pares válidos por serie (default: {MIN_PARES})",
    )
    parser.add_argument(
        "--max-radio", "-r",
        type=float,
        default=MAX_RADIO,
        metavar="R",
        help=f"Radio máximo del diagrama en unidades normalizadas (default: {MAX_RADIO})",
    )
    parser.add_argument(
        "--dpi",
        type=int,
        default=DPI,
        metavar="DPI",
        help=f"Resolución de los PNG (default: {DPI})",
    )
    parser.add_argument(
        "--umbral-pm25",
        type=float,
        default=LIMITES_VALIDOS["PM25"][1],
        metavar="UG_M3",
        help=(
            "Techo absoluto para observaciones de PM2.5 en µg/m³. "
            "Pares con max_obs > este valor se descartan antes del cálculo. "
            f"Default: {LIMITES_VALIDOS['PM25'][1]} µg/m³."
        ),
    )
    parser.add_argument(
        "--iqr-factor",
        type=float,
        default=IQR_FACTOR,
        metavar="K",
        help=(
            "Factor multiplicador del IQR para detección de outliers en PM2.5. "
            "Se eliminan observaciones fuera de [Q1 - k·IQR, Q3 + k·IQR]. "
            "k=3.0 (default, conservador) | k=1.5 (criterio boxplot estándar, agresivo)."
        ),
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    # Aplicar argumentos a variables globales
    global MIN_PARES, MAX_RADIO, DPI, IQR_FACTOR, LIMITES_VALIDOS
    MIN_PARES  = args.min_pares
    MAX_RADIO  = args.max_radio
    DPI        = args.dpi
    IQR_FACTOR = args.iqr_factor

    # Actualizar el techo absoluto de PM2.5 según el argumento CLI
    lim_pm25 = list(LIMITES_VALIDOS["PM25"])
    lim_pm25[1] = args.umbral_pm25   # max_obs
    LIMITES_VALIDOS["PM25"] = tuple(lim_pm25)

    print("=" * 60)
    print("  Diagramas de Taylor — Evaluación WRF-Chem / SINAICA")
    print("=" * 60)
    print(f"  Entrada      : {args.entrada}")
    print(f"  Salida       : {args.salida}")
    print(f"  Mes          : {args.mes or 'todos'}")
    print(f"  Ciudades     : {args.ciudades or 'todas'}")
    print(f"  Min par      : {MIN_PARES}")
    print(f"  QC — techo PM2.5 : {LIMITES_VALIDOS['PM25'][1]} µg/m³")
    print(f"  QC — factor IQR  : {IQR_FACTOR}  (k·IQR sobre obs PM2.5)")
    print("=" * 60)

    # 0. Validar y normalizar el filtro de ciudades (si se proporcionó)
    ciudades_filtro = parsear_lista_ciudades(args.ciudades)

    # 1. Leer y organizar todos los CSV por mes
    datos = agrupar_datos_por_mes(args.entrada, ciudades_filtro)

    # 2. Filtrar meses si se especificó uno
    if args.mes:
        if args.mes not in datos:
            sys.exit(
                f"[ERROR] El mes '{args.mes}' no tiene datos en '{args.entrada}'.\n"
                f"        Meses disponibles: {sorted(datos.keys())}"
            )
        meses_a_procesar = [args.mes]
    else:
        meses_a_procesar = sorted(datos.keys())

    # 3. Limpiar CSV acumulado si se regeneran todos los meses
    if ciudades_filtro:
        nombre_csv_base = "estadisticas_taylor_" + "-".join(ciudades_filtro) + ".csv"
    else:
        nombre_csv_base = "estadisticas_taylor.csv"
    ruta_csv_global = os.path.join(args.salida, nombre_csv_base)
    if not args.mes and os.path.exists(ruta_csv_global):
        os.remove(ruta_csv_global)
        print(f"[INFO] CSV previo eliminado para regeneración limpia: {ruta_csv_global}")

    # 4. Procesar cada mes
    for mes_str in meses_a_procesar:
        print(f"\n── Procesando: {mes_str} ──")
        procesar_mes(mes_str, datos[mes_str], args.salida, ciudades_filtro)

    print(f"\n[DONE] {len(meses_a_procesar)} mes(es) procesados.")


if __name__ == "__main__":
    main()
