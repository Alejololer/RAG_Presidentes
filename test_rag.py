"""
Pruebas de verificación del RAG (carga, chunking, detección y aislamiento).
Ejecutar:  .venv\Scripts\python.exe test_rag.py
"""

import json

from utils import (
    load_records,
    build_chunks,
    get_known_names,
    detect_president,
    retrieve,
    _key_to_slug,
    _normalize,
)


def test_carga_y_chunking():
    print("=== Carga y chunking ===")
    recs = load_records()
    print("Presidentes cargados:", len(recs))
    print("Ejemplo nombre:", recs[0]["nombre"])
    print("Nº secciones (1er presidente):", len(recs[0]["secciones"]))

    # Ninguna sección debe quedar sin mapear.
    raw = []
    for line in open("presidentes_ecuador.json", encoding="utf-8"):
        line = line.strip()
        if line:
            raw.append(json.loads(line))
    unmapped = set()
    for item in raw:
        for k in item.keys():
            if _normalize(k).startswith("nombre"):
                continue
            if _key_to_slug(k) is None:
                unmapped.add(k)
    print("Claves NO mapeadas:", unmapped if unmapped else "NINGUNA (ok)")

    chunks = build_chunks(recs)
    print("Total chunks:", len(chunks))
    print("Ejemplo id:", chunks[0]["id"])
    print()


def test_deteccion():
    print("=== Detección de presidente ===")
    names = get_known_names()
    # (pregunta, nombre canónico esperado o None). Incluye casos de regresión:
    # - puntuación pegada al token ("Moreno,")
    # - distinguir García Moreno de Lenín Moreno Garcés
    # - nombres que estaban contaminados en el dataset (Mancheno)
    casos = [
        ("Garcia Moreno, que obras hiciste?", "Gabriel García Moreno"),
        ("Que obras hizo Gabriel Garcia Moreno?", "Gabriel García Moreno"),
        ("Hablame de Eloy Alfaro", "Eloy Alfaro Delgado"),
        ("Cuentame de Bucaram", "Abdalá Bucaram Ortiz"),
        ("Cuentame de Mancheno", "Carlos Mancheno Cajas"),
        ("Lenin Moreno y la economia", "Lenín Moreno Garcés"),
        ("Cual es la capital de Francia?", None),
    ]
    todos_ok = True
    for q, esperado in casos:
        obtenido = detect_president(q, names)
        ok = obtenido == esperado
        todos_ok = todos_ok and ok
        marca = "OK" if ok else f"FALLO (esperaba {esperado!r})"
        print(f"  [{marca}] {q!r} -> {obtenido!r}")
    print("DETECCIÓN:", "TODO OK" if todos_ok else "HAY FALLOS")
    print()


def test_aislamiento():
    print("=== Aislamiento por presidente (bug original) ===")
    names = get_known_names()
    objetivo = next((n for n in names if "Alfaro" in n), names[0])
    res = retrieve("principales logros y obras", president=objetivo, top_k=5)
    print(f"Consulta filtrada por: {objetivo!r}  -> {len(res)} resultados")
    ok = all(r["presidente"] == objetivo for r in res)
    for r in res:
        print(f"   [{r['presidente']}] {r['seccion']} (dist={r['distance']:.3f})")
    print("AISLAMIENTO CORRECTO:" , "SÍ" if ok else "NO ❌ (hay mezcla)")
    print()


if __name__ == "__main__":
    test_carga_y_chunking()
    test_deteccion()
    test_aislamiento()
