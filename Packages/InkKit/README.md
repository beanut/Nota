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
| `ContinuousCanvasView.swift` | Continuous vertical scrolling: a scroll view over the column, with an embedded canvas for each page in view |
| `CanvasView+Embedded.swift` | A canvas as one page among several: placed by the host, transparent around its page, taking touches only on it |
| `PageSidebar.swift` | The page sidebar: thumbnails (rendered in the background, cached), jump, reorder, select, duplicate, rotate, delete, copy or move to another note (`PageDestination`, `PageSender`) |
| `LassoOverlayView.swift` | Draws the lasso path and the selection outline over the canvas |
| `CanvasDocument.swift` | One page's strokes, objects, size, template and one undo/redo command stack for ink and objects (`add`, which carries any pixel-eraser splits, `erase` (strokes and objects), `replace` for a standard erase, `clear`, `transform` (move, scale, rotate strokes and objects), `addObject`), and the views observing it: a page can be on screen in several canvases at once (a note open in two windows), and each hears every change, whichever made it. Outside InkKit, `observeChanges(_:onChange:)` reports each committed change (never mid-stroke), for autosave |
| `TestingSupport.swift` | `@_spi(Testing)` hooks for other packages' tests to put ink on a page (`drawTestStroke(through:)`, `undoForTesting()`) |
| `PageSize.swift` | Paper sizes in points: presets, custom sizes in in / mm / pt |
| `PageTemplate.swift` | `PageTemplate` (pattern, spacing, margins, paper colour, custom background), the built-in presets, `PaperColor` / `PaperPalette` |
| `TemplateLayout.swift` | Each pattern's measurements, and `lineMetrics(on:)`: baselines, line spacing, writing area and regions for the handwriting layout engine |
| `TemplateRenderer.swift` | Draws a template as Core Graphics vectors (canvas, thumbnails, PDF), skipping pattern outside the visible rect |
| `TemplateArtwork.swift` | A custom background's bytes (a PDF page or an image), decoded once; PDF pages stay vector |
| `TemplateView.swift` | The canvas layer that redraws the template at the current zoom, between the paper and the ink |
| `TemplateMenu.swift` | The page bar's template pill: built-ins, paper colour, PDF or image, use for all pages |
| `ViewTransform.swift` | Canvas → view mapping, zoom limits and page-swipe detection |
| `CanvasView.swift` | `UIView` that handles raw touches, gestures, palm rejection, finger ink, `UIPencilInteraction`, hover and the scribble gestures. Owns the page, the cached committed bitmap and the lasso overlay. Redraws from the document when another canvas on the same page changes it |
| `PencilSettings.swift` | `PencilSettings` (double-tap and squeeze actions, finger drawing, palm rejection, handedness, scribble toggles) and their persistence, quick-palette placement, and `PalmRejector` |
| `PencilSettingsView.swift` | The More menu's Apple Pencil settings |
| `Scribble.swift` | Scratch-out and circle-to-select detection and their target strokes |
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
| `CanvasView+Scribble.swift` | Scratch-out and circle-to-select |
| `CanvasView+Shapes.swift` | The shape tool, draw-and-hold to snap (and sizing the snapped shape before lifting), dragging a selected shape's handles, restyling selected shapes |
| `PageObjectsFile.swift` | `PageObjectsFile`, a page's objects as `pages/<page id>.json`: format version, reading, writing |
| `Selection.swift` | `PageSelection`, `SelectionBox` and `SelectionGeometry`: lasso and tap selection of strokes and objects, the box's handles and the transforms they make; `Stroke.applying(_:)` |
| `ObjectLayerView.swift` | The canvas layer that draws the page's objects between the template and the ink |
| `CanvasView+Selection.swift` | The lasso on the canvas: selecting (with the ink / objects filter), dragging the box and its handles, deleting, adding the test object |
| `CanvasView+SelectionActions.swift` | What the lasso does with a selection: cut, copy, paste, duplicate, recolour, thickness, bring to front / send to back, screenshot, drag out as an image; its menu (`UIEditMenuInteraction`) and ⌘X / ⌘C / ⌘V / ⌘D / Delete |
| `SelectionClip.swift` | `SelectionClip`, a copied selection on the pasteboard (its format, fresh copies with new ids), and `PastePlacement`, where a paste lands |
| `SelectionAction.swift` | `SelectionAction` and `LassoSelection`: the app's own items in the selection's menu (convert to text, AI actions) |
| `CommittedRenderer.swift` | The committed bitmap and its full re-render (geometry for uncached strokes built in parallel, culling, drawing in parallel bands), shared by the canvas and the benchmarks |
| `CommittedRaster.swift` | A page's committed layer kept compressed with the page, so reopening it restores the pixels instead of re-rendering |
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
| `texture` | `none`, `grain(scale 0.25…8, contrast 0…1, seed)`, `bristle(count 1…64, spread 0.1…2)` | Procedural, never a bitmap |
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
| Pencil (`pencils`) | HB Pencil (`.pencil`), Soft Pencil (coarser grain, pressure darkens, broad tilt shading) |
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
  vectors at the current transform; hidden on a page without objects), ink (committed bitmap and live layer),
  tape (`tapeLayer`, another `ObjectLayerView`: objects whose kind `drawsOverInk`), the laser (`LaserView`),
  overlay (lasso and selection box), the ruler. Thumbnails, screenshots and PDFs draw tape after the ink too
  (`PageRenderer.drawOverlays`). Objects are never in the committed ink bitmap, so adding or moving one
  doesn't re-render ink, and the pixel eraser never erases one. The live layer's multiply backdrop draws the
  objects too, so a highlighter previews over an object as it will commit.
- **Revisions.** `objectsRevision` counts object changes, separately from `revision` (the ink's), so an
  object edit doesn't drop the page's `CommittedRaster`. Object-only edits notify `.objectsEdited`.
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
- **Rendering.** The panel shows the box the way the canvas shows the page: a committed image of just the strokes that reach the box, rendered on its own queue whenever the page's committed bitmap changes (one render at a time), under its own `LiveInkView` showing the stroke being written. A finished stroke stays on the panel's live layer until a render that includes it lands, so it never blinks out. With the panel closed none of this exists and the ink path is unchanged; with it open, live strokes are filled in both live layers.
- **Following the line.** `ZoomWindow` keeps the box on a line of the page's `WritingLines` (derived from the page's template by `WritingLines.lines(for:on:)`, which falls back to `WritingLines.standard` for templates without even rows; the host can override per page), with the baseline 72% of the way down. A stroke written in the panel that reaches the right-hand 30% moves the box on so the stroke ends a quarter of the way in; at the end of the line the next one sends it to the start of the next line. Dragging the box by its tab snaps it to the nearest line; its corner knob resizes it, which changes the magnification.

### Continuous scrolling

More › Scroll Direction › Vertical (`PageLayoutMode.continuous`) shows every page in one column. `ContinuousPageLayout` fits the widest page to the width and stacks the pages with a gap, all at one scale; finding the pages in view and the current page (the one at the middle of the view) are binary searches, so the column's length doesn't matter.

- **Only the pages in or near the view are real.** A `UIScrollView` scrolls and zooms an empty stand-in for the column. Each page in view, and each page within half a screen of it, gets an embedded `CanvasView`, transparent outside its page; the canvas's own pan and pinch are off. A page scrolled away loses its canvas and bitmap, so memory follows what's on screen (at most 6 canvases), not the note's length. Embedded canvases leave no `CommittedRaster` behind: they're placed wherever the scroll left them, so it wouldn't match next time.
- **Scrolling doesn't re-render ink.** Each canvas sits in the scroll content over its *render window* (`ContinuousPageLayout.renderWindow`): the viewport plus half a screen above and below and a quarter to each side, cut to the page. At zoom 1 that's the whole page. The scroll view moves the canvas, and its already-rendered ink, with the paper, so a page only renders when it gets its canvas (before it scrolls into view), when the zoom changes, and, when zoomed in, when the view comes within a quarter screen of the window's edge and the window re-centres. During a pinch the window keeps its size (no new bitmap every frame) and the ink re-renders at the new scale as before. The host places each page with `place(_:settled:)`.
- **Touches.** A canvas takes touches only on its page (`point(inside:with:)`); the gaps belong to the scroll view, whose pan and pinch accept only fingers (two when one draws) and won't begin while a page is taking ink. Writing on a page makes it the current one, and the tools, undo and selection act on it.
- **Paged and continuous share the page bar and sidebar:** choosing a page scrolls to it, and reordering keeps the page being read where it was on screen. Writing in the bottom 15% of the last page adds a page like it.
- **Not yet:** a stroke can't cross from one page to the next (NOT-89), and the zoom window is offered only in paged mode.

### Input handling

- `coalescedTouches(for:)` delivers every Pencil sample (about 240 Hz) instead of one per 120 Hz frame.
- `predictedTouches(for:)` only extends the drawn tail and is discarded on the next real event.
- `touchesEstimatedPropertiesUpdated` patches refined force and tilt into both live and committed strokes.
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
  - *Scratch out to erase:* a pen, pencil or highlighter stroke that runs back and forth at least four
    times along its main axis, over strokes that lie mostly inside it, erases them instead of being kept
    (one undo step). Over blank paper it stays ink.
  - *Circle and hold to select:* a closed loop held still for about 0.45 s selects the strokes at least
    60% inside it, switches to the lasso and lets the same Pencil touch drag them.
  - *Draw and hold to snap shapes:* see Page objects › Shapes.
  - All three give canvas haptic feedback (`UICanvasFeedbackGenerator`) on Pencil Pro.

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
| `page_open.5k_ms` | Reopening a 5k-stroke page: a fresh committed bitmap with the page's `CommittedRaster` restored into it | < 150 ms |
| `page_open_cold.{1,5,20}k_ms` | Opening a page with no raster (first time shown at this size): a fresh committed bitmap, every stroke's geometry built, the page drawn | – |
| `page_raster.*` | Compressing a 5k-stroke page's committed layer when the page closes (in the background), and its size | – |
| `full_redraw.5k_ms` | Re-rendering a 5k-stroke page with geometry cached (undo, erase, end of zoom) | – |
| `ink_file.5k_kb`, `ink_file.bytes_per_point` | Size of a 5k-stroke page's `.ink` file. Each corpus copy is stretched a little so the compressor can't match copies against each other | < 1024 KB |
| `ink_file.encode_5k_ms` / `decode_5k_ms` | Encoding that page, and decoding it back (which joins page open in NOT-6) | decode < 50 ms |
| `stroke_geometry.stamp.*` | `stroke_geometry.*` with every stroke drawn by a stamp brush (bristles, jitter) | – (baseline only) |
| `live_event.stamp.p50/p95/p99_ms` | `live_event.*` with the same stamp brush | – (baseline only) |
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

Tape, the ruler, the laser and the presentation mirror have tests of their own (`TapeObjectTests`, `RulerTests`,
`PresentingTests`): tape's file format, hit-testing, toggling and undo and its rendering over ink; ruler edge
selection, projection, length and angle; the laser's fading; the presentation model, the mirror's layout and
render. The external-display scene itself is only exercised by hand. `LinkObjectTests` covers links' file format,
web-address tidying, adding and retargeting with undo, following with a tap (and tape over a link), and the
selection menu; `NoteOutlineTests` covers bookmarks, outline entries, pruning and remapping, lenient reading, PDF
outline import and `LinkHistory`.

A physical-iPad verification checklist (pressure, tilt, sample rate, eraser, lasso) lives in the InkCanvas README.
