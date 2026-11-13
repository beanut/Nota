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
│   ├── NotaApp.swift         Entry point, SwiftData container, stores
│   ├── LibraryView.swift     NavigationSplitView root, sidebar icons
│   ├── SidebarView.swift     Smart collections + folders
│   ├── NotesBrowser.swift    Filter chips, grid, search, menus
│   ├── NoteCard.swift        Card + PaperThumbnail
│   ├── NewNoteSheet.swift    Paper and page size for a new note
│   ├── NoteEditorView.swift  Hosts InkCanvasEditor, saves the note
│   └── Theme/                InkTheme.nota, model colours → NotaUI inks
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

## Design system

Colour, type, spacing, radius and elevation tokens, the icon set and shared controls live in **NotaUI**; the app and InkKit use tokens only. See [DESIGN.md](DESIGN.md).

## InkKit

The drawing engine: raw Pencil input, nib model, Catmull-Rom smoothing, pen / pencil / highlighter / eraser / lasso, undo/redo, pan and zoom, pages, and a debug HUD. How it works: [Packages/InkKit/README.md](Packages/InkKit/README.md).

```swift
import InkKit

let notebook = InkNotebook()                     // one US Letter page (612 × 792 pt)
notebook.addPage(size: .a4.landscape)            // presets: Letter, Legal, Tabloid, A3, A4, A5
notebook.addPage(size: .inches(width: 5, height: 7))   // or any custom size (1–200 in per side)
InkCanvasEditor(notebook: notebook)
```

- **Pages** – `InkNotebook` is an ordered list of `CanvasDocument`s with add / insert / remove / move and navigation. Each page has its own paper size, ink and undo history. A notebook always keeps at least one page.
- **Page size** – `PageSize` is in points (1/72 in) and defaults to Letter. Custom sizes can be given in inches, millimetres or points. Resizing a page keeps the ink where it is; ink past the new edge is hidden, not deleted.
- **Editor** – the page sits on a grey desk, fitted to the view. Ink is clipped to the page, and strokes can't start off it (the eraser and lasso can). The page bar under the page moves between pages, adds pages (any size, including custom) and deletes them. Its size menu resizes this page or every page.

Run the package tests on an iPad simulator (InkKit and NotaCore have test targets). The library's rules (smart collections, filter chips, search, sorting, Recently Deleted, folder order and `Date.libraryLabel`) live in NotaCore's `Library.swift` rather than the app's views, so NotaCore's tests cover them against an in-memory SwiftData store:

```bash
cd Packages/InkKit && xcodebuild test -scheme InkKit -skip-testing:InkKitBenchmarks -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

```bash
cd Packages/NotaCore && xcodebuild test -scheme NotaCore -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

InkKit's performance benchmarks and latency budgets (page open under 150 ms for 5k strokes, under 2 ms of live-stroke work per touch event) run nightly in CI against a stored baseline; run them locally with `scripts/run-benchmarks.sh bench-output`. See [Packages/InkKit/README.md › Benchmarks](Packages/InkKit/README.md#benchmarks).

## Known limitations

- Ink isn't saved to disk yet; strokes last until the app quits. InkKit can encode a page as a `.ink` file
  (NOT-5), but nothing writes one until NOT-6. Note metadata is persisted with SwiftData.
- Pages are shown one at a time; there's no continuous vertical scroll or page-thumbnail sidebar yet.
- A note's page sizes aren't stored in SwiftData, so a note reopened after relaunch starts as Letter pages.
- Thumbnails are placeholders, not renders of the ink.
- No PDF import/viewer, sharing or sync yet.

## Next steps

1. Per-note ink persistence: write each page's `.ink` file into the note package (NOT-6).
2. Real thumbnails from the committed bitmap.
3. PDF import and annotation, page thumbnails and drag-to-reorder.
