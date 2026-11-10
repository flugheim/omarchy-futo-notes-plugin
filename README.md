# Futo Notes for Omarchy

An Omarchy bar plugin that reads your **end-to-end encrypted** [FUTO Notes](https://notes.futo.tech/)
from a self-hosted sync server and shows them in a panel.

Click the 󰠮 icon in the bar to open the notes panel. The first time you open it,
enter your sync server URL and sync password; the plugin stores the password in
your system keyring and decrypts the notes locally.

## How it works

FUTO Notes encrypts every note with a 256-bit vault key, and stores only
ciphertext on the server. Quickshell (the shell Omarchy is built on) has no HTTP
or crypto API, so the heavy lifting lives in a small Python helper:

```
Panel.qml  ──runs──▶  futo-notes-sync.py  ──HTTPS──▶  your sync server
   ▲                        │
   └──── decrypted JSON ◀───┘   (PBKDF2 + AES-256-GCM, in Python)
```

- `futo-notes-sync.py` — logs in, unwraps the vault key, downloads and decrypts
  every note, and prints JSON. It also reads/writes the password in the keyring.
- `Panel.qml` — the panel UI: setup form, notes list, note detail.
- `BarWidget.qml` — the bar icon and note counter.
- `NoteRow.qml` — one row in the notes list.

The crypto follows the official
[FUTO Notes encryption spec](https://notes.futo.tech/docs/encryption/):
PBKDF2-HMAC-SHA256 (100,000 iterations) to derive a password key, AES-256-GCM to
unwrap the vault key, then AES-256-GCM to decrypt each blob, whose plaintext is
a frame of `[version][path length][path][content]`.

## Requirements

- A self-hosted FUTO Notes sync server (see the
  [self-hosting docs](https://notes.futo.tech/docs/self-hosting/)).
- FUTO Notes set up on at least one device, with the vault created and notes
  synced. A vault with no key yet cannot be read.
- `python3` with the `cryptography` package:
  ```bash
  sudo pacman -S python-cryptography
  ```
- `secret-tool` (libsecret) for the keyring:
  ```bash
  sudo pacman -S libsecret
  ```

## Install

```bash
omarchy plugin add https://github.com/<you>/omarchy-futo-notes-plugin.git --enable
```

Or from a local checkout:

```bash
omarchy plugin add /path/to/omarchy-futo-notes-plugin --enable
```

Then make sure the widget is in your bar (`~/.config/omarchy/shell.json`) and
restart the shell:

```bash
omarchy-restart-shell
```

## Use

1. Click the 󰠮 icon in the bar.
2. Enter your **sync server URL** (e.g. `https://notes.example.com`) and your
   **sync password**. Use **Test connection** to check them first.
3. Click **Connect & sync**. The password is saved to the keyring and your notes
   appear.
4. Click any note to read it. **Refresh** re-syncs. **Log out** clears the saved
   password and settings.

Bar interactions:

- **Left click** — open/close the panel
- **Middle click** — re-sync
- **Right click** — open the panel at its settings

## Security notes

- The password is stored in the system keyring via `secret-tool`, never in a
  plain file. The server URL and cached note count live in
  `~/.local/state/omarchy/settings/futo-notes.json`.
- Decryption happens locally. The server only ever sees ciphertext.
- As the FUTO Notes docs explain, the sync password is also the login password,
  so whoever runs the server can read requests to it. Self-host it somewhere you
  trust.

## Troubleshooting

| Message | Meaning |
| --- | --- |
| `Cannot reach server` | Wrong URL, or the server is down/unreachable. |
| `That URL does not look like a Futo Notes server` | The `/` endpoint did not return `{"name":"futo-notes",…}`. |
| `Wrong sync password` | The vault key could not be decrypted — check the password. |
| `This vault has no key yet` | Connect the FUTO Notes app on a device first so it creates the vault key. |
| `No password saved` | Open settings and enter the password. |

If the helper reports a missing package, install `python-cryptography`.

## Development

Validate a checkout before installing:

```bash
omarchy plugin validate ./omarchy-futo-notes-plugin
```

After editing, copy the files into `~/.config/omarchy/plugins/futo-notes/` and
run `omarchy-restart-shell`, then check the log:

```bash
journalctl --user -n 100 --no-pager | grep futo-notes
```

The sync helper can be tested on its own; it reads one JSON line on stdin:

```bash
echo '{"serverUrl":"https://notes.example.com","password":"…"}' | \
  python3 futo-notes-sync.py
```

## License

MIT.
