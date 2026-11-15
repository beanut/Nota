# Nota design system

Nota's visual language: tokens, icons and the shared controls built from them. It lives in the **NotaUI** package (`Packages/NotaUI`). InkKit doesn't depend on NotaUI: its editor chrome takes colours, fonts, icons and inks from an `InkTheme`, and the app passes `InkTheme.nota` (`Nota/Theme/InkTheme+Nota.swift`), built from these tokens. The source of truth is the Figma file [Nota · Components](https://www.figma.com/design/umhMoBpVlbSKRFE1aD1L6J/Nota?node-id=13-43).

**Rule:** Library and editor chrome use tokens only. No `Color(red:…)`, no `.secondary`/`.primary`, no system greys. If a value is missing, add a token here first.

Exempt: the debug Pencil HUD (a developer overlay), system menus, alerts and sheets (they keep system styling and SF Symbols). The colour picker's spectrum, hue bar and colour well are drawn in the ink colours they offer (not chrome), so they use the colours themselves rather than tokens.

## Colour rules

There are three accent roles. Each one means one thing.

| Role | Token | Means |
| --- | --- | --- |
| Ink · indigo | `accentInk`, `textInk`, `bgInkTint` | Your actions and selections: primary buttons, selected rows, chips and tools, sliders, playback. |
| Nota AI · violet | `accentAI`, `textAI`, `bgAITint` | Only when Nota acts for you: Ask Nota, Generate, dictation, AI suggestions. |
| Live · red | `signalRecord` | Only while the mic records raw audio. Always paired with a label. |

Selected = ink tint, everywhere (sidebar rows, filter chips, width presets). The one exception is the selected tool in the Pen Case, which lifts a raised tile with an ink glyph.

## Colour tokens

`NotaColor.*` (SwiftUI) and `NotaUIColor.*` (UIKit / Core Graphics) hold the same values. Figma defines light; dark values are Nota's own and should be added to Figma as a dark mode.

| Token | Figma | Light | Dark |
| --- | --- | --- | --- |
| `bgApp` | bg/app | `#F7F7F9` | `#111114` |
| `bgRaised` | bg/raised | `#FFFFFF` | `#1F1F24` |
| `bgFill` | bg/fill | `#EBEBF0` | `#2A2A31` |
| `bgDesk` | bg/desk | `#E3E3E9` | `#18181C` |
| `bgInkTint` | bg/ink-tint | `#E8EBFC` | `#252B57` |
| `bgAITint` | bg/ai-tint | `#F0EAFE` | `#2F2352` |
| `borderSeparator` | border/separator | `#E1E1E7` | `#34343C` |
| `borderCard` | border/card | `#E4E4EA` | `#2E2E35` |
| `textPrimary` | text/primary | `#1A1A1F` | `#F2F2F5` |
| `textSecondary` | text/secondary | `#5E5E6A` | `#A3A3AE` |
| `textTertiary` | text/tertiary | `#8A8A95` | `#72727D` |
| `textInk` | text/ink | `#3345D9` | `#8F9BFF` |
| `textAI` | text/ai | `#7D3BED` | `#B58CFF` |
| `textOnAccent` | text/on-accent | `#FFFFFF` | `#FFFFFF` |
| `accentInk` | accent/ink | `#3345D9` | `#5B6CF0` |
| `accentAI` | accent/ai | `#7D3BED` | `#9A63F5` |
| `signalRecord` | signal/record | `#D92D30` | `#FF5A5C` |
| `paperSurface` | paper/surface | `#FCFBF7` | same |
| `paperRule` | paper/rule | `#E2E5EE` | same |
| `paperMargin` | *(Nota addition)* margin rule, Cornell and planner dividers on white and cream paper | `#EDB4B4` | same |
| `paperLabel` | *(Nota addition)* planner labels on white and cream paper | `#9599A6` | same |
| `paperCreamSurface` / `paperCreamRule` | *(Nota addition)* cream paper | `#F8F2E2` / `#E3D9C1` | same |
| `paperDarkSurface` / `paperDarkRule` | *(Nota addition)* dark paper | `#24262A` / `#3C4048` | same |
| `paperDarkMargin` / `paperDarkLabel` | *(Nota addition)* dividers and labels on dark paper | `#6E4C55` / `#7D838E` | same |
| `shadow` | (shadow colour) | `#1A1A33` | `#000000` |
| `inkOutline` | *(Nota addition)* | black 6% | white 32% |

The app's `AccentColor` asset is `accentInk`, so system controls (toggles, links, the text cursor) follow it.

**Paper and ink don't change in dark mode.** The page is a physical sheet: ink written in dark mode must look the same in light mode, and black ink must stay readable. The desk around the page darkens; the page doesn't.

**Paper colours** are a page's own choice (white, cream or dark, set with its template), not the app's appearance: dark paper stays dark in light mode, and white paper stays white in dark mode. Templates draw their lines in the paper's rule colour, and margin rules, Cornell and planner dividers in its margin colour. `PaperPalette.nota` (NotaDocuments) maps each paper to these tokens for both the canvas (`InkTheme.nota`) and thumbnails.

## Inks

`NotaInk` values are stored with strokes, so they are fixed sRGB.

| Set | Tokens | Used for |
| --- | --- | --- |
| Pen inks (Figma) | `ink/black #1A1A1F`, `ink/blue #3345D9`, `ink/teal #12786B`, `ink/orange #C04C1A`, `ink/violet #7C3AED` | Pen and pencil colour presets, note-cover inks, folder colours |
| Highlighters *(addition)* | `highlight/yellow #F7C600`, `/green #5ED17A`, `/blue #5CA8FF`, `/pink #FF6FAE`, `/orange #FF9A3D` | Highlighter presets. Drawn at 38% with multiply, so they must be light and saturated; the pen inks go muddy. |
| Labels *(addition)* | `label/rose #C2255C`, `label/green #2B8A3E` | The two folder colours with no matching ink |
| Tape *(addition)* | `tape/sand #E8D7A9`, `/sage #B9D3B2`, `/sky #A9C8EA`, `/blush #F0BCC8`, `/slate #9EA3B2` | Tape tool presets (`InkTheme.tapeInks`). Drawn opaque over the ink, so soft and papery, with ink still legible on them. |
| Laser *(addition)* | `laser/magenta #F0308A` | The laser pointer's glow (`InkTheme.laser`), on the page and on an external display. Magenta, never the record red. |
| Links | `ink/blue #3345D9` | Links on the page (`InkTheme.link`): an 8% tint with a dotted underline, saved with each link. |

## Type

The Figma styles use Inter at exactly the iOS Dynamic Type sizes, so the app uses SF Pro text styles at the same size and weight. They scale with the reader's text size; Inter would not without extra work. `NotaFont.*`:

| Token | Figma | Size / weight | Used for |
| --- | --- | --- | --- |
| `largeTitle` | Nota/Large Title | 34 bold | Library title |
| `title3` | Nota/Title 3 | 20 semibold | Empty states, panel titles |
| `headline` | Nota/Headline | 17 semibold | Popover headers |
| `callout` / `calloutEmph` | Nota/Callout (Emph) | 16 regular / semibold | Sidebar rows; large buttons |
| `subheadline` / `subheadlineEmph` | Nota/Subheadline (Emph) | 15 regular / semibold | Chips, slider labels; card titles, compact buttons, page bar |
| `footnote` / `footnoteEmph` | Nota/Footnote (Emph) | 13 regular / semibold | Card detail; paper-size pill |
| `captionEmph` | Nota/Caption Emph | 12 medium | Tags |

## Spacing, radius, size, elevation

- **Spacing** (`NotaSpacing`): `xxxs 2 · xxs 4 · xs 6 · s 8 · sm 10 · m 12 · l 16 · xl 20 · xxl 24 · xxxl 32`.
- **Radius** (`NotaRadius`, continuous corners): `paper 4` (paper, thumbnails) · `control 10` (icon buttons, sidebar rows, search) · `group 12` (Pen Case docked in a bar) · `panel 16` (popovers, chips) · `bar 22` (floating bars). Buttons and chips are capsules.
- **Size** (`NotaSize`): icon 20 · icon button 40 × 36 · ink swatch 28 · floating bar 44.
- **Elevation** (`.notaElevation(_:)`): `tile` (selected tool, 0/1/1.5 black 8%) · `floating` (bars over the canvas, 0/8/12 at 10% + 0/1/1 at 8%) · `popover` (0/8/24 at 10% + 0/1/2 at 8%) · `paper` (0/6/16 at 7% + 0/1/2 at 6%). Shadows use the `shadow` token, never pure black.

## Icons

`NotaIcon` holds the 49 line icons (`icon/*`) as template SVGs in `NotaUI/Resources/Icons.xcassets`: 20 pt grid, 1.75 pt round stroke, recoloured with `foregroundStyle`. Use `NotaIconView(.pen)` (or `size:` for 12–18 pt uses). Nota's own chrome uses these; menus, alerts and sheets keep SF Symbols.

Tools: pen, pencil, highlighter, eraser, lasso, text, shapes, photo (the Pen Case's Insert menu), tape, laser and ruler (the tape and laser pointer tools and the ruler toggle; drawn in code for NOT-24, not yet in Figma). Editor: undo, redo, fit, grip, pressure, gauge, split (the editor's window menu; drawn in code for NOT-30 and not yet in Figma), return (the zoom window's new line; added in code, not yet in Figma), pens (the Pen Case's pen tray) and eyedropper (the colour picker's; both drawn in code for NOT-18, not yet in Figma). Library: grid, star, clock, trash, folder, plus, minus, search, filter, list, chevrons, xmark, ellipsis, share, arrow.up. Audio and AI: sparkles, mic, waveform, play, pause, stop, flashcards, quiz, calc.

To add one: draw it in Figma on the 20 pt grid, export the SVG with `stroke="#1A1A1F"`, add an imageset with `template-rendering-intent: template`, and add a case to `NotaIcon`.

## Components

| NotaUI | Figma | Notes |
| --- | --- | --- |
| `.buttonStyle(.notaIcon(selected:))` | Icon Button | 40 × 36. Selected: raised tile + ink glyph. Disabled: tertiary glyph. |
| `InkSwatch` | Ink Swatch | 28 pt target, 20 pt dot. Selected shrinks the dot to 16 and adds a 2 pt ring: never colour alone. |
| `NotaBarDivider(in:)` | Divider | 1 × 20, `textTertiary`. Turns horizontal in a vertical bar. |
| `.buttonStyle(.notaChip(selected:))`, `NotaChipStyle(.suggestion)` | Chip | 32 pt capsule. Filter / Filter Selected (ink tint) / Suggestion (AI tint). |
| `NotaTag` | Chip / Tag | 24 pt, caption emph, secondary. |
| `.buttonStyle(.nota(.primary / .ai / .secondary / .plain, size: .large / .compact))`, `NotaButtonLabel` | Button | Large 44 pt touch, compact 36 pt for toolbars. |
| `NotaSliderRow` | Slider Row | Label and value above a slider with an ink fill. |
| `.notaFloatingBar(fill:)` | Page Bar | Rounded 22, hairline `borderCard`, floating shadow. |
| `.notaPopoverContent()` | Tool Options | Raised background, popover on iPad and iPhone. |
| `NotaEmptyState` | *(addition)* | Icon on an ink-tint disc, Title 3, one line of guidance, optional primary button. |

InkKit draws the editor's own copies of the Icon Button, Ink Swatch, Divider, Slider Row, floating bar and popover surface (`InkKit/InkChrome.swift`) at the same sizes, coloured by its `InkTheme`. Its page sidebar uses `InkMetrics.panelRadius` (16, as `NotaRadius.panel`) and `paperRadius` (4, as `NotaRadius.paper`) for its thumbnails; Nota maps its pages button (`InkIcon.pages`) to `NotaIcon.grid`. Change a token here and the editor follows; change a size or shape and update `InkChrome.swift` to match.

App-only: `SidebarRow` (Figma Sidebar Row: 44 pt, selected = ink tint), `NoteCard` + `PaperThumbnail` (Figma Note Card and Paper, Letter ratio).

## Editor chrome

- **Pen Case** (`InkKit/ToolbarView.swift`): pen tray · tools · colours (quick colours and the colour well) · undo/redo · more. Sits in the navigation bar on the same row as the back button, centered (principal placement) and drawn flat without the bar's glass background; it can't be moved. A floating favourites bar is planned separately.
- **Room to grow:** the tool tray scrolls when it runs out of room, so M1 tools can be added without redesigning the bar. The shapes tool (`shapes` icon, `InkIcon.shapes`) sits after the highlighter, then the text tool (`text` icon, `InkIcon.text`). After the tools, the Insert menu (`photo` icon, `InkIcon.photo`; a system menu, so SF Symbols): Photos…, Take Photo… (disabled without a camera), Files…, Paste Image, Stickers…
- **Tool Options:** tap the selected tool again. Pen, pencil and highlighter start with a brush picker (the pencil's offers the HB and soft pencils and the crayon, a waxy raster brush; brushes are tiles drawn by the engine, so a new brush needs no icon):
  a two-column grid of tiles, each a sample stroke drawn by the engine in the current ink over the brush's
  name (selected: ink tint fill, emphasised ink-coloured label), the user's own brushes after the built-in ones (touch and hold a tile for Edit Brush / Edit a Copy / Delete Brush), and Customize Brush… (Edit Brush… for the user's own), which opens the brush editor. Then the three quick sizes (fine / medium / bold; touch and hold one to keep the current width there, or Reset Sizes) and a width slider; the lasso's shape (freeform or rectangle), what it selects (Ink and Objects switches; the last one on can't be turned off), Cut / Copy / Paste / Duplicate in a 2 × 2 grid of secondary buttons, Delete Selection (with shapes selected, also their line style, outline colour and fill). The shapes tool has Solid / Dashed / Dotted, a Fill row (No Fill, then the quick colours; fills draw at 30% opacity), a one-line hint and the width controls; its outline colour is the Pen Case's. The text tool has the typeface (Sans Serif, Serif, Rounded, Monospaced) and size (8–72 pt slider) new text boxes start in, and a one-line hint; their colour is the Pen Case's. The eraser adds its mode (Precision, Standard or Stroke, each with a one-line description), which ink it erases (All Ink, Highlighter or Pencil; disabled for Precision, which says why), Switch back after erasing, and Clear Page (with the same confirmation as the More menu).
- **Quick colours** follow the tool: pen and pencil start with the five pen inks, the highlighter its five highlighters, and the eraser and lasso keep the pen's dimmed so the bar doesn't change length; with something selected, the lasso's are lit and recolour the selection (the colour well stays dimmed). Each tool's quick colours are the user's to change: tap the selected swatch again to edit it in the colour picker (Reset Quick Colors goes back to the inks). The colour well after them (a hue ring around the current colour, filled when the colour isn't a quick colour) opens the picker for any colour.
- **Pen tray** (`InkKit/PenTrayView.swift`, the pens icon at the start of the Pen Case): the user's saved pens, each a row with the pen's sample stroke in its colour, its name, its brush and width, and its tool's icon; the pen in use is ink-tinted. Tap to write with it; Save Current Pen adds the one in use (named after its brush). Edit shows delete and reorder handles; each pen's menu has Rename…, Update to Current Pen, Move Up / Down and Delete Pen. Empty, it says what saving a pen does.
- **Colour picker** (`InkKit/ColorPickerView.swift`, a popover): saturation × brightness square over a hue bar (24 pt knobs with a raised ring), a hex field and the eyedropper, Recent (newest first, up to 12), then each palette (name, a ⋯ menu for Add Current Color / Rename / Delete, its swatches, a dashed + to add the current colour; touch and hold a swatch to remove it) and New Palette. Changes apply as you go; the final colour joins Recent when the picker closes.
- **Eyedropper** (`InkKit/EyedropperOverlay.swift`): covers the canvas with a floating banner (Touch the page to pick a color · Cancel); a 64 pt loupe above the finger shows the colour under it, and lifting uses it.
- **Brush editor** (`InkKit/BrushEditorView.swift`, a sheet): a live preview on paper, drawn by the engine in the tool's colour with the Pressure & Tilt settings, the name, then every `BrushDescriptor` parameter grouped as Nib, Pressure, Tilt, Speed and Ink Flow, Ends, Stroke, Texture, Jitter and Opacity: sliders (Slider Row) for the numbers, segmented pickers for tip, texture and blend, a toggle for tilt shading. Parameters that do nothing for the brush (an ellipse's angle on a round nib) are hidden. Cancel · Reset · Done, and "Also save as a pen".
- **Lasso selection** (`InkKit/CanvasView+Selection.swift`): draw a loop or rectangle to select, or tap to select the topmost stroke or object. The selection box is a dashed `accent` outline over an 8% `accent` tint, with 12 pt round knobs (paper fill, `accent` ring) at the corners to resize and one 28 pt above the top edge to rotate; it turns with a rotated object. Touch targets reach 22 pt around each knob. A single selected shape also shows its own handles (its points) as solid `accent` knobs with a paper ring; a line or arrow shows only those, with no box. The selection's actions are a system edit menu (`UIEditMenuInteraction`) placed clear of the rotate knob; menus keep SF Symbols, and Color shows the quick colours as a palette of swatches. With pictures selected it adds Crop (Crop, Freehand Crop, Reset Crop; one picture), Opacity (100 / 75 / 50 / 25%), and for any selection Save as Sticker.
- **Text format bar** (`InkKit/TextFormatBar.swift`): while a text box is edited, a floating bar (`inkFloatingBar`, 44 pt) at the top of the canvas, scrolling sideways if it runs out of room: typeface menu · size (− · size menu · +, stepping through 11–72 pt presets) · Bold, Italic, Underline · alignment menu · bulleted, numbered and checklist toggles · decrease / increase indent · Done (`textSelected`, emphasised body font). Toggles use the Icon Button with its selected state. *Exemption:* the format glyphs are SF Symbols until text-format line icons exist in `NotaIcon`. The Pen Case's colours stay live and colour the selected text. List markers and checkboxes are drawn in the text's own colour; a ticked box shows a tick in it.
- **Sticker picker** (`InkKit/InsertMenu.swift`, a popover from Insert › Stickers…): Title "Stickers", a three-column grid of 96 pt tiles, each the sticker's preview on paper (`paper`, `paperRadius`, hairline `border`) over its name (footnote, secondary); tap to place, touch and hold for Rename… / Delete Sticker. Empty, one line says how to make one (Save as Sticker in the selection menu).
- **Crop bar** (`InkKit/InsertMenu.swift`): while a picture is cropped, a floating bar (`inkFloatingBar`, 44 pt) at the top of the canvas: Rectangle / Freehand (segmented), a one-line hint (footnote, secondary), Reset (tertiary when there's nothing to reset), Cancel, Done (`textSelected`, emphasised). The picture shows whole at 30% with the kept part at full strength, outlined in `accent` (2 pt; dashed for freehand) with 12 pt grips (paper fill, `accent` ring) at its corners and edges.
- **Tape, laser and ruler** (NOT-24): the tape tool (`tape` icon) sits after the text tool, the laser pointer (`laser`) after the lasso, then the ruler toggle (`ruler`, Icon Button with its selected state while the ruler shows; touch and hold for Ruler / Protractor, a system menu). Tape's Tool Options: Plain / Striped / Grid (segmented), Reveal All · Hide All (secondary buttons), a one-line hint and the width controls (8–60 pt; quick sizes 12 / 20 / 32); its colours are the tape inks. Hidden tape is opaque with a zigzag-cut end and a hairline edge in its own colour darkened; revealed tape is its colour at 16% with a dashed edge. The laser's Tool Options: Trail / Dot (segmented) and a hint. The laser is the `laser` ink: a 14 pt glow at 22%, a 4.5 pt line and a 1.5 pt white core, fading over a second, with an 8 pt dot at its head.
- **Ruler** (`InkKit/RulerView.swift`): an 88 pt strip (or a 200 pt-radius half disc for the protractor) of `surfaceRaised` at 86% with a `border` hairline and `controlRadius` corners, ticks and numbers in `textSecondary` (page millimetres, half-centimetres and centimetres at the current zoom; degrees on the protractor), and its angle in the middle in `textPrimary`. While a stroke is drawn along it, a capsule by the Pencil (`surfaceRaised`, `border` hairline, `textPrimary`) shows the length in cm or the angle swept. *Exemption:* the ruler's numbers and readout are UIKit text drawn with the system font at the footnote and caption-2 text style sizes (monospaced digits), as `NotaFont` uses SF Pro at those sizes; `InkTheme` only carries SwiftUI fonts.
- **Presenting badge**: while an external display mirrors the page, a small floating capsule (`surfaceRaised`, `laser` icon, footnote emphasised, `textSecondary`) at the top of the editor says "Presenting this page". The external display itself shows only the page on the `desk` colour, with a `paper`-style shadow; with no note open, one line in headline `textSecondary`.
- **Links, bookmarks and outline** (NOT-31): the selection menu adds Add Link… (Open Link, Edit Link…, Remove Link
  for a selected link; SF Symbols, as menus keep them). The link sheet is a system sheet: Web / This Note / Another
  Note (segmented), then a web-address field, the note's pages (checkmark in `accent`; "This page", "Bookmarked"
  and outline titles as footnote `textSecondary`), or a note menu and its pages. A link is drawn in `ink/blue`.
  After a link is followed, a floating Back capsule (`surfaceRaised`, `back` glyph, footnote emphasised,
  `textPrimary`) sits at the top right: "Back to Page 3" or "Back to <note>". The page bar has a bookmark button
  (`bookmark` icon, Icon Button selected while the page is bookmarked) after the page number. The page sidebar has
  Pages / Outline (segmented) under its title; bookmarked thumbnails show a 14 pt `bookmark` in `accent` at the top
  right. The Outline tab: section headers in footnote emphasised `textSecondary` (Bookmarks, Outline, From PDF),
  rows in body with the page number in footnote `textSecondary` (the current page's title in `accent`), PDF entries
  indented 12 pt per level, Add This Page in `accent`, and a one-line hint in `textTertiary` when there are no
  bookmarks. New icons: `link` and `bookmark` (`InkIcon.link`, `.bookmark`); the outline and Back glyphs map to
  `list` and `chevron.left`.
- **More** (ellipsis): fit page (with zoom level), zoom window, Add Test Object (a placeholder object for the object layer, until shapes, text and images land), pressure and tilt, Apple Pencil, debug HUD, clear page.
- **Page Bar** (`InkKit/PageBar.swift`): previous · Page n of m · next · bookmark · add (hold for add before/after/size and Delete Page) · paper-size pill.

Not yet built (tracked in NOT-87): choosing which tools live in the Pen Case (Customize Toolbar), and the Liquid Glass variants for iOS 26+.

## Library

- Background `bgApp`, sidebar rows per Figma, folders use their label ink.
- Filters are chips; New Note is a compact primary button.
- Each empty section has its own `NotaEmptyState`: All Notes and folders offer New Note; search, filters, Recents, Favorites, Shared and Recently Deleted explain what would appear there.
