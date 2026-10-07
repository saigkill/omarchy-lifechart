"""Tests for lifechart_report.py.

Run with: python3 -m unittest discover -s tests
"""

import datetime as dt
import json
import os
import re
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

import lifechart_report as R  # noqa: E402

HELPER = os.path.join(ROOT, "lifechart_report.py")
NIMBUS = "/usr/share/fonts/gsfonts/NimbusSans-%s.otf"


def entry(day, **fields):
    data = {"date": day, "mood": 0, "functionality": 0, "sleepHours": 7}
    data.update(fields)
    return data


def page_text(pdf):
    """All text shown by Tj operators, decoded from WinAnsi."""
    out = []
    for match in re.finditer(rb"stream\n(.*?)\nendstream", pdf, re.S):
        body = match.group(1)
        try:
            body = zlib.decompress(body)
        except zlib.error:
            pass
        for literal in re.findall(rb"\(((?:\\.|[^\\)])*)\) Tj", body):
            text = re.sub(rb"\\(.)", rb"\1", literal)
            out.append(text.decode("cp1252"))
    return "\n".join(out)


class Workspace(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.data = os.path.join(self.dir.name, "data.json")
        self.meds = os.path.join(self.dir.name, "meds.json")
        self.out = os.path.join(self.dir.name, "out", "report.pdf")

    def tearDown(self):
        self.dir.cleanup()

    def write(self, path, payload):
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(payload if isinstance(payload, str) else json.dumps(payload))

    def run_helper(self, *args):
        return subprocess.run(
            [sys.executable, HELPER, "--data", self.data, "--meds", self.meds, *args],
            capture_output=True, text=True)


class ReportTests(Workspace):
    def test_report_for_a_range_contains_only_that_range(self):
        self.write(self.data, {"version": 1, "entries": [
            entry("2026-08-31", notes="outside before"),
            entry("2026-09-01", mood=2, notes="Spaziergang, Ärger überstanden"),
            entry("2026-09-15", mood=-4, functionality=-5, symptoms="Unruhe"),
            entry("2026-10-01", notes="outside after"),
        ]})
        result = self.run_helper("--from", "2026-09-01", "--to", "2026-09-30", "--out", self.out)
        self.assertEqual(result.returncode, 0, result.stderr)
        info = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(info["entries"], 2)
        with open(self.out, "rb") as handle:
            pdf = handle.read()
        self.assertTrue(pdf.startswith(b"%PDF-1.4"))
        self.assertTrue(pdf.rstrip().endswith(b"%%EOF"))
        text = page_text(pdf)
        self.assertIn("Spaziergang, Ärger überstanden", text)
        self.assertIn("Unruhe", text)
        self.assertIn("01.09.2026 – 30.09.2026", text)
        self.assertNotIn("outside", text)

    def test_output_is_private(self):
        self.write(self.data, {"entries": []})
        result = self.run_helper("--from", "2026-09-01", "--to", "2026-09-30", "--out", self.out)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(os.stat(self.out).st_mode), 0o600)

    def test_missing_data_file_gives_an_empty_report(self):
        result = self.run_helper("--from", "2026-09-01", "--to", "2026-09-30", "--out", self.out)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(self.out, "rb") as handle:
            self.assertIn("Keine Einträge", page_text(handle.read()))

    def test_damaged_data_file_is_an_error_not_an_empty_report(self):
        self.write(self.data, "{ broken")
        result = self.run_helper("--from", "2026-09-01", "--to", "2026-09-30", "--out", self.out)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(os.path.exists(self.out))

    def test_bad_ranges_are_rejected(self):
        self.assertEqual(self.run_helper("--from", "2026-10-01", "--to", "2026-09-01", "--out", self.out).returncode, 2)
        self.assertEqual(self.run_helper("--from", "01.09.2026", "--to", "2026-09-30", "--out", self.out).returncode, 2)

    def test_long_ranges_paginate_with_page_numbers(self):
        start = dt.date(2025, 1, 1)
        entries = [entry((start + dt.timedelta(days=i)).isoformat(), mood=(i % 11) - 5,
                         symptoms="lang " * 30) for i in range(365)]
        self.write(self.data, {"entries": entries})
        result = self.run_helper("--from", "2025-01-01", "--to", "2025-12-31", "--out", self.out, "--lang", "en")
        self.assertEqual(result.returncode, 0, result.stderr)
        info = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertGreater(info["pages"], 5)
        with open(self.out, "rb") as handle:
            text = page_text(handle.read())
        self.assertIn("Page 1 of %d" % info["pages"], text)
        self.assertIn("Page %d of %d" % (info["pages"], info["pages"]), text)

    def test_medications_come_from_the_meds_plugin(self):
        self.write(self.data, {"entries": [entry("2026-09-01")]})
        self.write(self.meds, {"medications": [
            {"id": "a", "name": "Lithium", "dosage": "450 mg", "times": ["20:00", "08:00"], "enabled": True},
            {"id": "b", "name": "Old", "dosage": "", "times": ["09:00"], "enabled": False},
            {"id": "c", "name": "Ibuprofen", "dosage": "400 mg", "times": [], "enabled": True},
        ], "log": []})
        result = self.run_helper("--from", "2026-09-01", "--to", "2026-09-30", "--out", self.out)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(self.out, "rb") as handle:
            text = page_text(handle.read())
        self.assertIn("Lithium  450 mg  –  08:00, 20:00", text)
        self.assertIn("Ibuprofen  400 mg  –  bei Bedarf", text)
        self.assertNotIn("Old", text)

    def test_health_data_never_appears_on_the_command_line(self):
        # The panel builds the command; the helper must not need more.
        with open(os.path.join(ROOT, "Model.js"), encoding="utf-8") as handle:
            source = handle.read()
        builder = re.search(r"function reportCommand\(.*?\n}\n", source, re.S).group(0)
        for word in ("entries", "notes", "symptoms", "mood"):
            self.assertNotIn(word, builder)


class TextTests(unittest.TestCase):
    def test_clean_maps_non_winansi(self):
        self.assertEqual(R.clean("−3 ✓ ⌀"), "-3 x Ø")
        self.assertEqual(R.clean("日本"), "??")
        self.assertEqual(R.clean("Grüße"), "Grüße")

    def test_wrap_respects_width_and_keeps_words(self):
        lines = R.wrap("eins zwei drei vier fünf sechs sieben acht", 8, 60)
        for line in lines:
            self.assertLessEqual(R.text_width(line, 8), 60)
        self.assertEqual(" ".join(lines), "eins zwei drei vier fünf sechs sieben acht")

    def test_wrap_breaks_overlong_words(self):
        lines = R.wrap("x" * 200, 8, 50)
        self.assertGreater(len(lines), 1)
        self.assertEqual("".join(lines), "x" * 200)

    def test_truncate_adds_ellipsis(self):
        short = R.truncate("a" * 100, 8, 40)
        self.assertTrue(short.endswith("…"))
        self.assertLessEqual(R.text_width(short, 8), 40)

    def test_parentheses_are_escaped(self):
        page = R.Page()
        page.text(0, 0, "a (b) \\ c")
        self.assertIn("(a \\(b\\) \\\\ c) Tj", page.stream().decode("latin-1"))


@unittest.skipUnless(os.path.exists(NIMBUS % "Regular"), "NimbusSans not installed")
class MetricsTests(unittest.TestCase):
    """The width tables match NimbusSans, which is metric compatible with Helvetica."""

    @staticmethod
    def font_widths(path):
        with open(path, "rb") as handle:
            data = handle.read()
        count = struct.unpack(">H", data[4:6])[0]
        tables = {}
        for i in range(count):
            tag, _, offset, _ = struct.unpack(">4sIII", data[12 + 16 * i:28 + 16 * i])
            tables[tag] = offset
        upem = struct.unpack(">H", data[tables[b"head"] + 18:tables[b"head"] + 20])[0]
        metrics = struct.unpack(">H", data[tables[b"hhea"] + 34:tables[b"hhea"] + 36])[0]
        hmtx = tables[b"hmtx"]
        advance = [struct.unpack(">H", data[hmtx + 4 * i:hmtx + 4 * i + 2])[0] for i in range(metrics)]
        cmap = tables[b"cmap"]
        sub = None
        for i in range(struct.unpack(">H", data[cmap + 2:cmap + 4])[0]):
            pid, eid, offset = struct.unpack(">HHI", data[cmap + 4 + 8 * i:cmap + 12 + 8 * i])
            if (pid, eid) == (3, 1):
                sub = cmap + offset
        segs = struct.unpack(">H", data[sub + 6:sub + 8])[0] // 2
        ends = struct.unpack(">%dH" % segs, data[sub + 14:sub + 14 + 2 * segs])
        pos = sub + 16 + 2 * segs
        starts = struct.unpack(">%dH" % segs, data[pos:pos + 2 * segs])
        pos += 2 * segs
        deltas = struct.unpack(">%dh" % segs, data[pos:pos + 2 * segs])
        ranges_at = pos + 2 * segs
        ranges = struct.unpack(">%dH" % segs, data[ranges_at:ranges_at + 2 * segs])

        def width(code):
            for i in range(segs):
                if starts[i] <= code <= ends[i]:
                    if ranges[i] == 0:
                        glyph = (code + deltas[i]) & 0xFFFF
                    else:
                        at = ranges_at + 2 * i + ranges[i] + 2 * (code - starts[i])
                        glyph = struct.unpack(">H", data[at:at + 2])[0]
                        glyph = (glyph + deltas[i]) & 0xFFFF if glyph else 0
                    return round(advance[min(glyph, metrics - 1)] * 1000 / upem)
            return None
        return width

    def check(self, style, bold):
        width = self.font_widths(NIMBUS % style)
        chars = [chr(c) for c in range(32, 127)] + list(R._EXTRA)
        wrong = [(ch, width(ord(ch)), R.char_width(ch, bold)) for ch in chars
                 if width(ord(ch)) != R.char_width(ch, bold)]
        self.assertEqual(wrong, [])

    def test_regular(self):
        self.check("Regular", False)

    def test_bold(self):
        self.check("Bold", True)


if __name__ == "__main__":
    unittest.main()
