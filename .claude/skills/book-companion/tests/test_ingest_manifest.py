import os, sys, json, tempfile, subprocess, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import ingest

MD = "# Chapter 1\nalpha\n\n# Chapter 2\nbeta\n\n# Chapter 3\ngamma\n"

class TestManifest(unittest.TestCase):
    def test_manifest_small_has_no_parts(self):
        man = ingest.build_manifest(MD, "/x/My Book.txt", "headings",
                                    {"title": "My Book", "author": "A", "language": "en"})
        self.assertEqual(man["size_class"], "small")
        self.assertEqual(man["parts"], [])
        self.assertEqual(man["source_stem"], "My Book")
        self.assertEqual(len(man["chapters"]), 3)
        self.assertEqual(man["structural_confidence"], "high")

    def test_manifest_large_has_parts(self):
        big = "# A\n" + ("x" * 300000) + "\n# B\n" + ("y" * 300000) + "\n"
        man = ingest.build_manifest(big, "/x/Big.epub", "headings",
                                    {"title": "Big", "author": "A", "language": "en"})
        self.assertEqual(man["size_class"], "large")
        self.assertTrue(len(man["parts"]) >= 2)

    def test_cli_writes_outputs(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "Sample.txt")
            with open(src, "w") as f:
                f.write(MD)
            out = os.path.join(d, "work")
            os.makedirs(out)
            rc = subprocess.call([sys.executable,
                os.path.join(os.path.dirname(__file__), "..", "scripts", "ingest.py"),
                src, "--out", out])
            self.assertEqual(rc, 0)
            self.assertTrue(os.path.exists(os.path.join(out, "normalized.md")))
            with open(os.path.join(out, "manifest.json")) as f:
                man = json.load(f)
            self.assertEqual(man["source_stem"], "Sample")

    def test_convert_strips_inline_html(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "book.md")
            with open(src, "w") as f:
                f.write(
                    '# <span class="se:label">Book</span> One\n\n'
                    "body <span>x</span> text\n"
                )
            markdown, detected, meta = ingest.convert_to_markdown(src)
            self.assertNotIn("<span", markdown)
            chapters = ingest.split_into_chapters(markdown)
            self.assertEqual(chapters[0]["title"], "Book One")

    @unittest.skipUnless(__import__("shutil").which("pandoc"), "pandoc not installed")
    def test_epub_conversion_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            md = os.path.join(d, "src.md")
            epub = os.path.join(d, "Fixture Book.epub")
            with open(md, "w") as f:
                f.write("# One\nalpha\n\n# Two\nbeta\n")
            subprocess.check_call(["pandoc", md, "-o", epub,
                                   "--metadata", "title=Fixture Book"])
            markdown, detected, meta = ingest.convert_to_markdown(epub)
            self.assertIn("One", markdown)
            self.assertEqual(detected, "headings")

if __name__ == "__main__":
    unittest.main()
