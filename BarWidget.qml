import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Life chart bar widget: a chart icon whose color reflects today's entry,
// plus the host for the panel. Owns the data file and the optional daily reminder;
// the panel reads state and mutates through the functions below.
BarWidget {
  id: root
  moduleName: "saigkill.lifechart"

  // State must NOT live inside the plugin directory: Quickshell watches that
  // folder and reloads the plugin on any write, which drops an open panel.
  readonly property string dataDir: Quickshell.env("HOME") + "/.local/state/omarchy-lifechart"
  readonly property string dataFile: dataDir + "/data.json"

  // ---- settings (shell.json entry) -----------------------------------
  // Daily reminder: optional (off by default), at a free "HH:mm" time. Both
  // are set from the panel's Settings tab or by hand in shell.json.
  readonly property bool reminderEnabled: setting("reminderEnabled", false) === true
  readonly property string reminderTime: Model.normalizeReminderTime(setting("reminderTime", ""))
    || Model.DEFAULT_REMINDER_TIME
  readonly property var reminderMinutes: Model.reminderMinutesFor(reminderEnabled, reminderTime)
  readonly property string region: Model.normalizeRegion(setting("region", "DE"))
  // reportLanguage: "de" or "en"; follows LANG when unset.
  readonly property string reportLanguage: Model.reportLanguage(setting("reportLanguage", ""), Quickshell.env("LANG"))
  readonly property int defaultPeriod: Model.PERIODS.indexOf(Number(setting("period", 30))) >= 0
    ? Number(setting("period", 30)) : 30

  // ---- state ----------------------------------------------------------
  property date now: new Date()
  property var entries: []
  // True once the file was read (or found missing). Nothing is written
  // before that, or a save could replace the history with an empty list.
  property bool loaded: false
  // Set when the file exists but cannot be parsed. Writes stay blocked until
  // the file is fixed, so a damaged file is never overwritten.
  property string loadError: ""
  property string saveError: ""

  // The medication tracker's data (saigkill.meds), or null when that plugin
  // is not used. READ ONLY: this plugin never writes the meds file.
  readonly property string medsFile: Quickshell.env("HOME") + "/.local/state/omarchy-meds/data.json"
  property var medsData: null

  // Day key of the last reminder the shell actually delivered.
  property string reminderDeliveredDay: ""
  property bool reminderInflight: false

  readonly property var view: Model.statusView(entries, now, reminderMinutes)
  readonly property bool writable: loaded && loadError === ""

  readonly property color warningColor: "#c9a227"
  readonly property color stateColor: loadError !== ""
    ? Color.urgent
    : (view.critical ? Color.urgent
      : (view.missing ? warningColor : (bar ? bar.barForeground : Color.foreground)))

  readonly property string tooltipText: loadError !== ""
    ? "Life chart: data file unreadable\n" + loadError
    : Model.tooltipText(view)

  // ---- mutation API for the panel ----------------------------------------
  // Returns { ok, critical } so the panel can show the crisis hint right
  // after saving, as the app does.
  function saveEntry(fields) {
    if (!root.writable) return { ok: false, critical: false }
    var next = Model.upsertEntry(root.entries, fields)
    if (!next) return { ok: false, critical: false }
    root.entries = next
    root.writeData()
    root.refreshNow()
    var saved = Model.findEntry(next, String(fields.date))
    return { ok: true, critical: Model.isCritical(saved) }
  }

  function deleteEntry(dateKey) {
    if (!root.writable) return false
    root.entries = Model.removeEntry(root.entries, dateKey)
    root.writeData()
    root.refreshNow()
    return true
  }

  // ---- PDF export ---------------------------------------------------------
  // lifechart_report.py reads the data file itself; only the dates travel on
  // the command line. The PDF lands in ~/Documents/LifeChart/ (mode 0600).
  readonly property string reportScript: Qt.resolvedUrl("lifechart_report.py").toString().replace("file://", "")
  property bool exportBusy: false
  property string exportPath: ""
  property string exportError: ""
  property string exportInfo: ""

  function exportReport(fromKey, toKey) {
    if (root.exportBusy) return
    root.exportBusy = true
    root.exportPath = ""
    root.exportError = ""
    root.exportInfo = ""
    reportProc.command = Model.reportCommand(root.reportScript, fromKey, toKey, root.reportLanguage)
    reportProc.running = true
  }

  // Returns "" on success or the reason the time was rejected.
  function setReminder(enabled, timeText) {
    var time = Model.normalizeReminderTime(timeText)
    if (!time) return "Use a time like 20:00 (HH:MM, 00:00–23:59)."
    // A reminder moved to another time counts as new for today: if the new
    // time has passed and today is still missing, it fires on the next tick.
    if (time !== root.reminderTime) root.reminderDeliveredDay = ""
    root.updateSettings({ reminderEnabled: enabled === true, reminderTime: time })
    return ""
  }

  function openExport() {
    if (root.exportPath !== "") Qt.openUrlExternally("file://" + root.exportPath)
  }

  // Panel choices (crisis region, chart period) persist in this widget's
  // shell.json entry, the same way the clock stores a cycled format.
  function updateSetting(name, value) {
    var patch = {}
    patch[name] = value
    root.updateSettings(patch)
  }

  // Several keys in one shell.json write.
  function updateSettings(patch) {
    var entry = {}
    var current = root.settings || {}
    for (var key in current) entry[key] = current[key]
    for (var name in patch) entry[name] = patch[name]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function writeData() {
    root.saveError = ""
    if (!dirProc.done) {
      // First write ever: the state directory may not exist yet, and
      // FileView does not create parents.
      dirProc.pendingWrite = true
      dirProc.running = true
      return
    }
    dataView.setText(Model.encode(root.entries))
  }

  function applyText(text) {
    var result = Model.decode(text)
    if (!result.ok) {
      root.loadError = "Fix or move " + root.dataFile + "; nothing is written until then."
      console.warn("saigkill.lifechart: " + root.dataFile + " is not a valid life chart file")
      root.loaded = true
      return
    }
    root.loadError = ""
    root.entries = result.data.entries
    root.loaded = true
    root.refreshNow()
  }

  // ---- periodic checks --------------------------------------------------
  function refreshNow() {
    root.now = new Date()
  }

  function checkStatus() {
    root.refreshNow()
    if (!root.loaded || root.loadError !== "" || root.reminderInflight) return
    if (!Model.reminderDue(root.entries, root.now, root.reminderMinutes, root.reminderDeliveredDay)) return
    root.reminderInflight = true
    notifyProc.day = root.view.today
    notifyProc.command = ["omarchy-notification-send", "-g", "", "-u", "normal",
      "-r", String(root.replaceIdFor(root.view.today)),
      "Life chart", "How was your day? Today's entry is still missing."]
    notifyProc.running = true
  }

  // Each bar runs its own widget, so the reminder is sent once per bar. A
  // replace id derived from the day makes the shell update one toast in
  // place instead of stacking one per monitor.
  function replaceIdFor(dayKey) {
    var hash = 0
    var text = "lifechart|" + dayKey
    for (var i = 0; i < text.length; i++) hash = (hash * 31 + text.charCodeAt(i)) % 1000000007
    return 1000 + (hash % 900000)
  }

  // ---- panel lifecycle (shape contract for shell summon/hide/toggle) ---
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function openTab(tab) { if (panelLoader.item) panelLoader.item.openTab(tab) }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    // Deliberately not triggeredOnStart: at t=0 the shell is still bringing
    // up its own notification service, so a send there is rejected. A failed
    // send is retried by the next tick regardless.
    triggeredOnStart: false
    onTriggered: root.checkStatus()
  }

  IpcHandler {
    target: "saigkill.lifechart"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.checkStatus() }
    // "today", "chart", "help" or "settings" — e.g. a keybinding to the chart.
    function openTab(tab: string): void { root.openTab(tab) }
    // Dates as DD.MM.YYYY or YYYY-MM-DD. Answers with the error or "started".
    function exportPdf(from: string, to: string): string {
      var range = Model.exportRange(from, to)
      if (!range.ok) return range.error
      root.exportReport(range.from, range.to)
      return "started"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    active: root.view.critical || root.loadError !== ""
    enabled: true
    foreground: root.stateColor
    tooltipText: root.tooltipText

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.toggle()
    }
  }

  // ---- io -----------------------------------------------------------
  // Watched, so every bar's widget (one per monitor) sees an entry saved
  // from any of them. Writes are atomic: a crash mid-write leaves the old
  // file, never half a file.
  FileView {
    id: dataView
    path: root.dataFile
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyText(text())
    onLoadFailed: function(error) {
      if (error === FileViewError.FileNotFound) {
        root.applyText("")
      } else {
        root.loadError = "Cannot read " + root.dataFile + " (error " + error + ")."
        root.loaded = true
      }
    }
    onFileChanged: reload()
    // QSaveFile creates a new file with 0666 & ~umask and only keeps the mode
    // of an existing one, so a first save is repaired here (see permProc).
    onSaved: if (!permProc.running) permProc.running = true
    onSaveFailed: function(error) {
      root.saveError = "Saving failed (error " + error + ")."
      console.warn("saigkill.lifechart: failed to save " + root.dataFile + ": " + error)
    }
  }

  // Watched so a dose logged in the meds panel updates the suggestion while
  // the life chart panel is open. No setText() here, ever.
  FileView {
    id: medsView
    path: root.medsFile
    watchChanges: true
    printErrors: false
    onLoaded: {
      var parsed = null
      try { parsed = JSON.parse(text()) } catch (error) { parsed = null }
      root.medsData = parsed && typeof parsed === "object" ? parsed : null
    }
    onLoadFailed: root.medsData = null
    onFileChanged: reload()
  }

  // This is a mental health record, so the state directory is private (0700)
  // and so is the history file (0600). Runs at startup to repair an existing
  // world-readable install, and before the first write to create the directory.
  // An existing file is only chmodded, never created or touched: an empty
  // data.json would be read back as "no entries".
  Process {
    id: dirProc
    property bool done: false
    property bool pendingWrite: false
    running: true
    command: ["sh", "-c",
      'umask 077 && mkdir -p "$1" && chmod 700 "$1" && { [ ! -e "$2" ] || chmod 600 "$2"; }',
      "sh", root.dataDir, root.dataFile]
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.saveError = "Cannot create " + root.dataDir + "."
        return
      }
      done = true
      if (pendingWrite) {
        pendingWrite = false
        root.writeData()
      }
    }
  }

  Process {
    id: permProc
    command: ["chmod", "600", root.dataFile]
  }

  Process {
    id: reportProc
    stdout: StdioCollector {
      id: reportOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: reportErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.exportBusy = false
      var result = exitCode === 0 ? Model.parseReportResult(reportOut.text) : null
      if (!result) {
        var message = String(reportErr.text || "").replace(/^\s+|\s+$/g, "")
        root.exportError = message !== "" ? message : "The report could not be created (exit " + exitCode + ")."
        console.warn("saigkill.lifechart: report failed: " + root.exportError)
        return
      }
      root.exportPath = result.path
      root.exportInfo = result.entries + (result.entries === 1 ? " entry, " : " entries, ")
        + result.pages + (result.pages === 1 ? " page" : " pages")
    }
  }

  Process {
    id: notifyProc
    property string day: ""
    onExited: function(exitCode) {
      root.reminderInflight = false
      // Only a delivered reminder counts; anything else is retried on the
      // next tick.
      if (exitCode === 0) root.reminderDeliveredDay = day
      else console.warn("saigkill.lifechart: reminder not delivered (exit " + exitCode + "), retrying")
    }
  }
}
