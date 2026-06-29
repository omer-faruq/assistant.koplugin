import os, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import write_companion as wc

class TestWrite(unittest.TestCase):
    def test_writes_identical_named_copies(self):
        with tempfile.TemporaryDirectory() as d:
            repo = os.path.join(d, "companions"); book = os.path.join(d, "book")
            os.makedirs(repo); os.makedirs(book)
            paths = wc.write_both("BODY", "/lib/My Book - Author.epub", repo, book)
            self.assertEqual(len(paths), 2)
            for pth in paths:
                self.assertTrue(pth.endswith("My Book - Author.companion.md"))
                with open(pth) as f:
                    self.assertEqual(f.read(), "BODY")

if __name__ == "__main__":
    unittest.main()
