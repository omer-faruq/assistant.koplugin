import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import common

class TestCommon(unittest.TestCase):
    def test_stem_strips_only_final_extension(self):
        self.assertEqual(
            common.companion_stem("/lib/Stranger in a Strange Land - Robert A. Heinlein.epub"),
            "Stranger in a Strange Land - Robert A. Heinlein")

    def test_stem_keeps_internal_dots(self):
        self.assertEqual(common.companion_stem("/x/A. B. Author - Vol.2.txt"), "A. B. Author - Vol.2")

    def test_filename_appends_companion_md(self):
        self.assertEqual(common.companion_filename("/x/Middlemarch.epub"), "Middlemarch.companion.md")

    def test_estimate_tokens_chars_over_four(self):
        self.assertEqual(common.estimate_tokens("a" * 400), 100)

    def test_estimate_tokens_minimum_one(self):
        self.assertEqual(common.estimate_tokens(""), 1)

if __name__ == "__main__":
    unittest.main()
