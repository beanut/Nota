# Nota

An iPad note-taking app. The **Library** organises notebooks into smart collections and folders; opening a note gives you an Apple Pencil canvas powered by **InkKit**, a local Swift package extracted from the InkCanvas prototype.

## At a glance

| | |
| --- | --- |
| Platform | iPadOS 17.5+, iPad only |
| Language | Swift 5 mode, SwiftUI + SwiftData |
| Bundle ID | `com.bernard.nota` |
| Dependencies | `InkKit` (local package in `Packages/InkKit`), no third-party dependencies |
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
├── Nota/                     App target (file-system-synchronised group)
│   ├── NotaApp.swift         Entry point, SwiftData container, InkStore
│   ├── LibraryView.swift     NavigationSplitView root
│   ├── SidebarView.swift     Smart collections + folders
│   ├── NotesBrowser.swift    Filter chips, grid, search, menus
│   ├── NoteCard.swift        Card + PaperThumbnail
│   ├── NoteEditorView.swift  Hosts InkCanvasEditor
│   ├── InkStore.swift        Per-note CanvasDocument cache
│   ├── Models.swift          Note, Folder, enums
│   └── SampleData.swift      First-launch seed
└── Packages/InkKit/          Drawing engine (Swift package)
```

## InkKit

The drawing engine: raw Pencil input, nib model, Catmull-Rom smoothing, pen / pencil / highlighter / eraser / lasso, undo/redo, pan and zoom, pages, and a debug HUD.

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

Run the package tests on an iPad simulator:

```bash
cd Packages/InkKit && xcodebuild test -scheme InkKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

## Known limitations

- Ink isn't saved to disk yet; strokes last until the app quits. Note metadata is persisted with SwiftData.
- Pages are shown one at a time; there's no continuous vertical scroll or page-thumbnail sidebar yet.
- A note's page sizes aren't stored in SwiftData, so a note reopened after relaunch starts as Letter pages.
- Thumbnails are placeholders, not renders of the ink.
- No PDF import/viewer, sharing or sync yet.
- InkKit is a copy of the InkCanvas sources, so engine fixes must be made in both places for now.

## Next steps

1. Codable stroke serialisation and per-note persistence.
2. Real thumbnails from the committed bitmap.
3. Make InkCanvas depend on the InkKit package.
4. PDF import and annotation, page thumbnails and drag-to-reorder.
5. A test target for the app's models, filters and date labels (InkKit has one).
