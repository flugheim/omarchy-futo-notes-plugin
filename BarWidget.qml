import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
    id: root
    moduleName: "futo-notes"

    property var settings: Model.Settings.load()
    property var api: Model.FutoNotesAPI
    property var notesModel: Model.NoteModel
    property bool configured: settings.serverUrl !== ""
    property int noteCount: 0
    property bool syncing: false
    property string lastSyncText: ""
    property string lastError: ""

    function injectPanel() {
        var target = panelLoader.item
        if (!target) return
        if ("bar" in target) target.bar = root.bar
        if ("settings" in target) target.settings = root.settings
        if ("anchorItem" in target) target.anchorItem = button
        if ("hostWidget" in target) target.hostWidget = root
    }

    function refresh() {
        if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
    }

    function togglePanel() {
        if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
    }

    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

    function open() {
        if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
    }

    function close() {
        if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
    }

    readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

    function closeForPopoutSwitch() {
        if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
    }

    // Configure API on startup
    Component.onCompleted: {
        api.serverUrl = settings.serverUrl
        api.token = settings.token
        loadNoteCount()
    }

    function loadNoteCount() {
        var cacheFile = Quickshell.FileSystem.readFile(
            Quickshell.env("HOME") + "/.local/state/omarchy/settings/futo-notes-cache.json"
        )
        if (cacheFile) {
            try {
                var cache = JSON.parse(cacheFile)
                noteCount = cache.count || 0
                if (cache.lastSync) {
                    var date = new Date(cache.lastSync)
                    lastSyncText = Qt.formatTime(date, "HH:mm")
                }
                if (cache.error) {
                    lastError = cache.error
                }
            } catch (e) {}
        }
    }

    function saveNoteCount() {
        var cache = {
            count: noteCount,
            lastSync: new Date().toISOString(),
            error: lastError
        }
        var path = Quickshell.env("HOME") + "/.local/state/omarchy/settings/futo-notes-cache.json"
        var dir = path.substring(0, path.lastIndexOf("/"))
        Quickshell.FileSystem.mkpath(dir)
        Quickshell.FileSystem.writeFile(path, JSON.stringify(cache))
    }

    visible: configured
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

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: noteCount > 0 ? noteCount.toString() : ""
        slotSize: Style.bar.statusSlot
        icon: "󰠮"
        tooltipText: configured
            ? (noteCount > 0 ? (noteCount + " note" + (noteCount === 1 ? "" : "s")) : "No notes synced")
              + (lastSyncText ? " (synced " + lastSyncText + ")" : "")
              + (lastError ? " - " + lastError : "")
            : "Futo Notes not configured - right-click for settings"

        onPressed: function(b) {
            if (!root.bar) return
            if (b === Qt.RightButton) {
                root.openSettings()
            } else if (b === Qt.MiddleButton) {
                root.refresh()
            } else {
                if (configured) {
                    root.togglePanel()
                } else {
                    root.openSettings()
                }
            }
        }
    }

    function openSettings() {
        root.bar.run("omarchy-menu-open --search futo-notes")
    }
}