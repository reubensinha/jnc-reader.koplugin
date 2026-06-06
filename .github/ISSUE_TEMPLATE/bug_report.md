---
name: Bug report
about: Report a problem with JNC Reader
title: ""
labels: bug
---

**What happened**
A clear description of the problem.

**Steps to reproduce**
1.
2.
3.

**Expected behavior**


**Device & versions**
- Device / OS (e.g. Kobo Clara, Kindle PW, Android 16):
- KOReader version:
- JNC Reader version (see `_meta.lua`):

**Debug log (very helpful)**
Set `local DEBUG = true` near the top of `main.lua`, restart KOReader, reproduce the
issue, then attach `jnc-debug.log` from KOReader's data directory. Set it back to
`false` afterwards.

> ⚠️ The log should not contain your password or auth token, but please skim it and
> remove anything personal before attaching.

**Notes**
- Is it a specific series/part? (Manga is not supported.)
- JNC membership tier, if it might affect access:
