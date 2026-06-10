"""
Deduplicador del dataset presidentes_ecuador.jsonl.

El audit detecto que 64 secciones tienen >1500 palabras, con parrafos enteros
repetidos literalmente (ej: Velasco Ibarra tiene la frase 'fue presidente de
Ecuador en cinco ocasiones...' 10 veces). Esto diluye el contexto que recibe
la LLM, gasta tokens y empuja a respuestas repetitivas.

Este script:
  1. Carga el JSONL.
  2. Para cada (presidente, seccion), divide el texto en parrafos.
  3. Normaliza cada parrafo (minusculas, sin acentos, colapsa espacios) y
     deduplica preservando la PRIMERA ocurrencia (no la ultima, porque suele
     ser la mas completa).
  4. Detecta tambien 'casi-duplicados' (>=85% de palabras en comun) y los
     colapsa.
  5. Escribe el resultado en presidentes_ecuador.dedup.jsonl SIN TOCAR el
     original.
  6. Imprime un reporte antes/despues.

NO usar el dedup sin revision humana previa. La idea es:
    python3 fix_duplicates.py
    # revisa presidentes_ecuador.dedup.jsonl
    # si esta bien: mv presidentes_ecuador.dedup.jsonl presidentes_ecuador.json
    # re-indexar: python generate_embeddings.py

Uso:
    python3 fix_duplicates.py
"""

import json
import re
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

SRC_PATH = Path("presidentes_ecuador.json")
OUT_PATH = Path("presidentes_ecuador.dedup.jsonl")
REPORT_PATH = Path("dedup_report.json")

# Umbral de similitud Jaccard sobre palabras para colapsar 'casi-duplicados'.
# 0.85 = muy parecidos, difieren solo en pequenas variaciones de redaccion.
JACCARD_THRESHOLD = 0.85

# Section slugs (copia del audit para autonomia).
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


def _strip_accents(text: str) -> str:
    nfkd = unicodedata.normalize("NFKD", text)
    return "".join(c for c in nfkd if not unicodedata.combining(c))


def _normalize_text(text: str) -> str:
    """Para comparar parrafos: minusculas, sin tildes, espacios colapsados."""
    t = _strip_accents(text).lower()
    t = re.sub(r"\s+", " ", t).strip()
    return t


def _jaccard(a: set, b: set) -> float:
    if not a or not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0


def _key_to_slug(key: str):
    nk = re.sub(r"\s+", " ", _strip_accents(key).lower()).strip()
    if nk.startswith("nombre"):
        return None
    for substrings, slug in SECTION_SLUGS:
        if any(s in nk for s in substrings):
            return slug
    return None


def _split_paragraphs(text: str) -> list[str]:
    """Divide un texto en parrafos. Tolerante a \n, \n\n, \r\n."""
    # Primero normalizar saltos de linea multiples.
    text = re.sub(r"\r\n", "\n", text)
    paras = re.split(r"\n\s*\n+", text)
    return [p.strip() for p in paras if p and p.strip()]


def _dedupe_paragraphs(paragraphs: list[str]) -> tuple[list[str], dict]:
    """Deduplica parrafos usando Jaccard sobre el conjunto de palabras.

    Estrategia greedy: para cada parrafo nuevo, si es casi-duplicado (>=
    JACCARD_THRESHOLD) de uno ya aceptado, se descarta. Si no, se acepta.

    Devuelve (parrafos_aceptados, stats).
    """
    accepted: list[str] = []
    accepted_norms: list[str] = []
    accepted_word_sets: list[set] = []
    dropped_exact = 0
    dropped_fuzzy = 0

    for p in paragraphs:
        norm = _normalize_text(p)
        if not norm:
            continue
        # Match exacto contra la lista de ya aceptados.
        if norm in accepted_norms:
            dropped_exact += 1
            continue
        # Match fuzzy: comparar contra aceptados recientes (cota de comparacion).
        word_set = set(re.findall(r"\w+", norm))
        if not word_set:
            continue
        is_dup = False
        for prev_set in accepted_word_sets[-30:]:  # ventana: ultimos 30 aceptados
            if _jaccard(word_set, prev_set) >= JACCARD_THRESHOLD:
                is_dup = True
                dropped_fuzzy += 1
                break
        if is_dup:
            continue
        accepted.append(p)
        accepted_norms.append(norm)
        accepted_word_sets.append(word_set)

    return accepted, {
        "parrafos_originales": len(paragraphs),
        "parrafos_aceptados": len(accepted),
        "dropped_exact": dropped_exact,
        "dropped_fuzzy": dropped_fuzzy,
    }


def main() -> int:
    print("=" * 60)
    print("DEDUPLICADOR DE DATASET - Presidentes del Ecuador")
    print("=" * 60)
    print(f"Origen:  {SRC_PATH}")
    print(f"Destino: {OUT_PATH}")
    print(f"Umbral Jaccard: {JACCARD_THRESHOLD}")
    print()

    # Cargar
    with open(SRC_PATH, "r", encoding="utf-8") as f:
        registros = [json.loads(line) for line in f if line.strip()]

    print(f"Registros cargados: {len(registros)}\n")

    # Procesar registro por registro, seccion por seccion.
    output_records = []
    cambios_por_seccion = []
    total_dropped = 0
    total_secciones_modificadas = 0

    for reg in registros:
        out_reg = {}
        for key, value in reg.items():
            # Mantener 'Nombre' (u otros campos no-seccion) sin tocar.
            slug = _key_to_slug(key)
            if not slug or not value or not str(value).strip():
                out_reg[key] = value
                continue
            texto_original = str(value)
            paras = _split_paragraphs(texto_original)
            if len(paras) <= 1:
                # Secciones de 1 solo parrafo: no hay que deduplicar.
                out_reg[key] = value
                continue
            aceptados, stats = _dedupe_paragraphs(paras)
            if stats["dropped_exact"] + stats["dropped_fuzzy"] == 0:
                # Nada que deduplicar: dejar igual.
                out_reg[key] = value
                continue
            texto_limpio = "\n\n".join(aceptados)
            out_reg[key] = texto_limpio

            wc_orig = len(texto_original.split())
            wc_new = len(texto_limpio.split())
            nombre = str(reg.get("Nombre", "")).split("\n")[0].strip().split("  ")[0].strip()
            cambios_por_seccion.append({
                "presidente": nombre,
                "seccion_slug": slug,
                "seccion_clave": key[:60],
                "palabras_orig": wc_orig,
                "palabras_dedup": wc_new,
                "reduccion_pct": round(100 * (wc_orig - wc_new) / max(wc_orig, 1), 1),
                **stats,
            })
            total_dropped += stats["dropped_exact"] + stats["dropped_fuzzy"]
            total_secciones_modificadas += 1

        output_records.append(out_reg)

    # Escribir destino (JSONL, un objeto por linea).
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        for r in output_records:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    # Reporte
    print(f"Salida: {OUT_PATH}  ({len(output_records)} registros)")
    print(f"Secciones modificadas: {total_secciones_modificadas}")
    print(f"Parrafos eliminados:   {total_dropped}")
    print()

    # Top 10 secciones con mayor reduccion.
    cambios_por_seccion.sort(key=lambda x: x["palabras_orig"] - x["palabras_dedup"], reverse=True)
    print("TOP 10 SECCIONES CON MAYOR REDUCCION DE PALABRAS:")
    print("-" * 80)
    print(f"  {'Presidente':<35} {'Seccion':<25} {'orig':>6} -> {'dedup':>6}  {'%':>5}")
    for c in cambios_por_seccion[:10]:
        print(f"  {c['presidente'][:34]:<35} {c['seccion_slug'][:24]:<25} "
              f"{c['palabras_orig']:>6} -> {c['palabras_dedup']:>6}  {c['reduccion_pct']:>5}%")

    # Totales
    total_orig = sum(c["palabras_orig"] for c in cambios_por_seccion)
    total_new = sum(c["palabras_dedup"] for c in cambios_por_seccion)
    if total_orig:
        pct = 100 * (total_orig - total_new) / total_orig
        print(f"\nTotal: {total_orig} -> {total_new} palabras ({pct:.1f}% reduccion)")

    # Guardar reporte estructurado.
    with open(REPORT_PATH, "w", encoding="utf-8") as f:
        json.dump({
            "registros": len(output_records),
            "secciones_modificadas": total_secciones_modificadas,
            "parrafos_eliminados": total_dropped,
            "palabras_orig": total_orig,
            "palabras_dedup": total_new,
            "reduccion_pct": round(pct, 2) if total_orig else 0,
            "detalle": cambios_por_seccion,
        }, f, ensure_ascii=False, indent=2)
    print(f"\nReporte: {REPORT_PATH}")

    # Sugerencia
    print("\n" + "=" * 60)
    print("SIGUIENTE PASO MANUAL")
    print("=" * 60)
    print(f"  1. Revisa {OUT_PATH} (no se toco el original).")
    print("  2. Si esta bien:")
    print(f"     mv {OUT_PATH} {SRC_PATH}")
    print("     python generate_embeddings.py    # re-indexar")
    print("  3. Si algo no convence: borra el .dedup y vuelve a empezar.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
