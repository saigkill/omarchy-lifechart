#!/usr/bin/env python3
"""PDF report for the life chart plugin (saigkill.lifechart).

Writes a report for any date range: header, mood/functionality chart, a
summary, the daily table, notes and the current medications from the
medication tracker (saigkill.meds). Modelled on the LifeChart app's
PdfRenderer, so a report from the bar looks like one from the app.

Standard library only. The PDF is written by hand with the built-in
Helvetica fonts (WinAnsiEncoding), so nothing has to be installed.

Usage:
    lifechart_report.py --from 2026-09-01 --to 2026-09-30 --out report.pdf [--lang de]

Privacy: the health data is read from the data files, never passed on the
command line (/proc/<pid>/cmdline is world readable). The arguments are only
dates, a language and the output path. The output file is created 0600.
"""

import argparse
import datetime as dt
import json
import os
import sys
import tempfile
import zlib

STATE = os.path.join(os.path.expanduser("~"), ".local", "state")
DATA_FILE = os.path.join(STATE, "omarchy-lifechart", "data.json")
MEDS_FILE = os.path.join(STATE, "omarchy-meds", "data.json")

PAGE_W = 595.28
PAGE_H = 841.89
MARGIN = 40.0
CONTENT_W = PAGE_W - 2 * MARGIN
FOOTER_H = 30.0
CONTENT_BOTTOM = PAGE_H - MARGIN - FOOTER_H
CHART_H = 220.0

# Colors as 0..1 RGB. Okabe-Ito, the same as the app and the panel.
MOOD = (0 / 255, 114 / 255, 178 / 255)
FUNC = (230 / 255, 159 / 255, 0 / 255)
HYPO = (204 / 255, 121 / 255, 167 / 255)
TEXT = (0.10, 0.10, 0.10)
MUTED = (0.42, 0.42, 0.42)
GRID = (0.78, 0.78, 0.78)
CRITICAL = (0.75, 0.10, 0.10)
# Bands pre-blended on white: the PDF needs no transparency for them.
BAND_UP = (1.0, 0.98, 0.88)
BAND_DOWN = (0.92, 0.95, 0.98)
HYPO_BAND = (0.98, 0.93, 0.96)
TABLE_HEAD = (0.94, 0.94, 0.94)

# ---- texts --------------------------------------------------------------

TEXTS = {
    "de": {
        "title": "LifeChart – Stimmungs- und Funktionsbericht",
        "period": "Zeitraum",
        "mood": "Stimmung",
        "functionality": "Funktionsfähigkeit",
        "hypomanic": "Hypomanisch",
        "scale": "+5 = Manie  ·  0 = ausgeglichen  ·  -5 = schwere Depression",
        "no_data": "Keine Einträge in diesem Zeitraum.",
        "summary": "Zusammenfassung",
        "recorded": "{count} von {days} Tagen erfasst",
        "avg_mood": "Ø Stimmung",
        "avg_func": "Ø Funktionsfähigkeit",
        "avg_sleep": "Ø Schlaf",
        "hypo_days": "Tage mit Hypomanie",
        "critical_days": "Kritische Tage",
        "med_days": "Medikation genommen",
        "daily": "Tagesübersicht",
        "cols": ["Datum", "Stimm.", "Funkt.", "Schlaf", "Medik.", "Mens.", "Hypom.", "Symptome"],
        "yes": "ja",
        "notes": "Notizen",
        "medications": "Aktuelle Medikamente",
        "as_needed": "bei Bedarf",
        "created": "Erstellt mit LifeChart für Omarchy am {ts}",
        "method": "Basierend auf der NIMH Life Chart Methode",
        "page": "Seite {n} von {total}",
        "date_fmt": "%d.%m.%Y",
        "short_fmt": "%d.%m.",
        "critical_note": "Kritisch: Stimmung und Funktionsfähigkeit beide bei -4 oder darunter.",
        "disclaimer": "Selbstbeobachtung, kein Medizinprodukt.",
    },
    "en": {
        "title": "LifeChart – Mood & Functionality Report",
        "period": "Period",
        "mood": "Mood",
        "functionality": "Functionality",
        "hypomanic": "Hypomanic",
        "scale": "+5 = mania  ·  0 = balanced  ·  -5 = severe depression",
        "no_data": "No entries in this period.",
        "summary": "Summary",
        "recorded": "{count} of {days} days recorded",
        "avg_mood": "Avg. mood",
        "avg_func": "Avg. functionality",
        "avg_sleep": "Avg. sleep",
        "hypo_days": "Hypomanic days",
        "critical_days": "Critical days",
        "med_days": "Medication taken",
        "daily": "Daily overview",
        "cols": ["Date", "Mood", "Func.", "Sleep", "Med.", "Mens.", "Hypo.", "Symptoms"],
        "yes": "yes",
        "notes": "Notes",
        "medications": "Current medications",
        "as_needed": "as needed",
        "created": "Created with LifeChart for Omarchy on {ts}",
        "method": "Based on the NIMH Life Chart method",
        "page": "Page {n} of {total}",
        "date_fmt": "%Y-%m-%d",
        "short_fmt": "%m-%d",
        "critical_note": "Critical: mood and functionality both at -4 or below.",
        "disclaimer": "Self-observation, not a medical device.",
    },
}

# ---- font metrics -------------------------------------------------------
# Advance widths (1/1000 em) of the PDF standard fonts Helvetica and
# Helvetica-Bold for ASCII 32..126, and (regular, bold) for the non-ASCII
# WinAnsi characters in _EXTRA. Checked against NimbusSans, which is metric
# compatible (tests/test_report.py does it again when the font is present).

_HELV = [
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
    333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
]
_HELV_BOLD = [
    278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611,
    975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556,
    333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611,
    611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584,
]
_EXTRA = {
    '\xa0': (278, 278), '¡': (333, 333), '¢': (556, 556), '£': (556, 556), '¤': (556, 556), '¥': (556, 556),
    '¦': (260, 280), '§': (556, 556), '¨': (333, 333), '©': (737, 737), 'ª': (370, 370), '«': (556, 556),
    '¬': (584, 584), '\xad': (333, 333), '®': (737, 737), '¯': (333, 333), '°': (400, 400), '±': (584, 584),
    '²': (333, 333), '³': (333, 333), '´': (333, 333), 'µ': (556, 611), '¶': (537, 556), '·': (278, 278),
    '¸': (333, 333), '¹': (333, 333), 'º': (365, 365), '»': (556, 556), '¼': (834, 834), '½': (834, 834),
    '¾': (834, 834), '¿': (611, 611), 'À': (667, 722), 'Á': (667, 722), 'Â': (667, 722), 'Ã': (667, 722),
    'Ä': (667, 722), 'Å': (667, 722), 'Æ': (1000, 1000), 'Ç': (722, 722), 'È': (667, 667), 'É': (667, 667),
    'Ê': (667, 667), 'Ë': (667, 667), 'Ì': (278, 278), 'Í': (278, 278), 'Î': (278, 278), 'Ï': (278, 278),
    'Ð': (722, 722), 'Ñ': (722, 722), 'Ò': (778, 778), 'Ó': (778, 778), 'Ô': (778, 778), 'Õ': (778, 778),
    'Ö': (778, 778), '×': (584, 584), 'Ø': (778, 778), 'Ù': (722, 722), 'Ú': (722, 722), 'Û': (722, 722),
    'Ü': (722, 722), 'Ý': (667, 667), 'Þ': (667, 667), 'ß': (611, 611), 'à': (556, 556), 'á': (556, 556),
    'â': (556, 556), 'ã': (556, 556), 'ä': (556, 556), 'å': (556, 556), 'æ': (889, 889), 'ç': (500, 556),
    'è': (556, 556), 'é': (556, 556), 'ê': (556, 556), 'ë': (556, 556), 'ì': (278, 278), 'í': (278, 278),
    'î': (278, 278), 'ï': (278, 278), 'ð': (556, 611), 'ñ': (556, 611), 'ò': (556, 611), 'ó': (556, 611),
    'ô': (556, 611), 'õ': (556, 611), 'ö': (556, 611), '÷': (584, 584), 'ø': (611, 611), 'ù': (556, 611),
    'ú': (556, 611), 'û': (556, 611), 'ü': (556, 611), 'ý': (500, 556), 'þ': (556, 611), 'ÿ': (500, 556),
    '–': (556, 556), '—': (1000, 1000), '•': (350, 350), '…': (1000, 1000), '„': (333, 500), '“': (333, 500),
    '”': (333, 500), '‚': (222, 278), '‘': (222, 278), '’': (222, 278), '€': (556, 556),
}

# Characters outside WinAnsi that users or the texts may produce.
_REPLACE = {"−": "-", "✓": "x", "⌀": "Ø", "\t": " ", "\r": ""}


def clean(text):
    """Make text printable in WinAnsi; anything else becomes '?'."""
    out = []
    for ch in str(text):
        ch = _REPLACE.get(ch, ch)
        if ch == "":
            continue
        try:
            ch.encode("cp1252")
            out.append(ch)
        except UnicodeEncodeError:
            out.append("?")
    return "".join(out)


def char_width(ch, bold=False):
    table = _HELV_BOLD if bold else _HELV
    code = ord(ch)
    if 32 <= code <= 126:
        return table[code - 32]
    pair = _EXTRA.get(ch)
    if pair:
        return pair[1] if bold else pair[0]
    return 556


def text_width(text, size, bold=False):
    return sum(char_width(ch, bold) for ch in clean(text)) * size / 1000.0


def wrap(text, size, width, bold=False):
    """Greedy word wrap; words longer than a line are broken by character."""
    lines = []
    for paragraph in clean(text).split("\n"):
        line = ""
        for word in paragraph.split(" "):
            candidate = word if not line else line + " " + word
            if text_width(candidate, size, bold) <= width:
                line = candidate
                continue
            if line:
                lines.append(line)
            line = ""
            while text_width(word, size, bold) > width:
                cut = len(word)
                while cut > 1 and text_width(word[:cut], size, bold) > width:
                    cut -= 1
                lines.append(word[:cut])
                word = word[cut:]
            line = word
        lines.append(line)
    return lines


def truncate(text, size, width, bold=False):
    text = clean(text).replace("\n", " ")
    if text_width(text, size, bold) <= width:
        return text
    while text and text_width(text + "…", size, bold) > width:
        text = text[:-1]
    return text.rstrip() + "…"


# ---- PDF writing ----------------------------------------------------------

def _pdf_string(text):
    raw = clean(text).encode("cp1252")
    return b"(" + raw.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)") + b")"


def _num(value):
    text = ("%.2f" % value).rstrip("0").rstrip(".")
    return text if text not in ("-0", "") else "0"


class Page:
    """One page's content stream, in top-left coordinates."""

    def __init__(self):
        self.ops = []

    def _y(self, y):
        return PAGE_H - y

    def color(self, rgb, stroke=False):
        self.ops.append("%s %s %s %s" % (_num(rgb[0]), _num(rgb[1]), _num(rgb[2]), "RG" if stroke else "rg"))

    def line(self, x1, y1, x2, y2, rgb, width=0.5, dash=None):
        self.color(rgb, stroke=True)
        self.ops.append("%s w" % _num(width))
        self.ops.append("[%s] 0 d" % (" ".join(_num(d) for d in dash) if dash else ""))
        self.ops.append("%s %s m %s %s l S" % (_num(x1), _num(self._y(y1)), _num(x2), _num(self._y(y2))))
        if dash:
            self.ops.append("[] 0 d")

    def polyline(self, points, rgb, width=1.5, dash=None):
        if len(points) < 2:
            return
        self.color(rgb, stroke=True)
        self.ops.append("%s w 1 j 1 J" % _num(width))
        self.ops.append("[%s] 0 d" % (" ".join(_num(d) for d in dash) if dash else ""))
        first = points[0]
        path = ["%s %s m" % (_num(first[0]), _num(self._y(first[1])))]
        for x, y in points[1:]:
            path.append("%s %s l" % (_num(x), _num(self._y(y))))
        self.ops.append(" ".join(path) + " S")
        self.ops.append("[] 0 d 0 j 0 J")

    def rect(self, x, y, w, h, fill=None, stroke=None, width=0.5):
        if fill:
            self.color(fill)
        if stroke:
            self.color(stroke, stroke=True)
            self.ops.append("%s w" % _num(width))
        op = "B" if fill and stroke else ("f" if fill else "S")
        self.ops.append("%s %s %s %s re %s" % (_num(x), _num(self._y(y + h)), _num(w), _num(h), op))

    def circle(self, cx, cy, r, rgb):
        # Four Bezier arcs.
        k = 0.5523 * r
        y = self._y(cy)
        self.color(rgb)
        self.ops.append(
            "%s %s m %s %s %s %s %s %s c %s %s %s %s %s %s c %s %s %s %s %s %s c %s %s %s %s %s %s c f" % tuple(
                _num(v) for v in (
                    cx + r, y,
                    cx + r, y + k, cx + k, y + r, cx, y + r,
                    cx - k, y + r, cx - r, y + k, cx - r, y,
                    cx - r, y - k, cx - k, y - r, cx, y - r,
                    cx + k, y - r, cx + r, y - k, cx + r, y)))

    def text(self, x, y, text, size=9, bold=False, rgb=TEXT, align="left"):
        """y is the top of the text line."""
        text = clean(text)
        if align != "left":
            w = text_width(text, size, bold)
            x = x - w if align == "right" else x - w / 2
        baseline = self._y(y + size * 0.8)
        self.color(rgb)
        self.ops.append("BT /%s %s Tf %s %s Td %s Tj ET" % (
            "F2" if bold else "F1", _num(size), _num(x), _num(baseline),
            _pdf_string(text).decode("latin-1")))

    def stream(self):
        return "\n".join(self.ops).encode("latin-1")


def write_pdf(pages, compress=True):
    """Serialize pages into a PDF file (bytes)."""
    objects = []

    def add(body):
        objects.append(body)
        return len(objects)

    catalog = add(None)
    pages_id = add(None)
    font_regular = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    font_bold = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
    page_ids = []
    for page in pages:
        data = page.stream()
        if compress:
            data = zlib.compress(data)
            content = add(b"<< /Length %d /Filter /FlateDecode >>\nstream\n" % len(data) + data + b"\nendstream")
        else:
            content = add(b"<< /Length %d >>\nstream\n" % len(data) + data + b"\nendstream")
        page_ids.append(add(
            b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %s %s] /Contents %d 0 R "
            b"/Resources << /Font << /F1 %d 0 R /F2 %d 0 R >> >> >>" % (
                pages_id, _num(PAGE_W).encode(), _num(PAGE_H).encode(), content, font_regular, font_bold)))
    objects[catalog - 1] = b"<< /Type /Catalog /Pages %d 0 R >>" % pages_id
    objects[pages_id - 1] = b"<< /Type /Pages /Kids [%s] /Count %d >>" % (
        b" ".join(b"%d 0 R" % p for p in page_ids), len(page_ids))

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for offset in offsets:
        out += b"%010d 00000 n \n" % offset
    out += b"trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, catalog, xref)
    return bytes(out)


# ---- data -----------------------------------------------------------------

def parse_day(value):
    return dt.date.fromisoformat(str(value))


def clamp(value, low, high):
    try:
        n = int(round(float(value)))
    except (TypeError, ValueError):
        n = 0
    return max(low, min(high, n))


def load_entries(path, start, end):
    """Entries in [start, end], normalized like Model.normalizeEntry()."""
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict) or not isinstance(data.get("entries"), list):
        raise ValueError("not a life chart data file")
    by_day = {}
    for raw in data["entries"]:
        if not isinstance(raw, dict):
            continue
        try:
            day = parse_day(raw.get("date"))
        except ValueError:
            continue
        if not (start <= day <= end):
            continue
        by_day[day] = {
            "date": day,
            "mood": clamp(raw.get("mood"), -5, 5),
            "functionality": clamp(raw.get("functionality"), -5, 5),
            "sleepHours": clamp(raw.get("sleepHours"), 0, 24),
            "medicationTaken": raw.get("medicationTaken") is True,
            "menstrualCycle": raw.get("menstrualCycle") is True,
            "isHypomanic": raw.get("isHypomanic") is True,
            "symptoms": (str(raw.get("symptoms") or "").strip() or None),
            "notes": (str(raw.get("notes") or "").strip() or None),
        }
    return [by_day[day] for day in sorted(by_day)]


def load_medications(path):
    """Enabled medications of the meds plugin, or [] when it is not used."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return []
    meds = data.get("medications") if isinstance(data, dict) else None
    out = []
    for med in meds if isinstance(meds, list) else []:
        if not isinstance(med, dict) or med.get("enabled") is False:
            continue
        name = str(med.get("name") or "").strip()
        if not name:
            continue
        times = [str(t) for t in med.get("times") or [] if isinstance(t, str)]
        out.append({"name": name, "dosage": str(med.get("dosage") or "").strip(), "times": sorted(set(times))})
    return out


def is_critical(entry):
    return entry["mood"] <= -4 and entry["functionality"] <= -4


def summarize(entries, start, end):
    def avg(key):
        values = [e[key] for e in entries]
        return sum(values) / len(values) if values else None
    return {
        "count": len(entries),
        "days": (end - start).days + 1,
        "mood": avg("mood"),
        "functionality": avg("functionality"),
        "sleep": avg("sleepHours"),
        "hypomanic": sum(1 for e in entries if e["isHypomanic"]),
        "critical": sum(1 for e in entries if is_critical(e)),
        "medication": sum(1 for e in entries if e["medicationTaken"]),
    }


def signed(value):
    return "+%d" % value if value > 0 else str(value)


def signed_avg(value):
    if value is None:
        return "–"
    rounded = round(value, 1)
    return ("+" if rounded > 0 else "") + ("%.1f" % rounded)


# ---- layout -----------------------------------------------------------------

class Report:
    def __init__(self, texts):
        self.t = texts
        self.pages = []
        self.y = 0.0
        self.new_page()

    @property
    def page(self):
        return self.pages[-1]

    def new_page(self):
        self.pages.append(Page())
        self.y = MARGIN

    def ensure(self, needed):
        if self.y + needed > CONTENT_BOTTOM:
            self.new_page()
            return True
        return False

    def rule(self, gap_before=8, gap_after=12):
        self.y += gap_before
        self.page.line(MARGIN, self.y, PAGE_W - MARGIN, self.y, GRID, 0.5)
        self.y += gap_after

    def heading(self, text):
        self.ensure(40)
        self.page.text(MARGIN, self.y, text, 10, bold=True)
        self.y += 16

    # -- sections ------------------------------------------------------------

    def header(self, start, end):
        t = self.t
        self.page.text(MARGIN, self.y, t["title"], 14, bold=True)
        self.y += 22
        period = "%s: %s – %s" % (t["period"], start.strftime(t["date_fmt"]), end.strftime(t["date_fmt"]))
        self.page.text(MARGIN, self.y, period, 9, rgb=MUTED)
        self.rule(14, 12)

    def chart(self, entries, start, end):
        t = self.t
        self.ensure(CHART_H + 60)
        page = self.page
        left = MARGIN + 24
        top = self.y
        width = CONTENT_W - 24
        total = max(1, (end - start).days)

        def x_of(day):
            return left + (day - start).days / total * width

        def y_of(score):
            return top + (5 - score) / 10.0 * CHART_H

        page.rect(left, top, width, CHART_H / 2, fill=BAND_UP)
        page.rect(left, top + CHART_H / 2, width, CHART_H / 2, fill=BAND_DOWN)
        for e in entries:
            if e["isHypomanic"]:
                page.rect(x_of(e["date"]) - 2.5, top, 5, CHART_H, fill=HYPO_BAND)
        for score in range(-5, 6):
            y = y_of(score)
            page.line(left, y, left + width, y, (0.55, 0.55, 0.55) if score == 0 else (0.85, 0.85, 0.85),
                      0.7 if score == 0 else 0.4)
            page.text(left - 5, y - 3.5, signed(score), 7, rgb=MUTED, align="right")
        page.rect(left, top, width, CHART_H, stroke=GRID, width=0.5)

        if not entries:
            page.text(left + width / 2, top + CHART_H / 2 - 6, t["no_data"], 10, rgb=MUTED, align="center")
        else:
            mood = [(x_of(e["date"]), y_of(e["mood"])) for e in entries]
            func = [(x_of(e["date"]), y_of(e["functionality"])) for e in entries]
            # Functionality dashed with square markers, so the two series
            # stay apart on a grayscale printout too.
            page.polyline(func, FUNC, 1.5, dash=(4, 3))
            page.polyline(mood, MOOD, 1.5)
            radius = 2.5 if len(entries) <= 60 else 1.6
            for x, y in func:
                page.rect(x - radius, y - radius, radius * 2, radius * 2, fill=FUNC)
            for x, y in mood:
                page.circle(x, y, radius, MOOD)
            for e in entries:
                if e["isHypomanic"]:
                    page.circle(x_of(e["date"]), top - 4, 3, HYPO)

        # Date labels: about eight, the last one right-aligned to the edge.
        step = max(1, total // 8)
        days = list(range(0, total + 1, step))
        if days[-1] != total and total - days[-1] < step / 2:
            days[-1] = total
        elif days[-1] != total:
            days.append(total)
        fmt = t["short_fmt"] if total <= 366 else t["date_fmt"]
        for offset in days:
            day = start + dt.timedelta(days=offset)
            x = left + offset / total * width
            align = "left" if offset == 0 else ("right" if offset == total else "center")
            page.text(x, top + CHART_H + 3, day.strftime(fmt), 7, rgb=MUTED, align=align)
        self.y = top + CHART_H + 16

        # Legend
        y = self.y
        page.line(left, y + 4, left + 18, y + 4, MOOD, 1.5)
        page.circle(left + 9, y + 4, 2.5, MOOD)
        page.text(left + 24, y, t["mood"], 8)
        x = left + 30 + text_width(t["mood"], 8) + 14
        page.line(x, y + 4, x + 18, y + 4, FUNC, 1.5, dash=(4, 3))
        page.rect(x + 7, y + 1.5, 5, 5, fill=FUNC)
        page.text(x + 24, y, t["functionality"], 8)
        x = x + 30 + text_width(t["functionality"], 8) + 14
        page.circle(x + 4, y + 4, 3, HYPO)
        page.text(x + 12, y, t["hypomanic"], 8)
        self.y += 14
        page.text(left, self.y, t["scale"], 7, rgb=MUTED)
        self.rule(10, 12)

    def summary(self, entries, start, end):
        t = self.t
        s = summarize(entries, start, end)
        self.heading(t["summary"])
        rows = [
            (t["recorded"].format(count=s["count"], days=s["days"]), ""),
            (t["avg_mood"], signed_avg(s["mood"])),
            (t["avg_func"], signed_avg(s["functionality"])),
            (t["avg_sleep"], "–" if s["sleep"] is None else "%.1f h" % s["sleep"]),
            (t["med_days"], "%d / %d" % (s["medication"], s["count"])),
            (t["hypo_days"], str(s["hypomanic"])),
            (t["critical_days"], str(s["critical"])),
        ]
        col = CONTENT_W / 2
        for index, (label, value) in enumerate(rows):
            x = MARGIN + (index % 2) * col
            if index % 2 == 0 and index:
                self.y += 13
            self.page.text(x, self.y, label, 8.5, bold=(index == 0))
            if value:
                self.page.text(x + col - 20, self.y, value, 8.5, bold=True, align="right")
        self.y += 13
        if s["critical"]:
            self.page.text(MARGIN, self.y + 2, t["critical_note"], 7.5, rgb=CRITICAL)
            self.y += 12
        self.rule(4, 12)

    def table(self, entries):
        if not entries:
            return
        t = self.t
        self.heading(t["daily"])
        widths = [62, 38, 38, 36, 38, 36, 40]
        widths.append(CONTENT_W - sum(widths))

        def header_row():
            self.page.rect(MARGIN, self.y, CONTENT_W, 14, fill=TABLE_HEAD)
            x = MARGIN
            for label, w in zip(t["cols"], widths):
                self.page.text(x + 3, self.y + 3, label, 8, bold=True)
                x += w
            self.y += 14

        header_row()
        for e in entries:
            symptoms = wrap(e["symptoms"] or "-", 7.5, widths[-1] - 6)[:3]
            height = max(13, 4 + 10 * len(symptoms))
            if self.ensure(height + 2):
                header_row()
            critical = is_critical(e)
            color = CRITICAL if critical else TEXT
            cells = [
                e["date"].strftime(t["date_fmt"]),
                signed(e["mood"]),
                signed(e["functionality"]),
                "%d h" % e["sleepHours"],
                t["yes"] if e["medicationTaken"] else "-",
                t["yes"] if e["menstrualCycle"] else "-",
                t["yes"] if e["isHypomanic"] else "-",
            ]
            x = MARGIN
            for value, w in zip(cells, widths):
                self.page.text(x + 3, self.y + 3, value, 7.5, bold=critical and value == cells[0], rgb=color)
                x += w
            for index, line in enumerate(symptoms):
                self.page.text(x + 3, self.y + 3 + index * 10, line, 7.5, rgb=MUTED)
            self.y += height
            self.page.line(MARGIN, self.y, PAGE_W - MARGIN, self.y, (0.88, 0.88, 0.88), 0.3)
        self.rule(8, 12)

    def notes(self, entries):
        with_notes = [e for e in entries if e["notes"]]
        if not with_notes:
            return
        t = self.t
        self.heading(t["notes"])
        label_w = 70
        for e in with_notes:
            lines = wrap(e["notes"], 8, CONTENT_W - label_w)
            first = True
            for index, line in enumerate(lines):
                if self.ensure(12) or first:
                    self.page.text(MARGIN, self.y, e["date"].strftime(t["date_fmt"]) + ":", 8, bold=True)
                    first = False
                self.page.text(MARGIN + label_w, self.y, line, 8, rgb=MUTED)
                self.y += 11
            self.y += 4
        self.rule(4, 12)

    def medications(self, meds):
        if not meds:
            return
        t = self.t
        self.heading(t["medications"])
        for med in meds:
            line = "•  " + med["name"]
            if med["dosage"]:
                line += "  " + med["dosage"]
            line += "  –  " + (", ".join(med["times"]) if med["times"] else t["as_needed"])
            for index, part in enumerate(wrap(line, 8.5, CONTENT_W)):
                self.ensure(12)
                self.page.text(MARGIN + (10 if index else 0), self.y, part, 8.5)
                self.y += 12

    def footers(self, created):
        t = self.t
        total = len(self.pages)
        for number, page in enumerate(self.pages, start=1):
            y = PAGE_H - MARGIN - 20
            page.line(MARGIN, y, PAGE_W - MARGIN, y, GRID, 0.4)
            page.text(MARGIN, y + 4, t["created"].format(ts=created), 7, rgb=MUTED)
            page.text(PAGE_W - MARGIN, y + 4, t["page"].format(n=number, total=total), 7, rgb=MUTED, align="right")
            page.text(MARGIN, y + 13, t["method"] + "  ·  " + t["disclaimer"], 7, rgb=MUTED)


def build_report(entries, meds, start, end, lang="de", created=None):
    texts = TEXTS.get(lang, TEXTS["de"])
    report = Report(texts)
    report.header(start, end)
    report.chart(entries, start, end)
    report.summary(entries, start, end)
    report.table(entries)
    report.notes(entries)
    report.medications(meds)
    report.footers(created or dt.datetime.now().strftime("%Y-%m-%d %H:%M"))
    return report.pages


def documents_dir():
    """XDG documents directory, like `xdg-user-dir DOCUMENTS`."""
    home = os.path.expanduser("~")
    config = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
    try:
        with open(os.path.join(config, "user-dirs.dirs"), encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line.startswith("XDG_DOCUMENTS_DIR="):
                    value = line.split("=", 1)[1].strip().strip('"')
                    value = value.replace("$HOME", home)
                    if value and value != home:
                        return value
    except OSError:
        pass
    return os.path.join(home, "Documents")


def default_output(start, end):
    """~/Documents/LifeChart/LifeChart_<from>_<to>.pdf, as the app names it."""
    return os.path.join(documents_dir(), "LifeChart",
                        "LifeChart_%s_%s.pdf" % (start.isoformat(), end.isoformat()))


def write_private(path, data):
    """Atomic write, mode 0600: the report is health data."""
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".lifechart-", suffix=".pdf", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--from", dest="start", required=True, help="first day, YYYY-MM-DD")
    parser.add_argument("--to", dest="end", required=True, help="last day, YYYY-MM-DD")
    parser.add_argument("--out", help="output PDF path (default: ~/Documents/LifeChart/LifeChart_<from>_<to>.pdf)")
    parser.add_argument("--lang", default="de", choices=sorted(TEXTS))
    parser.add_argument("--data", default=DATA_FILE, help=argparse.SUPPRESS)
    parser.add_argument("--meds", default=MEDS_FILE, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    try:
        start = parse_day(args.start)
        end = parse_day(args.end)
    except ValueError:
        print("error: dates must be YYYY-MM-DD", file=sys.stderr)
        return 2
    if start > end:
        print("error: --from is after --to", file=sys.stderr)
        return 2

    try:
        entries = load_entries(args.data, start, end)
    except FileNotFoundError:
        entries = []
    except (OSError, ValueError) as error:
        print("error: cannot read life chart data: %s" % error, file=sys.stderr)
        return 1

    out = args.out or default_output(start, end)
    pages = build_report(entries, load_medications(args.meds), start, end, args.lang)
    try:
        write_private(out, write_pdf(pages))
    except OSError as error:
        print("error: cannot write %s: %s" % (out, error), file=sys.stderr)
        return 1
    # The panel reads this line to show and open the file.
    print(json.dumps({"ok": True, "path": os.path.abspath(out), "entries": len(entries), "pages": len(pages)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
