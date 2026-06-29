import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import harvest_candidates as hc

MD = (
    "# One\n"
    "> An epigraph line\n\n"
    "Casaubon spoke of *incompatibilité d'humeur* to Dorothea.\n"
    "Will Ladislaw met Dorothea. Will Ladislaw left.\n"
    "Naïve readers note the café.\n"
)

class TestHarvest(unittest.TestCase):
    def test_emphasis_phrase_captured(self):
        out = hc.harvest(MD)
        self.assertIn("incompatibilité d'humeur", out["foreign_phrases"])

    def test_accented_run_captured(self):
        out = hc.harvest(MD)
        joined = " ".join(out["foreign_phrases"])
        self.assertTrue("Naïve" in joined or "café" in joined)

    def test_epigraph_captured(self):
        out = hc.harvest(MD)
        self.assertIn("An epigraph line", out["epigraphs"])

    def test_repeated_proper_noun(self):
        out = hc.harvest(MD)
        self.assertIn("Will Ladislaw", out["proper_nouns"])

    def test_single_occurrence_not_a_proper_noun(self):
        out = hc.harvest("# T\nNaumann appeared once.\n")
        self.assertNotIn("Naumann", out["proper_nouns"])

if __name__ == "__main__":
    unittest.main()
