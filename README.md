# Nota

An iPad note-taking app. The **Library** organises notebooks into smart collections and folders; opening a note gives you an Apple Pencil canvas powered by **InkKit**, a local Swift package extracted from the InkCanvas prototype.

## At a glance

| | |
| --- | --- |
| Platform | iPadOS 17.5+, iPad only |
| Language | Swift 5 mode, SwiftUI + SwiftData |
| Bundle ID | `com.bernard.nota` |
| Dependencies | Local packages in `Packages/` (see below), no third-party dependencies |
| Tested on | iPad Pro 11-inch and 13-inch (M5) simulators only; not yet run on a physical iPad |

## Build & run

```bash
xcodebuild -project Nota.xcodeproj -scheme Nota -destination 'generic/platform=iOS Simulator' build
```

Or open `Nota.xcodeproj`, pick an iPad simulator and Run. On first launch the library is seeded with 3 folders and 42 sample notes.

## Layout

```
Nota/
├── Nota.xcodeproj
├── Nota/                     App target: composition, navigation and scenes only
│   ├── NotaApp.swift         Entry point: library and note window scenes, shared container and stores
│   ├── LibraryView.swift     NavigationSplitView root, sidebar icons, the window's open notes
│   ├── SidebarView.swift     Smart collections + folders
│   ├── NotesBrowser.swift    Filter chips, grid, search, menus, drag to a new window
│   ├── NoteCard.swift        Card + PaperThumbnail
│   ├── NewNoteSheet.swift    Template, paper and page size for a new note
│   ├── NoteEditorView.swift  Hosts InkCanvasEditor, saves the note, window menu
│   ├── NoteSplitView.swift   Two notes side by side in one window
│   ├── NoteWindow.swift      A note in a window of its own
│   ├── NoteCommands.swift    Keyboard shortcuts for windows and split notes
│   ├── PresentationScene.swift  External display / AirPlay scene: shows InkKit's PresentationMirror
│   └── Theme/                InkTheme.nota, model colours → NotaUI inks
├── Config/Nota-Info.plist    Info.plist keys the build settings can't express (merged with the generated one)
└── Packages/
    ├── InkKit/               Drawing engine: input, brushes, rendering, pages, editor view
    ├── NotaCore/             Domain: Note, Folder, library filters and sorting, DocumentStore, note package + manifest, sample data
    ├── NotaDocuments/        Cover thumbnails and paper templates (PDF and import/export later)
    └── NotaUI/               Design system: tokens, icons, shared controls
```

### Dependency rule

```
InkKit      NotaUI          ← depend on nothing of ours
   ↑           ↑
NotaCore       │            ← depends on InkKit only
   ↑           │
NotaDocuments ─┘            ← feature packages: NotaCore (+ InkKit, NotaUI), never each other
   ↑
Nota (app)                  ← the only place that sees everything
```

Each package's `Package.swift` lists exactly these dependencies, so breaking the rule is a build error, and CI runs `scripts/check-dependency-rule.sh` to catch imports that would only compile inside the app build. InkKit's editor is themed with `InkTheme` rather than importing NotaUI; the app supplies `InkTheme.nota`. More feature packages from the architecture doc (NotaAudio, NotaSync, NotaIntelligence, NotaAI, NotaHandwriting) are created when their first code lands.

The InkCanvas prototype ([beanut/InkCanvas](https://github.com/beanut/InkCanvas)) is a thin demo app on this InkKit, referenced by local path: check it out next to this repository (`../Nota/Packages/InkKit`).

## Windows

Nota supports multiple windows, so it works in Split View, Slide Over and Stage Manager:

- **Library windows** show the sidebar and grid. Each keeps its own section and open notes and restores them with its scene (`@SceneStorage`, through NotaCore's `NoteWorkspace`).
- **Two notes in one window:** the editor's window menu (the split icon) opens another note beside the open one; each side has its own Pen Case and a close button.
- **A note in its own window:** *Open in New Window* from a note's context menu or the editor's window menu, or drag a note card to the side or edge of the screen (the drag carries a `NoteActivity`).
- **The same note open twice stays in step:** every window shares one SwiftData container and one `DocumentStore`, so both show the same `InkNotebook`, and each canvas on a page redraws when another one changes it.
- **Keyboard:** ⌥⌘O opens the note in a new window, ⌥⌘\\ swaps the two notes, ⇧⌘W closes the note (⌘N is still New Note). Hold ⌘ to list them.

## Design system

Colour, type, spacing, radius and elevation tokens, the icon set and shared controls live in **NotaUI**; the app and InkKit use tokens only. See [DESIGN.md](DESIGN.md).

## InkKit

The drawing engine: raw Pencil input, nib model, Catmull-Rom smoothing, pen / pencil / highlighter / shapes / text / tape / eraser / lasso / laser pointer, an on-screen ruler and protractor, with a built-in brush set (ballpoint, fineliner, fountain pen, brush pen, marker, dashed and dotted pens, HB and soft pencils, round and chisel highlighters), a pen tray of saved pens, quick sizes and colours per tool, a colour picker (spectrum, hex, eyedropper, palettes, recent colours) and a brush editor, undo/redo, pan and zoom, pages, and a debug HUD. How it works: [Packages/InkKit/README.md](Packages/InkKit/README.md).

```swift
import InkKit

let notebook = InkNotebook()                     // one US Letter page (612 × 792 pt)
notebook.addPage(size: .a4.landscape)            // presets: Letter, Legal, Tabloid, A3, A4, A5
notebook.addPage(size: .inches(width: 5, height: 7))   // or any custom size (1–200 in per side)
InkCanvasEditor(notebook: notebook)
```

- **Pages** – `InkNotebook` is an ordered list of `CanvasDocument`s with add / insert / remove / move and navigation. Each page has its own paper size, ink and undo history. A notebook always keeps at least one page.
- **Page size** – `PageSize` is in points (1/72 in) and defaults to Letter. Custom sizes can be given in inches, millimetres or points. Resizing a page keeps the ink where it is; ink past the new edge is hidden, not deleted.
- **Templates** – each page has a `PageTemplate`: blank, narrow / college / wide ruled, small and large grid, dotted, Cornell, music staff, isometric, to-do, weekly and monthly planners, or any PDF or image, on white, cream or dark paper. Templates are drawn as vectors (crisp at every zoom, real lines in an exported PDF) and expose their line metrics for handwriting layout. The page bar's template pill changes this page or every page; the library's Template menu changes a whole note.
- **Pictures and stickers** – the Pen Case's Insert menu puts photos on the page from Photos, the camera or Files,
  or pastes them; they can also be dropped onto the page. A picture's menu crops it to a rectangle or freehand
  (and back), and sets its opacity; it's moved, resized (keeping its shape), rotated, layered and written over like any object.
  Each picture is stored once in the note package's `assets/` and decoded at the size it's shown. Save as
  Sticker keeps any lasso selection (ink or pictures) in an app-wide sticker collection to place again on any
  page.
- **Objects** – besides ink, a page holds objects (`PageObject`: shapes, text, images and tape), each with a frame, a transform and a z-order, drawn between the template and the ink (tape is drawn over the ink). Shapes (`ShapeObject`) are the first real kind: the shape tool, or drawing with a pen or pencil and holding the Pencil still, snaps a rough stroke to a line, arrow, rectangle, ellipse, triangle, polygon or curve, recognised on the device, and a selected shape is reshaped by its handles. Text boxes (`TextObject`) are typed with the keyboard or written into with the Pencil (Scribble): the text tool makes one with a tap (or a drag to set its width), and a floating format bar sets the typeface, size, bold / italic / underline, alignment, bullets, numbers, checkboxes and indent; the Pen Case's colours colour the selected text. Text boxes are moved, rotated, layered and recoloured like any object (resizing one rewraps its text), their text is found by the library's search, and an exported PDF keeps it as real text. There's also a test object, `PlaceholderObject` (More › Add Test Object). The lasso selects ink and objects together (or only one of them), by loop, rectangle or tap; the selection box's handles move, resize and rotate them, and its menu cuts, copies, pastes (onto any page of any note), duplicates, recolours, thickens or thins, brings to front or sends to back, and takes a screenshot; a selection can be dragged out to other apps as an image. Every change goes on the page's one undo stack.
- **Tape** – the tape tool (`TapeObject`) covers part of the page with a strip of tape, dragged from end to end (snapping level, upright or to 45°) in the Pen Case's tape colours, plain, striped or grid. Tape is drawn over the ink, so it hides writing as well as paper and objects: a study aid. A tap on tape with any tool but the lasso and the eraser reveals it (a faint dashed outline over what it covers) or hides it again; the tape tool's options reveal or hide all the page's tape. Each strip's state is saved with the note; the lasso moves, rotates, resizes, recolours and deletes tape like any object, and every change is one undo step.
- **Ruler** – the Pen Case's ruler button shows a ruler over the canvas (touch and hold it for the protractor). One finger moves it, two turn it (snapping to every 15°), and it shows its angle. A pen, pencil or highlighter stroke that starts on it or within 28 pt of an edge is drawn exactly along that edge (round the protractor's arc, or along its baseline), and while it's drawn its length shows by the Pencil in centimetres of page (1 pt = 1/72 in), or the angle it sweeps round the protractor. The ruler isn't saved: it stays while the editor is open.
- **Laser pointer and presenting** – the laser tool draws a glowing line that fades after about a second (or, in Dot mode, a dot that follows the touch) and never writes on the page. When an external display or AirPlay screen is connected, it shows the page being worked on alone (no chrome, read-only, fitted to the screen) with the laser on it, instead of mirroring the whole iPad screen; the editor says it's presenting.
- **Scrolling** – More › Scroll Direction shows pages one at a time with sideways swipes (Horizontal) or all of them in one column scrolled vertically (Vertical), saved for every editor. In vertical scrolling only the pages in view get a canvas, so a 300-page note scrolls as smoothly as a short one; pinch to zoom, and writing near the bottom of the last page adds the next one.
- **Page sidebar** – the page bar's pages button opens thumbnails of every page: tap one to go to it, drag to reorder, and duplicate, rotate (ink and all), delete, or copy or move pages to another note, one page from its context menu or several with Select.
- **Editor** – the page sits on a grey desk, fitted to the view. Ink is clipped to the page, and strokes can't start off it (the eraser and lasso can). The page bar under the page moves between pages, adds pages (any size, including custom) and deletes them. Its size menu resizes this page or every page. The eraser erases pixel by pixel (Precision), the parts of strokes it passes over (Standard) or whole strokes, optionally only highlighter or only pencil ink, and can switch back to the previous tool afterwards.
- **Zoom window** – More › Zoom Window opens a magnified writing panel above the page bar for a box on the page, for small, neat handwriting. Every tool works in it. Writing into the panel's shaded right-hand zone moves the box along the line, and at the end of the line on to the next one, following the page template's ruling. Drag the box by its tab, resize it (and so the magnification) by its corner knob, or use the panel's back, on and new-line buttons.

Run the package tests on an iPad simulator (InkKit and NotaCore have test targets). The library's rules (smart collections, filter chips, search, sorting, Recently Deleted, folder order and `Date.libraryLabel`) live in NotaCore's `Library.swift` rather than the app's views, so NotaCore's tests cover them against an in-memory SwiftData store:

```bash
cd Packages/InkKit && xcodebuild test -scheme InkKit -skip-testing:InkKitBenchmarks -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

```bash
cd Packages/NotaCore && xcodebuild test -scheme NotaCore -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

InkKit's performance benchmarks and latency budgets (page open under 150 ms for 5k strokes, under 2 ms of live-stroke work per touch event) run nightly in CI against a stored baseline; run them locally with `scripts/run-benchmarks.sh bench-output`. See [Packages/InkKit/README.md › Benchmarks](Packages/InkKit/README.md#benchmarks).

## Known limitations

- Each note is a `.nota` package (manifest + one `.ink` file per page with ink + one `.json` objects file per
  page with objects + one file per picture in `assets/`) that `DocumentStore` autosaves
  about a second after each change, when the editor closes and when the app leaves the screen. Undo history
  isn't saved. Pages load a whole note at a time (decoded off the main thread); the 8 most recent notes stay
  in memory. Vertical scrolling draws only the pages in view, but a note's pages are still all read when it
  opens.
- A note's cover is re-rendered when its editor closes, so a note whose editor was open when the app was
  killed shows its previous cover until it's next opened and closed.
- The library index (SwiftData) is rebuilt from packages at launch if notes are missing from it, with title,
  dates, page count and template; folders, favourites and tints aren't in packages, so they're lost then.
- In vertical scrolling each page is still its own canvas: a stroke stops at the bottom of its page rather
  than flowing onto the next (NOT-89), and the zoom window isn't offered.
- Rotating a page clears its undo history.
- Pixel-eraser cuts belong to the page, not the strokes they cut: moving, copying or bringing to front a stroke
  that was partly pixel-erased shows it whole again in its new place (or order). The standard and stroke
  erasers don't have this problem.
- Pasting takes Nota's own selections and pictures copied in other apps; text copied from another app can't be
  pasted onto the page yet (it can be pasted into a text box being edited, as plain text). A selection dragged
  out of Nota can't be dropped back onto a page (drops from inside the app are ignored).
- Pictures (NOT-23): Take Photo needs a camera, so it's untested (disabled in the simulator); dropping and
  picking from Photos have only been tried on the simulator. Pictures no page uses are deleted from a note's
  `assets/` the next time it's opened, not when they're removed. Stickers are kept on this device only, like
  the pen tray.
- Tape, the ruler, the laser and presenting (NOT-24) have only been tried on the simulator: the external
  display scene and the mirror are unit-tested but haven't been shown on a real external display or AirPlay
  screen, and the ruler's two-finger turn and Pencil-on-ruler writing need a physical iPad (NOT-12). Ink shows
  on the external display as each stroke finishes, not while it's drawn. The zoom window's panel doesn't show
  tape, and the ruler doesn't guide strokes written in the zoom window.
- Shapes (NOT-20), text boxes (NOT-22), pictures (NOT-23) and tape (NOT-24) are the only real object types so far. Shape recognition is tuned on synthetic strokes,
  not yet on real handwriting (NOT-12), and a shape is hit anywhere in its bounds, so a diagonal line can be
  selected from the empty corners of its box. The zoom window's panel doesn't show objects, and the pixel eraser's live preview paints
  paper over them until the stroke commits (objects are never erased).
- Text boxes: Scribble (writing into a box with the Pencil) is the system's and hasn't been tried on a
  physical iPad yet (NOT-12). The on-screen keyboard can cover a box low on the page; the page doesn't
  scroll it into view. Undo while typing undoes typing; the page's undo takes back a whole editing session.
  Resizing a box changes the width its text wraps at, never the text's size (that's the format bar's).
- A note's page sizes aren't stored in SwiftData, so a note reopened after relaunch starts as Letter pages.
- Thumbnails are placeholders, not renders of the ink.
- No PDF import/viewer, sharing or sync yet. A PDF-kind note opens beside a notebook like any other note, but shows the canvas until the PDF viewer lands. PDFs and images can be used as page templates (the PDF's first page), and `PageRenderer.pdf(of:)` exports pages as PDF, but the app has no export button yet.
- A note open in two places shares its current page and undo history: turning the page or undoing in one turns or undoes it in the other.
- The two notes in a split window always take half the width each.
- Apple Pencil gestures, palm rejection, hover and scribble gestures (NOT-28) are tuned on the simulator
  only; their thresholds need a real Pencil 2 / Pencil Pro (NOT-12). Barrel roll is shown while hovering
  but doesn't steer a nib yet: the fountain pen, marker and chisel highlighter (NOT-17) hold their nib at a
  fixed angle.
- The built-in brushes (NOT-17) are tuned on the simulator with synthetic input, not yet on a physical
  iPad with Pencil (NOT-12).
- Saved pens, quick sizes and colours, custom brushes, palettes and recent colours (NOT-18) are kept on
  this device only (`Application Support/InkKit/PenTray.json`); the model is ready for sync but nothing
  syncs yet. The tool you were last using, and its colour and width, aren't restored at launch.

## Next steps

1. Real thumbnails from the committed bitmap.
2. PDF import and annotation.
