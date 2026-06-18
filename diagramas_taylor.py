#!/usr/bin/env python3
# =============================================================================
# diagramas_taylor.py
# Author      : "Jose Agustin Garcia Reynoso" <agustin@atmosfera.unam.mx>
# =============================================================================
"""
Genera diagramas de Taylor mensuales a partir de datos_diarios.csv
producido por extrae_evaluacion_html.sh.

Cada punto del diagrama representa una combinación única de:
    Ubicación + Contaminante + Horizonte
    Ejemplo: "Pachuca O3 24h", "Tula PM10 48h"

Por cada mes se genera:
    taylor_2026_MM.png       → diagrama de Taylor
    estadisticas_taylor.csv  → resumen estadístico completo

Metodología (Diagrama de Taylor, Taylor 2001):
    - Eje X          : desviación estándar del modelo (σ_mod)
    - Eje Y          : desviación estándar del modelo (mismo espacio polar)
    - Ángulo θ       : arccos(R), donde R = correlación de Pearson
    - Distancia al origen: σ_mod
    - CRMSE          : distancia del punto al punto de referencia (σ_obs, 0)
    - Referencia     : punto (σ_obs, 0) representando las observaciones

    Los valores se normalizan por σ_obs para facilitar la comparación entre
    contaminantes con distintas unidades.

Uso:
    python diagramas_taylor.py [opciones]

Opciones:
    --csv     CSV de datos diarios      [datos_diarios.csv]
    --meses   Meses a procesar (04 05 06)  [04 05 06]
    --out     Directorio de salida      [.]
    --dpi     Resolución de figuras     [150]
    --no-norm No normalizar por σ_obs
    -h        Ayuda

Ejemplos:
    python diagramas_taylor.py
    python diagramas_taylor.py --csv ./csv/datos_diarios.csv --out ./figuras
    python diagramas_taylor.py --meses 04 05 --dpi 200

Referencia:
    Taylor, K.E. (2001). Summarizing model performance in a single diagram.
    J. Geophys. Res., 106(D7), 7183-7192. doi:10.1029/2000JD900719

Dependencias: Python ≥ 3.9, pandas, numpy, matplotlib
"""

import argparse
import sys
import csv
import warnings
from pathlib import Path
from itertools import cycle

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.lines as mlines

# ── Constantes globales ────────────────────────────────────────────────────────
NOMBRES_MESES = {
    "01": "Enero",   "02": "Febrero",  "03": "Marzo",
    "04": "Abril",   "05": "Mayo",     "06": "Junio",
    "07": "Julio",   "08": "Agosto",   "09": "Septiembre",
    "10": "Octubre", "11": "Noviembre","12": "Diciembre",
}

# Marcadores y colores por ciudad
CIUDAD_STYLE = {
    "Pachuca": {"marker": "o", "base_color": "#e74c3c"},  # rojo
    "Tula":    {"marker": "s", "base_color": "#2980b9"},  # azul
}

# Tonos por horizonte (factor de luminosidad)
HORIZONTE_ALPHA = {"24": 1.0, "48": 0.65, "72": 0.35}

# Paleta de colores por contaminante (para leyenda)
CONTAM_COLORS = [
    "#e74c3c", "#2980b9", "#27ae60", "#8e44ad",
    "#f39c12", "#16a085", "#c0392b", "#1abc9c",
]

HDR_STATS = [
    "mes", "ubicacion", "contaminante", "horizonte", "n",
    "media_obs", "std_obs", "media_mod", "std_mod",
    "r", "rmse", "crmse", "bias",
    "std_mod_norm", "crmse_norm",
]


# ═════════════════════════════════════════════════════════════════════════════
# 1. LECTURA Y VALIDACIÓN DE DATOS
# ═════════════════════════════════════════════════════════════════════════════
def carga_csv(filepath: Path) -> pd.DataFrame:
    """
    Lee datos_diarios.csv y convierte columnas numéricas.
    Retorna DataFrame con columnas:
        fecha, mes, ubicacion, contaminante, horizonte,
        observacion, modelo, diferencia
    """
    if not filepath.exists():
        raise FileNotFoundError(f"No se encontró: {filepath}")

    df = pd.read_csv(filepath, dtype=str)
    df.columns = df.columns.str.strip()

    for col in ("observacion", "modelo", "diferencia"):
        df[col] = pd.to_numeric(df[col], errors="coerce")

    df["horizonte"] = df["horizonte"].astype(str).str.strip()
    df["mes"]       = df["mes"].astype(str).str.zfill(2)

    # Eliminar filas sin obs o modelo
    n_orig = len(df)
    df = df.dropna(subset=["observacion", "modelo"])
    n_drop = n_orig - len(df)
    if n_drop > 0:
        print(f"  [INFO] Se omitieron {n_drop} filas con valores faltantes")

    return df


# ═════════════════════════════════════════════════════════════════════════════
# 2. ESTADÍSTICAS PARA DIAGRAMA DE TAYLOR
# ═════════════════════════════════════════════════════════════════════════════
def calc_taylor_stats(obs: np.ndarray, mod: np.ndarray) -> dict | None:
    """
    Calcula las estadísticas necesarias para el diagrama de Taylor.

    Parámetros
    ----------
    obs : array de observaciones
    mod : array de valores del modelo (mismo tamaño que obs)

    Retorna
    -------
    dict con:
        n         : número de pares
        media_obs : media de las observaciones
        media_mod : media del modelo
        std_obs   : desviación estándar de obs   (ddof=1)
        std_mod   : desviación estándar del modelo
        r         : coeficiente de correlación de Pearson
        bias      : media(mod) - media(obs)
        rmse      : √(mean((mod - obs)²))
        crmse     : RMSE centrado = √(σ²_mod + σ²_obs - 2·σ_mod·σ_obs·R)
    Retorna None si n < 3 o σ_obs ≈ 0.
    """
    obs = np.asarray(obs, dtype=float)
    mod = np.asarray(mod, dtype=float)

    # Eliminar NaN pareados
    mask = np.isfinite(obs) & np.isfinite(mod)
    obs, mod = obs[mask], mod[mask]
    n = len(obs)

    if n < 3:
        return None

    std_obs = np.std(obs, ddof=1)
    std_mod = np.std(mod, ddof=1)

    if std_obs < 1e-12:
        return None   # observaciones constantes → diagrama no informativo

    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        r = np.corrcoef(obs, mod)[0, 1]

    if not np.isfinite(r):
        r = 0.0

    bias  = np.mean(mod) - np.mean(obs)
    rmse  = np.sqrt(np.mean((mod - obs) ** 2))
    # CRMSE = distancia euclidiana en el espacio de Taylor
    crmse = np.sqrt(std_mod**2 + std_obs**2 - 2 * std_mod * std_obs * r)

    return {
        "n":         n,
        "media_obs": float(np.mean(obs)),
        "media_mod": float(np.mean(mod)),
        "std_obs":   float(std_obs),
        "std_mod":   float(std_mod),
        "r":         float(r),
        "bias":      float(bias),
        "rmse":      float(rmse),
        "crmse":     float(crmse),
    }


def agrega_por_grupo(df: pd.DataFrame) -> list[dict]:
    """
    Agrupa por (mes, ubicacion, contaminante, horizonte) y calcula
    las estadísticas de Taylor para cada grupo.
    Retorna lista de dicts listos para el CSV de estadísticas y para graficar.
    """
    grupos = df.groupby(
        ["mes", "ubicacion", "contaminante", "horizonte"],
        sort=True
    )
    registros = []

    for (mes, ubicacion, contaminante, horizonte), g in grupos:
        st = calc_taylor_stats(g["observacion"].values, g["modelo"].values)
        if st is None:
            print(f"  [WARN] Sin stats: {mes} {ubicacion} {contaminante} {horizonte}h "
                  f"(n={len(g)})")
            continue

        rec = {
            "mes": mes, "ubicacion": ubicacion,
            "contaminante": contaminante, "horizonte": str(horizonte),
            **st,
            "std_mod_norm": st["std_mod"] / st["std_obs"],
            "crmse_norm":   st["crmse"]   / st["std_obs"],
        }
        registros.append(rec)

    return registros


# ═════════════════════════════════════════════════════════════════════════════
# 3. DIAGRAMA DE TAYLOR
# ═════════════════════════════════════════════════════════════════════════════
def _setup_taylor_axes(ax, max_sd: float, r_levels=None):
    """
    Dibuja la cuadrícula base del diagrama de Taylor en ax:
      - Arcos de desviación estándar constante
      - Líneas radiales de correlación
      - Arcos de CRMSE constante centrados en (1, 0) [normalizado]
    Todos los valores están normalizados: σ_obs = 1.
    """
    if r_levels is None:
        r_levels = [0.2, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 0.99]

    ax.set_aspect("equal")
    ax.set_xlim(0, max_sd)
    ax.set_ylim(0, max_sd)
    ax.set_xlabel("Desviación estándar normalizada  (σ_mod / σ_obs)", fontsize=9)
    ax.set_ylabel("Desviación estándar normalizada  (σ_mod / σ_obs)", fontsize=9)

    theta = np.linspace(0, np.pi / 2, 500)

    # ── Arcos de σ normalizada ───────────────────────────────────────────────
    sd_fracs = np.arange(0.25, max_sd + 0.01, 0.25)
    for sd in sd_fracs:
        arc = mpatches.Arc(
            (0, 0), 2*sd, 2*sd, angle=0, theta1=0, theta2=90,
            color="#d5d5d5", lw=0.8, zorder=1
        )
        ax.add_patch(arc)
        # Etiqueta sobre el arco (en eje X)
        if sd <= max_sd:
            ax.text(sd + 0.01, 0.01, f"{sd:.2g}",
                    fontsize=6.5, color="#aaa", va="bottom")

    # Arco grueso de referencia (σ = 1)
    arc_ref = mpatches.Arc(
        (0, 0), 2, 2, angle=0, theta1=0, theta2=90,
        color="#444", lw=1.5, zorder=2
    )
    ax.add_patch(arc_ref)
    ax.text(1.01, 0.01, "1.0 (obs)", fontsize=7, color="#333", va="bottom")

    # ── Líneas radiales de correlación ───────────────────────────────────────
    for R in r_levels:
        angle = np.arccos(R)
        xr = max_sd * np.cos(angle)
        yr = max_sd * np.sin(angle)
        ax.plot([0, xr], [0, yr],
                color="#c8d8e8", lw=0.7, ls="--", zorder=1)
        # Etiqueta en el extremo del radio
        ax.text(xr * 1.02, yr * 1.02, f"{R}",
                fontsize=6.5, color="#7799bb",
                ha="center", va="center", rotation=np.degrees(-angle))

    # Etiqueta del eje de correlación (diagonal)
    ax.text(max_sd * 0.62, max_sd * 0.80, "Correlación  R",
            fontsize=8, color="#7799bb", rotation=-45,
            ha="center", va="center")

    # ── Arcos de CRMSE constante (centro en σ_obs = 1) ─────────────────────
    for frac in [0.25, 0.5, 0.75, 1.0, 1.25, 1.5]:
        crmse = frac
        # Dibujar arco centrado en (1, 0) si cabe en el gráfico
        arc_c = mpatches.Arc(
            (1.0, 0), 2*crmse, 2*crmse, angle=0, theta1=0, theta2=180,
            color="#f5dde8", lw=0.7, ls=":", zorder=1
        )
        ax.add_patch(arc_c)
        # Etiqueta pequeña sobre el arco
        x_lbl = 1.0 + crmse * np.cos(np.radians(75))
        y_lbl = crmse * np.sin(np.radians(75))
        if 0 <= x_lbl <= max_sd and 0 <= y_lbl <= max_sd:
            ax.text(x_lbl, y_lbl, f"E'={frac:.2g}",
                    fontsize=5.5, color="#c099aa", ha="center")

    # Punto de referencia (observaciones)
    ax.plot(1.0, 0.0, "k*", ms=12, zorder=10, clip_on=False)
    ax.text(1.0, -0.04, "OBS", fontsize=7, ha="center",
            color="black", fontweight="bold")


def dibuja_punto(ax, st: dict, estilo: dict):
    """
    Coloca un punto en el diagrama de Taylor normalizado.

    Coordenadas polares:
        θ = arccos(R)
        r = σ_mod_norm
    → Cartesianas:
        x = r·cos(θ) = σ_mod_norm · R / sqrt(1 - R² + R²)  [simplificado]
        x = σ_mod_norm · cos(arccos(R))
        y = σ_mod_norm · sin(arccos(R))
    """
    R   = np.clip(st["r"], -1.0, 1.0)
    ang = np.arccos(R)
    sn  = st["std_mod_norm"]
    xs  = sn * np.cos(ang)
    ys  = sn * np.sin(ang)

    ax.scatter(
        xs, ys,
        color=estilo["color"],
        marker=estilo["marker"],
        s=estilo.get("size", 80),
        alpha=estilo.get("alpha", 1.0),
        zorder=8,
        edgecolors="white",
        linewidths=0.6,
        label=estilo.get("label", ""),
        clip_on=True,
    )
    return xs, ys


# ═════════════════════════════════════════════════════════════════════════════
# 4. FIGURA POR MES
# ═════════════════════════════════════════════════════════════════════════════
def genera_figura_mes(registros_mes: list[dict], mes: str, out: Path,
                      dpi: int = 150, normalizado: bool = True):
    """
    Crea la figura taylor_2026_MM.png con un único diagrama de Taylor
    que incluye todos los puntos (ubicacion × contaminante × horizonte).

    Convenciones visuales:
        Ciudad     → forma del marcador (○ Pachuca, □ Tula)
        Horizonte  → transparencia (24h=opaco, 48h=semitransparente, 72h=tenue)
        Contaminante → color
    """
    if not registros_mes:
        print(f"  [WARN] Sin registros para mes {mes}")
        return

    # ── Asignar color por contaminante ───────────────────────────────────────
    contams = sorted({r["contaminante"] for r in registros_mes})
    color_map = {c: CONTAM_COLORS[i % len(CONTAM_COLORS)]
                 for i, c in enumerate(contams)}

    max_sd = max(r["std_mod_norm"] for r in registros_mes)
    max_sd = max(1.5, np.ceil(max_sd / 0.25) * 0.25 + 0.25)

    fig, ax = plt.subplots(figsize=(10, 9))
    fig.patch.set_facecolor("white")

    _setup_taylor_axes(ax, max_sd)

    # ── Graficar cada punto ───────────────────────────────────────────────────
    for rec in registros_mes:
        ciudad  = rec["ubicacion"]
        contam  = rec["contaminante"]
        hor     = str(rec["horizonte"])

        c_style = CIUDAD_STYLE.get(ciudad, {"marker": "D", "base_color": "#555"})
        color   = color_map.get(contam, "#888")
        alpha   = HORIZONTE_ALPHA.get(hor, 0.5)

        label = f"{ciudad} {contam} {hor}h"
        estilo = {
            "color":  color,
            "marker": c_style["marker"],
            "size":   90,
            "alpha":  alpha,
            "label":  label,
        }
        dibuja_punto(ax, rec, estilo)

    # ── Leyendas ─────────────────────────────────────────────────────────────
    # 1. Contaminante → color
    legend_contam = [
        mpatches.Patch(color=color_map[c], label=c)
        for c in contams
    ]
    leg1 = ax.legend(
        handles=legend_contam, title="Contaminante",
        loc="upper left", fontsize=8, title_fontsize=8,
        framealpha=0.85, edgecolor="#ccc"
    )
    ax.add_artist(leg1)

    # 2. Ciudad → marcador
    legend_ciudad = [
        mlines.Line2D([], [], color="grey",
                      marker=CIUDAD_STYLE[c]["marker"],
                      linestyle="None", markersize=8, label=c)
        for c in CIUDAD_STYLE
        if any(r["ubicacion"] == c for r in registros_mes)
    ]
    leg2 = ax.legend(
        handles=legend_ciudad, title="Estación",
        loc="upper right", fontsize=8, title_fontsize=8,
        framealpha=0.85, edgecolor="#ccc"
    )
    ax.add_artist(leg2)

    # 3. Horizonte → transparencia
    legend_hor = [
        mlines.Line2D([], [], color="grey",
                      marker="o", linestyle="None",
                      markersize=8, alpha=a,
                      label=f"{h}h")
        for h, a in sorted(HORIZONTE_ALPHA.items())
    ]
    ax.legend(
        handles=legend_hor, title="Horizonte",
        loc="lower right", fontsize=8, title_fontsize=8,
        framealpha=0.85, edgecolor="#ccc"
    )

    # ── Título y anotación metodológica ──────────────────────────────────────
    nombre_mes = NOMBRES_MESES.get(mes, mes)
    ax.set_title(
        f"Diagrama de Taylor — {nombre_mes} 2026\n"
        r"Normalizado por $\sigma_{obs}$  •  Pachuca y Tula",
        fontsize=12, fontweight="bold", pad=14
    )
    ax.text(
        0.01, 0.01,
        "★ Observaciones  |  Taylor (2001) J.Geophys.Res.",
        transform=ax.transAxes,
        fontsize=7, color="#888", va="bottom"
    )

    plt.tight_layout()
    fname = out / f"taylor_2026_{mes}.png"
    fig.savefig(fname, dpi=dpi, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  ✓ Figura: {fname}")
    return fname


# ═════════════════════════════════════════════════════════════════════════════
# 5. CSV DE ESTADÍSTICAS
# ═════════════════════════════════════════════════════════════════════════════
def exporta_estadisticas(registros: list[dict], out: Path):
    """
    Escribe estadisticas_taylor.csv con todas las métricas calculadas
    para cada combinación mes × ubicacion × contaminante × horizonte.
    """
    fname = out / "estadisticas_taylor.csv"
    campos = HDR_STATS

    with open(fname, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=campos, extrasaction="ignore")
        w.writeheader()
        for r in sorted(registros, key=lambda x: (
                x["mes"], x["ubicacion"], x["contaminante"], x["horizonte"])):
            fila = {k: (f"{v:.4f}" if isinstance(v, float) else v)
                    for k, v in r.items()}
            w.writerow(fila)

    print(f"  ✓ Estadísticas: {fname}")
    return fname


# ═════════════════════════════════════════════════════════════════════════════
# 6. MAIN
# ═════════════════════════════════════════════════════════════════════════════
def parse_args():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--csv",    default="datos_diarios.csv",
                   help="CSV de datos diarios [datos_diarios.csv]")
    p.add_argument("--meses",  nargs="+", default=["04", "05", "06"],
                   help="Meses a procesar [04 05 06]")
    p.add_argument("--out",    default=".",
                   help="Directorio de salida [.]")
    p.add_argument("--dpi",    type=int, default=150,
                   help="Resolución DPI de figuras [150]")
    p.add_argument("--no-norm", action="store_true",
                   help="No normalizar por σ_obs (usa valores absolutos)")
    return p.parse_args()


def main():
    args = parse_args()
    out  = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    # ── Cargar datos ─────────────────────────────────────────────────────────
    print(f"\n[1/4] Cargando {args.csv} …")
    df = carga_csv(Path(args.csv))
    print(f"      {len(df):,} filas válidas | "
          f"ubicaciones: {sorted(df['ubicacion'].unique())} | "
          f"contaminantes: {sorted(df['contaminante'].unique())}")

    # ── Calcular estadísticas ────────────────────────────────────────────────
    print("\n[2/4] Calculando estadísticas de Taylor …")
    registros = agrega_por_grupo(df)
    print(f"      {len(registros)} grupos procesados")

    if not registros:
        print("[ERROR] No se obtuvieron estadísticas. Verifica el CSV.", file=sys.stderr)
        sys.exit(1)

    # ── Exportar CSV de estadísticas ─────────────────────────────────────────
    print("\n[3/4] Exportando estadisticas_taylor.csv …")
    exporta_estadisticas(registros, out)

    # ── Generar figuras por mes ──────────────────────────────────────────────
    print("\n[4/4] Generando diagramas de Taylor …")
    meses_pedir = [m.zfill(2) for m in args.meses]
    figs = []

    for mes in meses_pedir:
        recs_mes = [r for r in registros if r["mes"] == mes]
        if not recs_mes:
            print(f"  [WARN] Sin datos para mes {mes}")
            continue
        print(f"\n  Mes {mes} ({NOMBRES_MESES.get(mes, mes)}): "
              f"{len(recs_mes)} grupos")
        fig = genera_figura_mes(recs_mes, mes, out, dpi=args.dpi,
                                normalizado=not args.no_norm)
        if fig:
            figs.append(fig)

    print(f"\n✅ Proceso completado.")
    print(f"   Figuras    : {[str(f) for f in figs]}")
    print(f"   Estadísticas: {out}/estadisticas_taylor.csv")


if __name__ == "__main__":
    main()

