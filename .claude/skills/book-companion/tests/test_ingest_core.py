import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import ingest

MD = "# Chapter 1\nalpha\n\n# Chapter 2\nbeta\n\n# Chapter 3\ngamma\n"

class TestIngestCore(unittest.TestCase):
    def test_split_counts_and_titles(self):
        chs = ingest.split_into_chapters(MD)
        self.assertEqual([c["title"] for c in chs], ["Chapter 1", "Chapter 2", "Chapter 3"])
        self.assertEqual(chs[0]["index"], 1)

    def test_split_offsets_are_contiguous_and_cover_text(self):
        chs = ingest.split_into_chapters(MD)
        self.assertEqual(chs[0]["char_start"], 0)
        self.assertEqual(chs[-1]["char_end"], len(MD))
        for a, b in zip(chs, chs[1:]):
            self.assertEqual(a["char_end"], b["char_start"])

    def test_split_no_headings_yields_single_full_text(self):
        chs = ingest.split_into_chapters("just prose, no headings")
        self.assertEqual(len(chs), 1)
        self.assertEqual(chs[0]["title"], "Full Text")

    def test_confidence_high_with_three_heading_chapters(self):
        chs = ingest.split_into_chapters(MD)
        self.assertEqual(ingest.structural_confidence(chs, "headings"), "high")

    def test_confidence_low_for_fallback(self):
        self.assertEqual(ingest.structural_confidence([{"index": 1}], "none"), "low")

    def test_classify_size(self):
        self.assertEqual(ingest.classify_size(100), "small")
        self.assertEqual(ingest.classify_size(60000), "large")

    def test_target_parts_bounds(self):
        self.assertEqual(ingest.target_parts(100), 2)
        self.assertEqual(ingest.target_parts(10_000_000), 12)

    def test_plan_parts_balances_contiguously(self):
        chs = ingest.split_into_chapters(MD)
        parts = ingest.plan_parts(chs, 2)
        self.assertEqual(len(parts), 2)
        self.assertEqual(parts[0]["chapter_range"][0], 1)
        self.assertEqual(parts[-1]["chapter_range"][1], 3)
        self.assertEqual(parts[0]["char_start"], 0)
        self.assertEqual(parts[-1]["char_end"], len(MD))

    def test_split_includes_preamble_before_first_heading(self):
        text = "Front matter.\n\n# Chapter 1\nalpha\n\n# Chapter 2\nbeta\n"
        chs = ingest.split_into_chapters(text)
        self.assertEqual(chs[0]["char_start"], 0)
        self.assertEqual(chs[-1]["char_end"], len(text))
        for a, b in zip(chs, chs[1:]):
            self.assertEqual(a["char_end"], b["char_start"])

    def test_confidence_low_for_two_headings(self):
        text = "# A\nx\n\n# B\ny\n"
        chs = ingest.split_into_chapters(text)
        self.assertEqual(ingest.structural_confidence(chs, "headings"), "low")

    def test_choose_heading_level_returns_most_frequent(self):
        text = (
            "## Book I\n### Chapter 1\na\n### Chapter 2\nb\n\n"
            "## Book II\n### Chapter 3\nc\n### Chapter 4\nd\n"
        )
        self.assertEqual(ingest._choose_heading_level(text), 3)

    def test_chapter_level_picks_most_frequent_heading(self):
        text = (
            "## Book I\n### Chapter 1\na\n### Chapter 2\nb\n\n"
            "## Book II\n### Chapter 3\nc\n### Chapter 4\nd\n"
        )
        chapters = ingest.split_into_chapters(text)
        self.assertEqual(len(chapters), 4)
        self.assertEqual(
            [c["title"] for c in chapters],
            ["Chapter 1", "Chapter 2", "Chapter 3", "Chapter 4"],
        )

if __name__ == "__main__":
    unittest.main()
