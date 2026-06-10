"""
Tests unitarios para research_tool.py.

Cubre:
  - should_research: trigger conservador (4 casos de disparo + 2 de no-disparo).
  - wikipedia_search: integracion con API de Wikipedia (mockeada).
  - _extract_relevant: filtro de relevancia por presidente.
  - _truncate: limite de palabras.
  - research_for_chat: wrapper de alto nivel (4 escenarios end-to-end con mock).

Los tests usan unittest.mock para evitar dependencias de red y de Ollama.
Para ejecutarlos:
    python3 -m unittest test_research.py -v
"""

import sys
import unittest
from unittest.mock import MagicMock, patch

# Mockear 'requests' ANTES de importar research_tool para que el modulo
# cargue sin requerir la libreria instalada.
sys.modules.setdefault("requests", MagicMock())

# Asegurar que podemos importar research_tool desde el directorio actual.
sys.path.insert(0, ".")

import research_tool as rt  # noqa: E402


# --- Helpers de mock ---------------------------------------------------

def _mock_search_response(titles_with_ids: list[tuple[str, int]]) -> MagicMock:
    """Crea una respuesta simulada de /w/api.php?action=query&list=search."""
    m = MagicMock()
    m.json.return_value = {
        "query": {
            "search": [
                {"title": t, "pageid": pid} for t, pid in titles_with_ids
            ]
        }
    }
    m.raise_for_status = MagicMock()
    return m


def _mock_extracts_response(pageid_to_extract: dict[int, str]) -> MagicMock:
    """Crea una respuesta simulada de /w/api.php?prop=extracts."""
    m = MagicMock()
    m.json.return_value = {
        "query": {
            "pages": {
                str(pid): {"extract": extract}
                for pid, extract in pageid_to_extract.items()
            }
        }
    }
    m.raise_for_status = MagicMock()
    return m


def _fake_wiki_get_factory(
    search_titles: list[tuple[str, int]],
    extracts: dict[int, str],
):
    """Devuelve una funcion side_effect para mockear requests.get."""
    def fake_get(url, **kwargs):
        params = kwargs.get("params", {})
        if params.get("list") == "search":
            return _mock_search_response(search_titles)
        return _mock_extracts_response(extracts)
    return fake_get


# --- Tests del trigger -------------------------------------------------

class TestShouldResearch(unittest.TestCase):

    def test_triggers_when_no_president(self):
        """Pregunta general sin presidente: debe disparar research."""
        self.assertTrue(rt.should_research([], "historia del ecuador", None))

    def test_triggers_with_zero_local_chunks(self):
        """Si el retrieval local no devolvio nada, disparar."""
        self.assertTrue(rt.should_research(
            [], "que hizo Alfaro", "Eloy Alfaro Delgado"
        ))

    def test_does_not_trigger_with_strong_local_chunks(self):
        """Chunks a distancia baja: NO disparar (datos locales solidos)."""
        chunks = [{"distance": 0.30}, {"distance": 0.35}]
        self.assertFalse(rt.should_research(
            chunks, "cuales fueron sus obras", "Eloy Alfaro Delgado"
        ))

    def test_triggers_with_weak_local_chunks(self):
        """Chunks a distancia alta (>0.5 promedio): disparar como complemento."""
        chunks = [{"distance": 0.60}, {"distance": 0.55}]
        self.assertTrue(rt.should_research(
            chunks, "cualquier cosa", "Eloy Alfaro Delgado"
        ))

    def test_triggers_with_explicit_external_signal(self):
        """Senales explicitas del usuario (ej. 'segun fuentes externas')."""
        chunks = [{"distance": 0.30}]
        self.assertTrue(rt.should_research(
            chunks, "segun fuentes externas, que opino?",
            "Eloy Alfaro Delgado"
        ))

    def test_does_not_trigger_in_normal_case(self):
        """Caso normal: chunks solidos, sin trigger explicito."""
        chunks = [{"distance": 0.40}, {"distance": 0.42}]
        self.assertFalse(rt.should_research(
            chunks, "que obras hizo", "Eloy Alfaro Delgado"
        ))


# --- Tests de wikipedia_search -----------------------------------------

class TestWikipediaSearch(unittest.TestCase):

    def setUp(self):
        # Limpiar cache entre tests
        rt._cache.clear()

    def test_returns_extracts(self):
        """wikipedia_search devuelve [{title, extract, url}, ...]."""
        fake_get = _fake_wiki_get_factory(
            search_titles=[("Eloy Alfaro", 12345), ("Historia del Ecuador", 67890)],
            extracts={
                12345: "Eloy Alfaro Delgado fue presidente de Ecuador entre 1895 y 1911. Lidero la Revolucion Liberal y modernizo el pais con el ferrocarril Transandino.",
                67890: "La historia de Ecuador incluye la Revolucion Liberal de 1895 liderada por Alfaro y la conexion con el ferrocarril como simbolo de progreso nacional.",
            },
        )
        with patch("research_tool.requests.get", side_effect=fake_get):
            results = rt.wikipedia_search("Eloy Alfaro Delgado Ecuador")
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0]["title"], "Eloy Alfaro")
        self.assertIn("presidente", results[0]["extract"])
        self.assertTrue(results[0]["url"].startswith("https://es.wikipedia.org/wiki/"))

    def test_returns_empty_on_network_failure(self):
        """Si la API falla, devuelve lista vacia (degrada con gracia)."""
        def failing_get(url, **kwargs):
            raise ConnectionError("network down")
        with patch("research_tool.requests.get", side_effect=failing_get):
            results = rt.wikipedia_search("Eloy Alfaro")
        self.assertEqual(results, [])

    def test_filters_short_extracts(self):
        """Extractos demasiado cortos (<80 chars) se descartan."""
        fake_get = _fake_wiki_get_factory(
            search_titles=[("Eloy Alfaro", 12345)],
            extracts={12345: "corto"},  # < MIN_CHARS_PER_EXTRACT
        )
        with patch("research_tool.requests.get", side_effect=fake_get):
            results = rt.wikipedia_search("Eloy Alfaro")
        self.assertEqual(len(results), 0)

    def test_uses_cache(self):
        """La segunda llamada con la misma query NO hace request HTTP."""
        fake_get = _fake_wiki_get_factory(
            search_titles=[("Eloy Alfaro", 12345)],
            extracts={12345: "Eloy Alfaro Delgado fue presidente de Ecuador y lidero la Revolucion Liberal."},
        )
        with patch("research_tool.requests.get", side_effect=fake_get) as mock_get:
            rt.wikipedia_search("Eloy Alfaro")
            rt.wikipedia_search("Eloy Alfaro")
            rt.wikipedia_search("Eloy Alfaro")
        # Solo 2 calls en la primera invocacion (search + extracts).
        self.assertEqual(mock_get.call_count, 2)


# --- Tests del filtro de relevancia ------------------------------------

class TestExtractRelevant(unittest.TestCase):

    def test_keeps_only_mentions_of_president(self):
        """Extrae solo los resultados que mencionan al presidente."""
        results = [
            {"title": "Eloy Alfaro", "extract": "Eloy Alfaro Delgado fue presidente liberal del Ecuador y modernizo el pais con la construccion del ferrocarril."},
            {"title": "Gabriel Garcia Moreno", "extract": "Gabriel Garcia Moreno fue un presidente conservador del Ecuador en el siglo XIX, opuesto a las ideas liberales."},
            {"title": "Historia Ecuador", "extract": "La historia de Ecuador incluye presidentes como Alfaro y Plaza Lasso que fueron relevantes en el siglo XX."},
        ]
        filtered = rt._extract_relevant("Eloy Alfaro Delgado", results)
        titles = {r["title"] for r in filtered}
        # Garcia Moreno NO menciona a Alfaro -> se filtra.
        # Los otros dos SI lo mencionan.
        self.assertIn("Eloy Alfaro", titles)
        self.assertIn("Historia Ecuador", titles)
        self.assertNotIn("Gabriel Garcia Moreno", titles)

    def test_returns_all_if_none_mention_president(self):
        """Si NADIE menciona al presidente, devuelve los originales (mejor que nada)."""
        results = [
            {"title": "Ecuador", "extract": "Ecuador es un pais sudamericano con una rica historia politica y cultural que se extiende por siglos."},
        ]
        filtered = rt._extract_relevant("Presidente Inexistente", results)
        self.assertEqual(len(filtered), 1)


# --- Tests de truncate --------------------------------------------------

class TestTruncate(unittest.TestCase):

    def test_short_text_unchanged(self):
        self.assertEqual(rt._truncate("hola mundo", 50), "hola mundo")

    def test_long_text_truncated(self):
        text = "palabra " * 300
        out = rt._truncate(text, 50)
        self.assertLessEqual(len(out.split()), 52)  # 50 + '...'
        self.assertTrue(out.endswith("..."))


# --- Tests del wrapper research_for_chat --------------------------------

class TestResearchForChat(unittest.TestCase):

    def setUp(self):
        rt._cache.clear()

    def test_scenario_a_strong_local_no_research(self):
        """Chunks locales fuertes -> NO triggerea, devuelve vacio."""
        fake_get = _fake_wiki_get_factory(
            search_titles=[("Eloy Alfaro", 12345)],
            extracts={12345: "Eloy Alfaro Delgado presidente."},
        )
        with patch("research_tool.requests.get", side_effect=fake_get) as mock_get:
            ctx, fuentes = rt.research_for_chat(
                [{"distance": 0.3}, {"distance": 0.35}],
                "cuales fueron sus obras", "Eloy Alfaro Delgado"
            )
        self.assertEqual(ctx, "")
        self.assertEqual(fuentes, [])
        self.assertEqual(mock_get.call_count, 0)

    def test_scenario_b_no_local_research_triggers(self):
        """0 chunks locales -> triggerea, devuelve contexto de Wikipedia."""
        fake_get = _fake_wiki_get_factory(
            search_titles=[("Eloy Alfaro", 12345)],
            extracts={12345: "Eloy Alfaro Delgado fue presidente de Ecuador entre 1895 y 1911 y lidero la Revolucion Liberal con el apoyo de sectores populares."},
        )
        with patch("research_tool.requests.get", side_effect=fake_get):
            ctx, fuentes = rt.research_for_chat(
                [], "que hizo Alfaro", "Eloy Alfaro Delgado"
            )
        self.assertIn("Revolucion Liberal", ctx)
        self.assertEqual(len(fuentes), 1)
        self.assertEqual(fuentes[0]["titulo"], "Eloy Alfaro")

    def test_scenario_c_weak_local_research_complements(self):
        """Chunks debiles (distancia alta) -> research complementa."""
        fake_get = _fake_wiki_get_factory(
            search_titles=[("Eloy Alfaro", 12345)],
            extracts={12345: "Eloy Alfaro Delgado fue presidente y modernizo el pais con la construccion del ferrocarril Transandino que unio costa y sierra."},
        )
        with patch("research_tool.requests.get", side_effect=fake_get):
            ctx, fuentes = rt.research_for_chat(
                [{"distance": 0.60}, {"distance": 0.55}],
                "que hizo", "Eloy Alfaro Delgado"
            )
        self.assertIn("ferrocarril", ctx)
        self.assertEqual(len(fuentes), 1)

    def test_scenario_d_no_president_general_query(self):
        """Pregunta general sin presidente -> triggerea sin filtro."""
        fake_get = _fake_wiki_get_factory(
            search_titles=[("Historia del Ecuador", 67890)],
            extracts={67890: "La historia de Ecuador incluye multiples periodos politicos y transformaciones sociales desde la colonia hasta la actualidad."},
        )
        with patch("research_tool.requests.get", side_effect=fake_get):
            ctx, fuentes = rt.research_for_chat(
                [], "historia del ecuador en el siglo XX", None
            )
        self.assertIn("Ecuador", ctx)
        self.assertEqual(len(fuentes), 1)

    def test_explicit_external_trigger(self):
        """Senales explicitas en la pregunta disparan research."""
        fake_get = _fake_wiki_get_factory(
            search_titles=[("Eloy Alfaro", 12345)],
            extracts={12345: "Eloy Alfaro Delgado fue presidente liberal modernizador que impulso la separacion de la Iglesia y el Estado en Ecuador."},
        )
        with patch("research_tool.requests.get", side_effect=fake_get):
            ctx, fuentes = rt.research_for_chat(
                [{"distance": 0.3}],  # chunks fuertes
                "segun fuentes externas, que opino del modelo?",
                "Eloy Alfaro Delgado"
            )
        # A pesar de los chunks fuertes, el trigger explicito dispara.
        self.assertNotEqual(ctx, "")
        self.assertEqual(len(fuentes), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
