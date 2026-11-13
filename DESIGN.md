# Nota design system

Nota's visual language: tokens, icons and the shared controls built from them. It lives in the **NotaUI** package (`Packages/NotaUI`). InkKit doesn't depend on NotaUI: its editor chrome takes colours, fonts, icons and inks from an `InkTheme`, and the app passes `InkTheme.nota` (`Nota/Theme/InkTheme+Nota.swift`), built from these tokens. The source of truth is the Figma file [Nota · Components](https://www.figma.com/design/umhMoBpVlbSKRFE1aD1L6J/Nota?node-id=13-43).

**Rule:** Library and editor chrome use tokens only. No `Color(red:…)`, no `.secondary`/`.primary`, no system greys. If a value is missing, add a token here first.

Exempt: the debug Pencil HUD (a developer overlay), system menus, alerts and sheets (they keep system styling and SF Symbols).

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

`NotaIcon` holds the 42 line icons (`icon/*`) as template SVGs in `NotaUI/Resources/Icons.xcassets`: 20 pt grid, 1.75 pt round stroke, recoloured with `foregroundStyle`. Use `NotaIconView(.pen)` (or `size:` for 12–18 pt uses). Nota's own chrome uses these; menus, alerts and sheets keep SF Symbols.

Tools: pen, pencil, highlighter, eraser, lasso, text, shapes, photo. Editor: undo, redo, fit, grip, pressure, gauge, split (the editor's window menu; drawn in code for NOT-30 and not yet in Figma), return (the zoom window's new line; added in code, not yet in Figma). Library: grid, star, clock, trash, folder, plus, minus, search, filter, list, chevrons, xmark, ellipsis, share, arrow.up. Audio and AI: sparkles, mic, waveform, play, pause, stop, flashcards, quiz, calc.

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

InkKit draws the editor's own copies of the Icon Button, Ink Swatch, Divider, Slider Row, floating bar and popover surface (`InkKit/InkChrome.swift`) at the same sizes, coloured by its `InkTheme`. Change a token here and the editor follows; change a size or shape and update `InkChrome.swift` to match.

App-only: `SidebarRow` (Figma Sidebar Row: 44 pt, selected = ink tint), `NoteCard` + `PaperThumbnail` (Figma Note Card and Paper, Letter ratio).

## Editor chrome

- **Pen Case** (`InkKit/ToolbarView.swift`): tools · inks · undo/redo · more. Sits in the navigation bar on the same row as the back button, centered (principal placement) and drawn flat without the bar's glass background; it can't be moved. A floating favourites bar is planned separately.
- **Room to grow:** the tool tray scrolls when it runs out of room, so M1 tools (text, shapes, photo; icons already in the set) can be added without redesigning the bar.
- **Tool Options:** tap the selected tool again. Width presets (fine / medium / bold) and a width slider; whole-stroke or pixel eraser; freeform or rectangle lasso and Delete Selection.
- **Colour presets** follow the tool: pen and pencil show the five pen inks, the highlighter its five highlighters, and the eraser and lasso keep the pen inks dimmed so the bar doesn't change length.
- **More** (ellipsis): fit page (with zoom level), pressure and tilt, debug HUD, clear page.
- **Page Bar** (`InkKit/PageBar.swift`): previous · Page n of m · next · add (hold for add before/after/size and Delete Page) · paper-size pill.

Not yet built (tracked in NOT-87): choosing which tools live in the Pen Case (Customize Toolbar), and the Liquid Glass variants for iOS 26+.

## Library

- Background `bgApp`, sidebar rows per Figma, folders use their label ink.
- Filters are chips; New Note is a compact primary button.
- Each empty section has its own `NotaEmptyState`: All Notes and folders offer New Note; search, filters, Recents, Favorites, Shared and Recently Deleted explain what would appear there.
