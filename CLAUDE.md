# CLAUDE.md

Agent guide for Nota, an iPad note-taking app with an Apple Pencil canvas (InkKit). Read these rather than
guessing; this file doesn't repeat them:

- [README.md](README.md): what the app does, layout, the dependency-rule diagram, known limitations.
- [DESIGN.md](DESIGN.md): design tokens, colour roles, inks, icons, shared controls.
- [Packages/InkKit/README.md](Packages/InkKit/README.md): how the drawing engine works, and its benchmarks.
- [PLAN.md](PLAN.md): current milestone and the next issues. Linear is the source of truth.

## Build, test, lint

Run from the repo root on macOS with Xcode. Use the **iPad Pro 13-inch (M5)** simulator (any iPad Pro works;
CI picks the first one available). Before opening a PR, run everything below that your change touches.

```bash
# App
xcodebuild build -project Nota.xcodeproj -scheme Nota \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' CODE_SIGNING_ALLOWED=NO

# Package tests (only InkKit and NotaCore have test targets). Benchmarks are skipped here; see below.
(cd Packages/InkKit && xcodebuild test -scheme InkKit -skip-testing:InkKitBenchmarks \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' CODE_SIGNING_ALLOWED=NO)
(cd Packages/NotaCore && xcodebuild test -scheme NotaCore \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' CODE_SIGNING_ALLOWED=NO)

# Lint (brew install swiftlint swiftformat)
swiftformat --lint .          # `swiftformat .` to fix
swiftlint lint --strict --config .swiftlint.yml
scripts/check-dependency-rule.sh
```

CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs exactly these: a **Lint** job (SwiftFormat,
SwiftLint strict, dependency rule) and a **Build & Test** job (app build, then InkKit and NotaCore tests).
SwiftLint runs with `--strict`, so warnings fail CI.

> CI is **temporarily manual-only** to save Actions minutes: both workflows only run on `workflow_dispatch`
> (Actions tab › Run workflow, or `gh workflow run ci.yml --ref <branch>`). Until it's switched back on,
> running the commands above locally is the check, and `main` doesn't require any checks to merge. To
> re-enable: restore the commented-out triggers and re-add **Lint** and **Build & Test** as required checks.

## Architecture rules

| Package | Holds | May import |
| --- | --- | --- |
| `InkKit` | Drawing engine: Pencil input, brushes, smoothing, rendering, pages, `InkCanvasEditor`, `InkTheme` | nothing of ours |
| `NotaUI` | Design system: tokens, icons, shared controls | nothing of ours |
| `NotaCore` | Domain: `Note`, `Folder`, library filters/sorting/search (`Library.swift`), `DocumentStore`, note package + manifest, sample data | InkKit |
| `NotaDocuments` | Cover thumbnails, paper templates (PDF, import/export later) | NotaCore, InkKit, NotaUI; never another feature package |
| `Nota/` (app) | Composition, navigation and scenes **only** | everything |

- Logic goes in a package, not in the app's views. If you're writing a rule or a model in `Nota/`, move it
  to NotaCore (or the relevant feature package) so it can be tested.
- Each `Package.swift` lists exactly the allowed dependencies; `scripts/check-dependency-rule.sh` also
  catches imports that would only compile inside the app build. Adding a package means updating both.
- InkKit must stay free of Nota: it's themed through `InkTheme`, and the app supplies `InkTheme.nota`
  (`Nota/Theme/`). The InkCanvas prototype consumes InkKit by local path, so don't break its public API
  casually.
- New feature packages (NotaAudio, NotaSync, NotaAI, …) are created when their first code lands, not before.

## Performance gate

Ink must not get slower. Budgets (NOT-13 for ink, NOT-98 for the canvas), measured on a simulated iPad Pro
13-inch. **Enforced** (the committed baseline meets them, so missing one fails the compare):

- **Live stroke:** p95 < 2 ms of work per touch event for every brush (stamp brushes' p99 too), and it mustn't
  grow with stroke length.
- **Page open:** < 150 ms to reopen a 5k-stroke page; a 5k-stroke page decodes in < 50 ms.
- **Pixel erase** on a 5k-stroke page shows correct pixels in < 16 ms.
- **Gestures:** main-thread work per frame p95 < 8 ms during a pinch, a pan, a fling through 20 pages and over a
  page of objects; < 8 ms of render work per pan step at 6×; ink sharp < 150 ms after a pan; no blank frame in
  the fling; the template and objects sharp < 150 ms after a zoom.
- **Continuous scrolling:** a 5k-stroke page seen before entering view has its ink in < 50 ms; scrolling a
  20-page note of 5k-stroke pages adds < 300 MB.
- **Memory:** a 5k-stroke page at 6× while writing peaks < 80 MB.

**Known misses** (in the baseline as missed, so they don't fail a run but show how far over they are): undo
(~45 ms) and stroke erase (~0.55 s) on the 5k page, ink sharp after a pinch to a new level (~0.2 s, ~0.17 s if
the pinch is held), the 5k page's `.ink` file size (1.9 MB against 1 MB), and single-frame worsts (`*_max_ms`),
which swing with one scheduler hiccup on the simulator and never fail a run. The time-based misses are bound by
Core Graphics drawing strokes (InkKit README › Rendering pipeline › Why tiles). None of these budgets has been
confirmed on a physical iPad yet.

If you touch anything on the ink path (InkKit input, smoothing, geometry, rendering, tiles, rasters, page
open/close), run the benchmarks in Release and compare with the baseline before and after:

```bash
scripts/run-benchmarks.sh bench-output
scripts/bench-compare.py bench-output/results.json \
  --baseline Packages/InkKit/Benchmarks/baselines/apple-m1-pro-simulator.json
```

`--only zoom. pan. edit. scroll. memory.continuous` compares a run of just
`-only-testing:InkKitBenchmarks/CanvasBenchmarks`.

It fails on a > 10% regression or on a budget the baseline met and this run misses. The committed baseline
was recorded on an M1 Pro, and simulator numbers are noisy: run on an idle Mac (not straight after other
builds, which can show 40–100% "regressions" with no code change), and compare `main` against your branch on
the same machine (`--write-baseline bench-output/main.json` on `main` first). Put the before/after numbers in
the PR. Details: InkKit README › Benchmarks.

Swift Testing note: `xcodebuild test` prints XCTest's `Executed 0 tests` even when it passes. The real count
is on the `✔ Test run with N tests` line.

## Design system

Library and editor chrome use **NotaUI tokens only** (`NotaColor`, `NotaUIColor`, type, spacing, radius,
elevation, icons). No `Color(red:…)`, no `.primary`/`.secondary`, no system greys, no magic sizes. InkKit
chrome reads from `InkTheme`. If a value is missing, add a token to NotaUI and DESIGN.md first. Mind the
three accent roles (ink = your actions, violet = AI acting for you, red = recording only) and that paper and
ink don't change in dark mode. Exemptions are listed in DESIGN.md.

## Workflow

- **Issues** live in Linear (team NOT, project *Nota*). Every change belongs to a `NOT-<n>` issue.
- **Branch:** `<user>/not-<n>-<slug>`, e.g. `bintawachild/not-11-app-test-target-for-models-filters-and`
  (Linear's "copy git branch name" gives it). Branch from `main`, or from the branch you depend on when
  stacking PRs.
- **Commits:** imperative, sentence-case summary of what changed for the user or the code, ending in the
  issue: `Persist page sizes, paper and page count per note (NOT-7)`. Body explains why, if it isn't obvious.
- **PRs:** title in the same style with `(NOT-<n>)`; the body says what changed, why, how it was tested
  (commands run, simulator, benchmark numbers for ink changes) and links the Linear issue. Base on `main`
  unless stacked.
- **Tests come with new logic** (NOT-11). Library rules have NotaCore tests against an in-memory SwiftData
  store; engine behaviour has InkKit tests. Pure view code is the exception.
- Update README.md / DESIGN.md / InkKit's README in the same PR when behaviour, layout or tokens change.
  Update PLAN.md when a milestone or listed issue changes status.

## Gotchas

- **iPad only**, iPadOS **17.5+** (`TARGETED_DEVICE_FAMILY = 2`); don't add iPhone or Mac idioms.
- **Swift 5 language mode**, swift-tools-version 5.10. Don't switch packages to Swift 6 mode piecemeal.
- **No third-party dependencies.** Apple frameworks and our own packages only.
- **Only tested on simulators.** Nothing has run on a physical iPad with Pencil yet (NOT-12), so pressure,
  tilt, latency and palm rejection are unverified; the benchmark input fixture is synthetic. Say so in PRs
  that depend on real-device behaviour.
- Notes live in `.nota` packages written by `DocumentStore` (NotaCore): the manifest is the source of truth
  for pages and dates, SwiftData is the library index and can be rebuilt from packages. All package I/O goes
  through `DocumentStore`'s serial queue and `PackageFiles` (atomic temp + rename); don't write the manifest,
  `pages/` or `templates/` from elsewhere (`ThumbnailStore` owns `thumbs/`). See README › Known limitations.
- `DerivedData/` and `build/` in the repo root are gitignored local build output; don't commit them.
- Personal preferences go in `CLAUDE.local.md` (gitignored), not this file.
