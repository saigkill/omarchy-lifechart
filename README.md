# Life chart (saigkill.lifechart)

A daily mood and functionality tracker for the Omarchy bar, after the
[NIMH Life Chart method](https://www.nimh.nih.gov/). It brings the life chart
part of the [LifeChart app](https://github.com/saigkill/lifechart) to the
Quickshell bar; medications are handled by its sibling plugin
[omarchy-medical](https://github.com/saigkill/omarchy-medical) (`saigkill.meds`). This plugin is for people with bipolar disorder or other people, who wants to track their mood.

Life chart is a tool for self-observation, not a medical device.

**If you are in crisis, please contact a crisis helpline in your country.**
Germany: Telefonseelsorge **0800 111 0 111** (free, 24/7)

![Preview](https://github.com/saigkill/omarchy-lifechart/blob/master/preview.png?raw=true)

## Features

- **Bar widget**: a chart icon whose color reflects today's state:
  - Red: today's values are critical (mood **and** functionality at −4 or
    below), or the data file cannot be read
  - Amber: the reminder is on, its time has passed and today has no entry
  - Neutral: everything is fine
  The tooltip shows today's mood, functionality and sleep.
- **Today**: mood and functionality on a −5 to +5 scale. "More" adds sleep
  hours, medication taken, menstruation, hypomanic symptoms, symptoms and
  notes. ‹ › walk back to fill in a missed day. Saving critical values shows
  a crisis hint, as in the app. Closing and reopening the panel keeps
  unsaved input.
- **Medication tracker link**: when `saigkill.meds` is in use, "Medication
  taken" is pre-filled for a day that is not saved yet: on when every planned
  dose of that day is logged there, off otherwise. A hint shows the count
  ("2 of 3 doses logged"). Switching it by hand always wins, and a saved day
  is never changed. The meds file is only read, never written. Its log keeps
  30 days, so older days get no suggestion.
- **Chart**: mood and functionality over 30, 60 or 90 days, hypomanic days
  marked, with averages for the period. The colors are the colorblind-safe
  Okabe-Ito colors of the app.
- **PDF report** (Chart tab): any date range, typed as `DD.MM.YYYY` or
  picked with "Chart period", "Last month" or "All data". The report follows
  the app's: chart (functionality dashed, so it also reads in grayscale),
  summary (averages, hypomanic and critical days), daily table, notes and
  the current medications from `saigkill.meds`, with page numbers. It is
  saved as `~/Documents/LifeChart/LifeChart_<from>_<to>.pdf` (mode 0600) and
  can be opened from the panel. German or English, following `LANG` unless
  `reportLanguage` is set. Needs only `python3`, no extra packages.
- **Help**: crisis helplines per region (DE, AT, CH, GB, US, AU, CA, with
  findahelpline.com as fallback); copy the number or open the website.
- **Daily reminder** (optional, off by default): switch it on in the
  Settings tab and pick any time (`HH:MM`). If today has no entry by then, a
  notification is sent once that day; a reminder that could not be delivered
  (e.g. right after login) is retried every minute until it is.

## Data

```json
{
  "version": 1,
  "entries": [
    {
      "date": "2026-10-04",
      "mood": 1,
      "functionality": 0,
      "sleepHours": 7,
      "medicationTaken": true,
      "menstrualCycle": false,
      "isHypomanic": false,
      "symptoms": null,
      "notes": "Walk in the evening"
    }
  ]
}
```

One entry per day. The data lives in `~/.local/state/omarchy-lifechart/data.json`
(deliberately outside the plugin directory, since writing there makes
Quickshell reload the plugin). Entries are never trimmed. Writes are atomic,
the directory is private (`0700`) and the file `0600`, and a file that cannot be parsed is never overwritten: the widget turns red
and stops saving until the file is fixed.

The fields match the app's `DailyEntry`, so an export/import can map them one
to one.

## Install

```sh
omarchy plugin add https://github.com/saigkill/omarchy-lifechart.git --enable
```

## Configure

Settings live in the widget's entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "saigkill.lifechart",
  "reminderEnabled": true,
  "reminderTime": "20:00",
  "region": "DE",
  "period": 30
}
```

| Key | Default | Meaning |
|---|---|---|
| `reminderEnabled` | `false` | Daily reminder on/off (also set in the Settings tab) |
| `reminderTime` | `"20:00"` | Reminder time, `"HH:mm"`, any time of day (also set in the Settings tab) |
| `region` | `"DE"` | Crisis helplines shown in Help (also set from the panel) |
| `period` | `30` | Chart period, 30, 60 or 90 days (also set from the panel) |
| `reportLanguage` | from `LANG` | PDF report language, `"de"` or `"en"` |

## IPC

For keybindings and scripts:

```sh
omarchy-shell saigkill.lifechart toggle          # also: open, close, refresh
omarchy-shell saigkill.lifechart openTab chart   # today | chart | help | settings
omarchy-shell saigkill.lifechart exportPdf 01.09.2026 30.09.2026
```

`exportPdf` answers `started` (the panel then shows where the file went) or
the reason the range was rejected.

The report can also be made without the bar:

```sh
python3 lifechart_report.py --from 2026-09-01 --to 2026-09-30 [--lang en] [--out file.pdf]
```

It reads the data files itself; only the dates appear on the command line.

## Not (yet) included

The app's cloud backup (Google Drive, Nextcloud), biometric lock and
onboarding are not part of this plugin.

## Remove

```sh
omarchy plugin remove saigkill.lifechart
```

## Development

```sh
node tests/test_model.js                 # Model.js
python3 -m unittest discover -s tests    # PDF helper
```

See `AGENTS.md` for the rules that keep the plugin safe to change.
