import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "futo-notes"
  ipcTarget: "futo-notes"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false
  property var hostWidget: null

  readonly property var barIdentity: hostWidget || root

  // ---------------------------------------------------------------- paths
  readonly property string home: Quickshell.env("HOME")
  readonly property string settingsPath: home + "/.local/state/omarchy/settings/futo-notes.json"
  readonly property string scriptPath: home + "/.config/omarchy/plugins/futo-notes/futo-notes-sync.py"

  // ---------------------------------------------------------------- state
  property var settings: ({})
  property var notes: []
  property var selectedNote: null
  property bool loading: false
  property bool savingPassword: false
  property string errorMessage: ""
  property string statusMessage: ""
  property bool showSettings: false

  // Settings form buffers
  property string formUrl: ""
  property string formPassword: ""

  readonly property bool configured: !!(settings.serverUrl && String(settings.serverUrl).length > 0)

  // ---------------------------------------------------------------- lifecycle
  Component.onCompleted: {
    ensureDir.running = true
    loadSettings()
    if (!configured) showSettings = true
  }

  function loadSettings() {
    var s = ({})
    try { s = JSON.parse(settingsFile.text() || "{}") } catch (e) { s = ({}) }
    settings = s
    formUrl = s.serverUrl || ""
    if (!configured) showSettings = true
  }

  function persistSettings() {
    settingsFile.setText(JSON.stringify(root.settings, null, 2))
    if (hostWidget) hostWidget.settings = root.settings
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    if (configured && notes.length === 0 && !loading) refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    if (configured && notes.length === 0 && !loading) refresh()
    Qt.callLater(function() { if (root.opened) setCenterHoverRevealSuppressed(true) })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() { if (root.opened) root.close(); else root.openFromHotkey() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---------------------------------------------------------------- sync
  property string pendingPayload: ""

  function runSync(payload) {
    pendingPayload = JSON.stringify(payload) + "\n"
    loading = true
    syncProc.running = true
  }

  function refresh() {
    if (!configured) { showSettings = true; return }
    if (loading) return
    statusMessage = ""
    errorMessage = ""
    runSync({ serverUrl: root.settings.serverUrl })
  }

  function handleSyncResult(raw) {
    loading = false
    savingPassword = false
    var res = ({})
    try { res = JSON.parse(String(raw || "").trim() || "{}") } catch (e) {
      errorMessage = "Unexpected response from the sync helper."
      return
    }
    if (res.ok) {
      notes = res.notes || []
      selectedNote = null
      errorMessage = ""
      settings = Object.assign({}, settings, {
        lastCount: notes.length,
        lastSync: Qt.formatTime(new Date(), "HH:mm"),
        lastError: ""
      })
      persistSettings()
    } else {
      errorMessage = res.error || "Sync failed."
      settings = Object.assign({}, settings, { lastError: errorMessage })
      persistSettings()
    }
  }

  // ---------------------------------------------------------------- settings actions
  function connectAndSync() {
    var url = String(formUrl || "").trim().replace(/\/+$/, "")
    if (!url) { errorMessage = "Enter your sync server URL."; return }
    if (!formPassword) { errorMessage = "Enter your sync password."; return }

    errorMessage = ""
    statusMessage = ""
    savingPassword = true
    settings = Object.assign({}, settings, { serverUrl: url })
    persistSettings()
    runSync({ serverUrl: url, password: formPassword, savePassword: true })
  }

  property string testPayload: ""

  function testConnection() {
    var url = String(formUrl || "").trim().replace(/\/+$/, "")
    if (!url) { errorMessage = "Enter your sync server URL."; return }
    if (!formPassword) { errorMessage = "Enter your sync password."; return }

    errorMessage = ""
    statusMessage = "Testing…"
    loading = true
    testPayload = JSON.stringify({ serverUrl: url, password: formPassword }) + "\n"
    testProc.running = true
  }

  function logout() {
    settings = ({})
    notes = []
    selectedNote = null
    formUrl = ""
    formPassword = ""
    errorMessage = ""
    statusMessage = ""
    persistSettings()
    showSettings = true
    deleteProc.running = true
  }

  // ---------------------------------------------------------------- processes
  Process {
    id: ensureDir
    command: ["mkdir", "-p", root.home + "/.local/state/omarchy/settings"]
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    blockLoading: true
    printErrors: false
  }

  // Main sync run. The helper reads exactly one line, so stdin never has to
  // be closed (Quickshell's Process cannot close it).
  Process {
    id: syncProc
    command: ["python3", root.scriptPath]
    stdinEnabled: true
    onStarted: write(root.pendingPayload)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleSyncResult(text())
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) {
        root.loading = false
        if (root.errorMessage === "")
          root.errorMessage = "Sync helper exited with code " + code + "."
      }
    }
  }

  // Connection test (does not save anything).
  Process {
    id: testProc
    command: ["python3", root.scriptPath]
    stdinEnabled: true
    onStarted: write(root.testPayload)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        var res = ({})
        try { res = JSON.parse(String(text || "").trim() || "{}") } catch (e) {}
        if (res.ok)
          root.statusMessage = "Connected — found " + (res.notes ? res.notes.length : 0) + " note(s)."
        else
          root.errorMessage = res.error || "Connection test failed."
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) { root.loading = false }
  }

  // Remove the stored password on logout (clear reads no stdin).
  Process {
    id: deleteProc
    command: ["secret-tool", "clear", "service", "futo-notes"]
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      implicitHeight: col.implicitHeight
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: col
          width: scroll.width
          spacing: Style.space(16)

          // ---------------- Header ----------------
          Row {
            width: parent.width
            spacing: Style.space(12)

            Text {
              text: "󰠮"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.displayLarge
            }
            Column {
              spacing: Style.space(2)
              Text {
                text: "Futo Notes"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                text: root.configured
                  ? String(root.settings.serverUrl).replace(/^https?:\/\//, "")
                  : "Not configured"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          // ---------------- Settings form ----------------
          Column {
            visible: root.showSettings || !root.configured
            width: parent.width
            spacing: Style.space(12)

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.bar.foreground
              opacity: 0.12
            }

            Text {
              text: root.configured ? "Settings" : "Set up Futo Notes sync"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: "Sync server URL"
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              TextField {
                width: parent.width
                text: root.formUrl
                placeholderText: "https://notes.example.com"
                foreground: root.bar.foreground
                onTextChanged: root.formUrl = text
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: "Sync password"
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              TextField {
                width: parent.width
                text: root.formPassword
                placeholderText: "Password that decrypts your notes"
                foreground: root.bar.foreground
                password: true
                onTextChanged: root.formPassword = text
              }
              Text {
                text: "Stored in your system keyring (secret-tool), never in a file."
                color: Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Text {
              visible: root.errorMessage !== ""
              text: root.errorMessage
              color: "#f38ba8"
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
            Text {
              visible: root.statusMessage !== ""
              text: root.statusMessage
              color: "#a6e3a1"
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.space(8)
              Button {
                text: root.loading ? "Working…" : "Connect & sync"
                enabled: !root.loading && !root.savingPassword
                foreground: root.bar.background
                background: Commons.Color.accent
                onClicked: root.connectAndSync()
              }
              Button {
                text: "Test connection"
                enabled: !root.loading
                foreground: root.bar.foreground
                background: "transparent"
                onClicked: root.testConnection()
              }
              Button {
                visible: root.configured
                text: "Log out"
                enabled: !root.loading
                foreground: root.bar.foreground
                background: "transparent"
                onClicked: root.logout()
              }
            }
          }

          // ---------------- Notes list ----------------
          Column {
            visible: root.configured && !root.showSettings
            width: parent.width
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                text: root.notes.length + " note" + (root.notes.length === 1 ? "" : "s")
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Button {
                text: root.loading ? "Syncing…" : "Refresh"
                enabled: !root.loading
                foreground: root.bar.foreground
                background: "transparent"
                fontSize: Style.font.bodySmall
                onClicked: root.refresh()
              }
              Button {
                text: "Settings"
                enabled: !root.loading
                foreground: root.bar.foreground
                background: "transparent"
                fontSize: Style.font.bodySmall
                onClicked: root.showSettings = true
              }
            }

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.bar.foreground
              opacity: 0.12
            }

            Column {
              width: parent.width
              spacing: 0
              Repeater {
                model: root.notes
                delegate: NoteRow {
                  required property var modelData
                  width: parent.width
                  title: modelData.title || ""
                  path: modelData.path || ""
                  isImage: modelData.isImage === true
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  selected: root.selectedNote && root.selectedNote.id === modelData.id
                  onActivated: root.selectedNote = (root.selectedNote && root.selectedNote.id === modelData.id) ? null : modelData
                }
              }
              Item {
                visible: root.notes.length === 0 && !root.loading && root.errorMessage === ""
                width: parent.width
                height: Style.space(72)
                Text {
                  anchors.centerIn: parent
                  text: "No notes yet — create some in the Futo Notes app."
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }

            Text {
              visible: root.errorMessage !== ""
              text: root.errorMessage
              color: "#f38ba8"
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // ---------------- Note detail ----------------
          Column {
            visible: root.selectedNote !== null
            width: parent.width
            spacing: Style.space(12)

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.bar.foreground
              opacity: 0.12
            }

            Row {
              spacing: Style.space(8)
              Button {
                text: "Back"
                foreground: root.bar.foreground
                background: "transparent"
                onClicked: root.selectedNote = null
              }
              Text {
                text: root.selectedNote ? root.selectedNote.title : ""
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              visible: root.selectedNote && root.selectedNote.path
              text: root.selectedNote ? root.selectedNote.path : ""
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Flickable {
              width: parent.width
              height: Math.min(detailText.implicitHeight + Style.space(20), Style.space(420))
              clip: true
              contentWidth: width
              contentHeight: detailText.implicitHeight + Style.space(20)
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height

              Text {
                id: detailText
                width: parent.width - Style.space(8)
                text: {
                  if (!root.selectedNote) return ""
                  if (root.selectedNote.isImage) return "🖼 Image note (preview not supported here)."
                  return root.selectedNote.content || ""
                }
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
                padding: Style.space(8)
              }
            }
          }
        }
      }
    }
  }
}
