// Tests for the pure life chart logic. The domain rules are the app's
// (LifeChart.Domain); if one of these fails, check the app before the test.
//
// Run with: node tests/test_model.js

const assert = require("assert")
const path = require("path")
const Model = require(path.join(__dirname, "..", "Model.js"))

let passed = 0
function test(name, body) {
  try {
    body()
    passed++
  } catch (error) {
    console.error("FAIL: " + name)
    console.error("      " + error.message)
    process.exitCode = 1
  }
}

function entry(date, fields) {
  return Model.normalizeEntry(Object.assign({ date: date }, fields || {}))
}

// ---- domain rules -------------------------------------------------------

test("critical needs both mood and functionality at -4 or below", () => {
  assert.strictEqual(Model.isCritical(entry("2026-10-01", { mood: -4, functionality: -4 })), true)
  assert.strictEqual(Model.isCritical(entry("2026-10-01", { mood: -5, functionality: -5 })), true)
  assert.strictEqual(Model.isCritical(entry("2026-10-01", { mood: -5, functionality: -3 })), false)
  assert.strictEqual(Model.isCritical(entry("2026-10-01", { mood: -3, functionality: -5 })), false)
  assert.strictEqual(Model.isCritical(null), false)
})

test("scores clamp to -5..+5 and sleep to 0..24", () => {
  const e = entry("2026-10-01", { mood: 9, functionality: -12, sleepHours: 30 })
  assert.strictEqual(e.mood, 5)
  assert.strictEqual(e.functionality, -5)
  assert.strictEqual(e.sleepHours, 24)
  assert.strictEqual(entry("2026-10-01", { sleepHours: -2 }).sleepHours, 0)
  assert.strictEqual(entry("2026-10-01", { mood: "abc" }).mood, 0)
})

test("entries without a valid date are rejected", () => {
  assert.strictEqual(Model.normalizeEntry({ date: "2026-02-30" }), null)
  assert.strictEqual(Model.normalizeEntry({ date: "yesterday" }), null)
  assert.strictEqual(Model.normalizeEntry(null), null)
})

test("blank text becomes null, booleans must be true to count", () => {
  const e = entry("2026-10-01", { symptoms: "   ", notes: " ok ", medicationTaken: "yes" })
  assert.strictEqual(e.symptoms, null)
  assert.strictEqual(e.notes, "ok")
  assert.strictEqual(e.medicationTaken, false)
})

// ---- dates ----------------------------------------------------------------

test("day arithmetic crosses month, year and DST boundaries", () => {
  assert.strictEqual(Model.addDays("2026-10-31", 1), "2026-11-01")
  assert.strictEqual(Model.addDays("2027-01-01", -1), "2026-12-31")
  assert.strictEqual(Model.addDays("2026-03-28", 2), "2026-03-30")   // EU spring forward
  assert.strictEqual(Model.addDays("2026-10-24", 2), "2026-10-26")   // EU fall back
  assert.strictEqual(Model.daysBetween("2026-03-01", "2026-04-01"), 31)
})

// ---- entry list -----------------------------------------------------------

test("upsert keeps one entry per day, sorted, and returns a new list", () => {
  const list = [entry("2026-10-03"), entry("2026-10-01")]
  const next = Model.upsertEntry(list, { date: "2026-10-02", mood: 2 })
  assert.notStrictEqual(next, list)
  assert.deepStrictEqual(next.map(e => e.date), ["2026-10-01", "2026-10-02", "2026-10-03"])
  const replaced = Model.upsertEntry(next, { date: "2026-10-02", mood: -1 })
  assert.strictEqual(replaced.length, 3)
  assert.strictEqual(Model.findEntry(replaced, "2026-10-02").mood, -1)
  assert.strictEqual(Model.upsertEntry(list, { date: "nope" }), null)
})

test("remove drops only that day", () => {
  const list = [entry("2026-10-01"), entry("2026-10-02")]
  assert.deepStrictEqual(Model.removeEntry(list, "2026-10-01").map(e => e.date), ["2026-10-02"])
})

// ---- persistence ----------------------------------------------------------

test("empty or missing file decodes to an empty, writable list", () => {
  assert.deepStrictEqual(Model.decode(""), { ok: true, data: Model.emptyData() })
  assert.deepStrictEqual(Model.decode(null), { ok: true, data: Model.emptyData() })
})

test("a damaged file is reported, so it is never overwritten", () => {
  assert.strictEqual(Model.decode("{ broken").ok, false)
  assert.strictEqual(Model.decode("[]").ok, false)
  assert.strictEqual(Model.decode('{"entries": 3}').ok, false)
})

test("decode drops invalid entries and dedupes days", () => {
  const text = JSON.stringify({ entries: [
    { date: "2026-10-02", mood: 1 },
    { date: "bad" },
    { date: "2026-10-01", mood: 3 },
    { date: "2026-10-02", mood: 4 }
  ] })
  const result = Model.decode(text)
  assert.strictEqual(result.ok, true)
  assert.deepStrictEqual(result.data.entries.map(e => [e.date, e.mood]), [["2026-10-01", 3], ["2026-10-02", 4]])
})

test("encode and decode round-trip without losing old entries", () => {
  const list = [entry("2019-01-01", { mood: -2, notes: "old" }), entry("2026-10-01", { mood: 1 })]
  const back = Model.decode(Model.encode(list))
  assert.deepStrictEqual(back.data.entries, list)
})

// ---- chart ----------------------------------------------------------------

test("chart range is today minus N days through today, like the app", () => {
  assert.deepStrictEqual(Model.chartRange("2026-10-31", 30), { from: "2026-10-01", to: "2026-10-31", days: 30 })
})

test("chart points are positioned by day and limited to the range", () => {
  const list = [entry("2026-09-01"), entry("2026-10-01", { mood: 2 }), entry("2026-10-16"), entry("2026-10-31")]
  const points = Model.chartPoints(list, "2026-10-01", "2026-10-31")
  assert.deepStrictEqual(points.map(p => p.x), [0, 0.5, 1])
  assert.strictEqual(points[0].mood, 2)
})

test("score y maps +5 to the top and -5 to the bottom", () => {
  assert.strictEqual(Model.scoreY(5), 0)
  assert.strictEqual(Model.scoreY(0), 0.5)
  assert.strictEqual(Model.scoreY(-5), 1)
})

test("axis labels are dd.MM and about five of them", () => {
  const labels = Model.axisLabels("2026-10-01", "2026-10-31")
  assert.strictEqual(labels[0].label, "01.10")
  assert.ok(labels.length >= 5 && labels.length <= 7, "got " + labels.length)
})

test("range summary averages only recorded days", () => {
  const list = [
    entry("2026-10-01", { mood: 2, functionality: 1, sleepHours: 8 }),
    entry("2026-10-03", { mood: -1, functionality: 0, sleepHours: 6, isHypomanic: true }),
    entry("2026-10-04", { mood: -4, functionality: -4 })
  ]
  const s = Model.rangeSummary(list, "2026-10-01", "2026-10-04")
  assert.strictEqual(s.count, 3)
  assert.strictEqual(s.days, 4)
  assert.strictEqual(Model.formatAverage(s.mood), "-1.0")
  assert.strictEqual(s.hypomanicDays, 1)
  assert.strictEqual(s.criticalDays, 1)
  assert.strictEqual(Model.formatAverage(null), "–")
})

// ---- reminder -------------------------------------------------------------

const EVENING = 20 * 60

test("reminder is due after the time when today has no entry", () => {
  const now = new Date(2026, 9, 4, 20, 5)
  assert.strictEqual(Model.reminderDue([], now, EVENING, ""), true)
  assert.strictEqual(Model.reminderDue([], new Date(2026, 9, 4, 19, 59), EVENING, ""), false)
})

test("reminder is not due once today is recorded or delivered", () => {
  const now = new Date(2026, 9, 4, 21, 0)
  assert.strictEqual(Model.reminderDue([entry("2026-10-04")], now, EVENING, ""), false)
  assert.strictEqual(Model.reminderDue([], now, EVENING, "2026-10-04"), false)
  // Yesterday's delivery does not silence today.
  assert.strictEqual(Model.reminderDue([], now, EVENING, "2026-10-03"), true)
})

test("an empty or malformed reminder time switches the reminder off", () => {
  const now = new Date(2026, 9, 4, 23, 0)
  assert.strictEqual(Model.reminderDue([], now, Model.parseTimeMinutes(""), ""), false)
  assert.strictEqual(Model.reminderDue([], now, Model.parseTimeMinutes("25:00"), ""), false)
})

test("the reminder is off unless switched on", () => {
  assert.strictEqual(Model.reminderMinutesFor(false, "20:00"), null)
  assert.strictEqual(Model.reminderMinutesFor(undefined, "20:00"), null)
  assert.strictEqual(Model.reminderMinutesFor("true", "20:00"), null)
  assert.strictEqual(Model.reminderMinutesFor(true, "20:00"), 20 * 60)
  assert.strictEqual(Model.reminderMinutesFor(true, "7:15"), 7 * 60 + 15)
  assert.strictEqual(Model.reminderMinutesFor(true, "nope"), null)
  const off = Model.reminderMinutesFor(false, "08:00")
  assert.strictEqual(Model.reminderDue([], new Date(2026, 9, 4, 23, 0), off, ""), false)
})

test("reminder times are normalized to HH:mm", () => {
  assert.strictEqual(Model.normalizeReminderTime("7:05"), "07:05")
  assert.strictEqual(Model.normalizeReminderTime(" 21:30 "), "21:30")
  assert.strictEqual(Model.normalizeReminderTime("00:00"), "00:00")
  assert.strictEqual(Model.normalizeReminderTime("24:00"), null)
  assert.strictEqual(Model.normalizeReminderTime("7:5"), null)
  assert.strictEqual(Model.normalizeReminderTime(""), null)
})

// ---- bar status -----------------------------------------------------------

test("status marks missing only after the reminder time", () => {
  assert.strictEqual(Model.statusView([], new Date(2026, 9, 4, 12, 0), EVENING).missing, false)
  assert.strictEqual(Model.statusView([], new Date(2026, 9, 4, 20, 0), EVENING).missing, true)
  assert.strictEqual(Model.statusView([], new Date(2026, 9, 4, 23, 0), null).missing, false)
})

test("status flags a critical day", () => {
  const view = Model.statusView([entry("2026-10-04", { mood: -5, functionality: -4 })], new Date(2026, 9, 4, 9, 0), EVENING)
  assert.strictEqual(view.critical, true)
  assert.ok(Model.tooltipText(view).indexOf("Critical") >= 0)
})

// ---- PDF export -------------------------------------------------------------

test("date input accepts German and ISO dates and rejects impossible ones", () => {
  assert.strictEqual(Model.parseDateInput("01.09.2026"), "2026-09-01")
  assert.strictEqual(Model.parseDateInput(" 1.9.2026 "), "2026-09-01")
  assert.strictEqual(Model.parseDateInput("2026-9-1"), "2026-09-01")
  assert.strictEqual(Model.parseDateInput("31.02.2026"), null)
  assert.strictEqual(Model.parseDateInput("09/01/2026"), null)
  assert.strictEqual(Model.parseDateInput(""), null)
  assert.strictEqual(Model.formatDateInput("2026-09-01"), "01.09.2026")
})

test("export range checks order but allows any span", () => {
  assert.deepStrictEqual(Model.exportRange("01.01.2020", "04.10.2026"), { ok: true, from: "2020-01-01", to: "2026-10-04" })
  assert.deepStrictEqual(Model.exportRange("04.10.2026", "04.10.2026"), { ok: true, from: "2026-10-04", to: "2026-10-04" })
  assert.strictEqual(Model.exportRange("05.10.2026", "04.10.2026").ok, false)
  assert.strictEqual(Model.exportRange("x", "04.10.2026").ok, false)
})

test("the report command carries only dates and a language", () => {
  const cmd = Model.reportCommand("/plugin/lifechart_report.py", "2026-09-01", "2026-09-30", "de")
  assert.deepStrictEqual(cmd, ["python3", "/plugin/lifechart_report.py", "--from", "2026-09-01", "--to", "2026-09-30", "--lang", "de"])
  assert.strictEqual(Model.reportCommand("h", "a", "b", "fr")[7], "de")
})

test("report language follows the setting, then LANG", () => {
  assert.strictEqual(Model.reportLanguage("en", "de_DE.UTF-8"), "en")
  assert.strictEqual(Model.reportLanguage("", "de_DE.UTF-8"), "de")
  assert.strictEqual(Model.reportLanguage(undefined, "en_US.UTF-8"), "en")
  assert.strictEqual(Model.reportLanguage("fr", "C"), "en")
})

test("the helper's last JSON line is the result", () => {
  const ok = Model.parseReportResult('noise\n{"ok": true, "path": "/x.pdf", "entries": 3, "pages": 1}\n')
  assert.strictEqual(ok.path, "/x.pdf")
  assert.strictEqual(Model.parseReportResult(""), null)
  assert.strictEqual(Model.parseReportResult('{"ok": false}'), null)
  assert.strictEqual(Model.parseReportResult("not json"), null)
})

// ---- medication tracker -----------------------------------------------------

function meds(medications, log) {
  return { medications: medications, log: log }
}
function at(day, time) {
  const [y, m, d] = day.split("-").map(Number)
  const [hh, mm] = time.split(":").map(Number)
  return new Date(y, m - 1, d, hh, mm).toISOString()
}
const TWICE = { id: "a", name: "A", times: ["08:00", "20:00"], enabled: true }
const ONCE = { id: "b", name: "B", times: ["07:30"], enabled: true }

test("all planned doses logged suggests taken", () => {
  const data = meds([TWICE, ONCE], [
    { medicationId: "a", timestamp: at("2026-10-03", "08:10") },
    { medicationId: "a", timestamp: at("2026-10-03", "21:30") },
    { medicationId: "b", timestamp: at("2026-10-03", "07:35") }
  ])
  assert.deepStrictEqual(Model.medicationSuggestion(data, "2026-10-03", "2026-10-04"),
    { planned: 3, taken: 3, complete: true })
})

test("a missing dose suggests not taken", () => {
  const data = meds([TWICE], [{ medicationId: "a", timestamp: at("2026-10-03", "08:00") }])
  const s = Model.medicationSuggestion(data, "2026-10-03", "2026-10-04")
  assert.deepStrictEqual(s, { planned: 2, taken: 1, complete: false })
  assert.ok(Model.medicationHint(s).indexOf("1 of 2") >= 0)
})

test("extra logs for one medication do not cover another", () => {
  const data = meds([TWICE, ONCE], [
    { medicationId: "a", timestamp: at("2026-10-03", "08:00") },
    { medicationId: "a", timestamp: at("2026-10-03", "12:00") },
    { medicationId: "a", timestamp: at("2026-10-03", "20:00") }
  ])
  assert.deepStrictEqual(Model.medicationSuggestion(data, "2026-10-03", "2026-10-04"),
    { planned: 3, taken: 2, complete: false })
})

test("logs of other days do not count", () => {
  const data = meds([ONCE], [{ medicationId: "b", timestamp: at("2026-10-02", "23:59") }])
  assert.strictEqual(Model.medicationSuggestion(data, "2026-10-03", "2026-10-04").taken, 0)
})

test("disabled and as-needed medications are left out", () => {
  const data = meds([
    { id: "c", name: "C", times: ["09:00"], enabled: false },
    { id: "d", name: "D", times: [], enabled: true }
  ], [])
  assert.strictEqual(Model.medicationSuggestion(data, "2026-10-03", "2026-10-04"), null)
})

test("no suggestion without meds data, for the future or beyond the meds log", () => {
  const data = meds([ONCE], [])
  assert.strictEqual(Model.medicationSuggestion(null, "2026-10-03", "2026-10-04"), null)
  assert.strictEqual(Model.medicationSuggestion({ broken: true }, "2026-10-03", "2026-10-04"), null)
  assert.strictEqual(Model.medicationSuggestion(data, "2026-10-05", "2026-10-04"), null)
  assert.notStrictEqual(Model.medicationSuggestion(data, "2026-09-05", "2026-10-04"), null)
  assert.strictEqual(Model.medicationSuggestion(data, "2026-09-04", "2026-10-04"), null)
})

// ---- crisis resources -----------------------------------------------------

test("every region in the list has resources, unknown regions fall back", () => {
  for (const region of Model.CRISIS_REGIONS)
    assert.ok(Model.crisisResources(region.value).length > 0, region.value)
  assert.strictEqual(Model.crisisResources("XX")[0].url, "https://findahelpline.com")
  assert.strictEqual(Model.crisisResources("de")[0].phone, "0800 111 0 111")
  assert.strictEqual(Model.normalizeRegion("xx"), "DE")
})

console.log(passed + " passed" + (process.exitCode ? ", some FAILED" : ""))
