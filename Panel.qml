import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Life chart panel: the daily entry, the mood chart and crisis resources.
// All data and mutations live on the host bar widget; this panel reads and
// calls through `hostWidget` and only holds form state.
Panel {
  id: root
  moduleName: "saigkill.lifechart"
  ipcTarget: "saigkill.lifechart"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property var entries: hostWidget ? hostWidget.entries : []
  readonly property date now: hostWidget ? hostWidget.now : new Date()
  readonly property string todayKey: Model.keyForDate(now)
  readonly property bool writable: hostWidget ? hostWidget.writable : false
  readonly property string region: hostWidget ? hostWidget.region : "DE"
  readonly property int period: hostWidget ? hostWidget.defaultPeriod : 30

  readonly property color warningColor: "#c9a227"
  readonly property color contentForeground: bar ? bar.barForeground : Color.foreground
  readonly property color mutedForeground: Qt.darker(contentForeground, 1.5)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- view state ---------------------------------------------------
  property string tab: "today"

  // ---- form state -----------------------------------------------------
  // The form edits one day. It starts on today; ‹ › walk back to fill in a
  // missed day, never into the future.
  property string formDate: ""
  property int formMood: 0
  property int formFunctionality: 0
  property int formSleep: 0
  property bool formMedication: false
  property bool formMenstrual: false
  property bool formHypomanic: false
  property string formSymptoms: ""
  property string formNotes: ""
  property bool formExtended: false
  property bool formExists: false
  // Bumped whenever the form is reloaded, so the text areas re-take their
  // value without fighting the user's typing in between.
  property int formToken: 0
  property string formLoadedOn: ""

  property string statusText: ""
  property bool statusCritical: false
  property bool pendingDelete: false

  // Suggestion from the medication tracker for the day in the form. It only
  // fills the switch for a day that is not saved yet and that the user has
  // not set by hand; a saved value is never changed behind their back.
  readonly property var medsSuggestion: Model.medicationSuggestion(
    hostWidget ? hostWidget.medsData : null, formDate, todayKey)
  property bool medicationTouched: false

  onMedsSuggestionChanged: applyMedsSuggestion()

  function applyMedsSuggestion() {
    if (root.formExists || root.medicationTouched || !root.medsSuggestion) return
    root.formMedication = root.medsSuggestion.complete
  }

  // ---- PDF export form ----------------------------------------------------
  // Free text in DD.MM.YYYY (ISO works too); prefilled with the chart period.
  property string exportFrom: ""
  property string exportTo: ""
  property string exportFormError: ""
  property int exportToken: 0

  function setExportRange(fromKey, toKey) {
    root.exportFrom = Model.formatDateInput(fromKey)
    root.exportTo = Model.formatDateInput(toKey)
    root.exportFormError = ""
    root.exportToken++
  }

  function startExport() {
    var range = Model.exportRange(root.exportFrom, root.exportTo)
    if (!range.ok) {
      root.exportFormError = range.error
      return
    }
    root.exportFormError = ""
    if (root.hostWidget) root.hostWidget.exportReport(range.from, range.to)
  }

  // ---- reminder settings form ----------------------------------------------
  property bool reminderFormEnabled: false
  property string reminderFormTime: ""
  property string reminderFormError: ""
  property string reminderFormStatus: ""
  property int reminderToken: 0

  function loadReminderForm() {
    if (!root.hostWidget) return
    root.reminderFormEnabled = root.hostWidget.reminderEnabled
    root.reminderFormTime = root.hostWidget.reminderTime
    root.reminderFormError = ""
    root.reminderFormStatus = ""
    root.reminderToken++
  }

  function applyReminder() {
    if (!root.hostWidget) return
    var error = root.hostWidget.setReminder(root.reminderFormEnabled, root.reminderFormTime)
    root.reminderFormError = error
    if (error !== "") {
      root.reminderFormStatus = ""
      return
    }
    root.reminderFormTime = Model.normalizeReminderTime(root.reminderFormTime)
    root.reminderToken++
    root.reminderFormStatus = root.reminderFormEnabled
      ? "Saved. Reminder daily at " + root.reminderFormTime + " when today has no entry."
      : "Saved. The reminder is off."
  }

  function firstEntryKey() {
    return root.entries.length > 0 ? root.entries[0].date : root.todayKey
  }

  readonly property var range: Model.chartRange(todayKey, period)
  readonly property var summary: Model.rangeSummary(entries, range.from, range.to)

  // Reopening keeps unsaved input; only a new day starts a fresh form.
  function open() {
    if (root.formLoadedOn !== root.todayKey) root.loadForm(root.todayKey)
    if (root.exportFrom === "" && root.exportTo === "") root.setExportRange(root.range.from, root.range.to)
    root.loadReminderForm()
    root.controller.show()
  }

  function openTab(name) {
    if (["today", "chart", "help", "settings"].indexOf(String(name)) < 0) return
    root.tab = String(name)
    if (!root.opened) root.open()
  }

  function close() {
    root.pendingDelete = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  // ---- form ------------------------------------------------------------
  function loadForm(dateKey) {
    var entry = Model.findEntry(root.entries, dateKey)
    var source = entry || Model.blankEntry(dateKey)
    root.formDate = dateKey
    root.formMood = source.mood
    root.formFunctionality = source.functionality
    root.formSleep = source.sleepHours
    root.formMedication = source.medicationTaken
    root.formMenstrual = source.menstrualCycle
    root.formHypomanic = source.isHypomanic
    root.formSymptoms = source.symptoms || ""
    root.formNotes = source.notes || ""
    root.formExists = entry !== null
    // A day that already has symptoms or notes opens expanded, so they are
    // never hidden behind "More".
    root.formExtended = root.formSymptoms !== "" || root.formNotes !== ""
    root.statusText = ""
    root.statusCritical = false
    root.pendingDelete = false
    root.formLoadedOn = root.todayKey
    root.medicationTouched = false
    root.applyMedsSuggestion()
    root.formToken++
  }

  function shiftDay(delta) {
    var next = Model.addDays(root.formDate, delta)
    if (next > root.todayKey) return
    root.loadForm(next)
  }

  function saveForm() {
    if (!root.hostWidget) return
    var result = root.hostWidget.saveEntry({
      date: root.formDate,
      mood: root.formMood,
      functionality: root.formFunctionality,
      sleepHours: root.formSleep,
      medicationTaken: root.formMedication,
      menstrualCycle: root.formMenstrual,
      isHypomanic: root.formHypomanic,
      symptoms: root.formSymptoms,
      notes: root.formNotes
    })
    if (!result.ok) {
      root.statusCritical = true
      root.statusText = "Not saved: the data file is not writable."
      return
    }
    root.formExists = true
    root.statusCritical = result.critical
    root.statusText = result.critical
      ? "Saved. Your values are critical today — please reach out for support."
      : "Saved."
  }

  function deleteForm() {
    if (!root.hostWidget) return
    root.hostWidget.deleteEntry(root.formDate)
    root.loadForm(root.formDate)
    root.statusText = "Entry deleted."
  }

  function formDateLabel() {
    if (!root.formDate) return ""
    var date = Model.dateFromKey(root.formDate)
    var label = Qt.locale().toString(date, "dddd, d. MMMM yyyy")
    return root.formDate === root.todayKey ? "Today · " + label : label
  }

  function copyText(text) {
    copyProc.command = ["wl-copy", "--", String(text)]
    copyProc.running = true
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(500))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: symptomsArea.inputFocused || notesArea.inputFocused
        || exportFromField.activeFocus || exportToField.activeFocus || reminderTimeField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: mainColumn
          width: scroll.width
          spacing: Style.space(10)

          // ---- header ----------------------------------------------------
          Item {
            width: parent.width
            height: headerRow.implicitHeight
            implicitHeight: headerRow.implicitHeight

            PanelSectionHeader {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              text: "LIFE CHART"
            }

            ButtonGroup {
              id: headerRow
              anchors.right: parent.right
              options: [
                { value: "today", label: "Today" },
                { value: "chart", label: "Chart" },
                { value: "help", label: "Help" },
                { value: "settings", label: "Settings" }
              ]
              value: root.tab
              focusable: false
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onChanged: function(v) { root.tab = v }
            }
          }

          // ---- data file problem -----------------------------------------
          Rectangle {
            visible: !!root.hostWidget && (root.hostWidget.loadError !== "" || root.hostWidget.saveError !== "")
            width: parent.width
            height: visible ? errorText.implicitHeight + Style.space(14) : 0
            implicitHeight: height
            radius: Style.cornerRadius
            color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.14)

            Text {
              id: errorText
              anchors.fill: parent
              anchors.margins: Style.space(7)
              anchors.leftMargin: Style.space(12)
              text: root.hostWidget ? (root.hostWidget.loadError || root.hostWidget.saveError) : ""
              color: Color.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              verticalAlignment: Text.AlignVCenter
            }
          }

          PanelSeparator {
            foreground: root.contentForeground
          }

          // ==== TODAY =====================================================
          Column {
            id: todayColumn
            visible: root.tab === "today"
            width: parent.width
            height: visible ? implicitHeight : 0
            spacing: Style.space(10)

            // Day navigation
            Item {
              width: parent.width
              height: dayRow.implicitHeight
              implicitHeight: dayRow.implicitHeight

              Row {
                id: dayRow
                anchors.left: parent.left
                spacing: Style.space(6)

                PanelActionButton {
                  iconText: ""
                  tooltipText: "Previous day"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: root.shiftDay(-1)
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.formDateLabel()
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                PanelActionButton {
                  visible: root.formDate < root.todayKey
                  iconText: ""
                  tooltipText: "Next day"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: root.shiftDay(1)
                }
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.formExists ? "saved" : "no entry yet"
                color: root.mutedForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }

            ScoreRow {

              theme: root
              width: parent.width
              label: "Mood"
              hint: "-5 depressed · 0 balanced · +5 manic"
              accent: Model.MOOD_COLOR
              minimum: Model.SCORE_MIN
              maximum: Model.SCORE_MAX
              value: root.formMood
              valueText: Model.formatSigned(root.formMood)
              onChosen: function(v) { root.formMood = v }
            }

            ScoreRow {

              theme: root
              width: parent.width
              label: "Functionality"
              hint: "-5 not able to function · +5 fully functional"
              accent: Model.FUNCTIONALITY_COLOR
              minimum: Model.SCORE_MIN
              maximum: Model.SCORE_MAX
              value: root.formFunctionality
              valueText: Model.formatSigned(root.formFunctionality)
              onChosen: function(v) { root.formFunctionality = v }
            }

            // In quick mode the medication value is saved without its switch
            // being on screen, so say what will be saved and why.
            Text {
              visible: !root.formExtended && !!root.medsSuggestion
              width: parent.width
              text: "Medication: " + (root.formMedication ? "taken" : "not taken")
                + " (" + Model.medicationHint(root.medsSuggestion) + ")"
              color: root.medsSuggestion && !root.medsSuggestion.complete ? root.warningColor : root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Button {
              visible: !root.formExtended
              text: "More: sleep, medication, notes"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.formExtended = true
            }

            // ---- extended section --------------------------------------
            Column {
              visible: root.formExtended
              width: parent.width
              height: visible ? implicitHeight : 0
              spacing: Style.space(10)

              ScoreRow {

                theme: root
                width: parent.width
                label: "Sleep"
                hint: ""
                accent: root.contentForeground
                minimum: Model.SLEEP_MIN
                maximum: Model.SLEEP_MAX
                value: root.formSleep
                valueText: root.formSleep + " h"
                onChosen: function(v) { root.formSleep = v }
              }

              SwitchRow {

                theme: root
                width: parent.width
                label: "Medication taken as prescribed"
                checked: root.formMedication
                onToggled: {
                  root.medicationTouched = true
                  root.formMedication = !root.formMedication
                }
              }

              Text {
                visible: !!root.medsSuggestion
                width: parent.width
                text: Model.medicationHint(root.medsSuggestion)
                color: root.medsSuggestion && !root.medsSuggestion.complete ? root.warningColor : root.mutedForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              SwitchRow {

                theme: root
                width: parent.width
                label: "Menstruation"
                checked: root.formMenstrual
                onToggled: root.formMenstrual = !root.formMenstrual
              }

              SwitchRow {

                theme: root
                width: parent.width
                label: "Hypomanic symptoms"
                checked: root.formHypomanic
                onToggled: root.formHypomanic = !root.formHypomanic
              }

              NoteArea {

                theme: root
                id: symptomsArea
                width: parent.width
                label: "Symptoms"
                placeholder: "e.g. racing thoughts, irritability"
                value: root.formSymptoms
                syncToken: root.formToken
                onEdited: function(v) { root.formSymptoms = v }
              }

              NoteArea {

                theme: root
                id: notesArea
                width: parent.width
                label: "Notes"
                placeholder: "Anything else about today"
                value: root.formNotes
                syncToken: root.formToken
                onEdited: function(v) { root.formNotes = v }
              }
            }

            // ---- actions -------------------------------------------------
            Row {
              spacing: Style.space(10)

              Button {
                text: "Save"
                bordered: true
                focusable: true
                enabled: root.writable
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.saveForm()
              }

              Button {
                visible: root.formExists && !root.pendingDelete
                text: "Delete"
                foreground: root.mutedForeground
                fontFamily: root.contentFontFamily
                onClicked: root.pendingDelete = true
              }

              Button {
                visible: root.pendingDelete
                text: "Really delete this day"
                bordered: true
                foreground: Color.urgent
                fontFamily: root.contentFontFamily
                onClicked: root.deleteForm()
              }

              Button {
                visible: root.pendingDelete
                text: "Keep"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.pendingDelete = false
              }
            }

            Text {
              visible: root.statusText !== ""
              width: parent.width
              text: root.statusText
              color: root.statusCritical ? Color.urgent : root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              visible: root.statusCritical && root.formExists
              text: "Show crisis resources"
              bordered: true
              foreground: Color.urgent
              fontFamily: root.contentFontFamily
              onClicked: root.tab = "help"
            }
          }

          // ==== CHART =====================================================
          Column {
            visible: root.tab === "chart"
            width: parent.width
            height: visible ? implicitHeight : 0
            spacing: Style.space(10)

            ButtonGroup {
              options: Model.PERIODS.map(function(d) { return { value: String(d), label: d + " days" } })
              value: String(root.period)
              focusable: false
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              onChanged: function(v) { if (root.hostWidget) root.hostWidget.updateSetting("period", Number(v)) }
            }

            Text {
              visible: root.summary.count === 0
              width: parent.width
              text: "No entries in this period yet."
              color: root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            MoodChart {

              theme: root
              visible: root.summary.count > 0
              width: parent.width
              height: visible ? Style.space(240) : 0
              points: Model.chartPoints(root.entries, root.range.from, root.range.to)
              labels: Model.axisLabels(root.range.from, root.range.to)
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            // Legend
            Row {
              visible: root.summary.count > 0
              height: visible ? implicitHeight : 0
              spacing: Style.space(14)

              Repeater {
                model: [
                  { color: Model.MOOD_COLOR, label: "Mood" },
                  { color: Model.FUNCTIONALITY_COLOR, label: "Functionality" },
                  { color: Model.HYPOMANIA_COLOR, label: "Hypomanic" }
                ]

                Row {
                  required property var modelData
                  spacing: Style.space(5)

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(10)
                    height: Style.space(10)
                    radius: width / 2
                    color: modelData.color
                  }

                  Text {
                    text: modelData.label
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            Text {
              visible: root.summary.count > 0
              width: parent.width
              text: root.summary.count + " of " + root.summary.days + " days recorded"
                + "  ·  ⌀ mood " + Model.formatAverage(root.summary.mood)
                + "  ·  ⌀ functionality " + Model.formatAverage(root.summary.functionality)
                + "  ·  ⌀ sleep " + (root.summary.sleep === null ? "–" : root.summary.sleep.toFixed(1) + " h")
                + (root.summary.hypomanicDays > 0 ? "  ·  " + root.summary.hypomanicDays + " hypomanic" : "")
                + (root.summary.criticalDays > 0 ? "  ·  " + root.summary.criticalDays + " critical" : "")
              color: root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSeparator {
              foreground: root.contentForeground
            }

            // ---- PDF report ----------------------------------------------
            PanelSectionHeader {
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              text: "PDF REPORT"
            }

            Row {
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "From"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              TextField {
                id: exportFromField
                width: Style.space(120)
                foreground: root.contentForeground
                text: root.exportFrom
                placeholderText: "DD.MM.YYYY"
                onTextEdited: root.exportFrom = text
                onAccepted: root.startExport()
                Connections {
                  target: root
                  function onExportTokenChanged() { exportFromField.text = root.exportFrom }
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "to"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              TextField {
                id: exportToField
                width: Style.space(120)
                foreground: root.contentForeground
                text: root.exportTo
                placeholderText: "DD.MM.YYYY"
                onTextEdited: root.exportTo = text
                onAccepted: root.startExport()
                Connections {
                  target: root
                  function onExportTokenChanged() { exportToField.text = root.exportTo }
                }
              }
            }

            Row {
              spacing: Style.space(6)

              Button {
                text: "Chart period"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.setExportRange(root.range.from, root.range.to)
              }

              Button {
                text: "Last month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: {
                  var first = Model.dateFromKey(root.todayKey)
                  first.setDate(1)
                  var lastOfPrev = Model.addDays(Model.keyForDate(first), -1)
                  root.setExportRange(lastOfPrev.slice(0, 8) + "01", lastOfPrev)
                }
              }

              Button {
                text: "All data"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.setExportRange(root.firstEntryKey(), root.todayKey)
              }
            }

            Row {
              spacing: Style.space(10)

              Button {
                text: root.hostWidget && root.hostWidget.exportBusy ? "Creating…" : "Create PDF"
                bordered: true
                focusable: true
                enabled: !!root.hostWidget && !root.hostWidget.exportBusy
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.startExport()
              }

              Button {
                visible: !!root.hostWidget && root.hostWidget.exportPath !== ""
                text: "Open"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.hostWidget.openExport()
              }
            }

            Text {
              readonly property string message: root.exportFormError !== ""
                ? root.exportFormError
                : (root.hostWidget ? (root.hostWidget.exportError !== ""
                  ? root.hostWidget.exportError
                  : (root.hostWidget.exportPath !== ""
                    ? "Saved: " + root.hostWidget.exportPath + " (" + root.hostWidget.exportInfo + ")"
                    : "")) : "")
              readonly property bool failed: root.exportFormError !== ""
                || (!!root.hostWidget && root.hostWidget.exportError !== "")
              visible: message !== ""
              width: parent.width
              text: message
              color: failed ? Color.urgent : root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WrapAnywhere
            }
          }

          // ==== SETTINGS ==================================================
          Column {
            visible: root.tab === "settings"
            width: parent.width
            height: visible ? implicitHeight : 0
            spacing: Style.space(10)

            PanelSectionHeader {
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              text: "DAILY REMINDER"
            }

            SwitchRow {
              theme: root
              width: parent.width
              label: "Remind me when today's entry is missing"
              checked: root.reminderFormEnabled
              onToggled: {
                root.reminderFormEnabled = !root.reminderFormEnabled
                root.applyReminder()
              }
            }

            Row {
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Time"
                color: root.reminderFormEnabled ? root.contentForeground : root.mutedForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              TextField {
                id: reminderTimeField
                width: Style.space(90)
                foreground: root.contentForeground
                text: root.reminderFormTime
                placeholderText: "HH:MM"
                onTextEdited: root.reminderFormTime = text
                onAccepted: root.applyReminder()
                Connections {
                  target: root
                  function onReminderTokenChanged() { reminderTimeField.text = root.reminderFormTime }
                }
              }

              Button {
                text: "Save"
                bordered: true
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.applyReminder()
              }
            }

            Text {
              width: parent.width
              text: "A notification at this time on days without an entry. It is sent once a day; "
                + "after the time has passed the bar icon turns amber until the day is recorded."
              color: root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              visible: text !== ""
              width: parent.width
              text: root.reminderFormError !== "" ? root.reminderFormError : root.reminderFormStatus
              color: root.reminderFormError !== "" ? Color.urgent : root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ==== HELP ======================================================
          Column {
            visible: root.tab === "help"
            width: parent.width
            height: visible ? implicitHeight : 0
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: "If you are in crisis, please contact a crisis helpline. You are not alone."
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              wrapMode: Text.WordWrap
            }

            Dropdown {
              width: parent.width
              label: "Region"
              options: Model.CRISIS_REGIONS
              value: root.region
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onChanged: function(v) { if (root.hostWidget) root.hostWidget.updateSetting("region", v) }
            }

            Repeater {
              model: Model.crisisResources(root.region)

              Rectangle {
                required property var modelData
                width: parent.width
                height: resourceRow.implicitHeight + Style.space(14)
                implicitHeight: height
                radius: Style.cornerRadius
                color: Style.controlFill(false, false, root.contentForeground, Color.accent)

                Row {
                  id: resourceRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  spacing: Style.space(8)

                  Column {
                    width: parent.width - actionRow.width - Style.space(8)
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      text: modelData.name
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Text {
                      visible: modelData.phone !== ""
                      text: modelData.phone
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                    }

                    Text {
                      width: parent.width
                      text: modelData.url
                      color: root.mutedForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  Row {
                    id: actionRow
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(4)

                    PanelActionButton {
                      visible: modelData.phone !== ""
                      iconText: ""
                      tooltipText: "Copy phone number"
                      foreground: root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: root.copyText(modelData.phone)
                    }

                    PanelActionButton {
                      iconText: ""
                      tooltipText: "Open website"
                      foreground: root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: Qt.openUrlExternally(modelData.url)
                    }
                  }
                }
              }
            }

            Text {
              width: parent.width
              text: "Life chart is a tool for self-observation, not a medical device. "
                + "In an emergency call 112 (EU) or your local emergency number."
              color: root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }

  // ---- inline components ------------------------------------------------

  // A labelled integer slider with its current value on the right.
  component ScoreRow: Column {
    id: scoreRow
    required property var theme
    property string label: ""
    property string hint: ""
    property color accent: theme.contentForeground
    property int minimum: 0
    property int maximum: 10
    property int value: 0
    property string valueText: ""
    signal chosen(int value)

    spacing: Style.space(4)

    Item {
      width: parent.width
      height: scoreLabel.implicitHeight
      implicitHeight: height

      Text {
        id: scoreLabel
        anchors.left: parent.left
        text: scoreRow.label
        color: theme.contentForeground
        font.family: theme.contentFontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        anchors.right: parent.right
        text: scoreRow.valueText
        color: scoreRow.accent
        font.family: theme.contentFontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
    }

    Item {
      width: parent.width
      height: Style.space(26)

      PanelSlider {
        anchors.fill: parent
        bar: theme.bar
        minimum: scoreRow.minimum
        maximum: scoreRow.maximum
        step: 1
        integer: true
        tickCount: scoreRow.maximum - scoreRow.minimum + 1
        fillColor: scoreRow.accent
        knobColor: scoreRow.accent
        value: scoreRow.value
        onMoved: function(v) { scoreRow.chosen(Math.round(v)) }
        onReleased: function(v) { scoreRow.chosen(Math.round(v)) }
      }
    }

    Text {
      visible: scoreRow.hint !== ""
      width: parent.width
      text: scoreRow.hint
      color: theme.mutedForeground
      font.family: theme.contentFontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // A label with a switch on the trailing edge.
  component SwitchRow: Item {
    id: switchRow
    required property var theme
    property string label: ""
    property bool checked: false
    signal toggled()

    height: Math.max(switchLabel.implicitHeight, toggle.implicitHeight)
    implicitHeight: height

    Text {
      id: switchLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: switchRow.label
      color: theme.contentForeground
      font.family: theme.contentFontFamily
      font.pixelSize: Style.font.body
    }

    ToggleSwitch {
      id: toggle
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: switchRow.checked
      foreground: theme.contentForeground
      onToggled: switchRow.toggled()
    }
  }

  // A labelled multi-line field. The incoming value fills the box, typing
  // takes over, and `syncToken` is the explicit reload (another day loaded).
  component NoteArea: Column {
    id: noteArea
    required property var theme
    property string label: ""
    property string placeholder: ""
    property string value: ""
    property int syncToken: 0
    readonly property bool inputFocused: area.activeFocus
    signal edited(string value)

    spacing: Style.space(4)

    Text {
      text: noteArea.label
      color: theme.contentForeground
      font.family: theme.contentFontFamily
      font.pixelSize: Style.font.body
    }

    Rectangle {
      width: parent.width
      height: Style.space(64)
      radius: Style.cornerRadius
      color: "transparent"
      border.width: Style.normalBorderWidth
      border.color: area.activeFocus ? Color.accent : Qt.darker(theme.contentForeground, 2.2)

      TextArea {
        id: area
        anchors.fill: parent
        anchors.margins: Style.space(4)
        text: noteArea.value
        placeholderText: noteArea.placeholder
        placeholderTextColor: theme.mutedForeground
        wrapMode: TextArea.Wrap
        selectByMouse: true
        color: theme.contentForeground
        font.family: theme.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        background: null
        onTextChanged: if (activeFocus) noteArea.edited(text)
      }
    }

    onSyncTokenChanged: area.text = noteArea.value
  }

  // Mood and functionality over the chosen period, drawn like the app's
  // MoodChartDrawable: grid per score, zero line, hypomania as a band with a
  // dot on top, lines joining neighbouring entries.
  component MoodChart: Canvas {
    id: chart
    required property var theme
    property var points: []
    property var labels: []
    property color foreground: theme.contentForeground
    property string fontFamily: theme.contentFontFamily
    property color hypoColor: Model.HYPOMANIA_COLOR

    readonly property real marginLeft: Style.space(28)
    readonly property real marginRight: Style.space(10)
    readonly property real marginTop: Style.space(12)
    readonly property real marginBottom: Style.space(22)

    onPointsChanged: requestPaint()
    onLabelsChanged: requestPaint()
    onForegroundChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    function px(p) { return marginLeft + p.x * (width - marginLeft - marginRight) }
    function py(score) { return marginTop + Model.scoreY(score) * (height - marginTop - marginBottom) }
    function rgba(c, a) { return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")" }

    function drawSeries(ctx, key, color) {
      ctx.strokeStyle = color
      ctx.fillStyle = color
      ctx.lineWidth = 2
      ctx.beginPath()
      for (var i = 0; i < points.length; i++) {
        var x = px(points[i]), y = py(points[i][key])
        if (i === 0) ctx.moveTo(x, y)
        else ctx.lineTo(x, y)
      }
      ctx.stroke()
      for (var j = 0; j < points.length; j++) {
        ctx.beginPath()
        ctx.arc(px(points[j]), py(points[j][key]), 3, 0, Math.PI * 2)
        ctx.fill()
      }
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var right = width - marginRight
      var bottom = height - marginBottom
      var fontSize = Math.max(9, Math.round(Style.font.caption * 0.9))
      ctx.font = fontSize + "px \"" + fontFamily + "\""

      // Grid, one line per score; the zero line stronger.
      for (var s = Model.SCORE_MIN; s <= Model.SCORE_MAX; s++) {
        ctx.strokeStyle = rgba(foreground, s === 0 ? 0.45 : 0.12)
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(marginLeft, py(s))
        ctx.lineTo(right, py(s))
        ctx.stroke()
      }

      // Y labels every second score.
      ctx.fillStyle = rgba(foreground, 0.6)
      ctx.textAlign = "right"
      ctx.textBaseline = "middle"
      for (var y = Model.SCORE_MIN; y <= Model.SCORE_MAX; y += 1) {
        if ((y - Model.SCORE_MIN) % 2 !== 0) continue
        ctx.fillText(Model.formatSigned(y), marginLeft - 6, py(y))
      }

      // X labels.
      ctx.textAlign = "center"
      ctx.textBaseline = "top"
      // Clamped so the first and last label are not cut off at the edges.
      for (var l = 0; l < labels.length; l++) {
        var half = ctx.measureText(labels[l].label).width / 2
        var lx = Math.max(half, Math.min(width - half, px(labels[l])))
        ctx.fillText(labels[l].label, lx, bottom + 6)
      }

      // Hypomania bands and markers, behind the lines.
      var hypo = chart.hypoColor
      for (var h = 0; h < points.length; h++) {
        if (!points[h].isHypomanic) continue
        var hx = px(points[h])
        ctx.fillStyle = rgba(hypo, 0.18)
        ctx.fillRect(hx - 3, marginTop, 6, bottom - marginTop)
        ctx.fillStyle = Model.HYPOMANIA_COLOR
        ctx.beginPath()
        ctx.arc(hx, marginTop, 5, 0, Math.PI * 2)
        ctx.fill()
      }

      drawSeries(ctx, "functionality", Model.FUNCTIONALITY_COLOR)
      drawSeries(ctx, "mood", Model.MOOD_COLOR)
    }
  }

  // ---- io -----------------------------------------------------------------
  // Kept at the Panel level: KeyboardPanel only accepts visual children.
  Process {
    id: copyProc
  }
}
