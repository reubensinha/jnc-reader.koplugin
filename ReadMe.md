# JNC Reader

A [KOReader](https://koreader.rocks/) plugin for reading your [J-Novel Club](https://j-novel.club/) subscription directly on your e-reader, without leaving KOReader.

> **Active J-Novel Club subscription Requried.**

---

## Features

- **Sign in** with your J-Novel Club account; your session is remembered across KOReader restarts.
- **Home menu** — New Releases · Following · My Library · Sign out.
- **New Releases** — the last 30 days of pre-pub parts from series you follow.
- **Following** — your followed series; tap through to volumes and parts.
- **My Library** — your followed series, with owned volumes marked ★ in the series view.
- **Reads in KOReader's native reader** — pagination, fonts, line spacing, bookmarks, progress, and everything else KOReader gives you.

---

## Requirements

- **KOReader** 2021.04 or newer.
- An **active J-Novel Club subscription** (pre-pub access depends on your membership tier).
- An internet/Wi-Fi connection.

---

## Installation

1. Copy the `jnc-reader.koplugin/` folder into KOReader's `plugins/` directory. The location depends on your device:

   | Device          | Plugins folder                |
   | --------------- | ----------------------------- |
   | Kobo            | `.adds/koreader/plugins/`     |
   | Kindle          | `koreader/plugins/`           |
   | Android         | `<storage>/koreader/plugins/` |
   | Desktop / other | `koreader/plugins/`           |

   The result should be e.g. `…/koreader/plugins/jnc-reader.koplugin/main.lua`.

2. **Restart KOReader.**

3. Open the main menu → **More tools** → **JNC Reader**.

---

## Usage

1. Open **More tools → JNC Reader** from the KOReader menu.
2. **Sign in** with your J-Novel Club email/username and password (only needed once — the session is saved).
3. From the home menu, choose:
   - **New Releases** — tap a release to start reading it immediately.
   - **Following** — pick a series, then a part.
   - **My Library** — pick a series to see which volumes you own (★) and read its parts.
4. To **sign out**, open the home menu → **Sign out**.

---

## Known issues & limitations

- **Novels only.** Manga is currently not supported.

---

## Troubleshooting

To capture a log for a bug report, open `main.lua` and set:

```lua
local DEBUG = true
```

Restart KOReader, reproduce the issue, then collect `jnc-debug.log` from KOReader's data directory (next to its other settings). Set it back to `false` afterwards.

---

## Roadmap

- [ ] Cover images
- [ ] Automatic return to the home folder after reading
- [ ] Reading-progress sync (mark parts as read)

---

## License

Released under the [MIT License](LICENSE).

## Disclaimer

This project is **not affiliated with, endorsed by, or sponsored by J-Novel Club**. It uses J-Novel Club's API to display content to authenticated, subscribed users only. No content is stored or redistributed. All series, titles, and content are the property of their respective rights holders.
