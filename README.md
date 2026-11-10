# AppSalute

A keyboard-first app and window switcher for macOS, in the spirit of Cmd-Tab, with a window list per app and a one-step way to quit apps you are no longer using.

## Features

- **Recent-use order:** apps are listed most recently used first, so one quick press takes you back to the previous app.
- **Window list per app:** see every window of the selected app, including windows on other desktops, minimized windows and empty ones (open dialogs, new tabs, untitled documents).
- **Act on single windows:** raise or close one window without touching the rest of the app.
- **Close all inactive apps:** quits hidden or minimized apps that have no real window, after a confirmation step. Excluded apps and Finder are never closed.
- **Keyboard and mouse:** click to select, double-click to open.
- **Configurable shortcut**, excluded apps, and launch at login, all from the menu bar.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| `⌃⌥Tab` (default, changeable) | Open the switcher / next app (`⇧` for previous) |
| `←` `→` | Select app |
| `↓` `↑` | Move into / out of the window list and the "Close all inactive apps" bar |
| `Space` | Bring the selection to the front and stay in the switcher |
| `Return` | Open the selection and close the switcher |
| `Esc` | Dismiss |
| `⌘W` / `⌥W` / `⌃⌥W` | Close the selected window |
| `⌘Q` / `⌥Q` / `⌃⌥Q` | Quit the selected app |

Releasing the modifier keys opens the selection, unless "Confirm selection with return" is on.

## Requirements

- macOS 14 or later
- Xcode command line tools (`xcode-select --install`)
- **Accessibility permission** for AppSalute (System Settings → Privacy & Security → Accessibility). Without it the app can only list windows approximately and cannot raise, close or title them.

## Build

```bash
./build_app.sh
```

The script compiles the sources with `swiftc`, packages `AppSalute.app` and code-signs it. Options: `--suffix computer|none|NAME`, `--install` (copy to `/Applications`) and `--clean`.

### Keep the Accessibility permission across rebuilds

Ad-hoc signed apps get a new signature on every build, and macOS then drops the permission. Create a self-signed certificate once and the script will pick it up automatically:

1. Open Keychain Access → Certificate Assistant → Create a Certificate…
2. Name it `AppSalute Dev`, set Identity Type to *Self-Signed Root* and Certificate Type to *Code Signing*.
3. Open the new certificate, expand *Trust* and set *Code Signing* to *Always Trust*.

You can also pass your own identity with `SIGN_IDENTITY="..." ./build_app.sh`.

## Logs

`~/Library/Logs/AppSalute.log` records permission state and which apps are considered inactive, which helps when something does not behave as expected.

## Notes

AppSalute uses a few private macOS APIs (window IDs and Spaces lookup), so it is not suitable for the Mac App Store and may need updates after major macOS releases.

## License

Copyright (C) 2026 shmvon

AppSalute is free software, licensed under the [GNU Affero General Public License v3.0](LICENSE).
