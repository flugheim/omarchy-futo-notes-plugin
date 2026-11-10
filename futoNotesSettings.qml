import QtQuick
import qs.Commons
import qs.Ui

SettingsForm {
    id: root
    title: "Futo Notes"
    description: "Configure your self-hosted Futo Notes sync server"

    property var settings: {
        serverUrl: "",
        refreshMinutes: 15
    }

    Component.onCompleted: {
        loadSettings()
    }

    function loadSettings() {
        var path = Quickshell.env("HOME") + "/.local/state/omarchy/settings/futo-notes.json"
        var content = Quickshell.FileSystem.readFile(path)
        if (content) {
            try {
                settings = JSON.parse(content)
            } catch (e) {
                settings = { serverUrl: "", refreshMinutes: 15 }
            }
        }
    }

    function saveSettings() {
        var path = Quickshell.env("HOME") + "/.local/state/omarchy/settings/futo-notes.json"
        var dir = path.substring(0, path.lastIndexOf("/"))
        Quickshell.FileSystem.mkpath(dir)
        Quickshell.FileSystem.writeFile(path, JSON.stringify(settings, null, 2))
        // Trigger bar widget to reload
        root.bar.run("omarchy-shell shell rescanPlugins >/dev/null")
    }

    Column {
        width: parent.width
        spacing: Style.space(16)

        // Server URL
        Column {
            spacing: Style.space(6)
            width: parent.width

            Text {
                text: "Sync Server URL"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
            }

            Text {
                text: "The URL of your self-hosted Futo Notes sync server (e.g., https://notes.example.com)"
                color: Qt.darker(root.foreground, 1.3)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
            }

            TextField {
                width: parent.width
                text: settings.serverUrl
                placeholderText: "https://notes.yourdomain.com"
                foreground: root.foreground
                font.family: root.fontFamily
                onTextChanged: settings.serverUrl = text
            }
        }

        // Refresh interval
        Column {
            spacing: Style.space(6)
            width: parent.width

            Text {
                text: "Auto-refresh interval (minutes)"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
            }

            SpinBox {
                width: Style.space(100)
                value: settings.refreshMinutes
                minimum: 1
                maximum: 1440
                step: 1
                foreground: root.foreground
                font.family: root.fontFamily
                onValueChanged: settings.refreshMinutes = value
            }
        }

        // Test connection button
        Row {
            spacing: Style.space(8)

            Button {
                text: "Test Connection"
                foreground: root.background
                background: Commons.Color.accent
                font.family: root.fontFamily
                enabled: settings.serverUrl !== ""
                onClicked: testConnection()
            }

            Button {
                text: "Save"
                foreground: root.background
                background: Commons.Color.success
                font.family: root.fontFamily
                onClicked: saveSettings()
            }
        }

        // Status
        Text {
            id: statusText
            visible: false
            text: ""
            color: Qt.darker(root.foreground, 1.3)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
        }
    }

    function testConnection() {
        statusText.text = "Testing connection..."
        statusText.color = Qt.darker(root.foreground, 1.3)
        statusText.visible = true

        // Test by trying to fetch the capability document
        var url = settings.serverUrl + "/"
        var result = Quickshell.Http.get(url)

        if (result.status === 200) {
            try {
                var data = JSON.parse(result.body)
                if (data.name === "futo-notes") {
                    statusText.text = "✓ Connected to Futo Notes server v" + data.version
                    statusText.color = "#a6e3a1" // green
                } else {
                    statusText.text = "✗ Server responded but doesn't appear to be Futo Notes"
                    statusText.color = "#f38ba8" // red
                }
            } catch (e) {
                statusText.text = "✗ Invalid response from server"
                statusText.color = "#f38ba8"
            }
        } else {
            statusText.text = "✗ Connection failed (HTTP " + result.status + ")"
            statusText.color = "#f38ba8"
        }
    }
}