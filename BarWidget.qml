import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "futo-notes"

  readonly property string settingsPath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/futo-notes.json"

  property var settings: ({})
  property bool configured: false
  property int noteCount: 0
  property string lastSyncText: ""
  property string lastError: ""

  function applySettings(raw) {
    var s = ({})
    try { s = JSON.parse(raw || "{}") } catch (e) { s = ({}) }
    root.settings = s
    root.configured = !!(s.serverUrl && String(s.serverUrl).length > 0)
    root.noteCount = Number(s.lastCount || 0)
    root.lastSyncText = s.lastSync || ""
    root.lastError = s.lastError || ""
    if (panelLoader.item) panelLoader.item.settings = s
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() { if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh() }
  function togglePanel() { if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle() }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Watch the settings file so the badge follows changes made in the panel.
  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applySettings(text())
    onLoadFailed: root.applySettings("")
  }

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
    text: "󰠮"
    labelText: ""
    slotSize: Style.bar.statusSlot
    tooltipText: root.configured
      ? (root.lastSyncText ? "Synkert " + root.lastSyncText : "Ingen notater synkret")
        + (root.lastError ? " · " + root.lastError : "")
      : "Futo Notes — klikk for å sette opp"

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}