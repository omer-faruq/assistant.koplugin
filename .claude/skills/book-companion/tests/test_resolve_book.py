import os, sys, json, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import resolve_book as rb

ONE = json.dumps([{
    "id": 48, "title": "Stranger in a Strange Land", "authors": "Robert A. Heinlein",
    "formats": ["/lib/SiaSL - Robert A. Heinlein.mobi", "/lib/SiaSL - Robert A. Heinlein.epub"],
}])
MANY = json.dumps([
    {"id": 1, "title": "Hamlet", "authors": "Shakespeare", "formats": ["/l/Hamlet.epub"]},
    {"id": 2, "title": "Hamlet (annotated)", "authors": "Shakespeare", "formats": ["/l/Hamlet2.epub"]},
])
ONE_NO_FORMAT = json.dumps([{
    "id": 99, "title": "PDF Only Book", "authors": "Unknown",
    "formats": ["/lib/pdf_only.pdf"],
}])

class TestResolve(unittest.TestCase):
    def test_choose_format_prefers_epub(self):
        self.assertEqual(rb.choose_format(["/a/x.mobi", "/a/x.epub", "/a/x.md"]), "/a/x.epub")

    def test_choose_format_falls_back_to_md_then_txt(self):
        self.assertEqual(rb.choose_format(["/a/x.mobi", "/a/x.md"]), "/a/x.md")
        self.assertEqual(rb.choose_format(["/a/x.txt"]), "/a/x.txt")

    def test_choose_format_none(self):
        self.assertIsNone(rb.choose_format(["/a/x.pdf"]))

    def test_resolve_single_match(self):
        out = rb.resolve("Stranger", runner=lambda t: ONE)
        self.assertEqual(out["status"], "resolved")
        self.assertEqual(out["source"], "/lib/SiaSL - Robert A. Heinlein.epub")

    def test_resolve_ambiguous(self):
        out = rb.resolve("Hamlet", runner=lambda t: MANY)
        self.assertEqual(out["status"], "ambiguous")
        self.assertEqual(len(out["candidates"]), 2)

    def test_resolve_not_found(self):
        out = rb.resolve("Nope", runner=lambda t: "[]")
        self.assertEqual(out["status"], "not_found")

    def test_resolve_single_match_no_usable_format(self):
        """Single candidate with only PDF (unsupported format) should return not_found."""
        out = rb.resolve("PDF Only", runner=lambda t: ONE_NO_FORMAT)
        self.assertEqual(out["status"], "not_found")

if __name__ == "__main__":
    unittest.main()
