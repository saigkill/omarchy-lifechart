# AGENTS.md

Guidance for AI agents working in this repository. The README documents *what*
the plugin does; this file records *how* to change it without breaking it.

## What this is

An Omarchy shell plugin (Quickshell/QML), id `saigkill.lifechart`: the life
chart part of the LifeChart app (`~/Projects/repos/software/net/lifechart`)
as a bar widget with a panel. Medications are NOT part of it; they live in
the sibling plugin `saigkill.meds` (`../omarchy-medical`), whose data file
is read (never written) for the "medication taken" suggestion and the PDF.
The only helper is `lifechart_report.py` for the PDF report. There is no
network.

| File | Role |
|---|---|
| `manifest.json` | Plugin id, kind (`bar-widget`), entry point |
| `BarWidget.qml` | Owns all state: data file and meds file (FileView), mutation API, settings, daily reminder, PDF export process, IPC |
| `Panel.qml` | UI only: Today form, Chart (Canvas) with the PDF export form, Help, Settings (reminder). Holds form state, nothing persistent |
| `Model.js` | Pure domain, chart, reminder, persistence, meds suggestion and export logic. Qt-free, tested under node |
| `lifechart_report.py` | PDF report for any date range; stdlib only, writes the PDF by hand |
| `tests/test_model.js` | Tests for `Model.js` |
| `tests/test_report.py` | Tests for the report helper, incl. font metrics against NimbusSans |

## The one rule that matters most

**Never lose or overwrite the user's history.** This is a mental health
record; years of entries may sit in that file. That is why:

- nothing is written before the file has been read (`loaded`), or a save
  could replace the history with an empty list;
- a file that exists but does not decode (`Model.decode().ok === false`, or a
  read error other than "not found") sets `loadError` and blocks every write
  until the user fixes it. Do not "recover" by writing an empty file;
- writes go through `FileView` with `atomicWrites: true`;
- entries are never trimmed or pruned. Do not add a retention limit;
- the list is replaced, not mutated, and one entry per day is enforced by
  `Model.upsertEntry()`.

The tests cover these. If a test about decoding or round-tripping fails, the
change is wrong. Do not adjust the test.

## The user's data

`~/.local/state/omarchy-lifechart/data.json` holds the user's real entries.
Do not read it out, edit, reset or "clean up" that file, and do not save
entries in the running panel to test something. To test with data, point
`dataDir` in `BarWidget.qml` at a scratch directory with generated data, and
put it back before you finish (`grep -n 'dataDir:' BarWidget.qml`).

The file lives outside the plugin directory on purpose: Quickshell watches the
plugin folder and reloads the plugin on any write there. Never move state
into the plugin directory.

## Domain rules (from LifeChart.Domain; keep them identical)

- Mood and functionality: integers −5..+5. Sleep: integers 0..24.
- **Critical needs both**: `mood <= -4 && functionality <= -4`. A single
  axis at −5 is not critical. This mirrors `DailyEntry.IsCritical`.
- The chart period "30 days" is today − 30 through today (31 days), like the
  app's `GetChartDataUseCase`. Days without an entry are not drawn; the line
  joins neighbouring entries.
- Crisis resources are copied from the app's `StaticCrisisResourceService`.
  When the app's list changes, update `CRISIS_RESOURCES` in `Model.js`.
- Chart colors are the app's Okabe-Ito colors (`MOOD_COLOR`,
  `FUNCTIONALITY_COLOR`, `HYPOMANIA_COLOR`). Keep them colorblind-safe.

If you change a rule here, change it in the app too, or ask first.

## Medication tracker link

`BarWidget.qml` reads `~/.local/state/omarchy-meds/data.json` (the
`saigkill.meds` plugin, `../omarchy-medical`) with a watched `FileView`.

- **Read only.** Never call `setText()` on `medsView` or write that file in
  any other way; it belongs to the meds plugin and holds the user's
  medication data.
- `Model.medicationSuggestion()` counts per medication every log entry of
  the day, capped at the planned times. That is the meds panel's "1/2"
  progress (`dosesDone`/`doseProgress`), not its 45-minute slot rule, so
  the two plugins show the same numbers.
- The meds log keeps 30 days; days older than `MEDS_LOG_DAYS` get no
  suggestion, never a false "not taken".
- The suggestion only fills the switch while the day is unsaved and the user
  has not touched it (`medicationTouched`). A saved value is never changed.
- If the meds data format changes (`medications[].id/name/dosage/times/enabled`,
  `log[].medicationId/timestamp`), update `medicationSuggestion()`,
  `load_medications()` in `lifechart_report.py` and their tests together.

## PDF report

- **No health data on the command line.** `/proc/<pid>/cmdline` is world
  readable. The panel passes only dates, the language and nothing else
  (`Model.reportCommand()`); the helper reads `data.json` and the meds file
  itself. A test checks the builder. Do not add `--notes`, `--entries` or a
  JSON argument.
- The report is written atomically with mode 0600 into
  `~/Documents/LifeChart/` (XDG documents dir), named like the app's.
- A damaged data file is an error (exit 1, no file), never an empty report.
  A missing file is an empty report.
- **Standard library only.** No reportlab, matplotlib or fontTools. The PDF
  uses the built-in Helvetica fonts with WinAnsiEncoding: text goes through
  `clean()`, characters outside cp1252 become `?` (or a mapped stand-in).
- The width tables (`_HELV`, `_HELV_BOLD`, `_EXTRA`) drive wrapping and
  alignment. `MetricsTests` compares them with NimbusSans (metric compatible).
  If it fails, fix the table, not the test.
- Layout follows the app's `PdfRenderer` (header, chart, legend, daily
  table, notes, medications, footer). Functionality stays dashed with square
  markers so the series can be told apart in a grayscale printout.
- The panel validates the range with `Model.exportRange()` (`DD.MM.YYYY` or
  ISO, start not after end, any span allowed); the helper checks again and
  exits 2 on a bad range. `parseReportResult()` reads the helper's last
  stdout line (`{"ok": true, "path", "entries", "pages"}`); stderr becomes
  the error shown in the panel.
- To look at a change: render with `gs -q -dNOPAUSE -dBATCH -sDEVICE=png16m
  -r70 -sOutputFile=page-%d.png report.pdf`, using generated data via
  `--data`/`--meds` in a scratch directory, never the user's report folder.

## Dates

Entries are keyed by local calendar day, `"YYYY-MM-DD"`. Day arithmetic goes
through local noon (`dateFromKey`) so DST never shifts a date; keep it that
way and keep the DST tests. The form never moves into the future.

Reopening the panel keeps unsaved form input; only a new calendar day
(`formLoadedOn`) reloads the form. Do not reload it in `open()`
unconditionally.

## Reminder

- **Optional and off by default** (`reminderEnabled: false`), like the app's
  evening reminder without a time. `Model.reminderMinutesFor()` returns null
  unless it is switched on, and everything (notification, amber icon,
  "missing" tooltip) keys off that null. Do not turn it on by default.
- The time is free (`HH:mm`, any minute of the day). The Settings tab writes
  `reminderEnabled` and `reminderTime` together through `setReminder()` →
  `updateSettings()`; an invalid time is rejected with a message and nothing
  is written. A malformed time in shell.json falls back to 20:00.
- Changing the time clears `reminderDeliveredDay`, so a new time that has
  already passed reminds once more for today if the entry is still missing.
- `reminderDue()` is true after `reminderTime` when today has no entry and
  today's reminder was not *delivered*. `reminderDeliveredDay` is only set
  after `omarchy-notification-send` exits 0, because the shell rejects
  notifications in its first seconds after start.
- The timer is deliberately not `triggeredOnStart`.
- Each bar (one per monitor) runs its own widget and sends its own reminder;
  `replaceIdFor(day)` merges them into one toast. Keep the id deterministic.

## Settings

Settings come from the widget's `shell.json` entry via `setting(name,
fallback)`: `reminderEnabled`, `reminderTime`, `region`, `period`,
`reportLanguage`. Panel choices (reminder, region, period) are written back
with `updateSetting()` / `updateSettings()` (several keys at once), which call
`bar.shell.updateEntryInline()` the same way the built-in clock persists a
cycled format. Document every new setting in the README table.

## IPC

Target `saigkill.lifechart`: `open`, `close`, `show`, `hide`, `toggle`,
`refresh`, `openTab <today|chart|help|settings>`, `exportPdf <from> <to>` (returns
`started` or the validation error). Every bar registers the handler; only the
first one is used, which is why the log shows "Handler was registered but
will not be used". That warning is expected.

## Before you change anything

```sh
node tests/test_model.js
python3 -m unittest discover -s tests
```

Both must be green before and after. Add a test for every new `Model.js` function
and export it in `module.exports`.

## Editing the QML

**Count the braces after every insertion.** A stray `}` closes the enclosing
`Column`; Quickshell reports one `Syntax error` and the panel opens empty.

```sh
python3 - <<'EOF'
import re
for f in ('BarWidget.qml', 'Panel.qml'):
    depth = 0
    for l in open(f, encoding='utf-8').read().split('\n'):
        s = re.sub(r'"(\\.|[^"\\])*"', '""', l)
        s = re.sub(r'//.*', '', s)
        for c in s:
            depth += (c == '{') - (c == '}')
    print(f, depth)  # must be 0
EOF
```

- `qmllint` is not a syntax check here: `qs.*` imports give false positives.
- **Inline components (`component X: ...`) cannot see the file's ids**, so
  `root.` does not work inside them. They take `required property var theme`
  and every use passes `theme: root`.
- Do not put `height: visible ? implicitHeight : 0` on a `Text`: it causes a
  binding loop. A `Column` skips invisible children anyway; the pattern is
  only used on nested `Column`/`Row` sections.
- `PanelKeyCatcher` eats keys (j/k, Tab, Escape) unless `blocked`. Every text
  input must be part of the `blocked:` expression (`NoteArea.inputFocused`,
  `exportFromField.activeFocus`, `exportToField.activeFocus`,
  `reminderTimeField.activeFocus`).
- The export and reminder `TextField`s break their `text:` binding on
  typing; they are refilled through `exportToken` / `reminderToken` (a
  `Connections` per field). Use `setExportRange()` / `loadReminderForm()`,
  not direct assignment, to change them.
- `KeyboardPanel` only accepts visual items as direct children; keep `Process`
  objects at the top level of `Panel.qml`.
- `entries` must be replaced, never mutated in place, or bindings will not
  update.
- The Canvas repaints on `points`/`labels`/size changes only. If you add a
  property that affects drawing, add an `on...Changed: requestPaint()`.

## Deploying to test

`~/.config/omarchy/plugins/saigkill.lifechart` is a symlink to this
directory.

```sh
omarchy restart shell
pgrep -x quickshell || hyprctl dispatch 'hl.dsp.exec_cmd("omarchy-launch-shell")'
journalctl --user --since "-2m" | grep -i lifechart
omarchy-shell saigkill.lifechart openTab chart
```

`exportPdf` over IPC writes a real file into `~/Documents/LifeChart/`;
delete a report you created only for testing.

Use a full restart: QML keeps components it has already compiled, and the
hot reload does not replace them. A restart started from an agent can leave
the shell dead; the `pgrep` line brings it back. The shell's IPC is often
slow with many plugins: retry `omarchy-shell` calls instead of concluding the
plugin is broken. A panel screenshot right after `open` can catch the fade-in
and look empty; take a second one.

## Conventions

- English in code, comments, UI strings and the README; German in
  conversation.
- No dependencies beyond Qt/QML, Quickshell and the Omarchy shell's `qs.*`
  modules, plus the Python standard library for the report helper.
  External commands: `omarchy-notification-send`, `mkdir`, `wl-copy`,
  `python3`.
- Match the surrounding comment density: explain *why*.
- Bump `version` in `manifest.json` for user-visible changes.
