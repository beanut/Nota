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
| `InkNotebook.swift` | Ordered pages (`CanvasDocument`s) with add / insert / remove / move, navigation and page sizes; several pages at once (move, duplicate, remove, rotate, append) for the page sidebar; adding a page when writing reaches the end |
| `ContinuousPageLayout.swift` | `PageLayoutMode` (paged or continuous, saved in `UserDefaults`) and the continuous column: page frames, the pages in view, the current page |
| `ContinuousCanvasView.swift` | Continuous vertical scrolling: a scroll view over the column, with an embedded canvas for each page in view, and strokes carried across page boundaries |
| `PageSeam.swift` | Writing across a page boundary: how far past its page each page takes part in a stroke (its reach, from the brush's taper and nib), and which pieces are kept |
| `CanvasView+Embedded.swift` | A canvas as one page among several: placed by the host, transparent around its page, taking touches only on it |
| `PageSidebar.swift` | The page sidebar: thumbnails (rendered in the background, cached), jump, reorder, select, duplicate, rotate, delete, copy or move to another note (`PageDestination`, `PageSender`) |
| `LassoOverlayView.swift` | Draws the lasso path and the selection outline over the canvas |
| `CanvasDocument.swift` | One page's strokes, objects, size, template and one undo/redo command stack for ink and objects, each command optionally in a gesture's group (`editGroup`, for strokes across pages) (`add`, which carries any pixel-eraser splits, `erase` (strokes and objects), `replace` for a standard erase, `clear`, `transform` (move, scale, rotate strokes and objects), `addObject`), and the views observing it: a page can be on screen in several canvases at once (a note open in two windows), and each hears every change, whichever made it. Outside InkKit, `observeChanges(_:onChange:)` reports each committed change (never mid-stroke), for autosave. Keeps the page's `StrokeIndex` in step with every change to its strokes and objects, and its `inkVersion` and `inkChanges` (where each change of the ink went, mid-gesture ones too) |
| `InkChanges.swift` | `InkChangeLog`: the rect each recent change of a page's ink version touched (the reach of the strokes it added, removed or changed), so tiles are refilled only there (NOT-104) |
| `StrokeIndex.swift` | Where a page's strokes and objects are: a uniform grid of 32 pt cells (`SpatialGrid`) answering "what may reach this rect?" in page (z) order, without walking the page. Used by culling, the erasers, lasso and tap selection and circle-to-select; tiles query it per tile |
| `TestingSupport.swift` | `@_spi(Testing)` hooks for other packages' tests to put ink on a page (`drawTestStroke(through:)`, `undoForTesting()`) |
| `PageSize.swift` | Paper sizes in points: presets, custom sizes in in / mm / pt |
| `PageTemplate.swift` | `PageTemplate` (pattern, spacing, margins, paper colour, custom background), the built-in presets, `PaperColor` / `PaperPalette` |
| `TemplateLayout.swift` | Each pattern's measurements, and `lineMetrics(on:)`: baselines, line spacing, writing area and regions for the handwriting layout engine |
| `TemplateRenderer.swift` | Draws a template as Core Graphics vectors (canvas, thumbnails, PDF), skipping pattern outside the visible rect |
| `TemplateArtwork.swift` | A custom background's bytes (a PDF page or an image), decoded once; PDF pages stay vector |
| `TemplateView.swift` | The canvas layer that redraws the template at the current zoom, between the paper and the ink |
| `FollowingVectorView.swift` | Base of the template and object layers: drawn sharp when the canvas settles, scaled in between (until it no longer covers the page in view or is magnified past 1.5×), like the committed ink (NOT-105) |
| `TemplateMenu.swift` | The page bar's template pill: built-ins, paper colour, PDF or image, use for all pages |
| `ViewTransform.swift` | Canvas → view mapping, zoom limits and page-swipe detection |
| `CanvasView.swift` | The canvas `UIView`: its layers, the gesture recognizers, `UIPencilInteraction`, hover, the HUD and the lasso overlay. Composes input, viewport and the render coordinator below; redraws from the document when another canvas on the same page changes it |
| `CanvasView+Input.swift` / `CanvasInput.swift` | Input: touch phases, coalesced and predicted samples, estimated-property updates (`EstimateTracker`), palm rejection and finger ink, feeding `LiveStroke`; a finished stroke goes to the render coordinator |
| `CanvasView+Viewport.swift` / `CanvasViewport.swift` | Viewport: the view transform, the fitted transform, pan and pinch steps, page swipes, the slide back to the fitted page, cancelling an incidental pan or pinch. Pan and pinch steps (and the fitted transform) keep the offset on whole device pixels, so a gesture settles on the pixel grid with no extra render |
| `RenderCoordinator.swift` | The committed side: which tiles the view needs, filling missing and stale ones off the main thread, showing them (the current level over the level before it and the resting level while it fills in), drawing finished strokes (`PendingStroke`) into the tiles they reach, the geometry cache, revision tracking, the settled state, the page's `TileRaster` and the zoom panel's renders. Knows nothing of touches |
| `RenderScheduler.swift` | `RenderScheduler` (`.shared`), `RenderJob`, `RenderPriority`, `RenderCancellation`: the one place render work runs (tiles, finished strokes, the zoom panel, the presentation mirror, thumbnails, geometry warm-up, page rasters), by priority, cancellable, on a bounded number of workers, published in batches on the main thread at most once a frame |
| `TileCache.swift` | `TileLevel`, `TileKey` (256-pixel page-space tiles), `Tile` (pixels and the page revision they show) and `TileCache`, every page's tiles shared by every canvas and zoom panel, evicted least recently used under a byte budget |
| `TileFiller.swift` | `TileFiller` and `CoreGraphicsTileFiller` (drawing strokes into a tile), `TileBitmap` (tile contexts in page points with the grain pinned to the page; assembling tiles into an image), `InkSnapshot` (the ink a render job draws from), `GeometryStore` (stroke geometry the jobs of one fill share and build), `TileRaster` (a page's fitted tiles, compressed, for reopening it) |
| `TileLayers.swift` | `TileLayerGrid`: one level's tiles on screen as `CGImage` layer contents, placed by one transform |
| `PencilSettings.swift` | `PencilSettings` (double-tap and squeeze actions, finger drawing, palm rejection, handedness, scribble toggles) and their persistence, quick-palette placement, and `PalmRejector` |
| `PencilSettingsView.swift` | The More menu's Apple Pencil settings |
| `Scribble.swift` | Circle-to-select detection and the strokes a loop selects |
| `CanvasRepresentable.swift` | The `UIViewRepresentable` bridge from `InkCanvasEditor` to `CanvasView` |
| `CanvasView+ZoomWindow.swift` | The zoom window on the canvas: showing the panel and box, mapping panel touches onto the page, moving the box, rendering the panel; the hover and eraser cursors |
| `CanvasView+EraserSplits.swift` | Finding the ink strokes a pixel-eraser stroke cuts through; stroke and standard erasing, and the eraser cursor |
| `ZoomWindow.swift` | `WritingLines` (a page's ruling) and `ZoomWindow`, the box's geometry: auto-advance, line return, dragging and resizing |
| `ZoomPanelView.swift` | The zoom window's writing panel and the box overlay drawn on the page |
| `MultiFingerTapRecognizer.swift` | Two- and three-finger taps (undo, redo) without multi-tap delay |
| `LiveInkView.swift` | The live ink layer: a grid of tile layers showing the in-progress stroke and strokes awaiting rasterization, plus the hover/eraser cursor |
| `BrushDescriptor.swift` | `BrushDescriptor`: every brush parameter, its legal range and `clamped()`, and lenient JSON |
| `BuiltInBrushes.swift` | The built-in brush set (pens, pencils, highlighters, pixel eraser), `sized` and `personalized` (the Pressure & Tilt settings on top of a brush's character) |
| `BrushPicker.swift` | The tool options' brush picker (built-in brushes, then the user's), with sample strokes drawn by the engine (`BrushPreview`) |
| `BrushParameter.swift` | Every numeric `BrushDescriptor` parameter as the brush editor shows it: label, slider range inside the legal range, units, when it's shown, get and set (setters always leave the brush clamped) |
| `BrushEditorView.swift` | The brush editor sheet: live preview and a control for every parameter |
| `PenColor.swift` | `PenColor`, an exact 24-bit sRGB colour stored as `"#RRGGBB"`, with hex and HSB conversion |
| `PenTray.swift` | `PenTray` and its parts (`SavedPen`, `ToolPresets`, `ColorPalette`, `PenKind`): saved pens, quick sizes and colours, custom brushes, palettes and recent colours, with lenient JSON |
| `PenTrayStore.swift` | `PenTrayStore`, which keeps the tray and saves it on every change (`.shared` in Application Support) |
| `PenTrayView.swift` | The pen tray popover |
| `ColorPickerView.swift` | The colour picker popover (spectrum, hue, hex, eyedropper, recent colours, palettes) and the Pen Case's colour well |
| `EyedropperOverlay.swift` / `CanvasView+Eyedropper.swift` | The eyedropper's overlay, loupe and banner, and sampling one device pixel of the canvas as drawn |
| `StrokeRenderer.swift` | Nib model (from the descriptor: pressure → width, tilt → ellipse + opacity, taper, speed), centripetal Catmull-Rom, the hull path (tangent strips and nib stamps) and the stamp path, drawing, hit-testing, and the incremental `LiveStroke` |
| `PencilTexture.swift` | Procedural paper-tooth grain (scale, contrast, seed) for grain-textured brushes such as the pencil |
| `WaxRenderer.swift` | The raster brush (the crayon) on the GPU: each nib stamp lays wax on the page's paper tooth roughened by the stroke's own grain, max-blended into a field, drawn into any context `StrokeRenderer.draw` is given |
| `WaxShaders.swift` | `WaxRenderer`'s Metal shaders, as source compiled at run time (in the background when a canvas is made), so the build doesn't need the Metal toolchain |
| `StrokeSplitter.swift` | Splits ink strokes that a pixel eraser cuts clean through into separate strokes, and works out what a standard erase leaves of a stroke |
| `Lasso.swift` | Freeform and rectangle lasso regions and hit-testing |
| `PageObject.swift` | `PageObject` (frame, transform, z-order, drawing), `PageObjectPlacement` (the shared JSON keys), `PlaceholderObject` (the test object), objects of unknown kinds |
| `ShapeObject.swift` | `ShapeObject`: lines, arrows, rectangles, ellipses, triangles, polygons and curves, their handles and snap anchors, drawing (fill, solid / dashed / dotted outline) and lenient JSON; `ShapeStyle` |
| `ShapeRecognizer.swift` | The on-device recogniser: a rough stroke to the shape it was meant to be, with angle, upright, square/circle and shape-to-shape snapping |
| `RichText.swift` | `RichText`: a text box's paragraphs of styled runs (`TextStyle`, `TextFont`), alignment, lists, checkboxes and indent; lenient JSON; round-tripping through `NSAttributedString`; list numbering (`TextMarker`) |
| `TextObject.swift` | `TextObject` (a text box: rewraps rather than stretches when resized, ticks checkboxes), `TextLayout` (TextKit 1 layout and list markers shared by drawing and the editor), page text for search |
| `TextBoxEditor.swift` / `CanvasView+Text.swift` | Editing a text box in place (`InkTextView`, formatting, Return and Tab in lists) and the text tool on the canvas (tap or drag to make a box, tap to edit, tap a checkbox to tick it) |
| `TextFormatBar.swift` | The format bar shown while a box is edited, and the text tool's options |
| `ImageAssets.swift` | `ImageAssets`: pictures' bytes by content hash (in memory until a host persists them, then read from its files), downsampled and cached bitmaps decoded in the background; `ImageDrawing` (per-thread draw options) |
| `ImageObject.swift` | `ImageObject`: a picture with a non-destructive rectangular or freehand crop and opacity, its drawing and hit-testing, lenient JSON; the pictures a page uses |
| `ImageCropView.swift` | Cropping a picture on the canvas (rectangle grips or a freehand outline) and its geometry (`ImageCropGeometry`) |
| `CanvasView+Images.swift` | Inserting pictures (Photos, camera, Files, paste, drop), their selection-menu items (Crop, Opacity, Save as Sticker), cropping, placing stickers |
| `InsertMenu.swift` | The Pen Case's Insert menu, the camera, the sticker picker and the crop bar |
| `StickerStore.swift` | `Sticker` and `StickerStore`: the app-wide sticker collection (`.shared` in Application Support) |
| `CanvasView+Scribble.swift` | Circle-to-select |
| `CanvasView+Shapes.swift` | The shape tool, draw-and-hold to snap (and sizing the snapped shape before lifting), dragging a selected shape's handles, restyling selected shapes |
| `PageObjectsFile.swift` | `PageObjectsFile`, a page's objects as `pages/<page id>.json`: format version, reading, writing |
| `Selection.swift` | `PageSelection`, `SelectionBox` and `SelectionGeometry`: lasso and tap selection of strokes and objects, the box's handles and the transforms they make; `Stroke.applying(_:)` |
| `ObjectLayerView.swift` | The canvas layer that draws the page's objects between the template and the ink |
| `CanvasView+Selection.swift` | The lasso on the canvas: selecting (with the ink / objects filter), dragging the box and its handles, deleting, adding the test object |
| `CanvasView+SelectionActions.swift` | What the lasso does with a selection: cut, copy, paste, duplicate, recolour, thickness, bring to front / send to back, screenshot, drag out as an image; its menu (`UIEditMenuInteraction`) and ⌘X / ⌘C / ⌘V / ⌘D / Delete |
| `SelectionClip.swift` | `SelectionClip`, a copied selection on the pasteboard (its format, fresh copies with new ids), and `PastePlacement`, where a paste lands |
| `SelectionAction.swift` | `SelectionAction` and `LassoSelection`: the app's own items in the selection's menu (convert to text, AI actions) |
| `CommittedRenderer.swift` | Bitmaps laid out like the committed tiles, geometry for many strokes built in parallel, and the old whole-screen render in parallel bands (only the benchmarks' whole-page timings use it now) |
| `InputRecording.swift` | `InkInputRecording`, the recorded-Pencil-input format; the recorder the canvas feeds; and the replayer the benchmarks drive |
| `PageRenderer.swift` | Renders a page snapshot (template + objects + ink + tape) to an image off the main actor (thumbnails), or pages to a PDF |
| `TapeObject.swift` / `CanvasView+Tape.swift` | `TapeObject` (a strip drawn over the ink, revealed or hidden, plain / striped / grid, lenient JSON), revealing and hiding tape on a page; the tape tool and tap-to-toggle on the canvas |
| `LinkObject.swift` / `CanvasView+Links.swift` | `LinkTarget` (a web address, a page of this note, another note or one of its pages) and `LinkObject` (a link over a selection, kept as read when its target is from a newer app); following a link with a tap and the selection menu's Add / Edit / Open / Remove Link |
| `LinkSheet.swift` | `NoteLinks` and `LinkBack` (what the host says about other notes, and Back to the note a link came from), the link sheet and the floating Back button |
| `NoteOutline.swift` / `OutlinePanel.swift` | `NoteOutline` (bookmarks and outline entries, the user's and those from a PDF's outline), the notebook's bookmark and outline edits, `LinkHistory` for Back; the page sidebar's Outline tab |
| `CanvasView+Tools.swift` | Routes the touches of the tools that draw no ink (text, tape, laser) to each tool |
| `Ruler.swift` | `Ruler` (the on-screen ruler or protractor: body, edges, angle), `RulerGuide` (an edge carried into page space, and projecting points onto it), `RulerMeasurement` (length in cm, angle swept) |
| `RulerView.swift` / `CanvasView+Ruler.swift` | Showing, moving and turning the ruler, handing Pencil touches on it to the canvas, the readout; snapping strokes to it in the input path |
| `LaserTrail.swift` / `LaserView.swift` / `CanvasView+Laser.swift` | The laser pointer: its fading trail or dot (a value), the overlay view that draws it, and the laser tool on the canvas |
| `InkPresentation.swift` | Presentation mode: `InkPresentation` (the page presented and its laser), `PresentationMirror` / `PageMirrorView` (the external display's chrome-free, fitted page) and `PageMirrorLayout` |
| `PresentingTools.swift` | The tape and laser tool options, the Pen Case's ruler button and the presenting badge |
| `Stroke.swift` | `Stroke`, `StrokePoint`, tool enums, `RGBA` |
| `InkFile.swift` | `InkPageFile`, the `.ink` page format: encoder, decoder and `InkFileError` |
| `CanvasController.swift` | `ObservableObject` tool state shared by SwiftUI and UIKit: each tool's brush, colour and width, quick sizes and colours, saved pens, the brush editor and the eyedropper |
| `ToolbarView.swift` | Pen Case, tool options, pressure & tilt settings, the Pencil quick palette |
| `PageBar.swift` | Page bar (page size and template pills) and the custom page size sheet |
| `InkTheme.swift` / `InkChrome.swift` | The theme and the controls built from it |
| `PencilHUD.swift` | Debug HUD, throttled telemetry, sample-rate counter |

## Brushes

A brush is a `BrushDescriptor`: plain, `Codable` data (Architecture §4). The built-in brushes are bundled
descriptors, so a built-in brush and one a user or a model makes go through exactly the same code. A stroke
keeps a snapshot of its descriptor, with the width and Pressure & Tilt settings of the moment applied
(`personalized(width:minimumWidthRatio:pressureExponent:tilt:)`).

```swift
var marker = BrushDescriptor.pen.sized(6, minimumRatio: 0.6)
marker.tip = .ellipse(aspect: 0.3, angle: .pi / 4)
marker.taper = .init(startLength: 12, endLength: 20)
let json = try marker.jsonData(pretty: true)        // sorted keys: equal brushes, equal bytes
let brush = try BrushDescriptor(json: json)          // lenient and clamped
```

| Parameter | Legal range | What it does |
| --- | --- | --- |
| `tip` | `round`, or `ellipse(aspect 0.05…1, angle)` | Nib cross-section; a flat nib keeps its angle |
| `size` | upper 0.05…1000 pt, lower 0…upper | Width at no pressure … full pressure |
| `pressure` | amount 0…1, exponent 0.1…5 | Pressure → position in `size` (`input^exponent`) |
| `pressureOpacity` | amount 0…1, exponent 0.1…5 | Pressure → opacity (off by default) |
| `tilt` | start 1…89°, full 0…start−1°, length 0…8, breadth 0…4, opacity loss 0…1, contact shift 0…1 | Tilt shading; a round nib follows the azimuth |
| `velocity` | amount 0…1, exponent 0.1…5 | Thinning with speed (full at 1500 pt/s) |
| `taper` | start, end 0…500 pt; minimum scale 0…1 | Narrow ends. The end taper is applied when the Pencil lifts |
| `smoothing` | 0…0.95 | Stabiliser: each sample pulled toward the stroke so far |
| `texture` | `none`, `grain(scale 0.25…8, contrast 0…1, seed)`, `bristle(count 1…64, spread 0.1…2)`, `wax(scale 0.25…8, contrast 0…1, seed)` | Procedural, never a bitmap. `wax` is a raster brush drawn with Metal (see Raster brushes) |
| `spacing` | 0, or 0.05…4 nib widths | 0 draws on the hull path; more draws stamps |
| `dash` | on 0.05…50, off 0…50 full-pressure widths | Dashes by arc length from the stroke's start; off 0 is solid. Draws on the stamp path |
| `jitter` | size, angle, opacity 0…1; scatter 0…2 nib widths; seed | Per-stamp variation (stamp path) |
| `wetness` | 0…1 | Ink pools where the nib lingers, runs dry where it hurries |
| `blend` | `normal`, `multiply`, `destinationOut` | Compositing; `destinationOut` erases |
| `opacity` | 0.02…1 | Overall opacity |

### Built-in set

Each tool offers a few brushes (tap the selected tool for its options). Fixed ids (`6E6F7461-…-0000000000NN`)
mark a brush as built in; the first in each list is the tool's default, and the original pen, pencil,
highlighter and pixel eraser kept their ids (and their looks).

| Tool | Brushes |
| --- | --- |
| Pen (`pens`) | Ballpoint (`.pen`), Fineliner, Fountain Pen (angled stub nib, soft taper, ink pooling), Brush Pen (wide pressure range, taper, thins when fast), Marker (chisel), Dashed, Dotted |
| Pencil (`pencils`) | HB Pencil (`.pencil`), Soft Pencil (coarser grain, pressure darkens, broad tilt shading), Crayon (`.crayon`: a raster brush; waxy, ragged, paper showing through where the press is light, wide tilt edge) |
| Highlighter (`highlighters`) | Highlighter (round), Chisel Highlighter |

A brush's `size.upperBound` is its default width, and each brush remembers the last width used with it.
The Pressure & Tilt settings **adjust** a brush rather than replace its character: *Minimum width* moves
the brush's own minimum-width ratio the way the setting moves from its default (0.25), so the default
leaves every brush as designed and 1 makes all of them constant width; *Response curve* scales the brush's
pressure exponent by γ / 0.6; *Tilt shading* off turns shading off. The ballpoint gets the settings'
values exactly, as the pen always did.

The brushes are tuned on the simulator with synthetic input; they still need tuning on a physical iPad
with Pencil (NOT-12).

- **Clamping.** `clamped()` pulls every parameter into its range and replaces NaN with the pen's value.
  Decoding always clamps, a missing field takes its default (a partial object like `{"tilt": {"enabled":
  false}}` keeps the rest), and an unknown enum case falls back to the pen's, so no JSON decodes to a brush
  the renderer can't draw. That's what makes model-generated brushes safe to render.
- **Two render paths**, picked from the descriptor (`renderPath`). `spacing == 0` without a bristle texture
  is the **hull path**: the nib swept continuously, exactly as before descriptors (see Stroke geometry).
  Otherwise (a spacing, a bristle texture or a dash) the **stamp path**: nib stamps spread evenly over each spline segment about `spacing` nib widths
  apart, moved by `jitter` with a generator seeded by the stamp's place in the stroke, and split into
  bristle dots by a bristle texture. A dash drops the stamps in its gaps, by the arc length the live stroke
  already keeps for the taper. Segments never depend on each other, so live and committed strokes
  match and nothing grows with stroke length.
- **Raster brushes.** A `wax` texture (the crayon) isn't filled as paths: `StrokeRenderer.draw` hands it to
  `WaxRenderer`, which draws it with Metal into whatever context it was given, so the live layer, the
  committed bitmap (band by band), page images, thumbnails and exports all get the same wax.
  - Its geometry is the stamp path's, and each stamp keeps its nib and grain (`Hull.rasterStamp`, carried
    into `StrokeRun.stamps` as `RasterStamp`s), so erasing, splitting, the lasso and hit testing treat it
    like any stroke.
  - For the part of the stroke inside the context's clip, in the context's own pixels, the stamps are drawn
    as instanced ellipses into a half-float wax field with **max** blending: each pixel keeps the most wax
    any stamp left there, whatever order or batches the stamps come in. A stamp presses evenly over most of
    its patch and lightly at the rim. A compute pass then colours the field.
  - Each stamp's fragment lays its own wax on a **tooth**: the paper's (three octaves of value noise, 1.6 pt
    cells at scale 1, from the **page position** of the pixel, which comes from its device pixel alone so
    every tile and band computes it identically) mixed with the crayon's own texture at the stamp's
    `grain` offset. Wax reaches as far into the tooth as the press does, so a light stroke or the rim
    catches only the peaks, and a firm one fills all but the deepest pits. Where a tooth cell is under a
    couple of pixels (zoomed out, thumbnails) it fades to the share of paper covered instead of aliasing.
  - **Layering fills in.** A stamp's grain is its stroke's own offset (`Stroke.waxGrain`, from `createdAt`,
    which is saved exactly and kept by eraser pieces) shifted with the direction of travel
    (`RasterStamp.headingShift`). So another stroke over the same place, or the same stroke coming back
    the other way, misses different bits of paper and fills the holes in, as wax does; the paper's deepest
    pits are shared and stay bare under heavy layering. Along one pass the grain barely changes, so a
    single stroke still shows the paper.
  - Because each pixel depends only on the stamps over it and its page position, drawing a page whole or in
    pieces gives the same pixels (a test checks it), so the grain can't shimmer as a stroke grows or move
    when it's committed or reopened.
  - **Live.** Wax at a chunk joint depends on both chunks, so a raster stroke can't bake pixels chunk by
    chunk. It bakes the **field** instead: each tile keeps the settled chunks' field on the GPU
    (`WaxRenderer.WaxField`), and a redraw adds only the hot stamps over it, so it never grows with the
    stroke's length, and max blending makes the result exactly the committed field (a test compares them,
    including with the wax landing late, as on device). Settled raster chunks go only to the field, never
    to the tile's path bake: that would paint them as pattern and mark them done, so the field would miss
    them and later wax there would leave holes.
  - The live layer **doesn't wait for the GPU**: a touch event only encodes and commits the tile's job
    (`LiveInkView.requestWax`). The pixels come back on the main queue into the tile's baked bitmap, which
    the tile draws like any baked ink. Each tile has one job out at most; dirt asked for meanwhile waits and
    goes next. So the crayon's wax shows when the GPU is done (0.5 ms p50, 1.7 ms p95 on the simulator),
    up to about a frame after the other ink would. A wait per tile cost 0.3–1.5 ms on the simulator, several
    times an event, which is why it's asynchronous. The committed layer and page images still draw
    synchronously.
  - **Fallback.** Without a Metal device, or for a region over 8192² pixels, the stroke's paths are filled
    with the grain pattern of the same scale, contrast and seed, like a pencil. A build that doesn't know
    `wax` decodes it as `none` (as it does any unknown texture) and draws the same stamps solid.
- **Built-in tools look the same.** `Tests/InkKitTests/Snapshots/` holds golden images rendered by the
  engine before descriptors; the bundled descriptors match them pixel for pixel. Re-record with
  `TEST_RUNNER_INK_SNAPSHOT_RECORD=1` only for an intended change. Each brush of the built-in set has a
  golden of its own (`brush-*.png`).

## Pen tray

The user's own pens, colours and brushes (NOT-18) are one `PenTray`: plain `Codable` data with stable ids,
an explicit order and modification dates (to the second), so it can be synced later. It holds:

- **Saved pens** (`SavedPen`): a name, a `PenKind` (pen, pencil, highlighter), a full `BrushDescriptor`
  snapshot, a `PenColor` and a width. A pen keeps its own copy of its brush, so it outlives edits to or
  deletion of the brush it was made from. Choosing one switches to its tool with exactly that brush,
  colour and width.
- **Per tool** (`ToolPresets`): the three quick sizes and the quick colours (nil means the defaults: the
  tool's width presets and the theme's inks), and the brushes made in the brush editor, which the brush
  picker lists after the built-in ones. Editing a built-in brush makes a new brush with a new id; editing
  the user's own changes it in place. An ink tool's brush never erases.
- **Colours**: palettes (`ColorPalette`, a name and unique colours) and recent colours (newest first, no
  repeats, at most 12; added by the picker when it closes and by the eyedropper).

```swift
let store = PenTrayStore.shared                  // Application Support/InkKit/PenTray.json
store.update { $0.add(SavedPen(name: "Red Fountain", kind: .pen, brush: .fountainPen,
                               color: PenColor(hex: "#D92D30")!, width: 5)) }   // saved straight away
let json = try store.tray.jsonData()             // sorted keys, ISO 8601 dates
```

`PenTrayStore` saves the whole tray (a few kilobytes) atomically on every change; every editor shares
`.shared`, so a pen saved in one window appears in the others. Reading is lenient like brushes: unknown
fields are ignored, an unreadable pen, colour or palette is skipped rather than losing the file, and a file
that isn't a tray at all is moved aside to `PenTray.unreadable.json`. It's app data, not a note: it never
goes through `.nota` packages.

**Colours** are `PenColor`s: exact 8-bit sRGB, `"#RRGGBB"` in JSON, so equal colours compare equal however
they were picked. Strokes still store `RGBA`; a stroke's colour comes from the tool's current `PenColor`.

**Eyedropper.** The colour picker's eyedropper covers the canvas with an overlay in the canvas view's
coordinate space; touching it renders the canvas's layer tree into a one-pixel bitmap at that point (one
device pixel: paper, template and ink as drawn, or the desk off the page), shown in a loupe and used on
lift. It reads what's on screen, so a highlighter over ink gives the blended colour.

**Brush editor.** `BrushParameter.all` lists every numeric descriptor parameter with a slider range inside
its legal range; a test checks every number in a descriptor's JSON has one, and that setting any value
leaves the brush clamped. The editor's preview applies the Pressure & Tilt settings like a real stroke.

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
- Objects: see Page objects below.
- `Stroke { id, color, brush, points, createdAt }`: `brush` is a **snapshot** of the `BrushDescriptor` taken when the stroke began (see Brushes), so later brush or slider changes never restyle existing ink. `createdAt` is wall-clock time (point timestamps are touch uptime), for replaying ink against audio later; pieces a pixel eraser cuts keep it.
- View transform: canvas → view is a uniform scale plus translation with no rotation, so azimuth angles are the same in both spaces.

### Ink file format

A page's ink is stored as one `.ink` file (Architecture §3), read and written by `InkPageFile`:

```swift
let file = try InkPageFile(data: data)                  // off the main actor; throws InkFileError
let page = CanvasDocument(file: file, pageSize: size)  // page size comes from the note's manifest
let saved = page.inkFile.encoded()                      // snapshot on the main actor, encode anywhere
```

Layout (v1, little-endian):

| Bytes | Field |
| --- | --- |
| 0–3 | Magic `NINK` |
| 4–7 | Major, minor version (u16 each). Readers refuse any other **major** version and read every minor version of their own |
| 8–23 | Page id (`CanvasDocument.id`) |
| 24 | Body encoding: 0 stored, 1 LZFSE. 25–27 reserved |
| 28–35 | Stored body size, decoded body size (u32 each) |
| 36–39 | CRC-32 of bytes 0–35 and the stored body |
| 40– | Body: a sequence of records |

Each record is `type u8 · payload length (varint) · payload`:

- **1, brush table** (first): every distinct `BrushDescriptor` on the page, clamped and stored once. Per brush: its JSON length (varint), then the JSON with sorted keys, so the same brush always writes the same bytes. JSON keeps the table readable across versions (a reader ignores fields it doesn't know and defaults the ones that are missing); a brush that isn't a JSON object is `corrupt`. (Before NOT-16 this record held a fixed kind code and five numbers; no file was ever written in that layout.)
- **2, stroke**, in drawing order: id (16 bytes), brush index (varint), colour (4 × f32), `createdAt` (f64 seconds since 2001), the first point's timestamp (f64), point count (varint), then six columns of zigzag varints. Points are quantised (location to 1/64 pt, force to 1/1024, altitude and azimuth to 1/1024 rad, time to 1/4096 s) and delta-encoded: x, y and time as second-order deltas (the change in step, near zero for smooth, regularly sampled input), force, altitude and azimuth as first-order. Every step is a power of two, so a decoded page re-encodes to the same bytes.
- **Any other type** is kept as it is, with its position among the strokes, and written back on save. A newer minor version adds data that must survive older apps as new record types; fields it appends to a known record are skipped by older readers (and lost if they re-save).

Bodies over 256 bytes are LZFSE-compressed when that's smaller; the decoded size may be at most 256× the stored size, so a reader can bound its allocation. Decoding checks every length, count and index against what's left and rejects non-finite numbers, so damaged or truncated input throws an `InkFileError` (`notAnInkFile`, `unsupportedVersion`, `truncated`, `checksumMismatch`, `corrupt`) and never traps. Nota stores one per page with ink in the note package (`pages/<page id>.ink`, written by NotaCore's `DocumentStore`).

### Page objects

A page holds objects as well as ink (Architecture §5): shapes, text boxes, images, tape and links.
Every object is a `PageObject`: an `id`, a `frame` in its own space, a `transform` (`CGAffineTransform`)
that puts the frame on the page, and a `zIndex`. Each type only draws itself and encodes its own fields; the
lasso, the handles, undo and storage work on that placement. There are six types: `ShapeObject` (see
Shapes below), `TextObject` (see Text boxes below), `ImageObject` (see Pictures below), `TapeObject` (see Tape
below), `LinkObject` (see Links below) and `PlaceholderObject` (More › Add Test Object), a
rectangle with a cross that exercises the layer. A type that needs to move differently overrides
`applying(_:)` (a text box keeps its letters' size).

```swift
page.addObject(PlaceholderObject(frame: CGRect(x: 72, y: 72, width: 200, height: 120), color: PenColor(rgb: 0x2563EB)))
let file = page.objectsFile                         // → pages/<page id>.json; empty: no file
let reopened = CanvasDocument(file: ink, objects: try PageObjectsFile(data: json), pageSize: size)
```

- **Layers**, bottom to top: background (paper and template), objects in `zIndex` order (`ObjectLayerView`,
  vectors at the current transform; hidden on a page without objects), ink (committed tiles and live layer),
  tape (`tapeLayer`, another `ObjectLayerView`: objects whose kind `drawsOverInk`), the laser (`LaserView`),
  overlay (lasso and selection box), the ruler. Thumbnails, screenshots and PDFs draw tape after the ink too
  (`PageRenderer.drawOverlays`). Objects are never in the committed ink tiles, so adding or moving one
  doesn't re-render ink, and the pixel eraser never erases one. The live layer's multiply backdrop draws the
  objects too, so a highlighter previews over an object as it will commit.
- **Revisions.** `objectsRevision` counts object changes, separately from `revision` (the ink's), so an
  object edit doesn't drop the page's tiles or `TileRaster`. Object-only edits notify `.objectsEdited`.
- **One undo stack.** `addObject`, deleting a selection (`erase` with strokes and objects), `clear`,
  `transform`, `replaceObjects` (a shape reshaped by a handle or restyled; `previewObjects` shows a
  drag's in-between states without recording anything) and `edit` are commands on the page's stack, so one
  undo takes back whichever came last. `edit` (pasting, duplicating, recolouring, changing thickness, bringing
  to front, sending to back) keeps the page's strokes and objects before and after (copy-on-write, so it costs
  little more than what changed) and swaps them on undo and redo. `transform`
  replaced the move-only `move`: it records the strokes and objects as they were plus the affine transform;
  undo puts the saved values back exactly, redo applies the transform to them again, so neither drifts.
- **Transforming ink** (`Stroke.applying(_:)`) maps every point, turns the azimuth and a flat nib's angle
  with any rotation, and scales the brush's widths and taper by √|det|, so ink made twice as big is drawn
  twice as thick. A rigid move or rotation leaves the brush's size untouched.
- **Selection** (`SelectionGeometry`, shared by the lasso, tap-to-select and circle-to-select): a loop or
  rectangle selects strokes whose centerline touches it and objects whose outline touches it or that hold it;
  a tap (under 8 view points of movement) selects the topmost thing under it: tape first (it covers the ink),
  then ink (it's drawn over other objects), newest first, then objects from the top down. The box is axis-aligned around the selection, or a
  single object's own frame, and follows each transform, so it rotates with what it holds. Dragging inside
  moves, a corner knob resizes in the box's own axes about the opposite corner (never flipping, at least
  8 view points a side), the knob above rotates about the centre. Pixel-eraser strokes and objects of unknown
  kinds are never selected. The lasso's filter (Tool Options › Selects: Ink, Objects) limits what loops,
  rectangles and taps pick up; text and images get options of their own as they land.

#### Lasso actions

When a selection is made (or a drag of it ends), its menu appears above it: Cut, Copy, Paste, Duplicate,
Delete; Color (the pen's quick colours, or the highlighter's for highlighter ink alone), Thickness (Thicker /
Thinner, ×1.25 a step, the menu staying open), Arrange (Bring to Front / Send to Back), Crop and Opacity (for
pictures), Save as Sticker, Take Screenshot; then the app's `SelectionAction`s. A tap on the selection shows it again. Each action is one undo step.

- **Clipboard.** Copy puts a `SelectionClip` on the pasteboard as `app.nota.inkkit.selection` (JSON: the ink
  as an `.ink` file and the objects as an objects file, base64, plus the bytes of any pictures, so they
  survive a relaunch or a trip to another note) next to a PNG of the selection for other apps,
  so a selection reaches other pages, notes and windows. Paste makes copies with new ids (objects go through
  the objects file, so every kind copies the same way) and selects them. `PastePlacement`: a tap on nothing,
  with nothing selected, offers Paste there, centred on the tap; otherwise the clip lands in its own place
  (so a cut moves it to another page or note in position), a 24 pt step further for each copy already there
  (the originals on the page count as one, and so does each earlier paste of the same clip), and centred in
  view if that place is off screen. Duplicate copies a step down and right without touching the pasteboard.
- **Style.** Recolouring keeps each stroke's opacity (a highlighter stays see-through) and recolours objects
  through `PageObject.recolored(_:)` (kinds without a colour keep theirs). Thickness scales each brush's widths
  and tapers (`BrushDescriptor.scaled(by:)`), as resizing does. With the lasso and a selection, the Pen Case's
  quick colours recolour it too.
- **Order.** Ink is always over objects, so Bring to Front moves strokes to the end of the ink and objects to
  the top of the objects (renumbering `zIndex`), each keeping its own order.
- **Images.** Take Screenshot shares the page under the selection box, paper and template included
  (`PageRenderer.image(of:region:scale:palette:)`). Holding still on the selection with a finger or the Pencil
  lifts it out as a PNG to drop into other apps (`UIDragInteraction`, armed only while something is selected).
- **Hook.** `InkCanvasEditor(…, selectionActions:)` adds items after InkKit's, with an `isAvailable` check;
  `perform` gets a `LassoSelection`: the page id, bounds, the selected ink as an `InkPageFile`, the objects and
  `image(scale:)`.

#### Objects file

`pages/<page id>.json`, written beside the page's `.ink` file only when the page has objects (NotaCore's
`DocumentStore` removes it when the last one goes), so notes from before objects open unchanged and older
apps, which only look at `.ink` files, leave it alone:

```json
{ "formatVersion": 1, "pageID": "…",
  "objects": [ { "kind": "placeholder", "id": "…", "frame": { "x": 72, "y": 72, "width": 200, "height": 120 },
                 "transform": [1, 0, 0, 1, 0, 0], "zIndex": 0, "color": "#2563EB" } ] }
```

- `formatVersion` 1. A reader refuses a higher version (`unsupportedVersion`); the app sets such a file
  aside, as it does a damaged `.ink` file, rather than overwrite it. New object kinds don't need a new
  version.
- Every object has `kind` and the shared keys (`PageObjectPlacement`): `id`, `frame`, `transform`
  (`[a, b, c, d, tx, ty]`, default identity) and `zIndex` (default 0), next to its own fields. A missing
  frame, a non-finite number, a negative size, a transform that can't be inverted or a repeated id is
  `corrupt`.
- An object of a kind this version doesn't know is kept verbatim, in its place in the stack, and written back;
  it isn't drawn or selectable.
- Objects are written in stacking order with sorted keys: the same page always writes the same bytes.

#### Shapes

`ShapeObject` (file kind `"shape"`) is a line, arrow, rectangle, ellipse, triangle, polygon or curve. A
rectangle or ellipse is its `frame` (rotated ones keep an upright frame and turn with the transform); every
other kind is its `points`, which are also its handles, and its frame is their bounds. The outline is drawn in
page space at `lineWidth` × √|det| of the transform, so it scales with the shape like ink but never stretches
unevenly; it's solid, dashed or dotted, and closed kinds can be filled (`fill` at `fillOpacity`, 0.3 by
default). Its fields are `shape`, `points` (`[[x, y], …]`), `strokeColor`, `lineWidth`, `lineStyle`, `fill`
and `fillOpacity`; reading is lenient (an unknown `shape`, or points that don't fit it, read as a rectangle
in the same frame; a bad colour or width takes the default).

- **Making them.** The shape tool (Pen Case) turns every stroke into a shape when the Pencil lifts, in its own
  colour, width, line style and fill; a stroke that isn't a recognisable shape becomes a smooth curve through
  it. With the pen or pencil, **draw and hold** the Pencil still at the end of a stroke (about 0.45 s, the
  same hold as circle-to-select, which wins over ink it encircles): if the stroke is a shape it snaps to one
  in the stroke's colour and width (dashed or dotted with a dashed or dotted brush), with a haptic tick.
  Keep the Pencil down to size it: a line or arrow's end follows the Pencil, other shapes scale about their
  centre. Hold-to-snap only takes confident shapes (handwriting with sharp corners stays ink) at least 30 view
  points across, never applies to the highlighter, and can be turned off (Apple Pencil › Draw and hold to
  snap shapes).
- **Recognition** (`ShapeRecognizer`, pure geometry, nothing leaves the device). An open stroke is a line if
  it stays within 8% of its chord, an arrow if a straight shaft is followed by short barbs folding back from
  its end, otherwise a curve if it's smooth (no turn sharper than 50° between samples). A stroke whose end
  comes back within 22% of its size to its start is closed (overshoot trimmed); its corners (Ramer–Douglas–
  Peucker, then near-straight vertices dropped) are compared with a principal-axis ellipse fit: three corners
  are a triangle, four with near-right angles a rectangle, other four-, five- to eight-corner outlines
  polygons, as long as the corners fit better than the ellipse; otherwise a good ellipse fit is an ellipse.
- **Snapping.** Lines and arrows within 6° of a multiple of 45° are straightened onto it; rectangles and
  ellipses within 8° of upright stand upright; near-equal sides make a square or a circle. Ends and corners
  within 12 view points of another shape's anchor (corners, ends, edge midpoints, centres) land on it, while
  drawing, while sizing a snapped shape and while dragging a handle.
- **Editing.** Select a shape with the lasso: a point-based shape shows its handles as solid accent knobs;
  drag one to reshape it (one undo step). A line or arrow shows only its two ends, and moves by dragging along
  it; rectangles and ellipses reshape with the selection box. With shapes selected, the lasso's options change
  their line style, outline colour and fill.
- **Limits.** Tap-to-select and the lasso hit a shape anywhere in its bounds, so a diagonal line is
  selectable in the empty corners of its box. Recognition thresholds are tuned on synthetic strokes; they
  still need tuning with real handwriting on a physical iPad (NOT-12).

#### Text boxes

`TextObject` (file kind `"text"`) is rich text (`RichText`) wrapped at `frame.width`; `frame.height` always
follows the text. Its one field is `text`: `{"paragraphs": [{"runs": [{"text", "font", "size", "color",
"bold", "italic", "underline"}], "alignment", "list", "checked", "indent"}]}`, with defaults left out. Fonts
are the system font's four designs (sans serif, serif, rounded, monospaced); lists are bullets (•, ◦, ▪ by
level), numbers (counted per level, restarting under each item and after anything else) and checkboxes, up to
six levels deep. Reading is lenient: unknown fonts, lists or alignments and out-of-range sizes take the
default, so text is never lost.

- **Making and editing.** With the text tool, tap the page for a box `TextObject.defaultWidth` (320 pt) wide
  with the caret at the tap, or drag to set its width; tap a box to edit it with the caret where you tapped,
  or tap one of its checkboxes to tick it without opening it. New text takes the tool's typeface and size
  (Tool Options) and the Pen Case colour. While a box is edited (`TextBoxEditor`) a `UITextView` set up exactly
  like `TextLayout` sits over it at its scale and rotation, rendering sharply at the current zoom, and the
  box is hidden from the object layer, so nothing moves when editing starts or ends. Keyboard and Scribble
  both write into it; Bold / Italic / Underline (⌘B / ⌘I / ⌘U) work too, and pasted text takes the box's
  style. Return continues a list (a new checklist item starts unticked); Return on an empty item steps out a
  level, then ends the list; Tab and ⇧Tab indent and outdent. Tapping elsewhere, Done, another tool, undo or
  leaving the page finishes editing as one undoable edit: the box is added, changed, or removed if it was
  emptied. UIKit drops custom attributes from typed text now and then, so after every change the editor gives
  each paragraph one layout again (`repairParagraphs`).
- **Drawing.** TextKit 1 (`NSLayoutManager`) both draws the box and lays out the editor, with list markers
  drawn in the margin by `TextLayout.drawMarkers`. Layouts are cached on the main thread (the object layer
  redraws every box on every frame of a pan); thumbnails and PDFs, drawn elsewhere, lay out afresh. In a PDF
  the glyphs are real text, so it can be searched and copied.
- **Selecting.** The lasso moves, rotates, layers, recolours (every run), copies and deletes text boxes like
  any object. Resizing one rewraps it: `applying(_:)` keeps the text's scale and turns the stretch into a new
  wrap width (at least `minimumWidth`, 40 pt).
- **Search.** `CanvasDocument.text` and `PageObjectsFile.text` are the plain text of a page's boxes; NotaCore
  copies them onto `Note.textContent`, which the library's search matches.

#### Pictures

`ImageObject` (file kind `"image"`) names its picture by `asset`, the SHA-256 of its bytes, with the picture's
oriented `pixelSize`; its own fields are also `crop` (unit image space, absent for the whole picture), `mask`
(a freehand outline in unit image space) and `opacity` (absent for 1, at least 5%).

- **Bytes.** `ImageAssets.shared` holds pictures by id: in memory from insertion until a host writes them
  somewhere and calls `didPersist`, then read from that file (`register(fileURL:for:)`). InkKit never knows
  where; Nota's `DocumentStore` keeps them in each note package's `assets/`. Because ids are content hashes,
  a picture placed twice, or pasted into another note, is stored once per note. Clips (copy, paste, stickers)
  carry the bytes of their pictures.
- **Display.** Pictures are drawn by the object layer, never on the ink path. A picture is decoded with ImageIO
  as a thumbnail (orientation applied) at the next power of two above the size it's shown at (from 256 px),
  and cached (`NSCache`, 192 MB). The canvas never waits for a decode (`ImageDrawing.defersDecoding`): it
  draws the nearest size already decoded, or a faint stand-in, and redraws when the right size arrives.
  Thumbnails, copies and screenshots wait for it; PDFs embed pictures at 3 px per point.
- **Inserting.** The Pen Case's Insert menu (photo icon): Photos (`PhotosPicker`, up to 10, original bytes so
  HEIC stays HEIC), Take Photo (`UIImagePickerController`; disabled without a camera, as in the simulator),
  Files (`fileImporter`), Paste Image, and Stickers. Pictures also paste with ⌘V or the selection menu's Paste
  when the pasteboard holds no lasso clip, and drop onto the page (`UIDropInteraction`; drags from inside the
  app are ignored). A new picture is a pixel per half point, shrunk to 60% of the visible page at most,
  centred in view (or where it was dropped), selected with the lasso.
- **Cropping.** A selected picture's menu: Crop, Freehand Crop and Reset Crop. Cropping hides the picture from
  the object layer and shows `ImageCropView` over the canvas: the whole picture dimmed, the part kept at full
  strength, with grips at the corners and edges (rectangle) or an outline drawn around what to keep
  (freehand). The crop bar switches mode, resets, cancels or finishes; Done is one undoable edit
  (`replaceObjects`). Cropping changes the frame, never where the picture is, and can be changed again later.
  A freehand-cropped picture is only hit inside its outline (`PageObject.contains(_:tolerance:)`).
- **Resize, rotate, layer, opacity.** The object layer's transforms and Arrange; Opacity offers 100, 75, 50
  and 25%. A corner resizes a selection holding a picture evenly in both directions (by whichever the drag moved
  further, `SelectionGeometry.transform(…, keepsAspectRatio:)`), so photos never stretch; shapes, ink and text still
  resize freely. While cropping, drags belong to the crop: the page doesn't pan, zoom, swipe or go back.
- **Stickers.** Save as Sticker keeps the selection (ink, shapes, text and pictures) as a `SelectionClip` plus
  a PNG preview in `StickerStore.shared` (`Application Support/InkKit/Stickers`: `Stickers.json` and each
  sticker's `.clip` and `.png`), so ink stays vector and objects stay editable when placed. The Insert menu's
  Stickers… shows them; a tap places a copy in the middle of the view, selected; touch and hold to rename or
  delete.

#### Tape

`TapeObject` (file kind `"tape"`) is a strip: its `frame` is `length × width` centred on its own origin, and its
`transform` turns and places it, so drawn at an angle it's a rotated rectangle. Its own fields are `color`,
`pattern` (`plain`, `striped`, `grid`; absent for plain) and `revealed` (absent while hidden). Reading is lenient
(a bad colour is the default sand, an unknown pattern plain).

- **Over the ink.** `PageObject.drawsOverInk` is true only for tape, so the canvas splits the page's objects
  (`splitByInkLayer`) between `objectLayer` (under the ink) and `tapeLayer` (over it). Hidden tape is opaque, so
  it hides ink, text and pictures alike; revealed, it's a 16% tint with a dashed edge.
- **The tool.** A drag draws a strip from the touch-down point to the touch, snapping to 0°, 45° and 90° like a
  line, `width` page points wide (the tool's width, 8–60), in the Pen Case's tape colour and the options'
  pattern. A tape tool drag shorter than 8 view points is a tap.
- **Toggling.** A tap on tape with any tool but the lasso (which selects it) and the eraser reveals or hides it
  (`CanvasDocument.toggleTape(id:)`): a pen or highlighter tap (a stroke under 8 view points and 0.5 s) is turned
  into the toggle in `endStroke` instead of leaving a dot; the tape, text and laser tools toggle on their own taps;
  a finger tap does it when fingers don't draw (`TapeTapGestureRecognizer`). `setAllTape(revealed:)` reveals or
  hides the whole page. Each is one `replaceObjects` command, so it's undoable and saved with the note.

#### Links

`LinkObject` (file kind `"link"`) is a rectangle that goes somewhere when it's tapped. Its fields are `target`
(`LinkTarget`: `{ "url": … }`, `{ "page": <page id> }`, or `{ "note": <note id>, "page": <page id>? }`), an optional
`title` (what menus and VoiceOver call it, e.g. "Page 3") and `color` (`InkTheme.link`). A target this version can't
read is kept as read and written back; such a link does nothing.

- **Adding.** The selection menu's Add Link… (any selection that isn't a link) asks the editor for a target
  (`CanvasController.linkRequest`), and `CanvasDocument.addLink(to:covering:)` puts a link over the selection's
  bounds, padded 4 pt, on top of the page's objects. A link is an object of its own, not part of what it covers, so
  ink, shapes, text boxes and pictures are all linked the same way, and the lasso picks a link up with what's under
  it. With one link selected the menu has Open Link, Edit Link… (`setLinkTarget`) and Remove Link (which leaves
  what it covered). Each is one undoable edit.
- **Drawing.** Under the ink like other objects: an 8% tint of its colour with a dotted underline.
- **Following.** A pen, pencil, highlighter, shape tool or laser tap on a link follows it (`Tool.followsLinks`);
  tape over a link is toggled first (`tapObject(at:tool:)`). The lasso selects links, the eraser ignores them, and
  the text and tape tools keep their own taps. The editor follows `.url` with `openURL`, turns to a `.page` (pushing
  the page it was on onto `LinkHistory`) and hands `.note` to the host's `NoteLinks.open`. The Back button returns
  along `LinkHistory`, skipping deleted pages, and when that's empty, to `NoteLinks.back` (the note a link came
  from).

#### Bookmarks and outline

`InkNotebook.outline` (`NoteOutline`) holds bookmarked page ids and outline entries (title, page id, `level`, and
`source`: the user's own or `.pdf`). The page bar's bookmark button and a page's context menu in the sidebar
bookmark the page; bookmarked thumbnails show a bookmark. The sidebar's Outline tab lists the bookmarks in page
order, the user's entries (Add This Page, Rename…, Delete, drag to reorder) and the entries from a PDF, indented
by level. `NoteOutline.entries(fromOutlineOf:pageIDs:)` turns a `PDFDocument`'s outline into entries for the
pages showing its pages, and `InkNotebook.importPDFOutline` replaces the PDF entries with them. Entries and
bookmarks refer to pages by id: a deleted page's drop out of the panel, and `pruned(keeping:)` drops them when the
host saves. The host stores the outline (Nota keeps it in the note's manifest).

### Ruler

The Pen Case's ruler button shows `RulerView` over the canvas (over the continuous view in vertical scrolling,
over the page's canvas in paged mode). The ruler (`Ruler`) lives in that view's space, not the page's: it stays
put as the page pans and zooms, and isn't saved (the controller keeps its place while the editor is open).

- **Touches.** Only the ruler's body takes touches (`point(inside:with:)`). Fingers on it move it (one) or turn it
  (two, snapping to multiples of 15° within 1.5°), and the canvas's pan, pinch and taps won't begin there. A
  Pencil touch on it is handed to the canvas under it, so the Pencil writes along the ruler as on paper.
- **Snapping.** When a live stroke begins (pen, pencil or highlighter; not the eraser, not in the zoom window),
  `Ruler.guide(at:)` picks the edge it starts by: within 28 view points outside either long edge, or anywhere on
  the body (the nearer edge). The protractor guides along its arc or its baseline. The edge is mapped into page
  space once (`RulerGuide.mapped`), and `makePoint` projects every sample onto it, predicted ones included: one
  dot product and a multiply-add per point, so the live-ink path does the same work with the ruler as without,
  and nothing else in it changes. Hold-to-snap shapes is off for these strokes.
- **Measuring.** Once per touch event, `RulerMeasurement` advances with the stroke's newest point: the length
  along the edge in page centimetres (page points are 1/72 in, so 1 cm = 28.35 pt), or the angle swept round
  the protractor, shown in a capsule above the Pencil. The ruler's ticks are page millimetres and centimetres at
  the current zoom, and it shows its angle (0–179° for the ruler, 0–359° for the protractor).

### Laser pointer and presenting

- **Laser.** The laser tool draws nothing on the page. `LaserTrail` keeps its points in page space with their
  times: in Trail mode each point fades over 1 s (the point under the touch stays while it's down); in Dot mode
  only the latest point is kept, and it fades 0.3 s after the lift. `LaserView`, an overlay over the tape layer,
  draws it (a glow, a line and a white core, in a dozen opacity steps so a long trail is a dozen paths) and runs a
  display link only while something shows. A laser tap (under 8 view points) toggles tape or follows a link like any tool.
- **Presentation mode.** `InkPresentation.shared` holds the page being presented: each editor presents its
  current page when it appears and when the page changes, and stops when it goes away. The canvas hands it the
  laser trail on every touch event. `PresentationMirror` (SwiftUI, over `PageMirrorView`) shows that page fitted
  to the display with a 24 pt margin (`PageMirrorLayout`), rendered off the main thread with `PageRenderer` each
  time the page changes (one render at a time, at most 4096 px across), with its own `LaserView` mapped through
  the fitted transform. The host shows it on an external display: Nota's app delegate gives the
  `windowExternalDisplayNonInteractive` scene role a scene delegate whose window hosts `PresentationMirror` and
  sets `isMirroring`, which shows the editor's "Presenting this page" badge.

### Rendering pipeline

1. **Committed layer: page-space tiles** (NOT-102, following the decision below). Finished ink is drawn into
   256 × 256 device-pixel tiles of the page at a **level** (device pixels per page point), kept in the shared
   `TileCache` and shown as `CGImage` layer contents (`TileLayerGrid`).
   - **Settled, a canvas shows its own level**: `viewTransform.scale × displayScale`, with the offset on whole
     device pixels, so each tile pixel is a screen pixel and the tiles are what drawing the page whole at that
     transform gives. A gesture ending within 2% of a level the page already has (the fitted page, the last
     zoom) snaps to it, so returning there fills nothing.
   - **What's filled.** `RenderCoordinator` works out the tiles in view (and a ring of one tile around them, so a
     pan finds its next tiles cached) and fills only those missing or stale, one `RenderScheduler` job per tile
     (see Render scheduler below), each tile drawing in page order the strokes the page's `StrokeIndex` finds reaching it
     (`CoreGraphicsTileFiller`, through the same `StrokeRenderer.draw` as before). A pan at the same level over
     cached tiles fills nothing; a pinch fills nothing until it ends: the last level is scaled, over the
     **resting level** (the fitted page; continuous scrolling's column at zoom 1) where it has no tiles, masked
     away wherever it has. When the gesture ends, the new level's tiles in view are filled, centre-out, and
     each appears as its batch lands (see Zoom levels below).
   - **Zoom levels: progressive refinement (NOT-105).** A canvas shows up to three levels, each in a layer
     masked away wherever a level above it has a tile, so blurrier ink never shows around the sharp:
     - the **displayed level** (`displayedLevel`): mid-gesture the last settled one, scaled; once the gesture
       ends, the transform's own level at once, its tiles appearing as they land, centre-out;
     - the **level before it** (`underLevel`), scaled under it until the new level's tiles cover the view,
       then let go; so a pinch from 2× to 3× shows the 2× ink where 3× hasn't landed, never blank or the
       fitted page's softer ink;
     - the **resting level** (the fitted page; continuous scrolling's column at zoom 1) under both.

     Nothing is filled at a scale still changing, with two exceptions, both at fixed levels. A pinch out
     past the tiles drawn (fast, or after the cache let the resting level's tiles go) fills the resting
     level's missing tiles in view, so the page is never blank. And a pinch that holds a scale (within the 2%
     snap) for 100 ms (`steadyDelay`) fills that level's tiles in view while the fingers are still down;
     lifting them there snaps to it (levels being filled count as cached), so it's sharp sooner. Zooming
     back to a level still cached (the fitted page always is, as is a recent zoom) fills nothing, and the
     snap lands on the level's scale exactly (a scale a rounding error off would be another level).
     Settled levels stay exact rather than quantised to powers of √2: NOT-99 chose the transform's own level
     so a settled tile pixel is a screen pixel and the live layer matches; the fallbacks above do the
     quantised levels' job of always having something to show.

     The cache evicts tiles of levels nobody shows (one zoomed through) before the shown levels' off-screen
     tiles (the margin a pan uses next), and those before the resting level's (`TileCache.setInterest`'s
     `shown`), all within its 192 MB. The template and objects follow the same settle rule
     (`FollowingVectorView`), so paper, objects and ink sharpen together.
   - **Versions and dirty rects (NOT-104).** Each tile records the version of the page's ink it shows
     (`CanvasDocument.inkVersion`, which moves on with every change to the strokes: each command, undo and
     redo, and each step of an erase or a lasso drag, which `revision` only counts once recorded). The page
     logs where each change went (`inkChanges`, an `InkChangeLog` of the last 256): the reach of every stroke
     it added, removed or changed, before and after, padded a point. A recolour or a reorder counts only the
     strokes that differ; a standard erase, the strokes cut and their pieces. So a tile at an older version
     is brought up to date by what the changes since reach of it:
     - nothing: it's relabelled, unfilled (cached tiles at every level are moved on as changes arrive,
       `TileCache.advance`, and the rest when looked at);
     - part of it: only that part is refilled (`FillPlan.region`, a region job): the strokes the index finds
       there are drawn into a blank tile clipped to just around it, and its pixels there replace the old
       tile's, which stay on screen until the job lands;
     - all of it, or changes too old for the log, or the page resized: the tile is filled whole.

     A refilled region is the tile filled again to within one level in a few pixels (a clip moves Core
     Graphics' coverage that much; it never builds up, since a region is drawn from nothing each time). A
     grain stroke drawn through a transparency layer isn't clipped, as its pattern would shift. Every canvas
     and the zoom panel read the same log, so a second window's tiles catch up the same way. On the 5k
     benchmark page at the fitted zoom an undo of one stroke is ~45 ms (from ~1.4 s), and a stroke erase of
     ~90 strokes ~0.5 s (a 550 × 180 pt band of the densest page, so ~1,000 strokes to draw again); at 6× the
     tiles hold few strokes each. Closing that needs a cheaper fill per stroke (see the decision below).
   - **A finished stroke** is drawn into every cached tile it reaches, at every level, by an `underPencil` job
     (strokes sent meanwhile go in the next one, in order), so it never blinks; the tiles it doesn't reach move
     on to the new revision as they are (`TileCache.advance`). Fills run beside it and leave strokes still
     waiting for their estimates out, so a fill that started before the stroke was sent lands labelled with the
     revision before it: where the stroke doesn't reach, the coordinator's stroke log moves the label on; where
     it does, or the job saw a tile a fill has since replaced, the tile is marked stale and filled again.
   - **Live and committed match** as before: the same `.copy` run rule, multiply and wax, on a pixel grid
     aligned with the live layer's, and the pencil grain is pinned to the page in both
     (`PencilTexture.pinToPage`: the pattern anchored at the page origin's device pixel, not reduced modulo a
     cell, so a scaled grain lines up too).
   - **One cache, every view.** Tiles are keyed by page (`CanvasDocument.cacheID`), level and position, so the
     paged canvas, each embedded canvas in continuous scrolling (whose re-centred render windows now reuse
     the tiles they had) and the zoom window's panel share them. The cache keeps 192 MB, evicting least
     recently used tiles that no view shows first, then resting-level ones, never one on screen. Empty tiles
     keep no bitmap.
   - **Reopening a page.** With its tiles still cached, a page opens with no fill at all. When the paged canvas
     leaves a page it also hands the document a `TileRaster`: its fitted-level tiles, LZFSE-compressed (about
     5 MB for 5k strokes; any not cached at the page's revision are drawn in the background first), which a
     fill restores tile by tile instead of drawing once the cache has let them go. Any edit drops the raster;
     embedded canvases don't leave one (NOT-106 persists the tiles and keeps them across edits).
   - `PageRenderer` (thumbnails, PDF, the golden snapshots) still draws the page whole; tiles differ from it in
     well under 0.2% of pixels (Core Graphics' coverage of a path cut by a different clip), and the tile tests
     hold them to that.
2. **Live layer.** The in-progress stroke is drawn in a separate view made of 256 pt tile layers, so per-frame work doesn't grow with stroke length, screen size or zoom:
   - The stroke is cut into chunks of 8 segments. A chunk that is complete, and whose points are no longer waiting for estimated-property updates, is **baked**: rasterized once into a per-stroke bitmap for each tile it reaches, and never filled again.
   - Only the **hot** part (the newest chunk or two and the provisional tail) is re-filled each frame, and only in the tiles under the new ink, clipped to the invalidated rect.
   - Baking uses `.copy`, the same "later run replaces earlier" rule as the committed path, so live and committed pixels match.
   - A late estimate that changes a baked chunk re-bakes just the tiles it touches. Tiles are freed once every stroke has been committed.
   - A raster brush (the crayon) bakes its wax field on the GPU instead and gets its pixels back asynchronously (see Brushes › Raster brushes).
   - Multiply ink previews over the committed tiles on screen (`LiveInkView.underlay`, page rects and images).

#### Render scheduler (NOT-103)

All render work goes through `RenderScheduler.shared`: canvas tiles, finished strokes, the zoom window's panel,
the presentation mirror, page thumbnails, geometry warm-up after a raster restore, and a closing page's
`TileRaster`. There are no other render queues or in-flight/requested flags.

- **Jobs** (`RenderJob`) carry a priority, a rank within it (tiles: their place centre-out) and optionally a
  cancellation token and a coalescing key. `work` runs on a worker thread and returns an output; `publish` runs
  on the main thread with it, or with nil when the job was dropped, exactly once.
- **Priorities**, in order: `underPencil` (tiles within 8 pt of the nib, finished strokes), `visible` (tiles in
  view, the zoom panel), `margin` (the ring around the view, the presentation mirror), `otherLevel` (the page
  raster at the resting level), `background` (geometry warm-up, thumbnails). QoS follows: user-interactive,
  user-initiated, utility. A queued job can be moved (`reprioritise`: a margin tile that came into view).
- **Bounded.** At most every core but one run at once; while any canvas is in a gesture (the coordinator reports
  `isMoving`), two performance cores fewer than the device has (`hw.perflevel0`), so the main thread and the
  render server keep two. `otherLevel` and `background` jobs take at most two workers between them, so a slow
  thumbnail never holds up a tile.
- **Cancellation.** A cancelled job never starts; a running one is asked between strokes (`TileFiller.fill`'s
  `isCancelled`, and `GeometryStore` between geometry builds) and its output is dropped even if it finished. The
  coordinator cancels fills for tiles that left the wanted set, queued fills of a revision the page has moved on
  from (they're submitted again), everything on `discardInFlight` (a token), and everything when it goes (its
  lifetime token). A *running* fill of an older revision is left to finish, because its pixels are newer than
  what's on screen (a dense fitted tile takes 100–250 ms, and an erase changes the page faster than that); its
  tile is refilled when it lands. A coalescing key (zoom panel, mirror) cancels the older job if it hasn't
  started, and drops its output if a newer one published first, so stale pixels never land over fresh ones.
- **Published in batches.** Finished jobs are published together on the main thread, at most once per
  120 Hz frame; an owner hears once per batch (`afterBatch`), so the coordinator stores the batch's tiles and
  lays its layers out once.
- **Settled.** Fills are tracked per tile until published or cancelled. `rendersSettled` means "no fill of a
  tile in view and no finished stroke on its way, and every tile in view at the page's revision"; the margin's
  fills may still be running (`RenderCoordinator.isFilling`), as they change nothing on screen. So
  time-to-sharp no longer waits for the margin; benchmarks and tests that count fills wait for those too.
- **Region jobs.** NOT-104's dirty-rect refills are tile jobs like any other, with a region
  (`TileFiller.fill`'s `region`) and the tile they start from. NOT-105's progressive levels are `visible`
  jobs shown as each batch lands; fills of levels passed through during a pinch are cancelled, bar the
  resting level's missing tiles and a held scale's (see Zoom levels above).

#### Decision: tiled committed layer (NOT-99)

**Core Graphics fills page-space tiles; Core Animation composites them (option 3, "hybrid"). Metal fill is
deferred out of M1.5**, kept possible by the `TileFiller` interface below. The spike prototyped all three
options on the 5k-stroke benchmark page (`Tests/InkKitBenchmarks/RenderSpike.swift`, not part of the
benchmark run; `-only-testing:InkKitBenchmarks/RenderSpike` in Release prints `[inkbench] spike.*`). Numbers
are from the iPad Pro 13-inch (M5) simulator on an M1 Pro (10 cores), so the GPU is the Mac's:

| | Today (one bitmap, bands) | CG tiles, 256 px, pieces culled | Metal, stencil-then-cover, 4× MSAA |
| --- | ---: | ---: | ---: |
| One tile at the fitted zoom (p50 / p95) | – | 100 / 232 ms | – |
| One tile at 6× (p50 / p95) | – | 5.6 / 7.1 ms | 2–4.5 ms (512 px) |
| Whole page at the fitted zoom, every core | 1,817 ms | 1,408 ms (80 tiles) | 36–44 ms |
| Screen at 6×, every core | 150 ms | 102 ms (99 tiles) | 7–15 ms |
| Undo of one word-sized stroke, fitted zoom | 1,886 ms (`edit.undo_5k_ms`) | 220 ms whole tiles; **31 ms** dirty rect only | – |
| Same undo, only the tiles on screen at 6× | – | 9.4 ms | – |
| Memory | 22 MB bitmap | 256 KB a tile: 20 MB fitted page, 25 MB screen at 6× | 203 MB of vertices, 217 MB of MSAA targets |
| Pixels differing from today's (> 2 of 255) | – | 0.13% (0.06% at 512 px) | 35% at 1×, 14% at 6× |

What decided it:

- **Core Graphics is slow per stroke, not per pixel.** In a fitted-zoom tile a plain stroke costs 0.39 ms, a
  stroke with tilt-varying alpha (two or more runs, drawn through a transparency layer) 1.48 ms, a grain
  stroke 0.57 ms, whatever share of the tile it covers. So tiles don't make a full page cheaper (1.4 s), and a
  fitted-zoom tile on this page (up to 281 strokes) is 100–250 ms. What tiles buy is **not filling**: a pan
  over cached tiles fills nothing, an edit refills only its rect, and at 6× a tile holds few strokes.
- **Culling to pieces** (a tile fills only the strips and stamps of each stroke that reach it) takes a 6× tile
  from 7.9 to 5.6 ms (p50) and the 6× screen from 157 to 102 ms; it does nothing at the fitted zoom, where most
  of a stroke reaches the tile anyway.
- **Dirty rects, not dirty tiles.** Refilling whole tiles for an undo is 220 ms at the fitted zoom (10 tiles of
  ~100 ms); clearing and refilling only the stroke's padded bounds inside each tile is 31 ms, with 253 strokes
  under that rect on this page. That's still 2× the 16 ms edit budget on the benchmark page (a pile of corpus
  copies far denser than real notes); at 6× the visible part is 9.4 ms.
- **Tile size 256 px.** 512 px tiles take 26 ms each at 6× and 1024 px 128 ms: too coarse for a scheduler to
  cancel, prioritise and publish within a frame, and an undo refills 4–16× the pixels. 256 px costs the same
  memory at the fitted zoom (20 MB) and less at 6× (25 vs 30 MB), at up to ~100 layers on screen.
- **Metal is ~30× faster for a whole page (7–15× for the 6× screen), but isn't the same picture.** The prototype has no grain, no `.copy`
  between runs, an approximate multiply, and MSAA coverage instead of Core Graphics' analytic coverage: 35% of
  pixels differ at the fitted zoom. Closing that means porting the grain and the run rule to shaders and
  accepting that Core Graphics (PDF export, thumbnails, the goldens, the live layer) and Metal never match
  exactly. Its naive tessellation is 203 MB of vertices for 5k strokes (twice the 109 MB geometry cache) and
  0.6–1.9 s of CPU to build. That's a milestone of its own, not a step of this one.
- **Hand-off is cheap.** Snapshotting a tile bitmap as a `CGImage` for `CALayer.contents` is 0.03 ms
  (copy-on-write); uploading 512 px into an `MTLTexture` by hand is 1.1 ms. So tiles go to layers as images and
  Core Animation uploads them.

**Tiles.**

- A tile is **256 × 256 device pixels** of one page at one **level** (pixels per page point). Tile (col, row)
  covers page pixels [col × 256, (col + 1) × 256) × [row × 256, (row + 1) × 256) at that level, so its page
  rect is that divided by the level. Tiles are in page space: the same tile serves the paged canvas, embedded
  canvases in continuous scrolling and the zoom window's panel at the same level, wherever they're placed.
- A tile with no ink is stored as "empty" (no bitmap). A tile bitmap is premultiplied BGRA from
  `CommittedRenderer.makeBitmap`, 256 KB.
- Each tile remembers the page revision it shows. An edit marks tiles **stale** but keeps their pixels on
  screen until the refill lands, so nothing flashes blank.

**Zoom levels.**

- **Settled, a canvas shows tiles at exactly its scale.** The level is `viewTransform.scale × displayScale`,
  and when a gesture ends the transform's offset is snapped to whole device pixels so the tile grid lands on
  the screen's pixel grid. Then a tile's pixels are what drawing the page whole at that transform gives (to the
  0.13% above), the live layer is unchanged and still matches, and `CanvasBenchmarks`' pixel check keeps
  meaning "correct at the current transform".
- **Levels are reused, not quantised.** When a pinch ends within 2% of a level already cached for the page (the
  fitted level, the last zoom), the transform's scale snaps to that level exactly, so double-tapping back to fit
  or returning to a zoom refills nothing. Otherwise the new scale is a new level.
- **During a gesture nothing is filled at the moving scale.** The layers of the last settled level are
  transformed (as the bitmap is today), over the fitted level's tiles as a fallback where they're missing. When
  the gesture ends, the visible tiles of the new level are filled centre-out and swapped in as they land
  (NOT-105, landed: see Zoom levels in the pipeline above).
- The **fitted level** of each layout (paged; continuous) is kept for every open page; other levels go first
  under the byte budget. A fitted 5k-stroke page is 20 MB of tiles.

**Live and committed pixels stay matched** the way they do today: the committed tiles use the same
`StrokeRenderer.draw` (the `.copy` run rule, `WaxRenderer` for raster brushes) at the same scale, on a pixel
grid aligned with the live layer's. The pencil grain's pattern phase comes from the tile's page-pixel origin
(the pattern is anchored at a bitmap's bottom-left corner in device pixels), so grain is pinned to the page
across tiles. Committing a stroke draws it into the cached tiles it reaches at the current level (as it's
drawn onto the bitmap today, so it never blinks) and marks it stale at other levels.

**Golden snapshots don't change.** They're drawn by `PageRenderer` (whole page, one bitmap), which stays as it
is for thumbnails, PDF and the goldens. Tiles differ from a whole-page draw in 0.13% of pixels: not at the seams
(0.012% within 2 px of a tile edge) but inside, where Core Graphics' coverage of a path cut by a different clip
differs by a few levels (up to 50 for plain ink, 158 for grain). Today's bands, which only cut horizontally,
differ in 0.002%. So:

- Tile tests compare tiles with the **same tiles drawn from scratch** (exact), and tiles assembled into a page
  with `PageRenderer`'s whole page within a tolerance (0.2% of pixels by more than 2 levels).
- `CanvasBenchmarks.mismatch(of:)` draws its reference through the tile path from scratch (or relaxes its
  0.1% threshold to 0.2%); NOT-102 decides and updates it with `liveView.underlay`, which tiles replace.

**Types the follow-up issues build** (names are the proposal; adjust in review, then keep this list current):

| Type | Issue | Role |
| --- | --- | --- |
| `RenderCoordinator` | NOT-100, NOT-102 (landed) | The committed side pulled out of `CanvasView`: geometry cache, pending strokes, revision tracking, render requests. `CanvasView`, embedded canvases and the zoom panel talk to it; it owns no touches. Wraps today's bitmap behind `invalidate(rect:)` / `invalidateAll()`, `strokeCommitted(_:geometry:revisionBefore:)`, `visibleRect(for:)`, `isSettled` (what `rendersSettled` reads) and `publishedImage` (what `CanvasBenchmarks.mismatch(of:)` reads), so NOT-102 swaps the inside. The viewport already keeps the offset on device pixels (each pan or pinch step, and the fitted transform), so a settled transform is pixel-aligned |
| `StrokeIndex` | NOT-101 (landed) | Per page, owned by `CanvasDocument`, kept in step by every change (see Spatial index below). `strokes(in: CGRect) -> [Int]` (positions in page (z) order), `objects(in:)`; `CanvasDocument.strokeIndices(in:)` / `strokes(in:)` / `objects(in:)` wrap it. A uniform grid of 32 pt cells. No `nearest(to:limit:)`: tap selection wants the topmost stroke under the finger, which a rect query around the tap gives in z-order |
| `TileLevel`, `TileKey` | NOT-102 (landed) | `TileLevel(pixelsPerPoint:)` (and `isNear`, the 2% snap); `TileKey(page: UUID, level:, col:, row:)`, `TileKey.side = 256`, `rect` in page points, `pixelRect`, `keys(covering:page:level:)` |
| `TileCache` | NOT-102 (landed) | One for the app (`TileCache.shared`), shared by every canvas and zoom panel. Thread-safe. `tile(for:)` / `tiles(for:)` (`Tile`: `image`, nil when empty, and `revision`), `store` / `storeIfNewer`, `advance(page:from:to:outside:)`, `invalidate(page:rect:)` (marks stale at every level), `setInterest` (what a view shows and its resting level), LRU eviction under a byte budget, off-screen tiles first |
| `TileFiller` | NOT-102 (landed) | `fill(_ key:, region:, strokes: [TileStroke], into:)`: draws the given strokes (from `InkSnapshot.drawable(in:)`, which asks the `StrokeIndex`) into a tile, or only `region` of it (cleared first; NOT-104's dirty rects). `CoreGraphicsTileFiller` is the only one in M1.5 |
| `StrokeGeometry` pieces | not done | Each run's strips and stamps with their bounds, so a filler draws only the pieces reaching its tile. Left out of NOT-102: a copy of every stroke's pieces would roughly double the geometry cache (NOT-108 bounds it), and the spike's gain was at 6× only (7.9 → 5.6 ms a tile) |
| `RenderScheduler`, `RenderJob` | NOT-103 (landed) | Jobs carry a priority (`.underPencil`, `.visible`, `.margin`, `.otherLevel`, `.background`), a rank and a cancellation token; the coordinator tracks each tile's fill and its revision. Dropped before they start when stale or off screen, checked between strokes while running; results published in one batch per frame. See Render scheduler above |
| `CanvasDocument` change rects | NOT-104 (landed) | `inkVersion` moves on with every change to the strokes, mid-gesture too, and `inkChanges` (`InkChangeLog`) keeps the rect each touched; the coordinator relabels tiles no change reached and refills the rest by region (`FillPlan`, `TileFiller.fill(_:region:…)`). The rects travel in the document rather than with `invalidate(rect:)`, so every canvas and level showing the page uses them, whichever view made the change |
| Progressive levels | NOT-105 (landed) | `RenderCoordinator.displayedLevel` / `underLevel` over the resting level, each masked where the level above has tiles; the resting level's missing tiles and a held pinch's level filled mid-gesture (`steadyDelay`); `TileCache` evicts levels nobody shows first. `FollowingVectorView` gives the template and objects the same settle rule |

**Order of the follow-ups**: NOT-100 (split `CanvasView`, no behaviour change) → NOT-101 (index: tiles query it
per tile, and a linear scan per tile over 5k strokes would cost more than small fills) → NOT-102 (tiles, levels,
piece culling; pans and zoom levels reuse pixels) → NOT-103 (scheduler: cancellation and priorities make
time-to-sharp and pan margins work; leaves two performance cores free during gestures) → NOT-104 (dirty-rect
edits). What to expect against the NOT-98 budgets on the 5k page:

- `pan.6x_dense.*`: met after NOT-102/103 (cached tiles fill nothing; a new column of eleven 6× tiles every
  ~13 frames at 10 pt a frame is ~60 ms of background fill).
- `zoom.pinch_1x_6x.time_to_sharp_ms`: ~100 ms of fill on every core for the 6× screen, so about the 150 ms
  budget once the scheduler holds two cores back; centre-out order gets the middle sharp first. Measured
  after NOT-105: ~200 ms on the M1 Pro simulator, ~110 tiles whose fills add up to ~1.4 s (7.7 ms a tile
  alone, ~13 ms each when nine run side by side), so it's fill-bound; NOT-105 shows the tiles as they land
  and fills a held pinch's level before the fingers lift (`zoom.pinch_1x_6x_held`). Cutting run paths to
  the tile as they're drawn was tried and was slower (and not byte-identical): closing the rest needs
  cheaper strokes or the Metal fill.
- `edit.*`: ~31 ms at the fitted zoom after NOT-104, so still about 2× over on this page; 9 ms at 6×. Closing
  it needs cheaper strokes: the multi-run transparency layer is 4× a plain fill. Proposed as a follow-up
  (see below) rather than more scope for NOT-104.
- A **new zoom level near the fitted zoom** refills most of the page: ~1.4 s on this page, progressively,
  centre-out, over the scaled tiles. That's the case Metal fill would fix.
- `scroll.page_enter_5k_ms` (50 ms) needs the page's fitted-level tiles restored rather than drawn:
  NOT-102 replaced `CommittedRaster` with the paged canvas's `TileRaster` (and a page whose tiles are still
  cached enters with no fill at all); keeping fitted tiles for continuous pages and across edits is NOT-106.

**Metal fill: deferred.** Revisit after M1.5 if zoom-level refills or dense-page edits stay over budget on
device. A Metal `TileFiller` would need: the grain as a shader (as the wax tooth is), the `.copy` run rule
inside a stroke (stencil per run, later runs masking earlier), exact multiply (programmable blending reads the
destination on Apple GPUs), indexed tessellation built lazily per stroke rather than fans for the whole page,
and an answer for matching Core Graphics: either the live layer fills with Metal too and the goldens are
re-recorded, or a tolerance everywhere the two meet.

**What the crayon's `WaxRenderer` taught** (NOT-93/NOT-96), the first Metal on the ink path:

- **Make every pixel a function of its own inputs** and splitting the work can't show. The wax field is
  max-blended and its tooth comes from the page position of the device pixel, so tiles, bands and the live
  layer's dirty rects all give the same pixels, and a test checks it. Source-over ink isn't order-free like
  max, so a GPU filler for ordinary ink must keep page order within each tile.
- **Never wait for the GPU on a touch.** Waiting per live tile cost 0.3–1.5 ms on the simulator, several times
  an event; it now commits and gets pixels back on the main queue (0.5 ms p50, 0.85 ms p95). The committed path
  still waits, one GPU pass per stroke and band (`full_redraw.crayon_500_ms` 159 ms for 500 crayon strokes):
  batch strokes per tile in one pass instead.
- **Reading back is cheap if nothing is copied**: output lands in a shared `MTLBuffer` wrapped as a `CGImage`
  and composited by Core Graphics or Core Animation, so the GPU's output fits the same tile cache.
- **Shaders compile from source at runtime** (`makeLibrary(source:)`, since the package has no Metal build
  step), so the first use is slow: prewarm off the main thread. Keep a Core Graphics fallback (no Metal device,
  regions over 8192²), and the fallback is what PDF export and old builds see.
- **Simulator GPU numbers are the Mac's GPU.** None of this, wax or spike, has run on an iPad; on-device
  Instruments is the check before Metal goes further.

### Spatial index

Every question "what reaches this rect?" goes to the page's `StrokeIndex` rather than walking its strokes: the
committed layer's culling (full renders and the zoom panel draw only what the index finds on screen), the stroke
and standard erasers (the sweep), the pixel eraser's splits (the strokes under it and the erasers above each),
lasso and tap selection, and circle-to-select. Tiles (NOT-102) query it per tile.

- **What it holds.** A uniform grid of 32 pt cells (`SpatialGrid`) for the strokes and another for the objects.
  Each item is filed under a conservative rectangle. For a stroke that is its **reach**
  (`StrokeIndex.reach(of:)`): its points' bounds grown by the widest its nib can get (full pressure, a wet brush
  pooling, full tilt with its contact shift, stamp jitter) plus half its longest step for the spline's bulge.
  It reads only points and brush, never geometry, so it's cheap on open and on every edit. A test checks it
  holds the ink of every bundled brush. For an object it's `bounds`. Queries return candidates; callers still
  check exact geometry bounds.
- **Z-order.** Results are positions in the page's arrays, bottom first. Each item has a slot with an order key
  that increases with its position (fractional, renumbered in the rare case a gap runs out), so inserting or
  removing a stroke moves no cell contents, only two position-ordered arrays the size of the page's own.
  A query takes each item from the first of the rect's cells it's in (so there are no duplicates to drop),
  sorts by order key and binary-searches each back to its position.
- **Kept in step.** Every change to `CanvasDocument`'s strokes and objects goes through helpers that update the
  index too: commands and their undo and redo, live erasing (`remove`, `replace`), transform previews and late
  estimate updates. Whole-array changes (an undo of an erase, restyle, arrange, paste) refile only what lies
  between the unchanged start and end of the page. Tests check it against walking the page after random
  sequences of every edit, undo and redo.
- **Built off the main actor.** `DocumentStore` calls `InkPageFile.prepareIndex()` where it decodes a page, and
  `CanvasDocument(file:)` takes the index from the file (a page built without one builds its own). A 20k-stroke
  page builds in a few milliseconds (`index.build_20k_ms`). Items covering more than 1024 cells (a huge stroke
  or a page-sized object) are kept aside and checked on every query; a query whose cells hold about as many
  entries as the page has items (the whole screen at the fitted zoom) walks the items instead.

### Stroke geometry

- Samples are smoothed with **centripetal Catmull-Rom**, which avoids cusps and overshoot when samples are unevenly spaced.
- Each segment is cut into straight steps by **curvature, not distance**: enough to stay within 0.02 canvas points of the spline, to keep each step's turn small, and to keep the nib from changing more than about 10% per step, but never denser than half a nib width. A fast, nearly straight segment is one or two steps however long it is.
- At every sub-step the nib is an **ellipse**, from the stroke's `BrushDescriptor`:
  - Pressure sets the width across `size`: `width = upper × (ratio + (1 − ratio) × pressure^exponent)`, `ratio = lower / upper`. Taper and speed (`velocity`, `wetness`) then scale it, when the brush uses them.
  - When tilt is on, the ellipse stretches along azimuth, widens and loses opacity as altitude drops (for the built-in brushes shading starts below 60° and saturates at 15°). A flat (`ellipse`) tip keeps its own angle.
- The ink of each step is the **convex hull of two consecutive nib ellipses**. It is emitted as the quad between the ellipses' common tangents, with consecutive quads welded into one **strip** polygon. The nib ellipse itself (a **stamp**) is added only where the strips alone would leave a gap: the stroke's two caps, sharp bends, fast tapers, and wherever a strip has to break (a change of alpha, or a new chunk).
- This matters for speed: Core Graphics' fill time follows vertex count and overlap depth, not pixel count. Emitting every hull whole gave about 8× the vertices, all overlapping.
- Pieces with the same alpha are unioned into one non-zero-winding path, so overlapping joints never double up. When tilt varies alpha along a stroke, runs are drawn with `.copy` inside a transparency layer. This prevents seams.
- **Highlighter** composites with *multiply* (`blend`), so ink underneath stays readable. The **pixel eraser** is a `destinationOut` stroke in the same list, so it's undoable. A grain texture fills with a pattern colour whose phase is pinned to the page.
- Everything above is the **hull path**. The **stamp path** (textured brushes) emits only stamps, spread over each segment; see Brushes.
- **Pixel erasing splits strokes.** When a pixel-eraser stroke is committed, every ink stroke under it is checked: wherever the ink's whole cross-section (the nib's extent across the direction of travel) lies inside the union of the pixel erasers above it, the stroke is cut. Each cut strictly inside a stroke replaces it with separate `Stroke`s (fresh IDs, same style snapshot), so the stroke eraser removes only the piece it touches. Erasing a stroke's end only shortens it. The split is part of the eraser's `add` command, so one undo restores the original stroke. Partial erases that only together sever a line count as a cut too.
- **Eraser modes.** *Precision* is the pixel eraser above. *Standard* cuts away the parts of strokes the eraser passes over as it moves: each touched stroke is replaced in place (same z-order) by the runs of its spline the eraser didn't reach (`StrokeSplitter.remainder`), counting the nib's radius so the pieces' round caps stop at the eraser's edge. The whole gesture is one `replace(before:after:)` command. *Stroke* removes whole strokes (`erase`). Standard and stroke erasing can be limited to highlighter or to pencil ink (`EraserTarget`), so highlighting over handwriting comes off without touching the writing; precision erasing always takes everything, since its stroke composites over all the ink below it. The eraser shows its outline at its on-screen size while erasing, and can switch back to the previous tool when the stroke ends.

### Zoom window

More › Zoom Window shows a writing panel at the bottom of the canvas that magnifies a box on the page, for writing small and neatly. The page is refitted above the panel so the box is never under it.

- **Input.** A touch that begins in the panel's ink area is mapped through the panel's transform instead of the page's (`inputTransform`), so the stroke is stored in page space inside the box like any other, and every tool (pens, both erasers, the lasso) works there. Width-in-view rules (sample spacing, the eraser's on-screen size, lasso slop) use the panel's scale.
- **Rendering.** The panel shows the box the way the canvas shows the page: a committed image of just the strokes that reach the box, assembled from the page's tiles at the panel's own level, filling the ones the cache doesn't have, as a `visible` scheduler job whenever the page's committed tiles change (a newer render supersedes one that hasn't started, and an older one landing after a newer is dropped), under its own `LiveInkView` showing the stroke being written. A finished stroke stays on the panel's live layer until a render that includes it lands, so it never blinks out. With the panel closed none of this exists and the ink path is unchanged; with it open, live strokes are filled in both live layers.
- **Following the line.** `ZoomWindow` keeps the box on a line of the page's `WritingLines` (derived from the page's template by `WritingLines.lines(for:on:)`, which falls back to `WritingLines.standard` for templates without even rows; the host can override per page), with the baseline 72% of the way down. A stroke written in the panel that reaches the right-hand 30% moves the box on so the stroke ends a quarter of the way in; at the end of the line the next one sends it to the start of the next line. Dragging the box by its tab snaps it to the nearest line; its corner knob resizes it, which changes the magnification.

### Continuous scrolling

More › Scroll Direction › Vertical (`PageLayoutMode.continuous`, the default) shows every page in one column, like one long sheet. `ContinuousPageLayout` fits the widest page to the width and stacks the pages with a 6-point gap, all at one scale; finding the pages in view and the current page (the one at the middle of the view) are binary searches, so the column's length doesn't matter.

- **Only the pages in or near the view are real.** A `UIScrollView` scrolls and zooms an empty stand-in for the column. Each page in view, and each page within half a screen of it, gets an embedded `CanvasView`, transparent outside its page; the canvas's own pan and pinch are off. A page scrolled away loses its canvas, so views follow what's on screen (at most 6 canvases), not the note's length; its tiles stay in the shared cache (its column-at-zoom-1 level kept over others) until the cache needs the room, so scrolling back fills nothing. Embedded canvases leave no `TileRaster` behind (NOT-106).
- **Scrolling doesn't re-render ink.** Each canvas sits in the scroll content over its *render window* (`ContinuousPageLayout.renderWindow`): the viewport plus half a screen above and below and a quarter to each side, cut to the page. At zoom 1 that's the whole page. The scroll view moves the canvas, and its already-rendered ink, with the paper, so a page only fills tiles when it gets its canvas (before it scrolls into view) and they aren't cached, when the zoom changes (at the new level, once the pinch ends), and, when zoomed in, for the tiles a re-centred window uncovers. During a pinch the window keeps its size and the last level is scaled. The host places each page with `place(_:settled:)`.
- **Touches.** A canvas takes touches only on its page (`point(inside:with:)`); the gaps belong to the scroll view, whose pan and pinch accept only fingers (two when one draws) and won't begin while a page is taking ink. Writing on a page makes it the current one, and the tools, undo and selection act on it.
- **Paged and continuous share the page bar and sidebar:** choosing a page scrolls to it, and reordering keeps the page being read where it was on screen. Writing in the bottom 15% of the last page adds a page like it.
- **Writing across pages** (`PageSeam`). Ink and the eraser (every mode) carry on from one page onto the next without lifting the Pencil. The touch keeps arriving at the page the stroke began on, which hands each event to `ContinuousCanvasView`; every page with a canvas takes part while the Pencil is within its *reach* above or below it, and runs a piece of the stroke of its own, in its own coordinates, through the same `LiveStroke` path as any stroke (`joinStroke`, `continueStroke`, `leaveStroke`). The reach is the brush's longest taper plus twice its nib radius plus 12 points (at most 160), so neighbouring pages' pieces overlap across the gap: the piece above runs on past its bottom edge and the piece below starts above its top. Each page clips its ink to the page, so what shows is the same ink from the same samples up to the edge, and the pieces' ends, tapers and the stabiliser settling in all fall off the page. Each piece is committed as an ordinary stroke of its page, so saving needs nothing new. A piece whose ink never reached its page is dropped; a joined piece is never a tap or a shape (the shape tool, the lasso and the gesture tools stay on their page, and holding still doesn't snap a stroke on two pages). The pages' pieces share one `CanvasDocument.editGroup`, and undo or redo on any of them takes back the others' (`InkNotebook.undoGroup(_:)`), unless a page was edited since. Refined force and tilt are forwarded to the pages that joined. While a stroke is under way, the pages taking part keep their canvases and stay put, the scroll view doesn't pan or zoom, and writing past the end of the last page adds the next page at once, so the stroke carries on onto it. The cost per event is a location check for each page with a canvas (at most six).
- **Not yet:** the lasso works on one page at a time, so a selection can't span two pages or be dragged onto another; and the zoom window is offered only in paged mode.

### Input handling

- `coalescedTouches(for:)` delivers every Pencil sample (about 240 Hz) instead of one per 120 Hz frame.
- `predictedTouches(for:)` only extends the drawn tail and is discarded on the next real event.
- `touchesEstimatedPropertiesUpdated` patches refined force and tilt into both live and committed strokes.
- Input (`CanvasView+Input`), the viewport (`CanvasView+Viewport`) and the committed ink (`RenderCoordinator`) are
  separate (NOT-100): input feeds `LiveStroke` and hands finished strokes to the coordinator
  (`strokeCommitted`), the viewport moves the transform and asks the coordinator for ink at it, and only the
  coordinator touches a `CGContext` for committed ink.
- Pan, pinch and swipe recognizers accept only `.direct` (finger) touches, and they won't begin while the Pencil is down.
- The system three-finger editing gestures are disabled (`editingInteractionConfiguration = .none`) so the app's own undo/redo swipe takes over.

### Apple Pencil settings

More › Apple Pencil… edits `PencilSettings` (`PencilSettings.swift`). They're saved to `UserDefaults`, so
every editor and window shares them.

- **Double-tap and squeeze** (`UIPencilInteraction`) each pick Switch to Eraser, Previous Tool, Show
  Palette or Off. The default, System Setting, follows Settings › Apple Pencil (`preferredTapAction`,
  `preferredSqueezeAction`): the palette actions show the quick palette, and Run Shortcut is left to the
  system. The quick palette opens at the hover position, above the tip and away from the writing hand.
- **Finger drawing:** with Finger Draws, a lone finger draws ink, two fingers pan, and a second finger
  landing within 0.3 s of the first cancels the ink so pinch, pan and two-finger undo still work. System
  Setting follows Only Draw with Apple Pencil (`UIPencilInteraction.prefersPencilOnlyDrawing`). Finger
  ink has no pressure, so it's faked from drag speed.
- **Palm rejection** (`PalmRejector`): a direct touch is a palm if its contact (`majorRadius`) is larger
  than the sensitivity allows (45 / 32 / 24 pt for low / medium / high), or if it lands on the writing
  hand's side of the Pencil (below and to the right, or to the left in left-handed mode) shortly after the
  Pencil touched or hovered (0.2 / 0.5 / 1 s). Palms are ignored by every recognizer
  (`gestureRecognizer(_:shouldReceive:)`) and by drawing, and stay palms until they lift.
- **Hover:** `UIHoverGestureRecognizer` previews the nib's size and tilt, plus a tick showing the
  barrel's roll on Pencil Pro.
- **Scribble gestures** (`Scribble.swift`, pure geometry):
  - *Circle and hold to select:* a closed loop held still for about 0.45 s selects the strokes at least
    60% inside it, switches to the lasso and lets the same Pencil touch drag them.
  - *Draw and hold to snap shapes:* see Page objects › Shapes.
  - Both give canvas haptic feedback (`UICanvasFeedbackGenerator`) on Pencil Pro.

Barrel roll doesn't change the nib yet: there are no chisel or fountain brushes until the brush engine
(NOT-16). None of this has been tried on a real Pencil (see NOT-12).

### Simulator fallback

The simulator has no Pencil and Only Draw with Apple Pencil is off there, so by default a single
`.direct` touch draws, as finger ink does on a device:

- Pressure comes from drag speed, low-passed so the width changes smoothly.
- Altitude comes from the *Simulated altitude* slider (More › Pressure & Tilt).
- Azimuth is fixed at −45°.
- Panning requires two fingers.

## Debug HUD

This is a toggleable overlay, throttled to about 30 Hz so SwiftUI never sits on the input path. It shows:

- Input state: `pencil ✎`, `pencil hover`, `finger ×N`, `finger ink` or `idle`
- Raw force and maximum, plus a normalised pressure bar
- Altitude, azimuth and barrel roll (Pencil Pro) in degrees, plus a tilt compass. The compass line points along azimuth, and its length is cos(altitude).
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
| `page_open.5k_ms` | Reopening a 5k-stroke page whose tiles the cache let go: its fitted-level tiles restored from the page's `TileRaster` (with them still cached, opening fills nothing) | < 150 ms |
| `page_open_cold.{1,5,20}k_ms` | Opening a page with no raster (first time shown at this size): a fresh committed bitmap, every stroke's geometry built, the page drawn | – |
| `page_raster.*` | Compressing a 5k-stroke page's committed layer when the page closes (in the background), and its size | – |
| `full_redraw.5k_ms` | Re-rendering a 5k-stroke page with geometry cached (undo, erase, end of zoom) | – |
| `ink_file.5k_kb`, `ink_file.bytes_per_point` | Size of a 5k-stroke page's `.ink` file. Each corpus copy is stretched a little so the compressor can't match copies against each other | < 1024 KB |
| `ink_file.encode_5k_ms` / `decode_5k_ms` | Encoding that page, and decoding it back (which joins page open in NOT-6) | decode < 50 ms |
| `stroke_geometry.stamp.*` | `stroke_geometry.*` with every stroke drawn by a stamp brush (bristles, jitter) | – (baseline only) |
| `live_event.stamp.p50/p95/p99_ms` | `live_event.*` with the same stamp brush | – (baseline only) |
| `live_event.crayon.p50/p95/p99_ms` | `live_event.*` with every stroke drawn with the crayon: encoding each dirty tile's GPU job, plus copying back the wax that's finished (the main queue is drained after each event, without waiting) | p95 < 2 ms |
| `live_event.crayon.wax_latency_p50/p95_ms` | From committing a tile's crayon job to its pixels being back on the main queue | – |
| `live_event.crayon.long_stroke.*` | `live_event.long_stroke.*` with the crayon: its baked field must keep the work flat as the stroke grows | last-quarter p95 < 2 ms |
| `full_redraw.crayon_500_ms` | Re-rendering a page of 500 crayon strokes into the committed bitmap, one GPU pass per stroke and band | – |
| `index.build_20k_ms` | Building a 20k-stroke page's `StrokeIndex` from scratch (on open, off the main actor) | – |
| `index.query_tile_{5k,20k}_us`, `index.scan_tile_20k_us` | One tile-sized (128 pt) query, over every tile of the page: on the 5k page, and on a 20k page holding the same 5k strokes plus 15k elsewhere (it must not grow), against a scan of every stroke's rect | – |
| `memory.6x.*` | Physical footprint with a 5k page open at 6× zoom while the corpus is written on top: cached geometry, committed bitmap, live tiles. Measured from a settled baseline (free memory returned first), so earlier benchmarks don't change it | – |

### Canvas benchmarks

`CanvasBenchmarks` (NOT-98) covers what the canvas does beyond drawing a stroke and reopening a page. These
drive a real `CanvasView` (or `ContinuousCanvasView`) through the entry points its gestures and touches use
(`zoom(by:about:)`, `pan(by:)`, `undo()`, `eraseStrokes(along:)`, `endStroke(commit:)`, `place(_:settled:)`)
and time until `rendersSettled`: the committed layer shows the page as it is, sharp, at the current transform.
So they keep measuring what the user sees whatever the render architecture becomes; a new architecture only
has to keep `rendersSettled` honest. After each edit and gesture the pixels shown (the tiles in view,
assembled: `RenderCoordinator.composedImage()`) are checked against the same tiles drawn from scratch, with
no cache and every stroke's geometry rebuilt, which would show a stale tile. The pinch drops the 6× tiles
before each pass, so it measures filling a new level rather than returning to a cached one.

Gesture frames are fed at 120 Hz. A frame's **main-thread work** is its wall time minus the time the main run
loop slept in it, so it counts the gesture step, every render callback the main queue ran and any wait on a
lock. It doesn't count Core Animation's render server or the GPU: the views aren't in a window, and the
simulator's GPU isn't an iPad's. An on-device Instruments profile is the check on those.

| Metric | What it times | Budget |
| --- | --- | --- |
| `edit.undo_5k_ms` | Undoing the last stroke on a 5k-stroke page, to correct pixels | < 16 ms |
| `edit.erase_stroke_5k_ms` | One stroke-eraser sweep through the middle of a 5k-stroke page's ink, to correct pixels | < 16 ms |
| `edit.pixel_erase_5k_ms` | A pixel-eraser stroke across a 5k-stroke page's ink, from the Pencil lifting (splitting the strokes it severs, adding it, drawing it) to correct pixels | < 16 ms |
| `zoom.pinch_1x_6x.frame_p50/p95/max_ms` | Main-thread work per frame of a half-second pinch from the fitted page to 6× over a 5k-stroke page | p95 and max < 8 ms |
| `zoom.pinch_1x_6x.time_to_sharp_ms` | From the fingers lifting at 6× to sharp ink. `tiles_filled` and `fill_cpu_ms` (the fills' own times added up) say what it waited for | < 150 ms |
| `zoom.pinch_1x_6x_held.*` | The same pinch with the fingers held at 6× for 150 ms before lifting, as pinches usually end: the held level is filled meanwhile (NOT-105) | as above |
| `pan.6x_dense.frame_p50/p95/max_ms` | Main-thread work per frame of a half-second pan (10 pt a frame) at 6× over a 5k-stroke page | p95 and max < 8 ms |
| `pan.6x_dense.time_to_sharp_ms` | From the pan ending to sharp ink | < 150 ms |
| `pan.6x_dense.step_render_ms` | The tile fills the pans at 6× set off (what they uncovered and a tile's margin ahead), per frame, off the main thread. `tiles_filled` counts them; `cached_tiles_filled` counts fills in an untimed pan back over the last pass's cached tiles, which must be 0 | < 8 ms |
| `scroll.page_enter_5k_ms` | A 5k-stroke page entering view in continuous scrolling for the first time: its embedded canvas made, placed, laid out and its tiles in view filled (nothing cached or restored: NOT-106) | < 50 ms |
| `memory.continuous_20_pages_mb` | Peak footprint scrolling a 20-page note of 5k-stroke pages page by page, each page drawn, over the note's own strokes (`memory.continuous_20_pages.model_mb`) | < 300 MB |

The budgets are where the canvas revamp (milestone M1.5) is headed; today's engine misses most of them, and
`baselines/apple-m1-pro-simulator-canvas-revamp.json` (today's engine, every metric) records them as known
misses, so they only gate a run once a change meets them. It's the per-metric best of two full runs on an
M1 Pro that wasn't idle, so a single run on a busy Mac can read worse than it with no code change; rerun before
believing a regression, and compare against your base branch on the same machine as well. `*_max_ms` regressions are reported but don't fail a
run (one scheduler hiccup moves them); their budgets still count.

`RenderSpike` (NOT-99) sits beside them but isn't run by `scripts/run-benchmarks.sh` and has no baseline: it's
the throwaway prototypes of the render architectures behind Architecture › Rendering pipeline › Decision.
Run it with `-only-testing:InkKitBenchmarks/RenderSpike` when revisiting that decision.

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
scripts/run-benchmarks.sh bench-output          # Release, iPad Pro 13-inch simulator; ~10 min
scripts/bench-compare.py bench-output/results.json --baseline Packages/InkKit/Benchmarks/baselines/apple-m1-pro-simulator-canvas-revamp.json
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

Tape, the ruler, the laser and the presentation mirror have tests of their own (`TapeObjectTests`, `RulerTests`,
`PresentingTests`): tape's file format, hit-testing, toggling and undo and its rendering over ink; ruler edge
selection, projection, length and angle; the laser's fading; the presentation model, the mirror's layout and
render. The external-display scene itself is only exercised by hand. `LinkObjectTests` covers links' file format,
web-address tidying, adding and retargeting with undo, following with a tap (and tape over a link), and the
selection menu; `NoteOutlineTests` covers bookmarks, outline entries, pruning and remapping, lenient reading, PDF
outline import and `LinkHistory`.

`TileTests` checks the committed tiles: tiles assembled against the page drawn whole (seams and inside) for
plain, multi-run, grain, scaled-grain, multiply, pixel-eraser and crayon ink; against `PageRenderer` within 0.2%;
a stroke drawn into a cached tile against the tile filled again; `TileRaster` round trips; and the cache's
eviction order, revision rules and `advance`. `RenderCoordinatorTests` checks settling, committed strokes,
invalidation, that a pan over cached tiles and a pinch fill nothing (until the pinch ends), the 2% snap, and a
reopened page restoring its raster instead of filling. `RenderSchedulerTests` checks the scheduler: priority,
rank and submission order, `reprioritise`, cancellation before a job starts, while it runs and after it's done
but before its batch (none publishes), cancellation tokens, coalescing (an older job finishing after a newer
one is dropped), the worker limits in and out of a gesture and for low priorities, one batch for jobs that
finish together and at most one batch a frame. `RenderJobOrderingTests` checks the coordinator's jobs: under
the Pencil, then in view centre-out, then the margin; a discarded fill never reaching the cache; fills
overtaken by an edit dropped or refilled, ending with tiles identical to ones drawn from scratch; and fewer
workers during a gesture. `DirtyRectTests` checks NOT-104's dirty rects: the change log (what it knows, its
capacity, unknown changes), the reach a change counts (recolour, reorder, cut into pieces), that every kind of
change moves the ink version (live erasing and lasso drags too, objects not), a region refill against the tile
drawn from scratch for every kind of ink at two levels, and on a coordinator: an undo refilling only regions
of the tiles it reached, live erasing refilling as it goes, and the tiles after random sequences of every
edit, undo and redo, at two levels, against tiles drawn from scratch.

`StrokeIndexTests` checks the spatial index: grid queries against a scan (z-order, huge, empty and off-page
rects, renumbering), that a stroke's reach holds its ink for every bundled brush, and the page's index against
walking the page after random sequences of every edit, live erase, preview, undo and redo (and rotate, copy and
opening a prepared file).

A physical-iPad verification checklist (pressure, tilt, sample rate, eraser, lasso) lives in the InkCanvas README.
