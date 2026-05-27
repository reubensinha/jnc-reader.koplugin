# JNC Reader

A [KOReader](https://koreader.rocks/) plugin for reading [J-Novel Club](https://j-novel.club/) subscription content on KOReader-supported devices.

## Design principles

- **Streaming only** — part content is fetched on demand and held in memory. Nothing is written to disk. When you navigate away from a part, the content is discarded.
- **No piracy path** — the plugin does not provide any export, save, or download functionality. Access is gated by your active JNC subscription; if your token is invalid or your subscription has lapsed, the API returns an error and no content is shown.
- **No third-party dependencies** — uses only libraries bundled with KOReader (`socket.http`, `ssl.https`, `ltn12`, `json`).

## Features (v0.1)

- Sign in with your J-Novel Club account
- Browse your subscription library by series
- Read pre-pub parts directly in KOReader's text viewer
- Session token persisted across KOReader restarts (no re-login needed)

## Installation

1. Copy the `jnc-reader.koplugin/` directory to the `plugins/` folder inside your KOReader installation:
   ```
   /mnt/onboard/.adds/koreader/plugins/jnc-reader.koplugin/
   ```
2. Restart KOReader.
3. Open the main menu → **More tools** → **JNC Reader**.

## Usage

1. Tap **JNC Reader** in the KOReader main menu.
2. Enter your J-Novel Club email/username and password.
3. Browse your library and tap a part to read it.

To sign out, open the KOReader main menu → **More tools** → **JNC Reader** → **Sign out**.

## Project structure

```
jnc-reader.koplugin/
├── _meta.lua      — Plugin metadata (name, version, author)
├── main.lua       — Entry point; menu registration and UI flow
├── api.lua        — JNC API client (auth, library, parts)
├── renderer.lua   — XHTML → plain text converter
└── settings.lua   — Token and preference persistence
```

## Roadmap

- [ ] Paginated reader (instead of scroll widget)
- [ ] Cover image display in the library
- [ ] Follow / unfollow series
- [ ] Reading progress sync
- [ ] Native C++ Kobo app (no KOReader dependency)

## Legal

This plugin is unaffiliated with J-Novel Club. It uses their public API solely to display content to authenticated, subscribed users. No content is stored or redistributed.

Licensed under the MIT License.