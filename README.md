# Futo Notes Plugin for Omarchy

A Omarchy plugin that connects to your self-hosted Futo Notes sync server and displays your encrypted notes in a beautiful panel.

## Features

- 🔐 **End-to-end encrypted** - Notes are decrypted locally using your sync password
- 📱 **Panel UI** - Click the bar icon to open a slide-out panel with your notes
- 🔍 **Search & filter** - View notes with tags, folders, and full content
- ⚙️ **GUI Configuration** - Configure server URL and test connection from the panel
- 🔄 **Auto-refresh** - Configurable sync interval

## Prerequisites

- A self-hosted Futo Notes sync server (see [Futo Notes self-hosting docs](https://notes.futo.tech/docs/self-hosting/))
- Futo Notes app set up on at least one device with notes synced
- Your sync password (used to decrypt the vault key)

## Installation

### From GitHub (once published)

```bash
omarchy plugin add https://github.com/yourusername/omarchy-futo-notes-plugin.git --enable
```

### Local Development

```bash
# Clone or copy this directory to your plugins folder
cp -r omarchy-futo-notes-plugin ~/.config/omarchy/plugins/futo-notes

# Validate the plugin
omarchy plugin validate ~/.config/omarchy/plugins/futo-notes

# Enable it
omarchy plugin enable futo-notes
```

## Configuration

1. **Right-click** the Futo Notes icon in the bar (or click "Settings" in the panel)
2. Enter your **Sync Server URL** (e.g., `https://notes.example.com`)
3. Click **Test Connection** to verify
4. Click **Save & Sync**
5. Enter your **Sync Password** when prompted in the panel
6. Your notes will appear!

## Usage

- **Left-click** the bar icon → Open/close notes panel
- **Middle-click** → Force sync
- **Right-click** → Open settings
- In the panel: Click a note to view its full content
- Tags and folders are displayed for each note

## Security

- Your sync password is **never stored** - only kept in memory during the session
- The vault key is derived from your password using PBKDF2-SHA256 (100,000 iterations)
- Each note is decrypted using a per-object key derived via HKDF
- All crypto operations happen locally in the plugin

## Development

### Plugin Structure

```
omarchy-futo-notes-plugin/
├── manifest.json          # Plugin metadata
├── Model.js               # API client & note model
├── FutoCrypto.js          # E2EE decryption implementation
├── BarWidget.qml          # Bar icon widget
├── Panel.qml              # Notes panel UI
└── futoNotesSettings.qml  # Settings form for Omarchy menu
```

### Key Components

- **Model.js** - Handles HTTP communication with the Futo Notes sync server API
- **FutoCrypto.js** - Implements the Futo Notes encryption specification (PBKDF2, HKDF, AES-GCM)
- **BarWidget.qml** - Shows note count in the bar, opens panel on click
- **Panel.qml** - Full notes UI with list view, detail view, and settings

### Testing Changes

```bash
# After making changes, rescan plugins
omarchy-shell shell rescanPlugins

# Or restart the shell
omarchy-restart-shell
```

## Sharing with Community

1. **Push to GitHub**:
   ```bash
   git init
   git add .
   git commit -m "Initial Futo Notes plugin"
   git remote add origin https://github.com/yourusername/omarchy-futo-notes-plugin.git
   git push -u origin main
   ```

2. **Submit to Omarchy plugin catalog** (when available) or share the GitHub URL

3. **Users install with**:
   ```bash
   omarchy plugin add https://github.com/yourusername/omarchy-futo-notes-plugin.git --enable
   ```

## Troubleshooting

### "Failed to decrypt vault key"
- Wrong password entered
- The vault hasn't been initialized on another device yet
- Server URL points to wrong server

### "No vault key material found"
- First device to sync needs to "claim" the vault in the Futo Notes app settings
- Check that sync is working on your phone/computer first

### Notes not appearing
- Check that notes are synced to the server from another device
- Try middle-clicking the bar icon to force refresh
- Check the panel error message for details

### Connection failed
- Verify server URL is correct (include `https://`)
- Check server is accessible from your network
- Verify the server's `/` endpoint returns `{"name": "futo-notes", ...}`

## License

MIT License - Feel free to use, modify, and distribute.

## Credits

- Built for [Omarchy](https://omarchy.org/)
- Integrates with [Futo Notes](https://notes.futo.tech/) sync server
- Uses Quickshell for the UI framework