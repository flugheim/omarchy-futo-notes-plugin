import QtQuick
import QtQuick.Controls
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
  property bool loading: false
  property bool savingPassword: false
  property bool editorSaving: false
  property string errorMessage: ""
  property string statusMessage: ""
  property bool showSettings: false

  // Editor (popup) state
  property bool editorOpen: false
  property var editingNote: null   // null = new note
  property string editorPath: ""
  property string editorContent: ""
  property string editorError: ""

  // Detail view state
  property var selectedNote: null
  property var contentBlocks: []

  onSelectedNoteChanged: {
    if (root.selectedNote) {
      root.loadContentBlocks()
    } else {
      root.contentBlocks = []
    }
  }

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
    
    // Try to load password from keyring if server URL is configured
    if (configured && formUrl && formUrl.length > 0) {
      // We need to call the sync helper to lookup password from keyring
      // but we need to wait for the component to be fully initialized
      Qt.callLater(function() {
        // Use the same process as sync but without triggering a full sync
        testPayload = JSON.stringify({ serverUrl: formUrl }) + "\n"
        testProc.running = true
      })
    }
    
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

  // ---------------------------------------------------------------- editor actions
  function newNote() {
    editingNote = null
    editorPath = "Untitled.md"
    editorContent = ""
    editorError = ""
    editorOpen = true
  }

  function editNote(note) {
    editingNote = note
    editorPath = note.path || ""
    editorContent = note.content || ""
    editorError = ""
    editorOpen = true
  }

  function closeEditor() {
    editorOpen = false
    editingNote = null
    editorPath = ""
    editorContent = ""
    editorError = ""
  }

  function saveNote() {
    var path = String(editorPath || "").trim()
    if (!path) { editorError = "Gi notatet et navn (f.eks. Notat.md)"; return }
    if (!path.toLowerCase().endsWith(".md")) path += ".md"

    editorError = ""
    editorSaving = true

    if (editingNote) {
      // update existing — server expects next version number
      runSync({
        action: "update",
        id: editingNote.id,
        version: Number(editingNote.version || 0) + 1,
        path: path,
        content: editorContent,
      })
    } else {
      // create new
      runSync({
        action: "create",
        path: path,
        content: editorContent,
      })
    }
  }

  function deleteNote() {
    if (!editingNote) return
    editorError = ""
    editorSaving = true
    runSync({
      action: "delete",
      id: editingNote.id,
      version: Number(editingNote.version || 0),
    })
  }

  // ---------------------------------------------------------------- content blocks (checkbox support)

  function parseContentBlocks(content) {
    var TASK_RE = /^(\s*)- \[([ x])\] (.*)$/
    var blocks = []
    var lines = String(content || "").split("\n")
    var currentText = ""
    var currentTasks = null

    function flushText() {
      if (currentText !== "") {
        blocks.push({ type: "text", text: currentText })
        currentText = ""
      }
    }
    function flushTasks() {
      if (currentTasks && currentTasks.items.length > 0) {
        blocks.push(currentTasks)
      }
      currentTasks = null
    }

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var m = line.match(TASK_RE)
      if (m) {
        flushText()
        if (!currentTasks) currentTasks = { type: "tasks", items: [] }
        currentTasks.items.push({
          checked: m[2] === "x",
          text: m[3],
          indent: m[1],
        })
      } else {
        flushTasks()
        currentText += line + "\n"
      }
    }
    flushText()
    flushTasks()
    return blocks
  }

  function serializeBlocks(blocks) {
    var out = ""
    for (var i = 0; i < blocks.length; i++) {
      var b = blocks[i]
      if (b.type === "text") {
        out += b.text
        if (!b.text.endsWith("\n")) out += "\n"
      } else if (b.type === "tasks") {
        for (var j = 0; j < b.items.length; j++) {
          var it = b.items[j]
          var marker = it.checked ? "[x]" : "[ ]"
          out += it.indent + "- " + marker + " " + it.text + "\n"
        }
      }
    }
    return out
  }

  function loadContentBlocks() {
    if (!root.selectedNote) { root.contentBlocks = []; return }
    root.contentBlocks = parseContentBlocks(root.selectedNote.content || "")
  }

  function toggleTask(blockIdx, itemIdx) {
    if (!root.contentBlocks || blockIdx < 0 || blockIdx >= root.contentBlocks.length) return
    var b = root.contentBlocks[blockIdx]
    if (b.type !== "tasks" || itemIdx < 0 || itemIdx >= b.items.length) return
    var it = b.items[itemIdx]
    it.checked = !it.checked
    var newContent = serializeBlocks(root.contentBlocks)
    root.selectedNote.content = newContent
    // Auto-save after a short delay so rapid toggles batch into one call
    if (root._saveTimer) root._saveTimer.stop()
    root._saveTimer = Qt.callLater(function() { root.saveContentBlocks() })
  }

  function saveContentBlocks() {
    if (!root.selectedNote) return
    root.editorSaving = true
    root._skipRefresh = true
    runSync({
      action: "update",
      id: root.selectedNote.id,
      version: Number(root.selectedNote.version || 0) + 1,
      path: root.selectedNote.path,
      content: root.selectedNote.content,
    })
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
    editorSaving = false
    var res = ({})
    try { res = JSON.parse(String(raw || "").trim() || "{}") } catch (e) {
      errorMessage = "Unexpected response from the sync helper."
      return
    }
    if (res.ok) {
      if (res.notes) {
        // full sync (read)
        notes = res.notes || []
        editorOpen = false
        editingNote = null
        selectedNote = null
        errorMessage = ""
        settings = Object.assign({}, settings, {
          lastCount: notes.length,
          lastSync: Qt.formatTime(new Date(), "HH:mm"),
          lastError: ""
        })
        persistSettings()
      } else if (res.object) {
        // create / update succeeded
        editorOpen = false
        editingNote = null
        editorPath = ""
        editorContent = ""
        editorError = ""
        errorMessage = ""
        statusMessage = "Lagret."
        if (!root._skipRefresh) {
          selectedNote = null
          refresh()
        }
        root._skipRefresh = false
      } else {
        // delete succeeded
        editorOpen = false
        editingNote = null
        selectedNote = null
        editorPath = ""
        editorContent = ""
        editorError = ""
        errorMessage = ""
        statusMessage = "Slettet."
        refresh()
      }
    } else {
      if (editorOpen) {
        editorError = res.error || "Lagring mislyktes."
        editorSaving = false
      } else {
        errorMessage = res.error || "Sync feilet."
        settings = Object.assign({}, settings, { lastError: errorMessage })
        persistSettings()
      }
    }
  }

  // ---------------------------------------------------------------- settings actions
  function connectAndSync() {
    var url = String(formUrl || "").trim().replace(/\/+$/, "")
    if (!url) { errorMessage = "Oppgi synk-server-URL."; return }
    if (!formPassword) { errorMessage = "Oppgi synk-passordet."; return }

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
    if (!url) { errorMessage = "Oppgi synk-server-URL."; return }
    if (!formPassword) { errorMessage = "Oppgi synk-passordet."; return }

    errorMessage = ""
    statusMessage = "Tester…"
    loading = true
    testPayload = JSON.stringify({ serverUrl: url, password: formPassword }) + "\n"
    testProc.running = true
  }

  function logout() {
    settings = ({})
    notes = []
    editorOpen = false
    editingNote = null
    editorPath = ""
    editorContent = ""
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

  // Main sync run (read or write). The helper reads exactly one line, so stdin
  // never has to be closed (Quickshell's Process cannot close it).
  Process {
    id: syncProc
    command: ["python3", root.scriptPath]
    stdinEnabled: true
    onStarted: write(root.pendingPayload)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleSyncResult(text)
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) {
        root.loading = false
        root.editorSaving = false
        if (root.errorMessage === "" && root.editorError === "")
          root.errorMessage = "Synk-hjelperen avslutet med kode " + code + "."
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
        
        // Check if we have a successful result (which indicates password exists in keyring)
        if (res.ok && formPassword === "" && !(res.error && res.error.includes("No password saved"))) {
          formPassword = "[lagret i nøkkelringen]"
        }
        
        if (res.ok)
          root.statusMessage = "Koblet — funnet " + (res.notes ? res.notes.length : 0) + " notat(er)."
        else
          root.errorMessage = res.error || "Koblingstest feilet."
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) { root.loading = false }
  }

  // Remove the stored password on logout.
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
    contentHeight: Style.space(500)

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
                  : "Ikke konfigurert"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          // ---------------- Settings form ----------------
          Column {
            visible: root.showSettings || (!root.configured && !root.selectedNote)
            width: parent.width
            spacing: Style.space(12)

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.bar.foreground
              opacity: 0.12
            }

            Text {
              text: root.configured ? "Innstillinger" : "Sett opp Futo Notes-synk"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: "Synk-server-URL"
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
                text: "Synk-passord"
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              TextField {
                width: parent.width
                text: root.formPassword
                placeholderText: "Passordet som dekrypterer notatene dine"
                foreground: root.bar.foreground
                password: true
                onTextChanged: root.formPassword = text
              }
              Text {
                text: "Lagres i systemnøkkelringen (secret-tool), aldri i en fil."
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
                text: root.loading ? "Arbeider…" : "Koble til & synk"
                enabled: !root.loading && !root.savingPassword
                foreground: root.bar.background
                background: Commons.Color.accent
                onClicked: root.connectAndSync()
              }
              Button {
                text: "Test tilkobling"
                enabled: !root.loading
                foreground: root.bar.foreground
                background: "transparent"
                onClicked: root.testConnection()
              }
              Button {
                visible: root.configured
                text: "Logg ut"
                enabled: !root.loading
                foreground: root.bar.foreground
                background: "transparent"
                onClicked: root.logout()
              }
            }
          }

          // ---------------- Editor popup ----------------
          Column {
            visible: root.editorOpen
            width: parent.width
            spacing: Style.space(12)

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.bar.foreground
              opacity: 0.12
            }

            Text {
              text: root.editingNote ? "Rediger notat" : "Ny note"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: "Sti (navn på filen)"
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              TextField {
                width: parent.width
                text: root.editorPath
                placeholderText: "f.eks. Notater/Mitt notat.md"
                foreground: root.bar.foreground
                onTextChanged: root.editorPath = text
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: "Innhold"
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              TextArea {
                id: editorTextArea
                width: parent.width
                height: Style.space(260)
                text: root.editorContent
                color: root.bar.foreground
                onTextChanged: root.editorContent = text
                wrapMode: Text.Wrap
              }
            }

            Text {
              visible: root.editorError !== ""
              text: root.editorError
              color: "#f38ba8"
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.space(8)
              Button {
                text: root.editorSaving ? "Lagrer…" : "Lagre"
                enabled: !root.editorSaving
                foreground: root.bar.background
                background: Commons.Color.accent
                onClicked: root.saveNote()
              }
              Button {
                text: "Avbryt"
                enabled: !root.editorSaving
                foreground: root.bar.foreground
                background: "transparent"
                onClicked: root.closeEditor()
              }
              Button {
                visible: root.editingNote !== null
                text: "Slett"
                enabled: !root.editorSaving
                foreground: "#f38ba8"
                background: "transparent"
                onClicked: root.deleteNote()
              }
            }
          }

          // ---------------- Note detail (view mode) ----------------
          Column {
            visible: root.selectedNote !== null && !root.editorOpen && !root.showSettings
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
                text: "Tilbake"
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
              Text {
                visible: root.selectedNote && root.selectedNote.path
                text: root.selectedNote ? root.selectedNote.path : ""
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: root.contentBlocks
                delegate: Item {
                  width: parent.width

                  // Text paragraph block
                  Text {
                    visible: modelData.type === "text"
                    text: modelData.text
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                    width: parent.width
                  }

                  // Task block with checkboxes
                  Column {
                    visible: modelData.type === "tasks"
                    width: parent.width
                    spacing: Style.space(4)

                    Repeater {
                      model: modelData.items
                      delegate: Row {
                        spacing: Style.space(8)
                        width: parent.width

                        CheckBox {
                          checked: modelData.checked
                          onCheckedChanged: root.toggleTask(repeater.model.index, index)
                          width: Style.space(24)
                          height: Style.space(24)
                        }

                        Text {
                          text: modelData.text
                          color: modelData.checked ? Qt.darker(root.bar.foreground, 1.8) : root.bar.foreground
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.body
                          wrapMode: Text.WordWrap
                          width: parent.width - Style.space(32)
                        }
                      }
                    }
                  }
                }
              }

            Row {
              spacing: Style.space(8)
              Button {
                text: "Rediger"
                enabled: !root.editorSaving
                foreground: root.bar.background
                background: Commons.Color.accent
                onClicked: root.editNote(root.selectedNote)
              }
              Button {
                text: "Slett"
                enabled: !root.editorSaving
                foreground: "#f38ba8"
                background: "transparent"
                onClicked: root.deleteNote()
              }
            }
          }

          // ---------------- Notes list ----------------
          Column {
            visible: root.configured && !root.showSettings && !root.editorOpen && !root.selectedNote
            width: parent.width
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                text: root.notes.length + " notat" + (root.notes.length === 1 ? "" : "er")
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Button {
                text: root.loading ? "Synker…" : "Ny note"
                enabled: !root.loading
                foreground: root.bar.background
                background: Commons.Color.accent
                onClicked: root.newNote()
              }
              Button {
                text: root.loading ? "Synker…" : "Oppdater"
                enabled: !root.loading
                foreground: root.bar.foreground
                background: "transparent"
                fontSize: Style.font.bodySmall
                onClicked: root.refresh()
              }
              Button {
                text: "Innstillinger"
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
                  onActivated: root.selectedNote = modelData
                }
              }
              Item {
                visible: root.notes.length === 0 && !root.loading && root.errorMessage === ""
                width: parent.width
                height: Style.space(72)
                Text {
                  anchors.centerIn: parent
                  text: "Ingen notater ennå — lag en ny, eller synk fra Futo Notes-appen."
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
        }
      }
    }
  }
}
}
