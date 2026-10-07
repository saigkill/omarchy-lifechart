// Pure life chart logic for the bar widget and panel. Qt-free so it can be
// unit tested under node; the QML owns file IO and UI.
//
// The rules mirror the LifeChart app (LifeChart.Domain): mood and
// functionality run from -5 to +5, sleep from 0 to 24 hours, and a day is
// critical only when BOTH mood and functionality are at -4 or below.

var SCORE_MIN = -5
var SCORE_MAX = 5
var SLEEP_MIN = 0
var SLEEP_MAX = 24
var CRITICAL_THRESHOLD = -4
var DATA_VERSION = 1
var PERIODS = [30, 60, 90]

// Okabe-Ito colors, the same ones the app uses, so the chart stays readable
// with the common forms of color blindness.
var MOOD_COLOR = "#0072B2"
var FUNCTIONALITY_COLOR = "#E69F00"
var HYPOMANIA_COLOR = "#CC79A7"

function pad2(value) {
  var n = Number(value)
  return (n < 10 ? "0" : "") + n
}

// ---- dates ------------------------------------------------------------
// Entries are keyed by local calendar day, "YYYY-MM-DD", like the app's
// DateOnly. Day arithmetic goes through local noon so a DST switch can never
// push a date across midnight.

function keyForDate(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

function isDateKey(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(value))) return false
  return keyForDate(dateFromKey(value)) === String(value)
}

function dateFromKey(key) {
  var parts = String(key).split("-")
  return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]), 12, 0, 0)
}

function addDays(key, days) {
  var date = dateFromKey(key)
  date.setDate(date.getDate() + Math.round(Number(days) || 0))
  return keyForDate(date)
}

function daysBetween(fromKey, toKey) {
  return Math.round((dateFromKey(toKey).getTime() - dateFromKey(fromKey).getTime()) / 86400000)
}

// "13.07" — the axis label format of the app.
function shortLabel(key) {
  var parts = String(key).split("-")
  return parts[2] + "." + parts[1]
}

// "HH:mm" -> minutes since midnight, or null when malformed.
function parseTimeMinutes(value) {
  var text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (!/^([01]?\d|2[0-3]):[0-5]\d$/.test(text)) return null
  var parts = text.split(":")
  return Number(parts[0]) * 60 + Number(parts[1])
}

function minutesOfDay(date) {
  return date.getHours() * 60 + date.getMinutes()
}

// ---- values -----------------------------------------------------------

function clampInt(value, min, max, fallback) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

function clampScore(value) {
  return clampInt(value, SCORE_MIN, SCORE_MAX, 0)
}

function clampSleep(value) {
  return clampInt(value, SLEEP_MIN, SLEEP_MAX, 0)
}

// "+3", "-2", "0" — the app's display format for scores.
function formatSigned(value) {
  var n = Math.round(Number(value) || 0)
  return n > 0 ? "+" + n : String(n)
}

function optionalText(value) {
  var text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  return text === "" ? null : text
}

// A clean copy of an entry, or null when it has no valid date. Scores out of
// range are clamped rather than dropped: a hand-edited file should lose a
// typo, not a day.
function normalizeEntry(raw) {
  if (!raw || typeof raw !== "object" || !isDateKey(raw.date)) return null
  return {
    date: String(raw.date),
    mood: clampScore(raw.mood),
    functionality: clampScore(raw.functionality),
    sleepHours: clampSleep(raw.sleepHours),
    medicationTaken: raw.medicationTaken === true,
    menstrualCycle: raw.menstrualCycle === true,
    isHypomanic: raw.isHypomanic === true,
    symptoms: optionalText(raw.symptoms),
    notes: optionalText(raw.notes)
  }
}

function isCritical(entry) {
  if (!entry) return false
  return entry.mood <= CRITICAL_THRESHOLD && entry.functionality <= CRITICAL_THRESHOLD
}

function blankEntry(dateKey) {
  return normalizeEntry({ date: dateKey })
}

// ---- entry list -------------------------------------------------------
// The list is always sorted by date with one entry per day. Every function
// returns a new array: QML only notices a replaced list.

function sortEntries(entries) {
  return entries.slice().sort(function(a, b) {
    return a.date < b.date ? -1 : (a.date > b.date ? 1 : 0)
  })
}

function findEntry(entries, dateKey) {
  var list = entries || []
  for (var i = 0; i < list.length; i++)
    if (list[i].date === dateKey) return list[i]
  return null
}

// Insert or replace the entry for its day. Returns null for an invalid entry.
function upsertEntry(entries, raw) {
  var entry = normalizeEntry(raw)
  if (!entry) return null
  var out = []
  var list = entries || []
  for (var i = 0; i < list.length; i++)
    if (list[i].date !== entry.date) out.push(list[i])
  out.push(entry)
  return sortEntries(out)
}

function removeEntry(entries, dateKey) {
  return (entries || []).filter(function(entry) { return entry.date !== dateKey })
}

// Inclusive on both ends, like the app's GetRangeAsync.
function entriesInRange(entries, fromKey, toKey) {
  return (entries || []).filter(function(entry) {
    return entry.date >= fromKey && entry.date <= toKey
  })
}

// ---- chart ------------------------------------------------------------

// The app shows "30 days" as today minus 30 days through today.
function chartRange(todayKey, days) {
  var span = Math.max(1, Math.round(Number(days) || 30))
  return { from: addDays(todayKey, -span), to: todayKey, days: span }
}

// Points with their x position as a 0..1 fraction of the range, so the
// Canvas only has to scale. Gaps (days without an entry) stay gaps: the line
// joins neighbouring entries, as in the app.
function chartPoints(entries, fromKey, toKey) {
  var total = Math.max(1, daysBetween(fromKey, toKey))
  return entriesInRange(entries, fromKey, toKey).map(function(entry) {
    return {
      date: entry.date,
      x: daysBetween(fromKey, entry.date) / total,
      mood: entry.mood,
      functionality: entry.functionality,
      isHypomanic: entry.isHypomanic
    }
  })
}

// About five date labels along the x axis.
function axisLabels(fromKey, toKey) {
  var total = Math.max(1, daysBetween(fromKey, toKey))
  var step = Math.max(1, Math.floor(total / 5))
  var out = []
  for (var i = 0; i <= total; i += step) {
    var key = addDays(fromKey, i)
    out.push({ x: i / total, label: shortLabel(key) })
  }
  return out
}

// 0..1 from the top for a score, matching the app's YToPx.
function scoreY(value) {
  return (SCORE_MAX - clampScore(value)) / (SCORE_MAX - SCORE_MIN)
}

function average(values) {
  if (values.length === 0) return null
  var sum = 0
  for (var i = 0; i < values.length; i++) sum += values[i]
  return sum / values.length
}

// "+1.3" / "-0.5" / "–" for the summary line.
function formatAverage(value) {
  if (value === null || value === undefined) return "–"
  var rounded = Math.round(value * 10) / 10
  return (rounded > 0 ? "+" : "") + rounded.toFixed(1)
}

function rangeSummary(entries, fromKey, toKey) {
  var list = entriesInRange(entries, fromKey, toKey)
  return {
    count: list.length,
    days: Math.max(1, daysBetween(fromKey, toKey)) + 1,
    mood: average(list.map(function(e) { return e.mood })),
    functionality: average(list.map(function(e) { return e.functionality })),
    sleep: average(list.map(function(e) { return e.sleepHours })),
    hypomanicDays: list.filter(function(e) { return e.isHypomanic }).length,
    criticalDays: list.filter(isCritical).length
  }
}

// ---- reminder ---------------------------------------------------------

// True when the daily reminder should be sent now: enabled, the time has
// passed, there is no entry for today yet, and today's reminder has not been
// delivered. `deliveredDay` is the day key of the last DELIVERED reminder, so
// a send the shell rejected stays due and is retried on the next check.
function reminderDue(entries, now, reminderMinutes, deliveredDay) {
  if (reminderMinutes === null || reminderMinutes === undefined) return false
  var today = keyForDate(now)
  if (deliveredDay === today) return false
  if (findEntry(entries, today)) return false
  return minutesOfDay(now) >= reminderMinutes
}

var DEFAULT_REMINDER_TIME = "20:00"

// "8:5" is not accepted, "8:05" and "08:05" are; returns "HH:mm" or null.
function normalizeReminderTime(text) {
  var mins = parseTimeMinutes(text)
  if (mins === null) return null
  return pad2(Math.floor(mins / 60)) + ":" + pad2(mins % 60)
}

// The reminder is optional and off unless switched on, like the app's
// evening reminder without a time. Returns minutes since midnight or null.
function reminderMinutesFor(enabled, time) {
  if (enabled !== true) return null
  return parseTimeMinutes(time)
}

// ---- bar status -------------------------------------------------------

function statusView(entries, now, reminderMinutes) {
  var today = keyForDate(now)
  var entry = findEntry(entries, today)
  var reminderPassed = reminderMinutes !== null && reminderMinutes !== undefined
    && minutesOfDay(now) >= reminderMinutes
  return {
    today: today,
    entry: entry,
    hasEntry: entry !== null,
    critical: isCritical(entry),
    missing: entry === null && reminderPassed
  }
}

function tooltipText(view) {
  if (!view.entry) {
    return view.missing
      ? "Life chart: today's entry is still missing"
      : "Life chart: no entry for today yet"
  }
  var e = view.entry
  var lines = ["Life chart today",
    "Mood " + formatSigned(e.mood) + "  ·  Functionality " + formatSigned(e.functionality)
      + "  ·  Sleep " + e.sleepHours + " h"]
  if (e.isHypomanic) lines.push("Hypomanic")
  if (view.critical) lines.push("Critical values — help is in the panel")
  return lines.join("\n")
}

// ---- PDF export -----------------------------------------------------------

// "2026-09-01", "1.9.2026" or "01.09.2026" -> "2026-09-01", or null.
function parseDateInput(text) {
  var value = String(text === undefined || text === null ? "" : text).replace(/^\s+|\s+$/g, "")
  var iso = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(value)
  var german = /^(\d{1,2})\.(\d{1,2})\.(\d{4})$/.exec(value)
  var key = null
  if (iso) key = iso[1] + "-" + pad2(iso[2]) + "-" + pad2(iso[3])
  else if (german) key = german[3] + "-" + pad2(german[2]) + "-" + pad2(german[1])
  return key && isDateKey(key) ? key : null
}

// "01.09.2026" — how the form shows a day key.
function formatDateInput(key) {
  var parts = String(key).split("-")
  return parts.length === 3 ? parts[2] + "." + parts[1] + "." + parts[0] : ""
}

// Validates the export form. Any range is allowed, including days without
// entries and days before the first entry; only the order and real dates
// are checked.
function exportRange(fromText, toText) {
  var from = parseDateInput(fromText)
  var to = parseDateInput(toText)
  if (!from) return { ok: false, error: "Start date is not a valid date (DD.MM.YYYY)." }
  if (!to) return { ok: false, error: "End date is not a valid date (DD.MM.YYYY)." }
  if (from > to) return { ok: false, error: "The start date is after the end date." }
  return { ok: true, from: from, to: to }
}

// The helper's command line. Only dates and the language: the health data
// is read from the file by the helper, never passed as an argument.
function reportCommand(helper, fromKey, toKey, lang) {
  return ["python3", String(helper), "--from", String(fromKey), "--to", String(toKey),
    "--lang", lang === "en" ? "en" : "de"]
}

// "de" for a German locale, else "en"; the setting wins when it is valid.
function reportLanguage(setting, localeName) {
  var chosen = String(setting || "").toLowerCase()
  if (chosen === "de" || chosen === "en") return chosen
  return /^de/i.test(String(localeName || "")) ? "de" : "en"
}

// The helper prints one JSON line on success.
function parseReportResult(stdout) {
  var lines = String(stdout || "").split("\n").filter(function(l) { return l.replace(/\s+/g, "") !== "" })
  if (lines.length === 0) return null
  try {
    var result = JSON.parse(lines[lines.length - 1])
    return result && result.ok === true && typeof result.path === "string" ? result : null
  } catch (error) {
    return null
  }
}

// ---- medication tracker (saigkill.meds) -----------------------------------
// The meds plugin's data file is read, never written. Its log only keeps 30
// days, so older days get no suggestion rather than a false "not taken".
var MEDS_LOG_DAYS = 29

// Planned and logged doses of one day, counted the way the meds panel shows
// its "1/2" progress: per medication, every log entry of that day counts, up
// to the number of planned times. Only enabled medications with at least one
// valid time take part; "as needed" medications have no times and are left
// out. Returns null when there is nothing to suggest.
function medicationSuggestion(medsData, dateKey, todayKey) {
  if (!medsData || typeof medsData !== "object") return null
  if (!isDateKey(dateKey) || !isDateKey(todayKey)) return null
  var age = daysBetween(dateKey, todayKey)
  if (age < 0 || age > MEDS_LOG_DAYS) return null
  var meds = Array.isArray(medsData.medications) ? medsData.medications : []
  var log = Array.isArray(medsData.log) ? medsData.log : []
  var planned = 0
  var taken = 0
  for (var i = 0; i < meds.length; i++) {
    var med = meds[i]
    if (!med || med.enabled === false) continue
    var times = {}
    var count = 0
    var raw = Array.isArray(med.times) ? med.times : []
    for (var t = 0; t < raw.length; t++) {
      var mins = parseTimeMinutes(raw[t])
      if (mins === null || mins in times) continue
      times[mins] = true
      count++
    }
    if (count === 0) continue
    var done = 0
    for (var l = 0; l < log.length; l++) {
      var entry = log[l]
      if (!entry || entry.medicationId !== med.id) continue
      var at = new Date(entry.timestamp)
      if (!isNaN(at.getTime()) && keyForDate(at) === dateKey) done++
    }
    planned += count
    taken += Math.min(done, count)
  }
  if (planned === 0) return null
  return { planned: planned, taken: taken, complete: taken >= planned }
}

function medicationHint(suggestion) {
  if (!suggestion) return ""
  return "Medication tracker: " + suggestion.taken + " of " + suggestion.planned
    + " doses logged" + (suggestion.complete ? "" : " — not all taken")
}

// ---- crisis resources -------------------------------------------------
// Copied from the app's StaticCrisisResourceService. Keep both in sync.

var CRISIS_REGIONS = [
  { value: "DE", label: "Deutschland" },
  { value: "AT", label: "Österreich" },
  { value: "CH", label: "Schweiz" },
  { value: "GB", label: "United Kingdom" },
  { value: "US", label: "United States" },
  { value: "AU", label: "Australia" },
  { value: "CA", label: "Canada" }
]

var CRISIS_RESOURCES = {
  DE: [
    { name: "Telefonseelsorge", phone: "0800 111 0 111", url: "https://www.telefonseelsorge.de" },
    { name: "Telefonseelsorge", phone: "0800 111 0 222", url: "https://www.telefonseelsorge.de" }
  ],
  AT: [{ name: "Telefonseelsorge Österreich", phone: "142", url: "https://www.telefonseelsorge.at" }],
  CH: [{ name: "Die Dargebotene Hand", phone: "143", url: "https://www.143.ch" }],
  GB: [{ name: "Samaritans", phone: "116 123", url: "https://www.samaritans.org" }],
  US: [{ name: "988 Suicide & Crisis Lifeline", phone: "988", url: "https://988lifeline.org" }],
  AU: [{ name: "Lifeline Australia", phone: "13 11 14", url: "https://www.lifeline.org.au" }],
  CA: [{ name: "Crisis Services Canada", phone: "1-833-456-4566", url: "https://www.crisisservicescanada.ca" }]
}

var CRISIS_FALLBACK = [{ name: "findahelpline.com", phone: "", url: "https://findahelpline.com" }]

function crisisResources(region) {
  var key = String(region || "").toUpperCase()
  return CRISIS_RESOURCES[key] || CRISIS_FALLBACK
}

function normalizeRegion(region) {
  var key = String(region || "").toUpperCase()
  return CRISIS_RESOURCES[key] ? key : "DE"
}

// ---- persistence ------------------------------------------------------

function emptyData() {
  return { version: DATA_VERSION, entries: [] }
}

// Parse the data file. Returns { ok, data }: ok is false when the text is not
// a life chart file, so the caller can refuse to overwrite it.
function decode(text) {
  var source = String(text === undefined || text === null ? "" : text)
  if (source.replace(/\s+/g, "") === "") return { ok: true, data: emptyData() }
  var parsed
  try { parsed = JSON.parse(source) } catch (error) { return { ok: false, data: emptyData() } }
  if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.entries))
    return { ok: false, data: emptyData() }
  var entries = []
  var seen = {}
  for (var i = 0; i < parsed.entries.length; i++) {
    var entry = normalizeEntry(parsed.entries[i])
    if (!entry) continue
    seen[entry.date] = entry
  }
  for (var key in seen) entries.push(seen[key])
  return { ok: true, data: { version: DATA_VERSION, entries: sortEntries(entries) } }
}

// Entries are never trimmed: the history is the point of a life chart.
function encode(entries) {
  return JSON.stringify({ version: DATA_VERSION, entries: sortEntries(entries || []) }, null, 2) + "\n"
}

if (typeof module !== "undefined") {
  module.exports = {
    SCORE_MIN: SCORE_MIN,
    SCORE_MAX: SCORE_MAX,
    SLEEP_MIN: SLEEP_MIN,
    SLEEP_MAX: SLEEP_MAX,
    PERIODS: PERIODS,
    keyForDate: keyForDate,
    isDateKey: isDateKey,
    dateFromKey: dateFromKey,
    addDays: addDays,
    daysBetween: daysBetween,
    shortLabel: shortLabel,
    parseTimeMinutes: parseTimeMinutes,
    clampScore: clampScore,
    clampSleep: clampSleep,
    formatSigned: formatSigned,
    normalizeEntry: normalizeEntry,
    isCritical: isCritical,
    blankEntry: blankEntry,
    findEntry: findEntry,
    upsertEntry: upsertEntry,
    removeEntry: removeEntry,
    entriesInRange: entriesInRange,
    chartRange: chartRange,
    chartPoints: chartPoints,
    axisLabels: axisLabels,
    scoreY: scoreY,
    formatAverage: formatAverage,
    rangeSummary: rangeSummary,
    reminderDue: reminderDue,
    DEFAULT_REMINDER_TIME: DEFAULT_REMINDER_TIME,
    normalizeReminderTime: normalizeReminderTime,
    reminderMinutesFor: reminderMinutesFor,
    statusView: statusView,
    tooltipText: tooltipText,
    parseDateInput: parseDateInput,
    formatDateInput: formatDateInput,
    exportRange: exportRange,
    reportCommand: reportCommand,
    reportLanguage: reportLanguage,
    parseReportResult: parseReportResult,
    medicationSuggestion: medicationSuggestion,
    medicationHint: medicationHint,
    CRISIS_REGIONS: CRISIS_REGIONS,
    crisisResources: crisisResources,
    normalizeRegion: normalizeRegion,
    emptyData: emptyData,
    decode: decode,
    encode: encode
  }
}
