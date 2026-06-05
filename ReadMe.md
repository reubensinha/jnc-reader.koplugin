# JNC Reader

A [KOReader](https://koreader.rocks/) plugin for reading [J-Novel Club](https://j-novel.club/) subscription content on KOReader-supported devices.

## Design principles

- **Streaming, minimal footprint** — part content is fetched on demand and held in memory. To display it, KOReader's reader needs a real file, so the part is written to a single temporary `.html` in `koreader/jnc-reader-tmp/`. At most one part exists on disk at a time; it's cleared when you open the next part. (A future version will delete it as soon as the reader closes.)
- **No piracy path** — the plugin provides no export, save, or download functionality. Access is gated by your active JNC subscription; if your token is invalid or your subscription has lapsed, the API returns an error and no content is shown.
- **No third-party dependencies** — uses only libraries bundled with KOReader (`ssl.https`, `ltn12`, `json`, `mime`).

## Features (v0.2)

- Sign in with your J-Novel Club account; session persisted across KOReader restarts
- **Home menu** — New Releases · Following · My Library · Sign out
- **New Releases** — a feed of the last 14 days of pre-pub parts from series you follow, showing the part name and a relative release time ("Today", "3 days ago", "May 25, 2026"); tap to open the reader directly on that part
- **Following** — your followed series; tap through to volumes and parts
- **My Library** — your followed series, with owned volumes marked ★ in the series view
- Read pre-pub parts in KOReader's native reader (pagination, fonts, bookmarks, etc.)

> Text-only: cover thumbnails are intentionally absent in v0.2 — loading KOReader's image stack together with the network layer triggered a native crash on the Android 16 test device. See `PRODUCT_DESIGN_DOCUMENT.md` §6.

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
├── api.lua        — JNC API client (auth, series, events, parts)
├── renderer.lua   — Writes the self-contained part HTML to a short-lived temp file for the reader
└── settings.lua   — Token and preference persistence
```

## Roadmap

- [ ] Cover images (deferred — blocked by a native crash when the image stack is loaded alongside the network layer; see the design doc §6)
- [ ] Delete the temp part file as soon as the reader closes (tighter anti-piracy / cleanup)
- [ ] Flat "owned volumes" list across all series
- [ ] Reading progress sync (mark parts as read)
- [ ] Follow / unfollow series in-app
- [ ] Native C++ Kobo app (no KOReader dependency)

## Legal

This plugin is unaffiliated with J-Novel Club. It uses their public API solely to display content to authenticated, subscribed users. No content is stored or redistributed.

Licensed under the MIT License.