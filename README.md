# Nota

An iPad note-taking app. The **Library** organises notebooks into smart collections and folders; opening a note gives you an Apple Pencil canvas powered by **InkKit**, a local Swift package extracted from the InkCanvas prototype.

## At a glance

| | |
| --- | --- |
| Platform | iPadOS 17.5+, iPad only |
| Language | Swift 5 mode, SwiftUI + SwiftData |
| Targets | `Nota` (`com.bernard.nota`, production) and `Nota Staging` (`com.bernard.nota.staging`, test data) |
| Dependencies | `InkKit` (local package in `Packages/InkKit`), no third-party dependencies |
| Tested on | iPad Pro 11-inch (M5) simulator only; not yet run on a physical iPad |

## Build & run

```bash
xcodebuild -project Nota.xcodeproj -scheme Nota -destination 'generic/platform=iOS Simulator' build
```

Or open `Nota.xcodeproj`, pick a scheme and an iPad simulator, and Run.

| Scheme | Display name | Data |
| --- | --- | --- |
| `Nota` | Nota | Production: starts with an empty library and only holds your own notes. |
| `Nota Staging` | Nota Staging | Testing: on first launch the library is seeded with 3 folders and 42 sample notes. |

Both targets build from the same `Nota/` sources. Staging compiles with the `STAGING` flag, read by `AppEnvironment`. Different bundle IDs give each app its own SwiftData store and UserDefaults, so both can be installed side by side.

```bash
xcodebuild -project Nota.xcodeproj -scheme "Nota Staging" -destination 'generic/platform=iOS Simulator' build
```

## Layout

```
Nota/
├── Nota.xcodeproj
├── Nota/                     App target (file-system-synchronised group)
│   ├── NotaApp.swift         Entry point, SwiftData container, InkStore
│   ├── AppEnvironment.swift  Production vs staging switch
│   ├── LibraryView.swift     NavigationSplitView root
│   ├── SidebarView.swift     Smart collections + folders
│   ├── NotesBrowser.swift    Filter chips, grid, search, menus
│   ├── NoteCard.swift        Card + PaperThumbnail
│   ├── NoteEditorView.swift  Hosts InkCanvasEditor
│   ├── InkStore.swift        Per-note CanvasDocument cache
│   ├── Models.swift          Note, Folder, enums
│   └── SampleData.swift      First-launch seed (staging only)
└── Packages/InkKit/          Drawing engine (Swift package)
```

## InkKit

The drawing engine: raw Pencil input, nib model, Catmull-Rom smoothing, pen / pencil / highlighter / eraser / lasso, undo/redo, pan and zoom, and a debug HUD.

```swift
import InkKit

let document = CanvasDocument()          // one per page
InkCanvasEditor(document: document, showsDebugHUD: false)
```

## Known limitations

- Ink isn't saved to disk yet; strokes last until the app quits. Note metadata is persisted with SwiftData.
- Page count is metadata only; the canvas is a single infinite page.
- Thumbnails are placeholders, not renders of the ink.
- No PDF import/viewer, sharing or sync yet.
- InkKit is a copy of the InkCanvas sources, so engine fixes must be made in both places for now.

## Next steps

1. Codable stroke serialisation and per-note persistence.
2. Real thumbnails from the committed bitmap.
3. Make InkCanvas depend on the InkKit package.
4. Pages, PDF import and annotation.
5. A test target for models, filters and date labels.
