#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
informe_dicotomico.py
=====================
Calcula estadísticos dicotómicos mensuales (POD, FAR, CSI, TSS, PC, BIAS_DICHO)
a partir de los CSV diarios de `combinado/ajustados/` y genera un documento
Word (.docx) con los resultados organizados por contaminante y ciudad.

Contaminantes evaluados y umbrales normativos:
    O3   — 135 ppbv        (NOM-020-SSA1)
    PM10 — 75 µg/m³        (NOM-025-SSA1-2021)
    PM25 — 45 µg/m³        (NOM-025-SSA1-2021)
    SO2  — 130 ppbv        (NOM-022-SSA1-2010)

Estadísticos de la tabla de contingencia 2×2 (evento = valor ≥ umbral):
    H  — acierto       (obs evento,  mod evento)
    M  — fallo         (obs evento,  mod no-evento)
    F  — falsa alarma  (obs no-evento, mod evento)
    C  — rechazo correcto (obs no-evento, mod no-evento)

    POD  = H / (H + M)          Probabilidad de detección
    FAR  = F / (H + F)          Tasa de falsas alarmas
    CSI  = H / (H + M + F)      Índice de éxito crítico (Threat Score)
    TSS  = H/(H+M) − F/(F+C)   Pierce Skill Score  (Hanssen-Kuipers discriminant)
    PC   = (H + C) / N          Porcentaje correcto (Percent Correct)
    BIAS = (H + F) / (H + M)    Sesgo de frecuencia (Frequency Bias)

Formato de entrada:
    combinado/ajustados/eval_<CONT>_<Ciudad>_YYYY-MM-DD.csv
    Fecha,Ciudad,max_obs,mod_dia1,mod_dia2,mod_dia3

Uso:
    python3 informe_dicotomico.py
    python3 informe_dicotomico.py --entrada combinado/ajustados --salida informe_dicotomico.docx
    python3 informe_dicotomico.py --mes 2026-06
    python3 informe_dicotomico.py --ciudades Pachuca Tula CDMX
    python3 informe_dicotomico.py --help

Dependencias:
    pip install pandas numpy
    npm (docx preinstalado)

Autor  : Pipeline ddsinaica / WRF-Chem — ICAyCC, UNAM
Versión: 1.0.0 (2026-07)
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import warnings
from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURACIÓN GLOBAL
# ──────────────────────────────────────────────────────────────────────────────

# Umbrales normativos por contaminante
UMBRALES = {
    "O3":   135.0,   # ppbv      NOM-020-SSA1
    "PM10": 75.0,    # µg/m³     NOM-025-SSA1-2021
    "PM25": 45.0,    # µg/m³     NOM-025-SSA1-2021
    "SO2":  130.0,   # ppbv      NOM-022-SSA1-2010
}

# Unidades, nombres completos y citas normativas
META_CONT = {
    "O3": {
        "nombre":  "Ozono (O₃)",
        "unidad":  "ppbv",
        "norma":   "NOM-020-SSA1",
        "desc":    (
            "Gas oxidante de la troposfera, formado fotoquímicamente a partir de "
            "NOₓ y compuestos orgánicos volátiles (COV). Causa irritación respiratoria "
            "y daño a cultivos. Umbral de referencia: 135 ppbv (máximo diario de la "
            "media móvil de 8 h, NOM-020-SSA1)."
        ),
    },
    "PM10": {
        "nombre":  "Partículas suspendidas gruesas (PM10)",
        "unidad":  "µg/m³",
        "norma":   "NOM-025-SSA1-2021",
        "desc":    (
            "Partículas con diámetro aerodinámico ≤ 10 µm, de origen tanto natural "
            "(polvo mineral, suelo resuspendido, polen) como antrópico (tráfico, "
            "industria, agricultura). Penetran la nariz y la garganta y pueden "
            "alcanzar los bronquios. Umbral: 75 µg/m³ en promedio de 24 h "
            "(NOM-025-SSA1-2021)."
        ),
    },
    "PM25": {
        "nombre":  "Partículas suspendidas finas (PM2.5)",
        "unidad":  "µg/m³",
        "norma":   "NOM-025-SSA1-2021",
        "desc":    (
            "Fracción con diámetro ≤ 2.5 µm, principalmente de combustión "
            "(vehículos, generación eléctrica, quemas). Por su pequeño tamaño "
            "alcanzan los alvéolos pulmonares y pueden pasar al torrente sanguíneo, "
            "con efectos cardiovasculares documentados a largo plazo. Umbral: "
            "45 µg/m³ en 24 h (NOM-025-SSA1-2021)."
        ),
    },
    "SO2": {
        "nombre":  "Dióxido de azufre (SO₂)",
        "unidad":  "ppbv",
        "norma":   "NOM-022-SSA1-2010",
        "desc":    (
            "Gas incoloro de olor acre emitido principalmente por la combustión "
            "de combustibles fósiles con alto contenido de azufre (refinación de "
            "petróleo, centrales termoeléctricas). Produce irritación de las vías "
            "respiratorias superiores y contribuye a la formación de lluvia ácida. "
            "Umbral: 130 ppbv en promedio de 24 h (NOM-022-SSA1-2010, equivalente "
            "a 0.13 ppm)."
        ),
    },
}

# Catálogo oficial de ciudades del dominio
CIUDADES_DOMINIO = [
    "CDMX", "Cuernavaca", "Pachuca", "Puebla",
    "SJdelRio", "Tlaxcala", "Toluca", "Tula",
]
_CIUDADES_NORM = {c.lower(): c for c in CIUDADES_DOMINIO}
_CIUDADES_NORM.update({
    "sjdelrio":           "SJdelRio",
    "san juan del rio":   "SJdelRio",
    "cdmx":               "CDMX",
    "ciudad de mexico":   "CDMX",
})

# Horizontes de pronóstico
HORIZONTES = {"mod_dia1": "+24 h", "mod_dia2": "+48 h", "mod_dia3": "+72 h"}

# Mínimo de días con datos (H+M+F+C) para calcular estadísticos
MIN_DIAS = 5


# ──────────────────────────────────────────────────────────────────────────────
# UTILIDADES
# ──────────────────────────────────────────────────────────────────────────────

def normalizar_ciudad(nombre: str) -> str | None:
    return _CIUDADES_NORM.get(nombre.strip().lower())


def parsear_lista_ciudades(valor) -> list[str] | None:
    if not valor:
        return None
    if isinstance(valor, str):
        crudos = [t for t in re.split(r"[,\s]+", valor.strip()) if t]
    else:
        crudos = []
        for item in valor:
            crudos.extend(t for t in re.split(r"[,\s]+", item.strip()) if t)
    canonicas, invalidas = [], []
    for c in crudos:
        cn = normalizar_ciudad(c)
        if cn is None:
            invalidas.append(c)
        elif cn not in canonicas:
            canonicas.append(cn)
    if invalidas:
        sys.exit(
            f"[ERROR] Ciudad(es) no reconocida(s): {invalidas}\n"
            f"        Válidas: {CIUDADES_DOMINIO}"
        )
    return canonicas


def parsear_nombre_archivo(ruta: str):
    """Extrae (contaminante, ciudad) de eval_<CONT>_<Ciudad>_YYYY-MM-DD.csv"""
    nombre = Path(ruta).stem
    m = re.match(r"^eval_([A-Za-z0-9]+)_(.+)_\d{4}-\d{2}-\d{2}$", nombre)
    if not m:
        return None
    cont   = m.group(1).upper()
    ciudad = normalizar_ciudad(m.group(2)) or m.group(2)
    return cont, ciudad


# ──────────────────────────────────────────────────────────────────────────────
# CÁLCULO DE ESTADÍSTICOS DICOTÓMICOS
# ──────────────────────────────────────────────────────────────────────────────

def contingencia(obs: np.ndarray, mod: np.ndarray, umbral: float) -> dict:
    """
    Construye la tabla de contingencia 2×2 y calcula todos los
    estadísticos dicotómicos.

    Parámetros
    ----------
    obs, mod : arrays de igual longitud con valores diarios.
    umbral   : valor de referencia normativo (mismo umbral para obs y mod).

    Retorna dict con H, M, F, C, N, POD, FAR, CSI, TSS, PC, BIAS_FREQ,
    o None si N < MIN_DIAS.
    """
    mask  = np.isfinite(obs) & np.isfinite(mod)
    obs   = obs[mask]
    mod   = mod[mask]
    N     = len(obs)

    if N < MIN_DIAS:
        return None

    obs_ev = obs >= umbral
    mod_ev = mod >= umbral

    H = int(np.sum( obs_ev &  mod_ev))   # acierto
    M = int(np.sum( obs_ev & ~mod_ev))   # fallo
    F = int(np.sum(~obs_ev &  mod_ev))   # falsa alarma
    C = int(np.sum(~obs_ev & ~mod_ev))   # rechazo correcto

    def _safe(num, den, fallback=np.nan):
        return num / den if den > 0 else fallback

    POD       = _safe(H, H + M)
    FAR       = _safe(F, H + F)
    CSI       = _safe(H, H + M + F)
    POFD      = _safe(F, F + C)          # prob. de falsa detección
    TSS       = POD - POFD               # Pierce Skill Score (Hanssen-Kuipers)
    PC        = _safe(H + C, N)          # Percent Correct
    BIAS_FREQ = _safe(H + F, H + M)     # Frequency Bias (1 = sin sesgo)

    return {
        "N": N, "H": H, "M": M, "F": F, "C": C,
        "POD":  round(POD,  3) if np.isfinite(POD)  else None,
        "FAR":  round(FAR,  3) if np.isfinite(FAR)  else None,
        "CSI":  round(CSI,  3) if np.isfinite(CSI)  else None,
        "TSS":  round(TSS,  3) if np.isfinite(TSS)  else None,
        "PC":   round(PC,   3) if np.isfinite(PC)   else None,
        "BIAS": round(BIAS_FREQ, 3) if np.isfinite(BIAS_FREQ) else None,
    }


# ──────────────────────────────────────────────────────────────────────────────
# LECTURA Y AGRUPACIÓN DE CSV
# ──────────────────────────────────────────────────────────────────────────────

def leer_csvs(directorio: str, ciudades_filtro: list | None, mes_filtro: str | None) -> dict:
    """
    Lee los CSV de eval_*.csv y devuelve:
        datos[mes][ciudad][cont] → DataFrame acumulado (días del mes)
    """
    import glob
    archivos = sorted(glob.glob(os.path.join(directorio, "eval_*.csv")))
    if not archivos:
        sys.exit(f"[ERROR] No se encontraron eval_*.csv en '{directorio}'.")

    datos    = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    n_ok     = 0

    for ruta in archivos:
        meta = parsear_nombre_archivo(ruta)
        if meta is None:
            continue
        cont, ciudad = meta
        if cont not in UMBRALES:
            continue
        if ciudades_filtro and ciudad not in ciudades_filtro:
            continue
        try:
            df = pd.read_csv(ruta, parse_dates=["Fecha"])
        except Exception:
            continue
        cols_req = {"Fecha", "max_obs", "mod_dia1", "mod_dia2", "mod_dia3"}
        if not cols_req.issubset(df.columns):
            continue

        mes = df["Fecha"].dt.strftime("%Y-%m").iloc[0]
        if mes_filtro and mes != mes_filtro:
            continue

        datos[mes][ciudad][cont].append(df)
        n_ok += 1

    print(f"[INFO] Archivos leídos: {n_ok}")
    if n_ok == 0:
        sys.exit("[ERROR] Ningún archivo coincidió con los filtros indicados.")
    return datos


def calcular_resultados(datos: dict) -> dict:
    """
    Calcula los estadísticos dicotómicos para cada mes/ciudad/cont/horizonte.

    Retorna:
        resultados[mes][cont][ciudad][horizonte] → dict estadísticos | None
    """
    resultados = defaultdict(
        lambda: defaultdict(lambda: defaultdict(dict))
    )

    for mes, ciudades in sorted(datos.items()):
        for ciudad, conts in sorted(ciudades.items()):
            for cont, lista_df in sorted(conts.items()):
                umbral = UMBRALES[cont]
                df_mes = pd.concat(lista_df, ignore_index=True).sort_values("Fecha")
                obs    = df_mes["max_obs"].values

                for col, hor_label in HORIZONTES.items():
                    mod = df_mes[col].values
                    st  = contingencia(
                        np.asarray(obs, float),
                        np.asarray(mod, float),
                        umbral,
                    )
                    resultados[mes][cont][ciudad][hor_label] = st

    return resultados


# ──────────────────────────────────────────────────────────────────────────────
# EXPORTAR CSV DE ESTADÍSTICOS (opcional, para auditoría)
# ──────────────────────────────────────────────────────────────────────────────

def exportar_csv(resultados: dict, ruta_csv: str) -> None:
    filas = []
    for mes, conts in sorted(resultados.items()):
        for cont, ciudades in sorted(conts.items()):
            for ciudad, horizontes in sorted(ciudades.items()):
                for hor, st in sorted(horizontes.items()):
                    if st is None:
                        continue
                    fila = {"mes": mes, "contaminante": cont, "ciudad": ciudad,
                            "horizonte": hor}
                    fila.update(st)
                    filas.append(fila)
    if filas:
        pd.DataFrame(filas).to_csv(ruta_csv, index=False)
        print(f"[OK]  CSV de auditoría: {ruta_csv}")


# ──────────────────────────────────────────────────────────────────────────────
# GENERACIÓN DEL DOCUMENTO WORD  (via script Node.js temporal)
# ──────────────────────────────────────────────────────────────────────────────

_NOMBRE_MES = {
    "01": "Enero",   "02": "Febrero",  "03": "Marzo",
    "04": "Abril",   "05": "Mayo",     "06": "Junio",
    "07": "Julio",   "08": "Agosto",   "09": "Septiembre",
    "10": "Octubre", "11": "Noviembre","12": "Diciembre",
}


def _fmt(val, decimals=3) -> str:
    """Formatea un valor numérico o devuelve 'N/D'."""
    if val is None or (isinstance(val, float) and np.isnan(val)):
        return "N/D"
    return f"{val:.{decimals}f}"


def _color_pod(val) -> str:
    if val is None:
        return "808080"
    if val >= 0.7:
        return "1a7a3c"   # verde
    if val >= 0.4:
        return "b8860b"   # ámbar
    return "b22222"       # rojo


def _color_far(val) -> str:
    if val is None:
        return "808080"
    if val <= 0.3:
        return "1a7a3c"
    if val <= 0.5:
        return "b8860b"
    return "b22222"


def _color_csi(val) -> str:
    if val is None:
        return "808080"
    if val >= 0.4:
        return "1a7a3c"
    if val >= 0.2:
        return "b8860b"
    return "b22222"


def generar_json_datos(resultados: dict) -> dict:
    """
    Convierte resultados al formato JSON que consumirá el script Node.js.
    Estructura: { meses: [ { mes, cont_sections: [ { cont, ciudades: [...] } ] } ] }
    """
    meses_out = []

    for mes in sorted(resultados.keys()):
        anio, mm = mes.split("-")
        nombre_mes = _NOMBRE_MES.get(mm, mm)

        cont_sections = []
        for cont in sorted(resultados[mes].keys()):
            meta    = META_CONT[cont]
            umbral  = UMBRALES[cont]
            ciudades_data = []

            for ciudad in sorted(resultados[mes][cont].keys()):
                horizontes_data = []
                for hor_label in ["+24 h", "+48 h", "+72 h"]:
                    st = resultados[mes][cont][ciudad].get(hor_label)
                    if st is None:
                        hd = {"horizonte": hor_label, "valido": False,
                              "N": 0, "H": 0, "M": 0, "F": 0, "C": 0,
                              "POD": None, "FAR": None, "CSI": None,
                              "TSS": None, "PC": None, "BIAS": None}
                    else:
                        hd = {"horizonte": hor_label, "valido": True,
                              **st,
                              "POD_color": _color_pod(st["POD"]),
                              "FAR_color": _color_far(st["FAR"]),
                              "CSI_color": _color_csi(st["CSI"])}
                    horizontes_data.append(hd)

                ciudades_data.append({
                    "ciudad":     ciudad,
                    "horizontes": horizontes_data,
                })

            cont_sections.append({
                "cont":    cont,
                "nombre":  meta["nombre"],
                "unidad":  meta["unidad"],
                "norma":   meta["norma"],
                "umbral":  umbral,
                "desc":    meta["desc"],
                "ciudades": ciudades_data,
            })

        meses_out.append({
            "mes":          mes,
            "nombre_mes":   nombre_mes,
            "anio":         anio,
            "cont_sections": cont_sections,
        })

    return {"meses": meses_out}


NODE_SCRIPT = r"""
// generar_docx.js — generado por informe_dicotomico.py
// Requiere: npm package 'docx' (preinstalado en el entorno)

const {
  Document, Packer, Paragraph, Table, TableRow, TableCell,
  TextRun, HeadingLevel, AlignmentType, WidthType,
  ShadingType, BorderStyle, PageOrientation, Header,
  ImageRun, convertInchesToTwip,
  LevelFormat, VerticalAlign, PageBreak,
} = require('docx');
const fs = require('fs');

// ──────── datos ────────
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const outPath = process.argv[3];

// ──────── helpers ────────
const PAGE_W   = 12240;   // A4 landscape width  (DXA)
const PAGE_H   = 8418;    // A4 landscape height (DXA)
const MARGINS  = { top: 720, bottom: 720, left: 720, right: 720 };
const USABLE_W = PAGE_W - MARGINS.left - MARGINS.right;   // 10800 DXA

function rgb(hex) {
  return hex.replace('#', '');
}

function boldRun(text, size=18, color="000000") {
  return new TextRun({ text, bold: true, size, color });
}
function run(text, size=18, color="000000", italic=false) {
  return new TextRun({ text, size, color, italics: italic });
}

function heading1(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_1,
    spacing: { before: 240, after: 120 },
    children: [new TextRun({ text, bold: true, size: 28, color: "1F497D" })],
  });
}
function heading2(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_2,
    spacing: { before: 200, after: 80 },
    children: [new TextRun({ text, bold: true, size: 24, color: "2E74B5" })],
  });
}
function heading3(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_3,
    spacing: { before: 160, after: 60 },
    children: [new TextRun({ text, bold: true, size: 22, color: "215868" })],
  });
}
function para(text, size=18, spacing={before:60, after:60}) {
  return new Paragraph({
    spacing,
    children: [new TextRun({ text, size })],
  });
}
function paraRuns(runs, spacing={before:60, after:60}) {
  return new Paragraph({ spacing, children: runs });
}

function cellShaded(hex) {
  return { type: ShadingType.CLEAR, color: "auto", fill: hex };
}

// Celda de encabezado de tabla (fondo azul oscuro, texto blanco)
function hdrCell(text, w, span=1) {
  return new TableCell({
    width:  { size: w, type: WidthType.DXA },
    columnSpan: span,
    shading: cellShaded("1F497D"),
    verticalAlign: VerticalAlign.CENTER,
    children: [new Paragraph({
      alignment: AlignmentType.CENTER,
      spacing: { before: 40, after: 40 },
      children: [boldRun(text, 16, "FFFFFF")],
    })],
  });
}

// Celda de subencabezado (fondo azul claro)
function subHdrCell(text, w) {
  return new TableCell({
    width: { size: w, type: WidthType.DXA },
    shading: cellShaded("BDD7EE"),
    verticalAlign: VerticalAlign.CENTER,
    children: [new Paragraph({
      alignment: AlignmentType.CENTER,
      spacing: { before: 30, after: 30 },
      children: [boldRun(text, 15, "1F497D")],
    })],
  });
}

// Celda de dato numérico con color opcional
function dataCell(text, w, color="000000", bgColor="FFFFFF", bold=false) {
  return new TableCell({
    width: { size: w, type: WidthType.DXA },
    shading: cellShaded(bgColor),
    verticalAlign: VerticalAlign.CENTER,
    children: [new Paragraph({
      alignment: AlignmentType.CENTER,
      spacing: { before: 30, after: 30 },
      children: [new TextRun({ text, size: 16, color, bold })],
    })],
  });
}

// Celda de ciudad (primera columna)
function ciudadCell(text, w) {
  return new TableCell({
    width: { size: w, type: WidthType.DXA },
    shading: cellShaded("EBF3FB"),
    verticalAlign: VerticalAlign.CENTER,
    children: [new Paragraph({
      spacing: { before: 30, after: 30 },
      children: [boldRun(text, 16, "215868")],
    })],
  });
}

function fmtVal(val) {
  return (val === null || val === undefined) ? "N/D" : Number(val).toFixed(3);
}

// Colores de semáforo para celdas
function bgPOD(v)  { if(v===null||v===undefined) return "E8E8E8"; return v>=0.7?"C6EFCE":v>=0.4?"FFEB9C":"FFC7CE"; }
function bgFAR(v)  { if(v===null||v===undefined) return "E8E8E8"; return v<=0.3?"C6EFCE":v<=0.5?"FFEB9C":"FFC7CE"; }
function bgCSI(v)  { if(v===null||v===undefined) return "E8E8E8"; return v>=0.4?"C6EFCE":v>=0.2?"FFEB9C":"FFC7CE"; }
function bgTSS(v)  { if(v===null||v===undefined) return "E8E8E8"; return v>=0.4?"C6EFCE":v>=0.1?"FFEB9C":"FFC7CE"; }
function bgBIAS(v) { if(v===null||v===undefined) return "E8E8E8";
  const b = Math.abs(v - 1.0);
  return b<=0.3?"C6EFCE":b<=0.6?"FFEB9C":"FFC7CE";
}

// ──────── construcción de tabla por contaminante ────────
//
// Layout (landscape A4, USABLE_W = 10 800 DXA):
//   Ciudad (1400) | H+M+F+C (600) | [+24h: POD FAR CSI TSS PC BIAS] | [+48h] | [+72h]
//   Columnas de estadísticos: 6 × 3 horizontes = 18 cols × ~500 DXA = 9 000
//   Total: 1400 + 600 + 9000 = 11000 → ajustamos a 10800

const W_CIUDAD = 1400;
const W_N      = 600;
const W_STAT   = 492;   // 6 stats × 3 horizontes × 492 ≈ 8856 → total 10856 ≈ 10800 (ajuste fino)
const STATS    = ["POD", "FAR", "CSI", "TSS", "PC", "BIAS"];
const BG_FN    = { POD: bgPOD, FAR: bgFAR, CSI: bgCSI, TSS: bgTSS, PC: ()=>"FFFFFF", BIAS: bgBIAS };

function buildTable(contSection) {
  const HORS = ["+24 h", "+48 h", "+72 h"];
  const rows = [];

  // ── Fila 1: encabezado principal ──────────────────────────────────────────
  const hdrCells1 = [
    hdrCell("Ciudad",    W_CIUDAD),
    hdrCell("N días",    W_N),
  ];
  for (const hor of HORS) {
    hdrCells1.push(hdrCell(hor, W_STAT * STATS.length, STATS.length));
  }
  rows.push(new TableRow({ tableHeader: true, children: hdrCells1 }));

  // ── Fila 2: subencabezado (nombres de estadísticos) ───────────────────────
  const hdrCells2 = [
    subHdrCell("",       W_CIUDAD),
    subHdrCell("",       W_N),
  ];
  for (let i = 0; i < 3; i++) {
    for (const s of STATS) {
      hdrCells2.push(subHdrCell(s, W_STAT));
    }
  }
  rows.push(new TableRow({ tableHeader: true, children: hdrCells2 }));

  // ── Filas de datos por ciudad ─────────────────────────────────────────────
  for (const cd of contSection.ciudades) {
    // N total: tomar el horizonte +24h como referencia (tiene más días)
    const h24 = cd.horizontes.find(h => h.horizonte === "+24 h");
    const nTotal = (h24 && h24.valido) ? String(h24.N) : "—";

    const cells = [
      ciudadCell(cd.ciudad, W_CIUDAD),
      dataCell(nTotal, W_N, "215868", "EBF3FB", true),
    ];

    for (const hor of HORS) {
      const hd = cd.horizontes.find(h => h.horizonte === hor) || {};
      for (const stat of STATS) {
        const val = hd.valido ? hd[stat] : null;
        const bg  = BG_FN[stat](val);
        cells.push(dataCell(fmtVal(val), W_STAT, "222222", bg));
      }
    }
    rows.push(new TableRow({ children: cells }));
  }

  return new Table({
    width: { size: USABLE_W, type: WidthType.DXA },
    columnWidths: [
      W_CIUDAD, W_N,
      ...Array(STATS.length * 3).fill(W_STAT),
    ],
    rows,
  });
}

// ──────── tabla de contingencia por ciudad (detalle) ────────
function buildContingencyTable(contSection) {
  const HORS = ["+24 h", "+48 h", "+72 h"];
  const rows = [];

  // Encabezado
  const hc = [
    hdrCell("Ciudad",  W_CIUDAD),
    ...HORS.map(h => hdrCell(h, W_N * 4, 4)),
  ];
  rows.push(new TableRow({ tableHeader: true, children: hc }));

  // Sub-encabezado H M F C
  const hc2 = [subHdrCell("", W_CIUDAD)];
  for (let i = 0; i < 3; i++) {
    for (const lbl of ["H", "M", "F", "C"]) {
      hc2.push(subHdrCell(lbl, W_N));
    }
  }
  rows.push(new TableRow({ tableHeader: true, children: hc2 }));

  for (const cd of contSection.ciudades) {
    const cells = [ciudadCell(cd.ciudad, W_CIUDAD)];
    for (const hor of HORS) {
      const hd = cd.horizontes.find(h => h.horizonte === hor) || {};
      for (const lbl of ["H", "M", "F", "C"]) {
        const val = hd.valido ? String(hd[lbl]) : "—";
        const bg  = lbl === "H" ? "C6EFCE" : lbl === "M" || lbl === "F" ? "FFC7CE" : "FFFFFF";
        cells.push(dataCell(val, W_N, "222222", bg));
      }
    }
    rows.push(new TableRow({ children: cells }));
  }

  return new Table({
    width: { size: USABLE_W, type: WidthType.DXA },
    columnWidths: [W_CIUDAD, ...Array(12).fill(W_N)],
    rows,
  });
}

// ──────── leyenda de semáforo ────────
function buildLeyendaTable() {
  const rows = [];
  const items = [
    { stat: "POD", verde: "≥ 0.700", ambar: "0.400 – 0.699", rojo: "< 0.400" },
    { stat: "FAR", verde: "≤ 0.300", ambar: "0.301 – 0.500", rojo: "> 0.500" },
    { stat: "CSI", verde: "≥ 0.400", ambar: "0.200 – 0.399", rojo: "< 0.200" },
    { stat: "TSS", verde: "≥ 0.400", ambar: "0.100 – 0.399", rojo: "< 0.100" },
    { stat: "BIAS", verde: "|BIAS-1| ≤ 0.3", ambar: "0.3 – 0.6", rojo: "> 0.6" },
  ];
  rows.push(new TableRow({ tableHeader: true, children: [
    hdrCell("Métrica", 1000),
    hdrCell("🟢  Bueno", 2600),
    hdrCell("🟡  Aceptable", 2600),
    hdrCell("🔴  Deficiente", 2600),
  ]}));
  for (const it of items) {
    rows.push(new TableRow({ children: [
      ciudadCell(it.stat, 1000),
      dataCell(it.verde, 2600, "1a7a3c", "C6EFCE"),
      dataCell(it.ambar, 2600, "7d5a00", "FFEB9C"),
      dataCell(it.rojo,  2600, "9c1b1b", "FFC7CE"),
    ]}));
  }
  return new Table({
    width: { size: 8800, type: WidthType.DXA },
    columnWidths: [1000, 2600, 2600, 2600],
    rows,
  });
}

// ──────── sección de definición de métricas ────────
function defMetricas() {
  const elems = [
    heading2("Definición de estadísticos dicotómicos"),
    para(
      "Los estadísticos dicotómicos se calculan a partir de una tabla de contingencia 2×2 " +
      "en la que cada día se clasifica según si el valor observado y el modelado superaron " +
      "o no el umbral normativo del contaminante.",
      18, { before: 60, after: 80 }
    ),
  ];

  // Tabla de contingencia conceptual
  const W2 = [1600, 2800, 2800];
  const hRow = new TableRow({ tableHeader: true, children: [
    hdrCell("",                 W2[0]),
    hdrCell("Obs. EVENTO",      W2[1]),
    hdrCell("Obs. NO EVENTO",   W2[2]),
  ]});
  const r1 = new TableRow({ children: [
    ciudadCell("Mod. EVENTO",    W2[0]),
    dataCell("H — Acierto",      W2[1], "1a7a3c", "C6EFCE", true),
    dataCell("F — Falsa Alarma", W2[2], "9c1b1b", "FFC7CE", true),
  ]});
  const r2 = new TableRow({ children: [
    ciudadCell("Mod. NO EVENTO", W2[0]),
    dataCell("M — Fallo",        W2[1], "9c1b1b", "FFC7CE", true),
    dataCell("C — Rechazo Corr.",W2[2], "1a7a3c", "C6EFCE", true),
  ]});
  elems.push(new Table({
    width: { size: 7200, type: WidthType.DXA },
    columnWidths: W2,
    rows: [hRow, r1, r2],
  }));
  elems.push(para(""));

  const defs = [
    ["POD",  "= H / (H + M)",          "Probabilidad de detección (Probability of Detection). Fracción de eventos observados que el modelo detecta correctamente. Ideal = 1."],
    ["FAR",  "= F / (H + F)",           "Tasa de falsas alarmas (False Alarm Ratio). Fracción de eventos modelados que no ocurrieron. Ideal = 0."],
    ["CSI",  "= H / (H + M + F)",       "Índice de éxito crítico (Critical Success Index). Combina fallos y falsas alarmas; no considera rechazos correctos. Ideal = 1."],
    ["TSS",  "= POD − F/(F+C)",         "Pierce Skill Score (Hanssen-Kuipers discriminant). Diferencia entre tasa de detección y tasa de falsa detección. Rango [−1, 1]; ideal = 1."],
    ["PC",   "= (H + C) / N",           "Porcentaje correcto (Percent Correct). Fracción de días clasificados correctamente. Ideal = 1; puede ser engañoso cuando los eventos son raros."],
    ["BIAS", "= (H + F) / (H + M)",     "Sesgo de frecuencia (Frequency Bias). Cociente entre número de eventos pronosticados y observados. Ideal = 1; >1 sobreestima eventos; <1 los subestima."],
  ];
  for (const [nombre, formula, desc] of defs) {
    elems.push(paraRuns([
      boldRun(nombre + " ", 18),
      new TextRun({ text: formula, size: 18, italics: true, color: "1F497D" }),
    ], { before: 60, after: 20 }));
    elems.push(para("    " + desc, 17, { before: 20, after: 50 }));
  }
  return elems;
}

// ──────── Construcción del documento ────────
async function main() {
  const children = [];

  // ── Portada ──────────────────────────────────────────────────────────────
  children.push(new Paragraph({
    alignment: AlignmentType.CENTER,
    spacing: { before: 1440, after: 240 },
    children: [boldRun("EVALUACIÓN DICOTÓMICA MENSUAL DEL PRONÓSTICO", 36, "1F497D")],
  }));
  children.push(new Paragraph({
    alignment: AlignmentType.CENTER,
    spacing: { before: 0, after: 120 },
    children: [boldRun("WRF-Chem vs SINAICA/INECC", 28, "2E74B5")],
  }));
  children.push(new Paragraph({
    alignment: AlignmentType.CENTER,
    spacing: { before: 120, after: 120 },
    children: [run("Centro de México — Ocho zonas metropolitanas", 22, "215868")],
  }));
  children.push(new Paragraph({
    alignment: AlignmentType.CENTER,
    spacing: { before: 60, after: 60 },
    children: [run(
      data.meses.map(m => m.nombre_mes + " " + m.anio).join("  ·  "),
      20, "444444"
    )],
  }));
  children.push(new Paragraph({
    alignment: AlignmentType.CENTER,
    spacing: { before: 60, after: 60 },
    children: [run("Generado automáticamente por informe_dicotomico.py — ddsinaica / ICAyCC, UNAM", 16, "888888")],
  }));
  // Separador
  children.push(new Paragraph({
    border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: "2E74B5" } },
    spacing: { before: 240, after: 240 },
    children: [],
  }));

  // ── Resumen metodológico ─────────────────────────────────────────────────
  children.push(heading1("1. Introducción y metodología"));
  children.push(para(
    "El presente informe resume el desempeño del sistema de pronóstico de calidad " +
    "del aire WRF-Chem en la detección de episodios de contaminación (excedencias de " +
    "la norma) para cuatro contaminantes regulados en ocho zonas metropolitanas del " +
    "centro de México. La evaluación se realiza mediante estadísticos dicotómicos " +
    "calculados sobre la tabla de contingencia 2×2, comparando si el máximo diario " +
    "observado y el modelado superan o no el umbral normativo del contaminante.",
    18, { before: 80, after: 80 }
  ));

  // Tabla de umbrales
  children.push(heading2("Umbrales normativos empleados"));
  const WU = [2200, 1400, 1400, 3800];
  const uRows = [
    new TableRow({ tableHeader: true, children: [
      hdrCell("Contaminante",  WU[0]),
      hdrCell("Umbral",        WU[1]),
      hdrCell("Unidad",        WU[2]),
      hdrCell("Norma",         WU[3]),
    ]}),
    ...data.meses[0].cont_sections.map(cs => new TableRow({ children: [
      ciudadCell(cs.nombre, WU[0]),
      dataCell(String(cs.umbral), WU[1], "1F497D", "EBF3FB", true),
      dataCell(cs.unidad,         WU[2]),
      dataCell(cs.norma,          WU[3]),
    ]})),
  ];
  children.push(new Table({
    width: { size: 8800, type: WidthType.DXA },
    columnWidths: WU,
    rows: uRows,
  }));
  children.push(para(""));

  // Definición de métricas
  for (const e of defMetricas()) children.push(e);

  // Leyenda
  children.push(heading2("Leyenda de semáforo de desempeño"));
  children.push(buildLeyendaTable());
  children.push(para(""));

  // ── Resultados por mes → contaminante ────────────────────────────────────
  let secNum = 2;
  for (const mesData of data.meses) {
    // Salto de página antes de cada mes (excepto el primero)
    children.push(new Paragraph({
      children: [new PageBreak()],
    }));
    children.push(heading1(
      `${secNum}. Resultados — ${mesData.nombre_mes} ${mesData.anio}`
    ));
    secNum++;

    let subNum = 1;
    for (const cs of mesData.cont_sections) {
      children.push(heading2(
        `${secNum - 1}.${subNum}  ${cs.nombre}  (umbral: ${cs.umbral} ${cs.unidad}, ${cs.norma})`
      ));
      children.push(para(cs.desc, 17, { before: 40, after: 80 }));

      // Tabla principal de estadísticos
      children.push(heading3("Estadísticos de verificación dicotómica"));
      children.push(buildTable(cs));
      children.push(para(""));

      // Tabla de contingencia (H M F C)
      children.push(heading3("Tabla de contingencia (H, M, F, C)"));
      children.push(buildContingencyTable(cs));
      children.push(para("",18,{before:0,after:80}));

      subNum++;
    }
  }

  // ── Notas finales ─────────────────────────────────────────────────────────
  children.push(new Paragraph({ children: [new PageBreak()] }));
  children.push(heading1("Notas técnicas"));
  children.push(para(
    "• Los valores N/D indican que no se alcanzó el mínimo de días con datos " +
    "necesarios para el cálculo (≥5 pares obs/mod válidos).",
    17, { before: 60, after: 40 }
  ));
  children.push(para(
    "• El horizonte +72 h cubre solo 18 h de la ventana local (índices 54–71 " +
    "del wrfout) por la alineación UTC−6 con el inicio del run.",
    17, { before: 40, after: 40 }
  ));
  children.push(para(
    "• BIAS = 1 indica que el modelo pronosticó el mismo número de eventos que " +
    "los observados (sin importar la coincidencia día a día). BIAS > 1 indica " +
    "sobreestimación de la frecuencia; BIAS < 1, subestimación.",
    17, { before: 40, after: 40 }
  ));
  children.push(para(
    "• Las observaciones provienen de la red SINAICA/INECC; los valores del modelo " +
    "corresponden al máximo diario extraído del dominio WRF-Chem sobre la " +
    "región de cada ciudad (máximo espacial).",
    17, { before: 40, after: 40 }
  ));
  children.push(para(
    "• Generado con: informe_dicotomico.py (ddsinaica v2.5.0) — " +
    "ICAyCC, UNAM. Código disponible en https://github.com/JoseAgustin/ddsinaica",
    16, { before: 60, after: 40 }
  ));

  // ── Armar documento ───────────────────────────────────────────────────────
  const doc = new Document({
    styles: {
      paragraphStyles: [
        {
          id: "Normal",
          name: "Normal",
          run: { font: "Calibri", size: 18 },
        },
      ],
    },
    sections: [{
      properties: {
        page: {
          size:        { width: PAGE_W, height: PAGE_H, orientation: PageOrientation.LANDSCAPE },
          margin:      MARGINS,
        },
      },
      headers: {
        default: new Header({
          children: [new Paragraph({
            alignment: AlignmentType.RIGHT,
            border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: "2E74B5" } },
            children: [
              new TextRun({ text: "Evaluación Dicotómica WRF-Chem vs SINAICA  |  ICAyCC, UNAM", size: 14, color: "888888" }),
            ],
          })],
        }),
      },
      children,
    }],
  });

  const buf = await Packer.toBuffer(doc);
  fs.writeFileSync(outPath, buf);
  console.log("[OK] Documento generado: " + outPath);
}

main().catch(e => { console.error(e); process.exit(1); });
"""


def generar_docx(resultados: dict, ruta_salida: str) -> None:
    """Serializa los resultados a JSON, llama al script Node.js y genera el .docx."""

    datos_json = generar_json_datos(resultados)

    with tempfile.TemporaryDirectory() as tmpdir:
        ruta_json = os.path.join(tmpdir, "datos.json")
        ruta_js   = os.path.join(tmpdir, "generar_docx.js")

        with open(ruta_json, "w", encoding="utf-8") as f:
            json.dump(datos_json, f, ensure_ascii=False, indent=2)
        with open(ruta_js, "w", encoding="utf-8") as f:
            f.write(NODE_SCRIPT)

        result = subprocess.run(
            ["node", ruta_js, ruta_json, os.path.abspath(ruta_salida)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print("[ERROR] Node.js:", result.stderr)
            sys.exit(1)
        print(result.stdout.strip())


# ──────────────────────────────────────────────────────────────────────────────
# PUNTO DE ENTRADA
# ──────────────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(
        prog="informe_dicotomico.py",
        description=(
            "Genera un informe Word (.docx) con estadísticos dicotómicos "
            "mensuales (POD, FAR, CSI, TSS, PC, BIAS) para la evaluación "
            "WRF-Chem vs SINAICA/INECC."
        ),
    )
    p.add_argument("--entrada", "-i", default="combinado/ajustados",
                   help="Directorio con CSV eval_*.csv (default: combinado/ajustados)")
    p.add_argument("--salida",  "-o", default="informe_dicotomico.docx",
                   help="Ruta del .docx de salida")
    p.add_argument("--mes",     "-m", default=None,
                   help="Procesar solo este mes (YYYY-MM)")
    p.add_argument("--ciudades","-c", nargs="+", default=None,
                   help=f"Ciudades a incluir. Catálogo: {', '.join(CIUDADES_DOMINIO)}")
    p.add_argument("--csv-auditoria", default=None,
                   help="Ruta opcional para exportar un CSV con todos los estadísticos")
    return p.parse_args()


def main():
    args            = parse_args()
    ciudades_filtro = parsear_lista_ciudades(args.ciudades)

    print("=" * 58)
    print("  Informe Dicotómico — WRF-Chem / SINAICA")
    print("=" * 58)
    print(f"  Entrada : {args.entrada}")
    print(f"  Salida  : {args.salida}")
    print(f"  Mes     : {args.mes or 'todos'}")
    print(f"  Ciudades: {ciudades_filtro or 'todas'}")
    print("=" * 58)

    datos      = leer_csvs(args.entrada, ciudades_filtro, args.mes)
    resultados = calcular_resultados(datos)

    if args.csv_auditoria:
        exportar_csv(resultados, args.csv_auditoria)

    generar_docx(resultados, args.salida)
    print(f"[DONE] {args.salida}")


if __name__ == "__main__":
    main()

