#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
informe_dicotomico.py
=====================
Calcula estadísticos dicotómicos mensuales (POD, FAR, CSI, TSS, PC, BIAS_DICHO)
a partir de los CSV diarios de `combinado/ajustados/` y genera un documento
Word (.docx) con los resultados organizados por contaminante y ciudad utilizando
exclusivamente `python-docx` con tablas autoajustadas a la ventana.

Contaminantes evaluados y umbrales normativos:
    O3   — 135 ppbv        (NOM-020-SSA1)
    PM10 — 75 µg/m³        (NOM-025-SSA1-2021)
    PM25 — 45 µg/m³        (NOM-025-SSA1-2021)
    SO2  — 130 ppbv        (NOM-022-SSA1-2010)

Estadísticos de la tabla de contingencia 2×2 (evento = valor ≥ umbral):
    H  — acierto          (obs evento,    mod evento)
    M  — fallo            (obs evento,    mod no-evento)
    F  — falsa alarma     (obs no-evento, mod evento)
    C  — rechazo correcto (obs no-evento, mod no-evento)

    POD  = H / (H + M)          Probabilidad de detección
    FAR  = F / (H + F)          Tasa de falsas alarmas
    CSI  = H / (H + M + F)      Índice de éxito crítico (Threat Score)
    TSS  = H/(H+M) − F/(F+C)    Pierce Skill Score  (Hanssen-Kuipers discriminant)
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
    pip install pandas numpy python-docx

Autor  : Pipeline ddsinaica / WRF-Chem — ICAyCC, UNAM
Versión: 2.1.0 (2026-07) — Tablas autoajustadas a la ventana
"""

import argparse
import glob
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd

# Dependencias de python-docx
import docx
from docx import Document
from docx.enum.section import WD_ORIENT
from docx.enum.table import WD_ALIGN_VERTICAL, WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import parse_xml
from docx.oxml.ns import nsdecls
from docx.shared import Inches, Pt, RGBColor


# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURACIÓN GLOBAL
# ──────────────────────────────────────────────────────────────────────────────

UMBRALES = {
    "O3":   135.0,   # ppbv      NOM-020-SSA1
    "PM10": 75.0,    # µg/m³     NOM-025-SSA1-2021
    "PM25": 45.0,    # µg/m³     NOM-025-SSA1-2021
    "SO2":  130.0,   # ppbv      NOM-022-SSA1-2010
}

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
            "Umbral: 130 ppbv en promedio de 24 h (NOM-022-SSA1-2010)."
        ),
    },
}

CIUDADES_DOMINIO = [
    "CDMX", "Cuernavaca", "Pachuca", "Puebla",
    "SJdelRio", "Tlaxcala", "Toluca", "Tula",
]
_CIUDADES_NORM = {c.lower(): c for c in CIUDADES_DOMINIO}
_CIUDADES_NORM.update({
    "sjdelrio":         "SJdelRio",
    "san juan del rio": "SJdelRio",
    "cdmx":             "CDMX",
    "ciudad de mexico": "CDMX",
})

HORIZONTES = {"mod_dia1": "+24 h", "mod_dia2": "+48 h", "mod_dia3": "+72 h"}
MIN_DIAS = 5

_NOMBRE_MES = {
    "01": "Enero",   "02": "Febrero",  "03": "Marzo",
    "04": "Abril",   "05": "Mayo",     "06": "Junio",
    "07": "Julio",   "08": "Agosto",   "09": "Septiembre",
    "10": "Octubre", "11": "Noviembre","12": "Diciembre",
}


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
    nombre = Path(ruta).stem
    m = re.match(r"^eval_([A-Za-z0-9]+)_(.+)_\d{4}-\d{2}-\d{2}$", nombre)
    if not m:
        return None
    cont   = m.group(1).upper()
    ciudad = normalizar_ciudad(m.group(2)) or m.group(2)
    return cont, ciudad


def _fmt(val, decimals=3) -> str:
    if val is None or (isinstance(val, float) and np.isnan(val)):
        return "N/D"
    return f"{val:.{decimals}f}"


# Colores semáforo
def bg_pod(v):
    if v is None: return "E8E8E8"
    return "C6EFCE" if v >= 0.7 else ("FFEB9C" if v >= 0.4 else "FFC7CE")

def bg_far(v):
    if v is None: return "E8E8E8"
    return "C6EFCE" if v <= 0.3 else ("FFEB9C" if v <= 0.5 else "FFC7CE")

def bg_csi(v):
    if v is None: return "E8E8E8"
    return "C6EFCE" if v >= 0.4 else ("FFEB9C" if v >= 0.2 else "FFC7CE")

def bg_tss(v):
    if v is None: return "E8E8E8"
    return "C6EFCE" if v >= 0.4 else ("FFEB9C" if v >= 0.1 else "FFC7CE")

def bg_bias(v):
    if v is None: return "E8E8E8"
    b = abs(v - 1.0)
    return "C6EFCE" if b <= 0.3 else ("FFEB9C" if b <= 0.6 else "FFC7CE")

BG_FN = {
    "POD": bg_pod, "FAR": bg_far, "CSI": bg_csi,
    "TSS": bg_tss, "PC": lambda v: "FFFFFF", "BIAS": bg_bias
}


# ──────────────────────────────────────────────────────────────────────────────
# CÁLCULO DE ESTADÍSTICOS
# ──────────────────────────────────────────────────────────────────────────────

def contingencia(obs: np.ndarray, mod: np.ndarray, umbral: float) -> dict | None:
    mask = np.isfinite(obs) & np.isfinite(mod)
    obs  = obs[mask]
    mod  = mod[mask]
    N    = len(obs)

    if N < MIN_DIAS:
        return None

    obs_ev = obs >= umbral
    mod_ev = mod >= umbral

    H = int(np.sum( obs_ev &  mod_ev))
    M = int(np.sum( obs_ev & ~mod_ev))
    F = int(np.sum(~obs_ev &  mod_ev))
    C = int(np.sum(~obs_ev & ~mod_ev))

    def _safe(num, den, fallback=np.nan):
        return num / den if den > 0 else fallback

    POD       = _safe(H, H + M)
    FAR       = _safe(F, H + F)
    CSI       = _safe(H, H + M + F)
    POFD      = _safe(F, F + C)
    TSS       = POD - POFD
    PC        = _safe(H + C, N)
    BIAS_FREQ = _safe(H + F, H + M)

    return {
        "N": N, "H": H, "M": M, "F": F, "C": C,
        "POD":  round(POD,  3) if np.isfinite(POD)  else None,
        "FAR":  round(FAR,  3) if np.isfinite(FAR)  else None,
        "CSI":  round(CSI,  3) if np.isfinite(CSI)  else None,
        "TSS":  round(TSS,  3) if np.isfinite(TSS)  else None,
        "PC":   round(PC,   3) if np.isfinite(PC)   else None,
        "BIAS": round(BIAS_FREQ, 3) if np.isfinite(BIAS_FREQ) else None,
    }


def leer_csvs(directorio: str, ciudades_filtro: list | None, mes_filtro: str | None) -> dict:
    archivos = sorted(glob.glob(os.path.join(directorio, "eval_*.csv")))
    if not archivos:
        sys.exit(f"[ERROR] No se encontraron eval_*.csv en '{directorio}'.")

    datos = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    n_ok = 0

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
    resultados = defaultdict(lambda: defaultdict(lambda: defaultdict(dict)))

    for mes, ciudades in sorted(datos.items()):
        for ciudad, conts in sorted(ciudades.items()):
            for cont, lista_df in sorted(conts.items()):
                umbral = UMBRALES[cont]
                df_mes = pd.concat(lista_df, ignore_index=True).sort_values("Fecha")
                obs    = df_mes["max_obs"].values

                for col, hor_label in HORIZONTES.items():
                    mod = df_mes[col].values
                    st  = contingencia(np.asarray(obs, float), np.asarray(mod, float), umbral)
                    resultados[mes][cont][ciudad][hor_label] = st

    return resultados


def exportar_csv(resultados: dict, ruta_csv: str) -> None:
    filas = []
    for mes, conts in sorted(resultados.items()):
        for cont, ciudades in sorted(conts.items()):
            for ciudad, horizontes in sorted(ciudades.items()):
                for hor, st in sorted(horizontes.items()):
                    if st is None:
                        continue
                    fila = {"mes": mes, "contaminante": cont, "ciudad": ciudad, "horizonte": hor}
                    fila.update(st)
                    filas.append(fila)
    if filas:
        pd.DataFrame(filas).to_csv(ruta_csv, index=False)
        print(f"[OK]  CSV de auditoría: {ruta_csv}")


# ──────────────────────────────────────────────────────────────────────────────
# GENERACIÓN DE DOCUMENTO WORD (PYTHON-DOCX)
# ──────────────────────────────────────────────────────────────────────────────

def set_cell_background(cell, hex_color: str):
    if not hex_color:
        return
    shading = parse_xml(f'<w:shd {nsdecls("w")} w:fill="{hex_color}"/>')
    cell._tc.get_or_add_tcPr().append(shading)

def set_repeat_header(row):
    trPr = row._tr.get_or_add_trPr()
    trPr.append(parse_xml(f'<w:tblHeader {nsdecls("w")}/>'))

def set_cant_split(row):
    trPr = row._tr.get_or_add_trPr()
    trPr.append(parse_xml(f'<w:cantSplit {nsdecls("w")}/>'))

def format_cell(cell, text: str, font_size=8, bold=False, color="000000", bg_color="FFFFFF", align=WD_ALIGN_PARAGRAPH.CENTER, width=None):
    if width is not None:
        cell.width = width
    set_cell_background(cell, bg_color)
    cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER

    p = cell.paragraphs[0]
    p.alignment = align
    p.paragraph_format.space_before = Pt(2)
    p.paragraph_format.space_after = Pt(2)

    run = p.add_run(text)
    run.font.name = "Calibri"
    run.font.size = Pt(font_size)
    run.font.bold = bold
    run.font.color.rgb = RGBColor.from_string(color)
    return cell

def create_styled_table(doc, rows: int, cols: int):
    """Crea una tabla estilizada configurada para autoajustarse a la ventana."""
    table = doc.add_table(rows=rows, cols=cols)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = True

    # Forzar ancho al 100% de la ventana (entre márgenes) y autoajuste dinámico OpenXML
    tblPr = table._tbl.tblPr
    for child in list(tblPr):
        if child.tag.endswith('tblW') or child.tag.endswith('tblLayout'):
            tblPr.remove(child)
            
    tblW = parse_xml(f'<w:tblW {nsdecls("w")} w:w="5000" w:type="pct"/>')
    tblLayout = parse_xml(f'<w:tblLayout {nsdecls("w")} w:type="autofit"/>')
    tblPr.append(tblW)
    tblPr.append(tblLayout)

    return table

def add_heading_1(doc, text: str):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(12)
    p.paragraph_format.space_after = Pt(6)
    p.paragraph_format.keep_with_next = True
    run = p.add_run(text)
    run.font.name = "Calibri"
    run.font.size = Pt(14)
    run.font.bold = True
    run.font.color.rgb = RGBColor.from_string("1F497D")
    return p

def add_heading_2(doc, text: str):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(10)
    p.paragraph_format.space_after = Pt(4)
    p.paragraph_format.keep_with_next = True
    run = p.add_run(text)
    run.font.name = "Calibri"
    run.font.size = Pt(12)
    run.font.bold = True
    run.font.color.rgb = RGBColor.from_string("2E74B5")
    return p

def add_heading_3(doc, text: str):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(8)
    p.paragraph_format.space_after = Pt(3)
    p.paragraph_format.keep_with_next = True
    run = p.add_run(text)
    run.font.name = "Calibri"
    run.font.size = Pt(11)
    run.font.bold = True
    run.font.color.rgb = RGBColor.from_string("215868")
    return p

def add_para(doc, text: str, size=9, space_before=3, space_after=3, italic=False, bold=False):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(space_before)
    p.paragraph_format.space_after = Pt(space_after)
    run = p.add_run(text)
    run.font.name = "Calibri"
    run.font.size = Pt(size)
    run.font.italic = italic
    run.font.bold = bold
    return p


def generar_docx(resultados: dict, ruta_salida: str) -> None:
    doc = Document()

    # Configuración de página (Horizontal / Letter)
    section = doc.sections[0]
    section.orientation = WD_ORIENT.LANDSCAPE
    section.page_width = Inches(8.5)
    section.page_height = Inches(11.)
    section.top_margin = Inches(0.5)
    section.bottom_margin = Inches(0.5)
    section.left_margin = Inches(0.6)
    section.right_margin = Inches(0.6)

    # Encabezado
    header = section.header
    hp = header.paragraphs[0]
    hp.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    hrun = hp.add_run("Evaluación Dicotómica WRF-Chem vs SINAICA  |  ICAyCC, UNAM")
    hrun.font.name = "Calibri"
    hrun.font.size = Pt(8)
    hrun.font.color.rgb = RGBColor.from_string("888888")

    # ── Portada ──────────────────────────────────────────────────────────────
    p_title = doc.add_paragraph()
    p_title.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_title.paragraph_format.space_before = Pt(36)
    p_title.paragraph_format.space_after = Pt(12)
    r_title = p_title.add_run("EVALUACIÓN DICOTÓMICA MENSUAL DEL PRONÓSTICO")
    r_title.font.name = "Calibri"
    r_title.font.size = Pt(18)
    r_title.font.bold = True
    r_title.font.color.rgb = RGBColor.from_string("1F497D")

    p_sub = doc.add_paragraph()
    p_sub.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_sub.paragraph_format.space_before = Pt(0)
    p_sub.paragraph_format.space_after = Pt(6)
    r_sub = p_sub.add_run("WRF-Chem vs SINAICA/INECC")
    r_sub.font.name = "Calibri"
    r_sub.font.size = Pt(14)
    r_sub.font.bold = True
    r_sub.font.color.rgb = RGBColor.from_string("2E74B5")

    p_reg = doc.add_paragraph()
    p_reg.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_reg.paragraph_format.space_before = Pt(6)
    p_reg.paragraph_format.space_after = Pt(6)
    r_reg = p_reg.add_run("Centro de México — Ocho zonas metropolitanas")
    r_reg.font.name = "Calibri"
    r_reg.font.size = Pt(11)
    r_reg.font.color.rgb = RGBColor.from_string("215868")

    meses_txt = []
    for m in sorted(resultados.keys()):
        a, mm = m.split("-")
        meses_txt.append(f"{_NOMBRE_MES.get(mm, mm)} {a}")

    p_meses = doc.add_paragraph()
    p_meses.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_meses.paragraph_format.space_before = Pt(3)
    p_meses.paragraph_format.space_after = Pt(3)
    r_m = p_meses.add_run("  ·  ".join(meses_txt))
    r_m.font.name = "Calibri"
    r_m.font.size = Pt(10)
    r_m.font.color.rgb = RGBColor.from_string("444444")

    p_gen = doc.add_paragraph()
    p_gen.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_gen.paragraph_format.space_before = Pt(3)
    p_gen.paragraph_format.space_after = Pt(12)
    r_g = p_gen.add_run("Generado automáticamente por informe_dicotomico.py — ddsinaica / ICAyCC, UNAM")
    r_g.font.name = "Calibri"
    r_g.font.size = Pt(8)
    r_g.font.color.rgb = RGBColor.from_string("888888")

    # ── 1. Introducción y metodología ────────────────────────────────────────
    add_heading_1(doc, "1. Introducción y metodología")
    add_para(
        doc,
        "El presente informe resume el desempeño del sistema de pronóstico de calidad "
        "del aire WRF-Chem en la detección de episodios de contaminación (excedencias de "
        "la norma) para cuatro contaminantes regulados en ocho zonas metropolitanas del "
        "centro de México. La evaluación se realiza mediante estadísticos dicotómicos "
        "calculados sobre la tabla de contingencia 2×2, comparando si el máximo diario "
        "observado y el modelado superan o no el umbral normativo del contaminante.",
        size=9, space_before=4, space_after=4
    )

    add_heading_2(doc, "Umbrales normativos empleados")
    t_umb = create_styled_table(doc, rows=1 + len(UMBRALES), cols=4)
    t_umb.style = 'Table Grid'
    
    headers_u = ["Contaminante", "Umbral", "Unidad", "Norma"]
    widths_u = [Inches(2.2), Inches(1.4), Inches(1.4), Inches(3.8)]
    for j, h in enumerate(headers_u):
        format_cell(t_umb.cell(0, j), h, font_size=8, bold=True, color="FFFFFF", bg_color="1F497D", width=widths_u[j])
    set_repeat_header(t_umb.rows[0])
    set_cant_split(t_umb.rows[0])

    for i, (cont, meta) in enumerate(META_CONT.items(), start=1):
        row = t_umb.rows[i]
        format_cell(row.cells[0], meta["nombre"], font_size=8, bold=True, color="215868", bg_color="EBF3FB", align=WD_ALIGN_PARAGRAPH.LEFT, width=widths_u[0])
        format_cell(row.cells[1], str(UMBRALES[cont]), font_size=8, bold=True, color="1F497D", bg_color="EBF3FB", width=widths_u[1])
        format_cell(row.cells[2], meta["unidad"], font_size=8, color="000000", width=widths_u[2])
        format_cell(row.cells[3], meta["norma"], font_size=8, color="000000", align=WD_ALIGN_PARAGRAPH.LEFT, width=widths_u[3])
        set_cant_split(row)

    add_para(doc, "", size=6)

    add_heading_2(doc, "Definición de estadísticos dicotómicos")
    add_para(
        doc,
        "Los estadísticos dicotómicos se calculan a partir de una tabla de contingencia 2×2 "
        "en la que cada día se clasifica según si el valor observado y el modelado superaron "
        "o no el umbral normativo del contaminante.",
        size=9, space_before=3, space_after=4
    )

    # Contingencia conceptual
    t_concept = create_styled_table(doc, rows=3, cols=3)
    t_concept.style = 'Table Grid'
    widths_c = [Inches(2.0), Inches(2.8), Inches(2.8)]
    
    format_cell(t_concept.cell(0, 0), "", font_size=8, bg_color="1F497D", width=widths_c[0])
    format_cell(t_concept.cell(0, 1), "Obs. EVENTO", font_size=8, bold=True, color="FFFFFF", bg_color="1F497D", width=widths_c[1])
    format_cell(t_concept.cell(0, 2), "Obs. NO EVENTO", font_size=8, bold=True, color="FFFFFF", bg_color="1F497D", width=widths_c[2])
    
    format_cell(t_concept.cell(1, 0), "Mod. EVENTO", font_size=8, bold=True, color="215868", bg_color="EBF3FB", align=WD_ALIGN_PARAGRAPH.LEFT, width=widths_c[0])
    format_cell(t_concept.cell(1, 1), "H — Acierto", font_size=8, bold=True, color="1A7A3C", bg_color="C6EFCE", width=widths_c[1])
    format_cell(t_concept.cell(1, 2), "F — Falsa Alarma", font_size=8, bold=True, color="9C1B1B", bg_color="FFC7CE", width=widths_c[2])
    
    format_cell(t_concept.cell(2, 0), "Mod. NO EVENTO", font_size=8, bold=True, color="215868", bg_color="EBF3FB", align=WD_ALIGN_PARAGRAPH.LEFT, width=widths_c[0])
    format_cell(t_concept.cell(2, 1), "M — Fallo", font_size=8, bold=True, color="9C1B1B", bg_color="FFC7CE", width=widths_c[1])
    format_cell(t_concept.cell(2, 2), "C — Rechazo Corr.", font_size=8, bold=True, color="1A7A3C", bg_color="C6EFCE", width=widths_c[2])

    add_para(doc, "", size=6)

    defs = [
        ("POD",  "= H / (H + M)",          "Probabilidad de detección (Probability of Detection). Fracción de eventos observados que el modelo detecta correctamente. Ideal = 1."),
        ("FAR",  "= F / (H + F)",           "Tasa de falsas alarmas (False Alarm Ratio). Fracción de eventos modelados que no ocurrieron. Ideal = 0."),
        ("CSI",  "= H / (H + M + F)",       "Índice de éxito crítico (Critical Success Index). Combina fallos y falsas alarmas; no considera rechazos correctos. Ideal = 1."),
        ("TSS",  "= POD − F/(F+C)",         "Pierce Skill Score (Hanssen-Kuipers discriminant). Diferencia entre tasa de detección y tasa de falsa detección. Rango [−1, 1]; ideal = 1."),
        ("PC",   "= (H + C) / N",           "Porcentaje correcto (Percent Correct). Fracción de días clasificados correctamente. Ideal = 1; puede ser engañoso cuando los eventos son raros."),
        ("BIAS", "= (H + F) / (H + M)",     "Sesgo de frecuencia (Frequency Bias). Cociente entre número de eventos pronosticados y observados. Ideal = 1; >1 sobreestima eventos; <1 los subestima."),
    ]

    for nombre, formula, desc in defs:
        p_def = doc.add_paragraph()
        p_def.paragraph_format.space_before = Pt(3)
        p_def.paragraph_format.space_after = Pt(1)
        
        r1 = p_def.add_run(f"{nombre} ")
        r1.font.name = "Calibri"
        r1.font.size = Pt(9)
        r1.font.bold = True
        
        r2 = p_def.add_run(f"{formula}  ")
        r2.font.name = "Calibri"
        r2.font.size = Pt(9)
        r2.font.italic = True
        r2.font.color.rgb = RGBColor.from_string("1F497D")
        
        r3 = p_def.add_run(desc)
        r3.font.name = "Calibri"
        r3.font.size = Pt(8.5)

    add_heading_2(doc, "Leyenda de semáforo de desempeño")
    t_ley = create_styled_table(doc, rows=6, cols=4)
    t_ley.style = 'Table Grid'
    widths_l = [Inches(1.2), Inches(2.6), Inches(2.6), Inches(2.6)]

    headers_l = ["Métrica", "🟢  Bueno", "🟡  Aceptable", "🔴  Deficiente"]
    for j, h in enumerate(headers_l):
        format_cell(t_ley.cell(0, j), h, font_size=8, bold=True, color="FFFFFF", bg_color="1F497D", width=widths_l[j])
    set_repeat_header(t_ley.rows[0])

    items_ley = [
        {"stat": "POD",  "verde": "≥ 0.700",         "ambar": "0.400 – 0.699", "rojo": "< 0.400"},
        {"stat": "FAR",  "verde": "≤ 0.300",         "ambar": "0.301 – 0.500", "rojo": "> 0.500"},
        {"stat": "CSI",  "verde": "≥ 0.400",         "ambar": "0.200 – 0.399", "rojo": "< 0.200"},
        {"stat": "TSS",  "verde": "≥ 0.400",         "ambar": "0.100 – 0.399", "rojo": "< 0.100"},
        {"stat": "BIAS", "verde": "|BIAS-1| ≤ 0.3",  "ambar": "0.3 – 0.6",     "rojo": "> 0.6"},
    ]

    for i, it in enumerate(items_ley, start=1):
        row = t_ley.rows[i]
        format_cell(row.cells[0], it["stat"],  font_size=8, bold=True, color="215868", bg_color="EBF3FB", align=WD_ALIGN_PARAGRAPH.LEFT, width=widths_l[0])
        format_cell(row.cells[1], it["verde"], font_size=8, color="1A7A3C", bg_color="C6EFCE", width=widths_l[1])
        format_cell(row.cells[2], it["ambar"], font_size=8, color="7D5A00", bg_color="FFEB9C", width=widths_l[2])
        format_cell(row.cells[3], it["rojo"],  font_size=8, color="9C1B1B", bg_color="FFC7CE", width=widths_l[3])
        set_cant_split(row)

    add_para(doc, "", size=6)

    # ── Resultados por Mes ───────────────────────────────────────────────────
    sec_num = 2
    stats_cols = ["POD", "FAR", "CSI", "TSS", "PC", "BIAS"]

    for mes in sorted(resultados.keys()):
        doc.add_page_break()
        
        a, mm = mes.split("-")
        nombre_mes = _NOMBRE_MES.get(mm, mm)
        
        add_heading_1(doc, f"{sec_num}. Resultados — {nombre_mes} {a}")
        sec_num += 1

        sub_num = 1
        for cont in sorted(resultados[mes].keys()):
            meta = META_CONT[cont]
            umbral = UMBRALES[cont]
            ciudades_dict = resultados[mes][cont]

            add_heading_2(doc, f"{sec_num - 1}.{sub_num}  {meta['nombre']}  (umbral: {umbral} {meta['unidad']}, {meta['norma']})")
            add_para(doc, meta["desc"], size=8.5, space_before=2, space_after=4)

            # Tabla Principal de Estadísticos
            add_heading_3(doc, "Estadísticos de verificación dicotómica")
            
            num_ciudades = len(ciudades_dict)
            t_stat = create_styled_table(doc, rows=2 + num_ciudades, cols=20)
            t_stat.style = 'Table Grid'

            w_ciudad = Inches(1.3)
            w_n      = Inches(0.5)
            w_s      = Inches(0.48)

            # Encabezados de Fila 0
            format_cell(t_stat.cell(0, 0), "Ciudad", font_size=8, bold=True, color="FFFFFF", bg_color="1F497D", width=w_ciudad)
            format_cell(t_stat.cell(0, 1), "N días", font_size=8, bold=True, color="FFFFFF", bg_color="1F497D", width=w_n)

            c24 = t_stat.cell(0, 2);  c24.merge(t_stat.cell(0, 7))
            format_cell(c24, "+24 h", font_size=8, bold=True, color="FFFFFF", bg_color="1F497D")

            c48 = t_stat.cell(0, 8);  c48.merge(t_stat.cell(0, 13))
            format_cell(c48, "+48 h", font_size=8, bold=True, color="FFFFFF", bg_color="1F497D")

            c72 = t_stat.cell(0, 14); c72.merge(t_stat.cell(0, 19))
            format_cell(c72, "+72 h", font_size=8, bold=True, color="FFFFFF", bg_color="1F497D")

            set_repeat_header(t_stat.rows[0])
            set_cant_split(t_stat.rows[0])

            # Encabezados de Fila 1 (Métricas)
            format_cell(t_stat.cell(1, 0), "", font_size=7.5, bg_color="BDD7EE", width=w_ciudad)
            format_cell(t_stat.cell(1, 1), "", font_size=7.5, bg_color="BDD7EE", width=w_n)

            col_idx = 2
            for _ in range(3):
                for st_name in stats_cols:
                    format_cell(t_stat.cell(1, col_idx), st_name, font_size=7.5, bold=True, color="1F497D", bg_color="BDD7EE", width=w_s)
                    col_idx += 1

            set_repeat_header(t_stat.rows[1])
            set_cant_split(t_stat.rows[1])

            # Filas de Datos por Ciudad
            for r_i, (ciudad, horizontes) in enumerate(sorted(ciudades_dict.items()), start=2):
                row = t_stat.rows[r_i]

                st24 = horizontes.get("+24 h")
                n_txt = str(st24["N"]) if st24 and st24.get("N") is not None else "—"

                format_cell(row.cells[0], ciudad, font_size=8, bold=True, color="215868", bg_color="EBF3FB", align=WD_ALIGN_PARAGRAPH.LEFT, width=w_ciudad)
                format_cell(row.cells[1], n_txt,  font_size=8, bold=True, color="215868", bg_color="EBF3FB", width=w_n)

                c_idx = 2
                for hor_lbl in ["+24 h", "+48 h", "+72 h"]:
                    st_h = horizontes.get(hor_lbl)
                    for st_name in stats_cols:
                        val = st_h.get(st_name) if st_h else None
                        val_str = _fmt(val)
                        bg = BG_FN[st_name](val)
                        format_cell(row.cells[c_idx], val_str, font_size=7.5, color="222222", bg_color=bg, width=w_s)
                        c_idx += 1
                set_cant_split(row)

            add_para(doc, "", size=4)

            # Tabla de Contingencia (H M F C)
            add_heading_3(doc, "Tabla de contingencia (H, M, F, C)")
            t_cont = create_styled_table(doc, rows=2 + num_ciudades, cols=13)
            t_cont.style = 'Table Grid'

            w_c_n = Inches(0.68)

            format_cell(t_cont.cell(0, 0), "Ciudad", font_size=8, bold=True, color="FFFFFF", bg_color="1F497D", width=w_ciudad)

            for idx_h, hor_lbl in enumerate(["+24 h", "+48 h", "+72 h"]):
                start_c = 1 + idx_h * 4
                merged_c = t_cont.cell(0, start_c)
                merged_c.merge(t_cont.cell(0, start_c + 3))
                format_cell(merged_c, hor_lbl, font_size=8, bold=True, color="FFFFFF", bg_color="1F497D")

            set_repeat_header(t_cont.rows[0])
            set_cant_split(t_cont.rows[0])

            format_cell(t_cont.cell(1, 0), "", font_size=7.5, bg_color="BDD7EE", width=w_ciudad)
            c_idx = 1
            for _ in range(3):
                for lbl in ["H", "M", "F", "C"]:
                    format_cell(t_cont.cell(1, c_idx), lbl, font_size=7.5, bold=True, color="1F497D", bg_color="BDD7EE", width=w_c_n)
                    c_idx += 1

            set_repeat_header(t_cont.rows[1])
            set_cant_split(t_cont.rows[1])

            for r_i, (ciudad, horizontes) in enumerate(sorted(ciudades_dict.items()), start=2):
                row = t_cont.rows[r_i]
                format_cell(row.cells[0], ciudad, font_size=8, bold=True, color="215868", bg_color="EBF3FB", align=WD_ALIGN_PARAGRAPH.LEFT, width=w_ciudad)

                c_idx = 1
                for hor_lbl in ["+24 h", "+48 h", "+72 h"]:
                    st_h = horizontes.get(hor_lbl)
                    for lbl in ["H", "M", "F", "C"]:
                        val = st_h.get(lbl) if st_h else None
                        val_str = str(val) if val is not None else "—"
                        bg = "C6EFCE" if lbl == "H" else ("FFC7CE" if lbl in ["M", "F"] else "FFFFFF")
                        format_cell(row.cells[c_idx], val_str, font_size=7.5, color="222222", bg_color=bg, width=w_c_n)
                        c_idx += 1
                set_cant_split(row)

            add_para(doc, "", size=6)
            sub_num += 1

    # ── Notas técnicas ───────────────────────────────────────────────────────
    doc.add_page_break()
    add_heading_1(doc, "Notas técnicas")
    notas = [
        "• Los valores N/D indican que no se alcanzó el mínimo de días con datos necesarios para el cálculo (≥5 pares obs/mod válidos).",
        "• El horizonte +72 h cubre solo 18 h de la ventana local (índices 54–71 del wrfout) por la alineación UTC−6 con el inicio del run.",
        "• BIAS = 1 indica que el modelo pronosticó el mismo número de eventos que los observados (sin importar la coincidencia día a día). BIAS > 1 indica sobreestimación de la frecuencia; BIAS < 1, subestimación.",
        "• Las observaciones provienen de la red SINAICA/INECC; los valores del modelo corresponden al máximo diario extraído del dominio WRF-Chem sobre la región de cada ciudad (máximo espacial).",
        "• Generado con: informe_dicotomico.py (ddsinaica v2.5.0) — ICAyCC, UNAM. Código disponible en https://github.com/JoseAgustin/ddsinaica"
    ]
    for nota in notas:
        add_para(doc, nota, size=8.5, space_before=3, space_after=3)

    doc.save(ruta_salida)
    print(f"[OK] Documento generado: {ruta_salida}")


# ──────────────────────────────────────────────────────────────────────────────
# PUNTO DE ENTRADA
# ──────────────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(
        prog="informe_dicotomico.py",
        description=(
            "Genera un informe Word (.docx) con estadísticos dicotómicos "
            "mensuales (POD, FAR, CSI, TSS, PC, BIAS) para la evaluación "
            "WRF-Chem vs SINAICA/INECC usando python-docx."
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
