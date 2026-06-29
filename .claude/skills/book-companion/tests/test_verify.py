import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import verify_companion as vc

GOOD = (
    "## 1. Quick Orientation\nWorld stuff.\n\n"
    "## 3. Character Dictionary\n"
    "**Dorothea Brooke** — a young woman.\n\n"
    "## 2. Chapter-by-Chapter Plot\n"
    "### Chapter 1\nalpha\n### Chapter 2\nbeta\n\n"
    "## 6. Foreign-Language Phrases\n**incompatibilité d'humeur** — incompatibility.\n"
)
MANIFEST = {"chapters": [{"index": 1, "title": "Chapter 1"}, {"index": 2, "title": "Chapter 2"}]}
SOURCE = "Dorothea Brooke walked. incompatibilité d'humeur."
CANDS = {"foreign_phrases": ["incompatibilité d'humeur"]}

class TestVerify(unittest.TestCase):
    def test_header_clean_true(self):
        self.assertTrue(vc.check_header_clean(GOOD))

    def test_header_clean_false_on_stray_prefix(self):
        self.assertFalse(vc.check_header_clean("Ha## 1. Quick Orientation\n"))

    def test_extract_character_names(self):
        self.assertIn("Dorothea Brooke", vc.extract_character_names(GOOD))

    def test_chapter_coverage_full(self):
        cov = vc.chapter_coverage(GOOD, MANIFEST)
        self.assertEqual(cov["covered"], 2)
        self.assertEqual(cov["missing"], [])

    def test_chapter_coverage_missing(self):
        m = {"chapters": [{"index": 1, "title": "Chapter 1"},
                          {"index": 2, "title": "Chapter 2"},
                          {"index": 3, "title": "Chapter 3"}]}
        cov = vc.chapter_coverage(GOOD, m)
        self.assertEqual(cov["missing"], [3])

    def test_names_missing_from_source(self):
        self.assertEqual(vc.names_missing_from_source(["Dorothea Brooke"], SOURCE), [])
        self.assertEqual(vc.names_missing_from_source(["Casobon"], SOURCE), ["Casobon"])

    def test_phrases_uncovered(self):
        self.assertEqual(vc.phrases_uncovered(GOOD, CANDS["foreign_phrases"]), [])
        self.assertEqual(vc.phrases_uncovered(GOOD, ["dolce far niente"]), ["dolce far niente"])

    def test_verify_ok(self):
        report = vc.verify(GOOD, SOURCE, MANIFEST, CANDS, "Middlemarch",
                           ["/a/Middlemarch.companion.md", "/b/Middlemarch.companion.md"])
        self.assertTrue(report["ok"])

    def test_verify_fails_on_bad_stem(self):
        report = vc.verify(GOOD, SOURCE, MANIFEST, CANDS, "Middlemarch",
                           ["/a/Wrong.companion.md"])
        self.assertFalse(report["ok"])

    def test_verify_ok_despite_advisory_noise(self):
        # Bold group-label not present in source, plus an uncovered foreign-phrase candidate.
        # These are advisory: ok must still be True when the hard gates pass.
        companion = (
            "## 1. Quick Orientation\nWorld stuff.\n\n"
            "## 3. Character Dictionary\n"
            "**Dr. Sprague & Mr. Wrench & Mr. Toller** — physicians.\n\n"  # not in SOURCE
            "## 2. Chapter-by-Chapter Plot\n"
            "### Chapter 1\nalpha\n### Chapter 2\nbeta\n\n"
            "## 6. Foreign-Language Phrases\n**dolce far niente** — sweetness.\n"
        )
        # Source does NOT contain the bold group label
        source = "Dr. Sprague walked. Some English text."
        manifest = {"chapters": [{"index": 1, "title": "Chapter 1"},
                                  {"index": 2, "title": "Chapter 2"}]}
        # Candidate phrase is NOT present in companion text
        cands = {"foreign_phrases": ["incompatibilité d'humeur"]}
        report = vc.verify(companion, source, manifest, cands, "Middlemarch",
                           ["/a/Middlemarch.companion.md"])
        self.assertTrue(report["ok"])
        self.assertTrue(len(report["checks"]["names_missing_from_source"]) > 0,
                        "names_missing_from_source should be non-empty (advisory)")
        self.assertTrue(len(report["checks"]["phrases_uncovered"]) > 0,
                        "phrases_uncovered should be non-empty (advisory)")

    def test_verify_fails_on_missing_chapter(self):
        manifest_with_extra = {"chapters": [
            {"index": 1, "title": "Chapter 1"},
            {"index": 2, "title": "Chapter 2"},
            {"index": 3, "title": "Chapter 3"},
        ]}
        # GOOD only covers chapters 1 and 2
        report = vc.verify(GOOD, SOURCE, manifest_with_extra, CANDS, "Middlemarch",
                           ["/a/Middlemarch.companion.md"])
        self.assertFalse(report["ok"])

    def test_verify_fails_on_dirty_header(self):
        dirty = "Ha## 1. Quick Orientation\nWorld stuff.\n\n" + GOOD[GOOD.index("## 3"):]
        report = vc.verify(dirty, SOURCE, MANIFEST, CANDS, "Middlemarch",
                           ["/a/Middlemarch.companion.md"])
        self.assertFalse(report["ok"])

if __name__ == "__main__":
    unittest.main()
