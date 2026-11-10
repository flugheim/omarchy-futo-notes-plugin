import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
    id: root
    moduleName: "futo-notes"
    ipcTarget: "futo-notes"
    manageIpc: false

    property var anchorItem: null
    property bool openedFromHotkey: false
    property var hostWidget: null
    property var settings: {}
    property var api: Model.FutoNotesAPI
    property var notesModel: Model.NoteModel

    readonly property var barIdentity: hostWidget || root

    // UI state
    property var notes: []
    property var selectedNote: null
    property bool loading: false
    property string errorMessage: ""
    property bool showSettings: false
    property string passwordInput: ""
    property bool savingSettings: false
    property bool testingConnection: false

    function open() {
        openedFromHotkey = false
        setCenterHoverRevealSuppressed(false)
        root.controller.show()
        if (notes.length === 0 && settings.serverUrl) {
            refresh()
        }
    }

    function openFromHotkey() {
        openedFromHotkey = true
        root.controller.show()
        if (notes.length === 0 && settings.serverUrl) {
            refresh()
        }
        Qt.callLater(function() {
            if (root.opened) setCenterHoverRevealSuppressed(true)
        })
    }

    function close() {
        setCenterHoverRevealSuppressed(false)
        root.controller.hide()
    }

    function toggle() {
        if (root.opened) root.close()
        else root.openFromHotkey()
    }

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

    function refresh() {
        if (!settings.serverUrl) {
            showSettings = true
            return
        }

        if (!passwordInput) {
            // Need password to decrypt - show inline password field
            errorMessage = "Enter your sync password to decrypt notes"
            return
        }

        performSync()
    }

    function performSync() {
        loading = true
        errorMessage = ""

        var result = api.fullSync(passwordInput)
        if (result.success) {
            notes = result.notes
            errorMessage = ""
            passwordInput = "" // Clear password after use
            // Update badge count on bar widget
            if (hostWidget) {
                hostWidget.noteCount = notes.length
                hostWidget.lastSyncText = Qt.formatTime(new Date(), "HH:mm")
                hostWidget.lastError = ""
                hostWidget.saveNoteCount()
            }
        } else {
            errorMessage = result.error
            if (hostWidget) {
                hostWidget.lastError = result.error
                hostWidget.saveNoteCount()
            }
            if (result.error.includes("password") || result.error.includes("Wrong")) {
                passwordInput = "" // Clear wrong password
            }
        }
        loading = false
    }

    function selectNote(note) {
        selectedNote = selectedNote === note ? null : note
    }

    function saveSettings() {
        if (!settings.serverUrl) {
            errorMessage = "Server URL is required"
            return
        }

        savingSettings = true
        api.serverUrl = settings.serverUrl
        var userResult = api.getUser()
        if (userResult) {
            settings.token = "valid"
            Model.Settings.save(settings)
            showSettings = false
            errorMessage = ""
            // Update bar widget
            if (hostWidget) {
                hostWidget.settings = settings
                hostWidget.configured = true
                hostWidget.api.serverUrl = settings.serverUrl
            }
            refresh()
        } else {
            errorMessage = "Failed to connect to server. Check URL."
        }
        savingSettings = false
    }

    function testConnection() {
        if (!settings.serverUrl) return

        testingConnection = true
        errorMessage = ""

        var url = settings.serverUrl + "/"
        var result = Quickshell.Http.get(url)

        if (result.status === 200) {
            try {
                var data = JSON.parse(result.body)
                if (data.name === "futo-notes") {
                    errorMessage = "✓ Connected to Futo Notes server v" + data.version
                } else {
                    errorMessage = "✗ Server responded but doesn't appear to be Futo Notes"
                }
            } catch (e) {
                errorMessage = "✗ Invalid response from server"
            }
        } else {
            errorMessage = "✗ Connection failed (HTTP " + result.status + ")"
        }
        testingConnection = false
    }

    function logout() {
        settings = Model.Settings.defaults()
        Model.Settings.save(settings)
        notes = []
        selectedNote = null
        showSettings = true
        if (hostWidget) {
            hostWidget.settings = settings
            hostWidget.configured = false
            hostWidget.noteCount = 0
            hostWidget.lastSyncText = ""
            hostWidget.lastError = ""
            hostWidget.saveNoteCount()
        }
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
            implicitHeight: contentColumn.implicitHeight
            anchors.fill: parent
            onCloseRequested: root.close()
            onTabRequested: function(direction) { root.switchPanel(direction) }

            Flickable {
                id: scrollView
                anchors.fill: parent
                contentWidth: width
                contentHeight: contentColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height

                Column {
                    id: contentColumn
                    width: scrollView.width
                    spacing: Style.space(16)

                    // Header
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
                                text: settings.serverUrl ? "Connected to " + settings.serverUrl.replace(/^https?:\/\//, "") : "Not configured"
                                color: Qt.darker(root.bar.foreground, 1.5)
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.bodySmall
                            }
                        }
                    }

                    // Settings form (shown when not configured or explicitly requested)
                    Column {
                        visible: showSettings || !settings.serverUrl
                        width: parent.width
                        spacing: Style.space(12)

                        Rectangle {
                            width: parent.width
                            height: Style.spacing.hairline
                            color: root.bar.foreground
                            opacity: 0.12
                        }

                        Text {
                            text: settings.serverUrl ? "Settings" : "Setup Futo Notes Sync"
                            color: root.bar.foreground
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.body
                            font.bold: true
                        }

                        Column {
                            spacing: Style.space(8)
                            width: parent.width

                            Text {
                                text: "Sync Server URL"
                                color: Qt.darker(root.bar.foreground, 1.3)
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.bodySmall
                            }

                            TextField {
                                width: parent.width
                                text: settings.serverUrl
                                placeholderText: "https://notes.yourdomain.com"
                                foreground: root.bar.foreground
                                font.family: root.bar.fontFamily
                                onTextChanged: settings.serverUrl = text
                            }
                        }

                        Column {
                            spacing: Style.space(8)
                            width: parent.width

                            Text {
                                text: "Sync Password (for decryption)"
                                color: Qt.darker(root.bar.foreground, 1.3)
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.bodySmall
                            }

                            TextField {
                                width: parent.width
                                text: passwordInput
                                placeholderText: "Enter password to decrypt notes"
                                foreground: root.bar.foreground
                                font.family: root.bar.fontFamily
                                echoMode: TextField.Password
                                onTextChanged: passwordInput = text
                            }
                        }

                        Text {
                            visible: errorMessage !== ""
                            text: errorMessage
                            color: errorMessage.startsWith("✓") ? "#a6e3a1" : "#f38ba8"
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                        }

                        Row {
                            spacing: Style.space(8)

                            Button {
                                text: testingConnection ? "Testing..." : "Test Connection"
                                enabled: !savingSettings && !testingConnection && settings.serverUrl !== ""
                                foreground: root.bar.foreground
                                background: "transparent"
                                font.family: root.bar.fontFamily
                                onClicked: root.testConnection()
                            }

                            Button {
                                text: savingSettings ? "Saving..." : (settings.serverUrl ? "Save & Sync" : "Connect")
                                enabled: !savingSettings && !testingConnection && settings.serverUrl !== ""
                                foreground: root.bar.background
                                background: Commons.Color.accent
                                font.family: root.bar.fontFamily
                                onClicked: root.saveSettings()
                            }

                            Button {
                                visible: settings.serverUrl
                                text: "Logout"
                                enabled: !savingSettings && !testingConnection
                                foreground: root.bar.foreground
                                background: "transparent"
                                font.family: root.bar.fontFamily
                                onClicked: root.logout()
                            }
                        }
                    }

                    // Notes list (shown when configured and not in settings)
                    Column {
                        visible: settings.serverUrl && !showSettings
                        width: parent.width
                        spacing: Style.space(8)

                        Row {
                            width: parent.width
                            spacing: Style.space(8)

                            Text {
                                text: notes.length + " note" + (notes.length === 1 ? "" : "s")
                                color: Qt.darker(root.bar.foreground, 1.3)
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.bodySmall
                            }

                            Button {
                                text: loading ? "󰦖 Syncing..." : "󰇚 Refresh"
                                enabled: !loading
                                foreground: root.bar.foreground
                                background: "transparent"
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                onClicked: root.refresh()
                            }

                            Button {
                                text: "⚙ Settings"
                                enabled: !loading
                                foreground: root.bar.foreground
                                background: "transparent"
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                onClicked: showSettings = true
                            }
                        }

                        Rectangle {
                            width: parent.width
                            height: Style.spacing.hairline
                            color: root.bar.foreground
                            opacity: 0.12
                        }

                        Column {
                            spacing: 0

                            Repeater {
                                model: notes

                                NoteItem {
                                    required property var modelData
                                    width: parent.width
                                    selected: root.selectedNote && root.selectedNote.id === modelData.id
                                    onClicked: root.selectNote(modelData)
                                }
                            }

                            Item {
                                visible: notes.length === 0 && !loading && !errorMessage
                                width: parent.width
                                height: Style.space(80)

                                Text {
                                    anchors.centerIn: parent
                                    text: "No notes yet. Create some on your phone or computer."
                                    color: Qt.darker(root.bar.foreground, 1.5)
                                    font.family: root.bar.fontFamily
                                    font.pixelSize: Style.font.body
                                }
                            }
                        }

                        Text {
                            visible: errorMessage !== "" && !loading
                            text: errorMessage
                            color: "#f38ba8"
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                        }
                    }

                    // Note detail view
                    Column {
                        visible: selectedNote
                        width: parent.width
                        spacing: Style.space(16)

                        Rectangle {
                            width: parent.width
                            height: Style.spacing.hairline
                            color: root.bar.foreground
                            opacity: 0.12
                        }

                        Row {
                            spacing: Style.space(8)

                            Button {
                                text: "← Back"
                                foreground: root.bar.foreground
                                background: "transparent"
                                font.family: root.bar.fontFamily
                                onClicked: root.selectedNote = null
                            }

                            Text {
                                text: selectedNote.title
                                color: root.bar.foreground
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.title
                                font.bold: true
                            }
                        }

                        // Tags
                        Row {
                            visible: selectedNote.tags && selectedNote.tags.length > 0
                            spacing: Style.space(6)

                            Repeater {
                                model: selectedNote.tags

                                Rectangle {
                                    height: Style.space(20)
                                    radius: Style.cornerRadius
                                    color: Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)

                                    Text {
                                        anchors.centerIn: parent
                                        text: "#" + modelData
                                        color: Style.hoverStateColor(root.bar.foreground, Commons.Color.accent)
                                        font.family: root.bar.fontFamily
                                        font.pixelSize: Style.font.caption
                                        padding: Style.space(6)
                                    }
                                }
                            }
                        }

                        // Folder
                        Text {
                            visible: selectedNote.folder
                            text: "📁 " + selectedNote.folder
                            color: Qt.darker(root.bar.foreground, 1.4)
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.bodySmall
                        }

                        // Content
                        Flickable {
                            width: parent.width
                            height: Math.min(contentText.implicitHeight + Style.space(24), Style.space(400))
                            clip: true
                            contentWidth: width
                            contentHeight: contentText.implicitHeight + Style.space(24)
                            boundsBehavior: Flickable.StopAtBounds

                            Text {
                                id: contentText
                                width: parent.width - Style.space(24)
                                text: selectedNote.content
                                color: root.bar.foreground
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.body
                                wrapMode: Text.WordWrap
                                padding: Style.space(12)
                            }
                        }

                        // Metadata
                        Row {
                            spacing: Style.space(16)

                            Text {
                                text: "Created: " + Qt.formatDateTime(new Date(selectedNote.createdAt), "MMM d, yyyy HH:mm")
                                color: Qt.darker(root.bar.foreground, 1.5)
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                            Text {
                                visible: selectedNote.updatedAt !== selectedNote.createdAt
                                text: "Updated: " + Qt.formatDateTime(new Date(selectedNote.updatedAt), "MMM d, yyyy HH:mm")
                                color: Qt.darker(root.bar.foreground, 1.5)
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.caption
                            }
                        }
                    }
                }
            }
        }
    }
}

// Note item component
Component {
    id: NoteItem

    Rectangle {
        id: container
        required property var modelData
        required property bool selected
        width: parent.width
        height: content.implicitHeight + Style.space(16)
        radius: Style.cornerRadius
        color: selected ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent) : (mouseArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, 1.1) : "transparent")
        border.color: selected ? Style.hoverStateColor(root.bar.foreground, Commons.Color.accent) : "transparent"
        border.width: selected ? 1 : 0

        property alias onClicked: mouseArea.onClicked

        MouseArea {
            id: mouseArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
        }

        Column {
            id: content
            width: parent.width
            spacing: Style.space(6)
            anchors.margins: Style.space(12)

            Row {
                spacing: Style.space(10)

                Text {
                    text: "󰠮"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                }

                Column {
                    spacing: Style.space(2)

                    Text {
                        text: modelData.title
                        color: root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                        width: parent.width
                    }

                    Row {
                        spacing: Style.space(8)

                        Text {
                            visible: modelData.folder
                            text: "📁 " + modelData.folder
                            color: Qt.darker(root.bar.foreground, 1.5)
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.caption
                        }

                        Repeater {
                            model: modelData.tags ? modelData.tags.slice(0, 3) : []

                            Text {
                                text: "#" + modelData
                                color: Qt.darker(root.bar.foreground, 1.5)
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.caption
                            }
                        }

                        Text {
                            visible: modelData.tags && modelData.tags.length > 3
                            text: "+" + (modelData.tags.length - 3) + " more"
                            color: Qt.darker(root.bar.foreground, 1.5)
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.caption
                        }
                    }
                }
            }

            Text {
                visible: modelData.content && modelData.content.length > 0
                text: modelData.content.split("\n")[0]
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                width: parent.width
            }
        }
    }
}