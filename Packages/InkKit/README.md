# InkKit

Nota's drawing engine: raw Apple Pencil input, the nib model and brushes, rendering, the page model and the editor view. No PencilKit and no third-party dependencies.

**Dependency rule:** InkKit depends on nothing of ours. It knows about strokes, brushes and pages, not notes, folders, SwiftData or the design system. Two apps use it: Nota, and the InkCanvas demo ([beanut/InkCanvas](https://github.com/beanut/InkCanvas)), which references this package by path.

## Using it

```swift
import InkKit

let notebook = InkNotebook()                     // one US Letter page
InkCanvasEditor(notebook: notebook, title: $title)
    .inkTheme(myTheme)                           // optional; defaults to InkTheme.standard
```

## Theming

The editor's chrome (Pen Case, page bar, tool options, quick palette), the paper and desk, and the Pen Case's ink presets come from an `InkTheme` in the environment. `InkTheme.standard` uses system colours and SF Symbols on white paper; Nota passes `InkTheme.nota`, built from NotaUI tokens. The controls themselves (icon button, swatch, divider, slider row, floating bar) are in `InkChrome.swift` and match NotaUI's sizes.

## Source files

| File | Responsibility |
| --- | --- |
| `InkCanvasEditor.swift` | The public editor: canvas, Pen Case, page bar, HUD and quick palette, with page swiping |
| `InkNotebook.swift` | Ordered pages (`CanvasDocument`s) with add / insert / remove / move, navigation and page sizes |
| `CanvasDocument.swift` | One page's strokes, size, template and undo/redo command stack (`add`, which carries any pixel-eraser splits, `erase`, `clear`) |
| `PageSize.swift` | Paper sizes in points: presets, custom sizes in in / mm / pt |
| `PageTemplate.swift` | `PageTemplate` (pattern, spacing, margins, paper colour, custom background), the built-in presets, `PaperColor` / `PaperPalette` |
| `TemplateLayout.swift` | Each pattern's measurements, and `lineMetrics(on:)`: baselines, line spacing, writing area and regions for the handwriting layout engine |
| `TemplateRenderer.swift` | Draws a template as Core Graphics vectors (canvas, thumbnails, PDF), skipping pattern outside the visible rect |
| `TemplateArtwork.swift` | A custom background's bytes (a PDF page or an image), decoded once; PDF pages stay vector |
| `TemplateView.swift` | The canvas layer that redraws the template at the current zoom, between the paper and the ink |
| `TemplateMenu.swift` | The page bar's template pill: built-ins, paper colour, PDF or image, use for all pages |
| `ViewTransform.swift` | Canvas → view mapping, zoom limits and page-swipe detection |
| `CanvasView.swift` | `UIView` that handles raw touches, gestures, `UIPencilInteraction` and hover. Owns the page, the cached committed bitmap and the lasso overlay, plus the `UIViewRepresentable` bridge |
| `CanvasView+ZoomWindow.swift` | The zoom window on the canvas: showing the panel and box, mapping panel touches onto the page, moving the box, rendering the panel; the hover and eraser cursors |
| `CanvasView+EraserSplits.swift` | Finding the ink strokes a pixel-eraser stroke cuts through |
| `ZoomWindow.swift` | `WritingLines` (a page's ruling) and `ZoomWindow`, the box's geometry: auto-advance, line return, dragging and resizing |
| `ZoomPanelView.swift` | The zoom window's writing panel and the box overlay drawn on the page |
| `MultiFingerTapRecognizer.swift` | Two- and three-finger taps (undo, redo) without multi-tap delay |
| `LiveInkView.swift` | The live ink layer: a grid of tile layers showing the in-progress stroke and strokes awaiting rasterization, plus the hover/eraser cursor |
| `StrokeRenderer.swift` | Nib model (pressure → width, tilt → ellipse + opacity), centripetal Catmull-Rom, outline geometry (tangent strips and nib stamps), drawing, hit-testing, and the incremental `LiveStroke` |
| `PencilTexture.swift` | Graphite grain for the pencil |
| `StrokeSplitter.swift` | Splits ink strokes that a pixel eraser cuts clean through into separate strokes |
| `Lasso.swift` | Freeform and rectangle lasso regions and hit-testing |
| `CommittedRenderer.swift` | The committed bitmap and its full re-render (geometry for uncached strokes built in parallel, culling, drawing in parallel bands), shared by the canvas and the benchmarks |
| `CommittedRaster.swift` | A page's committed layer kept compressed with the page, so reopening it restores the pixels instead of re-rendering |
| `InputRecording.swift` | `InkInputRecording`, the recorded-Pencil-input format; the recorder the canvas feeds; and the replayer the benchmarks drive |
| `PageRenderer.swift` | Renders a page snapshot (template + ink) to an image off the main actor (thumbnails), or pages to a PDF |
| `Stroke.swift` | `Stroke`, `StrokePoint`, `BrushStyle`, tool enums, `RGBA` |
| `CanvasController.swift` | `ObservableObject` tool state shared by SwiftUI and UIKit |
| `ToolbarView.swift` | Pen Case, tool options, pressure & tilt settings, Pencil Pro quick palette |
| `PageBar.swift` | Page bar (page size and template pills) and the custom page size sheet |
| `InkTheme.swift` / `InkChrome.swift` | The theme and the controls built from it |
| `PencilHUD.swift` | Debug HUD, throttled telemetry, sample-rate counter |

## Page templates

Each page has a `PageTemplate`: a pattern (blank, ruled, grid, dots, Cornell, music staff, isometric, to-do,
weekly or monthly planner), its spacing and margins in points, a paper colour (white, cream, dark) and
optionally a custom background, a PDF page or an image whose bytes live in a `TemplateArtwork` beside it.
`PageTemplate.Preset` lists the built-ins (narrow / college / wide ruled, small and large grid, …).

```swift
notebook.setTemplate(PageTemplate.preset(.cornell).on(.cream), forPageAt: 0)
notebook.setTemplateForAllPages(.preset(.dots))
let metrics = page.template.lineMetrics(on: page.pageSize)   // baselines, spacing, writing area, regions
let pdf = PageRenderer.pdf(of: notebook.pages.map { $0.snapshot() }) { theme.palette(for: $0) }
```

- **Vectors everywhere.** `TemplateRenderer` draws with Core Graphics paths and CoreText, so the same code
  draws the canvas, thumbnails and PDF export. On the canvas a `TemplateView` between the page layer and the
  ink redraws it at the current transform whenever the page pans or zooms (never while ink is written),
  with a one-pixel minimum line width, so it's crisp at every zoom. Repeating patterns only build what's on
  screen, so a zoomed-in corner of a 200-inch page stays cheap. PDF backgrounds are drawn as PDF.
- **Ink stays separate.** The committed ink bitmap is transparent over the paper, so changing a template
  doesn't re-render ink, doesn't touch `revision` and isn't an undoable edit. The live layer's backdrop for
  multiply (highlighter) previews draws the template too.
- **Colours come from the theme.** `InkTheme.paperPalettes` maps each `PaperColor` to fixed (non-dynamic)
  surface, rule, accent and label colours; `PaperPalette.standard` is the default. Paper doesn't follow dark
  mode.
- **Line metrics** (`TemplateLineMetrics`) describe where writing goes, for the handwriting layout engine
  (NOT-65).
- **Known gaps:** the pixel eraser's live preview paints plain paper colour (the lines reappear when the
  stroke commits); a custom PDF background uses the file's first page.

## Architecture

### Data model

- `StrokePoint { location, force, altitude, azimuth, timestamp }`: `location` is in **canvas space**, independent of zoom and pan. `force` is normalised to 0…1 (`force / maximumPossibleForce`).
- `Stroke { id, tool, color, style, points }`: `tool` is an `InkKind` (`pen`, `pencil`, `highlighter` or `pixelEraser`). `style` is a **snapshot** of the brush settings taken when the stroke began, so later slider changes never restyle existing ink.
- View transform: canvas → view is a uniform scale plus translation with no rotation, so azimuth angles are the same in both spaces.

### Rendering pipeline

1. **Committed layer.** All finished strokes live in one screen-resolution bitmap. A finished stroke is drawn onto it incrementally. A full re-render happens only on undo, erase, clear, or the end of a zoom/pan.
   - A full re-render is Core Graphics fills, about 2 ms per handwritten word at the fitted zoom, so it uses every core: missing geometry is built in parallel, then the bitmap is split into horizontal bands filled at once, each drawing in page order the strokes that reach it. A 5k-stroke page takes about 2 s that way.
   - So a page isn't re-rendered when it reopens. When the canvas leaves a page it hands the document a `CommittedRaster`: the committed bitmap at the fitted zoom, LZFSE-compressed (about 5 MB for 5k strokes). The canvas tracks which document revision its bitmap holds, so this is normally the image already on screen; when it isn't (mid-erase, strokes not yet committed, left zoomed after an edit), the page is drawn again in the background. Reopening at the same revision, size and fitted transform decompresses it straight into the new bitmap, about 15 ms, and builds the strokes' geometry in the background for erasing and later re-renders. Any edit drops the raster.
2. **Live layer.** The in-progress stroke is drawn in a separate view made of 256 pt tile layers, so per-frame work doesn't grow with stroke length, screen size or zoom:
   - The stroke is cut into chunks of 8 segments. A chunk that is complete, and whose points are no longer waiting for estimated-property updates, is **baked**: rasterized once into a per-stroke bitmap for each tile it reaches, and never filled again.
   - Only the **hot** part (the newest chunk or two and the provisional tail) is re-filled each frame, and only in the tiles under the new ink, clipped to the invalidated rect.
   - Baking uses `.copy`, the same "later run replaces earlier" rule as the committed path, so live and committed pixels match.
   - A late estimate that changes a baked chunk re-bakes just the tiles it touches. Tiles are freed once every stroke has been committed.
3. **During pinch/pan** the cached bitmap is transformed. If a full re-render takes under 5 ms it is re-rendered live instead, and it is always re-rendered crisply when the gesture ends.

### Stroke geometry

- Samples are smoothed with **centripetal Catmull-Rom**, which avoids cusps and overshoot when samples are unevenly spaced.
- Each segment is cut into straight steps by **curvature, not distance**: enough to stay within 0.02 canvas points of the spline, to keep each step's turn small, and to keep the nib from changing more than about 10% per step, but never denser than half a nib width. A fast, nearly straight segment is one or two steps however long it is.
- At every sub-step the nib is an **ellipse**:
  - Pressure sets the width: `width = max × (minRatio + (1 − minRatio) × pressure^γ)`.
  - When tilt is on, the ellipse stretches along azimuth, widens and loses opacity as altitude drops (shading starts below 60° and saturates at 15°).
- The ink of each step is the **convex hull of two consecutive nib ellipses**. It is emitted as the quad between the ellipses' common tangents, with consecutive quads welded into one **strip** polygon. The nib ellipse itself (a **stamp**) is added only where the strips alone would leave a gap: the stroke's two caps, sharp bends, fast tapers, and wherever a strip has to break (a change of alpha, or a new chunk).
- This matters for speed: Core Graphics' fill time follows vertex count and overlap depth, not pixel count. Emitting every hull whole gave about 8× the vertices, all overlapping.
- Pieces with the same alpha are unioned into one non-zero-winding path, so overlapping joints never double up. When tilt varies alpha along a stroke, runs are drawn with `.copy` inside a transparency layer. This prevents seams.
- **Highlighter** composites with *multiply*, so ink underneath stays readable. The **pixel eraser** is a `destinationOut` stroke in the same list, so it's undoable.
- **Pixel erasing splits strokes.** When a pixel-eraser stroke is committed, every ink stroke under it is checked: wherever the ink's whole cross-section (the nib's extent across the direction of travel) lies inside the union of the pixel erasers above it, the stroke is cut. Each cut strictly inside a stroke replaces it with separate `Stroke`s (fresh IDs, same style snapshot), so the stroke eraser removes only the piece it touches. Erasing a stroke's end only shortens it. The split is part of the eraser's `add` command, so one undo restores the original stroke. Partial erases that only together sever a line count as a cut too.

### Zoom window

More › Zoom Window shows a writing panel at the bottom of the canvas that magnifies a box on the page, for writing small and neatly. The page is refitted above the panel so the box is never under it.

- **Input.** A touch that begins in the panel's ink area is mapped through the panel's transform instead of the page's (`inputTransform`), so the stroke is stored in page space inside the box like any other, and every tool (pens, both erasers, the lasso) works there. Width-in-view rules (sample spacing, the eraser's on-screen size, lasso slop) use the panel's scale.
- **Rendering.** The panel shows the box the way the canvas shows the page: a committed image of just the strokes that reach the box, rendered on its own queue whenever the page's committed bitmap changes (one render at a time), under its own `LiveInkView` showing the stroke being written. A finished stroke stays on the panel's live layer until a render that includes it lands, so it never blinks out. With the panel closed none of this exists and the ink path is unchanged; with it open, live strokes are filled in both live layers.
- **Following the line.** `ZoomWindow` keeps the box on a line of the page's `WritingLines` (derived from the page's template by `WritingLines.lines(for:on:)`, which falls back to `WritingLines.standard` for templates without even rows; the host can override per page), with the baseline 72% of the way down. A stroke written in the panel that reaches the right-hand 30% moves the box on so the stroke ends a quarter of the way in; at the end of the line the next one sends it to the start of the next line. Dragging the box by its tab snaps it to the nearest line; its corner knob resizes it, which changes the magnification.

### Input handling

- `coalescedTouches(for:)` delivers every Pencil sample (about 240 Hz) instead of one per 120 Hz frame.
- `predictedTouches(for:)` only extends the drawn tail and is discarded on the next real event.
- `touchesEstimatedPropertiesUpdated` patches refined force and tilt into both live and committed strokes.
- Pan, pinch and swipe recognizers accept only `.direct` (finger) touches, and they won't begin while the Pencil is down (palm rejection).
- `UIPencilInteraction` handles double-tap (pre-17.5 and 17.5+ APIs) and Pencil Pro squeeze. `UIHoverGestureRecognizer` previews nib size and tilt while hovering.
- The system three-finger editing gestures are disabled (`editingInteractionConfiguration = .none`) so the app's own undo/redo swipe takes over.

### Simulator fallback

Under `#if targetEnvironment(simulator)`, a single `.direct` touch acts as the Pencil:

- Pressure comes from drag speed, low-passed so the width changes smoothly.
- Altitude comes from the *Simulated altitude* slider (More › Pressure & Tilt).
- Azimuth is fixed at −45°.
- Panning requires two fingers.

## Debug HUD

This is a toggleable overlay, throttled to about 30 Hz so SwiftUI never sits on the input path. It shows:

- Input state: `pencil ✎`, `pencil hover`, `finger ×N`, `sim pencil` or `idle`
- Raw force and maximum, plus a normalised pressure bar
- Altitude and azimuth in degrees, plus a tilt compass. The compass line points along azimuth, and its length is cos(altitude).
- Hover height (`zOffset`)
- Samples/s and events/s, predicted-touch count, pending estimated updates, stroke count

## Benchmarks

`Tests/InkKitBenchmarks` holds XCTest performance benchmarks with latency budgets (Architecture §6), so
later features (textured brushes, PDF, continuous scroll) can't quietly make ink feel worse. They time
InkKit's own code paths, the ones `CanvasView` runs, on a model iPad Pro 13-inch screen (1032 × 1376 pt at 2×):

| Metric | What it times | Budget |
| --- | --- | --- |
| `stroke_geometry.*` | Building every corpus stroke's outline (spline, nib hulls, runs) from scratch | – |
| `live_event.p50/p95/p99_ms` | One touch event of a replayed stroke: appending its coalesced samples, finalizing segments, rebuilding the predicted tail, applying estimate updates, and drawing the dirty live-layer tiles | p95 < 2 ms |
| `live_event.long_stroke.*` | The same for the longest stroke (a 4 s tilted shading scribble), first quarter vs last quarter: work mustn't grow with length | last-quarter p95 < 2 ms |
| `page_open.5k_ms` | Reopening a 5k-stroke page: a fresh committed bitmap with the page's `CommittedRaster` restored into it | < 150 ms |
| `page_open_cold.{1,5,20}k_ms` | Opening a page with no raster (first time shown at this size): a fresh committed bitmap, every stroke's geometry built, the page drawn | – |
| `page_raster.*` | Compressing a 5k-stroke page's committed layer when the page closes (in the background), and its size | – |
| `full_redraw.5k_ms` | Re-rendering a 5k-stroke page with geometry cached (undo, erase, end of zoom) | – |
| `memory.6x.*` | Physical footprint with a 5k page open at 6× zoom while the corpus is written on top: cached geometry, committed bitmap, live tiles. Measured from a settled baseline (free memory returned first), so earlier benchmarks don't change it | – |

### Recorded input

The benchmarks replay `*.inkrec.json` recordings from `Tests/InkKitBenchmarks/Fixtures` through
`InputReplayer`, which feeds `LiveStroke` and a `LiveInkView` event by event exactly as the canvas does
(coalesced batches, predicted tails, late force/tilt estimates). Pages for the page-level benchmarks are
tiled from the same strokes.

- **Record** on an iPad: More menu › *Record Pencil Input*, write, turn it off, then *Share Pencil Recording…*.
  Drop the file into `Fixtures/` and record new baselines in the same change.
- The fixture in the repository today, `handwriting.synthetic.inkrec.json`, is **synthetic**
  (`SyntheticPencil`: 240 Hz samples on 120 Hz events, predictions, estimate updates, cursive-like words,
  a highlighter pass and a shading scribble), because nothing has been recorded on a physical iPad yet.
  Regenerate it with `TEST_RUNNER_INK_BENCH_WRITE_FIXTURE=<path>` and `-only-testing:InkKitBenchmarks/FixtureGeneration`;
  `TEST_RUNNER_INK_BENCH_PREVIEW_DIR=<dir>` renders every fixture to a PNG.

### Running them

```bash
scripts/run-benchmarks.sh bench-output          # Release, iPad Pro 13-inch simulator; ~5 min
scripts/bench-compare.py bench-output/results.json --baseline Packages/InkKit/Benchmarks/baselines/apple-m1-pro-simulator.json
```

Run them in Release (`-configuration Release ENABLE_TESTABILITY=YES`, which the script does); a Debug build
reports numbers but the compare script refuses them. In Xcode, each benchmark also shows its `measure` time.
`TEST_RUNNER_INK_BENCH_ENFORCE_BUDGETS=1` makes the tests themselves fail on a missed budget.

### Nightly job and baselines

`.github/workflows/benchmarks.yml` runs the suite nightly (and on pull requests that change the benchmarks;
the nightly schedule is temporarily commented out until a CI baseline is committed),
uploads `results.json` as an artifact, and writes the comparison table to the job summary. It fails when a
metric is more than 10% worse than `Benchmarks/baselines/ci-macos-15.json` (changes under a small noise
floor are ignored), or when a budget the baseline met is missed. Budgets the baseline already misses are
shown as known, so they don't keep the job red and hide new regressions.

Baselines are per environment: numbers from a GitHub runner and from a laptop aren't comparable. To
record one, run the workflow by hand with *record baseline* ticked and commit the `baseline` artifact,
or locally `scripts/bench-compare.py results.json --write-baseline <path>`.

## Tests

```bash
xcodebuild test -scheme InkKit -skip-testing:InkKitBenchmarks -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

A physical-iPad verification checklist (pressure, tilt, sample rate, eraser, lasso) lives in the InkCanvas README.
