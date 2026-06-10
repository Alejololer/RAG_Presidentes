"""
Auditor de calidad del dataset presidentes_ecuador.jsonl (standalone).

NO importa utils.py — corre con stdlib pura. Detecta:

  1. Campos "Nombre" sucios (texto desbordado, espacios anomalos, saltos de linea).
  2. Secciones vacias o faltantes por presidente.
  3. Claves del JSON que NO estan mapeadas en el SECTION_SLUGS canonico.
  4. Chunks que mencionan 2+ presidentes canonicos (riesgo de cruce en retrieval).
  5. Contradicciones de fechas intra-presidente (rangos de periodo inconsistentes).
  6. Anomalias de longitud (<20 palabras o >1500 palabras por seccion).

Salida: reporte en consola + JSON estructurado en audit_report.json.

Uso:
    python3 audit_data.py
"""

import json
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

DATA_PATH = Path("presidentes_ecuador.json")
REPORT_PATH = Path("audit_report.json")

# --- SECTION_SLUGS canonico (copia fiel de utils.py, necesario porque
#     no podemos importar utils sin sus dependencias). Mantener en sync. ---
SECTION_SLUGS = [
    (("periodos de actuacion", "periodos presidenciales"), "periodos_politicos"),
    (("datos demograficos",), "datos_demograficos"),
    (("capital global",), "capital_global"),
    (("redes y vinculaciones",), "redes_sociales"),
    (("posicionamiento politico", "posicionamiento politico-ideolog"), "posicionamiento_ideologico"),
    (("legislacion",), "legislacion"),
    (("obra publica",), "obra_publica"),
    (("manejo de los bienes",), "bienes_comunes"),
    (("posicionamiento con los derechos humanos", "derechos humanos"), "derechos_humanos"),
    (("relaciones politicas en el plano",), "relaciones_internacionales"),
    (("marcas de oratoria",), "oratoria"),
    (("imaginarios sobre el personaje",), "imaginarios"),
    (("fuentes bibliograficas",), "fuentes"),
]

SECTION_LABELS = {
    "periodos_politicos": "Períodos de actuación política",
    "datos_demograficos": "Datos demográficos",
    "capital_global": "Capital global (formación, familia)",
    "redes_sociales": "Redes y vinculaciones sociales",
    "posicionamiento_ideologico": "Posicionamiento político-ideológico",
    "legislacion": "Legislación expedida o fomentada",
    "obra_publica": "Obra pública",
    "bienes_comunes": "Manejo de los bienes comunes",
    "derechos_humanos": "Posicionamiento en derechos humanos",
    "relaciones_internacionales": "Relaciones políticas regionales y globales",
    "oratoria": "Marcas de oratoria",
    "imaginarios": "Imaginarios sobre el personaje",
    "fuentes": "Fuentes bibliográficas",
}

EXPECTED_SLUGS = set(SECTION_LABELS.keys())


# --- Utilidades de texto (copia minima de utils.py) ---

def _strip_accents(text: str) -> str:
    nfkd = unicodedata.normalize("NFKD", text)
    return "".join(c for c in nfkd if not unicodedata.combining(c))


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", _strip_accents(text).lower()).strip()


def _key_to_slug(key: str):
    nk = _normalize(key)
    if nk.startswith("nombre"):
        return None
    for substrings, slug in SECTION_SLUGS:
        if any(s in nk for s in substrings):
            return slug
    return None


def _is_dirty_name(nombre: str) -> tuple[bool, str]:
    if "\n" in nombre or "  " in nombre:
        return True, "salto de linea o espacios multiples"
    if len(nombre) > 60:
        return True, f"longitud anormal ({len(nombre)} chars)"
    if not re.search(r"[A-Za-zÁÉÍÓÚáéíóúÑñ]", nombre):
        return True, "sin caracteres alfabeticos"
    return False, ""


def _clean_name(nombre: str) -> str:
    """Replica el saneador de load_records()."""
    return re.split(r"\s{2,}|\n", str(nombre).strip())[0].strip()


# --- Carga robusta del JSONL (replica load_records sin dependencias) ---

def load_raw() -> list[dict]:
    out = []
    with open(DATA_PATH, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            out.append(json.loads(line))
    return out


def load_clean(raw: list[dict]) -> list[dict]:
    """Normaliza cada registro: extrae nombre limpio + secciones por slug."""
    out = []
    for item in raw:
        nombre = None
        secciones = {}
        for key, value in item.items():
            if _normalize(key).startswith("nombre"):
                nombre = _clean_name(str(value))
                continue
            slug = _key_to_slug(key)
            if slug and value and str(value).strip():
                secciones[slug] = str(value).strip()
        if nombre:
            out.append({"nombre": nombre, "secciones": secciones})
    return out


# --- Detectores ---

def detect_dirty_names(raw: list[dict], clean: list[dict]) -> list[dict]:
    """Encuentra nombres crudos con texto desbordado que load_records() tuvo
    que limpiar. Util para saber cuantos registros del dataset estan sucios."""
    clean_set = {r["nombre"] for r in clean}
    hallazgos = []
    for item in raw:
        raw_nombre = str(item.get("Nombre", ""))
        es_sucio, motivo = _is_dirty_name(raw_nombre)
        if not es_sucio:
            continue
        limpio = _clean_name(raw_nombre)
        if limpio in clean_set:
            hallazgos.append({
                "limpio": limpio,
                "crudo_preview": raw_nombre[:80] + ("..." if len(raw_nombre) > 80 else ""),
                "crudo_len": len(raw_nombre),
                "motivo": motivo,
            })
    return hallazgos


def detect_mismapped_keys(raw: list[dict]) -> dict[str, int]:
    counter = Counter()
    for item in raw:
        for key in item.keys():
            if _normalize(key).startswith("nombre"):
                continue
            if _key_to_slug(key) is None:
                counter[key] += 1
    return dict(counter)


def detect_missing_sections(clean: list[dict]) -> dict[str, list[str]]:
    out = {}
    for rec in clean:
        present = set(rec["secciones"].keys())
        missing = sorted(EXPECTED_SLUGS - present)
        if missing:
            out[rec["nombre"]] = missing
    return out


# Entidades colectivas del dataset que NO son presidentes-persona. Aparecen
# como entradas legitimas del JSONL, pero no las queremos contar como 'otros
# presidentes mencionados' en el cruce. Mantener esta lista sincronizada con
# el dataset.
NON_PERSON_ENTITIES = {
    "Consejo Supremo de Gobierno",
    "Junta Militar de Gobierno",
    "Junta de Salvación Nacional",
    "Revolución Juliana 1925",
    "Revolucion Juliana 1925",
    "Supremo Gobierno Provisional 1883",
    "Junta Provisional de Gobierno",
    "Gobierno Provisional",
}


def _is_person(name: str) -> bool:
    """Heuristica: es presidente-persona si su nombre no esta en la lista de
    entidades colectivas y ademas NO contiene palabras tipicas de organismos."""
    if name in NON_PERSON_ENTITIES:
        return False
    # Cualquier nombre que contenga 'Junta', 'Consejo', 'Gobierno Provisional',
    # 'Revolucion' o 'Supremo Gobierno' se trata como entidad colectiva.
    low = name.lower()
    org_keywords = ["junta", "consejo", "gobierno provisional", "revolucion", "revuelta"]
    return not any(k in low for k in org_keywords)


def detect_cross_president_chunks(clean: list[dict]) -> dict:
    """Para cada presidente-persona, lista chunks donde se mencionan OTROS
    presidentes-persona por apellido. Las entidades colectivas (juntas, consejos)
    se excluyen porque su mencion es esperada y no es bug.

    Severidad por seccion: 'relaciones_internacionales', 'posicionamiento_ideologico',
    'fuentes' -> esperado mencionar otros. 'obra_publica', 'legislacion',
    'datos_demograficos' -> ANORMAL.
    """
    known_persons = [r["nombre"] for r in clean if _is_person(r["nombre"])]
    secciones_esperadas_con_mencion = {
        "relaciones_internacionales",
        "posicionamiento_ideologico",
        "imaginarios",
        "fuentes",
    }
    out = defaultdict(list)
    for rec in clean:
        if not _is_person(rec["nombre"]):
            continue
        nombre = rec["nombre"]
        own_apellido = re.findall(r"[a-záéíóúñ]{5,}", nombre.lower())
        own_last = own_apellido[-1] if own_apellido else None
        for seccion, texto in rec["secciones"].items():
            text_low = texto.lower()
            otros = []
            for otro in known_persons:
                if otro == nombre:
                    continue
                tks = re.findall(r"[a-záéíóúñ]{5,}", otro.lower())
                if not tks:
                    continue
                apellido = tks[-1]
                if apellido == own_last:
                    continue
                if re.search(rf"\b{re.escape(apellido)}\b", text_low):
                    otros.append(otro)
            if not otros:
                continue
            # Filtrar: solo es senal si la mencion es en seccion NO esperada
            # O si es una mencion muy fuerte (>=3 apellidos distintos).
            es_seccion_esperada = seccion in secciones_esperadas_con_mencion
            mencion_fuerte = len(set(otros)) >= 3
            if es_seccion_esperada and not mencion_fuerte:
                continue
            out[nombre].append({
                "seccion": seccion,
                "seccion_esperada": es_seccion_esperada,
                "otros_mencionados": sorted(set(otros))[:5],
                "cantidad_otros": len(set(otros)),
                "snippet": texto[:160].replace("\n", " "),
            })
    return dict(out)


def detect_date_inconsistencies(clean: list[dict]) -> dict:
    """Busca inconsistencias reales en periodos presidenciales. Heuristica:

    Para cada presidente extrae todos los pares (y1, y2) del texto. Un
    presidente con multiples mandatos (Velasco Ibarra tuvo 5) es NORMAL: tiene
    varios pares distintos. Lo ANORMAL es:

      a) Anio de fin < anio de inicio (rango invertido).
      b) Anio de fin fuera de 1500-2030 (basura de OCR/dataset).
      c) Misma par (y1, y2) declarado con cifras distintas en distintas
         secciones (caso raro, pero senala corrupcion del dato).

    Reportamos solo (a) y (b) que son claros. (c) requiere un analisis mas
    fino que dejamos como extension.
    """
    period_re = re.compile(
        r"\b(1[5-9]\d{2}|20\d{2})\s*(?:-|\ba\b|hasta|al?)\s*(\d{2,4})\b",
        re.IGNORECASE,
    )
    out = {}
    for rec in clean:
        nombre = rec["nombre"]
        texto_total = " ".join(rec["secciones"].values())
        hallazgos = []
        pares_vistos = []
        for m in period_re.finditer(texto_total):
            y1 = int(m.group(1))
            y2_str = m.group(2)
            if len(y2_str) == 2:
                y2 = (y1 // 100) * 100 + int(y2_str)
            else:
                y2 = int(y2_str)
            pares_vistos.append((y1, y2, m.group(0)))
            # (a) rango invertido
            if y2 < y1:
                hallazgos.append({
                    "tipo": "rango_invertido",
                    "y1": y1, "y2": y2,
                    "match": m.group(0),
                })
            # (b) anio de fin invalido
            if y2 < 1500 or y2 > 2030:
                hallazgos.append({
                    "tipo": "anio_fin_invalido",
                    "y1": y1, "y2": y2,
                    "match": m.group(0),
                })
        if hallazgos:
            out[nombre] = hallazgos
    return out


def detect_length_anomalies(clean: list[dict]) -> dict:
    out = {"muy_cortas": [], "muy_largas": []}
    for rec in clean:
        for seccion, texto in rec["secciones"].items():
            wc = len(texto.split())
            if wc < 20:
                out["muy_cortas"].append({
                    "presidente": rec["nombre"], "seccion": seccion, "palabras": wc,
                })
            elif wc > 1500:
                out["muy_largas"].append({
                    "presidente": rec["nombre"], "seccion": seccion, "palabras": wc,
                })
    return out


# --- Presentacion ---

def _print_section(title: str, items, severity: str, fmt_fn):
    print(f"\n[{severity}] {title}  ({len(items)})")
    print("-" * 60)
    if not items:
        print("  (ninguno)")
        return
    for item in items[:30]:  # cap para no inundar la consola
        print(f"  - {fmt_fn(item)}")
    if len(items) > 30:
        print(f"  ... y {len(items) - 30} mas (ver audit_report.json)")


def main() -> int:
    print("=" * 60)
    print("AUDITOR DE DATASET - Presidentes del Ecuador (standalone)")
    print("=" * 60)

    raw = load_raw()
    clean = load_clean(raw)
    print(f"Registros crudos (JSONL): {len(raw)}")
    print(f"Registros limpios:        {len(clean)}")
    print(f"Secciones esperadas/pres: {len(EXPECTED_SLUGS)}")

    report = {
        "totales": {
            "registros_raw": len(raw),
            "registros_limpios": len(clean),
            "secciones_esperadas": len(EXPECTED_SLUGS),
        },
        "nombres_sucios": [],
        "claves_no_mapeadas": {},
        "secciones_faltantes": {},
        "chunks_con_cruce_de_presidentes": {},
        "contradicciones_fechas": {},
        "anomalias_longitud": {"muy_cortas": [], "muy_largas": []},
    }

    report["nombres_sucios"] = detect_dirty_names(raw, clean)
    report["claves_no_mapeadas"] = detect_mismapped_keys(raw)
    report["secciones_faltantes"] = detect_missing_sections(clean)
    report["chunks_con_cruce_de_presidentes"] = detect_cross_president_chunks(clean)
    report["contradicciones_fechas"] = detect_date_inconsistencies(clean)
    report["anomalias_longitud"] = detect_length_anomalies(clean)

    # ---- Consola ----
    _print_section(
        "Nombres sucios (texto desbordado)",
        report["nombres_sucios"],
        "ALTA" if report["nombres_sucios"] else "OK",
        lambda x: f"{x['limpio']!r}  [{x['crudo_len']} chars]  {x['motivo']}",
    )

    cn = report["claves_no_mapeadas"]
    _print_section(
        "Claves del JSON no mapeadas en SECTION_SLUGS",
        [{"clave": k, "repeticiones": v} for k, v in cn.items()],
        "MEDIA" if cn else "OK",
        lambda x: f"{x['clave']!r}  (aparece {x['repeticiones']}x)",
    )

    sf = report["secciones_faltantes"]
    _print_section(
        "Secciones faltantes por presidente",
        [{"presidente": k, "faltantes": v} for k, v in sf.items()],
        "MEDIA" if sf else "OK",
        lambda x: f"{x['presidente']}: {', '.join(x['faltantes'])}",
    )

    cruce = report["chunks_con_cruce_de_presidentes"]
    items_cruce = []
    for pres, hallazgos in cruce.items():
        for h in hallazgos:
            items_cruce.append({"presidente": pres, **h})
    _print_section(
        "Chunks que mencionan OTROS presidentes (riesgo de cruce)",
        items_cruce,
        "ALTA" if items_cruce else "OK",
        lambda x: f"{x['presidente']} | {x['seccion']} | otros={x['otros_mencionados']}",
    )

    cf = report["contradicciones_fechas"]
    items_cf = [{"presidente": k, "hallazgos": v} for k, v in cf.items()]
    _print_section(
        "Inconsistencias de fechas (rango invertido o anio invalido)",
        items_cf,
        "ALTA" if items_cf else "OK",
        lambda x: f"{x['presidente']}: {len(x['hallazgos'])} hallazgos -> {x['hallazgos'][:3]}",
    )

    cortas = report["anomalias_longitud"]["muy_cortas"]
    largas = report["anomalias_longitud"]["muy_largas"]
    _print_section(
        "Secciones muy cortas (<20 palabras)",
        cortas,
        "BAJA" if cortas else "OK",
        lambda x: f"{x['presidente']} | {x['seccion']} ({x['palabras']} palabras)",
    )
    _print_section(
        "Secciones muy largas (>1500 palabras, posible duplicacion)",
        largas,
        "MEDIA" if largas else "OK",
        lambda x: f"{x['presidente']} | {x['seccion']} ({x['palabras']} palabras)",
    )

    # ---- Resumen ----
    total = (
        len(report["nombres_sucios"])
        + len(report["claves_no_mapeadas"])
        + len(report["secciones_faltantes"])
        + len(items_cruce)
        + len(items_cf)
        + len(cortas) + len(largas)
    )
    print("\n" + "=" * 60)
    print("RESUMEN")
    print("=" * 60)
    print(f"  Nombres sucios:              {len(report['nombres_sucios'])}")
    print(f"  Claves no mapeadas:          {len(report['claves_no_mapeadas'])}")
    print(f"  Presidentes incompletos:     {len(report['secciones_faltantes'])}")
    print(f"  Chunks con cruce:            {len(items_cruce)}")
    print(f"  Contradicciones de fechas:   {len(items_cf)}")
    print(f"  Secciones muy cortas:        {len(cortas)}")
    print(f"  Secciones muy largas:        {len(largas)}")
    print(f"  ----------------------------------------")
    print(f"  TOTAL:                       {total}")

    with open(REPORT_PATH, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    print(f"\nReporte completo: {REPORT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
