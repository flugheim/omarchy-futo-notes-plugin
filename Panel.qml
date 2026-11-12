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
  readonly property string scriptPath: home + "/.config/omarchy/plugins/flugheim.futo-notes/futo-notes-sync.py"

  // ---------------------------------------------------------------- state
  property var settings: ({})
  property var notes: []
  property bool loading: false
  property bool savingPassword: false
  property bool editorSaving: false
  property string errorMessage: ""
  property string statusMessage: ""
  property bool showSettings: false
  // Set while a checkbox toggle saves, so the result does not leave the note.
  property bool skipRefresh: false

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
  property bool passwordStored: false

  readonly property bool configured: !!(settings.serverUrl && String(settings.serverUrl).length > 0)

  // Single source of truth for which section the panel shows.
  readonly property string view: {
    if (editorOpen) return "editor"
    if (selectedNote !== null) return "detail"
    if (showSettings || !configured) return "settings"
    return "list"
  }

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
      Qt.callLater(function() {
        keyringLookup.running = true
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
    if (!path) { editorError = "Give the note a name (e.g. Note.md)"; return }
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
    // Works from both the editor and the note detail view.
    var note = editingNote || selectedNote
    if (!note) return
    editorError = ""
    editorSaving = true
    runSync({
      action: "delete",
      id: note.id,
      version: Number(note.version || 0),
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
    // Auto-save after a short delay so rapid toggles batch into one call.
    saveTimer.restart()
  }

  Timer {
    id: saveTimer
    interval: 400
    repeat: false
    onTriggered: root.saveContentBlocks()
  }

  function saveContentBlocks() {
    if (!root.selectedNote) return
    root.editorSaving = true
    root.skipRefresh = true
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
  // A request that arrived while the helper was still running. The helper
  // handles exactly one request per run, so it has to wait for the next one.
  property var queuedPayload: null

  function runSync(payload) {
    // Every request needs the server URL; write actions don't repeat it.
    var request = Object.assign({}, payload)
    if (!request.serverUrl && root.settings.serverUrl)
      request.serverUrl = String(root.settings.serverUrl)
    if (syncProc.running) {
      queuedPayload = request
      return
    }
    queuedPayload = null
    pendingPayload = JSON.stringify(request) + "\n"
    loading = true
    syncProc.running = true
  }

  function runQueuedPayload() {
    if (syncProc.running || queuedPayload === null) return
    var payload = queuedPayload
    queuedPayload = null
    runSync(payload)
  }

  Timer {
    interval: 150
    repeat: false
    running: root.queuedPayload !== null && !syncProc.running
    onTriggered: root.runQueuedPayload()
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
        statusMessage = "Saved."
        if (!root.skipRefresh) {
          selectedNote = null
          refresh()
        }
        root.skipRefresh = false
      } else {
        // delete succeeded
        editorOpen = false
        editingNote = null
        selectedNote = null
        editorPath = ""
        editorContent = ""
        editorError = ""
        errorMessage = ""
        statusMessage = "Deleted."
        refresh()
      }
    } else {
      root.skipRefresh = false
      if (editorOpen) {
        editorError = res.error || "Saving failed."
        editorSaving = false
      } else {
        errorMessage = res.error || "Sync failed."
        if (String(errorMessage).indexOf("No password saved") !== -1) passwordStored = false
        settings = Object.assign({}, settings, { lastError: errorMessage })
        persistSettings()
      }
    }
  }

  // ---------------------------------------------------------------- settings actions
  function connectAndSync() {
    var url = String(formUrl || "").trim().replace(/\/+$/, "")
    if (!url) { errorMessage = "Enter the sync server URL."; return }
    if (!formPassword && !passwordStored) { errorMessage = "Enter the sync password."; return }

    errorMessage = ""
    statusMessage = ""
    savingPassword = true
    settings = Object.assign({}, settings, { serverUrl: url })
    persistSettings()
    var payload = { serverUrl: url }
    if (formPassword) {
      payload.password = formPassword
      payload.savePassword = true
      passwordStored = true
    }
    runSync(payload)
  }

  property string testPayload: ""

  // Process to lookup password from keyring when panel loads
  Process {
    id: keyringLookup
    command: ["python3", root.scriptPath]
    stdinEnabled: true
    onStarted: write(JSON.stringify({ serverUrl: formUrl }) + "\n")
    stdout: StdioCollector { waitForEnd: true
      onStreamFinished: {
        var res = ({})
        try { res = JSON.parse(String(text || "").trim() || "{}") } catch (e) {}
        // A successful sync means a usable password is already in the keyring.
        root.passwordStored = res.ok === true
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: { }
  }

  function testConnection() {
    var url = String(formUrl || "").trim().replace(/\/+$/, "")
    if (!url) { errorMessage = "Enter the sync server URL."; return }
    if (!formPassword && !passwordStored) { errorMessage = "Enter the sync password."; return }

    errorMessage = ""
    statusMessage = "Testing…"
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
    passwordStored = false
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
          root.errorMessage = "The sync helper exited with code " + code + "."
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
          Item {
            width: parent.width
            implicitHeight: Math.max(headerIcon.implicitHeight, headerLabels.implicitHeight, headerActions.implicitHeight)

            Text {
              id: headerIcon
              text: "󰠮"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.displayLarge
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: headerLabels
              anchors.left: headerIcon.right
              anchors.leftMargin: Style.space(12)
              anchors.right: headerActions.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Futo Notes"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.configured
                  ? String(root.settings.serverUrl).replace(/^https?:\/\//, "")
                  : "Not configured"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Row {
              id: headerActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              PanelActionButton {
                visible: root.configured && root.view !== "editor"
                iconText: "󰑐"
                tooltipText: "Refresh"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.refresh()
              }
              PanelActionButton {
                visible: root.configured && root.view !== "editor"
                iconText: "󰐕"
                tooltipText: "New note"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.newNote()
              }
              PanelActionButton {
                visible: root.configured && root.view !== "editor"
                iconText: root.view === "settings" ? "󰅖" : "󰒓"
                tooltipText: root.view === "settings" ? "Close settings" : "Settings"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: {
                  if (root.view === "settings") root.showSettings = false
                  else root.showSettings = true
                }
              }
            }
          }

          // ---------------- Settings form ----------------
          Column {
            id: settingsCol
            visible: root.view === "settings"
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
                placeholderText: "The password that decrypts your notes"
                foreground: root.bar.foreground
                password: true
                onTextChanged: root.formPassword = text
              }
              Text {
                visible: root.passwordStored && root.formPassword === ""
                text: "A password is already stored in the system keyring."
                color: "#a6e3a1"
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Text {
                text: "Stored in the system keyring (secret-tool), never in a file."
                color: Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Text {
              visible: root.errorMessage !== ""
              text: root.errorMessage
              color: Commons.Color.urgent
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

            Item {
              width: parent.width
              height: Math.max(connectButton.implicitHeight, settingsActions.implicitHeight)

              Button {
                id: connectButton
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰓦"
                text: root.loading ? "Working…" : "Connect & sync"
                enabled: !root.loading && !root.savingPassword
                foreground: root.bar.background
                background: Commons.Color.accent
                fontFamily: root.bar.fontFamily
                onClicked: root.connectAndSync()
              }

              Row {
                id: settingsActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                PanelActionButton {
                  iconText: "󰖟"
                  tooltipText: "Test connection"
                  enabled: !root.loading
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.testConnection()
                }
                PanelActionButton {
                  visible: root.configured
                  iconText: "󰍃"
                  tooltipText: "Log out"
                  enabled: !root.loading
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.logout()
                }
              }
            }
          }

          // ---------------- Editor popup ----------------
          Column {
            id: editorCol
            visible: root.view === "editor"
            width: parent.width
            spacing: Style.space(12)

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.bar.foreground
              opacity: 0.12
            }

            Item {
              width: parent.width
              height: Math.max(editorTitle.implicitHeight, editorActions.implicitHeight)

              Text {
                id: editorTitle
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.editingNote ? "Edit note" : "New note"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Row {
                id: editorActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                PanelActionButton {
                  iconText: "󰄬"
                  tooltipText: "Save"
                  hoverColor: Commons.Color.accent
                  enabled: !root.editorSaving
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.saveNote()
                }
                PanelActionButton {
                  iconText: "󰅖"
                  tooltipText: "Cancel"
                  enabled: !root.editorSaving
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.closeEditor()
                }
                PanelActionButton {
                  visible: root.editingNote !== null
                  iconText: "󰆴"
                  tooltipText: "Delete note"
                  hoverColor: Commons.Color.urgent
                  enabled: !root.editorSaving
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.deleteNote()
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: "Path (file name)"
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              TextField {
                width: parent.width
                text: root.editorPath
                placeholderText: "e.g. Notes/My note.md"
                foreground: root.bar.foreground
                onTextChanged: root.editorPath = text
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: "Content"
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
              color: Commons.Color.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // ---------------- Note detail (view mode) ----------------
          Column {
            id: detailCol
            visible: root.view === "detail"
            width: parent.width
            spacing: Style.space(12)

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.bar.foreground
              opacity: 0.12
            }

            Item {
              width: parent.width
              height: Math.max(backButton.implicitHeight, detailTitle.implicitHeight, detailActions.implicitHeight)

              PanelActionButton {
                id: backButton
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰁍"
                tooltipText: "Back"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.selectedNote = null
              }

              Column {
                id: detailTitle
                anchors.left: backButton.right
                anchors.right: detailActions.left
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  text: root.selectedNote ? root.selectedNote.title : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  visible: root.selectedNote && root.selectedNote.path
                  text: root.selectedNote ? root.selectedNote.path : ""
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                id: detailActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                PanelActionButton {
                  iconText: "󰏫"
                  tooltipText: "Edit"
                  enabled: !root.editorSaving
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.editNote(root.selectedNote)
                }
                PanelActionButton {
                  iconText: "󰆴"
                  tooltipText: "Delete note"
                  hoverColor: Commons.Color.urgent
                  enabled: !root.editorSaving
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.deleteNote()
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: root.contentBlocks
                delegate: Column {
                  id: blockDelegate
                  property int blockIndex: index
                  width: parent.width
                  spacing: Style.space(8)

                  // Text paragraph block
                  Text {
                    visible: modelData.type === "text"
                    text: modelData.type === "text" ? modelData.text : ""
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    lineHeight: 1.25
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
                          onCheckedChanged: {
                            if (checked !== modelData.checked)
                              root.toggleTask(blockDelegate.blockIndex, index)
                          }
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
            }
          }

          // ---------------- Notes list ----------------
          Column {
            id: notesCol
            visible: root.view === "list"
            width: parent.width
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                text: root.notes.length + (root.notes.length === 1 ? " note" : " notes")
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                visible: root.loading
                text: "Syncing…"
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
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
                  text: "No notes yet — create one, or sync from the Futo Notes app."
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }

            Text {
              visible: root.errorMessage !== ""
              text: root.errorMessage
              color: Commons.Color.urgent
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
