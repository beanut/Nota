# Plan

A short summary of where Nota is going, so agents and new contributors don't have to leave the repo to find
out. **[Linear](https://linear.app/nota-on-inkkit/project/nota) is the source of truth**: if this file and
Linear disagree, Linear wins, and this file should be fixed.

_Last updated: 2026-11-17._

## Milestones

| | Milestone | Outcome |
| --- | --- | --- |
| | M0 · Foundations | Ink persists to disk, the codebase is modular, CI runs on every push, and the app is verified on a physical iPad. |
| | M1 · Ink & Editor | Data-driven brush engine and the full editing toolset: shapes, text, images, lasso v2, templates, continuous scroll, Pencil gestures. |
| **▶** | **M1.5 · Canvas Performance** | Tiled, cached, incrementally updated ink instead of one screen-sized bitmap redrawn whole: edits, zoom and page entry within a frame budget on large pages, bounded memory, live-ink budgets held. |
| | M2 · Library & Documents | PDF import and annotation, import/export, handwriting recognition and search, library organisation. |
| | M3 · Audio & Sync | Audio recording with ink replay, on-device transcription, CloudKit sync, sharing. |
| | M4 · AI Platform | AI gateway, device auth, quotas, subscriptions, NotaAI client package, prompt registry and evals. Can run in parallel with M1–M3. |
| | M5 · AI Features | Brush Studio, handwriting synthesis and dictate-to-handwriting, Ask Nota, summaries, flashcards, maths, diagram clean-up. |
| | M6 · Beta & Launch | TestFlight beta, performance hardening, accessibility, localisation, App Store submission. |

## Current: M1.5 · Canvas Performance

The code is in, as a stack of pull requests: benchmarks and budgets (NOT-98), the render architecture
(NOT-99), the canvas split into input, viewport and render coordinator (NOT-100), a spatial index (NOT-101),
page-space tiles (NOT-102), a render scheduler (NOT-103), dirty-rect edits (NOT-104), progressive zoom levels
(NOT-105), tiles kept across edits and launches (NOT-106), continuous scrolling on the tiles (NOT-107), bounded
stroke geometry (NOT-108), template and objects as tiles (NOT-109), live ink handed to the tiles (NOT-110), and
the close-out that removed the old render path and recorded new baselines (NOT-112). The Metal tile fill
(NOT-111) was left out: NOT-99 deferred it. On the simulator the pixel-erase, gesture-frame, pan, page-entry and
memory budgets are met; undo (~45 ms against 16) and stroke erase (~0.55 s) on the dense page and time to sharp
after a pinch to a new level (~0.2 s against 0.15) are still bound by drawing strokes (InkKit README ›
Benchmarks).

Left to close the milestone, all needing a person with an iPad and Pencil:

1. [NOT-112](https://linear.app/nota-on-inkkit/issue/NOT-112) · Run the benchmarks and the on-device checklist on
   a physical iPad, and confirm the budgets there.
2. [NOT-80](https://linear.app/nota-on-inkkit/issue/NOT-80) · Re-scope M6's performance hardening to what's left.

## Earlier: M0 · Foundations

Done: design system (NOT-15), real thumbnails (NOT-8), persisted page sizes (NOT-7), packages (NOT-9),
CI (NOT-10), ink benchmarks and budgets (NOT-13), library tests (NOT-11), the `.ink` file format (NOT-5),
note packages on disk with autosave (NOT-6).

Next, in order:

1. [NOT-12](https://linear.app/nota-on-inkkit/issue/NOT-12) · Verify and tune on a physical iPad with Apple Pencil.
2. [NOT-14](https://linear.app/nota-on-inkkit/issue/NOT-14) · Release pipeline: signing and automated TestFlight builds.
3. [NOT-85](https://linear.app/nota-on-inkkit/issue/NOT-85) · Decide the minimum iPadOS version and supported devices.

Also open: the editor redesign in progress outside the milestones,
[NOT-86](https://linear.app/nota-on-inkkit/issue/NOT-86) and [NOT-87](https://linear.app/nota-on-inkkit/issue/NOT-87).

M1's first issues, the data-driven brush engine ([NOT-16](https://linear.app/nota-on-inkkit/issue/NOT-16)),
the built-in brush set ([NOT-17](https://linear.app/nota-on-inkkit/issue/NOT-17), pending tuning on a
physical iPad), the pen tray with quick sizes and colours, colour picker and brush editor
([NOT-18](https://linear.app/nota-on-inkkit/issue/NOT-18)), the page object model with transforms and unified undo
([NOT-19](https://linear.app/nota-on-inkkit/issue/NOT-19)), continuous scrolling with the page sidebar
([NOT-26](https://linear.app/nota-on-inkkit/issue/NOT-26)), the shape tool with hold-to-snap recognition
([NOT-20](https://linear.app/nota-on-inkkit/issue/NOT-20), pending tuning on a physical iPad), lasso v2: cut, copy,
paste across pages and notes, duplicate, recolour, thickness, arrange, screenshots and drag-out
([NOT-21](https://linear.app/nota-on-inkkit/issue/NOT-21)), and typed text boxes with rich formatting, checklists and
search ([NOT-22](https://linear.app/nota-on-inkkit/issue/NOT-22), in review), and images and stickers: insert, crop,
resize, rotate ([NOT-23](https://linear.app/nota-on-inkkit/issue/NOT-23), in review), and tape, ruler and laser
pointer tools with presentation mode ([NOT-24](https://linear.app/nota-on-inkkit/issue/NOT-24), in review), and links,
bookmarks and the note outline ([NOT-31](https://linear.app/nota-on-inkkit/issue/NOT-31), in review), and writing
across page boundaries in vertical scrolling ([NOT-89](https://linear.app/nota-on-inkkit/issue/NOT-89), in review),
landed early.

## Keeping this current

Update this file in the PR that changes it, not separately:

- **When an issue listed here closes**, move it to "Done" and pull the next one up from Linear's order.
- **When a milestone completes**, move the ▶ marker and rewrite "Current" for the next milestone.
- **When Linear's plan changes** (reordered, added or cut issues), mirror it here and bump the date.

Keep it short: one line per milestone and at most five "next" issues. Detail belongs in Linear.
